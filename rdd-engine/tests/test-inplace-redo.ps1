# inplace-redo-session-reuse tests — 桥接 run 同阶段返工复用原 worker 会话
# Covers requirements/inplace-redo-session-reuse.md acceptance 1-5 + design regressions:
#   T1  reclaim in-place full chain: live sidecar session -> redo pointer into the ORIGINAL
#       session (failure list + re-report instruction), reported->claimed same node, ledger
#       type=redo entry with failure_ref, roster gains no session.create row; re-report+settle
#       closes the round trip (report after redo is legal — the node is claimed again)
#   T2  fallback on dead session: prune + graft + repush (legacy path, session.create)
#   T3  -NoReuse escape: live session still takes the legacy rebuild path (byte-shape)
#   T4  no_push gate: in-place tree-side actions land, delivery skipped, next_step names the
#       manual path (isolation discipline: zero backend for the run's lifetime)
#   T5  AutoDispatch reuse: dead-claim repush resolves the ALIVE roster sibling (same task x
#       role) and prompts IT instead of session.create (pointer to history, no new session)
#   T6  rollback never reuses: rebuilt nodes push via session.create even with an alive
#       same-task CTO session in the roster (v1 boundary: cross-stage rebuild semantics)
#   T7  dead-endpoint fallback: unreachable probe -> liveness unknown -> legacy path
#       (no window, deterministic push failure); plus pure-CLI no_push fallback shape
#   T8  in-place prompt failure: RECLAIM_INPLACE_PROMPT_FAILED (zero state residue, node
#       stays reported, no redo entry) -> manual dispatch re-prompts the sidecar session
#       (reuse resolution) -> reclaim again lands the redo
#   T9  start-role SESSION_REUSE_UNSUPPORTED: -ExistingSessionId on a non-dsh backend
# Fixture form (design reading note): the isolation fixture is a LOCAL STUB DSH_WEB_URL
# endpoint (fake liveness + /api envelope receiver, zero real backend); the -NoPush flag in
# T4 means "skip delivery" under the in-place semantics. Runs the production interpreters
# (Windows PowerShell 5.1) against a throwaway git repo. Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'
$Work      = Join-Path $env:TEMP ('inplace-redo-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}
function Invoke-Bridge { param([string[]]$A)
    # bridge 默认形状翻转（promulgate legacy→wake）：本套件按旧链 chain-head 拓扑
    # 书写——promulgate 未显式带 -Shape 时机械补 legacy（显式 -Shape 优先，
    # 非 promulgate 命令零影响）。
    if ($A -contains 'promulgate' -and -not ($A -contains '-Shape')) { $A = @($A) + @('-Shape', 'legacy') }
    Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }
function Invoke-Tree   { param([string[]]$A) Invoke-Ps1 $TreePs1 $A }

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Read-LedgerLines { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/ledger.jsonl')
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne '' })
}

# --- stub control files ---
$StubAlive  = Join-Path $Work 'stub-alive.txt'     # alive session ids (liveness probe truth)
$StubFail   = Join-Path $Work 'stub-fail.txt'      # session ids whose session.prompt MUST fail
$StubCalls  = Join-Path $Work 'stub-calls.jsonl'   # every /api call (method/payload/response)

function Set-StubAlive { param([string[]]$Ids)
    Write-Utf8NoBom $StubAlive ((@($Ids) | Where-Object { $_ }) -join "`n")
}
function Add-StubFail { param([string]$Id)
    $cur = @()
    if (Test-Path -LiteralPath $StubFail) { $cur = @([System.IO.File]::ReadAllLines($StubFail) | Where-Object { $_.Trim() -ne '' }) }
    $cur += $Id
    Write-Utf8NoBom $StubFail (($cur | Select-Object -Unique) -join "`n")
}
function Clear-StubFail { Write-Utf8NoBom $StubFail '' }
function Read-StubCalls {
    if (-not (Test-Path -LiteralPath $StubCalls)) { return @() }
    $rows = @()
    foreach ($l in @([System.IO.File]::ReadAllLines($StubCalls) | Where-Object { $_.Trim() -ne '' })) {
        try { $rows += ,($l | ConvertFrom-Json) } catch { }
    }
    return $rows
}
function Get-RosterSessionIds { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/sessions.json')
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @(((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).sessions) | ForEach-Object { [string]$_.session_id })
}

# --- stub endpoint: fake plugin liveness + fake /api envelope receiver ---
# One raw-TCP HTTP server in a background job (HttpListener/http.sys is blocked by
# the harness sandbox, so the server hand-parses HTTP/1.1 at the byte level:
# headers until CRLFCRLF, Expect: 100-continue interim reply, Content-Length-exact
# UTF-8 body, Connection: close). Zero real backend touched: liveness truth is the
# stub-alive.txt set; /api session.create assigns stub-s<N> ids; session.prompt
# honors the stub-fail.txt injection set (business-error envelope).
$port = 0
$tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
$tcp.Start(); $port = ($tcp.LocalEndpoint).Port; $tcp.Stop()

$stubJob = Start-Job -ScriptBlock {
    param($Root, $Port)
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $sidCounter = 0
    function Read-IdSet { param($Path)
        $set = @{}
        if (Test-Path -LiteralPath $Path) {
            foreach ($l in [System.IO.File]::ReadAllLines($Path)) { $t = $l.Trim(); if ($t) { $set[$t] = $true } }
        }
        return $set
    }
    function Log-Call { param($Root, $Method, $Payload, $Extra)
        $row = @{ at = (Get-Date).ToUniversalTime().ToString('o'); method = $Method; payload = $Payload }
        if ($null -ne $Extra) { foreach ($k in @($Extra.Keys)) { $row[$k] = $Extra[$k] } }
        [System.IO.File]::AppendAllText((Join-Path $Root 'stub-calls.jsonl'), ((ConvertTo-Json $row -Depth 10 -Compress) + "`n"), $utf8NoBom)
    }
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 10000
            $stream.WriteTimeout = 10000
            # byte-level header read until CRLFCRLF (a StreamReader would buffer
            # past the header block and steal body bytes)
            $headerBytes = New-Object System.Collections.Generic.List[byte]
            $b1 = 0; $b2 = 0; $b3 = 0; $b4 = 0
            while ($true) {
                $nb = $stream.ReadByte()
                if ($nb -lt 0) { throw 'eof-during-headers' }
                $headerBytes.Add([byte]$nb)
                $b1 = $b2; $b2 = $b3; $b3 = $b4; $b4 = $nb
                if ($b1 -eq 13 -and $b2 -eq 10 -and $b3 -eq 13 -and $b4 -eq 10) { break }
            }
            $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
            $lines = @($headerText -split "`r`n")
            $reqParts = @(([string]$lines[0]).Split(' '))
            $methodVerb = [string]$reqParts[0]
            $rawPath = if ($reqParts.Count -gt 1) { [string]$reqParts[1] } else { '/' }
            $headers = @{}
            foreach ($h in @($lines | Select-Object -Skip 1)) {
                if (-not $h) { continue }
                $idx = $h.IndexOf(':')
                if ($idx -gt 0) { $headers[$h.Substring(0, $idx).Trim().ToLower()] = $h.Substring($idx + 1).Trim() }
            }
            if ($headers.ContainsKey('expect') -and ([string]$headers['expect']).ToLower().Contains('100-continue')) {
                $cont = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                $stream.Write($cont, 0, $cont.Length)
                $stream.Flush()
            }
            $bodyText = ''
            if ($headers.ContainsKey('content-length')) {
                $len = 0
                try { $len = [int]$headers['content-length'] } catch { $len = 0 }
                if ($len -gt 0) {
                    $bodyBytes = New-Object byte[] $len
                    $have = 0
                    while ($have -lt $len) {
                        $n = $stream.Read($bodyBytes, $have, $len - $have)
                        if ($n -le 0) { break }
                        $have += $n
                    }
                    $bodyText = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $have)
                }
            }
            $bodyJson = $null
            try { $bodyJson = $bodyText | ConvertFrom-Json } catch { }
            # --- query parse ---
            $q = @{}
            $pathOnly = $rawPath
            if ($rawPath.Contains('?')) {
                $pathOnly = $rawPath.Substring(0, $rawPath.IndexOf('?'))
                foreach ($pair in ($rawPath.Substring($rawPath.IndexOf('?') + 1)).Split('&')) {
                    if (-not $pair) { continue }
                    $kv = $pair.Split('=')
                    $k = [System.Uri]::UnescapeDataString($kv[0])
                    $v = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString(($kv[1] -replace '\+', ' ')) } else { '' }
                    $q[$k] = $v
                }
            }
            $alive = Read-IdSet (Join-Path $Root 'stub-alive.txt')
            $fail = Read-IdSet (Join-Path $Root 'stub-fail.txt')
            $jsonOut = $null
            if ($methodVerb -eq 'GET' -and $pathOnly -eq '/rdd-goal-tree/liveness') {
                # session-keyed probe: registry direct
                if ($q.ContainsKey('session_id') -and ([string]$q['session_id']).Trim() -ne '') {
                    $sid = [string]$q['session_id']
                    $live = if ($alive.ContainsKey($sid)) { 'alive' } else { 'dead' }
                    $jsonOut = @{ session_id = $sid; liveness = $live; reason = 'stub registry (session-keyed probe)' } | ConvertTo-Json -Compress
                }
                else {
                    # node-keyed probe: resolve the claims sidecar, then the registry
                    $sid = $null
                    if ($q.ContainsKey('run') -and $q.ContainsKey('node') -and $q['run'] -and $q['node']) {
                        $claimsPath = Join-Path $Root (".rdd/goal-trees/$($q['run'])/state/claims/$($q['node']).json")
                        if (Test-Path -LiteralPath $claimsPath -PathType Leaf) {
                            try {
                                $claim = [System.IO.File]::ReadAllText($claimsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                                if ($claim.dsh_session_id) { $sid = [string]$claim.dsh_session_id }
                            } catch { }
                        }
                    }
                    $live = 'unknown'
                    if ($sid) { $live = if ($alive.ContainsKey($sid)) { 'alive' } else { 'dead' } }
                    $jsonOut = @{ run = $q['run']; node = $q['node']; session_id = $sid; liveness = $live; reason = 'stub registry (node-keyed probe)' } | ConvertTo-Json -Compress
                }
            }
            elseif ($methodVerb -eq 'POST' -and $pathOnly.StartsWith('/api/')) {
                $method = $pathOnly.Substring(5)   # strip '/api/'
                # client-request envelope: real params live under .payload
                $params = if ($bodyJson -and $bodyJson.payload) { $bodyJson.payload } else { $bodyJson }
                $ok = $true; $code = $null; $message = $null
                $value = @{}
                switch ($method) {
                    'agentPreset.list' { $value = @{ presets = @(@{ id = 'rdd-pm' }, @{ id = 'rdd-cto' }, @{ id = 'rdd-ux' }, @{ id = 'rdd-dev' }, @{ id = 'rdd-qa' }, @{ id = 'rdd-eval' }, @{ id = 'rdd-pse' }, @{ id = 'rdd-planner' }) } }
                    'workspace.create' { $value = @{ workspace = @{ workspaceId = 'stub-ws-1' } } }
                    'session.create'   { $script:sidCounter++; $value = @{ sessionId = "stub-s$($script:sidCounter)" } }
                    'session.prompt'   {
                        $target = if ($params -and $params.sessionId) { [string]$params.sessionId } else { '' }
                        if ($target -and $fail.ContainsKey($target)) { $ok = $false; $code = 'STUB_INJECTED_FAILURE'; $message = 'stub injected session.prompt failure' }
                        $value = @{}
                    }
                    default            { $value = @{} }
                }
                $extra = $null
                if ($method -eq 'session.create') { $extra = @{ assigned_sid = $value['sessionId'] } }
                Log-Call $Root $method $params $extra
                if ($ok) {
                    $jsonOut = @{ result = @{ ok = $true; value = $value } } | ConvertTo-Json -Depth 10 -Compress
                }
                else {
                    # business-error shape: code/message nested under result.error
                    $jsonOut = @{ result = @{ ok = $false; error = @{ code = $code; message = $message } } } | ConvertTo-Json -Depth 10 -Compress
                }
            }
            else {
                $jsonOut = '{"error":"not found"}'
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$jsonOut)
            $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($hb, 0, $hb.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        catch { }
        finally { try { $client.Close() } catch { } }
    }
} -ArgumentList $Work, $port

function Stop-Stub {
    if ($stubJob) { Stop-Job -Job $stubJob -ErrorAction SilentlyContinue; Remove-Job -Job $stubJob -Force -ErrorAction SilentlyContinue }
}

# --- stub control helpers ---
function Get-StubCreateCount { param([string]$RunId = '')
    @((Read-StubCalls) | Where-Object { $_.method -eq 'session.create' }).Count
}
function Get-StubPromptsTo { param([string]$SessionId)
    @((Read-StubCalls) | Where-Object { $_.method -eq 'session.prompt' -and $_.payload -and [string]$_.payload.sessionId -eq $SessionId })
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
Set-StubAlive @()
Clear-StubFail
$null = git init -q $Work 2>$null

$env:DSH_WEB_URL = "http://127.0.0.1:$port"
# wait for the stub listener (bridge children will fail-fast if it is not up yet)
$stubUp = $false
foreach ($try in 1..40) {
    try { $null = [System.Net.WebRequest]::Create("http://127.0.0.1:$port/rdd-goal-tree/liveness?session_id=ping").GetResponse(); $stubUp = $true; break }
    catch { Start-Sleep -Milliseconds 250 }
}

# fixtures (mirror test-bridge-acceptance conventions)
function New-Archive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`ninplace-redo 测试归档 $Name。`n"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        $doc = "requirements/t$i.md"
        Write-Utf8NoBom (Join-Path $archDir $doc) "# $Name 需求 $i`n`n- **描述**：inplace-redo 测试需求 $i`n- **验收标准**：见 overview.md`n"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}
function Write-TestPlan { param([string]$Path, $Stages)
    $stageObjs = @()
    foreach ($st in $Stages) {
        $stageObjs += ,@{
            id = [string]$st.id
            goal = "stage $($st.id) 目标"
            milestone = "stage $($st.id) 里程碑"
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = @(@($st.tasks | ForEach-Object { [int]$_ } | Sort-Object))
            acceptance_point = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' }
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-01T00:00:00Z'; planner = 'test'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}
function New-Cb { param([string]$NodeId, [string]$Ref, [bool]$Qualified = $true)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'inplace-redo test delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
    }
    if ($Qualified) { $cb['extras'] = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } } }
    $cbFile = Join-Path $env:TEMP ("ir-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Claim { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$AsSession = $null)
    $prev = $env:DSH_SESSION_ID
    if ($AsSession) { $env:DSH_SESSION_ID = $AsSession } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    try {
        $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    }
    finally {
        if ($prev) { $env:DSH_SESSION_ID = $prev } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    }
    return $r
}
function Do-Report { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref, [bool]$Qualified = $true)
    $cb = New-Cb $NodeId $Ref $Qualified
    Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref, [bool]$Qualified = $true, [string]$AsSession = $null)
    $r = Do-Claim $RunId $NodeId $Role $AsSession
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $r = Do-Report $RunId $NodeId $Role $Ref $Qualified
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return $r
}

Push-Location $Work
try {
    Assert-True $stubUp 'T0 stub endpoint up (liveness + /api receiver)' "port $port"

    # ================= T1: reclaim in-place full chain =================
    $arch1 = New-Archive 'ir-t1' '[{"title":"T1","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf1 = Write-TestPlan (Join-Path $Work 'ir-t1-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1)
    Assert-True ($r.json.success -eq $true) 'T1 promulgate ok (push enabled)' ($r.raw)
    $run1 = 'deliver-ir-t1'
    $b1 = Read-BridgeJson $run1
    $devNode = [string]$b1.tasks.'1'.stages.DEV
    Assert-True ($devNode -ne '') 'T1 DEV head grafted + auto-pushed (stub session.create ran)' ($devNode)
    $push1Sid = $null
    foreach ($sid in (Get-RosterSessionIds $run1)) { if ($sid -like 'stub-s*') { $push1Sid = $sid } }
    Assert-True ($null -ne $push1Sid) 'T1 roster row for the pushed session'
    $createsBefore = Get-StubCreateCount

    # claim as sess-t1-live (alive), report unqualified -> reported
    $r = Do-Deliver $run1 $devNode 'DEV' "$arch1/requirements/t1.md" $false 'sess-t1-live'
    Set-StubAlive @('sess-t1-live')
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run1, '-NodeId', $devNode)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery-inplace') 'T1 reclaim takes the in-place path (live sidecar session)' ($r.raw)
    Assert-True ([string]$r.json.data.node_id -eq $devNode -and [string]$r.json.data.session.id -eq 'sess-t1-live') 'T1 same node + original session reported' ("node=$($r.json.data.node_id) sid=$($r.json.data.session.id)")
    # tree: reported -> claimed, same id, reported_at cleared, holder kept
    $n1 = Find-TreeNode $run1 $devNode
    Assert-True ([string]$n1.status -eq 'claimed' -and $null -eq $n1.reported_at -and [string]$n1.claimed_by -eq 'DEV') 'T1 node reported->claimed (same id, holder kept, reported_at cleared)' ("status=$($n1.status) reported_at=$($n1.reported_at)")
    # ledger: type=redo entry with failure_ref + session id
    $lastLedger = (Read-LedgerLines $run1)[-1] | ConvertFrom-Json
    Assert-True ([string]$lastLedger.type -eq 'redo' -and [string]$lastLedger.node_id -eq $devNode -and [string]$lastLedger.session_id -eq 'sess-t1-live' -and ([string]$lastLedger.failure_ref).Trim() -ne '' -and [string]$lastLedger.trigger -eq 'reclaim') 'T1 ledger redo entry (failure_ref + session_id + trigger)' ((Read-LedgerLines $run1)[-1])
    Assert-True (([string]$lastLedger.failure_ref) -match 'verification|quality_scan|full_report') 'T1 failure_ref carries mechanically retrieved evidence pointers' ([string]$lastLedger.failure_ref)
    # pointer payload: prompt to the ORIGINAL session with failure list + re-report instruction
    # (@() wrap: PS unrolls one-element pipeline output to a bare object, .Count would be $null)
    $prompts1 = @(Get-StubPromptsTo 'sess-t1-live')
    Assert-True ($prompts1.Count -ge 1) 'T1 redo pointer prompted into the original session'
    $pText = if ($prompts1.Count -gt 0) { [string]$prompts1[-1].payload.content[0].text } else { '' }
    Assert-True ($pText -match '重做指令' -and $pText -match '失败清单' -and $pText -match "report -RunId $run1" -and $pText -match $devNode) 'T1 pointer payload: failure list + re-report instruction + node anchor' ($pText)
    # no new session.create; roster unchanged for stub-* ids
    Assert-True ((Get-StubCreateCount) -eq $createsBefore) 'T1 zero new session.create (in-place = no cold start)'
    Assert-True (@(Get-RosterSessionIds $run1 | Where-Object { $_ -like 'stub-s*' }).Count -eq 1) 'T1 roster keeps exactly one work session row'
    # push ledger carries reuse visibility
    $b1 = Read-BridgeJson $run1
    $att = $b1.pushes.$devNode.attempts | Select-Object -Last 1
    Assert-True ([string]$att.reused_session_id -eq 'sess-t1-live') 'T1 push attempt records reused_session_id (status visibility)' (($att | ConvertTo-Json -Compress))
    # sidecar: session binding preserved
    $sidecar = Get-Content -LiteralPath (Join-Path $Work ".rdd/goal-trees/$run1/state/claims/$devNode.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$sidecar.dsh_session_id -eq 'sess-t1-live' -and ([string]$sidecar.claimed_at).Trim() -ne '') 'T1 sidecar keeps dsh_session_id, claimed_at refreshed' ($sidecar | ConvertTo-Json -Compress)
    # round trip: re-report (qualified) in the same session shape + settle completes
    $r = Do-Report $run1 $devNode 'DEV' "$arch1/requirements/t1.md" $true
    Assert-True ($r.json.success -eq $true) 'T1 re-report after redo accepted (claimed node, same session)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run1, '-NodeId', $devNode)
    Assert-True ($r.json.success -eq $true) 'T1 settle after in-place redo round trip' ($r.raw)

    # ================= T2: fallback on dead session (legacy path) =================
    $arch2 = New-Archive 'ir-t2' '[{"title":"T2","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf2 = Write-TestPlan (Join-Path $Work 'ir-t2-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-PlanFile', $pf2)
    Assert-True ($r.json.success -eq $true) 'T2 promulgate ok' ($r.raw)
    $run2 = 'deliver-ir-t2'
    $b2 = Read-BridgeJson $run2
    $dev2 = [string]$b2.tasks.'1'.stages.DEV
    $r = Do-Deliver $run2 $dev2 'DEV' "$arch2/requirements/t1.md" $false 'sess-t2-dead'   # NOT in alive set -> dead
    $createsBefore2 = Get-StubCreateCount
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run2, '-NodeId', $dev2)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'T2 dead session -> legacy rejected-delivery path' ($r.raw)
    Assert-True ([string]$r.json.data.fallback -eq 'dead') 'T2 fallback reason surfaced (dead)' ([string]$r.json.data.fallback)
    Assert-True ([string]$r.json.data.pruned_node -eq $dev2 -and [string]$r.json.data.node_id -ne $dev2) 'T2 legacy shape: old node pruned, replacement grafted' ($r.raw)
    $new2 = [string]$r.json.data.node_id
    $n2old = Find-TreeNode $run2 $dev2
    $n2new = Find-TreeNode $run2 $new2
    Assert-True ([string]$n2old.status -eq 'pruned' -and [string]$n2new.status -eq 'pending') 'T2 tree state: pruned old + pending replacement' ("old=$($n2old.status) new=$($n2new.status)")
    Assert-True ((Get-StubCreateCount) -gt $createsBefore2) 'T2 replacement pushed via session.create (fresh session)'
    $hasRedo2 = @((Read-LedgerLines $run2) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count -gt 0
    Assert-True (-not $hasRedo2) 'T2 no redo ledger entry on the fallback path'

    # ================= T3: -NoReuse escape forces the legacy path =================
    $arch3 = New-Archive 'ir-t3' '[{"title":"T3","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf3 = Write-TestPlan (Join-Path $Work 'ir-t3-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-PlanFile', $pf3)
    Assert-True ($r.json.success -eq $true) 'T3 promulgate ok' ($r.raw)
    $run3 = 'deliver-ir-t3'
    $b3 = Read-BridgeJson $run3
    $dev3 = [string]$b3.tasks.'1'.stages.DEV
    $r = Do-Deliver $run3 $dev3 'DEV' "$arch3/requirements/t1.md" $false 'sess-t3-live'
    Set-StubAlive @('sess-t3-live')
    $createsBefore3 = Get-StubCreateCount
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run3, '-NodeId', $dev3, '-NoReuse')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'T3 -NoReuse -> legacy path even with a live session' ($r.raw)
    Assert-True ([string]$r.json.data.fallback -eq 'no_reuse') 'T3 fallback reason surfaced (no_reuse)' ([string]$r.json.data.fallback)
    Assert-True ((Get-StubCreateCount) -gt $createsBefore3 -and @(Get-StubPromptsTo 'sess-t3-live').Count -eq 0) 'T3 replacement via session.create, no prompt to the live session'
    $hasRedo3 = @((Read-LedgerLines $run3) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count -gt 0
    Assert-True (-not $hasRedo3) 'T3 no redo ledger entry (-NoReuse)'

    # ================= T4: no_push gate (in-place keeps tree-side, skips delivery) =================
    $arch4 = New-Archive 'ir-t4' '[{"title":"T4","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf4 = Write-TestPlan (Join-Path $Work 'ir-t4-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch4 + '/task.json'), '-PlanFile', $pf4, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T4 no_push promulgate ok (zero backend from the start)' ($r.raw)
    $run4 = 'deliver-ir-t4'
    $b4 = Read-BridgeJson $run4
    $dev4 = [string]$b4.tasks.'1'.stages.DEV
    $r = Do-Deliver $run4 $dev4 'DEV' "$arch4/requirements/t1.md" $false 'sess-t4-live'
    Set-StubAlive @('sess-t4-live')
    $callsBefore4 = (Read-StubCalls).Count
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run4, '-NodeId', $dev4)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery-inplace' -and $r.json.data.no_push -eq $true) 'T4 no_push in-place: tree-side path taken, no_push flagged' ($r.raw)
    $n4 = Find-TreeNode $run4 $dev4
    Assert-True ([string]$n4.status -eq 'claimed') 'T4 node still migrated reported->claimed' ("status=$($n4.status)")
    $lastLedger4 = (Read-LedgerLines $run4)[-1] | ConvertFrom-Json
    Assert-True ([string]$lastLedger4.type -eq 'redo') 'T4 ledger redo entry present (tree-side actions land)'
    Assert-True ((Read-StubCalls).Count -eq $callsBefore4) 'T4 zero /api calls during the no_push reclaim (delivery skipped)'
    Assert-True (([string]$r.json.data.next_step) -match 'no_push') 'T4 next_step names the manual delivery path' ([string]$r.json.data.next_step)

    # ================= T5: AutoDispatch reuse (dead-claim repush -> alive roster sibling) =================
    $arch5 = New-Archive 'ir-t5' '[{"title":"T5","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf5 = Write-TestPlan (Join-Path $Work 'ir-t5-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5 + '/task.json'), '-PlanFile', $pf5)
    Assert-True ($r.json.success -eq $true) 'T5 promulgate ok' ($r.raw)
    $run5 = 'deliver-ir-t5'
    $b5 = Read-BridgeJson $run5
    $dev5 = [string]$b5.tasks.'1'.stages.DEV
    $push5Sid = $null
    foreach ($sid in (Get-RosterSessionIds $run5)) { if ($sid -like 'stub-s*') { $push5Sid = $sid } }
    Assert-True ($null -ne $push5Sid) 'T5 roster row for the initial push session'
    # claim as a DIFFERENT, dead session; keep the roster sibling alive
    Set-StubAlive @($push5Sid)
    $r = Do-Claim $run5 $dev5 'DEV' 'sess-t5-dead'
    Assert-True ($r.json.success -eq $true) 'T5 claim binds the dead sidecar session' ($r.raw)
    $createsBefore5 = Get-StubCreateCount
    $prompts5Before = @(Get-StubPromptsTo $push5Sid).Count
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run5, '-NodeId', $dev5)
    Assert-True ($r.json.success -eq $true) 'T5 dead-claim reclaim ok (steal + repush)' ($r.raw)
    $n5 = Find-TreeNode $run5 $dev5
    Assert-True ([string]$n5.status -eq 'claimed') 'T5 parked node stays claimed (repush target)' ("status=$($n5.status)")
    Assert-True ((Get-StubCreateCount) -eq $createsBefore5) 'T5 repush reused the ALIVE roster sibling (no session.create)'
    $prompts5 = @(Get-StubPromptsTo $push5Sid)
    Assert-True ($prompts5.Count -eq ($prompts5Before + 1)) 'T5 pointer delivered into the alive sibling session (exactly one new prompt)'
    $b5 = Read-BridgeJson $run5
    $att5 = $b5.pushes.$dev5.attempts | Select-Object -Last 1
    Assert-True ([string]$att5.reused_session_id -eq $push5Sid) 'T5 push attempt records reused_session_id' (($att5 | ConvertTo-Json -Compress))
    # -NoReuse variant on the same shape: dispatch must session.create instead
    $createsBefore5b = Get-StubCreateCount
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', $run5, '-NodeId', $dev5, '-NoReuse')
    Assert-True ($r.json.success -eq $true -and $null -eq $r.json.data.reused_session_id) 'T5b manual dispatch -NoReuse -> fresh session' ($r.raw)
    Assert-True ((Get-StubCreateCount) -gt $createsBefore5b) 'T5b dispatch -NoReuse used session.create'

    # ================= T6: rollback never reuses (v1 boundary) =================
    $arch6 = New-Archive 'ir-t6' '[{"title":"T6","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $pf6 = Write-TestPlan (Join-Path $Work 'ir-t6-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6 + '/task.json'), '-PlanFile', $pf6)
    Assert-True ($r.json.success -eq $true) 'T6 promulgate ok' ($r.raw)
    $run6 = 'deliver-ir-t6'
    $b6 = Read-BridgeJson $run6
    $cto6 = [string]$b6.tasks.'1'.stages.CTO
    $cto6Sid = $null
    foreach ($sid in (Get-RosterSessionIds $run6)) { if ($sid -like 'stub-s*') { $cto6Sid = $sid } }
    Assert-True ($null -ne $cto6Sid -and $cto6 -ne '') 'T6 CTO head pushed (roster row exists)' ("cto=$cto6 sid=$cto6Sid")
    Set-StubAlive @($cto6Sid)
    $r = Do-Deliver $run6 $cto6 'CTO' "$arch6/requirements/t1.md" $true 'sess-t6-cto'
    Set-StubAlive @($cto6Sid, 'sess-t6-cto')
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run6, '-NodeId', $cto6)
    Assert-True ($r.json.success -eq $true) 'T6 CTO settle ok (grafts + pushes the DEV node)' ($r.raw)
    $b6 = Read-BridgeJson $run6
    $dev6 = [string]$b6.tasks.'1'.stages.DEV
    Assert-True ($dev6 -ne '') 'T6 DEV node grafted after CTO settle' ($dev6)
    $r = Do-Deliver $run6 $dev6 'DEV' "$arch6/requirements/t1.md" $false 'sess-t6-dev'
    Set-StubAlive @($cto6Sid, 'sess-t6-cto')   # sess-t6-dev stays dead-side; irrelevant here
    $createsBefore6 = Get-StubCreateCount
    $prompts6Before = @(Get-StubPromptsTo $cto6Sid).Count
    $r = Invoke-Bridge @('-Command', 'rollback', '-RunId', $run6, '-NodeId', $dev6, '-To', 'CTO', '-Phase', 'DESIGN', '-Reason', 't6 rollback boundary check')
    Assert-True ($r.json.success -eq $true) 'T6 rollback ok' ($r.raw)
    Assert-True ((Get-StubCreateCount) -gt $createsBefore6) 'T6 rebuilt CTO node pushed via session.create (rollback never reuses)'
    Assert-True (@(Get-StubPromptsTo $cto6Sid).Count -eq $prompts6Before) 'T6 no new prompt into the OLD CTO session after rollback'
    $b6 = Read-BridgeJson $run6
    $rebuilt6 = [string]$b6.tasks.'1'.stages.CTO
    $att6 = $b6.pushes.$rebuilt6.attempts | Select-Object -Last 1
    Assert-True ($null -eq $att6.reused_session_id) 'T6 rebuilt node push attempt carries no reused_session_id' (($att6 | ConvertTo-Json -Compress))

    # ================= T7: dead-endpoint fallback (unreachable probe -> unknown -> legacy) =================
    $arch7 = New-Archive 'ir-t7' '[{"title":"T7","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf7 = Write-TestPlan (Join-Path $Work 'ir-t7-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    # promulgate against the stub (head push works), then point DSH_WEB_URL at a dead port
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-PlanFile', $pf7)
    Assert-True ($r.json.success -eq $true) 'T7 promulgate ok' ($r.raw)
    $run7 = 'deliver-ir-t7'
    $b7 = Read-BridgeJson $run7
    $dev7 = [string]$b7.tasks.'1'.stages.DEV
    $r = Do-Deliver $run7 $dev7 'DEV' "$arch7/requirements/t1.md" $false 'sess-t7-live'
    $prevUrl = $env:DSH_WEB_URL
    $env:DSH_WEB_URL = 'http://127.0.0.1:1/'   # unreachable: probe degrades to unknown
    try {
        $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run7, '-NodeId', $dev7)
        Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'T7 unreachable probe -> legacy path' ($r.raw)
        Assert-True ([string]$r.json.data.fallback -eq 'unknown') 'T7 fallback reason surfaced (unknown)' ([string]$r.json.data.fallback)
        $hasRedo7 = @((Read-LedgerLines $run7) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count -gt 0
        Assert-True (-not $hasRedo7) 'T7 no redo ledger entry'
        $failed7 = @($r.json.data.auto_push.failed)
        Assert-True ($failed7.Count -gt 0 -and [string]$failed7[0].retry_class -eq 'session-create') 'T7 replacement push failed session-create class (unreachable backend, no in-place, no window)' ($r.raw)
    }
    finally { $env:DSH_WEB_URL = $prevUrl }

    # T7b: pure CLI shell (DSH_WEB_URL absent) + no_push: same legacy shape, zero backend
    $arch7b = New-Archive 'ir-t7b' '[{"title":"T7b","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf7b = Write-TestPlan (Join-Path $Work 'ir-t7b-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $prevUrl = $env:DSH_WEB_URL
    Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
    try {
        $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7b + '/task.json'), '-PlanFile', $pf7b, '-NoPush')
        Assert-True ($r.json.success -eq $true) 'T7b CLI-shell no_push promulgate ok' ($r.raw)
        $run7b = 'deliver-ir-t7b'
        $b7b = Read-BridgeJson $run7b
        $dev7b = [string]$b7b.tasks.'1'.stages.DEV
        $r = Do-Deliver $run7b $dev7b 'DEV' "$arch7b/requirements/t1.md" $false
        $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run7b, '-NodeId', $dev7b)
        Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery' -and [string]$r.json.data.fallback -eq 'unknown') 'T7b CLI shell -> unknown -> legacy path (byte-shape)' ($r.raw)
    }
    finally { $env:DSH_WEB_URL = $prevUrl }

    # ================= T8: in-place prompt failure + manual dispatch recovery =================
    $arch8 = New-Archive 'ir-t8' '[{"title":"T8","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf8 = Write-TestPlan (Join-Path $Work 'ir-t8-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch8 + '/task.json'), '-PlanFile', $pf8)
    Assert-True ($r.json.success -eq $true) 'T8 promulgate ok' ($r.raw)
    $run8 = 'deliver-ir-t8'
    $b8 = Read-BridgeJson $run8
    $dev8 = [string]$b8.tasks.'1'.stages.DEV
    $r = Do-Deliver $run8 $dev8 'DEV' "$arch8/requirements/t1.md" $false 'sess-t8-live'
    Set-StubAlive @('sess-t8-live')
    Add-StubFail 'sess-t8-live'    # prompt injection failure
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run8, '-NodeId', $dev8)
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'RECLAIM_INPLACE_PROMPT_FAILED') 'T8 prompt failure -> RECLAIM_INPLACE_PROMPT_FAILED' ($r.raw)
    $n8 = Find-TreeNode $run8 $dev8
    Assert-True ([string]$n8.status -eq 'reported') 'T8 zero state residue: node stays reported' ("status=$($n8.status)")
    $hasRedo8 = @((Read-LedgerLines $run8) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count -gt 0
    Assert-True (-not $hasRedo8) 'T8 no redo ledger entry (migration never ran)'
    Clear-StubFail
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', $run8, '-NodeId', $dev8)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.reused_session_id -eq 'sess-t8-live') 'T8 manual dispatch re-prompts the sidecar session (reuse resolution)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run8, '-NodeId', $dev8)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery-inplace') 'T8 reclaim retry lands the redo (idempotent continue)' ($r.raw)

    # ================= T9: start-role SESSION_REUSE_UNSUPPORTED (non-dsh backend) =================
    $prevUrl = $env:DSH_WEB_URL
    Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $StartPs1 -Role DEV -TaskId 1 -ExistingSessionId sess-x 2>&1 | Out-String
        $code9 = $LASTEXITCODE
        Assert-True ($code9 -ne 0 -and $out -match 'SESSION_REUSE_UNSUPPORTED') 'T9 non-dsh backend rejects -ExistingSessionId' ($out)
    }
    finally { $env:DSH_WEB_URL = $prevUrl }

    # ================= goal-tree redo guard rails (direct CLI) =================
    # G1/G2 run against T4's node (claimed by DEV after the no_push in-place redo);
    # G3 runs against T1's node (done after the round-trip settle).
    $r = Invoke-Tree @('-Command', 'redo', '-RunId', $run4, '-NodeId', $dev4, '-Worker', 'DEV', '-FailureRef', 'guard: idempotent rerun')
    Assert-True ($r.json.success -eq $true -and $r.json.data.idempotent_noop -eq $true) 'G1 redo idempotent on an already-claimed same-worker node' ($r.raw)
    $r = Invoke-Tree @('-Command', 'redo', '-RunId', $run4, '-NodeId', $dev4, '-Worker', 'QA', '-FailureRef', 'guard: mismatch')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REDO_OWNER_MISMATCH') 'G2 redo rejects a different worker' ($r.raw)
    $r = Invoke-Tree @('-Command', 'redo', '-RunId', $run1, '-NodeId', $devNode, '-Worker', 'DEV', '-FailureRef', 'guard: terminal')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REDO_REQUIRES_REPORTED') 'G3 redo rejects terminal (done) nodes' ($r.raw)
    $r = Invoke-Tree @('-Command', 'redo', '-RunId', $run1, '-NodeId', $devNode, '-Worker', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'MISSING_FAILURE_REF') 'G4 redo without -FailureRef rejected (audit precondition)' ($r.raw)
    # ledger stats skip type=redo rows (goal-tree status still parses fine)
    $r = Invoke-Tree @('-Command', 'status', '-RunId', $run4)
    Assert-True ($r.json.success -eq $true) 'G5 goal-tree status parses with redo rows present (stats guard)' ($r.raw)
}
finally {
    Pop-Location
    Stop-Stub
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("inplace-redo suite: {0} passed, {1} failed" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Output ("FAIL  {0}   {1}" -f $_.name, $_.detail) }
    exit 1
}
if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
exit 0

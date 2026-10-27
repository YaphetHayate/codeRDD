# dispatch-reuse-from-node tests — 通用树 dispatch 会话复用（规划者显式指定）
# Covers the dispatch-reuse-from-node design acceptance:
#   T1  happy path cross-node: pending QA-verify node + -ReuseFrom <done QA-design
#       node> -> probe alive -> start-role -ExistingSessionId (session.prompt into
#       the ORIGINAL session, zero session.create), dispatch-log row carries
#       reused_from_node + reused_session_id, response data.reuse populated
#   T2  dead session -> REUSE_SESSION_DEAD, node stays pending, no prompt fired
#   T3  source node without a claims sidecar -> REUSE_SOURCE_NO_SESSION; unknown
#       source node -> REUSE_SOURCE_NOT_FOUND
#   T4  no flag -> legacy byte-shape: session.create path, dispatch-log row has
#       NO reuse fields (regression anchor)
#   T5  DryRun + -ReuseFrom -> preview (dry_run + reuse resolved), zero side
#       effects (no dispatch-log row, no /api call)
#   T6  non-dsh shell (DSH_WEB_URL absent) -> probe unknown -> REUSE_SESSION_DEAD
#       with the not-a-dsh-shell reason (unknown is never a reuse verdict)
#   T7  run-scoped reentry budget: manifest reuse_max=2 -> two reuse deliveries
#       tick, third refuses REUSE_REENTRY_EXCEEDED; budget -SetReuseMax raise
#       (verdict gate + raise-only) unblocks
#   T8  self-reuse via reset: leaf claim (sidecar bound) -> reset (pending,
#       sidecar KEPT) -> dispatch -ReuseFrom <self> re-prompts the same session
#   T9  status hint layer: pending node with same-role done dep + live sidecar
#       session -> reuse_hints entry with copyable suggestion; probe cap 3 per
#       status call (4 distinct candidate sessions -> exactly 3 probes);
#       non-dsh -> hints silently empty (fail-soft)
#   T10 role-mismatch reuse: succeeds with reuse.role_match=false and a NOTE in
#       next_step (advisory, never a refusal)
# Fixture form (mirror test-inplace-redo): LOCAL STUB DSH_WEB_URL endpoint
# (fake session-keyed liveness + /api envelope receiver, zero real backend),
# throwaway git repo, production interpreters. Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('dispatch-reuse-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Invoke-Tree { param([string[]]$A) Invoke-Ps1 $TreePs1 $A }
function Invoke-Leaf { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Read-DispatchLogLines { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/dispatch-log.jsonl')
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne '' })
}
function Set-NodeStatus { param([string]$RunId, [string]$NodeId, [string]$Status)
    # fixture-level tree edit (LOCAL STUB style): dispatch's dep gate needs the
    # design node done; dragging the full claim/report/settle callback contract
    # in would blur a suite that tests the dispatch plane only.
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    $tree = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($n in @($tree.nodes)) {
        if ([string]$n.id -eq $NodeId) { $n.status = $Status; $n.settled_at = '2026-10-01T00:00:00Z' }
    }
    Write-Utf8NoBom $p ($tree | ConvertTo-Json -Depth 10)
}
function Set-ClaimSidecar { param([string]$RunId, [string]$NodeId, [string]$SessionId)
    $dir = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/claims')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $claim = [ordered]@{ node = $NodeId; worker = 'qa'; claimed_at = '2026-10-01T00:00:00Z'; dsh_session_id = $SessionId }
    Write-Utf8NoBom (Join-Path $dir "$NodeId.json") ($claim | ConvertTo-Json -Depth 4)
}
function Remove-ClaimSidecar { param([string]$RunId, [string]$NodeId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/claims/' + $NodeId + '.json')
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
function Set-ManifestReuseMax { param([string]$RunId, [int]$Max)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/manifest.json')
    $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $m.budget | Add-Member -NotePropertyName reuse_max -NotePropertyValue $Max -Force
    Write-Utf8NoBom $p ($m | ConvertTo-Json -Depth 8)
}

# --- stub control files ---
$StubAlive  = Join-Path $Work 'stub-alive.txt'     # alive session ids (liveness probe truth)
$StubCalls  = Join-Path $Work 'stub-calls.jsonl'   # every /api call + liveness probe

function Set-StubAlive { param([string[]]$Ids)
    Write-Utf8NoBom $StubAlive ((@($Ids) | Where-Object { $_ }) -join "`n")
}
function Read-StubCalls {
    if (-not (Test-Path -LiteralPath $StubCalls)) { return @() }
    $rows = @()
    foreach ($l in @([System.IO.File]::ReadAllLines($StubCalls) | Where-Object { $_.Trim() -ne '' })) {
        try { $rows += ,($l | ConvertFrom-Json) } catch { }
    }
    return $rows
}
function Get-StubRowCount { @(Read-StubCalls).Count }
function Select-StubRowsAfter { param([int]$AfterRows)
    $rows = @(Read-StubCalls)
    if ($AfterRows -gt 0) { $rows = @($rows | Select-Object -Skip $AfterRows) }
    return @($rows)
}
function Get-StubCreateCount { param([int]$AfterRows = 0)
    @(Select-StubRowsAfter $AfterRows | Where-Object { $_.method -eq 'session.create' }).Count
}
function Get-StubPromptsTo { param([string]$SessionId, [int]$AfterRows = 0)
    @(Select-StubRowsAfter $AfterRows | Where-Object { $_.method -eq 'session.prompt' -and $_.payload -and [string]$_.payload.sessionId -eq $SessionId })
}
function Get-StubLivenessProbeCount { param([int]$AfterRows = 0)
    @(Select-StubRowsAfter $AfterRows | Where-Object { $_.method -eq 'liveness.probe' }).Count
}

# --- stub endpoint: fake plugin liveness + fake /api envelope receiver ---
# Same byte-level HTTP shape as test-inplace-redo (harness sandbox blocks
# HttpListener/http.sys). Liveness truth = stub-alive.txt; /api session.create
# assigns stub-s<N> ids; every call is logged (liveness probes included).
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
    function Log-Call { param($Root, $Method, $Payload)
        $row = @{ at = (Get-Date).ToUniversalTime().ToString('o'); method = $Method }
        if ($null -ne $Payload) { $row['payload'] = $Payload }
        [System.IO.File]::AppendAllText((Join-Path $Root 'stub-calls.jsonl'), ((ConvertTo-Json $row -Depth 10 -Compress) + "`n"), $utf8NoBom)
    }
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 10000
            $stream.WriteTimeout = 10000
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
            $jsonOut = $null
            if ($methodVerb -eq 'GET' -and $pathOnly -eq '/rdd-goal-tree/liveness') {
                $sid = ''
                if ($q.ContainsKey('session_id')) { $sid = [string]$q['session_id'] }
                Log-Call $Root 'liveness.probe' @{ session_id = $sid }
                $live = if ($sid -and $alive.ContainsKey($sid)) { 'alive' } else { 'dead' }
                $jsonOut = @{ session_id = $sid; liveness = $live; reason = 'stub registry (session-keyed probe)' } | ConvertTo-Json -Compress
            }
            elseif ($methodVerb -eq 'POST' -and $pathOnly.StartsWith('/api/')) {
                $method = $pathOnly.Substring(5)
                $params = if ($bodyJson -and $bodyJson.payload) { $bodyJson.payload } else { $bodyJson }
                $value = @{}
                switch ($method) {
                    'agentPreset.list' { $value = @{ presets = @(@{ id = 'rdd-pm' }, @{ id = 'rdd-cto' }, @{ id = 'rdd-ux' }, @{ id = 'rdd-dev' }, @{ id = 'rdd-qa' }, @{ id = 'rdd-eval' }, @{ id = 'rdd-pse' }, @{ id = 'rdd-planner' }) } }
                    'workspace.create' { $value = @{ workspace = @{ workspaceId = 'stub-ws-1' } } }
                    'session.create'   { $script:sidCounter++; $value = @{ sessionId = "stub-s$($script:sidCounter)" } }
                    'session.prompt'   { $value = @{} }
                    default            { $value = @{} }
                }
                Log-Call $Root $method $params
                $jsonOut = @{ result = @{ ok = $true; value = $value } } | ConvertTo-Json -Depth 10 -Compress
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

New-Item -ItemType Directory -Path $Work -Force | Out-Null
Set-StubAlive @()
$null = git init -q $Work 2>$null

$env:DSH_WEB_URL = "http://127.0.0.1:$port"
$stubUp = $false
foreach ($try in 1..40) {
    try { $null = [System.Net.WebRequest]::Create("http://127.0.0.1:$port/rdd-goal-tree/liveness?session_id=ping").GetResponse(); $stubUp = $true; break }
    catch { Start-Sleep -Milliseconds 250 }
}

# --- run factory: start + round + graft qa-design/dev/qa-verify(s) + fixture state ---
# Node map (legacy shape): n1 root, n2 qa design, n3 dev, n4.. verify (deps n2).
function New-DispatchRun {
    param([string]$RunId, [string]$SourceSession = 'sess-qa-design', [int]$VerifyNodes = 1)
    $r = Invoke-Tree @('-Command', 'start', '-RunId', $RunId, '-Goal', "dispatch-reuse 测试目标 $RunId", '-RefRoots', '.', '-NodeWidth', '12', '-MaxNodes', '30')
    if ($r.json.success -ne $true) { throw "start failed for ${RunId}: $($r.raw)" }
    $null = Invoke-Tree @('-Command', 'round-start', '-RunId', $RunId)
    $tasks = @(
        @{ title = "QA 用例设计 $RunId"; task = "设计测试用例（$RunId）"; role = 'qa' },
        @{ title = "DEV 实现 $RunId"; task = "编码实现（$RunId）"; role = 'dev' }
    )
    for ($i = 1; $i -le $VerifyNodes; $i++) {
        $tasks += @{ title = "QA 验收 ${RunId}-$i"; task = "执行验收（$RunId 第 $i 个验收节点）"; role = 'qa'; depends_on = @('n2') }
    }
    $tf = Join-Path $Work ("$RunId-tasks.json")
    Write-Utf8NoBom $tf ($tasks | ConvertTo-Json -Depth 5)
    $r = Invoke-Tree @('-Command', 'graft', '-RunId', $RunId, '-Parent', 'n1', '-TasksFile', $tf)
    if ($r.json.success -ne $true) { throw "graft failed for ${RunId}: $($r.raw)" }
    # fixture state: design node done + sidecar-bound session (the test-case author)
    Set-NodeStatus -RunId $RunId -NodeId 'n2' -Status 'done'
    if ($SourceSession) { Set-ClaimSidecar -RunId $RunId -NodeId 'n2' -SessionId $SourceSession }
    return @{ run_id = $RunId }
}

Push-Location $Work
try {
    Assert-True $stubUp 'T0 stub endpoint up (liveness + /api receiver)' "port $port"

    # ================= T1: happy path cross-node reuse =================
    $null = New-DispatchRun -RunId 'dr-t1'
    Set-StubAlive @('sess-qa-design')
    $rowsBefore1 = Get-StubRowCount
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t1', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $true) 'T1 dispatch -ReuseFrom succeeds' ($r.raw)
    Assert-True ([string]$r.json.data.reuse.session_id -eq 'sess-qa-design' -and [string]$r.json.data.reuse.from_node -eq 'n2' -and [string]$r.json.data.reuse.liveness -eq 'alive') 'T1 response reuse block (session/from/liveness)' ($r.json.data.reuse | ConvertTo-Json -Compress)
    Assert-True ($r.json.data.reuse.role_match -eq $true) 'T1 role_match true (qa -> qa)' ''
    Assert-True ((Get-StubCreateCount $rowsBefore1) -eq 0) 'T1 zero new session.create (in-place = no cold start)' ("creates=$(Get-StubCreateCount $rowsBefore1)")
    $prompts = @(Get-StubPromptsTo 'sess-qa-design' $rowsBefore1)
    Assert-True ($prompts.Count -ge 1) 'T1 pointer prompted into the ORIGINAL session' ''
    Assert-True (([string]$r.json.data.next_step) -match 'existing session sess-qa-design') 'T1 next_step names the reused session' ([string]$r.json.data.next_step)
    $logLine = @((Read-DispatchLogLines 'dr-t1'))[-1] | ConvertFrom-Json
    Assert-True ([string]$logLine.node -eq 'n4' -and [string]$logLine.reused_from_node -eq 'n2' -and [string]$logLine.reused_session_id -eq 'sess-qa-design') 'T1 dispatch-log row carries reuse fields' (@(Read-DispatchLogLines 'dr-t1')[-1])

    # ================= T2: dead session refuses =================
    $null = New-DispatchRun -RunId 'dr-t2'
    Set-StubAlive @()   # sess-qa-design NOT alive
    $rowsBefore2 = Get-StubRowCount
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t2', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REUSE_SESSION_DEAD') 'T2 dead session -> REUSE_SESSION_DEAD' ($r.raw)
    Assert-True (([string]$r.json.error.message) -match 'probe: dead') 'T2 error carries the probe verdict' ([string]$r.json.error.message)
    $n4 = Find-TreeNode 'dr-t2' 'n4'
    Assert-True ([string]$n4.status -eq 'pending') 'T2 node stays pending (zero half-write)' ([string]$n4.status)
    Assert-True ((@(Get-StubPromptsTo 'sess-qa-design' $rowsBefore2).Count) -eq 0 -and (Get-StubCreateCount $rowsBefore2) -eq 0) 'T2 no prompt and no session.create fired' ''

    # ================= T3: source without sidecar / unknown source =================
    $null = New-DispatchRun -RunId 'dr-t3' -SourceSession $null
    Set-StubAlive @('sess-qa-design')
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t3', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REUSE_SOURCE_NO_SESSION') 'T3 sidecar-less source -> REUSE_SOURCE_NO_SESSION' ($r.raw)
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t3', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n99')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REUSE_SOURCE_NOT_FOUND') 'T3 unknown source node -> REUSE_SOURCE_NOT_FOUND' ($r.raw)

    # ================= T4: no flag = legacy byte-shape =================
    $null = New-DispatchRun -RunId 'dr-t4' -SourceSession $null
    $rowsBefore4 = Get-StubRowCount
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t4', '-NodeId', 'n4', '-Role', 'QA')
    Assert-True ($r.json.success -eq $true) 'T4 legacy dispatch (no flag) succeeds' ($r.raw)
    Assert-True ($null -eq $r.json.data.reuse) 'T4 response reuse block absent' ($r.json.data | ConvertTo-Json -Depth 4 -Compress)
    Assert-True ((Get-StubCreateCount $rowsBefore4) -ge 1) 'T4 legacy path pulled a FRESH session (session.create ran)' ''
    $logLine4 = @((Read-DispatchLogLines 'dr-t4'))[-1] | ConvertFrom-Json
    Assert-True ($null -eq $logLine4.reused_session_id -and $null -eq $logLine4.reused_from_node) 'T4 dispatch-log row has NO reuse fields' (@(Read-DispatchLogLines 'dr-t4')[-1])

    # ================= T5: DryRun preview, zero side effects =================
    $null = New-DispatchRun -RunId 'dr-t5'
    Set-StubAlive @('sess-qa-design')
    $logBefore5 = (Read-DispatchLogLines 'dr-t5').Count
    $rowsBefore5 = Get-StubRowCount
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t5', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n2', '-DryRun')
    Assert-True ($r.json.success -eq $true -and $r.json.data.dry_run -eq $true) 'T5 DryRun succeeds with dry_run flag' ($r.raw)
    Assert-True ([string]$r.json.data.reuse.session_id -eq 'sess-qa-design' -and [string]$r.json.data.reuse.liveness -eq 'alive') 'T5 DryRun resolves + probes the reuse session' ''
    Assert-True (([string]$r.json.data.start_role.output) -match 'DRYRUN') 'T5 start-role rendered the dry-run carrier' ([string]$r.json.data.start_role.output)
    Assert-True ((Read-DispatchLogLines 'dr-t5').Count -eq $logBefore5) 'T5 no dispatch-log row on dry run' ''
    Assert-True ((Get-StubCreateCount $rowsBefore5) -eq 0 -and @(Get-StubPromptsTo 'sess-qa-design' $rowsBefore5).Count -eq 0) 'T5 zero delivery /api calls (no prompt, no create; the liveness probe itself is expected)' ''

    # ================= T6: non-dsh shell refuses =================
    $null = New-DispatchRun -RunId 'dr-t6'
    Set-StubAlive @('sess-qa-design')
    Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
    try {
        $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t6', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n2')
    }
    finally {
        $env:DSH_WEB_URL = "http://127.0.0.1:$port"
    }
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REUSE_SESSION_DEAD') 'T6 non-dsh shell -> probe unknown -> REUSE_SESSION_DEAD' ($r.raw)
    Assert-True (([string]$r.json.error.message) -match 'not a dsh shell') 'T6 error carries the not-a-dsh-shell reason' ([string]$r.json.error.message)

    # ================= T7: run-scoped reentry budget =================
    $null = New-DispatchRun -RunId 'dr-t7' -VerifyNodes 3   # n4 n5 n6 all deps n2
    Set-StubAlive @('sess-qa-design')
    Set-ManifestReuseMax -RunId 'dr-t7' -Max 2
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t7', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $true) 'T7 reuse delivery 1/2 lands' ($r.raw)
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t7', '-NodeId', 'n5', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $true) 'T7 reuse delivery 2/2 lands' ($r.raw)
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t7', '-NodeId', 'n6', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'REUSE_REENTRY_EXCEEDED') 'T7 third reuse -> REUSE_REENTRY_EXCEEDED' ($r.raw)
    Assert-True (([string]$r.json.error.message) -match 'budget -RunId dr-t7 -SetReuseMax') 'T7 refusal names the copyable raise command' ([string]$r.json.error.message)
    # verdict gate + raise-only
    $r = Invoke-Tree @('-Command', 'budget', '-RunId', 'dr-t7', '-SetReuseMax', '3')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'BUDGET_VERDICT_MISSING') 'T7 budget without -UserVerdict rejected' ($r.raw)
    $r = Invoke-Tree @('-Command', 'budget', '-RunId', 'dr-t7', '-SetReuseMax', '2', '-UserVerdict', 'test raise')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'BUDGET_RAISE_ONLY') 'T7 budget raise-only (2 <= 2 rejected)' ($r.raw)
    $r = Invoke-Tree @('-Command', 'budget', '-RunId', 'dr-t7', '-SetReuseMax', '3', '-UserVerdict', 'test raise reuse ceiling')
    Assert-True ($r.json.success -eq $true) 'T7 budget raise to 3 lands' ($r.raw)
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t7', '-NodeId', 'n6', '-Role', 'QA', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $true) 'T7 reuse delivery 3/3 lands after raise' ($r.raw)

    # ================= T8: self-reuse via reset (sidecar preserved) =================
    $null = New-DispatchRun -RunId 'dr-t8'
    Set-StubAlive @('sess-self-claim')
    # real leaf claim binds the node's sidecar to DSH_SESSION_ID
    $prevSid = $env:DSH_SESSION_ID
    $env:DSH_SESSION_ID = 'sess-self-claim'
    try {
        $r = Invoke-Leaf @('-Command', 'claim', '-RunId', 'dr-t8', '-NodeId', 'n4', '-Worker', 'qa')
    }
    finally {
        if ($prevSid) { $env:DSH_SESSION_ID = $prevSid } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    }
    Assert-True ($r.json.success -eq $true) 'T8 leaf claim ok (sidecar bound to sess-self-claim)' ($r.raw)
    $r = Invoke-Tree @('-Command', 'reset', '-RunId', 'dr-t8', '-NodeId', 'n4', '-Reason', 'dispatch-reuse self-reuse test')
    Assert-True ($r.json.success -eq $true) 'T8 reset returns the node to pending' ($r.raw)
    $claimAfterReset = Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/dr-t8/state/claims/n4.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$claimAfterReset.dsh_session_id -eq 'sess-self-claim') 'T8 sidecar KEPT through reset (binding truth preserved)' ($claimAfterReset | ConvertTo-Json -Compress)
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t8', '-NodeId', 'n4', '-Role', 'QA', '-ReuseFrom', 'n4')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.reuse.session_id -eq 'sess-self-claim') 'T8 self-reuse re-prompts the node own bound session' ($r.raw)
    Assert-True (@(Get-StubPromptsTo 'sess-self-claim').Count -ge 1) 'T8 pointer prompted into sess-self-claim' ''

    # ================= T9: status hint layer =================
    $null = New-DispatchRun -RunId 'dr-t9'
    Set-StubAlive @('sess-qa-design')
    $r = Invoke-Tree @('-Command', 'status', '-RunId', 'dr-t9')
    Assert-True ($r.json.success -eq $true) 'T9 status succeeds' ($r.raw)
    $hints = @($r.json.data.reuse_hints)
    Assert-True ($hints.Count -eq 1 -and [string]$hints[0].node -eq 'n4' -and [string]$hints[0].source_node -eq 'n2' -and [string]$hints[0].session_id -eq 'sess-qa-design') 'T9 hint names node/source/session' ($hints | ConvertTo-Json -Compress)
    Assert-True (([string]$hints[0].suggestion) -match '-ReuseFrom n2') 'T9 hint suggestion is copyable' ([string]$hints[0].suggestion)

    # probe cap: 4 candidates with DISTINCT sessions -> exactly 3 probes / 3 hints
    $null = New-DispatchRun -RunId 'dr-t9b' -SourceSession $null   # base n2 sidecarless: not a candidate
    # extra graft: designs n5-n8 (role qa) + verifies n9-n12 (deps n5..n8)
    $tasksB = @()
    foreach ($i in 5..8) { $tasksB += @{ title = "QA 设计9b-$i"; task = "设计（9b-$i）"; role = 'qa' } }
    foreach ($i in 5..8) { $tasksB += @{ title = "QA 验收9b-$i"; task = "验收（9b-$i）"; role = 'qa'; depends_on = @("n$i") } }
    $tfB = Join-Path $Work 'dr-t9b-extra.json'
    Write-Utf8NoBom $tfB ($tasksB | ConvertTo-Json -Depth 5)
    $r = Invoke-Tree @('-Command', 'graft', '-RunId', 'dr-t9b', '-Parent', 'n1', '-TasksFile', $tfB)
    if ($r.json.success -ne $true) { throw "graft failed for dr-t9b: $($r.raw)" }
    foreach ($i in 5..8) {
        Set-NodeStatus -RunId 'dr-t9b' -NodeId "n$i" -Status 'done'
        Set-ClaimSidecar -RunId 'dr-t9b' -NodeId "n$i" -SessionId "sess-q$i"
    }
    Set-StubAlive @('sess-q5', 'sess-q6', 'sess-q7', 'sess-q8')
    $probeBefore = Get-StubLivenessProbeCount
    $r = Invoke-Tree @('-Command', 'status', '-RunId', 'dr-t9b')
    $hintsB = @($r.json.data.reuse_hints)
    $probeAfter = Get-StubLivenessProbeCount
    Assert-True (($probeAfter - $probeBefore) -eq 3) 'T9 probe cap: 4 distinct candidate sessions -> exactly 3 probes' ("probes=$($probeAfter - $probeBefore)")
    Assert-True ($hintsB.Count -eq 3) 'T9 hints capped at 3' ("hints=$($hintsB.Count)")
    # fail-soft: non-dsh -> empty hints, status still fine
    Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
    try {
        $r = Invoke-Tree @('-Command', 'status', '-RunId', 'dr-t9b')
    }
    finally {
        $env:DSH_WEB_URL = "http://127.0.0.1:$port"
    }
    Assert-True ($r.json.success -eq $true -and @($r.json.data.reuse_hints).Count -eq 0) 'T9 non-dsh status -> hints silently empty' ($r.raw)

    # ================= T10: role-mismatch reuse warns, never refuses =================
    Set-StubAlive @('sess-qa-design')   # T9b narrowed the alive set; restore the dr-t9 source session
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'dr-t9', '-NodeId', 'n3', '-Role', 'DEV', '-ReuseFrom', 'n2')
    Assert-True ($r.json.success -eq $true -and $r.json.data.reuse.role_match -eq $false) 'T10 role-mismatch reuse succeeds with role_match=false' ($r.raw)
    Assert-True (([string]$r.json.data.next_step) -match 'NOTE: source node role differs') 'T10 next_step warns on role mismatch' ([string]$r.json.data.next_step)
}
finally {
    Pop-Location
    Stop-Stub
    Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue
    $passed = @($Results | Where-Object { $_.ok }).Count
    $failed = @($Results | Where-Object { -not $_.ok })
    foreach ($f in $failed) { Write-Output ("FAILED: {0} :: {1}" -f $f.name, $f.detail) }
    Write-Output ("dispatch-reuse suite: {0} passed, {1} failed" -f $passed, $failed.Count)
    if ($Work -and (Test-Path -LiteralPath $Work)) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

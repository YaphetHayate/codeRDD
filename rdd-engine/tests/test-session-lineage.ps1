# session-lineage-requirement-root tests — dsh 侧栏按需求嵌套
# Covers the requirement-rooted lineage policy in start-role.ps1's dsh branch:
#   T1  chain flatten: PM->CTO->UX->DEV handoffs from DIFFERENT sessions all
#       carry parentSessionId = the archive's recorded root (sess-pm), NOT the
#       per-hop calling session — one flat bundle, zero per-hop nesting
#   T2  -NoLineage opt-out: no parentSessionId key, registry untouched
#   T3  NoArchive intake (unanchored): legacy parent = current session, no
#       registry record even with resolvable archives on disk
#   T4  Handoff-annotated archive form: anchored (mirrors Build-PointerMessage)
#       -> parent = registry root
#   T5  corrupt registry: warning + legacy parent (current session), recovery
#       write rebuilds a valid map; handoff never blocked
#   T6  PLANNER takeover (archive-anchored): parent = registry root
#   T7  fresh archive: (a) no DSH_SESSION_ID -> no parent, no record;
#       (b) DryRun -> shows would-be registration, ZERO registry write;
#       (c) real run with env -> records root, parent = root
#   T8  -GoalTreeWorker (unanchored): legacy parent = current session
#   T9  DryRun on a recorded archive: previews the recorded root, registry
#       byte-identical before/after
# Fixture form (same family as test-inplace-redo): LOCAL STUB /api endpoint
# (raw-TCP HTTP, zero real backend) + throwaway git repo. Exit 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'
$Work      = Join-Path $env:TEMP ('session-lineage-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    return @{ exit = $code; raw = $out }
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# --- stub /api envelope receiver ---
$port = 0
$tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
$tcp.Start(); $port = ($tcp.LocalEndpoint).Port; $tcp.Stop()

$StubCalls = Join-Path $Work 'stub-calls.jsonl'
$stubJob = Start-Job -ScriptBlock {
    param($Root, $Port)
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $sidCounter = 0
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
            $jsonOut = $null
            if ($reqParts[0] -eq 'POST' -and $rawPath.StartsWith('/api/')) {
                $method = $rawPath.Substring(5)
                $params = if ($bodyJson -and $bodyJson.payload) { $bodyJson.payload } else { $bodyJson }
                $value = @{}
                switch ($method) {
                    'agentPreset.list' { $value = @{ presets = @(@{ id = 'rdd-pm' }, @{ id = 'rdd-cto' }, @{ id = 'rdd-ux' }, @{ id = 'rdd-dev' }, @{ id = 'rdd-qa' }, @{ id = 'rdd-eval' }, @{ id = 'rdd-pse' }, @{ id = 'rdd-planner' }) } }
                    'workspace.create' { $value = @{ workspace = @{ workspaceId = 'stub-ws-1' } } }
                    'session.create'   { $script:sidCounter++; $value = @{ sessionId = "stub-s$($script:sidCounter)" } }
                    default            { $value = @{} }
                }
                $extra = $null
                if ($method -eq 'session.create') { $extra = @{ assigned_sid = $value['sessionId'] } }
                Log-Call $Root $method $params $extra
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

function Read-StubCalls {
    if (-not (Test-Path -LiteralPath $StubCalls)) { return @() }
    $rows = @()
    foreach ($l in @([System.IO.File]::ReadAllLines($StubCalls) | Where-Object { $_.Trim() -ne '' })) {
        try { $rows += ,($l | ConvertFrom-Json) } catch { }
    }
    return $rows
}
function Get-CreateCalls { @(Read-StubCalls | Where-Object { $_.method -eq 'session.create' }) }

function Read-Registry {
    $p = Join-Path $Work '.rdd/lineage.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @{ corrupt = $true } }
}
function Get-RegistryCount { param($Reg)
    if ($null -eq $Reg -or $Reg.PSObject.Properties['corrupt'] -or $null -eq $Reg.archives) { return 0 }
    return @($Reg.archives.PSObject.Properties).Count
}
function Get-RegistryRoot { param($Reg, [string]$Archive)
    if ($null -eq $Reg -or $null -eq $Reg.archives) { return '' }
    $e = $Reg.archives.PSObject.Properties[$Archive]
    if ($null -eq $e) { return '' }
    return [string]$e.Value.rootSessionId
}

function Do-StartRole { param([string[]]$A, [string]$AsSession = '')
    $prev = $env:DSH_SESSION_ID
    if ($AsSession -ne '') { $env:DSH_SESSION_ID = $AsSession }
    else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    try { return (Invoke-Ps1 $StartPs1 $A) }
    finally {
        if ($prev) { $env:DSH_SESSION_ID = $prev } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    }
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
# isolate from the harness's own dsh session (tests manage DSH_SESSION_ID per case)
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue
$env:DSH_WEB_URL = "http://127.0.0.1:$port"

$stubUp = $false
foreach ($try in 1..40) {
    try {
        $probe = @{ type = 'client-request'; rpcId = [guid]::NewGuid().ToString(); method = 'agentPreset.list'; payload = @{} } | ConvertTo-Json -Compress
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/api/agentPreset.list")
        $req.Method = 'POST'; $req.ContentType = 'application/json; charset=utf-8'; $req.Timeout = 3000
        $bb = [System.Text.Encoding]::UTF8.GetBytes($probe)
        $req.ContentLength = $bb.Length
        $s = $req.GetRequestStream(); $s.Write($bb, 0, $bb.Length); $s.Close()
        $resp = $req.GetResponse(); $resp.Close(); $stubUp = $true; break
    } catch { Start-Sleep -Milliseconds 250 }
}

function New-Archive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nsession-lineage 测试归档 $Name。`n"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir "requirements/t$i.md") "# $Name 需求 $i`n`n- **描述**：session-lineage 测试需求 $i`n- **验收标准**：见 overview.md`n"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Ps1 $FlowPs1 @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.exit -ne 0) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

Push-Location $Work
try {
    Assert-True $stubUp 'T0 stub /api endpoint up' "port $port"

    # ================= T1: chain flatten (requirement root beats per-hop parent) =================
    $arch1 = New-Archive 'sl-t1' '[{"title":"T1","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $tj1 = Join-Path $arch1 'task.json'
    $r = Do-StartRole @('-Role', 'CTO', '-TaskId', '1', '-TaskJson', $tj1) 'sess-pm'
    Assert-True ($r.exit -eq 0) 'T1 first hop (PM session -> CTO) succeeded' ($r.raw)
    $r = Do-StartRole @('-Role', 'UX', '-TaskId', '1', '-TaskJson', $tj1) 'sess-cto'
    Assert-True ($r.exit -eq 0) 'T1 second hop (CTO session -> UX) succeeded' ($r.raw)
    $r = Do-StartRole @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', $tj1) 'sess-ux'
    Assert-True ($r.exit -eq 0) 'T1 third hop (UX session -> DEV) succeeded' ($r.raw)
    $creates = Get-CreateCalls
    Assert-True ($creates.Count -eq 3) 'T1 exactly three session.create calls' ("count=$($creates.Count)")
    $parents = @($creates | ForEach-Object { [string]$_.payload.parentSessionId })
    Assert-True (@($parents | Where-Object { $_ -eq 'sess-pm' }).Count -eq 3) 'T1 ALL hops parent = requirement root sess-pm (no per-hop nesting)' (($parents -join ','))
    $reg = Read-Registry
    Assert-True ((Get-RegistryRoot $reg 'sl-t1') -eq 'sess-pm') 'T1 registry recorded root sess-pm on first hop' ((Get-RegistryRoot $reg 'sl-t1'))
    Assert-True ((Get-RegistryCount $reg) -eq 1) 'T1 registry holds exactly one record' ((Get-RegistryCount $reg))

    # ================= T2: -NoLineage opt-out =================
    $regBefore = Get-Content -LiteralPath (Join-Path $Work '.rdd/lineage.json') -Raw
    $r = Do-StartRole @('-Role', 'QA', '-TaskId', '1', '-TaskJson', $tj1, '-NoLineage') 'sess-cto'
    Assert-True ($r.exit -eq 0) 'T2 -NoLineage handoff succeeded' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ($null -eq $last.payload.PSObject.Properties['parentSessionId']) 'T2 no parentSessionId key (top-level row)' (($last.payload | ConvertTo-Json -Compress))
    Assert-True ($r.raw -match 'NoLineage 生效') 'T2 narration names the opt-out' ($r.raw)
    $regAfter = Get-Content -LiteralPath (Join-Path $Work '.rdd/lineage.json') -Raw
    Assert-True ($regBefore -eq $regAfter) 'T2 registry untouched'

    # ================= T3: NoArchive intake stays unanchored (legacy parent) =================
    $r = Do-StartRole @('-Role', 'PM', '-NoArchive', '-TaskBrief', 'intake probe') 'sess-planner'
    Assert-True ($r.exit -eq 0) 'T3 NoArchive intake succeeded' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ([string]$last.payload.parentSessionId -eq 'sess-planner') 'T3 intake parent = current session (legacy)' ([string]$last.payload.parentSessionId)
    Assert-True ((Get-RegistryCount (Read-Registry)) -eq 1) 'T3 no registry record for unanchored intake' ((Get-RegistryCount (Read-Registry)))

    # ================= T4: Handoff-annotated archive form is anchored (mirror rule) =================
    $hf = Join-Path $Work 'sl-direct-brief.md'
    Write-Utf8NoBom $hf "# direct brief`n"
    $r = Do-StartRole @('-Role', 'EVAL', '-Handoff', $hf, '-TaskJson', $tj1) 'sess-eval'
    Assert-True ($r.exit -eq 0) 'T4 handoff form succeeded' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ([string]$last.payload.parentSessionId -eq 'sess-pm') 'T4 handoff+archive parent = registry root (message-anchor mirror)' ([string]$last.payload.parentSessionId)
    Assert-True ((Get-RegistryCount (Read-Registry)) -eq 1) 'T4 registry unchanged'

    # ================= T5: corrupt registry -> warn + legacy parent + recovery write =================
    Write-Utf8NoBom (Join-Path $Work '.rdd/lineage.json') '{ this is not json'
    $r = Do-StartRole @('-Role', 'CTO', '-TaskId', '1', '-TaskJson', $tj1) 'sess-fix'
    Assert-True ($r.exit -eq 0) 'T5 corrupt registry never blocks the handoff' ($r.raw)
    Assert-True ($r.raw -match '血统注册表读取失败') 'T5 corruption surfaced as a warning' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ([string]$last.payload.parentSessionId -eq 'sess-fix') 'T5 degraded to legacy parent (current session)' ([string]$last.payload.parentSessionId)
    $reg = Read-Registry
    Assert-True ((Get-RegistryRoot $reg 'sl-t1') -eq 'sess-fix') 'T5 recovery write rebuilt a valid map (root sess-fix)' ((Get-RegistryRoot $reg 'sl-t1'))

    # ================= T6: PLANNER takeover is archive-anchored =================
    $r = Do-StartRole @('-Role', 'PLANNER', '-TaskJson', $tj1) 'sess-user'
    Assert-True ($r.exit -eq 0) 'T6 PLANNER takeover succeeded' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ([string]$last.payload.parentSessionId -eq 'sess-fix') 'T6 PLANNER session parent = registry root (flat bundle)' ([string]$last.payload.parentSessionId)

    # ================= T7: fresh archive — record timing =================
    $arch7 = New-Archive 'sl-t7' '[{"title":"T7","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $tj7 = Join-Path $arch7 'task.json'
    # (a) no DSH_SESSION_ID: no parent, no record
    $r = Do-StartRole @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', $tj7) ''
    Assert-True ($r.exit -eq 0) 'T7a env-less first hop succeeded' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ($null -eq $last.payload.PSObject.Properties['parentSessionId']) 'T7a env-less first hop carries no parent' (($last.payload | ConvertTo-Json -Compress))
    Assert-True ((Get-RegistryCount (Read-Registry)) -eq 1) 'T7a nothing recorded without an id' ((Get-RegistryCount (Read-Registry)))
    # (b) DryRun previews registration but writes nothing
    $r = Do-StartRole @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', $tj7, '-DryRun') 'sess-late'
    Assert-True ($r.exit -eq 0 -and $r.raw -match 'parentSessionId=sess-late' -and $r.raw -match '本次登记') 'T7b DryRun previews the would-be root' ($r.raw)
    Assert-True ((Get-RegistryCount (Read-Registry)) -eq 1) 'T7b DryRun left zero registry writes' ((Get-RegistryCount (Read-Registry)))
    # (c) real run records the root
    $r = Do-StartRole @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', $tj7) 'sess-late'
    Assert-True ($r.exit -eq 0) 'T7c real hop succeeded' ($r.raw)
    $reg = Read-Registry
    Assert-True ((Get-RegistryRoot $reg 'sl-t7') -eq 'sess-late') 'T7c root recorded for the fresh archive' ((Get-RegistryRoot $reg 'sl-t7'))
    Assert-True ((Get-RegistryCount $reg) -eq 2) 'T7c registry holds both archives' ((Get-RegistryCount $reg))

    # ================= T8: -GoalTreeWorker stays unanchored =================
    $r = Do-StartRole @('-Role', 'DEV', '-GoalTreeWorker', '-GoalTreeRun', 'sl-run', '-GoalTreeNode', 'n1', '-TaskBrief', 'node task') 'sess-gt'
    Assert-True ($r.exit -eq 0) 'T8 goal-tree worker succeeded' ($r.raw)
    $last = (Get-CreateCalls)[-1]
    Assert-True ([string]$last.payload.parentSessionId -eq 'sess-gt') 'T8 worker parent = current session (legacy)' ([string]$last.payload.parentSessionId)
    Assert-True ((Get-RegistryCount (Read-Registry)) -eq 2) 'T8 registry unchanged' ((Get-RegistryCount (Read-Registry)))

    # ================= T9: DryRun on a recorded archive is a pure preview =================
    $regBefore = Get-Content -LiteralPath (Join-Path $Work '.rdd/lineage.json') -Raw
    $r = Do-StartRole @('-Role', 'UX', '-TaskId', '1', '-TaskJson', $tj1, '-DryRun') 'sess-anyone'
    Assert-True ($r.exit -eq 0 -and $r.raw -match 'parentSessionId=sess-fix' -and $r.raw -match '已登记') 'T9 DryRun previews the recorded root regardless of caller' ($r.raw)
    Assert-True ((Get-Content -LiteralPath (Join-Path $Work '.rdd/lineage.json') -Raw) -eq $regBefore) 'T9 registry byte-identical after DryRun'
}
finally {
    Pop-Location
    Stop-Stub
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("session-lineage suite: {0} passed, {1} failed" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Output ("FAIL  {0}   {1}" -f $_.name, $_.detail) }
    exit 1
}
if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
exit 0

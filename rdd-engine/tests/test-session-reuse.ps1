# session-reuse tests — 单点流程打回后原会话重入（含重入上限）
# Covers requirements/session-reuse.md acceptance 1-6 (archive 2026-10-20-single-point-session-reuse):
#   T1  AC-1: QA reject 打回 → DEV 原会话自动收到重做指针（理由+claim 任务锚附录），零
#       session.create，重入计数 +1，路由写先行（task.json 先落库再送信），JSON delivery
#       复用态 + stderr 送信叙事；锚点在 create 成功时写入（reentries=0）
#   T2  AC-2: 二次正向交接投回第一轮原会话（auto gate 同 task×role 存活复用），QA 全程
#       只占一个会话
#   T3  AC-3: 重入达上限（默认 3）→ start-role 拒投（四出口可复制命令）+ reject 裁决态
#       capped（不投递、不硬停路由）；reentry 子命令契约：缺 -UserVerdict / 互斥 /
#       raise-only / not-capped / no-anchor 全部 fail-loud，豁免后复用恢复，裁决入
#       decisions.jsonl（kind=reentry_verdict、decider=user、D<n> 续号），status 只读
#       视图，.decisions.lock 零残留
#   T4  AC-4: 原会话死 / 无锚 / unknown → 流程不阻断：start-role 回退新建并重锚清零；
#       reject 回退 new-session / no-anchor（现状行为）；unknown 永不作复用判定（保守）
#   T5  AC-5: 非 dsh 后端无回归——CLI（无 DSH_WEB_URL）与 Plus（RDD_RUNTIME=app）reject
#       JSON 零 delivery 键（字节级现状形状）；CLI -ExistingSessionId 仍
#       SESSION_REUSE_UNSUPPORTED
#   T6  AC-6: planner 桥接 run 互不可见（R7）——携带 -GoalTreeRun 标记时 auto gate 跳过
#       （DryRun 无复用判定、边车不动）、真实派发不写边车；对照组（无标记）gate 正常
#       触发/锚点正常写入；bridge 源零 dot-source 引擎内库（不变量回归锚）
#   T7  纪律与健壮性：投递失败不计数 + pointer 类失败禁止自动新建（手动二选一指引）；
#       边车损坏 fail-soft 降级（无 bak → no-anchor 现状；有 bak → 按 bak 复用并续计）
# Fixture form (design reading note): the isolation fixture is a LOCAL STUB DSH_WEB_URL
# endpoint (fake liveness + /api envelope receiver, zero real backend). Runs the
# production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$Work      = Join-Path $env:TEMP ('session-reuse-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# Invoke-Flow: rdd-flow stdout is the machine JSON; the dsh delivery tail narrates
# to STDERR (production Write-DeliveryNotice contract). Capture the two streams
# SEPARATELY so JSON parsing stays exact and notice texts stay assertable.
function Invoke-Flow { param([string[]]$A)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path $Work ('flow-err-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FlowPs1) + $A
        $out = & powershell @all 2> $errFile | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    $errText = ''
    if ((Test-Path -LiteralPath $errFile -PathType Leaf) -and ((Get-Item -LiteralPath $errFile).Length -gt 0)) {
        $errText = [System.IO.File]::ReadAllText($errFile)
    }
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out; stderr = $errText }
}

# Invoke-Start: start-role prints human-readable narration on stdout.
function Invoke-Start { param([string[]]$A)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StartPs1) + $A
        $out = & powershell @all 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    return @{ exit = $code; raw = $out }
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# --- stub control files ---
$StubAlive   = Join-Path $Work 'stub-alive.txt'    # alive session ids (liveness probe truth)
$StubFail    = Join-Path $Work 'stub-fail.txt'     # session ids whose session.prompt MUST fail
$StubUnknown = Join-Path $Work 'stub-unknown.txt'  # session ids probing as liveness=unknown
$StubCalls   = Join-Path $Work 'stub-calls.jsonl'  # every /api call (method/payload/response)

function Set-StubAlive { param([string[]]$Ids)
    Write-Utf8NoBom $StubAlive ((@($Ids) | Where-Object { $_ }) -join "`n")
}
function Add-StubFail { param([string]$Id)
    $cur = @()
    if (Test-Path -LiteralPath $StubFail) { $cur = @([System.IO.File]::ReadAllLines($StubFail) | Where-Object { $_.Trim() -ne '' }) }
    $cur += $Id
    Write-Utf8NoBom $StubFail (($cur | Select-Object -Unique) -join "`n")
}
function Add-StubUnknown { param([string]$Id)
    $cur = @()
    if (Test-Path -LiteralPath $StubUnknown) { $cur = @([System.IO.File]::ReadAllLines($StubUnknown) | Where-Object { $_.Trim() -ne '' }) }
    $cur += $Id
    Write-Utf8NoBom $StubUnknown (($cur | Select-Object -Unique) -join "`n")
}
function Read-StubCalls {
    if (-not (Test-Path -LiteralPath $StubCalls)) { return @() }
    $rows = @()
    foreach ($l in @([System.IO.File]::ReadAllLines($StubCalls) | Where-Object { $_.Trim() -ne '' })) {
        try { $rows += ,($l | ConvertFrom-Json) } catch { }
    }
    return $rows
}
function Get-StubCreateCount {
    @((Read-StubCalls) | Where-Object { $_.method -eq 'session.create' }).Count
}
function Get-StubPromptsTo { param([string]$SessionId)
    @((Read-StubCalls) | Where-Object { $_.method -eq 'session.prompt' -and $_.payload -and [string]$_.payload.sessionId -eq $SessionId })
}

# --- stub endpoint: fake plugin liveness + fake /api envelope receiver ---
# One raw-TCP HTTP server in a background job (http.sys is blocked by the harness
# sandbox, so the server hand-parses HTTP/1.1 at the byte level). Zero real
# backend touched: liveness truth is stub-alive.txt (+ stub-unknown.txt forcing
# the conservative unknown verdict); /api session.create assigns stub-s<N> ids;
# session.prompt honors the stub-fail.txt injection set (business-error envelope).
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
            $unknownSet = Read-IdSet (Join-Path $Root 'stub-unknown.txt')
            $fail = Read-IdSet (Join-Path $Root 'stub-fail.txt')
            $jsonOut = $null
            if ($methodVerb -eq 'GET' -and $pathOnly -eq '/rdd-goal-tree/liveness') {
                $sid = if ($q.ContainsKey('session_id')) { [string]$q['session_id'] } else { '' }
                $live = 'unknown'
                if ($sid -ne '') {
                    if ($unknownSet.ContainsKey($sid)) { $live = 'unknown' }
                    elseif ($alive.ContainsKey($sid)) { $live = 'alive' }
                    else { $live = 'dead' }
                }
                $jsonOut = @{ session_id = $sid; liveness = $live; reason = 'stub registry (session-keyed probe)' } | ConvertTo-Json -Compress
            }
            elseif ($methodVerb -eq 'POST' -and $pathOnly.StartsWith('/api/')) {
                $method = $pathOnly.Substring(5)
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

# --- sidecar helpers ---
function Get-AnchorSidecarPath { param([string]$ArchiveDir) (Join-Path $ArchiveDir 'session-anchors.json') }
function Read-AnchorEntry { param([string]$ArchiveDir, [string]$Role)
    $p = Get-AnchorSidecarPath $ArchiveDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { return 'CORRUPT' }
    $t = $parsed.'1'
    if ($null -eq $t -or $null -eq $t.roles) { return $null }
    $e = $t.roles.$Role
    if ($null -eq $e) { return $null }
    return @{ sessionId = [string]$e.sessionId; reentries = [int]$e.reentries }
}
function Write-AnchorSidecar { param([string]$ArchiveDir, [string]$Role, [string]$Sid, [int]$Reentries)
    $obj = @{ '1' = @{ roles = @{ } } }
    $obj.'1'.roles[$Role] = @{ sessionId = $Sid; reentries = $Reentries; anchoredAt = '2026-10-20T00:00:00.0000000Z' }
    Write-Utf8NoBom (Get-AnchorSidecarPath $ArchiveDir) ($obj | ConvertTo-Json -Depth 8)
}
function Set-AnchorReentries { param([string]$ArchiveDir, [string]$Role, [int]$Value)
    $p = Get-AnchorSidecarPath $ArchiveDir
    $obj = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $obj.'1'.roles.$Role.reentries = $Value
    Write-Utf8NoBom $p ($obj | ConvertTo-Json -Depth 8)
}
function Read-TaskRow { param([string]$ArchiveDir)
    $tj = [System.IO.File]::ReadAllText((Join-Path $ArchiveDir 'task.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    return $tj.tasks[0]
}
function Read-LastLedgerEntry { param([string]$ArchiveDir)
    $p = Join-Path $ArchiveDir 'decisions.jsonl'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $lines = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { return $null }
    return (($lines[$lines.Count - 1]) | ConvertFrom-Json)
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
Set-StubAlive @()
Write-Utf8NoBom $StubFail ''
Write-Utf8NoBom $StubUnknown ''
$null = git init -q $Work 2>$null

$env:DSH_WEB_URL = "http://127.0.0.1:$port"
$stubUp = $false
foreach ($try in 1..40) {
    try { $null = [System.Net.WebRequest]::Create("http://127.0.0.1:$port/rdd-goal-tree/liveness?session_id=ping").GetResponse(); $stubUp = $true; break }
    catch { Start-Sleep -Milliseconds 250 }
}

# fixtures (mirror test-inplace-redo conventions)
function New-Archive { param([string]$Name, [string]$OwnerRole)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nsession-reuse 测试归档 $Name。`n"
    Write-Utf8NoBom (Join-Path $archDir 'requirements/t1.md') "# $Name 需求 1`n`n- **描述**：session-reuse 测试需求 $Name`n- **验收标准**：见 overview.md`n"
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf ('[{"title":"' + $Name + '","requirement":"requirements/t1.md","currentOwners":["' + $OwnerRole + '"],"designDocs":[]}]')
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return $archDir
}

Push-Location $Work
try {
    Assert-True $stubUp 'SR-T0 stub endpoint up (liveness + /api receiver)' "port $port"

    # ================= T1 (AC-1): reject 打回 → DEV 原会话自动收到重做指针 =================
    $arch1 = New-Archive 'sr-t1' 'DEV'
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch1 'task.json'), '-Project', $Work)
    $devSid = ''
    $devEntry = Read-AnchorEntry $arch1 'DEV'
    if ($null -ne $devEntry -and $devEntry -ne 'CORRUPT') { $devSid = $devEntry.sessionId }
    Assert-True ($r.exit -eq 0 -and $null -ne $devEntry -and $devSid -like 'stub-s*') 'SR-101 T1 create-path anchor write (reentries=0, sid=stub-s*)' ($r.raw)
    Assert-True ($null -ne $devEntry -and [int]$devEntry.reentries -eq 0) 'SR-101b T1 anchor reentries starts at 0' (($devEntry | ConvertTo-Json -Compress))
    Set-StubAlive @($devSid)
    $createsBefore1 = Get-StubCreateCount
    $promptsBefore1 = @(Get-StubPromptsTo $devSid).Count
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t1', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', 'TC-005 分页边界未处理')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true) 'SR-102 T1 reject exit 0 + JSON success' ($r.raw)
    $dlv = $r.json.data.delivery
    Assert-True ($null -ne $dlv -and [string]$dlv.state -eq 'reused' -and [string]$dlv.sessionId -eq $devSid) 'SR-103 T1 delivery.state=reused into the ORIGINAL session' (($dlv | ConvertTo-Json -Depth 4 -Compress))
    Assert-True ($null -ne $dlv -and [int]$dlv.reentries -eq 1) 'SR-104 T1 delivery.reentries=1 after successful reuse push' (($dlv | ConvertTo-Json -Depth 4 -Compress))
    $task1 = Read-TaskRow $arch1
    Assert-True (@($task1.currentOwners) -contains 'DEV' -and ([string]$task1.remark) -match 'QA 打回 DEV' -and ([string]$task1.remark) -match 'TC-005') 'SR-105 T1 route write landed (owners + 打回轨迹 remark)' ("owners=$(($task1.currentOwners) -join '+') remark=$($task1.remark)")
    Assert-True ((Get-StubCreateCount) -eq $createsBefore1) 'SR-106 T1 zero session.create during reject (no cold start)'
    $prompts1 = @(Get-StubPromptsTo $devSid)
    Assert-True ($prompts1.Count -eq ($promptsBefore1 + 1)) 'T1 exactly one new prompt into the original DEV session' ("before=$promptsBefore1 after=$($prompts1.Count)")
    $pText = if ($prompts1.Count -gt 0) { [string]$prompts1[-1].payload.content[0].text } else { '' }
    Assert-True ($pText -match 'TC-005 分页边界未处理' -and $pText -match '【打回重做】' -and $pText -match 'claim -Role DEV -TaskId 1' -and $pText -match '\.rdd/changes/archive/sr-t1') 'SR-107 T1 pointer payload: 打回理由 + 打回标记 + claim 任务锚' ($pText)
    $devEntry2 = Read-AnchorEntry $arch1 'DEV'
    Assert-True ($null -ne $devEntry2 -and [int]$devEntry2.reentries -eq 1) 'SR-108 T1 sidecar reentries ticked to 1' (($devEntry2 | ConvertTo-Json -Compress))
    Assert-True (Test-Path -LiteralPath (Join-Path $arch1 'session-anchors.json.bak') -PathType Leaf) 'SR-108b T1 sidecar .bak rotation on write'
    Assert-True (($r.stderr -match '重做指针已投回') -and ($r.stderr -match $devSid)) 'SR-109 T1 delivery narration on stderr (JSON stdout stays pure)' ($r.stderr)

    # ================= T2 (AC-2): 二次正向交接投回第一轮验收原会话 =================
    $arch2 = New-Archive 'sr-t2' 'QA'
    $r = Invoke-Start @('-Role', 'QA', '-TaskId', '1', '-TaskJson', (Join-Path $arch2 'task.json'), '-Project', $Work)
    $qaEntry = Read-AnchorEntry $arch2 'QA'
    $qaSid = if ($null -ne $qaEntry -and $qaEntry -ne 'CORRUPT') { $qaEntry.sessionId } else { '' }
    Assert-True ($r.exit -eq 0 -and $qaSid -like 'stub-s*') 'T2 first QA dispatch anchors the QA session' ($r.raw)
    Set-StubAlive @($qaSid)
    $createsBefore2 = Get-StubCreateCount
    $promptsBefore2 = @(Get-StubPromptsTo $qaSid).Count
    $r = Invoke-Start @('-Role', 'QA', '-TaskId', '1', '-TaskJson', (Join-Path $arch2 'task.json'), '-Project', $Work)
    Assert-True ($r.exit -eq 0 -and ($r.raw -match '会话复用')) 'SR-110 T2 auto gate reuses the alive anchor session (二次正向交接)' ($r.raw)
    Assert-True ((Get-StubCreateCount) -eq $createsBefore2) 'SR-111 T2 zero session.create on the reuse path (QA 全程单会话)' ("before=$createsBefore2 after=$((Get-StubCreateCount))")
    Assert-True (@(Get-StubPromptsTo $qaSid).Count -eq ($promptsBefore2 + 1)) 'SR-112 T2 pointer re-delivered into the ORIGINAL QA session'
    $qaEntry2 = Read-AnchorEntry $arch2 'QA'
    Assert-True ($null -ne $qaEntry2 -and [int]$qaEntry2.reentries -eq 1) 'SR-113 T2 reentries ticked to 1' (($qaEntry2 | ConvertTo-Json -Compress))

    # ================= T3 (AC-3): 重入上限 → 裁决点四出口 + reentry 子命令 =================
    $arch3 = New-Archive 'sr-t3' 'QA'
    $r = Invoke-Start @('-Role', 'QA', '-TaskId', '1', '-TaskJson', (Join-Path $arch3 'task.json'), '-Project', $Work)
    $qa3 = Read-AnchorEntry $arch3 'QA'
    $qa3Sid = if ($null -ne $qa3 -and $qa3 -ne 'CORRUPT') { $qa3.sessionId } else { '' }
    Set-StubAlive @($qa3Sid)
    Set-AnchorReentries $arch3 'QA' 3
    $createsBefore3 = Get-StubCreateCount
    $promptsBefore3 = @(Get-StubPromptsTo $qa3Sid).Count
    $r = Invoke-Start @('-Role', 'QA', '-TaskId', '1', '-TaskJson', (Join-Path $arch3 'task.json'), '-Project', $Work)
    Assert-True ($r.exit -ne 0 -and ($r.raw -match 'REENTRY_CAP_EXCEEDED')) 'SR-120 T3 start-role cap refusal exit 1 (REENTRY_CAP_EXCEEDED)' ($r.raw)
    Assert-True (($r.raw -match '升级用户') -and ($r.raw -match '-NoReuse') -and ($r.raw -match '-Exempt') -and ($r.raw -match '-RaiseTo')) 'SR-120b T3 refusal carries the four copyable exits' ($r.raw)
    Assert-True ((Get-StubCreateCount) -eq $createsBefore3 -and @(Get-StubPromptsTo $qa3Sid).Count -eq $promptsBefore3) 'SR-120c T3 cap refusal delivers nothing (no create, no prompt)'
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1', '-From', 'PM', '-To', 'QA', '-Reason', '触顶后打回裁决检查')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and [string]$r.json.data.delivery.state -eq 'capped') 'SR-121 T3 reject at cap → delivery.state=capped (no delivery)' ($r.raw)
    $task3 = Read-TaskRow $arch3
    Assert-True (@($task3.currentOwners) -contains 'QA') 'SR-121b T3 route write still landed at the cap (触顶≠硬停路由)' ("owners=$(($task3.currentOwners) -join '+')")
    Assert-True (($r.stderr -match 'REENTRY_CAP_EXCEEDED')) 'SR-121c T3 capped adjudication text visible on stderr' ($r.stderr)
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1', '-Exempt')
    Assert-True ($r.exit -ne 0 -and [string]$r.json.error.code -eq 'MISSING_USER_VERDICT') 'SR-122 T3 mutation without -UserVerdict → MISSING_USER_VERDICT' ($r.raw)
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1', '-Exempt', '-RaiseTo', '8', '-UserVerdict', 'conflict probe')
    Assert-True ($r.exit -ne 0 -and [string]$r.json.error.code -eq 'REENTRY_ACTION_CONFLICT') 'SR-123 T3 -Exempt + -RaiseTo → REENTRY_ACTION_CONFLICT' ($r.raw)
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t2', '-TaskId', '1', '-Exempt', '-UserVerdict', '未触顶豁免探测')
    Assert-True ($r.exit -ne 0 -and [string]$r.json.error.code -eq 'REENTRY_EXEMPT_NOT_CAPPED') 'SR-124 T3 exemption rejected when not at the cap' ($r.raw)
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1', '-Exempt', '-UserVerdict', '用户裁决：豁免一次继续复用')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and [string]$r.json.data.action -eq 'exempt' -and [int]$r.json.data.reentryMax -eq 4) 'SR-125 T3 valid exempt → one-shot newMax=4' ($r.raw)
    $led1 = Read-LastLedgerEntry $arch3
    Assert-True ($null -ne $led1 -and [string]$led1.kind -eq 'reentry_verdict' -and [string]$led1.decider -eq 'user' -and [string]$led1.entry_id -eq 'D1' -and [string]$led1.action -eq 'exempt') 'SR-126 T3 exempt verdict lands in decisions.jsonl (kind/decider/D1)' (($led1 | ConvertTo-Json -Compress))
    $r = Invoke-Start @('-Role', 'QA', '-TaskId', '1', '-TaskJson', (Join-Path $arch3 'task.json'), '-Project', $Work)
    $qa3After = Read-AnchorEntry $arch3 'QA'
    Assert-True ($r.exit -eq 0 -and $null -ne $qa3After -and [int]$qa3After.reentries -eq 4) 'SR-127 T3 after exempt the reuse resumes (reentries 3→4)' ("exit=$($r.exit) entry=$(($qa3After | ConvertTo-Json -Compress))")
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1', '-RaiseTo', '3', '-UserVerdict', '提额探测')
    Assert-True ($r.exit -ne 0 -and [string]$r.json.error.code -eq 'REENTRY_RAISE_ONLY') 'SR-128 T3 raise-only violation (RaiseTo ≤ current max)' ($r.raw)
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1', '-RaiseTo', '6', '-UserVerdict', '用户裁决：提高重入上限至 6')
    Assert-True ($r.exit -eq 0 -and [int]$r.json.data.reentryMax -eq 6 -and [string]$r.json.data.action -eq 'raise') 'SR-129 T3 raise to 6 accepted' ($r.raw)
    $led2 = Read-LastLedgerEntry $arch3
    Assert-True ($null -ne $led2 -and [string]$led2.entry_id -eq 'D2' -and [string]$led2.kind -eq 'reentry_verdict') 'SR-130 T3 raise verdict lands as D2 (sequence continues)' (($led2 | ConvertTo-Json -Compress))
    $sidecar3 = Read-AnchorEntry $arch3 'QA'
    $raw3 = [System.IO.File]::ReadAllText((Get-AnchorSidecarPath $arch3), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True ([int]$raw3.'1'.reentryMax -eq 6) 'SR-131 T3 task-level reentryMax persisted in the sidecar' ($raw3 | ConvertTo-Json -Depth 5 -Compress)
    $r = Invoke-Flow @('-Command', 'reentry', '-Archive', '.rdd/changes/archive/sr-t3', '-TaskId', '1')
    Assert-True ($r.exit -eq 0 -and [int]$r.json.data.reentryMax -eq 6 -and ([string]$r.json.data.maxSource) -match 'task-level' -and @($r.json.data.roles).Count -ge 1) 'SR-132 T3 status view read-only (maxSource + roles rows, no verdict needed)' ($r.raw)
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $arch3 '.decisions.lock') -PathType Leaf)) 'SR-133 T3 decisions lock removed after appends (zero residue)'

    # ================= T4 (AC-4): 原会话死 / 无锚 / unknown → 不阻断 =================
    $arch4a = New-Archive 'sr-t4a' 'DEV'
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch4a 'task.json'), '-Project', $Work)
    $deadSid = (Read-AnchorEntry $arch4a 'DEV').sessionId   # deliberately NOT added to the alive set
    $createsBefore4 = Get-StubCreateCount
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch4a 'task.json'), '-Project', $Work)
    $reanchored = Read-AnchorEntry $arch4a 'DEV'
    Assert-True ($r.exit -eq 0 -and ($r.raw -match '不可达') -and (Get-StubCreateCount) -eq ($createsBefore4 + 1)) 'SR-140 T4 dead anchor → fallback create with explicit notice' ($r.raw)
    Assert-True ($null -ne $reanchored -and [string]$reanchored.sessionId -ne $deadSid -and [int]$reanchored.reentries -eq 0) 'SR-141 T4 replacement session re-anchored with a RESET count' (($reanchored | ConvertTo-Json -Compress))
    $arch4b = New-Archive 'sr-t4b' 'DEV'
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch4b 'task.json'), '-Project', $Work)
    $deadSidB = (Read-AnchorEntry $arch4b 'DEV').sessionId
    $createsBefore4b = Get-StubCreateCount
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t4b', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', '原会话已删除回归')
    Assert-True ($r.exit -eq 0 -and [string]$r.json.data.delivery.state -eq 'new-session' -and (Get-StubCreateCount) -eq ($createsBefore4b + 1)) 'SR-142 T4 reject dead anchor → auto fallback new-session' ($r.raw)
    Assert-True (($r.stderr -match '原会话不可达') -and ([string]$r.json.data.delivery.reason -match 'dead')) 'SR-143 T4 fallback reason surfaced (liveness=dead + stderr notice)' ($r.stderr)
    $newAnchorB = Read-AnchorEntry $arch4b 'DEV'
    Assert-True ($null -ne $newAnchorB -and [string]$newAnchorB.sessionId -ne $deadSidB) 'SR-144 T4 reject fallback re-anchored the replacement session' (($newAnchorB | ConvertTo-Json -Compress))
    $arch4c = New-Archive 'sr-t4c' 'DEV'
    $createsBefore4c = Get-StubCreateCount
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t4c', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', '无锚点现状行为回归')
    Assert-True ($r.exit -eq 0 -and [string]$r.json.data.delivery.state -eq 'no-anchor') 'SR-145 T4 reject without anchor → no-anchor state (current behavior)' ($r.raw)
    Assert-True ((Get-StubCreateCount) -eq $createsBefore4c) 'SR-146 T4 no-anchor state touches zero backend (manual handoff preserved)'
    $arch4d = New-Archive 'sr-t4d' 'DEV'
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch4d 'task.json'), '-Project', $Work)
    $unkSid = (Read-AnchorEntry $arch4d 'DEV').sessionId
    Add-StubUnknown $unkSid
    Set-StubAlive @($unkSid)
    $createsBefore4d = Get-StubCreateCount
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch4d 'task.json'), '-Project', $Work)
    $reanchoredD = Read-AnchorEntry $arch4d 'DEV'
    Assert-True ($r.exit -eq 0 -and (Get-StubCreateCount) -eq ($createsBefore4d + 1) -and ($r.raw -match 'unknown')) 'SR-147 T4 unknown liveness is NEVER a reuse verdict → fallback create' ($r.raw)
    Assert-True ($null -ne $reanchoredD -and [string]$reanchoredD.sessionId -ne $unkSid) 'SR-148 T4 unknown verdict re-anchored to the replacement' (($reanchoredD | ConvertTo-Json -Compress))

    # ================= T5 (AC-5): 非 dsh 后端无回归 =================
    $arch5 = New-Archive 'sr-t5' 'DEV'
    $prevUrl5 = $env:DSH_WEB_URL
    $prevRt5 = $env:RDD_RUNTIME
    try {
        Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\RDD_RUNTIME -ErrorAction SilentlyContinue
        $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t5', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', 'CLI 后端形状回归')
        Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $null -eq $r.json.data.PSObject.Properties['delivery']) 'SR-150 T5 CLI shell reject: JSON has NO delivery key (byte-shape regression)' ($r.raw)
    }
    finally {
        if ($prevUrl5) { $env:DSH_WEB_URL = $prevUrl5 } else { Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue }
        if ($prevRt5) { $env:RDD_RUNTIME = $prevRt5 } else { Remove-Item Env:\RDD_RUNTIME -ErrorAction SilentlyContinue }
    }
    $prevRt5 = $env:RDD_RUNTIME
    try {
        $env:RDD_RUNTIME = 'app'
        $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t5', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', 'Plus 后端形状回归')
        Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $null -eq $r.json.data.PSObject.Properties['delivery']) 'SR-151 T5 Plus backend (RDD_RUNTIME=app wins) reject: NO delivery key' ($r.raw)
    }
    finally {
        if ($prevRt5) { $env:RDD_RUNTIME = $prevRt5 } else { Remove-Item Env:\RDD_RUNTIME -ErrorAction SilentlyContinue }
    }
    $prevUrl5 = $env:DSH_WEB_URL
    try {
        Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
        $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch5 'task.json'), '-Project', $Work, '-ExistingSessionId', 'sess-x')
        Assert-True ($r.exit -ne 0 -and ($r.raw -match 'SESSION_REUSE_UNSUPPORTED')) 'SR-152 T5 CLI -ExistingSessionId still rejected (guard intact)' ($r.raw)
    }
    finally {
        if ($prevUrl5) { $env:DSH_WEB_URL = $prevUrl5 } else { Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue }
    }

    # ================= T6 (AC-6): planner 桥接 run 互不可见（R7） =================
    $arch6a = New-Archive 'sr-t6a' 'DEV'
    Write-AnchorSidecar $arch6a 'DEV' 'sess-bridge-1' 0
    Set-StubAlive @('sess-bridge-1')
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch6a 'task.json'), '-Project', $Work, '-GoalTreeRun', 'gt-r1', '-GoalTreeNode', 'n1', '-DryRun')
    $entry6a = Read-AnchorEntry $arch6a 'DEV'
    Assert-True ($r.exit -eq 0 -and ($r.raw -notmatch '复用会话')) 'SR-153 T6 bridge markers suppress the auto gate (no reuse verdict)' ($r.raw)
    Assert-True ($null -ne $entry6a -and [string]$entry6a.sessionId -eq 'sess-bridge-1' -and [int]$entry6a.reentries -eq 0) 'SR-154 T6 sidecar untouched by the bridge-marked call' (($entry6a | ConvertTo-Json -Compress))
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch6a 'task.json'), '-Project', $Work, '-DryRun')
    Assert-True ($r.exit -eq 0 -and ($r.raw -match '复用会话')) 'SR-155 T6 control (no markers): auto gate fires in DryRun' ($r.raw)
    $arch6b = New-Archive 'sr-t6b' 'DEV'
    $createsBefore6 = Get-StubCreateCount
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch6b 'task.json'), '-Project', $Work, '-GoalTreeRun', 'gt-r2', '-GoalTreeNode', 'n1')
    Assert-True ($r.exit -eq 0 -and (Get-StubCreateCount) -eq ($createsBefore6 + 1)) 'SR-156 T6 bridge-marked real dispatch: session created' ($r.raw)
    Assert-True (-not (Test-Path -LiteralPath (Get-AnchorSidecarPath $arch6b) -PathType Leaf)) 'SR-157 T6 bridge-marked real dispatch writes NO anchor sidecar'
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch6b 'task.json'), '-Project', $Work)
    Assert-True ($r.exit -eq 0 -and (Test-Path -LiteralPath (Get-AnchorSidecarPath $arch6b) -PathType Leaf)) 'SR-158 T6 control (no markers): anchor written on create (both directions isolated)'
    $bridgeSrc = [System.IO.File]::ReadAllText($BridgePs1, [System.Text.Encoding]::UTF8)
    Assert-True (($bridgeSrc -notmatch 'session-reuse\.ps1')) 'SR-159 T6 delivery-bridge never dot-sources the session-reuse lib (R7 invariant)'

    # ================= T7: 投递失败不计数 + 边车健壮性 =================
    $arch7a = New-Archive 'sr-t7a' 'DEV'
    $r = Invoke-Start @('-Role', 'DEV', '-TaskId', '1', '-TaskJson', (Join-Path $arch7a 'task.json'), '-Project', $Work)
    $sid7a = (Read-AnchorEntry $arch7a 'DEV').sessionId
    Set-StubAlive @($sid7a)
    Add-StubFail $sid7a
    $createsBefore7 = Get-StubCreateCount
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t7a', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', '投递失败不计数检查')
    $dlv7 = $r.json.data.delivery
    Assert-True ($r.exit -eq 0 -and [string]$dlv7.state -eq 'pointer-failed') 'SR-160 T7 prompt failure → pointer-failed state (route already written)' ($r.raw)
    Assert-True ((Get-StubCreateCount) -eq $createsBefore7) 'SR-161 T7 pointer-class failure NEVER auto-creates (防重复处理)'
    $entry7a = Read-AnchorEntry $arch7a 'DEV'
    Assert-True ($null -ne $entry7a -and [int]$entry7a.reentries -eq 0) 'SR-162 T7 failed delivery does NOT tick the reentry count' (($entry7a | ConvertTo-Json -Compress))
    Assert-True (($r.stderr -match '不自动新建') -and ($r.stderr -match '手动')) 'SR-163 T7 manual two-choice guidance on pointer failure' ($r.stderr)
    $arch7b = New-Archive 'sr-t7b' 'DEV'
    Write-Utf8NoBom (Get-AnchorSidecarPath $arch7b) 'NOT JSON {{{'
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t7b', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', '边车损坏降级检查')
    Assert-True ($r.exit -eq 0 -and [string]$r.json.data.delivery.state -eq 'no-anchor') 'SR-164 T7 corrupt sidecar without bak → fail-soft no-anchor (never crashes)' ($r.raw)
    $arch7c = New-Archive 'sr-t7c' 'DEV'
    Write-Utf8NoBom (Join-Path $arch7c 'session-anchors.json') 'BROKEN PRIMARY {'
    Write-Utf8NoBom (Join-Path $arch7c 'session-anchors.json.bak') (@{ '1' = @{ roles = @{ DEV = @{ sessionId = 'sess-bak-9'; reentries = 2; anchoredAt = '2026-10-20T00:00:00.0000000Z' } } } } | ConvertTo-Json -Depth 8)
    Set-StubAlive @('sess-bak-9')
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', '.rdd/changes/archive/sr-t7c', '-TaskId', '1', '-From', 'QA', '-To', 'DEV', '-Reason', 'bak 回退复用检查')
    $dlv7c = $r.json.data.delivery
    Assert-True ($r.exit -eq 0 -and [string]$dlv7c.state -eq 'reused' -and [string]$dlv7c.sessionId -eq 'sess-bak-9' -and [int]$dlv7c.reentries -eq 3) 'SR-165 T7 corrupt primary falls back to .bak and reuses with the tick' (($dlv7c | ConvertTo-Json -Depth 4 -Compress))
}
finally {
    Pop-Location
    Stop-Stub
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("session-reuse suite: {0} passed, {1} failed" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Output ("FAIL  {0}   {1}" -f $_.name, $_.detail) }
    exit 1
}
if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
exit 0

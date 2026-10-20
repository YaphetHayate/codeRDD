# inplace-redo QA black-box probe — 桥接 run 同阶段返工复用原 worker 会话（inplace-redo-session-reuse）
# 需求: 2026-10-01-planner-delivery-efficiency/requirements/inplace-redo-session-reuse.md (验收标准 1-5)
# 方法: 黑盒驱动 PS5.1 生产解释器（rdd-flow init + delivery-bridge promulgate/claim/settle/reclaim/
#       rollback/dispatch + goal-tree-leaf report + goal-tree redo/status），本地 raw-TCP stub 端点
#       承载 liveness 与 /api（零真后端），独立于 DEV 套件 test-inplace-redo.ps1 从需求侧复验：
#   - TC-B127 (AC1 正向): 原会话存活 → reclaim in-place 全链（同节点同会话、零 session.create、
#     指针含三源失败清单[四查 problems + 回调 full_report/extras.verification + 规划者 -FailureRef]
#     + 重新 report 指令、ledger type=redo 条目含 failure_ref、边车保会话且 claimed_at 换新钟）
#   - TC-B128 (AC1 正向): in-place 后原会话重报（qualified）+ settle 闭环
#   - TC-B129 (AC1 边界): no_push run 的 in-place：树侧迁移照落、零 /api 调用
#   - TC-B130 (AC2 反向): 原会话 dead → 回落现行「剪枝+重建+重推」路径（无 redo 条目、新会话）
#   - TC-B131 (AC2 异常): 探针不可达（liveness unknown）→ 回落现行路径
#   - TC-B132 (AC2 边界): CLI 后端（无 DSH_WEB_URL）回落 + start-role -ExistingSessionId 拒
#     SESSION_REUSE_UNSUPPORTED
#   - TC-B133 (AC3 正向): rollback 后再推进 → QA 重验节点经花名册（同 task×role）回原 QA 会话，
#     session 键控探针实证（注册表 liveness 优先的两级机制复用）
#   - TC-B134 (AC3 边界): rollback 重建节点永不复用（存活同角色会话在场仍 session.create）
#   - TC-B135 (AC3 正向): 手动 dispatch 复用解析：sidecar 优先回原会话（reused_session_id 透出）
#   - TC-B136 (AC4 静态): planner-guide 硬约束 4 措辞 + 命令面板 reclaim/settle/dispatch 行同步
#   - TC-B137 (AC5 反向): -NoReuse 逃生开关（reclaim 与 dispatch 双触点走现行路径）
#   - TC-B138 (AC5 边界): ledger redo 审计行不膨胀 worker 报告统计、goal-tree status 可解析
# Exit code 0 = all green.
#
# 注: 本文件含中文字符串断言，须以 UTF-8 **带 BOM** 落盘（PS5.1 无 BOM 按 ANSI 误读）。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# engine root: 从脚本位置逐级上溯找 rdd-engine/scripts/rdd-flow.ps1（三级定位链的项目内分支）
$EngineDir = $null
$cur = $PSScriptRoot
while ($cur -and -not $EngineDir) {
    if (Test-Path (Join-Path $cur 'rdd-engine\scripts\rdd-flow.ps1')) { $EngineDir = Join-Path $cur 'rdd-engine\scripts' }
    $parent = Split-Path -Parent $cur
    if ($parent -eq $cur) { break }
    $cur = $parent
}
if (-not $EngineDir) { $EngineDir = Join-Path $env:RDD_ENGINE_HOME 'scripts' }
if (-not (Test-Path (Join-Path $EngineDir 'delivery-bridge.ps1'))) { throw "rdd-engine scripts not located" }
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $EngineDir)
$Work      = Join-Path $env:TEMP ('inplace-redo-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# 隔离: 本探测可能在 dsh 会话内运行——中和继承的 DSH_SESSION_ID/DSH_WEB_URL，全部子进程只看见
# 本探针显式设置的环境（stub URL 或按场景清除）。
$SavedSessionId = $env:DSH_SESSION_ID
$SavedWebUrl    = $env:DSH_WEB_URL
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue
Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue

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
    # bridge 默认形状翻转（promulgate legacy→wake）：本探针按旧链 chain-head 拓扑
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
function Read-Sidecar { param([string]$RunId, [string]$NodeId)
    $p = Join-Path $Work (".rdd/goal-trees/$RunId/state/claims/$NodeId.json")
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

# --- stub control files ---
$StubAlive = Join-Path $Work 'stub-alive.txt'      # alive session ids (liveness truth)
$StubFail  = Join-Path $Work 'stub-fail.txt'       # session ids whose session.prompt MUST fail
$StubCalls = Join-Path $Work 'stub-calls.jsonl'    # every request (liveness query / api call)

function Set-StubAlive { param([string[]]$Ids)
    Write-Utf8NoBom $StubAlive ((@($Ids) | Where-Object { $_ }) -join "`n")
}
function Add-StubFail { param([string]$Id)
    $cur = @()
    if (Test-Path -LiteralPath $StubFail) { $cur = @([System.IO.File]::ReadAllLines($StubFail) | Where-Object { $_.Trim() -ne '' }) }
    $cur += $Id
    Write-Utf8NoBom $StubFail (($cur | Select-Object -Unique) -join "`n")
}
function Read-StubRows {
    if (-not (Test-Path -LiteralPath $StubCalls)) { return @() }
    $rows = @()
    foreach ($l in @([System.IO.File]::ReadAllLines($StubCalls) | Where-Object { $_.Trim() -ne '' })) {
        try { $rows += ,($l | ConvertFrom-Json) } catch { }
    }
    return $rows
}
function Get-StubApiRows { param([string]$Method = '')
    $rows = @((Read-StubRows) | Where-Object { $_.kind -eq 'api' })
    if ($Method) { $rows = @($rows | Where-Object { $_.method -eq $Method }) }
    return @($rows)
}
function Get-StubCreateCount { @(Get-StubApiRows 'session.create').Count }
function Get-StubPromptsTo { param([string]$SessionId)
    @((Read-StubRows) | Where-Object { $_.kind -eq 'api' -and $_.method -eq 'session.prompt' -and $_.payload -and [string]$_.payload.sessionId -eq $SessionId })
}
function Get-StubLivenessQueries { param([string]$Pattern)
    @((Read-StubRows) | Where-Object { $_.kind -eq 'liveness' -and ([string]$_.query) -match $Pattern })
}

# --- stub endpoint: fake plugin liveness + fake /api envelope receiver ---
# 裸 TcpListener 手写 HTTP/1.1（沙箱禁 http.sys/HttpListener）：字节级头解析、100-continue
# 应答、Content-Length 精确 UTF-8 body、Connection: close 收口。零真后端。
$port = 0
$tcpProbe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
$tcpProbe.Start(); $port = ($tcpProbe.LocalEndpoint).Port; $tcpProbe.Stop()

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
    function Log-Row { param($Root, $Row)
        [System.IO.File]::AppendAllText((Join-Path $Root 'stub-calls.jsonl'), ((ConvertTo-Json $Row -Depth 10 -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
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
            $fail = Read-IdSet (Join-Path $Root 'stub-fail.txt')
            $jsonOut = $null
            if ($methodVerb -eq 'GET' -and $pathOnly -eq '/rdd-goal-tree/liveness') {
                Log-Row $Root @{ at = (Get-Date).ToUniversalTime().ToString('o'); kind = 'liveness'; query = $rawPath }
                $sid = $null
                if ($q.ContainsKey('session_id') -and ([string]$q['session_id']).Trim() -ne '') {
                    $sid = [string]$q['session_id']
                }
                elseif ($q.ContainsKey('run') -and $q.ContainsKey('node') -and $q['run'] -and $q['node']) {
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
                $jsonOut = @{ session_id = $sid; liveness = $live; reason = 'stub registry probe' } | ConvertTo-Json -Compress
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
                $row = @{ at = (Get-Date).ToUniversalTime().ToString('o'); kind = 'api'; method = $method; payload = $params }
                if ($method -eq 'session.create') { $row['assigned_sid'] = $value['sessionId'] }
                Log-Row $Root $row
                if ($ok) { $jsonOut = @{ result = @{ ok = $true; value = $value } } | ConvertTo-Json -Depth 10 -Compress }
                else { $jsonOut = @{ result = @{ ok = $false; error = @{ code = $code; message = $message } } } | ConvertTo-Json -Depth 10 -Compress }
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
Write-Utf8NoBom $StubFail ''
$null = git init -q $Work 2>$null

$env:DSH_WEB_URL = "http://127.0.0.1:$port"
$stubUp = $false
foreach ($try in 1..40) {
    try { $null = [System.Net.WebRequest]::Create("http://127.0.0.1:$port/rdd-goal-tree/liveness?session_id=ping").GetResponse(); $stubUp = $true; break }
    catch { Start-Sleep -Milliseconds 250 }
}

# fixtures (mirror test-bridge-acceptance / prescan-gate-qa conventions)
function New-Archive { param([string]$Name, [string]$OwnersJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/t1.md') "# $Name`n`ninplace-redo QA probe fixture $Name。`n"
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf ('[{"title":"IQ","requirement":"requirements/t1.md","currentOwners":' + $OwnersJson + ',"designDocs":[]}]')
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}
function Write-TestPlan { param([string]$Path)
    $stage = @{ id = 'S1'; goal = 'stage S1 goal'; milestone = 'm1'; task_ids = @(1); batches = @(@(1)); acceptance_point = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' } }
    $plan = [ordered]@{ planned_at = '2026-10-02T00:00:00Z'; planner = 'qa-probe'; stages = @($stage); risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}
# 回调构造: ok=qualified(verification) / dev-ok=qualified(DEV 带 quality_scan skip) /
# failed=verdict failed（四查失败于 verdict，失败清单三源可标记）
function New-Cb { param([string]$NodeId, [string]$Ref, [string]$Kind = 'ok', [string]$FullReport = '', [string]$Verification = 'smoke ok')
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'inplace-redo QA probe delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
    }
    if ($Kind -eq 'failed') { $cb.verdict = 'failed' }
    if ($FullReport) { $cb['full_report'] = $FullReport }
    $verif = $Verification
    $qs = $null
    if ($Kind -eq 'dev-ok') { $qs = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } }
    if ($qs) { $cb['extras'] = @{ verification = $verif; quality_scan = $qs } }
    else { $cb['extras'] = @{ verification = $verif } }
    $cbFile = Join-Path $env:TEMP ("iq-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Claim { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$AsSession = $null)
    $prev = $env:DSH_SESSION_ID
    if ($AsSession) { $env:DSH_SESSION_ID = $AsSession } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    try { $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role) }
    finally {
        if ($prev) { $env:DSH_SESSION_ID = $prev } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    }
    return $r
}
function Do-Report { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref, [string]$Kind = 'ok', [string]$FullReport = '', [string]$Verification = 'smoke ok')
    $cb = New-Cb $NodeId $Ref $Kind $FullReport $Verification
    Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref, [string]$Kind = 'ok', [string]$AsSession = $null, [string]$FullReport = '', [string]$Verification = 'smoke ok')
    $r = Do-Claim $RunId $NodeId $Role $AsSession
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $r = Do-Report $RunId $NodeId $Role $Ref $Kind $FullReport $Verification
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return $r
}
function Get-LedgerReportCount { param([string]$RunId)
    $n = 0
    foreach ($l in (Read-LedgerLines $RunId)) {
        $e = $null
        try { $e = $l | ConvertFrom-Json } catch { }
        if ($e -and -not $e.type) { $n++ }
    }
    return $n
}

Push-Location $Work
try {
    Assert-True $stubUp 'T0 stub endpoint up (liveness + /api receiver)' "port $port"

    # ================= TC-B127: reclaim in-place full chain (AC1 positive) =================
    $g1 = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $p1Full = "P1-FULLREPORT-MARKER-$g1.md"   # leaf report gates full_report on file existence: marker rides the filename
    $p1Verif = "P1-VERIF-MARKER-$g1 tail text for truncation safety"
    $p1Planner = "P1-PLANNERREF-MARKER-$g1"
    $arch1 = New-Archive 'iq-p1' '["DEV"]'
    Write-Utf8NoBom (Join-Path $Work (".rdd/changes/archive/iq-p1/$p1Full")) "# P1 failed-delivery report doc`n`nmarker fixture`n"
    $p1Full = ".rdd/changes/archive/iq-p1/$p1Full"
    $pf1 = Write-TestPlan (Join-Path $Work 'iq-p1-plan.json')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1)
    Assert-True ($r.json.success -eq $true) 'TC-B127 promulgate ok (push enabled)' ($r.raw)
    $run1 = 'deliver-iq-p1'
    $b1 = Read-BridgeJson $run1
    $d1 = [string]$b1.tasks.'1'.stages.DEV
    Assert-True ($d1 -ne '') 'TC-B127 DEV head grafted + auto-pushed' ($d1)
    $r = Do-Deliver $run1 $d1 'DEV' "$arch1/requirements/t1.md" 'failed' 'p1-orig' $p1Full $p1Verif
    Set-StubAlive @('p1-orig')
    $treeBefore = Read-TreeNodes $run1
    $sideBefore = Read-Sidecar $run1 $d1
    $reportsBefore = Get-LedgerReportCount $run1
    $creates1 = Get-StubCreateCount
    $apiRows1 = @(Get-StubApiRows).Count
    $null = Start-Sleep -Milliseconds 1200   # guarantee the redo clock ticks past the claim clock
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run1, '-NodeId', $d1, '-FailureRef', $p1Planner)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery-inplace') 'TC-B127 reclaim takes the in-place path (live sidecar session)' ($r.raw)
    Assert-True ([string]$r.json.data.node_id -eq $d1 -and [string]$r.json.data.session.id -eq 'p1-orig') 'TC-B127 same node + ORIGINAL session reported' ("node=$($r.json.data.node_id) sid=$($r.json.data.session.id)")
    $n1 = Find-TreeNode $run1 $d1
    Assert-True ([string]$n1.status -eq 'claimed' -and $null -eq $n1.reported_at -and [string]$n1.claimed_by -eq 'DEV' -and [int]$n1.steal_count -eq 0) 'TC-B127 node reported->claimed, holder kept, reported_at cleared, no steal' ("status=$($n1.status) by=$($n1.claimed_by) steal=$($n1.steal_count)")
    $treeAfter = Read-TreeNodes $run1
    Assert-True ($treeAfter.Count -eq $treeBefore.Count -and @($treeAfter | Where-Object { [string]$_.status -eq 'pruned' }).Count -eq 0) 'TC-B127 no prune / no rebuild (tree shape unchanged)' ("before=$($treeBefore.Count) after=$($treeAfter.Count)")
    Assert-True ((Get-StubCreateCount) -eq $creates1) 'TC-B127 zero new session.create (in-place = no cold start)' ("before=$creates1 after=$(Get-StubCreateCount)")
    $prompts1 = @(Get-StubPromptsTo 'p1-orig')
    Assert-True ($prompts1.Count -ge 1) 'TC-B127 redo pointer prompted into the ORIGINAL session' ("count=$($prompts1.Count)")
    $pText = if ($prompts1.Count -gt 0) { [string]$prompts1[-1].payload.content[0].text } else { '' }
    $hasInstr = ($pText -match 'goal-tree-leaf') -and ($pText -match "report -RunId $run1") -and ($pText -match $d1)
    Assert-True $hasInstr 'TC-B127 pointer carries the re-report instruction + node anchor' ($pText)
    Assert-True ($pText -match [regex]::Escape($p1Full) -and $pText -match [regex]::Escape($p1Verif.Substring(0, 20)) -and $pText -match [regex]::Escape($p1Planner)) 'TC-B127 pointer failure list flows from all three sources (four-check report full_report/verification + planner -FailureRef)' ($pText)
    $lastLedger1 = (Read-LedgerLines $run1)[-1] | ConvertFrom-Json
    Assert-True ([string]$lastLedger1.type -eq 'redo' -and [string]$lastLedger1.node_id -eq $d1 -and [string]$lastLedger1.session_id -eq 'p1-orig' -and [string]$lastLedger1.trigger -eq 'reclaim') 'TC-B127 ledger redo audit entry (node/session/trigger)' ((Read-LedgerLines $run1)[-1])
    Assert-True (([string]$lastLedger1.failure_ref) -match [regex]::Escape($p1Full) -and ([string]$lastLedger1.failure_ref) -match [regex]::Escape($p1Planner)) 'TC-B127 ledger redo failure_ref carries the failure-list reference' ([string]$lastLedger1.failure_ref)
    $sideAfter = Read-Sidecar $run1 $d1
    Assert-True ([string]$sideAfter.dsh_session_id -eq 'p1-orig' -and ([string]$sideAfter.claimed_at).Trim() -ne '' -and ([string]$sideAfter.claimed_at) -ne ([string]$sideBefore.claimed_at)) 'TC-B127 sidecar keeps dsh_session_id, claimed_at clock renewed' ("before=$($sideBefore.claimed_at) after=$($sideAfter.claimed_at)")
    $b1 = Read-BridgeJson $run1
    $att1 = $b1.pushes.$d1.attempts | Select-Object -Last 1
    Assert-True ([string]$att1.reused_session_id -eq 'p1-orig') 'TC-B127 push attempt records reused_session_id' (($att1 | ConvertTo-Json -Compress))
    $rosterRows1 = @(((Get-Content -LiteralPath (Join-Path $Work ".rdd/goal-trees/$run1/sessions.json") -Raw -Encoding UTF8 | ConvertFrom-Json).sessions) | Where-Object { [string]$_.source -eq 'bridge-dispatch' })
    $rowP1 = @($rosterRows1 | Where-Object { [string]$_.session_id -eq 'p1-orig' })
    Assert-True ($rowP1.Count -eq 1 -and [string]$rowP1[0].node -eq $d1) 'TC-B127 roster re-anchored onto the redo target session (advisory row, node binding refreshed)' (($rowP1 | ConvertTo-Json -Compress))
    Assert-True (@(Get-StubLivenessQueries "node=$d1").Count -ge 1) 'TC-B127 node-keyed registry probe consulted before the in-place decision' ''
    Assert-True (@(Get-StubApiRows).Count -eq ($apiRows1 + 1)) 'TC-B127 /api traffic during reclaim = the pointer prompt only (no create/workspace/preset churn)' ("before=$apiRows1 after=$(@(Get-StubApiRows).Count)")

    # TC-B138: redo audit row never inflates worker-report stats; goal-tree status still parses
    Assert-True ((Get-LedgerReportCount $run1) -eq $reportsBefore) 'TC-B138 ledger worker-report count unchanged by the redo audit row' ("before=$reportsBefore after=$(Get-LedgerReportCount $run1)")
    $r = Invoke-Tree @('-Command', 'status', '-RunId', $run1)
    Assert-True ($r.json.success -eq $true) 'TC-B138 goal-tree status parses with redo rows present' ($r.raw)

    # ================= TC-B128: re-report + settle round trip in the same session shape =================
    $r = Do-Report $run1 $d1 'DEV' "$arch1/requirements/t1.md" 'dev-ok'
    Assert-True ($r.json.success -eq $true) 'TC-B128 re-report after redo accepted (claimed node, same session shape)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run1, '-NodeId', $d1)
    Assert-True ($r.json.success -eq $true) 'TC-B128 settle after in-place redo round trip' ($r.raw)

    # ================= TC-B130: dead original session -> legacy fallback (AC2 negative) =================
    $arch2 = New-Archive 'iq-p2' '["DEV"]'
    $pf2 = Write-TestPlan (Join-Path $Work 'iq-p2-plan.json')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-PlanFile', $pf2)
    Assert-True ($r.json.success -eq $true) 'TC-B130 promulgate ok' ($r.raw)
    $run2 = 'deliver-iq-p2'
    $b2 = Read-BridgeJson $run2
    $d2 = [string]$b2.tasks.'1'.stages.DEV
    $r = Do-Deliver $run2 $d2 'DEV' "$arch2/requirements/t1.md" 'failed' 'p2-dead'   # NOT in the alive set
    $creates2 = Get-StubCreateCount
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run2, '-NodeId', $d2)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'TC-B130 dead session -> legacy rejected-delivery path' ($r.raw)
    Assert-True ([string]$r.json.data.fallback -eq 'dead' -and [string]$r.json.data.pruned_node -eq $d2 -and [string]$r.json.data.node_id -ne $d2) 'TC-B130 legacy shape: fallback reason + pruned old + grafted replacement' ($r.raw)
    $old2 = Find-TreeNode $run2 $d2
    $new2 = Find-TreeNode $run2 ([string]$r.json.data.node_id)
    Assert-True ([string]$old2.status -eq 'pruned' -and [string]$new2.status -eq 'pending') 'TC-B130 tree state: pruned old + pending replacement' ("old=$($old2.status) new=$($new2.status)")
    Assert-True ((Get-StubCreateCount) -gt $creates2 -and @(Get-StubPromptsTo 'p2-dead').Count -eq 0) 'TC-B130 replacement pushed via session.create, no prompt to the dead session' ("createDelta=$((Get-StubCreateCount)-$creates2)")
    $redo2 = @((Read-LedgerLines $run2) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count
    Assert-True ($redo2 -eq 0) 'TC-B130 no redo ledger entry on the fallback path' ("redo=$redo2")

    # ================= TC-B131: unreachable probe (liveness unknown) -> legacy fallback =================
    $arch3 = New-Archive 'iq-p3' '["DEV"]'
    $pf3 = Write-TestPlan (Join-Path $Work 'iq-p3-plan.json')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-PlanFile', $pf3)
    Assert-True ($r.json.success -eq $true) 'TC-B131 promulgate ok' ($r.raw)
    $run3 = 'deliver-iq-p3'
    $b3 = Read-BridgeJson $run3
    $d3 = [string]$b3.tasks.'1'.stages.DEV
    $r = Do-Deliver $run3 $d3 'DEV' "$arch3/requirements/t1.md" 'failed' 'p3-live'
    Set-StubAlive @('p3-live')
    $prevUrl = $env:DSH_WEB_URL
    $env:DSH_WEB_URL = 'http://127.0.0.1:1/'
    try {
        $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run3, '-NodeId', $d3)
        Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery' -and [string]$r.json.data.fallback -eq 'unknown') 'TC-B131 unreachable probe -> unknown -> legacy path (zero behavior change)' ($r.raw)
        $redo3 = @((Read-LedgerLines $run3) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count
        Assert-True ($redo3 -eq 0) 'TC-B131 no redo ledger entry' ("redo=$redo3")
    }
    finally { $env:DSH_WEB_URL = $prevUrl }

    # ================= TC-B129: no_push run in-place (tree-side lands, zero /api) =================
    $arch4 = New-Archive 'iq-p4' '["DEV"]'
    $pf4 = Write-TestPlan (Join-Path $Work 'iq-p4-plan.json')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch4 + '/task.json'), '-PlanFile', $pf4, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'TC-B129 no_push promulgate ok' ($r.raw)
    $run4 = 'deliver-iq-p4'
    $b4 = Read-BridgeJson $run4
    $d4 = [string]$b4.tasks.'1'.stages.DEV
    $r = Do-Deliver $run4 $d4 'DEV' "$arch4/requirements/t1.md" 'failed' 'p4-live'
    Set-StubAlive @('p4-live')
    $apiRows4 = @(Get-StubApiRows).Count
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run4, '-NodeId', $d4)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery-inplace' -and $r.json.data.no_push -eq $true) 'TC-B129 no_push in-place: tree-side path taken, no_push flagged' ($r.raw)
    $n4 = Find-TreeNode $run4 $d4
    Assert-True ([string]$n4.status -eq 'claimed') 'TC-B129 node still migrated reported->claimed' ("status=$($n4.status)")
    $lastLedger4 = (Read-LedgerLines $run4)[-1] | ConvertFrom-Json
    Assert-True ([string]$lastLedger4.type -eq 'redo') 'TC-B129 ledger redo entry present (tree-side actions land)'
    Assert-True (@(Get-StubApiRows).Count -eq $apiRows4) 'TC-B129 zero /api calls during the no_push reclaim (delivery skipped)' ("before=$apiRows4 after=$(@(Get-StubApiRows).Count)")
    Assert-True (([string]$r.json.data.next_step) -match 'no_push' -or ([string]$r.json.data.next_step) -match 'dispatch') 'TC-B129 next_step names the manual delivery path' ([string]$r.json.data.next_step)

    # ============ TC-B133/B134: rollback boundary + AutoDispatch roster reuse (AC3) ============
    $arch5 = New-Archive 'iq-p5' '["CTO"]'
    $pf5 = Write-TestPlan (Join-Path $Work 'iq-p5-plan.json')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5 + '/task.json'), '-PlanFile', $pf5)
    Assert-True ($r.json.success -eq $true) 'TC-B133 promulgate ok (CTO head chain)' ($r.raw)
    $run5 = 'deliver-iq-p5'
    $b5 = Read-BridgeJson $run5
    $c5 = [string]$b5.tasks.'1'.stages.CTO
    $r = Do-Deliver $run5 $c5 'CTO' "$arch5/requirements/t1.md" 'ok'
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run5, '-NodeId', $c5)
    Assert-True ($r.json.success -eq $true) 'TC-B133 CTO settle grafts + pushes the DEV node' ($r.raw)
    $b5 = Read-BridgeJson $run5
    $dev5 = [string]$b5.tasks.'1'.stages.DEV
    Assert-True ($dev5 -ne '') 'TC-B133 DEV node grafted after CTO settle' ($dev5)
    $r = Do-Deliver $run5 $dev5 'DEV' "$arch5/requirements/t1.md" 'dev-ok'
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run5, '-NodeId', $dev5)
    Assert-True ($r.json.success -eq $true) 'TC-B133 DEV settle grafts + pushes the QA node' ($r.raw)
    $b5 = Read-BridgeJson $run5
    $qa5 = [string]$b5.tasks.'1'.stages.QA
    Assert-True ($qa5 -ne '') 'TC-B133 QA node grafted after DEV settle (first QA push = fresh create)' ($qa5)
    # the QA session that received the first push (roster row for qa5)
    $qaSid = $null
    $roster5 = @(((Get-Content -LiteralPath (Join-Path $Work ".rdd/goal-trees/$run5/sessions.json") -Raw -Encoding UTF8 | ConvertFrom-Json).sessions))
    foreach ($s in $roster5) { if ([string]$s.node -eq $qa5) { $qaSid = [string]$s.session_id } }
    Assert-True ($null -ne $qaSid) 'TC-B133 roster row for the first QA push session' ('')
    $devSid = $null
    foreach ($s in $roster5) { if ([string]$s.node -eq $dev5) { $devSid = [string]$s.session_id } }
    Set-StubAlive @($devSid, $qaSid)   # BOTH prior sessions alive: rollback must still never reuse
    # QA verifies and REJECTS (verdict failed) -> rollback to DEV (cross-stage rebuild)
    $r = Do-Deliver $run5 $qa5 'QA' "$arch5/requirements/t1.md" 'failed' $qaSid
    $creates5 = Get-StubCreateCount
    $promptsDev5Before = @(Get-StubPromptsTo $devSid).Count
    $r = Invoke-Bridge @('-Command', 'rollback', '-RunId', $run5, '-NodeId', $qa5, '-To', 'DEV', '-Phase', 'IMPL', '-Reason', 'p5 rollback boundary check')
    Assert-True ($r.json.success -eq $true) 'TC-B134 rollback ok (QA reject -> back to DEV)' ($r.raw)
    Assert-True ((Get-StubCreateCount) -gt $creates5) 'TC-B134 rebuilt DEV node pushed via session.create (rollback NEVER reuses, alive DEV roster row present)' ("createDelta=$((Get-StubCreateCount)-$creates5)")
    Assert-True (@(Get-StubPromptsTo $devSid).Count -eq $promptsDev5Before) 'TC-B134 no new prompt into the OLD DEV session after rollback' ("before=$promptsDev5Before after=$(@(Get-StubPromptsTo $devSid).Count)")
    $b5 = Read-BridgeJson $run5
    $dev5b = [string]$b5.tasks.'1'.stages.DEV
    $att5 = $b5.pushes.$dev5b.attempts | Select-Object -Last 1
    Assert-True ($null -eq $att5.reused_session_id) 'TC-B134 rebuilt node push attempt carries no reused_session_id' (($att5 | ConvertTo-Json -Compress))
    # DEV redoes on the rebuilt node; settle -> the RE-VERIFY QA node must reuse the ORIGINAL QA session
    $r = Do-Deliver $run5 $dev5b 'DEV' "$arch5/requirements/t1.md" 'dev-ok' $qaSid   # session id irrelevant here
    $creates5b = Get-StubCreateCount
    $promptsQa5Before = @(Get-StubPromptsTo $qaSid).Count
    $live5Before = @(Get-StubLivenessQueries ([regex]::Escape("session_id=$qaSid"))).Count
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run5, '-NodeId', $dev5b)
    Assert-True ($r.json.success -eq $true) 'TC-B133 DEV re-settle grafts + pushes the re-verify QA node' ($r.raw)
    $b5 = Read-BridgeJson $run5
    $qa5b = [string]$b5.tasks.'1'.stages.QA
    Assert-True ($qa5b -ne '' -and $qa5b -ne $qa5) 'TC-B133 fresh re-verify QA node grafted' ("qa5b=$qa5b")
    Assert-True ((Get-StubCreateCount) -eq $creates5b) 'TC-B133 re-verify QA push reused the ORIGINAL QA session (no session.create)' ("createDelta=$((Get-StubCreateCount)-$creates5b)")
    Assert-True (@(Get-StubPromptsTo $qaSid).Count -eq ($promptsQa5Before + 1)) 'TC-B133 pointer delivered into the original QA session (exactly one new prompt)' ("before=$promptsQa5Before after=$(@(Get-StubPromptsTo $qaSid).Count)")
    $att5b = $b5.pushes.$qa5b.attempts | Select-Object -Last 1
    Assert-True ([string]$att5b.reused_session_id -eq $qaSid) 'TC-B133 re-verify push attempt records reused_session_id' (($att5b | ConvertTo-Json -Compress))
    Assert-True (@(Get-StubLivenessQueries ([regex]::Escape("session_id=$qaSid"))).Count -gt $live5Before) 'TC-B133 session-keyed registry probe consulted during reuse resolution (two-level liveness reuse)' ''

    # ================= TC-B135: manual dispatch reuse resolution (sidecar first) =================
    $r = Do-Claim $run5 $qa5b 'QA' $qaSid
    Assert-True ($r.json.success -eq $true) 'TC-B135 re-verify QA node claimed by the original session' ($r.raw)
    $r = Do-Report $run5 $qa5b 'QA' "$arch5/requirements/t1.md" 'failed'
    Assert-True ($r.json.success -eq $true) 'TC-B135 QA rejection report accepted (re-verify round 2)' ($r.raw)
    $g5 = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $p5Planner = "P5-PLANNERREF-MARKER-$g5"
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run5, '-NodeId', $qa5b, '-FailureRef', $p5Planner)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery-inplace' -and [string]$r.json.data.session.id -eq $qaSid) 'TC-B135 in-place redo lands in the QA session (same-session re-verify)' ($r.raw)
    $creates5c = Get-StubCreateCount
    $promptsQa5c = @(Get-StubPromptsTo $qaSid).Count
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', $run5, '-NodeId', $qa5b)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.reused_session_id -eq $qaSid) 'TC-B135 manual dispatch resolves the sidecar session (reuse)' ($r.raw)
    Assert-True ((Get-StubCreateCount) -eq $creates5c -and @(Get-StubPromptsTo $qaSid).Count -eq ($promptsQa5c + 1)) 'TC-B135 dispatch prompted the same session, no new create' ("createDelta=$((Get-StubCreateCount)-$creates5c)")

    # ================= TC-B137: -NoReuse escape hatch (reclaim + dispatch) =================
    $arch7 = New-Archive 'iq-p7' '["DEV"]'
    $pf7 = Write-TestPlan (Join-Path $Work 'iq-p7-plan.json')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-PlanFile', $pf7)
    Assert-True ($r.json.success -eq $true) 'TC-B137 promulgate ok' ($r.raw)
    $run7 = 'deliver-iq-p7'
    $b7 = Read-BridgeJson $run7
    $d7 = [string]$b7.tasks.'1'.stages.DEV
    $r = Do-Deliver $run7 $d7 'DEV' "$arch7/requirements/t1.md" 'failed' 'p7-live'
    Set-StubAlive @('p7-live')
    $creates7 = Get-StubCreateCount
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run7, '-NodeId', $d7, '-NoReuse')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery' -and [string]$r.json.data.fallback -eq 'no_reuse') 'TC-B137 reclaim -NoReuse -> legacy path even with a live session' ($r.raw)
    Assert-True ((Get-StubCreateCount) -gt $creates7 -and @(Get-StubPromptsTo 'p7-live').Count -eq 0) 'TC-B137 replacement via session.create, no prompt to the live session' ("createDelta=$((Get-StubCreateCount)-$creates7)")
    $redo7 = @((Read-LedgerLines $run7) | Where-Object { ($_ | ConvertFrom-Json).type -eq 'redo' }).Count
    Assert-True ($redo7 -eq 0) 'TC-B137 no redo ledger entry (-NoReuse)' ("redo=$redo7")
    # dispatch -NoReuse on run5's claimed node: fresh session despite the alive sidecar
    $creates7b = Get-StubCreateCount
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', $run5, '-NodeId', $qa5b, '-NoReuse')
    Assert-True ($r.json.success -eq $true -and $null -eq $r.json.data.reused_session_id) 'TC-B137 dispatch -NoReuse -> fresh session (reuse disabled)' ($r.raw)
    Assert-True ((Get-StubCreateCount) -gt $creates7b) 'TC-B137 dispatch -NoReuse used session.create' ("createDelta=$((Get-StubCreateCount)-$creates7b)")
    # round trip closure on run5 (settle after dispatch/-NoReuse noise: node still claimed by the QA session)
    $r = Do-Report $run5 $qa5b 'QA' "$arch5/requirements/t1.md" 'ok'
    Assert-True ($r.json.success -eq $true) 'TC-B135 QA re-report after in-place redo accepted' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', $run5, '-NodeId', $qa5b)
    Assert-True ($r.json.success -eq $true) 'TC-B133 settle closes the QA re-verify round trip' ($r.raw)

    # ================= TC-B132: CLI backend fallback + SESSION_REUSE_UNSUPPORTED =================
    $prevUrl6 = $env:DSH_WEB_URL
    Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue
    try {
        $arch6 = New-Archive 'iq-p6' '["DEV"]'
        $pf6 = Write-TestPlan (Join-Path $Work 'iq-p6-plan.json')
        $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6 + '/task.json'), '-PlanFile', $pf6, '-NoPush')
        Assert-True ($r.json.success -eq $true) 'TC-B132 CLI-shell no_push promulgate ok (zero backend)' ($r.raw)
        $run6 = 'deliver-iq-p6'
        $b6 = Read-BridgeJson $run6
        $d6 = [string]$b6.tasks.'1'.stages.DEV
        $r = Do-Deliver $run6 $d6 'DEV' "$arch6/requirements/t1.md" 'failed'
        $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $run6, '-NodeId', $d6)
        Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery' -and [string]$r.json.data.fallback -eq 'unknown') 'TC-B132 CLI shell -> unknown -> legacy path' ($r.raw)
        $out9 = & powershell -NoProfile -ExecutionPolicy Bypass -File $StartPs1 -Role DEV -TaskId 1 -ExistingSessionId sess-x 2>&1 | Out-String
        $code9 = $LASTEXITCODE
        Assert-True ($code9 -ne 0 -and $out9 -match 'SESSION_REUSE_UNSUPPORTED') 'TC-B132 start-role rejects -ExistingSessionId on a non-dsh backend' ($out9)
    }
    finally { $env:DSH_WEB_URL = $prevUrl6 }
}
finally {
    Pop-Location
    Stop-Stub
    if ($SavedSessionId) { $env:DSH_SESSION_ID = $SavedSessionId } else { Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue }
    if ($SavedWebUrl) { $env:DSH_WEB_URL = $SavedWebUrl } else { Remove-Item Env:\DSH_WEB_URL -ErrorAction SilentlyContinue }
    if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
}

# ================= TC-B136: planner-guide doc sync (AC4, static checks on the real repo) =================
$pg = Get-Content (Join-Path $RepoRoot 'rdd-engine\references\planner-guide.md') -Raw -Encoding UTF8
Assert-True ($pg -match [regex]::Escape('已 settle 的 report 不重复消费；规划者显式 redo 指令可将 reported 退回 claimed（同会话 + ledger 留痕）')) 'TC-B136 hard constraint 4 wording updated as specified' ''
Assert-True ($pg -match 'REDO_FAILURE_REF_MISSING' -and $pg -match 'RECLAIM_INPLACE_PROMPT_FAILED') 'TC-B136 troubleshooting rows for the new reclaim error codes' ''
$reclaimRow = [regex]::Match($pg, '\| 回收 \|`?[^\r\n]*').Value
Assert-True ($reclaimRow -match '-FailureRef' -and $reclaimRow -match '-NoReuse' -and $reclaimRow -match 'rejected-delivery') 'TC-B136 command panel reclaim row carries -FailureRef/-NoReuse + dual-path description' ($reclaimRow)
$dispatchRow = [regex]::Match($pg, '\| 调动 \|`?[^\r\n]*').Value
Assert-True ($dispatchRow -match '\[-NoReuse\]') 'TC-B136 command panel dispatch row carries [-NoReuse]' ($dispatchRow)
$settleRow = [regex]::Match($pg, '\| 流转 \|`?[^\r\n]*').Value
Assert-True ($settleRow -match '复用优先') 'TC-B136 command panel settle row mentions reuse-priority resolution' ($settleRow)

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("inplace-redo-qa probe: {0} passed, {1} failed" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Output ("FAIL  {0}   {1}" -f $_.name, $_.detail) }
    exit 1
}
exit 0

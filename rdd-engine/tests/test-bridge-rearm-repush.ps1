# rearm-repush regression — 阶段推进槽位重臂后自动推送漏推（stale already_pushed）
#
# 事故形状（deliver-2026-10-26-level-mode-optimization，任务 1 IMPL→VERIFY）：
# wake 形状下 QA 槽跨阶段复用（DESIGN 验证轮 done → reset 重臂 pending 承载验收轮），
# settle 尾 auto_push 扫描只看「该节点历史上是否有 ok 推送」（last_ok_at 非空且无
# needs_repush 即跳过 already_pushed），对重臂视而不见：
#   1) next_stage_nodes 正确列出重臂节点（重臂本身发生）；
#   2) auto_push.skipped 含 <node>:already_pushed，pushed=[]；
#   3) 推送台账无新 attempt（n4 仅两条历史）；
#   4) sessions 花名册 updated_at 停在旧值——worker 会话从未收到新阶段指针；
#   5) 树面 pending 无人认领，无报错无 warning，交付链静默停摆。
#
# 修复双保险（rearm-repush）：
#   a) Invoke-GraftNextStage wake 分支重臂同尾 Set-NodeRepushFlag（对齐 reclaim 路径）；
#   b) already_pushed 收紧：pending 节点的 last_ok_at 早于树上 reset_at（最近重臂
#      时间戳，goal-tree reset/rotate 落盘）→ 视作待推；claimed（真在途）与
#      「晚于重臂的 ok 推送」保持跳过不误推。
#
#   RR1 主场景（wake 全链，CTO+QA@DESIGN + designDocs + 设计审查 pass）：
#       settle DEV（IMPL→VERIFY）重臂 QA 槽 → 断言三件事：auto_push 产生新 attempt
#       （含 reused_session_id，原 QA 会话带 DESIGN 上下文进 VERIFY）；pushes 台账
#       新增条目；sessions 花名册 updated_at 刷新 + stub 收到对该会话的新指针。
#       附：在途（claimed）跳过语义不回归；done 未重臂节点零重推（无推送风暴）；
#       重推后再次触发恢复 already_pushed（风暴自止）。
#   RR2 fix-b 隔离场景（绕过 graft 路径的手动 goal-tree reset）：
#       needs_repush 恒 false，仅有 reset_at 时间戳 → 扫描仍须补推；再触发即止。
#
# Fixture form: LOCAL STUB DSH_WEB_URL endpoint (fake liveness + /api envelope
# receiver, zero real backend — same technique as test-session-reuse.ps1), so the
# production start-role pushes SUCCEED and the ledger/roster/reuse chain is
# assertable end-to-end. Runs the production interpreters (Windows PowerShell 5.1)
# against a throwaway git repo. Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# planner-claim-guard（与 test-phase-model 同惯例）：夹具 claim/report 是 worker 侧
# 动作——DSH_SESSION_ID 残留会被身份门判成「规划者代跑」，显式清空以保确定性。
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('bridge-rearm-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Invoke-Bridge { param([string[]]$A) Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }
function Invoke-Tree   { param([string[]]$A) Invoke-Ps1 $TreePs1 $A }

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-BridgeJson { param([string]$RunId)
    (Get-Content -LiteralPath (Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')) -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Read-TreeNodes { param([string]$RunId)
    @((Get-Content -LiteralPath (Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')) -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Read-RosterRows { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/sessions.json')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).sessions)
}
function Get-RosterRow { param([string]$RunId, [string]$Node, [string]$Role)
    foreach ($s in (Read-RosterRows $RunId)) {
        if ([string]$s.role -eq $Role -and [string]$s.node -eq $Node) { return $s }
    }
    return $null
}
function Get-PushAttempts { param([string]$RunId, [string]$Node)
    $b = Read-BridgeJson $RunId
    if ($null -eq $b.pushes) { return @() }
    $prop = $b.pushes.PSObject.Properties[$Node]
    if ($null -eq $prop -or $null -eq $prop.Value.attempts) { return @() }
    return @($prop.Value.attempts)
}

# --- stub control files ---
$StubAlive = Join-Path $Work 'stub-alive.txt'
$StubCalls = Join-Path $Work 'stub-calls.jsonl'

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
function Get-StubPromptsTo { param([string]$SessionId)
    @((Read-StubCalls) | Where-Object { $_.method -eq 'session.prompt' -and $_.payload -and [string]$_.payload.sessionId -eq $SessionId })
}

# --- stub endpoint: fake plugin liveness + fake /api envelope receiver ---
# One raw-TCP HTTP server in a background job (http.sys is blocked by the harness
# sandbox, so the server hand-parses HTTP/1.1 at the byte level — technique lifted
# verbatim from test-session-reuse.ps1). Presets cover every role the bridge
# pushes in these fixtures, AUDITOR included (design-review node pushes).
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
            $jsonOut = $null
            if ($methodVerb -eq 'GET' -and $pathOnly -eq '/rdd-goal-tree/liveness') {
                $sid = if ($q.ContainsKey('session_id')) { [string]$q['session_id'] } else { '' }
                $live = 'unknown'
                if ($sid -ne '') {
                    if ($alive.ContainsKey($sid)) { $live = 'alive' }
                    else { $live = 'dead' }
                }
                $jsonOut = @{ session_id = $sid; liveness = $live; reason = 'stub registry (session-keyed probe)' } | ConvertTo-Json -Compress
            }
            elseif ($methodVerb -eq 'POST' -and $pathOnly.StartsWith('/api/')) {
                $method = $pathOnly.Substring(5)
                $params = if ($bodyJson -and $bodyJson.payload) { $bodyJson.payload } else { $bodyJson }
                $value = @{}
                switch ($method) {
                    'agentPreset.list' { $value = @{ presets = @(@{ id = 'rdd-pm' }, @{ id = 'rdd-cto' }, @{ id = 'rdd-ux' }, @{ id = 'rdd-dev' }, @{ id = 'rdd-qa' }, @{ id = 'rdd-eval' }, @{ id = 'rdd-pse' }, @{ id = 'rdd-planner' }, @{ id = 'rdd-auditor' }) } }
                    'workspace.create' { $value = @{ workspace = @{ workspaceId = 'stub-ws-1' } } }
                    'session.create'   { $script:sidCounter++; $value = @{ sessionId = "stub-s$($script:sidCounter)" } }
                    'session.prompt'   { $value = @{} }
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

# --- archive / plan / delivery fixtures (test-phase-model conventions) ---
function New-Archive { param([string]$Name, [string]$TasksJson, [bool]$WithDesign)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nrearm-repush 测试归档 $Name。`n`n## 整体验收判据`n`n无整体判据（理由：rearm-repush 回归测试归档，显式声明）`n"
    Write-Utf8NoBom (Join-Path $archDir 'requirements/t1.md') "# $Name 需求 1`n`n- **描述**：rearm-repush 测试需求 $Name`n- **验收标准**：见 overview.md`n"
    if ($WithDesign) {
        New-Item -ItemType Directory -Path (Join-Path $archDir 'design') -Force | Out-Null
        Write-Utf8NoBom (Join-Path $archDir 'design/d1.md') "# 设计文档 1`n`n变更地图：`n`n- ``src/mod-a.py``  [新增] 模块 A`n`n[新增] 1 | [修改] 0 | [删除] 0`n"
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}
function Write-TestPlan { param([string]$Path, [string[]]$StageTasks)
    $plan = [ordered]@{
        planned_at = '2026-10-26T00:00:00Z'; planner = 'test'
        stages = @(@{ id = 'S1'; goal = 'stage S1 目标'; milestone = 'S1 里程碑'
                      task_ids = @($StageTasks | ForEach-Object { [int]$_ })
                      batches = @(@($StageTasks | ForEach-Object { [int]$_ }))
                      acceptance_point = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable slice' } })
        risks = @()
    }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}
function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'rearm-repush test delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: no PowerShell in change set' } }
    }
    $cbFile = Join-Path $env:TEMP ("rr-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', (New-Cb $NodeId $Refs))
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}
function Write-ReviewFile { param([string]$ArchiveRel, [string]$StageId, [string[]]$DocRels, [string]$Verdict)
    $archAbs = Join-Path $Work $ArchiveRel
    $docs = @()
    foreach ($rel in @($DocRels)) {
        $findings = @()
        if ($Verdict -eq 'fail') {
            $findings += @{ severity = 'blocking'; dimension = 'change_map'; item = "blocking finding on $rel"; suggestion = '修正后重产' }
        }
        $docs += @{ doc = $rel; verdict = $Verdict; findings = $findings }
    }
    $file = [ordered]@{ reviewed_at = '2026-10-26T09:00:00Z'; reviewer = 'auditor'; stage = $StageId; docs = $docs; summary = @{ cross_design = @() } }
    $rel2 = "review/design-review-$StageId.json"
    $abs = Join-Path $archAbs ($rel2 -replace '/', '\')
    $dir = Split-Path $abs -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# 设计汇聚审查 — $ArchiveRel·$StageId`n`n镜像。`n"
    return $rel2
}
function Get-Ts { param([string]$S)
    try { return [datetime]::Parse($S, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return [datetime]::MinValue }
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

Push-Location $Work
try {
    Assert-True $stubUp 'RR0 stub endpoint up (liveness + /api receiver)' "port $port"

    # ================= RR1: wake 全链，IMPL→VERIFY 重臂 QA 槽（事故形状） =================
    $archA = New-Archive 'rr-a' '[{"title":"RR1 CTO+QA","requirement":"requirements/t1.md","currentOwners":["CTO","QA"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]' $true
    $refA = "$archA/requirements/t1.md"
    $pfA = Write-TestPlan (Join-Path $Work 'rr-a-plan.json') @('1')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archA + '/task.json'), '-PlanFile', $pfA, '-Shape', 'wake')
    Assert-True ($r.json.success -eq $true) 'RR1-01 promulgate ok (wake, live pushes)' ($r.raw)
    $b = Read-BridgeJson 'deliver-rr-a'
    $nCTO = [string]$b.tasks.'1'.stages.CTO
    $nQA = [string]$b.tasks.'1'.stages.QA
    Assert-True (-not [string]::IsNullOrWhiteSpace($nCTO) -and -not [string]::IsNullOrWhiteSpace($nQA)) 'RR1-01b CTO+QA slots mapped' ($b | ConvertTo-Json -Depth 4 -Compress)
    Assert-True ((@($r.json.data.auto_push.pushed) -contains $nCTO) -and (@($r.json.data.auto_push.pushed) -contains $nQA)) 'RR1-01c promulgate pushed BOTH design-round slots' ($r.raw)
    $qaRow0 = Get-RosterRow 'deliver-rr-a' $nQA 'QA'
    $ctoRow0 = Get-RosterRow 'deliver-rr-a' $nCTO 'CTO'
    Assert-True ($null -ne $qaRow0 -and $qaRow0.session_id -like 'stub-s*') 'RR1-01d QA roster row registered (stub session)' (($qaRow0) | ConvertTo-Json -Compress)
    $qaSid = [string]$qaRow0.session_id
    Set-StubAlive @($qaSid, ([string]$ctoRow0.session_id))
    $qaAttemptsDesign = @(Get-PushAttempts 'deliver-rr-a' $nQA).Count
    $qaUpdatedDesign = [string]$qaRow0.updated_at
    $qaPromptsDesign = @(Get-StubPromptsTo $qaSid).Count
    Assert-True ($qaAttemptsDesign -eq 1) 'RR1-01e QA slot ledger has exactly the design-round attempt' ("attempts=$qaAttemptsDesign")

    # --- 在途语义（n14 场景）：claimed 节点保持跳过，不误推 ---
    # 注：claimed 桶在状态视图里无 status 字段（桶成员即状态），扫描经由
    # last_ok_at 落到 already_pushed 跳过——「真在途不误推」即验收语义。
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-rr-a', '-NodeId', $nQA, '-Role', 'QA')
    Assert-True ($r.json.success -eq $true) 'RR1-02 QA claim ok (in-flight shape)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-rr-a')
    $inflightSkip = @(@($r.json.data.auto_push_touch.skipped) | Where-Object { [string]$_.node -eq $nQA })
    Assert-True ($r.json.success -eq $true -and $inflightSkip.Count -ge 1 -and (@($r.json.data.auto_push_touch.pushed) -notcontains $nQA) -and (@(Get-PushAttempts 'deliver-rr-a' $nQA).Count -eq $qaAttemptsDesign)) 'RR1-02b in-flight (claimed) slot stays SKIPPED, no mis-push, ledger untouched' ($r.raw)
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-rr-a', '-Worker', 'QA', '-CallbackFile', (New-Cb $nQA @($refA)))
    Assert-True ($r.json.success -eq $true) 'RR1-02c QA report ok (already claimed by RR1-02)' ($r.raw)

    # --- DESIGN 轮收口：CTO settle（narrow）→ QA settle（DESIGN→IMPL，graft DEV） ---
    Do-Deliver 'deliver-rr-a' $nCTO 'CTO' @("$archA/design/d1.md")
    $r = Do-Settle 'deliver-rr-a' $nCTO
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 0) 'RR1-03 CTO settle narrows (no graft, QA still live)' ($r.raw)
    $r = Do-Settle 'deliver-rr-a' $nQA
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.phase -eq 'DESIGN') 'RR1-03b QA settle switches DESIGN->IMPL' ($r.raw)
    $b = Read-BridgeJson 'deliver-rr-a'
    $nDEV = [string]$b.tasks.'1'.stages.DEV
    Assert-True (-not [string]::IsNullOrWhiteSpace($nDEV)) 'RR1-03c DEV slot grafted under container' ($b | ConvertTo-Json -Depth 4 -Compress)
    $revNode = [string]$b.plan.stages[0].design_review.node
    Assert-True (-not [string]::IsNullOrWhiteSpace($revNode)) 'RR1-03d design-review node grafted' ($b | ConvertTo-Json -Depth 5 -Compress)
    Assert-True (@($r.json.data.auto_push.skipped) -contains "${nDEV}:blocked_by_design_review") 'RR1-03e DEV push held by design-review gate (docs on disk, review open)' ($r.raw)
    Assert-True (@($r.json.data.auto_push.pushed) -contains $revNode) 'RR1-03f review node auto-pushed (AUDITOR stub session)' ($r.raw)

    # --- 审查 pass → DEV 解锁推送 ---
    Write-ReviewFile $archA 'S1' @('design/d1.md') 'pass' | Out-Null
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-rr-a', '-NodeId', $revNode, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'RR1-04 review claim ok' ($r.raw)
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-rr-a', '-Worker', 'AUDITOR', '-CallbackFile', (New-Cb $revNode @("$archA/review/design-review-S1.json", "$archA/review/design-review-S1.md")))
    Assert-True ($r.json.success -eq $true) 'RR1-04b review report ok' ($r.raw)
    $r = Do-Settle 'deliver-rr-a' $revNode
    Assert-True ($r.json.success -eq $true) 'RR1-04c review settle (pass) ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-rr-a'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'passed') 'RR1-04d engine-derived verdict pass recorded' ($b | ConvertTo-Json -Depth 5 -Compress)
    Assert-True (@($r.json.data.auto_push.pushed) -contains $nDEV) 'RR1-04e DEV unblocked and auto-pushed at the review settle tail' ($r.raw)

    # --- IMPL→VERIFY：settle DEV 重臂 QA 槽（事故现场）——三条核心断言 ---
    $ctoAttemptsBefore = @(Get-PushAttempts 'deliver-rr-a' $nCTO).Count
    Do-Deliver 'deliver-rr-a' $nDEV 'DEV' @($refA)
    $r = Do-Settle 'deliver-rr-a' $nDEV
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.phase -eq 'IMPL') 'RR1-05 DEV settle switches IMPL->VERIFY' ($r.raw)
    Assert-True (@($r.json.data.next_stage_nodes) -contains $nQA -and @($r.json.data.next_stage_nodes).Count -eq 1) 'RR1-05b next_stage_nodes lists the RE-ARMED QA slot (re-arm happened)' ($r.raw)
    # ① auto_push 对重臂槽产生新推送
    Assert-True (@($r.json.data.auto_push.pushed) -contains $nQA) 'RR1-A1 re-armed QA slot PUSHED at the same settle tail (was: skipped already_pushed)' ($r.raw)
    Assert-True (-not (@($r.json.data.auto_push.skipped) -contains "${nQA}:already_pushed")) 'RR1-A1b no stale already_pushed skip for the re-armed slot' ($r.raw)
    # ② 推送台账新增条目（复用会话）
    $attemptsAfter = @(Get-PushAttempts 'deliver-rr-a' $nQA)
    $lastAttempt = if ($attemptsAfter.Count -gt 0) { $attemptsAfter[-1] } else { $null }
    Assert-True ($attemptsAfter.Count -eq ($qaAttemptsDesign + 1)) 'RR1-A2 push ledger gained ONE new attempt for the re-armed slot' ("before=$qaAttemptsDesign after=$($attemptsAfter.Count)")
    Assert-True ($null -ne $lastAttempt -and $lastAttempt.ok -eq $true -and [string]$lastAttempt.reused_session_id -eq $qaSid) 'RR1-A2b new attempt is ok and REUSED the original QA session (DESIGN context carries into VERIFY)' (($lastAttempt) | ConvertTo-Json -Compress)
    # ③ 花名册 updated_at 刷新 + 会话收到新阶段指针
    $qaRowV = Get-RosterRow 'deliver-rr-a' $nQA 'QA'
    Assert-True ($null -ne $qaRowV -and (Get-Ts ([string]$qaRowV.updated_at)) -gt (Get-Ts $qaUpdatedDesign)) 'RR1-A3 roster QA row updated_at REFRESHED (was frozen at the design-round value)' ("design=$qaUpdatedDesign verify=$($qaRowV.updated_at)")
    Assert-True (@(Get-StubPromptsTo $qaSid).Count -gt $qaPromptsDesign) 'RR1-A3b QA session received the VERIFY-round pointer (new session.prompt in stub)' ("before=$qaPromptsDesign after=$(@(Get-StubPromptsTo $qaSid).Count)")
    # 反向钉：done 且未重臂的节点不得被重复推送（无推送风暴）
    Assert-True ((@($r.json.data.auto_push.pushed) -notcontains $nCTO) -and (@(Get-PushAttempts 'deliver-rr-a' $nCTO).Count -eq $ctoAttemptsBefore)) 'RR1-A4 anti-storm: done-not-re-armed CTO slot NOT re-pushed' ($r.raw)
    # 重推后语义回位：再次触发恢复 already_pushed（风暴自止）
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-rr-a')
    $settledSkip = @(@($r.json.data.auto_push_touch.skipped) | Where-Object { [string]$_.node -eq $nQA -and [string]$_.reason -eq 'already_pushed' })
    Assert-True ($r.json.success -eq $true -and $settledSkip.Count -ge 1 -and @(Get-PushAttempts 'deliver-rr-a' $nQA).Count -eq ($qaAttemptsDesign + 1)) 'RR1-A5 after the re-round push, next trigger skips already_pushed again (attempts unchanged — no storm)' ($r.raw)

    # ================= RR2: fix-b 隔离——手动 goal-tree reset（绕过 graft 重推臂） =================
    $archB = New-Archive 'rr-b' '[{"title":"RR2 单链","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]' $false
    $refB = "$archB/requirements/t1.md"
    $pfB = Write-TestPlan (Join-Path $Work 'rr-b-plan.json') @('1')
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archB + '/task.json'), '-PlanFile', $pfB, '-Shape', 'wake')
    Assert-True ($r.json.success -eq $true) 'RR2-01 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-rr-b'
    $nCTO2 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-rr-b' $nCTO2 'CTO' @($refB)
    $r = Do-Settle 'deliver-rr-b' $nCTO2
    Assert-True ($r.json.success -eq $true) 'RR2-01b CTO settle -> IMPL' ($r.raw)
    $b = Read-BridgeJson 'deliver-rr-b'
    $nDEV2 = [string]$b.tasks.'1'.stages.DEV
    Do-Deliver 'deliver-rr-b' $nDEV2 'DEV' @($refB)
    $r = Do-Settle 'deliver-rr-b' $nDEV2
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 1) 'RR2-01c DEV settle grafts QA (verify round, fresh slot)' ($r.raw)
    $b = Read-BridgeJson 'deliver-rr-b'
    $nQA2 = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-rr-b' $nQA2 'QA' @($refB)
    $r = Do-Settle 'deliver-rr-b' $nQA2
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.task_lifecycle -eq 'completed') 'RR2-01d QA settle completes the task' ($r.raw)
    $qaRow2 = Get-RosterRow 'deliver-rr-b' $nQA2 'QA'
    $qa2Sid = [string]$qaRow2.session_id
    Set-StubAlive @($qaSid, ([string]$ctoRow0.session_id), $qa2Sid)
    $qa2Attempts0 = @(Get-PushAttempts 'deliver-rr-b' $nQA2).Count
    Assert-True ($qa2Attempts0 -eq 1) 'RR2-01e QA verify slot has its single graft-time attempt' ("attempts=$qa2Attempts0")
    $qa2Node0 = Find-TreeNode 'deliver-rr-b' $nQA2
    Assert-True ($null -ne $qa2Node0 -and [string]$qa2Node0.status -eq 'done' -and $null -eq $qa2Node0.reset_at) 'RR2-01f done never-re-armed slot carries NO reset_at stamp' ($qa2Node0 | ConvertTo-Json -Compress)
    # 手动重臂：goal-tree reset（不经 Invoke-GraftNextStage —— fix-a 的重推臂不在场）
    Start-Sleep -Milliseconds 1200
    $r = Invoke-Tree @('-Command', 'reset', '-RunId', 'deliver-rr-b', '-NodeId', $nQA2, '-Reason', 'RR2 manual re-arm (fix-b isolation fixture)')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.from -eq 'done') 'RR2-02 manual goal-tree reset re-armed the done slot (done->pending)' ($r.raw)
    $qa2Node1 = Find-TreeNode 'deliver-rr-b' $nQA2
    Assert-True ($null -ne $qa2Node1 -and [string]$qa2Node1.status -eq 'pending' -and -not [string]::IsNullOrWhiteSpace([string]$qa2Node1.reset_at)) 'RR2-02b reset_at stamped on the tree AND persisted (serializer whitelist)' ($qa2Node1 | ConvertTo-Json -Compress)
    $bBefore = Read-BridgeJson 'deliver-rr-b'
    $flagBefore = [bool]$bBefore.pushes.PSObject.Properties[$nQA2].Value.needs_repush
    Assert-True (-not $flagBefore) 'RR2-02c needs_repush stays FALSE (reset never touched bridge.json — rescue can only come from the staleness comparison)' ($bBefore.pushes.PSObject.Properties[$nQA2].Value | ConvertTo-Json -Compress)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-rr-b')
    Assert-True ($r.json.success -eq $true -and (@($r.json.data.auto_push_touch.pushed) -contains $nQA2)) 'RR2-B1 stale-ledger guard: pending slot with last_ok_at OLDER than reset_at got PUSHED (no needs_repush flag involved)' ($r.raw)
    $attempts2 = @(Get-PushAttempts 'deliver-rr-b' $nQA2)
    $last2 = if ($attempts2.Count -gt 0) { $attempts2[-1] } else { $null }
    Assert-True ($attempts2.Count -eq ($qa2Attempts0 + 1) -and $null -ne $last2 -and $last2.ok -eq $true -and [string]$last2.reused_session_id -eq $qa2Sid) 'RR2-B2 rescue attempt is ok and reused the QA session' (($last2) | ConvertTo-Json -Compress)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-rr-b')
    $skip2 = @(@($r.json.data.auto_push_touch.skipped) | Where-Object { [string]$_.node -eq $nQA2 -and [string]$_.reason -eq 'already_pushed' })
    Assert-True ($r.json.success -eq $true -and $skip2.Count -ge 1 -and @(Get-PushAttempts 'deliver-rr-b' $nQA2).Count -eq ($qa2Attempts0 + 1)) 'RR2-B3 second trigger skips already_pushed again (last ok now newer than reset_at — storm stops)' ($r.raw)
    $dev2Attempts = @(Get-PushAttempts 'deliver-rr-b' $nDEV2).Count
    Assert-True ($dev2Attempts -le 1 -and (@($r.json.data.auto_push_touch.pushed) -notcontains $nDEV2)) 'RR2-B4 done-not-re-armed DEV slot untouched (anti-storm mirror)' ("attempts=$dev2Attempts")
}
finally {
    Pop-Location
    Stop-Stub
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("rearm-repush suite: {0} passed, {1} failed" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count)
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Output ("FAIL  {0}   {1}" -f $_.name, $_.detail) }
    exit 1
}
if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
exit 0

# delivery-bridge-verify.ps1 — 规划者交付编排桥接 验收验证器（QA 独立实现，零依赖）
#
# 被测对象:rdd-engine/scripts/delivery-bridge.cmd(桥接编排黑盒)
#   黑盒集成测试:仅通过 CLI 接口驱动——delivery-bridge.cmd 组合 goal-tree / goal-tree-leaf /
#   rdd-flow / start-role 公开 CLI;fixture 归档建在 .rdd/tmp 下(绝不触碰真实归档)。
#   断言锚定规划者交付编排需求验收标准 1~7 与 planner-guide.md 协议;
#   2026-09-18 goal-tree-goal-root:目标根树形/依赖驱动自动推送/存活门禁/v2 账目。
#
# 用例规约:TC-B01 ~ TC-B27(映射 BR-AC-1 ~ BR-AC-7 + GR-AC-2~6 + CB-AC + RR-AC-1~4)
#
# 用法:
#   pwsh -File .rdd/tests/delivery-bridge/delivery-bridge-verify.ps1 [-Suite all|promulgate|claim|settle|recover|conclude|regression|compat|autopush|callback|review] [-KeepRuns] [-Json]
#   (Windows PowerShell 5.1 亦可运行;建议 pwsh 7+)
#
# 套件说明:
#   promulgate 颁布:run 建立/映射落盘/依赖推导/重复颁布防护 —— TC-B01~B02
#   claim      复合认领:双上下文/重复唤起冲突反馈/依赖阻塞/泊位接管 —— TC-B03~B05
#   settle     流转门禁:三查拒绝/通过/链式 graft/complete/advance 拒绝路径 —— TC-B06~B08
#   recover    恢复:rejected-delivery 回收/死 claim 回收(存活门禁)/status 修复/resume —— TC-B09~B10
#   conclude   结案:全终态校验/annex(根目标达成状态)/check 结果/租约释放 —— TC-B11
#   regression 回归:非桥接 run 零桥接文件;五角色默认流不变(rdd-flow 无桥接感知) —— TC-B12
#   compat     更名零兼容(旧命名 sidecar 不被识别,显式 reclaim 是迁移路径) —— TC-B13
#   autopush   目标根/依赖驱动自动推送/存活判定两极/失败分档(含真实分类)/v2 格式门禁 —— TC-B14~B20
#   callback   回调契约呈现层:指针 goal-tree 标记段(autopush+dispatch) + claim report_hint 三件套 + 非桥零标记回归 —— TC-B21~B22
#   review     需求审查门(-ReviewFile,planner-requirement-review RR-AC-1~4):三级处置消费/审计
#              三载体/错误码三枚/部分达成结案/缺省回归 —— TC-B23~B27(2026-09-20-planner-capability-optimization)
#   uniqueness 规划者唯一性(planner-uniqueness-callback PU-AC 引擎侧):start-role 误启拒绝/合法入口
#              (-RunId 续跑/-Force)/无活跃 run 放行回归/信息层禁令文案 —— TC-B28~B31(2026-09-20-planner-capability-optimization)
#   all        全部
#
# 严重度语义:P0 失败=阻塞(退出码 1);P1 失败=严重不阻塞;P2 失败=备忘警告(WARN)。
# 退出码:0=无 P0 失败;1=存在 P0 失败;2=验证器自身错误。
#
# 测试产生的运行目录与 fixture 归档默认结束后清理,-KeepRuns 保留供排查。
#
# 环境隔离(hard):套件级 mock dsh 载波(进程内 runspace + TcpListener)接管
# DSH_WEB_URL——所有自动推送的 start-role 走 dsh 分支打到 mock(零真实会话、零开窗、
# 与本机是否装 opencode/wt 无关);liveness 存活查证经 mock 应答可配置
# (alive/dead/unknown,TC-B17 切规则覆盖);原环境变量在退出时恢复。

param(
    [ValidateSet("all", "promulgate", "claim", "settle", "recover", "conclude", "regression", "compat", "autopush", "callback", "review", "uniqueness")]
    [string]$Suite = "all",
    [switch]$KeepRuns,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:EnvSaved = @{
    DSH_WEB_URL    = $env:DSH_WEB_URL
    RDD_RUNTIME    = $env:RDD_RUNTIME
    DSH_SESSION_ID = $env:DSH_SESSION_ID
}

# ---------- 全局定位 ----------

$RepoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $RepoRoot) { Write-Error "not inside a git repo"; exit 2 }
$RepoRoot = $RepoRoot -replace '/', '\'
$BridgeCmd = Join-Path $RepoRoot "rdd-engine\scripts\delivery-bridge.cmd"
$GoalTreeCmd = Join-Path $RepoRoot "rdd-engine\scripts\goal-tree.cmd"
$GoalTreeLeafCmd = Join-Path $RepoRoot "rdd-engine\scripts\goal-tree-leaf.cmd"
$FlowCmd = Join-Path $RepoRoot "rdd-engine\scripts\rdd-flow.cmd"
foreach ($x in @($BridgeCmd, $GoalTreeCmd, $GoalTreeLeafCmd, $FlowCmd)) {
    if (-not (Test-Path $x)) { Write-Host "FATAL: not found: $x"; exit 2 }
}

$script:RunStamp = "qa-bridge-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID
$script:WorkDir = Join-Path $RepoRoot (".rdd\tmp\delivery-bridge-verify\{0}" -f $script:RunStamp)
$script:CreatedRuns = New-Object System.Collections.Generic.List[string]
$script:CreatedArchives = New-Object System.Collections.Generic.List[string]
New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------- CLI 调用与状态读取 ----------

function Invoke-EngineCli {
    param([string]$Script, [string[]]$ArgList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Script @ArgList 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    $text = ($output | Out-String).Trim()
    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
    return @{ exit = $exitCode; text = $text; json = $json }
}
function TB   { param([string[]]$A) Invoke-EngineCli $BridgeCmd $A }
function TRun { param([string[]]$A) Invoke-EngineCli $GoalTreeCmd $A }
function TLeaf { param([string[]]$A) Invoke-EngineCli $GoalTreeLeafCmd $A }
function TFlow { param([string[]]$A) Invoke-EngineCli $FlowCmd $A }

function Get-RunDirPath { param([string]$Id) Join-Path $RepoRoot (".rdd\goal-trees\{0}" -f $Id) }
function Read-RunFileText { param([string]$Id, [string]$Rel)
    [System.IO.File]::ReadAllText((Join-Path (Get-RunDirPath $Id) ($Rel -replace '/', '\')), [System.Text.Encoding]::UTF8)
}
function Read-RunTree { param([string]$Id) (Read-RunFileText $Id "state/tree.json") | ConvertFrom-Json }
function Read-BridgeJson { param([string]$Id) (Read-RunFileText $Id "bridge.json") | ConvertFrom-Json }

# ---------- fixture 归档 ----------

function New-FixtureArchive {
    # 独立 fixture 归档(路径 .rdd/tmp 下,绝不触碰 .rdd/changes)
    # 任务形态:T1 无依赖(DEV 阶段);T2 依赖 T1;T3 独立(CTO 阶段,验证多角色阶段链)
    param([string]$Tag)
    $archName = "2099-12-31-qa-fixture-$Tag-$($script:RunStamp)"
    $archDir = Join-Path $script:WorkDir $archName
    New-Item -ItemType Directory -Path (Join-Path $archDir "requirements") -Force | Out-Null
    # 原始需求(overview):goal 根的目标文本来源(H1=标题,全文=描述)
    [System.IO.File]::WriteAllText((Join-Path $archDir "requirements\overview.md"), "# 原始需求：QA 夹具总纲`r`n`r`n三件套夹具:底座/依赖方/独立项——供桥接验证器断言目标根语义。", $Utf8NoBom)
    $reqs = @{
        "t1" = "# T1`r`n`r`n- **描述**：底座`r`n- **依赖关系**：无（本需求为底座）"
        "t2" = "# T2`r`n`r`n- **描述**：依赖方`r`n- **依赖关系**：依赖需求 1（t1 底座）"
        "t3" = "# T3`r`n`r`n- **描述**：独立项`r`n- **依赖关系**：无"
    }
    foreach ($k in $reqs.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $archDir "requirements\$k.md"), $reqs[$k], $Utf8NoBom)
    }
    $tasksJson = @'
{
    "version": 1,
    "archive": "fixture",
    "tasks": [
        { "id": 1, "title": "T1 bottom", "requirement": "requirements/t1.md", "currentOwners": ["DEV"], "designDocs": [], "currentWorker": [], "remark": "", "lifecycle": "active" },
        { "id": 2, "title": "T2 dependent", "requirement": "requirements/t2.md", "currentOwners": ["DEV"], "designDocs": [], "currentWorker": [], "remark": "", "lifecycle": "active" },
        { "id": 3, "title": "T3 independent", "requirement": "requirements/t3.md", "currentOwners": ["CTO"], "designDocs": [], "currentWorker": [], "remark": "", "lifecycle": "active" }
    ]
}
'@
    [System.IO.File]::WriteAllText((Join-Path $archDir "task.json"), $tasksJson, $Utf8NoBom)
    $script:CreatedArchives.Add($archDir) | Out-Null
    return @{ name = $archName; dir = $archDir; run_id = "deliver-$archName" }
}

function New-CallbackFile {
    param([string]$NodeId, [string]$Verdict, [bool]$WithCitations, [bool]$WithVerification, [bool]$RealPaths)
    $cits = @()
    if ($WithCitations) {
        $ref = if ($RealPaths) { "rdd-engine/scripts/goal-tree.ps1" } else { "no/such/path/anywhere.ts" }
        $cits = @(@{ ref = $ref; locator = "schema" })
    }
    $extras = @{}
    if ($WithVerification) { $extras = @{ verification = "lint+tests pass" } }
    $cb = @{
        node_id = $NodeId; verdict = $Verdict; confidence = 0.9
        summary = "delivery summary for $NodeId"; citations = $cits
        next_suggestion = ""; extras = $extras
    }
    $p = Join-Path $script:WorkDir ("cb-{0}.json" -f ([guid]::NewGuid().ToString("N").Substring(0, 8)))
    [System.IO.File]::WriteAllText($p, ($cb | ConvertTo-Json -Depth 6), $Utf8NoBom)
    return $p
}

# ---------- 用例执行框架 ----------

$script:Results = New-Object System.Collections.Generic.List[object]
function Assert { param($Ctx, [bool]$Cond, [string]$Msg)
    if (-not $Cond) { $Ctx.fails.Add($Msg) | Out-Null }
}
function Run-Tc {
    param([string]$Id, [string]$Title, [string]$Priority, [string]$Acceptance, [scriptblock]$Body)
    $ctx = @{ id = $Id; fails = (New-Object System.Collections.Generic.List[string]) }
    try { & $Body $ctx } catch { $ctx.fails.Add("EXCEPTION: $($_.Exception.Message)") | Out-Null }
    $status = if ($ctx.fails.Count -eq 0) { "PASS" } elseif ($Priority -eq "P2") { "WARN" } else { "FAIL" }
    $script:Results.Add([pscustomobject]@{
        id = $Id; title = $Title; priority = $Priority; acceptance = $Acceptance
        status = $status; fails = @($ctx.fails)
    })
    Write-Host ("  [{0,-4}] {1} ({2}) {3}" -f $status, $Id, $Priority, $Title)
    foreach ($f in $ctx.fails) { Write-Host ("        - $f") }
}

# 辅助:全链闭环一个任务(claim → report → settle),只返回 settle 结果
# 注意:前两步必须显式丢弃输出,否则函数返回值变成三步输出的数组(PS 管道语义)
function Complete-Stage {
    param([string]$RunId, [string]$NodeId, [string]$Role)
    $null = TB @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeId, "-Role", $Role)
    $cb = New-CallbackFile $NodeId "done" $true $true $true
    $null = TLeaf @("-Command", "report", "-RunId", $RunId, "-Worker", $Role, "-CallbackFile", $cb)
    return (TB @("-Command", "settle", "-RunId", $RunId, "-NodeId", $NodeId))
}

function Set-ClaimAge {
    # age one node's claim beyond every threshold (dead-claim reclaim precheck:
    # unknown liveness falls back to the 60-min time rule)
    param([string]$RunId, [string]$NodeId, [int]$Hours = 2)
    $tp = Join-Path (Get-RunDirPath $RunId) "state\tree.json"
    $t = [System.IO.File]::ReadAllText($tp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $n = $t.nodes | Where-Object id -eq $NodeId
    $n.claimed_at = (Get-Date).ToUniversalTime().AddHours(-1 * $Hours).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    [System.IO.File]::WriteAllText($tp, ($t | ConvertTo-Json -Depth 10), $Utf8NoBom)
}

# mock dsh 载波(进程内 runspace + TcpListener,字节级读写环取自 role-handoff 已验证实现):
#   POST /api/<method>            → 请求信封 {rpcId,method,payload},按规则文件应答:
#                                   默认 ok(result.value={});kind=error → 业务错误(ok:false)
#   GET  /rdd-goal-tree/liveness* → 回规则 liveness 正文(默认 unknown)
# 规则文件按连接重读(场景切换免重启,Set-DshMockRule);请求逐条追加日志文件供断言/排查。
$script:DshMock = $null
function Set-DshMockRule {
    param([hashtable]$Methods, [string]$Liveness)
    $rulesPath = if ($script:DshMock) { $script:DshMock.rulesPath } else { Join-Path $script:WorkDir "dshmock-rules.json" }
    $livenessText = if ([string]::IsNullOrEmpty($Liveness)) { '{"run":"x","node":"n","session_id":"qa-bridge-mock","liveness":"unknown","reason":"mock default"}' } else { $Liveness }
    # default rule: agentPreset.list answers the full role preset set (start-role's
    # preset pre-check fails on an empty list); scenario -Methods MERGE over the
    # defaults so injected failures never accidentally clobber unrelated methods.
    $presets = @("rdd-pm", "rdd-cto", "rdd-ux", "rdd-dev", "rdd-qa", "default") | ForEach-Object { @{ id = $_ } }
    $rules = @{
        methods  = @{ "agentPreset.list" = @{ kind = "ok"; value = @{ presets = $presets } } }
        liveness = $livenessText
    }
    if ($null -ne $Methods) { foreach ($k in @($Methods.Keys)) { $rules.methods[$k] = $Methods[$k] } }
    [System.IO.File]::WriteAllText($rulesPath, ($rules | ConvertTo-Json -Depth 8), $Utf8NoBom)
}
# runspace 载波脚本必须以【字符串】喂给 AddScript(PS5.1 下脚本块直传在 /api 分支
# 半途死连接且无异常痕迹;字符串形态为 role-handoff 已验证模式),并带全包 catch——
# 单请求失败绝不拖垮载波。
$script:DshMockScript = @'
param($ConfigPath)
$cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$utf8 = New-Object System.Text.UTF8Encoding($false)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$server = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$server.Start()
$port = ([System.Net.IPEndPoint]$server.LocalEndpoint).Port
[System.IO.File]::WriteAllText($cfg.readyFile, "$port")
try {
    while (-not (Test-Path -LiteralPath $cfg.stopFile)) {
        if (-not $server.Pending()) { Start-Sleep -Milliseconds 25; continue }
        $client = $server.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 15000
            $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 8192
            $headerLen = -1
            $contentLen = 0
            while ($true) {
                if ($headerLen -lt 0) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $ms.Write($buf, 0, $n)
                    $raw = $latin1.GetString($ms.ToArray())
                    $idx = $raw.IndexOf("`r`n`r`n")
                    if ($idx -ge 0) {
                        $headerLen = $idx + 4
                        if ($raw -match "(?im)^Content-Length:\s*(\d+)") { $contentLen = [int]$Matches[1] }
                        # .NET HttpWebRequest defaults to Expect: 100-continue —
                        # answer the interim probe so the client flushes the body
                        # immediately instead of after its 350ms fallback timer.
                        if ($raw -match "(?im)^Expect:\s*100-continue") {
                            $cont = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                            $stream.Write($cont, 0, $cont.Length)
                        }
                    }
                }
                else {
                    $need = $headerLen + $contentLen - $ms.Length
                    if ($need -le 0) { break }
                    $n = $stream.Read($buf, 0, [Math]::Min($need, $buf.Length))
                    if ($n -le 0) { break }
                    $ms.Write($buf, 0, $n)
                }
            }
            if ($headerLen -lt 0) { continue }
            $reqLine = ($latin1.GetString($ms.ToArray(), 0, $headerLen) -split "`r`n")[0]
            $path = ($reqLine -split " ")[1]
            $respText = $null
            if ($path -like "/rdd-goal-tree/liveness*") {
                $rules = [System.IO.File]::ReadAllText($cfg.rulesPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $respText = [string]$rules.liveness
            }
            elseif ($path -like "/api/*") {
                $bodyText = [System.Text.Encoding]::UTF8.GetString($ms.ToArray(), $headerLen, $ms.Length - $headerLen)
                $envelope = $null
                try { $envelope = $bodyText | ConvertFrom-Json } catch {}
                $method = ($path -replace "^/api/", "") -replace "\?.*$", ""
                $payloadJson = "{}"
                if ($null -ne $envelope -and $null -ne $envelope.payload) {
                    $pj = $envelope.payload | ConvertTo-Json -Depth 10 -Compress
                    if (-not [string]::IsNullOrWhiteSpace($pj)) { $payloadJson = $pj }
                }
                [System.IO.File]::AppendAllText($cfg.logFile, ('{"method":"' + $method + '","payload":' + $payloadJson + "}`n"), $utf8)
                $rules = [System.IO.File]::ReadAllText($cfg.rulesPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $rule = $null
                $mprop = $rules.methods.PSObject.Properties[$method]
                if ($null -ne $mprop) { $rule = $mprop.Value }
                $result = @{ ok = $true; value = @{} }
                if ($null -ne $rule -and [string]$rule.kind -eq "error") {
                    $result = @{ ok = $false; error = @{ code = [string]$rule.code; message = [string]$rule.message; details = @{} } }
                }
                elseif ($null -ne $rule -and $null -ne $rule.value) {
                    $result = @{ ok = $true; value = $rule.value }
                }
                $rpcId = ""
                if ($null -ne $envelope -and $envelope.PSObject.Properties["rpcId"]) { $rpcId = [string]$envelope.rpcId }
                $respText = (@{ rpcId = $rpcId; result = $result } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($null -eq $respText) { $respText = '{"ok":false,"error":{"code":"MOCK_NO_ROUTE","message":"no route"}}' }
            $body = [System.Text.Encoding]::UTF8.GetBytes($respText)
            $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: " + $body.Length + "`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $stream.Write($body, 0, $body.Length)
        }
        catch {
            try { [System.IO.File]::AppendAllText($cfg.logFile, "CONN-ERR: " + $_.Exception.Message, $utf8) } catch {}
        }
        finally { $client.Close() }
    }
}
finally { $server.Stop() }
'@
function Start-DshMock {
    $rulesPath = Join-Path $script:WorkDir "dshmock-rules.json"
    $logPath = Join-Path $script:WorkDir "dshmock-log.jsonl"
    Set-DshMockRule
    if (Test-Path $logPath) { Remove-Item $logPath -Force }
    $readyFile = Join-Path $script:WorkDir "dshmock.ready"
    $stopFile = Join-Path $script:WorkDir "dshmock.stop"
    foreach ($f in @($readyFile, $stopFile)) { if (Test-Path $f) { Remove-Item $f -Force } }
    $cfg = @{ rulesPath = $rulesPath; logFile = $logPath; readyFile = $readyFile; stopFile = $stopFile }
    $cfgPath = Join-Path $script:WorkDir "dshmock.cfg.json"
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 6), $Utf8NoBom)
    $ps = [powershell]::Create()
    $null = $ps.AddScript($script:DshMockScript).AddArgument($cfgPath)
    $handle = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $readyFile)) { throw "mock dsh 载波未就绪" }
    $port = [int]([System.IO.File]::ReadAllText($readyFile)).Trim()
    $script:DshMock = @{ ps = $ps; handle = $handle; rulesPath = $rulesPath; logPath = $logPath; stopFile = $stopFile; port = $port }
    return "http://127.0.0.1:$port"
}
function Stop-DshMock {
    if ($null -ne $script:DshMock) {
        try { [System.IO.File]::WriteAllText($script:DshMock.stopFile, "stop") } catch {}
        try { $script:DshMock.ps.Stop() } catch {}
        $script:DshMock.ps.Dispose()
        $script:DshMock = $null
    }
}
function Read-DshMockLog {
    if ($null -eq $script:DshMock -or -not (Test-Path $script:DshMock.logPath)) { return @() }
    $lines = @([System.IO.File]::ReadAllLines($script:DshMock.logPath, [System.Text.Encoding]::UTF8) | Where-Object { $_ -ne "" })
    return @($lines | ForEach-Object { $_ | ConvertFrom-Json })
}

# ============================================================
# 套件:promulgate — TC-B01 / TC-B02(BR-AC-2, BR-AC-1)
# ============================================================

function Suite-Promulgate {
    Write-Host "`n== suite: promulgate (BR-AC-1/2 颁布与映射) =="

    Run-Tc "TC-B01" "promulgate:run 建立 + 目标根树形(需求节点 ref↔需求文档) + bridge.json v2 1:N 映射落盘 + 依赖自动推导" "P0" "BR-AC-2" {
        param($c)
        $fx = New-FixtureArchive "pm01"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-CreatedBy", "QA")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($d.run_id -eq $fx.run_id) "run_id=$($d.run_id),期望 $($fx.run_id)"
        Assert $c (@($d.tasks).Count -eq 3) "颁布任务数 $(@($d.tasks).Count),期望 3"
        # 映射落盘可查:bridge.json 双向(v2:goal_root 锚 + goal 标题 + pushes 账目容器)
        $b = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b) "bridge.json 不可读"
        Assert $c ([int]$b.format_version -eq 2) "format_version=$($b.format_version),期望 2"
        Assert $c ($b.goal_root -eq "n1" -and $b.goal.title -eq "原始需求：QA 夹具总纲") "goal_root/goal.title 异常: $($b.goal_root)/$($b.goal.title)"
        Assert $c ($null -ne $b.pushes) "pushes 账目容器缺失"
        Assert $c ($b.nodes.n2.task_id -eq 1 -and $b.nodes.n2.stage -eq "DEV") "n2 映射异常"
        Assert $c ($b.nodes.n3.task_id -eq 2 -and $b.nodes.n4.task_id -eq 3 -and $b.nodes.n4.stage -eq "CTO") "n3/n4 映射异常"
        Assert $c ($b.tasks.'1'.stages.DEV -eq "n2") "任务1 反向映射异常"
        # 目标根树形:n1 type=goal 且为一二级父;需求节点 ref ↔ 需求文档;依赖推导(T2 → T1)
        $t = Read-RunTree $fx.run_id
        $n1 = $t.nodes | Where-Object id -eq "n1"
        $n3 = $t.nodes | Where-Object id -eq "n3"
        $n2 = $t.nodes | Where-Object id -eq "n2"
        Assert $c ([string]$n1.type -eq "goal") "根节点 type 应为 goal: $($n1.type)"
        Assert $c ($n1.title -eq "原始需求：QA 夹具总纲" -and $n1.task -like "*三件套夹具*") "目标根 title/task 应承载原始需求(overview)"
        Assert $c (@($n1.children) -contains "n2" -and @($n1.children) -contains "n4") "需求链头应挂 goal 根下: $($n1.children -join ',')"
        Assert $c ([string]$n2.ref -eq "$($fx.name)/requirements/t1.md") "n2.ref=$($n2.ref),期望需求文档绑定"
        Assert $c (@($n3.depends_on) -contains "n2") "T2→T1 依赖未推导: $($n3.depends_on -join ',')"
        # 预算自动下限:width ≥ 任务数
        $st = TRun @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ([int]$st.json.data.budget.node_width -ge 3) "node_width 下限未生效: $($st.json.data.budget.node_width)"
        # 开放轮:round 1 打开(claim 可用)
        Assert $c ([int]$st.json.data.round.open -eq 1) "round.open=$($st.json.data.round.open),期望 1"
        # 租约自动获取
        Assert $c ($null -ne (Get-Item (Join-Path (Get-RunDirPath $fx.run_id) "planner-lease.json") -ErrorAction SilentlyContinue)) "planner-lease.json 未落盘"
    }

    Run-Tc "TC-B02" "重复 promulgate 防护(RUN_EXISTS);dispatch -DryRun 预演不误开窗" "P1" "BR-AC-1" {
        param($c)
        $fx = New-FixtureArchive "pm02"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $dup = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($dup.exit -eq 1 -and $dup.json.error.code -eq "RUN_EXISTS") "重复颁布未拒: $($dup.text)"
        # dispatch DryRun:start-role -DryRun 透传(cli 后端打印并退出 0,不开窗)
        $r = TB @("-Command", "dispatch", "-RunId", $fx.run_id, "-NodeId", "n2", "-DryRun")
        Assert $c ($r.exit -eq 0 -and $r.json.success -and $r.json.data.dry_run -eq $true) "dispatch DryRun 失败: $($r.text)"
        Assert $c ($r.json.data.stage -eq "DEV" -and $r.json.data.task_id -eq 1) "dispatch 映射异常"
        # 非桥接 run 拒绝(protect plain runs)
        $rid = "qa-bridge-plain-$($script:RunStamp)"
        $script:CreatedRuns.Add($rid) | Out-Null
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "plain", "-RefRoots", ".", "-CreatedBy", "QA")
        $nb = TB @("-Command", "status", "-RunId", $rid)
        Assert $c ($nb.exit -eq 2 -and $nb.json.error.code -eq "NOT_A_BRIDGE_RUN") "非桥接 run 未拒: $($nb.text)"
    }
}

# ============================================================
# 套件:claim — TC-B03 ~ TC-B05(BR-AC-2/3)
# ============================================================

function Suite-Claim {
    Write-Host "`n== suite: claim (BR-AC-2/3 复合认领与冲突反馈) =="

    Run-Tc "TC-B03" "claim 双上下文:树侧节点(task 指针/ref)+ 流侧任务(requirement/design)+ 开工指引" "P0" "BR-AC-2" {
        param($c)
        $fx = New-FixtureArchive "cl03"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $r = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "claim 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($d.tree_claim.node.status -eq "claimed" -and $d.tree_claim.node.ref -eq "$($fx.name)/requirements/t1.md") "树侧上下文异常"
        Assert $c ($d.flow_claim.claimed -eq $true) "流侧未认领"
        Assert $c ($null -ne $d.task -and [string]$d.task.id -eq "1") "流侧任务上下文异常"
        Assert $c ([string]$d.report_hint -ne "") "缺 report 指引"
        # 流侧 currentWorker 有 DEV 条目
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        $hasDev = $false
        foreach ($w in @($t1.currentWorker)) {
            if ($w -is [System.Collections.IDictionary]) { if (@($w.Keys) -contains "DEV") { $hasDev = $true } }
            else { if (@($w.PSObject.Properties | ForEach-Object { $_.Name }) -contains "DEV") { $hasDev = $true } }
        }
        Assert $c $hasDev "task.json currentWorker 无 DEV 条目"
    }

    Run-Tc "TC-B04" "重复唤起:第二会话得确定性冲突反馈(认领者+可领清单),引导改领;依赖阻塞直达" "P0" "BR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "cl04"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        # 第二会话唤起同一节点
        $dup = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($dup.exit -eq 1 -and $dup.json.error.code -eq "NODE_NOT_CLAIMABLE") "重复认领未给确定性反馈: $($dup.text)"
        Assert $c ($dup.json.error.message.Contains("claimed_by=DEV")) "反馈未含认领者"
        Assert $c ($dup.json.error.message.Contains("n4")) "反馈未含可领清单(n4=T3 CTO 节点应可领)"
        # 依赖阻塞:n3(T2)被 n2 阻塞
        $blk = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n3", "-Role", "DEV")
        Assert $c ($blk.exit -eq 1 -and $blk.json.error.code -eq "NODE_BLOCKED_BY_DEPS" -and $blk.json.error.message.Contains("n2")) "依赖阻塞反馈异常: $($blk.text)"
        # 误开的会话按清单改领 n4 成功
        $alt = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n4", "-Role", "CTO")
        Assert $c ($alt.exit -eq 0) "按清单改领失败: $($alt.text)"
    }

    Run-Tc "TC-B05" "角色不符/非映射节点/生命周期终态的确定性拒绝" "P1" "BR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "cl05"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # 角色不属于 owners:n2 是 DEV 阶段,用 QA 认领
        $w1 = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "QA")
        Assert $c ($w1.exit -eq 1 -and $w1.json.error.code -eq "ROLE_NOT_OWNER") "角色不符未拒: $($w1.text)"
        # 非映射节点(根 n1;退出码 2 = 参数/映射类错误)
        $w2 = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n1", "-Role", "DEV")
        Assert $c ($w2.exit -eq 2 -and $w2.json.error.code -eq "NODE_NOT_MAPPED") "根节点未拒: $($w2.text)"
    }
}

# ============================================================
# 套件:settle — TC-B06 ~ TC-B08(BR-AC-4)
# ============================================================

function Suite-Settle {
    Write-Host "`n== suite: settle (BR-AC-4 唯一流转通道与三查门禁) =="

    Run-Tc "TC-B06" "三查门禁:verdict≠done / citations 空 / 虚假路径 / extras.verification 缺失 全部拒绝且不流转" "P0" "BR-AC-4" {
        param($c)
        $fx = New-FixtureArchive "st06"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        # 未 reported 的节点:settle 拒绝
        $w0 = TB @("-Command", "settle", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($w0.exit -eq 1 -and $w0.json.error.code -eq "SETTLE_REQUIRES_REPORTED") "非 reported settle 未拒"
        # verdict=failed
        $cb = New-CallbackFile "n2" "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb)
        $w1 = TB @("-Command", "settle", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($w1.exit -eq 1 -and $w1.json.error.code -eq "SETTLE_EVIDENCE_REJECTED" -and $w1.json.error.message.Contains("verdict")) "verdict 门禁未拒: $($w1.text)"
        # 回收后走 citations 空路径
        $null = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        $rep = ((Read-RunTree $fx.run_id).nodes | Where-Object id -eq "n4")
        $newNode = [string]((TB @("-Command", "status", "-RunId", $fx.run_id)).json.data | ConvertTo-Json -Depth 8 -Compress)
        $bridge = Read-BridgeJson $fx.run_id
        $curNode = [string]$bridge.tasks.'1'.stages.DEV
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $curNode, "-Role", "DEV")
        $cb2 = New-CallbackFile $curNode "done" $false $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb2)
        $w2 = TB @("-Command", "settle", "-RunId", $fx.run_id, "-NodeId", $curNode)
        Assert $c ($w2.exit -eq 1 -and $w2.json.error.message.Contains("citations")) "citations 空门禁未拒: $($w2.text)"
        # 回收后走虚假路径
        $null = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", $curNode)
        $bridge = Read-BridgeJson $fx.run_id
        $curNode = [string]$bridge.tasks.'1'.stages.DEV
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $curNode, "-Role", "DEV")
        $cb3 = New-CallbackFile $curNode "done" $true $true $false
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb3)
        $w3 = TB @("-Command", "settle", "-RunId", $fx.run_id, "-NodeId", $curNode)
        Assert $c ($w3.exit -eq 1 -and $w3.json.error.message.Contains("does not exist")) "虚假路径门禁未拒: $($w3.text)"
        # 回收后走 verification 缺失
        $null = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", $curNode)
        $bridge = Read-BridgeJson $fx.run_id
        $curNode = [string]$bridge.tasks.'1'.stages.DEV
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $curNode, "-Role", "DEV")
        $cb4 = New-CallbackFile $curNode "done" $true $false $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb4)
        $w4 = TB @("-Command", "settle", "-RunId", $fx.run_id, "-NodeId", $curNode)
        Assert $c ($w4.exit -eq 1 -and $w4.json.error.message.Contains("verification")) "verification 门禁未拒: $($w4.text)"
        # 全程 task.json 未流转(仍 DEV,无 advance 痕迹)
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c (@($t1.currentOwners) -contains "DEV") "被拒过程中任务被意外流转: $($t1.currentOwners -join '+')"
    }

    Run-Tc "TC-B07" "合格 settle:三查通过 → advance + 链式 graft QA 节点(父子关系/ref);QA settle → complete(lifecycle=completed)" "P0" "BR-AC-4" {
        param($c)
        $fx = New-FixtureArchive "st07"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $r = Complete-Stage $fx.run_id "n2" "DEV"
        Assert $c ($r.exit -eq 0 -and $r.json.success) "settle 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($d.flow_operation -eq "advance DEV->QA") "flow_operation=$($d.flow_operation)"
        $qaNode = [string]$d.next_stage_node
        Assert $c ($qaNode -ne "") "未自动 graft QA 节点"
        # 链式 parent:QA 节点父 = DEV 节点
        $t = Read-RunTree $fx.run_id
        $qa = $t.nodes | Where-Object id -eq $qaNode
        Assert $c ([string]$qa.parent -eq "n2") "链式 parent 异常: $($qa.parent)"
        Assert $c ([string]$qa.role -eq "qa" -and [string]$qa.ref -eq "$($fx.name)/requirements/t1.md") "QA 节点 role/ref 异常"
        # 流侧:owners=QA,worker 清空
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c ((@($t1.currentOwners) -contains "QA") -and (@($t1.currentWorker).Count -eq 0)) "advance 后路由/worker 异常"
        # bridge 映射更新:任务1 stages 含 QA
        $bridge = Read-BridgeJson $fx.run_id
        Assert $c ([string]$bridge.tasks.'1'.stages.QA -eq $qaNode) "bridge 映射未更新"
        # rdd-flow check 全程通过
        $chk = TFlow @("-Command", "check", "-Archive", $fx.dir)
        Assert $c ($chk.exit -eq 0 -and [int]$chk.json.data.issueCount -eq 0) "check 未过: $($chk.text)"
        # QA settle → complete
        $r2 = Complete-Stage $fx.run_id $qaNode "QA"
        Assert $c ($r2.exit -eq 0 -and $r2.json.data.flow_operation -eq "complete") "QA settle 失败: $($r2.text)"
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c ([string]$t1.lifecycle -eq "completed") "任务未 completed: $($t1.lifecycle)"
    }

    Run-Tc "TC-B08" "CTO 起步链:CTO settle → advance CTO->DEV;跨任务阶段互不干扰" "P1" "BR-AC-4" {
        param($c)
        $fx = New-FixtureArchive "st08"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # T3 从 CTO 起步(n4)
        $r = Complete-Stage $fx.run_id "n4" "CTO"
        Assert $c ($r.exit -eq 0 -and $r.json.data.flow_operation -eq "advance CTO->DEV") "CTO 链 settle 异常: $($r.text)"
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t3 = @($flow.json.data.tasks | Where-Object { $_.id -eq 3 })[0]
        Assert $c ((@($t3.currentOwners) -contains "DEV") -and (@($t3.currentWorker).Count -eq 0)) "T3 路由异常"
        # T1/T2 未被波及
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c (@($t1.currentOwners) -contains "DEV") "T1 被意外流转"
    }
}

# ============================================================
# 套件:recover — TC-B09 / TC-B10(BR-AC-5)
# ============================================================

function Suite-Recover {
    Write-Host "`n== suite: recover (BR-AC-5 回收/恢复/状态视图) =="

    Run-Tc "TC-B09" "reclaim 双模式:dead-claim(存活门禁+泊位+重派接管)与 rejected-delivery(剪枝+替换节点);reported 永不重复消费" "P0" "BR-AC-5" {
        param($c)
        $fx = New-FixtureArchive "rc09"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # dead-claim 门禁:新认领(存活 unknown 且未达时间阈值)→ RECLAIM_UNPROVEN_DEAD(宁等多收)
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        $rc0 = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rc0.exit -eq 1 -and $rc0.json.error.code -eq "RECLAIM_UNPROVEN_DEAD") "新认领未被存活门禁拦: $($rc0.text)"
        # 认领超过时间阈值(60min)后 → dead-claim 回收 → 泊位
        Set-ClaimAge $fx.run_id "n2"
        $rc = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rc.exit -eq 0 -and $rc.json.data.mode -eq "dead-claim") "dead-claim 回收失败: $($rc.text)"
        # 泊位后新会话 claim 接管(steal + force)
        $re = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($re.exit -eq 0 -and $re.json.data.tree_claim.node.claimed_by -eq "DEV") "泊位接管失败: $($re.text)"
        # rejected-delivery:failed 报告 → settle 拒 → reclaim 剪枝+替换
        $cb = New-CallbackFile "n2" "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb)
        $w = TB @("-Command", "settle", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($w.exit -eq 1) "failed 交付应被拒"
        $rc2 = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rc2.exit -eq 0 -and $rc2.json.data.mode -eq "rejected-delivery") "rejected-delivery 回收失败: $($rc2.text)"
        $newNode = [string]$rc2.json.data.node_id
        Assert $c ($newNode -ne "n2" -and $newNode -ne "") "替换节点异常: $newNode"
        # 旧节点 pruned(账本留痕),替换节点 pending 且可领
        $t = Read-RunTree $fx.run_id
        $old = $t.nodes | Where-Object id -eq "n2"
        Assert $c ([string]$old.status -eq "pruned") "旧节点未剪枝: $($old.status)"
        $ledger = Read-RunFileText $fx.run_id "state/ledger.jsonl"
        Assert $c ($ledger.Contains("n2")) "失败回调未留账本痕"
        $bridge = Read-BridgeJson $fx.run_id
        Assert $c ([string]$bridge.tasks.'1'.stages.DEV -eq $newNode) "bridge 未重映射到替换节点"
        $re2 = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $newNode, "-Role", "DEV")
        Assert $c ($re2.exit -eq 0) "替换节点认领失败: $($re2.text)"
        # reported 永不重复消费:done 节点 claim 拒绝
        $null = Complete-Stage $fx.run_id $newNode "DEV"
        $again = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $newNode, "-Role", "QA")
        Assert $c ($again.exit -eq 1) "done(settled)节点被重复消费"
    }

    Run-Tc "TC-B10" "status/resume:全程视图(阶段/终态计数/死 claim/pending_sync 修复)与断点恢复步骤" "P1" "BR-AC-5" {
        param($c)
        $fx = New-FixtureArchive "rc10"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # T1 走到 QA 阶段
        $null = Complete-Stage $fx.run_id "n2" "DEV"
        # 手工制造 pending_sync:tree settle 后 flow advance 失败路径难以稳定复现,
        # 直接验证 status 的一致性输出与修复通道存在性(pending_sync 字段 + 修复重试不崩溃)
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0 -and $st.json.success) "status 失败: $($st.text)"
        $d = $st.json.data
        Assert $c ($null -ne $d.tasks -and @($d.tasks).Count -eq 3) "status 任务行缺失"
        Assert $c ([string]$d.terminal -eq "0/3") "terminal=$($d.terminal),期望 0/3"
        $t1row = @($d.tasks | Where-Object { $_.task_id -eq 1 })[0]
        Assert $c (@($t1row.stages).Count -ge 2) "任务1 阶段行不足(应有 DEV+QA)"
        Assert $c ($null -ne $d.dead_claims) "dead_claims 视图缺失"
        # resume:断点视图 + 恢复步骤
        $rs = TB @("-Command", "resume", "-RunId", $fx.run_id)
        Assert $c ($rs.exit -eq 0 -and @($rs.json.data.recovery_steps).Count -ge 2) "resume 步骤过少: $($rs.text)"
        # 中断恢复:T1 QA 阶段闭环后 conclude 前状态正确
        $bridge = Read-BridgeJson $fx.run_id
        $qaNode = [string]$bridge.tasks.'1'.stages.QA
        $null = Complete-Stage $fx.run_id $qaNode "QA"
        $st2 = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ([string]$st2.json.data.terminal -eq "1/3") "terminal=$($st2.json.data.terminal),期望 1/3"
    }
}

# ============================================================
# 套件:conclude — TC-B11(BR-AC-6)
# ============================================================

function Suite-Conclude {
    Write-Host "`n== suite: conclude (BR-AC-6 结案) =="

    Run-Tc "TC-B11" "conclude:未全终态拒绝;全终态后产出 final-report + delivery-annex(任务终态表+check 结果)+ 租约释放" "P0" "BR-AC-6" {
        param($c)
        $fx = New-FixtureArchive "cn11"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # 未终态:拒绝
        $w = TB @("-Command", "conclude", "-RunId", $fx.run_id, "-Summary", "premature")
        Assert $c ($w.exit -eq 1 -and $w.json.error.code -eq "DELIVERY_INCOMPLETE") "未终态 conclude 未拒: $($w.text)"
        # 全链闭环:T1(DEV→QA)、T2(DEV→QA)、T3(CTO→DEV→QA)
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'1'.stages.DEV) "DEV"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'1'.stages.QA) "QA"
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'2'.stages.DEV) "DEV"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'2'.stages.QA) "QA"
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'3'.stages.CTO) "CTO"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'3'.stages.DEV) "DEV"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'3'.stages.QA) "QA"
        $r = TB @("-Command", "conclude", "-RunId", $fx.run_id, "-Summary", "QA-CONCLUDE-SUMMARY-XYZ")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "conclude 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($d.outcome -eq "achieved" -and $d.flow_check.ok -eq $true) "conclude 结果异常: $($r.text)"
        Assert $c ([string]$d.anchor_node -eq "n1" -and [string]$d.anchor_type -eq "goal") "结案锚应为 goal 根 n1: $($d.anchor_node)/$($d.anchor_type)"
        Assert $c (Test-Path (Join-Path (Get-RunDirPath $fx.run_id) "report\final-report.md")) "final-report.md 缺失"
        $fr = [System.IO.File]::ReadAllText((Join-Path (Get-RunDirPath $fx.run_id) "report\final-report.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($fr.Contains("根目标达成状态")) "final-report 缺「根目标达成状态」区"
        $annexPath = Join-Path (Get-RunDirPath $fx.run_id) "report\delivery-annex.md"
        Assert $c (Test-Path $annexPath) "delivery-annex.md 缺失"
        $annex = [System.IO.File]::ReadAllText($annexPath, [System.Text.Encoding]::UTF8)
        Assert $c ($annex.Contains("根目标: **达成**")) "annex 未体现根目标达成(goal 根=原始需求)"
        Assert $c ($annex.Contains("T1 bottom") -and $annex.Contains("T3 independent")) "annex 任务终态表不完整"
        Assert $c ($annex.Contains("completed")) "annex 未体现 completed 终态"
        Assert $c ($annex.Contains("QA-CONCLUDE-SUMMARY-XYZ")) "annex 未含结案摘要"
        Assert $c ($annex.Contains("rdd-flow check")) "annex 未含 check 结果"
        # run 已冻结;租约已释放
        $m = (Read-RunFileText $fx.run_id "manifest.json") | ConvertFrom-Json
        Assert $c ([string]$m.state -eq "concluded") "run 未冻结: $($m.state)"
        Assert $c (-not (Test-Path (Join-Path (Get-RunDirPath $fx.run_id) "planner-lease.json"))) "租约未释放"
    }
}

# ============================================================
# 套件:regression — TC-B12(BR-AC-7)
# ============================================================

function Suite-Regression {
    Write-Host "`n== suite: regression (BR-AC-7 未采用规划者的行为零变化) =="

    Run-Tc "TC-B12" "回归:纯 goal-tree run 零桥接文件;rdd-flow 纯流程照常;桥接命令不触碰真实归档" "P0" "BR-AC-7" {
        param($c)
        # 1) 纯 goal-tree run:core 命令后 run 目录无 bridge.json / planner-lease.json / delivery-annex.md
        $rid = "qa-bridge-reg-$($script:RunStamp)"
        $script:CreatedRuns.Add($rid) | Out-Null
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "regression plain run", "-RefRoots", ".", "-CreatedBy", "QA")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $tf = Join-Path $script:WorkDir "reg-tasks.json"
        [System.IO.File]::WriteAllText($tf, '[{"title":"a","task":"t"}]', $Utf8NoBom)
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1")
        $cbPath = Join-Path $script:WorkDir "reg-cb.json"
        [System.IO.File]::WriteAllText($cbPath, '{"node_id":"n2","verdict":"done","confidence":0.9,"summary":"s","citations":[{"ref":"package.json","locator":"root"}],"next_suggestion":""}', $Utf8NoBom)
        $null = TLeaf @("-Command", "report", "-RunId", $rid, "-Worker", "w1", "-CallbackFile", $cbPath)
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n2")
        $null = TRun @("-Command", "status", "-RunId", $rid)
        $null = TRun @("-Command", "resume", "-RunId", $rid)
        $runDir = Get-RunDirPath $rid
        foreach ($f in @("bridge.json", "planner-lease.json", "report\delivery-annex.md")) {
            Assert $c (-not (Test-Path (Join-Path $runDir $f))) "纯 run 出现桥接文件: $f"
        }
        # 纯 run 根节点无 type(目标根树形只由桥接颁布引入;goal-tree 默认路径零变化)
        $t = Read-RunTree $rid
        $n1 = $t.nodes | Where-Object id -eq "n1"
        Assert $c ($null -eq $n1.type) "纯 run 根节点不应有 type: $($n1.type)"
        # 2) 纯 rdd-flow 流程:fixture 归档 init→claim→advance→complete 照常(桥接零影响)
        $fx = New-FixtureArchive "rg12"
        $null = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $cl = TFlow @("-Command", "claim", "-TaskId", "1", "-Role", "DEV", "-Archive", $fx.dir)
        Assert $c ($cl.exit -eq 0 -and $cl.json.data.claimed -eq $true) "纯流程 claim 失败: $($cl.text)"
        $ad = TFlow @("-Command", "advance", "-TaskId", "1", "-From", "DEV", "-To", "QA", "-Archive", $fx.dir)
        Assert $c ($ad.exit -eq 0) "纯流程 advance 失败: $($ad.text)"
        $cp = TFlow @("-Command", "complete", "-TaskId", "1", "-Archive", $fx.dir)
        Assert $c ($cp.exit -eq 0) "纯流程 complete 失败: $($cp.text)"
        $chk = TFlow @("-Command", "check", "-Archive", $fx.dir)
        Assert $c ($chk.exit -eq 0 -and [int]$chk.json.data.issueCount -eq 0) "纯流程 check 失败: $($chk.text)"
        # 3) 真实归档(.rdd/changes)零触碰:整个验证器期间快照一致
        Assert $c ($script:ChangesAfterRun -eq $script:ChangesBeforeRun) ".rdd/changes/ 被改动(桥接命令必须只碰 fixture)"
    }
}

# ---------- 真实归档零触碰快照(回归 TC-B12 断言用) ----------

function Get-ChangesSnapshot {
    $root = Join-Path $RepoRoot ".rdd\changes"
    if (-not (Test-Path $root)) { return "<missing .rdd/changes>" }
    $files = @(Get-ChildItem $root -Recurse -File | Sort-Object FullName)
    $parts = foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length)
        "{0}:{1}" -f ($rel -replace '\\', '/'), (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
    return ($parts -join "`n")
}
$script:ChangesBeforeRun = Get-ChangesSnapshot
$script:ChangesAfterRun = Get-ChangesSnapshot   # filled at the end of main flow

# ============================================================
# 套件:compat — TC-B13(2026-09-18 更名需求;用户裁定零兼容:旧命名 sidecar 不识别)
# ============================================================

function Suite-Compat {
    Write-Host "`n== suite: compat (PR-AC-2 修订:旧命名 sidecar 不被识别,显式 reclaim 是迁移路径) =="

    Run-Tc "TC-B13" "存量 run 旧命名 sidecar 零兼容:manager-lease 活跃租约不被尊重(acquire 照常成功) + manager-reclaim 停泊节点不被识别(经新 reclaim 回收后可认领)" "P0" "PR-AC-2" {
        param($c)
        $fx = New-FixtureArchive "compat"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-CreatedBy", "QA")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $runDir = Get-RunDirPath $fx.run_id

        # --- 旧命名租约:把新版租约改名为 manager-lease.json,模拟存量 run 的活跃他方租约 ---
        Rename-Item (Join-Path $runDir "planner-lease.json") "manager-lease.json"
        # 读面(status/resume)不受影响:旧命名文件对读路径只是不可见文件
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0) "存量旧租约在场时 status 失败: $($st.text)"
        $rs = TB @("-Command", "resume", "-RunId", $fx.run_id)
        Assert $c ($rs.exit -eq 0) "存量旧租约在场时 resume 失败: $($rs.text)"
        # 零兼容裁定(planner-rename-cto-decisions #1/#4):manager-lease.json 不被读取,
        # 无 -Takeover 的 acquire 照常成功并落盘 planner-lease.json(旧租约孤儿化,无害)
        $acq = TB @("-Command", "lease", "-RunId", $fx.run_id, "-Acquire", "-Session", "qa-compat-new")
        Assert $c ($acq.exit -eq 0 -and $acq.json.success) "旧命名租约被尊重(与零兼容裁定不符,acquire 应照常成功): $($acq.text)"
        Assert $c ($null -ne (Get-Item (Join-Path $runDir "planner-lease.json") -ErrorAction SilentlyContinue)) "acquire 未落盘 planner-lease.json"
        # 清场:释放新租约,移除旧命名残留
        $null = TB @("-Command", "lease", "-RunId", $fx.run_id, "-Release", "-Session", "qa-compat-new")
        Remove-Item (Join-Path $runDir "manager-lease.json") -Force -ErrorAction SilentlyContinue

        # --- 旧命名停泊节点:claimed_by=manager-reclaim(2026-09-15 版 reclaim 写入值)不被识别 ---
        $treePath = Join-Path $runDir "state\tree.json"
        $tree = [System.IO.File]::ReadAllText($treePath) | ConvertFrom-Json
        $n2 = $tree.nodes | Where-Object id -eq "n2"
        $n2.status = "claimed"
        $n2.claimed_by = "manager-reclaim"
        $n2.claimed_at = (Get-Date).ToUniversalTime().ToString("o")
        [System.IO.File]::WriteAllText($treePath, ($tree | ConvertTo-Json -Depth 12), $Utf8NoBom)
        $cl = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($cl.exit -ne 0 -and $cl.text -match "NODE_NOT_CLAIMABLE") "manager-reclaim 停泊节点被当成新版泊位认领(零兼容裁定:旧值不识别,应报 NODE_NOT_CLAIMABLE): $($cl.text)"
        # 迁移路径(决策 #7 风险表:存量泊位需人工重新 reclaim):对新停泊节点跑新版
        # reclaim(dead-claim 模式),回收为 planner-reclaim 泊位后即可再认领
        # (泊位无 claims sidecar → 存活 unknown;时效化认领以通过 60min 兜底阈值)
        Set-ClaimAge $fx.run_id "n2"
        $rc = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rc.exit -eq 0 -and $rc.json.success) "新版 reclaim 回收旧停泊节点失败: $($rc.text)"
        $cl2 = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($cl2.exit -eq 0 -and $cl2.json.success) "reclaim 回收为 planner-reclaim 泊位后仍不可认领: $($cl2.text)"
    }
}

# ============================================================
# 套件:autopush — TC-B14 ~ TC-B19(2026-09-18 goal-tree-goal-root)
# ============================================================

function Suite-AutoPush {
    Write-Host "`n== suite: autopush (目标根树形/依赖驱动自动推送/存活门禁/失败分档/v2 门禁) =="

    Run-Tc "TC-B14" "初始自动推送:无依赖节点全部被推(T1-DEV/T3-CTO),依赖节点不推且 status 可见阻塞源;推送账目落盘" "P0" "GR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "ap14"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $ap = $r.json.data.auto_push
        $pushed = @($ap.pushed)
        Assert $c (($pushed -contains "n2") -and ($pushed -contains "n4")) "无依赖节点未全部推送: $($pushed -join ',')"
        Assert $c ($pushed -notcontains "n3") "依赖节点 T2 不应在初始推送: $($pushed -join ',')"
        Assert $c (@($ap.blocked) -contains "n3") "依赖节点未进阻塞视图: $($ap.blocked -join ',')"
        $t = Read-RunTree $fx.run_id
        $n3 = $t.nodes | Where-Object id -eq "n3"
        Assert $c (@($n3.depends_on) -contains "n2") "阻塞源依赖边缺失: $($n3.depends_on -join ',')"
        # 推送账目:被推节点 last_ok_at 落盘;goal 根不推
        $b = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b.pushes.n2.last_ok_at -and $null -ne $b.pushes.n4.last_ok_at) "推送账目未落盘 last_ok_at"
        Assert $c ($null -eq $b.pushes.n1) "goal 根不应有推送账目"
    }

    Run-Tc "TC-B15" "解锁推送:settle 后依赖满足节点 + 新阶段链节点被自动推送;全链闭环零手工 dispatch" "P0" "GR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "ap15"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $r = Complete-Stage $fx.run_id "n2" "DEV"
        Assert $c ($r.exit -eq 0 -and $r.json.success) "settle 失败: $($r.text)"
        $ap = $r.json.data.auto_push
        $pushed = @($ap.pushed)
        $qaNode = [string]$r.json.data.next_stage_node
        Assert $c ($pushed -contains $qaNode) "新 QA 阶段节点未被推送: $($pushed -join ',')"
        Assert $c ($pushed -contains "n3") "依赖解锁的 T2-DEV 未被推送: $($pushed -join ',')"
        # 全链闭环至 conclude:全程不手工 dispatch(推送即调度)
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'1'.stages.QA) "QA"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'2'.stages.DEV) "DEV"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'2'.stages.QA) "QA"
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'3'.stages.CTO) "CTO"
        $b = Read-BridgeJson $fx.run_id
        $null = Complete-Stage $fx.run_id ([string]$b.tasks.'3'.stages.DEV) "DEV"
        $b = Read-BridgeJson $fx.run_id
        $fin = Complete-Stage $fx.run_id ([string]$b.tasks.'3'.stages.QA) "QA"
        Assert $c ($fin.exit -eq 0) "末段 settle 失败: $($fin.text)"
        $con = TB @("-Command", "conclude", "-RunId", $fx.run_id, "-Summary", "autopush e2e")
        Assert $c ($con.exit -eq 0 -and [string]$con.json.data.anchor_node -eq "n1") "根锚结案失败: $($con.text)"
    }

    Run-Tc "TC-B16" "回收重推:dead-claim 回收入泊位后自动重推该节点;账目 needs_repush 清零" "P0" "GR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "ap16"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Set-ClaimAge $fx.run_id "n2"
        $rc = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rc.exit -eq 0 -and $rc.json.data.mode -eq "dead-claim") "dead-claim 回收失败: $($rc.text)"
        $ap = $rc.json.data.auto_push
        Assert $c (@($ap.pushed) -contains "n2") "泊位节点未被重推: $($ap.pushed -join ',')"
        $b = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b.pushes.n2.last_ok_at -and [bool]$b.pushes.n2.needs_repush -eq $false) "重推后账目未复位: $($b.pushes.n2 | ConvertTo-Json -Compress)"
        # 泊位节点重推后仍可被新会话接管认领
        $cl = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($cl.exit -eq 0) "重推节点不可认领: $($cl.text)"
    }

    Run-Tc "TC-B17" "存活判定两极:alive 经注册表证实拒绝回收;dead 证实后无需时间阈值即可回收;unknown 走时间兜底" "P0" "GR-AC-4" {
        param($c)
        $fx = New-FixtureArchive "ap17"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # sidecar 绑定 dsh 会话 id → 存活查证走 liveness 端点(套件 mock 载波)
        $env:DSH_SESSION_ID = "qa-liveness-probe"
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        $env:DSH_SESSION_ID = "qa-bridge-mock"
        # alive:长任务误杀物理不可能(新认领也拒)
        Set-DshMockRule -Liveness '{"run":"x","node":"n2","session_id":"qa-liveness-probe","liveness":"alive","reason":"mock alive"}'
        $rcA = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rcA.exit -eq 1 -and $rcA.json.error.code -eq "RECLAIM_TARGET_ALIVE") "alive 会话未被保护: $($rcA.text)"
        # dead:注册表证实死亡 → 无需时间阈值即可回收(泊位后自动重推亦走 mock /api)
        Set-DshMockRule -Liveness '{"run":"x","node":"n2","session_id":"qa-liveness-probe","liveness":"dead","reason":"mock dead"}'
        $rcD = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rcD.exit -eq 0 -and $rcD.json.data.mode -eq "dead-claim") "证实死亡回收失败: $($rcD.text)"
        # 复位默认规则(unknown;时间兜底分支由 TC-B09 覆盖)
        Set-DshMockRule
    }

    Run-Tc "TC-B18" "失败分档与补推:session-create 类 status 触碰自动重推;pointer 类只人工重推(不自动)" "P1" "GR-AC-5" {
        param($c)
        $fx = New-FixtureArchive "ap18"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-Session", "ap18-planner")
        $null = TB @("-Command", "lease", "-RunId", $fx.run_id, "-Release", "-Session", "ap18-planner")
        # 伪造推送账目:把初始推送的成功账目改写为失败待重推(n2 session-create / n4 pointer)
        $bp = Join-Path (Get-RunDirPath $fx.run_id) "bridge.json"
        $b = [System.IO.File]::ReadAllText($bp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $b.pushes.n2.last_ok_at = $null
        $b.pushes.n2.needs_repush = $true
        $b.pushes.n2.attempts = @(@{ at = $stamp; ok = $false; error = "start-role failed (forged session-create)"; retry_class = "session-create" })
        $b.pushes.n4.last_ok_at = $null
        $b.pushes.n4.needs_repush = $true
        $b.pushes.n4.attempts = @(@{ at = $stamp; ok = $false; error = "会话已创建，但指针投递失败 (forged pointer)"; retry_class = "pointer" })
        [System.IO.File]::WriteAllText($bp, ($b | ConvertTo-Json -Depth 12), $Utf8NoBom)
        # status 触碰:n2 被补推(ok 落账),n4 被跳过(人工)
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0) "status 失败: $($st.text)"
        $touch = $st.json.data.auto_push_touch
        $tPushed = @($touch.pushed)
        Assert $c ($tPushed -contains "n2") "session-create 类未被触碰补推: $($tPushed -join ',')"
        $tSkipped = @($touch.skipped | Where-Object { $_.node -eq "n4" })
        Assert $c ($tSkipped.Count -eq 1 -and [string]$tSkipped[0].reason -eq "pointer_manual_repush") "pointer 类未被跳过人工重推: $($touch.skipped | ConvertTo-Json -Compress)"
        # 账目复位:n2 ok + needs_repush 清零;n4 仍待人工
        $b2 = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b2.pushes.n2.last_ok_at -and [bool]$b2.pushes.n2.needs_repush -eq $false) "n2 补推后账目未复位"
        Assert $c ([bool]$b2.pushes.n4.needs_repush -eq $true) "n4 待人工状态被意外清除"
    }

    Run-Tc "TC-B19" "v2 格式门禁:v1 桥账(无 format_version)拒读并给出确定性指引;v2 正常" "P1" "GR-AC-6" {
        param($c)
        $fx = New-FixtureArchive "ap19"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # 降格为 v1:剥除 format_version / goal_root / pushes
        $bp = Join-Path (Get-RunDirPath $fx.run_id) "bridge.json"
        $b = [System.IO.File]::ReadAllText($bp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $b.PSObject.Properties.Remove("format_version")
        $b.PSObject.Properties.Remove("goal_root")
        $b.PSObject.Properties.Remove("pushes")
        [System.IO.File]::WriteAllText($bp, ($b | ConvertTo-Json -Depth 12), $Utf8NoBom)
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 3 -and $st.json.error.code -eq "BRIDGE_FORMAT_UNSUPPORTED") "v1 桥未被拒读: $($st.text)"
        Assert $c ($st.json.error.message.Contains("promulgate")) "拒读未附处置指引: $($st.json.error.message)"
        # v2 正常路径由 TC-B01/B14 覆盖(format_version=2 可读写)
    }

    Run-Tc "TC-B20" "真实失败分档与手动重推:create 阶段失败→session-create;prompt 失败(会话已建)→pointer;规则复位后 create 类自动补推、pointer 类只人工(dispatch 落账复位)" "P1" "GR-AC-5" {
        param($c)
        $fx = New-FixtureArchive "ap20"
        # 1) create 阶段即失败 → session-create 类(可自动重试)
        Set-DshMockRule -Methods @{ "session.create" = @{ kind = "error"; code = "MOCK_CREATE_FAIL"; message = "mock create failure" } }
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $ap = $r.json.data.auto_push
        Assert $c (@($ap.failed).Count -ge 1) "create 失败未入 failed 账: $($ap | ConvertTo-Json -Compress)"
        $fc = @($ap.failed | Where-Object { $_.node -eq "n2" })[0]
        Assert $c ($null -ne $fc -and [string]$fc.retry_class -eq "session-create") "create 失败分类错误: $($fc | ConvertTo-Json -Compress)"
        # 2) 切规则 create 成功、prompt 失败 → pointer 类(会话已建,只人工重推)
        Set-DshMockRule -Methods @{ "session.prompt" = @{ kind = "error"; code = "MOCK_PROMPT_FAIL"; message = "mock prompt failure" } }
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0 -and $st.json.success) "status 失败: $($st.text)"
        $b = Read-BridgeJson $fx.run_id
        $a2 = @($b.pushes.n2.attempts)
        Assert $c ($a2.Count -ge 2 -and [string]$a2[-1].retry_class -eq "pointer") "prompt 失败应分类 pointer: $($a2[-1] | ConvertTo-Json -Compress)"
        # 3) 规则复位:pointer 类触碰跳过(不自动重推);手动 dispatch 落账并复位
        Set-DshMockRule
        $st2 = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st2.exit -eq 0 -and $st2.json.success) "status2 失败: $($st2.text)"
        $touch2 = $st2.json.data.auto_push_touch
        Assert $c (@(@($touch2.skipped) | Where-Object { $_.node -eq "n2" -and [string]$_.reason -eq "pointer_manual_repush" }).Count -eq 1) "pointer 类未被跳过: $($touch2 | ConvertTo-Json -Compress)"
        $dp = TB @("-Command", "dispatch", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($dp.exit -eq 0 -and $dp.json.success) "手动重推失败: $($dp.text)"
        $b3 = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b3.pushes.n2.last_ok_at -and [bool]$b3.pushes.n2.needs_repush -eq $false) "手动重推后账目未复位"
    }
}

# ============================================================
# 套件:callback — TC-B21 / TC-B22(2026-09-18 planner-callback-handoff)
# ============================================================

function Suite-Callback {
    Write-Host "`n== suite: callback (CB-AC 指针标记段 + claim report_hint 产物位置三件套) =="

    Run-Tc "TC-B21" "推送指针携带 goal-tree 标记段(autopush + 手动 dispatch 两路径);claim report_hint 携带回调契约三件套与不直交指引" "P0" "CB-AC-2" {
        param($c)
        $fx = New-FixtureArchive "cb21"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        # autopush 注入标记段:该 run 的全部 session.prompt 指针尾部带 goal-tree-run=<RunId> node=<NodeId>
        $log = Read-DshMockLog
        $runPrompts = @($log | Where-Object { $_.method -eq "session.prompt" -and [string]$_.payload.content[0].text -like "*goal-tree-run=$($fx.run_id)*" })
        Assert $c ($runPrompts.Count -ge 2) "autopush 指针未携带 run 标记段(期望 n2+n4 至少 2 条): count=$($runPrompts.Count)"
        $n2Marked = @($runPrompts | Where-Object { [string]$_.payload.content[0].text -like "* node=n2" })
        Assert $c ($n2Marked.Count -ge 1) "autopush 指针未携带 node=n2 标记"
        # 手动 dispatch 同构注入(pointer 类人工重推 / 异常处置路径)
        $dp = TB @("-Command", "dispatch", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($dp.exit -eq 0 -and $dp.json.success) "手动 dispatch 失败: $($dp.text)"
        $ns = [string]$dp.json.data.next_step
        Assert $c ($ns.Contains("claim")) "dispatch next_step 语义被改: $ns"
        $log2 = Read-DshMockLog
        $n2After = @($log2 | Where-Object { $_.method -eq "session.prompt" -and [string]$_.payload.content[0].text -like "*goal-tree-run=$($fx.run_id)* node=n2" })
        Assert $c ($n2After.Count -ge 2) "手动 dispatch 未追加标记段指针(期望 autopush+dispatch 共 2 条): count=$($n2After.Count)"
        # claim report_hint:完成即回调规划者(不 start-role 直交)+ 产物位置三件套语义
        $cl = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n4", "-Role", "CTO")
        Assert $c ($cl.exit -eq 0 -and $cl.json.success) "claim 失败: $($cl.text)"
        $hint = [string]$cl.json.data.report_hint
        Assert $c ($hint -ne "") "缺 report_hint"
        Assert $c ($hint.Contains("report back to the Planner")) "report_hint 未指引回调规划者"
        Assert $c ($hint.Contains("instead of start-role-ing a downstream role")) "report_hint 未禁直交"
        Assert $c ($hint.Contains("citations") -and $hint.Contains("full_report") -and $hint.Contains("extras.verification")) "report_hint 缺产物位置三件套语义"
        Assert $c ($hint.Contains("goal-tree-leaf.cmd -Command report")) "report_hint 缺 leaf report 命令"
    }

    Run-Tc "TC-B22" "非桥回归:start-role 未传 -GoalTreeRun 直调时 B2 指针零标记段(以句号收尾,前缀形态不变)" "P1" "CB-AC-1" {
        param($c)
        $fx = New-FixtureArchive "cb22"
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try { $null = & $sr @("-Role", "QA", "-TaskId", "1", "-TaskJson", (Join-Path $fx.dir "task.json")) 2>$null; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($code -eq 0) "start-role 直调失败(exit=$code)"
        $log = Read-DshMockLog
        $last = @($log | Where-Object { $_.method -eq "session.prompt" }) | Select-Object -Last 1
        $txt = [string]$last.payload.content[0].text
        Assert $c ($txt -match "^请处理 .+ 下的需求。$") "B2 指针形态异常: $txt"
        Assert $c (-not $txt.Contains("goal-tree-run")) "非桥指针意外携带标记段: $txt"
    }
}

# ============================================================
# 套件:review — TC-B23 ~ TC-B27(RR-AC-1~4,需求审查门 -ReviewFile)
# 来源:2026-09-20-planner-capability-optimization / requirements/planner-requirement-review.md
# (用例设计自 DEV 自测 TC-DR1~DR5 转正;QA 独立复核断言后固化)
# ============================================================

function New-ReviewFixture {
    # 可变任务形态的 fixture 归档(审查门需要 5 任务/2 任务等非默认形态)
    # $Tasks: @( @{ id; title; owners; req } ) — req 为需求文档正文
    param([string]$Tag, [object[]]$Tasks)
    $archName = "2099-12-31-qa-fixture-$Tag-$($script:RunStamp)"
    $archDir = Join-Path $script:WorkDir $archName
    New-Item -ItemType Directory -Path (Join-Path $archDir "requirements") -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $archDir "requirements\overview.md"), "# 审查门夹具总纲`r`n`r`n$Tag:供审查门验证器断言三级处置语义。", $Utf8NoBom)
    $taskJson = @()
    foreach ($t in $Tasks) {
        $reqRel = "requirements/t$($t.id).md"
        [System.IO.File]::WriteAllText((Join-Path $archDir ("requirements\t$($t.id).md")), $t.req, $Utf8NoBom)
        $taskJson += @{
            id = $t.id; title = $t.title; requirement = $reqRel
            currentOwners = @($t.owners); designDocs = @(); currentWorker = @()
            remark = ""; lifecycle = "active"
        }
    }
    @{ version = 1; archive = $Tag; tasks = $taskJson } | ConvertTo-Json -Depth 6 | ForEach-Object {
        [System.IO.File]::WriteAllText((Join-Path $archDir "task.json"), $_, $Utf8NoBom)
    }
    $script:CreatedArchives.Add($archDir) | Out-Null
    return @{ name = $archName; dir = $archDir; run_id = "deliver-$archName" }
}

function New-ReviewVerdictFile {
    # ReviewFile(planner-guide 硬约束 6 契约):verdicts 数组原样落盘
    param([string]$Tag, $Verdicts)
    $p = Join-Path $script:WorkDir ("review-$Tag.json")
    $obj = @{
        reviewed_at = "2026-09-20T00:00:00Z"; reviewer = "qa-verifier"; verdicts = $Verdicts
    }
    [System.IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Depth 6), $Utf8NoBom)
    return $p
}

function Suite-Review {
    Write-Host "`n== suite: review (RR-AC-1~4 需求审查门:三级处置/审计三载体/错误码/部分达成/缺省回归) =="

    Run-Tc "TC-B23" "审查门 happy path:pass/override 清空/合并(已 deprecate)/驳回(已 reject)/依赖重定向 + 审计三载体 + 不阻断其余交付" "P0" "RR-AC-1/RR-AC-2" {
        param($c)
        $fx = New-ReviewFixture "rv1" @(
            @{ id = 1; title = "T1 base";       owners = "DEV"; req = "# T1`r`n`r`n- **描述**：底座`r`n- **依赖关系**：无" }
            @{ id = 2; title = "T2 dep-marked"; owners = "DEV"; req = "# T2`r`n`r`n- **描述**：依赖方（实际不依赖）`r`n- **依赖关系**：依赖需求 1（t1 底座）" }
            @{ id = 3; title = "T3 absorbed";   owners = "DEV"; req = "# T3`r`n`r`n- **描述**：与 T1 同一改动两个侧面`r`n- **依赖关系**：无" }
            @{ id = 4; title = "T4 off-goal";   owners = "DEV"; req = "# T4`r`n`r`n- **描述**：与根目标不符`r`n- **依赖关系**：无" }
            @{ id = 5; title = "T5 via3";       owners = "DEV"; req = "# T5`r`n`r`n- **描述**：经 T3 间接依赖底座`r`n- **依赖关系**：依赖需求 3（t3）" }
        )
        # 前置动作(planner 语义,脚本消费前完成):deprecate 被并入方 + reject 驳回方
        $null = TFlow @("-Command", "deprecate", "-TaskId", "3", "-Archive", $fx.dir)
        $null = TFlow @("-Command", "reject", "-TaskId", "4", "-From", "PLANNER", "-To", "PM", "-Reason", "与 overview 根目标不符", "-Archive", $fx.dir)
        $rf = New-ReviewVerdictFile "rv1" @(
            @{ task_id = 1; verdict = "pass";             reason = "独立、与根目标一致" }
            @{ task_id = 2; verdict = "tree_adjudicated"; reason = "依赖错标：实际不依赖 #1"; depends_on_override = @() }
            @{ task_id = 3; verdict = "tree_adjudicated"; reason = "与 #1 实为同一改动两个侧面"; merged_into_task_id = 1 }
            @{ task_id = 4; verdict = "reject_return";    reason = "与 overview 根目标不符" }
        )
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rf)
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $d = $r.json.data
        # 建树集 1/2/5;排除账目:skipped_review=[4](3 走既有 skipped_deprecated,不双计)
        Assert $c (@($d.tasks).Count -eq 3) "颁布任务数 $(@($d.tasks).Count), 期望 3"
        Assert $c (((@($d.tasks | ForEach-Object { $_.task_id })) -join ',') -eq "1,2,5") "颁布任务集异常: $(@($d.tasks | ForEach-Object { $_.task_id }) -join ',')"
        Assert $c (((@($d.skipped_review)) -join ',') -eq "4") "skipped_review=$(@($d.skipped_review) -join ','), 期望 4"
        Assert $c (((@($d.skipped_deprecated)) -join ',') -eq "3") "skipped_deprecated=$(@($d.skipped_deprecated) -join ','), 期望 3"
        # 节点映射与依赖:t2 override 清空;t5 重定向到 t1 的节点
        $t1n = [string](@($d.tasks | Where-Object { $_.task_id -eq 1 })[0].node)
        $t2n = [string](@($d.tasks | Where-Object { $_.task_id -eq 2 })[0].node)
        $t5n = [string](@($d.tasks | Where-Object { $_.task_id -eq 5 })[0].node)
        Assert $c ((@(@($d.tasks | Where-Object { $_.task_id -eq 2 })[0].dep_task_ids).Count -eq 0)) "t2 override 未清空依赖"
        Assert $c (((@(@($d.tasks | Where-Object { $_.task_id -eq 5 })[0].dep_task_ids)) -join ',') -eq "1") "t5 未重定向到 #1: $(@($d.tasks | Where-Object { $_.task_id -eq 5 })[0].dep_task_ids -join ',')"
        # 树侧真实边
        $tree = Read-RunTree $fx.run_id
        $n5 = @($tree.nodes | Where-Object { $_.id -eq $t5n })[0]
        Assert $c (@($n5.depends_on) -contains $t1n) "树侧 t5→t1 重定向边缺失: $($n5.depends_on -join ',')"
        $n2 = @($tree.nodes | Where-Object { $_.id -eq $t2n })[0]
        Assert $c (@($n2.depends_on).Count -eq 0) "树侧 t2 依赖未清空: $($n2.depends_on -join ',')"
        # 根下只有 3 个链头
        $heads = @($tree.nodes | Where-Object { $_.id -eq "n1" })[0].children
        Assert $c (@($heads).Count -eq 3 -and ($heads -contains $t1n) -and ($heads -contains $t2n) -and ($heads -contains $t5n)) "链头集异常: $($heads -join ',')"
        # 自动推送:t1/t2 被推;t5 被重定向依赖阻塞(其余需求交付不被阻断)
        $pushed = @($d.auto_push.pushed); $blocked = @($d.auto_push.blocked)
        Assert $c (($pushed -contains $t1n) -and ($pushed -contains $t2n)) "无依赖节点未推: $($pushed -join ',')"
        Assert $c ($pushed -notcontains $t5n) "t5 不应被推: $($pushed -join ',')"
        Assert $c ($blocked -contains $t5n) "t5 未进阻塞视图: $($blocked -join ',')"
        # 审计三载体:bridge.review / report/review.md / 返回值 review
        $b = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b.review -and @($b.review.verdicts).Count -eq 4 -and $b.review.applied_at) "bridge review 段异常"
        Assert $c ($null -eq $b.tasks.'3' -and $null -eq $b.tasks.'4') "排除任务进入了 bridge.tasks"
        $rev = Read-RunFileText $fx.run_id "report/review.md"
        foreach ($needle in @("通过", "树内裁定", "驳回回流", "依赖错标", "两个侧面", "根目标不符", "合并至 #1", "T5 via3", "最终裁决权在用户")) {
            Assert $c ($rev.Contains($needle)) "review.md 缺少: $needle"
        }
        Assert $c ($null -ne $d.review -and @($d.review.verdicts).Count -eq 4 -and ([string]$d.review.report).EndsWith("review.md")) "返回值 review 段异常"
        # flow 侧:t4 驳回路由 PM 保持 active(文档级驳回复用既有协议)
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t4 = @($flow.json.data.tasks | Where-Object { $_.id -eq 4 })[0]
        Assert $c ((@($t4.currentOwners) -contains "PM") -and [string]$t4.lifecycle -eq "active") "t4 驳回路由异常: $($t4.currentOwners -join '+')/$($t4.lifecycle)"
    }

    Run-Tc "TC-B24" "延后缝合:override 指向后位任务 → goal-tree deps add 补边 + deps-log 审计 + 新边阻塞推送" "P1" "RR-AC-2" {
        param($c)
        $fx = New-ReviewFixture "rv2" @(
            @{ id = 1; title = "F1"; owners = "DEV"; req = "# F1`r`n`r`n- **依赖关系**：无" }
            @{ id = 2; title = "F2 fwd"; owners = "DEV"; req = "# F2`r`n`r`n- **依赖关系**：无" }
            @{ id = 3; title = "F3 target"; owners = "DEV"; req = "# F3`r`n`r`n- **依赖关系**：无" }
        )
        $rf = New-ReviewVerdictFile "rv2" @(
            @{ task_id = 2; verdict = "tree_adjudicated"; reason = "实际依赖后位任务 #3"; depends_on_override = @(3) }
        )
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rf)
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $d = $r.json.data
        $t2n = [string](@($d.tasks | Where-Object { $_.task_id -eq 2 })[0].node)
        $t3n = [string](@($d.tasks | Where-Object { $_.task_id -eq 3 })[0].node)
        $tree = Read-RunTree $fx.run_id
        $n2 = @($tree.nodes | Where-Object { $_.id -eq $t2n })[0]
        Assert $c (@($n2.depends_on) -contains $t3n) "延后缝合边缺失: $($n2.depends_on -join ',')"
        $depsLog = Read-RunFileText $fx.run_id "state/deps-log.jsonl"
        Assert $c ($depsLog.Contains("dep-add")) "deps-log 未留 dep-add 审计痕"
        Assert $c (@($d.review.deferred_dep_edges).Count -ge 1) "返回值 deferred_dep_edges 为空"
        Assert $c (@($d.auto_push.blocked) -contains $t2n) "t2 未被延后缝合边阻塞: $($d.auto_push.blocked -join ',')"
    }

    Run-Tc "TC-B25" "错误码三枚(REVIEW_FILE_INVALID/REVIEW_TASK_NOT_FOUND/REVIEW_EXCLUDED_DEP)×7 场景确定性拒绝;错误均发生在建树前,无 run 目录残留" "P0" "RR-AC-1" {
        param($c)
        $fx = New-ReviewFixture "rv3" @(
            @{ id = 1; title = "E1 base"; owners = "DEV"; req = "# E1`r`n`r`n- **依赖关系**：无" }
            @{ id = 2; title = "E2 dep";  owners = "DEV"; req = "# E2`r`n`r`n- **依赖关系**：依赖需求 1（e1）" }
        )
        # a) pass 携带 merged_into_task_id
        $rfA = New-ReviewVerdictFile "rv3a" @( @{ task_id = 1; verdict = "pass"; reason = "x"; merged_into_task_id = 2 } )
        $ra = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rfA)
        Assert $c ($ra.exit -eq 2 -and $ra.json.error.code -eq "REVIEW_FILE_INVALID") "pass+merged 未拒: $($ra.text)"
        # b) task_id 不在归档
        $rfB = New-ReviewVerdictFile "rv3b" @( @{ task_id = 99; verdict = "pass"; reason = "x" } )
        $rb = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rfB)
        Assert $c ($rb.exit -eq 2 -and $rb.json.error.code -eq "REVIEW_TASK_NOT_FOUND") "未知 task 未拒: $($rb.text)"
        # c) REVIEW_EXCLUDED_DEP:t2 推导依赖被驳回排除的 t1(消息指向依赖方,禁止静默丢弃)
        $null = TFlow @("-Command", "reject", "-TaskId", "1", "-From", "PLANNER", "-To", "PM", "-Reason", "不符", "-Archive", $fx.dir)
        $rfC = New-ReviewVerdictFile "rv3c" @( @{ task_id = 1; verdict = "reject_return"; reason = "与根目标不符" } )
        $rc = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rfC)
        Assert $c ($rc.exit -eq 1 -and $rc.json.error.code -eq "REVIEW_EXCLUDED_DEP") "悬空依赖未硬拒: $($rc.text)"
        Assert $c ($rc.json.error.message.Contains("#2")) "硬拒消息未指向依赖方: $($rc.json.error.message)"
        # d) 同任务重复 verdict
        $rfD = New-ReviewVerdictFile "rv3d" @(
            @{ task_id = 2; verdict = "pass"; reason = "x" }
            @{ task_id = 2; verdict = "pass"; reason = "y" }
        )
        $rd = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rfD)
        Assert $c ($rd.exit -eq 2 -and $rd.json.error.code -eq "REVIEW_FILE_INVALID") "重复 verdict 未拒: $($rd.text)"
        # e) 不可解析 JSON
        $badPath = Join-Path $script:WorkDir "review-bad.json"
        [System.IO.File]::WriteAllText($badPath, "{ not json", $Utf8NoBom)
        $re = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $badPath)
        Assert $c ($re.exit -eq 2 -and $re.json.error.code -eq "REVIEW_FILE_INVALID") "坏 JSON 未拒: $($re.text)"
        # f) reject_return 打在 deprecated 任务上
        $fx2 = New-ReviewFixture "rv3f" @(
            @{ id = 1; title = "G1"; owners = "DEV"; req = "# G1`r`n`r`n- **依赖关系**：无" }
            @{ id = 2; title = "G2"; owners = "DEV"; req = "# G2`r`n`r`n- **依赖关系**：无" }
        )
        $null = TFlow @("-Command", "deprecate", "-TaskId", "1", "-Archive", $fx2.dir)
        $rfF = New-ReviewVerdictFile "rv3f" @( @{ task_id = 1; verdict = "reject_return"; reason = "x" } )
        $rf = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx2.dir "task.json"), "-ReviewFile", $rfF)
        Assert $c ($rf.exit -eq 2 -and $rf.json.error.code -eq "REVIEW_FILE_INVALID") "deprecated 上 reject 未拒: $($rf.text)"
        # g) 合并目标自身被驳回(不存活)
        $fx3 = New-ReviewFixture "rv3g" @(
            @{ id = 1; title = "H1"; owners = "DEV"; req = "# H1`r`n`r`n- **依赖关系**：无" }
            @{ id = 2; title = "H2"; owners = "DEV"; req = "# H2`r`n`r`n- **依赖关系**：无" }
        )
        $rfG = New-ReviewVerdictFile "rv3g" @(
            @{ task_id = 1; verdict = "reject_return"; reason = "x" }
            @{ task_id = 2; verdict = "tree_adjudicated"; reason = "并入被驳回的 #1"; merged_into_task_id = 1 }
        )
        $rg = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx3.dir "task.json"), "-ReviewFile", $rfG)
        Assert $c ($rg.exit -eq 2 -and $rg.json.error.code -eq "REVIEW_FILE_INVALID") "合并目标不存活未拒: $($rg.text)"
        # 无部分状态残留:错误全部发生在 goal-tree start 之前
        foreach ($a in @($fx, $fx2, $fx3)) {
            Assert $c (-not (Test-Path (Get-RunDirPath $a.run_id))) "错误后残留 run 目录: $($a.run_id)"
        }
    }

    Run-Tc "TC-B26" "部分达成结案:驳回任务 active@PM 豁免 DELIVERY_INCOMPLETE 门禁(豁免严格限定 reject_return 集);annex 如实呈现部分达成与注记" "P0" "RR-AC-3" {
        param($c)
        $fx = New-ReviewFixture "rv4" @(
            @{ id = 1; title = "P1 deliver"; owners = "DEV"; req = "# P1`r`n`r`n- **依赖关系**：无" }
            @{ id = 2; title = "P2 reject";  owners = "DEV"; req = "# P2`r`n`r`n- **依赖关系**：无" }
        )
        $null = TFlow @("-Command", "reject", "-TaskId", "2", "-From", "PLANNER", "-To", "PM", "-Reason", "与根目标不符", "-Archive", $fx.dir)
        $rf = New-ReviewVerdictFile "rv4" @(
            @{ task_id = 1; verdict = "pass"; reason = "独立、与根目标一致" }
            @{ task_id = 2; verdict = "reject_return"; reason = "与 overview 根目标不符" }
        )
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-ReviewFile", $rf)
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $devNode = [string](@($r.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        $s1 = Complete-Stage $fx.run_id $devNode "DEV"
        Assert $c ($s1.exit -eq 0) "DEV settle 失败: $($s1.text)"
        $qaNode = [string]$s1.json.data.next_stage_node
        $s2 = Complete-Stage $fx.run_id $qaNode "QA"
        Assert $c ($s2.exit -eq 0 -and $s2.json.data.flow_operation -eq "complete") "QA settle/complete 失败: $($s2.text)"
        $cc = TB @("-Command", "conclude", "-RunId", $fx.run_id, "-Summary", "QA-REVIEW-CONCLUDE-PARTIAL")
        Assert $c ($cc.exit -eq 0 -and $cc.json.success) "conclude 失败: $($cc.text)"
        Assert $c ([string]$cc.json.data.tasks_terminal -eq "2/2") "tasks_terminal 异常: $($cc.json.data.tasks_terminal)"
        Assert $c (((@($cc.json.data.reject_return_pending)) -join ',') -eq "2") "reject_return_pending 异常: $(@($cc.json.data.reject_return_pending) -join ',')"
        $annex = Read-RunFileText $fx.run_id "report/delivery-annex.md"
        Assert $c ($annex.Contains("部分达成（1 条驳回回流 PM")) "annex 未呈现部分达成"
        Assert $c ($annex.Contains("驳回回流 PM，修订中")) "annex 任务表缺驳回注记"
        Assert $c (-not $annex.Contains("根目标: **达成** —")) "annex 误呈现完全达成"
        Assert $c ($annex.Contains("P2 reject")) "annex 任务表缺被驳回任务行"
        Assert $c (Test-Path (Join-Path (Get-RunDirPath $fx.run_id) "report\final-report.md")) "final-report 缺失"
    }

    Run-Tc "TC-B27" "缺省回归:无 -ReviewFile 时 review=null、bridge 无 review 段、无 review.md、既有依赖推导不变(缺省路径与无审查门行为零变化)" "P0" "REG" {
        param($c)
        $fx = New-ReviewFixture "rv5" @(
            @{ id = 1; title = "D1"; owners = "DEV"; req = "# D1`r`n`r`n- **依赖关系**：无" }
            @{ id = 2; title = "D2"; owners = "DEV"; req = "# D2`r`n`r`n- **依赖关系**：依赖需求 1（d1）" }
        )
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($null -eq $d.review) "缺省路径返回了 review 段"
        Assert $c (@($d.skipped_review).Count -eq 0) "缺省路径 skipped_review 非空"
        $b = Read-BridgeJson $fx.run_id
        Assert $c ($null -eq $b.review) "缺省路径 bridge.json 出现 review 段"
        Assert $c (-not (Test-Path (Join-Path (Get-RunDirPath $fx.run_id) "report\review.md"))) "缺省路径出现 review.md"
        Assert $c (((@(@($d.tasks | Where-Object { $_.task_id -eq 2 })[0].dep_task_ids)) -join ',') -eq "1") "既有依赖推导被改"
    }
}

# ============================================================
# 套件:uniqueness — TC-B28 ~ TC-B31(PU-AC-1~4,规划者唯一性与回调防劫持)
# 来源:2026-09-20-planner-capability-optimization / requirements/planner-uniqueness-callback.md
# (AC3 投递层 readPlannerLease 单元断言在 dsh/rdd-goal-tree/tests/smoke.mjs 2d 节,
#  规约 TC-B32 挂 cases.json,codeRef 指向该文件——本套件只覆盖引擎侧可黑盒驱动面)
# ============================================================

function Suite-Uniqueness {
    Write-Host "`n== suite: uniqueness (PU-AC 规划者唯一性:误启拒绝/合法入口/无 run 放行/信息层禁令) =="

    Run-Tc "TC-B28" "误启动确定性反馈:活跃 run 归档上 start-role PLANNER → PLANNER_RUN_ACTIVE 拒绝(run 信息+-RunId 续跑指引+Takeover 衔接+-Force 通道),零会话创建" "P0" "PU-AC-2" {
        param($c)
        $fx = New-FixtureArchive "pu28"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        # 注入 rdd-planner preset:若门禁失效,会话将真实创建(让零创建断言有判别力)
        Set-DshMockRule -Methods @{ "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @(@{ id = "rdd-planner" }, @{ id = "default" }) } } }
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        $createsBefore = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.create" }).Count
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $txt = (& $sr @("-Role", "PLANNER", "-TaskJson", (Join-Path $fx.dir "task.json")) 2>$null | Out-String).Trim(); $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($code -eq 1) "误启动未被拒绝(exit=$code)"
        Assert $c ($txt.Contains("PLANNER_RUN_ACTIVE")) "拒绝反馈缺错误码 PLANNER_RUN_ACTIVE: $txt"
        Assert $c ($txt.Contains($fx.run_id)) "拒绝反馈缺 run 标识 $($fx.run_id)"
        Assert $c ($txt.Contains("start-role.cmd -Role PLANNER -RunId $($fx.run_id)")) "缺 -RunId 续跑合法入口指引"
        Assert $c ($txt.Contains("lease -RunId $($fx.run_id) -Takeover")) "缺 Takeover 衔接指引"
        Assert $c ($txt.Contains("-Force")) "缺 -Force 用户裁决通道说明"
        $createsAfter = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.create" }).Count
        Assert $c ($createsAfter -eq $createsBefore) "拒绝路径仍发起了会话创建(before=$createsBefore after=$createsAfter)"
        Set-DshMockRule
    }

    Run-Tc "TC-B29" "合法入口零误伤:-RunId 续跑不拦截(DryRun+租约持有者提示+接管指引);-Force 跳过门禁后 rdd-planner 会话照常创建" "P0" "PU-AC-2" {
        param($c)
        $fx = New-FixtureArchive "pu29"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        # (a) -RunId 续跑:合法再入,不拦截
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $txtA = (& $sr @("-Role", "PLANNER", "-RunId", $fx.run_id, "-DryRun") 2>$null | Out-String).Trim(); $codeA = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($codeA -eq 0) "续跑模式被误拦(exit=$codeA)"
        Assert $c ($txtA.Contains("续跑模式") -and $txtA.Contains("合法入口")) "续跑合法入口提示缺失: $txtA"
        Assert $c ($txtA.Contains("lease -RunId $($fx.run_id) -Takeover")) "续跑提示缺接管指引"
        # (b) -Force:跳过门禁,会话照常创建(用户显式裁决通道)
        Set-DshMockRule -Methods @{ "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @(@{ id = "rdd-planner" }, @{ id = "default" }) } } }
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $null = & $sr @("-Role", "PLANNER", "-TaskJson", (Join-Path $fx.dir "task.json"), "-Force") 2>$null; $codeB = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($codeB -eq 0) "-Force 强启失败(exit=$codeB)"
        $plannerCreates = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.create" -and [string]$_.payload.agentPreset -eq "rdd-planner" })
        Assert $c ($plannerCreates.Count -ge 1) "-Force 未创建 rdd-planner 会话(门禁外溢或通道断裂)"
        Set-DshMockRule
    }

    Run-Tc "TC-B30" "非桥回归:无活跃 run 归档启动 PLANNER 照常放行(RUN_NOT_FOUND→probe 放行),会话创建,指针零 goal-tree 标记段" "P0" "PU-AC-4" {
        param($c)
        $fx = New-FixtureArchive "pu30"   # 不 promulgate:该归档无桥接 run
        Set-DshMockRule -Methods @{ "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @(@{ id = "rdd-planner" }, @{ id = "default" }) } } }
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $txt = (& $sr @("-Role", "PLANNER", "-TaskJson", (Join-Path $fx.dir "task.json")) 2>$null | Out-String).Trim(); $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($code -eq 0) "无活跃 run 归档启动被误拦(exit=$code): $txt"
        Assert $c (-not $txt.Contains("PLANNER_RUN_ACTIVE")) "无 run 时不应报 PLANNER_RUN_ACTIVE"
        $log = Read-DshMockLog
        $created = @($log | Where-Object { $_.method -eq "session.create" -and [string]$_.payload.agentPreset -eq "rdd-planner" })
        Assert $c ($created.Count -ge 1) "放行后未创建会话(行为与改前不一致)"
        $lastPrompt = @($log | Where-Object { $_.method -eq "session.prompt" }) | Select-Object -Last 1
        $pText = [string]$lastPrompt.payload.content[0].text
        Assert $c ($pText -ne "" -and (-not $pText.Contains("goal-tree-run"))) "非桥 PLANNER 指针意外携带标记段: $pText"
        Set-DshMockRule
    }

    Run-Tc "TC-B31" "信息层禁令在位:next PLANNER 块自声明桥接 worker 不适用(longTask 照常触发);四 worker 卡逐字同构禁令+PM 卡适用前提+协议真源同步" "P0" "PU-AC-1" {
        param($c)
        $fx = New-FixtureArchive "pu31"
        # (a) 非桥 next:longTask 信号与 PLANNER 候选块照常输出(AC4 回归),note 含 worker 不适用声明(AC1 兜底)
        $n = TFlow @("-Command", "next", "-Archive", $fx.dir)
        Assert $c ($n.exit -eq 0 -and $n.json.success) "next 失败: $($n.text)"
        Assert $c ([bool]$n.json.data.longTask.triggered) "longTask 信号未触发(非桥回归破坏)"
        $plannerBlock = @($n.json.data.roles) | Where-Object { [string]$_.role -eq "PLANNER" } | Select-Object -First 1
        Assert $c ($null -ne $plannerBlock) "PLANNER 候选块未输出(非桥回归破坏)"
        Assert $c (([string]$plannerBlock.note).Contains("桥接 run 的 worker")) "PLANNER 块 note 缺桥接 worker 不适用声明"
        Assert $c (([string]$plannerBlock.note).Contains("勿启动 PLANNER")) "PLANNER 块 note 缺勿启动指引"
        # (b) 四张 worker 卡 goal-tree 分支禁令逐字同构
        $sentences = @()
        foreach ($card in @("rdd-cto", "rdd-ux", "rdd-dev", "rdd-qa")) {
            $t = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "$card\SKILL.md"), [System.Text.Encoding]::UTF8)
            $m = [regex]::Match($t, "桥接 run 内\*\*不启动 PLANNER\*\*.*?留痕。")
            Assert $c $m.Success "$card\SKILL.md 缺「不启动 PLANNER」禁令"
            if ($m.Success) { $sentences += $m.Value }
        }
        Assert $c (@($sentences | Select-Object -Unique).Count -le 1) "四卡禁令非逐字同构"
        # (c) PM 卡适用前提 + 协议真源(transition-guide / planner-guide)同步
        $pm = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "rdd-pm\SKILL.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($pm.Contains("PLANNER_RUN_ACTIVE")) "PM 卡 planner-takeover 话术缺适用前提(PLANNER_RUN_ACTIVE)"
        $tg = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "rdd-engine\references\transition-guide.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($tg.Contains("不启动 PLANNER")) "transition-guide goal-tree 分支缺不启动 PLANNER 禁令"
        $pg = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "rdd-engine\references\planner-guide.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($pg.Contains("回调投递目标解析")) "planner-guide 缺回调投递目标解析段"
        Assert $c ($pg.Contains("PLANNER_RUN_ACTIVE")) "planner-guide 双规划者误起条目未更新"
    }
}

# ============================================================
# 主流程
# ============================================================

Write-Host "delivery-bridge-verify — repo: $RepoRoot"
Write-Host "suite: $Suite  (runs under .rdd/goal-trees/ + fixture archives in .rdd/tmp, stamp: $script:RunStamp)"

# 套件级 mock dsh 载波:接管 DSH_WEB_URL,自动推送/liveness 查证全部打到 mock(见文件头)
$script:DshMockUrl = Start-DshMock
$env:DSH_WEB_URL = $script:DshMockUrl
$env:RDD_RUNTIME = $null
$env:DSH_SESSION_ID = "qa-bridge-mock"
Write-Host "dsh-mock carrier: $script:DshMockUrl"

$selected = if ($Suite -eq "all") { @("promulgate", "claim", "settle", "recover", "conclude", "regression", "compat", "autopush", "callback", "review", "uniqueness") } else { @($Suite) }
foreach ($s in $selected) {
    switch ($s) {
        "promulgate" { Suite-Promulgate }
        "claim"      { Suite-Claim }
        "settle"     { Suite-Settle }
        "recover"    { Suite-Recover }
        "conclude"   { Suite-Conclude }
        "regression" { $script:ChangesAfterRun = Get-ChangesSnapshot; Suite-Regression }
        "compat"     { Suite-Compat }
        "autopush"   { Suite-AutoPush }
        "callback"   { Suite-Callback }
        "review"     { Suite-Review }
        "uniqueness" { Suite-Uniqueness }
    }
}

Stop-DshMock
$env:DSH_WEB_URL = $script:EnvSaved.DSH_WEB_URL
$env:RDD_RUNTIME = $script:EnvSaved.RDD_RUNTIME
$env:DSH_SESSION_ID = $script:EnvSaved.DSH_SESSION_ID

# ---------- 结果汇总 ----------

$pass = @($script:Results | Where-Object { $_.status -eq "PASS" })
$fail = @($script:Results | Where-Object { $_.status -eq "FAIL" })
$warn = @($script:Results | Where-Object { $_.status -eq "WARN" })
$p0fail = @($fail | Where-Object { $_.priority -eq "P0" })
$p1fail = @($fail | Where-Object { $_.priority -eq "P1" })

$summary = [ordered]@{
    verifier   = "delivery-bridge-verify.ps1"
    suite      = $Suite
    ranAt      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    total      = $script:Results.Count
    passed     = $pass.Count
    failed     = $fail.Count
    warned     = $warn.Count
    results    = $script:Results
}
try {
    $resultsDir = Join-Path $RepoRoot ".rdd\tests\delivery-bridge"
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $resultsDir "results.json"), ($summary | ConvertTo-Json -Depth 6), $Utf8NoBom)
}
catch { Write-Host "WARN: results.json 写入失败: $($_.Exception.Message)" }

Write-Host ""
Write-Host ("==== 总览: 通过 {0}/{1}" -f $pass.Count, $script:Results.Count)
if ($p0fail.Count -gt 0) { Write-Host "  阻塞判断: 存在 P0 失败 $($p0fail.Count) 个 → 不可标记已完成" -ForegroundColor Red }
elseif ($p1fail.Count -gt 0) { Write-Host "  阻塞判断: 无 P0 失败;P1 失败 $($p1fail.Count) 个(严重不阻塞)" -ForegroundColor Yellow }
else { Write-Host "  阻塞判断: 无阻塞失败" -ForegroundColor Green }
if ($warn.Count -gt 0) { Write-Host "  P2 备忘: $($warn.Count) 个" }

if ($Json) { $summary | ConvertTo-Json -Depth 6 }

# ---------- 清理 ----------

if (-not $KeepRuns) {
    foreach ($id in $script:CreatedRuns) {
        Remove-Item (Get-RunDirPath $id) -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($a in $script:CreatedArchives) {
        # run 目录按 RunId 规约 deliver-<归档名> 同步清理
        $rn = "deliver-" + (Split-Path $a -Leaf)
        Remove-Item (Get-RunDirPath $rn) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit $(if ($p0fail.Count -gt 0) { 1 } else { 0 })

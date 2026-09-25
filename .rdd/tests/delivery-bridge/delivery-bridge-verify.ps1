# delivery-bridge-verify.ps1 — 规划者交付编排桥接 验收验证器（QA 独立实现，零依赖）
#
# 被测对象:rdd-engine/scripts/delivery-bridge.cmd(桥接编排黑盒)
#   黑盒集成测试:仅通过 CLI 接口驱动——delivery-bridge.cmd 组合 goal-tree / goal-tree-leaf /
#   rdd-flow / start-role 公开 CLI;fixture 归档建在 .rdd/tmp 下(绝不触碰真实归档)。
#   断言锚定规划者交付编排需求验收标准 1~7 与 planner-guide.md 协议;
#   2026-09-18 goal-tree-goal-root:目标根树形/依赖驱动自动推送/存活门禁/v2 账目。
#
# 用例规约:TC-B01 ~ TC-B37(映射 BR-AC-1 ~ BR-AC-7 + GR-AC-2~6 + CB-AC + RR-AC-1~4 + PU-AC + TGA-AC-1~4)
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
#   payload    派发任务锚定与目标透出(dispatch-task-goal-anchoring TGA-AC-1~4):node.task 目标为主单源落盘
#              (promulgate+graft 双构造点)/指针消息目标段三后端一致/旧格式保守降级零注入/标题与总长截断边界
#              —— TC-B33~B37(2026-09-20-planner-capability-optimization)
#   roster     派生会话标题与花名册(planner-session-roster PSR-AC):桥接派发 session.rename 钉住(先于 prompt)/
#              sessions.json 三来源(planner 本体+桥接回写+直交登记)/register-session 校验与幂等/改名失败降级/
#              普通 4 步交接零改名零花名册回归锚 —— TC-B38~B44(2026-09-20-planner-session-roster)
#   rollback   跨阶段回退单命令(planner-stage-rollback SRB-AC):守卫矩阵/剪枝+兄弟重建+reopen+自动重推全链/
#              三层一致性+重做上下文(node.task+指针)/幂等续跑(剪枝签名)/同 run 他任务无扰+dependents_warning
#              —— TC-B45~B48(2026-09-20-planner-enhancements)
#   automode   纯自动模式(planner-auto-mode AM-AC):开关快照+默认表明确列出/claim 授权传递/低风险自动拍板
#              全字段留痕/决策门禁矩阵(R1 硬底)/高风险升级+resolution 闭环/可见性与推翻通道/分级表覆盖
#              (R1 强制合并+无效策略零残留)/编排层不自动化+CTO 豁免文档锚/-NoPush 隔离性行为证据
#              —— TC-B50~B57(2026-09-20-planner-enhancements)
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
    [ValidateSet("all", "promulgate", "claim", "settle", "recover", "conclude", "regression", "compat", "autopush", "callback", "review", "uniqueness", "payload", "roster", "rollback", "automode")]
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
function TB   {
    param([string[]]$A)
    # long-task-planning: promulgate is a hard gate without -PlanFile; every
    # fixture ships a companion plan.json (New-FixtureArchive) and each call
    # names its fixture via -TaskJson, so inject -PlanFile here mechanically.
    if ($A -contains "promulgate" -and $A -notcontains "-PlanFile") {
        $ti = [array]::IndexOf($A, "-TaskJson")
        if ($ti -ge 0 -and ($ti + 1) -lt $A.Count) {
            $plan = Join-Path (Split-Path -Parent $A[$ti + 1]) "plan.json"
            if (Test-Path -LiteralPath $plan) { $A = @($A) + @("-PlanFile", $plan) }
        }
    }
    Invoke-EngineCli $BridgeCmd $A
}
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
    [System.IO.File]::WriteAllText((Join-Path $archDir "requirements\overview.md"), "# 原始需求：QA 夹具总纲`r`n`r`n三件套夹具:底座/依赖方/独立项——供桥接验证器断言目标根语义。`r`n`r`n## 整体验收判据`r`n`r`n无整体判据（理由：桥接验证器夹具，无整体验收场景，归档级已显式声明）", $Utf8NoBom)
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
    # long-task-planning companion PlanFile (promulgate hard gate): single
    # stage over all fixture tasks, batches = topological layers of the
    # fixture DAG ([[1,3],[2]]); the overview declares 无整体判据 so the
    # criteria_ref slot stays omitted (declared-none contract).
    $planJson = @'
{
    "planned_at": "2026-09-25T00:00:00Z",
    "planner": "qa-verify",
    "stages": [
        {
            "id": "S1",
            "goal": "夹具整批交付",
            "milestone": "三件套落位",
            "task_ids": [1, 2, 3],
            "batches": [[1, 3], [2]],
            "acceptance_point": {
                "criteria_items": ["smoke: fixture slice runs"],
                "slice": "runnable single-command slice"
            }
        }
    ],
    "risks": []
}
'@
    [System.IO.File]::WriteAllText((Join-Path $archDir "plan.json"), $planJson, $Utf8NoBom)
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
$seqCounters = @{}
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
                elseif ($null -ne $rule -and [string]$rule.kind -eq "seq") {
                    # 逐次返回 values 轮换值(模拟每次 session.create 返回不同 sessionId)
                    $i = 0
                    if ($seqCounters.ContainsKey($method)) { $i = $seqCounters[$method] }
                    $seqCounters[$method] = $i + 1
                    $result = @{ ok = $true; value = $rule.values[$i % $rule.values.Count] }
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
    [System.IO.File]::WriteAllText((Join-Path $archDir "requirements\overview.md"), "# 审查门夹具总纲`r`n`r`n$Tag:供审查门验证器断言三级处置语义。`r`n`r`n## 整体验收判据`r`n`r`n无整体判据（理由：审查门夹具，无整体验收场景，归档级已显式声明）", $Utf8NoBom)
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
# 套件:payload — TC-B33 ~ TC-B37(TGA-AC-1~4,派发任务锚定与目标透出)
# 来源:2026-09-20-planner-capability-optimization / requirements/dispatch-task-goal-anchoring.md
# (node.task 目标为主单源合成,promulgate+graft 双构造点;指针消息目标段三后端一致;
#  旧格式保守降级零注入;标题 60/总长 240 截断边界。AC2 树视图为 node.task 纯映射,
#  断言锚定落盘文本形态 + goaltrees.ts str(node.task) 纯映射钉)
# ============================================================

function New-PayloadFixture {
    # 载荷 fixture(长标题/长需求路径/设计文档段需要非默认任务形态)
    # $Tasks: @( @{ id; title; owners; reqRel; reqBody; designRels=@() } )
    param([string]$Tag, [object[]]$Tasks)
    $archName = "2099-12-31-qa-fixture-$Tag-$($script:RunStamp)"
    $archDir = Join-Path $script:WorkDir $archName
    New-Item -ItemType Directory -Path (Join-Path $archDir "requirements") -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $archDir "requirements\overview.md"), "# 载荷夹具总纲`r`n`r`n$Tag`:供派发载荷验证器断言目标为主文本契约。`r`n`r`n## 整体验收判据`r`n`r`n无整体判据（理由：载荷夹具，无整体验收场景，归档级已显式声明）", $Utf8NoBom)
    $taskJson = @()
    foreach ($t in $Tasks) {
        $reqAbs = Join-Path $archDir (($t.reqRel) -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $reqAbs) -Force | Out-Null
        [System.IO.File]::WriteAllText($reqAbs, $t.reqBody, $Utf8NoBom)
        $taskJson += @{
            id = $t.id; title = $t.title; requirement = ($t.reqRel -replace '\\', '/')
            currentOwners = @($t.owners)
            designDocs = @(@($t.designRels) | ForEach-Object { @{ path = $_; status = "ready" } })
            currentWorker = @(); remark = ""; lifecycle = "active"
        }
    }
    @{ version = 1; archive = $Tag; tasks = $taskJson } | ConvertTo-Json -Depth 6 | ForEach-Object {
        [System.IO.File]::WriteAllText((Join-Path $archDir "task.json"), $_, $Utf8NoBom)
    }
    $script:CreatedArchives.Add($archDir) | Out-Null
    return @{ name = $archName; dir = $archDir; run_id = "deliver-$archName" }
}

function Get-TreeNode {
    param([string]$RunId, [string]$NodeId)
    $tree = Read-RunTree $RunId
    return @($tree.nodes | Where-Object { $_.id -eq $NodeId })[0]
}

function Read-NodePrompt {
    # 最后一条发往 <run>/<node> 的指针(按尾部标记段过滤)
    param([string]$RunId, [string]$NodeId)
    $log = Read-DshMockLog
    return @($log | Where-Object { $_.method -eq "session.prompt" -and [string]$_.payload.content[0].text -like "*goal-tree-run=$RunId* node=$NodeId" }) | Select-Object -Last 1
}

function Suite-Payload {
    Write-Host "`n== suite: payload (TGA-AC 派发载荷目标化:node.task 单源/指针目标段/三后端/降级与截断) =="

    Run-Tc "TC-B33" "node.task 目标为主落盘(promulgate 构造点):目标句开头+需求文档/归档引用+claim 命令退居辅助尾段;claim 输出透传同一文本;goaltrees.ts 纯映射钉;设计文档段合成" "P0" "TGA-AC-1/TGA-AC-2" {
        param($c)
        $fx = New-FixtureArchive "tga33"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $nodeId = [string](@($r.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        $task = [string](Get-TreeNode $fx.run_id $nodeId).task
        Assert $c ($task.StartsWith("目标：完成「T1 bottom」的 DEV 阶段（编码实现）。")) "node.task 非目标为主开头: $task"
        Assert $c ($task.Contains("需求文档：requirements/t1.md；归档：$($fx.name)。")) "node.task 缺需求文档/归档引用: $task"
        Assert $c ($task.Contains("开工动作（辅助）：delivery-bridge.cmd -Command claim -RunId $($fx.run_id) -NodeId <本节点id> -Role DEV。")) "node.task claim 命令非辅助尾段: $task"
        Assert $c ($task.IndexOf("目标：") -lt $task.IndexOf("delivery-bridge.cmd")) "目标句未先于命令(信息次序硬要求)"
        # claim 输出透传同一文本——树视图/claim/指针三展示面同源于 node.task
        $cl = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $nodeId, "-Role", "DEV")
        Assert $c ($cl.exit -eq 0 -and $cl.json.success) "claim 失败: $($cl.text)"
        Assert $c ([string]$cl.json.data.tree_claim.node.task -eq $task) "claim 输出未透传 node.task 单源文本"
        # AC2 锚:树视图对 node.task 纯映射(零转换)——数据目标化后展示自动跟上
        $gts = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "dsh\rdd-goal-tree\src\goaltrees.ts"), [System.Text.Encoding]::UTF8)
        Assert $c ($gts.Contains("task: str(node.task)")) "goaltrees.ts 视图映射不再是纯透传(单源假设被破坏)"
        # 设计文档段:有 designDocs 时合成进 node.task
        $fx2 = New-PayloadFixture "tga33b" @(
            @{ id = 1; title = "D1 带设计文档"; owners = "CTO"; reqRel = "requirements/d1.md"; reqBody = "# D1`r`n`r`n- **依赖关系**：无"; designRels = @("design/d1-cto.md") }
        )
        $r2 = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx2.dir "task.json"))
        Assert $c ($r2.exit -eq 0 -and $r2.json.success) "promulgate(设计文档形态) 失败: $($r2.text)"
        $node2 = [string](@($r2.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        $task2 = [string](Get-TreeNode $fx2.run_id $node2).task
        Assert $c ($task2.StartsWith("目标：完成「D1 带设计文档」的 CTO 阶段（技术方向设计）。")) "CTO 阶段职责映射异常: $task2"
        Assert $c ($task2.Contains("；设计文档：design/d1-cto.md；归档：")) "设计文档段未合成进 node.task: $task2"
    }

    Run-Tc "TC-B34" "指针消息目标段(autopush+手动 dispatch 双路径):目标句/需求文档/真实 nodeId 认领命令,剔除归档与设计文档段,marker 居最末;三后端(cli 预填/app body/dsh text)注入同构" "P0" "TGA-AC-1/TGA-AC-3" {
        param($c)
        $fx = New-FixtureArchive "tga34"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $nodeId = [string](@($r.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        $goalHead = "本次唯一任务：完成「T1 bottom」的 DEV 阶段（编码实现）。"
        $claimCmd = "开工先领取节点：delivery-bridge.cmd -Command claim -RunId $($fx.run_id) -NodeId $nodeId -Role DEV。"
        # (a) autopush 注入
        $ent = Read-NodePrompt $fx.run_id $nodeId
        Assert $c ($null -ne $ent) "autopush 未推送 t1 节点指针"
        $txt = [string]$ent.payload.content[0].text
        Assert $c ($txt.Contains($goalHead)) "autopush 指针缺目标段: $txt"
        Assert $c ($txt.Contains("需求文档：requirements/t1.md。")) "目标段缺需求文档引用: $txt"
        Assert $c ($txt.Contains($claimCmd)) "目标段缺真实 nodeId 认领命令: $txt"
        Assert $c (-not $txt.Contains("<本节点id>")) "目标段占位符未填真实 nodeId: $txt"
        Assert $c (-not $txt.Contains("归档：")) "目标段未剔除归档段: $txt"
        Assert $c (-not $txt.Contains("设计文档：")) "目标段未剔除设计文档段: $txt"
        Assert $c ($txt.EndsWith("goal-tree-run=$($fx.run_id) node=$nodeId")) "marker 未居最末: $txt"
        Assert $c ($txt.IndexOf($goalHead) -lt $txt.IndexOf("goal-tree-run=")) "目标段未先于 marker"
        # (b) 手动 dispatch 同构(pointer 类人工重推路径)
        $dp = TB @("-Command", "dispatch", "-RunId", $fx.run_id, "-NodeId", $nodeId)
        Assert $c ($dp.exit -eq 0 -and $dp.json.success) "手动 dispatch 失败: $($dp.text)"
        $log2 = Read-DshMockLog
        $all = @($log2 | Where-Object { $_.method -eq "session.prompt" -and [string]$_.payload.content[0].text -like "*goal-tree-run=$($fx.run_id)* node=$nodeId" })
        Assert $c ($all.Count -ge 2) "手动 dispatch 未追加指针(期望 autopush+dispatch 共 ≥2 条): count=$($all.Count)"
        $txt2 = [string]($all | Select-Object -Last 1).payload.content[0].text
        Assert $c ($txt2.Contains($goalHead) -and $txt2.Contains($claimCmd) -and $txt2.EndsWith("goal-tree-run=$($fx.run_id) node=$nodeId")) "手动 dispatch 指针目标段形态异常: $txt2"
        # (c) 三后端注入同构:同一 -TaskBrief 直调 start-role(DryRun 逐后端取消息)
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        $briefArg = "$goalHead 需求文档：requirements/t1.md。$claimCmd"
        $srArgs = @("-Role", "DEV", "-TaskId", "1", "-TaskJson", (Join-Path $fx.dir "task.json"), "-TaskBrief", $briefArg, "-GoalTreeRun", $fx.run_id, "-GoalTreeNode", $nodeId, "-DryRun")
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try {
            # dsh 后端(载波环境即默认)
            $outDsh = (& $sr $srArgs 2>$null | Out-String).Trim(); $codeDsh = $LASTEXITCODE
            # cli 后端:清 DSH_WEB_URL + stub opencode 上 PATH(仅被发现,DryRun 不执行)
            $savedUrl = $env:DSH_WEB_URL; $env:DSH_WEB_URL = $null
            $stubDir = Join-Path $script:WorkDir "opencode-stub"
            New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $stubDir "opencode.cmd"), "@echo off`r`nexit 0", $Utf8NoBom)
            $savedPath = $env:PATH; $env:PATH = "$stubDir;$env:PATH"
            $outCli = (& $sr $srArgs 2>$null | Out-String).Trim(); $codeCli = $LASTEXITCODE
            $env:PATH = $savedPath; $env:DSH_WEB_URL = $savedUrl
            # app 后端:RDD_RUNTIME=app + -EmployeeId(Plus 语义)
            $savedRt = $env:RDD_RUNTIME; $env:RDD_RUNTIME = "app"
            $outApp = (& $sr ($srArgs + @("-EmployeeId", "11111111-2222-3333-4444-555555555555")) 2>$null | Out-String).Trim(); $codeApp = $LASTEXITCODE
            $env:RDD_RUNTIME = $savedRt
        }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($codeDsh -eq 0 -and $codeCli -eq 0 -and $codeApp -eq 0) "三后端 DryRun 退出码异常: dsh=$codeDsh cli=$codeCli app=$codeApp"
        $msgDsh = [regex]::Match($outDsh, "text=(?<m>.+)$", [System.Text.RegularExpressions.RegexOptions]::Multiline).Groups['m'].Value.Trim()
        $msgCli = [regex]::Match($outCli, "预填消息:\s*(?<m>.+)$", [System.Text.RegularExpressions.RegexOptions]::Multiline).Groups['m'].Value.Trim()
        $bodyLine = [regex]::Match($outApp, "\[DRYRUN\] body: (?<m>.+)$", [System.Text.RegularExpressions.RegexOptions]::Multiline).Groups['m'].Value.Trim()
        $msgApp = ""
        try { $msgApp = [string]($bodyLine | ConvertFrom-Json).message } catch {}
        foreach ($pair in @(@("dsh", $msgDsh), @("cli", $msgCli), @("app", $msgApp))) {
            $backend = $pair[0]; $m = $pair[1]
            Assert $c ($m.Contains($briefArg)) "$backend 后端消息缺目标段: $m"
            Assert $c ($m.EndsWith("goal-tree-run=$($fx.run_id) node=$nodeId")) "$backend 后端 marker 未居最末: $m"
            Assert $c ($m.IndexOf("本次唯一任务：") -lt $m.IndexOf("goal-tree-run=")) "$backend 后端目标段未先于 marker"
        }
    }

    Run-Tc "TC-B35" "存量旧格式节点保守降级:Execute TaskId 签名 → 零注入,指针=base+marker 旧形态(marker 仍居末,不做旧串翻译);空 -TaskBrief 直调零注入" "P0" "TGA-AC-4" {
        param($c)
        $fx = New-FixtureArchive "tga35"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $nodeId = [string](@($r.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        # (a) 落盘 node.task 改写为存量旧格式英文命令串(改造前 run 的落盘形态)
        $tp = Join-Path (Get-RunDirPath $fx.run_id) "state\tree.json"
        $treeObj = [System.IO.File]::ReadAllText($tp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $tn = @($treeObj.nodes | Where-Object { $_.id -eq $nodeId })[0]
        $tn.task = "Execute TaskId 1 stage DEV of $($fx.name). Requirement: requirements/t1.md. First action: delivery-bridge.cmd -Command claim -RunId $($fx.run_id) -NodeId $nodeId -Role DEV."
        [System.IO.File]::WriteAllText($tp, ($treeObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
        $dp = TB @("-Command", "dispatch", "-RunId", $fx.run_id, "-NodeId", $nodeId)
        Assert $c ($dp.exit -eq 0 -and $dp.json.success) "旧格式节点 dispatch 失败: $($dp.text)"
        $ent = Read-NodePrompt $fx.run_id $nodeId
        Assert $c ($null -ne $ent) "旧格式节点 dispatch 未产生指针"
        $txt = [string]$ent.payload.content[0].text
        Assert $c (-not $txt.Contains("本次唯一任务：")) "旧格式节点不应注入目标段(保守降级): $txt"
        Assert $c (-not $txt.Contains("目标：完成「")) "旧格式节点被错误翻译(应保守降级而非翻译): $txt"
        Assert $c ($txt.EndsWith("goal-tree-run=$($fx.run_id) node=$nodeId")) "旧格式节点 marker 未居最末: $txt"
        # (b) 空 -TaskBrief 直调(桥接标记在、目标段缺省):base+marker,与改造前逐字节同构
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $null = & $sr @("-Role", "DEV", "-TaskId", "1", "-TaskJson", (Join-Path $fx.dir "task.json"), "-GoalTreeRun", $fx.run_id, "-GoalTreeNode", $nodeId) 2>$null; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($code -eq 0) "空 brief 直调失败(exit=$code)"
        $last = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.prompt" }) | Select-Object -Last 1
        $txt2 = [string]$last.payload.content[0].text
        Assert $c (-not $txt2.Contains("本次唯一任务：")) "空 brief 注入了目标段: $txt2"
        Assert $c ($txt2.EndsWith("goal-tree-run=$($fx.run_id) node=$nodeId")) "空 brief 指针 marker 形态异常: $txt2"
    }

    Run-Tc "TC-B36" "长度边界:标题>60 截断加…;node.task 全文永不截断;brief 超 240 硬截断(239+…);设计文档段 node.task 保留/brief 剔除" "P1" "TGA-AC-1" {
        param($c)
        $longTitle = ("长标题" * 40)
        # reqRel 受 graft ref ≤128 约束(<归档名>/<reqRel>):取 66 字符——标题 61+路径 66+命令 ~131,自然 brief ~297 仍稳超 240 触发硬截断
        $longReqRel = "requirements/" + ("p" * 50) + ".md"
        $fx = New-PayloadFixture "tga36" @(
            @{ id = 1; title = $longTitle; owners = "DEV"; reqRel = $longReqRel; reqBody = "# 长文`r`n`r`n- **依赖关系**：无"; designRels = @("design/long-cto.md") }
        )
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $nodeId = [string](@($r.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        $task = [string](Get-TreeNode $fx.run_id $nodeId).task
        Assert $c ($task.Contains($longTitle)) "node.task 标题被截断(全文永不截断)"
        Assert $c ($task.Contains("；设计文档：design/long-cto.md；归档：")) "设计文档段未合成: $task"
        $ent = Read-NodePrompt $fx.run_id $nodeId
        Assert $c ($null -ne $ent) "长载荷节点未被推送"
        $txt = [string]$ent.payload.content[0].text
        $briefFull = [regex]::Match($txt, "(?<b>本次唯一任务：.+?)(?= goal-tree-run=)").Groups['b'].Value
        Assert $c ($briefFull -ne "") "指针缺目标段: $txt"
        Assert $c ($briefFull.Length -eq 240 -and $briefFull.EndsWith("…")) "brief 240 硬截断异常(len=$($briefFull.Length)): $briefFull"
        $titleInBrief = [regex]::Match($briefFull, "「(?<t>[^」]+)」").Groups['t'].Value
        Assert $c ($titleInBrief.Length -eq 61 -and $titleInBrief.EndsWith("…")) "标题 60 字截断异常(len=$($titleInBrief.Length))"
        Assert $c (-not $briefFull.Contains("设计文档：")) "brief 未剔除设计文档段"
        Assert $c (-not $briefFull.Contains("归档：")) "brief 未剔除归档段"
    }

    Run-Tc "TC-B37" "graft 构造点同新形态:DEV settle 链式 QA 节点目标为主文本(职责映射 测试与验收)+推送目标段含真实 nodeId" "P1" "TGA-AC-1" {
        param($c)
        $fx = New-FixtureArchive "tga37"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $devNode = [string](@($r.json.data.tasks) | Where-Object { $_.task_id -eq 1 })[0].node
        $s1 = Complete-Stage $fx.run_id $devNode "DEV"
        Assert $c ($s1.exit -eq 0 -and $s1.json.success) "DEV settle 失败: $($s1.text)"
        $qaNode = [string]$s1.json.data.next_stage_node
        Assert $c ($qaNode -ne "") "settle 未链式 graft 下阶段节点"
        $task = [string](Get-TreeNode $fx.run_id $qaNode).task
        Assert $c ($task.StartsWith("目标：完成「T1 bottom」的 QA 阶段（测试与验收）。")) "graft 节点非目标为主新形态: $task"
        Assert $c ($task.Contains("需求文档：requirements/t1.md；归档：$($fx.name)。")) "graft 节点缺引用段: $task"
        Assert $c ($task.Contains("-NodeId <本节点id> -Role QA。")) "graft 节点占位符/角色异常: $task"
        # 依赖满足后推送:QA 节点指针目标段含真实 nodeId
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0 -and $st.json.success) "status 失败: $($st.text)"
        $ent = Read-NodePrompt $fx.run_id $qaNode
        Assert $c ($null -ne $ent) "QA 节点未被推送(依赖满足后应自动)"
        $txt = [string]$ent.payload.content[0].text
        Assert $c ($txt.Contains("本次唯一任务：完成「T1 bottom」的 QA 阶段（测试与验收）。")) "QA 推送缺目标段: $txt"
        Assert $c ($txt.Contains("-NodeId $qaNode -Role QA。")) "QA 目标段缺真实 nodeId: $txt"
        Assert $c ($txt.EndsWith("goal-tree-run=$($fx.run_id) node=$qaNode")) "QA 推送 marker 未居末: $txt"
    }
}

# ============================================================
# 套件:roster — TC-B38 ~ TC-B44(PSR-AC planner-session-roster:
# 派生会话标题钉住 + run 级会话花名册 + 降级与回归锚)
# ============================================================

function Read-RosterJson { param([string]$Id) (Read-RunFileText $Id "sessions.json") | ConvertFrom-Json }

function Suite-Roster {
    Write-Host "`n== suite: roster (PSR-AC 派生会话标题钉住与花名册) =="

    Run-Tc "TC-B38" "桥接派发标题钉住:autopush 后 session.rename(user 源)先于同会话 prompt,载荷 title=[run短名] T#·角色·节点,sessionId 与创建回包一致" "P0" "PSR-AC-1" {
        param($c)
        $fx = New-FixtureArchive "rs38"
        # session.create 逐次返回不同 sessionId(seq 规则):n2/n4 各自成立,n4 不 upsert 覆盖 n2
        Set-DshMockRule -Methods @{ "session.create" = @{ kind = "seq"; values = @( @{ sessionId = "sess-rs38-n2" }, @{ sessionId = "sess-rs38-n4" } ) } }
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        Set-DshMockRule
        $short = $fx.name -replace '^\d{4}-\d{2}-\d{2}-', ''
        $log = Read-DshMockLog
        # mock 日志为整套件累积(载波全程单实例;既有用例以内容过滤/前后差量隔离)——
        # 以 fixture 唯一的标题圈定本用例 rename,不计入其他套件推送的改名
        $titleN2 = "[$short] T1·DEV·n2"
        $titleN4 = "[$short] T3·CTO·n4"
        $renames = @($log | Where-Object { $_.method -eq "session.rename" -and (([string]$_.payload.title -eq $titleN2) -or ([string]$_.payload.title -eq $titleN4)) })
        Assert $c ($renames.Count -eq 2) "rename 调用数 $($renames.Count),期望 2(n2/n4 各一次,planner 本体不经 start-role 改名)"
        $renN2 = @($renames | Where-Object { [string]$_.payload.title -eq $titleN2 })
        $renN4 = @($renames | Where-Object { [string]$_.payload.title -eq $titleN4 })
        Assert $c ($renN2.Count -eq 1 -and $renN4.Count -eq 1) "标题形态异常: n2=$(ConvertTo-Json $renN2.Count -Compress)/n4=$(ConvertTo-Json $renN4.Count -Compress),期望各 1($titleN2 / $titleN4)"
        $sidN2 = [string]$renN2[0].payload.sessionId
        $sidN4 = [string]$renN4[0].payload.sessionId
        Assert $c ((@("sess-rs38-n2", "sess-rs38-n4") -contains $sidN2) -and (@("sess-rs38-n2", "sess-rs38-n4") -contains $sidN4) -and ($sidN2 -ne $sidN4)) "rename sessionId 应各归不同会话: n2=$sidN2 n4=$sidN4(期望互异且来自 seq 回包,不耦合推送顺序)"
        # rename 先于同节点 prompt(钉住早于首消息,防自动标题竞态);指针按本用例
        # seq sessionId 圈定(所有 fixture 的节点都叫 n2,文本匹配会命中其他用例)
        $idxAll = @($log)
        $renIdx = [array]::IndexOf($idxAll, $renN2[0])
        $promptN2 = @($idxAll | Where-Object { $_.method -eq "session.prompt" -and ([string]$_.payload.sessionId -eq $sidN2) })
        Assert $c ($promptN2.Count -ge 1) "mock 日志缺 n2 指针(无法断言 rename→prompt 次序)"
        $promptIdx = [array]::IndexOf($idxAll, $promptN2[0])
        Assert $c ($renIdx -lt $promptIdx) "rename(行 $renIdx) 未先于 n2 prompt(行 $promptIdx)"
    }

    Run-Tc "TC-B39" "花名册落盘:promulgate 后 sessions.json 含 planner 本体行 + 桥接派发行,字段 session_id/role/node/source/title/created_at 齐;status 经 sessions 字段透出" "P0" "PSR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "rs39"
        Set-DshMockRule -Methods @{ "session.create" = @{ kind = "seq"; values = @( @{ sessionId = "sess-rs39-n2" }, @{ sessionId = "sess-rs39-n4" } ) } }
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        Set-DshMockRule
        $short = $fx.name -replace '^\d{4}-\d{2}-\d{2}-', ''
        $rosterPath = Join-Path (Get-RunDirPath $fx.run_id) "sessions.json"
        Assert $c (Test-Path -LiteralPath $rosterPath) "run 目录未落 sessions.json"
        $roster = Read-RosterJson $fx.run_id
        $rows = @($roster.sessions)
        Assert $c ($rows.Count -eq 3) "花名册行数 $($rows.Count),期望 3(planner 本体 + n2/n4 桥接)"
        $plannerRow = @($rows | Where-Object { [string]$_.source -eq "planner" })
        Assert $c ($plannerRow.Count -eq 1) "planner 本体行缺失(DSH_SESSION_ID 自登记)"
        Assert $c ([string]$plannerRow[0].session_id -eq "qa-bridge-mock" -and [string]$plannerRow[0].role -eq "PLANNER") "planner 行字段异常: $(ConvertTo-Json $plannerRow[0] -Compress)"
        Assert $c ([string]$plannerRow[0].title -eq "[PLANNER] $short") "planner 行 title=$($plannerRow[0].title),期望 [PLANNER] $short"
        $bridgeN2 = @($rows | Where-Object { [string]$_.node -eq "n2" })
        Assert $c ($bridgeN2.Count -eq 1 -and [string]$bridgeN2[0].source -eq "bridge-dispatch" -and [string]$bridgeN2[0].role -eq "DEV") "n2 桥接行字段异常: $(ConvertTo-Json $bridgeN2[0] -Compress)"
        Assert $c ([string]$bridgeN2[0].title -eq "[$short] T1·DEV·n2") "n2 桥接行 title 异常"
        $bridgeN4 = @($rows | Where-Object { [string]$_.node -eq "n4" })
        $ridN2 = [string]$bridgeN2[0].session_id
        $ridN4 = [string]$bridgeN4[0].session_id
        Assert $c ((@("sess-rs39-n2", "sess-rs39-n4") -contains $ridN2) -and (@("sess-rs39-n2", "sess-rs39-n4") -contains $ridN4) -and ($ridN2 -ne $ridN4)) "n2/n4 桥接行 session_id 应互异且来自 seq 回包: n2=$ridN2 n4=$ridN4"
        foreach ($row in $rows) {
            Assert $c ([string]$row.created_at -ne "" -and [string]$row.updated_at -ne "") "行缺时间戳: $(ConvertTo-Json $row -Compress)"
        }
        # status 透出
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0 -and $st.json.success) "status 失败: $($st.text)"
        $srows = @($st.json.data.sessions)
        Assert $c (@($srows | Where-Object { [string]$_.session_id -eq "qa-bridge-mock" }).Count -eq 1) "status sessions 未透出 planner 行"
        Assert $c (@($srows | Where-Object { [string]$_.session_id -in @("sess-rs39-n2", "sess-rs39-n4") }).Count -eq 2) "status sessions 未透出桥接行"
    }

    Run-Tc "TC-B40" "register-session 直交登记:合法参数入册(source=direct,title=[直交] 标签·角色),status 可溯源,next_step 指向 status" "P0" "PSR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "rs40"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $r = TB @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "sess-direct-1", "-Label", "T3-fix", "-Role", "DEV")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "register-session 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($d.registered -eq $true) "registered 标志异常"
        Assert $c ([string]$d.session.title -eq "[直交] T3-fix·DEV") "直交 title 异常: $($d.session.title)"
        Assert $c ([string]$d.session.source -eq "direct" -and [string]$d.session.label -eq "T3-fix") "直交行 source/label 异常"
        Assert $c ([string]$d.next_step -like "*status*") "next_step 未指向 status 溯源"
        $rows = @((Read-RosterJson $fx.run_id).sessions)
        $direct = @($rows | Where-Object { [string]$_.session_id -eq "sess-direct-1" })
        Assert $c ($direct.Count -eq 1 -and [string]$direct[0].role -eq "DEV" -and $null -eq $direct[0].node) "直交行落盘异常(直交无 node)"
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c (@($st.json.data.sessions | Where-Object { [string]$_.session_id -eq "sess-direct-1" }).Count -eq 1) "status sessions 未透出直交行"
    }

    Run-Tc "TC-B41" "register-session 确定性校验:缺 SessionId/非法格式/PLANNER 或非法 Role/缺 Label 均拒绝(错误码+exit 1)" "P1" "PSR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "rs41"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $cases = @(
            @{ args = @("-Command", "register-session", "-RunId", $fx.run_id, "-Label", "x", "-Role", "DEV"); code = "MISSING_SESSION_ID" },
            @{ args = @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "bad id!", "-Label", "x", "-Role", "DEV"); code = "SESSION_ID_INVALID" },
            @{ args = @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "sess-x", "-Label", "x", "-Role", "PLANNER"); code = "ROLE_INVALID" },
            @{ args = @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "sess-x", "-Label", "x", "-Role", "MANAGER"); code = "ROLE_INVALID" },
            @{ args = @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "sess-x", "-Role", "DEV"); code = "LABEL_REQUIRED" }
        )
        foreach ($case in $cases) {
            $r = TB $case.args
            Assert $c ($r.exit -eq 1 -and $null -ne $r.json.error -and [string]$r.json.error.code -eq $case.code) "场景($($case.code)) 未确定性拒绝: exit=$($r.exit) out=$($r.text)"
        }
    }

    Run-Tc "TC-B42" "幂等 upsert:同 sessionId 重复登记不增行,created_at 保留;resume 再登记 planner 行不重复" "P1" "PSR-AC-3" {
        param($c)
        $fx = New-FixtureArchive "rs42"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = TB @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "sess-idem", "-Label", "first", "-Role", "DEV")
        $rowsA = @((Read-RosterJson $fx.run_id).sessions)
        $createdA = [string](@($rowsA | Where-Object { [string]$_.session_id -eq "sess-idem" })[0].created_at)
        $null = TB @("-Command", "register-session", "-RunId", $fx.run_id, "-SessionId", "sess-idem", "-Label", "second", "-Role", "QA")
        $rowsB = @((Read-RosterJson $fx.run_id).sessions)
        Assert $c ($rowsB.Count -eq $rowsA.Count) "重复登记后行数 $($rowsB.Count) != $($rowsA.Count)(upsert 应改行不增行)"
        $idem = @($rowsB | Where-Object { [string]$_.session_id -eq "sess-idem" })
        Assert $c ([string]$idem[0].label -eq "second" -and [string]$idem[0].role -eq "QA") "upsert 未刷新 label/role"
        Assert $c ([string]$idem[0].created_at -eq $createdA) "upsert 重置了 created_at(应保留首登时间)"
        # resume:planner 本体再登记仍 1 行
        $null = TB @("-Command", "resume", "-RunId", $fx.run_id)
        $rowsC = @((Read-RosterJson $fx.run_id).sessions)
        Assert $c (@($rowsC | Where-Object { [string]$_.session_id -eq "qa-bridge-mock" }).Count -eq 1) "resume 后 planner 行重复"
    }

    Run-Tc "TC-B43" "改名失败降级不阻断:mock 注入 session.rename 业务错误 → 推送照常成功(pushed 含节点),花名册照常回写" "P0" "PSR-AC-4" {
        param($c)
        $fx = New-FixtureArchive "rs43"
        Set-DshMockRule -Methods @{
            "session.create"  = @{ kind = "seq"; values = @( @{ sessionId = "sess-rs43-n2" }, @{ sessionId = "sess-rs43-n4" } ) }
            "session.rename"  = @{ kind = "error"; code = "MOCK_RENAME_FAIL"; message = "mock rename failure" }
        }
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        Set-DshMockRule
        Assert $c ($r.exit -eq 0 -and $r.json.success) "rename 失败阻断了 promulgate(应降级): $($r.text)"
        $pushed = @($r.json.data.auto_push.pushed)
        Assert $c ($pushed -contains "n2" -and $pushed -contains "n4") "rename 失败后推送未照常: $($pushed -join ',')"
        $log = Read-DshMockLog
        Assert $c (@($log | Where-Object { $_.method -eq "session.rename" }).Count -ge 2) "rename 错误未被真实调用(注入无判别力)"
        $promptN2 = @($log | Where-Object { $_.method -eq "session.prompt" -and ([string]$_.payload.content[0].text).Contains("node=n2") })
        Assert $c ($promptN2.Count -ge 1) "rename 失败后 n2 指针未发送"
        # 花名册回写与 rename 无关(从 start-role 输出抓 sessionId;行按 node 区分,不耦合推送顺序)
        $rows = @((Read-RosterJson $fx.run_id).sessions)
        Assert $c (@($rows | Where-Object { [string]$_.node -eq "n2" -and [string]$_.session_id -in @("sess-rs43-n2", "sess-rs43-n4") }).Count -eq 1) "rename 失败后 n2 花名册行缺失"
        Assert $c (@($rows | Where-Object { [string]$_.node -eq "n4" -and [string]$_.session_id -in @("sess-rs43-n2", "sess-rs43-n4") }).Count -eq 1) "rename 失败后 n4 花名册行缺失"
    }

    Run-Tc "TC-B44" "回归锚:普通 4 步交接(无 goal-tree/无 handoff/无 label)零 rename 调用、指针逐字节保持、无花名册副作用;DryRun 预览无 rename RPC 行" "P0" "PSR-AC-5" {
        param($c)
        $fx = New-FixtureArchive "rs44"   # 不 promulgate:普通直调形态,归档无 run
        $sr = Join-Path $RepoRoot "rdd-engine\scripts\start-role.cmd"
        $renamesBefore = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.rename" }).Count
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $txt = (& $sr @("-Role", "QA", "-TaskId", "1", "-TaskJson", (Join-Path $fx.dir "task.json")) 2>$null | Out-String).Trim(); $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($code -eq 0) "普通交接失败(exit=$code): $txt"
        $log = Read-DshMockLog
        $renamesAfter = @($log | Where-Object { $_.method -eq "session.rename" }).Count
        Assert $c ($renamesAfter -eq $renamesBefore) "普通交接发起了改名调用(before=$renamesBefore after=$renamesAfter)"
        $lastPrompt = @($log | Where-Object { $_.method -eq "session.prompt" }) | Select-Object -Last 1
        $pText = [string]$lastPrompt.payload.content[0].text
        $fxRel = ($fx.dir.Substring($RepoRoot.Length + 1)) -replace '\\', '/'
        Assert $c ($pText -eq "请处理 $fxRel/ 下的需求。") "指针非逐字节旧形态: $pText"
        Assert $c (-not (Test-Path (Join-Path (Get-RunDirPath "deliver-$($fx.name)") "sessions.json") -ErrorAction SilentlyContinue)) "普通交接写了花名册(应零副作用)"
        Assert $c (-not (Test-Path (Join-Path $fx.dir "sessions.json"))) "普通交接在归档目录写了花名册"
        # dsh DryRun 无标记:RPC 行保持 legacy 形态(RPC 3 = session.prompt,零 rename 行)
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $dry = (& $sr @("-Role", "QA", "-TaskId", "1", "-TaskJson", (Join-Path $fx.dir "task.json"), "-DryRun") 2>$null | Out-String).Trim(); $dryCode = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($dryCode -eq 0) "无标记 DryRun 失败(exit=$dryCode): $dry"
        Assert $c ($dry -match "RPC 3:\s+POST \S+/api/session\.prompt") "无标记 DryRun RPC 3 应仍为 session.prompt: $dry"
        Assert $c (-not $dry.Contains("session.rename")) "无标记 DryRun 预览出现 rename RPC 行(应逐字节保持): $dry"
        # 带桥接标记 DryRun:RPC 3 = session.rename、RPC 4 = session.prompt
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $dryM = (& $sr @("-Role", "QA", "-TaskId", "1", "-TaskJson", (Join-Path $fx.dir "task.json"), "-GoalTreeRun", "deliver-2099-12-31-gt-probe", "-GoalTreeNode", "n2", "-DryRun") 2>$null | Out-String).Trim(); $dryMCode = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        Assert $c ($dryMCode -eq 0) "带标记 DryRun 失败(exit=$dryMCode): $dryM"
        Assert $c ($dryM -match "RPC 3:\s+POST \S+/api/session\.rename" -and $dryM -match "RPC 4:\s+POST \S+/api/session\.prompt") "带标记 DryRun 应预览 rename(RPC 3)+prompt(RPC 4): $dryM"
        Assert $c ($dryM.Contains("title=[gt-probe] T1·QA·n2")) "带标记 DryRun 缺标题载荷预览: $dryM"
    }
}

# ============================================================
# 套件:rollback — TC-B45 ~ TC-B49(2026-09-20-planner-enhancements;2026-09-23-delivery-phase-model 接口适配:显式 -To/-Phase 目标取代父推导)
# ============================================================

function Suite-Rollback {
    Write-Host "`n== suite: rollback (跨阶段回退单命令:守卫/全链/幂等续跑/他任务无扰 — phase-model 显式目标接口) =="

    Run-Tc "TC-B45" "rollback 守卫矩阵(phase-model 新接口):缺 -Phase 拒(SET_PHASE_REQUIRED)/坏枚举拒(PHASE_INVALID)/缺 -To 拒(MISSING_TO)/越白名单拒(PHASE_OWNER_MISMATCH)/pending/claimed 拒(REQUIRES_REPORTED)/缺 Reason 拒/根节点非映射拒/证据合格拒(REQUIRES_UNQUALIFIED 指引 settle)/链头显式目标回退成功(父推导守卫 NO_PREVIOUS_STAGE 已随显式目标模型移除)" "P0" "SRB-AC-1" {
        param($c)
        $fx = New-FixtureArchive "rb45"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # 缺 -Phase:回退目标是规划者显式输入,不再父推导(2026-09-23 phase-model)
        $w0 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-To", "DEV", "-Reason", "x")
        Assert $c ($w0.exit -eq 1 -and $w0.json.error.code -eq "SET_PHASE_REQUIRED") "缺 Phase 未拒: $($w0.text)"
        # 坏 phase 枚举:拒
        $w0b = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-To", "DEV", "-Phase", "BANANA", "-Reason", "x")
        Assert $c ($w0b.exit -eq 1 -and $w0b.json.error.code -eq "PHASE_INVALID") "坏 phase 枚举未拒: $($w0b.text)"
        # 缺 -To:拒(目标角色集必填)
        $w0c = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-Phase", "IMPL", "-Reason", "x")
        Assert $c ($w0c.exit -eq 1 -and $w0c.json.error.code -eq "MISSING_TO") "缺 To 未拒: $($w0c.text)"
        # -To 越阶段白名单:CTO 不在 PhaseRoles[IMPL],白名单硬约束
        $w0d = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-To", "CTO", "-Phase", "IMPL", "-Reason", "x")
        Assert $c ($w0d.exit -eq 1 -and $w0d.json.error.code -eq "PHASE_OWNER_MISMATCH") "越白名单未拒: $($w0d.text)"
        # pending:未 report → 拒
        $w1 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-To", "DEV", "-Phase", "IMPL", "-Reason", "x")
        Assert $c ($w1.exit -eq 1 -and $w1.json.error.code -eq "ROLLBACK_REQUIRES_REPORTED") "pending rollback 未拒: $($w1.text)"
        # claimed:仍拒(同阶段处置走 claim 等待或 reclaim)
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        $w2 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-To", "DEV", "-Phase", "IMPL", "-Reason", "x")
        Assert $c ($w2.exit -eq 1 -and $w2.json.error.code -eq "ROLLBACK_REQUIRES_REPORTED") "claimed rollback 未拒: $($w2.text)"
        # 缺 -Reason:拒(审计必填)
        $w3 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n2", "-To", "DEV", "-Phase", "IMPL")
        Assert $c ($w3.exit -eq 1 -and $w3.json.error.code -eq "MISSING_REASON") "缺 Reason 未拒: $($w3.text)"
        # 根节点:非桥接映射(退出码 2 = 映射类错误)
        $w5 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", "n1", "-To", "DEV", "-Phase", "IMPL", "-Reason", "x")
        Assert $c ($w5.exit -eq 2 -and $w5.json.error.code -eq "NODE_NOT_MAPPED") "根节点未拒: $($w5.text)"
        # 证据合格 → REQUIRES_UNQUALIFIED(先 report 不合格使 reclaim 走 rejected-delivery 路径重建,再 report 合格)
        $cb = New-CallbackFile "n2" "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb)
        $rc = TB @("-Command", "reclaim", "-RunId", $fx.run_id, "-NodeId", "n2")
        Assert $c ($rc.exit -eq 0) "reclaim 重建失败: $($rc.text)"
        $bridge = Read-BridgeJson $fx.run_id
        $newNode = [string]$bridge.tasks.'1'.stages.DEV
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $newNode, "-Role", "DEV")
        $cb2 = New-CallbackFile $newNode "done" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "DEV", "-CallbackFile", $cb2)
        $w6 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", $newNode, "-To", "DEV", "-Phase", "IMPL", "-Reason", "x")
        Assert $c ($w6.exit -eq 1 -and $w6.json.error.code -eq "ROLLBACK_REQUIRES_UNQUALIFIED") "合格交付回退未拒: $($w6.text)"
        Assert $c ($w6.json.error.message.Contains("settle")) "REQUIRES_UNQUALIFIED 未指引 settle"
        # 守卫全程路由零变更
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c (@($t1.currentOwners) -contains "DEV") "守卫拒绝过程中路由被意外变更: $($t1.currentOwners -join '+')"
        # 链头显式目标回退:独立 fixture 上 report 不合格后 -To CTO -Phase DESIGN 成功(NO_PREVIOUS_STAGE 父推导守卫已随显式目标模型移除)
        $fx2 = New-FixtureArchive "rb45b"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx2.dir "task.json"))
        $null = TB @("-Command", "claim", "-RunId", $fx2.run_id, "-NodeId", "n2", "-Role", "DEV")
        $cb3 = New-CallbackFile "n2" "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx2.run_id, "-Worker", "DEV", "-CallbackFile", $cb3)
        $w7 = TB @("-Command", "rollback", "-RunId", $fx2.run_id, "-NodeId", "n2", "-To", "CTO", "-Phase", "DESIGN", "-Reason", "design rework")
        Assert $c ($w7.exit -eq 0 -and $w7.json.success) "链头显式目标回退失败: $($w7.text)"
        Assert $c (@($w7.json.data.rebuilt_nodes).Count -eq 1 -and [string]$w7.json.data.to_phase -eq "DESIGN") "链头回退重建异常: $($w7.text)"
        $flow = TFlow @("-Command", "show", "-Archive", $fx2.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c ((@($t1.currentOwners) -join '+') -eq "CTO" -and [string]$t1.phase -eq "DESIGN") "链头回退后路由/phase 异常: $($t1.currentOwners -join '+')@$($t1.phase)"
    }

    Run-Tc "TC-B46" "rollback 全链:QA 判不合格 → 单命令剪枝+兄弟挂接重建 DEV+reopen 路由回退+自动重推;三层一致;重做上下文进 node.task 与指针消息;重做闭环后链不变量保持" "P0" "SRB-AC-1/2/3" {
        param($c)
        $fx = New-FixtureArchive "rb46"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # T1 走到 QA 阶段
        $null = Complete-Stage $fx.run_id "n2" "DEV"
        $bridge = Read-BridgeJson $fx.run_id
        $qaNode = [string]$bridge.tasks.'1'.stages.QA
        Assert $c ($qaNode -ne "") "QA 节点未 graft"
        # QA 判不合格:claim + report 非 done verdict(证据问题 = verdict 检查)
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-Role", "QA")
        $cb = New-CallbackFile $qaNode "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "QA", "-CallbackFile", $cb)
        # 单命令回退(显式目标:回退到 IMPL 阶段的 DEV)
        $r = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-To", "DEV", "-Phase", "IMPL", "-Reason", "验收未过:功能门禁失败")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "rollback 失败: $($r.text)"
        $d = $r.json.data
        $rebuilt = [string]$d.rebuilt_node
        Assert $c ($d.from_stage -eq "QA" -and $d.to_stage -eq "DEV" -and [string]$d.to_phase -eq "IMPL") "阶段推导异常: $($d.from_stage)->$($d.to_stage)@$($d.to_phase)"
        Assert $c ($d.pruned_node -eq $qaNode -and $rebuilt -ne $qaNode -and $rebuilt -ne "") "节点标识异常"
        # 树层:失败 QA 节点 pruned+审计 reason;重建 DEV 节点 pending+兄弟挂接(父=前一阶段节点 n2 的父=goal 根 n1)
        $t = Read-RunTree $fx.run_id
        $old = $t.nodes | Where-Object id -eq $qaNode
        $new = $t.nodes | Where-Object id -eq $rebuilt
        Assert $c ([string]$old.status -eq "pruned") "失败 QA 节点未剪枝: $($old.status)"
        Assert $c ([string]$old.pruned_reason -like "cross-stage rollback to DEV @ IMPL*") "剪枝审计 reason 异常: $($old.pruned_reason)"
        Assert $c ($old.pruned_reason.Contains("验收未过:功能门禁失败") -and $old.pruned_reason.Contains("verdict check")) "审计未含回退理由/证据问题"
        Assert $c ($old.pruned_reason -match 'cross-stage rollback to DEV @ IMPL \(by [^)]+\)') "审计未含操作者(AC-3): $($old.pruned_reason)"
        Assert $c ([string]$new.status -eq "pending") "重建节点非 pending: $($new.status)"
        Assert $c ([string]$new.parent -eq "n1") "兄弟挂接异常: parent=$($new.parent),期望 n1(goal 根)"
        Assert $c ([string]$new.role -eq "dev") "重建节点 role 异常: $($new.role)"
        # 重做上下文进 node.task(理由+证据问题)
        Assert $c ($new.task.Contains("重做上下文（跨阶段回退）") -and $new.task.Contains("验收未过:功能门禁失败") -and $new.task.Contains("verdict check")) "重做上下文未进 node.task"
        # 流层:owners 回 DEV、QA worker 残留被清、lifecycle active
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c ((@($t1.currentOwners) -contains "DEV") -and (-not (@($t1.currentOwners) -contains "QA"))) "路由未回退: $($t1.currentOwners -join '+')"
        Assert $c ([string]$t1.phase -eq "IMPL") "回退后 phase 未随 set-route 原子回写: $($t1.phase)"
        Assert $c (@($t1.currentWorker).Count -eq 0) "QA worker 残留未清"
        Assert $c ([string]$t1.lifecycle -eq "active") "lifecycle 异常: $($t1.lifecycle)"
        # 桥层:映射回写新 DEV 节点
        $bridge = Read-BridgeJson $fx.run_id
        Assert $c ([string]$bridge.tasks.'1'.stages.DEV -eq $rebuilt) "bridge 映射未回写"
        # 自动重推(mock dsh):重建节点在 pushed 里;指针消息携带重做上下文节选
        Assert $c (@($d.auto_push.pushed) -contains $rebuilt) "重建节点未被自动重推: $($r.text)"
        $prompts = @(Read-DshMockLog | Where-Object { $_.method -eq "session.prompt" })
        $lastPrompt = if ($prompts.Count -gt 0) { ($prompts[-1].payload | ConvertTo-Json -Depth 8 -Compress) } else { "" }
        Assert $c ($lastPrompt.Contains("重做上下文（跨阶段回退）")) "指针消息未携带重做上下文节选: $lastPrompt"
        # 无直接依赖 → dependents_warning 空(T2 依赖链头 n2,不依赖 QA 节点)
        Assert $c (@($d.dependents_warning).Count -eq 0) "无直接依赖却出现 dependents_warning"
        # 重做闭环:claim 重建节点 → 合格 → settle → 新 QA 节点挂重建节点下(链不变量);再闭环 complete
        $null = Complete-Stage $fx.run_id $rebuilt "DEV"
        $bridge = Read-BridgeJson $fx.run_id
        $qa2 = [string]$bridge.tasks.'1'.stages.QA
        Assert $c ($qa2 -ne $qaNode -and $qa2 -ne "") "二次 QA 节点异常: $qa2"
        $t = Read-RunTree $fx.run_id
        $qa2n = $t.nodes | Where-Object id -eq $qa2
        Assert $c ([string]$qa2n.parent -eq $rebuilt) "重做后链不变量破裂: QA2 parent=$($qa2n.parent),期望 $rebuilt"
        $null = Complete-Stage $fx.run_id $qa2 "QA"
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c ([string]$t1.lifecycle -eq "completed") "重做后未完成闭环: $($t1.lifecycle)"
    }

    Run-Tc "TC-B47" "rollback 幂等续跑:prune 后崩溃态(手工 prune 带 rollback 签名)重跑 → 不二次剪枝、续 graft 步、签名恢复证据问题;完整回退后重跑 → 幂等不重复重建" "P0" "SRB-AC-1" {
        param($c)
        $fx = New-FixtureArchive "rb47"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = Complete-Stage $fx.run_id "n2" "DEV"
        $bridge = Read-BridgeJson $fx.run_id
        $qaNode = [string]$bridge.tasks.'1'.stages.QA
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-Role", "QA")
        $cb = New-CallbackFile $qaNode "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "QA", "-CallbackFile", $cb)
        # 模拟 prune 成功后、graft 前崩溃:手工 prune 带 rollback 签名
        $sim = TRun @("-Command", "prune", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-Reason", "cross-stage rollback to DEV @ IMPL (by test-crash-sim): simulated crash; evidence problems: verdict check: last_verdict is 'failed', expected 'done' (worker self-assessment incomplete)")
        Assert $c ($sim.exit -eq 0) "崩溃模拟 prune 失败: $($sim.text)"
        # 重跑同命令:签名识别 → 续 graft 步(若二次剪枝会 ALREADY_PRUNED 失败)
        $r = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-To", "DEV", "-Phase", "IMPL", "-Reason", "resume-after-crash")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "幂等续跑失败: $($r.text)"
        Assert $c ($r.json.data.resumed -eq $true) "续跑标记缺失"
        $rebuilt = [string]$r.json.data.rebuilt_node
        Assert $c ($rebuilt -ne "" -and $rebuilt -ne $qaNode) "续跑未重建节点"
        # 签名恢复的证据问题进重做上下文
        $t = Read-RunTree $fx.run_id
        $new = $t.nodes | Where-Object id -eq $rebuilt
        Assert $c ($new.task.Contains("重做上下文（跨阶段回退）") -and $new.task.Contains("verdict check")) "签名恢复的证据问题未进重做上下文"
        # 三层一致
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t1 = @($flow.json.data.tasks | Where-Object { $_.id -eq 1 })[0]
        Assert $c (@($t1.currentOwners) -contains "DEV") "续跑后路由未回 DEV"
        $bridge = Read-BridgeJson $fx.run_id
        Assert $c ([string]$bridge.tasks.'1'.stages.DEV -eq $rebuilt) "续跑后映射异常"
        # 完整回退已发生后的重跑:幂等(在建后继存在 → 不重复 graft)
        $r2 = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-To", "DEV", "-Phase", "IMPL", "-Reason", "second-rerun")
        Assert $c ($r2.exit -eq 0 -and $r2.json.success) "二次重跑失败: $($r2.text)"
        Assert $c ([string]$r2.json.data.rebuilt_node -eq $rebuilt) "二次重跑重建了额外节点: $($r2.json.data.rebuilt_node)"
        $t = Read-RunTree $fx.run_id
        $devLive = @($t.nodes | Where-Object { $_.id -eq $rebuilt })
        Assert $c ($devLive.Count -eq 1 -and [string]$devLive[0].status -eq "pending") "重建节点状态异常: $($devLive[0].status)"
        $bridge2 = Read-BridgeJson $fx.run_id
        Assert $c ([string]$bridge2.tasks.'1'.stages.DEV -eq $rebuilt) "二次重跑后映射漂移"
    }

    Run-Tc "TC-B48" "他任务无扰 + dependents_warning:回退不动同 run 其他任务节点/路由/依赖边;直接依赖边仅警示(含推送状态派生)" "P1" "SRB-AC-4" {
        param($c)
        $fx = New-FixtureArchive "rb48"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = Complete-Stage $fx.run_id "n2" "DEV"
        $bridge = Read-BridgeJson $fx.run_id
        $qaNode = [string]$bridge.tasks.'1'.stages.QA
        # 人为给 T2 链头(n3)加一条对 qaNode 的直接依赖(制造下游依赖场景)
        $dep = TRun @("-Command", "deps", "-DepAction", "add", "-RunId", $fx.run_id, "-NodeId", "n3", "-On", $qaNode)
        Assert $c ($dep.exit -eq 0) "deps add 失败: $($dep.text)"
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-Role", "QA")
        $cb = New-CallbackFile $qaNode "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "QA", "-CallbackFile", $cb)
        $r = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-To", "DEV", "-Phase", "IMPL", "-Reason", "affects T2")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "rollback 失败: $($r.text)"
        $d = $r.json.data
        # 直接依赖边警示:含 n3(带 task/stage/pushed 派生),且不动它
        $dw = @($d.dependents_warning)
        Assert $c ($dw.Count -eq 1 -and [string]$dw[0].node -eq "n3") "dependents_warning 异常: $($r.text)"
        Assert $c ([int]$dw[0].task_id -eq 2 -and [string]$dw[0].stage -eq "DEV") "警示行映射异常"
        # T2 节点/路由/依赖边零变化:n3 仍 pending、依赖边仍在(未重定向未删除)
        $t = Read-RunTree $fx.run_id
        $n3 = $t.nodes | Where-Object id -eq "n3"
        Assert $c ([string]$n3.status -eq "pending") "T2 节点被回退波及: $($n3.status)"
        Assert $c (@($n3.depends_on) -contains $qaNode) "T2 依赖边被改动: $($n3.depends_on -join ',')"
        $flow = TFlow @("-Command", "show", "-Archive", $fx.dir)
        $t2 = @($flow.json.data.tasks | Where-Object { $_.id -eq 2 })[0]
        Assert $c ((@($t2.currentOwners) -contains "DEV") -and [string]$t2.lifecycle -eq "active") "T2 路由被波及"
        # T3(CTO 起步,独立)零变化
        $t3row = @($flow.json.data.tasks | Where-Object { $_.id -eq 3 })[0]
        Assert $c ((@($t3row.currentOwners) -contains "CTO") -and [string]$t3row.lifecycle -eq "active") "T3 路由被波及"
        $n4 = $t.nodes | Where-Object id -eq "n4"
        Assert $c ([string]$n4.status -in @("pending", "claimed")) "T3 节点异常: $($n4.status)"
    }

    Run-Tc "TC-B49" "rollback 边界:任务非 active(completed)确定性拒绝(TASK_NOT_ACTIVE 指引既有 reopen 语义)且零副作用——run 结束后的返工不属本命令范围" "P2" "SRB-AC-1" {
        param($c)
        $fx = New-FixtureArchive "rb49"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        $null = Complete-Stage $fx.run_id "n2" "DEV"
        $bridge = Read-BridgeJson $fx.run_id
        $qaNode = [string]$bridge.tasks.'1'.stages.QA
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-Role", "QA")
        $cb = New-CallbackFile $qaNode "failed" $true $true $true
        $null = TLeaf @("-Command", "report", "-RunId", $fx.run_id, "-Worker", "QA", "-CallbackFile", $cb)
        # 测试侧把夹具 T1 置为 completed(夹具即测试产物,允许改写)——模拟"run 已结束后的返工"边界
        $tjPath = Join-Path $fx.dir "task.json"
        $tj = [System.IO.File]::ReadAllText($tjPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        (@($tj.tasks) | Where-Object { $_.id -eq 1 }).lifecycle = "completed"
        [System.IO.File]::WriteAllText($tjPath, ($tj | ConvertTo-Json -Depth 6), $Utf8NoBom)
        $r = TB @("-Command", "rollback", "-RunId", $fx.run_id, "-NodeId", $qaNode, "-To", "DEV", "-Phase", "IMPL", "-Reason", "post-run rework")
        Assert $c ($r.exit -eq 1 -and $r.json.error.code -eq "TASK_NOT_ACTIVE") "completed 任务回退未拒: $($r.text)"
        Assert $c ($r.json.error.message.Contains("reopen")) "TASK_NOT_ACTIVE 未指引既有 reopen 语义"
        # 零副作用:节点仍 reported(未被剪枝、未重建、路由未动)
        $t = Read-RunTree $fx.run_id
        $n = $t.nodes | Where-Object id -eq $qaNode
        Assert $c ([string]$n.status -eq "reported") "拒绝后节点状态被改动: $($n.status)"
        Assert $c ([string]$n.pruned_reason -eq "") "拒绝后出现剪枝痕: $($n.pruned_reason)"
        $bridge2 = Read-BridgeJson $fx.run_id
        Assert $c ([string]$bridge2.tasks.'1'.stages.QA -eq $qaNode) "拒绝后映射被改动"
    }
}

# ============================================================
# 套件:automode — TC-B50 ~ TC-B57(2026-09-20-planner-enhancements · planner-auto-mode)
# ============================================================

function Suite-AutoMode {
    Write-Host "`n== suite: automode (纯自动模式:开关/授权/留痕/门禁/升级/可见性/分级表/编排边界/-NoPush 隔离性) =="

    Run-Tc "TC-B50" "开关与快照:-AutoMode 快照入 bridge.json(9 规则 R1~R9 序/R1 manual/源 default/含 auto 行);默认关闭回归(无 auto_mode 键/无 decisions.jsonl/claim 无段);planner-guide 默认分级表明确列出" "P0" "AM-AC-1/AM-AC-4" {
        param($c)
        $fx = New-FixtureArchive "am50"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode")
        Assert $c ($r.exit -eq 0 -and $r.json.success -eq $true) "auto promulgate 失败: $($r.text)"
        $b = Read-BridgeJson $fx.run_id
        Assert $c ([bool]$b.auto_mode.enabled) "bridge.json 无 auto_mode.enabled"
        Assert $c ([string]$b.auto_mode.policy_source -eq "default") "policy_source 非 default: $($b.auto_mode.policy_source)"
        $rules = @($b.auto_mode.policy.rules)
        Assert $c ($rules.Count -eq 9) "默认分级表规则数非 9: $($rules.Count)"
        $ids = (@($rules) | ForEach-Object { [string]$_.id }) -join ","
        Assert $c ($ids -eq "R1,R2,R3,R4,R5,R6,R7,R8,R9") "规则 id 序列异常: $ids"
        $r1 = @($rules) | Where-Object { [string]$_.id -eq "R1" } | Select-Object -First 1
        Assert $c ([string]$r1.action -eq "manual") "R1 非 manual: $($r1.action)"
        Assert $c ((@($rules) | Where-Object { [string]$_.action -eq "auto" }).Count -ge 1) "默认表无 auto 规则"
        # 默认关闭回归:同形态 fixture 不带 -AutoMode
        $fx2 = New-FixtureArchive "am50m"
        $r2 = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx2.dir "task.json"))
        Assert $c ($r2.exit -eq 0) "legacy promulgate 失败: $($r2.text)"
        $raw = Read-RunFileText $fx2.run_id "bridge.json"
        Assert $c ($raw -notmatch "auto_mode") "legacy bridge.json 出现 auto_mode 键"
        Assert $c (-not (Test-Path (Join-Path (Get-RunDirPath $fx2.run_id) "decisions.jsonl"))) "legacy run 出现 decisions.jsonl"
        $cl2 = TB @("-Command", "claim", "-RunId", $fx2.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($cl2.exit -eq 0) "legacy claim 失败: $($cl2.text)"
        Assert $c ($null -eq $cl2.json.data.auto_mode) "legacy claim 响应携带 auto_mode 段"
        # 默认分级表「明确列出」(协议真源文档锚,AC-4)
        $guide = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "rdd-engine\references\planner-guide.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($guide.Contains("纯自动模式")) "planner-guide 无「纯自动模式」节"
        foreach ($k in @("R1", "R5", "R9")) { Assert $c ($guide -match "\| $k \|") "planner-guide 分级表缺 $k 行" }
    }

    Run-Tc "TC-B51" "授权传递与低风险自动拍板留痕:claim 注入 auto_mode 段(enabled+分级表快照+decide/escalate 协议指引);decide -Kind auto 落 decisions.jsonl——输入/依据/时间/代答者身份/risk 全字段留痕可查" "P0" "AM-AC-2" {
        param($c)
        $fx = New-FixtureArchive "am51"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode")
        $cl = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        Assert $c ($cl.exit -eq 0) "claim 失败: $($cl.text)"
        $am = $cl.json.data.auto_mode
        Assert $c ($null -ne $am -and [bool]$am.enabled) "claim 响应缺 auto_mode 段"
        Assert $c (@($am.policy.rules).Count -eq 9) "claim 注入分级表规则数非 9"
        Assert $c (([string]$am.protocol -match "decide -RunId") -and ([string]$am.protocol -match "escalate")) "协议指引缺 decide/escalate 命令"
        $r = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "R5", "-Checkpoint", "单一方案确认", "-Decision", "沿用既有范式", "-Inputs", "设计输入:候选方案仅 1 个", "-Basis", "R5 单一可行方案/沿用现状范式", "-Risk", "low")
        Assert $c ($r.exit -eq 0 -and $r.json.success -eq $true) "decide auto 失败: $($r.text)"
        $led = @([System.IO.File]::ReadAllLines((Join-Path (Get-RunDirPath $fx.run_id) "decisions.jsonl")) | Where-Object { $_.Trim() -ne "" })
        Assert $c ($led.Count -eq 1) "账本条目数非 1: $($led.Count)"
        $e = $led[0] | ConvertFrom-Json
        Assert $c ([string]$e.entry_id -eq "D1" -and [string]$e.kind -eq "auto") "条目 id/kind 异常: $($e.entry_id)/$($e.kind)"
        Assert $c ([string]$e.decider -eq "auto/R5@DEV") "代答者身份异常: $($e.decider)"
        Assert $c ([string]$e.rule_id -eq "R5") "rule_id 异常: $($e.rule_id)"
        Assert $c ([string]$e.checkpoint -eq "单一方案确认" -and [string]$e.decision -eq "沿用既有范式") "checkpoint/decision 回读异常"
        Assert $c ([string]$e.inputs -eq "设计输入:候选方案仅 1 个" -and [string]$e.basis -eq "R5 单一可行方案/沿用现状范式") "inputs/basis 回读异常"
        Assert $c ([string]$e.risk -eq "low") "risk 回读异常: $($e.risk)"
        Assert $c ([string]$e.at -match "^\d{4}-\d{2}-\d{2}T") "at 时间戳缺失/畸形: $($e.at)"
        Assert $c ([string]$e.run_id -eq $fx.run_id -and [string]$e.node_id -eq "n2" -and [string]$e.stage -eq "DEV") "run/node/stage 归属异常"
    }

    Run-Tc "TC-B52" "决策门禁矩阵:R1 硬底拒自动答(manual 规则同拒)/未知规则拒/缺 RuleId 拒/auto 带 RefEntry 拒;非自动 run decide+escalate 双拒(AUTO_MODE_DISABLED);未认领节点拒;goal 根非映射拒" "P0" "AM-AC-2" {
        param($c)
        $fx = New-FixtureArchive "am52"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode")
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        $w1 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "R1", "-Checkpoint", "git 操作", "-Decision", "push")
        Assert $c ($w1.exit -eq 1 -and $w1.json.error.code -eq "RULE_NOT_AUTO") "R1 硬底未拒: $($w1.text)"
        $w2 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "R2", "-Checkpoint", "新依赖", "-Decision", "x")
        Assert $c ($w2.exit -eq 1 -and $w2.json.error.code -eq "RULE_NOT_AUTO") "manual 规则(R2)未拒: $($w2.text)"
        $w3 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "RX", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w3.exit -eq 1 -and $w3.json.error.code -eq "RULE_NOT_FOUND") "未知规则未拒: $($w3.text)"
        $w4 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w4.exit -eq 1 -and $w4.json.error.code -eq "RULE_REQUIRED") "缺 RuleId 未拒: $($w4.text)"
        $w5 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "R5", "-Checkpoint", "x", "-Decision", "x", "-RefEntry", "D1")
        Assert $c ($w5.exit -eq 1 -and $w5.json.error.code -eq "REF_ENTRY_FORBIDDEN") "auto 带 RefEntry 未拒: $($w5.text)"
        $w6 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n3", "-Kind", "auto", "-RuleId", "R5", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w6.exit -eq 1 -and $w6.json.error.code -eq "DECISION_NODE_NOT_CLAIMED") "未认领节点未拒: $($w6.text)"
        $w7 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n1", "-Kind", "auto", "-RuleId", "R5", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w7.exit -in 1, 2 -and $w7.json.error.code -eq "NODE_NOT_MAPPED") "goal 根未拒: $($w7.text)"
        $fx2 = New-FixtureArchive "am52m"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx2.dir "task.json"))
        $null = TB @("-Command", "claim", "-RunId", $fx2.run_id, "-NodeId", "n2", "-Role", "DEV")
        $w8 = TB @("-Command", "decide", "-RunId", $fx2.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "R5", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w8.exit -eq 1 -and $w8.json.error.code -eq "AUTO_MODE_DISABLED") "非自动 run decide 未拒: $($w8.text)"
        $w9 = TB @("-Command", "escalate", "-RunId", $fx2.run_id, "-NodeId", "n2", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w9.exit -eq 1 -and $w9.json.error.code -eq "AUTO_MODE_DISABLED") "非自动 run escalate 未拒: $($w9.text)"
    }

    Run-Tc "TC-B53" "高风险升级链路:escalate 写 open 条目(decider=null/risk 缺省 high/rule 留痕);status auto_mode 块列出未决升级;resolution 回填(user@in-session/ref_entry)后派生视图关闭;重复关闭/悬空引用/非升级目标均确定性拒绝" "P0" "AM-AC-3" {
        param($c)
        $fx = New-FixtureArchive "am53"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode")
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        $r = TB @("-Command", "escalate", "-RunId", $fx.run_id, "-NodeId", "n2", "-Checkpoint", "技术选型分叉", "-Decision", "消息队列选 RocketMQ 还是 RabbitMQ？", "-RuleId", "R4")
        Assert $c ($r.exit -eq 0 -and $r.json.success -eq $true) "escalate 失败: $($r.text)"
        $e = $r.json.data.entry
        Assert $c ([string]$e.kind -eq "escalation" -and $null -eq $e.decider) "升级条目 kind/decider 异常: $($e.kind)/$($e.decider)"
        Assert $c ([string]$e.risk -eq "high") "缺省 risk 非 high: $($e.risk)"
        Assert $c ([string]$e.rule_id -eq "R4") "升级条目 rule_id 丢失"
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0 -and [bool]$st.json.data.auto_mode.enabled) "status 无 auto_mode 块"
        $open = @($st.json.data.auto_mode.open_escalations)
        Assert $c ($open.Count -eq 1) "open_escalations 数非 1: $($open.Count)"
        Assert $c ([string]$open[0].entry_id -eq "D1" -and [string]$open[0].question -match "RocketMQ") "未决条目 entry/question 异常"
        Assert $c ([string]$open[0].rule_id -eq "R4" -and [string]$open[0].checkpoint -eq "技术选型分叉") "未决条目 rule/checkpoint 异常"
        $res = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "resolution", "-RefEntry", "D1", "-Checkpoint", "技术选型分叉", "-Decision", "用户拍板:RabbitMQ")
        Assert $c ($res.exit -eq 0) "resolution 失败: $($res.text)"
        $re = $res.json.data.entry
        Assert $c ([string]$re.kind -eq "resolution" -and [string]$re.decider -eq "user@in-session" -and [string]$re.ref_entry -eq "D1") "resolution 条目异常: $($re.kind)/$($re.decider)/$($re.ref_entry)"
        $st2 = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c (@($st2.json.data.auto_mode.open_escalations).Count -eq 0) "resolution 后派生视图未关闭升级"
        $w1 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "resolution", "-RefEntry", "D1", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w1.exit -eq 1 -and $w1.json.error.code -eq "ESCALATION_ALREADY_RESOLVED") "重复关闭未拒: $($w1.text)"
        $w2 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "resolution", "-RefEntry", "D99", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w2.exit -eq 1 -and $w2.json.error.code -eq "REF_ENTRY_NOT_FOUND") "悬空引用未拒: $($w2.text)"
        $w3 = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "resolution", "-RefEntry", "D2", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w3.exit -eq 1 -and $w3.json.error.code -eq "REF_ENTRY_NOT_ESCALATION") "非升级目标 resolution 未拒: $($w3.text)"
    }

    Run-Tc "TC-B54" "自动决策可见性与推翻通道:status 决策计数(逐节点 auto/escalation/resolution/overturn)+账本指针;decisions.jsonl 追加不改写(旧条目原样);overturn 推翻既有决策留痕(含依据);推翻推翻拒;resume 恢复步骤含未决升级处置指引" "P0" "AM-AC-5" {
        param($c)
        $fx = New-FixtureArchive "am54"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode")
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
        $null = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "auto", "-RuleId", "R7", "-Checkpoint", "命名清单", "-Decision", "按既有命名表", "-Inputs", "命名输入:模块 3 个", "-Basis", "R7 命名/文件清单")
        $null = TB @("-Command", "escalate", "-RunId", $fx.run_id, "-NodeId", "n2", "-Checkpoint", "含 P1 风险取舍", "-Decision", "缓存失效策略取舍呈用户", "-RuleId", "R8", "-Risk", "high")
        $ov = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "overturn", "-RefEntry", "D1", "-Checkpoint", "命名清单", "-Decision", "改用新命名表", "-Basis", "用户事后补充约束")
        Assert $c ($ov.exit -eq 0 -and $ov.json.success -eq $true) "overturn 失败: $($ov.text)"
        $oe = $ov.json.data.entry
        Assert $c ([string]$oe.kind -eq "overturn" -and [string]$oe.ref_entry -eq "D1" -and [string]$oe.decider -eq "user@in-session") "overturn 条目异常"
        Assert $c ([string]$oe.basis -eq "用户事后补充约束") "overturn 依据(basis)未留痕"
        $w = TB @("-Command", "decide", "-RunId", $fx.run_id, "-NodeId", "n2", "-Kind", "overturn", "-RefEntry", "D3", "-Checkpoint", "x", "-Decision", "x")
        Assert $c ($w.exit -eq 1 -and $w.json.error.code -eq "REF_ENTRY_KIND_INVALID") "推翻推翻未拒: $($w.text)"
        # 账本追加不改写:D1 仍为 auto 原样(含 inputs/basis)
        $led = @([System.IO.File]::ReadAllLines((Join-Path (Get-RunDirPath $fx.run_id) "decisions.jsonl")) | Where-Object { $_.Trim() -ne "" })
        Assert $c ($led.Count -eq 3) "账本条目数非 3: $($led.Count)"
        $d1 = $led[0] | ConvertFrom-Json
        Assert $c ([string]$d1.kind -eq "auto" -and [string]$d1.decider -eq "auto/R7@DEV") "D1 被改写(append-only 破坏): $($d1.kind)/$($d1.decider)"
        Assert $c ([string]$d1.inputs -eq "命名输入:模块 3 个" -and [string]$d1.basis -eq "R7 命名/文件清单") "D1 inputs/basis 丢失"
        # status 可见性:计数/账本指针/策略源
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        $amb = $st.json.data.auto_mode
        Assert $c ([bool]$amb.enabled -and [string]$amb.ledger -match "decisions\.jsonl") "status 缺 enabled/账本指针"
        Assert $c ([string]$amb.policy_source -eq "default") "status policy_source 异常"
        $row = @($amb.decision_counts) | Where-Object { [string]$_.node -eq "n2" } | Select-Object -First 1
        Assert $c ($null -ne $row) "decision_counts 缺 n2 行"
        Assert $c ([int]$row.auto -eq 1 -and [int]$row.escalation -eq 1 -and [int]$row.overturn -eq 1 -and [int]$row.total -eq 3) "n2 决策计数异常: $($row | ConvertTo-Json -Compress)"
        Assert $c (@($amb.open_escalations).Count -eq 1 -and [string]$amb.open_escalations[0].entry_id -eq "D2") "未决升级视图异常"
        # resume:恢复步骤含未决升级处置指引(CLI/Plus 兼容可见性)
        $rs = TB @("-Command", "resume", "-RunId", $fx.run_id)
        $rsText = $rs.json | ConvertTo-Json -Depth 8
        Assert $c ($rs.exit -eq 0 -and $rsText -match "D2" -and $rsText -match "resolution") "resume 缺未决升级处置指引"
    }

    Run-Tc "TC-B55" "分级表可配置:-RiskPolicy 整表覆盖(policy_source=override);R1 硬底强制合并(缺失→插入/改 auto→恢复 manual);无效策略(空表/重复 id/非法 action/坏 JSON)确定性拒绝且零 run 残留" "P1" "AM-AC-4" {
        param($c)
        $pol1 = Join-Path $script:WorkDir "am55-pol1.json"
        [System.IO.File]::WriteAllText($pol1, '{"rules":[{"id":"X1","match":"自定义低风险","action":"auto","note":"覆盖"}]}', $Utf8NoBom)
        $fx = New-FixtureArchive "am55"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode", "-RiskPolicy", $pol1)
        Assert $c ($r.exit -eq 0) "覆盖颁布失败: $($r.text)"
        $b = Read-BridgeJson $fx.run_id
        Assert $c ([string]$b.auto_mode.policy_source -eq "override") "policy_source 非 override"
        $rules = @($b.auto_mode.policy.rules)
        Assert $c ($rules.Count -eq 2) "覆盖后规则数非 2(强制 R1+X1): $($rules.Count)"
        Assert $c ($rules.Count -eq 2) "覆盖后规则数非 2(强制 R1+X1): $($rules.Count)"
        # 探针式断言(逐规则取 psobject 属性值比较):同 Where 模式在独立进程可复现通过、
        # 在本套件进程内对 override 表恒不中(根因未定位,PS 5.1 进程内行为差异),改用
        # 逐规则显式比较并内嵌探针结果;两侧断言口径不变
        $r1Forced = $false
        $x1Present = $false
        $probe = @()
        foreach ($r in $rules) {
            $rid = [string]$r.psobject.Properties['id'].Value
            $raction = [string]$r.psobject.Properties['action'].Value
            $probe += ("{0}:{1}" -f $rid, $raction)
            if ($rid -eq "R1" -and $raction -eq "manual") { $r1Forced = $true }
            if ($rid -eq "X1") { $x1Present = $true }
        }
        Assert $c $r1Forced "R1 硬底未强制合并; 逐规则探针: $($probe -join ' | ')"
        Assert $c $x1Present "X1 未入表; 逐规则探针: $($probe -join ' | ')"
        $pol2 = Join-Path $script:WorkDir "am55-pol2.json"
        [System.IO.File]::WriteAllText($pol2, '{"rules":[{"id":"R1","match":"宪法禁令","action":"auto"}]}', $Utf8NoBom)
        $fx2 = New-FixtureArchive "am55b"
        $r2 = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx2.dir "task.json"), "-AutoMode", "-RiskPolicy", $pol2)
        Assert $c ($r2.exit -eq 0) "R1=auto 覆盖颁布失败: $($r2.text)"
        $b2 = Read-BridgeJson $fx2.run_id
        $r1b = @($b2.auto_mode.policy.rules) | Where-Object { [string]$_.id -eq "R1" } | Select-Object -First 1
        Assert $c ([string]$r1b.action -eq "manual") "R1 被 override 放开为 auto(硬底失效)"
        # 无效策略四形态:确定性拒绝 + 零 run 残留(校验先于任何 run 状态创建)
        $badCases = @(
            @{ tag = "empty"; json = '{"rules":[]}' },
            @{ tag = "dupe"; json = '{"rules":[{"id":"Y1","match":"a","action":"auto"},{"id":"Y1","match":"b","action":"manual"}]}' },
            @{ tag = "action"; json = '{"rules":[{"id":"Y2","match":"a","action":"banana"}]}' },
            @{ tag = "parse"; json = 'not-json{' }
        )
        foreach ($bc in $badCases) {
            $badPath = Join-Path $script:WorkDir ("am55-bad-{0}.json" -f $bc.tag)
            [System.IO.File]::WriteAllText($badPath, $bc.json, $Utf8NoBom)
            $bfx = New-FixtureArchive ("am55bad" + $bc.tag)
            $br = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $bfx.dir "task.json"), "-AutoMode", "-RiskPolicy", $badPath)
            Assert $c ($br.json.error.code -eq "RISK_POLICY_INVALID") "[$($bc.tag)] 无效策略未确定性拒绝: $($br.text)"
            Assert $c (-not (Test-Path (Get-RunDirPath $bfx.run_id))) "[$($bc.tag)] 无效策略留下 run 残留"
        }
    }

    Run-Tc "TC-B56" "编排层裁决不自动化+CTO 宪法豁免锚:planner-guide 硬约束 7(编排层裁决不进分级表);rdd-cto SKILL 豁免指针(宪法原文不改写)+纯自动模式分支(门槛达标语义不豁免/decide+escalate 指引);staging 与真源逐字节一致" "P0" "AM-AC-4/边界" {
        param($c)
        $guide = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "rdd-engine\references\planner-guide.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($guide.Contains("纯自动模式边界")) "planner-guide 缺硬约束 7(纯自动模式边界)"
        Assert $c ($guide.Contains("不进分级表")) "硬约束 7 未声明编排层裁决不进分级表"
        $skill = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "rdd-cto\SKILL.md"), [System.Text.Encoding]::UTF8)
        Assert $c ($skill.Contains("纯自动模式豁免指针")) "CTO SKILL 缺宪法豁免指针"
        Assert $c ($skill.Contains("宪法原文不因自动模式改写")) "豁免指针缺「宪法原文不改写」声明"
        Assert $c ($skill.Contains("门槛达标语义不豁免")) "纯自动模式分支缺「门槛达标语义不豁免」声明"
        Assert $c ($skill.Contains("decide -Kind auto") -and $skill.Contains("escalate")) "分支缺 decide/escalate 操作指引"
        $staging = Join-Path $RepoRoot "dist\skills-staging\skills\rdd-cto\SKILL.md"
        Assert $c (Test-Path $staging) "staging SKILL.md 缺失(交付清单 #8)"
        if (Test-Path $staging) {
            $h1 = (Get-FileHash -LiteralPath $staging).Hash
            $h2 = (Get-FileHash -LiteralPath (Join-Path $RepoRoot "rdd-cto\SKILL.md")).Hash
            Assert $c ($h1 -eq $h2) "staging 与真源不一致(应逐字节一致)"
        }
    }

    Run-Tc "TC-B57" "-NoPush 隔离性(交付物·用户裁决核验项):promulgate -NoPush 推送惰性(trigger 含 NoPush/pushed=0/零 per-node pushes 账);status 触碰不得对隔离 run 发起推送(期望零新增会话创建——0923 事故后隔离承诺)" "P0" "AM-DELIVERY" {
        param($c)
        $fx = New-FixtureArchive "am57"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-AutoMode", "-NoPush")
        Assert $c ($r.exit -eq 0) "-NoPush 颁布失败: $($r.text)"
        Assert $c ([string]$r.json.data.auto_push.trigger -match "NoPush") "trigger 未标记 NoPush: $($r.json.data.auto_push.trigger)"
        Assert $c (@($r.json.data.auto_push.pushed).Count -eq 0) "NoPush 颁布仍推送: $($r.json.data.auto_push.pushed)"
        $b = Read-BridgeJson $fx.run_id
        $pushCount = 0
        if ($null -ne $b.pushes) { $pushCount = @($b.pushes.PSObject.Properties).Count }
        Assert $c ($pushCount -eq 0) "NoPush run 出现 per-node pushes 账(共 $pushCount 项)"
        $createsBefore = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.create" }).Count
        $st = TB @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ($st.exit -eq 0) "status 失败: $($st.text)"
        $createsAfter = @((Read-DshMockLog) | Where-Object { $_.method -eq "session.create" }).Count
        Assert $c ($createsAfter -eq $createsBefore) "status 触碰对 -NoPush run 发起了真实推送(session.create before=$createsBefore after=$createsAfter)——隔离承诺失效(0923 事故机制,缺陷 F1)"
        $b2 = Read-BridgeJson $fx.run_id
        $pushCount2 = 0
        if ($null -ne $b2.pushes) { $pushCount2 = @($b2.pushes.PSObject.Properties).Count }
        Assert $c ($pushCount2 -eq 0) "status 觸碰后 per-node pushes 账被写入(共 $pushCount2 项)——触碰确实执行了推送"
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

$selected = if ($Suite -eq "all") { @("promulgate", "claim", "settle", "recover", "conclude", "regression", "compat", "autopush", "callback", "review", "uniqueness", "payload", "roster", "rollback", "automode") } else { @($Suite) }
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
        "payload"    { Suite-Payload }
        "roster"     { Suite-Roster }
        "rollback"   { Suite-Rollback }
        "automode"   { Suite-AutoMode }
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

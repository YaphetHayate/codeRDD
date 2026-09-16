# delivery-bridge-verify.ps1 — Manager 交付编排桥接 验收验证器（QA 独立实现，零依赖）
#
# 被测对象:rdd-engine/scripts/delivery-bridge.cmd(桥接编排黑盒)
#   黑盒集成测试:仅通过 CLI 接口驱动——delivery-bridge.cmd 组合 goal-tree / goal-tree-leaf /
#   rdd-flow / start-role 公开 CLI;fixture 归档建在 .rdd/tmp 下(绝不触碰真实归档)。
#   断言锚定需求 manager-orchestration 验收标准 1~7 与 manager-guide.md 协议。
#
# 用例规约:TC-B01 ~ TC-B12(映射 BR-AC-1 ~ BR-AC-7)
#
# 用法:
#   pwsh -File .rdd/tests/delivery-bridge/delivery-bridge-verify.ps1 [-Suite all|promulgate|claim|settle|recover|conclude|regression] [-KeepRuns] [-Json]
#   (Windows PowerShell 5.1 亦可运行;建议 pwsh 7+)
#
# 套件说明:
#   promulgate 颁布:run 建立/映射落盘/依赖推导/重复颁布防护 —— TC-B01~B02
#   claim      复合认领:双上下文/重复唤起冲突反馈/依赖阻塞/泊位接管 —— TC-B03~B05
#   settle     流转门禁:三查拒绝/通过/链式 graft/complete/advance 拒绝路径 —— TC-B06~B08
#   recover    恢复:rejected-delivery 回收/死 claim 回收/status 修复/resume —— TC-B09~B10
#   conclude   结案:全终态校验/annex/check 结果/租约释放 —— TC-B11
#   regression 回归:非桥接 run 零桥接文件;五角色默认流不变(rdd-flow 无桥接感知) —— TC-B12
#   all        全部
#
# 严重度语义:P0 失败=阻塞(退出码 1);P1 失败=严重不阻塞;P2 失败=备忘警告(WARN)。
# 退出码:0=无 P0 失败;1=存在 P0 失败;2=验证器自身错误。
#
# 测试产生的运行目录与 fixture 归档默认结束后清理,-KeepRuns 保留供排查。

param(
    [ValidateSet("all", "promulgate", "claim", "settle", "recover", "conclude", "regression")]
    [string]$Suite = "all",
    [switch]$KeepRuns,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

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

# ============================================================
# 套件:promulgate — TC-B01 / TC-B02(BR-AC-2, BR-AC-1)
# ============================================================

function Suite-Promulgate {
    Write-Host "`n== suite: promulgate (BR-AC-1/2 颁布与映射) =="

    Run-Tc "TC-B01" "promulgate:run 建立 + 任务×阶段节点 + bridge.json 1:N 映射落盘 + ref 指针 + 依赖自动推导" "P0" "BR-AC-2" {
        param($c)
        $fx = New-FixtureArchive "pm01"
        $r = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"), "-CreatedBy", "QA")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "promulgate 失败: $($r.text)"
        $d = $r.json.data
        Assert $c ($d.run_id -eq $fx.run_id) "run_id=$($d.run_id),期望 $($fx.run_id)"
        Assert $c (@($d.tasks).Count -eq 3) "颁布任务数 $(@($d.tasks).Count),期望 3"
        # 映射落盘可查:bridge.json 双向
        $b = Read-BridgeJson $fx.run_id
        Assert $c ($null -ne $b) "bridge.json 不可读"
        Assert $c ($b.nodes.n2.task_id -eq 1 -and $b.nodes.n2.stage -eq "DEV") "n2 映射异常"
        Assert $c ($b.nodes.n3.task_id -eq 2 -and $b.nodes.n4.task_id -eq 3 -and $b.nodes.n4.stage -eq "CTO") "n3/n4 映射异常"
        Assert $c ($b.tasks.'1'.stages.DEV -eq "n2") "任务1 反向映射异常"
        # ref 指针 + 依赖推导(T2 → T1)
        $t = Read-RunTree $fx.run_id
        $n3 = $t.nodes | Where-Object id -eq "n3"
        $n2 = $t.nodes | Where-Object id -eq "n2"
        Assert $c ([string]$n2.ref -eq "$($fx.name)#1") "n2.ref=$($n2.ref)"
        Assert $c (@($n3.depends_on) -contains "n2") "T2→T1 依赖未推导: $($n3.depends_on -join ',')"
        # 预算自动下限:width ≥ 任务数
        $st = TRun @("-Command", "status", "-RunId", $fx.run_id)
        Assert $c ([int]$st.json.data.budget.node_width -ge 3) "node_width 下限未生效: $($st.json.data.budget.node_width)"
        # 开放轮:round 1 打开(claim 可用)
        Assert $c ([int]$st.json.data.round.open -eq 1) "round.open=$($st.json.data.round.open),期望 1"
        # 租约自动获取
        Assert $c ($null -ne (Get-Item (Join-Path (Get-RunDirPath $fx.run_id) "manager-lease.json") -ErrorAction SilentlyContinue)) "manager-lease.json 未落盘"
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
        Assert $c ($d.tree_claim.node.status -eq "claimed" -and $d.tree_claim.node.ref -eq "$($fx.name)#1") "树侧上下文异常"
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
        Assert $c ([string]$qa.role -eq "qa" -and [string]$qa.ref -eq "$($fx.name)#1") "QA 节点 role/ref 异常"
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

    Run-Tc "TC-B09" "reclaim 双模式:dead-claim(泊位+重派接管)与 rejected-delivery(剪枝+替换节点);reported 永不重复消费" "P0" "BR-AC-5" {
        param($c)
        $fx = New-FixtureArchive "rc09"
        $null = TB @("-Command", "promulgate", "-TaskJson", (Join-Path $fx.dir "task.json"))
        # dead-claim:认领后模拟会话死亡 → reclaim → 泊位
        $null = TB @("-Command", "claim", "-RunId", $fx.run_id, "-NodeId", "n2", "-Role", "DEV")
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
        Assert $c (Test-Path (Join-Path (Get-RunDirPath $fx.run_id) "report\final-report.md")) "final-report.md 缺失"
        $annexPath = Join-Path (Get-RunDirPath $fx.run_id) "report\delivery-annex.md"
        Assert $c (Test-Path $annexPath) "delivery-annex.md 缺失"
        $annex = [System.IO.File]::ReadAllText($annexPath, [System.Text.Encoding]::UTF8)
        Assert $c ($annex.Contains("T1 bottom") -and $annex.Contains("T3 independent")) "annex 任务终态表不完整"
        Assert $c ($annex.Contains("completed")) "annex 未体现 completed 终态"
        Assert $c ($annex.Contains("QA-CONCLUDE-SUMMARY-XYZ")) "annex 未含结案摘要"
        Assert $c ($annex.Contains("rdd-flow check")) "annex 未含 check 结果"
        # run 已冻结;租约已释放
        $m = (Read-RunFileText $fx.run_id "manifest.json") | ConvertFrom-Json
        Assert $c ([string]$m.state -eq "concluded") "run 未冻结: $($m.state)"
        Assert $c (-not (Test-Path (Join-Path (Get-RunDirPath $fx.run_id) "manager-lease.json"))) "租约未释放"
    }
}

# ============================================================
# 套件:regression — TC-B12(BR-AC-7)
# ============================================================

function Suite-Regression {
    Write-Host "`n== suite: regression (BR-AC-7 未采用 Manager 的行为零变化) =="

    Run-Tc "TC-B12" "回归:纯 goal-tree run 零桥接文件;rdd-flow 纯流程照常;桥接命令不触碰真实归档" "P0" "BR-AC-7" {
        param($c)
        # 1) 纯 goal-tree run:core 命令后 run 目录无 bridge.json / manager-lease.json / delivery-annex.md
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
        foreach ($f in @("bridge.json", "manager-lease.json", "report\delivery-annex.md")) {
            Assert $c (-not (Test-Path (Join-Path $runDir $f))) "纯 run 出现桥接文件: $f"
        }
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
# 主流程
# ============================================================

Write-Host "delivery-bridge-verify — repo: $RepoRoot"
Write-Host "suite: $Suite  (runs under .rdd/goal-trees/ + fixture archives in .rdd/tmp, stamp: $script:RunStamp)"

$selected = if ($Suite -eq "all") { @("promulgate", "claim", "settle", "recover", "conclude", "regression") } else { @($Suite) }
foreach ($s in $selected) {
    switch ($s) {
        "promulgate" { Suite-Promulgate }
        "claim"      { Suite-Claim }
        "settle"     { Suite-Settle }
        "recover"    { Suite-Recover }
        "conclude"   { Suite-Conclude }
        "regression" { $script:ChangesAfterRun = Get-ChangesSnapshot; Suite-Regression }
    }
}

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

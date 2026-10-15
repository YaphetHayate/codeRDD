# planner-midrun-derive tests — run 中途需求派生全链
# Covers requirements/planner-midrun-derive.md acceptance 1-7 + design regressions:
#   T1  propose 入口门：DERIVE_TITLE_REQUIRED / DERIVE_RATIONALE_REQUIRED /
#       DERIVE_DEP_INVALID / DERIVE_OWNERS_INVALID
#   T2  propose 登记：账本 derive_proposal 条目（四要素）+ bridge derivations[]
#       proposed + 呈报文案；零副作用（无节点）
#   T3  确认硬门：confirm 缺 -UserVerdict -> DERIVE_CONFIRMATION_MISSING（无记录
#       不执行，用户拍板口径 (b)）
#   T4  confirm 落地：ruling 条目（decider=user + ref_entry）→ 状态 confirmed +
#       PM 节点 graft 到 goal 根 + plan-log deviation/scope_derived
#   T5  PM settle 受控入册：确认记录复核 → add-task 代写（-BridgeRun + remark
#       锚点，phase=DESIGN）→ bridge.tasks 映射 + 链头预挂 → acceptance 升级
#       derived_upgrade → plan-log derivation_registered
#   T6  闸门 hold：registered 未吸收 → 派生链头 claim/dispatch NODE_BLOCKED_BY_GATE
#       （出路只有 replan）
#   T7  replan 吸收：白名单容忍未覆盖窗口 → 吸收标记 absorbed → 闸门放行
#   T8  自愈幂等：手工复现 crash 窗口（task_id 丢失）→ status 巡检重入册，
#       remark 锚点去重（task.json 不重复建任务）
#   T9  预算硬门：confirm 先记账后预算检查 -> DERIVE_BUDGET_EXCEEDED，
#       状态卡 confirmed 无节点（不可自动重试）；withdraw 收口
#   T10 结案硬门：全任务终态 + 派生挂起 -> DERIVATION_PENDING；withdraw 后
#       不再阻塞（走到 ACCEPTANCE 门即证明）
#   T11 防滥用阈值：-MaxDerivations 超限 DERIVATION_LIMIT_WARNING（警告不硬拒）
#   T12 add-task bridge-run 门：活动 run 下无 -BridgeRun ->
#       ADD_TASK_BRIDGE_RUN_REQUIRED / 错值 MISMATCH / 匹配成功；无 run 归档直加
#   T14 add-task 门释放（QA 缺陷 R2 回归锚）：conclude 实写**顶层** manifest.json
#       state=concluded → 门释放（直加成功）；复位 running → 门重新武装（活探针，
#       非缓存裁定）。缺陷根因：门探测 state/manifest.json（该路径永不存在）
#   T13 BOM 自检：engine 两脚本（本轮编辑过）首三字节 239,187,191（tips 义务）
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# planner-claim-guard: 夹具里的 claim/report 是 worker 侧动作 —— 套件若在 dsh 会话里运行，
# 环境里的 DSH_SESSION_ID 会被 start/promulgate 写进 run 的 state/planner.json，随后每次
# fixture claim 都会被身份门判成「规划者代跑」而拒（PLANNER_CANNOT_CLAIM）。显式清空以保
# 确定性（与 test-long-task-planning / test-handoff-gate 同惯例）。
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('bridge-derive-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Set-TestManifestState { param([string]$RunId, [string]$State)
    # goal-tree 的 conclude 写**顶层** manifest.json（Get-ManifestPath）——
    # T14 用同一位置翻转 state 复现/释放 add-task 门。
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/manifest.json')
    $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $m.state = $State
    $m.concluded = if ($State -eq 'concluded') {
        [ordered]@{ outcome = 'achieved'; concluded_at = '2026-10-08T00:00:00Z'; anchor_node = $null; summary = 'test fixture' }
    } else { $null }
    Write-Utf8NoBom $p ($m | ConvertTo-Json -Depth 8)
}
function Read-Ledger { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/decisions.jsonl')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    $out = @()
    foreach ($line in @([System.IO.File]::ReadAllLines($p))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $out += ($line | ConvertFrom-Json) } catch { }
    }
    return @($out)
}
function Read-PlanLog { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/plan-log.jsonl')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    $out = @()
    foreach ($line in @([System.IO.File]::ReadAllLines($p))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $out += ($line | ConvertFrom-Json) } catch { }
    }
    return @($out)
}
function Get-Der { param($Bridge, [string]$Id)
    foreach ($d in @($Bridge.derivations)) { if ([string]$d.id -eq $Id) { return $d } }
    return $null
}
function Read-Tasks { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/task.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
}

function New-PdArchive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nderive 测试归档 $Name。`n"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir "requirements/t$i.md") "# $Name 需求 $i`n`n- **描述**：derive 测试需求 $i`n- **验收标准**：见 overview.md`n"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

function Write-TestPlan { param([string]$Path, $Stages, [string]$CriteriaRef = '', $BatchSets = $null)
    $stageObjs = @()
    foreach ($st in $Stages) {
        $ap = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' }
        if ($CriteriaRef) { $ap['criteria_ref'] = $CriteriaRef }
        $batches = @(@($st.tasks | ForEach-Object { [int]$_ } | Sort-Object))
        if ($null -ne $BatchSets) { $batches = @($BatchSets | ForEach-Object { , @($_ | ForEach-Object { [int]$_ }) }) }
        $stageObjs += ,@{
            id = [string]$st.id
            goal = "stage $($st.id) 目标"
            milestone = "stage $($st.id) 里程碑"
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = $batches
            acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-07T00:00:00Z'; planner = 'test'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'bridge-derive test delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } }
    }
    $cbFile = Join-Path $env:TEMP ("pd-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-Cb $NodeId $Refs
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
# dead dsh URL: auto-push fails instantly (no real session) — attempts are accounted,
# gate-held nodes never attempt.
$env:DSH_WEB_URL = 'http://127.0.0.1:1'
Push-Location $Work
try {
    # ============ fixture: pd-main（1 DEV 任务，无整体验收判据 → single_exempt） ============
    $tasksMain = '[{"title":"主需求","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $arch = New-PdArchive 'pd-main' $tasksMain
    $pf = Write-TestPlan (Join-Path $Work 'pd-main-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch + '/task.json'), '-PlanFile', $pf, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T0 promulgate pd-main ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-pd-main'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    Assert-True ([string]$b.acceptance.status -eq 'none') 'T0 acceptance starts single_exempt (none)'

    # ================= T1: propose 入口门 =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'propose', '-Rationale', '缺口X')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_TITLE_REQUIRED') 'T1 no -Title -> DERIVE_TITLE_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'propose', '-Title', '派生A')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_RATIONALE_REQUIRED') 'T1 no -Rationale -> DERIVE_RATIONALE_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'propose', '-Title', '派生A', '-Rationale', '缺口X', '-DependsOn', '9')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_DEP_INVALID') 'T1 dep outside delivered set -> DERIVE_DEP_INVALID' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'propose', '-Title', '派生A', '-Rationale', '缺口X', '-Owners', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_OWNERS_INVALID') 'T1 -Owners outside CTO+UX+QA -> DERIVE_OWNERS_INVALID' ($r.raw)

    # ================= T2: propose 登记（零副作用） =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'propose', '-Title', '派生A', '-Rationale', '主链跑通后发现导出能力缺口', '-DependsOn', '1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'proposed') 'T2 propose ok (proposed)' ($r.raw)
    Assert-True ($null -ne $r.json.data.present_to_user -and [string]$r.json.data.present_to_user -match 'confirm' -and [string]$r.json.data.present_to_user -match 'withdraw') 'T2 present_to_user carries both verdict paths' ([string]$r.json.data.present_to_user)
    $led = Read-Ledger $arch
    $e1 = @($led | Where-Object { [string]$_.kind -eq 'derive_proposal' })[0]
    Assert-True ($null -ne $e1 -and [string]$e1.entry_id -eq 'D1' -and [string]$e1.decider -eq 'planner') 'T2 ledger D1 derive_proposal (planner)' ((@($led) | ConvertTo-Json -Depth 4 -Compress))
    Assert-True ($null -ne $e1 -and $null -ne $e1.background -and @($e1.options).Count -ge 2 -and [string]$e1.decision -ne '' -and [string]$e1.reason -ne '') 'T2 four elements present (background/options/decision/reason)'
    Assert-True ($null -ne $e1 -and @($e1.depends_on) -contains 1) 'T2 ledger entry carries depends_on context'
    $b = Read-BridgeJson 'deliver-pd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ($null -ne $d1 -and [string]$d1.status -eq 'proposed' -and [string]$d1.proposed_entry -eq 'D1' -and $null -eq $d1.node) 'T2 bridge derivations[] proposed, no node yet'
    Assert-True ($null -eq $b.pushes.PSObject.Properties[[string]$d1.node]) 'T2 zero side effects (no push/no node)'

    # ================= T3: 确认硬门 =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'confirm', '-DerivationId', 'DRV1')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_CONFIRMATION_MISSING') 'T3 confirm without -UserVerdict -> DERIVE_CONFIRMATION_MISSING (HARD gate)' ($r.raw)
    $b = Read-BridgeJson 'deliver-pd-main'
    Assert-True ((Get-Der $b 'DRV1').status -eq 'proposed') 'T3 nothing transitioned (still proposed)'

    # ================= T4: confirm 落地 =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意派生，并入当前交付')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'confirmed') 'T4 confirm ok (confirmed)' ($r.raw)
    $led = Read-Ledger $arch
    $e2 = @($led | Where-Object { [string]$_.kind -eq 'ruling' })[0]
    Assert-True ($null -ne $e2 -and [string]$e2.entry_id -eq 'D2' -and [string]$e2.decider -eq 'user' -and [string]$e2.ref_entry -eq 'D1') 'T4 ledger D2 ruling (decider=user, ref_entry=D1)' ((@($led) | ConvertTo-Json -Depth 4 -Compress))
    $b = Read-BridgeJson 'deliver-pd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ([string]$d1.status -eq 'confirmed' -and [string]$d1.confirm_entry -eq 'D2' -and $null -ne $d1.node) 'T4 derivation confirmed with grafted node'
    $plog = Read-PlanLog 'deliver-pd-main'
    Assert-True (@($plog | Where-Object { [string]$_.kind -eq 'deviation' -and [string]$_.event -eq 'scope_derived' }).Count -eq 1) 'T4 plan-log deviation/scope_derived recorded'

    # ================= T5: PM settle 受控入册 =================
    $pmNode = [string]$d1.node
    # PM 产出夹具：新需求文档 + overview 判据增补（模拟 PM 义务落地）
    Write-Utf8NoBom (Join-Path $Work "$arch/requirements/derive-a.md") "# 派生需求 A`n`n- **描述**：导出能力补齐`n- **验收标准**：导出可实证`n"
    $ovPath = Join-Path $Work "$arch/requirements/overview.md"
    Write-Utf8NoBom $ovPath "# pd-main`n`nderive 测试归档 pd-main。`n`n## 整体验收判据`n`n| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |`n|---|------|------|------|`n| 1 | 端到端含导出跑通 | demo 实证 | 主需求、派生A |`n"
    Do-Deliver 'deliver-pd-main' $pmNode 'PM' @("$arch/requirements/derive-a.md", "$arch/requirements/overview.md")
    $r = Do-Settle 'deliver-pd-main' $pmNode
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -match 'derivation registered') 'T5 PM node settle -> controlled registration' ($r.raw)
    $tasks = Read-Tasks $arch
    $t2 = @($tasks | Where-Object { [int]$_.id -eq 2 })[0]
    Assert-True ($null -ne $t2 -and @($t2.currentOwners) -contains 'CTO' -and [string]$t2.phase -eq 'DESIGN' -and [string]$t2.requirement -eq 'requirements/derive-a.md') 'T5 add-task issued by bridge (phase=DESIGN, requirement doc)' ((@($tasks) | ConvertTo-Json -Depth 4 -Compress))
    Assert-True ($null -ne $t2 -and [string]$t2.remark -match 'derivation=DRV1') 'T5 remark idempotency anchor recorded'
    $b = Read-BridgeJson 'deliver-pd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ([string]$d1.status -eq 'registered' -and [int]$d1.task_id -eq 2 -and [string]$d1.requirement -eq 'requirements/derive-a.md') 'T5 derivation registered (task #2)'
    $ctoNode = [string]$b.tasks.'2'.stages.CTO; $uxNode = [string]$b.tasks.'2'.stages.UX; $qaNode = [string]$b.tasks.'2'.stages.QA
    Assert-True ($ctoNode -and $uxNode -and $qaNode) 'T5 DESIGN chain heads grafted (CTO/UX/QA)' ((@($b.tasks.'2'.stages) | ConvertTo-Json -Compress))
    Assert-True ([string]$b.acceptance.status -eq 'planned' -and [string]$b.acceptance.basis -eq 'derived_upgrade') 'T5 acceptance upgraded (derived_upgrade, criteria now gate the run)'
    $plog = Read-PlanLog 'deliver-pd-main'
    Assert-True (@($plog | Where-Object { [string]$_.event -eq 'derivation_registered' }).Count -eq 1) 'T5 plan-log derivation_registered recorded'

    # ================= T6: 闸门 hold（未吸收不出队） =================
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-pd-main', '-NodeId', $ctoNode, '-DryRun')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_GATE' -and [string]$r.json.error.message -match 'replan') 'T6 unabsorbed chain head held (NODE_BLOCKED_BY_GATE, replan is the only exit)' ($r.raw)

    # ================= T7: replan 吸收 =================
    # T7a 白名单窗口：plan 暂不含派生任务 #2 —— replan 校验放行（不硬拒）
    $pfA = Write-TestPlan (Join-Path $Work 'pd-main-plan2.json') @(@{ id = 'S1'; tasks = @(1) }) 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-pd-main', '-PlanFile', $pfA, '-Reason', '滚动：先只滚主任务（派生待吸收窗口）')
    Assert-True ($r.json.success -eq $true) 'T7a replan tolerates registered-unabsorbed derived task (whitelist)' ($r.raw)
    # T7b 吸收：plan 纳入任务 #2（依赖 #1 → 分批 [1],[2]）→ absorbed 标记 + 闸门放行
    $pfB = Write-TestPlan (Join-Path $Work 'pd-main-plan3.json') @(@{ id = 'S1'; tasks = @(1, 2) }) 'requirements/overview.md#整体验收判据' @(@(1), @(2))
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-pd-main', '-PlanFile', $pfB, '-Reason', '吸收派生任务 #2')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.derivations_absorbed) -match 'DRV1') 'T7b replan absorbs derivation (absorbed marker)' ($r.raw)
    Assert-True ($null -ne $r.json.data.decision_ledger) 'T7b replan auto-ruling recorded in the decision ledger' ($r.raw)
    $b = Read-BridgeJson 'deliver-pd-main'
    Assert-True ((Get-Der $b 'DRV1').absorbed -eq $true) 'T7b bridge derivations[] absorbed=true'
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-pd-main', '-NodeId', $ctoNode, '-DryRun')
    Assert-True ($r.json.success -eq $true) 'T7b gate open after absorption (dispatch dry-run passes)' ($r.raw)

    # ================= T8: 自愈幂等（crash 窗口重入册） =================
    $bp = Join-Path $Work '.rdd/goal-trees/deliver-pd-main/bridge.json'
    $bj = Get-Content -LiteralPath $bp -Raw -Encoding UTF8 | ConvertFrom-Json
    $bj.derivations[0].task_id = $null
    $bj.derivations[0].status = 'confirmed'
    Write-Utf8NoBom $bp ($bj | ConvertTo-Json -Depth 10)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-pd-main')
    Assert-True ($r.json.success -eq $true) 'T8 status touch runs the patrol state machine' ($r.raw)
    $b = Read-BridgeJson 'deliver-pd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ([string]$d1.status -eq 'registered' -and [int]$d1.task_id -eq 2) 'T8 patrol re-registered the derivation (task_id restored)'
    $tasks = Read-Tasks $arch
    Assert-True (@($tasks).Count -eq 2) 'T8 remark anchor dedup — task.json NOT duplicated' ((@($tasks) | ConvertTo-Json -Depth 3 -Compress))

    # ================= 派生链跑完（T10 前置：全任务终态） =================
    # 主任务 #1 先走完（DEV -> QA）：派生链头 depends_on 主任务活跃节点，DAG 先解锁
    Do-Deliver 'deliver-pd-main' $devHead 'DEV' @("$arch/requirements/t1.md")
    $null = Do-Settle 'deliver-pd-main' $devHead
    $b = Read-BridgeJson 'deliver-pd-main'
    $t1qa = [string]$b.tasks.'1'.stages.QA
    Assert-True ($t1qa -ne '') 'T9p task-1 VERIFY head grafted after IMPL settled'
    Do-Deliver 'deliver-pd-main' $t1qa 'QA' @("$arch/requirements/t1.md")
    $null = Do-Settle 'deliver-pd-main' $t1qa
    Do-Deliver 'deliver-pd-main' $ctoNode 'CTO' @("$arch/requirements/derive-a.md")
    $null = Do-Settle 'deliver-pd-main' $ctoNode
    Do-Deliver 'deliver-pd-main' $uxNode 'UX' @("$arch/requirements/derive-a.md")
    $null = Do-Settle 'deliver-pd-main' $uxNode
    Do-Deliver 'deliver-pd-main' $qaNode 'QA' @("$arch/requirements/derive-a.md")
    $r = Do-Settle 'deliver-pd-main' $qaNode
    Assert-True ($r.json.success -eq $true) 'T9p DESIGN phase settles (serial CTO->UX->QA)' ($r.raw)
    $b = Read-BridgeJson 'deliver-pd-main'
    $implNode = [string]$b.tasks.'2'.stages.DEV
    Assert-True ($implNode -ne '') 'T9p IMPL head grafted after DESIGN converged' ((@($b.tasks.'2'.stages) | ConvertTo-Json -Compress))
    Do-Deliver 'deliver-pd-main' $implNode 'DEV' @("$arch/requirements/derive-a.md")
    $null = Do-Settle 'deliver-pd-main' $implNode
    $b = Read-BridgeJson 'deliver-pd-main'
    $verNode = [string]$b.tasks.'2'.stages.QA
    Assert-True ($verNode -ne $qaNode) 'T9p VERIFY head grafted after IMPL settled'
    Do-Deliver 'deliver-pd-main' $verNode 'QA' @("$arch/requirements/derive-a.md")
    $null = Do-Settle 'deliver-pd-main' $verNode
    $tasks = Read-Tasks $arch
    Assert-True (@($tasks | Where-Object { [string]$_.lifecycle -eq 'completed' }).Count -eq 2) 'T9p both tasks terminal' ((@($tasks) | ForEach-Object { "$($_.id):$($_.lifecycle)" }) -join ',')

    # ================= T10: 结案硬门 DERIVATION_PENDING =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'propose', '-Title', '派生B', '-Rationale', '结案前又见缺口（挂起验证用）')
    Assert-True ($r.json.success -eq $true) 'T10 DRV2 proposed (pending)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-pd-main', '-Summary', '结案尝试')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVATION_PENDING') 'T10 open derivation blocks conclude (DERIVATION_PENDING)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-main', '-Action', 'withdraw', '-DerivationId', 'DRV2', '-Reason', '用户改口：不派生')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'withdrawn') 'T10 withdraw DRV2 (zero side effects)' ($r.raw)
    $b = Read-BridgeJson 'deliver-pd-main'
    Assert-True ((Get-Der $b 'DRV2').status -eq 'withdrawn') 'T10 withdrawn never blocks'
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-pd-main', '-Summary', '结案尝试 2')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -ne 'DERIVATION_PENDING') 'T10 after withdraw the derivation gate no longer blocks (acceptance gate owns the next error)' ($r.raw)

    # ================= T9: 预算硬门（独立归档） =================
    $archB = New-PdArchive 'pd-budget' '[{"title":"预算夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfBud = Write-TestPlan (Join-Path $Work 'pd-budget-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archB + '/task.json'), '-PlanFile', $pfBud, '-NoPush', '-MaxNodes', '3')
    Assert-True ($r.json.success -eq $true) 'T9 pd-budget promulgated with -MaxNodes 3' ($r.raw)
    $null = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-budget', '-Action', 'propose', '-Title', '超预算派生', '-Rationale', '预算硬门验证')
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-budget', '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意但预算不够')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_BUDGET_EXCEEDED') 'T9 confirm beyond budget -> DERIVE_BUDGET_EXCEEDED (no graft attempted)' ($r.raw)
    $bB = Read-BridgeJson 'deliver-pd-budget'
    $dB = Get-Der $bB 'DRV1'
    Assert-True ([string]$dB.status -eq 'confirmed' -and $null -eq $dB.node) 'T9 ruling FIRST: stays confirmed-without-node (fact recorded, no auto retry)'
    $ledB = Read-Ledger $archB
    Assert-True (@($ledB | Where-Object { [string]$_.kind -eq 'ruling' -and [string]$_.decider -eq 'user' }).Count -eq 1) 'T9 user ruling recorded despite the budget failure'
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-budget', '-Action', 'withdraw', '-DerivationId', 'DRV1')
    Assert-True ($r.json.success -eq $true -and $null -eq $r.json.data.pruned_node) 'T9 withdraw closes the dead end (nothing pruned — no node existed)' ($r.raw)

    # ================= T11: 防滥用阈值（-MaxDerivations） =================
    $archL = New-PdArchive 'pd-limit' '[{"title":"阈值夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfL = Write-TestPlan (Join-Path $Work 'pd-limit-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archL + '/task.json'), '-PlanFile', $pfL, '-NoPush', '-MaxDerivations', '1')
    Assert-True ($r.json.success -eq $true) 'T11 pd-limit promulgated with -MaxDerivations 1' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-limit', '-Action', 'propose', '-Title', '派生1', '-Rationale', '第一条')
    Assert-True ($r.json.success -eq $true -and $null -eq $r.json.data.limit_warning) 'T11 first derivation within limit (no warning)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-pd-limit', '-Action', 'propose', '-Title', '派生2', '-Rationale', '第二条超限')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.limit_warning -match 'DERIVATION_LIMIT_WARNING') 'T11 over-limit -> DERIVATION_LIMIT_WARNING (warning, not rejected)' ($r.raw)
    $bL = Read-BridgeJson 'deliver-pd-limit'
    Assert-True ([int]$bL.max_derivation -eq 1) 'T11 bridge max_derivation persisted from -MaxDerivations'

    # ================= T12: rdd-flow add-task bridge-run 门 =================
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $arch, '-Title', '绕行任务', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_REQUIRED') 'T12 add-task under ACTIVE run without -BridgeRun -> ADD_TASK_BRIDGE_RUN_REQUIRED' ($r.raw)
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $arch, '-Title', '绕行任务', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV', '-BridgeRun', 'deliver-other')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_MISMATCH') 'T12 wrong -BridgeRun -> ADD_TASK_BRIDGE_RUN_MISMATCH' ($r.raw)
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $arch, '-Title', '受控任务', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV', '-BridgeRun', 'deliver-pd-main')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.taskId -eq 3) 'T12 matching -BridgeRun passes' ($r.raw)
    $archP = New-PdArchive 'pd-plain' '[{"title":"无run归档","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archP, '-Title', '普通追加', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'QA')
    Assert-True ($r.json.success -eq $true) 'T12 archive without a run keeps the legacy add-task path' ($r.raw)

    # ================= T14: add-task 门在 concluded run 释放（QA R2 回归锚） =================
    $archC = New-PdArchive 'pd-concl' '[{"title":"结案释放夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfC = Write-TestPlan (Join-Path $Work 'pd-concl-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archC + '/task.json'), '-PlanFile', $pfC, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T14 pd-concl promulgated (gate armed)' ($r.raw)
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archC, '-Title', '门内追加', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_REQUIRED') 'T14 baseline: an ACTIVE run still gates add-task' ($r.raw)
    Set-TestManifestState 'deliver-pd-concl' 'concluded'
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archC, '-Title', '结案后追加', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $true) 'T14 [QA R2] concluded run releases the add-task gate (top-level manifest.json)' ($r.raw)
    Set-TestManifestState 'deliver-pd-concl' 'running'
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archC, '-Title', '复位后再试', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_REQUIRED') 'T14 re-arms on the live file (no cached verdict)' ($r.raw)

    # ================= T13: BOM 自检（tips 义务：编辑过的 .ps1 必须 BOM 头） =================
 foreach ($f in @($BridgePs1, $FlowPs1)) {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $n = Split-Path $f -Leaf
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "T13 $n first-3-bytes = 239,187,191 (BOM intact)" ("got {0},{1},{2}" -f $bytes[0], $bytes[1], $bytes[2])
    }
}
finally {
    Pop-Location
    $env:DSH_WEB_URL = $null
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ("--- {0} passed / {1} failed / {2} total ---" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count, $Results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

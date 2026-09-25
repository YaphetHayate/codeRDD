# long-task-planning acceptance tests — 长程规划与滚动追踪（PlanFile + 三载体 + 闸门）
# Covers requirements/long-task-planning.md + design/long-task-planning-cto.md:
#   L1  PLAN_MISSING: promulgate without -PlanFile -> hard fail, zero run residue
#   L2  PLAN_FILE_INVALID: bad stage shape -> deterministic schema error, zero residue
#   L3  PLAN_ORDER_INVALID: dep staged in a later stage than its dependent -> DAG-order error
#   L4  PLAN_BATCH_INVALID: dependency edge inside one parallel batch -> batch-order error
#   L5  budget formula: K=1 -> width 4/nodes 16; K=2 -> 5/17; K=3 -> 7/23 (2/2/3 tasks)
#   L6  stage gate + [集成验收·S<k>] lifecycle: graft on stage terminality -> claim context ->
#       settle -> passed -> gate opens -> task claim unblocks -> conclude + annex「计划完成度」
#   L6b STAGE_ACCEPTANCE_PENDING ladder (distinct from ACCEPTANCE_*): whole-requirement §3 通过
#       readable but a stage acceptance point still open -> settle the node -> achieved
#   L8  replan: MISSING_REASON guard; structured changes[] + revision=2 + plan-log revision event;
#       REPLAN_NOT_ACTIVE after conclude
#   L9  deviation ledger: reclaim (rejected delivery) records a deviation event; replan over a
#       passed stage with changed content -> acceptance_invalidated + status reset (防闸门虚开)
#   L10 (QA 补充) AC-1「要素齐全」逐槽位边界: milestone 缺失 / goal 空 / batches 空 /
#       criteria_items 空 -> PLAN_FILE_INVALID + 零 run 残留
#   L11 (QA 补充) AC-2 跨会话进度/风险记录: risks 载体持久化 + plan-log 与计划段跨进程读回
#       对账 + status 读面 + replan 风险滚动修正（risks_changed / revision 事件）不误伤已过验收
#   L12 (QA 补充) AC-3 集成验收点透出: R1 判据锚 criteria_ref + 可运行切片 slice + 判据子集
#       透传至 stage acceptance claim；判据锚必填/必缺双向边界
#   L13 (F6 回归) 失效回收: 失效波 prune 旧验收点节点（pruned_reason 审计留痕）+ re-graft
#       复用 goal-root 子位——多轮失效波不累积子位，[整体验收] graft 不再 WIDTH_EXCEEDED，
#       末阶段复用 R1 终局链节点同守「≤1 活跃子位」不变量，run 可收口
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('long-task-planning-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Read-PlanLog { param([string]$RunId)
    # plan-log.jsonl (append-only event ledger): parse each line, quarantine-agnostic.
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/plan-log.jsonl')
    $entries = @()
    if (Test-Path -LiteralPath $p) {
        foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                try { $entries += ($line | ConvertFrom-Json) } catch { }
            }
        }
    }
    return $entries
}
function Get-RootActiveChildren { param([string]$RunId, [string]$RootId)
    # active goal-root children (pruned excluded — goal-tree graft counts the
    # same way toward node_width): the F6 slot-accumulation probe.
    @(Read-TreeNodes $RunId | Where-Object { [string]$_.parent -eq $RootId -and [string]$_.status -ne 'pruned' })
}

# overview blocks (acceptance criteria carrier fixtures)
$Script:CriteriaBlock = "## 整体验收判据`n`n| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |`n|---|------|------|------|`n| 1 | 端到端跑通完整场景 | demo 实证 | 需求 1、2 |`n"
$Script:DeclaredBlock = "## 整体验收判据`n`n无整体判据（理由：长程规划测试归档无整体验收场景，显式声明）`n"

# New archive: overview + task docs + init via rdd-flow (phase stored). TasksJson entries may
# carry "dep" (the upstream task id). OverviewExtra = criteria/declaration block.
function New-Archive { param([string]$Name, [string]$TasksJson, [string]$OverviewExtra = '')
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nlong-task-planning 测试归档 $Name。`n`n$OverviewExtra"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        $doc = "requirements/t$i.md"
        $depLine = ''
        if ($line.dep) { $depLine = "- **依赖关系**：依赖需求 $($line.dep)`n" }
        Write-Utf8NoBom (Join-Path $archDir $doc) "# $Name 需求 $i`n`n- **描述**：long-task-planning 测试需求 $i`n- **验收标准**：见 overview.md`n$depLine"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

# Minimal PlanFile writer: stages = the given task sets; each stage's batches =
# topological layers of its tasks under the dep map. -CriteriaRef pins the R1
# anchor (criteria-mode archives require it; criteria-free archives forbid it).
function Write-TestPlan { param([string]$Path, $Stages, $Deps, [string]$CriteriaItem = 'smoke: core flow works', [string]$CriteriaRef = '', $Risks = @())
    $stageObjs = @()
    foreach ($st in $Stages) {
        $pending = @($st.tasks | ForEach-Object { [int]$_ })
        $batches = @()
        while ($pending.Count -gt 0) {
            $batch = @($pending | Where-Object {
                $t = [int]$_
                @(@($Deps[$t]) | Where-Object { $pending -contains [int]$_ }).Count -eq 0
            })
            if ($batch.Count -eq 0) { throw "Write-TestPlan: cyclic deps in stage $($st.id)" }
            $batches += ,@($batch | Sort-Object)
            $pending = @($pending | Where-Object { $batch -notcontains [int]$_ })
        }
        $ap = @{
            criteria_items = @($(if ($st.criteria_item) { [string]$st.criteria_item } else { $CriteriaItem }))
            slice = $(if ($st.slice) { [string]$st.slice } else { 'runnable single-command slice' })
        }
        if ($CriteriaRef) { $ap['criteria_ref'] = $CriteriaRef }
        $stageObjs += ,@{
            id = [string]$st.id
            goal = $(if ($st.goal) { [string]$st.goal } else { "stage $($st.id) 目标" })
            milestone = $(if ($st.milestone) { [string]$st.milestone } else { "stage $($st.id) 里程碑" })
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = $batches
            acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-09-25T00:00:00Z'; planner = 'test'; stages = $stageObjs; risks = @($Risks) }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

function New-Cb { param([string]$NodeId, [string]$Ref, [bool]$Qualified = $true)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'long-task-planning test delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
    }
    if ($Qualified) { $cb['extras'] = @{ verification = 'smoke ok' } }
    $cbFile = Join-Path $env:TEMP ("ltp-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}

# claim -> report (qualified by default). Throws on hard failure.
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref, [bool]$Qualified = $true)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-Cb $NodeId $Ref $Qualified
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return $r
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

# a fake QA worker's three-section acceptance report (§3 verdict optional)
function Write-AcceptanceReport { param([string]$ArchiveRel, [string]$Verdict = '')
    $dir = Join-Path $Work "$ArchiveRel/tests"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $body = "# 集成/联调与整体验收`n`n## §1 集成/联调记录`n`n- 引用回调账本条目（不复制）`n`n## §2 判据逐条核验表`n`n| 判据 | 核验 | 结果 |`n|------|------|------|`n| 1 | demo 实证 | 通过 |`n"
    if ($Verdict) { $body += "`n## §3 总结论`n`n总结论：$Verdict`n" }
    Write-Utf8NoBom (Join-Path $dir 'integration-acceptance.md') $body
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # ================= L1: PLAN_MISSING + zero residue =================
    $arch1 = New-Archive 'lp-l1' '[{"title":"L1a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L1b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_MISSING') 'L1 promulgate without -PlanFile -> PLAN_MISSING' ($r.raw)
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-lp-l1'))) 'L1 zero run residue (nothing created)'

    # ================= L2: PLAN_FILE_INVALID + zero residue =================
    $badPlan = Join-Path $Work 'lp-l2-bad.json'
    Write-Utf8NoBom $badPlan '{"planned_at":"2026-09-25T00:00:00Z","planner":"test","stages":[{"id":"S1","goal":"g","milestone":"m","task_ids":[1,2],"batches":[[1,2]],"acceptance_point":{"criteria_items":["smoke"]}}]}'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $badPlan, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_FILE_INVALID') 'L2 acceptance_point without slice -> PLAN_FILE_INVALID' ($r.raw)
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-lp-l1'))) 'L2 zero run residue'

    # ================= L3: PLAN_ORDER_INVALID (dep behind its dependent) =================
    $arch3 = New-Archive 'lp-l3' '[{"title":"L3 上游","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L3 下游","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[],"dep":1}]' $Script:DeclaredBlock
    $pf3 = Write-TestPlan (Join-Path $Work 'lp-l3-plan.json') @(@{ id = 'S1'; tasks = @(2) }, @{ id = 'S2'; tasks = @(1) }) @{ 2 = @(1) }
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-PlanFile', $pf3, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_ORDER_INVALID') 'L3 dep staged behind its dependent -> PLAN_ORDER_INVALID' ($r.raw)
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-lp-l3'))) 'L3 zero run residue'

    # ================= L4: PLAN_BATCH_INVALID (dep inside one batch) =================
    # hand-written shape: one batch deliberately contains both dep ends
    $pf4 = Join-Path $Work 'lp-l4-plan.json'
    Write-Utf8NoBom $pf4 '{"planned_at":"2026-09-25T00:00:00Z","planner":"test","stages":[{"id":"S1","goal":"stage S1 目标","milestone":"stage S1 里程碑","task_ids":[1,2],"batches":[[1,2]],"acceptance_point":{"criteria_items":["smoke: core flow works"],"slice":"runnable single-command slice"}}],"risks":[]}'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-PlanFile', $pf4, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_BATCH_INVALID') 'L4 dependency edge inside one batch -> PLAN_BATCH_INVALID' ($r.raw)

    # ================= L5: budget formula by stage count =================
    $arch5a = New-Archive 'lp-l5a' '[{"title":"L5a-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L5a-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf5a = Write-TestPlan (Join-Path $Work 'lp-l5a-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5a + '/task.json'), '-PlanFile', $pf5a, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 4 -and [int]$r.json.data.budget.max_nodes -eq 16) 'L5 K=1: width 4 / max_nodes 16 (zero stage increment)' ($r.raw)

    $arch5b = New-Archive 'lp-l5b' '[{"title":"L5b-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L5b-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf5b = Write-TestPlan (Join-Path $Work 'lp-l5b-plan.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5b + '/task.json'), '-PlanFile', $pf5b, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 5 -and [int]$r.json.data.budget.max_nodes -eq 17) 'L5 K=2: width 5 / max_nodes 17 (stage +1 each)' ($r.raw)
    Assert-True ([int]$r.json.data.plan.revision -eq 1 -and @($r.json.data.plan.stages).Count -eq 2) 'L5 promulgate echoes plan section (revision 1, 2 stages)' ($r.raw)

    $arch5c = New-Archive 'lp-l5c' '[{"title":"L5c-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L5c-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]},{"title":"L5c-3","requirement":"requirements/t3.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf5c = Write-TestPlan (Join-Path $Work 'lp-l5c-plan.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) }, @{ id = 'S3'; tasks = @(3) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5c + '/task.json'), '-PlanFile', $pf5c, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 7 -and [int]$r.json.data.budget.max_nodes -eq 23) 'L5 K=3: width 7 / max_nodes 23 (stage +2 each)' ($r.raw)

    # ================= L6: stage gate + [集成验收·S1] lifecycle =================
    $arch6 = New-Archive 'lp-l6' '[{"title":"L6a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L6b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf6 = Write-TestPlan (Join-Path $Work 'lp-l6-plan.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6 + '/task.json'), '-PlanFile', $pf6, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'L6 promulgate ok (2-stage plan)' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l6'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'planned') 'L6 acceptance point starts planned'
    $h6a = [string]$b.tasks.'1'.stages.QA; $h6b = [string]$b.tasks.'2'.stages.QA
    # gate pre-check: S2's task is claimable ONLY after S1's acceptance point passes
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-lp-l6', '-NodeId', $h6b, '-Role', 'QA')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_GATE' -and $r.json.error.message -match 'S1') 'L6 task behind closed stage gate -> NODE_BLOCKED_BY_GATE (S1)' ($r.raw)
    Do-Deliver 'deliver-lp-l6' $h6a 'QA' "$arch6/requirements/t1.md"
    $r = Do-Settle 'deliver-lp-l6' $h6a
    Assert-True ($r.json.success -eq $true) 'L6 stage-1 task settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l6'
    $sa1 = [string]$b.plan.stages[0].acceptance_point.node
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'grafted' -and $sa1 -ne '') 'L6 [集成验收·S1] grafted on stage terminality' ("node=$sa1")
    $nSa1 = Find-TreeNode 'deliver-lp-l6' $sa1
    Assert-True ($null -ne $nSa1 -and [string]$nSa1.role -eq 'qa' -and [string]$nSa1.type -ne 'goal') 'L6 stage acceptance node is a QA tree-level work node' ("role=$($nSa1.role) type=$($nSa1.type)")
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-lp-l6', '-NodeId', $sa1, '-Role', 'QA')
    Assert-True ($r.json.success -eq $true -and $r.json.data.tree_level -eq $true -and [string]$r.json.data.acceptance.kind -eq 'stage_acceptance' -and [string]$r.json.data.acceptance.stage_id -eq 'S1' -and @($r.json.data.acceptance.criteria_items).Count -ge 1) 'L6 stage acceptance claim carries stage_acceptance context' ($r.raw)
    $cbSa = New-Cb $sa1 "$arch6/requirements/t1.md"
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-lp-l6', '-Worker', 'QA', '-CallbackFile', $cbSa)
    Assert-True ($r.json.success -eq $true) 'L6 stage acceptance report ok' ($r.raw)
    $r = Do-Settle 'deliver-lp-l6' $sa1
    Assert-True ($r.json.success -eq $true) 'L6 stage acceptance settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l6'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed') 'L6 acceptance point passed after settle (gate opens)'
    $log6 = Read-PlanLog 'deliver-lp-l6'
    Assert-True (@($log6 | Where-Object { [string]$_.kind -eq 'progress' -and [string]$_.event -eq 'acceptance_passed' -and [string]$_.stage -eq 'S1' }).Count -ge 1) 'L6 plan-log records acceptance_passed for S1'
    # gate now open: the S2 task claim succeeds (already claimed above), so the
    # delivery proceeds report -> settle without re-claiming.
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-lp-l6', '-NodeId', $h6b, '-Role', 'QA')
    Assert-True ($r.json.success -eq $true) 'L6 gate open -> S2 task claimable' ($r.raw)
    $cb6b = New-Cb $h6b "$arch6/requirements/t2.md"
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-lp-l6', '-Worker', 'QA', '-CallbackFile', $cb6b)
    $r = Do-Settle 'deliver-lp-l6' $h6b
    Assert-True ($r.json.success -eq $true) 'L6 S2 task settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l6'
    Assert-True ([string]$b.plan.stages[1].acceptance_point.status -eq 'passed') 'L6 final stage auto-passes without a whole-requirement chain'
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-lp-l6')
    Assert-True ($r.json.success -eq $true -and $null -ne $r.json.data.plan -and @($r.json.data.plan.stages).Count -eq 2) 'L6 status exposes the plan view' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-lp-l6', '-Summary', 'L6 all green')
    Assert-True ($r.json.success -eq $true -and $r.json.data.outcome -eq 'achieved') 'L6 conclude achieved with every acceptance point passed' ($r.raw)
    $annex6 = Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-lp-l6/report/delivery-annex.md') -Raw -Encoding UTF8
    Assert-True ($annex6 -match '计划完成度' -and $annex6 -match 'S1' -and $annex6 -match 'passed') 'L6 annex carries「计划完成度」with stage acceptance verdicts'
    # L8 side: REPLAN_NOT_ACTIVE after conclude (no active plan to revise)
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l6', '-PlanFile', $pf6, '-Reason', 'L8 after conclude')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'REPLAN_NOT_ACTIVE') 'L8 replan after conclude -> REPLAN_NOT_ACTIVE' ($r.raw)

    # ================= L6b: STAGE_ACCEPTANCE_PENDING distinct ladder =================
    $arch6b = New-Archive 'lp-l6b' '[{"title":"L6b-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L6b-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf6b = Write-TestPlan (Join-Path $Work 'lp-l6b-plan.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6b + '/task.json'), '-PlanFile', $pf6b, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'L6b promulgate ok (criteria mode, 2 stages)' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l6b'
    $g1 = [string]$b.tasks.'1'.stages.QA; $g2 = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-lp-l6b' $g1 'QA' "$arch6b/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l6b' $g1
    $b = Read-BridgeJson 'deliver-lp-l6b'
    $sa6b = [string]$b.plan.stages[0].acceptance_point.node
    Assert-True ($sa6b -ne '') 'L6b [集成验收·S1] grafted'
    Do-Deliver 'deliver-lp-l6b' $sa6b 'QA' "$arch6b/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l6b' $sa6b
    $b = Read-BridgeJson 'deliver-lp-l6b'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed') 'L6b S1 acceptance passed'
    Do-Deliver 'deliver-lp-l6b' $g2 'QA' "$arch6b/requirements/t2.md"
    $null = Do-Settle 'deliver-lp-l6b' $g2
    $b = Read-BridgeJson 'deliver-lp-l6b'
    $i6b = [string]$b.acceptance.integrate_node
    Assert-True ($i6b -ne '') 'L6b integrate grafted after ALL mapped settles'
    Write-AcceptanceReport $arch6b '通过'
    Do-Deliver 'deliver-lp-l6b' $i6b 'DEV' "$arch6b/tests/integration-acceptance.md"
    $null = Do-Settle 'deliver-lp-l6b' $i6b
    $b = Read-BridgeJson 'deliver-lp-l6b'
    $a6b = [string]$b.acceptance.accept_node
    Assert-True ($a6b -ne '') 'L6b accept node grafted'
    # deliver the accept node but leave it UNSETTLED: the whole-requirement §3 is 通过
    # while the final stage's acceptance point is still open.
    Do-Deliver 'deliver-lp-l6b' $a6b 'QA' "$arch6b/tests/integration-acceptance.md"
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-lp-l6b', '-Summary', 'L6b pending stage acceptance')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'STAGE_ACCEPTANCE_PENDING') 'L6b open stage acceptance point -> STAGE_ACCEPTANCE_PENDING (distinct ladder)' ($r.raw)
    $r = Do-Settle 'deliver-lp-l6b' $a6b
    Assert-True ($r.json.success -eq $true) 'L6b accept node settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l6b'
    Assert-True ([string]$b.plan.stages[1].acceptance_point.status -eq 'passed') 'L6b final acceptance binds to the R1 accept node and passes'
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-lp-l6b', '-Summary', 'L6b passed after settle')
    Assert-True ($r.json.success -eq $true -and $r.json.data.outcome -eq 'achieved') 'L6b conclude achieved after settling the acceptance node' ($r.raw)
    $annex6b = Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-lp-l6b/report/delivery-annex.md') -Raw -Encoding UTF8
    Assert-True ($annex6b -match '计划完成度' -and $annex6b -match '整体验收结论') 'L6b annex carries「计划完成度」and「整体验收结论」'

    # ================= L8: replan (rolling correction entry) =================
    $arch8 = New-Archive 'lp-l8' '[{"title":"L8a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L8b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf8 = Write-TestPlan (Join-Path $Work 'lp-l8-plan.json') @(@{ id = 'S1'; tasks = @(1); goal = '原定阶段一目标' }, @{ id = 'S2'; tasks = @(2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch8 + '/task.json'), '-PlanFile', $pf8, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'L8 promulgate ok' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l8', '-PlanFile', $pf8)
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'MISSING_REASON') 'L8 replan without -Reason -> MISSING_REASON' ($r.raw)
    $pf8b = Write-TestPlan (Join-Path $Work 'lp-l8-revised.json') @(@{ id = 'S1'; tasks = @(1); goal = '修订后阶段一目标' }, @{ id = 'S2'; tasks = @(2) }) @{}
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l8', '-PlanFile', $pf8b, '-Reason', 'L8 阶段目标修订（deviation 驱动）')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.revision -eq 2 -and @($r.json.data.changes).Count -ge 1) 'L8 replan applies revision 2 with structured changes[]' ($r.raw)
    Assert-True (@($r.json.data.changes | Where-Object { [string]$_.op -eq 'stage_changed' }).Count -ge 1) 'L8 changes[] carries the stage_changed row'
    $log8 = Read-PlanLog 'deliver-lp-l8'
    $revRows = @($log8 | Where-Object { [string]$_.kind -eq 'revision' -and [string]$_.event -eq 'replan' })
    Assert-True ($revRows.Count -eq 1 -and [int]$revRows[0].detail.revision -eq 2) 'L8 plan-log records ONE revision event (append-only)'
    $b = Read-BridgeJson 'deliver-lp-l8'
    Assert-True ([int]$b.plan.revision -eq 2) 'L8 bridge plan section bumped to revision 2'

    # ================= L9: deviation ledger + acceptance invalidation wave =================
    # 9a: rejected delivery -> reclaim (rejected-delivery mode) records a deviation event
    $arch9 = New-Archive 'lp-l9' '[{"title":"L9a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L9b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf9 = Write-TestPlan (Join-Path $Work 'lp-l9-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch9 + '/task.json'), '-PlanFile', $pf9, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'L9 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l9'
    $h9 = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-lp-l9' $h9 'QA' "$arch9/requirements/t1.md" $false     # unqualified: no extras.verification
    $r = Do-Settle 'deliver-lp-l9' $h9
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED') 'L9 unqualified delivery rejected at settle' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-lp-l9', '-NodeId', $h9)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'L9 reclaim recovers the rejected delivery' ($r.raw)
    $log9 = Read-PlanLog 'deliver-lp-l9'
    Assert-True (@($log9 | Where-Object { [string]$_.kind -eq 'deviation' -and [string]$_.event -eq 'reclaim' }).Count -ge 1) 'L9 plan-log records the reclaim deviation event'
    # 9b: replan over a stage whose acceptance already passed -> invalidation wave (防闸门虚开)
    $arch9b = New-Archive 'lp-l9b' '[{"title":"L9b-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L9b-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf9b = Write-TestPlan (Join-Path $Work 'lp-l9b-plan.json') @(@{ id = 'S1'; tasks = @(1); slice = 'v1 slice' }, @{ id = 'S2'; tasks = @(2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch9b + '/task.json'), '-PlanFile', $pf9b, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'L9b promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l9b'
    $k1 = [string]$b.tasks.'1'.stages.QA; $k2 = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-lp-l9b' $k1 'QA' "$arch9b/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l9b' $k1
    $b = Read-BridgeJson 'deliver-lp-l9b'
    $sa9b = [string]$b.plan.stages[0].acceptance_point.node
    Do-Deliver 'deliver-lp-l9b' $sa9b 'QA' "$arch9b/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l9b' $sa9b
    $b = Read-BridgeJson 'deliver-lp-l9b'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed') 'L9b S1 acceptance passed before replan'
    $pf9b2 = Write-TestPlan (Join-Path $Work 'lp-l9b-revised.json') @(@{ id = 'S1'; tasks = @(1); slice = 'v2 slice（实证切片改版）' }, @{ id = 'S2'; tasks = @(2) }) @{}
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l9b', '-PlanFile', $pf9b2, '-Reason', 'L9b 验收内容改版')
    Assert-True ($r.json.success -eq $true) 'L9b replan over a passed stage ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l9b'
    $newAp = $b.plan.stages[0].acceptance_point
    Assert-True ([string]$newAp.status -ne 'passed' -and ([string]$newAp.node -eq '' -or [string]$newAp.node -ne [string]$sa9b)) 'L9b changed stage acceptance invalidated (not passed; old node unbound or replaced by a fresh re-verification node)' ("status=$($newAp.status) node=$($newAp.node) old=$sa9b")
    $log9b = Read-PlanLog 'deliver-lp-l9b'
    Assert-True (@($log9b | Where-Object { [string]$_.kind -eq 'deviation' -and [string]$_.event -eq 'acceptance_invalidated' -and [string]$_.detail.trigger -eq 'replan' }).Count -ge 1) 'L9b plan-log records acceptance_invalidated (trigger=replan)'
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-lp-l9b', '-NodeId', $k2, '-Role', 'QA')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_GATE') 'L9b gate re-closes after the invalidation wave' ($r.raw)

    # ================= L10 (QA 补充) : AC-1「要素齐全」逐槽位边界 =================
    # 每个缺失槽位独立成案：确定性 PLAN_FILE_INVALID + 全部拒后零 run 残留。
    $arch10 = New-Archive 'lp-l10' '[{"title":"L10-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $tj10 = ($arch10 + '/task.json')
    $l10Cases = @(
        @{ name = 'L10 stage.milestone 缺失 -> PLAN_FILE_INVALID'; msg = 'missing required field: milestone';
           json = '{"planned_at":"2026-09-25T00:00:00Z","planner":"test","stages":[{"id":"S1","goal":"stage S1 目标","task_ids":[1],"batches":[[1]],"acceptance_point":{"criteria_items":["smoke: core flow works"],"slice":"runnable single-command slice"}}],"risks":[]}' },
        @{ name = 'L10 stage.goal 空串 -> PLAN_FILE_INVALID'; msg = 'goal must be a non-empty string';
           json = '{"planned_at":"2026-09-25T00:00:00Z","planner":"test","stages":[{"id":"S1","goal":"","milestone":"stage S1 里程碑","task_ids":[1],"batches":[[1]],"acceptance_point":{"criteria_items":["smoke: core flow works"],"slice":"runnable single-command slice"}}],"risks":[]}' },
        @{ name = 'L10 stage.batches 空 -> PLAN_FILE_INVALID'; msg = 'batches must be a non-empty array';
           json = '{"planned_at":"2026-09-25T00:00:00Z","planner":"test","stages":[{"id":"S1","goal":"stage S1 目标","milestone":"stage S1 里程碑","task_ids":[1],"batches":[],"acceptance_point":{"criteria_items":["smoke: core flow works"],"slice":"runnable single-command slice"}}],"risks":[]}' },
        @{ name = 'L10 acceptance_point.criteria_items 空 -> PLAN_FILE_INVALID'; msg = 'criteria_items must be non-empty';
           json = '{"planned_at":"2026-09-25T00:00:00Z","planner":"test","stages":[{"id":"S1","goal":"stage S1 目标","milestone":"stage S1 里程碑","task_ids":[1],"batches":[[1]],"acceptance_point":{"criteria_items":[],"slice":"runnable single-command slice"}}],"risks":[]}' }
    )
    foreach ($c10 in $l10Cases) {
        $p10 = Join-Path $Work 'lp-l10-plan.json'
        Write-Utf8NoBom $p10 $c10.json
        $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', $tj10, '-PlanFile', $p10, '-NoPush')
        Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_FILE_INVALID' -and $r.json.error.message -match $c10.msg) $c10.name ($r.raw)
    }
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-lp-l10'))) 'L10 zero run residue across every element gap'

    # ================= L11 (QA 补充) : AC-2 跨会话进度/风险记录与滚动修正 =================
    # 每条 CLI 调用都是独立 powershell 进程 —— 磁盘上的 plan-log.jsonl / bridge.json
    # plan 段即跨会话载体；本组显式做跨进程读回对账。
    $arch11 = New-Archive 'lp-l11' '[{"title":"L11-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L11-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf11 = Write-TestPlan (Join-Path $Work 'lp-l11-plan.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' '' @( @{ risk = '阶段二依赖外部接口交付'; level = 'P1'; note = '延期风险' }, @{ risk = '验收切片需真实环境'; level = 'P3'; note = '' } )
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch11 + '/task.json'), '-PlanFile', $pf11, '-NoPush')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.plan.risks).Count -eq 2) 'L11 promulgate carries the risk ledger (2 entries)' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l11'
    Assert-True (@($b.plan.risks).Count -eq 2 -and [string]$b.plan.risks[0].level -eq 'P1') 'L11 risks persisted into the plan section (跨会话载体)'
    $j11 = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-lp-l11' $j11 'QA' "$arch11/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l11' $j11
    $b = Read-BridgeJson 'deliver-lp-l11'
    $sa11 = [string]$b.plan.stages[0].acceptance_point.node
    Do-Deliver 'deliver-lp-l11' $sa11 'QA' "$arch11/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l11' $sa11
    $b = Read-BridgeJson 'deliver-lp-l11'
    $log11 = Read-PlanLog 'deliver-lp-l11'
    $stageIds11 = @($b.plan.stages | ForEach-Object { [string]$_.id })
    Assert-True (@($log11).Count -ge 2 -and @($log11 | Where-Object { $null -ne $_.stage -and $stageIds11 -notcontains [string]$_.stage }).Count -eq 0) 'L11 plan-log events all reconcile to planned stages'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed' -and @($log11 | Where-Object { [string]$_.event -eq 'acceptance_passed' }).Count -ge 1) 'L11 progress record stays aligned with the plan on cross-session readback'
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-lp-l11')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.plan.risks).Count -eq 2 -and [string]$r.json.data.plan.plan_log -match 'plan-log.jsonl') 'L11 status exposes risks + plan-log pointer (滚动追踪读面)' ($r.raw)
    $pf11b = Write-TestPlan (Join-Path $Work 'lp-l11-revised.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' '' @( @{ risk = '阶段二依赖外部接口交付（已升级为阻塞）'; level = 'P1'; note = '范围变化' } )
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l11', '-PlanFile', $pf11b, '-Reason', 'L11 风险清单滚动修正')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.changes | Where-Object { [string]$_.op -eq 'risks_changed' }).Count -eq 1) 'L11 replan emits risks_changed in changes[]' ($r.raw)
    $log11b = Read-PlanLog 'deliver-lp-l11'
    $rev11 = @($log11b | Where-Object { [string]$_.kind -eq 'revision' -and [string]$_.event -eq 'replan' })
    Assert-True ($rev11.Count -eq 1 -and [int]$rev11[0].detail.revision -eq 2) 'L11 plan-log revision event persists the rolling correction (修正记录)'
    $b = Read-BridgeJson 'deliver-lp-l11'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed') 'L11 risk-only revision keeps a passed acceptance point (不误伤已过验收)'

    # ================= L12 (QA 补充) : AC-3 判据锚（R1 整体验收判据）与可运行切片透出 =================
    $arch12 = New-Archive 'lp-l12' '[{"title":"L12-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L12-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf12 = Write-TestPlan (Join-Path $Work 'lp-l12-plan.json') @(@{ id = 'S1'; tasks = @(1); slice = 'demo 单命令整体切片（S1）' }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch12 + '/task.json'), '-PlanFile', $pf12, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'L12 promulgate ok (criteria mode, R1 anchor pinned)' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l12'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.criteria_ref -eq 'requirements/overview.md#整体验收判据') 'L12 plan section pins the R1 criteria anchor per stage'
    $k12 = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-lp-l12' $k12 'QA' "$arch12/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l12' $k12
    $b = Read-BridgeJson 'deliver-lp-l12'
    $sa12 = [string]$b.plan.stages[0].acceptance_point.node
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-lp-l12', '-NodeId', $sa12, '-Role', 'QA')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.acceptance.criteria_ref -eq 'requirements/overview.md#整体验收判据' -and [string]$r.json.data.acceptance.slice -eq 'demo 单命令整体切片（S1）' -and (@($r.json.data.acceptance.criteria_items) -contains 'smoke: core flow works')) 'L12 stage acceptance claim carries R1 anchor + runnable slice + criteria subset' ($r.raw)
    $arch12b = New-Archive 'lp-l12b' '[{"title":"L12b-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf12b = Write-TestPlan (Join-Path $Work 'lp-l12b-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{} 'smoke: core flow works' ''
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch12b + '/task.json'), '-PlanFile', $pf12b, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_FILE_INVALID' -and $r.json.error.message -match 'criteria_ref is required') 'L12 整体验收判据存在时缺 criteria_ref -> PLAN_FILE_INVALID' ($r.raw)
    $arch12c = New-Archive 'lp-l12c' '[{"title":"L12c-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf12c = Write-TestPlan (Join-Path $Work 'lp-l12c-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch12c + '/task.json'), '-PlanFile', $pf12c, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PLAN_FILE_INVALID' -and $r.json.error.message -match 'must be omitted') 'L12 无整体验收判据时带 criteria_ref -> PLAN_FILE_INVALID' ($r.raw)
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-lp-l12b')) -and -not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-lp-l12c'))) 'L12 判据锚不匹配零 run 残留'

    # ================= L13 (F6 回归) : 失效波重 graft 不累积 goal-root 子位 =================
    # 失效回收语义：失效波 prune 旧验收点节点（审计留痕）→ re-graft 复用子位。宽度预算
    # heads+2+(K-1)=5 无需计入失效波上界：多轮回退后 [整体验收] graft 仍能落位、run 可收口。
    $arch13 = New-Archive 'lp-l13' '[{"title":"L13-1","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"L13-2","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf13 = Write-TestPlan (Join-Path $Work 'lp-l13-plan.json') @(@{ id = 'S1'; tasks = @(1); slice = 'v1 slice' }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch13 + '/task.json'), '-PlanFile', $pf13, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 5) 'L13 promulgate ok（criteria 模式，宽度预算 5）' ($r.raw)
    $b = Read-BridgeJson 'deliver-lp-l13'
    $root13 = [string]$b.goal_root
    $u1 = [string]$b.tasks.'1'.stages.QA; $u2 = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-lp-l13' $u1 'QA' "$arch13/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l13' $u1
    $b = Read-BridgeJson 'deliver-lp-l13'
    $wa1 = [string]$b.plan.stages[0].acceptance_point.node
    Assert-True ($wa1 -ne '') 'L13 [集成验收·S1] v1 grafted'
    $baseChildren = @(Get-RootActiveChildren 'deliver-lp-l13' $root13).Count
    Assert-True ($baseChildren -eq 3) 'L13 基线活跃子位 = 3（2 链头 + 1 验收点）' ("count=$baseChildren")
    Do-Deliver 'deliver-lp-l13' $wa1 'QA' "$arch13/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l13' $wa1
    $b = Read-BridgeJson 'deliver-lp-l13'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed') 'L13 S1 acceptance passed before wave'
    # ---- wave #1: replan over changed stage content -> invalidate + reclaim ----
    $pf13b = Write-TestPlan (Join-Path $Work 'lp-l13-rev2.json') @(@{ id = 'S1'; tasks = @(1); slice = 'v2 slice（实证切片改版）' }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l13', '-PlanFile', $pf13b, '-Reason', 'L13 验收切片改版（失效波 #1）')
    Assert-True ($r.json.success -eq $true) 'L13 replan wave #1 ok' ($r.raw)
    $nWa1 = Find-TreeNode 'deliver-lp-l13' $wa1
    Assert-True ($null -ne $nWa1 -and [string]$nWa1.status -eq 'pruned' -and [string]$nWa1.pruned_reason -match 'acceptance invalidated: S1') 'L13 失效波回收旧验收点节点（pruned_reason 审计留痕）' ("status=$($nWa1.status) reason=$($nWa1.pruned_reason)")
    $log13 = Read-PlanLog 'deliver-lp-l13'
    Assert-True (@($log13 | Where-Object { [string]$_.kind -eq 'deviation' -and [string]$_.event -eq 'acceptance_invalidated' -and [string]$_.node -eq $wa1 }).Count -ge 1) 'L13 plan-log acceptance_invalidated 指向被回收节点'
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-lp-l13')
    $b = Read-BridgeJson 'deliver-lp-l13'
    $wa2 = [string]$b.plan.stages[0].acceptance_point.node
    Assert-True ($wa2 -ne '' -and $wa2 -ne $wa1) 'L13 re-graft 产生新验收点节点' ("v1=$wa1 v2=$wa2")
    $after1 = @(Get-RootActiveChildren 'deliver-lp-l13' $root13).Count
    Assert-True ($after1 -eq $baseChildren) 'L13 失效波重 graft 不累积子位（活跃 goal-root 子位数不变）' ("base=$baseChildren after=$after1")
    Do-Deliver 'deliver-lp-l13' $wa2 'QA' "$arch13/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l13' $wa2
    $b = Read-BridgeJson 'deliver-lp-l13'
    Assert-True ([string]$b.plan.stages[0].acceptance_point.status -eq 'passed') 'L13 wave #1 后再验收 passed（闸门重开）'
    # ---- wave #2: 多轮回退无上界——第二轮失效波同样只占 1 子位 ----
    $pf13c = Write-TestPlan (Join-Path $Work 'lp-l13-rev3.json') @(@{ id = 'S1'; tasks = @(1); slice = 'v3 slice（切片再改版）' }, @{ id = 'S2'; tasks = @(2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l13', '-PlanFile', $pf13c, '-Reason', 'L13 验收切片再改版（失效波 #2）')
    Assert-True ($r.json.success -eq $true) 'L13 replan wave #2 ok' ($r.raw)
    $nWa2 = Find-TreeNode 'deliver-lp-l13' $wa2
    Assert-True ($null -ne $nWa2 -and [string]$nWa2.status -eq 'pruned') 'L13 第二轮失效波同样回收旧节点' ("status=$($nWa2.status)")
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-lp-l13')
    $b = Read-BridgeJson 'deliver-lp-l13'
    $wa3 = [string]$b.plan.stages[0].acceptance_point.node
    $after2 = @(Get-RootActiveChildren 'deliver-lp-l13' $root13).Count
    Assert-True ($wa3 -ne '' -and $wa3 -ne $wa2 -and $after2 -eq $baseChildren) 'L13 多轮回退后仍不累积子位（第三节点复用子位）' ("v2=$wa2 v3=$wa3 base=$baseChildren after=$after2")
    Do-Deliver 'deliver-lp-l13' $wa3 'QA' "$arch13/requirements/t1.md"
    $null = Do-Settle 'deliver-lp-l13' $wa3
    # ---- R1 终局链：修复前 [整体验收] graft 恒 WIDTH_EXCEEDED 的断点 ----
    Do-Deliver 'deliver-lp-l13' $u2 'QA' "$arch13/requirements/t2.md"
    $null = Do-Settle 'deliver-lp-l13' $u2
    $b = Read-BridgeJson 'deliver-lp-l13'
    $i13 = [string]$b.acceptance.integrate_node
    Assert-True ($i13 -ne '') 'L13 [集成/联调] grafted after all tasks terminal'
    Write-AcceptanceReport $arch13 '通过'
    Do-Deliver 'deliver-lp-l13' $i13 'DEV' "$arch13/tests/integration-acceptance.md"
    $null = Do-Settle 'deliver-lp-l13' $i13
    $b = Read-BridgeJson 'deliver-lp-l13'
    $a13 = [string]$b.acceptance.accept_node
    Assert-True ($a13 -ne '') 'L13 [整体验收] graft 落位（F6 断点：修复前恒 WIDTH_EXCEEDED）' ("accept=$a13")
    Do-Deliver 'deliver-lp-l13' $a13 'QA' "$arch13/tests/integration-acceptance.md"
    $null = Do-Settle 'deliver-lp-l13' $a13
    $b = Read-BridgeJson 'deliver-lp-l13'
    Assert-True ([string]$b.plan.stages[1].acceptance_point.status -eq 'passed' -and [string]$b.plan.stages[1].acceptance_point.node -eq $a13) 'L13 末阶段验收点绑定 R1 终局链节点（复用）' ("node=$($b.plan.stages[1].acceptance_point.node)")
    # ---- 末阶段复用 R1 终局链节点：失效波同样不累积、不误伤共享节点 ----
    $pf13d = Write-TestPlan (Join-Path $Work 'lp-l13-rev4.json') @(@{ id = 'S1'; tasks = @(1); slice = 'v3 slice（切片再改版）' }, @{ id = 'S2'; tasks = @(2); slice = 'demo 全场景走查清单（末阶段切片改版）' }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-lp-l13', '-PlanFile', $pf13d, '-Reason', 'L13 末阶段验收切片修订（失效波 #3，波及终局链绑定）')
    Assert-True ($r.json.success -eq $true) 'L13 replan wave #3 ok（末阶段验收点失效）' ($r.raw)
    $nA13 = Find-TreeNode 'deliver-lp-l13' $a13
    Assert-True ($null -ne $nA13 -and [string]$nA13.status -ne 'pruned' -and [string]$nA13.pruned_reason -eq '') 'L13 末阶段失效波不 prune R1 终局链节点（复用而非回收）' ("status=$($nA13.status) reason=$($nA13.pruned_reason)")
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-lp-l13')
    $b = Read-BridgeJson 'deliver-lp-l13'
    $after3 = @(Get-RootActiveChildren 'deliver-lp-l13' $root13).Count
    Assert-True ([string]$b.plan.stages[1].acceptance_point.status -eq 'passed' -and [string]$b.plan.stages[1].acceptance_point.node -eq $a13) 'L13 末阶段失效波后再绑定复用同一 R1 节点（不占新子位）' ("node=$($b.plan.stages[1].acceptance_point.node) status=$($b.plan.stages[1].acceptance_point.status)")
    Assert-True ($after3 -eq $baseChildren + 2) 'L13 末阶段失效波后子位仍不累积（5 活跃 = 预算）' ("base=$baseChildren after=$after3")
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-lp-l13', '-Summary', 'L13 失效回收后 run 可收口')
    Assert-True ($r.json.success -eq $true -and $r.json.data.outcome -eq 'achieved') 'L13 conclude achieved（失效波后 run 可收口）' ($r.raw)
}
finally {
    Pop-Location
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("== long-task-planning: {0} passed, {1} failed ==" -f (@($Results).Count - $failed.Count), $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

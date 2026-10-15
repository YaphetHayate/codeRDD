# auditor-design-stage-review acceptance tests — 设计汇聚审查（DESIGN→IMPL 阶段边界门）
# Covers requirements/auditor-design-stage-review.md + design/auditor-design-stage-review-cto.md:
#   DR1 budget: +K (K=stage count) when AUDITOR deployed; design_review slots land in plan
#   DR2 graft trigger + gate: all-tasks-past-DESIGN + on-disk docs -> [设计审查·S1] graft;
#       DEV claim/dispatch -> NODE_BLOCKED_BY_DESIGN_REVIEW; AUDITOR claim context (docs +
#       design_maps); valid pass DesignReviewFile -> settle derives pass -> DEV unblocks
#   DR3 exempt: no design docs on disk / all-DEV stage (no in-run design work) -> exempt,
#       no review node, no gate
#   DR4 settle contract gate: DesignReviewFile violations (doc coverage miss +
#       verdict/findings inconsistency) -> SETTLE_EVIDENCE_REJECTED with design_review problems
#   DR5 fail wave: blocking finding -> verdict fail -> wave (DEV pruned, CTO rebuilt with
#       redo context, task back to CTO@DESIGN, design_review reset planned, review node
#       reclaimed, ledger blocking + summary entries)
#   DR6 invalidation wave (replan over a passed design review with changed content) ->
#       design_review_invalidated + reset planned + old review node pruned
#   DR7 legacy run: bridge.json without design_review sections (pre-feature shape) -> no gate
#   NR1-NR8 new chain (review_mode, auditor-subagent-review): the dual-form counterpart —
#       promulgate -ReviewMode subagent|session -> pure-contract chain: trigger -> ready
#       (no review node; plan-log design_review_ready + status/next hints), the ONLY
#       adjudication entry is design-review -Action submit (contract core shared with the
#       node settle gate), fail fires the existing fail wave with zero node reclaim,
#       reviewer enum auditor-delegated|auditor + production 留痕. The legacy DR1-DR7
#       cases above promulgate WITHOUT -ReviewMode (缺键) and stay byte-identical
#       (缺键 legacy 行为断言保留 — DR 用例双形态).
#   NR9 integration face (derive × review): a replan-added stage is where a mid-run
#       derivation lands — in the review_mode chain it gets a fresh planned slot
#       (mandatory review, no off value) and runs the SAME contract chain; a 缺键 run
#       stays slot-less (byte-identical).
# Self-isolation note: every promulgate runs -NoPush (bridge isolation discipline — no real
# session creation); the design-review state machines (graft/verdict/wave) run even under
# no_push by design (they are state, not pushes). The promulgate DEGRADE path (AUDITOR not
# deployed -> no slots + warning) is NOT testable in-repo: the engine-side dual probe
# (engine-sibling rdd-auditor/SKILL.md) always hits inside this checkout — degrade assertions
# are conditional (deployed ? +K : legacy) mirroring test-long-task-planning L5.
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('bridge-design-review-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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

$Script:DeclaredBlock = "## 整体验收判据`n`n无整体判据（理由：设计汇聚审查测试归档无整体验收场景，显式声明）`n"

function New-Archive { param([string]$Name, [string]$TasksJson, [string]$OverviewExtra = '')
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nauditor-design-stage-review 测试归档 $Name。`n`n$OverviewExtra"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        $doc = "requirements/t$i.md"
        Write-Utf8NoBom (Join-Path $archDir $doc) "# $Name 需求 $i`n`n- **描述**：设计汇聚审查测试需求 $i`n- **验收标准**：见 overview.md`n"
        # on-disk design artifacts named by designDocs (the review object face)
        foreach ($d in @($line.designDocs)) {
            if ($d -and $d.path) {
                $dAbs = Join-Path $archDir ([string]$d.path)
                $dDir = Split-Path $dAbs -Parent
                if (-not (Test-Path $dDir)) { New-Item -ItemType Directory -Path $dDir -Force | Out-Null }
                Write-Utf8NoBom $dAbs "# 设计文档 $i`n`n变更地图：`n`n- ``src/mod-a.py``  [新增] 模块 A`n`n[新增] 1 | [修改] 0 | [删除] 0`n"
            }
        }
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

function Write-TestPlan { param([string]$Path, $Stages)
    $stageObjs = @()
    foreach ($st in $Stages) {
        $stageObjs += ,@{
            id = [string]$st.id
            goal = $(if ($st.goal) { [string]$st.goal } else { "stage $($st.id) 目标" })
            milestone = $(if ($st.milestone) { [string]$st.milestone } else { "stage $($st.id) 里程碑" })
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = @(@($st.tasks | ForEach-Object { [int]$_ } | Sort-Object))
            acceptance_point = @{ criteria_items = @('smoke: core flow works'); slice = $(if ($st.slice) { [string]$st.slice } else { 'runnable single-command slice' }) }
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-06T00:00:00Z'; planner = 'test'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

function New-Cb { param([string]$NodeId, [string[]]$Refs, [bool]$Qualified = $true)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'design-review test delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
    }
    if ($Qualified) { $cb['extras'] = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } } }
    $cbFile = Join-Path $env:TEMP ("dr-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}

function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-Cb $NodeId $Refs
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return $r
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

# DesignReviewFile writer (archive-relative, on disk): pass/fail over the given docs.
# Reviewer/WithProduction/ProductionMode (auditor-subagent-review 双形态): new-chain
# files sign the reviewer enum (auditor-delegated / auditor) + carry the production
# audit section; the legacy defaults stay reviewer='auditor' with no section.
function Write-ReviewFile { param([string]$ArchiveRel, [string]$StageId, [string[]]$DocRels, [string]$Verdict, [string]$BlockingDim = 'change_map', [bool]$SkipCoverage = $false, [string]$Reviewer = 'auditor', [bool]$WithProduction = $false, [string]$ProductionMode = 'subagent', [string[]]$CrossDocs = @())
    $archAbs = Join-Path $Work $ArchiveRel
    $docs = @()
    foreach ($rel in @($DocRels)) {
        $findings = @()
        if ($Verdict -eq 'fail') {
            $findings += @{ severity = 'blocking'; dimension = $BlockingDim; item = "blocking finding on $rel"; suggestion = '修正后重产' }
        }
        $findings += @{ severity = 'advisory'; dimension = 'completeness'; item = "advisory finding on $rel"; suggestion = '补强说明' }
        $docs += @{ doc = $rel; verdict = $Verdict; findings = $findings }
    }
    $crossFindings = @()
    if (@($CrossDocs).Count -gt 0) {
        $crossFindings += @{ severity = 'blocking'; dimension = 'cross_design'; item = 'cross-doc combo hole (test)'; suggestion = '两文档对齐后重产'; involved_docs = @($CrossDocs) }
    }
    $file = [ordered]@{
        reviewed_at = '2026-10-06T09:00:00Z'; reviewer = $Reviewer; stage = $StageId
        docs = $docs
        summary = @{ cross_design = $crossFindings }
    }
    if ($WithProduction) { $file['production'] = @{ mode = $ProductionMode; template = 'rdd-engine/references/review-input-template.md' } }
    if ($SkipCoverage -and @($docs).Count -gt 1) { $file['docs'] = @($docs | Select-Object -First 1) }
    $rel = "review/design-review-$StageId.json"
    $abs = Join-Path $archAbs ($rel -replace '/', '\')
    $dir = Split-Path $abs -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# 设计汇聚审查 — $ArchiveRel·$StageId`n`n镜像。`n"
    return $rel
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # ================= DR1: budget +K + design_review slots =================
    $arch1 = New-Archive 'dr-l1' '[{"title":"DR1a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"DR1b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf1 = Write-TestPlan (Join-Path $Work 'dr-l1-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1, '-NoPush')
    $deployed = $false
    if ($r.json.success) { $deployed = (@($r.json.data.plan.stages | Where-Object { $null -ne $_.design_review }).Count -gt 0) }
    $expW = if ($deployed) { 5 } else { 4 }; $expN = if ($deployed) { 17 } else { 16 }
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq $expW -and [int]$r.json.data.budget.max_nodes -eq $expN) "DR1 K=1 budget width $expW / nodes $expN (+K when auditor deployed)" ($r.raw)
    if ($deployed) {
        Assert-True ([string]$r.json.data.design_review.deployed -eq $true -and @($r.json.data.plan.stages | Where-Object { @('planned', 'exempt') -contains [string]$_.design_review.status }).Count -eq 1) 'DR1 design_review slots land (planned/exempt per trigger) (deployed)' ($r.raw)
    }
    else {
        Assert-True ([string]$r.json.data.design_review.deployed -eq $false) 'DR1 degrade echo (not deployed)' ($r.raw)
    }

    # ================= DR2: graft trigger + gate + pass path =================
    $arch2 = New-Archive 'dr-l2' '[{"title":"DR2","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pf2 = Write-TestPlan (Join-Path $Work 'dr-l2-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-PlanFile', $pf2, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'DR2 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l2'
    $ctoNode = [string]$b.tasks.'1'.stages.CTO
    Assert-True (-not [string]::IsNullOrWhiteSpace($ctoNode)) 'DR2 CTO head node exists' ($b | ConvertTo-Json -Depth 6)
    # CTO delivery: settle advances the task past DESIGN -> trigger grafts [设计审查·S1]
    Do-Deliver 'deliver-dr-l2' $ctoNode 'CTO' @('.rdd/changes/archive/dr-l2/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l2' $ctoNode
    Assert-True ($r.json.success -eq $true) 'DR2 CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l2'
    $drSec = $b.plan.stages[0].design_review
    Assert-True ($null -ne $drSec -and [string]$drSec.status -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace([string]$drSec.node)) 'DR2 design_review grafted after all tasks past DESIGN' ($b | ConvertTo-Json -Depth 6)
    $revNode = [string]$drSec.node
    $devNode = [string]$b.tasks.'1'.stages.DEV
    Assert-True (-not [string]::IsNullOrWhiteSpace($devNode)) 'DR2 DEV node grafted by CTO settle' ($b | ConvertTo-Json -Depth 6)
    $revT = Find-TreeNode 'deliver-dr-l2' $revNode
    Assert-True ($null -ne $revT -and [string]$revT.title -eq '[设计审查·S1]' -and [string]$revT.role -eq 'auditor') 'DR2 review node tree shape (title/role, goal-root child)' ($revT | ConvertTo-Json)
    # gate: DEV claim + dispatch hard-refused while the review is open
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l2', '-NodeId', $devNode, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'DR2 DEV claim -> NODE_BLOCKED_BY_DESIGN_REVIEW' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-dr-l2', '-NodeId', $devNode)
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'DR2 dispatch -> NODE_BLOCKED_BY_DESIGN_REVIEW' ($r.raw)
    # AUDITOR claim context: docs list + kind
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l2', '-NodeId', $revNode, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.tree_level -eq $true -and [string]$r.json.data.acceptance.kind -eq 'design_review' -and @($r.json.data.acceptance.docs) -contains 'design/d1.md') 'DR2 AUDITOR claim carries design_review context (docs face)' ($r.raw)
    # valid pass DesignReviewFile -> settle derives pass -> DEV unblocks
    Write-ReviewFile '.rdd/changes/archive/dr-l2' 'S1' @('design/d1.md') 'pass' | Out-Null
    $cb = New-Cb $revNode @('.rdd/changes/archive/dr-l2/review/design-review-S1.json', '.rdd/changes/archive/dr-l2/review/design-review-S1.md')
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-dr-l2', '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'DR2 review report ok' ($r.raw)
    $r = Do-Settle 'deliver-dr-l2' $revNode
    Assert-True ($r.json.success -eq $true) 'DR2 review settle (contract pass) ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l2'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'passed' -and [string]$b.plan.stages[0].design_review.verdict -eq 'pass') 'DR2 engine-derived verdict pass recorded' ($b | ConvertTo-Json -Depth 6)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l2', '-NodeId', $devNode, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'DR2 DEV claim unblocked after pass' ($r.raw)
    $ev = @(Read-PlanLog 'deliver-dr-l2' | Where-Object { [string]$_.event -eq 'design_review_node_settled' })
    Assert-True ($ev.Count -ge 1) 'DR2 plan-log design_review_node_settled event' ((Read-PlanLog 'deliver-dr-l2') | ConvertTo-Json -Depth 4)

    # ================= DR3: exempt paths (no docs / no in-run design work) =================
    $arch3a = New-Archive 'dr-l3a' '[{"title":"DR3a","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $pf3a = Write-TestPlan (Join-Path $Work 'dr-l3a-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3a + '/task.json'), '-PlanFile', $pf3a, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'DR3a promulgate ok (CTO task, no design docs)' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l3a'
    $cto3 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-dr-l3a' $cto3 'CTO' @('.rdd/changes/archive/dr-l3a/requirements/t1.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l3a' $cto3
    Assert-True ($r.json.success -eq $true) 'DR3a CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l3a'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'exempt') 'DR3a no-docs stage -> exempt fast lane' ($b | ConvertTo-Json -Depth 6)
    $dev3 = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l3a', '-NodeId', $dev3, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'DR3a DEV claim not gated (exempt)' ($r.raw)

    $arch3b = New-Archive 'dr-l3b' '[{"title":"DR3b","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pf3b = Write-TestPlan (Join-Path $Work 'dr-l3b-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3b + '/task.json'), '-PlanFile', $pf3b, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'DR3b promulgate ok (all-DEV stage with design doc)' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l3b'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'exempt') 'DR3b no in-run DESIGN work -> exempt fast lane' ($b | ConvertTo-Json -Depth 6)
    $dev3b = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l3b', '-NodeId', $dev3b, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'DR3b DEV claim not gated (exempt)' ($r.raw)

    # ================= DR4: settle contract gate violations =================
    $arch4 = New-Archive 'dr-l4' '[{"title":"DR4a","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]},{"title":"DR4b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]}]' $Script:DeclaredBlock
    $pf4 = Write-TestPlan (Join-Path $Work 'dr-l4-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $conv4 = Join-Path $Work 'dr-l4-conventions.md'
    Write-Utf8NoBom $conv4 "# 架构约定（测试）`n`n- 分层一致；命名沿用现有风格。`n"
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch4 + '/task.json'), '-PlanFile', $pf4, '-ConventionsFile', $conv4, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'DR4 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l4'
    $c1 = [string]$b.tasks.'1'.stages.CTO; $c2 = [string]$b.tasks.'2'.stages.CTO
    Do-Deliver 'deliver-dr-l4' $c1 'CTO' @('.rdd/changes/archive/dr-l4/design/d1.md') | Out-Null
    Do-Settle 'deliver-dr-l4' $c1 | Out-Null
    Do-Deliver 'deliver-dr-l4' $c2 'CTO' @('.rdd/changes/archive/dr-l4/design/d2.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l4' $c2
    Assert-True ($r.json.success -eq $true) 'DR4 both CTO settle ok (graft on last)' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l4'
    $rev4 = [string]$b.plan.stages[0].design_review.node
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace($rev4)) 'DR4 review grafted after BOTH tasks past DESIGN' ($b | ConvertTo-Json -Depth 6)
    # violation 1: doc coverage miss (one of two docs omitted)
    Write-ReviewFile '.rdd/changes/archive/dr-l4' 'S1' @('design/d1.md', 'design/d2.md') 'fail' $true | Out-Null
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l4', '-NodeId', $rev4, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'DR4 AUDITOR claim ok' ($r.raw)
    $cb = New-Cb $rev4 @('.rdd/changes/archive/dr-l4/review/design-review-S1.json')
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-dr-l4', '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'DR4 review report ok' ($r.raw)
    $r = Do-Settle 'deliver-dr-l4' $rev4
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and ($r.raw -match 'design_review check')) 'DR4 coverage-miss DesignReviewFile -> SETTLE_EVIDENCE_REJECTED (design_review check)' ($r.raw)
    # violation 2: verdict/findings inconsistency (pass verdict WITH a blocking finding)
    $badAbs = Join-Path $Work '.rdd/changes/archive/dr-l4/review/design-review-S1.json'
    $bad = @{
        reviewed_at = '2026-10-06T09:00:00Z'; reviewer = 'auditor'; stage = 'S1'
        docs = @(
            @{ doc = 'design/d1.md'; verdict = 'pass'; findings = @(@{ severity = 'blocking'; dimension = 'alignment'; item = 'x'; suggestion = 'y' }) },
            @{ doc = 'design/d2.md'; verdict = 'pass'; findings = @() }
        )
        summary = @{ cross_design = @() }
    }
    Write-Utf8NoBom $badAbs ($bad | ConvertTo-Json -Depth 6)
    $r = Do-Settle 'deliver-dr-l4' $rev4
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and ($r.raw -match 'verdict=pass but carries')) 'DR4 pass-with-blocking inconsistency -> SETTLE_EVIDENCE_REJECTED' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l4'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'grafted') 'DR4 design_review stays grafted (rejected settle does not derive)' ($b | ConvertTo-Json -Depth 6)

    # ================= DR5: fail wave (rollback-primitive semantics) =================
    $arch5 = New-Archive 'dr-l5' '[{"title":"DR5","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pf5 = Write-TestPlan (Join-Path $Work 'dr-l5-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5 + '/task.json'), '-PlanFile', $pf5, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'DR5 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l5'
    $cto5 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-dr-l5' $cto5 'CTO' @('.rdd/changes/archive/dr-l5/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l5' $cto5
    Assert-True ($r.json.success -eq $true) 'DR5 CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l5'
    $rev5 = [string]$b.plan.stages[0].design_review.node
    $dev5 = [string]$b.tasks.'1'.stages.DEV
    Write-ReviewFile '.rdd/changes/archive/dr-l5' 'S1' @('design/d1.md') 'fail' | Out-Null
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l5', '-NodeId', $rev5, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'DR5 AUDITOR claim ok' ($r.raw)
    $cb = New-Cb $rev5 @('.rdd/changes/archive/dr-l5/review/design-review-S1.json', '.rdd/changes/archive/dr-l5/review/design-review-S1.md')
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-dr-l5', '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'DR5 review report ok' ($r.raw)
    $r = Do-Settle 'deliver-dr-l5' $rev5
    Assert-True ($r.json.success -eq $true) 'DR5 fail review settle ok (contract-valid fail)' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l5'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'planned') 'DR5 fail wave completes -> design_review reset planned (re-review on redo convergence)' ($b | ConvertTo-Json -Depth 6)
    # wave effects: DEV pruned, CTO rebuilt (new node, redo context), review node reclaimed
    $dev5T = Find-TreeNode 'deliver-dr-l5' $dev5
    $rev5T = Find-TreeNode 'deliver-dr-l5' $rev5
    Assert-True ($null -ne $dev5T -and [string]$dev5T.status -eq 'pruned') 'DR5 pending DEV node pruned by the wave' ($dev5T | ConvertTo-Json)
    Assert-True ($null -ne $rev5T -and [string]$rev5T.status -eq 'pruned') 'DR5 old review node reclaimed by the wave (slot reuse)' ($rev5T | ConvertTo-Json)
    $ctoNew = [string]$b.tasks.'1'.stages.CTO
    Assert-True (-not [string]::IsNullOrWhiteSpace($ctoNew) -and $ctoNew -ne $cto5) 'DR5 CTO group rebuilt (sibling graft, new node)' ($b | ConvertTo-Json -Depth 6)
    $ctoNewT = Find-TreeNode 'deliver-dr-l5' $ctoNew
    Assert-True ($null -ne $ctoNewT -and ([string]$ctoNewT.status -eq 'pending' -or [string]$ctoNewT.status -eq 'claimed') -and ($ctoNewT.task -match '设计审查否决')) 'DR5 rebuilt CTO node carries blocking redo context' ($ctoNewT | ConvertTo-Json)
    # flow side: task back to CTO @ DESIGN
    $r = Invoke-Flow @('-Command', 'show', '-Archive', '.rdd/changes/archive/dr-l5')
    $t5 = @($r.json.data.tasks | Where-Object { [int]$_.id -eq 1 })[0]
    Assert-True ($null -ne $t5 -and @($t5.currentOwners) -contains 'CTO' -and [string]$t5.phase -eq 'DESIGN') 'DR5 task route back to CTO @ DESIGN' ($r.raw)
    # ledger: blocking + summary entries in .rdd/review-ledger.jsonl (repo root, this temp repo)
    $ledgerPath = Join-Path $Work '.rdd/review-ledger.jsonl'
    Assert-True (Test-Path $ledgerPath) 'DR5 review ledger appended' ($ledgerPath)
    $ledgerLines = @()
    if (Test-Path $ledgerPath) { foreach ($ln in (Get-Content $ledgerPath -Encoding UTF8)) { if (-not [string]::IsNullOrWhiteSpace($ln)) { try { $ledgerLines += ($ln | ConvertFrom-Json) } catch { } } } }
    Assert-True (@($ledgerLines | Where-Object { [string]$_.kind -eq 'blocking' -and [string]$_.gap_type -eq 'change_map' }).Count -ge 1) 'DR5 blocking ledger entry (gap_type=dimension)' (($ledgerLines | ConvertTo-Json -Depth 4))
    Assert-True (@($ledgerLines | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.verdict -eq 'fail' }).Count -ge 1) 'DR5 design_review summary ledger entry' (($ledgerLines | ConvertTo-Json -Depth 4))

    # ================= DR6: invalidation wave (replan over passed review, content changed) =================
    $b = Read-BridgeJson 'deliver-dr-l2'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'passed') 'DR6 precondition: dr-l2 review passed' ($b | ConvertTo-Json -Depth 6)
    $revNodeD2 = [string]$b.plan.stages[0].design_review.node
    $pf2b = Write-TestPlan (Join-Path $Work 'dr-l2-plan2.json') @(@{ id = 'S1'; tasks = @(1); slice = 'revised runnable slice (content changed)' })
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-dr-l2', '-PlanFile', $pf2b, '-Reason', 'design drift after review pass')
    Assert-True ($r.json.success -eq $true) 'DR6 replan ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l2'
    $dr6 = $b.plan.stages[0].design_review
    Assert-True (@('planned', 'grafted') -contains [string]$dr6.status -and $null -eq $dr6.verdict -and ([string]$dr6.node -ne $revNodeD2)) 'DR6 changed-content replan resets design_review (fresh slot, re-review re-grafts 覆盖重产重审)' ($b | ConvertTo-Json -Depth 6)
    $revT2 = Find-TreeNode 'deliver-dr-l2' $revNodeD2
    Assert-True ($null -ne $revT2 -and [string]$revT2.status -eq 'pruned') 'DR6 stale review node pruned (anti-false-open gate)' ($revT2 | ConvertTo-Json)
    $ev = @(Read-PlanLog 'deliver-dr-l2' | Where-Object { [string]$_.event -eq 'design_review_invalidated' })
    Assert-True ($ev.Count -ge 1) 'DR6 design_review_invalidated event' ((Read-PlanLog 'deliver-dr-l2') | ConvertTo-Json -Depth 4)

    # ================= DR7: legacy run (no design_review sections) -> no gate =================
    $arch7 = New-Archive 'dr-l7' '[{"title":"DR7","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pf7 = Write-TestPlan (Join-Path $Work 'dr-l7-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-PlanFile', $pf7, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'DR7 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-dr-l7'
    $cto7 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-dr-l7' $cto7 'CTO' @('.rdd/changes/archive/dr-l7/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l7' $cto7
    Assert-True ($r.json.success -eq $true) 'DR7 CTO settle ok' ($r.raw)
    # strip design_review sections from bridge.json (pre-feature shape)
    $bp = Join-Path $Work '.rdd/goal-trees/deliver-dr-l7/bridge.json'
    $bj = Get-Content -LiteralPath $bp -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($st in @($bj.plan.stages)) { $st.PSObject.Properties.Remove('design_review') }
    $bj | ConvertTo-Json -Depth 20 | Out-File -FilePath $bp -Encoding utf8
    $b = Read-BridgeJson 'deliver-dr-l7'
    Assert-True ($null -eq $b.plan.stages[0].design_review) 'DR7 section stripped (legacy shape)' ($b | ConvertTo-Json -Depth 6)
    $dev7 = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-dr-l7', '-NodeId', $dev7, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'DR7 legacy run DEV claim not gated (no section = no gate)' ($r.raw)

    # ================= NR1: 新链 review_mode 落桥 + 预算零 +K + exempt =================
    $archN1 = New-Archive 'nr-l1' '[{"title":"NR1a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"NR1b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pfN1 = Write-TestPlan (Join-Path $Work 'nr-l1-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archN1 + '/task.json'), '-PlanFile', $pfN1, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'NR1 promulgate ok (-ReviewMode subagent)' ($r.raw)
    Assert-True ([int]$r.json.data.budget.node_width -eq 4 -and [int]$r.json.data.budget.max_nodes -eq 16) 'NR1 budget no +K in the new chain (no review nodes to reserve)' ($r.raw)
    Assert-True ([string]$r.json.data.design_review.mode -eq 'subagent') 'NR1 echo design_review.mode (部署判据=配置项)' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l1'
    Assert-True ([string]$b.review_mode -eq 'subagent') 'NR1 review_mode persisted in bridge.json' ($b | ConvertTo-Json -Depth 6)
    Assert-True (@($b.plan.stages | Where-Object { $null -ne $_.design_review }).Count -eq 1) 'NR1 design_review slots land unconditionally (无部署判据/零降级)' ($b | ConvertTo-Json -Depth 6)
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'exempt') 'NR1 no-docs stage -> exempt fast lane (shared semantics)' ($b | ConvertTo-Json -Depth 6)

    # ================= NR2: trigger -> ready（无节点）+ 闸门 =================
    $archN2 = New-Archive 'nr-l2' '[{"title":"NR2","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pfN2 = Write-TestPlan (Join-Path $Work 'nr-l2-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archN2 + '/task.json'), '-PlanFile', $pfN2, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'NR2 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l2'
    $ctoN2 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-nr-l2' $ctoN2 'CTO' @('.rdd/changes/archive/nr-l2/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-nr-l2' $ctoN2
    Assert-True ($r.json.success -eq $true) 'NR2 CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l2'
    $drN2 = $b.plan.stages[0].design_review
    Assert-True ([string]$drN2.status -eq 'ready' -and $null -eq $drN2.node) 'NR2 trigger -> ready (no review node in the new chain)' ($b | ConvertTo-Json -Depth 6)
    Assert-True (@(Read-TreeNodes 'deliver-nr-l2' | Where-Object { [string]$_.title -like '*设计审查*' }).Count -eq 0) 'NR2 zero [设计审查] nodes grafted (pure contract)' ((Read-TreeNodes 'deliver-nr-l2') | ConvertTo-Json)
    $evN2 = @(Read-PlanLog 'deliver-nr-l2' | Where-Object { [string]$_.event -eq 'design_review_ready' })
    Assert-True ($evN2.Count -ge 1) 'NR2 plan-log design_review_ready progress event' ((Read-PlanLog 'deliver-nr-l2') | ConvertTo-Json -Depth 4)
    $devN2 = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-nr-l2', '-NodeId', $devN2, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'NR2 DEV claim gated until submit lands' ($r.raw)

    # ================= NR3: -Action status 只读派审面（机械输入清单） =================
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', 'deliver-nr-l2')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.chain -eq 'contract (submit)' -and [string]$r.json.data.review_mode -eq 'subagent') 'NR3 status view chain/mode label' ($r.raw)
    $stN3 = @($r.json.data.stages | Where-Object { [string]$_.stage -eq 'S1' })[0]
    Assert-True ($null -ne $stN3 -and [string]$stN3.status -eq 'ready' -and @($stN3.docs) -contains 'design/d1.md') 'NR3 status view per-stage state + docs 清单' ($r.raw)
    Assert-True ([string]$stN3.template -eq 'rdd-engine/references/review-input-template.md' -and [string]$stN3.report -eq 'review/design-review-S1.json' -and [string]$stN3.production.mode -eq 'subagent') 'NR3 status view 模板/落点/production 常量（零转述填充面）' ($r.raw)
    Assert-True (@($r.json.data.reviewers) -contains 'auditor-delegated' -and @($r.json.data.reviewers) -contains 'auditor') 'NR3 status view reviewer 枚举单源' ($r.raw)

    # ================= NR4: submit 契约门（同源核心）违规 → 修复重报 =================
    Write-ReviewFile -ArchiveRel '.rdd/changes/archive/nr-l2' -StageId 'S1' -DocRels @('design/d1.md') -Verdict 'pass' -Reviewer 'planner' | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l2', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and ($r.raw -match 'reviewer must be one of')) 'NR4 reviewer enum violation rejected (auditor-delegated|auditor)' ($r.raw)
    Write-ReviewFile -ArchiveRel '.rdd/changes/archive/nr-l2' -StageId 'S1' -DocRels @('design/d1.md') -Verdict 'pass' -Reviewer 'auditor-delegated' -WithProduction $true -ProductionMode 'bogus-mode' | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l2', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and ($r.raw -match 'production.mode')) 'NR4 production.mode 值域校验（留痕形态）' ($r.raw)
    $badN2 = @{
        reviewed_at = '2026-10-06T09:00:00Z'; reviewer = 'auditor-delegated'; stage = 'S1'
        docs = @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @(@{ severity = 'blocking'; dimension = 'alignment'; item = 'x'; suggestion = 'y' }) })
        summary = @{ cross_design = @() }
    }
    Write-Utf8NoBom (Join-Path $Work '.rdd/changes/archive/nr-l2/review/design-review-S1.json') ($badN2 | ConvertTo-Json -Depth 6)
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l2', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and ($r.raw -match 'verdict=pass but carries')) 'NR4 pass-with-blocking inconsistency rejected (同源核心)' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l2'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'ready') 'NR4 rejected submit leaves state ready (修复重报零副作用)' ($b | ConvertTo-Json -Depth 6)

    # ================= NR5: 合法 pass（auditor-delegated + production）→ passed =================
    Write-ReviewFile -ArchiveRel '.rdd/changes/archive/nr-l2' -StageId 'S1' -DocRels @('design/d1.md') -Verdict 'pass' -Reviewer 'auditor-delegated' -WithProduction $true | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l2', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass' -and [string]$r.json.data.status -eq 'passed' -and [string]$r.json.data.reviewer -eq 'auditor-delegated') 'NR5 submit pass (engine-derived, 不采信声明值) -> passed' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l2'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'passed' -and [string]$b.plan.stages[0].design_review.verdict -eq 'pass') 'NR5 bridge state passed/verdict' ($b | ConvertTo-Json -Depth 6)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-nr-l2', '-NodeId', $devN2, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'NR5 DEV claim unblocked after submit pass' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l2', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_NOT_READY') 'NR5 repeat submit refused (仅 ready 接受)' ($r.raw)

    # ================= NR6: fail submit → 重做波（无节点可回收）+ 账本署名 =================
    $archN6 = New-Archive 'nr-l6' '[{"title":"NR6","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pfN6 = Write-TestPlan (Join-Path $Work 'nr-l6-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archN6 + '/task.json'), '-PlanFile', $pfN6, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'NR6 promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l6'
    $ctoN6 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-nr-l6' $ctoN6 'CTO' @('.rdd/changes/archive/nr-l6/design/d1.md') | Out-Null
    Do-Settle 'deliver-nr-l6' $ctoN6 | Out-Null
    $b = Read-BridgeJson 'deliver-nr-l6'
    $devN6 = [string]$b.tasks.'1'.stages.DEV
    Write-ReviewFile -ArchiveRel '.rdd/changes/archive/nr-l6' -StageId 'S1' -DocRels @('design/d1.md') -Verdict 'fail' -Reviewer 'auditor-delegated' -WithProduction $true | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l6', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'fail' -and @($r.json.data.wave.rolled).Count -ge 1) 'NR6 fail submit -> fail wave fired (零节点回收)' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l6'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'planned' -and $null -eq $b.plan.stages[0].design_review.node) 'NR6 wave completes -> reset planned (状态重置 + 覆盖重产)' ($b | ConvertTo-Json -Depth 6)
    $devN6T = Find-TreeNode 'deliver-nr-l6' $devN6
    Assert-True ($null -ne $devN6T -and [string]$devN6T.status -eq 'pruned') 'NR6 pending DEV node pruned by the wave' ($devN6T | ConvertTo-Json)
    $ctoN6New = [string]$b.tasks.'1'.stages.CTO
    $ctoN6NewT = Find-TreeNode 'deliver-nr-l6' $ctoN6New
    Assert-True ($null -ne $ctoN6NewT -and $ctoN6NewT.task -match '设计审查否决') 'NR6 rebuilt CTO node carries blocking redo context' ($ctoN6NewT | ConvertTo-Json)
    $ledgerPath = Join-Path $Work '.rdd/review-ledger.jsonl'
    $ledgerLines = @()
    if (Test-Path $ledgerPath) { foreach ($ln in (Get-Content $ledgerPath -Encoding UTF8)) { if (-not [string]::IsNullOrWhiteSpace($ln)) { try { $ledgerLines += ($ln | ConvertFrom-Json) } catch { } } } }
    Assert-True (@($ledgerLines | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.run_id -eq 'deliver-nr-l6' -and [string]$_.reviewer -eq 'auditor-delegated' }).Count -ge 1) 'NR6 ledger summary signed auditor-delegated (新枚举署名)' (($ledgerLines | ConvertTo-Json -Depth 4))

    # ================= NR7: session 强形态（review_mode=session → reviewer=auditor） =================
    $archN7 = New-Archive 'nr-l7' '[{"title":"NR7","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $pfN7 = Write-TestPlan (Join-Path $Work 'nr-l7-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archN7 + '/task.json'), '-PlanFile', $pfN7, '-ReviewMode', 'session', '-NoPush')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.design_review.mode -eq 'session') 'NR7 promulgate -ReviewMode session' ($r.raw)
    $b = Read-BridgeJson 'deliver-nr-l7'
    Assert-True ([string]$b.review_mode -eq 'session') 'NR7 review_mode=session persisted' ($b | ConvertTo-Json -Depth 6)
    $ctoN7 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-nr-l7' $ctoN7 'CTO' @('.rdd/changes/archive/nr-l7/design/d1.md') | Out-Null
    Do-Settle 'deliver-nr-l7' $ctoN7 | Out-Null
    Write-ReviewFile -ArchiveRel '.rdd/changes/archive/nr-l7' -StageId 'S1' -DocRels @('design/d1.md') -Verdict 'pass' -Reviewer 'auditor' -WithProduction $true -ProductionMode 'session' | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l7', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass' -and [string]$r.json.data.reviewer -eq 'auditor') 'NR7 session-form submit pass (reviewer=auditor 同契约入库)' ($r.raw)

    # ================= NR8: 缺键 legacy run 拒 submit + 动作守卫 =================
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-dr-l1', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_LEGACY_RUN') 'NR8 legacy run (缺键) submit refused — settle 通道不变' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', 'deliver-dr-l1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.chain -eq 'legacy (node settle)' -and $null -eq $r.json.data.review_mode) 'NR8 legacy run status face (read-only, chain label)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'open', '-RunId', 'deliver-nr-l2')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_ACTION_INVALID') 'NR8 conflict/derive action values rejected' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'design-review', '-RunId', 'deliver-nr-l2')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_ACTION_REQUIRED') 'NR8 missing -Action rejected' ($r.raw)

    # ================= NR9: replan 新增阶段的审查槽位（derive × 审查 集成面） =================
    # run 中途派生并入**新阶段**是 derive 通道的常态出口（同阶段吸收在派生任务带
    # DependsOn 时会与「全部任务过 DESIGN」触发条件互锁）；新段若没有 design_review
    # 段，其设计产物就静默逃过阶段边界审查（新链「评审强制、无 off 值」的缺口）。
    # 修法：新链（bridge.json review_mode 存在）的新段恒落 planned 槽位（与 promulgate
    # 段同构）；缺键 legacy run 不落段（部署双探只在 promulgate 生效，逐字节不回改）。
    $archN9 = New-Archive 'nr-l9' '[{"title":"NR9a","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]},{"title":"NR9b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]}]' $Script:DeclaredBlock
    $pfN9 = Write-TestPlan (Join-Path $Work 'nr-l9-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archN9 + '/task.json'), '-PlanFile', $pfN9, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'NR9 promulgate ok (single stage, subagent)' ($r.raw)
    $pfN9b = Write-TestPlan (Join-Path $Work 'nr-l9-plan2.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) })
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-nr-l9', '-PlanFile', $pfN9b, '-Reason', 'NR9: stage expansion (derive-like new stage)')
    Assert-True ($r.json.success -eq $true) 'NR9 replan adds a new stage' ($r.raw)
    $b9 = Read-BridgeJson 'deliver-nr-l9'
    $s2 = @($b9.plan.stages | Where-Object { [string]$_.id -eq 'S2' })[0]
    Assert-True ($null -ne $s2 -and $null -ne $s2.design_review -and [string]$s2.design_review.status -eq 'planned') 'NR9 [integration] a replan-added stage lands a planned review slot (no silent unreviewed stage)' ($b9.plan.stages | ConvertTo-Json -Depth 6)
    Assert-True (@(Read-PlanLog 'deliver-nr-l9' | Where-Object { [string]$_.event -eq 'design_review_slot_staged' }).Count -ge 1) 'NR9 plan-log design_review_slot_staged recorded' ((Read-PlanLog 'deliver-nr-l9') | ConvertTo-Json -Depth 4)
    # S1（全 DEV、无设计产物 -> exempt 快速通道）跑完并过其验收点，S2 才放行
    $dev9a = [string]$b9.tasks.'1'.stages.DEV
    Do-Deliver 'deliver-nr-l9' $dev9a 'DEV' @('.rdd/changes/archive/nr-l9/requirements/t1.md') | Out-Null
    Do-Settle 'deliver-nr-l9' $dev9a | Out-Null
    $qa9a = [string](Read-BridgeJson 'deliver-nr-l9').tasks.'1'.stages.QA
    Do-Deliver 'deliver-nr-l9' $qa9a 'QA' @('.rdd/changes/archive/nr-l9/requirements/t1.md') | Out-Null
    Do-Settle 'deliver-nr-l9' $qa9a | Out-Null
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-nr-l9')
    $b9 = Read-BridgeJson 'deliver-nr-l9'
    $sa9 = [string]$b9.plan.stages[0].acceptance_point.node
    Assert-True ($sa9 -ne '') 'NR9 S1 acceptance point grafts (S1 is no longer the final stage)' ($b9.plan.stages[0].acceptance_point | ConvertTo-Json -Depth 4)
    Do-Deliver 'deliver-nr-l9' $sa9 'QA' @('.rdd/changes/archive/nr-l9/requirements/overview.md') | Out-Null
    Do-Settle 'deliver-nr-l9' $sa9 | Out-Null
    # S2：新段的审查真实生效（其任务过 DESIGN -> ready；IMPL 被闸；pass 后放行）
    $cto9b = [string]$b9.tasks.'2'.stages.CTO
    Do-Deliver 'deliver-nr-l9' $cto9b 'CTO' @('.rdd/changes/archive/nr-l9/design/d2.md') | Out-Null
    Do-Settle 'deliver-nr-l9' $cto9b | Out-Null
    $b9 = Read-BridgeJson 'deliver-nr-l9'
    $s2 = @($b9.plan.stages | Where-Object { [string]$_.id -eq 'S2' })[0]
    Assert-True ([string]$s2.design_review.status -eq 'ready' -and $null -eq $s2.design_review.node) 'NR9 the new stage review reaches ready (zero node, new chain)' ($s2.design_review | ConvertTo-Json -Depth 4)
    $dev9b = [string]$b9.tasks.'2'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-nr-l9', '-NodeId', $dev9b, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'NR9 the new stage gates its IMPL node' ($r.raw)
    Write-ReviewFile '.rdd/changes/archive/nr-l9' 'S2' @('design/d2.md') 'pass' -Reviewer 'auditor-delegated' -WithProduction $true | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-nr-l9', '-Stage', 'S2')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass') 'NR9 the new stage review submits through the same contract chain' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-nr-l9', '-NodeId', $dev9b, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'NR9 the new stage IMPL unblocked after pass' ($r.raw)
    # legacy（缺键）侧不回改：同样的 replan 扩容不落段
    $archN9L = New-Archive 'nr-l9l' '[{"title":"NR9L-a","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]},{"title":"NR9L-b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]}]' $Script:DeclaredBlock
    $pfN9L = Write-TestPlan (Join-Path $Work 'nr-l9l-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archN9L + '/task.json'), '-PlanFile', $pfN9L, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'NR9 legacy promulgate ok (缺键)' ($r.raw)
    $pfN9Lb = Write-TestPlan (Join-Path $Work 'nr-l9l-plan2.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) })
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-nr-l9l', '-PlanFile', $pfN9Lb, '-Reason', 'NR9 legacy: stage expansion')
    Assert-True ($r.json.success -eq $true) 'NR9 legacy replan adds a new stage' ($r.raw)
    $b9l = Read-BridgeJson 'deliver-nr-l9l'
    $s2l = @($b9l.plan.stages | Where-Object { [string]$_.id -eq 'S2' })[0]
    Assert-True ($null -ne $s2l -and $null -eq $s2l.design_review) 'NR9 [legacy 不回溯] a new stage in a 缺键 run lands NO slot (byte-identical)' ($s2l | ConvertTo-Json -Depth 6)
    # ================= DR8: design_maps 刷新语义（design-maps-refresh-deadlock 主修） =================
    # 新链 fail 波后文档重产 / 迟入册：status 与 submit 门都须重解析缓存（fingerprint
    # 追平当前文件 + 新文档入册），杜绝「文档已修、缓存滞后、重审必现 blocking」死循环。
    $arch8 = New-Archive 'dr-l8' '[{"title":"DR8","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d8.md","status":"ready"}]}]'
    $pf8 = Write-TestPlan (Join-Path $Work 'dr-l8-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch8 + '/task.json'), '-PlanFile', $pf8, '-NoPush', '-ReviewMode', 'subagent')
    Assert-True ($r.json.success -eq $true) 'DR8 promulgate ok (new chain)' ($r.raw)
    $b8 = Read-BridgeJson 'deliver-dr-l8'
    $fpBefore = [string]$b8.design_maps.'design/d8.md'.fingerprint
    Assert-True (-not [string]::IsNullOrWhiteSpace($fpBefore)) 'DR8 initial scan populates design_maps (fingerprint present)' ($b8 | ConvertTo-Json -Depth 6)
    # 文档重产（指纹变化）+ 迟入册第二文档（手改 task.json 模拟 fail 波后的 add-design 形态）
    $d8Abs = Join-Path $Work '.rdd/changes/archive/dr-l8/design/d8.md'
    Write-Utf8NoBom $d8Abs "# 设计文档 8（重产）`n`n变更地图：`n`n- ``src/mod-b.py``  [修改] 模块 B`n`n[新增] 0 | [修改] 1 | [删除] 0`n"
    $d8bAbs = Join-Path $Work '.rdd/changes/archive/dr-l8/design/d8b.md'
    Write-Utf8NoBom $d8bAbs "# 设计文档 8b（迟入册）`n`n变更地图：`n`n- ``src/mod-c.py``  [新增] 模块 C`n`n[新增] 1 | [修改] 0 | [删除] 0`n"
    $tj8p = Join-Path $Work '.rdd/changes/archive/dr-l8/task.json'
    $tj8 = Get-Content -LiteralPath $tj8p -Raw -Encoding UTF8 | ConvertFrom-Json
    $tj8.tasks[0].designDocs += @{ path = 'design/d8b.md'; status = 'ready' }
    Write-Utf8NoBom $tj8p ($tj8 | ConvertTo-Json -Depth 8)
    # status 首跑即自愈：指纹追平 + 新文档入册
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', 'deliver-dr-l8')
    Assert-True ($r.json.success -eq $true) 'DR8 status ok' ($r.raw)
    $fi8 = Get-Item -LiteralPath $d8Abs
    $fpNow = "$($fi8.Length):$($fi8.LastWriteTimeUtc.Ticks)"
    $b8 = Read-BridgeJson 'deliver-dr-l8'
    Assert-True (([string]$b8.design_maps.'design/d8.md'.fingerprint) -eq $fpNow -and $fpBefore -ne $fpNow) 'DR8 status refreshes the stale fingerprint (frozen cache self-heals on first run)' ($b8 | ConvertTo-Json -Depth 6)
    Assert-True ($null -ne $b8.design_maps.'design/d8b.md') 'DR8 late-registered doc enters design_maps' ($b8 | ConvertTo-Json -Depth 6)
    # 越过 DESIGN → ready → submit 门同样刷新（幂等）+ 迟入册文档进审查对象面
    $cto8 = [string]$b8.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-dr-l8' $cto8 'CTO' @('.rdd/changes/archive/dr-l8/design/d8.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l8' $cto8
    Assert-True ($r.json.success -eq $true) 'DR8 CTO settle ok' ($r.raw)
    $b8 = Read-BridgeJson 'deliver-dr-l8'
    Assert-True ([string]$b8.plan.stages[0].design_review.status -eq 'ready') 'DR8 trigger -> ready' ($b8 | ConvertTo-Json -Depth 6)
    Write-ReviewFile '.rdd/changes/archive/dr-l8' 'S1' @('design/d8.md', 'design/d8b.md') 'pass' -Reviewer 'auditor-delegated' -WithProduction $true | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-dr-l8', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass' -and @($r.json.data.blocking).Count -eq 0) 'DR8 submit pass over the refreshed face (late doc accepted)' ($r.raw)

    # ================= DR9: designDocs 全路径归一（design-docs-path-normalization，defect 6.A） =================
    # 历史登记形态含绝对路径：归一后按归档相对键入册（修复前 Join-Path 失明 → 无产物
    # → exempt，审查面整体缺失——实录 S2 漏审 #5）。
    $arch9 = New-Archive 'dr-l9' '[{"title":"DR9","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d9.md","status":"ready"}]}]'
    $tj9p = Join-Path $Work '.rdd/changes/archive/dr-l9/task.json'
    $tj9 = Get-Content -LiteralPath $tj9p -Raw -Encoding UTF8 | ConvertFrom-Json
    $tj9.tasks[0].designDocs[0].path = ((Join-Path $Work '.rdd/changes/archive/dr-l9/design/d9.md') -replace '\\', '/')
    Write-Utf8NoBom $tj9p ($tj9 | ConvertTo-Json -Depth 8)
    $pf9 = Write-TestPlan (Join-Path $Work 'dr-l9-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch9 + '/task.json'), '-PlanFile', $pf9, '-NoPush', '-ReviewMode', 'subagent')
    Assert-True ($r.json.success -eq $true) 'DR9 promulgate ok' ($r.raw)
    $b9f = Read-BridgeJson 'deliver-dr-l9'
    Assert-True ($null -ne $b9f.design_maps.'design/d9.md') 'DR9 full-path designDoc lands in design_maps under the REL key' ($b9f | ConvertTo-Json -Depth 6)
    $cto9 = [string]$b9f.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-dr-l9' $cto9 'CTO' @('.rdd/changes/archive/dr-l9/design/d9.md') | Out-Null
    $r = Do-Settle 'deliver-dr-l9' $cto9
    Assert-True ($r.json.success -eq $true) 'DR9 CTO settle ok' ($r.raw)
    $b9f = Read-BridgeJson 'deliver-dr-l9'
    Assert-True ([string]$b9f.plan.stages[0].design_review.status -eq 'ready') 'DR9 normalized doc reaches the review trigger (exempt = the doc was missed)' ($b9f | ConvertTo-Json -Depth 6)
    Write-ReviewFile '.rdd/changes/archive/dr-l9' 'S1' @('design/d9.md') 'pass' -Reviewer 'auditor-delegated' -WithProduction $true | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-dr-l9', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass') 'DR9 submit pass (rel-keyed coverage accepted)' ($r.raw)

    # ================= DR10: cross_design 组合洞随 fail 波传递（defect 6.B） =================
    # 全文档 pass 但 cross_design blocking：involved_docs 展开映射 + 无属主文档广播兜底
    # ——两任务全部回 DESIGN，重做指针携带组合洞 problems（修复前不随波传递）。
    $archX = New-Archive 'dr-lx' '[{"title":"DR10a","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d10a.md","status":"ready"}]},{"title":"DR10b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d10b.md","status":"ready"}]}]' $Script:DeclaredBlock
    $pfX = Write-TestPlan (Join-Path $Work 'dr-lx-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $convX = Join-Path $Work 'dr-lx-conventions.md'
    Write-Utf8NoBom $convX "# 架构约定（DR10 测试）`n`n- 分层一致；命名沿用现有风格。`n"
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archX + '/task.json'), '-PlanFile', $pfX, '-ConventionsFile', $convX, '-NoPush', '-ReviewMode', 'subagent')
    Assert-True ($r.json.success -eq $true) 'DR10 promulgate ok' ($r.raw)
    $bX = Read-BridgeJson 'deliver-dr-lx'
    Do-Deliver 'deliver-dr-lx' ([string]$bX.tasks.'1'.stages.CTO) 'CTO' @('.rdd/changes/archive/dr-lx/design/d10a.md') | Out-Null
    Do-Settle 'deliver-dr-lx' ([string]$bX.tasks.'1'.stages.CTO) | Out-Null
    Do-Deliver 'deliver-dr-lx' ([string]$bX.tasks.'2'.stages.CTO) 'CTO' @('.rdd/changes/archive/dr-lx/design/d10b.md') | Out-Null
    $r = Do-Settle 'deliver-dr-lx' ([string]$bX.tasks.'2'.stages.CTO)
    Assert-True ($r.json.success -eq $true -and [string](Read-BridgeJson 'deliver-dr-lx').plan.stages[0].design_review.status -eq 'ready') 'DR10 both CTO settled -> ready' ($r.raw)
    Write-ReviewFile '.rdd/changes/archive/dr-lx' 'S1' @('design/d10a.md', 'design/d10b.md') 'pass' -Reviewer 'auditor-delegated' -WithProduction $true -CrossDocs @('design/d10a.md', 'design/d10b.md') | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-dr-lx', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'fail') 'DR10 cross_design blocking -> engine-derived fail' ($r.raw)
    $rolledIds = @($r.json.data.wave.rolled | ForEach-Object { [int]$_.task_id })
    Assert-True (($rolledIds -contains 1) -and ($rolledIds -contains 2) -and $rolledIds.Count -eq 2) 'DR10 combo hole rolls BOTH tasks' ($r.raw)
    $p1 = @(@($r.json.data.wave.rolled) | Where-Object { [int]$_.task_id -eq 1 })[0]
    Assert-True (@(@($p1.problems) -match 'cross_design').Count -gt 0) 'DR10 redo pointer carries the cross_design problem' ($r.raw)
    $bX = Read-BridgeJson 'deliver-dr-lx'
    Assert-True ([string]$bX.plan.stages[0].design_review.status -eq 'planned') 'DR10 fail wave resets planned (re-review on next convergence)' ($bX | ConvertTo-Json -Depth 6)
}
finally {
    Pop-Location
}

$fails = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("design-review suite: {0} assertions, {1} failed" -f $Results.Count, $fails.Count)
if ($fails.Count -gt 0) { exit 1 }
exit 0

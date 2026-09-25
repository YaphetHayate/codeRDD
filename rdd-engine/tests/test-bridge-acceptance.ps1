# overall-delivery acceptance tests — 端到端整体交付闭环（判据锚 + 验收链 + conclude 硬门）
# Covers requirements/overall-delivery.md acceptance 1/2 + design regressions:
#   T1 ACCEPTANCE_CRITERIA_MISSING: >=2 tasks without `## 整体验收判据` -> hard fail, zero residue
#   T2 single-task exemption: no criteria needed (basis=single_exempt), old flow byte-behavior
#   T3 declared-none exit: `无整体判据（理由：…）` -> basis=declared_none, no chain, conclude unchanged
#   T4 criteria mode + graft timing: acceptance planned at promulgate; chain grafts only after
#      ALL mapped nodes settle (2-task width formula +2 -> node_width=4)
#   T5 tree-level branch: role binding + evidence gate + documented reclaim boundary + ACCEPTANCE_PENDING
#   T6a full ladder: integrate -> accept -> §3 recorded -> conclude achieved; annex「整体验收结论」
#   T6b conclusion re-read ladder: ACCEPTANCE_PENDING -> NOT_PASSED -> 通过 (no re-settle needed)
#   T7 3-task WIDTH_EXCEEDED regression: heads+2 formula fits both chain nodes
#   T8 in-tree repair node reuse (unified tree-level branch): graft 下探 -> claim/report/settle, flow untouched
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('bridge-acceptance-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Read-Tasks { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/task.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
}

# overview blocks (acceptance criteria carrier fixtures)
$Script:CriteriaBlock = "## 整体验收判据`n`n| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |`n|---|------|------|------|`n| 1 | 端到端跑通完整场景 | demo 实证 | 需求 1、2 |`n"
$Script:DeclaredBlock = "## 整体验收判据`n`n无整体判据（理由：两个独立交付无共同完整场景，归档级已显式声明）`n"

# New archive: overview + task docs + init via rdd-flow (phase stored). OverviewExtra =
# criteria/declaration block or empty (exercises the missing-criteria gate).
function New-Archive { param([string]$Name, [string]$TasksJson, [string]$OverviewExtra = '')
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nacceptance 测试归档 $Name。`n`n$OverviewExtra"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        $doc = "requirements/t$i.md"
        $depLine = ''
        if ($line.dep) { $depLine = "- **依赖关系**：依赖需求 $($line.dep)`n" }
        Write-Utf8NoBom (Join-Path $archDir $doc) "# $Name 需求 $i`n`n- **描述**：acceptance 测试需求 $i`n- **验收标准**：见 overview.md`n$depLine"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

# Minimal PlanFile writer (long-task-planning): stages = the given task sets;
# each stage's batches = topological layers of its tasks under the dep map.
# -CriteriaRef pins the R1 anchor (criteria-mode archives require it).
function Write-TestPlan { param([string]$Path, $Stages, $Deps, [string]$CriteriaItem = 'smoke: core flow works', [string]$CriteriaRef = '')
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
        $ap = @{ criteria_items = @($CriteriaItem); slice = 'runnable single-command slice' }
        if ($CriteriaRef) { $ap['criteria_ref'] = $CriteriaRef }
        $stageObjs += ,@{
            id = [string]$st.id
            goal = "stage $($st.id) 目标"
            milestone = "stage $($st.id) 里程碑"
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = $batches
            acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-09-25T00:00:00Z'; planner = 'test'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

function New-Cb { param([string]$NodeId, [string]$Ref, [bool]$Qualified = $true)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'bridge-acceptance test delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
    }
    if ($Qualified) { $cb['extras'] = @{ verification = 'smoke ok' } }
    $cbFile = Join-Path $env:TEMP ("ba-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
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
    # ================= T1: ACCEPTANCE_CRITERIA_MISSING + zero residue =================
    $arch1 = New-Archive 'ba-t1' '[{"title":"T1a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"T1b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]'
    $pf1 = Write-TestPlan (Join-Path $Work 'ba-t1-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ACCEPTANCE_CRITERIA_MISSING') 'T1 missing criteria section -> ACCEPTANCE_CRITERIA_MISSING' ($r.raw)
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-ba-t1'))) 'T1 zero run residue (nothing created)'

    # ================= T2: single-task exemption =================
    $arch2 = New-Archive 'ba-t2' '[{"title":"T2","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]}]'
    $pf2 = Write-TestPlan (Join-Path $Work 'ba-t2-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-PlanFile', $pf2, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T2 single-task promulgate ok without criteria' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t2'
    Assert-True ([string]$b.acceptance.basis -eq 'single_exempt' -and [string]$b.acceptance.status -eq 'none') 'T2 acceptance basis=single_exempt status=none'
    $h2 = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-ba-t2' $h2 'QA' "$arch2/requirements/t1.md"
    $r = Do-Settle 'deliver-ba-t2' $h2
    Assert-True ($r.json.success -eq $true) 'T2 head settle ok (no chain involved)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t2', '-Summary', 'T2 done')
    Assert-True ($r.json.success -eq $true -and $r.json.data.outcome -eq 'achieved') 'T2 conclude ok without acceptance report (exempt)' ($r.raw)
    $annex2 = Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-ba-t2/report/delivery-annex.md') -Raw -Encoding UTF8
    Assert-True ($annex2 -match '整体验收结论' -and $annex2 -match 'single_exempt') 'T2 annex carries「整体验收结论」区 with exempt basis'

    # ================= T3: declared-none exit =================
    $arch3 = New-Archive 'ba-t3' '[{"title":"T3a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"T3b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:DeclaredBlock
    $pf3 = Write-TestPlan (Join-Path $Work 'ba-t3-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-PlanFile', $pf3, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T3 declared-none promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t3'
    Assert-True ([string]$b.acceptance.basis -eq 'declared_none' -and [string]$b.acceptance.status -eq 'none') 'T3 acceptance basis=declared_none (no chain ever)'
    $ha = [string]$b.tasks.'1'.stages.QA; $hb = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-ba-t3' $ha 'QA' "$arch3/requirements/t1.md"
    $null = Do-Settle 'deliver-ba-t3' $ha
    Do-Deliver 'deliver-ba-t3' $hb 'QA' "$arch3/requirements/t2.md"
    $null = Do-Settle 'deliver-ba-t3' $hb
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t3', '-Summary', 'T3 done')
    Assert-True ($r.json.success -eq $true) 'T3 conclude ok without acceptance report (declared)' ($r.raw)

    # ================= T4: criteria mode + graft timing + width formula =================
    $arch4 = New-Archive 'ba-t4' '[{"title":"T4a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"T4b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf4 = Write-TestPlan (Join-Path $Work 'ba-t4-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch4 + '/task.json'), '-PlanFile', $pf4, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T4 criteria promulgate ok' ($r.raw)
    Assert-True ([int]$r.json.data.budget.node_width -eq 4) 'T4 width formula heads+2 -> 4' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t4'
    Assert-True ([string]$b.acceptance.status -eq 'planned' -and [string]$b.acceptance.criteria_ref -eq 'requirements/overview.md#整体验收判据') 'T4 acceptance planned + criteria_ref anchored'
    Assert-True ($null -eq $b.acceptance.integrate_node -or [string]$b.acceptance.integrate_node -eq '') 'T4 chain NOT grafted at promulgate (timing)'
    $h4a = [string]$b.tasks.'1'.stages.QA; $h4b = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-ba-t4' $h4a 'QA' "$arch4/requirements/t1.md"
    $null = Do-Settle 'deliver-ba-t4' $h4a
    $b = Read-BridgeJson 'deliver-ba-t4'
    Assert-True ($null -eq $b.acceptance.integrate_node -or [string]$b.acceptance.integrate_node -eq '') 'T4 chain waits for ALL mapped nodes (1/2 settled)'
    Do-Deliver 'deliver-ba-t4' $h4b 'QA' "$arch4/requirements/t2.md"
    $r = Do-Settle 'deliver-ba-t4' $h4b
    Assert-True ($r.json.success -eq $true) 'T4 last mapped settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t4'
    $integ = [string]$b.acceptance.integrate_node
    Assert-True ($integ -ne '' -and [string]$b.acceptance.status -eq 'grafted') 'T4 [集成/联调] grafted after last mapped settle' ("integrate=$integ")
    $nInteg = Find-TreeNode 'deliver-ba-t4' $integ
    Assert-True ($null -ne $nInteg -and [string]$nInteg.type -ne 'goal' -and [string]$nInteg.role -eq 'dev') 'T4 integrate node is tree-level work node (role=dev, type!=goal)'

    # ================= T5: tree-level claim/settle branch + boundaries =================
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-ba-t4', '-NodeId', $integ, '-Role', 'QA')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ROLE_INVALID') 'T5 tree-level claim with wrong role -> ROLE_INVALID' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-ba-t4', '-NodeId', 'n1', '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_NOT_MAPPED') 'T5 goal root is not a delivery unit' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-ba-t4', '-NodeId', $integ, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true -and $r.json.data.tree_level -eq $true -and [string]$r.json.data.acceptance.kind -eq 'integrate' -and $null -eq $r.json.data.task_id) 'T5 tree-level claim: tree_level + acceptance context, no TaskId' ($r.raw)
    $cbBad = New-Cb $integ "$arch4/tests/integration-acceptance.md" $false
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-ba-t4', '-Worker', 'DEV', '-CallbackFile', $cbBad)
    $r = Do-Settle 'deliver-ba-t4' $integ
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and $r.json.error.message -match 'tree-level') 'T5 unqualified tree-level delivery rejected (honest disposition)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-ba-t4', '-NodeId', $integ)
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_NOT_MAPPED') 'T5 documented boundary: tree-level reclaim out of scope -> NODE_NOT_MAPPED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t4', '-Summary', 'T5 conclude')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ACCEPTANCE_PENDING') 'T5 stuck chain -> conclude reports ACCEPTANCE_PENDING' ($r.raw)

    # ================= T6a: full ladder -> recorded conclusion -> achieved =================
    $arch6 = New-Archive 'ba-t6' '[{"title":"T6a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"T6b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf6 = Write-TestPlan (Join-Path $Work 'ba-t6-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6 + '/task.json'), '-PlanFile', $pf6, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T6a promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t6'
    $g6a = [string]$b.tasks.'1'.stages.QA; $g6b = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-ba-t6' $g6a 'QA' "$arch6/requirements/t1.md"; $null = Do-Settle 'deliver-ba-t6' $g6a
    Do-Deliver 'deliver-ba-t6' $g6b 'QA' "$arch6/requirements/t2.md"; $null = Do-Settle 'deliver-ba-t6' $g6b
    $b = Read-BridgeJson 'deliver-ba-t6'
    $i6 = [string]$b.acceptance.integrate_node
    Assert-True ($i6 -ne '') 'T6a integrate grafted'
    Write-AcceptanceReport $arch6 '通过'
    $tasksBefore = (Get-Content -LiteralPath (Join-Path $Work "$arch6/task.json") -Raw -Encoding UTF8)
    $r = Do-Deliver 'deliver-ba-t6' $i6 'DEV' "$arch6/tests/integration-acceptance.md"
    Assert-True ($r.json.success -eq $true) 'T6a integrate deliver ok' ($r.raw)
    $r = Do-Settle 'deliver-ba-t6' $i6
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -like 'tree-level*') 'T6a integrate settle is tree-level (终态即止)' ($r.raw)
    $tasksAfter = (Get-Content -LiteralPath (Join-Path $Work "$arch6/task.json") -Raw -Encoding UTF8)
    Assert-True ($tasksBefore -eq $tasksAfter) 'T6a tree-level settle never touches task.json'
    $b = Read-BridgeJson 'deliver-ba-t6'
    $a6 = [string]$b.acceptance.accept_node
    Assert-True ($a6 -ne '') 'T6a [整体验收] grafted after integrate settle' ("accept=$a6")
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-ba-t6', '-NodeId', $a6, '-Role', 'QA')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.acceptance.kind -eq 'accept') 'T6a accept claim carries acceptance context' ($r.raw)
    $cbA = New-Cb $a6 "$arch6/tests/integration-acceptance.md"
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-ba-t6', '-Worker', 'QA', '-CallbackFile', $cbA)
    $r = Do-Settle 'deliver-ba-t6' $a6
    Assert-True ($r.json.success -eq $true) 'T6a accept settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t6'
    Assert-True ([string]$b.acceptance.conclusion -eq '通过' -and [string]$b.acceptance.recorded_at -ne '') 'T6a conclusion recorded at accept settle' ("conclusion=$($b.acceptance.conclusion)")
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t6', '-Summary', 'T6a all green')
    Assert-True ($r.json.success -eq $true -and $r.json.data.outcome -eq 'achieved') 'T6a conclude achieved gated on 通过' ($r.raw)
    $annex6 = Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-ba-t6/report/delivery-annex.md') -Raw -Encoding UTF8
    Assert-True ($annex6 -match '整体验收结论' -and $annex6 -match '总结论: 通过' -and $annex6 -match 'integration-acceptance\.md') 'T6a annex「整体验收结论」shows verdict + report pointer'
    Assert-True (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-ba-t6/report/final-report.md')) 'T6a final-report.md rendered'

    # ================= T6b: conclusion re-read ladder (no re-settle needed) =================
    $arch7 = New-Archive 'ba-t7' '[{"title":"T7a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"T7b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf7 = Write-TestPlan (Join-Path $Work 'ba-t7-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-PlanFile', $pf7, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T6b promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t7'
    $k7a = [string]$b.tasks.'1'.stages.QA; $k7b = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-ba-t7' $k7a 'QA' "$arch7/requirements/t1.md"; $null = Do-Settle 'deliver-ba-t7' $k7a
    Do-Deliver 'deliver-ba-t7' $k7b 'QA' "$arch7/requirements/t2.md"; $null = Do-Settle 'deliver-ba-t7' $k7b
    $b = Read-BridgeJson 'deliver-ba-t7'
    $i7 = [string]$b.acceptance.integrate_node
    Write-AcceptanceReport $arch7 ''          # §1/§2 only — §3 missing
    Do-Deliver 'deliver-ba-t7' $i7 'DEV' "$arch7/tests/integration-acceptance.md"
    $null = Do-Settle 'deliver-ba-t7' $i7
    $b = Read-BridgeJson 'deliver-ba-t7'
    $a7 = [string]$b.acceptance.accept_node
    Do-Deliver 'deliver-ba-t7' $a7 'QA' "$arch7/tests/integration-acceptance.md"
    $null = Do-Settle 'deliver-ba-t7' $a7
    $b = Read-BridgeJson 'deliver-ba-t7'
    Assert-True ($null -eq $b.acceptance.conclusion -or [string]$b.acceptance.conclusion -eq '') 'T6b accept settled without §3 -> conclusion unrecorded'
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t7', '-Summary', 'T6b pending')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ACCEPTANCE_PENDING') 'T6b conclude -> ACCEPTANCE_PENDING' ($r.raw)
    Write-AcceptanceReport $arch7 '不通过'
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t7', '-Summary', 'T6b not passed')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ACCEPTANCE_NOT_PASSED') 'T6b conclude -> ACCEPTANCE_NOT_PASSED on 不通过' ($r.raw)
    Write-AcceptanceReport $arch7 '通过'
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-ba-t7', '-Summary', 'T6b passed after fix')
    Assert-True ($r.json.success -eq $true) 'T6b fix §3 -> conclude achieved (no re-settle needed)' ($r.raw)

    # ================= T7: 3-task width regression (heads+2) =================
    $arch8 = New-Archive 'ba-t8' '[{"title":"T8a","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]},{"title":"T8b","requirement":"requirements/t2.md","currentOwners":["QA"],"designDocs":[]},{"title":"T8c","requirement":"requirements/t3.md","currentOwners":["QA"],"designDocs":[]}]' $Script:CriteriaBlock
    $pf8 = Write-TestPlan (Join-Path $Work 'ba-t8-plan.json') @(@{ id = 'S1'; tasks = @(1, 2, 3) }) @{} 'smoke: core flow works' 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch8 + '/task.json'), '-PlanFile', $pf8, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 5) 'T7 3-task width formula heads+2 -> 5' ($r.raw)
    $b = Read-BridgeJson 'deliver-ba-t8'
    foreach ($k in @('1', '2', '3')) {
        $hn = [string]$b.tasks.$k.stages.QA
        Do-Deliver 'deliver-ba-t8' $hn 'QA' "$arch8/requirements/t$([int]$k).md"
        $null = Do-Settle 'deliver-ba-t8' $hn
    }
    $b = Read-BridgeJson 'deliver-ba-t8'
    $i8 = [string]$b.acceptance.integrate_node
    Assert-True ($i8 -ne '') 'T7 integrate graft fits width (no WIDTH_EXCEEDED)' ("integrate=$i8")
    Write-AcceptanceReport $arch8 '通过'
    Do-Deliver 'deliver-ba-t8' $i8 'DEV' "$arch8/tests/integration-acceptance.md"
    $null = Do-Settle 'deliver-ba-t8' $i8
    $b = Read-BridgeJson 'deliver-ba-t8'
    Assert-True ([string]$b.acceptance.accept_node -ne '') 'T7 accept graft fits width (5th goal-root child)' ("accept=$($b.acceptance.accept_node)")

    # ================= T8: in-tree repair node reuse (unified tree-level branch) =================
    $graftFile = Join-Path $Work 't8-repair.json'
    Write-Utf8NoBom $graftFile '[{"title":"[修复] T4 不合格集成返修","task":"修复目标：补齐集成证据。","role":"dev","ref":"ba-t4/requirements/overview.md"}]'
    $r = Invoke-Tree @('-Command', 'graft', '-RunId', 'deliver-ba-t4', '-Parent', 'n1', '-TasksFile', $graftFile)
    Assert-True ($r.json.success -eq $true) 'T8 planner graft 下探 repair node ok' ($r.raw)
    $rid = [string]$r.json.data.grafted[0].id
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-ba-t4', '-NodeId', $rid)
    Assert-True ($r.json.success -eq $true -and $r.json.data.tree_level -eq $true -and [string]$r.json.data.start_context -match 'repair') 'T8 repair node claimable via unified branch (role default)' ($r.raw)
    $cbR = New-Cb $rid "$arch4/requirements/overview.md"
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-ba-t4', '-Worker', 'DEV', '-CallbackFile', $cbR)
    $tasksBeforeT8 = (Get-Content -LiteralPath (Join-Path $Work "$arch4/task.json") -Raw -Encoding UTF8)
    $r = Do-Settle 'deliver-ba-t4' $rid
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -like 'tree-level*') 'T8 repair node settle is tree-level' ($r.raw)
    $tasksAfterT8 = (Get-Content -LiteralPath (Join-Path $Work "$arch4/task.json") -Raw -Encoding UTF8)
    Assert-True ($tasksBeforeT8 -eq $tasksAfterT8) 'T8 repair settle never touches task.json (边界留痕)'
}
finally {
    Pop-Location
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("== bridge-acceptance: {0} passed, {1} failed ==" -f (@($Results).Count - $failed.Count), $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

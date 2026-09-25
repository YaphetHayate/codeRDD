# parallel-coordination conflict tests — 并行协作冲突预防与治理
# Covers requirements/parallel-coordination.md acceptance 1/2 + design regressions:
#   T1 CONVENTIONS_MISSING: >=2 parallel DESIGN chain heads without -ConventionsFile
#      -> hard fail BEFORE any run state (zero residue)
#   T2 conventions injection: -ConventionsFile lands report/architecture-conventions.md
#      + bridge.conventions +「架构约定：<path>」 in every DESIGN head node.task
#   T3 single-design / serial-design exemption: no conventions file needed
#   T4 file-overlap prevention: change-map exact-path overlap across concurrent DEV
#      nodes -> auto-registered kind=file conflict (change-map-scan) + both nodes held
#      at the push gate (no push attempt ever made)
#   T5 ownership/serialization resolution: conflict -Action resolve -Serialize <earlier>
#      -> later node depends_on earlier (goal-tree deps), earlier settles, later released
#   T6 design-kind settle gate: involved node ALWAYS rejected (不得默默二选一) until
#      resolved; escalated state attribute + resolution record the ruling
#   T7 file-kind settle gate split: dual-active writers block (first-landing premise);
#      a single active writer passes
#   T8 registry errors: CONFLICT_NOT_FOUND / CONFLICT_ALREADY_RESOLVED / CONFLICT_ENTRY_INVALID
#   T9 legacy change-map degrade: DESIGN_MAP_INVALID warning, never blocks the flow
#   T10 citation consistency soft-check: citations beyond the change map settle with a
#      warning + design_maps[].citation_deviations record (never hard-rejected)
#   T11 non-blocking guarantee: an open file conflict holds ONLY its involved nodes —
#      a third task without overlap keeps pushing / stays dispatchable
#      (需求边界: 不阻塞无冲突任务)
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('bridge-conflicts-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Find-TreeNode { param([string]$RunId, [string]$Id)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    foreach ($n in @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)) {
        if ([string]$n.id -eq $Id) { return $n }
    }
    return $null
}
function Get-NodeTask { param([string]$RunId, [string]$Id)
    $r = Invoke-Leaf @('-Command', 'status', '-RunId', $RunId, '-NodeId', $Id)
    if ($r.json.success -eq $true) { return [string]$r.json.data.node.task }
    return ''
}

# overview blocks (acceptance criteria carrier fixtures)
$Script:CriteriaBlock = "## 整体验收判据`n`n| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |`n|---|------|------|------|`n| 1 | 端到端跑通完整场景 | demo 实证 | 需求 1、2 |`n"

# New archive: overview + task docs + design docs (change-map carriers) + init via
# rdd-flow. TasksJson entries may carry "designMap" (verbatim design doc body) and
# "dep" (dependent task id).
function New-PcArchive { param([string]$Name, [string]$TasksJson, [string]$OverviewExtra = '')
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $archDir 'design') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nconflict 测试归档 $Name。`n`n$OverviewExtra"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        $doc = "requirements/t$i.md"
        $depLine = ''
        if ($line.dep) { $depLine = "- **依赖关系**：依赖需求 $($line.dep)`n" }
        Write-Utf8NoBom (Join-Path $archDir $doc) "# $Name 需求 $i`n`n- **描述**：conflict 测试需求 $i`n- **验收标准**：见 overview.md`n$depLine"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

# write the design docs the tasks reference (change-map carriers)
function Write-DesignDocs { param([string]$ArchiveRel, $TaskLines)
    $i = 1
    foreach ($line in ($TaskLines | ConvertFrom-Json)) {
        if ($line.designMap) {
            Write-Utf8NoBom (Join-Path $Work "$ArchiveRel/design/d$i.md") ([string]$line.designMap)
        }
        $i++
    }
}

# Minimal PlanFile writer (long-task-planning): one stage per given task set.
# CriteriaRef pins acceptance_point.criteria_ref (mandatory when the archive
# carries whole-requirement criteria; must stay omitted otherwise).
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
        summary = 'bridge-conflicts test delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
    }
    if ($Qualified) { $cb['extras'] = @{ verification = 'smoke ok' } }
    $cbFile = Join-Path $env:TEMP ("pc-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
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

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
# dead dsh URL: auto-push takes the dsh branch and fails instantly (no real session,
# no window) — push ATTEMPTS are recorded, held nodes never attempt.
$env:DSH_WEB_URL = 'http://127.0.0.1:1'
Push-Location $Work
try {
    # ================= T1: CONVENTIONS_MISSING + zero residue =================
    $mapA = "# pc-t1 设计 1`n`n## 需求概述`n`n独立设计 A。`n`n## 变更地图`n`nfixture-root/`n└── `app/core.py`   [修改] A 侧改动`n`n[新增] 0 | [修改] 1 | [删除] 0 | 无新增依赖`n"
    $tasks1 = '[{"title":"T1a","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]},{"title":"T1b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]}]'
    $arch1 = New-PcArchive 'pc-t1' $tasks1 $Script:CriteriaBlock
    Write-DesignDocs $arch1 $tasks1
    $pf1 = Write-TestPlan (Join-Path $Work 'pc-t1-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} -CriteriaRef 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1, '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CONVENTIONS_MISSING') 'T1 parallel DESIGN heads without conventions -> CONVENTIONS_MISSING' ($r.raw)
    Assert-True (-not (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-pc-t1'))) 'T1 zero run residue (nothing created)'

    # ================= T2: conventions injection =================
    $arch2 = New-PcArchive 'pc-t2' $tasks1 $Script:CriteriaBlock
    Write-DesignDocs $arch2 $tasks1
    Write-Utf8NoBom (Join-Path $Work 'pc-t2-conventions.md') "# 架构与风格约定`n`n- 约定 1：统一经 app/core.py 出入口，禁直改内部结构。`n- 约定 2：风格沿用项目现有基线。`n"
    $pf2 = Write-TestPlan (Join-Path $Work 'pc-t2-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} -CriteriaRef 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-PlanFile', $pf2, '-ConventionsFile', (Join-Path $Work 'pc-t2-conventions.md'), '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T2 promulgate ok with -ConventionsFile' ($r.raw)
    $b = Read-BridgeJson 'deliver-pc-t2'
    Assert-True ([string]$b.conventions.path -eq '.rdd/goal-trees/deliver-pc-t2/report/architecture-conventions.md') 'T2 bridge.conventions section recorded'
    $convTxt = Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-pc-t2/report/architecture-conventions.md') -Raw -Encoding UTF8
    Assert-True ($convTxt -match '约定 1') 'T2 report/architecture-conventions.md carrier written'
    $h2a = [string]$b.tasks.'1'.stages.CTO
    $task2 = Get-NodeTask 'deliver-pc-t2' $h2a
    Assert-True ($task2 -match '架构约定：\.rdd/goal-trees/deliver-pc-t2/report/architecture-conventions\.md') 'T2 DESIGN head node.task carries 架构约定 injection' $task2

    # ================= T3: single-design exemption =================
    $tasks3 = '[{"title":"T3","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $arch3 = New-PcArchive 'pc-t3' $tasks3
    $pf3 = Write-TestPlan (Join-Path $Work 'pc-t3-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-PlanFile', $pf3, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T3 single-design promulgate ok without conventions (exemption)' ($r.raw)

    # ================= T4: file-overlap auto-registration + hold =================
    $mapShared = "# 设计 — 变更地图机读契约样例`n`n## 需求概述`n`n改动同一批文件。`n`n## 变更地图`n`nfixture-root/`n├── ``app/core.py``   [修改] 共享核心`n└── ``app/models.py`` [新增] 本侧模型`n`n[新增] 1 | [修改] 1 | [删除] 0 | 无新增依赖`n"
    $tasks4 = ('[{"title":"T4a","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d1.md","status":"ready"}],"designMap":' + ($mapShared | ConvertTo-Json) + '},' +
               '{"title":"T4b","requirement":"requirements/t2.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d2.md","status":"ready"}],"designMap":' + ($mapShared | ConvertTo-Json) + '}]')
    $arch4 = New-PcArchive 'pc-t4' $tasks4 $Script:CriteriaBlock
    Write-DesignDocs $arch4 $tasks4
    $pf4 = Write-TestPlan (Join-Path $Work 'pc-t4-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} -CriteriaRef 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch4 + '/task.json'), '-PlanFile', $pf4)
    Assert-True ($r.json.success -eq $true) 'T4 promulgate ok (push happens behind the gate)' ($r.raw)
    $b = Read-BridgeJson 'deliver-pc-t4'
    $h4a = [string]$b.tasks.'1'.stages.DEV; $h4b = [string]$b.tasks.'2'.stages.DEV
    $conf4 = @($b.conflicts) | Where-Object { [string]$_.kind -eq 'file' } | Select-Object -First 1
    Assert-True ($null -ne $conf4 -and [string]$conf4.detected_by -eq 'change-map-scan') 'T4 overlap auto-registered as change-map-scan file conflict'
    Assert-True ($null -ne $conf4 -and (@($conf4.nodes) -contains $h4a) -and (@($conf4.nodes) -contains $h4b) -and (@($conf4.files) -contains 'app/core.py')) 'T4 conflict entry covers both nodes + the shared file'
    $pushedA = $b.pushes.PSObject.Properties[$h4a]; $pushedB = $b.pushes.PSObject.Properties[$h4b]
    Assert-True (($null -eq $pushedA) -and ($null -eq $pushedB)) 'T4 held nodes never attempted a push (push gate held both)'
    $mirrorPath = Join-Path $Work '.rdd/goal-trees/deliver-pc-t4/report/design-conflicts.md'
    $mirror = ''
    if (Test-Path -LiteralPath $mirrorPath) { $mirror = Get-Content -LiteralPath $mirrorPath -Raw -Encoding UTF8 }
    Assert-True ($mirror -match 'C1' -and $mirror -match '不得默默二选一') 'T4 human mirror report/design-conflicts.md written'
    # manual dispatch obeys the same gate
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-pc-t4', '-NodeId', $h4a, '-DryRun')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_HELD_BY_CONFLICT') 'T4 manual dispatch also held (no silent either-or)' ($r.raw)

    # ================= T5: resolve -Serialize -> dependency, release after settle =================
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t4', '-Action', 'resolve', '-ConflictId', ([string]$conf4.id), '-Ruling', '归属划分：app/core.py 改动归 T4a 先行落地', '-Serialize', $h4a)
    Assert-True ($r.json.success -eq $true) 'T5 resolve -Serialize ok' ($r.raw)
    $nb = Find-TreeNode 'deliver-pc-t4' $h4b
    Assert-True (@($nb.depends_on) -contains $h4a) 'T5 later node depends_on earlier (serialization edge)'
    $null = Do-Deliver 'deliver-pc-t4' $h4a 'DEV' "$arch4/requirements/t1.md"
    $r = Do-Settle 'deliver-pc-t4' $h4a
    Assert-True ($r.json.success -eq $true) 'T5 earlier node settles after resolve' ($r.raw)
    $attempted = @(@($r.json.data.auto_push.pushed) + @($r.json.data.auto_push.failed) | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.node } })
    Assert-True ($attempted -contains $h4b) 'T5 later node released (push attempt after earlier settled)' ($r.raw)

    # ================= T6: design-kind settle gate + escalation record =================
    $tasks6 = '[{"title":"T6","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $arch6 = New-PcArchive 'pc-t6' $tasks6
    $pf6 = Write-TestPlan (Join-Path $Work 'pc-t6-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6 + '/task.json'), '-PlanFile', $pf6, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T6 promulgate ok' ($r.raw)
    $b6 = Read-BridgeJson 'deliver-pc-t6'
    $h6 = [string]$b6.tasks.'1'.stages.DEV
    $null = Do-Deliver 'deliver-pc-t6' $h6 'DEV' "$arch6/requirements/t1.md"
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'open', '-ConflictKind', 'design', '-Nodes', $h6, '-Note', '架构互斥：两案语义不一致')
    Assert-True ($r.json.success -eq $true) 'T6 design conflict registered' ($r.raw)
    $r = Do-Settle 'deliver-pc-t6' $h6
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_HELD_BY_CONFLICT') 'T6 design-kind settle ALWAYS rejected (不得默默二选一)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'open', '-ConflictId', 'C1', '-ConflictStatus', 'escalated', '-Escalation', '两案取哪一案？')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.conflict.status -eq 'escalated') 'T6 escalation is a state attribute (open -> escalated)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'resolve', '-ConflictId', 'C1', '-Ruling', '用户裁决：取 A 案并同步 B 侧接口')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.conflict.status -eq 'resolved') 'T6 resolution records the ruling (append-only history)' ($r.raw)
    $b6 = Read-BridgeJson 'deliver-pc-t6'
    $c6 = @($b6.conflicts)[0]
    Assert-True ([string]$c6.escalation.question -eq '两案取哪一案？' -and [string]$c6.ruling.text -match '用户裁决' -and @($c6.history).Count -ge 3) 'T6 history keeps open -> escalated -> resolved (never rewritten)'
    $r = Do-Settle 'deliver-pc-t6' $h6
    Assert-True ($r.json.success -eq $true) 'T6 settle passes after resolution' ($r.raw)

    # ================= T8: registry errors =================
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'resolve', '-ConflictId', 'C9')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CONFLICT_NOT_FOUND') 'T8 unknown id -> CONFLICT_NOT_FOUND' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'resolve', '-ConflictId', 'C1', '-Ruling', 'x')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CONFLICT_ALREADY_RESOLVED') 'T8 double resolve -> CONFLICT_ALREADY_RESOLVED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'open', '-ConflictKind', 'file', '-Nodes', $h6)
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CONFLICT_ENTRY_INVALID') 'T8 kind=file without -Files -> CONFLICT_ENTRY_INVALID' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'open', '-ConflictKind', 'design', '-Nodes', $h6, '-Note', 'T8 open entry for error probing')
    Assert-True ($r.json.success -eq $true) 'T8 second entry registered (C2)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'resolve', '-ConflictId', 'C2')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CONFLICT_ENTRY_INVALID') 'T8 resolve without -Ruling/-Serialize -> CONFLICT_ENTRY_INVALID' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'open', '-ConflictId', 'C2')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CONFLICT_ENTRY_INVALID') 'T8 state-attribute update without -ConflictStatus -> CONFLICT_ENTRY_INVALID' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t6', '-Action', 'open', '-ConflictId', 'C2', '-ConflictStatus', 'suspended')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.conflict.status -eq 'suspended') 'T8 suspension is a state attribute too (open -> suspended)' ($r.raw)

    # ================= T7: file-kind settle split (dual-active block / single-active pass) =================
    $tasks7 = ('[{"title":"T7a","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d1.md","status":"ready"}],"designMap":' + ($mapShared | ConvertTo-Json) + '},' +
               '{"title":"T7b","requirement":"requirements/t2.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d2.md","status":"ready"}],"designMap":' + ($mapShared | ConvertTo-Json) + '}]')
    # T7a: single active writer passes (counterpart never started — first-landing = serialization premise)
    $arch7 = New-PcArchive 'pc-t7' $tasks7 $Script:CriteriaBlock
    Write-DesignDocs $arch7 $tasks7
    $pf7 = Write-TestPlan (Join-Path $Work 'pc-t7-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} -CriteriaRef 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-PlanFile', $pf7, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T7a promulgate ok (no push, manual registry)' ($r.raw)
    $b7 = Read-BridgeJson 'deliver-pc-t7'
    $h7a = [string]$b7.tasks.'1'.stages.DEV; $h7b = [string]$b7.tasks.'2'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t7', '-Action', 'open', '-ConflictKind', 'file', '-Nodes', ($h7a + ',' + $h7b), '-Files', 'app/core.py', '-Note', '重叠: app/core.py')
    Assert-True ($r.json.success -eq $true) 'T7a file conflict registered' ($r.raw)
    $null = Do-Deliver 'deliver-pc-t7' $h7a 'DEV' "$arch7/requirements/t1.md"
    $r = Do-Settle 'deliver-pc-t7' $h7a
    Assert-True ($r.json.success -eq $true) 'T7a single active writer passes settle (counterpart never started)' ($r.raw)

    # T7b: dual-active writers block each other (both claimed/reported)
    $arch7b = New-PcArchive 'pc-t7b' $tasks7 $Script:CriteriaBlock
    Write-DesignDocs $arch7b $tasks7
    $pf7b = Write-TestPlan (Join-Path $Work 'pc-t7b-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{} -CriteriaRef 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7b + '/task.json'), '-PlanFile', $pf7b, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T7b promulgate ok' ($r.raw)
    $b7b = Read-BridgeJson 'deliver-pc-t7b'
    $hb1 = [string]$b7b.tasks.'1'.stages.DEV; $hb2 = [string]$b7b.tasks.'2'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t7b', '-Action', 'open', '-ConflictKind', 'file', '-Nodes', ($hb1 + ',' + $hb2), '-Files', 'app/core.py', '-Note', '重叠: app/core.py')
    Assert-True ($r.json.success -eq $true) 'T7b file conflict registered' ($r.raw)
    $null = Do-Deliver 'deliver-pc-t7b' $hb1 'DEV' "$arch7b/requirements/t1.md"
    $null = Do-Deliver 'deliver-pc-t7b' $hb2 'DEV' "$arch7b/requirements/t2.md"
    $r = Do-Settle 'deliver-pc-t7b' $hb1
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_HELD_BY_CONFLICT') 'T7b active-vs-active settle blocked (no concurrent overwrite)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conflict', '-RunId', 'deliver-pc-t7b', '-Action', 'resolve', '-ConflictId', 'C1', '-Ruling', '串行化消解：T7b-a 先行落地，T7b-b 其后', '-Serialize', $hb1)
    Assert-True ($r.json.success -eq $true) 'T7b resolve -Serialize ok' ($r.raw)
    $r = Do-Settle 'deliver-pc-t7b' $hb1
    Assert-True ($r.json.success -eq $true) 'T7b settle passes after resolve (merges never overwrite)' ($r.raw)

    # ================= T9: legacy change-map degrade + T10: citation soft-check =================
    $legacyMap = "# 设计 — 旧格式变更地图`n`n## 需求概述`n`n存量格式。`n`n## 变更地图`n`nproject/`n└── app/models.py [修改] 字段扩展`n`n[新增] 0 | [修改] 1 | [删除] 0 | 无新增依赖`n"
    $newMap = "# 设计 — 变更地图`n`n## 需求概述`n`n正常格式。`n`n## 变更地图`n`nfixture-root/`n└── ``app/core.py``   [修改] 核心改动`n`n[新增] 0 | [修改] 1 | [删除] 0 | 无新增依赖`n"
    $tasks9 = ('[{"title":"T9","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d1.md","status":"ready"}],"designMap":' + ($legacyMap | ConvertTo-Json) + '}]')
    $arch9 = New-PcArchive 'pc-t9' $tasks9
    Write-DesignDocs $arch9 $tasks9
    $pf9 = Write-TestPlan (Join-Path $Work 'pc-t9-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch9 + '/task.json'), '-PlanFile', $pf9, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T9 legacy change map NEVER blocks the flow' ($r.raw)
    $b9 = Read-BridgeJson 'deliver-pc-t9'
    $dm9 = $b9.design_maps.PSObject.Properties['design/d1.md']
    $warn9 = ''
    if ($null -ne $dm9) { $warn9 = (@($dm9.Value.warnings) -join ';') }
    Assert-True ($null -ne $dm9 -and [bool]$dm9.Value.legacy -and $warn9 -match 'DESIGN_MAP_INVALID') 'T9 legacy map degraded with explicit DESIGN_MAP_INVALID warning' $warn9

    $tasks10 = ('[{"title":"T10","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d1.md","status":"ready"}],"designMap":' + ($newMap | ConvertTo-Json) + '}]')
    $arch10 = New-PcArchive 'pc-t10' $tasks10
    Write-DesignDocs $arch10 $tasks10
    Write-Utf8NoBom (Join-Path $Work 'other.py') "# 引用一致性软核对夹具`n"
    $pf10 = Write-TestPlan (Join-Path $Work 'pc-t10-plan.json') @(@{ id = 'S1'; tasks = @(1) }) @{}
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch10 + '/task.json'), '-PlanFile', $pf10, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'T10 promulgate ok' ($r.raw)
    $b10 = Read-BridgeJson 'deliver-pc-t10'
    $h10 = [string]$b10.tasks.'1'.stages.DEV
    $null = Do-Deliver 'deliver-pc-t10' $h10 'DEV' 'other.py'
    $r = Do-Settle 'deliver-pc-t10' $h10
    Assert-True ($r.json.success -eq $true) 'T10 citation deviation NEVER hard-rejects (soft check)' ($r.raw)
    $devWarn = ''
    foreach ($w in @($r.json.data.warnings)) { $devWarn += "$w;" }
    Assert-True ($devWarn -match '回执一致性软核对|回执偏差') 'T10 deviation surfaces as a warning in settle output' $devWarn
    $b10 = Read-BridgeJson 'deliver-pc-t10'
    $dev10 = $b10.design_maps.PSObject.Properties['design/d1.md'].Value.citation_deviations
    Assert-True (@($dev10).Count -ge 1 -and @(@($dev10)[0].refs) -contains 'other.py') 'T10 design_maps[].citation_deviations recorded'
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-pc-t10')
    $statWarn = (@($r.json.data.warnings) -join ';')
    Assert-True ($r.json.success -eq $true -and $statWarn -match '回执偏差') 'T10 status view keeps surfacing the deviation' $statWarn

    # ================= T11: open conflict never blocks non-overlapping tasks =================
    $soloMap = "# 设计 — 变更地图(独立侧)`n`n## 需求概述`n`n独立文件改动。`n`n## 变更地图`n`nfixture-root/`n└── ``app/reports.py``   [新增] 独立模块`n`n[新增] 1 | [修改] 0 | [删除] 0 | 无新增依赖`n"
    $tasks11 = ('[{"title":"T11a","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d1.md","status":"ready"}],"designMap":' + ($mapShared | ConvertTo-Json) + '},' +
                '{"title":"T11b","requirement":"requirements/t2.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d2.md","status":"ready"}],"designMap":' + ($mapShared | ConvertTo-Json) + '},' +
                '{"title":"T11c","requirement":"requirements/t3.md","currentOwners":["DEV"],"designDocs":[{"path":"design/d3.md","status":"ready"}],"designMap":' + ($soloMap | ConvertTo-Json) + '}]')
    $arch11 = New-PcArchive 'pc-t11' $tasks11 $Script:CriteriaBlock
    Write-DesignDocs $arch11 $tasks11
    $pf11 = Write-TestPlan (Join-Path $Work 'pc-t11-plan.json') @(@{ id = 'S1'; tasks = @(1, 2, 3) }) @{} -CriteriaRef 'requirements/overview.md#整体验收判据'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch11 + '/task.json'), '-PlanFile', $pf11)
    Assert-True ($r.json.success -eq $true) 'T11 promulgate ok (overlapping pair + one solo task)' ($r.raw)
    $b11 = Read-BridgeJson 'deliver-pc-t11'
    $h11a = [string]$b11.tasks.'1'.stages.DEV; $h11b = [string]$b11.tasks.'2'.stages.DEV; $h11c = [string]$b11.tasks.'3'.stages.DEV
    $conf11 = @($b11.conflicts) | Where-Object { [string]$_.kind -eq 'file' } | Select-Object -First 1
    Assert-True ($null -ne $conf11 -and (@($conf11.nodes) -contains $h11a) -and (@($conf11.nodes) -contains $h11b) -and (-not (@($conf11.nodes) -contains $h11c))) 'T11 conflict covers only the overlapping pair (solo node untouched)'
    Assert-True (($null -eq $b11.pushes.PSObject.Properties[$h11a]) -and ($null -eq $b11.pushes.PSObject.Properties[$h11b])) 'T11 overlapped heads held (no push attempt)'
    Assert-True ($null -ne $b11.pushes.PSObject.Properties[$h11c]) 'T11 non-overlapping task keeps pushing (open conflict never blocks it)'
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-pc-t11', '-NodeId', $h11c, '-DryRun')
    Assert-True (-not ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_HELD_BY_CONFLICT')) 'T11 solo node dispatch not held by the conflict gate' ($r.raw)
}
finally {
    Pop-Location
    $env:DSH_WEB_URL = $null
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ("--- {0} passed / {1} failed / {2} total ---" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count, $Results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

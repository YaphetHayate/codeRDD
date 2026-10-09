# derive-review-integration.ps1 — DEV 集成/联调探针
# run：deliver-2026-10-07-planner-midrun-derive 节点 n8（[集成/联调]）
#
# 使命（不是各模块独立跑通子验收，而是真实串联）：
#   在同一 run 内把两条机制的数据/调用链首尾相接跑一遍——
#     需求 1「planner mid-run 需求派生（derive）」：propose → 用户确认硬门 →
#       PM graft → 受控入册（桥代写 add-task + bridge.tasks 登记）→ replan 吸收
#       → 结案硬门/annex 留痕
#     需求 2「AUDITOR 评审子代理化」：review_mode=subagent 纯契约链 → ready
#       （零 [设计审查] 节点）→ 契约定裁定入库 → IMPL 闸门放行
#   重点在**缝**：派生 graft 是否扰动在审阶段、派生并入新阶段/同阶段两种形态对
#   审查态的影响、两本账（归档级决策账本 / 审视账本）分工、审查契约门与派生入
#   册的写入方契约、引擎写盘 ↔ dsh 插件产物读回、结案三联（派生清单 / 整体验收
#   结论 / 任务终态）。
#
# 三组夹具：
#   Run A  mi-a（主链，双阶段）：S1=主任务，run 中途派生并入**新阶段** S2；
#          两阶段各自一次子代理设计审查；跑完后走整体验收链结案。
#   Run B  mi-b（同阶段吸收的失效面）：派生并入**在审的同一阶段**时 replan 的
#          审查失效波与互锁形态——实测记录，不放水。
#   Real   真实仓：本 run 自身的 bridge/tree（引擎写）↔ 插件产物 aggregateGoalTrees
#          （插件读）逐字段对账 + 真仓归档级账本可读（零写入）。
#
# 运行：powershell -File .rdd/tests/delivery-bridge/derive-review-integration.ps1
# 退出码 0 = 全绿。
#
# 分工纪律（沙箱）：PS 驱动真引擎 CLI 写盘，node 只读 FS（integration-plugin-view.mjs）。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$EngineDir = Join-Path $RepoRoot 'rdd-engine/scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$PluginDrv = Join-Path $PSScriptRoot 'integration-plugin-view.mjs'
$Work      = Join-Path $env:TEMP ('derive-review-integration-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Read-JsonFile { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Read-Jsonl { param([string]$Path)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    foreach ($line in @([System.IO.File]::ReadAllLines($Path))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $out += ($line | ConvertFrom-Json) } catch { }
    }
    return @($out)
}

function Get-RunPath { param([string]$RunId) Join-Path $Work ('.rdd/goal-trees/' + $RunId) }
function Read-BridgeJson { param([string]$RunId) Read-JsonFile (Join-Path (Get-RunPath $RunId) 'bridge.json') }
function Read-TreeNodes { param([string]$RunId)
    $t = Read-JsonFile (Join-Path (Get-RunPath $RunId) 'state/tree.json')
    if ($null -eq $t) { return @() }
    return @($t.nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Read-PlanLog { param([string]$RunId) Read-Jsonl (Join-Path (Get-RunPath $RunId) 'plan-log.jsonl') }
function Count-PlanEvent { param([string]$RunId, [string]$Event)
    $c = 0
    foreach ($e in @(Read-PlanLog $RunId)) { if ([string]$e.event -eq $Event) { $c++ } }
    return $c
}
function Read-Ledger { param([string]$ArchiveRel) Read-Jsonl (Join-Path $Work ($ArchiveRel + '/decisions.jsonl')) }
function Read-ReviewLedger { Read-Jsonl (Join-Path $Work '.rdd/review-ledger.jsonl') }
function Read-ArchiveTasks { param([string]$ArchiveRel)
    $t = Read-JsonFile (Join-Path $Work ($ArchiveRel + '/task.json'))
    if ($null -eq $t) { return @() }
    return @($t.tasks)
}
function Get-Task { param([string]$ArchiveRel, [int]$Id)
    foreach ($t in (Read-ArchiveTasks $ArchiveRel)) { if ([int]$t.id -eq $Id) { return $t } }
    return $null
}
function Get-Der { param($Bridge, [string]$Id)
    foreach ($d in @($Bridge.derivations)) { if ([string]$d.id -eq $Id) { return $d } }
    return $null
}
function Get-LedgerEntry { param([string]$ArchiveRel, [string]$Kind)
    return @(Read-Ledger $ArchiveRel | Where-Object { [string]$_.kind -eq $Kind })[0]
}
function Count-LedgerKind { param([string]$ArchiveRel, [string]$Kind)
    $c = 0
    foreach ($e in @(Read-Ledger $ArchiveRel)) { if ([string]$e.kind -eq $Kind) { $c++ } }
    return $c
}
function Get-PluginView { param([string]$Root, [string]$RunId = '')
    $a = @($PluginDrv, $Root)
    if ($RunId) { $a += $RunId }
    $out = & node @a 2>&1 | Out-String
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}

$Script:AcceptanceBlock = @"
## 整体验收判据

| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |
|---|------------------|-----------|-----------|
| 1 | 主需求与中途派生需求在同一 run 内串联跑完 | 集成探针机械实证 | 主需求 |
"@

function New-Archive { param([string]$Name, [string]$TasksJson, [string]$Criteria = '')
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    $ov = "# $Name`n`n集成/联调探针夹具归档 $Name。`n`n"
    if ($Criteria) { $ov += $Criteria + "`n" }
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') $ov
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir "requirements/t$i.md") "# $Name 需求 $i`n`n- **描述**：集成探针夹具需求 $i`n- **验收标准**：见 overview.md`n"
        foreach ($d in @($line.designDocs)) {
            if ($d -and $d.path) {
                $dAbs = Join-Path $archDir ([string]$d.path)
                $dDir = Split-Path $dAbs -Parent
                if (-not (Test-Path $dDir)) { New-Item -ItemType Directory -Path $dDir -Force | Out-Null }
                Write-Utf8NoBom $dAbs ("# 设计文档 $i`n`n变更地图：`n`n- ``src/mod-$i.py``  [新增] 模块 $i`n`n[新增] 1 | [修改] 0 | [删除] 0`n")
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

function New-PlanFile { param([string]$Path, $StageSpecs, [string]$CriteriaRef = 'requirements/overview.md#整体验收判据')
    $objs = @()
    foreach ($s in $StageSpecs) {
        $ids = @($s['tasks'] | ForEach-Object { [int]$_ } | Sort-Object)
        $batches = @(, $ids)
        if ($s.Contains('batches') -and $s['batches']) { $batches = @($s['batches']) }
        $ap = [ordered]@{ criteria_items = @('集成：两机制串联真实跑通'); slice = 'runnable single-command slice' }
        if ($CriteriaRef) { $ap['criteria_ref'] = $CriteriaRef }
        $objs += , [ordered]@{
            id = [string]$s['id']; goal = "stage $($s['id']) 目标"; milestone = "stage $($s['id']) 里程碑"
            task_ids = $ids; batches = $batches; acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-07T00:00:00Z'; planner = 'test'; stages = $objs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 12)
    return $Path
}

function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'derive x design-review integration probe delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'probe fixture: settle evidence ok'; quality_scan = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } }
    }
    $cbFile = Join-Path $env:TEMP ("dri-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 6)
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
    return (Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId))
}
function Do-AfterClaim { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    # 节点已被显式 claim（claim 本身是被测断言）：只补报交 + settle
    $cb = New-Cb $NodeId $Refs
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return (Do-Settle $RunId $NodeId)
}
function Do-Node { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $null = Do-Deliver $RunId $NodeId $Role $Refs
    return (Do-Settle $RunId $NodeId)
}

function Write-ReviewFile { param([string]$ArchiveRel, [string]$StageId, [string[]]$DocRels, [string]$Verdict,
    [string]$Reviewer = 'auditor-delegated', [bool]$WithProduction = $true, [string]$ProductionMode = 'subagent')
    $archAbs = Join-Path $Work $ArchiveRel
    $docs = @()
    foreach ($rel in @($DocRels)) {
        $findings = @()
        if ($Verdict -eq 'fail') { $findings += @{ severity = 'blocking'; dimension = 'change_map'; item = "blocking on $rel"; suggestion = '修正后重产' } }
        $findings += @{ severity = 'advisory'; dimension = 'completeness'; item = "advisory on $rel"; suggestion = '补强说明' }
        $docs += @{ doc = $rel; verdict = $Verdict; findings = $findings }
    }
    $file = [ordered]@{
        reviewed_at = '2026-10-07T09:00:00Z'; reviewer = $Reviewer; stage = $StageId
        docs = $docs; summary = @{ cross_design = @() }
    }
    if ($WithProduction) { $file['production'] = @{ mode = $ProductionMode; template = 'rdd-engine/references/review-input-template.md' } }
    $rel = "review/design-review-$StageId.json"
    $abs = Join-Path $archAbs ($rel -replace '/', '\')
    $dir = Split-Path $abs -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 8)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# 设计汇聚审查 — $ArchiveRel·$StageId`n`n镜像。`n"
    return $rel
}

# ============ I0 前置：引擎脚本 BOM 完整性（本仓约定：中文 .ps1 必须 UTF-8 with BOM） ============
# 编辑工具会抹掉 BOM，而 PS 5.1 按 ANSI 解码 → 整脚本解析失败，错误还出现在毫不相关的
# 行上（本探针实测踩过：断言全假红的根因不在被测行为）。先 fail loud。
foreach ($f in @($BridgePs1, $FlowPs1)) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ("I0 {0} carries UTF-8 BOM (engine must stay parseable by PS 5.1)" -f (Split-Path $f -Leaf)) ("got {0},{1},{2} -- restore the BOM before running the probe" -f $bytes[0], $bytes[1], $bytes[2])
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
# 死端口：auto-push 即刻失败（无真实会话创建），闸门 hold 的节点不尝试推送
$env:DSH_WEB_URL = 'http://127.0.0.1:1'
Push-Location $Work
try {

# =====================================================================
# Run A — 单 run 双机制串联主链（mi-a / deliver-mi-a）
# =====================================================================
try {

# ============ I1 颁布：双机制配置同源落桥 ============
$tasksA = '[{"title":"主需求","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
$archA = New-Archive 'mi-a' $tasksA $Script:AcceptanceBlock
$runA = 'deliver-mi-a'
$pfA = New-PlanFile (Join-Path $Work 'mi-a-plan.json') @(@{ id = 'S1'; tasks = @(1) })
# 预算余量：预期会中途派生的 run 颁布时预留（planner-guide 指引；本 run 自身 2 任务用了
# -MaxNodes 40/-NodeWidth 8）。Run C 专门测「不预留」的后果。
$r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archA + '/task.json'), '-PlanFile', $pfA, '-ReviewMode', 'subagent', '-AutoMode', '-MaxNodes', '30', '-NodeWidth', '8', '-NoPush')
Assert-True ($r.json.success -eq $true) 'I1 promulgate ok (-ReviewMode subagent -AutoMode -NoPush, budget reserved)' ($r.raw)
$a1 = Read-BridgeJson $runA
Assert-True ([string]$a1.review_mode -eq 'subagent') 'I1 review_mode=subagent persisted in bridge.json' ($a1.tasks | ConvertTo-Json -Depth 4)
Assert-True ([string]$a1.plan.stages[0].design_review.status -eq 'planned') 'I1 design_review slot lands planned (new chain, unconditional)' ($a1.plan.stages[0].design_review | ConvertTo-Json -Depth 4)
Assert-True ([string]$a1.acceptance.status -eq 'planned' -and [string]$a1.acceptance.basis -eq 'criteria' -and [string]$a1.acceptance.criteria_ref -eq 'requirements/overview.md#整体验收判据') 'I1 acceptance planned on criteria basis (whole-requirement chain will graft)' ($a1.acceptance | ConvertTo-Json -Depth 4)
Assert-True ([string]$a1.archive_rel -eq '.rdd/changes/archive/mi-a') 'I1 archive_rel recorded (plugin-side archive resolution anchor)' ([string]$a1.archive_rel)
Assert-True ([int]$r.json.data.budget.node_width -eq 8 -and [int]$r.json.data.budget.max_nodes -eq 30) 'I1 reserved budget honoured (new chain adds no +K: width 8 / nodes 30 as requested)' ($r.raw)
$cto1 = [string]$a1.tasks.'1'.stages.CTO
Assert-True (-not [string]::IsNullOrWhiteSpace($cto1)) 'I1 CTO chain head grafted at promulgate' ($a1.tasks.'1'.stages | ConvertTo-Json -Depth 4)

# ============ I2 CTO 交付 → 子代理审查 ready（零节点）+ IMPL 闸门 + 派审面 ============
$null = Do-Deliver $runA $cto1 'CTO' @("$archA/design/d1.md")
$r = Do-Settle $runA $cto1
Assert-True ($r.json.success -eq $true) 'I2 CTO settle ok' ($r.raw)
$a2 = Read-BridgeJson $runA
$drS1 = $a2.plan.stages[0].design_review
Assert-True ([string]$drS1.status -eq 'ready' -and $null -eq $drS1.node) 'I2 [SEAM] all-past-DESIGN -> ready with NO review node (pure contract chain)' ($drS1 | ConvertTo-Json -Depth 4)
Assert-True (@(Read-TreeNodes $runA | Where-Object { [string]$_.title -like '*设计审查*' }).Count -eq 0) 'I2 zero [设计审查] nodes in the tree (独立会话形态已消除)' ((Read-TreeNodes $runA | ForEach-Object { [string]$_.title }) -join ' | ')
Assert-True ((Count-PlanEvent $runA 'design_review_ready') -ge 1) 'I2 plan-log design_review_ready recorded' ((Read-PlanLog $runA | ForEach-Object { [string]$_.event }) -join ',')
$dev1 = [string]$a2.tasks.'1'.stages.DEV
$r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runA, '-NodeId', $dev1, '-Role', 'DEV')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'I2 IMPL hard-gated while the review is open (no force bypass)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', $runA)
$st1 = @($r.json.data.stages | Where-Object { [string]$_.stage -eq 'S1' })[0]
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.chain -eq 'contract (submit)' -and [string]$r.json.data.review_mode -eq 'subagent') 'I2 dispatch face: chain=contract(submit), mode=subagent' ($r.raw)
Assert-True ($null -ne $st1 -and [string]$st1.status -eq 'ready' -and @($st1.docs) -contains 'design/d1.md') 'I2 dispatch face carries the mechanical docs list (零转述填充面)' ($r.raw)
Assert-True ([string]$st1.template -eq 'rdd-engine/references/review-input-template.md' -and [string]$st1.report -eq 'review/design-review-S1.json' -and [string]$st1.production.mode -eq 'subagent') 'I2 dispatch face carries template/report/production constants' ($r.raw)
$tmplRaw = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'rdd-engine/references/review-input-template.md'), [System.Text.Encoding]::UTF8)
$tmplSub = [bool]($tmplRaw -match '\| `REVIEWER_SUBAGENT` \| `auditor-delegated` \|')
$tmplSes = [bool]($tmplRaw -match '\| `REVIEWER_SESSION` \| `auditor` \|')
$enumOk = (@($r.json.data.reviewers) -contains 'auditor-delegated') -and (@($r.json.data.reviewers) -contains 'auditor')
Assert-True ($tmplSub -and $tmplSes -and $enumOk) 'I2 [SEAM] reviewer enum single source: template const table == engine live value domain' ("template=$tmplSub/$tmplSes engine=$(@($r.json.data.reviewers) -join ',')")

# ============ I3 run 中途派生：propose（零副作用）→ 确认硬门 → confirm 落地 ============
# Run A 起就是 AutoMode 纯自动模式：升级通道与派生并入同 run 共存（同一本账）
$r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runA, '-Action', 'propose', '-Title', '派生：导出能力补齐', '-Rationale', '主链 DEV 实现期发现不补导出能力根目标无法达成', '-DependsOn', '1')
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'proposed') 'I3 [SEAM] derive propose runs mid-run while a design review is ready' ($r.raw)
$a3 = Read-BridgeJson $runA
$d1 = Get-Der $a3 'DRV1'
Assert-True ($null -ne $d1 -and [string]$d1.status -eq 'proposed' -and $null -eq $d1.node -and [string]$d1.proposed_entry -ne '') 'I3 bridge derivations[] proposed (ledger entry referenced, not copied)' ($d1 | ConvertTo-Json -Depth 4)
Assert-True ([string](Read-BridgeJson $runA).plan.stages[0].design_review.status -eq 'ready') 'I3 [SEAM] propose leaves the open design review untouched (zero side effect)' ((Read-BridgeJson $runA).plan.stages[0].design_review | ConvertTo-Json -Depth 4)
$prop = Get-LedgerEntry $archA 'derive_proposal'
Assert-True ($null -ne $prop -and [string]$prop.decider -eq 'planner' -and [string]$prop.derivation_id -eq 'DRV1') 'I3 archive-level ledger holds the derive_proposal (decider=planner)' ($prop | ConvertTo-Json -Depth 4)
Assert-True ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.background) -and @($prop.options).Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$prop.decision) -and -not [string]::IsNullOrWhiteSpace([string]$prop.reason)) 'I3 ledger four-element schema complete (background/options/decision/reason)' ($prop | ConvertTo-Json -Depth 4)
$ledBefore = (@(Read-Ledger $archA)).Count
$r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runA, '-Action', 'confirm', '-DerivationId', 'DRV1')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DERIVE_CONFIRMATION_MISSING') 'I3 confirm without -UserVerdict -> DERIVE_CONFIRMATION_MISSING (hard gate)' ($r.raw)
$a3b = Read-BridgeJson $runA
Assert-True ((Get-Der $a3b 'DRV1').status -eq 'proposed' -and (@(Read-Ledger $archA)).Count -eq $ledBefore) 'I3 refused confirm is a true no-op (state + ledger unchanged)' ("status=$((Get-Der $a3b 'DRV1').status) ledger=$((@(Read-Ledger $archA)).Count)/$ledBefore")
$verdict = '同意派生，并入当前 run（用户拍板口径 a）'
$r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runA, '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', $verdict)
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'confirmed') 'I3 confirm with the verbatim user verdict -> confirmed' ($r.raw)
$a4 = Read-BridgeJson $runA
$d1 = Get-Der $a4 'DRV1'
$rul = Get-LedgerEntry $archA 'ruling'
Assert-True ($null -ne $rul -and [string]$rul.decider -eq 'user' -and [string]$rul.ref_entry -eq [string]$prop.entry_id) 'I3 ruling entry (decider=user, ref_entry -> proposal) is the confirmation record' ($rul | ConvertTo-Json -Depth 4)
Assert-True ($null -ne $rul -and ([string]$rul.decision).Trim() -eq $verdict) 'I3 user verdict stored VERBATIM (no paraphrase)' ([string]$rul.decision)
Assert-True ([string]$d1.status -eq 'confirmed' -and $null -ne $d1.node -and [string]$d1.confirm_entry -eq [string]$rul.entry_id) 'I3 derivation confirmed + PM node grafted, ledger entry referenced' ($d1 | ConvertTo-Json -Depth 4)
$pmNode = [string]$d1.node
$pmTree = Find-TreeNode $runA $pmNode
Assert-True ($null -ne $pmTree -and [string]$pmTree.parent -eq [string]$a4.goal_root -and [string]$pmTree.role -eq 'pm') 'I3 PM node is a goal-root child (in-run ingestion, not a chain run)' ($pmTree | ConvertTo-Json -Depth 4)
Assert-True ((Count-PlanEvent $runA 'scope_derived') -eq 1) 'I3 plan-log deviation/scope_derived recorded' ((Read-PlanLog $runA | ForEach-Object { [string]$_.kind + ':' + [string]$_.event }) -join ',')
$a4b = Read-BridgeJson $runA
Assert-True ([string]$a4b.plan.stages[0].design_review.status -eq 'ready') 'I3 [SEAM] graft of the PM node does not disturb the open review state' ($a4b.plan.stages[0].design_review | ConvertTo-Json -Depth 4)

# ============ I4 PM 交付 → 受控入册（桥代写 add-task + bridge.tasks 登记） ============
Write-Utf8NoBom (Join-Path $Work "$archA/requirements/dr1.md") "# 派生需求：导出能力补齐`n`n- **描述**：主链实现期发现的导出能力缺口`n- **验收标准**：导出可实证`n"
$ovNew = "# mi-a`n`n集成/联调探针夹具归档 mi-a。`n`n" + $Script:AcceptanceBlock + "| 2 | 派生需求导出能力补齐随同跑通 | 集成探针 mechanical | 派生 DRV1 |`n"
Write-Utf8NoBom (Join-Path $Work "$archA/requirements/overview.md") $ovNew
$null = Do-Deliver $runA $pmNode 'PM' @("$archA/requirements/dr1.md", "$archA/requirements/overview.md")
$r = Do-Settle $runA $pmNode
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -match 'derivation registered') 'I4 PM settle -> controlled registration (bridge-issued add-task)' ($r.raw)
$t2 = Get-Task $archA 2
Assert-True ($null -ne $t2 -and [string]$t2.phase -eq 'DESIGN' -and @($t2.currentOwners) -contains 'CTO' -and [string]$t2.requirement -eq 'requirements/dr1.md') 'I4 task.json #2 created (phase=DESIGN, requirement doc anchored)' ($t2 | ConvertTo-Json -Depth 4)
Assert-True ($null -ne $t2 -and [string]$t2.remark -match 'derivation=DRV1') 'I4 remark idempotency anchor written by the bridge' ([string]$t2.remark)
$r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archA, '-Title', '绕行任务', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_REQUIRED') 'I4 [SEAM] manual add-task stays gated while the run is active (bridge write is the only legitimate path)' ($r.raw)
$a5 = Read-BridgeJson $runA
$d1 = Get-Der $a5 'DRV1'
Assert-True ([string]$d1.status -eq 'registered' -and [int]$d1.task_id -eq 2 -and [string]$d1.requirement -eq 'requirements/dr1.md') 'I4 derivation registered (task #2 + requirement doc)' ($d1 | ConvertTo-Json -Depth 4)
Assert-True ([string]$a5.tasks.'2'.stages.CTO -ne '' -and [string]$a5.tasks.'2'.stages.UX -ne '' -and [string]$a5.tasks.'2'.stages.QA -ne '') 'I4 DESIGN chain heads grafted for the derived task' ($a5.tasks.'2'.stages | ConvertTo-Json -Depth 4)
Assert-True ((Count-PlanEvent $runA 'derivation_registered') -eq 1) 'I4 plan-log derivation_registered recorded' ((Read-PlanLog $runA | ForEach-Object { [string]$_.event }) -join ',')
$a5o = Read-BridgeJson $runA
Assert-True ([string]$a5o.acceptance.status -eq 'planned' -and [string]$a5o.acceptance.basis -eq 'criteria') 'I4 derived criteria stay gated by the live acceptance section' ($a5o.acceptance | ConvertTo-Json -Depth 4)
$cto2 = [string]$a5o.tasks.'2'.stages.CTO
$r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', $runA, '-NodeId', $cto2, '-DryRun')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_GATE' -and [string]$r.json.error.message -match 'replan') 'I4 unabsorbed derived chain head held (NODE_BLOCKED_BY_GATE, replan is the only exit)' ($r.raw)

# ============ I5 replan 吸收（并入新阶段 S2）→ 既有阶段审查态承载不变 ============
$pfA2 = New-PlanFile (Join-Path $Work 'mi-a-plan2.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) })
$r = Invoke-Bridge @('-Command', 'replan', '-RunId', $runA, '-PlanFile', $pfA2, '-Reason', '吸收 run 中途派生需求（并入新阶段 S2）')
Assert-True ($r.json.success -eq $true -and @($r.json.data.derivations_absorbed) -match 'DRV1') 'I5 replan absorbs the derivation (absorbed marker)' ($r.raw)
$a6 = Read-BridgeJson $runA
Assert-True ((Get-Der $a6 'DRV1').absorbed -eq $true) 'I5 bridge derivations[DRV1].absorbed=true' ((Get-Der $a6 'DRV1') | ConvertTo-Json -Depth 4)
Assert-True ($null -ne $a6.plan.stages[1].design_review -and [string]$a6.plan.stages[1].design_review.status -eq 'planned') 'I5 [SEAM] the derived stage S2 lands its OWN review slot (planned) — 派生并入的新阶段同样受边界审查' ($a6.plan.stages[1].design_review | ConvertTo-Json -Depth 4)
Assert-True ([string]$a6.plan.stages[0].design_review.status -eq 'ready') 'I5 [SEAM] S1 content unchanged -> its open review state rides the replan (no spurious invalidation)' ($a6.plan.stages[0].design_review | ConvertTo-Json -Depth 4)
Assert-True ((Count-PlanEvent $runA 'design_review_invalidated') -eq 0) 'I5 no invalidation event fired (each stage kept its own review slot)' ((Read-PlanLog $runA | ForEach-Object { [string]$_.event }) -join ',')
Assert-True ((Count-PlanEvent $runA 'design_review_slot_staged') -eq 1) 'I5 plan-log design_review_slot_staged recorded for the new stage' ((Read-PlanLog $runA | ForEach-Object { [string]$_.event + ':' + [string]$_.stage }) -join ',')
$r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', $runA, '-NodeId', $cto2, '-DryRun')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_GATE' -and [string]$r.json.error.message -match 'acceptance point') 'I5 [SEAM] gate layering: absorption releases the derive gate, the PREVIOUS stage acceptance point now owns the hold' ($r.raw)

# ============ I6 S1 审查契约入库（submit）→ 主任务链跑完 ============
Write-ReviewFile $archA 'S1' @('design/d1.md') 'pass' | Out-Null
$r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', $runA, '-Stage', 'S1')
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass' -and [string]$r.json.data.reviewer -eq 'auditor-delegated') 'I6 submit pass (engine-derived verdict, reviewer=auditor-delegated)' ($r.raw)
$a7 = Read-BridgeJson $runA
Assert-True ([string]$a7.plan.stages[0].design_review.status -eq 'passed' -and [string]$a7.plan.stages[0].design_review.verdict -eq 'pass') 'I6 S1 review passed recorded in bridge' ($a7.plan.stages[0].design_review | ConvertTo-Json -Depth 4)
$r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runA, '-NodeId', $dev1, '-Role', 'DEV')
Assert-True ($r.json.success -eq $true) 'I6 IMPL unblocked by the contract submit (auto-unlock at the next trigger point)' ($r.raw)
$revLed = @(Read-ReviewLedger | Where-Object { [string]$_.run_id -eq $runA -and [string]$_.kind -eq 'design_review' })
Assert-True ($revLed.Count -ge 1 -and [string]$revLed[0].reviewer -eq 'auditor-delegated') 'I6 [SEAM] review ledger signed auditor-delegated (审视账本 = reviewer 署名面)' (($revLed | ConvertTo-Json -Depth 4 -Compress))
Assert-True ((Count-LedgerKind $archA 'design_review') -eq 0) 'I6 [SEAM] two ledgers stay separate: no review entries leak into the archive decision ledger' ((@(Read-Ledger $archA | ForEach-Object { [string]$_.kind }) -join ','))
$null = Do-AfterClaim $runA $dev1 'DEV' @("$archA/requirements/t1.md")
$a8 = Read-BridgeJson $runA
$qa1 = [string]$a8.tasks.'1'.stages.QA
Assert-True ($qa1 -ne '') 'I6 VERIFY head grafted after IMPL settled' ($a8.tasks.'1'.stages | ConvertTo-Json -Depth 4)
$null = Do-Deliver $runA $qa1 'QA' @("$archA/requirements/t1.md")
$r = Do-Settle $runA $qa1
Assert-True ($r.json.success -eq $true) 'I6 task #1 VERIFY settled' ($r.raw)
Assert-True ([string](Get-Task $archA 1).lifecycle -eq 'completed') 'I6 task #1 terminal' ((Get-Task $archA 1) | ConvertTo-Json -Depth 4)

# ============ I7 阶段验收点放行 → 派生任务链（S2 子代理审查）+ 跨组件账本读写 ============
$r = Invoke-Bridge @('-Command', 'status', '-RunId', $runA)
$a7b = Read-BridgeJson $runA
$saNodeA = [string]$a7b.plan.stages[0].acceptance_point.node
Assert-True ([string]$a7b.plan.stages[0].acceptance_point.status -eq 'grafted' -and $saNodeA -ne '') 'I7 S1 tasks terminal -> its own [集成验收·S1] node grafts (non-final stage)' ($a7b.plan.stages[0].acceptance_point | ConvertTo-Json -Depth 4)
$null = Do-Deliver $runA $saNodeA 'QA' @("$archA/requirements/overview.md")
$r = Do-Settle $runA $saNodeA
Assert-True ($r.json.success -eq $true) 'I7 [集成验收·S1] settled' ($r.raw)
$r = Invoke-Bridge @('-Command', 'status', '-RunId', $runA)
Assert-True ([string](Read-BridgeJson $runA).plan.stages[0].acceptance_point.status -eq 'passed') 'I7 S1 acceptance point passed (stage gate opens for S2)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runA, '-NodeId', $cto2, '-Role', 'CTO')
Assert-True ($r.json.success -eq $true) 'I7 derived DESIGN chain head claimable (deps satisfied by the settled upstream chain)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'escalate', '-RunId', $runA, '-NodeId', $cto2, '-Checkpoint', '派生任务技术选型', '-Decision', '导出走 A 还是 B？', '-Risk', 'high')
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.kind -eq 'escalation') 'I7 engine writes an open escalation into the SAME archive-level ledger' ($r.raw)
$escId = [string]$r.json.data.entry.entry_id
Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-RunPath $runA) 'decisions.jsonl'))) 'I7 [SEAM] ledger lives at the ARCHIVE root only (no run-dir copy) — 写读同源' ("run-dir ledger exists=$(Test-Path -LiteralPath (Join-Path (Get-RunPath $runA) 'decisions.jsonl'))")
$decKinds = (@(Read-Ledger $archA | ForEach-Object { [string]$_.kind }) -join ',')
Assert-True ((Count-LedgerKind $archA 'derive_proposal') -eq 1 -and (Count-LedgerKind $archA 'escalation') -eq 1 -and (Count-LedgerKind $archA 'ruling') -ge 1) 'I7 one archive ledger carries BOTH derive entries and the auto-mode escalation (mixed kinds)' $decKinds
$pv = Get-PluginView $Work $runA
$openHit = @($pv.json.open | Where-Object { [string]$_.runId -eq $runA -and [string]$_.entryId -eq $escId })
Assert-True ($pv.exit -eq 0 -and $null -ne $pv.json -and $openHit.Count -eq 1) 'I7 [SEAM] plugin artifact reads the escalation through bridge.json archive_rel, ignoring the derive kinds' $pv.raw
Assert-True ($openHit.Count -eq 1 -and [string]$openHit[0].question -eq '导出走 A 还是 B？' -and [string]$openHit[0].nodeId -eq $cto2 -and [string]$openHit[0].risk -eq 'high') 'I7 projected inbox row keeps the wire shape over a mixed-kind ledger' ((@($openHit) | ConvertTo-Json -Depth 4 -Compress))
Assert-True ($null -ne $pv.json.run -and [string]$pv.json.run.runId -eq $runA) 'I7 [SEAM] plugin aggregates this run in the same call (engine-written state visible to the plugin)' $pv.raw
$r = Invoke-Bridge @('-Command', 'decide', '-RunId', $runA, '-NodeId', $cto2, '-Kind', 'resolution', '-RefEntry', $escId, '-Checkpoint', '派生任务技术选型', '-Decision', '选 A')
Assert-True ($r.json.success -eq $true) 'I7 user verdict recorded as resolution on the same ledger' ($r.raw)
$pv2 = Get-PluginView $Work $runA
Assert-True (@($pv2.json.open | Where-Object { [string]$_.runId -eq $runA }).Count -eq 0) 'I7 resolution closes it for the watcher immediately (fresh read, join-derived)' $pv2.raw
# 派生任务的 CTO 产出并**登记**设计产物（协议步 rdd-flow add-design）：漏登记 = 漏审
# （真实 run 的 n3 就漏掉了任务 2 设计的登记，见 D2）。登记后设计产物落在审查对象面上。
New-Item -ItemType Directory -Path (Join-Path $Work "$archA/design") -Force | Out-Null
Write-Utf8NoBom (Join-Path $Work "$archA/design/d2.md") ("# 派生设计文档`n`n变更地图：`n`n- ``src/mod-2.py``  [新增] 模块 2`n`n[新增] 1 | [修改] 0 | [删除] 0`n")
$r = Invoke-Flow @('-Command', 'add-design', '-Archive', $archA, '-TaskId', '2', '-Path', 'design/d2.md')
Assert-True ($r.json.success -eq $true) 'I7 derived CTO registers its design artifact (rdd-flow add-design)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'status', '-RunId', $runA)
Assert-True ([string](Read-BridgeJson $runA).plan.stages[1].design_review.status -eq 'planned') 'I7 [SEAM] artifact on disk but DESIGN unfinished -> the stage stays planned, NOT exempt (no premature no-artifact verdict)' ($r.raw)
$null = Do-AfterClaim $runA $cto2 'CTO' @("$archA/design/d2.md")
$a9 = Read-BridgeJson $runA
Assert-True ([string]$a9.plan.stages[1].design_review.status -eq 'planned') 'I7 CTO settle alone does not trigger S2 (its DESIGN group is still converging -> wait)' ($a9.plan.stages[1].design_review | ConvertTo-Json -Depth 4)
$ux2 = [string](Read-BridgeJson $runA).tasks.'2'.stages.UX
$null = Do-Deliver $runA $ux2 'UX' @("$archA/design/d2.md")
$null = Do-Settle $runA $ux2
$qa2d = [string](Read-BridgeJson $runA).tasks.'2'.stages.QA
$null = Do-Deliver $runA $qa2d 'QA' @("$archA/requirements/dr1.md")
$r = Do-Settle $runA $qa2d
Assert-True ($r.json.success -eq $true) 'I7 derived DESIGN phase settled (CTO->UX->QA)' ($r.raw)
$a10 = Read-BridgeJson $runA
$drS2 = $a10.plan.stages[1].design_review
Assert-True ([string]$drS2.status -eq 'ready' -and $null -eq $drS2.node) 'I7 [SEAM] S2 own review reached ready once its DESIGN work converged (second subagent review in the same run)' ($drS2 | ConvertTo-Json -Depth 4)
$r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', $runA)
$st2 = @($r.json.data.stages | Where-Object { [string]$_.stage -eq 'S2' })[0]
Assert-True ($null -ne $st2 -and @($st2.docs) -contains 'design/d2.md') 'I7 S2 review object face = the derived task design doc' ($r.raw)
$dev2 = [string]$a10.tasks.'2'.stages.DEV
Assert-True ($dev2 -ne '') 'I7 derived IMPL head grafted after DESIGN converged' ($a10.tasks.'2'.stages | ConvertTo-Json -Depth 4)
$r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runA, '-NodeId', $dev2, '-Role', 'DEV')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'I7 [SEAM] the DERIVED task IMPL is gated by the derived stage review (review reaches the derived design work)' ($r.raw)
Write-ReviewFile $archA 'S2' @('design/d1.md') 'pass' | Out-Null
$r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', $runA, '-Stage', 'S2')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED') 'I7 [SEAM] a review file covering the WRONG stage docs is rejected (contract core shared with the settle gate)' ($r.raw)
Write-ReviewFile $archA 'S2' @('design/d2.md') 'pass' | Out-Null
$r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', $runA, '-Stage', 'S2')
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass') 'I7 S2 submit pass' ($r.raw)
$r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runA, '-NodeId', $dev2, '-Role', 'DEV')
Assert-True ($r.json.success -eq $true) 'I7 derived IMPL unblocked by the derived stage review pass' ($r.raw)
$null = Do-AfterClaim $runA $dev2 'DEV' @("$archA/requirements/dr1.md")
$qa2v = [string](Read-BridgeJson $runA).tasks.'2'.stages.QA
$null = Do-Deliver $runA $qa2v 'QA' @("$archA/requirements/dr1.md")
$r = Do-Settle $runA $qa2v
Assert-True ($r.json.success -eq $true) 'I7 derived VERIFY settled' ($r.raw)
Assert-True ([string](Get-Task $archA 2).lifecycle -eq 'completed') 'I7 derived task #2 terminal (run converges without a new run)' ((Get-Task $archA 2) | ConvertTo-Json -Depth 4)

# ============ I8 结案闸门群 + 整体验收链（本节点自身的机制也在被测链上） ============
$r = Invoke-Bridge @('-Command', 'status', '-RunId', $runA)
Assert-True ($r.json.success -eq $true) 'I8 status touch runs the self-healing state machines' ($r.raw)
$a11 = Read-BridgeJson $runA
Assert-True ([string]$a11.plan.stages[0].acceptance_point.status -eq 'passed') 'I8 S1 acceptance point stayed passed (settled before the derived chain)' ($a11.plan.stages[0].acceptance_point | ConvertTo-Json -Depth 4)
Assert-True ([string]$a11.acceptance.status -eq 'grafted' -and [string]$a11.acceptance.integrate_node -ne '') 'I8 all mapped nodes terminal -> [集成/联调] grafted (same chain this node rides)' ($a11.acceptance | ConvertTo-Json -Depth 4)
$r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runA, '-Action', 'propose', '-Title', '派生：结案前又见缺口', '-Rationale', '结案硬门验证用（随后 withdraw）')
Assert-True ($r.json.success -eq $true) 'I8 DRV2 proposed (pending, blocks conclude)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'conclude', '-RunId', $runA, '-Summary', '结案尝试（派生挂起）')
Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DERIVATION_PENDING') 'I8 open derivation blocks the conclude (DERIVATION_PENDING hard gate)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runA, '-Action', 'withdraw', '-DerivationId', 'DRV2', '-Reason', '用户改口：不派生')
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'withdrawn') 'I8 withdraw closes the proposal (zero side effects)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'conclude', '-RunId', $runA, '-Summary', '结案尝试（验收链未过）')
Assert-True ($r.json.success -eq $false -and @('ACCEPTANCE_PENDING', 'STAGE_ACCEPTANCE_PENDING') -contains [string]$r.json.error.code) 'I8 after withdraw the ACCEPT/STAGE gate owns the next refusal (derive gate released)' ($r.raw)
$reportA = Join-Path $Work "$archA/tests/integration-acceptance.md"
New-Item -ItemType Directory -Path (Split-Path $reportA -Parent) -Force | Out-Null
Write-Utf8NoBom $reportA "# 整体验收（夹具 mi-a）`n`n## §1 集成/联调记录`n`n双机制串联（探针夹具）。`n`n## §2 判据逐条核验表`n`n| # | 判据 | 结果 |`n|---|------|------|`n| 1 | 主需求 + 派生需求同 run 串联 | PASS |`n`n## §3 总结论`n`n总结论：通过`n"
$integNode = [string](Read-BridgeJson $runA).acceptance.integrate_node
$null = Do-Deliver $runA $integNode 'DEV' @("$archA/tests/integration-acceptance.md")
$r = Do-Settle $runA $integNode
Assert-True ($r.json.success -eq $true) 'I8 [集成/联调] node settled (acceptance context = report + §3 conclusion rule)' ($r.raw)
$r = Invoke-Bridge @('-Command', 'status', '-RunId', $runA)
$a12 = Read-BridgeJson $runA
$acceptNode = [string]$a12.acceptance.accept_node
Assert-True ($acceptNode -ne '' -and [string]$a12.acceptance.status -eq 'grafted') 'I8 [整体验收] node grafted after the integrate node settled' ($a12.acceptance | ConvertTo-Json -Depth 4)
Assert-True ([string]$a12.plan.stages[1].acceptance_point.node -eq $acceptNode) 'I8 [SEAM] the final stage rides the R1 chain (no duplicate acceptance node)' ($a12.plan.stages[1].acceptance_point | ConvertTo-Json -Depth 4)
$null = Do-Deliver $runA $acceptNode 'QA' @("$archA/tests/integration-acceptance.md")
$r = Do-Settle $runA $acceptNode
Assert-True ($r.json.success -eq $true) 'I8 [整体验收] node settled' ($r.raw)
$r = Invoke-Bridge @('-Command', 'status', '-RunId', $runA)
$a13 = Read-BridgeJson $runA
Assert-True ([string]$a13.acceptance.conclusion -eq '通过' -and -not [string]::IsNullOrWhiteSpace([string]$a13.acceptance.recorded_at)) 'I8 §3 conclusion read back and recorded (decidable verdict)' ($a13.acceptance | ConvertTo-Json -Depth 4)
Assert-True ([string]$a13.plan.stages[1].acceptance_point.status -eq 'passed') 'I8 final stage acceptance bound to the settled accept node -> passed' ($a13.plan.stages[1].acceptance_point | ConvertTo-Json -Depth 4)

# ============ I9 结案：派生清单 / 整体验收结论 / 任务终态三联 + add-task 门释放 ============
$r = Invoke-Bridge @('-Command', 'conclude', '-RunId', $runA, '-Summary', '双机制串联交付：主需求 + run 中途派生需求 + 两阶段子代理设计审查')
Assert-True ($r.json.success -eq $true -and [string]$r.json.data.outcome -eq 'achieved') 'I9 conclude achieved' ($r.raw)
Assert-True ([string]$r.json.data.acceptance.conclusion -eq '通过') 'I9 conclude echoes the acceptance verdict' ($r.raw)
Assert-True ([string]$r.json.data.tasks_terminal -eq '2/2') 'I9 tasks_terminal = 2/2 (the derived task is covered by the terminal hard gate)' ([string]$r.json.data.tasks_terminal)
$derRows = @($r.json.data.derivations)
$d1Row = @($derRows | Where-Object { [string]$_.id -eq 'DRV1' })[0]
$d2Row = @($derRows | Where-Object { [string]$_.id -eq 'DRV2' })[0]
Assert-True ($null -ne $d1Row -and [string]$d1Row.status -eq 'registered' -and [int]$d1Row.task_id -eq 2 -and $d1Row.absorbed -eq $true) 'I9 conclude echoes the derivation view (DRV1 registered+absorbed, task #2)' ($d1Row | ConvertTo-Json -Depth 4)
Assert-True ($null -ne $d2Row -and [string]$d2Row.status -eq 'withdrawn') 'I9 withdrawn derivation echoed as terminal (never blocks)' ($d2Row | ConvertTo-Json -Depth 4)
$annexPath = Join-Path $Work ('.rdd/goal-trees/' + $runA + '/report/delivery-annex.md')
$annex = ''
if (Test-Path -LiteralPath $annexPath -PathType Leaf) { $annex = [System.IO.File]::ReadAllText($annexPath, [System.Text.Encoding]::UTF8) }
Assert-True ($annex -match '需求派生（mid-run derive）' -and $annex -match '\| DRV1 \|' -and $annex -match '#2' -and $annex -match '已入 plan') 'I9 [SEAM] annex 派生清单 present with status/task/absorption columns' ($annex)
Assert-True ($annex -match '整体验收结论' -and $annex -match '总结论: 通过' -and $annex -match [regex]::Escape($integNode) -and $annex -match [regex]::Escape($acceptNode)) 'I9 [SEAM] annex 整体验收结论區 carries chain ids + verdict (same report this node writes)' ($annex)
$mf = Read-JsonFile (Join-Path (Get-RunPath $runA) 'manifest.json')
Assert-True ($null -ne $mf -and [string]$mf.state -eq 'concluded') 'I9 manifest state=concluded (top-level manifest — the add-task release anchor)' ("state=$([string]$mf.state)")
$r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archA, '-Title', '结案后追加', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
Assert-True ($r.json.success -eq $true) 'I9 [SEAM] concluded run releases the add-task gate (R2 cross-component 通道)' ($r.raw)
$rulingKinds = (@(Read-Ledger $archA | ForEach-Object { [string]$_.kind + ':' + [string]$_.checkpoint }) -join ',')
Assert-True ((Count-LedgerKind $archA 'ruling') -ge 2) 'I9 conclude auto-ruling recorded on the archive decision ledger' $rulingKinds
}
catch {
    Assert-True $false 'Run A integration chain raised (probe must fail loud)' $_.Exception.Message
}

# =====================================================================
# Run B — 派生并入**同一（在审）阶段**的失效面（mi-b / deliver-mi-b）
# =====================================================================
try {
    $tasksB = '[{"title":"主需求B","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $archB = New-Archive 'mi-b' $tasksB $Script:AcceptanceBlock
    $runB = 'deliver-mi-b'
    $pfB = New-PlanFile (Join-Path $Work 'mi-b-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archB + '/task.json'), '-PlanFile', $pfB, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'I10 promulgate ok' ($r.raw)
    $b1 = Read-BridgeJson $runB
    $ctoB = [string]$b1.tasks.'1'.stages.CTO
    $null = Do-Deliver $runB $ctoB 'CTO' @("$archB/design/d1.md")
    $null = Do-Settle $runB $ctoB
    Assert-True ([string](Read-BridgeJson $runB).plan.stages[0].design_review.status -eq 'ready') 'I10 S1 review ready before the derivation lands' ((Read-BridgeJson $runB).plan.stages[0].design_review | ConvertTo-Json -Depth 4)
    $null = Invoke-Bridge @('-Command', 'derive', '-RunId', $runB, '-Action', 'propose', '-Title', '派生：同阶段并入', '-Rationale', '同阶段吸收的失效面验证', '-DependsOn', '1')
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runB, '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意并入当前 run（同阶段）')
    Assert-True ($r.json.success -eq $true) 'I10 derivation confirmed (same-stage scenario)' ($r.raw)
    $b2 = Read-BridgeJson $runB
    $pmB = [string](Get-Der $b2 'DRV1').node
    Write-Utf8NoBom (Join-Path $Work "$archB/requirements/dr1.md") "# 派生需求：同阶段并入`n`n- **描述**：同阶段吸收失效面`n- **验收标准**：可判`n"
    $null = Do-Deliver $runB $pmB 'PM' @("$archB/requirements/dr1.md", "$archB/requirements/overview.md")
    $r = Do-Settle $runB $pmB
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -match 'derivation registered') 'I10 PM settle -> registered (task #2)' ($r.raw)
    $pfB2 = New-PlanFile (Join-Path $Work 'mi-b-plan2.json') @(@{ id = 'S1'; tasks = @(1, 2); batches = @(@(1), @(2)) })
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', $runB, '-PlanFile', $pfB2, '-Reason', '同阶段吸收派生任务 #2')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.derivations_absorbed) -match 'DRV1') 'I10 replan absorbs into the SAME stage (content changed)' ($r.raw)
    $b3 = Read-BridgeJson $runB
    Assert-True ([string]$b3.plan.stages[0].design_review.status -eq 'planned') 'I10 [SEAM] same-stage absorption resets the review slot to planned (fresh re-review)' ($b3.plan.stages[0].design_review | ConvertTo-Json -Depth 4)
    Assert-True ((Count-PlanEvent $runB 'design_review_invalidated') -eq 1) 'I10 design_review_invalidated event recorded (anti-false-open: the old ready state cannot be reused)' ((Read-PlanLog $runB | ForEach-Object { [string]$_.event }) -join ',')
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', $runB, '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_NOT_READY') 'I10 a stale review product cannot pass after the invalidation' ($r.raw)
    $devB = [string]$b3.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runB, '-NodeId', $devB, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'I10 main-task IMPL re-gated by the reset review slot' ($r.raw)
    $ctoB2 = [string]$b3.tasks.'2'.stages.CTO
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $runB, '-NodeId', $ctoB2, '-Role', 'CTO')
    $depBlocked = ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DEPS')
    Assert-True ($r.json.success -eq $true -or $depBlocked) 'I10 derived DESIGN head claimable or dep-blocked (measured, not assumed)' ("ok=$($r.json.success) code=$([string]$r.json.error.code)")
    if ($depBlocked) {
        Assert-True $true 'I10 [SEAM] measured interlock: review waits for all-past-DESIGN while the derived head waits on upstream deps' ([string]$r.json.error.message)
    }
    else {
        Assert-True $true 'I10 [SEAM] measured: same-stage absorption leaves the derived head free (no dep interlock in this shape)' ''
    }
}
catch {
    Assert-True $false 'Run B block raised' $_.Exception.Message
}

# =====================================================================
# Run C — 未预留预算时，run 中途派生把节点预算吃干（结案/派生链双阻塞）
# =====================================================================
try {
    $tasksC = '[{"title":"主需求C","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $archC = New-Archive 'mi-c' $tasksC $Script:AcceptanceBlock
    $runC = 'deliver-mi-c'
    $pfC = New-PlanFile (Join-Path $Work 'mi-c-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    # 刻意**不预留**（默认预算 = 5*任务数+6，宽度 = 链头+2）
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archC + '/task.json'), '-PlanFile', $pfC, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'I20 promulgate ok (default budget, no headroom reserved)' ($r.raw)
    $c1 = Read-BridgeJson $runC
    $treeC = Read-JsonFile (Join-Path (Get-RunPath $runC) 'manifest.json')
    Assert-True ([int]$treeC.budget.max_nodes -eq 11 -and [int]$treeC.budget.node_width -eq 4) 'I20 default budget = 5*1+6 nodes / heads+2 width (no headroom)' ($treeC.budget | ConvertTo-Json -Compress)
    $ctoC = [string]$c1.tasks.'1'.stages.CTO
    $null = Do-Deliver $runC $ctoC 'CTO' @("$archC/design/d1.md")
    $null = Do-Settle $runC $ctoC
    Assert-True ([string](Read-BridgeJson $runC).plan.stages[0].design_review.status -eq 'ready') 'I20 S1 review ready' ((Read-BridgeJson $runC).plan.stages[0].design_review | ConvertTo-Json -Depth 4)
    $null = Invoke-Bridge @('-Command', 'derive', '-RunId', $runC, '-Action', 'propose', '-Title', '派生：未预留预算场景', '-Rationale', '预算预检盲区验证')
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', $runC, '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意派生（未预留预算）')
    Assert-True ($r.json.success -eq $true) 'I20 [SEAM] the confirm-time budget pre-check GREENLIGHTS the derivation (no DERIVE_BUDGET_EXCEEDED)' ($r.raw)
    $c2 = Read-BridgeJson $runC
    $pmC = [string](Get-Der $c2 'DRV1').node
    Write-Utf8NoBom (Join-Path $Work "$archC/requirements/dr1.md") "# 派生需求：预算场景`n`n- **描述**：预算预检盲区`n- **验收标准**：可判`n"
    $null = Do-Deliver $runC $pmC 'PM' @("$archC/requirements/dr1.md", "$archC/requirements/overview.md")
    $r = Do-Settle $runC $pmC
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -match 'derivation registered') 'I20 PM settle -> registered (task #2)' ($r.raw)
    $pfC2 = New-PlanFile (Join-Path $Work 'mi-c-plan2.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) })
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', $runC, '-PlanFile', $pfC2, '-Reason', '吸收派生（并入新阶段 S2）')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.derivations_absorbed) -match 'DRV1') 'I20 replan absorbs the derivation' ($r.raw)
    Write-ReviewFile $archC 'S1' @('design/d1.md') 'pass' | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', $runC, '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true) 'I20 S1 review submit pass' ($r.raw)
    $devC = [string](Read-BridgeJson $runC).tasks.'1'.stages.DEV
    $null = Do-Deliver $runC $devC 'DEV' @("$archC/requirements/t1.md")
    $null = Do-Settle $runC $devC
    $qaC = [string](Read-BridgeJson $runC).tasks.'1'.stages.QA
    $null = Do-Deliver $runC $qaC 'QA' @("$archC/requirements/t1.md")
    $null = Do-Settle $runC $qaC
    Assert-True ([string](Get-Task $archC 1).lifecycle -eq 'completed') 'I20 task #1 terminal' ((Get-Task $archC 1) | ConvertTo-Json -Depth 4)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', $runC)
    $c3 = Read-BridgeJson $runC
    $saC = [string]$c3.plan.stages[0].acceptance_point.node
    Assert-True ($saC -ne '') 'I20 [集成验收·S1] grafted (S1 no longer the final stage after absorbing S2)' ($c3.plan.stages[0].acceptance_point | ConvertTo-Json -Depth 4)
    $null = Do-Deliver $runC $saC 'QA' @("$archC/requirements/overview.md")
    $null = Do-Settle $runC $saC
    # —— 派生任务链照常推进（S2 审查同样生效），把节点预算逐节点吃掉 ——
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', $runC)
    $cto2C = [string](Read-BridgeJson $runC).tasks.'2'.stages.CTO
    $null = Invoke-Bridge @('-Command', 'claim', '-RunId', $runC, '-NodeId', $cto2C, '-Role', 'CTO')
    New-Item -ItemType Directory -Path (Join-Path $Work "$archC/design") -Force | Out-Null
    Write-Utf8NoBom (Join-Path $Work "$archC/design/d2.md") ("# 派生设计文档`n`n变更地图：`n`n- ``src/mod-2.py``  [新增] 模块 2`n`n[新增] 1 | [修改] 0 | [删除] 0`n")
    $null = Invoke-Flow @('-Command', 'add-design', '-Archive', $archC, '-TaskId', '2', '-Path', 'design/d2.md')
    $null = Do-AfterClaim $runC $cto2C 'CTO' @("$archC/design/d2.md")
    $ux2C = [string](Read-BridgeJson $runC).tasks.'2'.stages.UX
    $null = Do-Deliver $runC $ux2C 'UX' @("$archC/design/d2.md")
    $null = Do-Settle $runC $ux2C
    $qa2dC = [string](Read-BridgeJson $runC).tasks.'2'.stages.QA
    $null = Do-Deliver $runC $qa2dC 'QA' @("$archC/requirements/dr1.md")
    $null = Do-Settle $runC $qa2dC
    Assert-True ([string](Read-BridgeJson $runC).plan.stages[1].design_review.status -eq 'ready') 'I20 S2 review ready (the derived stage is reviewed even under budget pressure)' ((Read-BridgeJson $runC).plan.stages[1].design_review | ConvertTo-Json -Depth 4)
    Write-ReviewFile $archC 'S2' @('design/d2.md') 'pass' | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', $runC, '-Stage', 'S2')
    Assert-True ($r.json.success -eq $true) 'I20 S2 review submit pass' ($r.raw)
    $dev2C = [string](Read-BridgeJson $runC).tasks.'2'.stages.DEV
    Assert-True ($dev2C -ne '') 'I20 derived IMPL head grafted' ($dev2C)
    $null = Do-Deliver $runC $dev2C 'DEV' @("$archC/requirements/dr1.md")
    $null = Do-Settle $runC $dev2C
    $qa2vC = [string](Read-BridgeJson $runC).tasks.'2'.stages.QA
    $null = Do-Deliver $runC $qa2vC 'QA' @("$archC/requirements/dr1.md")
    $null = Do-Settle $runC $qa2vC
    # —— 节点配额到底：派生链把预算吃到最后一格，run 级验收链再也无处落位 ——
    $treeC = Read-JsonFile (Join-Path (Get-RunPath $runC) 'manifest.json')
    $nodesC = Read-JsonFile (Join-Path (Get-RunPath $runC) 'state/tree.json')
    $usedC = @($nodesC.nodes).Count
    $maxC = [int]$treeC.budget.max_nodes
    Assert-True ($usedC -eq $maxC) 'I20 [SEAM] the derived chain consumes the node budget to the last node (used == max)' ("used=$usedC max=$maxC")
    Assert-True ([string](Get-Task $archC 2).lifecycle -eq 'completed') 'I20 the derived requirement itself IS delivered (both tasks terminal)' ((Get-Task $archC 2) | ConvertTo-Json -Depth 4)
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', $runC)
    $null = Invoke-Bridge @('-Command', 'status', '-RunId', $runC)
    $c4 = Read-BridgeJson $runC
    Assert-True ([string]$c4.acceptance.integrate_node -eq '' -and [string]$c4.acceptance.status -eq 'planned') 'I20 [SEAM] all tasks terminal, yet the run-level acceptance chain can NEVER graft (no node left; repeated triggers leave it planned)' ($c4.acceptance | ConvertTo-Json -Depth 4)
    # 预算探针：直接向 goal root 追加一个节点，取 graft 的**显式错误码**——把「闭环失败」
    # 从现象钉到确定的绑定约束上。
    $probeItems = @(@{ title = '预算探针'; task = 'budget diagnostic probe node'; role = 'qa'; ref = 'requirements/overview.md' })
    $probeFile = Join-Path $Work 'mi-c-probe-tasks.json'
    Write-Utf8NoBom $probeFile (ConvertTo-Json @($probeItems) -Depth 8)
    $r = Invoke-Ps1 (Join-Path $EngineDir 'goal-tree.ps1') @('-Command', 'graft', '-RunId', $runC, '-Parent', ([string]$c4.goal_root), '-TasksFile', $probeFile)
    Assert-True ($r.json.success -eq $false -and @('WIDTH_EXCEEDED', 'NODES_EXCEEDED') -contains [string]$r.json.error.code) 'I20 [SEAM] the wall is explicit and deterministic (WIDTH_EXCEEDED / NODES_EXCEEDED)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', $runC, '-Summary', '结案尝试（预算吃干）')
    Assert-True ($r.json.success -eq $false -and @('STAGE_ACCEPTANCE_PENDING', 'ACCEPTANCE_PENDING', 'DELIVERY_INCOMPLETE') -contains [string]$r.json.error.code) 'I20 [SEAM] the run cannot be closed although every task is delivered (single-run convergence broken)' ($r.raw)
}
catch {
    Assert-True $false 'Run C block raised' $_.Exception.Message
}

# =====================================================================
# Real — 真实仓：引擎写 ↔ 插件读逐字段对账（零写入）
# =====================================================================
try {
    $realRun = 'deliver-2026-10-07-planner-midrun-derive'
    $realBridge = Read-JsonFile (Join-Path $RepoRoot ('.rdd/goal-trees/' + $realRun + '/bridge.json'))
    $realTree = Read-JsonFile (Join-Path $RepoRoot ('.rdd/goal-trees/' + $realRun + '/state/tree.json'))
    $realManifest = Read-JsonFile (Join-Path $RepoRoot ('.rdd/goal-trees/' + $realRun + '/manifest.json'))
    $pvReal = Get-PluginView $RepoRoot $realRun
    Assert-True ($pvReal.exit -eq 0 -and $null -ne $pvReal.json -and $pvReal.json.success -eq $true) 'I11 [SEAM] plugin artifact reads THIS run without error (real repo, zero write)' $pvReal.raw
    $rv = $pvReal.json.run
    Assert-True ($null -ne $rv -and [string]$rv.runId -eq $realRun -and [string]$rv.state -eq [string]$realManifest.state) 'I11 plugin run view state agrees the engine-written manifest' ("plugin=$($rv.state) manifest=$($realManifest.state)")
    $doneIds = @($realTree.nodes | Where-Object { [string]$_.status -eq 'done' } | ForEach-Object { [string]$_.id })
    $pvDoneIds = @($rv.nodes | Where-Object { [string]$_.status -eq 'done' } | ForEach-Object { [string]$_.id })
    Assert-True ([int]$rv.counts.done -eq $doneIds.Count) 'I11 [SEAM] done-count agrees engine tree.json <-> plugin view' ("plugin=$($rv.counts.done) tree=$($doneIds.Count)")
    Assert-True (@($pvDoneIds | Sort-Object) -join ',' -eq (@($doneIds | Sort-Object) -join ',')) 'I11 [SEAM] the same node id set is done on both sides (no view drift)' ("plugin=[$((@($pvDoneIds | Sort-Object)) -join ',')] tree=[$((@($doneIds | Sort-Object)) -join ',')]")
    Assert-True ([string]$realBridge.plan.stages[0].design_review.status -eq 'passed' -and [string]$realBridge.plan.stages[0].design_review.verdict -eq 'pass') 'I11 the delivered run carries an engine-derived passed review (legacy node chain — 存量不回溯)' ($realBridge.plan.stages[0].design_review | ConvertTo-Json -Depth 4)
    Assert-True ([string]$realBridge.acceptance.status -eq 'grafted' -and [string]$realBridge.acceptance.integrate_node -eq 'n8' -and [string]$realBridge.acceptance.report -eq 'tests/integration-acceptance.md') 'I11 acceptance chain points at THIS node and this report (self-referential contract intact)' ($realBridge.acceptance | ConvertTo-Json -Depth 4)
    $realTreeBudget = $realManifest.budget
    Assert-True ([int]$realTreeBudget.max_nodes -gt 16 -and [int]$realTreeBudget.node_width -gt 4) 'I11 [SEAM] THIS run reserved budget headroom at promulgate (the documented mitigation for mid-run derivation)' ($realTreeBudget | ConvertTo-Json -Compress)
    $realLed = Read-Jsonl (Join-Path $RepoRoot '.rdd/changes/archive/2026-10-07-planner-midrun-derive/decisions.jsonl')
    $badKinds = @($realLed | Where-Object { [string]$_.kind -notin @('checkpoint', 'ruling', 'derive_proposal', 'escalation', 'resolution', 'overturn', 'auto') })
    Assert-True ($realLed.Count -ge 5 -and $badKinds.Count -eq 0) 'I11 the delivered archive ledger is readable and carries only in-domain kinds' (($realLed | ForEach-Object { [string]$_.kind }) -join ',')
    $pvRealOpen = @($pvReal.json.open | Where-Object { [string]$_.runId -eq $realRun })
    Assert-True ($pvRealOpen.Count -eq 0) 'I11 no open escalation left in this run (plugin view consistent with the settled ledger)' $pvReal.raw
}
catch {
    Assert-True $false 'Real-repo block raised' $_.Exception.Message
}

# ============ I12 BOM 自检（tips 义务：本探针为中文 .ps1） ============
foreach ($f in @($PSCommandPath)) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $n = Split-Path $f -Leaf
    Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "I12 $n first-3-bytes = 239,187,191 (BOM intact)" ("got {0},{1},{2}" -f $bytes[0], $bytes[1], $bytes[2])
}

}
finally {
    Pop-Location
    $env:DSH_WEB_URL = $null
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("--- integration probe: {0} passed / {1} failed / {2} total ---" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count, $Results.Count)
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Output ("FAILED: {0}   {1}" -f $f.name, $f.detail) }
    exit 1
}
exit 0

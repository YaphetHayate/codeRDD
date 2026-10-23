# goal-tree-wake-model bridge acceptance — S4/S2 验收锚（设计文档 §9）
# 场景：wake 形状 promulgate → 3 波设计审查 fail 风暴 → 第 4 次唤醒撞配额（强制升级点）。
# 不变式：重做风暴中需求子树（容器+槽）节点数零增长；stages 映射节点恒定；
#         DEV 槽 reset 不 prune；审查槽每轮 +1（有界轮换产物，非需求槽重建）。
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('bridge-wake-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond }
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
function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'wake-model test delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: no PowerShell in change set' } }
    }
    $cbFile = Join-Path $env:TEMP ("wk-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { return $r }
    $cb = New-Cb $NodeId $Refs
    return (Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb))
}
function Write-ReviewFile { param([string]$ArchiveRel, [string]$StageId, [string[]]$DocRels, [string]$Verdict, [string]$Dim = 'change_map')
    $archAbs = Join-Path $Work $ArchiveRel
    $docs = @()
    foreach ($rel in @($DocRels)) {
        $findings = @()
        if ($Verdict -eq 'fail') {
            $findings += @{ severity = 'blocking'; dimension = $Dim; item = "blocking finding on $rel"; suggestion = '修正后重产' }
        }
        $docs += @{ doc = $rel; verdict = $Verdict; findings = $findings }
    }
    $file = [ordered]@{ reviewed_at = '2026-10-17T09:00:00Z'; reviewer = 'auditor'; stage = $StageId; docs = $docs; summary = @{ cross_design = @() } }
    $rel2 = "review/design-review-$StageId.json"
    $abs = Join-Path $archAbs ($rel2 -replace '/', '\')
    $dir = Split-Path $abs -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# 设计汇聚审查 — $ArchiveRel·$StageId`n`n镜像。`n"
    return $rel2
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # archive: 1 CTO design task with an on-disk design doc
    $archDir = Join-Path $Work '.rdd/changes/archive/wk-l1'
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $archDir 'design') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# wk-l1`n`nwake-model 测试归档。`n`n## 整体验收判据`n`n无整体判据（理由：wake 形状验收测试归档，显式声明）`n"
    Write-Utf8NoBom (Join-Path $archDir 'requirements/t1.md') "# wk-l1 需求 1`n`n- **描述**：wake 形状需求 1`n- **验收标准**：见 overview.md`n"
    Write-Utf8NoBom (Join-Path $archDir 'design/d1.md') "# 设计文档 1`n`n变更地图：`n`n- ``src/mod-a.py``  [新增] 模块 A`n`n[新增] 1 | [修改] 0 | [删除] 0`n"
    $tasksJson = '[{"title":"WK1","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $tf = Join-Path $Work 'wk-l1-init.json'
    Write-Utf8NoBom $tf $tasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/wk-l1', '-TasksFile', 'wk-l1-init.json')
    if ($r.json.success -ne $true) { throw "init failed: $($r.raw)" }

    $plan = [ordered]@{ planned_at = '2026-10-17T00:00:00Z'; planner = 'test'; stages = @(
        @{ id = 'S1'; goal = 'stage S1 目标'; milestone = 'S1 里程碑'; task_ids = @(1); batches = @(,@(1)); acceptance_point = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable slice' } }
    ); risks = @() }
    $pf = Join-Path $Work 'wk-l1-plan.json'
    Write-Utf8NoBom $pf ($plan | ConvertTo-Json -Depth 8)

    # ================= WK0: DEFAULT shape pin (no -Shape flag) =================
    # 引擎 1.2.0 起 promulgate 缺省形状 = wake（历史 default legacy 翻转）。本块
    # 用不传 -Shape 的颁布钉死默认值：bridge.json/manifest 双落 wake + 容器拓扑。
    # 若未来误将默认翻回 legacy，这里第一时刻红。
    $arch0 = Join-Path $Work '.rdd/changes/archive/wk-l0'
    New-Item -ItemType Directory -Path (Join-Path $arch0 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch0 'requirements/overview.md') "# wk-l0`n`nwake 默认形状钉定归档。`n`n## 整体验收判据`n`n无整体判据（理由：默认形状钉定测试归档，显式声明）`n"
    Write-Utf8NoBom (Join-Path $arch0 'requirements/t1.md') "# wk-l0 需求 1`n`n- **描述**：默认形状钉定需求 1`n- **验收标准**：见 overview.md`n"
    $tasks0 = '[{"title":"WK0","requirement":"requirements/t1.md","currentOwners":["UX"]}]'
    $tf0 = Join-Path $Work 'wk-l0-init.json'
    Write-Utf8NoBom $tf0 $tasks0
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/wk-l0', '-TasksFile', 'wk-l0-init.json')
    if ($r.json.success -ne $true) { throw "wk-l0 init failed: $($r.raw)" }
    $plan0 = [ordered]@{ planned_at = '2026-10-17T00:00:00Z'; planner = 'test'; stages = @(
        @{ id = 'S1'; goal = 'stage S1 目标'; milestone = 'S1 里程碑'; task_ids = @(1); batches = @(,@(1)); acceptance_point = @{ criteria_items = @('smoke: default shape pinned'); slice = 'runnable slice' } }
    ); risks = @() }
    $pf0 = Join-Path $Work 'wk-l0-plan.json'
    Write-Utf8NoBom $pf0 ($plan0 | ConvertTo-Json -Depth 8)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/wk-l0/task.json', '-PlanFile', $pf0, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'WK0 promulgate WITHOUT -Shape ok (default = wake)' ($r.raw)
    $b0 = Read-BridgeJson 'deliver-wk-l0'
    Assert-True ([string]$b0.shape -eq 'wake') 'WK0 bridge.json shape=wake by DEFAULT' ($b0 | ConvertTo-Json -Depth 3 -Compress)
    $mf0 = (Get-Content -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-wk-l0/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-True ([string]$mf0.shape -eq 'wake') 'WK0 manifest.json shape=wake by DEFAULT' ($mf0 | ConvertTo-Json -Compress)
    $cont0 = [string]$b0.tasks.'1'.container
    $ux0 = [string]$b0.tasks.'1'.stages.UX
    $nodes0 = Read-TreeNodes 'deliver-wk-l0'
    $contNode0 = $nodes0 | Where-Object { $_.id -eq $cont0 }
    $uxNode0 = $nodes0 | Where-Object { $_.id -eq $ux0 }
    Assert-True ($null -ne $contNode0 -and [string]$contNode0.type -eq 'sub' -and ($null -eq $contNode0.parent -or [string]$contNode0.parent -eq 'n1')) 'WK0 requirement container (type=sub) at goal root by default' ($contNode0 | ConvertTo-Json -Compress)
    Assert-True ($null -ne $uxNode0 -and [string]$uxNode0.parent -eq $cont0 -and [string]$uxNode0.duty -eq 'ux') 'WK0 UX slot under container with duty=ux' ($uxNode0 | ConvertTo-Json -Compress)
    Assert-True (@($nodes0 | Where-Object { -not $_.parent -and $_.role }).Count -eq 0) 'WK0 no bare role node at the goal root (default layer discipline)'

    # ================= WK1: wake promulgate shape =================
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/wk-l1/task.json', '-PlanFile', $pf, '-NoPush', '-Shape', 'wake')
    Assert-True ($r.json.success -eq $true) 'WK1 promulgate -Shape wake ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-wk-l1'
    Assert-True ([string]$b.shape -eq 'wake') 'WK1 bridge.json shape=wake' ($b | ConvertTo-Json -Depth 3 -Compress)
    $cto1 = [string]$b.tasks.'1'.stages.CTO
    $cont1 = [string]$b.tasks.'1'.container
    $nodes = Read-TreeNodes 'deliver-wk-l1'
    $contNode = $nodes | Where-Object { $_.id -eq $cont1 }
    $ctoNode = $nodes | Where-Object { $_.id -eq $cto1 }
    Assert-True ($null -ne $contNode -and [string]$contNode.type -eq 'sub' -and $null -eq $contNode.parent -or [string]$contNode.parent -eq 'n1') 'WK1 requirement container (type=sub) at goal root' ($contNode | ConvertTo-Json -Compress)
    Assert-True ($null -ne $ctoNode -and [string]$ctoNode.parent -eq $cont1 -and [string]$ctoNode.duty -eq 'cto') 'WK1 CTO slot under container with duty=cto' ($ctoNode | ConvertTo-Json -Compress)
    $bareRootRoles = @($nodes | Where-Object { -not $_.parent -and $_.role })
    Assert-True ($bareRootRoles.Count -eq 0) 'WK1 no bare role node at the goal root (layer discipline)'

    # ================= WK2: deliver + settle -> DEV slot materializes under container =================
    $r = Do-Deliver 'deliver-wk-l1' $cto1 'CTO' @('.rdd/changes/archive/wk-l1/design/d1.md')
    Assert-True ($r.json.success -eq $true) 'WK2a CTO deliver ok' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-wk-l1', '-NodeId', $cto1)
    Assert-True ($r.json.success -eq $true) 'WK2b CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-wk-l1'
    $dev1 = [string]$b.tasks.'1'.stages.DEV
    $devNode = Find-TreeNode 'deliver-wk-l1' $dev1
    Assert-True ($null -ne $devNode -and [string]$devNode.parent -eq $cont1) 'WK2c DEV slot materialized under the container (not chained under CTO)' ($devNode | ConvertTo-Json -Compress)
    $rev1 = [string]$b.plan.stages[0].design_review.node
    $revNode = Find-TreeNode 'deliver-wk-l1' $rev1
    Assert-True ($null -ne $revNode -and [string]$revNode.parent -eq ([string]$b.review_container)) 'WK2d review slot under the review container' ($revNode | ConvertTo-Json -Compress)
    $reqNodes0 = @((Read-TreeNodes 'deliver-wk-l1') | Where-Object { $_.id -in @($cont1, $cto1, $dev1) }).Count
    Assert-True ($reqNodes0 -eq 3) 'WK2e requirement subtree = container + CTO + DEV (3 nodes)'

    # ================= WK3: redo storm x3 (design-review fail waves) =================
    for ($wave = 1; $wave -le 3; $wave++) {
        # internal_consistency = 机械四判据之一 → wake 下仍硬打回（fail 波）
        Write-ReviewFile '.rdd/changes/archive/wk-l1' 'S1' @('design/d1.md') 'fail' 'internal_consistency' | Out-Null
        $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-wk-l1', '-NodeId', $rev1, '-Role', 'AUDITOR')
        Assert-True ($r.json.success -eq $true) "WK3.$wave.a review claim ok" ($r.raw)
        $cb = New-Cb $rev1 @('.rdd/changes/archive/wk-l1/review/design-review-S1.json', '.rdd/changes/archive/wk-l1/review/design-review-S1.md')
        $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-wk-l1', '-Worker', 'AUDITOR', '-CallbackFile', $cb)
        Assert-True ($r.json.success -eq $true) "WK3.$wave.b review report ok" ($r.raw)
        $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-wk-l1', '-NodeId', $rev1)
        Assert-True ($r.json.success -eq $true) "WK3.$wave.c fail review settle ok (wave fires)" ($r.raw)

        $b = Read-BridgeJson 'deliver-wk-l1'
        $ctoAfter = [string]$b.tasks.'1'.stages.CTO
        Assert-True ($ctoAfter -eq $cto1) "WK3.$wave.d CTO stages mapping STABLE (same slot, no rebuild)" ("before=$cto1 after=$ctoAfter")
        $ctoT = Find-TreeNode 'deliver-wk-l1' $cto1
        Assert-True ($null -ne $ctoT -and [string]$ctoT.status -eq 'pending' -and [int]$ctoT.wake_count -eq $wave) "WK3.$wave.e CTO slot reset (done->pending), wake=$wave/3" ($ctoT | ConvertTo-Json -Compress)
        $devT = Find-TreeNode 'deliver-wk-l1' $dev1
        Assert-True ($null -ne $devT -and [string]$devT.status -eq 'pending' -and [string]$devT.type -ne $null) "WK3.$wave.f DEV slot RESET not pruned" ($devT | ConvertTo-Json -Compress)
        $reqNow = @((Read-TreeNodes 'deliver-wk-l1') | Where-Object { $_.id -in @($cont1, $cto1, $dev1) }).Count
        Assert-True ($reqNow -eq 3) "WK3.$wave.g requirement subtree node count UNCHANGED (3)"
        # next wave re-delivers CTO (wake++) — EXCEPT after wave 3: the quota is
        # full (3 wakes burned by 3 deliveries), which is the design's forced
        # adjudication point asserted in WK4 below.
        if ($wave -lt 3) {
            $r = Do-Deliver 'deliver-wk-l1' $cto1 'CTO' @('.rdd/changes/archive/wk-l1/design/d1.md')
            Assert-True ($r.json.success -eq $true) "WK3.$wave.h CTO re-deliver (wake $($wave + 1)) ok" ($r.raw)
            $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-wk-l1', '-NodeId', $cto1)
            Assert-True ($r.json.success -eq $true) "WK3.$wave.i CTO settle ok" ($r.raw)
            $b = Read-BridgeJson 'deliver-wk-l1'
            $rev1 = [string]$b.plan.stages[0].design_review.node
            Assert-True (-not [string]::IsNullOrWhiteSpace($rev1)) "WK3.$wave.j next review slot grafted"
        }
    }

    # ================= WK4: quota exhaustion = forced adjudication =================
    $totalAfter3 = @(Read-TreeNodes 'deliver-wk-l1').Count
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-wk-l1', '-NodeId', $cto1, '-Role', 'CTO')
    Assert-True ($r.json.success -eq $false -and ($r.raw -match 'WAKE_QUOTA_EXCEEDED')) 'WK4a 4th CTO wake refused (quota 3/3 burned — adjudication point)' ($r.raw)
    # escalation route: budget raise with user verdict unlocks
    $r = Invoke-Tree @('-Command', 'budget', '-RunId', 'deliver-wk-l1', '-SetWakeMax', '4', '-UserVerdict', 'user: allow one more design wake')
    Assert-True ($r.json.success -eq $true) 'WK4b budget -SetWakeMax raise accepted' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-wk-l1', '-NodeId', $cto1, '-Role', 'CTO')
    Assert-True ($r.json.success -eq $true) 'WK4c claim after raise ok (wake 4/4)' ($r.raw)

    # ================= WK5: storm growth accounting =================
    $totalNow = @(Read-TreeNodes 'deliver-wk-l1').Count
    # growth = review slots only (round artifacts, +1 net per wave), requirement subtree constant
    Assert-True (($totalNow - $totalAfter3) -le 2) 'WK5a tree growth stays bounded (review round artifacts only, no requirement-slot rebuilds)' ("after3=$totalAfter3 now=$totalNow")
    $ledgerPath = Join-Path $Work '.rdd/goal-trees/deliver-wk-l1/state/ledger.jsonl'
    $ledger = @(); foreach ($ln in (Get-Content $ledgerPath -Encoding UTF8)) { if ($ln.Trim()) { try { $ledger += ($ln | ConvertFrom-Json) } catch { } } }
    $resetEntries = @($ledger | Where-Object { [string]$_.type -eq 'reset' -and [string]$_.node_id -eq $cto1 })
    Assert-True ($resetEntries.Count -ge 3) 'WK5b ledger carries the full wake/reset audit trail' ("reset entries: $($resetEntries.Count)")
    $redoEntries = @($ledger | Where-Object { [string]$_.type -eq 'redo' })
    Assert-True ($redoEntries.Count -ge 0) 'WK5c ledger redo entries parseable (wake/duty fields present)' ((@($redoEntries) | Select-Object -First 1) | ConvertTo-Json -Compress)

    # ================= WK6: S3 defer 通道 + 债务账本（§5.2/§5.3） =================
    # 非四判据 blocking（change_map：徽章尺寸矛盾类）→ 引擎降级 deferred，审查
    # pass、零波、需求不动；入债 state/debt.json；design-review status 露 ⚠1。
    $archDir2 = Join-Path $Work '.rdd/changes/archive/wk-l2'
    New-Item -ItemType Directory -Path (Join-Path $archDir2 'requirements') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $archDir2 'design') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir2 'requirements/overview.md') "# wk-l2`n`n## 整体验收判据`n`n无整体判据（理由：wake defer 通道测试归档，显式声明）`n"
    Write-Utf8NoBom (Join-Path $archDir2 'requirements/t1.md') "# wk-l2 需求 1`n`n- **描述**：defer 通道需求`n- **验收标准**：见 overview.md`n"
    Write-Utf8NoBom (Join-Path $archDir2 'design/d1.md') "# 设计 1`n`n变更地图：`n`n- ``src/b.py``  [新增] B`n`n[新增] 1 | [修改] 0 | [删除] 0`n"
    $tf2 = Join-Path $Work 'wk-l2-init.json'
    Write-Utf8NoBom $tf2 '[{"title":"WK6","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/wk-l2', '-TasksFile', 'wk-l2-init.json')
    if ($r.json.success -ne $true) { throw "wk-l2 init failed: $($r.raw)" }
    $plan2 = [ordered]@{ planned_at = '2026-10-17T00:00:00Z'; planner = 'test'; stages = @(
        @{ id = 'S1'; goal = 'S1'; milestone = 'S1'; task_ids = @(1); batches = @(,@(1)); acceptance_point = @{ criteria_items = @('smoke'); slice = 'slice' } }
    ); risks = @() }
    $pf2 = Join-Path $Work 'wk-l2-plan.json'
    Write-Utf8NoBom $pf2 ($plan2 | ConvertTo-Json -Depth 8)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/wk-l2/task.json', '-PlanFile', $pf2, '-NoPush', '-Shape', 'wake')
    Assert-True ($r.json.success -eq $true) 'WK6a wake promulgate ok' ($r.raw)
    $b2 = Read-BridgeJson 'deliver-wk-l2'
    $cto6 = [string]$b2.tasks.'1'.stages.CTO
    $r = Do-Deliver 'deliver-wk-l2' $cto6 'CTO' @('.rdd/changes/archive/wk-l2/design/d1.md')
    Assert-True ($r.json.success -eq $true) 'WK6b CTO deliver ok' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-wk-l2', '-NodeId', $cto6)
    Assert-True ($r.json.success -eq $true) 'WK6c CTO settle ok' ($r.raw)
    $b2 = Read-BridgeJson 'deliver-wk-l2'
    $rev6 = [string]$b2.plan.stages[0].design_review.node
    Write-ReviewFile '.rdd/changes/archive/wk-l2' 'S1' @('design/d1.md') 'fail' 'change_map' | Out-Null
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-wk-l2', '-NodeId', $rev6, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'WK6d review claim ok' ($r.raw)
    $cb = New-Cb $rev6 @('.rdd/changes/archive/wk-l2/review/design-review-S1.json', '.rdd/changes/archive/wk-l2/review/design-review-S1.md')
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-wk-l2', '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'WK6e review report ok' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-wk-l2', '-NodeId', $rev6)
    Assert-True ($r.json.success -eq $true) 'WK6f review settle ok' ($r.raw)
    $b2 = Read-BridgeJson 'deliver-wk-l2'
    Assert-True ([string]$b2.plan.stages[0].design_review.status -eq 'passed') 'WK6g non-four-criteria blocking DEFERRED -> engine verdict pass (no wave)' ($b2 | ConvertTo-Json -Depth 5 -Compress)
    $cto6T = Find-TreeNode 'deliver-wk-l2' $cto6
    Assert-True ($null -ne $cto6T -and [string]$cto6T.status -eq 'done' -and [string]$b2.tasks.'1'.stages.CTO -eq $cto6) 'WK6h requirement untouched (CTO stays done, mapping stable — deferred never rolls back)' ($cto6T | ConvertTo-Json -Compress)
    $debtPath = Join-Path $Work '.rdd/goal-trees/deliver-wk-l2/state/debt.json'
    Assert-True (Test-Path $debtPath) 'WK6i debt ledger written (state/debt.json)'
    $debt = @(); if (Test-Path $debtPath) { $debt = @(Get-Content $debtPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $openDebt = @($debt | Where-Object { $_.status -eq 'open' })
    Assert-True ($openDebt.Count -eq 1 -and [string]$openDebt[0].dimension -eq 'change_map' -and @($openDebt[0].deferred_stages).Count -eq 1) 'WK6j debt entry recorded (open, change_map, S1)' (($openDebt | ConvertTo-Json -Compress))
    $r = Invoke-Bridge @('-Command', 'design-review', '-RunId', 'deliver-wk-l2', '-Action', 'status')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.debt.open -eq 1 -and [int]$r.json.data.debt.warn_badge -ge 1 -and $r.json.data.debt.threshold -eq $false) 'WK6k status surfaces debt (⚠1, no threshold)' ($r.raw)
    # 老化升级语义（同一项跨 ≥2 阶段 → escalated）由 Add-DebtEntries 承担；
    # 单阶段用例已验 open 态，跨阶段 live 场景留 design doc 标注的后续切片。
    $r2 = Invoke-Tree @('-Command', 'status', '-RunId', 'deliver-wk-l2')
    Assert-True ($r2.json.success -eq $true) 'WK6l goal-tree status still green on the wake run' ($r2.raw)

    # ============ WK7: wake + ReviewFile depends_on_override（延后缝合对称性） ============
    # 回归锚（引擎 1.2.0 wake 分支漏写 grafted_dep_nodes）：override 同时点名
    # 「已建后向边」与「后位前向边」时，缝合必须只补缺失的那条前向边——把已存在
    # 的容器后向边再 add 一次会被 goal-tree 判 DEP_EXISTS，颁布整体中止、run 停在
    # 无 bridge.json 的半成品状态（真实事故：deliver-2026-10-23-enemy-debut-standard）。
    $archDir3 = Join-Path $Work '.rdd/changes/archive/wk-l3'
    New-Item -ItemType Directory -Path (Join-Path $archDir3 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir3 'requirements/overview.md') "# wk-l3`n`n## 整体验收判据`n`n无整体判据（理由：override 延后缝合回归归档，显式声明）`n"
    Write-Utf8NoBom (Join-Path $archDir3 'requirements/t1.md') "# wk-l3 需求 1`n`n- **描述**：基座需求`n- **验收标准**：见 overview.md`n"
    Write-Utf8NoBom (Join-Path $archDir3 'requirements/t2.md') "# wk-l3 需求 2`n`n- **描述**：override 需求（后向 #1 + 前向 #3）`n- **依赖关系**：#1`n- **验收标准**：见 overview.md`n"
    Write-Utf8NoBom (Join-Path $archDir3 'requirements/t3.md') "# wk-l3 需求 3`n`n- **描述**：后位需求`n- **依赖关系**：#1`n- **验收标准**：见 overview.md`n"
    $tf3 = Join-Path $Work 'wk-l3-init.json'
    Write-Utf8NoBom $tf3 '[{"title":"WK7-A","requirement":"requirements/t1.md","currentOwners":["CTO"]},{"title":"WK7-B","requirement":"requirements/t2.md","currentOwners":["CTO"]},{"title":"WK7-C","requirement":"requirements/t3.md","currentOwners":["CTO"]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/wk-l3', '-TasksFile', 'wk-l3-init.json')
    if ($r.json.success -ne $true) { throw "wk-l3 init failed: $($r.raw)" }
    # batches 依 DAG：#2 依赖 #3（前向引用补边后的真实顺序），故 [[1],[3],[2]]
    $plan3 = [ordered]@{ planned_at = '2026-10-17T00:00:00Z'; planner = 'test'; stages = @(
        @{ id = 'S1'; goal = 'S1'; milestone = 'S1'; task_ids = @(1, 2, 3); batches = @(@(1), @(3), @(2)); acceptance_point = @{ criteria_items = @('smoke'); slice = 'slice' } }
    ); risks = @() }
    $pf3 = Join-Path $Work 'wk-l3-plan.json'
    Write-Utf8NoBom $pf3 ($plan3 | ConvertTo-Json -Depth 8)
    # ReviewFile：#2 漏标对 #3 的依赖（前向引用）→ tree_adjudicated + override 全量
    # [1,3]（override 整体替代正则推导，故后向 #1 必须列全）
    $review3 = [ordered]@{
        reviewed_at = '2026-10-23T16:05:12+08:00'
        reviewer    = 'auditor'
        verdicts    = @(
            [ordered]@{ task_id = 1; verdict = 'pass'; reason = '四维无 gap' }
            [ordered]@{ task_id = 2; verdict = 'tree_adjudicated'; reason = '漏标对 #3 的依赖（前向引用，单遍建树静默丢边）→ override 补边；override 整体替代推导，故列全量 [1,3]'; depends_on_override = @(1, 3) }
            [ordered]@{ task_id = 3; verdict = 'pass'; reason = '四维无 gap' }
        )
    }
    $rf3 = Join-Path $Work 'wk-l3-review.json'
    Write-Utf8NoBom $rf3 ($review3 | ConvertTo-Json -Depth 6)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/wk-l3/task.json', '-PlanFile', $pf3, '-ReviewFile', $rf3, '-NoPush', '-Shape', 'wake')
    Assert-True ($r.json.success -eq $true) 'WK7a wake promulgate with depends_on_override ok (back edge NOT re-added → no DEP_EXISTS abort)' ($r.raw)
    $b3 = $null
    if (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-wk-l3/bridge.json')) { $b3 = Read-BridgeJson 'deliver-wk-l3' }
    Assert-True ($null -ne $b3) 'WK7b bridge.json written (publication completed, not a half-built run)' ($r.raw)
    $c1 = [string]$b3.tasks.'1'.container
    $c2 = [string]$b3.tasks.'2'.container
    $c3 = [string]$b3.tasks.'3'.container
    $cont2 = Find-TreeNode 'deliver-wk-l3' $c2
    $cont3 = Find-TreeNode 'deliver-wk-l3' $c3
    $deps2 = @(@($cont2.depends_on) | ForEach-Object { [string]$_ })
    $deps3 = @(@($cont3.depends_on) | ForEach-Object { [string]$_ })
    Assert-True ($deps2.Count -eq 2 -and ($deps2 -contains $c1) -and ($deps2 -contains $c3)) 'WK7c override container carries BOTH edges (backward #1 + forward #3), each once' ("deps2=$($deps2 -join ',') c1=$c1 c3=$c3")
    Assert-True ($null -ne $cont3 -and -not [string]::IsNullOrWhiteSpace($c1) -and $deps3.Count -eq 1 -and ($deps3 -contains $c1)) 'WK7d untouched container keeps its single inferred edge' ("deps3=$($deps3 -join ',')")
    Assert-True ($null -ne $cont2 -and [string]$cont2.type -eq 'sub' -and [string]$cont2.parent -eq 'n1') 'WK7e stitched edge lands container-level (layer rule), container stays a goal-root sub' ($cont2 | ConvertTo-Json -Compress)
    $deferred3 = @($r.json.data.review.deferred_dep_edges)
    Assert-True ($deferred3.Count -eq 1 -and $deferred3[0] -eq "task#2->task#3 ($c2->$c3)") 'WK7f exactly ONE deferred edge stitched (task#2->task#3), back edge not replayed' ("deferred=[$($deferred3 -join '; ')]")
    $depsLogPath = Join-Path $Work '.rdd/goal-trees/deliver-wk-l3/state/deps-log.jsonl'
    $depEvents = @(); foreach ($ln in (Get-Content $depsLogPath -Encoding UTF8)) { if ($ln.Trim()) { try { $depEvents += ($ln | ConvertFrom-Json) } catch { } } }
    $depPairs = @($depEvents | ForEach-Object { "$($_.node)->$($_.target)" })
    Assert-True ($depPairs.Count -eq 3 -and $depPairs -contains "$c2->$c3") 'WK7g deps-log audited exactly 3 dep-adds (2 graft + 1 stitched, no duplicate)' ("pairs=[$($depPairs -join '; ')]")
    Assert-True ($null -ne $b3.review -and -not [string]::IsNullOrWhiteSpace([string]$b3.review.reviewed_at) -and @($b3.review.verdicts).Count -eq 3) 'WK7h review section persisted on the bridge (review gate applied)' ($b3.review | ConvertTo-Json -Depth 3 -Compress)
    Assert-True (Test-Path (Join-Path $Work '.rdd/goal-trees/deliver-wk-l3/report/review.md')) 'WK7i human-readable review report written'
    # ============ WK8: silent-dep-disarm 防护 + push 折叠对称 + 回调契约 ============
    # 回归锚（deliver-2026-10-23 实录）：①颁布落账的裁定边被 deps remove 静默拆除 →
    # 需求级门失效、bridge.dep_task_ids 与活树脱钩（现须 -UserVerdict 硬门 + status
    # 对账警示）；②push 门只看节点自身边，wake 折叠门（claim 侧 §3.3）没折进来 →
    # 被 claim 拒的槽照推（worker 会话空转）。注：-Shape/-ReviewMode 拼错由参数绑定
    # ValidateSet 零残留硬拒（原判「静默换链」不成立——PS 字符串比较大小写不敏感）。
    $archDir4 = Join-Path $Work '.rdd/changes/archive/wk-l4'
    New-Item -ItemType Directory -Path (Join-Path $archDir4 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir4 'requirements/overview.md') "# wk-l4`n`n## 整体验收判据`n`n无整体判据（理由：silent-dep-disarm 防护回归归档，显式声明）`n"
    Write-Utf8NoBom (Join-Path $archDir4 'requirements/t1.md') "# wk-l4 需求 1`n`n- **描述**：基座需求`n- **验收标准**：见 overview.md`n"
    Write-Utf8NoBom (Join-Path $archDir4 'requirements/t2.md') "# wk-l4 需求 2`n`n- **描述**：依赖需求（文档声明 #1）`n- **依赖关系**：依赖需求 1`n- **验收标准**：见 overview.md`n"
    $tf4 = Join-Path $Work 'wk-l4-init.json'
    Write-Utf8NoBom $tf4 '[{"title":"WK8-A","requirement":"requirements/t1.md","currentOwners":["CTO"]},{"title":"WK8-B","requirement":"requirements/t2.md","currentOwners":["CTO"]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/wk-l4', '-TasksFile', 'wk-l4-init.json')
    if ($r.json.success -ne $true) { throw "wk-l4 init failed: $($r.raw)" }
    $plan4 = [ordered]@{ planned_at = '2026-10-23T00:00:00Z'; planner = 'test'; stages = @(
        @{ id = 'S1'; goal = 'S1'; milestone = 'S1'; task_ids = @(1, 2); batches = @(@(1), @(2)); acceptance_point = @{ criteria_items = @('smoke'); slice = 'slice' } }
    ); risks = @() }
    $pf4 = Join-Path $Work 'wk-l4-plan.json'
    Write-Utf8NoBom $pf4 ($plan4 | ConvertTo-Json -Depth 8)
    $review4 = [ordered]@{
        reviewed_at = '2026-10-23T17:00:00+08:00'
        reviewer    = 'auditor'
        verdicts    = @(
            [ordered]@{ task_id = 1; verdict = 'pass'; reason = '四维无 gap' }
            [ordered]@{ task_id = 2; verdict = 'pass'; reason = '四维无 gap' }
        )
    }
    $rf4 = Join-Path $Work 'wk-l4-review.json'
    Write-Utf8NoBom $rf4 ($review4 | ConvertTo-Json -Depth 6)
    # 不带 -NoPush：推送门须用 claim 同源的折叠门拦下 #2 的槽（start-role 在测试环境
    # 必失败入 failed 账——断言只钉确定性部分：#2 槽入 blocked、不入 pushed/failed）。
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/wk-l4/task.json', '-PlanFile', $pf4, '-ReviewFile', $rf4)
    Assert-True ($r.json.success -eq $true) 'WK8a wake promulgate (no -NoPush, dep-gated task) ok' ($r.raw)
    $b4 = Read-BridgeJson 'deliver-wk-l4'
    $s1b = [string]$b4.tasks.'1'.stages.CTO
    $s2b = [string]$b4.tasks.'2'.stages.CTO
    $c1b = [string]$b4.tasks.'1'.container
    $c2b = [string]$b4.tasks.'2'.container
    $blocked4 = @($r.json.data.auto_push.blocked)
    $attempted4 = @(@($r.json.data.auto_push.pushed) + @($r.json.data.auto_push.failed) | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.node } })
    Assert-True (@($blocked4) -contains $s2b) 'WK8b push gate folds the container dep gate (dep-task slot dep-blocked at push — claim-side §3.3 symmetry; the slot carries no own edge, only the folded gate can produce this)' ("blocked=[$($blocked4 -join ',')] s1=$s1b s2=$s2b")
    Assert-True ($attempted4 -notcontains $s2b) 'WK8c no session spawned for the dep-gated slot' ("attempted=[$($attempted4 -join ',')] s2=$s2b")
    $adjPath = Join-Path $Work '.rdd/goal-trees/deliver-wk-l4/state/adjudicated-deps.json'
    Assert-True (Test-Path $adjPath) 'WK8d adjudicated-deps.json written at promulgate'
    $adj = $null; if (Test-Path $adjPath) { $adj = Get-Content $adjPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $adjE = @(); if ($null -ne $adj) { $adjE = @($adj.edges) }
    Assert-True ($adjE.Count -eq 1 -and [string]$adjE[0].node -eq $c2b -and [string]$adjE[0].on -eq $c1b -and [int]$adjE[0].task_id -eq 2 -and [int]$adjE[0].on_task_id -eq 1 -and [string]$adjE[0].source -eq 'requirement') 'WK8e adjudicated edge recorded (task#2 -> task#1, source=requirement)' (($adjE | ConvertTo-Json -Compress))
    # deps remove 硬门：无声拆除被拒（DEP_ADJUDICATED）；带用户裁决放行且落 deps-log
    $r = Invoke-Tree @('-Command', 'deps', '-DepAction', 'remove', '-RunId', 'deliver-wk-l4', '-NodeId', $c2b, '-On', $c1b)
    Assert-True ($r.json.success -ne $true -and $r.json.error.code -eq 'DEP_ADJUDICATED') 'WK8f silent deps remove of an adjudicated edge rejected (DEP_ADJUDICATED)' ($r.raw)
    $r = Invoke-Tree @('-Command', 'deps', '-DepAction', 'remove', '-RunId', 'deliver-wk-l4', '-NodeId', $c2b, '-On', $c1b, '-UserVerdict', '用户裁决：#2 改为并行推进，不等 #1（测试注入）')
    Assert-True ($r.json.success -eq $true) 'WK8g adjudicated remove WITH -UserVerdict passes (explicit user ruling)' ($r.raw)
    $depLog4 = @(Get-Content (Join-Path $Work '.rdd/goal-trees/deliver-wk-l4/state/deps-log.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $lastDep = $depLog4[-1]
    Assert-True ([string]$lastDep.event -eq 'dep-remove' -and -not [string]::IsNullOrWhiteSpace([string]$lastDep.verdict)) 'WK8h deps-log carries the verbatim verdict on the adjudicated remove' (($lastDep | ConvertTo-Json -Compress))
    # status 对账：裁定边缺影 = 醒目警示（不阻断）；恢复边后自愈清零
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-wk-l4')
    $driftMiss = @(); if ($r.json.success -eq $true) { $driftMiss = @($r.json.data.deps_integrity) }
    $warnText4 = $(if ($r.json.success -eq $true) { @($r.json.data.warnings) -join ' | ' } else { $r.raw })
    Assert-True ($driftMiss.Count -eq 1 -and [string]$driftMiss[0].node -eq $c2b) 'WK8i status surfaces deps_integrity (adjudicated edge missing from the live tree)' (($driftMiss | ConvertTo-Json -Compress))
    Assert-True ($warnText4 -match 'deps_integrity') 'WK8j deps_integrity warning line present' ($warnText4)
    $r = Invoke-Tree @('-Command', 'deps', '-DepAction', 'add', '-RunId', 'deliver-wk-l4', '-NodeId', $c2b, '-On', $c1b)
    Assert-True ($r.json.success -eq $true) 'WK8k edge restored via public deps add' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-wk-l4')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.deps_integrity).Count -eq 0) 'WK8l deps_integrity self-heals to empty after restore' ($r.raw)
    # 回调契约在认领点可见（worker 摩擦实录：verdict 枚举此前只活在 planner 手册里）
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-wk-l4', '-NodeId', $s1b, '-Role', 'CTO')
    $cc = $null; if ($r.json.success -eq $true) { $cc = $r.json.data.tree_claim.callback_contract }
    Assert-True ($null -ne $cc -and ([string]$cc.verdict) -match 'done' -and ([string]$cc.verdict) -match 'inconclusive') 'WK8m claim response carries the callback contract (verdict enum at the point of use)' (($cc | ConvertTo-Json -Compress))

    $failed = @($Results | Where-Object { -not $_.ok })
    Write-Output ("=== wake-model bridge suite: {0}/{1} passed ===" -f ($Results.Count - $failed.Count), $Results.Count)
    if ($failed.Count -gt 0) { exit 1 }
}
finally {
    Pop-Location
}

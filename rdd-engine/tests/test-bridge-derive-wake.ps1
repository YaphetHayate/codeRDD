# wake-shape mid-run derive tests — derive 受控入册 wake 形状全链回归锚。
# 缺陷背景（2026-10-26 level-mode-optimization run 第三处缺陷）：wake 形状下
# DESIGN 链头嫁接固定挂 PM 节点 → ROLE_LAYER_LOCKED 确定性失败；失败路径零
# 落盘 → 巡检重入无限复现同一错误，派生任务链永不物化。
#   WD0  wake 缺省颁布（2 DEV 任务，overview 判据齐）
#   WD1  propose（-DependsOn 1,2 -Owners CTO+QA 缩窄）
#   WD2  confirm → PM 节点（goal 根 pm 槽——wake 层规则的唯一根级槽例外）
#   WD3  PM settle 受控入册：需求容器（type=sub @ goal 根，WBS 容器层依赖边
#        = 依赖任务容器）+ CTO/QA 槽（duty）挂容器下 + bridge.tasks container/
#        stages 映射 + derivations registered——不出现 ROLE_LAYER_LOCKED
#        （flow_operation 即判别器：旧缺陷卡 'registration pending patrol'）
#   WD4  闸门 hold：unabsorbed → 派生槽 dispatch NODE_BLOCKED_BY_GATE
#   WD5  replan 吸收（单阶段 [1,2,3]）→ absorbed 标记；依赖任务在途 →
#        goal-tree dispatch 折叠容器边 NODE_BLOCKED_BY_DEPS（任务级依赖语义）
#   WD6  依赖任务 1,2 跑到终态（DEV→QA）
#   WD7  一次 status touch → 派生 DESIGN 槽进入推送（dead URL：attempts 记账）
#   WD8  事故态重放（映射丢失 + 树剪 + confirmed/task_id=null/absorbed 清除）：
#        status 巡检一次收敛——不重复建任务/容器，absorbed 即时补标
#        （replan 先行、入册后到的时序窗）
#   WD9  分段中间态重放（容器已录 + 槽缺失）：status 巡检只补槽，容器 id 不变
#   WD10 DESIGN 收敛 → IMPL 槽挂同一容器（容器锚点喂后续阶段，与 promulgate
#        产物同构）
#   WD11 BOM 自检（tips 义务：编辑过的 .ps1 必须 BOM 头）
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# planner-claim-guard（与 test-bridge-derive 同惯例）：清空 DSH_SESSION_ID，
# 夹具 claim 不被身份门判成「规划者代跑」。
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('bridge-derive-wake-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
    (Get-Content -LiteralPath (Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')) -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Read-TreeNodes { param([string]$RunId)
    @((Get-Content -LiteralPath (Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')) -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Read-Tasks { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/task.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
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

function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'bridge-derive-wake test delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: no PowerShell in change set' } }
    }
    $cbFile = Join-Path $env:TEMP ("wd-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
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
function Complete-DevTask { param([string]$RunId, [int]$TaskId, [string]$ReqPath)
    $b = Read-BridgeJson $RunId
    $dev = [string]$b.tasks."$TaskId".stages.DEV
    if ($dev -eq '') { throw "task $TaskId DEV slot missing" }
    Do-Deliver $RunId $dev 'DEV' @($ReqPath)
    $null = Do-Settle $RunId $dev
    $b = Read-BridgeJson $RunId
    $qa = [string]$b.tasks."$TaskId".stages.QA
    if ($qa -eq '') { throw "task $TaskId QA verify slot missing after DEV settle" }
    Do-Deliver $RunId $qa 'QA' @($ReqPath)
    $null = Do-Settle $RunId $qa
}

# 归档 fixture：2 DEV 任务 + overview 整体验收判据（>=2 任务颁布即要求判据）
$arch = '.rdd/changes/archive/wd-main'
$archDir = Join-Path $Work $arch
New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# wd-main`n`nwake derive 测试归档。`n`n## 整体验收判据`n`n| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |`n|---|------|------|------|`n| 1 | 端到端跑通 | demo 实证 | 主需求1、主需求2 |`n"
Write-Utf8NoBom (Join-Path $archDir 'requirements/t1.md') "# 主需求1`n`n- **描述**：wake derive 主需求 1`n- **验收标准**：见 overview.md`n"
Write-Utf8NoBom (Join-Path $archDir 'requirements/t2.md') "# 主需求2`n`n- **描述**：wake derive 主需求 2`n- **验收标准**：见 overview.md`n"
$tasksJson = '[{"title":"主需求1","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]},{"title":"主需求2","requirement":"requirements/t2.md","currentOwners":["DEV"],"designDocs":[]}]'
$tf = Join-Path $Work 'wd-main-init.json'
Write-Utf8NoBom $tf $tasksJson
$CriteriaRef = 'requirements/overview.md#整体验收判据'

function Write-WdPlan { param([string]$Path, [int[][]]$BatchSets)
    $batches = @($BatchSets | ForEach-Object { , @($_ | ForEach-Object { [int]$_ }) })
    $stageObjs = @(
        @{
            id = 'S1'; goal = 'stage S1 目标'; milestone = 'S1 里程碑'
            task_ids = @(@($BatchSets) | ForEach-Object { $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
            batches = $batches
            acceptance_point = @{ criteria_ref = $CriteriaRef; criteria_items = @('smoke: core flow works'); slice = 'runnable slice' }
        }
    )
    $plan = [ordered]@{ planned_at = '2026-10-26T00:00:00Z'; planner = 'test'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
# dead dsh URL: auto-push fails instantly (attempts are accounted, gate-held nodes never attempt)
$env:DSH_WEB_URL = 'http://127.0.0.1:1'
Push-Location $Work
try {
    $r = Invoke-Flow @('-Command', 'init', '-Archive', $arch, '-TasksFile', 'wd-main-init.json')
    if ($r.json.success -ne $true) { throw "init failed: $($r.raw)" }

    # ================= WD0: wake 缺省颁布 =================
    $pf = Write-WdPlan (Join-Path $Work 'wd-main-plan.json') @(@(1), @(2))
    # -MaxNodes/-NodeWidth：预留派生预算（planner-guide 口径：预期派生的 run 颁布时
    # 预留——缺省 2*5+6=17 会被 WD8/WD9 的重放重挂打满（剪枝不释放节点计数））。
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch + '/task.json'), '-PlanFile', $pf, '-MaxNodes', '48', '-NodeWidth', '12')
    Assert-True ($r.json.success -eq $true) 'WD0 promulgate (default shape) ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    Assert-True ([string]$b.shape -eq 'wake') 'WD0 bridge.json shape=wake (default)' ($b | ConvertTo-Json -Depth 3 -Compress)
    $cont1 = [string]$b.tasks.'1'.container
    $cont2 = [string]$b.tasks.'2'.container
    Assert-True ($cont1 -ne '' -and $cont2 -ne '') 'WD0 native task containers recorded'

    # ================= WD1: propose（缩窄 owners + 双依赖） =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-wd-main', '-Action', 'propose', '-Title', '派生W', '-Rationale', '真机兼容缺口（wake 全链回归）', '-DependsOn', '1,2', '-Owners', 'CTO+QA')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'proposed') 'WD1 propose ok (narrowed CTO+QA, deps 1,2)' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ($null -ne $d1 -and @($d1.depends_on).Count -eq 2 -and @($d1.owners) -contains 'CTO' -and @($d1.owners) -contains 'QA') 'WD1 derivation carries deps+owners' ($d1 | ConvertTo-Json -Compress)

    # ================= WD2: confirm → PM 节点（goal 根 pm 槽） =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-wd-main', '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意派生，并入当前 run')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'confirmed') 'WD2 confirm ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    $pmNode = [string]((Get-Der $b 'DRV1').node)
    Assert-True ($pmNode -ne '') 'WD2 derivation PM node grafted'
    $pmTree = Find-TreeNode 'deliver-wd-main' $pmNode
    Assert-True ($null -ne $pmTree -and [string]$pmTree.role -eq 'pm') 'WD2 PM node is the root-level pm slot (wake layer exception)' ($pmTree | ConvertTo-Json -Compress)

    # ================= WD3: PM settle → 受控入册（wake 容器+槽） =================
    Write-Utf8NoBom (Join-Path $archDir 'requirements/derive-w.md') "# 派生需求 W`n`n- **描述**：真机兼容修复`n- **验收标准**：真机可实证`n- **依赖关系**：依赖任务 #1、#2`n"
    Do-Deliver 'deliver-wd-main' $pmNode 'PM' @("$arch/requirements/derive-w.md", "$arch/requirements/overview.md")
    $r = Do-Settle 'deliver-wd-main' $pmNode
    Assert-True ($r.json.success -eq $true) 'WD3 PM node settle ok' ($r.raw)
    # 核心判别器：旧缺陷在此返回 'derivation settle landed, registration pending patrol'（ROLE_LAYER_LOCKED 降级警告）
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -match 'derivation registered') 'WD3 [核心] registration completed in-settle (no ROLE_LAYER_LOCKED path)' ([string]$r.json.data.flow_operation)
    Assert-True (@($r.json.data.warnings | Where-Object { $_ -match 'registration incomplete' }).Count -eq 0) 'WD3 no registration-incomplete warning' ((@($r.json.data.warnings) | ConvertTo-Json -Compress))
    $tasks = Read-Tasks $arch
    $t3 = @($tasks | Where-Object { [int]$_.id -eq 3 })[0]
    Assert-True ($null -ne $t3 -and @($t3.currentOwners) -contains 'CTO' -and @($t3.currentOwners) -contains 'QA' -and [string]$t3.phase -eq 'DESIGN' -and [string]$t3.requirement -eq 'requirements/derive-w.md') 'WD3 add-task issued (DESIGN, CTO+QA, requirement doc)' ((@($tasks) | ConvertTo-Json -Depth 4 -Compress))
    Assert-True ($null -ne $t3 -and [string]$t3.remark -match 'derivation=DRV1') 'WD3 remark idempotency anchor recorded'
    $b = Read-BridgeJson 'deliver-wd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ([string]$d1.status -eq 'registered' -and [int]$d1.task_id -eq 3) 'WD3 derivation registered (task #3)' ($d1 | ConvertTo-Json -Compress)
    $b3 = $b.tasks.'3'
    $derContainer = [string]$b3.container
    Assert-True ($derContainer -ne '') 'WD3 bridge.tasks container mapping present' ($b3 | ConvertTo-Json -Compress)
    Assert-True (@($b3.initial_group) -contains 'CTO' -and @($b3.initial_group) -contains 'QA' -and @($b3.dep_task_ids).Count -eq 2) 'WD3 bridge mapping initial_group + dep_task_ids' ($b3 | ConvertTo-Json -Compress)
    $ctoNode = [string]$b3.stages.CTO
    $qaNode = [string]$b3.stages.QA
    Assert-True ($ctoNode -ne '' -and $qaNode -ne '') 'WD3 DESIGN slots mapped (CTO/QA)' ($b3 | ConvertTo-Json -Compress)
    # 树侧：容器 type=sub @ goal 根，依赖边落 WBS 容器层；槽挂容器下带 duty
    $goalRoot = [string]$b.goal_root
    $cNode = Find-TreeNode 'deliver-wd-main' $derContainer
    Assert-True ($null -ne $cNode -and [string]$cNode.type -eq 'sub' -and [string]$cNode.parent -eq $goalRoot -and $null -eq $cNode.role) 'WD3 [核心] derived container type=sub at goal root (unclaimable WBS layer)' ($cNode | ConvertTo-Json -Compress)
    $depSorted = @(@($cNode.depends_on) | Sort-Object) -join ','
    $wantSorted = @(@($cont1, $cont2) | Sort-Object) -join ','
    Assert-True ($depSorted -eq $wantSorted) 'WD3 [核心] container dep edges = dep task containers (WBS layer, serialize-container-edges semantics)' ("got [$depSorted] want [$wantSorted]")
    $ctoTree = Find-TreeNode 'deliver-wd-main' $ctoNode
    $qaTree = Find-TreeNode 'deliver-wd-main' $qaNode
    Assert-True ($null -ne $ctoTree -and [string]$ctoTree.parent -eq $derContainer -and [string]$ctoTree.duty -eq 'cto' -and [string]$ctoTree.role -eq 'cto') 'WD3 [核心] CTO slot under container with duty=cto' ($ctoTree | ConvertTo-Json -Compress)
    Assert-True ($null -ne $qaTree -and [string]$qaTree.parent -eq $derContainer -and [string]$qaTree.duty -eq 'qa') 'WD3 QA slot under container with duty=qa' ($qaTree | ConvertTo-Json -Compress)
    Assert-True ($null -ne $ctoTree -and [string]$ctoTree.task -match '整体验收判据') 'WD3 slot task text carries the criteria anchor' ([string]$ctoTree.task)
    Assert-True (@((Read-TreeNodes 'deliver-wd-main') | Where-Object { $null -eq $_.parent -and $_.role }).Count -eq 0) 'WD3 layer discipline: no bare role node at the goal root'
    $plog = Read-PlanLog 'deliver-wd-main'
    Assert-True (@($plog | Where-Object { [string]$_.event -eq 'derivation_registered' }).Count -eq 1) 'WD3 plan-log derivation_registered recorded'

    # ================= WD4: 闸门 hold（未吸收不出队） =================
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-wd-main', '-NodeId', $ctoNode, '-DryRun')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_GATE') 'WD4 unabsorbed slot held (NODE_BLOCKED_BY_GATE)' ($r.raw)

    # ================= WD5: replan 吸收 + 依赖在途折叠门 =================
    $pf2 = Write-WdPlan (Join-Path $Work 'wd-main-plan2.json') @(@(1), @(2), @(3))
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-wd-main', '-PlanFile', $pf2, '-Reason', '吸收派生任务 #3')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.derivations_absorbed) -match 'DRV1') 'WD5 replan absorbs derivation' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    Assert-True ((Get-Der $b 'DRV1').absorbed -eq $true) 'WD5 bridge absorbed=true'
    # 依赖任务 1,2 在途：容器边折叠 → goal-tree dispatch 拒 NODE_BLOCKED_BY_DEPS（任务级依赖语义）
    $r = Invoke-Tree @('-Command', 'dispatch', '-RunId', 'deliver-wd-main', '-NodeId', $ctoNode, '-Role', 'CTO', '-DryRun')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_DEPS') 'WD5 folded container edge holds the slot while deps are in flight (NODE_BLOCKED_BY_DEPS)' ($r.raw)

    # ================= WD6: 依赖任务 1,2 → 终态 =================
    Complete-DevTask 'deliver-wd-main' 1 "$arch/requirements/t1.md"
    Complete-DevTask 'deliver-wd-main' 2 "$arch/requirements/t2.md"
    $tasks = Read-Tasks $arch
    Assert-True (@($tasks | Where-Object { [int]$_.id -in @(1, 2) -and [string]$_.lifecycle -eq 'completed' }).Count -eq 2) 'WD6 dep tasks terminal' ((@($tasks) | ForEach-Object { "$($_.id):$($_.lifecycle)" }) -join ',')

    # ================= WD7: 一次 status touch → 派生槽进入推送 =================
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-wd-main')
    Assert-True ($r.json.success -eq $true) 'WD7 status touch ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    $pushCto = $null
    if ($b.pushes -and $b.pushes.PSObject.Properties[$ctoNode]) { $pushCto = $b.pushes.PSObject.Properties[$ctoNode].Value }
    $attemptCount = 0
    if ($null -ne $pushCto -and $pushCto.attempts) { $attemptCount = @($pushCto.attempts).Count }
    Assert-True ($attemptCount -ge 1) 'WD7 [核心] derived CTO slot ENTERED the push pipeline (attempt accounted; gate+deps unlocked)' ($b.pushes | ConvertTo-Json -Depth 4 -Compress)

    # ================= WD8: 事故态重放（映射丢失 + 树剪 + confirmed） =================
    # 活跃 run 事故现场：task.json 已有 task 3（remark 锚点）、bridge 无 tasks['3']
    # 映射、derivations confirmed/task_id=null、树无 #3 节点——巡检须一次收敛。
    $bp = Join-Path $Work '.rdd/goal-trees/deliver-wd-main/bridge.json'
    $bj = Get-Content -LiteralPath $bp -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($sid in @($bj.tasks.'3'.stages.PSObject.Properties | ForEach-Object { [string]$_.Value })) {
        if ($bj.nodes.PSObject.Properties[$sid]) { $bj.nodes.PSObject.Properties.Remove($sid) }
    }
    $bj.tasks.PSObject.Properties.Remove('3')
    $bj.derivations[0].status = 'confirmed'
    $bj.derivations[0].task_id = $null
    foreach ($p in @('absorbed', 'absorbed_at', 'registered_at', 'requirement')) {
        if ($bj.derivations[0].PSObject.Properties[$p]) { $bj.derivations[0].PSObject.Properties.Remove($p) }
    }
    Write-Utf8NoBom $bp ($bj | ConvertTo-Json -Depth 10)
    $rp = Invoke-Tree @('-Command', 'prune', '-RunId', 'deliver-wd-main', '-NodeId', $derContainer, '-Reason', 'incident replay: derived subtree wiped (registration window)')
    Assert-True ($rp.json.success -eq $true) 'WD8 prune derived subtree (container cascade)' ($rp.raw)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-wd-main')
    Assert-True ($r.json.success -eq $true) 'WD8 status touch re-runs the patrol' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ([string]$d1.status -eq 'registered' -and [int]$d1.task_id -eq 3) 'WD8 [核心] patrol re-registered from the incident state' ($d1 | ConvertTo-Json -Compress)
    Assert-True ($d1.PSObject.Properties['absorbed'] -and $d1.absorbed -eq $true) 'WD8 [核心] absorbed re-marked at registration (replan-first window join)' ($d1 | ConvertTo-Json -Compress)
    $tasks = Read-Tasks $arch
    Assert-True (@($tasks).Count -eq 3) 'WD8 remark anchor dedup — task.json NOT duplicated' ((@($tasks) | ForEach-Object { "$($_.id):$($_.lifecycle)" }) -join ',')
    $b3 = $b.tasks.'3'
    $derContainer2 = [string]$b3.container
    $ctoNode2 = [string]$b3.stages.CTO
    Assert-True ($derContainer2 -ne '' -and $ctoNode2 -ne '') 'WD8 container+slots re-materialized' ($b3 | ConvertTo-Json -Compress)
    Assert-True ($derContainer2 -ne $derContainer) 'WD8 container re-grafted with a fresh id (old one pruned)'
    $liveContainers = @(Read-TreeNodes 'deliver-wd-main' | Where-Object { [string]$_.type -eq 'sub' -and [string]$_.status -ne 'pruned' -and [string]$_.title -eq '派生W' })
    Assert-True ($liveContainers.Count -eq 1) 'WD8 exactly ONE live derived container (no duplicate materialization)' ($liveContainers.Count)
    $cNode2 = Find-TreeNode 'deliver-wd-main' $derContainer2
    $depSorted2 = @(@($cNode2.depends_on) | Sort-Object) -join ','
    Assert-True ($depSorted2 -eq $wantSorted) 'WD8 re-materialized container re-carries the WBS dep edges' ("got [$depSorted2]")

    # ================= WD9: 分段中间态重放（容器已录 + 槽缺失） =================
    $bj = Get-Content -LiteralPath $bp -Raw -Encoding UTF8 | ConvertFrom-Json
    $keepContainer = [string]$bj.tasks.'3'.container
    $staleSlots = @($bj.tasks.'3'.stages.PSObject.Properties | ForEach-Object { [string]$_.Value })
    $bj.tasks.'3'.stages = @{}
    foreach ($sid in $staleSlots) { if ($bj.nodes.PSObject.Properties[$sid]) { $bj.nodes.PSObject.Properties.Remove($sid) } }
    $bj.derivations[0].status = 'confirmed'
    $bj.derivations[0].task_id = $null
    foreach ($p in @('absorbed', 'absorbed_at', 'registered_at')) {
        if ($bj.derivations[0].PSObject.Properties[$p]) { $bj.derivations[0].PSObject.Properties.Remove($p) }
    }
    Write-Utf8NoBom $bp ($bj | ConvertTo-Json -Depth 10)
    foreach ($sid in $staleSlots) {
        $rp = Invoke-Tree @('-Command', 'prune', '-RunId', 'deliver-wd-main', '-NodeId', $sid, '-Reason', 'segmented mid-state replay: slots missing')
        if ($rp.json.success -ne $true) { throw "prune slot $sid failed: $($rp.raw)" }
    }
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-wd-main')
    Assert-True ($r.json.success -eq $true) 'WD9 status touch ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ([string]$d1.status -eq 'registered' -and [int]$d1.task_id -eq 3) 'WD9 patrol converged from the segmented mid-state' ($d1 | ConvertTo-Json -Compress)
    $b3 = $b.tasks.'3'
    Assert-True ([string]$b3.container -eq $keepContainer) 'WD9 [核心] recorded container REUSED (not re-grafted)' ("got [$($b3.container)] want [$keepContainer]")
    $liveContainers = @(Read-TreeNodes 'deliver-wd-main' | Where-Object { [string]$_.type -eq 'sub' -and [string]$_.status -ne 'pruned' -and [string]$_.title -eq '派生W' })
    Assert-True ($liveContainers.Count -eq 1) 'WD9 still exactly ONE live derived container' ($liveContainers.Count)
    $ctoNode3 = [string]$b3.stages.CTO
    $qaNode3 = [string]$b3.stages.QA
    Assert-True ($ctoNode3 -ne '' -and $qaNode3 -ne '' -and ($staleSlots -notcontains $ctoNode3)) 'WD9 missing slots re-grafted (fresh ids)' ($b3 | ConvertTo-Json -Compress)
    $tasks = Read-Tasks $arch
    Assert-True (@($tasks).Count -eq 3) 'WD9 task.json still NOT duplicated' ((@($tasks) | ForEach-Object { $_.id }) -join ',')

    # ================= WD10: DESIGN 收敛 → IMPL 槽挂同一容器 =================
    Do-Deliver 'deliver-wd-main' $ctoNode3 'CTO' @("$arch/requirements/derive-w.md")
    $null = Do-Settle 'deliver-wd-main' $ctoNode3
    Do-Deliver 'deliver-wd-main' $qaNode3 'QA' @("$arch/requirements/derive-w.md")
    $r = Do-Settle 'deliver-wd-main' $qaNode3
    Assert-True ($r.json.success -eq $true) 'WD10 DESIGN phase settles (serial CTO→QA convergence)' ($r.raw)
    $b = Read-BridgeJson 'deliver-wd-main'
    $implNode = [string]$b.tasks.'3'.stages.DEV
    Assert-True ($implNode -ne '') 'WD10 IMPL head grafted after DESIGN converged' ((@($b.tasks.'3'.stages) | ConvertTo-Json -Compress))
    $implTree = Find-TreeNode 'deliver-wd-main' $implNode
    Assert-True ($null -ne $implTree -and [string]$implTree.parent -eq $keepContainer -and [string]$implTree.duty -eq 'dev') 'WD10 [核心] IMPL slot under the SAME container (promulgate-isomorphic later stages)' ($implTree | ConvertTo-Json -Compress)

    # ================= WD11: BOM 自检（tips 义务） =================
    $bytes = [System.IO.File]::ReadAllBytes($BridgePs1)
    Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'WD11 delivery-bridge.ps1 BOM intact' ("got {0},{1},{2}" -f $bytes[0], $bytes[1], $bytes[2])
}
finally {
    Pop-Location
    $env:DSH_WEB_URL = $null
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ("--- {0} passed / {1} failed / {2} total ---" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count, $Results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

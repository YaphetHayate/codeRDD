# QA independent black-box probe — planner mid-run 需求派生（2026-10-07-planner-midrun-derive）
# 独立视角：从需求 7 条验收标准出发，主干独立复现 + 补 DEV 套件（test-bridge-derive.ps1）盲区。
#   QA1 入口防御：缺 -Action / 未知 action / 缺 Title / 缺 Rationale
#   QA2 propose 机读与呈报：账本四要素+derivation_id+depends_on 去重+owners 收窄机读；
#       present_to_user 双裁决路径+硬门句；next_step CLI/Plus 降级呈现指示
#   QA3 确认硬门确定性（验收 2）：缺 -UserVerdict 与空白串同码 DERIVE_CONFIRMATION_MISSING；
#       两次拒绝状态零漂移；不存在的 DRV -> DERIVE_NOT_FOUND
#   QA4 withdraw proposed 零副作用 + 裁决留痕 + 派生号不复用（withdrawn 占号）
#   QA5 主链 E2E（验收 1/3/4/5/6）：裁决原文逐字留痕（中文标点/空格）；PM 节点 graft 到
#       goal 根（树侧 parent/role）；plan-log D 事件 payload；受控入册 task.json 生命周期；
#       bridge.tasks 机读同构（dep_task_ids）；acceptance derived_upgrade live-read；
#       链头树侧 depends_on 依赖传导（DEV 盲区）；replan 吸收放行；claim 双上下文；
#       全链 DESIGN→IMPL→VERIFY 收敛；非法迁移（二次 confirm/withdraw registered/withdrawn）
#   QA6 conclude 门 + annex（验收 7，DEV 盲区——走到真实结案）：挂起 DERIVATION_PENDING；
#       annex「需求派生」清单（withdrawn 拒绝留痕/registered 已入 plan/确认记录号）+ 根目标口径行
#   QA7 settle 前确认复核（验收 2 硬门的第二触点，DEV 盲区）：篡改账本删 ruling 条目 ->
#       settle 降级拒入册（task.json 不动）+ status 巡检同样拒绝
#   QA8 旧 run 兼容（需求边界）：无 derivations 段的 bridge.json status 不崩 + propose 段重建
#   QA9 add-task 门边界：大小写不敏感匹配 / manifest concluded 后门释放（DEV 盲区）/ 无 run 归档 legacy
#   QA10 防滥用默认阈值 3（DEV 用 -MaxDerivations 1，默认值盲区）：前 3 条无警告第 4 条警告不硬拒
#   QA12 R1 跨组件锚（2026-10-08 reopen 复验轮新增）：真引擎 escalate 写归档级账本 →
#       插件产物 lib/goaltrees.js collectDecisionEntries 读回 → 写/读同源对拍（R1 失效面）+
#       resolution 即时收敛（现读非缓存）+ 旧 run 目录账本 legacy 兜底不退步
#   QA13 派生 PM 节点回收（上轮在册覆盖缺口）：dead-claim → steal 复用同族通道；
#       rejected-delivery（无 verification 的不合格重报）→ prune + 同源重建 PM 节点 +
#       derivations[].node 重锚且状态保持 confirmed
#   QA11 BOM 自检（tips 义务）：engine 两脚本 + 本探针首 3 字节 239,187,191
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# planner-claim-guard: 夹具 claim 属 worker 侧动作，套件在 dsh 会话里运行时环境
# DSH_SESSION_ID 会被写进 run 的 planner.json，fixture claim 会被身份门拒。清空保确定性。
Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

$EngineDir = Split-Path -Parent $PSScriptRoot | Split-Path -Parent | Join-Path -ChildPath 'engine' | Join-Path -ChildPath 'scripts'
if (-not (Test-Path (Join-Path $EngineDir 'delivery-bridge.ps1'))) {
    # .rdd/tests/delivery-bridge/ -> <repo>/rdd-engine/scripts
    $EngineDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\rdd-engine\scripts')).Path
}
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('midrun-derive-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    # EAP 容错：参数验证失败（ValidateSet 拒绝）时 stderr 变 ErrorRecord，Stop 会炸探针本身
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& powershell (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList) 2>&1 | Out-String) }
    finally { $ErrorActionPreference = $prevEap }
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}
function Invoke-Bridge { param([string[]]$A)
    # bridge 默认形状翻转（promulgate legacy→wake）：本探针按旧链 chain-head 拓扑
    # 书写——promulgate 未显式带 -Shape 时机械补 legacy（显式 -Shape 优先，
    # 非 promulgate 命令零影响）。
    if ($A -contains 'promulgate' -and -not ($A -contains '-Shape')) { $A = @($A) + @('-Shape', 'legacy') }
    Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }

$WatcherHelper = Join-Path $PSScriptRoot 'midrun-derive-watcher-qa-verify.mjs'
function Get-WatcherOpenEntries { param([string]$RepoRoot)
    # 插件产物读面（R1 跨组件锚）：信封兜底解析——lib 若向 stderr 打诊断，
    # 合流后整串不是纯 JSON，退化为「取最后一个以 { 开头的行」。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& node $WatcherHelper $RepoRoot 2>&1 | Out-String) }
    finally { $ErrorActionPreference = $prevEap }
    $code = $LASTEXITCODE
    $json = $null
    try { $json = ($out | ConvertFrom-Json) } catch {
        foreach ($line in @($out -split "`r?`n")) {
            if (-not $line.TrimStart().StartsWith('{')) { continue }
            try { $json = ($line | ConvertFrom-Json); break } catch { }
        }
    }
    return @{ json = $json; exit = $code; raw = $out }
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
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
function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    $obj = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($obj.nodes)
}
function Get-Der { param($Bridge, [string]$Id)
    foreach ($d in @($Bridge.derivations)) { if ([string]$d.id -eq $Id) { return $d } }
    return $null
}
function Read-Tasks { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/task.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
}

function New-QaArchive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nQA 探针归档 $Name。`n"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir "requirements/t$i.md") "# $Name 需求 $i`n`n- **描述**：QA 探针需求 $i`n- **验收标准**：见 overview.md`n"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

function Write-QaPlan { param([string]$Path, $Stages, [string]$CriteriaRef = '', $BatchSets = $null)
    $stageObjs = @()
    foreach ($st in $Stages) {
        $ap = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' }
        if ($CriteriaRef) { $ap['criteria_ref'] = $CriteriaRef }
        $batches = @(@($st.tasks | ForEach-Object { [int]$_ } | Sort-Object))
        if ($null -ne $BatchSets) { $batches = @($BatchSets | ForEach-Object { , @($_ | ForEach-Object { [int]$_ }) }) }
        $stageObjs += , @{
            id = [string]$st.id
            goal = "stage $($st.id) 目标"
            milestone = "stage $($st.id) 里程碑"
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = $batches
            acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-08T00:00:00Z'; planner = 'qa'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

function New-QaCb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'midrun-derive QA probe delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'QA probe fixture: cited set carries no PowerShell files' } }
    }
    $cbFile = Join-Path $env:TEMP ("qa-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-QaCb $NodeId $Refs
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}
function New-AcceptanceDoc { param([string]$ArchiveRel, [string]$Name)
    $dir = Join-Path $Work ($ArchiveRel + '/tests')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $body = "# 集成/联调与整体验收（$Name）`n`n## §1 集成/联调记录`n`n- 引用回调账本条目（不复制）`n`n## §2 判据逐条核验表`n`n| 判据 | 核验 | 结果 |`n|------|------|------|`n| 1 | demo 实证 | 通过 |`n`n## §3 总结论`n`n总结论: 通过`n`nQA 独立复跑全绿。`n"
    Write-Utf8NoBom (Join-Path $dir 'integration-acceptance.md') $body
    return "$ArchiveRel/tests/integration-acceptance.md"
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
# dead dsh URL: auto-push fails instantly (no real session) — attempts land in the push ledger only
$env:DSH_WEB_URL = 'http://127.0.0.1:1'
Push-Location $Work
try {
    # ============ fixture: qa-main（1 DEV 任务，无判据 -> single_exempt） ============
    $arch = New-QaArchive 'qa-main' '[{"title":"主链需求","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pf = Write-QaPlan (Join-Path $Work 'qa-main-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch + '/task.json'), '-PlanFile', $pf, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'QA0 promulgate qa-main ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-main'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    $goalRoot = [string]$b.goal_root

    # ================= QA1: 入口防御 =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_ACTION_REQUIRED') 'QA1 derive without -Action -> DERIVE_ACTION_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'bogus')
    Assert-True ($r.json -eq $null -and $r.exit -ne 0) 'QA1 unknown -Action rejected at the ValidateSet layer (fail-loud, no fake JSON)' ("exit=$($r.exit)")
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'propose', '-Rationale', '缺口')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_TITLE_REQUIRED') 'QA1 propose without -Title -> DERIVE_TITLE_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'propose', '-Title', '派生')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_RATIONALE_REQUIRED') 'QA1 propose without -Rationale -> DERIVE_RATIONALE_REQUIRED' ($r.raw)

    # ================= QA2: propose 机读与呈报（收窄 owners + 依赖去重） =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'propose', '-Title', '导出能力', '-Rationale', '主链跑通后发现导出能力缺口', '-DependsOn', '1,1', '-Owners', 'CTO+QA')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'proposed') 'QA2 propose ok (proposed)' ($r.raw)
    $present = [string]$r.json.data.present_to_user
    Assert-True ($present -match '-Action confirm' -and $present -match '-UserVerdict' -and $present -match '-Action withdraw' -and $present -match '无确认记录不派遣') 'QA2 present_to_user: both verdict paths + hard-gate sentence' ($present)
    Assert-True ([string]$r.json.data.next_step -match 'in-session') 'QA2 next_step carries the CLI/Plus in-session presentation instruction' ([string]$r.json.data.next_step)
    $led = Read-Ledger $arch
    $e1 = @($led | Where-Object { [string]$_.kind -eq 'derive_proposal' })[0]
    Assert-True ($null -ne $e1 -and [string]$e1.entry_id -eq 'D1' -and [string]$e1.derivation_id -eq 'DRV1' -and [string]$e1.decider -eq 'planner') 'QA2 ledger D1 derive_proposal (planner, derivation_id)' ((@($led) | ConvertTo-Json -Depth 4 -Compress))
    Assert-True ($null -ne $e1 -and @($e1.depends_on).Count -eq 1 -and [int]@($e1.depends_on)[0] -eq 1) 'QA2 ledger depends_on de-duplicated to [1] (机读格式)' ((@($e1.depends_on) | ConvertTo-Json -Compress))
    Assert-True ($null -ne $e1 -and @($e1.owners) -contains 'CTO' -and @($e1.owners) -contains 'QA' -and @($e1.owners) -notcontains 'UX') 'QA2 ledger owners narrowed [CTO,QA] (机读)' ((@($e1.owners) | ConvertTo-Json -Compress))
    $b = Read-BridgeJson 'deliver-qa-main'
    $d1 = Get-Der $b 'DRV1'
    Assert-True ($null -ne $d1 -and [string]$d1.status -eq 'proposed' -and $null -eq $d1.node -and $null -eq $d1.task_id -and @($d1.depends_on).Count -eq 1) 'QA2 bridge derivations[] proposed (no node/task, depends_on de-dup)' ((@($d1) | ConvertTo-Json -Depth 4 -Compress))

    # ================= QA3: 确认硬门确定性 =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'confirm', '-DerivationId', 'DRV1')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_CONFIRMATION_MISSING' -and $r.exit -eq 1) 'QA3 confirm without -UserVerdict -> DERIVE_CONFIRMATION_MISSING (exit 1)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '   ')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_CONFIRMATION_MISSING') 'QA3 whitespace -UserVerdict -> same hard-gate code' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-main'
    Assert-True ((Get-Der $b 'DRV1').status -eq 'proposed') 'QA3 two refusals leave zero state drift (still proposed)'
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'confirm', '-DerivationId', 'DRV999', '-UserVerdict', 'x')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_NOT_FOUND' -and $r.exit -eq 2) 'QA3 confirm unknown id -> DERIVE_NOT_FOUND (exit 2)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'withdraw', '-DerivationId', 'DRV999')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_NOT_FOUND' -and $r.exit -eq 2) 'QA3 withdraw unknown id -> DERIVE_NOT_FOUND (exit 2)' ($r.raw)

    # ================= QA4: withdraw proposed（零副作用 + 占号不复用） =================
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'withdraw', '-DerivationId', 'DRV1', '-Reason', '用户改口：不派生导出')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'withdrawn' -and $null -eq $r.json.data.pruned_node) 'QA4 withdraw proposed -> withdrawn, nothing pruned (zero side effects)' ($r.raw)
    $led = Read-Ledger $arch
    $e2 = @($led | Where-Object { [string]$_.kind -eq 'ruling' -and [string]$_.derivation_id -eq 'DRV1' })[0]
    Assert-True ($null -ne $e2 -and [string]$e2.decider -eq 'user' -and [string]$e2.ref_entry -eq 'D1') 'QA4 withdraw ruling recorded (decider=user, ref_entry back to proposal)' ((@($led) | ConvertTo-Json -Depth 4 -Compress))
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'propose', '-Title', '派生B', '-Rationale', '主链派生（全链走查用）', '-DependsOn', '1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.derivation_id -eq 'DRV2') 'QA4 withdrawn id never reused -> next proposal is DRV2' ([string]$r.json.data.derivation_id)

    # ================= QA5: 主链 E2E =================
    $verdict = '同意派生 R_new 并入当前 run——总目标需要 导出 能力（含, 标点）'
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'confirm', '-DerivationId', 'DRV2', '-UserVerdict', $verdict)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.status -eq 'confirmed' -and [string]$r.json.data.node_id -ne '') 'QA5 confirm ok (confirmed + node grafted)' ($r.raw)
    $led = Read-Ledger $arch
    $er = @($led | Where-Object { [string]$_.kind -eq 'ruling' -and [string]$_.derivation_id -eq 'DRV2' })[0]
    Assert-True ($null -ne $er -and [string]$er.decision -ceq $verdict -and [string]$er.decider -eq 'user') 'QA5 user verdict preserved VERBATIM in the ledger ruling (中文标点/空格逐字)' ("decision=$([string]$er.decision)")
    Assert-True ($null -ne $er -and [string]$er.ref_entry -eq 'D3') 'QA5 ruling ref_entry points back to the proposal entry (D3)' ([string]$er.ref_entry)
    $b = Read-BridgeJson 'deliver-qa-main'
    $d2 = Get-Der $b 'DRV2'
    $pmNode = [string]$d2.node
    $pmTree = @(Read-TreeNodes 'deliver-qa-main' | Where-Object { [string]$_.id -eq $pmNode })[0]
    Assert-True ($null -ne $pmTree -and [string]$pmTree.parent -eq $goalRoot -and [string]$pmTree.role -eq 'pm') 'QA5 PM node grafted as a goal-root child with role=pm (验收 1)' (("parent=$([string]$pmTree.parent); role=$([string]$pmTree.role)"))
    $plog = Read-PlanLog 'deliver-qa-main'
    $sd = @($plog | Where-Object { [string]$_.kind -eq 'deviation' -and [string]$_.event -eq 'scope_derived' })[0]
    Assert-True ($null -ne $sd -and [string]$sd.detail.derivation -eq 'DRV2' -and @($sd.detail.depends_on).Count -eq 1 -and [string]$sd.detail.ledger_entry -ne '') 'QA5 plan-log D event scope_derived (derivation/ledger_entry/depends_on payload, 验收 7)' ((@($plog) | ConvertTo-Json -Depth 4 -Compress))
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'confirm', '-DerivationId', 'DRV2', '-UserVerdict', '再次同意')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_STATE_INVALID') 'QA5 re-confirm a confirmed derivation -> DERIVE_STATE_INVALID' ($r.raw)

    # PM 交付：新需求文档 + overview 判据增补 -> settle -> 受控入册
    Write-Utf8NoBom (Join-Path $Work "$arch/requirements/derive-r.md") "# 派生需求 R_new`n`n- **描述**：导出能力补齐`n- **验收标准**：导出可实证`n- **依赖关系**：依赖主链需求（#1）`n"
    $ovPath = Join-Path $Work "$arch/requirements/overview.md"
    Write-Utf8NoBom $ovPath "# qa-main`n`nQA 探针归档 qa-main。`n`n## 整体验收判据`n`n| # | 用户可感知完整场景 | 可检验形态 | 覆盖子需求 |`n|---|------|------|------|`n| 1 | 端到端含导出跑通 | demo 实证 | 主链需求、派生R |`n"
    Do-Deliver 'deliver-qa-main' $pmNode 'PM' @("$arch/requirements/derive-r.md", "$arch/requirements/overview.md")
    $r = Do-Settle 'deliver-qa-main' $pmNode
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.flow_operation -match 'derivation registered') 'QA5 PM settle -> controlled registration' ($r.raw)
    $tasks = Read-Tasks $arch
    $t2 = @($tasks | Where-Object { [int]$_.id -eq 2 })[0]
    Assert-True ($null -ne $t2 -and [string]$t2.phase -eq 'DESIGN' -and [string]$t2.requirement -eq 'requirements/derive-r.md' -and [string]$t2.remark -match 'derivation=DRV2') 'QA5 task.json #2 lifecycle isomorphic (phase=DESIGN, requirement, remark anchor)' ((@($tasks) | ConvertTo-Json -Depth 4 -Compress))
    Assert-True ($null -ne $t2 -and @($t2.currentOwners) -contains 'CTO' -and @($t2.currentOwners) -contains 'UX' -and @($t2.currentOwners) -contains 'QA') 'QA5 default owners full chain (CTO+UX+QA)' ((@($t2.currentOwners) | ConvertTo-Json -Compress))
    $b = Read-BridgeJson 'deliver-qa-main'
    Assert-True (@($b.tasks.'2'.dep_task_ids).Count -eq 1 -and [int]@($b.tasks.'2'.dep_task_ids)[0] -eq 1) 'QA5 bridge.tasks dep_task_ids=[1] machine-readable (验收 6 机读同构)' ((@($b.tasks.'2'.dep_task_ids) | ConvertTo-Json -Compress))
    Assert-True ([string]$b.acceptance.status -eq 'planned' -and [string]$b.acceptance.basis -eq 'derived_upgrade' -and [string]$b.acceptance.criteria_ref -match '整体验收判据') 'QA5 acceptance upgraded derived_upgrade with live-read criteria anchor (验收 5)' ((@($b.acceptance) | ConvertTo-Json -Compress))
    $ctoNode = [string]$b.tasks.'2'.stages.CTO
    $ctoTree = @(Read-TreeNodes 'deliver-qa-main' | Where-Object { [string]$_.id -eq $ctoNode })[0]
    Assert-True ($null -ne $ctoTree -and @($ctoTree.depends_on) -contains $devHead) 'QA5 chain-head depends_on wired to the live dependency node (验收 6 建树依赖推导)' (("depends_on=$(@($ctoTree.depends_on) -join ',') devHead=$devHead"))
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-qa-main', '-NodeId', $ctoNode, '-DryRun')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_GATE') 'QA5 unabsorbed chain head held (NODE_BLOCKED_BY_GATE)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'withdraw', '-DerivationId', 'DRV2')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_STATE_INVALID' -and $r.raw -match 'deprecate') 'QA5 withdraw a registered derivation -> DERIVE_STATE_INVALID (deprecate guidance)' ($r.raw)
    $pfB = Write-QaPlan (Join-Path $Work 'qa-main-plan2.json') @(@{ id = 'S1'; tasks = @(1, 2) }) 'requirements/overview.md#整体验收判据' @(@(1), @(2))
    $r = Invoke-Bridge @('-Command', 'replan', '-RunId', 'deliver-qa-main', '-PlanFile', $pfB, '-Reason', '吸收派生任务 #2')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.derivations_absorbed) -match 'DRV2') 'QA5 replan absorbs DRV2 (验收 4 白名单+吸收)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-qa-main', '-NodeId', $ctoNode, '-DryRun')
    Assert-True ($r.json.success -eq $true) 'QA5 gate opens after absorption' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-main', '-NodeId', $ctoNode, '-Role', 'CTO')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'NODE_BLOCKED_BY_DEPS' -and $r.raw -match $devHead) 'QA5 chain-head claim held by the dependency gate until devHead settles (AC6 依赖传导行为面)' ($r.raw)

    # 主任务 #1 全链（DEV -> QA），派生链头依赖解锁
    Do-Deliver 'deliver-qa-main' $devHead 'DEV' @("$arch/requirements/t1.md")
    $null = Do-Settle 'deliver-qa-main' $devHead
    $b = Read-BridgeJson 'deliver-qa-main'
    $t1qa = [string]$b.tasks.'1'.stages.QA
    Assert-True ($t1qa -ne '') 'QA5 task-1 VERIFY head grafted'
    Do-Deliver 'deliver-qa-main' $t1qa 'QA' @("$arch/requirements/t1.md")
    $null = Do-Settle 'deliver-qa-main' $t1qa
    # 依赖解锁后：claim 派生链头（双上下文同构断言）→ 交付 → settle
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-main', '-NodeId', $ctoNode, '-Role', 'CTO')
    Assert-True ($r.json.success -eq $true -and $r.raw -match 'derive-r\.md' -and $r.raw -match 'task_id') 'QA5 claim chain head carries the dual context (task #2 + requirement pointer, 验收 4 同构)' ($r.raw)
    $cb = New-QaCb $ctoNode @("$arch/requirements/derive-r.md")
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-qa-main', '-Worker', 'CTO', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'QA5 CTO delivery report accepted' ($r.raw)
    $null = Do-Settle 'deliver-qa-main' $ctoNode
    # 派生 #2 全链（CTO 已 settle）：UX -> QA(DESIGN) -> DEV(IMPL) -> QA(VERIFY)
    $b = Read-BridgeJson 'deliver-qa-main'
    $uxNode = [string]$b.tasks.'2'.stages.UX; $desQa = [string]$b.tasks.'2'.stages.QA
    Do-Deliver 'deliver-qa-main' $uxNode 'UX' @("$arch/requirements/derive-r.md")
    $null = Do-Settle 'deliver-qa-main' $uxNode
    Do-Deliver 'deliver-qa-main' $desQa 'QA' @("$arch/requirements/derive-r.md")
    $null = Do-Settle 'deliver-qa-main' $desQa
    $b = Read-BridgeJson 'deliver-qa-main'
    $implNode = [string]$b.tasks.'2'.stages.DEV
    Assert-True ($implNode -ne '') 'QA5 IMPL head grafted after DESIGN converged'
    Do-Deliver 'deliver-qa-main' $implNode 'DEV' @("$arch/requirements/derive-r.md")
    $null = Do-Settle 'deliver-qa-main' $implNode
    $b = Read-BridgeJson 'deliver-qa-main'
    $verNode = [string]$b.tasks.'2'.stages.QA
    Assert-True ($verNode -ne '' -and $verNode -ne $desQa) 'QA5 VERIFY head grafted after IMPL settled'
    Do-Deliver 'deliver-qa-main' $verNode 'QA' @("$arch/requirements/derive-r.md")
    $null = Do-Settle 'deliver-qa-main' $verNode
    $tasks = Read-Tasks $arch
    Assert-True (@($tasks | Where-Object { [string]$_.lifecycle -eq 'completed' }).Count -eq 2) 'QA5 both tasks terminal (lifecycle completed)' ((@($tasks) | ForEach-Object { "$($_.id):$($_.lifecycle)" }) -join ',')

    # ================= QA6: 验收链 + conclude 硬门 + annex（验收 7 呈现） =================
    $b = Read-BridgeJson 'deliver-qa-main'
    $integ = [string]$b.acceptance.integrate_node
    Assert-True ($integ -ne '' -and [string]$b.acceptance.status -eq 'grafted') 'QA6 acceptance chain grafted after all mapped nodes settled' ("integrate=$integ")
    $accDoc = New-AcceptanceDoc $arch 'qa-main'
    Do-Deliver 'deliver-qa-main' $integ 'DEV' @($accDoc)
    $null = Do-Settle 'deliver-qa-main' $integ
    $b = Read-BridgeJson 'deliver-qa-main'
    $accept = [string]$b.acceptance.accept_node
    Assert-True ($accept -ne '') 'QA6 accept node grafted after integrate settled'
    Do-Deliver 'deliver-qa-main' $accept 'QA' @($accDoc)
    $null = Do-Settle 'deliver-qa-main' $accept
    $b = Read-BridgeJson 'deliver-qa-main'
    Assert-True ([string]$b.acceptance.conclusion -eq '通过') 'QA6 acceptance conclusion recorded (通过)' ("conclusion=$([string]$b.acceptance.conclusion)")
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'propose', '-Title', '派生C', '-Rationale', '结案前挂起验证')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.derivation_id -eq 'DRV3') 'QA6 DRV3 proposed (pending gate probe)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-qa-main', '-Summary', 'QA 结案尝试')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVATION_PENDING') 'QA6 open derivation blocks conclude (DERIVATION_PENDING)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-main', '-Action', 'withdraw', '-DerivationId', 'DRV3', '-Reason', '用户裁决：不派生')
    Assert-True ($r.json.success -eq $true) 'QA6 withdraw DRV3' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'conclude', '-RunId', 'deliver-qa-main', '-Summary', 'QA 全链结案')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.outcome -eq 'achieved') 'QA6 conclude achieved (single-run convergence)' ($r.raw)
    $annexPath = Join-Path $Work '.rdd/goal-trees/deliver-qa-main/report/delivery-annex.md'
    $annex = Get-Content -LiteralPath $annexPath -Raw -Encoding UTF8
    Assert-True ($annex -match '## 需求派生（mid-run derive）') 'QA6 annex carries the derivation section (验收 7 留痕三联之三)' ($annexPath)
    Assert-True ($annex -match 'DRV1.*withdrawn' -and $annex -match '拒绝') 'QA6 annex DRV1 withdrawn row shows the refusal record' ($annex)
    Assert-True ($annex -match 'DRV2.*registered' -and $annex -match '已入 plan' -and $annex -match '#2') 'QA6 annex DRV2 registered row (task #2, absorbed)' ($annex)
    Assert-True ($annex -match '根目标口径补充.*派生需求并入') 'QA6 annex root-goal line: 含 N 条 run 中途派生需求并入 (达成口径)' ($annex)

    # ================= QA7: settle 前确认复核（篡改账本防御，硬门第二触点） =================
    $archT = New-QaArchive 'qa-tamper' '[{"title":"篡改夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfT = Write-QaPlan (Join-Path $Work 'qa-tamper-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archT + '/task.json'), '-PlanFile', $pfT, '-NoPush')
    $null = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-tamper', '-Action', 'propose', '-Title', '派生T', '-Rationale', '篡改验证')
    $null = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-tamper', '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意（随后删除该记录）')
    $bT = Read-BridgeJson 'deliver-qa-tamper'
    $pmT = [string](Get-Der $bT 'DRV1').node
    Write-Utf8NoBom (Join-Path $Work "$archT/requirements/derive-t.md") "# 派生 T`n`n- **描述**：篡改验证派生`n"
    Do-Deliver 'deliver-qa-tamper' $pmT 'PM' @("$archT/requirements/derive-t.md", "$archT/requirements/overview.md")
    # 篡改：从归档账本中抹掉 ruling 条目（模拟无确认记录）
    $ledPath = Join-Path $Work ($archT + '/decisions.jsonl')
    $kept = @(); foreach ($line in @([System.IO.File]::ReadAllLines($ledPath))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json } catch { $kept += $line; continue }
        if ([string]$o.kind -ne 'ruling') { $kept += $line }
    }
    [System.IO.File]::WriteAllLines($ledPath, $kept)
    $r = Do-Settle 'deliver-qa-tamper' $pmT
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DERIVE_CONFIRMATION_MISSING' -and $r.exit -eq 1) 'QA7 settle REFUSED with DERIVE_CONFIRMATION_MISSING (nothing transitioned — hard gate 2nd touchpoint)' ($r.raw)
    $tasksT = Read-Tasks $archT
    Assert-True (@($tasksT).Count -eq 1) 'QA7 task.json untouched (registration refused by the hard gate)' ((@($tasksT) | ConvertTo-Json -Depth 3 -Compress))
    $bT = Read-BridgeJson 'deliver-qa-tamper'
    $dT = Get-Der $bT 'DRV1'
    Assert-True ([string]$dT.status -eq 'confirmed' -and $null -eq $dT.task_id) 'QA7 derivation stays confirmed-without-registration'
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-qa-tamper')
    $tasksT = Read-Tasks $archT
    Assert-True ($r.json.success -eq $true -and @($tasksT).Count -eq 1) 'QA7 status patrol re-checks the same hard gate (no self-heal past the gate)' ((@($tasksT) | ConvertTo-Json -Depth 3 -Compress))

    # ================= QA8: 旧 run 兼容（无 derivations 段） =================
    $archL = New-QaArchive 'qa-legacy' '[{"title":"旧run夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfL = Write-QaPlan (Join-Path $Work 'qa-legacy-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archL + '/task.json'), '-PlanFile', $pfL, '-NoPush')
    $bp = Join-Path $Work '.rdd/goal-trees/deliver-qa-legacy/bridge.json'
    $bl = Get-Content -LiteralPath $bp -Raw -Encoding UTF8 | ConvertFrom-Json
    $bl.PSObject.Properties.Remove('derivations')
    Write-Utf8NoBom $bp ($bl | ConvertTo-Json -Depth 10)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-qa-legacy')
    Assert-True ($r.json.success -eq $true) 'QA8 legacy bridge.json without derivations: status unchanged (缺键兼容)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-legacy', '-Action', 'propose', '-Title', '旧run派生', '-Rationale', '兼容验证')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.derivation_id -eq 'DRV1') 'QA8 derive on a legacy run rebuilds the section (DRV1)' ($r.raw)

    # ================= QA9: add-task 门边界 =================
    $archG = New-QaArchive 'qa-gate' '[{"title":"门夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfG = Write-QaPlan (Join-Path $Work 'qa-gate-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archG + '/task.json'), '-PlanFile', $pfG, '-NoPush')
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archG, '-Title', '绕行', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_REQUIRED') 'QA9 active run without -BridgeRun -> ADD_TASK_BRIDGE_RUN_REQUIRED' ($r.raw)
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archG, '-Title', '大小写', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV', '-BridgeRun', 'DELIVER-QA-GATE')
    Assert-True ($r.json.success -eq $true) 'QA9 -BridgeRun matching is case-insensitive' ($r.raw)
    # 缺陷锚 R2（P1，D1 裁定 reopen）：manifest.json 位于 run 顶层并携带 state=concluded，
    # 而修复前 Find-ActiveBridgeRunForArchive 探测 state/manifest.json（引擎从不写该路径）
    # → concluded 判定永不命中 → 已结案 run 的 add-task 门不释放（违背「concluded → no gate」）。
    # 修复后本断言翻转为「期望放行」；再复位为 running 复验门重新武装（活探针，非缓存裁定）。
    $mPath = Join-Path $Work '.rdd/goal-trees/deliver-qa-gate/manifest.json'
    $m = Get-Content -LiteralPath $mPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $m.state = 'concluded'
    Write-Utf8NoBom $mPath ($m | ConvertTo-Json -Depth 8)
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archG, '-Title', '结案后直加', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $true -and $r.json.data.added -eq $true) 'QA9 concluded run RELEASES the add-task gate (top-level manifest.json state, R2 fixed)' ($r.raw)
    $m.state = 'running'
    Write-Utf8NoBom $mPath ($m | ConvertTo-Json -Depth 8)
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archG, '-Title', '活探针复位', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ADD_TASK_BRIDGE_RUN_REQUIRED') 'QA9 gate re-arms when the run goes back to running (live state probe, not a cached verdict)' ($r.raw)
    $m.state = 'concluded'
    Write-Utf8NoBom $mPath ($m | ConvertTo-Json -Depth 8)
    $archP = New-QaArchive 'qa-plain' '[{"title":"无run归档","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $archP, '-Title', '普通追加', '-Requirement', 'requirements/t1.md', '-CurrentOwners', 'QA')
    Assert-True ($r.json.success -eq $true) 'QA9 archive without a run keeps the legacy add-task path' ($r.raw)

    # ================= QA10: 防滥用默认阈值 3 =================
    $archM = New-QaArchive 'qa-limit' '[{"title":"阈值夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfM = Write-QaPlan (Join-Path $Work 'qa-limit-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archM + '/task.json'), '-PlanFile', $pfM, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'QA10 qa-limit promulgated WITHOUT -MaxDerivations (default)' ($r.raw)
    $warns = @()
    foreach ($n in @('一', '二', '三')) {
        $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-limit', '-Action', 'propose', '-Title', "派生$n", '-Rationale', "阈值$n")
        $warns += [string]$r.json.data.limit_warning
    }
    Assert-True (@($warns | Where-Object { $_ -and $_ -ne '' }).Count -eq 0) 'QA10 first 3 derivations carry no limit warning (default threshold 3)' (($warns -join ' | '))
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-limit', '-Action', 'propose', '-Title', '派生四', '-Rationale', '超默认阈值')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.limit_warning -match 'DERIVATION_LIMIT_WARNING') 'QA10 4th derivation warns (warning, not rejected)' ([string]$r.json.data.limit_warning)

    # ================= QA12: R1 跨组件锚（引擎写入 ↔ watcher 读取同源账本） =================
    # R1（P0，D1 裁定 reopen）的失效面是「写端搬到归档根、读端仍在 run 目录」的静默错位。
    # 本锚不复用 DEV 的 smoke 夹具（那用手工播种的 lib 级夹具），而是用真实引擎写账本
    # （escalate → Get-ArchiveDecisionsPath），再用插件产物 lib/goaltrees.js 的
    # collectDecisionEntries 读回：两端在同一 run 上对拍——读端若退回 run 目录，本锚必读空。
    $archW = New-QaArchive 'qa-watch' '[{"title":"watcher夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfW = Write-QaPlan (Join-Path $Work 'qa-watch-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    # -AutoMode：escalate/decide 的承载面（纯自动模式升级通道）；-NoPush 保持零真实会话
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archW + '/task.json'), '-PlanFile', $pfW, '-AutoMode', '-NoPush')
    $bW = Read-BridgeJson 'deliver-qa-watch'
    $devW = [string]$bW.tasks.'1'.stages.DEV
    $null = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-watch', '-NodeId', $devW, '-Role', 'DEV')
    $r = Invoke-Bridge @('-Command', 'escalate', '-RunId', 'deliver-qa-watch', '-NodeId', $devW, '-Checkpoint', '技术选型', '-Decision', 'A 还是 B？', '-Risk', 'high')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.kind -eq 'escalation') 'QA12 escalate records an open escalation (engine write side)' ($r.raw)
    $escId = [string]$r.json.data.entry.entry_id
    $archLedgerW = Join-Path $Work ($archW + '/decisions.jsonl')
    $runLedgerW = Join-Path $Work '.rdd/goal-trees/deliver-qa-watch/decisions.jsonl'
    Assert-True ((Test-Path -LiteralPath $archLedgerW -PathType Leaf) -and -not (Test-Path -LiteralPath $runLedgerW)) 'QA12 engine ledger lands at the ARCHIVE root only, no run-dir copy (R1 write side)' ("archive=$archLedgerW run=$runLedgerW exists=$(Test-Path -LiteralPath $runLedgerW)")
    $w = Get-WatcherOpenEntries $Work
    $hit = @($w.json.open | Where-Object { [string]$_.runId -eq 'deliver-qa-watch' -and [string]$_.entryId -eq $escId })
    Assert-True ($w.exit -eq 0 -and $null -ne $w.json -and $hit.Count -eq 1) 'QA12 plugin watcher collects the engine-written escalation through bridge.json archive_rel (R1 read side)' ($w.raw)
    Assert-True ($hit.Count -eq 1 -and [string]$hit[0].checkpoint -eq '技术选型' -and [string]$hit[0].question -eq 'A 还是 B？' -and [string]$hit[0].nodeId -eq $devW -and [string]$hit[0].risk -eq 'high') 'QA12 projected inbox row keeps the wire shape (checkpoint/question/nodeId/risk)' ((@($hit) | ConvertTo-Json -Depth 4 -Compress))
    # 阴性对照（证明本锚是活的、且读的确实是 archive_rel 解析出的那一份）：把 archive_rel
    # 指向不存在的归档 → watcher 读空；还原后立刻又读到。即：读端若退回 run 目录（R1 形态），
    # 在本夹具上必然读空——本 run 无 run-dir 账本（上一断言已机械钉定）。
    $bpW = Join-Path $Work '.rdd/goal-trees/deliver-qa-watch/bridge.json'
    $bwJson = Get-Content -LiteralPath $bpW -Raw -Encoding UTF8 | ConvertFrom-Json
    $archRelW = [string]$bwJson.archive_rel
    $bwJson.archive_rel = '.rdd/changes/archive/qa-watch-nonexistent'
    Write-Utf8NoBom $bpW ($bwJson | ConvertTo-Json -Depth 10)
    $wNeg = Get-WatcherOpenEntries $Work
    $negHit = @($wNeg.json.open | Where-Object { [string]$_.runId -eq 'deliver-qa-watch' })
    Assert-True ($negHit.Count -eq 0) 'QA12 negative control: a bogus archive_rel yields nothing (the read follows bridge.json, no run-dir fallback hit here)' ($wNeg.raw)
    $bwJson.archive_rel = $archRelW
    Write-Utf8NoBom $bpW ($bwJson | ConvertTo-Json -Depth 10)
    $w = Get-WatcherOpenEntries $Work
    $restored = @($w.json.open | Where-Object { [string]$_.runId -eq 'deliver-qa-watch' -and [string]$_.entryId -eq $escId })
    Assert-True ($restored.Count -eq 1) 'QA12 restoring archive_rel brings the escalation straight back (live read, no cached verdict)' ($w.raw)
    $r = Invoke-Bridge @('-Command', 'decide', '-RunId', 'deliver-qa-watch', '-NodeId', $devW, '-Kind', 'resolution', '-RefEntry', $escId, '-Checkpoint', '技术选型', '-Decision', '选 A')
    Assert-True ($r.json.success -eq $true) 'QA12 user verdict recorded as resolution on the same ledger' ($r.raw)
    $w = Get-WatcherOpenEntries $Work
    $after = @($w.json.open | Where-Object { [string]$_.runId -eq 'deliver-qa-watch' })
    Assert-True ($after.Count -eq 0) 'QA12 resolution immediately closes the escalation for the watcher (fresh read, join-derived, no stale delivery)' ($w.raw)
    # legacy 兜底：无 bridge.json 的 pre-migration 形态（账本在 run 目录）仍可读，迁移不放退
    $legacyRun = Join-Path $Work '.rdd/goal-trees/qa-legacy-run'
    New-Item -ItemType Directory -Path (Join-Path $legacyRun 'state') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $legacyRun 'manifest.json') '{"run_id":"qa-legacy-run","state":"running","goal":"legacy","budget":{"max_rounds":2,"max_nodes":6}}'
    Write-Utf8NoBom (Join-Path $legacyRun 'decisions.jsonl') '{"entry_id":"D1","node_id":"n1","kind":"escalation","checkpoint":"成本","decision":"允许外呼吗？","risk":"high"}'
    $w = Get-WatcherOpenEntries $Work
    $lg = @($w.json.open | Where-Object { [string]$_.runId -eq 'qa-legacy-run' -and [string]$_.entryId -eq 'D1' })
    Assert-True ($lg.Count -eq 1 -and [string]$lg[0].question -eq '允许外呼吗？') 'QA12 legacy run-dir ledger still readable (pre-migration fallback 不退步)' ($w.raw)

    # ================= QA13: 派生 PM 节点回收（需求边界「中断幂等」，上轮在册覆盖缺口） =================
    # 上一轮验收在册备忘：derive 后 PM 节点回收复用 reclaim dead-claim / rejected-delivery 同族
    # 通道「已实现未测」。本锚补齐两条：①dead-claim → steal 重推；②rejected-delivery（无
    # extras.verification 的不合格重报）→ prune + 同源重建 PM 节点 + derivations[].node 重锚，
    # 且派生状态保持 confirmed（未入册）。
    # L3（reclaim-unproven-dead-gate）：夹具 claim 是 CLI 认领 → 边车无 dsh 会话绑定 →
    # liveness 恒 unknown，「-DeadClaimMinutes 0」这种「阈值当死亡证明」的旧夹具手法不再放行
    # （RECLAIM_DEATH_UNPROVEN_NEEDS_VERDICT）。按新契约补用户裁决原文（同一硬门与
    # derive confirm / budget 同形；裁决原文入归档决策账本）。
    $archR = New-QaArchive 'qa-reclaim' '[{"title":"回收夹具","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $pfR = Write-QaPlan (Join-Path $Work 'qa-reclaim-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archR + '/task.json'), '-PlanFile', $pfR, '-NoPush')
    $null = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-reclaim', '-Action', 'propose', '-Title', '回收派生', '-Rationale', '中断幂等验证')
    $r = Invoke-Bridge @('-Command', 'derive', '-RunId', 'deliver-qa-reclaim', '-Action', 'confirm', '-DerivationId', 'DRV1', '-UserVerdict', '同意派生（回收验证）')
    $bR = Read-BridgeJson 'deliver-qa-reclaim'
    $pmR = [string](Get-Der $bR 'DRV1').node
    $goalRootR = [string]$bR.goal_root
    $r = Invoke-Leaf @('-Command', 'claim', '-RunId', 'deliver-qa-reclaim', '-NodeId', $pmR, '-Worker', 'PM')
    Assert-True ($r.json.success -eq $true) 'QA13 fixture: derivation PM node claimed by a worker' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-qa-reclaim', '-NodeId', $pmR, '-DeadClaimMinutes', '0', '-UserVerdict', '确认该会话已死，同意回收派生 PM 节点')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'dead-claim (tree-level derivation PM node)' -and [int]$r.json.data.steal_count -eq 1) 'QA13 derivation node routes into the tree-level dead-claim channel (steal + repush)' ($r.raw)
    $nodeR = @(Read-TreeNodes 'deliver-qa-reclaim' | Where-Object { [string]$_.id -eq $pmR })[0]
    Assert-True ($null -ne $nodeR -and [string]$nodeR.status -eq 'claimed' -and [string]$nodeR.claimed_by -eq 'planner-reclaim') 'QA13 stolen node parks under planner-reclaim (derivation node id unchanged)' ("status=$([string]$nodeR.status) by=$([string]$nodeR.claimed_by)")
    $cbBad = Join-Path $env:TEMP ("qa-badcb-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    Write-Utf8NoBom $cbBad (@{ node_id = $pmR; verdict = 'done'; confidence = 0.9; summary = '不合格交付（无 verification）'; citations = @(@{ ref = "$archR/requirements/t1.md"; locator = 'L1' }); next_suggestion = '' } | ConvertTo-Json -Depth 5)
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-qa-reclaim', '-Worker', 'planner-reclaim', '-CallbackFile', $cbBad)
    Assert-True ($r.json.success -eq $true) 'QA13 unqualified PM report accepted (verdict=done, extras.verification absent)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-qa-reclaim', '-NodeId', $pmR)
    $newPm = [string]$r.json.data.node_id
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery (tree-level derivation PM node)' -and [string]$r.json.data.pruned_node -eq $pmR) 'QA13 rejected delivery rebuilds the derivation PM node (prune + same-source graft)' ($r.raw)
    $bR = Read-BridgeJson 'deliver-qa-reclaim'
    $dR = Get-Der $bR 'DRV1'
    Assert-True ($newPm -ne '' -and $newPm -ne $pmR -and [string]$dR.node -eq $newPm -and [string]$dR.status -eq 'confirmed' -and $null -eq $dR.task_id) 'QA13 bridge derivation re-anchored to the rebuilt node (stays confirmed, not registered)' ((@($dR) | ConvertTo-Json -Depth 4 -Compress))
    $newNodeR = @(Read-TreeNodes 'deliver-qa-reclaim' | Where-Object { [string]$_.id -eq $newPm })[0]
    Assert-True ($null -ne $newNodeR -and [string]$newNodeR.parent -eq $goalRootR -and [string]$newNodeR.role -eq 'pm' -and [string]$newNodeR.status -eq 'pending') 'QA13 rebuilt node is a goal-root PM child awaiting a fresh claim (same shape as the original)' ("parent=$([string]$newNodeR.parent) role=$([string]$newNodeR.role) status=$([string]$newNodeR.status)")
    $oldNodeR = @(Read-TreeNodes 'deliver-qa-reclaim' | Where-Object { [string]$_.id -eq $pmR })[0]
    Assert-True ($null -ne $oldNodeR -and [string]$oldNodeR.status -eq 'pruned') 'QA13 the rejected node is pruned (one live PM node per derivation)' ("status=$([string]$oldNodeR.status)")

    # ================= QA11: BOM 自检（tips 义务） =================
    foreach ($f in @($BridgePs1, $FlowPs1, $PSCommandPath)) {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $n = Split-Path $f -Leaf
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "QA11 $n first-3-bytes = 239,187,191 (BOM intact)" ("got {0},{1},{2}" -f $bytes[0], $bytes[1], $bytes[2])
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

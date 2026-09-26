# dep-notation QA black-box probe — 需求模板「依赖关系标注规范」文档声明与推导实现一致性
# 需求: 2026-09-26-requirement-dependency-field (验收标准 1/2/3)
# 规范单源: rdd-pm/references/requirement-item-template.md「依赖关系标注规范」
# 方法: 黑盒驱动 PS5.1 生产解释器(delivery-bridge promulgate -NoPush), 断言:
#   - 规范形态推导命中 + 建边 + 阻塞不错序 (TC-B103, 含 settle 解锁)
#   - 规范文档逐条声明与实际推导结果一致 (TC-B104~B109)
# TC-B105 是文档一致性断言(docClaim vs actual): 模板声明「备注不参与推导」, 解析正则
# 却扫描整行——备注中出现不同编号会被推导为额外依赖。两侧任一修正(改文档声明或改
# 解析器剥离备注)后本断言转绿; 现状应为 FAIL, 即 QA 报告的缺陷证据。
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# engine root: 从脚本位置逐级上溯找 rdd-engine/scripts/rdd-flow.ps1 (三级定位链的项目内分支)
$EngineDir = $null
$cur = $PSScriptRoot
while ($cur -and -not $EngineDir) {
    if (Test-Path (Join-Path $cur 'rdd-engine\scripts\rdd-flow.ps1')) { $EngineDir = Join-Path $cur 'rdd-engine\scripts' }
    $parent = Split-Path -Parent $cur
    if ($parent -eq $cur) { break }
    $cur = $parent
}
if (-not $EngineDir) { $EngineDir = Join-Path $env:RDD_ENGINE_HOME 'scripts' }
if (-not (Test-Path (Join-Path $EngineDir 'delivery-bridge.ps1'))) { throw "rdd-engine scripts not located" }
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('dep-notation-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
# New archive: 8 tasks, all [CTO] heads; dep fields rewritten by caller (legacy form here only for t7)
function New-Archive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`n依赖标注规范 QA 探针归档 $Name。`n`n## 整体验收判据`n`n无整体判据（理由：机读依赖标注黑盒探针归档，无整体验收场景）`n"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir ("requirements/t$i.md")) "# $Name 需求 $i`n`n- **描述**：依赖标注探针 $i`n- **验收标准**：见 requirement-item-template.md`n"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}
# Minimal PlanFile writer: single stage, batches = topological layers under the dep map
function Write-TestPlan { param([string]$Path, [int[]]$TaskIds, $Deps)
    $pending = @($TaskIds)
    $batches = @()
    while ($pending.Count -gt 0) {
        $batch = @($pending | Where-Object {
            $t = [int]$_
            @(@($Deps[$t]) | Where-Object { $pending -contains [int]$_ }).Count -eq 0
        })
        if ($batch.Count -eq 0) { throw "Write-TestPlan: cyclic deps" }
        $batches += ,@($batch | Sort-Object)
        $pending = @($pending | Where-Object { $batch -notcontains [int]$_ })
    }
    $plan = [ordered]@{
        planned_at = '2026-09-26T00:00:00Z'; planner = 'qa-probe'
        stages = @(@{ id = 'S1'; goal = 'stage S1 目标'; milestone = 'stage S1 里程碑'
                      task_ids = @($TaskIds | Sort-Object); batches = $batches
                      acceptance_point = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' } })
        risks = @()
    }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}
function New-Cb { param([string]$NodeId, [string]$Ref)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'dep-notation QA probe delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok' }
    }
    $cbFile = Join-Path $env:TEMP ("dn-qa-cb-$NodeId.json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-Cb $NodeId $Ref
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}
function Get-Head { param($Bridge, [int]$TaskId) [string]$Bridge.tasks."$TaskId".stages.CTO }
function Get-Deps { param([string]$RunId, [string]$NodeId)
    $n = Find-TreeNode $RunId $NodeId
    if ($null -eq $n) { return @() }
    return @(@($n.depends_on) | ForEach-Object { [string]$_ })
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # ================= qa-dn1: 规范声明逐条一致性 (TC-B103~B108) =================
    $arch1 = New-Archive 'qa-dn1' '[{"title":"上游","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]},{"title":"规范单依赖","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[]},{"title":"规范多依赖","requirement":"requirements/t3.md","currentOwners":["CTO"],"designDocs":[]},{"title":"备注同编号","requirement":"requirements/t4.md","currentOwners":["CTO"],"designDocs":[]},{"title":"备注异编号","requirement":"requirements/t5.md","currentOwners":["CTO"],"designDocs":[]},{"title":"跨行依赖","requirement":"requirements/t6.md","currentOwners":["CTO"],"designDocs":[]},{"title":"旧式部分命中","requirement":"requirements/t7.md","currentOwners":["CTO"],"designDocs":[]},{"title":"软引用","requirement":"requirements/t8.md","currentOwners":["CTO"],"designDocs":[]}]'
    # 按「依赖关系标注规范」写入各字段形态（与 PM 实际书写一致）
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t2.md')) "# qa-dn1 需求 2`n`n- **描述**：规范单依赖`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#1`n"
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t3.md')) "# qa-dn1 需求 3`n`n- **描述**：规范多依赖`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#1、#2`n"
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t4.md')) "# qa-dn1 需求 4`n`n- **描述**：备注重复同编号(规范正例形态)`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#1（#1 提供批次推导数据）`n"
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t5.md')) "# qa-dn1 需求 5`n`n- **描述**：备注出现不同编号(文档声称备注不参与推导)`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#1（上游 #2 提供数据）`n"
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t6.md')) "# qa-dn1 需求 6`n`n- **描述**：依赖写在两行(规范要求同一行)`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#1`n  依赖：#2`n"
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t7.md')) "# qa-dn1 需求 7`n`n- **描述**：旧式「依赖需求 1、3」(规范反例 2)`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖需求 1、3`n"
    Write-Utf8NoBom (Join-Path $Work ($arch1 + '/requirements/t8.md')) "# qa-dn1 需求 8`n`n- **描述**：指向不存在编号(软引用)`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#9`n"
    # PlanFile 依赖图 = 实际推导结果(黑盒观察值, 与推导一致以排除计划面干扰)
    $planDeps = @{ 2 = @(1); 3 = @(1, 2); 4 = @(1); 5 = @(1, 2); 6 = @(1); 7 = @(1) }
    $pf1 = Write-TestPlan (Join-Path $Work 'qa-dn1-plan.json') @(1..8) $planDeps
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'TC-B103 promulgate ok (机读标注归档建树成功)' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-dn1'
    $h1 = Get-Head $b 1; $h2 = Get-Head $b 2; $h3 = Get-Head $b 3; $h4 = Get-Head $b 4
    $h5 = Get-Head $b 5; $h6 = Get-Head $b 6; $h7 = Get-Head $b 7; $h8 = Get-Head $b 8

    # TC-B103: 规范形态(单项/多项)推导命中 + 建边 + 依赖方阻塞不错序 + settle 解锁
    $d2 = ((@($b.tasks.'2'.dep_task_ids) | Sort-Object) -join '+')
    $d3 = ((@($b.tasks.'3'.dep_task_ids) | Sort-Object) -join '+')
    Assert-True ($d2 -eq '1' -and $d3 -eq '1+2') 'TC-B103 规范形态推导命中(依赖：#1 → @(1); 依赖：#1、#2 → @(1,2))' ("t2=$d2 t3=$d3")
    $n2d = Get-Deps 'deliver-qa-dn1' $h2
    $n3d = Get-Deps 'deliver-qa-dn1' $h3
    Assert-True (($n2d -join '+') -eq $h1 -and (@($n3d | Sort-Object) -join '+') -eq (@(@($h1, $h2) | Sort-Object) -join '+')) 'TC-B103 树边落地(下游链头 depends_on 上游链头)' ("h2deps=$($n2d -join '+') h3deps=$($n3d -join '+') expected=$h1+$(@(@($h1, $h2) | Sort-Object) -join '+')")
    $nx = Invoke-Leaf @('-Command', 'next', '-RunId', 'deliver-qa-dn1')
    $blockedIds = @(@($nx.json.data.blocked) | ForEach-Object { [string]$_.id })
    $pendingIds = @(@($nx.json.data.pending) | ForEach-Object { [string]$_.id })
    Assert-True (($blockedIds -contains $h2) -and ($blockedIds -contains $h3)) 'TC-B103 依赖方在上游 settle 前 BLOCKED(不错序推送)' ("blocked=$($blockedIds -join '+')")
    $ref1 = "$arch1/requirements/t1.md"
    Do-Deliver 'deliver-qa-dn1' $h1 'CTO' $ref1
    $r1 = Do-Settle 'deliver-qa-dn1' $h1
    Assert-True ($r1.json.success -eq $true) 'TC-B103 上游 settle' ($r1.raw)
    $nx = Invoke-Leaf @('-Command', 'next', '-RunId', 'deliver-qa-dn1')
    $pendingIds = @(@($nx.json.data.pending) | ForEach-Object { [string]$_.id })
    $blockedIds = @(@($nx.json.data.blocked) | ForEach-Object { [string]$_.id })
    Assert-True (($pendingIds -contains $h2) -and ($blockedIds -contains $h3)) 'TC-B103 上游终态后单依赖解锁, 多依赖仍阻塞' ("pending=$($pendingIds -join '+') blocked=$($blockedIds -join '+')")

    # TC-B104: 备注重复同编号 → 去重后仅命中主编号(规范正例成立)
    $d4 = ((@($b.tasks.'4'.dep_task_ids) | Sort-Object) -join '+')
    Assert-True ($d4 -eq '1') 'TC-B104 备注重复同编号去重(依赖：#1（#1 提供数据）→ @(1))' ("t4=$d4")

    # TC-B105: 文档一致性——模板声明「备注不参与推导」, 期望 @(1); 实际推导见 detail。
    # 两侧任一修正(模板改声明 / 解析器剥离备注)后本断言转绿。
    $docClaim5 = @(1)
    $actual5 = @(@($b.tasks.'5'.dep_task_ids) | Sort-Object)
    Assert-True ((($actual5 | ForEach-Object { [int]$_ }) -join '+') -eq (($docClaim5 | ForEach-Object { [int]$_ }) -join '+')) 'TC-B105 文档声明一致性: 备注不参与推导(依赖：#1（上游 #2 提供数据）文档期望 @(1))' ("actual=[$(@($actual5) -join '+')] docClaim=[$($docClaim5 -join '+')] — 备注中的 #2 被实际推导为依赖")

    # TC-B106: 依赖写两行 → 仅第一行参与(规范填写规则 3)
    $d6 = ((@($b.tasks.'6'.dep_task_ids) | Sort-Object) -join '+')
    Assert-True ($d6 -eq '1') 'TC-B106 推导只读字段第一行(第二行 依赖：#2 不命中)' ("t6=$d6")

    # TC-B107: 旧式「依赖需求 1、3」→ 只有 1 命中(规范反例 2: 每个编号须自带前缀)
    $d7 = ((@($b.tasks.'7'.dep_task_ids) | Sort-Object) -join '+')
    Assert-True ($d7 -eq '1') 'TC-B107 旧式列表仅首个命中(依赖需求 1、3 → @(1))' ("t7=$d7")

    # TC-B108: 软引用——指向不存在编号静默丢弃, 不报错
    $d8 = @(@($b.tasks.'8'.dep_task_ids)).Count
    Assert-True ($d8 -eq 0) 'TC-B108 软引用静默丢弃(依赖：#9 → @(), 建树成功)' ("t8count=$d8")

    # ================= qa-dn2: 前向引用丢边 (TC-B109) =================
    $arch2 = New-Archive 'qa-dn2' '[{"title":"上游","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]},{"title":"前向引用方","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[]},{"title":"后建任务","requirement":"requirements/t3.md","currentOwners":["CTO"],"designDocs":[]}]'
    Write-Utf8NoBom (Join-Path $Work ($arch2 + '/requirements/t2.md')) "# qa-dn2 需求 2`n`n- **描述**：前向引用(规范反例 3)`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#3`n"
    Write-Utf8NoBom (Join-Path $Work ($arch2 + '/requirements/t3.md')) "# qa-dn2 需求 3`n`n- **描述**：回向依赖`n- **验收标准**：见 requirement-item-template.md`n- **依赖关系**：依赖：#1`n"
    $pf2 = Write-TestPlan (Join-Path $Work 'qa-dn2-plan.json') @(1, 2, 3) @{ 2 = @(3); 3 = @(1) }
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-PlanFile', $pf2, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'TC-B109 前向引用归档建树成功' ($r.raw)
    $b2 = Read-BridgeJson 'deliver-qa-dn2'
    $g1 = Get-Head $b2 1; $g2 = Get-Head $b2 2; $g3 = Get-Head $b2 3
    $d2f = ((@($b2.tasks.'2'.dep_task_ids) | Sort-Object) -join '+')
    Assert-True ($d2f -eq '3') 'TC-B109 前向引用记入 dep_task_ids(依赖：#3 → @(3) 有账)' ("t2=$d2f")
    $n2fd = Get-Deps 'deliver-qa-dn2' $g2
    Assert-True (($n2fd -contains $g3) -eq $false) 'TC-B109 前向引用不落树边(单遍建树只回连先建节点)' ("h2deps=$($n2fd -join '+') h3=$g3")
    $nx2 = Invoke-Leaf @('-Command', 'next', '-RunId', 'deliver-qa-dn2')
    $blocked2 = @(@($nx2.json.data.blocked) | ForEach-Object { [string]$_.id })
    Assert-True (-not ($blocked2 -contains $g2)) 'TC-B109 前向引用方不被阻塞(过早推送风险, 与规范反例 3 声明一致)' ("blocked=$($blocked2 -join '+')")
}
finally {
    Pop-Location
}

$fail = @($Results | Where-Object { -not $_.ok })
Write-Output ("`nSummary: {0}/{1} passed" -f ($Results.Count - $fail.Count), $Results.Count)
if ($fail.Count -gt 0) { exit 1 } else { exit 0 }

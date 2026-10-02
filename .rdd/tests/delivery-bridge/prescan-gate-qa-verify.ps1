# prescan-gate QA black-box probe — DEV 出报前质量自检机械门（dev-quality-prescan-gate）
# 需求: 2026-10-01-planner-delivery-efficiency/requirements/dev-quality-prescan-gate.md (验收标准 1-5)
# 方法: 黑盒驱动 PS5.1 生产解释器（rdd-flow init/set-route + delivery-bridge promulgate/claim/settle/reclaim
#       + goal-tree-leaf report），独立于 DEV 套件 test-handoff-gate.ps1 从需求侧复验：
#   - AC2/AC5 三路径: 凭据缺失拒(TC-B112) / 违规>0 拒(TC-B113) / skip 声明放行(TC-B114)
#   - AC1 凭据四要素字段级: 缺 tool(TC-B115) / 缺 files(TC-B116) / 计数非负边界 -1(TC-B117) / 退出码矛盾(TC-B118)
#   - AC2 处置通道: 门拒后 reclaim rejected-delivery 可用、节点停 reported(TC-B112/B119)
#   - AC1 正向: 完整形凭据覆盖 cited .ps1 全链放行(TC-B120) + claim 契约可见性(TC-B121)
#   - AC2 链式形态: set-route 缺凭据 HANDOFF_GATE_REJECTED + task.json 零残留(TC-B122) / skip 放行(TC-B123) /
#     完整形放行(TC-B124) / 未注册角色空转(TC-B125 前置)
#   - AC3 单源同步: docs §1 50行/5层 + execution-rules 出报门 + planner-guide 凭据四查(TC-B125)
#   - AC4 双保险: QA 复扫职责文件不在变更集且复扫指令仍在(TC-B126)
# Exit code 0 = all green.
#
# 注: 本文件含中文字符串断言，须以 UTF-8 **带 BOM** 落盘（PS5.1 无 BOM 按 ANSI 误读）。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# engine root: 从脚本位置逐级上溯找 rdd-engine/scripts/rdd-flow.ps1（三级定位链的项目内分支）
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
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $EngineDir)
$Work      = Join-Path $env:TEMP ('prescan-gate-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
function Read-TaskJson { param([string]$ArchRel)
    $p = Join-Path $Work ($ArchRel + '/task.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).tasks[0]
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    $nodes = @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
    foreach ($n in $nodes) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}

# 凭据预设（契约的完整形 / skip 形——按需求验收标准 1 的四要素构造）
$FullBase = @{
    tool = 'code-metrics 1.0'; base = 'HEAD'
    files = @('fixtures/code.ps1')
    thresholds = 'function<=50 lines, nesting<=5 depth'
    threshold_source = 'docs/code-quality.md #1'
    violation_count = 0; exit_code = 0
}
$SkipOk = @{ skip = $true; reason = 'no PowerShell file in the change set (docs-only delivery)' }

# 单任务归档 + promulgate -NoPush（返回 @{ arch; run }）。$Owners 决定 init 时的 currentOwners/phase。
function New-RunFixture { param([string]$Name, [string[]]$Owners)
    $archRel = ".rdd/changes/archive/$Name"
    $archDir = Join-Path $Work $archRel
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/t1.md') "# $Name`n`nprescan-gate QA probe fixture`n"
    $tf = Join-Path $Work "$Name-init.json"
    Write-Utf8NoBom $tf ('[{"title":"PG","requirement":"requirements/t1.md","currentOwners":["' + ($Owners -join '","') + '"],"designDocs":[]}]')
    $r = Invoke-Flow @('-Command', 'init', '-Archive', $archRel, '-TasksFile', "$Name-init.json")
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    $plan = @{
        planned_at = '2026-10-02T00:00:00Z'; planner = 'qa-probe'; risks = @()
        stages = @(@{ id = 'S1'; goal = 'goal'; milestone = 'ms'; task_ids = @(1); batches = @(@(1))
                     acceptance_point = @{ criteria_items = @('smoke'); slice = 'slice' } })
    }
    $planPath = Join-Path $Work "$Name-plan.json"
    Write-Utf8NoBom $planPath ($plan | ConvertTo-Json -Depth 8)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', (Join-Path $archRel 'task.json'), '-PlanFile', $planPath, '-NoPush')
    if ($r.json.success -ne $true) { throw "promulgate failed for $Name : $($r.raw)" }
    return @{ arch = $archRel; run = "deliver-$Name" }
}

# DEV 回调文件（$Scan: $null=不带凭据 / hashtable=凭据本体）
function New-DevCb { param([string]$NodeId, [string[]]$Refs, $Scan)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'prescan-gate QA probe delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'probe smoke ok' }
    }
    if ($null -ne $Scan) { $cb['extras'] = @{ verification = 'probe smoke ok'; quality_scan = $Scan } }
    $cbFile = Join-Path $env:TEMP ("pg-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 6)
    return $cbFile
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    New-Item -ItemType Directory -Path (Join-Path $Work 'fixtures') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $Work 'fixtures/code.ps1') "function Start-PgFixture { Write-Output 'pg' }`n"

    # ================= 链式场景（rdd-flow set-role gate） =================
    $chain = New-RunFixture 'pg-chain' @('DEV')
    $chainTaskJson = Join-Path $Work ($chain.arch + '/task.json')

    # TC-B122: DEV 退场缺凭据 -> HANDOFF_GATE_REJECTED + task.json 零残留（AC2 链式形态）
    $before = [System.IO.File]::ReadAllBytes($chainTaskJson)
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $chain.arch, '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'HANDOFF_GATE_REJECTED' -and $r.json.error.message -match 'quality_scan: credential absent') 'TC-B122 chain: DEV exit without credential -> HANDOFF_GATE_REJECTED (credential absent)' ($r.raw)
    $after = [System.IO.File]::ReadAllBytes($chainTaskJson)
    $t = Read-TaskJson $chain.arch
    Assert-True ((Compare-Object $before $after -SyncWindow 0) -eq $null -and (@($t.currentOwners) -join '+') -eq 'DEV' -and [string]$t.phase -eq 'IMPL') 'TC-B122 chain: task.json byte-identical after rejection (zero residue)' ((@($t.currentOwners) -join '+') + '@' + $t.phase)

    # TC-B123: skip+reason -> 放行（AC5 路径 3，链式）
    $skipFile = Join-Path $Work 'pg-chain-skip.json'
    Write-Utf8NoBom $skipFile ($SkipOk | ConvertTo-Json -Depth 4)
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $chain.arch, '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $skipFile)
    Assert-True ($r.json.success -eq $true -and (@($r.json.data.currentOwners) -join '+') -eq 'QA') 'TC-B123 chain: skip+reason declaration passes the gate' ($r.raw)

    # TC-B124: 完整形干净凭据 -> 放行（AC1 链式正向；先路由回 DEV）
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $chain.arch, '-TaskId', '1', '-To', 'DEV', '-Phase', 'IMPL')
    if ($r.json.success -ne $true) { throw "route back to DEV failed: $($r.raw)" }
    $fullFile = Join-Path $Work 'pg-chain-full.json'
    Write-Utf8NoBom $fullFile ($FullBase | ConvertTo-Json -Depth 6)
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $chain.arch, '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $fullFile)
    Assert-True ($r.json.success -eq $true -and (@($r.json.data.currentOwners) -join '+') -eq 'QA' -and [string]$r.json.data.phase -eq 'VERIFY') 'TC-B124 chain: clean full-form credential passes' ($r.raw)

    # TC-B125 前置: 未注册角色（CTO）退场空转放行（AC 边界: 门只挂 DEV 注册表）
    $narrow = New-RunFixture 'pg-narrow' @('CTO')
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $narrow.arch, '-TaskId', '1', '-To', 'UX')
    Assert-True ($r.json.success -eq $true -and (@($r.json.data.currentOwners) -join '+') -eq 'UX') 'TC-B125 pre: unregistered role exit (CTO->UX) no-ops the gate' ($r.raw)

    # ================= 桥接场景（delivery-bridge settle 第四查） =================
    $fx = New-RunFixture 'pg-bridge' @('DEV')
    function Get-DevNode { param($RunId) [string](Read-BridgeJson $RunId).tasks.'1'.stages.DEV }
    function Do-Cycle { param([string]$RunId, [string]$Action)
        # reclaim rejected-delivery -> 刷新 DEV 节点 -> claim（负例序列的推进器）
        $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $RunId, '-NodeId', (Get-DevNode $RunId))
        if ($r.json.success -ne $true) { throw "reclaim ($Action) failed: $($r.raw)" }
        $r2 = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', (Get-DevNode $RunId), '-Role', 'DEV')
        if ($r2.json.success -ne $true) { throw "claim ($Action) failed: $($r2.raw)" }
        return $r2
    }
    function Do-ReportSettle { param([string]$RunId, [string]$CbFile)
        $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', 'DEV', '-CallbackFile', $CbFile)
        if ($r.json.success -ne $true) { throw "report failed: $($r.raw)" }
        return Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', (Get-DevNode $RunId))
    }

    $devNode = Get-DevNode $fx.run
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $fx.run, '-NodeId', $devNode, '-Role', 'DEV')
    if ($r.json.success -ne $true) { throw "initial claim failed: $($r.raw)" }

    # TC-B112: citations 含 .ps1 而凭据缺失 -> SETTLE_EVIDENCE_REJECTED + 节点停 reported（AC2/AC5 路径 1）
    $r = Do-ReportSettle $fx.run (New-DevCb $devNode @('fixtures/code.ps1') $null)
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and $r.json.error.message -match 'quality_scan: credential absent') 'TC-B112 bridge: missing credential rejected with deterministic code' ($r.raw)
    $node = Find-TreeNode $fx.run $devNode
    Assert-True ($null -ne $node -and [string]$node.status -eq 'reported') 'TC-B112 bridge: node stays reported after rejection' ("status=$($node.status)")

    # TC-B119: 规划者处置通道——门拒后 reclaim rejected-delivery 可用（AC2）
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', $fx.run, '-NodeId', $devNode)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'TC-B119 bridge: reclaim rejected-delivery disposal channel intact' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $fx.run, '-NodeId', (Get-DevNode $fx.run), '-Role', 'DEV')
    if ($r.json.success -ne $true) { throw "claim after B119 failed: $($r.raw)" }

    # TC-B113: violation_count=3 -> 拒（AC2/AC5 路径 2）
    $bad = @{ tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'lim'; threshold_source = 'docs/code-quality.md #1'; violation_count = 3; exit_code = 1 }
    $r = Do-ReportSettle $fx.run (New-DevCb (Get-DevNode $fx.run) @('fixtures/code.ps1') $bad)
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and $r.json.error.message -match 'violation_count is 3') 'TC-B113 bridge: violation_count>0 rejected' ($r.raw)

    # TC-B115: 完整形缺 tool（工具标识）-> 拒（AC1 四要素）
    $null = Do-Cycle $fx.run 'B115'
    $noTool = @{ base = 'HEAD'; files = @('fixtures/code.ps1'); thresholds = 'lim'
        threshold_source = 'docs'; violation_count = 0; exit_code = 0 }
    $r = Do-ReportSettle $fx.run (New-DevCb (Get-DevNode $fx.run) @('fixtures/code.ps1') $noTool)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'missing required fields: tool') 'TC-B115 bridge: full form missing tool rejected' ($r.raw)

    # TC-B116: 完整形缺 files（作用文件集）-> 拒（AC1 四要素）
    $null = Do-Cycle $fx.run 'B116'
    $noFiles = @{ tool = 'code-metrics 1.0'; base = 'HEAD'; thresholds = 'lim'
        threshold_source = 'docs'; violation_count = 0; exit_code = 0 }
    $r = Do-ReportSettle $fx.run (New-DevCb (Get-DevNode $fx.run) @('fixtures/code.ps1') $noFiles)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'missing required fields: files') 'TC-B116 bridge: full form missing files rejected' ($r.raw)

    # TC-B117: violation_count=-1 -> 拒（非负整数边界）
    $null = Do-Cycle $fx.run 'B117'
    $neg = @{ tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'lim'; threshold_source = 'docs'; violation_count = -1; exit_code = 1 }
    $r = Do-ReportSettle $fx.run (New-DevCb (Get-DevNode $fx.run) @('fixtures/code.ps1') $neg)
    # -1 是 int，落入「必须为 0」分支拒绝；字符串形态才落「非负整数」分支——两者同为确定性拒
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and $r.json.error.message -match 'violation_count is -1 \(must be 0\)|violation_count must be a non-negative integer') 'TC-B117 bridge: negative violation_count rejected (non-negative boundary)' ($r.raw)

    # TC-B118: exit_code=0 与计数=2 矛盾 -> 拒（凭据自洽）
    $null = Do-Cycle $fx.run 'B118'
    $contra = @{ tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'lim'; threshold_source = 'docs'; violation_count = 2; exit_code = 0 }
    $r = Do-ReportSettle $fx.run (New-DevCb (Get-DevNode $fx.run) @('fixtures/code.ps1') $contra)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'contradicts violation_count') 'TC-B118 bridge: exit_code/count contradiction rejected' ($r.raw)

    # TC-B114: skip+reason + .md-only citations -> settle 放行 + 流转 QA@VERIFY（AC5 路径 3，桥接全链）
    $null = Do-Cycle $fx.run 'B114'
    $r = Do-ReportSettle $fx.run (New-DevCb (Get-DevNode $fx.run) @(($fx.arch + '/requirements/t1.md')) $SkipOk)
    Assert-True ($r.json.success -eq $true) 'TC-B114 bridge: skip declaration settles ok' ($r.raw)
    $t = Read-TaskJson $fx.arch
    Assert-True ((@($t.currentOwners) -join '+') -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'TC-B114 bridge: flow tail passed the chain gate (QA@VERIFY)' ((@($t.currentOwners) -join '+') + '@' + $t.phase)

    # TC-B120/B121: 独立正向 fixture——完整形凭据覆盖 cited .ps1 全链放行 + claim 契约可见性
    $full = New-RunFixture 'pg-full' @('DEV')
    $devF = Get-DevNode $full.run
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $full.run, '-NodeId', $devF, '-Role', 'DEV')
    if ($r.json.success -ne $true) { throw "claim pg-full failed: $($r.raw)" }
    Assert-True ($r.json.data.report_hint -match 'quality_scan' -and $r.json.data.report_hint -match 'violation_count must be 0') 'TC-B121 bridge: claim report_hint carries the credential contract' ([string]$r.json.data.report_hint)
    Assert-True ($r.json.data.start_context -match 'extras\.quality_scan') 'TC-B121 bridge: claim start_context carries the DEV note' ([string]$r.json.data.start_context)

    $r = Do-ReportSettle $full.run (New-DevCb $devF @('fixtures/code.ps1') $FullBase)
    Assert-True ($r.json.success -eq $true) 'TC-B120 bridge: full-form credential covering cited .ps1 settles ok' ($r.raw)
    $t = Read-TaskJson $full.arch
    Assert-True ((@($t.currentOwners) -join '+') -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'TC-B120 bridge: task routed to QA@VERIFY through both gates' ((@($t.currentOwners) -join '+') + '@' + $t.phase)
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

# ================= 文档单源断言（AC3/AC4，真实仓库静态检查） =================
$cq = Get-Content (Join-Path $RepoRoot 'docs\code-quality.md') -Raw -Encoding UTF8
Assert-True ($cq -match '单个函数不超过 50 行' -and $cq -match '嵌套不超过 5 层') 'TC-B125 docs: code-quality.md S1 remains the single threshold source (50 lines / 5 levels)' ''
$er = Get-Content (Join-Path $RepoRoot 'rdd-dev\references\execution-rules.md') -Raw -Encoding UTF8
Assert-True ($er -match '出报门' -and $er -match 'quality_scan' -and $er -match 'SETTLE_EVIDENCE_REJECTED' -and $er -match 'HANDOFF_GATE_REJECTED') 'TC-B125 docs: execution-rules.md upgraded to reporting-gate wording with credential contract' ''
$pg = Get-Content (Join-Path $RepoRoot 'rdd-engine\references\planner-guide.md') -Raw -Encoding UTF8
Assert-True ($pg -match '凭据四查' -and $pg -match 'extras\.quality_scan' -and $pg -match 'docs/code-quality\.md` §1') 'TC-B125 docs: planner-guide.md settle contract table synced (four checks + quality_scan row)' ''

# TC-B126: QA 后置复扫职责保留（AC4 双保险）——文件不在本次变更集 + #4/#5 复查指令仍在
$qaCheck = Get-Content (Join-Path $RepoRoot 'rdd-qa\references\code-quality-check.md') -Raw -Encoding UTF8
Assert-True ($qaCheck -match 'code-metrics\.cmd -Command scan' -and $qaCheck -match '函数 > 50 行' -and $qaCheck -match '嵌套 > 5 层') 'TC-B126 docs: QA re-scan duty intact in code-quality-check.md (#4/#5 recheck rows)' ''
$orig = Get-Location
Set-Location $RepoRoot
try { $touched = @(git diff --name-only HEAD -- 'rdd-qa/references/code-quality-check.md') } finally { Set-Location $orig }
Assert-True ($touched.Count -eq 0) 'TC-B126 docs: code-quality-check.md untouched by this change set' ($touched -join ',')

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ""
Write-Output ("prescan-gate-qa tests: {0} passed, {1} failed" -f ($Results.Count - $failed.Count), $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

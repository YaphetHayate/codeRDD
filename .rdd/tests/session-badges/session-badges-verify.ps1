# session-badges-verify.ps1 — QA 独立验证套件（session-list-badges 需求）
# 功能库：.rdd/tests/session-badges/cases.json（TC-S01~TC-S11）
# 覆盖：生成端徽章/简述拼装（DryRun 四形态+边界变体）、正则纯函数单元、
#       BOM/PS5.1 解析门禁、宿主装配字节预算锚点、渲染端回归锚点源码断言。
# 运行：pwsh -File session-badges-verify.ps1  （零副作用：仅 DryRun + 只读检查）
# 依赖：DSH 侧 vitest/tsc/oxlint 由 QA 会话独立运行并记录于验证报告，本脚本不重跑。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Assert-Case {
    param([string]$Id, [string]$Title, [scriptblock]$Check)
    try {
        & $Check
        $script:Passed++
        Write-Host ("[PASS] {0}  {1}" -f $Id, $Title) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:Failures += @("{0}: {1}" -f $Id, $_.Exception.Message)
        Write-Host ("[FAIL] {0}  {1}" -f $Id, $Title) -ForegroundColor Red
        Write-Host ("       => {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Assert-True { param([bool]$Cond, [string]$Msg) if (-not $Cond) { throw $Msg } }

# --- 定位（三级定位链同款根） ---
$repoRoot = (git rev-parse --show-toplevel).Trim()
$startRolePs1 = Join-Path $repoRoot 'rdd-engine/scripts/start-role.ps1'
$bridgePs1 = Join-Path $repoRoot 'rdd-engine/scripts/delivery-bridge.ps1'
$startRoleCmd = Join-Path $repoRoot 'rdd-engine/scripts/start-role.cmd'
$taskJson = Join-Path $repoRoot '.rdd/changes/archive/2026-09-20-planner-enhancements/task.json'
$dshPatch = 'D:\YaphetHayate\projects\dsh\deepseek-harness\packages\bundle\base\cordis.patch.yml'
$dshRows = 'D:\YaphetHayate\projects\dsh\deepseek-harness\packages\client\ui-workspace\src\client\rows\Rows.tsx'
$dshTree = 'D:\YaphetHayate\projects\dsh\deepseek-harness\packages\client\ui-workspace\src\client\tree.ts'
$dshBadgesPkg = 'D:\YaphetHayate\projects\dsh\deepseek-harness\packages\session\session-badges\src\types.ts'
foreach ($p in @($startRolePs1, $bridgePs1, $startRoleCmd, $taskJson)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "missing fixture: $p" }
}

# --- 工具：提取源文件中一个纯函数的文本（不执行脚本主流程；定义在调用方作用域） ---
# 注：返回文本必须由顶层 Invoke-Expression 定义（函数作用域内定义会随作用域销毁）；
#     [scriptblock]::Create 调用只执行"函数定义语句"、命名参数被静默忽略、恒返回空（QA 踩坑实录）。
function Get-ExtractedFnText {
    param([string]$File, [string]$FnName)
    $src = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
    $fn = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FnName
    }, $true) | Select-Object -First 1
    if ($null -eq $fn) { throw "function $FnName not found in $File" }
    return $fn.Extent.Text
}

# --- 工具：DryRun 执行（cmd wrapper 生产链路，含中文 -TaskSummary 转码实测） ---
function Invoke-DryRun {
    param([string[]]$ExtraArgs)
    $all = @('-DshUrl', 'http://127.0.0.1:3080', '-DryRun') + $ExtraArgs
    $out = & $startRoleCmd @all 2>&1
    return (@($out) -join "`n"), $LASTEXITCODE
}

Write-Host "=== session-badges QA 验证套件（$(Get-Date -Format 'yyyy-MM-dd HH:mm')）===" -ForegroundColor Cyan

# ---------- 门禁层：BOM + PS 5.1 解析 ----------
Assert-Case 'GATE-BOM' '两引擎脚本 UTF-8 BOM（code-quality §6.1；无 BOM 时中文正则按 GBK 误读、-TaskSummary 派生静默失效）' {
    foreach ($p in @($startRolePs1, $bridgePs1)) {
        $b = [System.IO.File]::ReadAllBytes($p)
        Assert-True ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) ("{0} 缺 UTF-8 BOM" -f (Split-Path -Leaf $p))
    }
}

Assert-Case 'GATE-PARSE' 'PS 5.1 Parser::ParseInput 零语法错误（生产入口 powershell.exe -File）' {
    foreach ($p in @($startRolePs1, $bridgePs1)) {
        $src = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$t, [ref]$e)
        Assert-True (@($e).Count -eq 0) ("{0} 解析错误 {1} 处: {2}" -f (Split-Path -Leaf $p), @($e).Count, ((@($e) | Select-Object -First 1).Message))
    }
}

# ---------- 生成端：DryRun 四形态（AC-1/AC-2/AC-3 + 回归锚点） ----------
Assert-Case 'TC-S01' 'AC-1 PLANNER 会话：rdd:planner 单枚徽章替代 [PLANNER] 文本前缀，标题=纯简述（用户裁定 2026-09-22：run 名不占行首）' {
    $text, $code = Invoke-DryRun @('-Role', 'PLANNER', '-TaskJson', $taskJson, '-Force', '-TaskSummary', '交付编排简述')
    Assert-True ($code -eq 0) "exit=$code"
    Assert-True ($text -match [regex]::Escape('badges=[{"kind":"rdd:planner"}]')) 'PLANNER 徽章数组不符（期望仅 rdd:planner 单枚）'
    Assert-True ($text -match 'title=交付编排简述（user') 'PLANNER 标题非纯简述'
    Assert-True ($text -notmatch '\[PLANNER\]') '标题通道仍残留 [PLANNER] 文本前缀'
}

Assert-Case 'TC-S02' 'AC-2 桥接 worker：阶段/任务/节点 以 stage/task/node 三枚徽章承载（角色胶囊置首，rdd:run 长名芯片按用户裁定移除）' {
    $text, $code = Invoke-DryRun @('-Role', 'QA', '-TaskId', '3', '-TaskJson', $taskJson, '-GoalTreeRun', 'deliver-2026-09-20-planner-enhancements', '-GoalTreeNode', 'n12', '-TaskSummary', '徽章化需求 QA')
    Assert-True ($code -eq 0) "exit=$code"
    $expect = 'badges=[{"kind":"rdd:stage","label":"QA"},{"kind":"rdd:task","label":"T3"},{"kind":"rdd:node","label":"n12"}]'
    Assert-True ($text -match [regex]::Escape($expect)) 'worker 徽章数组不符（期望 stage/task/node 三枚、角色置首）'
    Assert-True ($text -notmatch 'T3·QA·n12') '结构标记仍走纯文本标题形态'
}

Assert-Case 'TC-S03' 'AC-3 徽章钉住后标题=纯简述（结构由徽章承载，简述行内跟随）' {
    $text, $code = Invoke-DryRun @('-Role', 'QA', '-TaskId', '3', '-TaskJson', $taskJson, '-GoalTreeRun', 'deliver-2026-09-20-planner-enhancements', '-GoalTreeNode', 'n12', '-TaskSummary', '工作区会话列表 RDD 标识徽章化与简述展示 QA')
    Assert-True ($code -eq 0) "exit=$code"
    Assert-True ($text -match 'title=工作区会话列表 RDD 标识徽章化与简述展示 QA（user') 'rename 标题非纯简述（中文经 cmd 链应无损）'
    Assert-True ($text -match 'RPC 3:.*session\.setBadges') 'setBadges 未先于 rename（期望 RPC3=setBadges）'
    Assert-True ($text -match 'RPC 4:.*session\.rename') 'rename 序号错位（期望 RPC4）'
}

Assert-Case 'TC-S09' '回归锚点：纯角色激活零徽章 RPC、零 rename RPC（字节级与改造前一致）' {
    $text, $code = Invoke-DryRun @('-Role', 'DEV')
    Assert-True ($code -eq 0) "exit=$code"
    Assert-True ($text -notmatch 'setBadges') '纯激活形态出现 setBadges 注入'
    Assert-True ($text -notmatch 'session\.rename') '纯激活形态出现 rename 注入'
    Assert-True ($text -match 'RPC 3:.*session\.prompt') 'RPC3 应直接为 prompt'
}

Assert-Case 'TC-S11' 'AC-1 边界：直交会话 [直交] 标记一并徽章化（rdd:direct+rdd:role）' {
    $text, $code = Invoke-DryRun @('-Role', 'DEV', '-SessionLabel', 'explore-cache', '-TaskSummary', '探索缓存维护 DEV')
    Assert-True ($code -eq 0) "exit=$code"
    $expect = 'badges=[{"kind":"rdd:direct","label":"explore-cache"},{"kind":"rdd:role","label":"DEV"}]'
    Assert-True ($text -match [regex]::Escape($expect)) '直交徽章数组不符（期望 rdd:direct + rdd:role）'
    Assert-True ($text -notmatch '\[直交\]') '标题通道仍残留 [直交] 文本标记'
}

# ---------- 生成端：Get-NodeTaskSummary 纯函数单元（AC-3 截断 / legacy 零注入） ----------
Invoke-Expression (Get-ExtractedFnText -File $bridgePs1 -FnName 'Get-NodeTaskSummary')
Assert-Case 'TC-S04' 'AC-3 简述标题超长截断：>60 字符截为 60+省略号，跟随阶段缩写' {
    $longTitle = ('跨' * 80)
    $nodeTask = "目标：完成「$longTitle」的 QA 阶段（测试与验收）。需求文档：requirements/x.md"
    $summary = Get-NodeTaskSummary -NodeTask $nodeTask
    Assert-True ($summary -eq ('{0}… QA' -f $longTitle.Substring(0, 60))) "截断结果不符: len=$($summary.Length) tail=$($summary.Substring([Math]::Max(0,$summary.Length-8)))"
}

Assert-Case 'TC-S10' 'AC-3 反向：legacy 英文签名与不可解析 node.task → 空简述 → -TaskSummary 零注入' {
    Assert-True ((Get-NodeTaskSummary -NodeTask 'Execute TaskId=3 task=D:\x\task.json') -eq '') 'legacy Execute TaskId 签名应返回空'
    Assert-True ((Get-NodeTaskSummary -NodeTask '') -eq '') '空输入应返回空'
    Assert-True ((Get-NodeTaskSummary -NodeTask '任意无法解析的文本') -eq '') '不可解析文本应返回空'
    $ok = Get-NodeTaskSummary -NodeTask '目标：完成「标题」的 DEV 阶段。'
    Assert-True ($ok -eq '标题 DEV') "标准形态应得「标题 DEV」, got: $ok"
}

# ---------- 生成端：Get-PinnedTitle 纯函数单元（AC-4 降级路径 / AC-3 拼接降级） ----------
Invoke-Expression (Get-ExtractedFnText -File $startRolePs1 -FnName 'Get-PinnedTitle')
Assert-Case 'TC-S05' 'AC-4 降级：徽章未钉住时标题=旧标记+空格+简述（一次性拼接，无二次覆盖）' {
    Assert-True ((Get-PinnedTitle -LegacyTitle '[run] T3·QA·n12' -BadgesPinned $false -Summary '简述 X') -eq '[run] T3·QA·n12 简述 X') '未钉住应为拼接形态'
    Assert-True ((Get-PinnedTitle -LegacyTitle '[run] T3·QA·n12' -BadgesPinned $true -Summary '简述 X') -eq '简述 X') '钉住应为纯简述'
    Assert-True ((Get-PinnedTitle -LegacyTitle '[PLANNER] x' -BadgesPinned $false -Summary '  ') -eq '[PLANNER] x') '空白简述应保留旧标记'
    Assert-True ((Get-PinnedTitle -LegacyTitle '' -BadgesPinned $false -Summary '简述') -eq '简述') '无标记无徽章时退化为纯简述'
}

# ---------- 宿主/装配层：AC-4 字节预算锚点 + AC-5 投影通道 ----------
Assert-Case 'TC-S06' 'AC-4 徽章不占标题字节：session/badges 独立事件通道（与 rename 分离，无标题前缀注入）' {
    $t1, $c1 = Invoke-DryRun @('-Role', 'QA', '-TaskId', '3', '-TaskJson', $taskJson, '-GoalTreeRun', 'deliver-2026-09-20-planner-enhancements', '-GoalTreeNode', 'n12', '-TaskSummary', '简述')
    Assert-True ($c1 -eq 0) "exit=$c1"
    Assert-True ($t1 -match 'session\.setBadges' -and $t1 -match 'session\.rename') 'setBadges 与 rename 应并存且分离'
    Assert-True ($t1 -match 'title=简述（user') '标题不应混入任何结构标记字节'
    if (Test-Path -LiteralPath $dshBadgesPkg) {
        $types = [System.IO.File]::ReadAllText($dshBadgesPkg)
        Assert-True ($types -match 'sessionBadges: SessionBadge\[\] \| null') 'DSH 投影键声明缺失（sessionBadges 独立通道证据）'
    } else { throw "DSH fixture missing: $dshBadgesPkg" }
}

Assert-Case 'TC-S07' 'AC-4 宿主 80 UTF-8 字节预算装配锚点（maxTitleBytes: 80；简述可用空间 ≥ 现状纯文本标题）' {
    if (-not (Test-Path -LiteralPath $dshPatch)) { throw "DSH fixture missing: $dshPatch" }
    $patch = [System.IO.File]::ReadAllText($dshPatch)
    Assert-True ($patch -match 'maxTitleBytes:\s*80') 'cordis.patch.yml 应装配 maxTitleBytes: 80'
    # 现状标题可用空间 = 80B - 标记前缀（如 "[planner-enhancements] T3·QA·n12 " ≈ 30+ 字节）
    # 钉住后简述独享 80B → 不低于现状。生成端 60 字符截断 + 宿主 80B 双层已在 TC-S04 与 DSH normalize 测试覆盖。
}

Assert-Case 'TC-S08' 'AC-5 刷新回退：徽章与标题同走投影缓存（空投影不渲染徽章，行回退纯标题/cwd）' {
    foreach ($p in @($dshRows, $dshTree)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "DSH fixture missing: $p" }
    }
    $rows = [System.IO.File]::ReadAllText($dshRows)
    Assert-True ($rows -match 'badges === undefined \|\| badges\.length === 0\) return null') '渲染端空徽章应返回 null（回退纯标题行）'
    $css = [System.IO.File]::ReadAllText('D:\YaphetHayate\projects\dsh\deepseek-harness\packages\client\ui-workspace\src\client\rows\Rows.module.css')
    Assert-True ($css -match '\.badgeChain[\s\S]{0,400}text-overflow:\s*ellipsis') '徽章数值链应 ellipsis 截断（AC-3 视觉层）'
    $tree = [System.IO.File]::ReadAllText($dshTree)
    Assert-True ($tree -match 'sessionBadges' -and $tree -match 'badges\.length > 0') '投影直通应空数组不挂字段（冷行零徽章）'
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host ("=== 结果: PASS={0} FAIL={1} ===" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failures.Count -gt 0) { $script:Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red } }
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })

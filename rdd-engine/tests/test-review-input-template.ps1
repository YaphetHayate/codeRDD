# review-input-template protocol tests — 机械输入模板骨架 / 枚举常量 / 禁令段机械断言
# (auditor-subagent-review 验收 3「输入模板是协议产物」+ 验收 4「reviewer 枚举单源」;
#  防协议漂移：模板常量与引擎消费端、start-role 自举指针三面对账)。
# Pure file-content assertions — no engine runs needed. Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir    = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$RefsDir      = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'references'
$TemplatePath = Join-Path $RefsDir 'review-input-template.md'
$BridgePs1    = Join-Path $EngineDir 'delivery-bridge.ps1'
$StartRolePs1 = Join-Path $EngineDir 'start-role.ps1'

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Get-FileText { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Test-FirstThreeBytes { param([string]$Path, [int[]]$Expected)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 3) { return $false }
    for ($i = 0; $i -lt 3; $i++) { if ([int]$bytes[$i] -ne $Expected[$i]) { return $false } }
    return $true
}

$tpl = Get-FileText $TemplatePath
Assert-True ($null -ne $tpl) 'T1 template file exists (协议产物随引擎分发)' $TemplatePath

# ---- T2 骨架（标题常量） ----
Assert-True ($tpl -match [regex]::Escape('## 2. 需求四维审视（建树前 ReviewFile）')) 'T2 需求四维节标题' ''
Assert-True ($tpl -match [regex]::Escape('## 3. 设计五查汇聚（阶段边界 DesignReviewFile）')) 'T2 设计五查节标题' ''
Assert-True ($tpl -match [regex]::Escape('## 4. 禁令段')) 'T2 禁令段标题' ''
Assert-True ($tpl -match [regex]::Escape('## 5. 常量表')) 'T2 常量表标题' ''
Assert-True ($tpl -match [regex]::Escape('## 6. 落点与凭据链')) 'T2 落点节标题' ''

# ---- T3 常量表（单源，与消费端同表对账） ----
Assert-True ($tpl -match [regex]::Escape('| `REVIEWER_SUBAGENT` | `auditor-delegated` |')) 'T3 REVIEWER_SUBAGENT=auditor-delegated' ''
Assert-True ($tpl -match [regex]::Escape('| `REVIEWER_SESSION` | `auditor` |')) 'T3 REVIEWER_SESSION=auditor' ''
Assert-True ($tpl -match [regex]::Escape('| `REVIEWER_LEGACY` | `planner` |')) 'T3 REVIEWER_LEGACY=planner (存量只读)' ''
Assert-True ($tpl -match [regex]::Escape('| `TEMPLATE_REF` | `rdd-engine/references/review-input-template.md` |')) 'T3 TEMPLATE_REF 落点值' ''
Assert-True ($tpl -match [regex]::Escape('| `REVIEW_MODE_SUBAGENT` | `subagent` |')) 'T3 REVIEW_MODE_SUBAGENT=subagent' ''
Assert-True ($tpl -match [regex]::Escape('| `REVIEW_MODE_SESSION` | `session` |')) 'T3 REVIEW_MODE_SESSION=session' ''

# ---- T4 禁令段（协议纪律五条） ----
foreach ($item in @('禁止转述', '禁止裁定倾向注入', '禁止代审', '零父对话继承', '留痕可审计')) {
    Assert-True ($tpl.Contains($item)) "T4 禁令段: $item" ''
}

# ---- T5 落点与凭据链 ----
Assert-True ($tpl.Contains('review/requirement-review.json')) 'T5 ReviewFile 机读落点' ''
Assert-True ($tpl.Contains('review/design-review-<StageId>.json')) 'T5 DesignReviewFile 机读落点' ''
Assert-True ($tpl.Contains('.rdd/review-ledger.jsonl')) 'T5 记账落点' ''
Assert-True ($tpl.Contains('promulgate -ReviewFile')) 'T5 需求审查消费端（契约零改动）' ''
Assert-True ($tpl.Contains('design-review -Action submit')) 'T5 设计审查消费端（submit 入库）' ''

# ---- T6 可填充物标记（仅路径/任务 id/阶段 id/常量可填充） ----
foreach ($slot in @('{{ARCHIVE_REL}}', '{{TASK_JSON_REL}}', '{{CRITERIA_REF}}', '{{STAGE_ID}}', '{{DOC_LIST}}')) {
    Assert-True ($tpl.Contains($slot)) "T6 fillable slot $slot" ''
}

# ---- T7 方法论维度名（四维 / 五查，与引擎维度常量同词） ----
foreach ($dim in @('与根目标一致性', '独立性粒度', '依赖标注真实度', '验收标准可测性')) {
    Assert-True ($tpl.Contains($dim)) "T7 需求四维: $dim" ''
}
foreach ($dim in @('alignment', 'change_map', 'internal_consistency', 'completeness', 'cross_design')) {
    Assert-True ($tpl.Contains($dim)) "T7 设计五查: $dim" ''
}

# ---- T8 与引擎消费端同表对账（防协议漂移） ----
$bridgeSrc = Get-FileText $BridgePs1
Assert-True ($null -ne $bridgeSrc) 'T8 delivery-bridge.ps1 readable' $BridgePs1
Assert-True ($bridgeSrc.Contains('$script:DesignReviewReviewers = @(''auditor-delegated'', ''auditor'')')) 'T8 引擎 reviewer 值域与模板常量一致' ''
Assert-True ($bridgeSrc.Contains('$script:ReviewModeValues = @(''subagent'', ''session'')')) 'T8 引擎 review_mode 值域与模板常量一致' ''
Assert-True ($bridgeSrc.Contains('$script:ReviewInputTemplateRel = "rdd-engine/references/review-input-template.md"')) 'T8 引擎 TEMPLATE_REF 与模板一致' ''
Assert-True ($bridgeSrc.Contains('$script:DesignReviewDims = @("alignment", "change_map", "internal_consistency", "completeness", "cross_design")')) 'T8 引擎五查维度与模板一致' ''

# ---- T9 规划者单入口指引贯通（start-role 自举指针指向模板） ----
$srSrc = Get-FileText $StartRolePs1
Assert-True ($null -ne $srSrc -and $srSrc.Contains('review-input-template.md')) 'T9 start-role PLANNER 自举指针携带模板指引（单入口）' ''

# ---- T10 编码自检（write 工具抹 BOM → 落盘后重补；首 3 字节兜底断言，tip #6） ----
$bom = @(239, 187, 191)
Assert-True (Test-FirstThreeBytes $PSCommandPath $bom) 'T10 本测试脚本 UTF-8 BOM' $PSCommandPath
Assert-True (Test-FirstThreeBytes $BridgePs1 $bom) 'T10 delivery-bridge.ps1 UTF-8 BOM' $BridgePs1
Assert-True (Test-FirstThreeBytes $StartRolePs1 $bom) 'T10 start-role.ps1 UTF-8 BOM' $StartRolePs1

$fails = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("review-input-template suite: {0} assertions, {1} failed" -f $Results.Count, $fails.Count)
if ($fails.Count -gt 0) { exit 1 }
exit 0

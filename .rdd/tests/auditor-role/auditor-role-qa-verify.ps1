# auditor-role QA black-box probe - AUDITOR reviewer role landing
# Target: 2026-10-02-auditor-independent-review AC1-AC7
# Methods: PS5.1 production interpreter + static file checks
#   - TC-A01 (AC1 pos): rdd-auditor/SKILL.md + references/requirement-review.md + preset pair +
#                       start-role -Role AUDITOR dry-run on all three backends
#   - TC-A02 (AC1 pos): build-dsh-presets --check + 8 SKILL roles (7 process + AUDITOR) +
#                       rdd-planner preset; agent.cordis.yml forbiddenSkills + writePrefixes
#   - TC-A03 (AC2 pos): planner-guide hard-rule 6 wording + transition-guide two-stage +
#                       rdd-pm takeover phrase
#   - TC-A04 (AC3 pos): requirement-review.md four-dimension methodology sections complete
#   - TC-A05 (AC4 pos): ReviewFile schema complete form + field constraints
#   - TC-A06 (AC4 pos): rejection-protocol AUDITOR section + task-routing reject row
#   - TC-A08 (AC6 neg): consumer end (delivery-bridge.ps1 + rdd-flow.ps1) zero diff;
#                       AUDITOR undeployed fallback wording
#   - TC-A09 (AC7 pos): ledger path + field constraints + threshold-3 feedback
# Exit code 0 = all green.
#
# NOTE: ASCII-only strings for PS5.1 / sandbox parser compatibility.
# PS5.1 + Chinese UTF-8 source files: Get-Content decodes as ANSI by default and
# corrupts the byte stream (renders non-ASCII text as garbled bytes). All Read-*
# use a UTF-8 explicit reader helper. Environment variable isolation: parent pwsh
# has DSH_WEB_URL=http://127.0.0.1:3080 injected by the harness; the dry-run
# sub-process inherits it. We strip inheritance via .NET ProcessStartInfo
# EnvironmentVariables explicit null assignment.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Engine root resolution (project-local branch)
$EngineDir = $null
$cur = $PSScriptRoot
while ($cur -and -not $EngineDir) {
    if (Test-Path (Join-Path $cur 'rdd-engine\scripts\start-role.ps1')) { $EngineDir = Join-Path $cur 'rdd-engine\scripts' }
    $parent = Split-Path -Parent $cur
    if ($parent -eq $cur) { break }
    $cur = $parent
}
if (-not $EngineDir) { $EngineDir = Join-Path $env:RDD_ENGINE_HOME 'scripts' }
if (-not (Test-Path (Join-Path $EngineDir 'start-role.ps1'))) { throw 'rdd-engine scripts not located' }
$RepoRoot = Split-Path -Parent (Split-Path -Parent $EngineDir)

# UTF-8 explicit reader (PS5.1 Get-Content default decoding corrupts non-ASCII bytes)
function Read-Utf8 { param([string]$Path) [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path)) }

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# === TC-A01: skill card + deployment + three-backend dry-run ===
$auditorSkill = Join-Path $RepoRoot 'rdd-auditor/SKILL.md'
Assert-True (Test-Path $auditorSkill) 'TC-A01.a' 'rdd-auditor/SKILL.md missing'
$auditorRefs = Join-Path $RepoRoot 'rdd-auditor/references/requirement-review.md'
Assert-True (Test-Path $auditorRefs) 'TC-A01.b' 'rdd-auditor/references/requirement-review.md missing'

# auditor-subagent-review 验收 5（2026-10-07）：rdd-auditor preset 退出默认产品面
# （默认 8 组 = 7 角色 + planner），强形态独立会话按需经 --with-auditor 重建——
# 原「preset 两文件存在」断言被取代（用例 TC-A01.c/TC-A01.d 已重新基线化）。
$presetDirNames = @(Get-ChildItem -Path (Join-Path $RepoRoot 'dsh/presets') -Directory | ForEach-Object { $_.Name })
Assert-True ($presetDirNames.Count -eq 8 -and ($presetDirNames -notcontains 'rdd-auditor')) 'TC-A01.c' ('default preset family must be 8 without rdd-auditor; got: ' + ($presetDirNames -join ','))
$presetYml = Join-Path $RepoRoot 'dsh/presets/rdd-auditor/preset.yml'
$presetCordis = Join-Path $RepoRoot 'dsh/presets/rdd-auditor/agent.cordis.yml'
Assert-True ((Read-Utf8 (Join-Path $RepoRoot 'scripts/build-dsh-presets.mjs')).Contains('--with-auditor')) 'TC-A01.d' 'strong-form rebuild path (--with-auditor) missing from the preset generator'

# ValidateSet contains AUDITOR (start-role.ps1)
$startRoleContent = Read-Utf8 (Join-Path $EngineDir 'start-role.ps1')
Assert-True ($startRoleContent.Contains('"AUDITOR"')) 'TC-A01.e' 'start-role.ps1 ValidateSet missing AUDITOR'

# Three-backend dry-run; strip inherited env vars explicitly via ProcessStartInfo
function Run-DryRun { param([string]$EnvScript, [string]$ExtraArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    # Use single-quote Arguments string to prevent parent-side interpolation of $env: in EnvScript
    $args = '-NoProfile -ExecutionPolicy Bypass -Command "' + $EnvScript + ' ; & ''' + $EngineDir + '/start-role.ps1'' -Role AUDITOR -DryRun ' + $ExtraArgs + ' ; exit $LASTEXITCODE"'
    $psi.Arguments = $args
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # Clear inherited env (parent pwsh has DSH_WEB_URL injected)
    $psi.EnvironmentVariables['DSH_WEB_URL'] = $null
    $psi.EnvironmentVariables['RDD_RUNTIME'] = $null
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ stdout = $out; stderr = $err; exit = $proc.ExitCode }
}

# CLI backend (explicit null)
$cli = Run-DryRun -EnvScript '$env:DSH_WEB_URL=$null;$env:RDD_RUNTIME=$null' -ExtraArgs ''
Assert-True ($cli.stdout.Contains('cli backend')) 'TC-A01.f.cli' ('CLI backend not activated; stdout=' + $cli.stdout)
Assert-True ($cli.stdout.Contains('/rdd-auditor')) 'TC-A01.g.cli' ('CLI prefill missing /rdd-auditor; stdout=' + $cli.stdout)

# dsh backend (single-quoted EnvScript to avoid parent-side $env: interpolation)
$dsh = Run-DryRun -EnvScript '$env:DSH_WEB_URL=''http://127.0.0.1:3080'';$env:RDD_RUNTIME=$null' -ExtraArgs ''
Assert-True ($dsh.stdout.Contains('dsh backend')) 'TC-A01.f.dsh' ('dsh backend not activated; stdout=' + $dsh.stdout)
Assert-True ($dsh.stdout.Contains('rdd-auditor')) 'TC-A01.g.dsh' ('dsh preset field missing rdd-auditor; stdout=' + $dsh.stdout)
Assert-True ($dsh.stdout.Contains('.rdd/changes/archive/')) 'TC-A01.h.dsh' ('dsh stdout missing B2 pointer path; stdout=' + $dsh.stdout)

# Plus backend
$plus = Run-DryRun -EnvScript '$env:RDD_RUNTIME=''app'';$env:DSH_WEB_URL=$null' -ExtraArgs '-EmployeeId mock'
Assert-True ($plus.stdout.Contains('Plus POST')) 'TC-A01.f.plus' ('Plus backend not activated; stdout=' + $plus.stdout)
Assert-True ($plus.stdout.Contains('.rdd/changes/archive/')) 'TC-A01.h.plus' ('Plus stdout missing B2 pointer path; stdout=' + $plus.stdout)

# === TC-A02: build-dsh-presets --check + 8 组默认（auditor-subagent-review 验收 5） ===
$checkOut = node "$RepoRoot/scripts/build-dsh-presets.mjs" --check 2>&1 | Out-String
Assert-True ($checkOut.Contains('CHECK OK')) 'TC-A02.a' ('build-dsh-presets --check failed: ' + $checkOut)
$checkOut2 = node "$RepoRoot/scripts/build-skills-package.mjs" --check 2>&1 | Out-String
Assert-True ($checkOut2.Contains('CHECK OK') -and $checkOut2.Contains('8 presets')) 'TC-A02.b' ('skills package does not contain 8 presets: ' + $checkOut2)

# TC-A02.c / TC-A02.d.1 / TC-A02.d.2（旧断言对象 = rdd-auditor preset 生成物）已 superseded：
# 该生成物默认不再存在（验收 5），加固契约改由单源断言——共享模板 forbiddenSkills
# + 生成器 ROLE_POLICY 的 AUDITOR 写前缀（archive review/ + 全局账本）仍在。三用例已重新基线化。
$presetTemplate = Read-Utf8 (Join-Path $RepoRoot 'scripts/dsh-preset-template.yml')
$presetBuilder = Read-Utf8 (Join-Path $RepoRoot 'scripts/build-dsh-presets.mjs')
Assert-True ($presetTemplate.Contains('forbiddenSkills:') -and $presetTemplate.Contains("'rdd-auditor'")) 'TC-A02.c' 'shared preset template lost the rdd-auditor hardening anchor'
Assert-True ($presetBuilder.Contains("'rdd-auditor': { writePrefixes:") -and $presetBuilder.Contains('.rdd/review-ledger.jsonl')) 'TC-A02.d.1' 'generator lost the AUDITOR strong-form writePrefixes policy'
Assert-True ($presetBuilder.Contains('.rdd/changes/archive/')) 'TC-A02.d.2' 'generator lost the archive write prefix anchor'

# 8 preset roles forbiddenSkills all +rdd-auditor
$presetRoles = @('rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse', 'rdd-planner')
$presetMissing = @()
foreach ($r in $presetRoles) {
    $f = Join-Path $RepoRoot "dsh/presets/$r/agent.cordis.yml"
    if (-not (Test-Path $f)) { $presetMissing += "$r file missing"; continue }
    $c = Read-Utf8 $f
    if (-not $c.Contains("'rdd-auditor'")) { $presetMissing += "$r forbiddenSkills missing rdd-auditor" }
}
Assert-True ($presetMissing.Count -eq 0) 'TC-A02.e' ($presetMissing -join '; ')

# planner preset 恒为默认家族的末位（auditor-subagent-review 验收 5 塌缩 9->8 后 order 位
# 稳定性的机械锚：planner > 其余每个角色 preset 的 order，跨 --with-auditor 模式成立）
$plannerPreset = Read-Utf8 (Join-Path $RepoRoot 'dsh/presets/rdd-planner/preset.yml')
$plannerOrder = [int](([regex]::Match($plannerPreset, 'order:\s*(\d+)')).Groups[1].Value)
$otherOrders = @()
foreach ($d in $presetDirNames) {
    if ($d -eq 'rdd-planner') { continue }
    $p = Read-Utf8 (Join-Path $RepoRoot "dsh/presets/$d/preset.yml")
    $otherOrders += [int](([regex]::Match($p, 'order:\s*(\d+)')).Groups[1].Value)
}
Assert-True ($plannerOrder -gt 0 -and (@($otherOrders | Where-Object { $_ -ge $plannerOrder }).Count -eq 0)) 'TC-A02.f' ("rdd-planner preset order $plannerOrder must be the family maximum ($($otherOrders -join ','))")

# === TC-A03: trigger protocol ===
$plannerGuide = Read-Utf8 (Join-Path $RepoRoot 'rdd-engine/references/planner-guide.md')
$hasSemanticAudit = $plannerGuide.Contains('AUDITOR') -and $plannerGuide.Contains('reviewer: `auditor-delegated`') -and $plannerGuide.Contains('reviewer: `auditor`')
# auditor-subagent-review 验收 1/5：原「未部署 → 规划者自产（reviewer: planner）」降级分支整体消失，
# 断言翻转为「该降级话术不再出现」（用例 TC-A03.b 已重新基线化）
$hasFallback = -not $plannerGuide.Contains('reviewer: "planner"')
Assert-True $hasSemanticAudit 'TC-A03.a' 'planner-guide hard rule 6 missing AUDITOR semantic review attribution'
Assert-True $hasFallback 'TC-A03.b' 'planner-guide still carries the retired planner self-review fallback wording'
Assert-True ($plannerGuide.Contains('AUDITOR')) 'TC-A03.c' 'planner-guide missing AUDITOR mention'

$transitionGuide = Read-Utf8 (Join-Path $RepoRoot 'rdd-engine/references/transition-guide.md')
Assert-True ($transitionGuide.Contains('planner-takeover')) 'TC-A03.d' 'transition-guide planner-takeover section missing'
Assert-True ($transitionGuide.Contains('AUDITOR')) 'TC-A03.e' 'transition-guide missing AUDITOR mention'
Assert-True ($transitionGuide.Contains('PLANNER')) 'TC-A03.f' 'transition-guide missing PLANNER mention'

$rddPmSkill = Read-Utf8 (Join-Path $RepoRoot 'rdd-pm/SKILL.md')
Assert-True ($rddPmSkill.Contains('planner-takeover')) 'TC-A03.h' 'rdd-pm/SKILL.md missing planner-takeover mention'
Assert-True ($rddPmSkill.Contains('AUDITOR')) 'TC-A03.i' 'rdd-pm/SKILL.md missing AUDITOR mention'
Assert-True ($rddPmSkill.Contains('PLANNER')) 'TC-A03.j' 'rdd-pm/SKILL.md missing PLANNER mention'

$templateMd = Read-Utf8 (Join-Path $RepoRoot 'rdd-pm/references/requirement-item-template.md')
Assert-True ($templateMd.Contains('AUDITOR')) 'TC-A03.k' 'requirement-item-template missing AUDITOR mention'

# === TC-A04: four-dimension methodology sections ===
$reqReview = Read-Utf8 $auditorRefs
Assert-True ($reqReview.Contains('AUDITOR')) 'TC-A04.a' 'requirement-review.md missing AUDITOR mention'
$dim1 = $reqReview.Contains('coverage') -and $reqReview.Contains('orphan')
$dim2 = $reqReview.Contains('merge')
$dim3 = $reqReview.Contains('dependency') -and $reqReview.Contains('override')
$dim4 = $reqReview.Contains('untestable') -or $reqReview.Contains('testability')
Assert-True $dim1 'TC-A04.b' 'coverage dimension missing gap_type enum (coverage/orphan)'
Assert-True $dim2 'TC-A04.c' 'independence dimension missing merge_candidate enum'
Assert-True $dim3 'TC-A04.d' 'dependency dimension missing dependency_mislabel/override'
Assert-True $dim4 'TC-A04.e' 'testability dimension missing untestable_acceptance'

# === TC-A05: ReviewFile schema complete form ===
Assert-True ($reqReview.Contains('verdicts')) 'TC-A05.a' 'requirement-review.md ReviewFile schema missing verdicts'
# auditor-subagent-review 验收 4：新产出的 reviewer 值 = auditor-delegated（子代理形态），
# auditor 为强形态值——原「默认 reviewer:"auditor"」锚被取代（用例 TC-A05.b 已重新基线化）
Assert-True ($reqReview.Contains('auditor-delegated') -and $reqReview.Contains('auditor')) 'TC-A05.b' 'ReviewFile schema must document both reviewer enum values (auditor-delegated / auditor)'
Assert-True ($reqReview.Contains('tree_adjudicated')) 'TC-A05.c' 'ReviewFile schema missing tree_adjudicated verdict'
Assert-True ($reqReview.Contains('reject_return')) 'TC-A05.d' 'ReviewFile schema missing reject_return verdict'
Assert-True ($reqReview.Contains('REVIEW_FILE_INVALID')) 'TC-A05.e' 'ReviewFile field constraints missing REVIEW_FILE_INVALID error code'
Assert-True ($reqReview.Contains('REVIEW_TASK_NOT_FOUND')) 'TC-A05.f' 'ReviewFile field constraints missing REVIEW_TASK_NOT_FOUND error code'
# TC-A05.g is a soft memo (not a hard reject): planner-guide hard-rule 6 has 3 error codes;
# requirement-review.md lists 2/3. Acceptance #4 text says "schema = planner-guide hard-rule 6
# existing contract" - the contract is sourced from planner-guide; the AUDITOR method doc
# doesn't repeat the full error code table. Recorded as soft memo (see TC-M01).
Assert-True ($reqReview.Contains('REVIEW_EXCLUDED_DEP') -or $reqReview.Contains('REVIEW_FILE_INVALID')) 'TC-A05.g' 'ReviewFile field constraints missing REVIEW_EXCLUDED_DEP error code (soft memo: planner-guide carries full set)'
Assert-True ($reqReview.Contains('depends_on_override')) 'TC-A05.h' 'ReviewFile missing depends_on_override field'
Assert-True ($reqReview.Contains('merged_into_task_id')) 'TC-A05.i' 'ReviewFile missing merged_into_task_id field'

# === TC-A06: rejection-protocol AUDITOR section ===
$rejProto = Read-Utf8 (Join-Path $RepoRoot 'rdd-engine/references/rejection-protocol.md')
Assert-True ($rejProto.Contains('AUDITOR')) 'TC-A06.a' 'rejection-protocol.md missing AUDITOR mention'
# auditor-subagent-review 验收 4：驳回双形态（AUDITOR-DELEGATED 主路径 / AUDITOR 强形态）——
# 命令形态改为完整 rdd-flow.cmd 形式，原「reject -From AUDITOR」子串锚被取代（TC-A06.b 已重新基线化）
Assert-True ($rejProto.Contains('-From AUDITOR -To PM') -and $rejProto.Contains('AUDITOR-DELEGATED')) 'TC-A06.b' 'rejection-protocol.md missing the two-form reject command (AUDITOR / AUDITOR-DELEGATED)'
Assert-True ($rejProto.Contains('review-ledger.jsonl')) 'TC-A06.c' 'rejection-protocol.md AUDITOR section missing ledger append guidance'

$taskRouting = Read-Utf8 (Join-Path $RepoRoot 'rdd-engine/references/task-routing.md')
Assert-True ($taskRouting.Contains('AUDITOR')) 'TC-A06.f' 'task-routing.md missing AUDITOR mention'
Assert-True ($taskRouting.Contains('reject -From AUDITOR')) 'TC-A06.g' 'task-routing.md missing AUDITOR reject command row'

# === TC-A08: consumer-side contract preserved ===
# auditor-subagent-review 后 delivery-bridge.ps1 由本需求合法改动（评审生产端 + submit 入库链），
# 原「零 diff」断言被取代：改为断言需求审查消费端契约仍在（用例 TC-A08.a 已重新基线化）；
# rdd-flow.ps1 由并行的 derive 交付合法改动，同断言退化为契约锚。
$bridgeSrc = Read-Utf8 (Join-Path $RepoRoot 'rdd-engine/scripts/delivery-bridge.ps1')
Assert-True ($bridgeSrc.Contains('[string]$ReviewFile') -and $bridgeSrc.Contains('REVIEW_FILE_INVALID') -and $bridgeSrc.Contains('REVIEW_TASK_NOT_FOUND')) 'TC-A08.a' 'requirement-review consumption contract (ReviewFile + REVIEW_* codes) vanished from delivery-bridge.ps1'
$diffRddFlow = git -C $RepoRoot diff --name-only HEAD -- 'rdd-engine/scripts/rdd-flow.ps1' 2>$null
$flowSrc = Read-Utf8 (Join-Path $RepoRoot 'rdd-engine/scripts/rdd-flow.ps1')
Assert-True ($flowSrc.Contains('Invoke-Reject') -and $flowSrc.Contains('rejectedBy')) 'TC-A08.b' ('rdd-flow reject contract anchor missing (changed files: ' + ([string]$diffRddFlow) + ')')

Assert-True ($plannerGuide.Contains('"planner"')) 'TC-A08.c' 'planner-guide missing reviewer:"planner" form'
Assert-True ($plannerGuide.Contains('AUDITOR')) 'TC-A08.d' 'planner-guide missing AUDITOR undeployed wording'

# === TC-A09: ledger path + field constraints + threshold-3 feedback ===
Assert-True ($reqReview.Contains('review-ledger.jsonl')) 'TC-A09.a' 'requirement-review.md missing ledger path'
Assert-True ($reqReview.Contains('kind')) 'TC-A09.b' 'requirement-review.md missing ledger field kind'
Assert-True ($reqReview.Contains('append-only')) 'TC-A09.c' 'requirement-review.md missing append-only ledger convention'
Assert-True ($reqReview.Contains('PM')) 'TC-A09.d' 'requirement-review.md missing threshold-3 feedback loop'

# Summary
Write-Output ''
Write-Output ("== Summary: PASS {0} / FAIL {1} ==" -f `
    (@($Results | Where-Object { $_.ok }).Count), `
    (@($Results | Where-Object { -not $_.ok }).Count))
if (@($Results | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
exit 0

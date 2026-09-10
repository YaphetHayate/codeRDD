# rca-role-cards 文档面复验（QA 独立验收，2026-09-10-rca-role-landing 需求1）
# 断言：5 卡要素齐全（TC-001）、红线零基准题目知识（TC-002）、
#       四方引用链无断链（TC-003）、卡 schema 与派发契约可填槽（TC-004）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File rca-cards-review.ps1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$RefsDir  = Join-Path $root 'rdd-engine/references'
$CardsDir = Join-Path $RefsDir 'rca-roles'
$Roles    = @('data-prep', 'metric-analyst', 'log-analyst', 'trace-analyst', 'root-cause-analyst')
$Analysts = @('metric-analyst', 'log-analyst', 'trace-analyst')

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

$authority = Get-Content (Join-Path $RefsDir 'rca-roles.md') -Raw -Encoding UTF8
$dispatch  = Get-Content (Join-Path $RefsDir 'task-dispatch-guide.md') -Raw -Encoding UTF8
$loopGuide = Get-Content (Join-Path $RefsDir 'tree-run-guide.md') -Raw -Encoding UTF8
$cards = @{}
foreach ($r in $Roles) { $cards[$r] = Get-Content (Join-Path $CardsDir "$r.md") -Raw -Encoding UTF8 }

# ===== TC-001 要素覆盖：5 卡齐全，六要素齐备，probe 差异声明正确 =====
$missing = @()
foreach ($r in $Roles) {
    if ($cards[$r] -eq $null -or $cards[$r].Trim() -eq '') { $missing += "$r.md missing"; continue }
    foreach ($s in @('## 一、角色对象', '## 二、固定方法', '## 三、交付 schema', '## 四、验收挂钩', '## 五、probe 模式差异', '权威来源', '承接性质')) {
        if ($cards[$r].IndexOf($s) -lt 0) { $missing += "$r.md lacks '$s'" }
    }
}
Assert-True ($missing.Count -eq 0) 'TC-001 five cards exist with all required sections' ($missing -join '; ')

$probeOk = $true
foreach ($r in $Analysts) {
    if ($cards[$r] -match '## 五、probe 模式差异[\s\S]{0,40}无') { $probeOk = $false }   # 分析角色必须有 probe 差异
    if ($cards[$r].IndexOf('falsification_duty') -lt 0) { $probeOk = $false }              # 且与派发字段同名
}
foreach ($r in @('data-prep', 'root-cause-analyst')) {
    if (-not ($cards[$r] -match '## 五、probe 模式差异[\s\S]{0,40}无')) { $probeOk = $false } # 非分析角色显式"无"
}
Assert-True $probeOk 'TC-001 probe-mode declarations correct per role family'

$stepsOk = $true
foreach ($r in $Roles) {
    # 权威文件对应小节的编号方法步骤名，必须逐一出现在卡内（方法预设不缺失）
    $sec = [regex]::Match($authority, ("## $r[^\n]*\n([\s\S]*?)(?=\n## )")).Groups[1].Value
    $stepNames = [regex]::Matches($sec, '\d+\. \*\*([^*]+)\*\*') | ForEach-Object { $_.Groups[1].Value }
    if (-not $stepNames) { $stepsOk = $false; continue }
    foreach ($n in $stepNames) { if ($cards[$r].IndexOf($n) -lt 0) { $stepsOk = $false } }
}
Assert-True $stepsOk 'TC-001 every numbered method step from the authority doc is on the card'

# ===== TC-002 红线：卡内容零基准题目特有知识 =====
$redlineHits = @()
foreach ($r in $Roles) {
    $m = [regex]::Matches($cards[$r], '(?i)(mysql|tomcat|bank|cpu-\d|14:\d\d|rca-\d{4,})')
    if ($m.Count -gt 0) { $redlineHits += "$r.md: $($m[0].Value)" }
}
Assert-True ($redlineHits.Count -eq 0) 'TC-002 redline: cards carry generic SRE methodology only' ($redlineHits -join '; ')

# ===== TC-003 引用链：权威文件 <-> 卡 <-> 派发契约 <-> 循环指南 =====
$chain = @()
foreach ($r in $Roles) {
    if ($authority.IndexOf("rca-roles/$r.md") -lt 0) { $chain += "authority -> $r.md link missing" }
    if ($dispatch.IndexOf("rca-roles/$r.md") -lt 0) { $chain += "dispatch -> $r.md link missing" }
    $secTitle = [regex]::Match($cards[$r], 'rca-roles\.md` §「([^」]+)」').Groups[1].Value
    if ($secTitle -eq '' -or $authority.IndexOf("## $secTitle") -lt 0) { $chain += "$r.md authority-section anchor missing" }
    if ($cards[$r].IndexOf('task-dispatch-guide.md') -lt 0 -or $cards[$r].IndexOf('附录 A.2') -lt 0) { $chain += "$r.md -> dispatch A.2 link missing" }
}
if ($loopGuide.IndexOf('rca-roles.md') -lt 0 -or $loopGuide.IndexOf('角色卡嵌入点') -lt 0) { $chain += 'loop guide embed point missing' }
Assert-True ($chain.Count -eq 0) 'TC-003 cross-reference chain intact in all four directions' ($chain -join '; ')

# ===== TC-004 可填槽：卡 schema 与附录 A 机械契约同名对齐 =====
$slots = @()
foreach ($pair in @(@('data-prep', 'deliverables'), @('root-cause-analyst', 'conclusion'))) {
    if ($cards[$pair[0]].IndexOf($pair[1]) -lt 0 -or $dispatch.IndexOf("extras.$($pair[1])") -lt 0) { $slots += "$($pair[0]) extras namespace misaligned" }
}
foreach ($r in $Analysts) {
    if ($cards[$r].IndexOf('manifest.filled') -lt 0) { $slots += "$r manifest.filled missing" }
    if ($cards[$r].IndexOf('extras.probe') -lt 0) { $slots += "$r extras.probe missing" }
}
foreach ($token in @('falsification_duty', 'GRAFT_FALSIFICATION_REQUIRED', 'extras.probe', 'manifest.filled', 'found/clean/escalated')) {
    if ($dispatch.IndexOf($token) -lt 0) { $slots += "dispatch appendix lacks '$token'" }
}
Assert-True ($slots.Count -eq 0) 'TC-004 card schemas align with dispatch appendix A slots' ($slots -join '; ')

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("==== {0}/{1} passed ====" -f ($Results.Count - $failed.Count), $Results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

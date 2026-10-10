#Requires -Version 5.1
<#
.SYNOPSIS
  按 UX 模型策略物化 opencode 执行器。
.DESCRIPTION
  真相源是 rdd-ux/ux_subagent.json 的模型策略状态机（mode: uninitialized | inherit |
  random | pinned）——本脚本不再消费 agents 模型清单（schema v1 已废弃）。
  执行器约定集固定三名：ux-mockup-a / ux-mockup-b / ux-mockup-c（对应 fork-join
  三方向；方向知识永不进入执行器）。frontmatter 的 model 绑定按 mode 推导：
    - pinned                      → 第 i 条 pinned.model 绑到第 i 个执行器
                                    （清单不足 3 时其余执行器无绑定；超出只用前 3）
    - inherit / random /          → 全部执行器无 model 绑定（跟随会话模型 /
      uninitialized                  random 在 opencode 下降级为无绑定 + 简报差异化）
  对 .opencode/agent/ux-mockup-*.md 执行 Create / Update / Delete：
    - 约定集有、磁盘无            → Create（从模板生成，正文统一）
    - 磁盘有、绑定与期望不一致     → Update（只改 frontmatter 的 model 行）
    - managed 有、约定集无        → Delete（删文件 + 从 managed 移除）
    - 磁盘有、managed 与约定集均无 → orphan 警告（不自动删，安全）
  agent 正文不随策略变化——正文是通用执行器职责，固化在本脚本模板中。
  dsh 运行时不消费本脚本（策略实时生效）；仅 opencode 需要物化 + 重启。
.PARAMETER WhatIf
  干跑模式：只报告会做什么，不实际执行写/删操作，也不回写 json。
.EXAMPLE
  sync-ux-subagents.cmd
  sync-ux-subagents.cmd -WhatIf
#>
param(
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# ---------- 路径定位 ----------
# Resolve-RepoRoot - project-root location chain (git-optional; protocol source:
# rdd-engine/references/engine-location.md, "Project-root location chain"). Fixed order:
#   1. $env:RDD_PROJECT_ROOT          explicit override; invalid path -> fail-loud
#   2. git rev-parse --show-toplevel  most accurate: worktree / submodule / GIT_DIR
#   3. nearest .git ancestor          filesystem twin of (2) when git is missing or
#                                     refuses the repo (dubious ownership)
#   4. nearest .rdd/install.json ancestor  anchors non-git projects back onto their
#                                     coderdd-init root when run from a subdirectory
#   5. cwd                            final fallback - same rule as the dsh plugin's
#                                     findRepoRoot (one mental model across the ecosystem)
# (2)+(3) keep every existing git project byte-identical (regression anchor);
# (4)+(5) only rescue trees where git says "not a repository".
function Resolve-RepoRoot {
    $envRoot = [string]$env:RDD_PROJECT_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        if (Test-Path -LiteralPath $envRoot -PathType Container) { return $envRoot }
        throw "RDD_PROJECT_ROOT does not exist: $envRoot"
    }
    $t = $null
    # 2>$null must stay inside try/catch: under PS5.1, redirected native stderr
    # plus $ErrorActionPreference=Stop raises NativeCommandError.
    try { $t = git rev-parse --show-toplevel 2>$null } catch { }
    if ($t) { return $t.Trim() }
    $start = (Get-Location).ProviderPath
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".rdd/install.json")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $start
}
$root = Resolve-RepoRoot
$jsonPath = Join-Path $root "rdd-ux\ux_subagent.json"
$agentDir = Join-Path $root ".opencode\agent"

if (-not (Test-Path -LiteralPath $jsonPath)) {
  Write-Host "[ERROR] 真相源不存在：$jsonPath" -ForegroundColor Red
  exit 1
}
if (-not (Test-Path -LiteralPath $agentDir)) {
  New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
}

# ---------- 读取 json ----------
try {
  $jsonText = [System.IO.File]::ReadAllText($jsonPath)
  $config = $jsonText | ConvertFrom-Json
} catch {
  Write-Host "[ERROR] 解析 json 失败：$($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

# ---------- 策略解析（schema v2：mode 状态机）----------
$mode = $config.mode
if (-not $mode) {
  Write-Host "[ERROR] ux_subagent.json 仍是旧版 agents 模型清单（schema v1，已废弃）。" -ForegroundColor Red
  Write-Host "        现在的真相源是模型策略状态机（mode: uninitialized | inherit | random | pinned），" -ForegroundColor Red
  Write-Host "        初始为空、不预绑模型。请按 rdd-ux/references/mockup-generation.md「模型策略与运行时适配」" -ForegroundColor Red
  Write-Host "        更新该文件（或让 UX 在首次 fork-join 触发时征询落定）。" -ForegroundColor Red
  exit 1
}
if (@('uninitialized','inherit','random','pinned') -notcontains $mode) {
  Write-Host "[ERROR] mode 取值非法：$mode（合法：uninitialized | inherit | random | pinned）" -ForegroundColor Red
  exit 1
}

$managed = @($config.managed)
if (-not $managed) { $managed = @() }

# 执行器约定集（固定三名，对应 fork-join 三方向）
$trio = @('ux-mockup-a', 'ux-mockup-b', 'ux-mockup-c')

# 按 mode 推导每个执行器的期望 model 绑定（$null = 无绑定）
$expected = @{}
foreach ($name in $trio) { $expected[$name] = $null }
$notes = @()
if ($mode -eq 'pinned') {
  $pinned = @($config.pinned)
  if (-not $pinned) { $pinned = @() }
  for ($i = 0; $i -lt $trio.Count; $i++) {
    if ($i -lt $pinned.Count) {
      $m = [string]$pinned[$i].model
      if (-not [string]::IsNullOrWhiteSpace($m)) { $expected[$trio[$i]] = $m }
    }
  }
  if ($pinned.Count -gt 0 -and $pinned.Count -lt $trio.Count) {
    $notes += "pinned 清单 $($pinned.Count) 条 < 3：其余执行器无绑定（跟随会话模型）"
  }
  if ($pinned.Count -gt $trio.Count) {
    $notes += "pinned 清单 $($pinned.Count) 条 > 3：只用前 3 条"
  }
}

# ---------- 工具函数 ----------
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-AgentField {
  param([string]$Path, [string]$Field)
  $content = [System.IO.File]::ReadAllText($Path)
  if ($content -match '(?s)^---\r?\n(.*?)\r?\n---') {
    $yaml = $matches[1]
    $line = ($yaml -split "`r?`n" | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Field) + '\s*:') } | Select-Object -First 1)
    if ($line) {
      return ($line -replace ('^\s*' + [regex]::Escape($Field) + '\s*:\s*'), '').Trim()
    }
  }
  return $null
}

function Update-AgentFrontmatter {
  param([string]$Path, [string]$Model)
  # 期望绑定 = $Model；$null = 无绑定（删除 model 行）。同时清除遗留 temperature 行
  # （策略状态机不再携带温度——dsh 侧 agent() 覆盖对不支持，opencode 走默认值）。
  $content = [System.IO.File]::ReadAllText($Path)
  if ($content -match '(?s)^(---\r?\n)(.*?)(\r?\n---\r?\n)(.*)$') {
    $open = $matches[1]
    $yaml = $matches[2]
    $close = $matches[3]
    $body = $matches[4]
    $yaml = $yaml -replace '(?m)^\s*model\s*:.*$', ''
    $yaml = $yaml -replace '(?m)^\s*temperature\s*:.*$', ''
    $yaml = ($yaml -split "`r?`n" | Where-Object { $_ -ne '' }) -join "`n"
    if (-not [string]::IsNullOrEmpty($Model)) {
      # 插回 model 行：permission 行之前（模板形状由本脚本管理，锚点稳定）
      $yaml = $yaml -replace '(?m)^(permission\s*:)', "model: $Model`n`$1"
    }
    $newContent = $open + $yaml + $close + $body
    [System.IO.File]::WriteAllText($Path, $newContent, $utf8Bom)
  } else {
    Write-Host "  [WARN] 无法解析 frontmatter，跳过更新：$Path" -ForegroundColor Yellow
  }
}

# agent 正文模板（正文是通用执行器职责，固化在本脚本模板中；model 行按策略条件生成）
$agentTemplateHead = @'
---
description: >
  UX 视觉稿生成子代理。RDD-UX 专属，由 UX 派遣，按注入的方向简报生成单张
  UI mockup（图片或 HTML）。不进入 @ 菜单，不接受其他角色调用。模型与方向
  解耦——本代理不持有方向定义，具体设计方向由 UX dispatch 时动态注入；
  model 绑定由 ux_subagent.json 的策略状态机推导（本文件由 sync-ux-subagents
  脚本管理，请勿手改，改了也会被下次同步覆盖）。
mode: subagent
hidden: true
__MODEL_LINE__permission:
  read: allow
  glob: allow
  grep: allow
  list: allow
  edit:
    "*": deny
    ".rdd/changes/archive/**/design/mockups/**": allow
  bash: deny
  task: deny
  webfetch: deny
  websearch: deny
---

'@

$agentTemplateBody = @'
你是 UX 视觉稿生成子代理，RDD-UX 专属。

## 基本职责

UX 派遣你时会注入一份**方向简报**，其中包含：本方向的设计目标、主变量、驱动要素（布局/配色/风格关键词）、共享参数（内容领域、响应式目标、Phase 2 配色方向、设计规格草案要点）、素材类型（image 或 html）、输出路径，以及本方向的**完整生成指令**（image 素材的 prompt 骨架、html 素材的生成约束、差异化关键句）。

你的职责是**严格执行注入的方向简报**：
- 素材类型 = image → 按注入的 prompt 骨架填充，调用 runtime 可用的图片生成工具，存储到指定路径
- 素材类型 = html → 按注入的约束生成独立 HTML 文件（内联 `<style>`、CSS 自定义属性 Token、真实内容、含默认态与 hover 态），存储到指定路径

## 通用约束（所有方向适用）

- mockup 统一用内联 CSS，不依赖外部 CDN 或框架运行时——保证浏览器打开即正确渲染
- 若项目用 Tailwind CSS，在元素上以注释标注等效类名，但渲染不依赖 CDN
- 仅生成 1 份产物，分辨率/规格按方向简报要求
- 将产物写入 dispatch 指定的路径（`.rdd/changes/archive/.../design/mockups/` 下）
- 返回：文件名 + 一句话说明本方向视觉特征（供对比索引页使用）

## 边界

- 你**不持有任何方向定义**——"信息优先 / 任务优先 / 体验优先"等方向知识在 UX 的 `mockup-generation.md`，dispatch 时注入。若方向简报不完整，按其中已明确的部分执行，不自行编造方向
- 只写 dispatch 指定的 mockup 产物路径，不改其他文件
- 不派遣子代理、不联网、不执行 bash
- 仅接受 RDD-UX 派遣，其他角色调用应拒绝
'@

function New-AgentFile {
  param([string]$Path, [string]$Model)
  $modelLine = if ([string]::IsNullOrEmpty($Model)) { '' } else { "model: $Model`n" }
  $content = $agentTemplateHead.Replace('__MODEL_LINE__', $modelLine) + $agentTemplateBody
  [System.IO.File]::WriteAllText($Path, $content, $utf8Bom)
}

# ---------- 扫描磁盘 ----------
$disk = @{}
Get-ChildItem -LiteralPath $agentDir -Filter "ux-mockup-*.md" -File -ErrorAction SilentlyContinue | ForEach-Object {
  $name = $_.BaseName
  $disk[$name] = @{
    Path  = $_.FullName
    Model = (Get-AgentField -Path $_.FullName -Field "model")
  }
}

# ---------- 三路比对 + 执行 ----------
$changes = @()
$warnings = @()
$newManaged = @($managed)

# Create + Update（遍历约定集）
foreach ($name in $trio) {
  $model = $expected[$name]
  $modelDisplay = if ([string]::IsNullOrEmpty($model)) { '(无绑定，跟随会话模型)' } else { $model }
  $path = Join-Path $agentDir "$name.md"

  if (-not $disk.ContainsKey($name)) {
    # Create
    $changes += "created: $name  (model=$modelDisplay)"
    if (-not $WhatIf) {
      New-AgentFile -Path $path -Model $model
    }
    if ($newManaged -notcontains $name) { $newManaged += $name }
  } else {
    # Update 检测：磁盘 model 字段 vs 期望（无绑定时磁盘应无 model 行）
    $current = $disk[$name]
    $currentModel = $current.Model
    $needUpdate = $false
    if ([string]::IsNullOrEmpty($model)) {
      if (-not [string]::IsNullOrEmpty($currentModel)) {
        $changes += "updated: $name  (model: $currentModel -> 无绑定；mode=$mode)"
        $needUpdate = $true
      }
    } elseif ($currentModel -ne $model) {
      $from = if ([string]::IsNullOrEmpty($currentModel)) { '(无绑定)' } else { $currentModel }
      $changes += "updated: $name  (model: $from -> $model)"
      $needUpdate = $true
    }
    if ($needUpdate -and -not $WhatIf) {
      Update-AgentFrontmatter -Path $current.Path -Model $model
    }
  }
}

# Delete（遍历 managed，不在约定集的 → 删；约定集固定三名，此处仅清理遗留记录）
foreach ($name in @($managed)) {
  if ($trio -notcontains $name) {
    if ($disk.ContainsKey($name)) {
      $changes += "deleted: $name  (不在执行器约定集，清理对应 .md)"
      if (-not $WhatIf) {
        Remove-Item -LiteralPath $disk[$name].Path -Force
      }
    } else {
      $changes += "deleted: $name  (managed 记录残留，文件已不存在，仅清理记录)"
    }
    $newManaged = @($newManaged | Where-Object { $_ -ne $name })
  }
}

# Orphan 检测（磁盘有、managed 和约定集都没有 → 警告）
foreach ($name in @($disk.Keys)) {
  if ($managed -notcontains $name -and $trio -notcontains $name) {
    $warnings += "orphan: $name  (磁盘存在但非本系统管理，已跳过。如需纳入管理请加入 ux_subagent.json 的 managed 列表)"
  }
}

# ---------- 回写 json（仅当 managed 变化）----------
$managedChanged = $false
if (@($managed).Count -ne @($newManaged).Count) {
  $managedChanged = $true
} else {
  $diff = Compare-Object -ReferenceObject @($managed) -DifferenceObject @($newManaged)
  if ($diff) { $managedChanged = $true }
}

if ($managedChanged -and -not $WhatIf) {
  $config.managed = $newManaged
  $newJson = $config | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($jsonPath, $newJson + "`n", $utf8NoBom)
  $changes += "synced: managed 列表已更新回 $jsonPath"
}

# ---------- 报告 ----------
Write-Host ""
Write-Host "=== UX 子代理同步（策略驱动）===" -ForegroundColor Cyan
Write-Host "真相源：$jsonPath"
Write-Host "当前策略：mode=$mode"
Write-Host "执行器约定集：$($trio -join ' / ')"
Write-Host "目标目录：$agentDir"
if ($WhatIf) { Write-Host "模式：干跑（-WhatIf，未实际执行）" -ForegroundColor Yellow }
if ($notes.Count -gt 0) {
  Write-Host ""
  foreach ($n in $notes) { Write-Host "  note: $n" -ForegroundColor DarkYellow }
}
Write-Host ""

if ($changes.Count -eq 0 -and $warnings.Count -eq 0) {
  Write-Host "结果：无变更，所有 agent 配置已是最新。" -ForegroundColor Green
} else {
  if ($changes.Count -gt 0) {
    Write-Host "变更操作：" -ForegroundColor Green
    foreach ($c in $changes) { Write-Host "  + $c" }
  }
  if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "警告：" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
  }
  if ($changes.Count -gt 0 -and -not $WhatIf) {
    Write-Host ""
    Write-Host "*** agent 配置已变更，需重启 opencode 才能生效 ***" -ForegroundColor Cyan
  }
}
Write-Host ""
exit 0

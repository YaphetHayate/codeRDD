#Requires -Version 5.1
<#
.SYNOPSIS
  同步 UX 视觉稿生成子代理配置。
.DESCRIPTION
  真相源是 rdd-ux/ux_subagent.json。本脚本根据 json 的 agents（活跃）与 managed（所有权）
  列表，对 .opencode/agent/ux-mockup-*.md 执行 Create / Update / Delete：
    - agents 有、磁盘无           → Create（从模板生成，正文统一）
    - agents 有、磁盘有、字段不一致 → Update（只改 frontmatter 的 model/temperature）
    - managed 有、agents 无        → Delete（删文件 + 从 managed 移除）
    - 磁盘有、managed 与 agents 均无 → orphan 警告（不自动删，安全）
  agent 正文不随 model 变化——正文是通用执行器职责，固化在本脚本模板中。
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
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) {
  Write-Host "[ERROR] 无法定位 git 仓库根（git rev-parse --show-toplevel 失败）。请在仓库内运行。" -ForegroundColor Red
  exit 1
}
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

$active = @($config.agents)
$managed = @($config.managed)
if (-not $managed) { $managed = @() }

# 校验 agents 无重名
$activeNames = $active | ForEach-Object { $_.name }
$dups = $activeNames | Group-Object | Where-Object { $_.Count -gt 1 }
if ($dups) {
  Write-Host "[ERROR] agents 存在重名：$($dups.Name -join ', ')" -ForegroundColor Red
  exit 1
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
  param([string]$Path, [string]$Model, [string]$TempStr)
  $content = [System.IO.File]::ReadAllText($Path)
  if ($content -match '(?s)^(---\r?\n)(.*?)(\r?\n---\r?\n)(.*)$') {
    $open = $matches[1]
    $yaml = $matches[2]
    $close = $matches[3]
    $body = $matches[4]
    $yaml = $yaml -replace '(?m)^\s*model\s*:.*$', "model: $Model"
    $yaml = $yaml -replace '(?m)^\s*temperature\s*:.*$', "temperature: $TempStr"
    $newContent = $open + $yaml + $close + $body
    [System.IO.File]::WriteAllText($Path, $newContent, $utf8Bom)
  } else {
    Write-Host "  [WARN] 无法解析 frontmatter，跳过更新：$Path" -ForegroundColor Yellow
  }
}

# agent 正文模板（与手动维护的 agent 正文完全一致；model/temperature 用占位符）
$agentTemplate = @'
---
description: >
  UX 视觉稿生成子代理。RDD-UX 专属，由 UX 通过 Task 工具派遣，
  按注入的方向简报生成单张 UI mockup（图片或 HTML）。不进入 @ 菜单，
  不接受其他角色调用。model 与方向解耦——本代理只绑 model，具体设计方向
  由 UX dispatch 时动态注入。本文件由 sync-ux-subagents 脚本管理，
  请勿手改正文（改了也会被下次同步覆盖）；model/temperature 的真相源是
  rdd-ux/ux_subagent.json。
mode: subagent
hidden: true
model: __MODEL__
temperature: __TEMP__
permission:
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

你是 UX 视觉稿生成子代理，RDD-UX 专属。

## 基本职责

UX 派遣你时会通过 Task prompt 注入一份**方向简报**，其中包含：本方向的设计目标、主变量、驱动要素（布局/配色/风格关键词）、共享参数（内容领域、响应式目标、Phase 2 配色方向、设计规格草案要点）、素材类型（image 或 html）、输出路径，以及本方向的**完整生成指令**（image 素材的 prompt 骨架、html 素材的生成约束、差异化关键句）。

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
  param([string]$Path, [string]$Model, [string]$TempStr)
  $content = $agentTemplate.Replace('__MODEL__', $Model).Replace('__TEMP__', $TempStr)
  [System.IO.File]::WriteAllText($Path, $content, $utf8Bom)
}

# ---------- 扫描磁盘 ----------
$disk = @{}
Get-ChildItem -LiteralPath $agentDir -Filter "ux-mockup-*.md" -File -ErrorAction SilentlyContinue | ForEach-Object {
  $name = $_.BaseName
  $disk[$name] = @{
    Path  = $_.FullName
    Model = (Get-AgentField -Path $_.FullName -Field "model")
    Temp  = (Get-AgentField -Path $_.FullName -Field "temperature")
  }
}

# ---------- 三路比对 + 执行 ----------
$changes = @()
$warnings = @()
$newManaged = @($managed)

# Create + Update（遍历活跃 agents）
foreach ($agent in $active) {
  $name = $agent.name
  $model = $agent.model
  $tempStr = ($agent.temperature).ToString("G", [System.Globalization.CultureInfo]::InvariantCulture)
  $path = Join-Path $agentDir "$name.md"

  if (-not $disk.ContainsKey($name)) {
    # Create
    $changes += "created: $name  (model=$model, temperature=$tempStr)"
    if (-not $WhatIf) {
      New-AgentFile -Path $path -Model $model -TempStr $tempStr
    }
    if ($newManaged -notcontains $name) { $newManaged += $name }
  } else {
    # Update 检测
    $current = $disk[$name]
    $needUpdate = $false
    $detail = @()
    if ($current.Model -ne $model) {
      $detail += "model: $($current.Model) -> $model"
      $needUpdate = $true
    }
    if ($current.Temp -ne $tempStr) {
      $detail += "temperature: $($current.Temp) -> $tempStr"
      $needUpdate = $true
    }
    if ($needUpdate) {
      $changes += "updated: $name  ($($detail -join '; '))"
      if (-not $WhatIf) {
        Update-AgentFrontmatter -Path $current.Path -Model $model -TempStr $tempStr
      }
    }
  }
}

# Delete（遍历 managed，不在 active 的 → 删）
foreach ($name in @($managed)) {
  if ($activeNames -notcontains $name) {
    if ($disk.ContainsKey($name)) {
      $changes += "deleted: $name  (已从 agents 移除，清理对应 .md)"
      if (-not $WhatIf) {
        Remove-Item -LiteralPath $disk[$name].Path -Force
      }
    } else {
      $changes += "deleted: $name  (managed 记录残留，文件已不存在，仅清理记录)"
    }
    $newManaged = @($newManaged | Where-Object { $_ -ne $name })
  }
}

# Orphan 检测（磁盘有、managed 和 active 都没有 → 警告）
foreach ($name in @($disk.Keys)) {
  if ($managed -notcontains $name -and $activeNames -notcontains $name) {
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
Write-Host "=== UX 子代理同步 ===" -ForegroundColor Cyan
Write-Host "真相源：$jsonPath"
Write-Host "目标目录：$agentDir"
if ($WhatIf) { Write-Host "模式：干跑（-WhatIf，未实际执行）" -ForegroundColor Yellow }
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

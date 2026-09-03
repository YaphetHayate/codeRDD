# 归档规则

> PM 专属：统一归档流程。标准流程和快速通道均引用本文档，各自以差异覆盖。

---

## 归档目录结构

```
.rdd/changes/archive/YYYY-MM-DD-short-name/
├── task.json                        (路由总览，真源)
├── requirements/                   (需求文档)
│   ├── overview.md                 (需求概览)
│   └── {name}.md                   (独立需求文件)
├── design/                         (CTO/UX 产出)
├── tests/                          (QA 产出)
└── eval/                           (EVAL 产出)
```

---

## 归档步骤

### 1. 创建目录

在 `.rdd/changes/archive/` 下创建 `YYYY-MM-DD-short-name` 文件夹（如 `2026-06-04-engine-adapter-modularization`）。

```powershell
New-Item -ItemType Directory -Path ".rdd/changes/archive/YYYY-MM-DD-short-name/requirements" -Force
```

### 2. 生成 overview.md

写入 `requirements/overview.md`，按 `references/overview-template.md` 模板格式。

> **快速通道差异**：背景段简短即可。

### 3. 生成需求文件

写入 `requirements/{name}.md`（文件名由 PM 确定简短主题名词），按 `references/requirement-item-template.md` 模板格式。

> **快速通道差异**：只生成一个需求文件；描述直接引用用户原文；如用户提供了验收标准直接采用，否则写一条最简标准；如用户提供了具体做法标注"用户预设方案"。

### 4. 生成 task.json

写入 `task.json`（归档根目录），通过 CLI 初始化。先准备 `tasks-init.json`（UTF-8 无 BOM），包含 tasks 数组，然后调用 `init`：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command init -Archive ".rdd/changes/archive/YYYY-MM-DD-short-name" -TasksFile ".rdd/changes/archive/YYYY-MM-DD-short-name/tasks-init.json"
```

字段填写指南见 `references/task-template.md`，路由判定规则见 `references/artifact-routing.md`。`currentOwners` 设为该需求的下一条处理角色。

### 5. 设置流转控制

为每个需求文档设置 `## 流转控制 > 当前责任人`，按 `references/artifact-routing.md` 的路由判定规则：
- 简单需求、单一模块/功能、无架构影响 → `DEV`
- 涉及多模块/架构变更/技术选型 → `CTO`
- 涉及页面设计/UI/交互体验/前端界面 → `UX`
- 复合需求（技术+视觉耦合）→ 先 `CTO`，CTO 完成后再路由到 `UX`

> **快速通道差异**：不对目标角色做任何预设（可能是 DEV、CTO 或 UX）。

### 6. 委托 engine 探索代码（可选）

若需求需要理解现有代码，委托 rdd-engine 执行检索（产物缓存于全局双层索引——热区优先，下游角色可复用）：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search -Query "分析 [需求简述] 涉及的代码模块"
```

> engine 按 `rdd-engine/references/exploration-guide.md` 的策略执行：返回数据所在位置（已通过时效校验，热区优先），PM 扫 tags 判断后 Read 摘要或派 worker 探索并注册入热区。
>
> 如果变更范围简单（单文件/单模块），可跳过此步骤。快速通道默认跳过。

### 7. 执行角色交接

确认归档完成后（task.json 路由已初始化），按 `rdd-engine/references/transition-guide.md` 的**上游协议 4 步硬流程**执行角色交接：

1. task.json 路由已设置（Step 4 已在归档步骤完成）
2. 运行 `next` 展示可流转角色
3. 推荐角色 + 请求用户确认
4. 用户确认后运行 `start` 生成交接包，按模式（self-driven / app-driven）分支执行

> 完整流程、模式检测、交接包生成方式见 `rdd-engine/references/transition-guide.md`。

### 8. 完成后

告知归档位置，给出下一步建议，等待用户指令。

如果用户的问题还需要继续讨论，不要急着推进到归档。

---

## 历史兼容

- 旧归档结构（需求文件在根目录、无 requirements/ 子目录）各角色回退到旧逻辑处理
- 旧归档有 task.md 无 task.json：`rdd-flow.ps1` 自动回退解析 task.md；可用 `rdd-flow.cmd -Command migrate -Archive <path>` 迁移为 task.json
- 旧 task.md 格式（无路由总览、含已废弃的「角色参与计划」章节或旧版 ✅⬜ 状态表）各角色忽略 `角色参与计划`，从路由总览派生参与信息
- 旧 rdd-flow 脚本会先在根目录查找需求文件，找不到时回退到 `requirements/` 子目录

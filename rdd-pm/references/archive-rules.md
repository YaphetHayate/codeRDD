# 归档规则

> PM 专属：统一归档流程。标准流程和快速通道均引用本文档，各自以差异覆盖。

---

## 归档目录结构

```
.rdd/changes/archive/YYYY-MM-DD-short-name/
├── task.md                         (路由总览)
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

### 4. 生成 task.md

写入 `task.md`（归档根目录），按 `references/task-template.md` 模板格式。填写路由总览（`当前责任人` 列设为该需求下一条处理角色）。

需求文件列填写 `requirements/{name}.md` 格式。

### 5. 设置流转控制

为每个需求文档设置 `## 流转控制 > 当前责任人`，按 `references/artifact-routing.md` 的路由判定规则：
- 简单需求、单一模块/功能、无架构影响 → `DEV`
- 涉及多模块/架构变更/技术选型 → `CTO`
- 涉及页面设计/UI/交互体验/前端界面 → `UX`
- 复合需求（技术+视觉耦合）→ 先 `CTO`，CTO 完成后再路由到 `UX`

> **快速通道差异**：不对目标角色做任何预设（可能是 DEV、CTO 或 UX）。

### 6. 委托 engine 探索代码（可选）

若需求需要理解现有代码，委托 rdd-engine 执行探索（产物缓存于全局索引，下游角色可复用）：

```powershell
engine.ps1 -Type explore -Query "分析 [需求简述] 涉及的代码模块"
```

> engine 的 explore subagent 会按 `rdd-engine/references/exploration-guide.md` 的策略执行：先查 `.rdd/exploration/index.json` 缓存，命中且文件未过期则直接返回；否则探索代码并写入全局缓存。
>
> 如果变更范围简单（单文件/单模块），可跳过此步骤。快速通道默认跳过。

### 7. 调用流转脚本并告知用户

确认归档完成后，更新 `task.md` 路由总览，调用流转脚本查看待处理角色：

```powershell
rdd-engine/rdd-flow.ps1 -Command next -Archive ".rdd/changes/archive/YYYY-MM-DD-short-name" -Format markdown
```

告知用户：
- **归档位置**
- **各需求文档的路由去向**（列明每个需求文件的当前责任人）

> **标准流程额外告知**：
> - **并行可能**：CTO 和 UX 路由的需求在无耦合时可同时启动
> - **同角色多需求并行**：每个需求独立启动，用 `-TaskIndex` 区分
>   ```powershell
>   rdd-engine/rdd-flow.ps1 -Command start -Role DEV -TaskIndex 0 -Format markdown
>   rdd-engine/rdd-flow.ps1 -Command start -Role DEV -TaskIndex 1 -Format markdown
>   ```
> - **可流转角色**：使用 `next` 输出的 roles
> - **启动引导**：agent 决定并经用户确认后生成启动引导
>   ```powershell
>   rdd-engine/rdd-flow.ps1 -Command start -Role <目标角色> -Format markdown
>   ```
> - **用户拒绝则手动引导**：告知用户可输入 `/RDD-CTO`、`/RDD-UX` 或 `/RDD-DEV`

> **快速通道差异**：省略并行启动和 `-TaskIndex` 说明，单个需求无并行场景。

### 8. 完成后

告知归档位置，给出下一步建议，等待用户指令。

如果用户的问题还需要继续讨论，不要急着推进到归档。

---

## 历史兼容

- 旧归档结构（需求文件在根目录、无 requirements/ 子目录）各角色回退到旧逻辑处理
- 旧 task.md 格式（无路由总览、含已废弃的「角色参与计划」章节或旧版 ✅⬜ 状态表）各角色忽略 `角色参与计划`，从路由总览派生参与信息；无路由总览则回退到旧逻辑
- 旧 rdd-flow 脚本会先在根目录查找需求文件，找不到时回退到 `requirements/` 子目录

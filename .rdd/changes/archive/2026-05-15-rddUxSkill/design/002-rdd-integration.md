---
requirement_id: 需求 4+5
priority: 中
depends_on:
  - 需求 1+2+3（UX Skill 本体）
blocks: []
analysis_date: 2026-05-15
status: confirmed
---

# RDD 流程集成 — 设计文档

## 一、需求概述

将 UX skill 集成到现有 RDD 工作流中：注册到 skill-registry、改造 PM/CTO/DEV 的分流逻辑以支持 UX 环节、更新 task.md 模板。

## 二、技术方案

### 2.1 改动清单

| # | 改动文件 | 改动内容 | 改动性质 |
|---|----------|----------|----------|
| 1 | `skill-registry.md` | 新增 UX 条目 | 增量 |
| 2 | `rdd-pm/SKILL.md` | 第五步归档后增加 UX 分流引导 | 增量 |
| 3 | `rdd-pm/references/task-template.md` | 表头增加 UX 列 | 增量 |
| 4 | `rdd-cto/SKILL.md` | 1.2 领域识别增加 UX 匹配 | 增量 |
| 5 | `rdd-cto/references/design-guide.md` | 设计文档模板增加 UX 指导说明 | 增量 |
| 6 | `rdd-dev/SKILL.md` | 任务分析增加 UX 规格读取逻辑 | 增量 |

### 2.2 各改动详细方案

#### 改动 1：skill-registry.md

在现有条目之后追加：

```markdown
### rdd-ux

- **领域标签**：UX, 视觉设计, 交互设计, 前端设计, UI, 用户体验, 设计规格, design token, 组件规范, 响应式
- **能力概述**：前端视觉设计和交互设计，支持参考图分析（翻译者模式）和独立设计（创作者模式）
- **使用方式**：读取 SKILL.md 获取设计方法论；涉及前端视觉/交互需求时由 PM 引导或 CTO/DEV 自动匹配
```

#### 改动 2：rdd-pm/SKILL.md

在第五步归档后的分流逻辑中，增加 UX 分支。在现有"建议路径"判断之前，增加前端/视觉需求的检测：

```
归档完成后的分流增强：
  │
  ├── 需求涉及前端视觉/交互？
  │   ├── 是 → 建议启动 UX（/RDD-UX）
  │   │   ├── 与 CTO 不耦合 → 告知可同时启动 UX 和 CTO
  │   │   └── 与 CTO 有耦合 → 建议先 CTO 后 UX 或并行
  │   └── 否 → 走原有逻辑
  │
  └── 原有逻辑（建议 CTO 或 DEV）
```

具体改动位置：在 PM SKILL.md 的"第四步：分流"章节，在现有建议路径之前插入前端/视觉需求的判断。

#### 改动 3：task-template.md

表头增加 UX 列：

```markdown
| Task | 优先级 | PM | CTO | UX | DEV | QA |
```

Task 详情部分增加 UX 字段：

```markdown
- **UX**：⬜
```

UX 列状态规则与 CTO 一致：✅（设计完成）/ ⏭️（跳过，无需设计）/ ⬜（待处理）。

#### 改动 4：rdd-cto/SKILL.md

在 1.2 领域识别章节的领域标签提取规则中，补充前端相关领域：

```
- 视觉设计（UI/UX、布局、配色、交互、组件规范、响应式）
```

匹配到 UX 领域标签时，在分级结果表中引用 UX skill，并在设计文档的"1.5 领域 Skill 指导"章节中标注：

```
本需求涉及前端视觉/交互设计，建议由 UX skill 负责设计规格产出。
CTO 的设计文档聚焦技术架构（接口、数据模型、模块划分），
视觉层面的设计规格由 UX skill 的 design/ux-spec.md 提供。
```

#### 改动 5：rdd-cto/references/design-guide.md

在"设计文档模板"的"一点五、领域 Skill 指导"章节增加 UX 的说明示例：

```markdown
当需求匹配到 UX skill 时，CTO 设计文档中应标注：
> 本需求的前端视觉/交互设计由 UX skill 负责（→ design/ux-spec.md）。
> CTO 设计文档聚焦：接口设计、数据模型、模块划分、技术选型。
```

#### 改动 6：rdd-dev/SKILL.md

在任务分析阶段的分析流程中，"通读文档"步骤增加 UX 规格检查：

```
通读文档（设计文档/需求文档）
  │
  ├── 检查 design/ 目录下是否存在 ux-spec.md
  │   ├── 存在 → 读取 UX 设计规格，视觉/交互层面以 UX 规格为准
  │   └── 不存在 → 不影响，按原流程
  │
  ├── [原有逻辑继续]
```

在拆分计划的呈现格式中，增加 UX 规格的引用说明：

```
Task 2: [任务标题]
  涉及文件：xxx.js, yyy.css
  设计参考：CTO design/001-xxx.md + UX design/ux-spec.md
  / ⚠️ 无 UX 设计规格，视觉层面需自行判断
```

### 2.3 集成点描述

| 集成点 | 已有模块 | 调用关系 | 数据流向 | 时序约束 |
|--------|----------|----------|----------|----------|
| skill-registry | `skill-registry.md` | CTO/DEV 读取 | 领域标签匹配 → UX skill 引用 | CTO Phase 1 / DEV 任务分析 |
| PM 分流 | `rdd-pm/SKILL.md` | PM 归档后判断 | 需求内容 → 是否建议 UX | PM 第五步 |
| task.md | `rdd-pm/references/task-template.md` | 所有角色读写 | UX 列状态 | PM 归档 / UX Phase 4 / DEV 完成 |
| CTO 领域识别 | `rdd-cto/SKILL.md` | CTO Phase 1 | 领域标签 → UX skill 匹配 | CTO 1.2 |
| DEV 任务分析 | `rdd-dev/SKILL.md` | DEV 任务分析 | design/ux-spec.md → DEV 实现 | DEV 分析阶段 |

## 三、风险与应对

| 风险 | 影响 | 应对措施 | 优先级 |
|------|------|----------|--------|
| 改动影响现有流程 | 现有 skill 行为变化 | 所有改动为纯增量插入，不修改现有逻辑 | P2 |

## 四、实现优先级建议

在批次 A（UX Skill 本体）完成后执行。内部顺序：

1. skill-registry.md（注册 UX）
2. task-template.md（支持 UX 列）
3. rdd-pm/SKILL.md（PM 分流引导）
4. rdd-cto/SKILL.md + design-guide.md（CTO 领域识别）
5. rdd-dev/SKILL.md（DEV 规格读取）

## 五、实现步骤清单

| 步骤 | 文件 | 操作 |
|------|------|------|
| 1 | `skill-registry.md` | 追加 rdd-ux 条目 |
| 2 | `rdd-pm/references/task-template.md` | 表头和详情增加 UX 列 |
| 3 | `rdd-pm/SKILL.md` | 第五步分流增加 UX 引导 |
| 4 | `rdd-cto/SKILL.md` | 1.2 章节增加 UX 领域标签匹配 |
| 5 | `rdd-cto/references/design-guide.md` | 设计文档模板增加 UX 说明 |
| 6 | `rdd-dev/SKILL.md` | 任务分析增加 UX 规格读取 |

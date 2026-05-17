# 需求清单

## 背景

RDD-DEV 的 SKILL.md 当前约 630 行，其中大量篇幅是各工作模式和阶段的详细执行流程。每次加载 skill 时这些内容都会被读取，消耗不必要的 token。相比之下，同项目的 RDD-PM 已采用了轻量化拆分模式——SKILL.md 只保留工作流骨架和调度逻辑，具体做法全在 references/ 里。RDD-DEV 应对齐这一模式，在不损失能力完整性的前提下让 SKILL.md 变得轻量。

## 需求列表

### 需求 1：提取四种工作模式详细流程到 reference

- **描述**：将 SKILL.md 中"四种工作模式"章节（Mode 1 设计引导、Mode 2 需求引导、Mode 3 直接开发、Mode 4 Bug 修复）的全部详细执行流程提取到 `references/mode-strategies.md`
- **验收标准**：
  - `references/mode-strategies.md` 包含四种模式的完整执行流程，内容与提取前完全一致（只做位置迁移）
  - SKILL.md 中对应位置替换为简短描述 + 调度指针（如 `> 详细流程见 references/mode-strategies.md`）
- **优先级**：高
- **影响范围**：SKILL.md、references/mode-strategies.md（新建）

### 需求 2：提取任务分析阶段详细流程到 reference

- **描述**：将 SKILL.md 中"任务分析阶段"章节的详细分析流程（统一文档解读、Skill 匹配、文件冲突检查、前置条件核对、任务分类、集成点识别）、拆分原则、分类标准、冲突防护规则、依赖执行规则提取到 `references/task-analysis.md`
- **验收标准**：
  - `references/task-analysis.md` 包含任务分析阶段的全部详细流程和规则，内容与提取前完全一致
  - SKILL.md 中对应位置替换为简短概述 + 调度指针
- **优先级**：高
- **影响范围**：SKILL.md、references/task-analysis.md（新建）

### 需求 3：提取执行阶段详细规则到 reference

- **描述**：将 SKILL.md 中"执行阶段"章节的并行组执行流程、单任务自测规则、双层冒烟验证（含跳过条件）、Bug 修复场景验证专项检查提取到 `references/execution-rules.md`
- **验收标准**：
  - `references/execution-rules.md` 包含执行阶段的全部详细规则，内容与提取前完全一致
  - SKILL.md 中对应位置替换为简短概述 + 调度指针
- **优先级**：高
- **影响范围**：SKILL.md、references/execution-rules.md（新建）

### 需求 4：精简 SKILL.md 主体

- **描述**：在 R1-R3 提取完成后，确保 SKILL.md 整体结构清晰、行数从 ~630 行降至 ~300 行左右
- **验收标准**：
  - SKILL.md 行数 ≤ 350 行
  - 输入处理（优先级 A-E）、模式边界、核心原则、对话风格等章节保留在 SKILL.md 中
  - 提交、QA 流转、异常处理、模式衔接等章节的调度指针引用方式与现有 references 保持风格一致
  - 现有 6 个 reference 文件内容不受影响
  - SKILL.md 可独立阅读，调度逻辑完整（能通过指针找到所有详细流程）
- **优先级**：高
- **影响范围**：SKILL.md
- **依赖关系**：依赖 R1、R2、R3 完成

## 关键约束

- 所有内容只做位置迁移，不做语义修改或能力删减
- 现有 6 个 reference 文件不受影响
- 遵循 RDD-PM 的拆分模式：SKILL.md = "做什么、何时做"，references/ = "怎么做"

## 讨论记录

- 用户明确提出"将每个场景的详细做法拆分到 reference 里面"，方向明确
- 采用与 RDD-PM 一致的职责维度拆分策略（mode-strategies / task-analysis / execution-rules），而非按模式一对一拆分，避免文件碎片化

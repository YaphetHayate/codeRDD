# Skill 索引

> 本文件是历史兼容索引。新的统一入口是 rdd-engine 的 `/skill-manager`，管理文件位于 `.rdd/skill-manager/index.md`。
> 当 `.rdd/skill-manager/index.md` 不存在或未命中时，skill-manager 可读取本文件作为兼容来源，并把命中的条目同步到 manager index。
> 注意：rdd-pm、rdd-cto、rdd-dev、rdd-qa 是 RDD 工作流角色，不是领域顾问 skill，不纳入此索引。

### skill-manager

- **领域标签**：skill 管理, 技能管理, skill 匹配, skill 发现, find-skills, 能力增强, 领域顾问, skill 评分, skill 迭代
- **能力概述**：rdd-engine 的领域能力管理层，统一管理各角色可见的外部 skill，自动发现未掌握 skill，并根据 EVAL/用户反馈维护评分和迭代建议
- **使用方式**：CTO/DEV/UX/EVAL 遇到非通用领域能力需求时调用 `/skill-manager query`；EVAL 出现 C/D 评分或用户差评时调用 `/skill-manager feedback`

### pixel-art-sprites

- **领域标签**：像素美术, pixel art, sprite, 精灵图, 调色板, 像素画, 角色绘制, 动画帧, tile, 8-bit, 16-bit, 角色动画, retro
- **能力概述**：像素画创作、精灵图动画、有限调色板设计
- **使用方式**：读取 SKILL.md 获取像素画技法指导（调色板策略、像素密度、阴影技法、sprite sheet 设计）

### rdd-engine

- **领域标签**：项目理解, 代码风格, 项目结构, 项目术语, 代码分析, 上下文, 代码质量
- **能力概述**：RDD 工作流共享基础设施，提供项目理解产物的懒加载生成与管理。CTO/DEV/UX 在关键阶段自动调用 /context 获取项目上下文。
- **使用方式**：CTO Phase 1、DEV 任务分析、UX Phase 1 自动调用；也可手动执行 /context

### find-skill

- **领域标签**：技能发现, skill 搜索, 寻找技能, 找skill
- **能力概述**：当索引中无匹配 skill 时，搜索发现可用的技能
- **使用方式**：CTO/DEV 在索引中无匹配项时调用此 skill

### rdd-eval

- **领域标签**：验收评价, 质量评估, 流程审视, 代码审查, 设计评审, 协同分析, retrospective
- **能力概述**：对已完成需求进行全流程回顾性评价，覆盖 PM/CTO/UX/DEV/QA 各角色产出质量和跨角色协同效率，提炼 RDD 流程优化建议
- **使用方式**：用户显式调用 /RDD-EVAL 触发；读取全部归档产出物后生成结构化评价报告

### rdd-ux

- **领域标签**：UX, 视觉设计, 交互设计, 前端设计, UI, 用户体验, 设计规格, design token, 组件规范, 响应式, 页面设计, 界面设计
- **能力概述**：前端视觉设计和交互设计，支持参考图分析（翻译者模式）和独立设计（创作者模式），产出结构化设计规格文档
- **使用方式**：读取 SKILL.md 获取设计方法论；涉及前端视觉/交互需求时由 PM 引导或 CTO/DEV 自动匹配

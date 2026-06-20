# codeRDD — Requirement-Driven Development Skill

## 设计理念

SDD（Specification-Driven Development）驱动的开发工作流，围绕一个核心管道展开：

```
要做什么？ → 要怎么做？ ↔ 做 ↔ 验证 → 评价
```

### 阶段与角色映射

| 阶段 | 问题 | 角色 | 说明 |
|------|------|------|------|
| 定义 | **要做什么？** | [PM](./rdd-pm/) | 需求定义、场景拆分、优先级排序 |
| 设计 | **要怎么做？** | [CTO](./rdd-cto/) + [UX](./rdd-ux/) | 技术方案 + 视觉/交互设计 |
| 实现 | **做** | [DEV](./rdd-dev/) | 任务拆解、并行开发、代码审查 |
| 验证 | **验证** | [QA](./rdd-qa/) | 独立测试、质量验证 |
| 评价 | **评价** | [EVAL](./rdd-eval/) | 交付质量评估、协作效率复盘 |
| 呈现 | **怎么讲？** | [PSE](./rdd-pse/) | README 维护、项目上下文文档生成 |

### 核心迭代关系

- **要怎么做？ ↔ 做**：设计与实现双向反馈 — 设计指导实现，实现中发现的问题反馈优化设计
- **做 ↔ 验证**：实现与验证双向迭代 — 测试发现的问题驱动修复，修复后重新验证

### 基础设施

- **[rdd-engine](./rdd-engine/)**：能力总线，提供代码探索和阶段流转能力

---

## 使用方式

角色通过 opencode 自定义命令激活（命令位于 `.opencode/commands/`）。每个角色在自己的会话里工作；切换角色时**开新会话**以保证上下文纯净。

### 角色入口命令

- `/rdd-pm` — 需求定义（流程起点，无交接包）
- `/rdd-cto` — 技术架构
- `/rdd-ux` — 视觉/交互设计
- `/rdd-dev` — 开发实现
- `/rdd-qa` — 测试验证（待补）
- `/rdd-eval` — 交付评价（待补）
- `/rdd-pse` — 文档维护（待补）

### 角色切换流程

```
当前角色完成产物归档 → $r = git rev-parse --show-toplevel; & "$r\rdd-engine\scripts\rdd-flow.cmd" -Command next 推荐下游 → 用户确认
  → /new（Ctrl+X N）开新会话（清理上下文）
  → 输入 /rdd-<下游角色> → 自动加载角色 SKILL + 最新交接包 → 干净进入
```

> 角色切换必须开新会话：opencode 的 agent 无法在同会话内真正隔离上下文，"同会话宣布边界"无法阻止上游对话污染下游。详见 `rdd-engine/references/transition-guide.md`。

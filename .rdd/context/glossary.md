# 项目术语表

## 模块术语

| 术语/模块名 | 含义 | 对应路径 | 核心能力 |
|------------|------|---------|---------|
| RDD | Requirement-Driven Development，需求驱动开发工作流 | 全局 | 五阶段工作流：PM→CTO→DEV（UX/QA并行） |
| SKILL.md | 每个 RDD 角色的技能定义文件 | rdd-*/SKILL.md | 定义角色行为、约束、工作流程 |
| task.md | 任务追踪文件，包含角色参与计划和进度表 | .rdd/changes/archive/*/task.md | 追踪 PM/CTO/UX/DEV/QA 各阶段完成状态 |
| overview.md | 需求总览文件，索引所有需求 + 背景 + 讨论记录 | .rdd/changes/archive/*/overview.md | 需求族的总入口 |
| design/ | 设计文档子目录，存放 CTO 和 UX 产出 | .rdd/changes/archive/*/design/ | 独立存储各角色设计文档 |
| references/ | 各 skill 的策略文件子目录 | rdd-*/references/ | 存放详细执行策略、模板、指南 |
| /context | rdd-engine 提供的项目上下文指令 | rdd-engine/SKILL.md | 生成/读取 style.md, structure.md, glossary.md |

## 业务概念

| 术语 | 含义 | 出现场景 |
|------|------|---------|
| 角色参与计划 | task.md 中的章节，声明哪些角色参与本次需求 | task.md 头部 |
| 模式切换 | 通过指令（如 /RDD-CTO）在工作流角色间流转 | 各 SKILL.md 的"退出方式"章节 |
| 需求归档 | PM 完成需求梳理后将文档写入 .rdd/changes/archive/ 的过程 | PM Phase 5 |
| 分级设计 | CTO 对需求按 L1/L2/L3 分级，不同等级不同分析深度 | CTO Phase 1.1 |
| 需求与方案分离 | PM 的核心原则——将用户的问题描述与预设解法剥离开 | PM SKILL.md 核心原则 |
| 红线/禁令 | 各角色模式的硬性约束，凌驾于所有其他指令 | 各 SKILL.md "模式边界与红线" |
| 子 agent | DEV 模式下通过 Task 工具启动的并行工作单元 | DEV 执行阶段 |

## 技术术语（项目特有）

| 术语 | 含义 | 用途 |
|------|------|------|
| agent/subagent | opencode 的并行执行单元，通过 Task 工具启动 | DEV 拆分并行任务时使用 |
| explore agent | opencode 内置的代码探索 agent 类型 | 搜索、定位代码时使用 |
| general agent | opencode 内置的通用 agent 类型 | 执行复杂多步骤任务时使用 |
| skill 工具 | opencode 用来加载 SKILL.md 的技能注入工具 | 各角色通过 skill 工具启动目标模式 |

---
生成时间：2026-05-24T16:24:00
采样文件：rdd-cto/SKILL.md, rdd-dev/SKILL.md, rdd-engine/SKILL.md, rdd-pm/SKILL.md, rdd-ux/SKILL.md

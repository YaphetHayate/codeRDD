# 代码结构

## 目录布局

```
codeRDD/                          // RDD 工作流 skill 开发项目
├── rdd-cto/                      // CTO 技术架构师 skill 定义
│   ├── SKILL.md                  // 入口文件（224行）
│   ├── references/               // 策略文件（analysis-l2, design-guide, self-check 等）
│   └── skills/                   // 已缓存的外部 skill
├── rdd-dev/                      // DEV 开发主管 skill 定义
│   ├── SKILL.md                  // 入口文件（120行）
│   └── references/               // 策略文件（task-analysis, execution-rules 等）
├── rdd-engine/                   // 共享基础设施 skill 定义
│   ├── SKILL.md                  // 入口文件（313行）
│   └── references/               // 策略文件（context-guide, tools-metadata 等）
├── rdd-eval/                     // EVAL 验收评价 skill 定义
│   └── SKILL.md
├── rdd-pm/                       // PM 产品经理 skill 定义
│   ├── SKILL.md                  // 入口文件
│   └── references/               // 策略文件
├── rdd-qa/                       // QA 测试工程师 skill 定义
│   └── SKILL.md
├── rdd-ux/                       // UX 设计师 skill 定义
│   ├── SKILL.md                  // 入口文件（224行）
│   └── references/               // 策略文件
├── .rdd/                         // RDD 工作流数据
│   ├── changes/archive/          // 归档需求（14个历史归档）
│   └── context/                  // 项目理解产物（本次生成）
├── .claude/                      // Claude IDE 配置
└── .gitignore
```

## 模块职责

| 模块 | 路径 | 职责 | 关键文件 |
|------|------|------|---------|
| RDD-PM | rdd-pm/ | 产品经理模式：需求讨论、头脑风暴、需求归档 | SKILL.md |
| RDD-CTO | rdd-cto/ | 技术架构师模式：需求分析、技术方案设计 | SKILL.md, references/design-guide.md |
| RDD-DEV | rdd-dev/ | 开发主管模式：任务拆分、子agent协调、代码实施 | SKILL.md, references/task-analysis.md |
| RDD-UX | rdd-ux/ | UX设计师模式：视觉分析、设计规格产出 | SKILL.md |
| RDD-QA | rdd-qa/ | 测试工程师模式：测试用例设计、测试代码编写 | SKILL.md |
| RDD-EVAL | rdd-eval/ | 验收评价模式：全流程回顾、质量评价 | SKILL.md |
| rdd-engine | rdd-engine/ | 共享基础设施：项目理解（/context）、术语表、代码索引 | SKILL.md, references/context-guide.md |

## 模块依赖关系

```
              ┌─────────────┐
              │   rdd-pm    │  ← 工作流起点：需求梳理
              └──────┬──────┘
                     │ 归档需求文档
         ┌───────────┼───────────┐
         ▼           ▼           ▼
    ┌─────────┐ ┌─────────┐ ┌─────────┐
    │ rdd-cto │ │ rdd-ux  │二者可并行（前后端不耦合时）
    └────┬────┘ └────┬────┘
         │    设计文档    │
         └───────┬───────┘
                 ▼
    ┌──────────────────────┐
    │       rdd-dev        │  ← 工作流终点：代码实施
    └──────────┬───────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌──────┐  ┌──────┐  ┌──────┐
│  QA  │  │ EVAL │  │engine│  ← 角色均可调用 engine
└──────┘  └──────┘  └──────┘
```

- PM 是唯一入口——所有需求必须经 PM 归档
- CTO 和 UX 并行接收 PM 产出（需求文档），各自独立产出设计文档
- DEV 接收 CTO + UX 的设计文档后实施
- QA 独立于 DEV，只读需求文档不看设计文档（避免偏见）
- rdd-engine 被 CTO/DEV/UX 在关键阶段调用，提供项目上下文
- 各角色通过模式切换指令（/RDD-XX）流转

## 代码质量问题

> 本项目为纯 Markdown 技能定义项目，无传统代码。以下为文档组织层面的观察：

| 类型 | 位置 | 描述 | 严重程度 |
|------|------|------|---------|
| 模板参考缺失 | rdd-pm/references/ | PM SKILL.md 引用了 references/overview-template.md 等文件但实际不存在 | 中 |
| 模板参考缺失 | rdd-ux/references/ | UX SKILL.md 引用了 references/visual-analysis-guide.md 等文件但实际不存在 | 中 |
| 模板参考缺失 | rdd-engine/references/ | SKILL.md 引用了 references/tools-metadata.md 但 glob 未找到 | 低 |

---
生成时间：2026-05-24T16:24:00
采样文件：rdd-cto/SKILL.md, rdd-dev/SKILL.md, rdd-engine/SKILL.md, rdd-pm/SKILL.md, rdd-ux/SKILL.md

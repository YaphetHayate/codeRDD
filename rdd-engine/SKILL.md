---
name: rdd-engine
description: >
  RDD 工作流共享基础设施。不做决策，只做项目理解与知识服务——所有"需要做但不知道该谁做"的
  项目级工作统一委派给它。当前提供项目上下文产物的懒加载生成与管理（代码风格、代码结构、
  项目术语），以及 skill-manager：统一管理各角色可见的外部 skill、自动发现未掌握 skill、
  记录 skill 使用评分并从 EVAL 反馈中迭代角色能力。CTO/DEV/UX/EVAL 在关键阶段自动调用。
---

# rdd-engine — RDD 工作流共享基础设施

## 它解决什么问题

RDD 各角色（CTO/DEV/UX）每次进入项目都需要重新理解代码风格、结构和术语，也会在遇到特定领域时各自寻找 skill。这种重复理解和分散管理既低效也不一致——不同会话可能得出不同的结论，也可能重复搜索同一个 skill。

rdd-engine 通过**按需生成、持久化缓存**的项目理解产物，让项目知识一次生成、多角色复用；通过 **skill-manager** 统一管理领域 skill，让角色只提出能力需求，由 engine 负责匹配、发现、评分和迭代。它不替代 PM/CTO/DEV/UX/QA 做业务或技术决策，只提供知识服务。

## 定位

```
角色层（决策者）          基础设施层（服务者）
┌──────────┐
│   PM     │
├──────────┤
│   CTO    │──调用──▶┌──────────────┐
├──────────┤         │              │
│   DEV    │──调用──▶│  rdd-engine  │
├──────────┤         │              │
│   UX     │──调用──▶│  项目理解     │
├──────────┤         │  知识服务     │
│   QA     │         │              │
└──────────┘         └──────────────┘
```

## 核心指令

| 指令 | 功能 | 典型场景 |
|------|------|----------|
| `/context` | 生成/读取项目理解产物 | CTO Phase 1、DEV 任务分析、UX Phase 1 |
| `/skill-manager` | 匹配、发现、评分和迭代领域 skill | CTO/DEV/UX/EVAL 遇到非通用领域能力需求 |

---

## `/context` — 项目上下文产物管理

### 执行流程

```
/context

1. 检查 .rdd/context/ 是否存在完整产物（meta.json + style.md + structure.md + glossary.md）
   │
   ├── 存在 → 检查新鲜度
   │   ├── 新鲜 → 读取产物，返回产物路径
   │   └── 过期 → 提示用户：
   │       "项目理解产物已过期（生成于 [时间]，代码已变更）。
   │        - 重新生成 → 执行步骤 2-4
   │        - 继续使用旧产物 → 直接读取"
   │
   └── 不存在 → 进入步骤 2

2. 采样项目代码
   │  详见 `references/context-guide.md` > 采样策略
   │
   └── 总采样量控制在 3-8 个文件，轻量不全量扫描

3. AI 分析采样代码，生成三类产物
   │  详见 `references/artifact-template.md`
   │
   ├── style.md — 代码风格约定
   ├── structure.md — 代码结构与模块关系（含代码质量问题）
   └── glossary.md — 项目术语表

4. 写入 .rdd/context/ + 生成 meta.json
   │
   └── 返回产物路径

5. 如检测到代码质量问题，输出提醒：
   ⚠️ 检测到 [N] 个代码质量问题：
   - [高] [type] at [file] — [description]

   如需重构，可输入 /RDD-PM 将其立为需求。
```

### 新鲜度检测

通过 `meta.json` 记录的文件快照与当前项目对比：

```json
{
  "generated_at": "ISO 8601",
  "sampled_files": ["src/index.ts", "src/services/user.ts", ...],
  "file_hashes": {
    "src/index.ts": "md5hash"
  },
  "artifacts": ["style", "structure", "glossary"]
}
```

检测方式：
1. 对比 `sampled_files` 与当前项目——文件被删除或新增了关键目录 → 建议重新生成
2. 对比 `file_hashes` 与当前文件 MD5 → 有变化 → 建议重新生成
3. 全部通过 → 产物新鲜

### 产物存储

```
.rdd/
└── context/
    ├── meta.json       # 元数据（生成时间、文件快照、hash）
    ├── style.md        # 代码风格约定
    ├── structure.md    # 代码结构与模块关系
    └── glossary.md     # 项目术语表
```

---

## 代码坏味道检测

在生成 `structure.md` 时同步检测。基于采样代码分析，不逐文件扫描。

| 类型 | 检测方式 | 示例 |
|------|---------|------|
| 过长函数 | 采样文件中函数体行数 > 50 | `processOrder()` 跨 120 行 |
| 深层嵌套 | 缩进层级 > 4 | 条件嵌套过深 |
| 重复模式 | 多个文件中出现相似代码结构 | 多处相同校验逻辑 |
| God 文件 | 单文件行数 > 500 且职责混杂 | `utils.ts` 混合了 5 种不相关功能 |
| 分层违反 | UI 层直接访问数据库 | 组件内直接 SQL 查询 |

---

## 与其他 RDD Skill 的集成

### CTO 集成

```
CTO Phase 1 "理解项目现状"：
  加载 rdd-engine → 执行 /context → 读取产物
  → 基于产物（style + structure + glossary）理解项目
  → 后续代码引用通过 Read/Grep/Glob 获取

CTO 领域设计能力不足或涉及特定框架/协议/行业规范：
  加载 rdd-engine → 执行 /skill-manager query
  → 获取推荐 skill、使用理由、需要读取的 SKILL.md
  → 将领域指导融入方案
```

### DEV 集成

```
DEV 任务分析阶段：
  加载 rdd-engine → 执行 /context → 读取产物
  → 基于 style.md 遵循代码风格
  → 基于 glossary.md 理解项目术语
  → 代码定位通过 Grep/Glob 获取

DEV 实现任务涉及非通用领域：
  加载 rdd-engine → 执行 /skill-manager query
  → 获取推荐 skill 和领域实现要点
  → 在拆分计划和最终汇报中记录使用了哪个 skill
```

### UX 集成

```
UX Phase 1 "项目视觉上下文"：
  加载 rdd-engine → 执行 /context → 读取产物
  → 基于 structure.md 了解项目结构
  → 基于 style.md 了解编码约定

UX 遇到特定风格/媒介/交互范式：
  加载 rdd-engine → 执行 /skill-manager query
  → 获取相关设计 skill
  → 用该 skill 的方法论辅助产出 ux/{name}.md
```

### EVAL 集成

```
EVAL 评价涉及特定领域，或某角色评分为 C/D：
  加载 rdd-engine → 执行 /skill-manager feedback
  → 将低分原因、涉及角色、使用过的 skill、改进建议回传给 skill-manager
  → skill-manager 更新评分和迭代建议
```

---

## `/skill-manager` — 领域 Skill 统一管理

skill-manager 是 rdd-engine 的能力管理层。角色不再各自维护分散的 skill 查找逻辑，而是向 skill-manager 描述"我需要什么领域能力"，由 skill-manager 返回该用哪个 skill、为什么用、如何用，以及是否需要自动发现新 skill。

完整规则见 `references/skill-manager.md`。

### 支持动作

| 动作 | 功能 | 典型调用方 |
|------|------|------------|
| `query` | 根据角色、任务和领域标签匹配可用 skill | CTO/DEV/UX/EVAL |
| `discover` | 本地无匹配时调用 find-skills 查找新 skill | skill-manager 内部自动触发 |
| `record-use` | 记录某次需求实际使用了哪些 skill | CTO/DEV/UX/EVAL 完成阶段 |
| `feedback` | 接收 EVAL 低分或用户差评，分析 skill 是否有效 | EVAL / 用户显式反馈 |
| `review` | 查看 skill 评分、使用次数、问题模式和迭代建议 | 用户或任一角色 |

### 产物存储

```
.rdd/
└── skill-manager/
    ├── index.md        # 已管理 skill 清单、可见角色、领域标签、评分
    ├── usage-log.md    # 每次需求使用 skill 的记录
    └── feedback.md     # EVAL/用户反馈与迭代建议
```

---

## 路由规则

1. **明确指令** `/context` → 执行项目上下文产物管理
2. **明确指令** `/skill-manager` → 执行 skill 匹配、发现、记录或反馈处理
3. **RDD Skill 关键阶段** → 按自动触发规则执行（CTO Phase 1、DEV 任务分析、UX Phase 1、EVAL 低分反馈）
4. **无法确定** → 向用户确认

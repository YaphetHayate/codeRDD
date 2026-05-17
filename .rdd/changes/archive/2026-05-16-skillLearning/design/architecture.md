---
requirement_id: skillLearning
priority: 高
depends_on: []
blocks: []
analysis_date: 2026-05-16
status: confirmed
role: cto
tech_stack:
  - Claude Code Skill (prompt-based)
  - Markdown (artifact storage)
---

# Skill 学习能力与项目上下文系统 — 设计文档

## 一、需求概述

为 RDD 各角色增加项目自适应能力。通过新建 `rdd-engine` skill 提供项目理解产物的懒加载生成与管理，CTO/DEV/UX 按需调用获取项目上下文。同时为 UX/CTO 增加能力自评机制，为 CTO 增加代码结构质量把关。

## 需求覆盖映射

| 需求 ID | 本文档负责范围 | 对应章节 |
|---------|--------------|---------|
| 需求 1 | rdd-engine 新 skill 设计、项目上下文懒加载、代码坏味道检测 | 二、三 |
| 需求 2 | UX/CTO 能力自评 + find-skill 补齐 | 四 |
| 需求 3 | CTO 代码结构质量把关 | 五 |
| 目录迁移 | RDD/ → .rdd/ 目录结构变更 | 六 |

---

## 二、rdd-engine Skill 设计

### 2.1 定位

rdd-engine 是 RDD 工作流的**共享基础设施层**。不做决策（那是 PM/CTO/DEV/UX/QA 的事），只做项目理解与知识服务——所有"需要做但不知道该谁做"的项目级工作统一委派给它。

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

### 2.2 核心指令

| 指令 | 功能 | 典型场景 |
|------|------|----------|
| `/context` | 生成/读取项目理解产物 | CTO Phase 1、DEV 任务分析、UX Phase 1 |

未来可扩展的指令（不在本次实现范围）：
- `/check` — 运行项目级自动化检查（如风格一致性检查）
- `/diff` — 对比项目变更前后的上下文差异

### 2.3 `/context` 指令详解

#### 执行流程

```
/context 执行流程：

1. 检查 .rdd/context/ 是否存在完整产物
   │
   ├── 存在 → 检查新鲜度
   │   ├── 新鲜（meta.json 记录的文件快照与当前项目一致）→ 直接读取
   │   └── 过期（文件有变更）→ 提示用户，用户选择重新生成或继续使用
   │
   └── 不存在 → 进入步骤 2

2. 采样项目代码（轻量，不全量扫描）
   ├── 用 Glob 扫描项目根目录结构（排除 node_modules/.git 等）
   ├── 按目录分布采样 3-8 个代表性源码文件
   └── 采样依据：manifest 中的关键文件、各模块的入口文件

3. AI 分析采样代码，生成三类产物
   ├── style.md — 代码风格约定
   ├── structure.md — 代码结构与模块关系
   └── glossary.md — 项目术语表

4. 写入 .rdd/context/ 并返回产物路径
```

#### 采样策略

rdd-engine 不使用 Python 脚本建索引，而是直接通过 Glob/Grep/Read 采样代码。采样策略：

```
采样流程：

1. Glob 获取项目顶层目录结构（1 层深度）
   → 排除标准噪声目录：node_modules, .git, dist, build, __pycache__, vendor

2. 识别主要源码目录
   → 按常见模式识别：src/, lib/, app/, cmd/, internal/, pkg/ 等
   → 如果项目根目录直接是源码（无 src/ 子目录），直接扫描根目录

3. 每个源码目录采样 1-2 个文件
   → 优先采样：入口文件、配置文件、核心业务文件
   → 采样来源：目录名 + 常见入口文件名（index.*, main.*, app.*）

4. 总采样量控制在 3-8 个文件
   → 大项目（10+ 目录）每目录 1 个
   → 小项目（< 10 目录）每目录 1-2 个
```

#### 新鲜度检测

```
新鲜度检测：

.rdd/context/meta.json 记录：
{
  "generated_at": "ISO 8601",
  "sampled_files": ["src/index.ts", "src/utils/helpers.ts", ...],
  "file_hashes": { "src/index.ts": "md5hash", ... }
}

检测方式：
1. 对比 meta.json 中的 sampled_files 与当前项目文件
2. 如果文件被删除或新增了关键目录 → 建议重新生成
3. 对比 file_hashes 与当前文件的 MD5 → 如果有变化 → 建议重新生成
4. 如果所有检查通过 → 产物新鲜
```

### 2.4 产物内容规范

**style.md — 代码风格约定：**

```markdown
# 代码风格约定

## 命名规范
- 文件命名：[convention + 示例]
- 类/接口命名：[convention + 示例]
- 函数/方法命名：[convention + 示例]
- 变量命名：[convention + 示例]
- 常量命名：[convention + 示例]

## 代码格式
- 缩进：[tabs/spaces + 大小]
- 行宽限制：[limit]
- 引号风格：[single/double]
- 尾逗号：[有/无]
- 分号：[有/无]

## 项目特定约定
- [从代码中观察到的项目特有模式]

## 风格不一致处
| 偏离点 | 主流风格 | 例外位置 | 建议 |
|--------|---------|---------|------|

---
生成时间：[timestamp]
```

**structure.md — 代码结构与模块关系：**

```markdown
# 代码结构

## 目录布局
[精简版目录树，去掉噪声目录]

## 模块职责
| 模块 | 路径 | 职责 | 关键文件 |
|------|------|------|---------|

## 模块依赖关系
[基于代码分析的模块间调用关系描述]

## 代码质量问题
| 类型 | 位置 | 描述 | 严重程度 |
|------|------|------|---------|
| [smell] | [file] | [description] | 高/中/低 |

---
生成时间：[timestamp]
```

**glossary.md — 项目术语表：**

```markdown
# 项目术语表

## 模块术语
| 术语/模块名 | 含义 | 对应路径 | 核心能力 |
|------------|------|---------|---------|

## 业务概念
| 术语 | 含义 | 出现场景 |
|------|------|---------|

---
生成时间：[timestamp]
```

**meta.json — 产物元数据：**

```json
{
  "generated_at": "ISO 8601",
  "sampled_files": ["path/to/file1", "path/to/file2"],
  "file_hashes": { "path/to/file1": "md5hash" },
  "artifacts": ["style", "structure", "glossary"]
}
```

### 2.5 代码坏味道检测

在生成 `structure.md` 时同步检测代码坏味道。基于采样代码分析，不逐文件扫描：

| 类型 | 检测方式 | 示例 |
|------|---------|------|
| 过长函数 | 采样文件中函数体行数 > 50 | `processOrder()` 跨 120 行 |
| 深层嵌套 | 缩进层级 > 4 | 条件嵌套过深 |
| 重复模式 | 多个文件中出现相似代码结构 | 多处相同校验逻辑 |
| God 文件 | 单文件行数 > 500 且职责混杂 | `utils.ts` 混合了 5 种不相关功能 |
| 分层违反 | UI 层直接访问数据库 | 组件内直接 SQL 查询 |

检测到后：
1. 记录到 `structure.md` 的"代码质量问题"章节
2. 向用户输出提醒：
```
⚠️ 检测到 [N] 个代码质量问题：
- [高] [type] at [file] — [description]

如需重构，可输入 /RDD-PM 将其立为需求。
```

---

## 三、CTO/DEV 懒加载集成

### 3.1 CTO SKILL.md 改动

**改动位置**：`rdd-cto/SKILL.md` "理解项目现状"章节

```
改造前：
  Phase 1 → 执行 /understand（code-compass）→ 获得项目上下文摘要

改造后：
  Phase 1 → 加载 rdd-engine skill → 执行 /context
    ├── .rdd/context/ 产物存在且新鲜 → 读取产物
    └── 产物不存在 → rdd-engine 自动采样代码 + 生成产物 → 读取

  后续代码引用（如文件路径、类名、函数签名）通过 Read/Grep/Glob 获取，
  不再依赖 code-compass 的索引查询。
```

**同步改动**：CTO SKILL.md 中所有引用 code-compass 的地方更新为 rdd-engine。

### 3.2 DEV SKILL.md 改动

**改动位置**：`rdd-dev/SKILL.md` "任务分析阶段"章节

```
改造前：
  任务分析 → 执行 /understand + /navigate（code-compass）

改造后：
  任务分析 → 加载 rdd-engine skill → 执行 /context
    ├── 产物存在 → 读取 style.md（遵循代码风格）+ glossary.md（理解术语）
    └── 产物不存在 → rdd-engine 生成 → 读取

  代码定位（原 /navigate 功能）改用 Claude Code 原生 Grep/Glob 工具。
```

### 3.3 UX SKILL.md 改动

**改动位置**：`rdd-ux/SKILL.md` "Phase 1：项目视觉上下文理解"章节

```
改造前：
  Phase 1 → 执行 /understand（code-compass）

改造后：
  Phase 1 → 加载 rdd-engine skill → 执行 /context
    ├── 产物存在 → 读取 style.md + structure.md
    └── 产物不存在 → rdd-engine 生成 → 读取
```

---

## 四、角色能力自评与 Skill 补齐（需求 2，L1）

### 4.1 CTO SKILL.md 改动

**改动位置**：`rdd-cto/SKILL.md` Phase 1.2 "领域识别与 Skill 匹配"

在现有流程前增加一步能力自评：

```
1.2 领域识别与 Skill 匹配（改造后）：

1.2.1 能力自评
  │
  ├── 通用工程需求（架构、API、数据模型等）→ 能力充足，跳到 1.2.2
  │
  └── 涉及特定领域（图形算法、加密协议、特定框架等）
      → 自评：是否有足够领域知识设计方案？
      ├── 有 → 跳到 1.2.2
      └── 不确定/无 → 调用 find-skill 搜索相关 skill
          ├── 找到 → 读取 skill SKILL.md，融入设计
          └── 未找到 → 向用户说明能力缺口

1.2.2 领域识别与 Skill 匹配（现有流程不变）
```

**自评约束**：只对非通用工程需求做自评，避免每个任务都触发 find-skill。

### 4.2 UX SKILL.md 改动

**改动位置**：`rdd-ux/SKILL.md` Phase 1 之前新增 Phase 0.5

```
Phase 0.5: 设计能力自评（新增）
  │
  ├── 评估：
  │   - 设计类型（Web UI / 移动端 / 游戏界面 / 数据可视化 / 其他）
  │   - 风格要求（企业级 / 像素风 / 3D / 极简主义 / 其他）
  │
  ├── 能力覆盖（七步设计法适用）→ 进入 Phase 1
  │
  └── 能力不覆盖 → 调用 find-skill
      ├── 找到 → 集成 skill 方法论辅助设计
      └── 未找到 → 向用户说明：
          "本次设计涉及 [领域]，缺少专业方法论。
           建议补充对应 skill 或提供参考。"
```

---

## 五、CTO 代码结构质量把关（需求 3，L1）

### 5.1 CTO SKILL.md 改动

**改动位置**：`rdd-cto/SKILL.md` Phase 1 "理解项目现状"，在读取产物后、分级分析前插入。

```
3. 代码结构质量评估（新增步骤）
   │
   ├── 读取 structure.md 中的"代码质量问题"章节
   │
   ├── 评估每个问题性质：
   │   ├── 局部坏味道（单个函数过长、命名不规范等）
   │   │   → 记录备忘，不阻塞
   │   │
   │   └── 系统性问题（循环依赖、模块职责混乱、架构模式不一致）
   │       → 暂停，向用户报告
   │
   └── 系统性问题提醒模板：
       "⚠️ 发现代码结构系统性问题：
        1. [问题] — [描述]
        建议：输入 /RDD-PM 将重构立为需求，或明确'继续设计'"

4. 用户选择继续 → 进入分级分析
```

**区分标准：**

| 维度 | 局部坏味道 | 系统性问题 |
|------|-----------|-----------|
| 影响范围 | 单个文件/函数 | 跨模块，影响整体架构 |
| 对设计影响 | 不影响方案 | 影响模块划分、依赖关系、技术选型 |

---

## 六、目录迁移：RDD/ → .rdd/

### 6.1 迁移范围

所有 RDD 角色的产出物目录从 `RDD/` 变更为 `.rdd/`。

```
迁移前：                        迁移后：
RDD/                            .rdd/
├── changes/                    ├── changes/
│   └── archive/                │   └── archive/
│       └── ...                 │       └── ...（PM/CTO/DEV/UX/QA 产物不变）
└── ...                         ├── context/
                                │   ├── meta.json    # rdd-engine 产物
                                │   ├── style.md
                                │   ├── structure.md
                                │   └── glossary.md
                                └── bug-register.md  # DEV bug register（如有）
```

### 6.2 需要更新的文件

所有引用 `RDD/` 路径的 SKILL.md 文件：

| 文件 | 引用位置 | 改动 |
|------|---------|------|
| `rdd-pm/SKILL.md` | 归档路径白名单 | `RDD/changes/archive/...` → `.rdd/changes/archive/...` |
| `rdd-cto/SKILL.md` | 输入处理、归档路径 | 同上 |
| `rdd-dev/SKILL.md` | 输入处理、bug register 路径 | `RDD/changes/bug-register.md` → `.rdd/bug-register.md` |
| `rdd-ux/SKILL.md` | 输入处理、归档路径 | 同 PM/CTO |
| `rdd-qa/SKILL.md` | 输入处理、归档路径 | 同 PM/CTO |
| `rdd-dev/references/bug-register-template.md` | bug register 路径 | 同上 |

### 6.3 历史归档兼容

已有历史归档在 `RDD/changes/archive/` 下，不需要迁移。新旧目录均可访问。新归档统一写入 `.rdd/changes/archive/`。

---

## 七、skill-registry.md 更新

移除 code-compass 条目，新增 rdd-engine 条目：

```markdown
### rdd-engine
- **领域标签**：项目理解, 代码风格, 项目结构, 项目术语, 代码分析, 上下文
- **能力概述**：RDD 工作流共享基础设施，提供项目理解产物的懒加载生成与管理
- **使用方式**：CTO/DEV/UX 在关键阶段自动调用 /context 获取项目上下文
```

---

## 八、新增文件清单

```
rdd-engine/                     # 新 skill 目录
├── SKILL.md                    # skill 定义（包含 /context 指令、懒加载流程、产物规范）
└── references/
    ├── context-guide.md        # /context 指令详细执行指南
    └── artifact-template.md    # 三类产物的内容模板
```

---

## 九、实现步骤清单

按依赖顺序排列，DEV 按此顺序执行：

1. **创建 rdd-engine skill** — 新建 `rdd-engine/SKILL.md` 和 `references/` 目录，实现 `/context` 指令
2. **更新 CTO SKILL.md** — 替换 code-compass 引用为 rdd-engine，新增能力自评步骤（1.2.1），新增质量评估步骤
3. **更新 DEV SKILL.md** — 替换 code-compass 引用为 rdd-engine
4. **更新 UX SKILL.md** — 替换 code-compass 引用为 rdd-engine，新增能力自评（Phase 0.5）
5. **更新 QA SKILL.md** — 路径迁移 RDD/ → .rdd/
6. **更新 PM SKILL.md** — 路径迁移 RDD/ → .rdd/
7. **更新 skill-registry.md** — 移除 code-compass，新增 rdd-engine
8. **迁移 bug-register 路径** — `rdd-dev/references/bug-register-template.md` 中的路径引用

步骤 2-5 可并行（各改各的 SKILL.md，无文件交叉）。

## 十、实现优先级建议

建议开发顺序：步骤 1 → 步骤 2/3/4（并行）→ 步骤 5/6/7/8（并行）

步骤 1 是核心，必须先完成。步骤 2-4 依赖步骤 1 的 SKILL.md 作为参考。步骤 5-8 是路径替换，独立于步骤 1-4。

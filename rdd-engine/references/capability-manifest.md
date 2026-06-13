# 引擎能力清单

> **定位**：rdd-engine 所有可用能力的权威清单。各 RDD 角色通过本文档发现和使用引擎能力。
> **维护规则**：引擎新增/变更能力时，只需更新本文件（+ `engine.ps1`），各角色自动发现，无需逐个更新 SKILL.md。

---

## 能力速查

| 能力 | -Type | CLI 命令 | 触发场景 |
|------|-------|---------|---------|
| 代码探索（全局缓存） | `explore` | `engine.ps1 -Type explore -Query "..."` | 需要理解项目代码、定位模块/函数/依赖关系时 |
| 项目上下文生成 | `context` | `engine.ps1 -Type context -Query "..."` | 首次进入项目、需要了解代码风格/结构/术语时 |
| 技能发现 | `skills` | `engine.ps1 -Type skills -Query "..."` | 需要匹配领域 skill（如像素画、特定框架）时 |
| 项目工具委托 | `tools` | `engine.ps1 -Type tools -Query "..."` | 需要处理项目级通用任务（依赖检查等）时 |

---

## 各能力详解

### 1. 代码探索（explore）— 全局缓存

**这是最常用的能力。任何角色需要理解项目代码时，优先使用此能力。**

**核心机制：先查缓存 → 未命中则探索 → 写入缓存**

1. engine 读取 `.rdd/exploration/index.json`，语义匹配 Query 意图
2. 命中 → 检查涉及文件的 SHA-256 哈希，文件未变则直接返回缓存内容（无需重复探索）
3. 未命中 / 文件已变 → 启动 `explore` 子 agent 探索代码，产物写入 `.rdd/exploration/artifacts/`，更新 index
4. 返回探索结果摘要 + 产物正文

**调用示例：**

```powershell
# 分析认证模块
engine.ps1 -Type explore -Query "分析认证模块的中间件链和 Token 刷新机制"

# 理解数据库访问层
engine.ps1 -Type explore -Query "分析项目 ORM 层的 Repository 模式和事务管理"

# 定位特定功能实现
engine.ps1 -Type explore -Query "搜索并分析用户权限检查的实现逻辑"
```

**缓存特性：**
- 全局共享：PM 探索过的结果，CTO/DEV/QA 无需重新探索
- 自动失效：涉及文件变更后 SHA-256 不匹配，自动重新探索
- 索引文件：`.rdd/exploration/index.json`，产物目录：`.rdd/exploration/artifacts/`

> 完整执行流程见 `rdd-engine/references/exploration-guide.md`

---

### 2. 项目上下文生成（context）

生成/读取项目级理解产物（代码风格、模块结构、项目术语），产物缓存于 `.rdd/context/`。

**调用示例：**

```powershell
engine.ps1 -Type context -Query "分析项目结构，生成 code style 和 module structure"
```

> 参考指南：`rdd-engine/references/context-guide.md`、`rdd-engine/references/artifact-template.md`

---

### 3. 技能发现（skills）

根据关键词查询 `rdd-engine/skill-registry.md`，返回匹配的领域 skill 列表及使用建议。

**调用示例：**

```powershell
engine.ps1 -Type skills -Query "像素画 sprite 动画"
```

---

### 4. 项目工具委托（tools）

委托子 agent 处理项目级通用任务（如依赖安全性检查、构建脚本执行等）。当前预留，后续扩展。

**调用示例：**

```powershell
engine.ps1 -Type tools -Query "检查项目依赖安全性"
```

---

## 流转命令（rdd-flow.ps1）

除能力委托外，engine 还提供阶段流转命令，用于角色切换和上下文交接：

| Command | CLI 命令 | 说明 |
|---------|---------|------|
| `next` | `rdd-flow.ps1 -Command next` | 汇总当前有哪些角色有待处理任务 |
| `start` | `rdd-flow.ps1 -Command start -Role <PM\|CTO\|UX\|DEV\|QA>` | 为指定角色生成启动 prompt + handoff packet |
| `handoff` | `rdd-flow.ps1 -Command handoff -Role <DEV>` | 为指定角色生成最小交接包 |
| `validate` | `rdd-flow.ps1 -Command validate -Role <DEV>` | 校验指定角色是否有可执行任务 |

> 完整规则见 `rdd-engine/references/handoff-guide.md`

---

## 共享协议

所有 RDD 角色共享以下协议（定义在 `rdd-engine/references/` 下）：

| 协议 | 文件 | 说明 |
|------|------|------|
| 驳回协议 | `rejection-protocol.md` | 角色间正式驳回上游文档的标准流程 |
| 交接包规则 | `handoff-guide.md` | 最小上下文交接的构建规则 |

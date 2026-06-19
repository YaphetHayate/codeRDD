# 引擎能力清单

> **定位**：rdd-engine 所有可用能力的权威清单。各 RDD 角色通过本文档发现和使用引擎能力。
> **维护规则**：引擎新增/变更能力时，只需更新本文件（+ `explore.ps1`），各角色自动发现，无需逐个更新 SKILL.md。

---

## 能力速查

| 能力 | -Type | CLI 命令 | 触发场景 |
|------|-------|---------|---------|
| 代码探索（全局缓存） | `explore` | `explore.cmd -Type explore -Query "..."` | 需要理解项目代码、定位模块/函数/依赖关系时 |

---

## 能力详解

### 代码探索（explore）— 全局缓存

**这是引擎核心能力。任何角色需要理解项目代码时，优先使用此能力。**

**核心机制：先查缓存 → 未命中则探索 → 写入缓存**

1. engine 读取 `.rdd/exploration/index.json`，语义匹配 Query 意图
2. 命中 → 检查涉及文件的 SHA-256 哈希，文件未变则直接返回缓存内容（无需重复探索）
3. 未命中 / 文件已变 → 启动 `explore` 子 agent 探索代码，产物写入 `.rdd/exploration/artifacts/`，更新 index
4. 返回探索结果摘要 + 产物正文

**调用示例：**

```powershell
# 分析认证模块
explore.cmd -Type explore -Query "分析认证模块的中间件链和 Token 刷新机制"

# 理解数据库访问层
explore.cmd -Type explore -Query "分析项目 ORM 层的 Repository 模式和事务管理"

# 定位特定功能实现
explore.cmd -Type explore -Query "搜索并分析用户权限检查的实现逻辑"
```

**缓存特性：**
- 全局共享：PM 探索过的结果，CTO/DEV/QA 无需重新探索
- 自动失效：涉及文件变更后 SHA-256 不匹配，自动重新探索
- 索引文件：`.rdd/exploration/index.json`，产物目录：`.rdd/exploration/artifacts/`

> 完整执行流程见 `rdd-engine/references/exploration-guide.md`

---

## 流转命令（rdd-flow.ps1）

除代码探索外，engine 还提供阶段流转命令，用于角色切换和上下文交接：

| Command | CLI 命令 | 说明 |
|---------|---------|------|
| `next` | `rdd-flow.cmd -Command next` | 汇总当前有哪些角色有待处理任务 |
| `start` | `rdd-flow.cmd -Command start -Role <PM\|CTO\|UX\|DEV\|QA>` | 为指定角色生成启动 prompt + handoff packet |
| `handoff` | `rdd-flow.cmd -Command handoff -Role <DEV>` | 为指定角色生成最小交接包 |
| `validate` | `rdd-flow.cmd -Command validate -Role <DEV>` | 校验指定角色是否有可执行任务 |

> 完整规则见 `rdd-engine/references/handoff-guide.md`

---

## 共享协议

所有 RDD 角色共享以下协议（定义在 `rdd-engine/references/` 下）：

| 协议 | 文件 | 说明 |
|------|------|------|
| 角色交接协议 | `transition-guide.md` | 上游完成产物后的 4 步交接流程、下游三入口识别、双场景（self-driven/app-driven）模式检测 |
| 驳回协议 | `rejection-protocol.md` | 角色间正式驳回上游文档的标准流程 |
| 交接包规则 | `handoff-guide.md` | 最小上下文交接的构建规则 |

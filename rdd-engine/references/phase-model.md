# 阶段路由模型（Phase Routing Model）

> **定位**：交付编排（delivery-bridge / rdd-flow）阶段白名单模型的**唯一权威文档**。定义阶段划分、`phase` 字段、阶段切换与回退语义。实施前先读本文件；本文与代码不一致时以代码为准，并回改本文。
>
> **状态**：**已实施**（批 A/B/C 全部落地；实现落点见 §7）。
>
> **关联文档**：`task-routing.md`（路由协议）、`planner-guide.md`（桥接协议）、`transition-guide.md`（角色交接）、`handoff-guide.md`（交接包）。

---

## 1. 背景与缺口（历史，已由本模型修复）

修复前桥接的 stage 模型是**线性角色链**（`$script:StageOrder` / `$script:StageNext`，现为保守 legacy 兜底，`delivery-bridge.ps1:456-457`），存在三个缺口：

1. **顺序缺口**：`StageNext[CTO]=DEV` 钉死 CTO→DEV，无法表达 CTO→UX 的阶段内流转（`advance` 命令时代的历史问题；advance 已移除）。
2. **并行缺口**：旧 `Resolve-InitialStage` 对 `currentOwners=["CTO","UX"]` 只取第一个角色建链头，UX 无节点 → UX 工作静默丢失。**已修**：`Resolve-InitialGroup`（`delivery-bridge.ps1:1961`）返回整个并行组。
3. **树分裂缺口**：多链头并行时各自 graft 下游会分裂出重复节点。**已修**：settle 阶段感知汇聚（§5.2）。

根因：桥接把"角色"物化成了**物理节点**，而 `currentOwners` 的"并行集合"语义在树层没有对应物。本模型给树层补上了「阶段 = 白名单集合」的对应物。

## 2. 设计目标与约束

- 目标：`currentOwners` 多 pipeline 角色时，每个角色各建节点、各自独立工作；**阶段内全部 settle 后才推进到下一阶段**（汇聚）。
- 约束：单 owner 任务行为与旧模型**逐字节一致**（回归保证；test-phase-model 钉死）。
- 约束：`currentOwners` 永远**阶段纯净**（白名单制），禁止 `["UX","DEV"]` 这类跨阶段中间态。
- 约束：`phase` 是**显式存储值**，不从 `currentOwners` 反向推断（避免隐性成本）。
- 约束：`lifecycle`（`active`/`deprecated`/`completed`）三值语义**不动**。

## 3. 核心模型：白名单阶段

阶段是全序的，阶段内角色是白名单集合（**两处定义逐字节同步维护**：`rdd-flow.ps1:119-126`、`delivery-bridge.ps1:464-469`）：

```powershell
$script:PhaseRoles = @{
    "REQ"    = @("PM")
    "DESIGN" = @("CTO", "UX", "QA")   # QA = 测试用例设计（测试先行）
    "IMPL"   = @("DEV")
    "VERIFY" = @("QA")                # QA = 验收执行
}
$script:PhaseNext = @{ "REQ"="DESIGN"; "DESIGN"="IMPL"; "IMPL"="VERIFY"; "VERIFY"=$null }
```

```
REQ ──> DESIGN ──> IMPL ──> VERIFY ──> 完成
         CTO ∥ UX ∥ QA     DEV         QA(验收)
         （阶段内并行）
```

**关键决策记录**：

| 决策 | 结论 | 理由 |
|------|------|------|
| QA 归属 | QA 同时入 DESIGN（测试用例设计）和 VERIFY（验收执行） | 测试先行：测试用例是设计产物 |
| 并行定义 | 阶段是全局领域事实，不是 task 临时 join | 消除 join 对象的 settled 持久化 |
| `phase` 落点 | 独立字段，**不**融入 `lifecycle` | 生死（lifecycle）与推进（phase）正交 |
| 流转命令 | 统一 `set-route`，`advance` 已移除（2026-10） | `set-route` 是整组替换，天然表达阶段原子切换 |
| 阶段进度追踪 | `remaining` 从 `currentOwners` 现推，不持久化 settled | `phase` + `PhaseRoles` 已足够判断"阶段内还有谁" |

## 4. 字段定义

### 4.1 task.json（tasks[]）

```json
{
  "id": 1,
  "title": "...",
  "requirement": "...",
  "currentOwners": ["CTO", "UX"],
  "phase": "DESIGN",
  "designDocs": [],
  "currentWorker": [],
  "remark": "",
  "lifecycle": "active"
}
```

- `phase`：`"REQ" | "DESIGN" | "IMPL" | "VERIFY"`，`lifecycle=active` 时必有值；`completed`/`deprecated` 时 `phase=null`。
- 不变量：`currentOwners ⊆ PhaseRoles[phase]`（白名单硬约束，`Resolve-TaskPhase` 颁布侧校验 / `check` flow 侧校验）。

### 4.2 bridge.json（tasks[taskId]）

`stages: { stage: nodeId }` 保持单值映射——并行组各 stage 占不同 key，天然不冲突。**无** join 字段，阶段进度从 `currentOwners` + `phase` 现推。

## 5. 流转语义

### 5.1 `set-route`（`rdd-flow.ps1:2055`，跨阶段必带 `-Phase`）

```
set-route -To <角色集> [-Phase <阶段>]
```

- **缺省 `-Phase`**（阶段内收窄）：校验 `-To ⊆ PhaseRoles[当前phase]`，`phase` 不变；越界报 `SET_PHASE_REQUIRED`（`rdd-flow.ps1:197`）。
- **显式 `-Phase`**（阶段切换/回退）：`currentOwners` 与 `phase` 原子更新，校验 `-To ⊆ PhaseRoles[-Phase]`。
- **歧义角色**（QA 同属 DESIGN/VERIFY）跨阶段流转未传 `-Phase` → `SET_PHASE_REQUIRED`（`rdd-flow.ps1:219`）。

### 5.2 阶段切换时序（settle 汇聚，`Invoke-BridgeSettle` `delivery-bridge.ps1:7646`）

以 `["CTO","UX"]`（DESIGN）为例：

| 步骤 | 树侧 | flow 侧 | graft |
|------|------|---------|-------|
| CTO settle | 树 settle CTO | `set-route -To "UX"` | **不 graft**（`remaining=[UX]`） |
| UX settle | 树 settle UX | `set-route -To "DEV" -Phase "IMPL"` | graft 唯一 DEV 节点 |

阶段内串行 `["CTO"]` + `-To UX`：CTO settle → `set-route -To "UX"`（阶段内，phase 不变）→ **立即 graft UX**（阶段内下游）。

wake 形状注：阶段推进 graft 的锚点是任务的需求容器（`Invoke-GraftNextStage` `delivery-bridge.ps1:7893`，槽位唯一、redo/reset 复用同槽）；legacy 形状沿用链头链尾。

## 6. 回退语义（rollback，`Invoke-BridgeRollback` `delivery-bridge.ps1:6963`）

```
rollback -RunId <id> -NodeId <失败节点> -Reason <理由>
```

- **回退目标是引擎自动推导的**（一阶段回退 + 变更地图重叠路由）：`Get-RollbackContext` 从 phase 链反推目标阶段/角色集（`delivery-bridge.ps1:6688` 记 `target_roles`/`target_phase`），并按 design_maps 重叠把 IMPL 失败路由回重叠设计角色（如 CTO+UX）。**不接收**规划者手填 `-To`/`-Phase`——显式多阶段回退走 `replan`。
- 剪枝失败节点 → 重建目标角色集节点 → flow 侧 set-route 回退 → 自动重推。
- 回退到需求阶段：走 `reject -To PM`。

## 7. 实现落点（原「脚本改动清单」，已全部实施）

### 7.1 rdd-flow.ps1（flow 层 = 路由权威）

| 点 | 位置 |
|----|------|
| `PhaseRoles` / `PhaseNext` 常量 | `:119-126` |
| `set-route -Phase` | `Invoke-SetRoute` `:2055`（`SET_PHASE_REQUIRED` `:197/:219`） |
| `check` 校验 | `Invoke-Check` `:2606`（`PHASE_LIFECYCLE_CONFLICT` `:281`） |
| `reopen`（不消费 `-Phase`，阶段由 `-To` 推导） | `Invoke-Reopen` `:2555` |
| 读面透出 `phase` | `show`/`handoff`/`next`/`claim` |

### 7.2 delivery-bridge.ps1（bridge 层 = 编排）

| 点 | 位置 |
|----|------|
| `PhaseRoles` / `PhaseNext` 常量（与 flow 同步） | `:464-469` |
| `Resolve-TaskPhase`（`PHASE_INVALID` `:1990` / `PHASE_OWNER_MISMATCH` `:1995` / `GROUP_DIVERGENT_NEXT` `:2002`） | `:1980` |
| `Resolve-InitialGroup`（并行组建树） | `:1961` |
| `Invoke-BridgeSettle`（阶段感知汇聚 graft） | `:7646` |
| `Invoke-GraftNextStage`（阶段推进 graft，wake/legacy 双形状） | `:7893` |
| `Invoke-BridgeRollback`（自动推导回退） | `:6963` |

### 7.3 文档

`task-routing.md`（schema + set-route -Phase）、`transition-guide.md`（角色速查按阶段对齐）、`planner-guide.md`（命令签名）、`planner-scenarios.md`（阶段链模型）、`handoff-guide.md`（phase 透出）。

## 8. 错误码（全部已实现）

| 错误码 | 触发 | 位置 |
|--------|------|------|
| `PHASE_OWNER_MISMATCH` | `currentOwners` 不 ⊆ `PhaseRoles[phase]` | `delivery-bridge.ps1:1995` |
| `PHASE_INVALID` | `phase` 枚举非法 | `delivery-bridge.ps1:1990` |
| `PHASE_LIFECYCLE_CONFLICT` | `completed/deprecated` 但 `phase≠null`，或反之 | `rdd-flow.ps1:281` |
| `SET_PHASE_REQUIRED` | 阶段切换/含歧义角色（QA）未传 `-Phase` | `rdd-flow.ps1:197/:219` |
| `GROUP_DIVERGENT_NEXT` | 并行组推进目标阶段不唯一 | `delivery-bridge.ps1:2002` |

## 9. 回归测试点（test-phase-model.ps1 全覆盖）

1. 单 owner 全链 `["CTO"]→["DEV"]→["QA"]→complete`：行为逐字节一致。
2. 并行 `["CTO","UX"]`：建 2 节点 → CTO settle 不 graft → UX settle 才 graft 唯一 DEV。
3. 阶段内串行 `["CTO"]` + `-To UX`：CTO settle 立即 graft UX。
4. QA 测试先行 `["CTO","UX","QA"]`：QA settle 只收窄，不触发阶段切换。
5. 回退：剪枝失败节点 → 自动推导重建目标角色集 → set-route 回退。
6. `check`：`["UX","DEV"]` 跨阶段 → `PHASE_OWNER_MISMATCH`。
7. 旧归档无 `phase`：读面 `phase=null`，settle/check 保守降级不 crash。
8. 依赖多锚点：下游 `depends_on` 上游 CTO+UX 两节点，全 terminal 才解锁。

## 10. 实施状态（原「实施顺序」，3 批均已验收）

1. **批 A（flow 层）**：✅ 常量 + `phase` schema + `set-route -Phase` + `check` 校验 + 读面透出。
2. **批 B（bridge 编排）**：✅ `Resolve-InitialGroup` + 并行组建树 + settle 阶段感知 + graft 汇聚。
3. **批 C（回退 + 展示 + 文档）**：✅ rollback 自动推导回退 + `∥` 展示 + 文档同步。

## 11. 迁移与兼容

- 旧归档无 `phase`：读面返回 `phase=null`；`settle`/`check` 对 null 保守降级（不 crash）。
- `lifecycle` 三值消费零改动。
- `advance` 命令已移除（2026-10）：全部流转统一 `set-route -Phase`；桥接 legacy 尾部改道 set-route（歧义目标 QA 显式 `-Phase VERIFY`）。

# 阶段路由模型（Phase Routing Model）

> **定位**：交付编排桥接（delivery-bridge）的阶段白名单模型的**唯一权威设计文档**。定义阶段划分、`phase` 字段、阶段切换与回退语义，以及脚本/文档的精确改动清单。实施前先读本文件，与本文件冲突时以本文件为准。
>
> **状态**：已评审设计，待实施（交付 PM/PLANNER）。
>
> **关联文档**：`task-routing.md`（路由协议）、`planner-guide.md`（桥接协议）、`transition-guide.md`（角色交接）、`handoff-guide.md`（交接包）。

---

## 1. 背景与缺口

当前桥接的 stage 模型是**线性角色链**（`delivery-bridge.ps1:181-182`）：

```powershell
$script:StageOrder = @("CTO", "UX", "DEV", "QA")
$script:StageNext = @{ "CTO" = "DEV"; "UX" = "DEV"; "DEV" = "QA"; "QA" = $null }
```

这带来三个缺口：

1. **顺序缺口**：`StageNext[CTO]=DEV` 钉死 CTO→DEV，无法表达 `task-routing.md:327` 允许的 `advance -From CTO -To UX`（CTO→UX 顺序流转）。
2. **并行缺口**：`Resolve-InitialStage`（`:1242`）对 `currentOwners=["CTO","UX"]` 只取第一个角色建链头，UX 无节点 → UX 工作静默丢失。
3. **树分裂缺口**：若强行多链头，`settle` 无条件 `graft` 下游（`:2631-2637`）+ `stages[stage]=node` 单值覆盖（`:821`），会导致两个并行分支各自 graft 一个 DEV，产生两个 DEV 节点。

根因：桥接把"角色"物化成了**物理节点**，而 `currentOwners` 的"并行集合 + advance 去重"语义在树层没有对应物。

## 2. 设计目标与约束

- 目标：`currentOwners` 多 pipeline 角色时，每个角色各建链头节点、各自独立工作；**阶段内全部 settle 后才推进到下一阶段**（汇聚）。
- 约束：单 owner 任务行为与现状**逐字节一致**（回归保证）。
- 约束：`currentOwners` 永远**阶段纯净**（白名单制），禁止 `["UX","DEV"]` 这类跨阶段中间态。
- 约束：`phase` 是**显式存储值**，不从 `currentOwners` 反向推断（避免隐性成本）。
- 约束：`lifecycle`（`active`/`deprecated`/`completed`）三值语义**不动**。

## 3. 核心模型：白名单阶段

阶段是全序的，阶段内角色是白名单集合：

```powershell
# ⚠ 与 rdd-flow.ps1 同步维护
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
| `phase` 落点 | 独立字段，**不**融入 `lifecycle` | 生死（lifecycle）与推进（phase）正交；融入需改 58 处 lifecycle 消费 + 强制迁移反向推断 |
| 流转命令 | 统一 `set-route`，`advance` 退出主路径 | `set-route` 已是整组替换，天然表达阶段原子切换；`advance` 的单角色替换是跨阶段态元凶 |
| 阶段进度追踪 | `remaining` 从 `currentOwners` 现推，不持久化 settled | `phase` + `PhaseRoles` 已足够判断"阶段内还有谁" |

## 4. 字段定义

### 4.1 task.json（tasks[] 新增）

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
- 不变量：`currentOwners ⊆ PhaseRoles[phase]`（白名单硬约束）。

### 4.2 bridge.json（tasks[taskId] 沿用，不新增 join 字段）

`stages: { stage: nodeId }` 保持单值映射——并行组各 stage 占不同 key，天然不冲突。**不需要** join 字段，阶段进度从 `currentOwners` + `phase` 现推。

## 5. 流转语义

### 5.1 `set-route` 扩展

```
set-route -To <角色集> [-Phase <阶段>]
```

- **缺省 `-Phase`**（阶段内收窄）：校验 `-To ⊆ PhaseRoles[当前phase]`，`phase` 不变。例：`set-route -To "UX"`（CTO 完成，阶段仍 DESIGN）。
- **显式 `-Phase`**（阶段切换/回退）：`currentOwners` 与 `phase` 原子更新，校验 `-To ⊆ PhaseRoles[-Phase]`。例：`set-route -To "DEV" -Phase "IMPL"`。

### 5.2 阶段切换时序

以 `["CTO","UX"]`（DESIGN）为例：

| 步骤 | 树侧 | flow 侧 | graft |
|------|------|---------|-------|
| CTO settle | 树 settle CTO | `set-route -To "UX"` | **不 graft**（`remaining=[UX]`） |
| UX settle | 树 settle UX | `set-route -To "DEV" -Phase "IMPL"` | graft 唯一 DEV 节点 |

阶段内串行 `["CTO"]` + `-To UX`：CTO settle → `set-route -To "UX"`（阶段内，phase 不变）→ **立即 graft UX**（阶段内下游）。

## 6. 回退语义

```
rollback -RunId <id> -NodeId <失败节点> -To <回退角色集> -Phase <回退阶段> -Reason <理由>
```

- 剪枝失败节点 → 重建 `-To` 集合的角色节点 → `set-route -To -Phase` → 自动重推。
- 回退目标由**规划者显式指定**（`-To` + `-Phase`），替代现有"从 parent 推导前一角色"。
- 示例：DEV 发现设计问题 → `rollback -NodeId <DEV节点> -To "CTO+UX" -Phase "DESIGN"`。
- 回退到需求阶段：`-To "PM" -Phase "REQ"`（或走现有 `reject -To PM`）。

## 7. 脚本改动清单

### 7.1 rdd-flow.ps1（flow 层 = 路由权威）

| 点 | 位置 | 改动 |
|----|------|------|
| 常量 | 顶部 | 加 `PhaseRoles` / `PhaseNext` |
| schema | tasks[] | 加 `phase` 字段 |
| `set-route` | `Invoke-SetRoute` | 加 `-Phase` 参数 + 白名单校验 |
| `init`/`add-task` | — | 初始化 `phase` |
| `check` | `Invoke-Check` | 加 `phase` 枚举校验 + `currentOwners ⊆ PhaseRoles[phase]` + lifecycle/phase 一致性 |
| 读面 | `show`/`handoff`/`next`/`claim` | 透出 `phase` |
| `advance` | `Invoke-Advance` | 不改实现，文档标注退场 |

### 7.2 delivery-bridge.ps1（bridge 层 = 编排）

| 点 | 位置 | 改动 |
|----|------|------|
| 常量 | 顶部 | 加 `PhaseRoles` / `PhaseNext`（同步注释） |
| `Resolve-InitialStage` | `:1242` | → `Resolve-InitialGroup`：返回 `currentOwners ∩ pipeline roles` 数组 |
| `promulgate` 建树 | `:1697-1734` | 每任务对组内每个角色 graft 链头（挂 `n1`）；`depends_on` 指向上游**所有**链头 |
| `settle` | `Invoke-BridgeSettle` | **核心**：读 `phase` → 算 `remaining` → 改调 `set-route` → `remaining` 非空不 graft，空才 graft |
| `rollback` | `Invoke-BridgeRollback` | 加 `-To`/`-Phase`，重建角色集合节点 |
| `overview`/`conclude` | — | 并行组 `∥` 展示，阶段间 `→` |

### 7.3 文档

`task-routing.md`（schema + set-route -Phase + 并行节重写）、`transition-guide.md`（角色速查按阶段对齐）、`planner-guide.md`（阶段链模型重写 + 命令签名）、`handoff-guide.md`（phase 透出）。

## 8. 错误码

| 错误码 | 触发 |
|--------|------|
| `PHASE_OWNER_MISMATCH` | `currentOwners` 不 ⊆ `PhaseRoles[phase]` |
| `PHASE_INVALID` | `phase` 枚举非法 |
| `PHASE_LIFECYCLE_CONFLICT` | `completed/deprecated` 但 `phase≠null`，或反之 |
| `SET_PHASE_REQUIRED` | 阶段切换/含歧义角色（QA）未传 `-Phase` |
| `GROUP_DIVERGENT_NEXT` | 并行组推进目标阶段不唯一（第一版报错，不支持 fan-out） |

## 9. 回归测试点

1. 单 owner 全链 `["CTO"]→["DEV"]→["QA"]→complete`：行为逐字节一致。
2. 并行 `["CTO","UX"]`：建 2 链头 → CTO settle 不 graft → UX settle 才 graft 唯一 DEV。
3. 阶段内串行 `["CTO"]` + `-To UX`：CTO settle 立即 graft UX。
4. QA 测试先行 `["CTO","UX","QA"]`：QA settle 只收窄，不触发阶段切换。
5. 回退 `rollback -To "CTO+UX" -Phase "DESIGN"`：剪枝 IMPL → 重建 CTO+UX → set-route 回 DESIGN。
6. `check`：`["UX","DEV"]` 跨阶段 → `PHASE_OWNER_MISMATCH`。
7. 旧归档无 `phase`：读面 `phase=null`，settle/check 保守降级不 crash。
8. 依赖多锚点：下游 `depends_on` 上游 CTO+UX 两节点，全 terminal 才解锁。

## 10. 实施顺序（3 批可独立验收）

1. **批 A（flow 层）**：常量 + `phase` schema + `set-route -Phase` + `check` 校验 + 读面透出。
2. **批 B（bridge 编排）**：`Resolve-InitialGroup` + 多链头建树 + settle 阶段感知 + graft 汇聚。
3. **批 C（回退 + 展示 + 文档）**：`rollback -ToPhase` + `∥` 展示 + 四份文档同步。

## 11. 迁移与兼容

- 旧归档无 `phase`：读面返回 `phase=null`；`settle`/`check` 对 null 保守降级（不 crash），`migrate` 可后续一次性补 `phase`。
- `lifecycle` 三值消费（58 处）零改动。
- `advance` 命令保留（向后兼容），新流转统一 `set-route -Phase`。

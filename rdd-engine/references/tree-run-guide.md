# Tree-Run 协议（tree-run-guide）

> **定位**：树形长程任务循环引擎能力的**唯一权威协议**。Manager 循环协议、worker 派发契约、恢复流程、审计与保留策略均以本文档为准。
>
> **适用场景**：任意角色遇到长程任务（根因调查、批量审计、深度评估等需要多轮"派发 → 回写 → 再规划"的场景）时，启动一次 tree-run。
>
> **与现有体系的关系**：与 task.json 平铺流转、explore 探索链**三重正交**（目录 / 命令 / 数据零共享）。tree-run 不替代 rdd-flow 的需求流转——它是角色在执行某条任务**期间**可用的执行引擎。

---

## 双接口分权

引擎提供两个物理隔离的 CLI：

| 面 | CLI | 使用者 | 能做什么 | 不能做什么 |
|----|-----|--------|---------|-----------|
| **管理面** | `tree-run.cmd` | Manager 会话（发起长程任务的角色） | start / graft / prune / settle / conclude / round-start / round-end / status / resume | 不产生证据回调（不采证） |
| **消费面** | `tree-leaf.cmd` | 子代理 worker | next / claim / report / status（本节点） | 物理上无法改动树结构（CLI 硬编码字段白名单，只更新本节点 claim/status 字段） |

> 调用约定与 rdd-flow 相同：`$rdd` 指向 rdd-engine 目录（见 `task-routing.md`），输出 UTF-8 JSON。

---

## 运行数据布局（文件为唯一权威）

```
.rdd/tree-runs/<run-id>/            # gitignore，不入版本库
├── manifest.json                    # 预算 / 终局 / 引用范围(-RefRoots)
├── state/
│   ├── tree.json                    # 权威树快照（写前 .bak + 写后 read-back；损坏自动回退 .bak）
│   ├── ledger.jsonl                 # 回写账本（只追加；坏行隔离到 .corrupt，不静默丢行）
│   ├── ledger.jsonl.corrupt         # 隔离区（保留原始坏行文本）
│   └── round-log.jsonl              # 轮日志（只追加；每轮 start/end 两行制）
├── .lock                            # 每 run 一把互斥锁（所有写原语；持有者崩溃后 60s 可被接管）
└── report/
    ├── rounds/round-NN.md           # 每轮人类可读快照
    └── final-report.md              # 结案报告（三种终局均产出）
```

**节点生命周期**：`pending → claimed → reported → done`（或任一状态 `→ pruned`，剪枝级联整棵子树）。
已 `reported` 的节点**永远不可被重新消费**——claim 只接受 `pending`；这是"中断恢复不重复消费"的机械保证。

**回写账本条目**（`ledger.jsonl` 每行一条）：

```json
{
  "entry_id": "L1",
  "round": 1,
  "node_id": "n2",
  "worker": "w1-db",
  "reported_at": "2026-09-02T09:10:00Z",
  "callback": { "node_id": "...", "verdict": "...", "confidence": 0.85, "summary": "...", "citations": [{"ref": "...", "locator": "..."}], "next_suggestion": "...", "extras": {} },
  "validation": { "status": "valid|downgraded|invalid", "notes": [], "confidence_clamped": false, "range_check_failures": [], "verdict_downgraded": false }
}
```

---

## Manager 循环协议

一次标准 tree-run 的完整循环：

```
1. start          创建运行（根目标节点 n1 + 预算 + 引用范围）
2. round-start    开第 1 轮
3. graft          在选定父节点下颁布子任务节点（首批通常挂在 n1 下）
4. 派发 worker    按下方「worker 派发模板」扇出子代理，每个 worker：
   next → claim → 干活（读证据）→ report（结构化回调）
5. 整合           阅读 ledger 本轮新条目，逐个决策：
   - 证实/有用        → settle（reported → done）
   - 证伪/无关        → prune（附理由，级联子树）
   - 需要下探         → graft 新子节点
6. round-end       收轮（落 round-NN.md 快照，记录 summary/decision）
7. 判定            达标 → conclude achieved（锚点节点须 done）
                   预算尽 → conclude budget_exhausted（引擎校验预算确实耗尽）
                   空间尽 → conclude space_exhausted（树无 pending+claimed）
   否则 → 回到 2
```

**轮次纪律**：树生长（graft）与消费（claim/report）都只发生在**开放轮内**。每轮恰好一对 `round-start` / `round-end`；漏收轮会被 `status` 体检暴露为"悬挂轮"。

**预算**（start 时声明，引擎机械强制）：

- `max_rounds`：轮数上限，超出时 `round-start` 报 `ROUNDS_EXCEEDED`
- `node_width`：单父节点子节点数上限，超出时 graft 报 `WIDTH_EXCEEDED`
- `max_nodes`：全树节点数上限，超出时 graft 报 `NODES_EXCEEDED`
- "达标即停"类智能判定**留给 Manager**——引擎只管机械终局前置

**终局**（三种均为正常终结，均产出 final-report.md）：

| 终局 | 机械前置 | 语义 |
|------|---------|------|
| `achieved` | `-AnchorNodeId` 指向的节点 status=done | 最终目标达成 |
| `budget_exhausted` | 轮数或节点数预算确实耗尽 | 诚实报告当前最佳进展，**不伪造完成** |
| `space_exhausted` | 树无 pending 且无 claimed 节点 | 任务空间耗尽 |

预算未耗尽时调用 `budget_exhausted` 会被引擎拒绝（`BUDGET_NOT_EXHAUSTED`）——诚实性由引擎背书。

---

## 回调契约（引擎强制）

worker 的 `report` 必须提交固定核心 schema（引擎机械校验，领域字段进 `extras` 透传不校验）：

| 字段 | 类型 | 约束 |
|------|------|------|
| `node_id` | string | 必填，须为本人 claimed 的节点 |
| `verdict` | enum | 必填：`done` / `failed` / `inconclusive` |
| `confidence` | number | 必填 ∈ [0,1]；越界**截断**并记入 notes |
| `summary` | string | 必填非空 |
| `citations` | array | 必填：`[{ref, locator}]`；ref 必须落在声明范围内 |
| `next_suggestion` | string | 必填（允许空串） |
| `extras` | object | 可选，领域字段透传 |

**引用范围（RefRoots）**：start 时声明允许引用的 repo 内根路径（`,` 分隔；`.` 表示全仓库）。report 时的机械判定：

- ref 是 repo 相对路径且落在某根下 → 采
- ref 是相对根的路径（如 `plane/logs/x.log`）或带 repo 根前缀的全路径 → 引擎**机械归一**后采（rca-poc 教训下沉）
- 含 `..` 穿越 → 拒
- 其余 → **拒采**并原样记入 `range_check_failures`（不静默丢弃）

**降级规则**（不破坏运行）：

1. 结构不符（缺字段 / verdict 非法 / citations 非数组…）→ 账本记 `invalid` 条目，节点**不流转**（保持 claimed，可重报或 `-Steal` 回收）
2. confidence 越界 → 截断 + 记 notes → `downgraded`
3. 越界 citation 拒采 → 记 `range_check_failures` → `downgraded`
4. 拒采后无有效 citation 且 verdict=done → **降级为 inconclusive** → `downgraded`

**协议误用**（非回调质量问题）直接报错退出、不记账：重复 claim、非持有者 report、对非 claimed 节点 report、无开放轮操作等。

---

## worker 派发模板

给每个子代理的派发 prompt 模板（宿主扇出时逐 worker 填充）：

```text
你是 tree-run「<run-id>」的 worker，标签 <worker-label>。按以下硬顺序工作：

1. 领任务（一次只领一个节点）：
   & "$rdd\scripts\tree-leaf.cmd" -Command claim -RunId <run-id> -NodeId <node-id> -Worker <worker-label>
   失败（NODE_NOT_CLAIMABLE）说明该节点已被他人领走：改用 -Command next 重新挑一个 pending 节点。

2. 执行节点 task 描述的调查任务。证据只允许读取以下范围（越界引用会被引擎拒采）：
   <ref-roots 列表>

3. 回写（结构化回调，写入临时 JSON 文件后用 -CallbackFile 提交，避免命令行转义问题）：
   {
     "node_id": "<node-id>",
     "verdict": "done|failed|inconclusive",
     "confidence": 0.0~1.0,
     "summary": "<结论与证据链摘要>",
     "citations": [ { "ref": "<范围内文件路径>", "locator": "<行号/时间窗等定位>" } ],
     "next_suggestion": "<建议的下一步下探方向>",
     "extras": { <领域字段自由透传> }
   }
   & "$rdd\scripts\tree-leaf.cmd" -Command report -RunId <run-id> -Worker <worker-label> -CallbackFile <cb.json>

4. 回读输出的 validation 字段：invalid 时按 reasons 修正后重新 report；downgraded 属正常入账。
   你不能也不需要修改树结构——claim/report 之外的任何树变更都由 Manager 负责。
```

## 宿主 workflow 扇出模板

子代理的拉起是宿主能力（如 DSH `workflow` 的 `agent()` 扇出）。Manager 每轮：

1. `tree-leaf.cmd -Command next -RunId <id>` 拿 pending 节点清单
2. 对每个节点组装上述派发模板（`workflow` 的 `pipeline`/`parallel` 钩子逐节点扇出 worker）
3. 全部 worker 返回后，`tree-run.cmd -Command status -RunId <id>` 查看本轮回写与校验状态
4. 按「Manager 循环协议」第 5 步整合

```javascript
// workflow 扇出示意（每轮调用一次；结果汇入 Manager 整合）
await pipeline(pendingNodes, [
  async (node) => agent(renderDispatchPrompt(runId, node), { label: `w-${node.id}` }),
]);
```

---

## 恢复流程（任意一轮中断后）

新 Manager 会话凭状态文件恢复，三步：

1. **定位断点**：`tree-run.cmd -Command resume -RunId <id>`
   - 报告悬挂轮（round-start 未配 round-end）→ 继续派发剩余 pending，或直接 round-end 收轮
   - 报告下一轮编号；预算尽则提示走 budget_exhausted
   - 列出 claimed（可能死 claim，用 `tree-leaf claim -Steal` 回收）与 reported（待 settle）
2. **核对健康**：`tree-run.cmd -Command status -RunId <id>` 全量体检
   - read-back / tree.json 损坏自动从 .bak 回退（丢失窗口 ≤ 最近一个写原语）
   - ledger 坏行自动隔离到 `.corrupt`（原行保留）
   - 悬挂轮、未 settle 节点、死 claim 全部显式列出
3. **继续循环**：从 Manager 循环协议的对应步骤续跑。已回写节点不会重复消费（claim 只接受 pending；reported/done 永不可再 claim）。

**锁**：所有写原语互斥（每 run 一把 `.lock`）。争用时引擎独占重试 10s 后报 `LOCK_TIMEOUT`——调用方退避重试即可；持有者崩溃遗留的锁 60s 后被自动接管。

---

## 命令速查

### 管理面（tree-run.cmd）

```powershell
# 创建运行（RefRoots 必填；预算默认 5 轮 / 宽 4 / 30 节点）
& "$rdd\scripts\tree-run.cmd" -Command start -RunId <id> -Goal "<长程目标>" -RefRoots "<repo相对路径,...>" -CreatedBy <角色> [-MaxRounds 5] [-NodeWidth 4] [-MaxNodes 30] [-Notes "..."]

# 开轮 / 收轮（收轮自动落 report/rounds/round-NN.md）
& "$rdd\scripts\tree-run.cmd" -Command round-start -RunId <id>
& "$rdd\scripts\tree-run.cmd" -Command round-end -RunId <id> -Summary "<本轮整合摘要>" -Decision "<continue|conclude...>"

# 颁布子任务（-TasksFile 推荐，避免中文/引号经命令行转义；数组元素 {title, task, note?}）
& "$rdd\scripts\tree-run.cmd" -Command graft -RunId <id> -Parent <nodeId> -TasksFile <path>

# 剪枝（级联子树，理由必填，入审计）
& "$rdd\scripts\tree-run.cmd" -Command prune -RunId <id> -NodeId <nodeId> -Reason "<证伪/放弃理由>"

# 确认整合（reported → done）
& "$rdd\scripts\tree-run.cmd" -Command settle -RunId <id> -NodeId <nodeId> [-Note "<整合结论>"]

# 终结（三终局；achieved 需 -AnchorNodeId 且该节点 done）
& "$rdd\scripts\tree-run.cmd" -Command conclude -RunId <id> -Outcome achieved -AnchorNodeId <nodeId> -Summary "<结案摘要>"
& "$rdd\scripts\tree-run.cmd" -Command conclude -RunId <id> -Outcome budget_exhausted -Summary "<诚实进展>"
& "$rdd\scripts\tree-run.cmd" -Command conclude -RunId <id> -Outcome space_exhausted -Summary "<...>"

# 体检 / 恢复
& "$rdd\scripts\tree-run.cmd" -Command status -RunId <id>
& "$rdd\scripts\tree-run.cmd" -Command resume -RunId <id>
```

### 消费面（tree-leaf.cmd）

```powershell
& "$rdd\scripts\tree-leaf.cmd" -Command next   -RunId <id> [-Limit 5]
& "$rdd\scripts\tree-leaf.cmd" -Command claim  -RunId <id> -NodeId <nodeId> -Worker <label> [-Steal]
& "$rdd\scripts\tree-leaf.cmd" -Command report -RunId <id> -Worker <label> -CallbackFile <path>   # -Callback 仅建议纯 ASCII 短串
& "$rdd\scripts\tree-leaf.cmd" -Command status -RunId <id> [-NodeId <nodeId>]
```

### 错误码约定

`0` 成功（含回调被拒收但已降级记账：`accepted=false`）；`1` 校验/前置失败（usage）；`2` 运行或节点不存在；`3` 锁超时/状态损坏（read-back 失败、tree.json 与 .bak 均不可解析）。

---

## 审计与保留

- **审计三件**：轮快照（round-NN.md）+ 结案报告（final-report.md）+ 账本（ledger.jsonl，含全部 invalid/downgraded 原始回调与越界引用记录）全部落在运行目录
- **版本库留痕**：`.rdd/tree-runs/` 整体 gitignore（与 `.rdd/changes/` 惯例一致）。需要入库的结论由 Manager 将结案摘要记入发起会话产物（如归档文档或探索缓存）
- **保留策略**：引擎不强制清理。建议：结案运行保留 final-report.md + rounds/ 供追溯，空间紧张时可删 state/*.bak 与 .corrupt（账本本体建议永久保留）
- **并发规模**：锁为每 run 粒度，worker 数量不受引擎限制；写原语均为秒级，10s 锁超时足以应对常规扇出

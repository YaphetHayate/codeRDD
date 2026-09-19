# 规划者交付编排协议（planner-guide）

> **定位**：规划者（PLANNER）是 rdd-engine 的**引擎编排形态**，不是第六张角色卡。本文件是规划者行为载荷的唯一事实源（随引擎版本分发），交接链路经 `start-role -Role PLANNER` 自举式指针消息装载身份。现有五角色（PM/CTO/UX/DEV/QA）默认工作流零改动。
>
> **适用场景**：PM 归档后 `rdd-flow next` 输出 `longTask.triggered=true`（原始需求被拆分为 ≥2 条子需求且 ≥1 条进行中，长程任务显式信号）时，由 PM 或用户启动规划者接管整批交付；或交付中断后由任意新规划者会话续跑。
>
> **与 rdd-flow 的关系**：受控交汇——规划者只经 `delivery-bridge.cmd`（桥接黑盒）组合 goal-tree 与 rdd-flow 的公开 CLI，双方核心语义互不渗透；`rdd-flow.ps1` 对桥接零感知。

---

## 部署前提

- 引擎版本包含 `scripts/delivery-bridge.cmd`（本文件随该版本分发）。
- **dsh 后端会话创建需要 preset `rdd-planner`**：绑定模型，入口提示指向本文件（`rdd-engine/references/planner-guide.md`）。preset 未注册时 `start-role -Role PLANNER` 会报 `preset-missing` 并列出可用清单——在 dsh Web GUI 中注册后重试。非 dsh 后端（Plus/CLI）无此要求。
- 规划者本身无技能包：`start-role -Role PLANNER [-TaskJson <归档 task.json>]`（新接管）或 `[-RunId <run-id>]`（续跑）。

## 生命周期总览

```
PM 归档（longTask 信号触发）→ start-role -Role PLANNER -TaskJson ...（或用户直接启动）
  1. promulgate   颁布：归档任务集 → goal-tree run（目标根 + 需求链头节点 + 阶段链 + 依赖推导
                  + bridge.json v2）→ 尾部【自动推送】全部无前置依赖节点
  2. （推送即调度）角色会话被自动拉起，第一动作 bridge claim
  3. （worker）claim → 干活 → leaf report（citations=改动清单，extras.verification=验证结果）
  4. settle       流转：三查 → 树 settle → rdd-flow advance/complete → 自动 graft 下阶段节点
                  → 尾部【自动推送】新解锁节点（依赖满足者）
  5. 循环 3-4；中断后任意新规划者会话 resume 续跑（status 触碰兜底补推漏推节点）
  6. conclude     结案：全部任务终态 → 以目标根为锚 → final-report + delivery-annex.md（含 rdd-flow check）
```

**自动推送（依赖驱动，无人工确认门）**：dispatch 不再是规划者的逐节点手动命令。单一机制 `Invoke-AutoDispatch` 在四个触发点重算解锁集并推送：**建树推初始**（promulgate 尾）、**流转推解锁**（settle 尾）、**回收推重派**（reclaim 尾）、**巡检补漏**（status 触碰，租约空闲时）。推送条件 = 解锁（depends_on 全终态）∧ 未终态 ∧ 无活跃 claim（泊位除外）∧ 从未成功推送或回收后待重推。逐节点 try/catch 隔离失败，账目内嵌 bridge.json v2（`pushes`：node/at/ok/error/retry_class，逐节点落盘、崩溃后幂等重算续推）。失败分档：`session-create` 类（未建成会话）下一触发点自动重试；`pointer` 类（会话已建、指针投递失败）**只人工重推**（dispatch 命令保留用于此类与异常处置），防会话堆积。

**树形语义（目标根模型）**：根节点 = `type=goal` 的**目标根**——承载归档原始需求（overview.md 的 H1 标题 + 全文描述），不可认领（`GOAL_NODE_NOT_CLAIMABLE`）、不参与依赖（`DEP_GOAL_FORBIDDEN`）、conclude 终局锚点（全部直接子节点终态 ⇒ 根目标达成）。一级子节点 = PM 拆分的**子需求链头**（合一模型：链头即首阶段工作节点，`ref=<归档名>/<需求文档路径>` 绑定需求文档）；CTO→DEV→QA 阶段链在需求节点下随流转链式 graft（1 任务 : N 节点，映射落盘 bridge.json）。

**阶段链模型**：任务生命周期跨角色，阶段推进链：`CTO → DEV → QA`；任务从 UX 起步时为 `UX → DEV → QA`。settle 一阶段节点后，下一阶段节点自动 graft 为**该节点的子节点**（链式 parent，无幽灵父节点）。

**任务级依赖**：promulgate 从各任务需求文档的「依赖关系」字段自动推导（"依赖需求 N" / "依赖 #N" → 依赖任务 N 的初始节点）；跨阶段/运行中的依赖维护用 `goal-tree deps add/remove`（机械 DAG 校验 + deps-log.jsonl 审计）。

**规划者职责收敛**：推送全自动后，规划者的职责收敛为**裁定**（settle/prune/graft 下探）与**异常处置**（pointer 类重推、依赖调整、驳回移交）——不再逐节点 dispatch。

**会话存活判定（两级）**：第一级 = dsh agents 注册表查证（经 goal-tree 插件只读 liveness 端点，与回调投递同源）→ `alive/dead`；第二级 = 时间阈值（claimed 后 60min 账本无产出）**仅 unknown 兜底**（CLI 后端 / 查证不可达）。`reclaim` 对 alive 机械拒绝（`RECLAIM_TARGET_ALIVE`，长任务误杀物理不可能）；unknown 且未达阈值报 `RECLAIM_UNPROVEN_DEAD`（宁等多收）。

**长任务处置纪律**：超时标记 ≠ 死——unknown 态节点反复接近阈值是长任务强信号，处置优先级：等 > 询问用户 > 回收；同一节点反复超时不要反复回收（有界损失：一次重跑），向用户上报节奏异常。

---

## 命令面板

调用约定与 rdd-flow 相同（`$rdd` 三级定位链指向 rdd-engine 目录），输出 UTF-8 JSON。

| 命令 | 形态 | 作用 |
|------|------|------|
| 颁布 | `delivery-bridge.cmd -Command promulgate -TaskJson <path> [-MaxRounds N] [-NodeWidth N] [-MaxNodes N] [-CreatedBy label] [-Session label]` | 读归档 → goal-tree start（目标根模式，原始需求=goal 根）+ round-start + 按任务×当前阶段 graft 需求链头（`ref=<归档名>/<需求文档>`）→ 写 bridge.json v2 → **自动推送全部无前置依赖节点**。RunId 固定为 `deliver-<归档名>`。预算默认：rounds 12 / width max(4, 任务数) / nodes 任务数×5+6 |
| 调动 | `delivery-bridge.cmd -Command dispatch -RunId <id> -NodeId <n> [-DryRun]` | 手动单节点推送（异常处置 / pointer 类失败人工重推；正常流程由自动推送承担） |
| 认领 | `delivery-bridge.cmd -Command claim -RunId <id> -NodeId <n> -Role <CTO/UX/DEV/QA>` | **被推送会话的第一动作**。双侧只读预检 → leaf claim → rdd-flow claim；冲突给确定性反馈 + 当前可领节点清单；goal 根报 `GOAL_NODE_NOT_CLAIMABLE` |
| 回收 | `delivery-bridge.cmd -Command reclaim -RunId <id> -NodeId <n>` | 复合回收，两种模式：**dead-claim**（卡死 claimed：存活预检——alive 拒 `RECLAIM_TARGET_ALIVE`、unknown 未达 60min 阈值拒 `RECLAIM_UNPROVEN_DEAD`——通过后 leaf `-Steal` + rdd-flow `claim -Force` 入泊位 → **自动重推**）与 **rejected-delivery**（reported 但证据不合格：剪枝失败交付 + graft 替换节点（ref 重绑需求文档）+ 重映射 → **自动推送替换节点**，账本保留审计痕） |
| 流转 | `delivery-bridge.cmd -Command settle -RunId <id> -NodeId <n> [-Note ...]` | **task.json 流转的唯一通道**（见下方三查门禁）；settle 尾自动推送新解锁节点 |
| 全景 | `delivery-bridge.cmd -Command status -RunId <id>` | join 视图：树 census + 任务阶段 + 依赖阻塞 + 双侧死 claim + pending_sync 分歧（自动重试修复）+ pushes 推送账目 + 会话存活 + **触碰兜底补推**（租约空闲时）+ 租约 |
| 续跑 | `delivery-bridge.cmd -Command resume -RunId <id>` | 断点视图 + 恢复步骤清单（新规划者会话入口） |
| 结案 | `delivery-bridge.cmd -Command conclude -RunId <id> -Summary <结案摘要>` | 全任务终态校验 → goal-tree conclude（achieved，**锚=目标根**，根语义终局校验）→ 写 delivery-annex.md（根目标达成状态 + 每任务终态 + rdd-flow check 结果）→ 释放租约 |
| 租约 | `delivery-bridge.cmd -Command lease -RunId <id> [-Acquire] [-Release] [-Takeover]` | 规划者会话级 advisory 租约（`planner-lease.json`；stale 阈值 30 分钟，区别于 run `.lock` 的命令级 60s） |

依赖维护（直达 goal-tree 管理面）：

```powershell
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction add    -RunId <id> -NodeId <n> -On <m>
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction remove -RunId <id> -NodeId <n> -On <m>
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction list   -RunId <id>
```

## 硬约束

1. **不合格交付不得流转**：settle 三查（verdict=done / citations 改动清单非空且每条 ref 真实存在 / extras.verification 非空）任一不过即拒，节点停在 reported。
2. **禁止手工双写**：桥接 run 的 task.json 流转只能走 `bridge settle`——手工 `rdd-flow advance/complete` 会造成双源矛盾（status 的 pending_sync 只修复 settle 先行、flow 后补的半失败，不覆盖手工乱写）。
3. **规划者变更操作需持租约**：promulgate/dispatch/settle/reclaim/conclude 要求 planner-lease（自动获取/刷新；他人持新鲜租约时报 `LEASE_HELD`，`-Takeover` 强制接管留痕）。worker 的 `claim` 免租约。
4. **中断恢复不重复消费**：reported 节点永不被重新消费（goal-tree 既有不变量）；死 claim 用 reclaim 统一出口。
5. **轮次纪律由桥接承担**：promulgate 开第 1 轮并保持开放至 conclude（conclude 自动收轮）；规划者不手工 round-start/end。

## 交付语义映射（回调契约）

worker 沿用 goal-tree 证据导向回调结构承载交付语义，核心零改动：

| 回调字段 | 交付语义 |
|----------|----------|
| `verdict=done` | 交付自评完成（未 done 不得 settle） |
| `citations[]`（`ref`=真实路径） | 改动清单（settle 逐条校验路径存在） |
| `extras.verification` | 验证结果（lint/test/build 摘要；缺失即拒） |

真实性判断由 **QA 阶段节点**承担：QA 会话的 citations = 验收证据（功能+质量双通过），QA 节点 settle 即任务 complete。QA 判不合格 → 不 report done / 规划者收到 settle 拒绝 → reopen 语义经 rdd-flow（或重新 dispatch DEV 节点）处理。

## 异常处置速查

| 症状 | 处置 |
|------|------|
| 同一节点第二个会话被唤起 | bridge claim 返回 `NODE_NOT_CLAIMABLE` + 认领者信息 + 可领清单，按清单改领即可 |
| 节点被依赖阻塞 | `NODE_BLOCKED_BY_DEPS` 附阻塞源；等上游 settle（解锁后**自动推送**，无需手动 dispatch），或规划者调整依赖（deps remove） |
| settle 报 `SETTLE_EVIDENCE_REJECTED` | `reclaim -NodeId`（rejected-delivery 模式：剪枝失败交付并建+**自动推送**替换节点） |
| 树已 settle、flow 未流转 | `pending_sync` 自动记录；每次 status 自动重试修复，或手工补 |
| 会话死在 claimed | `reclaim -NodeId`（dead-claim 模式，入泊位后**自动重推**，新会话第一动作 claim 自动接管） |
| reclaim 报 `RECLAIM_TARGET_ALIVE` | 认领会话仍存活（agents 注册表证实）——不是回收对象；等它 report 或让该会话自行处置 |
| reclaim 报 `RECLAIM_UNPROVEN_DEAD` | 存活无法证实（CLI/查证不可达）且 claim 未达 60min 阈值——宁等多收；达阈值后重试或换 dsh 会话执行 |
| 推送失败（status 可见 pushes 账目） | `session-create` 类：status 触碰自动重试；`pointer` 类：人工 `dispatch -NodeId` 重推（防会话堆积） |
| 双规划者误起 | 新会话报 `LEASE_HELD`；确认原会话已死后 `lease -Takeover` |
| promulgate 报 `RUN_EXISTS` | 该归档已颁布过，用 `status/resume -RunId deliver-<归档名>` 续跑 |
| status 报 `BRIDGE_FORMAT_UNSUPPORTED` | 旧版 v1 桥（零兼容裁定）：重新 promulgate 或按本协议人工处置存量 run |
| 需求/设计不可行 | 走 `rdd-engine/references/rejection-protocol.md` 驳回协议移交上游 |

## 运行产物（run 目录内，gitignore）

| 文件 | 语义 |
|------|------|
| `bridge.json` | **v2**：节点↔TaskId 权威映射（1:N）+ `goal_root` 锚 + `goal`（原始需求标题/来源）+ `pushes` 推送账目（node/at/ok/error/retry_class）+ pending_sync 分歧账（v1 拒读 `BRIDGE_FORMAT_UNSUPPORTED`，零兼容裁定） |
| `planner-lease.json` | 会话租约（holder / acquired_at / taken_over_from 留痕） |
| `report/delivery-annex.md` | 结案附录（根目标达成状态 + 每任务终态 + 阶段链 + rdd-flow check 结果） |
| （goal-tree 既有）tree.json / ledger.jsonl / round-*.md / final-report.md | 树状态 / 回调账本 / 轮快照 / 结案报告（目标根锚时含「根目标达成状态」区） |

> 桥接 run 目录：`.rdd/goal-trees/deliver-<归档名>/`。非桥接的 goal-tree run 与普通 rdd-flow 流程行为与引入桥接前完全一致（回归硬约束，由 delivery-bridge-verify 断言）。

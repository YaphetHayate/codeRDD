# Manager 交付编排协议（manager-guide）

> **定位**：Manager 是 rdd-engine 的**引擎编排形态**，不是第六张角色卡。本文件是 Manager 行为载荷的唯一事实源（随引擎版本分发），交接链路经 `start-role -Role MANAGER` 自举式指针消息装载身份。现有五角色（PM/CTO/UX/DEV/QA）默认工作流零改动。
>
> **适用场景**：PM 归档后任务集较重（多需求、多角色、需并行/依赖编排）时，由 PM 或用户启动 Manager 接管整批交付；或交付中断后由任意新 Manager 会话续跑。
>
> **与 rdd-flow 的关系**：受控交汇——Manager 只经 `delivery-bridge.cmd`（桥接黑盒）组合 goal-tree 与 rdd-flow 的公开 CLI，双方核心语义互不渗透；`rdd-flow.ps1` 对桥接零感知。

---

## 部署前提

- 引擎版本包含 `scripts/delivery-bridge.cmd`（本文件随该版本分发）。
- **dsh 后端会话创建需要 preset `rdd-manager`**：绑定模型，入口提示指向本文件（`rdd-engine/references/manager-guide.md`）。preset 未注册时 `start-role -Role MANAGER` 会报 `preset-missing` 并列出可用清单——在 dsh Web GUI 中注册后重试。非 dsh 后端（Plus/CLI）无此要求。
- Manager 本身无技能包：`start-role -Role MANAGER [-TaskJson <归档 task.json>]`（新接管）或 `[-RunId <run-id>]`（续跑）。

## 生命周期总览

```
PM 归档（较重）→ start-role -Role MANAGER -TaskJson ...（或用户直接启动）
  1. promulgate   颁布：归档任务集 → goal-tree run（任务×阶段节点 + 依赖推导 + bridge.json）
  2. dispatch     调动：为节点开角色会话（start-role 投递链路，角色会话第一动作 bridge claim）
  3. （worker）claim → 干活 → leaf report（citations=改动清单，extras.verification=验证结果）
  4. settle       流转：三查 → 树 settle → rdd-flow advance/complete → 自动 graft 下阶段节点
  5. 循环 2-4；中断后任意新 Manager 会话 resume 续跑
  6. conclude     结案：全部任务终态 → final-report + delivery-annex.md（含 rdd-flow check）
```

**阶段链模型**：任务生命周期跨角色，桥接按 **任务×阶段** 建节点（1 任务 : N 节点，映射落盘 bridge.json）。阶段推进链：`CTO → DEV → QA`；任务从 UX 起步时为 `UX → DEV → QA`。settle 一阶段节点后，下一阶段节点自动 graft 为**该节点的子节点**（链式 parent，无幽灵父节点）。

**任务级依赖**：promulgate 从各任务需求文档的「依赖关系」字段自动推导（"依赖需求 N" / "依赖 #N" → 依赖任务 N 的初始节点）；跨阶段/运行中的依赖维护用 `goal-tree deps add/remove`（机械 DAG 校验 + deps-log.jsonl 审计）。

---

## 命令面板

调用约定与 rdd-flow 相同（`$rdd` 三级定位链指向 rdd-engine 目录），输出 UTF-8 JSON。

| 命令 | 形态 | 作用 |
|------|------|------|
| 颁布 | `delivery-bridge.cmd -Command promulgate -TaskJson <path> [-MaxRounds N] [-NodeWidth N] [-MaxNodes N] [-CreatedBy label]` | 读归档 → goal-tree start + round-start + 按任务×当前阶段 graft（`ref=<归档名>#<TaskId>`）→ 写 bridge.json。RunId 固定为 `deliver-<归档名>`。预算默认：rounds 12 / width max(4, 任务数) / nodes 任务数×5+6 |
| 调动 | `delivery-bridge.cmd -Command dispatch -RunId <id> -NodeId <n> [-DryRun]` | 为节点开对应阶段角色会话（内部走 start-role 投递链路；`-DryRun` 只预演） |
| 认领 | `delivery-bridge.cmd -Command claim -RunId <id> -NodeId <n> -Role <CTO/UX/DEV/QA>` | **被调动会话的第一动作**。双侧只读预检 → leaf claim → rdd-flow claim；冲突给确定性反馈 + 当前可领节点清单 |
| 回收 | `delivery-bridge.cmd -Command reclaim -RunId <id> -NodeId <n>` | 复合回收，两种模式：**dead-claim**（卡死 claimed：leaf `-Steal` + rdd-flow `claim -Force`，节点停入 "manager-reclaim" 泊位，下次 bridge claim 自动接管）与 **rejected-delivery**（reported 但证据不合格：剪枝失败交付 + graft 替换节点 + 重映射，账本保留审计痕） |
| 流转 | `delivery-bridge.cmd -Command settle -RunId <id> -NodeId <n> [-Note ...]` | **task.json 流转的唯一通道**（见下方三查门禁） |
| 全景 | `delivery-bridge.cmd -Command status -RunId <id>` | join 视图：树 census + 任务阶段 + 依赖阻塞 + 双侧死 claim + pending_sync 分歧（自动重试修复）+ 租约 |
| 续跑 | `delivery-bridge.cmd -Command resume -RunId <id>` | 断点视图 + 恢复步骤清单（新 Manager 会话入口） |
| 结案 | `delivery-bridge.cmd -Command conclude -RunId <id> -Summary <结案摘要>` | 全任务终态校验 → goal-tree conclude（achieved）→ 写 delivery-annex.md（每任务终态 + rdd-flow check 结果）→ 释放租约 |
| 租约 | `delivery-bridge.cmd -Command lease -RunId <id> [-Acquire] [-Release] [-Takeover]` | Manager 会话级 advisory 租约（`manager-lease.json`；stale 阈值 30 分钟，区别于 run `.lock` 的命令级 60s） |

依赖维护（直达 goal-tree 管理面）：

```powershell
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction add    -RunId <id> -NodeId <n> -On <m>
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction remove -RunId <id> -NodeId <n> -On <m>
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction list   -RunId <id>
```

## 硬约束

1. **不合格交付不得流转**：settle 三查（verdict=done / citations 改动清单非空且每条 ref 真实存在 / extras.verification 非空）任一不过即拒，节点停在 reported。
2. **禁止手工双写**：桥接 run 的 task.json 流转只能走 `bridge settle`——手工 `rdd-flow advance/complete` 会造成双源矛盾（status 的 pending_sync 只修复 settle 先行、flow 后补的半失败，不覆盖手工乱写）。
3. **Manager 变更操作需持租约**：promulgate/dispatch/settle/reclaim/conclude 要求 manager-lease（自动获取/刷新；他人持新鲜租约时报 `LEASE_HELD`，`-Takeover` 强制接管留痕）。worker 的 `claim` 免租约。
4. **中断恢复不重复消费**：reported 节点永不被重新消费（goal-tree 既有不变量）；死 claim 用 reclaim 统一出口。
5. **轮次纪律由桥接承担**：promulgate 开第 1 轮并保持开放至 conclude（conclude 自动收轮）；Manager 不手工 round-start/end。

## 交付语义映射（回调契约）

worker 沿用 goal-tree 证据导向回调结构承载交付语义，核心零改动：

| 回调字段 | 交付语义 |
|----------|----------|
| `verdict=done` | 交付自评完成（未 done 不得 settle） |
| `citations[]`（`ref`=真实路径） | 改动清单（settle 逐条校验路径存在） |
| `extras.verification` | 验证结果（lint/test/build 摘要；缺失即拒） |

真实性判断由 **QA 阶段节点**承担：QA 会话的 citations = 验收证据（功能+质量双通过），QA 节点 settle 即任务 complete。QA 判不合格 → 不 report done / Manager 收到 settle 拒绝 → reopen 语义经 rdd-flow（或重新 dispatch DEV 节点）处理。

## 异常处置速查

| 症状 | 处置 |
|------|------|
| 同一节点第二个会话被唤起 | bridge claim 返回 `NODE_NOT_CLAIMABLE` + 认领者信息 + 可领清单，按清单改领即可 |
| 节点被依赖阻塞 | `NODE_BLOCKED_BY_DEPS` 附阻塞源；等上游 settle，或 Manager 调整依赖（deps remove） |
| settle 报 `SETTLE_EVIDENCE_REJECTED` | `reclaim -NodeId`（rejected-delivery 模式：剪枝失败交付并建替换节点）→ 重新 dispatch 替换节点 |
| 树已 settle、flow 未流转 | `pending_sync` 自动记录；每次 status 自动重试修复，或手工补 |
| 会话死在 claimed | `reclaim -NodeId`（dead-claim 模式，节点入泊位）→ 重新 dispatch，新会话第一动作 claim 自动接管 |
| 双 Manager 误起 | 新会话报 `LEASE_HELD`；确认原会话已死后 `lease -Takeover` |
| promulgate 报 `RUN_EXISTS` | 该归档已颁布过，用 `status/resume -RunId deliver-<归档名>` 续跑 |
| 需求/设计不可行 | 走 `rdd-engine/references/rejection-protocol.md` 驳回协议移交上游 |

## 运行产物（run 目录内，gitignore）

| 文件 | 语义 |
|------|------|
| `bridge.json` | 节点↔TaskId 权威映射（1:N）+ pending_sync 分歧账 |
| `manager-lease.json` | 会话租约（holder / acquired_at / taken_over_from 留痕） |
| `report/delivery-annex.md` | 结案附录（每任务终态 + 阶段链 + rdd-flow check 结果） |
| （goal-tree 既有）tree.json / ledger.jsonl / round-*.md / final-report.md | 树状态 / 回调账本 / 轮快照 / 结案报告 |

> 桥接 run 目录：`.rdd/goal-trees/deliver-<归档名>/`。非桥接的 goal-tree run 与普通 rdd-flow 流程行为与引入桥接前完全一致（回归硬约束，由 delivery-bridge-verify 断言）。

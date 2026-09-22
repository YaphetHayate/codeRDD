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
  1. review      需求审查门（建树前，推荐）：逐条审视子需求独立性与合理性 → 三级处置
                  （通过 / 树内裁定 / 驳回回流）产出 ReviewFile，结论呈现用户（最终裁决权在用户）
  2. promulgate   颁布：归档任务集 → goal-tree run（目标根 + 需求链头节点 + 阶段链 + 依赖推导
                  + bridge.json v2；可选 -ReviewFile 消费审查结论——排除过滤/依赖覆盖/合并重定向）
                  → 尾部【自动推送】全部无前置依赖节点
  3. （推送即调度）角色会话被自动拉起，第一动作 bridge claim
  4. （worker）claim → 干活 → 完成即 leaf report 回调规划者（不 start-role 直交下游、
                  不启动 PLANNER——rdd-flow next 的 PLANNER 候选块对 worker 不适用，
                  误启收到 start-role 拒绝 PLANNER_RUN_ACTIVE；
                  回调携带产物位置：citations=改动清单，full_report=主产物文档指针，
                  extras.verification=验证结果）
  5. settle       流转：三查 → 树 settle → rdd-flow advance/complete → 自动 graft 下阶段节点
                  → 尾部【自动推送】新解锁节点（依赖满足者）；三查不过即拒（不合格交付不流转）——
                  同阶段重做走 reclaim，跨阶段回退走 rollback（剪枝+兄弟重建+reopen+自动重推）
  6. 循环 4-5；中断后任意新规划者会话 resume 续跑（status 触碰兜底补推漏推节点）
  7. conclude     结案：全部任务终态 → 以目标根为锚 → final-report + delivery-annex.md（含 rdd-flow check）
```

**自动推送（依赖驱动，无人工确认门）**：dispatch 不再是规划者的逐节点手动命令。单一机制 `Invoke-AutoDispatch` 在四个触发点重算解锁集并推送：**建树推初始**（promulgate 尾）、**流转推解锁**（settle 尾）、**回收推重派**（reclaim 尾）、**回退推重做**（rollback 尾）、**巡检补漏**（status 触碰，租约空闲时）。推送条件 = 解锁（depends_on 全终态）∧ 未终态 ∧ 无活跃 claim（泊位除外）∧ 从未成功推送或回收后待重推。逐节点 try/catch 隔离失败，账目内嵌 bridge.json v2（`pushes`：node/at/ok/error/retry_class，逐节点落盘、崩溃后幂等重算续推）。失败分档：`session-create` 类（未建成会话）下一触发点自动重试；`pointer` 类（会话已建、指针投递失败）**只人工重推**（dispatch 命令保留用于此类与异常处置），防会话堆积。

**树形语义（目标根模型）**：根节点 = `type=goal` 的**目标根**——承载归档原始需求（overview.md 的 H1 标题 + 全文描述），不可认领（`GOAL_NODE_NOT_CLAIMABLE`）、不参与依赖（`DEP_GOAL_FORBIDDEN`）、conclude 终局锚点（全部直接子节点终态 ⇒ 根目标达成）。一级子节点 = PM 拆分的**子需求链头**（合一模型：链头即首阶段工作节点，`ref=<归档名>/<需求文档路径>` 绑定需求文档）；CTO→DEV→QA 阶段链在需求节点下随流转链式 graft（1 任务 : N 节点，映射落盘 bridge.json）。

**阶段链模型**：任务生命周期跨角色，阶段推进链：`CTO → DEV → QA`；任务从 UX 起步时为 `UX → DEV → QA`。settle 一阶段节点后，下一阶段节点自动 graft 为**该节点的子节点**（链式 parent，无幽灵父节点）。rollback 跨阶段回退时，重建的前一阶段节点以**兄弟挂接**回到链头层（parent = 前一阶段节点的 parent）——链不变量与树深在多轮回退下保持。

**任务级依赖**：promulgate 从各任务需求文档的「依赖关系」字段自动推导（"依赖需求 N" / "依赖 #N" → 依赖任务 N 的初始节点）；跨阶段/运行中的依赖维护用 `goal-tree deps add/remove`（机械 DAG 校验 + deps-log.jsonl 审计）。

**规划者职责收敛**：推送全自动后，规划者的职责收敛为**裁定**（settle/prune/graft 下探）与**异常处置**（pointer 类重推、依赖调整、驳回移交）——不再逐节点 dispatch。

**会话存活判定（两级）**：第一级 = dsh agents 注册表查证（经 goal-tree 插件只读 liveness 端点，与回调投递同源）→ `alive/dead`；第二级 = 时间阈值（claimed 后 60min 账本无产出）**仅 unknown 兜底**（CLI 后端 / 查证不可达）。`reclaim` 对 alive 机械拒绝（`RECLAIM_TARGET_ALIVE`，长任务误杀物理不可能）；unknown 且未达阈值报 `RECLAIM_UNPROVEN_DEAD`（宁等多收）。

**长任务处置纪律**：超时标记 ≠ 死——unknown 态节点反复接近阈值是长任务强信号，处置优先级：等 > 询问用户 > 回收；同一节点反复超时不要反复回收（有界损失：一次重跑），向用户上报节奏异常。

---

## 命令面板

调用约定与 rdd-flow 相同（`$rdd` 三级定位链指向 rdd-engine 目录），输出 UTF-8 JSON。

| 命令 | 形态 | 作用 |
|------|------|------|
| 颁布 | `delivery-bridge.cmd -Command promulgate -TaskJson <path> [-ReviewFile <path>] [-MaxRounds N] [-NodeWidth N] [-MaxNodes N] [-CreatedBy label] [-Session label]` | 读归档 → goal-tree start（目标根模式，原始需求=goal 根）+ round-start + 按任务×当前阶段 graft 需求链头（`ref=<归档名>/<需求文档>`）→ 写 bridge.json v2 → **自动推送全部无前置依赖节点**。可选 `-ReviewFile` 消费需求审查结论（硬约束 6）：驳回/合并任务不建节点、`depends_on_override` 整体替代正则推导、合并依赖重定向到并入方、驳回残留依赖硬拒 `REVIEW_EXCLUDED_DEP`；缺省时行为与无审查门完全一致。RunId 固定为 `deliver-<归档名>`。预算默认：rounds 12 / width max(4, 任务数) / nodes 任务数×5+6 |
| 调动 | `delivery-bridge.cmd -Command dispatch -RunId <id> -NodeId <n> [-DryRun]` | 手动单节点推送（异常处置 / pointer 类失败人工重推；正常流程由自动推送承担） |
| 认领 | `delivery-bridge.cmd -Command claim -RunId <id> -NodeId <n> -Role <CTO/UX/DEV/QA>` | **被推送会话的第一动作**。双侧只读预检 → leaf claim → rdd-flow claim；冲突给确定性反馈 + 当前可领节点清单；goal 根报 `GOAL_NODE_NOT_CLAIMABLE` |
| 回收 | `delivery-bridge.cmd -Command reclaim -RunId <id> -NodeId <n>` | 复合回收，两种模式：**dead-claim**（卡死 claimed：存活预检——alive 拒 `RECLAIM_TARGET_ALIVE`、unknown 未达 60min 阈值拒 `RECLAIM_UNPROVEN_DEAD`——通过后 leaf `-Steal` + rdd-flow `claim -Force` 入泊位 → **自动重推**）与 **rejected-delivery**（reported 但证据不合格：剪枝失败交付 + graft 替换节点（ref 重绑需求文档）+ 重映射 → **自动推送替换节点**，账本保留审计痕） |
| 回退 | `delivery-bridge.cmd -Command rollback -RunId <id> -NodeId <失败节点> -Reason "<理由>"` | **跨阶段回退单命令**（与 settle 正向 / reclaim 同阶段构成三通道）：剪枝失败节点（prune reason 入 ledger 留审计：回退理由+操作者+证据问题清单）→ **兄弟挂接**重建前一阶段节点（parent=前一阶段节点的 parent；QA 证据问题+回退理由进新节点 task 的重做上下文）→ `rdd-flow reopen` 路由回退（owners 对齐，`Sync-TaskClaims` 自动清 worker 残留）→ **自动重推**重建节点。目标阶段机械单源推导（失败节点 parent 的 stage）；守卫 `ROLLBACK_REQUIRES_REPORTED` / `ROLLBACK_REQUIRES_UNQUALIFIED` / `ROLLBACK_NO_PREVIOUS_STAGE` / `TASK_NOT_ACTIVE`；prune→graft 崩溃窗口由剪枝签名幂等续跑守卫兜底（重跑同命令自动续 graft 步，不二次剪枝）。QA→DEV 为一等路径，DEV→CTO/UX 同一代码路径；返回值 `dependents_warning[]` 仅警示直接依赖边（不展开传递闭包，闭包经 `goal-tree deps list` 自查），不动其他任务节点 |
| 流转 | `delivery-bridge.cmd -Command settle -RunId <id> -NodeId <n> [-Note ...]` | **task.json 流转的唯一通道**（见下方三查门禁）；settle 尾自动推送新解锁节点 |
| 全景 | `delivery-bridge.cmd -Command status -RunId <id>` | join 视图：树 census + 任务阶段 + 依赖阻塞 + 双侧死 claim + pending_sync 分歧（自动重试修复）+ pushes 推送账目 + 会话存活 + **会话花名册**（sessions：本体/派发/直交全量清单）+ **触碰兜底补推**（租约空闲时）+ 租约 |
| 续跑 | `delivery-bridge.cmd -Command resume -RunId <id>` | 断点视图 + 恢复步骤清单（新规划者会话入口；本体会话自动入花名册） |
| 结案 | `delivery-bridge.cmd -Command conclude -RunId <id> -Summary <结案摘要>` | 全任务终态校验 → goal-tree conclude（achieved，**锚=目标根**，根语义终局校验）→ 写 delivery-annex.md（根目标达成状态 + 每任务终态 + rdd-flow check 结果）→ 释放租约 |
| 租约 | `delivery-bridge.cmd -Command lease -RunId <id> [-Acquire] [-Release] [-Takeover]` | 规划者会话级 advisory 租约（`planner-lease.json`；stale 阈值 30 分钟，区别于 run `.lock` 的命令级 60s） |
| 登记 | `delivery-bridge.cmd -Command register-session -RunId <id> -SessionId <sid> -Role <角色> -Label <标签>` | **树外直交登记**：直调 start-role 派发后，把打印的 sessionId 登入花名册（sessions.json），直交会话事后可溯源 |

依赖维护（直达 goal-tree 管理面）：

```powershell
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction add    -RunId <id> -NodeId <n> -On <m>
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction remove -RunId <id> -NodeId <n> -On <m>
& "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction list   -RunId <id>
```

## 硬约束

1. **不合格交付不得流转**：settle 三查（verdict=done / citations 改动清单非空且每条 ref 真实存在 / extras.verification 非空）任一不过即拒，节点停在 reported。
2. **禁止手工双写**：桥接 run 的 task.json 流转正向只能走 `bridge settle`、反向只能走 `bridge rollback`——双通道皆收敛进桥接层；手工 `rdd-flow advance/complete/reopen` 会造成双源矛盾（status 的 pending_sync 只修复 settle/rollback 先行、flow 后补的半失败，不覆盖手工乱写）。
3. **规划者变更操作需持租约**：promulgate/dispatch/settle/reclaim/rollback/conclude 要求 planner-lease（自动获取/刷新；他人持新鲜租约时报 `LEASE_HELD`，`-Takeover` 强制接管留痕）。worker 的 `claim` 免租约。
4. **中断恢复不重复消费**：reported 节点永不被重新消费（goal-tree 既有不变量）；死 claim 用 reclaim 统一出口。
5. **轮次纪律由桥接承担**：promulgate 开第 1 轮并保持开放至 conclude（conclude 自动收轮）；规划者不手工 round-start/end。
6. **建树前需求审查门（`-ReviewFile`）**：规划者接管归档时先审查后建树——读 task.json + 全部需求文档 + overview，逐条判定子需求的独立性与合理性（与根目标一致性、粒度、依赖标注真实度），结论分级：**通过**（正常建树）/ **树内裁定**（轻度问题：依赖错标 → `depends_on_override`；同一改动两个侧面 → `merged_into_task_id` 合并剪枝，留审计痕、不阻断其余需求交付）/ **驳回回流**（文档级不合理 → 先按驳回协议处置再 promulgate，见 `rejection-protocol.md`「PLANNER 发起的驳回」）。审查是规划者会话的语义判断，脚本层不硬拦（`-ReviewFile` 缺省不阻塞再 promulgate/自动化）；ReviewFile 契约（精确模板）：

   ```json
   {
     "reviewed_at": "<ISO-8601>",
     "reviewer": "planner",
     "verdicts": [
       { "task_id": 1, "verdict": "pass",             "reason": "独立、与根目标一致" },
       { "task_id": 2, "verdict": "tree_adjudicated", "reason": "依赖错标：实际不依赖 #1",
         "depends_on_override": [] },
       { "task_id": 3, "verdict": "tree_adjudicated", "reason": "与 #2 实为同一改动两个侧面",
         "merged_into_task_id": 2 },
       { "task_id": 4, "verdict": "reject_return",    "reason": "与 overview 根目标不符" }
     ]
   }
   ```

   - `verdict` 枚举 `pass / tree_adjudicated / reject_return`；未列出的任务 = 隐式通过。`pass` 不得携带 `depends_on_override`/`merged_into_task_id`；两者也不得同现于一条 verdict（合并任务不建节点）；同任务重复 verdict、指向不在归档的任务均拒。
   - **前置动作**（脚本消费前规划者必须完成）：`reject_return` → 需求文档「## 驳回记录」追加行 + `rdd-flow reject -From PLANNER -To PM`；`merged_into_task_id` → `rdd-flow deprecate -TaskId <被并入方>`（误判经 `reopen` 可恢复；ReviewFile 对已 deprecate 的被并入方记 merged_into 即为其留痕）。
   - **机械消费保证**：排除任务不建节点、不进 bridge.tasks、不被推送（`skipped_review` 与既有 `skipped_deprecated` 并列入 promulgate 返回值）；依赖被合并排除的任务重定向到并入方；依赖悬空于驳回排除任务硬拒 `REVIEW_EXCLUDED_DEP`（**禁止静默丢弃依赖**——静默丢弃会让依赖方被过早推送，正是审查门要消灭的错序 bug 类）；审查显式依赖（override/重定向）指向后位任务时经 `deps add` 延后缝合（DAG 校验 + deps-log 审计）。
   - **确定性错误码三枚**：`REVIEW_FILE_INVALID`（解析/schema/字段一致性）、`REVIEW_TASK_NOT_FOUND`（task_id/override/merge 指向不在归档）、`REVIEW_EXCLUDED_DEP`（依赖悬空于驳回排除任务）。
   - **结论呈现**：`report/review.md`（人读逐条结论表：结论/理由/处置/时间）+ promulgate 返回值 `review` 段 + bridge.json `review` 段（机器可读审计）。用户可随时干预或推翻裁定（**最终裁决权在用户**），推翻处置见异常处置速查。
   - **结案如实呈现**：conclude 门禁豁免严格限定 review 段 `reject_return` 集（该类任务 active@PM 是真实状态）；其余非终态任务照旧 `DELIVERY_INCOMPLETE` 硬拒。annex 根目标措辞：无未决驳回 =「达成」；有 =「部分达成（N 条驳回回流 PM，见任务终态表）」；被合并任务标注「deprecated（树内合并至 #N，非放弃）」。

## 交付语义映射（回调契约）

worker 沿用 goal-tree 证据导向回调结构承载交付语义，核心零改动：

| 回调字段 | 交付语义 |
|----------|----------|
| `verdict=done` | 交付自评完成（未 done 不得 settle） |
| `citations[]`（`ref`=真实路径） | 改动清单（settle 逐条校验路径存在） |
| `full_report` | 主产物文档指针（设计文档 / 实现说明；桥接 run 内规范必填——回调消息据此呈现 Doc 行，规划者凭单条消息即可裁定。引擎结构校验不强制：漏带降级可接受，citations 仍含文档路径，三查不卡） |
| `extras.verification` | 验证结果（lint/test/build 摘要；缺失即拒） |

真实性判断由 **QA 阶段节点**承担：QA 会话的 citations = 验收证据（功能+质量双通过），QA 节点 settle 即任务 complete。QA 判不合格 → report 非 done verdict（失败清单写入回调 full_report/extras），规划者收到后二选一：**同阶段重做** `reclaim -NodeId`（问题在本阶段可修）或**跨阶段回退** `rollback -NodeId -Reason <理由>`（退回 DEV 重做：单命令完成剪枝+重建+路由回退+自动重推，见命令面板「回退」行）。

**回调投递目标解析（dsh 后端）**：worker 回调投递给按「新鲜租约优先、planner.json 兜底」解析出的当前有效规划者——`planner-lease.json` 新鲜（30 分钟内，与 lease 命令 stale 阈值一致）且 holder 为 dsh 会话（`dsh-<sid>` 前缀）时投给该会话（Takeover 换手、续跑者拿租约后投递随之前指，修复断路）；否则回退 `state/planner.json` 记录的建 run 会话（误启的第二个规划者未持租约，回调不偏移；原规划者空闲存活时租约恰好 stale，回退目标正是它）。去重键（repo::run::entry）与投递目标无关，不会双投。CLI/Plus 后端无 watcher 实时投递（经 status/resume 拉取），不受影响。

## 异常处置速查

| 症状 | 处置 |
|------|------|
| 需树外直交某角色（用户裁决 / 事故修复） | 三步规程 + 登记：写 brief 文件 → `start-role -DryRun` 验证指针全文（含 `[直交] <标签>·<角色>` 标题行）→ 实发（`-Handoff <brief>` [+ `-SessionLabel <标签>`]，dsh 下会话标题自动钉住）→ `register-session -RunId <id> -SessionId <打印的sid> -Role <角色> -Label <标签>` 登入花名册 |
| 回调收到完成、但用户已手动直交下游角色 | 属正常优先级裁决：用户显式直交指令优先执行，但 worker 的 leaf report 回调先行不可省（next_suggestion 注明直交指令）——照常三查裁定 settle（ledger 留痕可对账）；直交会话与树推送会话撞车由 `FLOW_CLAIM_CONFLICT` / `NODE_NOT_CLAIMABLE` 确定性反馈兜底 |
| 同一节点第二个会话被唤起 | bridge claim 返回 `NODE_NOT_CLAIMABLE` + 认领者信息 + 可领清单，按清单改领即可 |
| 节点被依赖阻塞 | `NODE_BLOCKED_BY_DEPS` 附阻塞源；等上游 settle（解锁后**自动推送**，无需手动 dispatch），或规划者调整依赖（deps remove） |
| settle 报 `SETTLE_EVIDENCE_REJECTED` | `reclaim -NodeId`（rejected-delivery 模式：剪枝失败交付并建+**自动推送**替换节点——同阶段重做）或 `rollback -NodeId -Reason <理由>`（跨阶段回退：剪枝+重建前一阶段节点+reopen 路由回退+**自动重推**——退回 DEV 重做） |
| 树已 settle、flow 未流转 | `pending_sync` 自动记录；每次 status 自动重试修复，或手工补 |
| 会话死在 claimed | `reclaim -NodeId`（dead-claim 模式，入泊位后**自动重推**，新会话第一动作 claim 自动接管） |
| reclaim 报 `RECLAIM_TARGET_ALIVE` | 认领会话仍存活（agents 注册表证实）——不是回收对象；等它 report 或让该会话自行处置 |
| reclaim 报 `RECLAIM_UNPROVEN_DEAD` | 存活无法证实（CLI/查证不可达）且 claim 未达 60min 阈值——宁等多收；达阈值后重试或换 dsh 会话执行 |
| rollback 报 `ROLLBACK_REQUIRES_UNQUALIFIED` | 该节点证据合格——不该回退，settle 它即可 |
| rollback 报 `ROLLBACK_NO_PREVIOUS_STAGE` | 失败节点是链头（无前一阶段可退）——同阶段重做走 reclaim |
| rollback 报 `ROLLBACK_GRAFT_FAILED` | prune 已完成、graft 未成——**重跑同一条 rollback 命令**（剪枝签名幂等续跑守卫：自动从 graft 步续起，不二次剪枝） |
| 推送失败（status 可见 pushes 账目） | `session-create` 类：status 触碰自动重试；`pointer` 类：人工 `dispatch -NodeId` 重推（防会话堆积） |
| 双规划者误起 | 启动即被 start-role 前置校验拒绝（`PLANNER_RUN_ACTIVE`，附 run 信息与 `-RunId` 续跑指引；`-Force` 强启创建通道后命令级仍有 `LEASE_HELD` 防线，不产生第二个有效规划者）；确认原会话已死后 `lease -Takeover` 留痕接管 |
| promulgate 报 `RUN_EXISTS` | 该归档已颁布过，用 `status/resume -RunId deliver-<归档名>` 续跑 |
| promulgate 报 `REVIEW_FILE_INVALID` / `REVIEW_TASK_NOT_FOUND` | ReviewFile 契约违规（解析/schema/字段一致性/指向不在归档）——按错误消息修正 ReviewFile 后重试；错误均发生在建树前，无部分状态残留 |
| promulgate 报 `REVIEW_EXCLUDED_DEP` | 某任务依赖被驳回排除的任务—— planner 补裁定该任务（`depends_on_override` 或一并驳回），依赖不会被静默丢弃 |
| 用户推翻 planner 审查裁定 | **建树前**：直接改 ReviewFile 重产出（promulgate 未消费，无残留）。**run 已颁布**：误合并 → `rdd-flow reopen` 恢复被并入方（deprecate 非不可逆）+ 规划者经 `deps`/graft 补树内调整；误驳回 → PM 按驳回协议辩解翻案或 `rdd-flow reopen`，修订后经后续 run/正常流程承接。裁定推翻过程在会话内向用户留痕说明 |
| status 报 `BRIDGE_FORMAT_UNSUPPORTED` | 旧版 v1 桥（零兼容裁定）：重新 promulgate 或按本协议人工处置存量 run |
| 需求/设计不可行 | 走 `rdd-engine/references/rejection-protocol.md` 驳回协议移交上游 |

## 运行产物（run 目录内，gitignore）

| 文件 | 语义 |
|------|------|
| `bridge.json` | **v2**：节点↔TaskId 权威映射（1:N）+ `goal_root` 锚 + `goal`（原始需求标题/来源）+ `pushes` 推送账目（node/at/ok/error/retry_class）+ pending_sync 分歧账 + `review` 段（`-ReviewFile` 颁布时：reviewed_at/reviewer/verdicts/applied_at，机器可读审计）（v1 拒读 `BRIDGE_FORMAT_UNSUPPORTED`，零兼容裁定） |
| `planner-lease.json` | 会话租约（holder / acquired_at / taken_over_from 留痕） |
| `sessions.json` | 会话花名册（planner-session-roster）：本 run 派生的全部 dsh 会话——本体（promulgate/resume 自动登记）/ 桥接派发（推送回写）/ 直交（register-session 登记）；字段 session_id/role/node/label/source/title/created_at/updated_at，status 经 sessions 字段透出 |
| `report/review.md` | 需求审查结论（仅 `-ReviewFile` 颁布的 run）：逐条 verdict 表（结论/理由/处置/时间），呈现用户的人读持久化载体 |
| `report/delivery-annex.md` | 结案附录（根目标达成状态——有未决驳回时如实呈现「部分达成」+ 每任务终态（含树内合并/驳回注记）+ 阶段链 + rdd-flow check 结果） |
| （goal-tree 既有）tree.json / ledger.jsonl / round-*.md / final-report.md | 树状态 / 回调账本 / 轮快照 / 结案报告（目标根锚时含「根目标达成状态」区） |

> 桥接 run 目录：`.rdd/goal-trees/deliver-<归档名>/`。非桥接的 goal-tree run 与普通 rdd-flow 流程行为与引入桥接前完全一致（回归硬约束，由 delivery-bridge-verify 断言）。

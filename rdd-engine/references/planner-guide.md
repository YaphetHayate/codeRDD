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
  1.5 规划        长程规划（long-task-planning，必做）：从 task.json 产出**规划文件 PlanFile**
                  （阶段/批次/集成验收点/风险取舍）→ 随 promulgate -PlanFile 颁布（缺 PLAN_MISSING 硬门）
                  —— 见「长程规划与滚动追踪」节
  2. promulgate   颁布：归档任务集 → goal-tree run（目标根 + 需求链头节点 + 阶段链 + 依赖推导
                  + bridge.json v2 + plan 段（长程规划当前态）+ plan-log.jsonl（滚动记账）；
                  可选 -ReviewFile 消费审查结论——排除过滤/依赖覆盖/合并重定向）
                  → 尾部【自动推送】全部无前置依赖节点
  3. （推送即调度）角色会话被自动拉起，第一动作 bridge claim
  4. （worker）claim → 干活 → 完成即 leaf report 回调规划者（不 start-role 直交下游、
                  不启动 PLANNER——rdd-flow next 的 PLANNER 候选块对 worker 不适用，
                  误启收到 start-role 拒绝 PLANNER_RUN_ACTIVE；
                  回调携带产物位置：citations=改动清单，full_report=主产物文档指针，
                  extras.verification=验证结果）
  5. settle       流转：三查 → 树 settle → rdd-flow set-route（阶段内收窄 / 末位汇聚切换
                   -To PhaseRoles[下阶段] -Phase）或 complete → 收敛 graft 下一阶段链头
                   → 尾部【自动推送】新解锁节点（依赖满足者）；三查不过即拒（不合格交付不流转）——
                   同阶段重做走 reclaim，跨阶段回退走 rollback（剪枝+按 -To/-Phase 重建+set-route+自动重推）
  6. 循环 4-5；中断后任意新规划者会话 resume 续跑（status 触碰兜底补推漏推节点）
  7. 集成验收链（整体交付闭环）：全部子任务 settle → 自动 graft `[集成/联调]`（DEV，真实串联
                   数据/调用）→ settle → graft `[整体验收]`（QA，对照判据逐条核验真实链路）→
                   结论落 tests/integration-acceptance.md（桥接 run 全套机制，见「整体验收闭环」节）
  8. conclude     结案：全部任务终态 → ACCEPT 结论=通过 硬门（`ACCEPTANCE_PENDING`/
                   `ACCEPTANCE_NOT_PASSED`）→ 以目标根为锚 → final-report + delivery-annex.md
                   （含 rdd-flow check 与「整体验收结论」区）
```

**自动推送（依赖驱动，无人工确认门）**：dispatch 不再是规划者的逐节点手动命令。单一机制 `Invoke-AutoDispatch` 在四个触发点重算解锁集并推送：**建树推初始**（promulgate 尾）、**流转推解锁**（settle 尾）、**回收推重派**（reclaim 尾）、**回退推重做**（rollback 尾）、**巡检补漏**（status 触碰，租约空闲时）。推送条件 = 解锁（depends_on 全终态）∧ 未终态 ∧ 无活跃 claim（泊位除外）∧ 从未成功推送或回收后待重推。逐节点 try/catch 隔离失败，账目内嵌 bridge.json v2（`pushes`：node/at/ok/error/retry_class，逐节点落盘、崩溃后幂等重算续推）。失败分档：`session-create` 类（未建成会话）下一触发点自动重试；`pointer` 类（会话已建、指针投递失败）**只人工重推**（dispatch 命令保留用于此类与异常处置），防会话堆积。

**树形语义（目标根模型）**：根节点 = `type=goal` 的**目标根**——承载归档原始需求（overview.md 的 H1 标题 + 全文描述），不可认领（`GOAL_NODE_NOT_CLAIMABLE`）、不参与依赖（`DEP_GOAL_FORBIDDEN`）、conclude 终局锚点（全部直接子节点终态 ⇒ 根目标达成）。一级子节点 = PM 拆分的**子需求链头**（合一模型：链头即首阶段工作节点，`ref=<归档名>/<需求文档路径>` 绑定需求文档）；CTO→DEV→QA 阶段链在需求节点下随流转链式 graft（1 任务 : N 节点，映射落盘 bridge.json）。

**阶段链模型（phase-model）**：任务路由带 `phase` 字段，阶段全序 `REQ → DESIGN → IMPL → VERIFY → 完成`，阶段内角色白名单并行（DESIGN = CTO∥UX∥QA，含测试先行；完整模型见 `references/phase-model.md`，rdd-flow 侧协议见 `task-routing.md`）。多 owner 任务在颁布时**每个角色各建一个链头节点**（挂目标根），并行分支各自独立工作；settle 阶段感知：阶段内收窄不 graft，**最后一个 owner settle 才整组切换**（`set-route -To PhaseRoles[下一阶段] -Phase`）并收敛 graft 下一阶段节点（挂最后 settle 节点之下，链式 parent，无幽灵父节点，每角色至多一个活跃节点——并行分支不分裂树）。rollback 显式 `-To/-Phase` 回退时，重建的角色组节点以**兄弟挂接**回到目标阶段的链头层（沿失败节点祖先上溯第一个目标阶段白名单内节点的 parent；无锚挂目标根）——链不变量与树深在多轮回退下保持；回退到 REQ（`-To PM -Phase REQ`）可达，PM 为合法链头角色。旧归档（phase=null）整链保守降级为原 `CTO→DEV→QA` 线性行为（逐字节一致）。展示面：status/resume/conclude 的阶段链用 `∥`（阶段内并行）与 `→`（阶段间）渲染，如 `CTO=n2(done) ∥ UX=n3(done) → DEV=n5(claimed)`。

**任务级依赖**：promulgate 从各任务需求文档的「依赖关系」字段自动推导（"依赖需求 N" / "依赖 #N" → 依赖任务 N 的初始节点）；跨阶段/运行中的依赖维护用 `goal-tree deps add/remove`（机械 DAG 校验 + deps-log.jsonl 审计）。

**规划者职责收敛**：推送全自动后，规划者的职责收敛为**裁定**（settle/prune/graft 下探）与**异常处置**（pointer 类重推、依赖调整、驳回移交）——不再逐节点 dispatch。

**会话存活判定（两级）**：第一级 = dsh agents 注册表查证（经 goal-tree 插件只读 liveness 端点，与回调投递同源）→ `alive/dead`；第二级 = 时间阈值（claimed 后 60min 账本无产出）**仅 unknown 兜底**（CLI 后端 / 查证不可达）。`reclaim` 对 alive 机械拒绝（`RECLAIM_TARGET_ALIVE`，长任务误杀物理不可能）；unknown 且未达阈值报 `RECLAIM_UNPROVEN_DEAD`（宁等多收）。

**长任务处置纪律**：超时标记 ≠ 死——unknown 态节点反复接近阈值是长任务强信号，处置优先级：等 > 询问用户 > 回收；同一节点反复超时不要反复回收（有界损失：一次重跑），向用户上报节奏异常。

---

## 整体验收闭环（overall-delivery）

> **判据载体**：`requirements/overview.md` 固定段 `## 整体验收判据`（引用锚全程稳定），条目 = 用户可感知完整场景 + 可检验形态 + 覆盖子需求映射。必填分层（PM 归档规则，promulgate 机械校验）：**≥2 条子需求必填 / 单需求快速通道豁免 / 确无整体场景以一行「无整体判据（理由：…）」显式声明**——缺失且应填 → 颁布硬拒 `ACCEPTANCE_CRITERIA_MISSING`（不建树、零残留，修法=补判据段或显式声明）。
>
> **判据流动**：promulgate 校验非空 → 判据引用（`requirements/overview.md#整体验收判据`）注入 goal 根与**每个节点 task**（派发记录检验点，指针 brief 同步携带）→ 设计文档 frontmatter `acceptance_ref` 引用对齐（CTO/UX 模板同构字段）。
>
> **验收链机制（时机表达）**：全部子任务节点终态 → 自动 graft `[集成/联调]`（DEV，树级工作节点：真实串联各模块数据/调用跑通原始需求整体场景，**不是各模块独立跑通子验收**）→ 其 settle → graft `[整体验收]`（QA，对照判据逐条核验真实链路）→ 其 settle 记录结论。两节点挂目标根、**不绑 TaskId**（树级节点统一分支：claim 跳过 flow 侧、settle 跳过流转动作终态即止、自动推送照常）。`bridge.json` 顶层 `acceptance` 段全程占位可见：`status: planned→grafted` + `integrate_node`/`accept_node` + `criteria_ref` + `conclusion`。
>
> **结论落点**：`tests/integration-acceptance.md`（归档 tests/ 下）单文件三区——§1 集成/联调记录（**引用账本条目不复制**，指向 `[集成/联调]` 节点回调 citations）/ §2 判据逐条核验表（借判据「覆盖子需求映射」定位失败点到责任任务链）/ §3 总结论（**结论必须可判**：一行『总结论：通过』或『总结论：不通过』）。`[整体验收]` settle 时解析 §3 落 `acceptance.conclusion`；结论不可判时 conclude 给出 `ACCEPTANCE_PENDING` 并允许补写 §3 后重试（验收节点已 settle 无需重做）。
>
> **结案硬门**：`conclude achieved` 前置 ACCEPT 结论=通过——`ACCEPTANCE_PENDING`（验收链未走完/结论不可判）与 `ACCEPTANCE_NOT_PASSED`（结论=不通过，失败点见 §2）**优先于 goal 锚校验**报出；不通过时 run 保持开放，失败点经覆盖映射定位责任任务链（返工/回溯流程属需求边界外，复用 reclaim/rollback）。
>
> **场景分层**：桥接 run = 上述全套机制；**非桥接多需求** = 判据 + 设计文档 `acceptance_ref` 引用对齐 + QA 在 VERIFY 阶段对照判据逐条核验真实链路（轻量消费，不建验收链节点）；**单需求/快速通道** = 豁免（其验收标准即整体判据）。旧 run（bridge.json 无 `acceptance` 键）行为与引入前逐字节一致。

---

## 长程规划与滚动追踪（long-task-planning）

> 长程交付 = 规划先行 + 滚动追踪 + 只增不减的阶段闸门。规划是对交付的显式承诺，运行态随树滚动核销；任何偏差都必须经 `replan` 修正，不允许口头带过。

**三载体（各司其职，互不越权）**：

| 载体 | 位置 | 语义 |
|------|------|------|
| **规划文件 PlanFile** | 规划者产出的 `plan.json`（promulgate 入口 `-PlanFile`） | 颁布时的**规划承诺**：阶段/批次/集成验收点/风险取舍。必填（缺 → `PLAN_MISSING`）；schema/覆盖/顺序机械校验，失败零残留 |
| **bridge.json `plan` 段** | run 目录 | **当前态**：每阶段 acceptance_point 的 status/node、revision、applied_at——闸门判定与展示面的唯一读源 |
| **plan-log.jsonl** | run 目录 | **事件台账**（append-only）：`P<n>` progress（plan_promulgated/settle/acceptance_grafted/acceptance_passed）+ `D<n>` deviation（order/scope/delay/rollback/reclaim/acceptance_invalidated）+ `R<n>` revision（replan diff）。坏行隔离 `plan-log.jsonl.corrupt` 续写（账本范式，不重写） |

**PlanFile 形态**（要素齐全 ≠ 篇幅：目标一句话即可）：

```json
{
  "planned_at": "2026-09-24T00:00:00Z", "planner": "planner",
  "stages": [{
    "id": "S1", "goal": "阶段目标一句话", "milestone": "阶段里程碑",
    "task_ids": [1, 2], "batches": [[1, 2]],
    "acceptance_point": { "criteria_items": ["判据子集…"], "slice": "可运行整体切片形态（如 smoke 命令/演示路径）" }
  }],
  "risks": [{ "risk": "风险描述", "level": "P1", "note": "取舍说明" }]
}
```

- **task_ids**：每条交付任务恰在**一个**阶段（全覆盖 = 无幽灵 id、无遗漏；不交付的（deprecated/树内合并/驳回回流）豁免）。
- **batches**：阶段内**可并行批次**，须为依赖前向的拓扑序（依赖边不得落在同一批次内 → `PLAN_BATCH_INVALID`）。
- **acceptance_point**：每阶段**集成验收点**——`criteria_items` 判据子集 + `slice` 可运行切片形态（缺一 → `PLAN_FILE_INVALID`）。k<K 的阶段验收点在阶段任务全部终态时自动 graft 树级节点 `[集成验收·S<k>]`（role=QA，挂目标根）；末阶段 K 且有整体验收链时**绑定 R1 `[整体验收]` 节点**，无链（单任务/声明无判据）时任务终态**自动通过**。

**阶段闸门（只增不减）**：任务节点的推送与认领要求**其之前所有阶段**的 acceptance_point 均 `passed`；未过闸 → 推送跳过（`blocked_by_stage_gate`）、认领/调度硬拒 `NODE_BLOCKED_BY_GATE`（**无 Force 旁路**——出路只有两个：settle 对应 `[集成验收·S<k>]` 节点，或 replan 重划阶段）。`passed` 的机械含义 = 验收节点已 settle（真实执行完集成验收）；回退/回收/replan 波及已验收阶段时**失效波**把该阶段及之后的 acceptance_point 退回 `planned` 并解绑节点（防闸门虚开），解绑同步**失效回收**——prune 旧验收点节点（`pruned_reason` 留痕 `acceptance invalidated: <stage>`）释放 goal-root 子位、re-graft 复用子位不累积，维持「每非末段验收点 ≤1 活跃 goal-root 子位」不变量（末阶段复用 R1 终局链节点，同守不变量）。

**偏差检测（五个观测点，自动记账）**：settle 尾（任务落在规划外 = scope；后阶段任务先落而前阶段验收未过 = order）· reclaim 尾（deviation=reclaim）· rollback 尾（deviation=rollback）· status 巡检（claimed 超 `${DeadClaimMinutes}` 分钟无产出 = delay）· replan 内容变更（acceptance_invalidated）。

**replan（滚动修正唯一入口）**：`delivery-bridge.cmd -Command replan -RunId <run> -PlanFile <修订版> -Reason <偏差>`——`-Reason` 必填（缺 → `MISSING_REASON`）；产出**结构化 diff**（stage_added/removed/changed、task_moved、batches_changed、acceptance_changed、risks_changed，不快照全文）+ revision 事件（revision+1）。已 `passed` 的验收点仅当**阶段内容不变**时保留；内容变更即失效（+acceptance_invalidated 事件 + 失效回收 prune 旧验收点节点，re-graft 复用子位）。run 已结案或无 plan 段 → `REPLAN_NOT_ACTIVE`。

**预算公式**：`node_width = max(4, 链头数 + 2 + (K-1))`、`max_nodes = 任务数×5 + 6 + (K-1)`（K=阶段数；K=1 零增量——单阶段行为逐字节等价旧版）。验收点节点挂在目标根下，占宽度（+2 为 R1 验收链预留）。

**异常速查**：`PLAN_MISSING`（-PlanFile 缺失）/ `PLAN_FILE_INVALID`（schema/覆盖/幽灵 id，exit 2）/ `PLAN_ORDER_INVALID`（依赖落在更后阶段；同阶段合法，批次管细序）/ `PLAN_BATCH_INVALID`（依赖同批次）/ `NODE_BLOCKED_BY_GATE`（闸门未开）/ `STAGE_ACCEPTANCE_PENDING`（conclude 时仍有验收点未通过——在 `ACCEPTANCE_*` 门之后判）/ `REPLAN_NOT_ACTIVE` / `MISSING_REASON`。

---

## 命令面板

调用约定与 rdd-flow 相同（`$rdd` 三级定位链指向 rdd-engine 目录），输出 UTF-8 JSON。

| 命令 | 形态 | 作用 |
|------|------|------|
| 颁布 | `delivery-bridge.cmd -Command promulgate -TaskJson <path> -PlanFile <plan.json> [-ReviewFile <path>] [-AutoMode [-RiskPolicy <path>]] [-NoPush] [-MaxRounds N] [-NodeWidth N] [-MaxNodes N] [-CreatedBy label] [-Session label]` | 读归档 → goal-tree start（目标根模式，原始需求=goal 根）+ round-start + 按任务×初始角色组**每角色各 graft 一个链头**（phase-model 多链头：并行 `currentOwners` 不再丢工作；`ref=<归档名>/<需求文档>`，`depends_on` 指向上游任务**全部**链头——多锚点汇聚解锁）→ 写 bridge.json v2 → **自动推送全部无前置依赖节点**。长程规划 intake（必做）：`-PlanFile` 缺失 → `PLAN_MISSING`；schema/覆盖/阶段序/批次序机械校验 → `PLAN_FILE_INVALID`/`PLAN_ORDER_INVALID`/`PLAN_BATCH_INVALID`（零残留），plan 段 + plan-log.jsonl 随树落盘（见「长程规划与滚动追踪」节）。阶段校验门：owner 集跨阶段 → `GROUP_DIVERGENT_NEXT`（第一版不支持 fan-out）；存量 phase 非法 → `PHASE_INVALID`/`PHASE_OWNER_MISMATCH`。可选 `-ReviewFile` 消费需求审查结论（硬约束 6）：驳回/合并任务不建节点、`depends_on_override` 整体替代正则推导、合并依赖重定向到并入方、驳回残留依赖硬拒 `REVIEW_EXCLUDED_DEP`；缺省时行为与无审查门完全一致。整体验收判据校验（整体交付闭环）：≥2 条子需求且 overview.md 缺「## 整体验收判据」（既无条目也无「无整体判据」显式声明）→ `ACCEPTANCE_CRITERIA_MISSING` 拒建树（零残留）；判据引用注入 goal 根与各节点 task，bridge.json 落 `acceptance` 段（planned 占位）。可选 `-AutoMode` 启用纯自动模式（见「纯自动模式」节；缺省关闭=行为逐字节不变），`-RiskPolicy` 整表覆盖默认分级表（R1 硬底强制保留）。可选 `-NoPush`：只建 run 不启动任何角色会话（引擎测试套件/事故演练隔离——不触真后端，跳过入 pushes 账 `trigger='promulgate (-NoPush)'`）。RunId 固定为 `deliver-<归档名>`。预算默认：rounds 12 / width max(4, 链头数+2+(K-1))（+2=集成/联调+整体验收两枚树级验收节点的挂根预算；K-1=阶段验收点挂根增量，K=阶段数）/ nodes 任务数×5+6+(K-1)；重度返工 run 按回退预期调 `-MaxNodes`（每轮跨阶段回退按重建组规模净增节点） |
| 调动 | `delivery-bridge.cmd -Command dispatch -RunId <id> -NodeId <n> [-DryRun]` | 手动单节点推送（异常处置 / pointer 类失败人工重推；正常流程由自动推送承担） |
| 认领 | `delivery-bridge.cmd -Command claim -RunId <id> -NodeId <n> -Role <PM/CTO/UX/DEV/QA>` | **被推送会话的第一动作**。双侧只读预检 → leaf claim → rdd-flow claim；冲突给确定性反馈 + 当前可领节点清单；goal 根报 `GOAL_NODE_NOT_CLAIMABLE`；PM 为 REQ 阶段合法链头角色（rollback -To PM 的重建节点可认领）；**树级验收节点**（`[集成/联调]`/`[整体验收]`，无 TaskId）走树级分支：leaf claim 后跳过 flow 侧，响应附 acceptance 上下文（判据引用/交付记录约定）；纯自动模式 run 的响应额外携带 `auto_mode` 段（enabled + 分级表快照 + decide/escalate 协议指引，report_hint 注入先例；非自动 run 无此段） |
| 拍板 | `delivery-bridge.cmd -Command decide -RunId <id> -NodeId <n> -Kind auto\|resolution\|overturn -Checkpoint <名> -Decision <裁定/问题> [-Inputs ...] [-Basis ...] [-Risk ...] (-Kind auto 需 -RuleId <规则>；resolution/overturn 需 -RefEntry <条目id>)` | **worker 侧检查点决策留痕**（纯自动模式专用，否则 `AUTO_MODE_DISABLED`；须本 stage 的 claimed 节点，overturn 额外容忍 reported=未 settle 重做窗口）。`auto`=分级表代答（规则须 action=auto，R1 硬底永拒 `RULE_NOT_AUTO`，代答者 `auto/<规则>@<stage>`）；`resolution`=用户裁定回填关闭未决升级（`user@in-session`，重复关闭拒 `ESCALATION_ALREADY_RESOLVED`）；`overturn`=未 settle 期内推翻既有决策（auto/resolution/escalation 条目，run 级 ref 存在性校验）。追加进 decisions.jsonl（run `.lock` 内，读回校验） |
| 升级 | `delivery-bridge.cmd -Command escalate -RunId <id> -NodeId <n> -Checkpoint <名> -Decision <呈用户的问题> [-RuleId <规则>] [-Inputs ...] [-Basis ...] [-Risk high]` | **高风险检查点升级**（纯自动模式专用，同上门禁）：写 open 升级条目（无人拍板，decider=null），worker 就地**等待**。dsh：插件 watcher 5s 扫描投递规划者 inbox（exactly-once，`decision <id>` 去重命名空间，送达即唤醒——`agent.send(msg,'next-turn',true)`，空闲规划者会话立即开轮消费）→ 规划者呈现用户 → `decide -Kind resolution` 回填；CLI/Plus：降级为 status/resume 可见 |
| 回收 | `delivery-bridge.cmd -Command reclaim -RunId <id> -NodeId <n>` | 复合回收，两种模式：**dead-claim**（卡死 claimed：存活预检——alive 拒 `RECLAIM_TARGET_ALIVE`、unknown 未达 60min 阈值拒 `RECLAIM_UNPROVEN_DEAD`——通过后 leaf `-Steal` + rdd-flow `claim -Force` 入泊位 → **自动重推**）与 **rejected-delivery**（reported 但证据不合格：剪枝失败交付 + graft 替换节点（ref 重绑需求文档）+ 重映射 → **自动推送替换节点**，账本保留审计痕） |
| 回退 | `delivery-bridge.cmd -Command rollback -RunId <id> -NodeId <失败节点> -To "<角色集>" -Phase <REQ/DESIGN/IMPL/VERIFY> -Reason "<理由>"` | **跨阶段回退单命令**（与 settle 正向 / reclaim 同阶段构成三通道）：剪枝失败节点（prune reason 入 ledger 留审计：回退目标+阶段+理由+操作者+证据问题清单）→ **兄弟挂接**按 `-To` 角色集逐角色重建节点（挂接锚=沿失败节点祖先上溯第一个落在目标阶段白名单内的节点之 parent——回到该阶段链头层；无锚则挂目标根；QA 证据问题+回退理由进新节点 task 的重做上下文）→ `rdd-flow set-route -To -Phase` 原子路由回退（owners+phase 白名单同步，`Sync-TaskClaims` 自动清 worker 残留）→ **自动重推**全部重建节点。回退目标由规划者**显式指定**（替代旧的 parent 机械推导；链头回退 REQ 可达）；守卫 `SET_PHASE_REQUIRED`（缺 -Phase）/ `PHASE_INVALID` / `PHASE_OWNER_MISMATCH`（-To 不 ⊆ PhaseRoles[-Phase]）/ `ROLLBACK_REQUIRES_REPORTED` / `ROLLBACK_REQUIRES_UNQUALIFIED` / `TASK_NOT_ACTIVE`；prune→graft 崩溃窗口由剪枝签名幂等续跑守卫兜底（重跑同命令自动续 graft 步，不二次剪枝，签名兼容新旧两代格式）。例：DEV 发现设计缺陷 → `rollback -NodeId <DEV节点> -To "CTO+UX" -Phase DESIGN`；回退需求阶段 → `-To "PM" -Phase REQ`。返回值 `dependents_warning[]` 仅警示直接依赖边（不展开传递闭包，闭包经 `goal-tree deps list` 自查），不动其他任务节点 |
| 滚动修正 | `delivery-bridge.cmd -Command replan -RunId <id> -PlanFile <修订版 plan.json> -Reason <偏差说明>` | **滚动修正唯一入口**（见「长程规划与滚动追踪」节）：结构化 diff（stage_added/removed/changed、task_moved、batches_changed、acceptance_changed、risks_changed）+ revision+1 落 plan-log 账；已 `passed` 验收点仅当阶段内容不变才保留，内容变更触发失效波（退回 `planned` + 解绑节点 + 失效回收 prune 旧验收点节点 + `acceptance_invalidated` 事件，防闸门虚开）。守卫：`MISSING_REASON`（-Reason 必填）/ `REPLAN_NOT_ACTIVE`（run 已结案或无 plan 段） |
| 流转 | `delivery-bridge.cmd -Command settle -RunId <id> -NodeId <n> [-Note ...]` | **task.json 流转的唯一通道**（见下方三查门禁）。phase 感知（phase-model）：读 `phase` → 阶段内还有 owner 未 settle → `set-route` 收窄（不 graft，等待汇聚）；最后一个 owner settle → `set-route -To PhaseRoles[下一阶段] -Phase` 原子切换 + 收敛 graft 下一阶段全部链头（每角色至多一个活跃节点——并行分支不分裂树）；`VERIFY` 完成 → `complete`。phase=null（旧归档）保守降级走原 advance 路径（行为逐字节一致）。**树级验收节点**（无 TaskId）走树级分支：三查照常 → tree settle → 跳过流转动作（终态即止）；任一 settle 尾按**时机表达**触发验收链 graft（全部子任务终态 → `[集成/联调]` → 其 settle → `[整体验收]`），settle 尾自动推送新解锁节点 |
| 全景 | `delivery-bridge.cmd -Command status -RunId <id>` | join 视图：树 census + 任务阶段 + 依赖阻塞 + 双侧死 claim + pending_sync 分歧（自动重试修复）+ pushes 推送账目 + 会话存活 + **会话花名册**（sessions：本体/派发/直交全量清单）+ **触碰兜底补推**（租约空闲时）+ 租约 |
| 续跑 | `delivery-bridge.cmd -Command resume -RunId <id>` | 断点视图 + 恢复步骤清单（新规划者会话入口；本体会话自动入花名册） |
| 结案 | `delivery-bridge.cmd -Command conclude -RunId <id> -Summary <结案摘要>` | 全任务终态校验 → **整体验收硬门**（ACCEPT 结论=通过，否则 `ACCEPTANCE_PENDING`/`ACCEPTANCE_NOT_PASSED` **优先于 goal 锚校验**报出）→ goal-tree conclude（achieved，**锚=目标根**，根语义终局校验）→ 写 delivery-annex.md（根目标达成状态 + 每任务终态 +「整体验收结论」区 + rdd-flow check 结果）→ 释放租约 |
| 租约 | `delivery-bridge.cmd -Command lease -RunId <id> [-Acquire] [-Release] [-Takeover]` | 规划者会话级 advisory 租约（`planner-lease.json`；stale 阈值 30 分钟，区别于 run `.lock` 的命令级 60s） |
| 登记 | `delivery-bridge.cmd -Command register-session -RunId <id> -SessionId <sid> -Role <角色> -Label <标签>` | **树外直交登记**：直调 start-role 派发后，把打印的 sessionId 登入花名册（sessions.json），直交会话事后可溯源 |
| 冲突 | `delivery-bridge.cmd -Command conflict -RunId <id> -Action open [-ConflictId <C<n>> -ConflictStatus escalated\|suspended [-Escalation <问题>]] \| -Action open -ConflictKind design\|file -Nodes <n1,n2> [-Files <p1,p2>] [-Note ...] \| -Action resolve -ConflictId <C<n>> -Ruling <结论> [-Serialize <早者节点>]` | **并行协作冲突注册表**（见「并行协作冲突治理」节；动作仅 open\|resolve，上报/挂起为条目状态属性）：登记即 hold 涉事节点（推送门+settle 门），resolve 消解后自动恢复（-Serialize 组合 `goal-tree deps add` 串行化）。错误码 `NODE_HELD_BY_CONFLICT`/`CONFLICT_NOT_FOUND`/`CONFLICT_ALREADY_RESOLVED`/`CONFLICT_ENTRY_INVALID`；`CONVENTIONS_MISSING`/`DESIGN_MAP_INVALID` 见治理节 |

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
7. **纯自动模式边界（planner-auto-mode）**：自动拍板**仅限 worker 侧会话内检查点**（CTO 四检查点这类「达标+用户确认」闸门）；编排层裁决——建树审查门（硬约束 6）、settle 三查裁定、推翻/回退裁定——**不进分级表、不自动化**，永归人工。R1 宪法禁令行（安全/成本/不可逆/git）是脚本硬底：`-RiskPolicy` 整表覆盖也强制合并保留、永不许 action=auto。自动决策全程留痕可查可推翻（未 settle 走 overturn，已 settle 走 reclaim rejected-delivery / rollback 善后）；无 `-AutoMode` 的 run 一切行为与引入前逐字节一致。
8. **并行冲突不得默默二选一（parallel-coordination）**：设计冲突先调和出一致结论、或上报用户裁决并留痕（escalated），用户不在场挂起涉事链（suspended）并上报——不阻塞无冲突任务；文件冲突经**归属划分**（首选）或**串行化**消解，错峰不采用（时间错开不构成互斥）。未消解前涉事节点推送门 hold、settle 门拦截（design 恒拒；file 双活跃方互拦、单活跃写者放行）；消解后自动恢复。注册表只追加不改写（bridge.json `conflicts` 段 + `report/design-conflicts.md` 镜像）；多 CTO/UX 并行设计必须遵循同一套架构/风格约定（`-ConventionsFile`，`CONVENTIONS_MISSING` 建树前零残留）。
9. **规划承诺与阶段闸门（long-task-planning）**：`-PlanFile` 是颁布必填门（`PLAN_MISSING` 零残留）；规划须覆盖每条交付任务恰一次（`PLAN_FILE_INVALID`）、依赖不落后于被依赖者所在阶段（`PLAN_ORDER_INVALID`；同阶段合法——批次管细序）、批次内无依赖边（`PLAN_BATCH_INVALID`）。阶段闸门**只增不减**：任务推送/认领须其之前阶段的集成验收点全部 `passed`（`NODE_BLOCKED_BY_GATE`，**无 Force 旁路**——出路= settle `[集成验收·S<k>]` 或 replan）；回退/回收/replan 波及已验收阶段即触发失效波（退回 `planned`、解绑节点并失效回收 prune 旧验收点节点，防闸门虚开）。偏差只经 `replan -Reason` 修正（`MISSING_REASON`/`REPLAN_NOT_ACTIVE`），结构化 diff + revision 台账，不快照全文。

## 交付语义映射（回调契约）

worker 沿用 goal-tree 证据导向回调结构承载交付语义，核心零改动：

| 回调字段 | 交付语义 |
|----------|----------|
| `verdict=done` | 交付自评完成（未 done 不得 settle） |
| `citations[]`（`ref`=真实路径） | 改动清单（settle 逐条校验路径存在） |
| `full_report` | 主产物文档指针（设计文档 / 实现说明；桥接 run 内规范必填——回调消息据此呈现 Doc 行，规划者凭单条消息即可裁定。引擎结构校验不强制：漏带降级可接受，citations 仍含文档路径，三查不卡） |
| `extras.verification` | 验证结果（lint/test/build 摘要；缺失即拒） |

真实性判断由 **QA 阶段节点**承担：QA 会话的 citations = 验收证据（功能+质量双通过），QA 节点 settle 即任务 complete。QA 判不合格 → report 非 done verdict（失败清单写入回调 full_report/extras），规划者收到后二选一：**同阶段重做** `reclaim -NodeId`（问题在本阶段可修）或**跨阶段回退** `rollback -NodeId -To <角色集> -Phase <阶段> -Reason <理由>`（如退回 DEV 重做：`-To "DEV" -Phase IMPL`；单命令完成剪枝+重建+路由回退+自动重推，见命令面板「回退」行）。

**回调投递目标解析（dsh 后端）**：worker 回调投递给按「新鲜租约优先、planner.json 兜底」解析出的当前有效规划者——`planner-lease.json` 新鲜（30 分钟内，与 lease 命令 stale 阈值一致）且 holder 为 dsh 会话（`dsh-<sid>` 前缀）时投给该会话（Takeover 换手、续跑者拿租约后投递随之前指，修复断路）；否则回退 `state/planner.json` 记录的建 run 会话（误启的第二个规划者未持租约，回调不偏移；原规划者空闲存活时租约恰好 stale，回退目标正是它）。去重键（repo::run::entry）与投递目标无关，不会双投。CLI/Plus 后端无 watcher 实时投递（经 status/resume 拉取），不受影响。

## 纯自动模式（planner-auto-mode）

> **协议真源**。目标：桥接 run 无人值守时 worker 侧检查点（CTO 四检查点为代表）不再无限等待——低风险按分级表自动拍板并全程留痕，高风险升级人工，run 持续推进且无静默等待。边界见硬约束 7：编排层裁决不自动化。

**开关与快照**：`promulgate -AutoMode`（默认关闭；关闭时全部既有行为逐字节不变——bridge.json/claim/status/resume 均无 `auto_mode` 键；原回归套件 test-bridge-auto-mode.ps1 已按用户裁决移除（其隔离声明后仍产生真实夹具会话），字节门禁改为 `-NoPush` 开关语义与 pushes 账的静态核验）。分级表脚本内嵌默认（R1–R9，自上而下首条命中）：

| 规则 | 匹配 | 处置 |
|------|------|------|
| R1 | 宪法禁令类：安全/成本/不可逆操作/git | **人工（硬底，覆盖不可移除）** |
| R2 | 新框架/中间件/外部依赖 | 人工 |
| R3 | 协议语义变更/跨模块新机制 | 人工 |
| R4 | 技术选型实质分叉 | 人工（选型错沿链放大，默认保守） |
| R5 | 单一可行方案/沿用现状范式 | 自动 |
| R6 | 模块归属 | 自动 |
| R7 | 命名/文件清单/配置项 | 自动 |
| R8 | 风险取舍：含 P1→人工；仅 P2/P3→自动 | 按级别二分 |
| R9 | 回退/推翻既有决策 | 人工 |

`-RiskPolicy <path>` 提供整表覆盖（JSON：`{"rules":[{"id","match","action":"auto|manual","note"}]}`，空表/重复 id/非法 action 拒 `RISK_POLICY_INVALID`，校验先于任何 run 状态创建）；**R1 硬底强制合并保留**（缺失或被改成 auto 一律强制恢复内置 R1）。生效表快照入 `bridge.json.auto_mode`（enabled + policy + policy_source），**run 内不可变**（同 run 所有 worker 授权语义一致，改表经新 run 生效）。

**授权传递**：claim 是 worker 必经第一动作，纯自动 run 的 claim 响应注入 `auto_mode` 段（enabled + 分级表 + 协议指引，复用 report_hint 注入先例）——worker 无需自行探测模式；旧 run 无此段，逐字节兼容。

**决策账本（decisions.jsonl）**：`.rdd/goal-trees/<run>/decisions.jsonl` 追加式（与 state/ledger.jsonl 同范式：run `.lock` 内追加 + 读回校验，条目 id `D<n>` 递增）。字段：`entry_id/at/run_id/node_id/task_id/stage/kind(auto|escalation|resolution|overturn)/checkpoint/risk/rule_id/decision/inputs/basis/decider/ref_entry`。代答者身份取值：`auto/<规则>@<stage>`（规则代答）| `user@in-session`（会话内用户裁定/推翻）；升级条目 decider=null（未决=无人拍板）；`planner@lease` 为保留扩展位（规划者代答，v1 不启用）。**未决升级视图由 join 派生**：open = 升级条目 − 被 resolution/overturn 经 `ref_entry` 引用者；账本永不重写。ref_entry 校验放宽至 run 级存在性（容忍 rejected-delivery 换 node 后的悬挂引用；status 视图对 pruned 节点条目标注「历史」）。

**命令语义与守卫**：`decide`/`escalate` 均要求 `auto_mode.enabled`（否则 `AUTO_MODE_DISABLED`）+ 本 stage 的 claimed 节点（否则 `DECISION_NODE_NOT_CLAIMED`；overturn 额外容忍 reported=未 settle 重做窗口）。`decide -Kind auto` 要求规则在快照内且 action=auto（`RULE_NOT_FOUND`/`RULE_NOT_AUTO`——R1 硬底由此机械不可逾越）；`resolution` 关闭升级且不得重复关闭（`ESCALATION_ALREADY_RESOLVED`，改判走对 closing 条目的新 overturn）；`overturn` 目标限 auto/resolution/escalation 条目（禁止推翻推翻）。**升级不改变 reclaim 既有机械规则**（存活预检优先；长任务纪律「等>询问用户>回收」不变），worker 越过未决升级推进属协议违规（settle 三查不豁免，QA 审账可查）。

**升级通知与可见性**：dsh——rdd-goal-tree 插件 watcher 并行收集 open 升级条目（5s 扫描）投递规划者 inbox（exactly-once：`decision <id>` marker/去重命名空间，与 ledger `L<n>` 天然隔离；送达即唤醒——`agent.send(msg,'next-turn',true)`，空闲规划者会话立即开轮消费）→ 规划者呈现用户（tool-ask-user）→ `decide -Kind resolution` 回填后 worker 继续。CLI/Plus——降级为 status/resume 可见（`auto_mode` 块：enabled + 逐节点决策计数 + open escalations 清单；resume 恢复步骤含逐条升级处置指引）。QA/规划者经 decisions.jsonl 或 status 查每条自动决策的输入/依据规则/时间/代答者；worker 的 leaf report extras 可附 `auto_decisions` 摘要（计数 + 账本路径）。

**推翻通道**：未 settle 阶段内——会话内重做 + `decide -Kind overturn` 留痕（账本追加不改写，链路可审计）；已 settle 后——善后复用 `reclaim rejected-delivery`（同阶段）或 `rollback`（跨阶段，需求 1 回退命令软呼应：无硬依赖，本需求独立交付）。CTO 四检查点确认语义的条件豁免见 `rdd-cto/SKILL.md`「完成前置硬检查」纯自动模式分支（宪法原文不动；门槛达标语义不豁免；禁令类与人工分级不适用代答）。其余角色 SKILL v1 不改——机制经 claim 注入天然可用（扩展点）。

## 并行协作冲突治理（parallel-coordination）

多任务并行的两类冲突、一个注册表、三族确定性错误码。语义边界：本节管**编排层并行冲突**（设计互斥 / 文件重叠），与 worker 侧检查点决策账本（`decisions.jsonl`，纯自动模式）、建树前需求审查（`-ReviewFile`）分工不重叠。

**硬约束：并行冲突不得默默二选一**——设计冲突必须先调和出一致结论、或上报用户裁决并留痕；用户不在场挂起涉事链并上报（不阻塞无冲突任务）。时间错开（错峰）不构成互斥，**不是消解**。

### 两类冲突

| kind | 判定 | 发现途径 | 消解 |
|------|------|----------|------|
| `design` | 多 CTO/UX 设计互斥或风格不一致 | 规划者语义判断（评审设计产物） | **调和产出一致结论**（首选）→ `resolve -Ruling`；调和不成 → **上报用户裁决**（escalated）；用户不在场 → **挂起涉事链**（suspended）并上报 |
| `file` | 任务变更地图判出同文件重叠（精确路径匹配——保守判定是有意取舍） | 引擎推送门 `change-map-scan` 自动登记（亦可规划者人工登记） | **归属划分**（首选：`reclaim rejected-delivery` + replan，让唯一任务承载该文件改动）/ **串行化**（`resolve -Serialize <早者节点>`：晚者 `depends_on` 早者，早者 settle 后自动解锁） |

状态机：`open → resolved`｜`open → escalated → resolved`｜`open → suspended`。**上报/挂起是条目状态属性**（动作仅 `open|resolve`，同 decisions.jsonl 追加范式；history 追加不改写）：`conflict -Action open -ConflictId <C<n>> -ConflictStatus escalated -Escalation '<呈用户的问题>'` 或 `-ConflictStatus suspended`。

### 强制门（双触点）

1. **推送门**（`Test-PushCandidate`，与阶段闸门 AND 叠加、reason 分列）：涉事节点命中未决冲突 → `held_by_conflict`；变更地图精确路径重叠于并发实施（DEV）节点 → 自动登记 file 条目 + `held_by_file_overlap`。手动 `dispatch` 同守此门（`NODE_HELD_BY_CONFLICT`）——不得把节点推入未决冲突。
2. **settle 前置冲突门**（三查先行、错误码分立，冲突门后置）：`design` 涉事节点**恒拒**（`NODE_HELD_BY_CONFLICT`——不得默默二选一，先消解再 settle）；`file` **仅双活跃方互拦**（对方 claimed/reported 时防并发同文件覆盖；单活跃写者放行=先行落地即串行化前提，不追溯拦在途）。

消解后条目已决，下一触发点**自动推送**恢复，无须手动 dispatch。重叠口径与并发口径：重叠=变更地图文件路径精确匹配；并发=两任务间无依赖路径（传递闭包）的待推/在途实施节点。

### conflict 命令族

| 动作 | 形态 | 语义 |
|------|------|------|
| 登记 | `-Action open -ConflictKind design\|file -Nodes <n1,n2,...> [-Files <p1,p2,...>] [-Note ...] [-ConflictStatus escalated\|suspended [-Escalation ...]]` | 注册新条目 `C<n>`（递增），涉事节点即刻被门 hold；kind=file 必带 -Files（仓库根相对路径） |
| 状态属性 | `-Action open -ConflictId <C<n>> -ConflictStatus escalated\|suspended [-Escalation <问题>]` | 上报/挂起留痕（escalated 必带呈用户的问题）；已 resolved 的条目拒 `CONFLICT_ALREADY_RESOLVED`——裁定变更按**新条目**重开（注册表只追加） |
| 消解 | `-Action resolve -ConflictId <C<n>> -Ruling '<调和一致结论/用户裁决>' [-Serialize <早者节点>]` | -Serialize 组合 `goal-tree deps add`（DAG 校验 + deps-log 审计；失败即整体拒绝、冲突保持未决）。错误码：`CONFLICT_NOT_FOUND` / `CONFLICT_ALREADY_RESOLVED` / `CONFLICT_ENTRY_INVALID` |

全景视图：`status`（`conflicts` 段=登记全量+未决清单+回执偏差；未决冲突入 warnings）、`resume`（未决冲突=断点步骤）。人读镜像 `report/design-conflicts.md`；机器可读单源 bridge.json `conflicts` 段。

### 架构/风格约定（多 CTO/UX 设计共同基线）

- **载体**：review 步产出 `report/architecture-conventions.md`（架构/风格约定），经 `promulgate -ConventionsFile <path>` 注入（run 目录留副本 + bridge.json `conventions` 段）。
- **门**：DESIGN 并行链头 ≥2（多任务、互为并行——任意两设计任务间无依赖路径）缺 `-ConventionsFile` → `CONVENTIONS_MISSING`（**建树前判定，零残留**）。单设计（单任务设计单元）/串行设计（有依赖边）/非桥接 run 豁免。
- **注入**：每个 DESIGN 链头 node.task 带「架构约定：<path>」（与判据注入同构），设计会话开工即见共同基线。

### 变更地图机读契约（文件冲突的检测基础，rdd-cto/design-template.md 为准）

- **文件行**：`` `仓库根相对完整路径`  [新增]/[修改]/[删除] 说明 ``——可机读的**硬格式**；目录树行仅视觉分组；计数行（`[新增] n | [修改] n | [删除] n`）与实际解析机械核对。
- 不合契约的行 → `DESIGN_MAP_INVALID`（**警示级，不阻塞流转**）；存量/旧格式（无反引号完整路径）整体降级人工核对并显式警示——机械重叠检测对该文档失明，不硬拒也不静默放行。
- 引擎将设计产物机读进 bridge.json `design_maps`（只读派生缓存：文件集/计数/警示/指纹，文档变化自动重解析），供推送门重叠检测与回执软核对。

### 回执一致性软核对（警示，永不硬拒）

DEV 回执 `citations` 超出其设计变更地图文件集 → 偏差警示入 status/annex + `design_maps[doc].citation_deviations`——防「地图写错致检测失明」（变更地图失真风险的可见化），人工核对后按需修正设计产物。

## 异常处置速查

| 症状 | 处置 |
|------|------|
| 需树外直交某角色（用户裁决 / 事故修复） | 三步规程 + 登记：写 brief 文件 → `start-role -DryRun` 验证指针全文（含 `[直交] <标签>·<角色>` 标题行）→ 实发（`-Handoff <brief>` [+ `-SessionLabel <标签>`]，dsh 下会话标题自动钉住）→ `register-session -RunId <id> -SessionId <打印的sid> -Role <角色> -Label <标签>` 登入花名册 |
| 回调收到完成、但用户已手动直交下游角色 | 属正常优先级裁决：用户显式直交指令优先执行，但 worker 的 leaf report 回调先行不可省（next_suggestion 注明直交指令）——照常三查裁定 settle（ledger 留痕可对账）；直交会话与树推送会话撞车由 `FLOW_CLAIM_CONFLICT` / `NODE_NOT_CLAIMABLE` 确定性反馈兜底 |
| 同一节点第二个会话被唤起 | bridge claim 返回 `NODE_NOT_CLAIMABLE` + 认领者信息 + 可领清单，按清单改领即可 |
| 节点被依赖阻塞 | `NODE_BLOCKED_BY_DEPS` 附阻塞源；等上游 settle（解锁后**自动推送**，无需手动 dispatch），或规划者调整依赖（deps remove） |
| settle 报 `SETTLE_EVIDENCE_REJECTED` | `reclaim -NodeId`（rejected-delivery 模式：剪枝失败交付并建+**自动推送**替换节点——同阶段重做）或 `rollback -NodeId -To <角色集> -Phase <阶段> -Reason <理由>`（跨阶段回退：剪枝+按 -To/-Phase 重建角色组+set-route 路由回退+**自动重推**——如 `-To "DEV" -Phase IMPL` 退回 DEV 重做） |
| 树已 settle、flow 未流转 | `pending_sync` 自动记录；每次 status 自动重试修复，或手工补 |
| 会话死在 claimed | `reclaim -NodeId`（dead-claim 模式，入泊位后**自动重推**，新会话第一动作 claim 自动接管） |
| reclaim 报 `RECLAIM_TARGET_ALIVE` | 认领会话仍存活（agents 注册表证实）——不是回收对象；等它 report 或让该会话自行处置 |
| reclaim 报 `RECLAIM_UNPROVEN_DEAD` | 存活无法证实（CLI/查证不可达）且 claim 未达 60min 阈值——宁等多收；达阈值后重试或换 dsh 会话执行 |
| rollback 报 `ROLLBACK_REQUIRES_UNQUALIFIED` | 该节点证据合格——不该回退，settle 它即可 |
| rollback 报 `ROLLBACK_NO_PREVIOUS_STAGE` | 旧版错误（已由显式 -To/-Phase 目标取代）：回退目标不再从 parent 推导，链头回退 REQ 用 `-To "PM" -Phase REQ` 直接表达 |
| rollback 报 `ROLLBACK_GRAFT_FAILED` | prune 已完成、graft 未成——**重跑同一条 rollback 命令**（剪枝签名幂等续跑守卫：自动从 graft 步续起，不二次剪枝） |
| 推送失败（status 可见 pushes 账目） | `session-create` 类：status 触碰自动重试；`pointer` 类：人工 `dispatch -NodeId` 重推（防会话堆积） |
| 双规划者误起 | 启动即被 start-role 前置校验拒绝（`PLANNER_RUN_ACTIVE`，附 run 信息与 `-RunId` 续跑指引；`-Force` 强启创建通道后命令级仍有 `LEASE_HELD` 防线，不产生第二个有效规划者）；确认原会话已死后 `lease -Takeover` 留痕接管 |
| promulgate 报 `RUN_EXISTS` | 该归档已颁布过，用 `status/resume -RunId deliver-<归档名>` 续跑 |
| promulgate 报 `REVIEW_FILE_INVALID` / `REVIEW_TASK_NOT_FOUND` | ReviewFile 契约违规（解析/schema/字段一致性/指向不在归档）——按错误消息修正 ReviewFile 后重试；错误均发生在建树前，无部分状态残留 |
| promulgate 报 `REVIEW_EXCLUDED_DEP` | 某任务依赖被驳回排除的任务—— planner 补裁定该任务（`depends_on_override` 或一并驳回），依赖不会被静默丢弃 |
| promulgate 报 `ACCEPTANCE_CRITERIA_MISSING` | 归档 ≥2 条子需求但 overview.md 缺「## 整体验收判据」（既无条目也无显式声明）——按 overview-template 补判据条目（用户可感知完整场景 + 可检验形态 + 覆盖子需求映射），或写一行「无整体判据（理由：…）」显式声明后重试（错误发生在建树前，零残留） |
| promulgate 报 `CONVENTIONS_MISSING` | DESIGN 并行链头 ≥2（多 CTO/UX 并行设计）缺架构/风格约定——review 步产出 `report/architecture-conventions.md` 后 promulgate 补 `-ConventionsFile <path>`（错误发生在建树前，零残留）；单设计/串行设计/非桥接 run 不触发 |
| settle/dispatch 报 `NODE_HELD_BY_CONFLICT` | 节点在未决冲突内（design 恒拒；file 双活跃方互拦）——先处置冲突：调和/归属划分/串行化后 `conflict -Action resolve -ConflictId <C<n>> -Ruling <结论> [-Serialize <早者节点>]`，涉事节点自动恢复推送；设计冲突**不得默默二选一**，调和不成上报用户裁决 |
| 冲突要上报用户裁决 / 用户不在场 | `conflict -Action open -ConflictId <C<n>> -ConflictStatus escalated -Escalation '<呈用户的问题>'`（裁决落地后 `resolve -Ruling '<用户裁决>'` 留痕）；用户不在场 → `-ConflictStatus suspended` 挂起涉事链并上报（不阻塞无冲突任务，status/resume 持续可见） |
| conflict 报 `CONFLICT_NOT_FOUND` / `CONFLICT_ALREADY_RESOLVED` / `CONFLICT_ENTRY_INVALID` | 条目不存在（见 status `conflicts` 视图）/ 已 resolved（裁定变更按**新条目**重开，注册表只追加不改写）/ 条目参数违规（kind=file 缺 -Files、resolve 缺 -Ruling/-Serialize、状态属性更新缺 -ConflictStatus 或 escalated 缺 -Escalation）——按消息补参 |
| 设计产物带 `DESIGN_MAP_INVALID` 警示 | 变更地图行不合机读契约（`<仓库根相对完整路径>` + `[op]` 标注）或旧格式——**警示级不阻塞流转**，但机械文件重叠检测对失明文档降级人工核对；按 rdd-cto/design-template.md 行格式修正设计产物后下次触碰自动重扫 |
| status 报「回执偏差」警示 | DEV 回执 citations 超出其设计变更地图文件集——软核对警示不阻塞：核对变更地图是否漏报/写错（重叠检测失明风险），必要时修正设计产物或在交付说明中交代偏离 |
| conclude 报 `ACCEPTANCE_PENDING` | 整体验收闭环未收口——核对全部子任务已 settle 且 `[集成/联调]`/`[整体验收]` 两节点均已 settle；若仅 §3 总结论缺失/不可判，在 tests/integration-acceptance.md §3 补写一行『总结论：通过』或『总结论：不通过』后重跑 conclude（验收节点已 settle 无需重做） |
| conclude 报 `ACCEPTANCE_NOT_PASSED` | 整体验收结论=不通过——失败点见 tests/integration-acceptance.md §2（借「覆盖子需求映射」定位责任任务链）；按处置纪律走 reclaim/rollback 返工并重走集成/整体验收，结论翻转前 conclude achieved 恒被拒（需求边界外的返工流程以此为检测与记录点） |
| promulgate 报 `PLAN_MISSING` | 未传 `-PlanFile`——先按「长程规划与滚动追踪」节产出规划文件（阶段/批次/集成验收点/风险取舍，从 task.json 推导），再颁布（错误发生在建树前，零残留） |
| promulgate 报 `PLAN_FILE_INVALID` / `PLAN_ORDER_INVALID` / `PLAN_BATCH_INVALID` | 规划文件契约违规：schema/要素缺失、任务覆盖不全/幽灵 id、依赖落在更后阶段（同阶段合法，批次管细序）、依赖边落在同一批次内——按错误消息改 PlanFile 后重试（建树前零残留） |
| claim/dispatch 报 `NODE_BLOCKED_BY_GATE` | 任务在未过闸的阶段之后——settle 对应 `[集成验收·S<k>]` 节点（真实执行集成验收）开闸，或 `replan` 重划阶段；**无 Force 旁路**（闸门只增不减） |
| conclude 报 `STAGE_ACCEPTANCE_PENDING` | 整体验收已通过但仍有阶段集成验收点未 `passed`——settle 报告中的 `[集成验收·S<k>]`/`[整体验收]` 节点后重跑 conclude；被失效波退回 `planned` 的验收点需重新走完阶段任务并再次验收 |
| replan 报 `MISSING_REASON` / `REPLAN_NOT_ACTIVE` | `-Reason` 必填（偏差说明入 revision 台账）；run 已结案或无 plan 段则不可 replan——续跑请从归档侧重新规划 |
| status/resume 报 plan 相关 warning | 巡检自动记账的偏差（order/scope/delay）已在 plan-log.jsonl；按「长程规划与滚动追踪」节走 replan 修正或按提示 settle 验收节点 |
| 用户推翻 planner 审查裁定 | **建树前**：直接改 ReviewFile 重产出（promulgate 未消费，无残留）。**run 已颁布**：误合并 → `rdd-flow reopen` 恢复被并入方（deprecate 非不可逆）+ 规划者经 `deps`/graft 补树内调整；误驳回 → PM 按驳回协议辩解翻案或 `rdd-flow reopen`，修订后经后续 run/正常流程承接。裁定推翻过程在会话内向用户留痕说明 |
| status 报 `BRIDGE_FORMAT_UNSUPPORTED` | 旧版 v1 桥（零兼容裁定）：重新 promulgate 或按本协议人工处置存量 run |
| 需求/设计不可行 | 走 `rdd-engine/references/rejection-protocol.md` 驳回协议移交上游 |

## 运行产物（run 目录内，gitignore）

| 文件 | 语义 |
|------|------|
| `bridge.json` | **v2**：节点↔TaskId 权威映射（1:N）+ `goal_root` 锚 + `goal`（原始需求标题/来源）+ `pushes` 推送账目（node/at/ok/error/retry_class）+ pending_sync 分歧账 + `review` 段（`-ReviewFile` 颁布时：reviewed_at/reviewer/verdicts/applied_at，机器可读审计）+ `acceptance` 段（整体交付闭环：`status: planned→grafted`/`basis`/`criteria_ref`/`integrate_node`/`accept_node`/`conclusion`，planned 起全程占位可见；缺键=旧 run 逐字节兼容）+ `plan` 段（长程规划当前态：revision/source/stages[]（task_ids/batches/goal/milestone）/acceptance_point（criteria_items/slice/node/status: planned→grafted→passed）/risks；缺键=旧 run 逐字节兼容）（v1 拒读 `BRIDGE_FORMAT_UNSUPPORTED`，零兼容裁定） |
| `plan-log.jsonl` | 长程规划滚动台账（append-only）：`P<n>` progress（plan_promulgated/settle/acceptance_grafted/acceptance_passed/acceptance_node_settled）+ `D<n>` deviation（order/scope/delay/rollback/reclaim/acceptance_invalidated，含 trigger/key/blocked_by 等 detail）+ `R<n>` revision（replan：reason/revision/changes[]）；坏行隔离 `plan-log.jsonl.corrupt` 续写，账本永不重写（见「长程规划与滚动追踪」节） |
| `planner-lease.json` | 会话租约（holder / acquired_at / taken_over_from 留痕） |
| `sessions.json` | 会话花名册（planner-session-roster）：本 run 派生的全部 dsh 会话——本体（promulgate/resume 自动登记）/ 桥接派发（推送回写）/ 直交（register-session 登记）；字段 session_id/role/node/label/source/title/created_at/updated_at，status 经 sessions 字段透出 |
| `report/review.md` | 需求审查结论（仅 `-ReviewFile` 颁布的 run）：逐条 verdict 表（结论/理由/处置/时间），呈现用户的人读持久化载体 |
| `decisions.jsonl` | 决策账本（仅 `-AutoMode` 颁布的 run）：追加式条目流 `D<n>`（kind=auto/escalation/resolution/overturn，含 checkpoint/风险/规则/输入/依据/代答者/引用条目），未决升级视图 join 派生、账本永不重写（见「纯自动模式」节） |
| `report/delivery-annex.md` | 结案附录（根目标达成状态——有未决驳回时如实呈现「部分达成」+ 每任务终态（含树内合并/驳回注记）+ 阶段链 + **「整体验收结论」区**（判据引用/验收链节点/交付记录指针/总结论）+ rdd-flow check 结果） |
| `report/design-conflicts.md` | 并行协作冲突治理人读镜像（登记表 + 处置历史，追加不改写）；机器可读单源 = bridge.json `conflicts` 段（`C<n>`/kind/nodes/tasks/files/detected_by/status/escalation/ruling/serialize/history） |
| `report/architecture-conventions.md` | 架构/风格约定载体副本（`-ConventionsFile` 注入；DESIGN 链头 node.task「架构约定：<path>」引用，bridge.json `conventions` 段落指针） |
| bridge.json 新增可选段 | `conflicts`（冲突注册表）/ `design_maps`（变更地图机读派生缓存：files/counts/warnings/fingerprint/citation_deviations）/ `conventions`（约定指针）——缺键=引入前旧 run 逐字节兼容 || （goal-tree 既有）tree.json / ledger.jsonl / round-*.md / final-report.md | 树状态 / 回调账本 / 轮快照 / 结案报告（目标根锚时含「根目标达成状态」区） |

> 桥接 run 目录：`.rdd/goal-trees/deliver-<归档名>/`。非桥接的 goal-tree run 与普通 rdd-flow 流程行为与引入桥接前完全一致（回归硬约束，由 delivery-bridge-verify 断言）。

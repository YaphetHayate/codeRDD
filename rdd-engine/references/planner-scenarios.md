# 规划者场景细则（planner-scenarios）

> `planner-guide.md` 的场景下沉层：交付编排生命周期 / 交付角色分工 / 长程规划 / 交付回调四查 / 运行产物 / 需求审查门 / 收尾验收 / 并行冲突 / 设计审查 / 纯自动模式 / DEV 质量凭据 / 范围缺口派生。核心命令与硬约束见 planner-guide.md；本文各节仅在对应场景触发时阅读。

## 交付编排生命周期（planner-delivery，主体：大需求）

> **适用**：PM 归档后 `rdd-flow next` 输出 `longTask.triggered=true`（≥2 条非 deprecated 子需求且 ≥1 条进行中）时接管整批交付；或交付中断后由任意新规划者会话续跑。同归档重复启动被 `PLANNER_RUN_ACTIVE` 拒绝（续跑入口 `-RunId`）。

```
PM 归档（longTask 信号触发）→ start-role -Role PLANNER -TaskJson ...（或用户直接启动）
  1. review      需求审查门（建树前）：派需求审视子代理（机械模板，独立上下文）
                  产 ReviewFile → 呈用户 → promulgate -ReviewFile 机械消费
                  —— 细则见 §需求审查门
  1.5 规划       产出 PlanFile（必做，缺 → PLAN_MISSING）——见 §长程规划与滚动追踪
  2. promulgate  颁布：归档任务集 → goal-tree run（目标根 + 需求容器(type=sub) + 角色槽
                  + 阶段链 + 依赖推导；缺省形状 wake——引擎 1.2.0 起，`-Shape legacy`
                  为存量兼容路径）
                  → 尾部自动推送全部无前置依赖节点
  3. （推送即调度）角色会话被自动拉起，第一动作 bridge claim
  4. （worker）claim → 干活 → 完成即 leaf report 回调规划者
                  （不 start-role 直交下游、不启动 PLANNER——worker 侧规则见各角色卡）
  5. settle      四查门禁 → 阶段内收窄/末位汇聚/切换下阶段 → 自动推送新解锁节点；
                  四查不过即拒（不合格交付不流转）——同阶段重做走 reclaim，
                  跨阶段回退走 rollback（剪枝+重建+路由回退+自动重推；仅限活跃
                  任务上 report 未过四查的交付，已 completed 的事后返工不在此列
                  ——见 §交付角色分工与裁定触点 速查 7）
  5.5 设计审查门  阶段边界五查汇聚：派评审子代理产 DesignReviewFile
                  → design-review -Action submit 契约入库（pass 放行 IMPL，fail 自动
                  重做波）；缺键 legacy run 照旧 graft [设计审查·S<k>] 节点结算
                  —— 细则见 §设计汇聚审查
  5.6 需求派生    run 中途范围缺口 → derive（用户确认硬门）→ PM 起草新需求文档
                  → 受控入册 → replan 吸收并入当前 run——细则见 §范围缺口派生
  6. 循环 4-5；中断后任意新规划者会话 resume 续跑（status 触碰兜底补推漏推节点）
  7. 集成验收链  全部子任务终态 → [集成/联调]（DEV）→ [整体验收]（QA）
                  —— 细则见 §整体验收闭环
  8. conclude    结案：全部任务终态 + ACCEPT 结论=通过 硬门 → final-report
                  + delivery-annex.md（含 rdd-flow check 与「整体验收结论」区）；
                  未完结派生（proposed/confirmed/registered 未终态）拒结
                  （DERIVATION_PENDING）——单 run 收敛
```

**职责分工**：推送全自动（解锁即推、同 task×role 存活会话复用、session-create 类失败自动重试），规划者的工作收敛为**裁定**（settle / reclaim / rollback / replan）与**异常处置**（pointer 类推送失败人工 `dispatch` 重推、依赖调整、驳回移交、冲突调和）。长任务纪律：等 > 询问用户 > 回收。

**等待期纪律（对账跟决策走，决策跟事件走）**：回调通知与自动推送仍是**尽力而为的运输层**，但兜底已机械化——面板 watcher 定时臂（整/半点）扫描活动树，凡存在**已回调待裁决**（reported 未 settle）节点且规划者 30 分钟内无活动（双谓词：`idle` 且无近期会话事件），即带统一清单唤醒（digest；即时回调可能未达/丢失时由此补位）。因此：
- **被唤醒 = 消息自带待决事实**（单条回调或 digest 清单）：先处理清单内节点，**不做全局 status 对账**；仅当处置需要全树视野（graft 下探方向、rollback 波及面判断）时查对应 run。
- **升级投递零对账**：消息自带裁定上下文（checkpoint/question/inputs），呈用户 → `decide` 记账，消息内闭环。
- **主动 status 仅三种时机**：处置失败排障（按 `SETTLE_EVIDENCE_REJECTED` / `ROLLBACK_GRAFT_FAILED` 等错误指引查对应 run；pointer 类推送失败 `dispatch` 重推亦在此列）／用户询问态势／**静默自检**（>1h 无任何唤醒且存在在途认领——运输层可能整体停摆，含定时臂自身，查一次确认）。
- **「没收到通知」≠「没发生」——以 status/ledger 为准，不以 inbox 为准**——不变；变的只是查询时机：从「每次唤醒」收窄到「决策/排障/被问」。

**阶段链模型**：任务路由带 `phase`，全序 `REQ → DESIGN → IMPL → VERIFY → 完成`；阶段内角色白名单并行（DESIGN = CTO∥UX∥QA，QA 测试先行——尽量与 CTO 同期而非堆到 VERIFY，见速查 6）。多 owner 任务颁布时同需求各角色共享一个需求容器、每角色一个槽（wake 缺省形状，引擎 1.2.0 起；`-Shape legacy` 下仍为每角色一个链头节点）；settle 阶段感知：阶段内收窄不流转，最后一个 owner settle 才整组切换阶段并收敛 graft 下一阶段。rollback 显式 `-To <角色集> -Phase <REQ/DESIGN/IMPL/VERIFY>` 指定回退目标（回退 REQ 可达：`-To "PM" -Phase REQ`）；展示面用 `∥`（阶段内并行）/`→`（阶段间）渲染。旧归档（phase=null）保守降级为原线性链行为。阶段白名单真源 `references/phase-model.md`。

**依赖**：promulgate 从各需求文档「依赖关系」字段机读推导（标注格式以 `rdd-pm/references/requirement-item-template.md` 为准；单遍建树只回连先建节点，前向引用需审查门 `depends_on_override` 兜底，引擎自动缝合缺边）。运行中调整走 `goal-tree deps add/remove`（DAG 校验 + 审计）——**remove 命中颁布落账的裁定边（`state/adjudicated-deps.json`）须 `-UserVerdict <用户裁决原文>`**（`DEP_ADJUDICATED`）：这类边是需求级排序门，静默拆除会让依赖任务提前解锁且 `bridge.dep_task_ids` 与活树脱钩（status 的 `deps_integrity` 对账警示可查）；确需改序默认走 `replan`。目标根（承载归档原始需求）不可认领、不参与依赖，是 conclude 的终局锚点。

## 交付角色分工与裁定触点（裁定视角）

> **用法**：这四张表是你的裁定依据——settle 前拿回调的 `citations`/`full_report` 对照「主产物落点」判断交付是否真正回应了节点任务；判不合格时按速查选 reclaim 还是 rollback；`derive -Owners` 取值、conflict 调和责任人同样以此为准。
>
> **非双源声明**：本表是**规划者裁定视角的摘要**；worker 侧行为载荷真源在各自角色卡（`rdd-<role>/SKILL.md`），阶段白名单真源在 `references/phase-model.md`——冲突时以那两者为准，本表只服务于裁定判断，不得作为派发 prompt 的正文引用。

### 路由角色（桥接链上：`PhaseRoles` 白名单，可建节点 / 可 claim）

| 角色 | 阶段 | 一句话职责 | 主产物落点（citations / full_report 抽查锚） | 交付凭据特征 |
|------|------|-----------|--------------------------------------------|--------------|
| **PM** | REQ | 把用户意图变成可执行需求集（含依赖关系、验收标准），归档时建 task.json | `<归档>/requirements/overview.md`（`## 整体验收判据` 固定段在此）· `requirements/<需求>.md` | 无特化门，四查通用 |
| **CTO** | DESIGN | 定技术方向五问（技术/模块/关键要素/配置/涉及文件），不写实现 | `<归档>/design/<需求>-cto.md` · `<需求>-cto-decisions.md` | 无特化门 |
| **UX** | DESIGN | 需求/参考图 → 可执行设计规格（具体值而非感受词）；必要时出视觉稿与设计系统累积 | `<归档>/design/<需求>-ux.md` · `design/mockups/`（`.html` / `.png` / `manifest.json`）· `.rdd/design-system/`（`tokens.md` / `components.md`） | 无特化门 |
| **QA** | DESIGN | **测试先行（期望默认，非可选）**：只依需求设计用例规格（禁读 CTO 设计文档，保独立性）——用例在 DESIGN 成型，VERIFY 只做验收执行 | `.rdd/tests/{feature}/cases.json` · `.rdd/tests/index.json` · `<归档>/tests/cases.json` | 无特化门 |
| **DEV** | IMPL | 按需求/设计实现代码并自测；**提交交 QA**（本阶段不 commit） | 业务代码改动 · `<归档>/dev/implementation-notes.md` | **角色交接门**：变更集触及 `.ps1` → `extras.quality_scan` 必填（code-metrics 凭据，`violation_count=0`）；无 PowerShell 变更走 `skip` + reason |
| **QA** | VERIFY | 独立验收执行，功能 + 质量双通过后执行提交（用例应已在 DESIGN 成型——若在这里才从零写整套用例，说明路由漏了 QA 先行，见速查 6） | `<归档>/tests/verification-report.md` · `tests/cases.json` · 项目测试代码 | citations = 验收证据 |

### 树级节点角色（无 TaskId，一批一会话，claim 走树级分支）

| 节点 | 角色 | 职责 | 产物 / 门 |
|------|------|------|-----------|
| `[集成/联调]` | DEV | 真实串联各模块跑通原始需求整体场景（**不是**各模块独立跑通子验收） | citations · `tests/integration-acceptance.md` §1 |
| `[整体验收]` | QA | 对照 overview 整体验收判据逐条核验真实链路 | 同文件 §2 / §3（§3 总结论 = conclude 硬门读源） |
| `[设计审查·S<k>]` | AUDITOR | 阶段边界汇聚五查，pass 才放行 IMPL | `review/design-review-S<k>.json` + 同名 `.md`（角色交接门 `Test-DesignReviewFile`） |

> 建树前的**需求审查门不是节点**：AUDITOR 的 ReviewFile 由 `promulgate -ReviewFile` 机械消费（硬约束 6），只有设计汇聚审查才物化为树级节点。

### 非路由角色（不在 `PhaseRoles` / claim 白名单，run 内不建节点）

| 角色 | 定位 | 在 run 内怎么处理 |
|------|------|------------------|
| **AUDITOR** | 独立审视（事前把关：需求侧 + 设计侧） | 只经需求审查门 + 树级设计审查节点登场（该节点自带 `role=AUDITOR`）；非 task.json 路由角色 |
| **EVAL** | 验收评价（回顾性复盘，产出评价报告） | **不可建/不可领节点**（claim 白名单 = `PM/CTO/UX/DEV/QA`）；树外直交由用户驱动，或经 `register-session` 登记入花名册（仅溯源，不产生节点） |
| **PSE** | 项目上下文文档（README / AGENT / code-quality） | 同上 |

### 裁定触点速查

1. **settle 语义复核**：`citations` 与该角色「主产物落点」不匹配（例：IMPL 节点只报测试文件、无实现改动）→ 机械四查可能通过但语义空洞，**照拒**（reclaim）。
2. **不合格回退方向**：需求侧 → `rollback -To "PM" -Phase REQ`；设计侧 → `rollback -To "CTO+UX" -Phase DESIGN`；实现侧 → 同阶段 `reclaim`（reclaim 只在本阶段重做，跨阶段一律 rollback——但 rollback 仅限**活跃交付 report 不合格**；任务已 completed 的事后缺陷见 7）。**会话复用差异**：`reclaim` 无需传 SessionId——引擎从节点 claim 边车读原认领会话，探活后把重做指针+失败清单投回**原会话**（in-place，上下文连续即"缓存复用"），死会话才剪枝重建（`-NoReuse` 强制走重建）；`dispatch` 同理两级复用（节点现绑会话 → 同 task×role 存活会话）；**`rollback` 例外**：重建节点不复用原会话（inplace-redo v1 边界，进全新会话）——在意会话连续性优先 reclaim，必须跨阶段时接受换会话。
3. **中途派生**：`derive -Owners` 只能取 DESIGN 白名单子集（`CTO` / `UX` / `QA`，可组合）——派生的是新需求，入册后落 DESIGN 相位。
4. **冲突调和责任人**：`design` 冲突的调和结论出自设计生产者（CTO/UX），你裁定一致性并留痕；`file` 冲突的归属划分落在实施者（DEV）。
5. **QA 两次登场**：DESIGN（用例设计）与 VERIFY（验收执行）是同一角色的两段职责——不要因"QA 已在 DESIGN 出现"就把后续 VERIFY 节点当重复而剪枝。
6. **QA 尽量先行（与 CTO/UX 并行，不堆到交付尾部）**：QA 用例设计只依需求文档、对 CTO/UX 设计**零依赖**（禁读设计文档正是独立性根基），owner 集含 QA 即自动获得并行链头——用例在设计期成型，验收只剩执行。**接管/建树前审查时留意路由**：有可测验收标准的任务若 owner 集不含 QA，QA 就只会在 VERIFY 出现，整套用例被推迟到实现完成之后才开始写（最重的工作串行化到尾部）——建树前呈报用户或回流 PM 补路由（`set-route -To "CTO+UX+QA" -Phase DESIGN`；建树前 task.json 归 PM 管辖，不触硬约束 2 的双写禁区）。回退 DESIGN 且用例需返工 → `-To "CTO+UX+QA"` 把 QA 一并带回。
7. **事后缺陷（任务已全链 settle / completed）不走 rollback**：引擎硬语义 `TASK_NOT_ACTIVE`——rollback 只覆盖**活跃**桥接任务的流转，completed 后的返工明确落在 `rdd-flow reopen` 语义。处置：`rdd-flow reopen`（如 `-To DEV`）把任务拉回活跃 → 按 rdd-flow 标准流转重做（树侧既有节点已终态，**不手工重建**；是否/如何再入桥接编排呈报用户裁定）。产品反馈可先在 run 目录 `report/` 落缺陷清单留痕（好习惯，非必需）——rollback 的失败上下文本就由引擎自动写入；失败清单指针是 `reclaim -FailureRef` 的参数。

## 长程规划与滚动追踪（long-task-planning）

> 长程交付 = 规划先行 + 滚动追踪 + 只增不减的阶段闸门。规划是对交付的显式承诺；任何偏差都必须经 `replan` 修正，不允许口头带过。

**三载体**：PlanFile（`plan.json`，颁布时的规划承诺，必填）· bridge.json `plan` 段（当前态，闸门判定唯一读源）· `plan-log.jsonl`（append-only 事件台账：进度/偏差/修订）。

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

**规划方法**（从 task.json 推导）：

1. 读 overview「## 整体验收判据」+ 各需求「依赖关系」，按**交付批次**划分阶段：被依赖的基础/独立需求在前（S1），依赖它们的后续需求其后（S2…）；K=1（单阶段）合法且行为等价旧版。
2. 每条交付任务恰在**一个**阶段（`PLAN_FILE_INVALID`：全覆盖、无幽灵 id；不交付的 deprecated/树内合并/驳回回流豁免）。
3. `batches` = 阶段内可并行批次：依赖边不得落在同一批次（`PLAN_BATCH_INVALID`）、依赖不得落后于被依赖者所在阶段（`PLAN_ORDER_INVALID`；同阶段合法，批次管细序）。
4. 每阶段 `acceptance_point`：从整体验收判据选该阶段应可验证的**子集** + 一个可运行切片形态（缺一 → `PLAN_FILE_INVALID`）。k<K 的验收点在阶段任务全部终态时自动 graft `[集成验收·S<k>]`（role=QA）；末阶段绑定 R1 `[整体验收]` 节点。

**阶段闸门（只增不减）**：任务推送/认领要求其之前所有阶段的 acceptance_point 均 `passed`（未过闸 → `NODE_BLOCKED_BY_GATE`，**无 Force 旁路**——出路只有 settle 对应 `[集成验收·S<k>]` 或 replan 重划阶段）。回退/回收/replan 波及已验收阶段时，引擎自动失效该阶段及之后的验收点（防闸门虚开）。偏差由引擎在五个观测点自动记账（settle / reclaim / rollback / status 巡检 / replan），修正只走 `replan -RunId <id> -PlanFile <修订版> -Reason <偏差>`（`-Reason` 必填；run 已结案或无 plan 段报 `REPLAN_NOT_ACTIVE`）。

## 交付回调与四查门禁

worker 完成即经 `goal-tree-leaf.cmd -Command report` 回调**你**（回调自动送达当前有效规划者会话——新鲜租约优先）。投递是**通知层**（dsh 下经插件 watcher），**可能缺席**——账本 `ledger.jsonl` 与节点 `reported` 态才是权威信号：回调未达时 `status -RunId` 一样能看到，勿据「未收到通知」判定 worker 未完成、更勿据此干等（等待期对账纪律见 §交付编排生命周期）。各角色的产物落点与凭据特征见 §交付角色分工与裁定触点；下表是字段语义：

| 回调字段 | 交付语义 |
|----------|----------|
| `verdict=done` | 交付自评完成（未 done 不得 settle） |
| `citations[]`（`ref`=真实路径） | 改动清单（settle 逐条校验路径存在） |
| `full_report` | 主产物文档指针（设计文档/实现说明；据此呈现 Doc 行，凭单条消息即可裁定） |
| `extras.verification` | 验证结果（lint/test/build 摘要；缺失即拒） |
| `extras.quality_scan` | DEV 出报必填（.ps1 变更时 code-metrics 凭据，violation_count=0；无 PowerShell 变更走 skip 形 `{skip:true,reason}`；完整字段与机械判定 R1-R6 见 §DEV 质量扫描凭据） |

**真实性判断由 QA 阶段节点承担**：QA 会话的 citations = 验收证据，QA 节点 settle 即任务 complete。**QA 判不合格** → 回调带非 done verdict + 失败清单（full_report/extras）→ 你二选一：**同阶段重做** `reclaim -NodeId`（问题在本阶段可修；失败清单自动组装）或**跨阶段回退** `rollback -NodeId -To <角色集> -Phase <阶段> -Reason <理由>`。

## 运行产物（run 目录 `.rdd/goal-trees/deliver-<归档名>/`，gitignore）

| 文件 | 语义 |
|------|------|
| `bridge.json` | v2 权威映射：节点↔TaskId + goal 根锚 + pushes 推送账 + pending_sync + review/acceptance/plan/conflicts/design_maps/conventions/**derivations** 段（缺键=旧 run 兼容；v1 拒读） |
| `plan-log.jsonl` | 长程规划台账：`P<n>` 进度 + `D<n>` 偏差（含 `scope_derived`）+ `R<n>` 修订（append-only，坏行隔离续写） |
| `planner-lease.json` | 会话租约（holder / acquired_at / taken_over_from 留痕） |
| `sessions.json` | 会话花名册：本体/桥接派发/直交全量清单（status 经 sessions 字段透出） |
| `report/review.md` | 需求审查结论人读镜像（仅 `-ReviewFile` run） |
| `report/delivery-annex.md` | 结案附录：根目标达成状态 + 每任务终态 + 阶段链 + 整体验收结论区 + rdd-flow check 结果 |
| `report/design-conflicts.md` | 冲突治理人读镜像（机器可读单源 = bridge.json `conflicts` 段） |
| `report/architecture-conventions.md` | 架构/风格约定副本（`-ConventionsFile` 注入） |
| `state/dispatch-log.jsonl` | 通用派发审计（`goal-tree dispatch` 真实派发逐行：node/role/worker/round/exit/at；status `dispatches` 段透出） |
| tree.json / ledger.jsonl / round-*.md / final-report.md | goal-tree 既有：树状态 / 回调账本 / 轮快照 / 结案报告 |

> **统一决策账本 `decisions.jsonl` 位于归档根**（`.rdd/changes/archive/<归档名>/`，gitignore 由归档策略管理）——非 run 目录：账本是长期分析资产，归档是长期载体。条目四要素（background/options[]/decision/reason）+ decider（user / planner / auto\<规则\>@\<stage\>）；kinds：auto/escalation/resolution/overturn（AutoMode 既有）+ derive_proposal / checkpoint / ruling（rollback/reclaim/replan/conclude/conflict-resolve 命令尾 advisory 追加 + planner-routing-refusal 拒/覆写 advisory 追加，见 §统一决策账本）。append-only 单调 `D<n>`，坏行隔离续写，旧形态缺字段容忍读。


## 需求审查门（建树前，接管归档时）

**审查输入**：task.json + 全部需求文档 + overview。**审查维度**：逐条判定子需求的独立性与合理性——与根目标一致性、粒度、依赖标注真实度、验收标准可测性。

**三级处置**：

| 结论 | 处置 | 适用 |
|------|------|------|
| `pass` | 正常建树 | 独立、与根目标一致 |
| `tree_adjudicated` | 轻度问题树内裁定：依赖错标 → `depends_on_override`；同一改动两个侧面 → `merged_into_task_id` 合并剪枝（留审计痕，不阻断其余需求交付） | 依赖标注与实际不符 / 需求重复 |
| `reject_return` | 文档级不合理 → 先按驳回协议处置再 promulgate | 需求本身有问题、需合并或拆分需求文档 |

**语义审查归属（评审内生于规划者会话，auditor-subagent-review）**：

- **新链单入口**：规划者派**需求审视子代理**（独立上下文，输入 = `rdd-engine/references/review-input-template.md` 机械清单——禁转述、禁裁定倾向注入、禁代审，见模板禁令段）生产 ReviewFile（`reviewer: "auditor-delegated"`），结论呈用户（最终裁决权在用户）后机械消费——保持「机械转发审视产物」分工，且审视上下文与规划者会话完全隔离。原「AUDITOR 缺席 → 规划者自产（reviewer: "planner"）」降级分支**整体消失**。
- **强形态分支（用户显式要求独立会话评审）**：`start-role -Role AUDITOR` 独立会话按同一模板产同一契约产物（`reviewer: "auditor"`）；dsh 后端需 preset `rdd-auditor`（产品面默认 8 组不含 AUDITOR——设计 #8：删除引擎机制（节点/AutoDispatch 推送/一批一会话），保留方法论。重建脚本 `build-dsh-presets.mjs --with-auditor` **属源码仓 `scripts/`，不随引擎包分发**——引擎安装（`.rdd/skills/rdd-engine/` 布局）内该通道缺席时**不要手工装配/安装 preset**（DSH_HOME 是用户域部署面，规划者不得代装配）；强形态本就是可选项，缺 preset 时回落子代理形态即可）。
- **reviewer 枚举（单源见模板常量表）**：`auditor-delegated`（子代理形态，新产出）/ `auditor`（强形态会话，新产出）/ `planner`（存量只读——历史值合法，不再产出）。产出必带 `production` 留痕（`{ mode: "subagent"|"session", template: "rdd-engine/references/review-input-template.md" }`，消费端容忍、审计可检）。

**ReviewFile 契约**（精确模板）：

```json
{
  "reviewed_at": "<ISO-8601>",
  "reviewer": "auditor-delegated",
  "production": { "mode": "subagent", "template": "rdd-engine/references/review-input-template.md" },
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

- `verdict` 枚举 `pass / tree_adjudicated / reject_return`；未列出的任务 = 隐式通过。`pass` 不得携带 `depends_on_override`/`merged_into_task_id`；两者不得同现于一条 verdict（合并任务不建节点）；同任务重复 verdict、指向不在归档的任务均拒。
- **前置动作**（脚本消费前审视方必须完成）：`reject_return` → 需求文档「## 驳回记录」追加行 + `rdd-flow reject -From <PLANNER/AUDITOR/AUDITOR-DELEGATED> -To PM`（见 `rejection-protocol.md`「PLANNER / AUDITOR 发起的驳回」——子代理形态驳回由规划者代递，署名 `auditor-delegated`）；`merged_into_task_id` → `rdd-flow deprecate -TaskId <被判合并的那条任务（verdict 自身的 task_id）>`——并入方（`merged_into_task_id` 指向者）必须保持可交付，误把并入方废弃会在建树前 `REVIEW_FILE_INVALID` 硬拒（误判经 `reopen` 可恢复）。
- **机械消费保证**：排除任务不建节点、不进 bridge.tasks、不被推送；依赖被合并排除的任务重定向到并入方；依赖悬空于驳回排除任务硬拒 `REVIEW_EXCLUDED_DEP`（**禁止静默丢弃依赖**——静默丢弃会让依赖方被过早推送，正是审查门要消灭的错序 bug 类）；审查显式依赖指向后位任务时经 `deps add` 延后缝合（DAG 校验 + 审计），缝合**只补缺失边**（已建边不重放：后向边由单遍建树表达，重放会撞 goal-tree `DEP_EXISTS` 并中止颁布）。
- **错误码**：`REVIEW_FILE_INVALID`（解析/schema/字段一致性）/ `REVIEW_TASK_NOT_FOUND`（task_id/override/merge 指向不在归档）/ `REVIEW_EXCLUDED_DEP`（依赖悬空）。
- **结论呈现**：`report/review.md`（人读逐条结论表）+ promulgate 返回值 `review` 段 + bridge.json `review` 段。用户可随时干预或推翻裁定（**最终裁决权在用户**）：建树前直接改 ReviewFile 重产出；run 已颁布 → 误合并 `rdd-flow reopen` 恢复 + `deps`/graft 补树内调整，误驳回 PM 按驳回协议辩解翻案或 `reopen`，会话内留痕说明。
- **结案如实呈现**：conclude 门禁豁免严格限定 `reject_return` 集；annex 根目标措辞：无未决驳回=「达成」，有=「部分达成（N 条驳回回流 PM）」；被合并任务标注「deprecated（树内合并至 #N，非放弃）」。

## 整体验收闭环（overall-delivery）

**判据载体**：`requirements/overview.md` 固定段 `## 整体验收判据`（引用锚全程稳定），条目 = 用户可感知完整场景 + 可检验形态 + 覆盖子需求映射。必填分层：≥2 条子需求必填 / 单需求快速通道豁免 / 确无整体场景以一行「无整体判据（理由：…）」显式声明——缺失且应填 → `ACCEPTANCE_CRITERIA_MISSING` 拒建树（零残留）。

**判据流动**：promulgate 校验非空 → 判据引用注入 goal 根与每个节点 task（派发记录检验点，指针 brief 同步携带）→ 设计文档 frontmatter `acceptance_ref` 引用对齐（CTO/UX 模板同构字段）。

**验收链机制（时机表达）**：全部子任务节点终态 → 自动 graft `[集成/联调]`（DEV，树级工作节点：真实串联各模块数据/调用跑通原始需求整体场景，**不是各模块独立跑通子验收**）→ 其 settle → graft `[整体验收]`（QA，对照判据逐条核验真实链路）→ 其 settle 记录结论。两节点挂目标根、不绑 TaskId（claim 跳过 flow 侧、settle 终态即止、自动推送照常）。bridge.json 顶层 `acceptance` 段全程占位可见。

**结论落点**：`tests/integration-acceptance.md` 单文件三区——§1 集成/联调记录（引用账本条目不复制，指向 `[集成/联调]` 节点回调 citations）/ §2 判据逐条核验表（借「覆盖子需求映射」定位失败点到责任任务链）/ §3 总结论（**结论必须可判**：一行『总结论：通过』或『总结论：不通过』）。`[整体验收]` settle 时解析 §3 落 `acceptance.conclusion`；不可判时 conclude 报 `ACCEPTANCE_PENDING`，补写 §3 后重试（验收节点无需重做）。

**结案硬门**：`conclude achieved` 前置 ACCEPT 结论=通过——`ACCEPTANCE_PENDING`（验收链未走完/结论不可判）与 `ACCEPTANCE_NOT_PASSED`（结论=不通过，失败点见 §2）优先于 goal 锚校验报出；不通过时 run 保持开放，失败点经覆盖映射定位责任任务链（返工复用 reclaim/rollback）。

**场景分层**：桥接 run = 上述全套；非桥接多需求 = 判据 + 设计文档 `acceptance_ref` 对齐 + QA 在 VERIFY 阶段对照判据逐条核验（不建验收链节点）；单需求/快速通道 = 豁免。旧 run（bridge.json 无 `acceptance` 键）行为不变。

## 并行协作冲突治理细则（parallel-coordination）

语义边界：本节管**编排层并行冲突**（设计互斥 / 文件重叠），与 worker 侧检查点决策账本（decisions.jsonl）、建树前需求审查分工不重叠。

| kind | 判定 | 发现途径 | 消解 |
|------|------|----------|------|
| `design` | 多 CTO/UX 设计互斥或风格不一致 | 规划者语义判断（评审设计产物） | **调和产出一致结论**（首选）→ `resolve -Ruling`；调和不成 → 上报用户裁决（escalated）；用户不在场 → 挂起涉事链（suspended）并上报 |
| `file` | 任务变更地图判出同文件重叠（精确路径匹配——保守判定是有意取舍） | 引擎推送门自动登记（亦可人工登记） | **归属划分**（首选：`reclaim rejected-delivery` + replan，让唯一任务承载该文件）/ **串行化**（`resolve -Serialize <早者节点>`：晚者依赖早者，早者 settle 后自动解锁） |

状态机：`open → resolved`｜`open → escalated → resolved`｜`open → suspended`。上报/挂起是条目状态属性（注册表只追加不改写，history 追加）；已 resolved 的裁定变更按**新条目**重开（`CONFLICT_ALREADY_RESOLVED`）。

**强制门（双触点）**：

1. **推送门**：涉事节点命中未决冲突 → `held_by_conflict`；变更地图路径重叠于并发实施节点 → 自动登记 file 条目 + `held_by_file_overlap`。手动 `dispatch` 同守此门（`NODE_HELD_BY_CONFLICT`）。
2. **settle 前置冲突门**：`design` 涉事节点恒拒；`file` 仅双活跃方互拦（对方 claimed/reported 时防并发覆盖；单活跃写者放行=先行落地即串行化前提）。

消解后下一触发点自动推送恢复，无须手动 dispatch。重叠口径 = 变更地图文件路径精确匹配；并发口径 = 两任务间无依赖路径（传递闭包）的待推/在途实施节点。

**conflict 命令族**：

| 动作 | 形态 | 语义 |
|------|------|------|
| 登记 | `-Action open -ConflictKind design\|file -Nodes <n1,n2,...> [-Files <p1,p2,...>] [-Note ...] [-ConflictStatus escalated\|suspended [-Escalation ...]]` | 注册新条目 `C<n>`（递增），涉事节点即刻被门 hold；kind=file 必带 -Files（仓库根相对路径） |
| 状态属性 | `-Action open -ConflictId <C<n>> -ConflictStatus escalated\|suspended [-Escalation <问题>]` | 上报/挂起留痕（escalated 必带呈用户的问题） |
| 消解 | `-Action resolve -ConflictId <C<n>> -Ruling '<调和一致结论/用户裁决>' [-Serialize <早者节点>]` | -Serialize 组合 `goal-tree deps add`（失败即整体拒绝、冲突保持未决） |

错误码：`CONFLICT_NOT_FOUND` / `CONFLICT_ALREADY_RESOLVED` / `CONFLICT_ENTRY_INVALID`（kind=file 缺 -Files、resolve 缺 -Ruling/-Serialize、escalated 缺 -Escalation）。全景：status `conflicts` 段（未决入 warnings）+ resume（未决=断点步骤）+ `report/design-conflicts.md` 人读镜像；机器可读单源 = bridge.json `conflicts` 段。

**架构/风格约定（多 CTO/UX 设计共同基线）**：载体 `report/architecture-conventions.md`，经 `promulgate -ConventionsFile <path>` 注入（run 目录留副本 + bridge.json `conventions` 段）。门：DESIGN 并行链头 ≥2 缺 `-ConventionsFile` → `CONVENTIONS_MISSING`（建树前零残留）；单设计/串行设计/非桥接 run 豁免。每个 DESIGN 链头 node.task 带「架构约定：<path>」，设计会话开工即见共同基线。

**变更地图机读契约**（文件冲突检测基础，`rdd-cto/design-template.md` 为准）：文件行 `` `仓库根相对完整路径`  [新增]/[修改]/[删除] 说明 `` 为硬格式；计数行与实际解析机械核对。不合契约 → `DESIGN_MAP_INVALID`（**警示级不阻塞**，机械重叠检测对该文档失明降级人工核对）；引擎将设计产物机读进 bridge.json `design_maps`（只读派生缓存，文档变化自动重解析）。

**回执一致性软核对（警示，永不硬拒）**：DEV 回执 citations 超出其设计变更地图文件集 → 偏差警示入 status/annex + `design_maps[doc].citation_deviations`——防「地图写错致检测失明」。

## 设计汇聚审查（auditor-design-stage-review）

编排层语义；五查方法论与 DesignReviewFile 生产契约（提示词素材）见 `rdd-auditor/references/design-review.md`，评审子代理输入模板见 `rdd-engine/references/review-input-template.md`。与建树前需求审查门、QA 集成验收构成三道独立审查：**建树前查需求（评审子代理/强形态 AUDITOR）/ 进实现前查设计（同左）/ 实现后查符合性（QA 集成验收）**——互不污染。

**双链总纲**（`bridge.json review_mode` 为分界，决策 #4/#7）：**新链**（promulgate 带 `-ReviewMode subagent|session`，落 `review_mode` 键）审查无节点——纯契约：触发后状态置 `ready`，规划者派评审子代理产 DesignReviewFile，经 `design-review -Action submit -Stage <S<k>>` 入库裁定；**缺键 legacy 照旧**（graft `[设计审查·S<k>]` 节点、AUDITOR 一批一会话 settle 结算，行为逐字节不变，不回溯存量 run）。

> **新颁布一律带 `-ReviewMode subagent`（dsh 下硬性）**。legacy 链的 graft 判据 `Test-AuditorDeployed` 是双探（引擎旁 `rdd-auditor/SKILL.md` 角色卡目录 or repo `dsh/presets/rdd-auditor` 任一在场即 true）——**角色卡在场 ≠ dsh preset 在场**：按 `.rdd/skills/` 布局安装角色的项目恒使探测为真，legacy 链随之落审查节点；节点需真实 AUDITOR 会话 claim+report 才能 settle，而 dsh 产品面默认 8 组 preset 不含 `rdd-auditor` → 节点不可派发、审查卡死（规划者派子代理产的 DesignReviewFile 也进不了链——submit 对缺键 run 报 `DESIGN_REVIEW_LEGACY_RUN`）。卡死处置：删除 run 目录 → task.json 复位 → 带 `-ReviewMode subagent` 重建（评审产物可直接复用 submit）；**禁止手工装配 rdd-auditor preset 进 DSH_HOME 自救**——用户域部署面规划者不得代装配，且 preset 缺席非根因（legacy 节点形态才是）。

**状态机**（`plan.stages[k].design_review`，无段 = 无门零成本）：

| 状态 | 新链语义（review_mode） | legacy 语义（缺键） | 进入 |
|------|------------------------|--------------------|------|
| `planned` | 槽位已落（新链恒落，无部署判据/零降级）待触发 | 槽位已落（promulgate 时 AUDITOR 已部署）待触发 | promulgate / 失效重置 / fail 波完成重置 |
| `ready` | **待派审**：触发达成但产物未入库（plan-log `design_review_ready` + status/next 提示双感知面，无自动会话） | —（不存在） | 全部任务越过 DESIGN + ≥1 落盘产物 + 阶段有 DESIGN 节点 |
| `grafted` | —（不存在，新链零节点） | `[设计审查·S<k>]` 已挂树待审（role=AUDITOR、无 TaskId、推送/认领/settle 走树级分支；claim 响应附 design_review 上下文：docs 清单 + design_maps + 架构约定引用 + 判据 ref） | 同上触发 |
| `passed` | `design-review -Action submit` 契约校验通过 + 总裁定推导 pass | 审查节点 settle + 契约校验通过 + 推导 pass | 裁定入库 |
| `failed` | submit 裁定 fail → 重做波进行中（波可重入；零节点回收，状态重置后覆盖重产） | 文件缺/不可解析或存在 blocking → 波进行中 | 总裁定 fail |
| `exempt` | 快速通道豁免（共享语义，无门） | 同左 | 全阶段无落盘设计产物 / 无 in-run 设计工作 |

**总裁定引擎推导**（pass ⇔ DesignReviewFile 全文档 pass 且全局零 blocking，**不采信声明值**）；契约校验与节点 settle 门**同一核心**（`Test-DesignReviewFileCore`：docs 全覆盖 / verdict-findings 一致 / finding 四字段 / 枚举值域 / reviewer 枚举 `auditor-delegated|auditor` / production 留痕形态，违规 `SETTLE_EVIDENCE_REJECTED` 带问题清单——修复重报）。

**重做波**（fail 自动，rollback 原语语义复用）：逐 blocking 归属任务（按 involved docs 后缀映射 `-cto`→CTO / `-ux`→UX / `-qa`→QA，无后缀取任务 in-run DESIGN 角色，兜底 CTO）→ prune 活跃 post-DESIGN 节点 → set-route 回 DESIGN → 兄弟挂接重建 DESIGN 组（blocking 清单注入重做上下文）→ 自动重推；重做收敛后再审（覆盖重产重审）。新链波零节点回收（审查无节点），legacy 波回收审查节点槽位。任一步失败停在 `failed`，下一触发点自愈重入（幂等）。失效波联动：rollback/reclaim/replan 波及已审查阶段 → design_review 重置 `planned` + 旧审查节点（legacy）失效回收。

**唤醒两层与段轮换（wake-rotation，引擎 1.3.0）**：重做波/reset 后的重推不再有配额死点——段配额（`wake_max`，默认 3）触顶时 push 门自动 `rotate`（同节点、段+1、强制新同角色会话、附交接包），零人工（1024 事故的结构性修复：v1 的段满=裁定点会被 `WAKE_QUOTA_EXCEEDED` 卡住等提额）。规划者只在两种情形需要出手：① **提前换会话**（判断当前会话理解已固化，不必等段满）——`goal-tree rotate`（仅交接点 pending/done 可用）；② **跨段总量触顶**（`WAKE_TOTAL_EXCEEDED`，默认 6）——真裁定点，四路由：升级用户 / 拆分需求回 PM / 带债放行 / `budget -SetWakeTotalMax -UserVerdict`。服务过旧段的会话被 claim 门（`ROTATED_OUT`）与复用解析双重退役；树徽章 `[k/K]·s<N>` 呈现世代，枯萎段留在树上供决策考古。

**感知面（新链 `ready` 待派审）**：plan-log `design_review_ready` progress 事件 + `status` 警示 + `resume` 步骤清单（含 submit 命令行）三面机械可感；**无自动会话推送**（设计 #8：删除 AutoDispatch 推送——派审是规划者动作）。规划者纪律：**settle 尾必查待审阶段**（planner-guide 硬约束 10）。

**降级与兼容**：缺键 legacy run 的 `design-review` submit 报 `DESIGN_REVIEW_LEGACY_RUN`（照旧 settle 节点通道）；legacy 链 AUDITOR 部署判据（双探：引擎仓旁挂 `rdd-auditor/SKILL.md` + 项目 `dsh/presets/rdd-auditor`，`Test-AuditorDeployed`）不变——未部署即不落段无门（旧 run 逐字节）。新链审查节点失败场景不存在；legacy 审查节点自身失败（会话死）走 reclaim dead-claim 通道。

**触发记账**：裁定落盘时引擎自动追加 `.rdd/review-ledger.jsonl`（汇总 + fail 逐 blocking 条目，reviewer 署名 = 枚举；同 dimension 同 run ≥3 次 → 回流建议条目，只建议不代建）。

**信号路由表**（审查/回流产物的去向，规划者按表处置）：

| 信号 | 去向 |
|------|------|
| DesignReviewFile 环境类错误（文件缺/不可解析/契约违规） | 新链 `submit` 门拒 / legacy settle 门拒（`SETTLE_EVIDENCE_REJECTED` 带问题清单）→ 修复重报（新链由规划者重派子代理核验或复核文件后重 submit；legacy 同会话 redo）；legacy 会话死走 reclaim |
| 审查发现需求本体空缺（验收不可测/覆盖洞/依赖错标——设计侧无法承接） | finding 呈现用户建议回流 PM（`rdd-flow reject -From <AUDITOR/AUDITOR-DELEGATED> -To PM` 按驳回协议——子代理形态驳回由规划者代递），不阻塞其余设计维度裁定 |
| 同任务/同因驳回 ≥2 次（重做波后再 fail 同因） | 建议走 RCA：升级用户裁决（conflict escalated 或规划者上报），必要时 replan 重划阶段 |
| 设计类问题（错位/失真/遗漏/跨设计不一致/DESIGN_MAP_INVALID 实锤） | 走设计审查 fail 波自动重做，不回流 PM |
| 同 dimension blocking 同 run ≥3 次 | 引擎自动追加回流建议条目（`.rdd/review-ledger.jsonl` kind=reflux_suggestion）——建议生成 CTO 模板/流程改进需求，只建议不代建 |

## 纯自动模式细则（planner-auto-mode）

**目标**：桥接 run 无人值守时 worker 侧检查点（CTO 四检查点为代表）不再无限等待——低风险按分级表自动拍板并全程留痕，高风险升级人工，run 持续推进且无静默等待。边界见 planner-guide 硬约束 7（编排层裁决不自动化）。

**开关与快照**：`promulgate -AutoMode`（默认关闭；关闭时 bridge.json/claim/status/resume 均无 `auto_mode` 键）。分级表脚本内嵌默认（R1–R9，自上而下首条命中）：

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

`-RiskPolicy <path>` 整表覆盖（JSON：`{"rules":[{"id","match","action":"auto|manual","note"}]}`，空表/重复 id/非法 action 拒 `RISK_POLICY_INVALID`，校验先于任何 run 状态创建）；**R1 硬底强制合并保留**（缺失或被改成 auto 一律强制恢复内置 R1）。生效表快照入 `bridge.json.auto_mode`（enabled + policy + policy_source），**run 内不可变**（改表经新 run 生效）。

**授权传递**：claim 是 worker 必经第一动作，纯自动 run 的 claim 响应注入 `auto_mode` 段（enabled + 分级表 + 协议指引）——worker 无需自行探测模式；旧 run 无此段。

**决策账本（decisions.jsonl，归档级统一账本）**：`.rdd/changes/archive/<归档名>/decisions.jsonl` 追加式（归档 `.decisions.lock` 内追加 + 读回校验，条目 id `D<n>` 递增；账本是长期分析资产、归档是长期载体——新旧场景一本账到底）。字段：`entry_id/at/run_id/node_id/task_id/stage/kind(auto|escalation|resolution|overturn|derive_proposal|checkpoint|ruling)/checkpoint/risk/rule_id/decision/inputs/basis/decider/ref_entry`；**四要素**（background/options[]/decision/reason）为 derive_proposal/checkpoint/ruling 标准形。代答者身份：`auto/<规则>@<stage>`（规则代答）| `user@in-session`（会话内用户裁定/推翻）| `user`（derive confirm / checkpoint——用户确认门记录）| `planner`（派生提议 / 编排裁定自动入账）；升级条目 decider=null（未决）。**未决升级视图由 join 派生**：open = 升级条目 − 被 resolution/overturn 经 `ref_entry` 引用者；账本永不重写。

**命令守卫**：`decide`/`escalate` 均要求 `auto_mode.enabled`（否则 `AUTO_MODE_DISABLED`）+ 本 stage 的 claimed 节点（`DECISION_NODE_NOT_CLAIMED`；overturn 额外容忍 reported=未 settle 重做窗口）。`decide -Kind auto` 要求规则在快照内且 action=auto（`RULE_NOT_FOUND`/`RULE_NOT_AUTO`）；`resolution` 不得重复关闭（`ESCALATION_ALREADY_RESOLVED`）；`overturn` 限 auto/resolution/escalation 条目（禁止推翻推翻）。**升级不改变 reclaim 机械规则**（存活预检优先；长任务纪律「等>询问用户>回收」不变），worker 越过未决升级推进属协议违规（settle 四查不豁免，QA 审账可查）。

**升级通知与可见性**：dsh——rdd-goal-tree 插件 watcher 并行收集 open 升级条目（5s 扫描）投递规划者 inbox（exactly-once：`decision <id>` 去重命名空间；送达即唤醒，空闲规划者会话立即开轮消费）→ 规划者呈现用户 → `decide -Kind resolution` 回填后 worker 继续。**watcher 读的就是归档级 `decisions.jsonl`**（经该 run 的 `bridge.json` → `archive_rel` 解析，run 目录位置仅作 legacy 兜底）——账本搬迁类改动必须同步改插件侧，否则升级投递静默断链。CLI/Plus——降级为 status/resume 可见（`auto_mode` 块：enabled + 逐节点决策计数 + open escalations 清单；resume 恢复步骤含逐条升级处置指引）。

**推翻通道**：未 settle 阶段内——会话内重做 + `decide -Kind overturn` 留痕；已 settle 后——善后复用 `reclaim rejected-delivery`（同阶段）或 `rollback`（跨阶段）。CTO 四检查点确认语义的条件豁免见 `rdd-cto/SKILL.md`「完成前置硬检查」纯自动模式分支（宪法原文不动；门槛达标语义不豁免；禁令类与人工分级不适用代答）。worker 的 leaf report extras 可附 `auto_decisions` 摘要（计数 + 账本路径）。

## DEV 质量扫描凭据（extras.quality_scan 完整形）

**DEV 出报必填**（角色交接门 dev-quality-prescan-gate）：code-metrics 质量扫描凭据。

- **完整形**（变更集含 PowerShell）：`tool`（工具标识与版本）/ `tool_hash`* / `base` / `files`（作用文件集）/ `thresholds` / `threshold_source`（阈值来源 `docs/code-quality.md` §1）/ `violation_count`（**必须为 0**）/ `exit_code`（**必须为 0**）/ `report_ref`*（带 * 可选）。
- **skip 形**（变更集无 PowerShell 时唯一合法）：`{"skip":true,"reason":"<理由>"}`。

**机械判定 R1-R6**：凭据缺失拒 / 结构不完整拒 / 计数非零拒 / 退出码与计数矛盾拒 / citations 含 .ps1 而 skip 拒 / citations 的 .ps1 未被 files 覆盖拒。凭据违规的 DEV 交付在 settle 前即被拦（QA 硬性项驳回轮次前置消除）；伪造凭据属语义欺骗不在机械防御面（QA 复扫双保险兜底）。非 DEV 角色未注册校验器，门空转放行。链式场景（DEV 直转 QA 的 `rdd-flow set-route`）挂同一门：DEV 退场必带 `-QualityScanFile <凭据JSON>`，缺失拒 `HANDOFF_GATE_REJECTED`。

## 范围缺口派生（planner-midrun-derive）

**适用判定**：run 中途出现「只管新增、不管改既有」的范围缺口——rollback（跨阶段回退既有交付）/ reclaim（同阶段重做既有交付）均不对症；树外直交产物又进不了当前树（结案验收覆盖不到）。**唯一消化通道是 derive**。两项用户拍板口径不可偏移：(a) 新需求**并入当前 run**（非链式新 run——单 run 收敛到结案）；(b) 用户确认门是**硬门**——无确认记录的执行请求确定性拒绝。

**全链时序**：

1. **propose**（`derive -Action propose -Title <标题> -Rationale <缺口理由> [-DependsOn <任务id,…>] [-Owners <CTO+UX+QA 子集>]`）：账本登记 derive_proposal 条目（四要素）+ bridge `derivations[]` 落 `proposed`，返回**标准呈报文案**（present_to_user）——dsh 经 tool-ask-user 呈现，CLI/Plus 会话内呈现并留痕。**零副作用**（不 graft、不派遣）。`-DependsOn` 限本 run 已交付任务 id（`DERIVE_DEP_INVALID`）；`-Owners` 只能缩窄缺省全链 CTO+UX+QA（`DERIVE_OWNERS_INVALID`；PM 自任派生 REQ 节点，不在 owner 集）。
2. **用户确认硬门**：confirm 必带 `-UserVerdict <用户裁决原文>`——裁决原文即确认记录（账本 ruling 条目，decider=user，ref_entry→提议条目）；缺失 → `DERIVE_CONFIRMATION_MISSING`，**不执行**。CLI/Plus 降级路径：规划者会话内呈现提议原文并记录用户裁决（decide checkpoint 同族纪律），再回填 confirm。
3. **confirm 落地**（顺序契约：**事实永远记录先行**）：账本 ruling 入账 → 状态落 confirmed → 预算预检（保守增量：节点 = owner数+4，goal 根宽度 +2；不足 → `DERIVE_BUDGET_EXCEEDED` **不盲目 graft**，派生卡 confirmed **不可自动重试**——出路 withdraw（获批 `budget` 扩展后可重新 propose→confirm）或另起新 run）→ graft PM 节点（goal 根子节点，node.task 注入判据增补义务与派生上下文）→ plan-log 记 `deviation/scope_derived` → 自动推送 PM 会话起草需求文档。
4. **PM 产出义务**：新需求文档（requirements/ 下，含验收标准与依赖关系如实标注）+ overview.md 增补需求索引行与「## 整体验收判据」条目——判据经锚点 live 读，验收门自然覆盖派生需求。
5. **受控入册**（PM 节点 settle）：确认记录防御性复核（无记录拒绝执行）→ 新需求文档定位（citations 中 requirements/*.md，overview 除外；缺失 → `DERIVE_REQUIREMENT_DOC_MISSING`，reclaim 重做 PM 节点）→ **桥代写** `rdd-flow add-task -BridgeRun <runId>`（task.json 单一写入方不破；remark 带 `derivation=DRV<n>` 幂等锚点；任务落 DESIGN 相位）→ bridge.tasks 映射登记 → DESIGN 链头预挂 PM 节点下（depends_on 多锚缝合到各依赖任务活跃节点）→ acceptance 段 live 刷新（single_exempt/declared 且判据已落 → 升级 planned/basis=derived_upgrade）→ plan-log 记 `progress/derivation_registered`。settle 与入册之间中断 → status 巡检幂等自愈（remark 锚点去重，不重复建任务）。
6. **replan 吸收**：registered 未吸收期间派生链头被阶段闸门 hold（`NODE_BLOCKED_BY_GATE`，消息引导 replan——**推送/认领闸门不豁免**，与 replan 覆盖校验白名单方向相反是有意设计）；replan 将派生任务纳入阶段 → absorbed 标记 + 闸门放行。之后与原生任务同轨（DESIGN 收敛 → IMPL → VERIFY）。
7. **withdraw**：proposed/confirmed 可撤（账本 ruling 留痕零副作用；未 settle 的已 graft PM 节点自动 prune）；registered 不可撤（任务在册，走 `rdd-flow deprecate`）。
8. **结案硬门**：未完结派生（proposed/confirmed，或 registered 任务未终态）→ `DERIVATION_PENDING` 拒结；withdrawn 永不阻塞。annex 含「需求派生」清单区 + 根目标行「含 N 条 run 中途派生需求并入」口径。
9. **回收**：派生 PM 节点 dead-claim / rejected-delivery 走 reclaim 同族通道（原会话存活 in-place 重做，否则 prune + 同源重建 + 重推）。

**防滥用**：`max_derivation` 缺省 3（promulgate `-MaxDerivations` 覆盖）；超限 propose 返回 `DERIVATION_LIMIT_WARNING` **警告上报不硬拒**——mid-run 范围增长本身是节奏异常信号，如实呈报用户。**预期会派生的 run 颁布时预留预算**（`-MaxNodes`/`-NodeWidth`）。

**add-task 受控门（rdd-flow 侧）**：归档处于活动 bridge run（run **顶层** `manifest.json` 的 `state` 不为 `concluded`）时，`add-task` 必须带匹配的 `-BridgeRun`（缺失 → `ADD_TASK_BRIDGE_RUN_REQUIRED`；错值 → `ADD_TASK_BRIDGE_RUN_MISMATCH`）——mid-run 范围增长必须走 derive，不得绕行直写 task.json。结案（`conclude` 写 `state=concluded`）后门即释放，归档回到 legacy 直加路径。

## 统一决策账本（checkpoint / ruling）

- **五角色检查点留痕**（`decide -Kind checkpoint -Archive <归档> -Checkpoint <名> -Decision <结论> [-Reason] [-Options A|B] [-Background] [-Role] [-RunId]`）：五交付角色经用户确认的检查点决策入账（纪律性义务，SKILL 协议层引导角色执行；无 run/节点绑定要求）。四要素 + decider=user + checkpoint/role 上下文字段。
- **编排裁定自动入账**（机械零负担，advisory）：rollback / reclaim / replan / conclude / conflict-resolve 命令尾自动追加 kind=ruling 条目（decider=planner，背景=命令与裁定内容）——规划者裁定也是决策，统一账本可分析。追加失败降级为命令 warnings，不回滚主命令语义。
- **路由拒绝与覆写**（planner-routing-refusal，规划者输出时建议性入账）：`planner-guide.md` §一 路由拒绝触发的拒与「并入」opt-in 覆写均走 `ruling` kind——拒时 decider=`planner`（背景=旧 runId + 判据三选一结果 + 新需求摘要，options=[拒、新会话、PM 路径]，decision=disposition，reason=命中判据条目）；覆写时 decider=`user`（ref_entry→对应拒条目，背景=触发词原文 + 旧树近尾声确认）。与命令尾自动入账同源，路径同归档根 `decisions.jsonl`，零 schema 改动。
- 账本文件契约见 §纯自动模式细则「决策账本」段（归档级路径、append-only、坏行隔离、旧形态缺字段容忍读）。

## 异常处置速查

命令报错/异常症状 → 处置对照表（按需查阅；核心命令语义见 planner-guide 命令面板）：

| 症状 | 处置 |
|------|------|
| 需树外直交某角色（用户裁决/事故修复） | 写 brief 文件 → `start-role -DryRun` 验证指针全文 → 实发 `-Handoff <brief>` → `register-session` 登入花名册 |
| `goal-tree dispatch` 报 `DISPATCH_FAILED` | start-role 会话拉起失败（指针类）——按 start_role.output 修正后重发即可（节点不受损仍 pending；失败已落 dispatch-log，status `dispatches.failed` 可见）；DryRun 先验指针再实发 |
| 回调收到完成、但用户已手动直交下游 | 用户显式指令优先执行，但 worker 回调先行不可省——照常四查裁定 settle（ledger 留痕对账）；撞车由 `FLOW_CLAIM_CONFLICT`/`NODE_NOT_CLAIMABLE` 兜底 |
| 同一节点第二个会话被唤起 | bridge claim 返回 `NODE_NOT_CLAIMABLE` + 认领者信息 + 可领清单，按清单改领 |
| 节点被依赖阻塞 | `NODE_BLOCKED_BY_DEPS` 附阻塞源：等上游 settle（解锁后自动推送）或 `deps remove` |
| claim/dispatch 报 `NODE_BLOCKED_BY_GATE`（消息含 replan 吸收指引） | 派生任务已入册未吸收——`replan` 将其纳入阶段（见 §范围缺口派生）；**无 Force 旁路** |
| settle 报 `SETTLE_EVIDENCE_REJECTED` | `reclaim -NodeId`（同阶段：原会话存活 in-place 重做 / 否则剪枝重建）或 `rollback`（跨阶段，见命令面板「回退」） |
| 树已 settle、flow 未流转 | `pending_sync` 自动记录；每次 status 自动重试修复 |
| 会话死在 claimed | `reclaim -NodeId`（dead-claim：存活预检 → 自动重推，新会话第一动作 claim 接管）——**先确认它真死了**：跑得久 ≠ 死 |
| reclaim 报 `RECLAIM_TARGET_ALIVE` | 目标上仍有存活会话在干——不是回收对象，等它 report。两个证据面：①边车绑定的会话探针可证存活；②边车绑定不可用（缺失/损坏/被代跑清空）时，花名册里绑到**本节点**的存活会话即证据（仅此分支生效：认领已被证实 dead 的，其回收 + 重推恰好要复用那个存活兄弟会话，不否决——见 test-inplace-redo T5） |
| reclaim 报 `RECLAIM_UNPROVEN_DEAD` | 存活不可证实且未达 60min 阈值——宁等多收；**达阈值后仍不自动放行**，见下条 |
| reclaim 报 `RECLAIM_DEATH_UNPROVEN_NEEDS_VERDICT` | 已过 60min 但存活仍不可证实（非 dsh shell / 探针端点不可达）——时间阈值不是死亡证明：**把情况呈给用户，拿到裁决原文再 `-UserVerdict "<原文>"` 重试**（裁决入归档决策账本）；别自己判死 |
| 规划者会话跑 claim 报 `PLANNER_CANNOT_CLAIM` | 认领是 worker 的第一动作，规划者代跑会劫持 worker 视图绑定（硬约束 16）——改 `dispatch -NodeId` 把节点交给 worker；真需代跑则显式 `-OnBehalfOf <label>`（代跑不写会话绑定） |
| reclaim 报 `REDO_FAILURE_REF_MISSING` | 失败清单（四查 problems + 回调 full_report/extras 自动检索）组装为空——带 `-FailureRef "<失败清单引用>"` 重试，或 `-NoReuse` 走重建 |
| reclaim 报 `RECLAIM_INPLACE_PROMPT_FAILED` | 重做指针投递原会话失败（节点零残留）——`dispatch -NodeId` 重投原会话，或 `reclaim -NoReuse` 重建 |
| rollback 报 `ROLLBACK_REQUIRES_UNQUALIFIED` | 该节点证据合格——不该回退，settle 即可 |
| rollback 报 `ROLLBACK_REQUIRES_REPORTED` | 节点非 report 态（claimed/pending/终态）——卡死认领走 `reclaim -NodeId`，待推节点等回调；rollback 只回退「report 未过四查」的交付 |
| rollback 报 `TASK_NOT_ACTIVE` | 任务已 completed——rollback 不覆盖事后返工：`rdd-flow reopen`（如 `-To DEV`）拉回活跃后按 rdd-flow 流转重做，再入桥接编排呈报用户（见 §交付角色分工与裁定触点 速查 7） |
| rollback 报 `ROLLBACK_GRAFT_FAILED` | prune 已完成、graft 未成——**重跑同一条 rollback 命令**（幂等续跑，不二次剪枝） |
| 推送失败（status pushes 账可见） | `session-create` 类：status 触碰自动重试；`pointer` 类：人工 `dispatch -NodeId` 重推（防会话堆积） |
| worker 已 report 但你没收到回调通知 | 通知层尽力而为（watcher 停摆/租约漂移可缺席）——`status -RunId` 看 `reported` 节点与 ledger 条目为权威，照常四查 settle；勿干等、勿据 inbox 有无判定 |
| 下游会话迟迟未起（如 DEV 没被派出、你在干等） | 先 `status` 对账 `pushes`/`dispatches` 账：session-create 类失败→status 触碰自动重试；pointer 类失败→人工 `dispatch -NodeId` 重推；节点 pending 且无推送记录→查依赖/冲突门（`NODE_BLOCKED_BY_DEPS` / `held_by_conflict`）。**通用树（非桥接）没有自动推送——`dispatch` 是你的主动动作**，建了树不派发就是永久等待 |
| graft/round-start 报 `ROUNDS_EXCEEDED`/`NODES_EXCEEDED`/`WIDTH_EXCEEDED` | 预算触顶：**先呈报用户，获批后同 run 只增扩展**——`budget -SetMaxRounds/-SetNodeWidth/-SetMaxNodes <n> -UserVerdict <用户裁决原文>`（硬门：缺裁决报 `BUDGET_VERDICT_MISSING`；只增不减报 `BUDGET_RAISE_ONLY`；桥接形态另支持 `-SetMaxDerivations`，裁决入归档决策账本）。扩展即生效（graft/round-start 解锁、budget_exhausted 诚实门按新上限重挂）。用户不批 → `conclude budget_exhausted` 诚实收口，续作开**新 RunId**（开工前读旧 run final-report/ledger 摘要继承上下文），**勿自行删目录重建** |
| 新 run 开出后要找回旧 run 记录 | 旧 run 目录 `.rdd/goal-trees/<run-id>/` 永不迁移、随时可查（`status -RunId <旧>` / `report/final-report.md` / `state/ledger.jsonl`）；全部 run 清单 = `.rdd/goal-trees/` 目录名。**禁止删除旧 run 目录腾 RunId**——桥接 RunId 冻结 `deliver-<归档>`，删目录重建 = 销毁全部审计记录（「删 run 重建」仅适用于颁布形态错误的死锁处置且须用户确认） |
| 双规划者误起 | 启动即被 `PLANNER_RUN_ACTIVE` 拒绝；确认原会话已死后 `lease -Takeover` 留痕接管 |
| promulgate 报 `RUN_EXISTS` | 已颁布过——`status/resume -RunId deliver-<归档名>` 续跑 |
| promulgate 报 `REVIEW_FILE_INVALID`/`REVIEW_TASK_NOT_FOUND`/`REVIEW_EXCLUDED_DEP` | ReviewFile 契约/指向/依赖悬空——按错误消息修正后重试（建树前零残留）；见 §需求审查门 |
| promulgate 报 `ACCEPTANCE_CRITERIA_MISSING` | overview.md 补「## 整体验收判据」条目或一行「无整体判据（理由：…）」显式声明——见 §整体验收闭环 |
| promulgate 报 `CONVENTIONS_MISSING` | DESIGN 并行链头 ≥2 缺架构约定——产出 `report/architecture-conventions.md` 后补 `-ConventionsFile` |
| promulgate 报 `PLAN_MISSING`/`PLAN_FILE_INVALID`/`PLAN_ORDER_INVALID`/`PLAN_BATCH_INVALID` | 按 §长程规划与滚动追踪 的规划方法产出/修正 PlanFile（建树前零残留） |
| claim/dispatch 报 `NODE_BLOCKED_BY_GATE` | settle 对应 `[集成验收·S<k>]` 开闸或 `replan` 重划阶段；**无 Force 旁路** |
| claim/dispatch 报 `NODE_BLOCKED_BY_DESIGN_REVIEW` | 等设计裁定 pass（新链 `design-review -Action submit`；legacy settle 审查节点；fail 自动重做波）或 `replan`；见 §设计汇聚审查 |
| 设计审查证据被拒 `SETTLE_EVIDENCE_REJECTED`（DesignReviewFile 契约） | 新链：按问题清单修复 DesignReviewFile 后重新 `design-review -Action submit`（状态仍 `ready`）；legacy：AUDITOR 会话按 `rdd-auditor/references/design-review.md` 修复重报，会话死走 `reclaim` |
| 新链 submit 报 `DESIGN_REVIEW_NOT_READY` | 状态非 `ready`（提前/重复提交，或 fail 波进行中）——查 `design-review -Action status`，待 `ready` 再审 |
| 新链 submit 报 `DESIGN_REVIEW_LEGACY_RUN` | 该 run 缺 `review_mode` 键（存量链）——照旧 settle `[设计审查·S<k>]` 节点 |
| legacy run 审查节点派不出 AUDITOR 会话（dsh 无 `rdd-auditor` preset / dispatch 报 `NODE_NOT_MAPPED`） | 死锁形态，preset 缺席非根因（legacy 节点形态才是）——**不要手工装配 preset 进 DSH_HOME**。正解：删除 run 目录 → task.json 复位路由 → 带 `-ReviewMode subagent` 重新颁布（子代理评审产物可复用直接 submit）；见 §设计汇聚审查 双链总纲注 |
| conclude 报 `ACCEPTANCE_PENDING`/`ACCEPTANCE_NOT_PASSED` | 验收链未收口/结论不通过——处置见 §整体验收闭环（仅 §3 缺总结论时补写后重跑 conclude） |
| conclude 报 `STAGE_ACCEPTANCE_PENDING` | 仍有阶段验收点未 `passed`——settle 对应 `[集成验收·S<k>]` 节点后重跑 |
| conclude 报 `DERIVATION_PENDING` | 有未完结派生（proposed/confirmed 挂起或 registered 任务未终态）——推进到终态或 `-Action withdraw` 撤销挂起提议；withdrawn 永不阻塞（见 §范围缺口派生） |
| replan 报 `MISSING_REASON`/`REPLAN_NOT_ACTIVE` | `-Reason` 必填（偏差入台账）；run 已结案/无 plan 段不可 replan |
| status/resume 报 plan 相关 warning | 巡检自动记账的偏差已在 plan-log.jsonl——走 replan 修正或按提示 settle 验收节点 |
| derive 报 `DERIVE_TITLE_REQUIRED`/`DERIVE_RATIONALE_REQUIRED`/`DERIVE_DEP_INVALID`/`DERIVE_OWNERS_INVALID` | propose 入参门——按错误消息补正（-Owners 只能缩窄 CTO+UX+QA） |
| derive 报 `DERIVE_CONFIRMATION_MISSING` | 用户确认硬门——先呈报提议、拿到用户裁决，confirm 带 `-UserVerdict <裁决原文>`（无记录不执行） |
| derive confirm 报 `DERIVE_BUDGET_EXCEEDED` | 预算不足且 graft 未尝试——派生卡 confirmed 不可自动重试：withdraw 撤销，或本 run 收口后另起新 run（颁布时 `-MaxNodes`/`-NodeWidth` 预留） |
| derive confirm 报 `DERIVE_ALREADY_CONFIRMED`/`DERIVE_STATE_INVALID` | 状态机守卫——confirm 一次/仅 proposed；registered 撤销走 `rdd-flow deprecate` |
| settle 派生节点降级警告 `DERIVE_REQUIREMENT_DOC_MISSING` | PM 交付未引用新需求文档——`reclaim` 重做 PM 节点（citations 带 requirements/<name>.md） |
| settle 派生节点降级警告 `DERIVE_ADD_TASK_FAILED` | 桥代写 add-task 失败（task.json 未动）——status 触碰巡检自动重试 |
| add-task 报 `ADD_TASK_BRIDGE_RUN_REQUIRED`/`ADD_TASK_BRIDGE_RUN_MISMATCH` | 归档处于活动 bridge run——mid-run 范围增长走 derive；确需直写则带匹配 `-BridgeRun` |
| propose 返回 `DERIVATION_LIMIT_WARNING` | 超防滥用阈值（警告不硬拒）——mid-run 范围增长是节奏异常信号，如实呈报用户 |
| settle/dispatch 报 `NODE_HELD_BY_CONFLICT` / conflict 报 `CONFLICT_*` | 见 §并行协作冲突治理细则（已 resolved 的裁定变更按新条目重开） |
| status 报回执偏差/`DESIGN_MAP_INVALID` 警示 | 警示级不阻塞——核对变更地图是否漏报（重叠检测失明风险），见 §并行协作冲突治理细则 |
| 用户推翻 planner 审查裁定 | 建树前：直接改 ReviewFile 重产出（未消费零残留）；已颁布：`rdd-flow reopen` 恢复 + `deps`/graft 补树内调整；会话内向用户留痕说明（详见 §需求审查门） |
| status 报 `BRIDGE_FORMAT_UNSUPPORTED` | 旧版 v1 桥零兼容——重新 promulgate 或按本协议人工处置存量 run |
| 需求/设计不可行 | 走 `rdd-engine/references/rejection-protocol.md` 驳回协议移交上游 |

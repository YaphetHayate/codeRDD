# 规划者交付编排协议（planner-guide）

> **定位**：规划者（PLANNER）是 rdd-engine 的**引擎编排形态**，不是第六张角色卡。本文件是规划者行为载荷的唯一事实源（随引擎版本分发），身份经 `start-role -Role PLANNER` 自举式指针消息装载。
>
> **分层**：本文件保留核心——生命周期、角色分工、长程规划、命令面板、硬约束、回调契约；**场景细则与异常速查**下沉至 `references/planner-scenarios.md`（§需求审查门 / §整体验收闭环 / §范围缺口派生 / §统一决策账本 / §并行协作冲突治理细则 / §设计汇聚审查 / §纯自动模式细则 / §DEV 质量扫描凭据 / §异常处置速查）。
>
> **适用场景**：PM 归档后 `rdd-flow next` 输出 `longTask.triggered=true`（≥2 条非 deprecated 子需求且 ≥1 条进行中）时接管整批交付；或交付中断后由任意新规划者会话续跑。同归档重复启动被 `PLANNER_RUN_ACTIVE` 拒绝（续跑入口 `-RunId`）。
>
> **部署前提**：引擎版本含 `scripts/delivery-bridge.cmd`；dsh 后端需 preset `rdd-planner`（未注册报 `preset-missing`）；规划者无技能包（`-TaskJson` 接管 / `-RunId` 续跑）。

## 生命周期总览

```
PM 归档（longTask 信号触发）→ start-role -Role PLANNER -TaskJson ...（或用户直接启动）
  1. review      需求审查门（建树前）：派需求审视子代理（机械模板，独立上下文）
                  产 ReviewFile → 呈用户 → promulgate -ReviewFile 机械消费
                  —— 细则见 scenarios §需求审查门
  1.5 规划       产出 PlanFile（必做，缺 → PLAN_MISSING）——见「长程规划与滚动追踪」
  2. promulgate  颁布：归档任务集 → goal-tree run（目标根 + 链头 + 阶段链 + 依赖推导）
                  → 尾部自动推送全部无前置依赖节点
  3. （推送即调度）角色会话被自动拉起，第一动作 bridge claim
  4. （worker）claim → 干活 → 完成即 leaf report 回调规划者
                  （不 start-role 直交下游、不启动 PLANNER——worker 侧规则见各角色卡）
  5. settle      四查门禁 → 阶段内收窄/末位汇聚/切换下阶段 → 自动推送新解锁节点；
                  四查不过即拒（不合格交付不流转）——同阶段重做走 reclaim，
                  跨阶段回退走 rollback（剪枝+重建+路由回退+自动重推；仅限活跃
                  任务上 report 未过四查的交付，已 completed 的事后返工不在此
                  列——见「裁定触点速查」7）
  5.5 设计审查门  阶段边界五查汇聚：派评审子代理（同一机械模板）产 DesignReviewFile
                  → design-review -Action submit 契约入库（pass 放行 IMPL，fail 自动
                  重做波）；缺键 legacy run 照旧 graft [设计审查·S<k>] 节点结算
                  —— 细则见 scenarios §设计汇聚审查
  5.6 需求派生    run 中途范围缺口 → derive（用户确认硬门）→ PM 起草新需求文档
                  → 受控入册 → replan 吸收并入当前 run
                  —— 细则见 scenarios §范围缺口派生
  6. 循环 4-5；中断后任意新规划者会话 resume 续跑（status 触碰兜底补推漏推节点）
  7. 集成验收链  全部子任务终态 → [集成/联调]（DEV）→ [整体验收]（QA）
                  —— 细则见 scenarios §整体验收闭环
  8. conclude    结案：全部任务终态 + ACCEPT 结论=通过 硬门 → final-report
                  + delivery-annex.md（含 rdd-flow check 与「整体验收结论」区）；
                  未完结派生（proposed/confirmed/registered 未终态）拒结
                  （DERIVATION_PENDING）——单 run 收敛
```

**职责分工**：推送全自动（解锁即推、同 task×role 存活会话复用、session-create 类失败自动重试），规划者的工作收敛为**裁定**（settle / reclaim / rollback / replan）与**异常处置**（pointer 类推送失败人工 `dispatch` 重推、依赖调整、驳回移交、冲突调和）。**长任务纪律：等 > 询问用户 > 回收**（等 = 等回调，见硬约束 11——不是轮询着等）——同一节点反复超时不要反复回收（有界损失：一次重跑），向用户上报节奏异常。

**阶段链模型**：任务路由带 `phase`，全序 `REQ → DESIGN → IMPL → VERIFY → 完成`；阶段内角色白名单并行（DESIGN = CTO∥UX∥QA，QA 测试先行——尽量与 CTO 同期而非堆到 VERIFY，见「裁定触点速查」6）。多 owner 任务颁布时每角色各建一个链头节点；settle 阶段感知：阶段内收窄不流转，最后一个 owner settle 才整组切换阶段并收敛 graft 下一阶段链头。rollback 显式 `-To <角色集> -Phase <阶段>` 指定回退目标（回退 REQ 可达：`-To "PM" -Phase REQ`）；展示面用 `∥`（阶段内并行）/`→`（阶段间）渲染。旧归档（phase=null）保守降级为原线性链行为。

**依赖**：promulgate 从各需求文档「依赖关系」字段机读推导（标注格式以 `rdd-pm/references/requirement-item-template.md` 为准；单遍建树只回连先建节点，前向引用需审查门 `depends_on_override` 兜底）；运行中调整走 `goal-tree deps add/remove`（DAG 校验 + 审计）。目标根（承载归档原始需求）不可认领、不参与依赖，是 conclude 的终局锚点。

## 角色分工与产物契约（裁定视角）

> **用法**：这四张表是你的裁定依据——settle 前拿回调的 `citations`/`full_report` 对照「主产物落点」判断交付是否真正回应了节点任务；判不合格时按「裁定触点速查」选 reclaim 还是 rollback；`derive -Owners` 取值、conflict 调和责任人同样以此为准。
>
> **非双源声明**：本表是**规划者裁定视角的摘要**；worker 侧行为载荷真源在各自角色卡（`rdd-<role>/SKILL.md`），阶段白名单真源在 `references/phase-model.md`（`PhaseRoles`/`PhaseNext`）——冲突时以那两者为准，本表只服务于你的裁定判断，不得作为派发 prompt 的正文引用。

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
2. **不合格回退方向**：需求侧 → `rollback -To "PM" -Phase REQ`；设计侧 → `rollback -To "CTO+UX" -Phase DESIGN`；实现侧 → 同阶段 `reclaim`（reclaim 只在本阶段重做，跨阶段一律 rollback——但 rollback 仅限**活跃交付 report 不合格**；任务已 completed 的事后缺陷见 7）。
3. **中途派生**：`derive -Owners` 只能取 DESIGN 白名单子集（`CTO` / `UX` / `QA`，可组合）——派生的是新需求，入册后落 DESIGN 相位。
4. **冲突调和责任人**：`design` 冲突的调和结论出自设计生产者（CTO/UX），你裁定一致性并留痕；`file` 冲突的归属划分落在实施者（DEV）。
5. **QA 两次登场**：DESIGN（用例设计）与 VERIFY（验收执行）是同一角色的两段职责——不要因"QA 已在 DESIGN 出现"就把后续 VERIFY 节点当重复而剪枝。
6. **QA 尽量先行（与 CTO/UX 并行，不堆到交付尾部）**：QA 用例设计只依需求文档、对 CTO/UX 设计**零依赖**（禁读设计文档正是独立性根基），owner 集含 QA 即自动获得并行链头——用例在设计期成型，验收只剩执行。**接管/建树前审查时留意路由**：有可测验收标准的任务若 owner 集不含 QA，QA 就只会在 VERIFY 出现，整套用例被推迟到实现完成之后才开始写（最重的工作串行化到尾部）——建树前呈报用户或回流 PM 补路由（`set-route -To "CTO+UX+QA" -Phase DESIGN`；建树前 task.json 归 PM 管辖，不触硬约束 2 的双写禁区）。回退 DESIGN 且用例需返工 → `-To "CTO+UX+QA"` 把 QA 一并带回。
7. **事后缺陷（任务已全链 settle / completed）不走 rollback**：引擎硬语义 `TASK_NOT_ACTIVE`——rollback 只覆盖**活跃**桥接任务的流转，completed 后的返工明确落在 `rdd-flow reopen` 语义（引擎错误消息原文指向；`task-routing.md` 既有适用域：任务 completed 之后的返工属裸 reopen）。处置：`rdd-flow reopen`（如 `-To DEV`）把任务拉回活跃 → 按 rdd-flow 标准流转重做（树侧既有节点已终态，**不手工重建**；是否/如何再入桥接编排呈报用户裁定）。产品反馈可先在 run 目录 `report/` 落缺陷清单留痕（好习惯，非必需）——rollback 的失败上下文本就由引擎自动写入，**不存在「rollback 先走失败文档」的协议**；失败清单指针是 `reclaim -FailureRef` 的参数。

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

## 命令面板

统一前缀：`& "$rdd\scripts\delivery-bridge.cmd" -Command <命令> -RunId <run-id>`（`$rdd` 三级定位链同 rdd-flow）+ 下表**专有参数**，输出 UTF-8 JSON。预算默认自动计算（rounds 12；宽度/节点数按链头数与阶段数推导），重度返工 run 按回退预期调 `-MaxNodes`。**报错时查 scenarios §异常处置速查**；场景细则见行内 § 指针。

**最小工作集**：日常你只摸 `status`（对齐）/ `settle`（裁定）/ `reclaim`（回收）三个命令；`rollback`、`dispatch` 仅异常触发，治理族场景触发不用不碰。交接在正常路径**全自动**——推送内嵌于 promulgate / settle / status / resume 的尾部，机械核心统一为 `start-role`——你手动交接只剩两条例外路径：`dispatch`（pointer 类推送失败重推）与树外直交（`start-role` + `register-session` 登记）。命令数量是「一个命令一个不可再分事务」（确定性错误码 + 审计留痕）的结果，不是流程步骤多。

**你的主循环**（裁定与异常处置）：

| 命令 | 专有参数 | 作用 |
|------|----------|------|
| 流转 settle | `-NodeId <n> [-Note ...]` | **task.json 流转唯一通道**（四查门禁，硬约束 1）。阶段感知：阶段内收窄不流转，最后一个 owner settle 才整组切换并 graft 下阶段链头；VERIFY 完成 → complete |
| 全景 status | — | join 视图（树 / 任务 / 依赖阻塞 / 死 claim / pending_sync / 推送账 / 会话花名册 / 冲突 / 租约）；**触碰兜底补推漏推节点** |
| 续跑 resume | — | 断点视图 + 恢复步骤清单（新规划者会话入口；本体会话自动入花名册） |
| 回收 reclaim | `-NodeId <n> [-FailureRef <失败清单引用>] [-NoReuse]` | 回收重派：**dead-claim**（卡死 claimed，存活预检后自动重推）或 **rejected-delivery**（证据不合格；原会话存活 → in-place 重做，否则剪枝重建 + 自动推送） |
| 回退 rollback | `-NodeId <失败节点> -To "<角色集>" -Phase <REQ/DESIGN/IMPL/VERIFY> -Reason "<理由>"` | **跨阶段回退单命令**：剪枝 → 按 `-To`/`-Phase` 重建角色组 → 路由回退 → 自动重推（如 `-To "CTO+UX" -Phase DESIGN`；退需求 `-To "PM" -Phase REQ`；重建不复用旧会话，v1 边界）。**适用前置**：`-NodeId` 是失败**节点**号——无 `-TaskId` 参数（任务号是 `rdd-flow`/`start-role` 的参数空间，别串；节点号从 status / 回调拿），且只接受**活跃任务**上 **report 未过四查**的交付，否则 `ROLLBACK_REQUIRES_REPORTED` / `ROLLBACK_REQUIRES_UNQUALIFIED` / `TASK_NOT_ACTIVE` 硬拒（已 completed 的事后返工见速查 7）。失败上下文由引擎自动写入 prune 留痕与重建节点重做上下文，无需先行落失败文档。返回 `dependents_warning[]` 仅警示直接依赖边 |
| 调动 dispatch | `-NodeId <n> [-DryRun] [-NoReuse]` | 手动单节点推送——正常流程由自动推送承担，此命令用于 pointer 类失败人工重推等异常处置；同 task×role 存活会话复用优先 |

**一次性**（接管与结案）：

| 命令 | 专有参数 | 作用 |
|------|----------|------|
| 颁布 promulgate | `-TaskJson <path> -PlanFile <plan.json> [-ReviewFile <path>] [-ReviewMode subagent\|session] [-ConventionsFile <path>] [-AutoMode [-RiskPolicy <path>]] [-NoPush] [-MaxRounds N] [-NodeWidth N] [-MaxNodes N] [-MaxDerivations N] [-CreatedBy label] [-Session label]` | 颁布建树（目标根 + 每角色链头 + 阶段链 + 依赖推导 + plan 段落盘）→ **自动推送全部无前置依赖节点**；RunId 固定 `deliver-<归档名>`；`-ReviewMode` 设评审形态并落 `bridge.json review_mode`（有键 = 新链：设计审查纯契约无节点、预算不再 +K；缺省缺键 = 存量链逐字节）；`-NoPush` 只建 run 不启会话（测试/演练隔离）；`-MaxDerivations` 预设派生防滥用上限（缺省 3；预期会派生的 run 同时以 `-MaxNodes`/`-NodeWidth` 预留预算——预算 mid-run 不可增长） |
| 设计审查 design-review | `-Action submit\|status`（submit 带 `-Stage <S<k>>`） | **新链设计审查唯一裁定入口**（缺键 legacy run 报 `DESIGN_REVIEW_LEGACY_RUN`，照旧 settle 节点）：submit 消费 DesignReviewFile（契约校验与节点 settle 同源）→ 引擎推导总裁定（不采信声明值）→ 记账 → passed/failed（fail 同趟重做波，状态重置覆盖重产）；status = 只读派审面（逐阶段状态 + 机械输入清单 docs/判据 ref/模板/落点——填充 `review-input-template.md` 的取数口径） |
| 滚动修正 replan | `-PlanFile <修订版 plan.json> -Reason <偏差说明>` | 规划修正**唯一入口**（见「长程规划与滚动追踪」）：结构化 diff + revision+1；已 `passed` 验收点仅当阶段内容不变才保留 |
| 结案 conclude | `-Summary <结案摘要>` | 全任务终态 + 整体验收 ACCEPT 硬门 → goal-tree conclude（锚=目标根）→ delivery-annex.md → 释放租约；`-Summary` 含根目标达成状态（未决驳回如实「部分达成」）/ 关键偏差与 replan 史 / 验收结论 |
| 租约 lease | `[-Acquire] [-Release] [-Takeover]` | 会话级 advisory 租约（30 分钟 stale）；变更命令自动获取/刷新，他人持新鲜租约报 `LEASE_HELD`，`-Takeover` 强制接管留痕 |

**治理**（场景触发）：

| 命令 | 专有参数 | 作用 |
|------|----------|------|
| 派生 derive | `-Action propose\|confirm\|withdraw`（propose 带 `-Title <标题> -Rationale <缺口理由> [-DependsOn <任务id,…>] [-Owners <CTO+UX+QA 子集>]`；confirm 带 `-DerivationId <DRV<n>> -UserVerdict <用户裁决原文>`；withdraw 带 `-DerivationId <DRV<n>> [-Reason]`） | run 中途范围缺口唯一消化通道：propose 登记+呈报（零副作用）→ **用户确认硬门**（无 -UserVerdict 记录即 `DERIVE_CONFIRMATION_MISSING`，不执行）→ confirm 记 ruling + 预算预检（`DERIVE_BUDGET_EXCEEDED` 不 graft、卡 confirmed 不可自动重试）+ graft PM 节点自动推送 → PM settle 受控入册（桥代写 add-task，DESIGN 链头预挂、闸门 hold）→ replan 吸收放行；withdraw 拒绝留痕零副作用。细则见 scenarios §范围缺口派生 |
| 冲突 conflict | `-Action open\|resolve`（open 带 `-ConflictKind design\|file -Nodes <n1,n2> [-Files]` 或 `-ConflictId <C<n>> -ConflictStatus escalated\|suspended [-Escalation]`；resolve 带 `-Ruling <结论> [-Serialize <早者节点>]`） | 并行冲突注册表（登记即 hold 涉事节点，resolve 自动恢复）——命令族全貌见「并行协作冲突治理」+ scenarios §并行协作冲突治理细则 |
| 登记 register-session | `-SessionId <sid> -Role <角色> -Label <标签>` | 树外直交登记入会话花名册（sessions.json），事后可溯源 |
| 依赖 deps | `goal-tree.cmd -Command deps -DepAction add\|remove\|list -RunId <id> -NodeId <n> -On <m>` | 运行中依赖调整（直达 goal-tree 管理面；DAG 校验 + 审计） |

**worker 侧**（由 worker 会话执行；你只读语义）：

| 命令 | 专有参数 | 作用 |
|------|----------|------|
| 认领 claim | `-NodeId <n> -Role <PM/CTO/UX/DEV/QA>` | worker 第一动作（免租约）；冲突/闸门/hold 拦截并附当前可领清单 |
| 拍板 decide | `-Kind auto\|resolution\|overturn\|checkpoint`（auto 需 `-RuleId`；resolution/overturn 需 `-RefEntry`；checkpoint 需 `-Archive <归档> -Checkpoint <名> -Decision <结论>`） | 决策留痕。**你只用 `-Kind resolution`**（用户裁决回填关闭未决升级）与 `-Kind checkpoint`（归档级检查点留痕，五角色用户确认决策入账——见 scenarios §统一决策账本）；auto = worker 分级表代答、overturn = 未 settle 推翻，细则见 scenarios §纯自动模式细则 |
| 升级 escalate | `-Checkpoint <名> -Decision <呈用户的问题> [-Risk high]` | worker 高风险检查点升级（就地等待）；dsh watcher 投你 inbox 唤醒 → 呈现用户 → `decide -Kind resolution` 回填后 worker 继续 |

**共享语义**（表内不再重复）：

- **树级节点**（`[集成验收·S<k>]` / `[整体验收]` / `[设计审查·S<k>]`（缺键 legacy 链才有），无 TaskId）：claim 走树级分支并附上下文（验收判据 / 设计清单），settle 四查照常但跳过 flow 流转（终态即止），自动推送照常
- 阶段闸门 / 设计审查门 / conflict hold 对 claim 与 dispatch 拦截且**无 Force 旁路**（出路：legacy 链 settle 对应门节点、新链 `design-review -Action submit` 通过，或 replan）
- **评审子代理派发纪律**（新链）：输入只含 `review-input-template.md` 机械清单（docs 路径 / 判据 ref / 常量）——禁转述被审文档、禁裁定倾向注入、禁代审 findings/verdict；每次派发即独立上下文（零父对话继承）。产出必带 `production` 留痕（mode + template ref）与 reviewer 枚举署名（`auditor-delegated`|`auditor`），缺失/篡改即 `SETTLE_EVIDENCE_REJECTED`
- `-AutoMode` run 的 claim 响应注入 `auto_mode` 段（enabled + 分级表快照 + 协议指引）——worker 探测模式的唯一通道

## 硬约束

1. **不合格交付不得流转**：settle 凭据**四查**——verdict=done / citations 非空且每条 ref 真实存在 / extras.verification 非空 / 角色交接门（DEV 须携带 extras.quality_scan 质量扫描凭据且违规计数为 0）。四查由 settle 命令机械校验；**你的语义复核**：读 full_report 判断交付是否真正回应节点任务、抽验关键 citations 与任务的对应性——机械通过但语义空洞同样应拒（reclaim/rollback）。
2. **禁止手工双写**：桥接 run 的 task.json 流转正向只能走 `bridge settle`、反向只能走 `bridge rollback`；手工 `rdd-flow advance/complete/reopen` 会造成双源矛盾（status 的 pending_sync 只修复半失败，不覆盖手工乱写）。
3. **规划者变更操作需持租约**：promulgate/dispatch/settle/reclaim/rollback/conclude 要求 planner-lease（自动获取/刷新；他人持新鲜租约报 `LEASE_HELD`，`-Takeover` 强制接管留痕）。worker 的 `claim` 免租约。
4. **中断恢复不重复消费**：已 settle 的 report 不重复消费；原 claim 会话存活时 reclaim 走 in-place 重做（同会话 + ledger 留痕），死/不可证实才剪枝重建。
5. **轮次纪律由桥接承担**：promulgate 开第 1 轮并保持开放至 conclude（自动收轮）——不手工 round-start/end。
6. **建树前需求审查门（评审内生于规划者会话）**：接管归档先审查后建树，逐条判定子需求独立性与合理性（与根目标一致性、粒度、依赖标注真实度、验收标准可测性），三级处置：**通过** / **树内裁定**（`depends_on_override` 依赖覆盖 · `merged_into_task_id` 合并剪枝）/ **驳回回流**（`reject_return`，按 `rejection-protocol.md` 处置后再 promulgate）。审视由你派**需求审视子代理**（独立上下文）生产——输入 = `rdd-engine/references/review-input-template.md` 机械清单，产出 ReviewFile（reviewer: `auditor-delegated`）呈用户（最终裁决权在用户）后 `promulgate -ReviewFile` 机械消费（消费端契约零改动）；`planner` 署名仅存量只读，**不再产出**。强形态（用户显式要求独立会话评审）走 `start-role -Role AUDITOR` 会话产同一契约产物（reviewer: `auditor`）。ReviewFile 契约、前置动作与错误码见 scenarios §需求审查门。
7. **纯自动模式边界**：自动拍板**仅限 worker 侧会话内检查点**；编排层裁决（建树审查门、settle 裁定、推翻/回退裁定）**不进分级表、不自动化**，永归人工。R1 宪法禁令行（安全/成本/不可逆/git）是脚本硬底：`-RiskPolicy` 整表覆盖也强制合并保留、永不许 action=auto。无 `-AutoMode` 的 run 一切行为与纯人工一致。
8. **并行冲突不得默默二选一**：设计冲突先调和出一致结论、或上报用户裁决并留痕（escalated）；用户不在场挂起涉事链（suspended）并上报——不阻塞无冲突任务；文件冲突经归属划分（首选）或串行化消解；错峰不构成互斥。未消解前涉事节点推送门 hold、settle 门拦截（见「并行协作冲突治理」）。
9. **规划承诺与阶段闸门**：`-PlanFile` 必填、全覆盖、批次拓扑序（见「长程规划与滚动追踪」）；阶段闸门只增不减、**无 Force 旁路**；偏差只经 `replan -Reason` 修正。
10. **设计汇聚审查门（双链，settle 尾必查待审阶段）**：阶段内全部任务越过 DESIGN 且 ≥1 落盘设计产物 → 触发五查汇聚（同视野全阶段产物，**禁逐设计串行审**）；无设计产物/无 in-run 设计工作快速通道豁免。**新链**（`review_mode`）：状态机 `planned → ready → passed|failed`——`ready` 即待派审（plan-log `design_review_ready` + status/next 提示双感知面，无自动会话推送），**你 settle 尾必查待审阶段**：每次 settle 后看 status 警示，有 `ready` 阶段即派评审子代理（同一机械模板）产 DesignReviewFile 并 `design-review -Action submit -Stage <S<k>>` 落地裁定。**缺键 legacy 照旧**（graft `[设计审查·S<k>]` 节点、AUDITOR 一批一会话结算）。**审查未过不得进 IMPL**（`NODE_BLOCKED_BY_DESIGN_REVIEW`，与阶段闸门同族无 Force 旁路）；fail → 自动重做波。状态机与信号路由见 scenarios §设计汇聚审查。
11. **等待回调，禁止轮询**：worker 交付的唯一完成信号是 **leaf report 回调**（携带四查凭据；dsh 下送达即唤醒你的会话），中间态不得作为裁定依据。禁止以循环 `status` / 定时查看的方式等待任务结果——那只消耗会话轮次，并诱发对中间态的误判与过早回收。`status` 的合法触点：会话启动/续跑后的全景对齐、**自己刚执行的命令输出中出现推送失败/警告后**的一次性核验与重试（session-create 类失败 status 触碰即自动重试）、用户询问或长任务异常排查（纪律：等 > 询问用户 > 回收）。CLI/Plus 无实时投递，以 `resume` 断点 + 用户驱动承接，同样不轮询。
12. **中途派生必经用户确认硬门**：run 中途范围缺口（只管新增不管改既有——rollback/reclaim 不对症）唯一消化通道是 `derive`：propose → **呈报用户** → confirm `-UserVerdict`（用户裁决原文即确认记录，缺即 `DERIVE_CONFIRMATION_MISSING` 确定性拒绝、不执行）→ 并入**当前 run**（非链式新 run）；新需求并入后经 replan 吸收，结案受 `DERIVATION_PENDING` 硬门约束（单 run 收敛）。预期会派生的 run 颁布时预留预算（`-MaxNodes`/`-NodeWidth`/`-MaxDerivations`）——预算 mid-run 不可增长，超预算派生卡 confirmed 不可自动重试（withdraw 或另起新 run）。

## 交付语义映射（回调契约）

worker 完成即经 `goal-tree-leaf.cmd -Command report` 回调**你**（回调自动送达当前有效规划者会话——新鲜租约优先，投递机制无需关心）：

> 各角色的**产物落点**与**凭据特征**（含 DEV 质量扫描门、AUDITOR `DesignReviewFile` 门）见上文「角色分工与产物契约」——下表是字段语义，那张表是每角色该交什么、交到哪。

| 回调字段 | 交付语义 |
|----------|----------|
| `verdict=done` | 交付自评完成（未 done 不得 settle） |
| `citations[]`（`ref`=真实路径） | 改动清单（settle 逐条校验路径存在） |
| `full_report` | 主产物文档指针（设计文档/实现说明；据此呈现 Doc 行，凭单条消息即可裁定） |
| `extras.verification` | 验证结果（lint/test/build 摘要；缺失即拒） |
| `extras.quality_scan` | DEV 出报必填（.ps1 变更时 code-metrics 凭据，violation_count=0；无 PowerShell 变更走 skip 形 `{skip:true,reason}`；完整字段与机械判定 R1-R6 见 scenarios §DEV 质量扫描凭据） |

**真实性判断由 QA 阶段节点承担**：QA 会话的 citations = 验收证据，QA 节点 settle 即任务 complete。**QA 判不合格** → 回调带非 done verdict + 失败清单（full_report/extras）→ 你二选一：**同阶段重做** `reclaim -NodeId`（问题在本阶段可修；失败清单自动组装）或**跨阶段回退** `rollback -NodeId -To <角色集> -Phase <阶段> -Reason <理由>`。

## 并行协作冲突治理（parallel-coordination）

**纪律：并行冲突不得默默二选一**（硬约束 8）。两类冲突：`design`（多 CTO/UX 设计互斥或风格不一致——**你的语义判断**：评审涉事设计产物，调和出一致结论为首选，不成则上报用户裁决留痕）与 `file`（变更地图判出同文件重叠——引擎推送门自动登记，首选归属划分，或 `resolve -Serialize <早者节点>` 串行化）。命令族：`conflict -Action open -ConflictKind design|file -Nodes <n1,n2> [-Files <p1,p2>]`（登记即 hold）/ `-Action open -ConflictId <C<n>> -ConflictStatus escalated|suspended [-Escalation <问题>]`（上报/挂起留痕）/ `-Action resolve -ConflictId <C<n>> -Ruling <结论> [-Serialize <早者节点>]`（消解后自动恢复推送）。状态机、强制门、架构/风格约定（多设计并行须 `-ConventionsFile`）与变更地图机读契约见 scenarios §并行协作冲突治理细则。

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
| tree.json / ledger.jsonl / round-*.md / final-report.md | goal-tree 既有：树状态 / 回调账本 / 轮快照 / 结案报告 |

> **统一决策账本 `decisions.jsonl` 位于归档根**（`.rdd/changes/archive/<归档名>/`，gitignore 由归档策略管理）——非 run 目录：账本是长期分析资产，归档是长期载体。条目四要素（background/options[]/decision/reason）+ decider（user / planner / auto\<规则\>@\<stage\>）；kinds：auto/escalation/resolution/overturn（AutoMode 既有）+ **derive_proposal / checkpoint / ruling**（planner-midrun-derive 新增：派生提议 / 五角色检查点留痕 / 编排裁定自动入账——rollback/reclaim/replan/conclude/conflict-resolve 命令尾 advisory 追加）。append-only 单调 `D<n>`，坏行隔离续写，旧形态缺字段容忍读。

> 场景细则索引：`references/planner-scenarios.md` —— §需求审查门 · §整体验收闭环 · §范围缺口派生 · §统一决策账本 · §并行协作冲突治理细则 · §设计汇聚审查 · §纯自动模式细则 · §DEV 质量扫描凭据 · §异常处置速查（报错时查）。

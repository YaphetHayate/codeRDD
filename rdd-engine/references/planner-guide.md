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
  5. settle       流转：三查 → 树 settle → rdd-flow set-route（阶段内收窄 / 末位汇聚切换
                   -To PhaseRoles[下阶段] -Phase）或 complete → 收敛 graft 下一阶段链头
                   → 尾部【自动推送】新解锁节点（依赖满足者）；三查不过即拒（不合格交付不流转）——
                   同阶段重做走 reclaim，跨阶段回退走 rollback（剪枝+按 -To/-Phase 重建+set-route+自动重推）
  6. 循环 4-5；中断后任意新规划者会话 resume 续跑（status 触碰兜底补推漏推节点）
  7. conclude     结案：全部任务终态 → 以目标根为锚 → final-report + delivery-annex.md（含 rdd-flow check）
```

**自动推送（依赖驱动，无人工确认门）**：dispatch 不再是规划者的逐节点手动命令。单一机制 `Invoke-AutoDispatch` 在四个触发点重算解锁集并推送：**建树推初始**（promulgate 尾）、**流转推解锁**（settle 尾）、**回收推重派**（reclaim 尾）、**回退推重做**（rollback 尾）、**巡检补漏**（status 触碰，租约空闲时）。推送条件 = 解锁（depends_on 全终态）∧ 未终态 ∧ 无活跃 claim（泊位除外）∧ 从未成功推送或回收后待重推。逐节点 try/catch 隔离失败，账目内嵌 bridge.json v2（`pushes`：node/at/ok/error/retry_class，逐节点落盘、崩溃后幂等重算续推）。失败分档：`session-create` 类（未建成会话）下一触发点自动重试；`pointer` 类（会话已建、指针投递失败）**只人工重推**（dispatch 命令保留用于此类与异常处置），防会话堆积。

**树形语义（目标根模型）**：根节点 = `type=goal` 的**目标根**——承载归档原始需求（overview.md 的 H1 标题 + 全文描述），不可认领（`GOAL_NODE_NOT_CLAIMABLE`）、不参与依赖（`DEP_GOAL_FORBIDDEN`）、conclude 终局锚点（全部直接子节点终态 ⇒ 根目标达成）。一级子节点 = PM 拆分的**子需求链头**（合一模型：链头即首阶段工作节点，`ref=<归档名>/<需求文档路径>` 绑定需求文档）；CTO→DEV→QA 阶段链在需求节点下随流转链式 graft（1 任务 : N 节点，映射落盘 bridge.json）。

**阶段链模型（phase-model）**：任务路由带 `phase` 字段，阶段全序 `REQ → DESIGN → IMPL → VERIFY → 完成`，阶段内角色白名单并行（DESIGN = CTO∥UX∥QA，含测试先行；完整模型见 `references/phase-model.md`，rdd-flow 侧协议见 `task-routing.md`）。多 owner 任务在颁布时**每个角色各建一个链头节点**（挂目标根），并行分支各自独立工作；settle 阶段感知：阶段内收窄不 graft，**最后一个 owner settle 才整组切换**（`set-route -To PhaseRoles[下一阶段] -Phase`）并收敛 graft 下一阶段节点（挂最后 settle 节点之下，链式 parent，无幽灵父节点，每角色至多一个活跃节点——并行分支不分裂树）。rollback 显式 `-To/-Phase` 回退时，重建的角色组节点以**兄弟挂接**回到目标阶段的链头层（沿失败节点祖先上溯第一个目标阶段白名单内节点的 parent；无锚挂目标根）——链不变量与树深在多轮回退下保持；回退到 REQ（`-To PM -Phase REQ`）可达，PM 为合法链头角色。旧归档（phase=null）整链保守降级为原 `CTO→DEV→QA` 线性行为（逐字节一致）。展示面：status/resume/conclude 的阶段链用 `∥`（阶段内并行）与 `→`（阶段间）渲染，如 `CTO=n2(done) ∥ UX=n3(done) → DEV=n5(claimed)`。

**任务级依赖**：promulgate 从各任务需求文档的「依赖关系」字段自动推导（"依赖需求 N" / "依赖 #N" → 依赖任务 N 的初始节点）；跨阶段/运行中的依赖维护用 `goal-tree deps add/remove`（机械 DAG 校验 + deps-log.jsonl 审计）。

**规划者职责收敛**：推送全自动后，规划者的职责收敛为**裁定**（settle/prune/graft 下探）与**异常处置**（pointer 类重推、依赖调整、驳回移交）——不再逐节点 dispatch。

**会话存活判定（两级）**：第一级 = dsh agents 注册表查证（经 goal-tree 插件只读 liveness 端点，与回调投递同源）→ `alive/dead`；第二级 = 时间阈值（claimed 后 60min 账本无产出）**仅 unknown 兜底**（CLI 后端 / 查证不可达）。`reclaim` 对 alive 机械拒绝（`RECLAIM_TARGET_ALIVE`，长任务误杀物理不可能）；unknown 且未达阈值报 `RECLAIM_UNPROVEN_DEAD`（宁等多收）。

**长任务处置纪律**：超时标记 ≠ 死——unknown 态节点反复接近阈值是长任务强信号，处置优先级：等 > 询问用户 > 回收；同一节点反复超时不要反复回收（有界损失：一次重跑），向用户上报节奏异常。

---

## 命令面板

调用约定与 rdd-flow 相同（`$rdd` 三级定位链指向 rdd-engine 目录），输出 UTF-8 JSON。

| 命令 | 形态 | 作用 |
|------|------|------|
| 颁布 | `delivery-bridge.cmd -Command promulgate -TaskJson <path> [-ReviewFile <path>] [-AutoMode [-RiskPolicy <path>]] [-NoPush] [-MaxRounds N] [-NodeWidth N] [-MaxNodes N] [-CreatedBy label] [-Session label]` | 读归档 → goal-tree start（目标根模式，原始需求=goal 根）+ round-start + 按任务×初始角色组**每角色各 graft 一个链头**（phase-model 多链头：并行 `currentOwners` 不再丢工作；`ref=<归档名>/<需求文档>`，`depends_on` 指向上游任务**全部**链头——多锚点汇聚解锁）→ 写 bridge.json v2 → **自动推送全部无前置依赖节点**。阶段校验门：owner 集跨阶段 → `GROUP_DIVERGENT_NEXT`（第一版不支持 fan-out）；存量 phase 非法 → `PHASE_INVALID`/`PHASE_OWNER_MISMATCH`。可选 `-ReviewFile` 消费需求审查结论（硬约束 6）：驳回/合并任务不建节点、`depends_on_override` 整体替代正则推导、合并依赖重定向到并入方、驳回残留依赖硬拒 `REVIEW_EXCLUDED_DEP`；缺省时行为与无审查门完全一致。可选 `-AutoMode` 启用纯自动模式（见「纯自动模式」节；缺省关闭=行为逐字节不变），`-RiskPolicy` 整表覆盖默认分级表（R1 硬底强制保留）。可选 `-NoPush`：只建 run 不启动任何角色会话（引擎测试套件/事故演练隔离——不触真后端，跳过入 pushes 账 `trigger='promulgate (-NoPush)'`）。RunId 固定为 `deliver-<归档名>`。预算默认：rounds 12 / width max(4, 任务数) / nodes 任务数×5+6；重度返工 run 按回退预期调 `-MaxNodes`（每轮跨阶段回退按重建组规模净增节点） |
| 调动 | `delivery-bridge.cmd -Command dispatch -RunId <id> -NodeId <n> [-DryRun]` | 手动单节点推送（异常处置 / pointer 类失败人工重推；正常流程由自动推送承担） |
| 认领 | `delivery-bridge.cmd -Command claim -RunId <id> -NodeId <n> -Role <PM/CTO/UX/DEV/QA>` | **被推送会话的第一动作**。双侧只读预检 → leaf claim → rdd-flow claim；冲突给确定性反馈 + 当前可领节点清单；goal 根报 `GOAL_NODE_NOT_CLAIMABLE`；PM 为 REQ 阶段合法链头角色（rollback -To PM 的重建节点可认领）；纯自动模式 run 的响应额外携带 `auto_mode` 段（enabled + 分级表快照 + decide/escalate 协议指引，report_hint 注入先例；非自动 run 无此段） |
| 拍板 | `delivery-bridge.cmd -Command decide -RunId <id> -NodeId <n> -Kind auto\|resolution\|overturn -Checkpoint <名> -Decision <裁定/问题> [-Inputs ...] [-Basis ...] [-Risk ...] (-Kind auto 需 -RuleId <规则>；resolution/overturn 需 -RefEntry <条目id>)` | **worker 侧检查点决策留痕**（纯自动模式专用，否则 `AUTO_MODE_DISABLED`；须本 stage 的 claimed 节点，overturn 额外容忍 reported=未 settle 重做窗口）。`auto`=分级表代答（规则须 action=auto，R1 硬底永拒 `RULE_NOT_AUTO`，代答者 `auto/<规则>@<stage>`）；`resolution`=用户裁定回填关闭未决升级（`user@in-session`，重复关闭拒 `ESCALATION_ALREADY_RESOLVED`）；`overturn`=未 settle 期内推翻既有决策（auto/resolution/escalation 条目，run 级 ref 存在性校验）。追加进 decisions.jsonl（run `.lock` 内，读回校验） |
| 升级 | `delivery-bridge.cmd -Command escalate -RunId <id> -NodeId <n> -Checkpoint <名> -Decision <呈用户的问题> [-RuleId <规则>] [-Inputs ...] [-Basis ...] [-Risk high]` | **高风险检查点升级**（纯自动模式专用，同上门禁）：写 open 升级条目（无人拍板，decider=null），worker 就地**等待**。dsh：插件 watcher 5s 扫描投递规划者 inbox（exactly-once，`decision <id>` 去重命名空间，送达即唤醒——`agent.send(msg,'next-turn',true)`，空闲规划者会话立即开轮消费）→ 规划者呈现用户 → `decide -Kind resolution` 回填；CLI/Plus：降级为 status/resume 可见 |
| 回收 | `delivery-bridge.cmd -Command reclaim -RunId <id> -NodeId <n>` | 复合回收，两种模式：**dead-claim**（卡死 claimed：存活预检——alive 拒 `RECLAIM_TARGET_ALIVE`、unknown 未达 60min 阈值拒 `RECLAIM_UNPROVEN_DEAD`——通过后 leaf `-Steal` + rdd-flow `claim -Force` 入泊位 → **自动重推**）与 **rejected-delivery**（reported 但证据不合格：剪枝失败交付 + graft 替换节点（ref 重绑需求文档）+ 重映射 → **自动推送替换节点**，账本保留审计痕） |
| 回退 | `delivery-bridge.cmd -Command rollback -RunId <id> -NodeId <失败节点> -To "<角色集>" -Phase <REQ/DESIGN/IMPL/VERIFY> -Reason "<理由>"` | **跨阶段回退单命令**（与 settle 正向 / reclaim 同阶段构成三通道）：剪枝失败节点（prune reason 入 ledger 留审计：回退目标+阶段+理由+操作者+证据问题清单）→ **兄弟挂接**按 `-To` 角色集逐角色重建节点（挂接锚=沿失败节点祖先上溯第一个落在目标阶段白名单内的节点之 parent——回到该阶段链头层；无锚则挂目标根；QA 证据问题+回退理由进新节点 task 的重做上下文）→ `rdd-flow set-route -To -Phase` 原子路由回退（owners+phase 白名单同步，`Sync-TaskClaims` 自动清 worker 残留）→ **自动重推**全部重建节点。回退目标由规划者**显式指定**（替代旧的 parent 机械推导；链头回退 REQ 可达）；守卫 `SET_PHASE_REQUIRED`（缺 -Phase）/ `PHASE_INVALID` / `PHASE_OWNER_MISMATCH`（-To 不 ⊆ PhaseRoles[-Phase]）/ `ROLLBACK_REQUIRES_REPORTED` / `ROLLBACK_REQUIRES_UNQUALIFIED` / `TASK_NOT_ACTIVE`；prune→graft 崩溃窗口由剪枝签名幂等续跑守卫兜底（重跑同命令自动续 graft 步，不二次剪枝，签名兼容新旧两代格式）。例：DEV 发现设计缺陷 → `rollback -NodeId <DEV节点> -To "CTO+UX" -Phase DESIGN`；回退需求阶段 → `-To "PM" -Phase REQ`。返回值 `dependents_warning[]` 仅警示直接依赖边（不展开传递闭包，闭包经 `goal-tree deps list` 自查），不动其他任务节点 |
| 流转 | `delivery-bridge.cmd -Command settle -RunId <id> -NodeId <n> [-Note ...]` | **task.json 流转的唯一通道**（见下方三查门禁）。phase 感知（phase-model）：读 `phase` → 阶段内还有 owner 未 settle → `set-route` 收窄（不 graft，等待汇聚）；最后一个 owner settle → `set-route -To PhaseRoles[下一阶段] -Phase` 原子切换 + 收敛 graft 下一阶段全部链头（每角色至多一个活跃节点——并行分支不分裂树）；`VERIFY` 完成 → `complete`。phase=null（旧归档）保守降级走原 advance 路径（行为逐字节一致）。settle 尾自动推送新解锁节点 |
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
7. **纯自动模式边界（planner-auto-mode）**：自动拍板**仅限 worker 侧会话内检查点**（CTO 四检查点这类「达标+用户确认」闸门）；编排层裁决——建树审查门（硬约束 6）、settle 三查裁定、推翻/回退裁定——**不进分级表、不自动化**，永归人工。R1 宪法禁令行（安全/成本/不可逆/git）是脚本硬底：`-RiskPolicy` 整表覆盖也强制合并保留、永不许 action=auto。自动决策全程留痕可查可推翻（未 settle 走 overturn，已 settle 走 reclaim rejected-delivery / rollback 善后）；无 `-AutoMode` 的 run 一切行为与引入前逐字节一致。

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
| `decisions.jsonl` | 决策账本（仅 `-AutoMode` 颁布的 run）：追加式条目流 `D<n>`（kind=auto/escalation/resolution/overturn，含 checkpoint/风险/规则/输入/依据/代答者/引用条目），未决升级视图 join 派生、账本永不重写（见「纯自动模式」节） |
| `report/delivery-annex.md` | 结案附录（根目标达成状态——有未决驳回时如实呈现「部分达成」+ 每任务终态（含树内合并/驳回注记）+ 阶段链 + rdd-flow check 结果） |
| （goal-tree 既有）tree.json / ledger.jsonl / round-*.md / final-report.md | 树状态 / 回调账本 / 轮快照 / 结案报告（目标根锚时含「根目标达成状态」区） |

> 桥接 run 目录：`.rdd/goal-trees/deliver-<归档名>/`。非桥接的 goal-tree run 与普通 rdd-flow 流程行为与引入桥接前完全一致（回归硬约束，由 delivery-bridge-verify 断言）。

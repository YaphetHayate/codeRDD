# 规划者场景细则（planner-scenarios）

> `planner-guide.md` 的场景下沉层：接管审查 / 收尾验收 / 并行冲突 / 设计审查 / 纯自动模式 / DEV 质量凭据。核心命令与硬约束见 planner-guide.md；本文各节仅在对应场景触发时阅读。

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
- **强形态分支（用户显式要求独立会话评审）**：`start-role -Role AUDITOR` 独立会话按同一模板产同一契约产物（`reviewer: "auditor"`）；dsh 后端需 preset `rdd-auditor`（`scripts/build-dsh-presets.mjs --with-auditor` 可重建，产品面默认 8 组不含 AUDITOR——设计 #8：删除引擎机制（节点/AutoDispatch 推送/一批一会话），保留方法论）。
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
- **前置动作**（脚本消费前审视方必须完成）：`reject_return` → 需求文档「## 驳回记录」追加行 + `rdd-flow reject -From <PLANNER/AUDITOR/AUDITOR-DELEGATED> -To PM`（见 `rejection-protocol.md`「PLANNER / AUDITOR 发起的驳回」——子代理形态驳回由规划者代递，署名 `auditor-delegated`）；`merged_into_task_id` → `rdd-flow deprecate -TaskId <被并入方>`（误判经 `reopen` 可恢复）。
- **机械消费保证**：排除任务不建节点、不进 bridge.tasks、不被推送；依赖被合并排除的任务重定向到并入方；依赖悬空于驳回排除任务硬拒 `REVIEW_EXCLUDED_DEP`（**禁止静默丢弃依赖**——静默丢弃会让依赖方被过早推送，正是审查门要消灭的错序 bug 类）；审查显式依赖指向后位任务时经 `deps add` 延后缝合（DAG 校验 + 审计）。
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

**感知面（新链 `ready` 待派审）**：plan-log `design_review_ready` progress 事件 + `status` 警示 + `resume` 步骤清单（含 submit 命令行）三面机械可感；**无自动会话推送**（设计 #8：删除 AutoDispatch 推送——派审是规划者动作）。规划者纪律：**settle 尾必查待审阶段**（planner-guide 硬约束 10）。

**降级与兼容**：缺键 legacy run 的 `design-review` submit 报 `DESIGN_REVIEW_LEGACY_RUN`（照旧 settle 节点通道）；legacy 链 AUDITOR 部署判据（双探：引擎仓 `rdd-auditor/SKILL.md` + `.claude/skills/rdd-auditor/SKILL.md` / `$env:USERPROFILE` 同名 / 项目 `dsh/presets/rdd-auditor`）不变——未部署即不落段无门（旧 run 逐字节）。新链审查节点失败场景不存在；legacy 审查节点自身失败（会话死）走 reclaim dead-claim 通道。

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
3. **confirm 落地**（顺序契约：**事实永远记录先行**）：账本 ruling 入账 → 状态落 confirmed → 预算预检（保守增量：节点 = owner数+4，goal 根宽度 +2；不足 → `DERIVE_BUDGET_EXCEEDED` **不盲目 graft**，派生卡 confirmed **不可自动重试**——预算 mid-run 不可增长，出路 withdraw 或另起新 run）→ graft PM 节点（goal 根子节点，node.task 注入判据增补义务与派生上下文）→ plan-log 记 `deviation/scope_derived` → 自动推送 PM 会话起草需求文档。
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
- 账本文件契约见 §纯自动模式细则「决策账本」段（归档级路径、append-only、坏行隔离、旧形态缺字段容忍读）。

## 异常处置速查

命令报错/异常症状 → 处置对照表（按需查阅；核心命令语义见 planner-guide 命令面板）：

| 症状 | 处置 |
|------|------|
| 需树外直交某角色（用户裁决/事故修复） | 写 brief 文件 → `start-role -DryRun` 验证指针全文 → 实发 `-Handoff <brief>` → `register-session` 登入花名册 |
| 回调收到完成、但用户已手动直交下游 | 用户显式指令优先执行，但 worker 回调先行不可省——照常四查裁定 settle（ledger 留痕对账）；撞车由 `FLOW_CLAIM_CONFLICT`/`NODE_NOT_CLAIMABLE` 兜底 |
| 同一节点第二个会话被唤起 | bridge claim 返回 `NODE_NOT_CLAIMABLE` + 认领者信息 + 可领清单，按清单改领 |
| 节点被依赖阻塞 | `NODE_BLOCKED_BY_DEPS` 附阻塞源：等上游 settle（解锁后自动推送）或 `deps remove` |
| claim/dispatch 报 `NODE_BLOCKED_BY_GATE`（消息含 replan 吸收指引） | 派生任务已入册未吸收——`replan` 将其纳入阶段（见 §范围缺口派生）；**无 Force 旁路** |
| settle 报 `SETTLE_EVIDENCE_REJECTED` | `reclaim -NodeId`（同阶段：原会话存活 in-place 重做 / 否则剪枝重建）或 `rollback`（跨阶段，见命令面板「回退」） |
| 树已 settle、flow 未流转 | `pending_sync` 自动记录；每次 status 自动重试修复 |
| 会话死在 claimed | `reclaim -NodeId`（dead-claim：存活预检 → 自动重推，新会话第一动作 claim 接管） |
| reclaim 报 `RECLAIM_TARGET_ALIVE` | 认领会话仍存活——不是回收对象；等它 report |
| reclaim 报 `RECLAIM_UNPROVEN_DEAD` | 存活不可证实且未达 60min 阈值——宁等多收；达阈值后重试 |
| reclaim 报 `REDO_FAILURE_REF_MISSING` | 失败清单（四查 problems + 回调 full_report/extras 自动检索）组装为空——带 `-FailureRef "<失败清单引用>"` 重试，或 `-NoReuse` 走重建 |
| reclaim 报 `RECLAIM_INPLACE_PROMPT_FAILED` | 重做指针投递原会话失败（节点零残留）——`dispatch -NodeId` 重投原会话，或 `reclaim -NoReuse` 重建 |
| rollback 报 `ROLLBACK_REQUIRES_UNQUALIFIED` | 该节点证据合格——不该回退，settle 即可 |
| rollback 报 `ROLLBACK_REQUIRES_REPORTED` | 节点非 report 态（claimed/pending/终态）——卡死认领走 `reclaim -NodeId`，待推节点等回调；rollback 只回退「report 未过四查」的交付 |
| rollback 报 `TASK_NOT_ACTIVE` | 任务已 completed——rollback 不覆盖事后返工：`rdd-flow reopen`（如 `-To DEV`）拉回活跃后按 rdd-flow 流转重做，再入桥接编排呈报用户（见 planner-guide「裁定触点速查」7） |
| rollback 报 `ROLLBACK_GRAFT_FAILED` | prune 已完成、graft 未成——**重跑同一条 rollback 命令**（幂等续跑，不二次剪枝） |
| 推送失败（status pushes 账可见） | `session-create` 类：status 触碰自动重试；`pointer` 类：人工 `dispatch -NodeId` 重推（防会话堆积） |
| 双规划者误起 | 启动即被 `PLANNER_RUN_ACTIVE` 拒绝；确认原会话已死后 `lease -Takeover` 留痕接管 |
| promulgate 报 `RUN_EXISTS` | 已颁布过——`status/resume -RunId deliver-<归档名>` 续跑 |
| promulgate 报 `REVIEW_FILE_INVALID`/`REVIEW_TASK_NOT_FOUND`/`REVIEW_EXCLUDED_DEP` | ReviewFile 契约/指向/依赖悬空——按错误消息修正后重试（建树前零残留）；见 §需求审查门 |
| promulgate 报 `ACCEPTANCE_CRITERIA_MISSING` | overview.md 补「## 整体验收判据」条目或一行「无整体判据（理由：…）」显式声明——见 §整体验收闭环 |
| promulgate 报 `CONVENTIONS_MISSING` | DESIGN 并行链头 ≥2 缺架构约定——产出 `report/architecture-conventions.md` 后补 `-ConventionsFile` |
| promulgate 报 `PLAN_MISSING`/`PLAN_FILE_INVALID`/`PLAN_ORDER_INVALID`/`PLAN_BATCH_INVALID` | 按 planner-guide「长程规划与滚动追踪」节的规划方法产出/修正 PlanFile（建树前零残留） |
| claim/dispatch 报 `NODE_BLOCKED_BY_GATE` | settle 对应 `[集成验收·S<k>]` 开闸或 `replan` 重划阶段；**无 Force 旁路** |
| claim/dispatch 报 `NODE_BLOCKED_BY_DESIGN_REVIEW` | 等设计裁定 pass（新链 `design-review -Action submit`；legacy settle 审查节点；fail 自动重做波）或 `replan`；见 §设计汇聚审查 |
| 设计审查证据被拒 `SETTLE_EVIDENCE_REJECTED`（DesignReviewFile 契约） | 新链：按问题清单修复 DesignReviewFile 后重新 `design-review -Action submit`（状态仍 `ready`）；legacy：AUDITOR 会话按 `rdd-auditor/references/design-review.md` 修复重报，会话死走 `reclaim` |
| 新链 submit 报 `DESIGN_REVIEW_NOT_READY` | 状态非 `ready`（提前/重复提交，或 fail 波进行中）——查 `design-review -Action status`，待 `ready` 再审 |
| 新链 submit 报 `DESIGN_REVIEW_LEGACY_RUN` | 该 run 缺 `review_mode` 键（存量链）——照旧 settle `[设计审查·S<k>]` 节点 |
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
| settle/dispatch 报 `NODE_HELD_BY_CONFLICT` / conflict 报 `CONFLICT_*` | 见 §并行协作冲突治理细则与 planner-guide「并行协作冲突治理」（已 resolved 的裁定变更按新条目重开） |
| status 报回执偏差/`DESIGN_MAP_INVALID` 警示 | 警示级不阻塞——核对变更地图是否漏报（重叠检测失明风险），见 §并行协作冲突治理细则 |
| 用户推翻 planner 审查裁定 | 建树前：直接改 ReviewFile 重产出（未消费零残留）；已颁布：`rdd-flow reopen` 恢复 + `deps`/graft 补树内调整；会话内向用户留痕说明（详见 §需求审查门） |
| status 报 `BRIDGE_FORMAT_UNSUPPORTED` | 旧版 v1 桥零兼容——重新 promulgate 或按本协议人工处置存量 run |
| 需求/设计不可行 | 走 `rdd-engine/references/rejection-protocol.md` 驳回协议移交上游 |

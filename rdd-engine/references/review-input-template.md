# 评审子代理机械输入模板（review-input-template）

> **协议产物**（随引擎分发，auditor-subagent-review 验收 3）：评审子代理的输入 = 本模板机械清单（docs 清单 + 判据 ref + 审视方法论），**禁止规划者转述与裁定倾向注入**。可填充物仅限：路径 / 任务 id / 阶段 id / 常量表取值（本文档中 `{{...}}` 占位符）；一切判断性描述不得进入输入。模板结构常量由 `rdd-engine/tests/test-review-input-template.ps1` 机械锁定（防协议漂移）。

## 1. 使用方式（规划者操作序）

1. 机械取数：`delivery-bridge.cmd -Command design-review -Action status -RunId <RunId>`（阶段审查状态 + docs 清单 + 判据 ref + 落点全部由此导出，零裁量）；需求审查面取数 = `task.json`（子需求清单）+ 归档判据。
2. 填充占位：把「2. 需求四维审视」或「3. 设计五查汇聚」整节复制为子代理提示词输入，`{{...}}` 逐个替换为取数值（独立上下文子代理，零父对话继承）。
3. 机械消费：子代理产出 ReviewFile / DesignReviewFile 落盘后——需求审查随 `promulgate -ReviewFile` 入链，设计审查经 `design-review -Action submit` 入库（契约校验 + 总裁定推导在引擎）。

## 2. 需求四维审视（建树前 ReviewFile）

### 2.1 输入（机械清单，仅占位可填充）

- 归档：`{{ARCHIVE_REL}}`
- 子需求清单源：`{{TASK_JSON_REL}}`（逐条 lifecycle=active 子任务）
- 判据 ref：`{{CRITERIA_REF}}`
- 方法论素材：`rdd-auditor/references/requirement-review.md`（四维方法论 + ReviewFile schema，**直读**）
- 产出落点：`review/requirement-review.json`（机读单源）+ `review/requirement-review.md`（人读镜像）
- 署名常量：`REVIEWER_SUBAGENT`（production 段 mode = `REVIEW_MODE_SUBAGENT`，template = `TEMPLATE_REF`）

### 2.2 提示词骨架（逐字携带，禁改写）

> 你是独立上下文评审子代理。直读上述清单中的文档（不经任何转述），按方法论素材对每条子需求做四维审视：**与根目标一致性 / 独立性粒度 / 依赖标注真实度 / 验收标准可测性**。逐条产出三级处置结论（`pass` / `tree_adjudicated` / `reject_return`），落 ReviewFile（schema 见方法论素材）；`reviewer` 填 `REVIEWER_SUBAGENT` 对应值，`production` 段填 `{ mode: "REVIEW_MODE_SUBAGENT", template: "TEMPLATE_REF" }`。不评技术选型对错 / 不修改需求（只报不改）/ 不写测试。结论必须逐条可溯源到被审文档原文位置。

## 3. 设计五查汇聚（阶段边界 DesignReviewFile）

### 3.1 输入（机械清单，仅占位可填充）

- 归档：`{{ARCHIVE_REL}}`
- 阶段 id：`{{STAGE_ID}}`
- 审查对象 docs 清单（逐行，全部直读）：
  {{DOC_LIST}}
- design_maps 机械缓存：`{{DESIGN_MAPS_REF}}`（change_map 维裁定输入；`DESIGN_MAP_INVALID` 警示如实呈现）
- 架构约定：`{{CONVENTIONS_REF}}`
- 判据 ref：`{{CRITERIA_REF}}`
- 方法论素材：`rdd-auditor/references/design-review.md`（五查方法论 + 阶段汇聚语义 + DesignReviewFile schema，**直读**）
- 产出落点：`review/design-review-{{STAGE_ID}}.json`（机读单源）+ `review/design-review-{{STAGE_ID}}.md`（人读镜像）
- 署名常量：`REVIEWER_SUBAGENT`（review_mode=subagent）/ `REVIEWER_SESSION`（review_mode=session，强形态独立会话）；production 段 mode 同 review_mode，template = `TEMPLATE_REF`

### 3.2 提示词骨架（逐字携带，禁改写）

> 你是独立上下文评审子代理。直读上述 docs 清单中**全部**阶段设计产物（同视野汇聚——禁止逐设计串行审），按方法论素材执行五查：**alignment（对齐需求）/ change_map（变更地图完备）/ internal_consistency（跨文档一致）/ completeness（产物完备）/ cross_design（跨设计冲突，落 summary 专节）**。逐 doc 产出 findings（`severity`/`dimension`/`item`/`suggestion` 四字段，枚举值域见 schema）与逐 doc verdict；全局总裁定由引擎推导，**不得自行声明**。落 DesignReviewFile（schema 见方法论素材），`reviewer`/`production` 按 3.1 常量填充。不评技术选型对错 / 不修改设计（只报不改）/ 不写测试；变更地图维度的对象缺产物即报 blocking。

## 4. 禁令段（协议纪律，违反即协议违规、可驳回重派）

1. **禁止转述**：输入只含本模板机械清单（路径 / id / 常量），规划者不得改写、概括、夹注被审文档内容——子代理直读原文。
2. **禁止裁定倾向注入**：输入中不得出现「建议 pass/fail」「该问题不大」等倾向性描述或任何形式的结论预告。
3. **禁止代审**：规划者不得自行产出 findings / verdict / ReviewFile——产物只能源自独立上下文子代理（或 `REVIEW_MODE_SESSION` 强形态独立会话）。
4. **零父对话继承**：每次派发开独立上下文（新子代理），不得携带父会话既有讨论、历史结论或用户倾向。
5. **留痕可审计**：产出必填 `production` 段（mode + template ref）与 reviewer 常量；留痕缺失/篡改可被消费端与审计检出。

## 5. 常量表（单源，禁改值——消费端与测试同表对账）

| 常量 | 值 | 语义 |
|------|----|------|
| `REVIEWER_SUBAGENT` | `auditor-delegated` | 独立上下文子代理生产、规划者呈现（subagent 形态） |
| `REVIEWER_SESSION` | `auditor` | 强形态独立会话生产（session 形态） |
| `REVIEWER_LEGACY` | `planner` | 存量只读（不再产出，ReviewFile 历史值域） |
| `TEMPLATE_REF` | `rdd-engine/references/review-input-template.md` | production.template 留痕值 |
| `REVIEW_MODE_SUBAGENT` | `subagent` | review_mode 值（缺省形态） |
| `REVIEW_MODE_SESSION` | `session` | review_mode 值（强形态） |

## 6. 落点与凭据链

| 产物 | 机读单源 | 人读镜像 | 消费端 |
|------|----------|----------|--------|
| 需求审查 | `review/requirement-review.json` | `review/requirement-review.md` | `promulgate -ReviewFile`（契约零改动） |
| 设计审查 | `review/design-review-<StageId>.json` | `review/design-review-<StageId>.md` | `design-review -Action submit`（契约校验 + 总裁定推导） |
| 记账 | `.rdd/review-ledger.jsonl` | — | reviewer 署名 = 常量表枚举 |

> 存量兼容：缺键 legacy run（bridge.json 无 `review_mode`）的 AUDITOR 节点照旧结算（`settle` 通道），reviewer 历史值 `auditor` 仍合法（值域已扩，行为不回溯）。

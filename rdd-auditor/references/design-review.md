# 设计汇聚审查方法论与 DesignReviewFile 生产流程

> **定位**：DESIGN→IMPL 阶段边界的独立设计审查（auditor-design-stage-review）。与需求侧审视（[requirement-review.md](requirement-review.md)）构成两个事前把关位：**需求集进规划建树前查需求 / 设计汇聚进实现前查设计**；与 QA 阶段解禁（已交付）构成完整独立审查链——**实现前查设计本身质量 / 实现后查符合性（QA）**：两者读同一份设计但回答不同问题，互不污染（审视者不写测试，QA 验收基线先冻结）。本文件兼具**评审子代理提示词素材**定位：`rdd-engine/references/review-input-template.md` §3 提示词骨架直指本方法论（子代理直读）。

---

## 一、审查对象与时机

- **触发**（引擎自动，无人工判断）：桥接 run 中某阶段全部在册任务越过 DESIGN（phase ∈ {IMPL, VERIFY} 或 lifecycle 终态）且 ≥1 落盘设计产物。**新链**（bridge.json `review_mode`）：状态置 `ready`（plan-log `design_review_ready` + status/resume 提示，无自动会话）→ 规划者派评审子代理（或强形态会话）产 DesignReviewFile → `delivery-bridge.cmd -Command design-review -Action submit -RunId <RunId> -Stage <S<k>>` 入库；**缺键 legacy**：引擎 graft 树级节点 `[设计审查·S<k>]`（role=AUDITOR）推送会话 → `settle` 结算。全阶段无设计产物 / 无 in-run 设计工作 → `exempt` 快速通道（无门）。
- **阶段汇聚**（原「一批一会话」，现为方法论级语义）：**汇聚审查本阶段全部设计产物**，禁止逐设计节点串行审查——并行设计间的跨设计一致性只有汇聚在同一视野内才可查。引擎侧「一批一会话」机制（节点 + 会话推送）已删（设计 #8），汇聚语义保留为方法论硬纪律。
- **审查对象** = 阶段内在册任务的**全部落盘设计产物**（`design-review -Action status` 输出的 docs 清单 / legacy claim 输出 `acceptance.docs` 是权威清单）：CTO 技术方向文档、UX 交互/体验设计、QA 测试先行设计。**UX 纯视觉稿类产物：审查对象为变更地图与交互说明，缺产物即该文档 fail（产物契约不满足）。**
- **审查完成后**：产出 DesignReviewFile（见「三、契约」）→ 新链由规划者 `design-review -Action submit` 入库 / legacy `settle -NodeId <审查节点id>`。契约校验与节点 settle 门**同一核心**；总裁定**由引擎推导**（pass ⇔ 全文档 pass 且全局零 blocking）——不采信任何声明值：
  - **pass** → `design_review=passed` → IMPL 闸门开（被闸节点下一触发点自动放行）
  - **fail** → 引擎自动触发**重做波**：受影响任务（blocking 归属）rollback 原语语义回 DESIGN（blocking 清单注入重做上下文，目标角色按文档后缀精确映射 `-cto`→CTO / `-ux`→UX / `-qa`→QA）→ 重做收敛后再审（覆盖重产重审）
- **审查会话自身失败**：legacy 节点走既有 `reclaim` dead-claim 通道（park + 重推）；新链子代理失败即重新派发（无节点状态残留）。

## 二、五查维度（每一维度都必须产出，漏一维 = 审查不完整）

| 维度 | 查什么 | 判定要点 |
|------|--------|----------|
| `alignment`（设计-需求对齐） | 每需求点有承接、范围无放大/缩小 | 逐条对照需求验收标准与方案正文；范围漂移（顺手加需求外能力 / 偷砍需求点）= blocking |
| `change_map`（变更地图质量） | 格式 / 计数 / 文件归属 | 消费 claim 输出的 `acceptance.design_maps` 机械缓存——**`DESIGN_MAP_INVALID` 警示是裁定输入**（格式违例、计数不符、旧格式失明）；共享文件漏列 = blocking（file 冲突检测将失明） |
| `internal_consistency`（内部一致性） | 决策记录 vs 方案正文 vs frontmatter `acceptance_ref` | 自相矛盾（正文与决策记录冲突、判据锚错需求）= blocking |
| `completeness`（完备性） | 边界 / 异常 / 模块影响 | 需求明列的边界与异常是否有承接；跨模块影响是否显式声明；关键遗漏 = blocking，次要补强 = advisory |
| `cross_design`（跨设计一致性） | 并行设计间架构与风格约定 | 对照架构约定（claim 输出 `acceptance.conventions`）；同层不同策略（如同一缓存层不同失效策略）= 建议登记 conflict 的跨设计项，blocking 与否按「是否导致实现互斥/返工」裁定 |

> 每条 finding 必须落四字段（severity / dimension / item / suggestion）——settle 门机械校验。**建议给出可执行的修正方向，不做替代设计。**

## 三、DesignReviewFile 契约（机读单源 + 人读镜像）

落盘位置（归档相对）：`review/design-review-S<k>.json`（机读单源，引擎消费）+ `review/design-review-S<k>.md`（人读镜像）。

```json
{
  "reviewed_at": "2026-10-06T09:00:00Z",
  "reviewer": "auditor-delegated",
  "production": {
    "mode": "subagent",
    "template": "rdd-engine/references/review-input-template.md"
  },
  "stage": "S1",
  "docs": [
    {
      "doc": "design/feature-x-cto.md",
      "verdict": "fail",
      "findings": [
        {
          "severity": "blocking",
          "dimension": "change_map",
          "item": "变更地图漏列共享模块文件 app/cache.py（file 冲突检测将失明）",
          "suggestion": "补列 app/cache.py 并重出计数行；与并行设计的缓存层策略一并对齐后重产"
        },
        {
          "severity": "advisory",
          "dimension": "completeness",
          "item": "缓存失效的异常路径未声明模块影响",
          "suggestion": "补「边界与异常」节的失效兜底说明"
        }
      ]
    }
  ],
  "summary": {
    "cross_design": [
      {
        "severity": "advisory",
        "item": "两设计对同一缓存层用了不同失效策略（A 事件失效 / B 定时失效）",
        "suggestion": "建议登记 conflict 由 planner/用户调和（AUDITOR 只建议不代登记）",
        "involved_docs": ["design/feature-x-cto.md", "design/feature-y-cto.md"]
      }
    ]
  }
}
```

**字段约束（submit / legacy settle 门同源机械校验，违规 = SETTLE_EVIDENCE_REJECTED）**：

- `reviewer` ∈ {`auditor-delegated`, `auditor`}（单源 `review-input-template.md` 常量表；legacy 存量文件 `planner` 值不再产出）；`production` 留痕形态（mode ∈ {subagent, session} + template ref 非空）；`stage` 必须等于被审阶段 id；`reviewed_at` 非空
- `docs[]` **全覆盖**：阶段落盘设计文档双向逐一致（漏审任一文档 / 审查不存在的文档均违规）；同一文档不得重复列出
- 每文档 `verdict ∈ {pass, fail}`；**fail 必有 ≥1 条 blocking finding、pass 必无 blocking**（verdict-findings 一致性）
- 每条 finding 四字段完备：`severity ∈ {blocking, advisory}`、`dimension ∈ {alignment, change_map, internal_consistency, completeness, cross_design}`、`item`/`suggestion` 非空
- `summary.cross_design[]` 每条必带 `severity`/`item`/`suggestion` + `involved_docs` 非空且都在册（跨设计项必附涉及文档）
- **总裁定没有声明字段**——引擎推导：pass ⇔ 全文档 pass 且全局（docs findings + cross_design）零 blocking

**人读镜像 `.md` 模板**：`# 设计汇聚审查 — <归档名>·S<k>` + 审查摘要（触发判据 / 五查各维度 finding 数 / production 留痕 / 账本追加状态）+ 逐文档结论表（文档 / 结论 / blocking 数 / advisory 数）+ 跨设计专节 + 回流建议（如有）。

## 四、记账规范（触发记账，验收 8）

每次裁定落盘时引擎自动追加 `.rdd/review-ledger.jsonl`（全局单文件 JSONL，账本范式不重写）：

- 汇总条目：`{at, archive, reviewer:<枚举>, kind:"design_review", run_id, stage, verdict, docs_count, blocking_count, advisory_count, dimension_counts}`
- fail 时逐 blocking 条目：`{at, archive, reviewer:<枚举>, kind:"blocking", gap_type:<dimension>, task_id, run_id, stage, detail:{doc, item, suggestion}}`
- **回流建议**：同 dimension blocking 同 run 累计 ≥3 次 → 引擎追加 `kind:"reflux_suggestion"` 条目（建议生成 CTO 模板/流程改进需求——**只建议不代建**，AUDITOR 不替 CTO 建模板）。人读镜像顶部同步标注。

> 与需求侧审视的记账同文件同范式（`kind:"gap"` 为需求侧、`kind:"blocking"` 为设计侧），审计追溯一条账本链到底。

## 五、与需求侧审视（requirement-review）的分工

| | 需求侧审视（requirement-review） | 设计汇聚审查（本文档） |
|---|---|---|
| 时机 | 归档后、规划建树前 | 桥接 run 内、DESIGN 全 settle 后 / IMPL 前 |
| 对象 | 需求集（overview + 各需求文档） | 设计产物（CTO/UX/QA 设计文档 + 变更地图） |
| 产物 | `review/requirement-review.json` + `.md` | `review/design-review-S<k>.json` + `.md` |
| 消费端 | `promulgate -ReviewFile`（建树前机械消费） | `design-review -Action submit`（新链入库）/ `settle` 门（legacy 节点）+ 阶段闸门（IMPL 解锁门） |
| 失败处置 | `reject_return` 驳回回流 PM | fail 波自动回 DESIGN 重做（复用 rollback 原语） |

**判定归属**：需求本身空缺（验收不可测 / 覆盖洞 / 依赖错标）→ 需求侧审视维度，即便在设计审查中发现也按「需求空缺」定性并建议回流 PM；设计层问题（错位 / 失真 / 遗漏 / 跨设计不一致）→ 本审查裁定。

## 六、三条边界（防越权，宪法层同源）

1. **不评技术选型对错**——选型对错是 CTO 四检查点 + 用户裁决域，AUDITOR 只查「设计是否回答了该回答的问题」，不裁决「选 A 还是 B 更好」。
2. **不修改设计**——只报不改：白名单仅 `review/` 产物 + 账本 + 驳回记录追加行；发现问题的唯一出路是 finding + suggestion，重产由原设计角色完成。
3. **不写测试**——QA 独立性链条不动：本审查不产测试用例、不动 tests/，QA 验收基线先冻结（与 QA 阶段解禁互补不互扰）。

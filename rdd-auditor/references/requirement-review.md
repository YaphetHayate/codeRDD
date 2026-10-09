# 需求审视方法论与 ReviewFile 生产流程

> 本文件是审视方法论文档（auditor-subagent-review 后兼具**评审子代理提示词素材**定位）——SKILL.md 给出三禁纪律与双形态定位，本文件给出可执行的方法论、契约模板、记账规范、驳回指引。规划者派需求审视子代理时，`rdd-engine/references/review-input-template.md` §2 的提示词骨架直指本方法论（子代理**直读**本文档）。设计侧方法论见 `design-review.md`。

---

## 一、审视对象与时机

| 项 | 值 |
|------|------|
| 审视对象 | 归档 `.rdd/changes/archive/<name>/` 下的需求集（`requirements/overview.md` + `requirements/*.md`）+ task.json 路由 |
| 时机 | 归档后、建树前；规划者经 `promulgate -ReviewFile` 机械消费 |
| 触发判据 | 归档含 ≥2 条非 deprecated 子需求（与 `rdd-flow next` longTask 信号同判据）→ 审视必经；单需求快速通道豁免 |
| 审视频率 | **每次审视覆盖重产**（后续 run / 驳回回流修订后必重审；不复用旧结论） |
| 审视周期 | 一次性——一次审视产出整次 ReviewFile（`verdicts[]` 覆盖 task.json 中每条 active 任务；未列出的任务 = 隐式通过） |

---

## 二、四维审视方法论

> 每条子需求过四维；每维度独立产出 gap 列表；gap 落入对应 `verdicts[]` 条目 + 计入账本 `gap_type` 字段。

### 维度 1：覆盖完整性（coverage）

**目标**：overview 顶层描述提到的所有功能点都有子需求承接；子需求承接的功能点都在 overview 顶层描述中显式声明（无孤儿）。

**机制**：**双向映射表**

| overview 功能点 | 承接子需求 | gap 标记 |
|----------------|----------|---------|
| 「存档云同步」 | （无） | `coverage_hole` — overview 提及但无子需求承接（空洞） |
| 「跨设备会话同步」 | #3（存档云同步） | OK |
| 「编辑器性能优化」 | #5（启动性能 + 编辑响应延迟） | OK（合并建议：`merge_candidate`，如 #5 是同一改动两个侧面） |
| （无） | #7（某边缘场景） | `orphan_requirement` — 子需求存在但 overview 未提及（孤儿） |

**判定动作**：
- `coverage_hole`：overview 提到但无子需求承接 → **严重**（通常 `reject_return`，除非 PM 显式说明该功能点已下线/移交其他归档）
- `orphan_requirement`：子需求存在但 overview 未提及 → **中度**（通常 `tree_adjudicated` + 备注「PM 应补回 overview」；不驳回——可能 PM 拆分时遗漏补充，可在 review 镜像中列出建议 PM 修订）

### 维度 2：独立性与粒度（independence & granularity）

**目标**：每条子需求 = 一个用户可感知的完整成果；无「同一改动两个侧面」冗余；无「应拆分但 PM 写成一条」的过粗需求。

**判定动作**：
- **粒度过粗**（一条需求包含多个独立可交付的功能）：备注 PM 应拆分；严重时 `reject_return`（不替 PM 拆）
- **粒度过细**（一条需求拆出本可合一的子任务）：备注 PM 应合并；不强制驳回（细粒度未必是问题，留待规划者或后续 run 处理）
- **`merge_candidate`**（多条子需求实为同一改动两个侧面）：记入 `verdicts[]` 的 `merged_into_task_id` 字段，规划者经 `rdd-flow deprecate -TaskId <被并入方>` 处置（与 planner-guide 硬约束 6 既有契约同构）

### 维度 3：依赖标注真实度（dependency）

**目标**：需求文档 `**依赖关系**` 字段的机读标注与实际依赖关系一致（无错标 / 无漏标）。

**判定动作**：
- **错标**（声明依赖 #N，实际无依赖；或不声明依赖 #N，实际强依赖）：`tree_adjudicated` + `depends_on_override: []`（清空错依赖）或追加真实依赖（延后缝合由规划者经 `deps add` 处理）
- **漏标**（实际强依赖某条需求但未声明）：同上 `tree_adjudicated` + `depends_on_override` 补依赖
- **前向引用**（指向更大编号，按 `rdd-pm/references/requirement-item-template.md` 规范会静默丢边）：备注 + `depends_on_override` 后位补依赖

> **机读规则的边界**：括号备注内的编号不参与依赖推导（见 `requirement-item-template.md`「依赖关系标注规范」）。审计时只看字段值机械推导结果是否漏掉真实依赖。

### 维度 4：验收标准可测性（testability）

**目标**：每条子需求的「验收标准」都是可观察输出或命令形态（QA 能独立基于此设计测试）；无「代码看起来不错」「体验良好」等主观措辞。

**判定动作**：
- **不可测**（含「良好」「合理」「优雅」等无量化锚点的措辞）：`reject_return` 或 `tree_adjudicated` + 备注「请补可测形态」（粒度判给 PM 把握；通常强拒）
- **半可测**（含可测部分 + 模糊尾巴）：备注 + 建议 PM 修剪
- **可测**（含可观察输出/命令/JSON 字段/状态转移）：OK

**可测锚点示例**：
- ✅ `start-role.cmd -Role AUDITOR -DryRun` 输出含身份装载与归档相对路径
- ✅ `node scripts/build-dsh-presets.mjs --check` 退出码 0（默认 8 组 preset 与技能源一致）
- ❌ `接口设计合理`（无量化锚点）

---

## 三、ReviewFile Schema

> 与 `rdd-engine/references/planner-guide.md` 硬约束 6 既有契约**同构**——消费端（`delivery-bridge.ps1`）只看非空 ReviewFile 与 `verdicts[]` 字段，值域零改动。`reviewer` 字段取值（单源 `review-input-template.md` 常量表）：`auditor-delegated`（子代理形态产出，主路径）/ `auditor`（强形态独立会话产出）/ `planner`（存量只读，不再产出）。

### 完整形

```json
{
  "reviewed_at": "2026-10-02T12:34:56+08:00",
  "reviewer": "auditor-delegated",
  "archive": "2026-10-02-auditor-independent-review",
  "trigger": "longTask" | "manual" | "planner-dispatch",
  "production": {
    "mode": "subagent" | "session",
    "template": "rdd-engine/references/review-input-template.md"
  },
  "deployment_check": {
    "preset_id": "rdd-auditor",
    "present": true,
    "note": "legacy 字段（缺键链部署探测留痕）；新链以 bridge.json review_mode 为准，本字段可省"
  },
  "verdicts": [
    {
      "task_id": 1,
      "verdict": "pass",
      "reason": "独立、与根目标一致；四维审视均无 gap"
    },
    {
      "task_id": 2,
      "verdict": "tree_adjudicated",
      "reason": "overview 提到的「存档云同步」无子需求承接（coverage_hole），但本归档已显式声明该功能点移交其他归档；可放行",
      "depends_on_override": []
    },
    {
      "task_id": 3,
      "verdict": "tree_adjudicated",
      "reason": "与 #4 实为同一改动两个侧面（merge_candidate）",
      "merged_into_task_id": 4
    },
    {
      "task_id": 4,
      "verdict": "reject_return",
      "reason": "验收标准含「接口设计合理」无量化锚点（untestable_acceptance），不可测"
    }
  ],
  "gaps_summary": {
    "coverage_hole": 0,
    "orphan_requirement": 1,
    "dependency_mislabel": 0,
    "merge_candidate": 1,
    "untestable_acceptance": 1
  },
  "ledger_appended": true,
  "ledger_path": ".rdd/review-ledger.jsonl"
}
```

### 字段约束（与 planner-guide 硬约束 6 既有契约一致）

- `verdict` 枚举 `pass / tree_adjudicated / reject_return`；未列出的任务 = 隐式通过
- `pass` 不得携带 `depends_on_override` / `merged_into_task_id`
- `tree_adjudicated` 的 `depends_on_override` 与 `merged_into_task_id` 不得同现于一条 verdict（合并任务不建节点）
- 同任务重复 verdict、指向不在归档的任务均拒（消费端 `REVIEW_FILE_INVALID` / `REVIEW_TASK_NOT_FOUND`）
- `reject_return` 的前置动作：需求文档「## 驳回记录」追加行（仅追加不改本体）+ `rdd-flow.cmd reject -From <AUDITOR-DELEGATED|AUDITOR> -To PM -Reason "..."`（子代理形态由规划者代递，署名 `AUDITOR-DELEGATED`）

---

## 四、人读镜像模板（`requirement-review.md`）

```markdown
# 需求审视报告 — <归档名>

- **审视时间**：YYYY-MM-DD HH:MM
- **审视者**：AUDITOR（审视员）
- **触发**：[longTask / manual / planner-dispatch]
- **部署检测**：[preset rdd-auditor 已就位 / 缺席已落降级提示]
- **任务总数**：N（含 active）
- **四维 gap 计数**：coverage_hole=N, orphan_requirement=N, dependency_mislabel=N, merge_candidate=N, untestable_acceptance=N

## 逐条结论

| 任务 ID | 标题 | 结论 | 理由 | 处置 |
|---------|------|------|------|------|
| 1 | xxx | pass | 独立、与根目标一致；四维审视均无 gap | — |
| 2 | xxx | tree_adjudicated | overview 提到「存档云同步」无子需求承接，但本归档显式声明已移交他处 | depends_on_override=[]（无副作用） |
| 3 | xxx | tree_adjudicated | 与 #4 实为同一改动两个侧面 | merged_into_task_id=4（待 deprecate） |
| 4 | xxx | reject_return | 验收标准含「接口设计合理」无量化锚点（不可测） | 已发起驳回（见 requirements/xxx.md「## 驳回记录」） |

## 账本状态

- 已追加 `.rdd/review-ledger.jsonl`（N 行 gap 条目）
- 同类 gap_type 累计：[coverage_hole N 次 / orphan_requirement N 次 / dependency_mislabel N 次 / merge_candidate N 次 / untestable_acceptance N 次]
- ≥3 次同类 gap_type 建议：[是 / 否]（如「是」，建议回流 PM 流程改进需求；只建议不代建）

## 用户裁定（待用户填写）

> 最终裁决权在用户。可在此表追加「推翻」或「确认」列，标注对每条 verdict 的处置。
```

---

## 五、记账规范

### 账本位置与格式

- 路径：`.rdd/review-ledger.jsonl`（项目根，全局单文件）
- 格式：JSONL 追加式（每行一个 JSON 对象，UTF-8 + LF 行尾）
- 范式：**append-only，账本不重写**（与 `ledger.jsonl` / `decisions.jsonl` / `plan-log.jsonl` 同源范式）

### 单条格式

```json
{
  "at": "2026-10-02T12:34:56+08:00",
  "archive": "2026-10-02-auditor-independent-review",
  "reviewer": "auditor-delegated",
  "kind": "gap",
  "task_id": 2,
  "gap_type": "coverage_hole",
  "detail": "overview 提到的「存档云同步」无子需求承接"
}
```

### 字段约束

| 字段 | 类型 | 说明 |
|------|------|------|
| `at` | string | ISO-8601 时间戳 |
| `archive` | string | 归档名 |
| `reviewer` | string | 枚举 `auditor-delegated`（子代理形态）/ `auditor`（强形态会话）/ `planner`（存量只读）——单源 `review-input-template.md` 常量表；设计侧 blocking 条目同枚举 + `kind="blocking"` |
| `kind` | string | `"gap"`（本条）/ `"blocking"`（#2 预留） |
| `task_id` | number \| null | 涉及的任务 ID（无涉及则为 null） |
| `gap_type` | string \| null | 枚举 `coverage_hole / orphan_requirement / dependency_mislabel / merge_candidate / untestable_acceptance`（无 gap 则为 null） |
| `detail` | string | 一句话描述 |

### ≥3 次同类回流判定

审视完成后，扫描 `.rdd/review-ledger.jsonl` 全量条目，按 `gap_type` 分组计数。任一 `gap_type` 累计 ≥3 次（不限时间窗）→ 在 `requirement-review.md` 顶部摘要 + 账本状态区标注「建议回流 PM 流程改进需求」；**只建议不代建**——AUDITOR 不替 PM 创建需求。

> **并发追加无锁**：本需求落地接受小团队场景下「审视结束一次性追加」的纪律（同会话单次落盘，原子性天然保证）；极端并行下追加行交错风险属 #2 评估范围。

---

## 六、驳回指引（`reject_return` 前置动作）

> `reject_return` 的完整协议见 `rdd-engine/references/rejection-protocol.md`「评审方发起的驳回」节（双形态）；本节是审视者侧的实操指引。

### 前置动作（两件）

1. **在目标需求文档的「## 驳回记录」表格追加一行**（仅追加；发起方 = `AUDITOR-DELEGATED`（子代理形态，规划者代递）/ `AUDITOR`（强形态会话）、状态 = `待回应`）——不改写需求文档其余内容本体，**包括遗留的 `## 流转控制 > 当前责任人` 字段**（路由事实以 task.json 为准，文档本体归 PM）
2. **更新路由**：`rdd-flow.cmd -Command reject -Archive "<归档>" -TaskId <n> -From <AUDITOR-DELEGATED|AUDITOR> -To PM -Reason "<理由>"`

### ReviewFile 与驳回的衔接

- ReviewFile `verdicts[]` 中标 `reject_return` 的任务 → **不建节点、不进本轮交付**；`conclude` 门禁豁免该任务（active@PM 是真实状态）
- 后续流转（PM 响应辩解 / 人工裁决 / 文档生命周期）沿用通用规则
- **驳回修订后的需求不回流本轮 run**——由后续 run 或正常流程承接；本归档若重启审视，**覆盖重产** review/requirement-review.json（旧结论不重用）

### 向上游反馈话术

```
⚠️ [需求文档 X] 已驳回给 PM

驳回理由：[一句话说明，引用四维中具体哪一维度]
被驳回方看到后可以：接受并修订 / 解释辩解
```

---

## 七、与下游消费端的衔接

> AUDITOR 本身不主动启动 PLANNER——本角色审视完成 + 产物落盘后，由 PM 推荐话术的用户侧确认触发规划者启动，规划者经 `delivery-bridge.cmd -Command promulgate -TaskJson <task.json> -ReviewFile <归档>/review/requirement-review.json` 机械消费。

**消费端契约现成零改动**（设计保证）：
- `delivery-bridge.ps1` 仅检查 ReviewFile 非空 + `verdicts[]` 字段合法性 + 字段约束
- `reviewer` 字段值（枚举 `auditor-delegated` / `auditor` / `planner`）对消费端透明（仅查非空）
- `reject_return` / `tree_adjudicated` / `pass` 三态处置流程不变
- **错误码清单**（消费端可预期的确定性反馈，planner-scenarios「异常处置速查」同源）：
  - `REVIEW_FILE_INVALID` — ReviewFile 不可解析 / schema 违规 / 字段一致性冲突（pass 带_override|merged、一 verdict 双字段、task_id 重复等），建树前零残留
  - `REVIEW_TASK_NOT_FOUND` — verdict/override/合并目标指向的 task_id 不在该归档
  - `REVIEW_EXCLUDED_DEP` — 某任务依赖被驳回排除的任务：依赖不会被静默丢弃，planner 须补裁定该任务（`depends_on_override` 或一并驳回）

**审计追溯**：
- `bridge.json v2` 顶层 `review` 段落盘（含 `reviewer` 字段，便于区分生产形态）
- run 侧 `report/review.md`（人读镜像，逐条结论表）——与归档 `review/requirement-review.md` 并存，前者是 run 消费端镜像，后者是归档内产物镜像，**两者并存职责不同**

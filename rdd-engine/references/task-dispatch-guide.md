# 任务派发验收契约（task-dispatch-guide）

> **定位**：tree-run 节点派发与验收的**标准协议**。Manager 在 graft 时按本文档定型任务、附带验收契约；worker 按契约交付；引擎按硬门禁对账。与 `tree-run-guide.md`（循环权威）配套——本文档管"每个节点派什么、怎么算完成"。
>
> **版本**: V1.1（2026-09-09 增补附录 A：M1/M2 引擎落地 schema——graft/回调的具体格式与错误码处置。协议文本见 V1 种子版）。来源事故与设计论证：`D:\YaphetHayate\projects\todo\2026-09-08-openrca-treerun-验收契约设计.md`。
>
> **V1 粒度规则（已拍板）**：覆盖清单粒度由 **manager 单方决定**（时间 × 模态，5–15 格）；worker 细化协商为 V2 backlog。

---

## 速查卡（Manager graft 前必读，≤60 行）

```
┌─ 1. 定性：这句 goal 在问什么？ ─────────────────────────────┐
│ 要穷举域内发现（含阴性）        → Sweep   （覆盖图验收）      │
│ 要证实/证伪一个具体假设         → Probe   （证伪义务验收）    │
│ 要调和证据产出结论              → Synthesis（无缺口验收）     │
│ 要预处理/搬运/切分数据          → Transform（对账验收）       │
└──────────────────────────────────────────────────────────┘
┌─ 2. 定规模（引擎预采名义值，worker 报 delta） ───────────────┐
│ 名义规模 = 文件大小/行数/目录结构（graft 时引擎写入派发）      │
│ 有效规模 = schema 意外/实际遍耗时（worker FEASIBILITY 上报）  │
│ S: 名义值覆盖无压力  M: 需方法声明  L: 需方法+预算+分块对账   │
└──────────────────────────────────────────────────────────┘
┌─ 3. 拆解判据（一句话） ────────────────────────────────────┐
│ 方法内伸缩自己扛；域覆盖缺口必须上报。                        │
│ 试金石：我此刻崩溃，树知不知道还剩什么没覆盖？                │
│   自扛 = 分块读取/多遍扫描/脚本迭代（保证不变、域不变）        │
│   上报 = 预算只够覆盖域的一部分 / 需要不同保证等级 / 崩溃不可恢复│
└──────────────────────────────────────────────────────────┘
┌─ 4. 派发五件套 ───────────────────────────────────────────┐
│ task = goal + domain + deliverable schema + 验收契约 + budget│
│ Sweep 必附 coverage manifest（预分区清单，5–15 格）           │
│ Probe 必附证伪义务字段    Synthesis 必消耗全部 ledger 保证等级 │
└──────────────────────────────────────────────────────────┘
┌─ 5. settle 三值 ──────────────────────────────────────────┐
│ done（契约全过）/ done_with_caveats（缺口如实披露，不惩罚）    │
│ / fail（未披露缺口被对账发现 → 重派）。                        │
│ 披露的捷径合法；未披露的捷径 fail。                           │
└──────────────────────────────────────────────────────────┘
```

---

## 一、任务公式与两轴分类

> **task = goal + domain + deliverable schema + acceptance contract (+ budget)**

| 轴 | 取值 | 决定什么 |
|----|------|---------|
| **A 性质** | Sweep / Probe / Synthesis / Transform | 验收标准的形状（见模板） |
| **B 规模** | S / M / L | 预算模板与拆解政策 |

**名义规模 vs 有效规模**：引擎 graft 前预采客观数据指标（文件大小、行数、目录结构）写入派发——tier 判定不靠猜；worker 只上报**有效规模 delta**（schema 意外、实际遍耗时），FEASIBILITY 是增量报告不是求救信号。

## 二、四类契约模板（manager 填槽）

> **角色卡选卡引用（填槽第一步）**：定性（A 轴）之后按承接性质选角色卡，整卡嵌入派发 prompt 或按路径引用（`rca-roles/<role-id>.md`）——卡内已固化该角色的方法预设与交付 schema，manager 填槽时**零即兴改写**：
>
> | 定性 | 可选角色卡（权威定义见 `rca-roles.md`） |
> |------|------------------------------------------|
> | Transform | `rca-roles/data-prep.md` |
> | Sweep / Probe | `rca-roles/metric-analyst.md` · `rca-roles/log-analyst.md` · `rca-roles/trace-analyst.md`（按模态选） |
> | Synthesis | `rca-roles/root-cause-analyst.md` |
>
> Probe 派发额外带 `falsification_duty` 字段（见 §2.2 与附录 A.1）；一次派发只绑定一种性质。

### 2.1 Sweep（普查）——重契约

```json
{
  "type": "sweep",
  "goal": "<枚举域内所有 X，输出 finding 表>",
  "domain": {"t_start": "...", "t_end": "...", "scope": "<文件/组件/模态>（说明性字段；机械域在 run 级 start -DomainJsonFile 声明）"},
  "manifest": {
    "granularity": {"time_bucket_s": 600},
    "cells": [{"id": "c01", "interval": ["YYYY-MM-DD HH:MM:SS", "YYYY-MM-DD HH:MM:SS"], "modality": "metric"}]
  },
  "deliverable": "finding 表：同实体多异常逐 episode 一行（禁止折叠首峰）；每行 interval+证据引用",
  "acceptance_hard": ["清单无空格（found/clean/escalated 三态）", "声明落在扫描范围内", "clean 格挂工件"],
  "acceptance_audit": ["粒度与基线合理性"],
  "budget": "<遍数上限/时间>"
}
```

> 注意：graft 时的 cells **不带 status**——清单冻结在 declared，状态由 worker 回调的 `extras.manifest.filled` 填写（见附录 A.2）。具体字段格式与校验规则以**附录 A**为准。

**格式铁律**：`14:39 & 14:57 → onset 14:39 (episodic)` 是禁止项——两个 episode 两行；峰数是排序特征，不是丢弃理由。

### 2.2 Probe（验证）——中契约

```json
{
  "type": "probe",
  "hypothesis": "<可证伪表述：什么证据会推翻它>",
  "falsification_duty": "<必须尝试的反例路径>",
  "deliverable": "verdict + 证据区间 + 反例尝试记录",
  "acceptance_hard": ["假设含可证伪条件", "verdict 挂证据"],
  "acceptance_audit": ["方法是否真的尝试过推翻"]
}
```

**反模式**：纯确认式 probe（只找支持证据）= 确认偏误放大器。resume 得来的 inherited ledger 结论一律视为 unverified，**"与前次收敛"不计为证据**。

### 2.3 Synthesis（综合）——重契约

```json
{
  "type": "synthesis",
  "acceptance_hard": [
    "答案 ∈ 查询域（时间型任务：落在查询窗口 ± 容差内）",
    "覆盖并集无未认领格（引擎合并全部 Sweep manifest 集合运算）",
    "消耗每个 ledger 条目的保证等级（full-coverage / opportunistic / disclosed-gap）"
  ]
}
```

### 2.4 Transform（加工）——轻契约

```json
{
  "type": "transform",
  "deliverable": "<输出 schema>",
  "acceptance_hard": ["行数/计数对账", "输出可解析", "幂等（重跑同结果）"]
}
```

## 三、FEASIBILITY 上报格式（worker 领取后开工前）

```
FEASIBILITY {
  type_dispute:  none | "<对定性的质疑及理由>",
  blockers:      ["<客观数据障碍：文件/行数/缺失列>"],
  domain_at_risk:["<按当前方法无法覆盖的域片段>"],   # 关键字段；无风险也须显式空
  proposed_split:{ key: "<拆分键>", slices: [...], need_aggregator: true },
  floor_check:   "低于拆分阈值，已自扛（方法：分块读取）"
}
```

拆分模式固定 map-reduce：叶子切片 + 聚合节点折叠。拆分键 worker 提议（局部知识）、manager 批准（全局一致）；扇出 ≤ NodeWidth；最大拆解深度 2；低于阈值必须自扛。

## 四、反模式清单（R1–R9，每条注事故出处）

| # | 反模式 / 规则 | 出处 |
|---|---|---|
| R1 | Sweep 派发无预分区清单，worker 自选扫描范围 | rca-133915 n3：只扫 14:28–14:41，[14:41,15:00] 从未被分配 |
| R2 | 多峰折叠为首峰 + "episodic" 标签 | rca-133915 n2：`14:39 & 14:57 → 14:39`，真值分钟被表格自己丢掉 |
| R3 | 域覆盖缺口沉默（把域问题当方法问题） | rca-133915 n3：扫描范围从兄弟结论倒推 |
| R4 | Synthesis 收尾不查覆盖并集 | [14:50,15:00] 无人认领，GT 14:57 正在其中 |
| R5 | 纯确认式 probe / inherited 结论当证据 | rca-133915 round-2 "pre-window verification"；"与前次收敛"自证 |
| R6 | 名义规模不预采，规模靠猜 | 1.25GB trace 事后才知；schema 缺列开工才知 |
| R7 | 披露缺口受罚（逼 worker 隐瞒） | 设计推演：不对称惩罚——披露=pass-with-caveats，未披露=fail |
| R8 | clean 声明不挂工件 | rca-133915 pass1 输出自带 tmin/tmax（工件自证的实证） |
| R9 | 兄弟域零重叠（放弃免费测谎） | n2/n3 模态冗余本可交叉验证 |

**新增规则必须带事故出处**（post-mortem PR 纪律）。

## 五、瞒报防线（五层摘要）

1. **预分区清单**：义务枚举后，隐瞒从决策问题变成对账问题（主防结构性无知）。
2. **工件遥测自证**：扫描工件自带 tmin/tmax/行数，引擎免重跑对账。
3. **交叉验证**（V2）：兄弟 Sweep 域刻意重叠 10–20%，分歧率 = 可信度信号。
4. **抽样审计**（V2）：settle 前抽结论关键路径附近的阴性声明重查。
5. **激励**：披露不罚、瞒报整单 fail——让诚实成为最便宜策略。

## 六、归属分层

- **引擎层（本目录）**：速查卡、四类模板骨架、FEASIBILITY 格式、反模式清单——跨项目通用。
- **领域物挂引擎目录**：RCA 角色族（`rca-roles.md` 权威索引 + `rca-roles/` 落地卡）是 OpenRCA 类根因调查的领域方法论，挂在引擎层 `references/` 供跨项目取用；其内容受红线约束（只含通用 SRE 方法论，零基准题目特有答案知识），引擎对其只做格式级机械支持（role 标识格式校验，不校词表——词表权威在 `rca-roles.md`）。
- **项目层（`<project>/.rdd/`）**：领域槽位（如 OpenRCA 的时间窗语义、遥测模态定义、粒度默认值）。派发引用模板 ID + 项目槽位填充。

## 七、落地状态

- **M1 ✅（2026-09-09）**：R1（settle 清单完整性）+ R4（conclude 覆盖并集）已接入引擎 CLI，warn/enforce 两档，legacy run fail-open 零影响。
- **M2 ✅（2026-09-09）**：R2（findings 折叠检测）+ R8（clean 工件对账）+ found 挂 findings 行 + spotcheck 防伪抽查（note-only 观察期）已接入 report 链路。单测累计 48 项。
- **M3 ✅（2026-09-10，角色感知部分）**：R5 已机械接入——graft 硬拦 `GRAFT_FALSIFICATION_REQUIRED`（结构契约派发时拦截）+ report 对 `extras.probe` 三值 note-only 对账；`role` 标识 graft 声明 → node 持久化 → ledger 追溯（`ROLE_INVALID` 格式校验，不校词表）；与 RCA 角色卡（`rca-roles/`）构成"文档定义 + 引擎校验"闭环。单测累计 65 项。R6 名义规模预采、R7 settle 三值化维持 V2 backlog（角色卡 worker 侧规模预采不受影响）。
- **附录 A = 机械格式权威**：与以上协议文本冲突时，以附录 A 为准。

## 附录 A：引擎落地 schema（M1/M2 已接入，机械格式权威）

> 时间戳一律 `YYYY-MM-DD HH:MM:SS`，区间为闭区间。本附录描述 `tree-run.ps1` / `tree-leaf.ps1` 实际校验的格式。

### A.1 Manager：run 启动与 sweep 派发

**run 启动（时间域任务）**：

```powershell
tree-run.cmd -Command start -RunId <id> -Goal "<goal>" -RefRoots .
  -DomainJsonFile <domain.json> -GateMode enforce -CoverageToleranceS <秒>
```

`domain.json`（注意：inline `-DomainJson` 会被 powershell/cmd 传参剥引号，**一律用文件**）：

```json
{"intervals": [["2021-03-04 14:30:00", "2021-03-04 15:00:00"]], "scope": ["telemetry:Bank"]}
```

- `-GateMode warn|enforce`：默认 warn（只记 R1-WARN/R4-WARN 不拦）；enforce 时 settle/conclude 硬拦
- `-CoverageToleranceS`：R4 缺口算术的容忍秒数（≤tolerance 的边界尾巴不算缺口）；0 = 严格
- conclude/settle 时 `-Override warn|enforce` 可单次覆盖 run 级档位

**graft sweep 任务**（`-TasksFile`，JSON 数组，每项一个任务）：

```json
[{
  "title": "metric sweep 14:30-15:00",
  "task": "<任务正文，须包含本附录 A.2 的回调格式要求或指向本文件>",
  "type": "sweep",
  "role": "metric-analyst",
  "manifest": {
    "granularity": {"time_bucket_s": 600},
    "cells": [
      {"id": "m01", "interval": ["2021-03-04 14:30:00", "2021-03-04 14:40:00"], "modality": "metric"},
      {"id": "m02", "interval": ["2021-03-04 14:40:00", "2021-03-04 15:00:00"], "modality": "metric"}
    ]
  }
}]
```

**graft probe 任务**（角色感知契约，对齐 §2.2 与角色卡 probe 差异节）：

```json
[{
  "title": "verify hypothesis H on metric channel",
  "task": "<单向证伪表述：什么观测会推翻该假设>",
  "type": "probe",
  "role": "metric-analyst",
  "falsification_duty": "<必须尝试的反例路径，非空字符串>"
}]
```

- `type: "sweep"` 无 `manifest` → `GRAFT_MANIFEST_REQUIRED`；cells 非法（重复 id / 时间戳格式错 / end≤start）→ `GRAFT_MANIFEST_INVALID`
- `type: "probe"` 缺 `falsification_duty`（或空白串）→ `GRAFT_FALSIFICATION_REQUIRED`（结构契约在派发时拦截，Manager 补齐后重 graft）
- `role`：可选字段，kebab-case `^[a-z0-9]+(-[a-z0-9]+)*$`、长度 ≤64，否则 `ROLE_INVALID`。**引擎只校格式不校词表**——角色词表权威在 `rca-roles.md` / `rca-roles/` 角色卡（引擎层跨项目通用，领域槽位在引用层）。`type` / `role` / `falsification_duty` 平铺持久化进 node（可选字段，可 null；legacy run 无这些字段 → null，fail-open 零影响）
- 多个 sweep 的 cells 并集须铺满查询域（R4 在 conclude 按全部 found/clean 格并集对账）；相邻格共享边界时间戳合法
- 非 sweep/probe 任务不写 type/manifest/falsification_duty，行为零变化（role 可选声明）

### A.2 Worker：report 回调的 extras 契约

```json
{
  "extras": {
    "manifest": {
      "filled": {
        "m01": {"status": "found", "evidence": [{"ref": "sweep_metric.csv", "tmin": "2021-03-04 14:30:00", "tmax": "2021-03-04 14:40:00", "rows": 600}], "note": "CPU-0 hog"},
        "m02": {"status": "clean", "evidence": [{"ref": "sweep_metric.csv", "tmin": "2021-03-04 14:40:00", "tmax": "2021-03-04 15:00:00", "rows": 600}]}
      }
    },
    "findings": [
      {"entity": "CPU-0_SingleCpuUtil", "interval": ["2021-03-04 14:39:00", "2021-03-04 14:40:00"], "evidence": ["sweep_metric.csv"], "note": "burst 87%"}
    ],
    "probe": {
      "verdict": "refuted",
      "falsification_attempted": ["pre-window baseline check: no envelope crossing before the window"]
    }
  }
}
```

> `extras.probe` 仅 `type: "probe"` 节点对账（结构定义与角色卡 probe 差异节单点对齐：`rca-roles/metric-analyst.md` 等）；其余性质的 extras 命名空间见角色卡交付 schema（`extras.deliverables` = Transform / `extras.conclusion` = Synthesis，机械面透传不校验）。

**填格规则（引擎在 report 时机械校验；违规格退回 pending 并记 notes；report 本身永不被拒）**：

| 格状态 | 要求 |
|---|---|
| `found` | ≥1 条 findings 行且其 interval 落在该格 interval 内；evidence 可为裸引用字符串 |
| `clean` | evidence 必须是对象化条目 `{ref, tmin, tmax}`：ref 在 RefRoots 内且磁盘存在；**格子 interval ⊆ [tmin, tmax]**；裸字符串不够 |
| `escalated` | 豁免（诚实上报没有工件）；note 须写明原因与缺口影响 |

**findings 行铁律（R2）**：同实体多 episode 必须多行，每行自带独立 interval + ≥1 evidence 引用。行内文本出现 `14:39 & 14:57` / `14:39/14:57` / `14:39,14:57`（两个相隔 >2 分钟的时间戳并列）= 折叠模式 → 行作废 + 关联格退 pending。写区间用 `14:39-14:41`（连字符）合法。

**evidence 工件**：扫描输出落盘在仓库内（RefRoots 覆盖），工件自带时间遥测（首/末行时间戳）——引擎抽查首尾 50 行对账声明 tmin/tmax，不符记 `spotcheck_mismatch` note（观察期只记不罚）。

### A.3 门禁错误码与处置

| 错误码 | 触发点 | 含义与处置 |
|---|---|---|
| `GRAFT_MANIFEST_REQUIRED` | graft | sweep 任务缺 manifest → 补上再 graft |
| `GRAFT_MANIFEST_INVALID` | graft | cells 格式非法（错误信息指明哪格）→ 修正 |
| `GRAFT_FALSIFICATION_REQUIRED` | graft | `type:"probe"` 任务缺非空 `falsification_duty`（R5 结构契约在派发时拦截，零运行中状态风险）→ 补齐证伪义务字段后重 graft |
| `ROLE_INVALID` | graft | `role` 非 kebab-case 或长度 >64 → 改为 `^[a-z0-9]+(-[a-z0-9]+)*$` 格式（词表不校验，权威在角色卡） |
| `DOMAIN_UNPARSEABLE` / `DOMAIN_FILE_NOT_FOUND` | start | 域 JSON 非法/文件不存在 → 改用 `-DomainJsonFile` |
| `SETTLE_MANIFEST_INCOMPLETE` | settle (enforce) | 有格子未达终态（pending 或被 R2/R8 打回）→ report 一次性语义：节点不能重报，只能 `prune` + 重新 graft 补扫 |
| `CONCLUDE_COVERAGE_GAPS` | conclude achieved (enforce) | 查询域有未覆盖缺口（错误信息列出区间）→ graft 覆盖缺口的 sweep 并 settle；或诚实 `budget_exhausted`（需预算真实耗尽） |
| `BUDGET_NOT_EXHAUSTED` | conclude | budget_exhausted 但预算没用完 → 继续干活，或改 achieved/space_exhausted |

**probe 三值对账（note-only 观察期）**：`type:"probe"` 节点 report 时，引擎对 `extras.probe` 做 note-only 对账（对齐 spotcheck / manifest_missing"只记不罚"先例，report 永不被拒）——缺 `extras.probe` → `probe_extras_missing`；缺 verdict → `probe_verdict_missing`；verdict 非 `upheld|refuted|inconclusive` → `probe_verdict_invalid`；`falsification_attempted` 空 → `probe_falsification_not_recorded`（纯确认式 probe 违反 R5）。全部落 ledger 条目 `validation.notes`。

**角色追溯链**：node `type` / `role` / `falsification_duty`（tree.json，写前 .bak + 写后 read-back）→ report 时复制 `node.role` 到 ledger entry 顶层（恒存在可 null；task_type 不进 ledger——extras 结构已可区分性质）→ status / resume / next 公开视图统一带 `role` / `type`。legacy run（无这些字段）→ null，全部新逻辑跳过。

**escalated 是 R1 合法终态**（settle 放行）但 **R4 计为未覆盖**——诚实披露让你能结算，不给你伪装覆盖。

### A.4 可见性

- `tree-run status/resume` → `coverage` 块（domain / gates / sweeps / covered_spans / gaps）
- `tree-leaf status -NodeId <n>` → 该节点 `manifest`（declared + filled + findings 全景）
- ledger 条目 `validation.notes` → 全部 R1'/R2/R8/spotcheck 提示的落点

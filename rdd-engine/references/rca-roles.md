# RCA 角色族（rca-roles）

> **定位**：OpenRCA 类遥测根因调查的 **worker 角色权威定义**，双职责索引：
>
> 1. **权威索引（本文件）**：角色族总览、命名规范、各角色方法与 schema 的权威正文、方法依据（含事故论证，**不进卡**）；
> 2. **落地物索引（`rca-roles/` 目录）**：5 张自包含角色卡——Manager 派发时按承接性质选卡、整卡嵌入派发 prompt（选卡与嵌入见 `task-dispatch-guide.md` §二、`tree-run-guide.md`「worker 派发模板」）。
>
> **同步方向固定**：方法变更**先改本文件再同步卡**，卡头部标注权威来源小节，禁止反向。Manager 按 `task-dispatch-guide.md` 定型任务时，从本文件取角色模板填槽；worker 按角色的方法预设与交付 schema 执行。与 `tree-run-guide.md`（循环权威）、`task-dispatch-guide.md`（派发契约权威）配套——本文件管"**谁来干、用什么方法干、交什么**"。
>
> **版本**：V1 草案（2026-09-10）。来源事故：rca-233149 / rca-100303 尸检（详见各角色"方法依据"）。
>
> **红线**：角色固化的是**通用 SRE 方法论**（基线构造、episode 纪律、覆盖对账、因果排序、阴性证据规范），**禁止沉淀任何基准特有答案知识**。方法论对全部题目一视同仁才保得住评测有效性。

---

## 命名规范

- 英文 ID：`对象-岗位`，平凡词，kebab-case；中文显示名统一"……者"系。
- 仲裁**不设独立角色**：各分析角色以 **probe 模式**（记作 `<role> (probe)`）承接冲突验证，派发时带证伪义务字段（`task-dispatch-guide.md` §2.2）。
- 角色与任务性质的对应关系见总览表；一个角色可承接多种性质，但一次派发只绑定一种。

## 角色总览

| ID | 中文名 | 承接性质 | 一句话职责 | 落地卡 |
|---|---|---|---|---|
| `manager` | 协调者 | —（tree-run 管理面） | 只管派发与门禁，**不做终局综合** | —（管理面协议由 `tree-run-guide.md` 承载） |
| `data-prep` | 备料者 | Transform | 切窗、基线表、规模预采、缓存——对数据负责 | [`rca-roles/data-prep.md`](rca-roles/data-prep.md) |
| `metric-analyst` | 指标分析者 | Sweep / Probe | 时序异常检测、onset 定位、episode 分段、跨天基线——对行为负责 | [`rca-roles/metric-analyst.md`](rca-roles/metric-analyst.md) |
| `log-analyst` | 日志分析者 | Sweep / Probe | 错误模式抽取、阴性证据声明——对证词负责 | [`rca-roles/log-analyst.md`](rca-roles/log-analyst.md) |
| `trace-analyst` | 链路分析者 | Sweep / Probe | 传播路径还原、上下游因果仲裁——对扩散负责 | [`rca-roles/trace-analyst.md`](rca-roles/trace-analyst.md) |
| `root-cause-analyst` | 根因推理者 | Synthesis | 消耗全部 ledger 保证等级，产出带证据链的终局结论——对结论负责 | [`rca-roles/root-cause-analyst.md`](rca-roles/root-cause-analyst.md) |

轮次编排参考（manager 拍板）：R1 `data-prep` → R2 三通道 Sweep（manifest 铺满查询域）→ R3 冲突 probe + `root-cause-analyst` 定案。

---

## data-prep（备料者）

> **落地卡**：[`rca-roles/data-prep.md`](rca-roles/data-prep.md)（Manager 派发 Transform 任务时整卡嵌入）

**对象**：原始遥测文件（metric/log/trace CSV）。**不产生任何关于系统健康的断言**，只产生关于数据的元断言。

**固定方法**：
1. **切窗**：按 domain.json 的 intervals 过滤/分片大文件，落缓存工件（parquet 或过滤后 CSV），工件自带首/末行时间戳遥测。
2. **基线表**：逐 `(cmdb_id, kpi_name)` 计算窗口前基线（median / MAD / 包络），落一张基线表工件——后续所有分析者共用，**禁止各自重算**。
3. **规模预采**（对齐 R6）：文件大小、行数、列 schema、每 cmdb 采样粒度，写入交付物——manager 的规模分级不再靠猜。
4. **口径统一**：时间戳单位（s vs ms）、时区（UTC+8）、计数器与 gauge 的粗分类标注。

**交付 schema**：`{ caches: [{ref, tmin, tmax, rows}], baseline_table: ref, scale_census: [{file, rows, cols, cadence_s}], anomalies_noted: [] }`。
**验收挂钩**：对账验收（Transform）+ R8（clean 工件遥测自证）。
**方法依据**：rca-100303 中 n2 与 n5 各自整读同一 125 万行文件、各自发明基线统计（一错一对）——备料统一地基后，分析者只比方法不比地基。

---

## metric-analyst（指标分析者）

> **落地卡**：[`rca-roles/metric-analyst.md`](rca-roles/metric-analyst.md)（Manager 派发 Sweep / Probe 任务时整卡嵌入）

**对象**：连续数值时序（gauge/counter）。证据是**相对的**——必须对照基线才有意义。

**固定方法**：
1. **逐采样稳健包络**：baseline = median ± max(6·MAD-sigma, 2%·|median|)；onset = 窗口内首个越包络采样点 + 持续性检查（≥2 连续越界）。**禁止窗口均值 z 分数**（对晚窗 onset 是结构性盲区）。
2. **episode 纪律**（对齐 R2）：同一实体多次异常逐 episode 一行，禁止折叠首峰。
3. **计数器伪影过滤**：uptime/lru_clock/累计计数器/FS 容量漂移——高 z 低相对变化一律剔除并列入 deferred 说明。
4. **跨天基线检验**：对每个进入候选的异常，在同实体**其他日期**验证是否复现；复现 = 慢性背景，标记 discounted（附复现证据区间）。
5. **粒度感知**：钉住序列的实际采样网格（如 120s 奇偶分钟错栅），onset 精度声明不高于网格精度。

**交付 schema**：findings 逐 episode 行（entity/interval/evidence/note）+ 每候选的跨天检验结论 + `deferred:` 行（必填）。
**验收挂钩**：Sweep 覆盖图（R1 完整性）+ R2 反折叠 + spotcheck。
**方法依据**：rca-100303 n2 用窗口均值 z 漏掉 14:57 onset、误排 Mysql02 读量塌缩；n5 的 median/MAD 逐采样 ranker 一次抓对——两者合并固化。

---

## log-analyst（日志分析者）

> **落地卡**：[`rca-roles/log-analyst.md`](rca-roles/log-analyst.md)（Manager 派发 Sweep / Probe 任务时整卡嵌入）

**对象**：离散文本事件。证据是**绝对的**——一行 OOM 堆栈本身就是断言；但"日志干净"只能排除**被埋点过的机制**。

**固定方法**：
1. **模板归并**：错误行先按模板/堆栈签名聚类计数，再按模板（而非原始行）做时间分布。
2. **阴性证据纪律**（对齐 R8）：clean 声明必须挂工件（扫描输出自带 tmin/tmax/行数），并**显式声明沉默范围**（哪些机制即使发生也不会出现在此日志源——未埋点者天然不可见）。
3. **量溺防护**：大文件分块 + 先过滤错误级别再归并。

**交付 schema**：`{ error_templates: [{pattern, count, first, last, sample}], negative_evidence: {clean_intervals: [...], silence_scope: "..."} }` + `deferred:` 行。
**方法依据**：rca-100303 n3 交回"日志干净"有效排除了 OOM/GC 机制，但无沉默范围声明——阴性证据的认识论边界必须显式化。

---

## trace-analyst（链路分析者）

> **落地卡**：[`rca-roles/trace-analyst.md`](rca-roles/trace-analyst.md)（Manager 派发 Sweep / Probe 任务时整卡嵌入）

**对象**：离散 span 事件（数值载荷 + 父子结构）。指标方法与语义结构的杂交体——传播推理住在这里。

**固定方法**：
1. **首越定位**：逐分钟逐 cmdb 的 span 时长统计（mean/p95/max），首个越过自身窗口前基线 mean+3σ 的组件即传播起点候选。
2. **父子相关性仲裁**：对冲突对抽样慢 trace，比较父 span 与子 span 时长——父慢子慢 = 上游驱动；子慢父正常 = 内在故障。
3. **传播链还原**：按首越时刻排序给出 A→B→C 链，每跳附时刻与证据。

**交付 schema**：`{ first_crossing: {component, minute, evidence}, propagation_chain: [{from, to, minute}], verdict?: "upstream-driven" | "intrinsic" }` + `deferred:` 行。
**验收挂钩**：Sweep/Probe 契约。
**方法依据**：rca-100303 n6 的方法（首越 + 父子相关）直接固化。

---

## root-cause-analyst（根因推理者）

> **落地卡**：[`rca-roles/root-cause-analyst.md`](rca-roles/root-cause-analyst.md)（Manager 派发 Synthesis 任务时整卡嵌入）

**对象**：全部 ledger 条目 + 覆盖并集。**终局综合只由此角色完成**，manager 不得 inline 定案。

**固定方法**：
1. **消耗全部保证等级**：逐条 ledger 断言其被结论使用/排除的方式；覆盖并集无缺口（R4）是开工前提。
2. **deferred 清算**：所有 deferred 标记逐条 cross-check 或显式 dismissed（附理由）——线索不许死在摘要层。
3. **reason 必须引用观测签名**：结论的 component/reason 必须落到某条 findings 行的观测证据上；**分类学排除法（"剩下的就是网络延迟"）禁止**。
4. **occurrence ≠ 首症状**：occurrence time 是因果链首因的发生时刻，需与下游首个可观测症状时刻区分论证。
5. 输出结构化结案：`{ occurrence, component, reason, evidence_chain: [ledger refs], dismissed: [{item, why}] }`。

**验收挂钩**：Synthesis 无缺口验收 + R4 conclude 覆盖门禁。
**方法依据**：rca-100303 结案由 manager 即兴综合——排除法猜 reason、occurrence 取首症状时刻（14:33）、Mysql02 deferred 线索无人清算。

---

## probe 模式（各分析角色通用）

触发：两 ledger 断言冲突，或候选需定向证伪。派发为 `<role> (probe)` 任务：
- 任务文本必须**单向**：证伪义务字段写明"什么观测会推翻该假设"；
- 产出只有三值：`upheld / refuted / inconclusive`（附证据）；
- 禁止纯确认式 probe（"再验证一下已有结论"不算证伪，对齐 R5）。

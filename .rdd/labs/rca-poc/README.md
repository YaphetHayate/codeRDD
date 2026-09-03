# RCA 调查流编排架构预研 PoC

> 归属归档:`.rdd/changes/archive/2026-08-30-rca-investigation-poc/`(需求 + CTO 设计为权威源)
> 本目录为实验根,**PoC 全部产物 confined 于此**;不动 DSH harness、不动 rdd-engine、不进任何角色白名单。

## 1. 目的

验证"**假设树驱动 + Manager-Worker 编排**"架构对超长程根因排查(RCA)任务的可行性:

- **编排臂**(验证对象):goal 驱动的 Manager 会话,每轮读持久化认知状态 → 选假设 → workflow 扇出 N 个新鲜上下文 worker → 采证结构化回调 → 整合证据 → 剪枝/下探 → 停止决策。
- **基线臂**(对照):ralph 循环,每轮 1 个全新 agent 兼规划+采证(单体模式本地化身)。
- **产出**:三层验证结论 + 归属判据报告(原语够用性/格式稳定性/归属建议)。

验证的是**架构机制**(循环能否运转、假设树能否驱动下探),不是 AI 排查智力。

## 2. 目录结构

```
rca-poc/
├── README.md                  ← 本文件
├── datasets/                  ← 外部素材克隆(gitignore,只读,--depth 1;获取方式见 §5)
├── cases/
│   ├── registry.jsonl         ← 案例注册表(来源/改装规则版本/答案托管/审计摘要)
│   ├── l1-mock/mock-00X/      ← DEV 手造玩具故障:case.json + plane/(静态观测面)
│   ├── l2-openrca/openrca-*/  ← convert-openrca.mjs 产物(与 l1 同构)
│   └── l3-postmortem/pm-*/    ← L3 补充案例(同构)
├── prompts/
│   ├── manager-system.md      ← Manager 认知状态协议 + 决策规则 + 停止语义
│   ├── worker-dispatch.md     ← Worker 派发模板(单假设验证 + 只读边界 + 回调协议)
│   └── ralph-baseline.md      ← 基线臂 objective 模板
├── tools/
│   ├── convert-openrca.mjs    ← L2 观测面改装脚本(改装规则 = 可审代码)
│   └── score.mjs              ← 对托管答案评分 + 两臂汇总
├── runs/<案例id>-<arm>-<序号>/ ← 运行实例(结构见 §4)
└── analysis/                  ← 观察项落档 / 评分产物 / 改装审计 / 归属判据素材
```

## 3. 三层验证矩阵

| 层 | 载体 | 验证目标 | 失败归因 |
|----|------|----------|----------|
| L1 冒烟 | `cases/l1-mock/`(自造 mock;SRE-skills-bench 抽样可选) | 循环全链路机械结构:建树→派发→回调→剪枝/下探→下一轮→停止;状态持久化与断点恢复 | L1 失败 = 架构机械问题 |
| L2 能力 | `cases/l2-openrca/`(OpenRCA 5~10 案例改装回放) | 调查能力,至少 1 案例收敛真实根因,证据链完整可复核 | L2 失败 = 调查能力问题 |
| L2 对照 | 同上 + ralph 基线臂 | 编排增益:两臂同案例同预算对照 | 不高于基线 = 编排无增益信号 |
| L3 补充 | `cases/l3-postmortem/`(postmortem 回放) | 真实噪声鲁棒性 | — |

## 4. 运行实例与状态格式(全部带 `format_version`,格式稳定性 = 归属判据载体)

```
runs/<案例id>-<arm>-<序号>/
├── manifest.json              # case_id / arm(orchestrated|baseline) / 预算 / format_version / final_state
├── state/
│   ├── hypothesis-tree.json   # 假设树(唯一权威认知状态,Manager 每轮首读)
│   ├── evidence-chain.jsonl   # 证据链(追加式,每条:id/round/hypothesis_id/type/断言/引用)
│   └── round-log.jsonl        # Manager 每轮决策快照(派发/整合/剪枝/下探/停止判定)
└── report/
    ├── rounds/round-NN.md     # 轮次人类复核快照
    └── final-report.md        # 结案报告(根因结论 + 证据链索引 + 停止原因)
```

**状态文件权威契约**(Manager/worker 双方遵守,详见 `prompts/`):

- `hypothesis-tree.json`:`{format_version, case_id, updated_round, nodes[{id,parent,statement,prior,status(pending|supported|pruned|concluded),confidence,prune_reason,evidence_ids,children}], active_focus[], conclusion{root_cause_hypothesis,confidence,stop_reason}}`
- `evidence-chain.jsonl` 每行:`{id, round, hypothesis_id, worker, type(correlational|causal), assertion, citations[{file,locator}], confidence(0~1), verdict(support|refute|inconclusive), note}` — **文件为追加式,禁止改写历史行**
- `round-log.jsonl` 每行:`{round, started_at, dispatched[], integration{pruned[],dove[],range_check_failures[]}, verify_prune_applied[], decision, stop_check{top_confidence, threshold, rounds_left}, ended_at}`

**答案结构性隔离**(决策 #4):根因答案**不进** `cases/` 目录——托管于 `analysis/scoring/answers.jsonl`,仅评分脚本 `score.mjs` 读取;worker 的只读边界为 `cases/<tier>/<id>/plane/`,prompt 层禁读 `analysis/` 与 `datasets/`(沙箱无子目录 ACL,结构性隔离压爆炸半径,越界行为记观察项)。

**配置就地化**:无全局配置文件。`max_rounds` / `worker_width`(默认 2~3)/ `confidence_stop`(默认 0.8)/ `verify_prune_prior` 全部写入 run `manifest.json`。

## 5. 运行方式

### 5.0 素材获取(datasets/,只读)

```powershell
git clone --depth 1 https://github.com/microsoft/OpenRCA.git datasets/OpenRCA
git clone --depth 1 https://github.com/Rootly-AI-Labs/SRE-skills-bench.git datasets/SRE-skills-bench
git clone --depth 1 https://github.com/danluu/post-mortems.git datasets/post-mortems
```

> **OpenRCA 注意(2026-08-31 实测)**:git 仓库仅含评测 harness(`rca/baseline/rca_agent` 单体 agent 代码与 prompt,可作基线臂 objective 措辞参照);**遥测数据集外置 Google Drive**(见 `datasets/OpenRCA/dataset/README.md`),需人工下载后置入 `datasets/`。**详细下载步骤见 `docs/dataset-download-guide.md`**(最小集策略/浏览器与 rclone 两种方式/校验清单)。
>
> **执行状态(2026-08-31 收官)**:数据最小集(Bank/2021_03_04)已就位;L2 已执行 4 案双臂(pilot task_1 + 批量 task6-1800/task2-1330/task1-2100,convert RULE_VERSION=2,`--range` 按窗口选案);L3 已执行 pm-001 双臂(CircleCI 蓝本合成回放,`tools/gen-pm001.mjs` 可再生)。结论见 `analysis/attribution-report.md`(三判据全过,PoC 判定成功;两臂对照与评测口径发现见 `analysis/observations.md` §4/§7)。

datasets/ 已 gitignore,不入库、不用 submodule。L1 冒烟仅依赖 `l1-mock`(本地自造,零外部依赖)。

### 5.1 L1 冒烟(编排臂,验证机械结构)

1. **案例就绪预检**(决策 #8,goal 创建前必须):`node tools/score.mjs --preflight cases/l1-mock/mock-001` — 校验 case.json/plane 文件/答案托管齐备,预检不过**不建 goal**;
2. 建 run 目录:从 `runs/_template/` 复制或手写 `manifest.json`,初始化空 `state/`;
3. **创建 goal**(Manager 会话):objective 措辞 = "**完成一次 <案例id> 调查运行并产出结案报告**"(与破案成功解耦,决策 #7),`max_goal_rounds` = manifest 的 `max_rounds`(基线公平性,决策 #2);
4. 每 goal 轮(按 `prompts/manager-system.md` 执行):读 `state/` → 选假设 → `workflow` 扇出 `worker_width` 个 worker(prompt 按 `prompts/worker-dispatch.md`,schema 强制 EvidenceReport 回调)→ 整合(含 confidence ∈ [0,1] 范围校验,决策 #9;高先验剪枝 Manager 亲读 plane 复核,双验规则)→ 更新三个状态文件 → 写 `report/rounds/round-NN.md` → 停止判定;
5. 停止(三选一):置信度达标 → 根因结论 / 预算耗尽 → 如实落档 / 假设空间尽 → **诚实输出"升级人类"**,禁止硬编结论;
6. 评分:`node tools/score.mjs --run runs/<run-id>`(对托管答案,产出 `analysis/scoring/` 结果)。

**断点恢复验证**(验收 1):任一轮 kill 掉 Manager 会话,新会话凭 `state/` 三文件 + round-log 续跑(文件为唯一权威,会话记忆仅缓存)。

### 5.2 L2 能力 + 基线对照

1. 单案例 **pilot** 先行(决策 #10):`node tools/convert-openrca.mjs --case datasets/OpenRCA/<原案例> --out cases/l2-openrca/openrca-<id>` → 人工双向校准(不泄答案 / 不阉割信号)后才批量;
2. 编排臂按 §5.1 跑 5~10 案例;基线臂用 ralph(`prompts/ralph-baseline.md`),`maxRounds` = 编排臂 `max_goal_rounds` 同值,同观测面同现象描述;
3. `node tools/score.mjs --all` 汇总两臂,对照论文单体基线(双口径:本地受控对照为主,论文数字为参照,模型/提示差异显式标注)。

### 5.3 L3 补充

postmortem 改装回放(同构 case.json + plane/),验证真实噪声鲁棒性。改装方式手工 + registry 审计。

## 6. 验收对照(需求 7 条 → 产物位置)

| # | 验收标准 | 产物位置 |
|---|----------|----------|
| 1 | L1 冒烟通过(全链路机械结构 + 状态持久化 + 断点恢复) | `runs/mock-*-orchestrated-*` + `analysis/observations.md` |
| 2 | L2 至少 1 案例收敛真实根因,证据链完整可复核 | `cases/l2-openrca/` + `runs/openrca-*-orchestrated-*` + `analysis/scoring/` |
| 3 | 基线对照(两臂成绩 + 论文参照,如实落档) | `analysis/scoring/summary.md` |
| 4 | 失败归因三分类可用 | §3 矩阵 + `analysis/observations.md` |
| 5 | 归属判据报告(原语够用性 / 格式稳定性 / 归属建议) | `analysis/attribution-report.md`(结案时产出) |
| 6 | 影响范围约束(产物 confined 实验目录) | 本目录;git status 验证 |
| 7 | 只读边界(全部调查动作针对静态快照文件) | plane/ 均为静态文件;observations 落档 |

## 7. 边界声明

- 调查过程不接触任何真实线上系统;观测面为静态快照文件,无观测副作用。
- L3 真实线上偶发问题(等待态原语)排除在预研范围外,缺口记入归属判据报告。
- 证据污染缓解:correlational/causal 强制区分 + 高先验剪枝双验;缓解效果本身作观察项落档(`analysis/observations.md`)。

# L2/L3 阶段执行提示词(rca-investigation-poc)

> 用途:交给下一个执行会话(DEV 角色或 PoC 运行者),驱动 L2 能力验证(OpenRCA)与 L3 补充(postmortem)。
> 前置:L1 冒烟已通过(mock-001 全链路);全部设施就绪。本文件自包含,执行会话无需本会话上下文。

---

你是 RCA 调查流编排架构预研 PoC 的执行者(DEV 角色)。任务归档:`.rdd/changes/archive/2026-08-30-rca-investigation-poc/`;实验根:`.rdd/labs/rca-poc/`(全部产物 confined 于此)。

## 0. 必读(动手前,按序)

1. `labs/README.md` — 目录结构/状态格式契约/运行方式/验收对照
2. `labs/prompts/manager-system.md` — 编排臂 Manager 协议(你要按它扮演 Manager)
3. `labs/prompts/worker-dispatch.md` — Worker 派发模板
4. `labs/prompts/ralph-baseline.md` — 基线臂 objective 模板
5. `labs/analysis/observations.md` — 已有观察项(L1 实证),你将运行期追加
6. 设计文档(归档内 `design/rca-investigation-poc-cto.md` + `-cto-decisions.md`)— 决策与风险

## 1. 阶段零:素材就位(人工前置,不可跳过)

- OpenRCA 遥测数据**不在 git 仓**(仓里只有评测 harness):按 `datasets/OpenRCA/dataset/README.md` 的 Google Drive 链接人工下载,解压置入 `datasets/OpenRCA-data/`(保持原始结构,勿改名)。
- 未就位时:禁止编造数据强行跑 L2;如实报告阻塞,L2 顺延。SRE-skills-bench / post-mortems 已克隆就位。

## 2. 阶段一:L2 单案例 pilot(校准,决策 #10)

1. `node labs/tools/convert-openrca.mjs --probe datasets/OpenRCA-data/<某案例>` 观察实际结构;
2. 结构与 ADAPTER 常量区不符 → 校准 `labs/tools/convert-openrca.mjs` 顶部 ADAPTER(metaCandidates/t0Fields/symptomFields/telemetryDirs/topologyCandidates),置 `ADAPTER_CALIBRATED=true`,`RULE_VERSION` +1;
3. 单案例转换:`--case <源> --out labs/cases/l2-openrca/openrca-<原id> --audit`;
4. **双向校准**(人工,不可省):
   - 泄答案检查:cases/ 目录与 plane/ 内容不得含根因线索标注(R4 已剔,抽查确认);
   - 信号阉割检查:对照原案例,确认调查所需遥测(metrics/logs/拓扑)保留、时间可归一、实体中性化不破坏拓扑关系;
5. 校准通过 → 把脚本输出的 registry 行合入 `labs/cases/registry.jsonl`,该案例 `leak_check` 由 pending-pilot 置 `pass`;
6. 预检:`node labs/tools/score.mjs --preflight labs/cases/l2-openrca/openrca-<id>`,通过才继续;失败=基础设施问题,禁止建 goal(决策 #8)。
7. pilot 案例**先跑一次编排臂**(见 §3 流程),确认可解性(改装没有把案例变成不可解);不可解时按 R1 回退:扩时间窗 `--window -120:15` 重转,或向案例注入拓扑文件,回退事件记 observations。

## 3. 阶段二:L2 批量(5~10 案例,两臂对照)

### 3a. 编排臂(每案例一次运行)

1. 预检(preflight,过才继续);
2. 建 run 目录 `labs/runs/<案例id>-orchestrated-<两位序号>/`:manifest.json(arm=orchestrated;budget 建议 max_rounds=3~5、worker_width=2~3、confidence_stop=0.8、verify_prune_prior=0.6)+ 空 state/ 三件套(参照 mock-001-orchestrated-001 结构);
3. 建初始假设树(Manager 职责:从案例 symptom 生成 3~4 个顶层假设,prior 按合理性);
4. 创建 goal:objective 措辞="**完成一次 <案例id> 调查运行并产出结案报告**"(与破案成功解耦,决策 #7),`max_goal_rounds` = manifest.max_rounds;
5. 每 goal 轮严格执行 manager-system.md §1:轮初**重读 state/ 三文件**(文件为唯一权威)→ 选假设 → workflow 扇出 worker(prompt 按 worker-dispatch.md 填充,EvidenceReport schema 强制回调)→ 整合(confidence ∈ [0,1] 范围校验;citations 缺 file/locator 的回调降级 inconclusive;引用越出 plane/ 的证据拒收并记 range_check_failures)→ 按决策规则更新假设树(高先验 ≥0.6 剪枝前**亲读 plane 双验**)→ **追加式**写 evidence-chain/round-log(**每次写后 read-back 校验全行可解析**,工具无 append 原语,L1 已两次损坏)→ 写 report/rounds/round-NN.md → 停止判定;
6. 停止三选一:置信度达标=根因结论 / 预算耗尽=如实落档 / 假设空间尽=诚实"升级人类"(禁止硬编结论)→ report/final-report.md(含根因结论/证据链索引/排除项/保留缺口)+ manifest.final_state 更新 + goal complete;
7. 评分:`node labs/tools/score.mjs --run labs/runs/<run-id>`。

### 3b. 基线臂(每案例,ralph)

1. 建 run 目录 `<案例id>-baseline-<两位序号>/`(manifest arm=baseline,同构 state/);
2. 用 ralph 工具执行,objective 按 `labs/prompts/ralph-baseline.md` 模板填充;**`maxRounds` = 该案例编排臂 max_goal_rounds 同值**(公平性硬约束);
3. 同观测面、同现象描述;ralph 每轮全新 agent 兼规划+采证,工作区即 run 目录;
4. 完成后 `score.mjs --run` 评分。

### 3c. 对照与落档

1. `node labs/tools/score.mjs --all` → `analysis/scoring/summary.json/md`;
2. 论文参照口径:从 `datasets/OpenRCA/docs/` 或论文(ICLR'25 OpenRCA)取单体基线报告数字,**显式标注模型/提示/预算差异,不并表硬比**(R6 双口径);
3. observations.md §4 填两臂对照(定位成绩/轮次/证据条数效率),**无增益本身是重要归属信号,如实落档**。

## 4. 阶段三:L3 补充(postmortem,1~2 案例)

1. 从 `datasets/post-mortems/` 合集挑选案例,标准:时间线完整、根因明确且可从公开细节构造观测面、规模适中;
2. **手工改装**(无自动脚本):按 convert 的 R1~R5 规则手工构造 `labs/cases/l3-postmortem/pm-<slug>/`(case.json + plane/):时间归一 T0/实体中性化/仅事件前窗口/根因与修复记录一律不进 plane/指标与日志名保留;
3. 答案行追加 `analysis/scoring/answers.jsonl`(verdict_keywords/reject_keywords/key_evidence);registry 合入(audit 注明 handcrafted-from-postmortem + 来源链接);preflight 过后按 §3a 跑编排臂(基线臂可选);
4. L3 验证目标:真实噪声鲁棒性(原始 postmortem 叙述含大量无关细节与模糊时间)。

## 5. 收尾:归属判据报告(结案必产)

L2/L3 完成后(或预算耗尽如实终止后),产出 `labs/analysis/attribution-report.md`,三判据:

- **(a) 原语够用性**:goal/workflow/ralph 组合能否支撑调查循环;缺口清单(workflow 无轮间恢复/无子代理 ACL/schema 无数值边界与 pattern/无等待态原语/会话文件工具无 append 原语——L1 已实证,见 observations §1,运行期追加);
- **(b) 格式稳定性**:hypothesis-tree/evidence-chain 的 format_version 全程是否发生不兼容变更及原因;
- **(c) 归属建议**:基于 (a)(b) + 增益信号(两臂对照)给出——挂 rdd-engine skill / DSH 上游需求 / 独立工程 / 运营期角色化。

## 6. 硬约束(全程)

- 只读边界:调查动作仅针对静态快照文件,禁触真实系统;worker 只读 `cases/<tier>/<id>/plane/`;
- 影响范围:不动 DSH harness、不动 rdd-engine、不进角色白名单;产物 confined `.rdd/labs/rca-poc/`(datasets/ 已 gitignore);
- 诚实红线:证据必须可追溯(file+locator);correlational 不得单独支撑结论;找不到根因=如实"升级人类";预算耗尽=如实落档;**失败与无增益都是有效验证产出,禁止美化**;
- 每轮落盘后如会话中断,恢复=重读三状态文件续跑,不重复派发已回调的 (hypothesis, round) 对。

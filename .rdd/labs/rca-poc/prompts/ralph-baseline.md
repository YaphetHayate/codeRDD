# 基线臂 objective 模板(ralph 单体模式本地化身)

> 用途:L2 基线对照(决策 #2)。ralph 每轮 1 个全新 agent 兼任规划+采证——这是被验证编排臂的对照面,不是要优化的对象。
> 公平性约束(设计「基线公平性」):`maxRounds` = 编排臂同案例 `max_goal_rounds` 同值;同观测面、同现象描述;objective 同样与破案成功解耦。

## ralph objective(填充后使用)

```
对案例 {{CASE_ID}} 完成一次根因调查并产出结案报告。

- 案例现象:{{SYMPTOM}}
- 系统拓扑:{{CASE_DIR}}/plane/topology.json
- 观测面(只读):{{CASE_DIR}}/plane/ 下全部静态快照文件,清单见 {{CASE_DIR}}/case.json 的 plane_manifest。
  时间戳为相对 T0(症状爆发)偏移,负值 = 症状前。
- 禁读:datasets/、analysis/、runs/、cases/registry.jsonl、任何答案文件。
- 工作区(持久化,纯移动可恢复):{{RUN_DIR}}/
  - state/hypothesis-tree.json   假设树(唯一权威认知状态;每轮首读再续)
  - state/evidence-chain.jsonl   证据链(只追加;每条含 id/round/hypothesis_id/
    type(correlational|causal)/assertion/citations[{file,locator}]/confidence/verdict)
  - state/round-log.jsonl        每轮决策快照(dispatched/integration/decision/stop_check)
  - report/rounds/round-NN.md    每轮人类复核快照
  - manifest.json                预算:{{MAX_ROUNDS}} 轮(即你的 maxRounds,硬上限)
    格式契约(字段名与取值)见 {{LAB_ROOT}}/README.md §4,format_version 沿用 1。

循环方式:每轮读 state/ 续认知 → 自选下一个最有信息增益的假设 → 亲读 plane/ 采证
(引用必须可追溯:文件+定位)→ 证据追加落链 → 更新假设树(剪枝/下探必须引用证据 id,
禁止凭空排除)→ 判断停止。

停止三选一(达到即写 report/final-report.md 并报告完成,与破案成功解耦):
1. 某假设 confidence ≥ {{CONFIDENCE_STOP}} 且有 causal 证据支撑 → 结案:根因结论
2. 轮次达 {{MAX_ROUNDS}} 仍无达标 → 结案:如实写"预算耗尽"+ 当前最佳假设与缺口
3. 假设空间耗尽(全部剪枝/不可观测)→ 结案:诚实输出"升级人类" + 已排除项清单

红线:找不到根因不是失败,硬编结论才是;证据无引用 = 无效;correlational 证据不得
单独支撑根因结论。
```

## 双口径对照说明(R6)

- 本地基线(上述 ralph)为主口径:同观测面、同现象、同预算轮次,受控对照。
- 论文报告的 OpenRCA 单体基线数字为参照口径:模型/提示/预算与本 PoC 不同,
  只作定性参照,在 `analysis/scoring/summary.md` 显式标注差异,不并表硬比。

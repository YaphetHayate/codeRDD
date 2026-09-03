# 执行决策树 — openrca-bank-task1-2100-orchestrated-001

- 臂:`orchestrated` | 案例层级:`l2-openrca` | 预算:`4` 轮 | 终态:`root_cause_concluded`
- 证据 `3` 条(correlational 3 / causal 0);轮次记录 `1`
- 评分:verdict=`located`,关键词命中 `5`(`IG01,high,JVM,CPU,load`),误归因 `0`,需复核=`true`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["openrca-bank-task1-2100<br/>假设树起点"])
  H1["🟢 H1 JVM 进程级 CPU 事件:某 JVM 实例(IG01/IG02/MG01/MG02)JV<br/>prior 0.6 → conf 0.82 · E1,E2,E3"]
  START --> H1
  H2["🔵 H2 OS/资源级事件:某实例(含 Mysql/Redis/Tomcat/apache/docke<br/>prior 0.5 → conf 0.7 · E2"]
  START --> H2
  H3["🔵 H3 服务面症状锚定:metric_app 在窗口内的突变时刻与形态(供根因事件对齐)<br/>prior 0.4 → conf 0.85 · E3"]
  START --> H3
  subgraph R1["第 1 轮"]
  E_E1("🟢support 0.93<br/>w1-H1-jvm-scan · correlational")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:支持/下探| H1
  E_E2("🟢support 0.82<br/>w2-H2-os-scan · correlational")
  H2 -.->|派发采证| E_E2
  E_E2 -.->|裁决:支持/下探| H2
  E_E3("🟢support 0.88<br/>w3-H3-symptom-anchor · correlational")
  H3 -.->|派发采证| E_E3
  E_E3 -.->|裁决:支持/下探| H3
  end
  D1["🛑 R1 决策:STOP(停止条件 1(置信度达标):Manager 综合 H1(0.93,独占性+形态+夹逼精确)与症状-根因解扣复杂度折扣后 )"]
  R1 -.-> D1
  CONCL["🏁 结案:H1 conf 0.82<br/>停止:confidence_threshold<br/>根因组件=IG01,原因=high JVM CPU load(JVM_CPULoad 阶跃 0.16→26.8→平台 50.0,≈280× 基线,JVM 进程内"]
  H1 ==> CONCL
  style H1 fill:#c8e6c9,stroke:#666
  style H2 fill:#cfe8ff,stroke:#666
  style H3 fill:#cfe8ff,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/openrca-bank-task1-2100-orchestrated-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | support | 0.93 | correlational | 唯一候选事件:IG01 JVM_CPULoad(JVM-Operating System_7778_JVM_JVM_CPULoad)事件型异常(阶跃-平台-阶跃恢复,非锯齿基线)。 |
| E2 | H2 | 1 | support | 0.82 | correlational | 窗口 [0,+1800] 独占事件清单(60s 夹逼):① IG01 OS CPU 用户态突增(核心):末正常 660(25.79%)→首偏离 720(67.16%),区间 (21 |
| E3 | H3 | 1 | support | 0.88 | correlational | 症状锚定成立但锚点在追溯窗而非报障窗:报障窗 [0,+1800] metric_app 11 服务×101 采样 rr=sr=100 全平,trace 同平(span 4.2k-1 |

# 执行决策树 — openrca-bank-task2-1330-orchestrated-001

- 臂:`orchestrated` | 案例层级:`l2-openrca` | 预算:`4` 轮 | 终态:`hypothesis_space_exhausted`
- 证据 `5` 条(correlational 5 / causal 0);轮次记录 `2`
- 评分:verdict=`escalated`,关键词命中 `5`(`MG02,high,JVM,CPU,load`),误归因 `0`,需复核=`false`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["openrca-bank-task2-1330<br/>假设树起点"])
  H1["🔴 H1 数据库层故障(Mysql01/Mysql02)或缓存层故障(Redis01/Redis02)<br/>prior 0.5 → conf 0 · E1"]
  START --> H1
  H2["🔴 H2 应用层资源型故障:某应用实例(IG/MG/Tomcat/apache/docker)JVM/<br/>prior 0.55 → conf 0 · E2"]
  START --> H2
  H3["🔴 H3 网络型故障:层间网络时延/丢包/连接异常导致服务劣化<br/>prior 0.4 → conf 0 · E3"]
  START --> H3
  H4["🔵 H4 MG02 JVM 事件为根因(high JVM CPU load 口径):MG02 名下 J<br/>prior 0.55 → conf 0.65 · E4"]
  START --> H4
  H5["🔴 H5 ST4 故障窗 [120,720] 致因=Mysql02 工作负载事件(t=120 起 Ha<br/>prior 0.5 → conf 0 · E5"]
  START --> H5
  subgraph R1["第 1 轮"]
  E_E1("🔴refute 0.8<br/>w1-H1-db-cache · correlational")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:剪枝/排除| H1
  E_E2("🔴refute 0.85<br/>w2-H2-app-resource · correlational")
  H2 -.->|派发采证| E_E2
  E_E2 -.->|裁决:剪枝/排除| H2
  E_E3("🔴refute 0.75<br/>w3-H3-network · correlational")
  H3 -.->|派发采证| E_E3
  E_E3 -.->|裁决:剪枝/排除| H3
  end
  D1["➡️ R1 决策:继续(整合后进入下一轮)"]
  R1 -.-> D1
  subgraph R2["第 2 轮"]
  E_E4("🔴refute 0.95<br/>w4-H4-mg02-jvm · correlational")
  H4 -.->|派发采证| E_E4
  E_E4 -.->|裁决:剪枝/排除| H4
  E_E5("🔴refute 0.86<br/>w5-H5-mysql-workload · correlational")
  H5 -.->|派发采证| E_E5
  E_E5 -.->|裁决:剪枝/排除| H5
  end
  D2["🛑 R2 决策:STOP(停止条件 3(假设空间耗尽):ST4 症状致因全部可检验候选排除,注入源观测面外;H4 事件已刻画至观测面极限(60s )"]
  R2 -.-> D2
  CONCL["🏁 结案:H4(评测口径裁决) conf 0.65<br/>停止:hypothesis_space_exhausted<br/>评测口径结论:根因组件=MG02,原因=high JVM CPU load(JVM_CPULoad 阶跃 0.89→29.31→平台 50.6,起点 ∈(T+9"]
  H4 ==>|评测口径裁决| CONCL
  style H1 fill:#ffcdd2,stroke:#666
  style H2 fill:#ffcdd2,stroke:#666
  style H3 fill:#ffcdd2,stroke:#666
  style H4 fill:#cfe8ff,stroke:#666
  style H5 fill:#ffcdd2,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/openrca-bank-task2-1330-orchestrated-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | refute | 0.8 | correlational | 数据/缓存域四实例窗内无故障级异常:Redis01/02 引擎 KPI 全程恒稳(clients 601/402 恒、rejected/evicted/blocked 全 0、op |
| E2 | H2 | 1 | refute | 0.85 | correlational | 应用/容器实例无窗口对齐的资源异常:CPU 25-27% 恒定(IG/MG/Tomcat)、堆锯齿 11-57% 无饱和、GC 窗口 41 次 vs 基线 40 次全 ParNew |
| E3 | H3 | 1 | refute | 0.75 | correlational | 网络型故障不成立:18 实例 NETInErr/NETOutErr 全时段 0、带宽利用率 '0.2%、DefaultRoute 恒通、CLOSE-WAIT/FIN-WAIT 仅追 |
| E4 | H4 | 2 | refute | 0.95 | correlational | (a) 存在性成立:MG02 JVM_CPULoad(JVM-Operating System_7779_JVM_JVM_CPULoad)事件型阶跃+平台,起点 ∈(T+900,T |
| E5 | H5 | 2 | refute | 0.86 | correlational | (1) 时间线不成立:Handler Read Next 唯一主尖峰 t=540(8007,单点),t=120-480 全 0(ST4 最深劣化 t=180 时 RdNext=0) |

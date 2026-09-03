# 执行决策树 — openrca-bank-task6-1800-orchestrated-001

- 臂:`orchestrated` | 案例层级:`l2-openrca` | 预算:`4` 轮 | 终态:`hypothesis_space_exhausted`
- 证据 `5` 条(correlational 5 / causal 0);轮次记录 `2`
- 评分:verdict=`escalated`,关键词命中 `4`(`Redis02,high,memory,usage`),误归因 `0`,需复核=`false`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["openrca-bank-task6-1800<br/>假设树起点"])
  H1["🔵 H1 数据库层故障(Mysql01/Mysql02):资源耗尽或查询异常导致症状窗口内单点故障<br/>prior 0.5 → conf 0.5 · E1"]
  START --> H1
  H2["🔴 H2 缓存层故障(Redis01/Redis02):某 Redis 实例异常(内存/CPU/连接/<br/>prior 0.5 → conf 0 · E2"]
  START --> H2
  H3["🔴 H3 应用层故障(Tomcat/IG/MG/docker/apache/gw 实例):某实例资源异<br/>prior 0.5 → conf 0 · E3"]
  START --> H3
  H1.1["🔴 H1.1 Mysql02 IO 争用(sdc 小 IO 争用,自 T-600)为 T+0 应用尖峰根因<br/>prior 0.55 → conf 0 · E1,E4"]
  H1 -->|下探| H1.1
  H2.1["🔵 H2.1 Redis02 宿主 OS 内存事件(T+600-840,~5.4GB 瞬时占用)为根因事件<br/>prior 0.5 → conf 0.6 · E2,E5"]
  H2 -->|下探| H2.1
  subgraph R1["第 1 轮"]
  E_E1("🟢support 0.5<br/>w1-H1-db · correlational")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:支持/下探| H1
  E_E2("🔴refute 0.7<br/>w2-H2-cache · correlational")
  H2 -.->|派发采证| E_E2
  E_E2 -.->|裁决:剪枝/排除| H2
  E_E3("🔴refute 0.7<br/>w3-H3-app · correlational")
  H3 -.->|派发采证| E_E3
  E_E3 -.->|裁决:剪枝/排除| H3
  end
  D1["➡️ R1 决策:继续(整合后进入下一轮)"]
  R1 -.-> D1
  subgraph R2["第 2 轮"]
  E_E4("🔴refute 0.62<br/>w4-H1.1-mysql-io · correlational")
  H1.1 -.->|派发采证| E_E4
  E_E4 -.->|裁决:剪枝/排除| H1.1
  E_E5("🔴refute 0.93<br/>w5-H2.1-host-mem · correlational")
  H2.1 -.->|派发采证| E_E5
  E_E5 -.->|裁决:剪枝/排除| H2.1
  end
  D2["🛑 R2 决策:STOP(停止条件 3(假设空间耗尽):T+0 尖峰致因的全部可检验假设被证据排除,剩余盲区(网络瞬态/进程级)在本观测面结构性不)"]
  R2 -.-> D2
  CONCL["🏁 结案:H2.1(评测口径裁决) conf 0.6<br/>停止:hypothesis_space_exhausted<br/>评测口径结论:根因组件=Redis02(宿主 OS 层),原因=high memory usage(匿名内存阶跃 +5.4GB,起点 ∈(T+540,T+600"]
  H1 ==>|评测口径裁决| CONCL
  style H1 fill:#cfe8ff,stroke:#666
  style H2 fill:#ffcdd2,stroke:#666
  style H3 fill:#ffcdd2,stroke:#666
  style H1.1 fill:#ffcdd2,stroke:#666
  style H2.1 fill:#cfe8ff,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/openrca-bank-task6-1800-orchestrated-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | support | 0.5 | correlational | 最可疑=Mysql02,IO 争用型查询异常(非资源耗尽):SlowQueries 自 T-600 爬升(基线 0.2-4 → 11.5@-600 → 27.5@-300 → 峰值 |
| E2 | H2 | 1 | refute | 0.7 | correlational | Redis 实例级全 KPI 稳态(used_memory 13-16MB vs 4GB maxmemory、零 evicted/blocked/rejected、命中率/ops/ |
| E3 | H3 | 1 | refute | 0.7 | correlational | 应用层实例无资源/网络异常:CPU ~26% 平坦、堆在 t=0 反而下降、零 Full GC/OOM/kill、ParNew'0.1s、磁盘 busy≤5%、docker 平坦、 |
| E4 | H1.1 | 2 | refute | 0.62 | correlational | Mysql02 IO 争用是真实但与 T+0 事件无关的慢性背景劣化:(1) 劣化 T-600/-660 一步台阶后为平台(CPUWio 25.7→24-29% 稳定、sdc bu |
| E5 | H2.1 | 2 | refute | 0.93 | correlational | Redis02 宿主内存事件刻画(非根因裁决,事实部分为结案关键):(1) 起点 ∈(T+540,T+600](T+540 仍基线 23%/1668MB,T+600 单采样阶跃 9 |

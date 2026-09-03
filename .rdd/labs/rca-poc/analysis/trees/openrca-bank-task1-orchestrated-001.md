# 执行决策树 — openrca-bank-task1-orchestrated-001

- 臂:`orchestrated` | 案例层级:`l2-openrca` | 预算:`4` 轮 | 终态:`budget_exhausted`
- 证据 `7` 条(correlational 7 / causal 0);轮次记录 `3`
- 评分:verdict=`budget_exhausted`,关键词命中 `1`(`Mysql02`),误归因 `0`,需复核=`false`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["openrca-bank-task1<br/>假设树起点"])
  H1["🔵 H1 数据库层故障(Mysql01/Mysql02):某 Mysql 实例出现异常导致窗口内系统单<br/>prior 0.55 → conf 0.5 · E1"]
  START --> H1
  H2["🔴 H2 缓存层故障(Redis01/Redis02)<br/>prior 0.35 → conf 0 · E2"]
  START --> H2
  H3["🔴 H3 应用层故障(Tomcat/Service/docker/gw 实例)<br/>prior 0.4 → conf 0 · E3"]
  START --> H3
  H1.1["🔵 H1.1 Mysql02 工作负载型异常为根因:查询模式/速率变化(T+540 前兆)触发阵发性慢查询<br/>prior 0.6 → conf 0.6 · E1,E4,E6,E7"]
  H1 -->|下探| H1.1
  H1.2["🔴 H1.2 Mysql02 内存持续高压为根因('high memory usage' 型)<br/>prior 0.45 → conf 0 · E5"]
  H1 -->|下探| H1.2
  H1.1.1["🔴 H1.1.1 末环因果闭合:应用侧存在对 DB 异常的直接响应证据<br/>prior 0.55 → conf 0 · E6"]
  H1.1 -->|下探| H1.1.1
  H1.1.2["🔴 H1.1.2 锁/长事务侧机制:锁持有者先于慢查询首爆<br/>prior 0.5 → conf 0 · E7"]
  H1.1 -->|下探| H1.1.2
  subgraph R1["第 1 轮"]
  E_E1("🟢support 0.5<br/>w1-H1-db-domain · correlational")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:支持/下探| H1
  E_E2("🔴refute 0.88<br/>w2-H2-cache-domain · correlational")
  H2 -.->|派发采证| E_E2
  E_E2 -.->|裁决:剪枝/排除| H2
  E_E3("🔴refute 0.8<br/>w3-H3-app-domain · correlational")
  H3 -.->|派发采证| E_E3
  E_E3 -.->|裁决:剪枝/排除| H3
  end
  D1["➡️ R1 决策:继续(整合后进入下一轮)"]
  R1 -.-> D1
  subgraph R2["第 2 轮"]
  E_E4("🟢support 0.6<br/>w4-H1.1-workload-type · correlational")
  H1.1 -.->|派发采证| E_E4
  E_E4 -.->|裁决:支持/下探| H1.1
  E_E5("🔴refute 0.88<br/>w5-H1.2-memory-type · correlational")
  H1.2 -.->|派发采证| E_E5
  E_E5 -.->|裁决:剪枝/排除| H1.2
  end
  D2["➡️ R2 决策:继续(整合后进入下一轮)"]
  R2 -.-> D2
  subgraph R3["第 3 轮"]
  E_E6("🔴refute 0.65<br/>w6-H1.1.1-causal-close · correlational")
  H1.1.1 -.->|派发采证| E_E6
  E_E6 -.->|裁决:剪枝/排除| H1.1.1
  E_E7("🔴refute 0.7<br/>w7-H1.1.2-lock-mechanism · correlational")
  H1.1.2 -.->|派发采证| E_E7
  E_E7 -.->|裁决:剪枝/排除| H1.1.2
  end
  D3["🛑 R3 决策:STOP(停止条件 2(预算路径,主动变体):置信度 0.6'0.8 且 causal 闭合被观测面结构性盲区阻断(Mysql 无)"]
  R3 -.-> D3
  CONCL["🏁 结案:H1.1 conf 0.6<br/>停止:budget_exhausted<br/>根因组件 = Mysql02(多线交叉:时序首发/孪生对照/历史回合共变/trace 时延梯度独立指向)。机制 = 查询模式/速率变化触发的工作负载型阵发性慢查"]
  H1 ==>|评测口径裁决| CONCL
  style H1 fill:#cfe8ff,stroke:#666
  style H2 fill:#ffcdd2,stroke:#666
  style H3 fill:#ffcdd2,stroke:#666
  style H1.1 fill:#cfe8ff,stroke:#666
  style H1.2 fill:#ffcdd2,stroke:#666
  style H1.1.1 fill:#ffcdd2,stroke:#666
  style H1.1.2 fill:#ffcdd2,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/openrca-bank-task1-orchestrated-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | support | 0.5 | correlational | 最可疑组件=Mysql02,异常类型=症状窗内间歇性慢查询爆发(SlowQueries 基线0.03-0.5升至7-8.9@T+660/720、5.4@+1260、4.6-4.8@ |
| E2 | H2 | 1 | refute | 0.88 | correlational | 缓存域双实例全 KPI 稳态:内存无压力(used_memory 15-18MB vs 4GB maxmemory,'0.5%;evicted/blocked/rejected 全 |
| E3 | H3 | 1 | refute | 0.8 | correlational | 应用层域内全部组件平稳:Tomcat01-04 CPU 26-28%/JVM 堆基线包络/ErrorCount 恒定/GC 全 ParNew 小回收(0.02-0.09s,无 Fu |
| E4 | H1.1 | 2 | support | 0.6 | correlational | H1.1 成立:根因组件=Mysql02,原因类型=查询模式变化触发的工作负载型异常(慢查询爆发+行锁竞争,非资源耗尽:CPU≤51%/连接恒37/2000,Mysql01 对照全 |
| E5 | H1.2 | 2 | refute | 0.88 | correlational | H1.2 不成立(两条件均不满足):(1) 无事件型变化——Mysql02 MEMUsedMemPerc=98.0 于[-3600,+1800]每采样点恒定(先于窗口≥3600s  |
| E6 | H1.1.1 | 3 | refute | 0.65 | correlational | 末环按假设所述直接传递机制不闭合:(1) 日志负证据确凿——[600,900] timeout/lock wait/connection/pool/refuse/exception |
| E7 | H1.1.2 | 3 | refute | 0.7 | correlational | 锁/长事务机制假设被 refute(预注册判定:基线=安静段均值+3σ):(1) 无先导——Row Lock Time/Waits、ThreadsRunning、SlowQueri |

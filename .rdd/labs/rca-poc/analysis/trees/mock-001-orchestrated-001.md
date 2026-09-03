# 执行决策树 — mock-001-orchestrated-001

- 臂:`orchestrated` | 案例层级:`l1-mock` | 预算:`3` 轮 | 终态:`root_cause_concluded`
- 证据 `5` 条(correlational 2 / causal 3);轮次记录 `2`
- 评分:verdict=`located`,关键词命中 `5`(`release-2185,orders,customer_id,全表扫描,rows_examined`),误归因 `0`,需复核=`false`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["mock-001<br/>假设树起点"])
  H1["🔵 H1 数据库层异常导致 /v1/orders 查询慢:连接池耗尽、慢查询或 db 过载,web 层<br/>prior 0.7 → conf 0.85 · E1"]
  START --> H1
  H2["🔴 H2 web 实例资源不足(CPU/内存)导致 API 处理慢(依据:延迟从 web 层观测到;需<br/>prior 0.5 → conf 0 · E2"]
  START --> H2
  H3["🔴 H3 上游流量激增导致系统过载(依据:延迟突增与错误率升高的常见共因;需流量证据判定)<br/>prior 0.3 → conf 0 · E3"]
  START --> H3
  H1.1["🟢 H1.1 release-2185(T-45 上线)引入的 orders 表按 customer_id<br/>prior 0.85 → conf 0.9 · E1,E4"]
  H1 -->|下探| H1.1
  H1.2["🔴 H1.2 连接池配置不足或存在其他连接持有者(长事务/泄漏),与查询负载叠加导致池耗尽<br/>prior 0.2 → conf 0 · E5"]
  H1 -->|下探| H1.2
  subgraph R1["第 1 轮"]
  E_E1("🟢support 0.85<br/>w1-H1-db · causal")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:支持/下探| H1
  E_E2("🔴refute 0.85<br/>w2-H2-web · causal")
  H2 -.->|派发采证| E_E2
  E_E2 -.->|裁决:剪枝/排除| H2
  E_E3("🔴refute 0.8<br/>w3-H3-traffic · correlational")
  H3 -.->|派发采证| E_E3
  E_E3 -.->|裁决:剪枝/排除| H3
  end
  D1["➡️ R1 决策:继续(整合后进入下一轮)"]
  R1 -.-> D1
  subgraph R2["第 2 轮"]
  E_E4("🟢support 0.9<br/>w4-H1.1-missing-index · causal")
  H1.1 -.->|派发采证| E_E4
  E_E4 -.->|裁决:支持/下探| H1.1
  E_E5("🔴refute 0.8<br/>w5-H1.2-pool-config · correlational")
  H1.2 -.->|派发采证| E_E5
  E_E5 -.->|裁决:剪枝/排除| H1.2
  end
  D2["🛑 R2 决策:STOP(H1.1 根因假设 confidence 0.9 ≥ 0.8 且 E4 为 causal(部署→慢查询→池耗尽→等待→告)"]
  R2 -.-> D2
  CONCL["🏁 结案:H1.1 conf 0.9<br/>停止:confidence_reached<br/>release-2185(T-45 上线)引入的 orders 表按 customer_id 查询缺有效索引,rows_examined≈49万全表扫描、单条耗"]
  H1.1 ==> CONCL
  style H1 fill:#cfe8ff,stroke:#666
  style H2 fill:#ffcdd2,stroke:#666
  style H3 fill:#ffcdd2,stroke:#666
  style H1.1 fill:#c8e6c9,stroke:#666
  style H1.2 fill:#ffcdd2,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/mock-001-orchestrated-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | support | 0.85 | causal | H1 成立(机制链 causal,含一处子句反证):/v1/orders 变慢的直接原因是数据库读路径慢查询——T-44.2 起 orders 表按 customer_id 的 S |
| E2 | H2 | 1 | refute | 0.85 | causal | H2(web 实例资源不足)不成立。CPU 子命题被直接反证:(1) 时序不成立——延迟恶化始于 T-40,此刻三实例 CPU 均基线 25-27%,web-2 首次抬升(T-30 |
| E3 | H3 | 1 | refute | 0.8 | correlational | H3(流量激增过载)不成立:症状峰值窗口 web-1/3 CPU 仅 36~41%、mysql CPU 峰值 59%,系统远未过载;唯一饱和点是连接池,504 失败原因均为等 db |
| E4 | H1.1 | 2 | support | 0.9 | causal | H1.1 成立(causal)。机制链每一环有直接观测且时序严格递进、量级匹配:(1) t=-45 部署 release-2185,明确 adds SELECT on orders |
| E5 | H1.2 | 2 | refute | 0.8 | correlational | 池耗尽的替代根因假设(配置不足/其他持有者)不成立:窗口内连接池上限无任何变更记录(deploy.log 仅日志采样调整与新增 SELECT 路径,均非池配置);慢查询出现前(T- |

# 执行决策树 — pm-001-orchestrated-001

- 臂:`orchestrated` | 案例层级:`l3-postmortem` | 预算:`4` 轮 | 终态:`root_cause_concluded`
- 证据 `3` 条(correlational 1 / causal 2);轮次记录 `1`
- 评分:verdict=`located`,关键词命中 `10`(`#4821,deploy,ALTER,字段,类型,validation,混合,migrator,反向迁移,hotfix-ignore-field`),误归因 `0`,需复核=`false`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["pm-001<br/>假设树起点"])
  H1["🔵 H1 部署/变更引发:窗口内某次 deploy(#4821 T-95 或 #4822 T-40)的<br/>prior 0.6 → conf 0.88 · E1"]
  START --> H1
  H2["🟢 H2 数据层状态问题:pg 中的数据状态(校验失败指向的数据不一致)导致 distributor <br/>prior 0.55 → conf 0.9 · E2"]
  START --> H2
  H3["🔴 H3 服务自身/资源问题:worker 池/队列服务/网络/其他组件(canary/billing<br/>prior 0.35 → conf 0 · E3"]
  START --> H3
  subgraph R1["第 1 轮"]
  E_E1("🟢support 0.88<br/>w1-H1-change · causal")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:支持/下探| H1
  E_E2("🟢support 0.9<br/>w2-H2-data · causal")
  H2 -.->|派发采证| E_E2
  E_E2 -.->|裁决:支持/下探| H2
  E_E3("🔴refute 0.9<br/>w3-H3-self · correlational")
  H3 -.->|派发采证| E_E3
  E_E3 -.->|裁决:剪枝/排除| H3
  end
  D1["🛑 R1 决策:STOP(停止条件 1:H2 conf 0.90 causal(机制每环有观测+hotfix 自然实验直接证明);H1 0.88 )"]
  R1 -.-> D1
  CONCL["🏁 结案:H2 conf 0.9<br/>停止:confidence_threshold<br/>根因=deploy #4821 的 pg-migrator 对 pg.jobs 表执行 ALTER(列 14 存储表示改为 raw numeric),变更后新写"]
  H2 ==> CONCL
  style H1 fill:#cfe8ff,stroke:#666
  style H2 fill:#c8e6c9,stroke:#666
  style H3 fill:#ffcdd2,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/pm-001-orchestrated-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | support | 0.88 | causal | 支持(机制=变更遗留状态,非变更代码在跑):deploy #4821(T-95 启动/T-92 完成,targets=distributor-api+pg-migrator)的 m |
| E2 | H2 | 1 | support | 0.9 | causal | 成立(机制+时序完整):T-92 #4821 的 pg-migrator ALTER jobs 表→此后 ~13300 行新写入 column 14 呈 raw numeric,与 |
| E3 | H3 | 1 | refute | 0.9 | correlational | H3 不成立:(a) worker 池故障窗全程空闲健康(CPU 22-36%/内存 54-60%/GC 23-90ms);dispatch=0 与 worker 空闲同时成立→停 |

# 执行决策树 — pm-001-ralph-001

- 臂:`ralph-baseline` | 案例层级:`l3-postmortem` | 预算:`4` 轮 | 终态:`root_cause_concluded`
- 证据 `7` 条(correlational 3 / causal 4);轮次记录 `1`
- 评分:verdict=`located`,关键词命中 `9`(`#4821,deploy,ALTER,schema,字段,type mismatch,validation,migrator,hotfix-ignore-field`),误归因 `0`,需复核=`false`

> 本图由 `tools/render-tree.mjs` 从 state 机械生成;任何节点可回查 `runs/${runId}/state/*` 与 `analysis/scoring/${runId}.json`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。

```mermaid
flowchart TD
  START(["pm-001<br/>假设树起点"])
  H0["⚪ H0 故障定位:失效点在 distributor 的 scan→dispatch 门禁环节(job<br/>prior 0.9 → conf 0.95 · E1,E6"]
  START --> H0
  H1["⚪ H1 deploy #4821(jobs-infra 组,同时携带 distributor-api<br/>prior 0.45 → conf 0.9 · E1"]
  H0 -->|下探| H1
  H1a["🔴 H1a 持续原因为 distributor-api 新代码(v2.30 线)自身 bug,回滚代码即<br/>prior 0.25 → conf 0.05 · E4"]
  H1 -->|下探| H1a
  H1b["⚪ H1b 根因机制:pg-migrator 的 ALTER TABLE jobs(deploy #48<br/>prior 0.2 → conf 0.9 · E2,E3,E5"]
  H1 -->|下探| H1b
  H1b-1["⚪ H1b-1 回滚无效的机制:deploy #4821 manifest 未定义 reverse migr<br/>prior 0.15 → conf 0.9 · E4,E5"]
  H1b -->|下探| H1b-1
  H2["🔴 H2 存量脏数据:变更前已存在的坏行导致校验失败<br/>prior 0.15 → conf 0.02 · E2"]
  H0 -->|下探| H2
  H3["🔴 H3 服务/容量问题:worker 池耗尽,或 distributor/pg 宕机、过载<br/>prior 0.25 → conf 0.02 · E3,E6"]
  H0 -->|下探| H3
  H4["🔴 H4 deploy #4822(billing-web)或 redis 故障波及 job 分发链路<br/>prior 0.05 → conf 0.02 · E7"]
  H0 -->|下探| H4
  subgraph R1["第 1 轮"]
  E_E1("supports 0.85<br/>E1 · correlational")
  H1 -.->|派发采证| E_E1
  E_E1 -.->|裁决:存疑| H1
  E_E2("supports 0.85<br/>E2 · causal")
  H1b -.->|派发采证| E_E2
  E_E2 -.->|裁决:存疑| H1b
  E_E3("supports 0.95<br/>E3 · causal")
  H1b -.->|派发采证| E_E3
  E_E3 -.->|裁决:存疑| H1b
  E_E4("supports 0.9<br/>E4 · causal")
  H1b-1 -.->|派发采证| E_E4
  E_E4 -.->|裁决:存疑| H1b-1
  E_E5("supports 0.9<br/>E5 · causal")
  H1b -.->|派发采证| E_E5
  E_E5 -.->|裁决:存疑| H1b
  E_E6("refutes 0.85<br/>E6 · correlational")
  H3 -.->|派发采证| E_E6
  E_E6 -.->|裁决:存疑| H3
  E_E7("refutes 0.85<br/>E7 · correlational")
  H4 -.->|派发采证| E_E7
  E_E7 -.->|裁决:存疑| H4
  end
  D1["➡️ R1 决策:继续(整合后进入下一轮)"]
  R1 -.-> D1
  CONCL["🏁 结案:H1b conf 0.9<br/>停止:H1b confidence 0.9 ≥ 0.8,且由多条独立因果证据支撑:E2(行级身份匹<br/>"]
  H4 ==>|评测口径裁决| CONCL
  style H0 fill:#f5f5f5,stroke:#666
  style H1 fill:#f5f5f5,stroke:#666
  style H1a fill:#ffcdd2,stroke:#666
  style H1b fill:#f5f5f5,stroke:#666
  style H1b-1 fill:#f5f5f5,stroke:#666
  style H2 fill:#ffcdd2,stroke:#666
  style H3 fill:#ffcdd2,stroke:#666
  style H4 fill:#ffcdd2,stroke:#666
```

## 断言摘要(每条证据一句话,全文见 `runs/pm-001-ralph-001/state/evidence-chain.jsonl`)

| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|
|------|------|----|---------|------|------|------------|
| E1 | H1 | 1 | supports | 0.85 | correlational | 故障起点与 deploy #4821 强时间耦合:deploy #4821(component_group=jobs-infra,targets=distributor-api,p |
| E2 | H1b | 1 | supports | 0.85 | causal | 行级身份匹配证明失败行起源于迁移本身:pg.log 记录 ALTER TABLE jobs 由 role=pg-migrator 执行(deploy #4821 migration |
| E3 | H1b | 1 | supports | 0.95 | causal | 分发停止是 distributor 校验门禁的 fail-closed 决策,而非扫描器/PG/worker 停摆:distributor.log 明确记录 'dispatch h |
| E4 | H1b-1 | 1 | supports | 0.9 | causal | T+15 回滚自然实验隔离出持续原因为 schema 而非代码版本:回滚于 T+18 完成,仅还原 distributor-api 至 v2.29,pg-migrator NOT  |
| E5 | H1b | 1 | supports | 0.9 | causal | 干预实验闭环因果:oncall 于 T+25 手工部署定制构建 hotfix-ignore-field-8803(名称指向忽略该字段校验)后,分发立即恢复(151/min@+25  |
| E6 | H3 | 1 | refutes | 0.85 | correlational | 容量/服务面排除:worker 全时段 CPU 22-36%、内存约 54-60%、gc_pause 多为 25-90ms,在故障起点(T-88)与恢复点(T+25)均无跳变,与' |
| E7 | H4 | 1 | refutes | 0.85 | correlational | billing-web/redis 干扰排除:deploy #4822 目标为 billing-web(topology 标记 kind=unrelated-service,与 d |

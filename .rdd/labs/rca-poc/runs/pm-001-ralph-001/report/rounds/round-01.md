# Round 01 — pm-001(ralph-baseline 单体臂,run pm-001-ralph-001)

## 进入状态
空状态(round 0):假设树 0 节点、证据链 0 条。预算 4 轮,本轮为第 1 轮。

## 本轮动作
1. 精读观测面全部内容:`plane/topology.json`、`plane/metrics/*.csv`(5 个,分钟粒度 T-95..T+40)、`plane/logs/*.log`(deploy/distributor/pg/app 4 个)。
2. 构造初始假设树:H0 定界(失效在 distributor scan→dispatch 门禁),竞争分支 H1(deploy #4821 变更)/H2(存量脏数据)/H3(容量与服务)/H4(billing-web/redis 干扰),H1 下探 H1a(代码 bug)/H1b(迁移改表示→门禁 fail-closed)/H1b-1(回滚无效机制)。
3. 采证 E1–E7 追加落链并 read-back 校验通过;按证据剪枝 H1a/H2/H3/H4(剪枝理由全部引用证据 id,无凭空排除)。

## 关键发现(证据 → 结论)
| 证据 | 类型 | 支撑/反驳 | 要点 |
|---|---|---|---|
| E1 | correlational | H1 | #4821(T-92 完成,targets=distributor-api,pg-migrator)与故障起点 T-88 强耦合;dispatch T-85 归零,队列 47→760@T0 |
| E2 | causal | H1b(兼 refutes H2) | ALTER 前表恰 1742091 行;distributor 首个失败行 row_id_hint=jobs:1742091=迁移后第一行;部署前 fail=0 |
| E3 | causal | H1b(兼 refutes H3 宕机分支) | 日志显式 "dispatch halted: scan validation gate failed";scan 循环全程 12/min 正常,PG 持续可读写 |
| E4 | causal | H1b-1(兼 refutes H1a) | 回滚只还原代码(v2.29),pg-migrator NOT reverted(无 reverse step);T+19..+24 v2.29 仍报同错,失败行为回滚后新写入行 |
| E5 | causal | H1b | T+25 hotfix-ignore-field-8803 → dispatch 151/min 恢复,fail_rows→0@T+31,validation=clean@T+30,backlog drained@T+33;无任何 schema 回退 |
| E6 | correlational | refutes H3 | worker 全程平稳、故障边界无跳变;api 健康;T-60..-53 CPU/GC 凸包与边界不对齐,判噪声 |
| E7 | correlational | refutes H4 | #4822(billing-web)晚于故障首现 48 分钟;拓扑无连边;redis 仅连 web |

## 假设树状态(round 1 末)
- H0 confirmed(0.95)· H1 confirmed(0.9)
- **H1b confirmed(0.9)——根因** · **H1b-1 confirmed(0.9)——回滚无效机制**
- refuted:H1a(E4)、H2(E2)、H3(E3/E6)、H4(E7)

## 停止判定
**满足停止条件 1**:H1b confidence 0.9 ≥ 0.8,且有 4 条独立 causal 证据(E2 身份匹配 / E3 fail-closed 显式机制 / E4 回滚自然实验 / E5 干预恢复实验)。correlational 证据仅用于定界与排除,未单独支撑结论。

→ 本轮直接结案:产出 `report/final-report.md`,manifest final_state → `root_cause_concluded`。

## 诚实性备注
- pg.log 只有日期无时刻,其时序由内容互证(引用 deploy #4821、行数 1742091 与失败行 id 精确一致)。
- ALTER 的 DDL 细节被审计策略省略,"column 14 表示变更"由 distributor 错误信息反推。
- distributor.log T-88 已记 halted,而 dispatch 指标 T-88..-86 仍有 117/111/109、T-85 归零:判为在途分发排空滞后,不影响根因。

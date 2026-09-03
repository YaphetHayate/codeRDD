# pm-001 结案报告(L3 基线臂 · ralph 单体模式 · run pm-001-ralph-001)

- 结案方式:停止条件 1(根因假设 confidence 0.9 ≥ 0.8,且有多条独立 causal 证据)
- 结案轮次:1 / 4(预算 4 轮)
- final_state:`root_cause_concluded`

---

## 一、结论(TL;DR)

**根因:deploy #4821 的数据库迁移(deploy #4821 migration step 2/2,`ALTER TABLE jobs`)改变了 jobs 表 column 14 的存储表示——由"数值的文本表示"变为"原生 numeric"。** 迁移完成后新写入的 job 行在 distributor 扫描时触发其严格 schema 校验门禁(`column 14 type mismatch (expected text representation of numeric, got raw numeric)`),而该门禁是 **fail-closed** 设计——`dispatch halted: scan validation gate failed (refusing to dispatch from inconsistent snapshot)`,只要快照中存在校验失败行就拒绝分发**任何** job。自 T-85 起分发速率归零并持续为 0,job 创建路径(api→pg)始终正常、worker 池始终空闲,队列单调堆积至 T0 触发告警(760 pending / oldest 80.5min)。

**为什么 T+15 的回滚没有恢复分发:回滚只还原了代码,还原不了数据库。** T+18 回滚仅将 distributor-api 退回 v2.29,`pg-migrator NOT reverted`——因为 **deploy #4821 的 manifest 根本没有定义 reverse migration step**(pg.log: "reverse migration skipped: reverse step not defined"),schema 变更滞留线上;而 **v2.29 旧代码对 column 14 抱有与新代码完全相同的期望(文本表示)**,因此回滚后 T+19..T+24 仍持续报同一校验错误(失败行明确注记为回滚窗口开始后新写入)。真正的恢复来自 T+25 手工部署的定制构建 `hotfix-ignore-field-8803`(容忍该字段的新表示,无任何 schema 回退):分发当分钟恢复(151/min),validation_fail_rows 逐分钟衰减至 T+31 归 0,T+30 `validation=clean`,T+33 `backlog drained`,队列 T+34 回落至基线。

**归类:变更(部署 #4821)× 数据层(schema 表示变更),经 distributor 校验门禁的 fail-closed 设计放大为全量分发停摆;回滚失效的直接原因是迁移不可逆(manifest 无 reverse step)+ 新旧代码对该列期望一致。**

## 二、时间线(T0 = 告警时刻)

| 时刻 | 事件 | 证据 |
|---|---|---|
| T-95 | deploy #4821 STARTED(target=distributor-api,jobs-infra 组,ci-bot) | deploy.log L2 |
| T-92 | deploy #4821 COMPLETED(targets=distributor-api,**pg-migrator**);`ALTER TABLE jobs` 由 pg-migrator 执行(step 2/2),变更前表恰 **1742091** 行 | deploy.log L3;pg.log L2-L3 |
| T-89→T-88 | 最后一次正常 scan(rows=120566,dispatched=121)→ 首个校验失败:row_id_hint=**jobs:1742091**(= 迁移后写入的第一行);`dispatch halted: scan validation gate failed`;validation_fail_rows 由 0 → 318 | distributor.log L3-L5;scan-rate offset -89/-88 |
| T-85 | dispatch 指标归零(T-88..-85 为 117→109 在途排空)并保持 0 至 T+24 | distributor-dispatch.csv |
| T-86→T0 | 队列单调攀升 47→760,oldest_job_age 6→80.5min;T0 触发告警 | job-queue-depth.csv |
| T0..T+14 | api p99 轻度抬升(~438ms 峰,伴随症状);worker 全程空闲(CPU 22-36%) | api-latency.csv;worker-cpu.csv |
| T+15 / T+18 | rollback #4821 REQUESTED / COMPLETED:**仅还原 distributor-api 至 v2.29,pg-migrator NOT reverted**;pg 侧反向迁移被跳过(manifest 无 reverse step) | deploy.log L6-L7;pg.log L5 |
| T+19..T+24 | v2.29 下同一 column 14 校验错误持续,失败行注记"row written AFTER rollback window began"→ 回滚无效实锤 | distributor.log L23-L27 |
| T+25 | 手工部署 hotfix-ignore-field-8803 → **dispatch 立即恢复 151/min**,队列达峰 880 后回落 | deploy.log L8;distributor-dispatch.csv |
| T+27 | 4x 扩容 worker(晚于恢复起点,非恢复因素) | deploy.log L9;worker-cpu.csv |
| T+30 / T+31 | `validation=clean`(dispatched=165)/ validation_fail_rows 归 0 | distributor.log L28;scan-rate |
| T+33 / T+34 | `backlog drained: queue depth normalized` / 队列回落至 56(基线) | distributor.log L29;job-queue-depth.csv |

## 三、因果链(每环均有证据 id)

```
deploy #4821 迁移步 ALTER TABLE jobs(证据: deploy.log L3, pg.log L2)
  │  E2(行级身份匹配): 变更前行数 1742091 = 首个失败行 id;部署前 fail=0
  ▼
jobs.column14 表示变化: 文本表示 → 原生 numeric(新写入行携带)
  │  E3(显式机制): distributor 严格 schema 校验门禁 fail-closed
  ▼
"refusing to dispatch from inconsistent snapshot" → dispatch=0(E1: T-85..T+24)
  │  扫描循环 12 scans/min、PG 可读写、worker 空闲均排除他因(E3/E6)
  ▼
队列单调堆积 → T0 告警(E1)
  │
  ├─ E4(回滚自然实验): 仅回滚代码至 v2.29 + schema 滞留(manifest 无 reverse step)
  │   → T+19..T+24 仍同错 → 代码版本非持续原因,schema 才是
  ▼
T+25 hotfix-ignore-field-8803(容忍新表示, 无 schema 回退)
  │  E5(干预实验): dispatch 151/min 恢复, fail_rows→0, T+33 积压清空
  ▼
分发恢复, 队列归位 → 因果闭环
```

## 四、根因问答(对齐案例提问)

1. **变更、数据还是服务?** 变更(deploy #4821)中的**数据层部分**:pg-migrator 的 `ALTER TABLE jobs` 改变 column 14 表示;distributor 服务本身全程存活,worker 池空闲,api 正常。
2. **为什么 job 创建了却从不下发?** 创建走 api→pg,不受影响;下发必须通过 distributor 的 scan 校验门禁,迁移后每个扫描快照都含"raw numeric"的新行,门禁 fail-closed 拒绝从该快照分发任何 job。
3. **为什么 T+15 回滚无效?** 三重原因:(a) 回滚范围只含 distributor-api 代码,pg-migrator 未回滚;(b) 无法回滚是结构性的——manifest 未定义 reverse migration step;(c) 即便回到 v2.29,旧代码对 column 14 的期望同样是文本表示,schema 不一致依旧触发同一门禁。恢复的真正杠杆是让代码容忍新表示(+25 hotfix)。

## 五、已排除假设(均引用证据 id)

| 假设 | 排除理由 | 证据 |
|---|---|---|
| H1a 新代码 bug 为持续原因 | 回滚至 v2.29 后同错持续,失败行为回滚后新写入行 | E4 |
| H2 存量脏数据 | 部署前 fail=0;首失败行=迁移后首行(1742091) | E2 |
| H3 容量/服务(worker 耗尽、distributor/pg 宕机) | scan 循环全程正常、PG 可读写、门禁是显式停发决策;worker 曲线在起点/恢复点无跳变,4x 扩容无效果 | E3, E6 |
| H4 billing-web(#4822)/redis 波及 | 故障首现早于 #4822 约 48 分钟;拓扑无连边;redis 仅连 web | E7 |

## 六、证据质量与残留不确定性(诚实声明)

1. **pg.log 无时刻**:仅有日期。其与 T-92 部署的先后关系由内容互证(引用 deploy #4821、行数 1742091 与 distributor 首个失败行 row_id 精确一致)——时序定位依赖该互证,可信但不完美。
2. **DDL 细节被省略**("statement detail elided by audit policy"):"column 14 表示变更"由 distributor 错误信息反推,非直接 DDL 文本。
3. **-88/-85 的轻微错位**:distributor.log T-88 已记 halted,dispatch 指标 T-88..-86 尚有 117/111/109、T-85 归零,判为在途分发排空滞后,不影响根因判定。
4. **hotfix 机制由名称+行为推断**:观测面内无源码;"ignore-field-8803 容忍字段校验"由部署名与即时恢复行为(fail_rows 同步衰减)共同支撑。
5. 以上不确定项均不削弱主因果链(E2/E3/E4/E5),结论置信度 0.9。

## 七、防再发建议(附赠,不属结案必需)

1. 迁移部署包必须定义并演练 reverse migration step;回滚工具对"含迁移的部署"应强制提示/阻断仅代码回滚。
2. distributor 校验门禁按行隔离失败(跳过坏行+告警)而非全量 fail-closed,避免局部不一致放大为全量停摆。
3. 部署后迁移验证门禁(canary 扫描+schema 表示断言)应在 COMPLETED 前执行,而非等生产告警。
4. 告警联动:validation_fail_rows 自 T-88 起持续非零,比队列深度告警(T0)早 88 分钟,应作为一级信号。

## 八、产物清单

- `state/hypothesis-tree.json`(8 节点;H1b/H1b-1 confirmed@0.9;H1a/H2/H3/H4 refuted,均引用证据 id)
- `state/evidence-chain.jsonl`(E1-E7,read-back 校验通过)
- `state/round-log.jsonl`(round 1 决策快照)
- `report/rounds/round-01.md`(本轮人类复核快照)
- `manifest.json`(final_state=root_cause_concluded)

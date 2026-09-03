# Round 01 报告 — openrca-bank-task2-1330(ralph-baseline,单体模式)

**轮次**: 1 / 4(预算: 4 轮硬上限)
**状态**: 进行中(未达停止条件)

---

## 1. 本轮做了什么

首轮从空状态初始化认知。按信息增益顺序执行:

1. **症状定位**(metric_app.csv,全量 44KB):ServiceTest4 是窗口 [0,1800] 内唯一崩溃的服务——rr(响应率)t=120 起跌,最低 40.54 @ t=180(mrt 7512ms),t=660 起恢复,t=720 完全正常。ServiceTest3 轻微受累(97.8–99.0),其余服务 sr 恒 100。基线 [-3600,0) 内 ST4 也有周期性 rr 低谷(最低 43.33 @ -900)→ 存在慢性背景,窗口内是连续加重的急性发作。
2. **失败形态**(log_service.csv 流式 + grep):无任何非 200;失败 = **10 秒超时**(k6 客户端上限):t=180 分钟 26/40 请求 ≥10s(65%),t=300: 14/32,t=360: 8/18。超时横跨全部 4 个 Tomcat + 双 IG → 共享下游问题,非单实例。
3. **组件级时长扫描**(trace_span.csv 流式聚合,12 组件 × 每分钟):t≈660–720 全系统时长阶跃下降 5–10 倍,最大时长不再触及 10–20s 帽;与 ST4 恢复同时刻同步。
4. **KPI 差分**(metric_container.csv,故障窗 [120,660] vs 健康窗 [720,1800],1487 条序列):Mysql02 签名最强——Handler Read Next 50×、Rows Read 8×、buffer pool read requests 8×、SlowQueries 6.7×、Row Lock Time 5.2×、Handler Rollback 5.9×、ThreadsRunning 4×、CPU user 9.5×。
5. **请求级因果链**(grep 精确秒 + trace_id 时间编码对齐):慢 trace `gw0120210304133300327733` 与 t=190 记录的 ST4 10018ms 超时请求互证(IG02=10019ms / Tomcat02=10017ms)。时延由 MG01(16306ms)→dockerB2(16300ms)承担,内部为 **~7 次串行后端子调用(0.4–4.5s/次,正常毫秒级)**,累计 16.3s > 10s → rr 崩溃。阻塞在被追踪链路最底层(docker 之下 = 未追踪的 MySQL/Redis)。
6. **排除项**:Redis01/02(blocked/evicted/rejected 全 0、内存稳定);docker 容器资源(CPU<5.2%、内存恒定);主机资源(Mysql02 CPU≤51%、磁盘服务时间 0.72–1.35ms、无连接风暴 Aborted=0、Max Used 37 未顶格);GC(ParNew 19–98ms 正常节奏)。

## 2. 关键判读

- **受害链路**: k6 → apache → IG01/02 → Tomcat01–04 → MG01/02 → dockerB(trace-st)/dockerA(role-st) → [MySQL/Redis,trace 不可见]
- **Mysql01 vs Mysql02**:Mysql02 承载几乎全部重负载(Rows Read 55–73 万 vs Mysql01 的 339–718);但**双库在 t=120/180 同步出现行锁等待尖峰**(Mysql02: 24.83,全时间线最大;Mysql01: 8.3→12.77),而基线期 ST4 历史超时爆发无此尖峰 → 急性层(锁/并发)与慢性层(重扫描)分层。
- **为什么只有 ST4 崩**:ST4 请求需多次串行后端子调用,单次子调用恶化到 0.4–4.5s 时累计最先越过 10s;其他服务单跳变慢但能完成(sr=100, mrt 抬升)。

## 3. 假设树状态(摘)

| id | 陈述(简) | 状态 | 置信度 | 依据 |
|----|----------|------|--------|------|
| H-SYM | 症状锚点:ST4 超时崩溃 t=120–660 | established | 0.95 | E1,E2,E3,E7 |
| **H1** | **MySQL 侧查询阻塞(重扫描+锁)拖慢子调用 → ST4 超时** | **active_focus** | **0.62** | E3,E4,E5 |
| H1a | 急性=行锁/事务持锁,慢性=重扫描背景 | active_focus | 0.55 | E4,E5 |
| H1b | 直接排队点=连接/线程池而非行锁 | open | 0.35 | E5 |
| H2 | docker 容器层退化 | weakened | 0.15 | E3,E6 |
| H3 | Redis 故障 | pruned | 0.03 | E6 |
| H4 | 主机资源饱和 | pruned | 0.05 | E6 |
| H5 | JVM GC 风暴 | open | 0.10 | E6(待专项排除) |
| H6 | 网络丢包/劣化 | open | 0.10 | (待排除) |

## 4. 停止判断

未达停止条件:H1 = 0.62 < 0.8;E3 已给出机制级定位(阻塞在 DB 侧,Request-level 因果),但 "DB 内部何种等待直接拖慢子调用" 还差最后一层直接证据;H5/H6 未正式排除。

## 5. 下一轮计划

1. grep log_service 窗口内 Full GC / 长停顿 → 排除 H5
2. 各主机 NETInErr/NETOutErr/TCP-CLOSE-WAIT → 排除 H6
3. 抽取慢子调用对应 dockerA(role-st) span,确认 0.4–4.5s 落点在 role-st→MySQL 一跳;Mysql02 Com Select/Bytes Received 与子调用变慢的分钟级相关性
4. ThreadsCreated/ThreadsCached/ThreadsRunning 细节 → 区分 H1a(行锁)vs H1b(池排队)
5. 若置信度 ≥0.8 且有 DB 侧直接因果证据 → 结案;否则第 3 轮收敛

## 6. 产物清单

- `state/hypothesis-tree.json`(9 节点,2 剪枝 1 弱化)
- `state/evidence-chain.jsonl`(E1–E7,已 read-back 校验,UTF-8 逐行 JSON 解析通过)
- `state/round-log.jsonl`(本轮决策快照)
- 本报告 `report/rounds/round-01.md`

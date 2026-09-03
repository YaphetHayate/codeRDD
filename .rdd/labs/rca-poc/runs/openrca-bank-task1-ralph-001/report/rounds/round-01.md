# Round 1 报告 — openrca-bank-task1(Ralph 基线臂,单体模式)

**轮次**: 1/4 · **阶段**: 探索+分诊(症状定位与假设空间初始化) · **停止判定**: 未达(无 ≥0.8 置信且含 causal 证据的假设)

## 1. 本轮做了什么

从空状态启动。读取 plane 四份数据结构与 manifest;以 metric_app(全读)→ 访问日志秒级慢请求提取 → 容器指标全 KPI 偏差扫描/首偏差时间线 → trace 分层聚合/操作分类的顺序推进;对每个候选假设亲读原始序列求证。全程仅聚合查询大文件,未整读。

## 2. 症状锚点(已证实,EV-001/EV-003/EV-012)

- **失败形态是纯时延型**: 全数据 0 条非 200 HTTP 状态;metric_app `sr` 恒 100。表现为 `rr`(请求速率)与 mrt 波动。
- **[0,1800] 内三次多服务停滞事件**(apache 口径 >5s 请求秒级时间戳):
  - **E1 = [252, 280]s**(14:34:12–14:34:40): ServiceTest3/4/6/9,含精确 10010–10850ms(10s 超时签名)
  - **E2 = [643, 706]s**(14:40:43–14:41:46): 较宽,ServiceTest4 为主
  - **E3 = [857, 886]s**(14:44:17–14:44:46): ServiceTest3/4/6/7/9,大量 10010–10023ms
- 叠加全窗轻度抬升(per-service 窗/基线均值比: S9 1.71x、S3 1.66x、S6 1.34x、S7 1.30x、S4 1.29x),1800 后恶化趋势(apache01 iowait 17→50%@2280-2340、Mysql02 RowLock 14.13@2400)。

## 3. 关键结构发现

1. **停顿是"等待"而非"执行"**(EV-004): 三事件期间 IG/MG/Tomcat 层 span 最大 10–15s,而 docker 层(dockerA1/A2/B1/B2)span 均值 26–83ms 与平静期无异。慢 span 的操作类型: Tomcat 层为 `st`(→dockerA/role-st)、MG 层为 `dle`(→dockerB/trace-st)。
2. **T0 前存在同签名更严重事件**(EV-002): [-3579,-2869] 数百条 >5s(ServiceTest4 为主,10.01–10.03s),伴 Mysql02 重压(Rows Read 55–73 万/60s、SlowQ 17–25、RowLock 24.8s、ThreadsRun 16-17);-2760 工作负载切换后恢复。**起点被数据左边界截断**。
3. **拓扑**(EV-013): apache → IG01/02(JVM:7778) → MG01/02(JVM:7779) → Tomcat01-04(:8003) 全网格 → dockerA(role-st)/dockerB(trace-st) → Mysql02(活动库)/Redis01。
4. **E2 与 Mysql02 锁竞争精确吻合**(EV-005): RowLock 4.42/6.48@660/720,SlowQ 7.05/8.9,ThreadsRun 10;后续 1200-1260(17 线程)、1440-1620(11.78)、1800+ 持续恶化。E1/E3 落在 60s 采样点之间,无法以现有采样排除同一机制(EV-011)。

## 4. 假设树状态(12 节点)

| 假设 | 内容 | 状态 | 置信 |
|---|---|---|---|
| H1 | Mysql02 行锁/慢查询竞争周期性阻塞后端 | active | 0.45 |
| H2 | Tomcat→dockerA / MG→dockerB 调用路径上的等待(池/队列) | active | 0.30 |
| H3 | Redis01 间歇停顿(ops 同步下降@240/840,客户端 -100@420-540) | active | 0.15 |
| H9 | Mysql01 角色变化(+2 永久连接@660) | active | 0.10 |
| CTX-PRE | 窗前同签名事件(左截断,时刻不可定位) | parked | 0.50 |
| H4 | ~~MG01 CPU-2 核饱和@(-1560,-1320]~~ | **pruned** | EV-006: 热核 CPU-3→CPU-2 迁移伪象,整体 CPU 平坦,MG02 同构 |
| H5 | ~~Redis 资源故障~~ | **pruned** | EV-007: blocked/evicted/fork 全 0,CPU/内存平坦 |
| H6 | ~~docker 容器资源故障~~ | **pruned** | EV-008: MemPercent 恒定、CPU<5% |
| H7 | ~~JVM GC/重启/泄漏~~ | **pruned** | EV-009: uptime 单调、堆锯齿、无 Full GC(gc 暂停时长因快照截断不可读,留注) |

## 5. 诚实记录的坑(方法教训)

- NETPacketsIn 的"爆炸值"是采集器交错的累计计数快照(单调递增),非故障;
- MG01 CPU-2 "饱和"、Redis01 CPU-0 "100%"、Tomcat03/04 单核 100% 均为热核调度迁移伪象(有孪生节点同构佐证);
- 首偏差自动扫描的下行触发(值<中位数/3)在低中位数序列上产生大量噪声首命中,已人工复核;
- trace 窗口划分条件顺序错误一度使 E3 聚合为空,已修复重跑;
- PowerShell `$pid` 为只读自动变量导致一次分类查询失败,已改名重跑。

## 6. 下一轮计划(信息增益排序)

1. **E1/E3 归属判别**(最高增益): localhost_access_log 按秒对齐事件窗,分服务/分 Tomcat/分 IG 提取本地处理 ms——Tomcat 本地耗时若同样慢则停顿在 docker 侧以下;若快则在上游等待。结合慢操作 `st`/`dle` 与受害服务集映射 ServiceTest→dockerA/B 路由。
2. Mysql02 计数器变化率细查(Com_*/Handler_*/Innodb)在 180/240/300 与 780/840/900 采样点,寻找 E1/E3 的弱锁信号。
3. Redis01 深查: rejected_connections、total_connections_received、keyspace hits/misses、uptime(420-540 下陷与重启判定)。
4. 若仍无信号: Tomcat-Threads/MEMORY(7441)秒级与 docker Network 字段。
5. 目标: H1 获得跨三次事件的一致 causal 证据,或转向 H2 的池/队列证据。

## 7. 状态产物

- `state/evidence-chain.jsonl`: 13 条(EV-001…EV-013),已 read-back 校验
- `state/hypothesis-tree.json`: 12 节点(updated_round=1),JSON 校验通过
- `state/round-log.jsonl`: round=1 条目,校验通过

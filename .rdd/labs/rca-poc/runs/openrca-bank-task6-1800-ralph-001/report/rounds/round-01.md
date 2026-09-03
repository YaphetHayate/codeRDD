# Round 01 报告 — openrca-bank-task6-1800 (Ralph 基线臂, 单体模式)

- 轮次: 1/4 | 耗时预算: 已用 1 轮
- 停止判定: **未达停止条件,继续**(无 confidence≥0.8 的假设;假设空间未耗尽)

## 1. 症状锚定(已确认,confidence 0.98)

**单次 60 秒事件:t=0(2021-03-04 18:00:00–18:01:00 UTC+8)**

| 口径 | 事件窗表现 | 基线 |
|---|---|---|
| metric_app rr (t=0 桶) | ST4 85.96 / ST7 89.29 / ST3 96.43 / ST6 96.3 / ST1 97.53 / ST8 98.67 | 100(其余 29 桶全部 100) |
| metric_app mrt | ST4 2755ms / ST6 1654 / ST3 1490 | ST4 ~1100,其余 ~100-500 |
| apache 边缘(k6) | apache01 均值 0.968s(n=281,max **15s**,39 条>1s);apache02 0.962s | 0.02–0.36s |
| HTTP 状态 | 全部 200(全量无非 2xx) | 同 |
| 恢复 | t=60 桶起全部恢复 | — |

前兆(窗外):t=-420(17:53) ST4 单服务 rr=95.71、mrt=1798。

**幅度梯度**(IG 视角 bucket 0):ST4 2.75s > ST6 1.69 > ST3 1.55 > ST9 1.42 > ST7 1.36 > ST8 0.99 > ST1 0.70 > ST2 0.59 ≈ ST10 0.53 ≈ ST5 0.46 >> **ST11 0.14(≈基线,免疫)** —— 劣化幅度∝服务调用深度。

## 2. 层间归因(span 自耗时 = du − Σ子span du)

| 组件 | avgself 基线[-300,0) | avgself 事件[0,60) | 结论 |
|---|---|---|---|
| Tomcat02 | 4.8ms | **147.3ms** | 最重 |
| Tomcat04 | 4.8 | 63.5 | 次重 |
| Tomcat01/03 | 6.2 / 4.0 | 1.8 / 8.9 | 持平(其劣化全由 MG 子调用解释) |
| MG01 / MG02 | 43 / 44.8 | **158.7 / 126.2** | 显著 |
| docker A1/A2/B1/B2 | 30/11.7/25.1/18.6 | 20.6/8.3/32.3/20.8 | **全部持平或降** |
| IG01/IG02 | 0.8/1.4 | 80.8/65.3 | 含未追踪等待 |

慢 trace 解剖(trace gw0120210304180023446669 等):IG02 15007ms ≈ Tomcat02 15005ms(IG→Tomcat 腿不加时延);**Tomcat02 span 开始后 ~10s 无任何子 span 空窗**;最深 MG01/MG02 span 1–6.5s 且无子 span → 停顿位于 Tomcat/MG 的**未追踪依赖等待**处(MySQL 直连 / 网络 / 存储写点)。

## 3. 排除项(均附证据)

| 假设 | 状态 | 关键反证 |
|---|---|---|
| Tomcat02 本地故障 | 剪枝 (0.05) | 4 台 Tomcat 同步劣化 5-8x;T02 JVM/OS 干净(无 Full GC、busy 0-2/500、ErrorCount 静态) |
| Redis01/02 | 剪枝 (0.03) | blocked/rejected/evicted/fork 全 0,ops 平滑,内存平稳 |
| MG JVM 停顿 | 剪枝 (0.05) | 无重启(uptime 连续)、CPULoad 未升、线程平稳;堆突增可由积压解释 |
| TCP 连接层 | 剪枝 (0.05) | CLOSE-WAIT/FIN-WAIT 全 0;连接数仅 +25% |

数据工件(非因果):MG→docker span 父子链自 bucket **-60** 起断链且恢复后仍断,与故障窗不同界 → 追踪采集异常;不影响"docker 层 flat"结论(其 span 速率/时延均不变)。

## 4. 存活假设(双主线)

### H-MYSQL2 (confidence 0.42) — 当前最佳
Mysql02 InnoDB 行锁/慢查询竞争自 **t≈-600 爬坡**:RowLockTime 4.7→13.8→28.3→52.7→**74.95(峰,-240)**→21(-60)→38.9(+60) ms/s;SlowQueries 2.8→27.5(峰)→24.3;ThreadsRunning →**17(+60,全程最大)**;Questions 194→145(吞吐受抑);Mysql01 于 +60 出现唯一锁尖峰 35.7。前兆 ST4 劣化(-420)与爬坡吻合;ST11 免疫与幅度梯度吻合。
**缺口**:事件期锁/慢查询幅度未达秒级,-240 峰时应用未故障 → 需要找到 t=0 的急性触发(binlog/检查点写风暴?连接洪峰?)或改用高分辨率序列证明被 60-120s 采样稀释的爆发。Mysql02 sdc 盘慢性 ~100% busy + CPUWio 26-37% 是背景压力。

### H-INFRA (confidence 0.35)
应用层主机共享基础设施(存储 fsync/虚拟化/网络)60s 抖动:解释客户端侧口径全层停顿、依赖服务端侧口径全部干净(MySQL 内部 GetResponseTime=0、Redis、docker)、**全部应用主机同步 iowait 凸起**(apache/IG/Tomcat/MG/Mysql01 于 t=0/60:0.1%→1-6%,t=120/180 回落;Redis 主机无)、自动恢复。
**缺口**:拓扑无网络/存储组件可归因;服务端侧指标不含网络路径时延的观测盲区使其难以直接证实。

## 5. 下一轮计划(round 2)

1. **H-MYSQL2-BURST 高分辨率检验**:Mysql02 的 Bytes Sent/Received、Connections、ThreadsConnected、Innodb log waits / os log fsyncs / data pending fsyncs、buffer pool pages dirty、sdc DSKBps/DSKPercentBusy 于 t=0±120 的精细序列(各 KPI 采样偏移不同,可拼出 <60s 分辨率)。
2. **H-INFRA 对照**:应用主机(IG01/Tomcat02/apache01/MG01)本地盘 DSKAvgServ/DSKPercentBusy/DSKBps 于 t=0 的精细序列,检验"存储停顿"signature。
3. **幅度梯度机制验证**:基线窗 ST4 vs ST11 的 trace 扇出(MG 调用数/请求),验证"劣化∝每请求下游调用数"。

## 6. 产物清单

- `state/evidence-chain.jsonl`:12 条证据(E1-E12,已 read-back 校验,全部 correlational)
- `state/hypothesis-tree.json`:9 节点(1 确认锚点 + 2 存活 + 4 剪枝 + 1 待验子假设 + 1 工件记录)
- `state/round-log.jsonl`:round 1 决策快照

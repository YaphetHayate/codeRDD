# Round 02 报告 — openrca-bank-task2-1330(Ralph 单体,L2 基线臂)

**轮次**:2/4 | **状态**:结案(停止条件 1) | **本轮新增证据**:E8–E12(5 条,均已 read-back 校验)

## 本轮目标(承接 round-01 计划)
1. 终局排除 H5(JVM GC)与 H6(网络)
2. 下探 H1a:dockerA/MG 侧 span 结构,确认子调用时延落点
3. 判别 H1a(行锁)vs H1b(连接/线程排队)
4. 争取 DB 侧直接证据将 H1 推过 0.8

## 执行与发现

### 1. H5 排除(E8)
- `grep 'Full GC'` log_service.csv 全文件 **零匹配**;gc 日志仅 Tomcat01-04 产生(各 32-34 条)
- 133 条 gc 记录全局最大停顿 **0.12s**;窗口 [-60,780] 内 19 条全部 ≤0.1s、时间均匀无聚集
- MG 无 gc 日志,但 E3 已证 MG01 16306ms span 完全由嵌套 RPC 承担 → 无停顿空间

### 2. H6 排除(E9)
- 窗口 [0,720]:9 主机 NETInErr/InErrPrc/OutErr/OutErrPrc **全 0**(全文件唯一值即 0.0)
- 14 组件(含双 MySQL、双 apache)TCP-CLOSE-WAIT / TCP-FIN-WAIT **全 0**;带宽利用率 ≤0.6%

### 3. Span 树解码 → 机制定位(E10,causal)
重建慢 trace `gw0120210304133300327733` 全 45 行,并对照基线 trace 解码出系统为 **MG↔pod 递归工作流**(MG→dle-way1→dockerA/B pod→role-st/trace-st→MG→…)。
- 链路:IG02(10019)→Tomcat02(10017,内部 5 span 全 0ms)→MG01(**16306**,在客户端 10s 截断后仍继续 6.3s)→dockerB2(16300)
- dockerB2 15 个内部 span:12 个 0-1ms,**3 个劣化 406/1013/1014ms**(兄弟即正常基线)
- 4 个串行子调用出口 1759/3578/4483/2943ms ↔ 服务端 span 在 **MG01/MG02**(1756/3574/4481/2940ms,同 ref、2-3ms 差)
- 每个 MG 服务端 span 时长又 **100% 嵌套下一跳 dle-way1 出口**(无更深 trace 行 = 追踪叶子)
- **结论:全部被追踪组件自身耗时≈0-1ms;16.3s 的 ~93% 分布于串行 RPC 链;滞留在未追踪持久化/派发层;拓扑上该层仅 MySQL×2/Redis×2,Redis 已排除 → MySQL 侧**
- 数据瑕疵注记:docker 行时间戳带 ~-320s 本地钟偏,duration 自洽

### 4. H1a vs H1b 判别(E11)
| 判别项 | 读数 | 含义 |
|---|---|---|
| Threads Created / Slow launch / Aborted | 全 0(双库全程) | 无线程/连接churn |
| ThreadsConnected / Max Used Connections | 25→27 / 恒 37(Mysql01 恒 44/108) | 无连接耗尽 |
| Connections 速率 | 0.15-0.25/s 平坦 | 无连接风暴 |
| Row Lock Waits / current waits | 0.07-0.55/s 平坦 / 恒 0 | 无持续锁排队 |
| LongestTrxActiveTime / CurrentSQLMaxRunningTime | ≤1(全程) | 无长事务/长 SQL 持锁 |
| Max trx rows locked / modified | ≤1 | 无人锁多行 |

→ **H1b 剪枝**;**持续性行锁机制排除**;t=120 锁尖峰(Mysql02 24.83 / Mysql01 8.3→12.77)降级为 **onset 标记**,方向(触发 vs 表征)本观测面不可判定。ThreadsRunning 16-17 = 真实并发执行(扫描查询),非池排队。

### 5. 扫描负载刻画与共动(E12)
- 逐分钟 [0,720]:SlowQueries 17.4-25.8/s;Rows Read 548-732k/s ÷ Com Select 58-91/s ≈ **8k 行/查询**;Com Insert 41-59/s;Select Scan 5.1-8.6/s;ThreadsRunning 16-17(健康 1-4);CPUUser 32.5-48.1%(t=840 仅 1.5%)
- InnoDB 内部干净:buffer pool wait free=0、data pending reads=0、tmp disk tables≈0.03、CPUWio≤6.8% → **非 IO/缓冲瓶颈,慢在行扫描执行**
- 包络:签名自 ≤-3600 持续(对应 ST4 基线轻度低谷),**于 (720,840] 坍塌**(840:0.25 慢查询/4.7k 行/1 线程/1.6% CPU)
- 次级吻合:t=540 Handler Read Next 突发 8006(其余全 0)、t=660 SlowQueries 25.8+LockTime 5.34 ↔ ST4 次级下探(超时 3→9@540→600,rr 85.96@600)
- 恢复次序自洽:客户端 10s 超时=负载卸载 → t≈720 积压泄尽恢复 → 扫描成本随积压表清空而坍塌(720-840)——**扫描成本随积压伸缩的闭环**

## 假设树变化
- H1 → **concluded(0.80)**;新增 **H1c**(扫描负载驱动,established 0.80)
- H1a → weakened(0.25,onset 标记);H1b → pruned;H2 → pruned(容器自身耗时≈0);H5/H6 → pruned
- 全树 10 节点:1 established 症状锚点 + 1 concluded + 1 established 机制 + 7 pruned/weakened,均引用证据 id

## 停止判定
**条件 1 达成**:H1 confidence 0.8 ≥ 0.8,且有 causal 证据支撑(E3 请求级互证 + E10 span 树因果分解)。
→ 写入 `report/final-report.md`;manifest `final_state=root_cause_concluded`。预算消耗 2/4。

## 诚实边界
- 观测面无慢查询日志/DB 逐查询遥测,"子调用↔具体 SQL"最后一环由 请求级分解+穷尽排除+包络共动 闭合,已在 final-report 如实标注
- t=120 锁尖峰方向未判定,不影响主结论(无论触发或表征,驱动均为扫描负载)

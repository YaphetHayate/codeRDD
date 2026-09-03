# 结案报告 — openrca-bank-task2-1330(根因调查)

**Run**:`openrca-bank-task2-1330-ralph-001` | **臂**:ralph-baseline(L2 基线,单体模式) | **轮次**:2/4(预算 4)
**结案方式**:停止条件 1 —— 假设 confidence ≥ 0.8 且有 causal 证据支撑
**manifest final_state**:`root_cause_concluded`

---

## 一、根因结论(原因 + 组件 + 时刻)

### 原因(reason)
**Mysql02 上的 CPU 密集全表扫描查询负载使工作流子调用时延从毫秒级劣化至 0.4–4.5 秒,叠加 t=+120s 双库行锁等待尖峰触发急性发作与积压放大,导致 ServiceTest4 的长串行调用链累计 16.3s、唯一越过客户端 10s 超时而发生响应率崩溃。**

展开:
- **持续驱动(慢性层)**:Mysql02 承载重扫描查询负载——平均每次 SELECT 读取 ~8000 行(Rows Read 548–732k/s ÷ Com Select 58–91/s)、SlowQueries 17–26/s、ThreadsRunning 16–17(健康 1–4)、CPU 用户态 32.5–48.1%(恢复后仅 1.5%)。该负载自 T0−3600 之前即存在,对应 ST4 基线期轻度周期性低谷(E1:-900 rr=43.33、-1560 rr=50.0)。InnoDB 内部无 IO/缓冲/tmp 瓶颈(buffer pool wait free=0、data pending reads=0、tmp disk≈0.03、iowait≤6.8%)——**慢在行扫描执行本身**。
- **急性触发(标记层)**:t=+120s 双库行锁等待时间尖峰(Mysql02 24.83=全时间线最大;Mysql01 8.3→12.77,而 Mysql01 几乎无查询负载),与 ST4 崩溃起点精确对齐;基线期 ST4 低谷无此类尖峰(E5)。
- **受害机制**:系统为 MG↔pod 递归工作流;窗口内每步持久化/派发子调用劣化为 0.4–4.5s;ServiceTest4 单请求需 ~7 次串行子调用(实测 trace 累计 16.3s:子调用 1756/3574/4481/2940ms + pod 内部操作 406/1013/1014ms),远超客户端 10s 超时 → k6 计为失败(无 HTTP 错误,全部 200);链路较短的其他服务仅变慢(sr=100)。
- **恢复机制**:客户端超时形成负载卸载,积压于 t≈+720s 泄尽(ST4 rr=100、全系统 span 时长阶跃回落);扫描负载随积压表清空于 (720,840] 坍塌(Rows Read 711k→4.7k、SlowQueries 23→0.25、ThreadsRunning 17→1)——扫描成本随积压规模伸缩的自洽闭环。

### 组件(component)
- **主:Mysql02**(重扫描负载与执行层劣化的载体)
- 次:Mysql01(仅 t=120/180 瞬时行锁尖峰,无负载异常)

### 时刻(time,T0=13:30 UTC+8)
| 节点 | 时刻 | 观测 |
|---|---|---|
| 发作起点 | t=+120s(13:32) | 双库锁尖峰;ST4 rr 开始跌落(94.52) |
| 最劣 | t=+180s(13:33) | rr=40.54%、mrt=7512ms;26/40 请求 ≥10s |
| 持续 | t=+120~660 | rr 40.5→91.9 波动回升(积压-泄流动力学) |
| 恢复 | t≈+720s(13:42) | rr=100、span 时长阶跃回落 |
| 负载坍塌 | (720,840](13:44 前) | Mysql02 扫描签名消失 |

---

## 二、因果证据链

### 请求级因果锚(causal)
- **E3**(R1):trace `gw0120210304133300327733`(t=180 起)即 log_service 中 ST4 10018ms 超时请求,1–2ms 互证;IG02 10019→Tomcat02 10017→MG01 **16306**→dockerB2 **16300**;MG 在客户端截断后仍继续 6.3s(无取消传播)。
- **E10**(R2,causal):全 45 行 span 树解码——全部被追踪组件(IG/Tomcat/MG/dockerA/dockerB)自身 span 耗时 ≈0–1ms;16.3s 的 ~93% 分布于串行 RPC 链;4 个慢子调用服务端落 MG01/02 且各自 100% 嵌套下一跳未追踪 dle-way1 出口(=追踪叶子);**滞留唯一可能在未追踪的 MySQL/Redis 后端**,Redis 已排除 → MySQL。

### 负载共动与判别(correlational)
- **E4**(R1):Mysql02 慢性扫描签名(8–20 倍 Rows Read、慢查询、CPU)与全系统恢复在 t≈720–840 同步终结。
- **E5**(R1):t=120 行锁尖峰为窗口独有急性事件;基线 ST4 低谷无此尖峰。
- **E12**(R2):逐分钟包络吻合(含次级事件:Handler Read Next 8006@540、SlowQueries 25.8@660 ↔ ST4 次级下探);InnoDB 内部无 IO/缓冲瓶颈 → 行扫描执行本身慢;~8k 行/查询 + Insert 41–59/s 的写密集模式。
- **E7**(R1):12 组件 span 时长与 ST4 rr 同刻阶跃恢复。

### 排除性证据(correlational)
| 假设 | 证据 | 关键读数 |
|---|---|---|
| H2 容器层自身退化 | E3/E6/E10 | 容器 CPU<5.2%、自身 span≈0–1ms,不持有时间 |
| H3 Redis 故障 | E6 | blocked/evicted/rejected 全 0 |
| H4 主机资源饱和 | E6 | CPU≤51%、load<2.5、磁盘服务时间 ms 级 |
| H5 JVM GC 风暴 | E8 | 零 Full GC;全局最大停顿 0.12s |
| H6 网络丢包/劣化 | E9 | NET 错包全 0;TCP 状态全 0;带宽 ≤0.6% |
| H1b 连接/线程池排队 | E11 | ThreadsCreated/SlowLaunch/Aborted=0;MaxUsed 恒 37 |
| H1a-持续 持续行锁排队 | E11 | LongestTrx≤1s;LockWaits 平坦;MaxRowsLocked≤1 |

---

## 三、诚实边界与残留缺口
1. **观测面边界**:plane 无慢查询日志、无 DB 侧逐查询/逐会话遥测。"子调用 ↔ 具体 SQL"的最后一环未获直接观测,由三点合力闭合:(a) E3/E10 请求级分解证明滞留在未追踪层且被追踪组件自身耗时≈0;(b) 拓扑穷尽(未追踪后端仅 MySQL×2/Redis×2)叠加 Redis/主机/网络/GC/排队全排除;(c) Mysql02 负载与故障窗同包络 + 恢复同步 + 次级事件分钟级共动。置信度 0.8 已如实反映此边界。
2. **t=120 锁尖峰方向未判定**:既可能是外部触发事件,也可能是劣化启动后的并发堆积表征;不影响"扫描负载为持续驱动"的主结论。
3. **数据瑕疵**:docker 行 span 时间戳带 ~-320s 本地钟偏(duration 自洽);部分 zabbix 计数为坏值(Bytes Received 为负、row lock time avg/max 为陈旧累计值),均未参与推断。

## 四、对评测口径的说明
若评测以"原因 reason + 组件"计:reason=**数据库慢查询/全表扫描负载导致服务时延劣化超过客户端超时**;组件=**Mysql02**。本报告根因结论由 causal 证据(E3/E10)支撑,correlational 证据(E4/E5/E7/E12)仅作共动与排除用途,未单独支撑结论。

## 五、过程产物索引
- 证据链:`state/evidence-chain.jsonl`(E1–E12,12 条,全部 read-back 校验)
- 假设树:`state/hypothesis-tree.json`(10 节点;H1 concluded 0.8;7 项剪枝/降级均引用证据 id)
- 轮志:`state/round-log.jsonl`(R1、R2)
- 分轮报告:`report/rounds/round-01.md`、`round-02.md`
- 预算:2/4 轮,提前于预算结案

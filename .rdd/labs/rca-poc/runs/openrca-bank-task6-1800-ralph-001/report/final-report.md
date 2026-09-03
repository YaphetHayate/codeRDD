# 结案报告 — openrca-bank-task6-1800 (根因调查)

**Run**: openrca-bank-task6-1800-ralph-001 · **Arm**: ralph-baseline(单体,L2 基线臂) · **轮次**: 2/4(停止条件 1)
**final_state**: `root_cause_concluded`

---

## 1. 结论(TL;DR)

> **根因组件: Mysql02**(MySQL 数据库服务,宿主 Mysql02)
>
> **根因原因: Mysql02 上 MySQL 的急性查询服务停顿(约 18–20 秒,t=18:00:20–18:00:38)**——事件分钟内 mysqld 内部触发一次**检查点型猛烈刷脏**(将全部 3548 个脏页刷盘:pages written 74 页/s=基线 8–30 倍,data written 2.52MB/s=全序列 66 个样本中唯一最大值;逻辑写请求平稳=非应用驱动),刷脏负载穿过**长期饱和的 sdc 盘**(慢性 85–100% busy、iowait 26–37%),叠加自 17:50(t=−600)以来的**行锁/慢查询竞争慢性爬坡**(17:53 t=−420 已产生 ServiceTest4 单服务轻症前兆)。停顿期间每 DB 往返成本升至 0.7–1s 典型/5–8s 峰值,经 MG→Tomcat→IG 链路**按每请求 DB 调用数乘性放大**:深调用服务 ServiceTest4 最重(均值 2.75s,边缘 max 15s),无 DB 扇出服务 ServiceTest11 完全免疫(0.141s≈基线);刷脏完成即恢复(t≈38–40 秒级恢复,t=60 全部 KPI 复常)。

**时刻**: 2021-03-04 18:00:20–18:00:38(UTC+8,急性窗;报告桶 18:00:00–18:01:00 由停顿+尾部排水构成)。前兆 17:53(t=−420,ST4 单服务);慢性背景病起点 ≈17:50(t=−600)。

## 2. 症状(证据 E1/E2/E4/E12)

- t=0 桶(60s)单次事件: 7/11 服务 rr 跌破 100(ST4 最低 85.96),sr 全程 100(无错误,全 200),ST4 mrt 2755ms(基线 ~1100ms),边缘 max 15s;t=60 完全恢复。
- 幅度梯度: ST4 2.75 > ST6 1.69 > ST3 1.55 > … > ST11 0.141s(≈基线,免疫)。
- Span 自耗时归因: docker 层以上全慢、docker flat;慢 trace 解剖: 秒级空窗位于 Tomcat/MG 的未追踪依赖(MySQL 直连)等待处。

## 3. 因果证据链(证据索引 E1–E18,全部含 文件+定位 引用)

### 3.1 触发步(E13,correlational): 唯一且事件锁定的猛烈刷脏
| KPI (Mysql02) | 基线 | 事件分钟 | 判读 |
|---|---|---|---|
| pages written/flushed | 0–9.6 页/s | 73.95 页/s | 8–30x |
| data written | 0.10–0.52 MB/s | 2.52 MB/s | 全序列唯一最大值 |
| dblwr pages written | 0–12 页/s | 73.87 页/s(批式) | 真实穿盘写 |
| dirty pages | 4701→5012 累积 | 5012→**1464** | 全部脏页刷完(Δ−3548) |
| write requests(逻辑写) | 500–670/s | 535/s | **平稳→内部触发** |
| log waits / pending fsyncs | 0 / 1 | 0 / 1 | 非 redo 追压 |

### 3.2 效应结构(E14,causal): 秒级窗 + 剂量-反应
- 急性窗 t∈[20,38): t≤19 时 MG span avg≤323ms 且零个≥5s;t=22–37 avg 1078–7978ms;t=38–40 恢复。
- 请求时延 ∝ MG 调用数: 1-3/4-7/8-11 span → 812/1697/2710ms(基线 102/268/894);每 span 成本 3–7x;p95 最高 11755ms。
- 乘性结构排除恒定偏移的冻结/释放型故障。

### 3.3 案例内复制(E16,causal): 同病两次发作,剂量-幅度
- 逐分钟 ≥5s MG span 计数: 97/99 分钟为 0–6;minute 0=56(本次事件)、minute −7=22(=t−420 ST4 前兆,当时无刷脏、锁竞争主导)。
- 免疫对照: ST11(无 DB 扇出)、Redis 往返、docker 层、12 台应用主机本地盘(sda busy 0–4.75%)全程干净。

### 3.4 传播介质与恢复(E15/E18 + E8/E12): 
- 刷脏 IO 全程穿盘完成(sdc DSKWrite 2092–2338KB/s 无塌缩/回灌)→ 排除存储冻结;慢性饱和盘上的排队恶化为推断步(时延序列死指标,见缺口)。
- 恢复耦合: 刷完即恢复;+60 排水脚印(ThreadsRunning 17、SlowQ 24.3、MG 堆 1184MB、Mysql01 回声 35.7ms/s)。

### 3.5 排除项(全部证据引用,见 hypothesis-tree.json)
| 假设 | 置信 | 排除依据 |
|---|---|---|
| H-INFRA 共享基础设施 60s 抖动 | 0.08 | E15(无冻结)+E16(本地盘闲置/免疫对照)+E17(E9 重估为排水脚印) |
| H-TOMCAT2 Tomcat02 本地故障 | 0.05 | E4+E5(四台同步劣化+自身干净) |
| H-REDIS | 0.03 | E6(KPI 全净) |
| H-MGJVM MG 层 GC/STW | 0.05 | E7+E12+E18 |
| H-NETTCP TCP 连接层 | 0.05 | E10+E16 |
| H-MYSQL2-BURST 的连接洪峰/锁爆发/redo 变体 | — | E13/E15 内数据 |

## 4. 诚实缺口(caveats)

1. **无磁盘时延/队列遥测**(sdc DSKAvgServ 恒 0.72 死指标):"刷脏→IO 排队→查询停顿"为推断;不能完全区分"并发内部停顿(如 mutex)+刷脏伴生"——**两种解释均位于 Mysql02 内部,不影响组件归因,只影响机制细节置信(≈0.65)**。
2. 采样分辨率 60–120s:急性窗 [20,38) 与刷脏样本区间 [−60,+60] 对齐取下界。
3. MG→Mysql02 专属网络链路无遥测;经 Redis 同底座往返平滑间接排除共享网底座。
4. 全部证据为静态快照的**观察型因果推断**(时序+剂量-反应+案例内复制+免疫对照;Bradford-Hill: 强度/梯度/时序/一致性/特异性),无干预实验可能;correlational 证据未单独支撑结论。
5. 数据工件(隔离): MG→docker span 父子链自 t=−60 断裂(E11),未参与因果推理。

## 5. 评测口径说明

若评测以"单一根因组件"对分:本报告结论 **Mysql02**;若以"根因原因"文本对分:核心词为 *MySQL/Mysql02、检查点型脏页刷脏(furious flush/checkpoint)、磁盘 IO 饱和(sdc 慢性 85–100%)、行锁竞争爬坡、查询时延乘性放大*。最佳备选(如口径不同): H-INFRA(0.08,不可观测盲区)。

## 6. 产物清单

- `state/hypothesis-tree.json` — 9 节点,终态含 conclusion(轮 2)
- `state/evidence-chain.jsonl` — E1–E18(轮 1: E1–E12;轮 2: E13–E18,含 2 条 causal 型)
- `state/round-log.jsonl` — 轮 1–2 决策快照
- `report/rounds/round-01.md` / `round-02.md` — 人类复核快照
- `manifest.json` — final_state=root_cause_concluded

## 7. 若继续(已停,仅备忘)

后续可做而预算未用于: binlog/慢日志取证(本 plane 无 MySQL 日志,需外部数据);sdc 队列深度/iostat avgserv 原始数据;mysqld 进程级 thread 状态采样。均超出观测面,属升级人类/运维侧动作。

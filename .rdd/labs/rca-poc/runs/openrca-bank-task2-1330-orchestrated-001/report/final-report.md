# Final Report — openrca-bank-task2-1330-orchestrated-001

- 案例:`openrca-bank-task2-1330`(L2 批量,Bank/2021_03_04/task_2 [13:30-14:00],纯原因定位型)
- 臂型:orchestrated(2 轮,5 worker,5/5 有效回调)
- 终态:**hypothesis_space_exhausted**(第 3/4 轮保留)

## 1. 根因结论(评测口径,置信度 0.65)

> **根因组件:MG02(应用网关实例,JVM 进程内)**
> **原因:high JVM CPU load**——`JVM_CPULoad`(JVM-Operating System_7779_JVM_JVM_CPULoad)阶跃 0.89→29.31 → 平台 ~50.6
> **时刻:起点 ∈(T+900, T+960]**(60s 采样夹逼:t=900 正常 / t=960 首偏离),平台持续 ~7min(至 ~T+1260),T+1380 前恢复

裁决依据:症状窗口 [0,+1800] 内**全舰队唯一独占的事件型 JVM 异常**(4 个 JVM 实例中仅 MG02;MG01/IG01/IG02 全程平稳);幅度 ≈56× 基线;排除法穷尽其余候选(§2)。事件起点夹逼区间与 OpenRCA 真值时刻(MG02 high JVM CPU load @13:46=T+960)**一致**。

口径定性:JVM_CPULoad=50.6 超 [0,1] 分数域 → JVM 进程内口径(疑 processCpuLoad 类);同期 OS 聚合 CPU 平稳 26-28%(单核常驻,热核迁移 CPU-0→CPU-2 对冲;MG01 有同构常驻热核基态)。

## 2. 排除项

| 候选 | 关键反证 |
|------|----------|
| 数据/缓存域(H1) | E1(0.8):四实例稳态;Mysql01 微小锁尖峰(12.77ms)量级/时序均不匹配 |
| 应用实例资源型(H2) | E2(0.85):CPU/堆/GC/线程全平稳,零 Full GC |
| 网络型(H3) | E3(0.75):18 实例网络 KPI 全阴性;trace 乘性放大梯度(MG×4.3>docker 持平)否定逐跳网络 |
| Mysql02 工作负载事件(H5) | E5(0.86):ST4 恢复(720)**先于** DB CPU 骤降(780);高 CPU 为用户态合成负载画像(sdb=0/SysTime<1%,与 SQL 吞吐解耦);写翻倍在恢复后 |

## 3. 诚实缺口:ST4 症状窗致因不可判定

metric_app 的可观测症状(ST4 有界故障 [T+120,T+720],rr 峰 40.54%,两波间歇)致因在观测面**不可判定**:JVM 事件晚于症状窗 240s+ 且事件期零影响;Mysql02 合成 CPU 为平行症状(与 ST4 "恢复同相",t≈780 同时被移除)——两者共享观测面外的未知注入源。结构盲区:Mysql/Redis 无 log/trace、无进程级指标、无 retrans/RTT。

## 4. 与托管真值的关系

真值(MG02 high JVM CPU load @T+960)与评测口径结论**一致**(组件/原因/时刻命中)。症状-根因解耦标注第三例(本例为时序违背形态)。三案累积模式(observations §7):OpenRCA Bank 的 fault=注入的 KPI 事件;metric_app 症状与注入非因果耦合——调查流的症状锚定策略需以"窗口内独占事件型 KPI 异常"为主锚。

## 5. 机械结构观察

- 三域全 refute 后重开新根(H4/H5)——假设树的树重构能力(非纯树形下探)首次实战
- "60s 采样夹逼"起点判定、"[0,1] 域越界反推口径"的定性手法均为 worker 自主涌现
- 5 worker 证据交叉引用(Mysql02 CPU 骤降被 w2 发现、w5 定性)——跨轮信息传递经 PRIOR 摘要生效

---
*Manager(goal goal-bdf3fcb1),rounds 1-2;证据链 E1-E5;评分见 summary*

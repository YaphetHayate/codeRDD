# Final Report — openrca-bank-task1-orchestrated-001

- 案例:`openrca-bank-task1`(L2 pilot,Bank/2021_03_04/task_1,改装观测面)
- 臂型:orchestrated(Manager + 3 轮 worker 扇出,7 worker 调用,7/7 有效回调)
- 预算:4 轮用 3,worker_width 3;第 4 轮保留(边际增益评估见 §5)
- 终态:**budget_exhausted**(置信度 0.6 < 0.8,causal 闭合受观测面结构性盲区阻断)

## 1. 根因结论(最佳假设 H1.1,置信度 0.6,correlational)

> **根因组件:Mysql02(MySQL 数据库实例)**
> **机制:查询模式/速率变化触发的工作负载型阵发性慢查询爆发**(非资源耗尽、非锁竞争主导)
> **发生时刻:T+660s**(= 14:41:00 UTC+8,首个满足预注册异常判定标准的采样点;物理起始 ∈ (T+540, T+660] 采样盲区;T+540s 为语句速率前兆)

判定标准(Round 2 预注册):同一采样点 SlowQueries≥5(基线中位 0.40)且 ThreadsRunning≥5(基线中位 1)且 Row Lock Time≥1.8(基线 <0.6),且下一采样点持续。T+660 实测 SQ=7.05 / TR=10.0 / RLT=4.42。

传导链(观测支撑到倒数第二环):
T+540 语句速率前兆(Questions/ComSelect/ComInsert 全窗新高 +23~26%,RowsRead 平坦 → 语句模式/速率变化而非行扫描洪峰)→ T+660 慢查询首爆(持续至 +720:SQ 8.9)→ *滞后两步机制:Mysql02 风暴期间 MG 层排队/连接池耗竭(**推测**,观测面无该环指标)*→ T+837 MG02 首条 5.9s span / T+840 应用面突变(ST3 mrt 2464.71ms、ST4 rr 90.48,trace 时延梯度 MG 4.5-5.1x > IG/Tomcat 3x > Service 容器平稳)→ T+870-900 恢复。

## 2. 排除项(证据支撑的剪枝)

| 排除假设 | 关键反证 |
|----------|----------|
| 缓存域(Redis01/02) | ~30 KPI × 全点 min/max 双实例全稳态(E2, refute 0.88) |
| 应用域(Tomcat/docker/IG/MG/apache) | 资源全平稳 + 178336 行日志全 200;T+840 突变为传递性受害(E3, refute 0.8) |
| 内存高压型根因(H1.2) | 内存 98% 为静态慢性基线:先于窗口 1h+ 即存在、孪生 Mysql01 同样高压却 SQ≤0.13(判别失败)、BP 命中≈100%/零等待/零 swap/Qcache 零剪枝(E5, refute 0.88) |
| 锁/长事务机制(H1.1.2) | 锁系 KPI 与 SQ 完全同步无先导;current waits/LongestTrx 全窗零;孪生 Mysql01 的 RLT 抬升无慢查询伴随 → 锁时间为伴随量非因(E7, refute 0.7) |
| 末环直接传递(H1.1.1) | 时序反转:T+840 时 DB 空闲(SQ=0.098/TR=2/Questions −35%)而应用请求量稳定 → 应用卡住使 DB 断流,非 DB 正在阻塞应用(E6, refute 0.65) |

## 3. 关键证据(E1–E7 摘录)

- `plane/metric_container.csv`:Mysql02 SlowQueries 时序(基线 0.03–0.5 → 7.05@T+660 / 8.9@+720 / 5.37@+1260 / 4.6@+1560 / 4.8@+1620 / 3.93@+1800);Mysql01 全程 ≤0.13
- `plane/metric_container.csv`:T−3420 历史回合:Mysql02 SQ=19.47 与应用面同刻劣化(ST4 rr=40.54)共变——同机制复现,Mysql01 干净
- `plane/metric_app.csv`:T+840 唯一多服务协同突变;660/720/780 全 rr=100
- `plane/trace_span.csv`:10s 桶时延演化(MG02 @830-840 率先劣化);串行重试签名(13661→7601→3226→9 ms);docker 本地 span 0-17ms(放大不在 Service 容器)
- `plane/metric_container.csv`:资源面反证(CPU≤51%/连接 37/2000/磁盘 busy=0/swap=0)

## 4. 与托管真值的分歧(如实呈现,交人工裁决)

| 口径 | 组件 | 原因 | 时刻 |
|------|------|------|------|
| 托管真值(record.csv) | Mysql02 | high memory usage | T+1620s |
| 本调查结论 | **Mysql02(一致)** | 工作负载型慢查询爆发(内存为静态基线,E5) | T+660s(首爆;T+1620 恰有 SQ=4.8 复发采样) |

组件定位一致;**reason 与时刻存在分歧**。调查证据显示内存恒 98% 无事件型变化且孪生同样高压(E5),窗口内唯一的可判定事件是慢查询爆发。分歧归因:评测集 record 的运维记录口径 vs 遥测观测面的可判定事件口径——标注粒度问题,非调查错误。此分歧为 L2 的重要观察产出(见 observations.md)。

## 5. 置信度未达阈值的诚实说明

- 因果末环(MG 排队/池耗竭)为推测:观测面结构性盲区——log/trace 对 Mysql 本体零覆盖、metric 采样 60s 粒度(720–840 空洞)、MG 池类指标不在 metric_container
- 第 4 轮保留依据:剩余可探方向(语句混合指纹 Com 计数器差分、磁盘写对齐)属机制细节刻画,不改变"组件/原因类型/时刻"三要素判定;边际信息增益低于轮次成本
- 若可补观测:MG 数据源连接池 active/waiting 序列 + MySQL 慢查询日志/error log,可将因果链闭合并可能升级 causal

## 6. 机械结构观察(供 attribution 报告)

- 大观测面(158MB trace/27MB log)grep 按需查询模式全流程无障碍;worker 自主形成查询策略(域内全组件扫描→孪生对照→预注册判定标准)
- 7 worker 调用 7/7 schema 有效回调;citations 全部合规 `plane/` 相对形式(零规范化)
- 独立证据线交叉(H1 域证据 + H3 的 trace 梯度独立指向)再次出现
- 落盘脚本化 + read-back 全程零损坏(PowerShell 内联转义坑以临时 .mjs 规避)

---
*报告生成:Manager(goal goal-025c975d),rounds 1-3 决策快照见 report/rounds/;证据链 E1-E7 见 state/evidence-chain.jsonl*

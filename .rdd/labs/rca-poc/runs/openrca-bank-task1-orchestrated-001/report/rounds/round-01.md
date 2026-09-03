# Round 01 — 决策快照(人类复核用)

- run:`openrca-bank-task1-orchestrated-001`(L2 pilot,编排臂,大观测面首跑)
- 派发:H1(db 域)/ H2(缓存域)/ H3(应用域)→ 3 worker,3/3 有效回调
- 证据落地:E1(H1, correlational, support, 0.50)/ E2(H2, correlational, refute, 0.88)/ E3(H3, correlational, refute, 0.80)

## 整合结论

| 假设 | 回调 | 决策 | 依据 |
|------|------|------|------|
| H1 db 域 | support 0.50 | **下探** → H1.1 / H1.2 | Mysql02 慢查询爆发 + ThreadsRunning 尖峰 + RowLock 抬升;w3 独立发现 trace 时延梯度(MG 5.1x>IG/Tomcat 3x>Service 容器平稳)指向 Mysql 层——两条证据线交汇 |
| H2 缓存域 | refute 0.88 | **剪枝**(免双验,prior 0.35<0.6) | 30 KPI × 全点 min/max 双实例全稳态 |
| H3 应用域 | refute 0.80 | **剪枝**(免双验,prior 0.4<0.6) | 应用组件平稳 + 178336 行日志全 200;T+840 突变为传递性受害 |

## 关键中间事实(供下轮与复核)

- 应用面突变时刻:**T+840**(metric_app:ST3 mrt=2464.71ms,ST4 rr=90.48)——服务受影响的直接观测锚点
- Mysql02 慢查询爆发采样点:T+660/720(7.05/8.9)、T+1260(5.37)、T+1560/1620(4.6/4.8)
- 内存形态:Mysql02 MEMUsedMemPerc 恒 98%(Mysql01 同 97-98%)——静态基线,非事件突变;真值口径待下轮判定(负载型 vs 高压型)
- 观测面盲区:log/trace 对 Mysql 零覆盖(机制通路只能从指标面间接闭合)

## 观察(机械结构)

- 大观测面 grep 模式首跑成功:worker 自主用"grep 组件+KPI 关键词→窗口前后形态对比→横向孪生对照(Mysql01/Mysql02)"的查询策略,未整读大文件
- 三 worker 证据交叉(独立发现 Mysql 层)——扇出宽度的冗余印证再次出现
- citations 格式全部合规(prompt 格式要求持续生效)
- 落盘脚本化(.mjs 临时脚本 + read-back)规避 PowerShell 内联转义坑——记 observations

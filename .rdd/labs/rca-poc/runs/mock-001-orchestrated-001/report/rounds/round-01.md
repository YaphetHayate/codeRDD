# Round 01 — 决策快照(人类复核用)

- run:`mock-001-orchestrated-001`(L1 冒烟,编排臂)
- 派发:H1(db 层异常)/ H2(web 资源不足)/ H3(流量激增)→ 3 worker 并行,3/3 有效回调
- 证据落地:E1(H1, causal, support, 0.85)/ E2(H2, causal, refute, 0.85)/ E3(H3, correlational, refute, 0.80)

## 整合结论

| 假设 | 回调 | 决策 | 依据 |
|------|------|------|------|
| H1 db 层异常 | support 0.85 causal | **下探** → H1.1 / H1.2 | 慢查询(T-44.2 起 rows_examined≈49万)→ 池满(T-20)→ web 等待连接;db 过载子句被反证(CPU 仅 59%) |
| H2 web 资源不足 | refute 0.85 causal | **剪枝**(免双验,prior 0.5<0.6) | 时序与分布双重反证:低 CPU 实例同样慢/504;web-2 抬升与 retry 共变,属下游症状 |
| H3 流量激增 | refute 0.80 correlational | **剪枝**(免双验,prior 0.3<0.6) | 峰值窗口 2/3 实例 CPU<41%、db 59%、写接口全程正常;504 全为等 db 连接 |

## 停止判定

- top_confidence = 0.85(H1)≥ 0.8 阈值,**但未停**:H1 是传导机制层假设,根因层(为什么出现慢查询)未定 → 下探,避免过早停在不完整结论(决策理由落 round-log stop_check.why_not_stop)

## 观察(机械结构)

- 状态三件套轮初首读 ✅;证据链追加式落盘 ✅;范围校验通过(无 confidence 越界)✅
- 原语缺口实证:w2/w3 citations.file 回传全路径而非 `plane/` 相对形式,schema 子集无 pattern 约束,Manager 归一 14 处(归属判据素材,已记 observations)
- worker 无越界读(datasets/analysis 未被引用)✅

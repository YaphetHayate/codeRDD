# Final Report — pm-001-orchestrated-001

- 案例:`pm-001`(L3 postmortem 回放,蓝本 CircleCI 2021-11-08,合成遥测,已标注)
- 臂型:orchestrated(**单轮**收敛,3 worker,3/3 有效回调)
- 终态:**root_cause_concluded**(停止条件 1:0.90 causal ≥ 0.8)

## 1. 根因结论(置信度 0.90,causal)

> **deploy #4821 的 pg-migrator 对 pg.jobs 表执行 ALTER(列 14 存储表示改为 raw numeric)**→ 变更后新写入行与旧行类型混存 → distributor 严格 scan 校验门在混合行上失败(**T-88** 首错)并"拒绝从不一致快照分发"(**T-85** 分发归零)→ job 大量堆积(T0 告警,队列 760)。

**为什么回滚无效**(现象明示的疑点):T+18 回滚仅还原 distributor-api 代码,**pg-migrator 反向迁移未定义被跳过**(pg.log:"reverse step not defined in deploy #4821 manifest")——数据层保持污染,且回滚后仍有新不一致行写入(T+19 错误行标注 "row written AFTER rollback window began")。纯代码回滚在原理上不可能恢复分发。

**直接证明(自然实验)**:T+25 hotfix-ignore-field-8803(读取端容忍该字段)落地**当分钟**分发即恢复(151/min),而 validation_fail_rows 仍处峰值(1400)、T+31 才归零——绕过门禁即恢复,证明阻断条件 = 校验门 × 数据不一致。

## 2. 时序链(每环有观测)

T-95/92 #4821 部署完成(distributor-api + pg-migrator)→ T-90 起新类型行写入 → T-88 校验首败(fail_rows=318)+ dispatch halted → T-85 dispatch 归零 → 队列 60→760(T0) → T+18 回滚完成(代码侧)→ T+19~24 校验仍失败 → T+25 hotfix → dispatch 即恢复 → T+30 validation clean → T+33 backlog drained。

## 3. 噪声鲁棒性(L3 验证目标)

| 噪声/陷阱 | 判定 |
|-----------|------|
| 无关 deploy #4822(T-40,billing-web) | 时间+组件双重排除(w1/w2 独立) |
| canary 重启×3(T-60 期 CPU/GC 波动) | known flake CR-882,始于分发停止后 25min,自行恢复 |
| redis failover 测试 | topology 无 distributor→redis 边 |
| billing-web 慢响应/queue sink lag | unrelated-service |
| 单 worker GC×2 / disk 71% / rate-limiter | 聚合指标同分钟平稳 / 未破阈值 / 果非因 |
| pg.log 时间模糊(仅日期无时刻) | 由 deploy.log 时刻链补齐,未阻碍定位 |

app.log 11 条噪声**全部被正确排除**,误导信号未捕获调查方向。

## 4. 与托管真值的关系

结论与托管答案一致(变更-机制-回滚无效-恢复路径全对齐);R4 检查:根因细节(具体列/类型)不在任何单一 plane 文件,需 deploy.log 审计 × distributor.log 错误消息 × pg.log 反向迁移缺失的组合推理——合法调查链路,非单点泄漏。

## 5. 机械结构观察

- L1/L2 累积经验(域级扇出+机制专项+噪声清单化)在 L3 一次到位:单轮 3 worker 收敛,H1/H2 双 causal 独立交叉
- "自然实验"识别(hotfix 恢复先于数据干净的时序差)为 worker 自主推理
- 小观测面(精读)+ 大观测面(grep)两种模式下调查纪律一致

---
*Manager(goal goal-8230966e),round 1;证据链 E1-E3;评分见 summary*

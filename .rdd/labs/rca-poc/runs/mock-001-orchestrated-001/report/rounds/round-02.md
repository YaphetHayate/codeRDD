# Round 02 — 决策快照(人类复核用)

- run:`mock-001-orchestrated-001`(L1 冒烟,编排臂)
- 轮初首读 state/(hypothesis-tree updated_round=1)✅ 断点恢复语义验证
- 派发:H1.1(缺索引全表扫描占池)/ H1.2(池配置不足/其他持有者)→ 2 worker,2/2 有效回调
- 证据落地:E4(H1.1, causal, support, 0.90)/ E5(H1.2, correlational, refute, 0.80)

## 整合结论

| 假设 | 回调 | 决策 | 依据 |
|------|------|------|------|
| H1.1 release-2185 缺索引全表扫描 | support 0.90 causal | **concluded(根因)** | 部署 T-45 → 首条同型慢查询 T-44.2(0.8min 间隔)→ 池爬升 26→100 → 504 等连接:时序递进+量级匹配(rows_examined≈49万 与参数无关=全表扫描签名)+ 替代解释排除(另两条慢查询量级小 20 倍且晚于池爬升;部署前慢日志零记录) |
| H1.2 池配置/其他持有者 | refute 0.80 correlational | **剪枝**(免双验,prior 0.2<0.6) | 部署前池占用 21~26/100 余量 4 倍,直接反证;无池配置变更记录;无长事务/锁等待型慢查询 |

## 停止判定

- **停止条件 1 触发**:H1.1 confidence 0.90 ≥ 0.8 且 E4 为 causal 证据 → `root_cause_concluded`,写 final-report.md
- 预算余量:2/3 轮已用,剩 1 轮未耗

## 观察(机械结构)

- 引用格式:本轮 worker citations.file 全部合规(Round 1 后 prompt 增加格式要求,补丁生效)
- **工具层失误实证 ×2**:Manager 用 edit(替换语义)操作追加式 evidence-chain/round-log 各造成一次行损坏(已发现并修复,read-back 校验机制起效)——**会话文件工具无 append 原语、无事务性写入**,记入原语缺口观察项(归属判据素材)

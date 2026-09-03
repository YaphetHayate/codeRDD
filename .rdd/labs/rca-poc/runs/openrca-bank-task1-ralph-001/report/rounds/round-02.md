# Round 02 报告 — openrca-bank-task1(基线臂,单体模式)

**轮次目标**: 归因 E1/E3(轮1遗留)、Mysql02 计数器取证、Redis01 深查、等待机制定位。
**实际完成**: 全部完成,并完成一次关键的结构性重构(调用链修正 + 新根因假设 H10 + causal 证据)。

---

## 1. 本轮关键发现

### 1.1 调用链修正(结构性,EV-017)
轮1用 trace 共现推断的 `IG→MG→Tomcat` 排序是错的。以 `parent_id` 链重构 3 条慢 trace 后确认为:

```
apache → IG01/02 ─(op in)→ Tomcat01-04 ─(op st)→ MG01/02 ─(op dle)→ dockerB(trace-st)
                                        dockerB ─(op trace)→ MG(回调)
```

- dockerA(role-st,op=role)**不在**用户请求链上;MySQL/Redis 无 span。
- 轮1的"Tomcat=st(→dockerA)"解读作废;st 是 Tomcat→MG。

### 1.2 停顿机制的请求内定位(causal,EV-018)
E1 窗口全部 9 条 ≥9s 慢 trace 逐 span 重构:

| trace | IG server | Tomcat server/st | MG server | MG dle | dockerB span |
|---|---|---|---|---|---|
| gw…355353121 | 10008 | 10007/10002 | 10828 | **10828** | 无 |
| gw…408349692 | 9935 | 9934/9930 | 9929 | **9929** | 无 |
| gw…407349688 | 10848 | 10847/9840 | 9838 | **9838** | 无 |

MG server 时长 **==** 其 dle 子 span 时长(MG 除等待 dle 外零处理),Tomcat/IG 仅嵌套传播;挂起调用在 dockerB 侧**无对应 span**。9/9 慢 trace 同为 dle+st 双慢(同链传播)。→ **附加时延精确进入 MG→dockerB 的 dle 调用**。

### 1.3 dockerB 未停机(选择性停顿,EV-019)
E1/E3 期间 dockerB1/B2 span 发射速率与基线[-600,-301]无异(B1 2-115/s、B2 2-99/s 量级),dockerA 亦正常 → 仅**部分** MG→dockerB 调用挂起(连接级/选择性),非 dockerB 整体故障;E3 后有补偿高峰(877s B2=136/s、884s B1=115/s)。

### 1.4 事件精确时刻与量级(EV-020/EV-022)
| 事件 | 爬升 | 主爆 | 尾 | apache >5s | dle 慢时长分布 |
|---|---|---|---|---|---|
| E1 | 230-232 | **[232,258]** | 289 | [252,280] ~26条 | 5021-12307ms(n=45) |
| E2 | ~612 | 弥散 | 706 | [643,706] ~27条 | 5203-8864(n=12) |
| E3 | 837-839 | **[840,865]** | 886 | [857,886] ~38条 | 5081-15065(n=26) |
| T0前微事件 | — | [-86,-66] | — | 未查(轮3) | dockerB执行慢(max 12302) |

- apache 的 10.01-10.02s 紧簇 = **上层 10s 超时截断**;内部 dle 等待 5-15s 连续分布 → 重传恢复型轮廓,非源端固定超时。
- 基线平均 n2000=3.9/s ≈ 窗内平静期 ~5/s → 2-7s 背景 span 是常态噪声(轮1的"全窗轻度抬升"部分为噪声+均值敏感)。

### 1.5 DB/Redis 裁决
- **E1/E3 完全无 Mysql02 信号**(EV-014): RowLock 300=0.05/840=0.049/900=0.24,SlowQ≈0.1-0.19,ThreadsRunning 1-2,current waits=0 → H1 无法解释 E1/E3,降级 0.45→0.15。
- **E2 锁突发=锁冲突非负载**(EV-015): Queries/RowsRead 正常带内,RowLock 4.4-6.5s、SlowQ 7-8.9、ThreadsRun 10、宿主 CPU 23.9%/Wio 19.3;方向(因/果)未定。
- **Redis01 干净**(EV-016): uptime 单调、rejected/blocked=0、misses 零增量、无 bgsave/aof;[420,540] 客户端 -100 下陷窗口请求路径无停顿 → **H3 剪枝**。

### 1.6 新发现的两类伴随事件
- **T0前[-86,-66] 微事件**(EV-021): dockerB server+trace span 慢(36条,12.3s),无 MySQL/Redis 信号 → 与 E1/E3 **同族**(dockerB 路径)但"执行慢"模式 → 故障族 T0 前已存在。
- **[480,540] 后端微事件**(EV-023): dockerA1/A2+B1/B2 执行慢(66条)+ Redis -100 客户端 + Mysql02 连接 28→20,用户无感 → 被吸收的扰动。

---

## 2. 假设树变更(15 节点)

| 节点 | 变更 | 依据 |
|---|---|---|
| **H10(新)** MG→dockerB 选择性连接级阻断 | 0.70(causal EV-018) | EV-018/019/020/022 |
| ├ H10a 网络丢包/建连受阻 | 0.40 | EV-019/022 |
| └ H10b dockerB 内部排队/accept | 0.25 | EV-018/021 |
| H1 Mysql02 锁竞争 | 0.45→**0.15** | EV-014(E1/E3 全净) |
| H2 MG 池/队列 | 0.30→0.15 | EV-018(时延在 dle 跳)+反向迹象 |
| H3 Redis | **剪枝** | EV-016 |
| H4/H5/H6/H7 | 维持剪枝(H6 补 EV-019,H7 补 EV-018) | — |
| CTX-PRE | 更新: -86 同族事件入谱 | EV-021 |
| TOPO | 修正调用链 | EV-017 |
| SYM | 事件窗口/量级精化 | EV-020/022 |

## 3. 证据链
EV-014…EV-023 共 10 条追加(含 1 条 causal:EV-018),累计 23 条,全部 read-back 校验通过(JSONL 可解析,末条 EV-023)。

## 4. 停止判断
**未达标**: H10=0.70(<0.8),且**根因发生时刻未裁决**——窗内首次发作=+230s,但同族最早证据=-86s(T0前)。预算余 2 轮。

## 5. 轮3计划
1. **时刻裁决**: apache[-130,-1] 用户影响 + [-130,-60] 慢 span 秒级构成(dle 等待型 vs dockerB 执行型)→ 确定 -86 事件性质,给出根因发生时刻最终口径;
2. H10a/H10b 判别: dle 慢 span 的 span_id 端口/way 标记 × MG 实例关联;E2 的 dle 慢秒与 RowLock 采样窗对齐(删除事务堆积因果方向);
3. [900,2400] 同族模式与 1800 后恶化趋势确认;
4. 决策门: H10≥0.8 → final-report 结案;否则轮4诚实收尾(最佳假设+缺口)。

## 6. 产物清单(仅 run 目录)
- `state/evidence-chain.jsonl`(23 条)
- `state/hypothesis-tree.json`(updated_round=2,15 节点)
- `state/round-log.jsonl`(round=2)
- `report/rounds/round-02.md`(本文件)
- `scratch/`(中间提取/分析脚本与数据:ts 窗口提取、slow5000 普查、apache 逐秒、mysql/redis 窗口、分析脚本)

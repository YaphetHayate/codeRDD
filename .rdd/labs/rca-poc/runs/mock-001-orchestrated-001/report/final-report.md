# 结案报告 — mock-001(L1 冒烟,编排臂)

- run:`mock-001-orchestrated-001`
- 停止条件:**根因置信度达标**(H1.1 confidence 0.90 ≥ 0.80 阈值,预算 3 轮仅用 2 轮)
- final_state:`root_cause_concluded`

## 根因结论

**release-2185(T-45 上线)引入的 orders 表按 customer_id 查询缺有效索引,rows_examined≈49万的全表扫描(单条耗时 3.9s→6.5s)长期占用连接,逐步耗尽数据库连接池(上限 100,T-20 打满),web 层等待连接导致 /v1/orders p99 从 ~150ms 突增至 8s+、错误率 4%(HTTP 504)。**

关键判别:

- 写接口(/v1/orders/create)全程正常 —— 新查询仅命中读路径,排除 db 整体退化
- db CPU 峰值仅 59% 未饱和 —— 排除算力瓶颈,与"少量长扫描占连接"机制自洽
- web-2 CPU 升至 73% 与 retry 注记共变 —— 客户端重试放大所致,**相关非因果**
- 另两条慢查询(2.1万/3.2万行)量级小 20 倍且晚于池爬升主段 —— 非因
- 部署前(T-60~-45)池占用 21~26/100、慢日志零记录 —— 排除存量路径与池配置不足

## 因果链(每一环有观测支撑)

```
T-45  release-2185 上线(新增 SELECT on orders by customer_id,无 schema 迁移)
        ↓ 0.8min
T-44.2 首条同型慢查询:rows_examined 48.7万(与 customer_id 参数无关 ≈ 全表基数,rows_sent=50)
        ↓ 查询持续,duration 3.9s→6.5s 递增
T-40  连接池 active 26→58,/v1/orders p99 开始爬升(230ms)
        ↓ 连接持有时长暴增
T-20  池满(active=100/100,idle=0,waiters=38→69 累积),p99 1900ms
        ↓
T-10.9 首现 504(注记:upstream timeout waiting for db connection)
        ↓
T0    告警:p99 8400ms,err 4.1%
```

## 证据链索引

| id | 轮 | 假设 | 类型 | 判定 | conf | 要点 |
|----|----|------|------|------|------|------|
| E1 | 1 | H1 | causal | support | 0.85 | 传导机制:慢查询→池耗尽→web 等连接 |
| E2 | 1 | H2 | causal | refute | 0.85 | web 资源不足:时序+分布双重反证 |
| E3 | 1 | H3 | correlational | refute | 0.80 | 流量激增:低 CPU+写接口正常反证 |
| E4 | 2 | H1.1 | causal | support | 0.90 | 根因:部署→慢查询→池满完整时序链 |
| E5 | 2 | H1.2 | correlational | refute | 0.80 | 池配置/其他持有者:部署前余量 4 倍反证 |

排除项(全部有证据 id 支撑,无凭空排除):H2(E2)/ H3(E3)/ H1.2(E5)/ H1 的 db 过载子句(E1)。

## 保留缺口(诚实声明)

- 观测面无 EXPLAIN / 索引 DDL 记录:**"缺有效索引"由全表扫描签名(rows_examined≈全表基数且与参数无关)+ 部署明细 "no schema migration" 推断**,非直接索引观测
- 无新路径 QPS 数据,未做 concurrency≈QPS×duration 的精确核算
- 此两缺口是 confidence 0.90 而非更高的原因

## 修复建议(供复核者参考,非调查结论)

短期:回滚 release-2185 或为其查询临时加 (customer_id, created_at) 索引;长期:上线前对新增查询路径强制 EXPLAIN 审查 + 连接池占用按语句聚合告警。

## 运行元数据

- 轮次:2/3;worker 回调:5/5 有效;correlational/causal = 2/3
- 双验规则:未触发(全部剪枝假设 prior < 0.6 门槛)
- 机械结构:建树→派发→回调→剪枝/下探→下一轮→停止 全链路跑通;状态经文件持久化,轮初首读恢复

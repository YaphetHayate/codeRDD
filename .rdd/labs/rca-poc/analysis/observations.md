# 观察项落档(运行期追加)

> 归属判据报告(`analysis/attribution-report.md`,结案时产出)的事实素材。
> 初始清单来自设计决策文档「归属判据观察项清单」,DEV 在运行期逐项追加事实。

## 1. 原语够用性 / 缺口(待验证)

| # | 观察项 | 初始判断(设计期) | 运行期事实 |
|---|--------|--------------------|------------|
| 1 | workflow 无轮间恢复(resume 为引擎延迟项) | 缺口:轮间状态须由 Manager 落盘传递 | **L1 证实可行**:Round 2 轮初重读 state/ 三文件重建认知,断点恢复语义成立(Round 2 首读 updated_round=1 与落盘一致);但状态搬运完全靠 Manager 自觉,引擎不提供任何保障 |
| 2 | 无子代理文件 ACL(worker 只读边界为 prompt 级) | 缺口:R3 越界读理论可行 | **L1 未观察到越界**:5 个 worker 回调 citations 全部在 plane/ 内;但边界仍非强制,归观察项持续量化 |
| 3 | workflow schema 子集无数值边界/pattern | 缺口:confidence ∈ [0,1] 靠 Manager 整合步校验(决策 #9) | **L1 实证两次形态**:(a) 数值边界——5 回调 confidence 全部合规,未触发截断;(b) **pattern 缺失实证**——Round 1 两个 worker 回传 citations.file 全路径而非 `plane/` 相对形式,Manager 归一 14 处;prompt 加格式说明后 Round 2 全部合规(协议层可部分缓解,但非强制) |
| 4 | 无等待态原语(偶现问题复现窗口) | 需求已声明:记入不改,静态快照消解 | (不适用本 PoC) |
| 5 | goal blocked 最小轮次门槛 | 基础设施故障不走 blocked → 案例就绪预检(决策 #8) | **L1 未触发 blocked**:预检通过后 goal 正常 active→complete,3 轮上限只用 2 轮即自然终结 |
| 6 | ralph 无轮内扇出(单 agent/轮) | 设计如此;这使其成为单体基线而非缺陷 | (L2 基线运行时观察) |
| 7 | **(新增)会话文件工具无 append 原语/事务性写入** | 设计期未列入 | **L1 实证 ×2**:Manager 用 edit(替换语义)向追加式 JSONL 追加记录,两次造成既有行损坏(E3 行丢失/round-1 行头部截断),均靠 read-back 校验发现并修复。缺口:结构化状态文件需要专用追加接口或原子写;当前协议必须"追加后立即 read-back 校验"(已写入 manager-system 教训,见 §6 事件日志) |

## 2. 格式稳定性

| 状态文件 | format_version | 变更记录 |
|----------|----------------|----------|
| hypothesis-tree.json | 1 | L1 全程无格式变更;manager_note 字段为实现期自然增加的自由字段,非 schema 破坏 |
| evidence-chain.jsonl | 1 | L1 全程无格式变更;citations.file 约定为 `plane/` 相对路径(Round 1 偏差靠 Manager 归一) |
| round-log.jsonl | 1 | L1 全程无格式变更 |
| case.json | 1 | 无变更 |

## 3. 证据污染缓解效果(双验规则)

- 双验触发次数:**0**(L1 全部剪枝假设 prior < 0.6 门槛:H2=0.5、H3=0.3、H1.2=0.2)
- 复核推翻 worker 初判次数:0(未触发即无推翻)
- 错剪枝导致死路次数:0
- 交叉印证信号(非设计机制但值得记录):Round 1 三个 worker 独立回调均指向 release-2185 时序链,互为佐证——扇出宽度带来的冗余可能是编排臂的隐性增益来源(L2 对照时量化)

## 4. 编排增益信号(两臂对照)

### L1(仅编排臂,mock-001)
2/3 轮收敛,verdict=located(5 关键词命中/0 误归因),证据 5 条(correlational 2/causal 3),链完整,needs_human_review=false。

### L2 双臂对照(4 案配对,同观测面/同现象/同预算 4 轮)

| 维度 | 编排臂(goal+workflow) | 基线臂(ralph 单体) |
|------|------------------------|---------------------|
| 组件命中(含真值组件名) | **4/4**(task1 1词/task6 4词/task2 5词/task1-2100 5词) | **0/4** |
| located(硬口径:concluded+≥2 词) | 1/4(task1-2100;另 2 案 escalated 但关键词 4/5 全中,pilot 1 词) | 0/4(1 案 located_needs_review="CPU"泛词假信号,组件未中) |
| 轮次 | 1-3 轮(4 轮预算) | 1-3 轮(相当) |
| 结案行为 | 3/4 软结案(escalated/exhausted,自评 conf 0.6-0.82) | 4/4 硬结案(concluded,自评 conf 0.8-0.85 + causal) |
| 根因锚定策略 | "窗口内全队独占事件型 KPI 异常"(排除法+独占性)——与评测真值口径一致 | "症状机制解释"(每案给出症状的完整机制故事:flush 风暴/全表扫描/网络流阻塞)——解释力强但组件 0/4 命中 |

**增益结论(首组数据,n=4,不外推)**:编排臂在组件定位上 4/4 vs 0/4。增益来源假设(供 attribution 报告):(a) 扇出宽度的域级穷尽扫描(基线单线扫描漏掉 JVM_CPULoad 等事件线,案 3 实证);(b) 多 worker 独立发现交叉(w1 指标面与 w3 trace 梯度独立指向,两案实证);(c) Manager 整合层的"独占性"判据将调查从症状机制拉回事件锚定。**注意公平性**:基线的机制解释在"调查深度"维度并不差(同秒差分/方向不对称/全网格配对等实验设计漂亮),分歧本质是目标口径(解释症状 vs 找被标注事件),编排臂的优势部分来自 Manager 层的口径裁决,而非 worker 单兵能力。

- 基线过度自信模式:4/4 自评 conf≥0.8+causal 而 0/4 组件命中——单体无交叉校验时"causal 自评"不可靠(attribution 素材)
- 编排臂保守模式:3/4 软结案(escalated)但组件全对——软结案+关键词全中的组合需人工复核通道(已由 component_hit 维度补足)

## 5. 降级路径触发

- 是否启用方案 C(workflow 内循环 + bootstrap 恢复):**未触发**(goal+workflow 组合 L1 顺利运转)
- 触发原因:—

## 6. 运行事件日志(追加式)

| 日期 | 层 | 事件 | 影响 |
|------|----|------|------|
| 2026-08-31 | 脚手架 | 实验目录按设计变更地图搭建;L1 mock×3 + prompts×3 + tools×2 + registry/answers 落地 | 基线就绪 |
| 2026-08-31 | 自测 | score --preflight 三案例全过;convert-openrca 合成样本自测:发现并修复 R2 中性化交叉替换 bug(pattern 产出的中性名被后续 pattern 二次匹配)+ `--probe` 不消费位置参数;R1/R3/R4 规则验证通过;诚实失败路径验证通过 | 工具可用 |
| 2026-08-31 | L1 冒烟 | run mock-001-orchestrated-001:2 轮,R1 派 3 worker(R1 顶层假设 H1/H2/H3)→ 剪枝 2/下探 2;R2 派 2 worker(H1.1/H1.2)→ H1.1 concluded 0.90(causal)触发停止条件 1;score verdict=located | **验收 1 机械结构全链路跑通** |
| 2026-08-31 | L1 冒烟 | 事件:evidence-chain edit 误删 E3 行、round-log edit 截断 round-1 行,均 read-back 发现并修复;根因=会话文件工具无 append 原语 | 观察项 #7 入册;协议增加"追加后 read-back"防御 |
| 2026-08-31 | L1 冒烟 | Round 1 w2/w3 citations.file 回传全路径(格式偏差),Manager 归一 14 处;prompt 补格式说明后 Round 2 合规 | 观察项 #3(b) pattern 缺失实证 |
| 2026-08-31 | datasets | 三仓库 --depth 1 克隆成功:OpenRCA / SRE-skills-bench / post-mortems。**发现:OpenRCA git 仓仅含评测 harness(rca/baseline/rca_agent 单体 agent 代码+prompt,可作基线臂措辞参照),遥测数据集外置 Google Drive(datasets/OpenRCA/dataset/README.md 指引)**,本会话无该渠道下载原语 → L2 主素材获取受阻,属环境限制非架构问题;L2 批量顺延至数据人工置入 datasets/ 后执行(convert-openrca ADAPTER_CALIBRATED=false 诚实失败设计已就绪) | R7 预判命中;L1/L3 素材不受阻;失败归因仍三分类可用 |
| 2026-08-31 | L2 pilot | 人工置入 Drive 最小集(Bank 单日 2021_03_04:query/record/telemetry 四类 csv,~1.5GB);实测结构校准 convert-openrca RULE_VERSION 2:csv 源(非 JSON)、task 级案例化、大文件流式切片 [T0-60min,T0+40min](T0=query 窗口起点防泄答案)、时间列归一相对秒、组件名保留(R2 审计:多组件平面数据中组件名非答案线索且为评分要素);plane 产物 ~191MB(trace 158MB)→ grep 观测面模式,plane 入 .gitignore(可由脚本再生);task_1 双向校准通过(信号在:Mysql02 MEMUsedMemPerc=98/对照平稳;泄答案:scoring_points/record 未进 plane) | **验收 2 前置就绪**;ADAPTER 校准闭环(决策 #10 路径) |
| 2026-08-31 | L2 pilot | run openrca-bank-task1-orchestrated-001(goal 4 轮用 3):R1 域级三 worker(H1 db 支持/H2 缓存证伪 0.88/H3 应用证伪 0.8,trace 时延梯度独立指向 Mysql 层)→ R2 类型级两 worker(H1.1 负载型支持 0.6/H1.2 内存型证伪 0.88)→ R3 机制级两 worker(末环直接传递证伪 0.65/锁长事务证伪 0.7,均反向强化 H1.1)→ 停止条件 2(预算路径,第 4 轮主动保留:边际增益低于成本) | verdict=budget_exhausted;组件定位正确(Mysql02 与真值一致);**验收 3(真实数据可调查)通过**;大观测面 grep 模式全流程无障碍 |
| 2026-08-31 | L2 pilot | PowerShell 内联 node -e 转义坑(引号/中文混排致脚本语法错乱)→ 落盘动作改为临时 .mjs 脚本执行 + read-back,全程零损坏 | 观察项 #7 的又一佐证:结构化落盘需要脚本化接口 |
| 2026-08-31 | 评分 | score --run:链完整/零置信度违规/零悬空引用;summary --all 刷新(orchestrated 2 案例) | 双臂对照待 L2 批量 |
| 2026-08-31 | L2 批量 | 数据侧:发现 task_index 非唯一(=任务类型),convert 加 --range 按窗口唯一定位 + instruction 措辞泛化(between X and Y / from X to Y);三新案转换+preflight 全过(task6-1800/task2-1330/task1-2100);词表缺陷:verdict_keywords 滤掉 3 字符词(JVM/CPU)→合入时手工补全;task1-2100 的 log_service.csv 切 0 行(原始日志该时段无覆盖,记为观测面限制) | 案例池 4 就绪 |
| 2026-08-31 | L2 批量 | 编排臂三案:task6-1800 2 轮(三域 refute→双线下探→停止条件 3,评测口径 Redis02 宿主内存,关键词 4/4);task2-1330 2 轮(三域 refute→树重构新根 H4/H5→停止条件 3,MG02 JVM,关键词 5/5);task1-2100 单轮收敛(停止条件 1,IG01 JVM 时刻夹逼,verdict=located 5/5) | 编排臂 OpenRCA 4/4 组件命中 |
| 2026-08-31 | L2 批量 | 基线臂四案(ralph,同预算):全部 1-3 轮硬结案(自评 conf 0.8-0.85+causal)但组件 0/4 命中(apache02 进程数/Mysql02 扫描/Mysql02 flush/MG-dockerB 网络流)——症状机制解释锚定 vs 评测事件锚定的系统性分歧;task1-2100 基线"CPU"泛词 1 命中→located_needs_review 拦截 | **首组两臂对照数据落档(§4)** |
| 2026-08-31 | 评分 | score.mjs 增强:arm 识别兼容 ralph-baseline 前缀;新增 truth_component/component_hit 维度(软结案组件对 vs 硬结案组件错的公平对照);summary.md 加组件命中列 | --all:编排 located 2/5+组件 5/5,基线 located 1/5(假信号)+组件 0/4 |
| 2026-08-31 | L3 | pm-001 生成(蓝本 CircleCI 2021-11-08,合成遥测已标注;gen-pm001.mjs 可再生):R1-R5 手工执行,R4 根因细节仅托管(deploy.log 只见目标/distributor.log 只见现象/pg.log 只见"有 ALTER 且反向迁移未定义"且无时刻);L3 噪声注入(无关 deploy #4822/canary×3/redis failover/GC/磁盘/rate-limiter)+判别点"回滚无效"(时序推理深度) | 案例就绪,preflight 过 |
| 2026-08-31 | L3 | pm-001 双臂:编排臂单轮收敛(3 worker;H2 0.90 causal——hotfix 自然实验直接证明;H1 0.88 causal 交叉;11 条噪声全排除)→ located 10/13 词 0 reject;基线臂单轮 concluded 0.9+4 causal 且**结论同样正确**(行级身份匹配 1742091) | **两臂等价——增益边界条件实证**(症状即根因机制的传统案例单体即可,增益仅在症状-根因解耦形态显现);attribution §3.3 |
| 2026-08-31 | 结案 | attribution-report.md 产出:三判据全过(机械结构/调查能力/增益归因),PoC 判定=成功;增益三来源(扇出穷尽/独立交叉/口径裁决)+边界条件;建议 5 条(扩样/双锚判据/补盲区/原语上抛/基线校准实验) | **验收 4/5/6/7 素材齐** |

## 7. 评测集口径观察(L2 新增,attribution 素材)

### 7.1 症状-根因解耦(四例累积,模式确认)

| 案例 | 真值(组件/原因/时刻) | 可观测症状 | 解耦形态 |
|------|----------------------|-----------|----------|
| task1(pilot) | Mysql02 high memory @T+1620 | T+840 应用突变(mrt 2469ms) | 内存为静态基线;窗口事件=慢查询;真值时刻恰有复发采样 |
| task6-1800 | Redis02(宿主)high memory @T+540 | T+0 应用尖峰(11 服务 ~10s) | 时序倒置 600s;根因事件对应用零影响 |
| task2-1330 | MG02 high JVM CPU load @T+960 | ST4 有界故障 [120,720] | 事件晚于症状窗 240s+;事件期零影响 |
| task1-2100 | IG01 high JVM CPU load @T+360 | 报障窗内零症状(episode 在追溯窗 20:29) | 症状早于根因事件 35min |

**结论(模式)**:OpenRCA Bank 的"fault"=注入的 KPI 事件(record.csv 运维记录口径),与 metric_app 症状**非因果耦合**。以"症状因果"为锚的调查(解释症状机制)会系统性偏离评测口径;以"窗口内全队独占事件型 KPI 异常"为锚则对齐(编排臂 4/4 命中的核心启发式)。对调查流设计的启示:症状锚定策略需改为"独占事件锚定",症状仅作参考面——这是 L2 对后续迭代最可迁移的发现。

### 7.2 标注粒度

- record 的 reason 为状态描述型("high memory usage" 在 OS 级恒态、非事件),单靠遥测无法从 reason 反推事件形态;需以 component+时刻为主、reason 语义为辅
- 60s 采样下"末基线点/首偏离点"夹逼与真值粒度一致(四例均落在夹逼区间或端点)

### 7.3 worker 行为正面信号

- 面对显眼数字(内存 98%)不锚定,主动孪生对照推翻(pilot w5)
- 预注册判定标准(先定阈值再比对)、"[0,1] 域越界反推口径"、"无症状共存判据"(同等劣化前后不产生症状→非触发器)、"画像指纹比对"(事件内存画像 vs Mysql01 常态)——调查纪律自主涌现

### 7.4 机械评分假阳性实录

- task1-2100-ralph:结论 apache02(组件错)但报告含"CPU"泛词→1 命中→located_needs_review(拦截层生效);component_hit 维度(本日新增)正确判 ❌——泛词命中需与组件命中交叉核验

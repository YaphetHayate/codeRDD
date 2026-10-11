# CodeRDD 项目介绍（最新版）

> 本文档梳理 CodeRDD 当前的完整项目画像，可直接用于项目介绍、申报材料或对外宣讲。
> 事实来源：仓库 `README.md`、`rdd-engine/references/*`、各角色 `SKILL.md`、`docs/code-quality.md` 与当前发布产物，均为撰写时点的真实状态。

---

## 一、项目介绍

CodeRDD 是一套基于 **SDD（Specification-Driven Development，规范驱动开发）** 理念的 **AI 原生软件工程化工作流系统**。它把 Vibe Coding 拆解为「**定义 → 设计 → 实现 → 验证 → 评价 → 呈现**」六个标准化阶段，每个阶段由专属 AI 角色独立执行：PM（需求定义）、CTO（技术架构）、UX（体验设计）、DEV（开发实现）、QA（测试验证）、EVAL（交付评价）、PSE（文档呈现），另设 AUDITOR（事前独立审视）与 PLANNER（规划者，引擎编排形态）承担阶段间的把关与编排。角色职责与协作协议经 `SKILL.md` 标准化定义，通过 **rdd-engine 能力总线**串成一条「阶段可审视、交付可回溯、质量可复现」的流水线。

系统平台无关：同一套角色卡可挂载到 **OpenCode、Claude Code、ZCode、Codex、Warp** 等 Agent 客户端，并为 **DSH（DeepSeek Harness）** 提供桌面应用增强套件（探索缓存插件、目标树状态条插件与一组按角色绑定的 preset）。团队可按角色灵活搭配不同 LLM 与 Agent——例如用强推理模型做需求澄清与技术方案、用高性价比模型做实现与回归——从而沉淀出**成本可控、质量可靠**的 Agent 研发团队。

**一句话概括**：把 Vibe Coding 从「作坊式对话」升级为「有角色、有阶段、有门禁、有账本、可回溯」的工程化生产线，且这套生产线本身是轻量、可移植、平台无关的。

> **命名说明**：RDD = **Requirement-Driven Development**（需求驱动开发，见仓库 `package.json` 自述）；SDD = Specification-Driven Development（规范驱动开发）指其遵循的方法论——**先有明确规范，再进入实现**。

---

## 二、技术栈

| 层次 | 技术选型 |
|------|---------|
| 方法论 | SDD（规范驱动开发）、Plan-and-Execute 范式、规划者–Worker 树形编排（rdd-goal-tree） |
| Agent 协作 | 多角色 Agent（8 角色 + 规划者）、Subagent（`rdd-explore` 探索 worker、评审子代理、UX 多方案 mockup）、Skill（`SKILL.md` 单一事实源） |
| 客户端接入 | OpenCode、Claude Code、ZCode（`coderdd init` 直接支持，含各自专属的 `rdd-explore` 子代理与配置落点）、Codex / Warp（经中立技能发现路径 `.agents/skills/` 共享角色技能）、DSH（DeepSeek Harness）插件与 presets |
| 工具通道 | DSH 插件工具 `rdd_explore`（缓存优先探索）/ `rdd_models`（派发期模型目录）、`rdd-goal-tree` 状态条（MCP 时代的 `rdd_explore` 工具已废弃删除，改用确定性 CLI 协议） |
| 能力总线 | rdd-engine：PowerShell CLI 家族（零运行时依赖）+ 零依赖 Node 运营看板 |
| 检索算法 | 词法 BM25 + 向量余弦多路召回 → RRF 融合 → Top-K 截断（冻结公式 F1–F8）；SHA-256 时效校验 |
| 数据载体 | JSON / JSONL 账本：`task.json`、`.rdd/goal-trees/<run-id>/`、`.rdd/exploration/`、`.rdd/tips/entries/`、`.rdd/review-ledger.jsonl`，全部落盘可审计 |
| 分发安装 | GitHub Release 三 tarball 一体化安装器（engine → plugin → skills 固定顺序）、源码安装（`coderdd` CLI）、引擎/技能组件级独立安装；npm 渠道规划中 |

---

## 三、背景：Vibe Coding 的四大核心痛点

在深入实践 Vibe Coding 的过程中，暴露出四个结构性问题：

1. **意图偏差** —— LLM 对需求理解错误，生成的代码偏离预期；对话里的"隐含共识"无法追溯，返工往往从头开始。
2. **质量不可控** —— 生成代码质量参差不齐，缺乏标准化验收；测试常由同一模型"基于已有实现"编写，等于自己给自己判卷。
3. **上下文溢出** —— 长对话超出窗口限制，早期信息被挤掉；上游讨论的噪音持续污染下游判断。
4. **重复消耗** —— 多模型、多会话之间没有知识共享，同一个模块被反复阅读理解，Token 与时间双重浪费。

根因是：现有 AI 辅助开发整体呈现**"作坊式"状态**——有产能，但没有工程化管理手段；有产出，但没有可回溯的交付物与可复现的验收标准。CodeRDD 要补的正是这一层"工程化基础设施"。

---

## 四、目标

打造一套**轻量、可移植、平台无关**的 AI 开发工作流框架，让任何团队都能把 AI 辅助开发纳入工程化管理：

- **阶段可审视**：每个阶段的输入、产物、判据都明确落盘，可单独打开检查，而不是埋在一段长对话里；
- **交付可回溯**：任务路由、认领、驳回、返工、结案全过程留痕，任何交付物都能追到它的需求出处；
- **质量可复现**：验收标准来自需求文档而非实现代码，量化门禁由确定性工具执行，换人换模型结果一致；
- **成本可控**：通过代码探索缓存与上下文精准裁剪，把"重复理解"的开销降到接近零；
- **灵活搭配**：环节相互独立，不同 LLM 与 Agent 可按角色自由组合，适配多元场景。

---

## 五、行动：做了什么

### 5.1 基于 Plan-and-Execute 的角色 Agent 体系

以 `SKILL.md` 为单一事实源，标准化定义每个角色的职责边界、输入产物、输出产物、宪法层禁令与协作协议，形成覆盖"需求 → 交付"全流程的角色矩阵（权威能力清单见 `rdd-engine/references/capability-manifest.md`，角色扩充无需逐个改技能）。

统一归档目录为 `.rdd/changes/archive/YYYY-MM-DD-<short-name>/{task.json, requirements/, design/, tests/, eval/, review/}`，每个角色的写入范围由**文件白名单**限定——越界写入一律拒绝。

| 阶段 | 角色 | 一句话职责 | 关键产物 |
|------|------|-----------|---------|
| 定义 | **PM**<br>Product Manager | 场景对话 → **需求全貌（确认版）硬门** → 基于全貌拆解归档；只定"做什么"，不定"怎么做" | `requirements/overview.md`（含诉求清单 R# 表）+ `requirements/<name>.md`（含机读「依赖：#N」标注）+ `tasks-init.json` |
| 设计 | **CTO**<br>Chief Technology Officer | 只做技术方向决策（选型 / 模块归属 / 关键要素命名职责 / 配置 / 涉及文件），不写代码；需求分级 L1 可直达 DEV | `design/<name>-cto.md` + `design/<name>-cto-decisions.md`（**变更地图机读契约**） |
| 设计 | **UX**<br>User Experience Designer | 把需求或参考图翻译成 DEV 拿到即可编码的结构化规格（**具体值，禁模糊描述**）；可与 CTO 并行 | `design/<name>-ux.md`、`design/mockups/final.html` + `manifest.json`、`.rdd/design-system/{tokens,components}.md` |
| 实现 | **DEV**<br>Developer | 按设计实现代码并完成自测；出报前过质量自检机械门，**不自行提交**（提交权移交 QA） | 业务代码 + git 分支 + 质量扫描凭据（`-QualityScanFile`）+ `.rdd/bug-register.md` 追加行 |
| 验证 | **QA**<br>Quality Assurance | 双时机：**测试先行**（DESIGN 尾，PM→CTO→QA→DEV）与**验证验收**（VERIFY，功能 + 质量双通过后执行提交） | 测试代码、`.rdd/tests/<feature>/cases.json`（跨迭代长期资产，废弃标 `deprecated` 不删）、`.rdd/tests/index.json`、归档内 `tests/cases.json` |
| 评价 | **EVAL**<br>Evaluation | 交付闭环后的回顾：六维度 A/B/C/D 评分 + 协同链路分析（报告呈用户，不进流转）；**唯一可写 `eval/`** | `eval/evaluation-report.md` |
| 审视 | **AUDITOR**<br>Auditor | **事前把关**（独立滤镜）：建树前四维审归档需求集、设计汇聚后五查审阶段全部设计产物 | `review/requirement-review.json` + `.md`、`review/design-review-S<k>.json` + `.md`、`.rdd/review-ledger.jsonl` |
| 呈现 | **PSE**<br>Pre-Sales Engineer | 横切维护项目"门面"与全局代码质量规范 | `README.md`、`CLAUDE.md` / `AGENT.md`、`docs/code-quality.md` |
| 编排 | **PLANNER**<br>（非角色卡，引擎编排形态） | 目标树的维护者：颁布节点 → 调动角色会话 → `settle` 唯一流转通道 → 结案报告 | `bridge.json`、`plan-log`、结案报告 |

体系的两个关键设计：

- **QA / AUDITOR / EVAL 三权分立**：QA 是"实现之后"的功能与质量双守门；AUDITOR 是"实现之前 / 建树之前"的独立滤镜（只审不改、不代用户裁决、结论契约化落盘）；EVAL 是"交付之后"的复盘。三者视野不同、互不替代，杜绝 LLM 自说自话式验收。
- **AUDITOR 形态演进**：设计 #8 之后，审查不再要求"一批一会话"——需求四维审视与设计五查汇聚的方法论完整保留，内化为**规划者会话内的评审子代理**（`review_mode=subagent`，reviewer 署名 `auditor-delegated`，按 `review-input-template.md` 机械模板逐字携带提示词，禁改写）；用户显式要求独立会话时 `/RDD-AUDITOR` 手动启动强形态（`review_mode=session`，reviewer `auditor`），两者产出同一份契约产物，消费端零改动。

### 5.2 rdd-engine 能力总线：跨角色 / 跨会话的知识共享与流程编排

rdd-engine 是整套工作流的基础设施层，提供七类能力：

**① 代码探索缓存（跨角色 / 跨会话知识共享）**

- **三段式产物**：索引条目（热区 / 持久层）→ `{slug}.summary.md`（摘要，命中时读）→ `{slug}.md`（完整记录，按需读）。检索**返回数据位置而非全量内容**，由调用方按位置自取，单次消费的 Token 量由调用方决定。
- **新鲜度保障**：注册时对 `-Files` 列出的每个受访文件计算 **SHA-256**；检索时逐一校验，文件变更或被删即自动驱逐 stale 条目——缓存不会返回过期结论。
- **精度排序管线**：词法 BM25（零配置常开）+ 向量余弦（配置齐备自动启用，支持跨语语义匹配）多路召回 → **RRF 融合**（公式 F1–F8 冻结）→ Top-K 截断（默认 5）；单路故障自动降级不阻塞。
- **两分支协议**：`results` 非空 = 命中（相关性由确定性公式判定，非 LLM 自判），直接读首条 `summaryPath`；为空 = 未命中，返回体附 `dispatchPrompt`，派遣 `rdd-explore` worker 探索，完成后 `register` 入热区、注册即对下一次检索可见。
- **双 zone 生命周期**：热区 `hot.json`（保留 7 天 / 容量 50 条）+ 持久层 `index.json`；超期未转正条目由 sweep **保底自动转正**，任何已探索结果都不会丢。
- 净效果：**任一角色探索过的模块，其他角色、其他会话零成本直接命中**，且命中确定、可审计（`query-log.jsonl` 记录查询流水与命中率）。

**② 阶段模型、流转与交接包**

- **四阶段全序 + 角色白名单**：`REQ → DESIGN → IMPL → VERIFY → 完成`。

  | 阶段 | 白名单角色 | 语义 |
  |------|-----------|------|
  | REQ | PM | 需求分析与拆解 |
  | DESIGN | CTO ∥ UX ∥ **QA** | 设计与**测试先行**（测试用例本身是设计产物） |
  | IMPL | DEV | 编码实现 |
  | VERIFY | QA | 验收执行 |

  硬不变量 `currentOwners ⊆ PhaseRoles[phase]`——`["UX","DEV"]` 这类跨阶段中间态**无法经任何流转命令达成**（报 `PHASE_OWNER_MISMATCH`）。`phase` 是显式存储字段、不从责任人反推；"生死（lifecycle）与推进（phase）正交"。
- 单一真源 `task.json`：`currentOwners`（阶段白名单内的责任人数组）、`phase`、`designDocs[{path,status}]`、`currentWorker`（认领记录）、`lifecycle`（active / completed / deprecated）。
- `rdd-flow` 提供 17 个命令：`next`（有哪些角色有待办）/ `start` / `handoff`（生成**最小交接包**）/ `claim`（认领锁，同角色重复认领返回冲突而非报错，由用户裁决 `-Force` 抢占）/ `set-route`（**唯一流转路径**，整组替换责任人）/ `reject`（驳回回流）/ `complete` / `reopen` / `deprecate` / `check` / `migrate` 等；角色**禁止直接编辑 task.json**（手写易 schema 漂移，且绕过写入门）。
- **交接即裁剪**：交接包只带下游必需的最小文档集合（需求摘要 / 设计摘要 / 阶段 / 工作模式 / **忽略项 ignored**），并明确六条读取纪律——只读 packet 列出的文档、不扫描整个归档、不读 ignored、代码探索从 `involvedFiles` 起步。上游长对话不随行，配合"阶段切换必开新会话"的硬约束，从机制上杜绝上游上下文污染下游。
- **上下文预算被机械约束**：树内回调 summary ≤600 字符（超限 `SUMMARY_TOO_LONG` 拒收）、worker 最终消息 ≤10 行、完整调查过程必须落文件并由 `full_report` 指针引用（**pull 模型**：规划者默认只读 summary 层，verdict 冲突才按指针拉全文）；`node.task` 禁止复述上游发现，只引用账本条目。长文本一律走文件通道，不进消息。
- **平台入口的防编码损伤设计**：`-TasksFile` / `-CallbackFile` / `-GoalFile` / `-TaskBriefFile` / 派发工单全部走文件通道（参数经 cmd 重解析对中文有静默损坏风险），中文内容只在文件里出现。
- `start-role` 一键交接：按判据链（`RDD_RUNTIME` → `DSH_WEB_URL` → CLI）自动选择后端——Plus 应用内建对话、DSH 经 `/api` 载波建会话并绑定 `rdd-<角色>` preset（含会话血统）、纯 CLI 开新终端窗口预填入口；**任何后端都以新会话承载交接**，agent 无法"同会话内假装隔离"。

**③ 目标树与交付编排（长程任务的 Plan-and-Execute 引擎）**

- **双接口分权**：管理面 `goal-tree.cmd`（规划者驱动树生长：start / graft / prune / settle / redo / conclude / round-start / round-end / deps / status / resume / dispatch）与消费面 `goal-tree-leaf.cmd`（worker 只做 next / claim / report / 本节点 status，**CLI 硬编码字段白名单，物理上无法篡改树结构**）。
- **节点生命周期**：`pending → claimed → reported → done`（或任一状态 → `pruned`，级联整棵子树）。**已 reported 的节点永远不可被重新消费**（claim 只接受 pending）——这是"中断恢复不重复消费"的机械保证；NodeId 单调递增永不复用。
- **硬预算（建树时声明，mid-run 不可增长）**：轮数 `-MaxRounds`（默认 5）、单父节点宽度 `-NodeWidth`（默认 4）、全树节点数 `-MaxNodes`（默认 30），超限分别报 `ROUNDS_EXCEEDED` / `WIDTH_EXCEEDED` / `NODES_EXCEEDED`；依赖 DAG 全图校验（`DEP_CYCLE` / `DEP_SELF` 等原子拒绝）；证据引用范围由 `-RefRoots` 圈定，`citations` 越界或含 `..` 穿越一律拒采并**原样记账**（不静默丢弃）。
- **工程化保障**：状态文件为唯一权威（`.rdd/goal-trees/<run-id>/`，整个目录 gitignore）、`tree.json` 写前 `.bak` + 写后 read-back（损坏自动回退，丢失窗口 ≤ 最近一个写原语）、每 run 一把 `.lock`（争用独占重试 10s，持有者崩溃 60s 自动接管）、回写账本只追加且**坏行隔离到 `.corrupt`**、轮日志起止两行制支持任意一轮中断后 `resume` 续跑。
- **三种终局均为正常终结并产出结案报告**：`achieved`（锚节点终态）/ `budget_exhausted`（引擎校验预算**确实耗尽**，否则拒收——诚实性由引擎背书）/ `space_exhausted`（树无 pending 且无 claimed）。
- **交付桥接 delivery-bridge**：goal-tree 与 task.json 流转的**受控交汇组件**（两侧 CLI 保持黑盒，交汇只经桥接协议）。PM 归档较重时，规划者 `promulgate` 一次性颁布（目标根 + 链头 + 阶段链 + 依赖推导，自动推送无前置依赖节点）→ 调动角色会话 → **`settle` 是 task.json 流转的唯一通道**（四查门禁：verdict=done / citations 真实存在 / extras.verification 非空 / **角色交接门**，再叠加规划者语义复核——机械通过但语义空洞照拒）→ `conclude` 结案（全任务终态 + 整体验收 ACCEPT 硬门）产出结案报告。配套机制：阶段闸门、阶段级回退 `rollback`（剪枝 → 重建回退角色节点 → 路由回退 → 自动重推，**单命令完成**）、规划修正唯一入口 `replan`（revision+1，闸门只增不减）、返工 `reclaim`、并行协作冲突治理（变更地图重叠推送门、串行化消解）、设计汇聚审查（`[设计审查·S<k>]`）、集成验收节点（`[集成验收·S<k>]`）、返工复用原 worker 会话（in-place redo）、规划者租约（30 min stale，他人持新鲜租约报 `LEASE_HELD`，防双规划者）。
- **树级节点**（挂目标根、不绑 TaskId）：`[集成/联调]`（DEV，真实串联各模块跑通原始需求整体场景）、`[整体验收]`（QA，对照判据逐条核验，总结论不可判则结案报 `ACCEPTANCE_PENDING`）、`[集成验收·S<k>]`（阶段验收点自动 graft，是阶段闸门的过闸载体）、`[设计审查·S<k>]`（AUDITOR 阶段边界汇聚审查，pass 才放行 IMPL）。
- **规划者（PLANNER）**：不是第六张角色卡，而是引擎编排形态——树的**唯一维护者**（结构变更权只在它手里）。接单四档分诊（简单问答直接回复 / 简单需求直接实现 / 结构化工作直接建树 / 立项开发拉 PM 走需求审批），三类场景（大需求走桥接链 / 模块直连通用树 / 运维任务走调查角色族扇出），标准循环 `start → round-start → graft → 派发 → 整合（证实 settle / 证伪 prune / 下探 graft）→ round-end → 判定`。硬约束含"等待回调、**禁止轮询**"（worker 交付的唯一完成信号是 leaf report 回调）。
- **调查角色族**（针对根因调查类长程任务，首个验证场景为遥测数据根因回放）：`data-prep`（备料：切窗 / 基线表 / 口径统一）、`metric-analyst`（指标扫描：稳健包络 + 连续性检查）、`log-analyst`（日志：模板聚类 + **阴性证据纪律**，声明沉默范围）、`trace-analyst`（链路：首越定位 + 父子相关性仲裁 upstream-driven / intrinsic）、`root-cause-analyst`（**终局综合只由它完成**，规划者不得 inline 定案）；另有单向证伪的 `probe` 模式（产出只有 upheld / refuted / inconclusive，禁止纯确认式 probe）。

**④ 确定性质量度量（code-metrics）**

把"函数净行数 ≤ 50""嵌套深度 ≤ 5 层"从 LLM 人工审查改为**工具确定性执行**：一场扫描完成变更范围判定（git diff + 追踪态文件，与 Base 版本逐函数文本对比判定"本次触及"）→ 行数 / 嵌套度量 → 双区报告（违规区 + 备忘区）；输出逐字节可复现，退出码分层（0 无违规 / 1 存在硬性违规 / 2 运行错误）。DEV 在出报前跑同一工具做自测前置拦截，QA 用同一口径复核——**口径单源，双方对账**。

**⑤ 项目 tips 知识沉淀（组织学习）**

任意角色把可复用的坑 / 陷阱 / 约定沉淀为结构化条目（`.rdd/tips/entries/`，一条目一 JSON，随仓分发）。核心语义是 **「记录 ≠ 注入」**：新条目出生 `latent`，只有**独立碰撞**（不同会话再撞同一坑，count ≥ 2 自动晋升 `active`）或显式 `pin`（稀有高价教训逃生阀）才进入开工注入段；教训已固化进工具则 `supersede` 让出席位。开工时由 `start-role` 定向注入（8 常青 + 2 试销席位），实现经验在角色间的自动流转。

**⑥ 运营看板（dashboard）**

零 npm 依赖的**本地只读 Node 服务**，一条命令启动（默认 `127.0.0.1:8787`，`-Port` 可换），每次请求重读磁盘、无缓存层，单数据域故障降级为 `available:false` 而不拖垮整页。聚合**七个数据域**：需求归档（含 task.json 流转与生命周期）、探索缓存、查询流水与命中率、检索质量、tips、交付树、配置。页面：总览（KPI 卡 + 跨域规模对比 + 近期动态）、需求归档（可下钻单条需求）、探索缓存、命中率、检索质量、tips、交付树、**配置中心**。数据根支持运行时切换（原生目录选择对话框），服务不重启即可换项目。让"流程到底跑得怎么样"变成可视化运营指标，而不是感觉。

**⑦ 平台接入插件（DSH 增强套件）**

- `@coderrdd/dsh-rdd-explore` **v0.3.1**：把缓存优先的代码探索做成 DSH 原生模型工具——`rdd_explore` 命中即跑精度管线返回候选（默认 topK=5 / recallDepth=20 / rrfK=60），未命中则经宿主 `ctx.subagents` 派 worker 探索并落盘注册；`rdd_models` 提供**活模型目录**（宿主 provider 路由 + 各模型能力标注），供派发时按需选模型（UX 多方案 fork-join 在 DSH 下的模型发现通道）。工程约束上，preset 的委派段**移除了全部裸 subagent 工具行**，替换为该插件行（worker 仅四读工具 `read/read_image/glob/grep`、拒载 `rdd-*` 技能、写白名单、可选只读沙箱、默认 60 分钟周期维护）——**该 preset 会话不存在绕过探索缓存的派遣路径**，这是装配层保证而非提示词约定。
- `@coderrdd/dsh-rdd-goal-tree` **v0.6.0**：把目标树运行状态渲染成输入框上方的**只读状态条**（轮次 x/y、节点预算、状态计数、可展开节点树；运行/节点文档与 UX 视觉稿 chip 一键用系统默认应用打开），**按会话角色分档**（worker 只看自己认领的节点 ＞ 规划者看全树 + 待裁定数 ＞ 旧 run 退化全树 ＞ 不渲染）；ledger 监视器发现新的 report 账目时经宿主 `agent.send(..., 'next-turn')` **自动唤醒**空闲规划者会话（三重幂等去重，重启不重放）。独立构建分发，不在一体化 release 三组件内。
- **索引契约跨客户端互通**：DSH 插件与 rdd-engine CLI 写的是同一份 `.rdd/exploration/`——OpenCode / Claude Code / ZCode 注册的探索产物，DSH 会话直接命中，反之亦然。

### 5.3 门禁体系：让"质量"变成机械事实

- **出口门（DEV 退场）**：DEV 退场必须携带 `-QualityScanFile` 质量扫描凭据（`{tool, base, files, thresholds, threshold_source, violation_count:0, exit_code:0}` 或诚实 skip + reason）；凭据缺失 / 违规数非 0 / 文件不存在 / 非法 JSON → `HANDOFF_GATE_REJECTED`（exit 1，**task.json 零残留**）。被受理的凭据贯穿链式流转，跨阶段回退以诚实 skip 过门。
- **流程门**：`claim` 认领锁防并发重复处理（写路径统一维护 `currentWorker ⊆ currentOwners ∩ lifecycle=active` 不变式）；阶段白名单校验先于任何写操作（拒绝时零残留）；**阶段闸门无 Force 旁路**——未过闸报 `NODE_BLOCKED_BY_GATE`，唯一出路是 settle 对应 `[集成验收·S<k>]` 节点或 `replan` 重划阶段，且闸门只增不减。
- **验收门**：PM 归档必须含「整体验收判据」（缺失即 `ACCEPTANCE_CRITERIA_MISSING` 硬拒）；每阶段须先声明验收点（判据子集 + 一个可运行切片，缺一报 `PLAN_FILE_INVALID`）；结案前须经 `[集成/联调]` 与 `[整体验收]` 节点，总结论须可判否则结案被拒。
- **独立性门**：QA 三条禁令（禁读 CTO 设计文档、禁改业务代码、禁改归档文档）+ 文件白名单；AUDITOR 只审不改、不代用户裁决、产物契约化——**独立不是态度，是被文件白名单和 schema 强制的结构**。
- **规范单源**：`docs/code-quality.md`（PSE 维护）经 `opencode.json` 的 `instructions` 注入所有 Agent 系统提示词，是 QA 量化门禁与 DEV `code-metrics` 阈值（函数 ≤50 行 / 嵌套 ≤5 层）的共同出处——**PSE 定规则、DEV 自测、QA 执行**三方分工，口径不会各自漂移。

### 5.4 分发与安装：一套码，多端可用

- **一体化安装（普通用户主入口）**：一条命令装齐三组件（rdd-engine CLI → dsh-rdd-explore 插件 → 角色技能 + presets），固定顺序编排（preset 挂载依赖插件、技能自检依赖引擎），两步下载消除发布替换瞬间的版本撕裂，装完统一回填 `releaseTag` 到两本账；支持 `-Status` 版本对账、`-Release` 钉版 / 降级、`-Remove` 卸载（只动用户级落点，项目内 `.rdd/` 数据零触碰）。
- **源码安装**：仓根 `npm run register` 注册全局 `coderdd` 命令 → 任意目标项目 `coderdd init .`（可选客户端与角色，配置合并而非覆盖）；`coderdd update .` 按清单更新；多项目批量更新脚本一键全更。
- **组件级独立通道**：只需引擎 CLI 时走 `rdd-engine.tgz`（用户侧零 node/npm 依赖，三级定位链自动命中）；只需角色体系时走 `rdd-skills.tgz`（9 个技能 = 8 角色 + `rdd-engine` 能力卡，连同角色 presets 一起装到用户级，装一次该用户所有项目可用，skills/presets 热生效无需重启）；只需 DSH 插件时 `dsh plugin --profile web add dsh-rdd-explore.tgz`（项目侧零要求，不要求项目里有 rdd-engine）。
- **preset 由 SKILL.md 单源生成**：`build-dsh-presets.mjs` 从各角色 `SKILL.md` 机械生成 preset（剥 frontmatter、替换引擎能力样板、附加 DSH 环境适配声明），`--check` 幂等校验防"改了角色卡忘了重建产物"；规划者 preset 无角色卡，persona 为指向 `planner-guide.md` 的自举指针。仓库默认跟踪 8 组（7 角色 + 规划者），AUDITOR 第 9 组按需 `--with-auditor` 生成（评审已内生于规划者会话，不再默认部署）。
- **平台无关的单一真实源**：技能内容只存 `.rdd/skills/`，各客户端目录（`.agents/skills/`、`.claude/skills/`）以 junction / symlink 指向它——一份内容，多客户端共享，改一处即全端生效。

---

## 六、成果

### 6.1 机制成果

1. **需求与技术实现解耦，从流程上消灭"认知偏差返工"**：PM 的两道门（需求全貌确认硬门 + 基于全貌拆解）保证"无遗漏 / 无曲解 / 无私自增删"，需求无歧义、方案明确后才进入开发。
2. **验收独立性可强制执行**：QA 严格基于需求文档验收标准生成用例，物理上禁止阅读 CTO 设计文档、禁止修改业务代码与归档文档——LLM 无法"基于已有实现自圆其说"。更进一步，QA 被纳入 **DESIGN 阶段白名单**：测试用例可以在设计阶段先行产出（与 CTO/UX 并行），而不是被串行化到交付尾部才发现"测不了"。
3. **探索结果零成本复用**：任意角色经子代理探索代码后自动生成「索引 + 摘要 + 全文」三段式缓存，逐文件 SHA-256 保障新鲜度；其余角色相同探索需求直接命中位置，**显著减少重复代码理解开销**（探索命中 / 未命中由确定性公式判定，命中率可在运营看板查看）。
4. **上下文纯净度有机制保障**：阶段切换强制新会话（`start-role` 三种后端均以新会话承载交接），交接包只带最小上下文，上游污染下游在物理上不可能发生。
5. **长程任务不再失控**：目标树把"派发 → 回写 → 再规划"循环落成持久化状态机——断点可续跑、节点不重复消费、预算可封顶、终局必出结案报告；配合阶段闸门与集成验收节点，"大需求"也能被拆成可审视的小步。
6. **质量从主观判断变为机械事实**：函数行数 / 嵌套深度由工具确定性核查，DEV 自测与 QA 复核同口径；出口门、流程门、验收门、独立性门四层门禁共同保证"质量可复现"。
7. **经验在角色之间自动流动**：tips 机制让踩坑经验变成结构化条目并按碰撞证据自动获得注入资格，后来者开工即被提醒，组织记忆不再随会话结束而蒸发。
8. **成本可核算、可优化**：探索缓存压缩重复理解开销，单任务 / 单需求会话（一需求一会话）限制单次上下文规模，角色 × 模型可自由搭配——好模型用在刀刃上，重复劳动交给缓存。

### 6.2 自举实践数据（本仓库自身即用 CodeRDD 开发）

> CodeRDD 是完全自举的：它自己的每一次功能迭代也走 PM → CTO/UX → DEV → QA → 归档 → 规划者编排的同一套流程。以下为撰写时点的仓库实况数据。

| 指标 | 数值 |
|------|------|
| 已归档需求批次（`.rdd/changes/archive/`） | **29** 批 |
| 目标树交付运行（`deliver-*` run） | **13** 次（另有 QA 夹具运行若干） |
| 测试用例资产（`.rdd/tests/index.json`） | **17** 个功能块 / **552** 条活跃用例 |
| 引擎自带回归套件（`rdd-engine/tests/`） | **19** 个 PowerShell 套件 + **6** 个 Node 套件 |
| 沉淀的角色 tips 条目 | **47** 条 |
| 提交数（单文件 CLI + 文档为主） | **83** commit |
| 当前组件版本 | engine **1.1.0** / coderdd CLI **1.1.0** / dsh-rdd-explore **0.3.1** / dsh-rdd-goal-tree **0.6.0** / skills **1.0.0**（发布通道 tag `v1.0.x`） |

典型的引擎回归套件单次断言规模在数十条量级（如 goal-tree 门禁 80 断言、交付桥接验收 48 断言、阶段模型 80 断言、并行冲突 51 断言、in-place redo 72 断言等），并由 QA 以独立黑盒探针二次复核——**验证者与实现者分离**在工程数据上同样成立。

---

## 七、相对上一版项目介绍的增量

上一版介绍停留在"七角色（PM/CTO/UX/DEV/QA/EVAL/PSE）+ rdd-engine 能力总线（探索缓存 + 流转交接）+ 强制 /new 新会话"。当前版本新增与演进如下：

1. **角色体系扩为 8 角色 + 规划者**：新增 **AUDITOR**（事前独立审视，需求集与设计产物双调用点）与 **PLANNER**（规划者，引擎编排形态而非角色卡，承担交付编排与目标树维护）。
2. **新增目标树与交付桥接**：`goal-tree` / `goal-tree-leaf` / `delivery-bridge` 三件套，把"多轮派发 → 回写 → 再规划"沉淀为可续跑、可封顶、可结案的长程编排引擎。
3. **新增阶段模型**：阶段白名单（REQ / DESIGN / IMPL / VERIFY）、阶段闸门、阶段级回退 `rollback`、集成验收与设计汇聚审查节点。
4. **探索缓存升级为精度排序管线**：由"索引+摘要+全文三段式"升级为**多路召回（BM25 + 向量）+ RRF 融合 + Top-K** 的确定性排序，附带命中率查询流水与运营看板。
5. **新增确定性质量门禁**：`code-metrics` 工具化 #4/#5 条款（函数 50 行 / 嵌套 5 层）、DEV 出报前质量自检机械门（R1–R6 凭据）。
6. **新增 tips 组织学习机制**：记录≠注入、碰撞驱动的注入资格、`latent/active/pinned/superseded` 生命周期。
7. **新增 DSH 平台化接入**：`dsh-rdd-explore` 插件（`rdd_explore` / `rdd_models` 工具）+ `rdd-goal-tree` 状态条插件 + 角色 presets（由 `SKILL.md` 单源生成），实现"装一次，任意 DSH 项目可用"；preset 委派段以插件工具行替换全部裸 subagent 行，探索委派成为**装配层保证**。
8. **新增运营看板**：一条命令起的本地只读服务，聚合探索命中率、需求流转、检索质量、配置、目标树、tips 等**七个数据域**，并可运行时切换项目数据根。
9. **分发体系成型**：GitHub Release 三 tarball 一体化安装器（顺序编排 + 版本对账 + 幂等续装 + 卸载）、源码安装、引擎/技能组件级独立安装三条通道并行。
10. **交接方式自动化**：由"人工 `/new` + 敲命令"升级为 `start-role` 一键交接（Plus / DSH / CLI 三后端自动判据选择，含会话徽章、指针消息、任务绑定）。

---

## 八、一句话价值主张

> **CodeRDD 让 AI 写代码从"一次对话的运气"，变成"一条生产线的产出"**——
> 需求有确认门、设计有评审门、实现有质量门、验收有独立性门，每一步都落盘、可回溯、可复现；
> 而这条生产线本身不绑定任何单一模型或平台，只依赖一套轻量的 CLI 能力总线与 Markdown 角色卡。

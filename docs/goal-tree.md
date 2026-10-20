# goal-tree 目标树编排

> 解决的问题：长程任务在纯对话里必然失控——上下文溢出、预算失控、节点重复消费、中断后无法续跑。goal-tree 把"规划 → 派发 → 回报 → 再规划"的多轮循环交给持久化状态机承载：预算有上限、中断可续跑、节点不重复消费、终局必出结案报告。

## 是什么

Plan-and-Execute 范式的树形编排：**规划者**把目标拆解为节点树，多个 **Worker 会话**并行认领叶子节点、执行并回报，规划者裁定闭环（done / failed / inconclusive），直到目标根达成终局。与角色协作流（rdd-flow 阶段流转）、探索缓存三重正交（目录 / 命令 / 数据零共享），`delivery-bridge` 是唯一受控交汇。

## 双面 CLI 分权

物理隔离的两个 CLI，权限白名单硬编码：

| 面 | CLI | 使用者 | 命令 |
|----|-----|--------|------|
| 管理面 | `goal-tree.cmd` | 规划者会话 | `start` / `graft` / `prune` / `redo` / `settle` / `conclude` / `round-start` / `round-end` / `deps` / `status` / `resume` / `dispatch` |
| 消费面 | `goal-tree-leaf.cmd` | Worker 子代理 | `next` / `claim` / `report` / `status`（字段白名单硬编码，物理上无法改树结构） |

运行数据落 `.rdd/goal-trees/<run-id>/`（gitignore）：`manifest.json`（预算/终局/RefRoots）、`state/tree.json`（权威快照，写前 .bak + 写后 read-back）、`state/ledger.jsonl`（回写账本）、`state/claims/`（认领会话边车）、`.lock`（每 run 一把互斥锁，崩溃 60s 可接管）、`report/rounds/round-NN.md` + `final-report.md`。

## 核心机制

- **节点生命周期**：`pending → claimed → reported → done`（或 → `pruned` 级联子树）；reported 永不可重新消费（claim 只接受 pending）
- **NodeId** = `n<序号>` 单调递增不复用；`depends_on` 显式依赖边与 parent 结构分解正交（全图 DAG 校验），claim 门禁"依赖全满足"（done / pruned 均算）
- **预算三上限**（MaxRounds 5 / NodeWidth 4 / MaxNodes 30）引擎机械强制；三终局 `achieved` / `budget_exhausted`（引擎校验确实耗尽，伪造会被 `BUDGET_NOT_EXHAUSTED` 拒绝）/ `space_exhausted`
- **回调契约**（引擎强制校验）：`node_id` / `verdict` / `confidence∈[0,1]` / `summary≤600 字符` / `full_report` 文件指针 / `citations[{ref,locator}]`（RefRoots 范围内机械归一，越界拒采）/ `next_suggestion` / `extras`；降级规则保证坏回调不破坏运行（invalid 不流转、confidence 截断、拒采后无有效 citation 降 inconclusive）
- **B2 通道分离**：summary 只装判定层，完整调查写 `report/workers/<node-id>.md`——上下游交接不被长报告污染
- **dispatch**：角色 × 任务 × 节点三绑定——规划者根据当前态势把子任务派发给指定角色的 worker 会话：按节点任务性质选角，无依赖的 pending 节点可并行派发（连续 dispatch 各拉各的会话，一个回调周期推进多条线，如 CTO ∥ UX ∥ QA 齐发）；有依赖的等上游 settle 解锁再派——依赖图就是并行计划表。工单走 `state/briefs/<node-id>.md` 文件通道（防 cmd.exe 参数重解析损伤），经 `start-role -GoalTreeWorker` 拉起角色会话

### 可派发 worker 角色

`dispatch -Role` 白名单为会话型八角色，规划者按节点任务性质对号入座选角（`PLANNER` 不可派发——规划者是树维护者不是 worker）：

| 角色 | 职能 | 技能卡 |
|------|------|--------|
| **PM** | 把用户意图变成可执行需求集（依赖关系 + 验收标准 + 整体验收判据）；唯一直吃用户原话的角色 | [`rdd-pm/SKILL.md`](../rdd-pm/SKILL.md) |
| **CTO** | 定技术方向五问（技术/模块/关键要素/配置/涉及文件），不写实现 | [`rdd-cto/SKILL.md`](../rdd-cto/SKILL.md) |
| **UX** | 需求/参考图 → 可执行设计规格（具体值而非感受词） | [`rdd-ux/SKILL.md`](../rdd-ux/SKILL.md) |
| **QA** | 两段职责：DESIGN 测试先行（只依需求写用例，禁读设计）+ VERIFY 独立验收执行 | [`rdd-qa/SKILL.md`](../rdd-qa/SKILL.md) |
| **DEV** | 按需求/设计实现并自测；提交交 QA（IMPL 阶段不 commit） | [`rdd-dev/SKILL.md`](../rdd-dev/SKILL.md) |
| **AUDITOR** | 独立审视：需求侧审查门 + 设计汇聚审查（事前把关） | [`rdd-auditor/SKILL.md`](../rdd-auditor/SKILL.md) |
| **EVAL** | 交付质量评估、协作效率复盘（二级档：常走树外直交，经 `register-session` 登记溯源） | [`rdd-eval/SKILL.md`](../rdd-eval/SKILL.md) |
| **PSE** | README / AGENT / code-quality 等项目上下文文档维护（二级档：树外直交） | [`rdd-pse/SKILL.md`](../rdd-pse/SKILL.md) |

另有卡片型调查角色族（`data-prep` / `metric-analyst` / `log-analyst` / `trace-analyst` / `root-cause-analyst`）不走 dispatch——由宿主扇出子代理整卡嵌入，权威定义见 [`investigation-roles.md`](../rdd-engine/references/investigation-roles.md)。两级选角菜单（一级常用六角色、二级按职责收拢）与输入通道细则见 [`planner-guide.md`](../rdd-engine/references/planner-guide.md) §三。

## delivery-bridge：归档任务集的树化交付

`delivery-bridge.cmd` 是 goal-tree × rdd-flow 的黑盒桥（只编排两侧公开 CLI，不 dot-source 内部）。把已归档的需求任务集颁布为交付 run，按阶段链推进、证据检查后前向流转 task.json：

| 命令 | 职责 |
|------|------|
| `promulgate` | 归档任务集颁布为 `deliver-<归档名>` run：goal 根 = 原始需求 → 需求链头节点 → 阶段链；强制 `-PlanFile` DAG 校验，可选 `-ReviewFile` 需求审查门，无依赖节点 auto-push |
| `dispatch` / `claim` / `reclaim` | 派发 / 认领 / 回收（活会话机械不可回收 `RECLAIM_TARGET_ALIVE`，经 dsh agents registry 判活） |
| `settle` | 唯一 task.json 前向流转通道：三重证据检查 → tree settle → flow set-route/complete → 下一阶段链头收敛 graft → 依赖驱动 auto-push |
| `rollback` | 跨阶段回退：prune + 兄弟重嫁接 + set-route |
| `replan` | 滚动计划修正唯一通道 |
| `status` / `resume` / `conclude` / `lease` / `register-session` / `decide` / `escalate` | 观测 / 续跑 / 结案（+delivery-annex.md）/ 规划者租约 / 会话登记 / 裁定 / 升级 |

## DSH 状态条插件

DSH 环境下可装 [dsh/rdd-goal-tree](../dsh/rdd-goal-tree/) 插件：把运行状态渲染为输入框上方只读状态条（按会话角色分档——Worker 只看认领节点、规划者看全树），Worker 回调可自动唤醒规划者会话。独立构建分发，不随引擎安装——详见 [DSH 适配](./dsh-integration.md)。

## 快速上手

```powershell
# 引擎定位（三级定位链自动命中，此处以用户级安装为例）
$rdd = "$HOME\.rdd\engine\current"

# 规划者：起一棵目标树（goal 根锚定终局）
& "$rdd\scripts\goal-tree.cmd" -Command start -RunId demo -GoalRoot "重构鉴权模块" -GoalFile goal.md
& "$rdd\scripts\goal-tree.cmd" -Command graft -RunId demo -Parent n1 -Title "梳理现有调用链"   # 拆节点
& "$rdd\scripts\goal-tree.cmd" -Command dispatch -RunId demo -Node n2 -Role dev                  # 派发角色 worker

# Worker：认领与回报（消费面）
& "$rdd\scripts\goal-tree-leaf.cmd" -Command next -RunId demo
& "$rdd\scripts\goal-tree-leaf.cmd" -Command claim -RunId demo -Node n2
& "$rdd\scripts\goal-tree-leaf.cmd" -Command report -RunId demo -Node n2 -CallbackFile report.json
```

实际使用中规划者 / Worker 由角色会话驱动，人类只需在规划者会话里下达目标；规划者编排形态见 [`rdd-engine/references/planner-guide.md`](../rdd-engine/references/planner-guide.md) 与 [`planner-scenarios.md`](../rdd-engine/references/planner-scenarios.md)。

## 深度协议

- [`rdd-engine/references/goal-tree-guide.md`](../rdd-engine/references/goal-tree-guide.md) — 唯一权威协议：双面 / 依赖 / 回调 / 恢复 / 审计
- [`rdd-engine/references/task-dispatch-guide.md`](../rdd-engine/references/task-dispatch-guide.md) — 派发与工单通道

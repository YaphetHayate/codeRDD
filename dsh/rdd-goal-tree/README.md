# @coderrdd/dsh-rdd-goal-tree

独立的 **DSH Profile Bundle**：把 rdd-engine 的 goal-tree 运行状态做成输入框上方的**只读状态条**（`conversation.input.dock` 插槽，order 30，排在 todo/goal/queue 之后）。双半边：

- **宿主半边**（exports `.`，经 `cordis.patch.yml` 插入插件行）：`inject ['webServer']`，注册 `GET /rdd-goal-tree/runs?cwd=<会话工作区>`；按 dsh 的项目根规则（向上找 `.git`）定位仓库，纯文件读取聚合 `.rdd/goal-trees/<run-id>/{manifest.json, state/tree.json, state/round-log.jsonl}`。
- **浏览器半边**（exports `./client`，经 package.json `dsh.client: {platform:'web'}` 进 boot graph，浏览器从 `/plugins/@coderrdd/dsh-rdd-goal-tree/client.js` 加载）：`ctx.slots.inject('conversation.input.dock')` 注册 `GoalTreeDock`；`useSessions` 取当前会话 cwd，fetch 轮询（15s + 可见性恢复），渲染运行徽章、轮次 x/y、节点预算、状态计数与可展开的节点树。

**只读边界**：不触碰 goal-tree 的任何写原语（锁/账本/审计由规划者会话的 CLI 独占）；无 run、加载中、cwd 缺失一律渲染空。`@deepseek-ai/*` 导入中仅 `@deepseek-ai/dsh-llm`（`createUserMessage`）与 `@deepseek-ai/dsh-agent`（agents 注册表服务）是运行时依赖，其余 type-only——两者均为 DSH 核心包，经 profile 的 hoisted store 解析。

## 会话绑定与视图（v0.3.0，按会话角色收敛）

引擎在 dsh 环境里额外写两个**增量 sidecar**（文件仍是唯一权威）：

- `state/planner.json` — `goal-tree.cmd start` / `delivery-bridge.cmd promulgate` 发起时的 `DSH_SESSION_ID`。
- `state/claims/<node>.json` — `goal-tree-leaf.cmd claim` / bridge claim 认领时的 `DSH_SESSION_ID`。

条带按会话角色分档（判定表为无依赖纯函数 `pickGoalTreeView`，顺序敏感：Worker > 规划者 > 退化 > 不渲染）：

- **Worker 视图**：当前会话认领了任一 run 的某节点 → 只显示"我的节点"（节点 id/标题/任务全文/状态/回报下一步），整棵树折叠在"查看整棵树"之后。
- **规划者视图**：当前会话是任一 run 的发起者（全表扫 planner sidecar，首个命中——非首位 run 的发起者也看到自己的树）→ 全树条带 + 有 `reported` 未裁定时加一行高亮提示（◆ n 待裁定 → settle / prune）。
- **退化视图（普通全树）**：仅当排序最高 run（`runs[0]`）**无 planner sidecar**（旧 run / 非 dsh 终端发起）时，其余会话保持全树条带；不向后续 run 回退。
- **不渲染**：有 sidecar 的 run 下，与该 run 无关的会话不再渲染树条带（收敛项）。

同一会话既发起又认领时 Worker 视图胜出（判定表顺序）。

## Worker 回调（v0.2.0）

宿主半边带一个 ledger 监视器（默认 5s，仅扫描该端点服务过的仓库，LRU 上限 8 个）：发现**新的 report 账目行**且该 run 绑定了规划者会话时，经 `agent.inbox.append('next-turn', …)`（goal round driver 同款持久队列）向规划者会话投递一条插件消息——内容为节点/worker/verdict/confidence/账目号 + settle/prune/graft 行动提示。规划者会话立即可见，并在其下一轮被消费。**投递从不自动开启新轮**（不替用户花 token）；按 entry 幂等，插件重启靠 inbox 扫描去重。

## 构建与冒烟（codeRDD 仓）

```powershell
node scripts\build-dsh-goal-tree.mjs            # tsc ×2 → client bundle 包装 → npm pack → dist/plugin/dsh-rdd-goal-tree.tgz
node dsh\rdd-goal-tree\tests\smoke.mjs          # 聚合（真实 dsh-demo run）+ 回调产物行 + 视图分档判定表 + bundle 格式断言
node scripts\build-dsh-goal-tree.mjs --check    # 产物形状校验
```

构建期类型经 tsconfig `paths` 指向 DSH checkout 的 `lib/types/*.d.ts`，`@types/react` 以 junction 指入 checkout 的 pnpm store——**不修改 DSH checkout 的任何文件**。`DSH_CHECKOUT` 环境变量可覆盖 checkout 路径。

## 安装（标准 DSH）

```powershell
dsh plugin --profile web add dsh-rdd-goal-tree.tgz     # 装一次，该 profile 打开的任何项目可用
# 重启 profile（重开 dsh web / 新会话）后生效；项目侧零要求、零 rdd-engine 依赖
dsh plugin --profile web remove @coderrdd/dsh-rdd-goal-tree   # 卸载
```

升级 = 新版 tarball 重跑 add；回滚 = 旧版重跑。

## Config

| 字段 | 默认 | 说明 |
|---|---|---|
| `repoRoot` | 按请求从 cwd 向上找 `.git` | 仓库根覆盖（一般不需要） |
| `notifyPlanner` | `true` | Worker report 后向规划者会话投递回调消息 |
| `scanIntervalMs` | `5000` | ledger 扫描周期（毫秒）；`<= 0` 关闭监视器 |

## 已知边界

- 条带按 cwd 解析仓库：会话 cwd 不是 git 仓库时落到 cwd 本身（与 dsh-rdd-explore 同规则）。
- 多 run 并存时显示排序最高者（running 优先、updatedAt 新者优先）；完整列表切换留二期。
- 多 run 退化边界：`runs[0]` 为**有 sidecar** 的新 run 时，无关会话不向后续旧 run 回退（特定组合下旁观者看不到旧 run 全树——已裁定语义，随旧 run 清退归零）。
- 集群/远程工作区未经测试：本插件假设宿主与仓库同机（本机单用户 GUI 语义）。
- 会话绑定依赖**补丁后**的引擎脚本与新的认领/发起：旧 run（sidecar 缺失）退化为普通视图、无回调；Worker/规划者会话须与本插件同属一个 `dsh web` 进程（回调经该进程的 agents 注册表投递）。
- 引擎脚本 `goal-tree.ps1` / `goal-tree-leaf.ps1` 为 UTF-8 **带 BOM**（`powershell.exe` 5.1 按 ANSI 读无 BOM 的含中文脚本会解析失败）——改动这两个文件务必保持 BOM。

## 迁移说明（Manager→PLANNER 更名）

- 配置键 `notifyManager` 已更名 `notifyPlanner`（零兼容策略，旧键不再识别）：曾显式设置 `notifyManager: false` 的环境升级后需改配 `notifyPlanner: false`，否则回调回落默认开启。
- 引擎与插件需**同版本升级**：`state/planner.json` sidecar 由新版 `goal-tree.ps1` 写入，旧引擎 + 新插件的组合读不到 sidecar，表现为视图退化（普通视图、无回调），不报错。
- 存量旧 run（含 `state/manager.json`）不做兼容读取：按零兼容策略落入 legacy 降级分支（普通视图、无回调）。

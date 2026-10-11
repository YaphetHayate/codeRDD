# DSH 适配（DeepSeek Harness）

> codeRDD 平台无关（角色技能经 `.agents/skills/` / `.claude/skills/` 中立发现路径挂载到 OpenCode / Claude Code / ZCode / Codex / Warp），DSH 是其中获得**最深增强**的宿主：两个插件 + 一组 presets + 用户级安装形态。本文讲装了什么、怎么协作;安装操作见[安装指南](./installation.md)。

## 组件总览

| 组件 | 形态 | 提供的能力 |
|------|------|-----------|
| [dsh-rdd-explore](../dsh/dsh-rdd-explore/) 插件 | DSH 插件（一体化三组件之一） | 模型工具 `rdd_explore`（缓存优先探索）+ `rdd_models`（活模型目录）；探索缓存的 TS 字面镜像 |
| [dsh-rdd-goal-tree](../dsh/rdd-goal-tree/) 插件 | DSH 插件（独立分发，可选） | goal-tree 只读状态条 + 规划者回调自动唤醒 |
| rdd presets ×9 | `$DSH_HOME\.agent-presets\rdd-*` 或一体化安装落点 | 按角色绑定的会话 preset（8 角色 + `rdd-planner` 引导） |

## rdd-explore 插件

一体化安装的第二组件（engine → **plugin** → skills 顺序居中——preset 挂载依赖插件）。功能语义见[探索缓存](./exploration-cache.md)，DSH 侧形态：

- **模型工具 `rdd_explore`**：两分支工具（命中读摘要 / 未命中派 worker），worker 为最小权限纯研究者（toolFilter 只放行 read / read_image / glob / grep 四读工具），结构化输出六字段由插件代写代注册
- **模型工具 `rdd_models`**：枚举 `ctx.llm` 注册路由的可服务模型，条目 `{provider,id}` 与派遣覆盖一一对应——规划者派发前用它选模型，避免硬编码模型名落错路由
- **周期维护**：维护定时器（默认 60 分钟）做双区新鲜度清理 + 热区 sweep（仅插件有定时器；引擎 PS CLI 调用驱动）
- **engineRoot 六级候选链**：config → `.rdd/skills/rdd-engine` → `.agents/skills/rdd-engine` → `rdd-engine` → 包内 vendored `assets/rdd-engine`（任意项目开箱即用）→ `~/.rdd/engine/current`
- **插件装完需重启 profile**（bundle 层启动时组合）；skills / presets 则热生效

## rdd-goal-tree 状态条插件

goal-tree 的 DSH 呈现层，**独立构建与分发**（`node scripts/build-dsh-goal-tree.mjs` → `dsh plugin --profile web add dsh-rdd-goal-tree.tgz`），功能语义见 [goal-tree](./goal-tree.md)。双半边结构：

- **宿主半边**：注册 `GET /rdd-goal-tree/runs?cwd=`（聚合 `.rdd/goal-trees` 状态文件，零写原语零锁）与 `GET /rdd-goal-tree/liveness`（会话活性，供 delivery-bridge reclaim 预检）；三层性能设计——并行聚合、per-run mtime+size 指纹缓存（2s TTL）、载荷瘦身（默认只回摘要，活跃 claim 或 `?run=` 才回全量）
- **浏览器半边**：`conversation.input.dock` 插槽渲染 GoalTreeBar（15s 轮询），视图按会话角色分档：Worker 视图（自己的节点 + 任务全文 + 文档 chips）> 规划者视图（全树 + 待裁定提示）> 退化全树 > 不渲染
- **PlannerCallbackWatcher**：监视回写账本新行，经 `agent.send(msg,'next-turn',true)` 投递规划者 inbox **并唤醒会话**；exactly-once 三层去重（内存 set + pending inbox 扫描 + run 级持久 marker）

## presets 体系

`scripts/build-dsh-presets.mjs` 从各角色 `SKILL.md` 生成 `dsh/presets/rdd-{pm,cto,ux,dev,qa,eval,pse,planner}/`（各含 `preset.yml` + `agent.cordis.yml`，跟踪态生成物，`build:local` 做漂移检查）。生成规则核心：

- **移除裸 tool-subagent 工具行、替换为 rdd-explore 工具行**——装配层保证不存在绕过探索缓存的派遣路径
- **persona 内联 SKILL.md 正文**（含 dsh 环境适配节：路径基准 / rdd_explore 探索 / write 白名单 / start-role 交接）
- **forbiddenSkills 硬拒 rdd-\* 经 skill 工具加载**——角色卡只经 preset 装配，防双重人格
- `rdd-planner` 是第 9 组引导 preset：规划者（PLANNER）为引擎编排形态非角色卡，preset 仅作自举指针；`rdd-auditor` 默认退出产品面（评审内生于规划者会话，`--with-auditor` 按需重建）

**分层发现**：项目 `.agents\skills\` 同名技能自动覆盖用户级（DSH 原生机制，零配置）——`coderdd init` 项目布局与用户级安装并存不冲突。

## start-role 后端判据链

角色交接（4 步硬流程的最后一步）由 `start-role.cmd -Role <角色> -TaskId <n>` 承载，脚本按判据链**自动选后端**（agent 不判断模式）：

```
RDD_RUNTIME（显式覆盖）
  → DSH_WEB_URL（dsh 后端：自动创建 preset 绑定的会话并投递交接指针消息）
  → CLI 后端（自动开新终端窗口，预填 /rdd-<角色> 入口）
```

角色切换必须开新会话——上游长对话会污染下游，各后端都以新会话承载交接。协议细节见 [`rdd-engine/references/transition-guide.md`](../rdd-engine/references/transition-guide.md)。

goal-tree 场景的扩展参数：`-GoalTreeRun` / `-GoalTreeNode`（桥接回调标记）、`-TaskBrief` / `-TaskBriefFile`（工单文件通道）、`-GoalTreeWorker`（通用 run worker 指针）、`-ExistingSessionId`（立项回投）。

## 相关安装形态

- **一体化安装**（主入口，三组件同 release）：见[安装指南 · 一体化安装](./installation.md#一体化安装dsh-用户主入口)
- **角色体系用户级安装**（只要技能 + presets）：见[安装指南 · 角色体系用户级安装](./installation.md#角色体系用户级安装rdd-skillstgz)
- **goal-tree 状态条插件**（可选独立分发）：见[安装指南 · 一体化安装](./installation.md#一体化安装dsh-用户主入口)末尾

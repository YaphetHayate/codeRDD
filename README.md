# codeRDD — Requirement-Driven Development Skill

SDD（规范驱动开发）理念的多角色 AI 开发工作流系统：8 个角色技能卡 + rdd-engine 能力总线，把 Vibe Coding 升级为「有角色、有阶段、有门禁、可回溯」的工程化流水线。平台无关——同一套角色卡挂载到 OpenCode / Claude Code / ZCode / Codex / Warp，DSH 宿主另获插件级增强。

## 设计理念

围绕一个核心管道展开：

```
要做什么？ → 要怎么做？ ↔ 做 ↔ 验证 → 评价
```

### 阶段与角色映射

| 阶段 | 问题 | 角色 | 说明 |
|------|------|------|------|
| 定义 | **要做什么？** | [PM](./rdd-pm/) | 需求定义、场景拆分、优先级排序 |
| 设计 | **要怎么做？** | [CTO](./rdd-cto/) + [UX](./rdd-ux/) | 技术方案 + 视觉/交互设计 |
| 实现 | **做** | [DEV](./rdd-dev/) | 任务拆解、并行开发、代码审查 |
| 验证 | **验证** | [QA](./rdd-qa/) | 独立测试、质量验证 |
| 评价 | **评价** | [EVAL](./rdd-eval/) | 交付质量评估、协作效率复盘 |
| 审视 | **事前把关** | [AUDITOR](./rdd-auditor/) | 上游产物独立审视（需求集/设计汇聚进建树/实现前）——独立于 QA 的事前把关角色；EVAL 是事后回顾（报告不进流转），二者定位不同 |
| 呈现 | **怎么讲？** | [PSE](./rdd-pse/) | README 维护、项目上下文文档生成 |

### 核心迭代关系

- **要怎么做？ ↔ 做**：设计与实现双向反馈 — 设计指导实现，实现中发现的问题反馈优化设计
- **做 ↔ 验证**：实现与验证双向迭代 — 测试发现的问题驱动修复，修复后重新验证

角色之上另有**规划者（PLANNER）**——引擎编排形态而非角色卡，承担长程任务的树形编排（见 [goal-tree](./docs/goal-tree.md)）。

## 核心能力

[rdd-engine](./rdd-engine/) 是能力总线,以下能力各自独立成篇详写:

| 能力 | 一句话 | 详见 |
|------|--------|------|
| **探索缓存** | 跨角色/跨会话复用的代码理解知识库——任一角色探索过的代码,其余会话直接命中复用(BM25 + 向量双路召回 → RRF 融合);未命中自动派探索 worker 调查并注册回缓存 | [docs/exploration-cache.md](./docs/exploration-cache.md) |
| **goal-tree 目标树** | 长程任务的 Plan-and-Execute 树形编排:规划者拆目标为节点树、多 Worker 会话并行认领、回报裁定闭环;预算三上限机械强制、中断可续跑、终局必出结案报告;delivery-bridge 把归档任务集树化交付 | [docs/goal-tree.md](./docs/goal-tree.md) |
| **运营端** | 零 npm 依赖的本地只读看板(`ops-dashboard.cmd`):需求归档 / 探索缓存 / 命中率 / 检索质量 / tips / 交付树 / 配置中心七个数据域 + 受控配置写面 | [docs/ops-dashboard.md](./docs/ops-dashboard.md) |
| **DSH 适配** | DeepSeek Harness 宿主的增强套件:rdd-explore 插件(模型工具)/ goal-tree 状态条插件(回调自动唤醒)/ 9 组角色 presets / start-role 三后端判据链 | [docs/dsh-integration.md](./docs/dsh-integration.md) |

三者与角色流转(rdd-flow)的关系:探索缓存、goal-tree、task.json 流转**三重正交**(目录/命令/数据零共享),delivery-bridge 是唯一受控交汇。

## 安装

五种形态速查(完整操作、布局规则与维护者发布流程见 **[docs/installation.md](./docs/installation.md)**):

| 形态 | 适用 | 入口 |
|------|------|------|
| **DSH 一体化安装**(主入口) | 标准 DSH 用户,一条命令装齐 engine + 插件 + 技能 | `install-rdd.ps1` 统一安装器(GitHub Release) |
| **源码安装**(推荐) | 开发者/贡献者,改源码即时生效 | 仓根 `npm run register` → 目标项目 `coderdd init .` |
| npm 安装(规划中) | 待发布 | `npm i -g coderdd` |
| 引擎 CLI 独立安装 | 只要 rdd-engine 命令行 | `rdd-engine.tgz` + `install-rdd-engine.ps1` |
| 角色体系用户级安装 | 只要 9 技能 + 9 组 presets | `rdd-skills.tgz` + `install-rdd-skills.ps1` |

**运行时依赖**:Node.js 18+(仅安装器);git 可选——缺失或非 git 仓时引擎按五级定位链降级,非 git 项目全量可用(协议见 [`rdd-engine/references/engine-location.md`](./rdd-engine/references/engine-location.md))。

## 使用方式

角色通过 skills 激活（OpenCode / ZCode / Codex / Warp 经 `.agents/skills/`、Claude Code 经 `.claude/skills/` 发现，实际内容都在 `.rdd/skills/` 唯一真实源；用户级安装形态则位于 `$DSH_HOME\skills\rdd-*`）。每个角色在自己的会话里工作；切换角色时**开新会话**以保证上下文纯净。

### 角色入口命令

- `/rdd-pm` — 需求定义（流程起点，无交接包）
- `/rdd-cto` — 技术架构
- `/rdd-ux` — 视觉/交互设计
- `/rdd-dev` — 开发实现
- `/rdd-qa` — 测试验证
- `/rdd-eval` — 交付评价
- `/rdd-auditor` — 上游产物独立审视（事前把关：归档需求集/设计汇聚建树前；与 EVAL 事后回顾定位不同）
- `/rdd-pse` — 文档维护

### 角色切换流程

上游角色完成产物归档后，按 transition-guide 的 4 步硬流程交接（命令均经引擎三级定位链定位 `$rdd`，此处以 `rdd-flow` / `start-role` 代指）：

```
rdd-flow set-route（推进 task.json 路由到下游角色：阶段内收窄不带 -Phase，跨阶段切换显式 -Phase）
  → rdd-flow next（展示可流转角色与任务数）→ 推荐目标角色，请用户确认
  → start-role.cmd -Role <角色> -TaskId <n>
      脚本按判据链（RDD_RUNTIME → DSH_WEB_URL → CLI）自动选后端：
      Plus 自动建对话驱动目标角色 / DSH 自动建会话并投递交接指针 / CLI 自动开新终端窗口预填 /rdd-<角色> 入口
```

> 角色切换必须开新会话：agent 无法在同会话内真正隔离上下文，上游长对话会污染下游——start-role 各后端都以新会话承载交接。协议细节见 `rdd-engine/references/transition-guide.md`。

## 项目结构

```
codeRDD/
├── rdd-engine/        能力总线:PowerShell CLI 家族(goal-tree / delivery-bridge / explore /
│                      rdd-flow / start-role / tips / code-metrics / dashboard)+ 运营看板
│                      (dashboard/)+ 协议文档唯一权威源(references/)
├── rdd-<role>/ ×8     角色技能卡(pm/cto/ux/dev/qa/eval/auditor/pse),SKILL.md 单一事实源
├── dsh/               DSH 适配:dsh-rdd-explore 插件 / rdd-goal-tree 状态条插件 / presets 生成物
├── src/               coderdd 安装器 CLI(TypeScript:init / update / uninstall)
├── bin/               coderdd 命令入口
├── scripts/           构建 / 发布 / 安装脚本(build-*.mjs、install-rdd*.ps1、update-projects.ps1)
├── docs/              项目文档(安装指南 / 各能力子文档 / code-quality.md / 项目介绍材料)
├── dist/              构建产物(engine / plugin / skills tarball,发布通道)
└── .rdd/              本仓自用运行时数据(探索缓存 / goal-trees / changes 归档 / tips)
```

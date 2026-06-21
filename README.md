# codeRDD — Requirement-Driven Development Skill

## 设计理念

SDD（Specification-Driven Development）驱动的开发工作流，围绕一个核心管道展开：

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
| 呈现 | **怎么讲？** | [PSE](./rdd-pse/) | README 维护、项目上下文文档生成 |

### 核心迭代关系

- **要怎么做？ ↔ 做**：设计与实现双向反馈 — 设计指导实现，实现中发现的问题反馈优化设计
- **做 ↔ 验证**：实现与验证双向迭代 — 测试发现的问题驱动修复，修复后重新验证

### 基础设施

- **[rdd-engine](./rdd-engine/)**：能力总线，提供代码探索和阶段流转能力

---

## 安装到其他项目

仓库根提供 `install.ps1`（PowerShell 5.1+）、`install.cmd`（Windows 包装器）、`install.sh`（macOS/Linux 包装器，需 `pwsh`）。把 codeRDD 的 skill + 引擎 + 命令 + 工具装进任意 git 仓库。

### 快速开始

```powershell
# Windows：克隆 codeRDD 后，在目标项目里执行
D:\path\to\codeRDD\install.cmd -Target .

# macOS / Linux
/path/to/codeRDD/install.sh -target .
```

### 安装模式

| 模式 | 内容 | 适用 |
|------|------|------|
| `full`（默认） | engine + 全部 7 角色 + 全部 commands + docs | 完整 RDD 流程 |
| `minimal` | engine + PM/CTO/DEV + 对应 commands | 主链路（需求→设计→开发） |
| `custom` | engine + `-Roles` 指定角色 | 按需组合 |

```powershell
install.ps1 -Target D:\my-project -Mode minimal
install.ps1 -Target D:\my-project -Mode custom -Roles pm,cto,qa
install.ps1 -Target D:\my-project -NoDocs      # 不装 docs/code-quality.md
```

### 冲突合并规则

目标项目已有配置时，**合并而非覆盖**：

| 目标文件 | 策略 |
|---------|------|
| `.opencode/package.json` | `dependencies` 取并集，已存在的依赖保留目标版本 |
| `opencode.json` | `instructions` 追加 `docs/code-quality.md`（已存在则跳过），其他字段不动 |
| `docs/code-quality.md` | 已存在则跳过（用户可能已定制） |
| 其余 copied 文件 | 内容相同跳过；内容不同且未 `-Force` 则跳过并警告 |

### 更新与卸载

```powershell
install.ps1 -Target D:\my-project -Update       # 按原配置刷新（Force 覆盖 codeRDD 文件）
install.ps1 -Target D:\my-project -Uninstall    # 删除 copied 文件、还原 merged 配置
install.ps1 -Target D:\my-project -DryRun       # 预演，不写盘
```

`-Update` 沿用清单记录的 mode/roles；要切换 mode/roles 请先 `-Uninstall` 再装。安装记录写入 `<target>/.opencode/.rdd-install.json`，合并前的原始配置备份到 `<target>/.opencode/.rdd-install-backup/`。

### 参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `-Target` | `.` | 目标项目根（必须是 git 仓库） |
| `-Mode` | `full` | `full` / `minimal` / `custom` |
| `-Roles` | — | `custom` 模式必填，逗号分隔：`pm,cto,ux,dev,qa,eval,pse` |
| `-NoDocs` | — | 不复制 `docs/code-quality.md`，不追加 instructions |
| `-Force` | — | 覆盖内容不同的 copied 文件（不影响用户自有文件） |
| `-DryRun` | — | 预演，输出将做什么但不执行 |
| `-Update` | — | 基于清单记录的配置刷新安装 |
| `-Uninstall` | — | 按清单卸载、还原配置 |
| `-Quiet` | — | 只输出摘要 |

### 运行时依赖

- **PowerShell 5.1+**（Windows 自带；macOS/Linux 装 `pwsh`）
- **Bun**（opencode plugin 机制需要）
- **git**（rdd-engine 用 `git rev-parse` 定位仓库根）

---

## 使用方式

角色通过 opencode 自定义命令激活（命令位于 `.opencode/commands/`）。每个角色在自己的会话里工作；切换角色时**开新会话**以保证上下文纯净。

### 角色入口命令

- `/rdd-pm` — 需求定义（流程起点，无交接包）
- `/rdd-cto` — 技术架构
- `/rdd-ux` — 视觉/交互设计
- `/rdd-dev` — 开发实现
- `/rdd-qa` — 测试验证（待补）
- `/rdd-eval` — 交付评价（待补）
- `/rdd-pse` — 文档维护（待补）

### 角色切换流程

```
当前角色完成产物归档 → $rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command next 推荐下游 → 用户确认
  → /new（Ctrl+X N）开新会话（清理上下文）
  → 输入 /rdd-<下游角色> → 自动加载角色 SKILL + 最新交接包 → 干净进入
```

> 角色切换必须开新会话：opencode 的 agent 无法在同会话内真正隔离上下文，"同会话宣布边界"无法阻止上游对话污染下游。详见 `rdd-engine/references/transition-guide.md`。

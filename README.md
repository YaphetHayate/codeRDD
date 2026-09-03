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

## 安装

提供三种形态：**项目内整仓安装**（源码安装，当前可用，推荐）、**DSH 插件化用户级安装**（一体化安装，装一次任意 DSH 项目可用，见下）、**npm 安装**（规划中）。仅需引擎 CLI（技能已由其他渠道安装）时可走**引擎独立安装**，仅需角色技能体系时可走**角色体系用户级安装**（均见本节末尾），无需克隆本仓库。

### 一体化安装（DSH 用户主入口）

目标用户是**标准 DSH 用户**：一条命令装齐三组件（rdd-engine CLI → rdd-explore 插件 → 角色技能 + presets），并保证三件来自同一个 release。发布渠道为 GitHub Release（三 tarball 固定名 + `install-rdd.ps1` 统一安装器，不用 npm）。

**前置**：Windows 10 1803+（自带 `tar.exe`）、PowerShell 5.1+、git、标准 DSH（`dsh` 与 `pnpm` 在 PATH）。

```powershell
# 一条命令（latest release：下载统一安装器并执行）
powershell -ExecutionPolicy Bypass -Command `
  "Invoke-RestMethod https://raw.githubusercontent.com/YaphetHayate/codeRDD/master/scripts/install-rdd.ps1 -OutFile $env:TEMP\install-rdd.ps1; & $env:TEMP\install-rdd.ps1"

# 离线安装：三 tarball 已备好（如 dist/release/ 或手动下载）时
powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Offline <dir>
```

安装顺序编排为 **engine → plugin → skills**（硬编码：preset 挂载依赖插件、技能装后自检依赖引擎定位链）；两步下载（先解析 latest → 具体 tag，再从该 tag 目录取三件）消除发布替换瞬间的版本撕裂；装完统一回填 `releaseTag` 到两个账本（`~\.rdd\engine\manifest.json`、`~\.rdd\skills\manifest.json`）。任一组件失败时打印已完成组件与续装指引（组件安装器幂等，重跑即续装），不做自动回滚。

```powershell
powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Status           # 版本对账：三组件 version / releaseTag / 一致性判定
powershell -ExecutionPolicy Bypass -File install-rdd.ps1                   # 升级到 latest
powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Release v1.0.0   # 降级 / 钉住旧版
powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Remove           # 卸载（尽力删 + 残留汇总报告）
```

- **插件装完需重启 profile**（重开 `dsh web` / 新会话），bundle 层在启动时组合；skills / presets 热生效无需重启
- **升级 / 卸载只动用户级落点**（`~\.rdd\engine`、`$DSH_HOME\skills` 与 `.agent-presets`、profile 依赖行），项目内 `.rdd/` 数据零触碰
- **项目内旧数据兼容**：`task.json` v1、探索缓存（`.rdd/exploration/` 只读格式）、`tree-runs` 状态文件均向后兼容——用户级安装与其并存，互不改动
- 组件级细节见下方各节与 [dsh/dsh-rdd-explore/README.md](./dsh/dsh-rdd-explore/README.md)

### 方式一：源码安装（推荐）

分两步：先在 codeRDD 仓根注册全局 `coderrdd` 命令（一次性），之后在任意目标项目里安装。

**第 1 步：注册全局命令**（在 codeRDD 仓库根执行）

```bash
git clone https://github.com/YaphetHayate/codeRDD.git
cd codeRDD
npm run register     # 依赖检查 -> 构建 -> npm link -> 自检，输出后续指引
```

**第 2 步：安装到目标项目**（在任意目标项目根执行）

```bash
coderrdd init .                                # 交互式：选择 AI 客户端与角色
coderrdd init . --tools opencode,claude --yes  # 非交互（CI / 脚本）
coderrdd init . --roles pm,cto,dev --yes       # 只装部分角色（engine 必装）
```

register 的行为与约定：

- **改源码即时生效**：全局命令始终执行本仓 `dist/`，`npm run build` 后所有目标项目即用新版
- **升级**：源仓 `git pull && npm run build` → 目标项目里 `coderrdd update .`
- **移除全局命令**：仓根 `npm run unregister`
- **源仓移动/重命名后链接失效**：回仓根重新 `npm run register`
- 与 `npm i -g coderrdd` 占用同一命令槽位，后装者覆盖
- PowerShell 若提示"无法加载脚本"：改用 `coderrdd.cmd` 或执行 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

### 方式二：npm 安装（规划中）

安装器已按 npm 包标准组织（`bin`/`files` 字段完备，`npm pack` 体积约 200 kB），待发布后即可：

```bash
npm i -g coderrdd     # 或 npx coderrdd init .
```

### 备选：直接调用（不注册全局命令）

在 codeRDD 仓库根执行 `npm install && npm run build` 后：

```bash
node /path/to/codeRDD/bin/coderrdd.js init .
```

### 安装布局（唯一真实源 + 链接）

```
<target>/
├── .rdd/skills/rdd-<role>/          # 唯一真实源（8 个角色 skill 目录）
├── .agents/skills/rdd-<role>        # junction/symlink -> .rdd/skills/rdd-<role>
│                                    # OpenCode / ZCode / Codex / Warp 共享的中立发现路径
├── .opencode/                       # 仅 OpenCode 专属薄文件与配置
│   ├── agent/rdd-explore.md
│   └── package.json                 # 合并（备份后追加，不覆盖）
├── .claude/skills/rdd-<role>        # junction/symlink（Claude Code 不读 .agents/）
│   └── agents/rdd-explore.md
├── .zcode/agents/rdd-explore.md     # ZCode 子代理（选 zcode 时写入）
└── opencode.json                    # 合并（备份后追加，不覆盖）
```

ZCode 的 skill 发现同样走 `.agents/skills/`（与 OpenCode 共享，无需单独链接）；`--tools zcode` 只负责安装 `.zcode/agents/rdd-explore.md` 子代理。

Windows 下链接为 junction（无需管理员权限），macOS/Linux 为相对 symlink。`.rdd/` 下的 `changes/`、`handoff/` 等运行时数据由脚本自行创建，init 不会触碰；其中 `.rdd/exploration/` 为探索缓存运行时数据：`hot.json`（热区，新探索结果先落此，保留 7 天 / 容量 50 条，超期由 sweep 保底转正）+ `index.json`（持久层）+ `artifacts/`（配对产物）+ `search-config.json`（检索调参，可省，全字段有默认值）+ `vectors.json`（向量 sidecar，gitignore 的派生数据，可随时用 `explore-store.cmd -Type embed-backfill` 重建）。旧版安装过 OpenCode MCP 工具 `.opencode/tools/rdd_explore.ts` 的项目，该工具已废弃删除（与现行协议断裂且无人使用）：`coderrdd uninstall` 会按安装清单清理，或手动删除该文件。

### 冲突合并规则

目标项目已有配置时，**合并而非覆盖**：

| 目标文件 | 策略 |
|---------|------|
| `.opencode/package.json` | `dependencies` 取并集，已存在的依赖保留目标版本 |
| `opencode.json` | `instructions` 追加 `docs/code-quality.md`（已存在则跳过），其他字段不动 |
| `docs/code-quality.md` | 已存在则跳过（用户可能已定制） |
| `.rdd/skills/` 与薄文件 | 内容相同跳过；内容不同且未 `--force` 则跳过并警告 |

### 更新与卸载

```bash
coderrdd update .     # 按清单（.rdd/install.json）非交互更新受管理文件
coderrdd uninstall .  # 删链接/薄文件/角色目录，还原合并配置；保留 .rdd 运行时数据
```

### init 参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `[target]` | `.` | 目标项目根 |
| `--tools` | 交互选择 | 逗号分隔：`opencode,claude`；已检测到的客户端会预选 |
| `--roles` | 全部 | 逗号分隔：`engine,pm,cto,ux,dev,qa,eval,pse`（engine 必装） |
| `--force` | — | 覆盖内容不同的受管理文件 |
| `--yes` | — | 跳过交互，使用默认值 |

### 运行时依赖

- **Node.js 18+**（仅安装器需要）
- **git**（rdd-engine 用 `git rev-parse` 定位仓库根）

### 旧版安装脚本（deprecated）

`install.ps1` / `install.cmd` / `install.sh` 为旧版安装方式，安装布局与当前 CLI 不一致（角色目录平铺在项目根、仅适配 OpenCode），**不再维护**，请改用 `coderrdd init`。旧脚本安装过的项目可用 `install.ps1 -Target . -Uninstall` 清理后重新 init。

### 引擎 CLI 独立安装（rdd-engine.tgz，免克隆 codeRDD）

只需要 rdd-engine 命令行工具（角色技能已由其他渠道安装，或只想在任意项目里直接用流转 / 任务树 / 探索缓存 CLI）时，走独立分发通道：GitHub Release 提供固定名 `rdd-engine.tgz` 与配套安装器，**用户侧零 node/npm 依赖**。

**前置**：Windows 10 1803+（自带 `tar.exe`）、PowerShell 5.1+、git（引擎数据落点 `.rdd/changes|tree-runs|labs` 由 git 仓库根推导，非 git 项目不可用——继承现状）。

```powershell
# 1) 从 GitHub Release 下载 rdd-engine.tgz 与 scripts/install-rdd-engine.ps1
# 2) 安装到用户级引擎落点（~\.rdd\engine\<版本>\ + current junction + manifest.json 账本）
powershell -ExecutionPolicy Bypass -File install-rdd-engine.ps1 -Tarball .\rdd-engine.tgz
# 3) 自检（安装器末尾会自动执行一次；也可手动验证）
& "$HOME\.rdd\engine\current\scripts\rdd-flow.cmd" -Command version
```

安装后，技能 / 文档中的 `$rdd` 三级定位链 snippet 在任意项目自动命中引擎（`RDD_ENGINE_HOME` 覆盖 → 项目内 `rdd-engine` → `~\.rdd\engine\current`），无需手工配置路径；链序 / 判据 / 失败语义的协议单源见 `rdd-engine/references/engine-location.md`（随 tarball 与脚本同版本分发）。

- **升级**：对新版本 tarball 重跑安装器（`current` junction 原子翻转，多版本目录共存）
- **回滚**：对旧版本 tarball 重跑安装器
- **卸载**：删除 `~\.rdd\engine\`（含 `current` junction 与 `manifest.json` 账本）
- **PATH shim**：`-AddToPath` 开关 opt-in 把 `current\scripts` 加入用户 PATH，仅为人类终端便利——PATH 变更不影响运行中的会话，技能定位始终走文件系统定位链（确定性）
- **junction 失败的降级**（OneDrive 重定向等特殊 profile）：安装器会打印 `setx RDD_ENGINE_HOME "<版本目录>"` 指引，定位链候选① 即命中
- **适用边界**：`start-role` 的 Plus 后端仅定制环境生效（标准 DSH 环境自动降级 CLI 后端，交接主载体是 handoff/start 输出）；`sync-ux-subagents` 为 opencode 流专用（标准 DSH 惰性）
- **构建（维护者）**：仓根 `node scripts/build-engine-package.mjs` 产出 `dist/engine/rdd-engine.tgz`（固定名）+ `dist/engine/rdd-engine-<版本>.tgz`（带版本名归档）双产物；`--check` 为 CI 校验模式（含旧定位 snippet 残留零容忍检查）

### 角色体系用户级安装（rdd-skills.tgz）

把 8 个 RDD 角色技能 + 7 组 DSH presets 装到**用户级**，装一次后该用户的所有 DSH 项目可用，无需克隆 codeRDD。与一体化安装的关系：本节是组件级高级通道（只装技能体系）；普通用户走上方**一体化安装**主入口，不要重复执行本节。

```powershell
Invoke-WebRequest https://github.com/YaphetHayate/codeRDD/releases/latest/download/rdd-skills.tgz -OutFile .\rdd-skills.tgz
powershell -ExecutionPolicy Bypass -File scripts\install-rdd-skills.ps1 -Tarball .\rdd-skills.tgz
```

- **落点与生效**：skills → `$DSH_HOME\skills\rdd-*`（DSH user-dsh 发现层，watcher 热失效）；presets → `$DSH_HOME\.agent-presets\rdd-*`（user 信任层，发现每次调用重读）——**安装后无需重启 DSH**
- **项目级优先**：项目 `.agents\skills\` 下的同名技能自动覆盖用户级同名技能（DSH 分层发现机制原生提供，零配置）；`coderrdd init` 装出的项目布局与用户级安装并存不冲突
- **装后自检**：① 引擎三级定位链探测（miss 时 WARN 并输出安装指引，不阻断）；② rdd-explore 插件缺失 WARN（rdd-* presets 的探索委派依赖该插件，未装则挂载 broken）——推荐先装引擎与插件（或直接走一体化安装）
- **升级 / 降级**：对新（旧）版本 tarball 重跑安装器；分发前清落点 `rdd-*` 再拷，升级不留旧文件残留
- **卸载**：`install-rdd-skills.ps1 -Remove`——删两落点 `rdd-*` 与 `~\.rdd\skills\manifest.json` 版本账本；项目内 `.rdd/` 数据零触碰
- **包内结构**：`skills/`（8 技能；`rdd-engine` 仅 SKILL.md——协议文档经引擎三级定位链解析到引擎侧，与脚本同版本，不随包重复）+ `presets/`（7 组生成物），子树边界 = 安装器分发边界；v1 coderrdd 项目布局（`.rdd/skills/rdd-engine`）经定位链候选② 命中，与用户级安装互不影响
- **构建（维护者）**：仓根 `node scripts/build-skills-package.mjs` 产出 `dist/skills/rdd-skills.tgz` 双产物（先自动再生成 presets 保证新鲜；junction 技能源 fail-loud；`--check` 为 CI 模式）

### 一体化发布（维护者）

```powershell
node scripts\build-release.mjs            # 串联三组件构建 → dist/release/（6 tarball + SHA256SUMS + release-notes 模板）
node scripts\build-release.mjs --check    # CI：委托三组件 --check + SHA256SUMS 一致性复核
gh release create vX.Y.Z dist/release/*.tgz dist/release/SHA256SUMS dist/release/release-notes.md --notes-file dist/release/release-notes.md
```

release tag 统一 `vX.Y.Z`（仓库主版本，起步 v1.0.0，`--tag` 覆盖）；三 tarball 内部版本各自独立线（notes 模板携带组件版本对照表）。发布动作手动执行（CI 自动化留作演进）。

---

## 使用方式

角色通过 skills 激活（安装后位于各客户端的 skills 目录，如 `.opencode/skills/rdd-pm/`，实际内容在 `.rdd/skills/` 唯一真实源）。每个角色在自己的会话里工作；切换角色时**开新会话**以保证上下文纯净。

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
当前角色完成产物归档 → $rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command next 推荐下游 → 用户确认
  → /new（Ctrl+X N）开新会话（清理上下文）
  → 输入 /rdd-<下游角色> → 自动加载角色 SKILL + 最新交接包 → 干净进入
```

> 角色切换必须开新会话：opencode 的 agent 无法在同会话内真正隔离上下文，"同会话宣布边界"无法阻止上游对话污染下游。详见 `rdd-engine/references/transition-guide.md`。

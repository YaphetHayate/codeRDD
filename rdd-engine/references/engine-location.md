# 引擎定位链协议（engine-location）

> **定位**：rdd-engine CLI 定位方式的协议单源。所有角色技能 / dsh preset / 文档中的 `$rdd` 定义块必须逐字嵌入本文「规范 snippet」，不得自行改写。
> **同版本分发**：本文位于 `references/`，随引擎 tarball 与脚本同版本打包分发——协议文档永远与脚本配套（安装侧看 tarball 内副本，开发侧看本文件）。
> **维护规则**：链序 / 判据 / 失败语义任何变更只改本文 + 规范 snippet，再由各技能机械同步（旧 snippet 残留检查见 `scripts/build-engine-package.mjs --check`）。

## 三级定位链

调用 rdd-engine CLI 前，按以下顺序解析引擎根（`$rdd`）：

| 级 | 候选 | 说明 |
|----|------|------|
| ① | `$env:RDD_ENGINE_HOME` | 环境显式覆盖，最高优先级。junction 失败等特殊 profile 场景可直指具体版本目录（如 `~\.rdd\engine\1.0.0`） |
| ② | 项目内查找 | `git rev-parse --show-toplevel` 后递归 depth-3 找名为 `rdd-engine` 的目录（codeRDD 开发流仓根布局 / v1 coderrdd 项目安装布局 `.rdd/skills/rdd-engine` 均在 depth 3 内命中） |
| ③ | `~\.rdd\engine\current` | 用户级独立安装默认落点；`current` 是指向具体版本目录的 junction（见「用户级安装布局」） |

**判据**：三个候选统一以 `scripts\rdd-flow.cmd` 存在性判定有效。目录名不足以采信——防止无关同名目录误命中，也保证三候选之间无语义分叉。

**设计依据**：codeRDD dogfood 版本（仓内源）与 v1 coderrdd 项目安装版本必须胜过用户级安装（向后兼容硬约束）；与 dsh-rdd-explore 插件的 engineRoot 哲学同构（覆盖 → 项目 → 兜底），生态内一种心智模型。

## 规范 snippet

**单行嵌入版**——技能 / preset / 文档逐字复制此行，置于命令调用之前：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }
```

等价**多行阅读版**（仅作理解用，嵌入一律用上面的单行版）：

```powershell
$rdd = $null                              # 命中后为引擎根目录
$t = $null
try { $t = git rev-parse --show-toplevel } catch { }   # 非 git / 无 git 时不炸（候选②跳过）
foreach ($c in @(
    $env:RDD_ENGINE_HOME                  # ① 环境覆盖
    if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }   # ② 项目内
    "$HOME\.rdd\engine\current"           # ③ 用户级默认
)) {
    if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break }   # 统一判据，首个命中即用
}
if (-not $rdd) { throw "rdd-engine 未定位（……见单行版全文……）" }             # fail-loud
```

> snippet 刻意零 `|` 管道字符：嵌入 markdown 表格行时不破坏表格列。兼容 Windows PowerShell 5.1 / pwsh 7+ 与受限语言模式（ConstrainedLanguage）。

## 失败语义（fail-loud）

三级候选全 miss 时，snippet 以 `throw` 中止并输出可操作指引（安装通道 + 本协议文档路径），**绝不静默返回空值**——空值会把排障成本转嫁给后续每一条 `& "$rdd\scripts\..."` 调用。看到该错误时按序排查：

1. **已在 codeRDD 仓内 / 已 `coderdd init` 的项目**：确认在 git 仓库内运行（引擎**定位**候选② 依赖 git toplevel 搜索 `rdd-engine`；数据落点已不依赖 git，见「项目根定位链」）；
2. **独立安装**：从 GitHub Release（codeRDD 仓库）下载 `rdd-engine.tgz` 与 `scripts/install-rdd-engine.ps1`，运行安装器落到 `~\.rdd\engine\`（详见 codeRDD README「引擎 CLI 独立安装」）；
3. **junction 不可用的特殊 profile**（OneDrive 重定向 / 漫游等）：`setx RDD_ENGINE_HOME "<具体版本目录>"`（如 `C:\Users\<u>\.rdd\engine\1.0.0`），候选① 即命中；
4. **版本诊断**：命中后可用 `& "$rdd\scripts\rdd-flow.cmd" -Command version` 输出 `version` + `engineRoot` 自检。

## 用户级安装布局

```
~\.rdd\engine\
├── <version>\            # 各版本目录共存（如 1.0.0\），内容 = tarball 解包（package.json + scripts\ + references\）
├── current               # junction → 当前版本目录（升级 = 翻转 junction，原子、免管理员）
└── manifest.json         # 版本账本：current 指针 + 已装版本清单 + 安装历史（供一体化 release 编排消费）
```

- 安装器：codeRDD 仓 `scripts/install-rdd-engine.ps1`（`-Tarball` 指定 tarball，`-AddToPath` 默认关闭）。
- 升级：对新版本 tarball 重跑安装器 → 新版本目录落位 → `current` 翻转 → `manifest.json` 记账；回滚 = 对旧版本 tarball 重跑安装器。
- 卸载：删除 `~\.rdd\engine\`（含 `current` junction 与 `manifest.json`）。
- PATH shim（`-AddToPath`）仅为人类终端便利，opt-in：PATH 变更对已运行会话不生效，技能定位一律走文件系统定位链（确定性）。

## 项目根定位链（repoRoot / 数据落点）

> **定位**：rdd-engine 数据面（`.rdd/changes|goal-trees|labs|exploration`）的项目根解析协议单源。与上文「三级定位链」正交：那条链回答"引擎在哪"，本链回答"数据落在哪"。

数据面脚本（explore / explore-store / goal-tree / goal-tree-leaf / delivery-bridge / rdd-flow / start-role / sync-ux-subagents 共 8 个）统一以 `Resolve-RepoRoot` 定位项目根，链序固定：

| 级 | 候选 | 说明 |
|----|------|------|
| ① | `$env:RDD_PROJECT_ROOT` | 显式覆盖，最高优先级；指向不存在的目录 → **fail-loud**（防笔误静默漂移）。定位同 `RDD_ENGINE_HOME` 哲学：人工排障 / 启动器注入的逃生门，**安装器永不自动写入**——用户级持久环境变量是全局单值，会把其他项目的解析整体劫持到错误根上 |
| ② | `git rev-parse --show-toplevel` | git 可用且在仓内 → 最准：worktree / submodule / `GIT_DIR` 语义全部继承 |
| ③ | 最近 `.git` 祖先 | ② 的纯文件系统孪生：git 二进制缺失、或 dubious-ownership 拒绝时兜底；`.git` 为文件（worktree/submodule 形态）同样命中 |
| ④ | 最近 `.rdd/install.json` 祖先 | 非 git 项目的锚点：`coderdd init` 写下的安装清单即"此目录为 RDD 项目根"的声明；从子目录运行时自动回到安装根 |
| ⑤ | 回退 cwd | 最后兜底——与 dsh 插件 `findRepoRoot` 同规则（生态一种心智模型；插件实现为其 ③+⑤ 子集） |

**链序约束**：②③ 在前，保证所有现存 git 项目的根解析**逐字节不变**（回归锚点，含"init 装进大仓子目录、数据落外层根"的历史形态——不迁移）；④⑤ 只救援 git 说"不是仓库"的树，那里此前是直接报错，不存在回归面。

**维护规则**：`Resolve-RepoRoot` 为冻结镜像（与 hot-zone 常量同款约定），8 个脚本逐字复制；`tests/test-repo-root-fallback.ps1` 校验镜像一致性（全等 + 每脚本 `git rev-parse` 恰好出现一次）。链序 / 判据 / 失败语义任何变更只改本文 + 函数模板，再机械同步。

## 向后兼容声明

- **codeRDD 开发流**：仓内 `rdd-engine/` 由候选② 命中，开发形态 = 分发形态（原地 `npm pack` 成包），零行为变化。
- **v1 coderrdd 项目安装布局**：`.rdd/skills/rdd-engine` 距 git toplevel 恰为 depth 3，由候选② 命中，v1 装法零影响（独立安装通道与其并存，互不改动）。
- **旧定位 snippet**（`Get-ChildItem -Filter 'rdd-engine' | Select-Object -First 1`）已被本文规范 snippet 取代：链序、判据（`scripts\rdd-flow.cmd` 存在性）与 fail-loud 语义均以本文为准；旧 snippet 在源码中残留 = 构建检查失败。

## 边界与适用范围

- **仅 Windows**（本期验收）：`.cmd` 包装器 + junction；pwsh 跨平台预留后续评估。
- **git 可选**：引擎数据落点（`.rdd/changes|goal-trees|labs|exploration`）按「项目根定位链」解析——git 仓内走 `git rev-parse`（与历史行为逐字节一致）；无 git / 非 git 项目依次回退 `.git` 祖先 → `.rdd/install.json` 祖先 → cwd，CLI 全量可用；`RDD_PROJECT_ROOT` 可显式覆盖（安装器不代写）。
- **start-role**：Plus 后端（`RDD_RUNTIME=app`）仅定制环境生效；标准 DSH 环境无此变量，脚本内建自动降级 CLI 后端，交接主载体是 handoff/start 输出——随包分发，零改动。
- **sync-ux-subagents**：opencode 流专用；标准 DSH 环境惰性（不调用即无影响）——随包分发，零改动。

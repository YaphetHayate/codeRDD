# @coderrdd/dsh-rdd-explore

独立的 **DSH Profile Bundle**：把 rdd-engine 的探索缓存做成**缓存优先的模型工具** `rdd_explore`。查询项目 `.rdd/exploration` 索引，命中返回按相关性精排的 candidates；未命中（或 `force_dispatch: true`）经 `ctx.subagents` service 派遣 worker 子代理探索代码并注册产物。装一次（一个 profile），该 profile 打开的**任何项目**都能用——不要求项目里有 rdd-engine。

在标准/官方 DSH 上即可安装，无需定制构建、无需克隆 codeRDD。与裸 `subagent` 工具的关系：本插件是 subagent 能力的**另一个 Consumer**（service 层直调）；装配它之后可以让探索委派全部走缓存，而不是 prompt 约定。

## 安装（标准 DSH，一条命令）

前置：标准 DSH 已可运行（`dsh` 与 `pnpm` 在 PATH 上）。

```powershell
# 方式 A：安装脚本（推荐）——自动解析 GitHub Release latest 固定名产物并装入 profile
powershell -ExecutionPolicy Bypass -Command `
  "Invoke-RestMethod https://raw.githubusercontent.com/YaphetHayate/codeRDD/master/scripts/install-dsh-plugin.ps1 -OutFile $env:TEMP\install-dsh-plugin.ps1; & $env:TEMP\install-dsh-plugin.ps1"

# 方式 B：手动两步（等价）
Invoke-WebRequest https://github.com/YaphetHayate/codeRDD/releases/latest/download/dsh-rdd-explore.tgz -OutFile .\dsh-rdd-explore.tgz
dsh plugin --profile web add .\dsh-rdd-explore.tgz
```

- 默认装入 `web` profile（`-Profile <name>` 换目标；profile 不存在会自动初始化）。
- 安装后**重启该 profile**（重开 `dsh web` / 新会话）即可在任意项目里调用 `rdd_explore`。
- 升级 = 对新版本 tarball 重跑安装；卸载 = `dsh plugin --profile web remove @coderrdd/dsh-rdd-explore`。
- 已发布的历史版本经 `releases/download/<tag>/dsh-rdd-explore.tgz` 始终可达。
- tarball 预构建了 `lib/`（无 prepare / allowBuilds 摩擦）；6 个 `@deepseek-ai/*` 依赖声明为 peerDependencies（规格 `*`），由 profile 的 hoisted linker + `$DSH_HOME/profiles/node_modules` healed fallback 解析——与安装侧共享同一个 cordis 实例。

> 本插件只是 RDD 全家桶（角色技能 / 流程引擎 / 探索缓存）中的一件。想一次装齐三组件，用 codeRDD 仓库的一体化安装器 `install-rdd.ps1`（见 codeRDD README「一体化安装」）。

## 装载形态与最小权限

本包声明 `dsh.bundle`（`cordis.patch.yml`），经 `dsh plugin --profile <name> add` 装入后作为 profile 的一个 patch 层插入插件行：

```yaml
- insert:
    - id: rdd-explore
      name: '@coderrdd/dsh-rdd-explore'
      config:
        provider: spawn
        registerMode: plugin
        toolFilter:
          allow: [read, read_image, glob, grep]
```

`toolFilter.allow` 四读工具是刻意收紧的 worker 最小权限（`registerMode: plugin` 下落盘与注册由插件可信代码完成，worker 无需写工具）。**无论经哪条路径装载（bundle patch / 手写 profile patch / preset 派遣），都请携带同样的 `toolFilter.allow`**——用户 profile patch 可按 id `rdd-explore` 覆盖整行配置。

注意：Web profile 中工具行属于 agent preset 层——preset 侧的挂载见 codeRDD `dsh/presets/rdd-*/`；本 bundle patch 插入的是宿主层工具行，两种形态语义一致。

## engine 协议文本如何解析（六级候选链）

worker 派遣 prompt 需要 `references/exploration-guide.md`。解析链（首个命中即用，判据统一为该文件存在）：

| 级 | 候选 | 说明 |
|----|------|------|
| ① | `engineRoot` 配置 | 显式覆盖，最高优先级 |
| ② | `<repoRoot>/.rdd/skills/rdd-engine` | v1 coderrdd 项目安装布局 |
| ③ | `<repoRoot>/.agents/skills/rdd-engine` | 项目级技能布局 |
| ④ | `<repoRoot>/rdd-engine` | codeRDD 开发流布局 |
| ⑤ | **包内 `assets/rdd-engine`（vendored）** | 兜底：任意项目开箱即用，无需安装 rdd-engine |
| ⑥ | `~/.rdd/engine/current` | 用户级引擎独立安装（`install-rdd-engine.ps1` 落点） |

rdd 项目零行为变化（②③④ 仍胜出）；标准环境靠 ⑤ 兜底。vendored 副本由 codeRDD 的构建脚本从 `rdd-engine/references/exploration-guide.md` 同步并 CI 校验（`node scripts/build-dsh-plugin.mjs --check`）。全 miss 即 fail-loud（该错误只会在安装损坏时出现，重装即愈）。

## registerMode 选择

- **`plugin`（默认，推荐）**：worker 是纯研究者（四读工具），探索结果经结构化输出返回，由插件落盘并注册。不依赖 shell，与任意会话沙箱模式正交，任何项目可用。
- `worker`：worker 自调 engine CLI 注册（需项目内或用户级 rdd-engine——靠候选 ⑥；且 win32 需 PowerShell 5.1、POSIX 需 pwsh 7+）。仅当你要复用 engine 侧注册钩子（如同步 embedding）时才考虑。

## 缓存数据落点

- 数据留在项目内：`.rdd/exploration/`（hot.json / index.json / search-config.json / vectors.json / artifacts/），插件零初始化（读宽容 MISS、写 mkdir recursive 惰性自举），格式与 rdd-engine CLI 冻结契约互通（Claude Code / OpenCode / ZCode 注册的产物，dsh 会话直接命中，反之亦然）。
- `repoRoot` 从会话 cwd 向上找 `.git`；**非 git 项目回退会话 cwd 本身**（缓存就落在该目录下）。
- 热区常量与引擎冻结表对齐：保留 **7 天 / 容量 50 条**（`HOT_RETENTION_DAYS` / `HOT_CAPACITY`，镜像 `explore-store.ps1`）。

## 文件

| 文件 | 职责 |
|---|---|
| `src/cache.ts` | 双层索引读写（hot.json/index.json）、SHA-256 时效校验、sweep/转正原语、注册入热区、合并读、`maintainCache` 周期维护（先清后转）、复合入口模块级锁、产物落盘（`slugifyKey`/`writeArtifacts`）、检索精度管线（config 读取 / recallers 协议 / RRF 融合 / Top-K 截断）与向量 sidecar 读写 |
| `src/recallers/lexical.ts` | 词法召回器：F3 分词 + BM25 评分（F4） |
| `src/recallers/vector.ts` | 向量召回器：F6 有效性过滤 + embedding API + 余弦门限 |
| `src/dispatch.ts` | worker 派遣 prompt 构造（内嵌 exploration-guide 协议） |
| `src/index.ts` | 插件主体：`name`/`inject`/`Config`/`apply` + `defineTool`（两分支调用协议）+ `resolveEngineRoot` 六级候选链 + 会话权限守卫 + 周期维护装配（`setInterval` + `ctx.effect` + `unref`，repoRoot 首次调用 pin 冻结） |
| `cordis.patch.yml` | bundle patch 层：insert `rdd-explore` 插件行（含 toolFilter.allow 最小权限基线） |
| `assets/rdd-engine/references/exploration-guide.md` | vendored 协议文本（构建时从 rdd-engine 同步，git 追踪可审计；候选 ⑤ 数据源） |
| `tests/cache-cli.mjs` | 无 key 调试 CLI（select 合并读 / search 精度检索 / register 入热区 / persist 转正），兼跨客户端互操作检查工具 |
| `tests/maintenance.mjs` | 周期维护回归：先清后转 / stale 不转正 / 7 天/50 条阈值 / 幂等 / 空区无副作用 / 并发互斥（注册在维护期间排队不丢）；`RDD_ENGINE_ROOT` 可发现时做 PS/TS 阈值常量对照 |
| `tests/search-ranking.mjs` | 检索精度回归：冻结公式 F1–F8 逐项断言 + PS/TS 双侧一致性（发现 `rdd-engine` 经 `RDD_ENGINE_ROOT` 时自动启用） |
| `tests/engine-root.mjs` | engineRoot 候选链回归：①配置覆盖 ②③④项目布局 ⑤包内 vendored 兜底的次序与判据 |
| `tests/policy-smoke.mjs` | 写白名单判定与 slug 派生的纯函数烟测 |

## 索引格式契约（冻结，跨客户端共享）

`explore.ps1` / `explore-store.ps1` 与本插件写同一份 `.rdd/exploration/` 双层缓存。改格式必须两侧同步：

- **双层结构**：注册一律落**热区** `hot.json` = `{ "entries": HotEntry[] }`（compact JSON，UTF-8 无 BOM）；持久层 `index.json` = `{ "entries": ExplorationEntry[] }`。HotEntry = index entry + `registeredAt`（ISO-8601 UTC），转正时剥除
- **热区策略常量**（`HOT_RETENTION_DAYS = 7` / `HOT_CAPACITY = 50`，`src/cache.ts` 与 explore-store.ps1 顶部常量互为镜像，冻结表为真相源）：每次 register/persist 触发 sweep——超 7 天未转正或容量超 50 的热区条目**按原样**自动落入 index.json（保底不丢）
- **周期维护**（仅本插件有定时器，engine CLI 保持调用驱动）：`maintainCache` = 一次双区新鲜度清理（stale 热条目直接丢弃不转正）+ 一次 sweep 转正，先清后转；五个复合入口（register / persist / sweep / mergedFresh / maintainCache）经 `cache.ts` 模块级锁串行；维护失败仅告警，下周期幂等重试
- **转正原语**：先写 index（按 key/产物去重替换）后清 hot，幂等；中断窗口靠"幂等 + 检索抑制"自愈
- **合并读**：热区排前（registeredAt 倒序，origin=hot），同 key/同产物双 zone 并存时热区胜出；stale 条目从所在 zone 驱逐（热区 stale 直接丢弃，不转正）
- entry = `{ key, tags: string[], brief, path, files: Record<path, "sha256:<hex>"> }`（热区另含 `registeredAt`）
- **路径有两种形态**：engine CLI 在 Windows 写绝对 `/` 路径，本插件一律写仓库相对 `/` 路径；两侧读取按 `Resolve-RepoPath` 语义兼容两种形态
- 时效：任一 anchor 文件哈希不符/缺失，或 artifact 缺失 → stale（读取时清理出所在 zone）
- 配对约定：完整记录 `<slug>.md` + 摘要 `<slug>.summary.md`；`registerMode: 'plugin'` 下两者均由插件可信代码从 worker 结构化返回落盘

## 检索精度契约（冻结，2026-08-29 search-precision-ranking）

工具对 query 的相关性判定**在管线内部决定**（多路召回 → RRF 融合 → Top-K），调用方只剩两分支：`results` 非空 = 命中（直接消费），空 = 未命中（派遣探索）。candidates 每项带 `score`（融合分，6 位小数）与 `recalledBy`（召回路径名数组），`rankMeta` 报告各路召回器状态与 fused/returned 计数。

- **运行时文件**：`.rdd/exploration/search-config.json`（调参，损坏/非法值 fail-soft 回默认）；`.rdd/exploration/vectors.json`（向量 sidecar，gitignore 派生数据，主键 `(key, textHash, model)`）
- **冻结公式**：检索文本 `key + "\n" + tags.join(",") + "\n" + brief`（F1）、textHash（F2）、F3 分词、BM25（F4，k1=1.2 b=0.75）、embedding API 形状（F5）、向量有效性四条件（F6）、RRF `Σ weight/(rrfK+rank)`（F7）、总分序（F8）
- **默认值**：topK=5，recallDepth=20，rrfK=60；lexical enabled=true weight=1.0；vector enabled="auto" weight=1.0 minCosine=0.30 timeout=10s
- **PS/TS 一致性**是回归防线：改任一侧公式前先改冻结表（`rdd-engine/references/exploration-guide.md`）
- **范围注意**：本插件 registerEntry **不含** embedding 钩子；DSH 侧产物靠 lexical + `embed-backfill` 覆盖

## Config

| 字段 | 默认 | 说明 |
|---|---|---|
| `provider` | `spawn` | `ctx.subagents` provider 名 |
| `toolName` | `rdd_explore` | 模型可见工具名 |
| `engineRoot` | 六级候选链 | 见上文「engine 协议文本如何解析」 |
| `repoRoot` | 会话工作区向上最近 `.git` 祖先（非 git 回退 cwd） | `.rdd/` 属主；每次调用从会话 cwd 解析，不是宿主进程启动目录 |
| `registerMode` | `plugin` | 见上文「registerMode 选择」 |
| `persona` | — | per-child persona |
| `toolFilter` | bundle 默认四读工具 | worker 工具裁剪；worker 模式需另加 `write` + shell |
| `forbiddenSkills` | — | 硬拒绝经 `skill` 工具加载的名字列表（`tools/pre-execute` 拦截） |
| `writePrefixes` | — | 写白名单：`write`/`edit` 的 `file_path` 须命中其一前缀，否则硬拒绝 |
| `sessionReadOnly` | — | 首次工具调用前种 `sandbox/mode: read-only` 事件；注意 base 的 permission-presets 在会话创建时即钉住模式的组合中不生效 |
| `maintenanceIntervalMinutes` | `60` | 周期维护间隔（分钟，`0` 禁用定时器）：每 tick 自动跑双区新鲜度清理 + 热区 sweep 转正 |

## 开发（codeRDD 仓）

真相源在 codeRDD `dsh/dsh-rdd-explore/`（git 追踪）。构建管线：

```powershell
node scripts\build-dsh-plugin.mjs           # 同步 vendored guide → DSH workspace 集成 → pnpm --filter build → npm pack → dist/plugin/ 双产物
node scripts\build-dsh-plugin.mjs --check   # CI：vendored 同步 + manifest/文件清单一致性校验
node tests\engine-root.mjs                  # （先 build）候选链回归
```

- DSH checkout 的 `packages/local/rdd-explore` 是指向本目录的 junction（构建/联调镜像；dogfood 通道——`apps/cli` 的 `workspace:*` 依赖行不动）。junction 被 pnpm 拒收时构建脚本自动退化为目录同步。
- 测试在 build 后运行：`node tests/maintenance.mjs`、`node tests/search-ranking.mjs`、`node tests/policy-smoke.mjs`、`node tests/engine-root.mjs`。

## 已知限制

- `sessionReadOnly` 种入时机是"首次工具调用"：首个请求的 runtime-context 横幅仍显示部署默认模式。
- `isConcurrencySafe: false` 串行化调用（索引写竞争保守）。
- engine 的 Windows 绝对路径写入属上游兼容面（两侧已按直通语义互通）。
- 端到端演练记录（2026-09-03，开发机隔离落点）：外部 tarball 经 `dsh plugin add` 装入全新隔离 profile → `--dump-config` 确认 bundle 层组合（rdd-explore 行 + toolFilter 四读工具）→ 统一安装器 engine→plugin→skills 离线编排、`-Status` 一致性判定、`-Remove` 卸载、定位链 fail-loud 对照全部通过。公开发布前仍建议在真正干净的 Windows VM 上按上述清单复演一轮。

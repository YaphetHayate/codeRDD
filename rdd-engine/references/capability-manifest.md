# 引擎能力清单

> **定位**：rdd-engine 所有可用能力的权威清单。各 RDD 角色通过本文档发现和使用引擎能力。
> **维护规则**：引擎新增/变更能力时，只需更新本文件（+ `explore.ps1`），各角色自动发现，无需逐个更新 SKILL.md。

---

## 能力速查

| 能力 | 入口 | CLI 命令 | 触发场景 |
|------|-------|---------|---------|
| 缓存检索（精度排序） | `explore.cmd -Type search` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search -Query "..."` | 需要理解项目代码、定位模块/函数/依赖关系时（**第一步**） |
| 候选兼容面 | `explore.cmd -Type explore` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type explore -Query "..."` | 旧调用方兼容（dispatchPrompt 恒附）；新代码一律用 search |
| 产物注册（入热区） | `explore-store.cmd -Type register` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type register -Key "..." -Tags "..." -Path "..." -Brief "..." -Files "..."` | `rdd-explore` worker 探索完成后注册产物（向量配置齐备时同步 embedding） |
| 持久化转正 | `explore-store.cmd -Type persist` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "..."` | 将热区条目转正进持久层 |
| 向量补齐 | `explore-store.cmd -Type embed-backfill` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type embed-backfill [-PurgeOtherModels]` | 配置/更换 embedding 模型后，为存量条目补齐/重建 `.rdd/exploration/vectors.json` |
| 树形长程任务运行（管理面） | `tree-run.cmd` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\tree-run.cmd" -Command start -RunId <id> -Goal "..." -RefRoots "..."` | 长程任务（根因调查/批量审计等）需要多轮"派发→回写→再规划"循环时，Manager 会话创建并驱动树 |
| 树节点消费与回写（消费面） | `tree-leaf.cmd` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\tree-leaf.cmd" -Command next -RunId <id>` | tree-run 的子代理 worker 认领叶子节点并结构化回写结果 |

---

## 能力详解

### 缓存检索（search）— 多路召回 + RRF 融合 + Top-K 精度排序，返回位置

**这是引擎核心能力。任何角色需要理解项目代码时，第一步始终调用此能力。**

**核心机制：合并读双 zone → 精度排序管线 → 返回排序位置 → 调用方两分支消费**

1. 角色调用 `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search -Query "..."`
2. engine 合并读 `.rdd/exploration/hot.json`（热区）与 `.rdd/exploration/index.json`（持久层），对每条 entry 做 SHA-256 时效校验
   - 哈希不匹配 / 文件被删 → 自动驱逐 stale 条目（热区 stale 直接丢弃，不转正）
   - 同 key / 同产物双 zone 并存 → 热区胜出（持久层重复项抑制）
3. **精度排序管线**（冻结公式 F1–F8，详见 `exploration-guide.md`）：
   - 多路召回（`scripts/recallers/*.ps1`，可插拔）：词法 BM25（零配置常开）+ 向量余弦（`search-config.json` 配置齐备自动启用，含跨语语义匹配）
   - RRF 融合：`score(d) = Σ weight/(rrfK + rank)`，按召回路累计
   - Top-K 截断（默认 5）：总分序 score DESC → hot 优先 → registeredAt DESC → key 字典序
4. 返回 `{ results, rankMeta, dispatchPrompt? }`。results 每条含 `key` / `tags` / `brief` / `summaryPath` / `fullPath` / `origin` / `score` / `recalledBy`——**位置而非内容**，调用方按位置自取
5. **调用方两分支消费**：
   - `results` 非空 = **命中**（相关性已由管线判定）→ Read 首条（或最相关条）的 `summaryPath`；需深入细节再 Read `fullPath`
   - `results` 为空 = **未命中**（返回体附 dispatchPrompt）→ 用 `dispatchPrompt` 派遣 `rdd-explore` 子代理

**调用示例：**

```powershell
# 第一步：检索缓存（始终先调这一步）
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search -Query "分析认证模块的中间件链和 Token 刷新机制"

# results 非空 → 命中：Read data.results[0].summaryPath（score 最高者）
# results 为空 → 未命中：用 data.dispatchPrompt 派遣 rdd-explore（可写 worker）
```

> **相关性在管线内判定**（确定性公式，非 LLM 自判）：`rankMeta` 报告各召回路状态（ok/disabled/failed + qualified 计数），单路故障降级不阻塞检索。`tags` 同时是 LLM 阅读语言与词法召回语料。
>
> **硬约束**：禁止用内置只读 `explore` / `general` 子代理做代码探索——它们无法写产物、无法注册缓存，物理上无法完成协议。

### 产物注册（register，写面 explore-store）— worker 完成探索后调用

`rdd-explore` worker 探索完代码、写好摘要 + 完整记录后，调用此能力注册产物（**落热区**，注册即对下一次检索可见）：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type register `
  -Key "认证中间件链和 Token 刷新" `
  -Tags "认证,鉴权,登录,auth,jwt,token,中间件,middleware" `
  -Path ".rdd/exploration/artifacts/auth-middleware.md" `
  -Brief "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑" `
  -Files "src/auth/middleware.ts,src/auth/jwt.ts"
```

register 会校验 `{slug}.md` 与 `{slug}.summary.md` 配对存在、计算每个文件的 SHA-256、在**热区内**按 key/产物去重后追加（index 同 key 旧条目留待转正时去重替换收口）。向量配置齐备时同步 embedding 单条（输出 `embed.status` = skipped/reused/embedded/failed，失败仅告警不阻断注册）。

> 旧路径 `explore.cmd -Type register` 仍可用：薄转发到 explore-store，输出附 `deprecation` 提示。新代码一律直调 explore-store。

### 持久化转正（persist）— 热区条目转正进持久层

将热区条目按 key 转正进 `index.json`（去重替换、剥除 registeredAt），成功后从 `hot.json` 移除；key 不存在报 `HOT_KEY_NOT_FOUND`：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "认证中间件链和 Token 刷新"
```

转正后检索 origin 变为 `persistent`，不再依赖热区存活。**保底不丢**：热区保留 7 天 / 容量 50 条，超期或溢出的未转正条目由 sweep 在每次 register/persist 时按原样自动落入持久层——异步管线未运行/失败不丢任何已探索结果。

### 向量补齐（embed-backfill）— 存量条目的 embedding 重建入口

对合并池全部 fresh 条目按当前向量配置补齐 `.rdd/exploration/vectors.json`：textHash 一致的既有向量复用（不重复调 API），内容变更的重嵌，单条失败不阻断（`failed[]` 逐条报告）；`-PurgeOtherModels` 清掉非当前 model 的旧向量。配置不齐报 `EMBED_CONFIG_INCOMPLETE`（fail loud）。DSH 插件代注册的产物（无 register 钩子）靠此命令补齐向量。

**缓存特性：**
- 热区即时可见：worker 注册即落热区，下一次检索（含跨会话/跨角色）立即可见
- 保底不丢：sweep 自动转正超期/溢出的热区条目
- 精度排序：多路召回 + RRF 融合 + Top-K（冻结公式 F1–F8）；词法路零配置常开，向量路配置齐备自动启用，单路故障降级
- 全局共享：PM 探索过的结果，CTO/DEV/QA/UX 无需重新探索
- 自动失效：涉及文件变更后 SHA-256 不匹配，检索时自动驱逐 stale 条目（向量随 textHash 失效自动重嵌）
- 三层结构：索引条目（热区/持久层）→ summary（摘要，命中时读）→ full record（完整记录，按需读）
- 索引文件：`.rdd/exploration/hot.json` + `.rdd/exploration/index.json` + `search-config.json`（调参）+ `vectors.json`（向量 sidecar，gitignore），产物目录：`.rdd/exploration/artifacts/`

> 完整执行流程见 `rdd-engine/references/exploration-guide.md`

---

## 树形长程任务运行（tree-run / tree-leaf 双面）

长程任务的 Manager-Worker 树形循环引擎能力（沉淀自 `.rdd/labs/rca-poc/` 已验证模式）。**双接口分权**：管理面 `tree-run.cmd`（Manager 会话驱动树生长与生命周期：start / graft / prune / settle / conclude / round-start / round-end / status / resume）；消费面 `tree-leaf.cmd`（worker 子代理 next / claim / report / status，CLI 硬编码字段白名单，物理上无法篡改树结构）。

**核心机制**：状态文件为唯一权威（`.rdd/tree-runs/<run-id>/`，gitignore）；回写账本只追加、坏行隔离 `.corrupt`；树写前 `.bak` + 写后 read-back；每 run 一把 `.lock` 互斥所有写原语；引用范围 `-RefRoots` 机械校验 + 引擎归一；回调核心 schema 引擎强制，invalid 降级记账不破坏运行；三种终局（achieved / budget_exhausted / space_exhausted）均为正常终结并产出结案报告；轮日志起止两行制支持任意一轮中断后 `resume` 续跑，已回写节点永不重复消费。

```powershell
# Manager：创建并驱动一次运行
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }
& "$rdd\scripts\tree-run.cmd" -Command start -RunId my-rca-001 -Goal "排查这批告警的根因" -RefRoots ".rdd/labs/rca-poc/cases/l1-mock/mock-001" -CreatedBy DEV
& "$rdd\scripts\tree-run.cmd" -Command round-start -RunId my-rca-001
& "$rdd\scripts\tree-run.cmd" -Command graft -RunId my-rca-001 -Parent n1 -TasksFile <batch.json>   # [{title, task, note?}]

# Worker（子代理）：领节点 → 干活 → 结构化回写
& "$rdd\scripts\tree-leaf.cmd" -Command claim -RunId my-rca-001 -NodeId n2 -Worker w1-db
& "$rdd\scripts\tree-leaf.cmd" -Command report -RunId my-rca-001 -Worker w1-db -CallbackFile <callback.json>
```

> 完整协议（Manager 循环、worker 派发模板、workflow 扇出模板、恢复流程）见 `rdd-engine/references/tree-run-guide.md`。与 task.json 流转 / explore 链三重正交，互不影响。

---

## 流转命令（rdd-flow.ps1）

除代码探索外，engine 还提供阶段流转命令，用于角色切换和上下文交接：

| Command | CLI 命令 | 说明 |
|---------|---------|------|
| `next` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command next` | 汇总当前有哪些角色有待处理任务 |
| `start` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role <PM\|CTO\|UX\|DEV\|QA>` | 为指定角色生成启动 prompt + handoff packet |
| `handoff` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role <DEV>` | 为指定角色生成最小交接包 |
| `validate` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command validate -Role <DEV>` | 校验指定角色是否有可执行任务 |
| `version` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command version` | 输出引擎版本 + `engineRoot`（来自 `package.json`；无需 git 仓库，安装自检/诊断用） |

> 完整规则见 `rdd-engine/references/handoff-guide.md`

---

## 共享协议

所有 RDD 角色共享以下协议（定义在 `rdd-engine/references/` 下）：

| 协议 | 文件 | 说明 |
|------|------|------|
| 角色交接协议 | `transition-guide.md` | 上游完成产物后的 4 步交接流程、下游三入口识别、双场景（self-driven/app-driven）模式检测 |
| 驳回协议 | `rejection-protocol.md` | 角色间正式驳回上游文档的标准流程 |
| 交接包规则 | `handoff-guide.md` | 最小上下文交接的构建规则 |

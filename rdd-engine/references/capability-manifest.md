# 引擎能力清单

> **定位**：rdd-engine 所有可用能力的权威清单。各 RDD 角色通过本文档发现和使用引擎能力。
> **维护规则**：引擎新增/变更能力时，只需更新本文件（+ `explore.ps1`），各角色自动发现，无需逐个更新 SKILL.md。

---

## 能力速查

| 能力 | 入口 | CLI 命令 | 触发场景 |
|------|-------|---------|---------|
| 缓存检索（精度排序） | `explore.cmd -Type search` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search -Query "..."` | 需要理解项目代码、定位模块/函数/依赖关系时（**第一步**）；唯一读面，其他 `-Type` 报 `INVALID_TYPE` |
| 产物注册（入热区） | `explore-store.cmd -Type register` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type register -Key "..." -Tags "..." -Path "..." -Brief "..." -Files "..."` | `rdd-explore` worker 探索完成后注册产物（向量配置齐备时同步 embedding） |
| 持久化转正 | `explore-store.cmd -Type persist` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "..."` | 将热区条目转正进持久层 |
| 向量补齐 | `explore-store.cmd -Type embed-backfill` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type embed-backfill [-PurgeOtherModels]` | 配置/更换 embedding 模型后，为存量条目补齐/重建 `.rdd/exploration/vectors.json` |
| 树形长程任务运行（管理面） | `goal-tree.cmd` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\goal-tree.cmd" -Command start -RunId <id> -Goal "..." -RefRoots "..."` | 长程任务（根因调查/批量审计等）需要多轮"派发→回写→再规划"循环时，规划者 会话创建并驱动树 |
| 树节点消费与回写（消费面） | `goal-tree-leaf.cmd` | `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\goal-tree-leaf.cmd" -Command next -RunId <id>` | goal-tree 的子代理 worker 认领叶子节点并结构化回写结果 |
| 节点依赖管理 | `goal-tree.cmd -Command deps` | `$rdd = ...同上定位链...; & "$rdd\scripts\goal-tree.cmd" -Command deps -DepAction add -RunId <id> -NodeId <n> -On <m>` | 树内节点声明/解除依赖（DAG 机械校验 + 认领门禁 + 审计）；规划者 编排跨角色依赖场景 |
| 通用树角色派发 | `goal-tree.cmd -Command dispatch` | `$rdd = ...同上定位链...; & "$rdd\scripts\goal-tree.cmd" -Command dispatch -RunId <id> -NodeId <n> -Role <PM\|CTO\|UX\|DEV\|QA\|EVAL\|PSE\|AUDITOR> [-DryRun]` | 通用 run（模块/运维任务，无 task.json 归档）为 pending 节点拉角色会话——角色×任务×节点三绑定（任务取自节点单源注入 worker 指针，`start-role -GoalTreeWorker` 免归档模式）；前置门与 claim 同源；真实派发落 dispatch-log 审计、status dispatches 段透出；桥接 run 用 delivery-bridge dispatch |
| 交付编排桥接（规划者） | `delivery-bridge.cmd` | `$rdd = ...同上定位链...; & "$rdd\scripts\delivery-bridge.cmd" -Command promulgate -TaskJson <归档 task.json> [-ReviewMode subagent\|session] [-Shape wake\|legacy]` | PM 归档较重时启动 规划者 接管整批交付：颁布节点（任务×阶段）→ 调动角色会话 → settle 唯一流转通道 → 结案报告。`-ReviewMode` 落 `bridge.json review_mode`（有键 = 评审子代理新链：设计审查纯契约无节点，`design-review -Action submit\|status` 唯一裁定入口；缺键 = 存量链逐字节，审查走 `[设计审查·S<k>]` 节点 settle）。**树形状自引擎 1.2.0 起缺省 `wake`**（`bridge.json shape=wake`：每条需求一个 type=sub 容器 + 角色槽，返工波 redo/reset 不增树；`-Shape legacy` = 旧链头形状兼容路径；形状颁布时钉死，存量 run 不受影响）。协议见 `planner-guide.md`。**两条机械门**（planner-claim-guard）：`claim` 属 worker 侧动作，规划者会话代跑被硬拒 `PLANNER_CANNOT_CLAIM`（硬约束 16）；`reclaim` 的 dead-claim 存活判定在探针不可证实时过了 60min 也需 `-UserVerdict` 用户裁决原文（`RECLAIM_DEATH_UNPROVEN_NEEDS_VERDICT`） |
| 代码度量（客观指标） | `code-metrics.cmd -Command scan` | `$rdd = ...同上定位链...; & "$rdd\scripts\code-metrics.cmd" -Command scan [-Base <ref>] [-Files <清单>] [-MaxFunctionLines 50] [-MaxNestingDepth 5]` | QA 验证模式硬性项 #4/#5（函数行数/嵌套深度）确定性检查、DEV 自测前置拦截（本期 PowerShell） |
| tips 记录/碰撞/生命周期 | `tips.cmd -Command add` / `-Command list` / `-Command target` / `-Command collide` / `-Command pin` / `-Command unpin` / `-Command supersede` / `-Command migrate` | `$rdd = ...同上定位链...; & "$rdd\scripts\tips.cmd" -Command add -By <ROLE> [-Title -Problem -Avoidance \| -File <payload.json>]`；`& "$rdd\scripts\tips.cmd" -Command list [-Role <R>] [-All]`；`& "$rdd\scripts\tips.cmd" -Command target -Id <tip-id> -By <ROLE>`；`& "$rdd\scripts\tips.cmd" -Command collide -Id <tip-id> -By <ROLE> [-SawTip]`；`& "$rdd\scripts\tips.cmd" -Command pin\|unpin -Id <tip-id> -By <ROLE>`；`& "$rdd\scripts\tips.cmd" -Command supersede -Id <tip-id> -By <ROLE> [-Note <ascii>]`；`& "$rdd\scripts\tips.cmd" -Command migrate -By <ROLE> [-Pin "<id>,..."]` | 任意角色会话把可复用坑/陷阱/约定沉淀为结构化 tip（`.rdd/tips/entries/` 一条目一 JSON，git 跟踪）。**记录即归属，记录≠注入**（v2 碰撞驱动）：add 出生 latent 并返回 `candidates` 近重复候选（记录 agent 裁决：同根因改 `collide -Id`，不同才保留新条目）；独立碰撞 count≥2 或 `pin` 才入注入池，`supersede`（已固化进工具）terminal 退场；`target` 为已有条目增补本角色（幂等）；`list -Role` 输出供 start-role B2 定向注入消费（8 常青 + 2 试销席位）。中文内容走 `-File` 通道（inline 非 ASCII 机械硬拒） |

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

> 旧路径 `explore.cmd -Type register`（薄转发）与 `-Type explore`（候选兼容面）已删除（删除时仓内与各角色 SKILL 零调用方）：检索只保留 `-Type search`，注册直调 `explore-store.cmd -Type register`；残留调用报 `INVALID_TYPE`（fail-loud，不再静默空转）。

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

## 长程目标树运行（rdd-goal-tree / goal-tree 与 goal-tree-leaf 双面）

长程任务的 规划者-Worker 树形循环引擎能力——**rdd-goal（长程目标编排）能力族的树方法 rdd-goal-tree**（沉淀自早期调查流 PoC 实验验证过的模式）。**双接口分权**：管理面 `goal-tree.cmd`（规划者 会话驱动树生长与生命周期：start / graft / prune / settle / conclude / round-start / round-end / status / resume / budget——运行期预算只增扩展，`-UserVerdict` 人工审批硬门）；消费面 `goal-tree-leaf.cmd`（worker 子代理 next / claim / report / status，CLI 硬编码字段白名单，物理上无法篡改树结构）。

**核心机制**：状态文件为唯一权威（`.rdd/goal-trees/<run-id>/`，gitignore）；回写账本只追加、坏行隔离 `.corrupt`；树写前 `.bak` + 写后 read-back；每 run 一把 `.lock` 互斥所有写原语；引用范围 `-RefRoots` 机械校验 + 引擎归一；回调核心 schema 引擎强制，invalid 降级记账不破坏运行；三种终局（achieved / budget_exhausted / space_exhausted）均为正常终结并产出结案报告；轮日志起止两行制支持任意一轮中断后 `resume` 续跑，已回写节点永不重复消费。

> **命名注**：`rdd-goal` 指 RDD 层的长程目标编排能力（目标 → 多轮 → 账本 → 结案，跨会话文件持久化），与宿主 harness 的会话级 goal 工具（同会话自动续跑）无关——前者是编排引擎，后者是会话机制。

```powershell
# 规划者：创建并驱动一次运行
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }
& "$rdd\scripts\goal-tree.cmd" -Command start -RunId my-goal-001 -Goal "排查这批告警的根因" -RefRoots "docs" -CreatedBy DEV
& "$rdd\scripts\goal-tree.cmd" -Command round-start -RunId my-goal-001
& "$rdd\scripts\goal-tree.cmd" -Command graft -RunId my-goal-001 -Parent n1 -TasksFile <batch.json>   # [{title, task, note?}]

# Worker（子代理）：领节点 → 干活 → 结构化回写
& "$rdd\scripts\goal-tree-leaf.cmd" -Command claim -RunId my-goal-001 -NodeId n2 -Worker w1-db
& "$rdd\scripts\goal-tree-leaf.cmd" -Command report -RunId my-goal-001 -Worker w1-db -CallbackFile <callback.json>
```

> 完整协议（规划者 循环、worker 派发模板、workflow 扇出模板、恢复流程）见 `rdd-engine/references/goal-tree-guide.md`。与 task.json 流转 / explore 链三重正交，互不影响。

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
| 任务路由操作族 | `rdd-flow.cmd -Command <claim/init/add-task/set-route/add-design/reject/complete/reopen/deprecate/check/migrate>`（如 `-Command claim -Role DEV -TaskId <n>`） | 认领（claim：同角色冲突时用户裁决 `-Force` 抢占）、路由推进/驳回/闭环/重开/废弃、schema 校验（check）、旧 task.md 迁移（migrate）——协议单源 `references/task-routing.md`，逐命令一句话说明见 SKILL.md Command 表 |

> 完整规则见 `rdd-engine/references/handoff-guide.md`

---

## 代码度量（code-metrics.ps1）

将 QA 硬性项 #4（函数净行数）/ #5（嵌套深度）由 LLM 人工审查改为确定性工具执行；DEV 自测前置运行同一工具，在进入 QA 前拦截违规（设计归档：`2026-09-24-qa-metric-tooling`）。QA 与 DEV 双角色共用，口径单源。

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~/.rdd/engine/current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }
& "$rdd\scripts\code-metrics.cmd" -Command scan -Base HEAD
```

- **能力**：一趟完成变更范围判定（git diff + 未跟踪 .ps1；Base 版本与工作区**逐函数文本对比**判定「本次触及」，历史未触及函数只入备忘不判违规）→ 行数/嵌套度量 → 统一格式报告
- **口径**（三轮 QA 报告实战口径固化）：净代码行 = AST 函数体扣除注释与空行；嵌套深度 = if/for/foreach/while（含 else 分支参与链路）祖先链计数、顶层记第 1 层、违规为 >5 层（switch 不计，do 族归 while 族）；默认阈值 50 行 / 5 层（`docs/code-quality.md §1` 单源，参数可覆盖）
- **输出**：纯文本双区——违规区（`文件:行号 | 函数名 | 条款 #4/#5 | 现值 | HEAD 基线如 27->70 | 链路径如 if@L2836 -> if@L2874`）+ 备忘区；排序稳定（路径→起始行→条款），同一输入逐字节一致
- **退化**：无 git / Base 不可得时要求显式 `-Files`，报告标注「无基线」（全部函数视为本次触及）；AST 解析失败即报（兼作 .ps1 无 lint/build 配置时的 #1 语法兜底）
- **退出码**：`0=无违规 / 1=存在硬性违规 / 2=运行错误`
- 验收测试：`rdd-engine/tests/test-code-metrics.ps1`（48 断言，临时 git 仓库 + 固定基准样本 `tests/fixtures/code-metrics/`）

---

## tips 记录/碰撞/生命周期（tips.ps1）

项目级角色 tips 沉淀能力——任意角色会话一条命令把可复用的坑/陷阱/约定记录为结构化条目，与 task.json 需求流转完全解耦（独立入口镜像解耦语义；归档 `2026-10-06-role-tips-mechanism`；v2 生命周期 2026-10-09）。不读不写 task.json、不碰 exploration 区（复用的是**共享代码库** `scripts/lib/recall-shared.ps1`——registry/F7 fusion/config 装载，与 explore.ps1 同源单份；数据面独立：`.rdd/tips/search-config.json` + `.rdd/tips/vectors.json`，与探索区不共池）。

**核心语义：记录≠注入（碰撞驱动注入资格）**。新条目出生 `latent`（count=1），注入面只认证据——独立碰撞（count≥2 自动晋升 `active`）或显式 `pin`（稀有高价教训逃生阀）；一次性噪音自然沉淀在 latent 永不进提示词；`superseded`（教训已固化进工具）terminal 退场。碰撞的主要识别时机在**归档回顾**：当场认出同根因难、回顾对照全量易。

- **存储**：`.rdd/tips/entries/` 一条目一 JSON（schema `rdd-tip/2`，UTF-8 无 BOM，git 跟踪——人工知识随仓分发）；ID=`<UTC时间戳>-<角色>-<4hex>`，纯 ASCII 文件名字典序=时间序，免疫并行/跨克隆合并冲突；生命周期字段 `status/count/collidedBy[{role,at,sawTip}]` + 可选 `pinnedBy/pinnedAt/supersededBy/supersededAt/note`（legacy `rdd-tip/1` 兼容读=active/1，任何 v2 写触碰即整文件归一）；`deprecated` 为预留字段恒 false
- **add**：`-By <ROLE> [-Title -Problem -Avoidance | -File <payload.json>]`——**记录即归属**（2026-10-06 用户裁决）：无任何目标角色输入，新条目恒 `roles=[-By]`、出生 `latent`；信封携带 `candidates`（近重复 top-K：共享精度管线词法 BM25 零配置/向量 auto，适配器 key=id·tags=roles·brief=title+problem+avoidance；管线只出相对序，**同根因裁决归记录 agent**——candidates 非空读 top 判同根因改走 collide，否则保留新条目；任何管线失败降级空候选+stderr 警告，记录永不因去重失败而失败）；inline 与 -File 互斥（同给报 `DUAL_CHANNEL`）；inline 参数机械拒绝非 ASCII（`NON_ASCII_INLINE`），中文内容唯一正道 = `-File` UTF-8 payload `{title, problem, avoidance}`（建议暂存 `.rdd/tmp/`，未知键拒绝——含旧 `roles` 键）；角色大小写不敏感归一到白名单规范形
- **title 质量约定（2026-10-08）**：title 一句话必须同时含「坑——规避」（问题 + 解法，破折号衔接），写共性规律、不写个案细节——start-role B2 序号摘要行只取 title，缺规避半句的 title 对开工读者价值减半
- **collide（碰撞记账）**：`-Id <tip-id> -By <ROLE> [-SawTip]`——同坑独立再撞一次：count++、`collidedBy` 盖章 `{role, at, sawTip}`（`-SawTip` 标记本次碰撞的会话**曾注入过该条**——B2 指针行冻结了会话所见，未注入期碰撞=价值证明、注入后碰撞=注入无效/该固化进工具的信号，两分）；latent 于 count≥2 自动晋升 active；碰撞角色不必是条目成员（跨角色撞坑同样有效证据）；校验链同 target
- **pin / unpin / supersede（状态机）**：`pin`（幂等；superseded 不可 pin——terminal）置顶逃生阀；`unpin` 按证据重算（count≥2→active 否则 latent；非 pinned 报 `INVALID_STATE`）；`supersede`（terminal，`-Note <ascii>` 固化指针）后条目退出 list 默认视图与 candidates 语料
- **list**：`[-Role <R>] [-All]`——排序 **count 降序→新旧→id**（碰撞证据压过新近性；全员 count=1 时与 v1 新→旧序逐条一致——迁移前回归锚）；superseded 默认排除（`-All` 审计面）；不截断（席位策略归消费方——start-role B2 注入 = 8 常青 + 2 试销）；每条含 `title` + `path` + `status` + `count`；空库 `count=0` 非 error
- **target（有机扩散）**：`-Id <tip-id> -By <ROLE>`——当前角色把自己挂上已有条目；幂等（已含则成功回显不改文件）；重写经 `ConvertTo-StoredEntry` 整文件归一为 v2
- **migrate（一次性迁移）**：`-By <ROLE> [-Pin "<id>,..."]`——全库 legacy `rdd-tip/1` → v2：pin 名单→pinned、其余→latent；v2 条目跳过不动；两遍式（-Pin id 全库校验先行，打错字在任何写盘前 `MIGRATE_PIN_UNKNOWN` fail-loud）；幂等可重跑
- **校验 fail-loud**：必填缺失（`MISSING_TITLE/PROBLEM/AVOIDANCE/BY/ID`）、角色非法（`INVALID_ROLE`）、payload 非法（`PAYLOAD_INVALID`/`PAYLOAD_NOT_FOUND`）、状态错序（`INVALID_STATE`）→ 显式错误码、exit 1、不落盘；读取侧半损坏条目 `CORRUPT_ENTRY` exit 3 指名文件
- **退出码/信封**：0 成功 / 1 调用与校验错 / 2 环境错 / 3 数据损坏（对齐 rdd-flow 分层）；输出统一 `{success,data}` / `{success:false,error:{code,message}}` JSON 信封
- **角色白名单**：`PM/CTO/UX/DEV/QA/EVAL/PSE/PLANNER/AUDITOR`（对齐 start-role.ps1 `-Role` ValidateSet 单源，漂移为 QA 核对项）；`-By` 为记录/操作角色（9 角色之一）
- 验收测试：`rdd-engine/tests/test-tips.ps1`（97 断言：v1 语义全量保留 + S10 候选召回/legacy 兼容 + S11 collide 晋升与审计 + S12 pin/unpin/supersede + S13 target 归一 + S14 migrate 两遍式幂等；`RDD_PROJECT_ROOT` 指向 %TEMP% 一次性根完全隔离）

---

## 共享协议

所有 RDD 角色共享以下协议（定义在 `rdd-engine/references/` 下）：

| 协议 | 文件 | 说明 |
|------|------|------|
| 角色交接协议 | `transition-guide.md` | 上游完成产物后的 4 步交接流程、下游三入口识别、双场景（self-driven/app-driven）模式检测、planner-takeover 可选分支（单入口，评审子代理内生） |
| 驳回协议 | `rejection-protocol.md` | 角色间正式驳回上游文档的标准流程（发起方枚举 `AUDITOR-DELEGATED`/`AUDITOR`/`PLANNER`，评审方驳回双形态） |
| 交接包规则 | `handoff-guide.md` | 最小上下文交接的构建规则 |
| 评审子代理输入模板 | `review-input-template.md` | **协议产物**：评审子代理机械输入清单（需求四维 / 设计五查两节 + 禁令段 + 落点 + 常量表）——reviewer 枚举 / review_mode 值域 / TEMPLATE_REF 的**单源常量表**在此，消费端与测试同表对账 |
| 规划者 树维护协议 | `planner-guide.md` | 规划者（引擎编排形态，**树的维护者**）四段载荷：职责声明（三类树主体/动态生长循环）、树维护命令面板（通用树 + 交付桥接，核心派发命令三绑定）、可派发 worker 角色列表（会话型 + 调查卡片型）、禁令与提示（硬约束 1–16） |
| 规划者 场景细则 | `planner-scenarios.md` | planner-guide 的场景下沉层：交付编排生命周期、交付角色分工与裁定触点、长程规划（PlanFile）、交付回调四查、运行产物、需求审查门（ReviewFile 契约）、整体验收闭环、并行协作冲突治理细则、设计汇聚审查（双链契约态）、纯自动模式细则、DEV 质量扫描凭据、范围缺口派生、异常处置速查 |

> **枚举单源行**：`reviewer` 枚举 = `auditor-delegated`（子代理形态产出）| `auditor`（强形态独立会话产出）| `planner`（存量只读，不再产出）；`decider` 枚举 = `user` | `planner`（结算态）——单源常量表 `review-input-template.md` §5，引擎值域 `delivery-bridge.ps1` `$script:DesignReviewReviewers` 同步锁定（`test-review-input-template.ps1` 对账防漂移）。**部署判据**：AUDITOR 能力载体不再是 preset 部署探测——新链以 `promulgate -ReviewMode`（bridge.json `review_mode` 键）为准（缺键即存量链），**新颁布一律 `-ReviewMode subagent`**；legacy 链的 `Test-AuditorDeployed` 双探（引擎旁 `rdd-auditor/SKILL.md` 角色卡目录 or repo `dsh/presets/rdd-auditor` 任一在场即 true）**只代表「角色卡在」，不等于 dsh preset 在**——legacy 审查节点需真实 AUDITOR 会话 claim+report 才能 settle，dsh 默认 8 组 preset 面不可派发（死锁组合与处置见 `planner-scenarios.md` §设计汇聚审查）。`dsh/presets/rdd-auditor` 仅强形态独立会话按需重建（`build-dsh-presets.mjs --with-auditor`——脚本属源码仓 `scripts/`，**不随引擎包分发**；引擎安装内缺席时回落子代理形态，勿手工装配 preset）。

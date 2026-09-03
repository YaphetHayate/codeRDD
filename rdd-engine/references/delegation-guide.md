# 能力-文件映射

> 本文档定义每种引擎能力的 reference 文件和子 agent 配置，供 `explore.ps1` CLI 入口脚本运行时参考。

## 映射表

| 能力类型 (`-Type`) | 入口脚本 | Reference 文件 | 子 agent 类型 | 产物位置 |
|-------------------|---------|---------------|--------------|----------|
| `search` | `explore.ps1`（读面） | `references/exploration-guide.md` | `rdd-explore`（可写 worker，仅 miss 时派遣） | `.rdd/exploration/`（全局缓存） |
| `explore`（兼容面） | `explore.ps1`（读面） | `references/exploration-guide.md` | 同上 | `.rdd/exploration/` |
| `register` | `explore-store.ps1`（写面） | `references/exploration-guide.md` | n/a（CLI 直接写热区 hot.json） | `.rdd/exploration/` |
| `persist` | `explore-store.ps1`（写面） | `references/exploration-guide.md` | n/a（CLI 直接搬运热区条目进 index.json） | `.rdd/exploration/` |
| `embed-backfill` | `explore-store.ps1`（写面） | `references/exploration-guide.md` | n/a（CLI 直接补齐 vectors.json） | `.rdd/exploration/vectors.json` |
| `handoff` | `rdd-flow.ps1` | `references/handoff-guide.md` | n/a | stdout / file |

## 能力说明

### search — 缓存检索（多路召回 + RRF + Top-K 精度排序，返回排序位置）

`explore.ps1` 是**自包含缓存仲裁**：自己合并读热区（`hot.json`）与持久层（`index.json`）、做 SHA-256 时效校验、跑精度排序管线（词法 BM25 + 向量余弦多路召回 → RRF 融合 → Top-K 截断，冻结公式 F1–F8）。
- 返回 `{ results, rankMeta, dispatchPrompt? }`。results 是 Top-K 排序命中（含 `tags` / `brief` / `summaryPath` / `fullPath` / `origin` / `score` / `recalledBy`），按融合分降序；**仅 miss（空结果）时附 dispatchPrompt**。`rankMeta` 报告各召回路状态（ok/disabled/failed）。
- 调用方**两分支**消费：`results` 非空 = 命中 → Read `summaryPath`（score 最高者优先）；`results` 为空 = 未命中 → 用 `dispatchPrompt` 派遣 `rdd-explore` worker。
- stale 条目从所在 zone 驱逐（热区 stale 直接丢弃，不转正）。

> **关键**：`rdd-explore` 是**可写**子代理（需写摘要 + 完整记录 + 调 explore-store register）。内置只读 `explore`/`general` 子代理无法完成注册，禁止用于代码探索。

### register — 产物注册（写热区）

worker 探索完成后调用，校验摘要/完整记录配对、计算文件 SHA-256、在热区内按 key/产物去重后写入 `hot.json`（盖 registeredAt）。注册即对下一次检索可见。向量配置齐备时同步 embedding 单条（失败仅告警）。CLI 直接写热区，无需子代理。

### persist — 持久化转正

将热区条目按 key 转正进 `index.json`（去重替换、剥除 registeredAt），成功后从 `hot.json` 移除。每次 register/persist 触发 sweep：超 7 天未转正或容量超 50 条的热区条目按原样自动落入持久层（保底不丢）。

### embed-backfill — 向量补齐

对合并池全部 fresh 条目按当前向量配置补齐/重建 `.rdd/exploration/vectors.json`（textHash 一致复用，`-PurgeOtherModels` 清其他模型旧向量；配置不齐报 `EMBED_CONFIG_INCOMPLETE`）。CLI 直接写 sidecar，无需子代理。

### handoff — 阶段交接包

通过 `rdd-flow.ps1` 读取归档目录的 task.json（无 task.json 时回退 task.md），按目标角色筛选最小上下文，生成 handoff packet。下游角色优先读取交接包，不默认继承上游长对话或扫描整个归档。

## CLI 调用方式

```powershell
# 缓存检索，返回位置（第一步始终调用）
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search -Query "分析认证模块的中间件链"

# 产物注册，入热区（worker 探索完成后）
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type register -Key "..." -Tags "..." -Path "..." -Brief "..." -Files "..."

# 持久化转正（异步增强管线完成后）
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "..."
```

详见 `SKILL.md` 或 `references/exploration-guide.md`。

## 子代理注册

`rdd-explore` worker 在各平台以薄配置文件注册（协议单源在 `references/exploration-guide.md`，miss dispatch prompt 已内嵌全文）：

- opencode：`.opencode/agent/rdd-explore.md`（`mode: subagent`，放开 `.rdd/exploration/**` 写权限）
- Claude Code：`.claude/agents/rdd-explore.md`

未注册专用 worker 的平台，退回**可写** general 子代理 + miss dispatch prompt 也能正确执行协议（prompt 已自带完整指南）。

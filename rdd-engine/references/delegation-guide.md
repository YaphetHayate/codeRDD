# 能力-文件映射

> 本文档定义每种引擎能力的 reference 文件和子 agent 配置，供 `explore.ps1` CLI 入口脚本运行时参考。

## 映射表

| 能力类型 (`-Type`) | Reference 文件 | 子 agent 类型 | 产物位置 |
|-------------------|---------------|--------------|----------|
| `explore` | `references/exploration-guide.md` | `rdd-explore`（可写 worker，仅 miss 时派遣） | `.rdd/exploration/`（全局缓存） |
| `register` | `references/exploration-guide.md` | n/a（CLI 直接写 index） | `.rdd/exploration/` |
| `handoff` | `references/handoff-guide.md` | n/a | stdout / file |

## 能力说明

### explore — 代码探索（时效过滤 + candidates 返回）

`explore.ps1` 是**自包含缓存仲裁**：自己读 index、做 SHA-256 时效校验、返回 candidates。**不做语义匹配**——语义判断交给调用方 LLM。
- 返回 `{ candidates, dispatchPrompt }`。candidates 是全部通过时效校验的条目（含 `tags` / `brief` / `summaryPath` / `fullPath`）。
- 调用方 LLM 扫描 candidates 的 `tags` + `brief` 自主判断：命中 → Read `summaryPath`；无匹配 → 用 `dispatchPrompt` 派遣 `rdd-explore` worker。

> **关键**：`rdd-explore` 是**可写**子代理（需写摘要 + 完整记录 + 调 register）。内置只读 `explore`/`general` 子代理无法完成注册，禁止用于代码探索。

### register — 产物注册

worker 探索完成后调用，校验摘要/完整记录配对、计算文件 SHA-256、写入 tags，追加进 index。CLI 直接写 index，无需子代理。

### handoff — 阶段交接包

通过 `rdd-flow.ps1` 读取归档目录的 task.json（无 task.json 时回退 task.md），按目标角色筛选最小上下文，生成 handoff packet。下游角色优先读取交接包，不默认继承上游长对话或扫描整个归档。

## CLI 调用方式

```powershell
# 时效过滤，返回 candidates（第一步始终调用）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "分析认证模块的中间件链"

# 产物注册（worker 探索完成后）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type register -Key "..." -Tags "..." -Path "..." -Brief "..." -Files "..."
```

详见 `SKILL.md` 或 `references/exploration-guide.md`。

## 子代理注册

`rdd-explore` worker 在各平台以薄配置文件注册（协议单源在 `references/exploration-guide.md`，miss dispatch prompt 已内嵌全文）：

- opencode：`.opencode/agent/rdd-explore.md`（`mode: subagent`，放开 `.rdd/exploration/**` 写权限）
- Claude Code：`.claude/agents/rdd-explore.md`

未注册专用 worker 的平台，退回**可写** general 子代理 + miss dispatch prompt 也能正确执行协议（prompt 已自带完整指南）。

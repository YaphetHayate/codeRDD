# 能力-文件映射

> 本文档定义每种引擎能力的 reference 文件和子 agent 配置，供 `explore.ps1` CLI 入口脚本运行时参考。

## 映射表

| 能力类型 (`-Type`) | Reference 文件 | 子 agent 类型 | 产物位置 |
|-------------------|---------------|--------------|----------|
| `explore` | `references/exploration-guide.md` | `rdd-explore`（可写 worker，仅 miss 时派遣） | `.rdd/exploration/`（全局缓存） |
| `register` | `references/exploration-guide.md` | n/a（CLI 直接写 index） | `.rdd/exploration/` |
| `handoff` | `references/handoff-guide.md` | n/a | stdout / file |

## 能力说明

### explore — 代码探索缓存判定

`explore.ps1` 是**自包含缓存仲裁**：自己读 index、做 token 匹配、校验 SHA-256。
- 命中（`cache:"hit"`）→ 直接返回 artifact 正文，**不派遣任何子代理**。
- 未命中（`cache:"miss"`）→ 返回 `rdd-explore` worker 的 dispatch prompt（内嵌完整协议），调用方据此派遣。

> **关键**：`rdd-explore` 是**可写**子代理（需写 artifact + 调 register）。内置只读 `explore`/`general` 子代理无法完成注册，禁止用于代码探索。

### register — 产物注册

worker 探索完成后调用，计算文件 SHA-256 并追加进 index。CLI 直接写 index，无需子代理。

### handoff — 阶段交接包

通过 `rdd-flow.ps1` 读取归档目录的 `task.md` 路由总览，按目标角色筛选最小上下文，生成 handoff packet。下游角色优先读取交接包，不默认继承上游长对话或扫描整个归档。

## CLI 调用方式

```powershell
# 缓存判定（第一步始终调用）
$r = git rev-parse --show-toplevel; & "$r\rdd-engine\scripts\explore.cmd" -Type explore -Query "分析认证模块的中间件链"

# 产物注册（worker 探索完成后）
$r = git rev-parse --show-toplevel; & "$r\rdd-engine\scripts\explore.cmd" -Type register -Key "..." -Path "..." -Brief "..." -Files "..."
```

详见 `SKILL.md` 或 `references/exploration-guide.md`。

## 子代理注册

`rdd-explore` worker 在各平台以薄配置文件注册（协议单源在 `references/exploration-guide.md`，miss dispatch prompt 已内嵌全文）：

- opencode：`.opencode/agent/rdd-explore.md`（`mode: subagent`，放开 `.rdd/exploration/**` 写权限）
- Claude Code：`.claude/agents/rdd-explore.md`

未注册专用 worker 的平台，退回**可写** general 子代理 + miss dispatch prompt 也能正确执行协议（prompt 已自带完整指南）。

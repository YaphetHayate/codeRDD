# 能力-文件映射

> 本文档定义每种引擎能力的 reference 文件和子 agent 配置，供 `explore.ps1` CLI 入口脚本运行时参考。

## 映射表

| 能力类型 (`-Type`) | Reference 文件 | 子 agent 类型 | 产物位置 |
|-------------------|---------------|--------------|----------|
| `explore` | `references/exploration-guide.md` | `explore` | `.rdd/exploration/`（全局缓存） |
| `handoff` | `references/handoff-guide.md` | n/a | stdout / file |

## 能力说明

### explore — 代码探索（全局缓存）

分析项目代码，结果缓存于 `.rdd/exploration/artifacts/`。通过 `.rdd/exploration/index.json` 索引，后续同主题探索命中缓存后直接返回，无需重复探索。

参考指南：`references/exploration-guide.md`（索引匹配、时效性检查、产物模板）。

### handoff — 阶段交接包

通过 `rdd-flow.ps1` 读取归档目录的 `task.md` 路由总览，按目标角色筛选最小上下文，生成 handoff packet。下游角色优先读取交接包，不默认继承上游长对话或扫描整个归档。

## CLI 调用方式

通过 `explore.ps1` 脚本调用。详见 `SKILL.md` 或直接运行 `explore.cmd -Type explore -Query "<description>"`。

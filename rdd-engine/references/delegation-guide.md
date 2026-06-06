# 能力-文件映射

> 本文档定义每种引擎能力的 reference 文件和子 agent 配置，供 `engine.ps1` CLI 入口脚本运行时参考。

## 映射表

| 能力类型 (`-Type`) | Reference 文件 | 子 agent 类型 | 产物位置 |
|-------------------|---------------|--------------|----------|
| `context` | `references/context-guide.md` + `references/artifact-template.md` | `explore` | `.rdd/context/` |
| `skills` | `skill-registry.md` | `general` | stdout |
| `tools` | `references/` 目录下对应文件（待补充） | `general` | stdout |
| `explore` | `references/exploration-guide.md` | `explore` | `.rdd/exploration/`（全局缓存） |
| `handoff` | `references/handoff-guide.md` | n/a | stdout / file |

## 能力说明

### context — 项目上下文生成

采样项目代码，分析风格约定、模块结构、项目术语，生成 `.rdd/context/` 下的三类产物：
- `style.md` — 代码风格约定
- `structure.md` — 代码结构与模块关系
- `glossary.md` — 项目术语表

参考指南：`references/context-guide.md`（采样策略、生成指南、新鲜度检测）、`references/artifact-template.md`（产物模板）。

### skills — 技能发现

根据关键词查询 `skill-registry.md`，返回匹配的领域 skill 列表及使用建议。

### tools — 项目工具

委托子 agent 处理项目级通用任务。当前预留，`references/` 下工具指南待补充。

### explore — 代码探索（全局缓存）

分析项目代码，结果缓存于 `.rdd/exploration/artifacts/`。通过 `.rdd/exploration/index.json` 索引，后续同主题探索命中缓存后直接返回，无需重复探索。

参考指南：`references/exploration-guide.md`（索引匹配、时效性检查、产物模板）。

### handoff — 阶段交接包

通过 `rdd-flow.ps1` 读取归档目录的 `task.md` 路由总览，按目标角色筛选最小上下文，生成 handoff packet。下游角色优先读取交接包，不默认继承上游长对话或扫描整个归档。

## CLI 调用方式

通过 `engine.ps1` 脚本调用。详见 `SKILL.md` 或直接运行 `engine.ps1 -Type <type> -Query "<description>"`。

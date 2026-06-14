---
name: rdd-engine
description: >
  RDD 通用能力总线。所有 RDD 角色按需调用 explore.ps1 CLI 脚本，启动子 agent 完成委托并返回结果。
---

# rdd-engine

engine 通过 CLI 脚本提供服务：

- `explore.ps1`：代码探索能力委托，生成子 agent 调度指令
- `rdd-flow.ps1`：阶段流转与上下文交接，生成最小 handoff packet

## 调用方式

### 代码探索

```powershell
explore.ps1 -Type explore -Query "<description>"
```

### 流转交接

```powershell
rdd-flow.ps1 -Command next -Archive <path>     # 不传 -Archive 则自动发现最新归档
rdd-flow.ps1 -Command start -Role CTO -TaskIndex 0       # 单需求启动
rdd-flow.ps1 -Command handoff -Role DEV                  # 自动定位最新归档
rdd-flow.ps1 -Command validate -Role DEV                 # 校验 DEV 是否有任务
```

`-Archive` 为可选参数，不传时脚本自动发现最新归档。传入含 `...` 占位符或不存在路径时，自动回退到自动发现。

### 参数

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Type` | 是 | — | 能力类型，当前仅支持：`explore` |
| `-Query` | 是 | — | 需求描述，传递给子 agent |

### 能力说明

> 引擎所有可用能力的权威清单定义在 `references/capability-manifest.md`。新增/变更能力时只需更新该文件（+ `explore.ps1`），各角色自动发现。

| -Type | 说明 | Reference 文件 |
|-------|------|---------------|
| `explore` | 代码探索（全局缓存）：按 Query 查询 index 命中缓存或重新探索，结果缓存于 `.rdd/exploration/` | `references/exploration-guide.md` |

### 流转命令

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Command` | 是 | `handoff` | `next` / `start` / `handoff` / `validate` |
| `-Role` | 否 | `DEV` | 目标角色：`PM` / `CTO` / `UX` / `DEV` / `QA` |
| `-Archive` | 否 | 自动发现 | 归档路径，不传则自动取最新归档 |
| `-TaskIndex` | 否 | `-1` | 0-based 任务索引，>=0 时只筛选该条任务（"一需求一会话"） |
| `-Format` | 否 | `json` | 输出格式：`json` / `markdown` |
| `-OutFile` | 否 | stdout | 写入文件路径 |

| Command | 说明 |
|---------|------|
| `next` | 根据 `task.md` 汇总有哪些角色有待处理任务 |
| `start` | 为指定角色生成启动 prompt 和 handoff packet |
| `handoff` | 为指定角色生成最小交接包 |
| `validate` | 校验指定角色是否有可执行任务 |

### 单需求并行示例

```powershell
# PM 归档后有 3 个需求路由到 DEV，并行拉起 3 个独立 DEV 会话：
rdd-flow.ps1 -Command start -Role DEV -TaskIndex 0
rdd-flow.ps1 -Command start -Role DEV -TaskIndex 1
rdd-flow.ps1 -Command start -Role DEV -TaskIndex 2
```

### 输出格式

stdout 输出纯 JSON：

```json
// 正常
{ "success": true, "data": { "subagentType": "...", "instructions": {...} } }
// 错误
{ "success": false, "error": { "code": "...", "message": "..." } }
```

### 示例

```powershell
# 代码探索（命中缓存直接返回，未命中则探索并缓存）
explore.ps1 -Type explore -Query "分析认证模块的中间件链"
```

## 路由依据

能力到 reference 文件的映射定义在 `references/delegation-guide.md` 中。交接包规则见 `references/handoff-guide.md`。
能力完整清单及使用场景见 `references/capability-manifest.md`（各角色通过此文件发现引擎能力）。

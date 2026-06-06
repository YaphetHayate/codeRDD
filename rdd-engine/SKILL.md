---
name: rdd-engine
description: >
  RDD 通用能力总线。所有 RDD 角色按需调用 engine.ps1 CLI 脚本，启动子 agent 完成委托并返回结果。
---

# rdd-engine

engine 通过 CLI 脚本提供服务：

- `engine.ps1`：通用能力委托，生成子 agent 调度指令
- `rdd-flow.ps1`：阶段流转与上下文交接，生成最小 handoff packet

## 调用方式

### 能力委托

```powershell
engine.ps1 -Type <type> -Query "<description>" [-Mode dispatch]
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
| `-Type` | 是 | — | 能力类型：`context` / `skills` / `tools` / `explore` |
| `-Query` | 是 | — | 需求描述，传递给子 agent |
| `-Mode` | 否 | `dispatch` | 执行模式：`dispatch`（生成指令） / `direct`（保留） |

### 能力类型

| -Type | 说明 | Reference 文件 |
|-------|------|---------------|
| `context` | 项目上下文生成：采样代码，分析风格/结构/术语，生成 `.rdd/context/` 产物 | `references/context-guide.md` + `references/artifact-template.md` |
| `skills` | 技能发现：根据关键词匹配 `skill-registry.md` 中的领域 skill | `skill-registry.md` |
| `tools` | 项目工具：委托子 agent 处理项目级通用任务 | `references/` 目录下对应文件 |
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
{ "success": true, "data": { "mode": "dispatch", "subagentType": "...", "instructions": {...} } }
// 错误
{ "success": false, "error": { "code": "...", "message": "..." } }
```

### 示例

```powershell
# 生成项目上下文
engine.ps1 -Type context -Query "分析项目结构，生成 code style 和 module structure 产物"

# 发现技能
engine.ps1 -Type skills -Query "像素画"

# 委托工具
engine.ps1 -Type tools -Query "检查项目依赖安全性"

# 变更级探索
engine.ps1 -Type explore -Query "分析认证模块的中间件链"
```

## 路由依据

能力到 reference 文件的映射定义在 `references/delegation-guide.md` 中。交接包规则见 `references/handoff-guide.md`。

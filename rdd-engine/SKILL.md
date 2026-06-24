---
name: rdd-engine
description: >
  RDD 通用能力总线。所有 RDD 角色按需调用 scripts/explore.ps1 CLI 脚本，启动子 agent 完成委托并返回结果。
---

# rdd-engine

engine 通过 CLI 脚本提供服务：

- `explore.ps1`：代码探索能力。`-Type explore` 做时效过滤（SHA-256 校验剔除 stale），返回全部 fresh candidates + dispatch prompt（**不做语义匹配**，由调用方 LLM 扫 tags 判断）；`-Type register` 由 worker 探索完成后注册产物到缓存（含 tags + 摘要配对校验）。
- `rdd-flow.ps1`：阶段流转与上下文交接，生成最小 handoff packet

> **脚本位置**：所有 `.cmd` / `.ps1` 位于 `scripts/` 子目录（与 `SKILL.md` 同级的 `scripts/`，非 skill 根目录），遵循 skill 标准结构。完整路径：`rdd-engine/scripts/explore.cmd`、`rdd-engine/scripts/rdd-flow.cmd`（仓库根相对）。
>
> **调用入口统一用 `.cmd` 包装器**（`scripts/rdd-flow.cmd` / `scripts/explore.cmd`，与同名 `.ps1` 同目录）。`.cmd` 内部以 `powershell -ExecutionPolicy Bypass -File` 调用 `.ps1`，绕过 Windows 默认的 `Restricted` 执行策略。**不要直接调用 `.ps1`**——在 ExecutionPolicy=Restricted 的环境下会被系统拦截。下方所有示例均使用仓库根相对的完整路径 `rdd-engine/scripts/*.cmd`。

## 调用方式

### 代码探索

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "<description>"
```

返回 JSON（始终返回 candidates + dispatchPrompt）：
- 扫描 `data.candidates` 的 `tags` + `brief`，结合 Query 判断相关性
- **命中** → Read `data.candidates[].summaryPath`（摘要）；需深入细节再 Read `fullPath`
- **无匹配** → 用 `data.dispatchPrompt` 派遣 `rdd-explore` 子代理（可写 worker）

### 探索产物注册（worker 探索完成后调用）

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type register -Key "<semantic key>" -Tags "<module/feature/synonym keywords, comma-separated>" -Path "<artifact path>" -Brief "<summary>" -Files "<comma-separated files>"
```

### 流转交接

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command next -Archive <path>     # 不传 -Archive 则自动发现最新归档
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role CTO -TaskIndex 0       # 单需求启动
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role DEV                  # 自动定位最新归档
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command validate -Role DEV                 # 校验 DEV 是否有任务
```

`-Archive` 为可选参数，不传时脚本自动发现最新归档。传入含 `...` 占位符或不存在路径时，自动回退到自动发现。

### 参数

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Type` | 是 | — | 能力类型：`explore`（时效过滤）/ `register`（注册产物） |
| `-Query` | `explore` 必需 | — | 需求描述，传递给 dispatchPrompt |
| `-Key` | `register` 必需 | — | 语义 key（中文可用），标识探索主题 |
| `-Tags` | `register` 必需 | — | 逗号分隔的关键词标签（模块名/功能名/同义词，中英文），LLM 判断命中的核心依据 |
| `-Path` | `register` 必需 | — | 完整记录文件路径（repo-relative，需配对 `{slug}.summary.md`） |
| `-Brief` | `register` 必需 | — | 一句话摘要 |
| `-Files` | `register` 必需 | — | 逗号分隔的已分析文件路径列表 |

### 能力说明

> 引擎所有可用能力的权威清单定义在 `references/capability-manifest.md`。新增/变更能力时只需更新该文件（+ `explore.ps1`），各角色自动发现。

| `-Type` | 说明 | Reference 文件 |
|-------|------|---------------|
| `explore` | 时效过滤：SHA-256 校验剔除 stale，返回全部 fresh candidates + dispatch prompt（语义判断由调用方 LLM 扫 tags 完成） | `references/exploration-guide.md` |
| `register` | 注册产物：worker 探索完成后，校验摘要配对、写入 tags、计算文件哈希并追加进 index | `references/exploration-guide.md` |

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
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role DEV -TaskIndex 0
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role DEV -TaskIndex 1
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role DEV -TaskIndex 2
```

### 输出格式

stdout 输出纯 JSON：

```json
// 正常（explore 返回 candidates + dispatchPrompt）
{ "success": true, "data": { "query": "...", "candidates": [...], "dispatchPrompt": "..." } }
// 错误
{ "success": false, "error": { "code": "...", "message": "..." } }
```

### 示例

```powershell
# 代码探索（返回 candidates，调用方 LLM 扫 tags 判断，无匹配时用 dispatchPrompt 派 worker）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "分析认证模块的中间件链"

# worker 探索完成后注册产物（含 tags + 配对校验）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type register -Key "认证中间件链" -Tags "认证,鉴权,auth,jwt,中间件" -Path ".rdd/exploration/artifacts/auth-middleware.md" -Brief "JWT 签发→验证→权限检查" -Files "src/auth/middleware.ts,src/auth/jwt.ts"
```

## 路由依据

能力到 reference 文件的映射定义在 `references/delegation-guide.md` 中。交接包规则见 `references/handoff-guide.md`。
能力完整清单及使用场景见 `references/capability-manifest.md`（各角色通过此文件发现引擎能力）。

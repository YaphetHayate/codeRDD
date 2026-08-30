---
name: rdd-engine
description: >
  RDD 通用能力总线。所有 RDD 角色按需调用 scripts/explore.ps1（读面：search/explore 检索）与
  scripts/explore-store.ps1（写面：register 入热区/persist 转正）CLI 脚本，启动子 agent 完成委托并返回结果。
---

# rdd-engine

engine 通过 CLI 脚本提供服务：

- `explore.ps1`（读面）：代码探索检索能力。`-Type search` 合并读双 zone（热区 `hot.json` 优先 + 持久层 `index.json`），SHA-256 时效校验剔除 stale，跑**精度排序管线**（词法 BM25 + 向量余弦多路召回 → RRF 融合 → Top-K 截断，冻结公式 F1–F8），返回排序后的数据**所在位置**（key/tags/brief/summaryPath/fullPath/origin/score/recalledBy + rankMeta），miss 时附 dispatch prompt（**两分支协议**：results 非空即命中，空则派遣）；`-Type explore` 为兼容面（candidates + 恒附 dispatchPrompt）；`-Type register` 为废弃转发（薄转发到 explore-store）。
- `explore-store.ps1`（写面）：缓存写入与生命周期。`-Type register` 注册产物入热区（注册即对下一次检索可见，向量配置齐备时同步 embedding）；`-Type persist` 按 key 转正进持久层；`-Type embed-backfill` 为存量条目补齐/重建向量 sidecar；sweep 保底（超 7 天 / 容量 50 条未转正 → 按原样自动落入持久层，任何已探索结果不丢）。
- `rdd-flow.ps1`：阶段流转与上下文交接，生成最小 handoff packet

> **脚本位置**：所有 `.cmd` / `.ps1` 位于 `scripts/` 子目录（与 `SKILL.md` 同级的 `scripts/`，非 skill 根目录），遵循 skill 标准结构。完整路径：`rdd-engine/scripts/explore.cmd`、`rdd-engine/scripts/explore-store.cmd`、`rdd-engine/scripts/rdd-flow.cmd`（仓库根相对）。
>
> **调用入口统一用 `.cmd` 包装器**（`scripts/rdd-flow.cmd` / `scripts/explore.cmd` / `scripts/explore-store.cmd`，与同名 `.ps1` 同目录）。`.cmd` 内部以 `powershell -ExecutionPolicy Bypass -File` 调用 `.ps1`，绕过 Windows 默认的 `Restricted` 执行策略。**不要直接调用 `.ps1`**——在 ExecutionPolicy=Restricted 的环境下会被系统拦截。下方所有示例均使用仓库根相对的完整路径 `rdd-engine/scripts/*.cmd`。

## 调用方式

### 缓存检索（第一步）

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type search -Query "<description>"
```

返回 JSON（results 为空时附 dispatchPrompt）：
- `data.results` 是精度管线排序后的 Top-K 命中（每条含 `score` 融合分 + `recalledBy` 召回路，`origin: hot|persistent`），**两分支**消费
- **非空 = 命中** → Read `data.results[0].summaryPath`（score 最高者优先；摘要）；需深入细节再 Read `fullPath`
- **空 = 未命中** → 用 `data.dispatchPrompt` 派遣 `rdd-explore` 子代理（可写 worker）

### 探索产物注册（worker 探索完成后调用，写面）

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type register -Key "<semantic key>" -Tags "<module/feature/synonym keywords, comma-separated>" -Path "<artifact path>" -Brief "<summary>" -Files "<comma-separated files>"
```

> 旧路径 `explore.cmd -Type register` 仍可用（薄转发，输出附 deprecation 提示）；新代码一律直调 `explore-store.cmd`。

### 持久化转正

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "<semantic key>"
```

### 向量补齐（配置/更换 embedding 模型后）

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type embed-backfill [-PurgeOtherModels]
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

explore.cmd（读面）：

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Type` | 是 | — | 能力类型：`search`（检索，返回位置）/ `explore`（兼容面，candidates + 恒附 dispatchPrompt）/ `register`（废弃转发到 explore-store） |
| `-Query` | `search`/`explore` 必需 | — | 需求描述，传递给 dispatchPrompt |

explore-store.cmd（写面）：

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Type` | 是 | — | 能力类型：`register`（注册入热区）/ `persist`（按 key 转正进持久层）/ `embed-backfill`（补齐向量 sidecar，可加 `-PurgeOtherModels` 清其他模型旧向量） |
| `-Key` | `register`/`persist` 必需 | — | 语义 key（中文可用），标识探索主题 |
| `-Tags` | `register` 必需 | — | 逗号分隔的关键词标签（模块名/功能名/同义词，中英文）——LLM 的阅读语言 + 词法召回的检索语料（直接进 BM25 评分） |
| `-Path` | `register` 必需 | — | 完整记录文件路径（repo-relative，需配对 `{slug}.summary.md`） |
| `-Brief` | `register` 必需 | — | 一句话摘要 |
| `-Files` | `register` 必需 | — | 逗号分隔的已分析文件路径列表 |

### 能力说明

> 引擎所有可用能力的权威清单定义在 `references/capability-manifest.md`。新增/变更能力时只需更新该文件（+ 对应脚本），各角色自动发现。

| `-Type` | 入口 | 说明 | Reference 文件 |
|-------|------|------|---------------|
| `search` | `explore.cmd` | 检索接口：双 zone 合并（SHA-256 剔除 stale）→ 精度排序管线（多路召回 + RRF 融合 + Top-K，冻结公式 F1–F8）→ 返回排序位置；miss 附 dispatchPrompt（两分支协议：非空即命中） | `references/exploration-guide.md` |
| `explore` | `explore.cmd` | 兼容面：candidates + 恒附 dispatchPrompt（旧调用方零改动，条目新增 origin 为超集增量） | `references/exploration-guide.md` |
| `register` | `explore-store.cmd` | 注册入热区：校验摘要配对、写入 tags、计算文件哈希，热区内去重后追加（盖 registeredAt），注册即可见（向量配置齐备时同步 embedding） | `references/exploration-guide.md` |
| `persist` | `explore-store.cmd` | 转正：热区条目按 key 转正进 index.json（去重替换） | `references/exploration-guide.md` |
| `embed-backfill` | `explore-store.cmd` | 向量补齐：为存量条目重建 `.rdd/exploration/vectors.json`（textHash 一致复用；配置不齐报 EMBED_CONFIG_INCOMPLETE） | `references/exploration-guide.md` |

### 流转命令

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Command` | 是 | `handoff` | `next` / `start` / `handoff` / `validate` |
| `-Role` | 否 | `DEV` | 目标角色：`PM` / `CTO` / `UX` / `DEV` / `QA` |
| `-Archive` | 否 | 自动发现 | 归档路径，不传则自动取最新归档 |
| `-TaskIndex` | 否 | `-1` | 0-based 任务索引，>=0 时只筛选该条任务（"一需求一会话"） |
| `-TaskId` | 否 | `-1` | task.json 中的任务 id，>=1 时按 id 筛选单条 |
| `-Format` | 否 | `json` | 输出格式：`json` / `markdown` |
| `-OutFile` | 否 | stdout | 写入文件路径 |

| Command | 说明 |
|---------|------|
| `next` | 根据 task.json 汇总有哪些角色有待处理任务 |
| `start` | 为指定角色生成启动 prompt 和 handoff packet |
| `handoff` | 为指定角色生成最小交接包 |
| `validate` | 校验指定角色是否有可执行任务 |
| `show` | 读取 task.json 任务路由（支持 `-Role` 过滤、`-TaskId` 精确查找） |
| `init` | PM 归档时创建 task.json（`-TasksFile` 指定 JSON 文件） |
| `add-task` | 向已有 task.json 追加单条任务 |
| `set-route` | 覆盖指定任务的 `currentOwners` |
| `advance` | 推进路由（替换语义：移除 `-From` 角色，加入 `-To` 角色） |
| `add-design` | 追加设计文档到指定任务 |
| `reject` | 发起驳回（`currentOwners` 改为被驳回方 + 写备注） |
| `complete` | 标记任务已闭环（`lifecycle=completed`） |
| `reopen` | 重新激活已闭环任务 |
| `deprecate` | 标记任务废弃（`lifecycle=deprecated`） |
| `check` | 校验 task.json schema + 与文档流转控制一致性 |
| `migrate` | 将旧 task.md 转为 task.json |

> 完整的路由操作协议见 `rdd-engine/references/task-routing.md`。

### 交接脚本（start-role）

为下游角色一键开启会话，免去手动 `/new` + 敲命令。脚本读 `$env:RDD_RUNTIME` **自动选择后端**，agent 无需判断运行模式：
- **CLI 后端**（`RDD_RUNTIME` 未设置）：开新 Windows Terminal 窗口，预填 `/rdd-<角色> ...`
- **Plus 后端**（`RDD_RUNTIME=app`，运行在 Plus 应用内）：POST 到 Plus `/api/rdd/handoff`，Plus 创建对话并自动驱动目标角色；需追加 `-EmployeeId <uuid>`

上游 agent 完成路由推进后调用：

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\start-role.cmd" -Role <下游角色> -TaskId <n>
```

| 参数 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `-Role` | 是 | — | 目标角色：`PM`/`CTO`/`UX`/`DEV`/`QA`/`EVAL`/`PSE` |
| `-TaskId` | 否 | `-1` | >=1 时 TaskId 模式，定位单条任务 |
| `-TaskJson` | 否 | 自动发现 | 显式指定 task.json 路径（不传则取 `.rdd/changes/archive/` 最新归档） |
| `-Handoff` | 否 | — | 传入交接包文件路径，启用 Handoff 模式（覆盖 TaskId） |
| `-EmployeeId` | 仅 Plus | — | Plus 模式必填，目标角色对应的员工 UUID |
| `-Project` | 否 | git root | 项目根，非 git 环境必须显式指定 |
| `-PlusUrl` | 否 | `http://127.0.0.1:8000` | Plus 后端地址 |
| `-DryRun` | 否 | — | 只打印将执行的命令，不实际交接 |

**CLI 后端 prompt 模式**（按 Handoff > TaskId > 纯角色 优先）：
- `-Handoff <path>` → `/rdd-<role> handoff=<abs>`
- `-TaskId <n>` → `/rdd-<role> TaskId=<n> task=<abs>`（推荐）
- 都不传 → `/rdd-<role>`（目标角色自行拉 handoff）

**Plus 后端**：脚本据 TaskId/TaskJson 定位归档，发送指针消息 `请处理 .rdd/changes/archive/<name>/ 下的需求。`（见 `transition-guide.md` 入口 B2），由目标员工的 `agent_mode` 绑定的角色 SKILL 接管。

脚本不校验 TaskId 有效性，由目标角色拉 handoff 时自行判断。详见 `references/transition-guide.md` 入口 B0。

### 单需求并行示例

```powershell
# PM 归档后有 3 个需求路由到 DEV，脚本自动开 3 个会话并行：
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName
& "$rdd\scripts\start-role.cmd" -Role DEV -TaskId 1
& "$rdd\scripts\start-role.cmd" -Role DEV -TaskId 2
& "$rdd\scripts\start-role.cmd" -Role DEV -TaskId 3
# Plus 模式下追加 -EmployeeId <对应 DEV 员工 UUID>
```

### 输出格式

stdout 输出纯 JSON：

```json
// 正常（search 返回排序位置 + rankMeta，miss 时附 dispatchPrompt）
{ "success": true, "data": { "query": "...", "results": [ { "key": "...", "tags": [...], "brief": "...", "summaryPath": "...", "fullPath": "...", "origin": "hot|persistent", "score": 0.032787, "recalledBy": ["lexical", "vector"] } ], "staleRemoved": 0, "rankMeta": { "recallers": [ { "name": "lexical", "status": "ok", "qualified": 3 } ], "fused": 3, "returned": 1 }, "dispatchPrompt": "..." } }
// 错误
{ "success": false, "error": { "code": "...", "message": "..." } }
```

### 示例

```powershell
# 缓存检索（返回排序位置：results 非空即命中读首条，空则用 dispatchPrompt 派 worker）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type search -Query "分析认证模块的中间件链"

# worker 探索完成后注册产物（入热区；含 tags + 配对校验）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type register -Key "认证中间件链" -Tags "认证,鉴权,auth,jwt,中间件" -Path ".rdd/exploration/artifacts/auth-middleware.md" -Brief "JWT 签发→验证→权限检查" -Files "src/auth/middleware.ts,src/auth/jwt.ts"

# 持久化转正
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "认证中间件链"
```

## 路由依据

能力到 reference 文件的映射定义在 `references/delegation-guide.md` 中。交接包规则见 `references/handoff-guide.md`。
能力完整清单及使用场景见 `references/capability-manifest.md`（各角色通过此文件发现引擎能力）。

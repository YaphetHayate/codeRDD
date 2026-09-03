# 任务路由协议（task-routing）

> **定位**：所有 RDD 角色对任务路由的读写操作的**唯一权威定义**。各角色 SKILL 不再重复定义路由操作细节，只引用本文档。
>
> **适用范围**：PM 归档初始化、CTO/UX/DEV/QA 流转推进、QA/EVAL/PSE 只读查询、任意角色发起驳回。

---

## 核心原则

1. **CLI 收敛**：路由字段的读写一律通过 `rdd-flow.cmd` 子命令完成。角色**禁止直接编辑 task.json**——手写 JSON 易 schema 漂移，且无法保证与文档自身流转控制的一致性。
2. **双源一致性**：task.json 的 `currentOwners` 与各需求/设计文档自身 `## 流转控制 > 当前责任人` 语义对齐。两者不一致时，**以文档自身为准**，CLI 的 `check` 命令负责检测并报告，角色通过 CLI 命令修正 task.json。
3. **结构化集合**：并行责任人、多设计文档用 JSON 数组表达，消灭旧的 `+` 分隔字符串约定和 `(待产出)` 文本占位。

---

## task.json

### 位置

`.rdd/changes/archive/<archive-name>/task.json`

### Schema

```json
{
  "version": 1,
  "archive": "2026-06-17-multi-owner-parallel-flow",
  "generatedAt": "2026-06-17T23:04:05",
  "tasks": [
    {
      "id": 1,
      "title": "支持单需求多角色并行流转",
      "requirement": "requirements/multi-owner.md",
      "currentOwners": ["CTO", "UX"],
      "designDocs": [
        { "path": "design/multi-owner-cto.md", "status": "pending" },
        { "path": "design/multi-owner-ux.md", "status": "pending" }
      ],
      "remark": "复合需求，CTO+UX 并行",
      "lifecycle": "active"
    },
    {
      "id": 2,
      "title": "修复登录跳转 bug",
      "requirement": "requirements/fix-login-bug.md",
      "currentOwners": ["DEV"],
      "designDocs": [],
      "remark": "",
      "lifecycle": "active"
    }
  ]
}
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `version` | number | schema 版本，当前固定 `1` |
| `archive` | string | 归档目录名（非完整路径） |
| `generatedAt` | string | ISO 8601 时间戳，由 CLI 维护 |
| `tasks[].id` | number | 任务序号，归档内唯一，从 1 递增 |
| `tasks[].title` | string | 需求标题（对应需求文档的一级标题） |
| `tasks[].requirement` | string | 需求文件路径，repo-relative，`/` 分隔（如 `requirements/fix-login-bug.md`） |
| `tasks[].currentOwners` | string[] | 当前责任人角色数组。单元素 = 单角色；多元素 = 并行。取值：`PM`/`CTO`/`UX`/`DEV`/`QA` |
| `tasks[].designDocs` | object[] | 关联设计文档集合。每项含 `path`（repo-relative）和 `status`（`pending`/`ready`）。无设计文档时为空数组 `[]` |
| `tasks[].remark` | string | 自由文本备注（并行标注、驳回摘要等） |
| `tasks[].lifecycle` | string | 生命周期：`active`（流转中）/ `deprecated`（被驳回废弃）/ `completed`（已闭环） |

**`designDocs[].status` 取值**：
- `pending`：PM 归档时预填的占位（对应旧 `(待产出)`），路径仅为预期位置
- `ready`：设计文档已实际产出

**`lifecycle` 与路由的关系**：
- `completed` 的任务不会被 `next`/`handoff`/`start` 匹配给任何角色，天然跳过已闭环需求
- `deprecated` 的任务保留行用于审计追溯，不进入流转

---

## CLI 命令

> **调用约定**：以下示例中 `$rdd` 指向 rdd-engine 目录，定义为：
> ```powershell
> $rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }
> ```
> 所有命令通过 `& "$rdd\scripts\rdd-flow.cmd" -Command <name> ...` 调用，输出 UTF-8 JSON。

### 读取类

#### `show` — 读取任务路由

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command show -Archive ".rdd/changes/archive/<name>"
& "$rdd\scripts\rdd-flow.cmd" -Command show -Archive ".rdd/changes/archive/<name>" -Role CTO
& "$rdd\scripts\rdd-flow.cmd" -Command show -Archive ".rdd/changes/archive/<name>" -TaskId 1
```

- 无过滤参数 → 返回全部 tasks
- `-Role <Role>` → 仅返回 `currentOwners` 含该角色且 `lifecycle=active` 的 tasks
- `-TaskId <n>` → 返回指定单条详情

各角色定位自己的任务一律用 `show -Role <本角色>`。

#### `version` — 输出引擎版本与安装根

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command version
```

- 无需归档、无需 git 仓库，任意目录可运行（安装器自检 / 环境诊断用）
- 返回 `data.version`（来自 `rdd-engine/package.json`，发行版本真相源）与 `data.engineRoot`（脚本所在引擎根）

### 初始化类（PM 归档用）

#### `init` — 创建 task.json

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command init -Archive ".rdd/changes/archive/<name>" -Tasks '<JSON>'
```

`-Tasks` 接收 tasks 数组的内联 JSON 字符串。中文内容通过 cmd 传参有编码风险，建议改用 `-TasksFile` 指向 JSON 文件（UTF-8 无 BOM）。PM 归档时一次性写入全部任务。每条 task 无需填 `id`（CLI 自动编号）和 `generatedAt`（CLI 自动写入），但须提供 `title`/`requirement`/`currentOwners`，可选 `designDocs`/`remark`。

示例 `-TasksFile`（推荐，避免中文编码问题）：
```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command init -Archive ".rdd/changes/archive/<name>" -TasksFile ".rdd/changes/archive/<name>/tasks-init.json"
```

示例 `-Tasks`：
```json
[
  {
    "title": "支持单需求多角色并行流转",
    "requirement": "requirements/multi-owner.md",
    "currentOwners": ["CTO", "UX"],
    "designDocs": [
      { "path": "design/multi-owner-cto.md", "status": "pending" },
      { "path": "design/multi-owner-ux.md", "status": "pending" }
    ],
    "remark": "复合需求，CTO+UX 并行"
  }
]
```

#### `add-task` — 追加单条任务

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command add-task -Archive ".rdd/changes/archive/<name>" -Title "标题" -Requirement "requirements/x.md" -CurrentOwners "DEV"
```

向已有 task.json 追加一条。`-CurrentOwners` 多角色用 `+` 连接（如 `CTO+UX`），CLI 自动转为数组。

#### `set-route` — 覆盖路由

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command set-route -Archive ".rdd/changes/archive/<name>" -TaskId 1 -To "DEV"
& "$rdd\scripts\rdd-flow.cmd" -Command set-route -Archive ".rdd/changes/archive/<name>" -TaskId 2 -To "CTO+UX"
```

直接覆盖指定 task 的 `currentOwners`。PM 归档时设置初始路由，或被打回后重新路由时使用。`-To` 多角色用 `+` 连接。

### 流转类（CTO/UX/DEV/QA 完成产物后）

#### `advance` — 推进路由

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command advance -Archive ".rdd/changes/archive/<name>" -TaskId 1 -From CTO -To DEV
```

**替换语义**：从 `currentOwners` 中移除 `-From` 角色，加入 `-To` 角色。

- 单角色场景：`["CTO"]` → advance -From CTO -To DEV → `["DEV"]`
- 并行场景：`["CTO","UX"]` → advance -From CTO -To DEV → `["UX","DEV"]`（UX 保留，仅 CTO 被 DEV 替换）
- 同角色去重：若 `-To` 已在数组中，不重复追加

`-From` 必须是当前 `currentOwners` 中的角色，否则报错（防止误操作）。

#### `add-design` — 追加设计文档

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command add-design -Archive ".rdd/changes/archive/<name>" -TaskId 1 -Path "design/multi-owner-cto.md"
```

将设计文档登记到指定 task 的 `designDocs`：
- 若 `designDocs` 中已存在同 `path` 的 `pending` 占位 → 将其 `status` 改为 `ready`
- 否则追加新条目 `{path, status: "ready"}`
- 自动去重，不覆盖他人已登记的路径

CTO/UX 完成设计归档后，先 `add-design` 再 `advance`。

### 终态类

#### `complete` — 标记已闭环

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command complete -Archive ".rdd/changes/archive/<name>" -TaskId 1
```

将 `lifecycle` 改为 `completed`。QA 验证通过后，或用户显式跳过 QA 后调用。

#### `reopen` — 重新激活

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command reopen -Archive ".rdd/changes/archive/<name>" -TaskId 1 -To DEV
```

将 `lifecycle` 从 `completed` 改回 `active`，并设置 `currentOwners`。QA 或用户后续发现问题时调用，重启流转。

#### `deprecate` — 标记废弃

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command deprecate -Archive ".rdd/changes/archive/<name>" -TaskId 1
```

将 `lifecycle` 改为 `deprecated`。驳回生效后旧文档对应的 task 调用，保留行用于审计。

### 驳回类

#### `reject` — 发起驳回

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command reject -Archive ".rdd/changes/archive/<name>" -TaskId 1 -From CTO -To PM -Reason "验收标准不可测试"
```

- `-From`：发起方角色（调用方自己）
- `-To`：被驳回方角色（路由指向谁）
- 将 `currentOwners` 改为 `[-To]`，`remark` 追加驳回摘要

驳回记录的完整表格仍写在文档自身的 `## 驳回记录` 章节（见 `rejection-protocol.md`）。本命令只同步路由状态。

### 校验类

#### `check` — 校验 task.json

```powershell
& "$rdd\scripts\rdd-flow.cmd" -Command check -Archive ".rdd/changes/archive/<name>"
```

执行两项校验：
1. **schema 校验**：字段完整、类型正确、取值合法
2. **一致性校验**：每个 task 的 `currentOwners` 与对应需求/设计文档 `## 流转控制 > 当前责任人` 是否一致；`designDocs` 中 `status=ready` 的文件是否存在

返回所有不一致项。PM 归档后、每次流转后建议运行。

---

## 各角色操作速查

| 角色 | 典型场景 | 命令 |
|------|---------|------|
| **PM** | 归档初始化 | `init`（一次性写入全部任务） |
| **PM** | 追加需求 | `add-task` |
| **PM** | 设置/重派路由 | `set-route` |
| **PM** | 被打回后修订完成 | `set-route`（重新路由） |
| **CTO** | 定位自己的任务 | `show -Role CTO` |
| **CTO** | 设计归档后推进 | `add-design` → `advance -From CTO -To DEV`（或 `-To UX`） |
| **CTO** | L1 快速结论直接发开发 | `advance -From CTO -To DEV`（无设计文档则跳过 add-design） |
| **UX** | 定位自己的任务 | `show -Role UX` |
| **UX** | 设计归档后推进 | `add-design` → `advance -From UX -To DEV` |
| **DEV** | 定位自己的任务 | `show -Role DEV` |
| **DEV** | 实现完成推进 QA | `advance -From DEV -To QA` |
| **QA** | 定位自己的任务 | `show -Role QA` |
| **QA** | 验证通过闭环 | `complete` |
| **QA** | 发现问题回退 | `reopen -To DEV` |
| **任意角色** | 发起驳回 | `reject -From <自己> -To <被驳回方> -Reason` |
| **EVAL/PSE** | 只读了解状态 | `show` |

---

## 关键语义

### 并行推进

当 `currentOwners` 含多个角色时，每个角色**独立推进自己那份**：

```
初始：["CTO", "UX"]
CTO 完成 → advance -From CTO -To DEV   → ["UX", "DEV"]
UX 完成  → advance -From UX  -To DEV   → ["DEV", "DEV"] → 去重 → ["DEV"]
```

只有当 `currentOwners` 收敛为单一角色时，该任务才进入单线流转。CLI 自动去重，无需手动处理。

### 双源一致性

task.json 与文档自身 `## 流转控制` 的关系：

- **文档自身是语义真源**：文档的 `当前责任人` 字段反映该文档实际归属
- **task.json 是路由缓存**：聚合所有任务的路由状态，供 CLI 快速查询和 handoff 生成
- **推进时双写**：角色推进路由时，先更新文档自身 `## 流转控制 > 当前责任人`，再调 CLI 命令同步 task.json
- **不一致时以文档为准**：`check` 命令报告不一致，角色用 `set-route` 修正 task.json

### 集合语义

- `currentOwners`：数组天然支持并行，无需字符串拼接
- `designDocs`：每个设计文档独立带状态，多人各自 `add-design` 不会互相覆盖

---

## 历史兼容

- **旧归档（有 task.md 无 task.json）**：`rdd-flow.ps1` 读不到 task.json 时回退解析 task.md 路由总览（legacy path），各命令仍可工作
- **迁移工具**：`migrate -Archive <path>` 可将旧 task.md 转为 task.json（处理存量归档，一次性）
- 旧 task.md 的「角色参与计划」章节、✅⬜ 状态表一律忽略，路由信息统一从 `currentOwners` 派生

# 角色交接协议

> **定位**：所有 RDD 角色在完成产物后、引导下一角色时的标准流程。
> 上游角色（PM/CTO/UX/QA）完成归档后**必须**按本协议执行交接，不走"直接告知用户输入斜杠命令"的捷径。
> 下游角色（DEV/CTO/QA）按本协议识别三种入口，统一以 handoff packet 为上下文边界开工。

---

## 模式检测

RDD 有两种运行环境，交接行为不同。**判据是运行时环境变量 `$env:RDD_RUNTIME`，由 `start-role.ps1` 在脚本层读取**——agent 不自行判断模式：

| 判断条件 | 模式 | 说明 |
|---------|------|------|
| `RDD_RUNTIME` **未设置** | **self-driven**（CLI） | 独立终端窗口跑 opencode，脚本走 CLI 后端开新 wt/PowerShell 窗口 |
| `RDD_RUNTIME=app` | **app-driven**（Plus） | 运行在 Plus 应用内（opencode server 由 Plus 启动并注入该 env），脚本走 Plus 后端调 `/api/rdd/handoff` |

> **判据演进**：旧版用 `.rdd/roles.json` 是否存在判断——但装了 Plus 后 `roles.json` 永久存在，导致用户用 CLI 时 agent 仍误判为 app-driven。现在 `roles.json` 降级为"Plus 能力声明文件"（存储角色配置），**不再决定交接分支**；真正的判据是 `RDD_RUNTIME`，它精确反映"当前这次会话从哪个入口发起"。
>
> `RDD_RUNTIME=app` 由 Plus 在启动 opencode server 时注入（`server.py` 的 `create_subprocess_exec` 传 `env`），子进程链继承，所以 agent/脚本都能读到。独立 CLI 窗口无人注入 → 自动 self-driven。

---

## 上游协议（4 步硬流程）

适用于 PM 归档需求、CTO/UX 归档设计、QA 归档测试用例后的"引导下一步"。

### Step 1 — 推进 task.json 路由

将已完成产物的需求行 `currentOwners` 改为下一处理角色（调用 `rdd-flow advance`），同步需求/设计文档自身的 `## 流转控制 > 当前责任人`。完整命令参考见 `rdd-engine/references/task-routing.md`。

### Step 2 — 运行 next，展示可流转角色

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command next -Format markdown
```

将输出的可流转角色列表展示给用户。

### Step 3 — 推荐角色 + 请求用户确认

根据 `next` 输出的 roles 和当前流程状态，推荐目标角色并请求确认：

```
建议进入 <角色>，有 N 个待处理任务。
是否确认进入？
```

**单条深耕模式下的重入分支**：CTO/UX/DEV 一次会话只深耕一条需求。归档单条后若 `next` 显示**本角色**仍有 `taskCount > 0`（其余待处理需求），优先推荐**重入本角色**（新会话）处理下一条，而非直接交下游：

```
本次需求已闭环。<本角色> 还有 N 条待处理，建议 /new 开新会话继续本角色处理下一条；
若希望先推进已就绪的下游任务，也可选择进入 <下游角色>。
```

仅当本角色已清空，或用户主动选择推进下游时，才按正常下游推荐。

### Step 4 — 用户确认后，调用交接脚本

无论哪种运行模式，上游 agent **统一调用交接脚本**，由脚本读 `$env:RDD_RUNTIME` 自动选择后端：

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\start-role.cmd" -Role <目标角色> -TaskId <n>
```

> app-driven 模式下还需 `-EmployeeId <uuid>`（目标角色对应的员工，从交接包/路由取）。脚本会 POST 到 Plus 的 `/api/rdd/handoff`，由 Plus 创建对话并自动驱动目标角色。

**脚本行为按后端分支**：

#### CLI 后端（`RDD_RUNTIME` 未设置）

脚本开启新 Windows Terminal 窗口（检测不到 `wt.exe` 时降级为 PowerShell 窗口），用 `opencode --prompt` 预填 `/rdd-<角色> ...` 入口命令。用户在新窗口按回车发送即进入角色。**同会话切换已废弃**——上游长对话会污染下游上下文。

#### Plus 后端（`RDD_RUNTIME=app`）

脚本 **不开外部窗口**，而是 POST 到 `127.0.0.1:8000/api/rdd/handoff`：Plus 创建该员工的新对话，发送指针消息（`请处理 .rdd/changes/archive/<name>/ 下的需求。`），由 `agent_mode` 绑定的角色 SKILL 拉起 handoff 开工。若目标员工当前有进行中的会话，handoff 进入服务端 FIFO 队列，待当前会话结束自动启动。脚本收到 200 返回即完成交接。

> Plus 后端不可达（连接失败）时，脚本打印警告并降级到 CLI 后端开窗，确保用户不被阻塞。
>
> **重要**：app-driven 模式下，agent 的职责到"调用脚本"为止。不越权直接加载目标 SKILL、不宣布上下文边界——这些由脚本 + Plus 接管。

---

## 下游协议（入口识别）

下游角色（DEV/CTO/UX/QA）进入时，按部署模式识别入口来源：

### 入口 B0 — 交接脚本（通用，优先）

上游 agent 完成路由推进后，**统一调用交接脚本**为目标角色开启下游会话。脚本读 `$env:RDD_RUNTIME` 自动选择后端，agent 无需判断模式：

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\start-role.cmd" -Role <下游角色> -TaskId <n>
```

> app-driven（Plus）模式下追加 `-EmployeeId <uuid>`，其余参数不变。

脚本行为按后端分支：
- **CLI 后端**（`RDD_RUNTIME` 未设置）：开新 Windows Terminal 窗口（检测不到 `wt.exe` 时降级为 PowerShell 窗口），`opencode --prompt` 预填 `/rdd-<角色> ...` 入口消息，用户在新窗口按回车发送即进入角色
- **Plus 后端**（`RDD_RUNTIME=app`）：不开窗口，POST 到 Plus `/api/rdd/handoff`，Plus 创建对话并自动发送指针消息驱动目标角色（见入口 B2）；目标员工忙碌时服务端排队

脚本参数模式（两后端共用）：
- **TaskId 模式**（推荐）：`-TaskId <n>`，CLI 后端预填 `/rdd-<角色> TaskId=<n> task=<task.json绝对路径>`；Plus 后端据此定位归档生成指针消息
- **Handoff 模式**（上游预生成交接包时）：`-Handoff <文件路径>`
- **纯角色模式**：不传 `-TaskId` / `-Handoff`，由目标角色自行拉 handoff（仅 CLI 后端支持；Plus 后端必须能定位归档）

**TaskId 由执行者校验**：脚本不校验 TaskId 有效性。目标角色拉 handoff 时若发现 TaskId 不存在（已被他人完成 / 被废弃），自行判断并告知用户。

**并行交接**：同一归档需要同时交多个角色时（如 PM 同时交 CTO+QA），上游 agent 循环调用脚本，每次指定不同 `-Role`，各自开独立窗口 / 各自建独立对话。TaskId 相同时多角色共享同一 task.json 指针。

### 入口 B1 — 手动新会话角色命令（self-driven，降级）

当脚本自动开窗不可用（非 Windows / 无 wt / opencode CLI 缺失），或用户偏好手动操作时，回退到手动流程。用户在上游引导下：

1. `/new`（Ctrl+X N）开新 session
2. 输入 `/rdd-<角色>` —— 命令自动加载角色 SKILL，并通过 `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command handoff` 拉取最新交接包

该入口由 `.opencode/commands/rdd-<角色>.md` 实现。**旧版"同会话宣布边界 / Agent 直接交接"已废弃**——无法真正隔离上游上下文。若用户坚持在同会话进入角色，按命令中的检查清单执行，并提示下次走脚本开窗或 `/new`。

### 入口 B2 — 应用层指针消息（app-driven）

收到形如以下的消息：

```
请处理 .rdd/changes/archive/<archive-name>/ 下的需求。
```

识别为应用层交接触发。在 Plus 模式下，这条消息由 `/api/rdd/handoff` 端点自动发送（脚本走 Plus 后端时触发）；用户也可在 Plus 对话框手动输入。提取归档路径，主动拉取交接包：

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role <self> -Archive ".rdd/changes/archive/<archive-name>"
```

用 packet 作为上下文边界开工。**不要将指针消息当作"用户直接下达的开发指令"（优先级 E）处理**——它是一个交接信号，背后有完整的 task.json 路由和交接包。

---

## 上下文边界规则

无论哪种入口，下游角色必须遵守（详见 `handoff-guide.md`）：

1. 只读 handoff packet 列出的需求/设计文档
2. 不扫描整个归档目录
3. 不读取 `ignored` 中的文档（除非用户明确要求）
4. 代码探索从 `involvedFiles` 起步，深入时委托 `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type search`
5. 角色切换走新会话（脚本入口 B0 自动选后端，或手动 `/new` 入口 B1）；同会话内不切换，避免上游对话污染

---

## 各角色速查

| 当前角色 | 典型下游 | 交接触发条件 | 下游入口命令 |
|---------|---------|-------------|-------------|
| PM | CTO / UX / DEV | 需求归档完成，task.json 路由已设置 | `/rdd-cto` `/rdd-ux` `/rdd-dev` |
| CTO | UX（并行）/ DEV | 设计文档归档完成，路由改为 UX 或 DEV | `/rdd-ux` `/rdd-dev` |
| UX | DEV | 设计规格归档完成，路由改为 DEV | `/rdd-dev` |
| QA | DEV（测试先行）/ 已完成（验证模式）/ DEV（reopen） | 测试先行：测试用例归档完成交 DEV；验证模式：功能+质量双通过 → 提交 → 标记已完成，任一硬性项不通过 → reopen 回 DEV | `/rdd-dev`（测试先行） |
| DEV | QA | 实现完成并自测通过，路由改为 QA（DEV 不再自行提交）；QA 验证通过并提交后改为"已完成" | `/rdd-qa` |

> 进入下游优先用交接脚本（入口 B0，`start-role.cmd -Role <下游> -TaskId <n>`，脚本按 `RDD_RUNTIME` 自动选 CLI/Plus 后端）；脚本不可用时手动 `/new` + 入口命令（B1）。
> app-driven（Plus）模式下脚本追加 `-EmployeeId <uuid>`。
> 同一归档中多个需求路由到同一角色时，用 `-TaskId` 逐条独立启动（一需求一会话并行）。

### 单条深耕与 handoff 语义

CTO/UX/DEV 采用单条深耕：每会话锁定一条需求做透。引擎返回的完整 handoff（含本角色全部 tasks）由 agent 在 SKILL 层负责锁定一条——这些"同角色但本会话不做"的需求**不属于** packet 的 `ignored`（`ignored` 指派给其他角色），而是本角色待办、留待后续会话。

- agent 锁定一条后，剩余 task 不需要重新拉 packet，靠 task.json 路由自然延续：归档一条推进一行，下个会话 `handoff` 自然读到剩余待办
- 多条 L2/L3 想并行时，可开多个新会话，各自用 `-TaskIndex` 指定不同索引独立启动（一需求一会话）；不想并行则按重入分支逐条串行

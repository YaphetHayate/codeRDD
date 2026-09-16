# 角色交接协议

> **定位**：所有 RDD 角色在完成产物后、引导下一角色时的标准流程。
> 上游角色（PM/CTO/UX/QA）完成归档后**必须**按本协议执行交接，不走"直接告知用户输入斜杠命令"的捷径。
> 下游角色（DEV/CTO/QA）按本协议识别三种入口，统一以 handoff packet 为上下文边界开工。
>
> **路由单一真源**：流转状态（当前处理角色、任务生命周期）只存在于 task.json，一律通过 `rdd-flow` CLI 读写。需求/设计文档是内容工件——任何角色都有权阅读，但只有作者角色有维护义务，**文档不承载流转字段**。存量归档中已有的「当前责任人」视为废弃历史痕迹，一律以 task.json 为准，无需回改。

---

## 模式检测

RDD 有三种运行环境，交接行为不同。**判据链由 `start-role.ps1` 在脚本层按固定顺序读取**——agent 不自行判断模式：

| 判断条件（按序） | 模式 | 说明 |
|---------|------|------|
| `RDD_RUNTIME=app` | **app-driven**（Plus） | 运行在 Plus 应用内（opencode server 由 Plus 启动并注入该 env），脚本走 Plus 后端调 `/api/rdd/handoff` |
| `DSH_WEB_URL` 非空 | **dsh-driven**（dsh Web GUI） | 运行在 dsh 会话内（harness 向 shell 子进程注入该变量），脚本走 dsh 后端经 `/api` 载波自动建会话 |
| 两者均未设置 | **self-driven**（CLI） | 独立终端窗口跑 opencode，脚本走 CLI 后端开新 wt/PowerShell 窗口 |

> `DSH_WEB_URL` 的值即 dsh Web GUI 本地服务地址（如 `http://127.0.0.1:3080`），dsh 后端直接以它为请求基地址（可用 `-DshUrl` 覆盖）。判据链顺序固定：`RDD_RUNTIME` 优先，保证 Plus/CLI 语义不变，也避免 Plus 环境变量泄漏进 dsh shell 时走错分支。

> **判据演进**：旧版用 `.rdd/roles.json` 是否存在判断——但装了 Plus 后 `roles.json` 永久存在，导致用户用 CLI 时 agent 仍误判为 app-driven。现在 `roles.json` 降级为"Plus 能力声明文件"（存储角色配置），**不再决定交接分支**；真正的判据是 `RDD_RUNTIME` / `DSH_WEB_URL` 判据链，它精确反映"当前这次会话从哪个入口发起"。
>
> `RDD_RUNTIME=app` 由 Plus 在启动 opencode server 时注入（`server.py` 的 `create_subprocess_exec` 传 `env`），子进程链继承，所以 agent/脚本都能读到。`DSH_WEB_URL` 由 dsh harness 向 shell 子进程注入（Web GUI 服务地址）。独立 CLI 窗口两者皆无人注入 → 自动 self-driven。

---

## 上游协议（4 步硬流程）

适用于 PM 归档需求、CTO/UX 归档设计、QA 归档测试用例后的"引导下一步"。

### Step 1 — 推进 task.json 路由

将已完成产物的需求行 `currentOwners` 改为下一处理角色，调用 `rdd-flow advance` 一步完成。**不修改任何文档侧的流转字段**——文档是内容工件，路由状态只活在 task.json；存量归档中已存在的「当前责任人」字段已废弃，以 task.json 为准。完整命令参考见 `rdd-engine/references/task-routing.md`。

### Step 2 — 运行 next，展示可流转角色

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command next -Format markdown
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

无论哪种运行模式，上游 agent **统一调用交接脚本**，由脚本按判据链（`RDD_RUNTIME` → `DSH_WEB_URL` → CLI）自动选择后端：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\start-role.cmd" -Role <目标角色> -TaskId <n>
```

> app-driven 模式下还需 `-EmployeeId <uuid>`（目标角色对应的员工，从交接包/路由取）。脚本会 POST 到 Plus 的 `/api/rdd/handoff`，由 Plus 创建对话并自动驱动目标角色。
> dsh-driven 模式下无需任何额外参数：脚本经 dsh 现有 `/api` 载波建会话并投递 B2 指针消息（`-EmployeeId` 属 Plus 语义，dsh 分支显式忽略）。

**脚本行为按后端分支**：

#### CLI 后端（判据链均未命中）

脚本开启新 Windows Terminal 窗口（检测不到 `wt.exe` 时降级为 PowerShell 窗口），用 `opencode --prompt` 预填 `/rdd-<角色> ...` 入口命令。用户在新窗口按回车发送即进入角色。**同会话切换已废弃**——上游长对话会污染下游上下文。

#### Plus 后端（`RDD_RUNTIME=app`）

脚本 **不开外部窗口**，而是 POST 到 `127.0.0.1:8000/api/rdd/handoff`：Plus 创建该员工的新对话，发送指针消息（`请处理 .rdd/changes/archive/<name>/ 下的需求。`），由 `agent_mode` 绑定的角色 SKILL 拉起 handoff 开工。若目标员工当前有进行中的会话，handoff 进入服务端 FIFO 队列，待当前会话结束自动启动。脚本收到 200 返回即完成交接。

> Plus 后端不可达（连接失败）时，脚本打印警告并降级到 CLI 后端开窗，确保用户不被阻塞。

#### dsh 后端（`DSH_WEB_URL` 非空）

脚本 **不开外部窗口，也不需要 `-EmployeeId`**，而是复用 dsh 现有 `/api` 载波四连发：`agentPreset.list` 预检 preset 存在性 → `workspace.create {path}` resolve-or-create 项目 workspace（realpath 规范化，幂等）→ `session.create {workspaceId, agentPreset: rdd-<角色>}` 创建会话并入账 workspace → `session.prompt` 发送指针消息（B2 语义）。preset 按命名约定 `rdd-<角色小写>` 绑定，miss 时报错并列出可用 preset。新会话直接出现在 Web GUI 侧栏的项目 workspace 文件夹内（cwd-only 创建不进任何 workspace 账，只会落入侧栏底部的 Ungrouped 区）；指针消息被接受即自动驱动目标角色跑完整个 turn——全程无手动建会话/选 preset 操作。

失败回退：业务错误 → 报错退出（含服务端错误码）；dsh 不可达（服务未启动/超时/403）→ 报错 + 打印人工指引（侧栏手动建会话选 preset + 指针消息全文）；create 成功但 prompt 失败 → 报错 + 打印指针消息，可点开侧栏已有会话手动粘贴。**不降级 CLI 开窗**（Web GUI 用户面前开本地终端窗无意义）。

> **DryRun**：`-DryRun` 在 dsh 分支打印模式/基地址/preset 与三个 RPC payload，不发送。
>
> **重要**：app-driven 模式下，agent 的职责到"调用脚本"为止。不越权直接加载目标 SKILL、不宣布上下文边界——这些由脚本 + Plus 接管。dsh-driven 同理，由脚本 + 目标角色 preset 接管。

---

## 下游协议（入口识别）

下游角色（DEV/CTO/UX/QA）进入时，按部署模式识别入口来源：

### 入口 B0 — 交接脚本（通用，优先）

上游 agent 完成路由推进后，**统一调用交接脚本**为目标角色开启下游会话。脚本按判据链（`RDD_RUNTIME` → `DSH_WEB_URL`）自动选择后端，agent 无需判断模式：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\start-role.cmd" -Role <下游角色> -TaskId <n>
```

> app-driven（Plus）模式下追加 `-EmployeeId <uuid>`，其余参数不变；dsh 模式无需任何额外参数。

脚本行为按后端分支：
- **CLI 后端**（判据链均未命中）：开新 Windows Terminal 窗口（检测不到 `wt.exe` 时降级为 PowerShell 窗口），`opencode --prompt` 预填 `/rdd-<角色> ...` 入口消息，用户在新窗口按回车发送即进入角色
- **Plus 后端**（`RDD_RUNTIME=app`）：不开窗口，POST 到 Plus `/api/rdd/handoff`，Plus 创建对话并自动发送指针消息驱动目标角色（见入口 B2）；目标员工忙碌时服务端排队
- **dsh 后端**（`DSH_WEB_URL` 非空）：不开窗口，经 dsh `/api` 载波 `workspace.create` + `session.create {workspaceId}`（绑定 `rdd-<角色>` preset 并入账）+ `session.prompt`（指针消息，见入口 B2）自动创建会话并开工；新会话直接出现在 Web GUI 侧栏的项目 workspace 文件夹内

脚本参数模式（各后端共用）：
- **TaskId 模式**（推荐）：`-TaskId <n>`，CLI 后端预填 `/rdd-<角色> TaskId=<n> task=<task.json绝对路径>`；Plus/dsh 后端据此定位归档生成指针消息
- **Handoff 模式**（上游预生成交接包时）：`-Handoff <文件路径>`
- **纯角色模式**：不传 `-TaskId` / `-Handoff`，由目标角色自行拉 handoff（仅 CLI 后端支持；Plus/dsh 后端必须能定位归档）

**TaskId 由执行者校验**：脚本不校验 TaskId 有效性。目标角色拉 handoff 时若发现 TaskId 不存在（已被他人完成 / 被废弃），自行判断并告知用户。

**并行交接**：同一归档需要同时交多个角色时（如 PM 同时交 CTO+QA），上游 agent 循环调用脚本，每次指定不同 `-Role`，各自开独立窗口 / 各自建独立对话。TaskId 相同时多角色共享同一 task.json 指针。

### 交接类型：manager-takeover（PM 可选分支）

PM 归档完成后判断任务集较重（多需求、多角色、需并行/依赖编排）时，可不逐条交接下游，而是把整批交付交给 Manager（引擎编排形态，非第六角色）：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位" }; & "$rdd\scripts\start-role.cmd" -Role MANAGER -TaskJson <归档 task.json>
```

- 脚本投递的是**自举式指针消息**（"请以 Manager 身份接管 … 先读 manager-guide.md，随后执行 delivery-bridge promulgate …"）——Manager 无角色卡，身份由消息 + `rdd-engine/references/manager-guide.md` 装载；三后端（CLI/Plus/dsh）一致。dsh 后端需 preset `rdd-manager`（部署前提见 manager-guide）。
- 中断续跑：`start-role.cmd -Role MANAGER -RunId <run-id>`。
- 该分支**纯可选**：未采用时按正常 4 步硬流程逐条交接，行为不变。任务路由仍先按 Step 1 推进到首个下游角色（promulgate 按当前 currentOwners 建阶段节点）。

### 入口 B1 — 手动新会话角色命令（self-driven，降级）

当脚本自动开窗不可用（非 Windows / 无 wt / opencode CLI 缺失），或用户偏好手动操作时，回退到手动流程。用户在上游引导下：

1. `/new`（Ctrl+X N）开新 session
2. 输入 `/rdd-<角色>` —— 命令自动加载角色 SKILL，并通过 `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command handoff` 拉取最新交接包

该入口由 `.opencode/commands/rdd-<角色>.md` 实现。**旧版"同会话宣布边界 / Agent 直接交接"已废弃**——无法真正隔离上游上下文。若用户坚持在同会话进入角色，按命令中的检查清单执行，并提示下次走脚本开窗或 `/new`。

### 入口 B2 — 应用层指针消息（app-driven）

收到形如以下的消息：

```
请处理 .rdd/changes/archive/<archive-name>/ 下的需求。
```

识别为应用层交接触发。这条消息由脚本的应用层后端自动发送——Plus 经 `/api/rdd/handoff` 端点（`RDD_RUNTIME=app`），dsh 经 `session.prompt`（`DSH_WEB_URL` 非空）；用户也可在 Plus 对话框手动输入。提取归档路径，主动拉取交接包：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role <self> -Archive ".rdd/changes/archive/<archive-name>"
```

用 packet 作为上下文边界开工。**不要将指针消息当作"用户直接下达的开发指令"（优先级 E）处理**——它是一个交接信号，背后有完整的 task.json 路由和交接包。

---

## 上下文边界规则

无论哪种入口，下游角色必须遵守（详见 `handoff-guide.md`）：

1. 只读 handoff packet 列出的需求/设计文档
2. 不扫描整个归档目录
3. 不读取 `ignored` 中的文档（除非用户明确要求）
4. 代码探索从 `involvedFiles` 起步，深入时委托 `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\explore.cmd" -Type search`
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

> 进入下游优先用交接脚本（入口 B0，`start-role.cmd -Role <下游> -TaskId <n>`，脚本按 `RDD_RUNTIME` → `DSH_WEB_URL` → CLI 判据链自动选后端）；脚本不可用时手动 `/new` + 入口命令（B1）。
> app-driven（Plus）模式下脚本追加 `-EmployeeId <uuid>`。
> 同一归档中多个需求路由到同一角色时，用 `-TaskId` 逐条独立启动（一需求一会话并行）。

### 单条深耕与 handoff 语义

CTO/UX/DEV 采用单条深耕：每会话锁定一条需求做透。引擎返回的完整 handoff（含本角色全部 tasks）由 agent 在 SKILL 层负责锁定一条——这些"同角色但本会话不做"的需求**不属于** packet 的 `ignored`（`ignored` 指派给其他角色），而是本角色待办、留待后续会话。

- agent 锁定一条后，剩余 task 不需要重新拉 packet，靠 task.json 路由自然延续：归档一条推进一行，下个会话 `handoff` 自然读到剩余待办
- 多条 L2/L3 想并行时，可开多个新会话，各自用 `-TaskIndex` 指定不同索引独立启动（一需求一会话）；不想并行则按重入分支逐条串行

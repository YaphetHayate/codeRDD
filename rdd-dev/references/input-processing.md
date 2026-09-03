# 输入处理

> 本文档是 [SKILL.md](../SKILL.md) 的补充材料，描述 DEV 模式进入后如何按优先级通过路由目录确定开发任务。

## 优先级 A0 — 脚本自动开窗的指针消息

当上游通过 `start-role.cmd` 自动开窗时，prompt 形如：

- **TaskId 模式**：`/rdd-dev TaskId=<n> task=<task.json绝对路径>`
- **Handoff 模式**：`/rdd-dev handoff=<交接包绝对路径>`

识别到指针后：

**TaskId 模式**：从指针的 task.json 路径定位归档，调 rdd-flow 拉单条 packet：
```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role DEV -Archive <task.json所在归档目录> -TaskId <n>
```
**TaskId 由本角色校验**：若 TaskId 在 task.json 中不存在（可能已被他人完成或废弃），向用户说明情况并请求裁决，不自行臆断。

**Handoff 模式**：直接 Read 交接包文件，按包内 tasks 开工。

两种模式下都只处理指针指向的单条任务，不扫描整个归档。

## 优先级 A — 用户指定了文档

用户提供了需求文档或设计文档路径，或者明确说"按设计方案开发 XX"。

→ 直接读取指定文档，跳转到对应模式。

## 优先级 B — 使用 handoff packet 定位待开发任务

DEV 有两种入口方式：

### B1 — Agent 间交接（上游传递）

当上游角色（PM/CTO）通过 `$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role DEV` 启动新会话时，新会话直接使用输出的 handoff packet，无需自行定位。此时：
- 一次会话只实现一条需求（与 CTO/UX 对称）。`-TaskIndex` 指定单条启动，未指定时 handoff 列出全部 DEV 任务，锁定一条深耕
- 只处理 packet 中 `tasks` 列出的需求/设计文档
- 不扫描整个归档目录
- 多个需求可通过多个 `/new` 会话各自带 `-TaskIndex` 并行（一条需求一个 session）

### B2 — 用户手动进入（路径 B）

用户输入 `/RDD-DEV` 但未指定归档时，调用流转脚本自动获取最新归档中的 DEV 任务：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role DEV
```

### B3 — 应用层指针消息（app-driven）

收到形如 `请处理 .rdd/changes/archive/<archive-name>/ 下的需求。` 的消息时，识别为应用层交接触发（Plus 模式）。提取归档路径，主动拉取交接包：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role DEV -Archive ".rdd/changes/archive/<archive-name>"
```

**不要将指针消息当作"用户直接下达的开发指令"（优先级 E）处理**——它是一个交接信号，背后有完整的 task.json 路由和交接包。

脚本自动定位最新归档，生成 DEV 的交接包。读取交接包后：

1. **锁定单条**：handoff 仅 1 条 DEV 任务 → 直接处理；多条时锁定一条深耕（推荐依赖根/优先级高的，其余留待后续 `/new` 会话）。一次会话只实现一条需求
2. 只处理锁定任务对应的需求/设计文档，不默认扫描整个归档目录
3. 不读取 `ignored` 中的文档，除非依赖缺失、验收标准不清或用户明确要求
4. 代码探索从交接包 `involvedFiles` 和对应需求/设计文档开始
5. 按 task 的 `workMode` 进入设计引导或需求引导模式
6. 设计文档（UX 规格）「视觉稿参考」章节登记的 mockup（如 `design/mockups/final.html`）必须读取作为视觉参考，不属扫描禁令范围；具体参数以规格文档为准

### 脚本返回值处理

- 返回 `success: true`，`tasks` 非空 → 按交接包执行
- 返回 `success: true`，`tasks` 为空 → 告知用户"当前没有分配给 DEV 的任务"，列出 `ignored` 原因
- 返回 `success: false`，错误码 `ARCHIVE_ROOT_NOT_FOUND` / `NO_ARCHIVES` → 自动退回到优先级 C
- 返回 `success: false`，其他错误 → 向用户说明，同时退回到优先级 C
- 脚本包含 `warnings` → 先向用户展示，再确认是否继续

## 优先级 C — 基于 task.json 定位待开发任务

仅当优先级 B 的 handoff 脚本不可用或报错回退至此，或用户明确要求手动定位时，通过路由目录定位任务：

1. 扫描 `.rdd/changes/archive/` 目录，按日期排序找到最新的归档
2. 调用 rdd-flow show -Role DEV 读取任务路由
3. 任务路由操作遵循 `rdd-engine/references/task-routing.md`。用 `show -Role DEV` 定位待开发任务
   - 逐条检查需求文件自身 `## 流转控制 > 当前责任人`；若与 `task.json` 不一致，以需求文件为准并通过 CLI 修正
4. 根据关联设计文档判定工作模式：
   - `design/` 下存在 CTO 或 UX 设计文档 → **设计引导模式**（严格按设计实现）
   - 仅有需求文件、无设计文档 → **需求引导模式**（基于需求灵活开发）
   - 如果存在 QA 已完成（QA✅）但 DEV 未开始的 task → **测试先行模式**
5. 向用户确认：

   > 在 task.json 中找到了 [X] 个待开发任务：
   > - Task N: [标题]（设计引导 / 需求引导）
   > - Task M: [标题]（...）
   >
   > 按这些任务来开发吗？

## 优先级 D — 无 task.json，自动查找文档

task.json 不存在时（旧归档自动回退 task.md），回退到手动查找：

1. 检查 `design/` 子目录下是否有设计文档
   - 有 → 读取设计文档，检查 frontmatter 的 `status: active` 和流转控制的 `当前责任人`
   - 如果 `当前责任人 = DEV` → 进入**设计引导模式**
   - 如果 `当前责任人` 不是 DEV → 告知用户该文档当前不归 DEV 处理
2. 检查 `requirement.md` 或 `overview.md`
   - 有 → 向用户确认后进入**需求引导模式**
3. 只有需求、无设计文档 → 确认：

   > 找到了需求文档但没有设计方案。你可以：
   > - 告诉我直接基于需求开发（进入需求引导模式）
   > - 输入 **/RDD-CTO** 先出设计方案再开发

## 优先级 E — 用户直接下达开发指令

用户直接描述要做什么（如"加个登录功能"、"修一下这个 bug"），没有关联任何文档。

**Bug 检测优先**：如果用户指令匹配 bug 报告模式（"XX 不工作"、"XX 报错"、"修一下 XX"、"XX 有问题"），直接进入 **Bug 修复模式（Mode 4）**，不走直接开发模式。

不匹配 bug 模式时，进入**直接开发模式**（Direct）。

## 优先级 F — 什么都找不到，也没有具体指令

> 当前没有可用的需求文档或设计文档，你也没有告诉我具体要做什么。你可以：
> - 直接告诉我要开发什么
> - 输入 **/RDD-PM** 先梳理需求
> - 输入 **/RDD-CTO** 做设计方案

---

## 路由系统下的设计文档扫描

当通过路由总览或扫描发现设计文档时，必须逐文档检查 `## 流转控制 > 当前责任人`：

- 本角色（DEV）只处理 `当前责任人 = DEV` 的设计文档
- 如果设计文档的 `当前责任人` 不是 DEV → 跳过，不在本次任务范围内
- 如果设计文档 `status = deprecated` → 跳过，不应基于废弃文档开发
- 如果设计文档 `## 驳回记录` 中有待处理项（状态 = 待回应 / 待裁决）→ 优先处理驳回流程，暂不开始开发

仅有需求文档、没有设计文档时，也必须检查需求文档的 `## 流转控制`：

- `当前责任人 = DEV` 且 `文档状态 = active` → 可进入需求引导模式
- `当前责任人` 不是 DEV → 跳过并通过 CLI 修正 `task.json`
- 存在待处理驳回记录 → 优先处理驳回流程，暂不开始开发

# 角色交接协议

> **定位**：所有 RDD 角色在完成产物后、引导下一角色时的标准流程。
> 上游角色（PM/CTO/UX/QA）完成归档后**必须**按本协议执行交接，不走"直接告知用户输入斜杠命令"的捷径。
> 下游角色（DEV/CTO/QA）按本协议识别三种入口，统一以 handoff packet 为上下文边界开工。

---

## 模式检测

RDD 有两种部署场景，交接行为不同。通过 `.rdd/roles.json` 是否存在判断：

| 判断条件 | 模式 | 说明 |
|---------|------|------|
| `.rdd/roles.json` **不存在** | **self-driven**（Standalone） | 纯 skill 模式，agent 在 CLI 中直接驱动，同会话切换角色 |
| `.rdd/roles.json` **存在** | **app-driven**（Plus） | 应用层 GUI 模式，应用层检测路由变化并驱动切换 |

> `.rdd/roles.json` 由 Plus 应用层创建（存储角色配置），Standalone 模式不会产生此文件。

---

## 上游协议（4 步硬流程）

适用于 PM 归档需求、CTO/UX 归档设计、QA 归档测试用例后的"引导下一步"。

### Step 1 — 更新 task.md 路由总览

将已完成产物的需求行 `当前责任人` 改为下一处理角色，同步需求/设计文档自身的 `## 流转控制 > 当前责任人`。

### Step 2 — 运行 next，展示可流转角色

```powershell
rdd-engine/rdd-flow.cmd -Command next -Format markdown
```

将输出的可流转角色列表展示给用户。

### Step 3 — 推荐角色 + 请求用户确认

根据 `next` 输出的 roles 和当前流程状态，推荐目标角色并请求确认：

```
建议进入 <角色>，有 N 个待处理任务。
是否确认进入？
```

### Step 4 — 用户确认后，生成交接包

```powershell
rdd-engine/rdd-flow.cmd -Command start -Role <目标角色> -OutFile ".rdd/handoff/<role>.md"
```

生成交接包后，**按模式分支**：

#### self-driven（Standalone）

Agent **不在同一会话内切换角色**——上游长对话会污染下游上下文，"宣布边界"无法真正隔离。改为引导用户开新 session：

1. （可选）落盘交接包便于排查：
   ```powershell
   rdd-engine/rdd-flow.cmd -Command start -Role <目标角色> -OutFile ".rdd/handoff/<role>.md"
   ```
2. 向用户输出切换指引（入口命令均为 `/rdd-<角色>`，见下文"各角色速查"）：

   ```
   ─────────────────────────────────────────
   角色切换：进入 <角色> 需要新的会话窗口
   1. 按 Ctrl+X N（或输入 /new）开新 session
   2. 在新 session 输入 /rdd-<目标角色>
      → 自动加载角色 SKILL + 最新交接包
   ─────────────────────────────────────────
   ```

3. 当前会话至此结束交接职责。不要在同会话加载新角色 SKILL，也不要代其开工。

#### app-driven（Plus）

Agent **不尝试加载目标 skill、不宣布上下文边界**——这些由应用层接管：

```
交接包已就绪：.rdd/handoff/<role>.md
路由已更新，请在应用层点击切换到 <角色>。
```

应用层会自动检测 task.md 的 `currentOwner` 变化，显示切换按钮。用户点击后，应用层切换员工并发送指针消息给下游角色。

> **重要**：app-driven 模式下，agent 的职责到"生成 packet + 更新 task.md"为止。不越权驱动角色切换，不干扰应用层的 UI 流程。

---

## 下游协议（入口识别）

下游角色（DEV/CTO/UX/QA）进入时，按部署模式识别入口来源：

### 入口 B1 — 新会话角色命令（self-driven）

self-driven 模式下，角色切换一律在新 session 完成，**不在同会话切换**。用户在上游引导下：

1. `/new`（Ctrl+X N）开新 session
2. 输入 `/rdd-<角色>` —— 命令自动加载角色 SKILL，并通过 `rdd-flow.cmd -Command handoff` 拉取最新交接包

该入口由 `.opencode/commands/rdd-<角色>.md` 实现。**旧版"同会话宣布边界 / Agent 直接交接"已废弃**——无法真正隔离上游上下文。若用户坚持在同会话进入角色，按命令中的检查清单执行，并提示下次走 `/new`。

### 入口 B2 — 应用层指针消息（app-driven）

收到形如以下的消息：

```
请处理 .rdd/changes/archive/<archive-name>/ 下的需求。
```

识别为应用层交接触发。提取归档路径，主动拉取交接包：

```powershell
rdd-engine/rdd-flow.cmd -Command handoff -Role <self> -Archive ".rdd/changes/archive/<archive-name>"
```

用 packet 作为上下文边界开工。**不要将指针消息当作"用户直接下达的开发指令"（优先级 E）处理**——它是一个交接信号，背后有完整的 task.md 路由和交接包。

---

## 上下文边界规则

无论哪种入口，下游角色必须遵守（详见 `handoff-guide.md`）：

1. 只读 handoff packet 列出的需求/设计文档
2. 不扫描整个归档目录
3. 不读取 `ignored` 中的文档（除非用户明确要求）
4. 代码探索从 `involvedFiles` 起步，深入时委托 `explore.ps1`
5. self-driven 角色切换走新会话（见入口 B1）；同会话内不切换，避免上游对话污染

---

## 各角色速查

| 当前角色 | 典型下游 | 交接触发条件 | 下游入口命令 |
|---------|---------|-------------|-------------|
| PM | CTO / UX / DEV | 需求归档完成，task.md 路由已设置 | `/rdd-cto` `/rdd-ux` `/rdd-dev` |
| CTO | UX（并行）/ DEV | 设计文档归档完成，路由改为 UX 或 DEV | `/rdd-ux` `/rdd-dev` |
| UX | DEV | 设计规格归档完成，路由改为 DEV | `/rdd-dev` |
| QA | DEV | 测试用例归档完成（测试先行），或测试报告产出（验证模式） | `/rdd-dev` |
| DEV | QA / 已完成 | 实现完成，路由改为 QA；QA 通过后改为"已完成" | `/rdd-qa` |

> self-driven 模式：进入下游 = 上游引导用户 `/new` 后输入上表入口命令，命令会自动加载 SKILL + handoff。CTO/UX/DEV 入口命令已就绪；QA/EVAL/PSE 按需补充。
> 同一归档中多个需求路由到同一角色时，用 `-TaskIndex` 逐条独立启动（一需求一会话并行）。

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
rdd-engine/rdd-flow.ps1 -Command next -Format markdown
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
rdd-engine/rdd-flow.ps1 -Command start -Role <目标角色> -OutFile ".rdd/handoff/<role>.md"
```

生成交接包后，**按模式分支**：

#### self-driven（Standalone）

Agent 在同一会话内直接切换角色：

1. 加载目标角色 SKILL.md（如 `rdd-dev/SKILL.md`）
2. 宣布上下文边界：

   ```
   ─────────────────────────────────────────
   上下文边界：以下进入 <角色> 模式
   以 handoff packet 为唯一入口上下文
   忽略上游对话中的非产物信息
   ─────────────────────────────────────────
   ```

3. 以 packet 中的 tasks/requirement/design 开始工作

#### app-driven（Plus）

Agent **不尝试加载目标 skill、不宣布上下文边界**——这些由应用层接管：

```
交接包已就绪：.rdd/handoff/<role>.md
路由已更新，请在应用层点击切换到 <角色>。
```

应用层会自动检测 task.md 的 `currentOwner` 变化，显示切换按钮。用户点击后，应用层切换员工并发送指针消息给下游角色。

> **重要**：app-driven 模式下，agent 的职责到"生成 packet + 更新 task.md"为止。不越权驱动角色切换，不干扰应用层的 UI 流程。

---

## 下游协议（三入口识别）

下游角色（DEV/CTO/QA）进入时，按优先级识别入口来源：

### 入口 B1 — Agent 直接交接（self-driven）

上游 agent 在同一会话内切换角色，直接传递 handoff packet。

- packet 已在上下文中 → 直接使用，无需重新拉取
- 只处理 packet 中 `tasks` 列出的需求/设计文档
- 不扫描整个归档目录

### 入口 B2 — 用户手动进入

用户输入 `/RDD-<角色>` 或明确要求进入某角色。

```powershell
rdd-engine/rdd-flow.ps1 -Command handoff -Role <self>
```

脚本自动定位最新归档生成交接包。读取后按 packet 的 tasks 开工。

### 入口 B3 — 应用层指针消息（app-driven）

收到形如以下的消息：

```
请处理 .rdd/changes/archive/<archive-name>/ 下的需求。
```

识别为应用层交接触发。提取归档路径，主动拉取交接包：

```powershell
rdd-engine/rdd-flow.ps1 -Command handoff -Role <self> -Archive ".rdd/changes/archive/<archive-name>"
```

用 packet 作为上下文边界开工。**不要将指针消息当作"用户直接下达的开发指令"（优先级 E）处理**——它是一个交接信号，背后有完整的 task.md 路由和交接包。

---

## 上下文边界规则

无论哪种入口，下游角色必须遵守（详见 `handoff-guide.md`）：

1. 只读 handoff packet 列出的需求/设计文档
2. 不扫描整个归档目录
3. 不读取 `ignored` 中的文档（除非用户明确要求）
4. 代码探索从 `involvedFiles` 起步，深入时委托 `explore.ps1`
5. self-driven 同会话切换时，忽略上游长对话中的非产物信息

---

## 各角色速查

| 当前角色 | 典型下游 | 交接触发条件 |
|---------|---------|-------------|
| PM | CTO / UX / DEV | 需求归档完成，task.md 路由已设置 |
| CTO | UX（并行）/ DEV | 设计文档归档完成，路由改为 UX 或 DEV |
| UX | DEV | 设计规格归档完成，路由改为 DEV |
| QA | DEV | 测试用例归档完成（测试先行），或测试报告产出（验证模式） |
| DEV | QA / 已完成 | 实现完成，路由改为 QA；QA 通过后改为"已完成" |

> 同一归档中多个需求路由到同一角色时，用 `-TaskIndex` 逐条独立启动（一需求一会话并行）。

# 视觉稿生成方法论

本文件定义 UX Skill Phase 2.5 的完整执行流程——将设计规格草案转化为用户可选、可迭代的视觉稿，并在确认后产出 DEV 可参考的精确实现。

## 设计理念

**纯文字规格传达不了"用起来什么感觉"，纯 HTML 传达不了"好不好看"，纯图片传达不了"DEV 能 inspect 什么"。**

不同素材各有擅长的表达维度，应**按需求场景匹配最合适的素材**，而非固定优先某一种再降级：

- **图片** 擅长视觉氛围、配色气质、品牌表现力（"好不好看、满不满意"）
- **HTML** 擅长精确信息架构、交互细节、可量化的视觉参数（"结构对不对、值是多少"）

选定素材后，方向探索统一采用**并行子代理 fork-join**：三个方向各自独立生成，互不串扰。无论素材是图片还是 HTML，都走同一套并行流程，保证速度与差异化。

> 对比展示用的框架 HTML 已**固化为模板**（`rdd-ux/templates/mockup-gallery.html`），UX 不再每次重写框架，只填数据。

---

## 素材类型场景匹配（核心决策）

进入 Phase 2.5 方向探索前，先按需求特征选定**主素材类型**，图片生成工具的可用性仅作为修正因子（不再作为唯一决策轴）。

### 主素材类型选择

| 需求场景 | 主素材 | 理由 |
|---------|--------|------|
| 创作者模式 · 品牌 / 氛围 / 首屏探索 | `image` | 图片表达视觉气质效率最高，氛围探索直观 |
| 创作者模式 · 数据密集 / 复杂交互（dashboard / 表格 / 表单流 / 多步操作） | `html` | 精确表达信息架构与交互，图片反而模糊失真、无法体现层级 |
| 翻译者模式（用户提供参考图） | `html`（单方向复刻） | 视觉方向已由参考图确定，跳过方向探索，直接精确复刻（见专节） |
| 混合模式 | `html` 为主（受参考图约束） | 参考图提供视觉系统约束，HTML 精确实现 |

判定不清时取两者交集：既非明显数据密集、也非明显氛围探索 → 默认 `html`（覆盖面更广、DEV 参考价值更高）。

### 工具可用性修正

| 主素材 | 图片生成工具可用 | 图片生成工具不可用 |
|--------|----------------|------------------|
| `image` | 正常生成图片方向探索 | 降级为 HTML 方向探索，告知用户："无图片生成工具，改用 HTML 方向探索，视觉氛围表现力会受限" |
| `html` | 不受影响（不调用图片工具） | 不受影响 |

### 图片生成工具检测

仅当主素材判定为 `image` 时才需要检测。按以下三段式规则识别 runtime 中可用的图片生成工具：

1. **关键词命中**：工具名或描述含 `generate` / `create` / `draw` / `render` / `paint` / `image` / `picture` 之一
2. **排除分析类**：工具名或描述含 `analyze` / `extract` / `ocr` / `describe` / `diff` / `read` / `recognize` 之一，即使含 `image` 也排除（如 `analyze_image` 是分析工具而非生成工具）
3. **探测兜底**：若前两步无定论，以最小参数试调用，检查返回值是否为图片 URL/路径（而非文本描述）

三段式任一步命中即判定为图片生成工具；全部不命中则视为无此工具，按上表降级。

---

## Phase 2.5a：方向探索（fork-join 并行）

> 适用：创作者模式需要方向探索的场景。翻译者模式跳过本节，走「翻译者模式：直接复刻」。

### 设计原则：方向要有不同的"侧重"，而非不同的"风格浓度"

三个方向不应只是"保守/平衡/激进"的同轴滑动——那样往往只换来配色或留白的微调，三份产物高度相似。每个方向应该回答一个**不同的设计问题**、主导一个**不同的设计维度**（信息架构 / 布局模式 / 信息密度 / 视觉气质），让用户真正在"不同的设计思路"之间做选择。

### 三方向侧重定义

默认采用以下三种设计侧重，每个方向有明确的设计目标、主变量与驱动要素（完整定义含 prompt 骨架与差异化关键句，见下方「默认方向定义库」）：

| 方向 | 设计侧重 | 回答的设计问题 | 主变量 |
|------|---------|---------------|--------|
| **A · 信息优先** | 信息密度与任务效率 | 如何让用户在一屏内最高效地获取与操作信息？ | 信息密度 + 布局 |
| **B · 任务优先** | 任务引导与认知减负 | 如何让用户不被信息淹没、顺畅完成核心任务？ | 信息层级 + 焦点 |
| **C · 体验优先** | 视觉表现与品牌共鸣 | 如何让界面在视觉与情感上打动用户、传递品牌？ | 视觉气质 + 配色 |

**按需定制：** 若 Phase 2 的设计分析浮现了更贴合本需求的设计张力（如"列表 vs 卡片"、"桌面效率 vs 移动优先"、"数据展示 vs 操作引导"），UX 可替换默认侧重，改为三个**针对该需求的设计假设**。须满足：① 三个侧重互为不同维度；② 每个侧重能一句话说清"它优化的是什么"。

### 并行生成策略（子代理 fork-join）

三个方向相互独立，**并行生成**而非串行。

#### model 与方向解耦

**核心设计：方向是需求层概念，model 是基础设施层概念，两者解耦。**

- **方向定义**（设计哲学、主变量、prompt 骨架、差异化关键句）全部在本文件的「默认方向定义库」中，是 UX 方法论的一部分
- **model 清单**在 `rdd-ux/ux_subagent.json`，是用户配置的基础设施——声明了哪些 subagent 执行器可用、各自绑定哪个 model
- **agent 定义**（`.opencode/agent/ux-mockup-{a,b,c}.md`）是纯执行器：只绑 model + 通用生成指令，**不含任何方向定义**。dispatch 时由 UX 把方向简报（含完整生成指令）注入

UX 派遣时做一次"方向 → 执行器"的匹配：按方向的 capability 画像（结构严谨/均衡/创意）从 `ux_subagent.json` 的执行器池里挑最匹配的。默认匹配见下表，UX 可按需求调整。

| 方向（默认） | capability 画像 | 默认绑定的执行器（见 ux_subagent.json） |
|--------------|----------------|----------------------------------------|
| A · 信息优先 | 结构严谨 | `ux-mockup-a` |
| B · 任务优先 | 均衡表达 | `ux-mockup-b` |
| C · 体验优先 | 创意表现 | `ux-mockup-c` |

> **为何绑定不同 model**：同一个 LLM 即便靠 prompt 区分方向，也容易在审美惯性下趋同。不同 model 的训练分布差异天然产生风格分化。叠加独立 context + 调高 temperature，从模型层而非仅 prompt 层保障差异化。具体 model 名在 `ux_subagent.json` 配置，换 provider 时改 json + 同步 agent 定义即可，方向定义不动。

#### fork-join 流程

1. **读 `ux_subagent.json`** 确认可用执行器。若条目 <3，向用户提示"可用 model 不足 3 个，部分方向将复用同一 model，差异化退化"并请求确认
2. **构造方向简报**：UX 基于「默认方向定义库」（或本次定制的方向）为每个方向生成一份完整简报——设计目标 + 主变量 + 驱动要素 + 来自 Phase 2 的共享参数 + **本次主素材类型（image / html）** + 输出路径 + **完整生成指令**（image 的 prompt 骨架 / html 的生成约束 / 差异化关键句，从方向定义库直接取）
3. **并行分发**：一次性派发 3 个子代理（Task 工具），`subagent_type` 指定匹配到的执行器名（默认 ux-mockup-a/b/c），`prompt` 传入对应方向简报。每个子代理独立完成"构造产出 → 调用工具或生成 HTML → 存储到指定路径 → 返回一句话视觉特征"
4. **汇聚**：3 个子代理全部返回后，UX 汇总，生成 `manifest.json` 并复制对比框架模板为 `index.html`

**UX 派遣单（每个子代理收到的 dispatch 输入）：**

```
## 方向简报
- 方向：[A 信息优先 / B 任务优先 / C 体验优先 / 本次定制方向名]
- 设计目标：[一句话]
- 主变量：[信息密度 / 信息层级 / 视觉气质]
- 驱动要素：[布局、配色、风格关键词]
- 共享参数：内容领域=[...]、响应式目标=[...]、Phase 2 配色方向=[...]、设计规格草案要点=[...]

## 生成指令（image 素材）
[完整 prompt 骨架，见「默认方向定义库」对应方向，逐字填入后传给子代理]

## 生成指令（html 素材）
[本方向的视觉气质对齐要求 + 通用 html 约束（见下）]

## 约束
- 输出路径：[images/direction-a-info-density.png 或 direction-a-info-density.html]
- 仅生成 1 份产物，严格围绕本方向侧重，不向其他方向趋同
- image：分辨率 ≥ 1024×768，重点是布局比例、配色氛围、视觉层次
- html：内联 CSS、CSS 自定义属性 Token、真实内容、含默认态与 hover 态
```

> 子代理执行器（`.opencode/agent/ux-mockup-*.md`）已内置通用生成约束（内联 CSS、Token、真实内容等），dispatch 简报只需传方向专属的 prompt 骨架与差异化关键句，无需重复通用约束。

### 默认方向定义库

> 本节是方向定义的**单一真相源**。子代理执行器不持有方向知识，UX 派遣时从这里取完整生成指令注入 dispatch 简报。换 provider / 改 model 不动本节；要调整设计方向才动本节。

#### 方向 A · 信息优先

- **设计哲学**：如何让用户在一屏内最高效地获取与操作信息？
- **设计目标**：信息密度与任务效率
- **主变量**：信息密度 + 布局
- **视觉气质**：工具感、专业、克制
- **布局倾向**：高密度（dashboard / 多栏网格）、紧凑信息组织、数据可视化突出
- **配色倾向**：工具感专业配色（蓝灰 / 中性），最小化装饰
- **差异化关键句**：`Maximize information density and data visibility, dense grid, minimal decoration, utility-first professional aesthetic.`

**image 素材 prompt 骨架：**
```
A professional [内容领域] web UI design.
Layout: dense multi-column grid / dashboard layout.
Information density: dense.
Visual style: utility-first, minimal decoration, professional aesthetic.
Color palette: [Phase 2 配色方向 × 工具感气质，蓝灰/中性].
Designed for [响应式目标]. High fidelity UI mockup, screen design.
[差异化关键句]
```
重点：布局比例、配色氛围、信息层级；UI 文字允许近似/占位；避免过于艺术化。

**html 素材方向要求：** 视觉气质对齐"紧凑、信息密集、工具感"。

#### 方向 B · 任务优先

- **设计哲学**：如何让用户不被信息淹没、顺畅完成核心任务？
- **设计目标**：任务引导与认知减负
- **主变量**：信息层级 + 焦点
- **视觉气质**：清晰、温和、聚焦
- **布局倾向**：聚焦式 / 渐进式布局（主操作区放大居中）、清晰视觉层级、适度留白、主次分明
- **配色倾向**：引导性配色（主操作区视觉突出，其余克制）
- **差异化关键句**：`Clear visual hierarchy guiding the primary task, prominent main action area, progressive disclosure, calm and focused.`

**image 素材 prompt 骨架：**
```
A professional [内容领域] web UI design.
Layout: focused / progressive layout with prominent main action area.
Information density: focused.
Visual style: clear hierarchy, progressive disclosure, calm and focused.
Color palette: [Phase 2 配色方向 × 引导性气质，主操作区突出].
Designed for [响应式目标]. High fidelity UI mockup, screen design.
[差异化关键句]
```
重点：视觉层级、主操作区焦点、阅读路径；UI 文字允许近似/占位；避免过于艺术化。

**html 素材方向要求：** 视觉气质对齐"聚焦、层级清晰、温和引导"。

#### 方向 C · 体验优先

- **设计哲学**：如何让界面在视觉与情感上打动用户、传递品牌？
- **设计目标**：视觉表现与品牌共鸣
- **主变量**：视觉气质 + 配色
- **视觉气质**：富表现力、有温度、品牌驱动
- **布局倾向**：富表现力布局（hero / 大留白）、大胆配色或质感、插画 / 渐变 / 动效暗示
- **配色倾向**：差异化视觉语言（可含深色模式、渐变、品牌色大胆运用）
- **差异化关键句**：`Expressive and brand-driven, generous whitespace, bold color and texture, immersive hero, distinctive visual language.`

**image 素材 prompt 骨架：**
```
A professional [内容领域] web UI design.
Layout: expressive layout with immersive hero, generous whitespace.
Information density: spacious.
Visual style: bold color, texture, brand-driven, distinctive visual language.
Color palette: [Phase 2 配色方向 × 富表现力气质，可含渐变/深色].
Designed for [响应式目标]. High fidelity UI mockup, screen design.
[差异化关键句]
```
重点：视觉气质、配色氛围、品牌表现力；UI 文字允许近似/占位；可在保证产品落地感的前提下适度艺术化。

**html 素材方向要求：** 视觉气质对齐"富表现力、大留白、品牌驱动"，可使用渐变、动效暗示（CSS transition/animation）、深色模式等差异化手法。

### 方向定制（按需）

默认三方向覆盖大多数场景。若 Phase 2 的设计分析浮现了更贴合本需求的设计张力（如"列表 vs 卡片"、"桌面效率 vs 移动优先"、"数据展示 vs 操作引导"），UX 可替换默认侧重，改为三个**针对该需求的设计假设**。须满足：① 三个侧重互为不同维度；② 每个侧重能一句话说清"它优化的是什么"；③ 为每个定制方向补齐上面的完整定义（哲学/目标/主变量/prompt 骨架/差异化关键句）。

### 子代理配置维护

> 本节定义 agent 配置的同步机制。真相源是 `rdd-ux/ux_subagent.json`，同步由脚本 `rdd-engine/scripts/sync-ux-subagents.cmd` 自动完成，UX 不手改 agent 定义文件。

**同步脚本管什么：**

| 操作 | 触发条件 | 脚本动作 |
|------|---------|---------|
| **Create** | `agents` 有、磁盘无对应 .md | 从内嵌模板生成 agent 文件，正文统一，加入 `managed` 列表 |
| **Update** | `agents` 有、磁盘有、但 model/temperature 不一致 | 只替换 frontmatter 的 model/temperature 行，正文不动 |
| **Delete** | `managed` 有、`agents` 无 | 删 agent 文件，从 `managed` 移除 |
| **Orphan 警告** | 磁盘有、`managed` 与 `agents` 均无 | 警告，不自动删（防误删用户手建 agent） |

> `managed` 列表是脚本的所有权记录：只有曾由脚本创建过（在 `managed` 里）的 agent 才允许被脚本删除。这是防止误删用户手建 agent 的安全机制。

**何时运行脚本：**
- 首次使用 mockup 生成前（确保配置就绪）
- 用户明确告知换了 provider / model
- `ux_subagent.json` 被修改后（UX Read 时发现不一致）

**运行方式：**

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\sync-ux-subagents.cmd"
```

UX 调用后读取脚本输出：
- **无变更** → 配置已是最新，继续 fork-join 流程
- **有变更** → 告知用户"agent 配置已变更（列出 created/updated/deleted），需**重启 opencode** 才能生效"，等待用户重启后再进入 mockup 生成
- **有 orphan 警告** → 向用户报告，询问是否纳入管理（加入 `managed`）或手动清理

**干跑预检（可选）：** 加 `-WhatIf` 参数只报告不执行，用于 UX 在不确定变更范围时预检：

```powershell
& "$rdd\scripts\sync-ux-subagents.cmd" -WhatIf
```

**UX 不手改 agent 文件：** agent 定义（`.opencode/agent/ux-mockup-*.md`）由脚本全权管理——正文是通用执行器模板（固化在脚本内），frontmatter 由脚本从 json 同步。UX 手改会被下次同步覆盖。唯一允许 UX 手改的是 `ux_subagent.json`（用户配置可用 model）。

### 产物命名与存储

- **数量**：3 份（每方向 1 份，并行生成）
- **存储目录**：`.rdd/changes/archive/.../design/mockups/`（html）或其下 `images/`（image）
- **命名**：`direction-{x}-{focus}`（x 为 a/b/c；`{focus}` 为该方向侧重关键词的英文 slug，如 `info-density` / `task-focus` / `experience`）。扩展名按素材类型：`.png` 或 `.html`

---

## 翻译者模式：直接 HTML 复刻

用户提供参考图时，视觉方向已由参考图确定，**无需再做方向探索**。直接进入精确复刻：

1. 用视觉分析工具（按 `visual-analysis-guide.md` 五步法）分解参考图，提取 Token / 布局 / 组件 / 信息层级（标注置信度）
2. 基于提取参数生成 **1 份 HTML**（`reference-mockup.html`），精确对齐参考图
3. 进入 Phase 2.5b 的迭代流程与用户确认

> 翻译者模式不派发方向探索子代理，产物为单方向 HTML。若用户主动要求"基于参考图给我几个变化方向"，再切换到创作者模式的 fork-join 流程。

---

## Phase 2.5b：精确实现（HTML）

方向探索选定后，进入精确实现。按选定方向的**源素材类型**分支处理：

### 分支一：源素材为 image（图片方向探索）

用户选定图片方向后，用视觉分析工具（通用图像分析 MCP，如 `analyze_image`，按 runtime 可用工具选择）分析选定的 PNG，提取参数：

| 提取维度 | 具体内容 | 参考 |
|---------|---------|------|
| 配色 | 主色、辅助色、背景色、文字色（HEX 值） | 参考 `visual-analysis-guide.md` Step 2 |
| 布局比例 | 各区域占比、最大宽度 | 参考 Step 1 |
| 视觉风格 | 圆角大小、阴影强度、间距密度 | 参考 Step 2 |
| 信息层级 | 视觉焦点、阅读路径 | 参考 Step 5 |

> 提取时必须标注置信度（🟢高/🟡中/🔴低），与 `visual-analysis-guide.md` 的置信度机制一致。

基于提取参数 + Phase 2 设计规格草案，生成对齐选定方向的 HTML。

### 分支二：源素材为 html（HTML 方向探索）

选定方向的 HTML 已是一份可用的实现基础，Phase 2.5b 是对其**迭代精修**而非从图片重建：跳过参数提取，直接进入迭代流程（用户反馈 → 局部调整）。该 HTML 即为 `final-v1.html` 起点。

### HTML mockup 生成约束

- 独立 HTML 文件，内联 `<style>`，用 CSS 自定义属性（`var(--token)`）实现三层 Token
- 真实内容（从 requirement.md 的实际数据，非 Lorem Ipsum）
- 应用 Phase 2 的三层 Token 系统（Primitive → Semantic → Component）
- 与选定方向的视觉方向对齐（配色、布局、风格一致）
- 包含核心组件的默认态和 hover 态（CSS `:hover`）

**技术栈适配说明：**

mockup 统一用内联 CSS，不依赖外部 CDN 或框架运行时——保证浏览器打开即可正确渲染，DEV 能直接 inspect 具体值。Token 输出格式（spec-template.md 的规格文档）仍按项目实际技术栈适配。

若项目用 Tailwind CSS，在 HTML 元素上以注释形式标注等效 Tailwind 类名（如 `<!-- class="bg-primary-500 px-4" -->`），供 DEV 参考；但渲染不依赖 CDN。

**命名与存储：**
- 文件：`direction-{x}-{name}.html`（x 为 a/b/c；翻译者模式为 `reference-mockup.html`）
- 目录：`.rdd/changes/archive/.../design/mockups/`

### 一致性校验（仅 image 源素材）

生成 HTML 后，用视觉分析工具对比 HTML 渲染截图与选定图片：

| 检查维度 | 通过标准 | 不通过时 |
|---------|---------|---------|
| 配色一致 | 主色色值差异 < 10%（HSL 色相偏差） | 调整 HTML 的 Token 值重新生成 |
| 布局比例一致 | 各区域占比偏差 < 15% | 调整 HTML 的 flex/grid 参数 |
| 视觉密度一致 | 间距/字号比例在同一档位 | 调整 HTML 的 spacing scale |

> 校验不要求像素级一致（图片本身不精确），只要求"视觉方向一致"。

### 迭代流程

```
用户在浏览器中查看 HTML mockup
  │
  ├── 满意 → 定稿为 final.html，进入 Phase 3
  │
  └── 需调整 → 用户在 CLI 中反馈
      │
      ├── "间距再大一点" → 调整 spacing Token 重新生成
      ├── "主色偏蓝" → 调整 color Token 重新生成
      ├── "这个组件布局不对" → 调整结构重新生成
      └── ...（每轮反馈后重新生成 HTML，浏览器刷新即可看变化）
```

**迭代约束：**
- 每轮迭代只调整用户反馈的部分，不重写整个 HTML
- 保留前一轮的 HTML 作为版本（`final-v1.html` / `final-v2.html`），便于回退
- 用户确认满意后，最终版重命名为 `final.html`

---

## 对比框架（固定模板 + manifest.json）

方向探索产出的多份素材通过**固定模板**统一对比展示，UX 不再每次重写框架 HTML。

### 模板位置

`rdd-ux/templates/mockup-gallery.html`（内联 CSS + JS，支持 `image`(`<img>`) 与 `html`(`<iframe>`) 两种卡片混排）。

### UX 产出步骤

1. **复制模板**为对比页：`cp rdd-ux/templates/mockup-gallery.html <mockups>/index.html`
2. **生成 `manifest.json`**（同目录），结构如下：

```json
{
  "title": "视觉稿方向对比",
  "hint": "选择最满意的方向后，在 CLI 中告知 UX（如\"选 B\"或\"选任务优先方案\"）",
  "variants": [
    {
      "id": "a",
      "name": "A · 信息优先",
      "desc": "[一句话视觉特征，来自子代理返回]",
      "type": "image",
      "src": "images/direction-a-info-density.png",
      "focus": "info-density"
    },
    {
      "id": "b",
      "name": "B · 任务优先",
      "desc": "[一句话视觉特征]",
      "type": "html",
      "src": "direction-b-task-focus.html",
      "focus": "task-focus"
    },
    {
      "id": "c",
      "name": "C · 体验优先",
      "desc": "[一句话视觉特征]",
      "type": "image",
      "src": "images/direction-c-experience.png",
      "focus": "experience"
    }
  ]
}
```

### 数据读取（模板已内置，无需 UX 处理）

模板 JS 按以下顺序读取 manifest：
1. 优先读取内嵌的 `<script id="rdd-manifest" type="application/json">`（file:// 双击打开可靠）
2. 缺失则 `fetch('./manifest.json')`（需 http server）

**推荐**：UX 把 `manifest.json` 内容同时粘贴进 `index.html` 的 `<script id="rdd-manifest">` 标签，确保用户直接双击即可查看，无需启动 server。`manifest.json` 文件仍保留（供归档与工具读取）。

### 交互能力（模板已内置）

- 卡片"选择此方向"→ 高亮 + 底部状态条提示用户回 CLI 告知选择
- 布局切换：网格（3 列）/ 单列大图
- 全屏查看

生成后告知用户在浏览器中打开 `index.html` 对比，并在 CLI 中告知选择。

---

## 文件组织

```
.rdd/changes/archive/.../design/
├── {name}-ux.md                    # 设计规格（权威参数）
└── mockups/                         # 视觉稿目录
    ├── images/                      # 图片生成产物（仅 image 素材时）
    │   ├── direction-a-info-density.png
    │   ├── direction-b-task-focus.png
    │   ├── direction-c-experience.png
    │   └── reference.png            # 选定方向的图片（视觉氛围参考，image 源时）
    ├── direction-a-info-density.html
    ├── direction-b-task-focus.html
    ├── direction-c-experience.html
    ├── reference-mockup.html        # 翻译者模式单方向复刻产物
    ├── final-v1.html                # 迭代版本（如有）
    ├── final-v2.html                # 迭代版本（如有）
    ├── final.html                   # 定稿
    ├── manifest.json                # 对比页数据源
    └── index.html                   # 对比页（复制自模板，内嵌 manifest）
```

> `index.html` 是模板副本（框架固定），`manifest.json` 是数据源。`final.html` 是基于选定方向精确实现的 HTML mockup，是 DEV 的主要参考。image 源素材时 `reference.png` 作为视觉氛围参考归档。

---

## 与其他 Phase 的衔接

| 上游 | 衔接点 |
|------|--------|
| Phase 2（设计创建） | 设计规格草案（Token + 布局 + 组件 + 内容策略）作为 Phase 2.5 的输入 |

| 下游 | 衔接点 |
|------|--------|
| Phase 3（设计规格定稿） | `final.html` 的参数回写到规格文档；`reference.png`（image 源时）作为视觉氛围参考归档 |
| Phase 4（归档交接） | mockup 路径写入设计规格文档的"视觉稿参考"章节 |
| DEV | mockup 是视觉参考，规格文档是精确参数源。实现时参考 mockup 理解视觉效果，具体参数以规格文档为准 |

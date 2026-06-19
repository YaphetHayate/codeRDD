# 视觉稿生成方法论

本文件定义 UX Skill Phase 2.5 的完整执行流程——将设计规格草案转化为用户可选、可迭代的视觉稿，并在确认后产出 DEV 可参考的精确实现。

## 设计理念

**纯文字规格传达不了"用起来什么感觉"，纯 HTML 传达不了"好不好看"。**

本方法论用两阶段混合解决：
- **图片生成**负责视觉方向探索（解决"好不好看、满不满意"）
- **HTML 生成**负责精确参数实现（解决"DEV 能不能 inspect 具体值"）

两阶段串行而非并行，避免产物不一致。

---

## 工具检测与降级策略

进入 Phase 2.5 时，先检测当前 runtime 是否有可用的图片生成工具。

### 检测方式

按以下三段式规则识别 runtime 中可用的图片生成类工具：

1. **关键词命中**：工具名或描述含 `generate` / `create` / `draw` / `render` / `paint` / `image` / `picture` 之一
2. **排除分析类**：工具名或描述含 `analyze` / `extract` / `ocr` / `describe` / `diff` / `read` / `recognize` 之一，即使含 `image` 也排除（如 `analyze_image` 是分析工具而非生成工具）
3. **探测兜底**：若前两步无定论，以最小参数试调用，检查返回值是否为图片 URL/路径（而非文本描述）

三段式任一步命中即判定为图片生成工具；全部不命中则视为无此工具。

### 分支

| 检测结果 | 流程 | 用户告知 |
|---------|------|---------|
| 有图片生成工具 | 完整双阶段（2.5a + 2.5b） | 告知将生成 3 个方向供选择 |
| 无图片生成工具 | 降级为纯 HTML（跳过 2.5a） | 明确告知：无图片生成工具，视觉质量受限，建议配置图片生成 MCP 以获得更好体验 |

---

## Phase 2.5a：方向探索（图片生成）

### 设计原则：方向要有不同的"侧重"，而非不同的"风格浓度"

三个方向不应只是"保守/平衡/激进"的同轴滑动——那样往往只换来配色或留白的微调，三张图高度相似。每个方向应该回答一个**不同的设计问题**、主导一个**不同的设计维度**（信息架构 / 布局模式 / 信息密度 / 视觉气质），让用户真正在"不同的设计思路"之间做选择。

### 三方向侧重定义

默认采用以下三种设计侧重，每个方向有明确的设计目标、主变量与 prompt 驱动要素：

| 方向 | 设计侧重 | 回答的设计问题 | 主变量 | prompt 驱动要素 |
|------|---------|---------------|--------|----------------|
| **A · 信息优先** | 信息密度与任务效率 | 如何让用户在一屏内最高效地获取与操作信息？ | 信息密度 + 布局 | 高密度布局（dashboard / 多栏网格）、紧凑信息组织、数据可视化突出、工具感专业配色（蓝灰/中性）、最小化装饰 |
| **B · 任务优先** | 任务引导与认知减负 | 如何让用户不被信息淹没、顺畅完成核心任务？ | 信息层级 + 焦点 | 聚焦式/渐进式布局（主操作区放大居中）、清晰视觉层级、适度留白、主次分明、引导性配色 |
| **C · 体验优先** | 视觉表现与品牌共鸣 | 如何让界面在视觉与情感上打动用户、传递品牌？ | 视觉气质 + 配色 | 富表现力布局（hero / 大留白）、大胆配色或质感、插画/渐变/动效暗示、差异化视觉语言（可含深色模式） |

**按需定制：** 若 Phase 2 的设计分析浮现了更贴合本需求的设计张力（如"列表 vs 卡片"、"桌面效率 vs 移动优先"、"数据展示 vs 操作引导"），UX 可替换默认侧重，改为三个**针对该需求的设计假设**。须满足：① 三个侧重互为不同维度；② 每个侧重能一句话说清"它优化的是什么"。

### 并行生成策略（子代理分发）

三个方向相互独立，**并行生成**而非串行，采用 fork-join 模式：

1. **构造侧重简报**：UX 基于上表为每个方向生成一份侧重简报——设计目标 + 主变量 + prompt 驱动要素 + 来自 Phase 2 的共享参数（内容领域、配色方向、响应式目标）
2. **并行分发**：一次性派发 3 个子代理（Task 工具，`subagent_type=general`），每个子代理收到一份侧重简报，独立完成"构造 prompt → 调用图片生成工具 → 返回图片路径 + 一句话视觉特征"
3. **汇聚**：3 个子代理全部返回后，UX 汇总路径，生成对比索引页

> **为何用子代理而非直接并行工具调用**：每个方向的 prompt 构造本身就是有侧重的独立工作（选词、调参、强化本方向的差异点）。子代理的独立上下文让每个方向被认真对待，从执行层面避免"三张图共用一个模板、只换关键词"的同质化——这正是"侧重差异化"的保障。

**子代理任务模板**（每个子代理收到的指令骨架）：

```
你是视觉稿生成子代理。请基于以下侧重简报生成一张 UI mockup 图片。

## 侧重简报
- 方向：[A 信息优先 / B 任务优先 / C 体验优先]
- 设计目标：[一句话]
- 主变量：[信息密度 / 信息层级 / 视觉气质]
- prompt 驱动要素：[布局、配色、风格关键词]
- 共享参数：内容领域=[...]、响应式目标=[...]、Phase 2 配色方向=[...]

## prompt 结构（按本方向侧重填充）
A professional [内容领域] web UI design.
Layout: [由侧重决定的布局类型]
Information density: [A=dense / B=focused / C=spacious]
Visual style: [本方向风格关键词]
Color palette: [Phase 2 配色方向 × 本方向气质]
Designed for [响应式目标]. High fidelity UI mockup, screen design.
方向侧重强化句（决定差异的关键）：
- A：「Maximize information density and data visibility, dense grid, minimal decoration, utility-first professional aesthetic.」
- B：「Clear visual hierarchy guiding the primary task, prominent main action area, progressive disclosure, calm and focused.」
- C：「Expressive and brand-driven, generous whitespace, bold color and texture, immersive hero, distinctive visual language.」

## 约束
- 仅生成 1 张图片，分辨率 ≥ 1024×768
- 重点是布局比例、配色氛围、视觉层次
- UI 文字不要求精确，允许近似/占位
- 避免过于艺术化、脱离实际产品视觉
- 严格围绕本方向"设计侧重"，不向其他方向趋同

## 输出
- 调用图片生成工具生成图片
- 存储到：.rdd/changes/archive/.../design/mockups/images/direction-{x}-{focus}.png
- 返回：图片文件名 + 一句话说明本方向视觉特征（供索引页使用）
```

### 图片生成约束

- **分辨率**：按工具能力选择最高可用，建议至少 1024×768 以上
- **数量**：3 张（每方向 1 张，并行生成）
- **存储路径**：`.rdd/changes/archive/.../design/mockups/images/`
- **命名**：`direction-a-{focus}.png` / `direction-b-{focus}.png` / `direction-c-{focus}.png`（`{focus}` 为该方向侧重关键词的英文 slug，如 `info-density` / `task-focus` / `experience`）

### 对比索引页生成

生成 `index.html` 供用户在浏览器中对比：

```html
<!-- index.html 结构 -->
<!DOCTYPE html>
<html>
<head><title>视觉稿方向对比</title>
<style>
  body { margin: 0; padding: 24px; background: #f5f5f5; font-family: sans-serif; }
  h1 { text-align: center; margin-bottom: 32px; }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; max-width: 1600px; margin: 0 auto; }
  .variant { background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .variant img { width: 100%; display: block; }
  .variant-info { padding: 16px; }
  .variant-name { font-size: 18px; font-weight: 600; margin: 0 0 8px; }
  .variant-desc { font-size: 14px; color: #6b7280; margin: 0; }
</style>
</head>
<body>
  <h1>视觉稿方向对比</h1>
  <p style="text-align:center;color:#6b7280;">选择最满意的方向后，在 CLI 中告知 UX（如"选 B 方案"或"选任务优先方案"）</p>
  <div class="grid">
    <div class="variant">
      <img src="images/direction-a-info-density.png" alt="信息优先方案">
      <div class="variant-info">
        <p class="variant-name">A · 信息优先</p>
        <p class="variant-desc">[具体差异描述]</p>
      </div>
    </div>
    <!-- B、C 同上结构 -->
  </div>
</body>
</html>
```

生成后告知用户在浏览器中打开 `index.html` 对比，并在 CLI 中告知选择。

---

## Phase 2.5b：精确实现（HTML 生成）

### 前置：图片参数提取

用户选定方向后，用视觉分析工具（通用图像分析 MCP，如 `analyze_image`，按 runtime 可用工具选择）分析选定的 PNG，提取以下参数：

| 提取维度 | 具体内容 | 参考 |
|---------|---------|------|
| 配色 | 主色、辅助色、背景色、文字色（HEX 值） | 参考 `visual-analysis-guide.md` Step 2 |
| 布局比例 | 各区域占比、最大宽度 | 参考 Step 1 |
| 视觉风格 | 圆角大小、阴影强度、间距密度 | 参考 Step 2 |
| 信息层级 | 视觉焦点、阅读路径 | 参考 Step 5 |

> 提取时必须标注置信度（🟢高/🟡中/🔴低），与 `visual-analysis-guide.md` 的置信度机制一致。

### HTML mockup 生成

基于提取参数 + Phase 2 设计规格草案，生成对齐选定方向的 HTML：

**生成约束：**
- 独立 HTML 文件，内联 `<style>`，用 CSS 自定义属性（`var(--token)`）实现三层 Token
- 真实内容（从 requirement.md 的实际数据，非 Lorem Ipsum）
- 应用 Phase 2 的三层 Token 系统（Primitive → Semantic → Component）
- 与选定图片的视觉方向对齐（配色、布局、风格一致）
- 包含核心组件的默认态和 hover 态（CSS `:hover`）

**技术栈适配说明：**

mockup 统一用内联 CSS，不依赖外部 CDN 或框架运行时——保证浏览器打开即可正确渲染，DEV 能直接 inspect 具体值。Token 输出格式（spec-template.md 的规格文档）仍按项目实际技术栈适配。

若项目用 Tailwind CSS，在 HTML 元素上以注释形式标注等效 Tailwind 类名（如 `<!-- class="bg-primary-500 px-4" -->`），供 DEV 参考；但渲染不依赖 CDN。

**命名与存储：**
- 文件：`direction-{x}-{name}.html`（x 为 a/b/c）
- 目录：`.rdd/changes/archive/.../design/mockups/`

### 一致性校验

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

## 降级方案（无图片生成工具时）

### 纯 HTML 流程

跳过 Phase 2.5a，直接进入 HTML 生成：

1. 基于 Phase 2 设计规格草案，按三方向侧重（信息优先 / 任务优先 / 体验优先，或本次定制的三个设计假设）生成 3 个 HTML mockup
2. 生成 `index.html` 并排展示（用 iframe 嵌入 3 个 HTML）
3. 用户选择方向后，进入迭代精修（同 2.5b 的迭代流程）

**必须告知用户的限制：**
> 当前无图片生成工具，直接用 HTML 生成视觉稿。
> HTML 的视觉质量受限于 LLM 的前端能力，可能缺乏设计师的精致感。
> 建议配置图片生成 MCP（如 DALL-E / FLUX）以获得更好的视觉探索体验。

---

## 文件组织

```
.rdd/changes/archive/.../design/
├── {name}-ux.md                    # 设计规格（权威参数）
└── mockups/                         # 视觉稿目录
    ├── images/                      # 图片生成产物
    │   ├── direction-a-info-density.png
    │   ├── direction-b-task-focus.png
    │   ├── direction-c-experience.png
    │   └── reference.png            # 选定方向的图片（视觉氛围参考）
    ├── direction-a-info-density.html
    ├── direction-b-task-focus.html
    ├── direction-c-experience.html
    ├── final-v1.html                # 迭代版本（如有）
    ├── final-v2.html                # 迭代版本（如有）
    ├── final.html                   # 定稿
    └── index.html                   # 对比索引页
```

> `images/reference.png` 是用户选定方向的图片，作为视觉氛围参考归档。`final.html` 是基于该方向精确实现的 HTML mockup，是 DEV 的主要参考。

---

## 与其他 Phase 的衔接

| 上游 | 衔接点 |
|------|--------|
| Phase 2（设计创建） | 设计规格草案（Token + 布局 + 组件 + 内容策略）作为 Phase 2.5 的输入 |

| 下游 | 衔接点 |
|------|--------|
| Phase 3（设计规格定稿） | `final.html` 的参数回写到规格文档；`reference.png` 作为视觉氛围参考归档 |
| Phase 4（归档交接） | mockup 路径写入设计规格文档的"视觉稿参考"章节 |
| DEV | mockup 是视觉参考，规格文档是精确参数源。实现时参考 mockup 理解视觉效果，具体参数以规格文档为准 |

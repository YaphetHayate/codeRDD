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

### 图片生成 prompt 构造

从 Phase 2 的设计规格草案提取以下维度，构造结构化 prompt：

```
图片生成 prompt 模板：

A professional [内容领域] web UI design, [布局类型],
[视觉风格关键词], [配色方向] color palette,
designed for [响应式目标], clean and modern aesthetic,
high fidelity UI mockup, screen design.

布局类型选项：sidebar + main content / single column centered / grid layout / dashboard / hero + features
视觉风格关键词：minimalist / modern / professional / friendly / bold / elegant
配色方向：[基于 Phase 2 的主色方向，如 blue-gray professional / warm energetic / dark premium]
内容领域：[从 requirement.md 推导，如 SaaS dashboard / e-commerce / admin panel]
响应式目标：desktop-first / mobile-first

重要约束：
- 重点是布局比例、配色氛围、视觉层次
- UI 中的文字不要求精确渲染，允许近似或占位
- 避免生成过于艺术化、脱离实际产品视觉的图像
```

### 三方向定义

生成 3 个差异明显的方向，每个方向调整 prompt 的关键参数：

| 方向 | 定位 | prompt 差异 |
|------|------|------------|
| **保守** | 贴近行业主流，低风险快速交付 | 标准布局 + 安全配色（蓝/灰）+ minimalist |
| **平衡** | 主流基础上加入 1-2 个设计亮点 | 标准布局 + 亮点配色 + modern + 一个视觉特色（如渐变/卡片阴影/动效暗示） |
| **激进** | 大胆探索，差异化竞争 | 非常规布局 + 大胆配色 + bold + 强视觉特征（如深色模式/大面积留白/非常规网格） |

### 图片生成约束

- **分辨率**：按工具能力选择最高可用，建议至少 1024×768 以上
- **数量**：3 张（每方向 1 张）
- **存储路径**：`.rdd/changes/archive/.../design/mockups/images/`
- **命名**：`direction-a-conservative.png` / `direction-b-balanced.png` / `direction-c-bold.png`

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
  <p style="text-align:center;color:#6b7280;">选择最满意的方向后，在 CLI 中告知 UX（如"选平衡方案"）</p>
  <div class="grid">
    <div class="variant">
      <img src="images/direction-a-conservative.png" alt="保守方案">
      <div class="variant-info">
        <p class="variant-name">A · 保守方案</p>
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

1. 基于 Phase 2 设计规格草案，按三方向（保守/平衡/激进）生成 3 个 HTML mockup
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
    │   ├── direction-a-conservative.png
    │   ├── direction-b-balanced.png
    │   ├── direction-c-bold.png
    │   └── reference.png            # 选定方向的图片（视觉氛围参考）
    ├── direction-a-conservative.html
    ├── direction-b-balanced.html
    ├── direction-c-bold.html
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

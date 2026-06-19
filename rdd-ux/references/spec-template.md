# 设计规格产出模板

本文件定义 UX Skill 产出物的标准格式。Phase 3 产出设计规格时，必须按此模板格式化。

## 设计规格文档结构

```markdown
# 设计规格 — [项目/页面名称]

---
requirement_id: [需求编号]
priority: 高/中/低
depends_on: []
status: active
role: ux
design_date: YYYY-MM-DD
source_mode: 翻译者 / 创作者 / 混合
---

## 需求覆盖映射

| 需求 ID | 本文档负责范围 | 对应章节 | 关联文档 |
|---------|--------------|---------|---------|
| [ID] | [UX 负责的范围] | [章节号] | design/{name}-cto.md (如有) |

---

## 1. 设计 Token 系统

> 采用三层结构：Primitive（原始值）→ Semantic（语义化）→ Component（组件级）。
> 原始值是数据的唯一来源，语义层按角色命名，组件层绑定具体组件。
> 改原始值即全局生效；改语义层即调整一类用途；改组件层即微调单个组件。

### 1.1 Primitive Tokens（原始值）

> 无语境的原始数据。按类型罗列，命名只描述值本身，不描述用途。

色彩调色板：

| Token | 值 | |
|-------|------|-|
| blue-100 | #DBEAFE | |
| blue-200 | #BFDBFE | |
| blue-500 | #3B82F6 | |
| blue-600 | #2563EB | |
| blue-700 | #1D4ED8 | |
| green-500 | #10B981 | |
| amber-500 | #F59E0B | |
| red-500 | #EF4444 | |
| gray-50 | #F9FAFB | |
| gray-100 | #F3F4F6 | |
| gray-200 | #E5E7EB | |
| gray-400 | #9CA3AF | |
| gray-500 | #6B7280 | |
| gray-700 | #374151 | |
| gray-900 | #111827 | |
| white | #FFFFFF | |

字体尺寸：

| Token | 值 |
|-------|------|
| font-size-display | 36px |
| font-size-h1 | 28px |
| font-size-h2 | 22px |
| font-size-h3 | 16px |
| font-size-body | 14px |
| font-size-body-sm | 13px |
| font-size-caption | 12px |
| font-weight-regular | 400 |
| font-weight-medium | 500 |
| font-weight-semibold | 600 |
| font-weight-bold | 700 |
| font-weight-extrabold | 800 |
| line-height-tight | 1.2 |
| line-height-normal | 1.5 |
| line-height-relaxed | 1.6 |

间距刻度（基准 4px）：

| Token | 值 |
|-------|------|
| space-1 | 4px |
| space-2 | 8px |
| space-3 | 12px |
| space-4 | 16px |
| space-6 | 24px |
| space-8 | 32px |
| space-10 | 40px |
| space-12 | 48px |
| space-16 | 64px |

圆角 / 阴影：

| Token | 值 |
|-------|------|
| radius-sm | 4px |
| radius-md | 6px |
| radius-lg | 8px |
| radius-xl | 12px |
| radius-full | 50% |
| shadow-sm | 0 1px 2px rgba(0,0,0,0.05) |
| shadow-md | 0 1px 3px rgba(0,0,0,0.1), 0 1px 2px rgba(0,0,0,0.06) |
| shadow-lg | 0 4px 6px rgba(0,0,0,0.07), 0 10px 15px rgba(0,0,0,0.1) |

字体族：
  主字体：[字体名], -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif
  代码字体：'SF Mono', 'Fira Code', 'Consolas', monospace

### 1.2 Semantic Tokens（语义化）

> 按角色命名，指向 Primitive。角色命名能熬过品牌重塑——`text-secondary` 永远有效，`gray-text` 换品牌色就失效。
> Semantic 层只指向 Primitive，不互相指向。

| Semantic Token | → Primitive | 用途说明 |
|----------------|------------|---------|
| color-action-primary | blue-500 | 主操作色（按钮、链接） |
| color-action-primary-hover | blue-600 | 主操作 hover |
| color-action-primary-active | blue-700 | 主操作 active |
| color-action-secondary | gray-200 | 次要操作 |
| color-bg-page | gray-50 | 页面背景 |
| color-bg-card | white | 卡片背景 |
| color-bg-input | white | 输入框背景 |
| color-text-primary | gray-900 | 主文字 |
| color-text-secondary | gray-500 | 次文字 |
| color-text-tertiary | gray-400 | 辅助文字 |
| color-text-placeholder | gray-400 | 占位文字 |
| color-text-on-action | white | 操作色上的文字 |
| color-border | gray-200 | 边框 |
| color-divider | gray-100 | 分割线 |
| color-success | green-500 | 成功 |
| color-warning | amber-500 | 警告 |
| color-error | red-500 | 错误 |
| color-info | blue-500 | 信息 |
| text-display | font-size-display / line-height-tight, font-weight-extrabold | 首页大标题 |
| text-h1 | font-size-h1 / line-height-tight, font-weight-bold | 页面标题 |
| text-h2 | font-size-h2 / line-height-tight, font-weight-semibold | 区块标题 |
| text-h3 | font-size-h3 / line-height-normal, font-weight-semibold | 小标题/卡片标题 |
| text-body | font-size-body / line-height-relaxed, font-weight-regular | 正文 |
| text-body-sm | font-size-body-sm / line-height-normal, font-weight-regular | 紧凑正文 |
| text-caption | font-size-caption / line-height-normal, font-weight-regular | 辅助信息 |
| text-button | font-size-body, font-weight-medium | 按钮文字 |
| text-overline | font-size-caption / 1.0, font-weight-semibold, letter-spacing: 0.05em | 标签文字 |
| spacing-xs | space-1 | 图标与文字间距 |
| spacing-sm | space-2 | 紧凑元素间距 |
| spacing-md | space-4 | 标准间距 |
| spacing-lg | space-6 | 区块内间距 |
| spacing-xl | space-8 | 区块间间距 |
| spacing-2xl | space-12 | 章节间距 |
| spacing-3xl | space-16 | 大章节间距 |
| border-default | 1px solid color-border | 默认边框 |
| border-focus | 2px solid color-action-primary | 聚焦边框 |

### 1.3 Component Tokens（组件级）

> 绑定具体组件的 Token，指向 Semantic 层。用于组件需要偏离全局默认值的场景。

| Component Token | → Semantic | 组件 · 属性 |
|-----------------|-----------|------------|
| button-primary-bg | color-action-primary | 主按钮 · 背景 |
| button-primary-bg-hover | color-action-primary-hover | 主按钮 · hover 背景 |
| button-primary-bg-active | color-action-primary-active | 主按钮 · active 背景 |
| button-primary-text | color-text-on-action | 主按钮 · 文字 |
| button-secondary-border | color-action-primary | 次按钮 · 边框 |
| card-bg | color-bg-card | 卡片 · 背景 |
| card-border | border-default | 卡片 · 边框 |
| card-radius | radius-lg | 卡片 · 圆角 |
| card-shadow | shadow-md | 卡片 · 阴影 |
| input-bg | color-bg-input | 输入框 · 背景 |
| input-border | border-default | 输入框 · 边框 |
| input-border-focus | border-focus | 输入框 · 聚焦边框 |

> 以上为示例。实际项目按组件清单逐个补充，每个组件至少有 bg / text / border / radius 四个 Component Token。

### 1.4 技术栈适配说明

[根据 Phase 1 识别的项目技术栈，说明三层 Token 如何映射到代码]

例如（Tailwind 项目）：
  Primitive 色彩映射到 tailwind.config.js 的 theme.extend.colors（如 blue-500: '#3B82F6'）
  Semantic 色彩映射为语义化别名（如 primary: { DEFAULT: 'var(--blue-500)', hover: 'var(--blue-600)' }）
  Component Token 在组件样式中通过 Tailwind 类名引用
  间距使用 Tailwind 内置间距（已对齐 4px 基准）

例如（CSS Modules 项目）：
  Primitive 定义为 :root 下的 CSS 自定义属性（--blue-500: #3B82F6）
  Semantic 引用 Primitive（--color-action-primary: var(--blue-500)）
  Component 引用 Semantic（--button-primary-bg: var(--color-action-primary)）

---

## 2. 内容策略

> 视觉设计只解决"长什么样"，内容策略解决"说什么、怎么说"。
> DEV 实现时需要知道每个场景用什么文案，不能自行编造。

### 2.1 语气与语调

产品语气：[专业权威 / 友好亲切 / 严谨克制 / 活泼有趣]

语调规则：

| 场景 | 语调 | 示例 |
|------|------|------|
| 常规操作 | [语气] | "[示例文案]" |
| 成功反馈 | [语气] | "[示例文案]" |
| 错误提示 | [语气，不指责用户] | "邮箱格式不正确，请检查后重试" |
| 空状态 | [语气，引导行动] | "还没有数据，[点击创建第一条]" |
| 危险操作确认 | [语气，强调后果] | "确认删除？此操作不可撤销" |

禁用表达：
- [如：禁止使用"您"，统一用"你"]
- [如：禁止使用感叹号]
- [如：禁止使用技术术语，如"异常终止"→"出了点问题"]

### 2.2 文案规范

| 场景 | 文案规则 | 示例 |
|------|---------|------|
| 主操作按钮 | 动词 + 名词，优先 ≤4 字 | "创建项目"、"提交表单" |
| 次要操作 | 约定用词 | "取消"、"返回"、"关闭" |
| 成功反馈 | [操作] + 成功 | "创建成功"、"保存成功" |
| 错误反馈 | 问题描述 + 解决方向 | "网络异常，请检查连接后重试" |
| 加载状态 | "加载中..." | 不用"请稍候" |
| 空状态标题 | 说明空原因 | "还没有项目" |
| 空状态引导 | 引导下一步 | "点击创建你的第一个项目" |
| 表单标签 | 名词，简洁 | "邮箱"、"密码"（不用"电子邮箱地址"） |
| 占位文字 | 提示输入格式 | "name@example.com" |
| 删除确认 | 强调不可逆 | "删除后无法恢复，确认删除？" |

### 2.3 信息层次

| 层次 | 角色 | 写作原则 |
|------|------|---------|
| 页面标题 | 概括页面核心内容 | 名词短语，≤12 字 |
| 区块标题 | 概括区块功能 | 名词短语，≤8 字 |
| 正文 | 传递具体信息 | 简洁，一句一意 |
| 辅助文字 | 补充说明 | 灰色弱化，不抢主信息焦点 |
| 操作文字 | 告知用户可做什么 | 动词开头，明确动作 |

---

## 3. 信息架构与用户流程

> DEV 交接最有效的产物之一（NN/g 数据）。让 DEV 理解页面间导航关系和用户完成任务的操作路径。

### 3.1 站点地图 / 页面导航

```
[页面导航图]

首页
├── 项目列表 ──→ 项目详情
│                 ├── 任务看板
│                 ├── 成员管理
│                 └── 设置
├── 数据统计
└── 个人设置
```

### 3.2 用户流程图

> 对每个核心场景，绘制用户从入口到完成目标的完整路径。

场景：[场景名称]

```
[入口页面]
  │
  ├─ 用户看到：[初始状态描述]
  │
  ├─ 操作：[动作]
  │  ├─ 前置条件：[什么情况下可操作]
  │  ├─ 反馈：[操作后的视觉变化]
  │  └─ 跳转/状态：[结果]
  │
  ├─ 操作：[动作]
  │  ├─ 异常分支：[异常情况]
  │  │  └─ 处理：[错误反馈 + 恢复路径]
  │  └─ 跳转/状态：[正常结果]
  │
  └─ [终点]：[目标达成]
```

场景：[另一个场景名称]
[同上格式]

---

## 4. 布局规格

### 4.1 页面布局

[ASCII 布局图]

```
┌─────────────────────────────────────────────┐
│                 Header (h: 64px)             │
├────────────┬────────────────────────────────┤
│            │                                │
│  Sidebar   │         Main Content           │
│  (240px)   │         (max-w: 1200px)        │
│            │                                │
│            │                                │
└────────────┴────────────────────────────────┘
```

布局实现方式：
  整体：flex / grid
  侧边栏：fixed / sticky / flex-shrink-0
  主内容：flex-grow-1 / auto

### 4.2 响应式规则

断点定义：
  --breakpoint-sm: 640px
  --breakpoint-md: 768px
  --breakpoint-lg: 1024px
  --breakpoint-xl: 1280px

| 断点 | 布局变化 |
|------|--------|
| ≥1280px | [桌面完整布局描述] |
| 1024-1280 | [平板横屏/小桌面布局变化] |
| 768-1024 | [平板竖屏布局变化] |
| 640-768 | [大手机布局变化] |
| <640px | [手机布局变化] |

---

## 5. 组件规格

### 5.1 [组件名 A]

用途：[一句话]

结构建议：
  <Container>
    <PrefixIcon />（可选）
    <Label />
    <SuffixIcon />（可选）
  </Container>

样式规则（引用 Component Token）：
  容器
    高度：[值]px
    内间距：[Semantic Token]
    背景：var(--[component-token])
    圆角：var(--[component-token])
    边框：var(--[component-token])
  文字
    字体：var(--[semantic-token])
    颜色：var(--[component-token])

变体：

| 变体 | 样式差异 |
|------|--------|
| primary | 背景 action-primary，文字 on-action |
| secondary | 背景 transparent，边框 action-primary，文字 action-primary |
| ghost | 背景 transparent，文字 action-primary |
| danger | 背景 error，文字 on-action |

尺寸：

| 尺寸 | 高度 | 内间距 | 字体 |
|------|------|-------|-----|
| sm | 32px | 0 space-3 | text-caption |
| md | 40px | 0 space-4 | text-button |
| lg | 48px | 0 space-6 | text-body |

状态变化：

| 状态 | 视觉变化 |
|------|--------|
| hover | 背景色 → var(--button-primary-bg-hover) |
| focus | 添加 focus ring: 0 0 0 3px rgba(59,130,246,0.3) |
| active | 背景色 → var(--button-primary-bg-active) |
| disabled | 背景 → color-text-tertiary，cursor: not-allowed |
| loading | 文字替换为 spinner + "加载中..." |

状态组合矩阵（多状态共存时的视觉规则）：

> 单状态规格定义了各状态独立的样子，但实际运行中状态会组合。
> 例如 disabled 按钮 hover 时该有什么反馈？loading 中的按钮能否 focus？
> 没有组合矩阵，DEV 会凭感觉实现，导致组合态视觉冲突。

| 基础状态 \ 叠加状态 | hover | focus | active | disabled | loading |
|---------------------|-------|-------|--------|----------|---------|
| **default** | 背景变 hover 色 | 显示 focus ring | 背景变 active 色 | 灰色 + 禁止光标 | 显示 spinner |
| **disabled** | 无反馈（忽略） | 无反馈（忽略） | 无反馈（忽略） | — | 不并存 |
| **loading** | 保持 loading 态 | 可 focus（无障碍） | 无反馈（忽略） | 不并存 | — |

> 矩阵单元格含义：该行基础状态 + 该列叠加状态同时存在时的视觉规则。
> "无反馈（忽略）"= 不触发该状态的视觉变化。
> "不并存"= 逻辑上不可能同时出现，无需定义。
> "—"= 自身对自身，无意义。

### 5.2 [组件名 B]
[同上模板]

---

## 6. 交互规格

### 6.1 状态流转

[组件名] 状态机：

```
┌─────────┐
│ [状态A] │ ──触发条件──▶ ┌─────────┐
└─────────┘              │ [状态B] │
                         └─────────┘
```

### 6.2 过渡动画

| 场景 | 时长 | 缓动函数 | 变化属性 |
|------|------|---------|---------|
| [场景描述] | [ms] | [easing] | [CSS 属性 + 起止值] |

### 6.3 反馈机制

| 操作 | 反馈方式 |
|------|--------|
| 创建成功 | Toast "创建成功" + 绿色图标，3 秒消失 |
| 删除确认 | 弹窗 "删除后无法恢复，确认删除？" |
| 保存失败 | Toast "保存失败" + 红色图标，需手动关闭 |
| 表单校验失败 | 字段下方红色错误文字 + 输入框红色边框 |

---

## 7. 设计决策记录

| 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|
| [决策描述] | A / B / C | [选择] | [理由] |

## 视觉稿参考

> 仅在执行了 Phase 2.5 时填写。未生成视觉稿则删除此章节。

- **定稿 mockup**：`design/mockups/final.html`
- **视觉氛围参考**：`design/mockups/images/reference.png`（如有）
- **方向探索历史**：`design/mockups/images/`（3 个方向，按设计侧重命名：如 信息优先 / 任务优先 / 体验优先）

> mockup 是视觉参考，本规格文档是精确参数源。
> 实现时参考 mockup 理解视觉效果（布局比例、配色氛围、视觉层次），具体参数以本文档为准。
> mockup 无法展示的部分（状态流转、动画时序、交互逻辑）以本文档的交互规格为准。

## 流转控制

- **当前责任人**：[DEV]
- **文档状态**：active / deprecated
- **前置设计文档**：[废弃后新建时，填写旧文档路径；否则省略]

## 驳回记录

> 任一角色可在认为文档不合理时发起驳回；
> 被驳回方可回应辩解；僵持不下时需人工裁决。
> 详细流程见 `rdd-engine/references/rejection-protocol.md`。

| 轮次 | 日期 | 发起方 | 理由 | 被驳回方回应 | 最终裁决 | 状态 |
|------|------|--------|------|-------------|----------|------|
| - | - | - | - | - | - | - |
```

---

## 翻译者模式额外章节

当设计规格基于参考图翻译时，在文档开头增加：

```markdown
## 0. 参考图信息

| 图号 | 描述 | 覆盖范围 |
|------|------|----------|
| 图 1 | [描述] | [覆盖了哪些页面/状态] |
| 图 2 | [描述] | [覆盖了哪些页面/状态] |

置信度说明：
  🟢 高 — 参考图中明确可见
  🟡 中 — 通过上下文推断
  🔴 低 — 参考图模糊或被遮挡
  ✦ — UX 补充（参考图未覆盖，由 UX 根据设计规范补充）
```

---

## 技术栈适配指南

不同 CSS 方案下，三层 Token 的输出格式不同。Phase 3 产出时按项目实际技术栈适配。

### Tailwind CSS

Primitive 色彩映射到 `tailwind.config.js` → `theme.extend.colors`，Semantic 层用语义化别名：

```javascript
// tailwind.config.js
module.exports = {
  theme: {
    extend: {
      colors: {
        // Primitive
        blue: { 100: '#DBEAFE', 500: '#3B82F6', 600: '#2563EB', 700: '#1D4ED8' },
        gray: { 50: '#F9FAFB', 200: '#E5E7EB', 500: '#6B7280', 900: '#111827' },
        // Semantic（指向 Primitive）
        primary: { DEFAULT: '#3B82F6', hover: '#2563EB', active: '#1D4ED8' },
      }
    }
  }
}
```

间距使用 Tailwind 内置（默认 4px 基准，与设计系统对齐）。
组件样式用 Tailwind 类名描述，Component Token 体现为类名组合。

### CSS Modules / 原生 CSS

三层都以 CSS 自定义属性输出，层间用 `var()` 引用：

```css
:root {
  /* Primitive */
  --blue-500: #3B82F6;
  --gray-900: #111827;
  --space-4: 16px;

  /* Semantic → Primitive */
  --color-action-primary: var(--blue-500);
  --color-text-primary: var(--gray-900);

  /* Component → Semantic */
  --button-primary-bg: var(--color-action-primary);
}
```

### CSS-in-JS (styled-components / Emotion)

三层都定义为 JS 对象，层间用引用连接：

```javascript
const primitive = {
  color: { blue500: '#3B82F6', gray900: '#111827' },
  space: { s4: '16px' },
}

const semantic = {
  colorActionPrimary: primitive.color.blue500,
  colorTextPrimary: primitive.color.gray900,
}

const component = {
  buttonPrimaryBg: semantic.colorActionPrimary,
}
```

### 无 CSS 框架

输出纯 CSS 自定义属性格式（同 CSS Modules 方案）。

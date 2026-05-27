# 设计规格产出模板

本文件定义 UX Skill 产出物的标准格式。Phase 3 产出设计规格时，必须按此模板格式化。

## 设计规格文档结构

```markdown
# 设计规格 — [项目/页面名称]

---
requirement_id: [需求编号]
priority: 高/中/低
depends_on: []
status: draft
role: ux
design_date: YYYY-MM-DD
source_mode: 翻译者 / 创作者 / 混合
---

## 需求覆盖映射

| 需求 ID | 本文档负责范围 | 对应章节 | 关联文档 |
|---------|--------------|---------|---------|
| [ID] | [UX 负责的范围] | [章节号] | design/{name}-cto.md (如有) |

---

## 1. 设计 Token

### 1.1 色彩系统

┌──────────┬───────────┬──────────┐
│ 用途      │ 色值       │ Token 名 │
├──────────┼───────────┼──────────┤
│ 主色      │ #3B82F6   │ --color-primary │
│ 主色hover │ #2563EB   │ --color-primary-hover │
│ 主色active│ #1D4ED8   │ --color-primary-active │
│ 辅色      │ #10B981   │ --color-secondary │
│ 页面背景  │ #F9FAFB   │ --color-bg-page │
│ 卡片背景  │ #FFFFFF   │ --color-bg-card │
│ 输入框背景│ #FFFFFF   │ --color-bg-input │
│ 主文字    │ #111827   │ --color-text-primary │
│ 次文字    │ #6B7280   │ --color-text-secondary │
│ 辅助文字  │ #9CA3AF   │ --color-text-tertiary │
│ 占位文字  │ #9CA3AF   │ --color-text-placeholder │
│ 边框      │ #E5E7EB   │ --color-border │
│ 分割线    │ #F3F4F6   │ --color-divider │
│ 成功      │ #10B981   │ --color-success │
│ 警告      │ #F59E0B   │ --color-warning │
│ 错误      │ #EF4444   │ --color-error │
│ 信息      │ #3B82F6   │ --color-info │
└──────────┴───────────┴──────────┘

### 1.2 字体系统

┌──────────┬──────────────────────────────┬────────────┐
│ 层级      │ 规格                          │ Token 名   │
├──────────┼──────────────────────────────┼────────────┤
│ Display  │ 36px/1.2 font-weight:800     │ --text-display │
│ H1       │ 28px/1.3 font-weight:700     │ --text-h1 │
│ H2       │ 22px/1.3 font-weight:600     │ --text-h2 │
│ H3       │ 16px/1.4 font-weight:600     │ --text-h3 │
│ Body     │ 14px/1.6 font-weight:400     │ --text-body │
│ Body-sm  │ 13px/1.5 font-weight:400     │ --text-body-sm │
│ Caption  │ 12px/1.5 font-weight:400     │ --text-caption │
│ Button   │ 14px font-weight:500         │ --text-button │
│ Overline │ 12px/1.0 font-weight:600 letter-spacing:0.05em │ --text-overline │
└──────────┴──────────────────────────────┴────────────┘

字体族：
  主字体：[字体名], -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif
  代码字体：'SF Mono', 'Fira Code', 'Consolas', monospace

### 1.3 间距系统

基准单位：[4/8]px

┌──────┬────────┬────────────────────┐
│ 等级  │ 值      │ 用途                │
├──────┼────────┼────────────────────┤
│ xs   │ 4px    │ 图标与文字间距       │
│ sm   │ 8px    │ 紧凑元素间距         │
│ md   │ 16px   │ 标准间距             │
│ lg   │ 24px   │ 区块内间距           │
│ xl   │ 32px   │ 区块间间距           │
│ 2xl  │ 48px   │ 章节间距             │
│ 3xl  │ 64px   │ 大章节间距           │
└──────┴────────┴────────────────────┘

### 1.4 视觉效果

圆角：
  --radius-sm: 4px    （标签、小按钮）
  --radius-md: 6px    （按钮、输入框）
  --radius-lg: 8px    （卡片）
  --radius-xl: 12px   （弹窗、面板）
  --radius-full: 50%  （头像、圆形按钮）

阴影：
  --shadow-sm: 0 1px 2px rgba(0,0,0,0.05)
  --shadow-md: 0 1px 3px rgba(0,0,0,0.1), 0 1px 2px rgba(0,0,0,0.06)
  --shadow-lg: 0 4px 6px rgba(0,0,0,0.07), 0 10px 15px rgba(0,0,0,0.1)

边框：
  --border-default: 1px solid var(--color-border)
  --border-focus: 2px solid var(--color-primary)

### 1.5 技术栈适配说明

[根据 Phase 1 识别的项目技术栈，说明 Token 如何映射]

例如（Tailwind 项目）：
  色彩系统映射到 tailwind.config.js 的 theme.extend.colors
  间距系统使用 Tailwind 内置间距（已对齐 4px 基准）
  圆角使用 Tailwind 的 rounded-{size} 类

例如（CSS Modules 项目）：
  Token 定义为 :root 下的 CSS 自定义属性
  组件样式引用 var(--token-name)

---

## 2. 布局规格

### 2.1 页面布局

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

### 2.2 响应式规则

断点定义：
  --breakpoint-sm: 640px
  --breakpoint-md: 768px
  --breakpoint-lg: 1024px
  --breakpoint-xl: 1280px

┌──────────┬──────────────────────────────────────────┐
│ 断点      │ 布局变化                                  │
├──────────┼──────────────────────────────────────────┤
│ ≥1280px  │ [桌面完整布局描述]                          │
│ 1024-1280│ [平板横屏/小桌面布局变化]                    │
│ 768-1024 │ [平板竖屏布局变化]                          │
│ 640-768  │ [大手机布局变化]                            │
│ <640px   │ [手机布局变化]                              │
└──────────┴──────────────────────────────────────────┘

---

## 3. 组件规格

### 3.1 [组件名 A]

用途：[一句话]

结构建议：
  <Container>
    <PrefixIcon />（可选）
    <Label />
    <SuffixIcon />（可选）
  </Container>

样式规则：
  容器
    高度：[值]px
    内间距：[值]
    背景：var(--color-[token])
    圆角：var(--radius-[token])
    边框：var(--border-[token])
  文字
    字体：var(--text-[token])
    颜色：var(--color-[token])

变体：
┌──────────┬──────────────────────────────────────────┐
│ 变体      │ 样式差异                                  │
├──────────┼──────────────────────────────────────────┤
│ primary  │ 背景 primary，文字白色                     │
│ secondary│ 背景 transparent，边框 primary，文字 primary│
│ ghost    │ 背景 transparent，文字 primary             │
│ danger   │ 背景 error，文字白色                       │
└──────────┴──────────────────────────────────────────┘

尺寸：
┌──────────┬──────────┬──────────┬──────────┐
│ 尺寸      │ 高度      │ 内间距    │ 字体      │
├──────────┼──────────┼──────────┼──────────┤
│ sm       │ 32px     │ 0 12px  │ text-caption │
│ md       │ 40px     │ 0 16px  │ text-button │
│ lg       │ 48px     │ 0 24px  │ text-body  │
└──────────┴──────────┴──────────┴──────────┘

状态变化：
┌──────────┬──────────────────────────────────────────┐
│ 状态      │ 视觉变化                                  │
├──────────┼──────────────────────────────────────────┤
│ hover    │ 背景色 → var(--color-primary-hover)        │
│ focus    │ 添加 focus ring: 0 0 0 3px rgba(59,130,246,0.3) │
│ active   │ 背景色 → var(--color-primary-active)       │
│ disabled │ 背景 → #9CA3AF，cursor: not-allowed        │
│ loading  │ 文字替换为 spinner + "加载中..."            │
└──────────┴──────────────────────────────────────────┘

### 3.2 [组件名 B]
[同上模板]

...

---

## 4. 交互规格

### 4.1 用户操作路径

场景：[场景名]

```
[初始状态]
  │
  ├── 操作：[动作]
  │   触发条件：[什么情况下可以操作]
  │   反馈：[操作后的视觉变化]
  │   结果：[操作后的状态变化]
  │
  ├── 操作：[动作]
  │   ...
  │
  └── 操作：[动作]
      ...
```

### 4.2 状态流转

[组件名] 状态机：

```
┌─────────┐
│ [状态A] │ ──触发条件──▶ ┌─────────┐
└─────────┘              │ [状态B] │
                         └─────────┘
```

### 4.3 过渡动画

┌──────────────────┬──────────┬──────────────┬──────────────────────────┐
│ 场景              │ 时长      │ 缓动函数      │ 变化属性                  │
├──────────────────┼──────────┼──────────────┼──────────────────────────┤
│ [场景描述]        │ [ms]     │ [easing]     │ [CSS 属性 + 起止值]       │
└──────────────────┴──────────┴──────────────┴──────────────────────────┘

### 4.4 反馈机制

┌──────────────────┬──────────────────────────────────────────┐
│ 操作              │ 反馈方式                                  │
├──────────────────┼──────────────────────────────────────────┤
│ 创建成功          │ Toast 提示 "创建成功" + 绿色图标，3秒自动消失│
│ 删除确认          │ 弹窗确认 "确认删除？此操作不可撤销"          │
│ 保存失败          │ Toast 提示 "保存失败" + 红色图标，需手动关闭│
│ 表单校验失败       │ 字段下方红色错误文字 + 输入框红色边框        │
└──────────────────┴──────────────────────────────────────────┘

---

## 5. 设计决策记录

| 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|
| [决策描述] | A / B / C | [选择] | [理由] |
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

不同 CSS 方案下，Token 的输出格式不同。Phase 3 产出时按项目实际技术栈适配。

### Tailwind CSS

色彩映射到 `tailwind.config.js` → `theme.extend.colors`
间距使用 Tailwind 内置（默认 4px 基准，与设计系统对齐）
圆角使用 `rounded-{size}` 类
组件样式用 Tailwind 类名描述

```javascript
// tailwind.config.js 新增
module.exports = {
  theme: {
    extend: {
      colors: {
        primary: { DEFAULT: '#3B82F6', hover: '#2563EB', active: '#1D4ED8' },
        // ...
      }
    }
  }
}
```

### CSS Modules / 原生 CSS

Token 定义为 CSS 自定义属性：

```css
:root {
  --color-primary: #3B82F6;
  --color-primary-hover: #2563EB;
  --text-body: 14px/1.6;
  --spacing-md: 16px;
  --radius-md: 6px;
  /* ... */
}
```

### CSS-in-JS (styled-components / Emotion)

Token 定义为 JS 对象：

```javascript
const tokens = {
  color: {
    primary: '#3B82F6',
    primaryHover: '#2563EB',
    // ...
  },
  spacing: {
    md: '16px',
    // ...
  }
}
```

### 无 CSS 框架

输出纯 CSS 自定义属性格式（同 CSS Modules 方案）。

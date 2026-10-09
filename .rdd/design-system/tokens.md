# 设计 Token 累积资产

> 跨需求复用的设计资产。首个设计建立基线；后续设计在 Phase 1 读取本文件作为约束基线，Phase 4 追加/更新。

## 基线说明

本项目（codeRDD）自身无前端渲染；RDD 相关 UI 全部落在 **DSH（deepseek-harness）渲染端**，其权威 Token 体系为 `--dsw-*`（`ui-theme/src/styles/design-platform.css`：static Primitive + alias Semantic，`body[data-ds-dark-theme]` 切深浅主题）。**RDD 设计不新建全局 Token，一律消费既有 alias**；本文件记录各设计消费的 alias 集与组件级映射。

## 作用域说明（2026-10-08 新增，重要）

上面那条"不新建全局 Token"的规则有**作用域边界**：它约束的是 **在 DSH 页面内渲染** 的 UI——`--dsw-*` 变量定义在 DSH 页面的 `body` 上，只有跑在 DSH 内的渲染端才取得到。

**独立浏览器页面**（如 `node:http` 伺服、浏览器直接打开的看板/报告页）**技术上取不到 `--dsw-*`**，强行要求消费将导致样式无从落笔。这类页面按以下规则处理：

1. 建立**页面自有命名空间**的三层 Token（如看板的 `--ops-*`）
2. **Primitive 层按值镜像**本文件登记的 DSH 品牌色板（是"值镜像"，不是变量引用——因此零跨进程依赖、离线可用）
3. 语义层/组件层在该命名空间内自建，并在本文件**按作用域分节登记**，不得与 DSH alias 作用域混表
4. 品牌同族性由"值镜像"保证：看板与 RDD 在 DSH 内的 UI 使用同一套色值

## Primitive 层（引用登记）

> 值唯一来源是 DSH design-platform.css，此处仅登记被 RDD 设计消费的条目。

| Token | 值 | 首次登记 |
|-------|-----|---------|
| deepseek-100 | rgb(228, 237, 253) | session-list-badges（2026-09-20） |
| deepseek-800 | rgb(52, 65, 91) | 同上 |
| deepseek-500 | rgb(65, 118, 230) | 同上 |
| deepseek-400 | rgb(103, 158, 254) | 同上 |
| neutral-bluish-1000 | rgb(15, 17, 21) | 同上 |
| neutral-bluish-50 | rgb(249, 250, 251) | 同上 |
| neutral-bluish-700 | rgb(97, 102, 107) | 同上 |
| neutral-bluish-300 | rgb(207, 211, 214) | 同上 |
| neutral-bluish-75 | rgb(241, 243, 245) | 同上 |
| neutral-bluish-850 | rgb(44, 44, 46) | 同上 |
| deepseek-300 | rgb(183, 200, 254) | ops-dashboard（2026-10-08） |
| deepseek-600 | rgb(72, 104, 178) | 同上 |
| neutral-bluish-60 | rgb(245, 246, 247) | 同上 |
| neutral-bluish-400 | rgb(173, 178, 184) | 同上（**仅装饰/图表系列，禁承载文字**：白底对比度 2.31:1） |
| neutral-bluish-600 | rgb(129, 133, 140) | 同上 |
| blue-450 | rgb(77, 147, 248) | 同上（图表分类色） |
| green-500 | rgb(34, 197, 94) | 同上（成功/通过语义） |
| amber-500 | rgb(245, 158, 11) | 同上（警告/小样本语义） |
| red-500 | rgb(239, 68, 68) | 同上（失败/打回语义） |
| red-400 | rgb(242, 90, 90) | 同上（深色主题 error） |
| **deepseek-700** | **rgb(58, 84, 140)** | **同上 —— ⚠️ UX 新增值（非 DSH 现有条目）**：品牌色阶深档补位，白字对比度 7.43:1。DSH 现有 `deepseek-700-delete rgb(47, 76, 143)` 带 delete 语义，不作通用档复用 |

## Semantic 层（消费登记）

| Semantic Token（DSH alias） | 浅 → 深 | RDD 用途 | 首次登记 |
|------------------------------|---------|----------|---------|
| `--dsw-alias-state-business-tertiary` | deepseek-100 → deepseek-800 | 徽章身份底色 | session-list-badges |
| `--dsw-alias-state-business-primary` | deepseek-500 → deepseek-400 | 徽章身份图标 | 同上 |
| `--dsw-alias-label-primary` | bluish-1000 → bluish-50 | 徽章身份文本 | 同上 |
| `--dsw-alias-label-secondary` | bluish-700 → bluish-300 | 数值链/通用徽章文本 | 同上 |
| `--dsw-alias-markdown-tag` | bluish-75 → bluish-850 | 未知 kind 通用徽章底 | 同上 |

## Semantic 层（独立页面作用域登记：`--ops-*`）

> 作用域：`rdd-engine/dashboard/static/style.css`（独立浏览器页面，见「作用域说明」）。浅色为默认，`body[data-theme="dark"]` 覆盖。**该命名空间只在看板页面内有效，不得被 DSH 渲染端消费**（跨作用域混用会让"改一处全局生效"失效）。

| Semantic Token（`--ops-*`） | 浅 → 深 | 用途 | 来源设计 |
|------------------------------|---------|------|---------|
| `bg-app` | bluish-60 → rgb(21,21,23) | 页面底 | ops-dashboard |
| `bg-surface` | #FFFFFF → rgb(35,35,36) | 卡片/面板底 | 同上 |
| `bg-subtle` | bluish-75 → rgb(44,44,46) | 表头/空态底/chip 底 | 同上 |
| `border-subtle` / `border-default` | rgba(0,0,0,0.06/0.10) → rgba(255,255,255,0.08/0.12) | 边框与分割线 | 同上 |
| `text-primary` | bluish-1000 → rgb(249,250,251) | 主文字/数值 | 同上 |
| `text-secondary` | bluish-700 → rgb(207,211,214) | 次要文字/表头/轴标签 | 同上 |
| `action-primary` | deepseek-500 → deepseek-400 | 链接/图标/聚焦环（**非文字**） | 同上 |
| **`action-on-tertiary`** | deepseek-600 → deepseek-300 | **品牌蓝文字落在品牌淡底/浅底上时专用** | 同上 |
| `action-fill` / `action-fill-hover` | deepseek-600 / deepseek-700 | 填充按钮底 / hover 底 | 同上 |
| `text-on-action` | #FFFFFF | 填充底上的文字 | 同上 |
| `accent-tertiary` | deepseek-100 → rgb(52,65,91) | 选中项底/行 hover 底/tag 底 | 同上 |
| `success` / `warn` / `error` | green-500 / amber-500 / red-500（深色 error 用 red-400） | 状态语义 | 同上 |
| `hero-grad` / `hero-scrim` | `linear-gradient(118deg, rgb(64,92,160), rgb(48,70,120), rgb(37,55,96))` / `rgba(0,0,0,0.10→0.18)` | 品牌 Hero 底 / 文字区压暗层 | 同上 |
| `chart-1` … `chart-6` | deepseek-500 / blue-450 / green-500 / amber-500 / red-500 / bluish-400 | 图表分类色（最多 6 系列） | 同上 |
| **`shadow-pop`** | `0 10px 28px rgba(15,17,21,0.14)` → `0 10px 28px rgba(0,0,0,0.5)` | 浮层面板投影（TopBar 下拉/弹出件） | project-switcher（2026-10-09） |

> **可复用教训（跨设计通用）**：品牌主色作为**文字**落在品牌淡底上通常不达 AA（实测 `deepseek-500` on `deepseek-100` 仅 **3.60:1**）。凡"淡底 + 品牌蓝文字"的组合，必须另取一档更深的品牌色（本设计取 `deepseek-600` → 4.57:1；深色主题取 `deepseek-300` → 6.19:1）。这类组合在 tag、选中导航项、chip hover、空态行动行上都会出现，容易系统性漏检。

## 组件级映射

| Component Token（逻辑名） | → Semantic | 组件 | 来源设计 |
|---------------------------|-----------|------|---------|
| sessionBadge-ident-bg | state-business-tertiary | SessionBadges · 身份徽章底 | session-list-badges-ux.md §1.3 |
| sessionBadge-ident-icon | state-business-primary | SessionBadges · 身份徽章图标 | 同上 |
| sessionBadge-ident-text | label-primary | SessionBadges · 身份徽章文本 | 同上 |
| sessionBadge-chain-text | label-secondary | SessionBadges · 数值链文本 | 同上 |
| sessionBadge-generic-bg | markdown-tag | SessionBadges · 通用徽章底 | 同上 |
| sessionBadge-generic-text | label-secondary | SessionBadges · 通用徽章文本 | 同上 |
| kpiCard-bg / border / radius / shadow | bg-surface / border-subtle / radius-card 8px / shadow-card | KpiCard · 容器（**整卡为锚元素**） | ops-dashboard-ux.md §5.5 |
| kpiCard-value | text-primary + font-kpi 36px + tabular-nums | KpiCard · 主数字 | 同上 |
| cardLink-color | action-on-tertiary | KpiCard · 「进入 →」行动行 | 同上 |
| emptyState-key / fact / action | text-primary / text-primary / action-on-tertiary | EmptyState · 三段式空态（事实/原因/行动） | §5.6 |
| noteBar-warn / fixture | warn 左边框 / 虚线边框 + accent-tertiary 徽章 | NoteBar · 小样本提示 / 夹具排除声明 | §5.7 |
| chartSeries-1..6 | chart-1 … chart-6 | ChartFrame · 系列色（**分布=条形，趋势才折线**） | §5.8 |
| table-head / row-hover / row-selected | bg-subtle + text-secondary / accent-tertiary / accent-tertiary + 左边框 | DataTable · 表头/行态 | §5.9 |
| navItem-* | bg-subtle(hover) / accent-tertiary+action-on-tertiary(选中) | SidebarNav · 导航项 | §5.2 |
| focusRing | action-primary 2px + offset 2px | 全部可交互元素 · 聚焦环 | §5.16 |
| switcherPanel-* | bg-surface / border-default / radius-panel 12px / padding 16px / width min(560px,100%-40px) / shadow-pop / 锚定 top:100%+8px left:24px | SwitcherPanel · 浮层切换面板容器 | project-switcher-ux.md §5.2 |
| pathInput-* | h32 / mono 13px / bg-surface / border-default / radius-card / focus=action-primary 边+accent-tertiary 2px 光晕 | PathInput · 路径输入框 | 同上 §5.3 |
| panelNote-* | 同 NoteBar（bg-subtle+4px 语义左条+radius-card） | PanelNote · 面板内反馈区（info/error/success） | 同上 §5.4 |
| switchFlash-* | NoteBar note-success + sessionStorage 一次性消费 | SwitchFlash · 切换成功提示 | 同上 §5.5 |

## 变更记录

- 2026-09-20 建立：session-list-badges 首次登记（全部为既有 alias 消费，无新建全局 Token）。
- 2026-10-08 ops-dashboard 登记：① 新增「作用域说明」——"消费既有 alias"规则的作用域边界（DSH 页面内 vs 独立页面），独立页面按"值镜像"建自有命名空间；② 新增 Primitive 登记 11 项，其中 **deepseek-700 rgb(58,84,140) 为 UX 新增值**（品牌色阶深档补位，DSH 无通用对应档）；③ 新增「独立页面作用域 Semantic 层（`--ops-*`）」分节（14 项）并附"淡底品牌蓝文字系统性不达 AA"的可复用教训；④ 新增看板组件级映射 11 项；⑤ 本次登记中验证的对比度数据见表内注明（19 组 ≥4.5:1）。
- 2026-10-09 project-switcher 登记：① Semantic 零新增（全部消费既有 `--ops-*`）；② 新增 `shadow-pop`（浮层投影档，浅深两值）；③ 新增组件级映射 4 组（switcherPanel/pathInput/panelNote/switchFlash）；④ 教训补录：**语义功能色作"文字"落浅底普遍不达 AA**——green-500 on bg-subtle 仅 2.05:1、amber-500 仅 1.93:1，语义色只可用于装饰性冗余编码（左边条/图标），文字一律 text-primary/secondary；success 左条 2.05:1 按装饰豁免与既有 warn/info 同模式处理（完整实测数据见该归档 design/project-switcher-ux.md 附录 A：16 项强制全 PASS）。

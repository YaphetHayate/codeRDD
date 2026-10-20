# 组件累积清单

> 已定义组件的跨需求复用清单。新设计 Phase 1 读取本文件避免重复定义；Phase 4 追加/更新。

| 组件 | 归属 | 用途 | 关键参数 | 来源设计 |
|------|------|------|---------|---------|
| **SessionBadges** | DSH `packages/client/ui-workspace/src/client/rows/`（渲染） | 会话行/搜索行内把 `sessionBadges` 投影数组渲染为「身份徽章 + 数值链」：首枚 18px 品牌色淡底胶囊（图标 12px + 文本 12px/16px），后续枚 label 连为数值链（12px/16px `·` 分隔）；未知 kind 通用徽章降级（label 首字符） | 身份徽章 18px 高/r9/底 state-business-tertiary；数值链 label-secondary；徽章组→标题 6px、max-width 55%；空数组不渲染（回归锚点） | design（2026-09-20-planner-enhancements）/session-list-badges-ux.md §5 |
| **AppShell** | `rdd-engine/dashboard/static/`（独立页面） | 侧边栏 220px（sticky 100vh）+ 顶栏 56px（sticky z=20）+ 主内容（max-w 1400px / padding 32px / gap 32px） | 侧边栏 <900px 收为 64px 图标条；主内容区为唯一滚动容器 | ops-dashboard-ux.md §5.1 |
| **SidebarNav** | 同上 | 7 项数据域导航 + 计数，任意域 ≤1 次点击可达 | 项高 38px/圆角 8px；默认 text-secondary；hover bg-subtle；选中 accent-tertiary + action-on-tertiary + 3px 左轨；0 值照常显示"0" | §5.2 |
| **TopBar** | 同上 | 数据根路径 + 最近更新 + 刷新（主按钮，含 loading 态）+ 主题切换 | 路径胶囊 13px 可省略；刷新按钮 loading 时 spinner + disabled + aria-busy | §5.3 |
| **HeroPanel** | 同上 | 品牌渐变沉浸区：eyebrow + h1 + 说明 + 4 个主数字 chip；**含折叠** | 展开 ≈293px / 折叠 58px（`is-collapsed`，localStorage 记忆）；白字对比度硬约束：装饰层 alpha ≤0.24 + scrim（实测 6.03:1 / 7.29:1） | §5.4 |
| **KpiCard** | 同上 | 每数据域一张：图标 + 标题 + 主数字 + 构成 chip + 迷你图 + 「进入 →」；**整卡为锚元素** | 内间距 24px/圆角 8px；hover translateY(-3px) + 阴影 + 强调轨；6 卡结构参数完全一致，仅内容与强调轨色不同 | §5.5 |
| **EmptyState** | 同上 | 三段式空态（事实 / 原因 / 行动）+ 可选出路行；域级 / 块级 / 错误级三档复用 | 底 bg-subtle + 边框 border-default；`.es-key` 40px 固定宽；行动行 action-on-tertiary；**禁写成单句"暂无数据"** | §5.6 |
| **NoteBar** | 同上 | 提示条五语义：warn（小样本）/ info（口径、取消）/ error（取数失败 + 重试、切换拒绝）/ fixture（夹具排除）/ **success（切换成功 flash）** | 左侧 4px 语义色条；fixture 变体改虚线边框 + accent-tertiary 徽章；语义色条为装饰冗余编码（文字承担识别，豁免 1.4.11） | §5.7 + project-switcher §5.6 |
| **ChartFrame** | 同上 | 图表面板容器，**强制承载降级判定**：0 条→块级空态；趋势 <3 天或 <5 条→禁折线改点阵；分布一律横向条形 | 最小高 280px；0 值行用虚线空轨不隐藏；Chart.js 不读 CSS 变量，需 `readTokens()` + 主题切换重建实例 | §5.8 |
| **DataTable** | 同上 | 域页第三层明细；表头 12px/bg-subtle，行 44px；支持可点行、选中行、空表、长文本省略、>20 行表头 sticky | 截断必须写「仅展示最近 N 条（共 M 条）」；状态列颜色 + 文字双编码 | §5.9 |
| **BarList** | 同上 | 横向排行（名称 + 轨道 + 值），用于 miss 高频 query、Owner/tag/角色分布、跨域规模对比 | 名称列固定 88–104px 保证数值对齐；条高 18px；hover opacity 0.78 | §5.10 |
| **Timeline** | 同上 | 跨域事件时间线（归档创建 / tip 记录 / 交付树创建） | 圆点 12px + 2px 竖线；**类型必须另有 Chip 文字**，不得只靠颜色区分 | §5.11 |
| **Chip / Badge** | 同上 | 构成计数、口径标签、状态徽章 | chip（bg-subtle + text-secondary）/ tag 与 fx-badge（accent-tertiary + action-on-tertiary）/ 状态 Badge（语义色）；带 swatch 时色点 + 文字双编码 | §5.12 |
| **Breadcrumb / FieldList** | 同上 | 详情页返回路径 + 「标签 + 值」字段列表 | 长值 `overflow-wrap:anywhere`；mono 路径带复制；空值渲染"—"不隐藏整行 | §5.13–5.14 |
| **Button** | 同上 | primary（唯一主操作）/ secondary / ghost | 高 32px/圆角 8px；primary 底 deepseek-600（白字 5.39:1），hover 底 deepseek-700（7.43:1）；hover/focus/active/disabled/loading + 组合矩阵齐备 | §5.15 |
| **SwitcherPanel** | 同上（TopBar 浮层） | 运行时切换数据根的浮层面板：当前根展示 + 浏览目录（服务端原生弹窗）+ 常驻粘贴路径兜底 + 反馈区 | 锚定 TopBar 下方（top:100%+8px/left:24px），z19，width min(560px,…)，shadow-pop，160ms ease-out 入场；**单飞原则**（切换在途全控件禁用）；light-dismiss + Esc + `P` 快捷键；焦点开→浏览钮/关→切换钮 | project-switcher-ux.md §5.2 |
| **PathInput** | 同上 | mono 路径/技术字符串输入框（可复用于任何路径输入场景） | h32/mono 13px/radius-card；focus=action-primary 边 + accent-tertiary 2px 光晕（非冷硬 outline）；错误不在框上着色、统一呈现于所属反馈区；Enter 提交 | 同上 §5.3 |
| **SwitchFlash** | 同上（`#ops-main` 顶部） | 跨页动作的一次性成功提示（sessionStorage 消费即清，再刷新不重现） | NoteBar note-success 变体 + 手动关闭；含新旧值对照（`旧 → 新`）保留「从哪来」信息 | 同上 §5.5 |
| **StatExpanderTile** | `rdd-engine/dashboard` /exploration（独立页面） | KPI 计数卡升级为「计数即入口」展开触发器：SSR 输出纯展示（无 JS = 现状外观），JS 注入 chevron + aria 升级（role=button / tabindex / aria-expanded / aria-controls） | hover 边框 action-primary；展开态 accent-tertiary 底 + label/hint 转 action-on-tertiary + chevron 旋转 180°；**chevron 由 JS 注入**（无 JS 零误导）；整卡为锚（对齐 KpiCard 约定） | exploration-entry-expansion-ux.md §5.1 |
| **KpiExpansionPanel** | 同上 | KPI 展开区容器：**头部行（标题+口径徽章+计数+收起指示）即原位收起开关** + dataTable/EmptyState + 口径脚注 | 容器与 `.panel` 同参（radius-panel 12px / padding 24px）；头部行热区 ≥32px、hover bg-subtle；**三等价收起入口**（头部行点击 / 同 KPI 卡再点 / Esc，收起后焦点回 KPI 卡）；高度界沿用 `.table-wrap` 560px + sticky 表头；入场 160ms 淡入下移（reduced-motion 禁用）；多展开区可并存 | 同上 §5.2 |
| **ExpandableRow** | 同上（DataTable 扩展） | 表格行**整行触发**详情展开/收起（无独立按钮）；行下插入详情行 `td[colspan]`；允许多开 | 行 tabindex=0 + Enter/Space；展开态 bg-subtle 底 + inset 3px action-primary 左轨（对齐 row-selected）；焦点环 inset -2px 防表格裁切；详情 = brief 正文 + fieldList（key/所属区/tags/涉及文件数/记录路径/注册时间）+ 动作行（vscode://file/ 跳转 + 复制路径兜底） | 同上 §5.3–5.4 |
| **PairStatusBadge** | 同上 /exploration | 产物对状态徽章：色点（8px 语义色圆点，aria-hidden）+ 达标文字（text-primary on bg-subtle）双编码；四态互斥穷尽（新鲜/不新鲜·X变更Y缺失/无清单/无条目） | 语义识别由文字承担→色点按 WCAG 1.4.11 装饰豁免；**语义色禁作文字、禁作 badge 淡底**（双禁令）；badge title 补全「无法现算」语义 | artifact-pair-observability-ux.md §5.3 |
| **PairDetail** | 同上（ExpandableRow 详情行变体） | 产物对详情行：判定行（色点+判定依据同句）→ 文件清单区（max-height 240px 内滚、分组 sticky 标题、变更/缺失排前、行内 mini 复制）→ fieldList（关联条目/生成时间双轨口径/artifact·summary 路径+行内复制）→ 动作行（打开 artifact + 打开 summary 双链接 + 复制兜底） | 清单区 240px 内层界叠 560px 表外层界；mtime 标注双落点（列表「≈」前缀 + 详情文字后缀）；缺 summary 不渲染死链接、如实标注异常配对 | 同上 §5.4 |

## kind → 图标映射（SessionBadges 附属资产）

| kind | 图标（dsh-client-ui-primitives 现有） |
|------|----------------------------------------|
| `rdd:planner` | IconAgentPresetOutline16 |
| `rdd:run` | IconChecklistOutline14 |
| `rdd:task` | IconEnhanceOutline16 |
| `rdd:stage` | IconPersonalizationOutline16 |
| `rdd:node` | IconBranchOutline16 |
| `rdd:direct` | IconSendOutline16 |
| `rdd:role` | IconUserOutline16 |
| 未知 kind | 无图标 → 通用徽章（label/kind 首字符） |

## 变更记录

- 2026-09-20 建立：SessionBadges 首次登记。
- 2026-10-08 ops-dashboard 登记：新增独立页面作用域组件 14 项（AppShell / SidebarNav / TopBar / HeroPanel / KpiCard / EmptyState / NoteBar / ChartFrame / DataTable / BarList / Timeline / Chip·Badge / Breadcrumb·FieldList / Button）。其中三处为**可跨需求复用的设计约定**：① KpiCard 整卡为锚元素（点击范围 = 视觉可点范围）；② EmptyState 必为三段式（事实/原因/行动）而非常态界面之外的单句兜底；③ ChartFrame 内置数据量降级判定（小样本禁趋势线），把"不误导"做成容器职责而非各处自觉。
- 2026-10-09 project-switcher 登记：① NoteBar 扩展第五语义 success（切换成功 flash）；② 新增 3 项（SwitcherPanel / PathInput / SwitchFlash）；③ 可复用约定两处：**单飞原则**（任一服务端动作请求在途，所属面板全控件禁用 + 服务端 409 防御）、**错误呈现位置唯一**（错误统一落在所属面板反馈区，不在输入框/角落分散着色）；④ TopBar 登记「数据根胶囊旁切换按钮」入口模式（入口与操作对象同域）。
- 2026-10-20 exploration-entry-expansion 登记：① 新增 3 项（StatExpanderTile / KpiExpansionPanel / ExpandableRow），全部零新建 Token；② 可复用约定两处：**行即开关**（行级容器的展开/收起触发器是行本体——KPI 卡/展开区头部行/条目行，不设独立展开按钮；键盘可达由行自身 tabindex + Enter/Space 承载）、**document 级事件委托**（行级交互绑定挂在 document 经 closest 定位，与 DOM 填充/刷新换 main 的时机解耦——逐元素绑定有时序失效面，视觉稿迭代实证）；③ **KpiExpander 模式**抽象为 #2/#3 挂接基线：`data-kpi` 卡 ↔ `kpi-expansion` 区经 aria-controls/id 配对 + 三等价收起入口 + 560px 高度界 + emptyState 三段式空态口径，新增展开区零 JS 改动。
- 2026-10-20 artifact-pair-observability 登记：① 新增 2 项（PairStatusBadge / PairDetail），零新建 Token——KpiExpander 模式按基线挂接成功（第四展开区 = SSR 多输出一个 section + `data-pair` 行词汇，委托监听器零改动）；② 可复用约定一处：**状态色双编码判定法**（语义识别由达标文字承担、色点仅装饰冗余 + aria-hidden；语义色禁作文字与淡底）——适用于一切「彩色状态」需求场景，先问「这个颜色承担唯一识别职责吗」再落笔。

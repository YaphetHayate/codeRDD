# 组件累积清单

> 已定义组件的跨需求复用清单。新设计 Phase 1 读取本文件避免重复定义；Phase 4 追加/更新。

| 组件 | 归属 | 用途 | 关键参数 | 来源设计 |
|------|------|------|---------|---------|
| **SessionBadges** | DSH `packages/client/ui-workspace/src/client/rows/`（渲染） | 会话行/搜索行内把 `sessionBadges` 投影数组渲染为「身份徽章 + 数值链」：首枚 18px 品牌色淡底胶囊（图标 12px + 文本 12px/16px），后续枚 label 连为数值链（12px/16px `·` 分隔）；未知 kind 通用徽章降级（label 首字符） | 身份徽章 18px 高/r9/底 state-business-tertiary；数值链 label-secondary；徽章组→标题 6px、max-width 55%；空数组不渲染（回归锚点） | design（2026-09-20-planner-enhancements）/session-list-badges-ux.md §5 |

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

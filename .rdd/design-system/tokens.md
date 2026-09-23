# 设计 Token 累积资产

> 跨需求复用的设计资产。首个设计建立基线；后续设计在 Phase 1 读取本文件作为约束基线，Phase 4 追加/更新。

## 基线说明

本项目（codeRDD）自身无前端渲染；RDD 相关 UI 全部落在 **DSH（deepseek-harness）渲染端**，其权威 Token 体系为 `--dsw-*`（`ui-theme/src/styles/design-platform.css`：static Primitive + alias Semantic，`body[data-ds-dark-theme]` 切深浅主题）。**RDD 设计不新建全局 Token，一律消费既有 alias**；本文件记录各设计消费的 alias 集与组件级映射。

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

## Semantic 层（消费登记）

| Semantic Token（DSH alias） | 浅 → 深 | RDD 用途 | 首次登记 |
|------------------------------|---------|----------|---------|
| `--dsw-alias-state-business-tertiary` | deepseek-100 → deepseek-800 | 徽章身份底色 | session-list-badges |
| `--dsw-alias-state-business-primary` | deepseek-500 → deepseek-400 | 徽章身份图标 | 同上 |
| `--dsw-alias-label-primary` | bluish-1000 → bluish-50 | 徽章身份文本 | 同上 |
| `--dsw-alias-label-secondary` | bluish-700 → bluish-300 | 数值链/通用徽章文本 | 同上 |
| `--dsw-alias-markdown-tag` | bluish-75 → bluish-850 | 未知 kind 通用徽章底 | 同上 |

## 组件级映射

| Component Token（逻辑名） | → Semantic | 组件 | 来源设计 |
|---------------------------|-----------|------|---------|
| sessionBadge-ident-bg | state-business-tertiary | SessionBadges · 身份徽章底 | session-list-badges-ux.md §1.3 |
| sessionBadge-ident-icon | state-business-primary | SessionBadges · 身份徽章图标 | 同上 |
| sessionBadge-ident-text | label-primary | SessionBadges · 身份徽章文本 | 同上 |
| sessionBadge-chain-text | label-secondary | SessionBadges · 数值链文本 | 同上 |
| sessionBadge-generic-bg | markdown-tag | SessionBadges · 通用徽章底 | 同上 |
| sessionBadge-generic-text | label-secondary | SessionBadges · 通用徽章文本 | 同上 |

## 变更记录

- 2026-09-20 建立：session-list-badges 首次登记（全部为既有 alias 消费，无新建全局 Token）。

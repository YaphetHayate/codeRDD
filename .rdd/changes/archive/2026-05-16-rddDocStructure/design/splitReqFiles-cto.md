---
requirement_id: 需求 1
priority: 高
depends_on: []
blocks:
  - 需求 2
  - 需求 3
analysis_date: 2026-05-16
status: confirmed
role: cto
---

# 需求文件拆分为独立文件 — 设计文档

## 一、需求概述

将 PM 产出的 `requirement.md` 从单文件多需求拆分为 `overview.md`（背景、关键约束、需求索引）+ 每个需求独立一个文件（以简短主题名词命名）。这是后续两个需求（task.md 文件关联、设计文件独立命名）的前置条件。

## 二、技术方案

### 2.1 模块归属

改动范围：PM skill（SKILL.md + references 模板）

### 2.2 核心变更

#### 变更 1：PM 文件白名单更新

**文件**：`rdd-pm/SKILL.md` L39-43

现有白名单：
```
- .rdd/changes/archive/.../requirement.md
- .rdd/changes/archive/.../task.md
```

改为：
```
- .rdd/changes/archive/.../overview.md
- .rdd/changes/archive/.../*.md（需求文件）
- .rdd/changes/archive/.../task.md
```

#### 变更 2：PM 归档步骤更新

**文件**：`rdd-pm/SKILL.md` L110-112

现有步骤：
```
2. 按第三步确认的内容生成 requirement.md
3. 按 references/task-template.md 中的格式生成 task.md
```

改为：
```
2. 按第三步确认的内容生成 overview.md（按 overview-template.md 模板）
3. 为每个需求生成独立文件（按 requirement-item-template.md 模板），文件名由 PM 确定的简短主题名词命名
4. 按 references/task-template.md 中的格式生成 task.md，填写需求文件和设计文件关联
```

#### 变更 3：PM 收敛总结引用更新

**文件**：`rdd-pm/SKILL.md` L87

现有：
```
按 references/requirement-template.md 中的模板格式整理需求清单草稿
```

改为：
```
按 references/overview-template.md + references/requirement-item-template.md 中的模板格式整理需求清单
```

#### 变更 4：新建 overview 模板

**文件**：`rdd-pm/references/overview-template.md`（新建）

```markdown
# [标题]

## 背景

[一两段话描述为什么有这个需求，解决了什么问题]

## 需求索引

| # | 文件 | 标题 | 优先级 |
|---|------|------|--------|
| 1 | {name}.md | [简明标题] | 高/中/低 |
| 2 | {name}.md | [简明标题] | 高/中/低 |

## 关键约束

- [技术限制、时间要求、用户场景等]

## 讨论记录

- [讨论过程中的关键决策和取舍，简要点出即可]
```

#### 变更 5：新建需求项模板

**文件**：`rdd-pm/references/requirement-item-template.md`（新建）

```markdown
# [简明标题]

- **描述**：[具体要做什么，只描述意图，不涉及实现方式]
- **验收标准**：[可检验的完成条件]
- **优先级**：高/中/低

按需补充（有则必填，无则省略）：

- **影响范围**：[涉及的模块/页面/接口]
- **用户场景**：[谁在什么情况下做什么操作、期望什么结果]
- **边界与异常**：[空数据、极端情况、已知限制等]
- **依赖关系**：[是否依赖其他需求或外部系统]
```

#### 变更 6：原模板保留

**文件**：`rdd-pm/references/requirement-template.md`

保留原文件不删除，在文件顶部添加标注：
```
> ⚠️ 本模板已拆分为 overview-template.md + requirement-item-template.md。保留此文件仅供历史参考。
```

### 2.3 向后兼容

PM 本身不读取旧归档，无需改动。但 CTO/UX/DEV 读取归档时需要兼容新旧结构，详见 `designFileNaming-cto.md` 中的向后兼容方案。

### 2.4 集成点描述

| 集成点 | 已有模块 | 调用关系 | 数据流向 | 时序约束 |
|--------|----------|----------|----------|----------|
| 模板引用 | rdd-pm/SKILL.md 第三步 | PM 归档时读取两个新模板 | 模板 → 产出文件 | 归档阶段 |
| 文件命名约定 | task.md 的需求文件字段 | PM 填写 → CTO/UX 读取 | PM 写入 task.md 需求文件字段 → CTO/UX 据此命名设计文件 | PM 归档时确定 |

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 原 requirement-template.md 处理 | 删除 / 保留标注 / 直接覆盖 | 保留并标注 | 避免外部引用断裂，保留历史记录 |
| overview.md 是否包含完整需求内容 | 包含 / 仅索引 | 仅索引 | overview 定位为总览入口，详细内容在独立文件中，避免信息重复 |

## 四、实现步骤清单

1. 新建 `rdd-pm/references/overview-template.md`
2. 新建 `rdd-pm/references/requirement-item-template.md`
3. 修改 `rdd-pm/references/requirement-template.md`（添加拆分标注）
4. 修改 `rdd-pm/SKILL.md`（白名单、归档步骤、收敛总结引用）

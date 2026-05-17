---
requirement_id: 需求 3
priority: 高
depends_on:
  - 需求 1
  - 需求 2
blocks: []
analysis_date: 2026-05-16
status: confirmed
role: cto
---

# 设计文件按需求独立命名 — 设计文档

## 一、需求概述

CTO 和 UX 的设计文档从共享/编号命名改为按需求独立命名，格式为 `{需求文件名}-cto.md` 和 `{需求文件名}-ux.md`。需求文件名从 task.md 的 `需求文件` 字段获取。

## 二、技术方案

### 2.1 模块归属

改动范围：CTO skill（SKILL.md + design-guide.md）、UX skill（SKILL.md + spec-template.md）、DEV skill（SKILL.md）

### 2.2 核心变更

#### 变更 1：CTO 输入处理兼容新结构

**文件**：`rdd-cto/SKILL.md` L44-45

现有：
```
- B — 自动查找：扫描 .rdd/changes/archive/，按日期找最新归档，读取 requirement.md + task.md
```

改为：
```
- B — 自动查找：扫描 .rdd/changes/archive/，按日期找最新归档，读取 task.md
  - 若 overview.md 存在（新结构）：读取 overview.md + task.md 中的需求文件字段定位各需求文件
  - 若 requirement.md 存在（旧结构）：读取 requirement.md + task.md
  - 若 .rdd/ 不存在：回退检查 RDD/changes/archive/
```

#### 变更 2：CTO 归档命名规则

**文件**：`rdd-cto/SKILL.md` Phase 4（L212-213）

现有：
```
1. 在归档目录下创建 design/ 子目录，写入各需求设计文档
2. 单需求或强耦合可合并为 design/architecture.md
```

改为：
```
1. 在归档目录下创建 design/ 子目录
2. 设计文件命名为 design/{需求文件名}-cto.md，需求文件名从 task.md 的"需求文件"字段获取
   例如：需求文件为 fixbug.md → 设计文件为 design/fixbug-cto.md
```

#### 变更 3：CTO 设计文档模板引用更新

**文件**：`rdd-cto/SKILL.md` L208

现有：
```
> 从 requirement.md 提取该需求的核心内容
```

改为：
```
> 从对应需求文件提取该需求的核心内容
```

#### 变更 4：CTO 归档结构示例更新

**文件**：`rdd-cto/references/design-guide.md` 归档结构示例（L364-376）

现有：
```
RDD/changes/archive/2026-04-26-addUserRole/
├── requirement.md
├── task.md
└── design/
    ├── 001-用户认证.md
    └── 002-权限管理.md
```

改为：
```
.rdd/changes/archive/2026-05-16-topicName/
├── overview.md
├── fixbug.md
├── optimizeCache.md
├── task.md
└── design/
    ├── fixbug-cto.md
    ├── optimizeCache-cto.md
    ├── fixbug-ux.md
    └── optimizeCache-ux.md
```

#### 变更 5：CTO 模式切换模板更新

**文件**：`rdd-cto/references/design-guide.md` 模式切换上下文传递模板（L380-390）

- `RDD/changes/archive/` → `.rdd/changes/archive/`

#### 变更 6：UX 输入处理兼容新结构

**文件**：`rdd-ux/SKILL.md` L47/54

优先级 B 读取逻辑更新：
```
1. 扫描 .rdd/changes/archive/ 目录，按日期找最新归档
2. 读取 task.md
   - 若 overview.md 存在（新结构）：从 task.md 的"需求文件"字段定位各需求文件
   - 若 requirement.md 存在（旧结构）：读取 requirement.md
3. 筛选出 PM 已完成（✅）、UX 未完成（⬜）的 task
```

#### 变更 7：UX 产出物命名更新

**文件**：`rdd-ux/SKILL.md` L196 和 L205

现有：
```
文件名：design/ux-spec.md
...
将设计规格文档写入 design/ux-spec.md
```

改为：
```
文件名：design/{需求文件名}-ux.md，需求文件名从 task.md 的"需求文件"字段获取
...
将设计规格文档写入 design/{需求文件名}-ux.md
```

#### 变更 8：UX spec 模板命名说明更新

**文件**：`rdd-ux/references/spec-template.md`

更新产出物命名与归档章节，说明新命名规则。

#### 变更 9：DEV 输入处理兼容新结构

**文件**：`rdd-dev/SKILL.md` L77/96

两处引用 `requirement.md` 的地方增加兼容逻辑：
```
- 若 overview.md 存在（新结构）：读 overview.md + 各需求文件
- 若 requirement.md 存在（旧结构）：读 requirement.md
```

L79 设计引导模式中 `design/` 检查逻辑去掉对 `architecture.md` 的特判。

### 2.3 向后兼容策略

所有 skill（CTO/UX/DEV）的输入处理统一使用以下判断逻辑：

```
读取归档需求：
├── overview.md 存在 → 新结构
│   ├── 读 overview.md 获取背景和约束
│   ├── 读 task.md 获取任务状态和文件关联
│   └── 按需读取 task.md 中"需求文件"字段指向的具体需求文件
│
└── overview.md 不存在 → 旧结构
    ├── requirement.md 存在 → 读 requirement.md
    ├── 都不存在 → 回退检查 RDD/changes/archive/
    └── 都没有 → 报错提示
```

### 2.4 集成点描述

| 集成点 | 已有模块 | 调用关系 | 数据流向 | 时序约束 |
|--------|----------|----------|----------|----------|
| 设计文件命名来源 | task.md 需求文件字段 | CTO/UX 归档时读取 | task.md → 文件名推导 | task.md 必须先由 PM 填写 |
| 需求文件定位 | task.md 需求文件字段 | CTO/UX/DEV 输入处理时读取 | task.md → 定位具体需求文件 | task.md 必须存在 |

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 设计文件名中的 name 来源 | CTO/UX 自行确定 / 从 task.md 读取 | 从 task.md 读取 | 保证命名一致性，避免 CTO/UX 各起各的名字 |

## 四、实现步骤清单

1. 修改 `rdd-cto/SKILL.md`（输入处理、归档命名、模板引用）
2. 修改 `rdd-cto/references/design-guide.md`（归档结构示例、模式切换模板）
3. 修改 `rdd-ux/SKILL.md`（输入处理、产出物命名）
4. 修改 `rdd-ux/references/spec-template.md`（命名说明）
5. 修改 `rdd-dev/SKILL.md`（输入处理兼容、design/ 检查逻辑）

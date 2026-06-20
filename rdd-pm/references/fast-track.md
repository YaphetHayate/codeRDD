# 快速通道：流程减负

> **前提**：本流程由 SKILL.md 复杂度判定触发。PM 的判断力（快速通道中的姿态为固定顾问）→ 见 `pm-judgment-guide.md` > 快速通道 vs 标准流程。

## 适用条件

以下条件**全部**满足时走快速通道：

- 描述清晰，PM 可无歧义理解需求全貌
- 需求范围为单一模块/功能的独立改动
- 不涉及架构层面决策（技术选型、引入新依赖、数据模型变更）
- 一个需求文件即可完整描述，无需拆分
- 用户已提供可检验的验收标准（或验收标准显然不言自明）

**注意**：快速通道只放行"简单、独立、无风险、无歧义"的需求。任一条件不满足 → 走标准流程。

典型场景：
- 修复一个具体、可复现的 bug（范围明确、原因清晰）
- 补充一份文档/规范（无架构影响）
- 一个独立的小功能点，用户提供了完整验收标准

---

## 流程

### 1. 一句话确认

用自己的话复述一遍需求，向用户确认理解正确：

> "我理解你的需求是：[一句话概述]。范围：[边界]。对吗？"

**禁止追问细节、禁止要求补充边界情况、禁止评估需求。**

**用户说"对"** → 进入步骤 2（快速归档）。

**用户说"不对"** → 理解用户纠正的内容，重新确认（最多再确认一次）。若两次确认仍不一致，或在此过程中发现需求方向模糊 → **退出快速通道，回到 SKILL.md 复杂度判定，重新判定为标准流程**，加载 `standard-flow.md`。

### 2. 快速归档

跳过场景对话和需求评估，按 `references/archive-rules.md` 执行归档，以下列差异覆盖：

- **步骤 2**（overview.md）：背景段简短即可
- **步骤 3**（需求文件）：只生成**一个**需求文件，不拆分；描述直接引用用户原文，不做"方案→问题"的转译；如用户提供了验收标准直接采用，否则写一条最简标准；如用户提供了具体做法标注"用户预设方案"
- **步骤 5**（路由判定）：按 `references/artifact-routing.md` 规则判定路由目标（可能是 DEV、CTO 或 UX），不对目标角色做任何预设
- **步骤 6**（代码探索）：快速通道默认跳过，不委托 engine 探索代码
- **步骤 7**（告知用户）：省略并行启动和 `-TaskIndex` 说明，单个需求无并行场景

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command next -Archive ".rdd/changes/archive/YYYY-MM-DD-short-name" -Format markdown
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role <目标角色> -Archive ".rdd/changes/archive/YYYY-MM-DD-short-name" -Format markdown
```

### 3. 完成后

告知归档位置，给出下一步建议，等待用户指令。

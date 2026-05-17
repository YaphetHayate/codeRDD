# Skill 协同机制增强

## 背景

当前 RDD 工作流中，UX 的启动依赖 CTO 的 skill 匹配结果（CTO Phase 1.2 匹配到 rdd-ux 时才委派），形成 PM → CTO → UX 的串行链路。实际上 UX Phase 1 已能独立检测项目技术栈和组件库，不需要 CTO 前置判断。同时 CTO 和 UX 的设计文档格式完全独立，DEV 需要用不同的心智模型分别解读，在并行产出场景下会增加认知切换成本。

本需求旨在：1) 让 PM 作为流程入口决定角色参与，解除 CTO 对 UX 的门控；2) 为 CTO 和 UX 的设计文档建立统一的"接口层"，降低 DEV 的解读成本。

## 需求列表

### 需求 1：PM 驱动的角色编排

- **描述**：PM 在归档时通过 task.md 声明每个角色（CTO/UX/DEV/QA）的参与计划，各角色按计划独立启动，不再存在角色之间的门控依赖。具体地，CTO 的 skill 匹配仅用于自身设计参考，不再作为 UX 是否启动的判断依据。
- **验收标准**：
  1. task.md 模板新增"角色参与计划"区域，PM 归档时填写每个角色的参与状态（✅参与 / ⏭️跳过）及简要理由
  2. UX 的启动条件从"CTO 委派"变为"task.md 中 UX 标记为 ✅参与"
  3. CTO Phase 1.2 的 skill 匹配仍然保留，但仅用于 CTO 自身设计参考（如标记某需求涉及视觉设计，提醒 DEV 读 ux-spec.md）
  4. DEV Mode 1 进入条件调整为：CTO 或 UX 任一标记为 ✅ 即可进入设计引导模式（而非仅检查 CTO）
  5. 以下场景均成立：仅 CTO 参与、仅 UX 参与、CTO+UX 并行、两者都跳过（直通 DEV）
- **优先级**：高
- **影响范围**：rdd-pm（task-template.md）、rdd-cto（SKILL.md Phase 1.2）、rdd-ux（SKILL.md 入口条件）、rdd-dev（SKILL.md Mode 1 条件判断）
- **边界与异常**：CTO 和 UX 并行工作时，各自独立检测技术栈可能出现分歧——此风险的检测与上报机制由后续环节（CTO/DEV）设计，本需求不处理

### 需求 2：设计文档接口层标准化

- **描述**：CTO 和 UX 的设计文档共享统一的 frontmatter 字段集和需求覆盖映射章节，但不统一正文结构。DEV 通过统一的"接口层 → 内容层"两步法解读两份文档。
- **验收标准**：
  1. CTO 和 UX 设计文档共享统一的 frontmatter 字段：`requirement_id`、`priority`、`depends_on`、`status`、`analysis_date`、`role`（值为 `cto` 或 `ux`）
  2. 两份文档各自包含"需求覆盖映射"章节，格式为表格：`| 需求 ID | 本文档负责范围 | 对应章节 | 关联文档 |`
  3. UX 文档新增对 CTO 文档的反向引用（当前仅有 CTO → UX 的单向引用）
  4. 两份文档的正文结构不做统一——CTO 保持技术方案格式，UX 保持视觉规范格式
  5. DEV SKILL.md 新增统一的文档解读指引：先读 frontmatter 确认状态 → 读需求覆盖映射定位章节 → 按角色分别进入正文
- **优先级**：中
- **影响范围**：rdd-cto（references/design-guide.md）、rdd-ux（references/spec-template.md）、rdd-dev（SKILL.md 文档解读部分）
- **边界与异常**：历史归档（14 个）不需要回溯修改，新格式从本需求归档开始生效

## 关键约束

- 改动仅涉及 skill 配置文件（SKILL.md、references/*.md），不涉及生产代码
- 历史归档保持不变，新格式向前兼容
- UX 作为 domain-advisor 和 workflow role 的双重身份（skill-registry.md 中已记录）不变

## 讨论记录

- 用户确认 CTX+UX 并行由 PM 在 task.md 中决定角色参与，而非 CTO 门控
- 用户确认"接口层标准化"粒度为 frontmatter 统一 + 需求覆盖映射表，正文不做统一
- DEV 读取两份文档尚无实际痛点，此为前瞻性优化
- CTO 和 UX 并行时的技术栈一致性风险由后续环节处理，本需求不覆盖

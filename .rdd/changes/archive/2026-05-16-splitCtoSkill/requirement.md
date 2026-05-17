# 需求：拆分 RDD-CTO SKILL.md 非核心内容到 references 目录

## 背景

RDD-CTO 的 SKILL.md 当前约 380 行，主流程与方法论细节（流程图、判定表格、格式模板）混在一起，导致文件过长、可读性下降。references/ 目录下已有 5 个拆分文件（analysis-l2.md、analysis-l3.md、design-guide.md、industry-research.md、self-check.md），但仍有部分详细内容留在主文件中。需要继续将非核心内容拆分到 references/，保持主文件只保留角色定义、红线约束和核心流程骨架。

## 需求列表

### 需求 1：拆分代码结构质量评估到 references

- **描述**：将 SKILL.md 中 3.5 节"代码结构质量评估"的完整内容（质量评估流程图、区分标准表格、暂停提醒话术、设计引用要求、技术选型约束）拆分到 `references/code-quality-assessment.md`，SKILL.md 中替换为一句引用指引
- **验收标准**：SKILL.md 中 3.5 节替换为引用指引（如"读取 references/code-quality-assessment.md 执行代码结构质量评估"）；新文件内容自包含、可独立阅读；引用风格与现有 references 文件一致
- **优先级**：高
- **影响范围**：`rdd-cto/SKILL.md`、新增 `rdd-cto/references/code-quality-assessment.md`

### 需求 2：拆分能力自评到 references

- **描述**：将 SKILL.md 中 1.2 节"能力自评"的完整内容（能力自评流程图、自评约束说明）拆分到 `references/capability-self-assessment.md`，SKILL.md 中替换为一句引用指引
- **验收标准**：SKILL.md 中 1.2 节替换为引用指引；新文件内容自包含
- **优先级**：高
- **影响范围**：`rdd-cto/SKILL.md`、新增 `rdd-cto/references/capability-self-assessment.md`

### 需求 3：拆分领域识别与 Skill 匹配到 references

- **描述**：将 SKILL.md 中 1.3 节"领域识别与 Skill 匹配"的完整内容（领域标签提取规则、匹配流程图、分级结果表格式、匹配结果汇总表）拆分到 `references/skill-matching.md`，SKILL.md 中替换为一句引用指引
- **验收标准**：SKILL.md 中 1.3 节替换为引用指引；新文件内容自包含
- **优先级**：高
- **影响范围**：`rdd-cto/SKILL.md`、新增 `rdd-cto/references/skill-matching.md`

### 需求 4：拆分全局架构评审到 references

- **描述**：将 SKILL.md 中 Phase 2.5"全局架构评审"的完整内容（评审内容清单、评审结果呈现表格、评审后处理流程）拆分到 `references/global-review.md`，SKILL.md 中替换为一句引用指引
- **验收标准**：SKILL.md 中 Phase 2.5 替换为引用指引；新文件内容自包含
- **优先级**：高
- **影响范围**：`rdd-cto/SKILL.md`、新增 `rdd-cto/references/global-review.md`

### 需求 5：整体验收

- **描述**：拆分完成后验证 SKILL.md 整体质量和所有引用路径的正确性
- **验收标准**：SKILL.md 行数 ≤ 250 行；所有 `references/xxx.md` 引用路径在文件系统中真实存在；通读 SKILL.md 主流程逻辑通顺、无断裂；拆分后的文件内容与原内容功能等价，无遗漏
- **优先级**：高

## 关键约束

- 拆分出的 references 文件必须自包含，不能依赖主文件上下文（不能出现"回到主流程第 X 步"等写法）
- 引用风格与现有 references 文件保持一致（一句引用指引 + 关键结论即可）
- 纯结构重组，不改变任何功能逻辑

## 讨论记录

- 确认了 4 个拆分段落：代码结构质量评估（3.5节）、能力自评（1.2节）、领域识别与Skill匹配（1.3节）、全局架构评审（Phase 2.5）
- 引用方式沿用现有模式（如 `详见 references/xxx.md`）
- 目标将 SKILL.md 从约 380 行降至约 220 行

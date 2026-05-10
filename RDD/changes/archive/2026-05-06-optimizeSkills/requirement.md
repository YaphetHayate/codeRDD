# 需求清单 — Skill 文件优化

## 背景

当前项目下 5 个 RDD skill 文件存在以下问题：

- **rdd-dev** (591行) 是最大文件，没有任何 reference 拆分，大量模板和指南内容嵌在主文件里
- **rdd-qa** (349行) 与 reference 之间存在内容重复（测试用例模板各写一遍）
- **rdd-cto** (302行) 部分模板内容可移入已有 reference，主文件可精简
- **code-compass** (75行) 引用了两个不存在的 reference 文件，功能无法正常执行
- rdd-pm (99行) 状态良好，无需调整

核心约束：**优化不改功能** — SKILL.md 的行为逻辑完全不变，只做"内容搬家"和"去重"。

## 需求列表

### 需求 1：rdd-dev — 模板和指南内容移入 references

- **描述**：将 rdd-dev/SKILL.md 中的纯模板、格式示例、详细指南等非核心执行指令移入 `rdd-dev/references/` 目录，主文件保留角色定义、行为规则、工作流逻辑
- **验收标准**：
  1. `rdd-dev/SKILL.md` 减少至 ~400 行以内
  2. 新建 `rdd-dev/references/` 目录，包含以下文件：
     - `prompt-template.md` — 子 agent Prompt 模板（原第 330-375 行）
     - `review-guide.md` — 分层审查策略 + 结果处理策略表（原第 379-396 行）
     - `exception-handling.md` — 四种异常场景的处理指南（原第 511-558 行）
     - `templates.md` — 拆分计划/验证报告/进度追踪呈现格式（原第 274-288、409-419、428-442 行）
     - `mode-integration.md` — 与上下游模式的衔接关系表（原第 561-581 行）
  3. 每个被移出的内容在原位置替换为简短的 reference 引用指令
  4. 移除后 SKILL.md 的执行行为与移出前完全一致
- **优先级**：高
- **影响范围**：`rdd-dev/SKILL.md`，新建 `rdd-dev/references/` 目录及 5 个文件
- **依赖关系**：无

### 需求 2：rdd-qa — 消除内容重复

- **描述**：移除 rdd-qa/SKILL.md 中与 `references/test-case-guide.md` 重复的内容，精简纯参考内容
- **验收标准**：
  1. 移除 SKILL.md 第 172-185 行的测试用例模板（已在 test-case-guide.md 第 76-88 行存在）
  2. SKILL.md 第 210 行测试命名规范精简为引用 reference
  3. SKILL.md 第 217-229 行测试文件组织目录树移入 `references/test-case-guide.md`
  4. SKILL.md 减少至 ~320 行以内
- **优先级**：中
- **影响范围**：`rdd-qa/SKILL.md`，追加内容到 `rdd-qa/references/test-case-guide.md`
- **依赖关系**：无

### 需求 3：rdd-cto — 移除冗余和精简

- **描述**：移除 rdd-cto/SKILL.md 中与 design-guide.md 重复的内容，将格式模板移入已有 reference，精简可压缩的段落
- **验收标准**：
  1. 移除第 196-198 行图表选用规则（design-guide.md 第 71 行已覆盖），替换为 reference 引用
  2. 将以下模板移入 `references/design-guide.md`：
     - 分级结果呈现表（原第 136-146 行）
     - L1 快速结论格式（原第 153-159 行）
     - 确认总览表（原第 231-245 行）
     - 归档目录结构示例（原第 254-263 行）
     - 自动流转上下文传递模板（原第 277-287 行）
  3. 精简以下段落：模式边界与红线（第 27-61 行）、输入处理（第 64-117 行）、Phase 1（第 120-183 行）、Phase 4（第 249-294 行）
  4. SKILL.md 减少至 ~180 行以内
- **优先级**：中
- **影响范围**：`rdd-cto/SKILL.md`，追加内容到 `rdd-cto/references/design-guide.md`
- **依赖关系**：无

### 需求 4：code-compass — 修复缺失的 reference 引用

- **描述**：code-compass/SKILL.md 第 74-75 行引用了 `references/map/map.md` 和 `references/readme-generator/readme-generator.md`，但这两个文件不存在
- **验收标准**：
  1. 所有 reference 路径真实存在（Glob 可查到）
  2. 如果 `/map` 和 `/readme` 是核心功能，创建对应的 reference 文件（内容需与 SKILL.md 描述一致）
  3. 如果 `/map` 和 `/readme` 暂未实现，移除或标注为待实现
- **优先级**：高
- **边界与异常**：创建新 reference 文件时，内容需与 SKILL.md 中描述的功能一致。需确认 `/map` 和 `/readme` 功能的预期行为
- **影响范围**：`code-compass/SKILL.md`，可能新建 `code-compass/references/map/map.md` 和 `code-compass/references/readme-generator/readme-generator.md`
- **依赖关系**：无

### 需求 5：跨 skill 一致性检查

- **描述**：确保所有 skill 的 reference 引用路径正确、引用方式一致
- **验收标准**：
  1. 所有 SKILL.md 中的 reference 路径均可通过 Glob 找到对应文件
  2. 各 skill 引用 reference 的写法一致
  3. 不影响任何 skill 的触发逻辑
- **优先级**：低
- **影响范围**：所有 SKILL.md
- **依赖关系**：依赖需求 1-4 完成后执行

## 关键约束

- **不改功能**：所有移动和精简只能改变内容位置，不能改变执行行为
- **不新增业务逻辑**：只做内容搬家、去重、精简

## 讨论记录

- 用户选择全量优化（5个 skill 均处理）
- rdd-pm 状态良好，不在优化范围内
- 需求 4（code-compass）需要确认 `/map` 和 `/readme` 功能的完整性再决定是创建还是移除引用

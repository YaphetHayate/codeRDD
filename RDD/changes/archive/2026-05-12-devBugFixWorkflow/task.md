# Task Tracker

> 状态说明：✅ 完成 | ⬜ 待开始 | ⏭️ 跳过 | 🔄 进行中

## 总览

| Task | 优先级 | PM | CTO | DEV | QA |
|------|--------|----|-----|-----|----|
| 1. DEV 新增 Bug 修复专用工作流 | 高 | ✅ | ✅ | ✅ | ⬜ |
| 2. PM Bug 验收标准锚定用户可见结果 | 高 | ✅ | ✅ | ✅ | ⬜ |
| 3. DEV Bug 修复后全链路验证 | 中 | ✅ | ✅ | ✅ | ⬜ |

## Task 1: DEV 新增 Bug 修复专用工作流

- **需求来源**：requirement.md > 需求 1
- **优先级**：高
- **PM**：✅
- **CTO**：✅（设计文档：`design/architecture.md` 第二章）
- **DEV**：✅
- **改动文件**：
  - `rdd-dev/SKILL.md`：新增模式四（Bug 修复模式）完整章节 + 输入处理 Priority D 增加 bug 检测路由
  - `rdd-dev/references/bug-register-template.md`：新增 bug register 格式模板
  - `rdd-dev/references/exception-handling.md`：实现卡住了增加 bug 处理分支
  - `rdd-dev/references/mode-integration.md`：向上游反馈表新增 3 行
- **QA**：⬜

## Task 2: PM Bug 验收标准锚定用户可见结果

- **需求来源**：requirement.md > 需求 2
- **优先级**：高
- **PM**：✅
- **CTO**：✅（设计文档：`design/architecture.md` 第四章）
- **DEV**：✅
- **改动文件**：
  - `rdd-pm/references/execution-strategy.md`：Bug 修复章节验收标准规则补充（禁止否定式、正反示例、追问话术）
- **QA**：⬜

## Task 3: DEV Bug 修复后全链路验证

- **需求来源**：requirement.md > 需求 3
- **优先级**：中
- **PM**：✅
- **CTO**：✅（设计文档：`design/architecture.md` 第二章 Step 5，与 Task 1 合并设计）
- **DEV**：✅
- **改动文件**：
  - `rdd-dev/SKILL.md`：冒烟验证章节新增"Bug 修复场景验证"专项 + Mode 4 Step 5 场景验证闭环
- **QA**：⬜

## 设计决策记录

- Task 1 和 Task 3 合并设计：诊断→修复→验证是完整闭环，拆开设计会导致衔接不清
- Bug 修复模式定位为"模式四 + 侧任务属性"：独立入口时作为 Mode 4，从其他模式切入时作为侧任务
- 引入 Bug Register 机制（`RDD/changes/bug-register.md`）：非阻塞 bug 记录待后续处理

# Task Tracker

> 状态说明：✅ 完成 | ⬜ 待开始 | ⏭️ 跳过 | 🔄 进行中

## 总览

| Task | 优先级 | PM | CTO | DEV | QA |
|------|--------|----|-----|-----|----|
| 1. 确定性索引构建脚本 | 高 | ✅ | ✅ | ✅ | ⬜ |
| 2. 脚本未解决项的报告输出 | 高 | ✅ | ✅ | ✅ | ⬜ |
| 3. 增量更新支持 | 高 | ✅ | ✅ | ✅ | ⬜ |
| 4. 更新 map.md 工作流指引 | 高 | ✅ | ✅ | ✅ | ⬜ |
| 5. AI 补充处理流程 | 中 | ✅ | ✅ | ✅ | ⬜ |

## Task 1: 确定性索引构建脚本

- **需求来源**：requirement.md > 需求 1
- **优先级**：高
- **PM**：✅
- **CTO**：✅ (design/001-script-architecture.md)
- **DEV**：✅
- **QA**：⬜

## Task 2: 脚本未解决项的报告输出

- **需求来源**：requirement.md > 需求 2
- **优先级**：高
- **PM**：✅
- **CTO**：✅ (design/001-script-architecture.md，与 Task 1 合并设计)
- **DEV**：✅ (与 Task 1 合并实现，pending.json 输出已包含)
- **QA**：⬜

## Task 3: 增量更新支持

- **需求来源**：requirement.md > 需求 3
- **优先级**：高
- **PM**：✅
- **CTO**：✅ (design/001-script-architecture.md，与 Task 1 合并设计)
- **DEV**：✅ (incremental.py + build_index.py 增量检测逻辑)
- **QA**：⬜

## Task 4: 更新 map.md 工作流指引

- **需求来源**：requirement.md > 需求 4
- **优先级**：高
- **PM**：✅
- **CTO**：✅ (design/002-map-workflow.md)
- **DEV**：✅ (references/map/map.md 已改写为 v3.0 脚本+AI 协作版)
- **QA**：⬜

## Task 5: AI 补充处理流程

- **需求来源**：requirement.md > 需求 5
- **优先级**：中
- **PM**：✅
- **CTO**：✅ (design/002-map-workflow.md，与 Task 4 合并设计)
- **DEV**：✅ (map.md 第三步、第四步已定义 AI 补充流程)
- **QA**：⬜

# Task Tracker

> 状态说明：✅ 完成 | ⬜ 待开始 | ⏭️ 跳过 | 🔄 进行中

## 总览

| Task | 优先级 | PM | CTO | DEV | QA |
|------|--------|----|-----|-----|----|
| 1. 内置 obj.method() 噪声过滤 | 高 | ✅ | ⏭️ | ✅ | ⬜ |
| 2. 项目级过滤配置支持 | 中 | ✅ | ⏭️ | ✅ | ⬜ |
| 3. AI 自动生成过滤配置 | 中 | ✅ | ⏭️ | ✅ | ⬜ |
| 4. 修复 Parser 误解析 bug | 高 | ✅ | ⏭️ | ✅ | ⬜ |

## Task 1: 内置 obj.method() 噪声过滤

- **需求来源**：requirement.md > 需求 1
- **优先级**：高
- **PM**：✅
- **CTO**：⏭️ (跳过设计)
- **DEV**：✅ (constants.py 新增 SKIP_METHOD_NAMES ~100 个，extractors.py _filter_calls 后置过滤)
- **QA**：⬜

## Task 2: 项目级过滤配置支持

- **需求来源**：requirement.md > 需求 2
- **优先级**：中
- **PM**：✅
- **CTO**：⏭️ (跳过设计)
- **DEV**：✅ (extractors.py load_skip_methods 加载 .code-compass/filters.json)
- **QA**：⬜

## Task 3: AI 自动生成过滤配置

- **需求来源**：requirement.md > 需求 3
- **优先级**：中
- **PM**：✅
- **CTO**：⏭️ (跳过设计)
- **DEV**：✅ (map.md 第三步增加 3a 噪声过滤环节)
- **QA**：⬜

## Task 4: 修复 Parser 误解析 bug

- **需求来源**：requirement.md > 需求 4
- **优先级**：高
- **PM**：✅
- **CTO**：⏭️ (跳过设计)
- **DEV**：✅ (extractors.py _filter_calls 中过滤 except/in 关键字)
- **QA**：⬜

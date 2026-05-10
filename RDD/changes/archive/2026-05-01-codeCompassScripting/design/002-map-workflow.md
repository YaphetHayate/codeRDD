---
requirement_id: 需求4+5
priority: 高
depends_on:
  - 需求1+2+3
blocks: []
analysis_date: 2026-05-01
status: confirmed
tech_stack:
  - Markdown
estimated_effort: 小 (1天)
---

# 更新 map.md 工作流 + AI 补充流程 — 设计文档

## 一、需求概述

将 `references/map/map.md` 的纯 AI 执行流程改写为脚本+AI 协作流程。改写后 AI Agent 先调用 Python 脚本完成确定性工作，再基于 pending.json 补充复杂调用推断和入口描述生成。

## 二、技术方案

### 2.1 改写策略

**保留（不动）：**
- 数据格式定义（manifest、methods、calls、entries 的 JSON 结构）
- 职责推测参考表
- 核心原则和语言策略

**删除：**
- 第四步到第八步的详细 regex pattern 和逐文件操作指引（已由脚本实现）
- 第十步到第十二步的手动操作描述（已由脚本实现）
- 增量更新的逐 Phase 手动操作指引（已由脚本实现）

**新增：**
- 脚本调用指令
- pending.json 格式定义
- AI 补充流程指引

### 2.2 改写后的文档结构

```
# 代码索引生成器（v3.0）

## 核心原则 (保留，微调措辞)
  - 新增"脚本与 AI 各司其职"原则

## 语言策略 (保留)

## 存储结构 (保留)
  - 新增 pending.json 说明

## 数据格式定义
  - manifest.json (保留)
  - methods/*.json (保留)
  - calls/*.json (保留)
  - entries.json (保留)
  - pending.json (新增)

## 构建流程

### 第一步：运行构建脚本

  指令：python {skill_path}/scripts/build_index.py {project_path}
  
  脚本自动完成：
  - 文件扫描与语言识别
  - Phase A-D
  - 入口点识别
  - manifest.json、overview.md、entries.json 生成
  - pending.json 生成

### 第二步：检查待处理项

  读取 .code-compass/pending.json
  - unresolved_calls 不为空 → 第三步
  - entries_without_description 不为空 → 第四步
  - 都为空 → 构建完成

### 第三步：AI 补充复杂调用关系

  对每条 unresolved_calls：
  1. Read 源文件，定位 caller_line 附近代码
  2. 根据 import 和上下文推断 callee 来源文件
  3. 更新 calls JSON（补充 callee_file，confidence → high）
  4. 同步更新目标文件的 called_by
  完成后更新 pending.json

### 第四步：AI 生成入口描述

  (沿用现有渐进式深度逻辑，不改动)
  
  对每条 entries_without_description：
  1. Read handler 函数所在文件
  2. 从 calls/*.json 获取直接调用列表
  3. 从 methods/*.json 获取签名和 docstring
  4. 生成 1-2 句中文业务摘要
  5. 更新 entries.json
  完成后更新 pending.json

## 增量更新流程

  运行同一命令，脚本自动检测变更。
  AI 检查更新后的 pending.json，执行第三步和第四步。

## /map --refresh 命令

  python {skill_path}/scripts/build_index.py {project_path} --refresh
  AI 执行第四步生成描述。

## 职责推测参考 (保留)
```

### 2.3 篇幅变化

| 部分 | 改写前 | 改写后 | 说明 |
|------|--------|--------|------|
| 核心原则 | ~15行 | ~20行 | 新增脚本协作原则 |
| 语言策略 | ~5行 | ~5行 | 不变 |
| 存储结构 | ~15行 | ~20行 | 新增 pending.json |
| 数据格式定义 | ~80行 | ~100行 | 新增 pending.json 格式 |
| 构建流程（12步） | ~450行 | ~80行 | 12步 → 4步，细节交给脚本 |
| 增量更新流程 | ~80行 | ~15行 | 交给脚本 |
| --refresh | ~15行 | ~10行 | 简化 |
| 职责推测参考 | ~70行 | ~70行 | 不变 |
| **总计** | **~647行** | **~320行** | **缩减约 50%** |

### 2.4 关键细节

**脚本路径解析：** map.md 中使用相对路径引用脚本。AI Agent 根据 map.md 自身所在位置推导：

```
map.md 位置: code-compass/references/map/map.md
脚本位置:    code-compass/scripts/build_index.py
相对路径:    ../../scripts/build_index.py
```

**向后兼容：** 数据格式定义完全保留，现有消费者（overview.md、entries.json 的读取方）无需任何改动。

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 改写范围 | 全量改写 / 增量修改 | 全量改写 | 结构变化太大，增量修补可读性差 |
| 数据格式 | 保留 / 修改 | 保留 | 向后兼容，避免破坏消费者 |

## 四、风险与应对

| 风险 | 影响 | 应对措施 | 优先级 |
|------|------|----------|--------|
| AI Agent 无法正确解析脚本路径 | 脚本调用失败 | 在 map.md 中同时给出相对路径和绝对路径推导逻辑 | P0 |
| 改写后的指令不够清晰 | AI 行为不符合预期 | 改写后用 evals 验证，确保现有测试用例仍能通过 | P0 |

## 五、实现优先级建议

在需求 1+2+3（脚本）完成并验证后执行。可先在脚本验证通过后再改写 map.md，避免指令与实际能力不匹配。

## 六、实现步骤清单

1. 基于上述结构重写 `references/map/map.md`
2. 确保 JSON 格式定义与现有一致
3. 编写 pending.json 格式定义
4. 编写 AI 补充流程指引（第三步、第四步）
5. 更新 SKILL.md 中的触发说明（如需）
6. 用 evals.json 中的测试用例验证改写后的 map.md 能被 AI 正确理解和执行

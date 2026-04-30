---
name: code-compass
description: >
  项目代码分析与索引工具集。自动识别项目技术栈、分析代码结构、提取函数调用关系、
  识别入口点并生成业务描述、生成项目文档。
  当用户提到"项目文档"、"代码分析"、"项目结构"、"生成文档"、"readme"、"documentation"、
  "project structure"、"code analysis"、"代码全景图"、"代码地图"、"code map"、
  "调用关系"、"入口点"、"代码导航"时触发此 skill。
  也应在用户想了解一个项目、整理项目信息、写项目说明、定位代码、评估改动影响时主动触发。
---

# Code Compass — 项目代码分析与索引工具集

本 skill 是一个工具集，根据用户的意图路由到不同的子功能。读取下方的功能列表，判断用户需要哪个功能，然后读取对应的参考文件执行。

## 可用功能

### `/readme` — 生成 README 文档

**触发关键词**：生成 README、写 README、项目说明文档、项目介绍、generate readme、project documentation

**触发命令**：`/readme`

**功能**：分析当前项目目录的代码结构，自动生成专业的 README.md 文档。支持自动识别任意语言和框架。

**执行方式**：读取 `references/readme-generator/readme-generator.md`，按其中的完整工作流程执行。

---

### `/map` — 代码索引（方法签名 + 调用关系 + 入口导航）

**触发关键词**：代码全景图、项目全景、代码地图、code map、panorama、项目结构概览、代码结构总览、代码导航、调用关系、入口点、更新索引

**触发命令**：`/map`（全量构建或增量更新）、`/map --refresh`（刷新 stale 入口描述）

**功能**：
- 扫描项目源码，生成模块化的代码索引系统
- 提取每个源码文件的方法签名
- 提取函数级调用关系（二元关系：A 调用 B），支持按需跳转查询"谁调用了我"和"我调用了谁"
- 识别 API 路由、定时任务、CLI 命令等入口点，生成业务摘要描述
- 支持基于文件变更检测的增量更新，关系数据实时更新，描述数据允许 stale 标记后延迟刷新
- 支持 Python、TypeScript/JavaScript 两种语言（优先），Java、Go 后续扩展

**输出结构**：
```
.code-compass/
├── manifest.json      # 全局索引（文件列表、mtime、hash）
├── overview.md        # 目录结构概览（人类可读）
├── methods/           # 方法签名数据（每文件一个 JSON）
├── calls/             # 调用关系数据（每文件一个 JSON）
└── entries.json       # 入口点汇总（API路由 + 定时任务 + CLI）
```

**AI Agent 使用方式**：
1. 读取 `manifest.json` 获取全局索引
2. 根据目标文件路径，读取对应的 `methods/*.json` 查看方法签名
3. 读取对应的 `calls/*.json` 查看调用关系（calls 出向 + called_by 入向）
4. 读取 `entries.json` 扫描入口描述，找到业务概念对应的入口点
5. 从入口出发，沿调用关系导航到具体函数

**执行方式**：读取 `references/map/map.md`，按其中的完整工作流程执行。

---

## 路由规则

1. 如果用户明确使用了命令（如 `/readme`、`/map`），直接执行对应功能
2. 如果用户用自然语言描述需求，根据关键词匹配最相关的功能
3. 如果无法确定，向用户确认需要哪个功能
4. 匹配到功能后，读取对应的参考文件开始执行

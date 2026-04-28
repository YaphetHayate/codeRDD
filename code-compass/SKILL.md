---
name: code-compass
description: >
  项目代码分析与文档生成工具集。自动识别项目技术栈、分析代码结构、生成项目文档。
  当用户提到"项目文档"、"代码分析"、"项目结构"、"生成文档"、"readme"、"documentation"、
  "project structure"、"code analysis"时触发此 skill。
  也应在用户想了解一个项目、整理项目信息、写项目说明时主动触发。
---

# Code Compass — 项目代码分析与文档工具集

本 skill 是一个工具集，根据用户的意图路由到不同的子功能。读取下方的功能列表，判断用户需要哪个功能，然后读取对应的参考文件执行。

## 可用功能

### `/readme` — 生成 README 文档

**触发关键词**：生成 README、写 README、项目说明文档、项目介绍、generate readme、project documentation

**触发命令**：`/readme`

**功能**：分析当前项目目录的代码结构，自动生成专业的 README.md 文档。支持自动识别任意语言和框架。

**执行方式**：读取 `references/readme-generator/readme-generator.md`，按其中的完整工作流程执行。

---

### `/analyze` — 项目结构分析（占位，暂未实现）

**触发关键词**：分析项目、项目结构、代码结构、analyze project、project structure

**功能**：深度分析项目架构，输出模块依赖图、代码统计、架构评估报告。

---

## 路由规则

1. 如果用户明确使用了命令（如 `/readme`），直接执行对应功能
2. 如果用户用自然语言描述需求，根据关键词匹配最相关的功能
3. 如果无法确定，向用户确认需要哪个功能
4. 匹配到功能后，读取对应的参考文件开始执行

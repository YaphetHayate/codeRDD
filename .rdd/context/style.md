# 代码风格约定

## 命名规范

- 文件命名：kebab-case，如 `context-guide.md`、`artifact-template.md`
- 目录命名：kebab-case，如 `rdd-cto/`、`references/`
- Skill 名称：UPPER-kebab（如 `RDD-CTO`、`RDD-DEV`）或 lowercase（如 `rdd-engine`）
- 函数/方法命名：N/A（无代码文件，纯 Markdown 项目）
- 变量命名：N/A
- 常量命名：N/A

## 代码格式

- 缩进：2 spaces
- 行宽限制：无明显限制，在 Markdown 中以可读性为优先
- 引号风格：N/A
- 尾逗号：N/A
- 分号：N/A
- 括号风格：N/A
- 空行约定：Markdown 段落间单空行，章节间增加空行分隔

## 文件结构约定

- 每个 skill 的入口文件为 `SKILL.md`，使用 YAML frontmatter（`---` 包裹）
- YAML frontmatter 必须包含 `name` 和 `description` 字段
- 技能元信息（name, description）与工作流指令在同一个 SKILL.md 中
- 详细策略文件放在 `references/` 子目录下
- SKILL.md 中用 `> 完整流程见 references/xxx.md` 格式引用策略文件
- 归档使用 `.rdd/changes/archive/` 目录，命名格式为 `YYYY-MM-DD-需求简称`
- 设计文档放在 `design/` 子目录，命名格式为 `{需求文件名}-{角色}.md`

## 项目特定约定

- 角色模式全部通过 SKILL.md 定义，无外部脚本
- 各角色 SKILL.md 均包含：核心原则、模式边界与红线、输入处理、工作流程、归档与退出
- 角色间通过模式切换指令协同（`/RDD-PM`、`/RDD-CTO` 等）
- rdd-engine 是共享基础设施层，不做决策只提供知识服务
- task.md 使用 emoji 状态标记：✅/⬜/⏭️/🔄

## 风格不一致处

> 未发现明显风格不一致。

---
生成时间：2026-05-24T16:24:00
采样文件：rdd-cto/SKILL.md, rdd-dev/SKILL.md, rdd-engine/SKILL.md, rdd-pm/SKILL.md, rdd-ux/SKILL.md

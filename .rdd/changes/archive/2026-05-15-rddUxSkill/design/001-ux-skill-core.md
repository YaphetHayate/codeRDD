---
requirement_id: 需求 1+2+3
priority: 高
depends_on: []
blocks:
  - 需求 4+5（流程集成）
analysis_date: 2026-05-15
status: confirmed
---

# UX Skill 本体 — 设计文档

## 一、需求概述

新建 RDD-UX skill，具备两种核心能力：视觉参考分析（翻译者模式）和独立设计（创作者模式），最终产出结构化的设计规格文档供 DEV 直接使用。

## 二、技术方案

### 2.1 目录结构

```
rdd-ux/
├── SKILL.md                        # 主技能定义
└── references/
    ├── execution-strategy.md       # 工作模式策略（翻译者/创作者/混合）
    ├── visual-analysis-guide.md    # 视觉参考分析方法论
    ├── design-methodology.md       # 独立设计方法论
    └── spec-template.md            # 设计规格产出模板
```

遵循现有 skill 的组织模式（参考 `rdd-cto/`、`rdd-qa/`）。

### 2.2 SKILL.md 核心架构

**定位**：UX 设计师角色，"只设计不动手"原则（同 `rdd-cto/SKILL.md` 第 19 行）。

**三种工作模式路由：**

```
用户输入
  │
  ├── 提供了参考图（PNG/JPG/URL）───────▶ 翻译者模式（Translator）
  │   加载 references/visual-analysis-guide.md
  │
  ├── 只有业务需求（无视觉参考）────────▶ 创作者模式（Creator）
  │   加载 references/design-methodology.md
  │
  └── 两者都有 ──────────────────────────▶ 混合模式（Hybrid）
      先翻译参考图提取基础视觉系统，再基于需求补充未覆盖部分
```

**核心流程：**

```
输入处理（确定模式 + 读取 requirement.md）
  │
  ├── Phase 1: 项目视觉上下文理解
  │   ├── 了解项目前端技术栈（CSS 框架、组件库、设计系统）
  │   ├── 了解项目现有视觉风格
  │   └── 读取 requirement.md 理解需求
  │
  ├── Phase 2: 视觉分析 / 设计创建
  │   ├── 翻译者模式：系统性分解参考图（→ visual-analysis-guide.md）
  │   ├── 创作者模式：从需求生成设计方案（→ design-methodology.md）
  │   └── 混合模式：先翻译再补充
  │
  ├── Phase 3: 设计规格产出
  │   └── 按 spec-template.md 格式输出设计规格文档
  │
  └── Phase 4: 归档与引导下一步
      ├── 写入 design/ 目录
      └── 引导用户 → DEV 模式
```

**红线与边界：**

- 不写业务代码，不创建分支，不执行 git 操作
- 唯一写入权限：`RDD/changes/archive/.../design/` 下的 `.md` 文件 + `task.md` UX 列更新
- 退出方式与 PM/CTO/DEV/QA 一致：显式声明切换
- UX 不替代 CTO——技术架构仍是 CTO 职责

### 2.3 关键设计决策

**决策 1：框架感知而非框架绑定**

设计方法论不依赖任何特定 CSS 框架，但产出物会适配项目技术栈：
- 项目用 Tailwind → 设计 token 映射为 Tailwind 类名
- 项目用 CSS Modules → 输出 CSS 变量定义
- 项目用 CSS-in-JS → 输出 JS 对象格式的 token

实现方式：Phase 1 先了解项目技术栈，Phase 3 产出时适配。

**决策 2：视觉分析依赖 MCP analyze_image 工具**

翻译者模式使用 `mcp__4_5v_mcp__analyze_image` 工具做参考图的系统性分析。分析 prompt 不是"描述这张图"，而是按五步分解法的结构化指令。

**决策 3：产出物与 CTO 设计文档同目录并存**

UX 的产出物归档在 `design/ux-spec.md`，CTO 的产出物在 `design/001-xxx.md` 等。DEV 读取时同时参考两份文档。

### 2.4 references 文件职责

| 文件 | 职责 | 加载时机 |
|------|------|----------|
| `execution-strategy.md` | 三种模式的详细执行流程、输入输出规则、模式切换条件 | Phase 2 前 |
| `visual-analysis-guide.md` | 五步视觉分解法（整体布局→设计Token→组件识别→交互状态→信息层级） | 翻译者/混合模式 |
| `design-methodology.md` | 七步设计法（需求理解→信息架构→布局→视觉系统→组件→交互→一致性检查） | 创作者/混合模式 |
| `spec-template.md` | 设计规格文档的标准化模板、每章格式要求、技术栈适配示例 | Phase 3 产出前 |

### 2.5 集成点描述

| 集成点 | 已有模块 | 调用关系 | 数据流向 | 时序约束 |
|--------|----------|----------|----------|----------|
| 视觉分析 | `mcp__4_5v_mcp__analyze_image` | UX 调用 MCP 工具 | 参考图 URL → 结构化分析结果 | Phase 2 翻译者模式 |
| 需求读取 | `RDD/changes/archive/.../requirement.md` | UX 读取 | requirement.md → UX 的设计输入 | Phase 1 |
| 产出物写入 | `RDD/changes/archive/.../design/` | UX 写入 | 设计规格 → design/ux-spec.md | Phase 4 |
| 状态更新 | `RDD/changes/archive/.../task.md` | UX 更新 UX 列 | ⬜ → ✅ | Phase 4 |
| 项目上下文 | code-compass `/understand` | UX 调用（可选） | 项目结构 → 技术栈信息 | Phase 1 |

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 产出物位置 | A. 独立 design-ux/ 目录 / B. 与 CTO 同目录 | B | 避免目录膨胀，DEV 已习惯读取 design/ |
| 工作模式数量 | A. 两种 / B. 三种（含混合） | B | 实际场景中用户经常同时提供参考和需求 |
| 技术栈适配 | A. 固定输出 CSS 变量 / B. 框架感知 | B | 项目技术栈多样，固定格式会降低实用性 |

## 四、风险与应对

| 风险 | 影响 | 应对措施 | 优先级 |
|------|------|----------|--------|
| AI 视觉分析精度上限 | 提取的设计 token 可能不完全准确 | 方法论中要求"推断值 + 置信度标注"，DEV 可据此判断 | P1 |
| 独立设计质量不稳定 | 不同需求的设计水准可能波动 | 七步法强制每个步骤都产出、设计决策必须给理由 | P1 |

## 五、实现优先级建议

批次 A 必须在批次 B 之前完成——UX Skill 本体必须先存在，才能做流程集成。在批次 A 内部，建议实现顺序：

1. SKILL.md（骨架 + 核心流程）
2. references/spec-template.md（产出物格式——DEV 需要的最终交付物）
3. references/visual-analysis-guide.md（翻译者模式方法论）
4. references/design-methodology.md（创作者模式方法论）
5. references/execution-strategy.md（模式策略整合）

## 六、实现步骤清单

| 步骤 | 文件 | 操作 |
|------|------|------|
| 1 | `rdd-ux/SKILL.md` | 新建。包含：frontmatter、核心原则、模式边界、输入处理、四阶段流程、对话风格 |
| 2 | `rdd-ux/references/spec-template.md` | 新建。设计规格文档的标准模板，含每章格式要求和示例 |
| 3 | `rdd-ux/references/visual-analysis-guide.md` | 新建。五步视觉分解法的详细方法论 |
| 4 | `rdd-ux/references/design-methodology.md` | 新建。七步设计法的详细方法论 |
| 5 | `rdd-ux/references/execution-strategy.md` | 新建。三种工作模式的详细执行策略 |

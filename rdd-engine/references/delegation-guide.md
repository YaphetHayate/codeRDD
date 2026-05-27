# 委托执行指南

engine 被 RDD 角色加载后，按本指南确定子 agent 配置并执行委托。

## 核心原则

- **不做决策，只做执行。** 引擎不判断"该做什么"，只负责执行。
- **子 agent 代理。** 所有能力通过 `task` 工具启动子 agent 完成。引擎分析需求、构造 prompt、启动执行、汇总结果。
- **按需加载。** 引擎不主动触发，由各 RDD 角色在需要时加载。

## 能力映射

| 能力 | 子 agent | 参考文件 |
|------|---------|---------|
| 项目上下文 | `explore` | `references/context-guide.md` + `references/artifact-template.md` |
| 技能发现 | `general` | `skill-registry.md` |
| 项目工具 | `general` | `references/` 下对应文件 |

## 项目上下文执行

1. 启动 `explore` 子 agent
2. 子 agent 读取 `references/context-guide.md`（采样策略、生成指南、新鲜度检测）和 `references/artifact-template.md`（产物模板）
3. 子 agent 按指南执行：检查新鲜度 → 采样代码 → 分析生成 → 写入 `.rdd/context/`
4. 返回产物路径

产物存储结构：
```
.rdd/
└── context/
    ├── meta.json       # 元数据（生成时间、采样文件 hash）
    ├── style.md        # 代码风格约定
    ├── structure.md    # 代码结构与模块关系
    └── glossary.md     # 项目术语表
```

## 技能发现执行

1. 启动 `general` 子 agent
2. 子 agent 依次查询：调用角色目录 `skills/index.md` → `skill-registry.md` → `find-skill`
3. 返回匹配 skill 列表及使用建议

## 项目工具执行

1. 启动 `general` 子 agent
2. 子 agent 读取 `references/` 下对应的工具指南
3. 返回分析结果

## 角色侧统一声明模板

各 RDD 角色 SKILL.md 中应包含以下声明：

```markdown
## rdd-engine 能力

本角色按需使用 rdd-engine 提供的通用能力：
- **项目上下文** — 委托 engine 生成/读取项目理解产物（代码风格、项目结构、术语表）
- **技能发现** — 委托 engine 匹配领域 skill
- **项目工具** — 委托 engine 处理项目级通用任务

需要以上能力时，加载 rdd-engine 并描述具体需求。
```

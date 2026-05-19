# 清理 RDD 历史遗留文件

## 背景

RDD 系列 skill 经历多轮迭代，当前开发目录（`codeRDD/`）中积累了一些与当前 skill 版本不一致的历史文件，包括：
1. 已被新机制取代的"历史兼容文件"（如 `skill-registry.md`）
2. 已完成的旧归档记录，对应需求早已合入当前 skill，无独立参考价值
3. IDE 配置文件碎片混入 skill 目录

## 需求索引

| # | 文件 | 标题 | 优先级 |
|---|------|------|--------|
| 1 | cleanupFragments.md | 删除项目根目录下的历史碎片文件 | 高 |
| 2 | cleanupObsoleteArchives.md | 删除 11 个过时归档 | 高 |

## 关键约束

- 仅删除开发版（`codeRDD/` 项目根目录）文件，不影响 stable 版（`~/.config/opencode/skills/`）

## 讨论记录

- 用户确认清理策略：删除第一组（6个 code-compass 早期归档）+ 第二组（5个被后续迭代覆盖的归档），共 11 个
- 额外发现 `rdd-engine/skill-registry.md` 自我声明为历史兼容文件，当前无任何 SKILL.md 主动引用
- 额外发现 `rdd-cto/.idea/` 为 IDE 配置碎片

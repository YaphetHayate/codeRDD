# Skill Manager

skill-manager 是 rdd-engine 的领域能力管理层，负责统一管理外部 skill、自动发现未掌握 skill、记录使用效果，并把 EVAL 反馈转化为 skill 评分和迭代建议。

它不替代角色做决策：PM 仍负责需求，CTO 仍负责技术方案，UX 仍负责设计规格，DEV 仍负责实现，QA/EVAL 仍负责测试和评价。skill-manager 只回答：**当前角色需要哪些 skill 辅助，为什么，怎么用，用完效果如何**。

skill-manager 自身也可以使用自己管理的 skill。例如评估一个 Java Spring Boot 相关 skill 时，如果 index 中已有 Java/Spring 规范类 skill，可以读取该 skill 来判断候选 skill 是否覆盖关键规范；但最终结论必须标注证据来源，不能把被评估 skill 的自述当作唯一依据。

---

## 核心能力

### 1. 外部 Skill 统一管理

角色遇到特定领域需求时，不再直接读取各自的 `skills/index.md` 或自行调用 find-skills，而是向 skill-manager 发起 `query`：

```text
/skill-manager query
role: UX
task: 设计像素风交互界面
domain_tags: 像素风, pixel art, UI, 动画
need: 找到可辅助设计该风格的 skill，并说明使用方式
```

skill-manager 返回：

- 推荐 skill 名称
- 匹配理由
- 适用角色
- 需要读取的 `SKILL.md`
- 该 skill 在当前任务中应该产出或影响什么
- 如果没有匹配，进入自动发现流程

### 2. Skill 自动获取

当本地管理清单和历史缓存都未命中时，skill-manager 自动调用 `find-skills` 搜索。搜索成功后：

1. 读取找到的 skill 元信息和 `SKILL.md`
2. 判断它是否能解决当前能力需求
3. 将条目写入 `.rdd/skill-manager/index.md`
4. 返回给调用角色使用

如果 `find-skills` 不可用或未找到：

- 向调用角色返回"领域能力缺口"
- 要求角色在产物中标注风险，例如：`⚠️ 领域知识缺口：缺少 Java Spring Boot 安全配置 skill`
- 不强行编造领域规范

### 3. Skill 评估与迭代

skill-manager 维护每个 skill 的评分。评分来自三类信号：

| 信号 | 来源 | 权重 |
|------|------|------|
| manager 判断 | 匹配度、覆盖度、指令清晰度 | 中 |
| 使用记录 | 角色是否成功把 skill 指导落到产物中 | 中 |
| EVAL 反馈 | 完成需求后的质量评分、差评原因、协同问题 | 高 |

触发场景：

- EVAL 中任一维度评分为 C/D，且该需求使用过领域 skill
- 用户明确说某个 skill 没帮上忙、指导错误、产出不佳
- 同一个 skill 在多次使用中反复出现相同问题
- 某角色反复出现领域能力缺口，说明需要补充新 skill

分析问题时区分四类原因：

| 类型 | 判断方式 | 后续动作 |
|------|----------|----------|
| skill 不匹配 | skill 领域与任务真实问题不一致 | 降低匹配评分，补充反例 |
| skill 指导不足 | skill 方向正确但缺关键步骤/模板 | 标记"需要迭代"，给出补充建议 |
| 角色使用不足 | skill 已提供指导但角色未落实 | 记录到角色流程改进，不降低 skill 主评分 |
| 需求/设计问题 | 上游产物不足导致 skill 难以发挥 | 反馈给对应角色，不归因于 skill |

---

## 管理文件

### `.rdd/skill-manager/index.md`

```markdown
# Skill Manager Index

## [skill-name]

- **领域标签**：[tag1], [tag2]
- **可见角色**：CTO, DEV, UX, EVAL
- **状态**：active / candidate / deprecated
- **评分**：A/B/C/D
- **使用次数**：0
- **最近使用**：YYYY-MM-DD
- **适用场景**：[什么时候使用]
- **不适用场景**：[什么时候不要使用]
- **来源**：内置 / find-skills / 用户指定
- **备注**：[关键限制或迭代建议]
```

### `.rdd/skill-manager/usage-log.md`

```markdown
## YYYY-MM-DD [archive-name]

- **角色**：CTO/DEV/UX/EVAL
- **任务**：[需求或任务名]
- **使用 skill**：[skill-name]
- **使用方式**：[读取了什么、影响了什么产物]
- **产物路径**：[cto/name.md 或 ux/name.md 等]
- **自评效果**：有效 / 部分有效 / 无效
```

### `.rdd/skill-manager/feedback.md`

```markdown
## YYYY-MM-DD [archive-name]

- **反馈来源**：EVAL / 用户
- **关联 skill**：[skill-name]
- **关联角色**：CTO/DEV/UX/QA/EVAL
- **评分/反馈**：[C/D 或用户原话摘要]
- **问题归因**：skill 不匹配 / skill 指导不足 / 角色使用不足 / 上游问题
- **证据**：[引用产物路径和具体问题]
- **迭代建议**：[如何改 skill 或角色流程]
```

---

## Query 流程

```
收到 query
  │
  ├── 提取 role / task / domain_tags / need
  │
  ├── 读取 .rdd/skill-manager/index.md
  │   ├── 命中 active skill → 返回推荐
  │   └── 未命中
  │
  ├── discover：调用 find-skills 搜索
  │   ├── 找到 → 评估适用性 → 写入 index.md → 返回推荐
  │   └── 未找到 → 返回领域能力缺口
```

## 返回格式

```markdown
Skill Manager 结果：

- **推荐 skill**：[skill-name] / 无
- **匹配理由**：[为什么适合当前任务]
- **适用角色**：[role]
- **使用方式**：[读取 SKILL.md 的哪些部分，如何融入产物]
- **预期影响**：[对 PM/CTO/UX/DEV/QA/EVAL 产物的影响]
- **风险**：[如有能力缺口或低评分提醒]
```

---

## Feedback 流程

```
收到 EVAL/用户反馈
  │
  ├── 定位归档目录和使用过的 skill（usage-log.md）
  │
  ├── 读取评价报告或用户反馈
  │
  ├── 判断是否 C/D 或明确差评
  │
  ├── 归因：skill 不匹配 / skill 指导不足 / 角色使用不足 / 上游问题
  │
  ├── 更新 feedback.md
  │
  └── 必要时更新 index.md 的评分、适用/不适用场景、迭代建议
```

评分调整建议：

- 一次 C：不直接降级，记录观察
- 一次 D 或连续两次 C：降一级或标记 `candidate`
- 明确证明 skill 指导错误：标记 `deprecated`，除非用户确认继续使用
- EVAL 证明 skill 明显改善产出：提升评分或记录最佳实践

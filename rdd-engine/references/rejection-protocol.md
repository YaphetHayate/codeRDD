# 驳回协议

> 本文档为通用协议，所有角色（PM/CTO/UX/DEV）在产物流转过程中发现上游文档不合理时，均可按此协议发起正式驳回；规划者（PLANNER）在需求审查门内发起的驳回见下方专节。
>
> **各角色自行判断该驳回给谁**——本协议不硬编码角色名称，只定义流程规范和记录格式。

---

## 驳回记录格式

每个产出文档（需求文档、设计文档）末尾的 `## 驳回记录` 章节中追加以下表格：

```markdown
| 轮次 | 日期 | 发起方 | 理由 | 被驳回方回应 | 最终裁决 | 状态 |
|------|------|--------|------|-------------|----------|------|
| 1 | YYYY-MM-DD | [角色名] | [驳回的具体理由] | [回应内容] | [裁决结论] | [状态] |
```

状态取值：

| 状态 | 含义 | 触发条件 |
|------|------|----------|
| 待回应 | 驳回刚发起 | 发起方新增驳回记录后 |
| 待裁决 | 双方僵持 | 被驳回方回应辩解后，发起方仍坚持 |
| 已驳回 | 驳回生效 | 被驳回方接受，或人工裁决驳回生效 |
| 已撤回 | 驳回方撤回 | 发起方认可被驳回方的辩解 |
| 已接受 | （预留） | — |

---

## 三步流程

### 第一步：发起驳回

1. 在目标文档的 `## 驳回记录` 表格中新增一行
2. 填写：发起方、日期、理由，状态 = `待回应`
3. 将目标文档的 `## 流转控制 > 当前责任人` 改为被驳回方
4. 更新 task.json 路由（调用 `rdd-flow.cmd -Command reject`，见 `rdd-engine/references/task-routing.md`）
5. 告知用户：

```
⚠️ [文档 X] 已驳回给 [角色 Y]

驳回理由：[一句话说明]
被驳回方看到后可以：接受并修订 / 解释辩解
```

### 第二步：被驳回方响应

被驳回方发现某文档的当前责任人和驳回记录指向自己时：

**选项 A：接受驳回**
```
1. 在驳回记录中填写回应 = "同意，按此修改"
2. 状态改为 已驳回
3. 将旧文档的「文档状态」改为 deprecated
4. 基于修订方向新建文档
5. 新文档「前置设计文档」字段填写被废弃文档的路径
```

**选项 B：不接受，辩解**
```
1. 在驳回记录中填写回应 = "不同意，理由：..."
2. 状态改为 待裁决
3. 将文档「当前责任人」设回原驳回方
```

### 第三步：人工裁决

当驳回记录状态变为「待裁决」时，双方已无法自行解决。当前处理角色应：

1. 将分歧点清晰地呈现给用户
2. 列出驳回理由和被驳回方辩解，不做倾向性建议
3. 由用户裁定：

```
分歧裁决：

文档 [X] 的流转出现分歧：

- [角色 A] 驳回理由：[...]
- [角色 B] 辩解：[...]

请裁决：驳回生效 / 驳回无效，继续推进
```

裁决后，更新驳回记录的「最终裁决」和「状态」字段。

---

## PLANNER 发起的驳回（需求审查门，PLANNER 形态）

规划者接管归档时的需求审查门（`rdd-engine/references/planner-guide.md` 硬约束 6，建树前）判定某子需求**文档级不合理**（需求本身有问题、需合并或拆分需求文档）时，按本协议发起驳回——仅在 **AUDITOR 未部署 / 用户裁定跳过**时由规划者自产审查并发起驳回（AUDITOR 已部署时规划者只机械消费审视产物，不自产驳回）。与通用第一步的差异只在发起方与记录边界：

1. 在该需求文档的 `## 驳回记录` 表格中**追加一行**（仅追加；发起方 = `PLANNER`、状态 = `待回应`）——不改写需求文档其余内容本体，**包括遗留的 `## 流转控制 > 当前责任人` 字段**（内容本体归 PM，路由事实以 task.json 为准）
2. 更新路由：`rdd-flow.cmd -Command reject -Archive <归档> -TaskId <n> -From PLANNER -To PM -Reason "<理由>"`
3. 在 ReviewFile 中将该任务记为 `reject_return` 后 promulgate：该任务不建节点、不进本轮交付；conclude 门禁豁免该任务（active@PM 为真实状态），结案附录如实呈现「部分达成（N 条驳回回流 PM）」
4. 告知用户（逐条审查结论呈现，最终裁决权在用户）

后续流转（PM 响应辩解 / 人工裁决 / 文档生命周期）沿用通用规则。**驳回修订后的需求不回流本轮 run**——由后续 run 或正常流程承接。

---

## AUDITOR 发起的驳回（需求审查门，AUDITOR 形态，主路径）

AUDITOR（AUDITOR 审视员，事前把关角色）对归档需求集做四维独立审视（`rdd-auditor/references/requirement-review.md`）后，判定某子需求**文档级不合理**时，按本协议发起驳回——AUDITOR 已部署时的**主路径**（planner-guide 硬约束 6 语义审查归属 AUDITOR）。与 PLANNER 形态的差异只在发起方与角色边界：

**角色边界差异**：

- AUDITOR 是**非路由角色**（不进 task.json `currentOwners` 枚举、不进 `rdd-flow -Role` ValidateSet）——`reject` 命令的 `-From AUDITOR` 是**自由字符串**（rdd-flow 解析 `-From` 为发起方标识，约束为非空，不绑定枚举），`rejection-protocol.md` 协议层接受任意 `-From` 字符串（仅约束非空 + 落账可见）
- **三禁纪律**（`rdd-auditor/SKILL.md` 宪法层）：只审不改、不代用户裁决、产物契约化——驳回由 AUDITOR 发起（机械执行审查结论），但**最终裁决权仍在用户**

**操作**（与 PLANNER 形态同族，仅发起方不同）：

1. 在该需求文档的 `## 驳回记录` 表格中**追加一行**（仅追加；发起方 = `AUDITOR`、状态 = `待回应`）——不改写需求文档其余内容本体，**包括遗留的 `## 流转控制 > 当前责任人` 字段**（内容本体归 PM，路由事实以 task.json 为准）
2. 更新路由：`rdd-flow.cmd -Command reject -Archive <归档> -TaskId <n> -From AUDITOR -To PM -Reason "<理由>"`
3. 在 ReviewFile 中将该任务记为 `reject_return`（`reviewer: "auditor"`，reviewer 字段值对消费端透明——`delivery-bridge` 仅查非空 + `verdicts[]` 合法性，值域零改动）后 promulgate：该任务不建节点、不进本轮交付；conclude 门禁豁免该任务（active@PM 为真实状态），结案附录如实呈现「部分达成（N 条驳回回流 PM）」
4. **记账追加** `.rdd/review-ledger.jsonl`（全局单文件 JSONL，账本范式不重写；格式 `{at, archive, reviewer:"auditor", kind:"gap", task_id, gap_type:"untestable_acceptance"|"coverage_hole"|"orphan_requirement"|"dependency_mislabel"|"merge_candidate", detail}`）——审计追溯 + 同类 gap_type 累计 ≥3 次回流判定（详见 `rdd-auditor/references/requirement-review.md#记账规范`）
5. 告知用户（逐条审查结论呈现，最终裁决权在用户）

后续流转（PM 响应辩解 / 人工裁决 / 文档生命周期）沿用通用规则。**驳回修订后的需求不回流本轮 run**——由后续 run 或正常流程承接；本归档若重启审视，**覆盖重产**归档 `review/requirement-review.json`（旧结论不重用，详见 `rdd-auditor/SKILL.md` 完成前置硬检查）。

> **设计侧驳回**（同批 #2 落地后）：AUDIOTR 对设计汇聚做五查维度独立审视，产出 DesignReviewFile；`reject_return` 同族流程，从设计文档「## 驳回记录」追加行 + `rdd-flow reject -From AUDITOR -To CTO`（被驳回方 = CTO 而非 PM）。

---

## 文档生命周期

```
active ──驳回生效──→ deprecated
                       │
          新文档 ←──────┘（前置设计文档指向旧文档）
```

- **active**：正常流转中的文档
- **deprecated**：已被废弃的文档，保留在原始路径供审计追溯
- 新文档创建时可在 `## 流转控制 > 前置设计文档` 填写废弃文档路径

---

## task.json 同步规则

- 发起驳回时：调用 `rdd-flow reject` 更新 `currentOwners`（见 `rdd-engine/references/task-routing.md`）
- 废弃文档：调用 `rdd-flow deprecate` 标记 `lifecycle=deprecated`；新增替代文档的行用 `add-task`
- 路由总览与文档自身字段不一致时：以文档自身的流转控制字段为准，角色通过 CLI 修正 task.json

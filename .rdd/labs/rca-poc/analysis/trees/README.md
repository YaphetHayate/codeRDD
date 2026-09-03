# 执行决策树索引(analysis/trees/)

> 11 张图由 `tools/render-tree.mjs` 从各 run 的 `state/` 三件套 + 评分 JSON **机械生成**(零手写、零 LLM 参与)——图上任何节点的 verdict/置信度/裁决都可回查源文件,这就是它们的验证价值。

## 图例

- 🔴 假设节点(pruned/refuted)= 被证据排除的分支;🔵 supported = 有支持但未结案;🟢 concluded = 结案假设;⚪ pending
- `(🔴refute 0.8 …)` 圆节点 = worker 回调证据(verdict/置信度/worker 名/证据类型)
- `派发采证` 虚线 = Manager→worker 派发;`裁决:剪枝/支持` 虚线 = Manager 整合动作
- `🛑 R2 决策:STOP(...)` = 轮末停止判定(含触发条件);`🏁 结案` = 最终结论 + 评分

## 索引(按案例 × 臂)

| 案例 | 编排臂 | 基线臂 |
|------|--------|--------|
| mock-001(L1) | [mock-001-orchestrated-001](mock-001-orchestrated-001.md) | —(设计:L1 不对照) |
| openrca-bank-task1(L2 pilot) | […-orchestrated-001](openrca-bank-task1-orchestrated-001.md) | […-ralph-001](openrca-bank-task1-ralph-001.md) |
| openrca-bank-task6-1800 | […-orchestrated-001](openrca-bank-task6-1800-orchestrated-001.md) | […-ralph-001](openrca-bank-task6-1800-ralph-001.md) |
| openrca-bank-task2-1330 | […-orchestrated-001](openrca-bank-task2-1330-orchestrated-001.md) | […-ralph-001](openrca-bank-task2-1330-ralph-001.md) |
| openrca-bank-task1-2100 | […-orchestrated-001](openrca-bank-task1-2100-orchestrated-001.md) | […-ralph-001](openrca-bank-task1-2100-ralph-001.md) |
| pm-001(L3) | [pm-001-orchestrated-001](pm-001-orchestrated-001.md) | [pm-001-ralph-001](pm-001-ralph-001.md) |

## 怎么用树验证有效性(30 分钟路径)

1. **看结构是否符合协议**(每张图 2 分钟):假设先验→派发→证据→裁决→停止条件,链路完整、剪枝都有证据 id、无"凭空排除"。对照协议:`prompts/manager-system.md`
2. **抽一条证据回查原始数据**(最关键,10 分钟):图下方的断言摘要表任选一行 → 打开 `runs/<run-id>/state/evidence-chain.jsonl` 找该条 `citations` → 照定位去 `cases/<tier>/<case-id>/plane/` grep 该时间点 → 数字对上 = 证据非编造
3. **抽一案验答案**(10 分钟):拿 `datasets/OpenRCA/.../record.csv` 真值对 `analysis/scoring/answers.jsonl` 同 case 行,再对图中 `🏁 结案` 节点
4. **对照臂看差异**(5 分钟):同案例两图并排——编排臂的"域级扇出+独占性裁决"vs 基线臂的"单线深挖",结论分歧一目了然(如 task1-2100:编排定位 IG01,基线定位 apache02)

> 提示:VSCode 装 Mermaid 预览插件、或粘贴到 mermaid.live 即可渲染;GitHub/GitLab 原生渲染。

# 两臂评分汇总

生成于 2026-08-31T12:20:38.494Z;共 11 个 run。verdict 口径:located=≥2 关键词命中且无误归因;located_needs_review=1 命中(需人工复核);misattributed=误归因;escalated=升级人类;missed=结论未命中。

| 案例 | run | 臂 | verdict | 定位 | 组件命中 | 关键词 | 轮次 | 证据(correlational/causal) |
|------|-----|----|---------|------|----------|--------|------|------------------------------|
| mock-001 | mock-001-orchestrated-001 | orchestrated | located | ✅ | ✅ | 5 | 2 | 5(2/3) |
| openrca-bank-task1-2100 | openrca-bank-task1-2100-orchestrated-001 | orchestrated | located | ✅ | ✅ | 5 | 1 | 3(3/0) |
| openrca-bank-task1-2100 | openrca-bank-task1-2100-ralph-001 | ralph-baseline | located_needs_review | ✅ | ❌ | 1 | 1 | 9(8/1) |
| openrca-bank-task1 | openrca-bank-task1-orchestrated-001 | orchestrated | budget_exhausted | ❌ | ✅ | 1 | 3 | 7(7/0) |
| openrca-bank-task1 | openrca-bank-task1-ralph-001 | ralph-baseline | missed | ❌ | ❌ | 0 | 3 | 29(27/2) |
| openrca-bank-task2-1330 | openrca-bank-task2-1330-orchestrated-001 | orchestrated | escalated | ❌ | ✅ | 5 | 2 | 5(5/0) |
| openrca-bank-task2-1330 | openrca-bank-task2-1330-ralph-001 | ralph-baseline | missed | ❌ | ❌ | 0 | 2 | 12(10/2) |
| openrca-bank-task6-1800 | openrca-bank-task6-1800-orchestrated-001 | orchestrated | escalated | ❌ | ✅ | 4 | 2 | 5(5/0) |
| openrca-bank-task6-1800 | openrca-bank-task6-1800-ralph-001 | ralph-baseline | missed | ❌ | ❌ | 0 | 2 | 18(16/2) |
| pm-001 | pm-001-orchestrated-001 | orchestrated | located | ✅ | ✅ | 10 | 1 | 3(1/2) |
| pm-001 | pm-001-ralph-001 | ralph-baseline | located | ✅ | ✅ | 9 | 1 | 7(3/4) |

**编排臂**:located 3/6,组件命中 6/6;**基线臂**:located 2/5,组件命中 1/5。

> 论文单体基线为参照口径(模型/提示/预算不同,不并表硬比,双口径落档见 R6)

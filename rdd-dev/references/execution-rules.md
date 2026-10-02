# 执行规则

> 本文档是 [SKILL.md](../SKILL.md) 的补充材料，包含执行阶段的自测与验证规则。

## 自测规则

每个任务完成后，必须通过以下验证才算完成：

| 检查项 | 条件 | 不通过时处理 |
|--------|------|-------------|
| Lint | 项目有 lint 配置时执行 | 必须修复，不能标记完成 |
| TypeCheck | 项目有 typecheck 配置时执行 | 必须修复，不能标记完成 |
| 相关模块测试 | 项目有测试框架时执行 | 必须修复，不能标记完成 |
| 代码度量（出报门） | PowerShell 变更必跑：三级定位链调用 `code-metrics.cmd -Command scan`（定位链见 `rdd-engine/references/capability-manifest.md`），退出码 0 才算过；项目无 lint/typecheck 配置时，该工具的 AST 解析兼作语法检查兜底。**凭据是机械门硬要求**（dev-quality-prescan-gate）：漏带凭据或违规计数 > 0 时，出报/流转会被引擎确定性拒绝（桥接 `SETTLE_EVIDENCE_REJECTED` / 链式 `HANDOFF_GATE_REJECTED`），原地补扫重报即可，不产生跨会话返工 | 必须修复，不能标记完成 |
| 冒烟检查 | 单任务完成后执行轻量验证 | 必须修复，不能标记完成 |

项目没有配置对应工具时，跳过该检查项。

## quality_scan 凭据（DEV 出报门，双场景）

`code-metrics` 自检已从角色纪律升级为引擎机械门（`dev-quality-prescan-gate`）——DEV 声称完成并交出任务时，**必须携带结构化质量扫描凭据**，两个交接场景同一 schema、同一校验规则（注册表分派，R1-R6 机械判定）：

| 交接场景 | 凭据载体 |
|----------|----------|
| 桥接 run（planner 桥接） | report 回调 `extras.quality_scan`（与 `extras.verification` 并列） |
| 链式直转（DEV → QA） | `rdd-flow set-route -QualityScanFile <凭据JSON>`（DEV 退场必填，缺失拒 `HANDOFF_GATE_REJECTED`，路由零残留） |

**完整形**（变更集含 PowerShell 文件时必填）：

```json
{
  "tool": "code-metrics 1.0",
  "base": "HEAD",
  "files": ["path/a.ps1", "path/b.ps1"],
  "thresholds": "function<=50 lines, nesting<=5 depth",
  "threshold_source": "docs/code-quality.md #1",
  "violation_count": 0,
  "exit_code": 0
}
```

- `violation_count` 与 `exit_code` 必须为 0（退出码非 0 = 仍有 #1/#4/#5 违规，修复后重扫）；`files` 必须覆盖改动清单（citations）中的每个 `.ps1`（POSIX 路径、大小写不敏感对账）；`thresholds`/`threshold_source` 如实记录实际生效阈值与来源（阈值唯一来源 `docs/code-quality.md` §1：50 行 / 5 层，QA 复核对账用）。可选字段：`tool_hash`、`report_ref`（扫描报告留存指针）。
- **skip 形**（变更集无 PowerShell 文件时）：`{"skip": true, "reason": "<为何无需扫描>"}`——citations 含 `.ps1` 时 skip 会被拒。

**组装指引**：凭据数据源 = 扫描退出码 + 汇总行（`-- 汇总: 违规 N 项 | 备忘 M 项 --`）+ 报头 `limits:` 行；stdout 捕获务必显式 UTF-8（如 `Out-File -Encoding utf8`，防重定向 UTF-16 陷阱）；凭据文件建议留存归档 `report/` 目录（非强制，链式门不校验留存）。

## 冒烟验证（双层）

冒烟验证分两层执行，分别对应不同的验证粒度：

**第一层：单任务冒烟（每个任务完成后）**
- 代码无语法错误、能通过编译/构建
- 新增的模块/函数能被正确导入/引用，不报运行时异常
- 不要求完整功能可用，只要求"不崩溃"

**第二层：整体冒烟（整体验证阶段）**
- 应用能正常启动（后端不崩溃、前端不白屏/不报 JS 错误）
- 至少一个核心用户场景能走通
- 已实现的功能没有被新改动破坏

冒烟验证不通过时：
- 单任务冒烟不通过 → 该任务不能标记完成，修复后重试
- 整体冒烟不通过 → 整体验证不通过，定位问题任务并修复

以下情况可跳过，但需在验证报告中说明原因：
- 项目是库/工具，无独立可启动入口（仅跳过第二层）
- 项目依赖外部服务且本地环境无法启动（仅跳过第二层）
- 本次改动仅涉及配置/文档/非运行时代码（两层均可跳过）

## Bug 修复场景验证

当本次改动属于 Bug 修复模式（Mode 4）时，冒烟验证增加专项检查：

1. **沿用户报告的完整操作路径验证最终行为**——不是检查报错是否消失，而是检查用户可见的最终结果是否符合预期
2. 如有 PM 定义的验收标准，逐条对照
3. 验证不通过时，回到 Mode 4 的诊断环节（Step 2），不作为普通冒烟失败处理

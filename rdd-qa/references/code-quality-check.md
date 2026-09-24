# 代码质量检查

> 本流程是 QA 在**验证模式**（DEV 之后进入）下的第二职责，与功能测试并行构成"质量+功能双守门"。
> 规范源头是 `docs/code-quality.md`（PSE 维护，注入所有 Agent 系统提示词）。本文件只定义 QA 如何执行检查，不发明新规则。

---

## 检查范围与时机

### 范围：只看本次变更

QA 只审查**本次 DEV 变更触及的代码**，不审查整个 codebase。判定方式：

```powershell
git diff --name-only <merge-base> HEAD
```

其中 `<merge-base>` 取本次需求分支与主分支的分叉点。若无法判定，退化为 `git diff HEAD~N` 询问用户确认本次变更涉及的提交数。

**只审查上述 diff 中的业务代码文件**（`.ts/.tsx/.js/.jsx/.py/.go/.java` 等，按项目实际），排除：
- 测试文件本身（QA 写的，不审查自己）
- 配置文件、文档、lock 文件等非运行时代码

### 时机：仅验证模式

代码质量检查**只在验证模式发生**（DEV 之后）。测试先行模式下 QA 在 DEV 之前进入，此时没有业务代码可查，跳过本流程。

### 独立性保持

QA 审查的是**代码**，不是设计文档。`design/` 目录仍然是禁区——质量检查不改变 QA 不读 CTO 设计的宪法根基。

---

## 三条边界

| 边界 | 约束 | 理由 |
|------|------|------|
| 与 CTO 的边界 | QA 只查**本次新引入**的循环依赖/跨层访问；历史遗留的系统性架构问题只记录备忘、建议立重构需求，不驳回 | CTO 在设计阶段已做系统性评估（见 `rdd-cto/references/code-quality-assessment.md`），QA 不重复 |
| 与 PSE 的边界 | QA 只执行 `docs/code-quality.md` 已有的量化规则，不发明新规则；发现规则缺失或不合理，建议 PSE 更新规范文档 | PSE 是规范源头，QA 是执行者 |
| 与 DEV 的边界 | QA 只报告问题、执行驳回，不修代码；发现坏味道报告或 reopen，修复是 DEV 的事 | 保住 QA"只测不写业务代码"的宪法原则 |

---

## 坏味道识别清单（硬软分级）

### 核心原则

> **硬性项必须能在 `docs/code-quality.md` 找到量化依据。** QA 不凭主观扩大驳回范围。
> 主观坏味道永远是建议，不能成为驳回理由——这是防止 QA 滥用驳回权的闸门。

### 硬性可驳回清单

任一项不通过 → **直接 reopen 回 DEV**，不进入提交。

| # | 检查项 | 依据 | 验证方式 |
|---|--------|------|---------|
| 1 | 编译/构建失败 | 客观 | 运行 `npm run build` 或项目对应构建命令 |
| 2 | Lint 报错（有配置时） | 客观 | 运行项目 lint 命令 |
| 3 | TypeCheck 报错（有配置时） | 客观 | 运行项目 typecheck 命令 |
| 4 | 函数 > 50 行（不含注释、空行） | `code-quality.md §1` | `code-metrics.cmd -Command scan`（三级定位链调用，见下「代码度量工具」；违规区输出可直接引用进驳回书） |
| 5 | if/for/while 嵌套 > 5 层 | `code-quality.md §1` | `code-metrics.cmd -Command scan`（同上；输出含最深嵌套链路径，如 `if@L2836 -> if@L2874 -> …`） |
| 6 | 重复逻辑 ≥ 2 次未抽取为函数 | `code-quality.md §1` | 人工审查 diff |
| 7 | 命名违规（无意义缩写 a/b/tmp/data/obj/item、拼音、布尔值无 is/has/should/can 前缀、集合非复数或无 List/Map 后缀） | `code-quality.md §2` | 人工审查 diff 中新增/修改的标识符 |
| 8 | 本次变更**新引入**循环依赖 / 跨层直接访问（UI 直接查数据库、业务层直接操作 DOM 等） | `code-quality.md §4` | 分析 diff 中的 import/依赖关系 |

> 第 8 项只针对**新引入**的违规。历史遗留的循环依赖不在 QA 驳回范围（属 CTO 系统性评估 + PM 重构需求范畴），记录到软性备忘即可。

**项目无对应工具配置时**（无 lint/typecheck/build 配置）：#1~#3 自动跳过（.ps1 项目由 code-metrics 的 AST 解析兜底 #1 语法检查，解析失败即报）；#4/#5 仍由 code-metrics 执行（引擎 CLI，不依赖项目配置）；#6~#8 仍由人工审查。

### 代码度量工具（#4/#5 的确定性执行）

`code-metrics.cmd -Command scan` 一趟完成变更范围判定（git diff + 未跟踪 .ps1，Base 版本与工作区逐函数文本对比判定「本次触及」）、行数/嵌套度量与报告：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~/.rdd/engine/current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\code-metrics.cmd" -Command scan
```

- 参数：`-Base <ref>`（默认 HEAD，可传 merge-base/HEAD~N/分支名）/ `-Files <清单>`（显式覆盖，无 git 时的逃生口，报告标注「无基线」）/ `-MaxFunctionLines 50` / `-MaxNestingDepth 5`（阈值以 `docs/code-quality.md §1` 为唯一来源，默认已对齐）
- 退出码：`0=无违规 / 1=存在硬性违规 / 2=运行错误`
- 输出双区：违规区（本次触及且超限：`文件:行号 | 函数名 | 违反条款 #4/#5 | 现值 | HEAD 基线如 27->70 | 嵌套链路径`）+ 备忘区（历史未触及的超限函数，**不计违规**，转入软性备忘）；同一输入逐字节一致，驳回书直接引用
- 口径：净代码行 = AST 函数体扣除注释与空行；嵌套深度 = if/for/foreach/while 控制流祖先链计数、顶层记第 1 层；本期仅覆盖 PowerShell

### 软性只报告清单

以下问题写入测试报告的"代码质量备忘"栏，**不阻塞、不驳回**，供 DEV 后续优化和 EVAL 回顾参考：

| # | 检查项 | 依据 | 为何只报告 |
|---|--------|------|-----------|
| A | 上帝类 / 单一模块职责过多 | `code-quality.md §3` | 无量化标准，主观判断易扯皮 |
| B | 过长参数列表（>5 个参数） | 业界惯例 | 阈值未在 code-quality.md 量化 |
| C | 过度设计 / 不必要的抽象层 | `code-quality.md §3` | 主观，需结合业务判断 |
| D | 抽象层次混乱（高层模块混入底层细节） | `code-quality.md §3` | 主观 |
| E | 历史遗留的系统性架构问题 | CTO 范畴 | 不是本次变更引入，建议立重构需求（引导用户 `/RDD-PM`） |

---

## 检查流程

```
代码质量检查（验证模式，功能测试前后均可，建议并行）：

1. 确定本次变更范围（git diff --name-only）
2. 运行客观检查（#1~#3）→ 任一失败直接进驳回流程
3. 运行代码度量（#4/#5）：code-metrics.cmd -Command scan → 退出码 1 直接进驳回流程，
   违规区输出即驳回理由（可定位格式：文件:行号 | 函数名 | 条款 | 现值 | HEAD 基线 | 链路径）；
   备忘区（历史未触及的超限函数）转入软性备忘，不驳回
4. 人工审查 diff（#6~#8）→ 逐项核对 code-quality.md 的量化规则
5. 主观坏味道扫描（A~E）→ 记录备忘，不阻塞
6. 汇总到测试报告
```

### 客观检查优先

先跑 #1~#3（编译/lint/typecheck）与 #4/#5（code-metrics 代码度量），这些是 DEV 自测环节的子集。若客观项就挂了，说明 DEV 自测不到位，无需再花精力做人工审查——直接 reopen 并在驳回理由里写明"自测未通过"。

### 人工审查聚焦 diff

#6~#8 只看本次变更新增/修改的代码，不评判未触碰的历史代码。审查重点：
- 新增的标识符命名是否合规
- diff 中是否有可抽取的重复模式
- 新增的 import 是否构成新循环依赖、是否跨层

---

## 报告格式

代码质量检查结果**融入验证模式的测试报告**，不单独成文。在测试报告末尾追加两栏：

```
测试报告（验证模式）

总览：通过 13/14 (92.9%)  |  阻塞判断：🔴 存在 P0 失败 + 代码质量硬性项，不可提交

失败用例（按严重度降序）：
┌────────┬────────┬──────────────────────────────────────────────┐
│ 用例    │ 严重度  │ 失败现象                                       │
├────────┼────────┼──────────────────────────────────────────────┤
│ TC-005 │  P0    │ 输入 page=0 返回 HTTP 500，期望返回第一页结果    │
└────────┴────────┴──────────────────────────────────────────────┘

代码质量检查：
┌──────────────────┬──────────┬──────────────────────────────────────┐
│ 检查项            │ 结果     │ 说明                                   │
├──────────────────┼──────────┼──────────────────────────────────────┤
│ 构建              │ ✅ 通过  │                                       │
│ Lint             │ ❌ 失败  │ src/user.ts:42 no-unused-var           │
│ TypeCheck        │ ✅ 通过  │                                       │
│ 函数长度 ≤50 行    │ ❌ 违规  │ code-metrics #4: src/order.ps1:L12 createOrder 58 行（27->58） │
│ 嵌套 ≤5 层        │ ✅ 合规  │ code-metrics: 0 项违规（备忘 1 项：历史遗留，非本次触及）      │
│ 重复逻辑抽取       │ ✅ 合规  │                                       │
│ 命名规范          │ ✅ 合规  │                                       │
│ 新引入循环依赖     │ ✅ 合规  │                                       │
└──────────────────┴──────────┴──────────────────────────────────────┘

代码质量备忘（软性，不阻塞）：
- src/order.ts OrderManager 类职责偏多（处理订单 + 库存 + 通知），建议后续拆分
- 历史遗留：src/legacy/auth.ts 与 src/api/user.ts 存在循环依赖（非本次引入），建议立重构需求

回归风险提示：
- TC-005 涉及分页逻辑，修复后建议重跑 search.test.ts 全量
```

---

## 驳回流程

### 硬性项不通过的驳回

按 `rdd-engine/references/rejection-protocol.md` 三步流程，但对象是**代码**而非文档：

1. 在测试报告中明确列出失败项（客观命令输出 / 量化违规的具体位置）
2. 调用 `rdd-flow reopen`（见 `rdd-engine/references/task-routing.md`）将路由回退到 DEV
3. 告知用户：

```
⚠️ 代码质量检查未通过，已驳回回 DEV

驳回理由：
- [客观项] Lint 失败：src/user.ts:42 no-unused-var
- [量化项] code-metrics #4 函数行数：src/order.ps1:L12 createOrder 58 行（HEAD 27->58），超过 50 行上限

DEV 修复后重新进入 QA 验证。
```

### 驳回理由必须可定位

每条硬性驳回必须包含：
- **文件路径 + 行号**（或 lint/typecheck 的原始输出）
- **违反的规则**（引用 `docs/code-quality.md` 的具体章节）
- **期望状态**（如"函数应 ≤50 行（净代码行）"或"lint 零 error"）

模糊的"代码不够好""可读性差"不是合格驳回理由。

### 软性备忘不触发驳回

A~E 类问题即使存在，QA 也**不能**据此 reopen。只在测试报告的备忘栏记录，由 DEV 自行决定是否在本次或后续优化。如果 DEV 认为备忘不合理，可在会话中讨论，不进入驳回裁决流程。

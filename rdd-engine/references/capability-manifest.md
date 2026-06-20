# 引擎能力清单

> **定位**：rdd-engine 所有可用能力的权威清单。各 RDD 角色通过本文档发现和使用引擎能力。
> **维护规则**：引擎新增/变更能力时，只需更新本文件（+ `explore.ps1`），各角色自动发现，无需逐个更新 SKILL.md。

---

## 能力速查

| 能力 | -Type | CLI 命令 | 触发场景 |
|------|-------|---------|---------|
| 代码探索（缓存判定） | `explore` | `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "..."` | 需要理解项目代码、定位模块/函数/依赖关系时 |
| 产物注册 | `register` | `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type register -Key "..." -Path "..." -Brief "..." -Files "..."` | `rdd-explore` worker 探索完成后注册产物 |

---

## 能力详解

### 代码探索（explore）— 缓存判定

**这是引擎核心能力。任何角色需要理解项目代码时，第一步始终调用此能力。**

**核心机制：先查缓存 → 命中零子代理返回 / 未命中生成 worker dispatch prompt**

1. 角色调用 `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "..."`
2. engine 读取 `.rdd/exploration/index.json`，对 Query 与每条 `entry.key` 做 token 匹配（Jaccard 相似度 ≥ 0.35）
3. 命中候选 → 检查涉及文件的 SHA-256 哈希
   - 全部一致 → **`cache:"hit"`**：直接返回 artifact 正文（**不派遣任何子代理**）
   - 任一变更 → 移除 stale 条目，落到 miss
4. 未命中 → **`cache:"miss"`**：返回 `{action:"dispatch-subagent", subagentHint:"rdd-explore", prompt:"<内嵌完整协议的 worker 指令>"}`，调用方取 `prompt` 派遣 `rdd-explore` 子代理

**调用示例：**

```powershell
# 第一步：缓存判定（始终先调这一步）
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "分析认证模块的中间件链和 Token 刷新机制"

# 返回 cache:hit  → 直接用 data.artifact，零子代理
# 返回 cache:miss → 用 data.prompt 派遣 rdd-explore（可写 worker）
```

> **硬约束**：禁止用内置只读 `explore` / `general` 子代理做代码探索——它们无法写 artifact、无法注册缓存，物理上无法完成协议。

### 产物注册（register）— worker 完成探索后调用

`rdd-explore` worker 探索完代码、写好 artifact 后，调用此能力注册产物：

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type register `
  -Key "认证中间件链和 Token 刷新" `
  -Path ".rdd/exploration/artifacts/auth-middleware.md" `
  -Brief "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑" `
  -Files "src/auth/middleware.ts,src/auth/jwt.ts"
```

register 会计算每个文件的 SHA-256，按 key 去重后追加进 index。

**缓存特性：**
- 全局共享：PM 探索过的结果，CTO/DEV/QA/UX 无需重新探索
- 自动失效：涉及文件变更后 SHA-256 不匹配，`explore` 自动移除 stale 条目
- 零子代理命中：命中缓存时不派遣任何子代理，触发成本最低
- 索引文件：`.rdd/exploration/index.json`，产物目录：`.rdd/exploration/artifacts/`

> 完整执行流程见 `rdd-engine/references/exploration-guide.md`

---

## 流转命令（rdd-flow.ps1）

除代码探索外，engine 还提供阶段流转命令，用于角色切换和上下文交接：

| Command | CLI 命令 | 说明 |
|---------|---------|------|
| `next` | `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command next` | 汇总当前有哪些角色有待处理任务 |
| `start` | `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command start -Role <PM\|CTO\|UX\|DEV\|QA>` | 为指定角色生成启动 prompt + handoff packet |
| `handoff` | `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command handoff -Role <DEV>` | 为指定角色生成最小交接包 |
| `validate` | `$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\rdd-flow.cmd" -Command validate -Role <DEV>` | 校验指定角色是否有可执行任务 |

> 完整规则见 `rdd-engine/references/handoff-guide.md`

---

## 共享协议

所有 RDD 角色共享以下协议（定义在 `rdd-engine/references/` 下）：

| 协议 | 文件 | 说明 |
|------|------|------|
| 角色交接协议 | `transition-guide.md` | 上游完成产物后的 4 步交接流程、下游三入口识别、双场景（self-driven/app-driven）模式检测 |
| 驳回协议 | `rejection-protocol.md` | 角色间正式驳回上游文档的标准流程 |
| 交接包规则 | `handoff-guide.md` | 最小上下文交接的构建规则 |

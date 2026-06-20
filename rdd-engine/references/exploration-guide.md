# 代码探索执行指南

> **定位**：全局代码探索能力。各角色（PM/CTO/DEV/QA/UX）需要理解项目代码时，委托 engine 执行。
> 产物缓存于 `.rdd/exploration/artifacts/`，通过 `.rdd/exploration/index.json` 索引，
> 后续同主题探索命中缓存后直接返回，无需重复探索。

---

## 职责划分

探索能力由两部分协作完成，职责严格分离：

| 角色 | 承载 | 职责 | 是否可写缓存 |
|------|------|------|-------------|
| **缓存仲裁（CLI）** | `explore.ps1`（确定性脚本） | 读 index、token 匹配、SHA-256 时效校验、命中直接返回产物 / 未命中生成 dispatch prompt；register 时算哈希、写 index | 读写 index 与 artifact（程序化） |
| **探索 worker** | `rdd-explore` 子代理（可写） | 收到 miss dispatch prompt 后：探索代码、按模板写 artifact、调用 `rdd-engine/scripts/explore.cmd -Type register` 注册、返回摘要 | 写 artifact + 调 register |

> **关键约束**：worker 必须是**可写**子代理（需写 artifact、调 register）。内置的只读 `explore` / `general` 探索子代理无法完成注册，**禁止用于代码探索**。详见各角色 SKILL 的硬规则。

---

## 调用方式

### 角色侧：第一步始终是 CLI 探索

```powershell
rdd-engine/scripts/explore.cmd -Type explore -Query "分析认证模块的中间件链和 Token 刷新机制"
```

返回 JSON，根据 `data.cache` 字段决定下一步：

- `cache: "hit"` → **直接使用产物，不派遣任何子代理**。`data.artifact` 即产物正文。
- `cache: "miss"` → `data.action = "dispatch-subagent"`，用 `data.prompt` 派遣 `rdd-explore` 子代理（`data.subagentHint`）。

### worker 侧：探索完成后注册

```powershell
rdd-engine/scripts/explore.cmd -Type register -Key "认证中间件链和 Token 刷新" `
  -Path ".rdd/exploration/artifacts/auth-middleware.md" `
  -Brief "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑" `
  -Files "src/auth/middleware.ts,src/auth/jwt.ts,src/auth/session.ts"
```

`register` 会计算每个文件的 SHA-256，按 key 去重后追加进 index，返回 `{registered: true, ...}`。

---

## CLI 执行流程（explore.ps1）

### `-Type explore`

```
接收 Query
    │
    ▼
读取 .rdd/exploration/index.json
    │
    ├── 文件不存在或 entries 为空 → cache:miss
    │
    ▼
token 匹配：Query ↔ entries[].key（Jaccard 相似度，阈值 0.35）
    │
    ├── 最高分 < 阈值 → cache:miss
    │
    ▼
对最高分 entry，逐个检查 files 的 SHA-256 时效性
    │
    │  对 entry.files 中每个文件路径：
    │    1. 文件是否存在？
    │    2. Get-FileHash -Algorithm SHA256  → 与存储哈希比对
    │
    ├── 任一不匹配或文件被删 → 产物 stale
    │       → 从 index 删除该 entry
    │       → cache:miss
    │
    └── 全部一致 → cache:hit
            → 读取 artifact 正文，写入 data.artifact 返回
```

### `-Type register`

```
接收 Key / Path / Brief / Files
    │
    ▼
校验 artifact 文件存在 → 不存在则报错
    │
    ▼
对 Files 列表中每个文件计算 SHA-256
    │   文件不存在则报错
    │
    ▼
按 Key（及 Path）去重，移除同 key 旧条目
    │
    ▼
追加新条目 → 写回 index.json（UTF-8 无 BOM，路径用 / 分隔）
    │
    ▼
返回 {registered: true}
```

### token 匹配算法

- Query 与 entry.key 各自小写化后分词
- CJK 字符（U+4E00–U+9FFF、U+3400–U+4DBF）逐字作为独立 token
- 连续字母数字作为整体 token（如 `codeRDD` → `coderdd`）
- 相似度 = Jaccard 系数 = |交集| / |并集|
- 阈值 0.35：误未命中（安全，会重新探索）；命中后用 brief 人工核对

---

## 输出格式

CLI 始终输出纯 ASCII JSON（非 ASCII 字符转义为 `\uXXXX`），保证任何调用方（PowerShell / cmd / bash / opencode / Claude）解码一致。

### 命中缓存（hit）

```json
{
  "success": true,
  "data": {
    "cache": "hit",
    "key": "认证中间件链和 Token 刷新",
    "path": ".rdd/exploration/artifacts/auth-middleware.md",
    "brief": "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑",
    "files": { "src/auth/middleware.ts": "sha256:...", "src/auth/jwt.ts": "sha256:..." },
    "matchScore": 0.57,
    "artifact": "<产物正文>"
  }
}
```

### 未命中（miss）

```json
{
  "success": true,
  "data": {
    "cache": "miss",
    "action": "dispatch-subagent",
    "subagentHint": "rdd-explore",
    "query": "分析认证模块的中间件链",
    "matchScore": 0.12,
    "prompt": "<内嵌完整协议的 worker 指令，含 Query + 本指南全文>"
  }
}
```

调用方取 `data.prompt` 派遣 `rdd-explore` 子代理即可，无需额外拼接协议。

---

## 索引文件：index.json

### 位置

`.rdd/exploration/index.json`

### Schema

```json
{
  "entries": [
    {
      "key": "认证中间件链和 Token 刷新",
      "path": ".rdd/exploration/artifacts/auth-middleware.md",
      "brief": "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑",
      "files": {
        "src/auth/middleware.ts": "sha256:abc123def456...",
        "src/auth/jwt.ts": "sha256:789012abc345..."
      }
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `key` | string | 语义描述，用于与 Query 做 token 匹配 |
| `path` | string | 产物文件路径（相对于 repo root，`/` 分隔） |
| `brief` | string | 一句话摘要，命中后供调用方快速核对 |
| `files` | object | `{ 文件路径: "sha256:哈希值" }`，仅包含产物中实际分析过的文件 |

### 操作规则（由 CLI 维护，worker 不直接写 index）

- **追加/更新**：`register` 按 key 去重后追加，同 key 旧条目被替换
- **删除 stale**：`explore` 时效性检查失败，CLI 自动移除对应条目
- **文件不存在**：视为空索引，跳过匹配直接 miss
- **文件损坏**（JSON 解析失败）：报错退出，建议手动删除重建

> worker 只通过 `register` 子命令间接写 index，不直接编辑 index.json，保证 schema 一致。

---

## 产物文件格式

每份 artifact 写在 `.rdd/exploration/artifacts/{topic-slug}.md`。

### 命名

以探索主题命名，使用小写英文 + 连字符。例如：
- `auth-middleware.md`
- `cache-layer-analysis.md`
- `rdd-flow-handoff.md`

重名时追加数字：`auth-middleware-2.md`。

### 文件头

产物文件第一行为元信息注释：

```html
<!-- exploration-artifact: key="认证中间件链" files="src/auth/middleware.ts,src/auth/jwt.ts,src/auth/session.ts" -->
```

> 此注释供人工阅读与 register 时参考（register 参数以 CLI 传入为准）。

### 正文模板

```markdown
<!-- exploration-artifact: key="主题名" files="路径1,路径2,..." -->

# 主题名

## 探索范围

| 探索的文件/模块 | 路径 | 理由 |
|------|------|------|
| 认证中间件 | src/auth/middleware.ts | JWT 签发与验证入口 |
| JWT 工具 | src/auth/jwt.ts | Token 生成/解析/刷新 |

## 模块职责

| 文件/模块 | 职责 | 与本主题的关系 |
|-----------|------|---------------|
| auth/middleware.ts | 请求认证入口，串联多个中间件 | 核心 |
| auth/jwt.ts | JWT 生成、验证、Token 刷新 | 核心依赖 |

## 关键接口

| 函数/方法 | 签名 | 说明 |
|-----------|------|------|
| createToken | `(payload: UserPayload) => string` | 签发新 JWT |
| verifyToken | `(token: string) => TokenPayload \| null` | 验证 JWT 有效性 |
| refreshToken | `(oldToken: string) => string \| null` | 刷新过期 Token |

## 依赖关系

> [以文字或 ASCII 图描述模块间的调用/依赖关系]

## 风险与边界

| 风险/边界 | 来源 | 影响 | 建议 |
|-----------|------|------|------|
| Token 无状态吊销 | auth/jwt.ts:45 | 无法主动失效 | 引入黑名单或短有效期 + refresh |

## 探索记录

| 文件 | 读取得出 | 是否需要深入 |
|------|---------|-------------|
| src/auth/middleware.ts | 完整分析 | 否 |
| src/auth/jwt.ts | 完整分析 | 否 |
| src/auth/session.ts | 仅读取接口 | 是（如需了解会话存储细节） |
```

---

## worker 探索策略

> 以下由 `rdd-explore` worker 在收到 miss dispatch prompt 后执行。

### 输入来源

1. 解析 dispatch prompt 中的 Query，提取关键词和意图
2. 根据 Query 在源码目录中定位相关文件

### 探索范围

- 根据 Query 关键词在源码目录中搜索相关函数/类/文件
- 以找到的文件为入口，沿 import/include 关系向外扩展 1-2 层
- 扩展边界：发现的文件总数控制在 5-15 个之间

### 探索要点

对每个被探索的文件/模块，记录：

1. **职责**：这个模块/文件做什么？（一句话）
2. **关键接口**：与主题相关的函数签名、类型
3. **依赖关系**：引用了哪些模块？被哪些模块引用？
4. **风险信号**：过长函数、深层嵌套、循环依赖等

### 完成步骤

1. 按正文模板写 artifact 到 `.rdd/exploration/artifacts/{topic-slug}.md`
2. 调用 `rdd-engine/scripts/explore.cmd -Type register` 注册（传入实际分析过的文件列表）
3. 返回一句话摘要给调用方角色

---

## 缓存特性

- **全局共享**：PM 探索过的结果，CTO/DEV/QA/UX 无需重新探索
- **自动失效**：涉及文件变更后 SHA-256 不匹配，`explore` 自动移除 stale 条目并 miss
- **零子代理命中**：命中缓存时 CLI 直接返回产物，不派遣任何子代理（触发成本最低）
- **索引文件**：`.rdd/exploration/index.json`，产物目录：`.rdd/exploration/artifacts/`

# 代码探索执行指南

> **定位**：全局代码探索能力。各角色（PM/CTO/DEV/QA/UX）需要理解项目代码时，委托 engine 执行。
> 采用**三层缓存结构**（索引 → 摘要 → 完整记录），缓存于 `.rdd/exploration/`。

---

## 职责划分

探索能力由**三方协作**完成，职责严格分离：

| 角色 | 承载 | 职责 | 是否可写缓存 |
|------|------|------|-------------|
| **缓存仲裁（CLI）** | `explore.ps1`（确定性脚本） | 读 index、SHA-256 时效过滤（剔除 stale 条目）、返回全部 fresh candidates + dispatch prompt；register 时校验配对、算哈希、写 index | 读写 index（程序化） |
| **调用方角色 LLM** | PM/CTO/DEV/QA/UX 会话 | 扫描 candidates 的 `tags` + `brief`，结合 Query **自主判断**是否有相关缓存。命中 → Read 摘要；无匹配 → 用 dispatch prompt 派遣 worker | 不可写 |
| **探索 worker** | `rdd-explore` 子代理（可写） | 探索代码、写摘要 + 完整记录、打 tags、调 register 注册、返回一句话摘要 | 写产物 + 调 register |

> **关键设计**：CLI **不做语义匹配**，只做时效维护（剔除过期条目）和索引快照提供。语义判断完全在调用方 LLM 侧——`tags` 是 LLM 的阅读语言，保持完整语义，不被脚本拆解。
>
> **关键约束**：worker 必须是**可写**子代理（需写产物 + 调 register）。内置的只读 `explore` / `general` 子代理无法完成注册，**禁止用于代码探索**。

---

## 三层缓存结构

| 层级 | 载体 | 内容 | 何时用 |
|------|------|------|--------|
| **索引** | `index.json` entry | key / tags / brief / path / files | 匹配 + 快速核对 |
| **摘要** | `artifacts/{slug}.summary.md` | 5-15 行结构化精炼：模块职责 + 关键接口 + 核心依赖 | **LLM 判断命中后读取**，替代完整文档污染 context |
| **完整记录** | `artifacts/{slug}.md` | 详细探索文档（探索范围、模块职责、关键接口、依赖关系、风险边界、探索记录） | 调用方需要深入细节时按需读 |

**命名配对约定**：完整记录 `{slug}.md` 与摘要 `{slug}.summary.md` 固定配对。`summaryPath` 不入 index，由 CLI 从 `path` 派生（`.md` → `.summary.md`），保持 index schema 最小。

---

## 调用方式

### 角色侧：第一步始终是 CLI 探索

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type explore -Query "分析认证模块的中间件链和 Token 刷新机制"
```

返回 JSON，`data.candidates` 是**全部**通过 SHA-256 时效校验的条目（每条含 `key` / `tags` / `brief` / `summaryPath` / `fullPath`）。然后**调用方 LLM 自行判断**：

- 扫描 `candidates` 的 `tags` + `brief`，结合 Query 判断是否有相关缓存
- **命中** → 用 Read 工具读 `summaryPath`（摘要）。需深入细节再读 `fullPath`（完整记录）
- **无匹配** → 用 `data.dispatchPrompt` 派遣 `rdd-explore` 子代理（可写 worker）

> `hit/miss` 二元状态已移除。candidates 为空（冷启动）时，LLM 自然走 dispatchPrompt。

### worker 侧：探索完成后注册

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type register `
  -Key "认证中间件链和 Token 刷新" `
  -Tags "认证,鉴权,登录,auth,jwt,token,中间件,middleware,权限,session" `
  -Path ".rdd/exploration/artifacts/auth-middleware.md" `
  -Brief "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑" `
  -Files "src/auth/middleware.ts,src/auth/jwt.ts,src/auth/session.ts"
```

`register` 会校验 `{slug}.md` 与 `{slug}.summary.md` 配对存在、计算每个文件的 SHA-256、按 key 去重后追加进 index。

---

## CLI 执行流程（explore.ps1）

### `-Type explore`

```
接收 Query
    │
    ▼
读取 .rdd/exploration/index.json
    │
    ├── 文件不存在或 entries 为空 → candidates = []（仍返回 dispatchPrompt）
    │
    ▼
遍历所有 entry，对每个做 SHA-256 时效校验
    │
    │  对 entry.files 中每个文件路径：
    │    1. 文件是否存在？
    │    2. Get-FileHash -Algorithm SHA256 → 与存储哈希比对
    │  另校验 entry.path（完整记录）文件存在
    │
    ├── 任一不匹配或文件被删 → 该 entry 标记 stale
    │       → 从 index 删除所有 stale entry
    │
    ▼
收集全部 fresh entry，构建 candidates
    │  每条含：key / tags / brief / summaryPath(派生) / fullPath
    │
    ▼
返回 { candidates, dispatchPrompt, staleRemoved }
```

> **脚本不做语义匹配**。所有 fresh entry 全量返回，由调用方 LLM 扫 tags 判断相关性。

### `-Type register`

```
接收 Key / Tags / Path / Brief / Files
    │
    ▼
校验完整记录文件存在 → 不存在则报错
    │
    ▼
校验配对摘要文件存在（{slug}.summary.md）→ 不存在则报错 SUMMARY_NOT_FOUND
    │
    ▼
校验 Tags 非空 → 空则报错 MISSING_TAGS
    │
    ▼
对 Files 列表中每个文件计算 SHA-256
    │   文件不存在则报错
    │
    ▼
按 Key（及 Path）去重，移除同 key 旧条目
    │
    ▼
追加新条目（含 tags） → 写回 index.json（UTF-8 无 BOM，路径用 / 分隔）
    │
    ▼
返回 { registered: true, summaryPath, tagsCount, filesCount }
```

---

## 输出格式

CLI 输出 UTF-8 JSON，控制台输出编码已设为 UTF-8，保证任何调用方（PowerShell / cmd / bash / opencode / Claude）解码一致。

### candidates 返回（explore 始终返回此结构）

```json
{
  "success": true,
  "data": {
    "query": "分析认证模块的中间件链",
    "candidates": [
      {
        "key": "认证中间件链和 Token 刷新",
        "tags": ["认证","鉴权","登录","auth","jwt","token","中间件","middleware"],
        "brief": "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑",
        "summaryPath": ".rdd/exploration/artifacts/auth-middleware.summary.md",
        "fullPath": ".rdd/exploration/artifacts/auth-middleware.md"
      }
    ],
    "staleRemoved": 0,
    "dispatchPrompt": "<内嵌完整协议的 worker 指令，含 Query + 本指南全文>"
  }
}
```

调用方取 `data.dispatchPrompt` 派遣 `rdd-explore` 子代理即可（仅当 LLM 判断无匹配时），无需额外拼接协议。

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
      "tags": ["认证","鉴权","登录","auth","jwt","token","中间件","middleware"],
      "brief": "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑",
      "path": ".rdd/exploration/artifacts/auth-middleware.md",
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
| `key` | string | 语义描述，标识这次探索的主题 |
| `tags` | string[] | 关键词标签，**LLM 判断命中/未命中的核心依据**（覆盖模块名/功能名/同义词，中英文混合） |
| `brief` | string | 一句话摘要，供调用方快速核对 |
| `path` | string | 完整记录文件路径（相对于 repo root，`/` 分隔）。摘要路径由它派生：`.md` → `.summary.md` |
| `files` | object | `{ 文件路径: "sha256:哈希值" }`，仅包含产物中实际分析过的文件 |

### 操作规则（由 CLI 维护，worker 不直接写 index）

- **追加/更新**：`register` 按 key 去重后追加，同 key 旧条目被替换
- **删除 stale**：`explore` 时效性检查失败，CLI 自动移除对应条目
- **文件不存在**：视为空索引，返回空 candidates
- **文件损坏**（JSON 解析失败）：报错退出，建议手动删除重建

> worker 只通过 `register` 子命令间接写 index，不直接编辑 index.json，保证 schema 一致。

---

## 产物文件格式

每个探索主题产出**两个配对文件**，写在 `.rdd/exploration/artifacts/` 下。

### 命名（配对约定）

以探索主题命名，使用小写英文 + 连字符：

| 文件 | 作用 |
|------|------|
| `{slug}.md` | 完整记录（详细文档） |
| `{slug}.summary.md` | 摘要（5-15 行精炼） |

例如 `auth-middleware.md` + `auth-middleware.summary.md`。重名时追加数字：`auth-middleware-2.md` + `auth-middleware-2.summary.md`。

> **register 强制校验配对**：缺摘要文件会报 `SUMMARY_NOT_FOUND`，两者必须同时写。

### 文件头

两个文件第一行均为元信息注释：

```html
<!-- exploration-artifact: key="认证中间件链" tags="认证,鉴权,auth,jwt" files="src/auth/middleware.ts,src/auth/jwt.ts,src/auth/session.ts" -->
```

> 此注释供人工阅读与 register 时参考（register 参数以 CLI 传入为准）。

### 摘要模板（{slug}.summary.md）

5-15 行结构化精炼，是 LLM 命中缓存后**实际消费**的内容。只保留决策必要信息，不展开细节：

```markdown
<!-- exploration-artifact: key="主题名" tags="标签1,标签2,..." files="路径1,路径2,..." -->

# 主题名

> 一句话定位（这个模块/功能做什么）。

## 核心模块

- `src/auth/middleware.ts` — 请求认证入口，串联多个中间件
- `src/auth/jwt.ts` — JWT 生成/验证/刷新

## 关键接口

- `createToken(payload)` — 签发新 JWT
- `verifyToken(token)` — 验证有效性
- `refreshToken(oldToken)` — 刷新过期 Token

## 核心依赖

middleware.ts → jwt.ts → session.ts（会话存储）

## 关键风险

- Token 无状态吊销（auth/jwt.ts:45），无法主动失效
```

### 完整记录模板（{slug}.md）

详细探索文档，调用方需要深入细节时按需读取：

```markdown
<!-- exploration-artifact: key="主题名" tags="标签1,标签2,..." files="路径1,路径2,..." -->

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

> 以下由 `rdd-explore` worker 在收到 dispatch prompt 后执行。

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

### 打 tags（关键步骤）

tags 是后续 LLM 判断命中/未命中的**核心依据**，要打得"宽"——覆盖不同的表达方式：

- **模块名**：探索涉及的模块/目录名（如 `认证`、`auth`、`middleware`）
- **功能名**：探索主题的功能描述（如 `Token刷新`、`权限校验`、`登录`）
- **同义词**：同一概念的不同表达（`认证`/`鉴权`/`授权`、`auth`/`authentication`）
- **中英文都打**：中文词 + 对应英文词，覆盖两种 Query 习惯
- **数量**：5-10 个为宜，太少覆盖不够，太多稀释语义

**示例**：探索"认证中间件链" → tags = `认证,鉴权,登录,auth,jwt,token,中间件,middleware,权限,session`

### 完成步骤

1. 写摘要到 `.rdd/exploration/artifacts/{slug}.summary.md`（按摘要模板，5-15 行）
2. 写完整记录到 `.rdd/exploration/artifacts/{slug}.md`（按完整记录模板）
3. 调用 `explore.cmd -Type register` 注册：
   - `-Key`：语义 key，中文可用，与 Query 主题对应
   - `-Tags`：上面打的标签，逗号分隔
   - `-Path`：`.rdd/exploration/artifacts/{slug}.md`（完整记录路径）
   - `-Brief`：一句话摘要
   - `-Files`：实际读过并分析过的文件路径列表（repo-relative，逗号分隔）
4. 返回一句话摘要给调用方角色

> `files` 只列**实际读过并分析**的文件；这些文件的哈希会被记录，日后任一变更会自动触发缓存失效。

---

## 缓存特性

- **全局共享**：PM 探索过的结果，CTO/DEV/QA/UX 无需重新探索
- **自动失效**：涉及文件变更后 SHA-256 不匹配，`explore` 自动剔除 stale 条目
- **索引文件**：`.rdd/exploration/index.json`，产物目录：`.rdd/exploration/artifacts/`
- **三层结构**：index（索引）→ summary（摘要，命中时读）→ full record（完整记录，按需读）

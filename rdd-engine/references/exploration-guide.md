# 代码探索执行指南

> **定位**：全局代码探索能力。各角色（PM/CTO/DEV/QA/UX）需要理解项目代码时，委托 engine 执行。
> 采用**双层缓存**（热区 → 持久层）+ **三层产物结构**（索引条目 → 摘要 → 完整记录），缓存于 `.rdd/exploration/`。

---

## 职责划分

探索能力由**三方协作**完成，职责严格分离：

| 角色 | 承载 | 职责 | 是否可写缓存 |
|------|------|------|-------------|
| **缓存仲裁（读面 CLI）** | `explore.ps1` | search/explore 合并读双 zone（热区优先）、SHA-256 时效过滤（stale 直接驱逐出所在 zone）、**精度排序管线**（多路召回 → RRF 融合 → Top-K 截断）、返回排序结果 + dispatch prompt；register 为废弃转发 | 只读（stale 驱逐除外） |
| **缓存仲裁（写面 CLI）** | `explore-store.ps1` | register 落热区（盖 registeredAt，配置齐备时同步 embedding）；persist 按 key 转正进 index.json；sweep（TTL/容量溢出 → 保底转正）；embed-backfill 向量补齐 | 读写 index + hot + vectors（程序化） |
| **调用方角色 LLM** | PM/CTO/DEV/QA/UX 会话 | 按两分支协议消费：`results` 非空 = **命中**（相关性已由管线判定，读摘要）；`results` 为空 = **未命中**（用 dispatchPrompt 派遣 worker） | 不可写 |
| **探索 worker** | `rdd-explore` 子代理（可写） | 探索代码、写摘要 + 完整记录、打 tags、调 explore-store register 注册、返回一句话摘要 | 写产物 + 调 register |

> **关键设计**：CLI 内置**确定性精度排序管线**——多路召回（词法 BM25 + 向量余弦，可插拔）→ RRF 融合 → Top-K 截断。相关性判定由冻结公式（F1–F8，见下文"检索精度管线"）在管线内完成，调用方不再自行扫 tags 判断。`tags` 的双重角色：既是 LLM 的阅读语言，又直接进入词法召回的检索语料（F1），保持完整语义、不做脚本拆解。
>
> **关键约束**：worker 必须是**可写**子代理（需写产物 + 调 register）。内置的只读 `explore` / `general` 子代理无法完成注册，**禁止用于代码探索**。

---

## 双层缓存结构

```
探索 worker / DSH 插件（代写产物并注册）
     │  写配对产物（共享，不动）：artifacts/{slug}.md + {slug}.summary.md
     │  explore-store.cmd -Type register（校验链：配对/哈希）
     ▼
┌─────────────────────────┐
│  hot.json（热区）         │  entry 同构 + registeredAt；register 即可见
│  保留 7 天 / 容量 50 条    │  常量置顶（$HotRetentionDays/$HotCapacity）
└───────────┬─────────────┘
    sweep 保底转正（register/persist 时触发：到期/溢出 → 按原样落入 index）
    persist -Key 显式转正（异步增强管线将来调用）
            │   转正 = 纯索引条目搬运（先写 index 后清 hot，幂等去重替换）
            ▼
┌─────────────────────────┐
│  index.json（持久层）      │  schema 与旧版完全一致
└───────────┬─────────────┘
            │
            ▼
explore.cmd -Type search（检索接口：合并双 zone，热区优先，origin 标注，
                          同 key/同产物 双 zone 热区胜出，miss 附 dispatchPrompt）
```

### 热区生命周期

| 事件 | 行为 |
|------|------|
| **register** | 新探索结果同步写入 hot.json（盖 `registeredAt`，ISO-8601 UTC）。下一次 search/explore 立即可见，**不等任何异步管线** |
| **sweep（TTL）** | 每次 register/persist 调用时：`registeredAt` 超 7 天仍未转正 → **按原样**自动落入 index.json（保底不丢：异步增强管线未运行/失败不丢任何已探索结果） |
| **sweep（容量）** | hot 条目数超 50 → 最旧未转正条目自动转正 |
| **persist** | 显式转正：热区条目按 key 转正进 index.json（去重替换），成功后从 hot.json 移除；key 不存在报 `HOT_KEY_NOT_FOUND`。供后续异步增强管线（标题重写/向量/BM25，另行立项）完成后调用 |
| **stale 驱逐** | search/explore 读时发现内容失效（SHA-256 不匹配/文件被删）→ 直接**驱逐出所在 zone**，热区 stale 条目**不转正**（stale = 代码已变，与管线未运行无关）。产物 md 文件保留 |

**转正写序**：先写 index.json 后清 hot.json。中断的极端场景产生双 zone 重复条目时，靠转正幂等（去重替换）+ 检索同 key/同产物抑制自愈。sweep 失败不阻断 register（热区写入成功即不丢，下次 sweep 幂等重试）。

### 三层产物结构

| 层级 | 载体 | 内容 | 何时用 |
|------|------|------|--------|
| **索引条目** | hot.json / index.json entry | key / tags / brief / path / files（热区多一个 registeredAt） | 匹配 + 快速核对 |
| **摘要** | `artifacts/{slug}.summary.md` | 5-15 行结构化精炼：模块职责 + 关键接口 + 核心依赖 | **LLM 判断命中后读取**，替代完整文档污染 context |
| **完整记录** | `artifacts/{slug}.md` | 详细探索文档（探索范围、模块职责、关键接口、依赖关系、风险边界、探索记录） | 调用方需要深入细节时按需读 |

**命名配对约定**：完整记录 `{slug}.md` 与摘要 `{slug}.summary.md` 固定配对。`summaryPath` 不入索引，由 CLI 从 `path` 派生（`.md` → `.summary.md`），保持索引 schema 最小。

---

## 检索精度管线（冻结契约）

search 的排序由以下**冻结公式**确定（`explore.ps1` + `explore-store.ps1` 与 dsh 插件 `@coderrdd/dsh-rdd-explore` 双侧字面镜像；改任何一条前先改本表，双侧同步 + `tests/search-ranking.mjs` 回归）：

| 编号 | 冻结内容 |
|------|---------|
| **F1** | 检索文本 = `key + "\n" + tags.join(",") + "\n" + brief` |
| **F2** | textHash = `"sha256:" + SHA256(UTF-8(text)).hex` |
| **F3** | 分词：lowercase → `[a-z0-9]+` 连续段各一词；CJK 连续段（`[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+`）整体一词 + 全部相邻二元组 |
| **F4** | BM25：`idf(t) = ln((N - df + 0.5)/(df + 0.5) + 1)`，k1=1.2 b=0.75，query token 去重累加，得分 >0 才入 qualified |
| **F5** | embedding：POST `{endpoint}`，body `{model, input:[texts]}`，Bearer `$env:RDD_EMBED_APIKEY`，取 `data[i].embedding` |
| **F6** | 向量有效 = sidecar 条目 model 匹配 ∧ textHash 匹配 ∧ 维度 == dimensions |
| **F7** | RRF：`score(d) = Σ_r weight_r / (rrfK + rank_r(d))`，rank 从 1，按注册序逐路累计（lexical 在 vector 前） |
| **F8** | Top-K 总分序：score DESC → origin hot 优先 → registeredAt DESC（persistent 视为最旧）→ key 字典序 ASC |

### 召回器插件协议

召回器放在 `scripts/recallers/*.ps1`（按文件名排序 dot-source，即注册序 = F7 累计序）：调 `Register-Recaller -Name <name> -DefaultEnabled <true|false|"auto"> [-AutoReady <scriptblock>] -ScriptBlock <block>`。输入 `{ query, docs, config, paths }`，输出 `{ name, scores, qualified[按名次], warning? }`；抛异常被管线捕获 → 空贡献 + failed 状态。`"auto"` 启用判定由 AutoReady 只读评估（不调 API）。新增一路召回 = 加一个文件，既有路径零改动。

### 运行时文件（`.rdd/exploration/`）

**`search-config.json`**（调参，全字段可省；PS/TS 共享的唯一运行时事实源）：

```json
{
  "topK": 5,
  "recallDepth": 20,
  "rrfK": 60,
  "recallers": {
    "lexical": { "enabled": true, "weight": 1.0, "bm25K1": 1.2, "bm25B": 0.75 },
    "vector": {
      "enabled": "auto",
      "weight": 1.0,
      "endpoint": "https://.../v1/embeddings",
      "model": "text-embedding-...",
      "dimensions": 1536,
      "minCosine": 0.30,
      "timeoutSeconds": 10
    }
  }
}
```

- 缺失/损坏 → 默认值 + stderr 告警（fail-soft：调参文件 vs 索引源数据的容错不对称是**有意设计**——索引数据损坏必须 fail-loud `INDEX_CORRUPT`）
- 字段级类型校验：非法值静默回默认（如 topK=0、minCosine=1.5）
- `vector.enabled = "auto"`：endpoint + model + dimensions≥1 + `$env:RDD_EMBED_APIKEY` 四要素齐备才启用，缺哪个 rankMeta 的 warning 点名哪个

**`vectors.json`**（向量 sidecar；gitignore 的派生数据，可随时删除重建）：

```json
{ "entries": [ { "key": "...", "textHash": "sha256:...", "model": "...", "vector": [0.012, -0.07, ...] } ] }
```

主键 `(key, textHash, model)` upsert；多模型向量共存（F6 按 model 过滤）；内容变更（textHash 变）自动失效重嵌。读取 fail-soft（损坏 → 空 + 告警，词法路不受影响）。

### 写入路径的 embedding

- **register 钩子**（explore-store.ps1）：注册成功后同步 embedding 单条（配置齐备时）；复用 textHash 命中的既有向量；失败仅告警。输出 `embed = { status: skipped|reused|embedded|failed, model?, reason? }`
- **embed-backfill**：全池补齐/重建（见上文"向量补齐"），换模型配 `-PurgeOtherModels`
- **DSH 插件代注册**：无钩子（插件写入路径不引入外部依赖），产物靠词法召回 + backfill 覆盖——跨客户端共享同一份 vectors.json

---

## 调用方式

### 角色侧：第一步始终是 search 检索

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore.cmd" -Type search -Query "分析认证模块的中间件链和 Token 刷新机制"
```

返回 JSON，`data.results` 是**管线排序后的 Top-K 命中**（每条含 `key` / `tags` / `brief` / `summaryPath` / `fullPath` / `origin: hot|persistent` / `score` / `recalledBy`）。调用方按**两分支协议**消费：

- **`results` 非空 = 命中**：相关性已由精度管线判定（分数从高到低）。用 Read 工具读首条（或最相关条目）的 `summaryPath`（摘要）。需深入细节再读 `fullPath`（完整记录）
- **`results` 为空 = 未命中**：返回体附 `dispatchPrompt` → 用它派遣 `rdd-explore` 子代理（可写 worker）

> 检索接口**返回位置而非内容**——调用方按位置自取，不再全量倾倒 candidates 内嵌 ~9KB prompt。命中载荷保持精简。
> 旧三分支中的"results 非空但均不相关 → 改调 explore"分支已删除：Top-K 截断 + 相关性阈值保证非空即相关。`-Type explore`（兼容面，dispatchPrompt 恒附）仅供旧调用方零改动过渡。

### worker 侧：探索完成后注册（写面 explore-store）

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type register `
  -Key "认证中间件链和 Token 刷新" `
  -Tags "认证,鉴权,登录,auth,jwt,token,中间件,middleware,权限,session" `
  -Path ".rdd/exploration/artifacts/auth-middleware.md" `
  -Brief "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑" `
  -Files "src/auth/middleware.ts,src/auth/jwt.ts,src/auth/session.ts"
```

register 会校验 `{slug}.md` 与 `{slug}.summary.md` 配对存在、计算每个文件的 SHA-256、**在热区内**按 key/产物去重后追加（index 同 key 旧条目保留不动，由检索的热区优先与转正的去重替换收口）。注册即落热区，下一次检索立即可见。向量配置齐备（endpoint + model + dimensions + `$env:RDD_EMBED_APIKEY`）时，register 会**同步 embedding 单条**（复用 textHash 一致的既有向量；失败仅告警不阻断注册，输出 `embed.status` = skipped/reused/embedded/failed）；配置缺失则跳过（`skipped`）。DSH 插件代注册的产物无此钩子，靠词法召回 + `embed-backfill` 补齐。

> **旧路径兼容**：`explore.cmd -Type register` 仍可用——薄转发到 explore-store，输出附 `deprecation` 提示。新代码一律直调 explore-store。

### 向量补齐：embed-backfill

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type embed-backfill [-PurgeOtherModels]
```

对合并池（热区 fresh 优先 + 持久层）里的全部条目，按当前向量配置补齐 `.rdd/exploration/vectors.json`：textHash 一致的既有向量**复用**（不重复调 API），内容变更的重新 embedding，单条失败不阻断其余（`failed[]` 逐条报告）。`-PurgeOtherModels` 额外清掉非当前 model 的旧向量（换 embedding 模型后用）。配置不齐时报 `EMBED_CONFIG_INCOMPLETE`（fail loud——与检索侧 fail-soft 不同：这是显式维护命令，静默跳过会让使用者误以为已补齐）。

### 持久化接口：persist（异步增强管线的转正入口）

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\explore-store.cmd" -Type persist -Key "认证中间件链和 Token 刷新"
```

把热区条目按 key 转正进 index.json（去重替换、剥除 registeredAt），成功后从 hot.json 移除。转正后检索 origin 变为 `persistent`，不再依赖热区存活。key 不存在报 `HOT_KEY_NOT_FOUND`。

---

## CLI 执行流程

### `explore.cmd -Type search`（检索接口）

```
接收 Query
    │
    ▼
合并读双 zone：index.json + hot.json
    │  各自做 SHA-256 时效校验（files 哈希 + 完整记录存在性）
    │  stale 条目从所在 zone 驱逐（热区 stale 不转正）
    │  同 key 或同产物 双 zone 并存时，热区胜出（持久层重复项抑制）
    │
    ▼
读 search-config.json（缺失/损坏 → 默认值 + stderr 告警，fail-soft）
    │
    ▼
多路召回（recalls/*.ps1 注册序）：每路输入 { query, docs, config }
    │  lexical：F3 分词 → BM25 评分（F4）→ 得分>0 门槛 → 按 recallDepth 截断 qualified
    │  vector："auto" 时先做就绪评估（配置四要素，无则整路静默跳过）
    │         → F6 过滤（model + textHash + 维度一致的 sidecar 向量才有效）
    │         → query embedding（F5）→ 余弦 ≥ minCosine 门槛 → 按 recallDepth 截断
    │  任一路抛异常 → 该路空贡献 + rankMeta 记 failed（其余路不受影响）
    │
    ▼
RRF 融合（F7）：score(d) = Σ weight_r / (rrfK + rank_r(d))，rank 从 1
    │
    ▼
Top-K 截断（F8 总分序）：score DESC → hot 优先 → registeredAt DESC（persistent 最旧）→ key 字典序
    │
    ▼
返回 { results: [{ key, tags, brief, summaryPath, fullPath, origin, score, recalledBy }],
       staleRemoved, rankMeta: { recallers[], fused, returned } }
    │  results 为空（miss）→ 附 dispatchPrompt
```

> **脚本内置精度排序**。相关性由冻结公式在管线内确定（分数非空即相关），调用方按两分支协议消费，不再自行扫 tags 判断。

### `explore.cmd -Type explore`（兼容面）

与 search 相同的双 zone 合并，但输出字段名保留旧契约 `candidates`，且 **dispatchPrompt 恒附**（无论命中与否）。旧调用方零改动可用；条目新增 `origin` 为超集增量。

### `explore-store.cmd -Type register`（写热区）

```
接收 Key / Tags / Path / Brief / Files
    │
    ▼
校验完整记录存在 → 校验配对摘要存在（{slug}.summary.md）
校验 Tags 非空 → 逐文件算 SHA-256
    │
    ▼
sweep（保留期 7 天 / 容量 50，含本条预留；失败仅告警不阻断）
    │
    ▼
热区内按 key/产物去重 → 追加（盖 registeredAt）→ 写回 hot.json
    │
    ▼
返回 { registered: true, zone: "hot", summaryPath, tagsCount, filesCount, ... }
```

### `explore-store.cmd -Type persist`（转正）

```
接收 Key → 热区定位（不存在报 HOT_KEY_NOT_FOUND）
    │
    ▼
先写 index.json（按 key/产物去重替换，剥除 registeredAt）
后清 hot.json（幂等：中断重试不产生重复）
    │
    ▼
sweep → 返回 { persisted: true, key, path, summaryPath }
```

---

## 输出格式

CLI 输出 UTF-8 JSON，控制台输出编码已设为 UTF-8，保证任何调用方（PowerShell / cmd / bash / opencode / Claude）解码一致。

### search 返回（检索接口）

```json
{
  "success": true,
  "data": {
    "query": "分析认证模块的中间件链",
    "results": [
      {
        "key": "认证中间件链和 Token 刷新",
        "tags": ["认证","鉴权","登录","auth","jwt","token","中间件","middleware"],
        "brief": "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑",
        "summaryPath": ".rdd/exploration/artifacts/auth-middleware.summary.md",
        "fullPath": ".rdd/exploration/artifacts/auth-middleware.md",
        "origin": "hot",
        "score": 0.032787,
        "recalledBy": ["lexical", "vector"]
      }
    ],
    "staleRemoved": 0,
    "rankMeta": {
      "recallers": [
        { "name": "lexical", "status": "ok", "qualified": 3 },
        { "name": "vector", "status": "ok", "qualified": 2 }
      ],
      "fused": 3,
      "returned": 1
    }
  }
}
```

- `score`：RRF 融合分（6 位小数），分数从高到低排序
- `recalledBy`：命中该条目的召回路径名（如 `["lexical","vector"]` 双路确认）
- `rankMeta`：可观测性——各路召回器状态（`ok` / `disabled` / `failed` + qualified 计数 + 失败警告）、融合条目数 `fused`、截断后返回数 `returned`

results 为空（miss）时额外附 `"dispatchPrompt": "<内嵌完整协议的 worker 指令，含 Query + 本指南全文>"`，调用方直接派遣 `rdd-explore` 子代理，无需额外拼接协议。**results 非空时不附 dispatchPrompt**（两分支协议：非空即命中）。

### explore 返回（兼容面）

结构同旧版：`data.candidates[]` + `dispatchPrompt`（恒附）+ `staleRemoved`；candidates 条目在旧字段之上新增 `origin`。

---

## 索引文件：hot.json 与 index.json

### 位置

- 热区：`.rdd/exploration/hot.json`
- 持久层：`.rdd/exploration/index.json`

### hot.json Schema（热区）

```json
{
  "entries": [
    {
      "key": "认证中间件链和 Token 刷新",
      "tags": ["认证","鉴权","登录","auth","jwt","token","中间件","middleware"],
      "brief": "JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑",
      "path": ".rdd/exploration/artifacts/auth-middleware.md",
      "files": {
        "src/auth/middleware.ts": "sha256:abc123def456..."
      },
      "registeredAt": "2026-08-28T18:37:49.1234567Z"
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `key` / `tags` / `brief` / `path` / `files` | — | 与 index.json entry 完全同构 |
| `registeredAt` | string | 热区落盘时间（ISO-8601 UTC），保留期与容量排序依据；转正时剥除 |

### index.json Schema（持久层）

与旧版**完全一致**：`{ "entries": [{ key, tags, brief, path, files }] }`（无 registeredAt）。

### 操作规则（由 CLI 维护，worker 不直接写索引）

- **入热区**：`explore-store register` 在热区内按 key/产物去重后追加；index 同 key 旧条目保留不动（检索热区胜出，转正时去重替换收口）
- **转正**：`explore-store persist` 或 sweep（TTL 到期 / 容量溢出）→ 先写 index（去重替换）后清 hot，幂等
- **驱逐 stale**：search/explore 时效性检查失败，CLI 自动将条目移出所在 zone
- **文件不存在**：视为空（该 zone 无条目）
- **文件损坏**（JSON 解析失败）：报错退出（`INDEX_CORRUPT` / `HOT_CORRUPT`），建议手动删除重建

> worker 只通过 `explore-store register` 子命令间接写缓存，不直接编辑 hot.json / index.json，保证 schema 一致。

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

tags 是**双重资产**：既是调用方 LLM 的阅读语言，又直接进入词法召回的检索语料（F1 拼进检索文本参与 BM25 评分）——**query 里的词与 tags 命中，条目才有分**。要打得"宽"，覆盖不同的表达方式：

- **模块名**：探索涉及的模块/目录名（如 `认证`、`auth`、`middleware`）
- **功能名**：探索主题的功能描述（如 `Token刷新`、`权限校验`、`登录`）
- **同义词**：同一概念的不同表达（`认证`/`鉴权`/`授权`、`auth`/`authentication`）
- **中英文都打**：中文词 + 对应英文词——中文 query 命中英文 tags（反之亦然）主要靠这里的重合（跨语语义匹配则由向量路兜底，但那需要 embedding 配置）
- **数量**：5-10 个为宜，太少召回覆盖不够（词法路丢分），太多稀释 BM25 权重（每多一个 tag 都在摊薄语料长度归一化）

**示例**：探索"认证中间件链" → tags = `认证,鉴权,登录,auth,jwt,token,中间件,middleware,权限,session`

### 完成步骤

1. 写摘要到 `.rdd/exploration/artifacts/{slug}.summary.md`（按摘要模板，5-15 行）
2. 写完整记录到 `.rdd/exploration/artifacts/{slug}.md`（按完整记录模板）
3. 调用 `explore-store.cmd -Type register` 注册：
   - `-Key`：语义 key，中文可用，与 Query 主题对应
   - `-Tags`：上面打的标签，逗号分隔
   - `-Path`：`.rdd/exploration/artifacts/{slug}.md`（完整记录路径）
   - `-Brief`：一句话摘要
   - `-Files`：实际读过并分析过的文件路径列表（repo-relative，逗号分隔）
4. 返回一句话摘要给调用方角色

> `files` 只列**实际读过并分析**的文件；这些文件的哈希会被记录，日后任一变更会自动触发缓存失效。

---

## 缓存特性

- **热区即时可见**：worker 注册即落热区，下一次检索（含跨会话/跨角色）立即可见，不等任何异步管线
- **保底不丢**：超保留期（7 天）或容量溢出（50 条）仍未转正的热区条目，由 sweep 按原样自动落入持久层；任何已探索结果不因异步管线未运行而丢失
- **精度排序**：search 内置多路召回 + RRF 融合 + Top-K 截断（冻结公式 F1–F8）；词法路零配置常开，向量路配置齐备自动启用，任一路故障降级不阻塞检索
- **全局共享**：PM 探索过的结果，CTO/DEV/QA/UX 无需重新探索
- **自动失效**：涉及文件变更后 SHA-256 不匹配，检索时自动驱逐 stale 条目（产物 md 保留；向量随 textHash 失效自动重嵌）
- **索引文件**：`.rdd/exploration/hot.json`（热区）+ `.rdd/exploration/index.json`（持久层）+ `.rdd/exploration/search-config.json`（调参）+ `.rdd/exploration/vectors.json`（向量 sidecar，gitignore），产物目录：`.rdd/exploration/artifacts/`
- **三层结构**：索引条目（热区/持久层）→ summary（摘要，命中时读）→ full record（完整记录，按需读）

---

## 平台差异与废弃记录

- **OpenCode MCP 工具已废弃**：`.opencode/tools/rdd_explore.ts`（rdd_explore / rdd_explore_register）与现行协议双重断裂（恒走 MISS 分支、注册缺 Tags 必然失败）且零存量用户，已删除。OpenCode 的规范路径是 SKILL → shell CLI（`explore.cmd -Type search` / `explore-store.cmd -Type register`）。旧版安装过该工具的项目可用 `coderrdd uninstall` 按清单清理，或手动删除 `.opencode/tools/rdd_explore.ts`。
- **协议双实现冻结契约**：本指南描述的 hot.json / index.json 双索引格式与检索精度公式（F1–F8、search-config.json、vectors.json）同时由 dsh 插件（`@coderrdd/dsh-rdd-explore`，DSH 探索链路：只读 worker 结构化返回 → harness 代写产物并注册）镜像实现，两侧必须同步修改（回归防线：插件 `tests/search-ranking.mjs` 的 PS/TS 双侧一致性断言）。

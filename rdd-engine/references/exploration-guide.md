# /explore 探索指令执行指南

> **定位**：全局代码探索能力。各角色（PM/CTO/DEV/QA）需要理解项目代码时，委托 engine 执行。
> 产物缓存于 `.rdd/exploration/artifacts/`，通过 `.rdd/exploration/index.json` 索引，
> 后续同主题探索命中缓存后直接返回，无需重复探索。

---

## 调用方式

各角色在 task 中调用：

```powershell
explore.cmd -Type explore -Query "分析认证模块的中间件链和 Token 刷新机制"
```

---

## 执行流程

```
接收 Query
    │
    ▼
读取 .rdd/exploration/index.json
    │
    ├── 文件不存在或 entries 为空 → 跳到"生成新产物"
    │
    ▼
语义匹配：Query 意图 ↔ entries[].key
    │
    ├── 无匹配 → 跳到"生成新产物"
    │
    ▼
匹配命中 → 对命中的 entry，逐个检查 files 即时效性
    │
    │  对 entry.files 中每个文件路径：
    │    1. 文件是否存在？
    │    2. Get-FileHash -Algorithm SHA256  → 与 entry.files[path] 比对
    │
    ├── 全部一致 → 产物 fresh，读取 artifact 内容，返回给角色
    │
    └── 任一不匹配或文件被删 → 产物 stale
           → 从 index 中删除该 entry
           → 跳到"生成新产物"
```

### 生成新产物

1. **探索代码**：按"探索策略"章节执行
2. **写入产物**：`.rdd/exploration/artifacts/{topic-slug}.md`
3. **更新索引**：在 `index.json` 的 `entries` 数组中追加新条目
4. **返回结果**：将产物内容摘要返回给角色

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
| `key` | string | 语义描述，用于与 Query 匹配 |
| `path` | string | 产物文件路径（相对于 repo root） |
| `brief` | string | 一句话摘要，命中后可快速判断是否匹配 |
| `files` | object | `{ 文件路径: "sha256:哈希值" }`，仅包含产物中实际分析过的文件 |

### 操作规则

- **追加**：新产物条目追加到 `entries` 数组末尾，不覆盖已有 entry
- **删除 stale**：时效性检查失败时，从 `entries` 中移除对应条目
- **文件不存在**：视为空索引，跳过匹配直接生成
- **文件损坏**（JSON 解析失败）：报错退出，建议手动删除重建

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

> 此注释供注册 index 时提取，不影响 markdown 渲染。

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

## 探索策略

### 输入来源

1. 解析 Query，提取关键词和意图
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

---

## 返回给角色

执行完毕后，角色的 task 应收到：

### 命中缓存时

```
已找到相关探索产物（生成于 2026-06-05）：

.rdd/exploration/artifacts/auth-middleware.md

摘要：JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑
涉及文件：src/auth/middleware.ts, src/auth/jwt.ts, src/auth/session.ts

[产物正文]
```

### 新生成时

```
已完成探索，产物已缓存：

.rdd/exploration/artifacts/auth-middleware.md

摘要：JWT 签发→验证→权限检查的中间件链，含 Token 刷新逻辑

[产物正文]
```


# 探索缓存（rdd-explore）

> 解决的问题：多角色、多会话、多模型之间缺乏知识共享——同一份代码被反复理解，Token 与时间浪费严重。探索缓存让任一角色 / 会话探索过的代码理解**零成本复用**给其余角色与后续会话。

## 是什么

一个落在项目内的**代码理解知识库**（`.rdd/exploration/`），由 rdd-engine 提供 CLI、由 DSH 插件提供模型工具 `rdd_explore`。检索是"缓存优先"两分支：

- **命中**（results 非空）→ 直接读摘要，不派 agent，零成本复用
- **未命中**（results 为空）→ 自动派遣探索 worker 子代理调查代码，产出配对产物（全文 + 摘要）并注册回缓存——下次任何人问同一主题直接命中

相关性判定在检索管线内部完成（多路召回融合后截断 Top-K），调用方不需要自己看 tags 挑结果。

## 运行数据布局

```
.rdd/exploration/
├── hot.json            # 热区：新探索结果先落此（保留 7 天 / 容量 50 条，超期由 sweep 保底转正）
├── index.json          # 持久层索引
├── artifacts/          # 配对产物：{slug}.md（全文）+ {slug}.summary.md（摘要）
├── search-config.json  # 检索调参（可省，全字段有默认值）
├── vectors.json        # 向量 sidecar（gitignore 派生数据，可随时重建）
└── query-log.jsonl     # 六字段查询流水（ts/entry/query/outcome/keys/recallers）——命中率观测数据源
```

## 检索管线（F1–F8 冻结公式）

```
检索文本 = key + tags + brief（F1）
  → 分词（F3，CJK 二元组）
  → 双路召回：词法 BM25（F4，k1=1.2 b=0.75）+ 向量余弦（F5/F6，"auto" 四要素齐备才启用）
  → RRF 融合（F7，Σ weight/(rrfK+rank)，rrfK=60）
  → Top-K 截断（F8，默认 topK=5）
```

公式与缓存格式是**冻结契约**（协议单源：[`rdd-engine/references/exploration-guide.md`](../rdd-engine/references/exploration-guide.md)），由 PowerShell CLI 与 TypeScript 插件双实现共同遵守，`tests/search-ranking.mjs` 断言双侧一致性——单侧改格式或公式会静默撕裂跨客户端缓存，改动必须先改冻结表并双侧同步。

## 双实现

| 实现 | 入口 | 说明 |
|------|------|------|
| 引擎侧（PowerShell） | `explore.cmd -Type search`（读面）/ `explore-store.cmd -Type register\|persist\|embed-backfill`（写面） | 零 node 依赖；register 即落热区可见；召回器插件协议 `scripts/recallers/*.ps1` |
| DSH 插件（TypeScript 字面镜像） | 模型工具 `rdd_explore`（见 [DSH 适配](./dsh-integration.md)） | worker 派遣为"无写工具纯研究者"模式（结构化输出返回六字段由插件代写代注册）；周期维护定时器（默认 60 分钟：双区新鲜度清理 + 热区 sweep） |

两侧共享同一份 `.rdd/exploration/`——OpenCode / DSH 等不同客户端对同一项目互通。词法召回两侧恒可用；向量召回依赖 embedding，插件侧注册暂无 embedding 钩子，靠引擎侧 `embed-backfill` 补齐。

## 怎么用

**角色会话内自动使用**：各角色 SKILL.md 的工作流内置"需要理解项目代码时，第一步调用 `rdd_explore` 查询探索缓存"——无需人工介入。

**人类直接用 CLI**（引擎安装后，任意项目）：

```powershell
& "$HOME\.rdd\engine\current\scripts\explore.cmd" -Type search -Query "登录鉴权流程"
```

**观测命中率**：查询流水落 `query-log.jsonl`，运营看板提供命中率趋势与 miss 高频 query 视图——见 [运营端](./ops-dashboard.md)。

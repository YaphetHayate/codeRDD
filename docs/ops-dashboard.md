# 运营端（ops-dashboard）

> 解决的问题：RDD 全链路的数据都落盘可审计（`.rdd/` 下的账本与索引），但缺一个人类可读的观测面。运营看板把这些数据聚合为七个域的只读视图 + 一个受控写面（配置域，外加产物对删除这一经确认的只读原则例外——见「写面 API」节），零 npm 依赖、本地启动。

## 启动

```powershell
# 仓库根的便捷别名（委托 rdd-engine\dashboard\dashboard.cmd，参数透传）
.\ops-dashboard.cmd            # 默认 http://127.0.0.1:8787
.\ops-dashboard.cmd -Port 9000 # 自定义端口

# 或引擎入口（用户级安装形态）
& "$HOME\.rdd\engine\current\dashboard\dashboard.cmd"
```

实现要点：**零 npm 依赖**的 Node 本地只读服务；每请求重读 `.rdd/`、无缓存层（正确性优先的设计决策）；SSR 渲染（无 JS 也有数字）+ `/api/*` 同数据 JSON 面（envelope `{domain,available,meta,data}`，单域故障降级 `available:false` 不倒页）。

## 七个数据域

| 域 | 路由 | 数据源 |
|----|------|--------|
| 需求归档 | `/requirements` | `.rdd/changes/archive/**` |
| 探索缓存 | `/exploration` | `.rdd/exploration/**` |
| 命中率 | `/hit-rate` | `.rdd/exploration/query-log.jsonl`（六字段流水；趋势图 / miss 高频 query） |
| 检索质量 | `/quality` | `.rdd/tests/explore-search/results.json` |
| Tips | `/tips` | `.rdd/tips/entries/*.json` |
| 交付树 | `/goal-trees` | `.rdd/goal-trees/**` + `goal-trees-archive/**`（只读轻量文件 manifest / tree / round-log） |
| 配置中心 | `/config` | env + `search-config.json` + 内置镜像常量（含向量就绪度、跨模块影响、ux-subagents 编辑） |

交付树域只读轻量树文件，`report/` 与 `claims/` 不进聚合——聚合规模随树数增长、不随节点数增长。goal-tree 本身的运行语义见 [goal-tree](./goal-tree.md)。

## 写面 API（配置域 + 受控删除）

只读原则下唯一的写面曾集中在配置域；产物对删除端点是经用户确认的**首个数据面写路径**（只读原则的受控例外，引擎脚本零改动——设计要点见归档 `2026-10-20-exploration-cache-ux/design/artifact-deletion-cto.md`）：

| 端点 | 职责 |
|------|------|
| `/api/config/search-config` | 探索检索参数 patch（校验 + 原子写）——参数语义见[探索缓存](./exploration-cache.md) |
| `/api/config/ux-subagents` | UX 子代理配置（`+sync` 触发 ux-sync） |
| `/api/project/pick` / `/api/project/switch` | 原生目录对话框切换数据根 |
| `/api/exploration/pair/delete` | 产物对**成对删除**（`POST {"slug": "..."}`）：移除 artifact 与 summary 两文件并同步移除 hot.json / index.json 对应条目，全删或全留（失败回滚）；前端二次确认在触发路径上；孤儿产物对拒绝（422）；条目匹配对齐引擎 Get-PathIdentity 语义，zone 写面为引擎同款紧凑形状（往返兼容） |

## 配套 CLI

| 命令 | 职责 |
|------|------|
| `code-metrics.cmd` / `.ps1` | 代码度量（确定性质量数据源） |
| `tips.cmd` / `.ps1` | 项目 tips 记录 / 碰撞 / pin / supersede |

均位于 `rdd-engine\scripts\`（用户级安装形态在 `~\.rdd\engine\current\scripts\`）。

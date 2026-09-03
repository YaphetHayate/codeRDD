# task.json Schema

> **定位**：PM 归档时 task.json 的字段定义与填写指南。完整的路由操作协议（CLI 命令、各角色用法、流转语义）见 `rdd-engine/references/task-routing.md`。
>
> **重要声明**：路由总览为 PM 参考建议，CTO/DEV 可在设计阶段重新组织工作划分（合并、拆分、重排优先级），不受此表约束。
>
> **单一信息源**：`currentOwners` 是角色参与/并行/完成状态的唯一来源。

---

## 位置

`.rdd/changes/archive/<archive-name>/task.json`

## Schema

```json
{
  "version": 1,
  "archive": "<archive-dir-name>",
  "generatedAt": "<ISO datetime, CLI 自动维护>",
  "tasks": [
    {
      "id": 1,
      "title": "需求标题",
      "requirement": "requirements/<name>.md",
      "currentOwners": ["CTO"],
      "designDocs": [
        { "path": "design/<name>-cto.md", "status": "pending" }
      ],
      "remark": "备注（可选）",
      "lifecycle": "active"
    }
  ]
}
```

## 字段填写指南

| 字段 | PM 归档时如何填 | 后续由谁更新 |
|------|----------------|-------------|
| `id` | 不填，CLI 自动编号 | CLI 维护 |
| `title` | 需求标题（对应需求文档一级标题） | — |
| `requirement` | 需求文件路径（归档相对，如 `requirements/fixbug.md`） | — |
| `currentOwners` | 该需求的下一条处理角色。单角色 `["DEV"]`，并行 `["CTO","UX"]` | CLI `advance`/`set-route` |
| `designDocs` | 预填预期设计文档位置，`status` 设为 `"pending"`；无设计文档填 `[]` | CLI `add-design`（CTO/UX 归档设计时） |
| `remark` | 并行标注、特殊说明；无则空字符串 | CLI `reject` 追加驳回摘要 |
| `lifecycle` | 不填（默认 `"active"`） | CLI `complete`/`reopen`/`deprecate` |

## 路由判定（PM 归档时设置 `currentOwners`）

按 `references/artifact-routing.md` 的路由判定规则：
- 简单需求、单一模块/功能、无架构影响 → `["DEV"]`
- 涉及多模块/架构变更/技术选型 → `["CTO"]`
- 涉及页面设计/UI/交互体验 → `["UX"]`
- 复合需求（技术+视觉耦合）→ 先 `["CTO"]`，CTO 完成后路由到 UX

## 生成方式

PM 归档时调用 CLI 初始化（**不要手写 task.json**）：

```powershell
$rdd = $null; $t = $null; try { $t = git rev-parse --show-toplevel } catch { }; foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) { if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $rdd = $c; break } }; if (-not $rdd) { throw "rdd-engine 未定位（三级定位链：RDD_ENGINE_HOME → 项目内 rdd-engine → ~\.rdd\engine\current 全 miss）。安装/排障：GitHub Release 下载 rdd-engine.tgz 后运行 scripts/install-rdd-engine.ps1；协议详见 rdd-engine/references/engine-location.md" }; & "$rdd\scripts\rdd-flow.cmd" -Command init -Archive ".rdd/changes/archive/<name>" -TasksFile ".rdd/changes/archive/<name>/tasks-init.json"
```

`tasks-init.json` 内容为 tasks 数组（UTF-8 无 BOM），示例：

```json
[
  {
    "title": "支持单需求多角色并行流转",
    "requirement": "requirements/multi-owner.md",
    "currentOwners": ["CTO", "UX"],
    "designDocs": [
      { "path": "design/multi-owner-cto.md", "status": "pending" }
    ],
    "remark": "复合需求，CTO+UX 并行"
  },
  {
    "title": "修复登录Bug",
    "requirement": "requirements/fix-bug.md",
    "currentOwners": ["DEV"],
    "designDocs": []
  }
]
```

## 历史兼容

- 旧归档（有 task.md 无 task.json）：`rdd-flow.ps1` 自动回退解析 task.md，各命令仍可工作
- 迁移旧归档：`rdd-flow.cmd -Command migrate -Archive <path>` 将 task.md 转为 task.json
- 旧 task.md 的「角色参与计划」章节、✅⬜ 状态表一律忽略

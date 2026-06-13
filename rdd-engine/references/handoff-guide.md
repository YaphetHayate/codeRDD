# Handoff 交接包指南

> 交接包用于阶段流转时裁剪上下文。下游角色不继承上游长对话，只读取交接包列出的最小文档集合。

## 目标

- 防止 PM/CTO 长对话污染 DEV 执行上下文
- 防止 DEV 默认读取同一归档下无关需求或设计
- 让流转入口变成可校验、可复现的脚本输出

## 调用方式

`-Archive` 为可选参数。不传时脚本自动发现 `.rdd/changes/archive/` 下最新归档。传入不含占位符的具体路径时精确匹配；传入包含 `...` 或 `<...>` 占位符时自动忽略并回退到自动发现。

查看当前归档有哪些角色有待处理任务：

```powershell
rdd-engine/rdd-flow.ps1 -Command next
```

生成目标角色启动引导（全部任务）：

```powershell
rdd-engine/rdd-flow.ps1 -Command start -Role CTO
```

生成目标角色启动引导（单需求，"一需求一会话"）：

```powershell
rdd-engine/rdd-flow.ps1 -Command start -Role DEV -TaskIndex 0
rdd-engine/rdd-flow.ps1 -Command start -Role DEV -TaskIndex 1
```

生成目标角色交接包：

```powershell
rdd-engine/rdd-flow.ps1 -Command handoff -Role DEV
```

可选输出 Markdown：

```powershell
rdd-engine/rdd-flow.ps1 -Command handoff -Role DEV -Format markdown
```

写入文件：

```powershell
rdd-engine/rdd-flow.ps1 -Command handoff -Role DEV -OutFile ".rdd/handoff/dev.json"
```

指定具体归档路径（精确匹配）：

```powershell
rdd-engine/rdd-flow.ps1 -Command next -Archive ".rdd/changes/archive/2026-06-04-engine-adapter-modularization"
rdd-engine/rdd-flow.ps1 -Command start -Role CTO -Archive ".rdd/changes/archive/2026-06-04-engine-adapter-modularization"
rdd-engine/rdd-flow.ps1 -Command handoff -Role DEV -Archive ".rdd/changes/archive/2026-06-04-engine-adapter-modularization"
```

## 交接包内容

脚本读取目标归档目录的 `task.md` 路由总览，只纳入 `当前责任人 = <Role>` 的行。

### 归档目录结构

```
.rdd/changes/archive/YYYY-MM-DD-short-name/
├── task.md                         (路由总览)
├── requirements/                   (PM 产出：需求文档)
│   ├── overview.md
│   └── {name}.md
├── design/                         (CTO/UX 产出)
├── tests/                          (QA 产出)
└── eval/                           (EVAL 产出)
```

### 交接包包含

每个 task 包含：
- 需求标题、需求文件、当前责任人、备注
- 工作模式：`design-guided` / `requirement-guided`
- 需求摘要：描述、验收标准、优先级、影响范围、用户场景、边界、依赖
- 设计摘要：技术方向文档路径、需求概述、技术方案、风险提示、涉及文件
- 忽略项：不属于当前角色、已废弃、存在待处理驳回、责任人不一致的文档

此外，代码探索需求应委托 engine 执行（而非读取 archive 级文件）：
```powershell
engine.ps1 -Type explore -Query "分析..." 
```
engine 通过 `exploration-guide.md` 管理全局可复用缓存。

## 下游读取规则

下游角色必须把交接包视为入口上下文：

1. 读取交接包列出的需求/设计文档
2. 不默认扫描整个归档目录
3. 不读取 `ignored` 中的文档，除非用户明确要求或交接包暴露依赖缺失
4. 代码探索从 `involvedFiles` 中列出的模块开始，需要深入时委托 engine
5. 只有在验收标准、依赖关系、涉及文件不足以执行时，才扩展读取范围

## 校验命令

```powershell
rdd-engine/rdd-flow.ps1 -Command validate -Role DEV -Archive ".rdd/changes/archive/2026-06-04-engine-adapter-modularization"
```

`validate` 只返回任务数量、忽略数量和 warning 数量，用于快速检查流转是否可执行。

## 流转命令语义

| 命令 | 用途 | 输出 | `-TaskIndex` |
|------|------|------|-------------|
| `next` | 汇总 `task.md` 中各角色待处理任务 | 可流转角色、启动命令用法、各角色任务数 | 不支持 |
| `start` | 为指定角色生成启动引导和 handoff packet | skill 路径、启动 prompt、最小交接包 | 支持，>=0 时只筛选单条 |
| `handoff` | 只生成指定角色的最小交接包 | JSON / Markdown handoff | 支持，>=0 时只筛选单条 |
| `validate` | 校验指定角色是否有可处理任务 | task/ignored/warning 计数 | 支持，>=0 时只校验单条 |

## 角色引导规则

上游角色完成归档或设计后，不直接写"进入某模式"作为唯一引导，而是先运行：

```powershell
rdd-engine/rdd-flow.ps1 -Command next
```

当前 agent 根据流程状态和用户确认决定目标角色后，再运行：

```powershell
rdd-engine/rdd-flow.ps1 -Command start -Role <推荐角色> -Format markdown
```

如需并行拉起多个会话（多个同角色需求），每个需求独立启动：

```powershell
rdd-engine/rdd-flow.ps1 -Command start -Role DEV -TaskIndex 0 -Format markdown
rdd-engine/rdd-flow.ps1 -Command start -Role DEV -TaskIndex 1 -Format markdown
```

将 `start` 输出的 prompt 作为新角色入口提示。若当前仍在同一会话内，也必须以该 prompt 和 handoff packet 作为上下文边界，忽略上游长对话中的非产物信息。

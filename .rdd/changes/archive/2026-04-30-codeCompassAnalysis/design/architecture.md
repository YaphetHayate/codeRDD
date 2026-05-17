---
requirement_id: code-compass-能力增强
priority: 高
depends_on: []
blocks:
  - 需求 2
  - 需求 3
  - 需求 4
analysis_date: 2026-05-01
status: confirmed
tech_stack:
  - Markdown (AI Skill 指令)
  - JSON (结构化数据)
  - Grep/Glob/Read (AI Agent 工具)
estimated_effort: 中
---

# code-compass 能力增强 — 整体架构设计文档

## 一、需求概述

将 code-compass 的 `/map` 功能从"单文件全景图"升级为"模块化、函数级、可增量更新"的代码索引系统。4 个需求构成严格线性依赖：存储架构 → 调用关系图 → 入口识别 → 增量更新。

## 二、技术方案

### 2.1 模块化存储架构（需求 1）

#### 目录结构

```
.code-compass/
├── manifest.json              # 全局索引：文件列表、mtime、hash、语言类型
├── overview.md                # 目录结构概览（人类可读）
├── methods/                   # 方法签名数据（每源码文件一个 JSON）
│   ├── backend.services.employee_service.json
│   └── ...
├── calls/                     # 调用关系数据（每源码文件一个 JSON）
│   ├── backend.services.employee_service.json
│   └── ...
└── entries.json               # 入口点汇总（API路由 + 定时任务 + CLI）
```

#### manifest.json 格式

```json
{
  "version": "2.0",
  "generated_at": "2026-04-30T22:00:00",
  "project": {
    "name": "项目名",
    "type": "项目类型",
    "languages": ["python", "typescript"],
    "entry_point": "入口文件路径"
  },
  "stats": {
    "total_files": 42,
    "total_methods": 187,
    "total_entries": 12
  },
  "files": {
    "backend/services/employee_service.py": {
      "language": "python",
      "mtime": 1745894400,
      "hash": "a1b2c3d4",
      "methods_count": 5,
      "calls_file": "calls/backend.services.employee_service.json",
      "methods_file": "methods/backend.services.employee_service.json"
    }
  }
}
```

设计决策：

- 文件路径作为 key，AI Agent 看到路径可直接 Read
- mtime + hash 双保险：mtime 快速判断文件是否改动，hash 精确判断内容是否变化
- calls_file / methods_file 为相对 `.code-compass/` 的路径

#### methods/*.json 格式

```json
{
  "file": "backend/services/employee_service.py",
  "language": "python",
  "mtime": 1745894400,
  "classes": [
    {
      "name": "EmployeeService",
      "methods": [
        {
          "name": "hire",
          "signature": "async def hire(self, office_id: str, role: str) -> Employee",
          "line": 45,
          "docstring": "雇佣新员工到指定办公室"
        }
      ]
    },
    {
      "name": "module_level",
      "methods": [
        {
          "name": "get_service",
          "signature": "def get_service() -> EmployeeService",
          "line": 12,
          "docstring": ""
        }
      ]
    }
  ]
}
```

#### calls/*.json 格式

```json
{
  "file": "backend/services/employee_service.py",
  "mtime": 1745894400,
  "calls": [
    {
      "caller": "EmployeeService.hire",
      "caller_line": 47,
      "callee": "Employee.create",
      "callee_file": "backend/models/schemas.py",
      "confidence": "high"
    },
    {
      "caller": "EmployeeService.hire",
      "caller_line": 50,
      "callee": "notify",
      "callee_file": null,
      "confidence": "low"
    }
  ],
  "called_by": [
    {
      "callee": "EmployeeService.hire",
      "caller": "hire_employee",
      "caller_file": "backend/api/employees.py",
      "caller_line": 23
    }
  ]
}
```

字段说明：

- **calls**：本文件函数调用了谁（出向）
- **called_by**：谁调用了我（入向），构建时预生成
- **confidence**：`high`（明确直接调用）或 `low`（同名匹配但来源不确定）
- **callee_file: null**：被调用函数来源文件无法确定

#### entries.json 格式

```json
{
  "generated_at": "2026-04-30T22:00:00",
  "stale": false,
  "entries": [
    {
      "id": "POST /api/employees/hire",
      "type": "api",
      "framework": "fastapi",
      "file": "backend/api/employees.py",
      "line": 20,
      "handler": "hire_employee",
      "description": "雇佣新员工到指定办公室。创建员工记录，分配AI角色，初始化工作空间，发送欢迎消息。",
      "stale": false,
      "calls": ["EmployeeService.hire", "ChatService.send_welcome"]
    }
  ]
}
```

### 2.2 函数级调用关系图（需求 2）

#### 整体流程

```
Phase A (Grep)          Phase B (Grep)          Phase C (Read)          Phase D (汇总)
构建方法索引    ────▶   构建 import 映射   ────▶  提取调用关系     ────▶  生成逆向索引
methods/*.json          (临时数据)              calls/*.json            called_by 字段
```

Phase A 和 B 用 Grep（低成本），Phase C 需要 AI Read 文件（高成本，逐文件处理）。

#### Phase A — 构建方法索引

复用现有 `/map` 的方法签名提取能力，结果写入 `methods/*.json`。为全局方法清单，供 Phase C 匹配调用目标。

#### Phase B — 构建 import 映射

对每个源码文件 Grep 以下模式，建立 `imported_name → source_file` 映射：

**Python：**

```
Pattern: ^from\s+([\w.]+)\s+import\s+(.+)$
  → { "Employee": "backend/models/schemas.py", ... }

Pattern: ^import\s+([\w.]+)(?:\s+as\s+(\w+))?$
  → { "employee_service": "backend/services/employee_service.py" }
```

**TypeScript：**

```
Pattern: import\s+\{([^}]+)\}\s+from\s+['"](.+)['"]
  → { "EmployeeService": "src/services/employee.service.ts" }

Pattern: import\s+(\w+)\s+from\s+['"](.+)['"]
  → { "axios": "external:axios" }
```

处理规则：

- 相对路径根据当前文件路径解析为项目内绝对路径
- 第三方库标记为 `external:xxx`，不纳入调用关系
- import 映射为临时数据，不单独存文件，在 Phase C 上下文中使用

#### Phase C — 提取调用关系

AI Agent 逐文件 Read 后分析。对每个源码文件：

1. Read 文件全文
2. 识别函数/方法边界
3. 在每个函数体内识别所有函数调用表达式
4. 对每个调用尝试匹配到已知函数定义
5. 判断置信度

调用匹配策略：

| 调用形式 | 匹配策略 | 置信度 |
|----------|----------|--------|
| `self.method()` | 同文件同类中查找 | high |
| `module.func()` | import 映射找到源文件再找 func | high |
| `func()` (裸调用) | 同文件内定义 → import 映射 | high/medium |
| `Class()` (实例化) | 查找 Class 定义所在文件 | high |
| `obj.method()` | callee_file 设为 null | low |
| 动态调用 (getattr 等) | 跳过 | N/A |

**不做 `obj` 类型推断**——复杂度收益比不合理，缺口留给 AI Agent 使用时 Grep 补充。

Python 已知不提取模式：`getattr()`、`callback_map[name]()`、装饰器隐式调用、`super().method()`

TypeScript 已知不提取模式：`Reflect.apply()`、`obj[dynamicKey]()`、`.on('event', handler)`

#### Phase D — 生成逆向索引

扫描所有 `calls/*.json`，对每条 call 记录，在 callee_file 对应的 calls JSON 中追加 called_by 记录。AI Agent 使用时只需读取目标文件的 calls JSON 即可查询"谁调用了我"。

#### 大项目分批处理

Step 4（Phase C）逐文件处理，每个文件 Read → 分析 → 写入 calls JSON → 释放上下文。按目录分批，每批处理完写盘后再处理下一批。

### 2.3 入口点识别与描述生成（需求 3）

#### 装饰器模式库

**Python API 路由：**

```
FastAPI:  @(app|router)\.(get|post|put|delete|patch)\s*\(
Flask:    @(app|bp)\.route\s*\(
Django:   (?:url|path|re_path)\s*\(\s*['"]
```

**Python 定时任务：**

```
Celery:      @app\.task|@shared_task|@celery\.task
APScheduler: @scheduler\.scheduled_job|@periodic_task
通用:        @cron|@schedule|@periodic
```

**Python CLI 命令：**

```
Click: @(click\.command|click\.group)\s*\(
Typer: app\s*=\s*typer\.Typer|@app\.(command|callback)
```

**TypeScript API 路由：**

```
Express:  (app|router)\.(get|post|put|delete|patch)\s*\(
NestJS:   @(Get|Post|Put|Delete|Patch|Controller)\s*\(
Next.js:  pages/api/ 或 app/api/ 目录下的文件（路径即路由）
```

#### 入口识别流程

1. Grep 扫描所有装饰器模式 → 候选入口列表
2. 对每个候选读取 handler 函数签名
3. 从 `calls/{file}.json` 获取 handler 的直接调用列表
4. 组装入口数据 → `entries.json`

#### 描述生成 — 渐进式深度

采用渐进式深度机制，信息充足就停，不够就往下追：

```
对每个入口:
  depth = 1
  loop:
    收集当前 depth 层的函数签名 + docstring
    if 能生成包含至少 2 个业务实体名词的具体摘要:
      break
    if depth >= 3:
      break  (最大深度)
    depth += 1
  
  基于 depth 层内收集的信息，生成 1-2 句中文业务摘要
```

"信息充足"判断标准：

- 至少识别出 2 个业务实体名词（如"员工"、"订单"）
- 能用一句话说清楚"这个入口做了什么业务操作"
- 收集到的都是技术词汇时说明还没追到业务层，继续

#### stale 标记机制

当入口 handler 的 calls 列表发生变化时，标记 `stale = true`，不立即重新生成描述。

刷新时机：

1. 用户主动执行 `/map --refresh`
2. AI Agent 使用数据时检测到 stale=true，先刷新再返回
3. 下次全量 `/map` 执行时自动刷新所有 stale 入口

### 2.4 增量更新机制（需求 4）

#### 整体流程

```
用户执行 /map
       │
       ▼
  manifest.json 存在？
    否 → 全量构建
    是 → 变更检测
       │
       ▼
  mtime 快筛 → hash 精确判断
       │
       ▼
  分类: unchanged / modified / added / deleted
       │
       ▼
  只对 modified + added 执行 Phase A→B→C→D
       │
       ▼
  修正所有 calls/*.json 的 called_by 字段
       │
       ▼
  入口 stale 检测 → 标记但不刷新
       │
       ▼
  更新 manifest.json
```

#### 变更检测

```
Step 1: Bash 获取每个源码文件的 mtime
Step 2: 对比 manifest 中的 mtime
  一致 → unchanged
  不同 → 计算 hash
    hash 一致 → unchanged (只是 touch)
    hash 不同 → modified
不在 manifest 中 → added
在 manifest 中但文件已不存在 → deleted
```

#### 分步增量

**methods/*.json**：只对 modified/added 文件重新提取，deleted 文件删除对应 JSON。

**import 映射**：只对 modified/added 文件重新提取（临时数据）。

**calls/*.json**：只对 modified/added 文件重新分析。完成后需要修正所有文件的 `called_by` 字段（删除已不存在的引用，新增新出现的引用）。

**entries.json**：handler 文件 modified 时检测 calls 列表是否变化，变化则标 stale。added 文件中 grep 新入口，有则追加（description 留空，stale=true）。deleted 文件对应的入口直接移除。

#### 数据流

```
manifest.json ──mtime/hash对比──▶ 源码文件
      │
      ▼ 变更文件列表
   methods/ ◀──覆盖写入── Phase A (Grep)
      │
      ▼
    calls/  ◀──覆盖写入── Phase C (AI Read)
      │
      ▼ called_by 修正
   entries.json ◀──stale检测── 比对调用列表变化
      │
      ▼
   manifest.json ◀──更新mtime/hash── 完成
```

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 存储格式 | 单文件 / 模块化JSON | 模块化JSON | 支持增量更新，AI 按需读取 |
| 调用关系粒度 | 完整调用链 / 二元关系 | 二元关系 | 避免大项目图爆炸，AI 按需跳转 |
| obj 类型推断 | 做 / 不做 | 不做 | 复杂度高收益低，留给 AI 使用时补充 |
| 概念索引 | 独立维护 / 融入入口描述 | 融入入口描述 | 入口天然是概念聚合点，减少维护 |
| 入口描述深度 | 固定一层 / 固定两层 / 渐进式 | 渐进式 | 文档好的项目一层够，文档差的多走几层 |
| 描述更新策略 | 实时 / 最终一致 | 最终一致 | 关系数据实时，描述数据 stale 标记后延迟刷新 |
| Python 调用精度 | 100% / 70-80% 可接受 | 70-80% 可接受 | grep 正则的固有限制，动态调用跳过 |

## 四、风险与应对

| 风险 | 影响 | 应对措施 | 优先级 |
|------|------|----------|--------|
| Python 静态调用提取精度有限（动态特性） | 约 20-30% 的调用无法捕获 | 输出中标注 confidence，AI Agent 使用时可 Grep 补充验证 | P1 |
| 大项目 Phase C Read 文件消耗大量 token | 构建/更新成本高 | 按目录分批处理，增量更新只处理变化文件 | P0 |
| 同名函数导致调用关系误匹配 | called_by 数据有噪音 | callee_file 为 null 或 confidence 为 low 的数据，AI Agent 可交叉验证 | P1 |
| 入口描述 AI 生成可能不准确 | 导航信息有误 | stale 机制允许定期刷新，description 作为辅助参考而非唯一依据 | P2 |

## 五、实现优先级建议

严格按 1 → 2 → 3 → 4 顺序开发（线性依赖）。

## 六、实现步骤清单

### 步骤 1：重写 map.md（需求 1 + 2 + 3 + 4 合并）

code-compass 是纯 Markdown Skill，所有需求最终都落地为 map.md 指令文件的重写。改动清单：

| 文件 | 改动类型 | 说明 |
|------|----------|------|
| `code-compass/references/map/map.md` | 重写 | 核心指令文件，包含全部 4 个需求的执行流程 |
| `code-compass/SKILL.md` | 更新 | 更新功能描述，新增 `/map --refresh` 命令说明 |

### 步骤 2：重写 map.md 的具体章节

map.md 的新结构：

1. **总览与原则** — 语言策略、核心原则（保留现有）
2. **全量构建流程** — Phase A→B→C→D 完整流程
   - Phase A：方法签名提取 → methods/*.json
   - Phase B：import 映射构建
   - Phase C：调用关系提取 → calls/*.json
   - Phase D：逆向索引生成
3. **入口识别与描述生成** — 装饰器模式库 + 渐进式深度描述生成
4. **增量更新流程** — 变更检测 + 分步增量 + stale 管理
5. **数据格式参考** — JSON schema 定义（manifest / methods / calls / entries）
6. **装饰器模式库** — 按语言和框架分类的入口识别模式
7. **输出组装** — overview.md 的生成规则
8. **职责推测参考** — 保留现有目录职责映射表

# 代码索引生成器

你的任务是扫描当前项目的源码目录，生成一份**模块化、函数级**的代码索引系统。索引包含：方法签名、函数调用关系、入口点识别与业务描述。所有数据存储在项目根目录的 `.code-compass/` 下，支持增量更新。

这份索引的核心目标是帮助 AI Agent（和人类开发者）快速建立项目代码的上下文，通过结构化数据精确定位目标文件和函数，评估代码改动的影响范围，减少在理解代码架构和定位目标代码时消耗的 token 和上下文成本。

## 语言策略

所有描述性文本必须使用中文，包括但不限于：目录职责推测、文件职责说明、方法说明、入口描述。方法名、函数签名、参数名等代码相关内容保持原文，不做翻译。

## 核心原则

1. **模块化存储，按需读取**。数据按文件粒度拆分存储，AI Agent 先读 manifest 获取全局索引，再按需读取单个文件的详细数据。
2. **覆盖主流写法，不追求 100%**。方法解析和调用提取基于 grep 正则 + AI Read，能识别大多数常见写法即可。动态调用（反射、getattr 等）无法捕获，属于可接受的遗漏。
3. **二元关系，按需跳转**。调用关系存储为"A 调用 B"的二元对，AI Agent 沿链条自行跳转，不预生成完整调用链。
4. **增量更新，最终一致**。关系数据（方法签名、调用关系）在文件变化后立即更新；AI 生成的入口描述允许 stale 标记后延迟刷新。
5. **大项目要克制**。文件数超过 200 时控制扫描深度，避免 token 溢出。

## 存储结构

```
.code-compass/
├── manifest.json              # 全局索引
├── overview.md                # 目录结构概览（人类可读）
├── methods/                   # 方法签名（每源码文件一个 JSON）
│   └── {path.with.dots}.json
├── calls/                     # 调用关系（每源码文件一个 JSON）
│   └── {path.with.dots}.json
└── entries.json               # 入口点汇总
```

文件路径中的 `/` 替换为 `.` 作为 JSON 文件名。例如 `backend/services/employee_service.py` → `backend.services.employee_service.json`。

## 数据格式定义

### manifest.json

```json
{
  "version": "2.0",
  "generated_at": "生成时间 ISO 8601",
  "project": {
    "name": "项目目录名",
    "type": "项目类型描述",
    "languages": ["语言列表"],
    "entry_point": "入口文件路径"
  },
  "stats": {
    "total_files": 0,
    "total_methods": 0,
    "total_entries": 0
  },
  "files": {
    "relative/path/to/file.py": {
      "language": "python",
      "mtime": 0,
      "hash": "文件内容MD5",
      "methods_count": 0,
      "calls_file": "calls/path.with.dots.json",
      "methods_file": "methods/path.with.dots.json"
    }
  }
}
```

### methods/*.json

```json
{
  "file": "relative/path/to/file.py",
  "language": "python",
  "mtime": 0,
  "classes": [
    {
      "name": "ClassName",
      "methods": [
        {
          "name": "method_name",
          "signature": "完整函数签名",
          "line": 0,
          "docstring": "函数说明（可为空字符串）"
        }
      ]
    },
    {
      "name": "module_level",
      "methods": [
        {
          "name": "func_name",
          "signature": "完整函数签名",
          "line": 0,
          "docstring": ""
        }
      ]
    }
  ]
}
```

`module_level` 是一个虚拟类名，用于存放不属于任何类的模块级函数。

### calls/*.json

```json
{
  "file": "relative/path/to/file.py",
  "mtime": 0,
  "calls": [
    {
      "caller": "ClassName.method_name",
      "caller_line": 0,
      "callee": "target_func_or_method",
      "callee_file": "relative/path/to/callee.py（可为null）",
      "confidence": "high 或 low"
    }
  ],
  "called_by": [
    {
      "callee": "ClassName.method_name",
      "caller": "caller_func",
      "caller_file": "relative/path/to/caller.py",
      "caller_line": 0
    }
  ]
}
```

confidence 说明：
- `high`：明确的直接调用（self.method()、通过 import 确认来源的函数调用）
- `low`：同名匹配但来源不确定（裸函数名调用且无法确认来源文件）

### entries.json

```json
{
  "generated_at": "生成时间 ISO 8601",
  "stale": false,
  "entries": [
    {
      "id": "POST /api/path",
      "type": "api 或 task 或 cli",
      "framework": "fastapi 等",
      "file": "relative/path/to/file.py",
      "line": 0,
      "handler": "handler_function_name",
      "description": "1-2句中文业务摘要",
      "stale": false,
      "calls": ["直接调用的函数列表"]
    }
  ]
}
```

## 全量构建流程

当 `.code-compass/` 目录不存在或 `manifest.json` 不存在时，执行全量构建。

### 第一步：扫描项目根目录

用 Read 工具列出项目根目录的内容，了解大致结构。识别配置文件判断技术栈（参考 `references/project-patterns.md`）。

### 第二步：构建目录树

用 Glob 工具扫描项目目录。**以下目录必须排除**，不要扫描、不要计数：

```
.git, .svn, .hg
node_modules, __pycache__, .venv, venv, env, .env
dist, build, out, target, .next, .nuxt, .output
vendor, Pods, .gradle, .idea, .vscode
coverage, .cache, .tmp, .temp, .tox, .mypy_cache, .pytest_cache
.code-compass
```

具体做法：

1. 先用 Glob `**/*` 拿到所有文件列表
2. 如果返回文件数 > 200，只保留前两层目录下的文件
3. 统计每个目录下的文件数量

### 第三步：按扩展名分组

将扫描到的文件按扩展名分组，识别语言类型：

| 扩展名 | 语言 | 代码文件 |
|--------|------|----------|
| `.ts`, `.tsx`, `.js`, `.jsx` | TypeScript / JavaScript | ✅ |
| `.py` | Python | ✅ |
| `.java` | Java | ✅ |
| `.go` | Go | ✅ |
| `.css`, `.scss`, `.less`, `.sass` | 样式文件 | ❌ |
| `.html`, `.vue`, `.svelte` | 模板文件 | ❌ |
| `.json`, `.yaml`, `.yml`, `.toml`, `.xml` | 配置文件 | ❌ |
| `.md`, `.txt`, `.rst` | 文档文件 | ❌ |
| `.sql` | 数据库脚本 | ❌ |
| `.sh`, `.bat`, `.ps1` | 脚本文件 | ❌ |
| `.png`, `.jpg`, `.svg`, `.ico` | 资源文件 | ❌ |
| 其他 | 未知 | ❌ |

### 第四步（Phase A）：提取方法签名

对每个代码文件，用 Grep 工具搜索函数/方法定义。按语言类型使用对应的搜索 pattern：

#### TypeScript / JavaScript (.ts, .tsx, .js, .jsx)

搜索以下 pattern（每个单独 grep）：

```
Pattern 1: function\s+\w+\s*\(
  匹配：function name( / export function name(
  提取：函数名 + 参数列表

Pattern 2: (?:const|let|var)\s+\w+\s*=\s*(?:async\s+)?\(
  匹配：const name = ( / const name = async (
  提取：变量名 + 参数列表

Pattern 3: (?:public|private|protected|static|async|get|set)?\s*\w+\s*\([^)]*\)\s*\{?
  匹配：class 方法
  提取：方法名 + 参数列表
  注意：排除 if/for/while/switch/catch 等控制语句
```

解读规则：
- 从匹配行提取函数名和参数列表，组合成签名
- 用 Read 工具读取匹配行的上方 1-2 行，如果有 JSDoc（`/** ... */`），提取首行描述
- 没有 JSDoc 则说明留空
- 归入 class 或 module_level

#### Python (.py)

```
Pattern 1: def\s+\w+\s*\(
  匹配：def name( / async def name(
  提取：函数名 + 参数列表（含 self/cls）

Pattern 2: class\s+\w+.*:
  匹配：class ClassName:
  提取：类名
```

解读规则：
- `def` 匹配行直接提取函数签名
- 如果是 `class` 行，记录类名，该类下面的缩进方法归属于此类
- 用 Read 工具读取匹配行下方 1-3 行，如果有 docstring（`"""..."""`），提取首行作为说明

#### Java (.java)

```
Pattern 1: (public|private|protected)\s+(?:static\s+)?(?:[\w<>.,\s\[\]]+)\s+(\w+)\s*\(
  匹配：访问修饰符 方法返回类型 方法名(
  提取：方法名 + 参数列表

Pattern 2: (public|private|protected)\s+(?:static\s+)?\w+\s*\(
  匹配：构造函数

Pattern 3: class\s+\w+
  匹配：类定义
```

解读规则：
- 从匹配行提取完整签名
- 构造函数通过方法名与类名相同判断
- 有 Javadoc（`/**` 开头）时提取首行描述

#### Go (.go)

```
Pattern 1: func\s+\w+\s*\(
  匹配：包级函数

Pattern 2: func\s+\([^)]+\)\s*\w+\s*\(
  匹配：带 receiver 的方法
```

解读规则：
- 从匹配行提取完整签名（含 receiver 和返回值）
- 上方有 `//` 注释行时提取作为说明

**写入结果**：对每个源码文件生成 `methods/{path.with.dots}.json`，格式见上文数据格式定义。

### 第五步（Phase B）：构建 import 映射

对每个源码文件，Grep 提取 import 语句，在上下文中构建临时映射表 `imported_name → source_file`。此数据不单独存文件，仅供 Phase C 使用。

#### Python import 模式

```
Pattern 1: ^from\s+([\w.]+)\s+import\s+(.+)$
  示例: from backend.models.schemas import Employee, Office
  提取: Employee → backend/models/schemas.py, Office → backend/models/schemas.py

Pattern 2: ^import\s+([\w.]+)(?:\s+as\s+(\w+))?$
  示例: import backend.services.employee_service as emp_svc
  提取: emp_svc → backend/services/employee_service.py
```

路径解析规则：
- `.` 分隔的模块路径 → `/` 分隔的文件路径（`backend.models.schemas` → `backend/models/schemas.py`）
- 相对路径（`from .xxx import`）需要根据当前文件所在目录解析

#### TypeScript import 模式

```
Pattern 1: import\s+\{([^}]+)\}\s+from\s+['"](.+)['"]
  示例: import { EmployeeService } from '../services/employee.service'
  提取: EmployeeService → 解析后的项目内路径

Pattern 2: import\s+(\w+)\s+from\s+['"](.+)['"]
  示例: import axios from 'axios'
  提取: axios → external:axios
```

处理规则：
- 相对路径（`../`、`./`）根据当前文件路径解析为项目内路径
- 第三方库（非相对路径、且项目中无对应文件）标记为 `external:xxx`，不纳入调用关系

### 第六步（Phase C）：提取调用关系

对每个源码文件，逐文件 Read 全文后分析调用关系。这是最重的操作，**按目录分批处理**——每个文件处理完后立即写入 JSON 释放上下文，再处理下一个。

对每个文件的流程：

1. Read 文件全文
2. 识别函数/方法边界（Python 用缩进，TS/JS 用花括号层级）
3. 在每个函数体内，识别所有函数调用表达式
4. 对每个调用，尝试匹配到 Phase A 中的已知函数定义
5. 判断置信度

#### 调用匹配策略

| 调用形式 | 匹配方式 | 置信度 |
|----------|----------|--------|
| `self.method()` | 同文件同类中查找 method | high |
| `module.func()` | import 映射找到 module 对应文件，再查找 func | high |
| `func()`（裸调用） | 优先查同文件内定义，再查 import 映射 | high 或 medium |
| `ClassName()`（实例化） | 查找 ClassName 定义所在文件 | high |
| `obj.method()` | callee_file 设为 null | low |

**不做 `obj` 的类型推断**。`obj.method()` 只记录 callee 为 `obj.method`，callee_file 为 null。

#### Python 特殊规则

- `await some_coroutine()` → 和普通调用同等处理
- `db.session.query(...)` → 链式调用只取第一段 `db.session.query`
- `super().method()` → 跳过，不提取
- `getattr(obj, 'method')()` → 跳过，不提取
- `callback_map[name]()` → 跳过，不提取
- 装饰器隐式调用 → 跳过

#### TypeScript 特殊规则

- `this.method()` → 同 class 内查找
- `service.method()` → 通过 import 推断 service 来源（如果能确定）
- `await fetch('/api/...')` → 标记 callee_file 为 `http:POST /api/...`
- `store.dispatch('action')` → 标记 callee 为 `store.dispatch`，callee_file 为 null
- `Reflect.apply()` → 跳过
- `obj[dynamicKey]()` → 跳过
- `.on('event', handler)` → 跳过

**写入结果**：对每个源码文件生成 `calls/{path.with.dots}.json`（此时只填充 `calls` 字段，`called_by` 留空数组）。

### 第七步（Phase D）：生成逆向索引

扫描所有 `calls/*.json` 文件，汇总生成每个文件的 `called_by` 数据：

1. 遍历每个 calls JSON 的 `calls` 数组
2. 对每条 call，如果 `callee_file` 不为 null，找到目标文件的 calls JSON
3. 在目标文件的 `called_by` 数组中追加记录：
   ```json
   {
     "callee": "callee名",
     "caller": "caller名",
     "caller_file": "caller所在文件",
     "caller_line": caller行号
   }
   ```
4. 覆盖写入更新后的 calls JSON

### 第八步：识别入口点

对每个源码文件，Grep 搜索装饰器模式识别入口点。按以下模式库匹配：

#### API 路由

**Python:**

```
FastAPI:  @(app|router)\.(get|post|put|delete|patch)\s*\(
Flask:    @(app|bp)\.route\s*\(
Django:   (?:url|path|re_path)\s*\(\s*['"]
```

**TypeScript:**

```
Express:  (app|router)\.(get|post|put|delete|patch)\s*\(
NestJS:   @(Get|Post|Put|Delete|Patch|Controller)\s*\(
Next.js:  pages/api/ 或 app/api/ 目录下的文件（文件路径即路由路径）
```

#### 定时任务

```
Celery:      @app\.task|@shared_task|@celery\.task
APScheduler: @scheduler\.scheduled_job|@periodic_task
通用:        @cron|@schedule|@periodic
```

#### CLI 命令

```
Click: @(click\.command|click\.group)\s*\(
Typer: app\s*=\s*typer\.Typer|@app\.(command|callback)
```

对识别到的每个入口：

1. 提取 handler 函数名、所在文件、行号
2. 从对应的 `calls/*.json` 获取 handler 的直接调用列表
3. 判断入口类型（`api` / `task` / `cli`）
4. 组装入口数据（此时 description 留空）

### 第九步：生成入口描述

对每个入口点，采用**渐进式深度**生成业务摘要：

```
对每个入口:
  depth = 1
  loop:
    收集当前 depth 层的函数签名 + docstring
    if 能生成包含至少 2 个业务实体名词的具体摘要:
      break
    if depth >= 3:
      break
    depth += 1

  基于 depth 层内收集的信息，生成 1-2 句中文业务摘要
```

具体流程：

1. Read handler 函数所在文件，定位 handler 函数体
2. 从 `calls/*.json` 获取 handler 的直接调用列表
3. 对每个被调用函数，从对应 `methods/*.json` 获取签名和 docstring
4. 基于 handler 源码 + 被调用函数信息，生成摘要
5. 如果信息不足（都是技术词汇如"连接"、"查询"、"序列化"），从被调用函数的调用列表继续展开一层（depth=2），重复直到信息充足或达到最大深度

摘要要求：
- 用中文描述
- 聚焦业务意图，不描述技术细节
- 包含关键实体名称（如"员工"、"办公室"、"角色"）
- 控制在 1-2 句话

**写入结果**：生成 `entries.json`，格式见上文数据格式定义。

### 第十步：生成 overview.md

生成一份人类可读的目录结构概览。格式如下：

```markdown
# 项目代码全景图

> 生成时间：{当前日期时间}
> 项目：{项目目录名} | 源码文件：{总数} | 方法/函数：{总数}

## 目录结构

{project_name}/
├── {dir1}/           # {职责推测} ({file_count} files, {method_count} methods)
│   ├── {subdir1}/    # {职责推测} ({file_count} files)
│   └── {subdir2}/    # {职责推测} ({file_count} files)
├── {dir2}/           # {职责推测} ({file_count} files)
└── {dir3}/           # {职责推测} ({file_count} files)

---

## 入口点

| 入口 | 类型 | 文件 | 描述 |
|------|------|------|------|
| POST /api/employees/hire | api | backend/api/employees.py | 雇佣新员工... |
| cleanup_expired_sessions | task | backend/tasks/cleanup.py | 清理过期会话... |
```

目录树中的职责说明基于目录名推测（参考文末职责推测参考表）。

大型项目（文件数 > 200）时：
1. 目录树只展示前两层，第三层起合并为 `... (N subdirs)`
2. 文件末尾追加：`> ⚠️ 大型项目，仅展示前两层结构。共 {total} 个源码文件。`

### 第十一步：生成 manifest.json

汇总所有数据，生成 `manifest.json`：

1. 统计 total_files、total_methods、total_entries
2. 为每个源码文件记录 mtime、hash（MD5）、language、methods_count
3. 计算 hash 的方法：用 Bash 执行 `certutil -hashfile {file} MD5`（Windows）或 `md5sum {file}`（Linux/Mac）

### 第十二步：写入文件

确保 `.code-compass/` 目录存在（Bash: `mkdir .code-compass`，如需子目录 `mkdir .code-compass\methods` 和 `mkdir .code-compass\calls`），然后将所有数据写入对应文件。

写入完成后，在对话中提示用户：建议将 `.code-compass/` 加入 `.gitignore`。

## 增量更新流程

当 `.code-compass/manifest.json` 已存在时，执行增量更新。

### 变更检测

1. 读取 manifest.json 获取文件列表和 mtime
2. 用 Bash 获取每个源码文件的当前 mtime：
   - Windows: `(Get-Item '{file}').LastWriteTimeUtc.Ticks`
   - Linux/Mac: `stat -c '%Y' '{file}'`
3. 对比 mtime：
   - mtime 一致 → `unchanged`，跳过
   - mtime 不同 → 计算文件 hash（MD5），hash 一致也标记为 `unchanged`
   - hash 不同 → `modified`
   - 文件在 manifest 中但磁盘上不存在 → `deleted`
   - 文件在磁盘上但不在 manifest 中 → `added`

### 分步增量

**Phase A 增量（methods/*.json）：**

- `modified` / `added` 文件：重新提取方法签名，覆盖写入 JSON
- `deleted` 文件：删除对应的 methods JSON

**Phase B 增量（import 映射）：**

- 只对 modified / added 文件重新提取 import 映射（临时数据）

**Phase C 增量（calls/*.json）：**

- `modified` / `added` 文件：Read 文件重新分析调用关系，覆盖写入 JSON
- `deleted` 文件：删除对应的 calls JSON

**Phase D 增量（逆向索引修正）：**

1. 收集 modified / added / deleted 文件的旧调用数据（从变更前的 calls JSON）
2. 对所有 `calls/*.json` 的 `called_by` 字段做修正：
   - 删除引用了 deleted 文件函数的 called_by 记录
   - 删除 modified 文件中已不存在的旧调用对应的 called_by 记录
   - 新增 modified / added 文件中新出现的调用对应的 called_by 记录

**入口 stale 检测：**

1. 读取 entries.json
2. 对每个入口：
   - handler 所在文件为 `deleted` → 从 entries.json 移除该入口
   - handler 所在文件为 `modified` → 从新 calls JSON 获取 handler 的 calls 列表，与 entries.json 中的 calls 对比，不同则标记 `stale: true`
3. 对 `added` 文件 grep 装饰器模式，发现新入口 → 追加到 entries.json，description 留空，`stale: true`

### 更新 manifest.json

更新所有变化文件的 mtime 和 hash，更新 stats 统计数据。

### Stale 描述刷新

增量更新**不自动刷新** stale 的入口描述。描述在以下时机刷新：

1. 用户执行 `/map --refresh` 时：对所有 `stale: true` 的入口重新生成描述
2. AI Agent 使用 entries.json 时发现 `stale: true`：先刷新该入口描述再返回数据

刷新逻辑与全量构建的第九步相同（渐进式深度）。

## `/map --refresh` 命令

当用户执行 `/map --refresh` 时：

1. 读取 entries.json
2. 找出所有 `stale: true` 的入口
3. 对每个 stale 入口执行渐进式深度描述生成（同第九步）
4. 更新 entries.json（stale 改为 false，更新 description）
5. 汇报刷新了多少个入口描述

## 职责推测参考

根据常见的目录命名推测职责：

| 目录名 | 推测职责 |
|--------|----------|
| `src` | 主要源码 |
| `lib` | 库代码 |
| `app` | 应用主代码 |
| `api` | API 接口定义 |
| `routes` | 路由定义 |
| `controllers` | 请求处理/控制器 |
| `models` | 数据模型 |
| `views` | 视图/页面渲染 |
| `services` | 业务逻辑/服务层 |
| `middleware` | 中间件 |
| `utils` / `helpers` / `lib` | 工具函数 |
| `components` | UI 组件 |
| `pages` | 页面 |
| `config` / `conf` | 配置文件 |
| `tests` / `test` / `spec` / `__tests__` | 测试文件 |
| `scripts` | 脚本 |
| `docs` | 文档 |
| `types` / `interfaces` | 类型定义 |
| `constants` | 常量定义 |
| `handlers` | 事件/请求处理器 |
| `store` / `stores` | 状态管理 |
| `hooks` | 自定义 Hooks |
| `styles` | 样式文件 |
| `assets` / `static` / `public` | 静态资源 |
| `migrations` | 数据库迁移 |
| `seeders` | 数据库种子 |
| `entities` | 实体类 |
| `repositories` | 数据访问层 |
| `dto` | 数据传输对象 |
| `validators` | 数据校验 |
| `exceptions` / `errors` | 异常定义 |
| `listeners` | 事件监听器 |
| `providers` | 服务提供者 |
| `commands` | 命令定义 |
| `queries` | 查询定义 |
| `workers` | 后台任务 |
| `channels` | 通道/消息处理 |
| `policies` | 权限策略 |
| `rules` | 业务规则 |
| `events` | 事件定义 |
| `notifications` | 通知 |
| `jobs` | 异步任务 |
| `mail` | 邮件 |
| `exports` | 导出 |
| `imports` | 导入 |
| `resources` | 资源转换 |
| `presenters` | 展示层 |
| `serializers` | 序列化 |
| `forms` | 表单 |
| `tasks` | 任务定义 |
| `decorators` | 装饰器 |
| `filters` | 过滤器 |
| `middlewares` | 中间件 |
| `guards` | 守卫 |
| `interceptors` | 拦截器 |
| `pipes` | 管道 |
| `adapters` | 适配器 |
| `factories` | 工厂 |
| `strategies` | 策略 |
| `observers` | 观察者 |
| `subscribers` | 订阅者 |
| `publishers` | 发布者 |
| `consumers` | 消费者 |
| `producers` | 生产者 |

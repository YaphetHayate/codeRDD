# 代码索引生成器（v3.0 — 脚本+AI 协作版）

你的任务是构建项目的**模块化、函数级**代码索引系统。索引包含：方法签名、函数调用关系、入口点识别与业务描述。所有数据存储在项目根目录的 `.code-compass/` 下，支持增量更新。

这份索引的核心目标是帮助 AI Agent（和人类开发者）快速建立项目代码的上下文，通过结构化数据精确定位目标文件和函数，评估代码改动的影响范围，减少在理解代码架构和定位目标代码时消耗的 token 和上下文成本。

## 语言策略

所有描述性文本必须使用中文，包括但不限于：目录职责推测、文件职责说明、方法说明、入口描述。方法名、函数签名、参数名等代码相关内容保持原文，不做翻译。

## 核心原则

1. **脚本与 AI 各司其职**。确定性工作（正则提取）由 Python 脚本完成，需要理解能力的工作（调用推断、描述生成）由 AI 完成。
2. **模块化存储，按需读取**。数据按文件粒度拆分存储，AI Agent 先读 manifest 获取全局索引，再按需读取单个文件的详细数据。
3. **覆盖主流写法，不追求 100%**。方法解析和调用提取基于正则，能识别大多数常见写法即可。动态调用（反射、getattr 等）无法捕获，属于可接受的遗漏。
4. **二元关系，按需跳转**。调用关系存储为"A 调用 B"的二元对，AI Agent 沿链条自行跳转，不预生成完整调用链。
5. **增量更新，最终一致**。关系数据（方法签名、调用关系）在文件变化后立即更新；AI 生成的入口描述允许 stale 标记后延迟刷新。
6. **大项目要克制**。文件数超过 200 时控制扫描深度，避免 token 溢出。

## 存储结构

```
.code-compass/
├── manifest.json              # 全局索引
├── overview.md                # 目录结构概览（人类可读）
├── methods/                   # 方法签名（每源码文件一个 JSON）
│   └── {path.with.dots}.json
├── calls/                     # 调用关系（每源码文件一个 JSON）
│   └── {path.with.dots}.json
├── entries.json               # 入口点汇总
└── pending.json               # 待 AI 处理的事项
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

### pending.json

```json
{
  "generated_at": "生成时间 ISO 8601",
  "summary": {
    "total_unresolved_calls": 0,
    "total_entries_without_description": 0
  },
  "unresolved_calls": [
    {
      "file": "relative/path/to/file.py",
      "caller": "ClassName.method",
      "caller_line": 0,
      "callee": "bare_func_name",
      "confidence": "low",
      "hint": "无法确定调用目标来源文件"
    }
  ],
  "entries_without_description": [
    {
      "id": "POST /api/path",
      "type": "api",
      "file": "relative/path/to/file.py",
      "handler": "handler_name",
      "stale": false
    }
  ]
}
```

## 构建流程

### 第一步：运行构建脚本

用 Bash 工具执行以下命令：

```bash
python "{脚本路径}/scripts/build_index.py" {项目路径}
```

**脚本路径的定位方法**：本文件（map.md）位于 `code-compass/references/map/map.md`，脚本位于 `code-compass/scripts/build_index.py`。从本文件向上两级再进入 scripts 目录即为脚本路径。

如果无法确定脚本路径，可用 Glob 工具搜索 `**/build_index.py` 定位。

脚本会自动完成：
- 文件扫描与语言识别（Python、TypeScript/JavaScript、Java、Go）
- Phase A：方法签名提取
- Phase B：import 映射构建
- Phase C：高置信度调用关系提取
- Phase D：逆向索引（called_by）生成
- 入口点识别（API 路由、定时任务、CLI 命令）
- manifest.json、overview.md、entries.json、pending.json 生成

脚本自动检测构建模式：
- `.code-compass/manifest.json` 不存在 → 全量构建
- `.code-compass/manifest.json` 已存在 → 增量更新（仅处理变化的文件）

### 第二步：检查待处理项

读取 `.code-compass/pending.json`，判断是否需要 AI 补充：

- `unresolved_calls` 不为空 → 需要补充调用推断，进入第三步
- `entries_without_description` 不为空 → 需要生成入口描述，进入第四步
- 两者都为空 → 构建完成，提示用户建议将 `.code-compass/` 加入 `.gitignore`

### 第三步：AI 补充复杂调用关系 + 噪声过滤

#### 3a. 噪声过滤

脚本已内置 SKIP_METHOD_NAMES 过滤常见的 `obj.method()` 噪声（如 `xxx.split()`、`xxx.append()` 等）。如果 `pending.json` 中仍有大量明显是内置方法调用的噪声（callee 是 `xxx.yyy()` 形式且 `yyy` 是通用方法名如 `get`、`format`），生成 `.code-compass/filters.json` 供后续构建使用：

```json
{
  "skip_methods": ["方法名1", "方法名2"]
}
```

规则：
- 只添加确信是内置方法的名字，宁可有少量噪声也不要误杀项目自定义方法
- 脚本下次运行时自动加载此文件，合并到内置过滤列表
- 如果 `.code-compass/filters.json` 不存在则只使用内置列表

#### 3b. 补充调用推断

对 `pending.json` 中剩余的 `unresolved_calls`（过滤噪声后）：

对 `pending.json` 中每条 `unresolved_calls`：

1. Read 调用者源文件，定位 `caller_line` 附近的代码（上下文 5-10 行）
2. 根据文件中的 import 语句和上下文语义，推断 `callee` 的来源文件
3. 如果能确定来源，更新 `.code-compass/calls/{file}.json` 中对应记录：
   - 补充 `callee_file` 字段
   - 将 `confidence` 改为 `high`
4. 同步更新目标文件的 `called_by` 数组
5. 从 `pending.json` 的 `unresolved_calls` 中移除已处理的条目

完成所有推断后，覆写 `pending.json`。

注意：如果推断不确定，保持 `confidence: low` 不修改，不要强行赋值。

### 第四步：AI 生成入口描述

对 `pending.json` 中每条 `entries_without_description`，采用**渐进式深度**生成业务摘要：

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
2. 从 `.code-compass/calls/{file}.json` 获取 handler 的直接调用列表
3. 对每个被调用函数，从 `.code-compass/methods/{file}.json` 获取签名和 docstring
4. 基于 handler 源码 + 被调用函数信息，生成摘要
5. 如果信息不足（都是技术词汇如"连接"、"查询"、"序列化"），从被调用函数的调用列表继续展开一层（depth=2），重复直到信息充足或达到最大深度

摘要要求：
- 用中文描述
- 聚焦业务意图，不描述技术细节
- 包含关键实体名称（如"员工"、"办公室"、"角色"）
- 控制在 1-2 句话

完成后：
1. 更新 `.code-compass/entries.json` 中对应入口的 `description` 和 `stale` 字段（stale 改为 false）
2. 从 `pending.json` 的 `entries_without_description` 中移除已处理的条目
3. 覆写两个 JSON 文件

## 增量更新流程

增量更新由脚本自动处理。AI 只需在脚本执行后检查 `pending.json`，执行第三步和第四步的补充工作。

脚本的增量逻辑：
- 通过 mtime + MD5 hash 检测文件变更（新增、修改、删除）
- 仅重新处理变化的文件
- 自动修正逆向索引（called_by）
- 自动检测入口点 stale 状态
- 自动发现新增入口点

## `/map --refresh` 命令

当用户执行 `/map --refresh` 时：

1. 用 Bash 执行：`python "{脚本路径}/scripts/build_index.py" {项目路径} --refresh`
2. 脚本会将所有入口标记为 `stale: true`
3. AI 执行第四步，为所有 stale 入口重新生成描述

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

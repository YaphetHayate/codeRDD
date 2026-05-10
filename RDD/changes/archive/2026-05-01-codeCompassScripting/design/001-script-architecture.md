---
requirement_id: 需求1+2+3
priority: 高
depends_on: []
blocks:
  - 需求4+5
analysis_date: 2026-05-01
status: confirmed
tech_stack:
  - Python 3
  - regex (re 标准库)
estimated_effort: 中 (3-5天)
---

# 确定性索引构建脚本 + 未解决项报告 + 增量更新 — 设计文档

## 一、需求概述

将 code-compass `/map` 命令中所有确定性的索引构建工作（方法签名提取、import 映射、高置信度调用关系、逆向索引、入口识别、manifest/overview 生成）交给 Python 脚本执行，脚本完成后输出 pending.json 告知 AI 哪些工作需要补充。同时支持增量更新模式。

## 二、技术方案

### 2.1 技术选型

纯正则方案（regex only）。使用 Python 标准 `re` 模块，直接翻译 map.md 中已定义的 pattern。不引入 tree-sitter 等外部依赖。

选型理由：
- map.md 原文明确"覆盖主流写法，不追求 100%"，regex 满足此定位
- Phase C 复杂场景已有 AI 兜底，脚本只做高置信度部分
- 零依赖，即装即用

### 2.2 模块归属

新增 `code-compass/scripts/` 目录，不改动任何现有文件。

```
code-compass/scripts/
├── build_index.py          # 入口：CLI 参数解析、流程编排
├── parsers/
│   ├── __init__.py          # 注册表：LANGUAGE_MAP = {'.py': PythonParser, ...}
│   ├── base.py              # BaseParser 接口
│   ├── python.py            # Python 解析器
│   ├── typescript.py        # TypeScript/JavaScript 解析器
│   ├── java.py              # Java 解析器
│   └── golang.py            # Go 解析器
├── extractors.py            # 方法/import/调用/入口提取（调用 parsers）
├── generators.py            # manifest、overview、reverse index、pending 生成
├── incremental.py           # 变更检测 + 增量更新逻辑
└── constants.py             # 排除目录、扩展名映射、装饰器 pattern 库
```

### 2.3 核心流程

#### 全量构建

```
文件扫描 ──▶ [file_list: [{path, language, mtime, hash}]]
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
  Phase A    Phase B    写入
  方法签名   import映射   methods/*.json
    │           │
    ▼           ▼
  Phase C: 调用关系提取
  (利用 methods + imports 确认高置信度调用)
    │
    ▼
  Phase D: 逆向索引 (called_by)
    │
    ├──▶ manifest.json
    ├──▶ overview.md
    ├──▶ entries.json (description 留空)
    └──▶ pending.json
```

#### 增量更新

```
读取 manifest.json (旧)
       │
       ▼
扫描文件系统 (新 mtime)
       │
       ▼
┌──────────────────────────────┐
│  三态分类：                    │
│  unchanged: mtime一致 or hash │
│  modified: hash 不同          │
│  added: 新文件                │
│  deleted: 旧文件不存在        │
└──────────────┬───────────────┘
               │
  ┌────────────┼────────────┐
  ▼            ▼            ▼
跳过      重新提取A/B/C   清理旧JSON
              │
              ▼
修正逆向索引 (called_by):
  1. 删除引用已删除文件的 called_by
  2. 删除旧调用对应的 called_by
  3. 添加新调用对应的 called_by
              │
              ▼
入口 stale 检测:
  - handler 文件 deleted → 移除入口
  - handler 文件 modified → 对比 calls, 不同则 stale=true
  - 新文件有装饰器 → 新增入口, stale=true
              │
              ▼
更新 manifest + 重生成 overview + 更新 pending
```

### 2.4 接口设计

#### parsers/base.py — 解析器接口

```python
class BaseParser:
    def extract_methods(self, content: str, filepath: str) -> dict:
        """返回 methods/*.json 格式的 dict"""

    def extract_imports(self, content: str, filepath: str) -> dict:
        """返回 {imported_name: source_file_path} 映射"""

    def extract_calls(self, content: str, filepath: str,
                      import_map: dict, known_methods: dict) -> list:
        """返回 calls 数组，每项含 caller/callee/callee_file/confidence"""

    def detect_entries(self, content: str, filepath: str) -> list:
        """返回入口点列表"""
```

#### parsers/__init__.py — 注册表

```python
from .python import PythonParser
from .typescript import TypeScriptParser
from .java import JavaParser
from .golang import GoParser

LANGUAGE_MAP = {
    '.py': PythonParser,
    '.ts': TypeScriptParser, '.tsx': TypeScriptParser,
    '.js': TypeScriptParser, '.jsx': TypeScriptParser,
    '.java': JavaParser,
    '.go': GoParser,
}

def get_parser(filepath: str) -> BaseParser | None:
    ext = Path(filepath).suffix
    cls = LANGUAGE_MAP.get(ext)
    return cls() if cls else None
```

#### build_index.py — CLI 入口

```
用法: python build_index.py [project_path] [--refresh]

参数:
  project_path    项目根目录，默认当前目录
  --refresh       刷新所有 stale 入口（配合 /map --refresh 使用）

自动检测:
  .code-compass/manifest.json 不存在 → 全量构建
  .code-compass/manifest.json 存在   → 增量更新
```

### 2.5 Phase C 调用置信度策略

| 调用形式 | 脚本处理 | 置信度 |
|----------|----------|--------|
| `self.method()` | 同文件同类中查找 | high |
| `cls.method()` | 同文件同类中查找 | high |
| `imported.func()` | import 映射确认来源 | high |
| `ClassName()` | import 映射确认来源 | high |
| `bare_func()` 同文件内定义 | 同文件查找 | high |
| `bare_func()` 跨文件 | 无法确认来源 | low → 交 AI |
| `obj.method()` | 无法推断 obj 类型 | low → 交 AI |
| 链式调用 `a.b.c()` | 无法追踪中间类型 | low → 交 AI |
| `getattr()` 等动态调用 | 直接跳过 | — |

### 2.6 pending.json 格式

```json
{
  "generated_at": "2026-05-01T12:00:00",
  "summary": {
    "total_unresolved_calls": 0,
    "total_entries_without_description": 0
  },
  "unresolved_calls": [
    {
      "file": "backend/services/employee_service.py",
      "caller": "EmployeeService.hire",
      "caller_line": 42,
      "callee": "send_notification",
      "confidence": "low",
      "hint": "裸函数名调用，未在 import 映射或同文件中找到定义"
    }
  ],
  "entries_without_description": [
    {
      "id": "POST /api/employees/hire",
      "type": "api",
      "file": "backend/api/employees.py",
      "handler": "hire_employee",
      "stale": false
    }
  ]
}
```

### 2.7 constants.py 配置

```python
EXCLUDE_DIRS = {
    '.git', '.svn', '.hg',
    'node_modules', '__pycache__', '.venv', 'venv', 'env', '.env',
    'dist', 'build', 'out', 'target', '.next', '.nuxt', '.output',
    'vendor', 'Pods', '.gradle', '.idea', '.vscode',
    'coverage', '.cache', '.tmp', '.temp', '.tox', '.mypy_cache', '.pytest_cache',
    '.code-compass',
}

CODE_EXTENSIONS = {
    '.py': 'python',
    '.ts': 'typescript', '.tsx': 'typescript',
    '.js': 'javascript', '.jsx': 'javascript',
    '.java': 'java',
    '.go': 'go',
}
```

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 解析引擎 | regex / tree-sitter | regex | 零依赖、与 map.md pattern 一一对应、精度不足由 AI 兜底 |
| 语言解析器组织 | 单文件 / 目录 | 目录 | 隔离性更好，新增语言只需加文件 |

## 四、风险与应对

| 风险 | 影响 | 应对措施 | 优先级 |
|------|------|----------|--------|
| Java/Go 复杂语法 regex 精度有限 | 部分方法签名或调用关系遗漏 | 低置信度的统一交 AI 补充；标注为 P1 持续优化 | P1 |
| Python 缩进层级跟踪 | 方法归属 class 判定可能出错 | 用行首空格计数跟踪缩进层级 | P1 |

## 五、实现优先级建议

在整体需求序列中最先开发，是需求 4+5（map.md 改写）的前置依赖。

## 六、实现步骤清单

1. 创建 `code-compass/scripts/` 目录结构
2. 实现 `constants.py` — 排除目录、扩展名映射
3. 实现 `parsers/base.py` — BaseParser 接口
4. 实现 `parsers/python.py` — Python 解析器
5. 实现 `parsers/typescript.py` — TS/JS 解析器
6. 实现 `parsers/java.py` — Java 解析器
7. 实现 `parsers/golang.py` — Go 解析器
8. 实现 `parsers/__init__.py` — 注册表
9. 实现 `extractors.py` — 提取逻辑编排
10. 实现 `generators.py` — manifest/overview/reverse_index/pending 生成
11. 实现 `incremental.py` — 变更检测 + 增量更新
12. 实现 `build_index.py` — CLI 入口 + 流程编排
13. 用一个小型项目测试全量构建和增量更新

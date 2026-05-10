# Pending.json 噪声过滤优化

## 背景

code-compass 脚本构建的 pending.json 中 87% 的 unresolved_calls 是噪声（主要是 `obj.builtin_method()` 模式），导致 AI 在补充调用关系时需要从大量无用条目中筛选真正有价值的项。需要通过内置过滤 + 项目级自适应配置降低噪声。

## 需求列表

### 需求 1：内置 obj.method() 噪声过滤

- **描述**：在 parsers 中新增 SKIP_METHOD_NAMES 集合，对 `obj.method()` 形式的调用，如果 method 部分匹配到内置方法名（如 `get`、`append`、`split`、`group` 等），则直接跳过不纳入调用关系
- **验收标准**：
  - 新增 SKIP_METHOD_NAMES 集合，覆盖 Python/TS/Java/Go 常见的对象内置方法（至少 50 个）
  - `content.split()`、`m.group()`、`result.append()` 等调用不再出现在 calls/*.json 和 pending.json 中
  - 过滤后 pending.json 的 unresolved_calls 从 ~638 条降至 ~100 条以内
- **优先级**：高
- **影响范围**：4 个语言 parser 的 extract_calls 方法
- **边界与异常**：如果 method 名恰好与项目自定义方法同名（如项目定义了一个 `get` 方法），内置过滤会误跳。通过需求 2 的项目级白名单机制可以补救

### 需求 2：项目级过滤配置支持

- **描述**：脚本支持从 `.code-compass/filters.json` 加载项目级的过滤规则，扩展或覆盖内置过滤列表。首次构建时不存在此文件则使用内置列表
- **验收标准**：
  - `.code-compass/filters.json` 不存在时，脚本正常运行（使用内置过滤）
  - `.code-compass/filters.json` 存在时，脚本加载其中的 skip_methods 列表，合并到内置过滤
  - filters.json 格式为 JSON，包含 `skip_methods` 字段（方法名字符串数组）
  - 脚本在 overview 或 manifest 中不暴露 filters.json（它是内部优化配置）
- **优先级**：中
- **影响范围**：parsers 的 extract_calls 方法、constants.py

### 需求 3：AI 自动生成过滤配置

- **描述**：在 map.md 的 AI 补充流程中，增加"AI 检查 pending.json 噪声并生成 filters.json"的步骤。AI 识别出明显是噪声的 callee 模式后，写入 filters.json 供后续构建使用
- **验收标准**：
  - map.md 第三步（AI 补充复杂调用）中增加噪声过滤环节
  - AI 能识别 pending.json 中高频出现的内置方法模式，生成 skip_methods 列表
  - 生成的 filters.json 格式正确，脚本下次运行时能正确加载
- **优先级**：中
- **影响范围**：map.md、AI 补充流程
- **依赖关系**：依赖需求 2

### 需求 4：修复 Parser 误解析 bug

- **描述**：修复 RE_CALL 正则将 `except` 和 `in` 关键字误识别为函数调用的问题（共 18 条误报）
- **验收标准**：
  - `except Exception as e:` 不再产生调用记录
  - `if x in y:` 不再产生调用记录
  - 修复后 pending.json 中不再出现 callee 为 `except` 或 `in` 的条目
- **优先级**：高
- **影响范围**：parsers/python.py 的 RE_CALL 正则

## 关键约束

- filters.json 是可选的，不创建时脚本行为与当前一致（只使用内置过滤）
- 内置过滤列表应该保守——只加入确信是内置方法的名字，宁可有少量噪声也不要误杀

## 讨论记录

- 87% 噪声中 71% 是 obj.method() 内置方法，13.6% 是裸函数名遗漏
- 用户倾向可演进机制而非纯静态列表
- 过滤配置存放在 .code-compass/filters.json，随索引一起维护
- AI 在补充 pending.json 时自动生成过滤规则，不需单独命令

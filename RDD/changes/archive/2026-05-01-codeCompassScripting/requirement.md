# Code Compass 索引构建脚本化

## 背景

code-compass 的 `/map` 命令目前完全依赖 AI Agent 逐文件执行 grep/read/write 来构建代码索引。这些操作中大部分是确定性的模式匹配（正则提取方法签名、import 解析、调用关系拼接），只有入口描述生成等少数环节真正需要 AI 的理解能力。通过将确定性工作交给 Python 脚本执行，可以大幅减少 token 消耗和构建时间，同时提高结果的一致性。

## 需求列表

### 需求 1：确定性索引构建脚本

- **描述**：开发一个 Python 脚本，承担 `/map` 流程中所有确定性环节的构建工作，包括方法签名提取、import 映射、高置信度调用关系提取、逆向索引生成、入口点识别、manifest 和 overview 生成
- **验收标准**：
  - 执行脚本后，`.code-compass/` 目录下生成与现有格式完全一致的 manifest.json、overview.md、methods/*.json、calls/*.json、entries.json（description 字段留空）
  - 支持 Python、TypeScript/JavaScript、Java、Go 四种语言的代码文件解析
  - 高置信度调用（self.method()、import 确认来源的调用）被正确提取；无法确认的调用标记为 low confidence 并列入未解决报告
  - 脚本运行时间对中小型项目（50-200 源文件）在秒级完成
- **优先级**：高
- **影响范围**：code-compass skill 的 references/map/map.md，新增脚本文件
- **边界与异常**：
  - 非 Python/TS/JS/Java/Go 的代码文件跳过，不报错
  - 脚本在无源码文件的项目中优雅退出并提示
  - 排除目录列表与 map.md 定义一致（node_modules, __pycache__, .git 等）

### 需求 2：脚本未解决项的报告输出

- **描述**：脚本执行完成后，输出一份结构化报告，告知 AI Agent 哪些工作需要它补充处理，包括未解决的调用关系和需要生成描述的入口点
- **验收标准**：
  - 报告列出所有 low confidence 调用的文件和位置，供 AI 补充推断
  - 报告列出所有已识别但缺少 description 的入口点
  - 报告格式为 JSON，AI 可直接读取解析
- **优先级**：高
- **影响范围**：新增报告文件（如 `.code-compass/pending.json`）

### 需求 3：增量更新支持

- **描述**：脚本支持增量更新模式，当 `.code-compass/manifest.json` 已存在时，仅重新处理变化的文件（新增、修改、删除），而非全量重建
- **验收标准**：
  - 通过 mtime + MD5 hash 检测文件变更，变更检测结果与现有 map.md 定义一致
  - 修改/新增的文件重新执行 Phase A/B/C/D 并覆盖对应 JSON
  - 删除的文件清理对应的 methods/*.json 和 calls/*.json
  - 逆向索引（called_by）在增量更新后正确修正
  - 入口 stale 检测逻辑与现有 map.md 定义一致
  - 未变化的文件跳过处理
- **优先级**：高
- **依赖关系**：依赖需求 1

### 需求 4：更新 map.md 工作流指引

- **描述**：更新 references/map/map.md，将现有的纯 AI 执行流程改为 AI+脚本协作流程，让 AI Agent 知道何时调用脚本、何时自行处理
- **验收标准**：
  - map.md 中明确标注哪些环节由脚本处理、哪些由 AI 处理
  - AI Agent 读取更新后的 map.md 后能正确执行协作流程（先调脚本，再补充）
  - 保留现有数据格式定义不变，确保向后兼容
- **优先级**：高
- **依赖关系**：依赖需求 1、2

### 需求 5：AI 补充处理流程

- **描述**：在 map.md 中定义 AI 拿到脚本报告后的补充处理流程，包括复杂调用关系推断和入口描述生成
- **验收标准**：
  - AI 能基于 pending.json 中的信息，逐文件读取源码补充复杂调用推断
  - 入口描述生成沿用现有渐进式深度逻辑
  - 补充完成后更新对应的 JSON 文件，并从 pending.json 中移除已处理项
- **优先级**：中
- **依赖关系**：依赖需求 2、4

## 关键约束

- 生成的 JSON 数据格式必须与现有定义完全一致，不破坏已有消费者（overview.md、entries.json 的读取方）
- 脚本仅使用 Python 标准库 + 常见轻量依赖（如 tree-sitter 如果需要更精确的 AST 解析），不引入重量级框架
- 脚本在 Windows 和 Linux/Mac 上均可运行
- 不强行脚本化不可靠的环节——复杂调用推断宁可交给 AI

## 讨论记录

- Phase C（调用关系）是可靠性最差的环节，决定脚本做高置信度部分，低置信度的交给 AI 补充
- 语言支持范围确定为全部四种（Python、TS/JS、Java、Go）
- 增量更新同步支持，不延后
- AI Agent 仍为流程主导者，脚本是被调用的工具

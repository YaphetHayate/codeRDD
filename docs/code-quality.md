# 代码质量规范

> 本文档由 RDD-PSE 根据项目实际代码风格生成，随项目演进持续维护。
> 所有 Agent（primary + subagent）在生成代码时都须遵守以下约束。

---

## 1. 可读性优先

代码首先是给人读的，其次才是给机器执行。

- **避免隐式意图**：复杂的条件判断拆分为具名中间变量，不把多步计算塞进一行
- **减少认知负担**：单个函数不超过 40 行（不含注释），超过则拆分
- **避免深层嵌套**：if/for/while 嵌套不超过 3 层，超出用提前 return 或提取子函数
- **公共逻辑必须抽取**：同一段逻辑出现 2 次以上，必须抽取为独立函数
- **注释写"为什么"**：不写"做了什么"（代码自己会说话），写"为什么这样做"

## 2. 命名规范

### 通用规则

- 名称必须语义化，禁止无意义缩写（`a`、`b`、`tmp`、`obj`、`data`、`item`）
- 名称长度与作用域成正比：全局/模块级命名应详尽，循环变量可略短
- 布尔值以 `is`/`has`/`should`/`can` 开头
- 集合变量用复数或 `List`/`Map` 后缀
- 避免拼音、避免双关语、避免无上下文的单字母

### 按类型

| 类型 | 规范 | 示例 |
|------|------|------|
| 文件名 | 与默认导出保持一致 | `UserService.ts`、`use-auth.ts` |
| 类/接口/类型 | PascalCase | `UserProfile`、`OrderStatus` |
| 函数/方法 | camelCase，动词开头 | `fetchUserById`、`validateEmail` |
| 变量 | camelCase，名词/形容词 | `userName`、`isLoading` |
| 常量 | UPPER_SNAKE_CASE | `MAX_RETRY_COUNT`、`API_BASE_URL` |
| 事件处理函数 | `handle` + 事件名 | `handleSubmit`、`handleKeyDown` |
| Hook/Callback | 以具体行为命名 | `onUserSelect`、`beforeSave` |

## 3. 单一职责

- **一个函数只做一件事**：函数名描述的事 = 函数实际做的事
- **一个模块只对一类外部角色负责**：组件只负责渲染，service 只负责数据，util 只负责纯计算
- **避免"万能类"**：如果一个类名称中包含 `Manager`/`Handler`/`Processor`/`Utils`，检查是否能用更具体的词替代
- **副作用集中管理**：数据变更（API 调用、状态修改、文件 IO）与纯逻辑分离
- **测试友好**：每个职责边界就是测试边界。如果一个函数很难写单元测试，大概率是职责太多

## 4. 高内聚低耦合

### 高内聚

- 同一模块内的函数/类服务于同一个业务领域，修改某个功能只需改一个模块
- 模块对外暴露最小接口：只 export 外部确实需要的东西
- 模块内部的 helper 函数用私有作用域（不 export），防止外部直接依赖

### 低耦合

- 模块间通过**明确的接口/类型**通信，不直接访问对方的内部状态
- 避免循环依赖：如果 A 引用 B 且 B 引用 A，抽出公共模块 C
- 避免跨层级直接访问：UI 层不直接查数据库，业务层不直接操作 DOM
- 用依赖注入代替硬编码的 import 依赖（不强制，但优先考虑）

### 检查清单

在提交代码前，自问：
1. 这个函数的职责能用一句话说清吗？（说不清 → 拆分）
2. 变量名别人一看就懂吗？（看不懂 → 重命名）
3. 这段代码和别人改同一个需求有关联吗？（无关 → 放错了模块）
4. 改这个模块会连带改其他模块吗？（会 → 耦合太高）

---

## 5. 代码探索决策

Agent 需要理解代码时，按场景选择探索手段，不要混用：

| 场景 | 用什么 | 理由 |
|------|--------|------|
| 单符号定位（"X 定义在哪"） | 内置 `explore` subagent | 只读、快、fresh context 适合轻量搜索 |
| 主题级理解（"X 模块如何工作"） | `explore.cmd -Type search`（探索缓存检索） | 返回数据位置（热区优先），扫 tags 判断；无匹配派 worker 探索 + 注册入热区 |
| 大规模探索（fresh context 隔离） | `rdd-explore` subagent | 通过 Task 工具派遣，写摘要 + 完整记录 + 注册 |

### 探索缓存使用边界

- **不要**把单符号定位委托给探索缓存：缓存粒度是主题级，单符号查询无法从 tags 获益，浪费一次调用
- **不要**在无匹配后跳过注册：不注册的探索产物无法被后续会话命中，等于白做
- **不要**用 `rdd-explore` subagent 做简单定位：它是可写 worker（fresh context 成本高），仅用于无匹配后的深度探索
- **注册必须带 tags**：tags 是 LLM 判断命中/未命中的核心依据，走 `explore-store.cmd -Type register -Tags "..."` CLI（注册入热区，下一次检索立即可见）
- **MCP 工具 `rdd_explore` / `rdd_explore_register` 已废弃删除**（与现行协议双重断裂：恒走 MISS 分支、注册缺 Tags 必然失败，且零存量用户）。OpenCode 的规范路径是 SKILL → shell CLI（`explore.cmd -Type search` 检索 / `explore-store.cmd -Type register` 注册）。旧版安装过 `.opencode/tools/rdd_explore.ts` 的项目：`coderrdd uninstall` 按清单清理，或手动删除该文件

### 注册时的文件列表

`explore-store.cmd -Type register` 的 `-Files` 参数只列**实际读过并分析**的文件。这些文件的 SHA-256 会被记录——任一变更触发缓存失效。列太多无关文件会降低缓存寿命；漏列关键文件会导致缓存过期不失效。

---

## 6. PowerShell 脚本约定

rdd-engine 的 CLI 脚本在 Windows 上运行，生成代码（含 `.ps1` 脚本本体、Agent 生成的临时脚本）时必须遵守以下约定，否则会踩已知的 PS 5.1 / Windows 陷阱。

### 6.1 `.ps1` 必须保存为 UTF-8 with BOM

PS 5.1 解析**无 BOM 的 UTF-8** 中文脚本时，中文字节会让解析器错位，静默吞掉后续函数定义，报莫名其妙的 `CommandNotFoundException`（函数明明在文件里却"不被识别"）。

- 含中文（注释、字符串、Write-Host 提示）的 `.ps1` 一律 UTF-8 with BOM（首 3 字节 `239,187,191`）
- 验证方式：`[System.IO.File]::ReadAllBytes($path)[0..2]` 应为 `239,187,191`
- 纯 ASCII 脚本不受影响，但统一带 BOM 可避免后续新增中文时遗漏

### 6.2 cmd wrapper 必须用 `.cmd` 而非 `.ps1` 作为入口

Windows 默认 ExecutionPolicy=Restricted，`.ps1` 不能直接执行。所有 rdd-engine 脚本都通过薄壳 `.cmd` 包装：

```cmd
@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0<script>.ps1" %*
```

调用方一律走 `.cmd`，不要直接调 `.ps1`。

### 6.3 `Start-Process` 启动外部程序：跳过 `.ps1`

`Start-Process` / `wt.exe` 无法将 `.ps1` 作为可执行文件直接启动，会报错 `0x800700c1`（ERROR_BAD_EXEFORMAT）。定位可执行文件时用白名单后缀：

```powershell
foreach ($name in @("opencode.cmd", "opencode.exe", "opencode.bat")) {
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if ($found) { return $found.Name }
}
```

显式跳过 `.ps1`（`Where-Object { $_.Extension -ne ".ps1" }`）。

### 6.4 cmd 传参禁用中文

cmd → powershell → 目标程序的参数链路经过 GBK→UTF-8 转码，中文几乎必乱码。需要向 cmd 传参的字符串（如 `--prompt` 内容）必须纯 ASCII：

- 路径用绝对路径，不含中文目录名时安全
- 提示性文字（如 `-TaskId` 的附加说明）用英文，中文放被引用的文件里由目标角色 Read

### 6.5 `Sort-Object` 单元素返回的陷阱

`$sorted = $collection | Sort-Object` 在 `$collection` 仅一个元素时返回**标量**而非数组，此时 `$sorted[0]` 会索引字符串的首字符而非第一个元素。

- 用 `Select-Object -First 1` 替代 `[0]` 索引：
  ```powershell
  return $collection | Sort-Object -Descending | Select-Object -First 1
  ```
- 或强制数组化：`@($collection | Sort-Object)[0]`

### 6.6 调用方路径约定

文档、SKILL 中调用 rdd-engine 脚本时，统一用仓库根定位，避免依赖当前工作目录：

```powershell
$rdd = (Get-ChildItem (git rev-parse --show-toplevel) -Recurse -Directory -Depth 3 -Filter 'rdd-engine' | Select-Object -First 1).FullName; & "$rdd\scripts\<script>.cmd" ...
```

不要写相对路径（`.\rdd-engine\...`），上游 agent 可能在任意子目录下执行。

---

*本规范由 PSE 角色维护。如发现规范与项目实际风格冲突，以项目实际约定为准并通过 PSE 更新本文档。*

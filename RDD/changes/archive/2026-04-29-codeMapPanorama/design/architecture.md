---
requirement_id: map-code-panorama
priority: 高
depends_on: []
blocks: []
analysis_date: 2026-04-30
status: confirmed
tech_stack:
  - opencode skill
  - Agent tools (glob, grep, read, write)
estimated_effort: 小
---

# `/map` 代码全景图 — 设计文档

## 一、需求概述

为 code-compass skill 新增 `/map` 命令，扫描项目源码目录，生成两层数据：目录树概览（带文件数/方法数标注）和文件级方法签名摘要。结果持久化到 `.code-compass/map.md`。替换现有 `/analyze` 占位。

覆盖 requirement.md 中的需求 1-5。

## 二、技术方案

### 2.1 模块归属

纯新增，在现有 `code-compass/references/` 下新建 `map/` 子目录。

```
code-compass/
├── evals/
│   └── evals.json              ← 修改：新增 /map eval 用例
├── references/
│   ├── map/
│   │   └── map.md              ← 新增：/map 核心参考文件
│   ├── project-patterns.md     （复用：技术栈识别）
│   └── readme-generator/
│       └── readme-generator.md （参考：同类文件的风格规范）
└── SKILL.md                    ← 修改：替换 /analyze 为 /map 路由
```

### 2.2 核心流程

```
用户输入 /map 或关键词触发
         │
         ▼
  SKILL.md 路由匹配
         │
         ▼ 读取 references/map/map.md
  ┌──────────────────────────────────────────────────┐
  │             Agent 按参考文件执行                    │
  │                                                    │
  │  Step 1: glob 扫描根目录，识别源码目录               │
  │     │                                              │
  │     ▼                                              │
  │  Step 2: 排除非源码目录，构建目录树                   │
  │     │  同时统计每个目录的文件数                       │
  │     ▼                                              │
  │  Step 3: 按扩展名分组，识别语言类型                   │
  │     │                                              │
  │     ▼                                              │
  │  Step 4: 对每种语言套用 grep pattern                │
  │     │  提取方法签名，统计方法数                       │
  │     │  补充到目录树的方法数标注                       │
  │     ▼                                              │
  │  Step 5: 组装 Markdown 输出                         │
  │     │  第一层：目录树 + 文件数/方法数                 │
  │     │  第二层：按目录分组的文件与方法摘要              │
  │     ▼                                              │
  │  Step 6: Write 写入 .code-compass/map.md            │
  └──────────────────────────────────────────────────┘
```

### 2.3 排除规则

以下目录在 Step 2 中跳过（不扫描、不计数）：

```
.git, .svn, .hg
node_modules, __pycache__, .venv, venv, env
dist, build, out, target, .next, .nuxt
vendor, Pods, .gradle, .idea, .vscode
coverage, .cache, .tmp, .temp
```

### 2.4 语言解析参考

Agent 按扩展名分组后，套用对应语言的 grep pattern：

#### TypeScript / JavaScript (.ts, .tsx, .js, .jsx)

```
匹配 pattern:
  - function name(          → 普通函数
  - export function name(   → 导出函数
  - const name = (          → 箭头函数赋值
  - async name(             → 异步方法（class 内）
  - name(params) {          → class 方法

解读规则：
  - 从匹配行提取函数名和参数列表
  - 如果上一行有 JSDoc 注释（/** ... */），提取为方法说明
  - 没有注释则标注方法名，说明留空让 Agent 推断
```

#### Python (.py)

```
匹配 pattern:
  - def name(               → 普通函数
  - async def name(         → 异步函数
  - class ClassName:        → 类定义（类本身也是结构信息）

解读规则：
  - 从匹配行提取函数名和参数列表（含 self/cls）
  - 如果函数下方有 docstring（"""..."""），提取首行作为说明
  - 缩进层级用来区分顶层函数和类方法
```

#### Java (.java)

```
匹配 pattern:
  - (public|private|protected) (static)? Type name(  → 方法
  - ClassName(                                       → 构造函数（与类名相同）
  - class ClassName                                  → 类定义

解读规则：
  - 提取访问修饰符、返回类型、方法名、参数列表
  - 构造函数特殊标注
  - 上一行的 Javadoc 注释作为说明
```

#### Go (.go)

```
匹配 pattern:
  - func name(                  → 包级函数
  - func (receiver) name(       → 方法（带 receiver）
  - func (receiver) (results)   → 多返回值

解读规则：
  - 提取 receiver 类型、函数名、参数列表
  - 方法签名中包含 receiver 信息
  - 上方的注释行作为说明
```

#### 其他语言 / 非代码文件

```
降级策略：
  - 只列出文件名
  - 标注文件类型（如"样式文件"、"配置文件"、"资源文件"）
  - 不解析方法，不报错
```

### 2.5 输出模板

`.code-compass/map.md` 的 Markdown 结构：

```markdown
# 项目代码全景图

> 生成时间：{timestamp}
> 项目：{project_name} | 源码文件：{total_files} | 方法/函数：{total_methods}

## 目录结构

{project_name}/
├── {dir1}/           # {职责说明} ({file_count} files, {method_count} methods)
│   ├── {subdir1}/    # {职责说明} ({file_count} files, {method_count} methods)
│   └── {subdir2}/    # {职责说明} ({file_count} files)
├── {dir2}/           # {职责说明} ({file_count} files)
└── {dir3}/           # {职责说明} ({file_count} files)

---

## {dir1}/

### {filename1}

职责：{一句话说明}

**方法：**

| 方法 | 签名 | 说明 |
|------|------|------|
| {name} | `{signature}` | {一句话} |

### {filename2}

职责：{一句话说明}

（非代码文件，不解析方法）

---

## {dir2}/
...
```

标题层级设计：
- `#` — 全景图标题（仅一个）
- `##` — 目录名（Agent 按需跳转）
- `###` — 文件名

### 2.6 大型项目处理

当 glob 扫描发现源码文件 > 200 个时：

1. 目录树只展示前两层目录，第三层起合并为 `... (N subdirs)`
2. 方法解析只处理前两层目录下的文件，更深层级标注 `(skipped)`
3. 输出文件末尾追加提示：`> ⚠️ 大型项目，仅展示前两层结构。共 {total} 个源码文件。`

### 2.7 持久化规则

- 路径：`<项目根目录>/.code-compass/map.md`
- `.code-compass/` 目录不存在时用 bash `mkdir` 创建
- 每次调用无条件覆盖，不做增量或缓存
- 参考文件中提示用户将 `.code-compass/` 加入 `.gitignore`

## 三、决策点记录

| 决策点 | 选项 | 最终选择 | 选择理由 |
|--------|------|----------|----------|
| 解析流程 | Agent 自行判断 vs 预定义流程 | 预定义流程 | 减少自主决策空间，执行更稳定 |
| 方法数统计时机 | 扫描阶段统计 vs 后补 | 扫描阶段统计 | 方法数是判断模块复杂度的关键信息，值得多花几秒 |

## 四、风险与应对

| 风险 | 影响 | 应对措施 | 优先级 |
|------|------|----------|--------|
| grep 正则对复杂语法准确率有限 | 部分方法漏识别或误识别 | 参考文件中明确"覆盖主流写法即可，不保证 100%"，降级不报错 | P1 |
| 大型项目扫描耗时长 / 消耗 token | Agent 上下文溢出或超时 | >200 文件触发深度控制，分批扫描 | P0 |
| 非代码文件被误扫描 | 输出噪音 | 排除规则 + 扩展名白名单双重过滤 | P1 |

## 五、实现优先级建议

整体只有一个交付物（`references/map/map.md`）+ 两个修改（SKILL.md、evals.json），建议顺序：

1. **先写 `references/map/map.md`**（覆盖需求 1-4 的完整工作流）
2. **更新 `SKILL.md` 路由**（需求 5）
3. **补充 evals.json 用例**（需求 5）

## 六、实现步骤清单

| 步骤 | 文件 | 操作 |
|------|------|------|
| 1 | `code-compass/references/map/map.md` | 新增。参考本设计文档第 2.2-2.7 节，编写完整的 Agent 指令文件。风格参照 `references/readme-generator/readme-generator.md` |
| 2 | `code-compass/SKILL.md` | 修改。将 `/analyze` 占位段替换为 `/map` 路由块：更新命令名、触发关键词（代码全景图、项目全景、代码地图、code map、panorama）、描述、参考文件路径指向 `references/map/map.md` |
| 3 | `code-compass/evals/evals.json` | 修改。新增 3 个 eval 用例：① `/map` 命令触发、② 自然语言"项目全景"触发、③ 已有 `.code-compass/map.md` 时覆盖 |

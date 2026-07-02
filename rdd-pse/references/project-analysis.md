# 项目分析流程

> 在动笔写任何文档之前，PSE 必须先充分理解项目。本文档定义了系统化的项目分析流程。

---

## 分析步骤

### Step 1：收集元信息

读取项目的身份标识文件：

| 文件 | 提取信息 |
|------|---------|
| `package.json` | 项目名、描述、脚本命令、依赖列表、Node 版本要求 |
| `Cargo.toml` | 项目名、依赖、Rust 版本 |
| `go.mod` | 模块名、Go 版本 |
| `requirements.txt` / `pyproject.toml` | Python 依赖 |
| `.gitignore` | 哪些文件被排除（反向推断构建产物、生成文件） |
| `Dockerfile` / `docker-compose.yml` | 部署方式 |

### Step 2：梳理目录结构

列出项目顶层目录和关键子目录，理解每个目录的职责：

```
项目根
├── src/ 或 backend/  → 主源码
├── frontend/  → 前端（如分离）
├── tests/ 或 __tests__/  → 测试代码
├── docs/  → 文档
├── scripts/  → 构建/部署脚本
├── config/  → 配置文件
├── .rdd/ 或 .claude/ 或 .opencode/  → AI agent 配置
└── node_modules/ 等 → 依赖（文档中忽略）
```

**判断方法：**
- 有 `package.json` 且含 React/Vue → 前端或全栈
- 有 `src/main.*` 或 `src/index.*` → 找入口文件
- 有多个 `package.json`（monorepo）→ 标注各子包职责

### Step 3：识别技术栈

从配置文件和代码推断完整技术栈：

| 维度 | 常见信号 |
|------|---------|
| **语言** | `.ts` / `.js` / `.py` / `.rs` / `.go` 文件 |
| **框架** | `package.json` 中的 `next` / `react` / `vue` / `express` / `fastapi` |
| **构建工具** | `vite.config.*` / `webpack.config.*` / `tsconfig.json` |
| **测试框架** | `package.json` 中的 `jest` / `vitest` / `pytest` / `mocha` |
| **Lint** | `.eslintrc.*` / `.prettierrc` / `ruff.toml` |
| **数据库** | `prisma/` / `.sql` 文件 / `pg` / `mysql2` 依赖 |

### Step 4：理解编码约定

从现有代码中推断（读取 3-5 个源文件即可）：

- **命名规范**：文件名是 kebab-case / camelCase / PascalCase？变量命名风格？
- **文件组织**：一个组件一个文件？模块如何划分？
- **导入风格**：相对路径 vs 别名路径？`import` vs `require`？
- **代码风格**：是否有 `.editorconfig` / `.prettierrc`？缩进是 tab 还是空格？
- **注释风格**：是否有 JSDoc / TSDoc 注释？注释是中文还是英文？

### Step 5：确认入口和执行方式

- 找到主入口文件（`src/index.ts` / `src/main.rs` 等）
- 在 `package.json` 的 `scripts` 中找到启动/构建/测试命令
- 如有 Docker，确认容器启动方式
- 如有 CI/CD，读取 `.github/workflows/` 了解流水线

### Step 6：了解 .rdd/changes/ 归档（如存在）

如有 `.rdd/changes/archive/` 目录：
- 浏览最近的 `requirement.md` 了解历史需求
- 调用 rdd-flow show 读取 task.json 的 currentOwners，了解各需求当前流转到了哪个角色、各角色如何分工
- 这些信息有助于理解项目的演进历史

### Step 7：识别项目亮点

> 售前的核心能力是发掘卖点。前 6 步是"事实采集"，本步是"价值提炼"。

从以下四个维度扫描项目，找出**真正有价值的特色**（不是堆砌功能清单）：

| 维度 | 找什么 | 判断标准 |
|------|--------|---------|
| 架构机制 | 独特的设计、巧妙的数据流、自研框架/中间件 | 同类项目里少见，且确实解决了问题 |
| 工作流创新 | 覆盖了竞品没覆盖的环节、流程编排上的巧思 | 让使用者少走弯路 |
| 痛点解决 | 明确消灭了某个行业/场景的老大难问题 | 能说清"以前多痛，现在怎样" |
| 技术选型 | 非显而易见但效果好的组合/取舍 | 有可量化的收益 |

**硬约束：**

- **每条亮点必须挂一个证据**——代码位置（`file:line`）、配置项、可观测数据或可复现的机制描述。没有证据的就不是亮点，是空话
- **限 3-5 条**：售前经验是"卖点超过 5 个等于没卖点"。强制取舍，只留最有冲击力的
- **场景化叙述**：每条亮点讲清"解决了什么痛点"——读者先共情痛点，再看到解法，最后有证据兜底

**亮点 vs 吹牛的判定：**

| 吹牛（禁止） | 亮点（鼓励） |
|-------------|-------------|
| "高性能" | "探索结果按文件 SHA-256 缓存，任一变更自动失效（`rdd-engine/scripts/explore.cmd`）" |
| "易扩展" | "新增角色只需加一个 SKILL.md，engine 自动纳入流转（`.opencode/commands/` 注册机制）" |
| "企业级" | （无对应证据，直接删） |

扫完四个维度若凑不够 3 条有证据的亮点，就**如实少写**，不硬凑。

---

## 分析产出格式

完成分析后，输出以下摘要给用户确认：

```markdown
## 项目理解摘要

**项目**：[名称] — [一句话描述]

**技术栈**：
- 语言：[X]，运行时：[Y]
- 框架：[前端框架] + [后端框架]
- 构建：[Vite/Webpack/Cargo/...]
- 测试：[Jest/Vitest/Pytest/...]

**入口**：
- 启动：`npm run dev` / `cargo run`
- 构建：`npm run build` / `cargo build`
- 测试：`npm test` / `cargo test`

**目录结构**：
[关键目录树 + 说明]

**编码约定**：
- 命名：[kebab-case/camelCase/...]
- 缩进：[2 spaces / 4 spaces / tabs]
- 文件组织：[...]

**已知注意事项**：
[从代码中发现的坑、历史遗留问题等]

**项目亮点（候选，待与用户确认最终 3-5 条）**：
1. [痛点] → [解法]（证据：`file:line` 或具体机制）
2. [痛点] → [解法]（证据：...）
3. ...
```

用户确认后，进入 README 或 Agent 上下文生成阶段。

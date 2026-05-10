# 代码查询指令实现指南

本文档定义 `/navigate`、`/trace`、`/impact` 三个查询指令的实现细节。

## 核心原则

1. **基于已有索引**：所有查询都基于 `.code-compass/` 下的索引数据，避免直接扫描源码
2. **按需读取**：只读取必要的索引文件，不一次性加载全部数据
3. **渐进式深入**：如果低层级的查询结果不足，再向更深的层级探索

---

## `/navigate` — 定位目标代码位置

### 功能定义

根据关键词（功能描述、实体名称、英文术语等），在项目中定位相关代码文件和方法。

### 查询策略（优先级递减）

1. **Level 1：入口点匹配**（最快、最准）
   - 读取 `entries.json`
   - 在 `id` 和 `description` 中模糊匹配关键词
   - 匹配度高，直接返回入口点及其相关文件

2. **Level 2：方法签名搜索**（精准定位函数）
   - 读取 `methods/*.json` 中的 `name` 和 `signature`
   - 在方法名和签名中匹配关键词
   - 返回匹配的方法定义位置

3. **Level 3：文件路径搜索**（兜底策略）
   - 在 `manifest.json` 的文件路径中匹配
   - 适用于只知道模块名或文件名的情况

4. **Level 4：源码搜索**（最后手段）
   - 直接搜索源码文件中的关键词
   - 搜索 `.py`、`.ts`、`.js`、`.java`、`.go` 文件

### 输出格式

```markdown
## 定位结果：[关键词]

**匹配入口点**（Level 1）：
| 入口 | 框架 | 文件 | 业务描述 |
|------|------|------|----------|
| [id] | [framework] | [file:line] | [description] |

**匹配方法**（Level 2）：
| 方法 | 类/模块 | 文件 | 行号 |
|------|---------|------|------|
| [name] | [class/module] | [file] | [line] |

**涉及文件清单**（综合）：
1. [文件A] — [匹配原因：在哪里被匹配到]
2. [文件B] — [匹配原因]

**建议下一步**：
- 如需理解流程：执行 `/trace [入口点]`
- 如需评估影响：执行 `/impact [文件或方法]`
```

### 示例

```
输入：/navigate 用户登录
输出：
## 定位结果：用户登录

**匹配入口点**：
| 入口 | 框架 | 文件 | 业务描述 |
|------|------|------|----------|
| POST /api/auth/login | FastAPI | api/auth.py:23 | 用户登录验证并返回 JWT 令牌 |
| GET /api/auth/session | FastAPI | api/auth.py:45 | 获取当前会话用户信息 |

**匹配方法**：
| 方法 | 类/模块 | 文件 | 行号 |
|------|---------|------|------|
| verify_password | utils | utils/security.py | 38 |
| authenticate_user | module | services/user.py | 56 |

**涉及文件清单**：
1. api/auth.py — 登录入口（路由定义）
2. services/user.py — 用户认证服务
3. utils/security.py — 密码验证工具

**建议下一步**：
- 执行 `/trace POST /api/auth/login` 追踪登录流程
- 执行 `/impact services/user.py` 评估修改影响
```

---

## `/trace` — 追踪代码执行流向

### 功能定义

从指定入口点出发，追踪代码的完整执行链路，展示调用栈和模块间的流转关系。

### 输入形式

```
/trace <入口标识>
```

入口标识可以是：
- API 路由（如 `POST /api/users/login`）
- 方法全名（如 `UserService.create_order`）
- 函数名（如 `handle_webhook`）

### 查询策略

1. **定位入口**
   - 如果是 API 路由：读取 `entries.json` 找到对应条目
   - 如果是方法：读取 `methods/*.json` 找到方法定义

2. **获取直接调用**
   - 读取入口文件的 `calls/{file}.json`
   - 获取 `calls` 数组（此文件调用的函数）

3. **递归追踪**
   - 对每个被调用的函数，读取对应的 `calls/*.json`
   - 追踪最大深度默认 5 层，超过时截断并提示
   - 避免循环追踪：记录已访问的函数集合

4. **生成调用树**
   - 按深度组织调用关系
   - 每个节点显示：函数签名、文件:行号、简要说明

### 输出格式

```markdown
## 执行流追踪：[入口标识]

**入口信息**：
- 类型：[api/cli/task]
- 文件：[file:line]
- 业务描述：[description]

**调用链路图**：
```
[入口函数] (file:line)
  └─→ [函数A] (file:line)
        ├─→ [函数B] (file:line)
        └─→ [函数C] (file:line)
              └─→ ...
```

**调用链详情**：
| 层级 | 函数 | 文件:行号 | 说明 |
|------|------|-----------|------|
| 0 | [入口函数签名] | api/auth.py:23 | 用户登录入口 |
| 1 | [函数A签名] | services/auth.py:45 | 认证逻辑 |
| 2 | [函数B签名] | services/user.py:67 | 用户查询 |
| ... | ... | ... | ... |

**涉及模块**：
- [模块A] → [模块B] → [模块C]

**涉及的入口点**（调用链路触达的）：
- [其他可能触发此链路的入口]
```

### 示例

```
输入：/trace POST /api/auth/login
输出：
## 执行流追踪：POST /api/auth/login

**入口信息**：
- 类型：api
- 文件：api/auth.py:23
- 业务描述：用户登录验证并返回 JWT 令牌

**调用链路图**：
```
login_handler (api/auth.py:23)
  └─→ authenticate_user (services/auth.py:45)
        ├─→ verify_password (utils/security.py:38)
        └─→ get_user_by_email (services/user.py:56)
              └─→ db.query (models/user.py:23)
```

**调用链详情**：
| 层级 | 函数 | 文件:行号 | 说明 |
|------|------|-----------|------|
| 0 | async def login_handler(request: LoginRequest) | api/auth.py:23 | 登录入口 |
| 1 | def authenticate_user(email, password) | services/auth.py:45 | 认证核心逻辑 |
| 2 | def verify_password(plain, hashed) | utils/security.py:38 | 密码校验 |
| 2 | def get_user_by_email(email) | services/user.py:56 | 数据库查询 |
| 3 | db.session.query(User).filter(...) | models/user.py:23 | ORM 查询 |

**涉及模块**：
api → services.auth → utils.security
                    └→ services.user → models

**涉及的入口点**：
- GET /api/auth/session（复用 authenticate_user）
```

---

## `/impact` — 评估代码改动影响

### 功能定义

分析修改某个文件、类或函数会影响的范围，帮助评估改动风险。

### 输入形式

```
/impact <文件路径或函数名>
```

### 查询策略

1. **如果是文件**
   - 读取 `calls/{file}.json`
   - 获取 `called_by` 数组（谁调用了这个文件中的函数）

2. **如果是函数/方法**
   - 先在 `methods/*.json` 中定位函数，获取所在文件
   - 读取文件的 `calls/*.json`
   - 获取 `called_by` 中匹配该方法的条目

3. **递归追踪上游**
   - 对每个调用方，递归获取其 `called_by`
   - 区分"直接影响"和"间接影响"
   - 最大递归深度 3 层

4. **关联入口点**
   - 检查哪些入口点会触发被分析的代码
   - 从 `entries.json` 中筛选相关入口

### 输出格式

```markdown
## 影响评估：[目标]

**目标信息**：
- 类型：[文件/类/函数]
- 位置：[file:line]

**直接影响**（直接调用此代码的位置）：
| 调用方 | 文件:行号 | 调用场景 |
|--------|-----------|----------|
| [函数A] | file:line | [简要说明] |
| [函数B] | file:line | [简要说明] |

**间接影响**（调用方的调用方，2 层内）：
| 影响函数 | 文件:行号 | 影响路径 |
|----------|-----------|----------|
| [函数C] | file:line | 通过 [函数A] 调用 |
| [函数D] | file:line | 通过 [函数B] 调用 |

**触达入口点**（会触发此代码的业务入口）：
- [入口1] — [文件]
- [入口2] — [文件]

**改动风险提示**：
1. **[高风险]** [说明]
2. **[中风险]** [说明]
3. **[低风险]** [说明]

**建议**：
- 改动前：确认以上直接影响是否都在预期内
- 改动后：重点测试以下入口：[入口列表]
```

### 示例

```
输入：/impact services/user.py
输出：
## 影响评估：services/user.py

**目标信息**：
- 类型：文件
- 位置：services/user.py

**直接影响**（直接调用此代码的位置）：
| 调用方 | 文件:行号 | 调用场景 |
|--------|-----------|----------|
| authenticate_user | services/auth.py:45 | 登录时验证用户 |
| get_user_profile | api/users.py:67 | 获取用户资料接口 |
| update_user_info | api/users.py:89 | 更新用户信息接口 |

**间接影响**（2 层内）：
| 影响函数 | 文件:行号 | 影响路径 |
|----------|-----------|----------|
| login_handler | api/auth.py:23 | 通过 authenticate_user 调用 |
| profile_handler | api/users.py:78 | 通过 get_user_profile 调用 |
| update_handler | api/users.py:90 | 通过 update_user_info 调用 |

**触达入口点**：
- POST /api/auth/login — 通过 authenticate_user
- GET /api/users/{id} — 通过 get_user_profile
- PUT /api/users/{id} — 通过 update_user_info

**改动风险提示**：
1. ⚠️ [高风险] 修改 User 模型字段会影响数据库迁移
2. ⚠️ [高风险] 修改 get_user_by_email 签名会影响 auth.py 的调用
3. 🔸 [中风险] User 类的序列化方式影响 API 响应格式

**建议**：
- 改动前：确认以上直接影响是否都在预期内
- 改动后：重点测试以下入口：POST /api/auth/login、GET /api/users/{id}
```

---

## 错误处理

### 索引不存在

```
⚠️ 代码索引尚未构建。请先执行 /map 构建索引。
```

### 入口/方法未找到

```
⚠️ 未找到匹配的 [入口/方法]。尝试：
1. 使用更通用的关键词
2. 使用 /map --refresh 更新索引
3. 直接告诉我你想找什么，我来搜索源码
```

### 追踪深度超限

```
⚠️ 调用链追踪超过 5 层深度，已截断。
完整链路可能存在更多层级。是否需要继续追踪？
提示：可以分两步执行，先追踪前半段，再追踪后半段。
```

### 循环依赖检测

```
⚠️ 检测到循环依赖，已停止追踪。
循环路径：[函数A] → [函数B] → [函数C] → [函数A]
```

---

## 性能优化

1. **缓存策略**：索引文件在单次指令执行中只读取一次
2. **延迟加载**：只在需要时才读取 `calls/*.json`
3. **批量处理**：多个匹配结果合并展示，避免重复输出
4. **大项目限制**：文件数超过 200 时，默认只显示 Top 20 匹配结果

---

## 与其他指令的联动

### `/understand` → `/navigate`

`/understand` 生成全局上下文后，用户可以基于上下文中的模块描述，使用 `/navigate` 定位具体代码。

### `/navigate` → `/trace`

找到目标入口点后，使用 `/trace` 追踪执行流程。

### `/navigate` → `/impact`

找到相关文件后，使用 `/impact` 评估修改影响。

### `/trace` → `/impact`

追踪完成后，可以对链路中的某个函数执行 `/impact` 评估影响。

---

## 典型使用场景

| 场景 | 推荐指令序列 |
|------|-------------|
| 接手新项目，快速了解架构 | `/understand` |
| 修改某个功能，定位要改的文件 | `/navigate [功能名]` |
| 理解业务流程，分析代码逻辑 | `/trace [入口]` |
| 评估改动风险，准备 code review | `/impact [文件]` |
| CTO 理解项目现状 | `/understand` → `/navigate` → `/trace` |
| DEV 定位开发范围 | `/navigate` → `/impact` |

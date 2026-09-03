# 测试用例设计指南

本文件包含测试用例设计的方法论、模板，以及功能用例库的存储规范。在第三步生成测试用例、第七步归档时按需读取。

## 目录

- [测试用例设计方法](#测试用例设计方法)
- [测试用例模板](#测试用例模板)
- [测试代码模板](#测试代码模板)
- [功能用例库](#功能用例库)

---

## 测试用例设计方法

### 等价类划分

将输入数据按有效/无效分成若干等价类，每个等价类取一个代表值。这样可以用较少的用例覆盖较多的输入情况。

举例——搜索功能的关键词输入：

| 等价类 | 示例值 | 说明 |
|--------|--------|------|
| 有效-普通字符串 | "张三" | 正常搜索 |
| 有效-特殊字符 | "C++" | 含特殊符号 |
| 有效-长字符串 | [200字] | 接近长度上限 |
| 无效-空字符串 | "" | 无输入 |
| 无效-超长字符串 | [10001字] | 超出长度限制 |

### 边界值分析

在等价类的边界上取值，因为边界是 bug 最容易藏身的地方。

举例——分页参数 `page` 的边界：

| 边界 | 测试值 | 预期 |
|------|--------|------|
| 最小值-1 | 0 | 报错或自动修正为 1 |
| 最小值 | 1 | 返回第一页 |
| 正常值 | 5 | 返回第五页 |
| 最大值 | 总页数 | 返回最后一页 |
| 最大值+1 | 总页数+1 | 返回空结果 |
| 负数 | -1 | 报错 |
| 非数字 | "abc" | 报错 |

### 错误推测

基于经验推测可能出错的场景。常见的易错点：

- 并发操作（两个用户同时修改同一条数据）
- 网络异常（请求超时、服务不可用）
- 数据状态异常（外键指向不存在的记录、字段为 null）
- 时区与时间边界（跨天、跨月、闰年）
- 字符编码（emoji、多字节字符、HTML 实体）
- 权限与认证（未登录、token 过期、无权限）

### 场景法

把用户场景转化为测试场景。从需求文档的"用户场景"部分直接提取：

```
用户场景：管理员在后台搜索用户，输入手机号后点击搜索，系统显示匹配的用户列表

→ 测试场景：
  TC-001：输入已注册手机号，返回对应用户（正向）
  TC-002：输入未注册手机号，返回空列表并提示未找到（反向）
  TC-003：输入格式错误的手机号，提示格式不正确（边界）
  TC-004：手机号前后有空格，自动去除空格后搜索（边界）
```

---

## 测试用例模板

### 完整模板

```markdown
### TC-[编号]：[测试标题]

- **关联需求**：[需求编号/标题]
- **测试类型**：正向 / 反向 / 边界 / 异常
- **优先级**：P0 / P1 / P2
- **前置条件**：[环境/数据/状态要求]
- **测试步骤**：
  1. [操作]
  2. [操作]
- **预期结果**：[明确的判断条件]
- **验收标准映射**：[需求中的验收标准编号]
```

### 精简模板（P2 用例适用）

对于优先级较低的边缘场景，可以用精简格式：

```markdown
### TC-[编号]：[一句话描述]

- **类型/优先级**：[类型] / P2
- **输入**：[输入值]
- **预期**：[预期结果]
```

### 用例编号规则

- 按需求分组，编号连续：需求 1 用 TC-001~TC-0XX，需求 2 用 TC-101~TC-1XX
- 同一需求内按优先级排序：P0 → P1 → P2
- 编号留出间隔（步长 5 或 10），方便后续插入

---

## 测试代码模板

### 单元测试（通用结构）

```python
# Python / pytest 示例
class TestUserSearch:
    """用户搜索功能测试 — 关联需求：搜索功能"""

    def test_search_by_phone_returns_matching_user(self):
        """TC-001: 输入已注册手机号返回对应用户"""
        # Arrange
        user = create_user(phone="13800138000", name="张三")

        # Act
        result = search_users(phone="13800138000")

        # Assert
        assert result.total == 1
        assert result.items[0].name == "张三"

    def test_search_by_unregistered_phone_returns_empty(self):
        """TC-002: 输入未注册手机号返回空列表"""
        result = search_users(phone="99999999999")

        assert result.total == 0
        assert result.items == []
```

```typescript
// TypeScript / Jest 示例
describe("用户搜索功能 — 关联需求：搜索功能", () => {
  test("TC-001: 输入已注册手机号返回对应用户", async () => {
    const user = await createUser({ phone: "13800138000", name: "张三" });

    const result = await searchUsers({ phone: "13800138000" });

    expect(result.total).toBe(1);
    expect(result.items[0].name).toBe("张三");
  });

  test("TC-002: 输入未注册手机号返回空列表", async () => {
    const result = await searchUsers({ phone: "99999999999" });

    expect(result.total).toBe(0);
    expect(result.items).toEqual([]);
  });
});
```

### 测试命名规范

测试函数名应包含三要素：**被测功能 + 测试条件 + 预期结果**

| 好的命名 | 不好的命名 |
|---------|-----------|
| `test_search_by_phone_returns_matching_user` | `test_search_1` |
| `test_create_order_with_empty_cart_raises_error` | `test_error` |
| `test_login_with_expired_token_returns_401` | `test_login_fail` |

### Arrange-Act-Assert 模式

每个测试遵循三段式结构：

1. **Arrange**（准备）：创建测试数据、设置前置条件
2. **Act**（执行）：调用被测函数/接口
3. **Assert**（断言）：验证结果是否符合预期

每段之间用空行分隔，必要时加 `// Arrange`、`// Act`、`// Assert` 注释。这比一大段连续代码更易读，也让其他人在测试失败时快速定位问题。

---

## 测试文件组织

如果项目没有明确的测试文件组织约定，可参照以下结构：

```
tests/
├── unit/                    # 单元测试
│   ├── services/
│   │   └── user.test.ts     # 对应 src/services/user.ts
│   └── utils/
│       └── validator.test.ts
├── integration/             # 集成测试
│   └── api/
│       └── user.test.ts
└── fixtures/                # 测试数据
    └── users.json
```

---

## 功能用例库

> 测试用例是按**功能**组织的长期资产（跨迭代活着），不是按需求归档的一次性快照。本节定义 `.rdd/tests/` 的结构、JSON Schema 和命名约定。
>
> **为什么是 JSON**：用例库是结构化数据（供可视化面板、回归分析、覆盖率统计消费），MD 表格无法机器校验。JSON 是唯一事实源，人类可读视图由工具从 JSON 渲染，不手写。

### 目录结构

```
.rdd/tests/
├── index.json               # 功能清单总览（QA 入口）
├── search/cases.json        # 搜索功能用例规约
├── user/cases.json          # 用户功能用例规约
└── order/cases.json         # 订单功能用例规约
```

**与 archive 的分工**：
- `.rdd/tests/{feature}/cases.json` = 功能的**当前态**（现在该测什么）— 类似 working tree
- `archive/.../tests/cases.json` = 本次变更的**增量**（动过哪些 TC）— 类似 commit

### 通用 JSON 约定

- **编码与格式**：UTF-8，2 空格缩进，键名用 camelCase
- **枚举值固定**，禁止自由文本（见各 Schema 注释）
- **id 唯一性**：同一 feature 内 TC 编号不得重复
- **写后自检**：每次写入后校验——JSON 可解析、枚举值合法、无重复 id、`activeCount`/`deprecatedCount` 与 cases 数组实际值一致

### index.json Schema

```json
{
  "features": [
    {
      "feature": "search",
      "relatedCode": ["src/services/search.ts"],
      "testCode": ["tests/search.test.ts"],
      "activeCount": 7,
      "deprecatedCount": 2,
      "lastUpdated": "2026-07-15",
      "lastChange": "2026-07-15-search-v2"
    }
  ]
}
```

### cases.json Schema（核心）

每个功能一个文件。结构固定，便于跨迭代演进：

```json
{
  "feature": "search",
  "status": "active",
  "relatedCode": ["src/services/search.ts"],
  "testCode": ["tests/search.test.ts"],
  "lastChange": "2026-07-15-search-v2",
  "cases": [
    {
      "id": "TC-001",
      "title": "合法关键词返回结果",
      "type": "positive",
      "priority": "P0",
      "acceptance": "AC-1.1",
      "codeRef": "tests/search.test.ts:12",
      "sourceChange": "2026-06-01-search-v1",
      "status": "active",
      "crossFeature": [],
      "precondition": "数据库存在种子用户",
      "steps": ["输入关键词「张三」", "点击搜索"],
      "expected": "返回名称匹配的用户列表"
    },
    {
      "id": "TC-002",
      "title": "旧版结果排序",
      "type": "positive",
      "priority": "P2",
      "acceptance": "AC-1.2",
      "codeRef": null,
      "sourceChange": "2026-06-01-search-v1",
      "status": "deprecated",
      "deprecatedReason": "v2 重构取代",
      "crossFeature": [],
      "expected": "按创建时间倒序"
    }
  ]
}
```

**字段说明**：

| 字段 | 必填 | 约束 |
|------|------|------|
| `feature` | ✅ | kebab-case，与目录名一致 |
| `status` | ✅ | `active` / `deprecated`（功能整体废弃时标 `deprecated`，不删文件） |
| `cases[].id` | ✅ | `TC-` 前缀 + 数字，同一 feature 内唯一，续编不重排 |
| `cases[].type` | ✅ | 枚举：`positive`（正向）/ `negative`（反向）/ `boundary`（边界）/ `exception`（异常） |
| `cases[].priority` | ✅ | 枚举：`P0` / `P1` / `P2` |
| `cases[].acceptance` | ✅ | 验收标准编号，如 `AC-1.1`；无映射时填 `null`（会被覆盖率追溯揪为孤立用例） |
| `cases[].codeRef` | ✅ | 测试代码位置：`文件:行号` 或 `类::方法`；deprecated 可为 `null` |
| `cases[].sourceChange` | ✅ | 首次引入时的 archive 目录名 |
| `cases[].status` | ✅ | 枚举：`active` / `deprecated` |
| `cases[].deprecatedReason` | deprecated 时必填 | 取代原因，如"v2 重构取代" |
| `cases[].crossFeature` | ✅ | 数组，关联的其他功能名；无关联填 `[]` |
| `precondition` / `steps` / `expected` | 建议填 | P0/P1 用例必填 `expected`；P2 可只填 `expected`（对应精简模板） |

### cases 数组 = 长期追溯矩阵

cases 数组同时承担追溯矩阵的职责（需求↔用例双向闭环），第三步覆盖率追溯直接读它：
- **正向**（验收标准 → 用例）：每条验收标准（`acceptance` 字段）是否有用例覆盖
- **反向**（用例 → 验收标准）：揪出 `acceptance` 为 `null` 的**孤立用例**（大概率是"测了需求外的东西"或"需求遗漏了"）

单条验收标准的功能无需刻意构建覆盖视图，cases 数组本身已足够。

### 功能命名约定（QA 淘汰式）

- **kebab-case**，语义化，与被测能力对齐（`search`、`user-auth`、`order-export`）
- **复用优先**：第〇步识别功能时，已有功能能覆盖的绝不新建。命名在首次使用时与用户确认，后续迭代沿用
- **避免过细**：一个功能 = 一组用户可感知的完整能力。"搜索"是一个功能，不要拆成"搜索输入"和"搜索结果"
- **重命名谨慎**：功能名一旦建立就是回归测试的锚点，轻易不改；确需改时同步更新所有 cases.json 和 index.json 的引用

### 演进规则

- **新增用例**：续编 TC 编号（步长见上方「用例编号规则」），`status: "active"`，填 `sourceChange`
- **修改用例**：原地改，`sourceChange` 不变、archive 增量记录本次修改。不保留旧版内容（旧版在历史 archive 里可查）
- **废弃用例**：**不删除**。`status` 改 `deprecated`，填 `deprecatedReason`。`codeRef` 置 `null` 或保留历史值
- **功能整体移除**：顶层 `status` 改 `deprecated`，不删文件

### 跨功能用例（cross-feature）

一条用例涉及多个功能时（如"登录后搜索"同时涉及登录和搜索）：

- **归属主触发功能**：用例对象放在核心行为落地的功能的 cases.json 里（"登录后搜索"归 `search`）
- **填 crossFeature 数组**：列出关联的其他功能：

  ```json
  {
    "id": "TC-008",
    "title": "登录用户搜索返回个性化结果",
    "crossFeature": ["user-auth"],
    "type": "positive",
    "priority": "P0"
  }
  ```

- **不在被关联功能里重复登记**：`user-auth/cases.json` 不重复写这条用例，避免同步成本

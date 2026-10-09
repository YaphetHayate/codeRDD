# 配置中心实现备注（goal-tree ops-config-panel-r2 · n3 · DEV）

> 单源设计依据：`.rdd/goal-trees/ops-config-panel-r2/design.md`（n2 CTO 产物，R1 设计之上增量）。
> 本文记录 R2 实现要点、与设计的偏差及理由、自测结果。R1 备忘见 git 历史（本文整体替换为 R2 版）。

## 1. 交付清单（设计 §7 接入点逐项）

| 文件 | 状态 | 要点 |
|------|------|------|
| `lib/readers/config.mjs` | 修改 | R2 单源追加：`MODULE_DEFS`（8 模块 29 行：item/layer 平实词/editable/consumers[]/crossModule + 生态行 probe/infoOnly）、`CROSS_MODULE_PATHS`（向量 7 字段）、`crossModuleImpact`（服务端 diff）、UX 面（`validateUxAgents` 三门一次报全 / `mergeUxAgents` 保留 $schema·comment·managed·rules / `writeUxSubagentsAtomic` 同 R1 五步序 / `readUx` 文件+磁盘 frontmatter 探测+BOM 剥离+syncStatus 五态）；`readConfig` 尾部纯增量 `data.modules`（defs+items，probe 结果合并）与 `data.ux`，l1–l5 一字未动 |
| `lib/ux-sync.mjs` | 新增 | `runUxSync`：spawn 临时 wrapper cmd（`call "sync-ux-subagents.cmd" > out 2> err`）——stdio 走**临时文件重定向**而非管道（宿主沙箱禁 named pipe，见偏差 2）；`RDD_PROJECT_ROOT` 钉数据根 + cwd；15s 超时 taskkill /T /F 树杀 → status='timeout'；exit≠0 → 'failed'（exitCode+stderr）；exit 0 解析「需重启 opencode 才能生效」→ changed/restartRequired +「变更操作：」节明细；stdout/stderr 各 16KB 截断、UTF-8 优先 GBK 回退解码 |
| `lib/views/config.mjs` | 重写 | renderBody 改 8 模块 panel（`MODULE_DEFS` 驱动：title + subtitle prose + 只读表「配置项/层/可写性/消费方/探测」+ 公用 badge；消费方文案单源=reader 常量）；R1 组件复用重组：env 观测表按模块过滤（shared×2 / search×APIKEY「已设置（不回显）」/ handoff×2）、调参状态行/14 字段对比表/就绪卡/表单内嵌 search 模块（标题去 L 前缀）；表单行增 `data-original`（客户端 diff 基线）与 `data-cross-module`（向量 7 字段）；向量 fieldset 下常驻跨模块 hint（提醒层①）；UX 模块四件套（清单表+同步状态探测面板含「运行同步」按钮+编辑表单含 readonly name/template 克隆源+rules 摘要+逃生门脚注）；声明条改「两个可写点」；页头 subtitle 换 §3 文案 |
| `server.mjs` | 修改 | `serveApi` 增两控制面分支（均 405 门）：`POST /api/config/ux-subagents`（§6.2 谱系：413→400 形状（body/agents/数组/条目对象）→422 unknown-field（顶层+条目一次报全）→422 invalid-field（谓词一次报全）→422 agent-count→合并→原子写→spawn sync→回读→200；handler 拆 `uxShapeProblem`/`uxGateProblem`/`uxWrite` 三层 ≤50 行）；`POST /api/config/ux-subagents/sync`（只跑脚本不写文件，200+sync+syncStatusAfter）；`handleConfigSave` 响应尾增可选 `impact`（仅向量字段实际变更时出现） |
| `static/app.js` | 修改 | ①config 表单提交前客户端 diff（`data-original` vs 当前值）∩ `data-cross-module` → `window.confirm` §4.2 文案，取消=不发请求表单保留；成功 note 增「影响面：检索召回 + 缓存向量化」（层③，依据响应 impact）；②UX 表单：全量收集（temperature 严格数字字面量才转 number，否则原样上送让 422 点名）→ POST → 双段渲染（绿「文件已保存」+ 绿「已同步…需重启 opencode」或黄「同步失败…重试指引」，sync 失败**不自动刷新**保持行动指引可见）→ 成功 800ms 刷新；③「运行同步」按钮 → sync 端点 → 结果渲染+重启提醒；④「添加子代理」template 克隆（无 JS 时表单只读可见不可存，沿 R1）；fieldErrors 列表抽 `buildFieldErrorList` 共享 |
| `lib/layout.mjs` | 修改 | 三处文案：brand-sub「本地 · 双点可写」；sidebar-note「…可写：search-config.json + ux_subagent.json（配置中心）」；页脚「…可写：search-config.json / ux_subagent.json（配置中心）…」 |
| `static/style.css` | 修改 | 5.19 段（module-sub / ux-agent-block / ux-sync-head，全部复用既有 token） |
| `tests/test-dashboard-ux.mjs` | 新增 | 125 项：模块覆盖矩阵（R-UX10：L1 5 变量/L2 14 字段 token/L3 5 常量/L4 全脚本 token/L5 全路径唯一归入 8 模块、4 可写行、7 公用行）；readUx 探测五态矩阵（synced/pending-sync 双字段点名/pending-clean/orphan/非 ux-mockup 忽略/unknown×2）；§5.2 谓词 17 样例逐条+重名+未知键路径+计数门；merge 键序/保真/骨架；runUxSync 假 cmd 注入（ok+changed+明细解析/无变更/exit 1/超时）；HTTP 全谱系（405×2/400×5/413/422×3+拒后字节不变+APIKEY 无涉）；真脚本冒烟（保存→updated+created+managed 回写+磁盘 .md frontmatter 断言+changed=false 幂等；损坏 json→sync-only 如实 failed exit 1；骨架路径）；impact 三态；SSR marker |
| `tests/test-dashboard-config.mjs` | 迁移 | §6.4 行 2：SSR marker 表换新文案集 + 负向断言（无 `\bL[1-5]\b`、无「唯一可写点」）+ 新页脚断言；reader/API/POST 节零改动（75/75） |
| `tests/test-dashboard-page-contract.mjs` | 迁移 | §6.4 行 4：Section D 声明条断言「两个可写点」+ 模块标题 marker + 负向断言；`data-config-field` 计数 14 保留；新增 `data-cross-module`=7、`data-original`、hint 层①、UX 表单区块断言（§8）；契约断言零改动（69/69） |
| `tests/test-config-acceptance.mjs` | 迁移 | §6.4 行 3 的**显式修正**（见偏差 1）：成功响应精确键集断言改超集断言（7 键全在，允许增量 `impact`），并新增 impact 内容断言；其余零改动（90/90） |
| `dev/implementation-notes.md` | 本文件 | R2 要点/偏差/自测 |

## 2. 与设计的偏差 / 实现裁量（逐条附理由）

1. **`test-config-acceptance.mjs` 的成功响应断言从「精确键集」放宽为「超集」**。设计 §6.4 行 3 预判该测试「零改动通过」，但其 L289 实际断言 `Object.keys(payload).join(',') === 'ok,code,path,bytes,writtenAt,effective,vectorReadiness'`（精确键集），而设计 §4.2/§E3 自己裁定 POST 响应新增**可选** `impact` 键——该测试的保存样例恰触及 endpoint/dimensions，`impact` 必然出现，精确键集必挂。这是设计内部预判错误（§4.2 超集扩展 vs §6.4 零改动预判冲突）。处置：按 §E3 的超集语义显式迁移该断言（7 键全在 + 新增 impact 内容断言），契约语义零放水；在测试注释与本文记录——非静默改测试（R-R8 精神）。
2. **sync spawn 的 stdio 从 `['ignore','pipe','pipe']` 改为临时文件重定向**。设计 §5.4 表指定管道捕获；但 DEV 宿主沙箱（DSH Windows sandbox）禁止子进程 named pipe（`spawn EPERM`，文档化边界），管道捕获在本环境不可运行。等价实现：生成一次性 wrapper cmd（`call "<sync.cmd>" > "<tmp>.out" 2> "<tmp>.err"`，`stdio:'ignore'`）+ close 后读文件（全量捕获、16KB 截断、超时态读到的部分内容如实上报）。捕获语义与设计一致；wrapper 引号由 cmd 脚本文件解析器处理，任意空格路径可用；文件用后即删。直接 `/c "cmd > file"` 的命令行嵌套引号在实测中解析失败（exit 1 零输出），wrapper 是唯一稳定形态。
3. **sync 失败/超时时 UX 表单成功后不自动整页刷新**。设计 §5.4 要求双段渲染+行动指引（重试同步/手工命令）+「失败是持续可见的状态」；若沿用 R1 的 800ms 自动刷新，双段指引会被立即冲掉（刷新后只剩探测面板的 pending-sync 状态，丢失 stderr 明细与重试入口）。裁量：仅 `sync.status==='ok'` 时 800ms 刷新；失败态保留完整回执直到用户操作。
4. **磁盘 frontmatter 探测剥 UTF-8 BOM**。sync 脚本 `New-AgentFile`/`Update-AgentFrontmatter` 用 `$utf8Bom` 写 .md，`readFileSync('utf8')` 直读则首字符为 U+FEFF，frontmatter `^---` 锚定失败、字段全读为 null → 永假 pending-sync。探测前置 BOM 剥离（与 io.mjs readText 同语义）。
5. **modules 的机读形态**为 `{defs: [...], items: [...]}`（设计 §6.3 只描述「数组+清单」的内容组成未定 schema）；items 行把 `probe`/`exists`/`infoOnly` 合并进对应生态行，view 与 API 共用一份。
6. **`agents` 条目级畸形输入的探测面行为**：readUx 如实返回原数组（n4 断言「文件 agents ≡ POST 数组」），探测跳过非对象/无名条目（不进 perAgent）；编辑表单对畸形条目按空值渲染占位行，保存链路由 400/422 门拦住。
7. **UX 编辑表单的既有行 name 输入框用 `readonly`（非 disabled）**：改名不做页面入口（§D5），readonly 保持可见可复制且 JS 收集时照常读取；新克隆行 name 可填。
8. **「运行同步」按钮常驻同步状态面板**（非仅失败后出现）：它同时是 §5.4 的「重试同步」恢复路径与手工同步的页面化入口；无 JS 时 disabled 并注明手工命令（沿 R1 保存按钮模式）。

## 3. 自测结果

| 测试 | 结果 | 覆盖 |
|------|------|------|
| `tests/test-dashboard-ux.mjs`（新，125/125） | ✅ | 见交付清单行 7 |
| `tests/test-dashboard-config.mjs`（迁移后 75/75） | ✅ | R1 契约节零改动通过；SSR marker 迁移 + 负向 L 黑话断言 |
| `tests/test-dashboard-page-contract.mjs`（迁移后 69/69） | ✅ | 完整文档契约/侧边栏/app.js 模块装配不回归；Section D 迁移 + UX 表单断言 |
| `tests/test-config-acceptance.mjs`（迁移后 90/90） | ✅ | R1 黑盒表零改动通过（§5/§6/§2/§9）；impact 超集断言 + 内容断言 |
| `tests/test-dashboard.mjs`（零改动 134/134） | ✅ | 不回归（7 域隔离、/config 路由、live 数据） |
| `scripts/code-metrics.cmd -Command scan` | ✅ | 违规 0（新 handler 三层拆分 ≤50 行；view 组件全部小函数） |
| 真实服务冒烟（本仓数据根，8790） | ✅ | /config 200 · 8 模块 marker 全齐 · 无 L1–L5 黑话 · UX 表单/模板/7 跨模块字段 · API 8 defs/29 items · UX 3 agents 全 synced · .md frontmatter 值正确读取 |

**安全边界自证**（设计 §8 ④）：ux 写目标 = `context.projectRoot + 'rdd-ux/ux_subagent.json'` 服务端推导，请求体零路径字段；未知键 422（顶层+条目）；`MAX_BODY_BYTES=8192` 复用；ux 域无密钥字段且全链路断言 APIKEY 不出现；原子写同 R1（tmp 同目录同卷 + pid 后缀 + 失败尽力清理原文件不动）；sync 子进程 env 钉 `RDD_PROJECT_ROOT`=当前数据根，脚本行为收口在该根内。

## 4. 已知边界（沿用设计 §9，无新增）

- R-UX1/R-UX3/R-UX6/R-UX7/R-UX10：按设计处置落地（in-band 分轨、单一写者、回读为准、结构不可逃逸、单源常量+覆盖自测）。
- sync 输出解码：UTF-8 优先、GBK 回退；极端不可解码环境 changed 判定降级为 false（探测面板仍如实显示 pending-sync 漂移），不吞异常不伪造成功。
- MODULE_DEFS 是引擎配置面的第 8 处镜像（沿 R1「改需双侧同步」约定）：引擎增删配置项时需同步分区表，覆盖断言（29 items/4 可写/7 公用）在 test-dashboard-ux.mjs 把关。

---

# R2 缺陷修复（goal-tree ops-config-panel-r2 · n5 · DEV · 2026-10-09）

> 依据：`.rdd/goal-trees/ops-config-panel-r2/verification-report.md`（n4 QA FAIL：D1/D2/D3）。规划者已裁定三项全部修复、不出范围。修复面最小化：仅 `lib/readers/config.mjs`、`lib/ux-sync.mjs`、`tests/test-dashboard-ux.mjs` 三文件 + run 目录内冒烟脚本/日志（`.rdd/goal-trees/ops-config-panel-r2/dev/`）。

## 1. 逐缺陷对照

| 缺陷 | 修复 | 位置 |
|------|------|------|
| **D1** · 判据①b · goal-tree 行缺 `GoalRoot` | MODULE_DEFS delivery 模块 goal-tree 行补 `GoalRoot off（switch，goal-root 模式：根为不可认领 conclude 锚点）`——措辞取 QA 报告 D1 修复建议/R1 工件 L93 权威行，插入位置在 MaxNodes 与 GateMode 之间（与工件参数序一致）；行 consumers 同步补 GoalRoot 语义（与 -GoalFile 成对、建树时决定根是否升格 type=goal 终局锚）。测试覆盖矩阵 frozen/CLI token 清单补 `GoalRoot`，SSR marker 增 `GoalRoot`/`goal-root 模式` | config.mjs L507；test-dashboard-ux.mjs L93、L324 |
| **D2** · 判据①b · `rdd-engine/package.json` 未入模块视图 | shared 模块补 infoOnly 一行：item 为 `rdd-engine/package.json（引擎版本 ${ENGINE_VERSION}）`。版本由 `readEngineVersion()` 在模块装载时**从本模块位置推导引擎根实读** package.json（`../../../package.json`：dashboard/lib/readers → rdd-engine），运行时读取、非静态镜像——版本 bump 后行文案自动跟随，读不到时如实落「未知」不伪造。consumers 依据事实源：rdd-flow -Command version 实读该文件（rdd-flow.ps1 L2527-2536）。测试补三断言：生态路径 token `rdd-engine/package.json`、**live 版本比对**（测试侧自读引擎 package.json 与 MODULE_DEFS 文案比对——静态硬编码版本号会在下次 bump 被该断言拦住）、items 计数 29→30 | config.mjs L462-471（helper/const）、L483（行）；test-dashboard-ux.mjs L96、L100-102、L223、L324 |
| **D3** · 质量硬规 · `runUxSync` 65 有效行 > 50 | 拆出五个模块级辅助：`cleanupFiles`（临时文件清理）/ `captureStreams`（双流读取+解码+截断）/ `startWrapper`（wrapper 生成+spawn，原引号理由注释随迁）/ `failedOutcome`（三失败路径共用形状）/ `settleOnce`（首调独胜 settle + 超时树杀定时器所有权，报告建议的 settleOnce 形态）。主函数回到 **40 有效行**（n4-func-len 同口径），五辅助各 ≤18 行。行为零变化：三失败路径字段级形状逐一保持——spawn 失败路径 stderr 不经 capStream、error 事件路径 capStream 前缀拼接 `\nspawn 错误：`、timeout/ok 路径形状原样；既有 125 项 runUxSync 单测零改动全绿护航 | ux-sync.mjs L96-158（五辅助）、L161-202（主函数） |

## 2. 裁量与边界（非缺陷面不动）

1. **D2 新行不标 crossModule（公用 badge）**：它是版本账本（单一消费方 rdd-flow version），非跨模块消费的配置；保持 QA 已验收的「公用 badge 恰 7 处」性质（crossRows=7 断言不变、零改）。与 manifest.json 行（定位链参与方，crossModule=true）性质不同。
2. **l1–l5 脊柱零改动**：D1/D2 均只动 R2 的 MODULE_DEFS 层。L4_TABLE 明细镜像与 L5_INFO_ONLY 不动——acceptance 断言 infoOnly 恒 1、reader 断言 probes 恒 5 依赖 R1 脊柱字节兼容。L4_TABLE 的 goal-tree 组本就是 R1 遗留子集（无 GoalRoot/CoverageToleranceS，QA 未列缺陷）；判据①b 的追溯口径是模块行 token 级，已由 MODULE_DEFS 满足（真根冒烟同步验证 API 行）。
3. **M1（serveApi/handleConfigSave 51 行临界）不顺手拆**：三项修复均未触及 server.mjs，按 n5 任务「不为此扩大改动面」处置。func-len 门禁自测从 3 超限降为 2 超限（即 M1 对），新/改函数全部 ≤50。
4. **冒烟脚本退出码坑**：初版 `process.exit()` 强退在 Windows 上触发 libuv teardown 断言（`UV_HANDLE_CLOSING`，undici async handle 与 ExitProcess 竞态；发生在全部断言通过与摘要打印之后的纯外观层）。定位过程排除动态 import/keep-alive 连接/close 时序后，改「await server.close() 回调 + `process.exitCode` 自然排空」收尾即 exit=0。已按 tips 协议沉淀。

## 3. 自测结果（2026-10-09）

| 项 | 结果 |
|----|------|
| `tests/test-dashboard-ux.mjs` | ✅ **131/131**（原 125 + 6 新断言：GoalRoot token / package.json token / live 版本比对 / SSR GoalRoot / goal-root 模式 / 引擎版本 marker） |
| `tests/test-dashboard-config.mjs` | ✅ 75/75 零改动 |
| `tests/test-dashboard-page-contract.mjs` | ✅ 69/69 零改动 |
| `tests/test-config-acceptance.mjs` | ✅ 90/90 零改动 |
| `tests/test-dashboard.mjs` | ✅ 134/134 零改动 |
| 函数长度门禁（qa/n4-func-len.mjs 同口径，8 文件全量） | ✅ 新/改函数全 ≤50（runUxSync 40、readEngineVersion 8、五辅助 ≤18）；剩 2 超限 = M1 备忘对（server.mjs，本次未触及，见裁量 3） |
| 真根只读冒烟（run 目录 `dev/n5-smoke.mjs` → `dev/n5-smoke.log`） | ✅ 10/10、exit 0：GET /config 渲染 GoalRoot+完整措辞+`rdd-engine/package.json（引擎版本 1.1.0）`；API 行形状（shared 归属/只读/infoOnly/无 probe/版本=引擎包实值）；护栏（8 defs/30 items、无 L1-L5 黑话、公用 7、可写 4） |

D1/D2 复验口径提示（供 QA 复跑）：`grep -c GoalRoot rdd-engine/dashboard` → 1+（原 0）；`grep -c "package.json" rdd-engine/dashboard` → 1+（原 0）；`node .rdd/goal-trees/ops-config-panel-r2/qa/n4-func-len.mjs` → 仅剩 M1 两 OVER。

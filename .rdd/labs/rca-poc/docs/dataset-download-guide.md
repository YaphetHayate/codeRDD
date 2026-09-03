# OpenRCA 遥测数据下载指导书

> 目的:为 L2 阶段(pilot + 批量)获取 OpenRCA 遥测数据。git 仓(`datasets/OpenRCA/`)只含评测 harness,**数据在 Google Drive 外置**。
> 官方要求(仓 README):全量数据建议 **≥80GB 磁盘 + 32GB 内存**——本 PoC 不需要全量,按 §2 最小集策略下载。
> 官方链接:`https://drive.google.com/drive/folders/1wGiEnu4OkWrjPxfx5ZTROnU37-5UDoPM`

## 1. 数据长什么样(官方 README 给出的结构)

```
{SYSTEM}/                     # Telecom | Bank | Market(Market 下分 cloudbed-1 / cloudbed-2)
├── query.csv                 # 查询集:现象描述(symptom 来源)+ 评估字段
├── record.csv                # 故障记录:根因真值(UTC+8 时区!)——PoC 的答案托管来源,严禁进 plane
└── telemetry/
    └── {YYYY_MM_DD}/         # 按日期组织
        ├── log/              # 半结构化日志
        ├── metric/           # KPI 时间序列
        └── trace/            # 依赖调用链(trace 图)
```

- 真值字段形态(评估口径):`root cause occurrence datetime` / `root cause component` / `root cause reason`
- FAQ 要点:遥测有固定采样频率,真值时间戳上未必恰有采样点;网络类故障常需看 trace 的父子 span 时延关系

## 2. 下载策略:最小集起步(重要)

| 级别 | 内容 | 体积量级 | 用途 |
|------|------|----------|------|
| **A. pilot 最小集(推荐先做)** | 单个 SYSTEM 的:query.csv + record.csv + telemetry 下**一个日期目录** | 数百 MB~数 GB | §2 pilot 校准 + 首个案例可解性验证 |
| B. L2 批量集 | 单个 SYSTEM 全量(或 2 个 SYSTEM) | 数 GB~数十 GB | 5~10 案例改装回放 |
| C. 全量 | Telecom + Bank + Market ×2 | 数十 GB+(官方建议 80GB 盘) | 本 PoC 不需要 |

先在 Drive 里浏览文件夹确认实际切分层级(预期按 SYSTEM → telemetry → 日期;以实际为准),**只勾选目标日期目录与两个 csv**。

## 3. 方式 A:浏览器下载(默认路径)

1. 浏览器打开上方 Drive 链接(公开分享,一般无需登录;若提示登录,用任意 Google 账号即可);
2. 进入目标 `{SYSTEM}` → 先单独下载 `query.csv` 与 `record.csv`(右键/三点菜单 → 下载);
3. 进入 `telemetry/{YYYY_MM_DD}` → 全选 → 右键 → 下载(Drive 会自动打 zip);
4. 注意:
   - 单次 zip 超过约 2GB 时 Drive 会**拆成多个分卷 zip**,需全部下载后逐个解压到同一目录;
   - Drive 对匿名下载有**每日配额**,超限会报"下载配额已用尽"——等 24h 或换账号重试;
   - 若网络无法直连 Google,需在可访问的网络环境完成下载,再拷贝到本机(见 §6)。

## 4. 方式 B:命令行(rclone,适合大体积/批量)

```powershell
# 安装(rclone 单文件工具):https://rclone.org/downloads/ 解压后置于 PATH
# 公共文件夹无需 OAuth,用链接 id 直接列目录(--drive-root-folder-id 即链接末段)
rclone lsd :drive: --drive-root-folder-id 1wGiEnu4OkWrjPxfx5ZTROnU37-5UDoPM
# 沿层级下钻确认子目录名(把 <id> 换成上一级列出的目录 id)
rclone lsd :drive: --drive-root-folder-id <id>
# 下载选定子目录到本地(--progress 看进度;--drive-server-side-across-configs 处理大文件)
rclone copy :drive: --drive-root-folder-id <日期目录id> D:\YaphetHayate\projects\codeRDD\.rdd\labs\rca-poc\datasets\OpenRCA-data\Bank\telemetry\2023_xx_xx --progress
```

> gdown(`pip install gdown` + `gdown --folder <链接>`)也可,但文件夹超过 50 个文件会被 Drive API 截断,本数据集大概率超限——优先 rclone。

## 5. 置入规范(下载完成后)

目标布局(数据与 harness 仓分离,`datasets/OpenRCA/` 保持只读):

```
.rdd/labs/rca-poc/datasets/OpenRCA-data/     ← 新建,数据统一放这里
└── Bank/                                    ← {SYSTEM}
    ├── query.csv
    ├── record.csv
    └── telemetry/2023_xx_xx/{log,metric,trace}
```

- 保持 Drive 内原始目录名与层级,**不重命名**;
- `datasets/` 已被 gitignore,数据不入库、不建 submodule;
- 置入后视为只读素材;`record.csv` 是根因真值,后续 pilot 中只进 `analysis/scoring/answers.jsonl` 托管,绝不进 `cases/*/plane/`。

## 6. 校验清单(置入后逐项确认)

1. **结构自查**:目录树与 §1 预期一致;zip 分卷已全部解压且无残留 `.zip`;`Get-ChildItem -Recurse -File | Measure-Object` 记录文件总数备查;
2. **csv 可读**:`query.csv`/`record.csv` 能以 UTF-8 打开,行数 > 0;
3. **探测验证**(衔接 runbook §2 pilot 的 ADAPTER 校准入口):
   ```powershell
   node .rdd/labs/rca-poc/tools/convert-openrca.mjs --probe .rdd/labs/rca-poc/datasets/OpenRCA-data/Bank
   ```
   输出 `meta_file`/`top_level`/`candidates` 供校准 ADAPTER 参考(注意:OpenRCA 的 query/record 是 csv 而非设计预想的 incident.json——**这正是预期中的 pilot 校准点**,ADAPTER 需按实际结构增加 csv 元数据源支持);
4. **答案隔离预检**:确认 `record.csv` 只存在于 `datasets/OpenRCA-data/` 与(改装后的)`analysis/scoring/answers.jsonl`,`cases/` 下无副本。

## 7. 常见问题

| 现象 | 处置 |
|------|------|
| Drive 提示配额用尽 / 无法下载 | 等 24h、换账号,或改用 rclone 分日分批 |
| zip 多分卷解压失败 | 确认所有分卷齐全后用 7-Zip/"全部解压",缺卷会报 CRC 错 |
| 时间对不上(真值时刻查无数据) | 真值为 UTC+8;且遥测有采样间隔,查最近采样点(官方 FAQ) |
| 本机网络不可达 Google | 在可达环境完成 §3/§4 下载,移动硬盘/内网拷贝回 `datasets/OpenRCA-data/` |
| 磁盘不足 | 只下载 §2-A 最小集;批量前清理 telemetry 中不用的日期目录 |

## 8. 完成标志

`datasets/OpenRCA-data/<SYSTEM>/` 结构通过 §6 校验 → 在 `analysis/observations.md` §6 追加一行事件(日期 + SYSTEM + 日期目录 + 文件数)→ 按 `prompts/l2-l3-runbook.md` §2 进入 pilot:probe → 校准 ADAPTER → 单案例转换 → 双向校准 → preflight → 编排臂试跑。

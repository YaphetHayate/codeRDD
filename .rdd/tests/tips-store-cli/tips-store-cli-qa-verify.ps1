# tips-store-cli QA 黑盒探针 — tips 存储与 CLI 记录/查询/扩散（archive 2026-10-06-role-tips-mechanism）
#
# QA 独立验收套件（与 DEV 的 rdd-engine/tests/test-tips.ps1 相互独立、零共享代码）：
# 用例源于 requirements/tips-storage-cli.md 的验收标准 + 任务 #2（tips-startup-injection）
# 落地的 CLI 契约演进（2026-10-06 用户裁决：记录即归属 + target 有机扩散 + ALL 哨兵移除），
# 经文档化 CLI 接口（capability-manifest.md「tips 记录/查询/扩散」）黑盒驱动生产解释器
# （Windows PowerShell 5.1）：tips.ps1 直驱 + tips.cmd 全链（chcp 65001）双 leg。场景组各自
# 使用独立一次性存储根（RDD_PROJECT_ROOT 定位链第一环指向 %TEMP% 子目录），互不依赖执行
# 顺序，零真仓污染。退出码 0 = 全绿。
#
# TC 编号与 .rdd/tests/tips-store-cli/cases.json 一一对应（TC-005..TC-125，步长 5；
# TC-025/TC-030/TC-080 已随旧「目标角色输入/ALL 哨兵」契约废弃，由 TC-095..TC-125 取代）。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:ToolPs1 = Join-Path $Script:RepoRoot 'rdd-engine\scripts\tips.ps1'
$Script:ToolCmd = Join-Path $Script:RepoRoot 'rdd-engine\scripts\tips.cmd'
$Script:Work = Join-Path $env:TEMP ('tips-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-TipsPs1 { param([string[]]$ArgList)
    # 生产解释器直驱 leg。native stderr 在 EAP=Stop 下会抛 NativeCommandError
    # （PS 5.1 已知陷阱），调用窗口内降为 Continue。
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ToolPs1) + $ArgList
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& powershell @all 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $json = $null
    try { $json = $raw | ConvertFrom-Json } catch { }
    return @{ exit = $code; raw = $raw; json = $json }
}

function Invoke-TipsCmd { param([string[]]$ArgList)
    # cmd 薄壳全链 leg（chcp 65001）；参数保持纯 ASCII，中文一律走 -File 字节通道。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& cmd /c $script:ToolCmd @ArgList 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $json = $null
    try { $json = $raw | ConvertFrom-Json } catch { }
    return @{ exit = $code; raw = $raw; json = $json }
}

function New-Store { param([string]$Name)
    # 每个场景组独立存储根：用例间零依赖（测试设计原则），失败也不会串扰。
    $root = Join-Path $script:Work $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $env:RDD_PROJECT_ROOT = $root
    return $root
}

function Get-EntryCount { param([string]$Root)
    $dir = Join-Path $Root '.rdd\tips\entries'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json').Count
}

function Read-EntryJson { param([string]$AbsPath)
    return ([System.IO.File]::ReadAllText($AbsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Resolve-InStore { param([string]$Root, [string]$RelForwardSlash)
    return (Join-Path $Root ($RelForwardSlash -replace '/', '\'))
}

function Write-Payload { param([string]$Path, [string]$Text)
    # 手造字面 CJK JSON（不经 ConvertTo-Json —— PS 5.1 会 \u 转义，掩蔽原始
    # CJK 字节解码这条真实现场路径），UTF-8 无 BOM。
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# 中文夹具：本套件带 BOM，PS 5.1 正确解析；进入被测 CLI 只经 -File payload 字节。
$ZhTitle = '中文标题：无 BOM 中文脚本解析错位'
$ZhProblem = '问题描述：UTF-8 无 BOM 的中文 .ps1 在 PS 5.1 下解析错位，静默吞函数定义'
$ZhAvoid = '规避：含中文的 .ps1 一律 UTF-8 with BOM 保存'
$ZhTitle2 = '第二条中文 tip：cmd 传参链禁中文'
$ZhProblem2 = '问题描述：cmd 到 powershell 的参数链经转码，中文必乱码'
$ZhAvoid2 = '规避：中文内容走 -File 文件通道'

$prevRoot = $env:RDD_PROJECT_ROOT
New-Item -ItemType Directory -Path $Work -Force | Out-Null

try {
    # ---------- S0：本套件自身 BOM 自检（§6.1 含中文 .ps1 必须带 BOM） ----------
    $selfBom = [System.IO.File]::ReadAllBytes($PSCommandPath)[0..2]
    Assert-True ($selfBom[0] -eq 239 -and $selfBom[1] -eq 187 -and $selfBom[2] -eq 191) 'S0 self BOM (zh suite saved UTF-8 with BOM)' ("first3=$($selfBom -join ',')")

    # ---------- TC-005（AC-1+2 正向）：完整字段 inline add 落盘 + 元数据（记录即归属） ----------
    $root = New-Store 'tc005'
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'ascii title one', '-Problem', 'problem text', '-Avoidance', 'avoidance text')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.recorded -eq $true) 'TC-005 inline add: exit 0 + success envelope + recorded' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ($r.json.data.path -match '^\.rdd/tips/entries/[^/]+\.json$') 'TC-005 persisted under .rdd/ prefix (repo-relative pointer)' ("path=$($r.json.data.path)")
    $entryAbs = Resolve-InStore $root ([string]$r.json.data.path)
    Assert-True (Test-Path -LiteralPath $entryAbs -PathType Leaf) 'TC-005 entry file exists on disk' ("path=$entryAbs")
    $e = Read-EntryJson $entryAbs
    Assert-True ($e.title -eq 'ascii title one' -and $e.problem -eq 'problem text' -and $e.avoidance -eq 'avoidance text') 'TC-005 entry content: three required fields intact' ($e | ConvertTo-Json -Compress)
    Assert-True ($e.recordedBy -eq 'DEV' -and $e.recordedAt -match '^\d{4}-\d{2}-\d{2}T[\d:.]+Z$') 'TC-005 metadata: recorder role + ISO-UTC timestamp' ($e | ConvertTo-Json -Compress)
    Assert-True ((@($e.roles) -join ',') -eq 'DEV' -and (@($r.json.data.roles) -join ',') -eq 'DEV' -and (Get-EntryCount $root) -eq 1) 'TC-005 record-then-own: envelope and file both stamp roles=[DEV]' ($e | ConvertTo-Json -Compress)

    # ---------- TC-010/015/020/035（AC-1 反向）：缺必填/非法 -By → 显式报错、不落盘 ----------
    $neg = New-Store 'neg'
    $negCases = @(
        @{ tc = 'TC-010'; code = 'MISSING_TITLE';     args = @('-By', 'DEV', '-Problem', 'p', '-Avoidance', 'a') },
        @{ tc = 'TC-015'; code = 'MISSING_PROBLEM';   args = @('-By', 'DEV', '-Title', 't', '-Avoidance', 'a') },
        @{ tc = 'TC-020'; code = 'MISSING_AVOIDANCE'; args = @('-By', 'DEV', '-Title', 't', '-Problem', 'p') },
        @{ tc = 'TC-035'; code = 'MISSING_BY';        args = @('-Title', 't', '-Problem', 'p', '-Avoidance', 'a') },
        @{ tc = 'TC-035'; code = 'INVALID_ROLE';      args = @('-By', 'GODZILLA', '-Title', 't', '-Problem', 'p', '-Avoidance', 'a') }
    )
    foreach ($case in $negCases) {
        $r = Invoke-TipsPs1 (@('-Command', 'add') + @($case.args))
        Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq $case.code) ("{0} rejects {1}: exit 1 + explicit error code" -f $case.tc, $case.code) ("exit=$($r.exit) raw=$($r.raw)")
    }
    # 空白字段值等价于缺失（等价类补全，QA 独立增量：DEV 套件未覆盖）
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', '   ', '-Problem', 'p', '-Avoidance', 'a')
    Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq 'MISSING_TITLE') 'TC-010 whitespace-only Title rejected as missing' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ((Get-EntryCount $neg) -eq 0) 'TC-010..035 negative battery wrote nothing (no partial entries)' ("count=$(Get-EntryCount $neg)")

    # ---------- TC-095（契约演进回归钉定）：-Roles 参数已摘除 → 参数绑定失败，无信封 ----------
    $root = New-Store 'tc095'
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 't', '-Problem', 'p', '-Avoidance', 'a', '-Roles', 'DEV,QA')
    Assert-True ($r.exit -ne 0 -and $null -eq $r.json) 'TC-095 legacy -Roles param: binding failure, exit != 0, no JSON envelope' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ((Get-EntryCount $root) -eq 0) 'TC-095 rejected legacy param wrote nothing' ("count=$(Get-EntryCount $root)")

    # ---------- TC-100（契约演进）：payload roles 键拒绝并指路 target ----------
    Write-Payload (Join-Path $root 'roles-key.json') '{"title":"t","problem":"p","avoidance":"a","roles":["DEV","QA"]}'
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-File', (Join-Path $root 'roles-key.json'))
    Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq 'PAYLOAD_INVALID') 'TC-100 payload roles key rejected (record-then-own owns targeting)' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ($r.json.error.message -match 'target') 'TC-100 error message points to the target subcommand' ($r.json.error.message)
    Assert-True ((Get-EntryCount $root) -eq 0) 'TC-100 rejected payload wrote nothing' ("count=$(Get-EntryCount $root)")

    # ---------- TC-040（AC-3 正向）：roles∋R 过滤命中、未标注不出现（记录即归属下） ----------
    $root = New-Store 'tc040'
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'dev targeted tip', '-Problem', 'p', '-Avoidance', 'a')
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'PM', '-Title', 'pm targeted tip', '-Problem', 'p', '-Avoidance', 'a')
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'DEV')
    $titles = @($r.json.data.entries | ForEach-Object { $_.title })
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 1 -and $titles -contains 'dev targeted tip') 'TC-040 DEV filter: DEV-owned entry present' ($r.raw)
    Assert-True ($titles -notcontains 'pm targeted tip') 'TC-040 DEV filter: entry without DEV absent' (($titles -join '|'))
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'PM')
    Assert-True ($r.json.data.count -eq 1 -and (@($r.json.data.entries | ForEach-Object { $_.title }) -contains 'pm targeted tip')) 'TC-040 PM filter symmetric hit' ($r.raw)

    # ---------- TC-045（AC-3 正向）：无过滤 = 全量 ----------
    $r = Invoke-TipsPs1 @('-Command', 'list')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 2 -and @($r.json.data.entries).Count -eq 2) 'TC-045 unfiltered list returns every entry' ($r.raw)

    # ---------- TC-050（AC-4 正向）：空库返回空结果而非报错 ----------
    $root = New-Store 'tc050'
    $r = Invoke-TipsPs1 @('-Command', 'list')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.count -eq 0) 'TC-050 empty store: list -> exit 0, count 0, not an error' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'DEV')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 0) 'TC-050 empty store: filtered list -> count 0, not an error' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsCmd @('-Command', 'list')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 0) 'TC-050 empty store via cmd chain: count 0' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- TC-055（AC-5 正向）：中文经 -File 通道，ps1 leg 全程零乱码 ----------
    $root = New-Store 'tc055'
    $zhPayload = '{"title":"' + $ZhTitle + '","problem":"' + $ZhProblem + '","avoidance":"' + $ZhAvoid + '"}'
    Write-Payload (Join-Path $root 'zh.json') $zhPayload
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'qa', '-File', (Join-Path $root 'zh.json'))
    Assert-True ($r.exit -eq 0 -and $r.json.data.title -eq $ZhTitle) 'TC-055 zh -File add: envelope echoes title intact' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ($r.json.data.recordedBy -eq 'QA') 'TC-055 recorder role case-canonicalized (qa -> QA)' ($r.json.data | ConvertTo-Json -Compress)
    $zhEntry = Read-EntryJson (Resolve-InStore $root ([string]$r.json.data.path))
    Assert-True ($zhEntry.title -eq $ZhTitle -and $zhEntry.problem -eq $ZhProblem -and $zhEntry.avoidance -eq $ZhAvoid) 'TC-055 zh entry file decodes all CJK fields verbatim' ($zhEntry | ConvertTo-Json -Compress)
    Assert-True ((@($zhEntry.roles) -join ',') -eq 'QA') 'TC-055 record-then-own stamps the recorder (zh payload has no roles key)' ($zhEntry | ConvertTo-Json -Compress)
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'QA')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 1 -and $r.json.data.entries[0].title -eq $ZhTitle) 'TC-055 zh readback via list: zero mojibake' ($r.raw)

    # ---------- TC-060（AC-5 正向）：中文 cmd 全链（chcp 65001）零乱码 ----------
    $root = New-Store 'tc060'
    $zh2Payload = '{"title":"' + $ZhTitle2 + '","problem":"' + $ZhProblem2 + '","avoidance":"' + $ZhAvoid2 + '"}'
    Write-Payload (Join-Path $root 'zh2.json') $zh2Payload
    $r = Invoke-TipsCmd @('-Command', 'add', '-By', 'DEV', '-File', ((Join-Path $root 'zh2.json') -replace '/', '\'))
    Assert-True ($r.exit -eq 0 -and $r.json.data.title -eq $ZhTitle2) 'TC-060 cmd-chain zh add: title roundtrips' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsCmd @('-Command', 'list', '-Role', 'DEV')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 1 -and $r.json.data.entries[0].title -eq $ZhTitle2) 'TC-060 cmd-chain zh readback intact' ($r.raw)
    $zh2Entry = Read-EntryJson (Resolve-InStore $root ([string]$r.json.data.entries[0].path))
    Assert-True ($zh2Entry.problem -eq $ZhProblem2 -and $zh2Entry.avoidance -eq $ZhAvoid2) 'TC-060 zh entry file decodes verbatim after cmd chain' ($zh2Entry | ConvertTo-Json -Compress)

    # ---------- TC-065（AC-5+1 反向）：inline 通道中文显式拒绝，不产出乱码条目 ----------
    $root = New-Store 'tc065'
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', $ZhTitle, '-Problem', 'p', '-Avoidance', 'a')
    Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq 'NON_ASCII_INLINE') 'TC-065 inline zh rejected explicitly (garble channel sealed)' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ((Get-EntryCount $root) -eq 0) 'TC-065 rejected inline zh wrote nothing' ("count=$(Get-EntryCount $root)")

    # ---------- TC-070（边界·异常）：半损坏条目 fail-loud，指名文件，移除后恢复 ----------
    $root = New-Store 'tc070'
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'healthy tip', '-Problem', 'p', '-Avoidance', 'a')
    $corruptName = '99999999T999999Z-DEV-deadbeef.json'
    $corruptPath = Join-Path $root ('.rdd\tips\entries\' + $corruptName)
    Write-Payload $corruptPath '{ oops not json'
    $r = Invoke-TipsPs1 @('-Command', 'list')
    Assert-True ($r.exit -eq 3 -and $r.json.success -eq $false -and $r.json.error.code -eq 'CORRUPT_ENTRY' -and $r.json.error.message -match [regex]::Escape($corruptName)) 'TC-070 unparseable entry: exit 3 + corrupt code + file named' ("exit=$($r.exit) raw=$($r.raw)")
    Write-Payload $corruptPath '{"schema":"rdd-tip/1","id":"x"}'
    $r = Invoke-TipsPs1 @('-Command', 'list')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY') 'TC-070 structurally incomplete entry: fail-loud too' ("exit=$($r.exit) raw=$($r.raw)")
    Remove-Item -LiteralPath $corruptPath -Force
    $r = Invoke-TipsPs1 @('-Command', 'list')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 1) 'TC-070 store healthy again after removing broken file' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- TC-075（AC-2 边界）：新→旧排序 + recordedAt/ID 形态 ----------
    $root = New-Store 'tc075'
    foreach ($t in @('oldest tip', 'middle tip', 'newest tip')) {
        $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', $t, '-Problem', 'p', '-Avoidance', 'a')
    }
    $r = Invoke-TipsPs1 @('-Command', 'list')
    $titles = @($r.json.data.entries | ForEach-Object { $_.title })
    Assert-True ($r.json.data.count -eq 3 -and ($titles -join '|') -eq 'newest tip|middle tip|oldest tip') 'TC-075 list newest-first ordering' (($titles -join '|'))
    $idsMatch = $true
    foreach ($entry in @($r.json.data.entries)) {
        $abs = Resolve-InStore $root ([string]$entry.path)
        $disk = Read-EntryJson $abs
        if ($disk.id -ne $entry.id -or $disk.id -ne [System.IO.Path]::GetFileNameWithoutExtension($abs)) { $idsMatch = $false }
        if ($disk.recordedAt -notmatch '^\d{4}-\d{2}-\d{2}T[\d:.]+Z$') { $idsMatch = $false }
    }
    Assert-True $idsMatch 'TC-075 ids consistent with filenames + ISO-UTC timestamps' ($r.raw)

    # ---------- TC-085（AC-1 反向·P2）：未知 -Role 过滤值显式报错 ----------
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'GODZILLA')
    Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq 'INVALID_ROLE') 'TC-085 unknown -Role filter rejected explicitly' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- TC-090（边界）：重复记录不去重（第一版契约） ----------
    $root = New-Store 'tc090'
    $r1 = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'duplicate tip', '-Problem', 'p', '-Avoidance', 'a')
    $r2 = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'duplicate tip', '-Problem', 'p', '-Avoidance', 'a')
    Assert-True ($r1.exit -eq 0 -and $r2.exit -eq 0 -and (Get-EntryCount $root) -eq 2) 'TC-090 identical content recorded twice -> 2 entries (no dedup)' ("count=$(Get-EntryCount $root)")
    Assert-True ($r1.json.data.id -ne $r2.json.data.id) 'TC-090 duplicate entries carry distinct ids' ("id1=$($r1.json.data.id) id2=$($r2.json.data.id)")

    # ---------- TC-105（契约演进正向）：target 增补——归属扩散、归一、落盘一致、元数据不动 ----------
    $root = New-Store 'tc105'
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'spreadable tip', '-Problem', 'p', '-Avoidance', 'a')
    $tipId = [string]$r.json.data.id
    $beforeEntry = Read-EntryJson (Resolve-InStore $root ([string]$r.json.data.path))
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', $tipId, '-By', 'qa')
    Assert-True ($r.exit -eq 0 -and $r.json.data.targeted -eq $true -and $r.json.data.appended -eq $true -and (@($r.json.data.roles) -join ',') -eq 'DEV,QA') 'TC-105 target -By qa: appended, canonicalized, roles DEV,QA' ("exit=$($r.exit) raw=$($r.raw)")
    $afterEntry = Read-EntryJson (Resolve-InStore $root ('.rdd/tips/entries/' + $tipId + '.json'))
    Assert-True ((@($afterEntry.roles) -join ',') -eq 'DEV,QA' -and (Get-EntryCount $root) -eq 1) 'TC-105 disk entry rewritten with the appended role (no extra files)' ($afterEntry | ConvertTo-Json -Compress)
    Assert-True ($afterEntry.recordedBy -eq $beforeEntry.recordedBy -and $afterEntry.recordedAt -eq $beforeEntry.recordedAt -and $afterEntry.problem -eq $beforeEntry.problem) 'TC-105 untouched fields stay byte-stable (recorder/timestamp/content)' ($afterEntry | ConvertTo-Json -Compress)
    Assert-True ($r.json.data.title -eq 'spreadable tip' -and $r.json.data.path -eq ('.rdd/tips/entries/' + $tipId + '.json')) 'TC-105 envelope echoes title + repo-relative pointer' ($r.json.data | ConvertTo-Json -Compress)

    # ---------- TC-110（契约演进边界）：target 幂等——已含角色成功且零重写 ----------
    $entryAbs = Resolve-InStore $root ('.rdd/tips/entries/' + $tipId + '.json')
    $bytesBefore = [System.IO.File]::ReadAllBytes($entryAbs)
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', $tipId, '-By', 'QA')
    Assert-True ($r.exit -eq 0 -and $r.json.data.appended -eq $false -and (@($r.json.data.roles) -join ',') -eq 'DEV,QA') 'TC-110 already-member target: success echo with appended=false' ("exit=$($r.exit) raw=$($r.raw)")
    $bytesAfter = [System.IO.File]::ReadAllBytes($entryAbs)
    $bytesEqual = ($bytesBefore.Length -eq $bytesAfter.Length)
    if ($bytesEqual) { for ($i = 0; $i -lt $bytesBefore.Length; $i++) { if ($bytesBefore[$i] -ne $bytesAfter[$i]) { $bytesEqual = $false; break } } }
    Assert-True $bytesEqual 'TC-110 idempotent target rewrites nothing (byte-identical file)' ("len=$($bytesBefore.Length)->$($bytesAfter.Length)")

    # ---------- TC-115（契约演进反向）：target 校验链 + 路径形状防御 ----------
    $root = New-Store 'tc115'
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'anchor tip', '-Problem', 'p', '-Avoidance', 'a')
    $r = Invoke-TipsPs1 @('-Command', 'target', '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_ID') 'TC-115 missing -Id rejected first' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', 'whatever')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_BY') 'TC-115 missing -By rejected next' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', 'whatever', '-By', 'GODZILLA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_ROLE') 'TC-115 unknown -By role rejected' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', '20990101T000000Z-DEV-0000', '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TIP_NOT_FOUND') 'TC-115 nonexistent id rejected' ("exit=$($r.exit) raw=$($r.raw)")
    foreach ($smuggled in @('..\leak', 'sub/inner')) {
        $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', $smuggled, '-By', 'QA')
        Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TIP_NOT_FOUND') ("TC-115 path-shape guard: id '{0}' -> same TIP_NOT_FOUND verdict" -f $smuggled) ("exit=$($r.exit) raw=$($r.raw)")
    }
    $leaked = (Test-Path (Join-Path $root '.rdd\tips\leak.json')) -or (Test-Path (Join-Path $root '.rdd\tips\entries\sub'))
    Assert-True ((-not $leaked) -and (Get-EntryCount $root) -eq 1) 'TC-115 nothing probed or written outside the store' ("count=$(Get-EntryCount $root) leaked=$leaked")

    # ---------- TC-120（契约演进异常）：遗留 ALL 形态条目判 CORRUPT（list 与 target 双路） ----------
    $root = New-Store 'tc120'
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'healthy', '-Problem', 'p', '-Avoidance', 'a')
    $allName = '20990101T000001Z-PM-all0001.json'
    Write-Payload (Join-Path $root ('.rdd\tips\entries\' + $allName)) '{"schema":"rdd-tip/1","id":"20990101T000001Z-PM-all0001","title":"legacy all","problem":"p","avoidance":"a","roles":["ALL"],"recordedBy":"PM","recordedAt":"2099-01-01T00:00:01.000Z","deprecated":false}'
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'EVAL')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY' -and $r.json.error.message -match [regex]::Escape($allName)) 'TC-120 legacy ALL entry judged corrupt by list (sentinel gone), file named' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', '20990101T000001Z-PM-all0001', '-By', 'QA')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY') 'TC-120 target on the legacy ALL entry fails loud too (exit 3)' ("exit=$($r.exit) raw=$($r.raw)")
    Remove-Item -LiteralPath (Join-Path $root ('.rdd\tips\entries\' + $allName)) -Force
    $r = Invoke-TipsPs1 @('-Command', 'list', '-Role', 'EVAL')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 0) 'TC-120 store healthy again after removing the legacy entry' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- TC-125（契约演进正向）：target cmd 全链（chcp 65001） ----------
    $root = New-Store 'tc125'
    $r = Invoke-TipsCmd @('-Command', 'add', '-By', 'DEV', '-Title', 'cmd spread tip', '-Problem', 'p', '-Avoidance', 'a')
    $cmdTipId = [string]$r.json.data.id
    $r = Invoke-TipsCmd @('-Command', 'target', '-Id', $cmdTipId, '-By', 'EVAL')
    Assert-True ($r.exit -eq 0 -and $r.json.data.appended -eq $true -and (@($r.json.data.roles) -join ',') -eq 'DEV,EVAL') 'TC-125 cmd-chain target: appended across the full chain' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- 交叉：每条 list 输出的 path 指针均可读可达（消费方契约） ----------
    $r = Invoke-TipsPs1 @('-Command', 'list')
    $allReachable = $true
    foreach ($entry in @($r.json.data.entries)) {
        if (-not (Test-Path -LiteralPath (Resolve-InStore $root ([string]$entry.path)) -PathType Leaf)) { $allReachable = $false }
    }
    Assert-True ($r.exit -eq 0 -and $allReachable) 'X-path every listed path pointer resolves to a real file' ($r.raw)
}
finally {
    if ($null -eq $prevRoot) { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue }
    else { $env:RDD_PROJECT_ROOT = $prevRoot }
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

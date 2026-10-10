# tips acceptance tests — tips 存储与 CLI + 启动定向注入（archive 2026-10-06-role-tips-mechanism）
#
# 驱动生产解释器（Windows PowerShell 5.1）经 tips.ps1 与 tips.cmd 双入口，
# 以 RDD_PROJECT_ROOT 显式覆盖（项目根定位链第一环）指向 %TEMP% 一次性项
# 目根实现完全隔离（test-code-metrics 先例；绝不污染 .rdd/changes）。断言集
# 随 2026-10-06 定向新语义更新：记录即归属（add 无目标输入，新条目恒
# roles=[-By]）+ target 有机扩散（幂等）+ ALL 哨兵移除（shape 校验判损坏）；
# 保留空库 + 半损坏 fail-loud + BOM 自举断言（决策 #8：write 工具抹 BOM →
# PS 5.1 中文静默解析失败正是催生本需求的坑，测试层防复发）。
# 退出码 0 = 全绿。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot
$ToolPs1 = Join-Path $EngineDir 'scripts\tips.ps1'
$ToolCmd = Join-Path $EngineDir 'scripts\tips.cmd'
$Work = Join-Path $env:TEMP ('tips-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# Native stderr under EAP=Stop raises NativeCommandError in PS5.1 (same
# defense as test-code-metrics Invoke-Metrics).
function Invoke-Tips { param([string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolPs1) + $ArgList
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& powershell @all 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $json = $null
    try { $json = $raw | ConvertFrom-Json } catch { }
    return @{ exit = $code; raw = $raw; json = $json }
}

# Full cmd-chain leg (chcp 65001 thin shell): args stay pure ASCII — Chinese
# travels via the -File payload, mirroring the sanctioned real-world usage.
function Invoke-TipsCmd { param([string[]]$ArgList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& cmd /c $ToolCmd @ArgList 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $json = $null
    try { $json = $raw | ConvertFrom-Json } catch { }
    return @{ exit = $code; raw = $raw; json = $json }
}

function Get-EntryCount {
    $dir = Join-Path $script:Work '.rdd\tips\entries'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json').Count
}

function Resolve-InWork { param([string]$RelForwardSlash)
    return (Join-Path $script:Work ($RelForwardSlash -replace '/', '\'))
}

# Chinese fixtures live HERE (the test file is BOM'd, PS 5.1 parses them
# correctly) and travel into the tool only through -File payload bytes.
$ZhTitle    = '中文标题：PS 5.1 无 BOM 中文脚本解析错位'
$ZhProblem  = '无 BOM 的 UTF-8 中文 .ps1 在 Windows PowerShell 5.1 下中文字节使解析器错位，静默吞掉后续函数定义'
$ZhAvoid    = '含中文的 .ps1 一律保存为 UTF-8 with BOM（首 3 字节 239,187,191）'
$ZhTitle2   = '第二条中文 tip：cmd 传参链禁中文'

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$TmpDir = Join-Path $Work '.rdd\tmp'
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
$prevRoot = $env:RDD_PROJECT_ROOT
$env:RDD_PROJECT_ROOT = $Work

# Hand-built literal-Chinese payload (NOT ConvertTo-Json: PS 5.1 would
# \u-escape and the raw-CJK-byte decode leg would go silent). Record-then-own:
# NO roles key — targeting is CLI-stamped (roles = [-By]).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ZhPayloadPath  = Join-Path $TmpDir 'payload-zh.json'
$Zh2PayloadPath = Join-Path $TmpDir 'payload-zh2.json'
$zhText  = '{"title":"' + $ZhTitle + '","problem":"' + $ZhProblem + '","avoidance":"' + $ZhAvoid + '"}'
$zh2Text = '{"title":"' + $ZhTitle2 + '","problem":"cmd 到 powershell 的参数链经转码中文必乱码","avoidance":"中文内容走 -File 文件通道"}'
[System.IO.File]::WriteAllText($ZhPayloadPath, $zhText, $Utf8NoBom)
[System.IO.File]::WriteAllText($Zh2PayloadPath, $zh2Text, $Utf8NoBom)

# ASCII error-path payloads
$BadPayloads = @{
    'malformed.json'   = '{ not json'
    'with-roles.json'  = '{"title":"t","problem":"p","avoidance":"a","roles":["DEV"]}'
    'unknown-key.json' = '{"title":"t","problem":"p","avoidance":"a","note":"x"}'
}
foreach ($name in $BadPayloads.Keys) {
    [System.IO.File]::WriteAllText((Join-Path $TmpDir $name), [string]$BadPayloads[$name], $Utf8NoBom)
}

try {
    # ---------- S0: BOM self-assert on the tool (decision #8) ----------
    $bom = [System.IO.File]::ReadAllBytes($ToolPs1)[0..2]
    Assert-True ($bom[0] -eq 239 -and $bom[1] -eq 187 -and $bom[2] -eq 191) 'S0 tips.ps1 saved as UTF-8 with BOM' ("first3=$($bom -join ',')")

    # ---------- S1: empty store (acceptance 4) ----------
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.count -eq 0) 'S1 empty store: list -> exit 0, count 0' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'list', '-Role', 'DEV')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 0) 'S1 empty store: filtered list -> count 0, not an error' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- S2: inline ASCII add — record-then-own (acceptance 1+2) ----------
    $r = Invoke-Tips @('-Command', 'add', '-By', 'DEV', '-Title', 'ascii tip one', '-Problem', 'p1', '-Avoidance', 'a1')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.recorded -eq $true) 'S2 inline add succeeds (no -Roles anywhere)' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ($r.json.data.path -match '^\.rdd/tips/entries/\d{8}T\d{6}Z-DEV-[0-9a-f]{4}\.json$') 'S2 entry path: repo-relative pointer, id = stamp-DEV-hex' ("path=$($r.json.data.path)")
    $entryFull = Resolve-InWork ([string]$r.json.data.path)
    Assert-True (Test-Path -LiteralPath $entryFull -PathType Leaf) 'S2 entry file exists on disk' ("path=$entryFull")
    $entryBytes = [System.IO.File]::ReadAllBytes($entryFull)
    Assert-True ($entryBytes[0] -ne 239) 'S2 entry file stored UTF-8 without BOM' ("first=$($entryBytes[0])")
    $entryObj = ([System.IO.File]::ReadAllText($entryFull, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ($entryObj.schema -eq 'rdd-tip/2' -and $entryObj.deprecated -eq $false -and $entryObj.recordedBy -eq 'DEV') 'S2 entry schema/recordedBy/deprecated stamped by CLI' ($entryObj | ConvertTo-Json -Compress)
    Assert-True ($entryObj.status -eq 'latent' -and $entryObj.count -eq 1 -and @($entryObj.collidedBy).Count -eq 0 -and $r.json.data.status -eq 'latent' -and $r.json.data.count -eq 1) 'S2 v2 birth: latent, count=1, empty collidedBy (file + envelope)' ($entryObj | ConvertTo-Json -Compress)
    Assert-True (@($r.json.data.candidates).Count -eq 0) 'S2 first add into an empty store: candidates=[]' ($r.raw)
    $firstId = [string]$r.json.data.id
    Assert-True ((@($entryObj.roles) -join ',') -eq 'DEV' -and (@($r.json.data.roles) -join ',') -eq 'DEV') 'S2 record-then-own: entry roles = [-By] (file + envelope)' ($entryObj | ConvertTo-Json -Compress)
    Assert-True ($entryObj.id -eq [System.IO.Path]::GetFileNameWithoutExtension($entryFull) -and $entryObj.recordedAt -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'S2 entry id/recordedAt complete' ($entryObj | ConvertTo-Json -Compress)

    # ---------- S3: validation battery — fail-loud, nothing hits disk (acceptance 1) ----------
    $cases = @(
        @{ name = 'MISSING_BY';         args = @('-Title', 't', '-Problem', 'p', '-Avoidance', 'a') },
        @{ name = 'INVALID_ROLE';       args = @('-By', 'GODZILLA', '-Title', 't', '-Problem', 'p', '-Avoidance', 'a') },
        @{ name = 'MISSING_TITLE';      args = @('-By', 'DEV', '-Problem', 'p', '-Avoidance', 'a') },
        @{ name = 'MISSING_PROBLEM';    args = @('-By', 'DEV', '-Title', 't', '-Avoidance', 'a') },
        @{ name = 'MISSING_AVOIDANCE';  args = @('-By', 'DEV', '-Title', 't', '-Problem', 'p') },
        @{ name = 'NON_ASCII_INLINE';   args = @('-By', 'DEV', '-Title', $ZhTitle, '-Problem', 'p', '-Avoidance', 'a') },
        @{ name = 'DUAL_CHANNEL';       args = @('-By', 'DEV', '-File', $ZhPayloadPath, '-Title', 't') },
        @{ name = 'PAYLOAD_NOT_FOUND';  args = @('-By', 'DEV', '-File', (Join-Path $TmpDir 'missing.json')) },
        @{ name = 'PAYLOAD_INVALID';    args = @('-By', 'DEV', '-File', (Join-Path $TmpDir 'malformed.json')) },
        @{ name = 'PAYLOAD_INVALID';    args = @('-By', 'DEV', '-File', (Join-Path $TmpDir 'with-roles.json')) },
        @{ name = 'PAYLOAD_INVALID';    args = @('-By', 'DEV', '-File', (Join-Path $TmpDir 'unknown-key.json')) }
    )
    foreach ($case in $cases) {
        $r = Invoke-Tips (@('-Command', 'add') + @($case.args))
        Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq $case.name) ("S3 add rejects: $($case.name)") ("exit=$($r.exit) raw=$($r.raw)")
    }
    $r = Invoke-Tips @('-Command', 'add', '-By', 'DEV', '-Title', 't', '-Problem', 'p', '-Avoidance', 'a', '-Roles', 'DEV')
    Assert-True ($r.exit -ne 0 -and $null -eq $r.json) 'S3 removed -Roles param: parameter binding fails, no envelope' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ((Get-EntryCount) -eq 1) 'S3 error battery wrote nothing (fail-loud, no partial entries)' ("count=$(Get-EntryCount)")

    # ---------- S4: Chinese via -File (ps1 leg) — record-then-own on -File channel ----------
    $r = Invoke-Tips @('-Command', 'add', '-By', 'qa', '-File', $ZhPayloadPath)
    Assert-True ($r.exit -eq 0 -and $r.json.data.title -eq $ZhTitle -and $r.json.data.recordedBy -eq 'QA') 'S4 zh -File add: title roundtrips, -By case-canonicalized' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True ((@($r.json.data.roles) -join ',') -eq 'QA') 'S4 zh -File add: record-then-own stamps roles=[QA]' ($r.raw)
    Assert-True ($r.json.data.path -match '-QA-[0-9a-f]{4}\.json$') 'S4 zh entry id carries canonical recorder role' ("path=$($r.json.data.path)")
    $zhEntry = ([System.IO.File]::ReadAllText((Resolve-InWork ([string]$r.json.data.path)), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ($zhEntry.title -eq $ZhTitle -and $zhEntry.problem -eq $ZhProblem -and $zhEntry.avoidance -eq $ZhAvoid) 'S4 zh entry file decodes all three CJK fields intact' ($zhEntry | ConvertTo-Json -Compress)
    Assert-True ((Get-EntryCount) -eq 2) 'S4 store count 2 after zh add' ("count=$(Get-EntryCount)")

    # ---------- S5: target — organic spread, idempotent, fail-loud chain ----------
    $r = Invoke-Tips @('-Command', 'add', '-By', 'CTO', '-Title', 'ascii cto tip', '-Problem', 'p', '-Avoidance', 'a')
    Assert-True ($r.exit -eq 0 -and (@($r.json.data.roles) -join ',') -eq 'CTO') 'S5 cto add: roles=[CTO] by record-then-own' ("exit=$($r.exit) raw=$($r.raw)")
    $ctoId = [string]$r.json.data.id
    $ctoPath = Resolve-InWork ([string]$r.json.data.path)
    Assert-True ((Get-EntryCount) -eq 3) 'S5 store count 3' ("count=$(Get-EntryCount)")
    $r = Invoke-Tips @('-Command', 'target', '-Id', $ctoId, '-By', 'qa')
    Assert-True ($r.exit -eq 0 -and $r.json.data.appended -eq $true -and (@($r.json.data.roles) -join ',') -eq 'CTO,QA' -and $r.json.data.recordedBy -eq 'CTO') 'S5 target appends role, keeps recorder' ("exit=$($r.exit) raw=$($r.raw)")
    $ctoEntry = ([System.IO.File]::ReadAllText($ctoPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ((@($ctoEntry.roles) -join ',') -eq 'CTO,QA' -and $ctoEntry.title -eq 'ascii cto tip' -and $ctoEntry.deprecated -eq $false) 'S5 entry file rewritten with extended roles' ($ctoEntry | ConvertTo-Json -Compress)
    Assert-True ([System.IO.File]::ReadAllBytes($ctoPath)[0] -ne 239) 'S5 rewritten entry stays UTF-8 without BOM' ('first=' + [System.IO.File]::ReadAllBytes($ctoPath)[0])
    $before = [System.IO.File]::ReadAllBytes($ctoPath)
    $r = Invoke-Tips @('-Command', 'target', '-Id', $ctoId, '-By', 'QA')
    $after = [System.IO.File]::ReadAllBytes($ctoPath)
    Assert-True ($r.exit -eq 0 -and $r.json.data.appended -eq $false -and (@($r.json.data.roles) -join ',') -eq 'CTO,QA') 'S5 target idempotent: already-member echoes success' ("exit=$($r.exit) raw=$($r.raw)")
    Assert-True (($before.Length -eq $after.Length) -and (-not (Compare-Object $before $after))) 'S5 idempotent target leaves the file untouched' ("before=$($before.Length)B after=$($after.Length)B")
    Assert-True ((Get-EntryCount) -eq 3) 'S5 target never creates entries' ("count=$(Get-EntryCount)")
    $r = Invoke-Tips @('-Command', 'target', '-Id', '20990101T000000Z-DEV-0000', '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TIP_NOT_FOUND') 'S5 target unknown id -> TIP_NOT_FOUND exit 1' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'target', '-Id', $ctoId, '-By', 'GODZILLA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_ROLE') 'S5 target unknown -By -> INVALID_ROLE' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'target', '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_ID') 'S5 target without -Id -> MISSING_ID' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'target', '-Id', $ctoId)
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_BY') 'S5 target without -By -> MISSING_BY' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- S6: filter semantics + ordering (acceptance 3; pure roles-contain-R) ----------
    $r = Invoke-Tips @('-Command', 'list')
    $titles = @($r.json.data.entries | ForEach-Object { $_.title })
    Assert-True ($r.json.data.count -eq 3) 'S6 unfiltered list returns every entry' ($r.raw)
    Assert-True (($titles -join '|') -eq ('ascii cto tip|' + $ZhTitle + '|ascii tip one')) 'S6 list newest-first ordering' (($titles -join '|'))
    $r = Invoke-Tips @('-Command', 'list', '-Role', 'DEV')
    $titles = @($r.json.data.entries | ForEach-Object { $_.title })
    Assert-True ($r.json.data.count -eq 1 -and ($titles -contains 'ascii tip one')) 'S6 DEV filter: exactly the DEV-recorded entry' (($titles -join '|'))
    $r = Invoke-Tips @('-Command', 'list', '-Role', 'QA')
    $titles = @($r.json.data.entries | ForEach-Object { $_.title })
    Assert-True ($r.json.data.count -eq 2 -and ($titles -contains $ZhTitle) -and ($titles -contains 'ascii cto tip')) 'S6 QA filter: QA-recorded + target-spread entry' (($titles -join '|'))
    $r = Invoke-Tips @('-Command', 'list', '-Role', 'PM')
    Assert-True ($r.json.data.count -eq 0) 'S6 PM filter: nothing (ALL sentinel gone)' ($r.raw)
    $r = Invoke-Tips @('-Command', 'list', '-Role', 'EVAL')
    Assert-True ($r.json.data.count -eq 0) 'S6 EVAL filter: nothing (no broadcast hits)' ($r.raw)
    $allPathsExist = $true
    $r = Invoke-Tips @('-Command', 'list')
    foreach ($e in @($r.json.data.entries)) { if (-not (Test-Path -LiteralPath (Resolve-InWork ([string]$e.path)))) { $allPathsExist = $false } }
    Assert-True $allPathsExist 'S6 every listed path is a Read-reachable pointer (n3 contract)' ($r.raw)
    $r = Invoke-Tips @('-Command', 'list', '-Role', 'GODZILLA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_ROLE') 'S6 unknown -Role filter rejected' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- S7: full cmd chain (chcp 65001) — zh leg ----------
    $r = Invoke-TipsCmd @('-Command', 'add', '-By', 'DEV', '-File', $Zh2PayloadPath)
    Assert-True ($r.exit -eq 0 -and $r.json.data.title -eq $ZhTitle2 -and (@($r.json.data.roles) -join ',') -eq 'DEV') 'S7 cmd-chain zh add roundtrips, roles=[DEV]' ("exit=$($r.exit) raw=$($r.raw)")
    $zh2Id = [string]$r.json.data.id
    $r = Invoke-TipsCmd @('-Command', 'list', '-Role', 'QA')
    $titles = @($r.json.data.entries | ForEach-Object { $_.title })
    Assert-True ($r.json.data.count -eq 2 -and ($titles -contains $ZhTitle) -and -not ($titles -contains $ZhTitle2)) 'S7 cmd-chain filtered list: zh titles intact, DEV-only zh2 excluded' (($titles -join '|'))
    $r = Invoke-TipsCmd @('-Command', 'list')
    Assert-True ($r.json.data.count -eq 4) 'S7 cmd-chain unfiltered count 4' ($r.raw)

    # ---------- S8: command-level errors ----------
    $r = Invoke-Tips @()
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_COMMAND') 'S8 no -Command -> MISSING_COMMAND' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'bogus')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_COMMAND') 'S8 unknown -Command -> INVALID_COMMAND' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- S9: half-broken store fails loud (edge cases) ----------
    $corruptName = '99999999T999999Z-DEV-deadbeef.json'
    $corruptPath = Join-Path $Work ('.rdd\tips\entries\' + $corruptName)
    [System.IO.File]::WriteAllText($corruptPath, '{ not json', $Utf8NoBom)
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY' -and ($r.json.error.message -match [regex]::Escape($corruptName))) 'S9 unparseable entry -> CORRUPT_ENTRY exit 3, file named' ("exit=$($r.exit) raw=$($r.raw)")
    [System.IO.File]::WriteAllText($corruptPath, '{"schema":"rdd-tip/1","id":"x"}', $Utf8NoBom)
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY') 'S9 structurally incomplete entry -> CORRUPT_ENTRY exit 3' ("exit=$($r.exit) raw=$($r.raw)")
    [System.IO.File]::WriteAllText($corruptPath, '{"schema":"rdd-tip/1","id":"99999999T999999Z-DEV-deadbeef","title":"t","problem":"p","avoidance":"a","roles":["ALL"],"recordedBy":"PM","recordedAt":"2026-10-06T00:00:00.0000000Z","deprecated":false}', $Utf8NoBom)
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY' -and ($r.json.error.message -match 'ALL')) 'S9 legacy ALL-shaped entry -> CORRUPT_ENTRY (sentinel removed)' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'target', '-Id', '99999999T999999Z-DEV-deadbeef', '-By', 'QA')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY') 'S9 target on corrupt entry -> CORRUPT_ENTRY exit 3' ("exit=$($r.exit) raw=$($r.raw)")
    Remove-Item -LiteralPath $corruptPath -Force
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 4) 'S9 store healthy again after removing the broken file' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- S10: v2 add — near-duplicate candidates + legacy compat ----------
    $r = Invoke-Tips @('-Command', 'add', '-By', 'DEV', '-Title', 'ascii tip one', '-Problem', 'p1 duplicate problem text', '-Avoidance', 'a1 again')
    Assert-True ($r.exit -eq 0 -and $r.json.data.status -eq 'latent' -and $r.json.data.count -eq 1) 'S10 duplicate-ish add: born latent count=1' ("exit=$($r.exit) raw=$($r.raw)")
    $dupId = [string]$r.json.data.id
    $candTitles = @($r.json.data.candidates | ForEach-Object { $_.title })
    Assert-True ($candTitles.Count -ge 1 -and $candTitles[0] -eq 'ascii tip one') 'S10 candidates: the original same-topic tip ranks first' (($candTitles -join '|') + ' raw=' + $r.raw)
    $cand0 = @($r.json.data.candidates)[0]
    Assert-True ($cand0.score -gt 0 -and @($cand0.recalledBy) -contains 'lexical' -and $cand0.count -ge 1) 'S10 candidate view: positive score + lexical recall + lifecycle fields' ($r.raw)
    Assert-True (($candTitles -contains 'ascii cto tip')) 'S10 weaker lexical overlap (cto tip shares ascii/tip) also recalled' (($candTitles -join '|'))
    $r = Invoke-Tips @('-Command', 'add', '-By', 'PM', '-Title', 'totally different subject xyzzy', '-Problem', 'nothing shared here quux', '-Avoidance', 'no overlap frobnicate')
    Assert-True ($r.exit -eq 0 -and @($r.json.data.candidates).Count -eq 0) 'S10 unrelated add: zero lexical overlap -> empty candidates' ($r.raw)
    $pmId = [string]$r.json.data.id
    # legacy rdd-tip/1 file: read as active/1 (pre-migration view), still recallable
    $legacyId = '20260101T000000Z-DEV-aaaa'
    $legacyPath = Join-Path $Work ('.rdd\tips\entries\' + $legacyId + '.json')
    [System.IO.File]::WriteAllText($legacyPath, '{"schema":"rdd-tip/1","id":"' + $legacyId + '","title":"legacy BOM trap tip","problem":"old BOM problem words","avoidance":"old BOM avoidance words","roles":["DEV"],"recordedBy":"DEV","recordedAt":"2026-01-01T00:00:00.0000000Z","deprecated":false}', $Utf8NoBom)
    $r = Invoke-Tips @('-Command', 'list')
    $legacyView = @($r.json.data.entries | Where-Object { $_.id -eq $legacyId })
    Assert-True ($legacyView.Count -eq 1 -and $legacyView[0].status -eq 'active' -and $legacyView[0].count -eq 1) 'S10 legacy rdd-tip/1 file reads as active/1 (compat view)' ($r.raw)
    $r = Invoke-Tips @('-Command', 'add', '-By', 'DEV', '-Title', 'BOM trap redux', '-Problem', 'BOM problem words again', '-Avoidance', 'BOM avoidance words again')
    $candIds = @($r.json.data.candidates | ForEach-Object { $_.id })
    Assert-True ($candIds -contains $legacyId) 'S10 legacy (schema/1) entry participates in the candidates corpus' (($candIds -join '|') + ' raw=' + $r.raw)

    # ---------- S11: collide — evidence, auto-promotion, ordering ----------
    $r = Invoke-Tips @('-Command', 'collide', '-Id', $ctoId, '-By', 'QA')
    Assert-True ($r.exit -eq 0 -and $r.json.data.collided -eq $true -and $r.json.data.count -eq 2 -and $r.json.data.status -eq 'active' -and $r.json.data.promoted -eq $true -and $r.json.data.sawTip -eq $false) 'S11 collide promotes latent -> active at count=2' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'collide', '-Id', $ctoId, '-By', 'dev', '-SawTip')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 3 -and $r.json.data.status -eq 'active' -and $r.json.data.promoted -eq $false -and $r.json.data.sawTip -eq $true) 'S11 second collide: count=3 stays active, sawTip stamped' ("exit=$($r.exit) raw=$($r.raw)")
    $ctoEntry2 = ([System.IO.File]::ReadAllText((Join-Path $Work ('.rdd\tips\entries\' + $ctoId + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ($ctoEntry2.schema -eq 'rdd-tip/2' -and @($ctoEntry2.collidedBy).Count -eq 2 -and @($ctoEntry2.collidedBy)[0].role -eq 'QA' -and @($ctoEntry2.collidedBy)[1].sawTip -eq $true) 'S11 collidedBy audit trail on disk (roles + sawTip)' ($ctoEntry2 | ConvertTo-Json -Compress)
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True ($r.json.data.entries[0].id -eq $ctoId -and $r.json.data.entries[0].count -eq 3) 'S11 list: collision evidence (count=3) outranks recency' ($r.raw)
    $r = Invoke-Tips @('-Command', 'collide', '-Id', '20990101T000000Z-DEV-0000', '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TIP_NOT_FOUND') 'S11 collide unknown id -> TIP_NOT_FOUND' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'collide', '-Id', $ctoId)
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_BY') 'S11 collide without -By -> MISSING_BY' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'collide', '-Id', $ctoId, '-By', 'GODZILLA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_ROLE') 'S11 collide unknown -By -> INVALID_ROLE' ("exit=$($r.exit) raw=$($r.raw)")
    [System.IO.File]::WriteAllText((Join-Path $Work '.rdd\tips\entries\99999999T888888Z-DEV-badbad.json'), '{ not json', $Utf8NoBom)
    $r = Invoke-Tips @('-Command', 'collide', '-Id', '99999999T888888Z-DEV-badbad', '-By', 'QA')
    Assert-True ($r.exit -eq 3 -and $r.json.error.code -eq 'CORRUPT_ENTRY') 'S11 collide on corrupt entry -> CORRUPT_ENTRY exit 3' ("exit=$($r.exit) raw=$($r.raw)")
    Remove-Item -LiteralPath (Join-Path $Work '.rdd\tips\entries\99999999T888888Z-DEV-badbad.json') -Force

    # ---------- S12: pin / unpin / supersede ----------
    $r = Invoke-Tips @('-Command', 'pin', '-Id', $zh2Id, '-By', 'QA')
    Assert-True ($r.exit -eq 0 -and $r.json.data.pinned -eq $true -and $r.json.data.already -eq $false -and $r.json.data.status -eq 'pinned') 'S12 pin: latent -> pinned' ("exit=$($r.exit) raw=$($r.raw)")
    $pinnedBytes = [System.IO.File]::ReadAllBytes((Join-Path $Work ('.rdd\tips\entries\' + $zh2Id + '.json')))
    $r = Invoke-Tips @('-Command', 'pin', '-Id', $zh2Id, '-By', 'QA')
    $pinnedAfter = [System.IO.File]::ReadAllBytes((Join-Path $Work ('.rdd\tips\entries\' + $zh2Id + '.json')))
    Assert-True ($r.exit -eq 0 -and $r.json.data.already -eq $true -and ($pinnedBytes.Length -eq $pinnedAfter.Length)) 'S12 pin idempotent: already-pinned, file untouched' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'unpin', '-Id', $zh2Id, '-By', 'QA')
    Assert-True ($r.exit -eq 0 -and $r.json.data.unpinned -eq $true -and $r.json.data.status -eq 'latent') 'S12 unpin recomputes from evidence: count=1 -> latent' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'unpin', '-Id', $zh2Id, '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_STATE') 'S12 unpin on non-pinned -> INVALID_STATE' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'collide', '-Id', $zh2Id, '-By', 'CTO')
    Assert-True ($r.exit -eq 0 -and $r.json.data.count -eq 2 -and $r.json.data.status -eq 'active') 'S12 zh2 collide promotes to active (count=2)' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'pin', '-Id', $zh2Id, '-By', 'QA')
    $r = Invoke-Tips @('-Command', 'unpin', '-Id', $zh2Id, '-By', 'QA')
    Assert-True ($r.exit -eq 0 -and $r.json.data.status -eq 'active') 'S12 unpin after promotion falls back to active (count>=2)' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'supersede', '-Id', $pmId, '-By', 'QA', '-Note', 'fixed-into-tool: start-role multi-archive warning')
    Assert-True ($r.exit -eq 0 -and $r.json.data.superseded -eq $true -and $r.json.data.status -eq 'superseded') 'S12 supersede with ASCII note' ("exit=$($r.exit) raw=$($r.raw)")
    $pmEntry = ([System.IO.File]::ReadAllText((Join-Path $Work ('.rdd\tips\entries\' + $pmId + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ($pmEntry.status -eq 'superseded' -and $pmEntry.supersededBy -eq 'QA' -and $pmEntry.note -match 'fixed-into-tool') 'S12 supersede stamps supersededBy/note on disk' ($pmEntry | ConvertTo-Json -Compress)
    $r = Invoke-Tips @('-Command', 'list')
    Assert-True (($r.json.data.entries | Where-Object { $_.id -eq $pmId }).Count -eq 0) 'S12 superseded excluded from default list' ($r.raw)
    $r = Invoke-Tips @('-Command', 'list', '-All')
    Assert-True (($r.json.data.entries | Where-Object { $_.id -eq $pmId }).Count -eq 1 -and $r.json.data.all -eq $true) 'S12 -All includes the superseded entry' ($r.raw)
    $r = Invoke-Tips @('-Command', 'add', '-By', 'PM', '-Title', 'totally different subject xyzzy', '-Problem', 'nothing shared here quux redux', '-Avoidance', 'overlap frobnicate again')
    $candIds2 = @($r.json.data.candidates | ForEach-Object { $_.id })
    Assert-True ($candIds2 -notcontains $pmId) 'S12 superseded entry leaves the candidates corpus' (($candIds2 -join '|') + ' raw=' + $r.raw)
    $r = Invoke-Tips @('-Command', 'pin', '-Id', $pmId, '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_STATE') 'S12 pin on superseded -> INVALID_STATE (terminal)' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'supersede', '-Id', $pmId, '-By', 'QA')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'INVALID_STATE') 'S12 re-supersede -> INVALID_STATE' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'supersede', '-Id', $firstId, '-By', 'QA', '-Note', $ZhTitle)
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'NON_ASCII_INLINE') 'S12 non-ASCII -Note -> NON_ASCII_INLINE' ("exit=$($r.exit) raw=$($r.raw)")

    # ---------- S13: target normalizes a legacy file to v2 ----------
    $r = Invoke-Tips @('-Command', 'target', '-Id', $legacyId, '-By', 'qa')
    Assert-True ($r.exit -eq 0 -and $r.json.data.appended -eq $true -and (@($r.json.data.roles) -join ',') -eq 'DEV,QA' -and $r.json.data.status -eq 'active') 'S13 target on legacy entry: append + lifecycle view in envelope' ("exit=$($r.exit) raw=$($r.raw)")
    $legacyEntry = ([System.IO.File]::ReadAllText($legacyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ($legacyEntry.schema -eq 'rdd-tip/2' -and $legacyEntry.status -eq 'active' -and $legacyEntry.count -eq 1 -and (@($legacyEntry.roles) -join ',') -eq 'DEV,QA') 'S13 rewrite normalizes the legacy file to full v2 in place' ($legacyEntry | ConvertTo-Json -Compress)

    # ---------- S14: migrate — legacy store -> v2 lifecycle ----------
    $legacy2Id = '20260102T000000Z-QA-bbbb'
    $legacy3Id = '20260103T000000Z-CTO-cccc'
    foreach ($pair in @(@($legacy2Id, 'QA'), @($legacy3Id, 'CTO'))) {
        [System.IO.File]::WriteAllText((Join-Path $Work ('.rdd\tips\entries\' + $pair[0] + '.json')), '{"schema":"rdd-tip/1","id":"' + $pair[0] + '","title":"migrate legacy ' + $pair[0] + '","problem":"old problem words","avoidance":"old avoidance words","roles":["' + $pair[1] + '"],"recordedBy":"' + $pair[1] + '","recordedAt":"2026-01-02T00:00:00.0000000Z","deprecated":false}', $Utf8NoBom)
    }
    $storeCount = Get-EntryCount
    $r = Invoke-Tips @('-Command', 'migrate')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MISSING_BY') 'S14 migrate without -By -> MISSING_BY' ("exit=$($r.exit) raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'migrate', '-By', 'PLANNER', '-Pin', '20990101T000000Z-DEV-nope')
    $legacy2Schema = ([System.IO.File]::ReadAllText((Join-Path $Work ('.rdd\tips\entries\' + $legacy2Id + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json).schema
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'MIGRATE_PIN_UNKNOWN' -and $legacy2Schema -eq 'rdd-tip/1') 'S14 unknown -Pin id fails loud BEFORE any write (legacy file untouched)' ("exit=$($r.exit) schema=$legacy2Schema raw=$($r.raw)")
    $r = Invoke-Tips @('-Command', 'migrate', '-By', 'PLANNER', '-Pin', $legacy2Id)
    Assert-True ($r.exit -eq 0 -and $r.json.data.migrated -eq 2 -and (@($r.json.data.pinnedIds) -join ',') -eq $legacy2Id -and (@($r.json.data.latentIds) -join ',') -eq $legacy3Id -and $r.json.data.skippedV2 -eq ($storeCount - 2)) 'S14 migrate: pin-list entry pinned, other legacy latent, v2 skipped' ("exit=$($r.exit) raw=$($r.raw)")
    $m2 = ([System.IO.File]::ReadAllText((Join-Path $Work ('.rdd\tips\entries\' + $legacy2Id + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    $m3 = ([System.IO.File]::ReadAllText((Join-Path $Work ('.rdd\tips\entries\' + $legacy3Id + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-True ($m2.schema -eq 'rdd-tip/2' -and $m2.status -eq 'pinned' -and $m2.pinnedBy -eq 'PLANNER') 'S14 pinned legacy file: v2 + pinnedBy stamped' ($m2 | ConvertTo-Json -Compress)
    Assert-True ($m3.schema -eq 'rdd-tip/2' -and $m3.status -eq 'latent' -and $m3.count -eq 1) 'S14 non-pin legacy file: v2 latent count=1' ($m3 | ConvertTo-Json -Compress)
    $r = Invoke-Tips @('-Command', 'migrate', '-By', 'PLANNER', '-Pin', $legacy2Id)
    Assert-True ($r.exit -eq 0 -and $r.json.data.migrated -eq 0 -and $r.json.data.skippedV2 -eq $storeCount) 'S14 migrate idempotent: second run migrates nothing' ("exit=$($r.exit) raw=$($r.raw)")
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

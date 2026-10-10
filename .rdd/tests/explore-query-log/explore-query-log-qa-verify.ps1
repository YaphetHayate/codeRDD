# explore-query-log QA 黑盒探针 — 探索查询流水记录/命中率数据源
# （archive 2026-10-08-rdd-ops-dashboard 任务 #1）
#
# QA 独立验收套件（与 DEV 侧任何测试零共享代码）：用例源于
# requirements/explore-query-log.md 的 5 条验收标准 + 边界（双入口标记 /
# UTF-8 无 BOM / 全新根首查询 / 非法入参零写入）。经文档化 CLI 接口
# （explore.ps1 -Type search / explore-store.ps1 -Type register）黑盒驱动
# 生产解释器（Windows PowerShell 5.1）。场景组各自使用一次性隔离根
# （RDD_PROJECT_ROOT —— 引擎根定位链第一环），零真仓污染。退出码 0 = 全绿。
#
# TC 编号与 .rdd/tests/explore-query-log/cases.json 一一对应
# （TC-005..TC-055 自动化；TC-060 为 DSH 插件入口手动 verify 协议，见文末
# MANUAL 段——本套件无法从 shell 驱动 harness 内的 rdd_explore 工具）。
#
# 断言独立性：outcome 取值词汇不预设——「命中」语义由已知命中查询的记录
# 自描述推导（AC-5 聚合口径同此），只断言需求级性质：两类查询的记录可区分、
# 可机械聚合出命中率百分比、追加式不丢历史、落盘失败不阻断查询。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot   = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:ExplorePs1 = Join-Path $Script:RepoRoot 'rdd-engine\scripts\explore.ps1'
$Script:ExploreCmd = Join-Path $Script:RepoRoot 'rdd-engine\scripts\explore.cmd'
$Script:StorePs1   = Join-Path $Script:RepoRoot 'rdd-engine\scripts\explore-store.ps1'
$Script:Work       = Join-Path $env:TEMP ('explore-qlog-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function ConvertFrom-RawJson { param([string]$Raw)
    # 2>&1 合流后 stderr 警告（如 TC-020 故障注入下的 query-log append failed，
    # 按验收标准 4 这是预期行为）会与 stdout JSON 信封混排——整串解析失败时
    # 退化为提取最后一个 {"success" 起始的 JSON 行解析。
    $json = $null
    try { $json = $Raw | ConvertFrom-Json } catch { }
    if ($null -ne $json) { return $json }
    $candidate = @($Raw -split "`r?`n" | Where-Object { $_ -match '^\{"success"' })
    if ($candidate.Count -gt 0) { try { $json = $candidate[-1] | ConvertFrom-Json } catch { } }
    return $json
}

function Invoke-ExplorePs1 { param([string[]]$ArgList)
    # 生产解释器直驱 leg。native stderr 在 EAP=Stop 下会抛 NativeCommandError
    # （PS 5.1 已知陷阱），调用窗口内降为 Continue。
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ExplorePs1) + $ArgList
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& powershell @all 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    return @{ exit = $code; raw = $raw; json = (ConvertFrom-RawJson $raw) }
}

function Invoke-ExploreCmd { param([string[]]$ArgList)
    # cmd 薄壳全链 leg（chcp 65001）；参数保持纯 ASCII。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& cmd /c $script:ExploreCmd @ArgList 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    return @{ exit = $code; raw = $raw; json = (ConvertFrom-RawJson $raw) }
}

function Invoke-StorePs1 { param([string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:StorePs1) + $ArgList
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& powershell @all 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    return @{ exit = $code; raw = $raw; json = (ConvertFrom-RawJson $raw) }
}

function New-Root { param([string]$Name)
    # 每个场景组独立隔离根：用例间零依赖，失败不串扰（同 tips 套件约定）。
    $root = Join-Path $script:Work $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $env:RDD_PROJECT_ROOT = $root
    return $root
}

function Get-LogPath { param([string]$Root)
    return (Join-Path $Root '.rdd\exploration\query-log.jsonl')
}

function Read-LogLines { param([string]$Root)
    # 返回 @{ lines = 已解析记录数组; parseFailures = 无法解析的行数 }
    $p = Get-LogPath $Root
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ lines = @(); parseFailures = 0 } }
    $lines = @(); $failures = 0
    foreach ($text in @([System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8))) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        try { $lines += ($text | ConvertFrom-Json) } catch { $failures++ }
    }
    return @{ lines = $lines; parseFailures = $failures }
}

function Register-Fixture { param([string]$Root, [string]$Slug, [string]$Anchor, [string]$Key)
    # 造缓存夹具：artifacts 下全记录 + 配对 summary（register 契约要求成对），
    # 锚点词写入 tags 与 brief 双通道（lexical 召回的数据面）。
    $dir = Join-Path $Root '.rdd\exploration\artifacts'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $full = Join-Path $dir ($Slug + '.md')
    $summ = Join-Path $dir ($Slug + '.summary.md')
    $rel  = '.rdd/exploration/artifacts/' + $Slug + '.md'
    [System.IO.File]::WriteAllText($full, "# fixture $Slug`nanchor token: $Anchor`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($summ, "fixture $Slug — anchor $Anchor`n", (New-Object System.Text.UTF8Encoding($false)))
    return (Invoke-StorePs1 @('-Type', 'register', '-Key', $Key, '-Path', $rel, '-Brief', ("QA fixture anchor $Anchor for query-log verification"), '-Tags', ("qa,fixture,$Anchor")))
}

$prevRoot = $env:RDD_PROJECT_ROOT
New-Item -ItemType Directory -Path $Work -Force | Out-Null

try {
    # ---------- S0：本套件自身 BOM 自检（含中文 .ps1 必须带 BOM，tips 教训钉定） ----------
    $selfBom = [System.IO.File]::ReadAllBytes($PSCommandPath)[0..2]
    Assert-True ($selfBom[0] -eq 239 -and $selfBom[1] -eq 187 -and $selfBom[2] -eq 191) 'S0 self BOM (zh suite saved UTF-8 with BOM)' ("first3=$($selfBom -join ',')")

    # ============================================================
    # 场景 MAIN：有夹具缓存的主流程（TC-005/010/035/015/025/030/045/055/020/050）
    # ============================================================
    $root = New-Root 'main'
    $fixtureKey = 'qa/fixture/explore-query-log-anchor'
    $anchor = 'zzqhitanchor'
    $reg = Register-Fixture $root 'qa-fixture-anchor' $anchor $fixtureKey
    Assert-True ($reg.exit -eq 0 -and $reg.json.success -eq $true) 'FIXTURE register anchor entry in isolated root' ("exit=$($reg.exit) raw=$($reg.raw)")

    # ---------- TC-005（AC-1 正向）：缓存命中查询 → 流水新增 1 行六类语义字段 ----------
    $r = Invoke-ExplorePs1 @('-Type', 'search', '-Query', $anchor)
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and @($r.json.data.results).Count -gt 0) 'TC-005 hit premise: anchor query returns non-empty results' ("exit=$($r.exit) raw=$($r.raw)")
    $log = Read-LogLines $root
    Assert-True ($log.lines.Count -eq 1 -and $log.parseFailures -eq 0) 'TC-005 one parseable log line after first query' ("lines=$($log.lines.Count) parseFailures=$($log.parseFailures)")
    $rec = $log.lines[0]
    Assert-True ([string]$rec.query -eq $anchor) 'TC-005 record carries query verbatim' ($rec | ConvertTo-Json -Compress)
    $tsFound = $false
    foreach ($p in @($rec.PSObject.Properties)) { if ("$($p.Value)" -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}') { $tsFound = $true } }
    Assert-True $tsFound 'TC-005 record carries an ISO-shaped timestamp field' ($rec | ConvertTo-Json -Compress)
    Assert-True (@($rec.keys) -contains $fixtureKey) 'TC-005 hit record keys contain the registered entry key' ($rec | ConvertTo-Json -Compress)
    Assert-True (@($rec.recallers).Count -ge 1) 'TC-005 record carries non-empty recaller status array' ($rec | ConvertTo-Json -Compress)
    $hitOutcome = [string]$rec.outcome
    Assert-True (-not [string]::IsNullOrWhiteSpace($hitOutcome)) 'TC-005 record carries an outcome marker (hit semantics derived from this known-hit query)' ($rec | ConvertTo-Json -Compress)

    # ---------- TC-055（AC-1 边界）：记录 keys 与该次真实召回集对账 ----------
    $resultKeys = @($r.json.data.results | ForEach-Object { [string]$_.key })
    $recKeys = @($rec.keys | ForEach-Object { [string]$_ })
    $sameSet = (($resultKeys | Sort-Object) -join '|') -eq (($recKeys | Sort-Object) -join '|')
    Assert-True ($sameSet -and $resultKeys.Count -gt 0) 'TC-055 logged keys set == actual search results keys set' ("results=($resultKeys -join '|') logged=($recKeys -join '|')")

    # ---------- TC-010（AC-2 正向）：未命中（dispatch 形态）查询 → 新增含可区分标记的记录 ----------
    $missQ = 'zzq-miss-nonce-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $r2 = Invoke-ExplorePs1 @('-Type', 'search', '-Query', $missQ)
    Assert-True ($r2.exit -eq 0 -and $r2.json.success -eq $true -and @($r2.json.data.results).Count -eq 0 -and $null -ne $r2.json.data.dispatchPrompt) 'TC-010 miss premise: nonce query returns empty results + dispatchPrompt' ("exit=$($r2.exit) raw=$($r2.raw)")
    $log = Read-LogLines $root
    Assert-True ($log.lines.Count -eq 2) 'TC-010 second query appended (2 lines)' ("lines=$($log.lines.Count)")
    $recMiss = $log.lines[1]
    Assert-True ([string]$recMiss.query -eq $missQ) 'TC-010 miss record carries nonce query verbatim' ($recMiss | ConvertTo-Json -Compress)
    Assert-True ([string]$recMiss.outcome -ne $hitOutcome) 'TC-010 miss outcome value distinguishable from hit outcome (no vocabulary assumed)' ("hit='$hitOutcome' miss='$($recMiss.outcome)'")
    Assert-True (@($recMiss.keys) -notcontains $fixtureKey) 'TC-010 miss record does not claim the registered key' ($recMiss | ConvertTo-Json -Compress)
    Assert-True (@($recMiss.recallers).Count -ge 1) 'TC-010 miss record also carries recaller status' ($recMiss | ConvertTo-Json -Compress)

    # ---------- TC-035（AC-1 边界）：入口标记字段存在且 CLI 两腿（ps1/cmd）恒定 ----------
    $entryMark = [string]$rec.entry
    Assert-True (-not [string]::IsNullOrWhiteSpace($entryMark)) 'TC-035 record carries a non-empty entry marker' ($rec | ConvertTo-Json -Compress)
    $r3 = Invoke-ExploreCmd @('-Type', 'search', '-Query', $anchor)
    Assert-True ($r3.exit -eq 0 -and $r3.json.success -eq $true -and @($r3.json.data.results).Count -gt 0) 'TC-035 cmd-chain leg: anchor query hits through explore.cmd' ("exit=$($r3.exit) raw=$($r3.raw)")
    $log = Read-LogLines $root
    Assert-True ($log.lines.Count -eq 3 -and [string]$log.lines[2].query -eq $anchor) 'TC-035 cmd leg query appended (3 lines)' ("lines=$($log.lines.Count)")
    Assert-True ([string]$log.lines[2].entry -eq $entryMark) 'TC-035 entry marker constant across ps1-direct and cmd-chain legs' ("first='$entryMark' cmd='$($log.lines[2].entry)'")

    # ---------- TC-015（AC-3 正向）：append-only —— 历史字节前缀保留、行数单调 ----------
    $logPath = Get-LogPath $root
    $bytesBefore = [System.IO.File]::ReadAllBytes($logPath)
    $null = Invoke-ExplorePs1 @('-Type', 'search', '-Query', $anchor)
    $bytesAfter = [System.IO.File]::ReadAllBytes($logPath)
    $prefixKept = $bytesAfter.Length -gt $bytesBefore.Length
    if ($prefixKept) {
        for ($i = 0; $i -lt $bytesBefore.Length; $i++) { if ($bytesBefore[$i] -ne $bytesAfter[$i]) { $prefixKept = $false; break } }
    }
    Assert-True $prefixKept 'TC-015 append-only: byte prefix of history preserved, file only grew' ("len=$($bytesBefore.Length)->$($bytesAfter.Length)")
    Assert-True ((Read-LogLines $root).lines.Count -eq 4) 'TC-015 line count monotonically grows to 4' ("lines=$((Read-LogLines $root).lines.Count)")

    # ---------- TC-025（AC-5 正向）：机械聚合出命中率百分比（#2 看板直接消费口径） ----------
    $log = Read-LogLines $root
    $hits = @($log.lines | Where-Object { [string]$_.outcome -eq $hitOutcome }).Count
    $misses = @($log.lines | Where-Object { [string]$_.outcome -ne $hitOutcome }).Count
    Assert-True ($hits -eq 3 -and $misses -eq 1) 'TC-025 aggregation input: 3 hit + 1 miss records groupable by outcome' ("hits=$hits misses=$misses")
    $pct = [math]::Round(100.0 * $hits / ($hits + $misses), 3)
    Assert-True ([math]::Abs($pct - 75.0) -lt 0.001) 'TC-025 mechanically aggregated hit rate = 75.0%' ("pct=$pct")

    # ---------- TC-030（AC-1 边界）：中文 query 原文零损 + 日志 UTF-8 无 BOM ----------
    $zhQ = '中文未命中查询锚点流水测试'
    $r4 = Invoke-ExplorePs1 @('-Type', 'search', '-Query', $zhQ)
    Assert-True ($r4.exit -eq 0 -and $r4.json.success -eq $true -and [string]$r4.json.data.query -ceq $zhQ) 'TC-030 zh query echoed intact on stdout (ps1 direct leg)' ("exit=$($r4.exit) query=$($r4.json.data.query)")
    $log = Read-LogLines $root
    Assert-True ($log.lines.Count -eq 5 -and [string]$log.lines[4].query -ceq $zhQ) 'TC-030 zh query persisted verbatim in log record' ("lines=$($log.lines.Count) logged=$($log.lines[4].query)")
    $fileBom = [System.IO.File]::ReadAllBytes($logPath)[0..2]
    Assert-True (-not ($fileBom[0] -eq 239 -and $fileBom[1] -eq 187 -and $fileBom[2] -eq 191)) 'TC-030 log file saved UTF-8 WITHOUT BOM (engine data-file convention)' ("first3=$($fileBom -join ',')")

    # ---------- TC-045（AC-1/2 边界）：召回器状态含需求示例词根（lexical/vector） ----------
    $recallerRootsOk = $true
    foreach ($rr in @($log.lines[0], $log.lines[1])) {
        $names = (@($rr.recallers) | ForEach-Object { [string]$_.name }) -join '|'
        if ($names -notmatch '(?i)lexical|vector') { $recallerRootsOk = $false }
    }
    Assert-True $recallerRootsOk 'TC-045 hit & miss records both carry lexical/vector recaller names' ((@($log.lines[0].recallers) | ForEach-Object { $_.name }) -join ',')

    # ---------- TC-020（AC-4 异常）：落盘失败不阻断查询（日志路径替换为同名目录注入故障） ----------
    $bak = "$logPath.bak"
    Move-Item -LiteralPath $logPath -Destination $bak -Force
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    $r5 = Invoke-ExplorePs1 @('-Type', 'search', '-Query', $anchor)
    Assert-True ($r5.exit -eq 0 -and $r5.json.success -eq $true -and @($r5.json.data.results).Count -gt 0) 'TC-020 query succeeds (exit 0, valid JSON, results intact) while log append must fail' ("exit=$($r5.exit) raw=$($r5.raw)")
    Assert-True (Test-Path -LiteralPath $logPath -PathType Container) 'TC-020 fault injection held: log path still a directory (no silent recreate)' ('')
    Remove-Item -LiteralPath $logPath -Recurse -Force
    Move-Item -LiteralPath $bak -Destination $logPath -Force
    $r6 = Invoke-ExplorePs1 @('-Type', 'search', '-Query', ('zzq-recover-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    $log = Read-LogLines $root
    Assert-True ($r6.exit -eq 0 -and $log.lines.Count -eq 6 -and $log.parseFailures -eq 0) 'TC-020 append recovers after fault cleared (6 parseable lines)' ("exit=$($r6.exit) lines=$($log.lines.Count)")

    # ---------- TC-050（AC-3 反向）：非法入参显式报错且零流水写入 ----------
    $before = (Read-LogLines $root).lines.Count
    $r7 = Invoke-ExplorePs1 @('-Type', 'search')
    $r8 = Invoke-ExplorePs1 @()
    Assert-True ($r7.exit -eq 1 -and $r7.json.success -eq $false) 'TC-050 MISSING_QUERY rejected with exit 1 error envelope' ("exit=$($r7.exit) raw=$($r7.raw)")
    Assert-True ($r8.exit -eq 1 -and $r8.json.success -eq $false) 'TC-050 MISSING_TYPE rejected with exit 1 error envelope' ("exit=$($r8.exit) raw=$($r8.raw)")
    Assert-True ((Read-LogLines $root).lines.Count -eq $before) 'TC-050 rejected invocations wrote no log lines (no partial writes on failure path)' ("before=$before after=$((Read-LogLines $root).lines.Count)")

    # ============================================================
    # 场景 FRESH：全新根首查询（TC-040）
    # ============================================================
    $root2 = New-Root 'fresh'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root2 '.rdd\exploration'))) 'TC-040 premise: pristine root has no .rdd/exploration yet' ('')
    $r9 = Invoke-ExplorePs1 @('-Type', 'search', '-Query', ('zzq-fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    $log2 = Read-LogLines $root2
    Assert-True ($r9.exit -eq 0 -and $log2.lines.Count -eq 1 -and $log2.parseFailures -eq 0) 'TC-040 first-ever query auto-creates dir+log and records 1 line (no history required)' ("exit=$($r9.exit) lines=$($log2.lines.Count)")

    # ============================================================
    # MANUAL TC-060（DSH 插件入口 rdd_explore 工具）——verify 时在 QA 会话内执行：
    #   1) 记录真实仓 .rdd/exploration/query-log.jsonl 当前行数与最后一条 entry 标记
    #   2) 会话内调用 rdd_explore 工具两次：一次可命中查询（如「探索缓存」）、
    #      一次带随机 nonce 的未命中查询（触发 dispatch）
    #   3) 断言真实仓日志新增 2 条，query 逐字对应，且 entry 标记取值区别于本套件
    #      观察到的 CLI 常量值（双入口可分统计的数据前提，AC-1/AC-2）
    # ============================================================
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

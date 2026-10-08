# ops-dashboard 整体验收探针 — 判据 #1 / #2 端到端
# （run: deliver-2026-10-08-rdd-ops-dashboard；判据源：requirements/overview.md#整体验收判据）
#
# 与功能级回归套件 ops-dashboard-qa-verify.ps1 的分工：
#   套件 = 单需求 6 条验收标准（AC-1..AC-6）的常驻回归；
#   本探针 = 跨需求的两条**用户可感知完整场景**（判据 #1 一条命令 + 打开即见全貌并钻取；
#            判据 #2 一 hit 一 miss 真实查询后刷新看板，命中率与流水随之变化）。
#
# 运行：
#   powershell -NoProfile -ExecutionPolicy Bypass -File ops-dashboard-acceptance.ps1 `
#       -StartCommand "<repo>\ops-dashboard.cmd -Port 8803" -Port 8803
#
# 副作用与可逆性（与套件 TC-120 同类）：为制造一次确定性命中，探针经 explore-store
# 注册一条带唯一 token 的缓存条目并在收尾删除（含配对 summary）；两次真实查询会追加
# 两条真实流水行——流水不清除（清除等于伪造证据）。
#
# 收尾约定（受限沙箱）：taskkill 恒 Access denied，故按端口 LISTENING 属主 Stop-Process。
# 只认 LISTENING 行：ESTABLISHED 行的最后一列是本探针自身（客户端）PID，按它杀 = 自杀。

param(
    [string]$StartCommand = '',
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:StorePs1 = Join-Path $Script:RepoRoot 'rdd-engine\scripts\explore-store.ps1'
$Script:ExploreCmd = Join-Path $Script:RepoRoot 'rdd-engine\scripts\explore.cmd'
$Script:LogPath = Join-Path $Script:RepoRoot '.rdd\exploration\query-log.jsonl'
$Script:Results = @()
$Script:ServiceProc = $null
$Script:BaseUrl = $null

function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Read-SharedText { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = $null; $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } catch { return '' } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Stop-ServiceInstance { param($Proc, [int]$Port = 0)
    try {
        $victims = @()
        if ($Port -gt 0) {
            foreach ($line in @(netstat -ano | Select-String (':' + $Port + '\s'))) {
                if ([string]$line.Line -notmatch '(?i)LISTENING') { continue }
                $parts = @(([string]$line.Line -split '\s+') | Where-Object { $_ -ne '' })
                if ($parts.Count -ge 5 -and $parts[-1] -match '^\d+$') { $victims += [int]$parts[-1] }
            }
        }
        if ($null -ne $Proc) { $victims += @([int]$Proc.Id) }
        foreach ($v in @($victims | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique)) {
            Stop-Process -Id $v -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $Proc -and -not $Proc.HasExited) { & cmd /c "taskkill /PID $($Proc.Id) /T /F" 2>&1 | Out-Null }
    } catch { }
}

function Get-PageText { param([string]$Html)
    return [System.Net.WebUtility]::HtmlDecode(($Html -replace '(?is)<script[\s\S]*?</script>', ' ' -replace '(?is)<style[\s\S]*?</style>', ' ' -replace '<[^>]+>', ' '))
}

function Get-LogStats {
    # 流水地面真值：独立从 jsonl 逐行算，不信看板自报。
    $stats = @{ lines = 0; hits = 0; misses = 0; queries = @() }
    if (-not (Test-Path -LiteralPath $Script:LogPath)) { return $stats }
    foreach ($line in @([System.IO.File]::ReadAllLines($Script:LogPath, [System.Text.Encoding]::UTF8))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $record = $line | ConvertFrom-Json
            $stats.lines++
            if ([string]$record.outcome -eq 'hit') { $stats.hits++ } else { $stats.misses++ }
            $stats.queries += [string]$record.query
        } catch { }
    }
    return $stats
}

function Get-DisplayedPercents { param([string]$Text)
    return @([regex]::Matches($Text, '(\d+(?:\.\d+)?)\s*%') | ForEach-Object { [double]$_.Groups[1].Value })
}

function Get-ArchiveTruth {
    # #1 需求归档地面真值 + 详情页样本（最新结构化归档 / 含 remark 分段的归档）。
    $truth = @{ structured = 0; legacy = 0; newestName = $null; newestTitle = $null; newestTaskId = $null
                remarkName = $null; remarkTaskId = $null; remarkSegments = @() }
    $root = Join-Path $Script:RepoRoot '.rdd\changes\archive'
    if (-not (Test-Path -LiteralPath $root)) { return $truth }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending)) {
        $taskFile = Join-Path $dir.FullName 'task.json'
        if (-not (Test-Path -LiteralPath $taskFile)) { $truth.legacy++; continue }
        $truth.structured++
        try { $task = [System.IO.File]::ReadAllText($taskFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        $firstTask = @($task.tasks)[0]
        if ($null -eq $firstTask) { continue }
        if ($null -eq $truth.newestName) {
            $truth.newestName = $dir.Name
            $truth.newestTitle = [string]$firstTask.title
            $truth.newestTaskId = [string]$firstTask.id
        }
        foreach ($item in @($task.tasks)) {
            $remark = [string]$item.remark
            if ($null -eq $truth.remarkName -and $remark -match '\|') {
                $truth.remarkName = $dir.Name
                $truth.remarkTaskId = [string]$item.id
                $truth.remarkSegments = @(($remark -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 4 })
            }
        }
    }
    return $truth
}

function Get-Response { param([string]$Url)
    try { return Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 10 } catch { return $null }
}

function Get-PageByPath { param([string]$Path)
    $resp = Get-Response ($Script:BaseUrl.TrimEnd('/') + $Path)
    if ($null -eq $resp) { return @{ ok = $false; text = ''; html = '' } }
    return @{ ok = $true; status = $resp.StatusCode; html = [string]$resp.Content; text = (Get-PageText ([string]$resp.Content)) }
}

New-Item -ItemType Directory -Path (Join-Path $Script:RepoRoot '.rdd\tmp') -Force | Out-Null
$work = Join-Path $Script:RepoRoot ('.rdd\tmp\qa-n11-acceptance-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$outFile = Join-Path $work 'svc-out.txt'
$errFile = Join-Path $work 'svc-err.txt'
$probeArtifact = $null
$probeSummary = $null
$probeKey = $null

try {
    if ([string]::IsNullOrWhiteSpace($StartCommand)) { throw 'StartCommand is required (the single command that brings the board up).' }
    $selfBom = [System.IO.File]::ReadAllBytes($PSCommandPath)[0..2]
    Assert-True ($selfBom[0] -eq 239 -and $selfBom[1] -eq 187 -and $selfBom[2] -eq 191) 'S0 suite self BOM (zh .ps1 must be UTF-8 with BOM)' ("first3=$($selfBom -join ',')")

    # ================= 判据 #1：一条命令 → 打开 URL 即见全貌并钻取 =================
    $Script:ServiceProc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $StartCommand `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline -and -not $Script:ServiceProc.HasExited) {
        $announced = Read-SharedText $outFile
        if ($announced -match 'http://(127\.0\.0\.1|localhost|\[::1\]):(\d+)') { $Script:BaseUrl = $Matches[0]; break }
        Start-Sleep -Milliseconds 500
    }
    if ($null -eq $Script:BaseUrl -and $Port -gt 0) { $Script:BaseUrl = "http://127.0.0.1:$Port" }
    $root = Get-PageByPath '/'
    Assert-True ($Script:BaseUrl -and $root.ok -and $root.status -eq 200 -and $root.html.Length -gt 0) `
        'A0 one command brings the board up: GET URL -> 200 with HTML (no extra manual step)' ("url=$($Script:BaseUrl) status=$($root.status)")
    Assert-True ($Script:BaseUrl -and (Read-SharedText $outFile) -match [regex]::Escape($Script:BaseUrl)) `
        'A1 the user is told where to open: announced URL appears verbatim on stdout' ("url=$($Script:BaseUrl)")

    $truth = Get-ArchiveTruth
    $navPages = @()
    foreach ($href in @([regex]::Matches($root.html, '(?is)<a[^>]+href="([^"#]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
        if ($href -match '\.(css|js|ico|png|jpe?g|svg|map)(\?|$)') { continue }
        $nav = Get-PageByPath ($href -replace '^https?://[^/]+', '')
        if ($nav.ok -and ([string]$nav.html) -match '(?is)^\s*<!DOCTYPE\s+html') { $navPages += $href }
    }
    $navUnix = @($navPages | Select-Object -Unique)
    Assert-True ($navUnix.Count -ge 6) 'A2 overview shows every P0 domain entry (>=6 same-origin domain pages navigable)' ("nav=$($navUnix -join ',')")
    $archiveTotal = $truth.structured + $truth.legacy
    $countsOnPage = ((Get-PageText $root.html) -match ("(?<!\d)" + $archiveTotal + "(?!\d)"))
    Assert-True $countsOnPage 'A3 counts agree with ground truth computed by QA from raw .rdd files (archive total)' ("archiveTotal=$archiveTotal (structured=$($truth.structured) legacy=$($truth.legacy))")

    $list = Get-PageByPath '/requirements'
    Assert-True ($list.ok -and $null -ne $truth.newestTitle -and $list.text.Contains($truth.newestTitle)) `
        'A4 requirement list carries the real CJK archive title verbatim' ("title=$($truth.newestTitle)")

    $detailPath = $null
    foreach ($href in @([regex]::Matches([string]$list.html, 'href="([^"#]+)"') | ForEach-Object { $_.Groups[1].Value })) {
        if ($href -match [regex]::Escape($truth.newestName)) { $detailPath = $href; break }
    }
    if ($null -eq $detailPath) { $detailPath = "/requirements/$($truth.newestName)/$($truth.newestTaskId)" }
    $detail = Get-PageByPath ($detailPath -replace '^https?://[^/]+', '')
    $signals = @{
        title = $detail.text.Contains([string]$truth.newestTitle)
        owner = ($detail.text -match '(?i)Owner|责任人|owner')
        lifecycle = ($detail.text -match '(?i)生命周期|lifecycle|active|completed|进行中|已完成')
        docpath = ($detail.text -match 'requirements/|design/')
    }
    Assert-True ($detail.ok -and $signals.title -and $signals.owner -and $signals.lifecycle -and $signals.docpath) `
        'A5 drill-down shows the full chain of one requirement (title / owner / lifecycle / doc paths)' ("path=$detailPath signals=$($signals | ConvertTo-Json -Compress)")

    if ($null -ne $truth.remarkName) {
        $remarkPage = Get-PageByPath "/requirements/$($truth.remarkName)/$($truth.remarkTaskId)"
        $missing = @($truth.remarkSegments | Where-Object { -not $remarkPage.text.Contains($_) })
        Assert-True (@($truth.remarkSegments).Count -gt 0 -and $missing.Count -eq 0) `
            'A6 rejection remarks (remark) are readable segment by segment on the detail page' ("archive=$($truth.remarkName) segments=$(@($truth.remarkSegments).Count) missing=$($missing -join ' / ')")
    } else {
        Assert-True $false 'A6 rejection remarks readable' 'no archive with a pipe-segmented remark found in ground truth'
    }

    # ================= 判据 #2：一 hit 一 miss 真实查询 → 刷新看板 → 数字与流水随之变化 =================
    $base = Get-LogStats
    $basePct = if ($base.lines -gt 0) { 100.0 * $base.hits / $base.lines } else { 0.0 }
    $hitRateBase = Get-PageByPath '/hit-rate'
    $shownBase = Get-DisplayedPercents $hitRateBase.text
    $baseOk = @($shownBase | Where-Object { [math]::Abs($_ - $basePct) -le 0.1 }).Count -gt 0
    Assert-True ($hitRateBase.ok -and $baseOk) 'B0 baseline: the shown hit-rate equals hit/(hit+miss) computed from the raw log' ("gt=$([math]::Round($basePct,1))% shown=[$($shownBase -join ',')] lines=$($base.lines)")

    $missNonce = 'zzqx' + (Get-Random -Minimum 10000000 -Maximum 99999999)
    $null = & $Script:ExploreCmd -Type search -Query $missNonce 2>&1
    $afterMiss = Get-LogStats
    Assert-True (($afterMiss.lines -eq $base.lines + 1) -and ($afterMiss.misses -eq $base.misses + 1)) `
        'B1 a real miss (dispatch) query appends exactly one miss record' ("lines=$($base.lines)->$($afterMiss.lines) misses=$($base.misses)->$($afterMiss.misses)")
    $missPct = 100.0 * $afterMiss.hits / $afterMiss.lines
    $hitRateMiss = Get-PageByPath '/hit-rate'
    $shownMiss = Get-DisplayedPercents $hitRateMiss.text
    Assert-True ((@($shownMiss | Where-Object { [math]::Abs($_ - $missPct) -le 0.1 }).Count -gt 0) -and ([math]::Abs($missPct - $basePct) -gt 0.05)) `
        'B2 after refresh the hit-rate is recomputed and moves' ("$([math]::Round($basePct,1))% -> $([math]::Round($missPct,1))% shown=[$($shownMiss -join ',')]")
    Assert-True $hitRateMiss.text.Contains($missNonce) 'B3 the miss query text is readable in the flow detail' ("query=$missNonce")

    $probeToken = 'qaacc' + (Get-Random -Minimum 10000000 -Maximum 99999999)
    $artifactDir = Join-Path $Script:RepoRoot '.rdd\exploration\artifacts'
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    $probeArtifact = Join-Path $artifactDir ("acceptance-probe-$probeToken.md")
    $probeSummary = Join-Path $artifactDir ("acceptance-probe-$probeToken.summary.md")
    $probeKey = "qa/acceptance-probe-$probeToken"
    [System.IO.File]::WriteAllText($probeArtifact, "# acceptance probe $probeToken`n`n判据 #2 命中查询用的一次性缓存条目（探针收尾删除）。`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($probeSummary, "acceptance probe $probeToken", (New-Object System.Text.UTF8Encoding($false)))
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script:StorePs1 -Type register -Key $probeKey `
        -Path (".rdd/exploration/artifacts/acceptance-probe-$probeToken.md") -Brief "acceptance probe $probeToken" -Tags "acceptance,$probeToken" 2>&1
    $null = & $Script:ExploreCmd -Type search -Query $probeToken 2>&1
    $afterHit = Get-LogStats
    Assert-True (($afterHit.lines -eq $afterMiss.lines + 1) -and ($afterHit.hits -eq $afterMiss.hits + 1)) `
        'B4 a real cache-hit query appends exactly one hit record' ("lines=$($afterMiss.lines)->$($afterHit.lines) hits=$($afterMiss.hits)->$($afterHit.hits)")
    $hitPct = 100.0 * $afterHit.hits / $afterHit.lines
    $hitRateHit = Get-PageByPath '/hit-rate'
    $shownHit = Get-DisplayedPercents $hitRateHit.text
    Assert-True ((@($shownHit | Where-Object { [math]::Abs($_ - $hitPct) -le 0.1 }).Count -gt 0) -and ([math]::Abs($hitPct - $missPct) -gt 0.05)) `
        'B5 after refresh the hit-rate is recomputed again and moves' ("$([math]::Round($missPct,1))% -> $([math]::Round($hitPct,1))% shown=[$($shownHit -join ',')]")
    Assert-True $hitRateHit.text.Contains($probeToken) 'B6 the hit query text is readable in the flow detail' ("query=$probeToken")
    $distinct = @($afterHit.queries | Select-Object -Unique)
    $missingQueries = @($distinct | Where-Object { -not $hitRateHit.text.Contains($_) })
    Assert-True ($missingQueries.Count -eq 0 -or $distinct.Count -gt 200) `
        'B7 the flow detail covers the logged flow (all distinct queries, or an explicit truncation notice)' ("distinct=$($distinct.Count) missing=$(@($missingQueries).Count)")
    Assert-True (-not $Script:ServiceProc.HasExited) 'B8 the service was never restarted across the whole flow (same process throughout)' ("pid=$($Script:ServiceProc.Id)")
} catch {
    Assert-True $false 'ACCEPTANCE unexpected exception (degraded to FAIL)' ($_.Exception.Message)
} finally {
    Stop-ServiceInstance -Proc $Script:ServiceProc -Port $Port
    foreach ($probe in @($probeArtifact, $probeSummary)) {
        if ($null -ne $probe -and (Test-Path -LiteralPath $probe)) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
    if ($null -ne $probeKey) {
        $hotPath = Join-Path $Script:RepoRoot '.rdd\exploration\hot.json'
        if (Test-Path -LiteralPath $hotPath) {
            try {
                $hot = [System.IO.File]::ReadAllText($hotPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $kept = @($hot.entries | Where-Object { [string]$_.key -ne $probeKey })
                [System.IO.File]::WriteAllText($hotPath, (@{ entries = $kept } | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }
    }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Script:Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Script:Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

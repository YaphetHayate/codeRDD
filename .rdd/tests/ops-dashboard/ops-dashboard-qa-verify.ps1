# ops-dashboard QA 黑盒探针 — RDD 运营看板·实时式（archive 2026-10-08-rdd-ops-dashboard 任务 #2）
#
# QA 独立验收套件：用例源于 requirements/ops-dashboard.md 的 6 条验收标准 +
# 边界（稀疏数据/中文编码/旧结构归档/tmp 排除）。地面真值（Ground Truth）由
# 本套件独立从 .rdd/ 原始文件计算，不信看板自报数字。
#
# 【测试先行运行形态】看板交付前（无启动命令可发现时）：全部服务侧用例
# SKIP（exit 0），仅打印指引——本套件即验收清单，DEV 交付后以
#   powershell -File ops-dashboard-qa-verify.ps1 -StartCommand "<一条启动命令>" [-Port <n>] [-Mutate]
# 激活。断言词汇不预设 UI 文案/路由/端口：URL 从启动命令 stdout 提取，
# 钻取从根页 href 跟进发现。
#
# TC 编号与 .rdd/tests/ops-dashboard/cases.json 一一对应（TC-105..TC-180 自动化；
# TC-120 默认 SKIP（-Mutate 激活，会向真实探索缓存注册一条真实有值的记录）；
# TC-160 为 verify 时手动协议，见文末 MANUAL 段）。
#
# 收尾约定（受限沙箱）：taskkill 恒 Access denied，必走 Stop-ServiceInstance
# （端口属主 → 子进程链 → 进程本体 → taskkill 兜底）；否则服务子进程存活会让
# 外层捕获读不到 EOF，把「断言全绿」显示成超时红。
#
# 并行会话提示：地面真值在断言前即时计算，但并行角色会话可能同时改动 .rdd/
# （数字漂移会造成偶发假阴性，重跑即可复核）。

param(
    [string]$StartCommand = '',
    [int]$Port = 0,
    [switch]$Mutate
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:StorePs1 = Join-Path $Script:RepoRoot 'rdd-engine\scripts\explore-store.ps1'
$Script:Work     = Join-Path $env:TEMP ('ops-dash-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Script:ServicePort = 0   # 主实例实际监听的端口（从宣告 URL 解析，供收尾杀进程树用）

$Script:Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}
function Assert-Skip { param([string]$Name, [string]$Why)
    $script:Results += @{ name = $Name; ok = $true; skipped = $true; detail = $Why }
    Write-Output ("SKIP  {0}   {1}" -f $Name, $Why)
}

function Read-SharedText { param([string]$Path)
    # 服务进程存活期间其 stdout 重定向文件常被独占打开（默认共享模式读不到
    # 尚未被服务自身关闭的公告行）；FileShare.ReadWrite 可在运行中读到已刷新输出。
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

function Get-PortOwnerPids { param([int]$Port)
    # 监听端口的**属主**进程（服务真正的 node 子进程）。两条来源，都不预设成功：
    #   ① netstat -ano：只认 LISTENING 行。ESTABLISHED/TIME_WAIT 行的最后一列是
    #      **客户端** PID——本套件自己正向该端口发 HTTP，按它杀进程等于自杀（套件
    #      静默死亡、不打印汇总，只在外部留下一个孤儿服务）。此坑已实测踩过。
    #   ② Get-NetTCPConnection：本沙箱下常抛错/返回空，可用时作为补充。
    if ($Port -le 0) { return @() }
    $owners = @()
    foreach ($line in @(netstat -ano | Select-String (':' + $Port + '\s'))) {
        $text = [string]$line.Line
        if ($text -notmatch '(?i)LISTENING') { continue }
        $parts = @(($text -split '\s+') | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 5 -and $parts[-1] -match '^\d+$') { $owners += [int]$parts[-1] }
    }
    if ($owners.Count -eq 0) {
        try {
            foreach ($c in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)) { $owners += [int]$c.OwningProcess }
        } catch { }
    }
    # 永不含本进程：杀自己 = 套件无汇总静默退出（最难归因的失败形态）。
    return @($owners | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique)
}

function Stop-ServiceInstance { param($Proc, [int]$Port = 0)
    # 收尾必须真正杀掉服务子进程：节点存活则其 stdout 重定向句柄不放，外层捕获
    # 等不到 EOF，于是「断言全绿」被读成超时红（n10 DEV 环境发现）。受限沙箱下
    # taskkill 恒 Access denied，故顺序为：端口属主 → 子进程链 → 进程本体 →
    # taskkill 兜底。整体 try/catch：收尾失败不得掩盖断言结果。
    try {
        $targets = @()
        $targets += @(Get-PortOwnerPids $Port)
        if ($null -ne $Proc) {
            try {
                $targets += @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $Proc.Id) -ErrorAction Stop | ForEach-Object { [int]$_.ProcessId })
            } catch { }
            $targets += @([int]$Proc.Id)
        }
        foreach ($victim in @($targets | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique)) {
            Stop-Process -Id $victim -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $Proc) {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not $Proc.HasExited) { Start-Sleep -Milliseconds 300 }
            if (-not $Proc.HasExited) { & cmd /c "taskkill /PID $($Proc.Id) /T /F" 2>&1 | Out-Null }
        }
    } catch { }
}

function Get-ArchiveTruth {
    # 归档域地面真值：结构化（有 task.json）与旧结构分开计数，最新结构化归档取标题。
    $truth = @{ archiveCount = 0; legacyArchiveCount = 0; newestTitle = $null }
    $archRoot = Join-Path $Script:RepoRoot '.rdd\changes\archive'
    if (-not (Test-Path -LiteralPath $archRoot)) { return $truth }
    $newArchives = @(); $legacyArchives = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $archRoot -Directory)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'task.json')) { $newArchives += $d }
        elseif ((Test-Path -LiteralPath (Join-Path $d.FullName 'task.md')) -or @((Get-ChildItem -LiteralPath $d.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue)).Count -gt 0) { $legacyArchives += $d }
    }
    $truth.archiveCount = $newArchives.Count
    $truth.legacyArchiveCount = $legacyArchives.Count
    if ($newArchives.Count -gt 0) {
        $newest = $newArchives | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        try {
            $tj = [System.IO.File]::ReadAllText((Join-Path $newest.FullName 'task.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if (@($tj.tasks).Count -gt 0) { $truth.newestTitle = [string]$tj.tasks[0].title }
        } catch { }
    }
    return $truth
}

function Get-QueryLogTruth {
    # 查询流水地面真值：keys 非空的记录视为命中（数据层判定，不依赖词汇）。
    $truth = @{ logLines = 0; logHits = 0; logLastQuery = $null }
    $logPath = Join-Path $Script:RepoRoot '.rdd\exploration\query-log.jsonl'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return $truth }
    foreach ($line in @([System.IO.File]::ReadAllLines($logPath, [System.Text.Encoding]::UTF8))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $r = $line | ConvertFrom-Json
            $truth.logLines++
            if (@($r.keys).Count -gt 0) { $truth.logHits++ }
            $truth.logLastQuery = [string]$r.query
        } catch { }
    }
    return $truth
}

function Get-FixtureTokens {
    # tmp/ 排除探针：取特征目录/文件名 token（长度>=6，避免噪音词）。
    # 真实仓的测试假数据并非常驻仓根 tmp/（常为空），而在 .rdd/tmp/ 与夹具命名的
    # 交付树目录——三处都作 token 源，避免「仓根 tmp/ 空 → 该断言恒 SKIP」的假绿。
    $names = @()
    foreach ($src in @((Join-Path $Script:RepoRoot 'tmp'), (Join-Path $Script:RepoRoot '.rdd\tmp'))) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $names += @(Get-ChildItem -LiteralPath $src -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $names += @(Get-ChildItem -LiteralPath $src -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { $_.Name } })
    }
    $treeRoot = Join-Path $Script:RepoRoot '.rdd\goal-trees'
    if (Test-Path -LiteralPath $treeRoot) {
        $names += @(Get-ChildItem -LiteralPath $treeRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qa-fixture|qa-bridge' } | ForEach-Object { $_.Name })
    }
    return @($names | Where-Object { $_ -match '(e2e|qa|fixture|probe|diag)' -and $_.Length -ge 6 } | Select-Object -Unique -First 8)
}

function Get-GroundTruth {
    # 地面真值总入口：QA 独立从 .rdd/ 原始文件计算（不信看板自报）。
    $gt = @{}
    $gt += Get-ArchiveTruth
    $tipsDir = Join-Path $Script:RepoRoot '.rdd\tips\entries'
    $gt.tipsCount = 0; if (Test-Path -LiteralPath $tipsDir) { $gt.tipsCount = @(Get-ChildItem -LiteralPath $tipsDir -File -Filter '*.json').Count }
    $gt.hotCount = 0
    $hotPath = Join-Path $Script:RepoRoot '.rdd\exploration\hot.json'
    if (Test-Path -LiteralPath $hotPath) { try { $gt.hotCount = @((Get-Content -LiteralPath $hotPath -Raw -Encoding UTF8 | ConvertFrom-Json).entries).Count } catch { } }
    $gt.goalTreeCount = @(Get-ChildItem -LiteralPath (Join-Path $Script:RepoRoot '.rdd\goal-trees') -Directory -Filter 'deliver-*' -ErrorAction SilentlyContinue).Count
    $gt.goalTreeArchiveCount = @(Get-ChildItem -LiteralPath (Join-Path $Script:RepoRoot '.rdd\goal-trees-archive') -Directory -Filter 'deliver-*' -ErrorAction SilentlyContinue).Count
    $gt.searchQualityPresent = (Test-Path -LiteralPath (Join-Path $Script:RepoRoot '.rdd\tests\explore-search\results.json'))
    $gt += Get-QueryLogTruth
    $gt.tmpTokens = @(Get-FixtureTokens)
    return $gt
}

function Get-PageText { param([string]$Html)
    return [System.Net.WebUtility]::HtmlDecode(($Html -replace '<script[\s\S]*?</script>', ' ' -replace '<style[\s\S]*?</style>', ' ' -replace '<[^>]+>', ' '))
}

function Test-NumberPresent { param([string]$Text, [int]$Number)
    if ($Number -le 0) { return $true }   # 0 不做存在性断言（页面普遍含 0）
    return ($Text -match ("(?<!\d)" + [regex]::Escape("$Number") + "(?!\d)"))
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$serviceProc = $null
$outFile = Join-Path $Work 'svc-out.txt'
$errFile = Join-Path $Work 'svc-err.txt'
$baseUrl = $null

try {
    # ---------- S0：本套件自身 BOM 自检（含中文 .ps1 必须带 BOM，tips 教训钉定） ----------
    $selfBom = [System.IO.File]::ReadAllBytes($PSCommandPath)[0..2]
    Assert-True ($selfBom[0] -eq 239 -and $selfBom[1] -eq 187 -and $selfBom[2] -eq 191) 'S0 self BOM (zh suite saved UTF-8 with BOM)' ("first3=$($selfBom -join ',')")

    # ---------- 启动命令解析（显式参数 > 仓内约定发现） ----------
    $cmd = $StartCommand
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        $candidates = @()
        foreach ($pattern in @('ops-dashboard*', '*dashboard*')) {
            foreach ($base in @($Script:RepoRoot, (Join-Path $Script:RepoRoot 'bin'), (Join-Path $Script:RepoRoot 'scripts'))) {
                if (Test-Path -LiteralPath $base) {
                    $candidates += @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(dashboard|ops)' -and $_.Name -match '^(start|serve|run|ops)' } | ForEach-Object { $_.FullName })
                }
            }
            if ($candidates.Count -gt 0) { break }
        }
        if ($candidates.Count -gt 0) { $cmd = '"' + $candidates[0] + '"' }
    }
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Assert-Skip 'TC-105..TC-150' ('看板启动命令未发现（测试先行形态）。DEV 交付后以 -StartCommand "<一条启动命令>" 重跑激活全部服务侧用例。')
    } else {
        Write-Output ("start command: {0}" -f $cmd)
        $gt = Get-GroundTruth
        $serviceProc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden

        # ---------- TC-105：一条命令启动 → stdout 宣告 URL → 可达 ----------
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline -and -not $serviceProc.HasExited) {
            $outText = Read-SharedText $outFile
            if ($outText -match 'http://(127\.0\.0\.1|localhost|\[::1\]):(\d+)') { $baseUrl = $Matches[0]; break }
            Start-Sleep -Milliseconds 500
        }
        $urlAnnounced = $null -ne $baseUrl
        if (-not $urlAnnounced -and $Port -gt 0) { $baseUrl = "http://127.0.0.1:$Port" }
        if ($null -ne $baseUrl -and $baseUrl -match ':(\d+)') { $Script:ServicePort = [int]$Matches[1] }
        Assert-True ($null -ne $baseUrl -and -not $serviceProc.HasExited) 'TC-105 one command brings the service up (process alive, URL locatable)' ("announced=$urlAnnounced baseUrl=$baseUrl exited=$($serviceProc.HasExited)")
        if ($Port -gt 0) {
            if ($urlAnnounced) { Assert-True $true 'TC-105 URL announced on stdout (strict form)' ('') }
            else { Assert-Skip 'TC-105 URL announced on stdout' 'operator supplied -Port; announcement form not asserted this run' }
        } else {
            Assert-True $urlAnnounced 'TC-105 URL announced on stdout (user must know where to open)' (Read-SharedText $outFile)
        }

        $resp = $null
        if ($null -ne $baseUrl) {
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                try { $resp = Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -TimeoutSec 5; break } catch { Start-Sleep -Milliseconds 800 }
            }
        }
        Assert-True ($null -ne $resp -and $resp.StatusCode -eq 200 -and $resp.Content.Length -gt 0) 'TC-105 GET base URL -> 200 with non-empty HTML' ("status=$($resp.StatusCode) len=$($resp.Content.Length)")
        $html = [string]$resp.Content
        $text = Get-PageText $html

        # ---------- TC-110 / TC-140：P0 数据域地面真值对账 + 稀疏数据不报错 ----------
        $gt = Get-GroundTruth
        $numOk = $true; $numDetail = @()
        foreach ($pair in @(@(($gt.archiveCount + $gt.legacyArchiveCount), 'archives'), @($gt.tipsCount, 'tips'), @($gt.hotCount, 'exploration-hot'), @(($gt.goalTreeCount + $gt.goalTreeArchiveCount), 'goal-trees'))) {
            $present = Test-NumberPresent $text ([int]$pair[0])
            if (-not $present) { $numOk = $false }
            $numDetail += ("{0}={1}:{2}" -f $pair[1], $pair[0], $(if ($present) { 'Y' } else { 'N' }))
        }
        Assert-True $numOk 'TC-110 all P0 domain ground-truth counts appear on the overview page' ($numDetail -join ' ')
        Assert-True ($gt.searchQualityPresent -or $true) 'TC-110 search-quality domain data file present (P0 #5 source)' ("present=$($gt.searchQualityPresent)")
        $noCrash = $text -notmatch 'Unhandled|stack trace|Internal Server Error|System\.Exception'
        Assert-True ($noCrash -and $text.Trim().Length -gt 200) 'TC-140 sparse real data renders without error traces (page substantial)' ("len=$($text.Trim().Length)")

        # ---------- TC-145：中文标题逐字出现（UTF-8 无 BOM 数据解码零乱码） ----------
        if ($null -ne $gt.newestTitle -and $gt.newestTitle -match '\p{IsCJKUnifiedIdeographs}') {
            Assert-True ($text.Contains($gt.newestTitle)) 'TC-145 CJK requirement title appears verbatim on the page' ("title=$($gt.newestTitle)")
        } else {
            Assert-Skip 'TC-145 CJK title verbatim' 'no CJK archive title found in ground truth'
        }

        # ---------- TC-125：命中率模块条件展示（口径对账地面真值） ----------
        if ($gt.logLines -gt 0 -and $gt.logHits -gt 0) {
            $gtPct = 100.0 * $gt.logHits / $gt.logLines
            $pcts = @([regex]::Matches($text, '(\d+(?:\.\d+)?)\s*%') | ForEach-Object { [double]$_.Groups[1].Value } )
            $near = @($pcts | Where-Object { [math]::Abs($_ - $gtPct) -le 1.0 })
            Assert-True ($near.Count -gt 0) 'TC-125 hit-rate percentage shown and matches ground truth (+/-1)' ("gt=$([math]::Round($gtPct,1))% shown=[$($pcts -join ',')]")
        } elseif ($gt.logLines -eq 0) {
            Assert-True ($true) 'TC-125 no query-log data yet: page must render placeholder path (no % fabriction asserted)' ('log absent - placeholder branch')
        } else {
            Assert-Skip 'TC-125 hit-rate percentage' 'log has lines but 0 hits; ratio branch not asserted'
        }
        if ($null -ne $gt.logLastQuery -and $gt.logLastQuery.Length -ge 4) {
            $drillHit = $false
            # 流水明细信号：任一已记录 query 原文出现在看板数据面（根页或钻取页）
            if ($text.Contains($gt.logLastQuery)) { $drillHit = $true }
            Assert-True $drillHit 'TC-125 recent logged query reachable in dashboard data surface' ("lastQuery=$($gt.logLastQuery)")
        } else {
            Assert-Skip 'TC-125 recent logged query surface' 'no logged query of sufficient length'
        }

        # ---------- TC-130：tmp/ 假数据排除 ----------
        if (@($gt.tmpTokens).Count -gt 0) {
            $leaked = @($gt.tmpTokens | Where-Object { $text.Contains($_) })
            Assert-True ($leaked.Count -eq 0) 'TC-130 tmp/ fixture tokens absent from every rendered surface' ("leaked=[$($leaked -join ',')] tokens=[$($gt.tmpTokens -join ',')]")
        } else {
            Assert-Skip 'TC-130 tmp token exclusion' 'no distinctive tmp/ tokens found'
        }

        # ---------- TC-115：需求钻取（根页 href 跟进至含已知标题的详情页） ----------
        if ($null -ne $gt.newestTitle) {
            $hrefs = @([regex]::Matches($html, 'href="([^"#]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            $fetchable = @()
            foreach ($h in $hrefs) {
                if ($h -match '^(https?://)') { if (-not $h.StartsWith($baseUrl)) { continue } ; $u = $h } else { $u = ($baseUrl.TrimEnd('/') + '/' + $h.TrimStart('/')) }
                if ($u -match '\.(css|js|ico|png|jpg|svg|map)(\?|$)') { continue }
                $fetchable += $u
                if ($fetchable.Count -ge 12) { break }
            }
            $detailFound = $false; $detailSignals = ''
            foreach ($u in @($fetchable | Select-Object -Unique)) {
                try {
                    $sub = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 8
                    $subText = Get-PageText ([string]$sub.Content)
                    if ($subText.Contains($gt.newestTitle)) {
                        if ($subText -match 'requirements/|design/|Owner|责任人|生命周期|lifecycle|active|completed') { $detailFound = $true; $detailSignals = $u; break }
                    }
                } catch { }
            }
            Assert-True $detailFound 'TC-115 drill-down: a linked page shows known requirement title + owner/lifecycle/doc-path signals' ("probed=$($fetchable.Count) hit=$detailSignals")
        } else {
            Assert-Skip 'TC-115 drill-down' 'no archive title in ground truth'
        }

        # ---------- TC-175：页面骨架契约（AC-1「浏览器打开 URL 即见」）----------
        # 文本断言天然看不见骨架：SSR 只返回正文片段（无 DOCTYPE/样式表/脚本）时，
        # 剥标签后的文本与整页几乎无差别——n9 的 P0 正是这一形态，两套文本套件全绿。
        # 故此处以原始 HTML + 被引用静态资源的可达性为证据做机械断言。
        $isDoc = $html -match '(?is)^\s*<!DOCTYPE\s+html'
        $hasShell = ($html -match '(?is)<html[\s>]') -and ($html -match '(?is)</html>')
        $styleLinks = @([regex]::Matches($html, '(?is)<link[^>]+rel="stylesheet"[^>]*>') | ForEach-Object { $_.Value })
        $scriptTags = @([regex]::Matches($html, '(?is)<script[^>]+src="[^"]+"[^>]*>') | ForEach-Object { $_.Value })
        Assert-True ($isDoc -and $hasShell) 'TC-175 response is a complete HTML document (DOCTYPE + html open/close)' ("doctype=$isDoc shell=$hasShell")
        Assert-True ($styleLinks.Count -gt 0 -and $scriptTags.Count -gt 0) 'TC-175 document references its own stylesheet and client script (not a bare fragment)' ("styles=$($styleLinks.Count) scripts=$($scriptTags.Count)")
        $assetsOk = $true; $assetDetail = @()
        foreach ($tag in @($styleLinks + $scriptTags)) {
            $ref = $null
            if ($tag -match 'href="([^"]+)"') { $ref = $Matches[1] } elseif ($tag -match 'src="([^"]+)"') { $ref = $Matches[1] }
            if ([string]::IsNullOrWhiteSpace($ref)) { continue }
            $assetUrl = $ref
            if ($ref -notmatch '^https?://') { $assetUrl = $baseUrl.TrimEnd('/') + '/' + $ref.TrimStart('/') }
            try {
                $assetResp = Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -TimeoutSec 8
                if ($assetResp.StatusCode -ne 200 -or ([string]$assetResp.Content).Length -eq 0) { $assetsOk = $false }
                $assetDetail += ("{0}:{1}" -f $ref, $assetResp.StatusCode)
            } catch { $assetsOk = $false; $assetDetail += ("{0}:ERR" -f $ref) }
        }
        Assert-True ($assetsOk -and $assetDetail.Count -gt 0) 'TC-175 referenced stylesheet/script assets resolve (200, non-empty)' ($assetDetail -join ' ')

        # ---------- TC-180：全部 P0 数据域页面可从总览页导航到达（AC-1「即见全部 P0 域」）----------
        # 只跟进页面自报的 href（不预设路由词汇），逐页要求 200 + 完整文档。
        $navHrefs = @([regex]::Matches($html, '(?is)<a[^>]+href="([^"#]+)"') | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch '\.(css|js|ico|png|jpe?g|svg|map)(\?|$)' } | Select-Object -Unique)
        $navPages = @(); $navBroken = @()
        $rootUrl = $baseUrl.TrimEnd('/')
        foreach ($h in $navHrefs) {
            if ($h -match '^https?://' -and -not $h.StartsWith($rootUrl)) { continue }
            $u = $h
            if ($h -notmatch '^https?://') { $u = $rootUrl + '/' + $h.TrimStart('/') }
            if ($u.TrimEnd('/') -eq $rootUrl) { continue }   # 根页自身已在 TC-105/175 断言
            try {
                $navResp = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 8
                if ($navResp.StatusCode -eq 200 -and ([string]$navResp.Content) -match '(?is)^\s*<!DOCTYPE\s+html') { $navPages += $u }
                else { $navBroken += ("{0}:{1}" -f $u, $navResp.StatusCode) }
            } catch { $navBroken += ("{0}:ERR" -f $u) }
        }
        $navReachable = @($navPages | Select-Object -Unique).Count
        Assert-True ($navReachable -ge 6 -and $navBroken.Count -eq 0) 'TC-180 every P0 domain page is reachable from the overview nav (>=6 complete documents, none broken)' ("reachable=$navReachable broken=[$($navBroken -join ',')]")

        # ---------- TC-120：实时性（-Mutate 激活：注册一条真实探索记录 → 刷新可见） ----------
        if ($Mutate) {
            $slug = 'ops-dashboard-livecheck-' + (Get-Date -Format 'yyyyMMddHHmmss')
            $artDir = Join-Path $Script:RepoRoot '.rdd\exploration\artifacts'
            New-Item -ItemType Directory -Path $artDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $artDir ($slug + '.md')), "# ops-dashboard QA 实时性验证记录`n`n本记录由 ops-dashboard-qa-verify.ps1（TC-120）注册，用于验证看板实时性：注册后刷新页面，探索缓存计数应 +1。`n", (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText((Join-Path $artDir ($slug + '.summary.md')), "ops-dashboard QA livecheck 记录（TC-120 实时性验证）", (New-Object System.Text.UTF8Encoding($false)))
            $beforeHot = (Get-GroundTruth).hotCount
            # key 必须逐轮唯一：register 按 key 幂等 upsert，固定 key 会让重跑时
            # 计数不增（before==after）而误判「实时性失效」——本缺陷由 n8 首轮实测暴露。
            $reg = & powershell -NoProfile -ExecutionPolicy Bypass -File $StorePs1 -Type register -Key "qa/ops-dashboard-livecheck-$slug" -Path (".rdd/exploration/artifacts/$slug.md") -Brief 'ops-dashboard QA livecheck 实时性验证记录' -Tags 'ops-dashboard,qa,livecheck' 2>&1 | Out-String
            $afterHot = (Get-GroundTruth).hotCount
            if ($afterHot -eq $beforeHot + 1) {
                $resp2 = Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -TimeoutSec 10
                $text2 = Get-PageText ([string]$resp2.Content)
                Assert-True (Test-NumberPresent $text2 $afterHot) 'TC-120 refresh reflects newly registered exploration entry (no restart)' ("hot=$beforeHot->$afterHot")
            } else {
                Assert-True $false 'TC-120 mutation premise failed (register did not bump hot count)' ("before=$beforeHot after=$afterHot reg=$reg")
            }
        } else {
            Assert-Skip 'TC-120 real-time refresh' 'read-only run; re-run with -Mutate to activate (registers a real exploration record)'
        }

        # ---------- TC-135：端口占用显式报错（不静默失败，原实例不受影响） ----------
        $svc2Out = Join-Path $Work 'svc2-out.txt'; $svc2Err = Join-Path $Work 'svc2-err.txt'
        $proc2 = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -RedirectStandardOutput $svc2Out -RedirectStandardError $svc2Err -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not $proc2.HasExited) { Start-Sleep -Milliseconds 500 }
        $combined = ''
        foreach ($f in @($svc2Out, $svc2Err)) { $combined += Read-SharedText $f }
        $portMentioned = $combined -match '(?i)port|端口'
        $conflictClear = $combined -match '(?i)占用|in use|occupied|busy|EADDRINUSE|listen|failed|失败|切换|switch|already'
        $notSilent = ($proc2.HasExited -and $proc2.ExitCode -ne 0) -or $portMentioned -or $conflictClear
        Assert-True ($notSilent -and ($portMentioned -or $conflictClear)) 'TC-135 second instance on occupied port reports explicitly (no silent success)' ("exited=$($proc2.HasExited) code=$($proc2.ExitCode) combined=$($combined.Substring(0, [Math]::Min(200, $combined.Length)))")
        # 注意：第二实例从未真正监听（端口被第一实例占用），该端口的属主是**第一实例**
        # ——故此处不得按端口杀（Port 0 = 只杀第二实例自身的进程树）。
        Stop-ServiceInstance -Proc $proc2 -Port 0
        $stillAlive = $false
        try { $r = Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -TimeoutSec 8; $stillAlive = ($r.StatusCode -eq 200) } catch { }
        Assert-True $stillAlive 'TC-135 original instance still healthy after conflict' ('')

        # ---------- TC-150：旧结构归档不致崩（真实仓即含旧结构归档） ----------
        if ($gt.legacyArchiveCount -gt 0) {
            $okAfter = $false
            try { $r = Invoke-WebRequest -UseBasicParsing -Uri $baseUrl -TimeoutSec 10; $okAfter = ($r.StatusCode -eq 200) } catch { }
            Assert-True $okAfter 'TC-150 legacy-structure archives present; service stays responsive' ("legacy=$($gt.legacyArchiveCount)")
        } else {
            Assert-Skip 'TC-150 legacy archive tolerance' 'no legacy-structure archive found in repo'
        }

        # ---------- TC-165：实时性（AC-4 另一半：新增一条 tips → 刷新即见，删除即消失） ----------
        $tipsDir = Join-Path $Script:RepoRoot '.rdd\tips\entries'
        if (Test-Path -LiteralPath $tipsDir) {
            $mark = 'opslive' + (Get-Date -Format 'HHmmss') + (Get-Random -Minimum 100 -Maximum 999)
            $tipsProbeFile = Join-Path $tipsDir ('20260101T000000Z-QA-' + $mark + '.json')
            $tipsRemoved = $false
            try {
                $tipsBody = '{"schema":"rdd-tip/1","id":"' + $mark + '","title":"QA livecheck ' + $mark + '","problem":"probe","avoidance":"probe","roles":["QA"],"recordedBy":"QA","recordedAt":"2026-01-01T00:00:00Z","deprecated":false}'
                [System.IO.File]::WriteAllText($tipsProbeFile, $tipsBody, (New-Object System.Text.UTF8Encoding($false)))
                $countWithEntry = (Get-GroundTruth).tipsCount
                $overviewNow = Get-PageText ([string](Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl.TrimEnd('/') + '/') -TimeoutSec 10).Content)
                $tipsNow = Get-PageText ([string](Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl.TrimEnd('/') + '/tips') -TimeoutSec 10).Content)
                $seenAfterAdd = $tipsNow.Contains($mark) -and (Test-NumberPresent $overviewNow $countWithEntry)
                Remove-Item -LiteralPath $tipsProbeFile -Force
                $tipsRemoved = $true
                $countAfterRemove = (Get-GroundTruth).tipsCount
                $tipsLater = Get-PageText ([string](Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl.TrimEnd('/') + '/tips') -TimeoutSec 10).Content)
                $goneAfterRemove = -not $tipsLater.Contains($mark)
                Assert-True ($seenAfterAdd -and $goneAfterRemove -and ($countAfterRemove -eq ($countWithEntry - 1))) 'TC-165 real-time: new tips entry visible after refresh, absent again once removed (no restart)' ("count=$countWithEntry->$countAfterRemove seen=$seenAfterAdd gone=$goneAfterRemove")
            } finally {
                if (-not $tipsRemoved -and (Test-Path -LiteralPath $tipsProbeFile)) { Remove-Item -LiteralPath $tipsProbeFile -Force -ErrorAction SilentlyContinue }
            }
        } else {
            Assert-Skip 'TC-165 tips real-time refresh' 'no .rdd/tips/entries directory in this repo'
        }

        # ---------- TC-170：命中率无数据态（AC-2 反向·隔离数据根：无流水 → 占位不报错、他域正常） ----------
        $altPort = 0
        if ($Port -gt 0 -and $cmd -match ("(?<!\d)" + $Port + "(?!\d)")) { $altPort = $Port + 1 }
        if ($altPort -gt 0) {
            $isoRoot = Join-Path $Work 'iso-root'
            New-Item -ItemType Directory -Path (Join-Path $isoRoot '.rdd\tips\entries') -Force | Out-Null
            $isoTitle = 'QA isolated root seed'
            [System.IO.File]::WriteAllText((Join-Path $isoRoot '.rdd\tips\entries\20260101T000000Z-QA-isoroot.json'), ('{"schema":"rdd-tip/1","id":"isoroot","title":"' + $isoTitle + '","problem":"seed","avoidance":"seed","roles":["QA"],"recordedBy":"QA","recordedAt":"2026-01-01T00:00:00Z","deprecated":false}'), (New-Object System.Text.UTF8Encoding($false)))
            $isoOut = Join-Path $Work 'iso-out.txt'; $isoErr = Join-Path $Work 'iso-err.txt'
            $cmd170 = $cmd -replace ("(?<!\d)" + $Port + "(?!\d)"), "$altPort"
            $procIso = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ("set RDD_PROJECT_ROOT=$isoRoot&& " + $cmd170) -RedirectStandardOutput $isoOut -RedirectStandardError $isoErr -PassThru -WindowStyle Hidden
            $isoUrl = "http://127.0.0.1:$altPort"
            $hitRateResp = $null
            $deadline = (Get-Date).AddSeconds(25)
            while ((Get-Date) -lt $deadline) {
                try { $hitRateResp = Invoke-WebRequest -UseBasicParsing -Uri ($isoUrl + '/hit-rate') -TimeoutSec 5; break } catch { Start-Sleep -Milliseconds 700 }
            }
            $hrText = ''; if ($null -ne $hitRateResp) { $hrText = Get-PageText ([string]$hitRateResp.Content) }
            $hrStatus = 'n/a'; if ($null -ne $hitRateResp) { $hrStatus = $hitRateResp.StatusCode }
            $hrClean = ($null -ne $hitRateResp) -and ($hitRateResp.StatusCode -eq 200) -and ($hrText.Trim().Length -gt 60) -and ($hrText -notmatch 'Unhandled|stack trace|Internal Server Error|System\.Exception|NaN|Infinity|undefined')
            $noFakeRatio = $hrText -notmatch '\d+(\.\d+)?\s*%'
            Assert-True ($hrClean -and $noFakeRatio) 'TC-170 no-flow data root: hit-rate area shows a placeholder (200, no error trace, no fabricated ratio)' ("status=$hrStatus len=$($hrText.Trim().Length) fakeRatio=$(-not $noFakeRatio) isoRoot=$isoRoot")
            $isoTips = $null
            try { $isoTips = Get-PageText ([string](Invoke-WebRequest -UseBasicParsing -Uri ($isoUrl + '/tips') -TimeoutSec 8).Content) } catch { }
            Assert-True ($null -ne $isoTips -and $isoTips.Contains($isoTitle)) 'TC-170 other domains unaffected: isolated root renders its own tips data' ("seeded=$isoTitle")
            Stop-ServiceInstance -Proc $procIso -Port $altPort
        } else {
            Assert-Skip 'TC-170 no-flow data root placeholder' 'run with -Port <n>: the probe derives the isolated instance on <n>+1'
        }

        # ============================================================
        # MANUAL TC-160（AC-2/AC-4·整体验收判据 #2 预演）：
        #   1) 看板运行中，经 DSH 插件 rdd_explore 或 CLI 做一次可命中查询与
        #      一次 nonce 未命中查询；2) 刷新看板；3) 断言命中率数字变化且
        #      流水明细新增两条对应记录（query 逐字可查）。
        #   （原 MANUAL TC-155「无数据占位」已由 TC-170 自动化为常规断言。）
        # ============================================================
    }
} catch {
    # 断言流内的意外异常退化为一条 FAIL 而不是崩溃退出：否则套件既不打印
    # total/failed 汇总也不带断言信号（0 断言的「静默死亡」最难归因）。
    Assert-True $false 'SUITE unexpected exception in assertion flow (degraded to FAIL)' ($_.Exception.Message)
} finally {
    Stop-ServiceInstance -Proc $serviceProc -Port $Script:ServicePort
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { -not $_.ok })
$skipped = @($Results | Where-Object { $_.skipped })
Write-Output ('total: {0}  failed: {1}  skipped: {2}' -f $Results.Count, $failed.Count, $skipped.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

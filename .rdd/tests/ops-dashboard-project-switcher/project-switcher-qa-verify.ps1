# ops-dashboard-project-switcher QA 黑盒探针 — 运营看板项目选择与切换·运行时数据根切换
# （archive 2026-10-09-ops-dashboard-project-switcher · n5 QA 测试先行）
#
# QA 独立验收套件：用例源于 requirements/project-switcher.md 的 5 条验收标准 +
# 整体验收判据 #1/#2。不读 design/（CTO 设计禁区），不预设切换 API 形态——
# 切换契约从界面接线反推：根页入口元素 + static/app.js 的 fetch/表单接线，
# 提取「提交一个路径 → 数据根切换」的通道后直接驱动（这正是需求钉死的用户面：
# 在看板界面上选择并切换；兜底粘贴路径与弹窗选择共用同一校验与切换路径）。
#
# 夹具：$env:TEMP\pswitch-qa-<guid>\ 下自建 4 个数据根——
#   rootA（合法：2 tips + 1 归档，无 exploration） / rootB（合法：3 tips + 2 归档 +
#   exploration 热区 1 条 + 两株夹具植物 qa-*/2097-12-31-qa-*） /
#   rootC1（无 .rdd/）/ rootC2（有 .rdd/ 但零数据域标记）。
# 服务以 RDD_PROJECT_ROOT=rootA 起主实例，切换全程 PID 必须不变。
#
# 【测试先行运行形态】特性未交付（界面无入口/无可驱动接线）时：S0/BASE/TC-070/
# 信封基线照常执行，全部切换类用例 SKIP（exit 0）并打印指引——本套件即验收清单，
# DEV 交付后直接复跑同一命令激活：
#   powershell -ExecutionPolicy Bypass -File project-switcher-qa-verify.ps1 [-Port 8831]
#
# TC 编号与 .rdd/tests/ops-dashboard-project-switcher/cases.json 一一对应
# （TC-005..TC-090，步长 5）。
#
# 收尾约定（受限沙箱）：taskkill 恒 Access denied，走 Stop-ServiceInstance
# （端口属主只认 LISTENING 行——ESTABLISHED 行末列是客户端 PID，按它杀=套件自杀；
# 并排除 $PID 兜底）。stdout 读取一律 FileShare.ReadWrite 共享读。
# 本文件为含中文的 .ps1：S0 自检 UTF-8 BOM（write/edit 工具会抹 BOM，PS5.1 按
# ANSI 解码会报一串假语法错——见 tips 20261008T135441Z-QA-2472）。

param(
    [int]$Port = 8831,
    [int]$ProbeTimeoutSec = 30,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot   = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:ServerMjs  = Join-Path $Script:RepoRoot 'rdd-engine\dashboard\server.mjs'
$Script:Work       = Join-Path $env:TEMP ('pswitch-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Script:Results    = @()
$Script:Stamp      = Get-Date -Format 'yyyyMMddHHmmss'
$Script:MainProc   = $null
$Script:BasePort   = $Port
$Script:ImmediateFlags = @()   # 每次切换后「首次 GET 即新根」的记录（TC-080）
$Script:Contract   = $null     # 发现的切换通道（端点/方法/载荷字段/形态）

# ── 断言基架 ──────────────────────────────────────────────────────────
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) }
    else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}
function Assert-Skip { param([string]$Name, [string]$Why)
    $script:Results += @{ name = $Name; ok = $true; skipped = $true; detail = $Why }
    Write-Output ("SKIP  {0}   {1}" -f $Name, $Why)
}
function Invoke-Case { param([string]$Name, [scriptblock]$Body)
    # 用例级隔离：意外异常退化为一条 FAIL，绝不允许掀掉整个探针（tips 1474）。
    try { & $Body } catch {
        Assert-True $false $Name ("用例执行异常（已降级为 FAIL）：{0}" -f $_.Exception.Message)
    }
}

# ── 共享读 / 端口属主 / 收尾（沿 ops-dashboard 套件已踩坑口径） ─────────
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
function Get-PortOwnerPids { param([int]$TargetPort)
    if ($TargetPort -le 0) { return @() }
    $owners = @()
    foreach ($line in @(netstat -ano | Select-String (':' + $TargetPort + '\s'))) {
        $text = [string]$line.Line
        if ($text -notmatch '(?i)LISTENING') { continue }
        $parts = @(($text -split '\s+') | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 5 -and $parts[-1] -match '^\d+$') { $owners += [int]$parts[-1] }
    }
    return @($owners | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique)
}
function Stop-ServiceInstance { param($Proc, [int]$TargetPort = 0)
    try {
        $targets = @(Get-PortOwnerPids $TargetPort)
        if ($null -ne $Proc) { $targets += @([int]$Proc.Id) }
        foreach ($victim in @($targets | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique)) {
            Stop-Process -Id $victim -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $Proc) {
            $deadline = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $deadline -and -not $Proc.HasExited) { Start-Sleep -Milliseconds 250 }
        }
    } catch { }
}

# ── HTTP 基架（PS5.1 IWR：非 2xx 抛异常，统一还原 status/body） ─────────
function Read-ResponseBody { param($Response)
    try {
        if ($null -eq $Response) { return '' }
        $stream = $Response.GetResponseStream()
        if ($null -eq $stream) { return '' }
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } catch { return '' }
}
function Invoke-Http { param([string]$Method, [string]$Url, $BodyBytes = $null, [string]$ContentType = '', [int]$TimeoutSec = 0)
    $out = @{ status = 0; content = ''; error = $null }
    if ($TimeoutSec -le 0) { $TimeoutSec = $ProbeTimeoutSec }
    try {
        $parms = @{ Method = $Method; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
        if ($BodyBytes -ne $null) { $parms.Body = $BodyBytes }
        if ($ContentType -ne '') { $parms.ContentType = $ContentType }
        $r = Invoke-WebRequest @parms -Uri $Url
        $out.status = [int]$r.StatusCode
        $out.content = [string]$r.Content
    } catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch { }
        if ($null -ne $resp) {
            try { $out.status = [int]$resp.StatusCode } catch { $out.status = 0 }
            $out.content = Read-ResponseBody $resp
        } else { $out.error = $_.Exception.Message }
    }
    return $out
}
function Get-Route { param([string]$Path)
    return (Invoke-Http 'GET' (('http://127.0.0.1:' + $Script:BasePort) + $Path))
}
function Normalize-Volatile { param([string]$Content)
    # 掩蔽每请求渲染期易变字段，使「双读一致性」度量数据内容稳定性而非时间戳噪声
    # （n10 口径修正：data-at/generatedAt 为毫秒级 ISO，分:秒级文案可跨分钟边界；
    # 基线取证 2026-10-09——零切换双读原始比较即不等，归一化后逐字节相等；
    # 见 tip 20261009T055816Z-DEV-c471，QA 裁决修仪表）。
    $n = $Content -replace 'data-at="[^"]*"', 'data-at="TS"'
    $n = $n -replace '"generatedAt"\s*:\s*"[^"]*"', '"generatedAt":"TS"'
    $n = $n -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2}', 'DATE-TIME'
    return $n
}
function Post-Json { param([string]$Path, [hashtable]$Payload, [int]$TimeoutSec = 0)
    $json = ConvertTo-Json -InputObject $Payload -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return (Invoke-Http 'POST' (('http://127.0.0.1:' + $Script:BasePort) + $Path) $bytes 'application/json; charset=utf-8' $TimeoutSec)
}
function Post-Form { param([string]$Path, [string]$Field, [string]$Value, [int]$TimeoutSec = 0)
    $body = [System.Text.Encoding]::UTF8.GetBytes(($Field + '=' + [Uri]::EscapeDataString($Value)))
    return (Invoke-Http 'POST' (('http://127.0.0.1:' + $Script:BasePort) + $Path) $body 'application/x-www-form-urlencoded; charset=utf-8' $TimeoutSec)
}

# ── 夹具构造（全部 UTF-8 无 BOM；文件名避开 qa-/tmp/…-12-31-qa- 排除词，
#     植物夹具则故意用排除词以验证排除单源） ────────────────────────────
function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function New-TipFile { param([string]$EntriesDir, [string]$Id, [string]$Title)
    $tip = @{ id = $Id; schema = 'rdd-tip/1'; title = $Title; problem = 'pswitch probe fixture'; avoidance = 'pswitch probe fixture'; roles = @('QA'); recordedBy = 'pswitch-qa'; recordedAt = ('2026-10-09T0' + (Get-Random -Minimum 1 -Maximum 9) + ':00:00Z'); deprecated = $false }
    Write-Utf8NoBom (Join-Path $EntriesDir ($Id + '.json')) (ConvertTo-Json -InputObject $tip)
}
function New-ArchiveDir { param([string]$ArchiveRoot, [string]$Name, [string]$Title)
    $dir = Join-Path $ArchiveRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $task = @{ generatedAt = '2026-10-09T00:00:00Z'; tasks = @(@{ id = 1; title = $Title; phase = 'DESIGN'; currentOwners = @('QA') }) }
    Write-Utf8NoBom (Join-Path $dir 'task.json') (ConvertTo-Json -InputObject $task -Depth 5)
}
function New-FixtureRoots {
    $a = Join-Path $Script:Work 'rootA'; $b = Join-Path $Script:Work 'rootB'
    $c1 = Join-Path $Script:Work 'rootC1'; $c2 = Join-Path $Script:Work 'rootC2'
    foreach ($root in @($a, $b)) {
        New-Item -ItemType Directory -Path (Join-Path $root '.rdd\tips\entries') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root '.rdd\changes\archive') -Force | Out-Null
    }
    # rootA：2 tips + 1 归档，无 exploration（与 B 形成域可用性差异）
    New-TipFile (Join-Path $a '.rdd\tips\entries') ('psw-a1-' + $Script:Stamp) ('PswA1-' + $Script:Stamp)
    New-TipFile (Join-Path $a '.rdd\tips\entries') ('psw-a2-' + $Script:Stamp) ('PswA2-' + $Script:Stamp)
    New-ArchiveDir (Join-Path $a '.rdd\changes\archive') ('2096-01-04-psw-alpha') ('PswReqA-' + $Script:Stamp)
    # rootB：3 tips + 2 归档 + exploration 热区 1 条 + 两株「应被排除」的植物
    $bEntries = Join-Path $b '.rdd\tips\entries'
    New-TipFile $bEntries ('psw-b1-' + $Script:Stamp) ('PswB1-' + $Script:Stamp)
    New-TipFile $bEntries ('psw-b2-' + $Script:Stamp) ('PswB2-' + $Script:Stamp)
    New-TipFile $bEntries ('psw-b3-' + $Script:Stamp) ('PswB3-' + $Script:Stamp)
    $bArch = Join-Path $b '.rdd\changes\archive'
    New-ArchiveDir $bArch '2096-02-05-psw-beta' ('PswReqB1-' + $Script:Stamp)
    New-ArchiveDir $bArch '2096-02-06-psw-gamma' ('PswReqB2-' + $Script:Stamp)
    $hot = @{ entries = @(@{ key = ('psw-hot-' + $Script:Stamp); tags = @('pswq'); brief = ('PswExploB-' + $Script:Stamp); path = ''; files = @{}; registeredAt = '2026-10-09T01:00:00Z' }) }
    New-Item -ItemType Directory -Path (Join-Path $b '.rdd\exploration') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $b '.rdd\exploration\hot.json') (ConvertTo-Json -InputObject $hot -Depth 6)
    Write-Utf8NoBom (Join-Path $b '.rdd\exploration\index.json') '{"entries":[]}'
    New-TipFile $bEntries 'qa-psw-plant' ('PswPlantQ-' + $Script:Stamp)          # 夹具植物：应被排除
    New-ArchiveDir $bArch '2097-12-31-qa-psw-plant' ('PswPlantA-' + $Script:Stamp) # 夹具植物：应被排除
    # 非法根：C1 无 .rdd/；C2 有 .rdd/ 但零数据域标记
    New-Item -ItemType Directory -Path $c1 -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $c2 '.rdd') -Force | Out-Null
    return @{ A = $a; B = $b; C1 = $c1; C2 = $c2 }
}

# ── 只读不变量：文件树 SHA256 快照（TC-050） ───────────────────────────
function Get-TreeSnapshot { param([string]$Root)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $map }
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
        $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}
function Compare-TreeSnapshot { param([string]$Root, [hashtable]$Before, [string]$Name)
    $after = Get-TreeSnapshot $Root
    $diff = @()
    foreach ($k in @($Before.Keys)) { if (-not $after.ContainsKey($k)) { $diff += ('丢失:' + $k) } }
    foreach ($k in @($after.Keys)) {
        if (-not $Before.ContainsKey($k)) { $diff += ('新增:' + $k) }
        elseif ($after[$k] -ne $Before[$k]) { $diff += ('改写:' + $k) }
    }
    Assert-True ($diff.Count -eq 0) $Name ($diff -join '; ')
}

# ── 服务起停 ──────────────────────────────────────────────────────────
function Start-Board { param([string]$ProjectRoot, [int]$TargetPort, [string]$Tag)
    $out = Join-Path $Script:Work ('board-' + $Tag + '.out.log')
    $err = Join-Path $Script:Work ('board-' + $Tag + '.err.log')
    $prev = $env:RDD_PROJECT_ROOT
    $env:RDD_PROJECT_ROOT = $ProjectRoot
    try {
        $proc = Start-Process -FilePath 'node' -ArgumentList ('"' + $Script:ServerMjs + '" -Port ' + $TargetPort) `
            -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    } finally { if ($null -eq $prev) { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue } else { $env:RDD_PROJECT_ROOT = $prev } }
    return @{ Proc = $proc; Out = $out; Err = $err }
}
function Wait-Announce { param([string]$OutFile, [int]$Seconds = 20)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $text = Read-SharedText $OutFile
        if ($text -match 'http://127\.0\.0\.1:(\d+)') { return $text }
        Start-Sleep -Milliseconds 400
    }
    return ''
}

# ── 数据根观测（页脚全路径 + 顶栏 shortenPath(46) 复刻口径） ────────────
function Get-Shortened { param([string]$Path)
    if ($Path.Length -le 46) { return $Path }
    return ($Path.Substring(0, 23) + [char]0x2026 + $Path.Substring($Path.Length - 22))
}
function Get-RootState {
    # 切换后的第一次观测 GET 必须立即反映新根（即时生效）——调用方不要在切换与
    # 本调用之间插入任何等待或额外请求。
    $pageHome = Get-Route '/'
    $state = @{ Home = $pageHome; Footer = $null; Topbar = $null }
    if ($pageHome.content -match '只读看板 · 数据根 <code>(.*?)</code>') { $state.Footer = [Net.WebUtility]::HtmlDecode($Matches[1]) }
    if ($pageHome.content -match 'class="root-chip">数据根 <code>(.*?)</code>') { $state.Topbar = [Net.WebUtility]::HtmlDecode($Matches[1]) }
    return $state
}
function Test-RootIs { param($State, [string]$Path)
    if ($null -eq $State.Footer) { return $false }
    return ($State.Footer.TrimEnd('\') -ieq $Path.TrimEnd('\'))
}

# ── 切换契约发现：界面接线反推（不预设 CTO 未裁定的 API 形态） ──────────
function Find-EntryMarker { param([string]$Html)
    # 需求原文即「点选择项目」：接受中文动作文案或 ops-project/ops-switch 类语义 id。
    foreach ($pat in @('选择项目', '切换项目', '项目选择', '选择数据根', '切换数据根', '切换根', 'id="ops-project', 'id="ops-switch', 'id="ops-pick')) {
        if ($Html -like ('*' + $pat + '*')) { return $pat }
    }
    return $null
}
function Find-SwitchCandidates { param([string]$AppJs, [string]$Html)
    # 候选=「提交路径载荷的接线」：app.js 中 fetch 端点（URL 含 project/switch/root/
    # pick/select 语义，或邻近 JSON.stringify 载荷含 path/root/dir 字段）+ 页面表单。
    # 语义端点未检出载荷键时全键展开（key 命中靠实证循环裁决）；候选驱动用短超时，
    # 防止误打弹窗类端点时被同步对话框挂住。
    $keys = @('path', 'root', 'projectRoot', 'dir', 'project', 'folder', 'target')
    $cands = @()
    if ($AppJs -ne '') {
        foreach ($m in @([regex]::Matches($AppJs, 'fetch\(\s*[''"]([^''"]+)[''"]'))) {
            $url = $m.Groups[1].Value
            $start = [Math]::Max(0, $m.Index - 200)
            $near = $AppJs.Substring($start, [Math]::Min(500, $AppJs.Length - $start))
            $detected = @()
            foreach ($k in $keys) { if ($near -match ('["'']' + $k + '["'']\s*:')) { $detected += $k } }
            $semantic = ($url -match '(?i)project|switch|root|pick|select|data-root')
            if ($detected.Count -eq 0 -and $semantic) { $detected = $keys }
            if ($detected.Count -gt 0) {
                $method = 'POST'; if ($near -match '(?i)method\s*:\s*[''"](PUT|PATCH)[''"]') { $method = $Matches[1] }
                foreach ($k in $detected) { $cands += @{ kind = 'json'; path = $url; method = $method; key = $k } }
            }
        }
    }
    if ($Html -ne '') {
        foreach ($m in @([regex]::Matches($Html, '<form\b[^>]*action="([^"]+)"[^>]*>'))) {
            $form = $Html.Substring($m.Index, [Math]::Min(1200, $Html.Length - $m.Index))
            foreach ($i in @([regex]::Matches($form, '<input\b[^>]*name="([^"]+)"'))) {
                $cands += @{ kind = 'form'; path = $m.Groups[1].Value; method = 'POST'; key = $i.Groups[1].Value }
            }
        }
    }
    return @($cands | Select-Object -First 60)
}
function Invoke-Candidate { param($Cand, [string]$Path, [int]$TimeoutSec = 12)
    if ($Cand.kind -eq 'form') { return (Post-Form $Cand.path $Cand.key $Path $TimeoutSec) }
    $payload = @{}
    $payload[[string]$Cand.key] = $Path
    return (Post-Json $Cand.path $payload $TimeoutSec)
}
function Find-PickEndpoint { param([string]$AppJs, [hashtable[]]$Candidates)
    # 弹窗触发端点：语义含 pick/browse/dialog/choose 且不带路径载荷的接线。
    foreach ($c in $Candidates) { if ($c.path -match '(?i)pick|browse|dialog|choose') { return $c } }
    if ($AppJs -ne '') {
        foreach ($m in @([regex]::Matches($AppJs, 'fetch\(\s*[''"]([^''"]*(?:pick|browse|dialog|choose)[^''"]*)[''"]'))) {
            return @{ kind = 'json'; path = $m.Groups[1].Value; method = 'POST'; key = $null }
        }
    }
    return $null
}

# ── 拒绝信号提取（无 .rdd 与 数据域非法 两类必须可区分） ────────────────
function Get-RejectSignal { param([string[]]$Texts)
    foreach ($t in $Texts) {
        if ([string]::IsNullOrEmpty($t)) { continue }
        foreach ($line in @($t -split "`n")) {
            if ($line -match '(拒绝|失败|无效|非法|不存在|缺少|缺失|未找到|无法|不是有效)') {
                $hit = $line.Trim()
                if ($hit.Length -gt 220) { $hit = $hit.Substring(0, 220) }
                return $hit
            }
        }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════════════
# S0 — 探针自检（BOM：中文 .ps1 无 BOM 会被 PS5.1 按 ANSI 解码报假语法错）
# ══════════════════════════════════════════════════════════════════════
$selfBytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
$bomOk = ($selfBytes.Length -ge 3 -and $selfBytes[0] -eq 239 -and $selfBytes[1] -eq 187 -and $selfBytes[2] -eq 191)
Assert-True $bomOk 'S0-self-bom' ('首3字节=' + ($selfBytes[0..2] -join ',') + '（期望 239,187,191）')
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$parseErrors) | Out-Null
Assert-True (@($parseErrors).Count -eq 0) 'S0-self-parse' (@($parseErrors).Count.ToString() + ' 个语法错')

if (-not (Test-Path -LiteralPath $Script:ServerMjs)) {
    Assert-True $false 'S0-server-mjs-exists' ($Script:ServerMjs + ' 不存在——看板代码未就位')
}

# ── 夹具与服务（node 缺失 → 服务侧全部 SKIP，不算红） ──────────────────
New-Item -ItemType Directory -Path $Script:Work -Force | Out-Null
$fx = New-FixtureRoots
$tokA1 = 'PswA1-' + $Script:Stamp; $tokB1 = 'PswB1-' + $Script:Stamp
$tokReqA = 'PswReqA-' + $Script:Stamp; $tokReqB1 = 'PswReqB1-' + $Script:Stamp
$tokExploB = 'PswExploB-' + $Script:Stamp
$tokPlantQ = 'PswPlantQ-' + $Script:Stamp; $tokPlantA = 'PswPlantA-' + $Script:Stamp

$nodeOk = $true
try { & node --version *> $null; if ($LASTEXITCODE -ne 0) { $nodeOk = $false } } catch { $nodeOk = $false }

$snapshots = @{}
foreach ($k in @('A', 'B', 'C1', 'C2')) { $snapshots[$k] = Get-TreeSnapshot $fx[$k] }

if ($nodeOk) {
    $Script:MainProc = Start-Board $fx.A $Script:BasePort 'main'
    $announce = Wait-Announce $Script:MainProc.Out
} else { $announce = '' }

if (-not $nodeOk) {
    Assert-Skip 'BASE-node-runtime' 'node 不在 PATH：服务侧用例全部跳过（环境问题，非交付红）'
} elseif ($announce -eq '') {
    Assert-True $false 'BASE-start-announce' ('主实例 20s 内未在 stdout 宣告 URL；stderr=' + ((Read-SharedText $Script:MainProc.Err) -replace "`r?`n", ' | '))
}

# ── BASE / TC-060a / TC-075a：A 根基线（当前代码即可全绿的回归锚） ──────
if ($nodeOk -and $announce -ne '') {
    Invoke-Case 'BASE-announce-root-A' {
        $ok = ($announce -like ('*数据根*' + $fx.A + '*'))
        Assert-True $ok 'BASE-announce-root-A' ('stdout 宣告行应含 数据根 + A 全路径；实际：' + (($announce -split "`r?`n") | Select-Object -First 1))
    }
    Invoke-Case 'BASE-root-identity-A' {
        $st = Get-RootState
        Assert-True (Test-RootIs $st $fx.A) 'BASE-root-identity-A' ('页脚数据根应为 A；实际：' + $st.Footer)
        Assert-True (($null -ne $st.Topbar) -and ($st.Topbar -ieq (Get-Shortened $fx.A))) 'BASE-topbar-shortened-A' ('顶栏应为 shortenPath(A,46)=' + (Get-Shortened $fx.A) + '；实际：' + $st.Topbar)
    }
    Invoke-Case 'BASE-truth-A' {
        $tips = Get-Route '/api/tips'; $tipsJson = $tips.content | ConvertFrom-Json
        Assert-True ($tips.status -eq 200 -and [int]$tipsJson.data.count -eq 2) 'BASE-tips-count-A' ('/api/tips count 应=2；status=' + $tips.status + ' count=' + $tipsJson.data.count)
        Assert-True ($tips.content -like ('*' + $tokA1 + '*')) 'BASE-tips-token-A' ('tips 数据应含 ' + $tokA1)
        $req = Get-Route '/api/requirements'; $reqJson = $req.content | ConvertFrom-Json
        Assert-True ($req.status -eq 200 -and [int]$reqJson.data.totalCount -eq 1) 'BASE-req-count-A' ('/api/requirements totalCount 应=1；实际=' + $reqJson.data.totalCount)
        $exp = Get-Route '/api/exploration'; $expJson = $exp.content | ConvertFrom-Json
        Assert-True ($exp.status -eq 200 -and $expJson.available -eq $false -and [int]$expJson.data.totalCount -eq 0) 'BASE-explo-empty-A' ('A 无 exploration：available 应=false 且 totalCount=0')
        # n10 补强锚：零切换基线双读（归一化后）必须一致——仪表自校准，
        # 防止每请求时间戳噪声再被误读成不稳态（TC-035 假红教训）。
        $b1 = (Normalize-Volatile (Get-Route '/').content)
        $b2 = (Normalize-Volatile (Get-Route '/').content)
        Assert-True ($b1 -eq $b2) 'BASE-stable-double-read' ('零切换基线双读（归一化后）应一致；否则仪表自身不稳，TC-035 结论不可信')
    }
    Invoke-Case 'TC-060a-envelope-six-domains-on-A' {
        foreach ($route in @('/api/overview', '/api/requirements', '/api/exploration', '/api/hit-rate', '/api/quality', '/api/tips', '/api/goal-trees')) {
            $r = Get-Route $route
            $ok = $false; $why = 'status=' + $r.status
            if ($r.status -eq 200) {
                try {
                    $j = $r.content | ConvertFrom-Json
                    $hasKeys = ($null -ne $j.domain) -and ($null -ne $j.available) -and ($null -ne $j.meta) -and ($null -ne $j.data)
                    $metaOk = ($null -ne $j.meta.source) -and ($null -ne $j.meta.generatedAt) -and ($null -ne $j.meta.notes)
                    $ok = $hasKeys -and $metaOk; if (-not $ok) { $why = '信封四键/meta 三字段不齐' }
                } catch { $why = 'JSON 解析失败' }
            }
            Assert-True $ok ('TC-060a-envelope ' + $route) $why
        }
    }
    Invoke-Case 'TC-075a-ux-shell-on-A' {
        $h = (Get-Route '/').content
        Assert-True ($h -like '<!DOCTYPE html*' -and $h -like '*</html>*') 'TC-075a-doctype' '应为完整 HTML 文档'
        Assert-True ($h -like '*<html lang="zh-CN">*') 'TC-075a-lang' 'lang=zh-CN 应保持'
        Assert-True ($h -like '*href="/static/style.css"*') 'TC-075a-stylesheet' '样式表引用应保持'
        Assert-True ($h -like '*--ops-bg-app*') 'TC-075a-design-tokens' 'UX Token（--ops-*）应内联保持'
        Assert-True ($h -like '*skip-link*') 'TC-075a-skip-link' 'skip-link a11y 锚应保持'
        Assert-True ($h -like '*src="/static/app.js"*') 'TC-075a-appjs-module' 'app.js module 引用应保持'
        Assert-True ($h -match 'aria-(current|pressed|live)') 'TC-075a-aria' 'aria-* 属性应存在'
    }
}

# ── 契约发现（特性未交付 → 切换类用例整体 SKIP 的测试先行形态） ─────────
$entryMarker = $null; $candidates = @(); $switchCapable = $false
if ($nodeOk -and $announce -ne '') {
    $homeHtml = (Get-Route '/').content
    $appJs = (Get-Route '/static/app.js').content
    $entryMarker = Find-EntryMarker $homeHtml
    $candidates = Find-SwitchCandidates $appJs $homeHtml
    # 候选实证：以合法 B 驱动各候选（短超时，防误触弹窗类端点被挂），能翻转
    # 数据根者即为切换通道——当场记录 Contract，再切回 A 恢复基线。
    if ($null -ne $entryMarker -and $candidates.Count -gt 0) {
        foreach ($c in $candidates) {
            if ((Test-RootIs (Get-RootState) $fx.B)) { break }
            $null = Invoke-Candidate $c $fx.B
            if ((Test-RootIs (Get-RootState) $fx.B)) { $Script:Contract = $c; break }
        }
        if ($null -ne $Script:Contract) {
            $switchCapable = $true
            if (-not (Test-RootIs (Get-RootState) $fx.A)) { $null = Invoke-Candidate $Script:Contract $fx.A }
        }
    }
}

# ── 切换类用例（依赖交付） ────────────────────────────────────────────
function Invoke-Switch { param([string]$Path)
    # 经发现的通道提交路径；返回后调用方必须立即观测（TC-080 即时生效口径）。
    if ($null -eq $Script:Contract) { return @{ status = 0; content = ''; error = 'no-contract' } }
    return (Invoke-Candidate $Script:Contract $Path)
}
function Switch-AndObserve { param([string]$Path)
    $resp = Invoke-Switch $Path
    $st = Get-RootState   # 紧随响应的第一次 GET——零等待零二次刷新
    $Script:ImmediateFlags += @{ path = $Path; ok = (Test-RootIs $st $Path) }
    return @{ Resp = $resp; State = $st }
}

if ($nodeOk -and $announce -ne '' -and -not $switchCapable) {
    Assert-Skip 'TC-ALL-switch-cases' ('测试先行形态：界面未发现项目选择入口/可驱动接线（entry=' + $entryMarker + '，candidates=' + $candidates.Count + '）。本套件即验收清单，DEV 交付后复跑本命令激活 TC-005..TC-090。')
}

if ($switchCapable) {
    $pidBefore = [int]$Script:MainProc.Proc.Id

    Invoke-Case 'TC-005-entry-and-wiring-discoverable' {
        Assert-True ($null -ne $entryMarker) 'TC-005-entry-marker' ('根页应含项目选择入口（匹配词：' + $entryMarker + '）')
        Assert-True ($null -ne $Script:Contract) 'TC-005-switch-wiring' ('应发现可驱动的切换接线：' + (ConvertTo-Json -InputObject $Script:Contract -Compress))
    }
    Invoke-Case 'TC-010-switch-A-to-B-closed-loop' {
        $r = Switch-AndObserve $fx.B
        Assert-True (Test-RootIs $r.State $fx.B) 'TC-010-root-flipped-B' ('切换后页脚应=B；实际：' + $r.State.Footer)
        Assert-True (($null -ne $r.State.Topbar) -and ($r.State.Topbar -ieq (Get-Shortened $fx.B))) 'TC-010-topbar-B' ('顶栏应为 shortenPath(B,46)；实际：' + $r.State.Topbar)
        $tips = (Get-Route '/api/tips').content | ConvertFrom-Json
        Assert-True ([int]$tips.data.count -eq 3 -and $tips.available -eq $true) 'TC-010-tips-B-truth' ('B 态 tips count 应=3；实际=' + $tips.data.count)
        $tipsPage = (Get-Route '/tips').content
        Assert-True ($tipsPage -like ('*' + $tokB1 + '*') -and $tipsPage -notlike ('*' + $tokA1 + '*')) 'TC-010-tips-page-swap' ('/tips 应含 ' + $tokB1 + ' 且不含 ' + $tokA1)
        $reqPage = (Get-Route '/requirements').content
        Assert-True ($reqPage -like ('*' + $tokReqB1 + '*') -and $reqPage -notlike ('*' + $tokReqA + '*')) 'TC-010-req-page-swap' ('/requirements 应含 ' + $tokReqB1 + ' 且不含 ' + $tokReqA)
        $reqJson = (Get-Route '/api/requirements').content | ConvertFrom-Json
        Assert-True ([int]$reqJson.data.totalCount -eq 2) 'TC-010-req-count-B' ('B 态归档总数应=2；实际=' + $reqJson.data.totalCount)
        $exp = (Get-Route '/api/exploration').content
        Assert-True ($exp -like ('*' + $tokExploB + '*')) 'TC-010-explo-B-truth' ('B 态探索缓存应含 ' + $tokExploB)
        Assert-True ((Get-Process -Id $pidBefore -ErrorAction SilentlyContinue) -ne $null) 'TC-010-pid-unchanged' ('服务进程 ' + $pidBefore + ' 应仍存活（不重启）')
    }
    Invoke-Case 'TC-080-immediate-effect' {
        # 每次切换响应后的第一次 GET 必须已是新根（即时生效，非延迟/二次刷新生效）
        $bad = @($Script:ImmediateFlags | Where-Object { -not $_.ok })
        Assert-True ($bad.Count -eq 0) 'TC-080-immediate-effect' ('存在切换后首次 GET 未即时反映新根的记录：' + ($bad | ForEach-Object { $_.path }) -join ';')
    }
    Invoke-Case 'TC-015-reject-no-rdd-dir' {
        $r = Switch-AndObserve $fx.C1
        $signal = Get-RejectSignal @($r.Resp.content, $r.State.Home.content, (Get-Route '/api/overview').content)
        Assert-True ($null -ne $signal -and $signal -match '\.rdd') 'TC-015-reason-mentions-rdd' ('拒绝原因应具体到 .rdd 缺失；信号：' + $signal)
        Assert-True (Test-RootIs (Get-RootState) $fx.B) 'TC-015-root-stays-B' ('拒绝后数据根应保持原值 B；实际：' + (Get-RootState).Footer)
        $Script:ReasonC1 = $signal
    }
    Invoke-Case 'TC-020-reject-illegal-data-domain' {
        $r = Switch-AndObserve $fx.C2
        $signal = Get-RejectSignal @($r.Resp.content, $r.State.Home.content, (Get-Route '/api/overview').content)
        Assert-True ($null -ne $signal) 'TC-020-reason-present' ('数据域非法也应给出具体原因；信号：' + $signal)
        $distinct = ($null -ne $signal) -and ($null -ne $Script:ReasonC1) -and ($signal -ne $Script:ReasonC1)
        $domainish = ($signal -match '数据域|数据根|标记|changes|tips|exploration|合法')
        Assert-True ($distinct -and $domainish) 'TC-020-reason-distinguishable' ('两类拒绝原因必须可区分：C1=[' + $Script:ReasonC1 + '] C2=[' + $signal + ']')
        Assert-True (Test-RootIs (Get-RootState) $fx.B) 'TC-020-root-stays-B' ('拒绝后数据根应保持原值 B；实际：' + (Get-RootState).Footer)
    }
    Invoke-Case 'TC-025-recover-after-reject' {
        $r = Switch-AndObserve $fx.A
        Assert-True (Test-RootIs $r.State $fx.A) 'TC-025-recover-to-valid' ('两次拒绝后再选合法 A 应切换成功；实际：' + $r.State.Footer)
        $tips = (Get-Route '/api/tips').content
        Assert-True ($tips -like ('*' + $tokA1 + '*')) 'TC-025-tips-A-truth' ('恢复后 tips 应为 A 真值')
    }
    Invoke-Case 'TC-055-fixture-exclusion-on-B' {
        $null = Invoke-Switch $fx.B
        $tips = (Get-Route '/api/tips').content | ConvertFrom-Json
        Assert-True ([int]$tips.data.count -eq 3) 'TC-055-plant-tip-excluded' ('植物 tips（qa- 前缀）不得计入：count 应=3；实际=' + $tips.data.count)
        $tipsPage = (Get-Route '/tips').content
        Assert-True ($tipsPage -notlike ('*' + $tokPlantQ + '*')) 'TC-055-plant-tip-invisible' ('植物 tips 标题不得出现在页面')
        $reqJson = (Get-Route '/api/requirements').content | ConvertFrom-Json
        Assert-True ([int]$reqJson.data.totalCount -eq 2) 'TC-055-plant-archive-excluded' ('植物归档（2097-12-31-qa-）不得计入：totalCount 应=2；实际=' + $reqJson.data.totalCount)
        $footerHome = (Get-Route '/').content
        Assert-True ($footerHome -like '*已排除*测试夹具目录*') 'TC-055-exclusion-declared' ('页脚应声明夹具排除口径（已排除 N 个测试夹具目录）')
    }
    Invoke-Case 'TC-060b-envelope-six-domains-on-B' {
        foreach ($route in @('/api/overview', '/api/requirements', '/api/exploration', '/api/hit-rate', '/api/quality', '/api/tips', '/api/goal-trees')) {
            $r = Get-Route $route
            $ok = $false; $why = 'status=' + $r.status
            if ($r.status -eq 200) {
                try {
                    $j = $r.content | ConvertFrom-Json
                    $ok = ($null -ne $j.domain) -and ($null -ne $j.available) -and ($null -ne $j.meta) -and ($null -ne $j.data) -and ($null -ne $j.meta.source)
                    if (-not $ok) { $why = '信封键不齐' }
                } catch { $why = 'JSON 解析失败' }
            }
            Assert-True $ok ('TC-060b-envelope ' + $route) $why
        }
    }
    Invoke-Case 'TC-065-live-read-after-switch' {
        # 切换后实时读盘语义不变：向当前根（B）新增/删除一条 tips，刷新即见（不重启）
        $liveId = 'psw-live-' + $Script:Stamp
        $liveTitle = 'PswLive-' + $Script:Stamp
        New-TipFile (Join-Path $fx.B '.rdd\tips\entries') $liveId $liveTitle
        $tips1 = (Get-Route '/api/tips').content | ConvertFrom-Json
        Assert-True ([int]$tips1.data.count -eq 4 -and ((Get-Route '/tips').content -like ('*' + $liveTitle + '*'))) 'TC-065-live-add-visible' ('新增后刷新应即见 count=4 与标题；实际 count=' + $tips1.data.count)
        Remove-Item -LiteralPath (Join-Path $fx.B ('.rdd\tips\entries\' + $liveId + '.json')) -Force
        $tips2 = (Get-Route '/api/tips').content | ConvertFrom-Json
        Assert-True ([int]$tips2.data.count -eq 3) 'TC-065-live-remove-reverts' ('删除后刷新应回退 count=3；实际=' + $tips2.data.count)
        Assert-True ((Get-Process -Id $pidBefore -ErrorAction SilentlyContinue) -ne $null) 'TC-065-pid-unchanged' ('全程服务进程不重启')
    }
    Invoke-Case 'TC-030-round-trips' {
        $seq = @($fx.A, $fx.B, $fx.A, $fx.B, $fx.A)
        $allOk = $true; $lastWhy = ''
        foreach ($target in $seq) {
            $r = Switch-AndObserve $target
            if (-not (Test-RootIs $r.State $target)) { $allOk = $false; $lastWhy = ('目标 ' + $target + ' 实际 ' + $r.State.Footer) }
            if ((Get-Process -Id $pidBefore -ErrorAction SilentlyContinue) -eq $null) { $allOk = $false; $lastWhy = '服务进程消失' }
        }
        Assert-True $allOk 'TC-030-round-trips' ('A→B→A→B→A 五连切换全部生效且 PID 不变；' + $lastWhy)
        Assert-True ((Get-Route '/api/tips').content -like ('*' + $tokA1 + '*')) 'TC-030-final-A-truth' ('终态应为 A 真值')
    }
    Invoke-Case 'TC-035-no-mixed-state' {
        # 终态 A：各数据面新根 token 出现 ∧ 旧根 token 缺失（按域取 token 族），
        # 连续两次 GET 归一化后一致（无闪烁/混合；口径=掩蔽每请求时间戳类易变字段，
        # n10 修正——原始比较把毫秒级 data-at/generatedAt 噪声当成不稳态假红）。
        $mixed = @()
        $faces = @(
            @{ route = '/';             present = $tokReqA; absent = $tokReqB1 },
            @{ route = '/tips';         present = $tokA1;   absent = $tokB1 },
            @{ route = '/requirements'; present = $tokReqA; absent = $tokReqB1 },
            @{ route = '/api/tips';     present = $tokA1;   absent = $tokB1 }
        )
        foreach ($face in $faces) {
            $c1 = (Get-Route $face.route).content; $c2 = (Get-Route $face.route).content
            if (-not ($c1 -like ('*' + $face.present + '*'))) { $mixed += ($face.route + ':缺新根token') }
            if ($c1 -like ('*' + $face.absent + '*')) { $mixed += ($face.route + ':残留旧根token') }
            if ((Normalize-Volatile $c1) -ne (Normalize-Volatile $c2)) { $mixed += ($face.route + ':两次读取不一致(归一化后)') }
        }
        Assert-True ($mixed.Count -eq 0) 'TC-035-no-mixed-state' ('混合态/不稳态：' + ($mixed -join ';'))
    }
    Invoke-Case 'TC-085-path-tolerance' {
        $r = Switch-AndObserve ($fx.B + '\')
        Assert-True (Test-RootIs $r.State $fx.B) 'TC-085-trailing-slash-ok' ('尾随反斜杠路径应规范化后成功；实际：' + $r.State.Footer)
        $nope = Join-Path $Script:Work ('nope-' + $Script:Stamp)
        $r2 = Switch-AndObserve $nope
        Assert-True (-not (Test-RootIs $r2.State $nope)) 'TC-085-nonexistent-rejected' ('不存在的路径不得切换成功')
        Assert-True ((Get-Route '/').status -eq 200) 'TC-085-service-alive' ('拒绝后服务应仍 200')
        $null = Invoke-Switch $fx.A
    }
    Invoke-Case 'TC-090-inflight-requests-survive' {
        # 切换瞬间在途请求：全部得到干净响应、服务存活（不断言在途归属——设计裁定项）
        Add-Type -AssemblyName System.Net.Http
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $tasks = @()
        foreach ($p in @('/', '/requirements', '/exploration', '/tips', '/api/overview')) {
            $tasks += $client.GetAsync(('http://127.0.0.1:' + $Script:BasePort) + $p)
        }
        $null = Invoke-Switch $fx.B   # 在途期间切换
        [System.Threading.Tasks.Task]::WaitAll($tasks)
        $bad = @()
        foreach ($t in $tasks) { if (-not $t.Result.IsSuccessStatusCode) { $bad += $t.Result.StatusCode } }
        Assert-True ($bad.Count -eq 0) 'TC-090-inflight-all-responded' ('在途请求应全部 2xx；异常：' + ($bad -join ','))
        Assert-True ((Get-Route '/').status -eq 200) 'TC-090-service-alive' ('切换冲击后服务应仍 200')
        Assert-True ((Get-Process -Id $pidBefore -ErrorAction SilentlyContinue) -ne $null) 'TC-090-pid-unchanged' ('服务进程不变')
        $client.Dispose()
    }
    Invoke-Case 'TC-040-dialog-degradation' {
        # 无桌面会话（本沙箱恒成立）：弹窗路径必须不卡死服务、有清晰降级提示、手动兜底可用
        $appJs = (Get-Route '/static/app.js').content
        $pick = Find-PickEndpoint $appJs $candidates
        $hintSeen = $false
        if ($null -ne $pick) {
            $resp = Invoke-Candidate @{ kind = 'json'; path = $pick.path; method = 'POST'; key = 'path' } $fx.A 30
            $hintSeen = (($resp.content + (Get-Route '/').content) -match '弹窗|对话框|失败|超时|桌面|会话|手动|降级')
        }
        Assert-True ((Get-Route '/').status -eq 200) 'TC-040-service-alive' ('弹窗触发（或其失败路径）后服务应仍 200 响应')
        Assert-True ($null -ne $Script:Contract) 'TC-040-manual-fallback-exists' ('手动粘贴路径兜底通道应可用（发现的切换通道即兜底通道）')
        if ($null -ne $pick) {
            Assert-True $hintSeen 'TC-040-degradation-hint' ('弹窗失败/超时/无桌面会话应有清晰提示信号（响应或页面）')
        } else {
            Assert-Skip 'TC-040-degradation-hint' '未发现独立弹窗端点（弹窗或内联于切换通道）——降级提示由人工协议补充核验'
        }
    }
    Invoke-Case 'TC-045-manual-channel-equivalence' {
        # 兜底与弹窗共用同一校验与切换路径：直接以任意路径驱动通道即等价证据
        $r = Switch-AndObserve $fx.B
        Assert-True (Test-RootIs $r.State $fx.B) 'TC-045-manual-channel-works' ('手动通道提交合法路径应走通同一切换路径')
        $entryHome = (Get-Route '/').content
        Assert-True ($null -ne (Find-EntryMarker $entryHome)) 'TC-045-entry-on-new-root' ('切换后页面应仍有项目选择入口（可再次切换）')
    }
    Invoke-Case 'TC-075b-ux-shell-on-B' {
        $h = (Get-Route '/').content
        Assert-True ($h -like '<!DOCTYPE html*' -and $h -like '*</html>*' -and $h -like '*<html lang="zh-CN">*' -and $h -like '*href="/static/style.css"*' -and $h -like '*--ops-bg-app*' -and $h -like '*skip-link*' -and $h -like '*src="/static/app.js"*' -and ($h -match 'aria-(current|pressed|live)')) 'TC-075b-ux-shell-B' '切换后页面 UX Token/组件体系（含 a11y）应与切换前同构'
    }
}

# ── TC-070：启动期三级解析语义不变（增量能力不得改变启动行为） ──────────
if ($nodeOk) {
    Invoke-Case 'TC-070-startup-semantics-unchanged' {
        $inst = Start-Board $fx.C1 ($Script:BasePort + 2) 'c1'
        $exited = $false
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            if ($inst.Proc.HasExited) { $exited = $true; break }
            Start-Sleep -Milliseconds 300
        }
        $errText = Read-SharedText $inst.Err
        Assert-True $exited 'TC-070-c1-exits' ('RDD_PROJECT_ROOT 指向无 .rdd 目录时启动应失败退出（现行语义）')
        Assert-True ($errText -match '\.rdd') 'TC-070-c1-actionable-message' ('失败提示应含 .rdd 语义可处置信息；stderr：' + $errText)
        if (-not $exited) { Stop-ServiceInstance $inst.Proc ($Script:BasePort + 2) }
        $inst2 = Start-Board $fx.B ($Script:BasePort + 3) 'b2'
        $ann = Wait-Announce $inst2.Out
        Assert-True ($ann -like ('*数据根*' + $fx.B + '*')) 'TC-070-b-starts-with-env' ('RDD_PROJECT_ROOT 指向合法 B 时应正常启动且数据根=B')
        Stop-ServiceInstance $inst2.Proc ($Script:BasePort + 3)
    }
}

# ── TC-050：只读不变量（全程零回写） ──────────────────────────────────
Invoke-Case 'TC-050-readonly-zero-writeback' {
    Compare-TreeSnapshot $fx.A $snapshots['A'] 'TC-050-readonly-A'
    Compare-TreeSnapshot $fx.B $snapshots['B'] 'TC-050-readonly-B'
    Compare-TreeSnapshot $fx.C1 $snapshots['C1'] 'TC-050-readonly-C1'
    Compare-TreeSnapshot $fx.C2 $snapshots['C2'] 'TC-050-readonly-C2'
}

# ── 收尾与汇总 ────────────────────────────────────────────────────────
if ($null -ne $Script:MainProc) { Stop-ServiceInstance $Script:MainProc.Proc $Script:BasePort }
if ($switchCapable) {
    $contractFile = Join-Path $Script:Work 'contract.json'
    Write-Utf8NoBom $contractFile (ConvertTo-Json -InputObject $Script:Contract -Depth 4)
}
$total = $Script:Results.Count
$failed = @($Script:Results | Where-Object { -not $_.ok }).Count
$skipped = @($Script:Results | Where-Object { $_.skipped }).Count
Write-Output ('total: {0} failed: {1} skipped: {2}' -f $total, $failed, $skipped)
Write-Output ('work: ' + $Script:Work)
if (-not $KeepWork -and $failed -eq 0) {
    try { Remove-Item -LiteralPath $Script:Work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
if ($failed -gt 0) { exit 1 } else { exit 0 }

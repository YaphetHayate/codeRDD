# decision-ledger tests — 归档级统一决策账本（planner-midrun-derive 决策 #3）
# Covers the archive-level decisions.jsonl contract:
#   D1  decide -Kind checkpoint 链式 -Archive 形态：归档根 decisions.jsonl +
#       四要素（background/options/decision/reason）+ decider=user + checkpoint/
#       role 字段
#   D2  checkpoint 门：ARCHIVE_REQUIRED / CHECKPOINT_REQUIRED /
#       DECISION_REQUIRED / ARCHIVE_NOT_FOUND
#   D3  -Options 'A|B' 竖线拆分
#   D4  append-only 单调递增 D<n>（多次追加 entry_id 严格递增，行数一致）
#   D5  旧 kind / 缺字段 / 坏行容忍：legacy 行（缺 background/options/reason）与
#       不可解析行不阻断后续追加（读侧降级到可解析前缀，账本永不丢）
#   D6  -RunId 可选透传（checkpoint 归档级条目允许携带 run 上下文）
#   D7  BOM 自检：engine 两脚本 + 两个新测试文件首三字节 239,187,191
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$Work      = Join-Path $env:TEMP ('decision-ledger-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}
function Invoke-Bridge { param([string[]]$A) Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-LedgerLines { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/decisions.jsonl')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllLines($p) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
$env:DSH_WEB_URL = 'http://127.0.0.1:1'
Push-Location $Work
try {
    # fixture archive（无需 run——checkpoint 是归档级条目）
    $archDir = Join-Path $Work '.rdd/changes/archive/dl-main'
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# dl-main`n`ndecision ledger 测试归档。`n"
    $tf = Join-Path $Work 'dl-init.json'
    Write-Utf8NoBom $tf '[{"title":"L1","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/dl-main', '-TasksFile', 'dl-init.json')
    Assert-True ($r.json.success -eq $true) 'D0 archive init ok' ($r.raw)
    $arch = '.rdd/changes/archive/dl-main'

    # ================= D2: checkpoint 门（先测门，账本保持零行） =================
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Checkpoint', '架构选型', '-Decision', '取 A')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ARCHIVE_REQUIRED') 'D2 checkpoint without -Archive -> ARCHIVE_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-Decision', '取 A')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'CHECKPOINT_REQUIRED') 'D2 no -Checkpoint -> CHECKPOINT_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-Checkpoint', '架构选型')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'DECISION_REQUIRED') 'D2 no -Decision -> DECISION_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', '.rdd/changes/archive/nope', '-Checkpoint', 'X', '-Decision', 'Y')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ARCHIVE_NOT_FOUND') 'D2 bogus -Archive -> ARCHIVE_NOT_FOUND' ($r.raw)
    Assert-True (@(Read-LedgerLines $arch).Count -eq 0) 'D2 gate failures leave the ledger untouched (zero lines)'

    # ================= D1: 链式 -Archive 形态 + 四要素 =================
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-Checkpoint', '架构选型', '-Decision', '取 A 方案（读多写少场景）', '-Reason', 'A 的读路径延迟低 40%，写路径满足预算内吞吐', '-Options', 'A:列存读优化 | B:行存写优化', '-Background', '两条备选路线均已过 CTO 评审', '-Role', 'CTO')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.kind -eq 'checkpoint') 'D1 checkpoint decide ok (chained -Archive form)' ($r.raw)
    $lines = @(Read-LedgerLines $arch)
    Assert-True ($lines.Count -eq 1 -and (Test-Path (Join-Path $Work ($arch + '/decisions.jsonl')))) 'D1 ledger at the ARCHIVE root (archive-level, not run dir)'
    $e = $lines[0] | ConvertFrom-Json
    Assert-True ([string]$e.entry_id -eq 'D1' -and [string]$e.kind -eq 'checkpoint' -and [string]$e.decider -eq 'user') 'D1 D1 kind=checkpoint decider=user'
    Assert-True ([string]$e.decision -match '取 A' -and [string]$e.reason -match '读路径' -and [string]$e.background -match 'CTO 评审') 'D1 four elements recorded (decision/reason/background)'
    Assert-True (@($e.options).Count -eq 2 -and [string]$e.options[0] -match '^A:') 'D1 options recorded'
    Assert-True ([string]$e.checkpoint -eq '架构选型' -and [string]$e.role -eq 'CTO') 'D1 checkpoint + role context fields'
    Assert-True ($null -eq $e.run_id) 'D1 archive-scoped entry carries no run binding by default'

    # ================= D3: -Options 竖线拆分（含空白容错） =================
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-Checkpoint', '交互稿定稿', '-Decision', '采用第二稿', '-Options', ' 第一稿 | 第二稿 | 第三稿 ')
    Assert-True ($r.json.success -eq $true) 'D3 second checkpoint ok' ($r.raw)
    $e2 = @(Read-LedgerLines $arch)[1] | ConvertFrom-Json
    Assert-True ([string]$e2.entry_id -eq 'D2' -and @($e2.options).Count -eq 3 -and [string]$e2.options[0] -eq '第一稿') 'D3 options split on | with whitespace trimmed' ((@($e2.options)) -join ';')

    # ================= D4: append-only 单调递增 =================
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-Checkpoint', '上线窗口', '-Decision', '周五低峰')
    Assert-True ($r.json.success -eq $true) 'D4 third checkpoint ok' ($r.raw)
    $lines = @(Read-LedgerLines $arch)
    $ids = @($lines | ForEach-Object { [string](([string]$_ | ConvertFrom-Json).entry_id) })
    Assert-True ($lines.Count -eq 3 -and $ids[0] -eq 'D1' -and $ids[1] -eq 'D2' -and $ids[2] -eq 'D3') 'D4 append-only, strictly monotonic D<n>' ($ids -join ',')

    # ================= D5: legacy 行 / 坏行容忍 =================
    $lp = Join-Path $Work ($arch + '/decisions.jsonl')
    $nl = [string][char]10
    # legacy 形态：旧 kinds（auto）缺 background/options/reason/decider 四要素
    [System.IO.File]::AppendAllText($lp, ('{"entry_id":"D4","at":"2026-10-06T00:00:00Z","kind":"auto","task_id":1,"stage":"CTO","risk":"low","decision":"auto-answer"}' + $nl), (New-Object System.Text.UTF8Encoding($false)))
    # 坏行：截断 JSON（保留行尾换行——坏行永不阻断后续追加）
    [System.IO.File]::AppendAllText($lp, ('{"entry_id":"D5","kind":"chopped' + $nl), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-Checkpoint', '回补检查点', '-Decision', '继续', '-Reason', 'legacy 兼容后追加')
    Assert-True ($r.json.success -eq $true) 'D5 append succeeds past legacy + corrupt lines' ($r.raw)
    $lines = @(Read-LedgerLines $arch)
    $last = $lines[-1] | ConvertFrom-Json
    $idsDetail = @($lines | ForEach-Object { $x = '<corrupt>'; try { $x = [string](([string]$_ | ConvertFrom-Json).entry_id) } catch { }; $x }) -join ','
    Assert-True ([string]$last.entry_id -eq 'D5' -and [string]$last.kind -eq 'checkpoint') 'D5 numbering counts only parseable entries (legacy D4 counted, corrupt line skipped)' $idsDetail

    # ================= D6: -RunId 可选透传 =================
    $r = Invoke-Bridge @('-Command', 'decide', '-Kind', 'checkpoint', '-Archive', $arch, '-RunId', 'deliver-dl-main', '-Checkpoint', '带 run 上下文', '-Decision', 'OK')
    Assert-True ($r.json.success -eq $true) 'D6 checkpoint with -RunId ok' ($r.raw)
    $last = @(Read-LedgerLines $arch)[-1] | ConvertFrom-Json
    Assert-True ([string]$last.entry_id -eq 'D6' -and [string]$last.run_id -eq 'deliver-dl-main') 'D6 run context passthrough recorded'

    # ================= D7: BOM 自检（tips 义务） =================
    $selfAndSiblings = @($BridgePs1, $FlowPs1, (Join-Path $PSScriptRoot 'test-decision-ledger.ps1'), (Join-Path $PSScriptRoot 'test-bridge-derive.ps1'))
    foreach ($f in $selfAndSiblings) {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $n = Split-Path $f -Leaf
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "D7 $n first-3-bytes = 239,187,191 (BOM intact)" ("got {0},{1},{2}" -f $bytes[0], $bytes[1], $bytes[2])
    }
}
finally {
    Pop-Location
    $env:DSH_WEB_URL = $null
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ("--- {0} passed / {1} failed / {2} total ---" -f @($Results | Where-Object { $_.ok }).Count, $failed.Count, $Results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

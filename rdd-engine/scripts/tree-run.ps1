# tree-run.ps1 — tree-run management plane CLI (Manager sessions only)
#
# Drives the lifecycle of a tree-shaped long-running task run:
#   start / graft / prune / settle / conclude / round-start / round-end / status / resume
#
# Layout (per design/tree-run-engine-cto.md):
#   .rdd/tree-runs/<run-id>/
#   ├── manifest.json          budget / outcome / ref roots
#   ├── state/
#   │   ├── tree.json          authoritative snapshot (pre-write .bak + read-back)
#   │   ├── ledger.jsonl       append-only callback ledger (bad lines -> .corrupt)
#   │   └── round-log.jsonl    round log (start/end two-line scheme, append-only)
#   ├── .lock                  one exclusive lock per run (all write primitives)
#   └── report/
#       ├── rounds/round-NN.md per-round human-readable snapshot
#       └── final-report.md    conclusion artifact (all three outcomes)
#
# Structure-change rights (graft/prune/settle/conclude) live ONLY here.
# Worker sessions use tree-leaf.ps1 (consumption plane: next/claim/report).
# Fully orthogonal to task.json routing and the explore chain — zero shared data.

[CmdletBinding()]
param(
    [ValidateSet("start", "graft", "prune", "settle", "conclude", "round-start", "round-end", "status", "resume")]
    [string]$Command = "status",

    [string]$RunId,

    # start
    [string]$Goal,
    [string]$Title,
    [ValidateRange(1, 1000)]
    [int]$MaxRounds = 5,
    [ValidateRange(1, 100)]
    [int]$NodeWidth = 4,
    [ValidateRange(1, 10000)]
    [int]$MaxNodes = 30,
    [string]$RefRoots,
    [string]$CreatedBy,
    [string]$Notes,

    # graft / prune / settle
    [string]$Parent,
    [string]$NodeId,
    [string]$Tasks,
    [string]$TasksFile,
    [string]$Reason,
    [string]$Note,

    # conclude / round-end
    [ValidateSet("achieved", "budget_exhausted", "space_exhausted")]
    [string]$Outcome,
    [string]$Summary,
    [string]$AnchorNodeId,
    [string]$Decision
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$repoRoot = (git rev-parse --show-toplevel).Trim()

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TreeRunsRoot = Join-Path $repoRoot ".rdd/tree-runs"
$script:LockStream = $null
$script:LockPath = $null

# === Generic helpers ===

function ConvertTo-PortableJson {
    param($Object, [int]$Depth = 6)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-ErrorResult {
    param(
        [string]$Code,
        [string]$Message,
        [int]$ExitCode = 1
    )
    ConvertTo-PortableJson @{
        success = $false
        error   = @{ code = $Code; message = $Message }
    } -Depth 3
    exit $ExitCode
}

function Get-UtcNowIso {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Convert-PSObjectToHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) {
            $h[$p.Name] = Convert-PSObjectToHashtable $p.Value
        }
        return $h
    }
    if ($Value -is [array]) {
        $arr = @()
        foreach ($v in $Value) { $arr += ,(Convert-PSObjectToHashtable $v) }
        return $arr
    }
    return $Value
}

function Convert-ToSafeArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

# === Run directory layout ===

function Get-RunDir       { param([string]$Id); Join-Path $script:TreeRunsRoot $Id }
function Get-ManifestPath { param([string]$RunDir); Join-Path $RunDir "manifest.json" }
function Get-StateDir     { param([string]$RunDir); Join-Path $RunDir "state" }
function Get-TreePath     { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "tree.json" }
function Get-LedgerPath   { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "ledger.jsonl" }
function Get-CorruptPath  { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "ledger.jsonl.corrupt" }
function Get-RoundLogPath { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "round-log.jsonl" }
function Get-LockPath     { param([string]$RunDir); Join-Path $RunDir ".lock" }
function Get-ReportDir    { param([string]$RunDir); Join-Path $RunDir "report" }
function Get-RoundsDir    { param([string]$RunDir); Join-Path (Get-ReportDir $RunDir) "rounds" }
function Get-FinalPath    { param([string]$RunDir); Join-Path (Get-ReportDir $RunDir) "final-report.md" }

function Resolve-RunDir {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        Write-ErrorResult "MISSING_RUN_ID" "-RunId is required" 1
    }
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-ErrorResult "INVALID_RUN_ID" "RunId must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ : $Id" 1
    }
    $dir = Get-RunDir $Id
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-ErrorResult "RUN_NOT_FOUND" "Tree run not found: .rdd/tree-runs/$Id" 2
    }
    return $dir
}

# === Per-run exclusive lock (all write primitives) ===
# CreateNew+FileShare::None gives an OS-level mutex. Holders that crash leave a
# stale file; anything older than STALE_SEC is taken over. Waiting writers retry
# until LOCK_TIMEOUT_SEC then fail loud (caller backs off and retries).

function Enter-RunLock {
    param([string]$RunDir, [int]$TimeoutSec = 10, [int]$StaleSec = 60)

    $script:LockPath = Get-LockPath $RunDir
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stolen = $false

    while ($true) {
        try {
            $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "cmd=$Command pid=$PID at=$(Get-Date -Format s)"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            $script:LockStream = $fs
            return @{ path = $script:LockPath; stale_taken_over = $stolen }
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if (Test-Path -LiteralPath $script:LockPath -PathType Leaf) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $script:LockPath).LastWriteTime).TotalSeconds
                if ($age -gt $StaleSec) {
                    # stale holder (crashed process) — take over
                    try { Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue } catch {}
                    $stolen = $true
                    continue
                }
            }
            else {
                continue
            }
            if ((Get-Date) -gt $deadline) {
                Write-ErrorResult "LOCK_TIMEOUT" "Run lock held by another writer for > ${TimeoutSec}s: $script:LockPath. Back off and retry." 3
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Exit-RunLock {
    if ($null -ne $script:LockStream) {
        try { $script:LockStream.Close() } catch {}
        $script:LockStream = $null
    }
    if ($script:LockPath -and (Test-Path -LiteralPath $script:LockPath -PathType Leaf)) {
        # best-effort release: only delete if no one else re-created it after our close
        try {
            $raw = [System.IO.File]::ReadAllText($script:LockPath, [System.Text.Encoding]::UTF8)
            if ($raw -match "pid=$PID ") { Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

# === manifest.json ===

function Read-ManifestEditable {
    param([string]$RunDir)
    $p = Get-ManifestPath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-ErrorResult "MANIFEST_NOT_FOUND" "manifest.json not found in run: $RunDir" 2
    }
    try {
        $m = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "MANIFEST_CORRUPT" "manifest.json failed to parse: $($_.Exception.Message)" 3
    }
    $concluded = $null
    if ($m.concluded) {
        $concluded = [ordered]@{
            outcome      = [string]$m.concluded.outcome
            concluded_at = [string]$m.concluded.concluded_at
            anchor_node  = if ($null -ne $m.concluded.anchor_node) { [string]$m.concluded.anchor_node } else { $null }
            summary      = [string]$m.concluded.summary
        }
    }
    return [ordered]@{
        format_version = [int]$m.format_version
        run_id         = [string]$m.run_id
        goal           = [string]$m.goal
        created_at     = [string]$m.created_at
        created_by     = if ($m.created_by) { [string]$m.created_by } else { "unknown" }
        budget         = @{
            max_rounds = [int]$m.budget.max_rounds
            node_width = [int]$m.budget.node_width
            max_nodes  = [int]$m.budget.max_nodes
        }
        ref_roots      = @(Convert-ToSafeArray $m.ref_roots)
        state          = [string]$m.state
        concluded      = $concluded
        notes          = if ($m.notes) { [string]$m.notes } else { "" }
    }
}

function Write-ManifestFile {
    param([string]$RunDir, $Manifest)
    $p = Get-ManifestPath $RunDir
    $json = ConvertTo-Json $Manifest -Depth 8
    [System.IO.File]::WriteAllText($p, $json, $script:Utf8NoBom)
    try {
        $null = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "MANIFEST_WRITE_READBACK_FAILED" "manifest.json read-back failed after write: $($_.Exception.Message)" 3
    }
}

# === state/tree.json ===

function Convert-NodeToHashtable {
    param($Node)
    return [ordered]@{
        id             = [string]$Node.id
        parent         = if ($Node.parent) { [string]$Node.parent } else { $null }
        title          = [string]$Node.title
        task           = [string]$Node.task
        status         = [string]$Node.status
        created_round  = if ($null -ne $Node.created_round) { [int]$Node.created_round } else { 0 }
        claimed_by     = if ($Node.claimed_by) { [string]$Node.claimed_by } else { $null }
        claimed_at     = if ($Node.claimed_at) { [string]$Node.claimed_at } else { $null }
        steal_count    = if ($null -ne $Node.steal_count) { [int]$Node.steal_count } else { 0 }
        reported_at    = if ($Node.reported_at) { [string]$Node.reported_at } else { $null }
        settled_at     = if ($Node.settled_at) { [string]$Node.settled_at } else { $null }
        settled_note   = if ($Node.settled_note) { [string]$Node.settled_note } else { $null }
        pruned_at      = if ($Node.pruned_at) { [string]$Node.pruned_at } else { $null }
        pruned_reason  = if ($Node.pruned_reason) { [string]$Node.pruned_reason } else { $null }
        last_verdict   = if ($Node.last_verdict) { [string]$Node.last_verdict } else { $null }
        last_confidence = if ($null -ne $Node.last_confidence) { [double]$Node.last_confidence } else { $null }
        ledger_refs    = @(Convert-ToSafeArray $Node.ledger_refs)
        note           = if ($Node.note) { [string]$Node.note } else { $null }
        children       = @(Convert-ToSafeArray $Node.children)
    }
}

function Read-TreeEditable {
    param([string]$RunDir)
    $p = Get-TreePath $RunDir
    $bak = "$p.bak"
    $usedBak = $false
    $obj = $null

    foreach ($candidate in @($p, $bak)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $obj = [System.IO.File]::ReadAllText($candidate, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($candidate -eq $bak) { $usedBak = $true }
            break
        }
        catch { continue }
    }
    if ($null -eq $obj) {
        Write-ErrorResult "TREE_CORRUPT" "tree.json (and .bak) failed to parse under $RunDir" 3
    }

    $nodes = @()
    foreach ($n in @(Convert-ToSafeArray $obj.nodes)) { $nodes += ,(Convert-NodeToHashtable $n) }
    return @{
        used_backup = $usedBak
        tree        = [ordered]@{
            format_version = [int]$obj.format_version
            run_id         = [string]$obj.run_id
            goal           = [string]$obj.goal
            updated_at     = [string]$obj.updated_at
            nodes          = $nodes
        }
    }
}

function Write-TreeFile {
    param([string]$RunDir, $Tree)
    $p = Get-TreePath $RunDir
    $Tree.updated_at = Get-UtcNowIso
    $json = ConvertTo-Json $Tree -Depth 10
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        Copy-Item -LiteralPath $p -Destination "$p.bak" -Force
    }
    [System.IO.File]::WriteAllText($p, $json, $script:Utf8NoBom)
    try {
        $null = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        if (Test-Path -LiteralPath "$p.bak" -PathType Leaf) {
            Copy-Item -LiteralPath "$p.bak" -Destination $p -Force
        }
        Write-ErrorResult "TREE_WRITE_READBACK_FAILED" "tree.json read-back failed after write; previous snapshot restored from .bak" 3
    }
}

# === state/ledger.jsonl (append-only; consumption plane writes, both planes read) ===

function Read-Ledger {
    param([string]$RunDir)
    $p = Get-LedgerPath $RunDir
    $entries = @()
    $badLines = @()
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ entries = $entries; bad_lines = $badLines } }
    $lines = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })
    foreach ($line in $lines) {
        try {
            $e = $line | ConvertFrom-Json
            if (-not $e.entry_id) { throw "missing entry_id" }
            $entries += ,(Convert-PSObjectToHashtable $e)
        }
        catch {
            $badLines += $line
        }
    }
    return @{ entries = $entries; bad_lines = $badLines }
}

function Invoke-LedgerQuarantine {
    # rewrite ledger.jsonl without bad lines; move them to ledger.jsonl.corrupt
    # (wrapped, original raw text preserved — never silently dropped). Lock must be held.
    param([string]$RunDir, [array]$Entries, [array]$BadLines)

    $p = Get-LedgerPath $RunDir
    $corrupt = Get-CorruptPath $RunDir
    $goodJson = @()
    foreach ($e in $Entries) { $goodJson += (ConvertTo-Json $e -Depth 10 -Compress) }

    foreach ($bad in $BadLines) {
        $wrap = ConvertTo-Json @{ quarantined_at = (Get-UtcNowIso); run_id = (Split-Path $RunDir -Leaf); raw = $bad } -Depth 6 -Compress
        [System.IO.File]::AppendAllText($corrupt, $wrap + "`n", $script:Utf8NoBom)
    }
    $tmp = "$p.tmp"
    [System.IO.File]::WriteAllText($tmp, ($(if ($goodJson.Count -gt 0) { $goodJson -join "`n" } else { "" }) + "`n"), $script:Utf8NoBom)
    Copy-Item -LiteralPath $tmp -Destination $p -Force
    Remove-Item -LiteralPath $tmp -Force
}

function Get-LedgerStats {
    param([array]$Entries)
    $stats = @{ total = $Entries.Count; valid = 0; downgraded = 0; invalid = 0; range_failures = 0 }
    foreach ($e in $Entries) {
        $st = [string]$e.validation.status
        if ($st -eq "valid") { $stats.valid++ }
        elseif ($st -eq "downgraded") { $stats.downgraded++ }
        else { $stats.invalid++ }
        if ($e.validation.range_check_failures) { $stats.range_failures += @($e.validation.range_check_failures).Count }
    }
    return $stats
}

# === state/round-log.jsonl (start/end two-line scheme) ===

function Read-RoundLog {
    param([string]$RunDir)
    $p = Get-RoundLogPath $RunDir
    $lines = @()
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $lines = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })
    }
    return $lines
}

function Add-RoundLogLine {
    param([string]$RunDir, $LineHashtable)
    $p = Get-RoundLogPath $RunDir
    $json = ConvertTo-Json $LineHashtable -Depth 8 -Compress
    [System.IO.File]::AppendAllText($p, $json + "`n", $script:Utf8NoBom)
    # read-back finish: last non-empty line must parse
    $all = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })
    if ($all.Count -eq 0) { Write-ErrorResult "ROUNDLOG_READBACK_FAILED" "round-log.jsonl empty after append" 3 }
    try { $null = $all[-1] | ConvertFrom-Json }
    catch { Write-ErrorResult "ROUNDLOG_READBACK_FAILED" "round-log.jsonl last line failed to parse after append" 3 }
}

function Get-RoundState {
    param([string]$RunDir)
    $lines = Read-RoundLog $RunDir
    $lastRound = 0
    $openRound = 0
    $openStartedAt = $null
    $closedRounds = @()
    $parseWarnings = @()
    foreach ($line in $lines) {
        try {
            $o = $line | ConvertFrom-Json
            if ($o.event -eq "round-start") {
                $lastRound = [int]$o.round
                $openRound = [int]$o.round
                $openStartedAt = [string]$o.started_at
            }
            elseif ($o.event -eq "round-end") {
                $openRound = 0
                $closedRounds += [int]$o.round
            }
        }
        catch {
            $parseWarnings += "unparseable round-log line: $line"
        }
    }
    return @{
        last_round     = $lastRound
        open_round     = $openRound
        open_started_at = $openStartedAt
        closed_rounds  = $closedRounds
        warnings       = $parseWarnings
    }
}

# === Tree analysis helpers ===

function Find-Node {
    param($Tree, [string]$Id)
    foreach ($n in $Tree.nodes) {
        if ($n.id -eq $Id) { return $n }
    }
    return $null
}

function Get-NextNodeId {
    param($Tree)
    $max = 0
    foreach ($n in $Tree.nodes) {
        if ($n.id -match '^n(\d+)$') {
            $num = [int]$Matches[1]
            if ($num -gt $max) { $max = $num }
        }
    }
    return "n$($max + 1)"
}

function Get-TreeCensus {
    param($Tree)
    $census = @{ pending = @(); claimed = @(); reported = @(); done = @(); pruned = @() }
    foreach ($n in $Tree.nodes) {
        if ($census.ContainsKey($n.status)) { $census[$n.status] += $n.id }
    }
    return $census
}

function Get-NodeDescendants {
    param($Tree, [string]$Id)
    $childrenOf = @{}
    foreach ($n in $Tree.nodes) {
        if ($n.parent) {
            if (-not $childrenOf.ContainsKey($n.parent)) { $childrenOf[$n.parent] = @() }
            $childrenOf[$n.parent] += $n.id
        }
    }
    $result = @()
    $queue = @(Convert-ToSafeArray $childrenOf[$Id])
    while ($queue.Count -gt 0) {
        $cur = $queue[0]
        $queue = @($queue | Select-Object -Skip 1)
        $result += $cur
        $queue += @(Convert-ToSafeArray $childrenOf[$cur])
    }
    return $result
}

function Render-TreeOutline {
    param($Tree)
    $nodeById = @{}
    $childrenOf = @{}
    foreach ($n in $Tree.nodes) {
        $nodeById[$n.id] = $n
        if ($n.parent) {
            if (-not $childrenOf.ContainsKey($n.parent)) { $childrenOf[$n.parent] = @() }
            $childrenOf[$n.parent] += $n.id
        }
    }
    $lines = @()
    foreach ($root in @($Tree.nodes | Where-Object { -not $_.parent })) {
        $stack = @(@{ id = $root.id; depth = 0 })
        while ($stack.Count -gt 0) {
            $cur = $stack[0]
            $stack = @($stack | Select-Object -Skip 1)
            $n = $nodeById[$cur.id]
            $lines += (("  " * $cur.depth) + "- $($n.id) [$($n.status)] $($n.title)")
            $kids = @(Convert-ToSafeArray $childrenOf[$cur.id])
            if ($kids.Count -eq 0) { continue }
            [array]::Reverse($kids)
            foreach ($k in $kids) {
                $stack = @(@{ id = $k; depth = ($cur.depth + 1) }) + $stack
            }
        }
    }
    return ($lines -join "`n")
}

function Get-BudgetUsage {
    param($Manifest, $Tree, $RoundState)
    return @{
        rounds_used  = [int]$RoundState.last_round
        max_rounds   = [int]$Manifest.budget.max_rounds
        nodes_used   = @($Tree.nodes).Count
        max_nodes    = [int]$Manifest.budget.max_nodes
        node_width   = [int]$Manifest.budget.node_width
    }
}

# === Report artifacts ===

function Write-RoundSnapshot {
    param([string]$RunDir, $Manifest, $Tree, $Round, [string]$StartedAt, [string]$EndedAt, [string]$SummaryText, [string]$DecisionText, [bool]$Auto)

    $dir = Get-RoundsDir $RunDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $ledger = Read-Ledger $RunDir
    $roundEntries = @($ledger.entries | Where-Object { [int]$_.round -eq [int]$Round })

    $census = Get-TreeCensus $Tree
    $budget = Get-BudgetUsage $Manifest $Tree @{ last_round = [int]$Round }

    $lines = @()
    $lines += "# Round $("{0:D2}" -f [int]$Round) 快照 — $($Manifest.run_id)"
    $lines += ""
    $lines += "- 窗口: $StartedAt → $EndedAt$(if ($Auto) { ' (由 conclude 自动收轮)' } else { '' })"
    $lines += "- 目标: $($Manifest.goal)"
    $lines += "- 预算: rounds $($budget.rounds_used)/$($budget.max_rounds) · nodes $($budget.nodes_used)/$($budget.max_nodes) · width ≤ $($budget.node_width)"
    $lines += ""
    $lines += "## 本轮回写（$($roundEntries.Count) 条）"
    $lines += ""
    if ($roundEntries.Count -eq 0) {
        $lines += "- （无）"
    }
    else {
        $lines += "| entry | node | worker | verdict | confidence | 校验 |"
        $lines += "|-------|------|--------|---------|------------|------|"
        foreach ($e in $roundEntries) {
            $cb = $e.callback
            $lines += "| $($e.entry_id) | $($e.node_id) | $($e.worker) | $($cb.verdict) | $($cb.confidence) | $($e.validation.status) |"
        }
    }
    $lines += ""
    $lines += "## Manager 整合"
    $lines += ""
    $lines += "- summary: $(if ($SummaryText) { $SummaryText } else { '-' })"
    $lines += "- decision: $(if ($DecisionText) { $DecisionText } else { '-' })"
    $lines += ""
    $lines += "## 树状态"
    $lines += ""
    $lines += "- pending: $($census.pending -join ', ')"
    $lines += "- claimed: $($census.claimed -join ', ')"
    $lines += "- reported(未 settle): $($census.reported -join ', ')"
    $lines += "- done: $($census.done -join ', ')"
    $lines += "- pruned: $($census.pruned -join ', ')"
    $lines += ""
    $lines += "## 树形结构"
    $lines += ""
    $lines += '```'
    $lines += (Render-TreeOutline $Tree)
    $lines += '```'
    $lines += ""

    $path = Join-Path $dir ("round-{0:D2}.md" -f [int]$Round)
    [System.IO.File]::WriteAllText($path, ($lines -join "`n"), $script:Utf8NoBom)
    return $path
}

function Write-FinalReport {
    param([string]$RunDir, $Manifest, $Tree, [string]$Outcome, [string]$SummaryText, $AnchorNode)

    $dir = Get-ReportDir $RunDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $roundLines = Read-RoundLog $RunDir
    $rounds = @()
    foreach ($l in $roundLines) {
        try { $o = $l | ConvertFrom-Json; if ($o.event -eq "round-start") { $rounds += [int]$o.round } } catch {}
    }
    $ledger = Read-Ledger $RunDir
    $stats = Get-LedgerStats $ledger.entries
    $census = Get-TreeCensus $Tree

    $outcomeText = @{
        achieved         = "最终目标达成"
        budget_exhausted = "预算耗尽（诚实报告当前最佳进展）"
        space_exhausted  = "任务空间耗尽（树无可消费/在途节点）"
    }[$Outcome]

    $lines = @()
    $lines += "# Tree-Run 结案报告 — $($Manifest.run_id)"
    $lines += ""
    $lines += "- 终局: **$Outcome**（$outcomeText）"
    $lines += "- 结案时间: $(Get-UtcNowIso) · 创建时间: $($Manifest.created_at) · 发起: $($Manifest.created_by)"
    $lines += "- 目标: $($Manifest.goal)"
    if ($AnchorNode) { $lines += "- 锚点节点: $AnchorNode（status=done）" }
    $lines += ""
    $lines += "## Manager 结案摘要"
    $lines += ""
    $lines += $SummaryText
    $lines += ""
    $lines += "## 预算使用"
    $lines += ""
    $lines += "- rounds: $($rounds.Count)/$($Manifest.budget.max_rounds)（已开轮: $(($rounds | Sort-Object) -join ', ')）"
    $lines += "- nodes: $(@($Tree.nodes).Count)/$($Manifest.budget.max_nodes)（width 上限 $($Manifest.budget.node_width)）"
    $lines += ""
    $lines += "## 节点统计"
    $lines += ""
    $lines += "- done: $($census.done.Count)（$($census.done -join ', ')）"
    $lines += "- reported 未 settle: $($census.reported.Count)（$($census.reported -join ', ')）"
    $lines += "- claimed 在途: $($census.claimed.Count)（$($census.claimed -join ', ')）"
    $lines += "- pending: $($census.pending.Count)（$($census.pending -join ', ')）"
    $lines += "- pruned: $($census.pruned.Count)（$($census.pruned -join ', ')）"
    $lines += ""
    $lines += "## 回写账本统计"
    $lines += ""
    $lines += "- 总回调: $($stats.total)（valid $($stats.valid) / downgraded $($stats.downgraded) / invalid $($stats.invalid)）"
    $lines += "- 引用越界拒采: $($stats.range_failures) 处（详见 ledger 对应 entry 的 range_check_failures）"
    $corruptPath = Get-CorruptPath $RunDir
    if (Test-Path -LiteralPath $corruptPath -PathType Leaf) {
        $lines += "- 坏行隔离: ledger.jsonl.corrupt 存在（读取时已隔离的坏行）"
    }
    $lines += ""
    $lines += "## 最终树形结构"
    $lines += ""
    $lines += '```'
    $lines += (Render-TreeOutline $Tree)
    $lines += '```'
    $lines += ""
    $lines += "## 过程产物"
    $lines += ""
    $lines += "- 每轮快照: report/rounds/round-NN.md"
    $lines += "- 回写账本: state/ledger.jsonl（只追加）"
    $lines += "- 轮日志: state/round-log.jsonl（起止两行制）"
    $lines += "- 引用范围: $($Manifest.ref_roots -join '; ')"
    $lines += ""

    $path = Get-FinalPath $RunDir
    [System.IO.File]::WriteAllText($path, ($lines -join "`n"), $script:Utf8NoBom)
    return $path
}

# === Guards ===

function Assert-Running {
    param($Manifest)
    if ($Manifest.state -eq "concluded") {
        Write-ErrorResult "RUN_CONCLUDED" "Run concluded at $($Manifest.concluded.concluded_at) (outcome=$($Manifest.concluded.outcome)). No further mutations." 1
    }
}

function Assert-OpenRound {
    param($RoundState)
    if ($RoundState.open_round -eq 0) {
        Write-ErrorResult "NO_OPEN_ROUND" "No open round. Run 'round-start' first (tree growth and callbacks happen inside rounds)." 1
    }
}

# === Command: start ===

function Invoke-Start {
    if ([string]::IsNullOrWhiteSpace($RunId)) { Write-ErrorResult "MISSING_RUN_ID" "-RunId is required" 1 }
    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Write-ErrorResult "INVALID_RUN_ID" "RunId must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ : $RunId" 1 }
    if ([string]::IsNullOrWhiteSpace($Goal)) { Write-ErrorResult "MISSING_GOAL" "-Goal is required" 1 }
    if ([string]::IsNullOrWhiteSpace($RefRoots)) { Write-ErrorResult "MISSING_REF_ROOTS" "-RefRoots is required (comma-separated repo-relative paths allowed as citation roots; use '.' to allow the whole repo)" 1 }

    $runDir = Get-RunDir $RunId
    if (Test-Path -LiteralPath $runDir -PathType Container) {
        Write-ErrorResult "RUN_EXISTS" "Tree run already exists: .rdd/tree-runs/$RunId" 1
    }

    # normalize ref roots: forward slashes, trimmed; each must exist (typo guard)
    $roots = @()
    foreach ($r in ($RefRoots -split '[,;]')) {
        $t = ($r.Trim() -replace '\\', '/')
        if ($t -ne '') { $roots += $t }
    }
    if ($roots.Count -eq 0) { Write-ErrorResult "MISSING_REF_ROOTS" "-RefRoots parsed to empty" 1 }
    foreach ($r in $roots) {
        if ($r -eq '.') { continue }
        $abs = Join-Path $repoRoot ($r -replace '/', '\')
        if (-not (Test-Path -LiteralPath $abs)) {
            Write-ErrorResult "REF_ROOT_NOT_FOUND" "RefRoot does not exist under repo root: $r" 1
        }
    }

    $now = Get-UtcNowIso
    $rootTitle = if ([string]::IsNullOrWhiteSpace($Title)) { "root" } else { $Title }

    $manifest = [ordered]@{
        format_version = 1
        run_id         = $RunId
        goal           = $Goal
        created_at     = $now
        created_by     = if ([string]::IsNullOrWhiteSpace($CreatedBy)) { "unknown" } else { $CreatedBy }
        budget         = @{ max_rounds = $MaxRounds; node_width = $NodeWidth; max_nodes = $MaxNodes }
        ref_roots      = $roots
        state          = "running"
        concluded      = $null
        notes          = if ([string]::IsNullOrWhiteSpace($Notes)) { "" } else { $Notes }
    }

    $tree = [ordered]@{
        format_version = 1
        run_id         = $RunId
        goal           = $Goal
        updated_at     = $now
        nodes          = @(
            [ordered]@{
                id              = "n1"
                parent          = $null
                title           = $rootTitle
                task            = $Goal
                status          = "pending"
                created_round   = 0
                claimed_by      = $null
                claimed_at      = $null
                steal_count     = 0
                reported_at     = $null
                settled_at      = $null
                settled_note    = $null
                pruned_at       = $null
                pruned_reason   = $null
                last_verdict    = $null
                last_confidence = $null
                ledger_refs     = @()
                note            = $null
                children        = @()
            }
        )
    }

    # atomic create: manifest.json via CreateNew prevents concurrent double-start
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Get-StateDir $runDir) -Force | Out-Null
    New-Item -ItemType Directory -Path (Get-ReportDir $runDir) -Force | Out-Null
    New-Item -ItemType Directory -Path (Get-RoundsDir $runDir) -Force | Out-Null
    $manifestPath = Get-ManifestPath $runDir
    try {
        $fs = [System.IO.File]::Open($manifestPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-Json $manifest -Depth 8))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Close()
    }
    catch [System.IO.IOException] {
        Write-ErrorResult "RUN_EXISTS" "Tree run already exists (manifest.json race-lost): .rdd/tree-runs/$RunId" 1
    }
    Write-TreeFile $RunDir $tree
    [System.IO.File]::WriteAllText((Get-LedgerPath $runDir), "", $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Get-RoundLogPath $runDir), "", $script:Utf8NoBom)

    return @{
        success = $true
        data    = @{
            started   = $true
            run_id    = $RunId
            directory = ".rdd/tree-runs/$RunId"
            root_node = "n1"
            budget    = $manifest.budget
            ref_roots = $roots
            state     = "running"
            next_step = "tree-run.cmd -Command round-start -RunId $RunId"
        }
    }
}

# === Command: graft ===

function Invoke-Graft {
    param([string]$RunDir)

    if ([string]::IsNullOrWhiteSpace($Parent)) { Write-ErrorResult "MISSING_PARENT" "-Parent (parent node id) is required" 1 }

    $tasksJson = $null
    if (-not [string]::IsNullOrWhiteSpace($TasksFile)) {
        $tf = $TasksFile
        if (-not [System.IO.Path]::IsPathRooted($tf)) { $tf = Join-Path $repoRoot $tf }
        if (-not (Test-Path -LiteralPath $tf -PathType Leaf)) { Write-ErrorResult "TASKS_FILE_NOT_FOUND" "Tasks file not found: $tf" 1 }
        $tasksJson = [System.IO.File]::ReadAllText($tf, [System.Text.Encoding]::UTF8)
    }
    else {
        $tasksJson = $Tasks
    }
    if ([string]::IsNullOrWhiteSpace($tasksJson)) { Write-ErrorResult "MISSING_TASKS" "-Tasks (inline JSON array) or -TasksFile is required" 1 }

    $inputTasks = ConvertFrom-Json $tasksJson
    if ($inputTasks -isnot [array]) { $inputTasks = @($inputTasks) }
    if ($inputTasks.Count -eq 0) { Write-ErrorResult "EMPTY_TASKS" "Graft batch is empty" 1 }
    foreach ($t in $inputTasks) {
        if ([string]::IsNullOrWhiteSpace([string]$t.title)) { Write-ErrorResult "INVALID_TASK" "Every grafted task requires a non-empty title" 1 }
        if ([string]::IsNullOrWhiteSpace([string]$t.task)) { Write-ErrorResult "INVALID_TASK" "Every grafted task requires a non-empty task body (title: $($t.title))" 1 }
    }

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        Assert-Running $manifest
        $roundState = Get-RoundState $RunDir
        Assert-OpenRound $roundState

        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree

        $parentNode = Find-Node $Tree $Parent
        if ($null -eq $parentNode) { Write-ErrorResult "NODE_NOT_FOUND" "Parent node not found: $Parent" 2 }
        if ($parentNode.status -eq "pruned") { Write-ErrorResult "PARENT_PRUNED" "Parent $Parent is pruned; grafting onto a pruned subtree is not allowed" 1 }

        $incoming = @($inputTasks).Count
        if ((@($parentNode.children).Count + $incoming) -gt [int]$manifest.budget.node_width) {
            Write-ErrorResult "WIDTH_EXCEEDED" "Graft would exceed node_width $($manifest.budget.node_width): parent $Parent already has $(@($parentNode.children).Count) children, incoming $incoming" 1
        }
        if ((@($tree.nodes).Count + $incoming) -gt [int]$manifest.budget.max_nodes) {
            Write-ErrorResult "NODES_EXCEEDED" "Graft would exceed max_nodes $($manifest.budget.max_nodes): tree already has $(@($tree.nodes).Count) nodes, incoming $incoming. Consider concluding with budget_exhausted." 1
        }

        $created = @()
        $round = [int]$roundState.open_round
        foreach ($t in $inputTasks) {
            $newId = Get-NextNodeId $tree
            $node = [ordered]@{
                id              = $newId
                parent          = $Parent
                title           = [string]$t.title
                task            = [string]$t.task
                status          = "pending"
                created_round   = $round
                claimed_by      = $null
                claimed_at      = $null
                steal_count     = 0
                reported_at     = $null
                settled_at      = $null
                settled_note    = $null
                pruned_at       = $null
                pruned_reason   = $null
                last_verdict    = $null
                last_confidence = $null
                ledger_refs     = @()
                note            = if ($t.note) { [string]$t.note } else { $null }
                children        = @()
            }
            $tree.nodes += ,$node
            $parentNode.children = @($parentNode.children) + $newId
            $created += $node
        }

        Write-TreeFile $RunDir $tree

        return @{
            success = $true
            data    = @{
                run_id     = $RunId
                grafted    = @($created | ForEach-Object { @{ id = $_.id; title = $_.title; parent = $_.parent; status = $_.status } })
                count      = $created.Count
                round      = $round
                nodes_used = "$(@($tree.nodes).Count)/$($manifest.budget.max_nodes)"
                lock       = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: prune ===

function Invoke-Prune {
    param([string]$RunDir)

    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Reason)) { Write-ErrorResult "MISSING_REASON" "-Reason is required (audit trail)" 1 }

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        Assert-Running $manifest
        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree

        $target = Find-Node $tree $NodeId
        if ($null -eq $target) { Write-ErrorResult "NODE_NOT_FOUND" "Node not found: $NodeId" 2 }
        if ($target.status -eq "pruned") { Write-ErrorResult "ALREADY_PRUNED" "Node $NodeId is already pruned" 1 }

        $now = Get-UtcNowIso
        $prunedIds = @()
        $target.status = "pruned"
        $target.pruned_at = $now
        $target.pruned_reason = $Reason
        $prunedIds += $target.id

        foreach ($descId in (Get-NodeDescendants $tree $NodeId)) {
            $d = Find-Node $tree $descId
            if ($d.status -ne "pruned") {
                $d.status = "pruned"
                $d.pruned_at = $now
                $d.pruned_reason = "cascade from ${NodeId}: $Reason"
                $prunedIds += $d.id
            }
        }

        Write-TreeFile $RunDir $tree

        return @{
            success = $true
            data    = @{ run_id = $RunId; pruned = $prunedIds; cascade_count = ($prunedIds.Count - 1); reason = $Reason; lock = $lockInfo }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: settle ===

function Invoke-Settle {
    param([string]$RunDir)

    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        Assert-Running $manifest
        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree

        $target = Find-Node $tree $NodeId
        if ($null -eq $target) { Write-ErrorResult "NODE_NOT_FOUND" "Node not found: $NodeId" 2 }
        if ($target.status -ne "reported") {
            Write-ErrorResult "SETTLE_REQUIRES_REPORTED" "Node $NodeId is '$($target.status)'; settle only accepts reported nodes (pending → claim → reported → done). Use prune or re-dispatch instead." 1
        }

        $target.status = "done"
        $target.settled_at = Get-UtcNowIso
        $target.settled_note = if ([string]::IsNullOrWhiteSpace($Note)) { $null } else { $Note }

        Write-TreeFile $RunDir $tree

        return @{
            success = $true
            data    = @{ run_id = $RunId; node_id = $NodeId; status = "done"; ledger_refs = @($target.ledger_refs); settled_note = $target.settled_note; lock = $lockInfo }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: round-start / round-end ===

function Invoke-RoundStart {
    param([string]$RunDir)

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        Assert-Running $manifest
        $roundState = Get-RoundState $RunDir
        if ($roundState.open_round -ne 0) {
            Write-ErrorResult "ROUND_ALREADY_OPEN" "Round $($roundState.open_round) is already open (started $($roundState.open_started_at)). Run 'round-end' first." 1
        }
        $next = [int]$roundState.last_round + 1
        if ($next -gt [int]$manifest.budget.max_rounds) {
            Write-ErrorResult "ROUNDS_EXCEEDED" "Next round $next would exceed max_rounds $($manifest.budget.max_rounds). Conclude with budget_exhausted." 1
        }

        $now = Get-UtcNowIso
        Add-RoundLogLine $RunDir @{ event = "round-start"; round = $next; started_at = $now; note = $Note }

        return @{
            success = $true
            data    = @{ run_id = $RunId; round = $next; started_at = $now; rounds_used = "$next/$($manifest.budget.max_rounds)"; lock = $lockInfo }
        }
    }
    finally {
        Exit-RunLock
    }
}

function Invoke-RoundEnd {
    param([string]$RunDir, [bool]$Auto = $false, $AutoStartedAt = $null)

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        Assert-Running $manifest
        $roundState = Get-RoundState $RunDir
        if ($roundState.open_round -eq 0) {
            Write-ErrorResult "NO_OPEN_ROUND" "No open round to end." 1
        }
        $round = [int]$roundState.open_round
        $startedAt = if ($AutoStartedAt) { [string]$AutoStartedAt } else { [string]$roundState.open_started_at }
        $endedAt = Get-UtcNowIso

        # render the snapshot BEFORE appending the round-end line: a render
        # failure leaves the round open (retry-able) instead of ended-without-snapshot
        $readBack = Read-TreeEditable $RunDir
        $snapshotPath = Write-RoundSnapshot $RunDir $manifest $readBack.tree $round $startedAt $endedAt $Summary $Decision $Auto
        Add-RoundLogLine $RunDir @{ event = "round-end"; round = $round; ended_at = $endedAt; summary = $Summary; decision = $Decision; auto = $Auto }

        return @{
            success = $true
            data    = @{
                run_id        = $RunId
                round         = $round
                ended_at      = $endedAt
                auto          = $Auto
                snapshot      = ".rdd/tree-runs/$RunId/report/rounds/$(Split-Path $snapshotPath -Leaf)"
                next_round    = ($round + 1)
                budget_hint   = $(if (($round + 1) -gt [int]$manifest.budget.max_rounds) { "max_rounds reached — conclude (budget_exhausted) when appropriate" } else { "round-start to continue" })
                lock          = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: conclude ===

function Invoke-Conclude {
    param([string]$RunDir)

    if ([string]::IsNullOrWhiteSpace($Summary)) { Write-ErrorResult "MISSING_SUMMARY" "-Summary is required (honest closing summary; for budget_exhausted report real best progress)" 1 }
    if ([string]::IsNullOrWhiteSpace($Outcome)) { Write-ErrorResult "MISSING_OUTCOME" "-Outcome achieved|budget_exhausted|space_exhausted is required" 1 }

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        Assert-Running $manifest
        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree
        $roundState = Get-RoundState $RunDir

        $anchor = $null
        switch ($Outcome) {
            "achieved" {
                if ([string]::IsNullOrWhiteSpace($AnchorNodeId)) {
                    Write-ErrorResult "MISSING_ANCHOR" "-AnchorNodeId is required for outcome=achieved (the done node that proves the goal)" 1
                }
                $anchor = Find-Node $tree $AnchorNodeId
                if ($null -eq $anchor) { Write-ErrorResult "ANCHOR_NOT_FOUND" "Anchor node not found: $AnchorNodeId" 2 }
                if ($anchor.status -ne "done") {
                    Write-ErrorResult "ANCHOR_NOT_DONE" "Anchor $AnchorNodeId is '$($anchor.status)'; achieved requires a settled (done) anchor. settle it first." 1
                }
            }
            "budget_exhausted" {
                $roundsHit = ([int]$roundState.last_round -ge [int]$manifest.budget.max_rounds)
                $nodesHit = (@($tree.nodes).Count -ge [int]$manifest.budget.max_nodes)
                if (-not ($roundsHit -or $nodesHit)) {
                    Write-ErrorResult "BUDGET_NOT_EXHAUSTED" "Budget not exhausted (rounds $($roundState.last_round)/$($manifest.budget.max_rounds), nodes $(@($tree.nodes).Count)/$($manifest.budget.max_nodes)). budget_exhausted must be honest — keep working, or conclude achieved/space_exhausted." 1
                }
            }
            "space_exhausted" {
                $census = Get-TreeCensus $tree
                if (($census.pending.Count + $census.claimed.Count) -gt 0) {
                    Write-ErrorResult "SPACE_NOT_EXHAUSTED" "Task space not exhausted: pending=[$($census.pending -join ',')] claimed=[$($census.claimed -join ',')]. space_exhausted requires a tree with no pending+claimed nodes." 1
                }
            }
        }

        # auto-close a hanging round so the two-line scheme stays consistent
        $autoClosed = $false
        if ($roundState.open_round -ne 0) {
            $null = Invoke-RoundEndAuto $RunDir $manifest ("auto round-end by conclude ($Outcome)")
            $autoClosed = $true
        }

        $concludedAt = Get-UtcNowIso
        $manifest.state = "concluded"
        $manifest.concluded = [ordered]@{
            outcome      = $Outcome
            concluded_at = $concludedAt
            anchor_node  = if ($anchor) { $anchor.id } else { $null }
            summary      = $Summary
        }

        # render the final report BEFORE flipping the manifest on disk: a render
        # failure leaves the run retry-able instead of concluded-without-report
        $finalTree = (Read-TreeEditable $RunDir).tree
        $reportPath = Write-FinalReport $RunDir $manifest $finalTree $Outcome $Summary $(if ($anchor) { $anchor.id } else { $null })
        Write-ManifestFile $RunDir $manifest

        return @{
            success = $true
            data    = @{
                run_id        = $RunId
                outcome       = $Outcome
                concluded_at  = $concludedAt
                anchor_node   = $(if ($anchor) { $anchor.id } else { $null })
                auto_round_closed = $autoClosed
                final_report  = ".rdd/tree-runs/$RunId/report/final-report.md"
                lock          = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# auto round-end inside conclude: shares the already-held lock, so it must not re-enter
function Invoke-RoundEndAuto {
    param([string]$RunDir, $Manifest, [string]$Why)

    $roundState = Get-RoundState $RunDir
    if ($roundState.open_round -eq 0) { return $null }
    $round = [int]$roundState.open_round
    $startedAt = [string]$roundState.open_started_at
    $endedAt = Get-UtcNowIso
    # snapshot first, log line second (same crash-ordering contract as round-end)
    $tree = (Read-TreeEditable $RunDir).tree
    $null = Write-RoundSnapshot $RunDir $Manifest $tree $round $startedAt $endedAt $Why "auto" $true
    Add-RoundLogLine $RunDir @{ event = "round-end"; round = $round; ended_at = $endedAt; summary = $Why; decision = "auto"; auto = $true }
    return $round
}

# === Command: status (full health check) ===

function Invoke-Status {
    param([string]$RunDir)

    $lockInfo = Enter-RunLock $RunDir
    try {
        $warnings = @()
        $manifest = Read-ManifestEditable $RunDir
        $readBack = Read-TreeEditable $RunDir
        if ($readBack.used_backup) { $warnings += "tree.json primary read failed; recovered from tree.json.bak" }
        $tree = $readBack.tree
        if ($tree.run_id -ne $manifest.run_id) { $warnings += "tree/manifest run_id mismatch: tree=$($tree.run_id) manifest=$($manifest.run_id)" }

        # ledger integrity + quarantine (only for still-running runs; concluded runs are frozen)
        $quarantined = 0
        if ($manifest.state -eq "running") {
            $ledger = Read-Ledger $RunDir
            if ($ledger.bad_lines.Count -gt 0) {
                Invoke-LedgerQuarantine $RunDir $ledger.entries $ledger.bad_lines
                $quarantined = $ledger.bad_lines.Count
                $warnings += "$($ledger.bad_lines.Count) unparseable ledger line(s) quarantined to ledger.jsonl.corrupt"
            }
        }
        $ledger2 = Read-Ledger $RunDir
        $stats = Get-LedgerStats $ledger2.entries

        $roundState = Get-RoundState $RunDir
        $warnings += @($roundState.warnings)
        $hangingRound = if ($roundState.open_round -ne 0) { $roundState.open_round } else { $null }

        $census = Get-TreeCensus $tree
        $budget = Get-BudgetUsage $manifest $tree $roundState

        $unsettled = @()
        foreach ($id in $census.reported) {
            $n = Find-Node $tree $id
            $unsettled += @{ id = $n.id; title = $n.title; reported_at = $n.reported_at; ledger_refs = @($n.ledger_refs) }
        }
        $inFlight = @()
        foreach ($id in $census.claimed) {
            $n = Find-Node $tree $id
            $ageSec = $null
            if ($n.claimed_at) {
                try { $ageSec = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($n.claimed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds } catch {}
            }
            $inFlight += @{ id = $n.id; title = $n.title; claimed_by = $n.claimed_by; claimed_at = $n.claimed_at; steal_count = $n.steal_count; age_seconds = $ageSec }
        }
        if ($unsettled.Count -gt 0) { $warnings += "$($unsettled.Count) reported node(s) awaiting settle: $(($unsettled | ForEach-Object { $_.id }) -join ', ')" }
        if ($hangingRound) { $warnings += "round $hangingRound open since $($roundState.open_started_at) (round-start without round-end)" }
        if ($manifest.state -eq "running" -and $census.pending.Count -eq 0 -and $census.claimed.Count -eq 0 -and $census.reported.Count -eq 0) {
            $warnings += "no pending/claimed/reported nodes left — consider conclude (space_exhausted or achieved)"
        }

        return @{
            success = $true
            data    = [ordered]@{
                run_id         = $RunId
                state          = $manifest.state
                concluded      = $manifest.concluded
                goal           = $manifest.goal
                created_by     = $manifest.created_by
                budget         = $budget
                round          = @{ last = $roundState.last_round; open = $hangingRound; open_started_at = $roundState.open_started_at }
                nodes          = [ordered]@{
                    total    = @($tree.nodes).Count
                    pending  = @($census.pending)
                    claimed  = $inFlight
                    reported = $unsettled
                    done     = @($census.done)
                    pruned   = @($census.pruned)
                }
                ledger         = [ordered]@{
                    entries     = $stats.total
                    valid       = $stats.valid
                    downgraded  = $stats.downgraded
                    invalid     = $stats.invalid
                    range_failures = $stats.range_failures
                    quarantined_now = $quarantined
                }
                integrity      = @{ tree_read_from_backup = $readBack.used_backup; warnings = $warnings }
                lock           = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: resume (breakpoint location for a fresh session) ===

function Invoke-Resume {
    param([string]$RunDir)

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-ManifestEditable $RunDir
        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree
        $roundState = Get-RoundState $RunDir
        $census = Get-TreeCensus $tree

        if ($manifest.state -eq "concluded") {
            return @{
                success = $true
                data    = @{
                    run_id = $RunId
                    state  = "concluded"
                    concluded = $manifest.concluded
                    message = "Run already concluded (outcome=$($manifest.concluded.outcome) at $($manifest.concluded.concluded_at)). Nothing to resume. Final report: report/final-report.md"
                }
            }
        }

        $hangingRound = $roundState.open_round
        $nextRound = [int]$roundState.last_round + 1
        $roundsExhausted = ($nextRound -gt [int]$manifest.budget.max_rounds)

        $pendingNodes = @()
        foreach ($id in $census.pending) {
            $n = Find-Node $tree $id
            $pendingNodes += @{ id = $n.id; title = $n.title }
        }
        $claimedNodes = @()
        foreach ($id in $census.claimed) {
            $n = Find-Node $tree $id
            $ageSec = $null
            if ($n.claimed_at) {
                try { $ageSec = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($n.claimed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds } catch {}
            }
            $claimedNodes += @{ id = $n.id; title = $n.title; claimed_by = $n.claimed_by; age_seconds = $ageSec }
        }
        $reportedNodes = @()
        foreach ($id in $census.reported) {
            $n = Find-Node $tree $id
            $reportedNodes += @{ id = $n.id; title = $n.title; ledger_refs = @($n.ledger_refs) }
        }

        $steps = @()
        if ($hangingRound -ne 0) {
            $steps += "Round $hangingRound is OPEN (started $($roundState.open_started_at)) — either keep dispatching remaining pending nodes (tree-leaf next/claim) or close it with: tree-run.cmd round-end -RunId $RunId -Summary <...>"
        }
        elseif ($roundsExhausted) {
            $steps += "Rounds budget exhausted (next would be $nextRound > max_rounds $($manifest.budget.max_rounds)) — conclude with: tree-run.cmd conclude -RunId $RunId -Outcome budget_exhausted -Summary <honest progress>"
        }
        else {
            $steps += "No hanging round — continue with: tree-run.cmd round-start -RunId $RunId (round $nextRound)"
        }
        if ($reportedNodes.Count -gt 0) {
            $steps += "Settle reported node(s) before re-planning: $(($reportedNodes | ForEach-Object { $_.id }) -join ', ') → tree-run.cmd settle"
        }
        if ($claimedNodes.Count -gt 0) {
            $steps += "In-flight claim(s) exist ($(($claimedNodes | ForEach-Object { $_.id }) -join ', ')); workers may still be running — verify, or steal stale claims via tree-leaf.cmd claim -Steal"
        }
        $steps += "Already-reported nodes are never re-consumed: claim only succeeds on pending (or steal on claimed)."

        return @{
            success = $true
            data    = [ordered]@{
                run_id         = $RunId
                state          = $manifest.state
                goal           = $manifest.goal
                budget         = (Get-BudgetUsage $manifest $tree $roundState)
                breakpoint     = [ordered]@{
                    hanging_round    = $(if ($hangingRound -ne 0) { $hangingRound } else { $null })
                    hanging_since    = $(if ($hangingRound -ne 0) { $roundState.open_started_at } else { $null })
                    next_round       = $nextRound
                    rounds_exhausted = $roundsExhausted
                }
                pending        = $pendingNodes
                claimed        = $claimedNodes
                reported_unsettle = $reportedNodes
                recovery_steps = $steps
                lock           = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Dispatch ===

switch ($Command) {
    "start"       { $result = Invoke-Start }
    "graft"       { $runDir = Resolve-RunDir $RunId; $result = Invoke-Graft $runDir }
    "prune"       { $runDir = Resolve-RunDir $RunId; $result = Invoke-Prune $runDir }
    "settle"      { $runDir = Resolve-RunDir $RunId; $result = Invoke-Settle $runDir }
    "round-start" { $runDir = Resolve-RunDir $RunId; $result = Invoke-RoundStart $runDir }
    "round-end"   { $runDir = Resolve-RunDir $RunId; $result = Invoke-RoundEnd $runDir }
    "conclude"    { $runDir = Resolve-RunDir $RunId; $result = Invoke-Conclude $runDir }
    "status"      { $runDir = Resolve-RunDir $RunId; $result = Invoke-Status $runDir }
    "resume"      { $runDir = Resolve-RunDir $RunId; $result = Invoke-Resume $runDir }
}

ConvertTo-PortableJson $result -Depth 14
exit 0

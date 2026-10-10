[CmdletBinding()]
param(
    [string]$Type,
    [string]$Query
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$scriptRoot = $PSScriptRoot
# Resolve-RepoRoot - project-root location chain (git-optional; protocol source:
# rdd-engine/references/engine-location.md, "Project-root location chain"). Fixed order:
#   1. $env:RDD_PROJECT_ROOT          explicit override; invalid path -> fail-loud
#   2. git rev-parse --show-toplevel  most accurate: worktree / submodule / GIT_DIR
#   3. nearest .git ancestor          filesystem twin of (2) when git is missing or
#                                     refuses the repo (dubious ownership)
#   4. nearest .rdd/install.json ancestor  anchors non-git projects back onto their
#                                     coderdd-init root when run from a subdirectory
#   5. cwd                            final fallback - same rule as the dsh plugin's
#                                     findRepoRoot (one mental model across the ecosystem)
# (2)+(3) keep every existing git project byte-identical (regression anchor);
# (4)+(5) only rescue trees where git says "not a repository".
function Resolve-RepoRoot {
    $envRoot = [string]$env:RDD_PROJECT_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        if (Test-Path -LiteralPath $envRoot -PathType Container) { return $envRoot }
        throw "RDD_PROJECT_ROOT does not exist: $envRoot"
    }
    $t = $null
    # 2>$null must stay inside try/catch: under PS5.1, redirected native stderr
    # plus $ErrorActionPreference=Stop raises NativeCommandError.
    try { $t = git rev-parse --show-toplevel 2>$null } catch { }
    if ($t) { return $t.Trim() }
    $start = (Get-Location).ProviderPath
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".rdd/install.json")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $start
}
$repoRoot = Resolve-RepoRoot

# explore.ps1 is the READ face of the exploration cache (explore-store.ps1
# is the write face). -Type search is the ONLY face: the retrieval contract —
# precision-ranked data LOCATIONS (summaryPath / fullPath). Pluggable
# multi-recall (lexical BM25 + vector cosine, see recallers/*.ps1) -> RRF
# fusion -> Top-K truncation run INSIDE this interface; results non-empty =
# HIT (relevance decided here, deterministically), empty = MISS
# (dispatchPrompt attached).
#
# The legacy `-Type explore` candidates face and the deprecated `-Type
# register` pass-through were removed (zero callers at removal time). Any
# other -Type value — including omitted/empty — fails loud at input
# validation (MISSING_TYPE / INVALID_TYPE): a stale caller must never get a
# silent empty success. Registration lives at explore-store.cmd -Type
# register.
#
# Stale entries (hash mismatch / deleted) are evicted from their own zone;
# a stale hot entry is dropped, never promoted.

# === Output encoding ===
# Emit UTF-8 JSON. Console output encoding is set to UTF8 above so callers
# receive valid UTF-8 regardless of system codepage.

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
    ConvertTo-PortableJson @{ success = $false; error = @{ code = $Code; message = $Message } } -Depth 3
    exit $ExitCode
}

# === Paths ===

function Get-ExplorationDir { Join-Path $repoRoot ".rdd/exploration" }
function Get-IndexPath      { Join-Path (Get-ExplorationDir) "index.json" }
function Get-HotPath        { Join-Path (Get-ExplorationDir) "hot.json" }
function Get-ArtifactsDir   { Join-Path (Get-ExplorationDir) "artifacts" }
function Get-QueryLogPath   { Join-Path (Get-ExplorationDir) "query-log.jsonl" }

function Resolve-RepoPath {
    param([string]$RelOrAbs)
    if ([string]::IsNullOrWhiteSpace($RelOrAbs)) { return $RelOrAbs }
    if ([System.IO.Path]::IsPathRooted($RelOrAbs)) { return $RelOrAbs }
    return (Join-Path $repoRoot $RelOrAbs)
}

function Get-NormalizedRelPath {
    param([string]$AbsPath)
    # Both sides normalized to platform separators before the prefix check:
    # git rev-parse --show-toplevel returns forward slashes on Windows, which
    # otherwise makes the comparison miss and every entry fall back to
    # absolute-path form (non-portable index).
    $full = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $AbsPath).Path.Replace("/", [System.IO.Path]::DirectorySeparatorChar))
    $root = [System.IO.Path]::GetFullPath($repoRoot.TrimEnd("\", "/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).Replace("\", "/")
    }
    return $full.Replace("\", "/")
}

function Get-FileSha256 {
    param([string]$AbsPath)
    if (-not (Test-Path -LiteralPath $AbsPath -PathType Leaf)) { return $null }
    $h = Get-FileHash -LiteralPath $AbsPath -Algorithm SHA256
    return "sha256:$($h.Hash.ToLowerInvariant())"
}

# Derive the paired summary path from a full-record path.
# ".rdd/exploration/artifacts/auth.md" -> ".rdd/exploration/artifacts/auth.summary.md"
function Get-SummaryPath {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $FullPath }
    if ($FullPath -match '\.md$') {
        return ($FullPath -replace '\.md$', '.summary.md')
    }
    return $FullPath + '.summary.md'
}

# Stable comparison identity for a stored artifact path (writers may store
# repo-relative OR absolute forward-slash forms). Resolves to the normalized
# repo-relative form, lowercased for Windows case-insensitivity.
function Get-PathIdentity {
    param([string]$StoredPath)
    $s = [string]$StoredPath
    if (-not [string]::IsNullOrWhiteSpace($s)) {
        try {
            $abs = Resolve-RepoPath $s
            if (Test-Path -LiteralPath $abs -PathType Leaf) {
                return ((Get-NormalizedRelPath $abs).ToLowerInvariant())
            }
        }
        catch { }
    }
    return $s.ToLowerInvariant()
}

# Parse a hot-zone registeredAt stamp (ISO-8601) into a UTC DateTime for
# ordering; unparseable stamps sort as the oldest.
function Get-HotTimestamp {
    param($Value)
    $parsed = [datetime]::MinValue
    if ($null -ne $Value) {
        $ok = [datetime]::TryParse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)
        if ($ok -and $parsed.Kind -eq [System.DateTimeKind]::Local) {
            $parsed = $parsed.ToUniversalTime()
        }
    }
    return $parsed
}

# === Index / hot IO ===

function Read-Index {
    $p = Get-IndexPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj.entries) { return @() }
        return @($obj.entries)
    }
    catch {
        Write-ErrorResult "INDEX_CORRUPT" "Failed to parse index.json: $($_.Exception.Message). Consider deleting and rebuilding." 3
    }
}

function Read-Hot {
    $p = Get-HotPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj.entries) { return @() }
        return @($obj.entries)
    }
    catch {
        Write-ErrorResult "HOT_CORRUPT" "Failed to parse hot.json: $($_.Exception.Message). Consider deleting it (unpromoted entries must be re-registered from their artifacts)." 3
    }
}

function Convert-ToFilesHashtable {
    param($Files)
    $ht = @{}
    if (-not $Files) { return $ht }
    if ($Files -is [System.Collections.IDictionary]) {
        foreach ($k in $Files.Keys) { $ht[$k] = $Files[$k] }
    }
    else {
        foreach ($prop in $Files.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
    }
    return $ht
}

# Normalize a tags value (from JSON or CLI) into a clean string array.
function Convert-ToTagsArray {
    param($Value)
    if (-not $Value) { return @() }
    if ($Value -is [string]) {
        return (($Value -split "[,;]") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }
    $arr = @()
    foreach ($item in $Value) {
        $s = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($s)) { $arr += $s.Trim() }
    }
    return $arr
}

function Write-Index {
    param([array]$Entries)
    $dir = Get-ExplorationDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $artifacts = Get-ArtifactsDir
    if (-not (Test-Path -LiteralPath $artifacts)) {
        New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    }
    # Rebuild each entry as a plain hashtable so ConvertTo-Json never re-serializes
    # a ConvertFrom-Json PSCustomObject (PS 5.1 deadlocks on that). Use the
    # type-aware helper: hashtable.PSObject.Properties returns .NET reflection
    # members (Count/Keys/...), NOT dictionary entries, in PS 5.1.
    $clean = @()
    foreach ($e in $Entries) {
        $clean += @{
            key   = $e.key
            tags  = @(Convert-ToTagsArray $e.tags)
            brief = $e.brief
            path  = $e.path
            files = (Convert-ToFilesHashtable $e.files)
        }
    }
    $payload = @{ entries = $clean } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText((Get-IndexPath), $payload, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Hot {
    param([array]$Entries)
    $dir = Get-ExplorationDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Same PS 5.1 defense as Write-Index: plain hashtables only.
    $clean = @()
    foreach ($e in $Entries) {
        $clean += @{
            key          = $e.key
            tags         = @(Convert-ToTagsArray $e.tags)
            brief        = $e.brief
            path         = $e.path
            files        = (Convert-ToFilesHashtable $e.files)
            registeredAt = ([string]$e.registeredAt)
        }
    }
    $payload = @{ entries = $clean } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText((Get-HotPath), $payload, (New-Object System.Text.UTF8Encoding($false)))
}

# === Fresh-candidate selection ===
# Returns fresh entries (SHA-256 still valid + artifact file present).
# Stale entries (hash mismatch / file deleted) are reported for zone cleanup.
function Select-FreshEntries {
    param([array]$Entries)

    $fresh = @()
    $stalePaths = @()

    foreach ($entry in $Entries) {
        $isStale = $false
        $entryFiles = Convert-ToFilesHashtable $entry.files

        foreach ($k in $entryFiles.Keys) {
            $current = Get-FileSha256 -AbsPath (Resolve-RepoPath $k)
            if ($null -eq $current -or $current -ne $entryFiles[$k]) {
                $isStale = $true
                break
            }
        }

        # Artifact file itself must still exist.
        if (-not $isStale) {
            $artifactAbs = Resolve-RepoPath $entry.path
            if (-not (Test-Path -LiteralPath $artifactAbs -PathType Leaf)) {
                $isStale = $true
            }
        }

        if ($isStale) {
            $stalePaths += $entry.path
        }
        else {
            $fresh += $entry
        }
    }

    return @{ Fresh = $fresh; StalePaths = $stalePaths }
}

# === Dual-zone merged read (search / explore) ===
# Hot zone first (newest registeredAt first), then the persistent index.
# Stale entries are evicted from their own zone (a stale hot entry is DROPPED,
# never promoted — staleness means the code changed, not that a pipeline
# lagged). Persistent entries whose key OR artifact path collides with a hot
# entry are suppressed: the hot view shadows the old persistent one until
# promotion's dedupe-replace reconciles the index.

function Get-MergedFresh {
    $indexEntries = Read-Index
    $indexResult = Select-FreshEntries -Entries $indexEntries
    if ($indexResult.StalePaths.Count -gt 0) {
        $kept = @()
        foreach ($e in $indexEntries) {
            if ($indexResult.StalePaths -notcontains $e.path) { $kept += $e }
        }
        Write-Index -Entries $kept
    }

    $hotEntries = Read-Hot
    $hotResult = Select-FreshEntries -Entries $hotEntries
    if ($hotResult.StalePaths.Count -gt 0) {
        $keptHot = @()
        foreach ($e in $hotEntries) {
            if ($hotResult.StalePaths -notcontains $e.path) { $keptHot += $e }
        }
        Write-Hot -Entries $keptHot
    }

    $hotFresh = @($hotResult.Fresh | Sort-Object -Descending -Property @{ Expression = { Get-HotTimestamp $_.registeredAt } })

    $hotKeys = @{}
    $hotIdentities = @{}
    $merged = @()
    foreach ($e in $hotFresh) {
        $hotKeys[[string]$e.key] = $true
        $hotIdentities[(Get-PathIdentity ([string]$e.path))] = $true
        $merged += @{ entry = $e; origin = "hot" }
    }
    foreach ($e in $indexResult.Fresh) {
        if ($hotKeys.ContainsKey([string]$e.key)) { continue }
        if ($hotIdentities.ContainsKey((Get-PathIdentity ([string]$e.path)))) { continue }
        $merged += @{ entry = $e; origin = "persistent" }
    }

    return @{
        Merged       = $merged
        StaleRemoved = ($indexResult.StalePaths.Count + $hotResult.StalePaths.Count)
    }
}

function ConvertTo-LocationViews {
    param([array]$Merged)
    $views = @()
    foreach ($m in $Merged) {
        $entry = $m.entry
        $views += @{
            key         = $entry.key
            tags        = @(Convert-ToTagsArray $entry.tags)
            brief       = $entry.brief
            summaryPath = (Get-SummaryPath $entry.path)
            fullPath    = $entry.path
            origin      = $m.origin
        }
    }
    return $views
}
# NOTE: callers must collect with @(...) — a function's return unwraps a
# single-element array to a scalar, which would serialize as an object
# instead of a one-element JSON array.

# === Precision-ranking pipeline (search branch only; read path stays pure-read) ===
# Frozen contract (see references/exploration-guide.md, formulas F1-F8):
#   F7 RRF   score(d) = SUM_r weight_r / (rrfK + rank_r(d)), rank from 1,
#            accumulated per recaller in registration order over each
#            qualified list (identical in the dsh plugin mirror).
#   F8 Top-K score DESC -> origin hot first -> registeredAt DESC (persistent
#            treated as oldest) -> key ordinal ASC (total order).
# The recall machinery itself -- frozen search-config defaults + fail-soft
# merge, the recaller plugin registry (recallers/*.ps1 loading included),
# the generic recaller invocation loop, the F7 fusion, and a comparator-
# driven insertion sort -- lives in the SHARED library lib/recall-shared.ps1
# (single source, dot-sourced by explore.ps1 and tips.ps1 alike; never fork
# a copy -- a second implementation would become a third mirror to keep in
# sync). Host-owned below: the exploration-specific glue -- tuning-file /
# vectors-sidecar paths, the merged-pool -> doc mapping, and the F8 Top-K
# views. Config lives in .rdd/exploration/search-config.json (all fields
# optional, missing = built-in defaults; PS/TS read the SAME file, so it is
# the runtime single source of behavior parity).

. (Join-Path $scriptRoot "lib\recall-shared.ps1")

function Get-SearchConfigPath { Join-Path (Get-ExplorationDir) "search-config.json" }
function Get-VectorsPath      { Join-Path (Get-ExplorationDir) "vectors.json" }

function Read-SearchConfig {
    # Thin host wrapper over the shared fail-soft reader (lib/recall-shared.ps1):
    # same defaults, same per-field validators, pointed at the exploration
    # tuning file.
    return (Read-RecallConfigFile -Path (Get-SearchConfigPath))
}

function Invoke-AllRecallers {
    # Host wrapper over the shared Invoke-Recallers (lib/recall-shared.ps1):
    # maps the merged fresh pool into corpus doc records (key/tags/brief feed
    # the recallers' F1 composition; path/origin ride along in the recaller
    # ctx contract), then runs the shared registry loop against the
    # exploration vectors sidecar.
    param([string]$Query, [array]$Merged, [hashtable]$Config)

    $docs = @()
    foreach ($m in $Merged) {
        $docs += @{
            key    = [string]$m.entry.key
            tags   = @(Convert-ToTagsArray $m.entry.tags)
            brief  = [string]$m.entry.brief
            path   = [string]$m.entry.path
            origin = $m.origin
        }
    }

    return (Invoke-Recallers -Query $Query -Docs $docs -Config $Config -VectorsPath (Get-VectorsPath))
}

function New-RankedCandidates {
    # Fusion-scored merged entries as sortable candidates; `stamp` feeds F8's
    # registeredAt tie-break (persistent entries count as the oldest).
    param([array]$Merged, [hashtable]$Fusion)
    $candidates = @()
    foreach ($m in $Merged) {
        $key = [string]$m.entry.key
        if (-not $Fusion.scores.ContainsKey($key)) { continue }
        $candidates += @{
            key        = $key
            tags       = @(Convert-ToTagsArray $m.entry.tags)
            brief      = [string]$m.entry.brief
            path       = [string]$m.entry.path
            origin     = $m.origin
            score      = [double]$Fusion.scores[$key]
            recalledBy = @($Fusion.recalledBy[$key])
            stamp      = $(if ($m.origin -eq "hot") { Get-HotTimestamp $m.entry.registeredAt } else { [datetime]::MinValue })
        }
    }
    return [object[]]$candidates
}

function Compare-RankedCandidates {
    # F8 total order (frozen): score DESC -> hot origin first -> registeredAt
    # DESC -> key ordinal ASC. Returns <0 when $Cur sorts BEFORE $Other.
    param($Cur, $Other)
    $diff = [double]$Cur.score - [double]$Other.score
    if ($diff -gt 0) { return -1 }
    if ($diff -lt 0) { return 1 }
    $curHot = ($Cur.origin -eq "hot")
    $otherHot = ($Other.origin -eq "hot")
    if ($curHot -ne $otherHot) { return $(if ($curHot) { -1 } else { 1 }) }
    $tickDiff = [long]$Cur.stamp.Ticks - [long]$Other.stamp.Ticks
    if ($tickDiff -gt 0) { return -1 }
    if ($tickDiff -lt 0) { return 1 }
    return [string]::CompareOrdinal([string]$Cur.key, [string]$Other.key)
}

function Sort-RankedCandidates {
    # F8 total order via the shared comparator-driven insertion sort
    # (lib/recall-shared.ps1); the ordering itself — Compare-RankedCandidates
    # — is the frozen part (no culture-sensitive comparisons anywhere).
    param([object[]]$Items)
    return (Invoke-InsertionSort -Items $Items -Compare { param($Cur, $Other) (Compare-RankedCandidates -Cur $Cur -Other $Other) })
}

function ConvertTo-TopKResultViews {
    # Top-K truncation + the caller-facing result view (summaryPath derived,
    # score rounded to 6 decimals — same rounding as the dsh mirror).
    param([object[]]$Ranked, [int]$TopK)
    $results = @()
    $take = $Ranked.Count
    if ($take -gt $TopK) { $take = $TopK }
    for ($i = 0; $i -lt $take; $i++) {
        $c = $Ranked[$i]
        $results += @{
            key         = $c.key
            tags        = @($c.tags)
            brief       = $c.brief
            summaryPath = (Get-SummaryPath $c.path)
            fullPath    = $c.path
            origin      = $c.origin
            score       = [math]::Round([double]$c.score, 6)
            recalledBy  = @($c.recalledBy)
        }
    }
    return $results
}

function Select-TopKResults {
    # F8 (frozen): build the fusion-scored candidates, sort by the total
    # order, truncate to Top-K. @(...) at each hop: a function's return
    # unwraps single-element arrays (see the NOTE above).
    param([array]$Merged, [hashtable]$Fusion, [int]$TopK)
    $ranked = @(New-RankedCandidates -Merged $Merged -Fusion $Fusion)
    $sorted = Sort-RankedCandidates -Items ([object[]]$ranked)
    return @(ConvertTo-TopKResultViews -Ranked ([object[]]$sorted) -TopK $TopK)
}

# === Dispatch prompt (returned for the caller LLM to use on no-match) ===

function Get-ExplorationGuidePath { Join-Path $scriptRoot "../references/exploration-guide.md" }

function Build-DispatchPrompt {
    param([string]$QueryText)
    $g = Get-ExplorationGuidePath
    if (-not (Test-Path -LiteralPath $g -PathType Leaf)) {
        Write-ErrorResult "REFERENCE_NOT_FOUND" "Reference file not found: references/exploration-guide.md (expected at $g)" 2
    }
    $guide = [System.IO.File]::ReadAllText($g, [System.Text.Encoding]::UTF8)
    return (@(
        "You are the rdd-engine code-exploration worker (rdd-explore).",
        "You are NOT a read-only explorer: you must write artifacts and register them.",
        "",
        "User exploration query:",
        $QueryText,
        "",
        "Repository root: $repoRoot",
        "Exploration cache directory: $(Get-ExplorationDir)",
        "Artifacts directory: $(Get-ArtifactsDir)",
        "",
        "Follow the protocol below strictly. On finish, call:",
        "  rdd-engine/scripts/explore-store.cmd -Type register -Key `"<semantic key, Chinese ok>`" -Tags `"<comma-separated module/feature/synonym keywords, Chinese and English>`" -Path `"<repo-relative FULL record path>`" -Brief `"<one-line summary>`" -Files `"<comma-separated repo-relative file paths>`"  (explore-store.sh on POSIX)",
        "Note: the full record and its paired summary ({slug}.summary.md) must both be written before registering. Registration lands in the hot zone (.rdd/exploration/hot.json) and is retrievable immediately.",
        "",
        "--- exploration-guide.md ---",
        $guide
    ) -join [System.Environment]::NewLine)
}

# === Query log (hit-rate data source) ===
# One append-only JSONL line per search query (.rdd/exploration/query-log.jsonl)
# -- the raw data hit-rate / miss-query analytics are computed from. Frozen
# six-field line contract, shared with the dsh plugin mirror
# (packages/local/rdd-explore/src/query-log.ts -- change both sides together):
#   ts        ISO-8601 UTC with milliseconds ("yyyy-MM-ddTHH:mm:ss.fffZ")
#   entry     "cli" (this script) | "dsh-plugin" (the tool side)
#   query     original query text
#   outcome   hit | miss (the CLI has no force-dispatch face)
#   keys      Top-K returned entry keys in rank order (miss -> [])
#   recallers [{name,status,qualified}] projected from the rankMeta outcomes
# Field order is frozen (ts,entry,query,outcome,keys,recallers) so lines from
# both writers are comparable apart from values. Failure isolation is a hard
# acceptance gate: any throw degrades to a stderr warning only -- the search
# result, stdout payload and exit code are untouched.
function Write-QueryLog {
    param(
        [string]$Query,
        [string]$Outcome,
        [array]$Keys,
        [array]$RecallerOutcomes
    )
    try {
        $loggedRecallers = @()
        foreach ($o in @($RecallerOutcomes)) {
            $loggedRecallers += [ordered]@{
                name      = [string]$o.name
                status    = [string]$o.status
                qualified = [int]$o.qualified
            }
        }
        $record = [ordered]@{
            ts        = ([datetime]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
            entry     = 'cli'
            query     = $Query
            outcome   = $Outcome
            keys      = @($Keys | ForEach-Object { [string]$_ })
            recallers = $loggedRecallers
        }
        $dir = Get-ExplorationDir
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # AppendAllText + UTF8Encoding($false): O_APPEND single-line write, no
        # BOM ever (Add-Content/Out-File stay banned -- PS5.1 default-encoding
        # traps). [ordered] keeps the field order identical to the TS mirror.
        [System.IO.File]::AppendAllText((Get-QueryLogPath), (ConvertTo-PortableJson $record) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        [Console]::Error.WriteLine("query-log append failed (ignored, search unaffected): $($_.Exception.Message)")
    }
}

# === Input validation ===
# search is the ONLY face. The legacy `explore` candidates face and the
# deprecated `register` pass-through were removed (zero callers at removal
# time) — stale callers fail loud here instead of getting a silent no-op.

if ([string]::IsNullOrWhiteSpace($Type)) {
    Write-ErrorResult "MISSING_TYPE" "-Type is required. Valid values: search" 1
}
if ($Type -ne "search") {
    Write-ErrorResult "INVALID_TYPE" "Unknown type: '$Type'. search is the only read face (explore.cmd -Type search -Query '...'); the legacy 'explore' and 'register' faces were removed; registration lives at explore-store.cmd -Type register." 1
}

# === Type: search (retrieval contract: precision-ranked locations) — the only face ===
# Multi-recall -> RRF fusion -> Top-K truncation run INSIDE this branch, over
# the merged fresh pool. The caller protocol is TWO branches: results
# non-empty = HIT (relevance is the interface's deterministic verdict — read
# summaryPath by rank, no more full-tag scanning), empty = MISS (dispatchPrompt
# attached). Single-path failure/disable degrades to the remaining paths.

if ($Type -eq "search") {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-ErrorResult "MISSING_QUERY" "-Query is required and cannot be empty" 1
    }

    $result = Get-MergedFresh
    $config = Read-SearchConfig
    $recall = Invoke-AllRecallers -Query $Query -Merged $result.Merged -Config $config
    $fusion = Invoke-RRFFusion -QualifiedLists $recall.lists -RrfK ([int]$config.rrfK)
    $results = @(Select-TopKResults -Merged $result.Merged -Fusion $fusion -TopK ([int]$config.topK))

    $recallerViews = @()
    foreach ($o in @($recall.outcomes)) {
        $view = @{
            name      = [string]$o.name
            status    = [string]$o.status
            qualified = [int]$o.qualified
        }
        if (-not [string]::IsNullOrEmpty([string]$o.warning)) { $view["warning"] = [string]$o.warning }
        $recallerViews += $view
    }

    # Query-log decision point (hit-rate data source): ONE append per search,
    # after results are computed and before anything is emitted. The CLI has
    # no force-dispatch face, so the outcome is exactly hit|miss here.
    $loggedOutcome = 'miss'
    $loggedKeys = @()
    if ($results.Count -gt 0) {
        $loggedOutcome = 'hit'
        $loggedKeys = @($results | ForEach-Object { [string]$_.key })
    }
    Write-QueryLog -Query $Query -Outcome $loggedOutcome -Keys $loggedKeys -RecallerOutcomes $recallerViews

    $data = @{
        query        = $Query
        results      = $results
        staleRemoved = $result.StaleRemoved
        rankMeta     = @{
            recallers = $recallerViews
            fused     = $fusion.scores.Count
            returned  = $results.Count
        }
    }
    if ($results.Count -eq 0) {
        $data["dispatchPrompt"] = (Build-DispatchPrompt -QueryText $Query)
    }

    ConvertTo-PortableJson @{ success = $true; data = $data } -Depth 8
    exit 0
}

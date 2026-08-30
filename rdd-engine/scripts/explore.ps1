[CmdletBinding()]
param(
    [string]$Type,
    [string]$Query,
    [string]$Key,
    [string]$Tags,
    [string]$Path,
    [string]$Brief,
    [string]$Files
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$scriptRoot = $PSScriptRoot
$repoRoot = git rev-parse --show-toplevel

# explore.ps1 is the READ face of the exploration cache (explore-store.ps1
# is the write face):
#   -Type explore  -> legacy candidates face: merged dual-zone fresh entries
#                     (hot first), dispatchPrompt ALWAYS attached. Superset of
#                     the old single-zone output (each candidate gains `origin`).
#   -Type search   -> the retrieval contract: precision-ranked data LOCATIONS
#                     (summaryPath / fullPath). Pluggable multi-recall (lexical
#                     BM25 + vector cosine, see recallers/*.ps1) -> RRF fusion
#                     -> Top-K truncation run INSIDE this interface; results
#                     non-empty = HIT (relevance decided here, deterministically),
#                     empty = MISS (dispatchPrompt attached).
#   -Type register -> DEPRECATED pass-through to explore-store.ps1 (register
#                     now writes the hot zone); output gains a deprecation note.
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
# Config lives in .rdd/exploration/search-config.json (all fields optional,
# missing = built-in defaults below; PS/TS read the SAME file, so it is the
# runtime single source of behavior parity). Defaults are frozen mirrors of
# dsh packages/local/rdd-explore/src/cache.ts SEARCH_CONFIG_DEFAULTS.

$SearchDefaults = @{
    topK        = 5
    recallDepth = 20
    rrfK        = 60
    recallers   = @{
        lexical = @{
            enabled = $true
            weight  = 1.0
            bm25K1  = 1.2
            bm25B   = 0.75
        }
        vector  = @{
            enabled         = "auto"
            weight          = 1.0
            endpoint        = ""
            model           = ""
            dimensions      = 0
            minCosine       = 0.30
            timeoutSeconds  = 10
        }
    }
}

function Get-SearchConfigPath { Join-Path (Get-ExplorationDir) "search-config.json" }
function Get-VectorsPath      { Join-Path (Get-ExplorationDir) "vectors.json" }

function Get-SearchConfigValue {
    # Typed, range-checked single-field override; invalid or unknown values
    # silently keep the default (only file-level corruption warns — a tuning
    # file fails soft, unlike the fail-loud index data).
    param($Obj, [string]$Name, $Current, [scriptblock]$Valid)
    if ($null -ne $Obj) {
        $prop = $Obj.PSObject.Properties[$Name]
        if ($null -ne $prop) {
            $v = $prop.Value
            if (& $Valid $v) { return $v }
        }
    }
    return $Current
}

function Get-SearchFieldValidator {
    # Single copy of every field predicate, shared by the section mergers
    # below (semantics identical to the dsh cache.ts pick() validators).
    # An unknown kind yields a never-matching predicate: the tuning file
    # fails soft, like every other config path here.
    param([string]$Kind)
    switch ($Kind) {
        "posInt"    { { param($v) $v -is [int] -and $v -ge 1 } }
        "posNum"    { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -gt 0 } }
        "isEnabled" { { param($v) $v -is [bool] -or ($v -is [string] -and $v -eq "auto") } }
        "isString"  { { param($v) $v -is [string] } }
        "isDim"     { { param($v) $v -is [int] -and $v -ge 0 } }
        "isK1"      { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge 0 } }
        "isB"       { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge 0 -and [double]$v -le 1 } }
        "isCos"     { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge -1 -and [double]$v -le 1 } }
        "isTimeout" { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge 1 } }
        default     { { param($v) $false } }
    }
}

function Merge-LexicalRecallerConfig {
    param($Section, $Defaults)
    return @{
        enabled = Get-SearchConfigValue $Section "enabled" $Defaults.enabled (Get-SearchFieldValidator "isEnabled")
        weight  = Get-SearchConfigValue $Section "weight"  $Defaults.weight  (Get-SearchFieldValidator "posNum")
        bm25K1  = Get-SearchConfigValue $Section "bm25K1"  $Defaults.bm25K1  (Get-SearchFieldValidator "isK1")
        bm25B   = Get-SearchConfigValue $Section "bm25B"   $Defaults.bm25B   (Get-SearchFieldValidator "isB")
    }
}

function Merge-VectorRecallerConfig {
    param($Section, $Defaults)
    return @{
        enabled        = Get-SearchConfigValue $Section "enabled"        $Defaults.enabled        (Get-SearchFieldValidator "isEnabled")
        weight         = Get-SearchConfigValue $Section "weight"         $Defaults.weight         (Get-SearchFieldValidator "posNum")
        endpoint       = Get-SearchConfigValue $Section "endpoint"       $Defaults.endpoint       (Get-SearchFieldValidator "isString")
        model          = Get-SearchConfigValue $Section "model"          $Defaults.model          (Get-SearchFieldValidator "isString")
        dimensions     = Get-SearchConfigValue $Section "dimensions"     $Defaults.dimensions     (Get-SearchFieldValidator "isDim")
        minCosine      = Get-SearchConfigValue $Section "minCosine"      $Defaults.minCosine      (Get-SearchFieldValidator "isCos")
        timeoutSeconds = Get-SearchConfigValue $Section "timeoutSeconds" $Defaults.timeoutSeconds (Get-SearchFieldValidator "isTimeout")
    }
}

function Read-SearchConfig {
    $config = $SearchDefaults

    $obj = $null
    $p = Get-SearchConfigPath
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
        }
        catch {
            [Console]::Error.WriteLine("search-config.json unreadable (built-in defaults apply): $($_.Exception.Message)")
            return $config
        }
    }
    if ($null -eq $obj) { return $config }

    $lex = $null
    $vec = $null
    if ($null -ne $obj.recallers) {
        $lex = $obj.recallers.lexical
        $vec = $obj.recallers.vector
    }
    return @{
        topK        = Get-SearchConfigValue $obj "topK" $config.topK (Get-SearchFieldValidator "posInt")
        recallDepth = Get-SearchConfigValue $obj "recallDepth" $config.recallDepth (Get-SearchFieldValidator "posInt")
        rrfK        = Get-SearchConfigValue $obj "rrfK" $config.rrfK (Get-SearchFieldValidator "posNum")
        recallers   = @{
            lexical = Merge-LexicalRecallerConfig -Section $lex -Defaults $config.recallers.lexical
            vector  = Merge-VectorRecallerConfig -Section $vec -Defaults $config.recallers.vector
        }
    }
}

# --- Recaller plugin registry (each recallers/*.ps1 self-registers) ---

$script:Recallers = @()

function Register-Recaller {
    # Plugin contract (mirrored in dsh src/cache.ts Recaller): a recaller only
    # SCORES docs — never fuses, never truncates. $DefaultEnabled is what an
    # unconfigured recaller falls back to ($true / $false / "auto").
    # $AutoReady evaluates the "auto" rule without running the recaller; it
    # receives the WHOLE config and returns @{ ready; reason? }. Recallers
    # take everything through $ctx and never reference host functions back.
    param(
        [string]$Name,
        $DefaultEnabled,
        [scriptblock]$AutoReady,
        [scriptblock]$ScriptBlock
    )
    $script:Recallers += @{
        Name           = $Name
        DefaultEnabled = $DefaultEnabled
        AutoReady      = $AutoReady
        ScriptBlock    = $ScriptBlock
    }
}

# Dot-source every plugin (sorted by name = frozen registration order, which
# F7's accumulation order depends on: lexical.ps1 before vector.ps1).
$recallerDir = Join-Path $scriptRoot "recallers"
if (Test-Path -LiteralPath $recallerDir -PathType Container) {
    foreach ($plugin in @(Get-ChildItem -LiteralPath $recallerDir -Filter "*.ps1" -File | Sort-Object -Property Name)) {
        . $plugin.FullName
    }
}
if ($script:Recallers.Count -eq 0) {
    [Console]::Error.WriteLine("no recallers registered (expected scripts/recallers/*.ps1); search degrades to always-miss")
}

function Get-RecallerSection {
    # Null-safe config-section lookup. A third-party recaller (a new file in
    # recallers/) has NO section in search-config.json nor $SearchDefaults —
    # it must get $null here, never a null-array index crash. Frozen mirror
    # of the dsh plugin's `config.recallers[recaller.name]` optional access.
    param([hashtable]$Config, [string]$Name)
    if ($null -eq $Config -or $null -eq $Config.recallers) { return $null }
    return $Config.recallers[$Name]
}

function Resolve-RecallerEnabled {
    # run/skip decision for one recaller. An unconfigured recaller falls back
    # to its self-reported DefaultEnabled (frozen mirror of the dsh
    # `section?.enabled ?? recaller.defaultEnabled`); "auto" consults the
    # plugin's AutoReady against the WHOLE config, forwarding its reason.
    param($Recaller, $Section, [hashtable]$Config)
    $enabledValue = $null
    if ($null -ne $Section) { $enabledValue = $Section["enabled"] }
    if ($null -eq $enabledValue) { $enabledValue = $Recaller.DefaultEnabled }
    if ($enabledValue -eq $true) { return @{ run = $true } }
    if ($enabledValue -ne "auto") { return @{ run = $false } }
    $verdict = @{ ready = $true }
    if ($null -ne $Recaller.AutoReady) { $verdict = & $Recaller.AutoReady $Config }
    if ($verdict.ready) { return @{ run = $true } }
    return @{ run = $false; warning = ([string]$verdict.reason) }
}

function Invoke-SingleRecaller {
    # Runs one recaller; any throw degrades to a failed outcome (the
    # pluggability guarantee: one broken path never breaks the interface).
    param($Recaller, [hashtable]$Ctx, [double]$Weight)
    try {
        $res = & $Recaller.ScriptBlock $Ctx
        $qualified = @($res.qualified)
        $outcome = @{
            name      = [string]$res.name
            status    = "ok"
            qualified = $qualified.Count
        }
        if (-not [string]::IsNullOrEmpty([string]$res.warning)) { $outcome["warning"] = [string]$res.warning }
        return @{
            outcome = $outcome
            list    = @{ name = [string]$res.name; qualified = $qualified; weight = $Weight }
        }
    }
    catch {
        return @{
            outcome = @{ name = $Recaller.Name; status = "failed"; qualified = 0; warning = "$($_.Exception.Message)" }
        }
    }
}

function Invoke-AllRecallers {
    # Runs every registered recaller (registration order = F7 accumulation
    # order); a disabled/failed path yields an empty contribution plus a
    # rankMeta outcome — the interface stays complete on any single-path
    # failure (pluggability guarantee).
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
    $ctx = @{
        query  = $Query
        docs   = $docs
        config = $Config
        paths  = @{ vectorsPath = (Get-VectorsPath) }
    }

    $outcomes = @()
    $qualifiedLists = @()
    foreach ($r in $script:Recallers) {
        $section = Get-RecallerSection -Config $Config -Name $r.Name
        $decision = Resolve-RecallerEnabled -Recaller $r -Section $section -Config $Config
        if (-not $decision.run) {
            $outcome = @{ name = $r.Name; status = "disabled"; qualified = 0 }
            if ($null -ne $decision.warning) { $outcome["warning"] = $decision.warning }
            $outcomes += $outcome
            continue
        }
        $weight = 1.0
        if ($null -ne $section -and $null -ne $section["weight"]) { $weight = [double]$section["weight"] }
        $ran = Invoke-SingleRecaller -Recaller $r -Ctx $ctx -Weight $weight
        $outcomes += $ran.outcome
        if ($null -ne $ran.list) { $qualifiedLists += $ran.list }
    }

    return @{ outcomes = $outcomes; lists = $qualifiedLists }
}

function Invoke-RRFFusion {
    # F7 (frozen): accumulate in registration order over each qualified list.
    # Ordinal key tables so PS's default case-insensitive hashtables can never
    # collide two distinct entry keys.
    param([array]$QualifiedLists, [int]$RrfK)

    $scores = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $recalledBy = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($list in $QualifiedLists) {
        $rank = 0
        foreach ($key in @($list.qualified)) {
            $rank++
            if (-not $scores.ContainsKey($key)) {
                $scores[$key] = 0.0
                $recalledBy[$key] = @()
            }
            $scores[$key] = [double]$scores[$key] + [double]$list.weight / ($RrfK + $rank)
            $recalledBy[$key] = @($recalledBy[$key]) + @($list.name)
        }
    }
    return @{ scores = $scores; recalledBy = $recalledBy }
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
    # In-place insertion sort over the F8 total order: no culture-sensitive
    # comparisons, so the ordering is frozen-identical to the dsh mirror.
    param([object[]]$Items)
    for ($i = 1; $i -lt $Items.Count; $i++) {
        $cur = $Items[$i]
        $j = $i - 1
        while ($j -ge 0 -and (Compare-RankedCandidates -Cur $cur -Other $Items[$j]) -lt 0) {
            $Items[$j + 1] = $Items[$j]
            $j--
        }
        $Items[$j + 1] = $cur
    }
    return $Items
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

# === Input validation ===

if ([string]::IsNullOrWhiteSpace($Type)) {
    Write-ErrorResult "MISSING_TYPE" "-Type is required. Valid values: explore, search, register" 1
}
if ($Type -notin @("explore", "search", "register")) {
    Write-ErrorResult "INVALID_TYPE" "Unknown type: '$Type'. Valid values: explore, search, register" 1
}

# === Type: explore (legacy candidates face; dispatchPrompt always attached) ===
# Returns ALL fresh candidates from BOTH zones (hot first), each with `origin`.
# The caller LLM inspects tags + brief to decide relevance itself. Semantic
# matching is NOT done here.

if ($Type -eq "explore") {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-ErrorResult "MISSING_QUERY" "-Query is required and cannot be empty" 1
    }

    $result = Get-MergedFresh
    $candidates = @(ConvertTo-LocationViews -Merged $result.Merged)

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            query          = $Query
            candidates     = $candidates
            staleRemoved   = $result.StaleRemoved
            dispatchPrompt = (Build-DispatchPrompt -QueryText $Query)
        }
    } -Depth 6
    exit 0
}

# === Type: search (retrieval contract: precision-ranked locations) ===
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

# === Type: register (DEPRECATED pass-through to explore-store.ps1) ===
# The write face moved to explore-store.ps1; registration now lands in the
# hot zone. Old callers keep working unchanged; the output gains a
# `deprecation` field pointing at explore-store.

if ($Type -eq "register") {
    $storeScript = Join-Path $scriptRoot "explore-store.ps1"
    if (-not (Test-Path -LiteralPath $storeScript -PathType Leaf)) {
        Write-ErrorResult "STORE_NOT_FOUND" "register moved to explore-store.ps1, which was not found at: $storeScript" 2
    }

    $raw = $null
    try {
        $raw = & $storeScript -Type register -Key $Key -Tags $Tags -Path $Path -Brief $Brief -Files $Files
    }
    catch {
        Write-ErrorResult "REGISTER_FORWARD_FAILED" "explore-store.ps1 register invocation failed: $($_.Exception.Message)" 1
    }
    $forwardExit = $LASTEXITCODE
    if ($null -eq $forwardExit) { $forwardExit = 0 }

    $text = ""
    if ($null -ne $raw) { $text = ($raw -join [System.Environment]::NewLine) }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-ErrorResult "REGISTER_FORWARD_FAILED" "explore-store.ps1 register produced no output (exit=$forwardExit)" 1
    }

    $obj = $null
    try { $obj = $text | ConvertFrom-Json } catch { $obj = $null }

    if ($null -eq $obj -or -not $obj.success) {
        # Forward failures (and unparseable output) verbatim.
        $text
        exit $forwardExit
    }

    # Rebuild as a plain hashtable (PS 5.1 ConvertTo-Json deadlock defense)
    # and add the deprecation note.
    $dataHt = @{}
    if ($null -ne $obj.data) {
        foreach ($p in $obj.data.PSObject.Properties) { $dataHt[$p.Name] = $p.Value }
    }
    $dataHt["deprecation"] = "explore.ps1 -Type register is deprecated and forwards to explore-store.ps1 (registration lands in the hot zone .rdd/exploration/hot.json). Call rdd-engine/scripts/explore-store.cmd -Type register directly."
    ConvertTo-PortableJson @{ success = $true; data = $dataHt } -Depth 4
    exit $forwardExit
}

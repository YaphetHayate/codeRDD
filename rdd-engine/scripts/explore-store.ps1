[CmdletBinding()]
param(
    [string]$Type,
    [string]$Key,
    [string]$Tags,
    [string]$Path,
    [string]$Brief,
    [string]$Files,
    [switch]$PurgeOtherModels
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$repoRoot = git rev-parse --show-toplevel

# === Hot-zone policy constants ===
# Mirrored in the dsh plugin (packages/local/rdd-explore/src/cache.ts) —
# change both writers together (frozen contract). No config file, no env var.
$HotRetentionDays = 7
$HotCapacity = 50

# === Embedding constants (frozen mirrors) ===
# Same values as explore.ps1 $SearchDefaults and dsh cache.ts
# SEARCH_CONFIG_DEFAULTS — change all copies together (frozen contract).
$EmbedDefaults = @{
    endpoint        = ""
    model           = ""
    dimensions      = 0
    minCosine       = 0.30
    timeoutSeconds  = 10
    weight          = 1.0
    enabled         = "auto"
}

# explore-store.ps1 is the WRITE face of the exploration cache (explore.ps1
# is the read face):
#   -Type register -> validate (same chain as the legacy register), write
#                     the HOT ZONE (.rdd/exploration/hot.json), stamped with
#                     registeredAt — then SYNCHRONOUSLY EMBED the single new
#                     entry (vectors.json sidecar) when the vector config is
#                     complete. Embedding failure only warns: the hot write
#                     already guarantees registration, and embed-backfill can
#                     retry later. The next search/explore sees the entry at
#                     once via the lexical path regardless; no async pipeline
#                     is required.
#   -Type persist  -> promote one hot entry by key into the persistent
#                     index.json (dedupe-replace), then remove it from hot.
#                     The vectors sidecar is content-addressed and
#                     zone-agnostic, so promotion moves nothing.
#   -Type embed-backfill -> (re)compute missing vectors for every fresh
#                     merged entry under the CURRENT configured model
#                     (content/model change invalidates via F6, so a model
#                     switch re-embeds automatically). -PurgeOtherModels also
#                     drops sidecar entries of every OTHER model. Deployment
#                     migration = run this once.
# A sweep runs on every register/persist call: entries older than the
# retention window, or overflowing the capacity, are promoted into
# index.json AS-IS. "No loss" is the hard constraint: an already-explored
# result never disappears because the enhancement pipeline never ran.
# Sweep failures are reported on stderr but never block the caller; the next
# sweep retries idempotently.

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
function Get-SummaryPath {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $FullPath }
    if ($FullPath -match '\.md$') {
        return ($FullPath -replace '\.md$', '.summary.md')
    }
    return $FullPath + '.summary.md'
}

# Stable comparison identity for a stored artifact path. Writers store either
# repo-relative or absolute forward-slash forms; resolve to the normalized
# repo-relative form (lowercased, so Windows case-insensitivity holds) when
# the file exists, else fall back to the raw lowercased string.
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

# Parse a hot-zone registeredAt stamp (ISO-8601 UTC) into a UTC DateTime.
# RoundtripKind keeps the UTC ticks; unparseable stamps collapse to MinValue
# so a malformed entry counts as the OLDEST on sweep (conservative no-loss).
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

# === Embedding write face (frozen-contract copies) ===
# F1/F2/F5 below are frozen formulas shared (as literal copies, per repo
# convention) with scripts/recallers/vector.ps1 and the dsh plugin
# (src/cache.ts + src/recallers/vector.ts). Change every copy together.

function Get-EmbedSearchText {
    # F1 (frozen): key + "\n" + tags.join(",") + "\n" + brief.
    param([string]$Key, [array]$Tags, [string]$Brief)
    return ($Key + "`n" + ((@($Tags) | ForEach-Object { [string]$_ }) -join ",") + "`n" + $Brief)
}

function Get-EmbedTextHash {
    # F2 (frozen): "sha256:" + SHA256(utf8(F1 text)).hex.
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ("sha256:" + (($hash | ForEach-Object { $_.ToString("x2") }) -join ""))
    }
    finally {
        $sha.Dispose()
    }
}

function Get-VectorsSidecarPath { Join-Path (Get-ExplorationDir) "vectors.json" }

function Get-SearchConfigSidecarPath { Join-Path (Get-ExplorationDir) "search-config.json" }

function Read-EmbedVectorConfig {
    # Reads ONLY the vector recaller section of search-config.json (same
    # fail-soft rules as the read face: missing/corrupt -> defaults + stderr
    # warning). Field validators mirror explore.ps1 / dsh cache.ts exactly.
    $v = @{
        endpoint        = [string]$EmbedDefaults.endpoint
        model           = [string]$EmbedDefaults.model
        dimensions      = [int]$EmbedDefaults.dimensions
        minCosine       = [double]$EmbedDefaults.minCosine
        timeoutSeconds  = [int]$EmbedDefaults.timeoutSeconds
    }
    $p = Get-SearchConfigSidecarPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $v }

    $obj = $null
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
    }
    catch {
        [Console]::Error.WriteLine("search-config.json unreadable (built-in defaults apply): $($_.Exception.Message)")
        return $v
    }
    if ($null -eq $obj) { return $v }
    if ($null -eq $obj.recallers) { return $v }
    $vec = $obj.recallers.vector
    if ($null -eq $vec) { return $v }

    if ($null -ne $vec.PSObject.Properties["endpoint"] -and $vec.endpoint -is [string]) { $v.endpoint = [string]$vec.endpoint }
    if ($null -ne $vec.PSObject.Properties["model"] -and $vec.model -is [string]) { $v.model = [string]$vec.model }
    if ($null -ne $vec.PSObject.Properties["dimensions"] -and $vec.dimensions -is [int] -and $vec.dimensions -ge 0) { $v.dimensions = [int]$vec.dimensions }
    if ($null -ne $vec.PSObject.Properties["timeoutSeconds"] -and ($vec.timeoutSeconds -is [int] -or $vec.timeoutSeconds -is [double]) -and [double]$vec.timeoutSeconds -ge 1) { $v.timeoutSeconds = [int][double]$vec.timeoutSeconds }
    if ($null -ne $vec.PSObject.Properties["weight"] -and ($vec.weight -is [int] -or $vec.weight -is [double]) -and [double]$vec.weight -gt 0) { $v.weight = [double]$vec.weight }
    return $v
}

function Test-EmbedVectorConfig {
    # Auto/completeness rule (frozen, same in recallers/vector.ps1 AutoReady):
    # endpoint + model + dimensions>=1 + RDD_EMBED_APIKEY.
    param([hashtable]$V)
    $missing = @()
    if ([string]::IsNullOrWhiteSpace([string]$V.endpoint)) { $missing += "endpoint" }
    if ([string]::IsNullOrWhiteSpace([string]$V.model)) { $missing += "model" }
    if ([int]$V.dimensions -lt 1) { $missing += "dimensions" }
    if ([string]::IsNullOrWhiteSpace([string]$env:RDD_EMBED_APIKEY)) { $missing += "RDD_EMBED_APIKEY" }
    return @{ Complete = ($missing.Count -eq 0); Missing = $missing }
}

function Invoke-EmbedApi {
    # F5 (frozen): POST {endpoint} with { model, input: [texts] }, Bearer key
    # from RDD_EMBED_APIKEY, response data[i].embedding. UTF-8 byte body so
    # PS 5.1 never re-encodes CJK single-byte.
    param([hashtable]$V, [string[]]$Texts)
    $apiKey = [string]$env:RDD_EMBED_APIKEY
    $body = @{ model = [string]$V.model; input = @($Texts) } | ConvertTo-Json -Depth 4 -Compress
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = Invoke-RestMethod `
        -Method Post `
        -Uri ([string]$V.endpoint) `
        -ContentType "application/json; charset=utf-8" `
        -Headers @{ Authorization = "Bearer $apiKey" } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec ([int]$V.timeoutSeconds)
    if ($null -eq $resp -or $null -eq $resp.data) {
        throw "embedding response missing data[] (endpoint: $([string]$V.endpoint))"
    }
    # Comma-wrap each vector: plain += would FLATTEN the nested arrays.
    $out = @()
    foreach ($d in @($resp.data)) { $out += ,([double[]]($d.embedding)) }
    return $out
}

function Read-VectorsSidecar {
    # vectors.json: { "entries": [{ key, textHash, model, vector }] }. Derived
    # data — corrupt = empty + stderr warning (embed-backfill rebuilds).
    $p = Get-VectorsSidecarPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj.entries) { return @() }
        return @($obj.entries)
    }
    catch {
        [Console]::Error.WriteLine("vectors.json unreadable (treated as empty; embed-backfill rebuilds it): $($_.Exception.Message)")
        return @()
    }
}

function Write-VectorsSidecar {
    # PS 5.1 defense: rebuild every entry as a plain hashtable (never
    # re-serialize ConvertFrom-Json PSCustomObjects).
    param([array]$Entries)
    $dir = Get-ExplorationDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $clean = @()
    foreach ($e in $Entries) {
        $clean += @{
            key      = [string]$e.key
            textHash = [string]$e.textHash
            model    = [string]$e.model
            vector   = [double[]]($e.vector | ForEach-Object { [double]$_ })
        }
    }
    $payload = @{ entries = $clean } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText((Get-VectorsSidecarPath), $payload, (New-Object System.Text.UTF8Encoding($false)))
}

function Find-VectorsSidecarEntry {
    # Primary key (key, textHash, model) — exact triple match (frozen).
    param([array]$Entries, [string]$Key, [string]$TextHash, [string]$Model)
    foreach ($e in $Entries) {
        if ([string]$e.key -eq $Key -and [string]$e.textHash -eq $TextHash -and [string]$e.model -eq $Model) {
            return $e
        }
    }
    return $null
}

function Add-VectorsSidecarEntry {
    # Upsert by the (key, textHash, model) triple: replaces an exact match,
    # appends otherwise. Other models' vectors coexist untouched.
    param([array]$Entries, [string]$Key, [string]$TextHash, [string]$Model, [double[]]$Vector)
    $out = @()
    $replaced = $false
    foreach ($e in $Entries) {
        if ([string]$e.key -eq $Key -and [string]$e.textHash -eq $TextHash -and [string]$e.model -eq $Model) {
            $out += @{ key = $Key; textHash = $TextHash; model = $Model; vector = $Vector }
            $replaced = $true
        }
        else {
            $out += $e
        }
    }
    if (-not $replaced) {
        $out += @{ key = $Key; textHash = $TextHash; model = $Model; vector = $Vector }
    }
    return $out
}

function Test-EntryFresh {
    # Pure freshness check (no zone eviction) — embed-backfill spends API
    # calls only on entries the read face would still serve.
    param($Entry)
    $entryFiles = Convert-ToFilesHashtable $Entry.files
    foreach ($k in $entryFiles.Keys) {
        $current = Get-FileSha256 -AbsPath (Resolve-RepoPath $k)
        if ($null -eq $current -or $current -ne $entryFiles[$k]) { return $false }
    }
    if (-not (Test-Path -LiteralPath (Resolve-RepoPath ([string]$Entry.path)) -PathType Leaf)) { return $false }
    return $true
}

function Invoke-RegisterEmbedHook {
    # Synchronous single-entry embed after a successful hot write. Returns a
    # small status object for the register output; NEVER throws.
    param([string]$Key, [array]$Tags, [string]$Brief)
    try {
        $v = Read-EmbedVectorConfig
        $check = Test-EmbedVectorConfig -V $v
        if (-not $check.Complete) {
            return @{ status = "skipped"; reason = ("vector config incomplete (" + ($check.Missing -join ", ") + ")") }
        }
        $text = Get-EmbedSearchText -Key $Key -Tags $Tags -Brief $Brief
        $hash = Get-EmbedTextHash $text
        $entries = @(Read-VectorsSidecar)
        $existing = Find-VectorsSidecarEntry -Entries $entries -Key $Key -TextHash $hash -Model ([string]$v.model)
        if ($null -ne $existing) {
            return @{ status = "reused"; model = [string]$v.model }
        }
        $embedded = @(Invoke-EmbedApi -V $v -Texts @($text))
        $entries = Add-VectorsSidecarEntry -Entries $entries -Key $Key -TextHash $hash -Model ([string]$v.model) -Vector ([double[]]$embedded[0])
        Write-VectorsSidecar -Entries $entries
        return @{ status = "embedded"; model = [string]$v.model }
    }
    catch {
        [Console]::Error.WriteLine("register embed hook failed (registration unaffected; embed-backfill can retry): $($_.Exception.Message)")
        return @{ status = "failed"; reason = "$($_.Exception.Message)" }
    }
}

# === JSON IO ===

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
    # a ConvertFrom-Json PSCustomObject (PS 5.1 deadlocks on that).
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

# === Promotion primitive (hot -> persistent index) ===
# Pure index-entry move: the artifact md files are shared, nothing moves on
# disk. Order is: write index.json FIRST, then clear hot.json. An interrupted
# promote leaves the entry in both zones, healed by dedupe-replace on the next
# promote and by same-key/path suppression on every merged read.

function Invoke-Promote {
    param([array]$HotEntries, [array]$RemainingHot)

    $promoteKeys = @{}
    $promotePaths = @{}
    foreach ($e in $HotEntries) {
        $promoteKeys[[string]$e.key] = $true
        $promotePaths[(Get-PathIdentity ([string]$e.path))] = $true
    }

    $index = Read-Index
    $kept = @()
    foreach ($e in $index) {
        if ($promoteKeys.ContainsKey([string]$e.key)) { continue }
        if ($promotePaths.ContainsKey((Get-PathIdentity ([string]$e.path)))) { continue }
        $kept += $e
    }
    foreach ($e in $HotEntries) {
        # Promote AS-IS; registeredAt is hot-zone bookkeeping only.
        $kept += @{
            key   = $e.key
            tags  = @(Convert-ToTagsArray $e.tags)
            brief = $e.brief
            path  = $e.path
            files = (Convert-ToFilesHashtable $e.files)
        }
    }

    Write-Index -Entries $kept
    Write-Hot -Entries $RemainingHot
}

# Sweep: promote hot entries whose retention window expired, then shed
# overflow beyond capacity (oldest first). $Reserve reserves one slot for an
# incoming register so the write itself never overflows.
# Returns the number of promoted entries. Throws on IO/parse failure — the
# CALLER decides whether to continue (register warns and continues).

function Invoke-HotSweep {
    param([int]$Reserve = 0)

    $hot = @(Read-Hot)
    if ($hot.Count -eq 0) { return 0 }

    $cutoff = [datetime]::UtcNow.AddDays(-$HotRetentionDays)
    $sorted = @($hot | Sort-Object -Property @{ Expression = { Get-HotTimestamp $_.registeredAt } })
    $promote = @()
    $remaining = @()
    foreach ($e in $sorted) {
        if ((Get-HotTimestamp $e.registeredAt) -lt $cutoff) { $promote += $e }
        else { $remaining += $e }
    }

    $limit = $HotCapacity - $Reserve
    while ($remaining.Count -gt $limit) {
        $promote += $remaining[0]
        if ($remaining.Count -eq 1) { $remaining = @() }
        else { $remaining = @($remaining | Select-Object -Skip 1) }
    }

    if ($promote.Count -gt 0) {
        Invoke-Promote -HotEntries $promote -RemainingHot $remaining
    }
    return $promote.Count
}

function Write-SweepWarning {
    param([string]$Cause)
    [Console]::Error.WriteLine("hot-zone sweep failed (caller proceeds; the next sweep retries idempotently): $Cause")
}

# === Input validation ===

if ([string]::IsNullOrWhiteSpace($Type)) {
    Write-ErrorResult "MISSING_TYPE" "-Type is required. Valid values: register, persist, embed-backfill" 1
}
if ($Type -notin @("register", "persist", "embed-backfill")) {
    Write-ErrorResult "INVALID_TYPE" "Unknown type: '$Type'. Valid values: register, persist, embed-backfill" 1
}

# === Type: register (write the hot zone) ===

if ($Type -eq "register") {
    if ([string]::IsNullOrWhiteSpace($Key))   { Write-ErrorResult "MISSING_KEY"   "-Key is required for register" 1 }
    if ([string]::IsNullOrWhiteSpace($Path))  { Write-ErrorResult "MISSING_PATH"  "-Path is required (artifact path, repo-relative)" 1 }
    if ([string]::IsNullOrWhiteSpace($Brief)) { Write-ErrorResult "MISSING_BRIEF" "-Brief is required (one-line summary)" 1 }

    $artifactAbs = Resolve-RepoPath $Path
    if (-not (Test-Path -LiteralPath $artifactAbs -PathType Leaf)) {
        Write-ErrorResult "ARTIFACT_NOT_FOUND" "Artifact file not found: $Path (resolved: $artifactAbs)" 1
    }
    $normPath = Get-NormalizedRelPath $artifactAbs

    # The paired summary file ({slug}.summary.md) MUST exist before registering.
    $summaryRel = Get-SummaryPath $normPath
    $summaryAbs = Resolve-RepoPath $summaryRel
    if (-not (Test-Path -LiteralPath $summaryAbs -PathType Leaf)) {
        Write-ErrorResult "SUMMARY_NOT_FOUND" "Paired summary file not found. Expected: $summaryRel (full record and summary must be written together)." 1
    }

    $tagList = Convert-ToTagsArray $Tags
    if ($tagList.Count -eq 0) {
        Write-ErrorResult "MISSING_TAGS" "-Tags is required (comma-separated module/feature/synonym keywords, Chinese and English)." 1
    }

    $fileList = @()
    if (-not [string]::IsNullOrWhiteSpace($Files)) {
        $fileList = ($Files -split "[,;]") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    }

    $filesMap = @{}
    foreach ($relFile in $fileList) {
        $absFile = Resolve-RepoPath $relFile
        $hash = Get-FileSha256 -AbsPath $absFile
        if ($null -eq $hash) {
            Write-ErrorResult "REGISTER_FILE_NOT_FOUND" "Cannot hash file (not found): $relFile" 1
        }
        $filesMap[(Get-NormalizedRelPath $absFile)] = $hash
    }

    # Sweep before the write (reserving one slot for this entry). Failure must
    # not block register: the hot write below is what guarantees no loss.
    $sweptCount = 0
    try { $sweptCount = Invoke-HotSweep -Reserve 1 }
    catch { Write-SweepWarning $_.Exception.Message }

    # Dedupe ONLY within the hot zone (by key or artifact identity). Same-key
    # entries in index.json stay untouched: the hot view shadows them in
    # retrieval, and promotion's dedupe-replace reconciles the index later.
    $newIdentity = Get-PathIdentity $normPath
    $hot = @(Read-Hot)
    $kept = @()
    foreach ($e in $hot) {
        if ([string]$e.key -eq $Key) { continue }
        if ((Get-PathIdentity ([string]$e.path)) -eq $newIdentity) { continue }
        $kept += $e
    }

    $registeredAt = (Get-Date).ToUniversalTime().ToString("o")
    $kept += @{
        key          = $Key
        tags         = $tagList
        brief        = $Brief
        path         = $normPath
        files        = $filesMap
        registeredAt = $registeredAt
    }
    Write-Hot -Entries $kept

    # Synchronous single-entry embed (frozen write-side hook): only when the
    # vector config is complete; any failure warns without blocking — the hot
    # write above already guaranteed "register is visible".
    $embedMeta = Invoke-RegisterEmbedHook -Key $Key -Tags $tagList -Brief $Brief

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            registered   = $true
            zone         = "hot"
            key          = $Key
            path         = $normPath
            summaryPath  = $summaryRel
            tagsCount    = $tagList.Count
            filesCount   = $fileList.Count
            registeredAt = $registeredAt
            sweptToIndex = $sweptCount
            embed        = $embedMeta
        }
    } -Depth 4
    exit 0
}

# === Type: persist (promote one hot entry into index.json) ===

if ($Type -eq "persist") {
    if ([string]::IsNullOrWhiteSpace($Key)) {
        Write-ErrorResult "MISSING_KEY" "-Key is required for persist (the hot-zone entry to promote)" 1
    }

    $hot = @(Read-Hot)
    $target = $null
    foreach ($e in $hot) {
        if ([string]$e.key -eq $Key) { $target = $e; break }
    }
    if ($null -eq $target) {
        Write-ErrorResult "HOT_KEY_NOT_FOUND" "No hot-zone entry with key '$Key' in .rdd/exploration/hot.json. Already persisted, or never registered." 1
    }

    $remaining = @()
    foreach ($e in $hot) {
        if ([object]::ReferenceEquals($e, $target)) { continue }
        $remaining += $e
    }

    Invoke-Promote -HotEntries @($target) -RemainingHot $remaining

    try { $null = Invoke-HotSweep -Reserve 0 }
    catch { Write-SweepWarning $_.Exception.Message }

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            persisted   = $true
            key         = $target.key
            path        = $target.path
            summaryPath = (Get-SummaryPath ([string]$target.path))
        }
    } -Depth 4
    exit 0
}

# === Type: embed-backfill (one-shot vector migration / maintenance) ===
# Recomputes missing vectors for every FRESH merged entry under the CURRENT
# configured model. The (key, textHash, model) primary key means: content or
# model change => missing => re-embedded; untouched entries report reused.
# -PurgeOtherModels additionally drops every OTHER model's sidecar entries.
# Requires the complete vector embed config (endpoint/model/dimensions +
# RDD_EMBED_APIKEY) — an explicit maintenance command fails loud instead of
# silently doing nothing.

if ($Type -eq "embed-backfill") {
    $v = Read-EmbedVectorConfig
    $check = Test-EmbedVectorConfig -V $v
    if (-not $check.Complete) {
        Write-ErrorResult "EMBED_CONFIG_INCOMPLETE" "embed-backfill requires a complete vector config (missing: $($check.Missing -join ', ')). Set recallers.vector.endpoint/model/dimensions in .rdd/exploration/search-config.json and export RDD_EMBED_APIKEY." 1
    }

    $purged = 0
    if ($PurgeOtherModels) {
        $sidecar = @(Read-VectorsSidecar)
        $keptVectors = @()
        foreach ($e in $sidecar) {
            if ([string]$e.model -eq [string]$v.model) { $keptVectors += $e }
            else { $purged++ }
        }
        Write-VectorsSidecar -Entries $keptVectors
    }

    # Fresh merged pool (hot first, same-key/same-artifact suppression) — the
    # same view the read face serves, without zone eviction side effects.
    $hotFresh = @()
    foreach ($e in @(Read-Hot)) {
        if (Test-EntryFresh -Entry $e) { $hotFresh += $e }
    }
    $hotFresh = @($hotFresh | Sort-Object -Descending -Property @{ Expression = { Get-HotTimestamp $_.registeredAt } })
    $hotKeys = @{}
    $hotIdentities = @{}
    $merged = @()
    foreach ($e in $hotFresh) {
        $hotKeys[[string]$e.key] = $true
        $hotIdentities[(Get-PathIdentity ([string]$e.path))] = $true
        $merged += $e
    }
    foreach ($e in @(Read-Index)) {
        if ($hotKeys.ContainsKey([string]$e.key)) { continue }
        if ($hotIdentities.ContainsKey((Get-PathIdentity ([string]$e.path)))) { continue }
        if (-not (Test-EntryFresh -Entry $e)) { continue }
        $merged += $e
    }

    $entries = @(Read-VectorsSidecar)
    $embeddedCount = 0
    $reusedCount = 0
    $failures = @()
    foreach ($e in $merged) {
        $key = [string]$e.key
        # NOT `$tags`: the script-level param block declares [string]$Tags and
        # PowerShell variable names are case-insensitive — assigning an array
        # to it would silently coerce to a space-joined ($OFS) string.
        $entryTags = @(Convert-ToTagsArray $e.tags)
        $text = Get-EmbedSearchText -Key $key -Tags $entryTags -Brief ([string]$e.brief)
        $hash = Get-EmbedTextHash $text
        if ($null -ne (Find-VectorsSidecarEntry -Entries $entries -Key $key -TextHash $hash -Model ([string]$v.model))) {
            $reusedCount++
            continue
        }
        try {
            $vectors = @(Invoke-EmbedApi -V $v -Texts @($text))
            $entries = Add-VectorsSidecarEntry -Entries $entries -Key $key -TextHash $hash -Model ([string]$v.model) -Vector ([double[]]$vectors[0])
            $embeddedCount++
        }
        catch {
            $failures += @{ key = $key; error = "$($_.Exception.Message)" }
        }
    }
    if ($embeddedCount -gt 0) {
        Write-VectorsSidecar -Entries $entries
    }

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            model    = [string]$v.model
            purged   = $purged
            embedded = $embeddedCount
            reused   = $reusedCount
            failed   = @($failures)
        }
    } -Depth 4
    exit 0
}

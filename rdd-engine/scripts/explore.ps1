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

# === Output encoding ===
# Emit pure-ASCII JSON so any caller (PowerShell, cmd, bash, opencode, Claude)
# decodes it identically regardless of console codepage. Non-ASCII chars are
# escaped to \uXXXX; surrogate pairs are emitted as \uD83D\uDE00 style which is
# valid JSON.

function Escape-NonAscii {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -gt 127) {
            [void]$sb.Append('\u' + $code.ToString('x4'))
        }
        else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function ConvertTo-PortableJson {
    param($Object, [int]$Depth = 6)
    return (Escape-NonAscii ($Object | ConvertTo-Json -Depth $Depth -Compress))
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
function Get-ArtifactsDir   { Join-Path (Get-ExplorationDir) "artifacts" }

function Resolve-RepoPath {
    param([string]$RelOrAbs)
    if ([string]::IsNullOrWhiteSpace($RelOrAbs)) { return $RelOrAbs }
    if ([System.IO.Path]::IsPathRooted($RelOrAbs)) { return $RelOrAbs }
    return (Join-Path $repoRoot $RelOrAbs)
}

function Get-NormalizedRelPath {
    param([string]$AbsPath)
    $full = (Resolve-Path -LiteralPath $AbsPath).Path
    $root = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
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

# === Index IO ===

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

# === Fresh-candidate selection ===
# Returns fresh entries (SHA-256 still valid + artifact file present).
# Stale entries (hash mismatch / file deleted) are reported for index cleanup.
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

# === Dispatch prompt (always returned for caller LLM to use on no-match) ===

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
        "  rdd-engine/scripts/explore.cmd -Type register -Key `"<semantic key, Chinese ok>`" -Tags `"<comma-separated module/feature/synonym keywords, Chinese and English>`" -Path `"<repo-relative FULL record path>`" -Brief `"<one-line summary>`" -Files `"<comma-separated repo-relative file paths>`"",
        "Note: the full record and its paired summary ({slug}.summary.md) must both be written before registering.",
        "",
        "--- exploration-guide.md ---",
        $guide
    ) -join [System.Environment]::NewLine)
}

# === Input validation ===

if ([string]::IsNullOrWhiteSpace($Type)) {
    Write-ErrorResult "MISSING_TYPE" "-Type is required. Valid values: explore, register" 1
}
if ($Type -notin @("explore", "register")) {
    Write-ErrorResult "INVALID_TYPE" "Unknown type: '$Type'. Valid values: explore, register" 1
}

# === Type: explore ===
# Returns ALL fresh candidates (SHA-256 valid). The caller LLM inspects
# tags + brief to decide relevance itself. Semantic matching is NOT done here.

if ($Type -eq "explore") {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-ErrorResult "MISSING_QUERY" "-Query is required and cannot be empty" 1
    }

    $entries = Read-Index
    $result = Select-FreshEntries -Entries $entries
    $freshEntries = $result.Fresh
    $stalePaths = $result.StalePaths

    # Clean up stale entries so the index stays fresh.
    if ($stalePaths.Count -gt 0) {
        $kept = @()
        foreach ($e in $entries) {
            if ($stalePaths -notcontains $e.path) { $kept += $e }
        }
        Write-Index -Entries $kept
    }

    # Build candidate snapshot for the caller LLM.
    $candidates = @()
    foreach ($entry in $freshEntries) {
        $candidates += @{
            key         = $entry.key
            tags        = @(Convert-ToTagsArray $entry.tags)
            brief       = $entry.brief
            summaryPath = (Get-SummaryPath $entry.path)
            fullPath    = $entry.path
        }
    }

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            query         = $Query
            candidates    = $candidates
            staleRemoved  = $stalePaths.Count
            dispatchPrompt = (Build-DispatchPrompt -QueryText $Query)
        }
    } -Depth 6
    exit 0
}

# === Type: register ===

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

    $entries = Read-Index
    $kept = @()
    foreach ($e in $entries) {
        if ($e.key -eq $Key -or $e.path -eq $normPath) { continue }
        $kept += $e
    }
    $kept += @{
        key   = $Key
        tags  = $tagList
        brief = $Brief
        path  = $normPath
        files = $filesMap
    }

    Write-Index -Entries $kept

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            registered  = $true
            key         = $Key
            path        = $normPath
            summaryPath = $summaryRel
            tagsCount   = $tagList.Count
            filesCount  = $fileList.Count
        }
    } -Depth 4
    exit 0
}

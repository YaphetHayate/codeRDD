[CmdletBinding()]
param(
    [string]$Type,
    [string]$Query,
    [string]$Key,
    [string]$Path,
    [string]$Brief,
    [string]$Files
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$scriptRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scriptRoot "../..")).Path

# Jaccard token-overlap threshold. Query must share at least this fraction of
# tokens with an entry.key to be considered a cache hit candidate.
$MatchThreshold = 0.35

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

# === Tokenizer: CJK per-char + Latin alphanumeric words ===

function Get-Tokens {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $lower = $Text.ToLowerInvariant()
    $set = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($ch in $lower.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x4E00 -and $code -le 0x9FFF) -or
            ($code -ge 0x3400 -and $code -le 0x4DBF)) {
            [void]$set.Add($ch.ToString())
        }
    }
    foreach ($m in [regex]::Matches($lower, '[a-z0-9]+')) {
        [void]$set.Add($m.Value)
    }
    return @($set)
}

function Get-JaccardSimilarity {
    param([string]$A, [string]$B)
    $ta = Get-Tokens $A
    $tb = Get-Tokens $B
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }

    $setB = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $tb) { [void]$setB.Add($t) }

    $inter = 0
    foreach ($t in $ta) {
        if ($setB.Contains($t)) { $inter++ }
    }
    $union = $ta.Count + $tb.Count - $inter
    if ($union -le 0) { return 0.0 }
    return [double]$inter / [double]$union
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
            path  = $e.path
            brief = $e.brief
            files = (Convert-ToFilesHashtable $e.files)
        }
    }
    $payload = @{ entries = $clean } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText((Get-IndexPath), $payload, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-EntryByPath {
    param([array]$Entries, [string]$Path)
    $kept = @()
    foreach ($e in $Entries) {
        if ($e.path -ne $Path) { $kept += $e }
    }
    return $kept
}

# === Dispatch prompt (cache miss) ===

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
        "  rdd-engine/scripts/explore.cmd -Type register -Key `"<semantic key, Chinese ok>`" -Path `"<repo-relative artifact path>`" -Brief `"<one-line summary>`" -Files `"<comma-separated repo-relative file paths>`"",
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

if ($Type -eq "explore") {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-ErrorResult "MISSING_QUERY" "-Query is required and cannot be empty" 1
    }

    $entries = Read-Index

    $bestEntry = $null
    $bestScore = 0.0
    foreach ($entry in $entries) {
        $score = Get-JaccardSimilarity -A $Query -B $entry.key
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestEntry = $entry
        }
    }

    if ($bestEntry -and $bestScore -ge $MatchThreshold) {
        $stale = $false
        $bestFiles = Convert-ToFilesHashtable $bestEntry.files
        foreach ($k in $bestFiles.Keys) {
            $current = Get-FileSha256 -AbsPath (Resolve-RepoPath $k)
            if ($null -eq $current -or $current -ne $bestFiles[$k]) {
                $stale = $true
                break
            }
        }

        if (-not $stale) {
            $artifactAbs = Resolve-RepoPath $bestEntry.path
            if (Test-Path -LiteralPath $artifactAbs -PathType Leaf) {
                $content = [System.IO.File]::ReadAllText($artifactAbs, [System.Text.Encoding]::UTF8)
                $filesOut = Convert-ToFilesHashtable $bestEntry.files
                ConvertTo-PortableJson @{
                    success = $true
                    data    = @{
                        cache      = "hit"
                        key        = $bestEntry.key
                        path       = $bestEntry.path
                        brief      = $bestEntry.brief
                        files      = $filesOut
                        matchScore = $bestScore
                        artifact   = $content
                    }
                }
                exit 0
            }
            $stale = $true
        }

        if ($stale) {
            Write-Index -Entries (Remove-EntryByPath -Entries $entries -Path $bestEntry.path)
        }
    }

    # cache miss -> dispatch
    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            cache        = "miss"
            action       = "dispatch-subagent"
            subagentHint = "rdd-explore"
            query        = $Query
            matchScore   = $bestScore
            prompt       = (Build-DispatchPrompt -QueryText $Query)
        }
    }
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
        path  = $normPath
        brief = $Brief
        files = $filesMap
    }

    Write-Index -Entries $kept

    ConvertTo-PortableJson @{
        success = $true
        data    = @{
            registered = $true
            key        = $Key
            path       = $normPath
            filesCount = $fileList.Count
        }
    }
    exit 0
}

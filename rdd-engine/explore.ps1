[CmdletBinding()]
param(
    [string]$Type,
    [string]$Query
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

filter Write-ResultJson {
    $_ | ConvertTo-Json -Depth 6 -Compress
}

function Write-ErrorResult {
    param(
        [string]$Code,
        [string]$Message,
        [int]$ExitCode = 1
    )
    @{
        success = $false
        error   = @{
            code    = $Code
            message = $Message
        }
    } | ConvertTo-Json -Depth 3 -Compress
    exit $ExitCode
}

# === Input validation ===

if ([string]::IsNullOrWhiteSpace($Type)) {
    Write-ErrorResult "MISSING_TYPE" "-Type is required. Valid value: explore" 1
}

$validTypes = @("explore")
if ($validTypes -notcontains $Type) {
    Write-ErrorResult "INVALID_TYPE" "Unknown type: '$Type'. Valid value: explore" 1
}

if ([string]::IsNullOrWhiteSpace($Query)) {
    Write-ErrorResult "MISSING_QUERY" "-Query is required and cannot be empty" 1
}

# === Reference file mapping ===

$referenceMap = @{
    "explore" = @{
        files         = @("references/exploration-guide.md")
        subagentType  = "explore"
        outputTarget  = ".rdd/exploration/"
        description   = "Code exploration with global cache: check index.json for existing artifacts, verify file freshness via SHA-256, return cached or generate new"
    }
}

$config = $referenceMap[$Type]

# === Validate reference files exist ===

$resolvedFiles = @()
foreach ($relPath in $config.files) {
    $absPath = Join-Path $scriptRoot $relPath
    if (-not (Test-Path -LiteralPath $absPath)) {
        Write-ErrorResult "REFERENCE_NOT_FOUND" "Reference file not found: $relPath (expected at $absPath)" 2
    }
    $resolvedFiles += $absPath
}

# === Read reference file contents ===

$referenceContents = @{}
foreach ($file in $resolvedFiles) {
    $filename = Split-Path -Leaf $file
    $referenceContents[$filename] = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
}

# === Build sub-agent prompt ===

$promptLines = @(
    "You are an rdd-engine sub-agent. Complete the following delegated task.",
    "",
    "Task type: $($config.description)",
    "",
    "User request:",
    $Query,
    "",
    "Reference guides below. Follow their workflows and templates strictly:",
    ""
)

foreach ($file in $resolvedFiles) {
    $filename = Split-Path -Leaf $file
    $promptLines += "--- $filename ---"
    $promptLines += $referenceContents[$filename]
    $promptLines += ""
}

$prompt = $promptLines -join [System.Environment]::NewLine

# === Dispatch to sub-agent ===

$result = @{
    success = $true
    data    = @{
        subagentType = $config.subagentType
        instructions = @{
            prompt          = $prompt
            referenceFiles  = $resolvedFiles
            outputTarget    = $config.outputTarget
        }
    }
}
$result | ConvertTo-Json -Depth 6 -Compress
exit 0

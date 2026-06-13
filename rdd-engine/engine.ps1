[CmdletBinding()]
param(
    [string]$Type,
    [string]$Query,
    [string]$Mode = "dispatch"
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
    Write-ErrorResult "MISSING_TYPE" "-Type is required. Valid values: context, skills, tools" 1
}

$validTypes = @("context", "skills", "tools", "explore")
if ($validTypes -notcontains $Type) {
    Write-ErrorResult "INVALID_TYPE" "Unknown type: '$Type'. Valid values: context, skills, tools" 1
}

if ([string]::IsNullOrWhiteSpace($Query)) {
    Write-ErrorResult "MISSING_QUERY" "-Query is required and cannot be empty" 1
}

$validModes = @("dispatch", "direct")
if ($validModes -notcontains $Mode) {
    Write-ErrorResult "INVALID_MODE" "Unknown mode: '$Mode'. Valid values: dispatch, direct" 1
}

# === Reference file mapping ===

$referenceMap = @{
    "context" = @{
        files         = @("references/context-guide.md", "references/artifact-template.md")
        subagentType  = "explore"
        outputTarget  = ".rdd/context/"
        description   = "Project context generation: sample code, analyze style/structure/glossary, generate .rdd/context/ artifacts"
    }
    "skills" = @{
        files         = @("skill-registry.md")
        subagentType  = "general"
        outputTarget  = "stdout"
        description   = "Skill discovery: match domain skills from skill-registry by keyword"
    }
    "tools" = @{
        files         = @()
        subagentType  = "general"
        outputTarget  = "stdout"
        description   = "Project tools: delegate general project-level tasks to sub-agent"
    }
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

# === Execute by mode ===

switch ($Mode) {
    "dispatch" {
        $result = @{
            success = $true
            data    = @{
                mode         = "dispatch"
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
    }
    "direct" {
        Write-ErrorResult "SUB_AGENT_FAILED" "Direct mode not yet implemented: opencode CLI/API interface is not available" 3
    }
}

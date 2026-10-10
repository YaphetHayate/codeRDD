<#
.SYNOPSIS
    Batch-update every coderdd-managed target project from this source repo.

.DESCRIPTION
    Runs the coderdd CLI update in every managed project so a fresh source
    build reaches all targets in one shot:

      source repo:  git pull && npm run build:local
      this script:  updates ALL target projects (what `coderdd update .`
                    does per project, without the per-project legwork)

    Target resolution:
      - explicit -Projects list wins (comma-separated or repeated);
      - otherwise depth-1 discovery under -Root (default: this repo's parent
        directory) of subdirectories carrying .rdd\install.json;
      - the codeRDD source repo itself is always excluded.

    The CLI is invoked as `node <repo>\bin\coderdd.js update <target>` on
    purpose: it always runs THIS repo's dist/ build, so a stale global
    `coderdd` link (repo moved / re-registered elsewhere) can never leak an
    old version into the update. Requires `npm run build:local` to have run
    at least once (dist/ present).

.PARAMETER Projects
    Explicit target project roots. Skips discovery when given.

.PARAMETER Root
    Discovery root for the auto-scan mode. Default: parent of this repo.

.PARAMETER Depth
    Discovery recursion depth under -Root. Default 3 (covers nested layouts
    like <root>\demo\<vendor>\<project>). Depth 1 = the old siblings-only scan.

.PARAMETER ListOnly
    Print the resolved target list without updating anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\update-projects.ps1

    Auto-discover and update every managed sibling project.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\update-projects.ps1 -Projects D:\projA,D:\projB

    Update an explicit list only.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\update-projects.ps1 -ListOnly

    Show what auto-discovery would touch.

.NOTES
    Exit codes: 0 = all targets updated (or listed); 1 = any target failed
    (missing manifest, CLI error). Runtime data (.rdd/tips, exploration,
    handoff, ...) is never touched - `coderdd update` only rewrites the
    install-managed files recorded in .rdd\install.json.
#>
[CmdletBinding()]
param(
    [string[]]$Projects = @(),
    [string]$Root,
    [int]$Depth = 3,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$repoRoot = Split-Path -Parent $PSScriptRoot

function Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Resolve-TargetProjects {
    # Explicit -Projects wins; otherwise discovery under -Root (default: the
    # repo's parent dir), -Depth levels deep, for dirs carrying
    # .rdd\install.json. Junk trees (node_modules / VCS / python caches) are
    # pruned and access-denied dirs skipped silently (foreign-tree noise).
    # The codeRDD source repo itself is always excluded.
    if ($Projects.Count -gt 0) { return $Projects }
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $repoRoot }
    $prune = 'node_modules|\.git($|\\)|\.pytest_cache|__pycache__|\.venv|\\dist($|\\)'
    $found = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Depth $Depth -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -ne $repoRoot -and $_.FullName -notmatch $prune -and (Test-Path -LiteralPath (Join-Path $_.FullName '.rdd\install.json') -PathType Leaf)
    })
    return @($found | ForEach-Object { $_.FullName })
}

# --- 1. Resolve the CLI (always THIS repo's build; never a stale global link) ---
$cli = Join-Path $repoRoot 'bin\coderdd.js'
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
    Fail "coderdd CLI missing: $cli - run 'npm run build:local' in the source repo first"
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Fail "node not on PATH (>= 18 required)"
}

# --- 2. Resolve targets ---
$targets = Resolve-TargetProjects
if ($targets.Count -eq 0) {
    Fail "no coderdd-managed projects found (depth-1 scan for .rdd\install.json; pass -Projects <path,...> to list them explicitly)"
}

# --- 3. Update each target (manifest check keeps unmanaged dirs fail-loud) ---
$ok = 0
$failed = @()
foreach ($target in $targets) {
    $resolved = $target
    if (Test-Path -LiteralPath $target) { $resolved = (Resolve-Path -LiteralPath $target).Path }
    if (-not (Test-Path -LiteralPath (Join-Path $resolved '.rdd\install.json') -PathType Leaf)) {
        Write-Host "[SKIP] $resolved - no .rdd\install.json (not coderdd-managed? run 'coderdd init .' there first)" -ForegroundColor Yellow
        $failed += $resolved
        continue
    }
    if ($ListOnly) { Write-Host "[LIST] $resolved"; continue }
    Write-Host "=== update: $resolved"
    & node $cli update $resolved
    if ($LASTEXITCODE -eq 0) { $ok++ } else { $failed += $resolved }
}

# --- 4. Summary ---
if ($ListOnly) {
    Write-Host ("discovered: {0} project(s)" -f $targets.Count)
    exit 0
}
Write-Host ("--- updated: {0}/{1}  failed: {2}" -f $ok, $targets.Count, $failed.Count) 
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host "  failed: $_" -ForegroundColor Red }
    exit 1
}
exit 0

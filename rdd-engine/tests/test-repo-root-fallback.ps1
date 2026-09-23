# repo-root location chain acceptance tests (git-optional engine)
# Validates the frozen Resolve-RepoRoot mirror (five-level chain: env -> git ->
# .git ancestor -> .rdd/install.json ancestor -> cwd) in three layers:
#   1. mirror invariants   identical function text across the 8 data-plane
#                          scripts + exactly one `git rev-parse` per script
#   2. chain semantics     extracted function under controlled cwd / env / PATH
#   3. end-to-end          rdd-flow / explore run under Windows PowerShell 5.1
#                          inside NON-git trees (data plane previously died there)
# Exit code 0 = all green.
#
# Usage: powershell -File test-repo-root-fallback.ps1   (or via pwsh tool)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptsDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$FlowPs1    = Join-Path $ScriptsDir 'rdd-flow.ps1'
$ExplorePs1 = Join-Path $ScriptsDir 'explore.ps1'
$Work       = Join-Path $env:TEMP ('repo-root-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$MirrorFiles = @(
    'rdd-flow.ps1', 'explore.ps1', 'explore-store.ps1', 'goal-tree.ps1',
    'goal-tree-leaf.ps1', 'delivery-bridge.ps1', 'start-role.ps1', 'sync-ux-subagents.ps1'
)

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Normalize-DirPath { param([string]$P)
    return ([System.IO.Path]::GetFullPath($P)).TrimEnd('\', '/')
}

# Extract the Resolve-RepoRoot function body (from `function Resolve-RepoRoot {`
# to the first column-0 closing brace — inner braces are always indented).
function Get-RepoRootFnRange {
    param([string]$Path)
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^function Resolve-RepoRoot \{') { $start = $i; break }
    }
    if ($start -lt 0) { throw "Resolve-RepoRoot not found in $Path" }
    $end = $start
    for ($i = $start; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\}$') { $end = $i; break }
    }
    return @($start, $end)
}

function Get-RepoRootFnText {
    param([string]$Path)
    $r = Get-RepoRootFnRange $Path
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    return (($lines[$r[0]..$r[1]]) -join "`n")
}

function Invoke-Script { param([string]$Ps1, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Ps1) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null

try {
    # ===== layer 1: mirror invariants =====
    $canonical = Get-RepoRootFnText (Join-Path $ScriptsDir 'rdd-flow.ps1')
    Assert-True ($canonical -match '^function Resolve-RepoRoot \{') 'canonical extract parses (rdd-flow.ps1)'
    foreach ($f in $MirrorFiles) {
        $p = Join-Path $ScriptsDir $f
        $t = Get-RepoRootFnText $p
        Assert-True ($t -ceq $canonical) "mirror identical: $f"
        # no executable rev-parse OUTSIDE the chain (comment mentions are fine —
        # the pre-existing explore.ps1 path-normalization comment keeps one)
        $r = Get-RepoRootFnRange $p
        $lines = Get-Content -LiteralPath $p -Encoding UTF8
        $stray = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -ge $r[0] -and $i -le $r[1]) { continue }
            if ($lines[$i] -match '^\s*#') { continue }
            if ($lines[$i] -match 'git rev-parse --show-toplevel') { $stray++ }
        }
        Assert-True ($stray -eq 0) "no rev-parse outside the chain: $f" ("stray: $stray")
    }

    # ===== layer 2: chain semantics (extracted function, in-process) =====
    Invoke-Expression $canonical

    # fixture trees (git-dependent setup FIRST, before any PATH stripping)
    $repoA = Join-Path $Work 'repoA'
    New-Item -ItemType Directory -Path (Join-Path $repoA 'sub\deep') -Force | Out-Null
    Push-Location $repoA
    try { git init -q 2>$null | Out-Null } finally { Pop-Location }

    $plainRoot = Join-Path $Work 'plainroot'
    New-Item -ItemType Directory -Path (Join-Path $plainRoot 'a\b') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $plainRoot '.rdd') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $plainRoot '.rdd\install.json') @'
{
  "version": "test"
}
'@

    $noMarker = Join-Path $Work 'nomarker\x'
    New-Item -ItemType Directory -Path $noMarker -Force | Out-Null

    $savedPath = $env:Path

    # (2) git repo, deep subdir, git available -> repo root
    Push-Location (Join-Path $repoA 'sub\deep')
    try {
        $got = Resolve-RepoRoot
        Assert-True ((Normalize-DirPath $got) -eq (Normalize-DirPath $repoA)) 'chain (2): git repo + deep subdir -> repo root' ("got: $got")
    } finally { Pop-Location }

    # (3) same tree, git binary unreachable -> .git ancestor twin
    Push-Location (Join-Path $repoA 'sub\deep')
    try {
        $env:Path = $env:windir
        $got = Resolve-RepoRoot
        Assert-True ((Normalize-DirPath $got) -eq (Normalize-DirPath $repoA)) 'chain (3): no git binary -> nearest .git ancestor' ("got: $got")
    } finally { $env:Path = $savedPath; Pop-Location }

    # (4) non-git tree + install.json anchor, deep subdir, git unreachable -> install root
    Push-Location (Join-Path $plainRoot 'a\b')
    try {
        $env:Path = $env:windir
        $got = Resolve-RepoRoot
        Assert-True ((Normalize-DirPath $got) -eq (Normalize-DirPath $plainRoot)) 'chain (4): non-git tree -> .rdd/install.json ancestor' ("got: $got")
    } finally { $env:Path = $savedPath; Pop-Location }

    # (5) no markers anywhere -> cwd fallback
    Push-Location $noMarker
    try {
        $env:Path = $env:windir
        $got = Resolve-RepoRoot
        Assert-True ((Normalize-DirPath $got) -eq (Normalize-DirPath $noMarker)) 'chain (5): no markers -> cwd fallback' ("got: $got")
    } finally { $env:Path = $savedPath; Pop-Location }

    # (1) valid env override beats git
    Push-Location (Join-Path $repoA 'sub\deep')
    try {
        $env:RDD_PROJECT_ROOT = $plainRoot
        $got = Resolve-RepoRoot
        Assert-True ((Normalize-DirPath $got) -eq (Normalize-DirPath $plainRoot)) 'chain (1): RDD_PROJECT_ROOT beats git repo' ("got: $got")
    } finally { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue; Pop-Location }

    # (1) invalid env override -> fail-loud
    $threw = $false
    try { $env:RDD_PROJECT_ROOT = 'Z:\definitely-not-here-' + [guid]::NewGuid().ToString('N'); Resolve-RepoRoot | Out-Null }
    catch { $threw = $true }
    finally { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue }
    Assert-True $threw 'chain (1): invalid RDD_PROJECT_ROOT fails loud'

    # ===== layer 3: end-to-end under PS 5.1 in NON-git trees =====
    $rootNG = Join-Path $Work 'ngproject'
    $ArchiveRel = '.rdd/changes/archive/ng-fix'
    New-Item -ItemType Directory -Path (Join-Path $rootNG ($ArchiveRel + '/requirements')) -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rootNG '.rdd') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $rootNG '.rdd\install.json') @'
{
  "version": "test"
}
'@
    Write-Utf8NoBom (Join-Path $rootNG ($ArchiveRel + '/requirements/a.md')) @'
# Test requirement A

- **Desc**: non-git project fixture
'@
    Write-Utf8NoBom (Join-Path $rootNG ($ArchiveRel + '/tasks-init.json')) @'
[
  { "title": "non-git main line", "requirement": "requirements/a.md", "currentOwners": ["DEV"], "designDocs": [] }
]
'@

    # G: init from non-git project root (git present on PATH but not a repo)
    Push-Location $rootNG
    try {
        $r = Invoke-Script $FlowPs1 @('-Command', 'init', '-Archive', $ArchiveRel, '-TasksFile', ($ArchiveRel + '/tasks-init.json'))
        Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.taskCount -eq 1) 'e2e G: rdd-flow init works in non-git project'
        Assert-True (Test-Path -LiteralPath (Join-Path $rootNG ($ArchiveRel + '/task.json'))) 'e2e G: task.json written under project root'
    } finally { Pop-Location }

    # H: init from a deep SUBDIRECTORY anchors back onto the install root
    $rootNG2 = Join-Path $Work 'ngproject2'
    New-Item -ItemType Directory -Path (Join-Path $rootNG2 ($ArchiveRel + '/requirements')) -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rootNG2 'nested\deep') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rootNG2 '.rdd') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $rootNG2 '.rdd\install.json') @'
{
  "version": "test"
}
'@
    Write-Utf8NoBom (Join-Path $rootNG2 ($ArchiveRel + '/requirements/a.md')) @'
# Test requirement A

- **Desc**: subdirectory anchoring fixture
'@
    Write-Utf8NoBom (Join-Path $rootNG2 ($ArchiveRel + '/tasks-init.json')) @'
[
  { "title": "subdir anchoring", "requirement": "requirements/a.md", "currentOwners": ["DEV"], "designDocs": [] }
]
'@
    Push-Location (Join-Path $rootNG2 'nested\deep')
    try {
        $r = Invoke-Script $FlowPs1 @('-Command', 'init', '-Archive', $ArchiveRel, '-TasksFile', ($ArchiveRel + '/tasks-init.json'))
        Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.taskCount -eq 1) 'e2e H: init from subdirectory succeeds'
        Assert-True (Test-Path -LiteralPath (Join-Path $rootNG2 ($ArchiveRel + '/task.json'))) 'e2e H: archive resolved against install root, not cwd'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $rootNG2 'nested\deep\.rdd'))) 'e2e H: no .rdd stray under the subdirectory'
    } finally { Pop-Location }

    # V: version regression anchor — never touches repoRoot, works anywhere
    Push-Location $rootNG
    try {
        $r = Invoke-Script $FlowPs1 @('-Command', 'version')
        Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and [string]$r.json.data.version -ne '') 'e2e V: version works in non-git dir (regression anchor)'
    } finally { Pop-Location }

    # E: explore read face survives in a non-git project
    Push-Location $rootNG
    try {
        $r = Invoke-Script $ExplorePs1 @('-Type', 'search', '-Query', 'repo-root-test')
        Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true) 'e2e E: explore search works in non-git project'
    } finally { Pop-Location }

    # ===== summary =====
    $failed = @($Results | Where-Object { -not $_.ok })
    Write-Output ''
    Write-Output ("total: {0}  failed: {1}" -f $Results.Count, $failed.Count)
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
finally {
    Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Install the rdd-engine CLI distribution into the user-level engine home.

.DESCRIPTION
    Extracts the rdd-engine tarball (npm-pack format, produced by scripts/build-engine-package.mjs)
    into <EngineHome>\<version>\, flips the 'current' junction (atomic, no admin rights needed),
    records the manifest.json version ledger, and self-checks via `rdd-flow.cmd -Command version`.

    Location chain (protocol single source: rdd-engine/references/engine-location.md):
      1. %RDD_ENGINE_HOME%           explicit override (may point at a concrete version dir)
      2. project-local rdd-engine    git toplevel recursive depth-3 lookup (codeRDD / v1 coderrdd layouts)
      3. ~\.rdd\engine\current       user-level default installed by this script

    User side has ZERO node/npm dependency: extraction is done by tar.exe (Win10 1803+).

.PARAMETER Tarball
    Path to rdd-engine.tgz. Default search order: beside this script, then <repo>\dist\engine\rdd-engine.tgz.

.PARAMETER EngineHome
    Install root. Default: %USERPROFILE%\.rdd\engine (override for testing / release orchestration).

.PARAMETER AddToPath
    Opt-in: append <EngineHome>\current\scripts to the user PATH. Human-terminal convenience only;
    PATH changes never affect already-running sessions - skill location always uses the
    file-system chain above (deterministic).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install-rdd-engine.ps1 -Tarball .\rdd-engine.tgz

.NOTES
    Exit codes: 0 = installed & self-checked; 1 = actionable failure (missing tooling, bad tarball,
    self-check mismatch). Upgrade = re-run with a newer tarball; rollback = re-run with an older one;
    uninstall = remove the engine home directory.
#>
[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$EngineHome = (Join-Path $HOME '.rdd\engine'),
    [switch]$AddToPath
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Fail {
    param([string]$Message, [int]$Code = 1)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit $Code
}

function Info {
    param([string]$Message)
    Write-Host $Message
}

# --- 1. Environment checks (fail with actionable messages) ---
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Fail "PowerShell 5.1+ required (found $($PSVersionTable.PSVersion)). Install Windows Management Framework 5.1 or PowerShell 7+ (https://aka.ms/powershell), then retry."
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Fail "tar.exe not found on PATH. It ships with Windows 10 1803+ (bsdtar). Update Windows, or install bsdtar/libarchive and put it on PATH, then retry."
}

# --- 2. Resolve tarball ---
$candidates = @()
if ($Tarball) {
    $candidates += $Tarball
}
else {
    $candidates += (Join-Path $PSScriptRoot 'rdd-engine.tgz')
    $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\engine\rdd-engine.tgz')
}
$tgz = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $tgz) {
    Fail "rdd-engine.tgz not found (searched: $($candidates -join ' ; ')). Download it from the codeRDD GitHub Release, then retry with -Tarball <path>."
}
$tgz = (Resolve-Path -LiteralPath $tgz).Path

# --- 3. Read package metadata straight from the tarball (no full extract) ---
$pkgLines = & tar.exe -xOf $tgz 'package/package.json'
if ($LASTEXITCODE -ne 0 -or -not $pkgLines) {
    Fail "Cannot read package/package.json inside '$tgz' (tar exit code $LASTEXITCODE). The file may be corrupted - re-download it from the GitHub Release."
}
$pkg = ($pkgLines -join "`n") | ConvertFrom-Json
if ($pkg.name -ne '@coderrdd/rdd-engine') {
    Fail "Unexpected package name '$($pkg.name)' (expected '@coderrdd/rdd-engine') - this is not an rdd-engine distribution tarball."
}
$version = [string]$pkg.version
if ([string]::IsNullOrWhiteSpace($version)) { Fail "Tarball package.json carries no version." }
Info "[1/6] Tarball OK: $($pkg.name) v$version (source: $(Split-Path -Leaf $tgz))"

# --- 4. Extract into staging, then swap into <EngineHome>\<version> ---
New-Item -ItemType Directory -Path $EngineHome -Force | Out-Null
$stage = Join-Path $EngineHome ('.staging-' + [guid]::NewGuid().ToString('N'))
$target = Join-Path $EngineHome $version
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    & tar.exe -xzf $tgz -C $stage
    if ($LASTEXITCODE -ne 0) { Fail "tar extract failed (exit code $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'package\scripts\rdd-flow.cmd'))) {
        Fail "Extracted tarball is missing scripts\rdd-flow.cmd - not a valid rdd-engine layout. Re-download from the GitHub Release."
    }
    if (Test-Path -LiteralPath $target) {
        Info "[2/6] Version dir already exists, replacing: $target"
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    else {
        Info "[2/6] Creating version dir: $target"
    }
    Move-Item -LiteralPath (Join-Path $stage 'package') -Destination $target
    Info "[3/6] Extracted to: $target"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 5. Flip the 'current' junction (atomic pointer swap) ---
$current = Join-Path $EngineHome 'current'
try {
    if (Test-Path -LiteralPath $current) {
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkType) { $item.Delete() }
        else {
            Write-Warning "'current' exists as a real directory (not a junction) - removing it and re-creating as a junction."
            Remove-Item -LiteralPath $current -Recurse -Force
        }
    }
    New-Item -ItemType Junction -Path $current -Target $target | Out-Null
    Info "[4/6] 'current' junction -> v$version"
}
catch {
    # Degraded profiles (OneDrive redirection / roaming): keep the install usable via env override.
    Write-Warning "Junction flip failed: $($_.Exception.Message)"
    Write-Host "[FALLBACK] Point RDD_ENGINE_HOME at the concrete version dir instead (location chain candidate #1):" -ForegroundColor Yellow
    Write-Host "           setx RDD_ENGINE_HOME `"$target`"" -ForegroundColor Yellow
    Write-Host "           then open a NEW terminal so the variable takes effect." -ForegroundColor Yellow
}

# --- 6. manifest.json version ledger (consumed by the unified release orchestration) ---
$manifestPath = Join-Path $EngineHome 'manifest.json'
$manifest = @{ current = $null; installed = @{}; history = @() }
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.current = $raw.current
        if ($raw.installed) {
            $raw.installed.PSObject.Properties | ForEach-Object { $manifest.installed[$_.Name] = $_.Value }
        }
        if ($raw.history) { $manifest.history = @($raw.history) }
    }
    catch {
        Write-Warning "Existing manifest.json is unreadable - recreating it (installed version dirs are left untouched)."
    }
}
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$manifest.installed[$version] = @{ installedAt = $now; tarball = (Split-Path -Leaf $tgz) }
$manifest.current = $version
# 外层 @() 强制数组形状：单元素时 Select-Object 会解包成标量，导致 JSON 中 history 时为数组时为对象
$manifest.history = @((@($manifest.history) + @{ version = $version; at = $now }) | Select-Object -Last 50)
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Info "[5/6] manifest.json updated (current = v$version)"

# --- 7. Self-check: installed rdd-flow must report the tarball version ---
$versionCli = Join-Path $target 'scripts\rdd-flow.cmd'
$out = & $versionCli -Command version
$jsonLine = $out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
if (-not $jsonLine) {
    Fail "Self-check failed: rdd-flow.cmd produced no JSON output (raw: $($out -join ' '))"
}
$check = $jsonLine | ConvertFrom-Json
if (-not $check.success) {
    Fail "Self-check failed: rdd-flow.cmd reported failure: $($jsonLine)"
}
if ([string]$check.data.version -ne $version) {
    Fail "Self-check failed: installed v$version but rdd-flow reports v$($check.data.version). Remove '$target' and retry."
}
Info "[6/6] Self-check OK: rdd-flow v$($check.data.version) @ $($check.data.engineRoot)"

# --- 8. Optional PATH shim (opt-in; never affects running sessions) ---
if ($AddToPath) {
    $shimDir = Join-Path $current 'scripts'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }
    if (($userPath -split ';') -notcontains $shimDir) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $shimDir), 'User')
        Info "PATH (user scope) updated with: $shimDir - takes effect in NEW terminals only."
    }
    else {
        Info "PATH (user scope) already contains: $shimDir"
    }
}

Write-Host ''
Write-Host "rdd-engine v$version installed." -ForegroundColor Green
Write-Host "  engine home : $EngineHome"
Write-Host "  current     : $current"
Write-Host "  verify      : & `"$current\scripts\rdd-flow.cmd`" -Command version"
Write-Host "  locate chain: RDD_ENGINE_HOME -> project-local rdd-engine -> ~\.rdd\engine\current"
Write-Host "  protocol    : references\engine-location.md (shipped inside the tarball)"
Write-Host "  upgrade     : re-run this installer with a newer tarball (junction flip is atomic)"
Write-Host "  rollback    : re-run this installer with an older tarball"
Write-Host "  uninstall   : remove the directory $EngineHome"
exit 0

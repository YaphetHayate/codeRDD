<#
.SYNOPSIS
    Install / remove the RDD role system (skills + presets) at the user level.

.DESCRIPTION
    Distributes the rdd-skills tarball (produced by scripts/build-skills-package.mjs)
    into the user-level DSH discovery roots:
      skills/   -> <DshHome>\skills\rdd-*        (DSH 'user-dsh' rank; project-level
                  .agents/skills automatically SHADOWS same-name user skills)
      presets/  -> <DshHome>\.agent-presets\rdd-*  ('user' trust; discovery re-reads
                  roots on every call - no restart needed)

    Install semantics: clean-then-copy (target rdd-* dirs are removed before the
    new copy lands, so upgrades never leave stale files behind). Re-running the
    installer IS the upgrade; pointing it at an older tarball IS the rollback.

    Post-install self-checks (warnings, not failures):
      1. engine three-tier location chain probe (skills reference rdd-engine
         scripts through it) - miss prints the fail-loud install guidance;
      2. rdd-explore plugin presence across profiles (presets delegate to it).

    The version ledger lands at <LedgerHome>\manifest.json (default
    ~\.rdd\skills\manifest.json): version / installedAt / releaseTag (backfilled
    by the unified installer when it owns the download) / target dirs.

.PARAMETER Tarball
    Path to rdd-skills.tgz. Default search order: beside this script, then
    <repo>\dist\skills\rdd-skills.tgz.

.PARAMETER DshHome
    DSH home override (default $env:DSH_HOME, else ~\.dsh). For testing.

.PARAMETER LedgerHome
    Ledger directory override (default ~\.rdd\skills). For testing / release
    orchestration.

.PARAMETER Remove
    Uninstall: remove rdd-* from both roots and delete the ledger. Project-level
    .rdd/ data is NEVER touched.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install-rdd-skills.ps1 -Tarball .\rdd-skills.tgz

.NOTES
    Exit codes: 0 = installed (or removed) & self-checked; 1 = actionable failure.
#>
[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$DshHome,
    [string]$LedgerHome,
    [switch]$Remove
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

if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' } }
if (-not $LedgerHome) { $LedgerHome = Join-Path $HOME '.rdd\skills' }
$skillsRoot = Join-Path $DshHome 'skills'
$presetsRoot = Join-Path $DshHome '.agent-presets'
$ledgerPath = Join-Path $LedgerHome 'manifest.json'

# --- Remove flow -------------------------------------------------------------
if ($Remove) {
    Info "[1/2] Removing rdd-* from user-level roots..."
    foreach ($root in @($skillsRoot, $presetsRoot)) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -Filter 'rdd-*' -ErrorAction SilentlyContinue | ForEach-Object {
                Info "  removing $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }
        }
    }
    if (Test-Path -LiteralPath $ledgerPath) {
        Remove-Item -LiteralPath $ledgerPath -Force
        Info "  removed ledger $ledgerPath"
    }
    Info "[2/2] RDD skills removed (project-level .rdd/ data untouched)."
    Info "  note   : DSH skill watcher hot-invalidates; presets are re-discovered per call - no restart needed"
    Info "  reinstall: re-run this installer with a tarball"
    exit 0
}

# --- 1. Environment checks ---------------------------------------------------
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Fail "PowerShell 5.1+ required (found $($PSVersionTable.PSVersion))."
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Fail "tar.exe not found on PATH. It ships with Windows 10 1803+."
}

# --- 2. Resolve tarball --------------------------------------------------------
$candidates = @()
if ($Tarball) { $candidates += $Tarball }
else {
    $candidates += (Join-Path $PSScriptRoot 'rdd-skills.tgz')
    $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\skills\rdd-skills.tgz')
}
$tgz = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $tgz) {
    Fail "rdd-skills.tgz not found (searched: $($candidates -join ' ; ')). Download the latest fixed-name asset first:`n" +
         "  Invoke-WebRequest https://github.com/YaphetHayate/codeRDD/releases/latest/download/rdd-skills.tgz -OutFile .\rdd-skills.tgz`n" +
         "then retry with -Tarball .\rdd-skills.tgz"
}
$tgz = (Resolve-Path -LiteralPath $tgz).Path

# --- 3. Validate & extract ----------------------------------------------------
$pkgLines = & tar.exe -xOf $tgz 'package/package.json'
if ($LASTEXITCODE -ne 0 -or -not $pkgLines) {
    Fail "Cannot read package/package.json inside '$tgz' (tar exit code $LASTEXITCODE). The file may be corrupted - re-download it."
}
$pkg = ($pkgLines -join "`n") | ConvertFrom-Json
if ($pkg.name -ne '@coderrdd/rdd-skills') {
    Fail "Unexpected package name '$($pkg.name)' (expected '@coderrdd/rdd-skills') - this is not an rdd-skills distribution tarball."
}
$version = [string]$pkg.version
if ([string]::IsNullOrWhiteSpace($version)) { Fail "Tarball package.json carries no version." }
Info "[1/5] Tarball OK: $($pkg.name) v$version (source: $(Split-Path -Leaf $tgz))"

$stage = Join-Path $env:TEMP ('rdd-skills-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    & tar.exe -xzf $tgz -C $stage
    if ($LASTEXITCODE -ne 0) { Fail "tar extract failed (exit code $LASTEXITCODE)." }
    $pkgSkills = Join-Path $stage 'package\skills'
    $pkgPresets = Join-Path $stage 'package\presets'
    if (-not (Test-Path $pkgSkills) -or -not (Test-Path $pkgPresets)) {
        Fail "Extracted tarball is missing skills/ or presets/ subtrees - not a valid rdd-skills layout. Re-download from the GitHub Release."
    }

    # --- 4. Clean-then-copy distribution (upgrade = clean overwrite) ---------
    Info "[2/5] Distributing into user-level roots (clean-then-copy)..."
    foreach ($root in @(@($presetsRoot, $pkgPresets), @($skillsRoot, $pkgSkills))) {
        $targetRoot, $sourceRoot = $root
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        Get-ChildItem -LiteralPath $sourceRoot -Directory -Filter 'rdd-*' | ForEach-Object {
            $dst = Join-Path $targetRoot $_.Name
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse
            Info "  $($_.Name) -> $dst"
        }
    }

    # --- 5. Version ledger (releaseTag backfilled by the unified installer) --
    Info "[3/5] Writing ledger $ledgerPath"
    New-Item -ItemType Directory -Path $LedgerHome -Force | Out-Null
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $manifest = @{
        component = 'rdd-skills'
        version = $version
        installedAt = $now
        releaseTag = $null
        dshHome = $DshHome
        skillDirs = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Filter 'rdd-*' | ForEach-Object { $_.Name })
        presetDirs = @(Get-ChildItem -LiteralPath $presetsRoot -Directory -Filter 'rdd-*' | ForEach-Object { $_.Name })
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ledgerPath -Encoding UTF8

    # --- 6. Self-check ①: engine three-tier location chain -------------------
    $engine = $null
    $t = $null
    try { $t = git rev-parse --show-toplevel } catch { }
    foreach ($c in @($env:RDD_ENGINE_HOME; if ($t) { (Get-ChildItem $t -Recurse -Directory -Depth 3 -Filter 'rdd-engine').FullName }; "$HOME\.rdd\engine\current")) {
        if ($c -and (Test-Path "$c\scripts\rdd-flow.cmd")) { $engine = $c; break }
    }
    if ($engine) {
        Info "[4/5] Engine located via the three-tier chain: $engine"
    }
    else {
        Write-Warning "[4/5] rdd-engine NOT located (three-tier chain: RDD_ENGINE_HOME -> project-local rdd-engine -> ~\.rdd\engine\current all missed)."
        Write-Host "       Skills reference engine scripts through that chain. Install it:" -ForegroundColor Yellow
        Write-Host "         Invoke-WebRequest https://github.com/YaphetHayate/codeRDD/releases/latest/download/rdd-engine.tgz -OutFile .\rdd-engine.tgz" -ForegroundColor Yellow
        Write-Host "         powershell -ExecutionPolicy Bypass -File scripts\install-rdd-engine.ps1 -Tarball .\rdd-engine.tgz" -ForegroundColor Yellow
        Write-Host "       (protocol: rdd-engine/references/engine-location.md)" -ForegroundColor Yellow
    }

    # --- 7. Self-check ②: rdd-explore plugin presence ------------------------
    $pluginFound = $false
    $profilesDir = Join-Path $DshHome 'profiles'
    if (Test-Path -LiteralPath $profilesDir) {
        foreach ($manifestFile in Get-ChildItem -LiteralPath $profilesDir -Recurse -Filter 'package.json' -Depth 1 -ErrorAction SilentlyContinue) {
            try {
                $m = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($m.dependencies -and $m.dependencies.'@coderrdd/dsh-rdd-explore') {
                    $pluginFound = $true
                    Info "[5/5] rdd-explore plugin present in profile manifest: $($manifestFile.FullName)"
                    break
                }
            } catch { }
        }
    }
    if (-not $pluginFound) {
        Write-Warning "[5/5] The @coderrdd/dsh-rdd-explore plugin was not found in any profile ($profilesDir)."
        Write-Host "       The rdd-* presets delegate exploration to that plugin - without it, preset sessions mount with a broken tool row." -ForegroundColor Yellow
        Write-Host "         Invoke-WebRequest https://github.com/YaphetHayate/codeRDD/releases/latest/download/dsh-rdd-explore.tgz -OutFile .\dsh-rdd-explore.tgz" -ForegroundColor Yellow
        Write-Host "         dsh plugin --profile web add .\dsh-rdd-explore.tgz   (or scripts\install-dsh-plugin.ps1 -Tarball .\dsh-rdd-explore.tgz)" -ForegroundColor Yellow
    }
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "RDD skills v$version installed (user-level)." -ForegroundColor Green
Write-Host "  skills  : $skillsRoot\rdd-* (project .agents/skills shadows same names - project wins)"
Write-Host "  presets : $presetsRoot\rdd-* (select them when creating sessions; no restart needed)"
Write-Host "  ledger  : $ledgerPath"
Write-Host "  upgrade : re-run this installer with a newer tarball (clean overwrite)"
Write-Host "  rollback: re-run with an older tarball"
Write-Host "  remove  : scripts\install-rdd-skills.ps1 -Remove (project .rdd/ data untouched)"
exit 0

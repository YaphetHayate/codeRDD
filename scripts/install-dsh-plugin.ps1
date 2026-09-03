<#
.SYNOPSIS
    Install the @coderrdd/dsh-rdd-explore profile bundle into a dsh profile.

.DESCRIPTION
    Thin wrapper around `dsh plugin --profile <name> add <tarball>`:
      1. verifies dsh and pnpm are on PATH (dsh plugin forwards to pnpm),
      2. resolves the tarball (-Tarball, or the fixed-name search order below),
      3. validates the tarball is really @coderrdd/dsh-rdd-explore,
      4. runs the add, then verifies the profile manifest picked it up.

    Default tarball search order (first hit wins):
      - beside this script (dsh-rdd-explore.tgz)
      - <repo>\dist\plugin\dsh-rdd-explore.tgz
    The GitHub Release always serves the fixed name for `latest`:
      https://github.com/YaphetHayate/codeRDD/releases/latest/download/dsh-rdd-explore.tgz

    After installing, RESTART the profile (reopen `dsh web` / start a new
    session) so the new bundle layer composes. The plugin works in ANY project
    that profile opens - no per-project setup, no rdd-engine checkout needed
    (a vendored exploration-guide ships inside the package).

.PARAMETER Tarball
    Path to dsh-rdd-explore.tgz. Required for offline installs; online users
    can download the latest fixed-name asset first.

.PARAMETER Profile
    Target profile name. Default 'web'. The profile is auto-initialized when
    missing (dsh plugin initializes it with @deepseek-ai/dsh-base).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install-dsh-plugin.ps1 -Tarball .\dsh-rdd-explore.tgz -Profile web

.NOTES
    Exit codes: 0 = installed & verified; 1 = actionable failure.
    Upgrade = re-run with a newer tarball; rollback = re-run with an older one;
    uninstall = dsh plugin --profile <name> remove @coderrdd/dsh-rdd-explore
    (or the unified installer's -Remove flow).
#>
[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$Profile = 'web'
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

# --- 1. Environment checks -------------------------------------------------
if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) {
    Fail "dsh not found on PATH. Install the standard DeepSeek Harness first (it provides the 'dsh' launcher), then retry."
}
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Fail "pnpm not found on PATH. 'dsh plugin' forwards to pnpm - install pnpm 10+ (https://pnpm.io/installation), then retry."
}

# --- 2. Resolve tarball ------------------------------------------------------
$candidates = @()
if ($Tarball) { $candidates += $Tarball }
else {
    $candidates += (Join-Path $PSScriptRoot 'dsh-rdd-explore.tgz')
    $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\plugin\dsh-rdd-explore.tgz')
}
$tgz = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $tgz) {
    Fail "dsh-rdd-explore.tgz not found (searched: $($candidates -join ' ; ')). Download the latest fixed-name asset first:`n" +
         "  Invoke-WebRequest https://github.com/YaphetHayate/codeRDD/releases/latest/download/dsh-rdd-explore.tgz -OutFile .\dsh-rdd-explore.tgz`n" +
         "then retry with -Tarball .\dsh-rdd-explore.tgz"
}
$tgz = (Resolve-Path -LiteralPath $tgz).Path
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Fail "tar.exe not found on PATH (needed to verify the tarball). It ships with Windows 10 1803+."
}

# --- 3. Validate the tarball ------------------------------------------------
$pkgLines = & tar.exe -xOf $tgz 'package/package.json'
if ($LASTEXITCODE -ne 0 -or -not $pkgLines) {
    Fail "Cannot read package/package.json inside '$tgz' (tar exit code $LASTEXITCODE). The file may be corrupted - re-download it."
}
$pkg = ($pkgLines -join "`n") | ConvertFrom-Json
if ($pkg.name -ne '@coderrdd/dsh-rdd-explore') {
    Fail "Unexpected package name '$($pkg.name)' (expected '@coderrdd/dsh-rdd-explore') - this is not an rdd-explore bundle tarball."
}
if (-not $pkg.dsh.bundle.patch) {
    Fail "The tarball's manifest declares no dsh.bundle - it would install as a plain dependency and activate no layer. Re-download a valid release tarball."
}
Info "[1/3] Tarball OK: $($pkg.name) v$($pkg.version) (bundle patch: $($pkg.dsh.bundle.patch))"

# --- 4. dsh plugin add -------------------------------------------------------
Info "[2/3] dsh plugin --profile $Profile add $tgz"
& dsh plugin --profile $Profile add $tgz
if ($LASTEXITCODE -ne 0) {
    Fail "dsh plugin add failed (exit code $LASTEXITCODE). See the pnpm output above."
}

# --- 5. Verify the profile picked it up -------------------------------------
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$profileManifest = Join-Path $dshHome "profiles\$Profile\package.json"
$verified = $false
if (Test-Path -LiteralPath $profileManifest) {
    try {
        $manifest = Get-Content -LiteralPath $profileManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $dep = $manifest.dependencies.'@coderrdd/dsh-rdd-explore'
        if ($dep) {
            $verified = $true
            Info "[3/3] Profile '$Profile' now depends on @coderrdd/dsh-rdd-explore ($dep)."
        }
    } catch { }
}
if (-not $verified) {
    Write-Warning "Could not verify the profile manifest at '$profileManifest' - check it manually for the @coderrdd/dsh-rdd-explore dependency."
}

Write-Host ''
Write-Host "rdd-explore v$($pkg.version) installed into profile '$Profile'." -ForegroundColor Green
Write-Host "  next step : RESTART the profile (reopen dsh web / new session) - the bundle layer composes at boot"
Write-Host "  use       : the rdd_explore tool is available in ANY project this profile opens"
Write-Host "  engine    : vendored guide ships inside the package; projects with rdd-engine keep using their own"
Write-Host "  upgrade   : re-run this installer with a newer tarball"
Write-Host "  uninstall : dsh plugin --profile $Profile remove @coderrdd/dsh-rdd-explore"
exit 0

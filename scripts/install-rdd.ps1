<#
.SYNOPSIS
    Unified RDD installer: engine + explore plugin + role skills from ONE release.

.DESCRIPTION
    Orchestrates the three component installers so a user installs everything
    from a single GitHub release with version-consistent components. The
    orchestration layer only downloads, orders, backfills, and reports - zero
    component-install logic is duplicated (each component installer stays
    independently runnable).

    Install order is HARDCODED: engine -> plugin -> skills
      (presets delegate to the plugin; the skills self-check uses the engine
       location chain - see the role-skills design constraints).

    Version consistency: the two-step download resolves 'latest' to a concrete
    tag FIRST, then fetches all three fixed-name assets from that tag's
    directory - no torn mix across a release replacement. After installing,
    the orchestrator backfills releaseTag into both manifests
    (~\.rdd\engine\manifest.json, ~\.rdd\skills\manifest.json) itself.

    Failure semantics: component installers are idempotent (re-run = safe
    resume). On failure this script prints the completed components and how to
    resume; no automatic rollback (component-level junction flips are atomic
    and clean-overwrite installs make rollback complexity not worth it).

    Component installers are located beside this script (repo scripts/ or the
    release attachment bundle), else downloaded from the tag's raw source.

.PARAMETER Release
    Release tag. Default 'latest' (resolved to a concrete tag before any
    download). Pinning an older tag = downgrade.

.PARAMETER Offline
    Directory that already contains the three tarballs (+ component installers).
    Skips all network access.

.PARAMETER Remove
    Uninstall everything: ~\.rdd\engine, skills installer -Remove, and
    'dsh plugin remove' per profile that carries the plugin. Best effort:
    component failures do not block the rest; a residual summary is printed.

.PARAMETER Status
    Version reconciliation: reads both manifests (releaseTag) plus the plugin
    dependency in profiles, prints the three components and a consistency verdict.

.PARAMETER Profile
    dsh profile for the plugin component. Default 'web'.

.PARAMETER EngineHome / DshHome / LedgerHome
    Passthrough overrides for testing / release orchestration (default
    ~\.rdd\engine, $env:DSH_HOME or ~\.dsh, ~\.rdd\skills).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install-rdd.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Release v1.0.0

.NOTES
    Exit codes: 0 = success; 1 = actionable failure.
#>
[CmdletBinding()]
param(
    [string]$Release = 'latest',
    [string]$Offline,
    [switch]$Remove,
    [switch]$Status,
    [string]$Profile = 'web',
    [string]$EngineHome,
    [string]$DshHome,
    [string]$LedgerHome
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Repo = 'YaphetHayate/codeRDD'
$PluginPackage = '@coderrdd/dsh-rdd-explore'

function Fail {
    param([string]$Message, [int]$Code = 1)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit $Code
}

function Info {
    param([string]$Message)
    Write-Host $Message
}

if (-not $EngineHome) { $EngineHome = Join-Path $HOME '.rdd\engine' }
if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' } }
if (-not $LedgerHome) { $LedgerHome = Join-Path $HOME '.rdd\skills' }
$engineManifestPath = Join-Path $EngineHome 'manifest.json'
$skillsLedgerPath = Join-Path $LedgerHome 'manifest.json'

# DSH home must be visible to child processes (dsh + the plugin installer read it)
$env:DSH_HOME = $DshHome

$componentInstallers = [ordered]@{
    engine = 'install-rdd-engine.ps1'
    plugin = 'install-dsh-plugin.ps1'
    skills = 'install-rdd-skills.ps1'
}
$assetNames = [ordered]@{
    engine = 'rdd-engine.tgz'
    plugin = 'dsh-rdd-explore.tgz'
    skills = 'rdd-skills.tgz'
}

function Read-JsonProperty {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json).$Name } catch { return $null }
}

# ---------------------------------------------------------------------------
# -Status: version reconciliation
# ---------------------------------------------------------------------------
function OrDash {
    param($Value)
    if ($null -ne $Value -and "$Value" -ne '') { return $Value }
    return '-'
}

if ($Status) {
    $engineVersion = Read-JsonProperty $engineManifestPath 'current'
    $engineTag = Read-JsonProperty $engineManifestPath 'releaseTag'
    $skillsVersion = Read-JsonProperty $skillsLedgerPath 'version'
    $skillsTag = Read-JsonProperty $skillsLedgerPath 'releaseTag'
    $pluginInfo = $null
    $profilesDir = Join-Path $DshHome 'profiles'
    if (Test-Path -LiteralPath $profilesDir) {
        foreach ($m in Get-ChildItem -LiteralPath $profilesDir -Recurse -Filter 'package.json' -Depth 1 -ErrorAction SilentlyContinue) {
            try {
                $dep = (Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.$PluginPackage
                if ($dep) { $pluginInfo = "present ($dep) in $(Split-Path -Leaf (Split-Path -Parent $m.FullName))"; break }
            } catch { }
        }
    }
    Write-Host "RDD component status (engine home $EngineHome / dsh home $DshHome):"
    Write-Host ("  engine : v{0}  releaseTag={1}" -f (OrDash $engineVersion), (OrDash $engineTag))
    Write-Host ("  plugin : {0}" -f (OrDash $pluginInfo))
    Write-Host ("  skills : v{0}  releaseTag={1}" -f (OrDash $skillsVersion), (OrDash $skillsTag))
    $tags = @($engineTag, $skillsTag) | Where-Object { $_ }
    $consistent = ($tags.Count -eq 2 -and ($tags | Select-Object -Unique).Count -eq 1 -and $pluginInfo)
    if (-not (Test-Path -LiteralPath $engineManifestPath) -and -not (Test-Path -LiteralPath $skillsLedgerPath) -and -not $pluginInfo) {
        Write-Host '  verdict: nothing installed' -ForegroundColor Yellow
    }
    elseif ($consistent) {
        Write-Host "  verdict: consistent (all from $($tags[0]))" -ForegroundColor Green
    }
    else {
        Write-Host '  verdict: INCONSISTENT - components come from different releases (or the plugin is missing).' -ForegroundColor Yellow
        Write-Host '          Re-run install-rdd.ps1 (optionally -Release <tag>) to realign.' -ForegroundColor Yellow
    }
    exit 0
}

# ---------------------------------------------------------------------------
# -Remove: best-effort uninstall with residual summary
# ---------------------------------------------------------------------------
if ($Remove) {
    $residual = @()

    # 1. engine home
    if (Test-Path -LiteralPath $EngineHome) {
        try { Remove-Item -LiteralPath $EngineHome -Recurse -Force; Info "[1/3] removed $EngineHome" }
        catch { $residual += "engine home $EngineHome ($($_.Exception.Message))" }
    }
    else { Info '[1/3] engine home not present (nothing to do)' }

    # 2. skills (component installer owns the clean-up semantics)
    $skillsInstaller = @($PSScriptRoot, (Join-Path $PSScriptRoot 'scripts')) |
        ForEach-Object { Join-Path $_ $componentInstallers.skills } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($skillsInstaller) {
        $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $skillsInstaller, '-Remove', '-DshHome', $DshHome, '-LedgerHome', $LedgerHome)
        & powershell @args_
        if ($LASTEXITCODE -ne 0) { $residual += "skills removal failed (exit $LASTEXITCODE) - re-run: powershell -File $skillsInstaller -Remove" }
        else { Info '[2/3] skills removed' }
    }
    else {
        $residual += "skills installer not found - remove manually: $DshHome\skills\rdd-*, $DshHome\.agent-presets\rdd-*, $skillsLedgerPath"
    }

    # 3. plugin (only profiles that actually carry the dependency)
    $removedPlugin = $false
    $profilesDir = Join-Path $DshHome 'profiles'
    if ((Test-Path -LiteralPath $profilesDir) -and (Get-Command dsh -ErrorAction SilentlyContinue)) {
        foreach ($m in Get-ChildItem -LiteralPath $profilesDir -Recurse -Filter 'package.json' -Depth 1 -ErrorAction SilentlyContinue) {
            try {
                $manifest = Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($manifest.dependencies -and $manifest.dependencies.$PluginPackage) {
                    $profileName = Split-Path -Leaf (Split-Path -Parent $m.FullName)
                    & dsh plugin --profile $profileName remove $PluginPackage
                    if ($LASTEXITCODE -eq 0) { $removedPlugin = $true; Info "[3/3] plugin removed from profile '$profileName'" }
                    else { $residual += "plugin removal from profile '$profileName' failed (exit $LASTEXITCODE)" }
                }
            } catch { }
        }
    }
    if (-not $removedPlugin) {
        Info '[3/3] plugin not found in any profile (nothing to do)'
    }
    if (-not (Get-Command dsh -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $profilesDir)) {
        $residual += "dsh not on PATH - remove the plugin manually per profile: dsh plugin --profile <name> remove $PluginPackage"
    }

    Write-Host ''
    if ($residual.Count -eq 0) {
        Write-Host 'RDD removed (project-level .rdd/ data untouched).' -ForegroundColor Green
    }
    else {
        Write-Host 'RDD removed with residuals:' -ForegroundColor Yellow
        $residual | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Install: resolve assets + installers, run engine -> plugin -> skills, backfill
# ---------------------------------------------------------------------------
if ($Offline -and -not (Test-Path -LiteralPath $Offline -PathType Container)) {
    Fail "-Offline directory not found: $Offline"
}

$staging = Join-Path $env:TEMP ('rdd-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
$tag = $null
try {
    if ($Offline) {
        # --- offline: everything must already be there ----------------------
        $tag = "[offline:$(Split-Path -Leaf (Resolve-Path $Offline))]"
        foreach ($key in @('engine', 'plugin', 'skills')) {
            $src = Join-Path $Offline $assetNames[$key]
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Fail "offline dir misses asset: $src" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $staging $assetNames[$key])
        }
    }
    else {
        # --- online: two-step download (resolve tag first, no torn mixes) ---
        if ($Release -eq 'latest') {
            Info 'Resolving latest release tag...'
            $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
            $tag = $rel.tag_name
            if (-not $tag) { Fail 'GitHub API returned no tag_name for the latest release.' }
        }
        else { $tag = $Release }
        $base = "https://github.com/$Repo/releases/download/$tag/"
        foreach ($key in @('engine', 'plugin', 'skills')) {
            $url = $base + $assetNames[$key]
            $dst = Join-Path $staging $assetNames[$key]
            Info "Downloading $url"
            Invoke-WebRequest $url -OutFile $dst
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { Fail "download failed: $url" }
        }
    }
    Info "Assets staged for tag $tag (engine -> plugin -> skills)."

    # --- component installers: beside script > repo scripts/ > raw source at tag ---
    function Resolve-Installer {
        param([string]$FileName)
        $local = @($PSScriptRoot, (Join-Path $PSScriptRoot 'scripts')) |
            ForEach-Object { Join-Path $_ $FileName } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($local) { return $local }
        if ($Offline) { Fail "component installer '$FileName' not found beside this script or under -Offline dir" }
        $url = "https://raw.githubusercontent.com/$Repo/$tag/scripts/$FileName"
        $dst = Join-Path $staging $FileName
        Info "Downloading $url"
        Invoke-WebRequest $url -OutFile $dst
        return $dst
    }

    $engineInstaller = Resolve-Installer $componentInstallers.engine
    $pluginInstaller = Resolve-Installer $componentInstallers.plugin
    $skillsInstaller = Resolve-Installer $componentInstallers.skills

    # --- 1. engine ---------------------------------------------------------
    Info ''
    Info '=== [1/3] rdd-engine ==='
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engineInstaller, '-Tarball', (Join-Path $staging $assetNames.engine), '-EngineHome', $EngineHome)
    & powershell @args_
    if ($LASTEXITCODE -ne 0) { Fail "engine install failed (exit $LASTEXITCODE). Resume: re-run this script (components are idempotent) or: powershell -File $engineInstaller -Tarball $(Join-Path $staging $assetNames.engine)" }

    # --- 2. plugin ---------------------------------------------------------
    Info ''
    Info "=== [2/3] dsh-rdd-explore plugin (profile: $Profile) ==="
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pluginInstaller, '-Tarball', (Join-Path $staging $assetNames.plugin), '-Profile', $Profile)
    & powershell @args_
    if ($LASTEXITCODE -ne 0) { Fail "plugin install failed (exit $LASTEXITCODE). Engine is already installed. Resume: re-run this script, or: powershell -File $pluginInstaller -Tarball $(Join-Path $staging $assetNames.plugin) -Profile $Profile" }
    Info 'next: RESTART the profile (reopen dsh web / new session) so the new bundle layer composes.'

    # --- 3. skills ---------------------------------------------------------
    Info ''
    Info '=== [3/3] rdd-skills (skills + presets) ==='
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $skillsInstaller, '-Tarball', (Join-Path $staging $assetNames.skills), '-DshHome', $DshHome, '-LedgerHome', $LedgerHome)
    & powershell @args_
    if ($LASTEXITCODE -ne 0) { Fail "skills install failed (exit $LASTEXITCODE). Engine + plugin are installed. Resume: re-run this script, or: powershell -File $skillsInstaller -Tarball $(Join-Path $staging $assetNames.skills)" }

    # --- releaseTag backfill (the orchestrator writes what it reads) --------
    foreach ($pair in @(@($engineManifestPath, 'engine'), @($skillsLedgerPath, 'skills'))) {
        $path, $label = $pair
        if (Test-Path -LiteralPath $path) {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.PSObject.Properties['releaseTag']) { $json.releaseTag = $tag }
            else { $json | Add-Member -NotePropertyName releaseTag -NotePropertyValue $tag }
            $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
            Info "backfilled releaseTag=$tag into $label manifest ($path)"
        }
        else {
            Write-Warning "$label manifest not found at $path - releaseTag not backfilled (re-run to fix)."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "RDD $tag installed (engine -> plugin -> skills)." -ForegroundColor Green
Write-Host '  verify  : powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Status'
Write-Host '  restart : reopen the dsh profile so the plugin bundle layer composes'
Write-Host '  upgrade : re-run install-rdd.ps1 (latest) or -Release <tag> to downgrade'
Write-Host '  remove  : powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Remove'
Write-Host '  data    : project-level .rdd/ data (changes/exploration/tree-runs) is never touched'
exit 0

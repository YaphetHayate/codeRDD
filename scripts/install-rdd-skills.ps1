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

    Reparse-point protection: a target rdd-* directory that is a junction or a
    symbolic link is NEVER deleted - it is the dev-machine form of a skill or
    engine pointer, and the skills/rdd-engine entry of the package holds only
    SKILL.md, so overwriting the link would truncate a whole engine checkout.
    Install keeps such a link when the files the package would place there are
    already byte-identical behind it, and fails before touching any root when
    they are not; -Remove refuses those links and exits non-zero, listing what
    it left in place.

    Package guidance gate: after extraction and before anything lands, every
    packaged preset must carry the start-role.cmd handoff guidance and must not
    carry the retired manual-session wording - a stale tarball fails here
    instead of silently reinstalling the old persona. After the copy the
    installed skills and presets are checked byte-for-byte against the package.

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
    Exit codes: 0 = installed (or removed) & self-checked; 1 = actionable failure
    (including a protected reparse point that -Remove left in place, or a package
    whose presets carry stale guidance).
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

function Test-ReparsePoint {
    # Junctions/symbolic links are the dev-machine form of a skill or engine
    # pointer. Deleting one replaces it with a plain directory and breaks the
    # link, so no code path in this installer ever removes one.
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Test-EntryContentPreserved {
    # True when every file the package would install for one entry is already
    # byte-identical behind the link. Only this case lets a protected reparse
    # point stand in for a normal clean-then-copy of that entry.
    param([string]$SourceDir, [string]$TargetDir)
    foreach ($file in Get-ChildItem -LiteralPath $SourceDir -Recurse -File) {
        $rel = $file.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
        $dst = Join-Path $TargetDir $rel
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return $false }
        $srcHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) { return $false }
    }
    return $true
}

if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' } }
if (-not $LedgerHome) { $LedgerHome = Join-Path $HOME '.rdd\skills' }
$skillsRoot = Join-Path $DshHome 'skills'
$presetsRoot = Join-Path $DshHome '.agent-presets'
$ledgerPath = Join-Path $LedgerHome 'manifest.json'

# --- Remove flow -------------------------------------------------------------
if ($Remove) {
    Info "[1/2] Removing rdd-* from user-level roots..."
    $keptLinks = @()
    foreach ($root in @($skillsRoot, $presetsRoot)) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -Filter 'rdd-*' -ErrorAction SilentlyContinue | ForEach-Object {
                if (Test-ReparsePoint -Path $_.FullName) {
                    $keptLinks += $_.FullName
                    return
                }
                Info "  removing $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }
        }
    }
    if ($keptLinks.Count -gt 0) {
        Write-Host "[ERROR] refusing to delete reparse points (junction/symbolic link):" -ForegroundColor Red
        foreach ($link in $keptLinks) {
            Write-Host "        $link -> $((Get-Item -LiteralPath $link -Force).Target)" -ForegroundColor Red
        }
        Write-Host "        These point at another checkout - delete them by hand only if they are truly obsolete." -ForegroundColor Yellow
        Write-Host "        Ledger kept: the uninstall is incomplete." -ForegroundColor Yellow
        exit 1
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

    # Guidance gate: a stale tarball silently reinstalls the retired persona.
    # Check the packaged presets here, before anything lands on disk.
    foreach ($entry in Get-ChildItem -LiteralPath $pkgPresets -Directory -Filter 'rdd-*') {
        $persona = [System.IO.File]::ReadAllText((Join-Path $entry.FullName 'agent.cordis.yml'))
        if ($persona -notmatch 'start-role\.cmd') {
            Fail "package preset $($entry.Name) lacks the start-role.cmd handoff guidance - stale tarball. Rebuild with scripts\build-skills-package.mjs."
        }
        if ($persona -match '新建目标角色会话') {
            Fail "package preset $($entry.Name) still carries the retired manual-session guidance - stale tarball. Rebuild with scripts\build-skills-package.mjs."
        }
    }

    # --- 4. Clean-then-copy distribution (upgrade = clean overwrite) ---------
    $presetEntries = @(Get-ChildItem -LiteralPath $pkgPresets -Directory -Filter 'rdd-*')
    $skillEntries = @(Get-ChildItem -LiteralPath $pkgSkills -Directory -Filter 'rdd-*')

    # Pre-flight: never delete a reparse point, and fail before any root is
    # modified when one does not already carry the package content.
    foreach ($root in @(@($presetsRoot, $presetEntries), @($skillsRoot, $skillEntries))) {
        $targetRoot, $entries = $root
        foreach ($entry in $entries) {
            $dst = Join-Path $targetRoot $entry.Name
            if (-not (Test-Path -LiteralPath $dst)) { continue }
            if (-not (Test-ReparsePoint -Path $dst)) { continue }
            if (-not (Test-EntryContentPreserved -SourceDir $entry.FullName -TargetDir $dst)) {
                Fail "refusing to overwrite reparse point '$dst' (junction/symbolic link): its content differs from the package. Remove the link, or install into another -DshHome."
            }
        }
    }

    Info "[2/5] Distributing into user-level roots (clean-then-copy)..."
    foreach ($root in @(@($presetsRoot, $presetEntries), @($skillsRoot, $skillEntries))) {
        $targetRoot, $entries = $root
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        foreach ($entry in $entries) {
            $dst = Join-Path $targetRoot $entry.Name
            if (Test-Path -LiteralPath $dst) {
                if (Test-ReparsePoint -Path $dst) {
                    Info "  preserved reparse point (content already matches): $dst"
                    continue
                }
                Remove-Item -LiteralPath $dst -Recurse -Force
            }
            Copy-Item -LiteralPath $entry.FullName -Destination $dst -Recurse
            Info "  $($entry.Name) -> $dst"
        }
    }

    # Post-copy check: every installed entry must equal the packaged one (a link
    # kept in place or a silently failed copy would otherwise pass unnoticed).
    foreach ($entry in $presetEntries) {
        $installed = Join-Path $presetsRoot $entry.Name
        foreach ($name in @('agent.cordis.yml', 'preset.yml')) {
            $src = Join-Path $entry.FullName $name
            $dst = Join-Path $installed $name
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { Fail "installed preset missing after copy: $dst" }
            if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash) {
                Fail "installed preset differs from the package: $dst"
            }
        }
    }
    foreach ($entry in $skillEntries) {
        $src = Join-Path $entry.FullName 'SKILL.md'
        $dst = Join-Path (Join-Path $skillsRoot $entry.Name) 'SKILL.md'
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { Fail "installed skill missing after copy: $dst" }
        if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash) {
            Fail "installed skill differs from the package: $dst"
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

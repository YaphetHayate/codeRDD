[CmdletBinding()]
param(
    [string]$Target = ".",
    [ValidateSet("full", "minimal", "custom")]
    [string]$Mode = "full",
    [string]$Roles,
    [switch]$NoDocs,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Update,
    [switch]$Uninstall,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SCRIPT_VERSION = "1.0.0"
$MANIFEST_NAME = ".rdd-install.json"
$BACKUP_NAME = ".rdd-install-backup"
$EXCLUDE_DIRS = @(".idea", ".claude", "node_modules", ".git")

$ALL_ROLES = @("pm", "cto", "ux", "dev", "qa", "eval", "pse")
$MINIMAL_ROLES = @("pm", "cto", "dev")
$ROLE_COMMANDS = @{
    pm  = "rdd-pm.md"
    cto = "rdd-cto.md"
    ux  = "rdd-ux.md"
    dev = "rdd-dev.md"
}

function Write-Step { param([string]$Message); if (-not $Quiet) { Write-Host "[*] $Message" -ForegroundColor Cyan } }
function Write-Ok { param([string]$Message); if (-not $Quiet) { Write-Host "[+] $Message" -ForegroundColor Green } }
function Write-Warn { param([string]$Message); if (-not $Quiet) { Write-Host "[!] $Message" -ForegroundColor Yellow } }
function Write-Err { param([string]$Message); Write-Host "[x] $Message" -ForegroundColor Red }

function Test-GitRepo {
    param([string]$Path)
    try { git -C $Path rev-parse --show-toplevel 2>&1 | Out-Null; return $LASTEXITCODE -eq 0 }
    catch { return $false }
}

function Get-SourceCommit {
    param([string]$SourceRoot)
    try { return (git -C $SourceRoot rev-parse HEAD 2>$null).Trim() }
    catch { return "unknown" }
}

function Resolve-Roles {
    param([string]$Mode, [string]$Roles)
    if ($Mode -eq "custom") {
        if ([string]::IsNullOrWhiteSpace($Roles)) {
            Write-Err "Mode=custom 需要 -Roles 参数，如 -Roles pm,cto,dev"
            exit 1
        }
        $list = $Roles -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
        foreach ($r in $list) {
            if ($r -notin $ALL_ROLES) {
                Write-Err "未知角色: $r。可用: $($ALL_ROLES -join ', ')"
                exit 1
            }
        }
        return $list
    }
    if ($Mode -eq "minimal") { return $MINIMAL_ROLES }
    return $ALL_ROLES
}

function Get-CommandForRole {
    param([string]$Role)
    if ($ROLE_COMMANDS.ContainsKey($Role)) { return $ROLE_COMMANDS[$Role] }
    return $null
}

function Test-FileSame {
    param([string]$A, [string]$B)
    if (-not (Test-Path -LiteralPath $A) -or -not (Test-Path -LiteralPath $B)) { return $false }
    return (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

function Copy-FileSmart {
    param([string]$Source, [string]$Destination, [string]$RelPath, $Manifest, [switch]$Force, [switch]$DryRun)
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent) -and -not $DryRun) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        if (-not $DryRun) { Copy-Item -LiteralPath $Source -Destination $Destination -Force }
        $null = $Manifest.Add(@{ path = $RelPath; action = "created" })
        return
    }
    if (Test-FileSame -A $Source -B $Destination) {
        $null = $Manifest.Add(@{ path = $RelPath; action = "unchanged" })
        return
    }
    if ($Force) {
        if (-not $DryRun) { Copy-Item -LiteralPath $Source -Destination $Destination -Force }
        $null = $Manifest.Add(@{ path = $RelPath; action = "overwritten" })
        return
    }
    $null = $Manifest.Add(@{ path = $RelPath; action = "skipped(user-modified)" })
    Write-Warn "跳过已修改文件: $RelPath（-Force 覆盖）"
}

function Copy-TreeSmart {
    param([string]$Source, [string]$Destination, [string]$BaseRel, $Manifest, [switch]$Force, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Destination) -and -not $DryRun) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    foreach ($f in (Get-ChildItem -LiteralPath $Source -File)) {
        $rel = ($BaseRel + "/" + $f.Name)
        Copy-FileSmart -Source $f.FullName -Destination (Join-Path $Destination $f.Name) -RelPath $rel -Manifest $Manifest -Force:$Force -DryRun:$DryRun
    }
    foreach ($d in (Get-ChildItem -LiteralPath $Source -Directory | Where-Object { $_.Name -notin $EXCLUDE_DIRS })) {
        $newBase = ($BaseRel + "/" + $d.Name)
        Copy-TreeSmart -Source $d.FullName -Destination (Join-Path $Destination $d.Name) -BaseRel $newBase -Manifest $Manifest -Force:$Force -DryRun:$DryRun
    }
}

function Copy-EngineAsset {
    param([string]$SourceRoot, [string]$TargetRoot, $Manifest, [switch]$Force, [switch]$DryRun)
    Write-Step "复制 rdd-engine ..."
    Copy-TreeSmart -Source (Join-Path $SourceRoot "rdd-engine") -Destination (Join-Path $TargetRoot "rdd-engine") -BaseRel "rdd-engine" -Manifest $Manifest -Force:$Force -DryRun:$DryRun
}

function Copy-RoleAssets {
    param([string]$SourceRoot, [string]$TargetRoot, [string[]]$Roles, $Manifest, [switch]$Force, [switch]$DryRun)
    foreach ($role in $Roles) {
        $roleDir = "rdd-$role"
        $srcRole = Join-Path $SourceRoot $roleDir
        if (-not (Test-Path -LiteralPath $srcRole)) { Write-Warn "源缺少 $roleDir，跳过"; continue }
        Write-Step "复制 $roleDir ..."
        Copy-TreeSmart -Source $srcRole -Destination (Join-Path $TargetRoot $roleDir) -BaseRel $roleDir -Manifest $Manifest -Force:$Force -DryRun:$DryRun
        $cmd = Get-CommandForRole -Role $role
        if ($cmd) {
            $srcCmd = Join-Path $SourceRoot ".opencode\commands\$cmd"
            if (Test-Path -LiteralPath $srcCmd) {
                $rel = ".opencode/commands/$cmd"
                Write-Step "复制 $rel"
                Copy-FileSmart -Source $srcCmd -Destination (Join-Path $TargetRoot ".opencode\commands\$cmd") -RelPath $rel -Manifest $Manifest -Force:$Force -DryRun:$DryRun
            }
        }
    }
}

function Copy-InfraAssets {
    param([string]$SourceRoot, [string]$TargetRoot, $Manifest, [switch]$Force, [switch]$DryRun)
    $items = @(@("agent", "rdd-explore.md"), @("tools", "rdd_explore.ts"))
    foreach ($pair in $items) {
        $sub, $file = $pair
        $src = Join-Path $SourceRoot ".opencode\$sub\$file"
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $rel = ".opencode/$sub/$file"
        Write-Step "复制 $rel"
        Copy-FileSmart -Source $src -Destination (Join-Path $TargetRoot ".opencode\$sub\$file") -RelPath $rel -Manifest $Manifest -Force:$Force -DryRun:$DryRun
    }
}

function Copy-DocsAsset {
    param([string]$SourceRoot, [string]$TargetRoot, $Manifest, [switch]$DryRun)
    $src = Join-Path $SourceRoot "docs\code-quality.md"
    $dst = Join-Path $TargetRoot "docs\code-quality.md"
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    if (Test-Path -LiteralPath $dst) {
        Write-Warn "docs/code-quality.md 已存在，跳过（用户可能已定制）"
        $null = $Manifest.Add(@{ path = "docs/code-quality.md"; action = "skipped(exists)" })
        return $false
    }
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    $null = $Manifest.Add(@{ path = "docs/code-quality.md"; action = "created" })
    return $true
}

function Backup-File {
    param([string]$FilePath, [string]$BackupDir, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $false }
    $backupFile = Join-Path $BackupDir (Split-Path -Leaf $FilePath)
    if (Test-Path -LiteralPath $backupFile) { return $true }
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Copy-Item -LiteralPath $FilePath -Destination $backupFile -Force
    }
    return $true
}

function Restore-Backup {
    param([string]$FileName, [string]$BackupDir, [string]$TargetPath, [switch]$DryRun)
    $backupFile = Join-Path $BackupDir $FileName
    if (-not (Test-Path -LiteralPath $backupFile)) { return $false }
    if (-not $DryRun) { Copy-Item -LiteralPath $backupFile -Destination $TargetPath -Force }
    return $true
}

function Merge-PackageJson {
    param([string]$SourcePath, [string]$TargetPath, [switch]$DryRun)
    $sourcePkg = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path (Split-Path $TargetPath) -Force | Out-Null
            Copy-Item -LiteralPath $SourcePath -Destination $TargetPath
        }
        return @{ action = "created"; detail = $TargetPath }
    }
    $targetPkg = Get-Content -LiteralPath $TargetPath -Raw | ConvertFrom-Json
    if (-not ($targetPkg.PSObject.Properties.Name -contains "dependencies")) {
        $targetPkg | Add-Member -MemberType NoteProperty -Name "dependencies" -Value (New-Object PSObject)
    }
    $added = @()
    foreach ($name in $sourcePkg.dependencies.PSObject.Properties.Name) {
        $ver = $sourcePkg.dependencies.$name
        if ($targetPkg.dependencies.PSObject.Properties.Name -contains $name) {
            $existing = $targetPkg.dependencies.$name
            if ($existing -ne $ver) { Write-Warn "package.json: $name 版本差异（目标 $existing / 源 $ver），保留目标版本" }
            continue
        }
        $targetPkg.dependencies | Add-Member -MemberType NoteProperty -Name $name -Value $ver
        $added += $name
    }
    if ($added.Count -gt 0 -and -not $DryRun) {
        $targetPkg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TargetPath -Encoding UTF8
    }
    $action = if ($added.Count -gt 0) { "merged(+$($added -join ','))" } else { "unchanged" }
    return @{ action = $action; detail = $TargetPath }
}

function Merge-OpencodeJson {
    param([string]$SourcePath, [string]$TargetPath, [bool]$IncludeInstructions, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        if ($IncludeInstructions) {
            $cfg = [ordered]@{ "`$schema" = "https://opencode.ai/config.json"; instructions = @("docs/code-quality.md") }
            if (-not $DryRun) { $cfg | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $TargetPath -Encoding UTF8 }
            return @{ action = "created"; detail = $TargetPath }
        }
        return @{ action = "skipped"; detail = "$TargetPath (-NoDocs)" }
    }
    if (-not $IncludeInstructions) { return @{ action = "skipped"; detail = "$TargetPath (-NoDocs)" } }
    $targetCfg = Get-Content -LiteralPath $TargetPath -Raw | ConvertFrom-Json
    $current = @()
    if ($targetCfg.PSObject.Properties.Name -contains "instructions") { $current = @($targetCfg.instructions) }
    if ("docs/code-quality.md" -in $current) { return @{ action = "unchanged"; detail = $TargetPath } }
    $current += "docs/code-quality.md"
    if (-not $DryRun) {
        $targetCfg.instructions = $current
        $targetCfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TargetPath -Encoding UTF8
    }
    return @{ action = "merged(+code-quality.md)"; detail = $TargetPath }
}

function Merge-ConfigAssets {
    param([string]$SourceRoot, [string]$TargetRoot, [string]$BackupDir, [bool]$IncludeDocs, $MergedManifest, [switch]$DryRun)
    $srcPkg = Join-Path $SourceRoot ".opencode\package.json"
    $dstPkg = Join-Path $TargetRoot ".opencode\package.json"
    Write-Step "合并 .opencode/package.json"
    $null = Backup-File -FilePath $dstPkg -BackupDir $BackupDir -DryRun:$DryRun
    $r1 = Merge-PackageJson -SourcePath $srcPkg -TargetPath $dstPkg -DryRun:$DryRun
    $null = $MergedManifest.Add(@{ path = ".opencode/package.json"; action = $r1.action; detail = $r1.detail })
    $srcCfg = Join-Path $SourceRoot "opencode.json"
    $dstCfg = Join-Path $TargetRoot "opencode.json"
    Write-Step "合并 opencode.json"
    if (Test-Path -LiteralPath $dstCfg) { $null = Backup-File -FilePath $dstCfg -BackupDir $BackupDir -DryRun:$DryRun }
    $r2 = Merge-OpencodeJson -SourcePath $srcCfg -TargetPath $dstCfg -IncludeInstructions $IncludeDocs -DryRun:$DryRun
    $null = $MergedManifest.Add(@{ path = "opencode.json"; action = $r2.action; detail = $r2.detail })
}

function Write-Manifest {
    param([string]$TargetRoot, $ManifestData, [switch]$DryRun)
    $manifestPath = Join-Path $TargetRoot ".opencode\$MANIFEST_NAME"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path (Split-Path $manifestPath) -Force | Out-Null
        $ManifestData | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    }
}

function Read-Manifest {
    param([string]$TargetRoot)
    $manifestPath = Join-Path $TargetRoot ".opencode\$MANIFEST_NAME"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Remove-ManifestFile {
    param([string]$TargetRoot)
    $manifestPath = Join-Path $TargetRoot ".opencode\$MANIFEST_NAME"
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
}

function Remove-EmptyTreeDir {
    param([string]$Path, [switch]$DryRun)
    foreach ($sub in (Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
        Remove-EmptyTreeDir -Path $sub.FullName -DryRun:$DryRun
    }
    $hasItems = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hasItems) {
        if (-not $DryRun) { Remove-Item -LiteralPath $Path -Force }
        Write-Ok "清理空目录 $(Split-Path -Leaf $Path)"
    }
}

function Remove-EmptyCodeRddDirs {
    param([string]$TargetRoot, [switch]$DryRun)
    $topDirs = Get-ChildItem -LiteralPath $TargetRoot -Directory -Filter "rdd-*" -ErrorAction SilentlyContinue
    foreach ($top in $topDirs) { Remove-EmptyTreeDir -Path $top.FullName -DryRun:$DryRun }
    foreach ($s in @("commands", "agent", "tools")) {
        $p = Join-Path $TargetRoot ".opencode\$s"
        if (Test-Path -LiteralPath $p) { Remove-EmptyTreeDir -Path $p -DryRun:$DryRun }
    }
    $docsDir = Join-Path $TargetRoot "docs"
    if (Test-Path -LiteralPath $docsDir) { Remove-EmptyTreeDir -Path $docsDir -DryRun:$DryRun }
}

function Invoke-Install {
    param([string]$SourceRoot, [string]$TargetRoot, [string]$Mode, [string]$RolesParam, [switch]$NoDocs, [switch]$Force, [switch]$DryRun)
    Write-Step "codeRDD 安装 -> $TargetRoot (mode=$Mode)"
    if (-not (Test-GitRepo -Path $TargetRoot)) {
        Write-Err "目标不是 git 仓库（rdd-engine 依赖 git 定位根）: $TargetRoot"
        exit 1
    }
    if (Read-Manifest -TargetRoot $TargetRoot) { Write-Warn "已有安装记录。建议 -Update。继续将覆盖清单。" }
    $roles = Resolve-Roles -Mode $Mode -Roles $RolesParam
    Write-Step "角色: $($roles -join ', ')"
    $copied = New-Object System.Collections.ArrayList
    $merged = New-Object System.Collections.ArrayList
    $backupDir = Join-Path $TargetRoot ".opencode\$BACKUP_NAME"
    Copy-EngineAsset -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Manifest $copied -Force:$Force -DryRun:$DryRun
    Copy-RoleAssets -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Roles $roles -Manifest $copied -Force:$Force -DryRun:$DryRun
    Copy-InfraAssets -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Manifest $copied -Force:$Force -DryRun:$DryRun
    Merge-ConfigAssets -SourceRoot $SourceRoot -TargetRoot $TargetRoot -BackupDir $backupDir -IncludeDocs (-not $NoDocs) -MergedManifest $merged -DryRun:$DryRun
    $withDocs = $false
    if (-not $NoDocs) { $withDocs = Copy-DocsAsset -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Manifest $copied -DryRun:$DryRun }
    $manifestData = @{
        version = $SCRIPT_VERSION; installedAt = (Get-Date -Format "o")
        sourceRoot = $SourceRoot; sourceCommit = (Get-SourceCommit -SourceRoot $SourceRoot)
        mode = $Mode; roles = $roles; withDocs = $withDocs
        copied = $copied.ToArray(); merged = $merged.ToArray()
    }
    Write-Manifest -TargetRoot $TargetRoot -ManifestData $manifestData -DryRun:$DryRun
    Show-Summary -Copied $copied -Merged $merged -DryRun:$DryRun
}

function Invoke-Update {
    param([string]$SourceRoot, [string]$TargetRoot, [switch]$DryRun)
    $manifest = Read-Manifest -TargetRoot $TargetRoot
    if (-not $manifest) { Write-Err "未找到安装记录。请先安装。"; exit 1 }
    $useMode = $manifest.mode
    $useRoles = if ($manifest.roles) { ($manifest.roles -join ',') } else { "" }
    $useNoDocs = -not [bool]$manifest.withDocs
    Write-Step "更新 codeRDD (mode=$useMode roles=$useRoles)。改 mode/roles 请先 -Uninstall。"
    Remove-ManifestFile -TargetRoot $TargetRoot
    Invoke-Install -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Mode $useMode -RolesParam $useRoles -NoDocs:$useNoDocs -Force -DryRun:$DryRun
}

function Invoke-Uninstall {
    param([string]$TargetRoot, [switch]$DryRun)
    Write-Step "卸载 codeRDD -> $TargetRoot"
    $manifest = Read-Manifest -TargetRoot $TargetRoot
    if (-not $manifest) { Write-Err "未找到安装记录 (.opencode/$MANIFEST_NAME)，无法卸载"; exit 1 }
    $backupDir = Join-Path $TargetRoot ".opencode\$BACKUP_NAME"
    foreach ($m in $manifest.merged) {
        $leaf = Split-Path -Leaf $m.path
        $targetPath = Join-Path $TargetRoot ($m.path -replace '/', '\')
        $restored = Restore-Backup -FileName $leaf -BackupDir $backupDir -TargetPath $targetPath -DryRun:$DryRun
        if ($restored) { Write-Ok "还原 $($m.path) <- backup" }
        elseif (Test-Path -LiteralPath $targetPath) {
            if (-not $DryRun) { Remove-Item -LiteralPath $targetPath -Force }
            Write-Ok "删除 codeRDD 创建的 $($m.path)"
        }
    }
    $deleted = 0
    foreach ($c in $manifest.copied) {
        $targetPath = Join-Path $TargetRoot ($c.path -replace '/', '\')
        if (Test-Path -LiteralPath $targetPath) {
            if (-not $DryRun) { Remove-Item -LiteralPath $targetPath -Force }
            $deleted++
        }
    }
    Write-Ok "删除 $deleted 个 copied 文件"
    Remove-EmptyCodeRddDirs -TargetRoot $TargetRoot -DryRun:$DryRun
    if (-not $DryRun) {
        Remove-ManifestFile -TargetRoot $TargetRoot
        if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    }
    Write-Ok "卸载完成"
}

function Show-Summary {
    param($Copied, $Merged, [switch]$DryRun)
    $prefix = if ($DryRun) { "[DRYRUN] " } else { "" }
    $created = @($Copied | Where-Object { $_.action -eq "created" }).Count
    $overwritten = @($Copied | Where-Object { $_.action -eq "overwritten" }).Count
    $unchanged = @($Copied | Where-Object { $_.action -eq "unchanged" }).Count
    $skipped = @($Copied | Where-Object { $_.action -like "skipped*" }).Count
    Write-Host ""
    Write-Host "$prefix`安装摘要:" -ForegroundColor White
    Write-Host "  复制文件: +$created 新增, ~$overwritten 覆盖, =$unchanged 不变, ?$skipped 跳过"
    $mergedCount = @($Merged | Where-Object { $_.action -notlike "skipped*" -and $_.action -ne "unchanged" -and $_.action -ne "created" }).Count
    $mergedNew = @($Merged | Where-Object { $_.action -eq "created" }).Count
    Write-Host "  配置合并: $mergedCount 项变更, $mergedNew 项新建"
    if ($DryRun) { return }
    Write-Host ""
    Write-Host "依赖检查:" -ForegroundColor White
    $psVer = $PSVersionTable.PSVersion.ToString()
    Write-Host "  [+] PowerShell $psVer"
    $bun = Get-Command bun -ErrorAction SilentlyContinue
    if ($bun) { Write-Host "  [+] Bun $($bun.Source)" }
    else { Write-Host "  [!] 未检测到 Bun (plugin 需要) — https://bun.sh" }
    if ($PSVersionTable.Platform -ne "Win32NT") {
        $pwshErr = "pwsh 未配置为 Windows 默认"
    }
    Write-Host ""
    Write-Host "下一步:" -ForegroundColor White
    Write-Host "  cd <target>"
    Write-Host "  opencode"
    Write-Host "  /rdd-pm   (或 /rdd-cto /rdd-ux /rdd-dev)"
}

$SourceRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not (Test-Path (Join-Path $SourceRoot "rdd-engine"))) {
    Write-Err "找不到 rdd-engine/ 目录。install.ps1 必须位于 codeRDD 仓库根"
    exit 1
}
$TargetRoot = (Resolve-Path -LiteralPath $Target).Path
if ($SourceRoot -eq $TargetRoot) {
    Write-Err "目标与 codeRDD 源相同，不能安装到自身。请指定 -Target <other-project>"
    exit 1
}

if ($Uninstall) { Invoke-Uninstall -TargetRoot $TargetRoot -DryRun:$DryRun; exit 0 }
if ($Update) { Invoke-Update -SourceRoot $SourceRoot -TargetRoot $TargetRoot -DryRun:$DryRun; exit 0 }
Invoke-Install -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Mode $Mode -RolesParam $Roles -NoDocs:$NoDocs -Force:$Force -DryRun:$DryRun

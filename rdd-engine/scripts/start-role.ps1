[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE")]
    [string]$Role,

    [int]$TaskId = -1,
    [string]$TaskJson = "",
    [string]$Handoff = "",
    [string]$Project = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step { param([string]$Message); Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message); Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Err  { param([string]$Message); Write-Host "[x] $Message" -ForegroundColor Red; exit 1 }

function Resolve-ProjectRoot {
    if ($Project) {
        if (-not (Test-Path -LiteralPath $Project -PathType Container)) { Write-Err "项目根不存在: $Project" }
        return (Resolve-Path -LiteralPath $Project).Path
    }
    $root = $null
    try { $root = (git rev-parse --show-toplevel 2>$null) } catch { }
    if (-not $root) { Write-Err "不在 git 仓库内，请用 -Project 指定项目根" }
    return $root.Trim()
}

function Find-OpencodeExecutable {
    # 优先返回可直接执行的封装：.cmd / .exe / .bat
    # 跳过 .ps1 —— Windows 无法将 .ps1 作为 exe 直接启动（错误 0x800700c1）
    foreach ($name in @("opencode.cmd", "opencode.exe", "opencode.bat")) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { return $found.Name }
    }
    $oc = Get-Command opencode -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".ps1" } | Select-Object -First 1
    if ($oc) { return $oc.Name }
    return $null
}

function Resolve-AbsolutePath {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if (-not ([System.IO.Path]::IsPathRooted($Path))) {
        $Path = Join-Path $Root $Path
    }
    return (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
}

function Find-LatestTaskJson {
    param([string]$Root)
    $archiveRoot = Join-Path $Root ".rdd\changes\archive"
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container)) { return "" }
    $candidates = Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "task.json" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if (-not $candidates -or $candidates.Count -eq 0) { return "" }
    # 归档名以 YYYY-MM-DD 开头，按名降序取最新
    # Select-Object -First 1 避免 Sort-Object 单元素返回字符串后被 [0] 索引成字符
    return $candidates | Sort-Object -Descending | Select-Object -First 1
}

function Build-PromptMessage {
    # 优先级：Handoff 模式 > TaskId 模式 > 纯角色激活
    # 路径不套内层引号（避免 wt 参数解析中断）；LLM 按文本读取路径
    $roleLower = $Role.ToLower()
    $base = "/rdd-$roleLower"

    if (-not [string]::IsNullOrWhiteSpace($Handoff)) {
        $abs = Resolve-AbsolutePath -Path $Handoff -Root $root
        if (-not $abs) { Write-Err "Handoff 文件不存在: $Handoff" }
        return "$base handoff=$abs"
    }

    if ($TaskId -ge 1) {
        $taskJsonAbs = if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
            Resolve-AbsolutePath -Path $TaskJson -Root $root
        } else {
            Find-LatestTaskJson -Root $root
        }
        if (-not $taskJsonAbs) {
            Write-Err "未找到 task.json。请用 -TaskJson 显式指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        return "$base TaskId=$TaskId task=$taskJsonAbs"
    }

    return $base
}

function Test-WindowsTerminal { return [bool](Get-Command wt.exe -ErrorAction SilentlyContinue) }

function Start-WithWindowsTerminal {
    param([string]$Root, [string]$Message, [string]$Opencode)
    $wtArgs = "-d `"$Root`" $Opencode --prompt `"$Message`""
    Start-Process wt -ArgumentList $wtArgs
}

function Start-WithPowerShell {
    param([string]$Root, [string]$Message, [string]$Opencode)
    Start-Process -FilePath $Opencode -ArgumentList @("--prompt", $Message) -WorkingDirectory $Root
}

$root = Resolve-ProjectRoot
$opencode = Find-OpencodeExecutable
if (-not $opencode) { Write-Err "未找到 opencode（.cmd/.exe/.bat），请先安装 (npm install -g opencode-ai)" }

$message = Build-PromptMessage
$useWt = Test-WindowsTerminal

if ($DryRun) {
    Write-Host "[DRYRUN] 项目根:   $root" -ForegroundColor Yellow
    Write-Host "[DRYRUN] opencode: $opencode" -ForegroundColor Yellow
    Write-Host "[DRYRUN] 预填消息: $message" -ForegroundColor Yellow
    if ($useWt) {
        Write-Host "[DRYRUN] 终端:    Windows Terminal (wt.exe)" -ForegroundColor Yellow
    } else {
        Write-Host "[DRYRUN] 终端:    PowerShell 窗口 (wt.exe 不可用，降级)" -ForegroundColor Yellow
    }
    exit 0
}

Write-Step "为角色 $Role 开新窗口 ..."
if ($useWt) {
    Start-WithWindowsTerminal -Root $root -Message $message -Opencode $opencode
    Write-Ok "已开启 Windows Terminal 窗口"
} else {
    Start-WithPowerShell -Root $root -Message $message -Opencode $opencode
    Write-Ok "已开启 PowerShell 窗口"
}

Write-Host "[i] 预填消息: $message" -ForegroundColor Cyan
Write-Host "[i] 在新窗口按回车发送即可进入 $Role 角色" -ForegroundColor Cyan

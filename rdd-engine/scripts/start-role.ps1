[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE")]
    [string]$Role,

    [int]$TaskId = -1,
    [string]$TaskJson = "",
    [string]$Handoff = "",
    [string]$Project = "",
    [string]$EmployeeId = "",
    [string]$PlusUrl = "http://127.0.0.1:8000",
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

function Resolve-RuntimeMode {
    # Plus injects RDD_RUNTIME=app into the opencode server subprocess; that env
    # propagates to every agent/tool spawned inside the app (including this
    # script). A standalone CLI window has no such env var.
    # Returns "app" or "cli". This is the single source of truth for backend
    # selection — agents never judge the mode themselves.
    if ($env:RDD_RUNTIME -eq "app") { return "app" }
    return "cli"
}

function Resolve-TaskJsonAbsolute {
    # Shared by both backends: resolve the task.json path (explicit -TaskJson or
    # latest archive). Returns "" if none found.
    if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
        return Resolve-AbsolutePath -Path $TaskJson -Root $root
    }
    return Find-LatestTaskJson -Root $root
}

function Get-RelativePathFromRoot {
    # PS 5.1 (.NET Framework) lacks [System.IO.Path]::GetRelativePath, so compute
    # manually. Both inputs are absolute paths under the same root (drive). Returns
    # a forward-slashed relative path (empty if $AbsPath equals the root).
    param([string]$AbsPath, [string]$RootPath)
    if (-not $AbsPath) { return "" }
    $abs = (Resolve-Path -LiteralPath $AbsPath -ErrorAction SilentlyContinue).Path
    $base = (Resolve-Path -LiteralPath $RootPath -ErrorAction SilentlyContinue).Path
    if (-not $abs -or -not $base) { return ($AbsPath -replace '\\', '/') }
    $baseTrim = $base.TrimEnd('\', '/')
    if ($abs -ieq $baseTrim) { return "" }
    $baseWithSep = $baseTrim + '\'
    if ($abs.StartsWith($baseWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $abs.Substring($baseWithSep.Length)
    } else {
        $rel = $abs
    }
    return ($rel -replace '\\', '/')
}

function Resolve-ArchiveRelativePath {
    param([string]$TaskJsonAbs, [string]$RootPath)
    # Derive ".rdd/changes/archive/<name>" from the task.json location.
    # Forward slashes so the pointer message matches transition-guide B2 format.
    if (-not $TaskJsonAbs) { return "" }
    $parent = Split-Path -Parent $TaskJsonAbs
    $rel = Get-RelativePathFromRoot -AbsPath $parent -RootPath $RootPath
    if ($rel) { return "$rel/" }
    return ""
}

function Build-PlusMessage {
    # Plus binds the role SKILL via employee.agent_mode, so the slash command
    # form does NOT work (opencode server prompt API doesn't parse TUI commands).
    # Instead emit the app-layer pointer message (transition-guide entry B2/C),
    # which the role's SKILL recognizes and pulls handoff from.
    $taskJsonAbs = Resolve-TaskJsonAbsolute
    if (-not $taskJsonAbs) {
        Write-Err "Plus 模式需要 task.json 来定位归档。请用 -TaskJson 指定，或确保 .rdd/changes/archive/ 下有归档。"
    }
    $archiveRel = Resolve-ArchiveRelativePath -TaskJsonAbs $taskJsonAbs -RootPath $root
    if (-not $archiveRel) { Write-Err "无法从 task.json 路径推导归档相对路径: $taskJsonAbs" }

    $msg = "请处理 $archiveRel 下的需求。"
    if (-not [string]::IsNullOrWhiteSpace($Handoff)) {
        $handoffAbs = Resolve-AbsolutePath -Path $Handoff -Root $root
        if ($handoffAbs) {
            $handoffRel = Get-RelativePathFromRoot -AbsPath $handoffAbs -RootPath $root
            $msg += "（交接包: $handoffRel）"
        }
    }
    return $msg
}

function Invoke-PlusHandoff {
    param([string]$Message)
    # POST to Plus; returns $null on connection failure (caller falls back to CLI).
    if (-not $EmployeeId) {
        Write-Err "Plus 模式必须提供 -EmployeeId（目标角色对应的员工 UUID）。"
    }
    $uri = "$PlusUrl/api/rdd/handoff"
    $bodyObj = @{
        project_path = $root
        employee_id  = $EmployeeId
        message      = $Message
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Compress

    if ($DryRun) {
        Write-Host "[DRYRUN] Plus POST $uri" -ForegroundColor Yellow
        Write-Host "[DRYRUN] body: $bodyJson" -ForegroundColor Yellow
        return @{ conversation_id = "<dryrun>"; queued = $false; position = 1 }
    }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json; charset=utf-8" -Body $bodyJson -TimeoutSec 10
        return $resp
    } catch {
        $ex = $_.Exception
        # Distinguish "Plus reachable but rejected" (HTTP 4xx/5xx, has a Response)
        # from "Plus unreachable" (connection refused / timeout, no Response).
        $httpResponse = $null
        if ($ex -is [System.Net.WebException]) { $httpResponse = $ex.Response }
        elseif ($ex.PSObject.Properties['Response']) { $httpResponse = $ex.Response }
        if ($httpResponse) {
            $code = "?"
            try { $code = [int]$httpResponse.StatusCode } catch { }
            Write-Err "Plus handoff 失败 (HTTP $code): $($ex.Message)"
        }
        # No HTTP response → connection-level failure. Caller falls back to CLI.
        return $null
    }
}

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
$mode = Resolve-RuntimeMode

# --- Plus backend -----------------------------------------------------------
# When running inside the app (RDD_RUNTIME=app), drive the target role's
# conversation via Plus's handoff endpoint instead of spawning an external
# terminal window. On connection failure, fall back to the CLI backend so the
# user is never blocked (the env marker can leak into a standalone shell).
if ($mode -eq "app") {
    $plusMessage = Build-PlusMessage
    Write-Step "检测到 Plus 运行时，向应用层交接角色 $Role ..."
    $result = Invoke-PlusHandoff -Message $plusMessage
    if ($result) {
        $conv = $result.conversation_id
        $queued = [bool]$result.queued
        if ($queued) {
            Write-Ok "已加入队列（位置 $($result.position)），将在当前会话结束后启动 $Role"
        } else {
            Write-Ok "已在 Plus 内为 $Role 开启对话 ($conv)"
        }
        Write-Host "[i] 指针消息: $plusMessage" -ForegroundColor Cyan
        Write-Host "[i] 请在应用层切换到该员工查看对话" -ForegroundColor Cyan
        exit 0
    }
    Write-Host "[!] Plus 后端不可达（$PlusUrl），降级为 CLI 开窗" -ForegroundColor Yellow
}

# --- CLI backend (default / fallback) --------------------------------------
$opencode = Find-OpencodeExecutable
if (-not $opencode) { Write-Err "未找到 opencode（.cmd/.exe/.bat），请先安装 (npm install -g opencode-ai)" }

$message = Build-PromptMessage
$useWt = Test-WindowsTerminal

if ($DryRun) {
    Write-Host "[DRYRUN] 模式:      $mode (cli backend)" -ForegroundColor Yellow
    Write-Host "[DRYRUN] 项目根:    $root" -ForegroundColor Yellow
    Write-Host "[DRYRUN] opencode:  $opencode" -ForegroundColor Yellow
    Write-Host "[DRYRUN] 预填消息:  $message" -ForegroundColor Yellow
    if ($useWt) {
        Write-Host "[DRYRUN] 终端:     Windows Terminal (wt.exe)" -ForegroundColor Yellow
    } else {
        Write-Host "[DRYRUN] 终端:     PowerShell 窗口 (wt.exe 不可用，降级)" -ForegroundColor Yellow
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

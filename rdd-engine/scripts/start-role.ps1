[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE", "MANAGER")]
    [string]$Role,

    [int]$TaskId = -1,
    [string]$TaskJson = "",
    [string]$Handoff = "",
    [string]$RunId = "",
    [string]$Project = "",
    [string]$EmployeeId = "",
    [string]$PlusUrl = "http://127.0.0.1:8000",
    [string]$DshUrl = "",
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

    # MANAGER 自举式指针：Manager 是引擎编排形态而非角色卡（无 /rdd-manager
    # 斜杠命令可加载），CLI 预填消息本身携带身份引导——指向 manager-guide.md。
    if ($Role -eq "MANAGER") {
        if (-not [string]::IsNullOrWhiteSpace($RunId)) {
            return "你是 RDD Manager。先读 rdd-engine/references/manager-guide.md，然后执行 delivery-bridge resume -RunId $RunId 续跑交付。"
        }
        $taskJsonAbs = if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
            Resolve-AbsolutePath -Path $TaskJson -Root $root
        } else {
            Find-LatestTaskJson -Root $root
        }
        if (-not $taskJsonAbs) {
            Write-Err "未找到 task.json。请用 -TaskJson 显式指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        return "你是 RDD Manager。先读 rdd-engine/references/manager-guide.md，然后用 delivery-bridge promulgate -TaskJson $taskJsonAbs 接管该归档的整批交付。"
    }

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
    # script). A dsh (Web GUI) session instead injects DSH_WEB_URL — the local
    # URL of the Web GUI serving this session — into every shell subprocess.
    # Returns "app", "dsh", or "cli". The chain order is fixed and is the
    # single source of truth for backend selection — agents never judge the
    # mode themselves. RDD_RUNTIME wins so a leaked Plus marker can never
    # reroute a dsh/CLI handoff.
    if ($env:RDD_RUNTIME -eq "app") { return "app" }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_WEB_URL)) { return "dsh" }
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

function Build-PointerMessage {
    # App-driven backends (Plus, dsh) bind the role SKILL via the employee's
    # agent_mode / the rdd-<role> agent preset, so the slash command form does
    # NOT work there. Instead emit the app-layer pointer message
    # (transition-guide entry B2/C), which the role's SKILL recognizes and
    # pulls handoff from.
    #
    # MANAGER variant: bootstrap pointer (no role card exists to bind) — the
    # message itself names the Manager identity and the first-read document
    # (manager-guide.md), plus the concrete bridge command for takeover/resume.
    if ($Role -eq "MANAGER") {
        if (-not [string]::IsNullOrWhiteSpace($RunId)) {
            return "请以 Manager 身份续跑 goal-tree 交付 run ${RunId}：先读 rdd-engine/references/manager-guide.md，随后执行 delivery-bridge -Command resume -RunId $RunId 按断点续跑。"
        }
        $taskJsonAbs = Resolve-TaskJsonAbsolute
        if (-not $taskJsonAbs) {
            Write-Err "应用层交接（Plus/dsh 后端）需要 task.json 来定位归档。请用 -TaskJson 指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        $archiveRel = Resolve-ArchiveRelativePath -TaskJsonAbs $taskJsonAbs -RootPath $root
        if (-not $archiveRel) { Write-Err "无法从 task.json 路径推导归档相对路径: $taskJsonAbs" }
        return "请以 Manager 身份接管 ${archiveRel}的整批交付：先读 rdd-engine/references/manager-guide.md，随后执行 delivery-bridge -Command promulgate -TaskJson $taskJsonAbs 颁布交付节点并按需调动角色会话。"
    }

    $taskJsonAbs = Resolve-TaskJsonAbsolute
    if (-not $taskJsonAbs) {
        Write-Err "应用层交接（Plus/dsh 后端）需要 task.json 来定位归档。请用 -TaskJson 指定，或确保 .rdd/changes/archive/ 下有归档。"
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

function ConvertTo-DshRequestJson {
    # Serialize one client-request envelope for the dsh /api carrier.
    param([string]$Method, [hashtable]$Payload)
    $envelope = @{
        type    = "client-request"
        rpcId   = [guid]::NewGuid().ToString()
        method  = $Method
        payload = $Payload
    }
    return $envelope | ConvertTo-Json -Depth 8 -Compress
}

function Send-DshHttpPost {
    # Transport for one /api RPC: POST the envelope and return the response
    # body text. Both directions carry UTF-8 bytes explicitly — PS 5.1 sends
    # string bodies as Latin-1 (garbling the Chinese pointer message), and its
    # Invoke-RestMethod decodes a charset-less application/json response as
    # Latin-1 too (the server sends no charset), so raw HttpWebRequest handles
    # both here. Connection/carrier failures throw to the caller.
    param([string]$Uri, [string]$Json)
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = "POST"
    $req.ContentType = "application/json; charset=utf-8"
    $req.Timeout = 10000
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $req.ContentLength = $bodyBytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    try {
        $rs = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        $rs.CopyTo($ms)
        $rs.Close()
    } finally { $resp.Close() }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Get-DshFailureStatus {
    # Classify a transport exception into the unreachable result: keep the HTTP
    # status when the server answered (e.g. trust-fence 403), otherwise name the
    # transport status alongside the message. PS 5.1 reports a failed .NET call
    # as a MethodInvocationException wrapping the WebException, so .Status and
    # .Response are read from the inner chain — the caught exception itself
    # carries neither.
    param([System.Exception]$Exception)
    $webError = $Exception
    while ($webError -and -not ($webError -is [System.Net.WebException])) {
        $webError = $webError.InnerException
    }
    if (-not $webError) {
        return @{ status = "unreachable"; message = $Exception.Message; httpStatus = 0 }
    }
    $transportStatus = [string]$webError.Status
    $httpStatus = 0
    if ($webError.Response) {
        try { $httpStatus = [int]$webError.Response.StatusCode } catch { }
    }
    if ($httpStatus) {
        return @{ status = "unreachable"; message = $webError.Message; httpStatus = $httpStatus }
    }
    return @{ status = "unreachable"; message = "$($webError.Message) ($transportStatus)"; httpStatus = 0 }
}

function Invoke-DshApi {
    # One RPC over the dsh /api fetch carrier: a client-request envelope POSTed
    # to $DshUrl/api/<method>. Business errors arrive as HTTP 200 + ok:false;
    # connection/carrier failures throw in the transport. Returns one of:
    #   @{ status = "ok";         value = <business value> }
    #   @{ status = "business";   code; message; details }   server ok:false
    #   @{ status = "unreachable"; message; httpStatus }     not reachable / carrier refused
    param([string]$Method, [hashtable]$Payload)
    $json = ConvertTo-DshRequestJson -Method $Method -Payload $Payload
    try {
        $text = Send-DshHttpPost -Uri "$DshUrl/api/$Method" -Json $json
        $parsed = $text | ConvertFrom-Json
    } catch {
        return Get-DshFailureStatus -Exception $_.Exception
    }
    $result = $parsed.result
    if ($result.ok) { return @{ status = "ok"; value = $result.value } }
    return @{ status = "business"; code = [string]$result.error.code; message = [string]$result.error.message; details = $result.error.details }
}

function Invoke-DshHandoff {
    # Four-shot dsh handoff over the /api carrier: preset pre-check,
    # workspace resolve-or-create, workspace-scoped session.create, then
    # queue-mode session.prompt with the B2 pointer message. The server still
    # mints a random sessionId (never hits the live-reuse or resume branches).
    # The workspace attach puts the new session inside its project folder in
    # the Web GUI sidebar — a cwd-only create joins no workspace account, so
    # it trails in the sidebar's Ungrouped section instead. An accepted prompt
    # wakes the driver so the target role runs its full turn without further
    # user action.
    param([string]$Message, [string]$Preset)

    $list = Invoke-DshApi -Method "agentPreset.list" -Payload @{}
    if ($list.status -ne "ok") { return $list }
    $availablePresets = @($list.value.presets | ForEach-Object { $_.id })
    if ($availablePresets -notcontains $Preset) {
        return @{ status = "preset-missing"; preset = $Preset; availablePresets = $availablePresets }
    }

    # Resolve-or-create (realpath-normalized, idempotent): same step the GUI's
    # New Session flow relies on, so the handoff session lands in the project's
    # workspace folder rather than Ungrouped.
    $ws = Invoke-DshApi -Method "workspace.create" -Payload @{ path = $root }
    if ($ws.status -ne "ok") { return $ws }
    $workspaceId = [string]$ws.value.workspace.workspaceId

    $create = Invoke-DshApi -Method "session.create" -Payload @{ workspaceId = $workspaceId; agentPreset = $Preset }
    if ($create.status -ne "ok") { return $create }
    $sessionId = [string]$create.value.sessionId

    $prompt = Invoke-DshApi -Method "session.prompt" -Payload @{
        sessionId = $sessionId
        mode      = "queue"
        content   = @(@{ type = "text"; text = $Message })
    }
    if ($prompt.status -ne "ok") {
        return @{ status = "prompt-failed"; sessionId = $sessionId; failure = $prompt }
    }
    return @{ status = "done"; sessionId = $sessionId }
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
    $plusMessage = Build-PointerMessage
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

# --- dsh backend ------------------------------------------------------------
# Inside a dsh Web GUI session (DSH_WEB_URL injected by the harness into shell
# subprocesses), drive the target role through the GUI's own /api carrier:
# resolve-or-create the project workspace, create a session bound to the
# rdd-<role> preset inside it (the GUI's own New Session path), then send the
# B2 pointer message. No external window opens; the new session appears inside
# the project's workspace folder in the Web GUI sidebar. Failures never fall
# back to the CLI backend — a local terminal window is useless to a Web GUI
# user: unreachable → error + manual guidance, business error → error code,
# prompt-failed → pointer message for manual paste into the already-created
# session.
if ($mode -eq "dsh") {
    if ([string]::IsNullOrWhiteSpace($DshUrl)) { $DshUrl = $env:DSH_WEB_URL }
    if ([string]::IsNullOrWhiteSpace($DshUrl)) {
        Write-Err "dsh 模式需要 Web GUI 服务地址：设置 DSH_WEB_URL 环境变量或传 -DshUrl。"
    }
    $DshUrl = $DshUrl.TrimEnd('/')
    if (-not [string]::IsNullOrWhiteSpace($EmployeeId)) {
        Write-Host "[i] -EmployeeId 属 Plus 语义，dsh 后端不适用，已忽略。" -ForegroundColor Yellow
    }

    $pointerMessage = Build-PointerMessage
    $preset = "rdd-" + $Role.ToLower()

    if ($DryRun) {
        Write-Host "[DRYRUN] 模式:    dsh backend ($DshUrl)" -ForegroundColor Yellow
        Write-Host "[DRYRUN] 项目根:  $root" -ForegroundColor Yellow
        Write-Host "[DRYRUN] preset:  $preset（经 agentPreset.list 预检存在性）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 1:   POST $DshUrl/api/workspace.create" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: path=$root（resolve-or-create，realpath 规范化）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 2:   POST $DshUrl/api/session.create" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: workspaceId=<RPC 1 返回> agentPreset=$preset（入账 workspace，侧栏进项目文件夹）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 3:   POST $DshUrl/api/session.prompt" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: sessionId=<RPC 2 返回> mode=queue text=$pointerMessage" -ForegroundColor Yellow
        exit 0
    }

    Write-Step "检测到 dsh 运行时（$DshUrl），为角色 $Role 自动创建会话 ..."
    $result = Invoke-DshHandoff -Message $pointerMessage -Preset $preset
    switch ($result.status) {
        "done" {
            Write-Ok "已在 dsh 内为 $Role 创建会话（preset: $preset, sessionId: $($result.sessionId)）"
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            Write-Host "[i] 新会话已出现在 Web GUI 侧栏，目标角色已自动开工，可点开查看进度" -ForegroundColor Cyan
            exit 0
        }
        "preset-missing" {
            $availableText = ($result.availablePresets) -join ", "
            Write-Err "目标角色 preset 不存在: $($result.preset)。可用 preset: $availableText"
        }
        "business" {
            $detailsText = ""
            try { $detailsText = " details: $($result.details | ConvertTo-Json -Depth 6 -Compress)" } catch { }
            Write-Err "dsh 交接失败（业务错误 $($result.code)）: $($result.message)$detailsText"
        }
        "prompt-failed" {
            $failure = $result.failure
            if ($failure.status -eq "business") {
                $reason = "业务错误 $($failure.code): $($failure.message)"
            } else {
                $reason = $failure.message
            }
            Write-Host "[x] 会话已创建（$($result.sessionId)）但指针消息发送失败: $reason" -ForegroundColor Red
            Write-Host "[!] 可在 Web GUI 侧栏点开该会话，手动粘贴发送下面的指针消息：" -ForegroundColor Yellow
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            exit 1
        }
        "unreachable" {
            Write-Host "[x] dsh 服务不可达（$DshUrl）: $($result.message)" -ForegroundColor Red
            if ($result.httpStatus -eq 403) {
                Write-Host "[i] HTTP 403：Host 不在信任栅栏内。DSH_WEB_URL 指向非 loopback 地址时，需在 dsh 启动时以 --trusted-host 声明该地址。" -ForegroundColor Cyan
            }
            Write-Host "[!] 人工回退：在 Web GUI 侧栏新建会话并选择 preset $preset，粘贴发送下面的指针消息：" -ForegroundColor Yellow
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            exit 1
        }
        default {
            Write-Err "dsh 交接返回未知结果: $($result.status)"
        }
    }
}

# --- CLI backend (default / Plus fallback) ----------------------------------
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

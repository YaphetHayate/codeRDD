# role-handoff 集成测试 — 关联需求：2026-08-30-rdd-dsh-auto-handoff
# 被测对象：rdd-engine/scripts/start-role.ps1（dsh 后端 + CLI/Plus 回归）、
#           rdd-engine/references/transition-guide.md、各角色 SKILL.md、
#           scripts/build-dsh-presets.mjs（persona 生成与加固闸②）、
#           scripts/install-rdd-skills.ps1（加固闸①③）
# 运行：powershell -NoProfile -ExecutionPolicy Bypass -File .rdd\tests\role-handoff\run-tests.ps1
#
# 架构：
#   - 子进程调用 start-role.ps1（与 start-role.cmd 相同的 powershell 5.1 启动方式），
#     stdout/stderr 经 PowerShell 自身管道重定向捕获（UTF-8）；项目根用夹具目录
#     （临时目录 + .rdd/changes/archive/<fixture>/task.json）经 -Project 注入，
#     被测脚本因此不依赖任何真实归档
#   - dsh /api 载波由进程内 Runspace + TcpListener 模拟（HttpListener 在部分平台不可用），
#     按 server-response envelope 回包，逐请求落盘日志供断言
#   - 文档/生成物/落点一致性用例（AC-6/AC-7/AC-8 + 加固闸①②③）以参数指向源仓、
#     $DSH_HOME 与同级项目副本；机器无关的负向用例（伪造仓 / 旧 tarball / 临时 DshHome）
#     在临时目录内自建夹具
#
# 生效面用例（AC-7/AC-8）依赖本机安装形态：$DSH_HOME\.agent-presets 未安装或
# 同级目录下没有项目副本时记为 SKIP，不计失败。

[CmdletBinding()]
param(
    [string]$DshHome = '',
    [string]$PeerProjectsRoot = ''
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# $PSScriptRoot = <repo>\.rdd\tests\role-handoff
$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' } }
if (-not $PeerProjectsRoot) { $PeerProjectsRoot = Split-Path -Parent $RepoRoot }

$ScriptPath = Join-Path $RepoRoot 'rdd-engine\scripts\start-role.ps1'
$CmdPath = Join-Path $RepoRoot 'rdd-engine\scripts\start-role.cmd'
$TransitionGuide = Join-Path $RepoRoot 'rdd-engine\references\transition-guide.md'
$GeneratorPath = Join-Path $RepoRoot 'scripts\build-dsh-presets.mjs'
$InstallerPath = Join-Path $RepoRoot 'scripts\install-rdd-skills.ps1'
$SkillsTarball = Join-Path $RepoRoot 'dist\skills\rdd-skills.tgz'
$PresetLanding = Join-Path $DshHome '.agent-presets'
$PresetSourceRoot = Join-Path $RepoRoot 'dsh\presets'

$Roles = @('pm', 'cto', 'ux', 'dev', 'qa', 'eval', 'pse')
$ChainRoles = @('pm', 'cto', 'ux', 'dev', 'qa')
$LegacyPhrase = '新建目标角色会话'
$FixtureName = 'role-handoff-fixture'

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rdd-handoff-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $WorkDir | Out-Null

# 夹具项目根：被测脚本只要求 task.json 存在并可推导归档相对路径
$FixtureRoot = Join-Path $WorkDir 'project'
$TaskJson = Join-Path $FixtureRoot ".rdd\changes\archive\$FixtureName\task.json"
New-Item -ItemType Directory -Path (Split-Path -Parent $TaskJson) -Force | Out-Null
[System.IO.File]::WriteAllText($TaskJson, '{ "archive": "role-handoff-fixture", "version": 1, "tasks": [] }', (New-Object System.Text.UTF8Encoding($false)))
$ArchivePointer = "请处理 .rdd/changes/archive/$FixtureName/ 下的需求。"

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Tc, [string]$Title, [string]$Status, [string]$Detail)
    $script:Results.Add([pscustomobject]@{ Tc = $Tc; Title = $Title; Status = $Status; Detail = $Detail })
}

function Join-Lines {
    param($Items, [string]$Sep = "; ")
    return (($Items | Where-Object { $_ }) -join $Sep)
}

function Get-FileText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Test-ReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# --- 子进程调用 ---------------------------------------------------------------

function Invoke-StartRole {
    # 以 start-role.cmd 同款 powershell 5.1 启动方式运行被测脚本。
    # $EnvOverrides: @{ DSH_WEB_URL = "http://..." } 覆盖；值 $null 表示删除该变量。
    param([string[]]$RoleArgs, [hashtable]$EnvOverrides = @{}, [string]$Tag = "run")

    $names = @("DSH_WEB_URL", "RDD_RUNTIME")
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n) }
    try {
        foreach ($k in $EnvOverrides.Keys) {
            if ($null -eq $EnvOverrides[$k]) { Remove-Item -Path ("Env:\" + $k) -ErrorAction SilentlyContinue }
            else { Set-Item -Path ("Env:\" + $k) -Value $EnvOverrides[$k] }
        }
        $out = Join-Path $WorkDir "$Tag.out.txt"
        $err = Join-Path $WorkDir "$Tag.err.txt"
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @RoleArgs 1> $out 2> $err
        $ErrorActionPreference = $prevEap
        $code = $LASTEXITCODE
        return @{
            exit   = $code
            stdout = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8)
            stderr = [System.IO.File]::ReadAllText($err, [System.Text.Encoding]::UTF8)
        }
    }
    finally {
        foreach ($n in $names) {
            if ($null -ne $saved[$n]) { Set-Item -Path ("Env:\" + $n) -Value $saved[$n] }
            else { Remove-Item -Path ("Env:\" + $n) -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-Installer {
    param([string[]]$InstallerArgs, [string]$Tag = "install")
    $out = Join-Path $WorkDir "$Tag.out.txt"
    $err = Join-Path $WorkDir "$Tag.err.txt"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallerPath @InstallerArgs 1> $out 2> $err
    $ErrorActionPreference = $prevEap
    $code = $LASTEXITCODE
    return @{
        exit   = $code
        stdout = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8)
        stderr = [System.IO.File]::ReadAllText($err, [System.Text.Encoding]::UTF8)
    }
}

function Invoke-Node {
    param([string[]]$NodeArgs, [string]$Tag = "node")
    $out = Join-Path $WorkDir "$Tag.out.txt"
    $err = Join-Path $WorkDir "$Tag.err.txt"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & node @NodeArgs 1> $out 2> $err
    $ErrorActionPreference = $prevEap
    $code = $LASTEXITCODE
    return @{
        exit   = $code
        stdout = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8)
        stderr = [System.IO.File]::ReadAllText($err, [System.Text.Encoding]::UTF8)
        all    = ([System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8) + [System.IO.File]::ReadAllText($err, [System.Text.Encoding]::UTF8))
    }
}

# --- mock dsh /api 载波 --------------------------------------------------------

# mock 循环运行于独立 Runspace；场景配置与请求日志经文件交换。
$MockScript = @'
param([string]$ConfigPath)
$cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$utf8 = New-Object System.Text.UTF8Encoding($false)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$server = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$server.Start()
$port = ($server.LocalEndpoint).Port
[System.IO.File]::WriteAllText($cfg.readyFile, "$port")
$counters = @{}
function Resolve-Value {
    param($Rule, [string]$Method)
    if ($Rule.kind -eq "seq") {
        $i = 0
        if ($counters.ContainsKey($Method)) { $i = $counters[$Method] }
        $counters[$Method] = $i + 1
        return @{ kind = "ok"; value = $Rule.values[$i % $Rule.values.Count] }
    }
    return $Rule
}
try {
    while (-not (Test-Path -LiteralPath $cfg.stopFile)) {
        if (-not $server.Pending()) { Start-Sleep -Milliseconds 25; continue }
        $client = $server.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 15000
            $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 8192
            $raw = ""
            $headerLen = -1
            $contentLen = 0
            while ($true) {
                if ($headerLen -lt 0) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $ms.Write($buf, 0, $n)
                    $raw = $latin1.GetString($ms.ToArray())
                    $idx = $raw.IndexOf("`r`n`r`n")
                    if ($idx -ge 0) {
                        $headerLen = $idx + 4
                        if ($raw -match "(?im)^Content-Length:\s*(\d+)") { $contentLen = [int]$Matches[1] }
                    }
                }
                else {
                    $need = $headerLen + $contentLen - $ms.Length
                    if ($need -le 0) { break }
                    $n = $stream.Read($buf, 0, [Math]::Min($need, $buf.Length))
                    if ($n -le 0) { break }
                    $ms.Write($buf, 0, $n)
                }
            }
            if ($headerLen -lt 0) { continue }
            $reqLine = ($latin1.GetString($ms.ToArray(), 0, $headerLen) -split "`r`n")[0]
            $path = ($reqLine -split " ")[1]
            $bodyText = [System.Text.Encoding]::UTF8.GetString($ms.ToArray(), $headerLen, $ms.Length - $headerLen)
            $envelope = $bodyText | ConvertFrom-Json
            $method = $envelope.method
            $entry = @{ path = $path; method = $method; rpcId = $envelope.rpcId; payload = $envelope.payload }
            [System.IO.File]::AppendAllText($cfg.logFile, (($entry | ConvertTo-Json -Depth 10 -Compress) + "`n"), $utf8)
            $rule = $null
            if ($cfg.responses.PSObject.Properties[$method]) { $rule = $cfg.responses.$method }
            if ($null -eq $rule) { $rule = @{ kind = "ok"; value = @{} } }
            $resolved = Resolve-Value -Rule $rule -Method $method
            if ($resolved.kind -eq "status") {
                # 传输层拒绝（如信任栅栏 403）：回原始 HTTP 状态而非 200 envelope，
                # 让调用方走 WebException 分支而不是业务错误分支
                $errObj = @{ ok = $false; error = @{ code = $resolved.code; message = $resolved.message; details = @{} } }
                $body = [System.Text.Encoding]::UTF8.GetBytes(($errObj | ConvertTo-Json -Depth 10 -Compress))
                $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $($resolved.status) $($resolved.reason)`r`nContent-Type: application/json`r`nContent-Length: " + $body.Length + "`r`nConnection: close`r`n`r`n")
            }
            else {
                $result = if ($resolved.kind -eq "error") {
                    @{ ok = $false; error = @{ code = $resolved.code; message = $resolved.message; details = @{} } }
                }
                else { @{ ok = $true; value = $resolved.value } }
                $respObj = @{ type = "server-response"; rpcId = $envelope.rpcId; result = $result }
                $respJson = $respObj | ConvertTo-Json -Depth 10 -Compress
                $body = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: " + $body.Length + "`r`nConnection: close`r`n`r`n")
            }
            $stream.Write($head, 0, $head.Length)
            $stream.Write($body, 0, $body.Length)
        }
        finally { $client.Close() }
    }
}
finally {
    $server.Stop()
    [System.IO.File]::WriteAllText($cfg.doneFile, "done")
}
'@

function New-MockServer {
    # $Responses: @{ "agentPreset.list" = @{ kind="ok"; value=@{...} }; ... }
    # 返回 @{ Port; Log(读日志); Stop() }
    param([hashtable]$Responses, [string]$Tag)

    $cfgPath = Join-Path $WorkDir "$Tag.cfg.json"
    $logFile = Join-Path $WorkDir "$Tag.log.jsonl"
    $readyFile = Join-Path $WorkDir "$Tag.ready"
    $stopFile = Join-Path $WorkDir "$Tag.stop"
    $doneFile = Join-Path $WorkDir "$Tag.done"
    $respObj = @{}
    foreach ($k in $Responses.Keys) { $respObj[$k] = $Responses[$k] }
    $cfg = @{ responses = $respObj; logFile = $logFile; readyFile = $readyFile; stopFile = $stopFile; doneFile = $doneFile }
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

    $ps = [powershell]::Create()
    $ps.AddScript($MockScript).AddArgument($cfgPath) | Out-Null
    $handle = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $readyFile)) { throw "mock server 未就绪: $Tag" }
    $port = [int]([System.IO.File]::ReadAllText($readyFile)).Trim()

    # GetNewClosure：让 Log/Stop 捕获本函数内的 $logFile/$stopFile/$ps/$handle
    $logBlock = {
        $entries = @()
        if (Test-Path -LiteralPath $logFile) {
            foreach ($line in [System.IO.File]::ReadAllLines($logFile, [System.Text.Encoding]::UTF8)) {
                if ($line.Trim()) { $entries += ($line | ConvertFrom-Json) }
            }
        }
        return $entries
    }.GetNewClosure()
    $stopBlock = {
        Set-Content -Path $stopFile -Value "stop"
        $deadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path -LiteralPath $doneFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        try { $ps.EndInvoke($handle) } catch { }
        $ps.Dispose()
    }.GetNewClosure()
    return @{ Port = $port; Log = $logBlock; Stop = $stopBlock }
}

function Read-MockLog {
    param($Mock)
    return & $Mock.Log
}

# --- 通用断言 -------------------------------------------------------------------

function Assert-All {
    param([string]$Tc, [string]$Title, [object[]]$Checks)
    # $Checks: @{ name; ok; actual } 失败时逐条列出
    $failed = @($Checks | Where-Object { -not $_.ok })
    $ok = $failed.Count -eq 0
    $detail = ""
    if (-not $ok) {
        $detail = Join-Lines ($failed | ForEach-Object { "$($_.name): 实际=$($_.actual)" })
    }
    Add-Result -Tc $Tc -Title $Title -Status $(if ($ok) { "PASS" } else { "FAIL" }) -Detail $detail
}

# --- TC-065 边界 AC-1：PS 5.1 兼容守护（BOM + 5.1 启动） --------------------------

function Test-BomGuard {
    $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $installerBytes = [System.IO.File]::ReadAllBytes($InstallerPath)
    $installerBom = ($installerBytes.Length -ge 3 -and $installerBytes[0] -eq 0xEF -and $installerBytes[1] -eq 0xBB -and $installerBytes[2] -eq 0xBF)
    $cmdText = Get-FileText $CmdPath
    Assert-All "TC-065" "start-role.ps1 带 UTF-8 BOM 且 .cmd 走 powershell 5.1" @(
        @{ name = "start-role.ps1 首三字节 EF BB BF"; ok = $hasBom; actual = if ($hasBom) { "BOM 存在" } else { "无 BOM（PS5.1 按 GBK 解析中文会语法错误）" } }
        @{ name = "start-role.cmd 用 powershell 启动"; ok = ($cmdText -match "powershell\s+-NoProfile"); actual = $cmdText.Trim() }
        @{ name = "install-rdd-skills.ps1 带 UTF-8 BOM"; ok = $installerBom; actual = "无 BOM：PS5.1 按 GBK 解码中文，加固闸③ 的中文匹配会静默失效" }
    )
}

# --- TC-060 边界 AC-2：用户确认语义保留 -------------------------------------------

function Test-ConfirmationRetained {
    $guide = Get-FileText $TransitionGuide
    Assert-All "TC-060" "transition-guide Step3 推荐后须用户确认、Step4 明示确认后调用" @(
        @{ name = "Step 3 标题含「请求用户确认」"; ok = ($guide -match "Step 3.*请求用户确认"); actual = "缺 Step3 确认标题" }
        @{ name = "Step 4 标题含「用户确认后」"; ok = ($guide -match "Step 4.*用户确认后"); actual = "缺 Step4 确认前置" }
    )
}

# --- TC-055 正向 AC-6：文档同步且无旧式人工指引残留 ------------------------------

function Test-DocsSynced {
    $guide = Get-FileText $TransitionGuide
    $checks = @(
        @{ name = "transition-guide 含 DSH_WEB_URL 判据"; ok = ($guide -match "DSH_WEB_URL"); actual = "未提及 DSH_WEB_URL" }
        @{ name = "transition-guide 含 dsh 后端四连发描述"; ok = ($guide -match "agentPreset\.list" -and $guide -match "workspace\.create" -and $guide -match "session\.create" -and $guide -match "session\.prompt"); actual = "四连发方法名不齐" }
        @{ name = "transition-guide 含失败回退（不降级 CLI）"; ok = ($guide -match "不降级 CLI"); actual = "缺失败回退语义" }
    )
    foreach ($r in $ChainRoles) {
        $text = Get-FileText (Join-Path $RepoRoot "rdd-$r\SKILL.md")
        $updated = ($text -match "start-role\.cmd") -and ($text -match "DSH_WEB_URL")
        $checks += @{ name = "rdd-$r SKILL 含脚本自动建会话指引"; ok = $updated; actual = "rdd-$r SKILL 未更新" }
    }
    foreach ($r in @("eval", "pse")) {
        $text = Get-FileText (Join-Path $RepoRoot "rdd-$r\SKILL.md")
        $checks += @{ name = "rdd-$r SKILL 入口 B2 表述含 dsh"; ok = ($text -match "dsh"); actual = "rdd-$r SKILL 未更新" }
    }
    foreach ($r in $Roles) {
        $text = Get-FileText (Join-Path $RepoRoot "rdd-$r\SKILL.md")
        $checks += @{ name = "rdd-$r SKILL 无旧式人工指引残留"; ok = (-not $text.Contains($LegacyPhrase)); actual = "残留旧指引" }
    }
    $checks += @{ name = "transition-guide 无旧式人工指引残留"; ok = (-not $guide.Contains($LegacyPhrase)); actual = "残留旧指引" }
    Assert-All "TC-055" "transition-guide 与 7 个角色 SKILL 同步更新，无旧指引残留" $checks
}

# --- TC-005 正向 AC-1：dsh happy path 四连发 --------------------------------------

function Test-DshHappyPath {
    $mock = New-MockServer -Tag "t005" -Responses @{
        "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @(
            @{ id = "default" }, @{ id = "rdd-pm" }, @{ id = "rdd-qa" }) } }
        "workspace.create"  = @{ kind = "ok"; value = @{ workspace = @{ workspaceId = "ws-test-1" } } }
        "session.create"    = @{ kind = "ok"; value = @{ sessionId = "sess-1" } }
        "session.prompt"    = @{ kind = "ok"; value = @{} }
    }
    try {
        $r = Invoke-StartRole -Tag "t005" -RoleArgs @("-Role", "QA", "-TaskId", "1", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080"; RDD_RUNTIME = $null }
        $log = Read-MockLog $mock
        $order = @($log | ForEach-Object { $_.method }) -join ","
        $createPayload = @($log | Where-Object { $_.method -eq "session.create" })[0].payload
        $promptPayload = @($log | Where-Object { $_.method -eq "session.prompt" })[0].payload
        Assert-All "TC-005" "dsh happy path：四连发成功、preset 绑定、B2 指针消息" @(
            @{ name = "exit 0"; ok = ($r.exit -eq 0); actual = "exit=$($r.exit); out=$($r.stdout -replace "`r?`n", " | ")" }
            @{ name = "输出含成功行（preset rdd-qa / sessionId sess-1）"; ok = ($r.stdout -match [regex]::Escape("preset: rdd-qa") -and $r.stdout -match [regex]::Escape("sessionId: sess-1")); actual = $r.stdout }
            @{ name = "输出含侧栏出现提示"; ok = ($r.stdout -match "新会话已出现在 Web GUI 侧栏"); actual = $r.stdout }
            @{ name = "RPC 顺序 list→ws→create→prompt"; ok = ($order -eq "agentPreset.list,workspace.create,session.create,session.prompt"); actual = $order }
            @{ name = "session.create 绑定 agentPreset=rdd-qa"; ok = ($createPayload.agentPreset -eq "rdd-qa"); actual = ($createPayload | ConvertTo-Json -Compress) }
            @{ name = "session.prompt 文本为 B2 指针消息"; ok = ($promptPayload.content[0].text -eq $ArchivePointer); actual = $promptPayload.content[0].text }
            @{ name = "session.prompt mode=queue"; ok = ($promptPayload.mode -eq "queue"); actual = $promptPayload.mode }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-010 正向 AC-3：session.create 入账 workspace（侧栏归组前提） ---------------

function Test-WorkspaceAccounting {
    $mock = New-MockServer -Tag "t010" -Responses @{
        "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @( @{ id = "rdd-qa" }) } }
        "workspace.create" = @{ kind = "ok"; value = @{ workspace = @{ workspaceId = "ws-acct-9" } } }
        "session.create"   = @{ kind = "ok"; value = @{ sessionId = "sess-acct" } }
        "session.prompt"   = @{ kind = "ok"; value = @{} }
    }
    try {
        $r = Invoke-StartRole -Tag "t010" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        $log = Read-MockLog $mock
        $createPayload = @($log | Where-Object { $_.method -eq "session.create" })[0].payload
        $wsPayload = @($log | Where-Object { $_.method -eq "workspace.create" })[0].payload
        $hasCwd = ($createPayload.PSObject.Properties["cwd"]) -ne $null
        Assert-All "TC-010" "session.create 携带 workspaceId 且无 cwd（cwd-only 落侧栏 Ungrouped）" @(
            @{ name = "exit 0"; ok = ($r.exit -eq 0); actual = "exit=$($r.exit)" }
            @{ name = "workspace.create 传入项目根"; ok = ($wsPayload.path -eq $FixtureRoot); actual = ($wsPayload | ConvertTo-Json -Compress) }
            @{ name = "payload.workspaceId = ws-acct-9（来自 workspace.create 返回）"; ok = ($createPayload.workspaceId -eq "ws-acct-9"); actual = ($createPayload | ConvertTo-Json -Compress) }
            @{ name = "payload 不含 cwd"; ok = (-not $hasCwd); actual = ($createPayload | ConvertTo-Json -Compress) }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-015 反向 AC-4：dsh 不可达 → 明确报错 + 人工回退 ----------------------------

function Test-Unreachable {
    $r = Invoke-StartRole -Tag "t015" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:1") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
    Assert-All "TC-015" "dsh 不可达：exit 1、报错含地址与人工回退指引、指针消息全文" @(
        @{ name = "exit 1"; ok = ($r.exit -eq 1); actual = "exit=$($r.exit)" }
        @{ name = "报错含「dsh 服务不可达」"; ok = ($r.stdout -match "dsh 服务不可达"); actual = $r.stdout }
        @{ name = "含人工回退指引"; ok = ($r.stdout -match "人工回退"); actual = $r.stdout }
        @{ name = "含指针消息全文"; ok = ($r.stdout -match [regex]::Escape($ArchivePointer)); actual = $r.stdout }
        @{ name = "含目标 preset 名（rdd-qa）"; ok = ($r.stdout -match "rdd-qa"); actual = $r.stdout }
        @{ name = "报错含解出的传输层状态（ConnectFailure）"; ok = ($r.stdout -match "ConnectFailure"); actual = $r.stdout }
        @{ name = "报错尾部无空括号"; ok = ($r.stdout -notmatch "\(\)"); actual = $r.stdout }
    )
}

# --- TC-100 反向 AC-4：信任栅栏拒绝（HTTP 403）→ 报错 + 人工回退 -------------------

function Test-TrustFence {
    # DSH_WEB_URL 指向非 loopback 地址时 dsh 以 403 拒答（Host 不在信任栅栏内）。
    # 传输层拒绝不是业务错误：403 专用提示依赖从异常内链解出的 HTTP 状态——
    # PS 5.1 抛的是包裹 WebException 的 MethodInvocationException，状态不在外层。
    $mock = New-MockServer -Tag "t100" -Responses @{
        "agentPreset.list" = @{ kind = "status"; status = 403; reason = "Forbidden"; code = "trust-fence"; message = "Host not trusted" }
    }
    try {
        $mockBase = "http://127.0.0.1:$($Mock.Port)"
        $r = Invoke-StartRole -Tag "t100" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", $mockBase) -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        Assert-All "TC-100" "信任栅栏拒绝（HTTP 403）：exit 1、403 可见、信任栅栏专用提示、人工回退指引" @(
            @{ name = "exit 1"; ok = ($r.exit -eq 1); actual = "exit=$($r.exit); out=$($r.stdout -replace "`r?`n", " | ")" }
            @{ name = "报错含「dsh 服务不可达」与基地址"; ok = ($r.stdout -match "dsh 服务不可达" -and $r.stdout -match [regex]::Escape($mockBase)); actual = $r.stdout }
            @{ name = "403 对用户可见且未被当作业务错误"; ok = ($r.stdout -match "403" -and $r.stdout -notmatch "业务错误"); actual = $r.stdout }
            @{ name = "命中 403 信任栅栏专用提示（--trusted-host）"; ok = ($r.stdout -match "trusted-host"); actual = $r.stdout }
            @{ name = "含人工回退指引与指针消息全文"; ok = ($r.stdout -match "人工回退" -and $r.stdout -match [regex]::Escape($ArchivePointer)); actual = $r.stdout }
            @{ name = "报错尾部无空括号"; ok = ($r.stdout -notmatch "\(\)"); actual = $r.stdout }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-020 正向 AC-5：CLI 后端行为不变 --------------------------------------------

function Test-CliUnchanged {
    $opencode = Get-Command opencode.cmd, opencode.exe, opencode.bat -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $opencode) {
        $oc = Get-Command opencode -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".ps1" } | Select-Object -First 1
        $opencode = $oc
    }
    if (-not $opencode) {
        Add-Result "TC-020" "CLI 后端行为不变（DryRun）" "SKIP" "环境缺 opencode 可执行文件——CLI DryRun 在 opencode 探测后才打印（start-role.ps1 的 Find-OpencodeExecutable 前置检查）"
        return
    }
    $r = Invoke-StartRole -Tag "t020" -RoleArgs @("-Role", "QA", "-TaskId", "1", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DryRun") -EnvOverrides @{ DSH_WEB_URL = $null; RDD_RUNTIME = $null }
    Assert-All "TC-020" "CLI 后端行为不变：DryRun 走 cli backend、预填斜杠命令形式" @(
        @{ name = "exit 0"; ok = ($r.exit -eq 0); actual = "exit=$($r.exit); out=$($r.stdout -replace "`r?`n", " | ")" }
        @{ name = "模式行为 cli backend"; ok = ($r.stdout -match "cli backend"); actual = $r.stdout }
        @{ name = "预填 /rdd-qa TaskId=1 斜杠形式"; ok = ($r.stdout -match "/rdd-qa TaskId=1"); actual = $r.stdout }
        @{ name = "无 dsh/Plus 分支痕迹"; ok = ($r.stdout -notmatch "dsh backend" -and $r.stdout -notmatch "Plus POST"); actual = $r.stdout }
    )
}

# --- TC-025 反向 E-2：preset 缺失 → 明确报错且中止后续 RPC ---------------------

function Test-PresetMissing {
    $mock = New-MockServer -Tag "t025" -Responses @{
        "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @( @{ id = "default" }, @{ id = "rdd-pm" }, @{ id = "rdd-cto" }) } }
    }
    try {
        $r = Invoke-StartRole -Tag "t025" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        $log = Read-MockLog $mock
        $methods = @($log | ForEach-Object { $_.method })
        Assert-All "TC-025" "preset 缺失：exit 1、列出可用 preset、不发起后续 RPC" @(
            @{ name = "exit 1"; ok = ($r.exit -eq 1); actual = "exit=$($r.exit); out=$($r.stdout -replace "`r?`n", " | ")" }
            @{ name = "报错指明缺失 preset rdd-qa"; ok = ($r.stdout -match [regex]::Escape("目标角色 preset 不存在: rdd-qa")); actual = $r.stdout }
            @{ name = "列出可用 preset"; ok = ($r.stdout -match "可用 preset" -and $r.stdout -match "rdd-pm"); actual = $r.stdout }
            @{ name = "仅调用 agentPreset.list（预检中止）"; ok = ($methods.Count -eq 1 -and $methods[0] -eq "agentPreset.list"); actual = ($methods -join ",") }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-030 正向 AC-5：Plus 后端行为不变 -------------------------------------------

function Test-PlusUnchanged {
    $r = Invoke-StartRole -Tag "t030" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-EmployeeId", "uuid-test", "-DryRun") -EnvOverrides @{ RDD_RUNTIME = "app"; DSH_WEB_URL = $null }
    Assert-All "TC-030" "Plus 后端行为不变：DryRun 走 Plus POST /api/rdd/handoff" @(
        @{ name = "exit 0"; ok = ($r.exit -eq 0); actual = "exit=$($r.exit); out=$($r.stdout -replace "`r?`n", " | ")" }
        @{ name = "Plus POST /api/rdd/handoff 预览"; ok = ($r.stdout -match "Plus POST" -and $r.stdout -match "/api/rdd/handoff"); actual = $r.stdout }
        @{ name = "body 含 employee_id"; ok = ($r.stdout -match "uuid-test"); actual = $r.stdout }
        @{ name = "指针消息为应用层形式"; ok = ($r.stdout -match [regex]::Escape($ArchivePointer)); actual = $r.stdout }
    )
}

# --- TC-035 边界 AC-5/E-4：判据链 RDD_RUNTIME 优先于 DSH_WEB_URL ----------------

function Test-EnvChainPriority {
    $r = Invoke-StartRole -Tag "t035" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-EmployeeId", "uuid-test", "-DryRun") -EnvOverrides @{ RDD_RUNTIME = "app"; DSH_WEB_URL = "http://127.0.0.1:3080" }
    Assert-All "TC-035" "判据链优先级：RDD_RUNTIME=app 与 DSH_WEB_URL 并存时走 Plus" @(
        @{ name = "exit 0"; ok = ($r.exit -eq 0); actual = "exit=$($r.exit); out=$($r.stdout -replace "`r?`n", " | ")" }
        @{ name = "走 Plus 分支（Plus POST 输出）"; ok = ($r.stdout -match "Plus POST"); actual = $r.stdout }
        @{ name = "未走 dsh 分支"; ok = ($r.stdout -notmatch "dsh backend"); actual = $r.stdout }
    )
}

# --- TC-040 反向 AC-4：业务错误 → exit 1 且含错误码 --------------------------------

function Test-BusinessError {
    $mock = New-MockServer -Tag "t040" -Responses @{
        "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @( @{ id = "rdd-qa" }) } }
        "workspace.create" = @{ kind = "error"; code = "workspace-invalid"; message = "路径不可用" }
    }
    try {
        $r = Invoke-StartRole -Tag "t040" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        Assert-All "TC-040" "业务错误：exit 1、报错含「业务错误」与服务端错误码" @(
            @{ name = "exit 1"; ok = ($r.exit -eq 1); actual = "exit=$($r.exit)" }
            @{ name = "报错含业务错误标识与错误码"; ok = ($r.stdout -match "业务错误" -and $r.stdout -match "workspace-invalid"); actual = $r.stdout }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-045 反向 E-6：prompt 半途失败 → 指引手动粘贴 -------------------------------

function Test-PromptFailed {
    $mock = New-MockServer -Tag "t045" -Responses @{
        "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @( @{ id = "rdd-qa" }) } }
        "workspace.create" = @{ kind = "ok"; value = @{ workspace = @{ workspaceId = "ws-pf" } } }
        "session.create"   = @{ kind = "ok"; value = @{ sessionId = "sess-pf-9" } }
        "session.prompt"   = @{ kind = "error"; code = "prompt-rejected"; message = "会话忙" }
    }
    try {
        $r = Invoke-StartRole -Tag "t045" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        Assert-All "TC-045" "prompt 失败：exit 1、输出已建 sessionId 与手动粘贴指引" @(
            @{ name = "exit 1"; ok = ($r.exit -eq 1); actual = "exit=$($r.exit)" }
            @{ name = "输出已创建会话 sessionId"; ok = ($r.stdout -match "sess-pf-9"); actual = $r.stdout }
            @{ name = "指引手动粘贴指针消息"; ok = ($r.stdout -match "手动粘贴" -and $r.stdout -match [regex]::Escape($ArchivePointer)); actual = $r.stdout }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-050 正向 E-3：并行交接独立性（同归档 → 各自会话、同指针） ------------------

function Test-ParallelIndependence {
    $mock = New-MockServer -Tag "t050" -Responses @{
        "agentPreset.list" = @{ kind = "ok"; value = @{ presets = @( @{ id = "rdd-qa" }, @{ id = "rdd-cto" }) } }
        "workspace.create" = @{ kind = "ok"; value = @{ workspace = @{ workspaceId = "ws-par" } } }
        "session.create"   = @{ kind = "seq"; values = @( @{ sessionId = "sess-a" }, @{ sessionId = "sess-b" } ) }
        "session.prompt"   = @{ kind = "ok"; value = @{} }
    }
    try {
        $r1 = Invoke-StartRole -Tag "t050a" -RoleArgs @("-Role", "QA", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        $r2 = Invoke-StartRole -Tag "t050b" -RoleArgs @("-Role", "CTO", "-TaskJson", $TaskJson, "-Project", $FixtureRoot, "-DshUrl", "http://127.0.0.1:$($Mock.Port)") -EnvOverrides @{ DSH_WEB_URL = "http://127.0.0.1:3080" }
        $log = Read-MockLog $mock
        $creates = @($log | Where-Object { $_.method -eq "session.create" })
        $prompts = @($log | Where-Object { $_.method -eq "session.prompt" })
        $presetsBound = @($creates | ForEach-Object { $_.payload.agentPreset })
        Assert-All "TC-050" "并行交接：两次交接各自独立会话、共享同一归档指针" @(
            @{ name = "两次交接均 exit 0"; ok = ($r1.exit -eq 0 -and $r2.exit -eq 0); actual = "qa=$($r1.exit) cto=$($r2.exit)" }
            @{ name = "绑定各自角色 preset（rdd-qa/rdd-cto）"; ok = ($presetsBound -contains "rdd-qa" -and $presetsBound -contains "rdd-cto"); actual = ($presetsBound -join ",") }
            @{ name = "两次 session.create 返回不同 sessionId"; ok = ($creates.Count -eq 2); actual = ($creates | ForEach-Object { $_.payload | ConvertTo-Json -Compress }) -join "," }
            @{ name = "两条指针消息一致（同归档）"; ok = ($prompts.Count -eq 2 -and $prompts[0].payload.content[0].text -eq $ArchivePointer -and $prompts[1].payload.content[0].text -eq $ArchivePointer); actual = ($prompts | ForEach-Object { $_.payload.content[0].text }) -join " || " }
        )
    }
    finally { & $mock.Stop }
}

# --- TC-070 正向 AC-6：源仓落点（文档 + 生成器常量） ------------------------------

function Test-SourceLanding {
    $guide = Get-FileText $TransitionGuide
    $generator = Get-FileText $GeneratorPath
    # persona 头部常量：生成器源码内唯一以 "'- 角色切换：" 开头的样例行
    $constantLines = @($generator -split "`n" | Where-Object { $_ -match "^\s*'- 角色切换：" })
    $checks = @(
        @{ name = "transition-guide 含三后端判据链"; ok = ($guide -match "三种运行环境" -and $guide -match "dsh-driven"); actual = "判据链未更新" }
        @{ name = "transition-guide 含 dsh 后端小节"; ok = ($guide -match "#### dsh 后端"); actual = "缺 dsh 后端小节" }
        @{ name = "transition-guide 明示不降级 CLI"; ok = ($guide -match "不降级 CLI"); actual = "缺失败回退语义" }
        @{ name = "生成器 persona 常量含 start-role.cmd"; ok = ($constantLines.Count -eq 1 -and $constantLines[0].Contains("start-role.cmd")); actual = "命中 $($constantLines.Count) 行" }
        @{ name = "生成器 persona 常量无旧式人工指引"; ok = ($constantLines.Count -eq 1 -and -not $constantLines[0].Contains($LegacyPhrase)); actual = "命中 $($constantLines.Count) 行" }
        @{ name = "生成器含加固闸② 断言函数与调用"; ok = ($generator -match "function assertHandoffGuidance" -and $generator -match "assertHandoffGuidance\(persona, role\)"); actual = "缺 persona 断言" }
    )
    Assert-All "TC-070" "变更落源仓：transition-guide + 生成器 persona 常量 + 加固闸②" $checks
}

# --- TC-075 正向 AC-7：preset 生成物与 $DSH_HOME 落点 ------------------------------

function Test-PresetPersona {
    if (-not (Test-Path -LiteralPath $PresetLanding -PathType Container)) {
        Add-Result "TC-075" "preset persona 生成物与新落点" "SKIP" "本机未安装用户级 presets（$PresetLanding 不存在）——先运行 scripts\install-rdd-skills.ps1"
        return
    }
    $checks = @()
    foreach ($r in $Roles) {
        $src = Join-Path "$PresetSourceRoot\rdd-$r" 'agent.cordis.yml'
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $checks += @{ name = "生成物存在 dsh/presets/$r"; ok = $false; actual = "缺生成物" }
            continue
        }
        $srcText = Get-FileText $src
        $checks += @{ name = "生成物 $r 含 start-role.cmd"; ok = $srcText.Contains("start-role.cmd"); actual = "生成物未更新" }
        $checks += @{ name = "生成物 $r 无旧式人工指引"; ok = (-not $srcText.Contains($LegacyPhrase)); actual = "生成物残留旧指引" }

        $dst = Join-Path "$PresetLanding\rdd-$r" 'agent.cordis.yml'
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
            $checks += @{ name = "落点存在 $r"; ok = $false; actual = "落点缺 agent.cordis.yml" }
            continue
        }
        $srcHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        $checks += @{ name = "落点 $r 与源仓 hash 一致"; ok = ($srcHash -eq $dstHash); actual = "hash 漂移（落点未刷新）" }
        $dstText = Get-FileText $dst
        $checks += @{ name = "落点 $r 无旧式人工指引"; ok = (-not $dstText.Contains($LegacyPhrase)); actual = "落点仍是旧 persona" }
    }
    # rdd-manager 引导 preset（非角色卡）：源仓生成物存在且指向 manager-guide（落点 hash 校验仅限已安装的 7 角色——
    # manager preset 新装前落点缺失不算失败，安装后经 TC-095 的 8 组计数覆盖）
    $mgrSrc = Join-Path $PresetSourceRoot 'rdd-manager\agent.cordis.yml'
    if (-not (Test-Path -LiteralPath $mgrSrc -PathType Leaf)) {
        $checks += @{ name = "生成物存在 rdd-manager"; ok = $false; actual = "缺 Manager 引导 preset 生成物" }
    }
    else {
        $mgrText = Get-FileText $mgrSrc
        $mgrPresetYml = Join-Path $PresetSourceRoot 'rdd-manager\preset.yml'
        $checks += @{ name = "rdd-manager persona 指向 manager-guide.md"; ok = ($mgrText -match "manager-guide\.md"); actual = "未指向 manager-guide" }
        $checks += @{ name = "rdd-manager persona 含 start-role.cmd 调动指引"; ok = ($mgrText.Contains("start-role.cmd")); actual = "缺 start-role 指引" }
        $checks += @{ name = "rdd-manager preset.yml 存在且命名 RDD-MANAGER"; ok = ((Test-Path -LiteralPath $mgrPresetYml -PathType Leaf) -and ((Get-FileText $mgrPresetYml) -match "name:\s*RDD-MANAGER")); actual = "缺 preset.yml 或命名不符" }
    }
    Assert-All "TC-075" "preset 生成物与 \$DSH_HOME 落点均为新指引且 hash 一致" $checks
}

# --- TC-080 正向 AC-8：同级项目副本同步 -------------------------------------------

function Test-CopySync {
    if (-not (Test-Path -LiteralPath $PeerProjectsRoot -PathType Container)) {
        Add-Result "TC-080" "项目副本同步（start-role + transition-guide）" "SKIP" "未找到同级项目根：$PeerProjectsRoot"
        return
    }
    $copies = @()
    foreach ($dir in Get-ChildItem -LiteralPath $PeerProjectsRoot -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
        if ($dir.FullName -ieq $RepoRoot) { continue }
        $candidate = Join-Path $dir.FullName '.rdd\skills\rdd-engine\scripts\start-role.ps1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $copies += $dir.FullName }
    }
    if ($copies.Count -eq 0) {
        Add-Result "TC-080" "项目副本同步（start-role + transition-guide）" "SKIP" "同级目录下未发现含 .rdd\skills\rdd-engine 的项目副本"
        return
    }
    $checks = @()
    foreach ($copy in $copies) {
        $name = Split-Path -Leaf $copy
        $sr = Join-Path $copy '.rdd\skills\rdd-engine\scripts\start-role.ps1'
        $tg = Join-Path $copy '.rdd\skills\rdd-engine\references\transition-guide.md'
        $srText = Get-FileText $sr
        $checks += @{ name = "$name start-role.ps1 含 dsh 后端"; ok = ($srText -match "DSH_WEB_URL" -and $srText -match "Invoke-DshHandoff"); actual = "副本无 dsh 后端" }
        if (Test-Path -LiteralPath $tg -PathType Leaf) {
            $tgText = Get-FileText $tg
            $checks += @{ name = "$name transition-guide 含 dsh 分支"; ok = ($tgText -match "DSH_WEB_URL"); actual = "副本指南无 dsh 分支" }
        }
        else {
            $checks += @{ name = "$name transition-guide 存在"; ok = $false; actual = "副本缺 transition-guide.md" }
        }
    }
    Assert-All "TC-080" "5 个项目副本（含 harness）均取得 dsh 后端与文档新指引（$($copies.Count) 个副本）" $checks
}

# --- TC-085 反向 加固闸②：生成器拒绝旧措辞（临时伪造仓） --------------------------

function Test-GeneratorGate {
    $fake = Join-Path $WorkDir 'fakerepo'
    New-Item -ItemType Directory -Path (Join-Path $fake 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $GeneratorPath -Destination (Join-Path $fake 'scripts\build-dsh-presets.mjs')
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\dsh-preset-template.yml') -Destination (Join-Path $fake 'scripts\dsh-preset-template.yml')
    foreach ($r in $Roles) {
        New-Item -ItemType Directory -Path (Join-Path $fake "rdd-$r") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot "rdd-$r\SKILL.md") -Destination (Join-Path $fake "rdd-$r\SKILL.md")
    }
    $control = Invoke-Node -Tag "t085a" -NodeArgs @((Join-Path $fake 'scripts\build-dsh-presets.mjs'))
    # 篡改一个角色 SKILL.md：追加旧式人工指引
    Add-Content -LiteralPath (Join-Path $fake 'rdd-dev\SKILL.md') -Value "`n提示用户在 Web GUI $LegacyPhrase（preset 选择）并带入交接包。" -Encoding UTF8
    $sabotaged = Invoke-Node -Tag "t085b" -NodeArgs @((Join-Path $fake 'scripts\build-dsh-presets.mjs'))
    Assert-All "TC-085" "加固闸②：生成器断言 persona 必须含 start-role.cmd 且无旧式人工指引" @(
        @{ name = "对照仓生成成功（断言不误伤）"; ok = ($control.exit -eq 0); actual = "exit=$($control.exit); $($control.all)" }
        @{ name = "篡改后生成失败（fail loud）"; ok = ($sabotaged.exit -ne 0); actual = "exit=$($sabotaged.exit)" }
        @{ name = "失败信息指明旧式人工指引"; ok = ($sabotaged.all -match "旧式人工指引"); actual = $sabotaged.all }
    )
}

# --- TC-090 反向 加固闸③：安装器拒绝旧 tarball（不落盘） --------------------------

function Test-InstallerPackageGate {
    if (-not (Test-Path -LiteralPath $SkillsTarball -PathType Leaf)) {
        Add-Result "TC-090" "加固闸③：安装器拒绝旧 persona tarball" "SKIP" "未找到 dist\skills\rdd-skills.tgz（先运行 scripts\build-skills-package.mjs）"
        return
    }
    $staleDir = Join-Path $WorkDir 'stale'
    New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
    & tar.exe -xzf $SkillsTarball -C $staleDir
    $persona = Join-Path $staleDir 'package\presets\rdd-dev\agent.cordis.yml'
    Add-Content -LiteralPath $persona -Value "`n- 角色切换：提示用户在 Web GUI $LegacyPhrase（preset 选择）并带入交接包。" -Encoding UTF8
    $staleTgz = Join-Path $WorkDir 'rdd-skills-stale.tgz'
    if (Test-Path -LiteralPath $staleTgz) { Remove-Item -LiteralPath $staleTgz -Force }
    & tar.exe -czf $staleTgz -C $staleDir package
    $tarOk = ($LASTEXITCODE -eq 0)

    $tmpDsh = Join-Path $WorkDir 'dsh-stale'
    $tmpLedger = Join-Path $WorkDir 'ledger-stale'
    $r = Invoke-Installer -Tag "t090" -InstallerArgs @("-Tarball", $staleTgz, "-DshHome", $tmpDsh, "-LedgerHome", $tmpLedger)
    $landed = @()
    if (Test-Path -LiteralPath (Join-Path $tmpDsh 'skills')) { $landed += @(Get-ChildItem -LiteralPath (Join-Path $tmpDsh 'skills') -Directory -Filter 'rdd-*' -ErrorAction SilentlyContinue) }
    if (Test-Path -LiteralPath (Join-Path $tmpDsh '.agent-presets')) { $landed += @(Get-ChildItem -LiteralPath (Join-Path $tmpDsh '.agent-presets') -Directory -Filter 'rdd-*' -ErrorAction SilentlyContinue) }
    $all = $r.stdout + $r.stderr
    Assert-All "TC-090" "加固闸③：包内 persona 不合规 → 拷贝前 Fail，落点保持原状" @(
        @{ name = "旧 tarball 构造成功"; ok = $tarOk; actual = "tar exit=$LASTEXITCODE" }
        @{ name = "安装 exit 1"; ok = ($r.exit -eq 1); actual = "exit=$($r.exit); out=$($all -replace "`r?`n", " | ")" }
        @{ name = "报错指明 tarball 过期"; ok = ($all -match "stale tarball"); actual = $all }
        @{ name = "落点未落任何 rdd-* 目录"; ok = ($landed.Count -eq 0); actual = "落了 $($landed.Count) 项" }
    )
}

# --- TC-095 反向 加固闸①：reparse point 保护（安装保留 + -Remove 拒绝） ----------

function Test-ReparseProtection {
    if (-not (Test-Path -LiteralPath $SkillsTarball -PathType Leaf)) {
        Add-Result "TC-095" "加固闸①：junction 保护覆盖安装与 -Remove 两条删除路径" "SKIP" "未找到 dist\skills\rdd-skills.tgz"
        return
    }
    $tmpDsh = Join-Path $WorkDir 'dsh-protect'
    $tmpLedger = Join-Path $WorkDir 'ledger-protect'
    $skillsRoot = Join-Path $tmpDsh 'skills'
    New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
    $junction = Join-Path $skillsRoot 'rdd-engine'
    New-Item -ItemType Junction -Path $junction -Target (Join-Path $RepoRoot 'rdd-engine') | Out-Null

    $install = Invoke-Installer -Tag "t095a" -InstallerArgs @("-Tarball", $SkillsTarball, "-DshHome", $tmpDsh, "-LedgerHome", $tmpLedger)
    $junctionsAfterInstall = Test-ReparsePoint -Path $junction
    $roleDirs = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Filter 'rdd-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'rdd-engine' }).Count
    $presetsInstalled = @(Get-ChildItem -LiteralPath (Join-Path $tmpDsh '.agent-presets') -Directory -Filter 'rdd-*' -ErrorAction SilentlyContinue).Count

    $remove = Invoke-Installer -Tag "t095b" -InstallerArgs @("-Remove", "-DshHome", $tmpDsh, "-LedgerHome", $tmpLedger)
    $junctionAfterRemove = Test-ReparsePoint -Path $junction
    $removeAll = $remove.stdout + $remove.stderr
    Assert-All "TC-095" "加固闸①：安装保留 junction、-Remove 拒绝删除 junction" @(
        @{ name = "安装 exit 0"; ok = ($install.exit -eq 0); actual = "exit=$($install.exit); out=$(($install.stdout + $install.stderr) -replace "`r?`n", " | ")" }
        @{ name = "输出标注 junction 被保留"; ok = (($install.stdout) -match "preserved reparse point"); actual = $install.stdout }
        @{ name = "安装后 junction 仍在"; ok = $junctionsAfterInstall; actual = "junction 消失" }
        @{ name = "7 个角色技能目录到位"; ok = ($roleDirs -eq 7); actual = "实到 $roleDirs 个" }
        @{ name = "8 组 preset 落点到位（7 角色 + rdd-manager）"; ok = ($presetsInstalled -eq 8); actual = "实到 $presetsInstalled 组" }
        @{ name = "-Remove exit 1（保护即报错）"; ok = ($remove.exit -eq 1); actual = "exit=$($remove.exit)" }
        @{ name = "-Remove 报错指明拒绝删除"; ok = ($removeAll -match "refusing to delete reparse points"); actual = $removeAll }
        @{ name = "-Remove 后 junction 仍在"; ok = $junctionAfterRemove; actual = "junction 被删除" }
    )
}

# --- 执行 ---------------------------------------------------------------------

try {
    Test-BomGuard
    Test-ConfirmationRetained
    Test-DocsSynced
    Test-DshHappyPath
    Test-WorkspaceAccounting
    Test-Unreachable
    Test-TrustFence
    Test-CliUnchanged
    Test-PresetMissing
    Test-PlusUnchanged
    Test-EnvChainPriority
    Test-BusinessError
    Test-PromptFailed
    Test-ParallelIndependence
    Test-SourceLanding
    Test-PresetPersona
    Test-CopySync
    Test-GeneratorGate
    Test-InstallerPackageGate
    Test-ReparseProtection
}
finally {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

$pass = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
$skipped = @($script:Results | Where-Object { $_.Status -eq "SKIP" }).Count
$total = $script:Results.Count
""
"role-handoff 测试结果：$pass/$total 通过（SKIP $skipped）"
"{0,-8} {1,-6} {2}" -f "TC", "结果", "标题"
foreach ($row in $script:Results) {
    "{0,-8} {1,-6} {2}" -f $row.Tc, $row.Status, $row.Title
}
$failures = @($script:Results | Where-Object { $_.Status -eq "FAIL" })
$skips = @($script:Results | Where-Object { $_.Status -eq "SKIP" })
if ($skips.Count -gt 0) {
    ""
    "跳过详情："
    foreach ($s in $skips) { "[$($s.Tc)] $($s.Detail)" }
}
if ($failures.Count -gt 0) {
    ""
    "失败详情："
    foreach ($f in $failures) {
        "[$($f.Tc)] $($f.Title)"
        "  $($f.Detail)"
    }
    exit 1
}
exit 0

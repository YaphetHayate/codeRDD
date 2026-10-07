# tips-injection QA 黑盒探针 — 启动定向注入与角色开工规则（archive 2026-10-06-role-tips-mechanism，任务 #2 / 节点 n8）
#
# QA 独立验收套件（与 DEV 的 rdd-engine/tests/test-tips.ps1 及其注入端到端相互独立、零共享代码）：
# 用例源于 requirements/tips-startup-injection.md 的 4 条验收标准 + 边界（体积控制 cap、
# 降级、段序、A0/PLANNER 不注入），黑盒驱动生产解释器（Windows PowerShell 5.1）：
#   - start-role.ps1 经子进程 -DryRun 驱动（dsh 后端 = DSH_WEB_URL 注入；CLI 后端 = 双清）
#   - B2 指针消息从 DryRun 末行 "mode=queue text=<msg>" 提取（该行是 DryRun 最后一条输出）
#   - 无 tips 回归基线 = git show HEAD:start-role.ps1（无注入能力的上一版）同夹具同环境运行
#   - tips 夹具经 tips.cmd/tips.ps1 公开 CLI 落盘，存储根 = RDD_PROJECT_ROOT 指向 %TEMP%
#     一次性根（零真仓污染）；场景组互不依赖执行顺序。退出码 0 = 全绿。
#
# TC 编号与 .rdd/tests/tips-startup-injection/cases.json 一一对应（TC-005..TC-055，步长 5）。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot   = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:EngineDir  = Join-Path $Script:RepoRoot 'rdd-engine\scripts'
$Script:StartPs1   = Join-Path $Script:EngineDir 'start-role.ps1'
$Script:TipsPs1    = Join-Path $Script:EngineDir 'tips.ps1'
$Script:Work       = Join-Path $env:TEMP ('tips-inj-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-TipsPs1 { param([string[]]$ArgList)
    # 生产解释器直驱 tips CLI（夹具准备面）。native stderr 在 EAP=Stop 下会抛
    # NativeCommandError（PS 5.1 已知陷阱），调用窗口内降为 Continue。
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:TipsPs1) + $ArgList
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = (& powershell @all 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $json = $null
    try { $json = $raw | ConvertFrom-Json } catch { }
    return @{ exit = $code; raw = $raw; json = $json }
}

function Invoke-StartRole { param([string]$Role, [string]$Root, [string[]]$ExtraArgs, [string]$Backend)
    # 子进程驱动 start-role -DryRun，后端由环境显式钉定（dsh = DSH_WEB_URL；cli = 双清），
    # cwd 与 RDD_PROJECT_ROOT 都钉在夹具根——tips 取数与 task.json 定位全部隔离。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $argLine = '-Role ' + $Role + ' -DryRun -TaskJson ''' + (Join-Path $Root '.rdd\changes\archive\qa-tips-fixture\task.json') + ''''
    foreach ($a in $ExtraArgs) { $argLine += ' ' + $a }
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "& ''' + $script:StartPs1 + ''' ' + $argLine + ' ; exit $LASTEXITCODE"'
    $psi.WorkingDirectory = $Root
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['DSH_WEB_URL'] = $null
    $psi.EnvironmentVariables['RDD_RUNTIME'] = $null
    $psi.EnvironmentVariables['RDD_PROJECT_ROOT'] = $Root
    if ($Backend -eq 'dsh') { $psi.EnvironmentVariables['DSH_WEB_URL'] = 'http://127.0.0.1:9' }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ stdout = $out; stderr = $err; exit = $proc.ExitCode }
}

function Get-PointerText { param([string]$Stdout)
    # DryRun 的 prompt payload 行是最后一条输出：从最后一个 "mode=queue text=" 截取到
    # 输出末尾，仅剥掉控制台行尾一次（消息自身携带的尾换行必须保留——逐字节断言依赖它）。
    $anchor = 'mode=queue text='
    $idx = $Stdout.LastIndexOf($anchor)
    if ($idx -lt 0) { return $null }
    $text = $Stdout.Substring($idx + $anchor.Length)
    if ($text.EndsWith("`r`n")) { return $text.Substring(0, $text.Length - 2) }
    if ($text.EndsWith("`n")) { return $text.Substring(0, $text.Length - 1) }
    return $text
}

function Get-A0Prefill { param([string]$Stdout)
    # 预填消息行后还有「终端」等 DryRun 行——只取锚点后的第一个物理行。
    $anchor = '[DRYRUN] 预填消息:  '
    $idx = $Stdout.LastIndexOf($anchor)
    if ($idx -lt 0) { return $null }
    $text = $Stdout.Substring($idx + $anchor.Length)
    $nl = $text.IndexOf("`n")
    if ($nl -ge 0) { $text = $text.Substring(0, $nl) }
    return $text.TrimEnd("`r")
}

function New-FixtureRoot { param([string]$Name)
    $root = Join-Path $script:Work $Name
    $archDir = Join-Path $root '.rdd\changes\archive\qa-tips-fixture'
    New-Item -ItemType Directory -Path $archDir -Force | Out-Null
    $taskJson = '{"archive":"qa-tips-fixture","generatedAt":"2026-10-06T00:00:00Z","version":1,"tasks":[{"id":1,"title":"fixture task","requirement":"requirements/t1.md","currentOwners":["DEV"],"phase":"IMPL","lifecycle":"active"}]}'
    [System.IO.File]::WriteAllText((Join-Path $archDir 'task.json'), $taskJson, (New-Object System.Text.UTF8Encoding($false)))
    return $root
}

function Set-TipsStore { param([string]$Root)
    $env:RDD_PROJECT_ROOT = $Root
    return (Join-Path $Root '.rdd\tips\entries')
}

function Write-Payload { param([string]$Path, [string]$Text)
    # 手造字面 CJK JSON（不经 ConvertTo-Json —— PS 5.1 会 \u 转义，掩蔽原始 CJK 字节
    # 这条真实现场路径），UTF-8 无 BOM。
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-BytesEqual { param([string]$A, [string]$B)
    $ba = [System.Text.Encoding]::UTF8.GetBytes($A)
    $bb = [System.Text.Encoding]::UTF8.GetBytes($B)
    if ($ba.Length -ne $bb.Length) { return $false }
    for ($i = 0; $i -lt $ba.Length; $i++) { if ($ba[$i] -ne $bb[$i]) { return $false } }
    return $true
}

# 中文夹具（本套件带 BOM，PS 5.1 正确解析；进入被测链路只经 -File payload 字节）。
$ZhTitle     = '中文标题：BOM 被抹导致函数静默丢失'
$ZhProblem   = '问题描述：UTF-8 无 BOM 的中文 .ps1 在 PS 5.1 下解析错位'
$ZhAvoidance = '规避：写入后重补 BOM 并断言首 3 字节'

$BaseMsg = '请处理 .rdd/changes/archive/qa-tips-fixture/ 下的需求。'
$HeaderDev = '【定向 tips（DEV）——开工前先通读，详情按行内指针读取】'
$HeaderQa   = '【定向 tips（QA）——开工前先通读，详情按行内指针读取】'

$prevRoot = $env:RDD_PROJECT_ROOT
New-Item -ItemType Directory -Path $Work -Force | Out-Null

try {
    # ---------- S0：BOM 自检（§6.1 含中文 .ps1 必须带 BOM；QA tip 20261006T100831Z 的测试层兜底） ----------
    $selfBom = [System.IO.File]::ReadAllBytes($PSCommandPath)[0..2]
    Assert-True ($selfBom[0] -eq 239 -and $selfBom[1] -eq 187 -and $selfBom[2] -eq 191) 'S0.a self BOM (zh suite saved UTF-8 with BOM)' ("first3=$($selfBom -join ',')")
    foreach ($f in @('rdd-engine\scripts\start-role.ps1', 'rdd-engine\scripts\tips.ps1', 'rdd-engine\tests\test-tips.ps1')) {
        $bom = [System.IO.File]::ReadAllBytes((Join-Path $script:RepoRoot $f))[0..2]
        Assert-True ($bom[0] -eq 239 -and $bom[1] -eq 187 -and $bom[2] -eq 191) ('S0.b delivered .ps1 keeps BOM: ' + $f) ("first3=$($bom -join ',')")
    }

    # ---------- 夹具与 HEAD 基线准备 ----------
    $fixture = New-FixtureRoot 'main'
    $headScripts = Join-Path $Work 'head-engine\scripts'
    New-Item -ItemType Directory -Path $headScripts -Force | Out-Null
    $headStartRole = Join-Path $headScripts 'start-role.ps1'
    cmd /c "git -C ""$script:RepoRoot"" show HEAD:rdd-engine/scripts/start-role.ps1> ""$headStartRole"""
    $headBom = [System.IO.File]::ReadAllBytes($headStartRole)[0..2]
    Assert-True ($headBom[0] -eq 239 -and $headBom[1] -eq 187 -and $headBom[2] -eq 191) 'S1.a HEAD baseline extracted intact (BOM preserved)' ("first3=$($headBom -join ',')")

    function Invoke-HeadStartRole { param([string]$Role, [string]$Root)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "& ''' + $headStartRole + ''' -Role ' + $Role + ' -DryRun -TaskJson ''' + (Join-Path $Root '.rdd\changes\archive\qa-tips-fixture\task.json') + ''' ; exit $LASTEXITCODE"'
        $psi.WorkingDirectory = $Root
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.EnvironmentVariables['DSH_WEB_URL'] = 'http://127.0.0.1:9'
        $psi.EnvironmentVariables['RDD_RUNTIME'] = $null
        $psi.EnvironmentVariables['RDD_PROJECT_ROOT'] = $Root
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return @{ stdout = $out; stderr = $err; exit = $proc.ExitCode }
    }

    # ---------- TC-015（AC-2）：空 tips 项目 B2 与 HEAD 逐字节一致 ----------
    $null = Set-TipsStore $fixture            # 空库：不落任何条目
    $wtRun = Invoke-StartRole -Role DEV -Root $fixture -ExtraArgs @() -Backend dsh
    Assert-True ($wtRun.exit -eq 0 -and $wtRun.stdout.Contains('dsh backend')) 'TC-015.a worktree dry-run: dsh backend, exit 0' ("exit=$($wtRun.exit) out=$($wtRun.stdout)")
    $wtMsg = Get-PointerText $wtRun.stdout
    Assert-True ($wtMsg -ceq $BaseMsg) 'TC-015.b empty store: pointer message equals legacy single-line form' ("msg=[$wtMsg]")
    $headRun = Invoke-HeadStartRole -Role DEV -Root $fixture
    Assert-True ($headRun.exit -eq 0) 'TC-015.c HEAD baseline dry-run: exit 0' ("exit=$($headRun.exit) out=$($headRun.stdout)")
    $headMsg = Get-PointerText $headRun.stdout
    Assert-True (Test-BytesEqual $wtMsg $headMsg) 'TC-015.d regression anchor: worktree == HEAD byte-for-byte (UTF-8)' ("wt=[$wtMsg] head=[$headMsg]")
    Assert-True (-not $wtRun.stdout.Contains('定向 tips') -and -not $wtRun.stdout.Contains('[!]')) 'TC-015.e no tips segment, no degrade warning on a tip-less project' ($wtRun.stdout)

    # ---------- TC-005（AC-1 正向）：DEV 定向中文 tip 注入 B2 ----------
    $zhPayloadPath = Join-Path $fixture 'zh-tip.json'
    Write-Payload $zhPayloadPath ('{"title":"' + $ZhTitle + '","problem":"' + $ZhProblem + '","avoidance":"' + $ZhAvoidance + '"}')
    $r = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-File', $zhPayloadPath)
    $tipId = [string]$r.json.data.id
    Assert-True ($r.exit -eq 0 -and $r.json.data.recorded -eq $true -and (@($r.json.data.roles) -join ',') -eq 'DEV') 'TC-005.a fixture add -By DEV: record-then-own stamps roles=[DEV]' ("exit=$($r.exit) raw=$($r.raw)")
    $devRun = Invoke-StartRole -Role DEV -Root $fixture -ExtraArgs @() -Backend dsh
    $devMsg = Get-PointerText $devRun.stdout
    $tipLine = '- ' + $ZhTitle + ' — .rdd/tips/entries/' + $tipId + '.json'
    $expectedMsg = $BaseMsg + "`n" + $HeaderDev + "`n" + $tipLine + "`n"
    Assert-True ($devRun.exit -eq 0) 'TC-005.b DEV startup: exit 0' ("exit=$($devRun.exit)")
    Assert-True ($devMsg -ceq $expectedMsg) 'TC-005.c DEV B2 carries tips segment: header + one line (title + repo pointer), CJK verbatim, exact form' ("msg=[$devMsg]")
    $pointerAbs = Join-Path $fixture ('.rdd\tips\entries\' + $tipId + '.json')
    Assert-True (Test-Path -LiteralPath $pointerAbs -PathType Leaf) 'TC-005.d inline detail pointer resolves to a real file' ("path=$pointerAbs")

    # ---------- TC-010（AC-1 反向）：非定向条目不出现 ----------
    $pmRun = Invoke-StartRole -Role PM -Root $fixture -ExtraArgs @() -Backend dsh
    $pmMsg = Get-PointerText $pmRun.stdout
    Assert-True ($pmMsg -ceq $BaseMsg) 'TC-010.a PM startup: non-targeted entry absent, message equals tip-less form' ("msg=[$pmMsg]")
    $qaRun0 = Invoke-StartRole -Role QA -Root $fixture -ExtraArgs @() -Backend dsh
    Assert-True ((Get-PointerText $qaRun0.stdout) -ceq $BaseMsg) 'TC-010.b QA startup before target spread: absent as well' ("msg=[$((Get-PointerText $qaRun0.stdout))]")

    # ---------- TC-030（AC-4）：BOM 场景端到端（记录即归属 → target 扩散） ----------
    $r = Invoke-TipsPs1 @('-Command', 'target', '-Id', $tipId, '-By', 'qa')
    Assert-True ($r.exit -eq 0 -and $r.json.data.appended -eq $true -and (@($r.json.data.roles) -join ',') -eq 'DEV,QA') 'TC-030.a target -By qa: appended, case-canonicalized, roles DEV,QA' ("exit=$($r.exit) raw=$($r.raw)")
    $qaRun = Invoke-StartRole -Role QA -Root $fixture -ExtraArgs @() -Backend dsh
    $qaMsg = Get-PointerText $qaRun.stdout
    $expectedQa = $BaseMsg + "`n" + $HeaderQa + "`n" + $tipLine + "`n"
    Assert-True ($qaMsg -ceq $expectedQa) 'TC-030.b QA startup after spread: B2 carries the tip (exact form)' ("msg=[$qaMsg]")
    $pmRun2 = Invoke-StartRole -Role PM -Root $fixture -ExtraArgs @() -Backend dsh
    Assert-True ((Get-PointerText $pmRun2.stdout) -ceq $BaseMsg) 'TC-030.c PM startup: still absent after spread' ("msg=[$((Get-PointerText $pmRun2.stdout))]")
    $devRun2 = Invoke-StartRole -Role DEV -Root $fixture -ExtraArgs @() -Backend dsh
    Assert-True ((Get-PointerText $devRun2.stdout) -ceq $expectedMsg) 'TC-030.d DEV startup: segment unchanged by the spread' ("msg=[$((Get-PointerText $devRun2.stdout))]")

    # ---------- TC-045（边界）：段序 base → tips → TaskBrief → goal-tree marker（marker 居末） ----------
    $brief = '本次唯一任务：完成注入验证'
    $ordRun = Invoke-StartRole -Role DEV -Root $fixture -ExtraArgs @('-TaskBrief', ('''' + $brief + ''''), '-GoalTreeRun', 'deliver-qa-x', '-GoalTreeNode', 'n9') -Backend dsh
    $ordMsg = Get-PointerText $ordRun.stdout
    $iBase = $ordMsg.IndexOf($BaseMsg); $iHead = $ordMsg.IndexOf($HeaderDev); $iTip = $ordMsg.IndexOf($tipLine); $iBrief = $ordMsg.IndexOf($brief); $iMark = $ordMsg.IndexOf('goal-tree-run=deliver-qa-x node=n9')
    Assert-True (($iBase -ge 0) -and ($iHead -gt $iBase) -and ($iTip -gt $iHead) -and ($iBrief -gt $iTip) -and ($iMark -gt $iBrief)) 'TC-045.a segment order: base < tips header < tip line < brief < marker' ("idx=$iBase,$iHead,$iTip,$iBrief,$iMark msg=[$ordMsg]")
    Assert-True ($ordMsg.EndsWith('goal-tree-run=deliver-qa-x node=n9')) 'TC-045.b marker keeps the trailing-anchor position' ("msg=[$ordMsg]")

    # ---------- TC-035（边界·体积控制）：cap=10，超限提示行，新→旧 ----------
    $capRoot = New-FixtureRoot 'cap'
    $null = Set-TipsStore $capRoot
    foreach ($n in 1..13) {
        $nn = '{0:D2}' -f $n
        $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', ('cap tip ' + $nn), '-Problem', 'p', '-Avoidance', 'a')
    }
    $capRun = Invoke-StartRole -Role DEV -Root $capRoot -ExtraArgs @() -Backend dsh
    $capMsg = Get-PointerText $capRun.stdout
    $tipLines = @([regex]::Matches($capMsg, '(?m)^- cap tip \d\d — \.rdd/tips/entries/'))
    Assert-True ($tipLines.Count -eq 10) 'TC-035.a 13 entries capped to exactly 10 summary lines' ("count=$($tipLines.Count) msg=[$capMsg]")
    Assert-True ($capMsg.Contains('- cap tip 13 — ') -and $capMsg.Contains('- cap tip 04 — ') -and -not $capMsg.Contains('- cap tip 03 — ')) 'TC-035.b newest first: 13 shown, 04 is the 10th, 03 cut' ("msg=[$capMsg]")
    Assert-True ($capMsg.Contains('另有 3 条更早定向 tips 未列出') -and $capMsg.Contains('list -Role DEV')) 'TC-035.c overflow hint names the remaining 3 + full-list command' ("msg=[$capMsg]")
    $capPm = Invoke-StartRole -Role PM -Root $capRoot -ExtraArgs @() -Backend dsh
    Assert-True ((Get-PointerText $capPm.stdout) -ceq $BaseMsg) 'TC-035.d PM in a full store: still tip-less form' ("msg=[$((Get-PointerText $capPm.stdout))]")

    # ---------- TC-040（异常·降级）：半损坏条目 → 警告指名文件 + 零注入 + 不阻断 ----------
    $degRoot = New-FixtureRoot 'degrade'
    $null = Set-TipsStore $degRoot
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'DEV', '-Title', 'healthy tip', '-Problem', 'p', '-Avoidance', 'a')
    $corruptName = '99999999T999999Z-DEV-deadbee.json'
    Write-Payload (Join-Path $degRoot ('.rdd\tips\entries\' + $corruptName)) '{ oops not json'
    $degRun = Invoke-StartRole -Role DEV -Root $degRoot -ExtraArgs @() -Backend dsh
    $degMsg = Get-PointerText $degRun.stdout
    Assert-True ($degRun.stdout.Contains('定向 tips 注入降级') -and $degRun.stdout.Contains($corruptName)) 'TC-040.a degrade warning names the broken file' ("out=$($degRun.stdout)")
    Assert-True ($degMsg -ceq $BaseMsg) 'TC-040.b zero injection: message equals tip-less form' ("msg=[$degMsg]")
    Assert-True ($degRun.exit -eq 0) 'TC-040.c handoff never blocked (exit 0)' ("exit=$($degRun.exit)")

    # ---------- TC-050（边界）：CLI 后端 A0 预填消息不注入 ----------
    $cliRun = Invoke-StartRole -Role DEV -Root $fixture -ExtraArgs @('-TaskId', '1') -Backend cli
    $a0 = Get-A0Prefill $cliRun.stdout
    Assert-True ($a0 -ne $null -and $a0.Contains('/rdd-dev TaskId=1 task=')) 'TC-050.a CLI prefill carries the A0 pointer form' ("a0=[$a0] out=$($cliRun.stdout)")
    Assert-True (($a0 -ne $null) -and (-not $a0.Contains('【')) -and (-not $cliRun.stdout.Contains('定向 tips（'))) 'TC-050.b A0 prefill never carries the tips segment (store non-empty)' ("a0=[$a0]")

    # ---------- TC-055（边界）：PLANNER 启动消息不注入（早退分支） ----------
    $plRoot = New-FixtureRoot 'planner'
    $null = Set-TipsStore $plRoot
    $null = Invoke-TipsPs1 @('-Command', 'add', '-By', 'PLANNER', '-Title', 'planner scoped tip', '-Problem', 'p', '-Avoidance', 'a')
    $plRun = Invoke-StartRole -Role PLANNER -Root $plRoot -ExtraArgs @('-RunId', 'deliver-qa-x') -Backend dsh
    Assert-True ($plRun.stdout.Contains('planner-guide.md') -and $plRun.stdout.Contains('deliver-qa-x')) 'TC-055.a PLANNER bootstrap message shape' ("out=$($plRun.stdout)")
    Assert-True (-not $plRun.stdout.Contains('定向 tips（')) 'TC-055.b PLANNER-targeted tip exists yet never injected (early return)' ("out=$($plRun.stdout)")

    # ---------- TC-020（AC-3）：7 份角色 SKILL.md 携带 tips 双向规则小节 ----------
    $skillRoles = @('rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse')
    foreach ($role in $skillRoles) {
        $skillPath = Join-Path $script:RepoRoot (Join-Path $role 'SKILL.md')
        $skillText = [System.IO.File]::ReadAllText($skillPath, [System.Text.Encoding]::UTF8)
        $hasSection = $skillText.Contains('## 项目 tips 双向规则') -and $skillText.Contains('开工读') -and $skillText.Contains('随手沉淀') -and $skillText.Contains('复用优先') -and $skillText.Contains('target')
        Assert-True $hasSection ('TC-020 ' + $role + '/SKILL.md carries the bidirectional tips section') ($skillPath)
    }

    # ---------- TC-025（AC-3）：presets / skills-staging 同步 + 双构建校验 ----------
    foreach ($role in $skillRoles) {
        $presetPath = Join-Path $script:RepoRoot ('dsh\presets\' + $role + '\agent.cordis.yml')
        $presetText = [System.IO.File]::ReadAllText($presetPath, [System.Text.Encoding]::UTF8)
        Assert-True $presetText.Contains('项目 tips 双向规则') ('TC-025 preset rebuilt: ' + $presetPath) ('phrase missing')
    }
    foreach ($role in $skillRoles) {
        $stagedPath = Join-Path $script:RepoRoot ('dist\skills-staging\skills\' + $role + '\SKILL.md')
        Assert-True (Test-Path -LiteralPath $stagedPath -PathType Leaf) ('TC-025 staging present: ' + $role) ($stagedPath)
        if (Test-Path -LiteralPath $stagedPath -PathType Leaf) {
            $staged = [System.IO.File]::ReadAllText($stagedPath, [System.Text.Encoding]::UTF8)
            Assert-True $staged.Contains('## 项目 tips 双向规则') ('TC-025 staging rebuilt: ' + $role) ($stagedPath)
        }
    }
    Push-Location $script:RepoRoot
    try {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $null = & node 'scripts/build-dsh-presets.mjs' '--check' 2>&1
            $checkPresets = $LASTEXITCODE
            $null = & node 'scripts/build-skills-package.mjs' '--check' 2>&1
            $checkSkills = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prevEap }
    } finally { Pop-Location }
    Assert-True ($checkPresets -eq 0) 'TC-025.i build-dsh-presets --check green (persona/preset sync)' ("exit=$checkPresets")
    Assert-True ($checkSkills -eq 0) 'TC-025.j build-skills-package --check green (staging/package sync)' ("exit=$checkSkills")
}
finally {
    if ($null -eq $prevRoot) { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue }
    else { $env:RDD_PROJECT_ROOT = $prevRoot }
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

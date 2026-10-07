# tips-chain E2E 集成探针 — 模块 #1（tips 存储/CLI）× 模块 #2（start-role B2 定向注入）真实串联
# （archive 2026-10-06-role-tips-mechanism，[集成/联调] 节点 n9）
#
# 与两个模块级 QA 套件（tips-store-cli / tips-startup-injection）的分工：那两套全程以
# RDD_PROJECT_ROOT+cwd 双钉定隔离根驱动；本探针补的是**集成层缝隙**——两个模块各自独立
# 解析仓库根（start-role 的 $root 链 vs tips.cmd 子进程的 cwd/env 链）在真实 git 仓、
# 无任何环境钉定下的**一致性**：
#   C1  真实 git 仓端到端完整场景（判据 #1 全链）：子目录记录中文 tip（-File 通道）→ target
#       扩散 QA → CLI 返回条目标识 → start-role DEV 的 B2 精确携带（CJK 逐字）→ 行内指针
#       在仓内可解析回完整教训（开工前即知晓规避方法）→ QA 含 / PM 不含
#   C2  跨仓根分叉防回归（n9 修复锚）：-Project <A> 而 cwd 在外来仓 B 时，注入的必须是 A
#       自身的 tips（修复前 B 的条目+B 相对指针泄漏进 A 的 B2）
#   C3  无 tips 项目启动行为与现状一致：空库 B2 与注入特性前一版（d082287~1）逐字节一致
#   C4  降级不阻断（无钉定形态）：半损坏条目 → 警告指名文件 + 零注入 + exit 0
#   C5  真仓冒烟：真实归档 + 真实 dogfood 条目（QA 记录的 BOM tip）的 DEV 含 / PM 不含，
#       且条目 git 在册（fresh clone 不丢——设计约束「人工知识随仓分发」）
#
# TC 编号与 .rdd/tests/tips-integration/cases.json 一一对应（TC-005..TC-025，步长 5）。
# 探针驱动生产解释器（Windows PowerShell 5.1）；工作区 %TEMP% 一次性 git 仓，真仓只读冒烟。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Script:RepoRoot   = (Get-Item (Join-Path $PSScriptRoot '..\..\..')).FullName
$Script:EngineDir  = Join-Path $Script:RepoRoot 'rdd-engine\scripts'
$Script:StartPs1   = Join-Path $Script:EngineDir 'start-role.ps1'
$Script:TipsPs1    = Join-Path $Script:EngineDir 'tips.ps1'
$Script:Work       = Join-Path $env:TEMP ('tips-chain-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Quote-Sq { param([string]$V) return ('''' + $V + '''') }

function Invoke-ChildPs { param([string]$File, [string]$Cwd, [string[]]$ArgList, [hashtable]$EnvSet, [string]$EntryStyle)
    # 子进程驱动（生产解释器）。-File 模式参数不含空格（本探针全部满足）；需要路径/含空格
    # 参数时用 -Command + 单引号包裹（EntryStyle 'command'）。native stderr 在 EAP=Stop 下会抛
    # NativeCommandError（PS 5.1 已知陷阱），调用窗口内降为 Continue。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    if ($EntryStyle -eq 'command') {
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "& ' + (Quote-Sq $File) + ' ' + ($ArgList -join ' ') + ' ; exit $LASTEXITCODE"'
    }
    else {
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $File + '" ' + ($ArgList -join ' ')
    }
    $psi.WorkingDirectory = $Cwd
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # 集成探针核心前提：双清环境钉定——仓库根只能经 git/cwd 链解析，与真实交付会话同形态。
    $psi.EnvironmentVariables['RDD_PROJECT_ROOT'] = $null
    $psi.EnvironmentVariables['RDD_RUNTIME'] = $null
    $psi.EnvironmentVariables['DSH_WEB_URL'] = $null
    if ($EnvSet) { foreach ($k in $EnvSet.Keys) { $psi.EnvironmentVariables[$k] = $EnvSet[$k] } }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ stdout = $out; stderr = $err; exit = $proc.ExitCode }
}

function Invoke-TipsCli { param([string]$Cwd, [string[]]$ArgList)
    $r = Invoke-ChildPs -File $script:TipsPs1 -Cwd $Cwd -ArgList $ArgList -EntryStyle 'file'
    $json = $null
    try { $json = $r.stdout | ConvertFrom-Json } catch { }
    return @{ exit = $r.exit; raw = $r.stdout; json = $json }
}

function Invoke-StartRole { param([string]$Cwd, [string[]]$ArgList)
    # dsh 后端 DryRun（DSH_WEB_URL 注入；与真实派发同分支），仓库根零钉定。
    return (Invoke-ChildPs -File $script:StartPs1 -Cwd $Cwd -ArgList $ArgList -EnvSet @{ DSH_WEB_URL = 'http://127.0.0.1:9' } -EntryStyle 'command')
}

function Get-PointerText { param([string]$Stdout)
    # DryRun 的 prompt payload 行是最后一条输出：从最后一个 "mode=queue text=" 截取到输出
    # 末尾，仅剥掉控制台行尾一次（消息自身携带的尾换行必须保留——逐字节断言依赖它）。
    $anchor = 'mode=queue text='
    $idx = $Stdout.LastIndexOf($anchor)
    if ($idx -lt 0) { return $null }
    $text = $Stdout.Substring($idx + $anchor.Length)
    if ($text.EndsWith("`r`n")) { return $text.Substring(0, $text.Length - 2) }
    if ($text.EndsWith("`n")) { return $text.Substring(0, $text.Length - 1) }
    return $text
}

function Test-BytesEqual { param([string]$A, [string]$B)
    $ba = [System.Text.Encoding]::UTF8.GetBytes($A)
    $bb = [System.Text.Encoding]::UTF8.GetBytes($B)
    if ($ba.Length -ne $bb.Length) { return $false }
    for ($i = 0; $i -lt $ba.Length; $i++) { if ($ba[$i] -ne $bb[$i]) { return $false } }
    return $true
}

function New-LabRepo { param([string]$Name)
    # %TEMP% 下一次性 git 仓 + 最小归档夹具（task.json）。
    $root = Join-Path $script:Work $Name
    $archDir = Join-Path $root '.rdd\changes\archive\e2e-fixture'
    New-Item -ItemType Directory -Path $archDir -Force | Out-Null
    git -C $root init -q
    $taskJson = '{"archive":"e2e-fixture","generatedAt":"2026-10-07T00:00:00Z","version":1,"tasks":[{"id":1,"title":"fixture task","requirement":"requirements/t1.md","currentOwners":["DEV"],"phase":"IMPL","lifecycle":"active"}]}'
    [System.IO.File]::WriteAllText((Join-Path $archDir 'task.json'), $taskJson, (New-Object System.Text.UTF8Encoding($false)))
    return $root
}

# 中文夹具（进入被测链路只经 -File payload 字节；手造字面 CJK JSON，不经 ConvertTo-Json）。
$ZhTitle     = '集成链中文无损：write 工具抹掉 ps1 的 UTF-8 BOM'
$ZhProblem   = '问题描述：无 BOM 的中文 ps1 在 PS 5.1 下解析错位，函数被静默吞掉'
$ZhAvoidance = '规避：写入后立即重补 BOM 并断言首 3 字节 239,187,191'
$FixtureTaskJsonName = '.rdd\changes\archive\e2e-fixture\task.json'
$BaseMsg = '请处理 .rdd/changes/archive/e2e-fixture/ 下的需求。'
$HeaderDev = '【定向 tips（DEV）——开工前先通读，详情按行内指针读取】'

New-Item -ItemType Directory -Path $Work -Force | Out-Null

try {
    # ---------- C0：BOM 自检（QA tip 20261006T100831Z 的测试层兜底，§6.1） ----------
    $selfBom = [System.IO.File]::ReadAllBytes($PSCommandPath)[0..2]
    Assert-True ($selfBom[0] -eq 239 -and $selfBom[1] -eq 187 -and $selfBom[2] -eq 191) 'C0.a self BOM (zh suite saved UTF-8 with BOM)' ("first3=$($selfBom -join ',')")
    foreach ($f in @('rdd-engine\scripts\start-role.ps1', 'rdd-engine\scripts\tips.ps1')) {
        $bom = [System.IO.File]::ReadAllBytes((Join-Path $script:RepoRoot $f))[0..2]
        Assert-True ($bom[0] -eq 239 -and $bom[1] -eq 187 -and $bom[2] -eq 191) ('C0.b delivered .ps1 keeps BOM: ' + $f) ("first3=$($bom -join ',')")
    }

    # ---------- C1 / TC-005：真实 git 仓端到端完整场景（判据 #1 全链，无环境钉定） ----------
    $labA = New-LabRepo 'labA'
    $sub = Join-Path $labA 'pkg\nested'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    $zhPayload = Join-Path $labA 'zh-tip.json'
    [System.IO.File]::WriteAllText($zhPayload, ('{"title":"' + $ZhTitle + '","problem":"' + $ZhProblem + '","avoidance":"' + $ZhAvoidance + '"}'), (New-Object System.Text.UTF8Encoding($false)))
    # 记录发生在子目录：CLI 的 git 根解析必须把条目落进 labA 的仓内沉淀区
    $r = Invoke-TipsCli $sub @('-Command', 'add', '-By', 'DEV', '-File', $zhPayload)
    $tipId = [string]$r.json.data.id
    Assert-True ($r.exit -eq 0 -and $r.json.data.recorded -eq $true -and (@($r.json.data.roles) -join ',') -eq 'DEV' -and $tipId -match '^\d{8}T\d{6}Z-DEV-[0-9a-f]{4}$') 'TC-005.a subdir add -By DEV -File(zh): CLI returns the entry id (record-then-own roles=[DEV])' ("exit=$($r.exit) raw=$($r.raw)")
    $entryAbs = Join-Path $labA ('.rdd\tips\entries\' + $tipId + '.json')
    Assert-True (([string]$r.json.data.path) -eq ('.rdd/tips/entries/' + $tipId + '.json') -and (Test-Path -LiteralPath $entryAbs -PathType Leaf)) 'TC-005.b entry persisted inside the lab repo at the repo-relative path the envelope returned' ("path=$($r.json.data.path)")
    $lst = Invoke-TipsCli $sub @('-Command', 'list', '-Role', 'DEV')
    Assert-True ($lst.exit -eq 0 -and $lst.json.data.count -ge 1 -and @(@($lst.json.data.entries) | Where-Object { $_.id -eq $tipId }).Count -eq 1) 'TC-005.c subdir list -Role DEV sees the entry (query leg, same root chain)' ("exit=$($lst.exit) raw=$($lst.raw)")
    $tg = Invoke-TipsCli $sub @('-Command', 'target', '-Id', $tipId, '-By', 'QA')
    Assert-True ($tg.exit -eq 0 -and (@($tg.json.data.roles) -join ',') -eq 'DEV,QA') 'TC-005.d target -By QA spreads roles to DEV,QA' ("exit=$($tg.exit) raw=$($tg.raw)")

    $taskA = Join-Path $labA $FixtureTaskJsonName
    $devRun = Invoke-StartRole $labA @('-Role', 'DEV', '-DryRun', '-TaskJson', (Quote-Sq $taskA))
    $devMsg = Get-PointerText $devRun.stdout
    $tipLine = '- ' + $ZhTitle + ' — .rdd/tips/entries/' + $tipId + '.json'
    $expectedMsg = $BaseMsg + "`n" + $HeaderDev + "`n" + $tipLine + "`n"
    Assert-True ($devRun.exit -eq 0 -and $devMsg -ne $null) 'TC-005.e start-role DEV (cwd=repo root, no env pin): dsh DryRun exit 0, pointer line present' ("exit=$($devRun.exit)")
    Assert-True ($devMsg -ceq $expectedMsg) 'TC-005.f DEV B2 exact form: base + header + one CJK tip line, verbatim' ("msg=[$devMsg]")
    # 判据最后一环：DEV 开工前依据行内指针即可读回完整教训（规避方法）
    $tipDoc = $null
    try { $tipDoc = [System.IO.File]::ReadAllText($entryAbs, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
    Assert-True ($null -ne $tipDoc -and $tipDoc.schema -eq 'rdd-tip/1' -and $tipDoc.id -eq $tipId -and $tipDoc.title -ceq $ZhTitle -and $tipDoc.avoidance -ceq $ZhAvoidance -and (@($tipDoc.roles) -join ',') -eq 'DEV,QA') 'TC-005.g inline pointer resolves to the full lesson (schema/id/title/avoidance/roles, CJK verbatim)' ("doc=$tipDoc")
    $qaMsg = Get-PointerText (Invoke-StartRole $labA @('-Role', 'QA', '-DryRun', '-TaskJson', (Quote-Sq $taskA))).stdout
    Assert-True (($qaMsg -ne $null) -and $qaMsg.Contains($tipLine)) 'TC-005.h QA (spread target) startup: B2 carries the same tip line' ("msg=[$qaMsg]")
    $pmMsg = Get-PointerText (Invoke-StartRole $labA @('-Role', 'PM', '-DryRun', '-TaskJson', (Quote-Sq $taskA))).stdout
    Assert-True (($pmMsg -ne $null) -and $pmMsg -ceq $BaseMsg) 'TC-005.i PM startup: non-targeted entry absent, exact legacy form' ("msg=[$pmMsg]")

    # ---------- C2 / TC-010：跨仓根分叉防回归（n9 修复锚：-Project + 外来 cwd） ----------
    $labB = New-LabRepo 'labB'
    $null = Invoke-TipsCli $labB @('-Command', 'add', '-By', 'DEV', '-Title', 'FOREIGN_labB_store_tip', '-Problem', 'p', '-Avoidance', 'a')
    $c2 = Invoke-StartRole $labB @('-Role', 'DEV', '-DryRun', '-Project', (Quote-Sq $labA), '-TaskJson', (Quote-Sq $taskA))
    $c2Msg = Get-PointerText $c2.stdout
    Assert-True (($c2Msg -ne $null) -and $c2Msg.Contains($tipLine) -and -not $c2Msg.Contains('FOREIGN_labB_store_tip')) 'TC-010.a -Project labA from foreign cwd (labB): B2 carries labA tip only, foreign store stays out' ("msg=[$c2Msg]")
    $c2PointerRel = '.rdd/tips/entries/' + $tipId + '.json'
    $c2PointerAbs = Join-Path $labA ('.rdd\tips\entries\' + $tipId + '.json')
    Assert-True ($c2Msg.Contains($c2PointerRel) -and (Test-Path -LiteralPath $c2PointerAbs -PathType Leaf)) 'TC-010.b injected pointer resolves inside the -Project repo (not the cwd repo)' ("msg=[$c2Msg]")
    $c2b = Invoke-StartRole $labB @('-Role', 'DEV', '-DryRun', '-Project', (Quote-Sq $labA), '-TaskJson', (Quote-Sq $taskA))
    Assert-True ((Get-PointerText $c2b.stdout) -ceq $c2Msg) 'TC-010.c deterministic on immediate re-run (env pin/restore leaves no leakage)' ("second=[$(Get-PointerText $c2b.stdout)]")

    # ---------- C3 / TC-015：无 tips 项目启动行为与现状一致（注入特性前一版逐字节锚） ----------
    $labC = New-LabRepo 'labC'
    $taskC = Join-Path $labC $FixtureTaskJsonName
    $cur = Invoke-StartRole $labC @('-Role', 'DEV', '-DryRun', '-TaskJson', (Quote-Sq $taskC))
    $curMsg = Get-PointerText $cur.stdout
    Assert-True (($curMsg -ne $null) -and $curMsg -ceq $BaseMsg) 'TC-015.a tip-less repo: current B2 equals the legacy single-line form' ("msg=[$curMsg]")
    $baseDir = Join-Path $Work 'pre-feature-engine\scripts'
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    $baseStart = Join-Path $baseDir 'start-role.ps1'
    cmd /c "git -C ""$script:RepoRoot"" show d082287~1:rdd-engine/scripts/start-role.ps1> ""$baseStart"""
    $baseBom = [System.IO.File]::ReadAllBytes($baseStart)[0..2]
    Assert-True ($baseBom[0] -eq 239 -and $baseBom[1] -eq 187 -and $baseBom[2] -eq 191) 'TC-015.b pre-injection baseline (d082287~1) extracted intact (BOM preserved)' ("first3=$($baseBom -join ',')")
    $baseRun = Invoke-ChildPs -File $baseStart -Cwd $labC -ArgList @('-Role', 'DEV', '-DryRun', '-TaskJson', (Quote-Sq $taskC)) -EnvSet @{ DSH_WEB_URL = 'http://127.0.0.1:9' } -EntryStyle 'command'
    $baseMsgText = Get-PointerText $baseRun.stdout
    Assert-True ($baseRun.exit -eq 0 -and $baseMsgText -ne $null) 'TC-015.c pre-injection baseline dry-run: exit 0, pointer line present' ("exit=$($baseRun.exit)")
    Assert-True (Test-BytesEqual $curMsg $baseMsgText) 'TC-015.d regression anchor: tip-less startup byte-for-byte identical to the pre-injection version (UTF-8)' ("cur=[$curMsg] base=[$baseMsgText]")

    # ---------- C4 / TC-020：降级不阻断（半损坏条目，无环境钉定） ----------
    $labD = New-LabRepo 'labD'
    $taskD = Join-Path $labD $FixtureTaskJsonName
    $null = Invoke-TipsCli $labD @('-Command', 'add', '-By', 'DEV', '-Title', 'healthy_e2e_tip', '-Problem', 'p', '-Avoidance', 'a')
    $corruptName = '99999999T999999Z-DEV-deadbee.json'
    [System.IO.File]::WriteAllText((Join-Path $labD ('.rdd\tips\entries\' + $corruptName)), '{ oops not json', (New-Object System.Text.UTF8Encoding($false)))
    $deg = Invoke-StartRole $labD @('-Role', 'DEV', '-DryRun', '-TaskJson', (Quote-Sq $taskD))
    $degMsg = Get-PointerText $deg.stdout
    Assert-True ($deg.stdout.Contains('定向 tips 注入降级') -and $deg.stdout.Contains($corruptName)) 'TC-020.a degrade warning names the broken file' ("out=$($deg.stdout)")
    Assert-True (($degMsg -ne $null) -and $degMsg -ceq $BaseMsg) 'TC-020.b zero injection: message equals the legacy form' ("msg=[$degMsg]")
    Assert-True ($deg.exit -eq 0) 'TC-020.c handoff never blocked (exit 0)' ("exit=$($deg.exit)")

    # ---------- C5 / TC-025：真仓冒烟（真实归档 + dogfood 条目 + git 在册） ----------
    $realTask = Join-Path $script:RepoRoot '.rdd\changes\archive\2026-10-06-role-tips-mechanism\task.json'
    $realBase = '请处理 .rdd/changes/archive/2026-10-06-role-tips-mechanism/ 下的需求。'
    $realTipTitle = 'write/edit 工具会抹掉 .ps1 的 UTF-8 BOM'
    $realTipId = '20261006T100831Z-QA-4183'
    $realDev = Invoke-StartRole $script:RepoRoot @('-Role', 'DEV', '-DryRun', '-TaskJson', (Quote-Sq $realTask))
    $realDevMsg = Get-PointerText $realDev.stdout
    Assert-True (($realDevMsg -ne $null) -and $realDevMsg.Contains('- ' + $realTipTitle + ' — .rdd/tips/entries/' + $realTipId + '.json')) 'TC-025.a real-repo DEV startup: B2 carries the dogfood BOM tip (title verbatim + pointer)' ("msg=[$realDevMsg]")
    $realPmMsg = Get-PointerText (Invoke-StartRole $script:RepoRoot @('-Role', 'PM', '-DryRun', '-TaskJson', (Quote-Sq $realTask))).stdout
    Assert-True (($realPmMsg -ne $null) -and $realPmMsg -ceq $realBase) 'TC-025.b real-repo PM startup: exact base form, no tips segment' ("msg=[$realPmMsg]")
    git -C $script:RepoRoot ls-files --error-unmatch ('.rdd/tips/entries/' + $realTipId + '.json') 2>$null
    Assert-True ($LASTEXITCODE -eq 0) 'TC-025.c the real tip entry is git-tracked (fresh clone keeps human knowledge)' ("exit=$LASTEXITCODE")
    $realDoc = $null
    try { $realDoc = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot ('.rdd\tips\entries\' + $realTipId + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
    Assert-True ($null -ne $realDoc -and $realDoc.schema -eq 'rdd-tip/1' -and (@($realDoc.roles) -contains 'DEV') -and (@($realDoc.roles) -contains 'QA')) 'TC-025.d real entry parses and targets DEV+QA (both startup legs share one source)' ("doc=$realDoc")
}
finally {
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

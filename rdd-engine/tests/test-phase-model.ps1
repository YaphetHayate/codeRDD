# phase-model acceptance tests — 交付编排桥接的阶段白名单模型
# Covers references/phase-model.md §9 regression points 1-8 + multi-anchor deps:
#   S1 single-owner full chain ["CTO"]->["DEV"]->["QA"]->complete (behavior-equivalent)
#   S2 parallel ["CTO","UX"]: 2 heads -> CTO settle narrows (no graft) -> UX settle grafts ONE DEV
#   S3 serial within DESIGN: ["CTO"] expanded to CTO+UX -> CTO settle grafts UX immediately
#   S4 QA test-first ["CTO","UX","QA"]: QA settle narrows only; QA re-entry in VERIFY gets a fresh node
#   S5 rollback -To "CTO+UX" -Phase DESIGN: prune IMPL -> rebuild both heads -> set-route back
#   S6 promulgate gates: cross-phase owners (no phase) -> GROUP_DIVERGENT_NEXT; stored junk -> PHASE_OWNER_MISMATCH
#   S7 standalone ["QA"] = VERIFY: settle completes the task
#   S8 legacy null-phase archive: promulgate + settle degrade to the old advance path (byte-identical)
#   S9 multi-anchor deps: dependent's heads depend on BOTH upstream heads; unlocks only when both terminal
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$TreePs1   = Join-Path $EngineDir 'goal-tree.ps1'
$Work      = Join-Path $env:TEMP ('phase-model-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}
function Invoke-Bridge { param([string[]]$A) Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }
function Invoke-Tree   { param([string[]]$A) Invoke-Ps1 $TreePs1 $A }

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
# tree ground truth: state/tree.json nodes carry full objects (id/parent/depends_on/status).
# (goal-tree status view buckets carry plain node-id strings.)
function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Read-Tasks { param([string]$ArchiveRel)
    $p = Join-Path $Work ($ArchiveRel + '/task.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
}
function Find-Task { param($Tasks, [int]$Id)
    foreach ($t in $Tasks) { if ([int]$t.id -eq $Id) { return $t } }
    return $null
}

# New archive: overview + task docs + init via rdd-flow (phase stored). Returns archive rel path.
function New-Archive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') "# $Name`n`nphase-model 测试归档 $Name。`n"
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        $doc = "requirements/t$i.md"
        $depLine = ''
        if ($line.dep) { $depLine = "- **依赖关系**：依赖需求 $($line.dep)`n" }
        Write-Utf8NoBom (Join-Path $archDir $doc) "# $Name 需求 $i`n`n- **描述**：phase-model 测试需求 $i`n- **验收标准**：见 phase-model.md`n$depLine"
        $i++
    }
    $tf = Join-Path $Work ("$Name-init.json")
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', ("$Name-init.json"))
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

function New-Cb { param([string]$NodeId, [string]$Ref, [bool]$Qualified = $true)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'phase-model test delivery'
        citations = @(@{ ref = $Ref; locator = 'L1' })
        next_suggestion = ''
    }
    if ($Qualified) { $cb['extras'] = @{ verification = 'smoke ok' } }
    $cbFile = Join-Path $env:TEMP ("pm-cb-$NodeId.json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}

# claim -> report (qualified by default). Returns nothing; throws on hard failure.
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string]$Ref, [bool]$Qualified = $true)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-Cb $NodeId $Ref $Qualified
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # ================= S1: single-owner full chain (behavior-equivalent) =================
    $arch1 = New-Archive 'pm-s1' '[{"title":"S1 单链","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $ref1 = "$arch1/requirements/t1.md"
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $true) 'S1 promulgate ok'
    $b = Read-BridgeJson 'deliver-pm-s1'
    $cto = [string]$b.tasks.'1'.stages.CTO
    Assert-True ($cto -eq 'n2') 'S1 CTO head grafted under goal root' ("cto=$cto")
    Do-Deliver 'deliver-pm-s1' $cto 'CTO' $ref1
    $r = Do-Settle 'deliver-pm-s1' $cto
    Assert-True ($r.json.success -eq $true -and $r.json.data.phase -eq 'DESIGN' -and $r.json.data.flow_operation -like 'set-route DESIGN->IMPL*') 'S1 CTO settle switches to IMPL' ($r.raw)
    $t = Find-Task (Read-Tasks $arch1) 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'DEV' -and [string]$t.phase -eq 'IMPL') 'S1 owners=[DEV] phase=IMPL'
    $dev = [string]$b.tasks.'1'.stages.DEV
    $b = Read-BridgeJson 'deliver-pm-s1'
    $dev = [string]$b.tasks.'1'.stages.DEV
    Assert-True ($dev -ne '' -and $null -ne $dev) 'S1 DEV node grafted after CTO settle'
    Do-Deliver 'deliver-pm-s1' $dev 'DEV' $ref1
    $r = Do-Settle 'deliver-pm-s1' $dev
    Assert-True ($r.json.success -eq $true -and $r.json.data.phase -eq 'IMPL') 'S1 DEV settle switches to VERIFY'
    $t = Find-Task (Read-Tasks $arch1) 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'S1 owners=[QA] phase=VERIFY'
    $b = Read-BridgeJson 'deliver-pm-s1'
    $qa = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-pm-s1' $qa 'QA' $ref1
    $r = Do-Settle 'deliver-pm-s1' $qa
    Assert-True ($r.json.success -eq $true -and $r.json.data.task_lifecycle -eq 'completed') 'S1 QA settle completes task'
    $t = Find-Task (Read-Tasks $arch1) 1
    Assert-True ([string]$t.lifecycle -eq 'completed' -and $null -eq $t.phase) 'S1 lifecycle=completed phase=null'
    $chk = Invoke-Flow @('-Command', 'check', '-Archive', $arch1)
    Assert-True ($chk.json.data.issueCount -eq 0) 'S1 check clean' ($chk.raw)

    # ================= S2: parallel ["CTO","UX"] convergence =================
    $arch2 = New-Archive 'pm-s2' '[{"title":"S2 并行","requirement":"requirements/t1.md","currentOwners":["CTO","UX"],"designDocs":[]}]'
    $ref2 = "$arch2/requirements/t1.md"
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch2 + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $true) 'S2 promulgate ok'
    $b = Read-BridgeJson 'deliver-pm-s2'
    $cto2 = [string]$b.tasks.'1'.stages.CTO
    $ux2  = [string]$b.tasks.'1'.stages.UX
    Assert-True ($cto2 -eq 'n2' -and $ux2 -eq 'n3' -and $cto2 -ne $ux2) 'S2 TWO heads built (CTO+UX)' ("cto=$cto2 ux=$ux2")
    Do-Deliver 'deliver-pm-s2' $cto2 'CTO' $ref2
    $r = Do-Settle 'deliver-pm-s2' $cto2
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 0) 'S2 CTO settle grafts NOTHING (remaining=[UX])' ($r.raw)
    $t = Find-Task (Read-Tasks $arch2) 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'UX' -and [string]$t.phase -eq 'DESIGN') 'S2 narrowed to [UX] phase=DESIGN'
    $b = Read-BridgeJson 'deliver-pm-s2'
    Assert-True ($null -eq $b.tasks.'1'.stages.DEV) 'S2 no DEV node yet'
    Do-Deliver 'deliver-pm-s2' $ux2 'UX' $ref2
    $r = Do-Settle 'deliver-pm-s2' $ux2
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 1) 'S2 UX settle grafts exactly ONE DEV (convergence)' ($r.raw)
    $t = Find-Task (Read-Tasks $arch2) 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'DEV' -and [string]$t.phase -eq 'IMPL') 'S2 owners=[DEV] phase=IMPL'
    $b = Read-BridgeJson 'deliver-pm-s2'
    $dev2 = [string]$b.tasks.'1'.stages.DEV
    # chain parent: DEV hangs under the last-settled node (UX)
    $devNode = Find-TreeNode 'deliver-pm-s2' $dev2
    $devParent = ''
    if ($null -ne $devNode) { $devParent = [string]$devNode.parent }
    Assert-True ($devParent -eq $ux2) 'S2 DEV grafted under last-settled UX node' ("dev=$dev2 parent=$devParent expected=$ux2")

    # ================= S3: serial within DESIGN (mid-flow expansion) =================
    $arch3 = New-Archive 'pm-s3' '[{"title":"S3 串行","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $ref3 = "$arch3/requirements/t1.md"
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch3 + '/task.json'), '-NoPush')
    $b = Read-BridgeJson 'deliver-pm-s3'
    $cto3 = [string]$b.tasks.'1'.stages.CTO
    # planner expands the owner set within DESIGN (set-route no -Phase = narrowing against whitelist)
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $arch3, '-TaskId', '1', '-To', 'CTO+UX')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.phase -eq 'DESIGN') 'S3 expand to CTO+UX keeps DESIGN' ($r.raw)
    Do-Deliver 'deliver-pm-s3' $cto3 'CTO' $ref3
    $r = Do-Settle 'deliver-pm-s3' $cto3
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 1) 'S3 CTO settle grafts UX immediately (in-phase downstream)' ($r.raw)
    $t = Find-Task (Read-Tasks $arch3) 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'UX' -and [string]$t.phase -eq 'DESIGN') 'S3 owners=[UX] still DESIGN'
    $b = Read-BridgeJson 'deliver-pm-s3'
    $ux3 = [string]$b.tasks.'1'.stages.UX
    Assert-True ($ux3 -ne '' -and $null -ne $ux3) 'S3 UX node exists after CTO settle'

    # ================= S4: QA test-first (3-way DESIGN) + QA re-entry in VERIFY =================
    $arch4 = New-Archive 'pm-s4' '[{"title":"S4 测试先行","requirement":"requirements/t1.md","currentOwners":["CTO","UX","QA"],"designDocs":[]}]'
    $ref4 = "$arch4/requirements/t1.md"
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch4 + '/task.json'), '-NoPush')
    $b = Read-BridgeJson 'deliver-pm-s4'
    $cto4 = [string]$b.tasks.'1'.stages.CTO; $ux4 = [string]$b.tasks.'1'.stages.UX; $qa4 = [string]$b.tasks.'1'.stages.QA
    Assert-True ($cto4 -and $ux4 -and $qa4 -and ($cto4 -ne $ux4) -and ($ux4 -ne $qa4)) 'S4 THREE heads built (CTO+UX+QA)'
    Do-Deliver 'deliver-pm-s4' $qa4 'QA' $ref4
    $r = Do-Settle 'deliver-pm-s4' $qa4
    Assert-True ($r.json.success -eq $true -and $r.json.data.flow_operation -like 'set-route narrow*') 'S4 QA settle narrows only (no phase switch)' ($r.raw)
    $t = Find-Task (Read-Tasks $arch4) 1
    Assert-True ((@($t.currentOwners | Sort-Object) -join '+') -eq 'CTO+UX' -and [string]$t.phase -eq 'DESIGN') 'S4 owners=[CTO,UX] phase=DESIGN'
    Do-Deliver 'deliver-pm-s4' $cto4 'CTO' $ref4
    $null = Do-Settle 'deliver-pm-s4' $cto4
    Do-Deliver 'deliver-pm-s4' $ux4 'UX' $ref4
    $r = Do-Settle 'deliver-pm-s4' $ux4
    Assert-True ($r.json.success -eq $true) 'S4 UX settle (last of DESIGN) switches to IMPL'
    $b = Read-BridgeJson 'deliver-pm-s4'
    $dev4 = [string]$b.tasks.'1'.stages.DEV
    Do-Deliver 'deliver-pm-s4' $dev4 'DEV' $ref4
    $r = Do-Settle 'deliver-pm-s4' $dev4
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 1) 'S4 DEV settle grafts fresh QA (verify) node' ($r.raw)
    $b = Read-BridgeJson 'deliver-pm-s4'
    $qa4b = [string]$b.tasks.'1'.stages.QA
    Assert-True ($qa4b -ne $qa4) 'S4 QA verify node differs from done QA design node' ("design=$qa4 verify=$qa4b")
    $t = Find-Task (Read-Tasks $arch4) 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'S4 owners=[QA] phase=VERIFY'

    # ================= S5: rollback -To CTO+UX -Phase DESIGN =================
    # reuse S2's run: task 1 is now owners=[DEV] phase=IMPL with $dev2 pending.
    # Deliver DEV with UNQUALIFIED evidence (no extras.verification) -> rollback target.
    Do-Deliver 'deliver-pm-s2' $dev2 'DEV' $ref2 $false
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-pm-s2', '-NodeId', $dev2)
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED') 'S5 settle refuses unqualified delivery' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'rollback', '-RunId', 'deliver-pm-s2', '-NodeId', $dev2, '-To', 'CTO+UX', '-Phase', 'DESIGN', '-Reason', 'S5 设计缺陷回退')
    Assert-True ($r.json.success -eq $true) 'S5 rollback ok' ($r.raw)
    Assert-True (@($r.json.data.rebuilt_nodes).Count -eq 2) 'S5 rebuilt BOTH heads (CTO+UX)'
    $t = Find-Task (Read-Tasks $arch2) 1
    Assert-True ((@($t.currentOwners | Sort-Object) -join '+') -eq 'CTO+UX' -and [string]$t.phase -eq 'DESIGN') 'S5 set-route back to [CTO,UX] @ DESIGN'
    $tree = Invoke-Tree @('-Command', 'status', '-RunId', 'deliver-pm-s2')
    $rebuiltParents = @()
    foreach ($rn in @($r.json.data.rebuilt_nodes)) {
        $rnNode = Find-TreeNode 'deliver-pm-s2' ([string]$rn)
        if ($null -ne $rnNode) { $rebuiltParents += [string]$rnNode.parent }
    }
    $nonRoot = @($rebuiltParents | Where-Object { $_ -ne 'n1' })
    Assert-True ($nonRoot.Count -eq 0) 'S5 rebuilt heads sibling-attached at head layer (parent=n1)' ("parents=$($rebuiltParents -join ',')")
    # redo loop closes: settle both rebuilt heads -> DEV regrafted (fresh id), then full chain completes
    $b = Read-BridgeJson 'deliver-pm-s2'
    $cto5 = [string]$b.tasks.'1'.stages.CTO; $ux5 = [string]$b.tasks.'1'.stages.UX
    Do-Deliver 'deliver-pm-s2' $cto5 'CTO' $ref2
    $null = Do-Settle 'deliver-pm-s2' $cto5
    Do-Deliver 'deliver-pm-s2' $ux5 'UX' $ref2
    $r = Do-Settle 'deliver-pm-s2' $ux5
    Assert-True ($r.json.success -eq $true -and @($r.json.data.next_stage_nodes).Count -eq 1) 'S5 redo converges back to ONE DEV'
    $b = Read-BridgeJson 'deliver-pm-s2'
    $dev5 = [string]$b.tasks.'1'.stages.DEV
    Assert-True ($dev5 -ne $dev2) 'S5 regrafted DEV differs from pruned node' ("old=$dev2 new=$dev5")
    Do-Deliver 'deliver-pm-s2' $dev5 'DEV' $ref2
    $null = Do-Settle 'deliver-pm-s2' $dev5
    $b = Read-BridgeJson 'deliver-pm-s2'
    $qa5 = [string]$b.tasks.'1'.stages.QA
    Do-Deliver 'deliver-pm-s2' $qa5 'QA' $ref2
    $r = Do-Settle 'deliver-pm-s2' $qa5
    Assert-True ($r.json.success -eq $true -and $r.json.data.task_lifecycle -eq 'completed') 'S5 loop closes after rollback redo'

    # ================= S6: promulgate phase gates =================
    # 6a: cross-phase owners, no stored phase -> GROUP_DIVERGENT_NEXT
    $arch6 = Join-Path $Work '.rdd/changes/archive/pm-s6a'
    New-Item -ItemType Directory -Path (Join-Path $arch6 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch6 'requirements/overview.md') "# pm-s6a`n`nS6a 归档`n"
    Write-Utf8NoBom (Join-Path $arch6 'requirements/t1.md') "# S6a 需求`n`n- **描述**：跨阶段 owner 集`n"
    Write-Utf8NoBom (Join-Path $arch6 'task.json') '{"version":1,"archive":"pm-s6a","tasks":[{"id":1,"title":"S6a 跨阶段","requirement":"requirements/t1.md","currentOwners":["UX","DEV"],"designDocs":[],"currentWorker":[],"remark":"","lifecycle":"active"}]}'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6.Replace('\', '/') + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'GROUP_DIVERGENT_NEXT') 'S6a cross-phase owners -> GROUP_DIVERGENT_NEXT' ($r.raw)
    # 6b: stored junk phase -> PHASE_OWNER_MISMATCH
    $arch6b = Join-Path $Work '.rdd/changes/archive/pm-s6b'
    New-Item -ItemType Directory -Path (Join-Path $arch6b 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch6b 'requirements/overview.md') "# pm-s6b`n`nS6b 归档`n"
    Write-Utf8NoBom (Join-Path $arch6b 'requirements/t1.md') "# S6b 需求`n`n- **描述**：存量 phase 与 owner 冲突`n"
    Write-Utf8NoBom (Join-Path $arch6b 'task.json') '{"version":1,"archive":"pm-s6b","tasks":[{"id":1,"title":"S6b 冲突","requirement":"requirements/t1.md","currentOwners":["CTO","UX"],"phase":"IMPL","designDocs":[],"currentWorker":[],"remark":"","lifecycle":"active"}]}'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch6b.Replace('\', '/') + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PHASE_OWNER_MISMATCH') 'S6b stored phase conflicts owners -> PHASE_OWNER_MISMATCH' ($r.raw)
    # 6c: flow check flags owners outside the stored phase (design test point 6)
    $arch6c = Join-Path $Work '.rdd/changes/archive/pm-s6c'
    New-Item -ItemType Directory -Path (Join-Path $arch6c 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch6c 'requirements/overview.md') "# pm-s6c`n`nS6c 归档`n"
    Write-Utf8NoBom (Join-Path $arch6c 'requirements/t1.md') "# S6c 需求`n`n- **描述**：UX+DEV 跨阶段集带 DESIGN phase`n"
    Write-Utf8NoBom (Join-Path $arch6c 'task.json') '{"version":1,"archive":"pm-s6c","tasks":[{"id":1,"title":"S6c 白名单违例","requirement":"requirements/t1.md","currentOwners":["UX","DEV"],"phase":"DESIGN","designDocs":[],"currentWorker":[],"remark":"","lifecycle":"active"}]}'
    $chk = Invoke-Flow @('-Command', 'check', '-Archive', '.rdd/changes/archive/pm-s6c')
    $phaseIssues = @(@($chk.json.data.issues) | Where-Object { $_ -like '*PHASE_OWNER_MISMATCH*' })
    Assert-True ($chk.json.data.issueCount -ge 1 -and $phaseIssues.Count -ge 1) 'S6c check reports PHASE_OWNER_MISMATCH for [UX,DEV]@DESIGN' ($chk.raw)
    # 6d: legacy null-phase cross-phase set stays silent (conservative degrade)
    $chk = Invoke-Flow @('-Command', 'check', '-Archive', '.rdd/changes/archive/pm-s6a')
    Assert-True ($chk.json.data.issueCount -eq 0) 'S6d check silent on legacy null-phase [UX,DEV]' ($chk.raw)

    # ================= S7: standalone ["QA"] = VERIFY =================
    $arch7 = New-Archive 'pm-s7' '[{"title":"S7 独立QA","requirement":"requirements/t1.md","currentOwners":["QA"],"designDocs":[]}]'
    $ref7 = "$arch7/requirements/t1.md"
    $t = Find-Task (Read-Tasks $arch7) 1
    Assert-True ([string]$t.phase -eq 'VERIFY') 'S7 init infers VERIFY for ["QA"]'
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-NoPush')
    $b = Read-BridgeJson 'deliver-pm-s7'
    $qa7 = [string]$b.tasks.'1'.stages.QA
    Assert-True ($qa7 -eq 'n2') 'S7 QA head grafted'
    Do-Deliver 'deliver-pm-s7' $qa7 'QA' $ref7
    $r = Do-Settle 'deliver-pm-s7' $qa7
    Assert-True ($r.json.success -eq $true -and $r.json.data.task_lifecycle -eq 'completed') 'S7 QA settle completes (VERIFY is terminal)'
    $t = Find-Task (Read-Tasks $arch7) 1
    Assert-True ([string]$t.lifecycle -eq 'completed') 'S7 lifecycle completed'

    # ================= S8: legacy null-phase degrade (byte-identical old path) =================
    $arch8 = Join-Path $Work '.rdd/changes/archive/pm-s8'
    New-Item -ItemType Directory -Path (Join-Path $arch8 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch8 'requirements/overview.md') "# pm-s8`n`nS8 旧归档`n"
    Write-Utf8NoBom (Join-Path $arch8 'requirements/t1.md') "# S8 需求`n`n- **描述**：无 phase 旧格式`n"
    Write-Utf8NoBom (Join-Path $arch8 'task.json') '{"version":1,"archive":"pm-s8","tasks":[{"id":1,"title":"S8 存量","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[],"currentWorker":[],"remark":"","lifecycle":"active"}]}'
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch8.Replace('\', '/') + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $true) 'S8 legacy promulgate ok (conservative degrade)' ($r.raw)
    $t = Find-Task (Read-Tasks '.rdd/changes/archive/pm-s8') 1
    Assert-True ($null -eq $t.phase) 'S8 task.json phase stays null (no hidden inference)'
    $b = Read-BridgeJson 'deliver-pm-s8'
    $cto8 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-pm-s8' $cto8 'CTO' "$($arch8.Replace('\','/'))/requirements/t1.md"
    $r = Do-Settle 'deliver-pm-s8' $cto8
    Assert-True ($r.json.success -eq $true -and $r.json.data.flow_operation -eq 'advance CTO->DEV') 'S8 legacy settle walks old advance path' ($r.raw)
    $t = Find-Task (Read-Tasks '.rdd/changes/archive/pm-s8') 1
    Assert-True (@($t.currentOwners) -join '+' -eq 'DEV' -and $null -eq $t.phase) 'S8 advance semantics unchanged (owners=[DEV], phase null)'

    # ================= S9: multi-anchor deps =================
    $arch9 = New-Archive 'pm-s9' '[{"title":"S9 上游","requirement":"requirements/t1.md","currentOwners":["CTO","UX"],"designDocs":[]},{"title":"S9 下游","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[],"dep":1}]'
    $ref9 = "$arch9/requirements/t1.md"
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch9 + '/task.json'), '-NoPush')
    Assert-True ($r.json.success -eq $true) 'S9 promulgate ok'
    $b = Read-BridgeJson 'deliver-pm-s9'
    $upCto = [string]$b.tasks.'1'.stages.CTO; $upUx = [string]$b.tasks.'1'.stages.UX; $down = [string]$b.tasks.'2'.stages.CTO
    $downNode = Find-TreeNode 'deliver-pm-s9' $down
    $downDeps = @()
    if ($null -ne $downNode) { $downDeps = @($downNode.depends_on) | ForEach-Object { [string]$_ } }
    Assert-True ((@($downDeps | Sort-Object) -join '+') -eq (@(@($upCto, $upUx) | Sort-Object) -join '+')) 'S9 downstream depends on BOTH upstream heads' ("down=$down deps=$($downDeps -join '+') expected=$upCto+$upUx")
    Do-Deliver 'deliver-pm-s9' $upCto 'CTO' $ref9
    $rSettle9a = Do-Settle 'deliver-pm-s9' $upCto
    $nx = Invoke-Leaf @('-Command', 'next', '-RunId', 'deliver-pm-s9')
    $blockedHits = @(@($nx.json.data.blocked) | Where-Object { [string]$_.id -eq $down })
    Assert-True ($blockedHits.Count -ge 1) 'S9 downstream still blocked after ONE upstream head settled' ("down=$down settleOk=$($rSettle9a.json.success) blocked=$(@($nx.json.data.blocked) | ForEach-Object { $_.id })")
    Do-Deliver 'deliver-pm-s9' $upUx 'UX' $ref9
    $rSettle9b = Do-Settle 'deliver-pm-s9' $upUx
    $nx = Invoke-Leaf @('-Command', 'next', '-RunId', 'deliver-pm-s9')
    $pendingHits = @(@($nx.json.data.pending) | Where-Object { [string]$_.id -eq $down })
    Assert-True ($pendingHits.Count -ge 1) 'S9 downstream unlocked after BOTH upstream heads terminal' ("down=$down settleOk=$($rSettle9b.json.success) pending=$(@($nx.json.data.pending) | ForEach-Object { $_.id })")

    # ================= S10: set-route whitelist hard constraint (AC-1) =================
    $arch10 = New-Archive 'pm-s10' '[{"title":"S10 白名单","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    # 10a: leaving the current phase without -Phase -> SET_PHASE_REQUIRED
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $arch10, '-TaskId', '1', '-To', 'CTO+DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SET_PHASE_REQUIRED') 'S10a cross-phase -To without -Phase -> SET_PHASE_REQUIRED' ($r.raw)
    # 10b: explicit -Phase but owner outside its whitelist -> PHASE_OWNER_MISMATCH
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $arch10, '-TaskId', '1', '-To', 'CTO+UX', '-Phase', 'IMPL')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PHASE_OWNER_MISMATCH') 'S10b -To CTO+UX not in PhaseRoles[IMPL] -> PHASE_OWNER_MISMATCH' ($r.raw)
    # 10c: rejected writes must not pollute task.json (owners/phase unchanged)
    $t = Find-Task (Read-Tasks $arch10) 1
    Assert-True ((@($t.currentOwners) -join '+') -eq 'CTO' -and [string]$t.phase -eq 'DESIGN') 'S10c task.json untouched after guard rejections' ("owners=$(@($t.currentOwners) -join '+') phase=$($t.phase)")
    # 10d: explicit atomic phase switch is the legal path
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $arch10, '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.phase -eq 'VERIFY') 'S10d -Phase VERIFY -To QA switches atomically' ($r.raw)
    $t = Find-Task (Read-Tasks $arch10) 1
    Assert-True ((@($t.currentOwners) -join '+') -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'S10d owners=[QA] phase=VERIFY persisted'
    # 10e/10f: legacy null-phase task without -Phase
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/pm-s8', '-TaskId', '1', '-To', 'CTO+DEV')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'PHASE_OWNER_MISMATCH') 'S10e legacy spanning set (no stored phase) -> PHASE_OWNER_MISMATCH' ($r.raw)
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/pm-s8', '-TaskId', '1', '-To', 'QA')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SET_PHASE_REQUIRED') 'S10f legacy ambiguous QA (DESIGN/VERIFY) without -Phase -> SET_PHASE_REQUIRED' ($r.raw)

    # ================= S11: terminal lifecycle forces phase=null (AC-1, write side + check guard) =================
    $arch11 = New-Archive 'pm-s11' '[{"title":"S11 终态","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'deprecate', '-Archive', $arch11, '-TaskId', '1')
    Assert-True ($r.json.success -eq $true) 'S11a deprecate ok' ($r.raw)
    $t = Find-Task (Read-Tasks $arch11) 1
    Assert-True ([string]$t.lifecycle -eq 'deprecated' -and $null -eq $t.phase) 'S11a deprecated task carries phase=null' ("lifecycle=$($t.lifecycle) phase=$($t.phase)")
    # hand-written archives violating the invariant are flagged by check (both terminal values)
    $arch11b = Join-Path $Work '.rdd/changes/archive/pm-s11b'
    New-Item -ItemType Directory -Path (Join-Path $arch11b 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch11b 'requirements/overview.md') "# pm-s11b`n`nS11b 归档`n"
    Write-Utf8NoBom (Join-Path $arch11b 'requirements/t1.md') "# S11b 需求`n`n- **描述**：终态残留 phase`n"
    Write-Utf8NoBom (Join-Path $arch11b 'task.json') '{"version":1,"archive":"pm-s11b","tasks":[{"id":1,"title":"S11b deprecated 残留","requirement":"requirements/t1.md","currentOwners":["CTO"],"phase":"DESIGN","designDocs":[],"currentWorker":[],"remark":"","lifecycle":"deprecated"},{"id":2,"title":"S11b completed 残留","requirement":"requirements/t1.md","currentOwners":["QA"],"phase":"VERIFY","designDocs":[],"currentWorker":[],"remark":"","lifecycle":"completed"}]}'
    $chk = Invoke-Flow @('-Command', 'check', '-Archive', '.rdd/changes/archive/pm-s11b')
    $conflicts = @(@($chk.json.data.issues) | Where-Object { $_ -like '*PHASE_LIFECYCLE_CONFLICT*' })
    Assert-True ($chk.json.data.issueCount -ge 2 -and $conflicts.Count -ge 2) 'S11b check flags phase residue on deprecated AND completed tasks' ($chk.raw)

    # ================= S12: show read side exposes normalized phase (AC-4/AC-8) =================
    # (use arch10: still active at QA@VERIFY after S10d; arch2 went completed in S5)
    $r = Invoke-Flow @('-Command', 'show', '-Archive', $arch10)
    $shown = @($r.json.data.tasks)[0]
    Assert-True ($r.json.success -eq $true -and [string]$shown.phase -eq 'VERIFY') 'S12a show exposes phase=VERIFY for phase-aware archive' ("phase=$($shown.phase)")
    $r = Invoke-Flow @('-Command', 'show', '-Archive', '.rdd/changes/archive/pm-s8')
    Assert-True ($r.json.success -eq $true) 'S12b show on legacy archive does not crash' ($r.raw)
    $shown8 = @($r.json.data.tasks)[0]
    Assert-True ($null -eq $shown8.phase) 'S12b legacy show phase=null (conservative degrade)' ("phase=$($shown8.phase)")

    # ================= S13: rollback demands explicit -Phase (edge E2) =================
    $arch13 = New-Archive 'pm-s13' '[{"title":"S13 歧义","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $null = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch13 + '/task.json'), '-NoPush')
    $r = Invoke-Bridge @('-Command', 'rollback', '-RunId', 'deliver-pm-s13', '-NodeId', 'n2', '-To', 'CTO+UX', '-Reason', 'no phase given')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SET_PHASE_REQUIRED') 'S13 rollback without -Phase -> SET_PHASE_REQUIRED' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'rollback', '-RunId', 'deliver-pm-s13', '-NodeId', 'n2', '-To', 'QA', '-Phase', 'DESIGN', '-Reason', 'pending guard check')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'ROLLBACK_REQUIRES_REPORTED') 'S13 pending node still guarded after explicit -To/-Phase (guards ordered)' ($r.raw)
}
finally {
    Pop-Location
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

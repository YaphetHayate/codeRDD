# role handoff gate tests — dev-quality-prescan-gate（统一交接门：桥接第四查 + 链式 set-route 门）
# Covers requirements/dev-quality-prescan-gate.md acceptance 1/2/5 + design regressions:
#   G1  chain: DEV exits without -QualityScanFile      -> HANDOFF_GATE_REJECTED, zero residue
#   G2  chain: full-form clean credential (count=0)    -> routing succeeds
#   G3  chain: violation_count=2                       -> rejected
#   G4  chain: skip+reason (trusted chain-side)        -> routing succeeds
#   G5  chain: non-DEV exit (CTO narrowing)            -> gate no-ops, succeeds
#   G6  chain: exit_code=1 vs count=0 (R4)             -> rejected
#   G7  chain: missing threshold_source (R2)           -> rejected
#   G8  chain: -QualityScanFile path not found         -> rejected
#   G9  chain: violation_count as string "0" (R3 type) -> rejected
#   G10 chain: skip without reason                     -> rejected
#   G11 bridge: DEV report without quality_scan (citations carry .ps1) -> SETTLE_EVIDENCE_REJECTED
#   G12 bridge: violation_count=1 (files cover)        -> SETTLE_EVIDENCE_REJECTED
#   G13 bridge: skip + .md-only citations              -> settle ok, flow tail set-route carries the credential
#   G14 bridge: skip contradicts .ps1 citations (R5)   -> SETTLE_EVIDENCE_REJECTED
#   G15 bridge: coverage gap — cited .ps1 outside files (R6) -> SETTLE_EVIDENCE_REJECTED
#   G16 bridge: full-form clean credential covers .ps1 -> settle ok (4th check + flow tail gate)
#   G17 bridge: QA node needs no quality_scan          -> settle ok (registry no-op)
#   G18 bridge: reclaim rejected-delivery still open after a G11 rejection (recovery channel intact)
#   G19 bridge: rollback of an unqualified DEV delivery -> disposal skip passes the chain gate
#   G20 conformance: the two synced gate blocks are verbatim-identical (source level)
#   G21 conformance: the same fixture yields byte-identical problem details on both scenarios
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway git repo.
# Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# The engine scripts are UTF-8 WITHOUT BOM; Windows PowerShell 5.1 reads a
# BOM-less -File script as UTF-8 only when the console codepage is 65001 (the
# engine .cmd wrappers chcp 65001 for exactly this reason). Child interpreters
# inherit the console CP, so switch it here and restore on exit.
$Script:PrevCp = (chcp | Select-Object -Last 1) -replace '\D', ''
$null = chcp 65001

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('handoff-gate-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

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

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# quality_scan credential presets (the contract's full / skip forms)
$Script:FullClean = @{
    tool = 'code-metrics 1.0'; base = 'HEAD'
    files = @('fixtures/code.ps1')
    thresholds = 'function<=50 lines, nesting<=5 depth'
    threshold_source = 'docs/code-quality.md #1'
    violation_count = 0; exit_code = 0
}
$Script:SkipOk = @{ skip = $true; reason = 'no PowerShell file in the change set' }

# DEV callback with a shapeable quality_scan. $Scan presets: 'full' / 'skip' / $null / custom object.
function New-DevCb { param([string]$NodeId, [string[]]$Refs, $Scan)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'handoff-gate test delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
    }
    $extras = @{ verification = 'smoke ok' }
    if ($null -ne $Scan) { $extras['quality_scan'] = $Scan }
    $cb['extras'] = $extras
    $cbFile = Join-Path $env:TEMP ("hg-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 6)
    return $cbFile
}

# chain-side credential file
function Write-ScanFile { param([string]$Name, $Credential)
    $p = Join-Path $Work $Name
    Write-Utf8NoBom $p ($Credential | ConvertTo-Json -Depth 6)
    return $p
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # shared fixture: a real .ps1 file cited by DEV deliveries (bridge scenario)
    New-Item -ItemType Directory -Path (Join-Path $Work 'fixtures') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $Work 'fixtures/code.ps1') "function Start-Fixture { Write-Output 'fixture' }`n"

    # ================= chain scenario (rdd-flow set-route) =================
    $arch = Join-Path $Work ".rdd/changes/archive/hg-chain"
    New-Item -ItemType Directory -Path (Join-Path $arch 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $arch 'requirements/t1.md') "# hg chain`n`nchain fixture`n"
    $tf = Join-Path $Work 'hg-chain-init.json'
    Write-Utf8NoBom $tf '[{"title":"HG","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/hg-chain', '-TasksFile', 'hg-chain-init.json')
    if ($r.json.success -ne $true) { throw "init failed: $($r.raw)" }

    # G1: DEV exits, no credential -> HANDOFF_GATE_REJECTED + zero residue
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY')
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'HANDOFF_GATE_REJECTED' -and $r.json.error.message -match 'quality_scan: credential absent') 'G1 chain: DEV exit without credential rejected' ($r.raw)
    $t = (Get-Content -LiteralPath (Join-Path $arch 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tasks[0]
    Assert-True (@($t.currentOwners) -join '+' -eq 'DEV' -and [string]$t.phase -eq 'IMPL') 'G1 chain: task.json untouched (zero residue)' ((@($t.currentOwners) -join '+') + '@' + $t.phase)

    # G3: violation_count=2 -> rejected (problem detail captured for G21)
    $p2 = Write-ScanFile 'hg-count2.json' (@{
        tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'function<=50 lines, nesting<=5 depth'; threshold_source = 'docs/code-quality.md #1'
        violation_count = 2; exit_code = 1 })
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p2)
    $Script:ChainCount2Msg = [string]$r.json.error.message
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'HANDOFF_GATE_REJECTED' -and $Script:ChainCount2Msg -match 'violation_count is 2') 'G3 chain: violation_count=2 rejected' ($r.raw)

    # G6: exit_code=1 vs count=0 contradicts -> rejected
    $p4 = Write-ScanFile 'hg-contra.json' (@{
        tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'function<=50 lines, nesting<=5 depth'; threshold_source = 'docs/code-quality.md #1'
        violation_count = 0; exit_code = 1 })
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p4)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'contradicts violation_count') 'G6 chain: exit_code/count contradiction rejected' ($r.raw)

    # G7: missing threshold_source -> rejected
    $p5 = Write-ScanFile 'hg-missing.json' (@{
        tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'function<=50 lines, nesting<=5 depth'
        violation_count = 0; exit_code = 0 })
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p5)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'missing required fields: .*threshold_source') 'G7 chain: missing field rejected' ($r.raw)

    # G8: credential file not found -> rejected
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', (Join-Path $Work 'no-such-file.json'))
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'not found') 'G8 chain: missing credential file rejected' ($r.raw)

    # G9: violation_count as string -> rejected (type check)
    $p6 = Join-Path $Work 'hg-strcount.json'
    Write-Utf8NoBom $p6 '{"tool":"code-metrics 1.0","base":"HEAD","files":["fixtures/code.ps1"],"thresholds":"lim","threshold_source":"docs","violation_count":"0","exit_code":0}'
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p6)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'must be a non-negative integer') 'G9 chain: string-typed count rejected' ($r.raw)

    # G10: skip without reason -> rejected
    $p7 = Write-ScanFile 'hg-noreason.json' (@{ skip = $true })
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p7)
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'skip form requires a non-empty reason') 'G10 chain: skip without reason rejected' ($r.raw)

    # G2: full-form clean credential -> routing succeeds
    $p1 = Write-ScanFile 'hg-clean.json' $Script:FullClean
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p1)
    Assert-True ($r.json.success -eq $true -and @($r.json.data.currentOwners) -join '+' -eq 'QA') 'G2 chain: clean full credential passes' ($r.raw)

    # G4: skip+reason trusted chain-side -> routing succeeds (back to DEV first)
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'DEV', '-Phase', 'IMPL')
    Assert-True ($r.json.success -eq $true) 'G4 chain: pre-step back to DEV' ($r.raw)
    $p3 = Write-ScanFile 'hg-skip.json' $Script:SkipOk
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-chain', '-TaskId', '1', '-To', 'QA', '-Phase', 'VERIFY', '-QualityScanFile', $p3)
    Assert-True ($r.json.success -eq $true -and @($r.json.data.currentOwners) -join '+' -eq 'QA') 'G4 chain: skip+reason passes (trusted declaration)' ($r.raw)

    # G5: non-DEV exit no-ops the gate (CTO narrowing inside DESIGN)
    $archB = Join-Path $Work ".rdd/changes/archive/hg-narrow"
    New-Item -ItemType Directory -Path (Join-Path $archB 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archB 'requirements/t1.md') "# hg narrow`n`nnarrow fixture`n"
    $tfB = Join-Path $Work 'hg-narrow-init.json'
    Write-Utf8NoBom $tfB '[{"title":"HGN","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/hg-narrow', '-TasksFile', 'hg-narrow-init.json')
    if ($r.json.success -ne $true) { throw "init B failed: $($r.raw)" }
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/hg-narrow', '-TaskId', '1', '-To', 'UX')
    Assert-True ($r.json.success -eq $true -and @($r.json.data.currentOwners) -join '+' -eq 'UX') 'G5 chain: CTO exit (unregistered role) no-ops the gate' ($r.raw)

    # ================= bridge scenario (delivery-bridge settle) =================
    $archC = Join-Path $Work ".rdd/changes/archive/hg-bridge"
    New-Item -ItemType Directory -Path (Join-Path $archC 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archC 'requirements/t1.md') "# hg bridge`n`nbridge fixture`n"
    $tfC = Join-Path $Work 'hg-bridge-init.json'
    Write-Utf8NoBom $tfC '[{"title":"HGB","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/hg-bridge', '-TasksFile', 'hg-bridge-init.json')
    if ($r.json.success -ne $true) { throw "init C failed: $($r.raw)" }
    $planC = @{
        planned_at = '2026-10-02T00:00:00Z'; planner = 'test'; risks = @()
        stages = @(@{ id = 'S1'; goal = 'goal'; milestone = 'ms'; task_ids = @(1); batches = @(@(1))
                     acceptance_point = @{ criteria_items = @('smoke'); slice = 'slice' } })
    }
    $planPath = Join-Path $Work 'hg-bridge-plan.json'
    Write-Utf8NoBom $planPath ($planC | ConvertTo-Json -Depth 8)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/hg-bridge/task.json', '-PlanFile', $planPath, '-NoPush')
    Assert-True ($r.json.success -eq $true) 'bridge fixture: promulgate ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-hg-bridge'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    Assert-True ($devHead -ne '') 'bridge fixture: DEV head node mapped' ("head=$devHead")

    function Do-Claim { param([string]$NodeId)
        $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-hg-bridge', '-NodeId', $NodeId, '-Role', 'DEV')
        if ($r.json.success -ne $true) { throw "claim failed ($NodeId): $($r.raw)" }
    }
    function Do-Report { param([string]$CbFile)
        $r = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-hg-bridge', '-Worker', 'DEV', '-CallbackFile', $CbFile)
        if ($r.json.success -ne $true) { throw "report failed: $($r.raw)" }
    }
    function Do-Settle { Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-hg-bridge', '-NodeId', $devHead) }

    # G11: DEV report without quality_scan, citations carry .ps1 -> 4th check rejects
    Do-Claim $devHead
    Do-Report (New-DevCb $devHead @('fixtures/code.ps1') $null)
    $r = Do-Settle
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and $r.json.error.message -match 'quality_scan: credential absent') 'G11 bridge: missing credential rejected (node stays reported)' ($r.raw)

    # G18: reclaim rejected-delivery still recycles the node (recovery channel intact)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-hg-bridge', '-NodeId', $devHead)
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.mode -eq 'rejected-delivery') 'G18 bridge: reclaim rejected-delivery ok after a gate rejection' ($r.raw)
    $b = Read-BridgeJson 'deliver-hg-bridge'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    Do-Claim $devHead

    # G12: violation_count=1 (files cover) -> rejected; capture detail for G21
    Do-Report (New-DevCb $devHead @('fixtures/code.ps1') (@{
        tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('fixtures/code.ps1')
        thresholds = 'function<=50 lines, nesting<=5 depth'; threshold_source = 'docs/code-quality.md #1'
        violation_count = 1; exit_code = 1 }))
    $r = Do-Settle
    $Script:BridgeCountMsg = [string]$r.json.error.message
    Assert-True ($r.json.success -eq $false -and $r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and $Script:BridgeCountMsg -match 'quality_scan: violation_count is 1') 'G12 bridge: violation_count=1 rejected' ($r.raw)

    # G14: skip contradicts .ps1 citations (R5)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-hg-bridge', '-NodeId', $devHead)
    if ($r.json.success -ne $true) { throw "reclaim after G12 failed: $($r.raw)" }
    $b = Read-BridgeJson 'deliver-hg-bridge'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    Do-Claim $devHead
    Do-Report (New-DevCb $devHead @('fixtures/code.ps1') $Script:SkipOk)
    $r = Do-Settle
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'skip contradicts the change list') 'G14 bridge: skip vs .ps1 citations rejected (R5)' ($r.raw)

    # G15: coverage gap — cited .ps1 outside files (R6)
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-hg-bridge', '-NodeId', $devHead)
    if ($r.json.success -ne $true) { throw "reclaim after G14 failed: $($r.raw)" }
    $b = Read-BridgeJson 'deliver-hg-bridge'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    Do-Claim $devHead
    Do-Report (New-DevCb $devHead @('fixtures/code.ps1', '.rdd/changes/archive/hg-bridge/requirements/t1.md') (@{
        tool = 'code-metrics 1.0'; base = 'HEAD'; files = @('other/nothing.ps1')
        thresholds = 'function<=50 lines, nesting<=5 depth'; threshold_source = 'docs/code-quality.md #1'
        violation_count = 0; exit_code = 0 }))
    $r = Do-Settle
    Assert-True ($r.json.success -eq $false -and $r.json.error.message -match 'coverage gap') 'G15 bridge: cited .ps1 outside files rejected (R6)' ($r.raw)

    # G13: skip + .md-only citations -> settle ok, flow tail carries the credential through the chain gate
    $r = Invoke-Bridge @('-Command', 'reclaim', '-RunId', 'deliver-hg-bridge', '-NodeId', $devHead)
    if ($r.json.success -ne $true) { throw "reclaim after G15 failed: $($r.raw)" }
    $b = Read-BridgeJson 'deliver-hg-bridge'
    $devHead = [string]$b.tasks.'1'.stages.DEV
    Do-Claim $devHead
    Do-Report (New-DevCb $devHead @('.rdd/changes/archive/hg-bridge/requirements/t1.md') $Script:SkipOk)
    $r = Do-Settle
    Assert-True ($r.json.success -eq $true) 'G13 bridge: skip + .md-only citations settles ok' ($r.raw)
    $t = (Get-Content -LiteralPath (Join-Path $archC 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tasks[0]
    Assert-True (@($t.currentOwners) -join '+' -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'G13 bridge: flow tail set-route passed the chain gate (IMPL->VERIFY)' ((@($t.currentOwners) -join '+') + '@' + $t.phase)

    # G16: full-form clean credential covering the cited .ps1 -> whole ladder green
    #      (fresh run: the previous run's DEV head is done — re-routing back would
    #      desync bridge mapping, so the happy path gets its own fixture)
    $archF = Join-Path $Work ".rdd/changes/archive/hg-full"
    New-Item -ItemType Directory -Path (Join-Path $archF 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archF 'requirements/t1.md') "# hg full`n`nfull fixture`n"
    $tfF = Join-Path $Work 'hg-full-init.json'
    Write-Utf8NoBom $tfF '[{"title":"HGF","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/hg-full', '-TasksFile', 'hg-full-init.json')
    if ($r.json.success -ne $true) { throw "init F failed: $($r.raw)" }
    Write-Utf8NoBom $planPath ($planC | ConvertTo-Json -Depth 8)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/hg-full/task.json', '-PlanFile', $planPath, '-NoPush')
    if ($r.json.success -ne $true) { throw "promulgate F failed: $($r.raw)" }
    $b = Read-BridgeJson 'deliver-hg-full'
    $devF = [string]$b.tasks.'1'.stages.DEV
    if ([string]::IsNullOrWhiteSpace($devF)) { throw "no DEV node in hg-full" }
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-hg-full', '-NodeId', $devF, '-Role', 'DEV')
    if ($r.json.success -ne $true) { throw "claim F failed: $($r.raw)" }
    $cbF = [ordered]@{
        node_id = $devF; verdict = 'done'; confidence = 0.9; summary = 'full-form happy path'
        citations = @(@{ ref = 'fixtures/code.ps1'; locator = 'L1' }); next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = $Script:FullClean }
    }
    $cbFFile = Join-Path $env:TEMP ("hg-full-$devF.json")
    Write-Utf8NoBom $cbFFile ($cbF | ConvertTo-Json -Depth 6)
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-hg-full', '-Worker', 'DEV', '-CallbackFile', $cbFFile)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-hg-full', '-NodeId', $devF)
    Assert-True ($r.json.success -eq $true) 'G16 bridge: full-form credential settles ok (4th check + tail gate)' ($r.raw)
    $t = (Get-Content -LiteralPath (Join-Path $archF 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tasks[0]
    Assert-True (@($t.currentOwners) -join '+' -eq 'QA' -and [string]$t.phase -eq 'VERIFY') 'G16 bridge: task routed to QA@VERIFY' ((@($t.currentOwners) -join '+') + '@' + $t.phase)

    # G17: QA node needs no quality_scan (registry no-op) + G19 rollback disposal skip
    $archD = Join-Path $Work ".rdd/changes/archive/hg-qa"
    New-Item -ItemType Directory -Path (Join-Path $archD 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archD 'requirements/t1.md') "# hg qa`n`nqa fixture`n"
    $tfD = Join-Path $Work 'hg-qa-init.json'
    Write-Utf8NoBom $tfD '[{"title":"HGQ","requirement":"requirements/t1.md","currentOwners":["DEV"],"designDocs":[]}]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/hg-qa', '-TasksFile', 'hg-qa-init.json')
    if ($r.json.success -ne $true) { throw "init D failed: $($r.raw)" }
    Write-Utf8NoBom $planPath ($planC | ConvertTo-Json -Depth 8)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', '.rdd/changes/archive/hg-qa/task.json', '-PlanFile', $planPath, '-NoPush')
    if ($r.json.success -ne $true) { throw "promulgate D failed: $($r.raw)" }
    $b = Read-BridgeJson 'deliver-hg-qa'
    $devD = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-hg-qa', '-NodeId', $devD, '-Role', 'DEV')
    if ($r.json.success -ne $true) { throw "claim D failed: $($r.raw)" }
    # unqualified DEV delivery: neither verification nor quality_scan
    $cbBad = [ordered]@{
        node_id = $devD; verdict = 'done'; confidence = 0.9; summary = 'unqualified fixture'
        citations = @(@{ ref = 'fixtures/code.ps1'; locator = 'L1' }); next_suggestion = ''
    }
    $cbBadFile = Join-Path $env:TEMP ("hg-bad-$devD.json")
    Write-Utf8NoBom $cbBadFile ($cbBad | ConvertTo-Json -Depth 5)
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-hg-qa', '-Worker', 'DEV', '-CallbackFile', $cbBadFile)
    # G19: rollback recycles the failed DEV delivery — disposal skip must pass the chain gate
    $r = Invoke-Bridge @('-Command', 'rollback', '-RunId', 'deliver-hg-qa', '-NodeId', $devD, '-To', 'CTO', '-Phase', 'DESIGN', '-Reason', 'fixture rollback')
    Assert-True ($r.json.success -eq $true) 'G19 bridge: rollback disposal passes the chain-side gate' ($r.raw)
    $t = (Get-Content -LiteralPath (Join-Path $archD 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tasks[0]
    Assert-True (@($t.currentOwners) -join '+' -eq 'CTO' -and [string]$t.phase -eq 'DESIGN') 'G19 bridge: task routed back CTO@DESIGN' ((@($t.currentOwners) -join '+') + '@' + $t.phase)

    # G17: QA settle without any quality_scan (registry no-op for non-DEV roles)
    #      rides the hg-full run — G16's settle grafted its live QA node
    $b = Read-BridgeJson 'deliver-hg-full'
    $qaNode = [string]$b.tasks.'1'.stages.QA
    if ([string]::IsNullOrWhiteSpace($qaNode)) { throw "no live QA node in hg-full" }
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-hg-full', '-NodeId', $qaNode, '-Role', 'QA')
    if ($r.json.success -ne $true) { throw "claim QA failed: $($r.raw)" }
    $cbQa = [ordered]@{
        node_id = $qaNode; verdict = 'done'; confidence = 0.9; summary = 'qa fixture'
        citations = @(@{ ref = 'fixtures/code.ps1'; locator = 'L1' }); next_suggestion = ''
        extras = @{ verification = 'qa ok' }
    }
    $cbQaFile = Join-Path $env:TEMP ("hg-qa-$qaNode.json")
    Write-Utf8NoBom $cbQaFile ($cbQa | ConvertTo-Json -Depth 5)
    $null = Invoke-Leaf @('-Command', 'report', '-RunId', 'deliver-hg-full', '-Worker', 'QA', '-CallbackFile', $cbQaFile)
    $r = Invoke-Bridge @('-Command', 'settle', '-RunId', 'deliver-hg-full', '-NodeId', $qaNode)
    Assert-True ($r.json.success -eq $true) 'G17 bridge: QA delivery without quality_scan settles ok (no-op)' ($r.raw)

    # ================= conformance (G20/G21) =================
    # G20: the synced gate blocks are verbatim-identical in both CLIs
    function Get-GateBlock { param([string]$Path)
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^# === Role handoff gate') { $start = $i; break }
        }
        if ($start -lt 0) { return $null }
        $block = @()
        for ($i = $start; $i -lt $lines.Count; $i++) {
            # section terminator: either marker style ('# === ...' in delivery-bridge,
            # '# --- ...' in rdd-flow) — the block itself never starts a line with them
            if ($i -gt $start -and $lines[$i] -match '^# (===|---) ') { break }
            $block += $lines[$i]
        }
        return $block
    }
    $blockA = Get-GateBlock (Join-Path $EngineDir 'delivery-bridge.ps1')
    $blockB = Get-GateBlock (Join-Path $EngineDir 'rdd-flow.ps1')
    Assert-True ($null -ne $blockA -and $null -ne $blockB -and $blockA.Count -gt 20) 'G20 conformance: gate blocks present in both CLIs' ("A=$($blockA.Count) B=$($blockB.Count)")
    $identical = ($blockA.Count -eq $blockB.Count)
    $diffIx = -1
    if ($identical) {
        for ($i = 0; $i -lt $blockA.Count; $i++) {
            if ([string]$blockA[$i] -ne [string]$blockB[$i]) { $identical = $false; $diffIx = $i; break }
        }
    }
    $diffNote = $(if ($diffIx -ge 0) { "first diff at line $($diffIx + 1): '$($blockA[$diffIx])' vs '$($blockB[$diffIx])'" } else { "counts: $($blockA.Count) vs $($blockB.Count)" })
    Assert-True $identical 'G20 conformance: the two gate blocks are verbatim-identical' $diffNote

    # G21: the same count=2 fixture yields the identical problem detail on both scenarios
    #      (chain G3 message vs bridge G12 uses count=1 — re-derive the bridge side with count=2)
    $chainDetail = ''
    if ($Script:ChainCount2Msg -match '(quality_scan: violation_count is 2[^.]*)') { $chainDetail = $Matches[1] }
    $bridgeDetail = ''
    if ($Script:BridgeCountMsg -match '(quality_scan: violation_count is 1[^.]*)') { $bridgeDetail = $Matches[1] }
    Assert-True ($chainDetail -ne '' -and $bridgeDetail -ne '') 'G21 conformance: both scenario messages carry the quality_scan detail' ("chain='$chainDetail' bridge='$bridgeDetail'")
    $chainNorm = $chainDetail -replace 'is 2', 'is N'
    $bridgeNorm = $bridgeDetail -replace 'is 1', 'is N'
    Assert-True ($chainNorm -eq $bridgeNorm) 'G21 conformance: problem details identical across scenarios (modulo the count)' ("chain='$chainNorm' bridge='$bridgeNorm'")
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Script:PrevCp -match '^\d+$' -and $Script:PrevCp -ne '65001') { $null = chcp $Script:PrevCp }
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ""
Write-Output ("handoff-gate tests: {0} passed, {1} failed" -f ($Results.Count - $failed.Count), $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

# goal-tree coverage gate tests (task-dispatch-guide R1/R4, M1 acceptance)
# Runs the engine scripts under the production interpreter (Windows PowerShell 5.1)
# against a throwaway git repo. Exit code 0 = all green.
#
# Usage: pwsh -File test-goal-tree-gates.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$RunPs1    = Join-Path $EngineDir 'goal-tree.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('goaltree-gates-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-GoalTree { param([string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RunPs1) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    try { return ($out | ConvertFrom-Json) } catch { return $null }
}
function Invoke-GoalTreeLeaf { param([string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LeafPs1) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    try { return ($out | ConvertFrom-Json) } catch { return $null }
}

function Write-TempJson { param([string]$Name, $Obj)
    $p = Join-Path $Work $Name
    [System.IO.File]::WriteAllText($p, ($Obj | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

function New-Callback { param([string]$NodeId, $Extras = $null, [string]$Ref = 'notes.md')
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.8; summary = 'unit-test callback'
        citations = @(@{ ref = $Ref; locator = 'L1' }); next_suggestion = ''
    }
    if ($null -ne $Extras) { $cb.extras = $Extras }
    return $cb
}

function New-CleanEvidence { param([string]$Ref = 'notes.md', [string]$Tmin = '2021-03-04 14:30:00', [string]$Tmax = '2021-03-04 15:00:00')
    # M2 R8-valid objectized evidence: artifact exists under RefRoots, telemetry covers the cell
    return @{ ref = $Ref; tmin = $Tmin; tmax = $Tmax; rows = 100 }
}

# --- setup throwaway repo ---
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Push-Location $Work
try {
    git init -q 2>$null | Out-Null
    Set-Content -Path (Join-Path $Work 'notes.md') -Value 'fixture note' -Encoding UTF8
    # M2 artifact fixtures: sweep outputs carrying their own timestamp telemetry
    $csvLines = @(); for ($mi = 870; $mi -lt 900; $mi++) { $csvLines += ('2021-03-04 {0:00}:{1:00}:00,row{2}' -f [int][Math]::Floor($mi / 60), ($mi % 60), ($mi - 870)) }
    Set-Content -Path (Join-Path $Work 'sweep-out.csv') -Value $csvLines -Encoding UTF8
    $tailLines = @(); for ($mi = 890; $mi -lt 900; $mi++) { $tailLines += ('2021-03-04 {0:00}:{1:00}:00,row{2}' -f [int][Math]::Floor($mi / 60), ($mi % 60), ($mi - 890)) }
    Set-Content -Path (Join-Path $Work 'sweep-tail.csv') -Value $tailLines -Encoding UTF8

    $Domain = '{"intervals":[["2021-03-04 14:30:00","2021-03-04 15:00:00"]],"scope":["telemetry:Bank"]}'
    # NOTE: written as raw JSON — PS5.1 ConvertTo-Json unwraps single-element nested arrays
    $DomainFile = Join-Path $Work 'domain.json'
    [System.IO.File]::WriteAllText($DomainFile, $Domain, (New-Object System.Text.UTF8Encoding($false)))

    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-bad4','-Goal','g','-RefRoots','.','-DomainJsonFile',"$Work\nope.json")
    Assert-True ($null -ne $r -and $r.success -eq $false -and $r.error.code -eq 'DOMAIN_FILE_NOT_FOUND') 'T1c missing domain file rejected'

    # ===== T1 bad domain json =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-bad','-Goal','g','-RefRoots','.','-DomainJson','{"intervals":[["nope","x"]]}')
    Assert-True ($null -ne $r -and $r.success -eq $false -and $r.error.code -eq 'DOMAIN_UNPARSEABLE') 'T1 bad interval rejected'

    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-bad2','-Goal','g','-RefRoots','.','-DomainJson','not json')
    Assert-True ($null -ne $r -and $r.success -eq $false -and $r.error.code -eq 'DOMAIN_UNPARSEABLE') 'T1b non-json domain rejected'

    # ===== T2 bad gate mode =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-bad3','-Goal','g','-RefRoots','.','-GateMode','strict')
    Assert-True ($null -ne $r -and $r.success -eq $false -and $r.error.code -eq 'INVALID_GATE_MODE') 'T2 invalid gate mode rejected'

    # ===== Scenario A: enforce run (full happy path + coverage-gap replay) =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-a','-Goal','unit goal','-RefRoots','.','-NodeWidth','8','-DomainJsonFile',$DomainFile,'-GateMode','enforce')
    Assert-True ($r.success -eq $true -and $r.data.gates.r1_settle -eq 'enforce' -and $r.data.domain.intervals.Count -eq 1) 'T3 start with domain+enforce'

    $r = Invoke-GoalTree @('-Command','round-start','-RunId','gate-a')
    Assert-True ($r.success -eq $true) 'T3b round-start'

    # T4 sweep without manifest
    $tf = Write-TempJson 't4.json' @(@{ title='no-manifest sweep'; task='body'; type='sweep' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-a','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'GRAFT_MANIFEST_REQUIRED') 'T4 sweep graft without manifest rejected'

    # T5 duplicate cell ids
    $cells = @(
        @{ id='c1'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='metric' }
        @{ id='c1'; interval=@('2021-03-04 14:40:00','2021-03-04 14:50:00'); modality='metric' }
    )
    $tf = Write-TempJson 't5.json' @(@{ title='dup'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$cells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-a','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'GRAFT_MANIFEST_INVALID') 'T5 duplicate cell ids rejected'

    # T6 graft real nodes: n2 sweep + n3 plain
    $n2cells = @(
        @{ id='c01'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='metric' }
        @{ id='c02'; interval=@('2021-03-04 14:40:00','2021-03-04 14:50:00'); modality='metric' }
        @{ id='c03'; interval=@('2021-03-04 14:50:00','2021-03-04 15:00:00'); modality='metric' }
    )
    $tasks = @(
        @{ title='m-sweep'; task='metric sweep body'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$n2cells } }
        @{ title='plain-probe'; task='plain body' }
    )
    $tf = Write-TempJson 't6.json' $tasks
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-a','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $true -and $r.data.count -eq 2 -and $r.data.sweep_manifests -eq 1) 'T6 graft sweep+plain'
    $n2id = $r.data.grafted[0].id; $n3id = $r.data.grafted[1].id
    Assert-True (Test-Path (Join-Path $Work ".rdd/goal-trees/gate-a/state/manifests/$n2id.json")) 'T6b sidecar file exists'
    Assert-True (-not (Test-Path (Join-Path $Work ".rdd/goal-trees/gate-a/state/manifests/$n3id.json"))) 'T6c plain node has no sidecar'

    # leaf status shows the manifest
    $r = Invoke-GoalTreeLeaf @('-Command','status','-RunId','gate-a','-NodeId',$n2id)
    Assert-True ($r.success -eq $true -and $null -ne $r.data.manifest -and @($r.data.manifest.declared.cells).Count -eq 3) 'T6d leaf status exposes manifest'

    # T7 report without extras.manifest -> note; settle enforce blocked
    $r = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-a','-NodeId',$n2id,'-Worker','w1')
    Assert-True ($r.success -eq $true) 'T7 claim n2'
    $cf = Write-TempJson 'cb-nomani.json' (New-Callback $n2id)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-a','-Worker','w1','-CallbackFile',$cf)
    $notesJoined = (@($r.data.validation.notes) -join ' ')
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and $notesJoined -match 'manifest_missing') 'T7b report accepted with manifest_missing note'
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-a','-NodeId',$n2id)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'SETTLE_MANIFEST_INCOMPLETE' -and $r.error.message -match 'c01') 'T7c settle enforce blocked on pending cells'

    # stuck reported node -> prune, re-graft n2b
    $r = Invoke-GoalTree @('-Command','prune','-RunId','gate-a','-NodeId',$n2id,'-Reason','manifest never filled')
    Assert-True ($r.success -eq $true) 'T8 prune stuck node'

    $tf = Write-TempJson 't8.json' @(@{ title='m-sweep-2'; task='metric sweep body v2'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$n2cells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-a','-Parent','n1','-TasksFile',$tf)
    $n2b = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-a','-NodeId',$n2b,'-Worker','w2')

    # T9 fill with bad_status + unknown_cell + escalated mix
    $extras = @{ manifest = @{ filled = @{
        c01 = @{ status='clean';   evidence=@(New-CleanEvidence); note='' }
        c02 = @{ status='bogus' }
        c03 = @{ status='escalated'; note='cannot cover trace slice in budget' }
        zz =  @{ status='clean' }
    } } }
    $cf = Write-TempJson 'cb-bad.json' (New-Callback $n2b $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-a','-Worker','w2','-CallbackFile',$cf)
    $notesJoined = (@($r.data.validation.notes) -join ' ')
    Assert-True ($r.success -eq $true -and $notesJoined -match 'bad_status' -and $notesJoined -match 'unknown_cell') 'T9 bad fill notes recorded'

    $sidecar = Get-Content (Join-Path $Work ".rdd/goal-trees/gate-a/state/manifests/$n2b.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($sidecar.filled.c01.status -eq 'clean' -and $sidecar.filled.c03.status -eq 'escalated' -and $null -eq $sidecar.filled.c02) 'T9b sidecar keeps valid fills only'

    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-a','-NodeId',$n2b)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'SETTLE_MANIFEST_INCOMPLETE' -and $r.error.message -match 'c02') 'T9c settle still blocked on c02'

    # stuck again -> prune, re-graft n2c with clean fill
    $null = Invoke-GoalTree @('-Command','prune','-RunId','gate-a','-NodeId',$n2b,'-Reason','bad fill')
    $tf = Write-TempJson 't10.json' @(@{ title='m-sweep-3'; task='metric sweep body v3'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$n2cells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-a','-Parent','n1','-TasksFile',$tf)
    $n2c = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-a','-NodeId',$n2c,'-Worker','w3')
    $extras = @{ manifest = @{ filled = @{
        c01 = @{ status='clean'; evidence=@(New-CleanEvidence) }
        c02 = @{ status='clean'; evidence=@(New-CleanEvidence) }
        c03 = @{ status='escalated'; note='gap: no trace modality covered' }
    } } }
    $cf = Write-TempJson 'cb-ok.json' (New-Callback $n2c $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-a','-Worker','w3','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and (@($r.data.validation.notes) -join ' ') -notmatch 'manifest') 'T10 clean fill accepted without manifest notes'

    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-a','-NodeId',$n2c)
    Assert-True ($r.success -eq $true -and $null -eq $r.data.r1_warning) 'T10b settle enforce passes with terminal fills'

    # plain node lifecycle in a gated run (legacy path)
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-a','-NodeId',$n3id,'-Worker','w4')
    $cf = Write-TempJson 'cb-plain.json' (New-Callback $n3id)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-a','-Worker','w4','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and (@($r.data.validation.notes) -join ' ') -notmatch 'manifest') 'T11 plain node report unaffected'
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-a','-NodeId',$n3id)
    Assert-True ($r.success -eq $true) 'T11b plain node settle unaffected'

    # T12 R4 replay: escalated [14:50,15:00] => achieved blocked
    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-a','-Outcome','achieved','-Summary','s','-AnchorNodeId',$n2c)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'CONCLUDE_COVERAGE_GAPS' -and $r.error.message -match '14:50:00' -and $r.error.message -match '15:00:00') 'T12 R4 enforce blocks achieved with gap detail (coverage-gap replay)'

    # status shows the gap mid-run
    $r = Invoke-GoalTree @('-Command','status','-RunId','gate-a')
    Assert-True ($r.success -eq $true -and @($r.data.coverage.gaps).Count -eq 1 -and $r.data.coverage.gaps[0] -match '14:50') 'T12b status exposes coverage gap'

    # T13 close the gap: sweep node covering [14:50,15:00]
    $gapCells = @(
        @{ id='d01'; interval=@('2021-03-04 14:50:00','2021-03-04 14:55:00'); modality='trace' }
        @{ id='d02'; interval=@('2021-03-04 14:55:00','2021-03-04 15:00:00'); modality='trace' }
    )
    $tf = Write-TempJson 't13.json' @(@{ title='gap-sweep'; task='cover the gap'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=300}; cells=$gapCells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-a','-Parent','n1','-TasksFile',$tf)
    $n4 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-a','-NodeId',$n4,'-Worker','w5')
    $extras = @{ findings = @(
        @{ entity='tomcat'; interval=@('2021-03-04 14:50:00','2021-03-04 14:55:00'); evidence=@('notes.md'); note='burst' }
    ); manifest = @{ filled = @{
        d01 = @{ status='found'; evidence=@(New-CleanEvidence 'notes.md' '2021-03-04 14:50:00' '2021-03-04 15:00:00'); note='tomcat burst' }
        d02 = @{ status='clean'; evidence=@(New-CleanEvidence 'notes.md' '2021-03-04 14:50:00' '2021-03-04 15:00:00') }
    } } }
    $cf = Write-TempJson 'cb-gap.json' (New-Callback $n4 $extras)
    $null = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-a','-Worker','w5','-CallbackFile',$cf)
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-a','-NodeId',$n4)
    Assert-True ($r.success -eq $true) 'T13 gap sweep settled'

    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-a','-Outcome','achieved','-Summary','gap closed','-AnchorNodeId',$n2c)
    Assert-True ($r.success -eq $true -and $r.data.outcome -eq 'achieved' -and $r.data.r4 -match 'covered') 'T13b achieved allowed after gap covered'

    # T12c resume exposes coverage while the run is live (replayed on a fresh partial run)
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-r','-Goal','g','-RefRoots','.','-NodeWidth','4','-DomainJsonFile',$DomainFile,'-GateMode','enforce')
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-r')
    $halfCells = @(
        @{ id='h1'; interval=@('2021-03-04 14:30:00','2021-03-04 14:45:00'); modality='metric' }
    )
    $halfTask = @{ title='half-sweep'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=900}; cells=$halfCells } }
    $tf = Write-TempJson 'r1.json' @($halfTask)
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-r','-Parent','n1','-TasksFile',$tf)
    $rn2 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-r','-NodeId',$rn2,'-Worker','w9')
    $extras = @{ manifest = @{ filled = @{ h1 = @{ status='clean'; evidence=@(New-CleanEvidence) } } } }
    $cf = Write-TempJson 'cb-r1.json' (New-Callback $rn2 $extras)
    $null = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-r','-Worker','w9','-CallbackFile',$cf)
    $null = Invoke-GoalTree @('-Command','settle','-RunId','gate-r','-NodeId',$rn2)
    $r = Invoke-GoalTree @('-Command','resume','-RunId','gate-r')
    Assert-True ($r.success -eq $true -and $null -ne $r.data.coverage -and @($r.data.coverage.gaps).Count -eq 1 -and $r.data.coverage.gaps[0] -match '14:45:00') 'T12c resume exposes coverage gap'

    # ===== Scenario B: warn run (defaults) + override =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-b','-Goal','g','-RefRoots','.','-DomainJsonFile',$DomainFile)
    Assert-True ($r.success -eq $true -and $null -eq $r.data.gates) 'T14 warn defaults'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-b')
    $tf = Write-TempJson 'b1.json' @(@{ title='sweep'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$n2cells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-b','-Parent','n1','-TasksFile',$tf)
    $bn2 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-b','-NodeId',$bn2,'-Worker','w1')
    $cf = Write-TempJson 'cb-b1.json' (New-Callback $bn2)   # no manifest fill
    $null = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-b','-Worker','w1','-CallbackFile',$cf)
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-b','-NodeId',$bn2)
    Assert-True ($r.success -eq $true -and $r.data.r1_warning -match 'R1-WARN' -and $r.data.r1_warning -match 'c01') 'T15 settle warn passes with R1 warning'

    # conclude with one-shot enforce override -> blocked
    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-b','-Outcome','achieved','-Summary','s','-AnchorNodeId',$bn2,'-Override','enforce')
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'CONCLUDE_COVERAGE_GAPS') 'T16 override enforce blocks warn run'

    # conclude plain warn -> allowed with R4 warning (no fills at all => whole domain is the gap)
    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-b','-Outcome','achieved','-Summary','s','-AnchorNodeId',$bn2)
    Assert-True ($r.success -eq $true -and $r.data.r4 -match 'R4-WARN' -and $r.data.r4 -match '14:30:00' -and $r.data.r4 -match '15:00:00') 'T17 warn conclude allowed with R4 warning'

    # ===== Scenario C: no domain -> fail-open =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-c','-Goal','g','-RefRoots','.')
    Assert-True ($r.success -eq $true) 'T18 start without domain'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-c')
    $tf = Write-TempJson 'c1.json' @(@{ title='probe'; task='plain' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-c','-Parent','n1','-TasksFile',$tf)
    $cn2 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-c','-NodeId',$cn2,'-Worker','w1')
    $cf = Write-TempJson 'cb-c1.json' (New-Callback $cn2)
    $null = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-c','-Worker','w1','-CallbackFile',$cf)
    $null = Invoke-GoalTree @('-Command','settle','-RunId','gate-c','-NodeId',$cn2)
    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-c','-Outcome','achieved','-Summary','s','-AnchorNodeId',$cn2,'-GateMode','enforce')
    Assert-True ($r.success -eq $true -and $null -eq $r.data.r4) 'T19 no-domain run concludes without R4'

    # ===== Scenario D: coverage_tolerance_s (G3-3) =====
    # helper: run whose only sweep cell is clean but stops 60s short of the domain end
    function Invoke-TailRun { param([string]$RunId, [int]$Tol)
        $extra = @(); if ($Tol -ge 0) { $extra = @('-CoverageToleranceS', "$Tol") }
        $r = Invoke-GoalTree (@('-Command','start','-RunId',$RunId,'-Goal','g','-RefRoots','.','-DomainJsonFile',$DomainFile,'-GateMode','enforce') + $extra)
        Assert-True ($r.success -eq $true -and $r.data.coverage_tolerance_s -eq $Tol) "T20 $RunId start (tol=$Tol)"
        $null = Invoke-GoalTree @('-Command','round-start','-RunId',$RunId)
        $tailCells = @(
            @{ id='t1'; interval=@('2021-03-04 14:30:00','2021-03-04 14:59:00'); modality='metric' }
        )
        $tf = Write-TempJson "$RunId-tasks.json" @(@{ title='tail-sweep'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=1740}; cells=$tailCells } })
        $r = Invoke-GoalTree @('-Command','graft','-RunId',$RunId,'-Parent','n1','-TasksFile',$tf)
        $tn = $r.data.grafted[0].id
        $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId',$RunId,'-NodeId',$tn,'-Worker','wt')
        $extras = @{ manifest = @{ filled = @{ t1 = @{ status='clean'; evidence=@(New-CleanEvidence 'notes.md' '2021-03-04 14:30:00' '2021-03-04 15:00:00') } } } }
        $cf = Write-TempJson "cb-$RunId.json" (New-Callback $tn $extras)
        $null = Invoke-GoalTreeLeaf @('-Command','report','-RunId',$RunId,'-Worker','wt','-CallbackFile',$cf)
        $null = Invoke-GoalTree @('-Command','settle','-RunId',$RunId,'-NodeId',$tn)
        return Invoke-GoalTree @('-Command','conclude','-RunId',$RunId,'-Outcome','achieved','-Summary','s','-AnchorNodeId',$tn)
    }
    # tolerance=60: the 60s edge tail ([14:59:00,15:00:00]) is noise, achieved passes (G3-3 preset semantics)
    $r = Invoke-TailRun 'gate-tol60' 60
    Assert-True ($r.success -eq $true -and $r.data.outcome -eq 'achieved') 'T20b 60s tail tolerated at tolerance=60'
    # default 0: the same tail is a gap, enforce blocks (structural hole detection stays sharp)
    $r = Invoke-TailRun 'gate-tol0' 0
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'CONCLUDE_COVERAGE_GAPS' -and $r.error.message -match '14:59:00') 'T20c 60s tail blocked at tolerance=0'

    # ===== Scenario E (M2): R2 fold + R8 evidence + D1 findings association + D2 spotcheck =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-e','-Goal','g','-RefRoots','.','-MaxRounds','1','-DomainJsonFile',$DomainFile,'-GateMode','enforce')
    Assert-True ($r.success -eq $true) 'E0 start gate-e'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-e')
    $ecells = @(
        @{ id='e1'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='metric' }
        @{ id='e2'; interval=@('2021-03-04 14:40:00','2021-03-04 14:50:00'); modality='metric' }
        @{ id='e3'; interval=@('2021-03-04 14:50:00','2021-03-04 15:00:00'); modality='metric' }
        @{ id='e4'; interval=@('2021-03-04 14:30:00','2021-03-04 14:35:00'); modality='trace' }
    )
    $tf = Write-TempJson 'e1.json' @(@{ title='e-sweep'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$ecells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-e','-Parent','n1','-TasksFile',$tf)
    $en1 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-e','-NodeId',$en1,'-Worker','we1')
    # folded-peak replay: the findings row "14:39 & 14:57" folds two episodes into one
    $extras = @{ findings = @(
        @{ entity='CPU-0_SingleCpuUtil'; interval=@('2021-03-04 14:39:00','2021-03-04 14:40:00'); evidence=@('sweep-out.csv'); note='burst 87%' }
        @{ entity='CPU-0_SingleCpuUtil'; interval=@('2021-03-04 14:39:00','2021-03-04 14:40:00'); evidence=@('sweep-out.csv'); note='14:39 & 14:57 episodic bursts' }
    ); manifest = @{ filled = @{
        e1 = @{ status='found'; evidence=@(New-CleanEvidence 'sweep-out.csv' '2021-03-04 14:30:00' '2021-03-04 14:59:00'); note='CPU-0 hog' }
        e2 = @{ status='clean'; evidence=@('sweep-out.csv') }
        e3 = @{ status='clean'; evidence=@(New-CleanEvidence 'sweep-out.csv' '2021-03-04 14:30:00' '2021-03-04 15:00:00') }
        e4 = @{ status='found'; evidence=@(New-CleanEvidence 'sweep-out.csv' '2021-03-04 14:30:00' '2021-03-04 14:59:00') }
    } } }
    $cf = Write-TempJson 'cb-e1.json' (New-Callback $en1 $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-e','-Worker','we1','-CallbackFile',$cf)
    $en = (@($r.data.validation.notes) -join ' ')
    Assert-True ($r.success -eq $true -and $en -match 'fold_detected' -and $en -match '14:39' -and $en -match '14:57') 'E1 folded findings row detected (multi-peak folding pattern)'
    Assert-True ($en -match 'r8_evidence_rejected: cell .e2.' -and $en -match 'bare ref') 'E2 clean cell with bare-string evidence rejected (R8)'
    Assert-True ($en -match 'findings_missing: cell .e4.') 'E3 found cell without linked findings row rejected (D1)'

    $sidecar = Get-Content (Join-Path $Work ".rdd/goal-trees/gate-e/state/manifests/$en1.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($sidecar.filled.e1.status -eq 'found' -and $sidecar.filled.e3.status -eq 'clean' -and $null -eq $sidecar.filled.e2 -and $null -eq $sidecar.filled.e4) 'E4 sidecar keeps only R2/R8-valid fills'
    Assert-True (@($sidecar.findings).Count -eq 1 -and $sidecar.findings[0].entity -eq 'CPU-0_SingleCpuUtil') 'E5 valid findings row persisted to sidecar'

    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-e','-NodeId',$en1)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'SETTLE_MANIFEST_INCOMPLETE' -and $r.error.message -match 'e2' -and $r.error.message -match 'e4') 'E6 R1 blocks settle on R8/D1-invalidated cells'

    # D2 spotcheck: declared range covers the cell but the artifact only observed 14:50..14:59 -> note-only
    $null = Invoke-GoalTree @('-Command','prune','-RunId','gate-e','-NodeId',$en1,'-Reason','invalid fills')
    $tf = Write-TempJson 'e2.json' @(@{ title='e-sweep2'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=@(@{ id='f1'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='metric' }) } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-e','-Parent','n1','-TasksFile',$tf)
    $en2 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-e','-NodeId',$en2,'-Worker','we2')
    $extras = @{ manifest = @{ filled = @{
        f1 = @{ status='clean'; evidence=@(@{ ref='sweep-tail.csv'; tmin='2021-03-04 14:30:00'; tmax='2021-03-04 14:40:00'; rows=10 }) }
    } } }
    $cf = Write-TempJson 'cb-e2.json' (New-Callback $en2 $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-e','-Worker','we2','-CallbackFile',$cf)
    $en = (@($r.data.validation.notes) -join ' ')
    Assert-True ($r.success -eq $true -and $en -match 'spotcheck_mismatch' -and $en -match 'sweep-tail.csv') 'E7 spotcheck mismatch recorded (note-only)'
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-e','-NodeId',$en2)
    Assert-True ($r.success -eq $true) 'E8 D2: spotcheck note does not invalidate the cell (settle passes)'

    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-e','-Outcome','budget_exhausted','-Summary','honest end')
    Assert-True ($r.success -eq $true) 'E9 gate-e concludes honestly (budget_exhausted exempt from R4)'

    # ===== Scenario F (M3/R5 + role awareness): probe contract + role traceability =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-f','-Goal','g','-RefRoots','.')
    Assert-True ($r.success -eq $true) 'F0 start gate-f'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-f')

    # P1 probe without falsification_duty -> hard block at graft (zero side effects)
    $tf = Write-TempJson 'f1.json' @(@{ title='probe-no-duty'; task='verify X'; type='probe' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'GRAFT_FALSIFICATION_REQUIRED') 'P1 probe graft without falsification_duty rejected'

    # R3 whitespace-only falsification_duty -> same hard block
    $tf = Write-TempJson 'f2.json' @(@{ title='probe-empty-duty'; task='verify X'; type='probe'; falsification_duty='   ' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'GRAFT_FALSIFICATION_REQUIRED') 'R3 empty falsification_duty rejected'

    # R1 role format invalid (uppercase / spaces) -> ROLE_INVALID
    $tf = Write-TempJson 'f3.json' @(@{ title='bad-role'; task='b'; role='Metric-Analyst' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'ROLE_INVALID') 'R1a uppercase role rejected'
    $tf = Write-TempJson 'f4.json' @(@{ title='bad-role2'; task='b'; role='metric analyst' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'ROLE_INVALID') 'R1b spaced role rejected'

    # P2 valid probe graft -> three fields persisted flat on the node + visible via leaf status
    $tf = Write-TempJson 'f5.json' @(@{ title='m-probe'; task='try to refute X'; type='probe'; role='metric-analyst'; falsification_duty='check pre-window baseline on other dates' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $true -and $r.data.count -eq 1 -and $r.data.grafted[0].role -eq 'metric-analyst' -and $r.data.grafted[0].type -eq 'probe') 'P2a probe graft accepted with role/type echo'
    $pn = $r.data.grafted[0].id
    $treeJson = Get-Content (Join-Path $Work ".rdd/goal-trees/gate-f/state/tree.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $pnode = @($treeJson.nodes | Where-Object { $_.id -eq $pn })[0]
    Assert-True ($pnode.type -eq 'probe' -and $pnode.role -eq 'metric-analyst' -and $pnode.falsification_duty -eq 'check pre-window baseline on other dates') 'P2b node persists type/role/falsification_duty flat'
    $r = Invoke-GoalTreeLeaf @('-Command','status','-RunId','gate-f','-NodeId',$pn)
    Assert-True ($r.success -eq $true -and $r.data.node.type -eq 'probe' -and $r.data.node.role -eq 'metric-analyst' -and $r.data.node.falsification_duty -eq 'check pre-window baseline on other dates') 'P2c leaf status exposes the three fields'

    # P3 probe report with three-valued extras.probe -> accepted, no R5 note, ledger entry carries role
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-f','-NodeId',$pn,'-Worker','wp1')
    $extras = @{ probe = @{ verdict = 'refuted'; falsification_attempted = @('pre-window baseline check: no envelope crossing before the window') } }
    $cf = Write-TempJson 'cb-p3.json' (New-Callback $pn $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-f','-Worker','wp1','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and ((@($r.data.validation.notes) -join ' ') -notmatch 'probe_')) 'P3a probe report accepted without R5 notes'
    $ledgerLines = @([System.IO.File]::ReadAllLines((Join-Path $Work ".rdd/goal-trees/gate-f/state/ledger.jsonl")) | Where-Object { $_.Trim() -ne '' })
    $lastEntry = ($ledgerLines[-1] | ConvertFrom-Json)
    Assert-True ($lastEntry.role -eq 'metric-analyst' -and $lastEntry.callback.extras.probe.verdict -eq 'refuted') 'P3b ledger entry carries node role at top level'

    # P4 missing extras.probe -> accepted + note
    $tf = Write-TempJson 'f6.json' @(@{ title='p4-probe'; task='try to refute Y'; type='probe'; role='log-analyst'; falsification_duty='check error templates across the window' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    $pn4 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-f','-NodeId',$pn4,'-Worker','wp2')
    $cf = Write-TempJson 'cb-p4.json' (New-Callback $pn4)   # no extras.probe
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-f','-Worker','wp2','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and ((@($r.data.validation.notes) -join ' ') -match 'probe_extras_missing')) 'P4 missing extras.probe accepted with note'

    # P5 non-three-valued verdict -> accepted + note (fresh node: report is one-shot semantics)
    $tf = Write-TempJson 'f7.json' @(@{ title='p5-probe'; task='try to refute Z'; type='probe'; role='trace-analyst'; falsification_duty='sample slow traces and compare parent/child durations' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    $pn5 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-f','-NodeId',$pn5,'-Worker','wp3')
    $extras = @{ probe = @{ verdict = 'confirmed'; falsification_attempted = @('slow-trace sampling') } }
    $cf = Write-TempJson 'cb-p5.json' (New-Callback $pn5 $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-f','-Worker','wp3','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and ((@($r.data.validation.notes) -join ' ') -match 'probe_verdict_invalid')) 'P5 non-three-valued verdict accepted with note'

    # R2 legacy task (no role/type): graft/report/next/settle behavior unchanged, new fields null
    $tf = Write-TempJson 'f8.json' @(@{ title='legacy-plain'; task='legacy body' })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-f','-Parent','n1','-TasksFile',$tf)
    Assert-True ($r.success -eq $true -and $r.data.count -eq 1 -and $null -eq $r.data.grafted[0].role -and $null -eq $r.data.grafted[0].type) 'R2a legacy graft accepted with null role/type'
    $pl = $r.data.grafted[0].id
    $r = Invoke-GoalTreeLeaf @('-Command','next','-RunId','gate-f')
    $legacyNext = @($r.data.pending | Where-Object { $_.id -eq $pl })[0]
    Assert-True ($r.success -eq $true -and $null -ne $legacyNext -and $null -eq $legacyNext.role -and $null -eq $legacyNext.type) 'R2b next lists legacy node with null fields'
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-f','-NodeId',$pl,'-Worker','wl')
    $cf = Write-TempJson 'cb-r2.json' (New-Callback $pl)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-f','-Worker','wl','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and ((@($r.data.validation.notes) -join ' ') -notmatch 'probe_')) 'R2c legacy report accepted without probe notes'
    $ledgerLines = @([System.IO.File]::ReadAllLines((Join-Path $Work ".rdd/goal-trees/gate-f/state/ledger.jsonl")) | Where-Object { $_.Trim() -ne '' })
    $lastEntry = ($ledgerLines[-1] | ConvertFrom-Json)
    Assert-True ($null -eq $lastEntry.role) 'R2d legacy ledger entry role is null'
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-f','-NodeId',$pl)
    Assert-True ($r.success -eq $true) 'R2e legacy settle unaffected'

    # ===== Scenario G (rca-212114 replay, REQ-1.2): cb-n5 equivalent fill lands on disk, settle enforce passes =====
    # worker declares t01/t02/t03 (trace, 10-min cells over the domain) and reports with
    # objectized evidence whose tmax sits at the NOMINAL cell end (cb-n5.json shape)
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-g','-Goal','g','-RefRoots','.','-DomainJsonFile',$DomainFile,'-GateMode','enforce')
    Assert-True ($r.success -eq $true) 'G0 start gate-g (enforce)'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-g')
    $gcells = @(
        @{ id='t01'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='trace' }
        @{ id='t02'; interval=@('2021-03-04 14:40:00','2021-03-04 14:50:00'); modality='trace' }
        @{ id='t03'; interval=@('2021-03-04 14:50:00','2021-03-04 15:00:00'); modality='trace' }
    )
    $tf = Write-TempJson 'g1.json' @(@{ title='trace sweep'; task='trace sweep body'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$gcells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-g','-Parent','n1','-TasksFile',$tf)
    $gn = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-g','-NodeId',$gn,'-Worker','wg1')
    $extras = @{ findings = @(
        @{ entity='dockerA2'; interval=@('2021-03-04 14:35:00','2021-03-04 14:36:00'); evidence=@('sweep-out.csv'); note='first crossing' }
        @{ entity='MG02'; interval=@('2021-03-04 14:44:00','2021-03-04 14:45:00'); evidence=@('sweep-out.csv'); note='burst' }
    ); manifest = @{ filled = @{
        t01 = @{ status='found'; evidence=@(@{ ref='sweep-out.csv'; tmin='2021-03-04 14:30:00'; tmax='2021-03-04 14:40:00' }); note='per-minute stats' }
        t02 = @{ status='found'; evidence=@(@{ ref='sweep-out.csv'; tmin='2021-03-04 14:40:00'; tmax='2021-03-04 14:50:00' }); note='per-minute stats' }
        t03 = @{ status='clean'; evidence=@(@{ ref='sweep-out.csv'; tmin='2021-03-04 14:50:00'; tmax='2021-03-04 15:00:00' }) }
    } } }
    $cf = Write-TempJson 'cb-g1.json' (New-Callback $gn $extras 'sweep-out.csv')
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-g','-Worker','wg1','-CallbackFile',$cf)
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and ((@($r.data.validation.notes) -join ' ') -notmatch 'r8_evidence_rejected')) 'G1 cb-n5 equivalent fill accepted without R8 rejects'
    $sidecar = Get-Content (Join-Path $Work ".rdd/goal-trees/gate-g/state/manifests/$gn.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($sidecar.filled.t01.status -eq 'found' -and $sidecar.filled.t02.status -eq 'found' -and $sidecar.filled.t03.status -eq 'clean') 'G2 fill persisted: sidecar filled carries t01/t02/t03 terminal states'
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-g','-NodeId',$gn)
    Assert-True ($r.success -eq $true -and $null -eq $r.data.r1_warning) 'G3 settle enforce passes after full terminal fill'

    # ===== Scenario H (REQ-1.3): declared-but-unfilled sweep blocks conclude even when another sweep covers the domain =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-h','-Goal','g','-RefRoots','.','-DomainJsonFile',$DomainFile,'-GateMode','enforce')
    Assert-True ($r.success -eq $true) 'H0 start gate-h (enforce)'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-h')
    $acells = @(
        @{ id='a01'; interval=@('2021-03-04 14:30:00','2021-03-04 14:50:00'); modality='metric' }
        @{ id='a02'; interval=@('2021-03-04 14:50:00','2021-03-04 15:00:00'); modality='metric' }
    )
    $bcells = @(
        @{ id='b01'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='trace' }
        @{ id='b02'; interval=@('2021-03-04 14:40:00','2021-03-04 15:00:00'); modality='trace' }
    )
    $tf = Write-TempJson 'h1.json' @(
        @{ title='A metric sweep'; task='a'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=1200}; cells=$acells } }
        @{ title='B trace sweep';  task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600};  cells=$bcells } }
    )
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-h','-Parent','n1','-TasksFile',$tf)
    $hnA = $r.data.grafted[0].id; $hnB = $r.data.grafted[1].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-h','-NodeId',$hnA,'-Worker','whA')
    $extras = @{ manifest = @{ filled = @{
        a01 = @{ status='clean'; evidence=@(New-CleanEvidence 'notes.md' '2021-03-04 14:30:00' '2021-03-04 15:00:00') }
        a02 = @{ status='clean'; evidence=@(New-CleanEvidence 'notes.md' '2021-03-04 14:30:00' '2021-03-04 15:00:00') }
    } } }
    $cf = Write-TempJson 'cb-hA.json' (New-Callback $hnA $extras)
    $null = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-h','-Worker','whA','-CallbackFile',$cf)
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-h','-NodeId',$hnA)
    Assert-True ($r.success -eq $true) 'H1 sweep A fills the whole domain and settles'
    # sweep B stays declared-but-unfilled (pending, never reported) — the rca-212114 escape must close
    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-h','-Outcome','achieved','-Summary','s','-AnchorNodeId',$hnA)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'CONCLUDE_COVERAGE_GAPS' -and $r.error.message -match 'trace' -and $r.error.message -match "$hnB\.b01" -and $r.error.message -match 'declared-but-unfilled') 'H2 conclude achieved blocked: unfilled B cells listed with interval+modality'
    $r = Invoke-GoalTree @('-Command','status','-RunId','gate-h')
    Assert-True ($r.success -eq $true -and @($r.data.coverage.unfilled).Count -eq 2) 'H3 status exposes declared-but-unfilled cells'
    $r = Invoke-GoalTree @('-Command','resume','-RunId','gate-h')
    Assert-True ($r.success -eq $true -and @($r.data.coverage.unfilled).Count -eq 2) 'H4 resume exposes declared-but-unfilled cells'
    # prune is the documented way out (R1 error text): obligation discharged, achieved passes
    $null = Invoke-GoalTree @('-Command','prune','-RunId','gate-h','-NodeId',$hnB,'-Reason','trace modality abandoned')
    $r = Invoke-GoalTree @('-Command','conclude','-RunId','gate-h','-Outcome','achieved','-Summary','s','-AnchorNodeId',$hnA)
    Assert-True ($r.success -eq $true -and $r.data.outcome -eq 'achieved') 'H5 prune discharges the unfilled declaration (achieved passes)'

    # ===== Scenario I (REQ-1.4): report-link callbacks — blank bare-ref evidence bounces with a reason note =====
    $r = Invoke-GoalTree @('-Command','start','-RunId','gate-i','-Goal','g','-RefRoots','.','-DomainJsonFile',$DomainFile,'-GateMode','enforce')
    Assert-True ($r.success -eq $true) 'I0 start gate-i (enforce)'
    $null = Invoke-GoalTree @('-Command','round-start','-RunId','gate-i')
    $icells = @(@{ id='i1'; interval=@('2021-03-04 14:30:00','2021-03-04 14:40:00'); modality='metric' })
    $tf = Write-TempJson 'i1.json' @(@{ title='blank-ev sweep'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$icells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-i','-Parent','n1','-TasksFile',$tf)
    $in1 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-i','-NodeId',$in1,'-Worker','wi1')
    $extras = @{ findings = @(
        @{ entity='CPU-0'; interval=@('2021-03-04 14:35:00','2021-03-04 14:36:00'); evidence=@('notes.md'); note='burst' }
    ); manifest = @{ filled = @{
        i1 = @{ status='found'; evidence=@(''); note='blank ref' }
    } } }
    $cf = Write-TempJson 'cb-i1.json' (New-Callback $in1 $extras)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-i','-Worker','wi1','-CallbackFile',$cf)
    $en = (@($r.data.validation.notes) -join ' ')
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and $en -match "r8_evidence_rejected: cell 'i1'" -and $en -match 'bare-ref evidence is empty/blank') 'I1 blank bare-ref evidence: cell back to pending + reason note (never silently accepted)'
    $sidecar = Get-Content (Join-Path $Work ".rdd/goal-trees/gate-i/state/manifests/$in1.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($null -eq $sidecar.filled.i1) 'I1b sidecar filled stays empty for the rejected cell'
    $r = Invoke-GoalTree @('-Command','settle','-RunId','gate-i','-NodeId',$in1)
    Assert-True ($r.success -eq $false -and $r.error.code -eq 'SETTLE_MANIFEST_INCOMPLETE') 'I1c settle enforce blocked after blank-evidence bounce'
    # missing extras entirely -> manifest_missing note (trilogy with T7b/G1)
    $tf = Write-TempJson 'i2.json' @(@{ title='no-extras sweep'; task='b'; type='sweep'; manifest=@{ granularity=@{time_bucket_s=600}; cells=$icells } })
    $r = Invoke-GoalTree @('-Command','graft','-RunId','gate-i','-Parent','n1','-TasksFile',$tf)
    $in2 = $r.data.grafted[0].id
    $null = Invoke-GoalTreeLeaf @('-Command','claim','-RunId','gate-i','-NodeId',$in2,'-Worker','wi2')
    $cf = Write-TempJson 'cb-i2.json' (New-Callback $in2)
    $r = Invoke-GoalTreeLeaf @('-Command','report','-RunId','gate-i','-Worker','wi2','-CallbackFile',$cf)
    $en = (@($r.data.validation.notes) -join ' ')
    Assert-True ($r.success -eq $true -and $r.data.accepted -eq $true -and $en -match 'manifest_missing') 'I2 missing extras: accepted with manifest_missing note'
}
finally {
    Pop-Location
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("==== {0}/{1} passed ====" -f ($Results.Count - $failed.Count), $Results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

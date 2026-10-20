# stage-acceptance-s1 QA integration probe - [集成验收·S1] auditor-role
# Target: deliver-2026-10-02-auditor-independent-review node n6 (stage acceptance S1)
# Slice coverage (plan S1 acceptance point):
#   TC-A10  start-role -Role AUDITOR three-backend -DryRun against a fixture
#           archive (identity loading: CLI /rdd-auditor prefill, dsh preset
#           rdd-auditor + pointer full text, Plus POST body)
#   TC-A11  trigger mechanization: >=2 non-deprecated sub-requirements ->
#           longTask signal (review mandatory path); deprecated excluded from
#           the count; single-task fast-track exemption
#   TC-A12  promulgate -ReviewFile consumption (reviewer "auditor"): merge +
#           reject exclusion (skipped_review), depends_on_override wholesale
#           replace, merge dep redirect, bridge.json review section, response
#           surface review echo, -NoPush isolation flag
#   TC-A13  node graph (excluded task builds no node; dep edges redirected) +
#           report/review.md human-readable mirror (all dispositions)
#   TC-A14  REVIEW_EXCLUDED_DEP hard fail (dep dangling on rejected task) with
#           zero residue + remediation path (override onto surviving task)
#   TC-A15  ReviewFile schema hard gates: pass-with-override rejected,
#           duplicate verdict rejected, unknown task rejected, RUN_EXISTS guard
#   TC-A16  -ReviewFile absent: no review section, no review.md, every task
#           builds a node, regex dep inference intact (legacy equivalence +
#           AUDITOR-undeployed degradation: flow not blocked)
# Runs the production interpreters (Windows PowerShell 5.1) against a
# throwaway git repo in TEMP. Exit code 0 = all green.
# ASCII-only literals; CJK tokens are built from code points (PS5.1-safe).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Engine root resolution (project-local branch)
$EngineDir = $null
$cur = $PSScriptRoot
while ($cur -and -not $EngineDir) {
    if (Test-Path (Join-Path $cur 'rdd-engine\scripts\start-role.ps1')) { $EngineDir = Join-Path $cur 'rdd-engine\scripts' }
    $parent = Split-Path -Parent $cur
    if ($parent -eq $cur) { break }
    $cur = $parent
}
if (-not $EngineDir) { $EngineDir = Join-Path $env:RDD_ENGINE_HOME 'scripts' }
if (-not (Test-Path (Join-Path $EngineDir 'start-role.ps1'))) { throw 'rdd-engine scripts not located' }
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'

# CJK tokens (code-point built; keep the probe file itself ASCII-only)
function ZH { param([int[]]$cp) -join ($cp | ForEach-Object { [char]$_ }) }
$ZhDepField = ZH @(0x4F9D, 0x8D56, 0x5173, 0x7CFB)                 # dep-relation field label
$ZhDepWord  = ZH @(0x4F9D, 0x8D56)                                  # dep word
$ZhCritHead = ZH @(0x6574, 0x4F53, 0x9A8C, 0x6536, 0x5224, 0x636E)  # overall acceptance heading
$ZhColon    = [string][char]0xFF1A                                  # fullwidth colon
$ZhComma    = [string][char]0x3001                                  # ideographic comma
$ZhAuditor  = ZH @(0x5BA1, 0x67E5, 0x8005)                          # reviewer label
$ZhMergeTo  = ZH @(0x5408, 0x5E76, 0x81F3)                          # merge-into label
$ZhRejectW  = ZH @(0x9A73, 0x56DE)                                  # reject label
$ZhOverride = ZH @(0x4F9D, 0x8D56, 0x8986, 0x76D6)                  # dep-override label
$CriteriaAnchor = 'requirements/overview.md#' + $ZhCritHead

function Read-Utf8 { param([string]$p) [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p)) }
function Write-Utf8NoBom { param([string]$p, [string]$t)
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}

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
function Invoke-Bridge { param([string[]]$A)
    # bridge 默认形状翻转（promulgate legacy→wake）：本探针按旧链 chain-head 拓扑
    # 书写——promulgate 未显式带 -Shape 时机械补 legacy（显式 -Shape 优先，
    # 非 promulgate 命令零影响）。
    if ($A -contains 'promulgate' -and -not ($A -contains '-Shape')) { $A = @($A) + @('-Shape', 'legacy') }
    Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }

# start-role -DryRun under an explicit backend env (strip inherited DSH_WEB_URL /
# RDD_RUNTIME so backend selection is deterministic), cwd pinned to the drill repo.
function Run-RoleDryRun { param([string]$EnvSetup, [string]$ExtraArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $EnvSetup +
        ' ; & ''' + $StartPs1 + ''' -Role AUDITOR -DryRun ' + $ExtraArgs + ' ; exit $LASTEXITCODE"'
    $psi.WorkingDirectory = $script:Work
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['DSH_WEB_URL'] = $null
    $psi.EnvironmentVariables['RDD_RUNTIME'] = $null
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ stdout = $o; stderr = $e; exit = $p.ExitCode }
}

$Work = Join-Path $env:TEMP ('sa1-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # ---- fixture helpers -------------------------------------------------
    # $Specs: @( @{ t='<title>'; d='<dep spec after dep-colon, e.g. #1 or #3<c>#4>' } )
    function New-Fixture { param([string]$Name, $Specs, [bool]$WithCriteria)
        $archDir = Join-Path $script:Work (".rdd/changes/archive/$Name/requirements")
        New-Item -ItemType Directory -Path $archDir -Force | Out-Null
        $ov = "# $Name`n`nstage-acceptance drill fixture $Name.`n`n"
        if ($WithCriteria) {
            $ov += "## $script:ZhCritHead`n`n| # | scene | check | sub |`n|---|---|---|---|`n| 1 | end-to-end | demo | 1 |`n"
        }
        Write-Utf8NoBom (Join-Path $archDir 'overview.md') $ov
        $entries = @()
        $i = 1
        foreach ($s in $Specs) {
            $depLine = ''
            if ($s.d) { $depLine = "- **$script:ZhDepField**$script:ZhColon$($script:ZhDepWord)$($script:ZhColon)$($s.d)`n" }
            Write-Utf8NoBom (Join-Path $archDir "t$i.md") "# $Name req $i`n`n- drill requirement $i of $Name`n$depLine"
            $entries += ('{{"title":"{0}","requirement":"requirements/t{1}.md","currentOwners":["QA"],"designDocs":[]}}' -f $s.t, $i)
            $i++
        }
        $tf = Join-Path $script:Work "$Name-init.json"
        Write-Utf8NoBom $tf ('[' + ($entries -join ',') + ']')
        $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', "$Name-init.json")
        if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
        return ".rdd/changes/archive/$Name"
    }

    # Minimal staged PlanFile (batches = topological layers of $Deps inside a stage).
    function Write-DrillPlan { param([string]$Path, $Stages, $Deps)
        $stageObjs = @()
        foreach ($st in $Stages) {
            $pending = @($st.tasks | ForEach-Object { [int]$_ })
            $batches = @()
            while ($pending.Count -gt 0) {
                $batch = @($pending | Where-Object {
                    $t = [int]$_
                    @(@($Deps[$t]) | Where-Object { $pending -contains [int]$_ }).Count -eq 0
                })
                if ($batch.Count -eq 0) { throw "Write-DrillPlan: cyclic deps in stage $($st.id)" }
                $batches += , @($batch | Sort-Object)
                $pending = @($pending | Where-Object { $batch -notcontains [int]$_ })
            }
            $ap = @{ criteria_items = @('drill: review-gate consumption works'); slice = 'promulgate -ReviewFile drill' }
            $ap['criteria_ref'] = $script:CriteriaAnchor
            $stageObjs += , @{
                id = [string]$st.id; goal = "stage $($st.id) goal"; milestone = "stage $($st.id) milestone"
                task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
                batches = $batches; acceptance_point = $ap
            }
        }
        $plan = [ordered]@{ planned_at = '2026-10-06T00:00:00Z'; planner = 'qa-drill'; stages = $stageObjs; risks = @() }
        Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
        return $Path
    }

    # ReviewFile in the AUDITOR production shape (consumer reads
    # reviewed_at/reviewer/verdicts only; extra fields are audit metadata).
    function Write-DrillReviewFile { param([string]$Path, [string]$ArchiveName, [array]$Verdicts)
        $v = @()
        foreach ($x in $Verdicts) {
            $e = [ordered]@{ task_id = [int]$x.t; verdict = [string]$x.v; reason = [string]$x.r }
            if ($x.ContainsKey('o')) { $e['depends_on_override'] = @($x.o) }
            if ($x.ContainsKey('m')) { $e['merged_into_task_id'] = [int]$x.m }
            $v += $e
        }
        $obj = [ordered]@{
            reviewed_at = '2026-10-06T12:00:00+08:00'; reviewer = 'auditor'; archive = $ArchiveName
            trigger = 'longTask'
            deployment_check = @{ preset_id = 'rdd-auditor'; present = $true; note = 'preset registered' }
            verdicts = $v
            gaps_summary = @{ coverage_hole = 0; orphan_requirement = 0; dependency_mislabel = 1; merge_candidate = 1; untestable_acceptance = 1 }
            ledger_appended = $true; ledger_path = '.rdd/review-ledger.jsonl'
        }
        Write-Utf8NoBom $Path ($obj | ConvertTo-Json -Depth 8)
        return $Path
    }

    function Read-RunJson { param([string]$RunId, [string]$File)
        (Get-Content -LiteralPath (Join-Path $script:Work ".rdd/goal-trees/$RunId/$File") -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    function Assert-RunDirAbsent { param([string]$RunId, [string]$Name)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:Work ".rdd/goal-trees/$RunId"))) $Name "run dir residue found: $RunId"
    }
    function Get-DrillTask { param($PromulgateJson, [int]$TaskId)
        @(@($PromulgateJson.data.tasks) | Where-Object { [int]$_.task_id -eq $TaskId })[0]
    }

    # ---- fixture A: 7 tasks (5 pass-world + 1 rejected + 1 deprecated) ----
    $specA = @(
        @{ t = 'sa core feature';       d = '' },
        @{ t = 'sa report export';      d = '#1' },
        @{ t = 'sa editor perf side a'; d = '#1' },
        @{ t = 'sa editor perf side b'; d = '' },
        @{ t = 'sa archive sync';       d = '#3' + $ZhComma + '#4' },
        @{ t = 'sa legacy leftover';    d = '' },
        @{ t = 'sa stale task';         d = '' }
    )
    $archA = New-Fixture 'sa-fixture-a' $specA $true
    $null = Invoke-Flow @('-Command', 'deprecate', '-Archive', $archA, '-TaskId', '7')

    # ===== TC-A11: trigger mechanization (longTask signal, same criterion) =====
    $nA = Invoke-Flow @('-Command', 'next', '-Archive', $archA)
    $ltA = $nA.json.data.longTask
    if (-not $ltA) { $ltA = $nA.json.longTask }
    Assert-True ($ltA.triggered -eq $true) 'TC-A11.a' ('longTask not triggered (7 tasks, 1 deprecated): ' + $nA.raw)
    Assert-True ([int]$ltA.totalTaskCount -eq 6) 'TC-A11.b' ('deprecated task counted: total=' + $ltA.totalTaskCount)
    $archSingle = New-Fixture 'sa-fixture-single' @(@{ t = 'solo task'; d = '' }) $false
    $nS = Invoke-Flow @('-Command', 'next', '-Archive', $archSingle)
    $ltS = $nS.json.data.longTask
    if (-not $ltS) { $ltS = $nS.json.longTask }
    Assert-True ($ltS.triggered -eq $false) 'TC-A11.c' ('single-task fast-track exemption failed: ' + $nS.raw)

    # ===== TC-A10: start-role -Role AUDITOR three-backend dry-run =====
    $taskAbsA = Join-Path $Work '.rdd/changes/archive/sa-fixture-a/task.json'
    $cli = Run-RoleDryRun '$env:DSH_WEB_URL=$null;$env:RDD_RUNTIME=$null' ('-TaskJson ' + $taskAbsA)
    Assert-True ($cli.stdout.Contains('cli backend') -and $cli.stdout.Contains('/rdd-auditor')) 'TC-A10.a' ('CLI dry-run missing backend/prefill: ' + $cli.stdout)
    $dsh = Run-RoleDryRun '$env:DSH_WEB_URL=''http://127.0.0.1:9'';$env:RDD_RUNTIME=$null' ('-TaskJson ' + $taskAbsA)
    Assert-True ($dsh.stdout.Contains('dsh backend') -and $dsh.stdout.Contains('preset:') -and $dsh.stdout.Contains('rdd-auditor')) 'TC-A10.b' ('dsh dry-run missing backend/preset: ' + $dsh.stdout)
    Assert-True ($dsh.stdout.Contains('agentPreset=rdd-auditor') -and $dsh.stdout.Contains('sa-fixture-a')) 'TC-A10.c' ('dsh payload missing preset binding or fixture archive pointer: ' + $dsh.stdout)
    $plus = Run-RoleDryRun '$env:RDD_RUNTIME=''app'';$env:DSH_WEB_URL=$null' ('-TaskJson ' + $taskAbsA + ' -EmployeeId mock-employee')
    Assert-True ($plus.stdout.Contains('Plus POST') -and $plus.stdout.Contains('sa-fixture-a')) 'TC-A10.d' ('Plus dry-run missing POST body/pointer: ' + $plus.stdout)

    # ===== TC-A12: promulgate -ReviewFile consumption (fixture A) =====
    $rfA = Write-DrillReviewFile (Join-Path $Work 'sa-review-a.json') 'sa-fixture-a' @(
        @{ t = 1; v = 'pass';             r = 'independent; four dimensions clean' },
        @{ t = 2; v = 'tree_adjudicated'; r = 'dependency mislabel: no real dep on task 1'; o = @() },
        @{ t = 3; v = 'tree_adjudicated'; r = 'merge candidate: same change two sides as task 4'; m = 4 },
        @{ t = 4; v = 'pass';             r = 'absorber survives; clean' },
        @{ t = 5; v = 'pass';             r = 'deps auto-redirect through merge mapping' },
        @{ t = 6; v = 'reject_return';    r = 'untestable acceptance: no observable anchor' }
    )
    $pfA = Write-DrillPlan (Join-Path $Work 'sa-plan-a.json') @(
        @{ id = 'S1'; tasks = @(1, 2) }, @{ id = 'S2'; tasks = @(4, 5) }
    ) @{ 2 = @(); 5 = @(4) }
    $rA = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archA/task.json", '-PlanFile', $pfA, '-ReviewFile', $rfA, '-NoPush')
    Assert-True ($rA.json.success -eq $true) 'TC-A12.a' ('promulgate -ReviewFile failed: ' + $rA.raw)
    $skA = (@(@($rA.json.data.skipped_review) | ForEach-Object { [int]$_ }) | Sort-Object) -join ','
    Assert-True ($skA -eq '3,6') 'TC-A12.b' ('skipped_review expected 3,6 got: ' + $skA)
    Assert-True ($rA.json.data.review.reviewer -eq 'auditor' -and -not [string]::IsNullOrWhiteSpace([string]$rA.json.data.review.applied_at)) 'TC-A12.c' 'response review echo missing reviewer=auditor/applied_at'
    Assert-True (@($rA.json.data.review.verdicts).Count -eq 6) 'TC-A12.d' ('review echo verdicts count != 6')
    $t5A = Get-DrillTask $rA.json 5
    $t2A = Get-DrillTask $rA.json 2
    Assert-True (((@($t5A.dep_task_ids) | ForEach-Object { [int]$_ }) -join ',') -eq '4') 'TC-A12.e' ('task5 dep redirect 3->4 failed: ' + (@($t5A.dep_task_ids) -join ','))
    Assert-True (@($t2A.dep_task_ids).Count -eq 0) 'TC-A12.f' ('task2 override-clear failed: ' + (@($t2A.dep_task_ids) -join ','))
    $bA = Read-RunJson 'deliver-sa-fixture-a' 'bridge.json'
    $keysA = (@($bA.tasks.PSObject.Properties.Name) | Sort-Object) -join ','
    Assert-True ($keysA -eq '1,2,4,5') 'TC-A12.g' ('bridge.tasks keys expected 1,2,4,5 got: ' + $keysA)
    Assert-True ([bool]$bA.no_push) 'TC-A12.h' 'bridge.json no_push flag missing'
    Assert-True ($bA.review.reviewer -eq 'auditor' -and @($bA.review.verdicts).Count -eq 6 -and -not [string]::IsNullOrWhiteSpace([string]$bA.review.applied_at)) 'TC-A12.i' 'bridge.json review section missing/malformed'

    # ===== TC-A13: node graph + report/review.md human mirror =====
    $treeA = Read-RunJson 'deliver-sa-fixture-a' 'state/tree.json'
    $nodeOf = @{}
    foreach ($p in $bA.tasks.PSObject.Properties) { $nodeOf[[int]$p.Name] = [string]$p.Value.stages.QA }
    $nodesA = @($treeA.nodes)
    $orphanA = @($nodesA | Where-Object { ([string]$_.title).Contains('side a') -or ([string]$_.title).Contains('legacy leftover') })
    Assert-True ($orphanA.Count -eq 0) 'TC-A13.a' ('excluded tasks built nodes: ' + ($orphanA | ForEach-Object { $_.id }) -join ',')
    $n5node = @($nodesA | Where-Object { [string]$_.id -eq $nodeOf[5] })[0]
    $n2node = @($nodesA | Where-Object { [string]$_.id -eq $nodeOf[2] })[0]
    Assert-True (@($n5node.depends_on) -contains $nodeOf[4]) 'TC-A13.b' ('task5 node dep edge not redirected to absorber head: ' + (@($n5node.depends_on) -join ','))
    Assert-True (@($n2node.depends_on).Count -eq 0) 'TC-A13.c' ('task2 node should carry no dep edge after override-clear: ' + (@($n2node.depends_on) -join ','))
    $revA = Read-Utf8 (Join-Path $Work '.rdd/goal-trees/deliver-sa-fixture-a/report/review.md')
    Assert-True ($revA.Contains($ZhAuditor + ': auditor')) 'TC-A13.d' 'review.md missing reviewer auditor line'
    Assert-True ($revA.Contains($ZhMergeTo + ' #4') -and $revA.Contains($ZhOverride + ': []') -and $revA.Contains($ZhRejectW)) 'TC-A13.e' 'review.md missing merge/override/reject disposition rows'

    # ===== TC-A14: REVIEW_EXCLUDED_DEP hard fail + remediation =====
    $archB = New-Fixture 'sa-fixture-b' @(
        @{ t = 'sb alpha'; d = '' },
        @{ t = 'sb beta dep alpha'; d = '#1' },
        @{ t = 'sb gamma'; d = '' }
    ) $true
    $pfB = Write-DrillPlan (Join-Path $Work 'sa-plan-b.json') @(@{ id = 'S1'; tasks = @(1, 2, 3) }) @{ 2 = @(3) }
    $rfB1 = Write-DrillReviewFile (Join-Path $Work 'sa-review-b1.json') 'sa-fixture-b' @(
        @{ t = 1; v = 'reject_return'; r = 'untestable acceptance' },
        @{ t = 2; v = 'pass';          r = 'clean' }
    )
    $rB1 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archB/task.json", '-PlanFile', $pfB, '-ReviewFile', $rfB1, '-NoPush')
    Assert-True ($rB1.json.success -eq $false -and [string]$rB1.json.error.code -eq 'REVIEW_EXCLUDED_DEP') 'TC-A14.a' ('expected REVIEW_EXCLUDED_DEP: ' + $rB1.raw)
    Assert-True ($rB1.exit -eq 1) 'TC-A14.b' ('REVIEW_EXCLUDED_DEP exit code expected 1 got: ' + $rB1.exit)
    Assert-RunDirAbsent 'deliver-sa-fixture-b' 'TC-A14.c'
    $rfB2 = Write-DrillReviewFile (Join-Path $Work 'sa-review-b2.json') 'sa-fixture-b' @(
        @{ t = 1; v = 'reject_return';    r = 'untestable acceptance' },
        @{ t = 2; v = 'tree_adjudicated'; r = 're-anchor dep to surviving task 3'; o = @(3) },
        @{ t = 3; v = 'pass';             r = 'clean' }
    )
    $rB2 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archB/task.json", '-PlanFile', $pfB, '-ReviewFile', $rfB2, '-NoPush')
    Assert-True ($rB2.json.success -eq $true) 'TC-A14.d' ('remediated promulgate failed: ' + $rB2.raw)
    $t2B = Get-DrillTask $rB2.json 2
    Assert-True (((@($t2B.dep_task_ids) | ForEach-Object { [int]$_ }) -join ',') -eq '3') 'TC-A14.e' ('override onto surviving task failed: ' + (@($t2B.dep_task_ids) -join ','))
    Assert-True (((@(@($rB2.json.data.skipped_review) | ForEach-Object { [int]$_ })) -join ',') -eq '1') 'TC-A14.f' ('skipped_review expected 1')

    # ===== TC-A15: ReviewFile schema hard gates + RUN_EXISTS =====
    $archC = New-Fixture 'sa-fixture-c' @(@{ t = 'sc one'; d = '' }, @{ t = 'sc two'; d = '' }) $true
    $pfC = Write-DrillPlan (Join-Path $Work 'sa-plan-c.json') @(@{ id = 'S1'; tasks = @(1, 2) }) @{}
    $rfC1 = Write-DrillReviewFile (Join-Path $Work 'sa-review-c1.json') 'sa-fixture-c' @(
        @{ t = 1; v = 'pass'; r = 'clean'; o = @(2) }
    )
    $rC1 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archC/task.json", '-PlanFile', $pfC, '-ReviewFile', $rfC1, '-NoPush')
    Assert-True ($rC1.json.success -eq $false -and [string]$rC1.json.error.code -eq 'REVIEW_FILE_INVALID') 'TC-A15.a' ('pass-with-override not rejected: ' + $rC1.raw)
    Assert-RunDirAbsent 'deliver-sa-fixture-c' 'TC-A15.a.residue'
    $rfC2 = Write-DrillReviewFile (Join-Path $Work 'sa-review-c2.json') 'sa-fixture-c' @(
        @{ t = 1; v = 'pass'; r = 'clean' }, @{ t = 1; v = 'pass'; r = 'dup' }
    )
    $rC2 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archC/task.json", '-PlanFile', $pfC, '-ReviewFile', $rfC2, '-NoPush')
    Assert-True ($rC2.json.success -eq $false -and [string]$rC2.json.error.code -eq 'REVIEW_FILE_INVALID') 'TC-A15.b' ('duplicate verdict not rejected: ' + $rC2.raw)
    $rfC3 = Write-DrillReviewFile (Join-Path $Work 'sa-review-c3.json') 'sa-fixture-c' @(
        @{ t = 9; v = 'pass'; r = 'phantom task' }
    )
    $rC3 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archC/task.json", '-PlanFile', $pfC, '-ReviewFile', $rfC3, '-NoPush')
    Assert-True ($rC3.json.success -eq $false -and [string]$rC3.json.error.code -eq 'REVIEW_TASK_NOT_FOUND') 'TC-A15.c' ('unknown task verdict not rejected: ' + $rC3.raw)
    Assert-RunDirAbsent 'deliver-sa-fixture-c' 'TC-A15.c.residue'
    $rfC4 = Write-DrillReviewFile (Join-Path $Work 'sa-review-c4.json') 'sa-fixture-c' @(
        @{ t = 1; v = 'pass'; r = 'clean' }, @{ t = 2; v = 'pass'; r = 'clean' }
    )
    $rC4 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archC/task.json", '-PlanFile', $pfC, '-ReviewFile', $rfC4, '-NoPush')
    Assert-True ($rC4.json.success -eq $true) 'TC-A15.d' ('valid ReviewFile promulgate failed: ' + $rC4.raw)
    $rC5 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archC/task.json", '-PlanFile', $pfC, '-NoPush')
    Assert-True ($rC5.json.success -eq $false -and [string]$rC5.json.error.code -eq 'RUN_EXISTS') 'TC-A15.e' ('re-promulgate guard missing: ' + $rC5.raw)

    # ===== TC-A16: -ReviewFile absent = legacy behavior (undeployed degradation) =====
    $archD = New-Fixture 'sa-fixture-d' @(
        @{ t = 'sd one'; d = '' }, @{ t = 'sd two dep one'; d = '#1' }, @{ t = 'sd three'; d = '' }
    ) $true
    $pfD = Write-DrillPlan (Join-Path $Work 'sa-plan-d.json') @(@{ id = 'S1'; tasks = @(1, 2, 3) }) @{ 2 = @(1) }
    $rD = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$archD/task.json", '-PlanFile', $pfD, '-NoPush')
    Assert-True ($rD.json.success -eq $true) 'TC-A16.a' ('promulgate without ReviewFile blocked (degradation contract broken): ' + $rD.raw)
    $bD = Read-RunJson 'deliver-sa-fixture-d' 'bridge.json'
    Assert-True ($null -eq $bD.review) 'TC-A16.b' 'bridge.json carries a review section without -ReviewFile'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Work '.rdd/goal-trees/deliver-sa-fixture-d/report/review.md'))) 'TC-A16.c' 'report/review.md written without -ReviewFile'
    $keysD = (@($bD.tasks.PSObject.Properties.Name) | Sort-Object) -join ','
    Assert-True ($keysD -eq '1,2,3') 'TC-A16.d' ('every task should build (no review gate): ' + $keysD)
    $t2D = Get-DrillTask $rD.json 2
    Assert-True (((@($t2D.dep_task_ids) | ForEach-Object { [int]$_ }) -join ',') -eq '1') 'TC-A16.e' ('regex dep inference regressed without review gate: ' + (@($t2D.dep_task_ids) -join ','))
    Assert-True ($null -eq $rD.json.data.review -and @($rD.json.data.skipped_review).Count -eq 0) 'TC-A16.f' 'response surface carries review artifacts without -ReviewFile'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("== stage-acceptance-s1 Summary: PASS {0} / FAIL {1} ==" -f `
    (@($Results | Where-Object { $_.ok }).Count), `
    (@($Results | Where-Object { -not $_.ok }).Count))
if (@($Results | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
exit 0

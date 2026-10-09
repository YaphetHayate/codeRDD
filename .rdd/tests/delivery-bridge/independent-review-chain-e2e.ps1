# independent-review-chain-e2e.ps1 - integration/e2e chain probe (tree-level
# integration node) for
# deliver-2026-10-02-auditor-independent-review node n9.
#
# ONE lab run chains ALL delivered modules with real data flowing between them
# (not per-module sub-acceptances):
#   CH0 role deployment     : start-role -Role AUDITOR dsh-backend DryRun against
#                             the fixture archive (the reviewer can be dispatched)
#   CH1 layer-1 gate        : AUDITOR ReviewFile (review/requirement-review.json)
#                             -> promulgate -ReviewFile consumption: merge+override
#                             applied, excluded task builds no node, bridge review
#                             section + run report/review.md mirror, longTask trigger
#   CH2 layer-2 aggregation : both surviving CTO chains settle -> the aggregated
#                             design-review node auto-grafts (mid-state: planned +
#                             gate armed); AUDITOR
#                             claim context docs == layer-1 surviving set + maps
#   CH3 fail wave -> pass   : contract-valid fail file -> engine-derived FAIL ->
#                             redo wave (blocking into rebuilt CTO context) ->
#                             re-review -> pass with engine-derived basis -> DEV unlock
#   CH3.g gate              : DEV claim hard-rejected before pass, allowed after
#   CH4 layer-3 QA          : DEV+QA full chain -> task lifecycle completed ->
#                             run-level integration node grafts (final stage rides
#                             the acceptance chain, exactly the mechanism that
#                             dispatches this probe's own node)
#   CH5 chain artifacts     : three layers independently auditable; AUDITOR wrote
#                             ONLY review/ (requirements bytes unchanged); both
#                             layers account into the same review-ledger.jsonl
#
# Runs the production interpreter (Windows PowerShell 5.1) against a throwaway
# git repo under %TEMP%. ASCII-only source: CJK tokens are codepoint-built so
# the file is BOM-independent on PS5.1. Exit code 0 = all green.
# -EvidenceDir <dir> copies lab artifacts (run state, archive review products,
# ledger) into a persisted evidence folder before cleanup.

param([string]$EvidenceDir = '')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

# repo root = <repo>/.rdd/tests/delivery-bridge -> up three levels
$RepoRoot  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$EngineDir = Join-Path $RepoRoot 'rdd-engine\scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'
$Work      = Join-Path $env:TEMP ('chain-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# ---------- codepoint token builders (ASCII-only source discipline) ----------
function C { param([int[]]$Codes) (-join ($Codes | ForEach-Object { [char]$_ })) }
$TReviewPfx  = C @(0x8BBE,0x8BA1,0x5BA1,0x67E5,0x00B7)            # design-review node prefix + middle dot
function Review-Title { param([string]$StageId) ('[' + $TReviewPfx + $StageId + ']') }
$TIntegrate  = '[' + (C @(0x96C6,0x6210)) + '/' + (C @(0x8054,0x8C03)) + ']'   # run-level integration node title
$TAccHead    = C @(0x6574,0x4F53,0x9A8C,0x6536,0x5224,0x636E)    # overall acceptance criteria heading
$TDepField   = C @(0x4F9D,0x8D56,0x5173,0x7CFB)                  # dep-relation field label
$TDepWord    = C @(0x4F9D,0x8D56)                                 # dep word
$TReviewer   = C @(0x5BA1,0x67E5,0x8005)                          # reviewer label
$TMergeTo    = C @(0x5408,0x5E76,0x81F3)                          # merge-into label
$TOverride   = C @(0x4F9D,0x8D56,0x8986,0x76D6)                   # dep-override label
$TRejectW    = C @(0x9A73,0x56DE)                                 # reject label
$TMapHdr     = C @(0x53D8,0x66F4,0x5730,0x56FE)                   # change-map heading
$TAddOp      = C @(0x65B0,0x589E)
$TDelOp      = C @(0x5220,0x9664)
$Colon       = [string][char]0xFF1A                               # fullwidth colon
$CriteriaAnchor = 'requirements/overview.md#' + $TAccHead

# ---------- harness ----------
$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}
function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList
    # 期望的 stderr（负向用例的参数校验 / fail-loud 信封 / 控制台警告）在 EAP=Stop 下会
    # 变成 NativeCommandError 直接掀掉探针本身——合流捕获局部降 Continue，finally 还原。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & powershell @all 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE
    $json = $null
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    if ($null -eq $json) {
        $envLines = @($out -split "`r?`n" | Where-Object { $_ -match '^\s*\{\s*"success"' })
        for ($i = $envLines.Count - 1; $i -ge 0; $i--) { try { $json = ($envLines[$i] | ConvertFrom-Json); break } catch { } }
    }
    return @{ json = $json; exit = $code; raw = $out }
}
function Invoke-Bridge { param([string[]]$A) Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }
function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-RunJson { param([string]$RunId, [string]$File)
    $p = Join-Path $script:Work ('.rdd/goal-trees/' + $RunId + '/' + $File)
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Read-TreeNodes { param([string]$RunId) @(($(Read-RunJson $RunId 'state/tree.json')).nodes) }
function Count-Title { param([string]$RunId, [string]$Title)
    @((Read-TreeNodes $RunId) | Where-Object { [string]$_.title -eq $Title }).Count
}
function Read-Ledger {
    $p = Join-Path $script:Work '.rdd/review-ledger.jsonl'
    $out = @()
    if (Test-Path -LiteralPath $p) {
        foreach ($ln in @(Get-Content -LiteralPath $p -Encoding UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($ln)) { try { $out += ($ln | ConvertFrom-Json) } catch { } }
        }
    }
    return @($out)
}

# start-role DryRun with a deterministic backend env (dsh), cwd pinned to the lab repo.
function Run-RoleDryRun { param([string]$EnvSetup, [string]$ExtraArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $EnvSetup +
        ' ; & ''' + $StartPs1 + ''' -Role AUDITOR -DryRun ' + $ExtraArgs + ' ; exit $LASTEXITCODE"'
    $psi.WorkingDirectory = $script:Work
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['DSH_SESSION_ID'] = $null
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ stdout = $o; stderr = $e; exit = $p.ExitCode }
}

# ---------- fixture builders ----------
function New-ChainArchive { param([string]$Name)
    $archDir = Join-Path $script:Work (".rdd/changes/archive/$Name")
    $reqDir = Join-Path $archDir 'requirements'
    New-Item -ItemType Directory -Path $reqDir -Force | Out-Null
    $crit = "## $TAccHead`n`n| # | scene | check | sub |`n|---|---|---|---|`n" +
        "| 1 | requirement-set review loop | ReviewFile consumed via promulgate | 1 2 3 |`n" +
        "| 2 | design review gate | pass unlocks IMPL | 1 2 |`n" +
        "| 3 | three-layer chain | artifacts independently auditable | 1 2 |`n"
    Write-Utf8NoBom (Join-Path $reqDir 'overview.md') ("# $Name`n`nchain e2e fixture.`n`n" + $crit)
    # t1 clean; t2 declares a phony dep on #1 (mislabel -> override cleared);
    # t3 same change surface as #2 (merge candidate -> merged into 2)
    $dep2 = "- **$TDepField**$Colon$TDepWord$Colon#1`n"
    $dep3 = "- **$TDepField**$Colon$TDepWord$Colon#2`n"
    Write-Utf8NoBom (Join-Path $reqDir 't1.md') "# $Name req 1`n`n- chain core capability`n- acceptance: core command exits 0`n"
    Write-Utf8NoBom (Join-Path $reqDir 't2.md') "# $Name req 2`n`n- chain report export`n$dep2- acceptance: export writes file`n"
    Write-Utf8NoBom (Join-Path $reqDir 't3.md') "# $Name req 3`n`n- chain export format merge`n$dep3- acceptance: format merged`n"
    # design docs for the two surviving tasks (change-map contract shape)
    $doc = "# design doc`n`n## $TMapHdr`n`n- ``src/mod-x.py``  [$TAddOp] module x`n`n[$TAddOp] 1 | [$TAddOp] 0 | [$TDelOp] 0`n"
    $d1 = Join-Path $archDir 'design/d1.md'; $d2 = Join-Path $archDir 'design/d2.md'
    New-Item -ItemType Directory -Path (Split-Path $d1 -Parent) -Force | Out-Null
    Write-Utf8NoBom $d1 $doc; Write-Utf8NoBom $d2 $doc
    # impl files cited by DEV/QA callbacks (repo-root relative)
    $src = Join-Path $script:Work 'assets/src'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    Write-Utf8NoBom (Join-Path $src 'core.ts') "export const core = 1`n"
    Write-Utf8NoBom (Join-Path $src 'export.ts') "export const exp = 2`n"
    $tasks = '[{"title":"chain core capability","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]},' +
        '{"title":"chain report export","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]},' +
        '{"title":"chain export format merge","requirement":"requirements/t3.md","currentOwners":["CTO"],"designDocs":[]}]'
    $tf = Join-Path $script:Work "$Name-init.json"
    Write-Utf8NoBom $tf $tasks
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', "$Name-init.json")
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

function Write-ChainPlan { param([string]$Path, [string]$StageId, [int[]]$TaskIds)
    $ap = @{ criteria_items = @('chain: three-layer review chain works end to end'); slice = 'one lab run through all layers'; criteria_ref = $CriteriaAnchor }
    $plan = [ordered]@{
        planned_at = '2026-10-06T00:00:00Z'; planner = 'chain-e2e'
        stages = @(@{ id = $StageId; goal = "stage $StageId goal"; milestone = "stage $StageId milestone"
            task_ids = @($TaskIds | Sort-Object); batches = @( ,@($TaskIds | Sort-Object) ); acceptance_point = $ap })
        risks = @()
    }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

# AUDITOR layer-1 artifacts: ReviewFile + human mirror + ledger gap lines
# (whitelist: only review/ + the global ledger; requirements untouched).
function Write-RequirementReview { param([string]$ArchiveRel, [string]$ArchiveName)
    $obj = [ordered]@{
        reviewed_at = '2026-10-06T13:00:00+08:00'; reviewer = 'auditor'; archive = $ArchiveName
        trigger = 'longTask'
        deployment_check = @{ preset_id = 'rdd-auditor'; present = $true; note = 'preset registered' }
        verdicts = @(
            @{ task_id = 1; verdict = 'pass'; reason = 'independent; four dimensions clean' }
            @{ task_id = 2; verdict = 'tree_adjudicated'; reason = 'dependency mislabel: no real coupling on task 1'; depends_on_override = @() }
            @{ task_id = 3; verdict = 'tree_adjudicated'; reason = 'merge candidate: same change surface as task 2'; merged_into_task_id = 2 }
        )
        gaps_summary = @{ coverage_hole = 0; orphan_requirement = 0; dependency_mislabel = 1; merge_candidate = 1; untestable_acceptance = 0 }
        ledger_appended = $true; ledger_path = '.rdd/review-ledger.jsonl'
    }
    $dir = Join-Path $script:Work (($ArchiveRel + '/review') -replace '/', '\')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Utf8NoBom (Join-Path $dir 'requirement-review.json') ($obj | ConvertTo-Json -Depth 8)
    Write-Utf8NoBom (Join-Path $dir 'requirement-review.md') "# requirement review mirror`n`n${TReviewer}: auditor`n`n- #2 ${TOverride}: []`n- #3 ${TMergeTo}: #2`n"
    $ledger = Join-Path $script:Work '.rdd/review-ledger.jsonl'
    $gap1 = @{ at = '2026-10-06T13:00:00+08:00'; archive = $ArchiveName; reviewer = 'auditor'; kind = 'gap'; task_id = 2; gap_type = 'dependency_mislabel'; detail = 'declared dep on #1 has no real coupling; override cleared' }
    $gap2 = @{ at = '2026-10-06T13:00:00+08:00'; archive = $ArchiveName; reviewer = 'auditor'; kind = 'gap'; task_id = 3; gap_type = 'merge_candidate'; detail = 'same change surface as #2; merged into 2' }
    Add-Content -LiteralPath $ledger -Value (($gap1 | ConvertTo-Json -Compress), ($gap2 | ConvertTo-Json -Compress)) -Encoding UTF8
    return ($ArchiveRel + '/review/requirement-review.json')
}

function New-Cb { param([string]$NodeId, [string[]]$Refs, [string]$Verification = 'chain e2e delivery')
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'chain e2e delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = $Verification; quality_scan = @{ skip = $true; reason = 'lab fixture: cited change set carries no PowerShell files' } }
    }
    $cbFile = Join-Path $env:TEMP ("chain-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}
function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs, [string]$Verification = 'chain e2e delivery')
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    return (Do-ReportSettle $RunId $NodeId $Role $Refs $Verification)
}
function Do-ReportSettle { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs, [string]$Verification = 'chain e2e delivery')
    $cb = New-Cb $NodeId $Refs $Verification
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return $r
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

# DesignReviewFile writer (archive review/, per role-card whitelist).
function Write-Rv { param([string]$ArchiveRel, [string]$StageId, $Docs, $Cross)
    $file = [ordered]@{
        reviewed_at = '2026-10-06T14:00:00Z'; reviewer = 'auditor'; stage = $StageId
        docs = @($Docs); summary = @{ cross_design = @($Cross) }
    }
    $rel = "review/design-review-$StageId"
    $abs = Join-Path $script:Work (($ArchiveRel + '/' + $rel + '.json') -replace '/', '\')
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# design review mirror`n"
    return ($rel + '.json')
}
function New-F { param([string]$Sev, [string]$Dim, [string]$Item = 'finding item', [string]$Sug = 'finding suggestion')
    @{ severity = $Sev; dimension = $Dim; item = $Item; suggestion = $Sug }
}
function Hash-File { param([string]$Path)
    if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { '' }
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    $Name = 'chain-e2e'; $RunId = 'deliver-chain-e2e'
    $Arch = New-ChainArchive $Name
    $conv = Join-Path $Work 'chain-conventions.md'
    Write-Utf8NoBom $conv "# conventions (chain e2e)`n`n- layered architecture; naming follows existing style.`n"

    # ===== CH0: AUDITOR deployment (dsh backend DryRun against the fixture) =====
    $taskAbs = Join-Path (Join-Path $Work ($Arch -replace '/', '\')) 'task.json'
    $dsh = Run-RoleDryRun '$env:DSH_WEB_URL=''http://127.0.0.1:9'';$env:RDD_RUNTIME=$null' ('-TaskJson ' + $taskAbs)
    Assert-True ($dsh.stdout.Contains('dsh backend') -and $dsh.stdout.Contains('agentPreset=rdd-auditor') -and $dsh.stdout.Contains($Name)) 'CH0.a AUDITOR deployable (dsh DryRun: preset binding + archive pointer)' ($dsh.stdout)

    # ===== CH1: layer-1 requirement review loop =====
    $n0 = Invoke-Flow @('-Command', 'next', '-Archive', $Arch)
    $lt = $n0.json.data.longTask; if (-not $lt) { $lt = $n0.json.longTask }
    Assert-True ($lt.triggered -eq $true -and [int]$lt.totalTaskCount -eq 3) 'CH1.a longTask trigger (3 sub-requirements: review mandatory)' ($n0.raw)
    $reqSnapshot = @{}
    foreach ($f in @(Get-ChildItem (Join-Path $Work (($Arch + '/requirements') -replace '/', '\')) -Filter '*.md')) { $reqSnapshot[$f.Name] = Hash-File $f.FullName }
    $null = Write-RequirementReview $Arch $Name
    $pf = Write-ChainPlan (Join-Path $Work 'chain-plan.json') 'S1' @(1, 2)
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', "$Arch/task.json", '-PlanFile', $pf, '-ConventionsFile', $conv, '-ReviewFile', (($Arch + '/review/requirement-review.json') -replace '/', '\'), '-NoPush', '-NodeWidth', '8')
    Assert-True ($r.json.success -eq $true) 'CH1.b promulgate -ReviewFile consumed (planner zero semantic judgment)' ($r.raw)
    $sk = (@(@($r.json.data.skipped_review) | ForEach-Object { [int]$_ }) | Sort-Object) -join ','
    Assert-True ($sk -eq '3') 'CH1.c merged task excluded from build (skipped_review=[3])' ('got: ' + $sk)
    $b = Read-RunJson $RunId 'bridge.json'
    $keys = (@($b.tasks.PSObject.Properties.Name) | Sort-Object) -join ','
    Assert-True ($keys -eq '1,2') 'CH1.d tree maps only surviving tasks (keys=1,2)' ('got: ' + $keys)
    Assert-True ($b.review.reviewer -eq 'auditor' -and @($b.review.verdicts).Count -eq 3 -and -not [string]::IsNullOrWhiteSpace([string]$b.review.applied_at)) 'CH1.e bridge.json review section persisted' ('')
    $t2 = @($r.json.data.tasks | Where-Object { [int]$_.task_id -eq 2 })[0]
    Assert-True (@($t2.dep_task_ids).Count -eq 0) 'CH1.f depends_on_override wholesale-replaced (mislabel cleared)' ('')
    $revRaw = [System.IO.File]::ReadAllText((Join-Path $Work '.rdd/goal-trees/deliver-chain-e2e/report/review.md'), [System.Text.Encoding]::UTF8)
    Assert-True ($revRaw.Contains($TReviewer + ': auditor') -and $revRaw.Contains($TMergeTo + ' #2') -and $revRaw.Contains($TOverride + ': []')) 'CH1.g run report/review.md human mirror (merge/override dispositions)' ('')

    # ===== CH2: DESIGN aggregation graft + mid-state gate + claim context =====
    $b = Read-RunJson $RunId 'bridge.json'
    $dr = $b.plan.stages[0].design_review
    Assert-True ($null -ne $dr -and [string]$dr.status -eq 'planned') 'CH2.a design_review slot planned at promulgate' ('')
    $c1 = [string]$b.tasks.'1'.stages.CTO; $c2 = [string]$b.tasks.'2'.stages.CTO
    Do-Deliver $RunId $c1 'CTO' @(($Arch + '/design/d1.md')) | Out-Null
    $r = Do-Settle $RunId $c1
    Assert-True ($r.json.success -eq $true -and (Count-Title $RunId (Review-Title 'S1')) -eq 0) 'CH2.b graft waits for ALL stage tasks past DESIGN' ($r.raw)
    $dev1 = [string]((Read-RunJson $RunId 'bridge.json').tasks.'1'.stages.DEV)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $dev1, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'CH2.c gate armed mid-state (DEV claim hard-rejected)' ($r.raw)
    Do-Deliver $RunId $c2 'CTO' @(($Arch + '/design/d2.md')) | Out-Null
    $r = Do-Settle $RunId $c2
    $b = Read-RunJson $RunId 'bridge.json'
    $dr = $b.plan.stages[0].design_review
    $revNode = [string]$dr.node
    Assert-True ($r.json.success -eq $true -and [string]$dr.status -eq 'grafted' -and (Count-Title $RunId (Review-Title 'S1')) -eq 1) 'CH2.d aggregated design-review node auto-grafted after last DESIGN settle' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $revNode, '-Role', 'AUDITOR')
    $acc = $null; if ($r.json.success) { $acc = $r.json.data.acceptance }
    Assert-True ($r.json.success -eq $true -and [string]$acc.kind -eq 'design_review') 'CH2.e AUDITOR claim passes the gate it owns (kind=design_review)' ($r.raw)
    $docs = @($acc.docs) | ForEach-Object { [string]$_ }
    Assert-True (($docs -contains 'design/d1.md') -and ($docs -contains 'design/d2.md') -and ($docs.Count -eq 2)) 'CH2.f claim docs == layer-1 surviving set (merged task contributes no design doc)' (($docs -join ','))
    $maps = @($acc.design_maps)
    Assert-True ($maps.Count -ge 1 -and [string]$maps[0].doc -like 'design/d*' -and @($maps[0].files).Count -ge 1 -and [string]$acc.criteria_ref -eq $CriteriaAnchor -and -not [string]::IsNullOrWhiteSpace([string]$acc.conventions) -and [string]$acc.report -eq 'review/design-review-S1.json') 'CH2.g claim context: design_maps cache + conventions + criteria anchor + report path' ($r.raw)

    # ===== CH3: fail wave -> redo -> re-review -> pass -> unlock =====
    $cb = New-Cb $revNode @(($Arch + '/review/design-review-S1.json'), ($Arch + '/review/design-review-S1.md'))
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'CH3.a AUDITOR review report accepted' ($r.raw)
    Write-Rv $Arch 'S1' @(
        @{ doc = 'design/d1.md'; verdict = 'fail'; findings = @((New-F 'blocking' 'change_map' 'd1 change map misses shared module'), (New-F 'advisory' 'completeness')) }
        @{ doc = 'design/d2.md'; verdict = 'pass'; findings = @() }
    ) @() | Out-Null
    $r = Do-Settle $RunId $revNode
    Assert-True ($r.json.success -eq $true) 'CH3.b contract-valid fail file settles (gate passes, engine derives)' ($r.raw)
    $b = Read-RunJson $RunId 'bridge.json'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'planned') 'CH3.c engine-derived FAIL -> wave reset planned' ('')
    $r = Invoke-Flow @('-Command', 'show', '-Archive', $Arch)
    $t1s = @($r.json.data.tasks | Where-Object { [int]$_.id -eq 1 })[0]
    Assert-True (@($t1s.currentOwners) -contains 'CTO' -and [string]$t1s.phase -eq 'DESIGN') 'CH3.d affected task routed back CTO @ DESIGN (redo)' ($r.raw)
    $b = Read-RunJson $RunId 'bridge.json'
    $ctoRedo = [string]$b.tasks.'1'.stages.CTO
    $redoNode = @((Read-TreeNodes $RunId) | Where-Object { [string]$_.id -eq $ctoRedo })[0]
    Assert-True ($null -ne $redoNode -and ([string]$redoNode.task -match '\[change_map\] design/d1\.md')) 'CH3.e blocking list auto-enters redo context ([change_map] marker)' ('')
    $led = @(Read-Ledger)
    Assert-True (@($led | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.verdict -eq 'fail' }).Count -ge 1 -and @($led | Where-Object { [string]$_.kind -eq 'blocking' -and [string]$_.gap_type -eq 'change_map' }).Count -ge 1) 'CH3.f fail accounting: ledger fail summary + blocking gap_type=change_map' ('')
    Do-Deliver $RunId $ctoRedo 'CTO' @(($Arch + '/design/d1.md')) | Out-Null
    $r = Do-Settle $RunId $ctoRedo
    $b = Read-RunJson $RunId 'bridge.json'
    $revNode2 = [string]$b.plan.stages[0].design_review.node
    Assert-True ($r.json.success -eq $true -and [string]$b.plan.stages[0].design_review.status -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace($revNode2) -and $revNode2 -ne $revNode) 'CH3.g re-review grafted after redo convergence (fresh node)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $revNode2, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'CH3.h re-review claim ok' ($r.raw)
    Write-Rv $Arch 'S1' @(
        @{ doc = 'design/d1.md'; verdict = 'pass'; findings = @((New-F 'advisory' 'completeness')) }
        @{ doc = 'design/d2.md'; verdict = 'pass'; findings = @() }
    ) @() | Out-Null
    $cb2 = New-Cb $revNode2 @(($Arch + '/review/design-review-S1.json'), ($Arch + '/review/design-review-S1.md'))
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', 'AUDITOR', '-CallbackFile', $cb2)
    Assert-True ($r.json.success -eq $true) 'CH3.i re-review report ok' ($r.raw)
    $r = Do-Settle $RunId $revNode2
    $b = Read-RunJson $RunId 'bridge.json'
    $drp = $b.plan.stages[0].design_review
    Assert-True ($r.json.success -eq $true -and [string]$drp.status -eq 'passed' -and [string]$drp.verdict -eq 'pass' -and ([string]$drp.basis -match 'engine-derived')) 'CH3.j pass with engine-derived basis recorded' ($r.raw)
    $dev1b = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $dev1b, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'CH3.k DEV unblocked after pass (was rejected at CH2.c)' ($r.raw)

    # ===== CH4: layer-3 QA verification + acceptance link continues =====
    $b = Read-RunJson $RunId 'bridge.json'
    $dev2 = [string]$b.tasks.'2'.stages.DEV
    $null = Do-ReportSettle $RunId $dev1b 'DEV' @('assets/src/core.ts')
    $r = Do-Settle $RunId $dev1b
    Assert-True ($r.json.success -eq $true) 'CH4.a task1 DEV settle ok (claimed at CH3.k)' ($r.raw)
    Do-Deliver $RunId $dev2 'DEV' @('assets/src/export.ts') | Out-Null
    $r = Do-Settle $RunId $dev2
    Assert-True ($r.json.success -eq $true) 'CH4.b task2 DEV settle ok' ($r.raw)
    $b = Read-RunJson $RunId 'bridge.json'
    $qa1 = [string]$b.tasks.'1'.stages.QA; $qa2 = [string]$b.tasks.'2'.stages.QA
    Do-Deliver $RunId $qa1 'QA' @('assets/src/core.ts') 'layer-3 verify PASS 8/8 on task 1' | Out-Null
    $r = Do-Settle $RunId $qa1
    Assert-True ($r.json.success -eq $true) 'CH4.c task1 QA verify settle ok' ($r.raw)
    Do-Deliver $RunId $qa2 'QA' @('assets/src/export.ts') 'layer-3 verify PASS 9/9 on task 2' | Out-Null
    $r = Do-Settle $RunId $qa2
    Assert-True ($r.json.success -eq $true) 'CH4.d task2 QA verify settle ok' ($r.raw)
    $r = Invoke-Flow @('-Command', 'show', '-Archive', $Arch)
    $done = @($r.json.data.tasks | Where-Object { ($_.id -in @(1, 2)) -and [string]$_.lifecycle -eq 'completed' })
    Assert-True ($done.Count -eq 2) 'CH4.e both tasks lifecycle=completed (layer-3 conformance closed)' ($r.raw)
    $b = Read-RunJson $RunId 'bridge.json'
    Assert-True ((Count-Title $RunId $TIntegrate) -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$b.acceptance.integrate_node)) 'CH4.f run-level integration node auto-grafted (final stage rides the acceptance chain)' ('')

    # ===== CH5: three-layer artifacts + whitelist + shared ledger =====
    $revDir = Join-Path $Work (($Arch + '/review') -replace '/', '\')
    $revFiles = @(@(Get-ChildItem $revDir -File) | ForEach-Object { $_.Name } | Sort-Object) -join ','
    Assert-True ($revFiles -eq 'design-review-S1.json,design-review-S1.md,requirement-review.json,requirement-review.md') 'CH5.a AUDITOR products exactly the four whitelisted review/ files' ('got: ' + $revFiles)
    $clean = $true; foreach ($k in $reqSnapshot.Keys) { if ((Hash-File (Join-Path $Work (($Arch + '/requirements/' + $k) -replace '/', '\'))) -ne $reqSnapshot[$k]) { $clean = $false } }
    Assert-True ($clean -and -not (Test-Path (Join-Path $Work (($Arch + '/tests') -replace '/', '\')))) 'CH5.b whitelist non-intrusion: requirements bytes unchanged, no tests/ written' ('')
    $ledRaw = @(Read-Ledger)
    $qaEntries = @(); foreach ($ln in @(Get-Content -LiteralPath (Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/ledger.jsonl')) -Encoding UTF8)) { if (-not [string]::IsNullOrWhiteSpace($ln)) { try { $qaEntries += ($ln | ConvertFrom-Json) } catch { } } }
    Assert-True (@($qaEntries | Where-Object { [string]$_.role -eq 'qa' -and [string]$_.callback.extras.verification -like 'layer-3 verify PASS*' }).Count -eq 2) 'CH5.c layer-3 QA conclusions independently auditable (run ledger verification entries)' ('')
    Assert-True (@($ledRaw | Where-Object { [string]$_.kind -eq 'gap' -and [string]$_.gap_type -eq 'dependency_mislabel' }).Count -ge 1 -and @($ledRaw | Where-Object { [string]$_.kind -eq 'gap' -and [string]$_.gap_type -eq 'merge_candidate' }).Count -ge 1) 'CH5.d layer-1 gap accounting present (review-ledger.jsonl)' ('')
    Assert-True (@($ledRaw | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.verdict -eq 'pass' -and [int]$_.advisory_count -ge 1 }).Count -ge 1) 'CH5.e layer-2 pass accounting present (same ledger file, both layers queryable)' ('')
}
finally {
    Pop-Location
}

# ---------- optional evidence capture before cleanup ----------
if ($EvidenceDir -and @( $Results | Where-Object { -not $_.ok }).Count -eq 0) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $keep = @('.rdd/goal-trees/deliver-chain-e2e/bridge.json', '.rdd/goal-trees/deliver-chain-e2e/state/tree.json', '.rdd/goal-trees/deliver-chain-e2e/state/ledger.jsonl', '.rdd/goal-trees/deliver-chain-e2e/plan-log.jsonl', '.rdd/goal-trees/deliver-chain-e2e/report/review.md', '.rdd/review-ledger.jsonl')
    foreach ($rel in $keep) {
        $src = Join-Path $Work ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $EvidenceDir (($rel -replace '/', '_') -replace '^\.rdd_', '')
            New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    $archSrc = Join-Path $Work '.rdd\changes\archive\chain-e2e'
    if (Test-Path $archSrc) { Copy-Item -Recurse -LiteralPath $archSrc -Destination (Join-Path $EvidenceDir 'archive-chain-e2e') -Force }
}
if ($Work -and (Test-Path $Work)) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }

$fails = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("independent-review-chain e2e: {0} assertions, {1} failed" -f $Results.Count, $fails.Count)
foreach ($f in $fails) { Write-Output ("  FAIL {0}   {1}" -f $f.name, $f.detail) }
if ($fails.Count -gt 0) { exit 1 }
exit 0

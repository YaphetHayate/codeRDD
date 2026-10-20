# design-review-qa-verify.ps1 - QA independent black-box probe for
# auditor-design-stage-review (stage-boundary design review node + DesignReviewFile
# contract). Requirement source (QA reads requirements only, never design/):
# .rdd/changes/archive/2026-10-02-auditor-independent-review/requirements/
# auditor-design-stage-review.md
#
# Independent from the DEV suite (rdd-engine/tests/test-bridge-design-review.ps1
# DR1-DR7): cases below are designed from the 8 acceptance criteria and target
# gaps + independent reproduction:
#   QA1 (AC-1, TC-B139) graft waits for ALL stage tasks past DESIGN (mid-state
#       planned + no review node + gate already armed), then grafts on the last
#   QA2 (AC-1, TC-B140) gate error-code family + dispatch touchpoint + status
#       observability + AUDITOR pass-through claim
#   QA3 (AC-1/8, TC-B141) pass path: engine-derived pass (basis recorded, no
#       declared verdict field) + DEV unblocks + PASS-path ledger accounting
#   QA4 (AC-2, TC-B142) contract negative battery: 12 violation shapes each
#       -> SETTLE_EVIDENCE_REJECTED with a locatable design_review problem;
#       rejected settles never derive; valid file still settles after battery
#   QA5 (AC-2/6, TC-B143) cross_design blocking: contract-valid file (docs all
#       pass) -> engine derives FAIL -> wave (route back CTO@DESIGN + redo
#       context carries the cross_design blocker + ledger gap_type=cross_design)
#   QA6 (AC-8, TC-B144) same-dimension blocking x3 in one run -> reflux_
#       suggestion ledger line appears only at >=3 (re-review convergence loop)
#   QA7 (AC-5, TC-B145) multi-stage: budget +K with K=2 (exact numbers), one
#       aggregated review node per stage, stage isolation (S2 stays planned)
#   QA8 (AC-3/4/6, TC-B146) delivered contract docs consistency anchors
#       (five dimensions + three boundaries + error codes + gate codes)
#   QA9 (AC-3, TC-B147) AUDITOR claim context completeness: docs + design_maps
#       mechanical cache rows + conventions ref + criteria_ref + report path
#
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway
# git repo under %TEMP%. ASCII-only source: Chinese tokens are built from
# codepoints so the file is BOM-independent on PS5.1. Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

# repo root = <repo>/.rdd/tests/delivery-bridge -> up three levels
$RepoRoot  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$EngineDir = Join-Path $RepoRoot 'rdd-engine\scripts'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$Work      = Join-Path $env:TEMP ('design-review-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# ---------- codepoint token builders (ASCII-only source discipline) ----------
function C { param([int[]]$Codes) (-join ($Codes | ForEach-Object { [char]$_ })) }
$TReviewPfx = C @(0x8BBE,0x8BA1,0x5BA1,0x67E5,0x00B7)                 # design-review prefix + middle dot
function Review-Title { param([string]$StageId) ('[' + $TReviewPfx + $StageId + ']') }
$TVeto       = C @(0x8BBE,0x8BA1,0x5BA1,0x67E5,0x5426,0x51B3)        # design-review veto marker
$TAccHead    = C @(0x6574,0x4F53,0x9A8C,0x6536,0x5224,0x636E)        # overall acceptance criteria heading
$TAccNone    = C @(0x65E0,0x6574,0x4F53,0x5224,0x636E)               # declared-none prefix (exact parser contract: ^ + wu-zheng-ti-pan-ju)
$TDeclare    = C @(0x663E,0x5F0F,0x58F0,0x660E)                       # explicit declaration
$TMapHdr     = C @(0x53D8,0x66F4,0x5730,0x56FE)                            # change map heading (## prefix per parser contract heading regex)
$TAddOp      = C @(0x65B0,0x589E)
$TModOp      = C @(0x4FEE,0x6539)
$TDelOp      = C @(0x5220,0x9664)
$TBound1     = C @(0x4E0D,0x8BC4,0x6280,0x672F,0x9009,0x578B)        # boundary: no tech-choice judging
$TBound2     = C @(0x4E0D,0x4FEE,0x6539,0x8BBE,0x8BA1)               # boundary: no design edits
$TBound3     = C @(0x4E0D,0x5199,0x6D4B,0x8BD5)                      # boundary: no test writing

$Script:DeclaredBlock = "## $TAccHead`n`n$TAccNone (QA probe fixture, $TDeclare)`n"
$Script:DocTemplate   = "# design doc`n`n## $TMapHdr`n`n- ``src/mod-a.py``  [$TAddOp] module A`n`n[$TAddOp] 1 | [$TModOp] 0 | [$TDelOp] 0`n"

# ---------- harness ----------
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
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).nodes)
}
function Find-TreeNode { param([string]$RunId, [string]$Id)
    foreach ($n in (Read-TreeNodes $RunId)) { if ([string]$n.id -eq $Id) { return $n } }
    return $null
}
function Count-ReviewTitleNodes { param([string]$RunId, [string]$StageId)
    $t = Review-Title $StageId
    @((Read-TreeNodes $RunId) | Where-Object { [string]$_.title -eq $t }).Count
}
function Read-Ledger {
    $p = Join-Path $Work '.rdd/review-ledger.jsonl'
    $out = @()
    if (Test-Path -LiteralPath $p) {
        foreach ($ln in @(Get-Content -LiteralPath $p -Encoding UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($ln)) { try { $out += ($ln | ConvertFrom-Json) } catch { } }
        }
    }
    return @($out)
}

function New-Archive { param([string]$Name, [string]$TasksJson, [string]$CriteriaBody = '')
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    $accBlock = $Script:DeclaredBlock
    if ($CriteriaBody) { $accBlock = "## $TAccHead`n`n$CriteriaBody`n" }
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') ("# $Name`n`nQA probe archive $Name.`n`n" + $accBlock)
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir ("requirements/t$i.md")) "# $Name requirement $i`n`n- QA probe requirement $i`n"
        foreach ($d in @($line.designDocs)) {
            if ($d -and $d.path) {
                $dAbs = Join-Path $archDir ([string]$d.path)
                $dDir = Split-Path $dAbs -Parent
                if (-not (Test-Path $dDir)) { New-Item -ItemType Directory -Path $dDir -Force | Out-Null }
                Write-Utf8NoBom $dAbs $Script:DocTemplate
            }
        }
        $i++
    }
    $tf = Join-Path $Work "$Name-init.json"
    Write-Utf8NoBom $tf $TasksJson
    $r = Invoke-Flow @('-Command', 'init', '-Archive', ".rdd/changes/archive/$Name", '-TasksFile', "$Name-init.json")
    if ($r.json.success -ne $true) { throw "init failed for $Name : $($r.raw)" }
    return ".rdd/changes/archive/$Name"
}

function Write-TestPlan { param([string]$Path, $Stages, [string]$CriteriaRef = '')
    $stageObjs = @()
    foreach ($st in $Stages) {
        $ap = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' }
        if ($CriteriaRef) { $ap['criteria_ref'] = $CriteriaRef }
        $stageObjs += ,@{
            id = [string]$st.id
            goal = "stage $($st.id) goal"
            milestone = "stage $($st.id) milestone"
            task_ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
            batches = @(@($st.tasks | ForEach-Object { [int]$_ } | Sort-Object))
            acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-06T00:00:00Z'; planner = 'qa'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'design-review QA probe delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'smoke ok'; quality_scan = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } }
    }
    $cbFile = Join-Path $env:TEMP ("drqa-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
    Write-Utf8NoBom $cbFile ($cb | ConvertTo-Json -Depth 5)
    return $cbFile
}

function Do-Deliver { param([string]$RunId, [string]$NodeId, [string]$Role, [string[]]$Refs)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $RunId, '-NodeId', $NodeId, '-Role', $Role)
    if ($r.json.success -ne $true) { throw "claim failed ($NodeId/$Role): $($r.raw)" }
    $cb = New-Cb $NodeId $Refs
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $RunId, '-Worker', $Role, '-CallbackFile', $cb)
    if ($r.json.success -ne $true) { throw "report failed ($NodeId/$Role): $($r.raw)" }
    return $r
}
function Do-Settle { param([string]$RunId, [string]$NodeId)
    Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

# DesignReviewFile writer (archive-relative). $Docs = @(@{ doc; verdict; findings }),
# $Cross = @(@{ severity; item; suggestion; involved_docs }).
function Write-Rv { param([string]$ArchiveRel, [string]$StageId, $Docs, $Cross,
    [string]$Reviewer = 'auditor', [string]$StageField = '', [string]$ReviewedAt = '2026-10-06T09:00:00Z')
    $file = [ordered]@{
        reviewed_at = $ReviewedAt; reviewer = $Reviewer
        stage = $(if ($StageField) { $StageField } else { $StageId })
        docs = @($Docs); summary = @{ cross_design = @($Cross) }
    }
    $rel = "review/design-review-$StageId"
    $abs = Join-Path $Work (($ArchiveRel + '/' + $rel + '.json') -replace '/', '\')
    $dir = Split-Path $abs -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# design review mirror`n"
    return ($rel + '.json')
}
function New-F { param([string]$Sev, [string]$Dim, [string]$Item = 'finding item', [string]$Sug = 'finding suggestion')
    @{ severity = $Sev; dimension = $Dim; item = $Item; suggestion = $Sug }
}

# fixture bootstrap: promulgate + CTO delivery settle -> review grafted. Returns run data.
# NodeWidth > 0 is passed through to promulgate (multiple fail-wave redo cycles need a
# wider goal-root fan-out than the auto floor; documented budget semantics).
function New-GraftedRun { param([string]$Name, [string]$TasksJson, [string[]]$DocRels, [hashtable]$PlanStages, [string]$ConventionsFile = '', [int]$NodeWidth = 0, [string]$CriteriaBody = '', [string]$CriteriaRef = '')
    $arch = New-Archive $Name $TasksJson $CriteriaBody
    $pf = Write-TestPlan (Join-Path $Work "$Name-plan.json") @($PlanStages.stages) $CriteriaRef
    $args = @('-Command', 'promulgate', '-TaskJson', ($arch + '/task.json'), '-PlanFile', $pf, '-NoPush')
    if ($ConventionsFile) { $args += @('-ConventionsFile', $ConventionsFile) }
    if ($NodeWidth -gt 0) { $args += @('-NodeWidth', "$NodeWidth") }
    $r = Invoke-Bridge $args
    if ($r.json.success -ne $true) { throw "promulgate failed for $Name : $($r.raw)" }
    $runId = 'deliver-' + $Name
    $b = Read-BridgeJson $runId
    $ctoNode = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver $runId $ctoNode 'CTO' @(($arch + '/' + $DocRels[0])) | Out-Null
    $r = Do-Settle $runId $ctoNode
    if ($r.json.success -ne $true) { throw "CTO settle failed for $Name : $($r.raw)" }
    return @{ run = $runId; arch = $arch; docs = $DocRels }
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
try {
    # ================= QA1 (AC-1): graft waits for ALL stage tasks past DESIGN =================
    $convShared = Join-Path $Work 'qa-conventions.md'
    Write-Utf8NoBom $convShared "# conventions (test)`n`n- layered architecture; naming follows existing style.`n"
    $arch1 = New-Archive 'qa-dr1' '[{"title":"QA1a","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]},{"title":"QA1b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]}]'
    $pf1 = Write-TestPlan (Join-Path $Work 'qa-dr1-plan.json') @(@{ id = 'S1'; tasks = @(1, 2) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $pf1, '-ConventionsFile', $convShared, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 5 -and [int]$r.json.data.budget.max_nodes -eq 17) 'QA1 budget +K (K=1): width 5 / nodes 17' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-dr1'
    Assert-True ($null -ne $b.plan.stages[0].design_review -and [string]$b.plan.stages[0].design_review.status -eq 'planned') 'QA1 slot lands planned at promulgate' ($b | ConvertTo-Json -Depth 6)
    $c1 = [string]$b.tasks.'1'.stages.CTO; $c2 = [string]$b.tasks.'2'.stages.CTO
    Do-Deliver 'deliver-qa-dr1' $c1 'CTO' @('.rdd/changes/archive/qa-dr1/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-qa-dr1' $c1
    Assert-True ($r.json.success -eq $true) 'QA1 first CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-dr1'
    $dr1 = $b.plan.stages[0].design_review
    Assert-True ([string]$dr1.status -eq 'planned' -and $null -eq $dr1.node) 'QA1 after FIRST settle design_review still planned (graft waits for all stage tasks)' ($b | ConvertTo-Json -Depth 6)
    Assert-True ((Count-ReviewTitleNodes 'deliver-qa-dr1' 'S1') -eq 0) 'QA1 no review node in tree mid-stage' ('')
    $dev1 = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-dr1', '-NodeId', $dev1, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'QA1 gate armed already in planned state (review not settled)' ($r.raw)
    Do-Deliver 'deliver-qa-dr1' $c2 'CTO' @('.rdd/changes/archive/qa-dr1/design/d2.md') | Out-Null
    $r = Do-Settle 'deliver-qa-dr1' $c2
    Assert-True ($r.json.success -eq $true) 'QA1 second CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-dr1'
    $dr1 = $b.plan.stages[0].design_review
    $revNode1 = [string]$dr1.node
    Assert-True ([string]$dr1.status -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace($revNode1)) 'QA1 grafted after LAST task passes DESIGN' ($b | ConvertTo-Json -Depth 6)
    $revT = Find-TreeNode 'deliver-qa-dr1' $revNode1
    Assert-True ($null -ne $revT -and [string]$revT.title -eq (Review-Title 'S1') -and [string]$revT.role -eq 'auditor') 'QA1 review node tree shape (title/role)' ($revT | ConvertTo-Json)

    # ================= QA2 (AC-1): gate family + observability + AUDITOR pass-through =================
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-dr1', '-NodeId', $dev1, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $false -and ([string]$r.json.error.code) -like 'NODE_BLOCKED_BY_*') 'QA2 gate code family NODE_BLOCKED_BY_* (same family as stage gate)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'dispatch', '-RunId', 'deliver-qa-dr1', '-NodeId', $dev1)
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'QA2 dispatch touchpoint blocked too' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'status', '-RunId', 'deliver-qa-dr1')
    Assert-True ($r.raw -match 'design_review') 'QA2 status output observability (design_review surface)' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-dr1', '-NodeId', $revNode1, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'QA2 AUDITOR claim passes through the gate it owns' ($r.raw)

    # ================= QA3 (AC-1/8): pass path + pass-path ledger accounting =================
    $f3 = New-GraftedRun 'qa-dr3' '[{"title":"QA3","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]' @('design/d1.md') @{ stages = @(@{ id = 'S1'; tasks = @(1) }) }
    Write-Rv $f3.arch 'S1' @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @((New-F 'advisory' 'completeness')) }) @() | Out-Null
    $b = Read-BridgeJson $f3.run
    $rev3 = [string]$b.plan.stages[0].design_review.node
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $f3.run, '-NodeId', $rev3, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'QA3 AUDITOR claim ok' ($r.raw)
    $cb = New-Cb $rev3 @(($f3.arch + '/review/design-review-S1.json'), ($f3.arch + '/review/design-review-S1.md'))
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $f3.run, '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'QA3 review report ok' ($r.raw)
    $r = Do-Settle $f3.run $rev3
    Assert-True ($r.json.success -eq $true) 'QA3 valid pass file settles ok' ($r.raw)
    $b = Read-BridgeJson $f3.run
    $dr3 = $b.plan.stages[0].design_review
    Assert-True ([string]$dr3.status -eq 'passed' -and [string]$dr3.verdict -eq 'pass' -and ([string]$dr3.basis) -match 'engine-derived') 'QA3 engine-derived pass recorded with basis' ($b | ConvertTo-Json -Depth 6)
    $dev3 = [string]$b.tasks.'1'.stages.DEV
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $f3.run, '-NodeId', $dev3, '-Role', 'DEV')
    Assert-True ($r.json.success -eq $true) 'QA3 DEV claim unblocked after pass' ($r.raw)
    $passEntry = @(Read-Ledger | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.run_id -eq $f3.run -and [string]$_.verdict -eq 'pass' })
    Assert-True ($passEntry.Count -ge 1 -and [int]$passEntry[0].advisory_count -eq 1 -and $null -ne $passEntry[0].dimension_counts) 'QA3 pass-path ledger entry with dimension distribution' ((Read-Ledger) | ConvertTo-Json -Depth 4)

    # ================= QA4 (AC-2): contract negative battery =================
    $f4 = New-GraftedRun 'qa-dr4' '[{"title":"QA4","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]' @('design/d1.md') @{ stages = @(@{ id = 'S1'; tasks = @(1) }) }
    $b = Read-BridgeJson $f4.run
    $rev4 = [string]$b.plan.stages[0].design_review.node
    # initial valid-shaped file so the report citations exist on disk before report
    $passDoc  = @{ doc = 'design/d1.md'; verdict = 'pass'; findings = @() }
    Write-Rv $f4.arch 'S1' @($passDoc) @() | Out-Null
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $f4.run, '-NodeId', $rev4, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'QA4 AUDITOR claim ok' ($r.raw)
    # battery table: name | docs spec | cross spec | extra args | expected problem substring
    $battery = @(
        @{ n = 'fail-without-blocking'; docs = @(@{ doc = 'design/d1.md'; verdict = 'fail'; findings = @((New-F 'advisory' 'completeness')) }); cross = @(); m = 'no blocking finding' }
        @{ n = 'reviewer-not-auditor';  docs = @($passDoc); cross = @(); m = "reviewer must be one of auditor-delegated|auditor"; rev = 'qa' }
        @{ n = 'stage-mismatch';        docs = @($passDoc); cross = @(); m = 'does not match the reviewed stage'; stage = 'S9' }
        @{ n = 'severity-enum';         docs = @(@{ doc = 'design/d1.md'; verdict = 'fail'; findings = @((New-F 'critical' 'alignment')) }); cross = @(); m = "severity 'critical' not in" }
        @{ n = 'dimension-enum';        docs = @(@{ doc = 'design/d1.md'; verdict = 'fail'; findings = @((New-F 'blocking' 'style')) }); cross = @(); m = "dimension 'style' not in" }
        @{ n = 'empty-suggestion';      docs = @(@{ doc = 'design/d1.md'; verdict = 'fail'; findings = @((New-F 'blocking' 'alignment' 'item x' '')) }); cross = @(); m = 'suggestion is empty' }
        @{ n = 'duplicate-doc';         docs = @($passDoc, $passDoc); cross = @(); m = 'more than once' }
        @{ n = 'ghost-doc-listed';      docs = @($passDoc, @{ doc = 'design/ghost.md'; verdict = 'pass'; findings = @() }); cross = @(); m = "lists 'design/ghost.md' which is not an on-disk design doc" }
        @{ n = 'cross-ghost-involved';  docs = @($passDoc); cross = @(@{ severity = 'advisory'; item = 'i'; suggestion = 's'; involved_docs = @('design/ghost.md') }); m = "involved_docs lists 'design/ghost.md' which is not" }
        @{ n = 'cross-empty-involved';  docs = @($passDoc); cross = @(@{ severity = 'advisory'; item = 'i'; suggestion = 's'; involved_docs = @() }); m = 'involved_docs is empty' }
        @{ n = 'empty-reviewed-at';     docs = @($passDoc); cross = @(); m = 'reviewed_at is absent/empty'; at = '' }
        @{ n = 'docs-coverage-empty';   docs = @(); cross = @(); m = 'is not covered by docs' }
    )
    $cb = New-Cb $rev4 @(($f4.arch + '/review/design-review-S1.json'), ($f4.arch + '/review/design-review-S1.md'))
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $f4.run, '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'QA4 review report ok (battery fixture)' ($r.raw)
    $i = 0
    foreach ($case in $battery) {
        $i++
        $revArg = 'auditor'; if ($case.rev) { $revArg = $case.rev }
        $stageArg = ''; if ($case.stage) { $stageArg = $case.stage }
        $atArg = '2026-10-06T09:00:00Z'; if ($case.at -ne $null -and $case.ContainsKey('at')) { $atArg = $case.at }
        Write-Rv $f4.arch 'S1' $case.docs $case.cross $revArg $stageArg $atArg | Out-Null
        $r = Do-Settle $f4.run $rev4
        # PS5.1 ConvertTo-Json escapes single quotes as \u0027 inside the error envelope
        $rawSan = $r.raw -replace '\\u0027', "'"
        Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED' -and ($rawSan -match [regex]::Escape($case.m))) ("QA4.{0} rejected with locatable problem [{1}]" -f $i, $case.n) ($r.raw)
    }
    $b = Read-BridgeJson $f4.run
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'grafted') 'QA4 rejected settles never derive (stays grafted)' ($b | ConvertTo-Json -Depth 6)
    Write-Rv $f4.arch 'S1' @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @() }) @() | Out-Null
    $r = Do-Settle $f4.run $rev4
    Assert-True ($r.json.success -eq $true -and [string](Read-BridgeJson $f4.run).plan.stages[0].design_review.status -eq 'passed') 'QA4 valid file settles after battery (positive control)' ($r.raw)

    # ================= QA5 (AC-2/6): cross_design blocking -> engine-derived FAIL + wave =================
    $f5 = New-GraftedRun 'qa-dr5' '[{"title":"QA5","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]' @('design/d1.md') @{ stages = @(@{ id = 'S1'; tasks = @(1) }) }
    $b = Read-BridgeJson $f5.run
    $rev5 = [string]$b.plan.stages[0].design_review.node
    # contract-VALID file: docs all pass, but summary.cross_design carries a blocking entry
    Write-Rv $f5.arch 'S1' @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @((New-F 'advisory' 'completeness')) }) @(
        @{ severity = 'blocking'; item = 'cross-design cache policy split'; suggestion = 'register conflict for planner arbitration'; involved_docs = @('design/d1.md') }
    ) | Out-Null
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $f5.run, '-NodeId', $rev5, '-Role', 'AUDITOR')
    Assert-True ($r.json.success -eq $true) 'QA5 AUDITOR claim ok' ($r.raw)
    $cb = New-Cb $rev5 @(($f5.arch + '/review/design-review-S1.json'), ($f5.arch + '/review/design-review-S1.md'))
    $r = Invoke-Leaf @('-Command', 'report', '-RunId', $f5.run, '-Worker', 'AUDITOR', '-CallbackFile', $cb)
    Assert-True ($r.json.success -eq $true) 'QA5 review report ok' ($r.raw)
    $r = Do-Settle $f5.run $rev5
    Assert-True ($r.json.success -eq $true) 'QA5 contract-valid cross_design-blocking file settles (gate passes)' ($r.raw)
    $b = Read-BridgeJson $f5.run
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'planned') 'QA5 engine derived FAIL (docs pass + global blocking) -> wave reset planned' ($b | ConvertTo-Json -Depth 6)
    $rev5T = Find-TreeNode $f5.run $rev5
    Assert-True ($null -ne $rev5T -and [string]$rev5T.status -eq 'pruned') 'QA5 old review node reclaimed' ($rev5T | ConvertTo-Json)
    $r = Invoke-Flow @('-Command', 'show', '-Archive', $f5.arch)
    $t5 = @($r.json.data.tasks | Where-Object { [int]$_.id -eq 1 })[0]
    Assert-True ($null -ne $t5 -and @($t5.currentOwners) -contains 'CTO' -and [string]$t5.phase -eq 'DESIGN') 'QA5 task routed back CTO @ DESIGN' ($r.raw)
    $ctoNew = [string]$b.tasks.'1'.stages.CTO
    $ctoNewT = Find-TreeNode $f5.run $ctoNew
    Assert-True ($null -ne $ctoNewT -and ([string]$ctoNewT.task -match '\[cross_design\] design/d1\.md')) 'QA5 rebuilt CTO redo context carries the cross_design blocker' ($ctoNewT | ConvertTo-Json)
    $led = @(Read-Ledger | Where-Object { [string]$_.run_id -eq $f5.run })
    Assert-True (@($led | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.verdict -eq 'fail' }).Count -ge 1 -and @($led | Where-Object { [string]$_.kind -eq 'blocking' -and [string]$_.gap_type -eq 'cross_design' }).Count -ge 1) 'QA5 ledger: fail summary + blocking gap_type=cross_design' ($led | ConvertTo-Json -Depth 4)

    # ================= QA6 (AC-8): same-dimension blocking x3 -> reflux_suggestion =================
    # NodeWidth 8: each fail wave leaves a done CTO audit node under the goal root, so
    # three redo cycles need a wider fan-out than the auto floor of 4 (budget semantics
    # documented in Get-PromulgateBudget; at the floor the 3rd wave graft defers and
    # self-heals on the next trigger - observed boundary, not a defect).
    $f6 = New-GraftedRun 'qa-dr6' '[{"title":"QA6","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]' @('design/d1.md') @{ stages = @(@{ id = 'S1'; tasks = @(1) }) } '' 8
    $cycle = 1
    while ($cycle -le 3) {
        $b = Read-BridgeJson $f6.run
        $rev6 = [string]$b.plan.stages[0].design_review.node
        Write-Rv $f6.arch 'S1' @(@{ doc = 'design/d1.md'; verdict = 'fail'; findings = @(
            (New-F 'blocking' 'change_map' "cycle $cycle blocking"), (New-F 'advisory' 'completeness')) }) @() | Out-Null
        $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $f6.run, '-NodeId', $rev6, '-Role', 'AUDITOR')
        if ($r.json.success -ne $true) { throw "QA6 cycle $cycle claim failed: $($r.raw)" }
        $cb = New-Cb $rev6 @(($f6.arch + '/review/design-review-S1.json'), ($f6.arch + '/review/design-review-S1.md'))
        $r = Invoke-Leaf @('-Command', 'report', '-RunId', $f6.run, '-Worker', 'AUDITOR', '-CallbackFile', $cb)
        if ($r.json.success -ne $true) { throw "QA6 cycle $cycle report failed: $($r.raw)" }
        $r = Do-Settle $f6.run $rev6
        Assert-True ($r.json.success -eq $true) ("QA6 cycle {0} fail settle ok" -f $cycle) ($r.raw)
        $b = Read-BridgeJson $f6.run
        Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'planned') ("QA6 cycle {0} wave reset planned" -f $cycle) ($b | ConvertTo-Json -Depth 6)
        $blkN = @(Read-Ledger | Where-Object { [string]$_.kind -eq 'blocking' -and [string]$_.gap_type -eq 'change_map' -and [string]$_.run_id -eq $f6.run }).Count
        Assert-True ($blkN -eq $cycle) ("QA6 cycle {0} ledger blocking count = {0}" -f $cycle) ((Read-Ledger) | ConvertTo-Json -Depth 4)
        $refluxN = @(Read-Ledger | Where-Object { [string]$_.kind -eq 'reflux_suggestion' -and [string]$_.run_id -eq $f6.run }).Count
        if ($cycle -lt 3) {
            Assert-True ($refluxN -eq 0) ("QA6 cycle {0} no reflux suggestion below threshold 3" -f $cycle) ('')
            # redo convergence: deliver rebuilt CTO -> review re-grafts
            $cto6 = [string]$b.tasks.'1'.stages.CTO
            Do-Deliver $f6.run $cto6 'CTO' @(($f6.arch + '/design/d1.md')) | Out-Null
            $r = Do-Settle $f6.run $cto6
            Assert-True ($r.json.success -eq $true) ("QA6 cycle {0} redo CTO settle ok" -f $cycle) ($r.raw)
            $b = Read-BridgeJson $f6.run
            Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'grafted') ("QA6 cycle {0} re-review grafted after redo (re-review on convergence)" -f $cycle) ($b | ConvertTo-Json -Depth 6)
        }
        else {
            Assert-True ($refluxN -ge 1) 'QA6 reflux_suggestion ledger line at >=3 same-dimension blocking' ((Read-Ledger) | ConvertTo-Json -Depth 4)
        }
        $cycle++
    }

    # ================= QA7 (AC-5): multi-stage +K budget, one node per stage, isolation =================
    $arch7 = New-Archive 'qa-dr7' '[{"title":"QA7a","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]},{"title":"QA7b","requirement":"requirements/t2.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d2.md","status":"ready"}]}]'
    $pf7 = Write-TestPlan (Join-Path $Work 'qa-dr7-plan.json') @(@{ id = 'S1'; tasks = @(1) }, @{ id = 'S2'; tasks = @(2) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch7 + '/task.json'), '-PlanFile', $pf7, '-ConventionsFile', $convShared, '-NoPush')
    Assert-True ($r.json.success -eq $true -and [int]$r.json.data.budget.node_width -eq 7 -and [int]$r.json.data.budget.max_nodes -eq 19) 'QA7 budget +K with K=2: width 7 / nodes 19' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-dr7'
    $slots = @($b.plan.stages | Where-Object { $null -ne $_.design_review -and [string]$_.design_review.status -eq 'planned' })
    Assert-True ($slots.Count -eq 2) 'QA7 one design_review slot per stage (2 planned slots)' ($b | ConvertTo-Json -Depth 6)
    $c71 = [string]$b.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-qa-dr7' $c71 'CTO' @('.rdd/changes/archive/qa-dr7/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-qa-dr7' $c71
    Assert-True ($r.json.success -eq $true) 'QA7 S1 CTO settle ok' ($r.raw)
    $b = Read-BridgeJson 'deliver-qa-dr7'
    Assert-True ([string]$b.plan.stages[0].design_review.status -eq 'grafted' -and [string]$b.plan.stages[1].design_review.status -eq 'planned') 'QA7 stage isolation: S1 grafted, S2 stays planned' ($b | ConvertTo-Json -Depth 6)
    Assert-True ((Count-ReviewTitleNodes 'deliver-qa-dr7' 'S1') -eq 1 -and (Count-ReviewTitleNodes 'deliver-qa-dr7' 'S2') -eq 0) 'QA7 exactly one aggregated review node for S1, none for S2 (one-session aggregation)' ('')

    # ================= QA9 (AC-3): AUDITOR claim context completeness =================
    # criteria-bearing archive (mode=criteria) so the criteria_ref face is populated:
    # the plan anchors stage acceptance_point.criteria_ref at the fixed overview anchor.
    $conv9 = Join-Path $Work 'qa-dr9-conventions.md'
    Write-Utf8NoBom $conv9 "# conventions (test)`n`n- layered architecture; naming follows existing style.`n"
    $anchor9 = 'requirements/overview.md#' + $TAccHead
    $f9 = New-GraftedRun 'qa-dr9' '[{"title":"QA9","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]' @('design/d1.md') @{ stages = @(@{ id = 'S1'; tasks = @(1) }) } $conv9 0 'QA9 overall criteria: core flow verifiable end to end (probe line)' $anchor9
    $b = Read-BridgeJson $f9.run
    $rev9 = [string]$b.plan.stages[0].design_review.node
    $r = Invoke-Bridge @('-Command', 'claim', '-RunId', $f9.run, '-NodeId', $rev9, '-Role', 'AUDITOR')
    $acc = $null; if ($r.json.success) { $acc = $r.json.data.acceptance }
    Assert-True ($null -ne $acc -and [string]$acc.kind -eq 'design_review') 'QA9 claim context kind=design_review' ($r.raw)
    Assert-True (@($acc.docs) -contains 'design/d1.md') 'QA9 claim context docs face' ($r.raw)
    $maps = @($acc.design_maps)
    Assert-True ($maps.Count -ge 1 -and [string]$maps[0].doc -eq 'design/d1.md' -and @($maps[0].files).Count -ge 1) 'QA9 claim context design_maps mechanical cache rows (change_map face)' ($r.raw)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$acc.conventions) -and [string]$acc.criteria_ref -eq $anchor9 -and [string]$acc.report -eq 'review/design-review-S1.json') 'QA9 claim context conventions + criteria_ref anchor + report path' ($r.raw)
}
finally {
    Pop-Location
}

# ================= QA8 (AC-3/4/6): delivered contract docs consistency anchors =================
function Read-RepoDoc { param([string]$Rel)
    [System.IO.File]::ReadAllText((Join-Path $RepoRoot ($Rel -replace '/', '\')), [System.Text.Encoding]::UTF8)
}
$drDoc = Read-RepoDoc 'rdd-auditor/references/design-review.md'
foreach ($dim in @('alignment', 'change_map', 'internal_consistency', 'completeness', 'cross_design')) {
    Assert-True ($drDoc -match [regex]::Escape($dim)) "QA8 design-review.md dimension anchor [$dim]" ('')
}
Assert-True ($drDoc -match 'reflux_suggestion' -and $drDoc -match 'design-review-S') 'QA8 design-review.md reflux accounting + report naming contract' ('')
Assert-True (($drDoc.IndexOf($TBound1) -ge 0) -and ($drDoc.IndexOf($TBound2) -ge 0) -and ($drDoc.IndexOf($TBound3) -ge 0)) 'QA8 design-review.md three boundaries (no tech-choice judging / no design edits / no test writing)' ('')
$skillDoc = Read-RepoDoc 'rdd-auditor/SKILL.md'
Assert-True ($skillDoc -match 'design-review\.md' -and $skillDoc -match 'review/design-review-S') 'QA8 SKILL.md wires the design-review reference + product whitelist' ('')
$pgDoc = Read-RepoDoc 'rdd-engine/references/planner-guide.md'
Assert-True ($pgDoc -match 'NODE_BLOCKED_BY_DESIGN_REVIEW' -and $pgDoc -match 'blocked_by_design_review') 'QA8 planner-guide gate codes (claim family + push skip face)' ('')
$rrDoc = Read-RepoDoc 'rdd-auditor/references/requirement-review.md'
Assert-True ($rrDoc -match 'REVIEW_FILE_INVALID' -and $rrDoc -match 'REVIEW_TASK_NOT_FOUND' -and $rrDoc -match 'REVIEW_EXCLUDED_DEP') 'QA8 requirement-review.md error-code list anchors' ('')

$fails = @($Results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ("design-review QA probe: {0} assertions, {1} failed" -f $Results.Count, $fails.Count)
Write-Output ("work dir: {0}" -f $Work)
if ($fails.Count -gt 0) { exit 1 }
exit 0

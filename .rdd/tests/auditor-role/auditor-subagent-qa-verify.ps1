# auditor-subagent-qa-verify.ps1 - QA independent black-box probe for
# auditor-subagent-review (AUDITOR review moved into planer-dispatched review
# subagents; both review gates become contract-shaped).
#
# Requirement source (QA reads requirements only, never design/):
#   .rdd/changes/archive/2026-10-07-planner-midrun-derive/requirements/
#   auditor-subagent-review.md  (acceptance criteria 1-7)
#
# Independent from the DEV suite (rdd-engine/tests/test-bridge-design-review.ps1
# NR1-NR8 / test-review-input-template.ps1): cases below are designed from the
# 7 acceptance criteria and probe faces the DEV suite does not (zero-+K budget
# delta measured against a legacy twin run, zero-node evidence, gate still armed
# in ready state, negative battery taken in the new chain only, reviewer
# `planner` (legacy read-only) actively refused in the new chain, reject -From
# end-to-end, preset family after the 9->8 collapse, and the single-entry
# PLANNER pointer text actually emitted by start-role).
#
#   QA-N1 (AC-2/5) new chain promulgate: review_mode persisted, slot planned at
#          promulgate, mechanical template ref surfaced, and the +K audit-node
#          budget bump is gone (measured against an identical legacy twin run)
#   QA-N2 (AC-2/6) CTO settle -> ready (contract state, NOT a grafted node):
#          zero review nodes, zero node growth, no design_review_grafted event,
#          gate still armed in ready state, status face = mechanical checklist
#          (chain label / docs / criteria / conventions / template / reviewers)
#   QA-N3 (AC-2) contract gate negative battery on submit: 5 violation shapes
#          each -> SETTLE_EVIDENCE_REJECTED with a locatable problem + zero side
#          effects (state stays ready); action guard + legacy run refusal
#   QA-N4 (AC-2/4) pass path: engine-derived pass -> IMPL gate opens, ledger
#          signed auditor-delegated, ZERO review nodes for the whole lifetime,
#          repeat submit refused
#   QA-N5 (AC-2) fail path: contract-valid file with a global blocking finding
#          -> engine-derived fail -> redo wave (task back to CTO@DESIGN) with
#          zero nodes to reclaim (no [design-review] node anywhere)
#   QA-N6 (AC-7) legacy compatibility: a key-less run still grafts the
#          [design-review] node, keeps +K, refuses submit (DESIGN_REVIEW_LEGACY_RUN)
#          and settles through the node channel exactly as before
#   QA-N7 (AC-4) reviewer enum touches all four signing faces: rdd-flow reject
#          -From auditor-delegated accepted verbatim, ReviewFile consumption
#          tolerates auditor-delegated + legacy planner, DesignReviewFile domain
#          widened but still closed
#   QA-N8 (AC-5) deployment criterion becomes a config item: preset family 8 by
#          default with rdd-auditor rebuildable on demand, manifest/guide anchors
#   QA-N9 (AC-1/3) single-entry takeover + protocol-shaped review input: the
#          PLANNER pointer that start-role actually emits instructs dispatching
#          a review subagent with the mechanical template (two-hop wording gone),
#          and the template carries the five protocol prohibitions
#
# Runs the production interpreters (Windows PowerShell 5.1) against a throwaway
# git repo under %TEMP%. ASCII-only source: Chinese tokens are built from
# codepoints so the file is BOM-independent on PS5.1. Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Remove-Item Env:\DSH_SESSION_ID -ErrorAction SilentlyContinue

# repo root = <repo>/.rdd/tests/auditor-role -> up three levels
$RepoRoot  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$EngineDir = Join-Path $RepoRoot 'rdd-engine\scripts'
$RefsDir   = Join-Path $RepoRoot 'rdd-engine\references'
$BridgePs1 = Join-Path $EngineDir 'delivery-bridge.ps1'
$FlowPs1   = Join-Path $EngineDir 'rdd-flow.ps1'
$LeafPs1   = Join-Path $EngineDir 'goal-tree-leaf.ps1'
$StartPs1  = Join-Path $EngineDir 'start-role.ps1'
$Work      = Join-Path $env:TEMP ('auditor-subagent-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# ---------- codepoint token builders (ASCII-only source discipline) ----------
function C { param([int[]]$Codes) (-join ($Codes | ForEach-Object { [char]$_ })) }
$TReviewPfx  = C @(0x8BBE,0x8BA1,0x5BA1,0x67E5,0x00B7)                        # design-review prefix + middle dot
function Review-Title { param([string]$StageId) ('[' + $TReviewPfx + $StageId + ']') }
$TSubagent   = C @(0x8BC4,0x5BA1,0x5B50,0x4EE3,0x7406)                        # review subagent
$TSubagentS  = C @(0x5BA1,0x89C6,0x5B50,0x4EE3,0x7406)                        # ...-review subagent (pointer wording)
$TInnate     = C @(0x5185,0x751F,0x4E8E,0x89C4,0x5212,0x8005)                 # intrinsic to the planner
$TBan1       = C @(0x7981,0x6B62,0x8F6C,0x8FF0)                               # prohibition: no paraphrasing
$TBan2       = C @(0x7981,0x6B62,0x88C1,0x5B9A,0x503E,0x5411,0x6CE8,0x5165)   # prohibition: no verdict bias
$TBan3       = C @(0x7981,0x6B62,0x4EE3,0x5BA1)                               # prohibition: no proxy review
$TBan4       = C @(0x96F6,0x7236,0x5BF9,0x8BDD,0x7EE7,0x627F)                 # zero parent-context inheritance
$TBan5       = C @(0x7559,0x75D5,0x53EF,0x5BA1,0x8BA1)                        # auditable trail
$TTwoStage   = C @(0x4E24,0x6BB5,0x5F0F)                                      # two-stage (retired wording)
$TTwoStageTk = C @(0x4E24,0x6BB5,0x5F0F,0x63A5,0x7BA1)                        # two-stage takeover (retired)
$TOneEntry   = C @(0x5355,0x5165,0x53E3)                                      # single entry point
$TStepMark   = C @(0x6B65,0x9AA4,0x0020,0x2460)                               # "step (1)" legacy wording
$TLegacyRO   = C @(0x5B58,0x91CF,0x53EA,0x8BFB)                               # legacy read-only
$TDeployAnchor = C @(0x90E8,0x7F72,0x5224,0x636E)                             # deployment criterion
$TAccHead    = C @(0x6574,0x4F53,0x9A8C,0x6536,0x5224,0x636E)                 # overall acceptance heading
$TAccNone    = C @(0x65E0,0x6574,0x4F53,0x5224,0x636E)                        # declared-none prefix
$TDeclared   = C @(0x663E,0x5F0F,0x58F0,0x660E)                               # explicit declaration

$TemplateRel = 'rdd-engine/references/review-input-template.md'
$AccBlock    = "## $TAccHead`n`n$TAccNone ($TDeclared, QA probe fixture)`n"

# ---------- harness ----------
$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# Child stderr is expected on the negative cases (parameter validation, fail-loud
# envelopes); a real child must never take the probe down with it, so the merge
# runs under a locally relaxed preference (restored in finally).
function Invoke-Ps1 { param([string]$Script, [string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & powershell @all 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE
    return @{ json = (ConvertFrom-RawJson $out); exit = $code; raw = $out }
}
function Invoke-Bridge { param([string[]]$A) Invoke-Ps1 $BridgePs1 $A }
function Invoke-Flow   { param([string[]]$A) Invoke-Ps1 $FlowPs1 $A }
function Invoke-Leaf   { param([string[]]$A) Invoke-Ps1 $LeafPs1 $A }

# Envelope parse with fallback: diagnostics may precede/companion the JSON line.
function ConvertFrom-RawJson { param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { $j = ($Raw | ConvertFrom-Json); if ($null -ne $j) { return $j } } catch { }
    $lines = @($Raw -split "`r?`n" | Where-Object { $_ -match '^\s*\{\s*"success"' })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try { return ($lines[$i] | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-TextFile { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Read-BridgeJson { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/bridge.json')
    (Read-TextFile $p | ConvertFrom-Json)
}
function Read-TreeNodes { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/state/tree.json')
    $d = (Read-TextFile $p | ConvertFrom-Json)
    return @($d.nodes)
}
function Read-PlanLog { param([string]$RunId)
    $p = Join-Path $Work ('.rdd/goal-trees/' + $RunId + '/plan-log.jsonl')
    return [string](Read-TextFile $p)
}
function Count-ReviewTitleNodes { param([string]$RunId, [string]$StageId)
    $t = Review-Title $StageId
    return @((Read-TreeNodes $RunId) | Where-Object { [string]$_.title -eq $t }).Count
}
function Read-Ledger { param([string]$RunId)
    $p = Join-Path $Work '.rdd/review-ledger.jsonl'
    $out = @()
    $raw = Read-TextFile $p
    if ($null -ne $raw) {
        foreach ($ln in @($raw -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try { $out += ($ln | ConvertFrom-Json) } catch { }
        }
    }
    return @($out)
}

function New-Cb { param([string]$NodeId, [string[]]$Refs)
    $cb = [ordered]@{
        node_id = $NodeId; verdict = 'done'; confidence = 0.9
        summary = 'auditor-subagent QA probe delivery'
        citations = @($Refs | ForEach-Object { @{ ref = $_; locator = 'L1' } })
        next_suggestion = ''
        extras = @{ verification = 'probe ok'; quality_scan = @{ skip = $true; reason = 'test fixture: cited change set carries no PowerShell files' } }
    }
    $cbFile = Join-Path $Work ("qa-cb-$NodeId-$([guid]::NewGuid().ToString('N').Substring(0,6)).json")
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
    return Invoke-Bridge @('-Command', 'settle', '-RunId', $RunId, '-NodeId', $NodeId)
}

function New-Archive { param([string]$Name, [string]$TasksJson)
    $archDir = Join-Path $Work (".rdd/changes/archive/$Name")
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $archDir 'requirements/overview.md') ("# $Name`n`nQA probe archive $Name.`n`n" + $AccBlock)
    $i = 1
    foreach ($line in ($TasksJson | ConvertFrom-Json)) {
        Write-Utf8NoBom (Join-Path $archDir ("requirements/t$i.md")) "# $Name requirement $i`n`n- QA probe requirement $i`n"
        foreach ($d in @($line.designDocs)) {
            if ($d -and $d.path) {
                $dAbs = Join-Path $archDir ([string]$d.path)
                $dDir = Split-Path $dAbs -Parent
                if (-not (Test-Path $dDir)) { New-Item -ItemType Directory -Path $dDir -Force | Out-Null }
                Write-Utf8NoBom $dAbs "# design doc`n`n- QA probe design product $i`n"
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

function Write-TestPlan { param([string]$Path, $Stages)
    $stageObjs = @()
    foreach ($st in @($Stages)) {
        $ap = @{ criteria_items = @('smoke: core flow works'); slice = 'runnable single-command slice' }
        if ($st.criteria_ref) { $ap['criteria_ref'] = [string]$st.criteria_ref }
        $ids = @($st.tasks | ForEach-Object { [int]$_ } | Sort-Object)
        $stageObjs += ,@{
            id = [string]$st.id
            goal = "stage $($st.id) goal"
            milestone = "stage $($st.id) milestone"
            task_ids = $ids
            batches = @(,$ids)
            acceptance_point = $ap
        }
    }
    $plan = [ordered]@{ planned_at = '2026-10-08T00:00:00Z'; planner = 'qa'; stages = $stageObjs; risks = @() }
    Write-Utf8NoBom $Path ($plan | ConvertTo-Json -Depth 8)
    return $Path
}

# DesignReviewFile writer (archive-relative). $Docs = @(@{ doc; verdict; findings }).
function Write-Rv { param([string]$ArchiveRel, [string]$StageId, $Docs, $Cross = @(),
    [string]$Reviewer = 'auditor-delegated', [string]$StageField = '', $Prod = $null)
    $file = [ordered]@{
        reviewed_at = '2026-10-08T09:00:00Z'
        reviewer = $Reviewer
        stage = $(if ($StageField) { $StageField } else { $StageId })
        docs = @($Docs)
        summary = @{ cross_design = @($Cross) }
    }
    if ($null -ne $Prod) { $file['production'] = $Prod }
    $rel = "review/design-review-$StageId"
    $abs = Join-Path $Work (($ArchiveRel + '/' + $rel + '.json') -replace '/', '\')
    $dir = Split-Path $abs -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8NoBom $abs ($file | ConvertTo-Json -Depth 6)
    Write-Utf8NoBom ($abs -replace '\.json$', '.md') "# design review mirror`n"
    return ($rel + '.json')
}
function New-F { param([string]$Sev, [string]$Dim, [string]$Item = 'finding item', [string]$Sug = 'finding suggestion')
    return @{ severity = $Sev; dimension = $Dim; item = $Item; suggestion = $Sug }
}
function New-Prod { param([string]$Mode = 'subagent', [string]$Template = $TemplateRel)
    return @{ mode = $Mode; template = $Template }
}

$OneTask = '[{"title":"NR","requirement":"requirements/t1.md","currentOwners":["CTO"],"designDocs":[{"path":"design/d1.md","status":"ready"}]}]'
$ConvRel = 'qa-conventions.md'

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$null = git init -q $Work 2>$null
Push-Location $Work
$exitCode = 0
try {
    Write-Utf8NoBom (Join-Path $Work $ConvRel) "# conventions (probe)`n`n- layered architecture; naming follows existing style.`n"

    # ================= QA-N1 (AC-2/5): new chain promulgate + zero +K =================
    $archL = New-Archive 'qa-nal' $OneTask
    $planL = Write-TestPlan (Join-Path $Work 'qa-nal-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $rL = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archL + '/task.json'), '-PlanFile', $planL, '-ConventionsFile', $ConvRel, '-NoPush')
    Assert-True ($rL.json.success -eq $true) 'QA-N1 legacy twin promulgate ok (budget baseline)' ($rL.raw)

    $arch1 = New-Archive 'qa-na1' $OneTask
    $plan1 = Write-TestPlan (Join-Path $Work 'qa-na1-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r1 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch1 + '/task.json'), '-PlanFile', $plan1, '-ConventionsFile', $ConvRel, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r1.json.success -eq $true) 'QA-N1 new-chain promulgate (review_mode=subagent) ok' ($r1.raw)

    $b1 = Read-BridgeJson 'deliver-qa-na1'
    Assert-True ([string]$b1.review_mode -eq 'subagent') 'QA-N1 review_mode persisted on the bridge (config-item carrier)' ($b1 | ConvertTo-Json -Depth 4)
    Assert-True ($null -ne $b1.plan.stages[0].design_review -and [string]$b1.plan.stages[0].design_review.status -eq 'planned' -and $null -eq $b1.plan.stages[0].design_review.node) 'QA-N1 slot lands planned with no node at promulgate' ($b1 | ConvertTo-Json -Depth 6)
    Assert-True ([string]$r1.json.data.design_review.note -match 'review-input-template\.md' -and [string]$r1.json.data.design_review.note -match 'design-review') 'QA-N1 response note points at the mechanical template + submit entry' ($r1.raw)

    $legacyNodes = [int]$rL.json.data.budget.max_nodes
    $newNodes = [int]$r1.json.data.budget.max_nodes
    Assert-True ($newNodes -lt $legacyNodes) ("QA-N1 zero +K: identical fixture budgets legacy={0} vs new-chain={1} (stage review node budget gone)" -f $legacyNodes, $newNodes) ($r1.raw)
    Assert-True ([string]$rL.json.data.design_review.deployed -eq 'True' -and -not [string]::IsNullOrWhiteSpace([string]$rL.json.data.design_review.note)) 'QA-N1 legacy twin keeps the deployment-probe chain (control)' ($rL.raw)

    # ================= QA-N2 (AC-2/6): settle -> ready, zero nodes, zero push =================
    $nodesBefore = @(Read-TreeNodes 'deliver-qa-na1').Count
    $cto1 = [string]$b1.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-qa-na1' $cto1 'CTO' @($arch1 + '/design/d1.md') | Out-Null
    $rs = Do-Settle 'deliver-qa-na1' $cto1
    Assert-True ($rs.json.success -eq $true) 'QA-N2 CTO settle ok (stage converged)' ($rs.raw)

    $b1 = Read-BridgeJson 'deliver-qa-na1'
    $dr1 = $b1.plan.stages[0].design_review
    Assert-True ([string]$dr1.status -eq 'ready' -and $null -eq $dr1.node) 'QA-N2 ready contract state (no grafted node)' ($b1 | ConvertTo-Json -Depth 6)
    Assert-True ((Count-ReviewTitleNodes 'deliver-qa-na1' 'S1') -eq 0) 'QA-N2 zero review nodes in the tree' ('')
    $nodesAfter = @(Read-TreeNodes 'deliver-qa-na1')
    $growth = $nodesAfter.Count - $nodesBefore
    Assert-True ($growth -le 1) ("QA-N2 zero review-node growth across the trigger (nodes {0} -> {1}; new nodes: {2})" -f $nodesBefore, $nodesAfter.Count, (@($nodesAfter | ForEach-Object { [string]$_.role }) -join ',')) ('')
    $plog = Read-PlanLog 'deliver-qa-na1'
    Assert-True ($plog -match 'design_review_ready' -and ($plog -notmatch 'design_review_grafted')) 'QA-N2 plan-log: ready event, never a graft event' ($plog)

    $dev1 = [string]$b1.tasks.'1'.stages.DEV
    $rg = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-na1', '-NodeId', $dev1, '-Role', 'DEV')
    Assert-True ($rg.json.success -eq $false -and [string]$rg.json.error.code -eq 'NODE_BLOCKED_BY_DESIGN_REVIEW') 'QA-N2 IMPL gate armed in ready state (review cannot be skipped)' ($rg.raw)

    $st = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', 'deliver-qa-na1')
    $row = @($st.json.data.stages)[0]
    Assert-True ($st.json.success -eq $true -and [string]$st.json.data.chain -eq 'contract (submit)' -and [string]$st.json.data.review_mode -eq 'subagent') 'QA-N2s status face: contract chain label + mode' ($st.raw)
    Assert-True ([string]$row.status -eq 'ready' -and (@($row.docs) -contains 'design/d1.md')) 'QA-N2s status face: ready stage + on-disk doc list' ($st.raw)
    Assert-True ([string]$row.template -eq $TemplateRel -and [string]$row.production.mode -eq 'subagent' -and [string]$row.production.template -eq $TemplateRel) 'QA-N2s status face: template ref + production constants (mechanical only)' ($st.raw)
    Assert-True ((-not [string]::IsNullOrWhiteSpace([string]$row.conventions)) -and ([string]$row.conventions).EndsWith('architecture-conventions.md')) 'QA-N2s status face: conventions ref derived mechanically from the input file' ($st.raw)
    Assert-True ((@($st.json.data.reviewers) -contains 'auditor-delegated') -and (@($st.json.data.reviewers) -contains 'auditor')) 'QA-N2s status face: reviewer enum single source' ($st.raw)
    Assert-True (([string]$st.json.data.next_step).Contains('review-input-template.md') -and ([string]$st.json.data.next_step).Contains($TSubagent) -and -not ([string]$st.json.data.next_step).Contains('start-role')) 'QA-N2s next_step dispatches a review subagent, never a reviewer session' ($st.raw)

    # ================= QA-N3 (AC-2): submit negative battery + guards =================
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-qa-na1', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED') 'QA-N3.1 submit without a file refused (fail-loud)' ($r.raw)

    $battery = @(
        @{ n = 'reviewer-planner-legacy-value'; docs = @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @() }); cross = @(); rev = 'planner'; prod = $null; m = "reviewer must be one of auditor-delegated|auditor" },
        @{ n = 'doc-not-covered';               docs = @();                                                                cross = @(); rev = 'auditor-delegated'; prod = $null; m = "docs[] is empty" },
        @{ n = 'production-mode-out-of-domain'; docs = @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @() }); cross = @(); rev = 'auditor-delegated'; prod = @{ mode = 'bogus'; template = $TemplateRel }; m = "production.mode" },
        @{ n = 'stage-mismatch';                docs = @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @() }); cross = @(); rev = 'auditor-delegated'; prod = $null; stage = 'S9'; m = "does not match the reviewed stage" },
        @{ n = 'pass-with-blocking';            docs = @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @((New-F 'blocking' 'completeness')) }); cross = @(); rev = 'auditor-delegated'; prod = $null; m = "pass but carries" }
    )
    $i = 0
    foreach ($case in $battery) {
        $i++
        $stageField = ''; if ($case.ContainsKey('stage')) { $stageField = [string]$case.stage }
        Write-Rv $arch1 'S1' $case.docs $case.cross ([string]$case.rev) $stageField $case.prod | Out-Null
        $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-qa-na1', '-Stage', 'S1')
        $rawSan = $r.raw -replace '\\u0027', "'"
        $ok = ($r.json.success -eq $false) -and ([string]$r.json.error.code -eq 'SETTLE_EVIDENCE_REJECTED') -and ($rawSan -match [regex]::Escape([string]$case.m))
        Assert-True $ok ("QA-N4.{0} refused with a locatable problem [{1}]" -f $i, $case.n) ($r.raw)
        $bMid = Read-BridgeJson 'deliver-qa-na1'
        $midState = [string]$bMid.plan.stages[0].design_review.status
        Assert-True ($midState -eq 'ready') ("QA-N4.{0} zero side effects (still ready after refusal)" -f $i) ($midState)
    }

    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'open', '-RunId', 'deliver-qa-na1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_ACTION_INVALID') 'QA-N3 action guard: conflict/derive actions refused' ($r.raw)
    $r = Invoke-Bridge @('-Command', 'design-review', '-RunId', 'deliver-qa-na1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_ACTION_REQUIRED') 'QA-N3 missing -Action refused' ($r.raw)

    # ================= QA-N4 (AC-2/4): pass path =================
    Write-Rv $arch1 'S1' @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @((New-F 'advisory' 'completeness')) }) @() 'auditor-delegated' '' (New-Prod 'subagent') | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-qa-na1', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'pass' -and [string]$r.json.data.status -eq 'passed') 'QA-N4 valid pass file -> engine-derived pass, status passed' ($r.raw)
    Assert-True ([string]$r.json.data.reviewer -eq 'auditor-delegated' -and [string]$r.json.data.review_mode -eq 'subagent') 'QA-N4 submit receipt signs the delegated reviewer + mode' ($r.raw)

    $b1 = Read-BridgeJson 'deliver-qa-na1'
    Assert-True ([string]$b1.plan.stages[0].design_review.status -eq 'passed' -and $null -eq $b1.plan.stages[0].design_review.node -and ([string]$b1.plan.stages[0].design_review.basis -match 'engine-derived')) 'QA-N4 engine-derived pass recorded on an empty node slot' ($b1 | ConvertTo-Json -Depth 6)
    Assert-True ((Count-ReviewTitleNodes 'deliver-qa-na1' 'S1') -eq 0) 'QA-N4 still zero review nodes after adjudication (record never materialised)' ('')
    $rd = Invoke-Bridge @('-Command', 'claim', '-RunId', 'deliver-qa-na1', '-NodeId', $dev1, '-Role', 'DEV')
    Assert-True ($rd.json.success -eq $true) 'QA-N4 IMPL gate opens after the delegated pass' ($rd.raw)
    $led = @(Read-Ledger 'deliver-qa-na1' | Where-Object { [string]$_.run_id -eq 'deliver-qa-na1' -and [string]$_.kind -eq 'design_review' -and [string]$_.verdict -eq 'pass' })
    Assert-True ($led.Count -ge 1 -and [string]$led[0].reviewer -eq 'auditor-delegated') 'QA-N4 review ledger signed auditor-delegated' ($led | ConvertTo-Json -Depth 4)
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-qa-na1', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_NOT_READY') 'QA-N4 repeat submit refused (single adjudication per cycle)' ($r.raw)

    # ================= QA-N5 (AC-2): fail path, zero nodes to reclaim =================
    $arch5 = New-Archive 'qa-na5' $OneTask
    $plan5 = Write-TestPlan (Join-Path $Work 'qa-na5-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r5 = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($arch5 + '/task.json'), '-PlanFile', $plan5, '-ConventionsFile', $ConvRel, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r5.json.success -eq $true) 'QA-N5 fail-path fixture promulgated' ($r5.raw)
    $b5 = Read-BridgeJson 'deliver-qa-na5'
    $cto5 = [string]$b5.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-qa-na5' $cto5 'CTO' @($arch5 + '/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-qa-na5' $cto5
    Assert-True ($r.json.success -eq $true) 'QA-N5 CTO settle ok' ($r.raw)
    $nodesBefore5 = @(Read-TreeNodes 'deliver-qa-na5').Count

    Write-Rv $arch5 'S1' @(@{ doc = 'design/d1.md'; verdict = 'fail'; findings = @((New-F 'blocking' 'change_map' 'design product incomplete')) }) @() 'auditor-delegated' '' (New-Prod 'subagent') | Out-Null
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-qa-na5', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.verdict -eq 'fail') 'QA-N5 blocking file -> engine-derived fail adjudicated' ($r.raw)

    $b5 = Read-BridgeJson 'deliver-qa-na5'
    Assert-True ([string]$b5.plan.stages[0].design_review.status -eq 'planned' -and (@($r.json.data.wave.rolled).Count -ge 1)) 'QA-N5 fail wave rolled the affected task back (state reset planned)' ($r.raw)
    Assert-True ((Count-ReviewTitleNodes 'deliver-qa-na5' 'S1') -eq 0) 'QA-N5 zero review nodes reclaimed (none ever existed)' ('')
    $n5 = Invoke-Flow @('-Command', 'show', '-Archive', $arch5)
    $t5 = @($n5.json.data.tasks | Where-Object { [int]$_.id -eq 1 })[0]
    Assert-True ($null -ne $t5 -and (@($t5.currentOwners) -contains 'CTO') -and [string]$t5.phase -eq 'DESIGN') 'QA-N5 task routed back to CTO @ DESIGN for redo' ($n5.raw)
    $redoCto = [string](Read-BridgeJson 'deliver-qa-na5').tasks.'1'.stages.CTO
    $rt = @(Read-TreeNodes 'deliver-qa-na5' | Where-Object { [string]$_.id -eq $redoCto })[0]
    Assert-True ($null -ne $rt -and ([string]$rt.task -match 'change_map')) 'QA-N5 rebuilt redo context carries the blocking dimension' ($rt | ConvertTo-Json)
    $led5 = @(Read-Ledger 'deliver-qa-na5' | Where-Object { [string]$_.run_id -eq 'deliver-qa-na5' })
    Assert-True (@($led5 | Where-Object { [string]$_.kind -eq 'design_review' -and [string]$_.verdict -eq 'fail' -and [string]$_.reviewer -eq 'auditor-delegated' }).Count -ge 1) 'QA-N5 fail summary ledger signed auditor-delegated' ($led5 | ConvertTo-Json -Depth 4)
    Assert-True (@($led5 | Where-Object { [string]$_.kind -eq 'blocking' -and [string]$_.gap_type -eq 'change_map' }).Count -ge 1) 'QA-N5 per-blocking ledger entry with gap_type=change_map' ($led5 | ConvertTo-Json -Depth 4)

    # ================= QA-N6 (AC-7): legacy run untouched =================
    $bL = Read-BridgeJson 'deliver-qa-nal'
    $ctoL = [string]$bL.tasks.'1'.stages.CTO
    Do-Deliver 'deliver-qa-nal' $ctoL 'CTO' @($archL + '/design/d1.md') | Out-Null
    $r = Do-Settle 'deliver-qa-nal' $ctoL
    Assert-True ($r.json.success -eq $true) 'QA-N6 legacy CTO settle ok' ($r.raw)
    $bL = Read-BridgeJson 'deliver-qa-nal'
    $revL = [string]$bL.plan.stages[0].design_review.node
    Assert-True ([string]$bL.plan.stages[0].design_review.status -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace($revL)) 'QA-N6 legacy run still grafts the review node (behaviour not回溯)' ($bL | ConvertTo-Json -Depth 6)
    Assert-True ((Count-ReviewTitleNodes 'deliver-qa-nal' 'S1') -eq 1) 'QA-N6 legacy review node present in the tree' ('')
    $r = Invoke-Bridge @('-Command', 'design-review', '-Action', 'submit', '-RunId', 'deliver-qa-nal', '-Stage', 'S1')
    Assert-True ($r.json.success -eq $false -and [string]$r.json.error.code -eq 'DESIGN_REVIEW_LEGACY_RUN') 'QA-N6 submit on a key-less run refused (node channel only)' ($r.raw)
    $stL = Invoke-Bridge @('-Command', 'design-review', '-Action', 'status', '-RunId', 'deliver-qa-nal')
    Assert-True ([string]$stL.json.data.chain -eq 'legacy (node settle)' -and $null -eq $stL.json.data.review_mode) 'QA-N6 legacy status face labels the node chain' ($stL.raw)

    Write-Rv $archL 'S1' @(@{ doc = 'design/d1.md'; verdict = 'pass'; findings = @() }) @() 'auditor' | Out-Null
    Do-Deliver 'deliver-qa-nal' $revL 'AUDITOR' @(($archL + '/review/design-review-S1.json'), ($archL + '/review/design-review-S1.md')) | Out-Null
    $r = Do-Settle 'deliver-qa-nal' $revL
    Assert-True ($r.json.success -eq $true) 'QA-N6 legacy node settles through the unchanged gate' ($r.raw)
    $bL = Read-BridgeJson 'deliver-qa-nal'
    Assert-True ([string]$bL.plan.stages[0].design_review.status -eq 'passed') 'QA-N6 legacy verdict recorded (auditor reviewer still legal)' ($bL | ConvertTo-Json -Depth 6)
    $ledL = @(Read-Ledger 'deliver-qa-nal' | Where-Object { [string]$_.run_id -eq 'deliver-qa-nal' -and [string]$_.kind -eq 'design_review' })
    Assert-True ($ledL.Count -ge 1 -and [string]$ledL[0].reviewer -eq 'auditor') 'QA-N6 legacy ledger keeps the auditor signature' ($ledL | ConvertTo-Json -Depth 4)

    # ================= QA-N7 (AC-4): reviewer enum across signing faces =================
    $arch7 = New-Archive 'qa-na7' $OneTask
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', $arch7, '-TaskId', '1', '-From', 'auditor-delegated', '-To', 'PM', '-Reason', 'probe: delegated reviewer returns the item')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.rejectedBy -eq 'auditor-delegated') 'QA-N7 reject -From auditor-delegated accepted verbatim' ($r.raw)
    Assert-True (([string]$r.json.data.remark).Contains('auditor-delegated')) 'QA-N7 reject record keeps the delegated signer in the task remark' ($r.raw)

    $rfPath = Join-Path $Work 'qa-na7-review.json'
    Write-Utf8NoBom $rfPath (@{ reviewed_at = '2026-10-08T09:00:00Z'; reviewer = 'auditor-delegated'; verdicts = @(@{ task_id = 1; verdict = 'pass'; reason = 'probe: delegated review passed' }) } | ConvertTo-Json -Depth 5)
    $archR = New-Archive 'qa-na8' $OneTask
    $planR = Write-TestPlan (Join-Path $Work 'qa-na8-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archR + '/task.json'), '-PlanFile', $planR, '-ReviewFile', $rfPath, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true -and [string]$r.json.data.review.reviewer -eq 'auditor-delegated') 'QA-N7 promulgate consumes a delegated ReviewFile (consumer contract unchanged)' ($r.raw)

    $rfLegacy = Join-Path $Work 'qa-na8-review-legacy.json'
    Write-Utf8NoBom $rfLegacy (@{ reviewed_at = '2026-10-08T09:00:00Z'; reviewer = 'planner'; verdicts = @(@{ task_id = 1; verdict = 'pass'; reason = 'probe: legacy planner signature stays readable' }) } | ConvertTo-Json -Depth 5)
    $archR2 = New-Archive 'qa-na9' $OneTask
    $planR2 = Write-TestPlan (Join-Path $Work 'qa-na9-plan.json') @(@{ id = 'S1'; tasks = @(1) })
    $r = Invoke-Bridge @('-Command', 'promulgate', '-TaskJson', ($archR2 + '/task.json'), '-PlanFile', $planR2, '-ReviewFile', $rfLegacy, '-ReviewMode', 'subagent', '-NoPush')
    Assert-True ($r.json.success -eq $true) 'QA-N7 legacy planner signature stays consumable (存量只读 value域)' ($r.raw)

    $bridgeSrc = Read-TextFile $BridgePs1
    Assert-True ($bridgeSrc.Contains("`$script:DesignReviewReviewers = @('auditor-delegated', 'auditor')")) 'QA-N7 engine value domain is the widened closed set' ('')
    Assert-True ($bridgeSrc.Contains($TLegacyRO)) 'QA-N7 planner documented as read-only legacy (not produced anymore)' ('')

    # ================= QA-N8 (AC-5): deployment criterion as a config item =================
    $presetDirs = @(Get-ChildItem -Path (Join-Path $RepoRoot 'dsh/presets') -Directory | ForEach-Object { $_.Name })
    Assert-True ($presetDirs.Count -eq 8 -and ($presetDirs -notcontains 'rdd-auditor')) ("QA-N8 default preset family is 8 with no rdd-auditor ({0} dirs)" -f $presetDirs.Count) ($presetDirs -join ',')
    Assert-True ($presetDirs -contains 'rdd-planner' -and $presetDirs -contains 'rdd-qa') 'QA-N8 the flow presets survive the collapse' ($presetDirs -join ',')

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $chk1 = (node (Join-Path $RepoRoot 'scripts/build-dsh-presets.mjs') --check 2>&1 | Out-String)
        $chk2 = (node (Join-Path $RepoRoot 'scripts/build-skills-package.mjs') --check 2>&1 | Out-String)
    } finally { $ErrorActionPreference = $prevEap }
    Assert-True ($chk1 -match 'CHECK OK') 'QA-N8 build-dsh-presets --check clean on the 8-group default' ($chk1)
    Assert-True ($chk2 -match 'CHECK OK') 'QA-N8 build-skills-package --check clean' ($chk2)

    $presetBuilder = Read-TextFile (Join-Path $RepoRoot 'scripts/build-dsh-presets.mjs')
    Assert-True ($presetBuilder.Contains('--with-auditor')) 'QA-N8 strong form is rebuildable on demand (--with-auditor)' ('')
    $manifest = Read-TextFile (Join-Path $RepoRoot 'rdd-engine/references/capability-manifest.md')
    Assert-True ($manifest.Contains('review_mode') -and $manifest.Contains($TDeployAnchor)) 'QA-N8 manifest: deployment criterion re-anchored on the config item' ('')
    Assert-True (($bridgeSrc -match 'function Test-AuditorDeployed') -and ($bridgeSrc -match 'legacy only')) 'QA-N8 deployment probe demoted to the legacy-only path' ('')

    # ================= QA-N9 (AC-1/3): single entry + protocol-shaped input =================
    $archE = New-Archive 'qa-nae' $OneTask
    $dry = Invoke-Ps1 $StartPs1 @('-Role', 'PLANNER', '-TaskJson', ($archE + '/task.json'), '-DryRun')
    Assert-True ($dry.raw.Contains('review-input-template.md') -and $dry.raw.Contains($TSubagentS)) 'QA-N9 PLANNER pointer dispatches the review subagent with the mechanical template' ($dry.raw)
    Assert-True (-not $dry.raw.Contains($TTwoStage) -and -not $dry.raw.Contains($TStepMark) -and -not $dry.raw.Contains('start-role.cmd -Role AUDITOR')) 'QA-N9 two-hop takeover wording is gone from the PLANNER pointer' ($dry.raw)

    $startSrc = Read-TextFile $StartPs1
    Assert-True ($startSrc.Contains('review-input-template.md') -and $startSrc.Contains('"AUDITOR"')) 'QA-N9 start-role keeps AUDITOR as a manual strong-form entry only' ('')

    $tmpl = Read-TextFile (Join-Path $RefsDir 'review-input-template.md')
    Assert-True ($null -ne $tmpl) 'QA-N9 protocol input template ships with the engine' ('')
    foreach ($needle in @($TBan1, $TBan2, $TBan3, $TBan4, $TBan5)) {
        Assert-True ($tmpl.Contains($needle)) ("QA-N9 template prohibition present: {0}" -f $needle) ('')
    }
    Assert-True ($tmpl.Contains('auditor-delegated') -and $tmpl.Contains('TEMPLATE_REF') -and $tmpl.Contains($TemplateRel)) 'QA-N9 template constant table is the single source' ('')
    Assert-True ($tmpl.Contains('{{DOC_LIST}}') -and $tmpl.Contains('{{CRITERIA_REF}}') -and $tmpl.Contains('{{STAGE_ID}}')) 'QA-N9 template exposes only fillable mechanical slots' ('')

    $guide = Read-TextFile (Join-Path $RefsDir 'planner-guide.md')
    Assert-True ($guide.Contains($TInnate) -and $guide.Contains('auditor-delegated')) 'QA-N9 planner-guide carries the innate-review contract' ('')
    $transit = Read-TextFile (Join-Path $RefsDir 'transition-guide.md')
    Assert-True ($transit.Contains($TOneEntry) -and (-not $transit.Contains($TTwoStageTk))) 'QA-N9 transition-guide takeover is single-entry' ('')
    $scen = Read-TextFile (Join-Path $RefsDir 'planner-scenarios.md')
    Assert-True ($scen.Contains('auditor-delegated') -and $scen.Contains('design-review -Action submit')) 'QA-N9 scenarios document the contract submit channel' ('')

    # ================= summary =================
    $failed = @($Results | Where-Object { -not $_.ok })
    Write-Output ''
    if ($failed.Count -eq 0) {
        Write-Output ("auditor-subagent QA probe: {0} assertions, 0 failed" -f $Results.Count)
    }
    else {
        Write-Output ("auditor-subagent QA probe: {0} assertions, {1} failed" -f $Results.Count, $failed.Count)
        $exitCode = 1
    }
    Write-Output ("work dir: {0}" -f $Work)
}
catch {
    Write-Output ("PROBE ABORTED: {0}" -f $_.Exception.Message)
    Write-Output ($_.ScriptStackTrace)
    $exitCode = 3
}
finally {
    Pop-Location
}
exit $exitCode

# delivery-bridge.ps1 — goal-tree × rdd-flow delivery orchestration CLI (Planner tooling)
#
# Black-box bridge between the two engines: it orchestrates EXCLUSIVELY through the
# public CLIs of goal-tree.cmd / goal-tree-leaf.cmd / rdd-flow.cmd / start-role.cmd
# as subprocesses — it never dot-sources engine internals. Core semantics of either
# side stay untouched (rdd-flow.ps1 has zero bridge awareness; goal-tree only gained
# the generic depends_on/ref schema).
#
# Commands:
#   promulgate  publish an archive's task set as a goal-tree run: goal root
#               (type=goal, the original requirement as the unclaimable conclude
#               anchor) -> requirement chain-head nodes (ref-bound to their
#               requirement docs) -> stage chains; then AUTO-PUSH every node
#               with no unsatisfied dependency (no manual dispatch, no gate).
#               Mandatory -PlanFile (long-task-planning hard gate PLAN_MISSING):
#               the staged plan (stage goals/milestones + task_ids + parallel
#               batches + per-stage acceptance point + risks) is validated
#               against the DAG and injected as bridge.json's plan section
#               (PLAN_FILE_INVALID / PLAN_ORDER_INVALID / PLAN_BATCH_INVALID
#               reject contradictions; the DAG stays the dependency authority).
#               Optional -ReviewFile (requirement review gate, planner-guide
#               hard constraint 6): merged/rejected tasks graft no node,
#               depends_on_override wholesale-replaces regex inference, merged
#               deps redirect to the absorber, deps dangling on a rejected task
#               hard-fail REVIEW_EXCLUDED_DEP; absent -> byte-identical legacy
#               behavior. Audit: bridge.json review section + report/review.md.
#               Optional -NoPush: suppress auto-push entirely (test / incident
#               isolation — no role sessions started, ever). The isolation is a
#               PERSISTED run-level attribute (bridge.json no_push=true) that
#               every later auto-dispatch trigger (status touch / reclaim /
#               settle / rollback) consumes and stays inert on; the promulgate
#               response reports it as trigger='promulgate (-NoPush)'. Manual
#               dispatch (explicit human action) remains the designated override.
#   dispatch    manual single-node start-role push (exception handling /
#               pointer-class re-push; the normal flow is auto-push)
#   claim       composite claim: read-only prechecks -> tree leaf claim -> rdd-flow claim
#   reclaim     composite recovery (dead-claim / rejected-delivery); alive sessions
#               are mechanically unreclaimable (RECLAIM_TARGET_ALIVE) — liveness via
#               the dsh agents registry, time-threshold fallback for unknown
#   settle      the ONLY forward task.json transition channel: three evidence
#               checks -> tree settle -> flow set-route (phase-internal narrowing
#               keeps the phase; the phase's LAST settle switches atomically via
#               -Phase) or complete -> convergence graft of the next phase heads
#               -> dependency-driven auto-push of newly unlocked nodes; null-phase
#               (legacy archive) tasks keep the byte-identical legacy path
#               (set-route without -Phase; only phase-ambiguous hops — QA — pass
#               -Phase VERIFY explicitly)
#   rollback    cross-phase reverse transition (phase-model explicit target):
#               prune the reported-but-unqualified node (ledger keeps the
#               audit) -> sibling-graft ONE rebuilt node per -To role at the
#               target phase's chain-head layer -> rdd-flow set-route -To/-Phase
#               -> auto re-push; with settle (forward) and reclaim (same-stage
#               redo) this closes the three transition channels inside the bridge
#   status      joined view: tree census + task stages + dep blocking + dead claims +
#               pending_sync repair + push ledger + session liveness + catch-up push
#   resume      breakpoint view for a fresh Planner session
#   conclude    final report after all tasks reach terminal state (+ delivery-annex.md),
#               anchored on the goal root (root semantics: all direct children terminal).
#               Review reject_return tasks pending at PM are exempt from the gate —
#               the annex renders them as partial achievement, never as complete
#   lease       advisory Planner session lease (planner-lease.json, stale 30 min)
#   register-session  record an off-tree direct-handoff dsh session into the
#               run's sessions.json roster (planner-session-roster): after a
#               direct start-role dispatch the planner registers the printed
#               sessionId + label so the session stays traceable
#   decide      pure-auto-mode decision ledger append (planner-auto-mode):
#               -Kind auto (grading-table answer for a low-risk checkpoint) /
#               resolution (user verdict closing an open escalation) /
#               overturn (in-session redo note over an existing decision).
#               Requires bridge.json auto_mode.enabled + this stage's claimed
#               node (overturn additionally tolerates reported); append happens
#               inside the run .lock with read-back finish
#   escalate    pure-auto-mode escalation append: a checkpoint the grading
#               table routes to humans (prohibition-class / unmatched / worker
#               judgment) lands as an open entry; dsh watcher delivers it to
#               the Planner inbox, CLI/Plus see it via status/resume
#   replan      long-task-planning rolling correction (the ONLY correction
#               channel): -PlanFile <revised plan> -Reason <deviation> ->
#               DAG-fit validation -> structured changes[] diff -> plan-log
#               `revision` event (append-only, no snapshots) -> bridge plan
#               section replaced (revision+1) -> unlock set recomputed
#               (auto-push tail). NODE_BLOCKED_BY_GATE is released by moving
#               the stalled task's stage here — never by a Force bypass;
#               registered-but-unabsorbed mid-run derivations are WHITELISTED
#               from the delivered-coverage check (opposite direction from the
#               push/claim gate, by design) and marked absorbed once covered
#   derive      mid-run scope-gap derivation (planner-midrun-derive): the
#               planner adjudicates rollback/reclaim both unfit (additions
#               only, never rework of existing docs) -> -Action propose
#               (-Title -Rationale [-DependsOn] [-Owners]) registers the
#               proposal + a derive_proposal ledger entry and returns the
#               standard user-facing text -> USER CONFIRMATION HARD GATE
#               (-Action confirm -DerivationId <DRV<n>> -UserVerdict "<the
#               user's ruling verbatim>" — no record, no execution:
#               DERIVE_CONFIRMATION_MISSING) -> ruling ledger entry -> budget
#               pre-check (DERIVE_BUDGET_EXCEEDED, graft never attempted on
#               insufficient budget) -> graft ONE PM node under the goal root
#               + auto-push (PM drafts the new requirement doc AND augments
#               overview's '## 整体验收判据' — live-read anchor, so derived
#               criteria ride the acceptance gate naturally) -> its settle
#               registers the task under bridge control (add-task -BridgeRun
#               代写 + bridge.tasks mapping + DESIGN chain heads pre-grafted
#               under the PM node, held by the stage gate until replan
#               absorbs them). -Action withdraw = refusal on record, zero
#               side effects (a grafted-but-unsettled PM node is pruned).
#               Derivation bookkeeping: bridge.json derivations[] state
#               machine + plan-log deviation/scope_derived + conclude-time
#               DERIVATION_PENDING gate + annex derivation section
#   design-review pure-contract design-review intake (auditor-subagent-review;
#               ONLY for runs promulgated with -ReviewMode = the new chain):
#               -Action submit ingests the review product of a planner-dispatched
#               independent-context review subagent (mechanical input template
#               rdd-engine/references/review-input-template.md) for one stage —
#               the SAME contract core the node settle gate runs (Test-
#               DesignReviewFileCore: coverage / verdict-findings consistency /
#               finding four fields / membership; violations = the
#               SETTLE_EVIDENCE_REJECTED problem list, fix and resubmit) + the
#               engine-derived overall verdict (never trusts a declared value)
#               + review-ledger bookkeeping + the passed|failed transition
#               (fail fires the existing fail wave; no node to reclaim in this
#               chain). -Action status is the read-only dispatch face: per-stage
#               review state + the mechanical input list (docs / criteria ref /
#               report drop / template ref) the subagent prompt is filled from.
#               Legacy runs (bridge.json WITHOUT review_mode) keep the node
#               chain byte-identical and are adjudicated via settle instead.
#
# Run artifacts (inside the goal-tree run dir, gitignored):
#   bridge.json           authoritative node<->TaskId mapping (v2: + goal_root anchor
#                         + per-node pushes ledger; v1 rejected BRIDGE_FORMAT_UNSUPPORTED)
#                         + auto_mode snapshot (ONLY for -AutoMode promulgations:
#                         enabled + immutable risk-policy table; absent otherwise)
#                         + no_push isolation flag (ONLY for -NoPush promulgations:
#                         true = every auto-dispatch trigger stays inert)
#   planner-lease.json    advisory session lease
#   sessions.json         run session roster (planner-session-roster): every dsh
#                         session this run derived — planner body (promulgate/
#                         resume self-registration), bridge dispatches (push
#                         write-back), registered direct handoffs; exposed via
#                         the status command's sessions field
#   report/review.md      requirement review conclusions (only for -ReviewFile
#                         promulgations): per-task verdict table, the persistent
#                         human-readable carrier presented to the user; the
#                         machine-readable copy rides bridge.json's review section
#   report/delivery-annex.md  per-task terminal states + rdd-flow check result
#                         + root-goal achievement state
#   decisions.jsonl       ARCHIVE-level unified decision ledger (planner-
#                         midrun-derive user ruling: ONE ledger per archive at
#                         .rdd/changes/archive/<name>/decisions.jsonl — long-
#                         term analysis asset): four-element entries
#                         (background / options[] / decision / reason +
#                         decider) for kinds derive_proposal / checkpoint /
#                         ruling, plus the AutoMode worker kinds auto /
#                         escalation / resolution / overturn (field-missing
#                         compatible — the old kinds keep their payloads);
#                         append-only with archive-level lock + read-back
#                         finish; open-escalation view derived by ref_entry
#                         join — the ledger is never rewritten
#   plan-log.jsonl        append-only long-task plan event ledger (long-task-
#                         planning, the cross-session progress/risk/deviation/
#                         revision carrier): P<n> entries, appended inside the
#                         run .lock with read-back finish, bad lines quarantined
#                         to plan-log.jsonl.corrupt (ledger paradigm)
#                         + bridge.json `plan` section (machine-readable current
#                         plan state: stages / batches / acceptance_point status;
#                         plan = the -PlanFile carrier is validated and injected
#                         at promulgate, rolled forward by replan only)
#
# Hard constraint: "不合格交付不得流转" — settle enforces the four evidence checks
# (verdict=done / citations non-empty and real paths / extras.verification non-empty
# / role handoff gate — DEV deliveries carry extras.quality_scan, the code-metrics
# credential; dev-quality-prescan-gate) before any task.json transition. Manual
# rdd-flow routing writes under a bridged run are forbidden by protocol (see
# references/planner-guide.md).

[CmdletBinding()]
param(
    [ValidateSet("promulgate", "dispatch", "claim", "reclaim", "rollback", "settle", "status", "resume", "conclude", "lease", "register-session", "decide", "escalate", "replan", "conflict", "derive", "design-review")]
    [string]$Command = "status",

    [string]$RunId,

    # promulgate / replan
    [string]$TaskJson,
    [string]$PlanFile,            # staged plan (long-task-planning): the plan
                                   # carrier consumed at promulgate (mandatory —
                                   # PLAN_MISSING hard gate) and replaced by the
                                   # replan rolling-correction channel (-Reason
                                   # records the deviation it answers)
    [string]$ReviewFile,          # optional requirement-review verdicts (planner
                                   # session product; planner-guide hard constraint 6)
    [ValidateSet("subagent", "session")]
    [string]$ReviewMode,          # auditor-subagent-review: design-review
                                   # production form for THIS run, persisted as
                                   # bridge.json `review_mode` (subagent =
                                   # planner-dispatched independent-context
                                   # review subagent, the default form | session
                                   # = strong form, an independent AUDITOR
                                   # session produced by start-role -Role
                                   # AUDITOR). No `off` value: in the new chain
                                   # review is mandatory. OMIT THE FLAG =
                                   # 缺键 legacy chain (byte-identical node
                                   # chain: dual probe / review nodes / +K
                                   # budget / AUDITOR push) — the compat path
                                   # for already-promulgated runs.
    [string]$ConventionsFile,     # 架构/风格约定载体 (parallel-coordination): review
                                   # 步产出的约定文档;DESIGN 并行链头 ≥2 时必填
                                   # (CONVENTIONS_MISSING,零残留),DESIGN 链头 node.task
                                   # 注入「架构约定:<path>」
    [switch]$AutoMode,            # pure-auto-mode opt-in (planner-auto-mode): snapshot
                                   # the risk-grading table into bridge.json auto_mode;
                                   # default off = byte-identical legacy behavior
    [string]$RiskPolicy,          # optional full-table override for -AutoMode (JSON
                                   # file); R1 constitutional hard floor is force-merged
                                   # back no matter what the file says
    [switch]$NoPush,              # promulgate isolation: build the run but suppress
                                   # auto-push for its WHOLE lifetime — persisted as
                                   # bridge.json no_push=true and consumed by every
                                   # auto-dispatch trigger (engine test suite / incident
                                   # drills — no real role sessions started; default
                                   # off = byte-identical behavior)
    [int]$MaxRounds = 12,
    [int]$NodeWidth = 0,          # 0 = auto (>= task count, floor 4)
    [int]$MaxNodes = 0,           # 0 = auto (task count * 5 + 6)
    [int]$MaxDerivations = 0,     # 0 = default 3 (planner-midrun-derive): the
                                   # per-run derivation-abuse ceiling recorded as
                                   # bridge.json max_derivation; exceeding it is a
                                   # WARNING (DERIVATION_LIMIT_WARNING), never a
                                   # hard reject (design decision #8)
    [string]$CreatedBy = "planner",

    # dispatch / claim / reclaim / settle / decide / escalate
    [string]$NodeId,
    [string]$Role,                # stage role (CTO/UX/DEV/QA) for claim; inferred from node for others
    [string]$Session,             # Planner lease holder label

    # design-review (auditor-subagent-review): the plan stage id (S<k>) whose
    # review product is submitted / whose review state is queried
    [string]$Stage,

    # decide / escalate (planner-auto-mode checkpoint payload + unified ledger)
    [ValidateSet("auto", "resolution", "overturn", "checkpoint")]
    [string]$Kind,                # decide entry kind (escalate always writes
                                   # kind=escalation; checkpoint = the archive-
                                   # scoped checkpoint ledger form, see -Archive)
    [string]$Checkpoint,          # checkpoint name (e.g. "技术选型" / "命名")
    [string]$Decision,            # the verdict text (for escalate: the question awaiting the user)
    [string]$Inputs,              # decision inputs (what was considered)
    [string]$Basis,               # rationale / recommendation source
    [string]$Risk,                # risk label (low / high / free text)
    [string]$RuleId,              # grading-table rule id (required for -Kind auto)
    [string]$RefEntry,            # referenced entry_id (required for resolution / overturn)
    [string]$Background,          # decide -Kind checkpoint: decision background
                                   # (four-element ledger schema)
    [string]$Options,             # decide -Kind checkpoint: candidate options,
                                   # '|' separated -> options[] (four-element
                                   # ledger schema)

    # derive (planner-midrun-derive): mid-run scope-gap derivation channel
    # (-Action propose|confirm|withdraw selects the sub-action)
    [string]$Title,               # derive propose: the new requirement's title
    [string]$Rationale,           # derive propose: the goal-gap rationale
    [string]$UserVerdict,         # derive confirm: the user's ruling VERBATIM —
                                   # the confirmation record itself (hard gate:
                                   # missing -> DERIVE_CONFIRMATION_MISSING)
    [string]$DerivationId,        # derive confirm/withdraw target (DRV<n>)
    [string]$DependsOn,           # derive propose: existing task ids (comma
                                   # separated) the derived requirement depends on
    [string]$Owners,              # derive propose: derived chain-head role set
                                   # ('+' separated, subset of CTO+UX+QA;
                                   # default = full chain CTO+UX+QA, decision #10)
    [string]$Archive,             # decide -Kind checkpoint: archive directory
                                   # (relative resolves against repo root) — the
                                   # unified decision ledger is archive-scoped

    # register-session (planner-session-roster): off-tree direct-handoff
    # registration into the run's sessions.json roster — the planner records
    # the dsh session start-role just created ([直交] <标签>·<角色>)
    [string]$SessionId,
    [string]$Label,

    # settle
    [string]$Note,

    # reclaim / dispatch (inplace-redo-session-reuse): disable live-session
    # reuse — reclaim's rejected-delivery branch then always takes the legacy
    # prune + graft + repush path even when the original claim session is
    # alive, and dispatch/auto-push always session.create. Escape hatch for
    # stale-context worries; default off = byte-identical behavior whenever no
    # live session exists anyway (regression anchor).
    [switch]$NoReuse,

    # reclaim (rejected-delivery, in-place path): planner-supplied failure-list
    # pointer that supplements the mechanically retrieved rejection sources
    # (four-check problems + the failing report's full_report/extras) inside
    # the redo pointer and the ledger redo entry.
    [string]$FailureRef,

    # rollback (planner-stage-rollback / phase-model explicit target)
    [string]$Reason,              # rollback audit trail (required): lands in the
                                   # prune reason AND the rebuilt node's redo context
    [string]$To,                  # rollback target role set ("CTO+UX") — required with -Phase
    [string]$Phase,               # rollback target phase (REQ/DESIGN/IMPL/VERIFY) — required

    # conclude
    [string]$Summary,

    # lease
    [switch]$Acquire,
    [switch]$Release,
    [switch]$Takeover,

    # dispatch
    [switch]$DryRun,

    # conflict (parallel-coordination 并行协作冲突治理):动作仅 open|resolve;
    # 上报/挂起为条目状态属性(经 open -ConflictId 更新 -ConflictStatus);
    # derive (planner-midrun-derive) 复用同一参数承载 propose|confirm|withdraw,
    # design-review (auditor-subagent-review) 复用同一参数承载 submit|status
    # (各命令各自守卫自己的动作集,互不感知)
    [ValidateSet("open", "resolve", "propose", "confirm", "withdraw", "submit", "status")]
    [string]$Action,              # conflict / derive / design-review action
    [string]$ConflictId,          # registry id C<n> (resolve / state-attribute update)
    [ValidateSet("design", "file")]
    [string]$ConflictKind,        # conflict kind for a new entry (design | file)
    [string]$Nodes,               # comma-separated node ids (new entry)
    [string]$Files,               # comma-separated repo-root-relative paths (kind=file)
    [string]$Ruling,              # 调和一致结论 / 用户裁决 (resolve)
    [string]$Serialize,           # 串行化早者节点 (resolve: 晚者 depends_on 早者)
    [ValidateSet("open", "escalated", "suspended")]
    [string]$ConflictStatus,      # 状态属性 (open→escalated|suspended)
    [string]$Escalation,          # 呈用户裁决的问题 (escalated 上报记录)
    [string]$DetectedBy,          # change-map-scan | planner (default planner)

    [int]$LeaseStaleMinutes = 30,
    [int]$DeadClaimMinutes = 60
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# Resolve-RepoRoot - project-root location chain (git-optional; protocol source:
# rdd-engine/references/engine-location.md, "Project-root location chain"). Fixed order:
#   1. $env:RDD_PROJECT_ROOT          explicit override; invalid path -> fail-loud
#   2. git rev-parse --show-toplevel  most accurate: worktree / submodule / GIT_DIR
#   3. nearest .git ancestor          filesystem twin of (2) when git is missing or
#                                     refuses the repo (dubious ownership)
#   4. nearest .rdd/install.json ancestor  anchors non-git projects back onto their
#                                     coderdd-init root when run from a subdirectory
#   5. cwd                            final fallback - same rule as the dsh plugin's
#                                     findRepoRoot (one mental model across the ecosystem)
# (2)+(3) keep every existing git project byte-identical (regression anchor);
# (4)+(5) only rescue trees where git says "not a repository".
function Resolve-RepoRoot {
    $envRoot = [string]$env:RDD_PROJECT_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        if (Test-Path -LiteralPath $envRoot -PathType Container) { return $envRoot }
        throw "RDD_PROJECT_ROOT does not exist: $envRoot"
    }
    $t = $null
    # 2>$null must stay inside try/catch: under PS5.1, redirected native stderr
    # plus $ErrorActionPreference=Stop raises NativeCommandError.
    try { $t = git rev-parse --show-toplevel 2>$null } catch { }
    if ($t) { return $t.Trim() }
    $start = (Get-Location).ProviderPath
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".rdd/install.json")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $start
}
$repoRoot = Resolve-RepoRoot

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:GoalTreesRoot = Join-Path $repoRoot ".rdd/goal-trees"
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Stage model: a task's lifecycle crosses roles; each (task, stage) is one tree node.
# Chain parent: cto -> dev -> qa are parent/child; ux grafts as its own chain head
# when the task starts at UX (ux -> dev -> qa).
# LEGACY (phase-model.md): StageOrder/StageNext now serve ONLY the conservative
# degrade path for null-phase tasks (pre-phase archives). Phase-aware tasks route
# through PhaseRoles/PhaseNext below.
$script:StageOrder = @("CTO", "UX", "DEV", "QA")
$script:StageNext = @{ "CTO" = "DEV"; "UX" = "DEV"; "DEV" = "QA"; "QA" = $null }

# Phase routing model (references/phase-model.md — single authority). Phases are
# totally ordered; roles inside a phase form a whitelist (parallel). A phase is
# complete when every currentOwner has settled; only then does the task advance
# (convergence graft). ⚠ synced with rdd-flow.ps1's same-name constants — changes
# go to BOTH.
$script:PhaseRoles = @{
    "REQ"    = @("PM")
    "DESIGN" = @("CTO", "UX", "QA")   # QA = test-case design (test-first)
    "IMPL"   = @("DEV")
    "VERIFY" = @("QA")                # QA = acceptance execution
}
$script:PhaseNext = @{ "REQ" = "DESIGN"; "DESIGN" = "IMPL"; "IMPL" = "VERIFY"; "VERIFY" = $null }
$script:PhaseOrder = @("REQ", "DESIGN", "IMPL", "VERIFY")
# every bridgeable role, in chain order (PM heads a REQ-phase chain; rollback -To PM
# grafts a PM head, so claim/push/display must all accept PM)
$script:RoleOrder = @("PM", "CTO", "UX", "DEV", "QA")

# Worker roles a direct handoff can target (planner-session-roster
# register-session validation): everything start-role accepts except PLANNER —
# the planner body self-registers via promulgate/resume, never manually.
$script:WorkerRoles = @("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE")

# === Generic helpers ===

function ConvertTo-PortableJson {
    param($Object, [int]$Depth = 6)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-ErrorResult {
    param(
        [string]$Code,
        [string]$Message,
        [int]$ExitCode = 1
    )
    ConvertTo-PortableJson @{
        success = $false
        error   = @{ code = $Code; message = $Message }
    } -Depth 3
    exit $ExitCode
}

function Get-UtcNowIso {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Convert-PSObjectToHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = Convert-PSObjectToHashtable $p.Value }
        return $h
    }
    if ($Value -is [array]) {
        $arr = @()
        foreach ($v in $Value) { $arr += ,(Convert-PSObjectToHashtable $v) }
        # comma-wrap: a bare `return @()` unrolls to AutomationNull, which
        # ConvertTo-Json renders as {} — that corrupted empty dep_task_ids on
        # every bridge rewrite and later crashed int casts on read.
        return ,$arr
    }
    return $Value
}

function Convert-ToSafeArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Test-PropPresent {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Name) }
    return ($null -ne $Obj.PSObject.Properties[$Name])
}

# === Subprocess orchestration (public CLIs only) ===

function Invoke-EngineCli {
    # run one engine CLI, capture stdout + exit code, parse JSON when possible.
    # EAP is relaxed around the call: PS 5.1 turns native stderr lines into
    # NativeCommandError records under ErrorActionPreference=Stop.
    param([string]$Script, [string[]]$ArgList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = $null
    $exitCode = 0
    try {
        $output = & $Script @ArgList 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    $text = ($output | Out-String).Trim()
    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
    return @{ exit = $exitCode; text = $text; json = $json }
}

function Invoke-GoalTree     { param([string[]]$A) Invoke-EngineCli (Join-Path $script:ScriptDir "goal-tree.cmd") $A }
function Invoke-GoalTreeLeaf { param([string[]]$A) Invoke-EngineCli (Join-Path $script:ScriptDir "goal-tree-leaf.cmd") $A }
function Invoke-RddFlow      { param([string[]]$A) Invoke-EngineCli (Join-Path $script:ScriptDir "rdd-flow.cmd") $A }
function Invoke-StartRole    { param([string[]]$A) Invoke-EngineCli (Join-Path $script:ScriptDir "start-role.cmd") $A }

# === Bridge state (run dir sidecars) ===

function Get-BridgeRunDir {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { Write-ErrorResult "MISSING_RUN_ID" "-RunId is required" 1 }
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Write-ErrorResult "INVALID_RUN_ID" "RunId must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ : $Id" 1 }
    $dir = Join-Path $script:GoalTreesRoot $Id
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-ErrorResult "RUN_NOT_FOUND" "Goal tree run not found: .rdd/goal-trees/$Id (promulgate first)" 2
    }
    return $dir
}

function Get-BridgePath { param([string]$RunDir); Join-Path $RunDir "bridge.json" }
function Get-LeasePath  { param([string]$RunDir); Join-Path $RunDir "planner-lease.json" }
function Get-AnnexPath  { param([string]$RunDir); Join-Path (Join-Path $RunDir "report") "delivery-annex.md" }

function Read-Bridge {
    # returns $null when the run is not promulgated (plain goal-tree run).
    # The bridge is normalized to DEEP HASHTABLES on read: task/node keys are
    # numeric strings ("1"), which PS 5.1's Add-Member -NotePropertyName cannot
    # carry (integer-looking strings convert to PSMemberTypes) — hashtables take
    # arbitrary keys and ConvertTo-Json still serializes them as JSON objects.
    # Format gate (goal-tree-goal-root, decision 7 zero-compat): only v2 (goal
    # root anchor + pushes ledger) is readable; v1 is rejected with an explicit
    # disposition (bridge runs are gitignored and short-lived — re-promulgate).
    param([string]$RunDir)
    $p = Get-BridgePath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try {
        $obj = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "BRIDGE_CORRUPT" "bridge.json failed to parse: $($_.Exception.Message)" 3
    }
    $h = Convert-PSObjectToHashtable $obj
    $v = 1
    if ($h.Contains('format_version') -and $null -ne $h['format_version']) { $v = [int]$h['format_version'] }
    if ($v -ne 2) {
        Write-ErrorResult "BRIDGE_FORMAT_UNSUPPORTED" "bridge.json format_version=$v is not supported (this bridge expects v2: goal_root anchor + pushes ledger). Disposition: re-promulgate the archive into a fresh run (-Command promulgate -TaskJson ...), or settle the legacy run's remaining work manually per planner-guide; run dirs are gitignored and short-lived." 3
    }
    if (-not $h.Contains('tasks') -or $null -eq $h['tasks']) { $h['tasks'] = @{} }
    if (-not $h.Contains('nodes') -or $null -eq $h['nodes']) { $h['nodes'] = @{} }
    if (-not $h.Contains('pending_sync') -or $null -eq $h['pending_sync'] -or $h['pending_sync'] -is [System.Collections.IDictionary]) { $h['pending_sync'] = @() }
    if (-not $h.Contains('pushes') -or $null -eq $h['pushes']) { $h['pushes'] = @{} }
    # read-side normalization: bridges written before the comma-return fix may
    # carry empty array slots as {} / null (AutomationNull serialization) —
    # repair the known array fields so downstream int casts cannot crash.
    foreach ($tk in @($h['tasks'].Keys)) {
        $entry = $h['tasks'][$tk]
        if ($null -eq $entry -or -not ($entry -is [System.Collections.IDictionary])) { continue }
        foreach ($arrKey in @('dep_task_ids', 'nodes')) {
            $raw = $entry[$arrKey]
            if ($null -eq $raw -or $raw -is [System.Collections.IDictionary]) { $entry[$arrKey] = @() }
        }
    }
    return $h
}

function Require-Bridge {
    param([string]$RunDir)
    $b = Read-Bridge $RunDir
    if ($null -eq $b) {
        Write-ErrorResult "NOT_A_BRIDGE_RUN" "No bridge.json under run $RunId — this run was not promulgated by delivery-bridge" 2
    }
    return $b
}

function Write-BridgeFile {
    # pre-write .bak + post-write read-back (same crash-ordering contract as tree.json)
    param([string]$RunDir, $Bridge)
    $p = Get-BridgePath $RunDir
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        Copy-Item -LiteralPath $p -Destination "$p.bak" -Force
    }
    [System.IO.File]::WriteAllText($p, (ConvertTo-Json $Bridge -Depth 10), $script:Utf8NoBom)
    try {
        $null = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        if (Test-Path -LiteralPath "$p.bak" -PathType Leaf) {
            Copy-Item -LiteralPath "$p.bak" -Destination $p -Force
        }
        Write-ErrorResult "BRIDGE_WRITE_READBACK_FAILED" "bridge.json read-back failed after write; previous snapshot restored" 3
    }
}

# === Pure auto mode (planner-auto-mode: worker-side checkpoint auto-decision) ===
#
# Bridge-run workers (CTO's four checkpoints being the canonical case) wait for
# in-session user confirmation; unattended runs would hang forever. Pure auto
# mode answers LOW-RISK checkpoints from an immutable risk-grading snapshot
# (decide -Kind auto, fully ledgered) and routes HIGH-RISK ones to humans
# (escalate -> open entry -> dsh watcher delivers to the Planner inbox /
# CLI-Plus degrade to status+resume visibility). Scope is EXACTLY worker-side
# in-session checkpoints: orchestration verdicts (review gate / settle
# adjudication / overturn adjudication) are never automated.
# Default OFF: no -AutoMode => no auto_mode key anywhere (byte-identical
# legacy behavior, same gating discipline as -ReviewFile).

# Default risk-grading table (first match wins, top-down). Conservative by
# design: substantive forks (R2-R4) go to humans; only mechanical/local calls
# (R5-R7, P2/P3 risk trades) auto-answer. R1 is the constitutional hard floor
# (safety / cost / irreversible / git) and CANNOT be removed or relaxed by a
# -RiskPolicy override — the snapshot builder force-merges it back in.
$script:AutoModeDefaultRules = @(
    @{ id = "R1"; match = "宪法禁令类：安全 / 成本 / 不可逆操作 / git 操作"; action = "manual"; note = "硬底：覆盖不可移除" }
    @{ id = "R2"; match = "新框架 / 中间件 / 外部依赖引入";              action = "manual"; note = "" }
    @{ id = "R3"; match = "协议语义变更 / 跨模块新机制";                 action = "manual"; note = "" }
    @{ id = "R4"; match = "技术选型实质分叉（多可行方案取舍）";          action = "manual"; note = "选型错沿链放大，默认保守" }
    @{ id = "R5"; match = "单一可行方案 / 沿用现状范式";                 action = "auto";   note = "" }
    @{ id = "R6"; match = "模块归属（放哪个模块/包）";                   action = "auto";   note = "" }
    @{ id = "R7"; match = "命名 / 文件清单 / 配置项";                    action = "auto";   note = "" }
    @{ id = "R8"; match = "风险取舍：含 P1 → 人工；仅 P2/P3 → 自动";     action = "auto";   note = "按风险级别二分" }
    @{ id = "R9"; match = "回退 / 推翻既有决策";                          action = "manual"; note = "" }
)

$script:BridgeLockStream = $null
$script:BridgeLockPath = $null

function Enter-BridgeRunLock {
    # Mirror of goal-tree.ps1's Enter-RunLock (same .lock file, same semantics:
    # CreateNew+FileShare::None OS mutex, stale takeover at 60s, loud timeout).
    # Duplicated on purpose — the bridge orchestrates ONLY through public CLIs
    # and never dot-sources engine internals (see the roster title precedent
    # above; changes must be synced on both sides).
    param([string]$RunDir, [int]$TimeoutSec = 10, [int]$StaleSec = 60)
    $script:BridgeLockPath = Join-Path $RunDir ".lock"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stolen = $false
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($script:BridgeLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "cmd=$Command pid=$PID at=$(Get-Date -Format s)"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            $script:BridgeLockStream = $fs
            return @{ path = $script:BridgeLockPath; stale_taken_over = $stolen }
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if (Test-Path -LiteralPath $script:BridgeLockPath -PathType Leaf) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $script:BridgeLockPath).LastWriteTime).TotalSeconds
                if ($age -gt $StaleSec) {
                    try { Remove-Item -LiteralPath $script:BridgeLockPath -Force -ErrorAction SilentlyContinue } catch {}
                    $stolen = $true
                    continue
                }
            }
            else {
                continue
            }
            if ((Get-Date) -gt $deadline) {
                Write-ErrorResult "LOCK_TIMEOUT" "Run lock held by another writer for > ${TimeoutSec}s: $script:BridgeLockPath. Back off and retry." 3
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Exit-BridgeRunLock {
    if ($null -ne $script:BridgeLockStream) {
        try { $script:BridgeLockStream.Close() } catch {}
        $script:BridgeLockStream = $null
    }
    if ($script:BridgeLockPath -and (Test-Path -LiteralPath $script:BridgeLockPath -PathType Leaf)) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:BridgeLockPath, [System.Text.Encoding]::UTF8)
            if ($raw -match "pid=$PID ") { Remove-Item -LiteralPath $script:BridgeLockPath -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

$script:ArchiveLockStream = $null
$script:ArchiveLockPath = $null

function Enter-ArchiveLock {
    # 归档级锁（统一决策账本临界区）——Enter-BridgeRunLock 的刻意镜像：同 .lock
    # 文件语义（CreateNew+FileShare::None OS 互斥、60s stale 抢占、10s 超时），
    # 锚在归档目录（<archive>/.decisions.lock）而非 run 目录——账本生命周期 =
    # 归档生命周期，跨 run 串行化。写入方 sync 纪律同 run 锁。
    param([string]$ArchivePath, [int]$TimeoutSec = 10, [int]$StaleSec = 60)
    $script:ArchiveLockPath = Join-Path $ArchivePath ".decisions.lock"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stolen = $false
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($script:ArchiveLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "cmd=$Command ledger=decisions pid=$PID at=$(Get-Date -Format s)"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            $script:ArchiveLockStream = $fs
            return @{ path = $script:ArchiveLockPath; stale_taken_over = $stolen }
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if (Test-Path -LiteralPath $script:ArchiveLockPath -PathType Leaf) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $script:ArchiveLockPath).LastWriteTime).TotalSeconds
                if ($age -gt $StaleSec) {
                    try { Remove-Item -LiteralPath $script:ArchiveLockPath -Force -ErrorAction SilentlyContinue } catch {}
                    $stolen = $true
                    continue
                }
            }
            else {
                continue
            }
            if ((Get-Date) -gt $deadline) {
                Write-ErrorResult "LOCK_TIMEOUT" "Archive decision-ledger lock held by another writer for > ${TimeoutSec}s: $script:ArchiveLockPath. Back off and retry." 3
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Exit-ArchiveLock {
    if ($null -ne $script:ArchiveLockStream) {
        try { $script:ArchiveLockStream.Close() } catch {}
        $script:ArchiveLockStream = $null
    }
    if ($script:ArchiveLockPath -and (Test-Path -LiteralPath $script:ArchiveLockPath -PathType Leaf)) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:ArchiveLockPath, [System.Text.Encoding]::UTF8)
            if ($raw -match "pid=$PID ") { Remove-Item -LiteralPath $script:ArchiveLockPath -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

function ConvertTo-PolicyRule {
    # One raw JSON rule object -> @{ id; match; action; note } (trimmed, action
    # lowercased), with the entry-level RISK_POLICY_INVALID errors: non-object
    # shape, missing id/match/action, duplicate id, action outside auto/manual.
    # $SeenIds is the caller's duplicate-id bookkeeper (hashtable, mutated in place).
    param($RawRule, $SeenIds)
    $rh = Convert-PSObjectToHashtable $RawRule
    if ($null -eq $rh -or -not ($rh -is [System.Collections.IDictionary])) {
        Write-ErrorResult "RISK_POLICY_INVALID" "each rule must be a JSON object with id/match/action" 2
    }
    foreach ($k in @('id', 'match', 'action')) {
        if (-not $rh.Contains($k) -or [string]::IsNullOrWhiteSpace([string]$rh[$k])) {
            Write-ErrorResult "RISK_POLICY_INVALID" "rule entry missing required field: $k" 2
        }
    }
    $id = ([string]$rh['id']).Trim()
    if ($SeenIds.Contains($id)) { Write-ErrorResult "RISK_POLICY_INVALID" "duplicate rule id: $id" 2 }
    $SeenIds[$id] = $true
    $action = ([string]$rh['action']).Trim().ToLowerInvariant()
    if ($action -notin @('auto', 'manual')) {
        Write-ErrorResult "RISK_POLICY_INVALID" "rule '$id' action '$action' not in auto/manual" 2
    }
    return @{ id = $id; match = ([string]$rh['match']).Trim(); action = $action; note = $(if ($rh.Contains('note')) { [string]$rh['note'] } else { "" }) }
}

function Read-RiskPolicyFile {
    # -RiskPolicy override parser/validator: a JSON object
    # { "rules": [ { "id": "R1", "match": "...", "action": "manual"|"auto", "note": "..." }, ... ] }.
    # Wholesale table replacement (empty array is invalid — the floor survives
    # only as a forced merge, a policy with nothing else to grade is a mistake).
    # Deterministic error: RISK_POLICY_INVALID (file-level here, entry-level in
    # ConvertTo-PolicyRule).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-ErrorResult "RISK_POLICY_INVALID" "RiskPolicy file not found: $Path" 2
    }
    $h = $null
    try {
        $h = Convert-PSObjectToHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch {
        Write-ErrorResult "RISK_POLICY_INVALID" "RiskPolicy failed to parse as JSON: $($_.Exception.Message)" 2
    }
    if ($null -eq $h -or -not ($h -is [System.Collections.IDictionary]) -or -not $h.Contains('rules')) {
        Write-ErrorResult "RISK_POLICY_INVALID" "RiskPolicy must be a JSON object with a rules array" 2
    }
    $raw = @(Convert-ToSafeArray $h['rules'])
    if ($raw.Count -eq 0) {
        Write-ErrorResult "RISK_POLICY_INVALID" "RiskPolicy rules must be a non-empty array (the override wholesale-replaces the default table)" 2
    }
    $rules = @()
    $seen = @{}
    foreach ($r in $raw) { $rules += (ConvertTo-PolicyRule $r $seen) }
    return @{ rules = $rules }
}

function New-AutoModeSnapshot {
    # Immutable in-run snapshot: @{ enabled = $true; policy = @{ rules = @(...) };
    # policy_source = "default" | "override" }. R1 hard floor: whatever the
    # override says, the built-in R1 (manual) survives — dropped or relaxed to
    # auto, it is (re)inserted at the head of the table.
    param([string]$RiskPolicyPath)
    $rules = @()
    $source = "default"
    if (-not [string]::IsNullOrWhiteSpace($RiskPolicyPath)) {
        $pol = Read-RiskPolicyFile $RiskPolicyPath
        $rules = @($pol.rules)
        $source = "override"
    }
    else {
        foreach ($r in $script:AutoModeDefaultRules) { $rules += @{ id = $r['id']; match = $r['match']; action = $r['action']; note = $r['note'] } }
    }
    $r1 = $script:AutoModeDefaultRules[0]
    $r1Entry = $null
    foreach ($r in $rules) { if ($r['id'] -eq "R1") { $r1Entry = $r; break } }
    if ($null -eq $r1Entry) {
        $rules = @(@{ id = $r1['id']; match = $r1['match']; action = $r1['action']; note = $r1['note'] }) + $rules
    }
    elseif ($r1Entry['action'] -ne 'manual') {
        $r1Entry['action'] = 'manual'
        if ([string]::IsNullOrWhiteSpace([string]$r1Entry['note'])) { $r1Entry['note'] = $r1['note'] }
    }
    return @{
        enabled       = $true
        policy        = @{ rules = $rules }
        policy_source = $source
    }
}

function Get-AutoModeSection {
    # $null unless this run was promulgated with -AutoMode and enabled — every
    # gated surface (claim injection / decide / escalate / status block) calls
    # this first; absence means plain legacy behavior.
    param($Bridge)
    if (-not (Test-PropPresent $Bridge 'auto_mode') -or $null -eq $Bridge['auto_mode']) { return $null }
    $am = $Bridge['auto_mode']
    if ($am -isnot [System.Collections.IDictionary]) { $am = Convert-PSObjectToHashtable $am }
    if (-not $am.Contains('enabled') -or $am['enabled'] -ne $true) { return $null }
    return $am
}

function Get-AutoModeProtocolHint {
    # The protocol guidance string injected into the claim response (the
    # report_hint precedent: plain text the worker session can follow verbatim).
    param([string]$RunIdText)
    return "pure auto mode is ENABLED on this run: at each in-session confirmation checkpoint, classify it against the injected risk policy (first match wins, top-down). Low-risk (rule action=auto): answer it yourself with 'delivery-bridge.cmd -Command decide -RunId $RunIdText -NodeId <n> -Kind auto -RuleId <rule> -Checkpoint <name> -Decision <verdict> [-Inputs ...] [-Basis ...] [-Risk ...]' — the ledgered decide counts as the confirmation gate. Prohibition-class (R1 hard floor: safety/cost/irreversible/git) or manual-graded or unsure: 'delivery-bridge.cmd -Command escalate -RunId $RunIdText -NodeId <n> -Checkpoint <name> -Decision <question for the user> [-Risk high] [-RuleId <rule>] [-Inputs ...]' and WAIT for the user verdict (delivered back through your session or the Planner; never proceed past an open escalation). Every decision is auditable in the archive-level decisions.jsonl (统一决策账本) and overturnable (decide -Kind overturn) before settle."
}

function Get-ArchiveDecisionsPath {
    # 归档级统一决策账本路径（planner-midrun-derive 用户裁定）：账本是长期分析
    # 资产，归档是长期载体——新旧场景（AutoMode worker 决策 / 五角色检查点 /
    # derive 全链 / 编排裁定）一本账到底。run 级路径就此退役（用户确认无历史
    # AutoMode run，零迁移负担）。
    param([string]$ArchivePath)
    return (Join-Path $ArchivePath "decisions.jsonl")
}

function Read-DecisionEntries {
    # All decision entries as deep hashtables; blank/unparseable lines are
    # skipped (our own writer enforces read-back finish; external corruption
    # degrades to the parseable prefix, never throws).
    # NOTE: callers MUST wrap the result in @() — PS 5.1 unwraps a single-element
    # return into the entry itself, and .Count on an OrderedDictionary means
    # KEY count, not entry count.
    param([string]$LedgerPath)
    $entries = @()
    if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) { return @() }
    foreach ($line in @([System.IO.File]::ReadAllLines($LedgerPath))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $e = Convert-PSObjectToHashtable ($line | ConvertFrom-Json)
            if ($null -ne $e -and $e -is [System.Collections.IDictionary]) { $entries += ,$e }
        } catch { continue }
    }
    return @($entries)
}

function Add-DecisionEntry {
    # THE decision-ledger append chain (archive lock -> read -> assign D<n> ->
    # append -> read-back finish -> unlock; ledger.jsonl paradigm) — the single
    # copy shared by escalate AND decide AND the derive chain AND the
    # orchestration-ruling tail. $ValidateCallback (optional, with
    # $ValidateContext) runs INSIDE the lock against the fresh entries:
    # race-sensitive validation (decide's ref-entry lookups) shares the
    # append's critical section instead of a stale pre-lock check. Contract:
    # & $ValidateCallback <entries> <context>; returns the written entry.
    # -Advisory: on read-back failure return @{ failed; error } instead of
    # exiting (for best-effort tails whose host command already succeeded).
    param([string]$LedgerPath, [string]$LockDir, $Entry, [scriptblock]$ValidateCallback = $null, $ValidateContext = $null, [switch]$Advisory)
    $lockInfo = Enter-ArchiveLock $LockDir
    try {
        $entries = @(Read-DecisionEntries $LedgerPath)
        if ($null -ne $ValidateCallback) { & $ValidateCallback $entries $ValidateContext }
        $Entry['entry_id'] = "D$($entries.Count + 1)"
        $line = ConvertTo-Json $Entry -Depth 8 -Compress
        [System.IO.File]::AppendAllText($LedgerPath, $line + "`n", $script:Utf8NoBom)
        $all = @([System.IO.File]::ReadAllLines($LedgerPath) | Where-Object { $_.Trim() -ne "" })
        try { $null = $all[-1] | ConvertFrom-Json } catch {
            if ($Advisory) { return @{ failed = $true; error = "decisions.jsonl last line failed to parse after append" } }
            Write-ErrorResult "DECISIONS_READBACK_FAILED" "decisions.jsonl last line failed to parse after append" 3
        }
    }
    finally {
        Exit-ArchiveLock
    }
    $Entry['lock'] = $lockInfo
    return $Entry
}

function New-LedgerEntryPayload {
    # 四要素条目（统一决策账本标准形，kinds: derive_proposal / checkpoint /
    # ruling）：background / options[] / decision / reason + decider
    # （user | auto/<规则>@<stage> | planner）。$Extra 可选键追加（checkpoint
    # 名等上下文）；run 上下文可空（checkpoint 的 -Archive 归档级形态无 run）。
    param([string]$KindText, [string]$RunIdText, [string]$BackgroundText, $OptionsArr, [string]$DecisionText, [string]$ReasonText, [string]$DeciderText, [string]$RefEntryOut = $null, $Extra = $null)
    $e = [ordered]@{
        at         = Get-UtcNowIso
        run_id     = $(if (-not [string]::IsNullOrWhiteSpace($RunIdText)) { $RunIdText } else { $null })
        kind       = $KindText
        background = $(if ([string]::IsNullOrWhiteSpace($BackgroundText)) { $null } else { $BackgroundText })
        options    = @($(if ($null -ne $OptionsArr) { @($OptionsArr) } else { @() }))
        decision   = $DecisionText
        reason     = $(if ([string]::IsNullOrWhiteSpace($ReasonText)) { $null } else { $ReasonText })
        decider    = $DeciderText
        ref_entry  = $RefEntryOut
    }
    if ($null -ne $Extra -and $Extra -is [System.Collections.IDictionary]) {
        foreach ($k in @($Extra.Keys)) { $e[$k] = $Extra[$k] }
    }
    return $e
}

function Add-OrchestrationRuling {
    # 编排裁定自动入账（机械零负担，advisory）：rollback / reclaim / replan /
    # conclude / conflict-resolve 命令尾追加 kind=ruling 条目——规划者裁定也是
    # 决策，统一账本可分析（决策 #3 全量接入）。追加失败降级为警告返回（主命令
    # 已成功，不因留痕失败回滚语义）。返回 @{ entry; warning }。
    param([string]$ArchivePath, [string]$RunIdText, [string]$CommandName, [string]$DecisionText, [string]$ReasonText, $OptionsArr)
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { return @{ entry = $null; warning = $null } }
    $payload = New-LedgerEntryPayload -KindText 'ruling' -RunIdText $RunIdText -BackgroundText "run 中途编排裁定（$CommandName）" -OptionsArr $OptionsArr -DecisionText $DecisionText -ReasonText $ReasonText -DeciderText 'planner'
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath $ArchivePath) -LockDir $ArchivePath -Entry $payload -Advisory
    if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('failed') -and $entry['failed'] -eq $true) {
        return @{ entry = $null; warning = "决策账本入账失败（advisory）：$([string]$entry['error'])" }
    }
    return @{ entry = $entry; warning = $null }
}

function Find-DecisionEntry {
    param($Entries, [string]$EntryId)
    foreach ($e in @($Entries)) {
        if ([string]$e['entry_id'] -eq $EntryId) { return $e }
    }
    return $null
}

function Get-ReferencedEntryIds {
    # entry_ids already referenced by a resolution/overturn (the join inputs for
    # the open-escalation derivation — the ledger itself is never rewritten).
    param($Entries)
    $refs = @{}
    foreach ($e in @($Entries)) {
        $k = [string]$e['kind']
        if (($k -eq 'resolution' -or $k -eq 'overturn') -and -not [string]::IsNullOrWhiteSpace([string]$e['ref_entry'])) {
            $refs[[string]$e['ref_entry']] = $true
        }
    }
    return $refs
}

function Get-OpenEscalationRows {
    # Derived open-escalation rows for the decision view (join: escalation
    # entries minus those a resolution/overturn references via ref_entry — the
    # ledger itself is never rewritten). A pruned/missing node degrades to
    # historical=true: the entry stays listed, just annotated.
    param($Entries, $TreeData)
    $refs = Get-ReferencedEntryIds $Entries
    $open = @()
    foreach ($e in @($Entries)) {
        if ([string]$e['kind'] -ne 'escalation') { continue }
        if ($refs.Contains([string]$e['entry_id'])) { continue }
        $node = [string]$e['node_id']
        $nodeStatus = "missing"
        $nodeState = Get-NodeViewState $TreeData $node
        if ($null -ne $nodeState) { $nodeStatus = [string]$nodeState.status }
        $open += @{
            entry_id    = [string]$e['entry_id']
            node        = $node
            stage       = [string]$e['stage']
            checkpoint  = [string]$e['checkpoint']
            question    = [string]$e['decision']
            risk        = $(if (-not [string]::IsNullOrWhiteSpace([string]$e['risk'])) { [string]$e['risk'] } else { $null })
            rule_id     = $(if (-not [string]::IsNullOrWhiteSpace([string]$e['rule_id'])) { [string]$e['rule_id'] } else { $null })
            at          = [string]$e['at']
            node_status = $nodeStatus
            historical  = ($nodeStatus -eq 'pruned' -or $nodeStatus -eq 'missing')
        }
    }
    return @($open)
}

function Get-AutoModeDecisionView {
    # Visibility block for status/resume: per-node decision counts + the derived
    # open-escalation list (Get-OpenEscalationRows). Counts and open rows read
    # the same single ledger snapshot taken here (the ARCHIVE-level unified
    # ledger — only the four AutoMode worker kinds join this view; checkpoint /
    # ruling / derive_proposal entries are archive-scoped bookkeeping, not
    # per-node worker decisions).
    param([string]$RunDir, $Bridge, $TreeData)
    $entries = @(Read-DecisionEntries (Get-ArchiveDecisionsPath ([string]$Bridge.archive)))
    $countsByNode = @{}
    foreach ($e in $entries) {
        $k = [string]$e['kind']
        if ($k -notin @('auto', 'escalation', 'resolution', 'overturn')) { continue }
        $node = [string]$e['node_id']
        if (-not $countsByNode.Contains($node)) { $countsByNode[$node] = @{ node = $node; auto = 0; escalation = 0; resolution = 0; overturn = 0; total = 0 } }
        $c = $countsByNode[$node]
        if ($c.Contains($k)) { $c[$k] = [int]$c[$k] + 1 }
        $c['total'] = [int]$c['total'] + 1
    }
    $amSection = Get-AutoModeSection $Bridge
    return @{
        enabled          = $true
        ledger           = "$([string]$Bridge.archive_rel)/decisions.jsonl"
        policy_source    = $(if ($null -ne $amSection -and $amSection.Contains('policy_source')) { [string]$amSection['policy_source'] } else { "default" })
        decision_counts  = @(@($countsByNode.Values) | Sort-Object node)
        open_escalations = @(Get-OpenEscalationRows $entries $TreeData)
    }
}

# === Session roster (planner-session-roster) ===
#
# run 级会话花名册：sessions.json 落 run 状态目录，登记本 run 派生过的全部 dsh 会话
# （planner 本体 / 桥接派发 / 树外直交登记），status 命令经 sessions 字段透出——
# 「建会话未认领」窗口期与直交会话不再失追踪。字段：session_id/role/node/label/
# source/title/created_at/updated_at。全部写入路径均为 advisory：登记失败降级不阻断
# 派发本身（标题与花名册是展示性信息，与使命参数的 fail-loud 策略刻意相反）。
# 标题格式与 start-role.ps1 Get-SessionTitle 同构（本桥只经公共 CLI 编排、不
# dot-source 引擎内部函数——两处小段重复以本注释交叉锚定，改动须双侧同步）。

function ConvertTo-RunShort {
    # "deliver-2026-09-20-planner-session-roster" -> "planner-session-roster"
    # (mirror of start-role.ps1 ConvertTo-RunShortName)
    param([string]$RunIdText)
    if ([string]::IsNullOrWhiteSpace($RunIdText)) { return "" }
    $archiveName = $RunIdText -replace '^deliver-', ''
    return ($archiveName -replace '^\d{4}-\d{2}-\d{2}-', '')
}

function Get-RosterPath { param([string]$RunDir); Join-Path $RunDir "sessions.json" }

function Read-Roster {
    # returns @{ exists; corrupt; sessions = @(deep hashtables) }. Missing file
    # -> exists=$false (the roster is optional state: pre-feature runs and CLI
    # pushes simply have none). Unparseable file -> corrupt=$true + empty list;
    # status surfaces the warning and the next registration self-heals it.
    param([string]$RunDir)
    $p = Get-RosterPath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ exists = $false; corrupt = $false; sessions = @() } }
    try {
        $obj = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $sessions = @()
        if ($null -ne $obj -and $null -ne $obj.sessions) { $sessions = @(Convert-ToSafeArray (Convert-PSObjectToHashtable $obj.sessions)) }
        return @{ exists = $true; corrupt = $false; sessions = $sessions }
    }
    catch {
        return @{ exists = $true; corrupt = $true; sessions = @() }
    }
}

function Write-RosterFile {
    # direct write + read-back parse (no .bak: advisory display data — a torn
    # write at worst drops one cosmetic row; bridge.json keeps the hard state).
    # Returns @{ ok; error } and never throws.
    param([string]$RunDir, [string]$RunIdText, $Sessions)
    $p = Get-RosterPath $RunDir
    $payload = @{ format_version = 1; run_id = $RunIdText; sessions = @($Sessions) }
    try {
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json $payload -Depth 8), $script:Utf8NoBom)
        $null = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return @{ ok = $true; error = $null }
    }
    catch {
        return @{ ok = $false; error = [string]$_.Exception.Message }
    }
}

function Add-RosterEntry {
    # idempotent upsert keyed by session_id: re-registration (planner resume,
    # same-session re-push) refreshes role/node/label/source/title and stamps
    # updated_at while preserving the first created_at. Returns
    # @{ ok; entry; error } — advisory, never throws.
    param([string]$RunDir, [string]$RunIdText, [string]$SessionId, [string]$Role, [string]$Node, [string]$Label, [string]$Source, [string]$Title)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return @{ ok = $false; entry = $null; error = "empty session id" } }
    $roster = Read-Roster $RunDir
    $now = Get-UtcNowIso
    $entry = $null
    foreach ($s in @($roster.sessions)) {
        if ($null -ne $s -and $s -is [System.Collections.IDictionary] -and [string]$s['session_id'] -eq $SessionId) { $entry = $s; break }
    }
    if ($null -eq $entry) {
        $entry = @{ session_id = $SessionId; created_at = $now }
        $roster.sessions += ,$entry
    }
    $entry['role'] = $Role
    $entry['node'] = $(if ([string]::IsNullOrWhiteSpace($Node)) { $null } else { $Node })
    $entry['label'] = $(if ([string]::IsNullOrWhiteSpace($Label)) { $null } else { $Label })
    $entry['source'] = $Source
    $entry['title'] = $Title
    $entry['updated_at'] = $now
    $w = Write-RosterFile -RunDir $RunDir -RunIdText $RunIdText -Sessions $roster.sessions
    return @{ ok = $w.ok; entry = $entry; error = $w.error }
}

function Register-PushedSession {
    # 桥接派发回写：parse the created dsh sessionId out of start-role's success
    # output ("sessionId: <id>") and upsert the roster row (source=bridge-dispatch,
    # title mirrors start-role's pinned "[<run短名>] T<#>·<角色>·<节点>"). No
    # sessionId in the output (CLI/Plus backend) or any write failure -> silent
    # skip: the push ledger in bridge.json remains the authoritative record.
    param([string]$RunDir, [string]$RunIdText, [string]$Stage, [int]$TaskIdNum, [string]$NodeId, [string]$StartRoleText)
    if ([string]::IsNullOrWhiteSpace($StartRoleText)) { return $null }
    $m = [regex]::Match($StartRoleText, 'sessionId[：:]\s*([A-Za-z0-9][A-Za-z0-9_-]*)')
    if (-not $m.Success) { return $null }
    $sid = $m.Groups[1].Value
    $title = ""
    $short = ConvertTo-RunShort $RunIdText
    if ($short) {
        $parts = @()
        if ($TaskIdNum -ge 1) { $parts += "T$TaskIdNum" }
        $parts += $Stage
        if (-not [string]::IsNullOrWhiteSpace($NodeId)) { $parts += $NodeId }
        $title = "[{0}] {1}" -f $short, ($parts -join '·')
    }
    $r = Add-RosterEntry -RunDir $RunDir -RunIdText $RunIdText -SessionId $sid -Role $Stage -Node $NodeId -Label $null -Source "bridge-dispatch" -Title $title
    if ($r.ok) { return $r.entry }
    return $null
}

function Register-PlannerBody {
    # planner 本体登记：register the CURRENT dsh session (the planner itself)
    # into the roster. DSH_SESSION_ID is injected by the harness into every
    # shell subprocess of a dsh session (same source Get-SessionLabel reads);
    # absent (CLI/Plus planner) -> silent skip. Called by promulgate (right
    # after the run dir exists) and resume (a fresh planner session joins the
    # roster; idempotent by session_id). Advisory.
    param([string]$RunDir, [string]$RunIdText)
    if ([string]::IsNullOrWhiteSpace($env:DSH_SESSION_ID)) { return $null }
    $short = ConvertTo-RunShort $RunIdText
    $title = $short
    $r = Add-RosterEntry -RunDir $RunDir -RunIdText $RunIdText -SessionId $env:DSH_SESSION_ID -Role "PLANNER" -Node $null -Label $null -Source "planner" -Title $title
    if ($r.ok) { return $r.entry }
    return $null
}

function Get-NodeTaskStage {
    # node id -> @{ task_id; stage } from the authoritative mapping; $null when unknown.
    # Read-Bridge normalizes the whole bridge to hashtables, so both containers
    # here are IDictionary (PS 5.1 Add-Member cannot carry numeric-string keys).
    param($Bridge, [string]$NodeId)
    if ($null -eq $Bridge) { return $null }
    if (-not (Test-PropPresent $Bridge 'nodes') -or $null -eq $Bridge.nodes) { return $null }
    $entry = $null
    if ($Bridge.nodes -is [System.Collections.IDictionary]) {
        if ($Bridge.nodes.Contains($NodeId)) { $entry = $Bridge.nodes[$NodeId] }
    }
    elseif ($Bridge.nodes -is [System.Management.Automation.PSCustomObject]) {
        $prop = $Bridge.nodes.PSObject.Properties[$NodeId]
        if ($null -ne $prop) { $entry = $prop.Value }
    }
    if ($null -eq $entry) { return $null }
    return @{ task_id = [int]$entry.task_id; stage = [string]$entry.stage }
}

function Set-NodeTaskStage {
    param($Bridge, [string]$NodeId, [int]$TaskId, [string]$Stage)
    $Bridge.nodes[$NodeId] = @{ task_id = $TaskId; stage = $Stage }
    $tKey = "$TaskId"
    if (-not $Bridge.tasks.Contains($tKey)) { $Bridge.tasks[$tKey] = @{} }
    $tEntry = $Bridge.tasks[$tKey]
    if (-not $tEntry.Contains('stages') -or $null -eq $tEntry['stages']) { $tEntry['stages'] = @{} }
    $tEntry['stages'][$Stage] = $NodeId
}

# === Auto-push machinery (goal-tree-goal-root: dependency-driven dispatch) ===
#
# Dispatch stopped being a per-node manual planner command: every trigger point
# (promulgate tail / settle tail / reclaim tail / status touch) recomputes the
# unlocked set and pushes EVERY node that is unlocked ∧ non-terminal ∧ free of an
# active claim ∧ not yet successfully pushed since its last reclaim. Accounting
# lives inside bridge.json v2 (pushes ledger, per-node .bak+read-back persistence)
# so a crash mid-batch leaves an idempotent recompute-and-continue state.

function Read-ArchiveGoal {
    # The goal root carries the ORIGINAL requirement (the final objective):
    # the archive's requirements/overview.md when present (H1 = title, full body =
    # description); a machine-synthesized summary from the plan otherwise.
    param([string]$ArchivePath, $Plan)
    $overview = Join-Path $ArchivePath "requirements/overview.md"
    if (Test-Path -LiteralPath $overview -PathType Leaf) {
        $content = ([System.IO.File]::ReadAllText($overview, [System.Text.Encoding]::UTF8)).Trim()
        $title = $null
        $m = [regex]::Match($content, '(?m)^\s*#\s+(.+?)\s*$')
        if ($m.Success) { $title = $m.Groups[1].Value.Trim() }
        if ([string]::IsNullOrWhiteSpace($title)) { $title = "archive goal" }
        return @{ title = $title; description = $content; source = "requirements/overview.md" }
    }
    $titles = @($Plan | ForEach-Object { [string]$_.task.title })
    return @{
        title       = "archive goal ($($Plan.Count) sub-requirements)"
        description = "Archive goal — deliver $($Plan.Count) sub-requirement(s): $($titles -join '; ')"
        source      = "synthesized"
    }
}

function Invoke-HttpGetJson {
    # minimal GET + JSON with a hard timeout, PS 5.1-safe (WebClient has no timeout;
    # HttpWebRequest does). Returns @{ ok; json; text } — never throws.
    param([string]$Url, [int]$TimeoutMs = 3000)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = "GET"
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null
        $resp = $req.GetResponse()
        try {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
        }
        finally { $resp.Close() }
        $json = $null
        try { $json = $text | ConvertFrom-Json } catch { $json = $null }
        return @{ ok = $true; json = $json; text = $text }
    }
    catch {
        return @{ ok = $false; json = $null; text = [string]$_.Exception.Message }
    }
}

function Get-ClaimLiveness {
    # Two-level session liveness for a claimed node (goal-tree-goal-root decision 6):
    # level 1 — the dsh agents registry via the goal-tree plugin's read-only
    # liveness endpoint (same source the worker-report callback delivery uses);
    # level 2 — time threshold (claimed_at older than $DeadClaimMinutes) ONLY as
    # the unknown fallback. Probe failures degrade to unknown and never block.
    # Outside dsh shells (no DSH_WEB_URL) liveness is unknown by construction.
    param([string]$RunId, [string]$NodeId)
    $claimsPath = Join-Path (Join-Path (Get-BridgeRunDir $RunId) "state") ("claims\$NodeId.json")
    $sessionId = $null
    if (Test-Path -LiteralPath $claimsPath -PathType Leaf) {
        try {
            $claim = [System.IO.File]::ReadAllText($claimsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($claim.dsh_session_id) { $sessionId = [string]$claim.dsh_session_id }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        return @{ liveness = "unknown"; session_id = $null; reason = "no dsh session binding on the claim sidecar (CLI claim or legacy run)" }
    }
    if ([string]::IsNullOrWhiteSpace($env:DSH_WEB_URL)) {
        return @{ liveness = "unknown"; session_id = $sessionId; reason = "not a dsh shell (DSH_WEB_URL absent) — registry unverifiable here" }
    }
    $url = "$($env:DSH_WEB_URL.TrimEnd('/'))/rdd-goal-tree/liveness?cwd=$([uri]::EscapeDataString($repoRoot))&run=$RunId&node=$NodeId"
    $r = Invoke-HttpGetJson $url
    if (-not $r.ok -or $null -eq $r.json) {
        return @{ liveness = "unknown"; session_id = $sessionId; reason = "liveness endpoint unreachable: $($r.text)" }
    }
    $live = "unknown"
    if ($r.json.PSObject.Properties['liveness']) { $live = [string]$r.json.liveness }
    return @{ liveness = $live; session_id = $sessionId; reason = "agents registry (plugin liveness endpoint)" }
}

function Get-SessionLiveness {
    # session-keyed liveness probe (inplace-redo-session-reuse): the same
    # agents-registry source as Get-ClaimLiveness's level 1, but the session id
    # comes from the CALLER — roster candidates are historical dispatches with
    # no live claim sidecar, so the node-keyed form cannot address them. The
    # plugin's liveness endpoint takes the optional session_id query parameter
    # (sidecar resolution skipped). Outside dsh shells or on probe failure
    # liveness degrades to unknown and the caller treats the candidate as
    # non-reusable (conservative — unknown is never a reuse verdict).
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return @{ liveness = "unknown"; session_id = $null; reason = "no session id" }
    }
    if ([string]::IsNullOrWhiteSpace($env:DSH_WEB_URL)) {
        return @{ liveness = "unknown"; session_id = $SessionId; reason = "not a dsh shell (DSH_WEB_URL absent) — registry unverifiable here" }
    }
    $url = "$($env:DSH_WEB_URL.TrimEnd('/'))/rdd-goal-tree/liveness?cwd=$([uri]::EscapeDataString($repoRoot))&session_id=$([uri]::EscapeDataString($SessionId))"
    $r = Invoke-HttpGetJson $url
    if (-not $r.ok -or $null -eq $r.json) {
        return @{ liveness = "unknown"; session_id = $SessionId; reason = "liveness endpoint unreachable: $($r.text)" }
    }
    $live = "unknown"
    if ($r.json.PSObject.Properties['liveness']) { $live = [string]$r.json.liveness }
    return @{ liveness = $live; session_id = $SessionId; reason = "agents registry (session-keyed probe)" }
}

function Find-ReusableSession {
    # reuse resolution for auto/manual dispatch (inplace-redo-session-reuse):
    # scan the run's session roster for the newest ALIVE session bound to the
    # same (task, stage) and return it as the push target — the discovery face;
    # the claim sidecar stays the binding truth of the in-place redo path.
    # Rows without a node binding (direct handoffs) cannot join the same-task
    # key and never match (v1 boundary). Roster blindness, non-dsh shells and
    # dead candidates degrade to $null = current behavior (session.create).
    # Returns @{ session_id; liveness } or $null.
    param([string]$RunDir, $Bridge, [int]$TaskId, [string]$Stage)
    if ([string]::IsNullOrWhiteSpace($env:DSH_WEB_URL)) { return $null }
    $roster = Read-Roster $RunDir
    if (-not $roster.exists -or $roster.corrupt) { return $null }
    $candidates = @()
    foreach ($s in @($roster.sessions)) {
        if ($null -eq $s -or $s -isnot [System.Collections.IDictionary]) { continue }
        if ([string]$s['role'] -ne $Stage) { continue }
        $rowNode = $(if ($s.Contains('node') -and $null -ne $s['node']) { [string]$s['node'] } else { "" })
        if ([string]::IsNullOrWhiteSpace($rowNode)) { continue }
        $mapping = Get-NodeTaskStage $Bridge $rowNode
        if ($null -eq $mapping -or [int]$mapping.task_id -ne $TaskId) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$s['session_id'])) { continue }
        $candidates += $s
    }
    if ($candidates.Count -eq 0) { return $null }
    # newest first (updated_at desc): the most recent delivery context wins —
    # after a re-push the upsert refreshes the winner's updated_at, keeping the
    # chain stable across consecutive reuses
    $sorted = @($candidates | Sort-Object -Descending { [string]$_['updated_at'] })
    foreach ($s in $sorted) {
        $sid = [string]$s['session_id']
        $live = Get-SessionLiveness $sid
        if ($live.liveness -eq "alive") { return @{ session_id = $sid; liveness = $live } }
    }
    return $null
}

function Get-NodePushState {
    # per-node push ledger entry (deep hashtable), $null when never pushed
    param($Bridge, [string]$NodeId)
    if (-not (Test-PropPresent $Bridge 'pushes') -or $null -eq $Bridge.pushes) { return $null }
    $entry = $null
    if ($Bridge.pushes -is [System.Collections.IDictionary]) {
        if ($Bridge.pushes.Contains($NodeId)) { $entry = $Bridge.pushes[$NodeId] }
    }
    else {
        $prop = $Bridge.pushes.PSObject.Properties[$NodeId]
        if ($null -ne $prop) { $entry = $prop.Value }
    }
    if ($null -ne $entry -and $entry -isnot [System.Collections.IDictionary]) { $entry = Convert-PSObjectToHashtable $entry }
    return $entry
}

function Set-NodePushRecord {
    # record ONE push attempt (ok or failed) for a node; persist bridge.json per
    # node (.bak + read-back contract) so a crash mid-batch loses at most the
    # in-flight entry and the next trigger recomputes idempotently.
    # retry_class: $null on success; 'session-create' (start-role failed before a
    # session existed — auto-retried by the next trigger) or 'pointer' (session
    # created but the pointer message failed — MANUAL re-push only, an auto retry
    # would stack duplicate sessions).
    # ReusedSessionId (inplace-redo-session-reuse): non-empty marks a
    # re-delivery into an EXISTING session — the attempt carries it so status
    # push rows show the destination (reuse visibility).
    param([string]$RunDir, $Bridge, [string]$NodeId, [bool]$Ok, [string]$Error, [string]$RetryClass, [string]$ReusedSessionId = $null)
    if (-not (Test-PropPresent $Bridge 'pushes') -or $null -eq $Bridge.pushes) { $Bridge['pushes'] = @{} }
    if (-not $Bridge.pushes.Contains($NodeId)) { $Bridge.pushes[$NodeId] = @{ last_ok_at = $null; needs_repush = $false; attempts = @() } }
    $st = $Bridge.pushes[$NodeId]
    if ($Ok) {
        $st['last_ok_at'] = Get-UtcNowIso
        $st['needs_repush'] = $false
    }
    else {
        $st['needs_repush'] = $true
    }
    $attempt = @{ at = Get-UtcNowIso; ok = $Ok }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $attempt['error'] = $Error }
    if (-not [string]::IsNullOrWhiteSpace($RetryClass)) { $attempt['retry_class'] = $RetryClass }
    if (-not [string]::IsNullOrWhiteSpace($ReusedSessionId)) { $attempt['reused_session_id'] = $ReusedSessionId }
    $attempts = @(Convert-ToSafeArray $st['attempts'])
    $attempts += ,$attempt
    if ($attempts.Count -gt 10) { $attempts = @($attempts | Select-Object -Last 10) }   # bounded ledger
    $st['attempts'] = $attempts
    Write-BridgeFile $RunDir $Bridge
    return $Bridge
}

function Set-NodeRepushFlag {
    # mark a node for re-push WITHOUT recording an attempt (reclaim parking is an
    # orchestration mark, not a delivery attempt — the push ledger stays honest).
    param([string]$RunDir, $Bridge, [string]$NodeId)
    if (-not (Test-PropPresent $Bridge 'pushes') -or $null -eq $Bridge.pushes) { $Bridge['pushes'] = @{} }
    if (-not $Bridge.pushes.Contains($NodeId)) { $Bridge.pushes[$NodeId] = @{ last_ok_at = $null; needs_repush = $false; attempts = @() } }
    $Bridge.pushes[$NodeId]['needs_repush'] = $true
    Write-BridgeFile $RunDir $Bridge
    return $Bridge
}

function Get-PushFailureClass {
    # one classifier, two callers (auto-dispatch + manual dispatch): a failure
    # whose text proves the session already existed ("会话已创建") is pointer
    # class — manual re-push only (an auto retry would stack a duplicate
    # session); everything else failed before the session existed and is safe
    # to auto-retry (session-create).
    param([string]$FailureText)
    if ($FailureText -match '会话已创建') { return "pointer" }
    return "session-create"
}

function Get-PushCandidates {
    # Pushable node descriptors: bridge-mapped delivery nodes + tree-level
    # acceptance nodes (overall-delivery chain, no TaskId). One unified
    # candidate list so the push loop sees both shapes through one gate.
    param($Bridge)
    $list = @()
    foreach ($nodeId in @($Bridge.nodes.Keys)) {
        $mapping = Get-NodeTaskStage $Bridge $nodeId
        if ($null -eq $mapping) { continue }
        $list += @{ node = [string]$nodeId; stage = [string]$mapping.stage; task_id = [int]$mapping.task_id; tree_level = $false }
    }
    $a = Get-AcceptanceSection $Bridge
    if ($null -ne $a -and ([string]$a['status']) -eq 'grafted') {
        foreach ($spec in @($script:AcceptanceChainSpecs)) {
            $nid = [string]$a[$spec.node_key]
            if (-not $nid) { continue }
            $role = [string]$spec.role
            if ((Test-PropPresent $a $spec.role_key) -and $a[$spec.role_key]) { $role = [string]$a[$spec.role_key] }
            $list += @{ node = $nid; stage = $role; task_id = 0; tree_level = $true }
        }
    }
    # stage acceptance nodes (long-task-planning): a grafted [集成验收·S<k>]
    # rides the same push path as the R1 chain nodes (tree-level, no TaskId).
    # stage design-review nodes (auditor-design-stage-review): a grafted
    # [设计审查·S<k>] rides the same tree-level push path (role=AUDITOR).
    # auditor-subagent-review: this face is LEGACY-CHAIN ONLY — review_mode runs
    # never graft review nodes (pure contract), so zero nodes appear here.
    # derivation PM nodes (planner-midrun-derive): a confirmed-but-unregistered
    # derivation's PM node rides the same tree-level push path (stage=PM).
    $p = Get-PlanSection $Bridge
    if ($null -ne $p) {
        foreach ($st in @($p['stages'])) {
            $ap = $st['acceptance_point']
            if (([string]$ap['status']) -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace([string]$ap['node'])) {
                $list += @{ node = [string]$ap['node']; stage = "QA"; task_id = 0; tree_level = $true }
            }
            $dr = $st['design_review']
            if ($null -ne $dr -and ([string]$dr['status']) -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace([string]$dr['node'])) {
                $list += @{ node = [string]$dr['node']; stage = "AUDITOR"; task_id = 0; tree_level = $true }
            }
        }
    }
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        if (([string]$d['status']) -ne 'confirmed') { continue }
        $dn = [string]$d['node']
        if ([string]::IsNullOrWhiteSpace($dn)) { continue }
        if ((Test-PropPresent $d 'task_id') -and $null -ne $d['task_id']) { continue }
        $list += @{ node = $dn; stage = "PM"; task_id = 0; tree_level = $true }
    }
    return $list
}

function Get-PushStatusMap {
    # whole-tree status/depends maps: unlock is computed HERE, not via the leaf
    # next view alone — parked (reclaim) nodes are status=claimed and never
    # appear in next's pending list, yet they are exactly the recycle-then-
    # repush targets. Returns @{ status; depends }.
    param([string]$RunIdText)
    $treeData = Get-TreeStatusView $RunIdText
    $statusOf = @{}
    $dependsOf = @{}
    foreach ($bucket in @("pending", "done", "pruned")) {
        foreach ($nid in @(Convert-ToSafeArray $treeData.nodes.$bucket)) { $statusOf[[string]$nid] = $bucket }
    }
    foreach ($n in @(Convert-ToSafeArray $treeData.nodes.claimed)) {
        $cid = if ($n -is [string]) { $n } else { [string]$n.id }
        $statusOf[$cid] = "claimed"
        if ($n -isnot [string]) { $dependsOf[$cid] = @(Convert-ToSafeArray $n.depends_on) }
    }
    foreach ($n in @(Convert-ToSafeArray $treeData.nodes.reported)) {
        $rid = if ($n -is [string]) { $n } else { [string]$n.id }
        $statusOf[$rid] = "reported"
        if ($n -isnot [string]) { $dependsOf[$rid] = @(Convert-ToSafeArray $n.depends_on) }
    }
    return @{ tree_data = $treeData; status = $statusOf; depends = $dependsOf }
}

function Add-LeafPendingToMap {
    # leaf next view supplement (its pending/blocked entries carry depends_on
    # where the status bucket only has bare ids). Mutates the maps in place.
    param($StatusOf, $DependsOf, $Nx)
    if ($null -eq $Nx) { return }
    foreach ($p in @(Convert-ToSafeArray $Nx.pending)) {
        $pnid = if ($p -is [string]) { $p } else { [string]$p.id }
        $StatusOf[$pnid] = "pending"
        if ($p -isnot [string]) { $DependsOf[$pnid] = @(Convert-ToSafeArray $p.depends_on) }
    }
    foreach ($b in @(Convert-ToSafeArray $Nx.blocked)) {
        $bnid = if ($b -is [string]) { $b } else { [string]$b.id }
        $StatusOf[$bnid] = "pending"
        if ($b -isnot [string]) { $DependsOf[$bnid] = @(Convert-ToSafeArray $b.depends_on) }
    }
}

function Test-PushCandidate {
    # Per-node push gate (state filter + unlock + push-ledger rules). Returns
    # $null = push it, or the skip record consumed by the caller's ledger.
    param([string]$NodeId, $Node, [string]$Status, [bool]$Parked, $StatusOf, $DependsOf, $Bridge, [string]$RunDir = "")
    if ($Status -in @("done", "pruned", "reported", "missing") -or ($Status -eq "claimed" -and -not $Parked)) {
        return @{ node = $NodeId; reason = $Status }
    }
    # unlock gate: every depends_on target must be terminal (done; pruned also
    # satisfies — prune discharges the obligation, same as the leaf claim gate).
    $deps = @()
    if ($null -ne $Node -and $Node.PSObject.Properties['depends_on'] -and $Node.depends_on) { $deps = @($Node.depends_on) }
    elseif ($DependsOf.ContainsKey($NodeId)) { $deps = $DependsOf[$NodeId] }
    $blockedHere = @()
    foreach ($d in $deps) {
        $ds = if ($StatusOf.ContainsKey([string]$d)) { $StatusOf[[string]$d] } else { "missing" }
        if (@('done', 'pruned') -notcontains $ds) { $blockedHere += [string]$d }
    }
    if ($blockedHere.Count -gt 0) {
        return @{ node = $NodeId; reason = "blocked_by_deps"; blocked_by = @($blockedHere) }
    }
    # stage gate (long-task-planning, 只增不减): on top of DAG unlock, the
    # node's task stage waits for EVERY earlier stage's acceptance point —
    # deterministic feedback is blocked_by_stage_gate (claim/dispatch surface
    # the same gate as NODE_BLOCKED_BY_GATE).
    $map = Get-NodeTaskStage $Bridge $NodeId
    if ($null -ne $map) {
        $gateBlockers = Get-PlanGateBlockers $Bridge ([int]$map.task_id)
        if ($gateBlockers.Count -gt 0) {
            return @{ node = $NodeId; reason = "blocked_by_stage_gate"; blocked_by = @($gateBlockers) }
        }
        # design-review gate (auditor-design-stage-review; 与阶段闸门/conflict hold
        # 同路径 AND 栈叠、reason 分列): an open [设计审查·S<k>] holds the post-DESIGN
        # nodes of tasks carrying on-disk design products (审查未过 IMPL 不解锁).
        $drBlockers = Get-DesignReviewGateBlockers $Bridge ([int]$map.task_id) ([string]$map.stage)
        if (@($drBlockers).Count -gt 0) {
            return @{ node = $NodeId; reason = "blocked_by_design_review"; blocked_by = @($drBlockers) }
        }
    }
    $pushState = Get-NodePushState $Bridge $NodeId
    $pushedOk = ($null -ne $pushState -and $pushState.Contains('last_ok_at') -and $null -ne $pushState['last_ok_at'])
    $needsRepush = ($null -ne $pushState -and $pushState.Contains('needs_repush') -and [bool]$pushState['needs_repush'])
    if ($pushedOk -and -not $needsRepush) {
        return @{ node = $NodeId; reason = "already_pushed" }
    }
    # pointer-class failures (session created, pointer message failed) are MANUAL
    # re-push only — an auto retry would stack a duplicate session (decision 5).
    if ($needsRepush) {
        $attempts = @()
        if ($pushState.Contains('attempts') -and $null -ne $pushState['attempts']) { $attempts = @(Convert-ToSafeArray $pushState['attempts']) }
        $lastAttempt = if ($attempts.Count -gt 0) { $attempts[-1] } else { $null }
        $lastClass = $null
        if ($null -ne $lastAttempt -and $lastAttempt -is [System.Collections.IDictionary] -and $lastAttempt.Contains('retry_class')) { $lastClass = [string]$lastAttempt['retry_class'] }
        if ($lastClass -eq 'pointer') {
            return @{ node = $NodeId; reason = "pointer_manual_repush"; retry_class = $lastClass }
        }
    }
    # parallel-coordination conflict gate (AND-stacked with the R3 stage gate
    # above, reasons kept apart): unresolved-conflict membership -> held_by_
    # conflict; fresh change-map file overlap -> auto-registered + held_by_file_
    # overlap. Old runs (no conflicts section) fall through untouched.
    if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
        $hold = Test-ConflictHold -NodeId $NodeId -Bridge $Bridge -RunDir $RunDir -StatusOf $StatusOf
        if ($null -ne $hold) { return $hold }
    }
    return $null
}

function Invoke-StartRolePush {
    # shared delivery core (inplace-redo-session-reuse): ONE start-role
    # invocation for a push candidate — a fresh session, or reuse of an
    # existing one (-ExistingSessionId; the redo re-anchoring payload rides
    # -Appendix). Push-ledger accounting and the roster write-back stay here so
    # reused and fresh deliveries classify identically; a failed prompt onto a
    # session that already exists is pointer-class BY CONSTRUCTION (manual
    # re-push only — an auto retry would re-prompt a session that may have
    # consumed the first delivery after a transient queue rejection).
    # Returns @{ ok; error; retry_class; bridge; session_id; reused }.
    param($Cand, [string]$RunDir, $Bridge, [string]$TaskText, [string]$ExistingSessionId, [string]$Appendix)
    $nodeId = [string]$Cand.node
    $brief = Get-NodeTaskBrief -NodeTask $TaskText -NodeId $nodeId
    $summary = Get-NodeTaskSummary -NodeTask $TaskText
    $reused = (-not [string]::IsNullOrWhiteSpace($ExistingSessionId))
    try {
        # -GoalTreeRun/-GoalTreeNode stamp the pointer message with the bridge
        # marker so the pushed worker session knows (first turn) that completion
        # goes back to the Planner via leaf report, not a 4-step direct handoff.
        # Tree-level acceptance nodes carry no -TaskId (start-role runs them in
        # the goal-tree run marker shape).
        $startArgs = @("-Role", $Cand.stage)
        if (-not $Cand.tree_level) { $startArgs += @("-TaskId", "$($Cand.task_id)") }
        $startArgs += @("-TaskJson", (Join-Path $Bridge.archive "task.json"), "-GoalTreeRun", ([string]$Bridge.run_id), "-GoalTreeNode", $nodeId)
        if ($brief) { $startArgs += @("-TaskBrief", $brief) }
        if ($summary) { $startArgs += @("-TaskSummary", $summary) }
        if ($reused) {
            $startArgs += @("-ExistingSessionId", $ExistingSessionId)
            if (-not [string]::IsNullOrWhiteSpace($Appendix)) { $startArgs += @("-Appendix", $Appendix) }
        }
        $r = Invoke-StartRole $startArgs
    }
    catch {
        $r = @{ exit = 1; text = "start-role invocation threw: $($_.Exception.Message)" }
    }
    $ok = ($r.exit -eq 0)
    $retryClass = $null
    $errText = $null
    if (-not $ok) {
        $errText = $r.text
        if ($reused) { $retryClass = "pointer" }
        else { $retryClass = Get-PushFailureClass $r.text }
    }
    $newBridge = Set-NodePushRecord $RunDir $Bridge $nodeId $ok $errText $retryClass $(if ($reused) { $ExistingSessionId } else { $null })
    if ($ok) {
        # roster write-back (planner-session-roster): advisory, silent skip —
        # a reuse success re-upserts the SAME session row (node/updated_at
        # refresh, no new row: the whole point is not stacking sessions)
        $taskNum = 0
        if (-not $Cand.tree_level) { $taskNum = [int]$Cand.task_id }
        $null = Register-PushedSession -RunDir $RunDir -RunIdText ([string]$Bridge.run_id) -Stage $Cand.stage -TaskIdNum $taskNum -NodeId $nodeId -StartRoleText $r.text
    }
    return @{ ok = $ok; error = $errText; retry_class = $retryClass; bridge = $newBridge; session_id = $ExistingSessionId; reused = $reused }
}

function Invoke-NodePush {
    # ONE start-role push for a candidate (mapped or tree-level). Reuse
    # resolution (inplace-redo-session-reuse) precedes the delivery: a live
    # roster session bound to the same (task, stage) receives the pointer
    # directly instead of a fresh session.create — QA re-verify nodes and
    # reclaim re-pushes benefit. Exclusions keep the legacy fresh-session path:
    # rollback-triggered batches (v1 boundary — cross-stage rebuild keeps
    # rebuild semantics), tree-level nodes (task_id=0 degrades the same-task
    # key into a global match) and -NoReuse. Returns
    # @{ ok; error; retry_class; bridge; session_id; reused; reused_session }.
    param($Cand, [string]$RunDir, $Bridge, $Nx, [bool]$AllowReuse = $true)
    $nodeId = [string]$Cand.node
    # task brief (dispatch-task-goal-anchoring): goal-first statement derived
    # from the PERSISTED node.task — in-place from the leaf next view first
    # (its pending entries carry the full task text), per-node probe as fallback.
    $taskText = ""
    if ($null -ne $Nx) {
        foreach ($p in @(Convert-ToSafeArray $Nx.pending)) {
            if (([string]$p.id) -eq $nodeId -and $null -ne $p.PSObject.Properties['task']) { $taskText = [string]$p.task }
        }
    }
    if (-not $taskText) { $taskText = Get-NodeTaskText -RunId ([string]$Bridge.run_id) -NodeId $nodeId }
    $reuseSession = $null
    if ($AllowReuse -and -not $Cand.tree_level) {
        $reuseSession = Find-ReusableSession -RunDir $RunDir -Bridge $Bridge -TaskId ([int]$Cand.task_id) -Stage ([string]$Cand.stage)
    }
    $existingId = $null
    if ($null -ne $reuseSession) { $existingId = [string]$reuseSession.session_id }
    $push = Invoke-StartRolePush -Cand $Cand -RunDir $RunDir -Bridge $Bridge -TaskText $taskText -ExistingSessionId $existingId
    $push['reused_session'] = $reuseSession
    return $push
}

function Invoke-AutoDispatch {
    # THE auto-push function (goal-tree-goal-root). Push = the same start-role
    # delivery chain the manual dispatch command uses. No concurrency cap
    # (decision 3: idempotent pushes, PM splits are small); per-node isolation so
    # one failure never blocks the rest; per-node accounting in bridge.json v2.
    # AllowReuse (inplace-redo-session-reuse): $false forces the legacy
    # fresh-session path for the whole batch — rollback-triggered rebuilds
    # always pass $false (v1 boundary), reclaim passes -not $NoReuse; every
    # other trigger keeps the reuse-priority resolution.
    # Returns { trigger; considered; pushed; skipped; failed; bridge } — failures
    # are data, never exceptions (callers embed them in their own output).
    param([string]$RunDir, $Bridge, [string]$Trigger, [bool]$AllowReuse = $true)
    # acceptance-chain trigger (overall-delivery): every auto-dispatch trigger
    # (promulgate/settle/reclaim/rollback/status touch) funnels through here, so
    # the timing expression ("all sub-requirement nodes settled") self-heals any
    # crash window on the next touch. Grafting is tree state, not a push — it
    # runs even under the no_push isolation gate below.
    $chain = Update-AcceptanceChain $RunDir $Bridge
    $Bridge = $chain.bridge
    $grafted = @($chain.grafted)
    # stage acceptance-point state machine (long-task-planning): same
    # self-healing trigger placement — grafts [集成验收·S<k>] nodes, binds the
    # R1 final chain, advances acceptance_point status, writes plan-log events.
    $planMoves = Update-StageAcceptancePoints $RunDir $Bridge
    $Bridge = $planMoves.bridge
    $grafted += @($planMoves.grafted)
    # stage design-review state machine (auditor-design-stage-review): same
    # self-healing placement — grafts [设计审查·S<k>] / exempt / records the
    # derived verdict / runs the fail wave. Graft & set-route are state, not
    # pushes: they run even under the no_push isolation gate below; the fail
    # wave's rebuilt DESIGN nodes reach the push loop of THIS pass when the
    # wave completes (repush rides the outer candidate enumeration).
    $drMoves = Update-StageDesignReviews $RunDir $Bridge
    $Bridge = $drMoves.bridge
    $grafted += @($drMoves.grafted)
    # derivation registration state machine (planner-midrun-derive): same
    # self-healing placement — a confirmed derivation whose PM node settled but
    # whose task registration did not land (crash window between the tree settle
    # and the add-task/bridge write) re-runs the idempotent registration here.
    # Registration is state, not a push: it runs even under no_push isolation.
    $derMoves = Update-DerivationRegistrations $RunDir $Bridge
    $Bridge = $derMoves.bridge
    # Run-level isolation gate (bridge.json no_push, set by promulgate -NoPush):
    # one upfront check makes an isolated run provably zero-backend for its
    # whole lifetime (0923 incident, QA F1). The manual dispatch command stays
    # open: an explicit human action is the designated isolation override.
    if (Test-PropPresent $Bridge 'no_push' -and $Bridge['no_push'] -eq $true) {
        return @{ trigger = "$Trigger (no_push)"; considered = 0; pushed = @(); skipped = @(); failed = @(); bridge = $Bridge; no_push = $true; acceptance_grafted = $grafted }
    }
    $result = @{ trigger = $Trigger; considered = 0; pushed = @(); skipped = @(); failed = @(); acceptance_grafted = $grafted }
    $maps = Get-PushStatusMap ([string]$Bridge.run_id)
    $nx = Get-LeafNextView ([string]$Bridge.run_id)
    Add-LeafPendingToMap $maps.status $maps.depends $nx
    foreach ($cand in @(Get-PushCandidates $Bridge)) {
        $result.considered++
        $node = Get-NodeFromTree $maps.tree_data ([string]$cand.node)
        $status = if ($node) { [string]$node.status } else { "missing" }
        # parked = recycled by reclaim, waiting for the next claimant: it is a PUSH
        # target (the "recycle then re-push" loop), unlike a live worker claim.
        $parked = ($status -eq "claimed" -and [string]$node.claimed_by -eq "planner-reclaim")
        $skip = Test-PushCandidate -NodeId ([string]$cand.node) -Node $node -Status $status -Parked $parked -StatusOf $maps.status -DependsOf $maps.depends -Bridge $Bridge -RunDir $RunDir
        if ($null -ne $skip) {
            $result.skipped += $skip
            continue
        }
        $push = Invoke-NodePush $cand $RunDir $Bridge $nx $AllowReuse
        $Bridge = $push.bridge
        if ($push.ok) { $result.pushed += [string]$cand.node }
        else { $result.failed += @{ node = [string]$cand.node; error = $push.error; retry_class = $push.retry_class } }
    }
    $result.bridge = $Bridge
    return $result
}

# === Planner lease (advisory, session-scale) ===
#
# Distinct from the per-run .lock (command-scale, 60s stale): a Planner conversation
# spans many commands, so the lease uses LastWriteTime staleness with an independent
# 30-minute threshold. -Takeover force-overrides with an audit trail in the file.

function Get-LeaseState {
    param([string]$RunDir)
    $p = Get-LeasePath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ exists = $false } }
    try {
        $obj = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch { return @{ exists = $true; corrupt = $true; age_seconds = 999999999; raw_holder = "<corrupt>" } }
    $age = ((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalSeconds
    $holder = [string]$obj.holder
    $stale = ($age -gt ($LeaseStaleMinutes * 60))
    # CLI one-shot holders are provably dead when their pid is gone: a fresh lease
    # left by an exited process must not wedge the run for the full stale window
    # (each bridge invocation in CLI land is its own pid label). dsh-session and
    # custom labels keep the pure time rule — their holder id is not a pid.
    if (-not $stale -and $holder -match '^planner-pid(\d+)$') {
        $holderPid = [int]$Matches[1]
        $procAlive = $false
        try { if (Get-Process -Id $holderPid -ErrorAction SilentlyContinue) { $procAlive = $true } } catch {}
        if (-not $procAlive) { $stale = $true }
    }
    return @{
        exists       = $true
        holder       = $holder
        acquired_at  = [string]$obj.acquired_at
        age_seconds  = [int]$age
        stale        = $stale
        takeover_of  = if ($obj.taken_over_from) { [string]$obj.taken_over_from } else { $null }
    }
}

function Get-SessionLabel {
    if (-not [string]::IsNullOrWhiteSpace($Session)) { return $Session }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_SESSION_ID)) { return "dsh-$env:DSH_SESSION_ID" }
    return "planner-pid$PID"
}

function Invoke-LeaseAcquire {
    param([string]$RunDir)
    $state = Get-LeaseState $RunDir
    $me = Get-SessionLabel
    if ($state.exists -and -not $state.corrupt -and -not $state.stale -and $state.holder -ne $me -and -not $Takeover) {
        Write-ErrorResult "LEASE_HELD" "Run $RunId is under an active Planner lease held by '$($state.holder)' (age $([int]($state.age_seconds/60)) min < $LeaseStaleMinutes min stale threshold). Wait, or pass -Takeover to force-take with an audit trail." 1
    }
    $p = Get-LeasePath $RunDir
    $payload = @{
        holder           = $me
        acquired_at      = Get-UtcNowIso
        taken_over_from  = $(if ($state.exists -and $state.holder -and $state.holder -ne $me) { $state.holder } else { $null })
    }
    [System.IO.File]::WriteAllText($p, (ConvertTo-Json $payload -Depth 4), $script:Utf8NoBom)
    return @{ holder = $me; taken_over_from = $payload.taken_over_from }
}

function Invoke-LeaseRelease {
    param([string]$RunDir)
    $p = Get-LeasePath $RunDir
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        Remove-Item -LiteralPath $p -Force
        return @{ released = $true }
    }
    return @{ released = $false; note = "no lease file" }
}

function Enter-PlannerLease {
    # gate for Planner-orchestration mutations (claim by a dispatched worker is exempt)
    param([string]$RunDir)
    return Invoke-LeaseAcquire $RunDir
}

function Try-PlannerLeaseForTouch {
    # non-failing lease acquire for the status touch-up push (goal-tree-goal-root):
    # when another live planner holds the lease, THEIR orchestration owns pushing —
    # return $null and status reports the skip instead of failing. Returns
    # @{ held_before = $bool } when acquired (caller releases unless it was ours).
    param([string]$RunDir)
    $state = Get-LeaseState $RunDir
    $me = Get-SessionLabel
    $wasMine = ($state.exists -and -not $state.corrupt -and $state.holder -eq $me)
    if ($state.exists -and -not $state.corrupt -and -not $state.stale -and $state.holder -ne $me) {
        return @{ acquired = $false; holder = $state.holder }
    }
    $null = Invoke-LeaseAcquire $RunDir
    return @{ acquired = $true; was_mine = $wasMine }
}

# === task.json side (via rdd-flow public CLI) ===

function Read-ArchiveTasks {
    # rdd-flow show -> @{ tasks = @(...); archive = name }; read-only
    param([string]$ArchivePath)
    $r = Invoke-RddFlow @("-Command", "show", "-Archive", $ArchivePath)
    if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) {
        Write-ErrorResult "FLOW_SHOW_FAILED" "rdd-flow show failed for $ArchivePath : $($r.text)" 2
    }
    return @{ tasks = @(Convert-ToSafeArray $r.json.data.tasks); archive = [string]$r.json.data.archive }
}

function Find-ArchiveTask {
    param($Tasks, [int]$TaskId)
    foreach ($t in $Tasks) {
        if ([int]$t.id -eq $TaskId) { return $t }
    }
    return $null
}

function Get-PhaseFromOwners {
    # Bridge-local copy of rdd-flow's write-time initialization rule (pure function;
    # the bridge never dot-sources engine internals — sync via the PhaseRoles
    # constants' cross-reference). LAST covering phase: ["QA"] -> VERIFY (standalone
    # QA task = acceptance execution); "" when the set spans phases.
    param([string[]]$Owners)
    $hit = @()
    foreach ($p in $script:PhaseOrder) {
        $roles = @($script:PhaseRoles[$p])
        $isCovered = $true
        foreach ($o in @($Owners)) { if ($roles -notcontains $o) { $isCovered = $false; break } }
        if ($isCovered) { $hit += $p }
    }
    if ($hit.Count -eq 0) { return "" }
    return $hit[-1]
}

function Resolve-InitialGroup {
    # phase-model: return EVERY bridgeable owner (currentOwners ∩ RoleOrder, chain
    # ordered) — parallel owners each get their own chain head at promulgate; the
    # single-role Resolve-InitialStage silently dropped all but the first owner,
    # losing that work. $null task.phase (legacy archive) is tolerated: the group is
    # derived from owners alone and the phase stays null (conservative degrade).
    param($Task)
    $owners = @()
    if ($null -ne $Task.currentOwners) { $owners = @($Task.currentOwners) }
    $group = @()
    foreach ($role in $script:RoleOrder) {
        if ($owners -contains $role -and $group -notcontains $role) { $group += $role }
    }
    if ($group.Count -eq 0) {
        Write-ErrorResult "TASK_STAGE_UNRESOLVED" "Task $($Task.id) currentOwners=[$($owners -join '+')] contains no bridgeable role (PM/CTO/UX/DEV/QA); route the task first" 1
    }
    return @($group)
}

function Resolve-TaskPhase {
    # task.phase when valid; inferred (last covering phase) when absent; deterministic
    # errors otherwise: PHASE_INVALID (junk enum) / GROUP_DIVERGENT_NEXT (owner set
    # spans phases — the parallel group has no single phase to advance to; first
    # version does not support fan-out).
    param($Task, [string[]]$Group)
    $stored = $null
    if ($null -ne $Task.phase -and ([string]$Task.phase) -ne "") { $stored = [string]$Task.phase }
    if ($null -ne $stored) {
        if ($script:PhaseOrder -notcontains $stored) {
            Write-ErrorResult "PHASE_INVALID" "Task $($Task.id) carries phase '$stored' not in $($script:PhaseOrder -join '/'); fix task.json (rdd-flow check) and re-promulgate" 2
        }
        $roles = @($script:PhaseRoles[$stored])
        foreach ($g in $Group) {
            if ($roles -notcontains $g) {
                Write-ErrorResult "PHASE_OWNER_MISMATCH" "Task $($Task.id) currentOwners [$($Group -join '+')] not ⊆ PhaseRoles[$stored] = [$($roles -join '+')] (whitelist hard constraint); fix task.json and re-promulgate" 2
            }
        }
        return $stored
    }
    $inferred = Get-PhaseFromOwners $Group
    if ($inferred -eq "") {
        Write-ErrorResult "GROUP_DIVERGENT_NEXT" "Task $($Task.id) currentOwners [$($Group -join '+')] spans multiple phases — the parallel group has no single next phase (fan-out unsupported in v1); split the task or fix its routing" 2
    }
    return $inferred
}

function Get-RequirementDepTaskIds {
    # infer task-level deps from the requirement doc's 依赖关系 field:
    # "依赖需求 2" / "依赖 #2" / "依赖：#1、#3" -> @(2) / @(2) / @(1,3).
    # Every id needs its own 需求/# prefix ("依赖需求 1、3" yields only @(1)).
    # Bracketed remarks are human-only and stripped BEFORE matching ("依赖：#1
    # （上游 #2 提供数据）" yields @(1), never @(1,2); an unclosed bracket makes
    # the rest of the line a remark). The canonical PM-side spec is
    # rdd-pm/references/requirement-item-template.md
    # 「依赖关系标注规范」. Ids that do not exist as tasks in this archive are
    # dropped (soft reference).
    param([string]$ArchivePath, $Task, [int[]]$AllTaskIds)
    $reqRel = [string]$Task.requirement
    if ([string]::IsNullOrWhiteSpace($reqRel)) { return @() }
    $reqAbs = Join-Path $ArchivePath ($reqRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $reqAbs -PathType Leaf)) { return @() }
    $ids = @()
    try {
        $content = [System.IO.File]::ReadAllText($reqAbs, [System.Text.Encoding]::UTF8)
        # field form: - **依赖关系**：... (same shape rdd-flow's Get-DocField matches)
        $m = [regex]::Match($content, '(?m)^\s*-\s*\*\*依赖关系\*\*[：:]\s*(.+?)\s*$')
        if ($m.Success) {
            # remark stripping: loop removes innermost （…）/(…) groups first
            # (nested remarks collapse), then an unclosed opening bracket takes
            # the rest of the line — numbers inside remarks never derive.
            $field = [string]$m.Groups[1].Value
            while ($field -match '[（(][^（）()]*[）)]') { $field = $field -replace '[（(][^（）()]*[）)]', '' }
            $field = $field -replace '[（(].*$',''
            foreach ($mm in [regex]::Matches($field, '(?:需求|#)\s*(\d+)')) {
                $n = [int]$mm.Groups[1].Value
                if (($n -ne [int]$Task.id) -and ($AllTaskIds -contains $n) -and ($ids -notcontains $n)) { $ids += $n }
            }
        }
    } catch { return @() }
    return @($ids)
}

function Read-ReviewFile {
    # requirement-review gate input (planner-requirement-review): parse + schema-
    # validate the planner session's ReviewFile (contract: planner-guide hard
    # constraint 6). Pure schema/membership checks live here; archive-state
    # consistency (deprecated tasks, merge-target survival) is adjudicated by the
    # caller. Deterministic errors (both exit 2):
    #   REVIEW_FILE_INVALID   — unparseable JSON / schema violation / field
    #                           consistency (pass carrying override|merged, both
    #                           fields on one verdict, duplicate task_id, ...).
    #                           Deprecated-task rules are enforced by the caller.
    #   REVIEW_TASK_NOT_FOUND — task_id / override entry / merge target not a
    #                           task of this archive.
    # Returns @{ reviewed_at; reviewer; verdicts = @(<deep hashtables>) }; every
    # verdict carries task_id (int), verdict (enum), reason, plus its optional
    # depends_on_override ([int]) / merged_into_task_id (int) normalized fields.
    param([string]$Path, [int[]]$AllTaskIds)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-ErrorResult "REVIEW_FILE_INVALID" "ReviewFile not found: $Path" 2
    }
    $h = $null
    try {
        $h = Convert-PSObjectToHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch {
        Write-ErrorResult "REVIEW_FILE_INVALID" "ReviewFile failed to parse as JSON: $($_.Exception.Message)" 2
    }
    if ($null -eq $h -or -not ($h -is [System.Collections.IDictionary])) {
        Write-ErrorResult "REVIEW_FILE_INVALID" "ReviewFile must be a JSON object with reviewed_at/reviewer/verdicts" 2
    }
    foreach ($k in @('reviewed_at', 'reviewer')) {
        if (-not $h.Contains($k) -or [string]::IsNullOrWhiteSpace([string]$h[$k])) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "ReviewFile missing required field: $k" 2
        }
    }
    $raw = @(Convert-ToSafeArray $h['verdicts'])
    if ($raw.Count -eq 0) {
        Write-ErrorResult "REVIEW_FILE_INVALID" "ReviewFile verdicts must be a non-empty array" 2
    }
    $verdicts = @()
    $seen = @{}
    foreach ($v in $raw) {
        $vh = Convert-PSObjectToHashtable $v
        if ($null -eq $vh -or -not ($vh -is [System.Collections.IDictionary])) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "each verdict must be a JSON object with task_id/verdict/reason" 2
        }
        foreach ($k in @('task_id', 'verdict', 'reason')) {
            if (-not $vh.Contains($k)) { Write-ErrorResult "REVIEW_FILE_INVALID" "verdict entry missing required field: $k" 2 }
        }
        $tid = 0
        try { $tid = [int]$vh['task_id'] } catch { Write-ErrorResult "REVIEW_FILE_INVALID" "verdict task_id is not an integer: $($vh['task_id'])" 2 }
        if ($tid -le 0) { Write-ErrorResult "REVIEW_FILE_INVALID" "verdict task_id must be a positive integer: $tid" 2 }
        if (-not ($AllTaskIds -contains $tid)) {
            Write-ErrorResult "REVIEW_TASK_NOT_FOUND" "verdict task_id #$tid is not a task of this archive" 2
        }
        if ($seen.Contains($tid)) { Write-ErrorResult "REVIEW_FILE_INVALID" "duplicate verdict for task #$tid" 2 }
        $seen[$tid] = $true
        $verdict = [string]$vh['verdict']
        if ($verdict -notin @('pass', 'tree_adjudicated', 'reject_return')) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid verdict '$verdict' not in pass/tree_adjudicated/reject_return" 2
        }
        if ([string]::IsNullOrWhiteSpace([string]$vh['reason'])) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid verdict carries an empty reason" 2
        }
        # field consistency: present-and-non-null is the meaningful form (a JSON
        # null is tolerated as absent — empty override arrays are meaningful)
        $hasOverride = ($vh.Contains('depends_on_override') -and $null -ne $vh['depends_on_override'])
        $hasMerged   = ($vh.Contains('merged_into_task_id') -and $null -ne $vh['merged_into_task_id'])
        if ($verdict -eq 'pass' -and ($hasOverride -or $hasMerged)) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "pass verdict for task #$tid must not carry depends_on_override/merged_into_task_id" 2
        }
        if ($hasOverride -and $hasMerged) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid carries both depends_on_override and merged_into_task_id (a merged task builds no node)" 2
        }
        if ($hasOverride) {
            $norm = @()
            foreach ($o in @(Convert-ToSafeArray $vh['depends_on_override'])) {
                $n = 0
                try { $n = [int]$o } catch { Write-ErrorResult "REVIEW_FILE_INVALID" "depends_on_override of task #$tid has a non-integer entry: $o" 2 }
                if ($n -le 0) { Write-ErrorResult "REVIEW_FILE_INVALID" "depends_on_override of task #$tid has a non-positive entry: $n" 2 }
                if ($n -eq $tid) { Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid cannot override-depend on itself" 2 }
                if (-not ($AllTaskIds -contains $n)) {
                    Write-ErrorResult "REVIEW_TASK_NOT_FOUND" "task #$tid depends_on_override entry #$n is not a task of this archive" 2
                }
                if ($norm -notcontains $n) { $norm += $n }
            }
            $vh['depends_on_override'] = @($norm)
        }
        if ($hasMerged) {
            $mt = 0
            try { $mt = [int]$vh['merged_into_task_id'] } catch { Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid merged_into_task_id is not an integer: $($vh['merged_into_task_id'])" 2 }
            if ($mt -le 0) { Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid merged_into_task_id must be positive: $mt" 2 }
            if ($mt -eq $tid) { Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid cannot merge into itself" 2 }
            if (-not ($AllTaskIds -contains $mt)) {
                Write-ErrorResult "REVIEW_TASK_NOT_FOUND" "task #$tid merged_into_task_id #$mt is not a task of this archive" 2
            }
            $vh['merged_into_task_id'] = $mt
        }
        $verdicts += $vh
    }
    return @{ reviewed_at = [string]$h['reviewed_at']; reviewer = [string]$h['reviewer']; verdicts = $verdicts }
}

# === Tree side (via goal-tree public CLI) ===

function Get-TreeStatusView {
    param([string]$Id)
    $r = Invoke-GoalTree @("-Command", "status", "-RunId", $Id)
    if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) {
        Write-ErrorResult "TREE_STATUS_FAILED" "goal-tree status failed: $($r.text)" 3
    }
    return $r.json.data
}

function Get-LeafNextView {
    param([string]$Id)
    $r = Invoke-GoalTreeLeaf @("-Command", "next", "-RunId", $Id)
    if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) {
        return $null
    }
    return $r.json.data
}

function Get-NodeFromTree {
    param($TreeData, [string]$NodeId)
    foreach ($bucket in @("pending", "done", "pruned")) {
        foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.$bucket)) {
            if ($n -is [string] -and $n -eq $NodeId) { return @{ id = $n; status = $bucket } }
        }
    }
    foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.claimed)) { if ($n.id -eq $NodeId) { return $n } }
    foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.reported)) { if ($n.id -eq $NodeId) { return $n } }
    return $null
}

function Get-NodeViewState {
    # Status-normalized node lookup (planner-auto-mode): the tree status view's
    # claimed/reported buckets carry rich objects WITHOUT a status field (bucket
    # membership IS the status there), while pending/done/pruned are bare id
    # strings — Get-NodeFromTree passes both shapes through raw. This helper
    # always resolves @{ status; claimed_by } (or $null when absent).
    param($TreeData, [string]$NodeId)
    foreach ($bucket in @("pending", "done", "pruned")) {
        foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.$bucket)) {
            if (($n -is [string] -and $n -eq $NodeId) -or ($null -ne $n -and $n -isnot [string] -and [string]$n.id -eq $NodeId)) {
                return @{ status = $bucket; claimed_by = $null }
            }
        }
    }
    foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.claimed)) {
        if ($null -ne $n -and [string]$n.id -eq $NodeId) { return @{ status = "claimed"; claimed_by = [string]$n.claimed_by } }
    }
    foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.reported)) {
        if ($null -ne $n -and [string]$n.id -eq $NodeId) { return @{ status = "reported"; claimed_by = $null } }
    }
    return $null
}

function Get-NodePruneReason {
    # Read-only probe of state/tree.json for one node's pruned_reason. The leaf
    # status view omits pruned_reason (slim serializer) while the rollback
    # resume guard needs the prune signature. Same direct-state-file read
    # precedent as Read-LedgerEntries / claim liveness (the bridge never
    # WRITES engine state). Returns "" when the node/reason is absent, $null
    # when no readable tree file carries the node.
    param([string]$RunDir, [string]$NodeId)
    foreach ($f in @((Join-Path $RunDir "state/tree.json"), (Join-Path $RunDir "state/tree.json.bak"))) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        try {
            $obj = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch { continue }
        foreach ($n in @(Convert-ToSafeArray $obj.nodes)) {
            if ([string]$n.id -ne $NodeId) { continue }
            if ($null -ne $n.PSObject.Properties['pruned_reason'] -and $n.pruned_reason) { return [string]$n.pruned_reason }
            return ""
        }
    }
    return $null
}

function Read-LedgerEntries {
    param([string]$RunDir)
    $p = Join-Path (Join-Path $RunDir "state") "ledger.jsonl"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    $entries = @()
    foreach ($line in @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })) {
        try { $entries += ,($line | ConvertFrom-Json) } catch {}
    }
    return $entries
}

function Find-AcceptedCallback {
    # the node's last accepted ledger entry (matches node.ledger_refs[-1])
    param([string]$RunDir, $Node)
    $refs = @(Convert-ToSafeArray $Node.ledger_refs)
    if ($refs.Count -eq 0) { return $null }
    $want = [string]$refs[-1]
    foreach ($e in (Read-LedgerEntries $RunDir)) {
        if ([string]$e.entry_id -eq $want) { return $e }
    }
    return $null
}

function Write-TempTasksFile {
    # graft payloads carry Chinese task text; command-line -Tasks would mangle the
    # encoding through the cmd -> powershell -File hop (engine convention: -TasksFile)
    param($Items)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-graft-{0}.json" -f ([guid]::NewGuid().ToString("N").Substring(0, 10)))
    [System.IO.File]::WriteAllText($p, (ConvertTo-Json @($Items) -Depth 8), $script:Utf8NoBom)
    return $p
}

function Invoke-GraftOne {
    # graft exactly one node; returns @{ ok; node_id; text }
    param([string]$Id, [string]$ParentNodeId, $GraftItem)
    $tf = Write-TempTasksFile @($GraftItem)
    try {
        $r = Invoke-GoalTree @("-Command", "graft", "-RunId", $Id, "-Parent", $ParentNodeId, "-TasksFile", $tf)
    }
    finally {
        Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
    }
    if ($r.exit -ne 0 -or -not $r.json.success) { return @{ ok = $false; node_id = $null; text = $r.text } }
    return @{ ok = $true; node_id = [string]$r.json.data.grafted[0].id; text = $r.text }
}

function Get-DeferredEdgesForNode {
    # Deferred review-edge stitching for ONE grafted chain-head node
    # (Invoke-Promulgate step 3b): single-pass graft can only express deps on
    # already-grafted nodes (task order); when the planner's override or a
    # merge-redirect points at a task grafted LATER, the edge is re-added here
    # via the public deps CLI (DAG-validated, deps-log audited) instead of
    # silently vanishing. Returns the edges actually added.
    param([string]$RunId, [int]$TaskId, [string]$NodeId, $ExplicitDeps, $GraftedDepNodes, $InitialNodesOfTask)
    $edges = @()
    foreach ($d in @($ExplicitDeps)) {
        if (-not $InitialNodesOfTask.ContainsKey([int]$d)) { continue }
        foreach ($on in @($InitialNodesOfTask[[int]$d])) {
            if (@($GraftedDepNodes) -contains $on) { continue }
            $r = Invoke-GoalTree @("-Command", "deps", "-DepAction", "add", "-RunId", $RunId, "-NodeId", $NodeId, "-On", $on)
            if ($r.exit -ne 0 -or -not $r.json.success) {
                Write-ErrorResult "PROMULGATE_DEP_FAILED" "deferred review dep stitch failed for task $TaskId -> task $d ($NodeId -> $on): $($r.text)" 3
            }
            $edges += @{ task_id = $TaskId; on_task_id = [int]$d; node = $NodeId; on = $on }
        }
    }
    return $edges
}

# === Acceptance chain (overall-delivery: integration + whole-requirement acceptance) ===
#
# Long-task split deliveries keep the ORIGINAL requirement's end-to-end objective:
# the archive's requirements/overview.md carries a fixed `## 整体验收判据` section
# (whole-requirement acceptance criteria: perceivable end-to-end scenario +
# verifiable form + covered sub-requirements). The criteria reference rides every
# node task text and the goal root (the dispatch-record check point), and after
# ALL sub-requirement nodes settle a two-node tree-level acceptance chain grafts
# under the goal root: [集成/联调] (DEV, real cross-module integration) -> settle
# -> [整体验收] (QA, per-criterion verification of the real chain) -> settle
# records the verdict (tests/integration-acceptance.md §3 总结论 must be
# decidable: 通过 / 不通过). conclude achieved is gated on that verdict.
# Tree-level nodes (no TaskId) share one branch across claim / settle / push.

$script:AcceptanceCriteriaHeading = "整体验收判据"
$script:AcceptanceReportRel = "tests/integration-acceptance.md"
$script:AcceptanceConclusionPattern = '(?m)^\s*总结论[：:]\s*(通过|不通过)\s*$'
$script:AcceptanceChainSpecs = @(
    @{ kind = "integrate"; title = "[集成/联调]"; node_key = "integrate_node"; role_key = "integrate_role"; role = "DEV"
       mission = "使命：全部子任务完成后的真实串联集成/联调——各模块数据/调用互相衔接，端到端跑通原始需求完整场景（不是各模块独立跑通子验收）。交付记录：tests/integration-acceptance.md §1 集成/联调记录（引用回调账本条目，不复制）。" }
    @{ kind = "accept"; title = "[整体验收]"; node_key = "accept_node"; role_key = "accept_role"; role = "QA"
       mission = "使命：对照整体验收判据逐条核验真实链路（数据/调用真实衔接），产出「通过/不通过」整体验收结论与失败点。交付记录：tests/integration-acceptance.md（§2 判据逐条核验表、§3 总结论——必须以一行『总结论：通过』或『总结论：不通过』收口）。" }
)

function Get-AcceptanceSection {
    # bridge.json acceptance section (deep hashtable after Read-Bridge); $null on
    # legacy runs — every caller degrades to byte-identical legacy behavior then.
    param($Bridge)
    if ($null -eq $Bridge) { return $null }
    if (-not (Test-PropPresent $Bridge 'acceptance')) { return $null }
    return $Bridge['acceptance']
}

function Read-AcceptanceCriteria {
    # Parse the archive's fixed criteria section (requirements/overview.md
    # `## 整体验收判据`, the stable reference anchor). Returns
    # @{ mode = criteria|declared|absent; criteria_ref; declaration; text } —
    # 'declared' = the explicit "无整体判据（理由：…）" exit (decision 7).
    param([string]$ArchivePath)
    $none = @{ mode = "absent"; criteria_ref = $null; declaration = $null; text = "" }
    $overview = Join-Path $ArchivePath "requirements/overview.md"
    if (-not (Test-Path -LiteralPath $overview -PathType Leaf)) { return $none }
    $content = [System.IO.File]::ReadAllText($overview, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($content, '(?ms)^##[ \t]*整体验收判据[ \t]*\r?\n(.*?)(?=^##[ \t]|\z)')
    if (-not $m.Success) { return $none }
    $body = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { return $none }
    $first = @($body -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0]
    if ($first -match '^\s*无整体判据') {
        return @{ mode = "declared"; criteria_ref = $null; declaration = $body; text = $body }
    }
    return @{ mode = "criteria"; criteria_ref = "requirements/overview.md#$($script:AcceptanceCriteriaHeading)"; declaration = $null; text = $body }
}

function New-AcceptanceSection {
    # bridge.json acceptance placeholder written at promulgate (planned -> grafted
    # -> conclusion). The >=2 sub-requirement gate (archive-rules tiering) hard-
    # fails ACCEPTANCE_CRITERIA_MISSING BEFORE any run state exists; single-
    # requirement archives are exempt (their acceptance criteria ARE the whole).
    param($Criteria, [int]$RequirementCount)
    $section = @{
        status = "none"; basis = "single_exempt"; criteria_ref = $null
        declaration = $null; report = $script:AcceptanceReportRel
        integrate_node = $null; integrate_role = "DEV"
        accept_node = $null; accept_role = "QA"
        conclusion = $null; recorded_at = $null
    }
    switch ([string]$Criteria.mode) {
        "criteria" {
            $section.status = "planned"; $section.basis = "criteria"
            $section.criteria_ref = [string]$Criteria.criteria_ref
        }
        "declared" {
            $section.basis = "declared_none"; $section.declaration = [string]$Criteria.declaration
        }
        default {
            if ($RequirementCount -ge 2) {
                Write-ErrorResult "ACCEPTANCE_CRITERIA_MISSING" "requirements/overview.md is missing the fixed '## 整体验收判据' section (>=2 sub-requirements: the whole-requirement acceptance criteria are mandatory). Fix: add criteria entries (user-perceivable end-to-end scenario + verifiable form + covered sub-requirements) per overview-template.md, or explicitly declare '无整体判据（理由：…）' when no whole scenario exists. Nothing was created." 1
            }
        }
    }
    return $section
}

function Get-AcceptanceNodeInfo {
    # tree-level acceptance node -> @{ kind; role; chain }; $null when the node is not
    # one of the run's chain nodes. The unified tree-level branch probes this
    # right after the bridge mapping lookup misses (claim / settle / push).
    param($Bridge, [string]$NodeId)
    $a = Get-AcceptanceSection $Bridge
    if ($null -eq $a) { return $null }
    foreach ($spec in @($script:AcceptanceChainSpecs)) {
        if ((Test-PropPresent $a $spec.node_key) -and [string]$a[$spec.node_key] -eq $NodeId) {
            $role = [string]$spec.role
            if ((Test-PropPresent $a $spec.role_key) -and $a[$spec.role_key]) { $role = [string]$a[$spec.role_key] }
            return @{ kind = [string]$spec.kind; role = $role; chain = $true }
        }
    }
    return $null
}

function Read-TreeFullNode {
    # full node object from state/tree.json (the status view reduces nodes to
    # bare {id,status} — type/role live only in the full state).
    param([string]$RunDir, [string]$NodeId)
    $treeFilePath = Join-Path (Join-Path $RunDir "state") "tree.json"
    if (-not (Test-Path -LiteralPath $treeFilePath -PathType Leaf)) { return $null }
    try {
        $fullTree = [System.IO.File]::ReadAllText($treeFilePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return @($fullTree.nodes | Where-Object { [string]$_.id -eq $NodeId })[0]
    } catch { return $null }
}

function Get-TreeLevelInfo {
    # The unified tree-level branch (design risk map: 验收节点+树内修复节点复用):
    # acceptance chain nodes first (kind/role + acceptance context), then stage
    # acceptance nodes (long-task-planning), then any other non-goal tree node
    # carrying a role (in-tree repair node, graft 下探).
    # $null = not a tree-level delivery node (structural root / unknown id).
    param($Bridge, [string]$RunDir, [string]$NodeId)
    $info = Get-AcceptanceNodeInfo $Bridge $NodeId
    if ($null -ne $info) { return $info }
    $sa = Get-StageAcceptanceNodeInfo $Bridge $NodeId
    if ($null -ne $sa) { return $sa }
    $dr = Get-DesignReviewNodeInfo $Bridge $NodeId
    if ($null -ne $dr) { return $dr }
    $node = Read-TreeFullNode $RunDir $NodeId
    if ($null -eq $node -or [string]$node.type -eq 'goal') { return $null }
    $r = ""
    if ($node.role) { $r = [string]$node.role }
    if (-not $r) { return $null }
    return @{ kind = "repair"; role = $r.ToUpper(); chain = $false }
}

function Read-AcceptanceConclusion {
    # The ACCEPT verdict lives in the archive's tests/integration-acceptance.md
    # §3 ("总结论：通过/不通过" on its own line). $null = not decidable yet.
    param([string]$ArchivePath)
    $p = Join-Path $ArchivePath $script:AcceptanceReportRel
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $content = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($content, $script:AcceptanceConclusionPattern)
    if (-not $m.Success) { return $null }
    return [string]$m.Groups[1].Value
}

function Test-AllMappedNodesTerminal {
    # "全部子任务 settle" (the timing expression): every bridge-mapped delivery
    # node is terminal (done / pruned). Tree-level chain nodes never gate here.
    param([string]$RunId, $Bridge)
    $treeData = Get-TreeStatusView $RunId
    foreach ($nodeId in @($Bridge.nodes.Keys)) {
        $node = Get-NodeFromTree $treeData ([string]$nodeId)
        $status = if ($node) { [string]$node.status } else { "missing" }
        if (@("done", "pruned") -notcontains $status) { return $false }
    }
    return $true
}

function New-AcceptanceChainGraftItem {
    # graft payload for ONE tree-level chain node (title/task/role/ref); the task
    # text still flows through New-NodeTaskText (sole producer) with the mission
    # and criteria-reference segments.
    param($Spec, [string]$ReqRel, [string]$AcceptanceRef, [string]$RunId)
    $taskText = New-NodeTaskText -Title ([string]$Spec.title) -Stage ([string]$Spec.role) -ReqRel $ReqRel `
        -DesignRels @() -RunId $RunId -AcceptanceRef $AcceptanceRef -Mission ([string]$Spec.mission)
    return @{
        title = [string]$Spec.title
        task  = $taskText
        role  = ([string]$Spec.role).ToLower()
        ref   = "$(($RunId -replace '^deliver-', ''))/$ReqRel"
    }
}

function Update-AcceptanceChain {
    # Timing-expression state machine (idempotent, rides every auto-dispatch
    # trigger so a crash window self-heals): planned -> graft [集成/联调] when all
    # sub-requirement nodes are terminal -> graft [整体验收] once the integrate
    # node settles -> record the §3 conclusion once the accept node settles.
    param([string]$RunDir, $Bridge)
    $a = Get-AcceptanceSection $Bridge
    $out = @{ bridge = $Bridge; grafted = @(); recorded = $null }
    if ($null -eq $a) { return $out }
    $status = [string]$a['status']
    if (@("planned", "grafted") -notcontains $status) { return $out }
    if ($status -eq "planned") {
        if (-not (Test-AllMappedNodesTerminal ([string]$Bridge.run_id) $Bridge)) { return $out }
        $spec = @($script:AcceptanceChainSpecs | Where-Object { $_.kind -eq "integrate" })[0]
        $item = New-AcceptanceChainGraftItem $spec "requirements/overview.md" ([string]$a['criteria_ref']) ([string]$Bridge.run_id)
        $g = Invoke-GraftOne ([string]$Bridge.run_id) ([string]$Bridge.goal_root) $item
        if (-not $g.ok) { $out.error = "acceptance chain graft failed (retries on next trigger): $($g.text)"; return $out }
        $a['integrate_node'] = $g.node_id; $a['status'] = "grafted"
        $Bridge['acceptance'] = $a
        Write-BridgeFile $RunDir $Bridge | Out-Null
        $out.bridge = $Bridge
        $out.grafted += $g.node_id
        return $out
    }
    return Update-AcceptanceChainTail $RunDir $Bridge $a $out
}

function Update-AcceptanceChainTail {
    # grafted-state tail: graft [整体验收] after the integrate node settles, then
    # record the decidable §3 conclusion after the accept node settles.
    param([string]$RunDir, $Bridge, $A, $Out)
    $treeData = Get-TreeStatusView ([string]$Bridge.run_id)
    $integrate = Get-NodeFromTree $treeData ([string]$A['integrate_node'])
    $integrateDone = ($null -ne $integrate -and [string]$integrate.status -eq "done")
    if ($integrateDone -and -not ([string]$A['accept_node'])) {
        $spec = @($script:AcceptanceChainSpecs | Where-Object { $_.kind -eq "accept" })[0]
        $item = New-AcceptanceChainGraftItem $spec "requirements/overview.md" ([string]$A['criteria_ref']) ([string]$Bridge.run_id)
        $g = Invoke-GraftOne ([string]$Bridge.run_id) ([string]$Bridge.goal_root) $item
        if (-not $g.ok) { $Out.error = "acceptance chain graft failed (retries on next trigger): $($g.text)"; return $Out }
        $A['accept_node'] = $g.node_id
        $Bridge['acceptance'] = $A
        Write-BridgeFile $RunDir $Bridge | Out-Null
        $Out.bridge = $Bridge
        $Out.grafted += $g.node_id
        return $Out
    }
    if (([string]$A['accept_node']) -and -not ([string]$A['conclusion'])) {
        $accept = Get-NodeFromTree $treeData ([string]$A['accept_node'])
        if ($null -ne $accept -and [string]$accept.status -eq "done") {
            $verdict = Read-AcceptanceConclusion ([string]$Bridge.archive)
            if ($null -ne $verdict) {
                $A['conclusion'] = $verdict; $A['recorded_at'] = Get-UtcNowIso
                $Bridge['acceptance'] = $A
                Write-BridgeFile $RunDir $Bridge | Out-Null
                $Out.bridge = $Bridge
                $Out.recorded = $verdict
            }
        }
    }
    return $Out
}

function Get-AcceptanceGateVerdict {
    # conclude hard gate (overall-delivery): the ACCEPT conclusion must be
    # decidable AND 通过 before any goal-anchor work. A settled accept node whose
    # §3 was written later is re-read here (fix the report, re-run conclude —
    # the chain never needs a re-settle). Returns @{ ok; code; message }.
    param($Bridge, [string]$ArchivePath)
    $a = Get-AcceptanceSection $Bridge
    if ($null -eq $a -or ([string]$a['status']) -eq "none") { return @{ ok = $true } }
    $conclusion = $null
    if ((Test-PropPresent $a 'conclusion') -and $a['conclusion']) { $conclusion = [string]$a['conclusion'] }
    if ($null -eq $conclusion) { $conclusion = Read-AcceptanceConclusion $ArchivePath }
    if ($null -eq $conclusion) {
        return @{ ok = $false; code = "ACCEPTANCE_PENDING"; message = "The whole-requirement acceptance conclusion is not decidable yet (acceptance status='$([string]$a['status'])'). Make sure every sub-requirement settled and both tree-level nodes ([集成/联调] -> [整体验收]) settled, then write one line '总结论：通过' or '总结论：不通过' into $($script:AcceptanceReportRel) §3 and re-run conclude." }
    }
    if ($conclusion -ne "通过") {
        return @{ ok = $false; code = "ACCEPTANCE_NOT_PASSED"; message = "Whole-requirement acceptance verdict is '$conclusion' — conclude achieved is refused. Failure points live in $($script:AcceptanceReportRel) §2 (the coverage mapping locates the responsible task chains); repair those task chains and re-run (the complete rework loop is out of this requirement's scope — overall-delivery boundary) before concluding." }
    }
    return @{ ok = $true; conclusion = $conclusion }
}

function Add-AcceptanceAnnexLines {
    # the annex's「整体验收结论」区 (planner-guide): criteria ref + chain node ids
    # + report pointer + verdict, rendered honestly incl. 不通过 failure pointers.
    param($Bridge, [string]$Conclusion)
    $lines = @()
    $lines += "## 整体验收结论"
    $lines += ""
    $a = Get-AcceptanceSection $Bridge
    if ($null -eq $a) {
        $lines += "- 整体验收判据: （无 acceptance 段——引入前的旧 run）"
    }
    elseif (([string]$a['status']) -eq "none") {
        $basisNote = [string]$a['basis']
        if ([string]$a['declaration']) { $basisNote += "：" + (([string]$a['declaration']) -replace '\|', '/') }
        $lines += "- 整体验收判据: 无（$basisNote）"
    }
    else {
        $lines += "- 判据: $([string]$a['criteria_ref'])"
        $lines += "- 验收链: [集成/联调] $([string]$a['integrate_node'])（$([string]$a['integrate_role'])）→ [整体验收] $([string]$a['accept_node'])（$([string]$a['accept_role'])）"
        $lines += "- 交付记录: $($script:AcceptanceReportRel)（§1 集成/联调记录 · §2 判据逐条核验表 · §3 总结论）"
        $verdictText = "不可判（§3 缺『总结论：通过/不通过』）"
        $verdictSuffix = ""
        if ($Conclusion) {
            $verdictText = $Conclusion
            if ($Conclusion -eq "不通过") { $verdictSuffix = "（失败点见交付记录 §2 覆盖映射）" }
        }
        $lines += "- 总结论: $verdictText$verdictSuffix"
    }
    $lines += ""
    return $lines
}

# === Long-task plan (long-task-planning: staged plan + rolling tracking) ===
#
# Three carriers, one authority split (planner-guide「长程规划与滚动追踪」):
#   PlanFile        promulgate/replan -PlanFile intake: staged plan — stages
#                   (goal/milestone/task_ids) + per-stage parallel batches +
#                   per-stage acceptance point (criteria subset + runnable
#                   slice) + initial risks. Validated at intake, never edited
#                   in place afterwards (corrections arrive as revised files).
#   bridge.json plan section  machine-readable CURRENT state (acceptance_point
#                   status/node + revision counter) — what status/resume render
#                   and what the stage gate consults.
#   plan-log.jsonl  append-only event ledger (P<n>: progress / deviation /
#                   revision) — the sole cross-session progress/risk record;
#                   a new planner session anchors on the run dir and gets the
#                   whole history without conversation memory (decisions.jsonl
#                   paradigm: run .lock append + read-back finish; bad lines
#                   quarantined to plan-log.jsonl.corrupt).
# Authority: task dependency ORDER lives in the goal-tree DAG (requirement
# deps + ReviewFile overrides). The plan only annotates topological batches —
# contradictions are rejected (PLAN_ORDER_INVALID / PLAN_BATCH_INVALID), never
# silently reconciled into a second dependency table.
# Stage gate (只增不减): a delivery node pushes/claims only after EVERY earlier
# stage's acceptance point passed; blocked = deterministic NODE_BLOCKED_BY_GATE.
# Stage acceptance point: stage task_ids all terminal (by TASK lifecycle;
# non-delivered ids — deprecated / in-tree merged / rejected-back — are exempt)
# -> graft tree-level [集成验收·S<k>] (role=QA under the goal root, k<K) /
# bind the R1 accept node (k=K) / auto-pass (k=K without a whole-requirement
# chain) -> node settled -> passed. Rollback/reclaim/reset of a covered task
# rolls the acceptance wave back to planned (防闸门虚开) and re-verification
# re-grafts a fresh node.

$script:PlanStageAcceptanceFmt = "[集成验收·{0}]"
$script:PlanLogFileName = "plan-log.jsonl"
$script:PlanTerminalLifecycles = @("completed", "deprecated")

function Get-PlanLogPath { param([string]$RunDir); Join-Path $RunDir $script:PlanLogFileName }
function Get-PlanLogCorruptPath { param([string]$RunDir); (Get-PlanLogPath $RunDir) + ".corrupt" }

function Get-PlanSection {
    # bridge.json `plan` section or $null (legacy runs: no plan view, no gate).
    param($Bridge)
    if ($null -eq $Bridge) { return $null }
    if (-not (Test-PropPresent $Bridge 'plan')) { return $null }
    return $Bridge['plan']
}

function Read-PlanLogEntries {
    # plan-log.jsonl -> @{ entries; bad }. Bad lines stay in place until the
    # next append quarantines them (ledger paradigm: nothing is lost).
    param([string]$RunDir)
    $p = Get-PlanLogPath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ entries = @(); bad = @() } }
    $entries = @(); $bad = @()
    foreach ($line in @([System.IO.File]::ReadAllLines($p))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $e = $null
        try { $e = Convert-PSObjectToHashtable ($line | ConvertFrom-Json) } catch { }
        if ($null -ne $e -and $e -is [System.Collections.IDictionary]) { $entries += ,$e }
        else { $bad += ,$line }
    }
    return @{ entries = @($entries); bad = @($bad) }
}

function Add-PlanLogEntry {
    # THE plan-log append chain (run .lock -> quarantine bad lines -> P<n> id ->
    # append -> read-back finish -> unlock; decisions.jsonl paradigm).
    param([string]$RunDir, $Entry)
    $lockInfo = Enter-BridgeRunLock $RunDir
    try {
        $p = Get-PlanLogPath $RunDir
        $good = @(); $bad = @()
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            foreach ($line in @([System.IO.File]::ReadAllLines($p))) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $ok = $false
                try { $null = $line | ConvertFrom-Json; $ok = $true } catch { }
                if ($ok) { $good += ,$line } else { $bad += ,$line }
            }
        }
        if ($bad.Count -gt 0) {
            $wrapped = @()
            foreach ($b in $bad) { $wrapped += ,('{"at":"' + (Get-UtcNowIso) + '","raw":' + (ConvertTo-Json ([string]$b) -Compress) + '}') }
            [System.IO.File]::AppendAllText((Get-PlanLogCorruptPath $RunDir), (($wrapped) -join "`n") + "`n", $script:Utf8NoBom)
            [System.IO.File]::WriteAllText($p, $(if ($good.Count -gt 0) { (($good) -join "`n") + "`n" } else { "" }), $script:Utf8NoBom)
        }
        $Entry['entry_id'] = "P$($good.Count + 1)"
        [System.IO.File]::AppendAllText($p, (ConvertTo-Json $Entry -Depth 8 -Compress) + "`n", $script:Utf8NoBom)
        $check = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })
        try { $null = $check[-1] | ConvertFrom-Json } catch {
            Write-ErrorResult "PLAN_LOG_READBACK_FAILED" "plan-log.jsonl last line failed to parse after append" 3
        }
    }
    finally {
        Exit-BridgeRunLock
    }
    $Entry['lock'] = $lockInfo
    return $Entry
}

function Add-PlanEvent {
    # one plan-log event: kind=progress (settle/acceptance) | deviation (the
    # five detection points) | revision (replan). Detail is free-form context.
    param([string]$RunDir, [string]$Kind, [string]$EventName, [string]$Node, $TaskId, [string]$Stage, $Detail)
    $entry = [ordered]@{
        at      = Get-UtcNowIso
        run_id  = $RunId
        kind    = $Kind
        event   = $EventName
        node    = $(if (-not [string]::IsNullOrWhiteSpace($Node)) { $Node } else { $null })
        task_id = $TaskId
        stage   = $(if (-not [string]::IsNullOrWhiteSpace($Stage)) { $Stage } else { $null })
        detail  = $Detail
    }
    return Add-PlanLogEntry $RunDir $entry
}

function ConvertTo-PlanIntList {
    # int list shape check (positive, no duplicates) shared by task_ids/batches.
    param($Value, [string]$Label)
    $out = @(); $seen = @{}
    foreach ($v in @(Convert-ToSafeArray $Value)) {
        $n = 0
        try { $n = [int]$v } catch { Write-ErrorResult "PLAN_FILE_INVALID" "$Label has a non-integer entry: $v" 2 }
        if ($n -le 0) { Write-ErrorResult "PLAN_FILE_INVALID" "$Label has a non-positive entry: $n" 2 }
        if ($seen.Contains($n)) { Write-ErrorResult "PLAN_FILE_INVALID" "$Label repeats task #$n" 2 }
        $seen[$n] = $true
        $out += $n
    }
    return @($out)
}

function ConvertTo-PlanAcceptance {
    # acceptance_point shape (要素齐全: criteria subset + runnable slice; the
    # criteria_ref slot is validated against the archive by Test-PlanCriteriaRef).
    param($RawAp, [string]$StageId)
    $ap = Convert-PSObjectToHashtable $RawAp
    if ($null -eq $ap -or -not ($ap -is [System.Collections.IDictionary])) {
        Write-ErrorResult "PLAN_FILE_INVALID" "stage $StageId acceptance_point must be an object with criteria_items + slice (要素齐全)" 2
    }
    $items = @()
    foreach ($i in @(Convert-ToSafeArray $ap['criteria_items'])) {
        if ([string]::IsNullOrWhiteSpace([string]$i)) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $StageId acceptance_point.criteria_items entries must be non-empty strings" 2 }
        $items += [string]$i
    }
    if ($items.Count -eq 0) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $StageId acceptance_point.criteria_items must be non-empty (判据子集覆盖本阶段子需求映射)" 2 }
    if (-not $ap.Contains('slice') -or [string]::IsNullOrWhiteSpace([string]$ap['slice'])) {
        Write-ErrorResult "PLAN_FILE_INVALID" "stage $StageId acceptance_point.slice must be a non-empty string (可运行整体切片形态)" 2
    }
    $ref = $null
    if ($ap.Contains('criteria_ref') -and $null -ne $ap['criteria_ref'] -and -not [string]::IsNullOrWhiteSpace([string]$ap['criteria_ref'])) {
        $ref = [string]$ap['criteria_ref']
    }
    return @{ criteria_ref = $ref; criteria_items = $items; slice = [string]$ap['slice']; node = $null; status = "planned" }
}

function ConvertTo-PlanRisk {
    param($RawRisk)
    $r = Convert-PSObjectToHashtable $RawRisk
    if ($null -eq $r -or -not ($r -is [System.Collections.IDictionary]) -or [string]::IsNullOrWhiteSpace([string]$r['risk'])) {
        Write-ErrorResult "PLAN_FILE_INVALID" "each risk must be an object with a non-empty risk string" 2
    }
    $level = "P2"
    if (-not [string]::IsNullOrWhiteSpace([string]$r['level'])) {
        $level = ([string]$r['level']).ToUpper()
        if (@("P1", "P2", "P3") -notcontains $level) { Write-ErrorResult "PLAN_FILE_INVALID" "risk '$([string]$r['risk'])' level must be P1/P2/P3 (P1 对齐 auto-mode 人工分级)" 2 }
    }
    return @{ risk = [string]$r['risk']; level = $level; note = $(if ($r.Contains('note')) { [string]$r['note'] } else { "" }) }
}

function ConvertTo-PlanStage {
    # one PlanFile stage entry -> normalized hashtable; stage identity and
    # shape live here, DAG fit later (Test-PlanDeliveryFit).
    param($RawStage, $SeenIds)
    $s = Convert-PSObjectToHashtable $RawStage
    if ($null -eq $s -or -not ($s -is [System.Collections.IDictionary])) {
        Write-ErrorResult "PLAN_FILE_INVALID" "each stage must be a JSON object with id/goal/milestone/task_ids/batches/acceptance_point" 2
    }
    foreach ($k in @('id', 'goal', 'milestone', 'task_ids', 'batches', 'acceptance_point')) {
        if (-not $s.Contains($k) -or $null -eq $s[$k]) { Write-ErrorResult "PLAN_FILE_INVALID" "stage entry missing required field: $k" 2 }
    }
    $sid = ([string]$s['id']).Trim()
    if ([string]::IsNullOrWhiteSpace($sid)) { Write-ErrorResult "PLAN_FILE_INVALID" "stage id must be a non-empty string (e.g. S1)" 2 }
    if ($SeenIds.Contains($sid)) { Write-ErrorResult "PLAN_FILE_INVALID" "duplicate stage id: $sid" 2 }
    $SeenIds[$sid] = $true
    foreach ($k in @('goal', 'milestone')) {
        if ([string]::IsNullOrWhiteSpace([string]$s[$k])) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $sid $k must be a non-empty string (要素齐全 ≠ 篇幅，一句话即可)" 2 }
    }
    $taskIds = @(ConvertTo-PlanIntList $s['task_ids'] "stage $sid task_ids")
    if ($taskIds.Count -eq 0) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $sid task_ids must be a non-empty int array" 2 }
    $batches = @()
    foreach ($b in @(Convert-ToSafeArray $s['batches'])) {
        $batch = @(ConvertTo-PlanIntList $b "stage $sid batches")
        if ($batch.Count -eq 0) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $sid batches must not contain empty batches" 2 }
        $batches += ,$batch
    }
    if ($batches.Count -eq 0) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $sid batches must be a non-empty array of task-id batches (可并行批次, R2 消费口)" 2 }
    return @{
        id = $sid; goal = [string]$s['goal']; milestone = [string]$s['milestone']
        task_ids = $taskIds; batches = $batches
        acceptance_point = ConvertTo-PlanAcceptance $s['acceptance_point'] $sid
    }
}

function Read-PlanFile {
    # PlanFile contract (planner-guide「长程规划与滚动追踪」): parse + schema
    # validation (PLAN_FILE_INVALID). DAG fit is Test-PlanDeliveryFit's job.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-ErrorResult "PLAN_FILE_INVALID" "PlanFile not found: $Path" 2
    }
    $h = $null
    try { $h = Convert-PSObjectToHashtable ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch { Write-ErrorResult "PLAN_FILE_INVALID" "PlanFile failed to parse as JSON: $($_.Exception.Message)" 2 }
    if ($null -eq $h -or -not ($h -is [System.Collections.IDictionary]) -or -not $h.Contains('stages')) {
        Write-ErrorResult "PLAN_FILE_INVALID" "PlanFile must be a JSON object with a stages array" 2
    }
    $rawStages = @(Convert-ToSafeArray $h['stages'])
    if ($rawStages.Count -eq 0) { Write-ErrorResult "PLAN_FILE_INVALID" "PlanFile stages must be a non-empty array (要素齐全: 阶段目标/里程碑/集成验收点/任务依赖排序/可并行批次)" 2 }
    $stages = @(); $seenIds = @{}
    foreach ($raw in $rawStages) { $stages += ,(ConvertTo-PlanStage $raw $seenIds) }
    $risks = @()
    foreach ($raw in @(Convert-ToSafeArray $h['risks'])) { $risks += ,(ConvertTo-PlanRisk $raw) }
    return @{
        planned_at = $(if ($h.Contains('planned_at') -and -not [string]::IsNullOrWhiteSpace([string]$h['planned_at'])) { [string]$h['planned_at'] } else { Get-UtcNowIso })
        planner    = $(if ($h.Contains('planner') -and -not [string]::IsNullOrWhiteSpace([string]$h['planner'])) { [string]$h['planner'] } else { "planner" })
        stages     = $stages
        risks      = $risks
    }
}

function Test-PlanStageOrder {
    # stage sequence vs DAG: a dependency must sit in a STRICTLY earlier stage
    # than its dependent (same stage is legal — batches carry that finer order).
    param($Plan, $StageOfTask, $DepMap)
    $index = @{}
    $i = 0
    foreach ($st in @($Plan.stages)) { $index[[string]$st.id] = $i; $i++ }
    foreach ($tid in @($StageOfTask.Keys)) {
        $deps = @(Convert-ToSafeArray $DepMap[$tid])
        $myIndex = [int]$index[[string]$StageOfTask[$tid]]
        foreach ($d in $deps) {
            if (-not $StageOfTask.Contains([int]$d)) { continue }   # exempt dep (not delivered here)
            $depIndex = [int]$index[[string]$StageOfTask[[int]$d]]
            if ($depIndex -gt $myIndex) {
                Write-ErrorResult "PLAN_ORDER_INVALID" "task #$tid (stage $($StageOfTask[$tid])) depends on task #$d (stage $($StageOfTask[[int]$d])) — a dependency must not sit in a later stage (same stage is legal: batches carry that finer order); the goal-tree DAG is the order authority" 2
            }
        }
    }
}

function Test-PlanBatches {
    # per-stage batch annotation rules: every staged task in exactly one batch,
    # batches carry only staged tasks, and no dependency edge inside a batch
    # (batch order must follow the DAG within the stage too).
    param($Plan, $StageOfTask, $DepMap)
    foreach ($st in @($Plan.stages)) {
        $batchOf = @{}
        $bi = 0
        foreach ($b in @($st.batches)) {
            foreach ($tid in @($b)) {
                if ($StageOfTask[[int]$tid] -ne [string]$st.id) { Write-ErrorResult "PLAN_BATCH_INVALID" "stage $($st.id) batches reference task #$tid which is not a task of this stage" 2 }
                if ($batchOf.Contains([int]$tid)) { Write-ErrorResult "PLAN_BATCH_INVALID" "stage $($st.id) task #$tid appears in batches $($batchOf[[int]$tid]) and $bi (exactly one batch per task)" 2 }
                $batchOf[[int]$tid] = $bi
            }
            $bi++
        }
        foreach ($tid in @($st.task_ids)) {
            if (-not $batchOf.Contains([int]$tid)) { Write-ErrorResult "PLAN_BATCH_INVALID" "stage $($st.id) task #$tid is missing from batches (each staged task sits in exactly one parallel batch)" 2 }
        }
        foreach ($tid in @($st.task_ids)) {
            foreach ($d in @(Convert-ToSafeArray $DepMap[[int]$tid])) {
                if (-not $batchOf.Contains([int]$d)) { continue }
                if ([int]$batchOf[[int]$d] -ge [int]$batchOf[[int]$tid]) {
                    Write-ErrorResult "PLAN_BATCH_INVALID" "stage $($st.id): task #$tid (batch $($batchOf[[int]$tid])) depends on task #$d (batch $($batchOf[[int]$d])) — batch order must follow the DAG; no dependency edge inside one batch" 2
                }
            }
        }
    }
}

function Test-PlanDeliveryFit {
    # plan vs the delivered set: every delivered task in exactly one stage,
    # no phantom task ids (coverage 要素齐全), then order + batch DAG fit.
    # $ExemptIds (planner-midrun-derive replan whitelist): registered-but-
    # unabsorbed derived task ids may sit OUTSIDE the stages during the window
    # between registration and replan absorption (opposite direction from the
    # push/claim gate, by design) — every other delivered id stays covered.
    param($Plan, [int[]]$ArchiveIds, [int[]]$DeliveredIds, $DepMap, [int[]]$ExemptIds = @())
    $stageOfTask = @{}
    foreach ($st in @($Plan.stages)) {
        foreach ($tid in @($st.task_ids)) {
            if ($ArchiveIds -notcontains [int]$tid) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $($st.id) task_ids references task #$tid which is not a task of this archive" 2 }
            if ($stageOfTask.Contains([int]$tid)) { Write-ErrorResult "PLAN_FILE_INVALID" "task #$tid appears in both stage $($stageOfTask[[int]$tid]) and $($st.id) (exactly one stage per task)" 2 }
            $stageOfTask[[int]$tid] = [string]$st.id
        }
    }
    foreach ($tid in @($DeliveredIds)) {
        if ($ExemptIds -contains [int]$tid) { continue }
        if (-not $stageOfTask.Contains([int]$tid)) { Write-ErrorResult "PLAN_FILE_INVALID" "task #$tid is delivered by this run but missing from the plan stages (every delivered task sits in exactly one stage)" 2 }
    }
    Test-PlanStageOrder $Plan $stageOfTask $DepMap
    Test-PlanBatches $Plan $stageOfTask $DepMap
}

function Test-PlanCriteriaRef {
    # acceptance_point.criteria_ref pins R1's fixed anchor when the archive
    # carries whole-requirement criteria; a criteria-free archive (single /
    # declared-none) requires the slot to stay empty.
    param($Plan, $Criteria)
    $mode = "none"
    if ($null -ne $Criteria) { $mode = [string]$Criteria.mode }
    foreach ($st in @($Plan.stages)) {
        $ref = $st.acceptance_point.criteria_ref
        if ($mode -eq 'criteria') {
            if ($null -eq $ref) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $($st.id) acceptance_point.criteria_ref is required (整体验收判据存在: $($Criteria.criteria_ref))" 2 }
            if ($ref -ne [string]$Criteria.criteria_ref) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $($st.id) acceptance_point.criteria_ref '$ref' must reference the fixed anchor '$($Criteria.criteria_ref)'" 2 }
        }
        elseif ($null -ne $ref) {
            Write-ErrorResult "PLAN_FILE_INVALID" "stage $($st.id) acceptance_point.criteria_ref must be omitted (本归档无整体验收判据)" 2
        }
    }
}

function New-PlanSection {
    # bridge.json plan section (machine-readable current state) from a
    # validated PlanFile; acceptance points start at status=planned.
    param($Plan, [string]$SourceText)
    $stages = @()
    foreach ($st in @($Plan.stages)) {
        $stages += ,@{
            id = $st.id; goal = $st.goal; milestone = $st.milestone
            task_ids = @($st.task_ids); batches = @($st.batches)
            acceptance_point = @{
                criteria_ref = $st.acceptance_point.criteria_ref
                criteria_items = @($st.acceptance_point.criteria_items)
                slice = $st.acceptance_point.slice
                node = $null; status = "planned"
            }
        }
    }
    return @{
        revision = 1; source = $SourceText; planner = $Plan.planner
        planned_at = $Plan.planned_at; applied_at = Get-UtcNowIso
        stages = $stages; risks = @($Plan.risks)
    }
}

function Get-PlanStageOfTask {
    param($PlanSec, [int]$TaskId)
    if ($null -eq $PlanSec) { return $null }
    foreach ($st in @($PlanSec['stages'])) {
        if (@($st['task_ids']) -contains $TaskId) { return $st }
    }
    return $null
}

function Get-PlanGateBlockers {
    # stage gate (只增不减): stages strictly before the task's own whose
    # acceptance point has not passed. Empty = gate open (legacy runs too —
    # no plan section means no gate on top of the dependency unlock semantics).
    # planner-midrun-derive: a bridge-delivered task sitting in NO stage is a
    # registered-unabsorbed derivation — the pseudo-blocker '<unplanned>' holds
    # it until replan absorbs it (the replan-side whitelist and this gate point
    # in OPPOSITE directions by design: fit validation tolerates the window,
    # push/claim never does).
    param($Bridge, [int]$TaskId)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return @() }
    $st = Get-PlanStageOfTask $p $TaskId
    if ($null -eq $st) {
        if ($Bridge.tasks.Contains("$TaskId")) { return @('<unplanned>') }
        return @()
    }
    $blockers = @()
    foreach ($other in @($p['stages'])) {
        if ([string]$other['id'] -eq [string]$st['id']) { break }
        if ([string]$other['acceptance_point']['status'] -ne 'passed') { $blockers += [string]$other['id'] }
    }
    return @($blockers)
}

function Assert-PlanGateOpen {
    # NODE_BLOCKED_BY_GATE — the deterministic claim/dispatch feedback for a
    # closed stage gate (long-task-planning). No force bypass: settling the
    # stage acceptance node or replanning the stages is the only way through.
    param($Bridge, [int]$TaskId)
    $blockers = Get-PlanGateBlockers $Bridge $TaskId
    if ($blockers.Count -gt 0) {
        if (@($blockers) -contains '<unplanned>') {
            Write-ErrorResult "NODE_BLOCKED_BY_GATE" "Task #$TaskId is registered but covered by NO plan stage (mid-run derived, awaiting replan absorption) — replan it into the stages: delivery-bridge.cmd -Command replan -RunId $RunId -PlanFile <revised plan incl. task #$TaskId> -Reason <deviation>; no force bypass (the whitelist lives on the replan validation side only)." 1
        }
        Write-ErrorResult "NODE_BLOCKED_BY_GATE" "Task #$TaskId sits behind a closed stage gate — waiting on acceptance point(s) of stage(s): [$($blockers -join ', ')]. Settle the [集成验收·S<k>] node(s) (真实执行集成验收), or replan to re-scope the stages; no force bypass." 1
    }
}

function Test-StageTasksTerminal {
    # stage completion is per-TASK terminality (complete/deprecated), not node
    # settle (multi-owner tasks settle node by node); ids this run does not
    # deliver (deprecated / in-tree merged / rejected-back) are exempt —
    # they must never wedge the gate or the acceptance trigger.
    param($Stage, $Bridge, $FlowTasks)
    foreach ($tid in @($Stage['task_ids'])) {
        if (-not $Bridge.tasks.Contains("$tid")) { continue }
        $task = Find-ArchiveTask $FlowTasks ([int]$tid)
        if ($null -eq $task) { continue }
        if ($script:PlanTerminalLifecycles -notcontains ([string]$task.lifecycle)) { return $false }
    }
    return $true
}

function New-StageAcceptanceSpec {
    # [集成验收·S<k>] node spec: role=QA tree-level node under the goal root,
    # task text carries the criteria subset + runnable slice (真实执行 evidence
    # asks for the slice run result in extras.verification).
    param($Stage, [string]$ReqRel, [string]$RunIdText)
    $title = $script:PlanStageAcceptanceFmt -f ([string]$Stage['id'])
    $items = (@($Stage['acceptance_point']['criteria_items']) | ForEach-Object { [string]$_ }) -join '；'
    $mission = "使命：阶段「$([string]$Stage['goal'])」末尾集成验收点——对照判据子集（$items）核验本阶段交付的真实衔接，并实证可运行切片：$([string]$Stage['acceptance_point']['slice'])。交付记录：验证摘要 + 切片运行证据（回调 extras.verification）。"
    $spec = @{ title = $title; role = "QA"; mission = $mission }
    $item = New-AcceptanceChainGraftItem $spec $ReqRel $([string]$Stage['acceptance_point']['criteria_ref']) $RunIdText
    return @{ title = $title; item = $item }
}

function Get-PlanStageReqRel {
    # requirement doc anchor for a stage acceptance node (archive-relative, the
    # graft-item convention): the first staged task this run delivers.
    param($Bridge, $Stage)
    foreach ($tid in @($Stage['task_ids'])) {
        if ($Bridge.tasks.Contains("$tid") -and $Bridge.tasks["$tid"].Contains('requirement')) {
            return [string]$Bridge.tasks["$tid"]['requirement']
        }
    }
    return "requirements/overview.md"
}

function Set-PlanAcceptanceState {
    # acceptance_point transition -> persist bridge -> plan-log progress event.
    param([string]$RunDir, $Bridge, $Stage, [string]$Status, [string]$Node, [string]$EventName, $Detail)
    $ap = $Stage['acceptance_point']
    $ap['status'] = $Status
    if (-not [string]::IsNullOrWhiteSpace($Node)) { $ap['node'] = $Node }
    Write-BridgeFile $RunDir $Bridge | Out-Null
    $null = Add-PlanEvent $RunDir 'progress' $EventName ([string]$ap['node']) $null ([string]$Stage['id']) $Detail
    return $Bridge
}

function Update-FinalStageAcceptance {
    # k=K acceptance point: the R1 [集成/联调]->[整体验收] chain IS the final
    # acceptance (no duplicate node — the accept node is bound once it exists).
    # Without a whole-requirement chain (single/declared-none exemption) the
    # final stage auto-passes on task terminality (K=1 stays zero extra nodes).
    param([string]$RunDir, $Bridge, $Stage)
    $a = Get-AcceptanceSection $Bridge
    if ($null -eq $a -or ([string]$a['status']) -eq 'none') {
        return Set-PlanAcceptanceState $RunDir $Bridge $Stage 'passed' $null 'acceptance_passed' @{ basis = "final stage without a whole-requirement acceptance chain — task terminality is the verification unit" }
    }
    $acceptNode = [string]$a['accept_node']
    if ([string]::IsNullOrWhiteSpace($acceptNode)) { return $Bridge }   # wait for the R1 chain
    $node = Get-NodeFromTree (Get-TreeStatusView $RunId) $acceptNode
    $status = "grafted"
    if ($null -ne $node -and ([string]$node.status) -eq 'done') { $status = 'passed' }
    return Set-PlanAcceptanceState $RunDir $Bridge $Stage $status $acceptNode 'acceptance_bound' @{ basis = "rides the R1 final-acceptance chain"; node = $acceptNode }
}

function Update-OneStageAcceptance {
    # one stage's acceptance transition (idempotent): tasks terminal -> graft
    # [集成验收·S<k>] / bind the final chain -> node settled -> passed.
    param([string]$RunDir, $Bridge, $Stage, [bool]$IsLast, $FlowTasks)
    if (([string]$Stage['acceptance_point']['status']) -eq 'passed') { return @{ bridge = $Bridge; grafted = $null } }
    if (-not (Test-StageTasksTerminal $Stage $Bridge $FlowTasks)) { return @{ bridge = $Bridge; grafted = $null } }
    if ($IsLast) { return @{ bridge = (Update-FinalStageAcceptance $RunDir $Bridge $Stage); grafted = $null } }
    $ap = $Stage['acceptance_point']
    if (([string]$ap['status']) -eq 'planned') {
        $spec = New-StageAcceptanceSpec $Stage (Get-PlanStageReqRel $Bridge $Stage) ([string]$Bridge.run_id)
        $g = Invoke-GraftOne ([string]$Bridge.run_id) ([string]$Bridge.goal_root) $spec.item
        if (-not $g.ok) { return @{ bridge = $Bridge; grafted = $null } }   # retried on the next trigger
        $b = Set-PlanAcceptanceState $RunDir $Bridge $Stage 'grafted' $g.node_id 'acceptance_grafted' @{ title = $spec.title; slice = [string]$ap['slice'] }
        return @{ bridge = $b; grafted = @{ node = $g.node_id; title = $spec.title; stage = [string]$Stage['id'] } }
    }
    $node = Get-NodeFromTree (Get-TreeStatusView $RunId) ([string]$ap['node'])
    if ($null -ne $node -and ([string]$node.status) -eq 'done') {
        $b = Set-PlanAcceptanceState $RunDir $Bridge $Stage 'passed' $null 'acceptance_passed' @{ node = [string]$ap['node']; slice = [string]$ap['slice'] }
        return @{ bridge = $b; grafted = $null }
    }
    return @{ bridge = $Bridge; grafted = $null }
}

function Update-StageAcceptancePoints {
    # Stage acceptance-point state machine — rides every auto-dispatch trigger
    # (self-healing, like Update-AcceptanceChain): grafts/binds/advances and
    # writes the plan-log progress events at the transitions only.
    param([string]$RunDir, $Bridge)
    $out = @{ bridge = $Bridge; grafted = @() }
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $out }
    $pending = @($p['stages'] | Where-Object { ([string]$_['acceptance_point']['status']) -ne 'passed' })
    if ($pending.Count -eq 0) { return $out }
    $flow = Read-ArchiveTasks $Bridge.archive
    $lastId = ""
    if (@($p['stages']).Count -gt 0) { $lastId = [string](@($p['stages'])[-1]['id']) }
    foreach ($st in @($pending)) {
        $r = Update-OneStageAcceptance $RunDir $out.bridge $st (([string]$st['id']) -eq $lastId) $flow.tasks
        $out.bridge = $r.bridge
        if ($null -ne $r.grafted) { $out.grafted += ,$r.grafted }
    }
    return $out
}

function Get-StageAcceptanceNodeInfo {
    # tree-level recognition for [集成验收·S<k>] nodes (the claim/settle
    # tree-level short-circuit branch, same shape as Get-AcceptanceNodeInfo).
    param($Bridge, [string]$NodeId)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $null }
    foreach ($st in @($p['stages'])) {
        $ap = $st['acceptance_point']
        if ($null -ne $ap -and -not [string]::IsNullOrWhiteSpace([string]$ap['node']) -and ([string]$ap['node']) -eq $NodeId) {
            return @{
                kind = "stage_acceptance"; role = "QA"; chain = $true
                stage_id = [string]$st['id']
                criteria_ref = $(if ($null -ne $ap['criteria_ref']) { [string]$ap['criteria_ref'] } else { $null })
                criteria_items = @($ap['criteria_items']); slice = [string]$ap['slice']
            }
        }
    }
    return $null
}

function Remove-InvalidatedAcceptanceNode {
    # 失效回收 (F6): an invalidation wave unbinds an acceptance point — its old
    # [集成验收·S<k>] node must give the goal-root child slot back (goal-tree
    # counts only ACTIVE children toward node_width), otherwise every re-graft
    # stacks one more slot and the [整体验收] graft turns WIDTH_EXCEEDED forever.
    # The R1 terminal-chain nodes ([集成/联调]/[整体验收]) are REUSED by the final
    # stage acceptance point (末阶段复用 R1 终局链的节点) and are never reclaimed
    # here — reuse keeps that stage at ≤1 active slot without touching the chain.
    # Audit: pruned_reason stays on the node ("acceptance invalidated: <stage>").
    # Missing / already-pruned = slot already free (idempotent); any other prune
    # failure is a hard, rerun-safe error (nothing is unbound before reclaim).
    param($Bridge, [string]$NodeId, [string]$StageId)
    if ([string]::IsNullOrWhiteSpace($NodeId)) { return }
    $a = Get-AcceptanceSection $Bridge
    if ($null -ne $a) {
        if ($NodeId -eq [string]$a['integrate_node'] -or $NodeId -eq [string]$a['accept_node']) { return }
    }
    $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", ([string]$Bridge.run_id), "-NodeId", $NodeId, "-Reason", "acceptance invalidated: $StageId")
    if ($rp.exit -eq 0 -and $null -ne $rp.json -and $rp.json.success) { return }
    $code = ""
    if ($null -ne $rp.json -and $null -ne $rp.json.error) { $code = [string]$rp.json.error.code }
    if ($code -eq "ALREADY_PRUNED" -or $code -eq "NODE_NOT_FOUND") { return }
    Write-ErrorResult "INVALIDATION_PRUNE_FAILED" "invalidation wave could not reclaim stale acceptance node $NodeId (stage $StageId): $($rp.text)" 1
}

function Reset-PlanStageAcceptance {
    # invalidation wave (防闸门虚开): the touched task's stage and every later
    # stage roll their acceptance point back to planned (node unbound; a later
    # re-verification re-grafts a fresh node). Records acceptance_invalidated.
    # The unbound node is reclaimed BEFORE the rollback (失效回收, F6): prune
    # frees its goal-root child slot so the re-graft REUSES the slot instead of
    # stacking one more (「每非末段验收点 ≤1 活跃 goal-root 子位」不变量).
    param([string]$RunDir, $Bridge, [int]$TaskId, [string]$Trigger, [string]$ReasonText)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $false }
    $st = Get-PlanStageOfTask $p $TaskId
    if ($null -eq $st) { return $false }
    $reached = $false; $hit = $false
    $wave = @()
    foreach ($other in @($p['stages'])) {
        if (([string]$other['id']) -eq ([string]$st['id'])) { $reached = $true }
        if (-not $reached) { continue }
        $ap = $other['acceptance_point']
        if (([string]$ap['status']) -eq 'planned') { continue }
        $wave += ,$other
    }
    foreach ($other in @($wave)) {
        Remove-InvalidatedAcceptanceNode $Bridge ([string]$other['acceptance_point']['node']) ([string]$other['id'])
    }
    foreach ($other in @($wave)) {
        # auditor-design-stage-review: 同波失效 design_review（防闸门虚开——任务回退
        # 进 DESIGN 后旧审查结论不再代表当前设计）；无段跳过（旧 run 零成本）。
        $dr = $other['design_review']
        if ($null -ne $dr -and ([string]$dr['status']) -notin @('', 'planned')) {
            Remove-InvalidatedDesignReviewNode $Bridge ([string]$dr['node']) ([string]$other['id'])
        }
    }
    foreach ($other in @($wave)) {
        $ap = $other['acceptance_point']
        $oldNode = [string]$ap['node']
        $ap['status'] = 'planned'; $ap['node'] = $null
        $hit = $true
        $null = Add-PlanEvent $RunDir 'deviation' 'acceptance_invalidated' $oldNode $TaskId ([string]$other['id']) @{ trigger = $Trigger; reason = $ReasonText }
        $dr = $other['design_review']
        if ($null -ne $dr -and ([string]$dr['status']) -notin @('', 'planned')) {
            $drOldNode = [string]$dr['node']
            $dr['status'] = 'planned'; $dr['node'] = $null; $dr['verdict'] = $null; $dr['reviewed_at'] = $null; $dr['basis'] = $null
            $null = Add-PlanEvent $RunDir 'deviation' 'design_review_invalidated' $drOldNode $TaskId ([string]$other['id']) @{ trigger = $Trigger; reason = $ReasonText }
        }
    }
    if ($hit) { Write-BridgeFile $RunDir $Bridge | Out-Null }
    return $hit
}

function Write-PlanRecoveryTail {
    # reclaim / rollback tail bookkeeping: deviation event (task failed / cross-
    # stage redo) + the acceptance invalidation wave over the touched stage.
    param([string]$RunDir, $Bridge, [string]$EventName, [string]$NodeIdText, [int]$TaskId, [string]$ModeText)
    if ($null -eq (Get-PlanSection $Bridge)) { return }
    $stage = Get-PlanStageOfTask (Get-PlanSection $Bridge) $TaskId
    $stageId = $null
    if ($null -ne $stage) { $stageId = [string]$stage['id'] }
    $null = Add-PlanEvent $RunDir 'deviation' $EventName $NodeIdText $TaskId $stageId @{ mode = $ModeText }
    $null = Reset-PlanStageAcceptance $RunDir $Bridge $TaskId $EventName $ModeText
}

# === Stage design review (auditor-design-stage-review) ===
#
# DESIGN→IMPL 阶段边界独立设计审查门（与已交付的 QA 阶段解禁构成「实现前查设计 /
# 实现后查符合性」独立审查链）。门禁形态 = 方案 B：settle 尾原子性不动，闸门为纯
# 判定函数叠加在现有三触点（push 候选 skip / claim / dispatch 硬错），与阶段闸门、
# conflict hold 同路径 AND 栈叠、reason 分列；pass 后下一个 auto-dispatch 触发点自动
# 放行（自愈免费）——「pass → 才 graft IMPL 链头」以效果语义满足（IMPL 无法开工）。
# 状态机 plan.stages[k].design_review = { status: planned|grafted|passed|failed|exempt,
# node, verdict, reviewed_at, basis }（与 acceptance_point 同构同址；无段 = 无门零成本，
# conflicts/conventions 先例，旧 run 逐字节不变）。审查节点 [设计审查·S<k>] 挂接语义
# 与 [集成验收·S<k>] 同构（树级·goal 根下·无 TaskId·role=AUDITOR·一批一会话）。

$script:PlanDesignReviewFmt = "[设计审查·{0}]"
$script:DesignReviewDims = @("alignment", "change_map", "internal_consistency", "completeness", "cross_design")
$script:DesignReviewReportFmt = "review/design-review-{0}.json"   # 归档相对机读单源（.md 人读镜像同名）
# reviewer 枚举单源（auditor-subagent-review 验收 4）：值域扩贯通 DesignReviewFile
# 契约 / review-ledger 署名 / 驳回协议 From / decisions.jsonl decider 四面；常量表
# 与 rdd-engine/references/review-input-template.md 的常量表同步（test-review-
# input-template.ps1 防协议漂移锁定）。
#   auditor-delegated = 独立上下文子代理生产、规划者呈现（subagent 形态）
#   auditor           = 强形态独立会话生产（session 形态）
#   planner           = 存量只读（ReviewFile 历史值域，不再产出；消费端零改动）
$script:DesignReviewReviewers = @('auditor-delegated', 'auditor')
$script:ReviewModeValues = @('subagent', 'session')          # review_mode 值域（无 off）
$script:ReviewInputTemplateRel = "rdd-engine/references/review-input-template.md"

function Get-BridgeReviewMode {
    # review_mode 配置载体（auditor-subagent-review 决策 #4/#7）：bridge.json 有键
    # （subagent|session）= 新链（纯契约，评审内生于规划者，无部署判据）；缺键 =
    # 存量 run 旧链逐字节（节点 graft / AUDITOR 推送 / +K 预算 / 双探照旧，行为不
    # 回溯）。返回 'subagent'|'session'|$null（$null = legacy）。
    param($Bridge)
    if ($null -eq $Bridge -or -not (Test-PropPresent $Bridge 'review_mode')) { return $null }
    $modeText = [string]$Bridge['review_mode']
    if ($script:ReviewModeValues -contains $modeText) { return $modeText }
    return $null
}

function Test-AuditorDeployed {
    # 【legacy only】降级双探（验收 7 缺键旧链保留）：engine 包 `rdd-auditor/` 角色
    # 卡目录（rdd-engine 同级布局）+ repo `dsh/presets/rdd-auditor/`——任一在即视为
    # 已部署。仅缺键（review_mode absent）的旧链 promulgate 消费；新链（-ReviewMode）
    # 部署判据 = 配置项本身，评审能力内生于规划者，此探测零触达。
    # best-effort：探测异常一律按未部署处理。
    param()
    $engineRoot = Split-Path (Split-Path $script:ScriptDir -Parent) -Parent
    $probes = @(
        (Join-Path $engineRoot "rdd-auditor/SKILL.md")
        (Join-Path $repoRoot "dsh/presets/rdd-auditor")
    )
    foreach ($p in @($probes)) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) { return $true }
    }
    return $false
}

function Set-PlanDesignReviewSlots {
    # promulgate 落段分支化（auditor-subagent-review）：新链（-ReviewMode）恒落
    # design_review 槽位（评审能力内生于规划者——无部署判据、无「未部署零门」降级）；
    # 缺键旧链沿双探（AUDITOR 已部署才落段，逐字节现行行为）。返回 @{ plan; deployed }。
    param($PlanSec, [string]$ReviewModeText)
    if ([string]::IsNullOrWhiteSpace($ReviewModeText) -and -not (Test-AuditorDeployed)) { return @{ plan = $PlanSec; deployed = $false } }
    foreach ($st in @($PlanSec['stages'])) {
        $st['design_review'] = @{
            status = "planned"; node = $null; verdict = $null
            reviewed_at = $null; basis = $null
        }
    }
    return @{ plan = $PlanSec; deployed = $true }
}

function Get-DesignReviewFlowTasks {
    # per-invocation memo（Get-ConflictFlowTasks 先例）：设计审查闸门逐候选查
    # task designDocs/phase，memo 让整个 push 循环只跑一次 rdd-flow show。
    param($Bridge)
    $key = [string]$Bridge.archive
    if ($null -ne $script:DesignReviewFlowTasksCache -and ([string]$script:DesignReviewFlowTasksCache.key) -eq $key) {
        return @($script:DesignReviewFlowTasksCache.tasks)
    }
    $flow = Read-ArchiveTasks $key
    $script:DesignReviewFlowTasksCache = @{ key = $key; tasks = @($flow.tasks) }
    return @($script:DesignReviewFlowTasksCache.tasks)
}

function Get-StageDesignDocs {
    # 阶段全部落盘设计产物（审查对象面）：阶内在册任务的 designDocs 中真实存在的
    # 文档（归档相对路径，'/' 规整）。返回 @{ docs; doc_tasks }（doc -> @([int] task)）。
    param($Bridge, $Stage, $FlowTasks)
    $docs = @()
    $docTasks = @{}
    foreach ($tid in @($Stage['task_ids'])) {
        if (-not $Bridge.tasks.Contains("$tid")) { continue }
        $task = Find-ArchiveTask $FlowTasks ([int]$tid)
        if ($null -eq $task) { continue }
        foreach ($d in @(Convert-ToSafeArray $task.designDocs)) {
            $rel = (([string]$d.path) -replace '\\', '/')
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $abs = Join-Path ([string]$Bridge.archive) ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
            if ($docs -notcontains $rel) { $docs += $rel }
            if (-not $docTasks.Contains($rel)) { $docTasks[$rel] = @() }
            if ($docTasks[$rel] -notcontains [int]$tid) { $docTasks[$rel] += [int]$tid }
        }
    }
    return @{ docs = @($docs); doc_tasks = $docTasks }
}

function Test-StageTaskPastDesign {
    # 越过 DESIGN 判定：phase ∈ {IMPL, VERIFY} 或 lifecycle 终态；legacy 空 phase 按
    # bridge 链推导（已挂 DEV 节点 = 已越过；QA 单角色歧义按未越过保守处理——设计
    # 组未收敛，审查等待，无死锁：QA settle 后 phase 推进或任务终态自愈）。
    param($Task, $BridgeTask)
    if ($script:PlanTerminalLifecycles -contains ([string]$Task.lifecycle)) { return $true }
    $ph = $null
    if (Test-PropPresent $Task 'phase') { $ph = [string]$Task.phase }
    if (-not [string]::IsNullOrWhiteSpace($ph)) { return (@('IMPL', 'VERIFY') -contains $ph) }
    if ($null -ne $BridgeTask -and $BridgeTask.Contains('stages') -and $null -ne $BridgeTask['stages']) {
        if ($BridgeTask['stages'].Contains('DEV')) { return $true }
    }
    return $false
}

function Test-StageDesignTrigger {
    # 触发判据（验收 1/5）：阶段内全部在册任务越过 DESIGN 且 ≥1 落盘设计产物 →
    # graft；全阶段无设计产物 / 阶段内无任何 DESIGN 节点（本 run 没做过设计工作，
    # 如全 DEV 起步的既有产物任务）→ exempt 快速通道；「存在 DESIGN 节点即审」
    # （v1 全量触发）。无产物任务不占闸门也不阻塞触发。
    param($Bridge, $Stage, $FlowTasks)
    $dd = Get-StageDesignDocs $Bridge $Stage $FlowTasks
    $hasDesignWork = $false
    foreach ($tid in @($Stage['task_ids'])) {
        if (-not $Bridge.tasks.Contains("$tid")) { continue }
        $bTask = $Bridge.tasks["$tid"]
        if ($null -ne $bTask -and $bTask.Contains('stages') -and $null -ne $bTask['stages']) {
            foreach ($role in @($script:PhaseRoles['DESIGN'])) {
                if ($bTask['stages'].Contains($role)) { $hasDesignWork = $true }
            }
        }
    }
    if (-not $hasDesignWork) {
        return @{ mode = "exempt"; reason = "no design-stage nodes in this run (no in-run design work to review)"; docs = @(); doc_tasks = $dd.doc_tasks }
    }
    if (@($dd.docs).Count -eq 0) {
        # 无产物快速通道只在**本段设计工作已经结束**时成立。派生并入的阶段（planner-
        # midrun-derive × 本机制集成面）在 replan 触发那一刻必然尚无产物：CTO 还没跑、
        # task.json 也还没有 designDocs 条目（设计文档路径由 CTO 产出并经 add-design
        # 登记）。若此刻落 exempt 终态，该段此后产出的设计产物永远不进审查、其 IMPL
        # 节点也不占闸门——新链「评审强制、无 off 值」在这里静默失效。改判：设计工作
        # 未结束 → wait；任务越过 DESIGN 后同一判据自然给出 exempt（确实没产物）或
        # graft/ready（有产物）——语义不变，只去掉过早定性。
        foreach ($tid in @($Stage['task_ids'])) {
            $task = Find-ArchiveTask $FlowTasks ([int]$tid)
            if ($null -eq $task) { continue }
            $bTask = $null
            if ($Bridge.tasks.Contains("$tid")) { $bTask = $Bridge.tasks["$tid"] }
            if (-not (Test-StageTaskPastDesign $task $bTask)) {
                return @{ mode = "wait"; reason = "task #$tid still inside DESIGN and no artifacts on disk yet (no-artifact exemption is decided only once the stage's design work is over)"; docs = @(); doc_tasks = $dd.doc_tasks }
            }
        }
        return @{ mode = "exempt"; reason = "no on-disk design artifacts (设计工作已结束且无产物快速通道豁免)"; docs = @(); doc_tasks = $dd.doc_tasks }
    }
    foreach ($tid in @($Stage['task_ids'])) {
        $task = Find-ArchiveTask $FlowTasks ([int]$tid)
        if ($null -eq $task) { continue }
        $bTask = $null
        if ($Bridge.tasks.Contains("$tid")) { $bTask = $Bridge.tasks["$tid"] }
        if (-not (Test-StageTaskPastDesign $task $bTask)) {
            return @{ mode = "wait"; reason = "task #$tid still inside DESIGN"; docs = @(); doc_tasks = $dd.doc_tasks }
        }
    }
    return @{ mode = "graft"; reason = "all stage tasks past DESIGN with on-disk design artifacts"; docs = @($dd.docs); doc_tasks = $dd.doc_tasks }
}

function New-StageDesignReviewSpec {
    # [设计审查·S<k>] node spec：role=AUDITOR 树级节点（goal 根下、无 TaskId），挂接
    # 语义与 [集成验收·S<k>] 同构；task text 携带五查维度 + DesignReviewFile 契约落点。
    param($Stage, [string]$ReqRel, [string]$RunIdText, [string[]]$DocRels, [string]$AcceptanceRef)
    $title = $script:PlanDesignReviewFmt -f ([string]$Stage['id'])
    $reportRel = $script:DesignReviewReportFmt -f ([string]$Stage['id'])
    $docsJoined = (@($DocRels) | ForEach-Object { [string]$_ }) -join '；'
    $mission = "使命：汇聚审查阶段「$([string]$Stage['goal'])」全部设计产物（一批一会话，禁止逐设计串行）——审查对象：$docsJoined。五查维度：$($script:DesignReviewDims -join ' / ')（变更地图维度消费 bridge.json design_maps 机械缓存，DESIGN_MAP_INVALID 警示为裁定输入；跨设计项落 summary 专节）。产出 DesignReviewFile（机读单源 $reportRel + 人读镜像 .md；总裁定由引擎推导——pass ⇔ 全文档 pass 且全局零 blocking）。三条边界：不评技术选型对错 / 不修改设计（只报不改）/ 不写测试。"
    $spec = @{ title = $title; role = "AUDITOR"; mission = $mission }
    $item = New-AcceptanceChainGraftItem $spec $ReqRel $AcceptanceRef $RunIdText
    return @{ title = $title; item = $item }
}

function Set-DesignReviewState {
    # design_review transition → persist bridge → plan-log progress event（与
    # Set-PlanAcceptanceState 同构；node 为空串/null 归一为 null）。
    param([string]$RunDir, $Bridge, $Stage, [string]$Status, $Node, [string]$EventName, $Detail)
    $dr = $Stage['design_review']
    $dr['status'] = $Status
    $dr['node'] = $(if ([string]::IsNullOrWhiteSpace($Node)) { $null } else { [string]$Node })
    Write-BridgeFile $RunDir $Bridge | Out-Null
    $null = Add-PlanEvent $RunDir 'progress' $EventName ([string]$dr['node']) $null ([string]$Stage['id']) $Detail
    return $Bridge
}

function Get-DesignReviewNodeInfo {
    # tree-level recognition for [设计审查·S<k>] nodes（claim/settle tree-level
    # 分支；Get-StageAcceptanceNodeInfo 同形）。docs 清单由 claim 上下文构造侧按
    # 当前盘面现算（这里只认节点归属）。
    param($Bridge, [string]$NodeId)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $null }
    foreach ($st in @($p['stages'])) {
        $dr = $st['design_review']
        if ($null -ne $dr -and -not [string]::IsNullOrWhiteSpace([string]$dr['node']) -and ([string]$dr['node']) -eq $NodeId) {
            return @{ kind = "design_review"; role = "AUDITOR"; chain = $true; stage_id = [string]$st['id'] }
        }
    }
    return $null
}

function Read-DesignReviewFile {
    # DesignReviewFile 机读单源读取：@{ ok; path; data; error }——ok=$false 时
    # data=$null + error 说明（settle 门与状态机共用的单一读入面）。
    param([string]$ArchivePath, [string]$StageId)
    $rel = $script:DesignReviewReportFmt -f $StageId
    $abs = Join-Path $ArchivePath ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
        return @{ ok = $false; path = $abs; data = $null; error = "DesignReviewFile 不存在：<archive>/$rel（AUDITOR 须产出机读单源 + 人读镜像）" }
    }
    try {
        $data = Convert-PSObjectToHashtable ([System.IO.File]::ReadAllText($abs, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch {
        return @{ ok = $false; path = $abs; data = $null; error = "DesignReviewFile 不可解析：$rel（$($_.Exception.Message)）" }
    }
    return @{ ok = $true; path = $abs; data = $data; error = $null }
}

function Get-DesignReviewVerdict {
    # 总裁定推导（验收 2：引擎推导，不采信声明值）：pass ⇔ 全文档 verdict=pass 且
    # 全局（docs[].findings + summary.cross_design）零 blocking。blocking 清单
    # （cross_design 项按 involved_docs 展开）供 fail 波与记账消费。
    param($ReviewData)
    $verdict = "pass"
    $blocking = @()
    foreach ($d in @(Convert-ToSafeArray $ReviewData['docs'])) {
        if (([string]$d['verdict']) -ne 'pass') { $verdict = "fail" }
        foreach ($f in @(Convert-ToSafeArray $d['findings'])) {
            if (([string]$f['severity']) -eq 'blocking') {
                $verdict = "fail"
                $blocking += @{ doc = [string]$d['doc']; dimension = [string]$f['dimension']; item = [string]$f['item']; suggestion = [string]$f['suggestion'] }
            }
        }
    }
    $summary = $ReviewData['summary']
    if ($null -ne $summary) {
        foreach ($f in @(Convert-ToSafeArray $summary['cross_design'])) {
            if (([string]$f['severity']) -eq 'blocking') {
                $verdict = "fail"
                foreach ($doc in @(Convert-ToSafeArray $f['involved_docs'])) {
                    $blocking += @{ doc = [string]$doc; dimension = "cross_design"; item = [string]$f['item']; suggestion = [string]$f['suggestion'] }
                }
            }
        }
    }
    return @{ verdict = $verdict; blocking = @($blocking) }
}

function Test-DesignReviewDocEntry {
    # 单条 docs[] 条目机械校验（Test-DesignReviewFile 子过程）：归属在册 / 重复 /
    # verdict 枚举 / verdict-findings 一致 / finding 四字段完备 + 枚举值域。
    param($DocEntry, [string]$StageId, [string[]]$Expected)
    $problems = @()
    $rel = [string]$DocEntry['doc']
    if ([string]::IsNullOrWhiteSpace($rel)) { return @("design_review check: docs[] entry carries an empty doc") }
    if ($Expected -notcontains $rel) { $problems += "design_review check: docs[] lists '$rel' which is not an on-disk design doc of stage $StageId（阶段设计文档全覆盖 + 归属在册）" }
    $v = [string]$DocEntry['verdict']
    if (@('pass', 'fail') -notcontains $v) { $problems += "design_review check: doc '$rel' verdict '$v' not in pass|fail" }
    $findings = @(Convert-ToSafeArray $DocEntry['findings'])
    $blockingN = @($findings | Where-Object { ([string]$_['severity']) -eq 'blocking' }).Count
    if ($v -eq 'fail' -and $blockingN -eq 0) { $problems += "design_review check: doc '$rel' verdict=fail but carries no blocking finding（fail 必有 blocking）" }
    if ($v -eq 'pass' -and $blockingN -gt 0) { $problems += "design_review check: doc '$rel' verdict=pass but carries $blockingN blocking finding(s)（pass 必无）" }
    $i = 0
    foreach ($f in @($findings)) {
        $i++
        $sev = [string]$f['severity']
        if (@('blocking', 'advisory') -notcontains $sev) { $problems += "design_review check: doc '$rel' finding #$i severity '$sev' not in blocking|advisory" }
        $dim = [string]$f['dimension']
        if ($script:DesignReviewDims -notcontains $dim) { $problems += "design_review check: doc '$rel' finding #$i dimension '$dim' not in $($script:DesignReviewDims -join '/')" }
        if ([string]::IsNullOrWhiteSpace([string]$f['item'])) { $problems += "design_review check: doc '$rel' finding #$i item is empty（finding 四字段完备）" }
        if ([string]::IsNullOrWhiteSpace([string]$f['suggestion'])) { $problems += "design_review check: doc '$rel' finding #$i suggestion is empty（finding 四字段完备）" }
    }
    return $problems
}

function Test-DesignReviewSummaryBlock {
    # summary.cross_design 专节机械校验（Test-DesignReviewFile 子过程）：四字段 +
    # involved_docs 非空且归属在册。
    param($Summary, [string]$StageId, [string[]]$Expected)
    $problems = @()
    if ($null -eq $Summary) { return @("design_review check: summary is absent（汇总段必带 cross_design 专节）") }
    $j = 0
    foreach ($f in @(Convert-ToSafeArray $Summary['cross_design'])) {
        $j++
        $sev = [string]$f['severity']
        if (@('blocking', 'advisory') -notcontains $sev) { $problems += "design_review check: summary.cross_design #$j severity '$sev' not in blocking|advisory" }
        if ([string]::IsNullOrWhiteSpace([string]$f['item'])) { $problems += "design_review check: summary.cross_design #$j item is empty" }
        if ([string]::IsNullOrWhiteSpace([string]$f['suggestion'])) { $problems += "design_review check: summary.cross_design #$j suggestion is empty" }
        $involved = @(Convert-ToSafeArray $f['involved_docs'])
        if ($involved.Count -eq 0) { $problems += "design_review check: summary.cross_design #$j involved_docs is empty（跨设计项必附涉及文档）" }
        foreach ($doc in @($involved)) {
            if ($Expected -notcontains [string]$doc) { $problems += "design_review check: summary.cross_design #$j involved_docs lists '$doc' which is not an on-disk design doc of stage $StageId" }
        }
    }
    return $problems
}

function Test-DesignReviewProduction {
    # production 留痕段（auditor-subagent-review 凭据链）：有则验形态（mode 值域 +
    # template ref 非空——机械输入模板留痕可审计），缺省不拦（存量 DesignReviewFile
    # 与 legacy 链零回归；转述/裁定倾向注入是协议违规，可驳回重派，不落机械门）。
    param($Data)
    if (-not (Test-PropPresent $Data 'production') -or $null -eq $Data['production']) { return @() }
    $prod = $Data['production']
    $problems = @()
    if ($script:ReviewModeValues -notcontains ([string]$prod['mode'])) {
        $problems += "design_review check: production.mode '$([string]$prod['mode'])' not in $($script:ReviewModeValues -join '|')"
    }
    if ([string]::IsNullOrWhiteSpace([string]$prod['template'])) {
        $problems += "design_review check: production.template is empty（输入模板留痕）"
    }
    return $problems
}

function Test-DesignReviewFileCore {
    # 契约校验核心（auditor-subagent-review 决策 #6 抽核心双调用点复用）：node settle
    # （legacy）与 design-review -Action submit 同源执行，拒绝复制校验逻辑（双份漂移
    # 风险）。机械校验（验收 2）：reviewed_at 非空 / reviewer 值域扩
    # （auditor-delegated|auditor，验收 4）/ stage 归属一致 / production 留痕形态 /
    # 阶段设计文档双向全覆盖 / verdict-findings 一致 / finding 四字段 + 枚举值域 /
    # blocking 归属在册。返回 problems[]（空 = 过）。
    param($Data, [string]$StageId, [string[]]$Expected)
    $problems = @()
    if ([string]::IsNullOrWhiteSpace([string]$Data['reviewed_at'])) { $problems += "design_review check: reviewed_at is absent/empty" }
    if ($script:DesignReviewReviewers -notcontains ([string]$Data['reviewer'])) {
        $problems += "design_review check: reviewer must be one of auditor-delegated|auditor (got '$([string]$Data['reviewer'])')"
    }
    if (([string]$Data['stage']) -ne $StageId) { $problems += "design_review check: stage field '$([string]$Data['stage'])' does not match the reviewed stage '$StageId'" }
    $problems += @(Test-DesignReviewProduction $Data)
    $docs = @(Convert-ToSafeArray $Data['docs'])
    if ($docs.Count -eq 0) { $problems += "design_review check: docs[] is empty（阶段设计文档全覆盖）" }
    $seen = @()
    foreach ($d in @($docs)) {
        $rel = [string]$d['doc']
        if ([string]::IsNullOrWhiteSpace($rel)) { $problems += "design_review check: docs[] entry carries an empty doc"; continue }
        if ($seen -contains $rel) { $problems += "design_review check: docs[] lists '$rel' more than once" }
        $seen += $rel
        $problems += @(Test-DesignReviewDocEntry $d $StageId $Expected)
    }
    foreach ($rel in @($Expected)) {
        if ($seen -notcontains $rel) { $problems += "design_review check: on-disk design doc '$rel' is not covered by docs[]（阶段设计文档全覆盖）" }
    }
    $problems += @(Test-DesignReviewSummaryBlock $Data['summary'] $StageId $Expected)
    return $problems
}

function Test-DesignReviewFile {
    # AUDITOR settle 门校验器（注册表派发——注册行在 verbatim 同步块之外，见
    # $script:RoleHandoffValidators 之后的一行；DEV 先例 Test-DevQualityScan 模式）。
    # GatePayload 桥接形态 { scenario; run_id; node_id }。文件层面的问题（缺文件/
    # 不可解析）也是 problems——四查通道统一拒不合格交付。契约断言本体在
    # Test-DesignReviewFileCore（与 design-review submit 双调用点同源，决策 #6）。
    param($GatePayload)
    $problems = @()
    if ($null -eq $GatePayload -or -not ($GatePayload -is [System.Collections.IDictionary])) {
        return @("design_review check: gate payload missing (bridge scenario form: run_id + node_id)")
    }
    $runId = [string]$GatePayload['run_id']
    $nodeId = [string]$GatePayload['node_id']
    if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($nodeId)) {
        return @("design_review check: gate payload missing run_id/node_id (bridge-only validator)")
    }
    $runDir = Get-BridgeRunDir $runId
    $bridge = Read-Bridge $runDir
    if ($null -eq $bridge) { return @("design_review check: run $runId not found (bridge.json unreadable)") }
    $p = Get-PlanSection $bridge
    if ($null -eq $p) { return @("design_review check: run $runId carries no plan section") }
    $stage = $null
    foreach ($st in @($p['stages'])) {
        $dr = $st['design_review']
        if ($null -ne $dr -and ([string]$dr['node']) -eq $nodeId) { $stage = $st; break }
    }
    if ($null -eq $stage) { return @("design_review check: node $nodeId is not a [设计审查·S<k>] node of run $runId") }
    $stageId = [string]$stage['id']
    $flow = Read-ArchiveTasks $bridge.archive
    $dd = Get-StageDesignDocs $bridge $stage $flow.tasks
    $expected = @($dd.docs)
    if ($expected.Count -eq 0) { return @("design_review check: stage $stageId has no on-disk design products — its review node should not exist (replan recovered it)") }
    $rv = Read-DesignReviewFile ([string]$bridge.archive) $stageId
    if (-not $rv.ok) { return @("design_review check: $($rv.error)") }
    return @(Test-DesignReviewFileCore $rv.data $stageId $expected)
}

function Get-DesignReviewDimCounts {
    # 审查数据维度统计（Add-DesignReviewLedger 子过程）：blocking 按 dimension 计数
    # （cross_design 项归 cross_design 维）+ advisory 总数。ReviewData=$null → 全零。
    param($ReviewData)
    $dims = @{}
    $advisory = 0
    if ($null -eq $ReviewData) { return @{ dims = $dims; advisory = 0 } }
    foreach ($d in @(Convert-ToSafeArray $ReviewData['docs'])) {
        foreach ($f in @(Convert-ToSafeArray $d['findings'])) {
            if (([string]$f['severity']) -eq 'blocking') {
                $dim = [string]$f['dimension']
                if (-not $dims.Contains($dim)) { $dims[$dim] = 0 }
                $dims[$dim] = [int]$dims[$dim] + 1
            }
            else { $advisory++ }
        }
    }
    foreach ($f in @(Convert-ToSafeArray $ReviewData['summary']['cross_design'])) {
        if (([string]$f['severity']) -eq 'blocking') {
            if (-not $dims.Contains('cross_design')) { $dims['cross_design'] = 0 }
            $dims['cross_design'] = [int]$dims['cross_design'] + 1
        }
        else { $advisory++ }
    }
    return @{ dims = $dims; advisory = $advisory }
}

function New-DesignReviewRefluxLines {
    # 回流建议行构造（Add-DesignReviewLedger 子过程）：同 dimension blocking 同
    # run（账本既有条目 + 本次计数）累计 ≥3 → kind=reflux_suggestion 建议行（只建
    # 议不代建）。best-effort：读账本失败返回空。
    param($Bridge, [string]$StageId, [string]$At, $DimCounts, [string]$ReviewerText = 'auditor')
    $lines = @()
    try {
        $ledgerPath = Join-Path $repoRoot ".rdd/review-ledger.jsonl"
        $perDim = @{}
        $runTag = '"run_id":"' + [string]$Bridge.run_id + '"'
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            foreach ($line in @([System.IO.File]::ReadAllLines($ledgerPath))) {
                if ([string]::IsNullOrWhiteSpace($line) -or ($line -notlike '*"kind":"blocking"*') -or ($line -notlike "*$runTag*")) { continue }
                try {
                    $g = [string]($line | ConvertFrom-Json).gap_type
                    if (-not [string]::IsNullOrWhiteSpace($g)) {
                        if (-not $perDim.Contains($g)) { $perDim[$g] = 0 }
                        $perDim[$g] = [int]$perDim[$g] + 1
                    }
                } catch { }
            }
        }
        foreach ($k in @($DimCounts.Keys)) {
            $total = [int]$DimCounts[$k] + $(if ($perDim.Contains($k)) { [int]$perDim[$k] } else { 0 })
            if ($total -ge 3) {
                $lines += (ConvertTo-PortableJson ([ordered]@{
                    at = $At; archive = [string]$Bridge.archive_rel; reviewer = $ReviewerText; kind = "reflux_suggestion"
                    gap_type = $k; run_id = [string]$Bridge.run_id; stage = $StageId
                    detail = "同 dimension blocking 同 run 累计 $total 次（≥3）——建议生成 CTO 模板/流程改进需求（只建议不代建）"
                }) -Depth 6)
            }
        }
    }
    catch { }
    return @($lines)
}

function Get-DesignReviewLedgerReviewer {
    # 账本署名（验收 4 统一新枚举）：优先 DesignReviewFile 的 reviewer 字段；读入
    # 失败按链推导缺省（subagent→auditor-delegated / session→auditor / 缺键 legacy
    # →auditor，旧链署名逐字节不变）。
    param($Bridge, $ReviewData)
    if ($null -ne $ReviewData -and -not [string]::IsNullOrWhiteSpace([string]$ReviewData['reviewer'])) { return [string]$ReviewData['reviewer'] }
    $modeText = Get-BridgeReviewMode $Bridge
    if ($modeText -eq 'subagent') { return 'auditor-delegated' }
    return 'auditor'
}

function Add-DesignReviewLedger {
    # 触发记账（验收 8）：审查结论明细入 `.rdd/review-ledger.jsonl`（全局单文件
    # JSONL，账本范式追加不重写）——kind=design_review 汇总条目（含维度分布）+
    # fail 时逐 blocking 条目（kind=blocking，gap_type=dimension）；同 dimension 同
    # run blocking ≥3 次 → 追加回流建议条目（只建议不代建）。best-effort：追加失败
    # 只落 plan-log 警示，不阻塞流转。统计/回流判定拆分至两个子过程。
    # 返回 $Bridge（链式透传，桥内容不变）。
    param([string]$RunDir, $Bridge, $Stage, $ReviewData, [string]$Verdict, $Blocking, [string]$ReviewerText = 'auditor')
    $at = Get-UtcNowIso
    $stageId = [string]$Stage['id']
    $counts = Get-DesignReviewDimCounts $ReviewData
    $dimCounts = @{}
    foreach ($k in @($counts.dims.Keys)) { $dimCounts[$k] = [int]$counts.dims[$k] }
    # 审查对象面（doc -> tasks 归属，gap 定位用；best-effort 不失败）
    $dd = @{ docs = @(); doc_tasks = @{} }
    try {
        $flow = Read-ArchiveTasks $Bridge.archive
        $dd = Get-StageDesignDocs $Bridge $Stage $flow.tasks
    } catch { }
    $lines = @()
    $lines += (ConvertTo-PortableJson ([ordered]@{
        at = $at; archive = [string]$Bridge.archive_rel; reviewer = $ReviewerText; kind = "design_review"
        run_id = [string]$Bridge.run_id; stage = $stageId; verdict = $Verdict
        docs_count = @(Convert-ToSafeArray $ReviewData['docs']).Count
        blocking_count = @($Blocking).Count; advisory_count = [int]$counts.advisory; dimension_counts = $dimCounts
    }) -Depth 6)
    foreach ($b in @($Blocking)) {
        # doc 归属任务取审查对象面的第一个在册归属（gap 定位用，非路由语义）
        $tid = $null
        $owners = @($dd.doc_tasks[[string]$b['doc']])
        if ($owners.Count -gt 0) { $tid = [int]$owners[0] }
        $lines += (ConvertTo-PortableJson ([ordered]@{
            at = $at; archive = [string]$Bridge.archive_rel; reviewer = $ReviewerText; kind = "blocking"
            gap_type = [string]$b['dimension']; task_id = $tid; run_id = [string]$Bridge.run_id; stage = $stageId
            detail = [ordered]@{ doc = [string]$b['doc']; item = [string]$b['item']; suggestion = [string]$b['suggestion'] }
        }) -Depth 6)
    }
    $lines += @(New-DesignReviewRefluxLines $Bridge $stageId $at $dimCounts $ReviewerText)
    try {
        $ledgerPath = Join-Path $repoRoot ".rdd/review-ledger.jsonl"
        $dir = Split-Path $ledgerPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        foreach ($ln in @($lines)) { [System.IO.File]::AppendAllText($ledgerPath, $ln + "`n", $script:Utf8NoBom) }
    }
    catch {
        $null = Add-PlanEvent $RunDir 'deviation' 'design_review_ledger_failed' ([string]$Stage['design_review']['node']) $null $stageId @{ error = [string]$_.Exception.Message }
    }
    return $Bridge
}

function Get-DesignReviewDocRoles {
    # 重做目标角色映射（后缀精确映射，技术方案）：`<name>-cto.md`→CTO / `-ux.md`→UX /
    # `-qa.md`→QA；无后缀命中 → 任务在本 run 内做过的 DESIGN 角色（bridge 链记录）；
    # 仍空 → CTO（设计默认责任）。
    param([string]$DocRel, $BridgeTask)
    $base = [System.IO.Path]::GetFileName([string]$DocRel)
    if ($base -match '-cto\.md$') { return @('CTO') }
    if ($base -match '-ux\.md$') { return @('UX') }
    if ($base -match '-qa\.md$') { return @('QA') }
    if ($null -ne $BridgeTask -and $BridgeTask.Contains('stages') -and $null -ne $BridgeTask['stages']) {
        $roles = @()
        foreach ($role in @($script:PhaseRoles['DESIGN'])) {
            if ($BridgeTask['stages'].Contains($role) -and $roles -notcontains $role) { $roles += $role }
        }
        if ($roles.Count -gt 0) { return @($roles) }
    }
    return @('CTO')
}

function Resolve-DesignReviewGraftParent {
    # 兄弟挂接锚点（rollback 原语 Resolve-RollbackGraftParent 同构）：任务在本 run
    # 内的 DESIGN 阶段节点（done 审计痕保留）的 parent；无记录 → goal root（链头层
    # ——promulgate 不变量）。
    param([string]$RunId, $Bridge, [int]$TaskId)
    $goalRoot = [string]$Bridge.goal_root
    if ([string]::IsNullOrWhiteSpace($goalRoot)) { $goalRoot = "n1" }
    if (-not $Bridge.tasks.Contains("$TaskId")) { return $goalRoot }
    $bTask = $Bridge.tasks["$TaskId"]
    if (-not ($bTask.Contains('stages') -and $null -ne $bTask['stages'])) { return $goalRoot }
    foreach ($role in @($script:PhaseRoles['DESIGN'])) {
        if (-not $bTask['stages'].Contains($role)) { continue }
        $nid = [string]$bTask['stages'][$role]
        if ([string]::IsNullOrWhiteSpace($nid)) { continue }
        $parent = Get-NodeParentSafe $RunId $nid
        if (-not [string]::IsNullOrWhiteSpace($parent)) { return $parent }
    }
    return $goalRoot
}

function Get-DesignReviewTaskBlockers {
    # blocking -> 受影响任务映射（Invoke-DesignReviewFailWave 子过程）：tid -> @(
    # blocking)；文件不可读时全部有产物任务按审查失败整体回退（空 blocking 列表）。
    param($ReviewRead, $StageDocs)
    $taskBlockers = @{}
    if ($ReviewRead.ok) {
        $dv = Get-DesignReviewVerdict $ReviewRead.data
        foreach ($b in @($dv.blocking)) {
            foreach ($tid in @($StageDocs.doc_tasks[[string]$b['doc']])) {
                $t = [int]$tid
                if (-not $taskBlockers.Contains($t)) { $taskBlockers[$t] = @() }
                $taskBlockers[$t] += ,$b
            }
        }
    }
    else {
        foreach ($rel in @($StageDocs.docs)) {
            foreach ($tid in @($StageDocs.doc_tasks[$rel])) {
                if (-not $taskBlockers.Contains([int]$tid)) { $taskBlockers[[int]$tid] = @() }
            }
        }
    }
    return $taskBlockers
}

function Invoke-DesignReviewFailPrune {
    # 单任务波第 1 步（Invoke-DesignReviewFailTask 子过程）：prune 活跃 DESIGN 后
    # 节点（DESIGN done 节点保留为审计痕；幂等：pruned/missing 容忍，其他失败仅告警
    # ——下一触发点自愈重入）。返回 warnings[]。
    param($Bridge, $BridgeTask, [int]$TaskId, [string]$PruneReason)
    $warnings = @()
    if ($null -eq $BridgeTask -or -not ($BridgeTask.Contains('stages') -and $null -ne $BridgeTask['stages'])) { return @() }
    $treeData = Get-TreeStatusView ([string]$Bridge.run_id)
    foreach ($role in @($BridgeTask['stages'].Keys)) {
        if (@($script:PhaseRoles['DESIGN']) -contains $role) { continue }
        $nid = [string]$BridgeTask['stages'][$role]
        if ([string]::IsNullOrWhiteSpace($nid)) { continue }
        $node = Get-NodeFromTree $treeData $nid
        $st = if ($node) { [string]$node.status } else { "missing" }
        if ($st -notin @('pending', 'claimed', 'reported')) { continue }
        $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", ([string]$Bridge.run_id), "-NodeId", $nid, "-Reason", $PruneReason)
        $code = ""
        if ($rp.exit -ne 0 -and $null -ne $rp.json -and $null -ne $rp.json.error) { $code = [string]$rp.json.error.code }
        if ($rp.exit -ne 0 -and $code -notin @('ALREADY_PRUNED', 'NODE_NOT_FOUND')) {
            $warnings += "fail-wave prune of $role node $nid (task #$TaskId) failed: $($rp.text)"
        }
    }
    return @($warnings)
}

function Invoke-DesignReviewFailTask {
    # 单任务波（Invoke-DesignReviewFailWave 子过程；rollback 原语语义，复用原语
    # 函数不复用 rollback CLI 守卫）：目标角色 = blocking docs 后缀精确映射（union，
    # 兜底 CTO）→ 1) Invoke-DesignReviewFailPrune → 2) set-route 回 DESIGN（失败 →
    # pending_sync + defer，不挂接不推送；skip 凭据诚实声明——同 rollback disposal
    # 纪律）→ 3) 兄弟挂接重建 DESIGN 组（blocking 合并注入重做上下文；活跃即跳过 =
    # 波重入幂等）。返回 @{ bridge; rolled; deferred; warnings }。
    param([string]$RunDir, $Bridge, $Stage, [string]$StageId, $Task, $BridgeTask, $TaskBlockers)
    $tid = [int]$Task.id
    $roles = @()
    foreach ($b in @($TaskBlockers)) {
        foreach ($r in @(Get-DesignReviewDocRoles ([string]$b['doc']) $BridgeTask)) {
            if ($roles -notcontains $r) { $roles += $r }
        }
    }
    if ($roles.Count -eq 0) { $roles = @('CTO') }
    $problems = @()
    foreach ($b in @($TaskBlockers)) {
        $problems += "[$([string]$b['dimension'])] $([string]$b['doc'])：$([string]$b['item'])（建议：$([string]$b['suggestion'])）"
    }
    if ($problems.Count -eq 0) {
        $problems = @("设计审查否决：[设计审查·$StageId] verdict=fail——设计产物未过汇聚五查，重产设计（明细见 review/design-review-$StageId.md）")
    }
    $pruneReason = "design review veto: [设计审查·$StageId] fail (task #$tid) — blocking: $($problems[0])"
    $warnings = @(Invoke-DesignReviewFailPrune $Bridge $BridgeTask $tid $pruneReason)
    $scanFile = Write-RollbackScanSkipFile $RunDir "design-review fail-wave disposal: [设计审查·$StageId] verdict=fail 否决当前设计 (delivery-bridge design review); not a DEV completion handoff"
    $toJoined = $roles -join '+'
    $r3 = Invoke-RddFlow @("-Command", "set-route", "-TaskId", "$tid", "-To", $toJoined, "-Phase", "DESIGN", "-Archive", $Bridge.archive, "-QualityScanFile", $scanFile)
    if ($r3.exit -ne 0 -or $null -eq $r3.json -or -not $r3.json.success) {
        $warnings += "fail-wave set-route failed for task #$tid — recorded as pending_sync (status touch retries, then the wave re-enters): $($r3.text)"
        $Bridge = Add-PendingSync $RunDir $Bridge ([string]$Stage['design_review']['node']) "set-route" "IMPL" $toJoined ($r3.text) -PhaseArg "DESIGN" -ScanEvidence $scanFile
        return @{ bridge = $Bridge; rolled = $null; deferred = $tid; warnings = @($warnings) }
    }
    $graftParent = Resolve-DesignReviewGraftParent ([string]$Bridge.run_id) $Bridge $tid
    $redo = @{ from_stage = "[设计审查·$StageId]"; reason = "设计审查否决：[设计审查·$StageId] verdict=fail"; problems = $problems }
    $rebuilt = @()
    $graftFailed = $false
    foreach ($role in @($roles)) {
        $live = Find-RollbackExistingGraft $Bridge $tid $role
        if ($null -ne $live) { $rebuilt += $live; continue }
        $g = Invoke-GraftNextStage $RunDir $Bridge $Task $graftParent $role -RedoContext $redo
        if ($g.success) { $Bridge = $g.bridge; $rebuilt += $g.node_id }
        else { $graftFailed = $true; $warnings += "fail-wave rebuilt $role node graft failed for task #$tid (retried on the next trigger): $($g.error)" }
    }
    if ($graftFailed) { return @{ bridge = $Bridge; rolled = $null; deferred = $tid; warnings = @($warnings) } }
    $rolled = @{ task_id = $tid; roles = @($roles); nodes = @($rebuilt); problems = @($problems) }
    return @{ bridge = $Bridge; rolled = $rolled; deferred = $null; warnings = @($warnings) }
}

function Invoke-DesignReviewFailWave {
    # fail 波（验收 1；settle 尾自动、lease 内）：逐受影响任务执行 rollback **原语**
    # 语义——审查否决 ≠ 交付不合格（单任务波体见 Invoke-DesignReviewFailTask）。
    # 全部受影响任务完成 → design_review 重置 planned + 旧审查节点回收（F6 槽位复用）
    # → 重做收敛后再审（覆盖重产重审）。任一步失败 → 状态留在 failed，下一触发点自愈重入
    # （prune 幂等 / set-route 幂等 / graft 活跃跳过）。重推由外层 auto-dispatch 同趟完成
    # （原作者会话 in-place redo 优先——AllowReuse 按触发点透传）。
    param([string]$RunDir, $Bridge, $Stage, $FlowTasks)
    $stageId = [string]$Stage['id']
    $rv = Read-DesignReviewFile ([string]$Bridge.archive) $stageId
    $dd = Get-StageDesignDocs $Bridge $Stage $FlowTasks
    $warnings = @(); $rolled = @(); $deferred = @()
    if (-not $rv.ok) {
        $warnings += "DesignReviewFile 不可读（$($rv.error)）——全部有产物任务按审查失败整体回退"
    }
    $taskBlockers = Get-DesignReviewTaskBlockers $rv $dd
    foreach ($tidKey in @($taskBlockers.Keys)) {
        $tid = [int]$tidKey
        $task = Find-ArchiveTask $FlowTasks $tid
        if ($null -eq $task) { continue }
        $bTask = $null
        if ($Bridge.tasks.Contains("$tid")) { $bTask = $Bridge.tasks["$tid"] }
        $one = Invoke-DesignReviewFailTask $RunDir $Bridge $Stage $stageId $task $bTask @($taskBlockers[$tid])
        $Bridge = $one.bridge
        $warnings += @($one.warnings)
        if ($null -ne $one.deferred) { $deferred += [int]$one.deferred }
        if ($null -ne $one.rolled) { $rolled += $one.rolled }
    }
    if (@($deferred).Count -eq 0) {
        # 全部受影响任务完成 → 重置 planned + 旧审查节点回收（F6）→ 覆盖重产重审
        $dr = $Stage['design_review']
        $oldNode = [string]$dr['node']
        Remove-InvalidatedDesignReviewNode $Bridge $oldNode $stageId
        $dr['status'] = 'planned'; $dr['node'] = $null; $dr['verdict'] = $null; $dr['reviewed_at'] = $null; $dr['basis'] = $null
        $null = Add-PlanEvent $RunDir 'deviation' 'design_review_invalidated' $oldNode $null $stageId @{ trigger = 'design_review_fail_wave'; reason = "review failed — designs rolled back to DESIGN for rework; re-review on next convergence" }
        Write-BridgeFile $RunDir $Bridge | Out-Null
    }
    return @{ bridge = $Bridge; rolled = @($rolled); deferred = @($deferred); warnings = @($warnings) }
}

function Update-DesignReviewPlanned {
    # planned 态推进（Update-StageDesignReviews 子过程）：触发判据 → wait 不动 /
    # exempt 快速通道 / graft [设计审查·S<k>]（旧链，失败下一触发点重试）/ 新链
    # ready（auditor-subagent-review：纯契约形态——无节点、无自动会话，plan-log
    # progress 事件 + status/next 视图提示派审；规划者派五查子代理产出
    # DesignReviewFile 后经 design-review -Action submit 入库）。
    # 返回 @{ bridge; grafted }（grafted = $null 表示无进展）。
    param([string]$RunDir, $Bridge, $Stage, $FlowTasks)
    $trig = Test-StageDesignTrigger $Bridge $Stage $FlowTasks
    if ($trig.mode -eq 'wait') { return @{ bridge = $Bridge; grafted = $null } }
    if ($trig.mode -eq 'exempt') {
        $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'exempt' $null 'design_review_exempt' @{ basis = $trig.reason }
        return @{ bridge = $Bridge; grafted = $null }
    }
    if ($null -ne (Get-BridgeReviewMode $Bridge)) {
        $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'ready' $null 'design_review_ready' @{
            docs     = @($trig.docs)
            template = $script:ReviewInputTemplateRel
            report   = ($script:DesignReviewReportFmt -f ([string]$Stage['id']))
            note     = "阶段设计汇聚审查就绪——按机械输入模板派评审子代理（独立上下文，禁转述），产出 DesignReviewFile 后 'delivery-bridge.cmd -Command design-review -Action submit -RunId $([string]$Bridge.run_id) -Stage $([string]$Stage['id'])'"
        }
        return @{ bridge = $Bridge; grafted = $null }
    }
    $accRef = $null
    $a = Get-AcceptanceSection $Bridge
    if ($null -ne $a) { $accRef = [string]$a['criteria_ref'] }
    $spec = New-StageDesignReviewSpec $Stage (Get-PlanStageReqRel $Bridge $Stage) ([string]$Bridge.run_id) @($trig.docs) $accRef
    $g = Invoke-GraftOne ([string]$Bridge.run_id) ([string]$Bridge.goal_root) $spec.item
    if (-not $g.ok) { return @{ bridge = $Bridge; grafted = $null } }   # retried on the next trigger
    $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'grafted' $g.node_id 'design_review_grafted' @{ title = $spec.title; docs = @($trig.docs) }
    return @{ bridge = $Bridge; grafted = @{ node = $g.node_id; title = $spec.title; stage = [string]$Stage['id'] } }
}

function Update-DesignReviewGrafted {
    # grafted 态推进（Update-StageDesignReviews 子过程）：节点 done → 从
    # DesignReviewFile 推导总裁定（引擎推导不采信声明值）→ 记账 → passed / failed
    # （failed 同趟落波——settle 尾租约内确定性完成）。返回 @{ bridge; wave }。
    param([string]$RunDir, $Bridge, $Stage, $FlowTasks)
    $dr = $Stage['design_review']
    $node = Get-NodeFromTree (Get-TreeStatusView ([string]$Bridge.run_id)) ([string]$dr['node'])
    if ($null -eq $node -or ([string]$node.status) -ne 'done') { return @{ bridge = $Bridge; wave = $null } }
    $rv = Read-DesignReviewFile ([string]$Bridge.archive) ([string]$Stage['id'])
    $verdict = 'fail'
    $blocking = @()
    if ($rv.ok) {
        $dv = Get-DesignReviewVerdict $rv.data
        $verdict = $dv.verdict
        $blocking = @($dv.blocking)
    }
    $Bridge = Add-DesignReviewLedger $RunDir $Bridge $Stage $(if ($rv.ok) { $rv.data } else { $null }) $verdict $blocking (Get-DesignReviewLedgerReviewer $Bridge $(if ($rv.ok) { $rv.data } else { $null }))
    # 裁定明细落段（verdict/reviewed_at/basis 与 status 同步持久化）
    $dr['verdict'] = $verdict
    $dr['reviewed_at'] = $(if ($rv.ok) { [string]$rv.data['reviewed_at'] } else { $null })
    if ($verdict -eq 'pass') {
        $dr['basis'] = "all docs pass with zero blocking findings (engine-derived)"
        $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'passed' ([string]$dr['node']) 'design_review_passed' @{
            verdict = 'pass'; reviewed_at = $dr['reviewed_at']
            basis = "all docs pass with zero blocking findings (engine-derived)"
        }
        return @{ bridge = $Bridge; wave = $null }
    }
    $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'failed' ([string]$dr['node']) 'design_review_failed' @{
        verdict = 'fail'; blocking_count = @($blocking).Count
        note = $(if (-not $rv.ok) { $rv.error } else { $null })
    }
    $wave = Invoke-DesignReviewFailWave $RunDir $Bridge $Stage $FlowTasks
    return @{ bridge = $wave.bridge; wave = $wave }
}

function Update-StageDesignReviews {
    # Stage design-review state machine——随每个 auto-dispatch 触发点重评（自愈，与
    # Update-StageAcceptancePoints 同放置位；graft/set-route 是状态非推送，no_push
    # 隔离下照常运行）。双链同机分支（auditor-subagent-review）：
    #   planned → 触发判据（全越过 DESIGN + ≥1 落盘产物 + 阶段有 DESIGN 节点）→
    #             旧链 graft [设计审查·S<k>] / 新链 ready（纯契约提示派审）/
    #             exempt（快速通道）—— Update-DesignReviewPlanned
    #   grafted → 旧链节点 done → 从 DesignReviewFile 推导总裁定 → passed / failed
    #             （记账）—— Update-DesignReviewGrafted（failed 同趟落波）
    #   ready   → 新链等待态：裁定经 design-review -Action submit（规划者提交子代理
    #             产物）落 passed|failed，本状态机不推进（防重派提示不漂移）
    #   failed  → fail 波进行中（可重入；完成 → planned 重置 + 旧节点回收[无节点
    #             时为空操作]）
    param([string]$RunDir, $Bridge)
    $out = @{ bridge = $Bridge; grafted = @(); wave = $null }
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $out }
    $pending = @($p['stages'] | Where-Object {
        $null -ne $_['design_review'] -and @('passed', 'exempt') -notcontains ([string]$_['design_review']['status'])
    })
    if ($pending.Count -eq 0) { return $out }
    $flow = Read-ArchiveTasks $Bridge.archive
    foreach ($st in @($pending)) {
        $status = [string]$st['design_review']['status']
        if ($status -eq 'planned') {
            $one = Update-DesignReviewPlanned $RunDir $out.bridge $st $flow.tasks
            $out.bridge = $one.bridge
            if ($null -ne $one.grafted) { $out.grafted += $one.grafted }
        }
        elseif ($status -eq 'grafted') {
            $one = Update-DesignReviewGrafted $RunDir $out.bridge $st $flow.tasks
            $out.bridge = $one.bridge
            if ($null -ne $one.wave) { $out.wave = $one.wave }
        }
        elseif ($status -eq 'failed') {
            $wave = Invoke-DesignReviewFailWave $RunDir $out.bridge $st $flow.tasks
            $out.bridge = $wave.bridge
            $out.wave = $wave
        }
    }
    return $out
}

function Remove-InvalidatedDesignReviewNode {
    # 失效回收（F6 同构）：失效波解绑 design_review 时旧 [设计审查·S<k>] 节点归还
    # goal-root 子位。幂等：missing/already-pruned = 槽位已还；其他 prune 失败硬错
    # （rerun-safe：未解绑前不动状态）。审计：pruned_reason 留痕。
    param($Bridge, [string]$NodeId, [string]$StageId)
    if ([string]::IsNullOrWhiteSpace($NodeId)) { return }
    $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", ([string]$Bridge.run_id), "-NodeId", $NodeId, "-Reason", "design review invalidated: $StageId")
    if ($rp.exit -eq 0 -and $null -ne $rp.json -and $rp.json.success) { return }
    $code = ""
    if ($null -ne $rp.json -and $null -ne $rp.json.error) { $code = [string]$rp.json.error.code }
    if ($code -eq "ALREADY_PRUNED" -or $code -eq "NODE_NOT_FOUND") { return }
    Write-ErrorResult "INVALIDATION_PRUNE_FAILED" "invalidation wave could not reclaim stale design review node $NodeId (stage $StageId): $($rp.text)" 1
}

function Get-DesignReviewGateBlockers {
    # 设计审查闸门（验收 1：审查未过 IMPL 不解锁）：任务所在阶段的 design_review
    # 未 passed/exempt 且（a）节点角色为 DESIGN 后角色（DEV；QA 仅在任务 phase 已到
    # IMPL/VERIFY——DESIGN 内测试先行 QA 不占闸门）且（b）任务携带落盘设计产物
    # （无产物任务不占闸门）→ 阻塞。返回 @(stage id)；空 = 门开（旧 run 无段零成本）。
    param($Bridge, [int]$TaskId, [string]$StageRole)
    if ([string]::IsNullOrWhiteSpace($StageRole)) { return @() }
    if (@('DEV', 'QA') -notcontains $StageRole) { return @() }
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return @() }
    $st = Get-PlanStageOfTask $p $TaskId
    if ($null -eq $st) { return @() }
    $dr = $st['design_review']
    if ($null -eq $dr) { return @() }
    if (@('passed', 'exempt') -contains ([string]$dr['status'])) { return @() }
    $task = $null
    foreach ($t in @(Get-DesignReviewFlowTasks $Bridge)) {
        if ([int]$t.id -eq $TaskId) { $task = $t; break }
    }
    if ($null -eq $task) { return @() }
    $hasDoc = $false
    foreach ($d in @(Convert-ToSafeArray $task.designDocs)) {
        $rel = (([string]$d.path) -replace '\\', '/')
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if (Test-Path -LiteralPath (Join-Path ([string]$Bridge.archive) ($rel -replace '/', '\')) -PathType Leaf) { $hasDoc = $true; break }
    }
    if (-not $hasDoc) { return @() }
    if ($StageRole -eq 'QA') {
        $ph = $null
        if (Test-PropPresent $task 'phase') { $ph = [string]$task.phase }
        if ($ph -notin @('IMPL', 'VERIFY')) { return @() }
    }
    return @([string]$st['id'])
}

function Assert-DesignReviewGateOpen {
    # NODE_BLOCKED_BY_DESIGN_REVIEW——与 NODE_BLOCKED_BY_GATE 同族（验收 1）：
    # [设计审查·S<k>] 未过（pass/exempt）时有设计产物在册任务的 IMPL/VERIFY 节点
    # 认领/分发硬拒；push 候选 skip 同因（reason 分列，AND 栈叠）。pass 后下一触发
    # 点自动放行（自愈免费）；无 Force 旁路。
    param($Bridge, [int]$TaskId, [string]$StageRole)
    $blockers = Get-DesignReviewGateBlockers $Bridge $TaskId $StageRole
    if (@($blockers).Count -gt 0) {
        Write-ErrorResult "NODE_BLOCKED_BY_DESIGN_REVIEW" "Task #$TaskId ($StageRole) sits behind an open design review — stage(s): [$($blockers -join ', ')]. Land a passing DesignReviewFile first (legacy chain: settle the [设计审查·S<k>] node; review_mode chain: delivery-bridge.cmd -Command design-review -Action submit) — pass 才放行 IMPL；fail 自动触发重做波; or replan to re-scope the stage; no force bypass." 1
    }
}

# === Command: design-review (auditor-subagent-review，纯契约入库) ===
#
# 新链（bridge.json review_mode 存在）设计汇聚审查的唯一裁定入口：规划者派五查
# 评审子代理（输入 = review-input-template.md 机械清单，独立上下文）产出
# DesignReviewFile 后经 -Action submit 入链；契约校验与 node settle 同源
# （Test-DesignReviewFileCore，决策 #6），总裁定引擎推导（不采信声明值），fail
# 触发既有重做波（无节点可回收——状态重置 + 覆盖重产）。缺键 legacy run 不适用
# （照旧 settle [设计审查·S<k>] 节点，行为不回溯）。评审子代理不经 bridge
# claim/settle——它不是树节点，产物经规划者入链。

function Get-DesignReviewSubmitStage {
    # -Stage 解析（Invoke-DesignReviewSubmit 前置）：plan.stages 内带 design_review
    # 槽位的阶段。返回 @{ ok; stage; error }（error = @{ code; message }）。
    param($Bridge, [string]$StageIdText)
    if ([string]::IsNullOrWhiteSpace($StageIdText)) {
        return @{ ok = $false; stage = $null; error = @{ code = "MISSING_STAGE"; message = "design-review requires -Stage <S<k>> (the plan stage id whose review product is submitted)" } }
    }
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) {
        return @{ ok = $false; stage = $null; error = @{ code = "PLAN_SECTION_MISSING"; message = "run carries no plan section — design review is a plan-stage mechanism" } }
    }
    foreach ($st in @($p['stages'])) {
        if (([string]$st['id']) -ne $StageIdText) { continue }
        if ($null -eq $st['design_review']) {
            return @{ ok = $false; stage = $null; error = @{ code = "DESIGN_REVIEW_SECTION_MISSING"; message = "stage $StageIdText carries no design_review slot (pre-feature run shape)" } }
        }
        return @{ ok = $true; stage = $st; error = $null }
    }
    return @{ ok = $false; stage = $null; error = @{ code = "STAGE_NOT_FOUND"; message = "stage '$StageIdText' not found in the run's plan" } }
}

function Invoke-DesignReviewSubmitGate {
    # submit 门（Invoke-DesignReviewSubmit 前置拆分）：状态必须 ready（提前/重复
    # 提交确定性拒绝——触发判据与派审时序不可跳过）→ 审查对象面 → DesignReviewFile
    # 读入 → 契约核心校验（违规 SETTLE_EVIDENCE_REJECTED 问题清单、修复重报）。
    # 返回 @{ bridge; stage; stage_id; mode; review; expected }（不通过即硬错退出）。
    param($Bridge, $Stage, [string]$ModeText)
    $stageId = [string]$Stage['id']
    $status = [string]$Stage['design_review']['status']
    if ($status -ne 'ready') {
        Write-ErrorResult "DESIGN_REVIEW_NOT_READY" "stage $stageId design_review is '$status' — submit is accepted only in 'ready'（触发判据达成后的派审态）; fail 波进行中待其完成重置 planned 再审，passed/failed 不接受重复提交" 1
    }
    $flow = Read-ArchiveTasks $Bridge.archive
    $dd = Get-StageDesignDocs $Bridge $Stage $flow.tasks
    $expected = @($dd.docs)
    $rv = Read-DesignReviewFile ([string]$Bridge.archive) $stageId
    if (-not $rv.ok) { Write-ErrorResult "SETTLE_EVIDENCE_REJECTED" "Unqualified delivery — nothing transitioned. Problems: design_review check: $($rv.error)" 1 }
    $problems = @()
    if ($expected.Count -eq 0) {
        $problems += "design_review check: stage $stageId has no on-disk design products — the review was invalidated before submit (重触发后覆盖重产重审)"
    }
    else {
        $problems = @(Test-DesignReviewFileCore $rv.data $stageId $expected)
    }
    if ($problems.Count -gt 0) {
        Write-ErrorResult "SETTLE_EVIDENCE_REJECTED" "Unqualified delivery — nothing transitioned. Problems: $($problems -join '; ')（修复 DesignReviewFile 后重报）" 1
    }
    return @{ bridge = $Bridge; stage = $Stage; stage_id = $stageId; mode = $ModeText; review = $rv.data; expected = $expected }
}

function Submit-DesignReviewVerdict {
    # 裁定落账（Invoke-DesignReviewSubmit 主体拆分）：总裁定引擎推导（不采信声明
    # 值）→ review-ledger 记账（署名 = reviewer 枚举）→ passed / failed（fail 同趟
    # 落波，与 legacy grafted 路径同一 fail 波实现——无节点时回收为空操作）。
    # 返回 @{ bridge; verdict; blocking; wave; reviewed_at; reviewer }。
    param([string]$RunDir, $Bridge, $Stage, [string]$ModeText, $ReviewData)
    $stageId = [string]$Stage['id']
    $dv = Get-DesignReviewVerdict $ReviewData
    $verdict = [string]$dv.verdict
    $blocking = @($dv.blocking)
    $reviewerText = Get-DesignReviewLedgerReviewer $Bridge $ReviewData
    $Bridge = Add-DesignReviewLedger $RunDir $Bridge $Stage $ReviewData $verdict $blocking $reviewerText
    $dr = $Stage['design_review']
    $dr['verdict'] = $verdict
    $dr['reviewed_at'] = [string]$ReviewData['reviewed_at']
    $basis = "all docs pass with zero blocking findings (engine-derived; design-review submit, mode=$ModeText)"
    if ($verdict -eq 'pass') {
        $dr['basis'] = $basis
        $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'passed' $null 'design_review_passed' @{
            verdict = 'pass'; reviewed_at = $dr['reviewed_at']; mode = $ModeText; reviewer = $reviewerText; basis = $basis
        }
        return @{ bridge = $Bridge; verdict = $verdict; blocking = @($blocking); wave = $null; reviewed_at = $dr['reviewed_at']; reviewer = $reviewerText }
    }
    $Bridge = Set-DesignReviewState $RunDir $Bridge $Stage 'failed' $null 'design_review_failed' @{
        verdict = 'fail'; blocking_count = @($blocking).Count; mode = $ModeText; reviewer = $reviewerText
        note = "design-review submit verdict=fail — fail 波重做（状态重置 + 覆盖重产，无节点可回收）"
    }
    $flowTasks = @(Get-DesignReviewFlowTasks $Bridge)
    $wave = Invoke-DesignReviewFailWave $RunDir $Bridge $Stage $flowTasks
    return @{ bridge = $wave.bridge; verdict = $verdict; blocking = @($blocking); wave = $wave; reviewed_at = $dr['reviewed_at']; reviewer = $reviewerText }
}

function New-DesignReviewSubmitResult {
    # submit 回执（Invoke-DesignReviewSubmit 尾部拆分）：裁定 + 落点 + fail 波效果
    # + 同趟 auto-dispatch 结果（pass 解锁的 IMPL 节点即时推送）。
    param([string]$RunIdText, $Stage, [string]$ModeText, $ReviewData, $Adjudged, $Push)
    $stageId = [string]$Stage['id']
    return @{
        success = $true
        data    = @{
            run_id      = $RunIdText
            stage       = $stageId
            review_mode = $ModeText
            verdict     = [string]$Adjudged.verdict
            status      = [string]$Stage['design_review']['status']
            reviewed_at = [string]$Adjudged.reviewed_at
            reviewer    = [string]$Adjudged.reviewer
            production  = $(if (Test-PropPresent $ReviewData 'production') { $ReviewData['production'] } else { $null })
            report      = ($script:DesignReviewReportFmt -f $stageId)
            blocking    = @($Adjudged.blocking | ForEach-Object { @{ doc = [string]$_.doc; dimension = [string]$_.dimension; item = [string]$_.item; suggestion = [string]$_.suggestion } })
            wave        = $(if ($null -ne $Adjudged.wave) { @{ rolled = @($Adjudged.wave.rolled); deferred = @($Adjudged.wave.deferred); warnings = @($Adjudged.wave.warnings) } } else { $null })
            auto_push   = @{ trigger = $Push.trigger; pushed = @($Push.pushed); blocked = @($Push.skipped | Where-Object { $_.reason -eq 'blocked_by_deps' } | ForEach-Object { $_.node }); failed = @($Push.failed) }
            next_step   = $(if ([string]$Adjudged.verdict -eq 'pass') { "stage $stageId design review passed (engine-derived) — IMPL 闸门已开，后续触发点照常推送" } else { "verdict=fail — fail 波已执行：受影响任务回 DESIGN 重做，重做收敛后状态机重新置 ready（覆盖重产重审）" })
        }
    }
}

function Invoke-DesignReviewSubmit {
    # design-review -Action submit 主编排（门序拆分至三个子过程，函数行数整改纪律）：
    # legacy 拒绝 → -Stage 解析 → submit 门（ready + 契约）→ 裁定落账 → 回执。
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $modeText = Get-BridgeReviewMode $bridge
    if ($null -eq $modeText) {
        Write-ErrorResult "DESIGN_REVIEW_LEGACY_RUN" "run $RunId carries no review_mode (缺键 legacy chain) — adjudicate its [设计审查·S<k>] node via -Command settle instead（既有节点照常结算，行为不回溯）" 1
    }
    $null = Enter-PlannerLease $runDir
    $res = Get-DesignReviewSubmitStage $bridge $Stage
    if (-not $res.ok) { Write-ErrorResult $res.error.code $res.error.message 1 }
    $gate = Invoke-DesignReviewSubmitGate $bridge $res.stage $modeText
    $adjudged = Submit-DesignReviewVerdict $runDir $gate.bridge $gate.stage $gate.mode $gate.review
    $push = Invoke-AutoDispatch $runDir $adjudged.bridge "design-review submit"
    return New-DesignReviewSubmitResult $RunId $gate.stage $gate.mode $gate.review $adjudged $push
}

function Get-DesignReviewStatusView {
    # design-review -Action status 只读派审面：逐阶段审查状态 + 机械输入清单（docs /
    # criteria_ref / conventions / report 落点 / 模板 ref / production 常量）——规划
    # 者填充 review-input-template.md 的全部可填充物由此机械导出，零转述零裁量。
    param($Bridge)
    $modeText = Get-BridgeReviewMode $Bridge
    $rows = @()
    $p = Get-PlanSection $Bridge
    if ($null -ne $p) {
        $flowTasks = @(Get-DesignReviewFlowTasks $Bridge)
        $a = Get-AcceptanceSection $Bridge
        foreach ($st in @($p['stages'])) {
            $dr = $st['design_review']
            if ($null -eq $dr) { continue }
            $dd = Get-StageDesignDocs $Bridge $st $flowTasks
            $rows += [ordered]@{
                stage       = [string]$st['id']
                status      = [string]$dr['status']
                verdict     = $(if ([string]::IsNullOrWhiteSpace([string]$dr['verdict'])) { $null } else { [string]$dr['verdict'] })
                docs        = @($dd.docs)
                criteria_ref = $(if ($null -ne $a) { [string]$a['criteria_ref'] } else { $null })
                conventions = Get-ConventionsRef $Bridge
                report      = ($script:DesignReviewReportFmt -f ([string]$st['id']))
                template    = $script:ReviewInputTemplateRel
                production  = @{ mode = $(if ($null -ne $modeText) { $modeText } else { 'subagent' }); template = $script:ReviewInputTemplateRel }
            }
        }
    }
    return @{
        success = $true
        data    = @{
            run_id      = [string]$Bridge.run_id
            review_mode = $modeText
            chain       = $(if ($null -ne $modeText) { "contract (submit)" } else { "legacy (node settle)" })
            reviewers   = @($script:DesignReviewReviewers)
            stages      = @($rows)
            next_step   = $(if (@($rows | Where-Object { [string]$_.status -eq 'ready' }).Count -gt 0) { "有 ready 阶段：按模板常量表填充 review-input-template.md 机械清单派评审子代理（独立上下文），产出 DesignReviewFile 后 -Action submit 入库" } else { "无待派审阶段" })
        }
    }
}

function Invoke-BridgeDesignReview {
    # design-review 命令族（auditor-subagent-review）：动作仅 submit|status——其余
    # 动作值属 conflict/derive，此处确定性拒绝（各命令守卫自己的动作集）。
    if (@('open', 'resolve', 'propose', 'confirm', 'withdraw') -contains $Action) {
        Write-ErrorResult "DESIGN_REVIEW_ACTION_INVALID" "-Action $Action belongs to conflict/derive — design-review accepts submit / status" 1
    }
    if ($Action -eq 'submit') { return Invoke-DesignReviewSubmit }
    if ($Action -eq 'status') {
        $runDir = Get-BridgeRunDir $RunId
        $bridge = Require-Bridge $runDir
        return Get-DesignReviewStatusView $bridge
    }
    Write-ErrorResult "DESIGN_REVIEW_ACTION_REQUIRED" "-Action is required (submit / status)" 1
}

function Test-PlanEventSeen {
    # deviation dedup: one event per (kind, event, key) observation signature —
    # the ledger stays replayable without spamming identical rows.
    param($Entries, [string]$EventName, [string]$Key, [string]$Signature)
    foreach ($e in @($Entries)) {
        if (([string]$e['kind']) -ne 'deviation' -or ([string]$e['event']) -ne $EventName) { continue }
        $d = $e['detail']
        if ($null -eq $d -or -not ($d -is [System.Collections.IDictionary])) { continue }
        if (([string]$d['key']) -eq $Key -and ([string]$d['signature']) -eq $Signature) { return $true }
    }
    return $false
}

function Write-PlanPatrolDeviations {
    # rolling reconciliation patrol (status touch): delay over the shared 60min
    # threshold + mid-run scope shrink (delivered task deprecated) — compared
    # against the plan entries, deduped per observation signature.
    param([string]$RunDir, $Bridge, $TreeData, $FlowTasks)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return @() }
    $log = Read-PlanLogEntries $RunDir
    $found = @()
    foreach ($c in @(Convert-ToSafeArray $TreeData.nodes.claimed)) {
        $node = [string]$c.id
        if ([string]::IsNullOrWhiteSpace($node)) { $node = [string]$c.node }
        $map = Get-NodeTaskStage $Bridge $node
        if ($null -eq $map) { continue }
        $stage = Get-PlanStageOfTask $p ([int]$map.task_id)
        if ($null -eq $stage) { continue }
        $claimedAt = [string]$c.claimed_at
        if (Test-PlanEventSeen $log.entries 'delay' $node $claimedAt) { continue }
        $null = Add-PlanEvent $RunDir 'deviation' 'delay' $node ([int]$map.task_id) ([string]$stage['id']) @{ key = $node; signature = $claimedAt; age_min = [int]$c.age_min; threshold_min = $DeadClaimMinutes }
        $found += "delay:$node"
    }
    foreach ($t in @($FlowTasks)) {
        if (([string]$t.lifecycle) -ne 'deprecated') { continue }
        $tid = [int]$t.id
        if (-not $Bridge.tasks.Contains("$tid")) { continue }
        if (Test-PlanEventSeen $log.entries 'scope' "task#$tid" 'deprecated') { continue }
        $stage = Get-PlanStageOfTask $p $tid
        $null = Add-PlanEvent $RunDir 'deviation' 'scope' $null $tid $(if ($null -ne $stage) { [string]$stage['id'] } else { $null }) @{ key = "task#$tid"; signature = 'deprecated'; note = "delivered task deprecated mid-run (范围变化)" }
        $found += "scope:task#$tid"
    }
    return @($found)
}

function Write-PlanSettleTail {
    # settle tail bookkeeping: progress event for the settled node + the
    # settle-time deviation checks (task outside the plan / an earlier stage's
    # acceptance still open while a later task landed).
    param([string]$RunDir, $Bridge, $Target, [string]$NodeIdText)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return }
    if ($Target.tree_level) {
        $sa = Get-StageAcceptanceNodeInfo $Bridge $NodeIdText
        if ($null -ne $sa) {
            $null = Add-PlanEvent $RunDir 'progress' 'acceptance_node_settled' $NodeIdText $null ([string]$sa.stage_id) @{ note = "stage acceptance node settled — the state machine records the pass" }
        }
        $dr = Get-DesignReviewNodeInfo $Bridge $NodeIdText
        if ($null -ne $dr) {
            $null = Add-PlanEvent $RunDir 'progress' 'design_review_node_settled' $NodeIdText $null ([string]$dr.stage_id) @{ note = "design review node settled — the state machine derives the verdict from the DesignReviewFile (pass 放行 / fail 波)" }
        }
        return
    }
    $taskId = [int]$Target.task_id
    $stage = Get-PlanStageOfTask $p $taskId
    if ($null -eq $stage) {
        # planner-midrun-derive: a registered-unabsorbed derived task sits outside
        # the stages by design during the absorption window — no deviation noise
        # for it (the whitelist mirrors Test-PlanDeliveryFit's $ExemptIds).
        $exempt = @(Get-UnabsorbedDerivedTaskIds $Bridge)
        if ($exempt -contains $taskId) { return }
        $null = Add-PlanEvent $RunDir 'deviation' 'scope' $NodeIdText $taskId $null @{ key = "task#$taskId"; signature = 'settled_out_of_plan'; note = "settled task is not covered by any plan stage (范围变化)" }
        return
    }
    $null = Add-PlanEvent $RunDir 'progress' 'settle' $NodeIdText $taskId ([string]$stage['id']) @{ stage_role = [string]$Target.stage }
    foreach ($other in @($p['stages'])) {
        if (([string]$other['id']) -eq ([string]$stage['id'])) { break }
        if (([string]$other['acceptance_point']['status']) -eq 'passed') { continue }
        $null = Add-PlanEvent $RunDir 'deviation' 'order' $NodeIdText $taskId ([string]$stage['id']) @{ key = "task#$taskId"; signature = 'out_of_stage_order'; blocked_by = [string]$other['id']; note = "task landed while an earlier stage's acceptance point is still open" }
        break
    }
}

function Compare-PlanRevisions {
    # structured diff old plan section vs new PlanFile (the revision event's
    # changes[]): stage_added/removed/changed, task_moved, batches_changed,
    # acceptance_changed, risks_changed — replayable, never a file snapshot.
    param($OldSec, $Plan)
    $changes = @()
    $oldById = @{}
    foreach ($st in @($OldSec['stages'])) { $oldById[[string]$st['id']] = $st }
    $newById = @{}
    foreach ($st in @($Plan.stages)) { $newById[[string]$st.id] = $st }
    foreach ($sid in @($newById.Keys)) {
        if (-not $oldById.Contains($sid)) { $changes += @{ op = "stage_added"; stage = $sid; detail = "tasks [$(@($newById[$sid].task_ids) -join ', ')]" }; continue }
        $o = $oldById[$sid]; $n = $newById[$sid]
        $changes += @(Compare-PlanStageEntry $o $n)
    }
    foreach ($sid in @($oldById.Keys)) {
        if (-not $newById.Contains($sid)) { $changes += @{ op = "stage_removed"; stage = $sid; detail = "tasks [$(@($oldById[$sid]['task_ids']) -join ', ')]" } }
    }
    if ((ConvertTo-PortableJson @($OldSec['risks'])) -ne (ConvertTo-PortableJson @($Plan.risks))) {
        $changes += @{ op = "risks_changed"; stage = $null; detail = "risk list replaced" }
    }
    return @($changes)
}

function Compare-PlanStageEntry {
    # one common stage: field-level diff (task set move gets the explicit rows).
    param($OldStage, $NewStage)
    $rows = @()
    $sid = [string]$NewStage.id
    $oldTasks = @($OldStage['task_ids']); $newTasks = @($NewStage.task_ids)
    $movedIn = @($newTasks | Where-Object { $oldTasks -notcontains $_ })
    $movedOut = @($oldTasks | Where-Object { $newTasks -notcontains $_ })
    if ($movedIn.Count -gt 0 -or $movedOut.Count -gt 0) {
        $rows += @{ op = "task_moved"; stage = $sid; detail = "in [$($movedIn -join ', ')] out [$($movedOut -join ', ')]" }
    }
    if (([string]$OldStage['goal']) -ne ([string]$NewStage.goal) -or ([string]$OldStage['milestone']) -ne ([string]$NewStage.milestone)) {
        $rows += @{ op = "stage_changed"; stage = $sid; detail = "goal/milestone revised" }
    }
    if ((ConvertTo-PortableJson @($OldStage['batches'])) -ne (ConvertTo-PortableJson @($NewStage.batches))) {
        $rows += @{ op = "batches_changed"; stage = $sid; detail = "parallel batches re-cut" }
    }
    $oap = $OldStage['acceptance_point']; $nap = $NewStage.acceptance_point
    $sameAp = (([string]$oap['criteria_ref']) -eq ([string]$nap.criteria_ref)) -and
              ((ConvertTo-PortableJson @($oap['criteria_items'])) -eq (ConvertTo-PortableJson @($nap.criteria_items))) -and
              (([string]$oap['slice']) -eq ([string]$nap.slice))
    if (-not $sameAp) { $rows += @{ op = "acceptance_changed"; stage = $sid; detail = "acceptance point criteria/slice revised" } }
    return @($rows)
}

function Set-NewPlanStageReviewSlot {
    # replan 新增阶段的审查槽位（auditor-subagent-review × planner-midrun-derive
    # 集成面）：run 中途派生并入新阶段是 derive 通道的常态出口（同阶段吸收在派生
    # 任务带 DependsOn 时与审查触发条件互锁），而新段若无 design_review 段则其设计
    # 产物静默逃过阶段的边界审查——新链"评审强制、无 off 值"因此有缺口。
    # 新链（bridge.json review_mode 存在）恒落 planned 槽位，与 promulgate 段同构；
    # 缺键 legacy run 不落段（部署双探只在 promulgate 生效，逐字节不回改）。
    param([string]$RunDir, $Bridge, $Stage, [string]$StageId)
    $reviewMode = ""
    if (Test-PropPresent $Bridge 'review_mode') { $reviewMode = [string]$Bridge['review_mode'] }
    if ([string]::IsNullOrWhiteSpace($reviewMode)) { return }
    $Stage['design_review'] = @{ status = 'planned'; node = $null; verdict = $null; reviewed_at = $null; basis = $null }
    $null = Add-PlanEvent $RunDir 'progress' 'design_review_slot_staged' $null $null $StageId @{ trigger = 'replan'; reason = 'new stage lands a fresh design-review slot (review is mandatory in the review_mode chain)' }
}

function Merge-PlanRevision {
    # replan application: carry runtime acceptance state over for untouched
    # stages; stages whose verified content changed reset to planned (the
    # invalidation wave semantics) with an acceptance_invalidated record.
    param([string]$RunDir, $Bridge, $OldSec, $Plan, [string]$SourceText)
    $newSec = New-PlanSection $Plan $SourceText
    $newSec['revision'] = ([int]$OldSec['revision']) + 1
    $newSec['planned_at'] = [string]$OldSec['planned_at']
    foreach ($st in @($newSec['stages'])) {
        $sid = [string]$st['id']
        $old = $null
        foreach ($o in @($OldSec['stages'])) { if (([string]$o['id']) -eq $sid) { $old = $o; break } }
        if ($null -eq $old) { Set-NewPlanStageReviewSlot $RunDir $Bridge $st $sid; continue }
        $contentSame = ((ConvertTo-PortableJson @($old['task_ids'])) -eq (ConvertTo-PortableJson @($st['task_ids']))) -and
                       ((ConvertTo-PortableJson @($old['batches'])) -eq (ConvertTo-PortableJson @($st['batches']))) -and
                       (([string]$old['acceptance_point']['slice']) -eq ([string]$st['acceptance_point']['slice']))
        if ($contentSame -and ([string]$old['acceptance_point']['status']) -ne 'planned') {
            $st['acceptance_point']['status'] = [string]$old['acceptance_point']['status']
            $st['acceptance_point']['node'] = $old['acceptance_point']['node']
        }
        elseif (-not $contentSame -and ([string]$old['acceptance_point']['status']) -ne 'planned') {
            # 失效回收 (F6): the invalidated stage's old acceptance node is
            # reclaimed before the new plan section lands — its goal-root child
            # slot goes back to the budget and the re-graft reuses it.
            Remove-InvalidatedAcceptanceNode $Bridge ([string]$old['acceptance_point']['node']) $sid
            $null = Add-PlanEvent $RunDir 'deviation' 'acceptance_invalidated' ([string]$old['acceptance_point']['node']) $null $sid @{ trigger = 'replan'; reason = "stage content changed after acceptance" }
        }
        # auditor-design-stage-review: design_review 槽位随 replan 承载（旧段存在才
        # 落新段——部署状态以 promulgate 时为准，不做中途翻转）；内容未变承载运行态，
        # 内容已变重置 planned + 旧审查节点回收（覆盖重产重审，验收 7 失效波语义）。
        if ($null -ne $old['design_review']) {
            $st['design_review'] = @{ status = 'planned'; node = $null; verdict = $null; reviewed_at = $null; basis = $null }
            $oldDrStatus = [string]$old['design_review']['status']
            if ($contentSame -and $oldDrStatus -notin @('', 'planned')) {
                $st['design_review']['status'] = $oldDrStatus
                $st['design_review']['node'] = $old['design_review']['node']
                $st['design_review']['verdict'] = $old['design_review']['verdict']
                $st['design_review']['reviewed_at'] = $old['design_review']['reviewed_at']
                $st['design_review']['basis'] = $old['design_review']['basis']
            }
            elseif (-not $contentSame -and $oldDrStatus -notin @('', 'planned', 'exempt')) {
                Remove-InvalidatedDesignReviewNode $Bridge ([string]$old['design_review']['node']) $sid
                $null = Add-PlanEvent $RunDir 'deviation' 'design_review_invalidated' ([string]$old['design_review']['node']) $null $sid @{ trigger = 'replan'; reason = "stage content changed after design review" }
            }
        }
    }
    $Bridge['plan'] = $newSec
    Write-BridgeFile $RunDir $Bridge | Out-Null
    return $Bridge
}

function New-PlanStageRow {
    param($Stage, $Bridge, $FlowTasks)
    $done = 0; $total = 0
    foreach ($tid in @($Stage['task_ids'])) {
        $total++
        $task = $null
        if ($Bridge.tasks.Contains("$tid")) { $task = Find-ArchiveTask $FlowTasks ([int]$tid) }
        if ($null -eq $task -or ($script:PlanTerminalLifecycles -contains ([string]$task.lifecycle))) { $done++ }
    }
    $ap = $Stage['acceptance_point']
    $row = [ordered]@{
        id         = [string]$Stage['id']
        goal       = [string]$Stage['goal']
        milestone  = [string]$Stage['milestone']
        task_ids   = @($Stage['task_ids'])
        batches    = @($Stage['batches'])
        progress   = "$done/$total"
        acceptance = [ordered]@{
            status         = [string]$ap['status']
            node           = $(if (-not [string]::IsNullOrWhiteSpace([string]$ap['node'])) { [string]$ap['node'] } else { $null })
            criteria_ref   = $ap['criteria_ref']
            criteria_items = @($ap['criteria_items'])
            slice          = [string]$ap['slice']
        }
    }
    # auditor-design-stage-review: 审查状态透出（无段 = $null，旧 run 视图不变）
    if ($null -ne $Stage['design_review']) {
        $dr = $Stage['design_review']
        $row['design_review'] = [ordered]@{
            status      = [string]$dr['status']
            node        = $(if (-not [string]::IsNullOrWhiteSpace([string]$dr['node'])) { [string]$dr['node'] } else { $null })
            verdict     = $(if ($null -ne $dr['verdict']) { [string]$dr['verdict'] } else { $null })
            reviewed_at = $(if ($null -ne $dr['reviewed_at']) { [string]$dr['reviewed_at'] } else { $null })
        }
    }
    return $row
}

function Get-PlanView {
    # status/resume plan view (the human-facing收口 of the machine plan; no
    # separate plan document is ever written). $null = legacy run, no plan view.
    param([string]$RunDir, $Bridge)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $null }
    $flow = Read-ArchiveTasks $Bridge.archive
    $rows = @()
    foreach ($st in @($p['stages'])) { $rows += ,(New-PlanStageRow $st $Bridge $flow.tasks) }
    $log = Read-PlanLogEntries $RunDir
    $deviations = @($log.entries | Where-Object { ([string]$_['kind']) -eq 'deviation' })
    $revisions = @($log.entries | Where-Object { ([string]$_['kind']) -eq 'revision' })
    return [ordered]@{
        revision     = [int]$p['revision']
        source       = [string]$p['source']
        planned_at   = [string]$p['planned_at']
        applied_at   = [string]$p['applied_at']
        plan_log     = ".rdd/goal-trees/$($Bridge.run_id)/$script:PlanLogFileName"
        stages       = $rows
        risks        = @($p['risks'])
        deviation_count = $deviations.Count
        revision_count  = $revisions.Count
        recent_events   = @($log.entries | Select-Object -Last 6 | ForEach-Object { "$($_['entry_id']) $($_['kind'])/$($_['event'])$(if ($null -ne $_['stage']) { '@' + ([string]$_['stage']) })" })
        log_corrupt     = (@($log.bad).Count -gt 0)
    }
}

function Add-PlanAnnexLines {
    # 「计划完成度」区 (delivery-annex): stage goals/milestones + completion
    # + acceptance verdicts + the rolling records pointer. Legacy runs get an
    # explicit "no plan" line — the annex stays honest either way.
    param([string]$RunDir, $Bridge, $FlowTasks)
    $lines = @()
    $lines += "## 计划完成度"
    $lines += ""
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) {
        $lines += "- 无计划段（引入长程规划前的旧 run）"
        $lines += ""
        return $lines
    }
    $log = Read-PlanLogEntries $RunDir
    $lines += "- 计划载体：$([string]$p['source'])（revision $([int]$p['revision'])）；进度/风险/偏差/修正账本：plan-log.jsonl"
    $lines += ""
    $lines += "| 阶段 | 目标 | 里程碑 | 任务 | 完成度 | 集成验收点 | 设计审查 |"
    $lines += "|------|------|--------|------|--------|------------|----------|"
    foreach ($st in @($p['stages'])) {
        $row = New-PlanStageRow $st $Bridge $FlowTasks
        $ap = $st['acceptance_point']
        $nodeNote = ""
        if (-not [string]::IsNullOrWhiteSpace([string]$ap['node'])) { $nodeNote = " ($([string]$ap['node']))" }
        # auditor-design-stage-review: 设计审查列（无段 = '-'，旧 run 行式一致）
        $drText = "-"
        if ($null -ne $st['design_review']) {
            $drText = [string]$st['design_review']['status']
            if (-not [string]::IsNullOrWhiteSpace([string]$st['design_review']['verdict'])) { $drText = "$drText/$([string]$st['design_review']['verdict'])" }
        }
        $lines += "| $($st['id']) | $($st['goal']) | $($st['milestone']) | $(@($st['task_ids']) -join ', ') | $($row.progress) | $([string]$ap['status'])$nodeNote | $drText |"
    }
    $lines += ""
    $lines += "- 修正记录：$(@($log.entries | Where-Object { ([string]$_['kind']) -eq 'revision' }).Count) 次 replan；偏差事件：$(@($log.entries | Where-Object { ([string]$_['kind']) -eq 'deviation' }).Count) 条（详见 plan-log.jsonl）"
    $lines += ""
    return $lines
}

function Get-PlanConcludeVerdict {
    # STAGE_ACCEPTANCE_PENDING (conclude hard gate, same family as ACCEPTANCE_*):
    # every stage's acceptance point must be passed before the run may anchor
    # on achieved — 未过验收点不得结案.
    param($Bridge)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return @{ ok = $true } }
    $pending = @()
    foreach ($st in @($p['stages'])) {
        $status = [string]$st['acceptance_point']['status']
        if ($status -ne 'passed') { $pending += "$([string]$st['id'])=$status" }
        # auditor-design-stage-review: 审查未过（pass/exempt 之外）不得结案——同
        # STAGE_ACCEPTANCE_PENDING 硬门（无段跳过，旧 run 不变）。
        $dr = $st['design_review']
        if ($null -ne $dr -and @('passed', 'exempt') -notcontains ([string]$dr['status'])) {
            $pending += "$([string]$st['id'])=design_review:$([string]$dr['status'])"
        }
    }
    if ($pending.Count -gt 0) {
        return @{
            ok = $false
            code = "STAGE_ACCEPTANCE_PENDING"
            message = "Stage acceptance point(s) not passed: [$($pending -join ', ')]. Settle the [集成验收·S<k>] node(s) first (真实执行集成验收), or replan to re-scope the stages; conclusion is blocked until every stage's acceptance point is passed."
        }
    }
    return @{ ok = $true }
}

function Get-PlanDepMaps {
    # delivered task ids + their DAG dep edges. The bridge's dep_task_ids IS
    # the promulgated task-DAG view (requirement inference + ReviewFile
    # overrides); goal-tree node edges stay the node-level authority.
    param($Bridge)
    $delivered = @(); $deps = @{}
    foreach ($key in @($Bridge.tasks.Keys)) {
        $tid = [int]$key
        $delivered += $tid
        $deps[$tid] = @(Convert-ToSafeArray $Bridge.tasks[$key]['dep_task_ids'] | ForEach-Object { [int]$_ })
    }
    return @{ delivered = @($delivered | Sort-Object); deps = $deps }
}

function Set-DerivationAbsorptions {
    # replan 吸收标记（planner-midrun-derive）：revised plan stages 覆盖到的
    # registered-unabsorbed 派生条目标 absorbed（有变化才写回 bridge）。
    # 返回 @{ bridge; absorbed = @("DRV<n>=task#<id>") }。
    param([string]$RunDir, $Bridge, [int[]]$StagedIds)
    $derivations = @(Get-DerivationSection $Bridge)
    $absorbedNow = @()
    foreach ($x in $derivations) {
        if (([string]$x['status']) -ne 'registered') { continue }
        if ((Test-PropPresent $x 'absorbed') -and $x['absorbed'] -eq $true) { continue }
        if ($null -eq $x['task_id']) { continue }
        if ($StagedIds -contains [int]$x['task_id']) {
            $x['absorbed'] = $true
            $x['absorbed_at'] = Get-UtcNowIso
            $absorbedNow += "$([string]$x['id'])=task#$([string]$x['task_id'])"
        }
    }
    if ($absorbedNow.Count -gt 0) {
        $Bridge['derivations'] = $derivations
        Write-BridgeFile $RunDir $Bridge
    }
    return @{ bridge = $Bridge; absorbed = @($absorbedNow) }
}

function Invoke-BridgeReplan {
    # long-task-planning rolling correction — the ONLY correction entry point:
    # revised PlanFile + mandatory -Reason -> DAG-fit validation -> structured
    # changes[] -> plan-log `revision` (append-only, never a file snapshot) ->
    # plan section replaced (revision+1) -> unlock set recomputed on the
    # auto-push tail. The DAG itself is never edited here; a re-cut that needs
    # different dependencies stitches them via goal-tree deps add/remove first.
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($PlanFile)) { Write-ErrorResult "PLAN_MISSING" "replan requires -PlanFile <revised staged plan>" 1 }
    if ([string]::IsNullOrWhiteSpace($Reason)) { Write-ErrorResult "MISSING_REASON" "replan requires -Reason <deviation being answered>" 1 }
    $oldSec = Get-PlanSection $bridge
    $tree = Get-TreeStatusView $RunId
    if ($null -eq $oldSec -or ([string]$tree.state) -eq 'concluded') {
        Write-ErrorResult "REPLAN_NOT_ACTIVE" "run $RunId has no active plan to revise (legacy run or already concluded) — replan only rolls a promulgated staged plan forward" 1
    }
    $null = Enter-PlannerLease $runDir
    $newPlan = Read-PlanFile $PlanFile
    $flow = Read-ArchiveTasks $bridge.archive
    $maps = Get-PlanDepMaps $bridge
    # planner-midrun-derive replan whitelist: registered-unabsorbed derived ids
    # may sit outside the stages during the absorption window; covering one
    # marks it absorbed (a later replan dropping it re-fails coverage).
    $exempt = @(Get-UnabsorbedDerivedTaskIds $bridge)
    Test-PlanDeliveryFit $newPlan @($flow.tasks | ForEach-Object { [int]$_.id }) $maps.delivered $maps.deps -ExemptIds $exempt
    Test-PlanCriteriaRef $newPlan (Read-AcceptanceCriteria ([string]$bridge.archive))
    $changes = Compare-PlanRevisions $oldSec $newPlan
    $bridge = Merge-PlanRevision $runDir $bridge $oldSec $newPlan $PlanFile
    $stagedIds = @()
    foreach ($st in @($newPlan.stages)) { $stagedIds += @($st.task_ids | ForEach-Object { [int]$_ }) }
    $absorb = Set-DerivationAbsorptions $runDir $bridge $stagedIds
    $bridge = $absorb.bridge
    $absorbedNow = @($absorb.absorbed)
    $rev = [int]((Get-PlanSection $bridge)['revision'])
    $null = Add-PlanEvent $runDir 'revision' 'replan' $null $null $null @{ reason = $Reason; revision = $rev; changes = $changes }
    $push = Invoke-AutoDispatch $runDir $bridge "replan"
    $bridge = $push.bridge
    # 编排裁定自动入账（统一决策账本，advisory）
    $ruling = Add-OrchestrationRuling -ArchivePath ([string]$bridge.archive) -RunIdText $RunId -CommandName 'replan' -DecisionText "replan revision $rev applied（absorbed: [$($absorbedNow -join ', ')]）" -ReasonText $Reason -OptionsArr @('维持原 plan', 'replan 滚动修正')
    $result = [ordered]@{
        run_id     = $RunId
        revision   = $rev
        reason     = $Reason
        changes    = @($changes)
        derivations_absorbed = @($absorbedNow)
        plan       = Get-PlanView $runDir $bridge
        auto_push  = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed); skipped = @($push.skipped | ForEach-Object { "$($_.node):$($_.reason)" }) }
        decision_ledger = $(if ($ruling.entry) { @{ entry_id = [string]$ruling.entry['entry_id'] } } else { $null })
        next_step  = "plan revision $rev applied — unlock set recomputed and stage gates re-evaluate against the revised stages"
    }
    if ($ruling.warning) { $result['warnings'] = @($ruling.warning) }
    return @{ success = $true; data = $result }
}

# === Command: promulgate ===

function Resolve-ReviewPlan {
    # Requirement review gate consumption (hard constraint 6, -ReviewFile):
    # classify verdicts into exclusion maps and validate merge-target survival.
    # No -ReviewFile -> every map stays empty and promulgate is byte-identical
    # to the pre-review behavior (regression guarantee).
    param($Tasks, $AllIds, [string]$ReviewFilePath)
    $info = @{
        review = $null; deprecated_ids = @(); excluded_merge = @{}
        excluded_reject = @{}; verdict_of = @{}; verdict_by_id = @{}
    }
    if ([string]::IsNullOrWhiteSpace($ReviewFilePath)) { return $info }
    $info.review = Read-ReviewFile $ReviewFilePath $AllIds
    $info.deprecated_ids = @($Tasks | Where-Object { ([string]$_.lifecycle) -eq 'deprecated' } | ForEach-Object { [int]$_.id })
    foreach ($v in @($info.review.verdicts)) {
        $tid = [int]$v['task_id']
        $verdict = [string]$v['verdict']
        $info.verdict_by_id[$tid] = $v
        # deprecated tasks are excluded before the review ever runs: only a
        # merged_into verdict documents their (already executed) pre-promulgate
        # deprecate; any other verdict on one is meaningless bookkeeping.
        if (($info.deprecated_ids -contains $tid) -and ($verdict -ne 'tree_adjudicated' -or -not $v.Contains('merged_into_task_id'))) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid is deprecated (excluded from delivery before the review) — only a merged_into verdict documents its pre-promulgate deprecate; remove task #$tid from the ReviewFile" 2
        }
        switch ($verdict) {
            'reject_return'    { $info.excluded_reject[$tid] = $true }
            'tree_adjudicated' {
                if ($v.Contains('merged_into_task_id')) { $info.excluded_merge[$tid] = [int]$v['merged_into_task_id'] }
                else { $info.verdict_of[$tid] = $v }
            }
            default            { $info.verdict_of[$tid] = $v }
        }
    }
    Test-ReviewMergeTargets $info
    return $info
}

function Test-ReviewMergeTargets {
    # merge-target survival: the absorber must itself produce an initial node —
    # not deprecated, not rejected, not absorbed away (no merge chains).
    param($ReviewInfo)
    foreach ($tid in @($ReviewInfo.excluded_merge.Keys)) {
        $target = [int]$ReviewInfo.excluded_merge[$tid]
        if (($ReviewInfo.deprecated_ids -contains $target) -or $ReviewInfo.excluded_merge.Contains($target) -or $ReviewInfo.excluded_reject.Contains($target)) {
            Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid merged_into_task_id=$target does not survive the review (deprecated / rejected / itself merged) — merge into a task this run actually delivers" 2
        }
    }
}

function Resolve-PlanTaskDeps {
    # Dependency resolution for ONE planned task under the review gate:
    # depends_on_override wholesale-replaces regex inference ([] clears all),
    # merged-away deps redirect to the absorber, deps dangling on a rejected
    # task hard-fail REVIEW_EXCLUDED_DEP (never a silent drop).
    param([int]$TaskId, $DepIds, [bool]$IsOverride, $ReviewInfo)
    $resolved = @()
    $explicit = @()
    foreach ($d in @($DepIds)) {
        $di = [int]$d
        if ($ReviewInfo.excluded_merge.Contains($di)) {
            $absorber = [int]$ReviewInfo.excluded_merge[$di]
            if ($resolved -notcontains $absorber) { $resolved += $absorber }
            if ($explicit -notcontains $absorber) { $explicit += $absorber }
        }
        elseif ($ReviewInfo.excluded_reject.Contains($di)) {
            Write-ErrorResult "REVIEW_EXCLUDED_DEP" "task #$TaskId depends on task #$di, which the review rejected back to PM — adjudicate task #$TaskId as well (depends_on_override, or reject it too); the dependency will not be silently dropped" 1
        }
        else {
            if ($IsOverride -and ($ReviewInfo.deprecated_ids -contains $di)) {
                Write-ErrorResult "REVIEW_FILE_INVALID" "task #$TaskId depends_on_override entry #$di is deprecated (delivers nothing, anchors no node) — override to tasks this run delivers, or drop the entry" 2
            }
            if ($resolved -notcontains $di) { $resolved += $di }
            if ($IsOverride -and $explicit -notcontains $di) { $explicit += $di }
        }
    }
    return @{ resolved = $resolved; explicit = $explicit }
}

function New-DeliveryPlan {
    # stage resolution + dependency inference per deliverable task (deprecated
    # and review-excluded tasks graft no node, enter no bridge.tasks, never push).
    param($Tasks, [string]$ArchivePath, $AllIds, $ReviewInfo)
    $plan = @()
    $skippedReview = @()
    foreach ($t in $Tasks) {
        if (([string]$t.lifecycle) -eq 'deprecated') { continue }   # deprecated tasks are not promulgated
        $taskId = [int]$t.id
        if ($ReviewInfo.excluded_reject.Contains($taskId) -or $ReviewInfo.excluded_merge.Contains($taskId)) {
            $skippedReview += $taskId
            continue
        }
        $group = @(Resolve-InitialGroup $t)
        $null = Resolve-TaskPhase $t $group   # phase gate: PHASE_INVALID / PHASE_OWNER_MISMATCH / GROUP_DIVERGENT_NEXT
        $depIds = @(Get-RequirementDepTaskIds $ArchivePath $t $AllIds)
        $isOverride = $false
        if ($ReviewInfo.verdict_of.Contains($taskId) -and $ReviewInfo.verdict_of[$taskId].Contains('depends_on_override')) {
            $depIds = @($ReviewInfo.verdict_of[$taskId]['depends_on_override'] | ForEach-Object { [int]$_ })
            $isOverride = $true
        }
        $explicitDeps = @()
        if ($null -ne $ReviewInfo.review) {
            $rd = Resolve-PlanTaskDeps -TaskId $taskId -DepIds $depIds -IsOverride $isOverride -ReviewInfo $ReviewInfo
            $depIds = @($rd.resolved)
            $explicitDeps = @($rd.explicit)
        }
        $plan += @{ task = $t; group = $group; dep_ids = $depIds; explicit_deps = $explicitDeps }
    }
    if ($null -ne $ReviewInfo.review -and $plan.Count -eq 0) {
        Write-ErrorResult "REVIEW_FILE_INVALID" "the review excluded every deliverable task — nothing to promulgate" 2
    }
    return @{ plan = $plan; skipped_review = $skippedReview }
}

function Invoke-GoalRootStart {
    # 1) goal-tree start in goal-root mode (RefRoots = whole repo: delivery
    #    citations are change lists anywhere). start itself is atomic (manifest
    #    CreateNew), so a concurrent double-promulgate loses here before any
    #    bridge state exists. Then: planner lease + roster row + open round 1
    #    (kept open for the whole delivery; conclude auto-closes it).
    param([string]$RunId, $Goal, [string]$ArchiveRel, [int]$EffWidth, [int]$EffMaxNodes)
    $goalFile = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-goal-{0}.md" -f ([guid]::NewGuid().ToString("N").Substring(0, 10)))
    [System.IO.File]::WriteAllText($goalFile, $Goal.description, $script:Utf8NoBom)
    try {
        $r = Invoke-GoalTree @("-Command", "start", "-RunId", $RunId,
            "-Goal", "$($Goal.title) — deliver $ArchiveRel",
            "-Title", $Goal.title,
            "-GoalRoot", "-GoalFile", $goalFile,
            "-RefRoots", ".", "-CreatedBy", $CreatedBy,
            "-MaxRounds", "$MaxRounds", "-NodeWidth", "$EffWidth", "-MaxNodes", "$EffMaxNodes",
            "-Notes", "delivery-bridge run for $ArchiveRel")
    }
    finally {
        Remove-Item -LiteralPath $goalFile -Force -ErrorAction SilentlyContinue
    }
    if ($r.exit -ne 0 -or -not $r.json.success) { Write-ErrorResult "PROMULGATE_START_FAILED" "goal-tree start failed: $($r.text)" 3 }
    $runDir = Join-Path $script:GoalTreesRoot $RunId
    $null = Enter-PlannerLease $runDir
    # planner body roster row (planner-session-roster): the promulgating dsh
    # session IS this run's planner — register it right after the run dir exists
    # (advisory; CLI planners carry no DSH_SESSION_ID and skip silently).
    $null = Register-PlannerBody -RunDir $runDir -RunIdText $RunId
    $r2 = Invoke-GoalTree @("-Command", "round-start", "-RunId", $RunId)
    if ($r2.exit -ne 0 -or -not $r2.json.success) { Write-ErrorResult "PROMULGATE_ROUND_FAILED" "round-start failed: $($r2.text)" 3 }
    return $runDir
}

function Get-PlanDepMapsFromDeliveryPlan {
    # delivered ids + task-DAG edges from the in-flight delivery plan — the
    # staged plan is validated against the very DAG promulgate is grafting.
    param($DeliveryPlan)
    $delivered = @(); $deps = @{}
    foreach ($p in @($DeliveryPlan)) {
        $tid = [int]$p.task.id
        $delivered += $tid
        $deps[$tid] = @(Convert-ToSafeArray $p['dep_ids'] | ForEach-Object { [int]$_ })
    }
    return @{ delivered = @($delivered | Sort-Object); deps = $deps }
}

function New-PromulgateGoal {
    # goal root payload (goal-tree-goal-root): the original requirement as the
    # final objective — title + description travel via the file channel (same
    # encoding-safety convention as graft's -TasksFile). criteria mode injects
    # the acceptance anchor (dispatch-record check point, overall-delivery).
    param([string]$ArchivePath, $Plan, $Acceptance)
    $goal = Read-ArchiveGoal $ArchivePath $Plan
    if (([string]$Acceptance.status) -eq 'planned') {
        $goal.description = $goal.description + "`n`n> 整体验收判据：$([string]$Acceptance.criteria_ref)"
    }
    return $goal
}

function New-PromulgateInitialPush {
    # 4) initial dependency-driven push (goal-tree-goal-root): every node with
    #    no unsatisfied dependency (and an open stage gate) gets its role
    #    session started right here — no manual dispatch, no confirmation gate.
    #    -NoPush (test/incident isolation): build the run but start NOTHING —
    #    the persisted run-level flag is re-asserted by every later trigger.
    param([string]$RunDir, $Bridge)
    if ($NoPush) {
        # auditor-design-stage-review: even an isolated run evaluates the
        # design-review state machine ONCE here (same placement as the push
        # path's auto-dispatch head) — at promulgate time a fresh run can only
        # transition exempt/wait (no task is past DESIGN yet), so the fast-lane
        # stages read exempt right away instead of lingering 'planned'.
        $drMoves = Update-StageDesignReviews $RunDir $Bridge
        $Bridge = $drMoves.bridge
        return @{ push = @{ trigger = "promulgate (-NoPush)"; considered = 0; pushed = @(); skipped = @(); failed = @() }; bridge = $Bridge }
    }
    $push = Invoke-AutoDispatch $RunDir $Bridge "promulgate"
    return @{ push = $push; bridge = $push.bridge }
}

function New-BridgeSkeleton {
    # bridge.json v2 skeleton: node<->TaskId authoritative mapping + goal_root
    # anchor + the acceptance placeholder (overall-delivery, planned -> grafted)
    # + the plan section (long-task-planning current state; mandatory at
    # promulgate since -PlanFile is a hard gate). max_derivation
    # (planner-midrun-derive) lands ONLY when promulgate passes
    # -MaxDerivations > 0 — absent key = default 3 (Get-MaxDerivations), and
    # legacy bridge.json files stay byte-compatible (optional section).
    param([string]$RunId, [string]$ArchivePath, [string]$ArchiveRel, $Goal, [string]$CreatedByText, $Acceptance, $PlanSec)
    $skel = @{
        format_version  = 2
        run_id          = $RunId
        archive         = $ArchivePath
        archive_rel     = $ArchiveRel
        promulgated_at  = Get-UtcNowIso
        created_by      = $CreatedByText
        goal_root       = "n1"
        goal            = @{ title = $Goal.title; source = $Goal.source }
        acceptance      = $Acceptance
        plan            = $PlanSec
        tasks           = @{}
        nodes           = @{}
        pending_sync    = @()
        pushes          = @{}
    }
    if ([int]$MaxDerivations -gt 0) { $skel['max_derivation'] = [int]$MaxDerivations }
    # auditor-subagent-review: review_mode 落桥（决策 #4 配置项载体）——有键 = 新链
    # （纯契约）；缺键 = 存量 run 旧链逐字节（决策 #7 缺键兼容判据）。
    if (-not [string]::IsNullOrWhiteSpace($ReviewMode)) { $skel['review_mode'] = [string]$ReviewMode }
    return $skel
}

function Invoke-InitialChainGrafts {
    # 3) graft one chain-head node per (task, initial group role) under the goal
    #    root; deps point at EVERY chain head of each dep task (phase-model
    #    multi-anchor: the dependent unlocks only when the whole upstream phase
    #    settles). Returns @{ bridge; initial_nodes_of_task }.
    param([string]$RunId, $Plan, $Bridge, [string]$ArchiveName, [string]$AcceptanceRef)
    $initialNodesOfTask = @{}
    foreach ($p in $Plan) {
        $t = $p.task
        $taskId = [int]$t.id
        $group = @($p.group)
        $depNodes = @()
        foreach ($d in $p.dep_ids) { if ($initialNodesOfTask.ContainsKey($d)) { $depNodes += @($initialNodesOfTask[$d]) } }
        # bookkeeping for the deferred review-edge stitching (single-pass graft
        # can only express deps on already-grafted nodes)
        $p['grafted_dep_nodes'] = @($depNodes)
        $reqRel = ([string]$t.requirement -replace '\\', '/')
        $designRels = @()
        foreach ($d in @(Convert-ToSafeArray $t.designDocs)) { $designRels += ([string]$d.path -replace '\\', '/') }
        $Bridge.tasks["$taskId"] = @{
            title          = [string]$t.title
            requirement    = $reqRel
            initial_group  = @($group)
            dep_task_ids   = @($p.dep_ids)
            stages         = @{}
        }
        $initialNodesOfTask[$taskId] = @()
        foreach ($role in $group) {
            # goal-first node task text (dispatch-task-goal-anchoring): single
            # authoritative producer — New-NodeTaskText; AcceptanceRef injects
            # the whole-requirement criteria anchor (overall-delivery).
            # ConventionsRef (parallel-coordination): DESIGN 链头注入「架构约定:<path>」。
            $conventionsRef = $null
            if (Test-DesignStageNode ([string]$role) $t) { $conventionsRef = Get-ConventionsRef $Bridge }
            $taskText = New-NodeTaskText -Title ([string]$t.title) -Stage $role -ReqRel $reqRel -DesignRels $designRels -RunId $RunId -AcceptanceRef $AcceptanceRef -ConventionsRef $conventionsRef
            $graftItem = @{
                title      = [string]$t.title
                task       = $taskText
                role       = $role.ToLower()
                ref        = "$ArchiveName/$reqRel"   # requirement-node ref <-> the requirement doc
            }
            if ($depNodes.Count -gt 0) { $graftItem['depends_on'] = @($depNodes) }
            $g = Invoke-GraftOne $RunId ([string]$Bridge.goal_root) $graftItem
            if (-not $g.ok) { Write-ErrorResult "PROMULGATE_GRAFT_FAILED" "graft failed for task $taskId ($role): $($g.text)" 3 }
            Set-NodeTaskStage $Bridge $g.node_id $taskId $role
            $initialNodesOfTask[$taskId] += $g.node_id
        }
    }
    return @{ bridge = $Bridge; initial_nodes_of_task = $initialNodesOfTask }
}

function Get-DeferredReviewEdges {
    # 3b) deferred review-edge stitching: single-pass graft can only express deps
    #     on already-grafted nodes (task order); when the planner's override or a
    #     merge-redirect points at a task grafted LATER, the edge is added via
    #     the public deps CLI (DAG-validated, deps-log audited) instead of
    #     silently vanishing. Per-node edge nesting cap: Get-DeferredEdgesForNode.
    param([string]$RunId, $Plan, $InitialNodesOfTask)
    $edges = @()
    foreach ($p in $Plan) {
        if (@($p['explicit_deps']).Count -eq 0) { continue }
        $have = @($p['grafted_dep_nodes'])
        foreach ($nodeId in @($InitialNodesOfTask[[int]$p.task.id])) {
            $edges += @(Get-DeferredEdgesForNode -RunId $RunId -TaskId ([int]$p.task.id) -NodeId $nodeId -ExplicitDeps @($p['explicit_deps']) -GraftedDepNodes $have -InitialNodesOfTask $InitialNodesOfTask)
        }
    }
    return $edges
}

function Set-BridgeOptionalSections {
    # 3c/3c-2/3c-3: review audit + auto_mode snapshot + no_push isolation as
    # PERSISTED run-level attributes. Absent when off: byte-identical legacy
    # promulgation (the -ReviewFile / -AutoMode / -NoPush gating discipline).
    param($Bridge, $ReviewInfo, [string]$ReviewAppliedAt, $AmSnapshot)
    if ($null -ne $ReviewInfo.review) {
        $Bridge['review'] = @{
            reviewed_at = $ReviewInfo.review.reviewed_at
            reviewer    = $ReviewInfo.review.reviewer
            verdicts    = @($ReviewInfo.review.verdicts)
            applied_at  = $ReviewAppliedAt
        }
    }
    if ($null -ne $AmSnapshot) { $Bridge['auto_mode'] = $AmSnapshot }
    if ($NoPush) { $Bridge['no_push'] = $true }
    return $Bridge
}

function Write-ReviewReportFile {
    # 3d) report/review.md — the human-readable per-task conclusions table
    #     (acceptance 1: the persistent carrier presented to the user; the
    #     planner session renders the same verdicts live from the JSON return).
    param([string]$RunId, [string]$RunDir, [string]$ArchiveRel, $Tasks, $ReviewInfo, [string]$ReviewAppliedAt, $DeferredEdges)
    $revDir = Join-Path $RunDir "report"
    if (-not (Test-Path -LiteralPath $revDir)) { New-Item -ItemType Directory -Path $revDir -Force | Out-Null }
    $verdictLabel = @{ pass = "通过"; tree_adjudicated = "树内裁定"; reject_return = "驳回回流" }
    $rl = @()
    $rl += "# 需求审查结论 — $RunId"
    $rl += ""
    $rl += "- 归档: $ArchiveRel"
    $rl += "- 审查时间: $($ReviewInfo.review.reviewed_at) · 审查者: $($ReviewInfo.review.reviewer) · 应用时间: $ReviewAppliedAt"
    $rl += ""
    $rl += "| Task | 标题 | 结论 | 理由 | 处置 |"
    $rl += "|------|------|------|------|------|"
    foreach ($t in $Tasks) {
        $taskId = [int]$t.id
        $isDep = (([string]$t.lifecycle) -eq 'deprecated')
        if ($isDep -and -not $ReviewInfo.verdict_by_id.Contains($taskId)) { continue }
        $label = "通过"; $reason = "（未单列 = 审查通过）"; $disp = "正常建树"
        if ($ReviewInfo.verdict_by_id.Contains($taskId)) {
            $v = $ReviewInfo.verdict_by_id[$taskId]
            $label = $verdictLabel[[string]$v['verdict']]
            $reason = ([string]$v['reason'] -replace '\|', '/')
            switch ([string]$v['verdict']) {
                'pass' { $disp = "正常建树" }
                'tree_adjudicated' {
                    if ($v.Contains('merged_into_task_id')) {
                        $disp = "合并至 #$([int]$v['merged_into_task_id'])（不建节点$(if ($isDep) { '，已 deprecate' } else { '，本 run 排除' })）"
                    } else {
                        $disp = "依赖覆盖: [$(@($v['depends_on_override']) -join ',')]（整体替代正则推导）"
                    }
                }
                'reject_return' { $disp = "驳回协议回流 PM（不建节点，不进本轮交付）" }
            }
        }
        $rl += "| $taskId | $(([string]$t.title) -replace '\|', '/') | $label | $reason | $disp |"
    }
    $rl += ""
    $rl += "> 未列出的 active 任务 = 审查通过（正常建树）；deprecated 且未列出的任务 = 审查前已排除，不属本 run 交付。用户可随时干预或推翻裁定（最终裁决权在用户）。"
    if (@($DeferredEdges).Count -gt 0) {
        $rl += ""
        $rl += "> 延后缝合的审查依赖边（graft 单趟无法表达的前向引用，经 deps add 补齐并留 deps-log 审计）: $(@($DeferredEdges | ForEach-Object { "#$($_.task_id)→#$($_.on_task_id)" }) -join '、')"
    }
    [System.IO.File]::WriteAllText((Join-Path $revDir "review.md"), ($rl -join "`n"), $script:Utf8NoBom)
}

function New-PlanResultSummary {
    # promulgate response plan echo: revision + stage/batch essentials + risks.
    param($PlanSec)
    return @{
        revision = [int]$PlanSec['revision']
        source   = [string]$PlanSec['source']
        stages   = @($PlanSec['stages'] | ForEach-Object {
            $pst = $_
            $stageRow = @{ id = [string]$pst['id']; goal = [string]$pst['goal']; milestone = [string]$pst['milestone']; task_ids = @($pst['task_ids']); batches = @($pst['batches']) }
            if ($null -ne $pst['design_review']) { $stageRow['design_review'] = @{ status = [string]$pst['design_review']['status'] } }
            $stageRow
        })
        risks    = @($PlanSec['risks'])
    }
}

function New-PromulgateResult {
    # the promulgate JSON payload (acceptance 1/2 response surface): plan echo +
    # review/auto_mode/acceptance optional sections + budget + auto-push ledger.
    param([string]$RunId, [string]$RunDir, [string]$ArchiveRel, $Goal, $Plan, $InitialNodesOfTask, $Tasks,
          $ReviewInfo, [string]$ReviewAppliedAt, $AmSnapshot, $DeferredEdges, $Acceptance,
          [int]$EffWidth, [int]$EffMaxNodes, $Push, $SkippedReview, $PlanSec)
    return @{
        success = $true
        data    = @{
            promulgated  = $true
            run_id       = $RunId
            archive      = $ArchiveRel
            directory    = ".rdd/goal-trees/$RunId"
            goal_root    = @{ node = "n1"; title = $Goal.title; source = $Goal.source }
            plan         = New-PlanResultSummary $PlanSec
            tasks        = @($Plan | ForEach-Object { @{ task_id = [int]$_.task.id; stage = @($_.group)[0]; group = @($_.group); node = @($InitialNodesOfTask[[int]$_.task.id])[0]; nodes = @($InitialNodesOfTask[[int]$_.task.id]); dep_task_ids = @($_.dep_ids) } })
            skipped_deprecated = @($Tasks | Where-Object { ([string]$_.lifecycle) -eq 'deprecated' } | ForEach-Object { [int]$_.id })
            skipped_review    = @($SkippedReview)
            acceptance   = $Acceptance
            review       = $(if ($null -ne $ReviewInfo.review) {
                @{
                    reviewed_at = $ReviewInfo.review.reviewed_at
                    reviewer    = $ReviewInfo.review.reviewer
                    applied_at  = $ReviewAppliedAt
                    report      = ".rdd/goal-trees/$RunId/report/review.md"
                    verdicts    = @($ReviewInfo.review.verdicts)
                    deferred_dep_edges = @($DeferredEdges | ForEach-Object { "task#$($_.task_id)->task#$($_.on_task_id) ($($_.node)->$($_.on))" })
                }
            } else { $null })
            auto_mode     = $(if ($null -ne $AmSnapshot) {
                @{
                    enabled       = $true
                    policy_source = $AmSnapshot.policy_source
                    rule_count    = @($AmSnapshot.policy.rules).Count
                    r1_floor      = "manual (hard floor, force-merged)"
                    protocol      = Get-AutoModeProtocolHint $RunId
                }
            } else { $null })
            budget       = @{ max_rounds = $MaxRounds; node_width = $EffWidth; max_nodes = $EffMaxNodes }
            # auditor-subagent-review: 新链回显 review_mode（部署判据 = 配置项）；
            # 缺键旧链回显部署状态原文（未部署 = 降级警示，逐字节不变）。
            design_review = $(if (-not [string]::IsNullOrWhiteSpace($ReviewMode)) {
                @{ mode = [string]$ReviewMode; deployed = $true; note = "评审内生于规划者：阶段边界派五查评审子代理（机械模板 $script:ReviewInputTemplateRel，独立上下文）产出 DesignReviewFile，'delivery-bridge.cmd -Command design-review -Action submit' 入库；pass 才放行 IMPL（闸门三触点：push skip / claim / dispatch 硬拒）" }
            } elseif (@(@($PlanSec['stages']) | Where-Object { $null -ne $_['design_review'] }).Count -gt 0) {
                @{ deployed = $true; note = "DESIGN 全 settle 后自动 graft [设计审查·S<k>]（AUDITOR 汇聚五查，一批一会话）；pass 才放行 IMPL（闸门三触点：push skip / claim / dispatch 硬拒）" }
            } else {
                @{ deployed = $false; note = "AUDITOR 未部署——降级为现行行为（设计不审直接 IMPL），不落 design_review 段；安装 rdd-auditor 后新 run 生效" }
            })
            lease        = @{ holder = (Get-LeaseState $RunDir).holder }
            auto_push    = @{ trigger = $Push.trigger; pushed = @($Push.pushed); blocked = @($Push.skipped | Where-Object { $_.reason -eq 'blocked_by_deps' } | ForEach-Object { $_.node }); failed = @($Push.failed) }
            next_step    = "initial pushes are automatic (pushed: [$(@($Push.pushed) -join ', ')]; dep-blocked nodes push when their dependencies settle). Workers start with: delivery-bridge.cmd -Command claim -RunId $RunId -NodeId <id> -Role <stage>."
        }
    }
}

function Resolve-PromulgatePaths {
    # path resolution + the RUN_EXISTS double-promulgate guard (the run id is the
    # frozen deliver-<archive> convention). Returns the resolved coordinates.
    param([string]$TaskJsonPath)
    if ([string]::IsNullOrWhiteSpace($TaskJsonPath)) { Write-ErrorResult "MISSING_TASK_JSON" "-TaskJson (archive task.json path) is required" 1 }
    $tj = $TaskJsonPath
    if (-not [System.IO.Path]::IsPathRooted($tj)) { $tj = Join-Path $repoRoot $tj }
    if (-not (Test-Path -LiteralPath $tj -PathType Leaf)) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found: $tj" 2 }
    $archivePath = Split-Path -Parent $tj
    $archiveName = Split-Path $archivePath -Leaf
    $runId = "deliver-$archiveName"
    $runDir = Join-Path $script:GoalTreesRoot $runId
    if (Test-Path -LiteralPath $runDir -PathType Container) {
        $existing = Read-Bridge $runDir
        if ($null -ne $existing) {
            Write-ErrorResult "RUN_EXISTS" "Bridge run already promulgated: .rdd/goal-trees/$runId (at $($existing.promulgated_at)). Use -RunId $runId with status/resume to continue." 1
        }
        Write-ErrorResult "RUN_EXISTS" "Run directory exists but is not a bridge run: .rdd/goal-trees/$runId" 1
    }
    return @{ task_json = $tj; archive = $archivePath; archive_name = $archiveName; run_id = $runId; run_dir = $runDir }
}

function Get-PromulgateBudget {
    # node_width budget = goal-root children: the chain heads + the two
    # tree-level acceptance nodes (overall-delivery width formula +2 — the 2/3
    # task-count WIDTH_EXCEEDED regression) + (K-1) stage acceptance nodes
    # (long-task-planning: they hang on the goal root too; K=1 adds zero);
    # node budget keeps per-task ×5 + 6 slack + (K-1). Explicit -NodeWidth /
    # -MaxNodes always win.
    param($Plan, [int]$StageCount = 1)
    $headCount = 0
    foreach ($p in $Plan) { $headCount += @($p.group).Count }
    $extra = [Math]::Max(0, $StageCount - 1)
    # auditor-design-stage-review: +K（K=阶段数，单阶段 run 即「+1」）——每阶段最多
    # 1 个 [设计审查·S<k>] goal-root 子位；+K 分支化（auditor-subagent-review）：
    # 缺键旧链仅 AUDITOR 已部署时计入（未部署零节点）；新链（review_mode）审查无
    # 节点（纯契约），goal-root 子位零占用，不再预留。
    $extraReview = 0
    if ([string]::IsNullOrWhiteSpace($ReviewMode) -and (Test-AuditorDeployed)) { $extraReview = $StageCount }
    return @{
        width     = $(if ($NodeWidth -gt 0) { $NodeWidth } else { [Math]::Max(4, $headCount + 2 + $extra + $extraReview) })
        max_nodes = $(if ($MaxNodes -gt 0) { $MaxNodes } else { (@($Plan).Count * 5 + 6 + $extra + $extraReview) })
    }
}

function New-PromulgateIntake {
    # intake guards before any run state exists (invalid input = deterministic
    # error, zero residue): review gate + auto-mode snapshot + acceptance basis.
    # NOTE: $amSnapshot is deliberately named that way here (the caller's
    # $autoModeName would shadow a common $autoMode variable per the review).
    param([string]$ArchivePath, $Tasks, $AllIds)
    $reviewInfo = Resolve-ReviewPlan $Tasks $AllIds $ReviewFile
    $amSnapshot = $null
    if ($AutoMode) { $amSnapshot = New-AutoModeSnapshot $RiskPolicy }
    $criteria = Read-AcceptanceCriteria $ArchivePath
    $reqCount = @($Tasks | Where-Object { ([string]$_.lifecycle) -ne 'deprecated' }).Count
    return @{
        review_info = $reviewInfo
        am_snapshot = $amSnapshot
        criteria    = $criteria
        acceptance  = (New-AcceptanceSection $criteria $reqCount)
    }
}

function Test-PlanPromulgateFit {
    # the plan's two promulgate-time fits (long-task-planning): every delivered
    # id lives in exactly one stage + dep edges run forward across stage order;
    # batches must form a dep-forward topological order inside each stage.
    param($PlanFileObj, $Plan, $AllIds, $Criteria)
    $maps = Get-PlanDepMapsFromDeliveryPlan $Plan
    Test-PlanDeliveryFit $PlanFileObj $AllIds $maps.delivered $maps.deps
    Test-PlanCriteriaRef $PlanFileObj $Criteria
}

function Set-PromulgateRunState {
    # bridge state persistence + plan ledger tail + optional review report —
    # everything between the initial grafts and the initial push tail.
    param([string]$RunIdText, [string]$RunDir, [string]$ArchiveRel, [string]$ArchiveName, $Bridge, $PlanSec, $ReviewInfo, $AmSnapshot, $Plan, $InitialNodesOfTask, $Tasks)
    $deferredEdges = @()
    $reviewAppliedAt = $null
    if ($null -ne $ReviewInfo.review) {
        $deferredEdges = @(Get-DeferredReviewEdges $RunIdText $Plan $InitialNodesOfTask)
        $reviewAppliedAt = Get-UtcNowIso
    }
    $Bridge = Set-BridgeOptionalSections $Bridge $ReviewInfo $reviewAppliedAt $AmSnapshot
    Write-BridgeFile $RunDir $Bridge
    # design_maps 只读派生缓存初扫(parallel-coordination):设计产物已在归档内时
    # 即刻机读,DESIGN_MAP_INVALID 警示早期可见(status 继续透出,不阻塞流转)。
    $null = Get-DesignMaps $RunDir $Bridge $Tasks
    $null = Add-PlanEvent $RunDir 'progress' 'plan_promulgated' $null $null $null @{
        revision = 1; stage_ids = @($PlanSec.stages | ForEach-Object { [string]$_.id })
    }
    if ($null -ne $ReviewInfo.review) {
        Write-ReviewReportFile $RunIdText $RunDir $ArchiveRel $Tasks $ReviewInfo $reviewAppliedAt $deferredEdges
    }
    return @{ bridge = $Bridge; deferred_edges = @($deferredEdges); review_applied_at = $reviewAppliedAt }
}

function Invoke-Promulgate {
    # long-task-planning hard gate: a staged plan is MANDATORY (要素齐全 ≠ 篇幅 —
    # one-line goals are fine, but the elements must be there). PLAN_MISSING
    # fires before any run state exists (zero residue, like every intake error).
    if ([string]::IsNullOrWhiteSpace($PlanFile)) {
        Write-ErrorResult "PLAN_MISSING" "promulgate requires -PlanFile <staged plan> (long-task-planning: 阶段目标/里程碑/集成验收点/任务依赖排序/可并行批次). Produce the PlanFile first — see planner-guide「长程规划与滚动追踪」." 1
    }
    # NOTE: the parsed plan is named $planParsed — PS names are case-INsensitive,
    # a $planFile local would silently clobber the bound $PlanFile path param.
    $planParsed = Read-PlanFile $PlanFile
    $paths = Resolve-PromulgatePaths $TaskJson
    $archivePath = $paths.archive
    $archiveName = $paths.archive_name
    $runId = $paths.run_id
    $runDir = $paths.run_dir

    $flow = Read-ArchiveTasks $archivePath
    $tasks = $flow.tasks
    if ($tasks.Count -eq 0) { Write-ErrorResult "EMPTY_ARCHIVE" "No tasks in task.json: $($paths.task_json)" 2 }
    $allIds = @($tasks | ForEach-Object { [int]$_.id })
    $archiveRel = ".rdd/changes/archive/$archiveName"

    # requirement review gate (hard constraint 6) + acceptance basis + auto-mode
    # snapshot: intake guard helper (invalid input = deterministic error, zero
    # residue; ordering discipline documented there).
    $intake = New-PromulgateIntake $archivePath $tasks $allIds
    $reviewInfo = $intake.review_info
    $amSnapshot = $intake.am_snapshot
    $criteria = $intake.criteria
    $acceptance = $intake.acceptance

    $pd = New-DeliveryPlan $tasks $archivePath $allIds $reviewInfo
    $plan = @($pd.plan)
    # staged-plan fit vs the delivery plan's DAG (authority: the DAG) + the
    # criteria anchor rules; only then is the plan injected as bridge state.
    Test-PlanPromulgateFit $planParsed $plan $allIds $criteria
    $planSec = New-PlanSection $planParsed $PlanFile
    # auditor-design-stage-review: design_review 槽位落段分支化（auditor-subagent-
    # review）——新链（-ReviewMode）恒落（评审内生于规划者）；缺键旧链 AUDITOR 已
    # 部署才落段（未部署 = 无段无门零成本，现行行为；警示随结果回显）。
    $drSlots = Set-PlanDesignReviewSlots $planSec $ReviewMode
    $planSec = $drSlots.plan
    $budget = Get-PromulgateBudget $plan (@($planParsed.stages).Count)

    # parallel-coordination conventions gate (zero residue — fires before ANY run
    # state exists, same discipline as ACCEPTANCE_CRITERIA_MISSING): DESIGN 并行
    # 链头 ≥2(多任务、互为并行)缺 -ConventionsFile -> CONVENTIONS_MISSING;
    # 单设计/串行设计/非桥接 run 豁免。
    $conventionsInput = Read-ConventionsInput $ConventionsFile
    Test-ConventionsRequired $plan $conventionsInput

    $goal = New-PromulgateGoal $archivePath $plan $acceptance
    $null = Invoke-GoalRootStart $runId $goal $archiveRel $budget.width $budget.max_nodes

    $bridge = New-BridgeSkeleton $runId $archivePath $archiveRel $goal $CreatedBy $acceptance $planSec
    # 架构约定落点(report/architecture-conventions.md + bridge.conventions 段)——
    # 须在链头 graft 前写入,DESIGN 链头 node.task 才能注入「架构约定:<path>」。
    if ($null -ne $conventionsInput) { $bridge = Set-ConventionsSection $runDir $runId $bridge $conventionsInput }
    $acceptanceRef = $null
    if (([string]$acceptance.status) -eq 'planned') { $acceptanceRef = [string]$acceptance.criteria_ref }
    $gg = Invoke-InitialChainGrafts $runId $plan $bridge $archiveName $acceptanceRef
    $bridge = $gg.bridge

    $runState = Set-PromulgateRunState $runId $runDir $archiveRel $archiveName $bridge $planSec $reviewInfo $amSnapshot $plan $gg.initial_nodes_of_task $tasks
    $bridge = $runState.bridge

    $pushRes = New-PromulgateInitialPush $runDir $bridge
    $push = $pushRes.push
    $bridge = $pushRes.bridge

    return New-PromulgateResult -RunId $runId -RunDir $runDir -ArchiveRel $archiveRel -Goal $goal -Plan $plan `
        -InitialNodesOfTask $gg.initial_nodes_of_task -Tasks $tasks -ReviewInfo $reviewInfo -ReviewAppliedAt $runState.review_applied_at `
        -AmSnapshot $amSnapshot -DeferredEdges $runState.deferred_edges -Acceptance $acceptance -EffWidth $budget.width `
        -EffMaxNodes $budget.max_nodes -Push $push -SkippedReview $pd.skipped_review -PlanSec $planSec
}

# === Command: dispatch ===

# dispatch 三道门守卫（Invoke-Dispatch 函数行数整改的纯拆分：零语义变更，门序、
# 错误码、返回结构均不动）。门序保持：(b) 阶段闸门 -> (c) 冲突门 -> (a) 任务目标锚定。
#   (a) 任务目标锚定  Get-DispatchTaskAnchorArgs  (dispatch-task-goal-anchoring)
#   (b) 阶段闸门      Assert-DispatchStageGate    (Assert-PlanGateOpen 的 dispatch 包装)
#   (c) 冲突门        Assert-DispatchConflictGate (Test-ConflictHold 的 dispatch 包装)

function Get-DispatchTaskAnchorArgs {
    # task brief (dispatch-task-goal-anchoring): the tree status view carries
    # ids only for pending nodes, so the brief source is the per-node leaf
    # status probe (full node incl. task). Empty brief (legacy-format nodes,
    # read failures) -> arg omitted -> zero injection. session-list-badges:
    # workspace-row summary rides -TaskSummary (title channel); zero-injection
    # contract identical to the brief above. Returns the full start-role arg
    # array (-TaskBrief/-TaskSummary appended only when non-empty).
    param([string]$RunIdText, [string]$NodeId, $Bridge, $Mapping)
    $nodeTaskText = Get-NodeTaskText -RunId $RunIdText -NodeId $NodeId
    $brief = Get-NodeTaskBrief -NodeTask $nodeTaskText -NodeId $NodeId
    $summary = Get-NodeTaskSummary -NodeTask $nodeTaskText
    $startArgs = @("-Role", $Mapping.stage, "-TaskId", "$($Mapping.task_id)", "-TaskJson", (Join-Path $Bridge.archive "task.json"), "-GoalTreeRun", $RunIdText, "-GoalTreeNode", $NodeId)
    if ($brief) { $startArgs += @("-TaskBrief", $brief) }
    if ($summary) { $startArgs += @("-TaskSummary", $summary) }
    return $startArgs
}

function Assert-DispatchStageGate {
    # stage gate (long-task-planning, 不设 Force 旁路): manual dispatch obeys
    # the same gate as auto-push — deterministic NODE_BLOCKED_BY_GATE feedback.
    # design-review gate (auditor-design-stage-review): AND-stacked on the same
    # dispatch gate path, reason kept apart (NODE_BLOCKED_BY_DESIGN_REVIEW) —
    # manual dispatch must not push an IMPL node through an open design review.
    param($Bridge, $Mapping)
    Assert-PlanGateOpen $Bridge ([int]$Mapping.task_id)
    Assert-DesignReviewGateOpen $Bridge ([int]$Mapping.task_id) ([string]$Mapping.stage)
}

function Assert-DispatchConflictGate {
    # parallel-coordination conflict gate (same discipline as the R3 stage gate
    # above: manual dispatch must not push a node INTO an unresolved conflict —
    # that would be the 「默默二选一」 the registry exists to prevent).
    param([string]$RunIdText, [string]$NodeId, $Bridge, [string]$RunDir, $TreeData)
    $conflictStatusOf = @{}
    foreach ($bucket in @('pending', 'claimed', 'reported', 'done', 'pruned')) {
        foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.$bucket)) {
            $bId = if ($n -is [string]) { $n } else { [string]$n.id }
            if ($bId) { $conflictStatusOf[$bId] = $bucket }
        }
    }
    $hold = Test-ConflictHold -NodeId $NodeId -Bridge $Bridge -RunDir $RunDir -StatusOf $conflictStatusOf
    if ($null -ne $hold) {
        Write-ErrorResult "NODE_HELD_BY_CONFLICT" "node $NodeId is held by conflict $($hold.conflict) ($($hold.reason)) — resolve first: delivery-bridge.cmd -Command conflict -RunId $RunIdText -Action resolve -ConflictId $($hold.conflict) -Ruling '<结论>' [-Serialize <早者节点>]" 1
    }
}

function Resolve-DispatchReuse {
    # dispatch 的两级复用候选（inplace-redo-session-reuse）：
    #   1) sidecar 优先：本节点自己的 claims 边车（Get-ClaimLiveness），命中存活
    #      即回原会话——reported 节点（redo 后重投 / 断链重续）的场景正是它；
    #   2) roster 扫描：同 task×role 的存活历史会话（Find-ReusableSession）。
    # 返回 @{ session_id; source } 或 $null（由调用方持有门禁与 -NoReuse）。
    param([string]$RunId, [string]$NodeId, [string]$RunDir, $Bridge, $Mapping)
    $claimLive = Get-ClaimLiveness $RunId $NodeId
    if ($claimLive.liveness -eq "alive" -and -not [string]::IsNullOrWhiteSpace([string]$claimLive.session_id)) {
        return @{ session_id = [string]$claimLive.session_id; source = "sidecar" }
    }
    return Find-ReusableSession -RunDir $RunDir -Bridge $Bridge -TaskId ([int]$Mapping.task_id) -Stage ([string]$Mapping.stage)
}

function Register-DispatchPush {
    # dispatch 的推送留痕（Invoke-Dispatch 的收尾步骤）：手动重推也是一次
    # push——成功记账、失败分类（复用投递失败归 pointer 类）；成功时回写
    # roster（advisory，静默跳过）。返回更新后的 $bridge。
    param([string]$RunDir, $Bridge, [string]$NodeId, $Mapping, $Result, $ReusedId)
    $okPush = ($Result.exit -eq 0)
    $pushClass = $null
    if (-not $okPush) {
        if ($null -ne $ReusedId) { $pushClass = "pointer" }
        else { $pushClass = Get-PushFailureClass $Result.text }
    }
    $bridge = Set-NodePushRecord $RunDir $Bridge $NodeId $okPush $(if ($okPush) { $null } else { $Result.text }) $pushClass $ReusedId
    if ($okPush) {
        # roster write-back (planner-session-roster): advisory, silent skip
        $null = Register-PushedSession -RunDir $RunDir -RunIdText $RunId -Stage $Mapping.stage -TaskIdNum $Mapping.task_id -NodeId $NodeId -StartRoleText $Result.text
    }
    return $bridge
}

function Invoke-Dispatch {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }

    # read-only state preview (tree side)
    $treeData = Get-TreeStatusView $RunId
    $node = Get-NodeFromTree $treeData $NodeId
    $nodeStatus = if ($node) { [string]$node.status } else { "missing" }
    if ($nodeStatus -in @("done", "pruned", "missing")) {
        Write-ErrorResult "NODE_NOT_DISPATCHABLE" "Node $NodeId is '$nodeStatus'; dispatch targets open work only." 1
    }
    # 三道门守卫（guard 函数见本节顶部；门序保持：阶段闸门 -> 冲突门 -> 任务目标锚定）
    Assert-DispatchStageGate $bridge $mapping
    Assert-DispatchConflictGate -RunIdText $RunId -NodeId $NodeId -Bridge $bridge -RunDir $runDir -TreeData $treeData

    # 任务目标锚定（dispatch-task-goal-anchoring）：brief/摘要均自 PERSISTED
    # node.task 派生，空则不注入（与旧消息逐字节一致）；
    # 细节见 Get-DispatchTaskAnchorArgs。
    $startArgs = Get-DispatchTaskAnchorArgs -RunIdText $RunId -NodeId $NodeId -Bridge $bridge -Mapping $mapping
    # 复用解析（inplace-redo-session-reuse，Resolve-DispatchReuse）：手动重推是
    # pointer 类失败的指定出路，命中复用即再投原会话而非堆新会话；
    # -NoReuse 显式禁用（逃生开关）。树级节点不参与（v1 边界）。
    $reusedId = $null
    if (-not $NoReuse -and -not $DryRun) {
        $reuseSession = Resolve-DispatchReuse -RunId $RunId -NodeId $NodeId -RunDir $runDir -Bridge $bridge -Mapping $mapping
        if ($null -ne $reuseSession) {
            $reusedId = [string]$reuseSession.session_id
            $startArgs += @("-ExistingSessionId", $reusedId)
        }
    }
    $r = Invoke-StartRole ($startArgs + $(if ($DryRun) { @("-DryRun") } else { @() }))
    # a real (non-dry-run) dispatch IS a push: record it in the ledger — the
    # manual path is the designated resolution for pointer-class failures, and
    # an unrecorded success would leave needs_repush stuck forever (status
    # would keep advertising manual work that is already done).
    if (-not $DryRun) {
        $bridge = Register-DispatchPush -RunDir $runDir -Bridge $bridge -NodeId $NodeId -Mapping $mapping -Result $r -ReusedId $reusedId
    }
    if (-not $DryRun -and $r.exit -ne 0) {
        Write-ErrorResult "DISPATCH_FAILED" "start-role exited $($r.exit): $($r.text)" 1
    }
    return @{
        success = $true
        data    = @{
            run_id     = $RunId
            node_id    = $NodeId
            task_id    = $mapping.task_id
            stage      = $mapping.stage
            node_status = $nodeStatus
            dry_run    = [bool]$DryRun
            reused_session_id = $reusedId
            start_role = @{ exit = $r.exit; output = $r.text }
            next_step  = "the dispatched session's first action: delivery-bridge.cmd -Command claim -RunId $RunId -NodeId $NodeId -Role $($mapping.stage)"
        }
    }
}

# === Command: claim (composite: prechecks -> tree -> flow) ===

function Resolve-ClaimTarget {
    # Resolve the claim target: bridge-mapped (task, stage) OR a tree-level node
    # (acceptance chain / in-tree repair node, no TaskId — the unified branch).
    # Returns @{ stage; task_id; tree_level; acceptance }.
    param($Bridge, [string]$RoleText, [string]$RunDirText)
    $mapping = Get-NodeTaskStage $Bridge $NodeId
    if ($null -ne $mapping) {
        $stage = if ([string]::IsNullOrWhiteSpace($RoleText)) { $mapping.stage } else { $RoleText }
        if ($script:RoleOrder -notcontains $stage) { Write-ErrorResult "ROLE_INVALID" "-Role must be one of PM/CTO/UX/DEV/QA" 1 }
        return @{ stage = $stage; task_id = [int]$mapping.task_id; tree_level = $false; acceptance = $null }
    }
    $info = Get-TreeLevelInfo $Bridge $RunDirText $NodeId
    if ($null -eq $info) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $stage = if ([string]::IsNullOrWhiteSpace($RoleText)) { $info.role } else { $RoleText }
    if ($stage -ne $info.role) {
        Write-ErrorResult "ROLE_INVALID" "Tree-level node $NodeId carries role '$($info.role)' ($($info.kind)); claim it as -Role $($info.role)." 1
    }
    return @{ stage = $stage; task_id = 0; tree_level = $true; acceptance = $info }
}

function Test-ClaimTreeState {
    # Precheck 1 (tree side, read-only): status + dependency blockers. Returns
    # @{ node; parked; leaf } or a deterministic conflict verdict.
    param($Bridge, [string]$NodeIdText, [string]$RunDirText)
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeIdText)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    # "parked" = recycled by reclaim and waiting for the next claimant: the tree side
    # shows claimed_by=planner-reclaim. A parked node is claimable (steal + force).
    $parked = ($node.status -eq "claimed" -and [string]$node.claimed_by -eq "planner-reclaim")
    if ($node.status -ne "pending" -and -not $parked) {
        # deterministic conflict feedback + claimable list (acceptance: duplicate
        # sessions never spin); delivery units = mapped + tree-level acceptance
        # nodes (the structural root n1 is not a delivery unit)
        $claimable = @()
        $nx = Get-LeafNextView $RunId
        if ($null -ne $nx) {
            foreach ($p in @(Convert-ToSafeArray $nx.pending)) {
                if ((Get-NodeTaskStage $Bridge ([string]$p.id)) -or (Get-TreeLevelInfo $Bridge $RunDirText ([string]$p.id))) { $claimable += $p.id }
            }
        }
        $who = if ($node.claimed_by) { " (claimed_by=$($node.claimed_by) at $($node.claimed_at))" } else { "" }
        Write-ErrorResult "NODE_NOT_CLAIMABLE" "Node $NodeIdText is '$($node.status)'$who. Claimable nodes right now: [$($claimable -join ', ')]. Pick one of those (delivery-bridge claim -RunId $RunId -NodeId <id> -Role <stage>)." 1
    }
    $blockedBy = @()
    if ($leafStatus.json.data.dependencies -and $leafStatus.json.data.dependencies.blocked_by) {
        $blockedBy = @($leafStatus.json.data.dependencies.blocked_by)
    }
    if ($blockedBy.Count -gt 0) {
        Write-ErrorResult "NODE_BLOCKED_BY_DEPS" "Node $NodeIdText is blocked by unsatisfied dependencies: [$($blockedBy -join ', ')]. Wait for them to settle or pick another node." 1
    }
    return @{ node = $node; parked = $parked; leaf = $leafStatus.json.data }
}

function Test-ClaimFlowState {
    # Precheck 2 (flow side, read-only): task exists + active + role owner + no
    # live worker conflict. Returns @{ force } — set for parked slots AND
    # replacement-node residue (both overwrite the lingering entry with -Force).
    param($Bridge, [string]$NodeIdText, [int]$TaskIdNum, [string]$Stage, [bool]$Parked, $Node)
    $flow = Read-ArchiveTasks $Bridge.archive
    $task = Find-ArchiveTask $flow.tasks $TaskIdNum
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskIdNum not found in $($Bridge.archive)" 2 }
    if (([string]$task.lifecycle) -ne "active") {
        Write-ErrorResult "TASK_NOT_CLAIMABLE" "TaskId $TaskIdNum lifecycle is '$($task.lifecycle)' (only active tasks can be claimed)" 1
    }
    $owners = @()
    if ($null -ne $task.currentOwners) { $owners = @($task.currentOwners) }
    if ($owners -notcontains $Stage) {
        Write-ErrorResult "ROLE_NOT_OWNER" "'$Stage' is not in currentOwners of TaskId ${TaskIdNum}: [$($owners -join '+')]" 1
    }
    $flowForce = $false
    foreach ($w in @(Convert-ToSafeArray $task.currentWorker)) {
        if ($null -eq $w) { continue }
        $keys = @()
        if ($w -is [System.Collections.IDictionary]) { $keys = @($w.Keys) } else { $keys = @($w.PSObject.Properties | ForEach-Object { $_.Name }) }
        if ($keys -contains $Stage) {
            $flowForce = Test-ClaimWorkerEntry -Bridge $Bridge -NodeIdText $NodeIdText -TaskIdNum $TaskIdNum -Stage $Stage -Parked $Parked -Node $Node -Entry $w
        }
    }
    return @{ force = $flowForce }
}

function Test-ClaimWorkerEntry {
    # One existing currentWorker entry vs this claim: parked residue / replacement
    # residue overwrite with -Force, anything else is a live-conflict hard error.
    param($Bridge, [string]$NodeIdText, [int]$TaskIdNum, [string]$Stage, [bool]$Parked, $Node, $Entry)
    $t0 = [string](@($Entry) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_[$Stage] } else { $_.$Stage } })
    if ($Parked) {
        # the parked entry was left by reclaim for exactly this next claimant;
        # the flow write below overwrites it with -Force
        return $true
    }
    # replacement-node residue: reclaim's rejected-delivery mode grafts a fresh
    # PENDING node for the same (task, stage) while the flow entry lingers.
    # Invariant: a live flow claim <=> the bridge's current stage node is in an
    # actively claimed state. If the current stage node IS this (pending) node,
    # the flow entry must be reclaim residue -> overwrite with -Force.
    $curStageNode = $null
    if ($Bridge.tasks.Contains("$TaskIdNum") -and $null -ne $Bridge.tasks["$TaskIdNum"]['stages']) {
        $bStages = $Bridge.tasks["$TaskIdNum"]['stages']
        if ($bStages.Contains($Stage)) { $curStageNode = [string]$bStages[$Stage] }
    }
    if ($curStageNode -eq $NodeIdText -and $Node.status -eq "pending") { return $true }
    Write-ErrorResult "FLOW_CLAIM_CONFLICT" "TaskId $TaskIdNum already has a currentWorker entry for $Stage (claimed at $t0). If that session is dead, ask the Planner to run: delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $NodeIdText" 1
}

function Invoke-ClaimWrites {
    # Write 1: tree side (parked nodes need -Steal to leave the reclaim parking
    # slot). Write 2: flow side — SKIPPED for tree-level acceptance nodes (no
    # TaskId exists; the tree settle is the whole state machine for them). A
    # flow conflict here is a half-claim (rare after the precheck).
    param([string]$NodeIdText, [int]$TaskIdNum, [string]$Stage, [bool]$Parked, [bool]$FlowForce, [bool]$TreeLevel, $Bridge)
    $treeArgs = @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeIdText, "-Worker", $Stage)
    if ($Parked) { $treeArgs += "-Steal" }
    $r1 = Invoke-GoalTreeLeaf $treeArgs
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "TREE_CLAIM_FAILED" "leaf claim failed: $($r1.text)" 1
    }
    if ($TreeLevel) { return @{ tree = $r1.json.data; flow = $null } }
    $flowArgs = @("-Command", "claim", "-TaskId", "$TaskIdNum", "-Role", $Stage, "-Archive", $Bridge.archive)
    if ($FlowForce) { $flowArgs += "-Force" }
    $r2 = Invoke-RddFlow $flowArgs
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        Write-ErrorResult "BRIDGE_CLAIM_HALF_FAILED" "Tree side claimed, rdd-flow claim errored: $($r2.text). Disposition: run 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $NodeIdText' to recycle the claim, or retry after fixing the flow-side error." 1
    }
    if ($r2.json.data.claimed -ne $true) {
        $conf = $r2.json.data.conflict
        Write-ErrorResult "BRIDGE_CLAIM_HALF_FAILED" "Tree side claimed but rdd-flow reports an existing $Stage claim on TaskId $TaskIdNum (at $($conf.claimedAt)). Disposition: run 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $NodeIdText' to recycle this half-claim." 1
    }
    return @{ tree = $r1.json.data; flow = $r2.json.data }
}

function Get-DesignReviewClaimMaps {
    # 审查对象面 + design_maps 行构造（Add-ClaimTreeLevelContext 子过程）：docs 清单
    # + 逐 doc 的 files/warnings（机械缓存刷新——文档可能刚落盘，原地更新
    # $Bridge.design_maps）。返回 @{ docs; map_rows }。
    param([string]$RunDir, $Bridge, $Stage)
    $docs = @(); $mapRows = @()
    if ($null -eq $Stage) { return @{ docs = @($docs); map_rows = @($mapRows) } }
    $flowTasks = @(Get-DesignReviewFlowTasks $Bridge)
    $dd = Get-StageDesignDocs $Bridge $Stage $flowTasks
    $docs = @($dd.docs)
    $mapsRes = Get-DesignMaps $RunDir $Bridge $flowTasks
    foreach ($rel in @($docs)) {
        $m = $null
        if ($mapsRes.maps -is [System.Collections.IDictionary] -and $mapsRes.maps.Contains($rel)) { $m = $mapsRes.maps[$rel] }
        $mapRows += @{
            doc = $rel
            files = @($(if ($null -ne $m) { Convert-ToSafeArray $m['files'] | ForEach-Object { [string]$_.path } } else { @() }))
            warnings = @($(if ($null -ne $m) { Convert-ToSafeArray $m['warnings'] } else { @() }))
        }
    }
    return @{ docs = @($docs); map_rows = @($mapRows) }
}

function Add-ClaimTreeLevelContext {
    # tree-level claim context (R1 acceptance chain / stage acceptance point /
    # design review node / in-tree repair node): mutates $Data with tree_level +
    # acceptance + start_context per kind.
    param($Data, $Target, $Bridge)
    $Data['tree_level'] = $true
    $kind = [string]$Target.acceptance.kind
    if ($kind -eq 'stage_acceptance') {
        $sa = $Target.acceptance
        $Data['acceptance'] = @{
            kind           = 'stage_acceptance'
            stage_id       = [string]$sa.stage_id
            criteria_ref   = $sa.criteria_ref
            criteria_items = @($sa.criteria_items)
            slice          = [string]$sa.slice
        }
        $Data['start_context'] = "stage acceptance node ($([string]$sa.stage_id)): 集成验收点判据子集 + 可运行切片形态 in node.task (claim 输出全文); 交付记录 = 验证摘要 + 切片运行证据 (extras.verification)"
        return
    }
    if ($kind -eq 'design_review') {
        # AUDITOR 设计汇聚审查节点（auditor-design-stage-review）：claim 注入新形态
        # design_review——阶段设计文档清单 + design_maps 机械缓存引用（DESIGN_MAP_INVALID
        # 警示为裁定输入）+ 架构约定引用 + 整体验收判据 ref（DESIGN 链头注入同构）。
        $drInfo = $Target.acceptance
        $p = Get-PlanSection $Bridge
        $stage = $null
        if ($null -ne $p) {
            foreach ($st in @($p['stages'])) { if (([string]$st['id']) -eq ([string]$drInfo.stage_id)) { $stage = $st; break } }
        }
        $face = Get-DesignReviewClaimMaps (Get-BridgeRunDir ([string]$Bridge.run_id)) $Bridge $stage
        $a = Get-AcceptanceSection $Bridge
        $Data['acceptance'] = @{
            kind         = 'design_review'
            stage_id     = [string]$drInfo.stage_id
            docs         = @($face.docs)
            design_maps  = @($face.map_rows)
            conventions  = Get-ConventionsRef $Bridge
            criteria_ref = $(if ($null -ne $a) { [string]$a['criteria_ref'] } else { $null })
            report       = ($script:DesignReviewReportFmt -f ([string]$drInfo.stage_id))
        }
        $Data['start_context'] = "design review node ($([string]$drInfo.stage_id)): 五查汇聚审查本阶段全部设计产物 — docs in acceptance.docs (claim 输出全文); design_maps 机械缓存 + DESIGN_MAP_INVALID 警示为 change_map 维裁定输入; 变更地图/交互说明类对象缺产物即 fail; 产出 DesignReviewFile: $($script:DesignReviewReportFmt -f ([string]$drInfo.stage_id)) (+同名 .md 人读镜像), 总裁定由引擎推导(pass ⇔ 全文档 pass 且全局零 blocking)"
        return
    }
    if ([bool]$Target.acceptance.chain) {
        $a = Get-AcceptanceSection $Bridge
        $Data['acceptance'] = @{
            kind       = $kind
            criteria_ref = $(if ($null -ne $a) { [string]$a['criteria_ref'] } else { $null })
            report     = $script:AcceptanceReportRel
            conclusion_rule = "§3 以一行『总结论：通过』或『总结论：不通过』收口（结论必须可判）"
        }
        $Data['start_context'] = "acceptance node ($kind): 整体验收判据 — $([string]$Data['acceptance'].criteria_ref); mission + deliverable convention in node.task (claim 输出全文)"
        return
    }
    $Data['start_context'] = "tree-level repair node ($kind, role $([string]$Target.acceptance.role)): mission + deliverable convention in node.task (claim 输出全文); 修复节点不动 flow 流转"
}

function New-ClaimResult {
    # Claim response assembly: the worker's context bundle (tree claim + flow
    # claim + task summary + report hint), auto_mode passthrough when enabled.
    param($Bridge, [string]$NodeIdText, $Target, [string]$Stage, $Writes)
    $data = @{
        run_id      = $RunId
        node_id     = $NodeIdText
        task_id     = $(if ($Target.tree_level) { $null } else { $Target.task_id })
        stage       = $Stage
        tree_claim  = @{ node = $Writes.tree.node; report_next = $Writes.tree.report_next; dep_note = $Writes.tree.dep_note }
        flow_claim  = $(if ($null -ne $Writes.flow) { @{ claimed = $Writes.flow.claimed; currentWorker = $Writes.flow.currentWorker } } else { $null })
        task        = $(if ($null -ne $Writes.flow) { $Writes.flow.task } else { $null })
        report_hint = "goal-tree bridge run: on completion report back to the Planner instead of start-role-ing a downstream role — goal-tree-leaf.cmd -Command report -RunId $RunId -Worker $Stage -CallbackFile <cb.json>. Artifact locations ride the callback: citations = change list (real paths; settle checks every ref exists), full_report = main deliverable doc pointer (design doc / implementation notes; expected in bridge runs), extras.verification = verification result (settle requires citations + verification non-empty). DEV quality gate (dev-quality-prescan-gate): when the change set touches PowerShell (.ps1), extras.quality_scan = the code-metrics credential (full form: tool/base/files/thresholds/threshold_source/violation_count/exit_code, violation_count must be 0 and every cited .ps1 inside files; skip form: skip+reason only when no PowerShell file changed) — the settle handoff gate mechanically rejects a DEV delivery without it"
        auto_mode   = $(if ($null -ne (Get-AutoModeSection $Bridge)) {
            # authorization passthrough (planner-auto-mode): the claim is the
            # worker's mandatory first action, so it is the natural injection
            # point — enabled flag + the immutable snapshot + the protocol hint.
            @{
                enabled  = $true
                policy   = (Get-AutoModeSection $Bridge)['policy']
                protocol = Get-AutoModeProtocolHint $RunId
            }
        } else { $null })
    }
    if ($Target.tree_level) { Add-ClaimTreeLevelContext $data $Target $Bridge }
    else {
        $data['start_context'] = "requirement: $($Bridge.archive_rel)/$($Bridge.tasks["$($Target.task_id)"].requirement) — full pointers in task.summary fields above; DEV note: PowerShell changes require extras.quality_scan (code-metrics credential) at report time — see rdd-dev/references/execution-rules.md"
    }
    return @{ success = $true; data = $data }
}

function Invoke-BridgeClaim {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $target = Resolve-ClaimTarget $bridge $Role $runDir
    # stage gate (long-task-planning): tree-level nodes carry no stage, only
    # mapped delivery claims wait on earlier stages' acceptance points.
    # design-review gate (auditor-design-stage-review): same tree-level
    # exemption — the [设计审查·S<k>] node itself claims as AUDITOR freely.
    if (-not $target.tree_level) {
        Assert-PlanGateOpen $bridge ([int]$target.task_id)
        Assert-DesignReviewGateOpen $bridge ([int]$target.task_id) ([string]$target.stage)
    }
    $ts = Test-ClaimTreeState $bridge $NodeId $runDir
    $flowForce = $false
    if (-not $target.tree_level) {
        $fs = Test-ClaimFlowState -Bridge $bridge -NodeIdText $NodeId -TaskIdNum $target.task_id -Stage $target.stage -Parked ([bool]$ts.parked) -Node $ts.node
        $flowForce = [bool]$fs.force
    }
    $writes = Invoke-ClaimWrites -NodeIdText $NodeId -TaskIdNum $target.task_id -Stage $target.stage -Parked ([bool]$ts.parked) -FlowForce $flowForce -TreeLevel ([bool]$target.tree_level) -Bridge $bridge
    return New-ClaimResult -Bridge $bridge -NodeIdText $NodeId -Target $target -Stage $target.stage -Writes $writes
}

# === Command: reclaim (composite recovery: dead claims AND rejected deliveries) ===

function Invoke-ReclaimRejectedDelivery {
    # rejected-delivery recovery: the reported node FAILED the four-check gate.
    # Dual path (inplace-redo-session-reuse): when the ORIGINAL claim session
    # (state/claims sidecar dsh_session_id) is provably ALIVE and reuse is not
    # disabled, recover IN PLACE — no prune, no graft: deliver the redo pointer
    # (failure list + re-report instruction) into the original session, then
    # migrate the node reported -> claimed (goal-tree redo, same session).
    # dead / unproven / non-dsh shells / -NoReuse fall back to the legacy
    # prune + graft + repush path below (byte-identical pre-feature behavior).
    param([string]$RunDir, $Bridge, $Node, [string]$NodeIdText, [int]$TaskId, [string]$Stage)
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $Node -NodeId $NodeIdText -Bridge $Bridge)
    if ($problems.Count -eq 0) {
        Write-ErrorResult "RECLAIM_REQUIRES_UNQUALIFIED" "Node $NodeIdText is reported with QUALIFIED evidence — settle it instead (settle -RunId $RunId -NodeId $NodeIdText); reclaim only recovers dead claims or rejected deliveries." 1
    }
    # --- in-place gate: the original claim session is alive and reuse is on ---
    $live = Get-ClaimLiveness $RunId $NodeIdText
    if (-not [bool]$NoReuse -and $live.liveness -eq "alive" -and -not [string]::IsNullOrWhiteSpace([string]$live.session_id)) {
        return Invoke-ReclaimInPlace -RunDir $RunDir -Bridge $Bridge -Node $Node -NodeIdText $NodeIdText -TaskId $TaskId -Stage $Stage -Problems $problems -Live $live
    }
    $reason = "delivery rejected by settle evidence gate: $($problems -join '; ')"
    $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", $RunId, "-NodeId", $NodeIdText, "-Reason", $reason)
    if ($rp.exit -ne 0 -or -not $rp.json.success) {
        Write-ErrorResult "RECLAIM_PRUNE_FAILED" "prune of rejected delivery failed: $($rp.text)" 1
    }
    # graft a replacement node for the same (task, stage) under the same parent
    $flow = Read-ArchiveTasks $Bridge.archive
    $task = Find-ArchiveTask $flow.tasks $TaskId
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found in $($Bridge.archive)" 2 }
    $g = Invoke-GraftNextStage $RunDir $Bridge $task ([string]$Node.parent) $Stage
    if (-not $g.success) { Write-ErrorResult "RECLAIM_GRAFT_FAILED" "replacement node graft failed after prune (task $TaskId stays routed at $Stage): $($g.error)" 1 }
    $Bridge = $g.bridge
    $newNodeId = $g.node_id
    $null = Invoke-RddFlow @("-Command", "claim", "-TaskId", "$TaskId", "-Role", $Stage, "-Archive", $Bridge.archive, "-Force")
    # plan recovery tail (long-task-planning) BEFORE the push tail below.
    Write-PlanRecoveryTail $RunDir $Bridge 'reclaim' $NodeIdText $TaskId "rejected delivery pruned; redo grafted as $newNodeId"
    # the fresh replacement node is never-pushed by construction — push it now
    # (goal-tree-goal-root: recycle-then-repush, no manual dispatch step).
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim" (-not [bool]$NoReuse)
    $Bridge = $push.bridge
    return @{
        success = $true
        data    = @{
            run_id       = $RunId
            node_id      = $newNodeId
            pruned_node  = $NodeIdText
            task_id      = $TaskId
            stage        = $Stage
            reclaimed    = $true
            mode         = "rejected-delivery"
            fallback     = $(if ($live.liveness -eq "alive") { "no_reuse" } else { $live.liveness })
            liveness     = $live
            auto_push    = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step    = "failed delivery pruned (ledger keeps the audit); replacement node $newNodeId grafted" + $(if (@($push.pushed) -contains $newNodeId) { " and auto-pushed" } else { " — re-push via status touch or dispatch -NodeId $newNodeId" })
        }
    }
}

function Get-RedoFailureRef {
    # 失败清单组装（inplace-redo-session-reuse 设计决策 6）：settle 四查
    # problems + 被驳回报告的 full_report/extras.verification（截断）+
    # 规划者显式 -FailureRef（脚本级参数，经作用域链解析），'；' 连接、
    # 折行压平。空串由调用方硬拒（REDO_FAILURE_REF_MISSING）。
    param([string]$RunDir, $Node, $Problems)
    $parts = @()
    foreach ($p in @(Convert-ToSafeArray $Problems)) { $parts += [string]$p }
    $cb = Find-AcceptedCallback $RunDir $Node
    if ($null -ne $cb) {
        if ($cb.callback.PSObject.Properties['full_report'] -and -not [string]::IsNullOrWhiteSpace([string]$cb.callback.full_report)) {
            $parts += "full_report: $([string]$cb.callback.full_report)"
        }
        $verif = $null
        if ((Test-PropPresent $cb.callback 'extras') -and $null -ne $cb.callback.extras -and (Test-PropPresent $cb.callback.extras 'verification')) { $verif = [string]$cb.callback.extras.verification }
        if (-not [string]::IsNullOrWhiteSpace($verif)) {
            $verif = ($verif -replace '\s+', ' ').Trim()
            if ($verif.Length -gt 160) { $verif = $verif.Substring(0, 159) + "…" }
            $parts += "verification: $verif"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FailureRef)) { $parts += "planner: $FailureRef" }
    return (($parts -join '；') -replace '\r?\n', ' ').Trim()
}

function Invoke-RedoPointerPush {
    # 重做指针投递（Invoke-ReclaimInPlace 的投递步骤）：把失败清单 + 原地
    # 重报指令拼进附录，经 Invoke-StartRolePush 投给原会话。投递失败即
    # RECLAIM_INPLACE_PROMPT_FAILED（Write-ErrorResult 直接退出——状态零
    # 迁移）。返回 $push（含更新后的 bridge）。
    param([string]$RunDir, $Bridge, [string]$NodeIdText, [int]$TaskId, [string]$Stage, [string]$Worker, [string]$SessionId, [string]$FailureRefText, [switch]$TreeLevel)
    $qsHint = ""
    if ($Stage -eq "DEV") { $qsHint = "；DEV 交付另需 extras.quality_scan 质量扫描凭据（violation_count=0）" }
    $appendix = "重做指令：节点 $NodeIdText 的交付未通过 settle 四查（rejected delivery）。失败清单：$FailureRefText。请在原会话内修复上述问题后重新出报：goal-tree-leaf.cmd -Command report -RunId $RunId -Worker $Worker -CallbackFile <回调JSON>（citations=改动清单、extras.verification=验证结果$qsHint）。本节点已退回 claimed（原会话 in-place 重做，ledger 已留 redo 留痕）。"
    $cand = @{ node = $NodeIdText; stage = $Stage; task_id = $TaskId; tree_level = ([bool]$TreeLevel) }
    $push = Invoke-StartRolePush -Cand $cand -RunDir $RunDir -Bridge $Bridge -TaskText (Get-NodeTaskText -RunId $RunId -NodeId $NodeIdText) -ExistingSessionId $SessionId -Appendix $appendix
    if (-not $push.ok) {
        # pointer-class failure onto an existing session: state NOT migrated
        # (zero residue), the manual outs are dispatch re-push (reuse
        # resolution re-prompts the same session) or a -NoReuse rerun
        Write-ErrorResult "RECLAIM_INPLACE_PROMPT_FAILED" "redo pointer delivery into the original session ($SessionId) failed (retry_class=$($push.retry_class)): $($push.error). Node stays reported (no state migrated). Re-push manually: dispatch -RunId $RunId -NodeId $NodeIdText (reuse resolution re-prompts the same session), or rerun reclaim with -NoReuse to take the rebuild path." 1
    }
    return $push
}

function Invoke-ReclaimInPlace {
    # in-place redo (inplace-redo-session-reuse, acceptance 1): recover the
    # rejected delivery in the ORIGINAL worker session — no prune, no graft,
    # no new session. Execution order is prompt-first (design decision 8):
    #   four-check (caller) -> liveness gate (caller) -> failure-ref gate ->
    #   no_push gate -> pointer delivery -> goal-tree redo migration (LAST)
    # A crash between delivery and migration leaves a retryable reported node
    # (redo is idempotent, reclaim rerun continues) — never a live session
    # holding a claimed lock without instructions. The failure list is a
    # mechanical precondition: an empty assembled ref with no -FailureRef
    # hard-rejects (REDO_FAILURE_REF_MISSING) — a redo pointer without a
    # failure list makes the session guess, worse than a fresh session.
    param([string]$RunDir, $Bridge, $Node, [string]$NodeIdText, [int]$TaskId, [string]$Stage, $Problems, $Live, [switch]$TreeLevel)
    $sessionId = [string]$Live.session_id
    $worker = [string]$Node.claimed_by
    if ([string]::IsNullOrWhiteSpace($worker)) { $worker = $Stage }
    # --- failure-ref assembly (decision 6, Get-RedoFailureRef): four-check
    # problems + the failing report's full_report/extras + the planner's
    # -FailureRef, joined; the ledger redo entry and the redo pointer both
    # carry it. Mechanical precondition: empty -> caller hard-rejects.
    $failureRef = Get-RedoFailureRef -RunDir $RunDir -Node $Node -Problems $Problems
    if ([string]::IsNullOrWhiteSpace($failureRef)) {
        Write-ErrorResult "REDO_FAILURE_REF_MISSING" "Node $NodeIdText has a live claim session ($sessionId) but no failure list could be assembled (four-check problems empty, no full_report/extras on the accepted report, no -FailureRef given). in-place redo without a failure list makes the session guess — pass -FailureRef <失败清单引用> or rerun with -NoReuse to take the rebuild path." 2
    }
    # --- no_push gate (design decision 7): isolated runs skip the delivery but
    # keep the tree-side migration — a no_push run stays zero-backend for its
    # whole lifetime; next_step names the manual delivery path
    $noPush = ((Test-PropPresent $Bridge 'no_push') -and $Bridge['no_push'] -eq $true)
    $push = $null
    if (-not $noPush) {
        $push = Invoke-RedoPointerPush -RunDir $RunDir -Bridge $Bridge -NodeIdText $NodeIdText -TaskId $TaskId -Stage $Stage -Worker $worker -SessionId $sessionId -FailureRef $failureRef -TreeLevel:$TreeLevel
        $Bridge = $push.bridge
    }
    # --- migration (prompt-first: the LAST write) ---
    $rr = Invoke-GoalTree @("-Command", "redo", "-RunId", $RunId, "-NodeId", $NodeIdText, "-Worker", $worker, "-FailureRef", $failureRef, "-Trigger", "reclaim")
    if ($rr.exit -ne 0 -or -not $rr.json.success) {
        Write-ErrorResult "RECLAIM_REDO_FAILED" "goal-tree redo migration failed for node $NodeIdText (pointer may already be delivered into session $sessionId — the session's next report may bounce once; retry reclaim, redo is idempotent): $($rr.text)" 1
    }
    # plan recovery tail (long-task-planning): a redo is still a reclaim
    # deviation — the audit trail keeps counting rework rounds
    Write-PlanRecoveryTail $RunDir $Bridge 'reclaim' $NodeIdText $TaskId "rejected delivery returned in place to the original session (redo; failure list recorded)"
    $nextStep = ""
    if ($noPush) {
        $nextStep = "node $NodeIdText redone in place (reported -> claimed, same session $sessionId) but NOT delivered — this is a no_push run. Deliver the redo pointer manually into the live session, e.g. dispatch -RunId $RunId -NodeId $NodeIdText (reuse resolution prompts the same session)."
    }
    else {
        $nextStep = "original session $sessionId received the redo pointer (failure list included) and node $NodeIdText is back to claimed — the session fixes the delivery and reports again in place (no context reload, no new session)."
    }
    return @{
        success = $true
        data    = @{
            run_id       = $RunId
            node_id      = $NodeIdText
            task_id      = $TaskId
            stage        = $Stage
            reclaimed    = $true
            mode         = "rejected-delivery-inplace"
            session      = @{ id = $sessionId; liveness = $Live.liveness; reason = $Live.reason }
            failure_ref  = $failureRef
            no_push      = $noPush
            auto_push    = $(if ($null -ne $push) { @{ delivered = $true; reused_session_id = $sessionId } } else { $null })
            next_step    = $nextStep
        }
    }
}

function Test-ReclaimLiveness {
    # liveness gate (goal-tree-goal-root decision 6): alive sessions are
    # mechanically unreclaimable (RECLAIM_TARGET_ALIVE); unknown liveness falls
    # back to the shared DeadClaimMinutes threshold — younger claims are not
    # provably dead. Returns the liveness probe row.
    param([string]$RunId, [string]$NodeIdText, $Node)
    $live = Get-ClaimLiveness $RunId $NodeIdText
    if ($live.liveness -eq "alive") {
        Write-ErrorResult "RECLAIM_TARGET_ALIVE" "Node $NodeIdText is claimed by a LIVE session (session_id=$($live.session_id), verified via $($live.reason)). Long-running work is not reclaimable — wait for its report, or have the session itself release/steal. If you are certain this is wrong, verify the session in dsh first." 1
    }
    if ($live.liveness -eq "unknown") {
        $ageMin = $null
        if ($Node.claimed_at) {
            try { $ageMin = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($Node.claimed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes } catch {}
        }
        if ($null -eq $ageMin -or $ageMin -lt $DeadClaimMinutes) {
            $shownAge = if ($null -ne $ageMin) { $ageMin } else { "?" }
            Write-ErrorResult "RECLAIM_UNPROVEN_DEAD" "Node $NodeIdText claim liveness is unknown ($($live.reason)) and the claim is only $shownAge min old (< $DeadClaimMinutes min threshold) — not provably dead, refusing to reclaim (better to wait than to miskill; timeout marks ≠ dead). Retry after the threshold, or reclaim from a dsh shell where the agents registry can verify the session." 1
        }
    }
    return $live
}

function Invoke-ReclaimDeadClaim {
    # dead-claim recovery: steal the tree claim, force-reclaim the flow route,
    # flag for re-push and auto-dispatch immediately (recycle-then-repush).
    param([string]$RunDir, $Bridge, $Node, [string]$NodeIdText, [int]$TaskId, [string]$Stage)
    $worker = "planner-reclaim"
    $live = Test-ReclaimLiveness $RunId $NodeIdText $Node
    # tree side: -Steal only recovers nodes stuck in claimed
    $r1 = Invoke-GoalTreeLeaf @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeIdText, "-Worker", $worker, "-Steal")
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "RECLAIM_TREE_FAILED" "leaf steal failed: $($r1.text)" 1
    }
    # flow side: -Force overwrites this role's timestamp
    $r2 = Invoke-RddFlow @("-Command", "claim", "-TaskId", "$TaskId", "-Role", $Stage, "-Archive", $Bridge.archive, "-Force")
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        Write-ErrorResult "RECLAIM_FLOW_FAILED" "rdd-flow claim -Force failed: $($r2.text)" 1
    }
    $Bridge = Set-NodeRepushFlag $RunDir $Bridge $NodeIdText
    # plan recovery tail (long-task-planning) BEFORE the push tail below.
    Write-PlanRecoveryTail $RunDir $Bridge 'reclaim' $NodeIdText $TaskId "dead claim stolen (session never delivered)"
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim" (-not [bool]$NoReuse)
    $Bridge = $push.bridge
    return @{
        success = $true
        data    = @{
            run_id     = $RunId
            node_id    = $NodeIdText
            task_id    = $TaskId
            stage      = $Stage
            reclaimed  = $true
            mode       = "dead-claim"
            steal_count = $r1.json.data.node.steal_count
            liveness   = $live
            auto_push  = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step  = $(if (@($push.pushed) -contains $NodeIdText) { "fresh session auto-pushed for the parked node; its first action re-claims with -Role $Stage" } else { "node is parked as '$worker' — re-push it via status touch or dispatch -NodeId $NodeIdText (its first action re-claims with -Role $Stage)" })
        }
    }
}

function Invoke-ReclaimDesignReviewNode {
    # tree-level design-review dead-claim recovery (auditor-design-stage-review;
    # Invoke-BridgeReclaim 分支体): no task.json flow side — steal the dead claim,
    # flag for re-push, auto-dispatch. A reported review node is NOT reclaimable
    # here (its delivery is adjudicated by the settle gate; the AUDITOR session
    # re-reports or the planner waits).
    param([string]$RunDir, $Bridge, [string]$NodeId)
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $drNode = $leafStatus.json.data.node
    if (([string]$drNode.status) -eq "reported") {
        Write-ErrorResult "RECLAIM_NOT_POSSIBLE" "Design review node $NodeId is reported — adjudicate it via settle (four evidence checks + DesignReviewFile contract gate); reclaim only recovers dead claims." 1
    }
    if (([string]$drNode.status) -in @("done", "pruned")) {
        Write-ErrorResult "RECLAIM_NOT_POSSIBLE" "Node $NodeId is '$([string]$drNode.status)' — terminal; nothing to reclaim." 1
    }
    if (([string]$drNode.status) -eq "pending") {
        Write-ErrorResult "RECLAIM_NOT_NEEDED" "Node $NodeId is pending (nobody claimed it) — a plain bridge claim is enough." 1
    }
    $null = Test-ReclaimLiveness $RunId $NodeId $drNode
    $worker = "planner-reclaim"
    $r1 = Invoke-GoalTreeLeaf @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeId, "-Worker", $worker, "-Steal")
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "RECLAIM_TREE_FAILED" "leaf steal failed: $($r1.text)" 1
    }
    $Bridge = Set-NodeRepushFlag $RunDir $Bridge $NodeId
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim" (-not [bool]$NoReuse)
    return @{
        success = $true
        data    = @{
            run_id     = $RunId
            node_id    = $NodeId
            task_id    = $null
            stage      = "AUDITOR"
            reclaimed  = $true
            mode       = "dead-claim (tree-level design review node)"
            steal_count = $r1.json.data.node.steal_count
            auto_push  = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step  = $(if (@($push.pushed) -contains $NodeId) { "fresh AUDITOR session auto-pushed for the parked review node" } else { "review node parked as '$worker' — re-push via status touch or dispatch -NodeId $NodeId" })
        }
    }
}

function Invoke-BridgeReclaim {
    # composite recovery (dead claims AND rejected deliveries) — orchestrator
    # over the two mode helpers (QA function-size gate decomposition; messages
    # and codes are unchanged from the pre-split single function).
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) {
        # tree-level design-review node (auditor-design-stage-review; 边界与异常:
        # 审查节点自身失败走既有 reclaim dead-claim 通道)——分支体见
        # Invoke-ReclaimDesignReviewNode（本函数行数预算拆分）。
        # derivation PM node (planner-midrun-derive): same family dead-claim /
        # rejected-delivery channel — 分支体见 Invoke-ReclaimDerivationNode。
        $drInfo = Get-DesignReviewNodeInfo $bridge $NodeId
        if ($null -ne $drInfo) { return Invoke-ReclaimDesignReviewNode $runDir $bridge $NodeId }
        $derInfo = Find-DerivationByNode $bridge $NodeId
        if ($null -ne $derInfo) { return Invoke-ReclaimDerivationNode $runDir $bridge $NodeId $derInfo }
        Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2
    }
    $stage = [string]$mapping.stage
    $taskId = [int]$mapping.task_id

    # read-only state check: the recovery path depends on the node's status
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    $nodeStatus = [string]$node.status

    $res = $null
    if ($nodeStatus -eq "reported") {
        $res = Invoke-ReclaimRejectedDelivery $runDir $bridge $node $NodeId $taskId $stage
    }
    elseif ($nodeStatus -eq "pending") {
        Write-ErrorResult "RECLAIM_NOT_NEEDED" "Node $NodeId is pending (nobody claimed it) — a plain bridge claim is enough; reclaim recovers dead claims or rejected deliveries." 1
    }
    elseif ($nodeStatus -in @("done", "pruned")) {
        Write-ErrorResult "RECLAIM_NOT_POSSIBLE" "Node $NodeId is '$nodeStatus' — terminal; nothing to reclaim." 1
    }
    else {
        # claimed: the dead-claim recovery path
        $res = Invoke-ReclaimDeadClaim $runDir $bridge $node $NodeId $taskId $stage
    }
    # 编排裁定自动入账（统一决策账本，advisory）——reclaim 也是规划者裁定
    if ($null -ne $res -and $res.success) {
        $ruling = Add-OrchestrationRuling -ArchivePath ([string]$bridge.archive) -RunIdText $RunId -CommandName 'reclaim' -DecisionText "reclaim $($res.data.mode) applied to node $($res.data.node_id)$(if ($res.data.task_id) { " (task #$($res.data.task_id))" })" -ReasonText $(if ([string]::IsNullOrWhiteSpace($Reason)) { "dead claim / rejected delivery recovery" } else { $Reason }) -OptionsArr @('等（长任务纪律）', 'reclaim 回收')
        if ($ruling.warning) { $res.data['warnings'] = @(@(Convert-ToSafeArray $res.data['warnings']) + $ruling.warning) }
        elseif ($ruling.entry) { $res.data['decision_ledger'] = @{ entry_id = [string]$ruling.entry['entry_id'] } }
    }
    return $res
}

# === Command: rollback (cross-stage reverse transition, planner-stage-rollback) ===
#
# The third bridge channel beside settle (forward) and reclaim (same-stage redo):
# a reported node whose delivery FAILED the three-check gate is sent back to the
# PREVIOUS stage as ONE command — prune the failed node (the goal-tree ledger
# keeps the audit) -> sibling-graft a rebuilt previous-stage node (parent = the
# previous-stage node's parent, preserving the chain invariant and the tree
# depth across multi-round rollbacks) -> rdd-flow reopen (owners back to the
# target stage; Sync-TaskClaims drops the stale worker residue) -> auto re-push
# of the never-pushed rebuilt node. No manual state editing anywhere (hard
# constraint 2: forward transitions go through settle, reverse ones through
# rollback — the manual double-write door stays closed in both directions).
# Target-stage derivation is mechanical single-source: the failed node's
# parent's stage (the chain invariant encodes the previous stage); a chain head
# (parent = goal root / unmapped) has no previous stage -> ROLLBACK_NO_PREVIOUS_STAGE
# (use same-stage reclaim instead). The prune -> graft -> reopen -> dispatch
# order keeps "no two in-flight nodes for one task" true at every instant; the
# prune->graft crash window is covered by the signature-based idempotent resume
# guard (a rerun recognizes its own prune signature and continues at the graft
# step instead of pruning twice).
# Decomposition (QA function-size gate, qa-ast-review <= 40 effective lines):
# the command is an orchestrator over guard/step helpers — Test-RollbackTarget
# (explicit target validation), Get-RollbackContext (probe + status dispatch),
# Resolve-RollbackReportedPlan / Resolve-RollbackResumePlan (guards + plan),
# Invoke-RollbackPrune / Invoke-RollbackRebuild / Invoke-RollbackFlowSide
# (prune -> graft -> reopen+push), Get-RollbackDependents / New-Rollback-
# NextStep (report assembly). Behavior is identical to the pre-split single
# function (same codes/messages/order).

# Explicit rollback target validation (phase-model §6): -Phase + -To are
# planner input — enum check, role-set parse and the PhaseRoles whitelist all
# run BEFORE any pruning. Returns the parsed, deduplicated target role set.
function Test-RollbackTarget {
    param([string]$To, [string]$Phase)
    if ([string]::IsNullOrWhiteSpace($Phase)) {
        Write-ErrorResult "SET_PHASE_REQUIRED" "-Phase is required: rollback targets are explicit planner input (e.g. rollback -To 'CTO+UX' -Phase DESIGN). The old parent-derived single-stage guess no longer applies." 1
    }
    if (-not ($script:PhaseOrder -contains $Phase)) {
        Write-ErrorResult "PHASE_INVALID" "-Phase '$Phase' not in $($script:PhaseOrder -join '/')" 1
    }
    if ([string]::IsNullOrWhiteSpace($To)) {
        Write-ErrorResult "MISSING_TO" "-To is required (the rollback target role set, e.g. 'CTO+UX'); must be ⊆ PhaseRoles[$Phase]" 1
    }
    $targetRoles = @()
    foreach ($role in ($To -split '\+')) {
        $r = $role.Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if ($script:RoleOrder -notcontains $r) {
            Write-ErrorResult "PHASE_OWNER_MISMATCH" "-To role '$r' is not a bridgeable role (PM/CTO/UX/DEV/QA)" 1
        }
        if ((@($script:PhaseRoles[$Phase]) -notcontains $r)) {
            Write-ErrorResult "PHASE_OWNER_MISMATCH" "-To [$($To)] not ⊆ PhaseRoles[$Phase] = [$(@($script:PhaseRoles[$Phase]) -join '+')] (whitelist hard constraint)" 1
        }
        if ($targetRoles -notcontains $r) { $targetRoles += $r }
    }
    if ($targetRoles.Count -eq 0) {
        Write-ErrorResult "MISSING_TO" "-To '$To' parsed to an empty role set" 1
    }
    return @($targetRoles)
}

function Get-RollbackContext {
    # probe + guard dispatch shared by the whole rollback chain: mapping ->
    # leaf status -> archive task (same order as settle/reclaim) -> explicit
    # target validation (Test-RollbackTarget), then the node-status dispatch
    # resolves WHAT to roll back into the plan fields (problems / target_roles /
    # target_phase / reason / resume). The rollback TARGET is explicit planner
    # input (phase-model §6). Guards call Write-ErrorResult, which exits the
    # process — identical to the inline pre-split originals.
    param([string]$RunDir, $Bridge)
    $mapping = Get-NodeTaskStage $Bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $task = Find-ArchiveTask (Read-ArchiveTasks $Bridge.archive).tasks $mapping.task_id
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $($mapping.task_id) not found in $($Bridge.archive)" 2 }
    $targetRoles = Test-RollbackTarget $To $Phase

    $ctx = @{
        node = $leafStatus.json.data.node; task = $task
        task_id = $mapping.task_id; stage = $mapping.stage
        target_roles = @($targetRoles); target_phase = $Phase
        resume = $false; reason = $Reason; problems = @()
    }
    $nodeStatus = [string]$ctx.node.status
    if ($nodeStatus -eq "reported") {
        $plan = Resolve-RollbackReportedPlan $RunDir $Bridge $ctx.node $task
        $ctx.problems = $plan.problems
    }
    elseif ($nodeStatus -eq "pruned") {
        $plan = Resolve-RollbackResumePlan $RunDir $ctx.node
        $ctx.resume = $true
        $ctx.reason = $plan.reason; $ctx.problems = $plan.problems
    }
    elseif ($nodeStatus -in @("claimed", "pending")) {
        Write-ErrorResult "ROLLBACK_REQUIRES_REPORTED" "Node $NodeId is '$nodeStatus' — rollback only rolls back REPORTED nodes that failed the evidence gate. For a stuck/parked claim use reclaim (delivery-bridge -Command reclaim -RunId $RunId -NodeId $NodeId); for a pending node wait for its report." 1
    }
    else {
        Write-ErrorResult "ROLLBACK_REQUIRES_REPORTED" "Node $NodeId is '$nodeStatus' (terminal); nothing to roll back." 1
    }
    return $ctx
}

function Resolve-RollbackReportedPlan {
    # reported path: rollback only recovers failed deliveries — qualified ones
    # settle; the flow precheck before anything irreversible (same discipline as
    # settle) restricts rollback to ACTIVE bridged tasks. The rollback TARGET
    # comes from the explicit -To/-Phase args (validated in Get-RollbackContext);
    # no parent-derived stage remains, so rolling a chain head back to REQ is
    # now expressible.
    param([string]$RunDir, $Bridge, $Node, $Task)
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $Node -NodeId $NodeId -Bridge $Bridge -PreloadedTasks @($Task))
    if ($problems.Count -eq 0) {
        Write-ErrorResult "ROLLBACK_REQUIRES_UNQUALIFIED" "Node $NodeId is reported with QUALIFIED evidence — settle it instead (settle -RunId $RunId -NodeId $NodeId); rollback only rolls back unqualified deliveries." 1
    }
    if (([string]$Task.lifecycle) -ne "active") {
        Write-ErrorResult "TASK_NOT_ACTIVE" "TaskId $($Task.id) lifecycle is '$($Task.lifecycle)'; rollback only covers ACTIVE bridged tasks — post-completion rework stays on the plain rdd-flow reopen semantics (out of scope)." 1
    }
    return @{ problems = $problems }
}

function Resolve-RollbackResumePlan {
    # idempotent resume guard: a rollback prune that already happened (crash
    # or graft failure before this rerun) is recognized by the rollback
    # signature in the prune reason — the rerun continues at the graft step
    # (goal-tree would refuse a second prune with ALREADY_PRUNED anyway).
    # The original user reason + evidence problems are recovered from the
    # signature so the rebuilt node's redo context matches a fresh run. The
    # resume TARGET itself comes from the (mandatory) -To/-Phase args of the
    # rerun command. (The leaf status view omits pruned_reason — slim
    # serializer — so the reason falls back to the read-only state probe.)
    # Both signature generations parse: the phase-model "CTO+UX @ DESIGN"
    # form and the legacy single-stage "CTO (by …)" form.
    param([string]$RunDir, $Node)
    $pr = [string]$Node.pruned_reason
    if ([string]::IsNullOrWhiteSpace($pr)) { $pr = [string](Get-NodePruneReason $RunDir $NodeId) }
    if (-not ($pr -match '^cross-stage rollback to (?<target>[A-Z+]+)( @ (?<phase>REQ|DESIGN|IMPL|VERIFY))? ')) {
        Write-ErrorResult "ROLLBACK_REQUIRES_REPORTED" "Node $NodeId is pruned without a rollback signature; rollback only accepts reported nodes with unqualified evidence." 1
    }
    $reason = $Reason
    $problems = @()
    if ($pr -match '^cross-stage rollback to (?<target>[A-Z+]+)( @ (?<phase>REQ|DESIGN|IMPL|VERIFY))? \(by [^)]*\): (?<reason>.*?); evidence problems: (?<probs>.*)$') {
        $reason = [string]$Matches['reason']
        $problems = @([string]$Matches['probs'] -split '; ')
    }
    return @{ reason = $reason; problems = $problems }
}

function Invoke-RollbackPrune {
    # step 1: prune the failed delivery. A chain-tail leaf prunes without
    # cascade; the reason (user reason + operator + evidence problems) is
    # the ledger audit trail (acceptance 3), and the rollback signature it
    # starts with is what the resume guard recognizes (roles + phase in the
    # phase-model format; legacy runs left the bare single-stage form).
    param([string]$RunDir, $Ctx, [string]$Holder)
    $auditReason = "cross-stage rollback to $(@($Ctx.target_roles) -join '+') @ $($Ctx.target_phase) (by $Holder): $($Ctx.reason); evidence problems: $(@($Ctx.problems) -join '; ')"
    $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", $RunId, "-NodeId", $NodeId, "-Reason", $auditReason)
    if ($rp.exit -ne 0 -or $null -eq $rp.json -or -not $rp.json.success) {
        Write-ErrorResult "ROLLBACK_PRUNE_FAILED" "prune of the failed delivery failed (nothing rolled back): $($rp.text)" 1
    }
}

function Get-NodeParentSafe {
    # rollback ancestor-walk primitive: a node's parent via leaf status, with
    # every failure mode (non-zero exit, bad json, missing node) degrading to
    # '' — walking past a missing/unreadable node must stop the walk, never
    # abort the rollback. Shared by the anchor probe and the upward walk.
    param([string]$RunId, [string]$ProbeId)
    $ps = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $ProbeId)
    if ($ps.exit -ne 0 -or $null -eq $ps.json -or -not $ps.json.success -or $null -eq $ps.json.data.node) { return "" }
    return [string]$ps.json.data.node.parent
}

function Resolve-RollbackGraftParent {
    # phase-model sibling anchor: walk up from the failed node's parent through
    # same-task ancestors; the FIRST ancestor whose role sits in the TARGET
    # phase's whitelist marks where that phase's nodes originally hung — graft
    # the rebuilt group under ITS parent (sibling attach back to the chain-head
    # layer). No such ancestor (e.g. rollback to REQ on a DESIGN-started task)
    # -> the goal root: the rebuilt heads belong to the head layer by the
    # promulgate invariant. QA matches both DESIGN and VERIFY whitelists, so a
    # QA-design ancestor anchors a DESIGN rollback exactly like CTO/UX do.
    # This preserves the legacy single-stage grandparent rule byte-for-byte
    # (one-phase rollback always finds the parent's own phase at depth 1).
    param([string]$RunDir, $Bridge, $Ctx)
    $goalRoot = [string]$Bridge.goal_root
    if ([string]::IsNullOrWhiteSpace($goalRoot)) { $goalRoot = "n1" }
    $probe = [string]$Ctx.node.parent
    for ($i = 0; $i -lt 12 -and -not [string]::IsNullOrWhiteSpace($probe); $i++) {
        $m = Get-NodeTaskStage $Bridge $probe
        $isSameTask = ($null -ne $m -and [int]$m.task_id -eq [int]$Ctx.task_id)
        $isPhaseAnchor = ($isSameTask -and @($script:PhaseRoles[$Ctx.target_phase]) -contains $m.stage)
        if ($isPhaseAnchor) {
            $anchorParent = Get-NodeParentSafe $RunId $probe
            if (-not [string]::IsNullOrWhiteSpace($anchorParent)) { return $anchorParent }
            break
        }
        $parent = Get-NodeParentSafe $RunId $probe
        if ([string]::IsNullOrWhiteSpace($parent)) { break }
        $probe = $parent
    }
    return $goalRoot
}

function Find-RollbackExistingGraft {
    # resume path: an in-flight successor for (task, target stage) already
    # exists when the graft step had completed before the interruption —
    # adopt it instead of grafting a second rebuilt node.
    param($Bridge, $TaskId, $TargetStage)
    $existing = $null
    if ($Bridge.tasks.Contains("$TaskId")) {
        $bTask = $Bridge.tasks["$TaskId"]
        if ($bTask.Contains('stages') -and $null -ne $bTask['stages'] -and $bTask['stages'].Contains($TargetStage)) {
            $existing = [string]$bTask['stages'][$TargetStage]
        }
    }
    if ($null -eq $existing) { return $null }
    $exNode = Get-NodeFromTree (Get-TreeStatusView $RunId) $existing
    $exStatus = if ($exNode) { [string]$exNode.status } else { "missing" }
    if ($exStatus -in @("pending", "claimed", "reported")) { return $existing }
    return $null
}

function Invoke-RollbackRebuild {
    # step 2: sibling-graft ONE rebuilt node per -To role (parallel group
    # rebuilds in one command — acceptance: rollback -To "CTO+UX" -Phase
    # DESIGN re-creates BOTH heads), resume-aware per role: a rerun whose
    # graft step already landed adopts the in-flight successor.
    param([string]$RunDir, $Bridge, $Ctx)
    $graftParent = Resolve-RollbackGraftParent $RunDir $Bridge $Ctx
    $redo = @{ from_stage = $Ctx.stage; reason = $Ctx.reason; problems = $Ctx.problems }
    $rebuiltNodes = @()
    foreach ($role in @($Ctx.target_roles)) {
        $rebuiltNode = $null
        if ($Ctx.resume) { $rebuiltNode = Find-RollbackExistingGraft $Bridge $Ctx.task_id $role }
        if ($null -ne $rebuiltNode) { $rebuiltNodes += $rebuiltNode; continue }
        $g = Invoke-GraftNextStage $RunDir $Bridge $Ctx.task $graftParent $role -RedoContext $redo
        if (-not $g.success) {
            Write-ErrorResult "ROLLBACK_GRAFT_FAILED" "rebuilt $role node graft failed after prune (task $($Ctx.task_id) partially rebuilt: [$($rebuiltNodes -join '+')]; the prune already happened). RERUN THE SAME COMMAND — the rollback signature in the prune reason makes the rerun resume at the graft step without pruning twice. Error: $($g.error)" 1
        }
        $Bridge = $g.bridge
        $rebuiltNodes += $g.node_id
    }
    return @{ bridge = $Bridge; node_ids = @($rebuiltNodes); node_id = @($rebuiltNodes)[0] }
}

function Invoke-RollbackFlowSide {
    # steps 3+4: flow side — set-route with the explicit -To/-Phase routes the
    # task back atomically (owners + phase whitelist rewrite + Sync-TaskClaims
    # drops the failed stage's worker residue); then the auto re-push reaches
    # the never-pushed rebuilt nodes. A set-route half-failure lands in
    # pending_sync (set-route op + phase) which every status touch retries;
    # the push is deferred until the repair succeeds (a worker pushed while
    # owners are stale would hit ROLE_NOT_OWNER on its very first claim).
    # Also warns when the task still carries LIVE nodes outside the rebuilt
    # role set (parallel leftovers from the pre-rollback phase).
    param([string]$RunDir, $Bridge, $Ctx)
    $warnings = @()
    $toJoined = @($Ctx.target_roles) -join '+'
    # dev-quality-prescan-gate: a rollback that moves a failed DEV delivery off
    # the task puts DEV in set-route's exit set — the chain-side gate demands a
    # credential, and the failing credential is often exactly why we are here.
    # Planner disposal is honestly declared via the skip form (trusted chain-side
    # by design); the rebuilt upstream chain faces the full gate on ITS completion.
    $scanFile = Write-RollbackScanSkipFile $RunDir
    $r3 = Invoke-RddFlow @("-Command", "set-route", "-TaskId", "$($Ctx.task_id)", "-To", $toJoined, "-Phase", [string]$Ctx.target_phase, "-Archive", $Bridge.archive, "-QualityScanFile", $scanFile)
    $routeFailed = ($r3.exit -ne 0 -or $null -eq $r3.json -or -not $r3.json.success)
    if ($routeFailed) {
        $warnings += "flow set-route failed after prune/graft — recorded as pending_sync (every status touch retries the repair, then the catch-up push fires): $($r3.text)"
        $Bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $Ctx.stage $toJoined ($r3.text) -PhaseArg ([string]$Ctx.target_phase) -ScanEvidence $scanFile
    }
    else {
        foreach ($role in @($script:RoleOrder)) {
            if (@($Ctx.target_roles) -contains $role) { continue }
            $live = Get-LiveStageNode -RunId $RunId -Bridge $Bridge -TaskId ([int]$Ctx.task_id) -Role $role
            if ($null -ne $live) {
                $warnings += "task $($Ctx.task_id) still has a live $role node ($live) outside the rollback target [$toJoined] — reclaim it if that work is now obsolete, or let it report/settle"
            }
        }
    }
    $push = @{ trigger = "rollback"; considered = 0; pushed = @(); skipped = @(); failed = @() }
    if (-not $routeFailed) {
        # rollback-triggered rebuilds never reuse (inplace-redo v1 boundary:
        # cross-stage rollback keeps rebuild semantics — fresh sessions)
        $push = Invoke-AutoDispatch $RunDir $Bridge "rollback" $false
        $Bridge = $push.bridge
        foreach ($f in @($push.failed)) {
            $warnings += "auto-push failed for node $($f.node) (retry_class=$($f.retry_class)): session-create class auto-retries on the next trigger; pointer class needs manual dispatch. $($f.error)"
        }
    }
    return @{ bridge = $Bridge; route_failed = $routeFailed; push = $push; warnings = @($warnings) }
}

function Get-RollbackDependents {
    # dependents warning (warn-only, direct edges): other tasks' nodes that
    # depend on the pruned node keep their dep edge untouched (acceptance 4);
    # a pruned dep target discharges the obligation, so such dependents may
    # have been unblocked/pushed against a delivery now being redone —
    # surface them (push ledger derived). Direct edges only; the transitive
    # closure stays inspectable via goal-tree deps list (protocol v1 limit).
    param($Bridge, [string]$TheNodeId)
    $dependents = @()
    foreach ($e in @(Convert-ToSafeArray (Get-TreeStatusView $RunId).dependencies.edges)) {
        $eNode = [string]$e.node
        if ($eNode -eq $TheNodeId) { continue }
        if ([string]$e.status -eq "pruned") { continue }
        $hit = $false
        foreach ($t in @(Convert-ToSafeArray $e.depends_on)) {
            if ([string]$t.target -eq $TheNodeId) { $hit = $true }
        }
        if (-not $hit) { continue }
        $m = Get-NodeTaskStage $Bridge $eNode
        $ps2 = Get-NodePushState $Bridge $eNode
        $pushedOk = ($null -ne $ps2 -and $ps2.Contains('last_ok_at') -and $null -ne $ps2['last_ok_at'])
        $dependents += @{
            node    = $eNode
            task_id = $(if ($m) { $m.task_id } else { $null })
            stage   = $(if ($m) { $m.stage } else { $null })
            pushed  = $pushedOk
            note    = "depends on the pruned node $TheNodeId — dep edge untouched (prune discharges it); verify this dependent against the redone delivery"
        }
    }
    return @($dependents)
}

function New-RollbackNextStep {
    # next_step assembly over the flow-side outcome (set-route repair / push
    # repair / pushed / awaits push) + the dependents count hint.
    param($Flow, [string]$RebuiltNode, [string]$TargetJoined, [int]$DependentCount)
    $nextStep = ""
    if ($Flow.route_failed) {
        $nextStep = "set-route recorded as pending_sync — run status -RunId $RunId (the touch retries the repair, then the catch-up push picks up node $RebuiltNode)"
    }
    elseif (@($Flow.push.failed).Count -gt 0) {
        $nextStep = "repair failed pushes: session-create class auto-retries via status; pointer class → dispatch -NodeId <id> manually"
    }
    elseif (@($Flow.push.pushed) -contains $RebuiltNode) {
        $nextStep = "rebuilt [$TargetJoined] node $RebuiltNode auto-pushed — its worker session re-claims with -Role <role> and redoes the work against the redo context in node.task"
    }
    else {
        $nextStep = "rebuilt node $RebuiltNode awaits push — status touch or dispatch -NodeId $RebuiltNode"
    }
    if ($DependentCount -gt 0) { $nextStep += "; dependents_warning lists $DependentCount direct dependent(s) to verify" }
    return $nextStep
}

function Invoke-BridgeRollback {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Reason)) { Write-ErrorResult "MISSING_REASON" "-Reason is required (rollback audit trail)" 1 }

    $lease = Enter-PlannerLease $runDir
    $ctx = Get-RollbackContext $runDir $bridge
    if (-not $ctx.resume) { Invoke-RollbackPrune $runDir $ctx $lease.holder }

    $rebuild = Invoke-RollbackRebuild $runDir $bridge $ctx
    $bridge = $rebuild.bridge

    # plan recovery tail (long-task-planning) BEFORE the flow-side auto-push:
    # deviation record + acceptance invalidation wave over the touched stage.
    Write-PlanRecoveryTail $runDir $bridge 'rollback' $NodeId ([int]$ctx.task_id) "cross-stage rollback to $(@($ctx.target_roles) -join '+') ($(if ($ctx.resume) { 'resume' } else { 'prune+rebuild' })): $($ctx.reason)"

    $flow = Invoke-RollbackFlowSide $runDir $bridge $ctx
    $bridge = $flow.bridge

    $dependents = @(Get-RollbackDependents $bridge $NodeId)
    $targetJoined = @($ctx.target_roles) -join '+'
    $nextStep = New-RollbackNextStep $flow $rebuild.node_id $targetJoined @($dependents).Count
    # 编排裁定自动入账（统一决策账本，advisory）
    $ruling = Add-OrchestrationRuling -ArchivePath ([string]$bridge.archive) -RunIdText $RunId -CommandName 'rollback' -DecisionText "rollback node $NodeId -> [$targetJoined]@$([string]$ctx.target_phase)（task #$($ctx.task_id)）" -ReasonText ([string]$ctx.reason) -OptionsArr @('settle 前进', 'reclaim 同阶段重做', 'rollback 跨阶段回退')

    $res = @{
        success = $true
        data    = @{
            run_id             = $RunId
            pruned_node        = $NodeId
            rebuilt_node       = $rebuild.node_id
            rebuilt_nodes      = @($rebuild.node_ids)
            task_id            = $ctx.task_id
            from_stage         = $ctx.stage
            to_stage           = $targetJoined
            to_phase           = [string]$ctx.target_phase
            resumed            = $ctx.resume
            reason             = $ctx.reason
            auto_push          = @{ trigger = $flow.push.trigger; pushed = @($flow.push.pushed); failed = @($flow.push.failed); skipped = @($flow.push.skipped | ForEach-Object { "$($_.node):$($_.reason)" }) }
            dependents_warning = @($dependents)
            warnings           = @($flow.warnings)
            next_step          = $nextStep
        }
    }
    if ($ruling.warning) { $res.data['warnings'] = @(@($flow.warnings) + $ruling.warning) }
    elseif ($ruling.entry) { $res.data['decision_ledger'] = @{ entry_id = [string]$ruling.entry['entry_id'] } }
    return $res
}

# === Role handoff gate (unified gate at BOTH handoff points) ===
# dev-quality-prescan-gate: quality self-scan discipline upgraded to a mechanical
# handoff gate. The gate is FIXED and runs unconditionally at every handoff
# point; WHICH roles actually get validated is registry dispatch (polymorphic):
#   bridge scenario (delivery-bridge.ps1, Test-SettleEvidence 4th check)
#     role source = mapped task's currentOwners (tree-level node -> node.role)
#   chain scenario (rdd-flow.ps1 set-route, before any write)
#     role source = exit-role set (currentOwners - To)
# An unregistered role is a no-op pass. A new role gate = a new validator
# function + one registry line; the gate and the dispatcher never change.
# ⚠ verbatim-synced copy — the SAME block lives in BOTH rdd-flow.ps1 and
# delivery-bridge.ps1; changes go to BOTH, verbatim (engine copy discipline,
# PhaseRoles precedent). tests/test-handoff-gate.ps1 locks the two copies
# identical (conformance extraction anchor: from this `# === Role handoff gate`
# marker line through the line before the next `# === `/`# --- ` section marker).

function Get-GateField {
    # credential field accessor tolerant of both hashtable and PSCustomObject
    # shapes (chain side parses JSON -> PSCustomObject; the bridge side may
    # carry either, depending on how the callback reached the ledger)
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function ConvertTo-NormalizedScanPath {
    # R6 normalization: repo-root-relative + POSIX separators + case-insensitive
    param([string]$Path)
    $p = [string]$Path
    if ($null -eq $p) { return "" }
    $p = ($p -replace '\\', '/').Trim()
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.ToLowerInvariant()
}

function Test-DevQualityScanSkipForm {
    # skip-form rules: the reason must be non-empty, and (bridge scenario) the
    # cited .ps1 set must be empty — a PowerShell change set cannot skip.
    param($Qs, [string[]]$Ps1Citations)
    $problems = @()
    $reason = [string](Get-GateField $Qs 'reason')
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $problems += "quality_scan: skip form requires a non-empty reason (why no code-metrics scan applies to this change set)"
    }
    if ($Ps1Citations.Count -gt 0) {
        $problems += "quality_scan: skip contradicts the change list — citations contain PowerShell files ($($Ps1Citations -join ', ')); a PowerShell change set requires the full code-metrics credential, not skip"
    }
    return $problems
}

function Test-DevQualityScanFullForm {
    # full-form rules — structure (R2), counts (R3), exit-code agreement (R4)
    # and bridge coverage (R6). Returns problem strings.
    param($Qs, [string[]]$Ps1Citations)
    $problems = @()
    $missing = @()
    foreach ($f in @('tool', 'base', 'files', 'thresholds', 'threshold_source', 'violation_count', 'exit_code')) {
        if ($null -eq (Get-GateField $Qs $f)) { $missing += $f }
    }
    if ($missing.Count -gt 0) {
        return @("quality_scan: full form is missing required fields: $($missing -join ', ')")
    }
    foreach ($f in @('tool', 'base', 'threshold_source')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-GateField $Qs $f))) {
            $problems += "quality_scan: field '$f' must be a non-empty string"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-GateField $Qs 'thresholds'))) {
        $problems += "quality_scan: field 'thresholds' must carry the effective limits (e.g. the scan report header's limits line)"
    }
    $files = @(Get-GateField $Qs 'files')
    if ($files.Count -eq 1 -and $files[0] -is [string] -and $files[0].IndexOfAny(@(',', ';')) -ge 0) {
        # tolerate the comma/semicolon-separated spelling (code-metrics -Files CLI form)
        $files = @($files[0] -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    foreach ($fe in $files) {
        if ($fe -isnot [string] -or [string]::IsNullOrWhiteSpace($fe)) {
            $problems += "quality_scan: 'files' entries must be non-empty strings"
            break
        }
    }
    $problems += @(Test-DevQualityScanCounts $Qs)
    # R6 — bridge coverage: every cited .ps1 must sit inside the scanned set
    if ($Ps1Citations.Count -gt 0) {
        $norm = @{}
        foreach ($fe in $files) { $norm[(ConvertTo-NormalizedScanPath ([string]$fe))] = $true }
        foreach ($ref in $Ps1Citations) {
            if (-not $norm.ContainsKey((ConvertTo-NormalizedScanPath $ref))) {
                $problems += "quality_scan: coverage gap — citation '$ref' (.ps1) is not inside the scanned files set; rescan with -Files covering every cited PowerShell file"
            }
        }
    }
    return $problems
}

function Test-DevQualityScanCounts {
    # R3 + R4 — counts and exit code (integer-typed: JSON numbers, not strings)
    param($Qs)
    $problems = @()
    $count = Get-GateField $Qs 'violation_count'
    $code = Get-GateField $Qs 'exit_code'
    $countIsInt = ($count -is [int] -or $count -is [long])
    $codeIsInt = ($code -is [int] -or $code -is [long])
    if (-not $countIsInt) {
        $problems += "quality_scan: violation_count must be a non-negative integer (got '$count')"
    }
    elseif ([int]$count -ne 0) {
        $problems += "quality_scan: violation_count is $count (must be 0) — fix the code-metrics violations (#1 parse / #4 function lines / #5 nesting depth) and rescan"
    }
    if (-not $codeIsInt) {
        $problems += "quality_scan: exit_code must be an integer (got '$code')"
    }
    elseif ($countIsInt -and (([int]$code -eq 0) -ne ([int]$count -eq 0))) {
        $problems += "quality_scan: exit_code $code contradicts violation_count $count (code-metrics exits 0 iff zero violations)"
    }
    return $problems
}

function Test-DevQualityScan {
    # DEV validator (dev-quality-prescan-gate): the code-metrics self-scan
    # discipline as a mechanical gate. Credential contract — extras.quality_scan
    # (bridge scenario) / -QualityScanFile JSON (chain scenario), one schema:
    #   full form : tool / tool_hash? / base / files / thresholds /
    #               threshold_source / violation_count / exit_code / report_ref?
    #   skip form : skip=true + reason (no applicable language in the change set)
    # Deterministic rules:
    #   R1 credential absent                                    -> reject
    #   R2 full form missing/invalid required fields            -> reject
    #   R3 violation_count not a non-negative integer, or != 0  -> reject
    #   R4 exit_code contradicts violation_count                -> reject
    #   R5 bridge: citations contain .ps1 but skip declared     -> reject
    #   R6 bridge: citations' .ps1 set not covered by files     -> reject
    # (the chain scenario has no reconciliation source for R5/R6 — the skip
    # declaration is trusted there and QA's re-scan is the safety net)
    # Returns an array of problem strings (empty = pass), each prefixed
    # "quality_scan:" so both scenario surfaces aggregate them uniformly.
    param($GatePayload)
    $qs = $GatePayload.quality_scan
    if ($null -eq $qs) {
        # R1 — credential absent
        return @("quality_scan: credential absent — run code-metrics.cmd -Command scan on the PowerShell change set and report the full credential, or skip+reason when no PowerShell file changed")
    }
    $skip = Get-GateField $qs 'skip'
    $isSkip = ($skip -is [bool] -and $skip)
    $ps1Cits = @()
    if ($GatePayload.scenario -eq 'bridge') {
        foreach ($c in @($GatePayload.citations)) {
            if ($null -eq $c) { continue }
            $ref = [string](Get-GateField $c 'ref')
            if (-not [string]::IsNullOrWhiteSpace($ref) -and $ref -match '\.ps1$') { $ps1Cits += $ref }
        }
    }
    if ($isSkip) { return @(Test-DevQualityScanSkipForm $qs $ps1Cits) }
    return @(Test-DevQualityScanFullForm $qs $ps1Cits)
}

$script:RoleHandoffValidators = @{
    "DEV" = ${function:Test-DevQualityScan}
}

function Invoke-RoleHandoffGate {
    # FIXED gate: runs unconditionally at every handoff point; a per-role
    # registry lookup decides what actually validates (polymorphic dispatch —
    # an unregistered role passes silently). $Roles is the scenario's role
    # source (bridge: mapped task currentOwners / tree node.role; chain:
    # exit-role set currentOwners - To). Returns an array of problem strings
    # (empty = pass).
    param([string[]]$Roles, $GatePayload)
    $problems = @()
    foreach ($role in @($Roles)) {
        if ($null -eq $role -or [string]::IsNullOrWhiteSpace([string]$role)) { continue }
        $validator = $script:RoleHandoffValidators[[string]$role]
        if ($null -eq $validator) { continue }
        $problems += @(& $validator $GatePayload)
    }
    return $problems
}

# === Settle evidence gate (shared by settle, reclaim and rollback) ===

function Get-SettleGateRoles {
    # Role source for the settle handoff gate (dev-quality-prescan-gate):
    # bridge-mapped node -> the task's live currentOwners (the routing truth);
    # tree-level node -> node.role. Empty array when undeterminable — the gate
    # then no-ops (same as an unregistered role). $PreloadedTasks skips the
    # rdd-flow show subprocess when the caller already holds the archive task
    # list (e.g. the status view probes every reported node).
    param($Bridge, $Node, [string]$NodeIdText, $PreloadedTasks = $null)
    if ($null -ne $Bridge) {
        $mapping = Get-NodeTaskStage $Bridge $NodeIdText
        if ($null -ne $mapping) {
            $tasks = $PreloadedTasks
            if ($null -eq $tasks) {
                $flow = Read-ArchiveTasks $Bridge.archive
                $tasks = $flow.tasks
            }
            $task = Find-ArchiveTask $tasks ([int]$mapping.task_id)
            if ($null -ne $task -and $null -ne $task.currentOwners) { return @($task.currentOwners) }
            return @()
        }
    }
    $r = [string]$Node.role
    if (-not [string]::IsNullOrWhiteSpace($r)) { return @($r.ToUpper()) }
    return @()
}

# design-review settle gate registration (auditor-design-stage-review): the
# AUDITOR validator joins the registry OUTSIDE the verbatim-synced gate block
# above (this sits past the `# === Settle evidence gate` section marker) —
# rdd-flow.ps1 never dispatches it (AUDITOR is not a task.json route role; the
# chain scenario has no bridge context to read the DesignReviewFile from), so
# the two synced copies stay byte-identical. Bridge-scenario GatePayload form:
# { scenario; run_id; node_id }.
$script:RoleHandoffValidators["AUDITOR"] = ${function:Test-DesignReviewFile}

function Write-QualityScanTempFile {
    # Materialize the accepted callback's quality_scan credential as a temp
    # JSON file for flow-tail set-route calls (dev-quality-prescan-gate): the
    # chain-side gate re-validates it independently — the same registry, the
    # same rules, no caller trust. Returns $null when no accepted callback /
    # no credential (the flow tail then omits the flag and the gate judges
    # from what it can see).
    param([string]$RunDir, $Node)
    $cb = Find-AcceptedCallback $RunDir $Node
    if ($null -eq $cb) { return $null }
    $qs = $null
    if ((Test-PropPresent $cb.callback 'extras') -and $null -ne $cb.callback.extras -and (Test-PropPresent $cb.callback.extras 'quality_scan')) {
        $qs = $cb.callback.extras.quality_scan
    }
    if ($null -eq $qs) { return $null }
    $path = Join-Path (Join-Path $RunDir 'state') ('quality-scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    ConvertTo-PortableJson $qs -Depth 8 | Out-File -FilePath $path -Encoding utf8
    return $path
}

function Write-RollbackScanSkipFile {
    # Cross-stage rollback disposal credential (dev-quality-prescan-gate): the
    # rollback tail's set-route moves a FAILED DEV delivery off the task — that
    # is planner disposal, not a DEV completion handoff, and the failing
    # credential is often exactly why the rollback happens (the gate would
    # deadlock its own disposal channel otherwise). The chain-side skip form
    # is a trusted declaration by design (no reconciliation source there), so
    # the engine states the disposal honestly and the gate passes it. The
    # rebuilt upstream chain faces the full gate again on ITS completion.
    # -ReasonText: the design-review fail wave (auditor-design-stage-review)
    # reuses this disposal channel with its own honest wording.
    param([string]$RunDir, [string]$ReasonText = 'cross-stage rollback disposal: recycling a failed delivery (delivery-bridge rollback); not a DEV completion handoff')
    $path = Join-Path (Join-Path $RunDir 'state') ('quality-scan-rollback-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $skip = @{ skip = $true; reason = $ReasonText }
    ConvertTo-PortableJson $skip -Depth 3 | Out-File -FilePath $path -Encoding utf8
    return $path
}

function Test-SettleEvidence {
    # The FOUR checks gating any task.json transition (hard constraint:
    # unqualified delivery never transitions):
    #   1. verdict=done (worker self-assessment complete)
    #   2. citations = change list, non-empty and every ref a real path
    #   3. extras.verification non-empty (the verification result)
    #   4. role handoff gate (registry dispatch; DEV -> quality_scan credential,
    #      dev-quality-prescan-gate) — problems join the same rejection channel
    # Returns an array of problem strings (empty = qualified).
    param([string]$RunDir, $Node, [string]$NodeId, $Bridge = $null, $PreloadedTasks = $null)
    $problems = @()
    if ([string]$Node.last_verdict -ne "done") {
        $problems += "verdict check: last_verdict is '$($Node.last_verdict)', expected 'done' (worker self-assessment incomplete)"
    }
    $cb = Find-AcceptedCallback $RunDir $Node
    if ($null -eq $cb) {
        $problems += "evidence check: no accepted ledger entry found for node $NodeId"
    }
    else {
        $cits = @(Convert-ToSafeArray $cb.callback.citations)
        if ($cits.Count -eq 0) {
            $problems += "change-list check: accepted callback has no citations (change list must be non-empty)"
        }
        else {
            foreach ($c in $cits) {
                $ref = [string]$c.ref
                $abs = Join-Path $repoRoot ($ref -replace '/', '\')
                if (-not (Test-Path -LiteralPath $abs)) {
                    $problems += "change-list check: citation ref does not exist on disk: $ref"
                }
            }
        }
        $verif = $null
        if ((Test-PropPresent $cb.callback 'extras') -and $null -ne $cb.callback.extras -and (Test-PropPresent $cb.callback.extras 'verification')) {
            $verif = $cb.callback.extras.verification
        }
        if ($null -eq $verif -or [string]::IsNullOrWhiteSpace([string]$verif)) {
            $problems += "verification check: callback extras.verification is absent/empty (worker must report the verification result)"
        }
        # 4th check: unified role handoff gate. Role source: bridge-mapped ->
        # the task's currentOwners; tree-level -> node.role. Without $Bridge
        # (a legacy direct caller) the role set is empty and the gate no-ops.
        $gateRoles = @(Get-SettleGateRoles -Bridge $Bridge -Node $Node -NodeIdText $NodeId -PreloadedTasks $PreloadedTasks)
        if ($gateRoles.Count -gt 0) {
            $qs = $null
            if ((Test-PropPresent $cb.callback 'extras') -and $null -ne $cb.callback.extras -and (Test-PropPresent $cb.callback.extras 'quality_scan')) {
                $qs = $cb.callback.extras.quality_scan
            }
            $problems += @(Invoke-RoleHandoffGate -Roles $gateRoles -GatePayload @{ scenario = 'bridge'; run_id = $RunId; node_id = $NodeId; quality_scan = $qs; citations = $cits })
        }
    }
    return $problems
}

# === Command: settle (the ONLY task.json transition channel) ===

function Invoke-FlowCompleteTail {
    # terminal flow tail shared by the legacy and phase settle tails: complete
    # the task in flow, with pending_sync fallback when the call fails after
    # the already-irreversible tree settle. Returns @{ bridge; warnings }.
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$Stage)
    $taskId = [int]$Task.id
    $r2 = Invoke-RddFlow @("-Command", "complete", "-TaskId", "$taskId", "-Archive", $Bridge.archive)
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        return @{ bridge = Add-PendingSync $RunDir $Bridge $NodeId "complete" $Stage $null ($r2.text); warnings = @("flow complete failed after tree settle — recorded as pending_sync: $($r2.text)") }
    }
    return @{ bridge = $Bridge; warnings = @() }
}

function Get-LegacyHopPhase {
    # The advance-era bridge tail (and its pending_sync replays) routed through the
    # removed rdd-flow advance command; set-route needs an explicit -Phase only when
    # the hop target is phase-ambiguous (QA spans DESIGN/VERIFY — the legacy chain's
    # DEV->QA hop is acceptance, so VERIFY). Unambiguous targets keep phase=null
    # (byte-identical legacy semantics; migrate is the designated filler).
    param([string]$NextStage)
    $covers = @($script:PhaseOrder | Where-Object { @($script:PhaseRoles[$_]) -contains $NextStage })
    if ($covers.Count -gt 1) { return "VERIFY" }
    return $null
}

function Invoke-LegacySettleFlow {
    # LEGACY null-phase flow tail — byte-identical pre-phase-model behavior
    # (conservative degrade for old archives; new archives always carry phase):
    # terminal stage -> flow complete; otherwise set-route onto the single
    # next-stage graft (unambiguous target keeps phase=null; QA passes -Phase
    # VERIFY). Half-failures land in pending_sync. Returns the settle-tail shape
    # @{ bridge; warnings; graftedNext; graftedNextNodes; flowOperation; taskLifecycle }.
    # $NextStage stays untyped: a null (terminal stage) must survive binding as
    # null — a [string] cast would turn it into "" and flip the route/complete fork.
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$Stage, $NextStage, [string]$QualityScanFile = $null)
    $taskId = [int]$Task.id
    $res = @{ bridge = $Bridge; warnings = @(); graftedNext = $null; graftedNextNodes = @(); flowOperation = ""; taskLifecycle = "" }
    if ($null -ne $NextStage) {
        $routeArgs = @("-Command", "set-route", "-TaskId", "$taskId", "-To", $NextStage, "-Archive", $Bridge.archive)
        $hopPhase = Get-LegacyHopPhase $NextStage
        if ($null -ne $hopPhase) { $routeArgs += @("-Phase", $hopPhase) }
        if (-not [string]::IsNullOrWhiteSpace($QualityScanFile)) { $routeArgs += @("-QualityScanFile", $QualityScanFile) }
        $r2 = Invoke-RddFlow $routeArgs
        if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
            $res.warnings += "flow set-route failed after tree settle — recorded as pending_sync: $($r2.text)"
            $res.bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $Stage $NextStage ($r2.text) -PhaseArg $hopPhase -ScanEvidence $QualityScanFile
        }
        else {
            $g = Invoke-GraftNextStage $RunDir $Bridge $Task $NodeId $NextStage
            if ($g.success) {
                $res.bridge = $g.bridge
                $res.graftedNext = $g.node_id
            }
            else {
                $res.warnings += "next-stage graft failed (flow side already routed): $($g.error)"
            }
        }
    }
    else {
        $done = Invoke-FlowCompleteTail $RunDir $Bridge $Task $NodeId $Stage
        $res.bridge = $done.bridge
        $res.warnings += @($done.warnings)
    }
    $res.flowOperation = $(if ($null -eq $NextStage) { "complete" } else { "set-route ${Stage}->${NextStage}" })
    $res.taskLifecycle = $(if ($null -eq $NextStage) { "completed" } else { "active @ $NextStage" })
    return $res
}

function Invoke-PhaseSwitchSettle {
    # LAST settle of a non-terminal phase (phase-model.md §5.2): atomic
    # set-route onto PhaseRoles[PhaseNext[phase]] + convergence graft of the
    # next phase's heads. A failed switch lands in pending_sync WITH the target
    # phase — retrying it as a plain narrowing would drift the whitelist.
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$TaskPhase, [string]$NextPhase, [hashtable]$Res, [string]$QualityScanFile = $null)
    $taskId = [int]$Task.id
    $nextOwners = @($script:PhaseRoles[$NextPhase])
    $to = $nextOwners -join '+'
    $routeArgs = @("-Command", "set-route", "-TaskId", "$taskId", "-To", $to, "-Phase", $NextPhase, "-Archive", $Bridge.archive)
    # credential passthrough (dev-quality-prescan-gate): a DEV settle switches
    # IMPL->VERIFY with DEV in the exit set — the chain-side gate demands the
    # quality_scan credential; the settle-side 4th check already validated it.
    if (-not [string]::IsNullOrWhiteSpace($QualityScanFile)) { $routeArgs += @("-QualityScanFile", $QualityScanFile) }
    $r2 = Invoke-RddFlow $routeArgs
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        $Res.warnings += "flow set-route phase switch failed after tree settle — recorded as pending_sync: $($r2.text)"
        $Res.bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $TaskPhase $to ($r2.text) -PhaseArg $NextPhase -ScanEvidence $QualityScanFile
    }
    else {
        $ens = Invoke-EnsureStageNodes $RunDir $Bridge $Task $NodeId $nextOwners
        $Res.bridge = $ens.bridge
        $Res.graftedNextNodes = @($ens.grafted)
        foreach ($f in @($ens.failed)) {
            $Res.warnings += "next-phase graft failed for role $($f.role) (flow side already switched to $NextPhase): $($f.error)"
        }
    }
    $Res.flowOperation = "set-route ${TaskPhase}->${NextPhase} [$to]"
    $Res.taskLifecycle = "active @ $NextPhase"
    return $Res
}

function Invoke-PhaseSettleFlow {
    # PHASE MODE flow tail (phase-model.md §5.2): owners narrowing keeps the
    # phase and only fills MISSING live nodes (serial CTO->UX inside DESIGN);
    # the LAST settle of the phase switches atomically to
    # PhaseRoles[PhaseNext[phase]] and grafts the next phase's heads
    # (convergence — no per-branch fan-out, no tree split). Same return shape
    # as Invoke-LegacySettleFlow.
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$Stage, $Owners, [string]$TaskPhase, [string]$QualityScanFile = $null)
    $taskId = [int]$Task.id
    $owners = @($Owners)
    $res = @{ bridge = $Bridge; warnings = @(); graftedNext = $null; graftedNextNodes = @(); flowOperation = ""; taskLifecycle = "active @ $TaskPhase" }
    $remaining = @($owners | Where-Object { $_ -ne $Stage })
    if ($remaining.Count -gt 0) {
        $to = $remaining -join '+'
        $routeArgs = @("-Command", "set-route", "-TaskId", "$taskId", "-To", $to, "-Archive", $Bridge.archive)
        if (-not [string]::IsNullOrWhiteSpace($QualityScanFile)) { $routeArgs += @("-QualityScanFile", $QualityScanFile) }
        $r2 = Invoke-RddFlow $routeArgs
        if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
            $res.warnings += "flow set-route narrowing failed after tree settle — recorded as pending_sync: $($r2.text)"
            $res.bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $TaskPhase $to ($r2.text) -ScanEvidence $QualityScanFile
        }
        else {
            $ens = Invoke-EnsureStageNodes $RunDir $Bridge $Task $NodeId $remaining
            $res.bridge = $ens.bridge
            $res.graftedNextNodes = @($ens.grafted)
            foreach ($f in @($ens.failed)) {
                $res.warnings += "convergence graft failed for role $($f.role) (flow side already narrowed to [$to]): $($f.error)"
            }
        }
        $res.flowOperation = "set-route narrow [$($owners -join '+')] -> [$to] @ $TaskPhase"
        return $res
    }
    $nextPhase = $script:PhaseNext[$TaskPhase]
    if ($null -eq $nextPhase) {
        $done = Invoke-FlowCompleteTail $RunDir $Bridge $Task $NodeId $Stage
        $res.bridge = $done.bridge
        $res.warnings += @($done.warnings)
        $res.flowOperation = "complete"
        $res.taskLifecycle = "completed"
        return $res
    }
    return Invoke-PhaseSwitchSettle $RunDir $Bridge $Task $NodeId $TaskPhase $nextPhase $res -QualityScanFile $QualityScanFile
}

function Resolve-SettleTarget {
    # Resolve the settle target: bridge-mapped (task, stage) OR a tree-level node
    # (acceptance chain / in-tree repair node, no TaskId — the unified branch).
    # mid-run derivation PM node (planner-midrun-derive): probed BEFORE the
    # generic tree-level repair fallback — its settle runs the controlled
    # registration branch (add-task 代写 + chain-head pre-graft), not the plain
    # tree-only settle. Returns @{ stage; task_id; tree_level; acceptance;
    # next_stage; derivation }.
    param($Bridge, [string]$NodeIdText, [string]$RunDirText)
    $mapping = Get-NodeTaskStage $Bridge $NodeIdText
    if ($null -ne $mapping) {
        return @{ stage = [string]$mapping.stage; task_id = [int]$mapping.task_id; tree_level = $false; acceptance = $null; next_stage = $script:StageNext[[string]$mapping.stage]; derivation = $null }
    }
    $der = Find-DerivationByNode $Bridge $NodeIdText
    if ($null -ne $der) {
        return @{ stage = 'PM'; task_id = 0; tree_level = $true; acceptance = $null; next_stage = $null; derivation = $der }
    }
    $info = Get-TreeLevelInfo $Bridge $RunDirText $NodeIdText
    if ($null -eq $info) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeIdText is not in this run's bridge mapping" 2 }
    return @{ stage = [string]$info.role; task_id = 0; tree_level = $true; acceptance = $info; next_stage = $null; derivation = $null }
}

function Test-SettleDelivery {
    # state precheck (node must be reported) + the four evidence checks —
    # identical gate for mapped and tree-level nodes (unqualified delivery never
    # transitions). Returns the node for the transition step.
    param([string]$RunDir, [string]$NodeIdText, [bool]$TreeLevel = $false, $Bridge = $null)
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeIdText)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    if ($node.status -ne "reported") {
        Write-ErrorResult "SETTLE_REQUIRES_REPORTED" "Node $NodeIdText is '$($node.status)'; settle only accepts reported nodes (claim -> work -> leaf report first)." 1
    }
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $node -NodeId $NodeIdText -Bridge $Bridge)
    if ($problems.Count -gt 0) {
        $disp = "Disposition: reclaim the node (delivery-bridge -Command reclaim -RunId $RunId -NodeId $NodeIdText), have the worker fix the delivery, then report again; or re-dispatch."
        if ($TreeLevel) {
            $disp = "Disposition: tree-level node (no task.json flow) — recycling it is out of this round's scope (overall-delivery boundary); ask the Planner for intervention (the run cannot conclude until a qualified delivery settles)."
        }
        Write-ErrorResult "SETTLE_EVIDENCE_REJECTED" "Unqualified delivery — nothing transitioned. $disp Problems: $($problems -join '; ')" 1
    }
    return $node
}

function Test-SettleFlowReady {
    # flow-side prechecks (avoid the settle->set-route half-failure window):
    # task exists + active + owner membership. Returns @{ task; task_phase; owners }.
    param($Bridge, $Target)
    $taskId = [int]$Target.task_id
    $flow = Read-ArchiveTasks $Bridge.archive
    $task = Find-ArchiveTask $flow.tasks $taskId
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $taskId not found in $($Bridge.archive)" 2 }
    if (([string]$task.lifecycle) -ne "active") {
        Write-ErrorResult "TASK_NOT_ACTIVE" "TaskId $taskId lifecycle is '$($task.lifecycle)'; nothing to advance." 1
    }
    $owners = @()
    if ($null -ne $task.currentOwners) { $owners = @($task.currentOwners) }
    # phase-model: a stored phase routes through set-route (every phase-mode settle
    # writes flow state), so the owner membership precheck applies unconditionally;
    # legacy null-phase keeps the old nextStage-gated precheck byte-for-byte.
    $taskPhase = $null
    if ($null -ne $task.phase -and ([string]$task.phase) -ne "") { $taskPhase = [string]$task.phase }
    if ($null -ne $taskPhase) {
        if ($script:PhaseOrder -notcontains $taskPhase) {
            Write-ErrorResult "PHASE_INVALID" "TaskId $taskId carries phase '$taskPhase' not in $($script:PhaseOrder -join '/') — fix task.json (rdd-flow check) before settling" 1
        }
        if ($owners -notcontains $Target.stage) {
            Write-ErrorResult "FLOW_SETROUTE_WOULD_FAIL" "Precheck: '$($Target.stage)' is not in currentOwners of TaskId $taskId ([$($owners -join '+')]) — the phase-side set-route would mis-narrow. Fix routing or use rdd-flow set-route first." 1
        }
    }
    elseif ($null -ne $Target.next_stage) {
        if ($owners -notcontains $Target.stage) {
            Write-ErrorResult "FLOW_SETROUTE_WOULD_FAIL" "Precheck: '$($Target.stage)' is not in currentOwners of TaskId $taskId ([$($owners -join '+')]) — the set-route would mis-replace. Fix routing or use rdd-flow set-route first." 1
        }
    }
    return @{ task = $task; task_phase = $taskPhase; owners = $owners }
}

function Invoke-TreeSettleWrite {
    # the irreversible tree settle (shared by the mapped and tree-level tails).
    param([string]$NodeIdText)
    $settleArgs = @("-Command", "settle", "-RunId", $RunId, "-NodeId", $NodeIdText)
    if (-not [string]::IsNullOrWhiteSpace($Note)) { $settleArgs += @("-Note", $Note) }
    $r1 = Invoke-GoalTree $settleArgs
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "TREE_SETTLE_FAILED" "goal-tree settle failed (nothing transitioned): $($r1.text)" 1
    }
    return $r1.json.data
}

function Invoke-SettleTreeOnly {
    # tree-level acceptance node settle: the tree settle IS the whole transition
    # ("终态即止" — no task.json transition exists for a TaskId-less node). The
    # acceptance-chain trigger rides the auto-dispatch tail after this returns.
    param([string]$RunDir, [string]$NodeIdText)
    $null = Invoke-TreeSettleWrite $NodeIdText
    return @{
        bridge = $null; warnings = @(); graftedNext = $null; graftedNextNodes = @()
        flowOperation = "tree-level settle (no task.json transition)"; taskLifecycle = "tree-level"
    }
}

function Invoke-SettleFlowTransition {
    # tree settle (irreversible) + flow transition + chained next-stage graft;
    # half-failures land in pending_sync (Repair-PendingSync re-runs them).
    param([string]$RunDir, $Bridge, $Target, $Ready, [string]$QualityScanFile = $null)
    $null = Invoke-TreeSettleWrite $NodeId
    if ($null -eq $Ready.task_phase) {
        # LEGACY null-phase task: conservative degrade — byte-identical pre-phase
        # behavior (StageNext chain + single graft). New archives always carry phase.
        # The legacy tail is a set-route too, so the credential passthrough applies
        # uniformly (a DEV exit hits the chain-side handoff gate either way).
        $tail = Invoke-LegacySettleFlow $RunDir $Bridge $Ready.task $NodeId $Target.stage $Target.next_stage -QualityScanFile $QualityScanFile
    }
    else {
        # PHASE MODE (phase-model.md §5.2). Owners narrowing keeps the phase and only
        # fills MISSING live nodes (serial CTO->UX inside DESIGN); the LAST settle of
        # the phase switches atomically to PhaseRoles[PhaseNext[phase]] and grafts the
        # next phase's heads (convergence — no per-branch fan-out, no tree split).
        $tail = Invoke-PhaseSettleFlow $RunDir $Bridge $Ready.task $NodeId $Target.stage $Ready.owners $Ready.task_phase -QualityScanFile $QualityScanFile
    }
    return $tail
}

function New-SettleResult {
    # settle response assembly (shared by mapped and tree-level targets).
    param($Target, $Tail, $Push, $Bridge, $Warnings)
    $taskIdOut = $(if ($Target.tree_level) { $null } else { $Target.task_id })
    return @{
        success = $true
        data    = @{
            run_id          = $RunId
            node_id         = $NodeId
            task_id         = $taskIdOut
            stage_settled   = $Target.stage
            tree_level      = [bool]$Target.tree_level
            phase           = $Tail.taskPhase
            flow_operation  = [string]$Tail.flowOperation
            next_stage_node = $Tail.graftedNext
            next_stage_nodes = @($Tail.graftedNextNodes)
            task_lifecycle  = [string]$Tail.taskLifecycle
            acceptance      = Get-AcceptanceSection $Bridge
            auto_push       = @{ trigger = $Push.trigger; pushed = @($Push.pushed); failed = @($Push.failed); skipped = @($Push.skipped | ForEach-Object { "$($_.node):$($_.reason)" }) }
            warnings        = $Warnings
            next_step       = $(if (@($Push.failed).Count -gt 0) { "repair failed pushes: session-create class auto-retries via status; pointer class → dispatch -NodeId <id> manually" } elseif ([string]$Tail.taskLifecycle -eq "completed") { "task $($Target.task_id) reached terminal state" } else { "unlocked nodes pushed automatically (see auto_push); failures retry via status touch" })
        }
    }
}

function Invoke-SettleDerivationTail {
    # settle 派生分支（planner-midrun-derive）：mid-run derivation PM node，
    # 四查已过 → 确认记录硬门复核 → tree settle（irreversible）→ 受控入册
    # （add-task 代写 + bridge.tasks mapping + DESIGN chain heads under this
    # node）。Registration failure degrades to a warning — the patrol state
    # machine (Update-DerivationRegistrations) re-runs it idempotently on the
    # next trigger (pending_sync philosophy, the derivations section IS the
    # record). Returns the settle tail (same shape as the other two branches).
    param([string]$RunDir, $Bridge, [string]$NodeIdText, $Der)
    $conf = Find-DeriveConfirmation @(Read-DecisionEntries (Get-ArchiveDecisionsPath ([string]$Bridge.archive))) $Der
    if ($null -eq $conf) { Write-ErrorResult "DERIVE_CONFIRMATION_MISSING" "no user ruling record for derivation $($Der['id']) in the archive decision ledger — execution refused (nothing transitioned). The user-confirmation gate is a HARD gate." 1 }
    $null = Invoke-TreeSettleWrite $NodeIdText
    $reg = Invoke-DeriveRegisterTask -RunDir $RunDir -Bridge $Bridge -DerId ([string]$Der['id']) -NodeText $NodeIdText
    $Bridge = $(if ($reg.bridge) { $reg.bridge } else { $Bridge })
    if ($reg.ok) {
        return @{
            bridge = $Bridge; warnings = @($reg.warnings); graftedNext = $null; graftedNextNodes = @()
            flowOperation = "derivation registered: add-task 代写 + bridge.tasks mapping + chain heads pre-grafted (held by the stage gate until replan)"; taskLifecycle = "registered as task #$($reg.task_id)"
        }
    }
    return @{
        bridge = $Bridge; warnings = @("derivation registration incomplete — the status patrol retries it (derivation stays confirmed): $($reg.error)"); graftedNext = $null; graftedNextNodes = @()
        flowOperation = "derivation settle landed, registration pending patrol"; taskLifecycle = "registration pending"
    }
}

function Invoke-BridgeSettle {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $target = Resolve-SettleTarget $bridge $NodeId $runDir
    $node = Test-SettleDelivery -RunDir $runDir -NodeIdText $NodeId -TreeLevel ([bool]$target.tree_level) -Bridge $bridge
    # quality_scan passthrough (dev-quality-prescan-gate): the 4th check has
    # ALREADY validated the credential on the settle side; the flow tail's
    # set-route re-runs the SAME gate chain-side (registry dispatch, no caller
    # trust), so the accepted credential rides along as a temp file instead of
    # being re-minted. A skip-form credential passes the chain side as-is
    # (trusted declaration there by design).
    $scanFile = Write-QualityScanTempFile -RunDir $runDir -Node $node
    # parallel-coordination settle conflict gate (四查证据门先行,冲突门后置,错误码分立):
    # design-kind 涉事节点恒拒 / file-kind 仅双活跃方互拦 — NODE_HELD_BY_CONFLICT
    if (-not [bool]$target.tree_level) {
        Test-SettleConflictGate -RunDir $runDir -Bridge $bridge -NodeIdText $NodeId
    }
    $conflictWarnings = @(Test-CitationDeviation -RunDir $runDir -Bridge $bridge -NodeIdText $NodeId -Node $node)
    $tail = $null
    if ($null -ne $target.derivation) {
        $tail = Invoke-SettleDerivationTail $runDir $bridge $NodeId $target.derivation
    }
    elseif ($target.tree_level) {
        $tail = Invoke-SettleTreeOnly $runDir $NodeId
    }
    else {
        $flowReady = Test-SettleFlowReady -Bridge $bridge -Target $target
        $tail = Invoke-SettleFlowTransition -RunDir $runDir -Bridge $bridge -Target $target -Ready $flowReady -QualityScanFile $scanFile
        $tail['taskPhase'] = $flowReady.task_phase
    }
    if ($null -eq $tail.bridge) { $tail.bridge = $bridge }
    $bridge = $tail.bridge

    # plan settle tail (long-task-planning rolling tracking): progress event +
    # settle-time deviation checks, before the auto-dispatch tail below.
    Write-PlanSettleTail $runDir $bridge $target $NodeId

    # dependency-driven unlock push (goal-tree-goal-root): settling this node may
    # unlock other tasks' nodes (and grafted this task's own next phase) — push
    # every newly unlocked node automatically; push failures are isolated data.
    # The same call runs the acceptance-chain trigger (overall-delivery).
    $push = Invoke-AutoDispatch $runDir $bridge "settle"
    $bridge = $push.bridge
    $warnings = @()
    $warnings += @($tail.warnings)
    $warnings += $conflictWarnings
    foreach ($f in @($push.failed)) {
        $warnings += "auto-push failed for node $($f.node) (retry_class=$($f.retry_class)): session-create class auto-retries on the next trigger; pointer class needs manual dispatch. $($f.error)"
    }

    return New-SettleResult -Target $target -Tail $tail -Push $push -Bridge $bridge -Warnings $warnings
}

function Add-PendingSync {
    param([string]$RunDir, $Bridge, [string]$NodeId, [string]$Op, [string]$From, $To, [string]$Error, [string]$PhaseArg = $null, [string]$ScanEvidence = $null)
    $entry = [ordered]@{
        node   = $NodeId
        op     = $Op
        from   = $From
        to     = $To
        error  = $Error
        at     = Get-UtcNowIso
    }
    # phase-model: set-route repairs need the target phase for the retry (a phase
    # switch recorded without it would retry as a narrowing and drift the whitelist)
    if (-not [string]::IsNullOrWhiteSpace($PhaseArg)) { $entry['phase'] = $PhaseArg }
    # dev-quality-prescan-gate: set-route repairs need the quality_scan credential
    # file for the retry (the chain-side handoff gate demands it when DEV exits)
    if (-not [string]::IsNullOrWhiteSpace($ScanEvidence)) { $entry['scan_evidence'] = $ScanEvidence }
    $pending = @(Convert-ToSafeArray $Bridge.pending_sync)
    $pending += ,$entry
    $Bridge.pending_sync = $pending
    Write-BridgeFile $RunDir $Bridge
    return $Bridge
}

# === Node task text (dispatch-task-goal-anchoring) ===
#
# node.task 单源合成：New-NodeTaskText 是唯一权威文本产出者（promulgate 与 graft
# 下阶段两处构造点都改调它），载荷"目标为主、命令退居辅助"：
#   目标：完成「<标题>」的 <阶段> 阶段（<阶段职责>）。需求文档：<rel>[；设计文档：<rel>…]；
#   归档：<归档名>。开工动作（辅助）：delivery-bridge.cmd -Command claim …
# Get-NodeTaskBrief 把已落盘 node.task 派生为指针消息 brief（目标句改写 + 剔除
# 设计文档/归档段 + 占位符填真实 nodeId）；检测到旧格式英文命令串签名（存量 run
# 落盘的 "Execute TaskId …"）时返回空——保守降级零注入，消息与改造前完全一致。
# node.task 不截断（全文永远在树视图/claim 输出里）；仅 brief 段受长度上限约束。

$script:StageDuty = @{
    PM  = "需求分析与拆解"
    CTO = "技术方向设计"
    UX  = "交互与体验设计"
    DEV = "编码实现"
    QA  = "测试与验收"
}

function New-NodeTaskText {
    # Sole authoritative producer of a bridge node's task text (goal-first;
    # the claim command is auxiliary). The node id slot stays the placeholder
    # <本节点id> — the id is unknown at graft time (goal-tree has no
    # node-update command) and reaches the worker via the pointer brief,
    # the claim output, and the view instead. Archive name derives from the
    # frozen deliver-<archive> run-id convention.
    # RedoContext (optional, planner-stage-rollback): @{ from_stage; reason;
    # problems[] } — a rebuilt node carries the failed delivery's evidence
    # problems + the rollback reason so the redo worker sees them at claim
    # time (the prune reason alone stays invisible to workers). The redo
    # section is composed HERE like every other segment (sole-producer
    # invariant); its stable prefix is what Get-NodeTaskBrief re-extracts.
    param([string]$Title, [string]$Stage, [string]$ReqRel, [string[]]$DesignRels, [string]$RunId, $RedoContext,
          [string]$AcceptanceRef, [string]$Mission, [string]$ConventionsRef)

    $duty = ""
    if ($script:StageDuty.Contains($Stage)) { $duty = "（$($script:StageDuty[$Stage])）" }
    $archiveName = $RunId -replace '^deliver-', ''

    $t = "目标：完成「$Title」的 $Stage 阶段$duty。"
    if (-not [string]::IsNullOrWhiteSpace($Mission)) { $t += $Mission }
    $t += "需求文档：$ReqRel"
    if (@($DesignRels).Count -gt 0) { $t += "；设计文档：$(@($DesignRels) -join '、')" }
    $t += "；归档：$archiveName。"
    if (-not [string]::IsNullOrWhiteSpace($AcceptanceRef)) { $t += "整体验收判据：$AcceptanceRef。" }
    # 架构约定注入(parallel-coordination,与判据注入同构):DESIGN 链头/节点带
    # 「架构约定:<path>」——多 CTO/UX 设计遵循同一套架构/风格约定。
    if (-not [string]::IsNullOrWhiteSpace($ConventionsRef)) { $t += "架构约定：$ConventionsRef。" }
    if ($null -ne $RedoContext) {
        $rcFrom = [string]$RedoContext.from_stage
        if ([string]::IsNullOrWhiteSpace($rcFrom)) { $rcFrom = "上一" }
        $rcReason = [string]$RedoContext.reason
        $rcProblems = @()
        foreach ($p in @(Convert-ToSafeArray $RedoContext.problems)) { $rcProblems += [string]$p }
        $t += "重做上下文（跨阶段回退）：本节点因 $rcFrom 阶段交付不合格被回退重建。回退理由：$rcReason。"
        if ($rcProblems.Count -gt 0) { $t += "证据问题清单：$($rcProblems -join '；')。" }
        $t += "本轮请针对上述问题重做。"
    }
    $t += "开工动作（辅助）：delivery-bridge.cmd -Command claim -RunId $RunId -NodeId <本节点id> -Role $Stage。"
    return $t
}

function Get-NodeTaskBrief {
    # Derive the pointer-message brief from a PERSISTED node.task (single
    # source: the brief always agrees with what the tree view / claim output
    # shows). Transform: 目标：→ 本次唯一任务：, keep the goal sentence; keep the
    # 需求文档 path (drop the 设计文档/归档 tail — the message base already
    # names the archive, details live in the docs); 开工动作（辅助）：→
    # 开工先领取节点： with the real node id filled into the placeholder.
    # Any unparseable input (including the legacy "Execute TaskId …" English
    # signature persisted by pre-change runs) returns "" — zero injection,
    # byte-identical to the old message (conservative degrade, no translation).
    # Length caps: title > 60 chars truncated with …; assembled brief > 240
    # chars hard-cut with … (full text always remains in node.task).
    param([string]$NodeTask, [string]$NodeId)

    if ([string]::IsNullOrWhiteSpace($NodeTask)) { return "" }
    if ($NodeTask.StartsWith("Execute TaskId")) { return "" }
    if ($NodeTask -notmatch '^目标：完成「(?<title>.+?)」的 (?<stage>PM|CTO|UX|DEV|QA) 阶段(?<duty>（[^）]*）)?。') { return "" }

    $title = [string]$Matches['title']
    if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + "…" }
    $brief = "本次唯一任务：完成「$title」的 $($Matches['stage']) 阶段$($Matches['duty'])。"

    if ($NodeTask -match '需求文档：(?<req>[^；。]+)') {
        $brief += "需求文档：$($Matches['req'])。"
    }
    $claimPart = ""
    if ($NodeTask -match '开工动作（辅助）：(?<cmd>delivery-bridge\.cmd[^。]*?)。') {
        $cmd = [string]$Matches['cmd']
        $cmd = $cmd -replace '<本节点id>', $NodeId
        $claimPart = "开工先领取节点：$cmd。"
    }
    # redo excerpt (planner-stage-rollback) + whole-delivery context (使命 /
    # 整体验收判据, overall-delivery): ride along room-aware — the claim command
    # always survives the cap; overlong text truncates here but the full text
    # always remains in node.task and the claim output (the brief only keeps the
    # message compact). Context is only injected when the claim command is
    # present (the legacy no-claim shape stays zero-injection).
    $context = @()
    if ($NodeTask -match '使命：(?<m>[^。]+)。') { $context += ,@("使命：", "$($Matches['m'])。") }
    if ($NodeTask -match '整体验收判据：(?<a>[^。]+)。') { $context += ,@("整体验收判据：", "$($Matches['a'])。") }
    if ($NodeTask -match '架构约定：(?<c>[^。]+)。') { $context += ,@("架构约定：", "$($Matches['c'])。") }
    if ($NodeTask -match '重做上下文（跨阶段回退）：(?<redo>.+?)(?=开工动作（辅助）：)') { $context += ,@("重做上下文（跨阶段回退）：", [string]$Matches['redo']) }
    foreach ($seg in $context) {
        if (-not $claimPart) { break }
        $room = 240 - $brief.Length - $claimPart.Length - 1
        $piece = Get-BriefContextSegment $seg[0] $seg[1] $room
        if ($piece) { $brief += $piece }
    }
    $brief += $claimPart

    if ($brief.Length -gt 240) { $brief = $brief.Substring(0, 239) + "…" }
    return $brief
}

function Get-BriefContextSegment {
    # room-aware optional context segment for the pointer brief (使命 / 整体验收
    # 判据 / 重做上下文): appended only while room remains after reserving the
    # claim command (the brief's mandatory tail); overlong body truncates with ….
    param([string]$Prefix, [string]$Body, [int]$Room)
    $avail = $Room - $Prefix.Length
    if ($avail -lt 1) { return "" }
    $text = [string]$Body
    if ($text.Length -gt $avail) { $text = $text.Substring(0, $avail - 1) + "…" }
    return $Prefix + $text
}

function Get-NodeTaskSummary {
    # session-list-badges: the workspace-row summary title (<标题> <阶段>)
    # derived from the PERSISTED node.task — same source and same regex as
    # Get-NodeTaskBrief (single source: the summary always agrees with the
    # tree view / claim output), title capped at 60 chars with … (the host's
    # rename then truncates to its own 80-UTF-8-byte budget; double-layer
    # consistency per the design). No 「」 wrapper (UX spec §2.1: badges carry
    # the structure; the summary stays a bare readable line, still
    # self-describing after CLI/legacy-text degrade). Any unparseable input
    # (including the legacy "Execute TaskId …" English signature persisted by
    # pre-change runs) returns "" → -TaskSummary omitted → zero injection:
    # start-role keeps the legacy marker title and every backend's behavior
    # stays byte-identical.
    param([string]$NodeTask)

    if ([string]::IsNullOrWhiteSpace($NodeTask)) { return "" }
    if ($NodeTask.StartsWith("Execute TaskId")) { return "" }
    if ($NodeTask -notmatch '^目标：完成「(?<title>.+?)」的 (?<stage>PM|CTO|UX|DEV|QA) 阶段(?<duty>（[^）]*）)?。') { return "" }

    $title = [string]$Matches['title']
    if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + "…" }
    return "$title $($Matches['stage'])"
}

function Get-NodeTaskText {
    # Read one node's persisted task text via the public leaf status CLI
    # (black-box: no internal state-file coupling). The tree STATUS view the
    # auto-dispatcher loads carries ids only for pending nodes, so this probe
    # is the uniform channel for nodes the in-place next view misses (parked
    # reclaim nodes, next-view failure). Any failure degrades to "" (zero
    # injection) and never blocks the push itself.
    param([string]$RunId, [string]$NodeId)

    $r = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) { return "" }
    if ($null -eq $r.json.data -or $null -eq $r.json.data.node) { return "" }
    return [string]$r.json.data.node.task
}

function Invoke-GraftNextStage {
    param([string]$RunDir, $Bridge, $Task, [string]$ParentNodeId, [string]$NextStage, $RedoContext)
    $taskId = [int]$Task.id
    # duplicate-graft hard gate (settle-route-narrow-duplicate-graft): refuse when
    # a LIVE node already maps to (task, stage) — the single choke point every
    # stage-graft path passes through (EnsureStageNodes guards first; rollback /
    # legacy-settle land here with the old node already terminal). A live mapping
    # means this graft would duplicate in-flight work AND poison bridge.tasks
    # .stages (the whitelist overwrite keeps only the latest node per role).
    $live = Get-LiveStageNode -RunId ([string]$Bridge.run_id) -Bridge $Bridge -TaskId $taskId -Role $NextStage
    if ($null -ne $live) {
        return @{ success = $false; error = "DUPLICATE_STAGE_GRAFT: task #$taskId already has a live $NextStage node ($live) — graft refused, in-flight mapping not overwritten" }
    }
    $title = [string]$Task.title
    $reqRel = ([string]$Task.requirement -replace '\\', '/')
    $designRels = @()
    foreach ($d in @(Convert-ToSafeArray $Task.designDocs)) { $designRels += ([string]$d.path -replace '\\', '/') }
    # goal-first node task text (dispatch-task-goal-anchoring): single
    # authoritative producer — see New-NodeTaskText above; RedoContext is
    # only supplied by rollback (rebuilt previous-stage node). ConventionsRef
    # (parallel-coordination): DESIGN 阶段节点同样注入「架构约定:<path>」。
    $conventionsRef = $null
    if (Test-DesignStageNode ([string]$NextStage) $Task) { $conventionsRef = Get-ConventionsRef $Bridge }
    $taskText = New-NodeTaskText -Title $title -Stage $NextStage -ReqRel $reqRel -DesignRels $designRels -RunId ([string]$Bridge.run_id) -RedoContext $RedoContext -ConventionsRef $conventionsRef
    $graftItem = @{
        title = "$title"
        task  = $taskText
        role  = $NextStage.ToLower()
        ref   = "$((Split-Path $Bridge.archive -Leaf))/$reqRel"   # stage nodes of a requirement keep its doc ref (goal-tree-goal-root)
    }
    $g = Invoke-GraftOne $Bridge.run_id $ParentNodeId $graftItem
    if (-not $g.ok) {
        return @{ success = $false; error = $g.text }
    }
    $nodeId = $g.node_id
    Set-NodeTaskStage $Bridge $nodeId $taskId $NextStage
    Write-BridgeFile $RunDir $Bridge
    return @{ success = $true; bridge = $Bridge; node_id = $nodeId }
}

function Get-LiveStageNode {
    # phase-model: the bridge's current (task, role) node when it exists AND sits in
    # a live (non-terminal) state; $null otherwise (absent / done / pruned / missing).
    # A done node for a re-entering role (QA design -> QA verify) does NOT count —
    # the whitelist overwrite in bridge.tasks keeps only the latest node per role.
    param([string]$RunId, $Bridge, [int]$TaskId, [string]$Role)
    $existing = $null
    if ($Bridge.tasks.Contains("$TaskId")) {
        $bTask = $Bridge.tasks["$TaskId"]
        if ($bTask.Contains('stages') -and $null -ne $bTask['stages'] -and $bTask['stages'].Contains($Role)) {
            $existing = [string]$bTask['stages'][$Role]
        }
    }
    if ($null -eq $existing) { return $null }
    # settle-route-narrow-duplicate-graft (2026-10-09 incident, ops-dashboard-
    # project-switcher): status MUST come from the NORMALIZED view resolver. The
    # raw Get-NodeFromTree passes the claimed/reported buckets' rich objects
    # through AS-IS and those carry NO status field (bucket membership IS the
    # status there), so `.status` evaluated to "" — every claimed/reported peer
    # looked dead here and each settle narrowing re-grafted live owners
    # (duplicate nodes + duplicate dispatches; bridge.tasks.stages poisoned by
    # the whitelist overwrite). Pending peers worked by accident: the bare-id
    # string buckets synthesize a status field. Use Get-NodeViewState (the
    # shape-normalized resolver this bug motivated) for every bucket shape.
    $view = Get-NodeViewState (Get-TreeStatusView $RunId) $existing
    $status = if ($view) { [string]$view.status } else { "missing" }
    if ($status -in @("pending", "claimed", "reported")) { return $existing }
    return $null
}

function Invoke-EnsureStageNodes {
    # phase-model convergence graft: after a settle-side set-route, guarantee every
    # CURRENT owner role has a live (non-terminal) node — graft the missing ones
    # under the just-settled node (chain parent). Parallel heads built at promulgate
    # are live already -> no graft -> NO TREE SPLIT (the single-graft-per-role rule
    # is what keeps two parallel branches from each grafting their own DEV). Roles
    # added to the owner set mid-flow (serial CTO -> UX inside DESIGN) and re-entering
    # roles whose previous node went terminal (QA design -> QA verify) get their
    # fresh node HERE, exactly once, from the settling node. Returns
    # @{ bridge; grafted = @(); failed = @() }.
    param([string]$RunDir, $Bridge, $Task, [string]$ParentNodeId, [string[]]$Roles)
    $taskId = [int]$Task.id
    $grafted = @()
    $failed = @()
    foreach ($role in @($Roles)) {
        $live = Get-LiveStageNode -RunId ([string]$Bridge.run_id) -Bridge $Bridge -TaskId $taskId -Role $role
        if ($null -ne $live) { continue }
        $g = Invoke-GraftNextStage $RunDir $Bridge $Task $ParentNodeId $role
        if ($g.success) { $Bridge = $g.bridge; $grafted += $g.node_id }
        else { $failed += @{ role = $role; error = $g.error } }
    }
    return @{ bridge = $Bridge; grafted = @($grafted); failed = @($failed) }
}

# === Command: status / resume ===

function Repair-PendingSync {
    # divergence repair: retry each recorded flow operation; clear on success
    param([string]$RunDir, $Bridge)
    $repaired = @()
    $remaining = @()
    foreach ($e in @(Convert-ToSafeArray $Bridge.pending_sync)) {
        $taskId = (Get-NodeTaskStage $Bridge ([string]$e.node)).task_id
        $r = $null
        if ([string]$e.op -eq "complete") {
            $r = Invoke-RddFlow @("-Command", "complete", "-TaskId", "$taskId", "-Archive", $Bridge.archive)
        }
        elseif ([string]$e.op -eq "set-route") {
            # phase-model settle/rollback half-failure: the tree side moved (settled
            # / pruned + rebuilt) but the flow set-route did not land — retry it,
            # WITH the recorded phase when the original was a phase switch (a
            # phaseless retry would narrow against the wrong whitelist)
            $retryArgs = @("-Command", "set-route", "-TaskId", "$taskId", "-To", [string]$e.to, "-Archive", $Bridge.archive)
            if ($null -ne $e.phase -and ([string]$e.phase) -ne "") {
                $retryArgs += @("-Phase", [string]$e.phase)
            }
            # dev-quality-prescan-gate: replay the recorded quality_scan credential
            # — a DEV-exiting retry hits the chain-side handoff gate without it
            # (a settled credential re-materializes from the entry's scan_evidence;
            # rollback disposals recorded the engine's honest skip declaration)
            $ev = [string]$e.scan_evidence
            if ($ev -ne '' -and (Test-Path -LiteralPath $ev -PathType Leaf)) {
                $retryArgs += @("-QualityScanFile", $ev)
            }
            $r = Invoke-RddFlow $retryArgs
        }
        elseif ([string]$e.op -eq "reopen") {
            # rollback half-failure (planner-stage-rollback): the tree side moved
            # (prune + rebuilt node) but the flow reopen did not land — retry it
            $r = Invoke-RddFlow @("-Command", "reopen", "-TaskId", "$taskId", "-To", [string]$e.to, "-Archive", $Bridge.archive)
        }
        else {
            # legacy 'advance'-op entries (engine predating the advance removal):
            # replay as set-route — -Phase only when the hop target is phase-
            # ambiguous (QA -> VERIFY, the legacy acceptance hop); unambiguous
            # targets keep the null-phase legacy semantics.
            $retryArgs = @("-Command", "set-route", "-TaskId", "$taskId", "-To", [string]$e.to, "-Archive", $Bridge.archive)
            $hopPhase = Get-LegacyHopPhase ([string]$e.to)
            if ($null -ne $hopPhase) { $retryArgs += @("-Phase", $hopPhase) }
            $ev = [string]$e.scan_evidence
            if ($ev -ne '' -and (Test-Path -LiteralPath $ev -PathType Leaf)) {
                $retryArgs += @("-QualityScanFile", $ev)
            }
            $r = Invoke-RddFlow $retryArgs
        }
        if ($r.exit -eq 0 -and $null -ne $r.json -and $r.json.success) {
            $repaired += @{ node = $e.node; op = $e.op }
        }
        else {
            $remaining += ,$e
        }
    }
    if ($repaired.Count -gt 0) {
        $Bridge.pending_sync = $remaining
        Write-BridgeFile $RunDir $Bridge
    }
    return @{ bridge = $Bridge; repaired = $repaired; remaining = $remaining }
}

function Get-RolePhase {
    # phase-model display lookup: a role's phase. Non-QA roles map through the
    # PhaseRoles whitelist (first hit in PhaseOrder). QA sits in BOTH the DESIGN
    # and VERIFY whitelists, so its row is dated by context — once DEV has a
    # record (or the task's phase reached IMPL/VERIFY) the QA row belongs to
    # VERIFY, else to DESIGN. Unknown roles degrade to '?'.
    param([string]$Role, [bool]$HasImpl, [string]$TaskPhase)
    if ($Role -eq "QA") {
        if ($HasImpl -or $TaskPhase -in @("IMPL", "VERIFY")) { return "VERIFY" }
        return "DESIGN"
    }
    foreach ($p in $script:PhaseOrder) {
        if (@($script:PhaseRoles[$p]) -contains $Role) { return $p }
    }
    return "?"
}

function Format-StageChain {
    # phase-model display: render a task's recorded (role -> node) stages as a
    # phase chain — roles of the same phase joined "∥" (parallel group), phases
    # joined "→". Get-RolePhase dates each row (QA design-vs-verify; unknown
    # roles fall back '?'). bridge.tasks keeps ONE node per role key
    # (phase-model §4.2), so a task that crossed QA twice displays the latest
    # node — by design.
    param($StagesMap, $TreeData, [string]$TaskPhase)
    if ($null -eq $StagesMap) { return "-" }
    $present = @()
    foreach ($role in $script:RoleOrder) {
        if ($StagesMap.Contains($role)) { $present += $role }
    }
    if ($present.Count -eq 0) { return "-" }
    $hasImpl = $StagesMap.Contains("DEV")
    $groups = [ordered]@{}
    foreach ($role in $present) {
        $ph = Get-RolePhase $role $hasImpl $TaskPhase
        if (-not $groups.Contains($ph)) { $groups[$ph] = @() }
        $nodeId = [string]$StagesMap[$role]
        $node = Get-NodeFromTree $TreeData $nodeId
        $groups[$ph] += "$role=$nodeId($(if ($node) { [string]$node.status } else { 'missing' }))"
    }
    $parts = @()
    foreach ($ph in @($groups.Keys)) { $parts += (@($groups[$ph]) -join ' ∥ ') }
    return ($parts -join ' → ')
}

function Get-BridgeTaskRows {
    # per-task join for the overview: stage nodes + flow routing/worker + lifecycle
    param($Bridge, $FlowTasks, $TreeData)
    $taskRows = @()
    foreach ($t in $FlowTasks) {
        $taskId = [int]$t.id
        $stages = @()
        $stageChain = "-"
        $bTask = $null
        if ($Bridge.tasks.Contains("$taskId")) { $bTask = $Bridge.tasks["$taskId"] }
        if ($null -ne $bTask) {
            $bStages = $bTask['stages']
            if ($null -eq $bStages) { $bStages = @{} }
            foreach ($stage in @($script:RoleOrder)) {
                if (-not $bStages.Contains($stage)) { continue }
                $nodeId = [string]$bStages[$stage]
                $node = Get-NodeFromTree $TreeData $nodeId
                $stages += @{
                    stage  = $stage
                    node   = $nodeId
                    status = $(if ($node) { [string]$node.status } else { "missing" })
                }
            }
            $taskPhase = [string]$t.phase
            if ([string]::IsNullOrEmpty($taskPhase)) { $taskPhase = $null }
            $stageChain = Format-StageChain $bStages $TreeData $(if ($null -ne $taskPhase) { $taskPhase } else { "" })
        }
        $workers = @()
        foreach ($w in @(Convert-ToSafeArray $t.currentWorker)) {
            if ($null -eq $w) { continue }
            if ($w -is [System.Collections.IDictionary]) { foreach ($k in @($w.Keys)) { $workers += "$k@$($w[$k])" } }
            else { foreach ($p in @($w.PSObject.Properties)) { $workers += "$($p.Name)@$($p.Value)" } }
        }
        $owners = @()
        if ($null -ne $t.currentOwners) { $owners = @($t.currentOwners) }
        $taskRowPhase = $null
        if ($null -ne $t.phase -and ([string]$t.phase) -ne "") { $taskRowPhase = [string]$t.phase }
        $taskRows += @{
            task_id        = $taskId
            title          = [string]$t.title
            lifecycle      = [string]$t.lifecycle
            current_owners = $owners
            phase          = $taskRowPhase
            flow_workers   = $workers
            stages         = $stages
            stage_chain    = $stageChain
        }
    }
    return $taskRows
}

function Get-BridgeDeadClaims {
    # dead claims: tree side claimed too old, or flow worker entries too old
    param($TreeData, $FlowTasks)
    $deadTreeClaims = @()
    $now = Get-Date
    foreach ($n in @(Convert-ToSafeArray $TreeData.nodes.claimed)) {
        $ageMin = $null
        if ($n.claimed_at) {
            try { $ageMin = [int](($now.ToUniversalTime() - [datetime]::Parse($n.claimed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes) } catch {}
        }
        if ($null -ne $ageMin -and $ageMin -ge $DeadClaimMinutes) {
            $deadTreeClaims += @{ node = $n.id; claimed_by = $n.claimed_by; age_minutes = $ageMin }
        }
    }
    $deadFlowClaims = @()
    foreach ($t in $FlowTasks) {
        foreach ($w in @(Convert-ToSafeArray $t.currentWorker)) {
            if ($null -eq $w) { continue }
            $pairs = @()
            if ($w -is [System.Collections.IDictionary]) { foreach ($k in @($w.Keys)) { $pairs += ,@($k, [string]$w[$k]) } }
            else { foreach ($p in @($w.PSObject.Properties)) { $pairs += ,@($p.Name, [string]$p.Value) } }
            foreach ($pair in $pairs) {
                try {
                    $ageMin = [int](($now - [datetime]::Parse($pair[1])).TotalMinutes)
                    if ($ageMin -ge $DeadClaimMinutes) { $deadFlowClaims += @{ task_id = [int]$t.id; role = $pair[0]; age_minutes = $ageMin } }
                } catch {}
            }
        }
    }
    return @{ tree = $deadTreeClaims; flow = $deadFlowClaims }
}

function Get-FlaggedDeliveries {
    # reported-but-unqualified deliveries (planner-stage-rollback): settle refuses
    # them; surface the disposition menu — same-stage reclaim (redo THIS stage)
    # vs cross-stage rollback (send the task one stage back) — so the choice
    # never degrades into hand-edited state (hard constraint 2). The status
    # view's reported rows lack last_verdict, so the full node comes from the
    # per-node leaf status probe (black-box, same channel Get-NodeTaskText uses).
    param([string]$RunDir, $Bridge, $TreeData, $FlowTasks)
    $flagged = @()
    foreach ($rn in @(Convert-ToSafeArray $TreeData.nodes.reported)) {
        $rid = if ($rn -is [string]) { $rn } else { [string]$rn.id }
        $rs = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $rid)
        if ($rs.exit -ne 0 -or $null -eq $rs.json -or -not $rs.json.success -or $null -eq $rs.json.data.node) { continue }
        $probs = @(Test-SettleEvidence -RunDir $RunDir -Node $rs.json.data.node -NodeId $rid -Bridge $Bridge -PreloadedTasks $FlowTasks)
        if ($probs.Count -gt 0) {
            $flagged += @{
                node        = $rid
                problems    = $probs
                same_stage  = "delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $rid"
                cross_stage = "delivery-bridge.cmd -Command rollback -RunId $RunId -NodeId $rid -To <roles> -Phase <REQ|DESIGN|IMPL|VERIFY> -Reason <why>"
            }
        }
    }
    return $flagged
}

function Get-BridgeOverview {
    # joined view shared by status and resume
    param([string]$RunDir, $Bridge)

    $treeData = Get-TreeStatusView $RunId
    $flow = Read-ArchiveTasks $Bridge.archive
    $repair = Repair-PendingSync $RunDir $Bridge
    $bridge = $repair.bridge

    $taskRows = Get-BridgeTaskRows -Bridge $Bridge -FlowTasks $flow.tasks -TreeData $treeData
    $deadClaims = Get-BridgeDeadClaims -TreeData $treeData -FlowTasks $flow.tasks

    # claimable nodes right now (tree pending + not dep-blocked + bridge-mapped)
    $claimable = @()
    $nx = Get-LeafNextView $RunId
    if ($null -ne $nx) {
        foreach ($p in @(Convert-ToSafeArray $nx.pending)) {
            if ($null -ne (Get-NodeTaskStage $bridge ([string]$p.id))) { $claimable += $p.id }
        }
    }

    $flagged = Get-FlaggedDeliveries -RunDir $RunDir -Bridge $bridge -TreeData $treeData -FlowTasks $flow.tasks

    $deps = $treeData.dependencies

    $terminalCount = @($flow.tasks | Where-Object { ([string]$_.lifecycle) -in @("completed", "deprecated") }).Count

    return @{
        bridge         = $bridge
        tree           = $treeData
        task_rows      = $taskRows
        dead_claims    = $deadClaims
        claimable      = $claimable
        flagged_deliveries = $flagged
        dependencies   = $deps
        repair         = @{ repaired = $repair.repaired; remaining = $repair.remaining }
        conflicts      = (Get-ConflictView $bridge)
        lease          = (Get-LeaseState $RunDir)
        flow_taskCount = $flow.tasks.Count
        terminalCount  = $terminalCount
    }
}

function Invoke-StatusTouch {
    # status touch catch-up push (goal-tree-goal-root trigger point 4) + the
    # long-task-planning patrol (delay/scope deviation detection): best-effort
    # and lease-aware — another live planner's lease owns pushing and writing.
    param([string]$RunDir, $Bridge, [string]$TreeState)
    if ($TreeState -eq "concluded") {
        return @{ touch = @{ ran = $false; note = $null }; bridge = $Bridge }
    }
    $leaseTry = Try-PlannerLeaseForTouch $RunDir
    if (-not $leaseTry.acquired) {
        return @{ touch = @{ ran = $false; note = "auto-push skipped: planner lease held by '$($leaseTry.holder)' (their orchestration owns pushing)" }; bridge = $Bridge }
    }
    $touch = @{ ran = $true; pushed = @(); skipped = @(); failed = @() }
    if ($null -ne (Get-PlanSection $Bridge)) {
        $flow = Read-ArchiveTasks $Bridge.archive
        $touch['plan_deviations'] = @(Write-PlanPatrolDeviations $RunDir $Bridge (Get-TreeStatusView $RunId) $flow.tasks)
    }
    $push = Invoke-AutoDispatch $RunDir $Bridge "status"
    if (-not $leaseTry.was_mine) { $null = Invoke-LeaseRelease $RunDir }
    $touch['pushed'] = @($push.pushed)
    $touch['skipped'] = @($push.skipped)
    $touch['failed'] = @($push.failed)
    return @{ touch = $touch; bridge = $push.bridge }
}

function New-StatusPushRows {
    # per-node push ledger view (failures with retry classes stay visible here).
    param($Bridge)
    $pushRows = @()
    foreach ($nodeId in @($Bridge.pushes.Keys)) {
        $st = $Bridge.pushes[$nodeId]
        $last = @()
        foreach ($a in @(Convert-ToSafeArray $st['attempts'])) { $last += $a }
        $lastAttempt = if ($last.Count -gt 0) { $last[-1] } else { $null }
        $pushRows += @{
            node         = $nodeId
            last_ok_at   = $st['last_ok_at']
            needs_repush = [bool]$st['needs_repush']
            attempts     = @($last | Select-Object -Last 3)
            last_error   = $(if ($lastAttempt -and -not $lastAttempt.ok) { $lastAttempt.error } else { $null })
            retry_class  = $(if ($lastAttempt -and -not $lastAttempt.ok) { $lastAttempt.retry_class } else { $null })
        }
    }
    return $pushRows
}

function New-StatusLivenessRows {
    # claimed-node session liveness (read-only; unknown is normal outside dsh).
    param($ClaimedNodes)
    $livenessRows = @()
    foreach ($n in @(Convert-ToSafeArray $ClaimedNodes)) {
        $cid = if ($n -is [string]) { $n } else { [string]$n.id }
        $live = Get-ClaimLiveness $RunId $cid
        $livenessRows += @{ node = $cid; claimed_by = $(if ($n -is [string]) { $null } else { $n.claimed_by }); liveness = $live.liveness; session_id = $live.session_id }
    }
    return $livenessRows
}

function New-StatusSessionRows {
    # session roster rows (planner-session-roster): every dsh session this run
    # derived — planner body, bridge dispatches, registered direct handoffs.
    param($Sessions)
    $sessionRows = @()
    foreach ($s in @($Sessions)) {
        if ($null -eq $s) { continue }
        $sessionRows += @{
            session_id = [string]$s['session_id']
            role       = [string]$s['role']
            node       = $(if ($s.Contains('node') -and $null -ne $s['node']) { [string]$s['node'] } else { $null })
            label      = $(if ($s.Contains('label') -and $null -ne $s['label']) { [string]$s['label'] } else { $null })
            source     = [string]$s['source']
            title      = [string]$s['title']
            created_at = [string]$s['created_at']
            updated_at = [string]$s['updated_at']
        }
    }
    return $sessionRows
}

function Add-PlanStatusWarnings {
    # plan-view warnings (long-task-planning): acceptance points awaiting their
    # settle + explicitly surfaced pending stage gates + quarantined log rows.
    param($PlanView, $Bridge)
    $w = @()
    if ($null -eq $PlanView) { return $w }
    foreach ($st in @($PlanView.stages)) {
        if (([string]$st.acceptance.status) -eq 'grafted') {
            $w += "stage $($st.id) acceptance point node $($st.acceptance.node) awaiting settle — downstream stage gates stay closed until it passes"
        }
        # auditor-design-stage-review: 审查节点待 settle / 审查未过提示（无段视图零增）
        if ($null -ne $st.design_review) {
            $drs = [string]$st.design_review.status
            if ($drs -eq 'grafted') {
                $w += "stage $($st.id) design review node $($st.design_review.node) awaiting settle — IMPL 节点闸门关闭至 DesignReviewFile verdict 落地（pass 放行 / fail 触发重做波）"
            }
            elseif ($drs -eq 'ready') {
                # auditor-subagent-review: 新链派审提示（plan-log progress 事件 + 本视图
                # 双感知面，无自动会话）——planner-guide 硬约束「settle 尾必查待审阶段」。
                $w += "stage $($st.id) design review is READY (design_review_due) — 派五查评审子代理（机械输入模板 rdd-engine/references/review-input-template.md，独立上下文）产出 DesignReviewFile 后 'delivery-bridge.cmd -Command design-review -Action submit -RunId $($Bridge['run_id']) -Stage $($st.id)'；IMPL 闸门关闭至 submit 落地"
            }
            elseif (@('planned', 'failed') -contains $drs) {
                $w += "stage $($st.id) design review is '$drs' — 有设计产物在册任务的 IMPL 节点被闸（NODE_BLOCKED_BY_DESIGN_REVIEW 同族）"
            }
        }
    }
    foreach ($key in @($Bridge.tasks.Keys)) {
        $blockers = Get-PlanGateBlockers $Bridge ([int]$key)
        if ($blockers.Count -gt 0) {
            $w += "task #$key is stage-gated (waiting on acceptance point(s): [$($blockers -join ', ')]) — settle those acceptance nodes, or replan to re-scope the stages"
        }
    }
    if ([bool]$PlanView.log_corrupt) { $w += "plan-log.jsonl has quarantined bad line(s) in plan-log.jsonl.corrupt" }
    return $w
}

function New-StatusWarnings {
    # joined warnings: tree integrity + roster/pending_sync/dead claims +
    # flagged deliveries + push failures + auto-mode escalations + plan view.
    param($View, $PushRows, $Roster, $AutoModeBlock, $PlanView, $Bridge)
    $warnings = @()
    foreach ($w in @($View.tree.integrity.warnings)) { $warnings += "tree: $w" }
    if ($Roster.corrupt) { $warnings += "sessions.json roster unparseable — read as empty (the next registration self-heals the file)" }
    if ($View.repair.remaining.Count -gt 0) { $warnings += "pending_sync unresolved: $(@($View.repair.remaining | ForEach-Object { "$($_.node):$($_.op)" }) -join ', ')" }
    if ($View.dead_claims.tree.Count -gt 0) { $warnings += "dead tree claim(s) (>= ${DeadClaimMinutes} min): $(@($View.dead_claims.tree | ForEach-Object { $_.node }) -join ', ') — reclaim them" }
    if ($View.dead_claims.flow.Count -gt 0) { $warnings += "dead flow claim(s): $(@($View.dead_claims.flow | ForEach-Object { "task#$($_.task_id):$($_.role)" }) -join ', ')" }
    if (@($View.flagged_deliveries).Count -gt 0) {
        $warnings += "unqualified reported delivery(ies): $(@($View.flagged_deliveries | ForEach-Object { $_.node }) -join ', ') — adjudicate: reclaim -NodeId <id> (redo the same stage) or rollback -NodeId <id> -Reason <why> (send the task one stage back)"
    }
    $failedPushes = @($PushRows | Where-Object { $_.retry_class })
    if ($failedPushes.Count -gt 0) {
        $warnings += "push failures: $(@($failedPushes | ForEach-Object { "$($_.node)($($_.retry_class))" }) -join ', ') — session-create class auto-retries on every status touch; pointer class needs manual dispatch"
    }
    if ($null -ne $AutoModeBlock -and @($AutoModeBlock.open_escalations).Count -gt 0) {
        $warnings += "open escalation(s): $(@($AutoModeBlock.open_escalations | ForEach-Object { "$($_.entry_id)@$($_.node)/$($_.checkpoint)$(if ($_.historical) { ' (historical: node pruned)' })" }) -join ', ') — present them to the user; verdict lands via decide -Kind resolution"
    }
    $warnings += @(Add-PlanStatusWarnings $PlanView $Bridge)
    # 需求派生视图（planner-midrun-derive）：registered-unabsorbed 派生高亮提示
    # replan 吸收（confirm 后规划者忘记 replan 的应对——链头被闸门 hold 不推进）。
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        $st = [string]$d['status']
        if ($st -in @('proposed', 'confirmed')) {
            $warnings += "derivation $($d['id'])「$($d['title'])」 is $st$(if ($st -eq 'proposed') { ' — awaiting the user ruling (confirm with -UserVerdict, or withdraw)' } else { " — PM node $($d['node']) in flight (or awaiting push/claim)" })"
        }
        elseif ($st -eq 'registered' -and -not ($d['absorbed'] -eq $true)) {
            $warnings += "derivation $($d['id']) registered as task #$($d['task_id']) but NOT yet absorbed by the plan — its chain is stage-gated (NODE_BLOCKED_BY_GATE); replan it into the stages: delivery-bridge.cmd -Command replan -RunId $($Bridge['run_id']) -PlanFile <revised plan incl. task #$($d['task_id'])> -Reason <deviation>"
        }
    }
    # 并行冲突治理视图(parallel-coordination):未决冲突 + 回执偏差警示(status/annex)。
    $cv = Get-ConflictView $Bridge
    foreach ($e in @($cv.open)) {
        $warnings += "unresolved conflict $($e['id']) (kind=$($e['kind']), status=$($e['status']), nodes [$($e['nodes'] -join ', ')]) — 治理中(调和/上报/挂起),不得默默二选一;处置后 'delivery-bridge.cmd -Command conflict -RunId $($Bridge['run_id']) -Action resolve -ConflictId $($e['id']) -Ruling <结论>'"
    }
    foreach ($dv in @($cv.citation_deviations)) {
        $warnings += "回执偏差(软核对): $($dv['node']) @ $($dv['doc']) citations 超出变更地图文件集 [$($dv['refs'] -join ', ')] — 核对变更地图是否漏报/写错(检测失明风险)"
    }
    return $warnings
}

function Invoke-BridgeStatus {
    # joined view orchestrator (QA function-size gate decomposition: the row/
    # warning/touch builders live beside it).
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $view = Get-BridgeOverview $runDir $bridge
    $bridge = $view.bridge

    $touchRes = Invoke-StatusTouch $runDir $bridge ([string]$view.tree.state)
    $bridge = $touchRes.bridge

    $pushRows = New-StatusPushRows $bridge
    $livenessRows = New-StatusLivenessRows $view.tree.nodes.claimed
    $roster = Read-Roster $runDir
    $sessionRows = New-StatusSessionRows $roster.sessions
    $planView = Get-PlanView $runDir $bridge

    # pure-auto-mode visibility block (planner-auto-mode): ONLY for -AutoMode
    # runs (byte-identical absence on legacy runs).
    $autoModeBlock = $null
    if ($null -ne (Get-AutoModeSection $bridge)) {
        $autoModeBlock = Get-AutoModeDecisionView $runDir $bridge $view.tree
    }
    $warnings = New-StatusWarnings $view $pushRows $roster $autoModeBlock $planView $bridge

    return @{
        success = $true
        data    = [ordered]@{
            run_id         = $RunId
            archive        = $bridge.archive_rel
            goal_root      = $(if ((Test-PropPresent $bridge 'goal_root') -and $bridge.goal_root) { $bridge.goal_root } else { $null })
            state          = $view.tree.state
            round          = $view.tree.round
            budget         = $view.tree.budget
            tasks          = $view.task_rows
            tree_census    = $view.tree.nodes
            dependencies   = $view.dependencies
            claimable      = $view.claimable
            dead_claims    = $view.dead_claims
            flagged_deliveries = @($view.flagged_deliveries)
            session_liveness = $livenessRows
            sessions       = $sessionRows
            pushes         = $pushRows
            auto_push_touch = $touchRes.touch
            auto_mode      = $autoModeBlock
            plan           = $planView
            conflicts      = $view.conflicts
            derivations    = @(New-DerivationViewRows $bridge)
            pending_sync   = $view.repair.remaining
            repaired_now   = $view.repair.repaired
            lease          = $view.lease
            terminal       = "$($view.terminalCount)/$($view.flow_taskCount)"
            warnings       = $warnings
            next_step      = $(if (@($view.flagged_deliveries).Count -gt 0) { "adjudicate unqualified delivery(ies) [$(@($view.flagged_deliveries | ForEach-Object { $_.node }) -join ', ')]: rollback -NodeId <id> -Reason <why> (one stage back) or reclaim -NodeId <id> (same-stage redo)" } elseif ($view.terminalCount -eq $view.flow_taskCount -and $view.flow_taskCount -gt 0) { "all tasks terminal — conclude: delivery-bridge.cmd -Command conclude -RunId $RunId -Summary <...>" } else { "settle reported nodes; pushes are automatic (initial/unlock/reclaim/rollback + status touch); claimable now: [$($view.claimable -join ', ')]" })
        }
    }
}

function New-PlanResumeSteps {
    # plan steps for a resuming planner (long-task-planning): acceptance points
    # awaiting their settle + explicitly surfaced stage gates + the replan exit.
    param($Bridge)
    $steps = @()
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return $steps }
    foreach ($st in @($p['stages'])) {
        $ap = $st['acceptance_point']
        if (([string]$ap['status']) -eq 'grafted') {
            $steps += "Stage $($st['id']) acceptance node $($ap['node']) awaiting settle — run 'delivery-bridge.cmd -Command settle -RunId $RunId -NodeId $($ap['node'])' (阶段集成验收点真实执行); downstream stage gates stay closed until it passes."
        }
        # auditor-design-stage-review: 审查节点待 settle 续跑步骤（无段零增）
        $dr = $st['design_review']
        if ($null -ne $dr -and ([string]$dr['status']) -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace([string]$dr['node'])) {
            $steps += "Stage $($st['id']) design review node $($dr['node']) awaiting settle — the AUDITOR session reports its DesignReviewFile then run 'delivery-bridge.cmd -Command settle -RunId $RunId -NodeId $($dr['node'])'; pass 放行 IMPL，fail 自动触发重做波."
        }
        # auditor-subagent-review: 新链 ready 派审续跑步骤（无段零增）
        if ($null -ne $dr -and ([string]$dr['status']) -eq 'ready') {
            $steps += "Stage $($st['id']) design review is READY — 派五查评审子代理（rdd-engine/references/review-input-template.md 机械清单，独立上下文）产出 DesignReviewFile 后 run 'delivery-bridge.cmd -Command design-review -Action submit -RunId $RunId -Stage $($st['id'])'; pass 放行 IMPL，fail 自动触发重做波."
        }
    }
    foreach ($key in @($Bridge.tasks.Keys)) {
        $blockers = Get-PlanGateBlockers $Bridge ([int]$key)
        if ($blockers.Count -gt 0) {
            $steps += "Task #$key is stage-gated (waiting on acceptance point(s): [$($blockers -join ', ')]) — clear via the acceptance node settles, or replan: 'delivery-bridge.cmd -Command replan -RunId $RunId -PlanFile <revised plan> -Reason <deviation>' (滚动修正唯一入口)."
        }
    }
    return $steps
}

function New-ResumeSteps {
    # breakpoint step list core (tree/flow recovery steps) for a fresh planner
    # session; auto_mode and plan steps are appended by the caller.
    param($View)
    $steps = @()
    if ($View.tree.state -eq "concluded") {
        $steps += "Run already concluded. Final report: report/final-report.md; delivery annex: report/delivery-annex.md."
        return $steps
    }
    $steps += "Round $($View.tree.round.open) is open since $($View.tree.round.open_started_at) — the bridge keeps one round open for the whole delivery; conclude closes it."
    foreach ($n in @(Convert-ToSafeArray $View.tree.nodes.reported)) {
        $id = if ($n -is [string]) { $n } else { $n.id }
        $steps += "Reported node awaiting settle: $id — run 'delivery-bridge.cmd -Command settle -RunId $RunId -NodeId $id' (three evidence checks gate the transition)."
    }
    if (@($View.flagged_deliveries).Count -gt 0) {
        $steps += "Unqualified reported delivery(ies) (settle will refuse): $(@($View.flagged_deliveries | ForEach-Object { $_.node }) -join ', ') — 'delivery-bridge.cmd -Command rollback -RunId $RunId -NodeId <id> -To <roles> -Phase <REQ|DESIGN|IMPL|VERIFY> -Reason <why>' (explicit cross-phase rollback target) or 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId <id>' (redo the same stage)."
    }
    if ($View.claimable.Count -gt 0) {
        $steps += "Dispatch sessions for claimable nodes: [$($View.claimable -join ', ')] — 'delivery-bridge.cmd -Command dispatch -RunId $RunId -NodeId <id>'."
    }
    if ($View.dead_claims.tree.Count -gt 0) {
        $steps += "Recover dead claims: $(@($View.dead_claims.tree | ForEach-Object { $_.node }) -join ', ') — 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId <id>'."
    }
    if ($View.repair.remaining.Count -gt 0) {
        $steps += "pending_sync divergence still unresolved (status retries the repair on every call): $(@($View.repair.remaining | ForEach-Object { "$($_.node):$($_.op)" }) -join ', ')."
    }
    if ($View.terminalCount -eq $View.flow_taskCount -and $View.flow_taskCount -gt 0) {
        $steps += "All tasks terminal — conclude with a summary."
    }
    $steps += "Reported nodes are never re-consumed; duplicate sessions get deterministic conflict feedback from bridge claim."
    return $steps
}

function New-DerivationResumeSteps {
    # 需求派生断点（planner-midrun-derive）：proposed 待裁决 / registered 待
    # 吸收都是续跑规划者的显式动作点。
    param([string]$RunIdText, $Bridge)
    $steps = @()
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        $st = [string]$d['status']
        if ($st -eq 'proposed') {
            $steps += "Derivation $($d['id'])「$($d['title'])」 proposed — present it to the user, then 'delivery-bridge.cmd -Command derive -RunId $RunIdText -Action confirm -DerivationId $($d['id']) -UserVerdict <用户裁决原文>' or '-Action withdraw -DerivationId $($d['id'])'."
        }
        elseif ($st -eq 'registered' -and -not ($d['absorbed'] -eq $true)) {
            $steps += "Derivation $($d['id']) registered as task #$($d['task_id']) but unabsorbed — replan it into the stages: 'delivery-bridge.cmd -Command replan -RunId $RunIdText -PlanFile <revised plan incl. task #$($d['task_id'])> -Reason <deviation>' (its chain stays NODE_BLOCKED_BY_GATE until then)."
        }
    }
    return @($steps)
}

function Invoke-BridgeResume {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $view = Get-BridgeOverview $runDir $bridge

    # planner body roster row (planner-session-roster): a resuming planner
    # session joins the roster (advisory, idempotent by session_id; the roster
    # then shows every session that ever orchestrated this run).
    $null = Register-PlannerBody -RunDir $runDir -RunIdText $RunId

    $steps = @(New-ResumeSteps $view)

    # pure-auto-mode breakpoint visibility (planner-auto-mode): open
    # escalations ARE the unattended-run breakpoints — a resuming planner
    # presents each to the user and records the verdict (decide -Kind
    # resolution). Absent on legacy runs (byte-identical resume).
    $autoModeBlock = $null
    if ($null -ne (Get-AutoModeSection $bridge)) {
        $autoModeBlock = Get-AutoModeDecisionView $runDir $bridge $view.tree
        foreach ($esc in @($autoModeBlock.open_escalations)) {
            $hist = if ($esc.historical) { " [historical: node $($esc.node) pruned]" } else { "" }
            $steps += "Open escalation${hist}: $($esc.entry_id) @ node $($esc.node) ($($esc.stage)) checkpoint '$($esc.checkpoint)' — present to the user, then record: delivery-bridge.cmd -Command decide -RunId $RunId -NodeId $($esc.node) -Kind resolution -RefEntry $($esc.entry_id) -Checkpoint '$($esc.checkpoint)' -Decision <user verdict>."
        }
    }

    # long-task-planning plan view + plan steps (pending acceptance points and
    # stage gates ARE breakpoints too). plan=$null degrades legacy runs.
    $planView = Get-PlanView $runDir $bridge
    $steps += @(New-PlanResumeSteps $bridge)
    $steps += @(New-DerivationResumeSteps $RunId $bridge)

    # 并行协作冲突治理(parallel-coordination):未决冲突也是断点——续跑规划者
    # 按 kind 续处(调和/上报/挂起),无冲突任务不被阻塞。
    $cv = $view.conflicts
    foreach ($e in @($cv.open)) {
        $steps += "Unresolved conflict $($e['id']) (kind=$($e['kind']), status=$($e['status']), nodes [$($e['nodes'] -join ', ')], files [$($e['files'] -join ', ')]) — 处置:调和产出一致结论后 'delivery-bridge.cmd -Command conflict -RunId $RunId -Action resolve -ConflictId $($e['id']) -Ruling <结论>'(文件冲突可 -Serialize <早者节点> 串行化);无法调和 → -Action open -ConflictId $($e['id']) -ConflictStatus escalated -Escalation '<呈用户的问题>' 上报用户裁决;用户不在场 → -ConflictStatus suspended 挂起涉事链并上报(不阻塞无冲突任务)。硬约束:不得默默二选一。"
    }
    foreach ($dv in @($cv.citation_deviations)) {
        $steps += "回执偏差(软核对): $($dv['node']) @ $($dv['doc']) citations 超出变更地图文件集 [$($dv['refs'] -join ', ')] — 核对变更地图是否漏报/写错。"
    }

    return @{
        success = $true
        data    = [ordered]@{
            run_id         = $RunId
            archive        = $bridge.archive_rel
            state          = $view.tree.state
            breakpoint     = [ordered]@{
                hanging_round = $view.tree.round.open
                tasks_terminal = "$($view.terminalCount)/$($view.flow_taskCount)"
                pending_sync  = @($view.repair.remaining | ForEach-Object { "$($_.node):$($_.op)" })
            }
            tasks          = $view.task_rows
            claimable      = $view.claimable
            dead_claims    = $view.dead_claims
            dependencies   = $view.dependencies
            auto_mode      = $autoModeBlock
            plan           = $planView
            conflicts      = $view.conflicts
            derivations    = @(New-DerivationViewRows $bridge)
            recovery_steps = $steps
            lease          = $view.lease
        }
    }
}

# === Command: conclude ===

function Resolve-ConcludeReviewState {
    # review-gate exemption sets (planner-requirement-review): tasks the planner
    # rejected back to PM stay active@PM BY DESIGN; merged tasks document their
    # in-tree absorption. Returns both maps + the pending reject id list.
    param($Bridge, $Flow)
    $rejectReturned = @{}
    $mergedInto = @{}
    if ((Test-PropPresent $Bridge 'review') -and $null -ne $Bridge['review']) {
        foreach ($v in @(Convert-ToSafeArray $Bridge['review']['verdicts'])) {
            if ($null -eq $v) { continue }
            if (([string]$v['verdict']) -eq 'reject_return') { $rejectReturned[[int]$v['task_id']] = $true }
            if (([string]$v['verdict']) -eq 'tree_adjudicated' -and (Test-PropPresent $v 'merged_into_task_id') -and $null -ne $v['merged_into_task_id']) {
                $mergedInto[[int]$v['task_id']] = [int]$v['merged_into_task_id']
            }
        }
    }
    $pendingRejectIds = @($Flow.tasks | Where-Object {
        $rejectReturned.Contains([int]$_.id) -and (([string]$_.lifecycle) -notin @("completed", "deprecated"))
    } | ForEach-Object { [int]$_.id })
    return @{ reject_returned = $rejectReturned; merged_into = $mergedInto; pending_reject_ids = $pendingRejectIds }
}

function Test-ConcludeDeliveryComplete {
    # DELIVERY_INCOMPLETE (every task terminal except the exempt reject_return
    # set) + TREE_NOT_SETTLED (every bridge-mapped delivery node terminal; the
    # structural root n1 and the acceptance chain never block here — the
    # acceptance gate below owns the chain).
    param($Bridge, $Flow, $RejectReturned, $TreeData)
    $notTerminal = @($Flow.tasks | Where-Object {
        (([string]$_.lifecycle) -notin @("completed", "deprecated")) -and (-not $RejectReturned.Contains([int]$_.id))
    })
    if ($notTerminal.Count -gt 0) {
        Write-ErrorResult "DELIVERY_INCOMPLETE" "Not all tasks are terminal yet: $(@($notTerminal | ForEach-Object { "#$($_.id)($($_.lifecycle)) @$($_.currentOwners -join '+')" }) -join ', '). Settle/prune the remaining work first." 1
    }
    $mappedPending = @()
    foreach ($p in @(Convert-ToSafeArray $TreeData.nodes.pending)) {
        if ($null -ne (Get-NodeTaskStage $Bridge ([string]$p))) { $mappedPending += [string]$p }
    }
    $mappedClaimed = @()
    foreach ($c in @(Convert-ToSafeArray $TreeData.nodes.claimed)) {
        $cid = if ($c -is [string]) { $c } else { [string]$c.id }
        if ($null -ne (Get-NodeTaskStage $Bridge $cid)) { $mappedClaimed += $cid }
    }
    if ($mappedPending.Count -gt 0 -or $mappedClaimed.Count -gt 0) {
        Write-ErrorResult "TREE_NOT_SETTLED" "Tree still has pending/claimed delivery nodes: pending=[$($mappedPending -join ',')] claimed=[$($mappedClaimed -join ',')]. Settle or prune them first." 1
    }
}

function Resolve-ConcludeAnchor {
    # anchor (goal-tree-goal-root): the goal root is the conclude anchor —
    # goal-tree validates it by root semantics (all direct children terminal).
    # Applies only when the node actually carries type=goal (v2 promulgations);
    # a legacy-shaped run falls through to the legacy anchor resolution.
    # NOTE: Get-NodeFromTree serves the status view (bare {id,status}) and the
    # goal root stays pending forever — read type=goal from state/tree.json.
    param([string]$RunDir, $Bridge, $Flow, $TreeData)
    $anchor = $null
    $rootNode = $null
    $anchorType = $null
    if ((Test-PropPresent $Bridge 'goal_root') -and $Bridge.goal_root) {
        $rootNode = Read-TreeFullNode $RunDir ([string]$Bridge.goal_root)
        if ($null -ne $rootNode -and [string]$rootNode.type -eq 'goal') { $anchor = [string]$Bridge.goal_root; $anchorType = 'goal' }
    }
    if ($null -eq $anchor) {
        foreach ($t in $Flow.tasks) {
            $taskId = [int]$t.id
            if ($Bridge.tasks.Contains("$taskId")) {
                $bStages = $Bridge.tasks["$taskId"]['stages']
                if ($null -ne $bStages -and $bStages.Contains('QA')) { $anchor = [string]$bStages['QA'] }
            }
        }
    }
    if ($null -eq $anchor) {
        $doneList = @($TreeData.nodes.done)
        if ($doneList.Count -gt 0) { $anchor = [string]$doneList[-1] }
    }
    if ($null -eq $anchor) { Write-ErrorResult "ANCHOR_UNRESOLVED" "No done node found to anchor the achieved conclusion" 1 }
    return @{ anchor = $anchor; anchor_type = $anchorType; root_node = $rootNode }
}

function New-AnnexTaskTableLines {
    # 「任务终态」table: per-task terminal state + phase chain, with the review-
    # gate annotations (merged = absorbed in-tree, pending rejects = active@PM).
    param($Bridge, $Flow, $TreeData, $MergedInto, $PendingRejectIds)
    $lines = @()
    $lines += "## 任务终态"
    $lines += ""
    $lines += "| Task | 标题 | 终态 | 阶段链 |"
    $lines += "|------|------|------|--------|"
    foreach ($t in $Flow.tasks) {
        $taskId = [int]$t.id
        $chain = "-"
        if ($Bridge.tasks.Contains("$taskId")) {
            $bStages = $Bridge.tasks["$taskId"]['stages']
            if ($null -ne $bStages) {
                # phase-model display: parallel group "∥", phases "→" (Format-
                # StageChain iterates RoleOrder — PM heads included)
                $cPhase = [string]$t.phase
                if ([string]::IsNullOrEmpty($cPhase)) { $cPhase = "" }
                $chain = Format-StageChain $bStages $TreeData $cPhase
            }
        }
        $termCell = [string]$t.lifecycle
        if ($MergedInto.Contains($taskId)) {
            $termCell = "$termCell（树内合并至 #$($MergedInto[$taskId])，非放弃）"
        }
        elseif ($PendingRejectIds -contains $taskId) {
            $termCell = "$termCell（驳回回流 PM，修订中）"
        }
        $lines += "| $taskId | $([string]$t.title) | $termCell | $chain |"
    }
    $lines += ""
    return $lines
}

function New-DeliveryAnnex {
    # delivery-annex.md assembly: header + root-goal achievement state + 任务终态
    # +「整体验收结论」区 (overall-delivery) + check issues + planner summary.
    param([string]$RunId, [string]$RunDir, $Bridge, $Flow, $TreeData, [bool]$CheckOk, $CheckIssues,
          [string]$SummaryText, $RootNode, $PendingRejects, $PendingRejectIds, $MergedInto, [string]$Conclusion)
    $annexDir = Join-Path $RunDir "report"
    if (-not (Test-Path -LiteralPath $annexDir)) { New-Item -ItemType Directory -Path $annexDir -Force | Out-Null }
    $lines = @()
    $lines += "# 交付结案附录 — $RunId"
    $lines += ""
    $lines += "- 归档: $($Bridge.archive_rel)"
    $lines += "- 结案时间: $(Get-UtcNowIso) · 发起: $($Bridge.created_by)"
    $lines += "- rdd-flow check: $(if ($CheckOk) { '通过（0 issues）' } else { "发现问题 $($CheckIssues.Count) 条" })"
    if ((Test-PropPresent $Bridge 'goal_root') -and $Bridge.goal_root -and (Test-PropPresent $Bridge 'goal') -and $null -ne $RootNode -and [string]$RootNode.type -eq 'goal') {
        # root-goal achievement state (goal-tree-goal-root AC-2): the original
        # requirement reached its final objective — every sub-requirement terminal
        # (goal-tree concluded the run anchored on the type=goal root). Review-
        # rejected sub-requirements pending at PM make it PARTIAL, rendered
        # honestly (never dressed up as complete) — acceptance 3 / edge #3.
        $goalTitle = if ($Bridge.goal.Contains('title')) { [string]$Bridge.goal['title'] } else { "-" }
        if (@($PendingRejects).Count -eq 0) {
            $lines += "- 根目标: **达成** — goal 根 $($Bridge.goal_root)「$goalTitle」全部直接子需求节点终态（原始需求=最终目标）"
        } else {
            $lines += "- 根目标: **部分达成（$(@($PendingRejects).Count) 条驳回回流 PM，见任务终态表）** — goal 根 $($Bridge.goal_root)「$goalTitle」交付节点全部终态；驳回项 active@PM 为真实状态，修订后经后续 run/正常流程承接"
        }
    }
    $lines += ""
    $lines += New-AnnexTaskTableLines $Bridge $Flow $TreeData $MergedInto $PendingRejectIds
    $lines += Add-AcceptanceAnnexLines $Bridge $Conclusion
    $lines += Add-PlanAnnexLines $RunDir $Bridge $Flow.tasks
    # 并行冲突治理记录引用(parallel-coordination):conclude 不新增硬门(涉事任务
    # 未终态由 DELIVERY_INCOMPLETE 兜底),annex 如实引用冲突治理记录。
    $lines += Add-ConflictAnnexLines $Bridge
    # 需求派生清单区（planner-midrun-derive，留痕三联之三）+ 根目标达成口径
    # （含派生并入条数——单 run 收敛语义的结案呈现）。
    $ders = @(Get-DerivationSection $Bridge)
    if ($ders.Count -gt 0) {
        $live = @($ders | Where-Object { [string]$_['status'] -ne 'withdrawn' })
        if (@($PendingRejects).Count -eq 0) {
            $lines += "- 根目标口径补充: 含 $($live.Count) 条 run 中途派生需求并入（详见下方「需求派生」清单——单 run 收敛）"
        }
    }
    $lines += Add-DerivationAnnexLines $Bridge
    if (-not $CheckOk) {
        $lines += "## rdd-flow check 问题清单"
        $lines += ""
        foreach ($i in $CheckIssues) { $lines += "- $i" }
        $lines += ""
    }
    $lines += "## 规划者结案摘要"
    $lines += ""
    $lines += $SummaryText
    $lines += ""
    [System.IO.File]::WriteAllText((Get-AnnexPath $RunDir), ($lines -join "`n"), $script:Utf8NoBom)
}

function Complete-BridgeConclude {
    # conclude 收尾三联 + 编排裁定入账（统一决策账本，advisory）：rdd-flow
    # check → delivery annex → lease 释放 → ruling。返回 @{ checkOk;
    # checkIssues; ruling }（annex/lease 的输入由调用方备齐）。
    param([string]$RunId, [string]$RunDir, $Bridge, $Flow, $TreeData, $ReviewState, $AnchorInfo, [string]$SummaryText, $Conclusion)
    $chk = Invoke-RddFlow @("-Command", "check", "-Archive", $Bridge.archive)
    $checkOk = ($chk.exit -eq 0 -and $null -ne $chk.json -and $chk.json.success -and [int]$chk.json.data.issueCount -eq 0)
    $checkIssues = @()
    if ($null -ne $chk.json -and $chk.json.success) { $checkIssues = @(Convert-ToSafeArray $chk.json.data.issues) }
    $pendingRejects = @($Flow.tasks | Where-Object { $ReviewState.pending_reject_ids -contains [int]$_.id })
    New-DeliveryAnnex -RunId $RunId -RunDir $RunDir -Bridge $Bridge -Flow $Flow -TreeData $TreeData -CheckOk $checkOk `
        -CheckIssues $checkIssues -SummaryText $SummaryText -RootNode $AnchorInfo.root_node -PendingRejects $pendingRejects `
        -PendingRejectIds $ReviewState.pending_reject_ids -MergedInto $ReviewState.merged_into -Conclusion $Conclusion
    $null = Invoke-LeaseRelease $RunDir
    $ruling = Add-OrchestrationRuling -ArchivePath ([string]$Bridge.archive) -RunIdText $RunId -CommandName 'conclude' -DecisionText "conclude achieved（含派生并入: $(@(@(Get-DerivationSection $Bridge) | Where-Object { [string]$_['status'] -ne 'withdrawn' }).Count) 条）" -ReasonText $SummaryText -OptionsArr @('继续推进', '结案（achieved）')
    return @{ checkOk = $checkOk; checkIssues = $checkIssues; ruling = $ruling }
}

function Invoke-BridgeConclude {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($Summary)) { Write-ErrorResult "MISSING_SUMMARY" "-Summary is required (closing summary for the delivery)" 1 }

    $null = Enter-PlannerLease $runDir

    $flow = Read-ArchiveTasks $bridge.archive
    $reviewState = Resolve-ConcludeReviewState $bridge $flow
    $treeData = Get-TreeStatusView $RunId
    Test-ConcludeDeliveryComplete $bridge $flow $reviewState.reject_returned $treeData
    # derivation hard gate (planner-midrun-derive, acceptance 7): open derivations
    # (proposed/confirmed, or a registered derived task not terminal) block the
    # conclude — a run with mid-run derivations concludes only when resolved.
    Test-ConcludeDerivations $bridge $flow

    # acceptance hard gate (overall-delivery): the whole-requirement ACCEPT
    # conclusion must be decidable AND 通过 — reported BEFORE any goal-anchor
    # work (ACCEPTANCE_PENDING / ACCEPTANCE_NOT_PASSED have priority over the
    # anchor codes). Runs without criteria (exempt/declared/legacy) pass through.
    $gate = Get-AcceptanceGateVerdict $bridge ([string]$bridge.archive)
    if (-not $gate.ok) { Write-ErrorResult $gate.code $gate.message 1 }
    # stage acceptance hard gate (long-task-planning, same family — after the
    # ACCEPTANCE_* gate so legacy/whole-requirement codes keep their priority):
    # every stage's acceptance point must be passed before anchoring achieved.
    $planGate = Get-PlanConcludeVerdict $bridge
    if (-not $planGate.ok) { Write-ErrorResult $planGate.code $planGate.message 1 }
    $conclusion = $null
    if ((Test-PropPresent $gate 'conclusion')) { $conclusion = [string]$gate.conclusion }

    $anchorInfo = Resolve-ConcludeAnchor $runDir $bridge $flow $treeData

    # 1) goal-tree conclude (auto-closes the open round; renders final-report.md)
    $r = Invoke-GoalTree @("-Command", "conclude", "-RunId", $RunId, "-Outcome", "achieved", "-AnchorNodeId", $anchorInfo.anchor, "-Summary", $Summary)
    if ($r.exit -ne 0 -or -not $r.json.success) {
        Write-ErrorResult "TREE_CONCLUDE_FAILED" "goal-tree conclude failed: $($r.text)" 3
    }

    # 2) rdd-flow check + 3) delivery annex + 4) lease release (+ ruling)
    $done = Complete-BridgeConclude $RunId $runDir $bridge $flow $treeData $reviewState $anchorInfo $Summary $conclusion
    $checkOk = $done.checkOk
    $checkIssues = @($done.checkIssues)
    $ruling = $done.ruling

    return @{
        success = $true
        data    = @{
            run_id         = $RunId
            concluded      = $true
            outcome        = "achieved"
            anchor_node    = $anchorInfo.anchor
            anchor_type    = $anchorInfo.anchor_type
            acceptance     = $(if ($null -ne $conclusion) { @{ conclusion = $conclusion } } else { $null })
            plan           = Get-PlanView $runDir $bridge
            flow_check     = @{ ok = $checkOk; issues = $checkIssues }
            final_report   = ".rdd/goal-trees/$RunId/report/final-report.md"
            delivery_annex = ".rdd/goal-trees/$RunId/report/delivery-annex.md"
            tasks_terminal = "$(@($flow.tasks | Where-Object { (([string]$_.lifecycle) -in @("completed", "deprecated")) -or $reviewState.reject_returned.Contains([int]$_.id) }).Count)/$($flow.tasks.Count)"
            reject_return_pending = @($reviewState.pending_reject_ids)
            derivations    = @(New-DerivationViewRows $bridge)
            decision_ledger = $(if ($ruling.entry) { @{ entry_id = [string]$ruling.entry['entry_id'] } } else { $null })
        }
    }
}

# === Command: lease ===

function Invoke-BridgeLease {
    $runDir = Get-BridgeRunDir $RunId
    Require-Bridge $runDir | Out-Null

    if ($Release) {
        $res = Invoke-LeaseRelease $runDir
        return @{ success = $true; data = @{ run_id = $RunId; action = "release"; released = $res.released } }
    }
    if ($Acquire) {
        $res = Invoke-LeaseAcquire $runDir
        return @{ success = $true; data = @{ run_id = $RunId; action = "acquire"; holder = $res.holder; taken_over_from = $res.taken_over_from; stale_minutes = $LeaseStaleMinutes } }
    }
    $state = Get-LeaseState $runDir
    return @{ success = $true; data = @{ run_id = $RunId; action = "show"; lease = $state } }
}

# === Command: register-session (planner-session-roster) ===

function Invoke-BridgeRegisterSession {
    # 直交登记入口：after a direct (off-tree) start-role dispatch the planner
    # registers the created dsh session here so the roster keeps it traceable
    # (the 2026-09-20 stray-dispatch incident: off-tree sessions had ZERO
    # registration — the roster closes that gap). Explicit command shape: the
    # sessionId arrives from start-role's printed output, the label from the
    # dispatch's -SessionLabel (or handoff file basename).
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($SessionId)) { Write-ErrorResult "MISSING_SESSION_ID" "-SessionId (the dsh session id start-role printed) is required" 1 }
    if ($SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Write-ErrorResult "SESSION_ID_INVALID" "-SessionId must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ : $SessionId" 1 }
    if ([string]::IsNullOrWhiteSpace($Role) -or $script:WorkerRoles -notcontains $Role) { Write-ErrorResult "ROLE_INVALID" "-Role must be one of $($script:WorkerRoles -join '/') for a direct-handoff registration (the PLANNER body self-registers via promulgate/resume)" 1 }
    if ([string]::IsNullOrWhiteSpace($Label)) { Write-ErrorResult "LABEL_REQUIRED" "-Label (the direct-handoff tag shown in the [直交] title) is required" 1 }

    $null = Enter-PlannerLease $runDir

    $title = "[直交] $Label·$Role"
    $r = Add-RosterEntry -RunDir $runDir -RunIdText $RunId -SessionId $SessionId -Role $Role -Node $null -Label $Label -Source "direct" -Title $title
    if (-not $r.ok) { Write-ErrorResult "ROSTER_WRITE_FAILED" "sessions.json write failed: $($r.error)" 3 }
    return @{
        success = $true
        data    = @{
            run_id      = $RunId
            registered  = $true
            session     = $r.entry
            roster_size = @((Read-Roster $runDir).sessions).Count
            next_step   = "roster visible via: delivery-bridge.cmd -Command status -RunId $RunId (sessions field)"
        }
    }
}

# === Commands: decide / escalate (planner-auto-mode) ===

function Get-DecisionGateContext {
    # Shared preflight for both decision commands. Returns
    # @{ run_dir; bridge; auto_mode; mapping; node; node_status }.
    # Gates (deterministic errors, exit 1):
    #   AUTO_MODE_DISABLED      run not promulgated with -AutoMode
    #   NODE_NOT_MAPPED         node not in the bridge mapping
    #   DECISION_NODE_NOT_CLAIMED  node not in this stage's claimed state
    #                            (overturn additionally tolerates reported — the
    #                            pre-settle in-session redo window)
    param([string]$KindContext)   # "auto"|"escalation"|"resolution"|"overturn"
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $am = Get-AutoModeSection $bridge
    if ($null -eq $am) {
        Write-ErrorResult "AUTO_MODE_DISABLED" "Run $RunId was not promulgated with -AutoMode — checkpoint auto-decisions are disabled (re-promulgate with -AutoMode to enable; the default posture is manual confirmation)" 1
    }

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $stage = $mapping.stage
    $taskId = $mapping.task_id

    # tree-side node state (read-only view; status-normalized — the raw view's
    # claimed/reported rows carry no status field, see Get-NodeViewState)
    $treeData = Get-TreeStatusView $RunId
    $nodeState = Get-NodeViewState $treeData $NodeId
    $nodeStatus = if ($nodeState) { [string]$nodeState.status } else { "missing" }
    $claimedByStage = ($nodeStatus -eq "claimed" -and [string]$nodeState.claimed_by -eq $stage)
    $allowed = $claimedByStage
    if ($KindContext -eq "overturn" -and $nodeStatus -eq "reported") { $allowed = $true }
    if (-not $allowed) {
        $who = if ($nodeState -and $nodeState.claimed_by) { " (claimed_by=$($nodeState.claimed_by))" } else { "" }
        Write-ErrorResult "DECISION_NODE_NOT_CLAIMED" "Node $NodeId is '$nodeStatus'$who — decision commands require this stage's ($stage) claimed node$(if ($KindContext -eq 'overturn') { ' (overturn also tolerates reported: the pre-settle redo window)' }). Claim it first: delivery-bridge.cmd -Command claim -RunId $RunId -NodeId $NodeId -Role $stage" 1
    }

    return @{ run_dir = $runDir; bridge = $bridge; auto_mode = $am; mapping = $mapping; node_state = $nodeState; node_status = $nodeStatus; tree = $treeData }
}

function Find-PolicyRule {
    # Locate a rule in the run's policy snapshot by id; $null when absent (the
    # one lookup shared by decide's auto-kind gate and escalate's optional
    # rule-id check — first-match table semantics live at the WORKER's grading
    # step; here it is plain id resolution).
    param($AutoMode, [string]$RuleIdText)
    foreach ($r in @(Convert-ToSafeArray $AutoMode['policy']['rules'])) {
        if ($null -ne $r -and ([string]$r['id']) -eq $RuleIdText) { return $r }
    }
    return $null
}

function New-DecisionEntryPayload {
    # Ordered decide/escalate entry hashtable — the design's single field list
    # (at / run_id / node_id / task_id / stage / kind / checkpoint / risk /
    # rule_id / decision / inputs / basis / decider / ref_entry; entry_id is
    # assigned by Add-DecisionEntry inside the lock). $RiskFallback: escalate
    # defaults a missing risk to "high", decide leaves it null. Reads the
    # script-scope command params ($RunId/$NodeId/$Checkpoint/$Decision/$Risk/
    # $Inputs/$Basis) like every other command function here.
    param([string]$KindText, [int]$TaskIdNum, [string]$Stage, [string]$RiskFallback, $Decider, $RuleIdOut, $RefEntryOut)
    return [ordered]@{
        at         = Get-UtcNowIso
        run_id     = $RunId
        node_id    = $NodeId
        task_id    = $TaskIdNum
        stage      = $Stage
        kind       = $KindText
        checkpoint = $Checkpoint
        risk       = $(if (-not [string]::IsNullOrWhiteSpace($Risk)) { $Risk } elseif (-not [string]::IsNullOrWhiteSpace($RiskFallback)) { $RiskFallback } else { $null })
        rule_id    = $RuleIdOut
        decision   = $Decision
        inputs     = $(if (-not [string]::IsNullOrWhiteSpace($Inputs)) { $Inputs } else { $null })
        basis      = $(if (-not [string]::IsNullOrWhiteSpace($Basis)) { $Basis } else { $null })
        decider    = $Decider
        ref_entry  = $RefEntryOut
    }
}

function Get-DecisionKindContext {
    # Kind-specific argument context for decide — runs AFTER Get-DecisionGateContext
    # so error precedence is unchanged. Required-arg matrix, the rule-table gate
    # (auto must reference an action=auto rule of the run's snapshot; R1 grades
    # manual, hence mechanically unreachable), and the decider/rule_id/ref_entry
    # payload fields. Errors: CHECKPOINT_REQUIRED / DECISION_REQUIRED /
    # RULE_REQUIRED / REF_ENTRY_FORBIDDEN / RULE_NOT_FOUND / RULE_NOT_AUTO /
    # REF_ENTRY_REQUIRED.
    param($Gate)
    if ([string]::IsNullOrWhiteSpace($Checkpoint)) { Write-ErrorResult "CHECKPOINT_REQUIRED" "-Checkpoint (the checkpoint name this decision answers) is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Decision)) { Write-ErrorResult "DECISION_REQUIRED" "-Decision (the verdict text) is required" 1 }
    switch ($Kind) {
        'auto' {
            if ([string]::IsNullOrWhiteSpace($RuleId)) { Write-ErrorResult "RULE_REQUIRED" "-Kind auto requires -RuleId (the grading-table rule that authorizes this answer)" 1 }
            if (-not [string]::IsNullOrWhiteSpace($RefEntry)) { Write-ErrorResult "REF_ENTRY_FORBIDDEN" "-Kind auto must not carry -RefEntry (references are for resolution / overturn)" 1 }
            $rule = Find-PolicyRule $Gate.auto_mode $RuleId
            if ($null -eq $rule) {
                $ruleSummary = (@(Convert-ToSafeArray $Gate.auto_mode['policy']['rules']) | ForEach-Object { "$($_['id'])=$($_['action'])" }) -join ', '
                Write-ErrorResult "RULE_NOT_FOUND" "rule '$RuleId' is not in this run's risk-policy snapshot (first-match table: $ruleSummary)" 1
            }
            if ([string]$rule['action'] -ne 'auto') {
                Write-ErrorResult "RULE_NOT_AUTO" "rule '$RuleId' grades '$($rule['action'])' — manual-graded checkpoints must be escalated (delivery-bridge.cmd -Command escalate ...), never auto-answered" 1
            }
            return @{ decider = "auto/$RuleId@$($Gate.mapping.stage)"; rule_id = $RuleId; ref_entry = $null }
        }
        'resolution' {
            if ([string]::IsNullOrWhiteSpace($RefEntry)) { Write-ErrorResult "REF_ENTRY_REQUIRED" "-Kind resolution requires -RefEntry (the open escalation entry_id it answers)" 1 }
            return @{ decider = "user@in-session"; rule_id = $null; ref_entry = $RefEntry }
        }
        'overturn' {
            if ([string]::IsNullOrWhiteSpace($RefEntry)) { Write-ErrorResult "REF_ENTRY_REQUIRED" "-Kind overturn requires -RefEntry (the decision entry_id being overturned)" 1 }
            return @{ decider = "user@in-session"; rule_id = $null; ref_entry = $RefEntry }
        }
    }
}

function Test-DecisionRefEntry {
    # Race-sensitive ref-entry validation for decide resolution/overturn — the
    # Add-DecisionEntry in-lock callback (contract: (Entries, Context{kind, ref}),
    # fresh ledger inside the append's critical section; auto-kind entries carry
    # no ref, non-applicable kinds return immediately). Errors:
    # REF_ENTRY_NOT_FOUND / REF_ENTRY_NOT_ESCALATION / REF_ENTRY_KIND_INVALID /
    # ESCALATION_ALREADY_RESOLVED.
    param($Entries, $Context)
    if ($null -eq $Context) { return }
    $kindText = [string]$Context['kind']
    if ($kindText -notin @('resolution', 'overturn')) { return }
    $refId = [string]$Context['ref']
    $target = Find-DecisionEntry $Entries $refId
    if ($null -eq $target) {
        Write-ErrorResult "REF_ENTRY_NOT_FOUND" "-RefEntry '$refId' does not exist in this archive's decision ledger (archive-level lookup — cross-node references are tolerated)" 1
    }
    $targetKind = [string]$target['kind']
    if ($kindText -eq 'resolution' -and $targetKind -ne 'escalation') {
        Write-ErrorResult "REF_ENTRY_NOT_ESCALATION" "-RefEntry '$refId' is kind='$targetKind' — resolution closes escalation entries (overturn is the channel for revising decisions)" 1
    }
    if ($kindText -eq 'overturn' -and $targetKind -eq 'overturn') {
        Write-ErrorResult "REF_ENTRY_KIND_INVALID" "-RefEntry '$refId' is itself an overturn — overturn the underlying decision instead of stacking meta-entries" 1
    }
    if ($kindText -eq 'resolution') {
        $refs = Get-ReferencedEntryIds $Entries
        if ($refs.Contains($refId)) {
            Write-ErrorResult "ESCALATION_ALREADY_RESOLVED" "escalation '$refId' is already closed by a resolution/overturn entry — a changed verdict goes through a NEW overturn of that closing entry" 1
        }
    }
}

function Test-DeriveRulingRefEntry {
    # derive confirm 的账本回调（Add-DecisionEntry in-lock 契约）：ruling 条目
    # 经 ref_entry 指向的必须是本派生的 derive_proposal 条目且尚未被其它 ruling
    # 关闭（DERIVE_ALREADY_CONFIRMED）。校验与追加共享临界区（竞态敏感）。
    param($Entries, $Context)
    if ($null -eq $Context) { return }
    $refId = [string]$Context['ref']
    $target = Find-DecisionEntry $Entries $refId
    if ($null -eq $target) {
        Write-ErrorResult "REF_ENTRY_NOT_FOUND" "-RefEntry '$refId' does not exist in the archive decision ledger" 1
    }
    if (([string]$target['kind']) -ne 'derive_proposal') {
        Write-ErrorResult "REF_ENTRY_NOT_DERIVE_PROPOSAL" "-RefEntry '$refId' is kind='$($target['kind'])' — the derive confirmation ruling must reference its own derive_proposal entry" 1
    }
    foreach ($e in @($Entries)) {
        if (([string]$e['kind']) -ne 'ruling') { continue }
        if (([string]$e['ref_entry']) -eq $refId -and (@($Context['derivation_ids']) -notcontains [string]$e['derivation_id'])) {
            Write-ErrorResult "DERIVE_ALREADY_CONFIRMED" "proposal '$refId' already carries a confirmation ruling ($($e['entry_id'])) — confirm is once per derivation (retry after DERIVE_BUDGET_EXCEEDED is NOT a thing: budget cannot grow mid-run; withdraw instead)" 1
        }
    }
}

function Get-DecideNextStep {
    # Per-kind post-write guidance (decide's next_step string; reads the
    # script-scope params $RuleId/$RefEntry/$Checkpoint like the callers).
    param([string]$KindText, $Entry, $View)
    switch ($KindText) {
        'auto'       { return "ledgered as $($Entry.entry_id) (rule $RuleId) — the confirmation gate for checkpoint '$Checkpoint' is satisfied; continue the stage work and leaf-report when done." }
        'resolution' { return "escalation $RefEntry closed by $($Entry.entry_id) — the waiting worker proceeds from the recorded verdict; open escalations remaining: $(@($View.open_escalations).Count)." }
        'overturn'   { return "decision $RefEntry overturned by $($Entry.entry_id) — redo the affected work in-session (pre-settle window); the chain stays auditable in decisions.jsonl." }
    }
    return $null
}

function Invoke-BridgeCheckpointDecide {
    # decide -Kind checkpoint（统一决策账本·角色检查点留痕，planner-midrun-
    # derive 决策 #3 全量接入）：五交付角色（PM/CTO/UX/DEV/QA）经用户确认的
    # 检查点决策入账——纪律性义务（SKILL 协议层），无 run / AutoMode / 节点
    # 绑定要求，归档级条目（-Archive 定位归档）。四要素 + decider=user。
    if ([string]::IsNullOrWhiteSpace($Archive)) { Write-ErrorResult "ARCHIVE_REQUIRED" "-Kind checkpoint requires -Archive <归档路径> (checkpoint entries are archive-scoped, no run binding)" 1 }
    if ([string]::IsNullOrWhiteSpace($Checkpoint)) { Write-ErrorResult "CHECKPOINT_REQUIRED" "-Checkpoint (the checkpoint name this decision answers) is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Decision)) { Write-ErrorResult "DECISION_REQUIRED" "-Decision (the verdict text) is required" 1 }
    $arch = $Archive
    if (-not [System.IO.Path]::IsPathRooted($arch)) { $arch = Join-Path $repoRoot $arch }
    if (-not (Test-Path -LiteralPath $arch -PathType Container)) { Write-ErrorResult "ARCHIVE_NOT_FOUND" "archive directory not found: $Archive (resolved: $arch)" 2 }
    $opts = @()
    if (-not [string]::IsNullOrWhiteSpace($Options)) {
        $opts = @(($Options -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    $payload = New-LedgerEntryPayload -KindText 'checkpoint' -RunIdText $RunId -BackgroundText $Background -OptionsArr $opts -DecisionText $Decision -ReasonText $Reason -DeciderText 'user'
    $payload['checkpoint'] = $Checkpoint
    $payload['role'] = $(if (-not [string]::IsNullOrWhiteSpace($Role)) { $Role } else { $null })
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath $arch) -LockDir $arch -Entry $payload
    return @{
        success = $true
        data    = @{
            archive    = $arch
            kind       = 'checkpoint'
            checkpoint = $Checkpoint
            entry      = $entry
            ledger     = "decisions.jsonl（归档级统一决策账本）"
            next_step  = "checkpoint '$Checkpoint' ledgered as $($entry.entry_id) — the confirmation record is on file; continue the flow."
        }
    }
}

function Invoke-BridgeDecide {
    # decide — ledger append for one checkpoint decision:
    #   -Kind auto        grading-table answer (rule must be action=auto);
    #                     decider = auto/<rule>@<stage>
    #   -Kind resolution  user verdict closing an open escalation (ref_entry);
    #                     decider = user@in-session
    #   -Kind overturn    in-session redo note over an existing decision (auto /
    #                     resolution / escalation target via ref_entry, archive-
    #                     level existence tolerated); decider = user@in-session
    #   -Kind checkpoint  archive-scoped role-checkpoint entry (five delivery
    #                     roles' user-confirmed decisions — no run/node binding);
    #                     four-element schema + decider=user
    # Composition (each piece ≤40 lines, ONE append chain): gate context ->
    # kind context -> Add-DecisionEntry (ref validation in-lock) -> view.
    if ([string]::IsNullOrWhiteSpace($Kind)) { Write-ErrorResult "DECISION_KIND_REQUIRED" "-Kind is required (auto / resolution / overturn / checkpoint)" 1 }
    if ($Kind -eq 'checkpoint') { return Invoke-BridgeCheckpointDecide }
    $g = Get-DecisionGateContext $Kind
    $k = Get-DecisionKindContext $g
    $payload = New-DecisionEntryPayload -KindText $Kind -TaskIdNum $g.mapping.task_id -Stage $g.mapping.stage -RiskFallback $null -Decider $k.decider -RuleIdOut $k.rule_id -RefEntryOut $k.ref_entry
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath ([string]$g.bridge.archive)) -LockDir ([string]$g.bridge.archive) -Entry $payload -ValidateCallback ${function:Test-DecisionRefEntry} -ValidateContext @{ kind = $Kind; ref = $RefEntry }
    $view = Get-AutoModeDecisionView $g.run_dir $g.bridge $g.tree
    return @{
        success = $true
        data    = @{
            run_id     = $RunId
            node_id    = $NodeId
            task_id    = $g.mapping.task_id
            stage      = $g.mapping.stage
            kind       = $Kind
            entry      = $entry
            open_escalations = @($view.open_escalations | ForEach-Object { $_.entry_id })
            next_step  = Get-DecideNextStep -Kind $Kind -Entry $entry -View $view
        }
    }
}

function Invoke-BridgeEscalate {
    # escalate — append an open escalation entry for a checkpoint the grading
    # table routes to humans (R1 hard floor / manual rule / no rule matched /
    # worker judgment). decider stays $null: no one has answered yet (the
    # pending-human state IS the escalation). Delivery: dsh watcher scans the
    # open entries into the Planner inbox (exactly-once); CLI/Plus see them in
    # status/resume. The worker WAITS — never proceeds past an open escalation.
    $g = Get-DecisionGateContext "escalation"
    if ([string]::IsNullOrWhiteSpace($Checkpoint)) { Write-ErrorResult "CHECKPOINT_REQUIRED" "-Checkpoint (the checkpoint name awaiting adjudication) is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Decision)) { Write-ErrorResult "DECISION_REQUIRED" "-Decision (the question presented to the user) is required" 1 }
    if (-not [string]::IsNullOrWhiteSpace($RuleId) -and $null -eq (Find-PolicyRule $g.auto_mode $RuleId)) {
        Write-ErrorResult "RULE_NOT_FOUND" "rule '$RuleId' is not in this run's risk-policy snapshot" 1
    }
    $ruleIdOut = $(if (-not [string]::IsNullOrWhiteSpace($RuleId)) { $RuleId } else { $null })
    $payload = New-DecisionEntryPayload -KindText "escalation" -TaskIdNum $g.mapping.task_id -Stage $g.mapping.stage -RiskFallback "high" -Decider $null -RuleIdOut $ruleIdOut -RefEntryOut $null
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath ([string]$g.bridge.archive)) -LockDir ([string]$g.bridge.archive) -Entry $payload
    return @{
        success = $true
        data    = @{
            run_id     = $RunId
            node_id    = $NodeId
            task_id    = $g.mapping.task_id
            stage      = $g.mapping.stage
            kind       = "escalation"
            entry      = $entry
            next_step  = "escalation $($entry.entry_id) is OPEN — dsh: the watcher delivers it to the Planner inbox (present it to the user); CLI/Plus: visible via status/resume. The worker WAITS at this checkpoint; the verdict lands via: delivery-bridge.cmd -Command decide -RunId $RunId -NodeId $NodeId -Kind resolution -RefEntry $($entry.entry_id) -Checkpoint '$Checkpoint' -Decision <verdict>."
        }
    }
}

# === Mid-run requirement derivation (planner-midrun-derive) ===
#
# run 中途范围缺口通道：规划者裁定 rollback（改既有）/ reclaim（同阶段重做）
# 都不对症（只管新增不管改既有）→ derive 经【用户确认硬门】派遣 PM 起草新
# 需求文档，受控入册后并入当前 run 的树与规划，单 run 收敛到结案。两项用户
# 拍板口径：(a) 新需求并入当前 run（非链式新 run）；(b) 用户确认门为硬门——
# 无确认记录的执行请求确定性拒绝（DERIVE_CONFIRMATION_MISSING）。
# 状态机（bridge.json 可选段 derivations[]，缺键 = 旧 run 逐字节不变）：
#   proposed → confirmed → registered；withdrawn 终态。确认细节单源引用归档
#   级决策账本 entry_id，不冗余存全文（决策 #9）。max_derivation 缺省 3
#   （promulgate -MaxDerivations 覆盖；超限 DERIVATION_LIMIT_WARNING 警告上
#   报不硬拒，决策 #8）。registered 未吸收期间 replan 覆盖校验白名单放行、
#   推送/认领闸门不豁免（NODE_BLOCKED_BY_GATE，出路只有 replan）——两方向
#   相反是有意设计。

$script:DeriveDefaultOwners = @("CTO", "UX", "QA")   # 决策 #10：缺省全链（DESIGN 相位角色集），-Owners 可缩窄

function Get-DerivationSection {
    # bridge.json derivations[]（深哈希表数组）；缺段 = @()（旧 run 兼容，conflicts 段先例）
    param($Bridge)
    if ($null -eq $Bridge -or -not (Test-PropPresent $Bridge 'derivations') -or $null -eq $Bridge['derivations']) { return @() }
    return @(Convert-ToSafeArray $Bridge['derivations'])
}

function Get-MaxDerivations {
    param($Bridge)
    if ($null -ne $Bridge -and (Test-PropPresent $Bridge 'max_derivation') -and $null -ne $Bridge['max_derivation'] -and [int]$Bridge['max_derivation'] -gt 0) { return [int]$Bridge['max_derivation'] }
    return 3
}

function Find-DerivationById {
    param($Bridge, [string]$DerId)
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        if (([string]$d['id']) -eq $DerId) { return $d }
    }
    return $null
}

function Find-DerivationByNode {
    # node → 未完结派生条目（confirm 后 settle 前的 PM 节点归属判定）
    param($Bridge, [string]$NodeId)
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        if (([string]$d['status']) -eq 'withdrawn') { continue }
        if ([string]$d['node'] -eq $NodeId) { return $d }
    }
    return $null
}

function Get-UnabsorbedDerivedTaskIds {
    # replan 白名单：已入册（registered）尚未被任何 plan 阶段吸收（absorbed≠true）
    # 的派生任务 id。吸收即标记——后续 replan 再把它移出阶段将恢复全覆盖校验
    # （白名单只覆盖 registered-unabsorbed 窗口期，不掩护丢弃）。
    param($Bridge)
    $ids = @()
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        if (([string]$d['status']) -ne 'registered') { continue }
        if (-not (Test-PropPresent $d 'task_id') -or $null -eq $d['task_id']) { continue }
        if ((Test-PropPresent $d 'absorbed') -and $d['absorbed'] -eq $true) { continue }
        $ids += [int]$d['task_id']
    }
    return @($ids)
}

function Find-DeriveConfirmation {
    # 确认门记录解析：账本中 ref_entry → proposed_entry 的 ruling 条目
    # （decider=user）。settle 入册前防御性复核 + confirm 后留痕单源。
    param($Entries, $Derivation)
    $target = [string]$Derivation['proposed_entry']
    foreach ($e in @($Entries)) {
        if (([string]$e['kind']) -ne 'ruling') { continue }
        if (([string]$e['ref_entry']) -ne $target) { continue }
        if ((Test-PropPresent $e 'decider') -and [string]$e['decider'] -eq 'user') { return $e }
    }
    return $null
}

function Read-TreeFullNodesRaw {
    # state/tree.json 全量节点只读探针（预算预检的节点普查 + goal root 活跃子
    # 女计数；Get-NodePruneReason 同款直读先例——桥绝不写引擎状态）。
    param([string]$RunDir)
    $p = Join-Path (Join-Path $RunDir "state") "tree.json"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    try {
        $obj = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return @(Convert-ToSafeArray $obj.nodes)
    }
    catch { return @() }
}

function Test-DeriveBudgetHeadroom {
    # confirm 侧预算预检（DEV 首查项核实结论：goal-tree start 只固化预算、graft
    # 时写前强制 WIDTH_EXCEEDED/NODES_EXCEEDED）——预算不足确定性报
    # DERIVE_BUDGET_EXCEEDED，不盲目 graft（卡 confirmed 不可自动重试）。
    # 一条派生链的保守增量：PM 节点 1 + 每链头 1 + IMPL/VERIFY 收敛 2 + 潜在
    # 新阶段验收节点 1 = owners.Count + 4；宽度增量：goal root 下 PM 节点 +
    # 潜在 [集成验收·S<k>] = 2。planner-guide 指引预期派生的 run 颁布时
    # -MaxNodes/-NodeWidth 预留余量。
    param([string]$RunDir, $Bridge, [string]$OwnerCount)
    $tree = Get-TreeStatusView ([string]$Bridge.run_id)
    $budget = $tree.budget
    $maxNodes = 0; $nodeWidth = 0
    if ($null -ne $budget) {
        $maxNodes = [int]$budget.max_nodes
        $nodeWidth = [int]$budget.node_width
    }
    $nodes = @(Read-TreeFullNodesRaw $RunDir)
    $needNodes = [int]$OwnerCount + 4
    if ($maxNodes -gt 0 -and (($nodes.Count + $needNodes) -gt $maxNodes)) {
        Write-ErrorResult "DERIVE_BUDGET_EXCEEDED" "Deriving this requirement would need ~$needNodes more nodes but the run budget is max_nodes=$maxNodes with $($nodes.Count) already grafted — the graft is NOT attempted (the derivation stays confirmed; budget cannot grow mid-run). Either withdraw it (-Action withdraw -DerivationId <id>), or finish this run and derive under a new run promulgated with -MaxNodes headroom (planner-guide: runs expected to derive should reserve budget at promulgate)." 1
    }
    $rootActive = 0
    foreach ($n in $nodes) {
        if (([string]$n.parent) -eq [string]$Bridge.goal_root -and ([string]$n.status) -ne 'pruned') { $rootActive++ }
    }
    if ($nodeWidth -gt 0 -and (($rootActive + 2) -gt $nodeWidth)) {
        Write-ErrorResult "DERIVE_BUDGET_EXCEEDED" "Deriving this requirement would add up to 2 goal-root children (PM node + a potential [集成验收·S<k>]) but node_width=$nodeWidth already has $rootActive active root children — the graft is NOT attempted (the derivation stays confirmed). Either withdraw it, or finish this run and derive under a new run promulgated with -NodeWidth headroom." 1
    }
}

function New-DeriveNodeTaskText {
    # 派生 PM 节点 task 文本（confirm 与 reclaim 重建共用的单源产出者）：
    # New-NodeTaskText 标准形（brief/summary 正则可解析）+ 使命段携带派生
    # 上下文与「overview『## 整体验收判据』增补条目」义务——判据经锚点 live
    # 读（DEV 首查项核实：现行实现即锚点引用），派生判据自然进验收门。
    param([string]$TitleText, [string]$RationaleText, [string]$RunIdText, [string]$ConfirmEntry, [string[]]$DepIds)
    $depsNote = ""
    if (@($DepIds).Count -gt 0) { $depsNote = "依赖既有任务 #" + (@($DepIds) -join '、#') + "（需求文档「依赖关系」字段如实标注，机读格式同构）。" }
    $rat = [string]$RationaleText
    if ($rat.Length -gt 200) { $rat = $rat.Substring(0, 199) + '…' }
    $mission = "使命：本需求为 run 中途派生（用户确认门已过，决策账本 $ConfirmEntry；缺口理由：$rat）。产出：requirements/ 下新需求文档（含验收标准与依赖关系），并在 requirements/overview.md 增补需求索引行与「## 整体验收判据」条目（判据经锚点 live 读，验收门自然覆盖派生需求）。$depsNote"
    return New-NodeTaskText -Title $TitleText -Stage 'PM' -ReqRel 'requirements/overview.md' -DesignRels @() -RunId $RunIdText -Mission $mission
}

function Test-DeriveProposeInputs {
    # propose 入参门（错误码族 DERIVE_*_REQUIRED/_INVALID）：Title/Rationale
    # 必填；-DependsOn 限本 run 已交付任务 id；-Owners 只能缩窄缺省全链
    # CTO+UX+QA（决策 #10）。返回 @{ depIds; ownerSet }。
    param($Bridge, [string]$DependsOnText, [string]$OwnersText)
    $depIds = @()
    if (-not [string]::IsNullOrWhiteSpace($DependsOnText)) {
        foreach ($d in ($DependsOnText -split ',')) {
            $di = 0
            if (-not [int]::TryParse($d.Trim(), [ref]$di) -or -not $Bridge.tasks.Contains("$di")) {
                Write-ErrorResult "DERIVE_DEP_INVALID" "-DependsOn entry '$($d.Trim())' is not a delivered task id of this run (delivered: $($(@($Bridge.tasks.Keys | Sort-Object) -join ',')))" 1
            }
            if ($depIds -notcontains $di) { $depIds += $di }
        }
    }
    # ⚠ 局部变量必须命名 $ownerSet：PS 变量名大小写不敏感，$owners 会与参数
    # $Owners 同变量互相覆盖（先落默认集 → 分支判断读到的永远是数组）。
    $ownerSet = @($script:DeriveDefaultOwners)
    if (-not [string]::IsNullOrWhiteSpace($OwnersText)) {
        $ownerSet = @(($OwnersText -split '\+') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ -ne '' })
        if ($ownerSet.Count -eq 0) { Write-ErrorResult "DERIVE_OWNERS_INVALID" "-Owners parsed to an empty set" 1 }
        foreach ($o in $ownerSet) {
            if (@($script:PhaseRoles['DESIGN']) -notcontains $o) {
                Write-ErrorResult "DERIVE_OWNERS_INVALID" "-Owners entry '$o' outside the DESIGN phase whitelist (CTO+UX+QA) — derive only NARROWS the default full chain (decision #10); PM heads the derived REQ node itself" 1
            }
        }
    }
    return @{ depIds = @($depIds); ownerSet = @($ownerSet) }
}

function New-DerivationRecord {
    # propose 登记落盘：账本 derive_proposal 条目（四要素 + 机读上下文）+
    # bridge derivations[] 追加 proposed 条目（全字段状态机起点）。
    # 返回 @{ entry; bridge }。
    param([string]$RunDir, $Bridge, [string]$RunIdText, [string]$DerId, [string]$TitleText, [string]$RationaleText, [int[]]$DepIds, [string[]]$OwnerSet)
    $options = @(
        "confirm：确认派生并入当前 run（用户裁决后经 -Action confirm 落地）"
        "withdraw：拒绝派生（留痕零副作用）"
        "维持现状：不派生，按既有范围收口（缺口如实呈报用户）"
    )
    $payload = New-LedgerEntryPayload -KindText 'derive_proposal' -RunIdText $RunIdText -BackgroundText "run 中途范围缺口：$RationaleText" -OptionsArr $options -DecisionText "提议派生新需求「$TitleText」并入当前 run" -ReasonText "rollback/reclaim 均不对症（只管新增不管改既有）；树外直交产物进不了当前树——derive 是唯一消化通道" -DeciderText 'planner'
    $payload['derivation_id'] = $DerId
    $payload['depends_on'] = @($DepIds)
    $payload['owners'] = @($OwnerSet)
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath ([string]$Bridge.archive)) -LockDir ([string]$Bridge.archive) -Entry $payload
    $derivations = @(Get-DerivationSection $Bridge)
    $derivations += @{
        id              = $DerId
        title           = $TitleText
        rationale       = $RationaleText
        depends_on      = @($DepIds)
        owners          = @($OwnerSet)
        status          = 'proposed'
        proposed_entry  = [string]$entry['entry_id']
        confirm_entry   = $null
        withdraw_entry  = $null
        node            = $null
        task_id         = $null
        requirement     = $null
        absorbed        = $false
        created_at      = Get-UtcNowIso
        confirmed_at    = $null
        registered_at   = $null
        withdrawn_at    = $null
    }
    $Bridge['derivations'] = $derivations
    Write-BridgeFile $RunDir $Bridge
    return @{ entry = $entry; bridge = $Bridge }
}

function Invoke-DerivePropose {
    # propose：登记提议（账本 derive_proposal 条目 + bridge derivations[]）
    # 并返回标准呈报文案——dsh 经 tool-ask-user 呈现，CLI/Plus 由规划者会话
    # 内呈现并留痕（需求验收 2 降级路径）。不 graft、不派遣（零副作用）。
    param([string]$RunDir, $Bridge)
    if ([string]::IsNullOrWhiteSpace($Title)) { Write-ErrorResult "DERIVE_TITLE_REQUIRED" "-Title (the new requirement's title) is required for -Action propose" 1 }
    if ([string]::IsNullOrWhiteSpace($Rationale)) { Write-ErrorResult "DERIVE_RATIONALE_REQUIRED" "-Rationale (the goal-gap rationale presented to the user) is required for -Action propose" 1 }
    $inputs = Test-DeriveProposeInputs $Bridge $DependsOn $Owners
    $depIds = @($inputs.depIds)
    $ownerSet = @($inputs.ownerSet)
    # 防滥用阈值（决策 #8）：超限警告上报，不硬拒
    $liveCount = @(Get-DerivationSection $Bridge | Where-Object { [string]$_['status'] -ne 'withdrawn' }).Count
    $maxDer = Get-MaxDerivations $Bridge
    $limitWarning = $null
    if (($liveCount + 1) -gt $maxDer) {
        $limitWarning = "DERIVATION_LIMIT_WARNING: this run already carries $liveCount non-withdrawn derivation(s) (max_derivation=$maxDer) — mid-run scope growth is abnormal, report the pace anomaly to the user (warning only, not rejected)"
    }
    # 派生号：max(未撤销数+1, 历史最大号+1) —— withdrawn 条目占号不复用（id 唯一
    # 是 Find-DerivationById 的前提，检索命中歧义不可接受）
    $maxN = 0
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        if ([string]$d['id'] -match '^DRV(\d+)$') { $n = [int]$Matches[1]; if ($n -gt $maxN) { $maxN = $n } }
    }
    $derId = "DRV$([Math]::Max($liveCount + 1, $maxN + 1))"
    $rec = New-DerivationRecord -RunDir $RunDir -Bridge $Bridge -RunIdText $RunId -DerId $derId -TitleText $Title -RationaleText $Rationale -DepIds $depIds -OwnerSet $ownerSet
    $entry = $rec.entry
    $present = "建议派生新需求「$Title」并入当前 run $RunId。缺口理由：$Rationale$(if (@($depIds).Count -gt 0) { '；依赖既有任务 #' + (@($depIds) -join '、#') })。请用户裁决：确认派生 → delivery-bridge.cmd -Command derive -RunId $RunId -Action confirm -DerivationId $derId -UserVerdict ""<用户裁决原文>""；拒绝 → -Action withdraw -DerivationId $derId。无确认记录不派遣（硬门）。"
    return @{
        success = $true
        data    = @{
            run_id         = $RunId
            action         = 'propose'
            derivation_id  = $derId
            status         = 'proposed'
            ledger_entry   = [string]$entry['entry_id']
            present_to_user = $present
            limit_warning  = $limitWarning
            next_step      = "present the proposal to the user verbatim (dsh: tool-ask-user; CLI/Plus: in-session, then record the verdict via confirm/withdraw). Nothing is grafted or dispatched yet."
        }
    }
}

function Invoke-DeriveConfirmGraft {
    # confirm 落地段（ruling 已入账、状态已 confirmed 之后）：graft PM 节点
    # （goal 根子节点，node.task 注入判据增补义务）→ node 落 derivations →
    # plan-log D 事件（deviation/scope_derived，决策 #7）→ 自动推送 PM 会话
    # （推送失败走既有推送账重试——session-create 类自动重试）。
    # 返回 @{ bridge; node_id; push }。
    param([string]$RunDir, $Bridge, $Derivation, [string]$DerId, [string]$ConfirmEntry)
    $taskText = New-DeriveNodeTaskText -TitleText ([string]$Derivation['title']) -RationaleText ([string]$Derivation['rationale']) -RunIdText $RunId -ConfirmEntry $ConfirmEntry -DepIds @($Derivation['depends_on'])
    $graftItem = @{
        title = [string]$Derivation['title']
        task  = $taskText
        role  = 'pm'
        ref   = "$(($RunId -replace '^deliver-', ''))/requirements/overview.md"
    }
    $g = Invoke-GraftOne $RunId ([string]$Bridge.goal_root) $graftItem
    if (-not $g.ok) { Write-ErrorResult "DERIVE_GRAFT_FAILED" "graft of the derivation PM node under the goal root failed (derivation $DerId stays confirmed, no node exists — retry confirm after the underlying cause is fixed): $($g.text)" 1 }
    $derivations = @(Get-DerivationSection $Bridge)
    foreach ($x in $derivations) {
        if ([string]$x['id'] -eq $DerId) { $x['node'] = $g.node_id }
    }
    $Bridge['derivations'] = $derivations
    Write-BridgeFile $RunDir $Bridge
    # 留痕：plan-log D 事件（kind=deviation + event=scope_derived，决策 #7）
    $rat = [string]$Derivation['rationale']
    if ($rat.Length -gt 120) { $rat = $rat.Substring(0, 119) + '…' }
    $null = Add-PlanEvent $RunDir 'deviation' 'scope_derived' $g.node_id $null 'PM' @{
        derivation    = $DerId
        title         = [string]$Derivation['title']
        rationale     = $rat
        ledger_entry  = $ConfirmEntry
        depends_on    = @($Derivation['depends_on'])
    }
    $push = Invoke-AutoDispatch $RunDir $Bridge "derive"
    return @{ bridge = $push.bridge; node_id = $g.node_id; push = $push }
}

function Invoke-DeriveConfirm {
    # confirm：过账本硬门（用户裁决原文 → ruling 条目）→ 预算预检 → graft
    # PM 节点（goal 根子节点，role=pm）→ 状态 confirmed + plan-log D 事件 →
    # 自动推送 PM 会话起草需求文档。顺序契约（设计风险表）：账本回填（事实
    # 永远记录）先行，预算不足确定性报 DERIVE_BUDGET_EXCEEDED 不盲目 graft
    # ——派生卡 confirmed 不可自动重试（预算 mid-run 不可增长）。
    param([string]$RunDir, $Bridge)
    $d = Find-DerivationById $Bridge $DerivationId
    if ($null -eq $d) { Write-ErrorResult "DERIVE_NOT_FOUND" "-DerivationId '$DerivationId' not found in run $RunId" 2 }
    if ([string]$d['status'] -ne 'proposed') { Write-ErrorResult "DERIVE_STATE_INVALID" "derivation $DerivationId is '$([string]$d['status'])' — confirm only applies to a 'proposed' derivation (withdrawn/confirmed/registered are settled states)" 1 }
    if ([string]::IsNullOrWhiteSpace($UserVerdict)) {
        Write-ErrorResult "DERIVE_CONFIRMATION_MISSING" "the user-confirmation gate is a HARD gate: -UserVerdict (the user's ruling verbatim) is the confirmation record itself — no record, no execution (final adjudication stays with the user)" 1
    }
    $options = @(
        "confirm：派生并入当前 run（本条目记录的用户裁决）"
        "withdraw：拒绝派生（零副作用）"
    )
    $payload = New-LedgerEntryPayload -KindText 'ruling' -RunIdText $RunId -BackgroundText "派生提议 $DerivationId「$([string]$d['title'])」：$([string]$d['rationale'])" -OptionsArr $options -DecisionText $UserVerdict -ReasonText "用户确认门（planner-midrun-derive 硬门）：mid-run 需求派生经用户裁决后执行" -DeciderText 'user' -RefEntryOut ([string]$d['proposed_entry'])
    $payload['derivation_id'] = $DerivationId
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath ([string]$Bridge.archive)) -LockDir ([string]$Bridge.archive) -Entry $payload -ValidateCallback ${function:Test-DeriveRulingRefEntry} -ValidateContext @{ ref = [string]$d['proposed_entry']; derivation_ids = @($DerivationId) }
    # 事实已入账 → 状态先落 confirmed（预算失败即卡此态，事实永远保留）
    $derivations = @(Get-DerivationSection $Bridge)
    foreach ($x in $derivations) {
        if ([string]$x['id'] -eq $DerivationId) {
            $x['status'] = 'confirmed'
            $x['confirm_entry'] = [string]$entry['entry_id']
            $x['confirmed_at'] = Get-UtcNowIso
        }
    }
    $Bridge['derivations'] = $derivations
    Write-BridgeFile $RunDir $Bridge
    Test-DeriveBudgetHeadroom -RunDir $RunDir -Bridge $Bridge -OwnerCount @($d['owners']).Count
    $grafted = Invoke-DeriveConfirmGraft -RunDir $RunDir -Bridge $Bridge -Derivation $d -DerId $DerivationId -ConfirmEntry ([string]$entry['entry_id'])
    return @{
        success = $true
        data    = @{
            run_id        = $RunId
            action        = 'confirm'
            derivation_id = $DerivationId
            status        = 'confirmed'
            ledger_entry  = [string]$entry['entry_id']
            node_id       = $grafted.node_id
            auto_push     = @{ trigger = $grafted.push.trigger; pushed = @($grafted.push.pushed); failed = @($grafted.push.failed) }
            next_step     = "PM session auto-pushed to draft the new requirement doc (+ overview「## 整体验收判据」augmentation). After it reports: settle -RunId $RunId -NodeId $($grafted.node_id) registers the task (add-task 代写 + DESIGN chain heads pre-grafted, held by the stage gate) — then replan absorbs task #<id> into the stages to unlock the chain."
        }
    }
}

function Invoke-DeriveWithdraw {
    # withdraw：拒绝留痕零副作用——账本 ruling 条目 + 状态 withdrawn；未
    # settle 的已 graft PM 节点 prune 掉（graft 是 confirm 的唯一副作用，
    # 撤销即回收）；已 registered 不可撤（任务在册，走 deprecate）。
    param([string]$RunDir, $Bridge)
    $d = Find-DerivationById $Bridge $DerivationId
    if ($null -eq $d) { Write-ErrorResult "DERIVE_NOT_FOUND" "-DerivationId '$DerivationId' not found in run $RunId" 2 }
    $st = [string]$d['status']
    if ($st -eq 'registered') { Write-ErrorResult "DERIVE_STATE_INVALID" "derivation $DerivationId is already registered as task #$([string]$d['task_id']) — withdraw cannot un-register a task; deprecate the task instead (rdd-flow deprecate)" 1 }
    if ($st -eq 'withdrawn') { Write-ErrorResult "DERIVE_STATE_INVALID" "derivation $DerivationId is already withdrawn" 1 }
    $payload = New-LedgerEntryPayload -KindText 'ruling' -RunIdText $RunId -BackgroundText "派生提议 $DerivationId「$([string]$d['title'])」被拒绝/撤回" -OptionsArr @("维持原范围收口", "派生并入当前 run") -DecisionText "$(if ([string]::IsNullOrWhiteSpace($Reason)) { 'withdraw：拒绝派生（零副作用）' } else { $Reason })" -ReasonText "derive 拒绝留痕（零副作用承诺）" -DeciderText 'user' -RefEntryOut ([string]$d['proposed_entry'])
    $payload['derivation_id'] = $DerivationId
    $entry = Add-DecisionEntry -LedgerPath (Get-ArchiveDecisionsPath ([string]$Bridge.archive)) -LockDir ([string]$Bridge.archive) -Entry $payload
    $prunedNode = $null
    $node = [string]$d['node']
    if (-not [string]::IsNullOrWhiteSpace($node)) {
        $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", $RunId, "-NodeId", $node, "-Reason", "derivation $DerivationId withdrawn before settle (zero side effects)")
        if ($rp.exit -ne 0 -or -not $rp.json.success) {
            Write-ErrorResult "DERIVE_WITHDRAW_PRUNE_FAILED" "prune of the grafted PM node $node failed (derivation NOT marked withdrawn — rerun withdraw after fixing): $($rp.text)" 1
        }
        $prunedNode = $node
    }
    $derivations = @(Get-DerivationSection $Bridge)
    foreach ($x in $derivations) {
        if ([string]$x['id'] -eq $DerivationId) {
            $x['status'] = 'withdrawn'
            $x['withdraw_entry'] = [string]$entry['entry_id']
            $x['withdrawn_at'] = Get-UtcNowIso
        }
    }
    $Bridge['derivations'] = $derivations
    Write-BridgeFile $RunDir $Bridge
    return @{
        success = $true
        data    = @{
            run_id        = $RunId
            action        = 'withdraw'
            derivation_id = $DerivationId
            status        = 'withdrawn'
            ledger_entry  = [string]$entry['entry_id']
            pruned_node   = $prunedNode
            next_step     = "refusal is on record (ledger $($entry['entry_id'])); no task was created$(if ($prunedNode) { ", node $prunedNode pruned" } else { '' }). Continue the run under the original scope."
        }
    }
}

function Invoke-BridgeDerive {
    # derive 命令编排：propose / confirm / withdraw（-Action）。
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $null = Enter-PlannerLease $runDir
    switch ($Action) {
        'propose'  { return Invoke-DerivePropose -RunDir $runDir -Bridge $bridge }
        'confirm'  { return Invoke-DeriveConfirm -RunDir $runDir -Bridge $bridge }
        'withdraw' { return Invoke-DeriveWithdraw -RunDir $runDir -Bridge $bridge }
        default    { Write-ErrorResult "DERIVE_ACTION_REQUIRED" "-Action propose|confirm|withdraw is required for -Command derive" 1 }
    }
}

function Get-DeriveRequirementFromCitations {
    # 从已 settle 派生节点的采纳回调 citations 提取新需求文档（归档相对路径）：
    # 命中 requirements/ 下 .md 且非 overview.md 的首个引用；无命中返回 $null。
    param([string]$RunDir, $Bridge, [string]$NodeText)
    $full = Read-TreeFullNode $RunDir $NodeText
    if ($null -eq $full) { return $null }
    $cb = Find-AcceptedCallback $RunDir $full
    if ($null -eq $cb) { return $null }
    $archRel = ([string]$Bridge.archive_rel).TrimEnd('/')
    foreach ($c in @($cb.callback.citations)) {
        $ref = ([string]$c.ref) -replace '\\', '/'
        if ($ref -match '(^|/)requirements/[^/]+\.md$' -and $ref -notmatch '(^|/)overview\.md$') {
            $rel = $ref
            if ($rel.StartsWith("$archRel/")) { $rel = $rel.Substring($archRel.Length + 1) }
            elseif ($rel.StartsWith(".rdd/changes/archive/") -and $rel -match '^\.rdd/changes/archive/[^/]+/(.+)$') { $rel = $Matches[1] }
            return $rel
        }
    }
    return $null
}

function Invoke-DeriveChainGraft {
    # 派生任务链头预挂（与 promulgate「链头预挂、闸门把守」模型同构）：每 owner
    # 一个链头节点挂 PM 节点下，depends_on 多锚缝合到各依赖任务的活跃节点
    # （阶段闸门 hold 至 replan 吸收——NODE_BLOCKED_BY_GATE 出路只有 replan）。
    # 返回 @{ bridge; nodes = @() }。
    param([string]$RunDir, $Bridge, $Derivation, [string]$ParentNode, [int]$TaskId, [string]$ReqRel)
    $treeData = Get-TreeStatusView ([string]$Bridge.run_id)
    $depNodes = @()
    foreach ($dt in @($Derivation['depends_on'])) {
        $depId = [int]$dt
        if (-not $Bridge.tasks.Contains("$depId")) { continue }
        $bStages = $Bridge.tasks["$depId"]['stages']
        if ($null -eq $bStages) { continue }
        foreach ($roleKey in @($bStages.Keys)) {
            $dn = [string]$bStages[$roleKey]
            $st = Get-NodeViewState $treeData $dn
            if ($null -ne $st -and @('pending', 'claimed', 'reported') -contains [string]$st['status'] -and $depNodes -notcontains $dn) { $depNodes += $dn }
        }
    }
    $acceptanceRef = $null
    $a = Get-AcceptanceSection $Bridge
    if ($null -ne $a -and ([string]$a['status']) -eq 'planned') { $acceptanceRef = [string]$a['criteria_ref'] }
    $archiveName = Split-Path $Bridge.archive -Leaf
    $nodes = @()
    foreach ($role in @($Derivation['owners'])) {
        $taskText = New-NodeTaskText -Title ([string]$Derivation['title']) -Stage $role -ReqRel $ReqRel -DesignRels @() -RunId ([string]$Bridge.run_id) -AcceptanceRef $acceptanceRef
        $graftItem = @{
            title = [string]$Derivation['title']
            task  = $taskText
            role  = $role.ToLower()
            ref   = "$archiveName/$ReqRel"
        }
        if ($depNodes.Count -gt 0) { $graftItem['depends_on'] = @($depNodes) }
        $g = Invoke-GraftOne ([string]$Bridge.run_id) $ParentNode $graftItem
        if (-not $g.ok) { return @{ bridge = $Bridge; nodes = @(); error = "graft failed for derived task $TaskId ($role): $($g.text)" } }
        Set-NodeTaskStage $Bridge $g.node_id $TaskId $role
        $nodes += $g.node_id
    }
    return @{ bridge = $Bridge; nodes = @($nodes); error = $null }
}

function Resolve-DeriveTargetTask {
    # 受控入册步骤 (2)+(3)：新需求文档定位（已有任务 remark 锚点优先——幂等
    # 续跑，否则采纳回调 citations）→ 首次入册时桥代写 rdd-flow add-task
    # （-BridgeRun 受控标记 + remark 幂等锚点，task.json 单一写入方不破）。
    # 返回 @{ taskId; reqRel; error }（error 非空 = 未入册，task.json 未动）。
    param([string]$RunDir, $Bridge, [string]$DerId, $Der, [string]$NodeText)
    $tag = "derivation=$DerId"
    $flow = Read-ArchiveTasks ([string]$Bridge.archive)
    $existing = $null
    foreach ($t in @($flow.tasks)) {
        if (([string]$t.remark) -match [regex]::Escape($tag)) { $existing = $t; break }
    }
    if ($null -ne $existing) {
        return @{ taskId = [int]$existing.id; reqRel = (([string]$existing.requirement) -replace '\\', '/'); error = $null }
    }
    $reqRel = Get-DeriveRequirementFromCitations -RunDir $RunDir -Bridge $Bridge -NodeText $NodeText
    if ([string]::IsNullOrWhiteSpace($reqRel)) {
        return @{ taskId = 0; reqRel = $null; error = "DERIVE_REQUIREMENT_DOC_MISSING: the PM delivery cites no new requirement doc (expected a requirements/<name>.md citation, overview.md excluded) — reclaim/redo the PM node or settle with proper citations" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path ([string]$Bridge.archive) $reqRel) -PathType Leaf)) {
        return @{ taskId = 0; reqRel = $null; error = "DERIVE_REQUIREMENT_DOC_MISSING: cited requirement doc not found at $reqRel" }
    }
    $ownersStr = (@($Der['owners']) -join '+')
    $r = Invoke-RddFlow @('-Command', 'add-task', '-Archive', ([string]$Bridge.archive), '-Title', ([string]$Der['title']), '-Requirement', $reqRel, '-CurrentOwners', $ownersStr, '-Phase', 'DESIGN', '-Remark', "mid-run 派生入册（$tag，run $($Bridge.run_id)）", '-BridgeRun', ([string]$Bridge.run_id))
    if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) {
        return @{ taskId = 0; reqRel = $null; error = "DERIVE_ADD_TASK_FAILED: bridge-issued add-task failed (task.json untouched — the patrol retries): $($r.text)" }
    }
    return @{ taskId = [int]$r.json.data.taskId; reqRel = $reqRel; error = $null }
}

function Update-DeriveAcceptanceOnRegister {
    # 受控入册步骤 (5a)：acceptance live 刷新 FIRST——single_exempt/declared
    # run 的 PM 增补了 overview 判据即升级 planned（basis=derived_upgrade），
    # 链头 node.task 随后携带 criteria 锚点，派生判据自然进验收门。
    # 返回 @{ bridge; warnings }。
    param($Bridge)
    $warnings = @()
    $a = Get-AcceptanceSection $Bridge
    if ($null -ne $a -and ([string]$a['status']) -eq 'none') {
        $criteria = Read-AcceptanceCriteria ([string]$Bridge.archive)
        if (([string]$criteria.mode) -eq 'criteria') {
            $a['status'] = 'planned'
            $a['basis'] = 'derived_upgrade'
            $a['criteria_ref'] = [string]$criteria.criteria_ref
            $a['declaration'] = $null
            $Bridge['acceptance'] = $a
            $warnings += "acceptance upgraded to criteria mode: the derived criteria (overview「## 整体验收判据」) now gate the run — the acceptance chain grafts once all mapped nodes are terminal"
        }
    }
    return @{ bridge = $Bridge; warnings = @($warnings) }
}

function Repair-DeriveChainHeads {
    # 受控入册步骤 (5b)：DESIGN 链头挂 PM 节点下（幂等——只补缺失角色的
    # 链头，已有活跃链头不重挂）。返回 @{ bridge; error }。
    param([string]$RunDir, $Bridge, $Der, [string]$ParentNode, [int]$TaskId, [string]$ReqRel)
    $treeData = Get-TreeStatusView ([string]$Bridge.run_id)
    $missingRoles = @()
    foreach ($role in @($Der['owners'])) {
        $has = $false
        if ($Bridge.tasks["$TaskId"]['stages'] -and $Bridge.tasks["$TaskId"]['stages'].Contains($role)) {
            $nid = [string]$Bridge.tasks["$TaskId"]['stages'][$role]
            $stt = Get-NodeViewState $treeData $nid
            if ($null -ne $stt -and [string]$stt['status'] -ne 'pruned') { $has = $true }
        }
        if (-not $has) { $missingRoles += $role }
    }
    if ($missingRoles.Count -eq 0) { return @{ bridge = $Bridge; error = $null } }
    $graft = Invoke-DeriveChainGraft -RunDir $RunDir -Bridge $Bridge -Derivation $Der -ParentNode $ParentNode -TaskId $TaskId -ReqRel $ReqRel
    return @{ bridge = $graft.bridge; error = $graft.error }
}

function Invoke-DeriveRegisterTask {
    # 受控入册（settle 派生分支与 status 巡检自愈共用的幂等实现）：PM 节点已
    # settle → (1) 确认记录防御性复核（无记录拒绝执行——硬门）→ (2) 新需求
    # 文档定位（citations / 已有任务 remark 锚点）→ (3) 桥代写 rdd-flow
    # add-task（-BridgeRun 受控标记 + remark 幂等锚点，task.json 单一写入方
    # 不破）→ (4) bridge.tasks 映射登记 → (5) 切 DESIGN 相位链头挂 PM 节点下
    # → (6) acceptance 段 live 刷新（派生判据自然进验收门）→ (7) plan-log
    # progress 事件。失败返回 @{ ok=$false; error } 不退出（settle 降级警告 +
    # 巡检重入，pending_sync 同族哲学）。
    param([string]$RunDir, $Bridge, [string]$DerId, [string]$NodeText)
    $der = $null
    foreach ($x in @(Get-DerivationSection $Bridge)) { if ([string]$x['id'] -eq $DerId) { $der = $x; break } }
    if ($null -eq $der) { return @{ ok = $false; error = "derivation $DerId vanished from bridge.json" } }
    $archivePath = [string]$Bridge.archive
    # (1) confirmation record — the HARD gate (execution requires a record)
    $entries = @(Read-DecisionEntries (Get-ArchiveDecisionsPath $archivePath))
    $conf = Find-DeriveConfirmation $entries $der
    if ($null -eq $conf) { return @{ ok = $false; error = "DERIVE_CONFIRMATION_MISSING: no user ruling entry (ref_entry=$([string]$der['proposed_entry'])) found in the archive decision ledger — execution refused" } }
    # (2)+(3) requirement doc location + bridge-issued add-task (idempotent)
    $target = Resolve-DeriveTargetTask -RunDir $RunDir -Bridge $Bridge -DerId $DerId -Der $der -NodeText $NodeText
    if ($null -ne $target.error) { return @{ ok = $false; error = [string]$target.error } }
    $taskId = [int]$target.taskId
    $reqRel = [string]$target.reqRel
    # (4) bridge.tasks mapping registration
    if (-not $Bridge.tasks.Contains("$taskId")) {
        $Bridge.tasks["$taskId"] = @{
            title         = [string]$der['title']
            requirement   = $reqRel
            initial_group = @($der['owners'])
            dep_task_ids  = @($der['depends_on'])
            stages        = @{}
        }
    }
    # (5a) acceptance live refresh FIRST (single_exempt/declared run whose PM
    # augmented overview criteria upgrades to planned) — the chain heads grafted
    # right below then carry the criteria anchor (criteria_ref) in node.task, and
    # replan's Test-PlanCriteriaRef demand + the acceptance chain gate the
    # derived requirement naturally.
    $acc = Update-DeriveAcceptanceOnRegister $Bridge
    $Bridge = $acc.bridge
    $warnings = @($acc.warnings)
    # (5b) DESIGN chain heads under the settled PM node (idempotent: only missing roles)
    $heads = Repair-DeriveChainHeads -RunDir $RunDir -Bridge $Bridge -Der $der -ParentNode $NodeText -TaskId $taskId -ReqRel $reqRel
    $Bridge = $heads.bridge
    if ($heads.error) { return @{ ok = $false; bridge = $Bridge; error = $heads.error } }
    # (7) derivation bookkeeping + plan-log progress event
    $derivations = @(Get-DerivationSection $Bridge)
    foreach ($x in $derivations) {
        if ([string]$x['id'] -eq $DerId) {
            $x['status'] = 'registered'
            $x['task_id'] = $taskId
            $x['requirement'] = $reqRel
            $x['registered_at'] = Get-UtcNowIso
        }
    }
    $Bridge['derivations'] = $derivations
    Write-BridgeFile $RunDir $Bridge
    $null = Add-PlanEvent $RunDir 'progress' 'derivation_registered' $NodeText $taskId $null @{ derivation = $DerId; ledger_entry = [string]$der['confirm_entry'] }
    return @{ ok = $true; bridge = $Bridge; task_id = $taskId; requirement = $reqRel; warnings = @($warnings) }
}

function Update-DerivationRegistrations {
    # 派生入册自愈状态机（与 pending_sync 同族的幂等续跑）：confirmed 且 PM
    # 节点已 done 但 task_id 未落（settle 与入册之间中断）→ 重跑
    # Invoke-DeriveRegisterTask（remark 锚点去重，不重复建任务）。入册是状态
    # 不是推送：no_push 隔离下照跑（AutoDispatch 状态机段调用）。
    param([string]$RunDir, $Bridge)
    $out = @{ bridge = $Bridge; registered = @(); failed = @() }
    $candidates = @()
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        if ([string]$d['status'] -ne 'confirmed') { continue }
        if ([string]::IsNullOrWhiteSpace([string]$d['node'])) { continue }
        if ((Test-PropPresent $d 'task_id') -and $null -ne $d['task_id']) { continue }
        $candidates += ,@{ id = [string]$d['id']; node = [string]$d['node'] }
    }
    if ($candidates.Count -eq 0) { return $out }
    $treeData = Get-TreeStatusView ([string]$Bridge.run_id)
    foreach ($c in $candidates) {
        $st = Get-NodeViewState $treeData $c.node
        if ($null -eq $st -or [string]$st['status'] -ne 'done') { continue }
        $reg = Invoke-DeriveRegisterTask -RunDir $RunDir -Bridge $Bridge -DerId $c.id -NodeText $c.node
        if ($reg.ok) {
            $Bridge = $reg.bridge
            $out.registered += @{ derivation = $c.id; task_id = $reg.task_id }
        }
        else {
            $Bridge = $(if ($reg.bridge) { $reg.bridge } else { $Bridge })
            $out.failed += @{ derivation = $c.id; error = [string]$reg.error }
        }
    }
    $out.bridge = $Bridge
    return $out
}

function New-DerivationViewRows {
    # status/resume 派生视图行（registered-unabsorbed 高亮由 warnings/resume
    # steps 提示 replan——风险应对：confirm 后规划者忘记 replan 吸收）。
    param($Bridge)
    $rows = @()
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        $rows += @{
            id             = [string]$d['id']
            title          = [string]$d['title']
            status         = [string]$d['status']
            node           = $(if ($null -ne $d['node']) { [string]$d['node'] } else { $null })
            task_id        = $(if ($null -ne $d['task_id']) { [int]$d['task_id'] } else { $null })
            absorbed       = ($d['absorbed'] -eq $true)
            ledger_entries = @(([string]$d['proposed_entry']), ($(if ($null -ne $d['confirm_entry']) { [string]$d['confirm_entry'] } else { $null })), ($(if ($null -ne $d['withdraw_entry']) { [string]$d['withdraw_entry'] } else { $null }))) | Where-Object { $_ }
            created_at     = [string]$d['created_at']
        }
    }
    return @($rows)
}

function Add-DerivationAnnexLines {
    # annex 派生清单区（留痕三联之三）：全部派生条目 + 状态 + 吸收口径；
    # 有派生的 run 根目标行补「含 N 条 run 中途派生需求并入」达成口径。
    param($Bridge)
    $ds = @(Get-DerivationSection $Bridge)
    if ($ds.Count -eq 0) { return @() }
    $lines = @()
    $lines += ""
    $lines += "## 需求派生（mid-run derive）"
    $lines += ""
    $lines += "| 派生 | 标题 | 状态 | 任务 | 确认记录 | 吸收 |"
    $lines += "|------|------|------|------|----------|------|"
    foreach ($d in $ds) {
        $tid = $(if ($null -ne $d['task_id']) { "#$([string]$d['task_id'])" } else { "-" })
        $conf = [string]$d['confirm_entry']
        if ([string]$d['status'] -eq 'withdrawn') { $conf = "$(if ($d['withdraw_entry']) { [string]$d['withdraw_entry'] })（拒绝）" }
        $abs = "-"
        if ([string]$d['status'] -eq 'registered') { $abs = $(if ($d['absorbed'] -eq $true) { "已入 plan" } else { "待 replan 吸收" }) }
        $lines += "| $($d['id']) | $(([string]$d['title']) -replace '\|', '/') | $($d['status']) | $tid | $conf | $abs |"
    }
    $lines += ""
    return $lines
}

function Test-ConcludeDerivations {
    # DERIVATION_PENDING（结案硬门，验收 7）：存在未完结派生（proposed/
    # confirmed 挂起，或 registered 任务未终态）拒绝结案——单 run 收敛语义；
    # 全任务终态硬门自然覆盖派生任务（registered 未完成照常拒）。
    param($Bridge, $Flow)
    $pending = @()
    foreach ($d in @(Get-DerivationSection $Bridge)) {
        $st = [string]$d['status']
        if ($st -eq 'withdrawn') { continue }
        if ($st -in @('proposed', 'confirmed')) {
            $pending += "$($d['id'])=$st"
            continue
        }
        if ($st -eq 'registered' -and $null -ne $d['task_id']) {
            $t = Find-ArchiveTask $Flow.tasks ([int]$d['task_id'])
            if ($null -eq $t -or $script:PlanTerminalLifecycles -notcontains ([string]$t.lifecycle)) {
                $pending += "$($d['id'])=task#$([string]$d['task_id']) 未终态"
            }
        }
    }
    if ($pending.Count -gt 0) {
        Write-ErrorResult "DERIVATION_PENDING" "Open derivation(s) block the conclude: [$($pending -join '; ')]. Settle/register them to completion, or withdraw the pending proposals first — a run with mid-run derivations concludes only when they are all resolved (withdrawn derivations never block)." 1
    }
}

function Steal-DerivationDeadClaim {
    # 派生 PM 节点 dead-claim 回收：存活预检已过 → steal + 标记重推 →
    # AutoDispatch 自动推送（reclaim 同族通道）。
    param([string]$RunDir, $Bridge, [string]$NodeId, $Node)
    $null = Test-ReclaimLiveness $RunId $NodeId $Node
    $worker = "planner-reclaim"
    $r1 = Invoke-GoalTreeLeaf @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeId, "-Worker", $worker, "-Steal")
    if ($r1.exit -ne 0 -or -not $r1.json.success) { Write-ErrorResult "RECLAIM_TREE_FAILED" "leaf steal failed: $($r1.text)" 1 }
    $Bridge = Set-NodeRepushFlag $RunDir $Bridge $NodeId
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim" (-not [bool]$NoReuse)
    return @{
        success = $true
        data    = @{
            run_id = $RunId; node_id = $NodeId; task_id = $null; stage = 'PM'
            reclaimed = $true; mode = 'dead-claim (tree-level derivation PM node)'
            steal_count = $r1.json.data.node.steal_count
            auto_push = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step = $(if (@($push.pushed) -contains $NodeId) { "fresh PM session auto-pushed for the parked derivation node" } else { "derivation node parked as '$worker' — re-push via status touch or dispatch -NodeId $NodeId" })
        }
    }
}

function Rebuild-DerivationRejectedDelivery {
    # 派生 PM 节点 rejected-delivery 回收：拒收证据已核 → 原会话存活走
    # in-place 重做；否则 prune + 同源重建 PM 节点（New-DeriveNodeTaskText
    # 单源）+ repush。
    param([string]$RunDir, $Bridge, [string]$NodeId, $Node, $Der, [string[]]$Problems, $Live)
    if (-not [bool]$NoReuse -and $Live.liveness -eq 'alive' -and -not [string]::IsNullOrWhiteSpace([string]$Live.session_id)) {
        return Invoke-ReclaimInPlace -RunDir $RunDir -Bridge $Bridge -Node $Node -NodeIdText $NodeId -TaskId 0 -Stage 'PM' -Problems $Problems -Live $Live -TreeLevel
    }
    $reason = "derivation PM delivery rejected by settle evidence gate: $($Problems -join '; ')"
    $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", $RunId, "-NodeId", $NodeId, "-Reason", $reason)
    if ($rp.exit -ne 0 -or -not $rp.json.success) { Write-ErrorResult "RECLAIM_PRUNE_FAILED" "prune of the rejected derivation delivery failed: $($rp.text)" 1 }
    $taskText = New-DeriveNodeTaskText -TitleText ([string]$Der['title']) -RationaleText ([string]$Der['rationale']) -RunIdText $RunId -ConfirmEntry ([string]$Der['confirm_entry']) -DepIds @($Der['depends_on'])
    $graftItem = @{
        title = [string]$Der['title']
        task  = $taskText
        role  = 'pm'
        ref   = "$(($RunId -replace '^deliver-', ''))/requirements/overview.md"
    }
    $g = Invoke-GraftOne $RunId ([string]$Bridge.goal_root) $graftItem
    if (-not $g.ok) { Write-ErrorResult "RECLAIM_GRAFT_FAILED" "replacement derivation PM node graft failed (derivation $($Der['id']) stays confirmed, old node pruned): $($g.text)" 1 }
    $derivations = @(Get-DerivationSection $Bridge)
    foreach ($x in $derivations) {
        if ([string]$x['id'] -eq [string]$Der['id']) { $x['node'] = $g.node_id }
    }
    $Bridge['derivations'] = $derivations
    Write-BridgeFile $RunDir $Bridge
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim" (-not [bool]$NoReuse)
    $Bridge = $push.bridge
    return @{
        success = $true
        data    = @{
            run_id = $RunId; node_id = $g.node_id; pruned_node = $NodeId; task_id = $null; stage = 'PM'
            reclaimed = $true; mode = 'rejected-delivery (tree-level derivation PM node)'
            fallback = $(if ($Live.liveness -eq 'alive') { 'no_reuse' } else { $Live.liveness })
            auto_push = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step = "rebuilt derivation PM node $($g.node_id) auto-pushed — the fresh PM session claims it and drafts the requirement doc"
        }
    }
}

function Invoke-ReclaimDerivationNode {
    # 派生 PM 节点回收（与 design review 节点同族的 tree-level 通道）：
    # dead-claim → steal + repush；reported-but-unqualified → 原会话存活时
    # in-place 重做（失败清单 + 原地重报），否则 prune + 重建 PM 节点（同
    # New-DeriveNodeTaskText 单源）+ repush。registered 后的链头节点是
    # bridge 映射节点，走既有 reclaim 通道（不经此处）。
    param([string]$RunDir, $Bridge, [string]$NodeId, $Der)
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    $nodeStatus = [string]$node.status
    if ($nodeStatus -eq 'pending') {
        Write-ErrorResult "RECLAIM_NOT_NEEDED" "Node $NodeId is pending (nobody claimed it) — a plain bridge claim is enough." 1
    }
    if ($nodeStatus -in @('done', 'pruned')) {
        Write-ErrorResult "RECLAIM_NOT_POSSIBLE" "Node $NodeId is '$nodeStatus' — terminal; nothing to reclaim." 1
    }
    if ($nodeStatus -eq 'claimed') {
        return Steal-DerivationDeadClaim -RunDir $RunDir -Bridge $Bridge -NodeId $NodeId -Node $node
    }
    # reported: rejected delivery — unqualified evidence required
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $node -NodeId $NodeId -Bridge $Bridge)
    if ($problems.Count -eq 0) {
        Write-ErrorResult "RECLAIM_REQUIRES_UNQUALIFIED" "Node $NodeId is reported with QUALIFIED evidence — settle it instead (settle -RunId $RunId -NodeId $NodeId); reclaim only recovers dead claims or rejected deliveries." 1
    }
    $live = Get-ClaimLiveness $RunId $NodeId
    return Rebuild-DerivationRejectedDelivery -RunDir $RunDir -Bridge $Bridge -NodeId $NodeId -Node $node -Der $Der -Problems $problems -Live $live
}

# === Parallel coordination (parallel-coordination: 并行协作冲突预防与治理) ===
#
# 两类冲突、一个注册表(planner-guide「并行协作冲突治理」):
#   design  多 CTO/UX 设计互斥或风格不一致 — PLANNER 调和产出一致结论,不成则上报
#           用户裁决(escalated,留痕),用户不在场挂起涉事链(suspended);硬约束:
#           不得默默二选一。
#   file    多 DEV 任务经 CTO 变更地图判出同文件重叠 — 派发前(推送门)识别并预防;
#           消解手段 = 归属划分(reclaim/replan,首选)/串行化(resolve -Serialize 组合
#           goal-tree deps add,兜底);错峰不采用(时间错开不构成互斥)。
# 状态机:open → resolved | open → escalated → resolved | open → suspended;
# 上报/挂起为条目状态属性,动作仅 open|resolve(同 decisions.jsonl 追加范式,
# history 追加不改写;语义边界=编排层并行冲突,与 AutoMode 决策账本分工)。
# 载体:bridge.json `conflicts` 段 + 人读镜像 report/design-conflicts.md;变更地图
# 机读缓存 `design_maps`(只读派生);架构/风格约定 `conventions` 段 +
# report/architecture-conventions.md(DESIGN 链头注入「架构约定:<path>」,与判据
# 注入同构)。三个新键全为可选 — 引入前的 run 逐字节兼容(无段=无门零成本)。
# 错误码: NODE_HELD_BY_CONFLICT / CONFLICT_NOT_FOUND / CONFLICT_ALREADY_RESOLVED /
# CONFLICT_ENTRY_INVALID / CONVENTIONS_MISSING / DESIGN_MAP_INVALID(警示级)。

$script:ConflictFlowTasksCache = $null

function Get-ConflictSection {
    param($Bridge)
    if (-not (Test-PropPresent $Bridge 'conflicts') -or $null -eq $Bridge['conflicts']) { return @() }
    return @(Convert-ToSafeArray $Bridge['conflicts'])
}

function Find-ConflictEntry {
    param($Bridge, [string]$ConflictId)
    foreach ($e in @(Get-ConflictSection $Bridge)) {
        if (([string]$e['id']) -eq $ConflictId) { return $e }
    }
    return $null
}

function Get-UnresolvedConflicts {
    param($Bridge)
    return @(Get-ConflictSection $Bridge | Where-Object { ([string]$_['status']) -ne 'resolved' })
}

function Write-ConflictReportFile {
    # 人读镜像(report/design-conflicts.md):每次注册表变更后整篇重写——镜像非账本,
    # 机器可读单源永远是 bridge.json `conflicts` 段。
    param([string]$RunDir, $Bridge)
    $repDir = Join-Path $RunDir "report"
    if (-not (Test-Path -LiteralPath $repDir)) { New-Item -ItemType Directory -Path $repDir -Force | Out-Null }
    $entries = @(Get-ConflictSection $Bridge)
    $rl = @()
    $rl += "# 并行协作冲突治理 — $([string]$Bridge['run_id'])"
    $rl += ""
    if ($entries.Count -eq 0) {
        $rl += "（无冲突登记）"
    }
    else {
        $rl += "| ID | 类型 | 状态 | 节点 | 任务 | 文件 | 发现途径 | 裁定/上报 |"
        $rl += "|----|------|------|------|------|------|----------|----------|"
        foreach ($e in $entries) {
            $ruling = "-"
            if ($null -ne $e['ruling']) { $ruling = (([string]$e['ruling']['text']) -replace '\|', '/') }
            elseif ($null -ne $e['escalation']) { $ruling = "上报用户：" + (([string]$e['escalation']['question']) -replace '\|', '/') }
            $fileCell = (@(Convert-ToSafeArray $e['files']) | ForEach-Object { ([string]$_) -replace '\|', '/' }) -join '<br>'
            $rl += "| $($e['id']) | $($e['kind']) | $($e['status']) | $(@(Convert-ToSafeArray $e['nodes']) -join ',') | $(@(Convert-ToSafeArray $e['tasks']) -join ',') | $fileCell | $($e['detected_by']) | $ruling |"
        }
        $rl += ""
        $rl += "## 处置历史（追加不改写）"
        $rl += ""
        foreach ($e in $entries) {
            foreach ($h in @(Convert-ToSafeArray $e['history'])) {
                $noteText = [string]$h['note']
                $extra = ""
                if (-not [string]::IsNullOrWhiteSpace($noteText)) { $extra = " — " + ($noteText -replace '\|', '/') }
                $rl += "- $($e['id']) · $($h['at']) · $($h['action'])$extra"
            }
        }
    }
    $rl += ""
    $rl += "> 硬约束：设计冲突**不得默默二选一**——调和产出一致结论，或上报用户裁决并留痕；用户不在场挂起涉事链并上报，不阻塞无冲突任务。机器可读单源：bridge.json ``conflicts`` 段。"
    [System.IO.File]::WriteAllText((Join-Path $repDir "design-conflicts.md"), ($rl -join "`n"), $script:Utf8NoBom)
}

function Save-ConflictState {
    # one persistence path for every registry mutation: bridge.json write-back
    # (read-back contract inside Write-BridgeFile) + human mirror rewrite.
    param([string]$RunDir, $Bridge)
    Write-BridgeFile $RunDir $Bridge
    Write-ConflictReportFile $RunDir $Bridge
    return $Bridge
}

function Add-ConflictEntry {
    # register ONE conflict (C<n> ascending, history append-only). The entry's
    # status attribute is set at open (escalated/suspended may be born recorded).
    param([string]$RunDir, $Bridge, [string]$Kind, [string[]]$NodeIds, [int[]]$TaskIds, [string[]]$FilePaths,
          [string]$DetectedByText, [string]$NoteText, [string]$StatusText, [string]$EscalationText)
    $maxId = 0
    foreach ($e in @(Get-ConflictSection $Bridge)) {
        if (([string]$e['id']) -match '^C(\d+)$') { $n = [int]$Matches[1]; if ($n -gt $maxId) { $maxId = $n } }
    }
    $now = Get-UtcNowIso
    $entry = [ordered]@{
        id          = "C$($maxId + 1)"
        kind        = $Kind
        nodes       = @($NodeIds)
        tasks       = @($TaskIds)
        files       = @($FilePaths)
        detected_by = $DetectedByText
        status      = $(if (-not [string]::IsNullOrWhiteSpace($StatusText)) { $StatusText } else { "open" })
        note        = $(if (-not [string]::IsNullOrWhiteSpace($NoteText)) { $NoteText } else { $null })
        escalation  = $(if (-not [string]::IsNullOrWhiteSpace($EscalationText)) { [ordered]@{ question = $EscalationText; at = $now } } else { $null })
        ruling      = $null
        serialize   = $null
        created_at  = $now
        updated_at  = $now
        history     = @([ordered]@{ at = $now; action = "open"; note = $NoteText })
    }
    $conflicts = @(Get-ConflictSection $Bridge)
    $conflicts += ,$entry
    $Bridge['conflicts'] = $conflicts
    $null = Save-ConflictState $RunDir $Bridge
    return $entry
}

function Set-ConflictState {
    # escalation / suspension are entry STATUS ATTRIBUTES (the action set stays
    # open|resolve): open -> escalated | open -> suspended | escalated <-> suspended.
    param([string]$RunDir, $Bridge, $Entry, [string]$StatusText, [string]$NoteText, [string]$EscalationText)
    $now = Get-UtcNowIso
    $Entry['status'] = $StatusText
    if (-not [string]::IsNullOrWhiteSpace($NoteText)) { $Entry['note'] = $NoteText }
    if (-not [string]::IsNullOrWhiteSpace($EscalationText)) { $Entry['escalation'] = [ordered]@{ question = $EscalationText; at = $now } }
    $Entry['updated_at'] = $now
    $hist = @(Convert-ToSafeArray $Entry['history'])
    $hist += ,[ordered]@{ at = $now; action = $StatusText; note = $NoteText }
    $Entry['history'] = $hist
    $null = Save-ConflictState $RunDir $Bridge
    return $Entry
}

function Set-ConflictSerializeEdges {
    # 串行化兜底(resolve -Serialize):晚者 depends_on 早者(goal-tree deps add 公开
    # CLI,DAG 校验 + deps-log 审计)——早者 settle 后晚者自动解锁。失败即整体拒绝
    # (登记不半写,冲突保持未决)。
    param([string]$RunIdText, $Entry, [string]$Earlier)
    $others = @(@($Entry['nodes']) | Where-Object { ([string]$_) -ne $Earlier })
    if ($others.Count -eq 0) {
        Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Serialize $Earlier needs at least one later counterpart node in $($Entry['id'])" 1
    }
    $added = @()
    foreach ($later in $others) {
        $r = Invoke-GoalTree @("-Command", "deps", "-DepAction", "add", "-RunId", $RunIdText, "-NodeId", ([string]$later), "-On", $Earlier)
        if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) {
            Write-ErrorResult "CONFLICT_ENTRY_INVALID" "serializing $later -> $Earlier failed (conflict stays OPEN): $($r.text)" 1
        }
        $added += "$later->$Earlier"
    }
    return $added
}

function Resolve-ConflictEntry {
    param([string]$RunDir, $Bridge, $Entry, [string]$RulingText, [string]$SerializeNode)
    $now = Get-UtcNowIso
    $Entry['status'] = "resolved"
    $Entry['ruling'] = [ordered]@{ text = $RulingText; at = $now; by = "planner" }
    if (-not [string]::IsNullOrWhiteSpace($SerializeNode)) { $Entry['serialize'] = [ordered]@{ earlier = $SerializeNode } }
    $Entry['updated_at'] = $now
    $hist = @(Convert-ToSafeArray $Entry['history'])
    $hist += ,[ordered]@{ at = $now; action = "resolve"; note = $RulingText }
    $Entry['history'] = $hist
    $null = Save-ConflictState $RunDir $Bridge
    return $Entry
}

function Read-DesignChangeMap {
    # 变更地图机读化(行格式契约:rdd-cto/design-template.md):文件行 =
    # `仓库根相对完整路径`  [新增]/[修改]/[删除] 说明;目录行仅视觉分组、计数行
    # 机械核对。带 [op] 标注但路径不可解析的行 -> DESIGN_MAP_INVALID 警示(警示级,
    # 不阻塞流转);存量/旧格式(无反引号完整路径)降级人工核对——显式警示,不硬拒
    # 也不静默放行(问题 1 补齐)。
    param([string]$DocAbsPath, [string]$DocRelPath)
    $res = [ordered]@{
        doc                  = $DocRelPath
        files                = @()
        counts               = $null
        parsed_counts        = [ordered]@{ add = 0; modify = 0; delete = 0 }
        warnings             = @()
        invalid_lines        = @()
        legacy               = $false
        fingerprint          = $null
        tasks                = @()
        citation_deviations  = @()
        parsed_at            = Get-UtcNowIso
    }
    $content = ""
    try { $content = [System.IO.File]::ReadAllText($DocAbsPath, [System.Text.Encoding]::UTF8) }
    catch { $res.warnings += "DESIGN_MAP_INVALID:变更地图读取失败 $DocRelPath ($($_.Exception.Message))"; return $res }
    $inMap = $false
    $opSeen = 0
    $fileSeen = 0
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*##\s*变更地图') { $inMap = $true; continue }
        if ($inMap -and $line -match '^\s*##\s') { break }
        if (-not $inMap) { continue }
        if ($line -match '^\s*\[新增\]\s*(\d+)\s*\|\s*\[修改\]\s*(\d+)\s*\|\s*\[删除\]\s*(\d+)') {
            $res.counts = [ordered]@{ add = [int]$Matches[1]; modify = [int]$Matches[2]; delete = [int]$Matches[3] }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match($line, '`(?<path>[^`]+)`\s*\[(?<op>新增|修改|删除)\]\s*(?<note>.*)$')
        if ($m.Success) {
            $p = ((([string]$m.Groups['path'].Value).Trim()) -replace '\\', '/') -replace '^\./', ''
            $opMap = @{ '新增' = 'add'; '修改' = 'modify'; '删除' = 'delete' }
            $op = $opMap[[string]$m.Groups['op'].Value]
            $res.files += ,([ordered]@{ path = $p; op = $op; note = ([string]$m.Groups['note'].Value).Trim() })
            $res.parsed_counts[$op] = [int]$res.parsed_counts[$op] + 1
            $fileSeen++
            continue
        }
        if ($line -match '\[(新增|修改|删除)\]') {
            $opSeen++
            $res.invalid_lines += ($line.Trim())
        }
    }
    if ($fileSeen -eq 0 -and $opSeen -gt 0) {
        $res.legacy = $true
        $res.warnings += "DESIGN_MAP_INVALID:旧格式/存量变更地图($opSeen 行带 [op] 标注但路径不可解析)——降级人工核对,文件重叠机械检测对 $DocRelPath 失明(不阻塞流转)"
    }
    elseif ($opSeen -gt 0) {
        $res.warnings += "DESIGN_MAP_INVALID:$opSeen 行带 [op] 标注但路径不可解析——按行格式契约('完整路径' [op] 说明)修正后可机读;不阻塞流转"
    }
    if ($null -ne $res.counts) {
        foreach ($k in @('add', 'modify', 'delete')) {
            if ([int]$res.counts[$k] -ne [int]$res.parsed_counts[$k]) {
                $res.warnings += "计数行机械核对不一致($DocRelPath):[$k] 声明 $($res.counts[$k]) / 实际解析 $($res.parsed_counts[$k])"
                break
            }
        }
    }
    return $res
}

function Get-DesignMaps {
    # design_maps 只读派生缓存:逐任务 designDocs 的变更地图机读结果。文档出现或
    # 内容变化(长度+mtime 指纹)时重解析;设计尚未产出的文档跳过(CTO 设计在 run
    # 中落地,下次触发点自动补扫)。返回 @{ maps; changed }。
    param([string]$RunDir, $Bridge, $FlowTasks, [switch]$Force)
    $changed = $false
    if (-not (Test-PropPresent $Bridge 'design_maps') -or $null -eq $Bridge['design_maps']) { $Bridge['design_maps'] = @{} }
    $maps = $Bridge['design_maps']
    foreach ($t in @(Convert-ToSafeArray $FlowTasks)) {
        $taskId = [int]$t.id
        foreach ($d in @(Convert-ToSafeArray $t.designDocs)) {
            $rel = (([string]$d.path) -replace '\\', '/')
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $abs = Join-Path ([string]$Bridge.archive) ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
            $fi = Get-Item -LiteralPath $abs
            $fp = "$($fi.Length):$($fi.LastWriteTimeUtc.Ticks)"
            $have = $null
            if ($maps -is [System.Collections.IDictionary] -and $maps.Contains($rel)) { $have = $maps[$rel] }
            if ((-not $Force) -and $null -ne $have -and ([string]$have['fingerprint']) -eq $fp) {
                $taskList = @(Convert-ToSafeArray $have['tasks'])
                if ($taskList -notcontains $taskId) {
                    $have['tasks'] = @($taskList + @($taskId))
                    $changed = $true
                }
                continue
            }
            $parsed = Read-DesignChangeMap $abs $rel
            $parsed['fingerprint'] = $fp
            $parsed['tasks'] = @($taskId)
            if ($null -ne $have) { $parsed['citation_deviations'] = @(Convert-ToSafeArray $have['citation_deviations']) }
            $maps[$rel] = $parsed
            $changed = $true
        }
    }
    if ($changed) {
        $Bridge['design_maps'] = $maps
        Write-BridgeFile $RunDir $Bridge
    }
    return @{ maps = $maps; changed = $changed }
}

function Get-ConflictFlowTasks {
    # per-invocation memo (one rdd-flow show subprocess per CLI run, not per node).
    param($Bridge)
    $key = [string]$Bridge.archive
    if ($null -ne $script:ConflictFlowTasksCache -and ([string]$script:ConflictFlowTasksCache.key) -eq $key) {
        return @($script:ConflictFlowTasksCache.tasks)
    }
    $flow = Read-ArchiveTasks $key
    $script:ConflictFlowTasksCache = @{ key = $key; tasks = @($flow.tasks) }
    return @($flow.tasks)
}

function Get-TaskChangeMapFiles {
    # 一任务的变更地图文件集(重叠口径=路径精确匹配,决策 6:保守判定是有意取舍)。
    param($Bridge, $FlowTasks, [int]$TaskIdNum)
    $files = @()
    if (-not (Test-PropPresent $Bridge 'design_maps') -or $null -eq $Bridge['design_maps']) { return @() }
    $maps = $Bridge['design_maps']
    foreach ($t in @(Convert-ToSafeArray $FlowTasks)) {
        if ([int]$t.id -ne $TaskIdNum) { continue }
        foreach ($d in @(Convert-ToSafeArray $t.designDocs)) {
            $rel = (([string]$d.path) -replace '\\', '/')
            if ($maps -is [System.Collections.IDictionary] -and $maps.Contains($rel)) {
                foreach ($f in @(Convert-ToSafeArray ($maps[$rel]['files']))) { $files += [string]$f['path'] }
            }
        }
    }
    return @($files | Select-Object -Unique)
}

function Test-TaskDependent {
    # A 依赖 B 或 B 依赖 A(传递闭包,dep_task_ids 单源) => 两任务非并发。
    param($Bridge, [int]$AId, [int]$BId)
    foreach ($pair in @(@($AId, $BId), @($BId, $AId))) {
        $seen = @{}
        $queue = @([int]$pair[0])
        while ($queue.Count -gt 0) {
            $cur = [int]$queue[0]
            if ($queue.Count -gt 1) { $queue = @($queue[1..($queue.Count - 1)]) } else { $queue = @() }
            if ($seen.Contains($cur)) { continue }
            $seen[$cur] = $true
            if ($cur -eq [int]$pair[1]) { return $true }
            if (-not $Bridge.tasks.Contains("$cur")) { continue }
            foreach ($dep in @(Convert-ToSafeArray $Bridge.tasks["$cur"]['dep_task_ids'])) { $queue += [int]$dep }
        }
    }
    return $false
}

function Test-ConflictHold {
    # 并行协作冲突推送门(与 R3 阶段闸门 AND 叠加、reason 分列):
    #   held_by_conflict      节点已在任一未决冲突条目内(设计/文件,登记在先)
    #   held_by_file_overlap  变更地图精确路径重叠于并发实施节点 -> 自动登记 file
    #                         条目 + hold(只 hold 待推候选,不追溯拦在途——对齐
    #                         「已 claimed 不受后加依赖回溯」)
    # resolve 后条目已决,下一触发点自动推送自然恢复。
    param([string]$NodeId, $Bridge, [string]$RunDir, $StatusOf)
    foreach ($e in @(Get-UnresolvedConflicts $Bridge)) {
        if (@(Convert-ToSafeArray $e['nodes']) -contains $NodeId) {
            return @{ node = $NodeId; reason = "held_by_conflict"; conflict = [string]$e['id']; kind = [string]$e['kind'] }
        }
    }
    $map = Get-NodeTaskStage $Bridge $NodeId
    if ($null -eq $map -or ([string]$map.stage) -ne 'DEV') { return $null }
    $tasks = Get-ConflictFlowTasks $Bridge
    $null = Get-DesignMaps $RunDir $Bridge $tasks
    $myFiles = @(Get-TaskChangeMapFiles $Bridge $tasks ([int]$map.task_id))
    if ($myFiles.Count -eq 0) { return $null }
    $counterparts = @()
    foreach ($otherId in @($Bridge.nodes.Keys)) {
        if (([string]$otherId) -eq $NodeId) { continue }
        $m2 = Get-NodeTaskStage $Bridge ([string]$otherId)
        if ($null -eq $m2) { continue }
        if (([string]$m2.stage) -ne 'DEV') { continue }
        if (([int]$m2.task_id) -eq ([int]$map.task_id)) { continue }
        $st2 = if ($StatusOf.ContainsKey([string]$otherId)) { [string]$StatusOf[[string]$otherId] } else { "missing" }
        if ($st2 -notin @('pending', 'claimed', 'reported')) { continue }   # 并发口径=待推/在途实施节点
        if (Test-TaskDependent $Bridge ([int]$map.task_id) ([int]$m2.task_id)) { continue }
        $otherFiles = @(Get-TaskChangeMapFiles $Bridge $tasks ([int]$m2.task_id))
        $overlap = @($myFiles | Where-Object { $otherFiles -contains $_ })
        if ($overlap.Count -eq 0) { continue }
        $counterparts += @{ node = [string]$otherId; task = [int]$m2.task_id; files = @($overlap) }
    }
    if ($counterparts.Count -eq 0) { return $null }
    $entryNodes = @($NodeId)
    $entryTasks = @([int]$map.task_id)
    $entryFiles = @()
    foreach ($c in $counterparts) {
        if ($entryNodes -notcontains $c.node) { $entryNodes += $c.node }
        if ($entryTasks -notcontains $c.task) { $entryTasks += $c.task }
        foreach ($f in @($c.files)) { if ($entryFiles -notcontains $f) { $entryFiles += $f } }
    }
    $noteText = "推送门自动登记:变更地图文件重叠($($entryFiles -join ', ')),并发实施节点 [$($entryNodes -join ', ')]——消解经归属划分(首选,reclaim/replan)或串行化(conflict -Action resolve -ConflictId <本条> -Serialize <早者节点>)"
    $entry = Add-ConflictEntry -RunDir $RunDir -Bridge $Bridge -Kind 'file' -NodeIds $entryNodes -TaskIds $entryTasks -FilePaths $entryFiles `
        -DetectedByText 'change-map-scan' -StatusText 'open' -EscalationText $null -NoteText $noteText
    return @{ node = $NodeId; reason = "held_by_file_overlap"; conflict = [string]$entry['id']; files = @($entryFiles); nodes = @($entryNodes) }
}

function Test-SettleConflictGate {
    # settle 前置冲突门(四查证据门先行、错误码分立,冲突门后置),按 kind 分流(决策 5):
    #   design 涉事节点恒拒(不得默默二选一——先调和/上报并 resolve 再 settle)
    #   file   仅双活跃方互拦(claimed/reported),单活跃写者放行(先行落地即串行化前提)
    param([string]$RunDir, $Bridge, [string]$NodeIdText)
    $open = @(Get-UnresolvedConflicts $Bridge | Where-Object { @(Convert-ToSafeArray $_['nodes']) -contains $NodeIdText })
    if ($open.Count -eq 0) { return }
    foreach ($e in $open) {
        if (([string]$e['kind']) -eq 'design') {
            Write-ErrorResult "NODE_HELD_BY_CONFLICT" "node $NodeIdText is inside unresolved conflict $($e['id']) (kind=design, status=$($e['status'])) — 设计冲突不得默默二选一:调和产出一致结论或上报用户裁决后,delivery-bridge.cmd -Command conflict -RunId $RunId -Action resolve -ConflictId $($e['id']) -Ruling '<一致结论/用户裁决>'" 1
        }
    }
    $tree = Get-TreeStatusView $RunId
    foreach ($e in $open) {
        if (([string]$e['kind']) -ne 'file') { continue }
        $counterparts = @()
        foreach ($other in @(Convert-ToSafeArray $e['nodes'])) {
            if (([string]$other) -eq $NodeIdText) { continue }
            $st2 = Get-NodeViewState $tree ([string]$other)
            $st2Text = if ($st2) { [string]$st2.status } else { "missing" }
            if ($st2Text -in @('claimed', 'reported')) { $counterparts += "$other($st2Text)" }
        }
        if ($counterparts.Count -gt 0) {
            Write-ErrorResult "NODE_HELD_BY_CONFLICT" "node $NodeIdText and active counterpart(s) [$($counterparts -join ', ')] both hold $($e['id']) (kind=file, files: $(@(Convert-ToSafeArray $e['files']) -join ', ')) — 双活跃方互拦防并发同文件覆盖:先 delivery-bridge.cmd -Command conflict -RunId $RunId -Action resolve -ConflictId $($e['id']) -Ruling '<归属划分/串行化结论>' [-Serialize <早者节点>]" 1
        }
    }
}

function Test-CitationDeviation {
    # 回执一致性软核对(不硬拒):DEV citations 超出其设计变更地图文件集 -> 偏差警示
    # 入 status/annex 并记进 design_maps[doc].citation_deviations——防「地图写错致
    # 检测失明」(变更地图失真 P1 风险的可见化)。
    param([string]$RunDir, $Bridge, [string]$NodeIdText, $Node)
    $map = Get-NodeTaskStage $Bridge $NodeIdText
    if ($null -eq $map -or ([string]$map.stage) -ne 'DEV') { return @() }
    $tasks = Get-ConflictFlowTasks $Bridge
    $null = Get-DesignMaps $RunDir $Bridge $tasks
    $expected = @(Get-TaskChangeMapFiles $Bridge $tasks ([int]$map.task_id))
    if ($expected.Count -eq 0) { return @() }
    $cb = Find-AcceptedCallback $RunDir $Node
    if ($null -eq $cb) { return @() }
    $deviant = @()
    foreach ($c in @(Convert-ToSafeArray $cb.callback.citations)) {
        $ref = ((([string]$c.ref) -replace '\\', '/') -replace '^\./', '')
        if ($expected -notcontains $ref) { $deviant += $ref }
    }
    if ($deviant.Count -eq 0) { return @() }
    $now = Get-UtcNowIso
    $maps = $Bridge['design_maps']
    $changed = $false
    foreach ($t in @(Convert-ToSafeArray $tasks)) {
        if ([int]$t.id -ne [int]$map.task_id) { continue }
        foreach ($d in @(Convert-ToSafeArray $t.designDocs)) {
            $rel = (([string]$d.path) -replace '\\', '/')
            if (-not ($maps -is [System.Collections.IDictionary] -and $maps.Contains($rel))) { continue }
            $devs = @(Convert-ToSafeArray $maps[$rel]['citation_deviations'])
            $devs += ,([ordered]@{ node = $NodeIdText; at = $now; refs = @($deviant) })
            $maps[$rel]['citation_deviations'] = $devs
            $changed = $true
        }
    }
    if ($changed) {
        $Bridge['design_maps'] = $maps
        Write-BridgeFile $RunDir $Bridge
    }
    return @("回执一致性软核对(警示,不阻塞):node $NodeIdText 的 citations 超出变更地图文件集 [$($deviant -join ', ')]——核对变更地图是否漏报/写错(机械重叠检测失明风险),人工确认后按需修正设计产物")
}

function Get-ConflictView {
    # status/resume 共用冲突视图:登记全量 + 未决清单 + 回执偏差。
    param($Bridge)
    $rows = @()
    foreach ($e in @(Get-ConflictSection $Bridge)) {
        $rows += [ordered]@{
            id          = [string]$e['id']
            kind        = [string]$e['kind']
            status      = [string]$e['status']
            nodes       = @(Convert-ToSafeArray $e['nodes'])
            tasks       = @(Convert-ToSafeArray $e['tasks'])
            files       = @(Convert-ToSafeArray $e['files'])
            detected_by = [string]$e['detected_by']
            note        = $e['note']
            escalation  = $e['escalation']
            ruling      = $e['ruling']
            serialize   = $e['serialize']
        }
    }
    $devs = @()
    if ((Test-PropPresent $Bridge 'design_maps') -and $null -ne $Bridge['design_maps'] -and ($Bridge['design_maps'] -is [System.Collections.IDictionary])) {
        foreach ($rel in @($Bridge['design_maps'].Keys)) {
            foreach ($dv in @(Convert-ToSafeArray $Bridge['design_maps'][$rel]['citation_deviations'])) {
                $devs += [ordered]@{ doc = $rel; node = [string]$dv['node']; at = [string]$dv['at']; refs = @(Convert-ToSafeArray $dv['refs']) }
            }
        }
    }
    return @{ conflicts = $rows; open = @($rows | Where-Object { $_['status'] -ne 'resolved' }); citation_deviations = $devs }
}

function Add-ConflictAnnexLines {
    # annex 引用冲突治理记录(conclude 不新增硬门:涉事任务未终态由 DELIVERY_
    # INCOMPLETE 兜底)。无登记无偏差时不产出行(旧 run annex 形态不变)。
    param($Bridge)
    $view = Get-ConflictView $Bridge
    if (@($view.conflicts).Count -eq 0 -and @($view.citation_deviations).Count -eq 0) { return @() }
    $openCount = @($view.open).Count
    $lines = @()
    $lines += "## 并行冲突治理"
    $lines += ""
    $lines += "- 冲突登记：共 $(@($view.conflicts).Count) 条（未决 $openCount 条），人读镜像 ``report/design-conflicts.md``，机器可读单源 bridge.json ``conflicts`` 段（追加不改写）"
    foreach ($e in @($view.conflicts)) {
        $rulingText = "-"
        if ($null -ne $e['ruling']) { $rulingText = [string]$e['ruling']['text'] }
        elseif ($null -ne $e['escalation']) { $rulingText = "上报用户：" + [string]$e['escalation']['question'] }
        $lines += "- $($e['id'])（$($e['kind'])/$($e['status'])）节点 [$($e['nodes'] -join ', ')] 文件 [$($e['files'] -join ', ')] — $rulingText"
    }
    foreach ($dv in @($view.citation_deviations)) {
        $lines += "- 回执偏差警示（软核对）：$($dv['node']) @ $($dv['doc']) — citations 超出变更地图文件集 [$($dv['refs'] -join ', ')]"
    }
    $lines += ""
    return $lines
}

function Get-ConventionsRef {
    param($Bridge)
    if ((Test-PropPresent $Bridge 'conventions') -and $null -ne $Bridge['conventions'] -and ($Bridge['conventions'] -is [System.Collections.IDictionary]) -and $Bridge['conventions'].Contains('path')) {
        return [string]$Bridge['conventions']['path']
    }
    return $null
}

function Test-DesignStageNode {
    # DESIGN 链头/节点判定:角色在 PhaseRoles[DESIGN] 白名单且任务所处阶段=DESIGN
    # (stored phase 优先,存量空 phase 按 owners 推导)。
    param([string]$Stage, $Task)
    if (@($script:PhaseRoles['DESIGN']) -notcontains $Stage) { return $false }
    $ph = $null
    if ($null -ne $Task) {
        $stored = $null
        if (Test-PropPresent $Task 'phase') { $stored = [string]$Task.phase }
        if (-not [string]::IsNullOrWhiteSpace($stored)) { $ph = $stored }
        else {
            $owners = @()
            if (Test-PropPresent $Task 'currentOwners') { $owners = @(Convert-ToSafeArray $Task.currentOwners) }
            $ph = Get-PhaseFromOwners $owners
        }
    }
    return ($ph -eq 'DESIGN')
}

function Read-ConventionsInput {
    # 架构/风格约定载体(决策 3:review 步产出 report/architecture-conventions.md):
    # promulgate -ConventionsFile。缺失/空内容在建树前判定(CONVENTIONS_MISSING,
    # 零残留——与 ACCEPTANCE_CRITERIA_MISSING 同纪律)。
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $repoRoot $p }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-ErrorResult "CONVENTIONS_MISSING" "conventions file not found: $Path — 多 CTO 设计须遵循同一套架构/风格约定,载体由 review 步产出(planner-guide「并行协作冲突治理」)" 2
    }
    $text = ""
    try { $text = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
    catch { Write-ErrorResult "CONVENTIONS_MISSING" "conventions file unreadable: $($_.Exception.Message)" 2 }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-ErrorResult "CONVENTIONS_MISSING" "conventions file is empty: $Path — 架构/风格约定必须非空(否则多 CTO 设计无共同基线)" 2
    }
    return @{ path = $p; text = $text }
}

function Test-PlanTasksDependent {
    # promulgate 期(bridge 未落)任务依赖判定:A 依赖 B 或 B 依赖 A(传递,plan dep_ids)。
    param($Plan, [int]$AId, [int]$BId)
    $depsOf = @{}
    foreach ($p in @($Plan)) { $depsOf[[int]$p.task.id] = @(Convert-ToSafeArray $p.dep_ids) }
    foreach ($pair in @(@($AId, $BId), @($BId, $AId))) {
        $seen = @{}
        $queue = @([int]$pair[0])
        while ($queue.Count -gt 0) {
            $cur = [int]$queue[0]
            if ($queue.Count -gt 1) { $queue = @($queue[1..($queue.Count - 1)]) } else { $queue = @() }
            if ($seen.Contains($cur)) { continue }
            $seen[$cur] = $true
            if ($cur -eq [int]$pair[1]) { return $true }
            if ($depsOf.Contains($cur)) { foreach ($d in @($depsOf[$cur])) { $queue += [int]$d } }
        }
    }
    return $false
}

function Test-ConventionsRequired {
    # CONVENTIONS_MISSING(建树前,零残留):DESIGN 并行链头 ≥2(多任务、互为并行——
    # 任意两任务间无依赖路径)而未提供 -ConventionsFile -> 拒建树。单设计(单任务
    # 设计单元)/串行设计(有依赖边)/非桥接 run 豁免。
    param($Plan, $ConventionsInput)
    if ($null -ne $ConventionsInput) { return }
    $designTaskIds = @()
    foreach ($p in @($Plan)) {
        $isDesign = $false
        foreach ($role in @($p.group)) {
            if (Test-DesignStageNode ([string]$role) $p.task) { $isDesign = $true }
        }
        if ($isDesign -and ($designTaskIds -notcontains [int]$p.task.id)) { $designTaskIds += [int]$p.task.id }
    }
    if ($designTaskIds.Count -lt 2) { return }
    for ($i = 0; $i -lt $designTaskIds.Count; $i++) {
        for ($j = $i + 1; $j -lt $designTaskIds.Count; $j++) {
            if (Test-PlanTasksDependent $Plan $designTaskIds[$i] $designTaskIds[$j]) { return }   # 串行设计豁免
        }
    }
    Write-ErrorResult "CONVENTIONS_MISSING" "promulgate 检出 DESIGN 并行链头 ≥2(并行设计任务 [$($designTaskIds -join ', ')],多 CTO 并行设计)但未提供 -ConventionsFile——多 CTO 设计须遵循同一套架构/风格约定(review 步产出 report/architecture-conventions.md,decision 3)。补 -ConventionsFile <path> 后重试;错误发生在建树前,零残留。" 1
}

function Set-ConventionsSection {
    # report/architecture-conventions.md + bridge.json `conventions` 段(运行侧落点);
    # DESIGN 链头 node.task 注入「架构约定:<path>」与判据注入同构。
    param([string]$RunDir, [string]$RunIdText, $Bridge, $ConventionsInput)
    $repDir = Join-Path $RunDir "report"
    if (-not (Test-Path -LiteralPath $repDir)) { New-Item -ItemType Directory -Path $repDir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $repDir "architecture-conventions.md"), $ConventionsInput.text, $script:Utf8NoBom)
    $Bridge['conventions'] = @{
        path       = ".rdd/goal-trees/$RunIdText/report/architecture-conventions.md"
        source     = $ConventionsInput.path
        applied_at = Get-UtcNowIso
    }
    return $Bridge
}

function Resolve-ConflictNodes {
    param($TreeData, [string]$NodesText)
    if ([string]::IsNullOrWhiteSpace($NodesText)) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Nodes (comma-separated node ids) is required" 1 }
    $ids = @()
    foreach ($raw in @(($NodesText -split ','))) {
        $nid = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($nid)) { continue }
        if ($null -eq (Get-NodeViewState $TreeData $nid)) {
            Write-ErrorResult "CONFLICT_ENTRY_INVALID" "node '$nid' does not exist in run $RunId" 1
        }
        if ($ids -notcontains $nid) { $ids += $nid }
    }
    if ($ids.Count -eq 0) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Nodes resolved to no node ids" 1 }
    return $ids
}

function Update-BridgeConflictState {
    # conflict open 既有条目状态属性更新（escalated/suspended——上报/挂起是
    # 条目状态属性，open→escalated/suspended）。返回命令结果。
    param([string]$RunDir, $Bridge, $Tree)
    $entry = Find-ConflictEntry $Bridge $ConflictId
    if ($null -eq $entry) { Write-ErrorResult "CONFLICT_NOT_FOUND" "conflict '$ConflictId' is not in this run's registry (see status conflicts view)" 1 }
    if (([string]$entry['status']) -eq 'resolved') { Write-ErrorResult "CONFLICT_ALREADY_RESOLVED" "conflict '$ConflictId' is already resolved — a changed verdict reopens as a NEW conflict entry (registry is append-only)" 1 }
    if ($ConflictStatus -notin @('escalated', 'suspended')) {
        Write-ErrorResult "CONFLICT_ENTRY_INVALID" "state-attribute update needs -ConflictStatus escalated|suspended (上报/挂起是条目状态属性;open→escalated/suspended)" 1
    }
    if ($ConflictStatus -eq 'escalated' -and [string]::IsNullOrWhiteSpace($Escalation)) {
        Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-ConflictStatus escalated needs -Escalation <呈用户裁决的问题>(上报记录)" 1
    }
    $entry = Set-ConflictState $RunDir $Bridge $entry $ConflictStatus $Note $Escalation
    return @{
        success = $true
        data    = [ordered]@{
            run_id    = $RunId
            conflict  = $entry
            report    = ".rdd/goal-trees/$RunId/report/design-conflicts.md"
            next_step = $(if ($ConflictStatus -eq 'escalated') { "已上报用户裁决($($entry['id']))——呈现问题并等用户裁决;裁决落地后 resolve:-Action resolve -ConflictId $($entry['id']) -Ruling '<用户裁决>'" } else { "涉事链已挂起($($entry['id']))并上报——不阻塞无冲突任务;后续会话续处,status 冲突视图可见" })
        }
    }
}

function New-BridgeConflictOpen {
    # conflict open 新建条目：kind/nodes/files 校验 → 任务反查 → 登记即拦截
    # 「默默二选一」（涉事节点推送门 hold / settle 门按 kind 分流）。
    # 返回命令结果。
    param([string]$RunDir, $Bridge, $Tree)
    if ([string]::IsNullOrWhiteSpace($ConflictKind)) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-ConflictKind design|file is required for a new conflict entry" 1 }
    $nodeIds = Resolve-ConflictNodes $Tree $Nodes
    $filePaths = @()
    if ($ConflictKind -eq 'file') {
        if ([string]::IsNullOrWhiteSpace($Files)) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "kind=file requires -Files (comma-separated repo-root-relative paths)" 1 }
        foreach ($f in @(($Files -split ','))) {
            $fp = (($f.Trim()) -replace '\\', '/')
            if (-not [string]::IsNullOrWhiteSpace($fp) -and ($filePaths -notcontains $fp)) { $filePaths += $fp }
        }
        if ($filePaths.Count -eq 0) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Files resolved to no path" 1 }
    }
    $statusOut = 'open'
    if ($ConflictStatus -in @('escalated', 'suspended')) { $statusOut = $ConflictStatus }
    if ($statusOut -eq 'escalated' -and [string]::IsNullOrWhiteSpace($Escalation)) {
        Write-ErrorResult "CONFLICT_ENTRY_INVALID" "status escalated needs -Escalation <呈用户裁决的问题>(上报记录)" 1
    }
    $taskIds = @()
    foreach ($nid in $nodeIds) {
        $m = Get-NodeTaskStage $Bridge $nid
        if ($null -ne $m -and ($taskIds -notcontains [int]$m.task_id)) { $taskIds += [int]$m.task_id }
    }
    $entry = Add-ConflictEntry -RunDir $RunDir -Bridge $Bridge -Kind $ConflictKind -NodeIds $nodeIds -TaskIds $taskIds -FilePaths $filePaths `
        -DetectedByText $(if (-not [string]::IsNullOrWhiteSpace($DetectedBy)) { $DetectedBy } else { 'planner' }) `
        -NoteText $Note -StatusText $statusOut -EscalationText $Escalation
    return @{
        success = $true
        data    = [ordered]@{
            run_id    = $RunId
            conflict  = $entry
            report    = ".rdd/goal-trees/$RunId/report/design-conflicts.md"
            next_step = "冲突已登记($($entry['id']),涉事节点推送门 hold/settle 门拦截)。调和落地 → -Action resolve -ConflictId $($entry['id']) -Ruling '<一致结论>'(文件冲突可 -Serialize <早者节点> 串行化);无法调和 → -Action open -ConflictId $($entry['id']) -ConflictStatus escalated -Escalation '<呈用户的问题>' 上报用户裁决;用户不在场 → -ConflictStatus suspended 挂起涉事链并上报(不阻塞无冲突任务)。硬约束:不得默默二选一。"
        }
    }
}

function Resolve-BridgeConflictCmd {
    # conflict resolve：调和一致结论 / 用户裁决落账（-Serialize 串行化可代结论）
    # → resolve 落地 + 编排裁定自动入账（统一决策账本，advisory——conflict
    # resolve 也是裁定）。返回命令结果。
    param([string]$RunDir, $Bridge)
    if ([string]::IsNullOrWhiteSpace($ConflictId)) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Action resolve requires -ConflictId <C<n>>" 1 }
    $entry = Find-ConflictEntry $Bridge $ConflictId
    if ($null -eq $entry) { Write-ErrorResult "CONFLICT_NOT_FOUND" "conflict '$ConflictId' is not in this run's registry (see status conflicts view)" 1 }
    if (([string]$entry['status']) -eq 'resolved') {
        Write-ErrorResult "CONFLICT_ALREADY_RESOLVED" "conflict '$ConflictId' was already resolved (ruling at $($entry['ruling']['at'])) — a changed verdict reopens as a NEW conflict entry (registry is append-only)" 1
    }
    $ruling = $Ruling
    $serialized = @()
    if (-not [string]::IsNullOrWhiteSpace($Serialize)) {
        $earlier = $Serialize.Trim()
        if (@(Convert-ToSafeArray $entry['nodes']) -notcontains $earlier) {
            Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Serialize $earlier is not a node of $($entry['id']) (nodes: $(@(Convert-ToSafeArray $entry['nodes']) -join ', '))" 1
        }
        $serialized = @(Set-ConflictSerializeEdges $RunId $entry $earlier)
        if ([string]::IsNullOrWhiteSpace($ruling)) {
            $laterText = (@(Convert-ToSafeArray $entry['nodes']) | Where-Object { ([string]$_) -ne $earlier }) -join ', '
            $ruling = "串行化消解：$earlier 先行落地,$laterText 待其 settle 后自动解锁(时间错开不构成互斥,故取依赖互斥)"
        }
    }
    if ([string]::IsNullOrWhiteSpace($ruling)) {
        Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Action resolve requires -Ruling <调和一致结论/用户裁决> (or -Serialize <早者节点> for 串行化)" 1
    }
    $entry = Resolve-ConflictEntry $RunDir $Bridge $entry $ruling $Serialize
    $ledger = Add-OrchestrationRuling -ArchivePath ([string]$Bridge.archive) -RunIdText $RunId -CommandName 'conflict-resolve' -DecisionText "conflict $($entry['id']) resolved: $ruling" -ReasonText $(if ([string]::IsNullOrWhiteSpace($Note)) { "并行冲突调和（不得默默二选一）" } else { $Note }) -OptionsArr @('调和（一致结论）', '上报用户裁决', '挂起涉事链')
    $res = @{
        success = $true
        data    = [ordered]@{
            run_id     = $RunId
            conflict   = $entry
            serialized = $serialized
            report     = ".rdd/goal-trees/$RunId/report/design-conflicts.md"
            next_step  = "$($entry['id']) 已 resolved——涉事节点解除 hold,下一触发点自动推送恢复;设计返修经 reclaim rejected-delivery(调和结论写入 -Note/重做上下文)或 rollback 落地"
        }
    }
    if ($ledger.entry) { $res.data['decision_ledger'] = @{ entry_id = [string]$ledger.entry['entry_id'] } }
    elseif ($ledger.warning) { $res.data['warnings'] = @($ledger.warning) }
    return $res
}

function Invoke-BridgeConflict {
    # conflict — 并行协作冲突注册表命令族(动作仅 open|resolve;上报/挂起为条目
    # 状态属性,经 open -ConflictId <id> 更新)。登记即拦截「默默二选一」:涉事节点
    # 推送门 hold / settle 门按 kind 分流;resolve 后下一触发点自动推送恢复。
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($Action)) { Write-ErrorResult "CONFLICT_ACTION_REQUIRED" "-Action is required (open / resolve)" 1 }
    if ($Action -in @('propose', 'confirm', 'withdraw')) {
        Write-ErrorResult "CONFLICT_ACTION_INVALID" "-Action $Action is a derive sub-action — the conflict registry only accepts open / resolve (derive lives under -Command derive)" 1
    }
    if ($Action -in @('submit', 'status')) {
        Write-ErrorResult "CONFLICT_ACTION_INVALID" "-Action $Action is a design-review sub-action — the conflict registry only accepts open / resolve (design-review lives under -Command design-review)" 1
    }
    $null = Enter-PlannerLease $runDir
    $tree = Get-TreeStatusView $RunId

    if ($Action -eq 'open') {
        if (-not [string]::IsNullOrWhiteSpace($ConflictId)) {
            # state-attribute update on an existing entry (escalated / suspended)
            return Update-BridgeConflictState -RunDir $runDir -Bridge $bridge -Tree $tree
        }
        return New-BridgeConflictOpen -RunDir $runDir -Bridge $bridge -Tree $tree
    }
    return Resolve-BridgeConflictCmd -RunDir $runDir -Bridge $bridge
}

# === Dispatch ===

switch ($Command) {
    "promulgate"       { $result = Invoke-Promulgate }
    "dispatch"         { $result = Invoke-Dispatch }
    "claim"            { $result = Invoke-BridgeClaim }
    "reclaim"          { $result = Invoke-BridgeReclaim }
    "rollback"         { $result = Invoke-BridgeRollback }
    "settle"           { $result = Invoke-BridgeSettle }
    "status"           { $result = Invoke-BridgeStatus }
    "resume"           { $result = Invoke-BridgeResume }
    "conclude"         { $result = Invoke-BridgeConclude }
    "lease"            { $result = Invoke-BridgeLease }
    "register-session" { $result = Invoke-BridgeRegisterSession }
    "decide"           { $result = Invoke-BridgeDecide }
    "escalate"         { $result = Invoke-BridgeEscalate }
    "replan"           { $result = Invoke-BridgeReplan }
    "conflict"         { $result = Invoke-BridgeConflict }
    "derive"           { $result = Invoke-BridgeDerive }
    "design-review"    { $result = Invoke-BridgeDesignReview }
}

ConvertTo-PortableJson $result -Depth 14
exit 0

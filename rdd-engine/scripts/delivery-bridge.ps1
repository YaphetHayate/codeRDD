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
#               (legacy archive) tasks keep the byte-identical advance path
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
#               the stalled task's stage here — never by a Force bypass
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
#   decisions.jsonl       append-only pure-auto-mode decision ledger (ONLY for
#                         -AutoMode runs; same paradigm as state/ledger.jsonl):
#                         auto / escalation / resolution / overturn entries,
#                         open-escalation view derived by ref_entry join — the
#                         ledger is never rewritten
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
# Hard constraint: "不合格交付不得流转" — settle enforces the three evidence checks
# (verdict=done / citations non-empty and real paths / extras.verification non-empty)
# before any task.json transition. Manual rdd-flow advance under a bridged run is
# forbidden by protocol (see references/planner-guide.md).

[CmdletBinding()]
param(
    [ValidateSet("promulgate", "dispatch", "claim", "reclaim", "rollback", "settle", "status", "resume", "conclude", "lease", "register-session", "decide", "escalate", "replan", "conflict")]
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
    [string]$CreatedBy = "planner",

    # dispatch / claim / reclaim / settle / decide / escalate
    [string]$NodeId,
    [string]$Role,                # stage role (CTO/UX/DEV/QA) for claim; inferred from node for others
    [string]$Session,             # Planner lease holder label

    # decide / escalate (planner-auto-mode checkpoint payload)
    [ValidateSet("auto", "resolution", "overturn")]
    [string]$Kind,                # decide entry kind (escalate always writes kind=escalation)
    [string]$Checkpoint,          # checkpoint name (e.g. "技术选型" / "命名")
    [string]$Decision,            # the verdict text (for escalate: the question awaiting the user)
    [string]$Inputs,              # decision inputs (what was considered)
    [string]$Basis,               # rationale / recommendation source
    [string]$Risk,                # risk label (low / high / free text)
    [string]$RuleId,              # grading-table rule id (required for -Kind auto)
    [string]$RefEntry,            # referenced entry_id (required for resolution / overturn)

    # register-session (planner-session-roster): off-tree direct-handoff
    # registration into the run's sessions.json roster — the planner records
    # the dsh session start-role just created ([直交] <标签>·<角色>)
    [string]$SessionId,
    [string]$Label,

    # settle
    [string]$Note,

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
    # 上报/挂起为条目状态属性(经 open -ConflictId 更新 -ConflictStatus)
    [ValidateSet("open", "resolve")]
    [string]$Action,              # conflict command action
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
    return "pure auto mode is ENABLED on this run: at each in-session confirmation checkpoint, classify it against the injected risk policy (first match wins, top-down). Low-risk (rule action=auto): answer it yourself with 'delivery-bridge.cmd -Command decide -RunId $RunIdText -NodeId <n> -Kind auto -RuleId <rule> -Checkpoint <name> -Decision <verdict> [-Inputs ...] [-Basis ...] [-Risk ...]' — the ledgered decide counts as the confirmation gate. Prohibition-class (R1 hard floor: safety/cost/irreversible/git) or manual-graded or unsure: 'delivery-bridge.cmd -Command escalate -RunId $RunIdText -NodeId <n> -Checkpoint <name> -Decision <question for the user> [-Risk high] [-RuleId <rule>] [-Inputs ...]' and WAIT for the user verdict (delivered back through your session or the Planner; never proceed past an open escalation). Every decision is auditable in .rdd/goal-trees/$RunIdText/decisions.jsonl and overturnable (decide -Kind overturn) before settle."
}

function Get-DecisionsPath { param([string]$RunDir); Join-Path $RunDir "decisions.jsonl" }

function Read-DecisionEntries {
    # All decision entries as deep hashtables; blank/unparseable lines are
    # skipped (our own writer enforces read-back finish; external corruption
    # degrades to the parseable prefix, never throws).
    # NOTE: callers MUST wrap the result in @() — PS 5.1 unwraps a single-element
    # return into the entry itself, and .Count on an OrderedDictionary means
    # KEY count, not entry count.
    param([string]$RunDir)
    $p = Get-DecisionsPath $RunDir
    $entries = @()
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    foreach ($line in @([System.IO.File]::ReadAllLines($p))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $e = Convert-PSObjectToHashtable ($line | ConvertFrom-Json)
            if ($null -ne $e -and $e -is [System.Collections.IDictionary]) { $entries += ,$e }
        } catch { continue }
    }
    return @($entries)
}

function Add-DecisionEntry {
    # THE decision-ledger append chain (lock -> read -> assign D<n> -> append ->
    # read-back finish -> unlock; ledger.jsonl paradigm) — the single copy shared
    # by escalate AND decide (no duplicated inline chain). $ValidateCallback
    # (optional, with $ValidateContext) runs INSIDE the lock against the fresh
    # entries: race-sensitive validation (decide's ref-entry lookups) shares the
    # append's critical section instead of a stale pre-lock check. Contract:
    # & $ValidateCallback <entries> <context>; returns the written entry.
    param([string]$RunDir, $Entry, [scriptblock]$ValidateCallback = $null, $ValidateContext = $null)
    $lockInfo = Enter-BridgeRunLock $RunDir
    try {
        $entries = @(Read-DecisionEntries $RunDir)
        if ($null -ne $ValidateCallback) { & $ValidateCallback $entries $ValidateContext }
        $Entry['entry_id'] = "D$($entries.Count + 1)"
        $line = ConvertTo-Json $Entry -Depth 8 -Compress
        [System.IO.File]::AppendAllText((Get-DecisionsPath $RunDir), $line + "`n", $script:Utf8NoBom)
        $all = @([System.IO.File]::ReadAllLines((Get-DecisionsPath $RunDir)) | Where-Object { $_.Trim() -ne "" })
        try { $null = $all[-1] | ConvertFrom-Json } catch {
            Write-ErrorResult "DECISIONS_READBACK_FAILED" "decisions.jsonl last line failed to parse after append" 3
        }
    }
    finally {
        Exit-BridgeRunLock
    }
    $Entry['lock'] = $lockInfo
    return $Entry
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
    # the same single ledger snapshot taken here.
    param([string]$RunDir, $Bridge, $TreeData)
    $entries = @(Read-DecisionEntries $RunDir)
    $countsByNode = @{}
    foreach ($e in $entries) {
        $node = [string]$e['node_id']
        if (-not $countsByNode.Contains($node)) { $countsByNode[$node] = @{ node = $node; auto = 0; escalation = 0; resolution = 0; overturn = 0; total = 0 } }
        $c = $countsByNode[$node]
        $k = [string]$e['kind']
        if ($c.Contains($k)) { $c[$k] = [int]$c[$k] + 1 }
        $c['total'] = [int]$c['total'] + 1
    }
    $amSection = Get-AutoModeSection $Bridge
    return @{
        enabled          = $true
        ledger           = ".rdd/goal-trees/$($Bridge.run_id)/decisions.jsonl"
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
    param([string]$RunDir, $Bridge, [string]$NodeId, [bool]$Ok, [string]$Error, [string]$RetryClass)
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
    $p = Get-PlanSection $Bridge
    if ($null -ne $p) {
        foreach ($st in @($p['stages'])) {
            $ap = $st['acceptance_point']
            if (([string]$ap['status']) -eq 'grafted' -and -not [string]::IsNullOrWhiteSpace([string]$ap['node'])) {
                $list += @{ node = [string]$ap['node']; stage = "QA"; task_id = 0; tree_level = $true }
            }
        }
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

function Invoke-NodePush {
    # ONE start-role push for a candidate (mapped or tree-level): brief/summary
    # ride the pointer message, the push ledger + roster get their write-back.
    # Returns @{ ok; error; retry_class } — failures are data, never exceptions.
    param($Cand, [string]$RunDir, $Bridge, $Nx)
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
    $brief = Get-NodeTaskBrief -NodeTask $taskText -NodeId $nodeId
    $summary = Get-NodeTaskSummary -NodeTask $taskText
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
        $retryClass = Get-PushFailureClass $r.text
    }
    $newBridge = Set-NodePushRecord $RunDir $Bridge $nodeId $ok $errText $retryClass
    if ($ok) {
        # roster write-back (planner-session-roster): advisory, silent skip
        $taskNum = 0
        if (-not $Cand.tree_level) { $taskNum = [int]$Cand.task_id }
        $null = Register-PushedSession -RunDir $RunDir -RunIdText ([string]$Bridge.run_id) -Stage $Cand.stage -TaskIdNum $taskNum -NodeId $nodeId -StartRoleText $r.text
    }
    return @{ ok = $ok; error = $errText; retry_class = $retryClass; bridge = $newBridge }
}

function Invoke-AutoDispatch {
    # THE auto-push function (goal-tree-goal-root). Push = the same start-role
    # delivery chain the manual dispatch command uses. No concurrency cap
    # (decision 3: idempotent pushes, PM splits are small); per-node isolation so
    # one failure never blocks the rest; per-node accounting in bridge.json v2.
    # Returns { trigger; considered; pushed; skipped; failed; bridge } — failures
    # are data, never exceptions (callers embed them in their own output).
    param([string]$RunDir, $Bridge, [string]$Trigger)
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
        $push = Invoke-NodePush $cand $RunDir $Bridge $nx
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
    # "依赖需求 2（xxx）" / "依赖需求1,3" / "依赖 #2" -> @(2) / @(1,3) / @(2).
    # Ids that do not exist as tasks in this archive are dropped (soft reference).
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
            foreach ($mm in [regex]::Matches($m.Groups[1].Value, '(?:需求|#)\s*(\d+)')) {
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
    param($Plan, [int[]]$ArchiveIds, [int[]]$DeliveredIds, $DepMap)
    $stageOfTask = @{}
    foreach ($st in @($Plan.stages)) {
        foreach ($tid in @($st.task_ids)) {
            if ($ArchiveIds -notcontains [int]$tid) { Write-ErrorResult "PLAN_FILE_INVALID" "stage $($st.id) task_ids references task #$tid which is not a task of this archive" 2 }
            if ($stageOfTask.Contains([int]$tid)) { Write-ErrorResult "PLAN_FILE_INVALID" "task #$tid appears in both stage $($stageOfTask[[int]$tid]) and $($st.id) (exactly one stage per task)" 2 }
            $stageOfTask[[int]$tid] = [string]$st.id
        }
    }
    foreach ($tid in @($DeliveredIds)) {
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
    param($Bridge, [int]$TaskId)
    $p = Get-PlanSection $Bridge
    if ($null -eq $p) { return @() }
    $st = Get-PlanStageOfTask $p $TaskId
    if ($null -eq $st) { return @() }
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
        $ap = $other['acceptance_point']
        $oldNode = [string]$ap['node']
        $ap['status'] = 'planned'; $ap['node'] = $null
        $hit = $true
        $null = Add-PlanEvent $RunDir 'deviation' 'acceptance_invalidated' $oldNode $TaskId ([string]$other['id']) @{ trigger = $Trigger; reason = $ReasonText }
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
        return
    }
    $taskId = [int]$Target.task_id
    $stage = Get-PlanStageOfTask $p $taskId
    if ($null -eq $stage) {
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
        if ($null -eq $old) { continue }
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
    return [ordered]@{
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
    $lines += "| 阶段 | 目标 | 里程碑 | 任务 | 完成度 | 集成验收点 |"
    $lines += "|------|------|--------|------|--------|------------|"
    foreach ($st in @($p['stages'])) {
        $row = New-PlanStageRow $st $Bridge $FlowTasks
        $ap = $st['acceptance_point']
        $nodeNote = ""
        if (-not [string]::IsNullOrWhiteSpace([string]$ap['node'])) { $nodeNote = " ($([string]$ap['node']))" }
        $lines += "| $($st['id']) | $($st['goal']) | $($st['milestone']) | $(@($st['task_ids']) -join ', ') | $($row.progress) | $([string]$ap['status'])$nodeNote |"
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
    Test-PlanDeliveryFit $newPlan @($flow.tasks | ForEach-Object { [int]$_.id }) $maps.delivered $maps.deps
    Test-PlanCriteriaRef $newPlan (Read-AcceptanceCriteria ([string]$bridge.archive))
    $changes = Compare-PlanRevisions $oldSec $newPlan
    $bridge = Merge-PlanRevision $runDir $bridge $oldSec $newPlan $PlanFile
    $rev = [int]((Get-PlanSection $bridge)['revision'])
    $null = Add-PlanEvent $runDir 'revision' 'replan' $null $null $null @{ reason = $Reason; revision = $rev; changes = $changes }
    $push = Invoke-AutoDispatch $runDir $bridge "replan"
    $bridge = $push.bridge
    return @{
        success = $true
        data    = [ordered]@{
            run_id     = $RunId
            revision   = $rev
            reason     = $Reason
            changes    = @($changes)
            plan       = Get-PlanView $runDir $bridge
            auto_push  = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed); skipped = @($push.skipped | ForEach-Object { "$($_.node):$($_.reason)" }) }
            next_step  = "plan revision $rev applied — unlock set recomputed and stage gates re-evaluate against the revised stages"
        }
    }
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
        return @{ push = @{ trigger = "promulgate (-NoPush)"; considered = 0; pushed = @(); skipped = @(); failed = @() }; bridge = $Bridge }
    }
    $push = Invoke-AutoDispatch $RunDir $Bridge "promulgate"
    return @{ push = $push; bridge = $push.bridge }
}

function New-BridgeSkeleton {
    # bridge.json v2 skeleton: node<->TaskId authoritative mapping + goal_root
    # anchor + the acceptance placeholder (overall-delivery, planned -> grafted)
    # + the plan section (long-task-planning current state; mandatory at
    # promulgate since -PlanFile is a hard gate).
    param([string]$RunId, [string]$ArchivePath, [string]$ArchiveRel, $Goal, [string]$CreatedByText, $Acceptance, $PlanSec)
    return @{
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
            @{ id = [string]$pst['id']; goal = [string]$pst['goal']; milestone = [string]$pst['milestone']; task_ids = @($pst['task_ids']); batches = @($pst['batches']) }
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
    return @{
        width     = $(if ($NodeWidth -gt 0) { $NodeWidth } else { [Math]::Max(4, $headCount + 2 + $extra) })
        max_nodes = $(if ($MaxNodes -gt 0) { $MaxNodes } else { (@($Plan).Count * 5 + 6 + $extra) })
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
    param($Bridge, $Mapping)
    Assert-PlanGateOpen $Bridge ([int]$Mapping.task_id)
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
    $r = Invoke-StartRole ($startArgs + $(if ($DryRun) { @("-DryRun") } else { @() }))
    # a real (non-dry-run) dispatch IS a push: record it in the ledger — the
    # manual path is the designated resolution for pointer-class failures, and
    # an unrecorded success would leave needs_repush stuck forever (status
    # would keep advertising manual work that is already done).
    if (-not $DryRun) {
        $okPush = ($r.exit -eq 0)
        $pushClass = $null
        if (-not $okPush) { $pushClass = Get-PushFailureClass $r.text }
        $bridge = Set-NodePushRecord $runDir $bridge $NodeId $okPush $(if ($okPush) { $null } else { $r.text }) $pushClass
        if ($okPush) {
            # roster write-back (planner-session-roster): advisory, silent skip
            $null = Register-PushedSession -RunDir $runDir -RunIdText $RunId -Stage $mapping.stage -TaskIdNum $mapping.task_id -NodeId $NodeId -StartRoleText $r.text
        }
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

function Add-ClaimTreeLevelContext {
    # tree-level claim context (R1 acceptance chain / stage acceptance point /
    # in-tree repair node): mutates $Data with tree_level + acceptance +
    # start_context per kind.
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
        report_hint = "goal-tree bridge run: on completion report back to the Planner instead of start-role-ing a downstream role — goal-tree-leaf.cmd -Command report -RunId $RunId -Worker $Stage -CallbackFile <cb.json>. Artifact locations ride the callback: citations = change list (real paths; settle checks every ref exists), full_report = main deliverable doc pointer (design doc / implementation notes; expected in bridge runs), extras.verification = verification result (settle requires citations + verification non-empty)"
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
        $data['start_context'] = "requirement: $($Bridge.archive_rel)/$($Bridge.tasks["$($Target.task_id)"].requirement) — full pointers in task.summary fields above"
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
    if (-not $target.tree_level) { Assert-PlanGateOpen $bridge ([int]$target.task_id) }
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
    # rejected-delivery recovery: the reported node FAILED the three-check gate —
    # prune the failed delivery (ledger keeps the audit) + graft a fresh stage
    # node + remap the bridge, so the task returns to workable state.
    param([string]$RunDir, $Bridge, $Node, [string]$NodeIdText, [int]$TaskId, [string]$Stage)
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $Node -NodeId $NodeIdText)
    if ($problems.Count -eq 0) {
        Write-ErrorResult "RECLAIM_REQUIRES_UNQUALIFIED" "Node $NodeIdText is reported with QUALIFIED evidence — settle it instead (settle -RunId $RunId -NodeId $NodeIdText); reclaim only recovers dead claims or rejected deliveries." 1
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
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim"
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
            auto_push    = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step    = "failed delivery pruned (ledger keeps the audit); replacement node $newNodeId grafted" + $(if (@($push.pushed) -contains $newNodeId) { " and auto-pushed" } else { " — re-push via status touch or dispatch -NodeId $newNodeId" })
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
    $push = Invoke-AutoDispatch $RunDir $Bridge "reclaim"
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

function Invoke-BridgeReclaim {
    # composite recovery (dead claims AND rejected deliveries) — orchestrator
    # over the two mode helpers (QA function-size gate decomposition; messages
    # and codes are unchanged from the pre-split single function).
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $stage = [string]$mapping.stage
    $taskId = [int]$mapping.task_id

    # read-only state check: the recovery path depends on the node's status
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    $nodeStatus = [string]$node.status

    if ($nodeStatus -eq "reported") {
        return Invoke-ReclaimRejectedDelivery $runDir $bridge $node $NodeId $taskId $stage
    }
    if ($nodeStatus -eq "pending") {
        Write-ErrorResult "RECLAIM_NOT_NEEDED" "Node $NodeId is pending (nobody claimed it) — a plain bridge claim is enough; reclaim recovers dead claims or rejected deliveries." 1
    }
    if ($nodeStatus -in @("done", "pruned")) {
        Write-ErrorResult "RECLAIM_NOT_POSSIBLE" "Node $NodeId is '$nodeStatus' — terminal; nothing to reclaim." 1
    }
    # claimed: the dead-claim recovery path
    return Invoke-ReclaimDeadClaim $runDir $bridge $node $NodeId $taskId $stage
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
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $Node -NodeId $NodeId)
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
    $r3 = Invoke-RddFlow @("-Command", "set-route", "-TaskId", "$($Ctx.task_id)", "-To", $toJoined, "-Phase", [string]$Ctx.target_phase, "-Archive", $Bridge.archive)
    $routeFailed = ($r3.exit -ne 0 -or $null -eq $r3.json -or -not $r3.json.success)
    if ($routeFailed) {
        $warnings += "flow set-route failed after prune/graft — recorded as pending_sync (every status touch retries the repair, then the catch-up push fires): $($r3.text)"
        $Bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $Ctx.stage $toJoined ($r3.text) -PhaseArg ([string]$Ctx.target_phase)
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
        $push = Invoke-AutoDispatch $RunDir $Bridge "rollback"
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

    return @{
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
}

# === Settle evidence gate (shared by settle, reclaim and rollback) ===

function Test-SettleEvidence {
    # The three checks gating any task.json transition (hard constraint:
    # unqualified delivery never transitions):
    #   1. verdict=done (worker self-assessment complete)
    #   2. citations = change list, non-empty and every ref a real path
    #   3. extras.verification non-empty (the verification result)
    # Returns an array of problem strings (empty = qualified).
    param([string]$RunDir, $Node, [string]$NodeId)
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

function Invoke-LegacySettleFlow {
    # LEGACY null-phase flow tail — byte-identical pre-phase-model behavior
    # (conservative degrade for old archives; new archives always carry phase):
    # terminal stage -> flow complete; otherwise advance + single next-stage
    # graft. Half-failures land in pending_sync. Returns the settle-tail shape
    # @{ bridge; warnings; graftedNext; graftedNextNodes; flowOperation; taskLifecycle }.
    # $NextStage stays untyped: a null (terminal stage) must survive binding as
    # null — a [string] cast would turn it into "" and flip the advance/complete fork.
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$Stage, $NextStage)
    $taskId = [int]$Task.id
    $res = @{ bridge = $Bridge; warnings = @(); graftedNext = $null; graftedNextNodes = @(); flowOperation = ""; taskLifecycle = "" }
    if ($null -ne $NextStage) {
        $r2 = Invoke-RddFlow @("-Command", "advance", "-TaskId", "$taskId", "-From", $Stage, "-To", $NextStage, "-Archive", $Bridge.archive)
        if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
            $res.warnings += "flow advance failed after tree settle — recorded as pending_sync: $($r2.text)"
            $res.bridge = Add-PendingSync $RunDir $Bridge $NodeId "advance" $Stage $NextStage ($r2.text)
        }
        else {
            $g = Invoke-GraftNextStage $RunDir $Bridge $Task $NodeId $NextStage
            if ($g.success) {
                $res.bridge = $g.bridge
                $res.graftedNext = $g.node_id
            }
            else {
                $res.warnings += "next-stage graft failed (flow side already advanced): $($g.error)"
            }
        }
    }
    else {
        $done = Invoke-FlowCompleteTail $RunDir $Bridge $Task $NodeId $Stage
        $res.bridge = $done.bridge
        $res.warnings += @($done.warnings)
    }
    $res.flowOperation = $(if ($null -eq $NextStage) { "complete" } else { "advance ${Stage}->${NextStage}" })
    $res.taskLifecycle = $(if ($null -eq $NextStage) { "completed" } else { "active @ $NextStage" })
    return $res
}

function Invoke-PhaseSwitchSettle {
    # LAST settle of a non-terminal phase (phase-model.md §5.2): atomic
    # set-route onto PhaseRoles[PhaseNext[phase]] + convergence graft of the
    # next phase's heads. A failed switch lands in pending_sync WITH the target
    # phase — retrying it as a plain narrowing would drift the whitelist.
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$TaskPhase, [string]$NextPhase, [hashtable]$Res)
    $taskId = [int]$Task.id
    $nextOwners = @($script:PhaseRoles[$NextPhase])
    $to = $nextOwners -join '+'
    $r2 = Invoke-RddFlow @("-Command", "set-route", "-TaskId", "$taskId", "-To", $to, "-Phase", $NextPhase, "-Archive", $Bridge.archive)
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        $Res.warnings += "flow set-route phase switch failed after tree settle — recorded as pending_sync: $($r2.text)"
        $Res.bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $TaskPhase $to ($r2.text) -PhaseArg $NextPhase
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
    param([string]$RunDir, $Bridge, $Task, [string]$NodeId, [string]$Stage, $Owners, [string]$TaskPhase)
    $taskId = [int]$Task.id
    $owners = @($Owners)
    $res = @{ bridge = $Bridge; warnings = @(); graftedNext = $null; graftedNextNodes = @(); flowOperation = ""; taskLifecycle = "active @ $TaskPhase" }
    $remaining = @($owners | Where-Object { $_ -ne $Stage })
    if ($remaining.Count -gt 0) {
        $to = $remaining -join '+'
        $r2 = Invoke-RddFlow @("-Command", "set-route", "-TaskId", "$taskId", "-To", $to, "-Archive", $Bridge.archive)
        if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
            $res.warnings += "flow set-route narrowing failed after tree settle — recorded as pending_sync: $($r2.text)"
            $res.bridge = Add-PendingSync $RunDir $Bridge $NodeId "set-route" $TaskPhase $to ($r2.text)
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
    return Invoke-PhaseSwitchSettle $RunDir $Bridge $Task $NodeId $TaskPhase $nextPhase $res
}

function Resolve-SettleTarget {
    # Resolve the settle target: bridge-mapped (task, stage) OR a tree-level node
    # (acceptance chain / in-tree repair node, no TaskId — the unified branch).
    # Returns @{ stage; task_id; tree_level; acceptance; next_stage }.
    param($Bridge, [string]$NodeIdText, [string]$RunDirText)
    $mapping = Get-NodeTaskStage $Bridge $NodeIdText
    if ($null -ne $mapping) {
        return @{ stage = [string]$mapping.stage; task_id = [int]$mapping.task_id; tree_level = $false; acceptance = $null; next_stage = $script:StageNext[[string]$mapping.stage] }
    }
    $info = Get-TreeLevelInfo $Bridge $RunDirText $NodeIdText
    if ($null -eq $info) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeIdText is not in this run's bridge mapping" 2 }
    return @{ stage = [string]$info.role; task_id = 0; tree_level = $true; acceptance = $info; next_stage = $null }
}

function Test-SettleDelivery {
    # state precheck (node must be reported) + the three evidence checks —
    # identical gate for mapped and tree-level nodes (unqualified delivery never
    # transitions). Returns the node for the transition step.
    param([string]$RunDir, [string]$NodeIdText, [bool]$TreeLevel = $false)
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeIdText)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    if ($node.status -ne "reported") {
        Write-ErrorResult "SETTLE_REQUIRES_REPORTED" "Node $NodeIdText is '$($node.status)'; settle only accepts reported nodes (claim -> work -> leaf report first)." 1
    }
    $problems = @(Test-SettleEvidence -RunDir $RunDir -Node $node -NodeId $NodeIdText)
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
            Write-ErrorResult "FLOW_ADVANCE_WOULD_FAIL" "Precheck: '$($Target.stage)' is not in currentOwners of TaskId $taskId ([$($owners -join '+')]) — the phase-side set-route would mis-narrow. Fix routing or use rdd-flow set-route first." 1
        }
    }
    elseif ($null -ne $Target.next_stage) {
        if ($owners -notcontains $Target.stage) {
            Write-ErrorResult "FLOW_ADVANCE_WOULD_FAIL" "Precheck: '$($Target.stage)' is not in currentOwners of TaskId $taskId ([$($owners -join '+')]) — advance would fail. Fix routing or use rdd-flow set-route first." 1
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
    param([string]$RunDir, $Bridge, $Target, $Ready)
    $null = Invoke-TreeSettleWrite $NodeId
    if ($null -eq $Ready.task_phase) {
        # LEGACY null-phase task: conservative degrade — byte-identical pre-phase
        # behavior (StageNext chain + single graft). New archives always carry phase.
        $tail = Invoke-LegacySettleFlow $RunDir $Bridge $Ready.task $NodeId $Target.stage $Target.next_stage
    }
    else {
        # PHASE MODE (phase-model.md §5.2). Owners narrowing keeps the phase and only
        # fills MISSING live nodes (serial CTO->UX inside DESIGN); the LAST settle of
        # the phase switches atomically to PhaseRoles[PhaseNext[phase]] and grafts the
        # next phase's heads (convergence — no per-branch fan-out, no tree split).
        $tail = Invoke-PhaseSettleFlow $RunDir $Bridge $Ready.task $NodeId $Target.stage $Ready.owners $Ready.task_phase
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

function Invoke-BridgeSettle {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $target = Resolve-SettleTarget $bridge $NodeId $runDir
    $node = Test-SettleDelivery -RunDir $runDir -NodeIdText $NodeId -TreeLevel ([bool]$target.tree_level)
    # parallel-coordination settle conflict gate (三查先行,冲突门后置,错误码分立):
    # design-kind 涉事节点恒拒 / file-kind 仅双活跃方互拦 — NODE_HELD_BY_CONFLICT
    if (-not [bool]$target.tree_level) {
        Test-SettleConflictGate -RunDir $runDir -Bridge $bridge -NodeIdText $NodeId
    }
    $conflictWarnings = @(Test-CitationDeviation -RunDir $runDir -Bridge $bridge -NodeIdText $NodeId -Node $node)
    $tail = $null
    if ($target.tree_level) {
        $tail = Invoke-SettleTreeOnly $runDir $NodeId
    }
    else {
        $flowReady = Test-SettleFlowReady -Bridge $bridge -Target $target
        $tail = Invoke-SettleFlowTransition -RunDir $runDir -Bridge $bridge -Target $target -Ready $flowReady
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
    param([string]$RunDir, $Bridge, [string]$NodeId, [string]$Op, [string]$From, $To, [string]$Error, [string]$PhaseArg = $null)
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
    $node = Get-NodeFromTree (Get-TreeStatusView $RunId) $existing
    $status = if ($node) { [string]$node.status } else { "missing" }
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
            $r = Invoke-RddFlow $retryArgs
        }
        elseif ([string]$e.op -eq "reopen") {
            # rollback half-failure (planner-stage-rollback): the tree side moved
            # (prune + rebuilt node) but the flow reopen did not land — retry it
            $r = Invoke-RddFlow @("-Command", "reopen", "-TaskId", "$taskId", "-To", [string]$e.to, "-Archive", $Bridge.archive)
        }
        else {
            $r = Invoke-RddFlow @("-Command", "advance", "-TaskId", "$taskId", "-From", [string]$e.from, "-To", [string]$e.to, "-Archive", $Bridge.archive)
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

function Get-BridgeOverview {
    # joined view shared by status and resume
    param([string]$RunDir, $Bridge)

    $treeData = Get-TreeStatusView $RunId
    $flow = Read-ArchiveTasks $Bridge.archive
    $repair = Repair-PendingSync $RunDir $Bridge
    $bridge = $repair.bridge

    # per-task join: stage nodes + flow routing/worker + lifecycle
    $taskRows = @()
    foreach ($t in $flow.tasks) {
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
                $node = Get-NodeFromTree $treeData $nodeId
                $stages += @{
                    stage  = $stage
                    node   = $nodeId
                    status = $(if ($node) { [string]$node.status } else { "missing" })
                }
            }
            $taskPhase = [string]$t.phase
            if ([string]::IsNullOrEmpty($taskPhase)) { $taskPhase = $null }
            $stageChain = Format-StageChain $bStages $treeData $(if ($null -ne $taskPhase) { $taskPhase } else { "" })
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

    # dead claims: tree side claimed too old, or flow worker entries too old
    $deadTreeClaims = @()
    $now = Get-Date
    foreach ($n in @(Convert-ToSafeArray $treeData.nodes.claimed)) {
        $ageMin = $null
        if ($n.claimed_at) {
            try { $ageMin = [int](($now.ToUniversalTime() - [datetime]::Parse($n.claimed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes) } catch {}
        }
        if ($null -ne $ageMin -and $ageMin -ge $DeadClaimMinutes) {
            $deadTreeClaims += @{ node = $n.id; claimed_by = $n.claimed_by; age_minutes = $ageMin }
        }
    }
    $deadFlowClaims = @()
    foreach ($t in $flow.tasks) {
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

    # claimable nodes right now (tree pending + not dep-blocked + bridge-mapped)
    $claimable = @()
    $nx = Get-LeafNextView $RunId
    if ($null -ne $nx) {
        foreach ($p in @(Convert-ToSafeArray $nx.pending)) {
            if ($null -ne (Get-NodeTaskStage $bridge ([string]$p.id))) { $claimable += $p.id }
        }
    }

    # reported-but-unqualified deliveries (planner-stage-rollback): settle refuses
    # them; surface the disposition menu — same-stage reclaim (redo THIS stage)
    # vs cross-stage rollback (send the task one stage back) — so the choice
    # never degrades into hand-edited state (hard constraint 2). The status
    # view's reported rows lack last_verdict, so the full node comes from the
    # per-node leaf status probe (black-box, same channel Get-NodeTaskText uses).
    $flagged = @()
    foreach ($rn in @(Convert-ToSafeArray $treeData.nodes.reported)) {
        $rid = if ($rn -is [string]) { $rn } else { [string]$rn.id }
        $rs = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $rid)
        if ($rs.exit -ne 0 -or $null -eq $rs.json -or -not $rs.json.success -or $null -eq $rs.json.data.node) { continue }
        $probs = @(Test-SettleEvidence -RunDir $RunDir -Node $rs.json.data.node -NodeId $rid)
        if ($probs.Count -gt 0) {
            $flagged += @{
                node        = $rid
                problems    = $probs
                same_stage  = "delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $rid"
                cross_stage = "delivery-bridge.cmd -Command rollback -RunId $RunId -NodeId $rid -To <roles> -Phase <REQ|DESIGN|IMPL|VERIFY> -Reason <why>"
            }
        }
    }

    $deps = $treeData.dependencies

    $terminalCount = @($flow.tasks | Where-Object { ([string]$_.lifecycle) -in @("completed", "deprecated") }).Count

    return @{
        bridge         = $bridge
        tree           = $treeData
        task_rows      = $taskRows
        dead_claims    = @{ tree = $deadTreeClaims; flow = $deadFlowClaims }
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

function Invoke-BridgeConclude {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($Summary)) { Write-ErrorResult "MISSING_SUMMARY" "-Summary is required (closing summary for the delivery)" 1 }

    $null = Enter-PlannerLease $runDir

    $flow = Read-ArchiveTasks $bridge.archive
    $reviewState = Resolve-ConcludeReviewState $bridge $flow
    $treeData = Get-TreeStatusView $RunId
    Test-ConcludeDeliveryComplete $bridge $flow $reviewState.reject_returned $treeData

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

    # 2) rdd-flow check (integrity of the whole archive routing)
    $chk = Invoke-RddFlow @("-Command", "check", "-Archive", $bridge.archive)
    $checkOk = ($chk.exit -eq 0 -and $null -ne $chk.json -and $chk.json.success -and [int]$chk.json.data.issueCount -eq 0)
    $checkIssues = @()
    if ($null -ne $chk.json -and $chk.json.success) { $checkIssues = @(Convert-ToSafeArray $chk.json.data.issues) }

    # 3) delivery annex: per-task terminal state + acceptance conclusion + check
    $pendingRejects = @($flow.tasks | Where-Object { $reviewState.pending_reject_ids -contains [int]$_.id })
    New-DeliveryAnnex -RunId $RunId -RunDir $runDir -Bridge $bridge -Flow $flow -TreeData $treeData -CheckOk $checkOk `
        -CheckIssues $checkIssues -SummaryText $Summary -RootNode $anchorInfo.root_node -PendingRejects $pendingRejects `
        -PendingRejectIds $reviewState.pending_reject_ids -MergedInto $reviewState.merged_into -Conclusion $conclusion

    # 4) release the lease (delivery closed)
    $null = Invoke-LeaseRelease $runDir

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
        Write-ErrorResult "REF_ENTRY_NOT_FOUND" "-RefEntry '$refId' does not exist in this run's decision ledger (run-level lookup — cross-node references are tolerated)" 1
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

function Invoke-BridgeDecide {
    # decide — ledger append for one checkpoint decision:
    #   -Kind auto        grading-table answer (rule must be action=auto);
    #                     decider = auto/<rule>@<stage>
    #   -Kind resolution  user verdict closing an open escalation (ref_entry);
    #                     decider = user@in-session
    #   -Kind overturn    in-session redo note over an existing decision (auto /
    #                     resolution / escalation target via ref_entry, run-level
    #                     existence tolerated); decider = user@in-session
    # Composition (each piece ≤40 lines, ONE append chain): gate context ->
    # kind context -> Add-DecisionEntry (ref validation in-lock) -> view.
    if ([string]::IsNullOrWhiteSpace($Kind)) { Write-ErrorResult "DECISION_KIND_REQUIRED" "-Kind is required (auto / resolution / overturn)" 1 }
    $g = Get-DecisionGateContext $Kind
    $k = Get-DecisionKindContext $g
    $payload = New-DecisionEntryPayload -KindText $Kind -TaskIdNum $g.mapping.task_id -Stage $g.mapping.stage -RiskFallback $null -Decider $k.decider -RuleIdOut $k.rule_id -RefEntryOut $k.ref_entry
    $entry = Add-DecisionEntry $g.run_dir $payload -ValidateCallback ${function:Test-DecisionRefEntry} -ValidateContext @{ kind = $Kind; ref = $RefEntry }
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
    $entry = Add-DecisionEntry $g.run_dir $payload
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
    # settle 前置冲突门(三查先行、错误码分立,冲突门后置),按 kind 分流(决策 5):
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

function Invoke-BridgeConflict {
    # conflict — 并行协作冲突注册表命令族(动作仅 open|resolve;上报/挂起为条目
    # 状态属性,经 open -ConflictId <id> 更新)。登记即拦截「默默二选一」:涉事节点
    # 推送门 hold / settle 门按 kind 分流;resolve 后下一触发点自动推送恢复。
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($Action)) { Write-ErrorResult "CONFLICT_ACTION_REQUIRED" "-Action is required (open / resolve)" 1 }
    $null = Enter-PlannerLease $runDir
    $tree = Get-TreeStatusView $RunId

    if ($Action -eq 'open') {
        if (-not [string]::IsNullOrWhiteSpace($ConflictId)) {
            # state-attribute update on an existing entry (escalated / suspended)
            $entry = Find-ConflictEntry $bridge $ConflictId
            if ($null -eq $entry) { Write-ErrorResult "CONFLICT_NOT_FOUND" "conflict '$ConflictId' is not in this run's registry (see status conflicts view)" 1 }
            if (([string]$entry['status']) -eq 'resolved') { Write-ErrorResult "CONFLICT_ALREADY_RESOLVED" "conflict '$ConflictId' is already resolved — a changed verdict reopens as a NEW conflict entry (registry is append-only)" 1 }
            if ($ConflictStatus -notin @('escalated', 'suspended')) {
                Write-ErrorResult "CONFLICT_ENTRY_INVALID" "state-attribute update needs -ConflictStatus escalated|suspended (上报/挂起是条目状态属性;open→escalated/suspended)" 1
            }
            if ($ConflictStatus -eq 'escalated' -and [string]::IsNullOrWhiteSpace($Escalation)) {
                Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-ConflictStatus escalated needs -Escalation <呈用户裁决的问题>(上报记录)" 1
            }
            $entry = Set-ConflictState $runDir $bridge $entry $ConflictStatus $Note $Escalation
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
        if ([string]::IsNullOrWhiteSpace($ConflictKind)) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-ConflictKind design|file is required for a new conflict entry" 1 }
        $nodeIds = Resolve-ConflictNodes $tree $Nodes
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
            $m = Get-NodeTaskStage $bridge $nid
            if ($null -ne $m -and ($taskIds -notcontains [int]$m.task_id)) { $taskIds += [int]$m.task_id }
        }
        $entry = Add-ConflictEntry -RunDir $runDir -Bridge $bridge -Kind $ConflictKind -NodeIds $nodeIds -TaskIds $taskIds -FilePaths $filePaths `
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

    if ([string]::IsNullOrWhiteSpace($ConflictId)) { Write-ErrorResult "CONFLICT_ENTRY_INVALID" "-Action resolve requires -ConflictId <C<n>>" 1 }
    $entry = Find-ConflictEntry $bridge $ConflictId
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
    $entry = Resolve-ConflictEntry $runDir $bridge $entry $ruling $Serialize
    return @{
        success = $true
        data    = [ordered]@{
            run_id     = $RunId
            conflict   = $entry
            serialized = $serialized
            report     = ".rdd/goal-trees/$RunId/report/design-conflicts.md"
            next_step  = "$($entry['id']) 已 resolved——涉事节点解除 hold,下一触发点自动推送恢复;设计返修经 reclaim rejected-delivery(调和结论写入 -Note/重做上下文)或 rollback 落地"
        }
    }
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
}

ConvertTo-PortableJson $result -Depth 14
exit 0

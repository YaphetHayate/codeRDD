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
#
# Hard constraint: "不合格交付不得流转" — settle enforces the three evidence checks
# (verdict=done / citations non-empty and real paths / extras.verification non-empty)
# before any task.json transition. Manual rdd-flow advance under a bridged run is
# forbidden by protocol (see references/planner-guide.md).

[CmdletBinding()]
param(
    [ValidateSet("promulgate", "dispatch", "claim", "reclaim", "rollback", "settle", "status", "resume", "conclude", "lease", "register-session", "decide", "escalate")]
    [string]$Command = "status",

    [string]$RunId,

    # promulgate
    [string]$TaskJson,
    [string]$ReviewFile,          # optional requirement-review verdicts (planner
                                   # session product; planner-guide hard constraint 6)
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
        return $arr
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
    if (-not $h.Contains('pending_sync') -or $null -eq $h['pending_sync']) { $h['pending_sync'] = @() }
    if (-not $h.Contains('pushes') -or $null -eq $h['pushes']) { $h['pushes'] = @{} }
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

function Invoke-AutoDispatch {
    # THE auto-push function (goal-tree-goal-root). Push = the same start-role
    # delivery chain the manual dispatch command uses. No concurrency cap
    # (decision 3: idempotent pushes, PM splits are small); per-node try/catch so
    # one failure never blocks the rest; per-node accounting in bridge.json v2.
    # Returns @{ trigger; considered; pushed; skipped; failed; bridge } — failures
    # are data, never exceptions (callers embed them in their own output).
    param([string]$RunDir, $Bridge, [string]$Trigger)
    # Run-level isolation gate (bridge.json no_push, set by promulgate -NoPush):
    # every auto-dispatch trigger funnels through here, so one upfront check
    # makes an isolated run provably zero-backend for its whole lifetime — the
    # 0923 incident mechanism was exactly a later trigger (the status touch)
    # re-deriving never-pushed nodes as candidates and really pushing them
    # (QA F1). The manual dispatch command stays open: an explicit human action
    # is the designated isolation override.
    if (Test-PropPresent $Bridge 'no_push' -and $Bridge['no_push'] -eq $true) {
        return @{ trigger = "$Trigger (no_push)"; considered = 0; pushed = @(); skipped = @(); failed = @(); bridge = $Bridge; no_push = $true }
    }
    $result = @{ trigger = $Trigger; considered = 0; pushed = @(); skipped = @(); failed = @() }
    $treeData = Get-TreeStatusView $Bridge.run_id
    # whole-tree status/depends maps: unlock is computed HERE, not via the leaf next
    # view alone — parked (reclaim) nodes are status=claimed and never appear in
    # next's pending list, yet they are exactly the recycle-then-repush targets.
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
    $nx = Get-LeafNextView $Bridge.run_id
    if ($null -ne $nx) {
        foreach ($p in @(Convert-ToSafeArray $nx.pending)) {
            $pnid = if ($p -is [string]) { $p } else { [string]$p.id }
            $statusOf[$pnid] = "pending"
            if ($p -isnot [string]) { $dependsOf[$pnid] = @(Convert-ToSafeArray $p.depends_on) }
        }
        foreach ($b in @(Convert-ToSafeArray $nx.blocked)) {
            $bnid = if ($b -is [string]) { $b } else { [string]$b.id }
            $statusOf[$bnid] = "pending"
            if ($b -isnot [string]) { $dependsOf[$bnid] = @(Convert-ToSafeArray $b.depends_on) }
        }
    }
    foreach ($nodeId in @($Bridge.nodes.Keys)) {
        $mapping = Get-NodeTaskStage $Bridge $nodeId
        if ($null -eq $mapping) { continue }
        $result.considered++
        $node = Get-NodeFromTree $treeData $nodeId
        $status = if ($node) { [string]$node.status } else { "missing" }
        # parked = recycled by reclaim, waiting for the next claimant: it is a PUSH
        # target (the "recycle then re-push" loop), unlike a live worker claim.
        $parked = ($status -eq "claimed" -and [string]$node.claimed_by -eq "planner-reclaim")
        if ($status -in @("done", "pruned", "reported", "missing") -or ($status -eq "claimed" -and -not $parked)) {
            $result.skipped += @{ node = $nodeId; reason = $status }
            continue
        }
        # unlock gate: every depends_on target must be terminal (done; pruned also
        # satisfies — prune discharges the obligation, same as the leaf claim gate).
        $deps = @()
        if ($null -ne $node -and $node.PSObject.Properties['depends_on'] -and $node.depends_on) { $deps = @($node.depends_on) }
        elseif ($dependsOf.ContainsKey($nodeId)) { $deps = $dependsOf[$nodeId] }
        $blockedHere = @()
        foreach ($d in $deps) {
            $ds = if ($statusOf.ContainsKey([string]$d)) { $statusOf[[string]$d] } else { "missing" }
            if (@('done', 'pruned') -notcontains $ds) { $blockedHere += [string]$d }
        }
        if ($blockedHere.Count -gt 0) {
            $result.skipped += @{ node = $nodeId; reason = "blocked_by_deps"; blocked_by = @($blockedHere) }
            continue
        }
        $pushState = Get-NodePushState $Bridge $nodeId
        $pushedOk = ($null -ne $pushState -and $pushState.Contains('last_ok_at') -and $null -ne $pushState['last_ok_at'])
        $needsRepush = ($null -ne $pushState -and $pushState.Contains('needs_repush') -and [bool]$pushState['needs_repush'])
        if ($pushedOk -and -not $needsRepush) {
            $result.skipped += @{ node = $nodeId; reason = "already_pushed" }
            continue
        }
        # pointer-class failures (session created, pointer message failed) are MANUAL
        # re-push only — an auto retry would stack a duplicate session (decision 5).
        # (Get-NodePushState normalizes to deep hashtables — single access path.)
        if ($needsRepush) {
            $attempts = @()
            if ($pushState.Contains('attempts') -and $null -ne $pushState['attempts']) { $attempts = @(Convert-ToSafeArray $pushState['attempts']) }
            $lastAttempt = if ($attempts.Count -gt 0) { $attempts[-1] } else { $null }
            $lastClass = $null
            if ($null -ne $lastAttempt -and $lastAttempt -is [System.Collections.IDictionary] -and $lastAttempt.Contains('retry_class')) { $lastClass = [string]$lastAttempt['retry_class'] }
            if ($lastClass -eq 'pointer') {
                $result.skipped += @{ node = $nodeId; reason = "pointer_manual_repush"; retry_class = $lastClass }
                continue
            }
        }
        # task brief (dispatch-task-goal-anchoring): goal-first statement for
        # the pushed session's pointer message, derived from the PERSISTED
        # node.task (in-place from the leaf next view first — its pending
        # entries carry the full task text; the per-node status probe covers
        # the rest, e.g. parked reclaim nodes). Empty brief (legacy-format
        # nodes, read failures) → arg omitted → zero injection.
        $taskText = ""
        if ($null -ne $nx) {
            foreach ($p in @(Convert-ToSafeArray $nx.pending)) {
                if (([string]$p.id) -eq $nodeId -and $null -ne $p.PSObject.Properties['task']) { $taskText = [string]$p.task }
            }
        }
        if (-not $taskText) { $taskText = Get-NodeTaskText -RunId $Bridge.run_id -NodeId $nodeId }
        $brief = Get-NodeTaskBrief -NodeTask $taskText -NodeId $nodeId
        # session-list-badges: the workspace-row summary rides start-role's
        # -TaskSummary (title channel). Same zero-injection contract as the
        # brief: unparseable/legacy node.task → "" → arg omitted.
        $summary = Get-NodeTaskSummary -NodeTask $taskText
        try {
            # -GoalTreeRun/-GoalTreeNode stamp the pointer message with the bridge
            # marker so the pushed worker session knows (first turn) that completion
            # goes back to the Planner via leaf report, not a 4-step direct handoff
            # (planner-callback-handoff dual-channel check, channel 1).
            $startArgs = @("-Role", $mapping.stage, "-TaskId", "$($mapping.task_id)", "-TaskJson", (Join-Path $Bridge.archive "task.json"), "-GoalTreeRun", $Bridge.run_id, "-GoalTreeNode", $nodeId)
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
        $Bridge = Set-NodePushRecord $RunDir $Bridge $nodeId $ok $errText $retryClass
        if ($ok) {
            $result.pushed += $nodeId
            # roster write-back (planner-session-roster): advisory, silent skip
            $null = Register-PushedSession -RunDir $RunDir -RunIdText ([string]$Bridge.run_id) -Stage $mapping.stage -TaskIdNum $mapping.task_id -NodeId $nodeId -StartRoleText $r.text
        }
        else { $result.failed += @{ node = $nodeId; error = $errText; retry_class = $retryClass } }
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

# === Command: promulgate ===

function Invoke-Promulgate {
    if ([string]::IsNullOrWhiteSpace($TaskJson)) { Write-ErrorResult "MISSING_TASK_JSON" "-TaskJson (archive task.json path) is required" 1 }
    $tj = $TaskJson
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

    $flow = Read-ArchiveTasks $archivePath
    $tasks = $flow.tasks
    if ($tasks.Count -eq 0) { Write-ErrorResult "EMPTY_ARCHIVE" "No tasks in task.json: $tj" 2 }
    $allIds = @($tasks | ForEach-Object { [int]$_.id })
    $archiveRel = ".rdd/changes/archive/$archiveName"

    # requirement review gate (planner-requirement-review): the planner session
    # reviews every sub-requirement BEFORE the tree exists and hands its verdicts
    # over as a ReviewFile; this layer mechanically consumes them — excluded
    # tasks (merged / reject_return) never graft, depends_on_override wholesale-
    # replaces regex inference, deps on a merged task redirect to the absorber,
    # deps dangling on a rejected task hard-fail (never silently dropped).
    # Default (no -ReviewFile): everything below short-circuits — promulgate is
    # byte-for-byte identical to the pre-review behavior (regression guarantee).
    $review = $null
    $deprecatedIds = @()
    $excludedMerge = @{}    # taskId -> absorber taskId (dep redirect + annex note)
    $excludedReject = @{}   # taskId -> $true (conclude-gate exemption set)
    $verdictOf = @{}        # taskId -> verdict (node-producing tasks only)
    $verdictById = @{}      # taskId -> verdict (all, for review.md rendering)
    if (-not [string]::IsNullOrWhiteSpace($ReviewFile)) {
        $review = Read-ReviewFile $ReviewFile $allIds
        $deprecatedIds = @($tasks | Where-Object { ([string]$_.lifecycle) -eq 'deprecated' } | ForEach-Object { [int]$_.id })
        foreach ($v in @($review.verdicts)) {
            $tid = [int]$v['task_id']
            $verdict = [string]$v['verdict']
            $verdictById[$tid] = $v
            # deprecated tasks are excluded before the review ever runs: only a
            # merged_into verdict documents their (already executed) pre-promulgate
            # deprecate; any other verdict on one is meaningless bookkeeping.
            if (($deprecatedIds -contains $tid) -and ($verdict -ne 'tree_adjudicated' -or -not $v.Contains('merged_into_task_id'))) {
                Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid is deprecated (excluded from delivery before the review) — only a merged_into verdict documents its pre-promulgate deprecate; remove task #$tid from the ReviewFile" 2
            }
            switch ($verdict) {
                'reject_return'    { $excludedReject[$tid] = $true }
                'tree_adjudicated' {
                    if ($v.Contains('merged_into_task_id')) { $excludedMerge[$tid] = [int]$v['merged_into_task_id'] }
                    else { $verdictOf[$tid] = $v }
                }
                default            { $verdictOf[$tid] = $v }
            }
        }
        # merge-target survival: the absorber must itself produce an initial node —
        # not deprecated, not rejected, not absorbed away (no merge chains).
        foreach ($tid in @($excludedMerge.Keys)) {
            $target = [int]$excludedMerge[$tid]
            if (($deprecatedIds -contains $target) -or $excludedMerge.Contains($target) -or $excludedReject.Contains($target)) {
                Write-ErrorResult "REVIEW_FILE_INVALID" "task #$tid merged_into_task_id=$target does not survive the review (deprecated / rejected / itself merged) — merge into a task this run actually delivers" 2
            }
        }
    }

    # pure-auto-mode snapshot build (planner-auto-mode): EARLY, before any run
    # state exists — an invalid -RiskPolicy is a deterministic usage error and
    # must never leave a half-promulgated run behind (the Read-ReviewFile
    # ordering discipline). $null when -AutoMode is absent (byte-identical
    # legacy promulgation); the snapshot lands in bridge.json at 3c-2 below.
    # NOTE: the local is named $amSnapshot (NOT $autoMode) — PS variable names
    # are case-INsensitive, so a `$autoMode = $null` init would shadow the
    # bound $AutoMode switch before the `if` below ever reads it.
    $amSnapshot = $null
    if ($AutoMode) {
        $amSnapshot = New-AutoModeSnapshot $RiskPolicy
    }

    # stage resolution + dependency inference (task-level, from requirement docs)
    $plan = @()
    $skippedReview = @()
    foreach ($t in $tasks) {
        if (([string]$t.lifecycle) -eq 'deprecated') { continue }   # deprecated tasks are not promulgated
        $taskId = [int]$t.id
        if ($excludedReject.Contains($taskId) -or $excludedMerge.Contains($taskId)) {
            $skippedReview += $taskId        # review-excluded tasks build no node, enter no bridge.tasks, never push
            continue
        }
        $group = @(Resolve-InitialGroup $t)
        $null = Resolve-TaskPhase $t $group   # phase gate: PHASE_INVALID / PHASE_OWNER_MISMATCH / GROUP_DIVERGENT_NEXT
        $depIds = @(Get-RequirementDepTaskIds $archivePath $t $allIds)
        $isOverride = $false
        if ($verdictOf.Contains($taskId) -and $verdictOf[$taskId].Contains('depends_on_override')) {
            # override presence wholesale-replaces regex inference ([] clears all deps)
            $depIds = @($verdictOf[$taskId]['depends_on_override'] | ForEach-Object { [int]$_ })
            $isOverride = $true
        }
        $explicitDeps = @()
        if ($null -ne $review) {
            $resolved = @()
            foreach ($d in $depIds) {
                $di = [int]$d
                if ($excludedMerge.Contains($di)) {
                    # merged-away dep: redirect to the absorber (its delivery covers
                    # the merged scope) — review key rule 1.
                    $absorber = [int]$excludedMerge[$di]
                    if ($resolved -notcontains $absorber) { $resolved += $absorber }
                    if ($explicitDeps -notcontains $absorber) { $explicitDeps += $absorber }
                }
                elseif ($excludedReject.Contains($di)) {
                    # dep dangling on a rejected task: hard error, never a silent drop —
                    # a silent drop would push this task prematurely (the exact
                    # mis-ordering bug class this gate exists to kill).
                    Write-ErrorResult "REVIEW_EXCLUDED_DEP" "task #$taskId depends on task #$di, which the review rejected back to PM — adjudicate task #$taskId as well (depends_on_override, or reject it too); the dependency will not be silently dropped" 1
                }
                else {
                    if ($isOverride -and ($deprecatedIds -contains $di)) {
                        Write-ErrorResult "REVIEW_FILE_INVALID" "task #$taskId depends_on_override entry #$di is deprecated (delivers nothing, anchors no node) — override to tasks this run delivers, or drop the entry" 2
                    }
                    if ($resolved -notcontains $di) { $resolved += $di }
                    if ($isOverride -and $explicitDeps -notcontains $di) { $explicitDeps += $di }
                }
            }
            $depIds = @($resolved)
        }
        $plan += @{ task = $t; group = $group; dep_ids = $depIds; explicit_deps = $explicitDeps }
    }
    if ($null -ne $review -and $plan.Count -eq 0) {
        Write-ErrorResult "REVIEW_FILE_INVALID" "the review excluded every deliverable task — nothing to promulgate" 2
    }

    $effWidth = if ($NodeWidth -gt 0) { $NodeWidth } else { [Math]::Max(4, $plan.Count) }
    $effMaxNodes = if ($MaxNodes -gt 0) { $MaxNodes } else { ($plan.Count * 5 + 6) }

    # goal root payload (goal-tree-goal-root): the original requirement as the
    # final objective — title + description travel via the file channel (same
    # encoding-safety convention as graft's -TasksFile).
    $goal = Read-ArchiveGoal $archivePath $plan
    $goalFile = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-goal-{0}.md" -f ([guid]::NewGuid().ToString("N").Substring(0, 10)))
    [System.IO.File]::WriteAllText($goalFile, $goal.description, $script:Utf8NoBom)

    # 1) goal-tree start in goal-root mode (RefRoots = whole repo: delivery citations
    #    are change lists anywhere). start itself is atomic (manifest CreateNew), so
    #    a concurrent double-promulgate loses here before any bridge state exists.
    try {
        $r = Invoke-GoalTree @("-Command", "start", "-RunId", $runId,
            "-Goal", "$($goal.title) — deliver $archiveRel",
            "-Title", $goal.title,
            "-GoalRoot", "-GoalFile", $goalFile,
            "-RefRoots", ".", "-CreatedBy", $CreatedBy,
            "-MaxRounds", "$MaxRounds", "-NodeWidth", "$effWidth", "-MaxNodes", "$effMaxNodes",
            "-Notes", "delivery-bridge run for $archiveRel")
    }
    finally {
        Remove-Item -LiteralPath $goalFile -Force -ErrorAction SilentlyContinue
    }
    if ($r.exit -ne 0 -or -not $r.json.success) { Write-ErrorResult "PROMULGATE_START_FAILED" "goal-tree start failed: $($r.text)" 3 }
    $runDir = Join-Path $script:GoalTreesRoot $runId

    $null = Enter-PlannerLease $runDir

    # planner body roster row (planner-session-roster): the promulgating dsh
    # session IS this run's planner — register it right after the run dir
    # exists (advisory; CLI planners carry no DSH_SESSION_ID and skip silently).
    $null = Register-PlannerBody -RunDir $runDir -RunIdText $runId

    # 2) open round 1 (kept open for the whole delivery; conclude auto-closes it)
    $r = Invoke-GoalTree @("-Command", "round-start", "-RunId", $runId)
    if ($r.exit -ne 0 -or -not $r.json.success) { Write-ErrorResult "PROMULGATE_ROUND_FAILED" "round-start failed: $($r.text)" 3 }

    # 3) graft one chain-head node per (task, initial group role) under the goal root;
    #    deps point at EVERY chain head of each dep task (phase-model multi-anchor:
    #    the dependent unlocks only when the whole upstream phase settles). The
    #    requirement chain heads (first-stage work nodes, ref-bound to their
    #    requirement docs) ARE the goal root's children — the "requirement node"
    #    layer and the first work node are one (decision 4). Parallel owners each
    #    get their own head (the old single-stage resolution dropped all but the
    #    first owner's work); stages stay single-value per role key in bridge.tasks
    #    so a parallel group never collides.
    $bridge = @{
        format_version  = 2
        run_id          = $runId
        archive         = $archivePath
        archive_rel     = $archiveRel
        promulgated_at  = Get-UtcNowIso
        created_by      = $CreatedBy
        goal_root       = "n1"
        goal            = @{ title = $goal.title; source = $goal.source }
        tasks           = @{}
        nodes           = @{}
        pending_sync    = @()
        pushes          = @{}
    }
    $initialNodesOfTask = @{}
    foreach ($p in $plan) {
        $t = $p.task
        $taskId = [int]$t.id
        $group = @($p.group)
        $depNodes = @()
        foreach ($d in $p.dep_ids) { if ($initialNodesOfTask.ContainsKey($d)) { $depNodes += @($initialNodesOfTask[$d]) } }
        # bookkeeping for the deferred review-edge stitching below (single-pass
        # graft can only express deps on already-grafted nodes)
        $p['grafted_dep_nodes'] = @($depNodes)

        $reqRel = ([string]$t.requirement -replace '\\', '/')
        $designRels = @()
        foreach ($d in @(Convert-ToSafeArray $t.designDocs)) { $designRels += ([string]$d.path -replace '\\', '/') }
        $bridge.tasks["$taskId"] = @{
            title          = [string]$t.title
            requirement    = $reqRel
            initial_group  = @($group)
            dep_task_ids   = @($p.dep_ids)
            stages         = @{}
        }
        $initialNodesOfTask[$taskId] = @()
        foreach ($role in $group) {
            # goal-first node task text (dispatch-task-goal-anchoring): single
            # authoritative producer — see New-NodeTaskText above
            $taskText = New-NodeTaskText -Title ([string]$t.title) -Stage $role -ReqRel $reqRel -DesignRels $designRels -RunId $runId
            $graftItem = @{
                title      = [string]$t.title
                task       = $taskText
                role       = $role.ToLower()
                ref        = "$archiveName/$reqRel"   # requirement-node ref ↔ the requirement doc (goal-tree-goal-root AC-1)
            }
            if ($depNodes.Count -gt 0) { $graftItem['depends_on'] = @($depNodes) }
            $g = Invoke-GraftOne $runId "n1" $graftItem
            if (-not $g.ok) { Write-ErrorResult "PROMULGATE_GRAFT_FAILED" "graft failed for task $taskId ($role): $($g.text)" 3 }
            $nodeId = $g.node_id
            Set-NodeTaskStage $bridge $nodeId $taskId $role
            $initialNodesOfTask[$taskId] += $nodeId
        }
    }

    # 3b) deferred review-edge stitching: single-pass graft can only express deps
    #     on already-grafted nodes (task order); when the planner's override or a
    #     merge-redirect points at a task grafted LATER, the edge is added here via
    #     the public deps CLI (DAG-validated, deps-log audited) instead of silently
    #     vanishing. Inferred (non-adjudicated) deps keep the legacy one-pass shape.
    #     Per-node edge stitching lives in Get-DeferredEdgesForNode (nesting cap).
    $deferredEdges = @()
    if ($null -ne $review) {
        foreach ($p in $plan) {
            if (@($p['explicit_deps']).Count -eq 0) { continue }
            $have = @($p['grafted_dep_nodes'])
            foreach ($nodeId in @($initialNodesOfTask[[int]$p.task.id])) {
                $deferredEdges += @(Get-DeferredEdgesForNode -RunId $runId -TaskId ([int]$p.task.id) -NodeId $nodeId -ExplicitDeps @($p['explicit_deps']) -GraftedDepNodes $have -InitialNodesOfTask $initialNodesOfTask)
            }
        }
    }

    # 3c) bridge.json v2 review section (machine-readable audit: disposition type /
    #     reason / times — acceptance 2). Old runs without it read unchanged
    #     (Test-PropPresent convention).
    $reviewAppliedAt = $null
    if ($null -ne $review) {
        $reviewAppliedAt = Get-UtcNowIso
        $bridge['review'] = @{
            reviewed_at = $review.reviewed_at
            reviewer    = $review.reviewer
            verdicts    = @($review.verdicts)
            applied_at  = $reviewAppliedAt
        }
    }

    # 3c-2) auto_mode snapshot (planner-auto-mode): ONLY for -AutoMode
    #       promulgations — the immutable in-run copy built EARLY above (default
    #       R1-R9, or the -RiskPolicy wholesale override with the R1
    #       constitutional hard floor force-merged back) lands in bridge.json.
    #       Absent when off: byte-identical legacy promulgation (the -ReviewFile
    #       gating discipline).
    if ($null -ne $amSnapshot) {
        $bridge['auto_mode'] = $amSnapshot
    }

    # 3c-3) -NoPush isolation as a PERSISTED run-level attribute (0923 incident
    #       response, QA F1): a promulgate-time skip alone was pierceable — every
    #       later auto-dispatch trigger (status touch / reclaim / settle /
    #       rollback) re-derived never-pushed nodes as candidates and really
    #       pushed them. Invoke-AutoDispatch consumes this flag at the top of its
    #       gate chain, so the run stays zero-backend for its whole lifetime;
    #       absent when off: byte-identical legacy promulgation.
    if ($NoPush) { $bridge['no_push'] = $true }

    Write-BridgeFile $runDir $bridge

    # 3d) report/review.md — the human-readable per-task conclusions table
    #     (acceptance 1: the persistent carrier presented to the user; the
    #     planner session renders the same verdicts live from the JSON return).
    if ($null -ne $review) {
        $revDir = Join-Path $runDir "report"
        if (-not (Test-Path -LiteralPath $revDir)) { New-Item -ItemType Directory -Path $revDir -Force | Out-Null }
        $verdictLabel = @{ pass = "通过"; tree_adjudicated = "树内裁定"; reject_return = "驳回回流" }
        $rl = @()
        $rl += "# 需求审查结论 — $runId"
        $rl += ""
        $rl += "- 归档: $archiveRel"
        $rl += "- 审查时间: $($review.reviewed_at) · 审查者: $($review.reviewer) · 应用时间: $reviewAppliedAt"
        $rl += ""
        $rl += "| Task | 标题 | 结论 | 理由 | 处置 |"
        $rl += "|------|------|------|------|------|"
        foreach ($t in $tasks) {
            $taskId = [int]$t.id
            $isDep = (([string]$t.lifecycle) -eq 'deprecated')
            if ($isDep -and -not $verdictById.Contains($taskId)) { continue }
            $label = "通过"; $reason = "（未单列 = 审查通过）"; $disp = "正常建树"
            if ($verdictById.Contains($taskId)) {
                $v = $verdictById[$taskId]
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
        if ($deferredEdges.Count -gt 0) {
            $rl += ""
            $rl += "> 延后缝合的审查依赖边（graft 单趟无法表达的前向引用，经 deps add 补齐并留 deps-log 审计）: $(@($deferredEdges | ForEach-Object { "#$($_.task_id)→#$($_.on_task_id)" }) -join '、')"
        }
        [System.IO.File]::WriteAllText((Join-Path $revDir "review.md"), ($rl -join "`n"), $script:Utf8NoBom)
    }

    # 4) initial dependency-driven push (goal-tree-goal-root): every node with no
    #    unsatisfied dependency gets its role session started right here — no
    #    manual per-node dispatch, no confirmation gate (decision 1-A/3).
    #    -NoPush (test/incident isolation): build the run but start NOTHING —
    #    deterministic zero-backend runs for the engine test-suite. The isolation
    #    lives in the PERSISTED run-level flag (bridge.json no_push=true, 3c-3
    #    above) and is re-asserted by Invoke-AutoDispatch's gate on every later
    #    trigger; this local early-out only spells the trigger out in the
    #    response and keeps the per-node pushes ledger empty.
    if ($NoPush) {
        $push = @{ trigger = "promulgate (-NoPush)"; considered = 0; pushed = @(); skipped = @(); failed = @() }
    } else {
        $push = Invoke-AutoDispatch $runDir $bridge "promulgate"
    }

    return @{
        success = $true
        data    = @{
            promulgated  = $true
            run_id       = $runId
            archive      = $archiveRel
            directory    = ".rdd/goal-trees/$runId"
            goal_root    = @{ node = "n1"; title = $goal.title; source = $goal.source }
            tasks        = @($plan | ForEach-Object { @{ task_id = [int]$_.task.id; stage = @($_.group)[0]; group = @($_.group); node = @($initialNodesOfTask[[int]$_.task.id])[0]; nodes = @($initialNodesOfTask[[int]$_.task.id]); dep_task_ids = @($_.dep_ids) } })
            skipped_deprecated = @($tasks | Where-Object { ([string]$_.lifecycle) -eq 'deprecated' } | ForEach-Object { [int]$_.id })
            skipped_review    = @($skippedReview)
            review       = $(if ($null -ne $review) {
                @{
                    reviewed_at = $review.reviewed_at
                    reviewer    = $review.reviewer
                    applied_at  = $reviewAppliedAt
                    report      = ".rdd/goal-trees/$runId/report/review.md"
                    verdicts    = @($review.verdicts)
                    deferred_dep_edges = @($deferredEdges | ForEach-Object { "task#$($_.task_id)->task#$($_.on_task_id) ($($_.node)->$($_.on))" })
                }
            } else { $null })
            auto_mode     = $(if ($null -ne $amSnapshot) {
                @{
                    enabled       = $true
                    policy_source = $amSnapshot.policy_source
                    rule_count    = @($amSnapshot.policy.rules).Count
                    r1_floor      = "manual (hard floor, force-merged)"
                    protocol      = Get-AutoModeProtocolHint $runId
                }
            } else { $null })
            budget       = @{ max_rounds = $MaxRounds; node_width = $effWidth; max_nodes = $effMaxNodes }
            lease        = @{ holder = (Get-LeaseState $runDir).holder }
            auto_push    = @{ trigger = $push.trigger; pushed = @($push.pushed); blocked = @($push.skipped | Where-Object { $_.reason -eq 'blocked_by_deps' } | ForEach-Object { $_.node }); failed = @($push.failed) }
            next_step    = "initial pushes are automatic (pushed: [$(@($push.pushed) -join ', ')]; dep-blocked nodes push when their dependencies settle). Workers start with: delivery-bridge.cmd -Command claim -RunId $runId -NodeId <id> -Role <stage>."
        }
    }
}

# === Command: dispatch ===

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

    # task brief (dispatch-task-goal-anchoring): the tree status view above
    # carries ids only for pending nodes, so the brief source is the per-node
    # leaf status probe (full node incl. task). Empty brief (legacy-format
    # nodes, read failures) → arg omitted → zero injection.
    $nodeTaskText = Get-NodeTaskText -RunId $RunId -NodeId $NodeId
    $brief = Get-NodeTaskBrief -NodeTask $nodeTaskText -NodeId $NodeId
    # session-list-badges: workspace-row summary rides -TaskSummary (title
    # channel); zero-injection contract identical to the brief above.
    $summary = Get-NodeTaskSummary -NodeTask $nodeTaskText
    $startArgs = @("-Role", $mapping.stage, "-TaskId", "$($mapping.task_id)", "-TaskJson", (Join-Path $bridge.archive "task.json"), "-GoalTreeRun", $RunId, "-GoalTreeNode", $NodeId)
    if ($brief) { $startArgs += @("-TaskBrief", $brief) }
    if ($summary) { $startArgs += @("-TaskSummary", $summary) }
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

function Invoke-BridgeClaim {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $stage = if ([string]::IsNullOrWhiteSpace($Role)) { $mapping.stage } else { $Role }
    if ($script:RoleOrder -notcontains $stage) { Write-ErrorResult "ROLE_INVALID" "-Role must be one of PM/CTO/UX/DEV/QA" 1 }
    $taskId = $mapping.task_id

    # --- precheck 1: tree side (read-only) ---
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    # "parked" = recycled by reclaim and waiting for the next claimant: the tree side
    # shows claimed_by=planner-reclaim. A parked node is claimable (steal + force).
    $parked = ($node.status -eq "claimed" -and [string]$node.claimed_by -eq "planner-reclaim")
    if ($node.status -ne "pending" -and -not $parked) {
        # deterministic conflict feedback + claimable list (acceptance: duplicate sessions never spin);
        # only bridge-mapped nodes count (the structural root n1 is not a delivery unit)
        $claimable = @()
        $nx = Get-LeafNextView $RunId
        if ($null -ne $nx) {
            foreach ($p in @(Convert-ToSafeArray $nx.pending)) {
                if ($null -ne (Get-NodeTaskStage $bridge ([string]$p.id))) { $claimable += $p.id }
            }
        }
        $who = if ($node.claimed_by) { " (claimed_by=$($node.claimed_by) at $($node.claimed_at))" } else { "" }
        Write-ErrorResult "NODE_NOT_CLAIMABLE" "Node $NodeId is '$($node.status)'$who. Claimable nodes right now: [$($claimable -join ', ')]. Pick one of those (delivery-bridge claim -RunId $RunId -NodeId <id> -Role <stage>)." 1
    }
    $blockedBy = @()
    if ($leafStatus.json.data.dependencies -and $leafStatus.json.data.dependencies.blocked_by) {
        $blockedBy = @($leafStatus.json.data.dependencies.blocked_by)
    }
    if ($blockedBy.Count -gt 0) {
        Write-ErrorResult "NODE_BLOCKED_BY_DEPS" "Node $NodeId is blocked by unsatisfied dependencies: [$($blockedBy -join ', ')]. Wait for them to settle or pick another node." 1
    }

    # --- precheck 2: flow side (read-only) ---
    $flow = Read-ArchiveTasks $bridge.archive
    $task = Find-ArchiveTask $flow.tasks $taskId
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $taskId not found in $($bridge.archive)" 2 }
    if (([string]$task.lifecycle) -ne "active") {
        Write-ErrorResult "TASK_NOT_CLAIMABLE" "TaskId $taskId lifecycle is '$($task.lifecycle)' (only active tasks can be claimed)" 1
    }
    $owners = @()
    if ($null -ne $task.currentOwners) { $owners = @($task.currentOwners) }
    if ($owners -notcontains $stage) {
        Write-ErrorResult "ROLE_NOT_OWNER" "'$stage' is not in currentOwners of TaskId ${taskId}: [$($owners -join '+')]" 1
    }
    $flowForce = $false   # set for parked slots AND replacement-node residue
    foreach ($w in @(Convert-ToSafeArray $task.currentWorker)) {
        if ($null -eq $w) { continue }
        $keys = @()
        if ($w -is [System.Collections.IDictionary]) { $keys = @($w.Keys) } else { $keys = @($w.PSObject.Properties | ForEach-Object { $_.Name }) }
        if ($keys -contains $stage) {
            $t0 = [string](@($w) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_[$stage] } else { $_.$stage } })
            if ($parked) {
                # the parked entry was left by reclaim for exactly this next claimant;
                # write 2 below overwrites it with -Force
                $flowForce = $true
                continue
            }
            # replacement-node residue: reclaim's rejected-delivery mode grafts a fresh
            # PENDING node for the same (task, stage) while the flow entry lingers.
            # Invariant: a live flow claim <=> the bridge's current stage node is in an
            # actively claimed state. If the current stage node IS this (pending) node,
            # the flow entry must be reclaim residue -> overwrite with -Force.
            $curStageNode = $null
            if ($bridge.tasks.Contains("$taskId") -and $null -ne $bridge.tasks["$taskId"]['stages']) {
                $bStages = $bridge.tasks["$taskId"]['stages']
                if ($bStages.Contains($stage)) { $curStageNode = [string]$bStages[$stage] }
            }
            if ($curStageNode -eq $NodeId -and $node.status -eq "pending") {
                $flowForce = $true
                continue
            }
            Write-ErrorResult "FLOW_CLAIM_CONFLICT" "TaskId $taskId already has a currentWorker entry for $stage (claimed at $t0). If that session is dead, ask the Planner to run: delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $NodeId" 1
        }
    }

    # --- write 1: tree side (parked nodes need -Steal to leave the reclaim parking slot) ---
    $treeArgs = @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeId, "-Worker", $stage)
    if ($parked) { $treeArgs += "-Steal" }
    $r1 = Invoke-GoalTreeLeaf $treeArgs
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "TREE_CLAIM_FAILED" "leaf claim failed: $($r1.text)" 1
    }

    # --- write 2: flow side; a conflict here is a half-claim (rare after the precheck) ---
    $flowArgs = @("-Command", "claim", "-TaskId", "$taskId", "-Role", $stage, "-Archive", $bridge.archive)
    if ($flowForce) { $flowArgs += "-Force" }
    $r2 = Invoke-RddFlow $flowArgs
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        Write-ErrorResult "BRIDGE_CLAIM_HALF_FAILED" "Tree side claimed, rdd-flow claim errored: $($r2.text). Disposition: run 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $NodeId' to recycle the claim, or retry after fixing the flow-side error." 1
    }
    if ($r2.json.data.claimed -ne $true) {
        $conf = $r2.json.data.conflict
        Write-ErrorResult "BRIDGE_CLAIM_HALF_FAILED" "Tree side claimed but rdd-flow reports an existing $stage claim on TaskId $taskId (at $($conf.claimedAt)). Disposition: run 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId $NodeId' to recycle this half-claim." 1
    }

    return @{
        success = $true
        data    = @{
            run_id      = $RunId
            node_id     = $NodeId
            task_id     = $taskId
            stage       = $stage
            tree_claim  = @{ node = $r1.json.data.node; report_next = $r1.json.data.report_next; dep_note = $r1.json.data.dep_note }
            flow_claim  = @{ claimed = $r2.json.data.claimed; currentWorker = $r2.json.data.currentWorker }
            task        = $r2.json.data.task
            start_context = "requirement: $($bridge.archive_rel)/$($bridge.tasks["$taskId"].requirement) — full pointers in task.summary fields above"
            report_hint = "goal-tree bridge run: on completion report back to the Planner instead of start-role-ing a downstream role — goal-tree-leaf.cmd -Command report -RunId $RunId -Worker $stage -CallbackFile <cb.json>. Artifact locations ride the callback: citations = change list (real paths; settle checks every ref exists), full_report = main deliverable doc pointer (design doc / implementation notes; expected in bridge runs), extras.verification = verification result (settle requires citations + verification non-empty)"
            auto_mode   = $(if ($null -ne (Get-AutoModeSection $bridge)) {
                # authorization passthrough (planner-auto-mode): the claim is the
                # worker's mandatory first action, so it is the natural injection
                # point — enabled flag + the immutable snapshot + the protocol
                # hint (report_hint precedent). Absent on non-auto runs (legacy
                # claim responses stay byte-identical).
                @{
                    enabled  = $true
                    policy   = (Get-AutoModeSection $bridge)['policy']
                    protocol = Get-AutoModeProtocolHint $RunId
                }
            } else { $null })
        }
    }
}

# === Command: reclaim (composite recovery: dead claims AND rejected deliveries) ===

function Invoke-BridgeReclaim {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $stage = $mapping.stage
    $taskId = $mapping.task_id
    $worker = "planner-reclaim"

    # read-only state check: the recovery path depends on the node's status
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    $nodeStatus = [string]$node.status

    if ($nodeStatus -eq "reported") {
        # A reported node whose delivery FAILED the three-check gate: it can neither
        # re-report (leaf refuses non-claimed) nor settle (evidence rejected). Recovery
        # = prune the failed delivery (ledger keeps the audit trail) + graft a fresh
        # stage node + remap the bridge, so the task returns to workable state.
        $problems = @(Test-SettleEvidence -RunDir $runDir -Node $node -NodeId $NodeId)
        if ($problems.Count -eq 0) {
            Write-ErrorResult "RECLAIM_REQUIRES_UNQUALIFIED" "Node $NodeId is reported with QUALIFIED evidence — settle it instead (settle -RunId $RunId -NodeId $NodeId); reclaim only recovers dead claims or rejected deliveries." 1
        }
        $reason = "delivery rejected by settle evidence gate: $($problems -join '; ')"
        $rp = Invoke-GoalTree @("-Command", "prune", "-RunId", $RunId, "-NodeId", $NodeId, "-Reason", $reason)
        if ($rp.exit -ne 0 -or -not $rp.json.success) {
            Write-ErrorResult "RECLAIM_PRUNE_FAILED" "prune of rejected delivery failed: $($rp.text)" 1
        }
        # graft a replacement node for the same (task, stage) under the same parent
        $flow = Read-ArchiveTasks $bridge.archive
        $task = Find-ArchiveTask $flow.tasks $taskId
        if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $taskId not found in $($bridge.archive)" 2 }
        $g = Invoke-GraftNextStage $runDir $bridge $task ([string]$node.parent) $stage
        if (-not $g.success) { Write-ErrorResult "RECLAIM_GRAFT_FAILED" "replacement node graft failed after prune (task $taskId stays routed at $stage): $($g.error)" 1 }
        $bridge = $g.bridge
        $newNodeId = $g.node_id
        $null = Invoke-RddFlow @("-Command", "claim", "-TaskId", "$taskId", "-Role", $stage, "-Archive", $bridge.archive, "-Force")
        # the fresh replacement node is never-pushed by construction — push it now
        # (goal-tree-goal-root: recycle-then-repush, no manual dispatch step).
        $push = Invoke-AutoDispatch $runDir $bridge "reclaim"
        $bridge = $push.bridge
        return @{
            success = $true
            data    = @{
                run_id       = $RunId
                node_id      = $newNodeId
                pruned_node  = $NodeId
                task_id      = $taskId
                stage        = $stage
                reclaimed    = $true
                mode         = "rejected-delivery"
                auto_push    = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
                next_step    = "failed delivery pruned (ledger keeps the audit); replacement node $newNodeId grafted" + $(if (@($push.pushed) -contains $newNodeId) { " and auto-pushed" } else { " — re-push via status touch or dispatch -NodeId $newNodeId" })
            }
        }
    }

    if ($nodeStatus -eq "pending") {
        Write-ErrorResult "RECLAIM_NOT_NEEDED" "Node $NodeId is pending (nobody claimed it) — a plain bridge claim is enough; reclaim recovers dead claims or rejected deliveries." 1
    }
    if ($nodeStatus -in @("done", "pruned")) {
        Write-ErrorResult "RECLAIM_NOT_POSSIBLE" "Node $NodeId is '$nodeStatus' — terminal; nothing to reclaim." 1
    }

    # claimed: the dead-claim recovery path — but first prove the session is not
    # alive (goal-tree-goal-root decision 6): alive sessions are mechanically
    # unreclaimable (RECLAIM_TARGET_ALIVE — long-task miskill becomes physically
    # impossible); unknown liveness (CLI claims / endpoint unreachable) falls back
    # to the DeadClaimMinutes threshold — younger claims are not provably dead.
    $live = Get-ClaimLiveness $RunId $NodeId
    if ($live.liveness -eq "alive") {
        Write-ErrorResult "RECLAIM_TARGET_ALIVE" "Node $NodeId is claimed by a LIVE session (session_id=$($live.session_id), verified via $($live.reason)). Long-running work is not reclaimable — wait for its report, or have the session itself release/steal. If you are certain this is wrong, verify the session in dsh first." 1
    }
    if ($live.liveness -eq "unknown") {
        $ageMin = $null
        if ($node.claimed_at) {
            try { $ageMin = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($node.claimed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes } catch {}
        }
        if ($null -eq $ageMin -or $ageMin -lt $DeadClaimMinutes) {
            $shownAge = if ($null -ne $ageMin) { $ageMin } else { "?" }
            Write-ErrorResult "RECLAIM_UNPROVEN_DEAD" "Node $NodeId claim liveness is unknown ($($live.reason)) and the claim is only $shownAge min old (< $DeadClaimMinutes min threshold) — not provably dead, refusing to reclaim (better to wait than to miskill; timeout marks ≠ dead). Retry after the threshold, or reclaim from a dsh shell where the agents registry can verify the session." 1
        }
    }

    # tree side: -Steal only recovers nodes stuck in claimed
    $r1 = Invoke-GoalTreeLeaf @("-Command", "claim", "-RunId", $RunId, "-NodeId", $NodeId, "-Worker", $worker, "-Steal")
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "RECLAIM_TREE_FAILED" "leaf steal failed: $($r1.text)" 1
    }

    # flow side: -Force overwrites this role's timestamp
    $r2 = Invoke-RddFlow @("-Command", "claim", "-TaskId", "$taskId", "-Role", $stage, "-Archive", $bridge.archive, "-Force")
    if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
        Write-ErrorResult "RECLAIM_FLOW_FAILED" "rdd-flow claim -Force failed: $($r2.text)" 1
    }

    # recycle-then-repush loop closure (goal-tree-goal-root): the parked node needs
    # a fresh session — mark it for re-push and auto-dispatch immediately.
    $bridge = Set-NodeRepushFlag $runDir $bridge $NodeId
    $push = Invoke-AutoDispatch $runDir $bridge "reclaim"
    $bridge = $push.bridge

    return @{
        success = $true
        data    = @{
            run_id     = $RunId
            node_id    = $NodeId
            task_id    = $taskId
            stage      = $stage
            reclaimed  = $true
            mode       = "dead-claim"
            steal_count = $r1.json.data.node.steal_count
            liveness   = $live
            auto_push  = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed) }
            next_step  = $(if (@($push.pushed) -contains $NodeId) { "fresh session auto-pushed for the parked node; its first action re-claims with -Role $stage" } else { "node is parked as '$worker' — re-push it via status touch or dispatch -NodeId $NodeId (its first action re-claims with -Role $stage)" })
        }
    }
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

function Invoke-BridgeSettle {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }

    $null = Enter-PlannerLease $runDir

    $mapping = Get-NodeTaskStage $bridge $NodeId
    if ($null -eq $mapping) { Write-ErrorResult "NODE_NOT_MAPPED" "Node $NodeId is not in this run's bridge mapping" 2 }
    $stage = $mapping.stage
    $taskId = $mapping.task_id
    $nextStage = $script:StageNext[$stage]

    # --- state precheck: node must be reported ---
    $leafStatus = Invoke-GoalTreeLeaf @("-Command", "status", "-RunId", $RunId, "-NodeId", $NodeId)
    if ($leafStatus.exit -ne 0 -or $null -eq $leafStatus.json -or -not $leafStatus.json.success) {
        Write-ErrorResult "NODE_STATUS_FAILED" "leaf status failed: $($leafStatus.text)" 2
    }
    $node = $leafStatus.json.data.node
    if ($node.status -ne "reported") {
        Write-ErrorResult "SETTLE_REQUIRES_REPORTED" "Node $NodeId is '$($node.status)'; settle only accepts reported nodes (claim -> work -> leaf report first)." 1
    }

    # --- the three evidence checks (hard gate: no qualified delivery, no transition) ---
    $problems = @(Test-SettleEvidence -RunDir $runDir -Node $node -NodeId $NodeId)
    if ($problems.Count -gt 0) {
        Write-ErrorResult "SETTLE_EVIDENCE_REJECTED" "Unqualified delivery — task.json NOT transitioned. Disposition: reclaim the node (delivery-bridge -Command reclaim -RunId $RunId -NodeId $NodeId), have the worker fix the delivery, then report again; or re-dispatch. Problems: $($problems -join '; ')" 1
    }

    # --- flow-side prechecks (avoid the settle->set-route half-failure window) ---
    $flow = Read-ArchiveTasks $bridge.archive
    $task = Find-ArchiveTask $flow.tasks $taskId
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $taskId not found in $($bridge.archive)" 2 }
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
        if ($owners -notcontains $stage) {
            Write-ErrorResult "FLOW_ADVANCE_WOULD_FAIL" "Precheck: '$stage' is not in currentOwners of TaskId $taskId ([$($owners -join '+')]) — the phase-side set-route would mis-narrow. Fix routing or use rdd-flow set-route first." 1
        }
    }
    elseif ($null -ne $nextStage) {
        if ($owners -notcontains $stage) {
            Write-ErrorResult "FLOW_ADVANCE_WOULD_FAIL" "Precheck: '$stage' is not in currentOwners of TaskId $taskId ([$($owners -join '+')]) — advance would fail. Fix routing or use rdd-flow set-route first." 1
        }
    }

    # --- tree settle (irreversible) ---
    $settleArgs = @("-Command", "settle", "-RunId", $RunId, "-NodeId", $NodeId)
    if (-not [string]::IsNullOrWhiteSpace($Note)) { $settleArgs += @("-Note", $Note) }
    $r1 = Invoke-GoalTree $settleArgs
    if ($r1.exit -ne 0 -or -not $r1.json.success) {
        Write-ErrorResult "TREE_SETTLE_FAILED" "goal-tree settle failed (nothing transitioned): $($r1.text)" 1
    }

    # --- flow transition + chained next-stage graft; half-failures land in pending_sync ---
    $warnings = @()
    $graftedNext = $null
    $graftedNextNodes = @()
    if ($null -eq $taskPhase) {
        # LEGACY null-phase task: conservative degrade — byte-identical pre-phase
        # behavior (StageNext chain + single graft). New archives always carry phase.
        $tail = Invoke-LegacySettleFlow $runDir $bridge $task $NodeId $stage $nextStage
    }
    else {
        # PHASE MODE (phase-model.md §5.2). Owners narrowing keeps the phase and only
        # fills MISSING live nodes (serial CTO->UX inside DESIGN); the LAST settle of
        # the phase switches atomically to PhaseRoles[PhaseNext[phase]] and grafts the
        # next phase's heads (convergence — no per-branch fan-out, no tree split).
        $tail = Invoke-PhaseSettleFlow $runDir $bridge $task $NodeId $stage $owners $taskPhase
    }
    $bridge = $tail.bridge
    $warnings += @($tail.warnings)
    $graftedNext = $tail.graftedNext
    $graftedNextNodes = @($tail.graftedNextNodes)
    if (@($graftedNextNodes).Count -gt 0) { $graftedNext = @($graftedNextNodes)[0] }
    $flowOperation = $tail.flowOperation
    $taskLifecycle = $tail.taskLifecycle

    # --- dependency-driven unlock push (goal-tree-goal-root): settling this node may
    #     unlock other tasks' nodes (and grafted this task's own next phase) — push
    #     every newly unlocked node automatically; push failures are isolated data.
    $push = Invoke-AutoDispatch $runDir $bridge "settle"
    $bridge = $push.bridge
    foreach ($f in @($push.failed)) {
        $warnings += "auto-push failed for node $($f.node) (retry_class=$($f.retry_class)): session-create class auto-retries on the next trigger; pointer class needs manual dispatch. $($f.error)"
    }

    return @{
        success = $true
        data    = @{
            run_id          = $RunId
            node_id         = $NodeId
            task_id         = $taskId
            stage_settled   = $stage
            phase           = $(if ($null -ne $taskPhase) { $taskPhase } else { $null })
            flow_operation  = $flowOperation
            next_stage_node = $graftedNext
            next_stage_nodes = @($graftedNextNodes)
            task_lifecycle  = $taskLifecycle
            auto_push       = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed); skipped = @($push.skipped | ForEach-Object { "$($_.node):$($_.reason)" }) }
            warnings        = $warnings
            next_step       = $(if ($push.failed.Count -gt 0) { "repair failed pushes: session-create class auto-retries via status; pointer class → dispatch -NodeId <id> manually" } elseif ($taskLifecycle -eq "completed") { "task $taskId reached terminal state" } else { "unlocked nodes pushed automatically (see auto_push); failures retry via status touch" })
        }
    }
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
    param([string]$Title, [string]$Stage, [string]$ReqRel, [string[]]$DesignRels, [string]$RunId, $RedoContext)

    $duty = ""
    if ($script:StageDuty.Contains($Stage)) { $duty = "（$($script:StageDuty[$Stage])）" }
    $archiveName = $RunId -replace '^deliver-', ''

    $t = "目标：完成「$Title」的 $Stage 阶段$duty。"
    $t += "需求文档：$ReqRel"
    if (@($DesignRels).Count -gt 0) { $t += "；设计文档：$(@($DesignRels) -join '、')" }
    $t += "；归档：$archiveName。"
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
    # redo excerpt (planner-stage-rollback): ride the 重做上下文 section along
    # when it fits — room-aware so the claim command always survives the cap;
    # overlong redo text truncates here but the full text always remains in
    # node.task and the claim output (the brief only keeps the message compact)
    if ($NodeTask -match '重做上下文（跨阶段回退）：(?<redo>.+?)(?=开工动作（辅助）：)') {
        $redoPrefix = "重做上下文（跨阶段回退）："
        $room = 240 - $brief.Length - $redoPrefix.Length - $claimPart.Length - 1
        if (-not $claimPart) { $room = 0 }
        if ($room -ge 1) {
            $redoText = [string]$Matches['redo']
            if ($redoText.Length -gt $room) { $redoText = $redoText.Substring(0, $room) + "…" }
            $brief += $redoPrefix + $redoText
        }
    }
    $brief += $claimPart

    if ($brief.Length -gt 240) { $brief = $brief.Substring(0, 239) + "…" }
    return $brief
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
    # only supplied by rollback (rebuilt previous-stage node)
    $taskText = New-NodeTaskText -Title $title -Stage $NextStage -ReqRel $reqRel -DesignRels $designRels -RunId ([string]$Bridge.run_id) -RedoContext $RedoContext
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
        lease          = (Get-LeaseState $RunDir)
        flow_taskCount = $flow.tasks.Count
        terminalCount  = $terminalCount
    }
}

function Invoke-BridgeStatus {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $view = Get-BridgeOverview $runDir $bridge
    $bridge = $view.bridge

    # --- status touch catch-up push (goal-tree-goal-root trigger point 4): retry
    #     session-create-class failures and any push missed by a crash mid-batch.
    #     Best-effort and lease-aware: another live planner's lease owns pushing.
    $touch = @{ ran = $false; note = $null }
    if ($view.tree.state -ne "concluded") {
        $leaseTry = Try-PlannerLeaseForTouch $runDir
        if ($leaseTry.acquired) {
            $push = Invoke-AutoDispatch $runDir $bridge "status"
            $bridge = $push.bridge
            if (-not $leaseTry.was_mine) { $null = Invoke-LeaseRelease $runDir }
            $touch = @{ ran = $true; pushed = @($push.pushed); skipped = @($push.skipped); failed = @($push.failed) }
        }
        else {
            $touch = @{ ran = $false; note = "auto-push skipped: planner lease held by '$($leaseTry.holder)' (their orchestration owns pushing)" }
        }
    }

    # per-node push ledger view (failures with retry classes stay visible here)
    $pushRows = @()
    foreach ($nodeId in @($bridge.pushes.Keys)) {
        $st = $bridge.pushes[$nodeId]
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

    # claimed-node session liveness (read-only; unknown is normal outside dsh)
    $livenessRows = @()
    foreach ($n in @(Convert-ToSafeArray $view.tree.nodes.claimed)) {
        $cid = if ($n -is [string]) { $n } else { [string]$n.id }
        $live = Get-ClaimLiveness $RunId $cid
        $livenessRows += @{ node = $cid; claimed_by = $(if ($n -is [string]) { $null } else { $n.claimed_by }); liveness = $live.liveness; session_id = $live.session_id }
    }

    # session roster (planner-session-roster): every dsh session this run
    # derived — planner body, bridge dispatches, registered direct handoffs.
    # Rows stay listed for the run's whole life: the create-before-claim window
    # and off-tree direct sessions are exactly what this list keeps traceable.
    $roster = Read-Roster $runDir
    $sessionRows = @()
    foreach ($s in @($roster.sessions)) {
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

    $warnings = @()
    foreach ($w in @($view.tree.integrity.warnings)) { $warnings += "tree: $w" }
    if ($roster.corrupt) { $warnings += "sessions.json roster unparseable — read as empty (the next registration self-heals the file)" }
    if ($view.repair.remaining.Count -gt 0) { $warnings += "pending_sync unresolved: $(@($view.repair.remaining | ForEach-Object { "$($_.node):$($_.op)" }) -join ', ')" }
    if ($view.dead_claims.tree.Count -gt 0) { $warnings += "dead tree claim(s) (>= ${DeadClaimMinutes} min): $(@($view.dead_claims.tree | ForEach-Object { $_.node }) -join ', ') — reclaim them" }
    if ($view.dead_claims.flow.Count -gt 0) { $warnings += "dead flow claim(s): $(@($view.dead_claims.flow | ForEach-Object { "task#$($_.task_id):$($_.role)" }) -join ', ')" }
    if (@($view.flagged_deliveries).Count -gt 0) {
        $warnings += "unqualified reported delivery(ies): $(@($view.flagged_deliveries | ForEach-Object { $_.node }) -join ', ') — adjudicate: reclaim -NodeId <id> (redo the same stage) or rollback -NodeId <id> -Reason <why> (send the task one stage back)"
    }
    $failedPushes = @($pushRows | Where-Object { $_.retry_class })
    if ($failedPushes.Count -gt 0) {
        $warnings += "push failures: $(@($failedPushes | ForEach-Object { "$($_.node)($($_.retry_class))" }) -join ', ') — session-create class auto-retries on every status touch; pointer class needs manual dispatch"
    }

    # pure-auto-mode visibility block (planner-auto-mode): ONLY for -AutoMode
    # runs — enabled + per-node decision counts + the derived open-escalation
    # list (QA / the Planner audit every auto answer's inputs / rule / time /
    # decider from here or the ledger). Absent on legacy runs (byte-identical).
    $autoModeBlock = $null
    if ($null -ne (Get-AutoModeSection $bridge)) {
        $autoModeBlock = Get-AutoModeDecisionView $runDir $bridge $view.tree
        if (@($autoModeBlock.open_escalations).Count -gt 0) {
            $warnings += "open escalation(s): $(@($autoModeBlock.open_escalations | ForEach-Object { "$($_.entry_id)@$($_.node)/$($_.checkpoint)$(if ($_.historical) { ' (historical: node pruned)' })" }) -join ', ') — present them to the user; verdict lands via decide -Kind resolution"
        }
    }

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
            auto_push_touch = $touch
            auto_mode      = $autoModeBlock
            pending_sync   = $view.repair.remaining
            repaired_now   = $view.repair.repaired
            lease          = $view.lease
            terminal       = "$($view.terminalCount)/$($view.flow_taskCount)"
            warnings       = $warnings
            next_step      = $(if (@($view.flagged_deliveries).Count -gt 0) { "adjudicate unqualified delivery(ies) [$(@($view.flagged_deliveries | ForEach-Object { $_.node }) -join ', ')]: rollback -NodeId <id> -Reason <why> (one stage back) or reclaim -NodeId <id> (same-stage redo)" } elseif ($view.terminalCount -eq $view.flow_taskCount -and $view.flow_taskCount -gt 0) { "all tasks terminal — conclude: delivery-bridge.cmd -Command conclude -RunId $RunId -Summary <...>" } else { "settle reported nodes; pushes are automatic (initial/unlock/reclaim/rollback + status touch); claimable now: [$($view.claimable -join ', ')]" })
        }
    }
}

function Invoke-BridgeResume {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $view = Get-BridgeOverview $runDir $bridge

    # planner body roster row (planner-session-roster): a resuming planner
    # session joins the roster (advisory, idempotent by session_id; the roster
    # then shows every session that ever orchestrated this run).
    $null = Register-PlannerBody -RunDir $runDir -RunIdText $RunId

    $steps = @()
    if ($view.tree.state -eq "concluded") {
        $steps += "Run already concluded. Final report: report/final-report.md; delivery annex: report/delivery-annex.md."
    }
    else {
        $steps += "Round $($view.tree.round.open) is open since $($view.tree.round.open_started_at) — the bridge keeps one round open for the whole delivery; conclude closes it."
        foreach ($n in @(Convert-ToSafeArray $view.tree.nodes.reported)) {
            $id = if ($n -is [string]) { $n } else { $n.id }
            $steps += "Reported node awaiting settle: $id — run 'delivery-bridge.cmd -Command settle -RunId $RunId -NodeId $id' (three evidence checks gate the transition)."
        }
        if (@($view.flagged_deliveries).Count -gt 0) {
            $steps += "Unqualified reported delivery(ies) (settle will refuse): $(@($view.flagged_deliveries | ForEach-Object { $_.node }) -join ', ') — 'delivery-bridge.cmd -Command rollback -RunId $RunId -NodeId <id> -To <roles> -Phase <REQ|DESIGN|IMPL|VERIFY> -Reason <why>' (explicit cross-phase rollback target) or 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId <id>' (redo the same stage)."
        }
        if ($view.claimable.Count -gt 0) {
            $steps += "Dispatch sessions for claimable nodes: [$($view.claimable -join ', ')] — 'delivery-bridge.cmd -Command dispatch -RunId $RunId -NodeId <id>'."
        }
        if ($view.dead_claims.tree.Count -gt 0) {
            $steps += "Recover dead claims: $(@($view.dead_claims.tree | ForEach-Object { $_.node }) -join ', ') — 'delivery-bridge.cmd -Command reclaim -RunId $RunId -NodeId <id>'."
        }
        if ($view.repair.remaining.Count -gt 0) {
            $steps += "pending_sync divergence still unresolved (status retries the repair on every call): $(@($view.repair.remaining | ForEach-Object { "$($_.node):$($_.op)" }) -join ', ')."
        }
        if ($view.terminalCount -eq $view.flow_taskCount -and $view.flow_taskCount -gt 0) {
            $steps += "All tasks terminal — conclude with a summary."
        }
    }
    $steps += "Reported nodes are never re-consumed; duplicate sessions get deterministic conflict feedback from bridge claim."

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
            recovery_steps = $steps
            lease          = $view.lease
        }
    }
}

# === Command: conclude ===

function Invoke-BridgeConclude {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    if ([string]::IsNullOrWhiteSpace($Summary)) { Write-ErrorResult "MISSING_SUMMARY" "-Summary is required (closing summary for the delivery)" 1 }

    $null = Enter-PlannerLease $runDir

    $flow = Read-ArchiveTasks $Bridge.archive
    # review-gate exemption (planner-requirement-review): tasks the planner
    # rejected back to PM stay active@PM BY DESIGN — their rework happens outside
    # this run. The gate exempts EXACTLY the review section's reject_return set;
    # every other non-terminal task still hard-fails DELIVERY_INCOMPLETE.
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
    $notTerminal = @($flow.tasks | Where-Object {
        (([string]$_.lifecycle) -notin @("completed", "deprecated")) -and (-not $rejectReturned.Contains([int]$_.id))
    })
    if ($notTerminal.Count -gt 0) {
        Write-ErrorResult "DELIVERY_INCOMPLETE" "Not all tasks are terminal yet: $(@($notTerminal | ForEach-Object { "#$($_.id)($($_.lifecycle)) @$($_.currentOwners -join '+')" }) -join ', '). Settle/prune the remaining work first." 1
    }
    # reject_return tasks still non-terminal = the pending rejections (active@PM)
    $pendingRejects = @($flow.tasks | Where-Object {
        $rejectReturned.Contains([int]$_.id) -and (([string]$_.lifecycle) -notin @("completed", "deprecated"))
    })
    $pendingRejectIds = @($pendingRejects | ForEach-Object { [int]$_.id })
    $treeData = Get-TreeStatusView $RunId
    # only BRIDGE-MAPPED nodes are delivery units — the structural root node (n1)
    # stays pending forever and must not block the conclusion
    $mappedPending = @()
    foreach ($p in @(Convert-ToSafeArray $treeData.nodes.pending)) {
        if ($null -ne (Get-NodeTaskStage $Bridge ([string]$p))) { $mappedPending += [string]$p }
    }
    $mappedClaimed = @()
    foreach ($c in @(Convert-ToSafeArray $treeData.nodes.claimed)) {
        $cid = if ($c -is [string]) { $c } else { [string]$c.id }
        if ($null -ne (Get-NodeTaskStage $Bridge $cid)) { $mappedClaimed += $cid }
    }
    if ($mappedPending.Count -gt 0 -or $mappedClaimed.Count -gt 0) {
        Write-ErrorResult "TREE_NOT_SETTLED" "Tree still has pending/claimed delivery nodes: pending=[$($mappedPending -join ',')] claimed=[$($mappedClaimed -join ',')]. Settle or prune them first." 1
    }

    # anchor (goal-tree-goal-root): the goal root is the conclude anchor — goal-tree
    # validates it by root semantics (all direct children terminal). The root anchor
    # applies only when the tree node actually carries type=goal (v2-promulgated runs);
    # a legacy-shaped run (v1 bridge.json migrated to v2 over a plain structural root)
    # falls through to the legacy anchor resolution below.
    # NOTE: Get-NodeFromTree serves the status view, where pending/done/pruned nodes
    # are reduced to bare {id,status} — and the goal root stays pending forever — so
    # its type=goal must be read from the full state/tree.json instead.
    $anchor = $null
    $rootNode = $null
    $anchorType = $null
    if ((Test-PropPresent $Bridge 'goal_root') -and $Bridge.goal_root) {
        $treeFilePath = Join-Path (Join-Path $runDir "state") "tree.json"
        if (Test-Path -LiteralPath $treeFilePath -PathType Leaf) {
            try {
                $fullTree = [System.IO.File]::ReadAllText($treeFilePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $rootNode = @($fullTree.nodes | Where-Object { [string]$_.id -eq [string]$Bridge.goal_root })[0]
            } catch { $rootNode = $null }
        }
        if ($null -ne $rootNode -and [string]$rootNode.type -eq 'goal') { $anchor = [string]$Bridge.goal_root; $anchorType = 'goal' }
    }
    if ($null -eq $anchor) {
        foreach ($t in $flow.tasks) {
            $taskId = [int]$t.id
            if ($Bridge.tasks.Contains("$taskId")) {
                $bStages = $Bridge.tasks["$taskId"]['stages']
                if ($null -ne $bStages -and $bStages.Contains('QA')) { $anchor = [string]$bStages['QA'] }
            }
        }
    }
    if ($null -eq $anchor) {
        $doneList = @($treeData.nodes.done)
        if ($doneList.Count -gt 0) { $anchor = [string]$doneList[-1] }
    }
    if ($null -eq $anchor) { Write-ErrorResult "ANCHOR_UNRESOLVED" "No done node found to anchor the achieved conclusion" 1 }

    # 1) goal-tree conclude (auto-closes the open round; renders final-report.md)
    $r = Invoke-GoalTree @("-Command", "conclude", "-RunId", $RunId, "-Outcome", "achieved", "-AnchorNodeId", $anchor, "-Summary", $Summary)
    if ($r.exit -ne 0 -or -not $r.json.success) {
        Write-ErrorResult "TREE_CONCLUDE_FAILED" "goal-tree conclude failed: $($r.text)" 3
    }

    # 2) rdd-flow check (integrity of the whole archive routing)
    $chk = Invoke-RddFlow @("-Command", "check", "-Archive", $Bridge.archive)
    $checkOk = ($chk.exit -eq 0 -and $null -ne $chk.json -and $chk.json.success -and [int]$chk.json.data.issueCount -eq 0)
    $checkIssues = @()
    if ($null -ne $chk.json -and $chk.json.success) { $checkIssues = @(Convert-ToSafeArray $chk.json.data.issues) }

    # 3) delivery annex: per-task terminal state + check result
    $annexDir = Join-Path $runDir "report"
    if (-not (Test-Path -LiteralPath $annexDir)) { New-Item -ItemType Directory -Path $annexDir -Force | Out-Null }
    $lines = @()
    $lines += "# 交付结案附录 — $RunId"
    $lines += ""
    $lines += "- 归档: $($Bridge.archive_rel)"
    $lines += "- 结案时间: $(Get-UtcNowIso) · 发起: $($Bridge.created_by)"
    $lines += "- rdd-flow check: $(if ($checkOk) { '通过（0 issues）' } else { "发现问题 $($checkIssues.Count) 条" })"
    if ((Test-PropPresent $Bridge 'goal_root') -and $Bridge.goal_root -and (Test-PropPresent $Bridge 'goal') -and $null -ne $rootNode -and [string]$rootNode.type -eq 'goal') {
        # root-goal achievement state (goal-tree-goal-root AC-2): the original
        # requirement reached its final objective — every sub-requirement terminal
        # (goal-tree concluded the run anchored on the type=goal root). Review-
        # rejected sub-requirements pending at PM make it PARTIAL, rendered
        # honestly (never dressed up as complete) — acceptance 3 / edge #3.
        $goalTitle = if ($Bridge.goal.Contains('title')) { [string]$Bridge.goal['title'] } else { "-" }
        if ($pendingRejects.Count -eq 0) {
            $lines += "- 根目标: **达成** — goal 根 $($Bridge.goal_root)「$goalTitle」全部直接子需求节点终态（原始需求=最终目标）"
        } else {
            $lines += "- 根目标: **部分达成（$($pendingRejects.Count) 条驳回回流 PM，见任务终态表）** — goal 根 $($Bridge.goal_root)「$goalTitle」交付节点全部终态；驳回项 active@PM 为真实状态，修订后经后续 run/正常流程承接"
        }
    }
    $lines += ""
    $lines += "## 任务终态"
    $lines += ""
    $lines += "| Task | 标题 | 终态 | 阶段链 |"
    $lines += "|------|------|------|--------|"
    foreach ($t in $flow.tasks) {
        $taskId = [int]$t.id
        $chain = "-"
        if ($Bridge.tasks.Contains("$taskId")) {
            $bStages = $Bridge.tasks["$taskId"]['stages']
            if ($null -ne $bStages) {
                # phase-model display: parallel group "∥", phases "→" (Format-
                # StageChain iterates RoleOrder — PM heads included)
                $cPhase = [string]$t.phase
                if ([string]::IsNullOrEmpty($cPhase)) { $cPhase = "" }
                $chain = Format-StageChain $bStages $treeData $cPhase
            }
        }
        # review-gate annotations (planner-requirement-review): merged tasks carry
        # "deprecated (absorbed in-tree, not abandoned)"; pending rejects carry
        # their true active@PM state — the annex never dresses either up.
        $termCell = [string]$t.lifecycle
        if ($mergedInto.Contains($taskId)) {
            $termCell = "$termCell（树内合并至 #$($mergedInto[$taskId])，非放弃）"
        }
        elseif ($pendingRejectIds -contains $taskId) {
            $termCell = "$termCell（驳回回流 PM，修订中）"
        }
        $lines += "| $taskId | $([string]$t.title) | $termCell | $chain |"
    }
    $lines += ""
    if (-not $checkOk) {
        $lines += "## rdd-flow check 问题清单"
        $lines += ""
        foreach ($i in $checkIssues) { $lines += "- $i" }
        $lines += ""
    }
    $lines += "## 规划者结案摘要"
    $lines += ""
    $lines += $Summary
    $lines += ""
    [System.IO.File]::WriteAllText((Get-AnnexPath $runDir), ($lines -join "`n"), $script:Utf8NoBom)

    # 4) release the lease (delivery closed)
    $null = Invoke-LeaseRelease $runDir

    return @{
        success = $true
        data    = @{
            run_id         = $RunId
            concluded      = $true
            outcome        = "achieved"
            anchor_node    = $anchor
            anchor_type    = $anchorType
            flow_check     = @{ ok = $checkOk; issues = $checkIssues }
            final_report   = ".rdd/goal-trees/$RunId/report/final-report.md"
            delivery_annex = ".rdd/goal-trees/$RunId/report/delivery-annex.md"
            tasks_terminal = "$(@($flow.tasks | Where-Object { (([string]$_.lifecycle) -in @("completed", "deprecated")) -or $rejectReturned.Contains([int]$_.id) }).Count)/$($flow.tasks.Count)"
            reject_return_pending = @($pendingRejectIds)
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
}

ConvertTo-PortableJson $result -Depth 14
exit 0

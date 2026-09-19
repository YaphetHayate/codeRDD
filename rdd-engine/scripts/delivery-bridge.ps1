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
#               with no unsatisfied dependency (no manual dispatch, no gate)
#   dispatch    manual single-node start-role push (exception handling /
#               pointer-class re-push; the normal flow is auto-push)
#   claim       composite claim: read-only prechecks -> tree leaf claim -> rdd-flow claim
#   reclaim     composite recovery (dead-claim / rejected-delivery); alive sessions
#               are mechanically unreclaimable (RECLAIM_TARGET_ALIVE) — liveness via
#               the dsh agents registry, time-threshold fallback for unknown
#   settle      the ONLY task.json transition channel: three evidence checks ->
#               tree settle -> flow advance/complete -> auto-graft next stage ->
#               dependency-driven auto-push of newly unlocked nodes
#   status      joined view: tree census + task stages + dep blocking + dead claims +
#               pending_sync repair + push ledger + session liveness + catch-up push
#   resume      breakpoint view for a fresh Planner session
#   conclude    final report after all tasks reach terminal state (+ delivery-annex.md),
#               anchored on the goal root (root semantics: all direct children terminal)
#   lease       advisory Planner session lease (planner-lease.json, stale 30 min)
#
# Run artifacts (inside the goal-tree run dir, gitignored):
#   bridge.json           authoritative node<->TaskId mapping (v2: + goal_root anchor
#                         + per-node pushes ledger; v1 rejected BRIDGE_FORMAT_UNSUPPORTED)
#   planner-lease.json    advisory session lease
#   report/delivery-annex.md  per-task terminal states + rdd-flow check result
#                         + root-goal achievement state
#
# Hard constraint: "不合格交付不得流转" — settle enforces the three evidence checks
# (verdict=done / citations non-empty and real paths / extras.verification non-empty)
# before any task.json transition. Manual rdd-flow advance under a bridged run is
# forbidden by protocol (see references/planner-guide.md).

[CmdletBinding()]
param(
    [ValidateSet("promulgate", "dispatch", "claim", "reclaim", "settle", "status", "resume", "conclude", "lease")]
    [string]$Command = "status",

    [string]$RunId,

    # promulgate
    [string]$TaskJson,
    [int]$MaxRounds = 12,
    [int]$NodeWidth = 0,          # 0 = auto (>= task count, floor 4)
    [int]$MaxNodes = 0,           # 0 = auto (task count * 5 + 6)
    [string]$CreatedBy = "planner",

    # dispatch / claim / reclaim / settle
    [string]$NodeId,
    [string]$Role,                # stage role (CTO/UX/DEV/QA) for claim; inferred from node for others
    [string]$Session,             # Planner lease holder label

    # settle
    [string]$Note,

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
$repoRoot = (git rev-parse --show-toplevel).Trim()

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:GoalTreesRoot = Join-Path $repoRoot ".rdd/goal-trees"
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Stage model: a task's lifecycle crosses roles; each (task, stage) is one tree node.
# Chain parent: cto -> dev -> qa are parent/child; ux grafts as its own chain head
# when the task starts at UX (ux -> dev -> qa).
$script:StageOrder = @("CTO", "UX", "DEV", "QA")
$script:StageNext = @{ "CTO" = "DEV"; "UX" = "DEV"; "DEV" = "QA"; "QA" = $null }

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
        try {
            # -GoalTreeRun/-GoalTreeNode stamp the pointer message with the bridge
            # marker so the pushed worker session knows (first turn) that completion
            # goes back to the Planner via leaf report, not a 4-step direct handoff
            # (planner-callback-handoff dual-channel check, channel 1).
            $r = Invoke-StartRole @("-Role", $mapping.stage, "-TaskId", "$($mapping.task_id)", "-TaskJson", (Join-Path $Bridge.archive "task.json"), "-GoalTreeRun", $Bridge.run_id, "-GoalTreeNode", $nodeId)
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
        if ($ok) { $result.pushed += $nodeId }
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

function Resolve-InitialStage {
    # earliest pipeline role present in currentOwners; error when unresolved
    param($Task)
    $owners = @()
    if ($null -ne $Task.currentOwners) { $owners = @($Task.currentOwners) }
    foreach ($stage in $script:StageOrder) {
        if ($owners -contains $stage) { return $stage }
    }
    Write-ErrorResult "TASK_STAGE_UNRESOLVED" "Task $($Task.id) currentOwners=[$($owners -join '+')] contains no pipeline role (CTO/UX/DEV/QA); route the task first" 1
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

    # stage resolution + dependency inference (task-level, from requirement docs)
    $plan = @()
    foreach ($t in $tasks) {
        if (([string]$t.lifecycle) -eq 'deprecated') { continue }   # deprecated tasks are not promulgated
        $stage = Resolve-InitialStage $t
        $depIds = @(Get-RequirementDepTaskIds $archivePath $t $allIds)
        $plan += @{ task = $t; stage = $stage; dep_ids = $depIds }
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

    # 2) open round 1 (kept open for the whole delivery; conclude auto-closes it)
    $r = Invoke-GoalTree @("-Command", "round-start", "-RunId", $runId)
    if ($r.exit -ne 0 -or -not $r.json.success) { Write-ErrorResult "PROMULGATE_ROUND_FAILED" "round-start failed: $($r.text)" 3 }

    # 3) graft one node per (task, initial stage) under the goal root; deps point at
    #    dep tasks' initial nodes. The requirement chain heads (first-stage work
    #    nodes, ref-bound to their requirement docs) ARE the goal root's children —
    #    the "requirement node" layer and the first work node are one (decision 4).
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
    $initialNodeOfTask = @{}
    foreach ($p in $plan) {
        $t = $p.task
        $taskId = [int]$t.id
        $stage = $p.stage
        $depNodes = @()
        foreach ($d in $p.dep_ids) { if ($initialNodeOfTask.ContainsKey($d)) { $depNodes += $initialNodeOfTask[$d] } }

        $reqRel = ([string]$t.requirement -replace '\\', '/')
        $designRels = @()
        foreach ($d in @(Convert-ToSafeArray $t.designDocs)) { $designRels += ([string]$d.path -replace '\\', '/') }
        $taskText = "Execute TaskId $taskId stage $stage of $archiveRel. Requirement: $reqRel."
        if ($designRels.Count -gt 0) { $taskText += " Design: $($designRels -join ', ')." }
        $taskText += " First action: delivery-bridge.cmd -Command claim -RunId $runId -NodeId <this-node> -Role $stage."

        $graftItem = @{
            title      = [string]$t.title
            task       = $taskText
            role       = $stage.ToLower()
            ref        = "$archiveName/$reqRel"   # requirement-node ref ↔ the requirement doc (goal-tree-goal-root AC-1)
        }
        if ($depNodes.Count -gt 0) { $graftItem['depends_on'] = @($depNodes) }
        $g = Invoke-GraftOne $runId "n1" $graftItem
        if (-not $g.ok) { Write-ErrorResult "PROMULGATE_GRAFT_FAILED" "graft failed for task $taskId ($stage): $($g.text)" 3 }
        $nodeId = $g.node_id
        $bridge.tasks["$taskId"] = @{
            title          = [string]$t.title
            requirement    = $reqRel
            initial_stage  = $stage
            dep_task_ids   = @($p.dep_ids)
            stages         = @{}
        }
        Set-NodeTaskStage $bridge $nodeId $taskId $stage
        $initialNodeOfTask[$taskId] = $nodeId
    }

    Write-BridgeFile $runDir $bridge

    # 4) initial dependency-driven push (goal-tree-goal-root): every node with no
    #    unsatisfied dependency gets its role session started right here — no
    #    manual per-node dispatch, no confirmation gate (decision 1-A/3).
    $push = Invoke-AutoDispatch $runDir $bridge "promulgate"

    return @{
        success = $true
        data    = @{
            promulgated  = $true
            run_id       = $runId
            archive      = $archiveRel
            directory    = ".rdd/goal-trees/$runId"
            goal_root    = @{ node = "n1"; title = $goal.title; source = $goal.source }
            tasks        = @($plan | ForEach-Object { @{ task_id = [int]$_.task.id; stage = $_.stage; node = $initialNodeOfTask[[int]$_.task.id]; dep_task_ids = @($_.dep_ids) } })
            skipped_deprecated = @($tasks | Where-Object { ([string]$_.lifecycle) -eq 'deprecated' } | ForEach-Object { [int]$_.id })
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

    $r = Invoke-StartRole (@("-Role", $mapping.stage, "-TaskId", "$($mapping.task_id)", "-TaskJson", (Join-Path $bridge.archive "task.json"), "-GoalTreeRun", $RunId, "-GoalTreeNode", $NodeId) + $(if ($DryRun) { @("-DryRun") } else { @() }))
    # a real (non-dry-run) dispatch IS a push: record it in the ledger — the
    # manual path is the designated resolution for pointer-class failures, and
    # an unrecorded success would leave needs_repush stuck forever (status
    # would keep advertising manual work that is already done).
    if (-not $DryRun) {
        $okPush = ($r.exit -eq 0)
        $pushClass = $null
        if (-not $okPush) { $pushClass = Get-PushFailureClass $r.text }
        $bridge = Set-NodePushRecord $runDir $bridge $NodeId $okPush $(if ($okPush) { $null } else { $r.text }) $pushClass
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
    if ($script:StageOrder -notcontains $stage) { Write-ErrorResult "ROLE_INVALID" "-Role must be one of CTO/UX/DEV/QA" 1 }
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

# === Settle evidence gate (shared by settle and reclaim) ===

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

    # --- flow-side prechecks (avoid the settle->advance half-failure window) ---
    $flow = Read-ArchiveTasks $bridge.archive
    $task = Find-ArchiveTask $flow.tasks $taskId
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $taskId not found in $($bridge.archive)" 2 }
    if (([string]$task.lifecycle) -ne "active") {
        Write-ErrorResult "TASK_NOT_ACTIVE" "TaskId $taskId lifecycle is '$($task.lifecycle)'; nothing to advance." 1
    }
    if ($null -ne $nextStage) {
        $owners = @()
        if ($null -ne $task.currentOwners) { $owners = @($task.currentOwners) }
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
    if ($null -eq $nextStage) {
        $r2 = Invoke-RddFlow @("-Command", "complete", "-TaskId", "$taskId", "-Archive", $bridge.archive)
        if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
            $warnings += "flow complete failed after tree settle — recorded as pending_sync: $($r2.text)"
            $bridge = Add-PendingSync $runDir $bridge $NodeId "complete" $stage $null ($r2.text)
        }
    }
    else {
        $r2 = Invoke-RddFlow @("-Command", "advance", "-TaskId", "$taskId", "-From", $stage, "-To", $nextStage, "-Archive", $bridge.archive)
        if ($r2.exit -ne 0 -or $null -eq $r2.json -or -not $r2.json.success) {
            $warnings += "flow advance failed after tree settle — recorded as pending_sync: $($r2.text)"
            $bridge = Add-PendingSync $runDir $bridge $NodeId "advance" $stage $nextStage ($r2.text)
        }
        else {
            $g = Invoke-GraftNextStage $runDir $bridge $task $NodeId $nextStage
            if ($g.success) {
                $bridge = $g.bridge
                $graftedNext = $g.node_id
            }
            else {
                $warnings += "next-stage graft failed (flow side already advanced): $($g.error)"
            }
        }
    }

    # --- dependency-driven unlock push (goal-tree-goal-root): settling this node may
    #     unlock other tasks' nodes (and grafted this task's own next stage) — push
    #     every newly unlocked node automatically; push failures are isolated data.
    $push = Invoke-AutoDispatch $runDir $bridge "settle"
    $bridge = $push.bridge
    foreach ($f in @($push.failed)) {
        $warnings += "auto-push failed for node $($f.node) (retry_class=$($f.retry_class)): session-create class auto-retries on the next trigger; pointer class needs manual dispatch. $($f.error)"
    }

    return @{
        success = $true
        data    = @{
            run_id         = $RunId
            node_id        = $NodeId
            task_id        = $taskId
            stage_settled  = $stage
            flow_operation = $(if ($null -eq $nextStage) { "complete" } else { "advance ${stage}->${nextStage}" })
            next_stage_node = $graftedNext
            task_lifecycle = $(if ($null -eq $nextStage) { "completed" } else { "active @ $nextStage" })
            auto_push      = @{ trigger = $push.trigger; pushed = @($push.pushed); failed = @($push.failed); skipped = @($push.skipped | ForEach-Object { "$($_.node):$($_.reason)" }) }
            warnings       = $warnings
            next_step      = $(if ($push.failed.Count -gt 0) { "repair failed pushes: session-create class auto-retries via status; pointer class → dispatch -NodeId <id> manually" } elseif ($null -eq $nextStage) { "task $taskId reached terminal state" } else { "unlocked nodes pushed automatically (see auto_push); failures retry via status touch" })
        }
    }
}

function Add-PendingSync {
    param([string]$RunDir, $Bridge, [string]$NodeId, [string]$Op, [string]$From, $To, [string]$Error)
    $entry = [ordered]@{
        node   = $NodeId
        op     = $Op
        from   = $From
        to     = $To
        error  = $Error
        at     = Get-UtcNowIso
    }
    $pending = @(Convert-ToSafeArray $Bridge.pending_sync)
    $pending += ,$entry
    $Bridge.pending_sync = $pending
    Write-BridgeFile $RunDir $Bridge
    return $Bridge
}

function Invoke-GraftNextStage {
    param([string]$RunDir, $Bridge, $Task, [string]$ParentNodeId, [string]$NextStage)
    $taskId = [int]$Task.id
    $title = [string]$Task.title
    $reqRel = ([string]$Task.requirement -replace '\\', '/')
    $designRels = @()
    foreach ($d in @(Convert-ToSafeArray $Task.designDocs)) { $designRels += ([string]$d.path -replace '\\', '/') }
    $taskText = "Execute TaskId $taskId stage $NextStage of $($Bridge.archive_rel). Requirement: $reqRel."
    if ($designRels.Count -gt 0) { $taskText += " Design: $($designRels -join ', ')." }
    $taskText += " First action: delivery-bridge.cmd -Command claim -RunId $($Bridge.run_id) -NodeId <this-node> -Role $NextStage."
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
        $bTask = $null
        if ($Bridge.tasks.Contains("$taskId")) { $bTask = $Bridge.tasks["$taskId"] }
        if ($null -ne $bTask) {
            $bStages = $bTask['stages']
            if ($null -eq $bStages) { $bStages = @{} }
            foreach ($stage in @($script:StageOrder)) {
                if (-not $bStages.Contains($stage)) { continue }
                $nodeId = [string]$bStages[$stage]
                $node = Get-NodeFromTree $treeData $nodeId
                $stages += @{
                    stage  = $stage
                    node   = $nodeId
                    status = $(if ($node) { [string]$node.status } else { "missing" })
                }
            }
        }
        $workers = @()
        foreach ($w in @(Convert-ToSafeArray $t.currentWorker)) {
            if ($null -eq $w) { continue }
            if ($w -is [System.Collections.IDictionary]) { foreach ($k in @($w.Keys)) { $workers += "$k@$($w[$k])" } }
            else { foreach ($p in @($w.PSObject.Properties)) { $workers += "$($p.Name)@$($p.Value)" } }
        }
        $owners = @()
        if ($null -ne $t.currentOwners) { $owners = @($t.currentOwners) }
        $taskRows += @{
            task_id        = $taskId
            title          = [string]$t.title
            lifecycle      = [string]$t.lifecycle
            current_owners = $owners
            flow_workers   = $workers
            stages         = $stages
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

    $deps = $treeData.dependencies

    $terminalCount = @($flow.tasks | Where-Object { ([string]$_.lifecycle) -in @("completed", "deprecated") }).Count

    return @{
        bridge         = $bridge
        tree           = $treeData
        task_rows      = $taskRows
        dead_claims    = @{ tree = $deadTreeClaims; flow = $deadFlowClaims }
        claimable      = $claimable
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

    $warnings = @()
    foreach ($w in @($view.tree.integrity.warnings)) { $warnings += "tree: $w" }
    if ($view.repair.remaining.Count -gt 0) { $warnings += "pending_sync unresolved: $(@($view.repair.remaining | ForEach-Object { "$($_.node):$($_.op)" }) -join ', ')" }
    if ($view.dead_claims.tree.Count -gt 0) { $warnings += "dead tree claim(s) (>= ${DeadClaimMinutes} min): $(@($view.dead_claims.tree | ForEach-Object { $_.node }) -join ', ') — reclaim them" }
    if ($view.dead_claims.flow.Count -gt 0) { $warnings += "dead flow claim(s): $(@($view.dead_claims.flow | ForEach-Object { "task#$($_.task_id):$($_.role)" }) -join ', ')" }
    $failedPushes = @($pushRows | Where-Object { $_.retry_class })
    if ($failedPushes.Count -gt 0) {
        $warnings += "push failures: $(@($failedPushes | ForEach-Object { "$($_.node)($($_.retry_class))" }) -join ', ') — session-create class auto-retries on every status touch; pointer class needs manual dispatch"
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
            session_liveness = $livenessRows
            pushes         = $pushRows
            auto_push_touch = $touch
            pending_sync   = $view.repair.remaining
            repaired_now   = $view.repair.repaired
            lease          = $view.lease
            terminal       = "$($view.terminalCount)/$($view.flow_taskCount)"
            warnings       = $warnings
            next_step      = $(if ($view.terminalCount -eq $view.flow_taskCount -and $view.flow_taskCount -gt 0) { "all tasks terminal — conclude: delivery-bridge.cmd -Command conclude -RunId $RunId -Summary <...>" } else { "settle reported nodes; pushes are automatic (initial/unlock/reclaim + status touch); claimable now: [$($view.claimable -join ', ')]" })
        }
    }
}

function Invoke-BridgeResume {
    $runDir = Get-BridgeRunDir $RunId
    $bridge = Require-Bridge $runDir
    $view = Get-BridgeOverview $runDir $bridge

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
    $notTerminal = @($flow.tasks | Where-Object { ([string]$_.lifecycle) -notin @("completed", "deprecated") })
    if ($notTerminal.Count -gt 0) {
        Write-ErrorResult "DELIVERY_INCOMPLETE" "Not all tasks are terminal yet: $(@($notTerminal | ForEach-Object { "#$($_.id)($($_.lifecycle)) @$($_.currentOwners -join '+')" }) -join ', '). Settle/prune the remaining work first." 1
    }
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
        # (goal-tree concluded the run anchored on the type=goal root).
        $goalTitle = if ($Bridge.goal.Contains('title')) { [string]$Bridge.goal['title'] } else { "-" }
        $lines += "- 根目标: **达成** — goal 根 $($Bridge.goal_root)「$goalTitle」全部直接子需求节点终态（原始需求=最终目标）"
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
                $parts = @()
                foreach ($stage in @($script:StageOrder)) {
                    if (-not $bStages.Contains($stage)) { continue }
                    $nodeId = [string]$bStages[$stage]
                    $node = Get-NodeFromTree $treeData $nodeId
                    $parts += "$stage=$nodeId($(if ($node) { $node.status } else { 'missing' }))"
                }
                if ($parts.Count -gt 0) { $chain = $parts -join ' → ' }
            }
        }
        $lines += "| $taskId | $([string]$t.title) | $([string]$t.lifecycle) | $chain |"
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
            tasks_terminal = "$($flow.tasks.Count)/$($flow.tasks.Count)"
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

# === Dispatch ===

switch ($Command) {
    "promulgate" { $result = Invoke-Promulgate }
    "dispatch"   { $result = Invoke-Dispatch }
    "claim"      { $result = Invoke-BridgeClaim }
    "reclaim"    { $result = Invoke-BridgeReclaim }
    "settle"     { $result = Invoke-BridgeSettle }
    "status"     { $result = Invoke-BridgeStatus }
    "resume"     { $result = Invoke-BridgeResume }
    "conclude"   { $result = Invoke-BridgeConclude }
    "lease"      { $result = Invoke-BridgeLease }
}

ConvertTo-PortableJson $result -Depth 14
exit 0

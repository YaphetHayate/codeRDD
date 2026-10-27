# session-reuse.ps1 -- single-point session-reuse shared library (single source).
#
# Context (single-point-session-reuse): dsh backend single-point handoff flow
# (rdd-flow + start-role) re-delivers the redo pointer into the ORIGINAL
# alive session of the same task x role (reject re-entry + second positive
# handoff), with a reentry budget (default 3, task-level override, cap =
# adjudication point with four exits -- never a hard stop). Anchors live in
# the ARCHIVE-LEVEL SIDECAR session-anchors.json; task.json stays untouched
# (design decision #1: control-plane/run-plane separation, planner-bridge
# state/claims sidecar precedent).
#
# Consumers: scripts/start-role.ps1 (auto-reuse gate + anchor write + reentry
# tick), scripts/rdd-flow.ps1 (reject dsh delivery branch + reentry
# subcommand), and scripts/goal-tree.ps1 (dispatch-reuse-from-node: liveness
# probe only — goal-tree's reentry budget stays RUN-SCOPED in its dispatch
# log, deliberately NOT this lib's archive-scoped anchor plane; R7 keeps the
# two anchor systems mutually invisible). start-role/rdd-flow/goal-tree
# dot-source this file. delivery-bridge.ps1 does NOT
# (documented invariant: the bridge never dot-sources engine internals --
# see delivery-bridge.ps1 L3-7/L688/L1089; function contracts below
# deliberately MIRROR the bridge's same-name semantics and carry one-side
# cross-anchoring comments so a future mechanical migration stays cheap --
# design decision #4, user-ruled case 甲).
#
# Sidecar shape (design "字段命名"):
#   { "<taskId>": { "roles": { "<ROLE>": { "sessionId", "reentries",
#                                          "anchoredAt" } },
#                   "reentryMax": <int optional> } }
#
# Write discipline: .bak rotation + read-back verify, advisory (non-mutex)
# semantics -- anchors never gate routing truth, any write failure degrades
# to current behavior with a warning (bridge.json precedent; crash window
# between delivery and count persist is an accepted ±1, design 落盘时机).
#
# Encoding: UTF-8 with BOM (verbatim comments carry CJK; the PS 5.1
# ANSI-decode trap applies to BOM-less non-ASCII .ps1).

# === Constants ================================================================

# Default reentry budget (design: 引擎硬编码默认，对齐 goal-tree wake 默认 3).
$script:SessionReuseDefaultReentryMax = 3

# === Anchor-plane task scope predicate ========================================

function Test-AnchorPlaneTaskScope {
    # Shared predicate for start-role.ps1's three anchor-plane call sites
    # (auto-reuse gate / reentry tick / anchor write): task-scoped single-point
    # deliveries only -- -TaskId >= 1, no -GoalTreeRun bridge marker (bridge
    # dispatches ALWAYS carry it, so the single-point and bridge anchor systems
    # stay mutually invisible, R7), not a NoArchive intake, not a GoalTreeWorker
    # dispatch. Binding is EXPLICIT at every call site; parameter names
    # deliberately differ from the caller's variables ($TaskIdNum vs $TaskId
    # etc. -- PowerShell names are case-insensitive, same-name locals shadow).
    # The lib-load guard ($script:SessionReuseLibLoaded) stays at the call
    # sites, short-circuiting BEFORE this call: this function only exists when
    # the library loaded (fail-soft load). The auto-reuse gate appends its own
    # two conditions on top (-ExistingSessionId absent / no -NoReuse escape).
    param(
        [int]$TaskIdNum,
        [string]$GoalTreeRunMarker,
        [switch]$NoArchiveIntake,
        [switch]$GoalTreeWorkerMode
    )
    return ($TaskIdNum -ge 1 -and
        [string]::IsNullOrWhiteSpace($GoalTreeRunMarker) -and
        -not $NoArchiveIntake -and
        -not $GoalTreeWorkerMode)
}

# === Sidecar path + IO (anchor CRUD) ==========================================

function Get-SessionAnchorsPath {
    # Archive-level sidecar (design decision #1/#8: named session-anchors.json
    # -- NOT sessions.json, that name is the bridge roster's).
    param([string]$ArchivePath)
    return (Join-Path $ArchivePath "session-anchors.json")
}

function ConvertTo-AnchorHashtable {
    # PSObject (ConvertFrom-Json) -> deep hashtable so callers can mutate in
    # place with uniform IDictionary semantics. $null-safe.
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj }
    $ht = @{}
    foreach ($p in $Obj.PSObject.Properties) {
        if ($null -ne $p.Value -and $p.Value -isnot [System.ValueType] -and $p.Value -isnot [string]) {
            $ht[$p.Name] = ConvertTo-AnchorHashtable $p.Value
        }
        else {
            $ht[$p.Name] = $p.Value
        }
    }
    return $ht
}

function Read-SessionAnchors {
    # Read the anchor sidecar as a mutable hashtable. Primary corrupt/missing
    # -> .bak fallback -> empty map. Never throws (fail-soft, advisory state).
    # Returns @{ data = <hashtable>; ok = <bool>; source = <primary|bak|empty> }.
    param([string]$ArchivePath)
    $path = Get-SessionAnchorsPath -ArchivePath $ArchivePath
    foreach ($candidate in @(@{ p = $path; s = "primary" }, @{ p = "$path.bak"; s = "bak" })) {
        if (-not (Test-Path -LiteralPath $candidate.p -PathType Leaf)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($candidate.p, [System.Text.Encoding]::UTF8)
            $parsed = $null
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $parsed = $raw | ConvertFrom-Json }
            if ($null -eq $parsed) {
                return @{ data = @{}; ok = $true; source = "$($candidate.s) (empty file)" }
            }
            return @{ data = (ConvertTo-AnchorHashtable $parsed); ok = $true; source = $candidate.s }
        }
        catch { continue }
    }
    return @{ data = @{}; ok = $true; source = "empty" }
}

function Write-SessionAnchors {
    # Persist the anchor map: rotate previous primary to .bak, write UTF-8
    # (no BOM), read back and re-parse to verify. Advisory: returns
    # @{ ok; error } -- callers WARN and continue on failure (anchors degrade
    # to no-reuse current behavior, never block routing/handoff).
    param([string]$ArchivePath, $Data)
    $path = Get-SessionAnchorsPath -ArchivePath $ArchivePath
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
        }
        $json = $Data | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($path, ($json + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $verify = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $verify) { return @{ ok = $false; error = "read-back parse failed: $path" } }
        return @{ ok = $true; error = $null }
    }
    catch {
        return @{ ok = $false; error = [string]$_.Exception.Message }
    }
}

function Get-SessionAnchorEntry {
    # The task x role anchor: @{ sessionId; reentries; anchoredAt } or $null.
    # Tolerant of absent task section / roles map / partial entries.
    param($Anchors, [int]$TaskIdNum, [string]$RoleName)
    if ($null -eq $Anchors) { return $null }
    $taskKey = "$TaskIdNum"
    if (-not $Anchors.Contains($taskKey)) { return $null }
    $taskEntry = $Anchors[$taskKey]
    if ($null -eq $taskEntry -or -not ($taskEntry -is [System.Collections.IDictionary])) { return $null }
    if (-not $taskEntry.Contains("roles") -or $null -eq $taskEntry["roles"]) { return $null }
    $roles = $taskEntry["roles"]
    if (-not ($roles -is [System.Collections.IDictionary])) { return $null }
    if (-not $roles.Contains($RoleName) -or $null -eq $roles[$RoleName]) { return $null }
    $entry = $roles[$RoleName]
    if (-not ($entry -is [System.Collections.IDictionary])) { return $null }
    $sid = [string]$entry["sessionId"]
    if ([string]::IsNullOrWhiteSpace($sid)) { return $null }
    return @{
        sessionId  = $sid
        reentries  = $(if ($null -ne $entry["reentries"]) { [int]$entry["reentries"] } else { 0 })
        anchoredAt = $(if ($null -ne $entry["anchoredAt"]) { [string]$entry["anchoredAt"] } else { "" })
    }
}

function Set-SessionAnchorEntry {
    # (Re-)anchor task x role to a freshly created session. Re-anchoring is a
    # RESET by contract: the new session takes over the redo duty with a fresh
    # reentry budget (design 落盘时机: 新建会话回退时重锚并清零计数). Mutates
    # $Anchors in place; callers persist via Write-SessionAnchors.
    param($Anchors, [int]$TaskIdNum, [string]$RoleName, [string]$SessionId)
    $taskKey = "$TaskIdNum"
    if (-not $Anchors.Contains($taskKey) -or $null -eq $Anchors[$taskKey] -or -not ($Anchors[$taskKey] -is [System.Collections.IDictionary])) {
        $Anchors[$taskKey] = @{ roles = @{} }
    }
    $taskEntry = $Anchors[$taskKey]
    if (-not $taskEntry.Contains("roles") -or $null -eq $taskEntry["roles"] -or -not ($taskEntry["roles"] -is [System.Collections.IDictionary])) {
        $taskEntry["roles"] = @{}
    }
    $taskEntry["roles"][$RoleName] = @{
        sessionId  = $SessionId
        reentries  = 0
        anchoredAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    return $Anchors
}

# === Reentry budget (quota gate) ==============================================

function Get-EffectiveReentryMax {
    # Two-level resolution (design decision #7, wake-model precedent):
    # task-level sidecar reentryMax -> engine default 3. No run level here
    # (single-point flow has no run concept).
    param($Anchors, [int]$TaskIdNum)
    if ($null -ne $Anchors) {
        $taskKey = "$TaskIdNum"
        if ($Anchors.Contains($taskKey) -and $null -ne $Anchors[$taskKey] -and ($Anchors[$taskKey] -is [System.Collections.IDictionary])) {
            $taskEntry = $Anchors[$taskKey]
            if ($taskEntry.Contains("reentryMax") -and $null -ne $taskEntry["reentryMax"]) {
                return [int]$taskEntry["reentryMax"]
            }
        }
    }
    return $script:SessionReuseDefaultReentryMax
}

function Test-ReentryCapped {
    # Capped = one more reuse delivery would exceed the budget
    # (reentries + 1 > max -- same arithmetic as goal-tree wake quota,
    # goal-tree.ps1 Invoke-Redo: wake_count + 1 -gt wakeMax).
    param($Anchors, [int]$TaskIdNum, [string]$RoleName)
    $entry = Get-SessionAnchorEntry -Anchors $Anchors -TaskIdNum $TaskIdNum -RoleName $RoleName
    if ($null -eq $entry) { return $false }
    $max = Get-EffectiveReentryMax -Anchors $Anchors -TaskIdNum $TaskIdNum
    return (([int]$entry.reentries + 1) -gt $max)
}

function Add-ReentryTick {
    # +1 on the task x role reentry count AFTER a successful reuse delivery
    # (design 落盘时机: 复用投递成功后计数 +1，投递失败不计数). Mutates $Anchors
    # in place; returns the new count, or -1 when no anchor exists (no-op).
    param($Anchors, [int]$TaskIdNum, [string]$RoleName)
    $entry = Get-SessionAnchorEntry -Anchors $Anchors -TaskIdNum $TaskIdNum -RoleName $RoleName
    if ($null -eq $entry) { return -1 }
    $taskEntry = $Anchors["$TaskIdNum"]
    $taskEntry["roles"][$RoleName]["reentries"] = ([int]$entry.reentries) + 1
    return (([int]$entry.reentries) + 1)
}

function Set-TaskReentryMax {
    # Task-level reentryMax write (raise-only enforcement stays with the
    # command layer; this is the mechanical setter). Mutates in place.
    param($Anchors, [int]$TaskIdNum, [int]$Max)
    $taskKey = "$TaskIdNum"
    if (-not $Anchors.Contains($taskKey) -or $null -eq $Anchors[$taskKey] -or -not ($Anchors[$taskKey] -is [System.Collections.IDictionary])) {
        $Anchors[$taskKey] = @{ roles = @{} }
    }
    $Anchors[$taskKey]["reentryMax"] = $Max
    return $Anchors
}

# === Liveness probe (bridge mirror, one-side cross-anchor) ====================

function Get-SessionLivenessProbe {
    # session-keyed liveness probe -- MIRROR of delivery-bridge.ps1
    # Get-SessionLiveness (L1324-1348): same endpoint
    # ($DSH_WEB_URL/rdd-goal-tree/liveness?cwd=<root>&session_id=<sid>), same
    # agents-registry source, same conservative verdicts (probe failure /
    # non-dsh shell / unparsable answer -> unknown; unknown is NEVER a reuse
    # verdict). Any semantic change here must be mirrored there (sync
    # discipline per bridge L1089 precedent).
    # Returns @{ liveness = alive|dead|unknown; reason }.
    param([string]$SessionId, [string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return @{ liveness = "unknown"; reason = "no session id" }
    }
    if ([string]::IsNullOrWhiteSpace($env:DSH_WEB_URL)) {
        return @{ liveness = "unknown"; reason = "not a dsh shell (DSH_WEB_URL absent) -- registry unverifiable here" }
    }
    $url = "$($env:DSH_WEB_URL.TrimEnd('/'))/rdd-goal-tree/liveness?cwd=$([uri]::EscapeDataString($RepoRoot))&session_id=$([uri]::EscapeDataString($SessionId))"
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "GET"
        $req.Timeout = 3000
        $req.ReadWriteTimeout = 3000
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
        if ($null -eq $json) {
            return @{ liveness = "unknown"; reason = "liveness endpoint returned unparsable body" }
        }
        $live = "unknown"
        if ($json.PSObject.Properties['liveness']) { $live = [string]$json.liveness }
        return @{ liveness = $live; reason = "agents registry (session-keyed probe)" }
    }
    catch {
        return @{ liveness = "unknown"; reason = "liveness endpoint unreachable: $([string]$_.Exception.Message)" }
    }
}

# === Cap adjudication (four exits) + pointer-failure guidance =================

function Get-ReentryCapRefusal {
    # Cap-exhausted adjudication text -- the single-point sibling of
    # goal-tree.ps1 Get-WakeQuotaRefusal (L2154-2160): exhaustion is an
    # adjudication point, not a stop; every exit lands as a COPYABLE command
    # (script world has no interactive UI -- design decision #10).
    # $Context keys: task_id, role, reentries, reentry_max, archive_rel,
    # task_json, requirement_rel, reject_trail.
    param($Context)
    $taskId = [int]$Context.task_id
    $role = [string]$Context.role
    $reentries = [int]$Context.reentries
    $max = [int]$Context.reentry_max
    $archiveRel = [string]$Context.archive_rel
    $taskJson = [string]$Context.task_json
    $reqRel = [string]$Context.requirement_rel
    $trail = [string]$Context.reject_trail
    $lines = @()
    $lines += "[x] REENTRY_CAP_EXCEEDED: 任务 $taskId 的 $role 会话重入预算已耗尽 [$reentries/$max] -- 触顶是裁决点而非硬停，四出口（裁决入决策账本 decisions.jsonl）："
    $lines += "  (1) 升级用户：本输出即升级材料，打回轨迹如下 -- $trail"
    $lines += "  (2) 换新会话承接（原会话上下文摘要指针：需求 $reqRel｜打回轨迹见上）：start-role.cmd -Role $role -TaskId $taskId -TaskJson $taskJson -NoReuse"
    $lines += "  (3) 显式豁免继续复用（豁免一次入账）：rdd-flow.cmd -Command reentry -Archive $archiveRel -TaskId $taskId -Exempt -UserVerdict `"<豁免理由（用户裁决）>`""
    $lines += "  (4) 提高上限（只增不减）：rdd-flow.cmd -Command reentry -Archive $archiveRel -TaskId $taskId -RaiseTo <N> -UserVerdict `"<提额理由（用户裁决）>`""
    return ($lines -join "`n")
}

function Get-ReusePointerFailureGuidance {
    # Pointer-class failure manual two-choice -- pointer 纪律（bridge
    # Invoke-StartRolePush L1641-1694: a failed prompt onto an EXISTING
    # session is pointer-class BY CONSTRUCTION; auto-creating a fresh session
    # is FORBIDDEN -- the original session may consume the first delivery
    # late, and the redo task would run twice; design 硬约束 ②）.
    # $Context keys: role, task_id, task_json, session_id, appendix_hint.
    param($Context)
    $role = [string]$Context.role
    $taskId = [int]$Context.task_id
    $taskJson = [string]$Context.task_json
    $sid = [string]$Context.session_id
    $appendixHint = [string]$Context.appendix_hint
    $lines = @()
    $lines += "[!] 复用投递失败（pointer 类，禁止自动新建防重复处理）——手动二选一："
    $lines += "  (a) 重推原会话（session $sid 仍存活，可手动粘贴指针或重跑投递）：start-role.cmd -Role $role -TaskId $taskId -TaskJson $taskJson -ExistingSessionId $sid$appendixHint"
    $lines += "  (b) 放弃复用换新会话：start-role.cmd -Role $role -TaskId $taskId -TaskJson $taskJson -NoReuse"
    return ($lines -join "`n")
}

# === Decision-ledger append (bridge lock protocol mirror) =====================

$script:ReuseLockStream = $null
$script:ReuseLockPath = $null

function Enter-DecisionsLock {
    # MIRROR of delivery-bridge.ps1 Enter-ArchiveLock (L740-777): the SAME
    # lock file (<archive>/.decisions.lock), same CreateNew+FileShare::None
    # OS mutex, same 60s stale takeover / 10s timeout -- mirroring the exact
    # protocol (not sharing the code) serializes this library's appends
    # against the bridge's without the bridge dot-sourcing engine internals
    # (design decision #4 甲案). Sync discipline: any change here must be
    # mirrored there.
    param([string]$ArchivePath, [string]$Label, [int]$TimeoutSec = 10, [int]$StaleSec = 60)
    $script:ReuseLockPath = Join-Path $ArchivePath ".decisions.lock"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stolen = $false
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($script:ReuseLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "cmd=$Label ledger=decisions pid=$PID at=$(Get-Date -Format s)"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            $script:ReuseLockStream = $fs
            return @{ path = $script:ReuseLockPath; stale_taken_over = $stolen }
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if (Test-Path -LiteralPath $script:ReuseLockPath -PathType Leaf) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $script:ReuseLockPath).LastWriteTime).TotalSeconds
                if ($age -gt $StaleSec) {
                    try { Remove-Item -LiteralPath $script:ReuseLockPath -Force -ErrorAction SilentlyContinue } catch {}
                    $stolen = $true
                    continue
                }
            }
            else {
                continue
            }
            if ((Get-Date) -gt $deadline) {
                return @{ path = $null; timeout = $true }
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Exit-DecisionsLock {
    # MIRROR of delivery-bridge.ps1 Exit-ArchiveLock (L779-790) -- see
    # Enter-DecisionsLock above for the sync note.
    if ($null -ne $script:ReuseLockStream) {
        try { $script:ReuseLockStream.Close() } catch {}
        $script:ReuseLockStream = $null
    }
    if ($script:ReuseLockPath -and (Test-Path -LiteralPath $script:ReuseLockPath -PathType Leaf)) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:ReuseLockPath, [System.Text.Encoding]::UTF8)
            if ($raw -match "pid=$PID ") { Remove-Item -LiteralPath $script:ReuseLockPath -Force -ErrorAction SilentlyContinue } catch {}
        }
        catch {}
    }
}

function Add-ReentryDecisionEntry {
    # Append ONE reentry-verdict entry to the archive's decisions.jsonl --
    # the unified decision ledger shared with delivery-bridge (bridge
    # Get-ArchiveDecisionsPath L900-907 / Add-DecisionEntry L929-959: same
    # file, same lock, same D<n> entry_id sequence, same four-element shape
    # background/options/decision/reason + decider; kind stays "reentry_verdict"
    # so ledger views can tell it from checkpoint/auto/ruling entries).
    # Entry-id assignment counts EXISTING lines under the lock (bridge
    # discipline). Advisory: a read-back failure returns @{ failed; error }
    # instead of throwing (the host command already took effect).
    param([string]$ArchivePath, [string]$Action, [int]$TaskIdNum, [string]$DecisionText, [string]$ReasonText, [string]$UserVerdict, [int]$ReentryMaxAfter)
    $ledgerPath = Join-Path $ArchivePath "decisions.jsonl"
    $entry = [ordered]@{
        at         = (Get-Date).ToUniversalTime().ToString("o")
        run_id     = $null
        kind       = "reentry_verdict"
        background = "single-point session reuse: reentry cap adjudication (task $TaskIdNum, action $Action)"
        options    = @("escalate", "new-session", "exempt", "raise")
        decision   = $DecisionText
        reason     = $(if ([string]::IsNullOrWhiteSpace($ReasonText)) { $null } else { $ReasonText })
        decider    = "user"
    }
    $entry["task_id"] = $TaskIdNum
    $entry["action"] = $Action
    $entry["reentry_max"] = $ReentryMaxAfter
    $entry["user_verdict"] = $UserVerdict
    $lock = Enter-DecisionsLock -ArchivePath $ArchivePath -Label "rdd-flow reentry"
    if ($lock.timeout) {
        return @{ failed = $true; error = "decisions lock timeout (held by another writer > 10s)" }
    }
    try {
        $count = 0
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            foreach ($line in @([System.IO.File]::ReadAllLines($ledgerPath))) {
                if (-not [string]::IsNullOrWhiteSpace($line)) { $count++ }
            }
        }
        $entry["entry_id"] = "D$($count + 1)"
        $line2 = $entry | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::AppendAllText($ledgerPath, $line2 + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $all = @([System.IO.File]::ReadAllLines($ledgerPath) | Where-Object { $_.Trim() -ne "" })
        try { $null = $all[-1] | ConvertFrom-Json } catch {
            return @{ failed = $true; error = "decisions.jsonl last line failed to parse after append" }
        }
    }
    finally {
        Exit-DecisionsLock
    }
    return @{ failed = $false; entry = $entry }
}

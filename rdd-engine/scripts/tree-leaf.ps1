# tree-leaf.ps1 — tree-run consumption plane CLI (worker/subagent sessions only)
#
# Workers consume LEAF tasks of a tree-run created by a Manager session:
#   next    — locate claimable pending nodes (read-only)
#   claim   — atomically take a pending node (lock-protected read-modify-write);
#             -Steal recovers a node stuck in claimed state
#   report  — submit the engine-enforced structured callback (schema + citation
#             range validation; invalid callbacks are recorded as-is and degraded,
#             never breaking the run)
#   status  — read-only view of the run / a single node
#
# Separation of powers: this CLI can only update claim/status fields of the node
# it owns (hardcoded whitelist). Tree structure changes (graft/prune/settle/
# conclude) are physically impossible here — they live in tree-run.ps1.
#
# Node lifecycle: pending → claimed → reported → done (or → pruned).
# Reported nodes are never re-claimable: interruption + resume cannot
# double-consume a node whose callback is already in the ledger.

[CmdletBinding()]
param(
    [ValidateSet("next", "claim", "report", "status")]
    [string]$Command = "next",

    [string]$RunId,
    [string]$NodeId,
    [string]$Worker,
    [string]$Callback,
    [string]$CallbackFile,
    [switch]$Steal,
    [int]$Limit = 0
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$repoRoot = (git rev-parse --show-toplevel).Trim()

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TreeRunsRoot = Join-Path $repoRoot ".rdd/tree-runs"
$script:LockStream = $null
$script:LockPath = $null

# === Generic helpers (same contract as tree-run.ps1) ===

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
        foreach ($p in $Value.PSObject.Properties) {
            $h[$p.Name] = Convert-PSObjectToHashtable $p.Value
        }
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

function Get-RunDir       { param([string]$Id); Join-Path $script:TreeRunsRoot $Id }
function Get-ManifestPath { param([string]$RunDir); Join-Path $RunDir "manifest.json" }
function Get-StateDir     { param([string]$RunDir); Join-Path $RunDir "state" }
function Get-TreePath     { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "tree.json" }
function Get-LedgerPath   { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "ledger.jsonl" }
function Get-RoundLogPath { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "round-log.jsonl" }
function Get-LockPath     { param([string]$RunDir); Join-Path $RunDir ".lock" }

# === Coverage manifest sidecars (task-dispatch-guide R1'; mirrors tree-run.ps1 helpers) ===

function Get-ManifestsDir     { param([string]$RunDir); Join-Path (Get-StateDir $RunDir) "manifests" }
function Get-NodeManifestPath { param([string]$RunDir, [string]$NodeId); Join-Path (Get-ManifestsDir $RunDir) "$NodeId.json" }

function Test-PropPresent {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Name) }
    return ($null -ne $Obj.PSObject.Properties[$Name])
}

function Read-NodeManifest {
    param([string]$RunDir, [string]$NodeId)
    $p = Get-NodeManifestPath $RunDir $NodeId
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch {
        Write-ErrorResult "NODE_MANIFEST_CORRUPT" "coverage manifest for node $NodeId failed to parse: $p" 3
    }
}

function Write-NodeManifest {
    param([string]$RunDir, $Sidecar)
    $dir = Get-ManifestsDir $RunDir
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Get-NodeManifestPath $RunDir ([string]$Sidecar.node_id)
    [System.IO.File]::WriteAllText($p, (ConvertTo-Json $Sidecar -Depth 10), $script:Utf8NoBom)
}

function ConvertTo-CoverageDatetime {
    param([string]$Value)
    $v = if ($Value) { $Value.Trim() } else { '' }
    try { return [datetime]::ParseExact($v, 'yyyy-MM-dd HH:mm:ss', $null) } catch { return $null }
}

function ConvertTo-DayMinute {
    # 'HH:MM(:SS)' -> minutes of day (for fold/spotcheck arithmetic); $null when unparseable
    param([string]$Ts)
    if ([string]::IsNullOrWhiteSpace($Ts)) { return $null }
    $parts = $Ts.Split(':')
    if ($parts.Count -lt 2) { return $null }
    $h = 0; $mi = 0
    if (-not [int]::TryParse($parts[0], [ref]$h)) { return $null }
    if (-not [int]::TryParse($parts[1], [ref]$mi)) { return $null }
    if ($h -lt 0 -or $h -gt 23 -or $mi -lt 0 -or $mi -gt 59) { return $null }
    return $h * 60 + $mi
}

function Get-FoldPair {
    # R2: two HH:MM(:SS) joined by & / / , inside ONE text field, more than 2 minutes apart,
    # is the folded-peaks antipattern (rca-133915: "14:39 & 14:57"). Adjacent pairs and
    # hyphen/'to' ranges are legitimate interval writing and are not flagged.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '(\d{1,2}:\d{2}(?::\d{2})?)\s*(?:&|/|,)\s*(\d{1,2}:\d{2}(?::\d{2})?)')
    if (-not $m.Success) { return $null }
    $t1 = ConvertTo-DayMinute $m.Groups[1].Value
    $t2 = ConvertTo-DayMinute $m.Groups[2].Value
    if ($null -eq $t1 -or $null -eq $t2) { return $null }
    if ([Math]::Abs($t2 - $t1) -le 2) { return $null }
    return @{ t1 = $m.Groups[1].Value; t2 = $m.Groups[2].Value }
}

function Invoke-EvidenceSpotCheck {
    # M2 D2 (note-only observation period): declared tmin/tmax must at least overlap the
    # timestamp range observable in the artifact's head+tail (50 lines each, <=10MB text).
    # Anti-lie telemetry check: reconciliation costs ~100 lines of reading, never a re-run.
    # Returns '' or a note. Never invalidates the cell (upgrade decision deferred to post-M5).
    param($Ev, [string]$AbsPath)
    try {
        if (-not (Test-Path -LiteralPath $AbsPath -PathType Leaf)) { return '' }
        if ((Get-Item -LiteralPath $AbsPath).Length -gt 10MB) { return '' }
        $all = [System.IO.File]::ReadAllLines($AbsPath)
        $sample = @()
        if ($all.Count -le 100) { $sample = $all }
        else { $sample = @($all[0..49]) + @($all[($all.Count - 50)..($all.Count - 1)]) }
        $obs = @{}
        foreach ($ln in $sample) {
            foreach ($mm in [regex]::Matches($ln, '\b(\d{1,2}:\d{2}(?::\d{2})?)\b')) {
                $mins = ConvertTo-DayMinute $mm.Groups[1].Value
                if ($null -ne $mins) { $obs[$mins] = $mm.Groups[1].Value }
            }
        }
        if ($obs.Count -lt 2) { return '' }
        $sorted = @($obs.Keys | Sort-Object)
        $obsMinRaw = $obs[$sorted[0]]; $obsMaxRaw = $obs[$sorted[-1]]
        $declMin = ConvertTo-DayMinute (([string]$Ev.tmin) -replace '^\d{4}-\d{2}-\d{2}\s+', '')
        $declMax = ConvertTo-DayMinute (([string]$Ev.tmax) -replace '^\d{4}-\d{2}-\d{2}\s+', '')
        if ($null -eq $declMin -or $null -eq $declMax) { return '' }
        if ($sorted[0] -gt $declMax -or $sorted[-1] -lt $declMin) {
            return "spotcheck_mismatch: artifact '$($Ev.ref)' shows ${obsMinRaw}..${obsMaxRaw} but evidence declares $($Ev.tmin)..$($Ev.tmax); note-only (D2 observation period)"
        }
    }
    catch { return '' }
    return ''
}

function Test-EvidenceEntry {
    # R8: returns $null when the evidence entry backs the claim, else a rejection reason.
    # clean claims REQUIRE an objectized entry {ref, tmin, tmax} whose artifact exists
    # under RefRoots and whose scanned range covers the cell interval. found claims may
    # use bare refs (the finding itself is the evidence) but objects are fully checked.
    param($Ev, [string]$CellStart, [string]$CellEnd, [array]$RefRoots, [string]$Mode, [ref]$SpotNote)
    $isObj = $Ev -is [System.Collections.IDictionary]
    if (-not $isObj) {
        if ($Mode -eq 'clean') { return 'clean claim needs objectized evidence {ref, tmin, tmax} — a bare ref proves nothing was scanned (R8)' }
        return $null
    }
    $ref = if ($Ev.Contains('ref')) { [string]$Ev.ref } else { '' }
    if ([string]::IsNullOrWhiteSpace($ref)) { return 'evidence object missing ref' }
    $res = Resolve-CitationRange $ref $RefRoots
    if (-not $res.in_range) { return "evidence ref '$ref' not under RefRoots ($($res.reason))" }
    $abs = Join-Path $repoRoot (($res.normalized_ref) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { return "evidence ref '$($res.normalized_ref)' does not exist on disk" }
    $hasTele = ($Ev.Contains('tmin') -and $Ev.tmin) -and ($Ev.Contains('tmax') -and $Ev.tmax)
    if (-not $hasTele) {
        if ($Mode -eq 'clean') { return 'clean claim requires tmin/tmax telemetry so the engine can reconcile artifact range vs cell (R8)' }
        return $null
    }
    $d1 = ConvertTo-CoverageDatetime ([string]$Ev.tmin)
    $d2 = ConvertTo-CoverageDatetime ([string]$Ev.tmax)
    if ($null -eq $d1 -or $null -eq $d2) { return "evidence tmin/tmax must use 'YYYY-MM-DD HH:mm:ss'" }
    $cs = ConvertTo-CoverageDatetime $CellStart
    $ce = ConvertTo-CoverageDatetime $CellEnd
    if ($null -ne $cs -and $null -ne $ce -and ($d1 -gt $cs -or $d2 -lt $ce)) {
        return "artifact range [$($Ev.tmin) .. $($Ev.tmax)] does not cover cell [$CellStart .. $CellEnd]"
    }
    $SpotNote.Value = Invoke-EvidenceSpotCheck $Ev $abs
    return $null
}

function Update-NodeManifestFill {
    # R1' (task-dispatch-guide): merge extras.manifest.filled into the node's sidecar.
    # declared cells are read-only (frozen at graft); statuses must be found|clean|escalated.
    # M2: R2 (findings/fold) + R8 (evidence reconciliation) are FILL-VALIDITY rules —
    # invalid cells stay pending; the only enforcement points remain settle (R1) / conclude (R4).
    # Returns validation notes; never rejects the report itself.
    param([string]$RunDir, [string]$NodeId, $Cb, [string]$Now, [array]$RefRoots)
    $notes = @()
    $sidecar = Read-NodeManifest $RunDir $NodeId
    if ($null -eq $sidecar) { return $notes }   # legacy node without a manifest: nothing to do

    $fill = $null
    if ((Test-PropPresent $Cb 'extras') -and $null -ne $Cb.extras -and (Test-PropPresent $Cb.extras 'manifest') -and $null -ne $Cb.extras.manifest) {
        $fill = $Cb.extras.manifest
    }
    if ($null -eq $fill) {
        $notes += 'manifest_missing: node has a coverage manifest but callback extras.manifest is absent; cells stay pending (settle gate R1 will flag)'
        return $notes
    }
    if (Test-PropPresent $fill 'declared') {
        $notes += 'declared_readonly: extras.manifest.declared ignored (cells are frozen at graft time)'
    }
    $fillMap = $null
    if ((Test-PropPresent $fill 'filled') -and $null -ne $fill.filled) { $fillMap = $fill.filled }
    if ($null -eq $fillMap) {
        $notes += 'manifest_missing: extras.manifest present but filled map absent; cells stay pending'
        return $notes
    }

    # --- R2: findings rows (one row per episode; folded peaks are discarded) ---
    $findingsRaw = @()
    if ((Test-PropPresent $Cb 'extras') -and $null -ne $Cb.extras -and (Test-PropPresent $Cb.extras 'findings') -and $null -ne $Cb.extras.findings) {
        $findingsRaw = @($Cb.extras.findings)
    }
    $validFindings = @()
    $ri = 0
    foreach ($row in $findingsRaw) {
        if ($null -eq $row -or $row -isnot [System.Management.Automation.PSCustomObject]) {
            $notes += "findings_row_invalid: findings[$ri] must be an object; discarded"; $ri++; continue
        }
        $entity = if (Test-PropPresent $row 'entity') { [string]$row.entity } else { '' }
        $rowNote = if (Test-PropPresent $row 'note') { [string]$row.note } else { '' }
        $iv = @()
        if (Test-PropPresent $row 'interval') { $iv = @($row.interval) }
        if ($iv.Count -ne 2) {
            $notes += "findings_row_invalid: findings[$ri] '$entity' must carry its own interval [start, end]; discarded (R2: one row per episode)"; $ri++; continue
        }
        $rowS = ConvertTo-CoverageDatetime ([string]$iv[0])
        $rowE = ConvertTo-CoverageDatetime ([string]$iv[1])
        if ($null -eq $rowS -or $null -eq $rowE -or $rowE -le $rowS) {
            $notes += "findings_row_invalid: findings[$ri] '$entity' interval must be 'YYYY-MM-DD HH:mm:ss' with end after start; discarded"; $ri++; continue
        }
        $fold = Get-FoldPair ("$entity $rowNote")
        if ($null -ne $fold) {
            $notes += "fold_detected: findings[$ri] '$entity' folds $($fold.t1) & $($fold.t2) into one row — split into one row per episode (R2); row discarded and linked cells stay pending"
            $ri++; continue
        }
        $rowEv = @()
        if (Test-PropPresent $row 'evidence') { $rowEv = @($row.evidence | ForEach-Object { [string]$_ }) }
        if ($rowEv.Count -eq 0) {
            $notes += "findings_row_invalid: findings[$ri] '$entity' has no evidence ref; discarded"; $ri++; continue
        }
        $validFindings += @{ entity = $entity; interval = @([string]$iv[0], [string]$iv[1]); evidence = $rowEv; note = $rowNote }
        $ri++
    }

    # --- per-cell fill validation (R1' status + R8 evidence + D1 findings association) ---
    $declaredIds = @()
    foreach ($c in @($sidecar.declared.cells)) { $declaredIds += [string]$c.id }

    $updated = @{}
    foreach ($cid in $declaredIds) {
        if (-not (Test-PropPresent $fillMap $cid)) { continue }
        $entry = $fillMap.$cid
        $status = ''
        if ($null -ne $entry -and (Test-PropPresent $entry 'status')) { $status = [string]$entry.status }
        if (@('found', 'clean', 'escalated') -notcontains $status) {
            $notes += "bad_status: cell '$cid' status '$status' not in found|clean|escalated; cell stays pending"
            continue
        }
        $cell = @()
        foreach ($c in @($sidecar.declared.cells)) { if ([string]$c.id -eq $cid) { $cell = @($c.interval) } }
        $cellStart = [string]$cell[0]; $cellEnd = [string]$cell[1]

        if ($status -ne 'escalated') {
            # evidence reconciliation (R8)
            $evArr = @()
            if ($null -ne $entry -and (Test-PropPresent $entry 'evidence')) {
                $evArr = @($entry.evidence | ForEach-Object { if ($_ -is [System.Collections.IDictionary] -or $_ -is [string]) { $_ } else { Convert-PSObjectToHashtable $_ } })
            }
            if ($evArr.Count -eq 0) {
                $notes += "r8_evidence_rejected: cell '$cid' ($status) carries no evidence; cell stays pending"
                continue
            }
            $evOk = $true
            foreach ($ev in $evArr) {
                $spotNote = ''
                $reason = Test-EvidenceEntry $ev $cellStart $cellEnd $RefRoots $status ([ref]$spotNote)
                if ($spotNote -ne '') { $notes += $spotNote }
                if ($null -ne $reason) {
                    $notes += "r8_evidence_rejected: cell '$cid' ($status) — $reason; cell stays pending"
                    $evOk = $false
                }
            }
            if (-not $evOk) { continue }

            # D1: found claims must hang off a findings row inside the cell interval
            if ($status -eq 'found') {
                $linked = $false
                foreach ($vf in $validFindings) {
                    $fs = ConvertTo-CoverageDatetime ([string]$vf.interval[0])
                    $fe = ConvertTo-CoverageDatetime ([string]$vf.interval[1])
                    $cs = ConvertTo-CoverageDatetime $cellStart
                    $ce = ConvertTo-CoverageDatetime $cellEnd
                    if ($null -ne $fs -and $null -ne $fe -and $null -ne $cs -and $null -ne $ce -and $fs -ge $cs -and $fe -le $ce) { $linked = $true; break }
                }
                if (-not $linked) {
                    $notes += "findings_missing: cell '$cid' filled found but no valid findings row falls inside [$cellStart .. $CellEnd]; cell stays pending (D1: findings rows are the sweep deliverable)"
                    continue
                }
            }
        }

        $storedEv = @()
        if ($null -ne $entry -and (Test-PropPresent $entry 'evidence')) {
            $storedEv = @($entry.evidence | ForEach-Object { if ($_ -is [string]) { $_ } else { Convert-PSObjectToHashtable $_ } })
        }
        $updated[$cid] = @{
            status   = $status
            evidence = $storedEv
            note     = if ($null -ne $entry -and (Test-PropPresent $entry 'note')) { [string]$entry.note } else { '' }
        }
    }
    foreach ($p in @($fillMap.PSObject.Properties)) {
        if ($declaredIds -notcontains $p.Name) { $notes += "unknown_cell: filled key '$($p.Name)' has no declared cell; ignored" }
    }

    if ($updated.Count -gt 0 -or $validFindings.Count -gt 0) {
        $merged = @{}
        if ((Test-PropPresent $sidecar 'filled') -and $null -ne $sidecar.filled) {
            foreach ($p in @($sidecar.filled.PSObject.Properties)) { $merged[$p.Name] = $p.Value }
        }
        foreach ($k in @($updated.Keys)) { $merged[$k] = $updated[$k] }
        $sidecar | Add-Member -Force -NotePropertyName filled -NotePropertyValue $merged
        $existingFindings = @()
        if ((Test-PropPresent $sidecar 'findings') -and $null -ne $sidecar.findings) { $existingFindings = @($sidecar.findings) }
        $sidecar | Add-Member -Force -NotePropertyName findings -NotePropertyValue (@($existingFindings) + @($validFindings))
        $sidecar | Add-Member -Force -NotePropertyName updated_at -NotePropertyValue $Now
        Write-NodeManifest $RunDir $sidecar
    }
    return $notes
}

function Get-ProbeReconciliationNotes {
    # R5 (task-dispatch-guide / rca role cards): probe nodes reconcile extras.probe against
    # the three-valued contract {verdict: upheld|refuted|inconclusive, falsification_attempted: [..]}.
    # Note-only observation period (mirrors spotcheck / manifest_missing precedent): notes land in
    # validation.notes, the report is never rejected and the node still transitions.
    # Legacy/non-probe nodes (type null) -> nothing to do (fail-open).
    param($Node, $Cb)
    $notes = @()
    if ([string]$Node.type -ne 'probe') { return $notes }

    $probe = $null
    if ((Test-PropPresent $Cb 'extras') -and $null -ne $Cb.extras -and (Test-PropPresent $Cb.extras 'probe') -and $null -ne $Cb.extras.probe) {
        $probe = $Cb.extras.probe
    }
    if ($null -eq $probe) {
        $notes += 'probe_extras_missing: node is type=probe but callback extras.probe is absent (expected {verdict: upheld|refuted|inconclusive, falsification_attempted: [...]}); note-only'
        return $notes
    }
    $verdict = ''
    if (Test-PropPresent $probe 'verdict') { $verdict = [string]$probe.verdict }
    if ([string]::IsNullOrWhiteSpace($verdict)) {
        $notes += 'probe_verdict_missing: extras.probe.verdict absent; expected upheld|refuted|inconclusive; note-only'
    }
    elseif (@('upheld', 'refuted', 'inconclusive') -notcontains $verdict) {
        $notes += "probe_verdict_invalid: extras.probe.verdict '$verdict' not in upheld|refuted|inconclusive; note-only"
    }
    $attempts = @()
    if ((Test-PropPresent $probe 'falsification_attempted') -and $null -ne $probe.falsification_attempted) { $attempts = @($probe.falsification_attempted) }
    if ($attempts.Count -eq 0) {
        $notes += 'probe_falsification_not_recorded: extras.probe.falsification_attempted absent or empty — a pure confirmation probe violates R5; note-only'
    }
    return $notes
}

function Resolve-RunDir {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        Write-ErrorResult "MISSING_RUN_ID" "-RunId is required" 1
    }
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-ErrorResult "INVALID_RUN_ID" "RunId must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ : $Id" 1
    }
    $dir = Get-RunDir $Id
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-ErrorResult "RUN_NOT_FOUND" "Tree run not found: .rdd/tree-runs/$Id" 2
    }
    return $dir
}

function Enter-RunLock {
    param([string]$RunDir, [int]$TimeoutSec = 10, [int]$StaleSec = 60)
    $script:LockPath = Get-LockPath $RunDir
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stolen = $false
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "cmd=$Command worker=$Worker pid=$PID at=$(Get-Date -Format s)"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            $script:LockStream = $fs
            return @{ path = $script:LockPath; stale_taken_over = $stolen }
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if (Test-Path -LiteralPath $script:LockPath -PathType Leaf) {
                $age = ((Get-Date) - (Get-Item -LiteralPath $script:LockPath).LastWriteTime).TotalSeconds
                if ($age -gt $StaleSec) {
                    try { Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue } catch {}
                    $stolen = $true
                    continue
                }
            }
            else {
                continue
            }
            if ((Get-Date) -gt $deadline) {
                Write-ErrorResult "LOCK_TIMEOUT" "Run lock held by another writer for > ${TimeoutSec}s: $script:LockPath. Back off and retry." 3
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Exit-RunLock {
    if ($null -ne $script:LockStream) {
        try { $script:LockStream.Close() } catch {}
        $script:LockStream = $null
    }
    if ($script:LockPath -and (Test-Path -LiteralPath $script:LockPath -PathType Leaf)) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:LockPath, [System.Text.Encoding]::UTF8)
            if ($raw -match "pid=$PID ") { Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

# === Readers ===

function Read-Manifest {
    param([string]$RunDir)
    $p = Get-ManifestPath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-ErrorResult "MANIFEST_NOT_FOUND" "manifest.json not found in run: $RunDir" 2
    }
    try {
        $m = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "MANIFEST_CORRUPT" "manifest.json failed to parse: $($_.Exception.Message)" 3
    }
    return @{
        run_id    = [string]$m.run_id
        goal      = [string]$m.goal
        created_by = if ($m.created_by) { [string]$m.created_by } else { "unknown" }
        budget    = @{
            max_rounds = [int]$m.budget.max_rounds
            node_width = [int]$m.budget.node_width
            max_nodes  = [int]$m.budget.max_nodes
        }
        ref_roots = @(Convert-ToSafeArray $m.ref_roots)
        state     = [string]$m.state
        concluded = $m.concluded
    }
}

function Convert-NodeToHashtable {
    param($Node)
    return [ordered]@{
        id              = [string]$Node.id
        parent          = if ($Node.parent) { [string]$Node.parent } else { $null }
        title           = [string]$Node.title
        task            = [string]$Node.task
        type            = if ($Node.type) { [string]$Node.type } else { $null }
        role            = if ($Node.role) { [string]$Node.role } else { $null }
        falsification_duty = if ($Node.falsification_duty) { [string]$Node.falsification_duty } else { $null }
        status          = [string]$Node.status
        created_round   = if ($null -ne $Node.created_round) { [int]$Node.created_round } else { 0 }
        claimed_by      = if ($Node.claimed_by) { [string]$Node.claimed_by } else { $null }
        claimed_at      = if ($Node.claimed_at) { [string]$Node.claimed_at } else { $null }
        steal_count     = if ($null -ne $Node.steal_count) { [int]$Node.steal_count } else { 0 }
        reported_at     = if ($Node.reported_at) { [string]$Node.reported_at } else { $null }
        settled_at      = if ($Node.settled_at) { [string]$Node.settled_at } else { $null }
        settled_note    = if ($Node.settled_note) { [string]$Node.settled_note } else { $null }
        pruned_at       = if ($Node.pruned_at) { [string]$Node.pruned_at } else { $null }
        pruned_reason   = if ($Node.pruned_reason) { [string]$Node.pruned_reason } else { $null }
        last_verdict    = if ($Node.last_verdict) { [string]$Node.last_verdict } else { $null }
        last_confidence = if ($null -ne $Node.last_confidence) { [double]$Node.last_confidence } else { $null }
        ledger_refs     = @(Convert-ToSafeArray $Node.ledger_refs)
        note            = if ($Node.note) { [string]$Node.note } else { $null }
        children        = @(Convert-ToSafeArray $Node.children)
    }
}

function Read-TreeEditable {
    param([string]$RunDir)
    $p = Get-TreePath $RunDir
    $bak = "$p.bak"
    $usedBak = $false
    $obj = $null
    foreach ($candidate in @($p, $bak)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $obj = [System.IO.File]::ReadAllText($candidate, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($candidate -eq $bak) { $usedBak = $true }
            break
        }
        catch { continue }
    }
    if ($null -eq $obj) {
        Write-ErrorResult "TREE_CORRUPT" "tree.json (and .bak) failed to parse under $RunDir" 3
    }
    $nodes = @()
    foreach ($n in @(Convert-ToSafeArray $obj.nodes)) { $nodes += ,(Convert-NodeToHashtable $n) }
    return @{
        used_backup = $usedBak
        tree        = [ordered]@{
            format_version = [int]$obj.format_version
            run_id         = [string]$obj.run_id
            goal           = [string]$obj.goal
            updated_at     = [string]$obj.updated_at
            nodes          = $nodes
        }
    }
}

function Write-TreeFile {
    param([string]$RunDir, $Tree)
    $p = Get-TreePath $RunDir
    $Tree.updated_at = Get-UtcNowIso
    $json = ConvertTo-Json $Tree -Depth 10
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        Copy-Item -LiteralPath $p -Destination "$p.bak" -Force
    }
    [System.IO.File]::WriteAllText($p, $json, $script:Utf8NoBom)
    try {
        $null = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        if (Test-Path -LiteralPath "$p.bak" -PathType Leaf) {
            Copy-Item -LiteralPath "$p.bak" -Destination $p -Force
        }
        Write-ErrorResult "TREE_WRITE_READBACK_FAILED" "tree.json read-back failed after write; previous snapshot restored from .bak" 3
    }
}

function Read-LedgerEntries {
    param([string]$RunDir)
    $p = Get-LedgerPath $RunDir
    $count = 0
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return 0 }
    $lines = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })
    return $lines.Count
}

function Get-OpenRound {
    param([string]$RunDir)
    $p = Get-RoundLogPath $RunDir
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return 0 }
    $lines = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne "" })
    $open = 0
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $o = $lines[$i] | ConvertFrom-Json
            if ($o.event -eq "round-start") { $open = [int]$o.round }
            break
        }
        catch { continue }
    }
    return $open
}

function Find-Node {
    param($Tree, [string]$Id)
    foreach ($n in $Tree.nodes) {
        if ($n.id -eq $Id) { return $n }
    }
    return $null
}

# === Citation range check ===
#
# A citation ref is IN RANGE when either:
#   (a) its normalized repo-relative form equals / is prefixed by a declared
#       RefRoot, or
#   (b) joining it under a RefRoot yields an existing path — the rca-poc
#       lesson: workers echo refs relative to the case root (plane/logs/x.log)
#       or as absolute paths; the engine normalizes both mechanically instead
#       of leaving that to the Manager. Existence is the mechanical witness
#       that a relative ref truly lives under the root.
# Path traversal (../ segments) can never be in range.

function Normalize-Ref {
    param([string]$Ref)
    $r = $Ref.Trim() -replace '\\', '/'
    $r = $r -replace '^\./', ''
    # strip absolute repo-root prefix (rca-poc lesson: workers echo full paths)
    $rootFwd = ($repoRoot -replace '\\', '/')
    $rootBak = $repoRoot
    foreach ($form in @($rootFwd, $rootBak)) {
        if ($r.Length -gt $form.Length -and $r.ToLowerInvariant().StartsWith($form.ToLowerInvariant())) {
            $r = $r.Substring($form.Length).TrimStart('/')
        }
    }
    $r = $r.TrimStart('/')
    return $r
}

function Test-RefTraversal {
    param([string]$NormRef)
    if ($NormRef -eq '..' -or $NormRef -like '../*' -or $NormRef -like '*/../*' -or $NormRef -like '*/..') { return $true }
    return $false
}

function Resolve-CitationRange {
    # returns @{ in_range = bool; normalized_ref = string; reason = string }
    param([string]$RawRef, [array]$Roots)

    $norm = Normalize-Ref $RawRef
    if ($norm -eq '') {
        return @{ in_range = $false; normalized_ref = $norm; reason = "empty ref" }
    }
    if (Test-RefTraversal $norm) {
        return @{ in_range = $false; normalized_ref = $norm; reason = "path traversal (..) is never in range" }
    }

    foreach ($r in $Roots) {
        $rn = ([string]$r).Trim() -replace '\\', '/'
        $rn = $rn.TrimEnd('/')
        if ($rn -eq '.' -or $rn -eq '') {
            return @{ in_range = $true; normalized_ref = $norm; reason = "" }
        }
        if ($norm -eq $rn -or $norm.ToLowerInvariant().StartsWith($rn.ToLowerInvariant() + '/')) {
            return @{ in_range = $true; normalized_ref = $norm; reason = "" }
        }
    }

    # relative-to-root join, witnessed by existence on disk
    foreach ($r in $Roots) {
        $rn = ([string]$r).Trim() -replace '\\', '/'
        $rn = $rn.TrimEnd('/')
        if ($rn -eq '.' -or $rn -eq '') { continue }
        $joined = "$rn/$norm"
        $abs = Join-Path $repoRoot ($joined -replace '/', '\')
        if (Test-Path -LiteralPath $abs) {
            return @{ in_range = $true; normalized_ref = $joined; reason = "normalized from root-relative '$RawRef'" }
        }
    }

    return @{ in_range = $false; normalized_ref = $norm; reason = "outside declared RefRoots: $($Roots -join ', ')" }
}

# === Callback validation (fixed core schema, engine-enforced) ===
#
#   node_id        string   required, must reference an existing node
#   verdict        enum     required: done | failed | inconclusive
#   confidence     number   required, clamped into [0,1] with a note when out of range
#   summary        string   required, non-empty
#   citations      array    required: [{ref, locator}] — ref must fall under a
#                           declared RefRoot; out-of-range citations are rejected
#                           (kept in range_check_failures), never silently dropped
#   next_suggestion string  required (may be empty)
#   extras         object   optional, passed through unvalidated (domain fields)
#
# Structural failures -> entry recorded with validation.status=invalid and the
# node is NOT transitioned (stays claimed; Manager re-dispatches or steals).
# Designed degradations -> validation.status=downgraded and the node advances.

function Test-CallbackStructure {
    param($Cb)
    # $Cb is a ConvertFrom-Json PSCustomObject (not yet converted)
    $problems = @()
    if ($null -eq $Cb) { return @("callback is not a JSON object") }
    if ($null -eq $Cb.PSObject.Properties["node_id"] -or [string]::IsNullOrWhiteSpace([string]$Cb.node_id)) { $problems += "missing/empty node_id" }
    if ($null -eq $Cb.PSObject.Properties["verdict"]) { $problems += "missing verdict" }
    else {
        $v = [string]$Cb.verdict
        if (@("done", "failed", "inconclusive") -notcontains $v) { $problems += "verdict must be done|failed|inconclusive, got '$v'" }
    }
    if ($null -eq $Cb.PSObject.Properties["confidence"]) { $problems += "missing confidence" }
    else {
        $c = $Cb.confidence
        if ($null -eq $c -or ($c -isnot [double] -and $c -isnot [int] -and $c -isnot [long] -and $c -isnot [decimal])) { $problems += "confidence must be a number, got '$c'" }
    }
    if ($null -eq $Cb.PSObject.Properties["summary"] -or [string]::IsNullOrWhiteSpace([string]$Cb.summary)) { $problems += "missing/empty summary" }
    if ($null -eq $Cb.PSObject.Properties["citations"]) { $problems += "missing citations" }
    else {
        if ($Cb.citations -isnot [array]) { $problems += "citations must be an array of {ref, locator}" }
        else {
            $i = 0
            foreach ($c in $Cb.citations) {
                if ($null -eq $c -or $c -isnot [System.Management.Automation.PSCustomObject] -or [string]::IsNullOrWhiteSpace([string]$c.ref)) {
                    $problems += "citations[$i] must be an object with non-empty ref"
                }
                $i++
            }
        }
    }
    if ($null -eq $Cb.PSObject.Properties["next_suggestion"]) { $problems += "missing next_suggestion (empty string allowed)" }
    if ($null -ne $Cb.PSObject.Properties["extras"] -and $null -ne $Cb.extras -and $Cb.extras -isnot [System.Management.Automation.PSCustomObject]) {
        $problems += "extras must be a JSON object when present"
    }
    return $problems
}

function Convert-NodeToPublicView {
    param($Node)
    return [ordered]@{
        id              = $Node.id
        parent          = $Node.parent
        title           = $Node.title
        task            = $Node.task
        type            = $Node.type
        role            = $Node.role
        falsification_duty = $Node.falsification_duty
        status          = $Node.status
        created_round   = $Node.created_round
        claimed_by      = $Node.claimed_by
        claimed_at      = $Node.claimed_at
        steal_count     = $Node.steal_count
        reported_at     = $Node.reported_at
        last_verdict    = $Node.last_verdict
        last_confidence = $Node.last_confidence
        ledger_refs     = @($Node.ledger_refs)
        note            = $Node.note
        children        = @($Node.children)
    }
}

# === Command: next ===

function Invoke-Next {
    param([string]$RunDir)
    $manifest = Read-Manifest $RunDir
    $readBack = Read-TreeEditable $RunDir
    $tree = $readBack.tree
    $openRound = Get-OpenRound $RunDir

    $pending = @()
    foreach ($n in $tree.nodes) {
        if ($n.status -eq "pending") {
            $pending += [ordered]@{ id = $n.id; parent = $n.parent; title = $n.title; task = $n.task; type = $n.type; role = $n.role; grafted_round = $n.created_round }
        }
    }
    if ($Limit -gt 0 -and $pending.Count -gt $Limit) {
        $pending = @($pending | Select-Object -First $Limit)
    }

    return @{
        success = $true
        data    = [ordered]@{
            run_id      = $RunId
            goal        = $manifest.goal
            state       = $manifest.state
            round_open  = ($openRound -ne 0)
            round       = $openRound
            budget      = $manifest.budget
            ref_roots   = @($manifest.ref_roots)
            pending     = $pending
            pending_all = (@($tree.nodes | Where-Object { $_.status -eq "pending" })).Count
            hint        = $(if ($openRound -eq 0) { "no open round — claim will be rejected until the Manager runs round-start" } else { "claim one node with: tree-leaf.cmd -Command claim -RunId $RunId -NodeId <id> -Worker <label>" })
        }
    }
}

# === Command: claim ===

function Invoke-Claim {
    param([string]$RunDir)

    if ([string]::IsNullOrWhiteSpace($NodeId)) { Write-ErrorResult "MISSING_NODE_ID" "-NodeId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Worker)) { Write-ErrorResult "MISSING_WORKER" "-Worker (your label) is required" 1 }

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-Manifest $RunDir
        if ($manifest.state -eq "concluded") {
            Write-ErrorResult "RUN_CONCLUDED" "Run concluded (outcome=$($manifest.concluded.outcome)); no further consumption." 1
        }
        $openRound = Get-OpenRound $RunDir
        if ($openRound -eq 0) { Write-ErrorResult "NO_OPEN_ROUND" "No open round; claims are only valid inside an open round." 1 }

        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree
        $node = Find-Node $tree $NodeId
        if ($null -eq $node) { Write-ErrorResult "NODE_NOT_FOUND" "Node not found: $NodeId" 2 }

        if ($Steal) {
            if ($node.status -ne "claimed") {
                Write-ErrorResult "STEAL_REQUIRES_CLAIMED" "-Steal only recovers nodes stuck in 'claimed' state; node $NodeId is '$($node.status)'." 1
            }
            $node.claimed_by = $Worker
            $node.claimed_at = Get-UtcNowIso
            $node.steal_count = [int]$node.steal_count + 1
            $stole = $true
        }
        else {
            if ($node.status -ne "pending") {
                Write-ErrorResult "NODE_NOT_CLAIMABLE" "Node $NodeId is '$($node.status)'; only pending nodes can be claimed (reported/done nodes are never re-consumed; stuck claimed nodes need -Steal)." 1
            }
            $node.status = "claimed"
            $node.claimed_by = $Worker
            $node.claimed_at = Get-UtcNowIso
            $stole = $false
        }

        Write-TreeFile $RunDir $tree

        return @{
            success = $true
            data    = @{
                run_id  = $RunId
                round   = $openRound
                stolen  = $stole
                node    = (Convert-NodeToPublicView $node)
                report_next = "tree-leaf.cmd -Command report -RunId $RunId -Worker $Worker -CallbackFile <path-to-callback.json>"
                lock    = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: report ===

function Invoke-Report {
    param([string]$RunDir)

    if ([string]::IsNullOrWhiteSpace($Worker)) { Write-ErrorResult "MISSING_WORKER" "-Worker (your label) is required" 1 }

    $cbJson = $null
    if (-not [string]::IsNullOrWhiteSpace($CallbackFile)) {
        $cf = $CallbackFile
        if (-not [System.IO.Path]::IsPathRooted($cf)) { $cf = Join-Path $repoRoot $cf }
        if (-not (Test-Path -LiteralPath $cf -PathType Leaf)) { Write-ErrorResult "CALLBACK_FILE_NOT_FOUND" "Callback file not found: $cf" 1 }
        $cbJson = [System.IO.File]::ReadAllText($cf, [System.Text.Encoding]::UTF8)
    }
    else {
        $cbJson = $Callback
    }
    if ([string]::IsNullOrWhiteSpace($cbJson)) { Write-ErrorResult "MISSING_CALLBACK" "-Callback (inline JSON) or -CallbackFile (recommended for non-ASCII) is required" 1 }

    try {
        $cb = $cbJson | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "CALLBACK_NOT_JSON" "Callback is not valid JSON: $($_.Exception.Message)" 1
    }

    # --- B2 channel separation (usage errors: not recorded, caller retries) ---
    # summary is a SUMMARY: full findings belong in a file referenced by full_report.
    # Without the cap, 2k+ char reports ride every status read / completion notice
    # into the Manager's context (the B2 pressure source observed in rca-eval).
    $summaryText = if ($null -ne $cb.PSObject.Properties["summary"]) { [string]$cb.summary } else { "" }
    if ($summaryText.Length -gt 600) {
        Write-ErrorResult "SUMMARY_TOO_LONG" "callback.summary is $($summaryText.Length) chars (limit 600). Write the FULL findings to a file under the run dir (e.g. report/workers/<node-id>.md), reference it via callback.full_report, and keep summary to verdict + key timestamps + <=3 findings." 1
    }
    $fullReport = $null
    if ($null -ne $cb.PSObject.Properties["full_report"] -and -not [string]::IsNullOrWhiteSpace([string]$cb.full_report)) {
        $fr = [string]$cb.full_report
        $frAbs = $fr
        if (-not [System.IO.Path]::IsPathRooted($frAbs)) { $frAbs = Join-Path $repoRoot $fr }
        if (-not (Test-Path -LiteralPath $frAbs -PathType Leaf)) { Write-ErrorResult "FULL_REPORT_NOT_FOUND" "callback.full_report not found: $frAbs" 1 }
        $fullReport = $fr
    }

    $lockInfo = Enter-RunLock $RunDir
    try {
        $manifest = Read-Manifest $RunDir
        if ($manifest.state -eq "concluded") {
            Write-ErrorResult "RUN_CONCLUDED" "Run concluded (outcome=$($manifest.concluded.outcome)); no further consumption." 1
        }
        $openRound = Get-OpenRound $RunDir
        if ($openRound -eq 0) { Write-ErrorResult "NO_OPEN_ROUND" "No open round; callbacks are only valid inside an open round." 1 }

        $readBack = Read-TreeEditable $RunDir
        $tree = $readBack.tree

        $entryId = "L$((Read-LedgerEntries $RunDir) + 1)"
        $now = Get-UtcNowIso
        $cbNodeId = if ($null -ne $cb.PSObject.Properties["node_id"]) { [string]$cb.node_id } else { $null }

        $node = $null
        if ($cbNodeId) { $node = Find-Node $tree $cbNodeId }

        # --- structural validation ---
        $problems = @(Test-CallbackStructure $cb)
        if ($problems.Count -gt 0 -or $null -eq $node) {
            if ($null -eq $node -and $problems.Count -eq 0) { $problems = @("node_id '$cbNodeId' does not exist in this run") }
            $entry = [ordered]@{
                entry_id    = $entryId
                round       = $openRound
                node_id     = $cbNodeId
                role        = if ($null -ne $node -and $node.role) { [string]$node.role } else { $null }
                worker      = $Worker
                reported_at = $now
                callback    = (Convert-PSObjectToHashtable $cb)
                validation  = [ordered]@{
                    status               = "invalid"
                    reasons               = $problems
                    confidence_clamped    = $false
                    range_check_failures  = @()
                    verdict_downgraded    = $false
                }
            }
            $line = ConvertTo-Json $entry -Depth 12 -Compress
            [System.IO.File]::AppendAllText((Get-LedgerPath $RunDir), $line + "`n", $script:Utf8NoBom)
            # read-back finish
            $all = @([System.IO.File]::ReadAllLines((Get-LedgerPath $RunDir)) | Where-Object { $_.Trim() -ne "" })
            try { $null = $all[-1] | ConvertFrom-Json } catch { Write-ErrorResult "LEDGER_READBACK_FAILED" "ledger.jsonl last line failed to parse after append" 3 }

            return @{
                success = $true
                data    = @{
                    run_id     = $RunId
                    entry_id   = $entryId
                    accepted   = $false
                    validation = $entry.validation
                    node_status = $(if ($node) { $node.status } else { "unknown-node" })
                    message    = "Callback rejected (structural). It is recorded in the ledger for audit; the node was NOT transitioned. Fix the callback and report again."
                    lock       = $lockInfo
                }
            }
        }

        # --- protocol state checks (usage errors: not recorded, caller must retry correctly) ---
        if ($node.status -ne "claimed") {
            Write-ErrorResult "NODE_NOT_CLAIMED" "Node $cbNodeId is '$($node.status)'; report requires the node to be claimed by you. done/reported nodes are never re-consumed." 1
        }
        if ([string]$node.claimed_by -ne $Worker) {
            Write-ErrorResult "CLAIM_OWNER_MISMATCH" "Node $cbNodeId is claimed by '$($node.claimed_by)', not '$Worker'. Only the current holder may report; a Manager can recover the node via claim -Steal." 1
        }

        # --- designed degradations ---
        $notes = @()
        $clamped = $false
        $downgradedVerdict = $false

        $confidence = [double]$cb.confidence
        if ($confidence -lt 0) { $confidence = 0.0; $clamped = $true; $notes += "confidence $($cb.confidence) < 0 clamped to 0" }
        if ($confidence -gt 1) { $confidence = 1.0; $clamped = $true; $notes += "confidence $($cb.confidence) > 1 clamped to 1" }

        $validCitations = @()
        $rangeFailures = @()
        foreach ($c in @($cb.citations)) {
            $res = Resolve-CitationRange ([string]$c.ref) @($manifest.ref_roots)
            if ($res.in_range) {
                $validCitations += @{ ref = $res.normalized_ref; locator = [string]$c.locator }
                if ($res.reason -ne '') { $notes += "citation '$($c.ref)' $res.reason" }
            }
            else {
                $rangeFailures += @{ ref = [string]$c.ref; locator = [string]$c.locator; reason = $res.reason }
            }
        }

        $verdict = [string]$cb.verdict
        if ($verdict -eq "done" -and $validCitations.Count -eq 0) {
            $verdict = "inconclusive"
            $downgradedVerdict = $true
            $notes += "verdict done downgraded to inconclusive: no in-range citation survived range check"
        }

        # --- R1' coverage manifest fill (task-dispatch-guide): notes only, never rejects ---
        $notes += @(Update-NodeManifestFill $RunDir ([string]$cb.node_id) $cb $now @($manifest.ref_roots))

        # --- R5 probe reconciliation (task-dispatch-guide): notes only, never rejects ---
        $notes += @(Get-ProbeReconciliationNotes $node $cb)

        # validation.status reflects actual DEGRADATIONS only (clamp / rejected
        # citations / verdict downgrade). Citation normalization notes are the
        # engine doing its job, not a callback defect.
        $validationStatus = "valid"
        if ($clamped -or $rangeFailures.Count -gt 0 -or $downgradedVerdict) { $validationStatus = "downgraded" }

        $finalCallback = [ordered]@{
            node_id        = [string]$cb.node_id
            verdict        = $verdict
            confidence     = $confidence
            summary        = [string]$cb.summary
            full_report    = $fullReport
            citations      = $validCitations
            next_suggestion = [string]$cb.next_suggestion
            extras         = (Convert-PSObjectToHashtable $cb.extras)
        }
        $entry = [ordered]@{
            entry_id    = $entryId
            round       = $openRound
            node_id     = [string]$cb.node_id
            role        = if ($node.role) { [string]$node.role } else { $null }
            worker      = $Worker
            reported_at = $now
            callback    = $finalCallback
            validation  = [ordered]@{
                status              = $validationStatus
                notes               = $notes
                confidence_clamped  = $clamped
                range_check_failures = $rangeFailures
                verdict_downgraded  = $downgradedVerdict
            }
        }

        # --- ledger append (append-only) + read-back ---
        $line = ConvertTo-Json $entry -Depth 12 -Compress
        [System.IO.File]::AppendAllText((Get-LedgerPath $RunDir), $line + "`n", $script:Utf8NoBom)
        $all = @([System.IO.File]::ReadAllLines((Get-LedgerPath $RunDir)) | Where-Object { $_.Trim() -ne "" })
        try { $null = $all[-1] | ConvertFrom-Json } catch { Write-ErrorResult "LEDGER_READBACK_FAILED" "ledger.jsonl last line failed to parse after append" 3 }

        # --- node transition (hardcoded whitelist: status/claim/report summary fields only) ---
        $node.status = "reported"
        $node.reported_at = $now
        $node.last_verdict = $verdict
        $node.last_confidence = $confidence
        $node.ledger_refs = @($node.ledger_refs) + $entryId
        Write-TreeFile $RunDir $tree

        return @{
            success = $true
            data    = @{
                run_id     = $RunId
                entry_id   = $entryId
                accepted   = $true
                validation = $entry.validation
                node       = (Convert-NodeToPublicView $node)
                lock       = $lockInfo
            }
        }
    }
    finally {
        Exit-RunLock
    }
}

# === Command: status (read-only worker view) ===

function Invoke-LeafStatus {
    param([string]$RunDir)
    $manifest = Read-Manifest $RunDir
    $readBack = Read-TreeEditable $RunDir
    $tree = $readBack.tree
    $openRound = Get-OpenRound $RunDir

    if (-not [string]::IsNullOrWhiteSpace($NodeId)) {
        $node = Find-Node $tree $NodeId
        if ($null -eq $node) { Write-ErrorResult "NODE_NOT_FOUND" "Node not found: $NodeId" 2 }
        $nodeManifest = Read-NodeManifest $RunDir $NodeId
        return @{
            success = $true
            data    = [ordered]@{
                run_id   = $RunId
                state    = $manifest.state
                round    = $openRound
                node     = (Convert-NodeToPublicView $node)
                manifest = $nodeManifest
            }
        }
    }

    $nodes = @()
    foreach ($n in $tree.nodes) {
        $nodes += (Convert-NodeToPublicView $n)
    }
    return @{
        success = $true
        data    = [ordered]@{
            run_id        = $RunId
            goal          = $manifest.goal
            state         = $manifest.state
            round         = $openRound
            budget        = $manifest.budget
            ref_roots     = @($manifest.ref_roots)
            nodes         = $nodes
            tree_read_from_backup = $readBack.used_backup
        }
    }
}

# === Dispatch ===

$runDir = Resolve-RunDir $RunId

switch ($Command) {
    "next"    { $result = Invoke-Next $runDir }
    "claim"   { $result = Invoke-Claim $runDir }
    "report"  { $result = Invoke-Report $runDir }
    "status"  { $result = Invoke-LeafStatus $runDir }
}

ConvertTo-PortableJson $result -Depth 14
exit 0

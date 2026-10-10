# tips.ps1 — project-level role tips record/query CLI (engine 5th CLI class)
#
# Persists reusable lessons (pitfalls, traps, conventions) that any role
# session hits as structured tip entries under .rdd/tips/entries/ — one JSON
# file per entry (schema rdd-tip/2, UTF-8 no BOM, git-tracked; unique-ID
# filenames are immune to parallel / cross-clone merge conflicts). Decoupled
# from task.json routing by design (archive 2026-10-06-role-tips-mechanism):
# it never reads or writes task.json and never touches the exploration zone
# (the recall machinery it borrows is the SHARED code library
# scripts/lib/recall-shared.ps1 — shared CODE, never shared DATA: tips keep
# their own config / vectors files under .rdd/tips/).
#
# v2 (collision-driven injection eligibility): recording NEVER equals
# injecting. A new entry is born latent (status=latent, count=1) and earns
# the injection face only through EVIDENCE — independent collisions (the
# same pit hit again) or an explicit pin. Recording stays cheap and
# ad-hoc-safe: a noisy one-off tip simply stays latent forever; the
# injection consumer (start-role) filters by status, so latent noise never
# reaches a prompt.
#
# Interface:
#   tips.cmd -Command add -By <ROLE> [-Title -Problem -Avoidance
#                                     | -File <payload.json>]
#   tips.cmd -Command list [-Role <R>] [-All]
#   tips.cmd -Command target    -Id <tip-id> -By <ROLE>
#   tips.cmd -Command collide   -Id <tip-id> -By <ROLE> [-SawTip]
#   tips.cmd -Command pin       -Id <tip-id> -By <ROLE>
#   tips.cmd -Command unpin     -Id <tip-id> -By <ROLE>
#   tips.cmd -Command supersede -Id <tip-id> -By <ROLE> [-Note <ascii>]
#   tips.cmd -Command migrate  -By <ROLE> [-Pin "<id>,<id>,..."]
#
#     add   record one tip (born latent: status=latent, count=1,
#           collidedBy=[]). The result envelope carries `candidates` —
#           near-duplicate entries recalled from the store by the shared
#           precision pipeline (lexical BM25 zero-config, vector auto) over
#           the adapter shape key=id, tags=roles, brief=title+problem+
#           avoidance. The recording agent adjudicates: same root cause ->
#           `collide -Id <that entry>` instead of a duplicate; distinct ->
#           keep the new one. Candidates are a prompt-layer gain: ANY
#           pipeline failure (missing library included) degrades to
#           candidates=[] plus a stderr warning — recording never fails
#           because dedup did. Record-then-own semantics (2026-10-06 user
#           ruling): roles = [-By] always, no target-role input on either
#           channel. Inline params and -File are mutually exclusive. Inline
#           values must be pure ASCII: the cmd -> powershell arg chain
#           garbles CJK into LEGAL Unicode that no content validator can
#           detect (docs/code-quality.md section 6.4), so the channel itself
#           is rejected mechanically (NON_ASCII_INLINE). Chinese content
#           goes through -File: a UTF-8 payload {title, problem, avoidance},
#           staged e.g. under .rdd/tmp/; unknown keys are rejected (a legacy
#           "roles" key is rejected too — record-then-own owns targeting).
#     list  query entries, count DESC -> recordedAt DESC -> id DESC, never
#           truncated (start-role B2 summaries consume this output; count
#           caps belong to the consumer). Superseded entries are excluded
#           unless -All. -Role R matches entries whose roles contain R; no
#           filter = every entry; empty store is count=0, not an error.
#           Every entry view carries its lifecycle fields (status/count);
#           legacy rdd-tip/1 files read as status=active count=1 (the
#           pre-migration compatibility view — the injection face keeps its
#           v1 behavior until the P3 migration re-stamps the store).
#     target organic spread: attach -By (the CURRENT role) to an existing
#           entry's roles — reuse a matching tip instead of re-recording it.
#           Idempotent: an already-member role succeeds WITHOUT a rewrite.
#           A rewrite normalizes the file to the full v2 form.
#     collide record one independent re-hit of the same pit: count++,
#           collidedBy += {role, at, sawTip}. -SawTip marks that the
#           colliding session HAD this tip injected (the B2 pointer line
#           freezes what a session saw, keeping pre-injection collisions =
#           value proof and post-injection collisions = injection-
#           ineffectiveness signals distinguishable). latent auto-promotes
#           to active at count>=2; active/pinned/superseded keep status.
#           The colliding role need not be a member (cross-role hits are
#           valid evidence). Missing tip -> TIP_NOT_FOUND.
#     pin   explicit escape valve for rare-but-expensive lessons (one
#           occurrence already proves the value): status=pinned,
#           pinnedBy/pinnedAt stamped. Idempotent. Superseded entries
#           cannot be pinned (INVALID_STATE — supersede is terminal).
#     unpin drop the pin and recompute from evidence: count>=2 -> active,
#           else latent. Requires the pinned status (INVALID_STATE).
#     supersede the tool itself now guards this pit (fixed-into-tool):
#           status=superseded, terminal — excluded from list (unless -All)
#           and from the candidates corpus. -Note carries the fix pointer
#           (pure ASCII inline channel, same NON_ASCII_INLINE guard).
#     migrate one-shot legacy-store migration to the v2 lifecycle
#           (idempotent): every rdd-tip/1 file is rewritten in full v2
#           form — ids listed in -Pin become pinned (pinnedBy = -By),
#           everything else latent. v2 files are skipped untouched;
#           -Pin ids missing from the store fail loud (a mistyped id
#           must not silently demote a proven tip to latent).
#
# Entry schema (rdd-tip/2):
#   {schema, id, title, problem, avoidance, roles[], recordedBy, recordedAt,
#    deprecated:false, status, count, collidedBy[{role,at,sawTip}],
#    pinnedBy?, pinnedAt?, supersededBy?, supersededAt?, note?} — the
#   lifecycle fields are optional ON DISK for rdd-tip/1 back-compat
#   (missing -> status=active count=1 collidedBy=[]; any v2 write
#   normalizes the whole file). deprecated stays reserved, always false.
#   id = <yyyyMMddTHHmmssZ UTC>-<ROLE>-<4 hex>; the fixed-width ASCII name
#   keeps lexicographic order == chronological order.
#
# Role whitelist mirrors start-role.ps1's -Role ValidateSet (single source;
# drift is a QA checklist item — runtime cross-script parsing would be a
# fragile coupling, design decision #6). Targeting is record-then-own only:
# add stamps roles = [-By], target extends an entry role by role; the former
# ALL sentinel is gone (no natural producer left — archive decision #4).
#
# Exit codes (rdd-flow layering): 0 success / 1 invocation & validation
# error / 2 environment error / 3 data corruption (half-broken entry named
# in the error — a query-type store must not silently skip rows). Every
# outcome emits exactly one JSON envelope on stdout: {success,data} or
# {success:false,error:{code,message}}. Messages are deliberately pure
# ASCII: this CLI exists to harden the Windows encoding chain, so it never
# depends on its own BOM surviving (docs/code-quality.md section 6.1).

[CmdletBinding()]
param(
    [string]$Command,
    [string]$By,
    [string]$Title,
    [string]$Problem,
    [string]$Avoidance,
    [string]$File,
    [string]$Role,
    [string]$Id,
    [string]$Note,
    [string]$Pin,
    [switch]$SawTip,
    [switch]$All
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Resolve-RepoRoot - project-root location chain (git-optional; protocol source:
# rdd-engine/references/engine-location.md, "Project-root location chain"). The
# explicit RDD_PROJECT_ROOT override (link 1) is also what lets the test suite
# point the store at a throwaway root.
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

# === Constants (zero config: embedded whitelist, fixed path conventions) ===
$TipSchema = "rdd-tip/2"
$LegacyTipSchema = "rdd-tip/1"
$RecorderRoles = @("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE", "PLANNER", "AUDITOR")
$TipStatuses = @("latent", "active", "pinned", "superseded")

# Shared recall machinery (the SAME single source explore.ps1 dot-sources —
# registry, recallers, config merge, F7 fusion, insertion sort). Loaded
# softly: a missing/broken library only disables near-duplicate candidates
# (a prompt-layer gain) — every other command runs untouched, and add never
# fails because dedup did.
$script:RecallSharedLoaded = $false
$recallSharedPath = Join-Path $PSScriptRoot "lib\recall-shared.ps1"
if (Test-Path -LiteralPath $recallSharedPath -PathType Leaf) {
    . $recallSharedPath
    $script:RecallSharedLoaded = $true
}

# === JSON envelope ===

function ConvertTo-PortableJson {
    param($Object, [int]$Depth = 6)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-ResultEnvelope {
    param($Data)
    [Console]::Out.WriteLine((ConvertTo-PortableJson @{ success = $true; data = $Data }))
    exit 0
}

function Write-ErrorResult {
    param([string]$Code, [string]$Message, [int]$ExitCode = 1)
    [Console]::Out.WriteLine((ConvertTo-PortableJson @{ success = $false; error = @{ code = $Code; message = $Message } } -Depth 3))
    exit $ExitCode
}

# === Paths ===

function Get-TipsEntriesDir { Join-Path $repoRoot ".rdd/tips/entries" }
function Get-TipsConfigPath { Join-Path $repoRoot ".rdd/tips/search-config.json" }
function Get-TipsVectorsPath { Join-Path $repoRoot ".rdd/tips/vectors.json" }

function ConvertTo-RepoRelativePath {
    # Read-reachable forward-slash pointer (start-role B2 consumes it). Both
    # sides normalized first: git rev-parse returns forward slashes on Windows,
    # which would otherwise make the prefix check miss.
    param([string]$AbsPath)
    $full = [System.IO.Path]::GetFullPath($AbsPath)
    $root = [System.IO.Path]::GetFullPath($repoRoot.TrimEnd("\", "/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).Replace("\", "/")
    }
    return $full.Replace("\", "/")
}

# === Role helpers ===

function Test-AsciiOnly {
    # Mechanical inline-channel guard: garbled CJK arrives as legal Unicode
    # that content validation cannot detect, so non-ASCII dies right here.
    param([string]$Value)
    return ($Value -notmatch '[^\x00-\x7F]')
}

function Get-CanonicalRole {
    # Case-insensitive whitelist lookup -> canonical spelling. Shells and
    # agents occasionally lowercase role names; rejecting would force a
    # pointless retry while the intent is unambiguous.
    param([string]$Value, [array]$Whitelist)
    foreach ($candidate in $Whitelist) {
        if ($Value -eq $candidate) { return $candidate }
    }
    return $null
}

# === add: content channels ===

function Get-InlineTipContent {
    # Inline channel: pure-ASCII shortcut path (engine CLI house style). Each
    # field is checked missing-first, then mechanically ASCII-guarded.
    $fields = @(
        @{ name = "Title";     value = $Title;     missing = "MISSING_TITLE" },
        @{ name = "Problem";   value = $Problem;   missing = "MISSING_PROBLEM" },
        @{ name = "Avoidance"; value = $Avoidance; missing = "MISSING_AVOIDANCE" }
    )
    $content = @{}
    foreach ($field in $fields) {
        if ([string]::IsNullOrWhiteSpace($field.value)) {
            Write-ErrorResult $field.missing ("-{0} is required for add (inline channel; or pass -File <payload.json>)" -f $field.name) 1
        }
        if (-not (Test-AsciiOnly $field.value)) {
            Write-ErrorResult "NON_ASCII_INLINE" ("-{0} carries non-ASCII characters: the cmd arg chain garbles them beyond detection (docs/code-quality.md section 6.4). Write a UTF-8 payload file and pass -File instead." -f $field.name) 1
        }
        $content[$field.name.ToLowerInvariant()] = $field.value.Trim()
    }
    return $content
}

function Read-TipPayload {
    # -File channel: the only legitimate path for non-ASCII content (explicit
    # UTF-8 read; the payload stays in-process as strings from here on).
    param([string]$PayloadPath)
    $absPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PayloadPath)
    if (-not (Test-Path -LiteralPath $absPath -PathType Leaf)) {
        Write-ErrorResult "PAYLOAD_NOT_FOUND" "payload file not found: $PayloadPath (resolved: $absPath)" 1
    }
    $payload = $null
    try {
        $raw = [System.IO.File]::ReadAllText($absPath, [System.Text.Encoding]::UTF8)
        $payload = $raw | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "PAYLOAD_INVALID" "payload is not valid JSON: $($_.Exception.Message)" 1
    }
    if ($null -eq $payload) {
        Write-ErrorResult "PAYLOAD_INVALID" "payload must be a JSON object with title, problem, avoidance" 1
    }
    foreach ($key in @($payload.PSObject.Properties.Name)) {
        if ($key -eq "roles") {
            Write-ErrorResult "PAYLOAD_INVALID" "payload key 'roles' is no longer accepted: add stamps roles = [-By] (record-then-own); use target -Id <id> -By <ROLE> to extend an existing entry" 1
        }
        if ($key -notin @("title", "problem", "avoidance")) {
            Write-ErrorResult "PAYLOAD_INVALID" "unknown payload key '$key' (allowed: title, problem, avoidance; roles/id/schema/recordedBy/recordedAt/deprecated are CLI-stamped)" 1
        }
    }
    $content = @{}
    foreach ($field in @("title", "problem", "avoidance")) {
        $prop = $payload.PSObject.Properties[$field]
        if ($null -eq $prop -or -not ($prop.Value -is [string]) -or [string]::IsNullOrWhiteSpace($prop.Value)) {
            Write-ErrorResult "PAYLOAD_INVALID" "payload field '$field' must be a non-empty string" 1
        }
        $content[$field] = $prop.Value.Trim()
    }
    return $content
}

# === add: persistence ===

function New-TipId {
    # Fixed-width UTC stamp keeps filename lexicographic order == chronological
    # order; the 4-hex suffix plus the exists-check absorbs same-second
    # collisions (design risk register).
    param([string]$RecorderRole)
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $suffix = -join ((1..4) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })
    return ("{0}-{1}-{2}" -f $stamp, $RecorderRole, $suffix)
}

function Write-TipEntry {
    # Persist one validated tip -> @{ id; path; entry }, or exit ENV_ERROR 2.
    param([hashtable]$Content, [array]$TargetRoles, [string]$Recorder)
    $entriesDir = Get-TipsEntriesDir
    $tipId = $null
    $entryPath = $null
    $entry = $null
    try {
        if (-not (Test-Path -LiteralPath $entriesDir -PathType Container)) {
            New-Item -ItemType Directory -Path $entriesDir -Force | Out-Null
        }
        do {
            $tipId = New-TipId $Recorder
            $entryPath = Join-Path $entriesDir ($tipId + ".json")
        } while (Test-Path -LiteralPath $entryPath)
        $entry = @{
            schema     = $TipSchema
            id         = $tipId
            title      = $Content["title"]
            problem    = $Content["problem"]
            avoidance  = $Content["avoidance"]
            roles      = @($TargetRoles)
            recordedBy = $Recorder
            recordedAt = (Get-Date).ToUniversalTime().ToString("o")
            deprecated = $false
            status     = "latent"
            count      = 1
            collidedBy = @()
        }
        [System.IO.File]::WriteAllText($entryPath, (ConvertTo-PortableJson $entry -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-ErrorResult "ENV_ERROR" "failed to persist the tip entry: $($_.Exception.Message)" 2
    }
    return @{ id = $tipId; path = $entryPath; entry = $entry }
}

function Get-AllTipEntryViews {
    # Every stored entry as a normalized reader view (fail-loud on corrupt
    # rows via Read-TipEntryFile); empty store -> @().
    $entriesDir = Get-TipsEntriesDir
    $views = @()
    if (Test-Path -LiteralPath $entriesDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $entriesDir -File -Filter "*.json")) {
            $views += (Read-TipEntryFile $file.FullName)
        }
    }
    return $views
}

function ConvertTo-RecallDoc {
    # Tips -> recaller doc adapter (the ONLY shape bridge): key=id (unique
    # scores-table key; timestamp tokens never enter the query), tags=roles
    # (role words join the lexical corpus), brief=title+problem+avoidance
    # (the retrieval body — the recaller-side F1 concatenates these slots).
    param([hashtable]$View)
    return @{
        key   = $View.id
        tags  = @($View.roles)
        brief = ($View.title + "`n" + $View.problem + "`n" + $View.avoidance)
        path  = $View.path
    }
}

function Get-TipCandidates {
    # Near-duplicate recall for a freshly recorded tip: the SHARED pipeline
    # (lib/recall-shared.ps1) over every other non-superseded entry, via the
    # ConvertTo-RecallDoc adapter. The pipeline yields a relative order
    # (score DESC -> id ordinal ASC); adjudication — same root cause or not
    # — belongs to the recording agent, never to the scores. ANY failure
    # (missing library included) degrades to @() + a stderr warning:
    # candidates are a prompt-layer gain, add itself never fails here.
    param([hashtable]$NewEntry, [array]$Others)

    if (-not $script:RecallSharedLoaded) {
        [Console]::Error.WriteLine("tips: recall-shared library not loaded - candidates disabled (recording unaffected)")
        return @()
    }
    $corpus = @($Others | Where-Object { $_.status -ne "superseded" })
    if ($corpus.Count -eq 0) { return @() }
    try {
        $docs = @($corpus | ForEach-Object { ConvertTo-RecallDoc $_ })
        $query = ($NewEntry.title + "`n" + $NewEntry.problem + "`n" + $NewEntry.avoidance)
        $config = Read-RecallConfigFile -Path (Get-TipsConfigPath)
        $recall = Invoke-Recallers -Query $query -Docs $docs -Config $config -VectorsPath (Get-TipsVectorsPath)
        $fusion = Invoke-RRFFusion -QualifiedLists $recall.lists -RrfK ([int]$config.rrfK)
        $byId = @{}
        foreach ($v in $corpus) { $byId[$v.id] = $v }
        $ranked = @()
        foreach ($entryId in @($fusion.scores.Keys)) {
            $v = $byId[[string]$entryId]
            if ($null -eq $v) { continue }
            $ranked += @{
                id         = $v.id
                title      = $v.title
                score      = [math]::Round([double]$fusion.scores[$entryId], 6)
                status     = $v.status
                count      = $v.count
                recalledBy = @($fusion.recalledBy[$entryId])
            }
        }
        $sorted = Invoke-InsertionSort -Items ([object[]]$ranked) -Compare {
            param($Cur, $Other)
            $diff = [double]$Cur.score - [double]$Other.score
            if ($diff -gt 0) { return -1 }
            if ($diff -lt 0) { return 1 }
            return [string]::CompareOrdinal([string]$Cur.id, [string]$Other.id)
        }
        $take = @($sorted).Count
        if ($take -gt [int]$config.topK) { $take = [int]$config.topK }
        return @($sorted | Select-Object -First $take)
    }
    catch {
        [Console]::Error.WriteLine("tips: candidate recall failed - candidates skipped for this add (recording unaffected): $($_.Exception.Message)")
        return @()
    }
}

function Invoke-AddTip {
    if ([string]::IsNullOrWhiteSpace($By)) {
        Write-ErrorResult "MISSING_BY" "-By <ROLE> (the recording role) is required for add" 1
    }
    $recorder = Get-CanonicalRole $By $RecorderRoles
    if ($null -eq $recorder) {
        Write-ErrorResult "INVALID_ROLE" "unknown -By role '$By' (valid: $($RecorderRoles -join ', '))" 1
    }
    $fileGiven = -not [string]::IsNullOrWhiteSpace($File)
    $inlineGiven = -not ([string]::IsNullOrWhiteSpace($Title) -and [string]::IsNullOrWhiteSpace($Problem) -and [string]::IsNullOrWhiteSpace($Avoidance))
    if ($fileGiven -and $inlineGiven) {
        Write-ErrorResult "DUAL_CHANNEL" "inline params (-Title/-Problem/-Avoidance) and -File are mutually exclusive; pass the content through exactly one channel" 1
    }
    if ($fileGiven) { $content = Read-TipPayload $File }
    else { $content = Get-InlineTipContent }
    # Record-then-own: the recorder IS the target — no roles input anywhere.
    $stored = Write-TipEntry -Content $content -TargetRoles @($recorder) -Recorder $recorder
    $others = @(Get-AllTipEntryViews | Where-Object { $_.id -ne $stored.id })
    $candidates = Get-TipCandidates -NewEntry $stored.entry -Others $others
    Write-ResultEnvelope @{
        recorded   = $true
        id         = $stored.id
        path       = (ConvertTo-RepoRelativePath $stored.path)
        title      = $stored.entry.title
        roles      = @($recorder)
        recordedBy = $recorder
        recordedAt = $stored.entry.recordedAt
        status     = "latent"
        count      = 1
        candidates = @($candidates)
    }
}

# === target: organic spread ===

function Write-TipEntryFile {
    # Whole-entry rewrite at a known path (UTF-8 no BOM, same canonical form
    # add writes; Depth 5 covers the collidedBy[{role,at,sawTip}] nesting) —
    # the persistence leg of target and every lifecycle transition.
    param([string]$EntryPath, [hashtable]$Entry)
    try {
        [System.IO.File]::WriteAllText($EntryPath, (ConvertTo-PortableJson $Entry -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-ErrorResult "ENV_ERROR" "failed to rewrite the tip entry: $($_.Exception.Message)" 2
    }
    return $Entry
}

function Invoke-TargetTip {
    # Attach $By (the CURRENT role, operator semantics reused from add) to an
    # existing entry — organic spread of a matching tip instead of a re-record
    # (2026-10-06 user ruling). Chain: MISSING_ID -> MISSING_BY ->
    # INVALID_ROLE -> TIP_NOT_FOUND -> CORRUPT_ENTRY (via Read-TipEntryFile,
    # exit 3). Idempotent: an already-member role echoes success WITHOUT
    # touching the file.
    if ([string]::IsNullOrWhiteSpace($Id)) {
        Write-ErrorResult "MISSING_ID" "-Id <tip-id> is required for target (the entry to extend, e.g. 20261006T100831Z-QA-4183)" 1
    }
    if ([string]::IsNullOrWhiteSpace($By)) {
        Write-ErrorResult "MISSING_BY" "-By <ROLE> (the role attaching itself) is required for target" 1
    }
    $role = Get-CanonicalRole $By $RecorderRoles
    if ($null -eq $role) {
        Write-ErrorResult "INVALID_ROLE" "unknown -By role '$By' (valid: $($RecorderRoles -join ', '))" 1
    }
    $tipId = $Id.Trim()
    $entryPath = Join-Path (Get-TipsEntriesDir) ($tipId + ".json")
    # Path-shape guard: a store entry is "<id>.json" inside the entries dir;
    # an $Id smuggling separators (traversal) can never be one — same
    # TIP_NOT_FOUND verdict, nothing is probed outside the store.
    $leaf = [System.IO.Path]::GetFileName($entryPath)
    if ($leaf -ne ($tipId + ".json") -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        Write-ErrorResult "TIP_NOT_FOUND" "no tip entry with id '$tipId' in the store" 1
    }
    $stored = Read-TipEntryFile $entryPath
    $newRoles = @($stored.roles)
    if ($newRoles -notcontains $role) {
        $newRoles += $role
        # ConvertTo-StoredEntry normalizes the file to the full v2 form
        # (a legacy rdd-tip/1 entry touched by target upgrades in place).
        # $null capture: the writer's return would otherwise leak into the
        # pipeline ahead of the JSON envelope (uncaptured output is emitted).
        $stored.roles = $newRoles
        $null = Write-TipEntryFile -EntryPath $entryPath -Entry (ConvertTo-StoredEntry $stored)
        $appended = $true
    }
    else {
        $appended = $false
    }
    Write-ResultEnvelope @{
        targeted   = $true
        appended   = $appended
        id         = $stored.id
        role       = $role
        roles      = $newRoles
        title      = $stored.title
        path       = $stored.path
        recordedBy = $stored.recordedBy
        status     = $stored.status
        count      = $stored.count
    }
}

# === collide / pin / unpin / supersede: lifecycle transitions (v2) =========

function Resolve-TipAndRole {
    # Shared preamble for the -Id/-By lifecycle commands: MISSING_ID ->
    # MISSING_BY -> INVALID_ROLE -> TIP_NOT_FOUND -> CORRUPT_ENTRY (via
    # Read-TipEntryFile, exit 3). Same path-shape guard as target: an $Id
    # smuggling separators can never be a store entry.
    # -> @{ view; entryPath; role }.
    if ([string]::IsNullOrWhiteSpace($Id)) {
        Write-ErrorResult "MISSING_ID" "-Id <tip-id> is required (the entry to touch, e.g. 20261006T100831Z-QA-4183)" 1
    }
    if ([string]::IsNullOrWhiteSpace($By)) {
        Write-ErrorResult "MISSING_BY" "-By <ROLE> (the acting role) is required" 1
    }
    $role = Get-CanonicalRole $By $RecorderRoles
    if ($null -eq $role) {
        Write-ErrorResult "INVALID_ROLE" "unknown -By role '$By' (valid: $($RecorderRoles -join ', '))" 1
    }
    $tipId = $Id.Trim()
    $entryPath = Join-Path (Get-TipsEntriesDir) ($tipId + ".json")
    $leaf = [System.IO.Path]::GetFileName($entryPath)
    if ($leaf -ne ($tipId + ".json") -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        Write-ErrorResult "TIP_NOT_FOUND" "no tip entry with id '$tipId' in the store" 1
    }
    $view = Read-TipEntryFile $entryPath
    return @{ view = $view; entryPath = $entryPath; role = $role }
}

function Invoke-CollideTip {
    # One independent re-hit of the same pit: count++, collidedBy stamp
    # {role, at, sawTip}; latent auto-promotes to active at count>=2. The
    # colliding role need not be a member of roles (cross-role hits are
    # valid evidence — organic spread stays target's job).
    $r = Resolve-TipAndRole
    $view = $r.view
    $view.count = [int]$view.count + 1
    $view.collidedBy = @($view.collidedBy) + @{
        role   = $r.role
        at     = (Get-Date).ToUniversalTime().ToString("o")
        sawTip = [bool]$SawTip
    }
    $promoted = $false
    if ($view.status -eq "latent" -and $view.count -ge 2) { $view.status = "active"; $promoted = $true }
    $null = Write-TipEntryFile -EntryPath $r.entryPath -Entry (ConvertTo-StoredEntry $view)
    Write-ResultEnvelope @{
        collided = $true
        id       = $view.id
        title    = $view.title
        count    = $view.count
        status   = $view.status
        promoted = $promoted
        role     = $r.role
        sawTip   = [bool]$SawTip
        path     = $view.path
    }
}

function Invoke-PinTip {
    # Explicit escape valve for rare-but-expensive lessons. Idempotent; a
    # superseded entry can never be pinned (supersede is terminal).
    $r = Resolve-TipAndRole
    $view = $r.view
    if ($view.status -eq "superseded") {
        Write-ErrorResult "INVALID_STATE" "superseded entries cannot be pinned (supersede is terminal)" 1
    }
    if ($view.status -eq "pinned") {
        Write-ResultEnvelope @{ pinned = $true; already = $true; id = $view.id; title = $view.title; status = $view.status; count = $view.count; path = $view.path }
    }
    $view.status = "pinned"
    $view["pinnedBy"] = $r.role
    $view["pinnedAt"] = (Get-Date).ToUniversalTime().ToString("o")
    $null = Write-TipEntryFile -EntryPath $r.entryPath -Entry (ConvertTo-StoredEntry $view)
    Write-ResultEnvelope @{ pinned = $true; already = $false; id = $view.id; title = $view.title; status = $view.status; count = $view.count; pinnedBy = $r.role; path = $view.path }
}

function Invoke-UnpinTip {
    # Drop the pin, recompute from evidence: count>=2 -> active, else
    # latent. Pinned-only (fail-loud otherwise).
    $r = Resolve-TipAndRole
    $view = $r.view
    if ($view.status -ne "pinned") {
        Write-ErrorResult "INVALID_STATE" "entry status is '$($view.status)', not pinned - nothing to unpin" 1
    }
    $view.status = "active"
    if ([int]$view.count -lt 2) { $view.status = "latent" }
    $view.Remove("pinnedBy")
    $view.Remove("pinnedAt")
    $null = Write-TipEntryFile -EntryPath $r.entryPath -Entry (ConvertTo-StoredEntry $view)
    Write-ResultEnvelope @{ unpinned = $true; id = $view.id; title = $view.title; status = $view.status; count = $view.count; path = $view.path }
}

function Invoke-SupersedeTip {
    # Fixed-into-tool: the tool itself now guards this pit. Terminal — the
    # entry leaves the default list AND the candidates corpus. -Note rides
    # the inline channel (pure ASCII, same NON_ASCII_INLINE guard as add).
    if (-not [string]::IsNullOrWhiteSpace($Note) -and -not (Test-AsciiOnly $Note)) {
        Write-ErrorResult "NON_ASCII_INLINE" "-Note carries non-ASCII characters: the cmd arg chain garbles them beyond detection (docs/code-quality.md section 6.4)" 1
    }
    $r = Resolve-TipAndRole
    $view = $r.view
    if ($view.status -eq "superseded") {
        Write-ErrorResult "INVALID_STATE" "entry is already superseded (terminal)" 1
    }
    $view.status = "superseded"
    $view["supersededBy"] = $r.role
    $view["supersededAt"] = (Get-Date).ToUniversalTime().ToString("o")
    if (-not [string]::IsNullOrWhiteSpace($Note)) { $view["note"] = $Note.Trim() }
    $null = Write-TipEntryFile -EntryPath $r.entryPath -Entry (ConvertTo-StoredEntry $view)
    Write-ResultEnvelope @{
        superseded   = $true
        id           = $view.id
        title        = $view.title
        status       = $view.status
        count        = $view.count
        supersededBy = $r.role
        note         = $Note
        path         = $view.path
    }
}

function Invoke-MigrateTips {
    # One-shot (idempotent) legacy-store migration to the v2 lifecycle.
    # Two passes on purpose: collect + validate FIRST (a -Pin id missing
    # from the store fails loud before ANY write — a typo must never
    # silently demote a proven tip to latent), then rewrite every
    # rdd-tip/1 file in full v2 form: -Pin ids -> pinned, the rest ->
    # latent. v2 files are skipped untouched.
    if ([string]::IsNullOrWhiteSpace($By)) {
        Write-ErrorResult "MISSING_BY" "-By <ROLE> (the acting role, stamped as pinnedBy) is required" 1
    }
    $role = Get-CanonicalRole $By $RecorderRoles
    if ($null -eq $role) {
        Write-ErrorResult "INVALID_ROLE" "unknown -By role '$By' (valid: $($RecorderRoles -join ', '))" 1
    }
    $pinIds = @()
    if (-not [string]::IsNullOrWhiteSpace($Pin)) {
        $pinIds = @($Pin -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
    }
    $entriesDir = Get-TipsEntriesDir
    $files = @(if (Test-Path -LiteralPath $entriesDir -PathType Container) { Get-ChildItem -LiteralPath $entriesDir -File -Filter "*.json" })
    $knownIds = @{}; $legacy = @()
    foreach ($file in $files) {
        $raw = $null
        try { $raw = ([System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
        if ($null -ne $raw -and $raw.PSObject.Properties["id"]) { $knownIds[[string]$raw.id] = $true }
        if ($null -eq $raw -or [string]$raw.schema -eq $LegacyTipSchema) { $legacy += $file.FullName }
    }
    foreach ($pinId in $pinIds) {
        if (-not $knownIds.ContainsKey($pinId)) { Write-ErrorResult "MIGRATE_PIN_UNKNOWN" "-Pin id '$pinId' not found in the store (typo? nothing was migrated)" 1 }
    }
    $pinned = @(); $latented = @()
    foreach ($entryPath in $legacy) {
        $view = Read-TipEntryFile $entryPath
        if ($pinIds -contains $view.id) {
            $view.status = "pinned"
            $view["pinnedBy"] = $role
            $view["pinnedAt"] = (Get-Date).ToUniversalTime().ToString("o")
            $pinned += $view.id
        }
        else {
            $view.status = "latent"
            $latented += $view.id
        }
        $null = Write-TipEntryFile -EntryPath $entryPath -Entry (ConvertTo-StoredEntry $view)
    }
    Write-ResultEnvelope @{
        migrated  = $legacy.Count
        pinnedIds = $pinned
        latentIds = $latented
        skippedV2 = ($files.Count - $legacy.Count)
    }
}

# === list: read face ===

function Get-EntryLifecycleShapeError {
    # -> $null when the optional v2 lifecycle fields (absent on legacy
    # rdd-tip/1 files) are either missing or well-formed, else the reason.
    param($Entry)
    $statusProp = $Entry.PSObject.Properties["status"]
    if ($null -ne $statusProp -and $TipStatuses -notcontains $statusProp.Value) {
        return ("invalid status '{0}' (valid: {1})" -f [string]$statusProp.Value, ($TipStatuses -join ", "))
    }
    $countProp = $Entry.PSObject.Properties["count"]
    if ($null -ne $countProp -and (-not ($countProp.Value -is [int]) -or $countProp.Value -lt 1)) {
        return "count must be an integer >= 1"
    }
    $collidedProp = $Entry.PSObject.Properties["collidedBy"]
    if ($null -ne $collidedProp) {
        if ($collidedProp.Value -is [string]) { return "collidedBy must be an array" }
        foreach ($hit in @($collidedProp.Value)) {
            $hitRole = $hit.PSObject.Properties["role"]
            $hitAt = $hit.PSObject.Properties["at"]
            $hitSaw = $hit.PSObject.Properties["sawTip"]
            if ($null -eq $hitRole -or $RecorderRoles -notcontains $hitRole.Value) { return "collidedBy[].role must be a whitelisted role" }
            if ($null -eq $hitAt -or -not ($hitAt.Value -is [string]) -or [string]::IsNullOrWhiteSpace($hitAt.Value)) { return "collidedBy[].at must be a non-empty string" }
            if ($null -eq $hitSaw -or -not ($hitSaw.Value -is [bool])) { return "collidedBy[].sawTip must be a boolean" }
        }
    }
    return $null
}

function Get-EntryShapeError {
    # -> $null when the parsed entry fully matches rdd-tip/2 (or a legacy
    # rdd-tip/1 file), else the reason. Stored entries are CLI-written
    # canonical data: any deviation (missing field, wrong type, unknown
    # role value) counts as corruption.
    param($Entry)
    foreach ($field in @("schema", "id", "title", "problem", "avoidance", "recordedBy", "recordedAt")) {
        $prop = $Entry.PSObject.Properties[$field]
        if ($null -eq $prop -or -not ($prop.Value -is [string]) -or [string]::IsNullOrWhiteSpace($prop.Value)) {
            return ("field '{0}' must be a non-empty string" -f $field)
        }
    }
    if (@($TipSchema, $LegacyTipSchema) -notcontains [string]$Entry.schema) {
        return ("unknown schema '{0}' (expected {1} or legacy {2})" -f [string]$Entry.schema, $TipSchema, $LegacyTipSchema)
    }
    $rolesProp = $Entry.PSObject.Properties["roles"]
    if ($null -eq $rolesProp -or $rolesProp.Value -is [string]) { return "roles must be an array of role names" }
    $roles = @($rolesProp.Value)
    if ($roles.Count -eq 0) { return "roles must contain at least one role" }
    foreach ($role in $roles) {
        if (-not ($role -is [string]) -or $RecorderRoles -notcontains $role) {
            return ("invalid role value '{0}' (valid: {1})" -f [string]$role, ($RecorderRoles -join ", "))
        }
    }
    $deprecatedProp = $Entry.PSObject.Properties["deprecated"]
    if ($null -ne $deprecatedProp -and -not ($deprecatedProp.Value -is [bool])) { return "deprecated must be a boolean" }
    $lifecycleError = Get-EntryLifecycleShapeError $Entry
    if ($null -ne $lifecycleError) { return $lifecycleError }
    return $null
}

function Read-TipEntryFile {
    # Half-broken entries abort the whole list run (CORRUPT_ENTRY, exit 3,
    # file named): a query-type store must never silently skip rows, and the
    # named file is the handle a human needs to repair it.
    param([string]$EntryPath)
    $fileName = Split-Path -Leaf $EntryPath
    $entry = $null
    try {
        $raw = [System.IO.File]::ReadAllText($EntryPath, [System.Text.Encoding]::UTF8)
        $entry = $raw | ConvertFrom-Json
    }
    catch {
        Write-ErrorResult "CORRUPT_ENTRY" ("{0}: unparseable JSON ({1})" -f $fileName, $_.Exception.Message) 3
    }
    if ($null -eq $entry) { Write-ErrorResult "CORRUPT_ENTRY" "$fileName`: empty or null payload" 3 }
    $shapeError = Get-EntryShapeError $entry
    if ($null -ne $shapeError) { Write-ErrorResult "CORRUPT_ENTRY" ("{0}: {1}" -f $fileName, $shapeError) 3 }
    $deprecated = $false
    if ($null -ne $entry.PSObject.Properties["deprecated"]) { $deprecated = [bool]$entry.deprecated }
    # Lifecycle normalization: legacy rdd-tip/1 files carry no lifecycle
    # fields -> the pre-migration compatibility view (status=active,
    # count=1, no collisions) keeps every consumer on its v1 behavior until
    # the migration re-stamps the store.
    $status = "active"
    if ($null -ne $entry.PSObject.Properties["status"]) { $status = [string]$entry.status }
    $count = 1
    if ($null -ne $entry.PSObject.Properties["count"]) { $count = [int]$entry.count }
    $collidedBy = @()
    if ($null -ne $entry.PSObject.Properties["collidedBy"]) {
        $collidedBy = @($entry.collidedBy | ForEach-Object {
            @{ role = [string]$_.role; at = [string]$_.at; sawTip = [bool]$_.sawTip }
        })
    }
    $view = @{
        id         = [string]$entry.id
        title      = [string]$entry.title
        problem    = [string]$entry.problem
        avoidance  = [string]$entry.avoidance
        roles      = @($entry.roles)
        recordedBy = [string]$entry.recordedBy
        recordedAt = [string]$entry.recordedAt
        deprecated = $deprecated
        status     = $status
        count      = $count
        collidedBy = $collidedBy
        path       = (ConvertTo-RepoRelativePath $EntryPath)
    }
    foreach ($stamp in @("pinnedBy", "pinnedAt", "supersededBy", "supersededAt", "note")) {
        $stampProp = $entry.PSObject.Properties[$stamp]
        if ($null -ne $stampProp -and -not [string]::IsNullOrWhiteSpace([string]$stampProp.Value)) {
            $view[$stamp] = [string]$stampProp.Value
        }
    }
    return $view
}

function ConvertTo-StoredEntry {
    # Canonical on-disk form from a reader view: full v2 fields, explicit
    # lifecycle (rewriting a legacy file through this normalizer upgrades
    # it to v2 in place). Optional stamps ride along only when present.
    param([hashtable]$View)
    $stored = @{
        schema     = $TipSchema
        id         = $View.id
        title      = $View.title
        problem    = $View.problem
        avoidance  = $View.avoidance
        roles      = @($View.roles)
        recordedBy = $View.recordedBy
        recordedAt = $View.recordedAt
        deprecated = $false
        status     = $View.status
        count      = $View.count
        collidedBy = @($View.collidedBy)
    }
    foreach ($stamp in @("pinnedBy", "pinnedAt", "supersededBy", "supersededAt", "note")) {
        if ($View.ContainsKey($stamp)) { $stored[$stamp] = $View[$stamp] }
    }
    return $stored
}

function Invoke-ListTips {
    $filterRole = $null
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $filterRole = Get-CanonicalRole $Role $RecorderRoles
        if ($null -eq $filterRole) {
            Write-ErrorResult "INVALID_ROLE" "unknown -Role filter '$Role' (valid: $($RecorderRoles -join ', '))" 1
        }
    }
    $items = @(Get-AllTipEntryViews)
    if (-not $All) {
        # Superseded = fixed-into-tool: out of the default view; -All is the
        # audit/repair face.
        $items = @($items | Where-Object { $_.status -ne "superseded" })
    }
    if ($null -ne $filterRole) {
        $items = @($items | Where-Object { $_.roles -contains $filterRole })
    }
    # Expression blocks, not -Property names: entries are hashtables and
    # Sort-Object cannot key off dictionary "properties" (code-metrics
    # lesson). count DESC leads (collision evidence outranks recency); the
    # recordedAt/id tie-breaks keep the all-count-1 order identical to the
    # v1 newest-first contract (pre-migration regression anchor).
    $ordered = @($items | Sort-Object -Descending -Property @{ Expression = { $_.count } }, @{ Expression = { $_.recordedAt } }, @{ Expression = { $_.id } })
    Write-ResultEnvelope @{ count = $ordered.Count; role = $filterRole; all = [bool]$All; entries = $ordered }
}

# === Dispatch ===

try {
    $validCommands = @("add", "list", "target", "collide", "pin", "unpin", "supersede", "migrate")
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-ErrorResult "MISSING_COMMAND" "-Command is required. Valid values: add, list, target, collide, pin, unpin, supersede, migrate" 1
    }
    if ($Command -notin $validCommands) {
        Write-ErrorResult "INVALID_COMMAND" "unknown command '$Command' (valid: add, list, target, collide, pin, unpin, supersede, migrate)" 1
    }
    if ($Command -eq "add") { Invoke-AddTip }
    elseif ($Command -eq "target") { Invoke-TargetTip }
    elseif ($Command -eq "collide") { Invoke-CollideTip }
    elseif ($Command -eq "pin") { Invoke-PinTip }
    elseif ($Command -eq "unpin") { Invoke-UnpinTip }
    elseif ($Command -eq "supersede") { Invoke-SupersedeTip }
    elseif ($Command -eq "migrate") { Invoke-MigrateTips }
    else { Invoke-ListTips }
}
catch {
    # Layer 2: environment errors (IO failure, unwritable store, ...). The
    # validation paths above exit before anything can throw.
    Write-ErrorResult "ENV_ERROR" "$($_.Exception.Message)" 2
}

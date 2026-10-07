# tips.ps1 — project-level role tips record/query CLI (engine 5th CLI class)
#
# Persists reusable lessons (pitfalls, traps, conventions) that any role
# session hits as structured tip entries under .rdd/tips/entries/ — one JSON
# file per entry (schema rdd-tip/1, UTF-8 no BOM, git-tracked; unique-ID
# filenames are immune to parallel / cross-clone merge conflicts). A fully
# self-contained leaf script, decoupled from task.json routing by design
# (archive 2026-10-06-role-tips-mechanism): it never reads or writes
# task.json and never touches the exploration zone.
#
# Interface:
#   tips.cmd -Command add -By <ROLE> [-Title -Problem -Avoidance
#                                     | -File <payload.json>]
#   tips.cmd -Command list [-Role <R>]
#   tips.cmd -Command target -Id <tip-id> -By <ROLE>
#
#     add   record one tip. Record-then-own semantics (2026-10-06 user
#           ruling): a new entry is ALWAYS targeted at the recording role
#           (roles = [-By]) — there is no target-role input on either
#           channel. Inline params and -File are mutually exclusive. Inline
#           values must be pure ASCII: the cmd -> powershell arg chain
#           garbles CJK into LEGAL Unicode that no content validator can
#           detect (docs/code-quality.md section 6.4), so the channel itself
#           is rejected mechanically (NON_ASCII_INLINE). Chinese content goes
#           through -File: a UTF-8 payload {title, problem, avoidance},
#           staged e.g. under .rdd/tmp/; unknown keys are rejected (a legacy
#           "roles" key is rejected too — record-then-own owns targeting).
#     list  query entries, newest first, never truncated (start-role B2
#           summaries consume this output; count caps belong to the
#           consumer). -Role R matches entries whose roles contain R; no
#           filter = every entry; empty store is count=0, not an error.
#     target organic spread: attach -By (the CURRENT role) to an existing
#           entry's roles — reuse a matching tip instead of re-recording it.
#           Idempotent: an already-member role succeeds WITHOUT a rewrite.
#
# Entry schema (rdd-tip/1):
#   {schema, id, title, problem, avoidance, roles[], recordedBy, recordedAt,
#    deprecated:false} — deprecated is reserved, always false in v1.
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
    [string]$Id
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
$TipSchema = "rdd-tip/1"
$RecorderRoles = @("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE", "PLANNER", "AUDITOR")

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
        }
        [System.IO.File]::WriteAllText($entryPath, (ConvertTo-PortableJson $entry -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-ErrorResult "ENV_ERROR" "failed to persist the tip entry: $($_.Exception.Message)" 2
    }
    return @{ id = $tipId; path = $entryPath; entry = $entry }
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
    Write-ResultEnvelope @{
        recorded   = $true
        id         = $stored.id
        path       = (ConvertTo-RepoRelativePath $stored.path)
        title      = $stored.entry.title
        roles      = @($recorder)
        recordedBy = $recorder
        recordedAt = $stored.entry.recordedAt
    }
}

# === target: organic spread ===

function Write-TipEntryFile {
    # Whole-entry rewrite at a known path (UTF-8 no BOM, same canonical form
    # add writes) — target's persistence leg. -> the written entry.
    param([string]$EntryPath, [hashtable]$Entry)
    try {
        [System.IO.File]::WriteAllText($EntryPath, (ConvertTo-PortableJson $Entry -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
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
        # $null capture: the writer's return would otherwise leak into the
        # pipeline ahead of the JSON envelope (uncaptured output is emitted).
        $null = Write-TipEntryFile -EntryPath $entryPath -Entry @{
            schema     = $TipSchema
            id         = $stored.id
            title      = $stored.title
            problem    = $stored.problem
            avoidance  = $stored.avoidance
            roles      = $newRoles
            recordedBy = $stored.recordedBy
            recordedAt = $stored.recordedAt
            deprecated = $stored.deprecated
        }
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
    }
}

# === list: read face ===

function Get-EntryShapeError {
    # -> $null when the parsed entry fully matches rdd-tip/1, else the reason.
    # Stored entries are CLI-written canonical data: any deviation (missing
    # field, wrong type, unknown role value) counts as corruption.
    param($Entry)
    foreach ($field in @("schema", "id", "title", "problem", "avoidance", "recordedBy", "recordedAt")) {
        $prop = $Entry.PSObject.Properties[$field]
        if ($null -eq $prop -or -not ($prop.Value -is [string]) -or [string]::IsNullOrWhiteSpace($prop.Value)) {
            return ("field '{0}' must be a non-empty string" -f $field)
        }
    }
    if ([string]$Entry.schema -ne $TipSchema) {
        return ("unknown schema '{0}' (expected {1})" -f [string]$Entry.schema, $TipSchema)
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
    return @{
        id         = [string]$entry.id
        title      = [string]$entry.title
        problem    = [string]$entry.problem
        avoidance  = [string]$entry.avoidance
        roles      = @($entry.roles)
        recordedBy = [string]$entry.recordedBy
        recordedAt = [string]$entry.recordedAt
        deprecated = $deprecated
        path       = (ConvertTo-RepoRelativePath $EntryPath)
    }
}

function Invoke-ListTips {
    $filterRole = $null
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $filterRole = Get-CanonicalRole $Role $RecorderRoles
        if ($null -eq $filterRole) {
            Write-ErrorResult "INVALID_ROLE" "unknown -Role filter '$Role' (valid: $($RecorderRoles -join ', '))" 1
        }
    }
    $entriesDir = Get-TipsEntriesDir
    $items = @()
    if (Test-Path -LiteralPath $entriesDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $entriesDir -File -Filter "*.json")) {
            $items += (Read-TipEntryFile $file.FullName)
        }
    }
    if ($null -ne $filterRole) {
        $items = @($items | Where-Object { $_.roles -contains $filterRole })
    }
    # Expression blocks, not -Property names: entries are hashtables and
    # Sort-Object cannot key off dictionary "properties" (code-metrics lesson).
    $ordered = @($items | Sort-Object -Descending -Property @{ Expression = { $_.recordedAt } }, @{ Expression = { $_.id } })
    Write-ResultEnvelope @{ count = $ordered.Count; role = $filterRole; entries = $ordered }
}

# === Dispatch ===

try {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-ErrorResult "MISSING_COMMAND" "-Command is required. Valid values: add, list, target" 1
    }
    if ($Command -notin @("add", "list", "target")) {
        Write-ErrorResult "INVALID_COMMAND" "unknown command '$Command' (valid: add, list, target)" 1
    }
    if ($Command -eq "add") { Invoke-AddTip }
    elseif ($Command -eq "target") { Invoke-TargetTip }
    else { Invoke-ListTips }
}
catch {
    # Layer 2: environment errors (IO failure, unwritable store, ...). The
    # validation paths above exit before anything can throw.
    Write-ErrorResult "ENV_ERROR" "$($_.Exception.Message)" 2
}

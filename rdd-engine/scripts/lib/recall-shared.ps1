# recall-shared.ps1 -- shared recall-pipeline library (single source).
#
# Hosts dot-source this file and get, with zero further wiring:
#   - the frozen search-config defaults + fail-soft per-field merge
#     (mirrors of dsh src/cache.ts SEARCH_CONFIG_DEFAULTS -- same values,
#     same key order)
#   - the recaller plugin registry (Register-Recaller) with every
#     scripts/recallers/*.ps1 plugin dot-sourced in filename order
#     (= registration order = F7 accumulation order: lexical before vector)
#   - the generic recaller invocation loop and the F7 RRF fusion
#   - a comparator-driven stable insertion sort (the mechanical core shared
#     by every host-side sorter)
#
# Consumers: scripts/explore.ps1 (exploration search) and scripts/tips.ps1
# (tip near-duplicate candidates). Corpus-agnostic by contract: hosts map
# their entries into doc records (key/tags/brief/path[/origin] -- free-text
# slots; the recallers' F1 composition concatenates key + tags + brief) and
# pass their own tuning-file path / vectors-sidecar path. Everything
# exploration-lifecycle (zone merge, staleness eviction, Top-K views) stays
# in the hosts.
#
# Frozen-contract note (references/exploration-guide.md): this file MOVES
# the frozen pieces (config defaults, F7) out of explore.ps1 without
# changing one value -- dsh/dsh-rdd-explore/tests/search-ranking.mjs is the
# PS/TS consistency regression gate for the extraction. Never fork this
# logic into a host: a copy would become a third mirror to keep in sync.
# If a formula must change, change the frozen table first, then this file
# AND the dsh plugin mirror together.
#
# Scope rules:
#   - here: registry + plugin loading + config merge + recaller invocation
#     + F7 fusion + generic insertion sort (all corpus-agnostic)
#   - NOT here: zone merge / SHA-256 staleness / Top-K result views
#     (exploration lifecycle, host-owned)
#
# Encoding: UTF-8 with BOM (verbatim comments carry em-dashes; the PS 5.1
# ANSI-decode trap applies to BOM-less non-ASCII .ps1).

# === Config: frozen defaults + fail-soft merge (search-config.json) ========
# Defaults are frozen mirrors of dsh src/cache.ts SEARCH_CONFIG_DEFAULTS.

$SearchDefaults = @{
    topK        = 5
    recallDepth = 20
    rrfK        = 60
    recallers   = @{
        lexical = @{
            enabled = $true
            weight  = 1.0
            bm25K1  = 1.2
            bm25B   = 0.75
        }
        vector  = @{
            enabled         = "auto"
            weight          = 1.0
            endpoint        = ""
            model           = ""
            dimensions      = 0
            minCosine       = 0.30
            timeoutSeconds  = 10
        }
    }
}

function Get-SearchConfigValue {
    # Typed, range-checked single-field override; invalid or unknown values
    # silently keep the default (only file-level corruption warns — a tuning
    # file fails soft, unlike the fail-loud index data).
    param($Obj, [string]$Name, $Current, [scriptblock]$Valid)
    if ($null -ne $Obj) {
        $prop = $Obj.PSObject.Properties[$Name]
        if ($null -ne $prop) {
            $v = $prop.Value
            if (& $Valid $v) { return $v }
        }
    }
    return $Current
}

function Get-SearchFieldValidator {
    # Single copy of every field predicate, shared by the section mergers
    # below (semantics identical to the dsh cache.ts pick() validators).
    # An unknown kind yields a never-matching predicate: the tuning file
    # fails soft, like every other config path here.
    param([string]$Kind)
    switch ($Kind) {
        "posInt"    { { param($v) $v -is [int] -and $v -ge 1 } }
        "posNum"    { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -gt 0 } }
        "isEnabled" { { param($v) $v -is [bool] -or ($v -is [string] -and $v -eq "auto") } }
        "isString"  { { param($v) $v -is [string] } }
        "isDim"     { { param($v) $v -is [int] -and $v -ge 0 } }
        "isK1"      { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge 0 } }
        "isB"       { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge 0 -and [double]$v -le 1 } }
        "isCos"     { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge -1 -and [double]$v -le 1 } }
        "isTimeout" { { param($v) ($v -is [int] -or $v -is [double]) -and [double]$v -ge 1 } }
        default     { { param($v) $false } }
    }
}

function Merge-LexicalRecallerConfig {
    param($Section, $Defaults)
    return @{
        enabled = Get-SearchConfigValue $Section "enabled" $Defaults.enabled (Get-SearchFieldValidator "isEnabled")
        weight  = Get-SearchConfigValue $Section "weight"  $Defaults.weight  (Get-SearchFieldValidator "posNum")
        bm25K1  = Get-SearchConfigValue $Section "bm25K1"  $Defaults.bm25K1  (Get-SearchFieldValidator "isK1")
        bm25B   = Get-SearchConfigValue $Section "bm25B"   $Defaults.bm25B   (Get-SearchFieldValidator "isB")
    }
}

function Merge-VectorRecallerConfig {
    param($Section, $Defaults)
    return @{
        enabled        = Get-SearchConfigValue $Section "enabled"        $Defaults.enabled        (Get-SearchFieldValidator "isEnabled")
        weight         = Get-SearchConfigValue $Section "weight"         $Defaults.weight         (Get-SearchFieldValidator "posNum")
        endpoint       = Get-SearchConfigValue $Section "endpoint"       $Defaults.endpoint       (Get-SearchFieldValidator "isString")
        model          = Get-SearchConfigValue $Section "model"          $Defaults.model          (Get-SearchFieldValidator "isString")
        dimensions     = Get-SearchConfigValue $Section "dimensions"     $Defaults.dimensions     (Get-SearchFieldValidator "isDim")
        minCosine      = Get-SearchConfigValue $Section "minCosine"      $Defaults.minCosine      (Get-SearchFieldValidator "isCos")
        timeoutSeconds = Get-SearchConfigValue $Section "timeoutSeconds" $Defaults.timeoutSeconds (Get-SearchFieldValidator "isTimeout")
    }
}

function Read-RecallConfigFile {
    # Generic tuning-file reader (the former inline explore.ps1
    # Read-SearchConfig, parameterized by path): all fields optional,
    # missing file -> built-in defaults; corrupt file -> defaults + a
    # stderr warning (fail-soft); invalid field values silently keep the
    # default per field.
    param([string]$Path)

    $config = $SearchDefaults

    $obj = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
        }
        catch {
            [Console]::Error.WriteLine("search-config.json unreadable (built-in defaults apply): $($_.Exception.Message)")
            return $config
        }
    }
    if ($null -eq $obj) { return $config }

    $lex = $null
    $vec = $null
    if ($null -ne $obj.recallers) {
        $lex = $obj.recallers.lexical
        $vec = $obj.recallers.vector
    }
    return @{
        topK        = Get-SearchConfigValue $obj "topK" $config.topK (Get-SearchFieldValidator "posInt")
        recallDepth = Get-SearchConfigValue $obj "recallDepth" $config.recallDepth (Get-SearchFieldValidator "posInt")
        rrfK        = Get-SearchConfigValue $obj "rrfK" $config.rrfK (Get-SearchFieldValidator "posNum")
        recallers   = @{
            lexical = Merge-LexicalRecallerConfig -Section $lex -Defaults $config.recallers.lexical
            vector  = Merge-VectorRecallerConfig -Section $vec -Defaults $config.recallers.vector
        }
    }
}

# --- Recaller plugin registry (each recallers/*.ps1 self-registers) ---

$script:Recallers = @()

function Register-Recaller {
    # Plugin contract (mirrored in dsh src/cache.ts Recaller): a recaller only
    # SCORES docs — never fuses, never truncates. $DefaultEnabled is what an
    # unconfigured recaller falls back to ($true / $false / "auto").
    # $AutoReady evaluates the "auto" rule without running the recaller; it
    # receives the WHOLE config and returns @{ ready; reason? }. Recallers
    # take everything through $ctx and never reference host functions back.
    param(
        [string]$Name,
        $DefaultEnabled,
        [scriptblock]$AutoReady,
        [scriptblock]$ScriptBlock
    )
    $script:Recallers += @{
        Name           = $Name
        DefaultEnabled = $DefaultEnabled
        AutoReady      = $AutoReady
        ScriptBlock    = $ScriptBlock
    }
}

# Dot-source every plugin (sorted by name = frozen registration order, which
# F7's accumulation order depends on: lexical.ps1 before vector.ps1).
# Resolved relative to THIS file (scripts/lib -> scripts/recallers), so any
# host dot-sourcing the library gets the plugins loaded exactly once, in the
# frozen order. Dot-source this library once per process: plugins appended
# twice would double-register and double-accumulate in F7.
$recallerDir = Join-Path $PSScriptRoot "..\recallers"
if (Test-Path -LiteralPath $recallerDir -PathType Container) {
    foreach ($plugin in @(Get-ChildItem -LiteralPath $recallerDir -Filter "*.ps1" -File | Sort-Object -Property Name)) {
        . $plugin.FullName
    }
}
if ($script:Recallers.Count -eq 0) {
    [Console]::Error.WriteLine("no recallers registered (expected scripts/recallers/*.ps1); search degrades to always-miss")
}

function Get-RecallerSection {
    # Null-safe config-section lookup. A third-party recaller (a new file in
    # recallers/) has NO section in search-config.json nor $SearchDefaults —
    # it must get $null here, never a null-array index crash. Frozen mirror
    # of the dsh plugin's `config.recallers[recaller.name]` optional access.
    param([hashtable]$Config, [string]$Name)
    if ($null -eq $Config -or $null -eq $Config.recallers) { return $null }
    return $Config.recallers[$Name]
}

function Resolve-RecallerEnabled {
    # run/skip decision for one recaller. An unconfigured recaller falls back
    # to its self-reported DefaultEnabled (frozen mirror of the dsh
    # `section?.enabled ?? recaller.defaultEnabled`); "auto" consults the
    # plugin's AutoReady against the WHOLE config, forwarding its reason.
    param($Recaller, $Section, [hashtable]$Config)
    $enabledValue = $null
    if ($null -ne $Section) { $enabledValue = $Section["enabled"] }
    if ($null -eq $enabledValue) { $enabledValue = $Recaller.DefaultEnabled }
    if ($enabledValue -eq $true) { return @{ run = $true } }
    if ($enabledValue -ne "auto") { return @{ run = $false } }
    $verdict = @{ ready = $true }
    if ($null -ne $Recaller.AutoReady) { $verdict = & $Recaller.AutoReady $Config }
    if ($verdict.ready) { return @{ run = $true } }
    return @{ run = $false; warning = ([string]$verdict.reason) }
}

function Invoke-SingleRecaller {
    # Runs one recaller; any throw degrades to a failed outcome (the
    # pluggability guarantee: one broken path never breaks the interface).
    param($Recaller, [hashtable]$Ctx, [double]$Weight)
    try {
        $res = & $Recaller.ScriptBlock $Ctx
        $qualified = @($res.qualified)
        $outcome = @{
            name      = [string]$res.name
            status    = "ok"
            qualified = $qualified.Count
        }
        if (-not [string]::IsNullOrEmpty([string]$res.warning)) { $outcome["warning"] = [string]$res.warning }
        return @{
            outcome = $outcome
            list    = @{ name = [string]$res.name; qualified = $qualified; weight = $Weight }
        }
    }
    catch {
        return @{
            outcome = @{ name = $Recaller.Name; status = "failed"; qualified = 0; warning = "$($_.Exception.Message)" }
        }
    }
}

function Invoke-Recallers {
    # Generic core (the former explore-only Invoke-AllRecallers): runs every
    # registered recaller (registration order = F7 accumulation order) over
    # PRE-SHAPED doc records; a disabled/failed path yields an empty
    # contribution plus a rankMeta outcome — the interface stays complete on
    # any single-path failure (pluggability guarantee). Hosts map their own
    # corpus into docs and pass their own vectors-sidecar path.
    param([string]$Query, [array]$Docs, [hashtable]$Config, [string]$VectorsPath)

    $ctx = @{
        query  = $Query
        docs   = $Docs
        config = $Config
        paths  = @{ vectorsPath = $VectorsPath }
    }

    $outcomes = @()
    $qualifiedLists = @()
    foreach ($r in $script:Recallers) {
        $section = Get-RecallerSection -Config $Config -Name $r.Name
        $decision = Resolve-RecallerEnabled -Recaller $r -Section $section -Config $Config
        if (-not $decision.run) {
            $outcome = @{ name = $r.Name; status = "disabled"; qualified = 0 }
            if ($null -ne $decision.warning) { $outcome["warning"] = $decision.warning }
            $outcomes += $outcome
            continue
        }
        $weight = 1.0
        if ($null -ne $section -and $null -ne $section["weight"]) { $weight = [double]$section["weight"] }
        $ran = Invoke-SingleRecaller -Recaller $r -Ctx $ctx -Weight $weight
        $outcomes += $ran.outcome
        if ($null -ne $ran.list) { $qualifiedLists += $ran.list }
    }

    return @{ outcomes = $outcomes; lists = $qualifiedLists }
}

function Invoke-RRFFusion {
    # F7 (frozen): accumulate in registration order over each qualified list.
    # Ordinal key tables so PS's default case-insensitive hashtables can never
    # collide two distinct entry keys.
    param([array]$QualifiedLists, [int]$RrfK)

    $scores = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $recalledBy = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($list in $QualifiedLists) {
        $rank = 0
        foreach ($key in @($list.qualified)) {
            $rank++
            if (-not $scores.ContainsKey($key)) {
                $scores[$key] = 0.0
                $recalledBy[$key] = @()
            }
            $scores[$key] = [double]$scores[$key] + [double]$list.weight / ($RrfK + $rank)
            $recalledBy[$key] = @($recalledBy[$key]) + @($list.name)
        }
    }
    return @{ scores = $scores; recalledBy = $recalledBy }
}

function Invoke-InsertionSort {
    # Generic stable in-place insertion sort driven by an injected comparator
    # scriptblock (returns <0 when $Cur sorts before $Other). No
    # culture-sensitive comparisons anywhere — the ordering is entirely the
    # comparator's, so every host sorter is a thin wrapper instead of a copy
    # (same loop the former inline F8 sorter used).
    param([object[]]$Items, [scriptblock]$Compare)
    for ($i = 1; $i -lt $Items.Count; $i++) {
        $cur = $Items[$i]
        $j = $i - 1
        while ($j -ge 0 -and ((& $Compare -Cur $cur -Other $Items[$j]) -lt 0)) {
            $Items[$j + 1] = $Items[$j]
            $j--
        }
        $Items[$j + 1] = $cur
    }
    return $Items
}

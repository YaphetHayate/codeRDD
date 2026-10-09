# QA engine-mirror test for the config centre (goal-tree ops-config-panel n4).
#
# Proves the validation-mirror consistency end to end, against the REAL
# engine (scripts/explore.cmd -Type search), on a throwaway data root:
#
#   1. seed a six-entry retrieval pool via explore-store register
#   2. baseline: rankMeta.returned == 5 (built-in topK default)
#   3. illegal values saved THROUGH THE PAGE endpoint -> 422, file never
#      created, engine still runs on defaults (write side rejects)
#   4. a hand-written illegal file (the editor bypass) -> engine exit 0,
#      returned == 5, per-field fail-soft to defaults (read side mirrors)
#   5. a legal save through the page endpoint -> topK=3 takes effect in the
#      very next engine run (legal values fully apply)
#
# Windows PowerShell 5.1 compatible. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File rdd-engine/tests/test-config-engine-mirror.ps1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$engineDir = Resolve-Path (Join-Path $scriptRoot '..')
$repoRoot = Resolve-Path (Join-Path $engineDir '..')
$storeCmd = Join-Path $engineDir 'scripts\explore-store.cmd'
$exploreCmd = Join-Path $engineDir 'scripts\explore.cmd'
$bootHelper = Join-Path $scriptRoot 'helper-config-mirror-boot.mjs'
$port = 8831
$base = "http://127.0.0.1:$port"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { $script:Pass++; Write-Output "PASS  $Name" }
    else { $script:Fail++; Write-Output "FAIL  $Name   $Detail" }
}

function Invoke-Search {
    param([string]$Query)
    $raw = (& $exploreCmd -Type search -Query $Query) -join "`n"
    return @{ json = ($raw | ConvertFrom-Json); exit = $LASTEXITCODE }
}

function Read-ErrorPayload {
    # Response body of a failed Invoke-RestMethod (5.1 stream / 7 ErrorDetails).
    param($ErrorRecord)
    $text = $null
    try { $text = $ErrorRecord.ErrorDetails.Message } catch { }
    if ([string]::IsNullOrWhiteSpace($text) -and $null -ne $ErrorRecord.Exception.Response) {
        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            $text = $reader.ReadToEnd()
        } catch { }
    }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Invoke-Save {
    # POST /api/config/search-config; never throws on 4xx/5xx.
    param([object]$Config)
    $body = @{ config = $Config } | ConvertTo-Json -Depth 5
    try {
        $response = Invoke-RestMethod -Uri "$base/api/config/search-config" -Method Post -ContentType 'application/json' -Body $body
        return @{ status = 200; payload = $response }
    }
    catch {
        $status = 0
        if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        return @{ status = $status; payload = (Read-ErrorPayload $_) }
    }
}

function Wait-ForDashboard {
    for ($i = 0; $i -lt 40; $i++) {
        try { Invoke-RestMethod -Uri "$base/api/config" -Method Get | Out-Null; return $true } catch { Start-Sleep -Milliseconds 250 }
    }
    return $false
}

function New-SeedPool {
    param([string]$Root)
    $artifacts = Join-Path $Root '.rdd\exploration\artifacts'
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    for ($i = 1; $i -le 6; $i++) {
        $slug = "m$i"
        [System.IO.File]::WriteAllText((Join-Path $artifacts "$slug.md"), "full record $slug alpha beta", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $artifacts "$slug.summary.md"), "summary $slug alpha beta gamma", $utf8NoBom)
        (& $storeCmd -Type register -Key "k$i" -Path ".rdd/exploration/artifacts/$slug.md" -Tags "alpha,beta,module$i" -Brief "mirror probe entry $i") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "register k$i failed" }
    }
}

# ── run ─────────────────────────────────────────────────────────────────
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("rdd-n4-mirror-" + [guid]::NewGuid().ToString('N'))
$previousRootEnv = $env:RDD_PROJECT_ROOT
$server = $null
try {
    New-Item -ItemType Directory -Path (Join-Path $root '.rdd') -Force | Out-Null
    $env:RDD_PROJECT_ROOT = $root
    New-SeedPool -Root $root
    $configPath = Join-Path $root '.rdd\exploration\search-config.json'

    $env:QA_MIRROR_ROOT = $root
    $env:QA_MIRROR_PORT = "$port"
    $server = Start-Process -FilePath 'node' -ArgumentList @($bootHelper) -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
    Assert-True (Wait-ForDashboard) 'boot: the dashboard serves the mirror workspace'

    $baseline = Invoke-Search -Query 'alpha'
    Assert-True ($baseline.exit -eq 0 -and $baseline.json.success -eq $true) 'engine: baseline search succeeds (pool registered)'
    Assert-True ($baseline.json.data.rankMeta.returned -eq 5) 'engine: baseline returned=5 (built-in topK default)' "returned=$($baseline.json.data.rankMeta.returned)"

    foreach ($case in @(
            @{ name = 'topK=0'; config = @{ topK = 0 }; path = 'topK' },
            @{ name = 'minCosine=1.5'; config = @{ recallers = @{ vector = @{ minCosine = 1.5 } } }; path = 'recallers.vector.minCosine' },
            @{ name = 'topK="5" (type-wrong)'; config = @{ topK = '5' }; path = 'topK' },
            @{ name = 'dimensions=-1'; config = @{ recallers = @{ vector = @{ dimensions = -1 } } }; path = 'recallers.vector.dimensions' }
        )) {
        $refused = Invoke-Save -Config $case.config
        $errorPath = $null
        if ($null -ne $refused.payload -and $null -ne $refused.payload.fieldErrors) { $errorPath = $refused.payload.fieldErrors[0].path }
        Assert-True ($refused.status -eq 422 -and $refused.payload.code -eq 'invalid-field' -and $errorPath -eq $case.path) "page-save: $($case.name) refused 422 invalid-field" "status=$($refused.status) code=$($refused.payload.code) path=$errorPath"
    }
    Assert-True (-not (Test-Path -LiteralPath $configPath)) 'page-save: the illegal attempts never created the file'
    $afterRefusal = Invoke-Search -Query 'alpha'
    Assert-True ($afterRefusal.exit -eq 0 -and $afterRefusal.json.data.rankMeta.returned -eq 5) 'engine: after refused saves the engine still runs on defaults (returned=5, exit 0)'

    $handwritten = @'
{
  "topK": 0,
  "recallDepth": 1.5,
  "rrfK": "60",
  "recallers": {
    "lexical": { "enabled": 1, "weight": 0 },
    "vector": { "minCosine": 1.5, "dimensions": -1 }
  }
}
'@
    [System.IO.File]::WriteAllText($configPath, $handwritten, $utf8NoBom)
    $failSoft = Invoke-Search -Query 'alpha'
    Assert-True ($failSoft.exit -eq 0 -and $failSoft.json.success -eq $true) 'engine: a hand-written illegal file fails SOFT (exit 0, success)'
    Assert-True ($failSoft.json.data.rankMeta.returned -eq 5) 'engine: every illegal field fell back to its default (returned=5)' "returned=$($failSoft.json.data.rankMeta.returned)"
    $vectorOutcome = @($failSoft.json.data.rankMeta.recallers) | Where-Object { $_.name -eq 'vector' }
    $lexicalOutcome = @($failSoft.json.data.rankMeta.recallers) | Where-Object { $_.name -eq 'lexical' }
    Assert-True ($vectorOutcome.status -eq 'disabled' -and $vectorOutcome.warning -match 'vector config incomplete') 'engine: vector path auto-disabled with the missing-factor warning (rankMeta 同口径)' ($vectorOutcome | ConvertTo-Json -Compress)
    Assert-True ($lexicalOutcome.status -eq 'ok') 'engine: illegal lexical.enabled=1 fell back to default true (lexical still ran)' ($lexicalOutcome | ConvertTo-Json -Compress)

    $legal = Invoke-Save -Config @{ topK = 3 }
    Assert-True ($legal.status -eq 200 -and $legal.payload.code -eq 'saved') 'page-save: legal topK=3 saved' "status=$($legal.status)"
    $applied = Invoke-Search -Query 'alpha'
    Assert-True ($applied.exit -eq 0 -and $applied.json.data.rankMeta.returned -eq 3) 'engine: the legal save takes full effect on the very next run (returned=3)' "returned=$($applied.json.data.rankMeta.returned)"
    $readinessAfter = (Invoke-RestMethod -Uri "$base/api/config").data.l2.vectorReadiness
    Assert-True (@($readinessAfter.missing) -contains 'apikey' -and $readinessAfter.ready -eq $false) 'page: readiness names the remaining factor from the dashboard env (same 口径)' ($readinessAfter | ConvertTo-Json -Compress)
}
finally {
    if ($null -ne $server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item Env:\QA_MIRROR_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\QA_MIRROR_PORT -ErrorAction SilentlyContinue
    if ($previousRootEnv -eq $null) { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue }
    else { $env:RDD_PROJECT_ROOT = $previousRootEnv }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
$total = $script:Pass + $script:Fail
Write-Output "total: $total  failed: $($script:Fail)"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }

# query-log acceptance tests (explore.ps1 hit-rate data source)
# Validates the Write-QueryLog decision point added to scripts/explore.ps1
# (requirement 2026-10-08-rdd-ops-dashboard/explore-query-log) end-to-end in
# a NON-git fixture project, with the search itself running under Windows
# PowerShell 5.1 (the strictest compatibility target, same harness pattern as
# test-repo-root-fallback.ps1):
#   1. hit   two-entry query -> ONE line, frozen six fields in frozen order,
#            keys == returned results in rank order, ts ISO-8601 UTC millis
#   2. miss  nonsense query  -> ONE line, outcome=miss, keys=[], and the
#            historical hit line byte-identical (append-only, acceptance #3)
#   3. isolation  read-only log file -> append fails -> search still exits 0
#            with success=true plus a stderr warning (acceptance #4)
#   4. encoding   the recreated log carries no UTF-8 BOM (data-file contract)
# Exit code 0 = all green.
#
# Usage: powershell -File test-query-log.ps1   (or via pwsh tool)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptsDir = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$ExplorePs1 = Join-Path $ScriptsDir 'explore.ps1'
$Work       = Join-Path $env:TEMP ('query-log-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ArtifactSha { param([string]$Path)
    $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return "sha256:$($h.Hash.ToLowerInvariant())"
}

# Run explore.ps1 under PS 5.1 anchored INSIDE the fixture project (Push-
# Location: the child inherits this cwd, so the repo-root chain resolves
# against the fixture, never the test runner's own git checkout). cmd /c
# merges the child's stderr into stdout BEFORE PowerShell ever sees a stream:
# a PS 5.1 outer shell with ErrorActionPreference=Stop would otherwise raise
# NativeCommandError over the isolation case's intentional warning (the same
# trap explore.ps1 documents for its own git call).
function Invoke-Explore { param([string]$QueryText, [string]$Cwd)
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Type search -Query "{1}" 2>&1' -f $ExplorePs1, $QueryText
    Push-Location $Cwd
    try { $out = (& cmd /c $cmd) -join [System.Environment]::NewLine } finally { Pop-Location }
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}

function Get-LogLines { param([string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    return [System.IO.File]::ReadAllLines($LogPath)
}

$FrozenFields = 'ts,entry,query,outcome,keys,recallers'

Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue

# ===== fixture: non-git project with a two-entry exploration cache =====
$proj = Join-Path $Work 'proj'
$explDir = Join-Path $proj '.rdd\exploration'
$artsDir = Join-Path $explDir 'artifacts'
New-Item -ItemType Directory -Path $artsDir -Force | Out-Null
Write-Utf8NoBom (Join-Path $proj '.rdd\install.json') @'
{
  "version": "test"
}
'@

$artA = Join-Path $artsDir 'auth-module.md'
$artB = Join-Path $artsDir 'auth-session-store.md'
Write-Utf8NoBom $artA 'full record: authentication module overview'
Write-Utf8NoBom $artB 'full record: session token store overview'

Write-Utf8NoBom (Join-Path $explDir 'index.json') (
    (@{
        entries = @(
            @{
                key   = 'auth-module'
                tags  = @('auth', 'login', 'access')
                brief = 'authentication module login overview'
                path  = '.rdd/exploration/artifacts/auth-module.md'
                files = @{ '.rdd/exploration/artifacts/auth-module.md' = (Get-ArtifactSha $artA) }
            },
            @{
                key   = 'auth-session-store'
                tags  = @('auth', 'session', 'token')
                brief = 'session token store module overview'
                path  = '.rdd/exploration/artifacts/auth-session-store.md'
                files = @{ '.rdd/exploration/artifacts/auth-session-store.md' = (Get-ArtifactSha $artB) }
            }
        )
    } | ConvertTo-Json -Depth 8)
)

$logPath = Join-Path $explDir 'query-log.jsonl'

try {
    # ===== 1. hit: two-entry query =====
    $hitQuery = 'auth login session token'
    $r1 = Invoke-Explore -QueryText $hitQuery -Cwd $proj
    Assert-True ($r1.exit -eq 0 -and $r1.json.success -eq $true) 'hit e2e: search succeeds' ("exit=$($r1.exit)")
    Assert-True (@($r1.json.data.results).Count -eq 2) 'hit e2e: both entries returned' ("results=$(@($r1.json.data.results).Count)")

    $lines1 = @(Get-LogLines $logPath)
    Assert-True ($lines1.Count -eq 1) 'hit: exactly one log line appended' ("lines=$($lines1.Count)")
    $rec = $lines1[0] | ConvertFrom-Json
    $propNames = (@($rec.PSObject.Properties) | ForEach-Object { $_.Name }) -join ','
    Assert-True ($propNames -ceq $FrozenFields) 'hit: frozen six fields in frozen order' ("got: $propNames")
    Assert-True ($rec.ts -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$') 'hit: ts is ISO-8601 UTC millis' ("ts=$($rec.ts)")
    Assert-True ($rec.entry -eq 'cli') 'hit: entry=cli'
    Assert-True ($rec.query -eq $hitQuery) 'hit: query recorded verbatim' ("query=$($rec.query)")
    Assert-True ($rec.outcome -eq 'hit') 'hit: outcome=hit'
    $returnedKeys = (@($r1.json.data.results) | ForEach-Object { [string]$_.key })
    $loggedKeys   = @($rec.keys)
    Assert-True (($loggedKeys -join '|') -eq ($returnedKeys -join '|')) 'hit: keys == returned keys in rank order' ("logged=$($loggedKeys -join '|') returned=$($returnedKeys -join '|')")
    $recallerNames = (@($rec.recallers) | ForEach-Object { [string]$_.name })
    Assert-True ($recallerNames -contains 'lexical') 'hit: recallers carries the lexical recaller' ("recallers=$($recallerNames -join ',')")
    $lex = @($rec.recallers) | Where-Object { $_.name -eq 'lexical' }
    Assert-True ((@($lex).Count -eq 1) -and ([string]$lex[0].status -eq 'ok') -and ([int]$lex[0].qualified -ge 1)) 'hit: lexical recaller ok with qualified>=1'
    $badRecaller = @($rec.recallers) | Where-Object { ((@($_.PSObject.Properties) | ForEach-Object { $_.Name }) -join ',') -ne 'name,status,qualified' }
    Assert-True (@($badRecaller).Count -eq 0) 'hit: every recaller has exactly name,status,qualified'

    # ===== 2. miss + append-only =====
    $lineBefore = $lines1[0]
    $missQuery = 'zzzqqq wubble'
    $r2 = Invoke-Explore -QueryText $missQuery -Cwd $proj
    Assert-True ($r2.exit -eq 0 -and $r2.json.success -eq $true) 'miss e2e: search succeeds' ("exit=$($r2.exit)")
    Assert-True (@($r2.json.data.results).Count -eq 0) 'miss e2e: no results (dispatchPrompt attached)'
    Assert-True ($null -ne $r2.json.data.dispatchPrompt) 'miss e2e: dispatchPrompt attached (dispatch marker path)'

    $lines2 = @(Get-LogLines $logPath)
    Assert-True ($lines2.Count -eq 2) 'miss: exactly one more line appended' ("lines=$($lines2.Count)")
    Assert-True ($lines2[0] -ceq $lineBefore) 'append-only: historical line byte-identical'
    $rec2 = $lines2[1] | ConvertFrom-Json
    $propNames2 = (@($rec2.PSObject.Properties) | ForEach-Object { $_.Name }) -join ','
    Assert-True ($propNames2 -ceq $FrozenFields) 'miss: frozen six fields in frozen order' ("got: $propNames2")
    Assert-True ($rec2.outcome -eq 'miss') 'miss: outcome=miss (dispatch marker)'
    Assert-True (@($rec2.keys).Count -eq 0) 'miss: keys empty'
    Assert-True ($rec2.query -eq $missQuery) 'miss: query recorded verbatim'

    # ===== 3. failure isolation: read-only log file, history preserved =====
    Set-ItemProperty -LiteralPath $logPath -Name IsReadOnly -Value $true
    $r3 = Invoke-Explore -QueryText 'auth login' -Cwd $proj
    Assert-True ($r3.exit -eq 0) 'isolation: exit code untouched by log failure' ("exit=$($r3.exit)")
    Assert-True ($r3.raw -match '"success":\s*true') 'isolation: search result untouched by log failure'
    Assert-True ($r3.raw -match 'query-log append failed') 'isolation: failure surfaced as stderr warning only'
    Set-ItemProperty -LiteralPath $logPath -Name IsReadOnly -Value $false

    # ===== 4. recovery + append-only across the failed write + no BOM =====
    $r4 = Invoke-Explore -QueryText 'auth access' -Cwd $proj
    Assert-True ($r4.exit -eq 0 -and $r4.json.success -eq $true) 'recovery: next query succeeds'
    $lines4 = @(Get-LogLines $logPath)
    Assert-True ($lines4.Count -eq 3) 'recovery: line 3 appended after the failed write' ("lines=$($lines4.Count)")
    Assert-True ($lines4[0] -ceq $lineBefore) 'append-only: line 1 still byte-identical'
    $rec4 = $lines4[2] | ConvertFrom-Json
    $returnedKeys4 = (@($r4.json.data.results) | ForEach-Object { [string]$_.key })
    Assert-True ($rec4.outcome -eq 'hit' -and (($rec4.keys -join '|') -ceq ($returnedKeys4 -join '|'))) 'recovery: line 3 is the hit record (keys == returned)'
    $bytes = [System.IO.File]::ReadAllBytes($logPath)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'encoding: query-log.jsonl has no UTF-8 BOM'

    # ===== summary =====
    $failed = @($Results | Where-Object { -not $_.ok })
    Write-Output ''
    Write-Output ("total: {0}  failed: {1}" -f $Results.Count, $failed.Count)
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
finally {
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Set-ItemProperty -LiteralPath $logPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    }
    Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

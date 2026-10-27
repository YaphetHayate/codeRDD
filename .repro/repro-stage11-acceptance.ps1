# Stage-11: ACCEPTANCE on the INSTALLED engine copy (ProtectTheCats).
# Runs AFTER sync. Three checks on the live run's read-only TEMP copy:
#   A success (container edges + task mirror + explicit translation + resolve)
#   B idempotent rerun (DEP_EXISTS tolerated)
#   C failure visibility (bogus node -> JSON error on stdout, exit 1, NON-ZERO bytes)
param([string]$EngDir = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats\.rdd\skills\rdd-engine\scripts')
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$runId    = 'deliver-2026-10-26-level-mode-optimization'
"engine dir: $EngDir"
"engine delivery-bridge.ps1 sha256: " + (Get-FileHash (Join-Path $EngDir 'delivery-bridge.ps1') -Algorithm SHA256).Hash

function Copy-RunToScratch {
    param([string]$Tag)
    $root = Join-Path $env:TEMP ("rdd-accept-$Tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
    Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
    return $root
}
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
function Add-ConflictEntry {
    param([string]$Root, [string]$Id, [string[]]$Nodes, [int[]]$Tasks, [string[]]$Files, [string]$Note)
    $bjPath = Join-Path $Root ".rdd/goal-trees/$runId/bridge.json"
    $bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
    $bj.conflicts = @($bj.conflicts) + ([ordered]@{
        id = $Id; kind = 'file'; nodes = $Nodes; tasks = $Tasks; files = $Files
        detected_by = 'planner'; status = 'open'; note = $Note; escalation = $null; ruling = $null; serialize = $null
        created_at = $now; updated_at = $now; history = @()
    })
    [System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
}
$bridgeCmd = Join-Path $EngDir 'delivery-bridge.cmd'
function Invoke-Resolve {
    param([string]$Root, [string]$ConflictId, [string]$Serialize)
    $env:RDD_PROJECT_ROOT = $Root
    $env:DSH_SESSION_ID   = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'
    $o = Join-Path $Root 'o.txt'; $e = Join-Path $Root 'e.txt'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = & cmd /c " `"$bridgeCmd`" -Command conflict -RunId $runId -Action resolve -ConflictId $ConflictId -Serialize $Serialize 1>`"$o`" 2>`"$e`" "
    $code = $LASTEXITCODE; $sw.Stop()
    $outTxt = ''; if (Test-Path $o) { $outTxt = Get-Content $o -Raw -Encoding UTF8 }
    $errTxt = ''; if (Test-Path $e) { $errTxt = Get-Content $e -Raw -Encoding UTF8 }
    return @{ exit = $code; ms = $sw.ElapsedMilliseconds; out = $outTxt; err = $errTxt }
}

$files = @('assets/scripts/core/level/config.ts', 'assets/scripts/core/level/types.ts', 'assets/scripts/core/level/level-session.ts', 'assets/scripts/level/LevelScene.ts')

# --- A: success path ---
$rA = Copy-RunToScratch 'a'
Add-ConflictEntry $rA 'C3' @('n13','n15','n16') @(1,4,3) $files 'acceptance inject (installed copy)'
$ra = Invoke-Resolve $rA 'C3' 'n13'
Write-Output "=== A success: exit=$($ra.exit) ms=$($ra.ms) stdoutBytes=$([Text.Encoding]::UTF8.GetByteCount($ra.out)) stderrBytes=$([Text.Encoding]::UTF8.GetByteCount($ra.err)) ==="
Write-Output $ra.out
if ($ra.exit -eq 0) {
    $t = Get-Content (Join-Path $rA ".rdd/goal-trees/$runId/state/tree.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($nid in 'n2','n7','n10') { $n = @($t.nodes | Where-Object { $_.id -eq $nid })[0]; Write-Output "tree $nid depends_on: [$(@($n.depends_on) -join ',')]" }
    $b2 = Get-Content (Join-Path $rA ".rdd/goal-trees/$runId/bridge.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output "C3 status: $(@($b2.conflicts | Where-Object { $_.id -eq 'C3' })[0].status)"
    foreach ($tk in '3','4') { Write-Output "task$tk dep_task_ids: [$(@($b2.tasks.$tk.dep_task_ids) -join ',')]" }
    Write-Output "deps-log: $(Test-Path (Join-Path $rA ".rdd/goal-trees/$runId/state/deps-log.jsonl"))"
}

# --- B: idempotent (pre-existing edges) ---
$rB = Copy-RunToScratch 'b'
Add-ConflictEntry $rB 'C4' @('n13','n15','n16') @(1,4,3) $files 'idempotent inject (installed copy)'
$tPath = Join-Path $rB ".rdd/goal-trees/$runId/state/tree.json"
$tj = [System.IO.File]::ReadAllText($tPath) | ConvertFrom-Json
foreach ($pair in @(@('n10','n2'), @('n7','n2'))) {
    $n = @($tj.nodes | Where-Object { $_.id -eq $pair[0] })[0]
    if (@($n.depends_on) -notcontains $pair[1]) { $n.depends_on = @($n.depends_on) + $pair[1] }
}
[System.IO.File]::WriteAllText($tPath, ($tj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
$rb = Invoke-Resolve $rB 'C4' 'n13'
Write-Output "=== B idempotent: exit=$($rb.exit) stdoutBytes=$([Text.Encoding]::UTF8.GetByteCount($rb.out)) ==="
Write-Output $rb.out

# --- C: failure visibility (bogus node) ---
$rC = Copy-RunToScratch 'c'
Add-ConflictEntry $rC 'C5' @('n999','n13') @(1) @('x.ts') 'failure-visibility inject (installed copy)'
$rc = Invoke-Resolve $rC 'C5' 'n999'
Write-Output "=== C failure visibility: exit=$($rc.exit) stdoutBytes=$([Text.Encoding]::UTF8.GetByteCount($rc.out)) stderrBytes=$([Text.Encoding]::UTF8.GetByteCount($rc.err)) ==="
Write-Output $rc.out
Write-Output "scratch roots: A=$rA B=$rB C=$rC"

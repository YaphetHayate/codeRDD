# Stage-11c: acceptance B (idempotent) + C (failure visibility) on the INSTALLED engine.
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$bridgeCmd = Join-Path $engDir 'delivery-bridge.cmd'
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$env:DSH_SESSION_ID = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'
$env:DSH_WEB_URL    = 'http://127.0.0.1:1'

function New-Scratch { param([string]$Tag)
    $root = Join-Path $env:TEMP ("rdd-acc11c-$Tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
    Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
    return $root
}
function Add-C { param([string]$Root, [string]$Id, [string[]]$Nodes, [int[]]$Tasks, [string[]]$Files)
    $bjPath = Join-Path $Root ".rdd/goal-trees/$runId/bridge.json"
    $bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
    $bj.conflicts = @($bj.conflicts) + ([ordered]@{
        id = $Id; kind = 'file'; nodes = $Nodes; tasks = $Tasks; files = $Files
        detected_by = 'planner'; status = 'open'; note = 'acceptance'; escalation = $null; ruling = $null; serialize = $null
        created_at = $now; updated_at = $now; history = @()
    })
    [System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-Resolve { param([string]$Root, [string]$CId, [string]$Ser)
    $env:RDD_PROJECT_ROOT = $Root
    $o = Join-Path $Root 'o.txt'; $e = Join-Path $Root 'e.txt'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = & cmd /c " `"$bridgeCmd`" -Command conflict -RunId $runId -Action resolve -ConflictId $CId -Serialize $Ser 1>`"$o`" 2>`"$e`" "
    $code = $LASTEXITCODE; $sw.Stop()
    $out=''; if (Test-Path $o) { $out = Get-Content $o -Raw -Encoding UTF8 }
    $err=''; if (Test-Path $e) { $err = Get-Content $e -Raw -Encoding UTF8 }
    return @{ exit = $code; ms = $sw.ElapsedMilliseconds; out = $out; err = $err }
}
$files = @('assets/scripts/core/level/config.ts','assets/scripts/core/level/types.ts','assets/scripts/core/level/level-session.ts','assets/scripts/level/LevelScene.ts')

# --- B: idempotent (pre-existing container edges + task mirrors) ---
$rB = New-Scratch 'b'
Add-C $rB 'C4' @('n13','n15','n16') @(1,4,3) $files
$tPath = Join-Path $rB ".rdd/goal-trees/$runId/state/tree.json"
$tj = [System.IO.File]::ReadAllText($tPath) | ConvertFrom-Json
foreach ($pair in @(@('n10','n2'), @('n7','n2'))) {
    $n = @($tj.nodes | Where-Object { $_.id -eq $pair[0] })[0]
    if (@($n.depends_on) -notcontains $pair[1]) { $n.depends_on = @($n.depends_on) + $pair[1] }
}
[System.IO.File]::WriteAllText($tPath, ($tj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
$bjPath = Join-Path $rB ".rdd/goal-trees/$runId/bridge.json"
$bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
$bj.tasks.'4'.dep_task_ids = @(@($bj.tasks.'4'.dep_task_ids) | ForEach-Object { [int]$_ }) + 1
$bj.tasks.'3'.dep_task_ids = @(@($bj.tasks.'3'.dep_task_ids) | ForEach-Object { [int]$_ }) + 1
[System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
$rb = Invoke-Resolve $rB 'C4' 'n13'
$ob = [Text.Encoding]::UTF8.GetByteCount($rb.out)
Write-Output "=== B idempotent: exit=$($rb.exit) ms=$($rb.ms) stdoutBytes=$ob ==="
Write-Output $rb.out
if ($rb.exit -eq 0) {
    $b2 = Get-Content $bjPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output "C4 status: $(@($b2.conflicts | Where-Object { $_.id -eq 'C4' })[0].status)"
    $t2 = Get-Content $tPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $n10 = @($t2.nodes | Where-Object { $_.id -eq 'n10' })[0]
    Write-Output ("n10 depends_on: [{0}]  (count n2: {1})" -f (@($n10.depends_on) -join ','), (@($n10.depends_on) | Where-Object { $_ -eq 'n2' } | Measure-Object).Count)
    Write-Output ("task4 dep_task_ids: [{0}] (count 1: {1})" -f (@($b2.tasks.'4'.dep_task_ids) -join ','), (@(@($b2.tasks.'4'.dep_task_ids) | Where-Object { [int]$_ -eq 1 }) | Measure-Object).Count)
}

# --- C: failure visibility (bogus node) ---
$rC = New-Scratch 'c'
Add-C $rC 'C5' @('n999','n13') @(1) @('x.ts')
$rc = Invoke-Resolve $rC 'C5' 'n999'
$oc = [Text.Encoding]::UTF8.GetByteCount($rc.out); $ec = [Text.Encoding]::UTF8.GetByteCount($rc.err)
Write-Output "=== C failure visibility: exit=$($rc.exit) ms=$($rc.ms) stdoutBytes=$oc stderrBytes=$ec ==="
Write-Output $rc.out
Write-Output "scratch roots: B=$rB C=$rC"

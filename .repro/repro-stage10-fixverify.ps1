# Stage-10: verify FIXED source engine on the live run's read-only TEMP copy.
# Success expectations: JSON success, container edges n10->n2 / n7->n2, task mirrors,
# C3 resolved with serialize.mode=container, explicit translation in serialized list.
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$engDir   = 'D:\YaphetHayate\projects\codeRDD\rdd-engine\scripts'   # FIXED SOURCE
$runId    = 'deliver-2026-10-26-level-mode-optimization'

$root = Join-Path $env:TEMP ("rdd-fixverify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
Copy-Item -LiteralPath "$demoRoot\.rdd\changes\archive\2026-10-26-level-mode-optimization" -Destination (Join-Path $root 'archive') -Recurse
$bjPath = Join-Path $root ".rdd/goal-trees/$runId/bridge.json"
$bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
$bj.archive = (Join-Path $root 'archive')
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$c3 = [ordered]@{
    id = 'C3'; kind = 'file'; nodes = @('n13', 'n15', 'n16'); tasks = @(1, 4, 3)
    files = @('assets/scripts/core/level/config.ts', 'assets/scripts/core/level/types.ts', 'assets/scripts/core/level/level-session.ts', 'assets/scripts/level/LevelScene.ts')
    detected_by = 'planner'; status = 'open'; note = 'fix-verify inject'; escalation = $null; ruling = $null; serialize = $null
    created_at = $now; updated_at = $now; history = @(@{ at = $now; action = 'open'; note = 'fix-verify inject' })
}
$bj.conflicts = @($bj.conflicts) + $c3
[System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))

$env:RDD_PROJECT_ROOT = $root
$env:DSH_SESSION_ID   = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'

$bridgeCmd = Join-Path $engDir 'delivery-bridge.cmd'
$outF = Join-Path $root 'o.txt'; $errF = Join-Path $root 'e.txt'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = & cmd /c " `"$bridgeCmd`" -Command conflict -RunId $runId -Action resolve -ConflictId C3 -Serialize n13 1>`"$outF`" 2>`"$errF`" "
$code = $LASTEXITCODE; $sw.Stop()
Write-Output "=== fix-verify A (success path) exit=$code elapsedMs=$($sw.ElapsedMilliseconds) ==="
$outTxt = Get-Content $outF -Raw -Encoding UTF8
Write-Output "stdout: $outTxt"
Write-Output "stderr: $(Get-Content $errF -Raw -Encoding UTF8)"

if ($code -eq 0) {
    $j = $outTxt | ConvertFrom-Json
    Write-Output "success: $($j.success)"
    Write-Output "serialized:"; $j.data.serialized | ForEach-Object { Write-Output "  - $_" }
    Write-Output "serialize block: mode=$($j.data.conflict.serialize.mode) earlier=$($j.data.conflict.serialize.earlier)"
    $t = Get-Content (Join-Path $root ".rdd/goal-trees/$runId/state/tree.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($nid in 'n2','n7','n10') { $n = @($t.nodes | Where-Object { $_.id -eq $nid })[0]; Write-Output "tree $nid depends_on: [$(@($n.depends_on) -join ',')]" }
    $dl = Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"
    Write-Output "deps-log exists: $(Test-Path $dl)"; if (Test-Path $dl) { Get-Content $dl | ForEach-Object { Write-Output "  $_" } }
    $b2 = Get-Content $bjPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output "C3 status: $(@($b2.conflicts | Where-Object { $_.id -eq 'C3' })[0].status)"
    foreach ($tk in '3','4') { Write-Output "task$tk dep_task_ids: [$(@($b2.tasks.$tk.dep_task_ids) -join ',')]" }
}

# --- fix-verify B: idempotent rerun (DEP_EXISTS) — fresh scratch, pre-existing edges ---
$root2 = Join-Path $env:TEMP ("rdd-fixverify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path (Join-Path $root2 '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root2 ".rdd/goal-trees/$runId") -Recurse
Copy-Item -LiteralPath "$demoRoot\.rdd\changes\archive\2026-10-26-level-mode-optimization" -Destination (Join-Path $root2 'archive') -Recurse
$bj2Path = Join-Path $root2 ".rdd/goal-trees/$runId/bridge.json"
$bj2 = [System.IO.File]::ReadAllText($bj2Path) | ConvertFrom-Json
$bj2.archive = (Join-Path $root2 'archive')
$c4 = [ordered]@{
    id = 'C4'; kind = 'file'; nodes = @('n13', 'n15', 'n16'); tasks = @(1, 4, 3)
    files = @('assets/scripts/core/level/config.ts', 'assets/scripts/core/level/types.ts', 'assets/scripts/core/level/level-session.ts', 'assets/scripts/level/LevelScene.ts')
    detected_by = 'planner'; status = 'open'; note = 'idempotent inject'; escalation = $null; ruling = $null; serialize = $null
    created_at = $now; updated_at = $now; history = @(@{ at = $now; action = 'open'; note = 'idempotent inject' })
}
$bj2.conflicts = @($bj2.conflicts) + $c4
# pre-existing node-level (container) edges + task mirrors, like an earlier entry would have left
$tPath = Join-Path $root2 ".rdd/goal-trees/$runId/state/tree.json"
$tj = [System.IO.File]::ReadAllText($tPath) | ConvertFrom-Json
foreach ($pair in @(@('n10','n2'), @('n7','n2'))) {
    $n = @($tj.nodes | Where-Object { $_.id -eq $pair[0] })[0]
    if (@($n.depends_on) -notcontains $pair[1]) { $n.depends_on = @($n.depends_on) + $pair[1] }
}
[System.IO.File]::WriteAllText($tPath, ($tj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
$bj2.tasks.'4'.dep_task_ids = @($bj2.tasks.'4'.dep_task_ids | ForEach-Object { [int]$_ }) + 1
$bj2.tasks.'3'.dep_task_ids = @($bj2.tasks.'3'.dep_task_ids | ForEach-Object { [int]$_ }) + 1
[System.IO.File]::WriteAllText($bj2Path, ($bj2 | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))

$env:RDD_PROJECT_ROOT = $root2
$outB = Join-Path $root2 'o.txt'; $errB = Join-Path $root2 'e.txt'
$null = & cmd /c " `"$bridgeCmd`" -Command conflict -RunId $runId -Action resolve -ConflictId C4 -Serialize n13 1>`"$outB`" 2>`"$errB`" "
$codeB = $LASTEXITCODE
Write-Output "=== fix-verify B (idempotent DEP_EXISTS) exit=$codeB ==="
$outBTxt = Get-Content $outB -Raw -Encoding UTF8
Write-Output "stdout: $outBTxt"
if ($codeB -eq 0) {
    $jb = $outBTxt | ConvertFrom-Json
    Write-Output "serialized:"; $jb.data.serialized | ForEach-Object { Write-Output "  - $_" }
}

# --- fix-verify C: failure visibility — bogus earlier node (not in tree) ---
$root3 = Join-Path $env:TEMP ("rdd-fixverify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path (Join-Path $root3 '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root3 ".rdd/goal-trees/$runId") -Recurse
$bj3Path = Join-Path $root3 ".rdd/goal-trees/$runId/bridge.json"
$bj3 = [System.IO.File]::ReadAllText($bj3Path) | ConvertFrom-Json
$c5 = [ordered]@{
    id = 'C5'; kind = 'file'; nodes = @('n999', 'n13'); tasks = @(1)
    files = @('x.ts'); detected_by = 'planner'; status = 'open'; note = 'failure-visibility inject'
    escalation = $null; ruling = $null; serialize = $null
    created_at = $now; updated_at = $now; history = @(@{ at = $now; action = 'open'; note = 'failure-visibility inject' })
}
$bj3.conflicts = @($bj3.conflicts) + $c5
[System.IO.File]::WriteAllText($bj3Path, ($bj3 | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
$env:RDD_PROJECT_ROOT = $root3
$outC = Join-Path $root3 'o.txt'; $errC = Join-Path $root3 'e.txt'
$null = & cmd /c " `"$bridgeCmd`" -Command conflict -RunId $runId -Action resolve -ConflictId C5 -Serialize n999 1>`"$outC`" 2>`"$errC`" "
$codeC = $LASTEXITCODE
Write-Output "=== fix-verify C (failure visibility, bogus node) exit=$codeC ==="
Write-Output "stdout bytes=$((Get-Item $outC).Length): $(Get-Content $outC -Raw -Encoding UTF8)"
Write-Output "stderr bytes=$((Get-Item $errC).Length): $(Get-Content $errC -Raw -Encoding UTF8)"
Write-Output "roots: A=$root B=$root2 C=$root3"

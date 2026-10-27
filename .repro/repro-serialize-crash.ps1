# Repro: delivery-bridge "conflict resolve -Serialize" silent death (exit 1, 0-byte both streams)
# Isolation: read-only copy of the live run into a TEMP scratch repo pinned via RDD_PROJECT_ROOT.
# The demo project is NEVER written (archive pointer repointed into the scratch copy).
$ErrorActionPreference = 'Continue'

$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$root     = Join-Path $env:TEMP ("rdd-serial-repro-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force

# 1) copy run dir (read-only source)
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
# 2) copy archive (ledger writes must stay inside scratch)
Copy-Item -LiteralPath "$demoRoot\.rdd\changes\archive\2026-10-26-level-mode-optimization" -Destination (Join-Path $root 'archive') -Recurse

# 3) patch scratch bridge.json: repoint archive + inject an OPEN C3 entry (same shape as C2's open state)
$bjPath = Join-Path $root ".rdd/goal-trees/$runId/bridge.json"
$bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
$bj.archive = (Join-Path $root 'archive')
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$c3 = [ordered]@{
    id = 'C3'; kind = 'file'; nodes = @('n13', 'n15', 'n16'); tasks = @(1, 4, 3)
    files = @('assets/scripts/core/level/config.ts', 'assets/scripts/core/level/types.ts', 'assets/scripts/core/level/level-session.ts', 'assets/scripts/level/LevelScene.ts')
    detected_by = 'planner'; status = 'open'; note = 'repro inject'; escalation = $null; ruling = $null; serialize = $null
    created_at = $now; updated_at = $now; history = @(@{ at = $now; action = 'open'; note = 'repro inject' })
}
$bj.conflicts = @($bj.conflicts) + $c3
[System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))

# 4) mirror the original planner session identity + pin the data plane into scratch
$env:RDD_PROJECT_ROOT = $root
$env:DSH_SESSION_ID   = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'

# 5) replay the exact failing command via the .cmd wrapper (cmd-layer per-stream file capture)
$outF = Join-Path $root 'stdout.txt'; $errF = Join-Path $root 'stderr.txt'
$bridgeCmd = Join-Path $engDir 'delivery-bridge.cmd'
$argLine = "-Command conflict -RunId $runId -Action resolve -ConflictId C3 -Serialize n13"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = & cmd /c " `"$bridgeCmd`" $argLine 1>`"$outF`" 2>`"$errF`" "
$code = $LASTEXITCODE
$sw.Stop()
Write-Output "=== variant A (wrapper, no -Ruling) exit=$code elapsedMs=$($sw.ElapsedMilliseconds) ==="
Write-Output ("stdout bytes={0}: {1}" -f (Get-Item $outF).Length, (Get-Content $outF -Raw -Encoding UTF8))
Write-Output ("stderr bytes={0}: {1}" -f (Get-Item $errF).Length, (Get-Content $errF -Raw -Encoding UTF8))

# 6) what landed in the scratch copy?
$dl = Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"
Write-Output "deps-log exists: $(Test-Path $dl)"
$tj = Get-Content (Join-Path $root ".rdd/goal-trees/$runId/state/tree.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$n15 = @($tj.nodes | Where-Object { $_.id -eq 'n15' })[0]
Write-Output "n15.depends_on: [$(@($n15.depends_on) -join ',')]"
$nb = Get-Content $bjPath -Raw -Encoding UTF8 | ConvertFrom-Json
$c3after = @($nb.conflicts | Where-Object { $_.id -eq 'C3' })[0]
Write-Output "C3 status after: $($c3after.status)"
Write-Output "task2 dep_task_ids after: [$(@($nb.tasks.'2'.dep_task_ids) -join ',')]"
Write-Output "scratch root: $root"

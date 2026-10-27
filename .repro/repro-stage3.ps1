# Stage-3: transcript capture of the silent death (no engine code modified)
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"

$root = Join-Path $env:TEMP ("rdd-serial-repro-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    detected_by = 'planner'; status = 'open'; note = 'repro inject'; escalation = $null; ruling = $null; serialize = $null
    created_at = $now; updated_at = $now; history = @(@{ at = $now; action = 'open'; note = 'repro inject' })
}
$bj.conflicts = @($bj.conflicts) + $c3
[System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))

$env:RDD_PROJECT_ROOT = $root
$env:DSH_SESSION_ID   = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'

$tLog = Join-Path $root 'transcript.txt'
$inner = "Start-Transcript -Path '$tLog' | Out-Null; & '$engDir\delivery-bridge.ps1' -Command conflict -RunId $runId -Action resolve -ConflictId C3 -Serialize n13; Write-Output ('AFTER-SCRIPT exit=' + `$LASTEXITCODE)"
$out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $inner 2>&1 | Out-String
Write-Output "=== transcript-wrap outer exit=$LASTEXITCODE ==="
Write-Output "outer captured: [$($out.Trim())]"
Write-Output "=== transcript ($((Get-Item $tLog -ErrorAction SilentlyContinue).Length) bytes) tail 60 ==="
if (Test-Path $tLog) { Get-Content $tLog -Tail 60 | ForEach-Object { $_ } }
Write-Output "scratch root: $root"

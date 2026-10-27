# Stage-2 bisect of the -Serialize silent death. Modes: direct / child / catch
param([Parameter(Mandatory = $true)][string]$Mode)
$ErrorActionPreference = 'Continue'

$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"

function New-Scratch {
    param([bool]$InjectC3 = $true)
    $root = Join-Path $env:TEMP ("rdd-serial-repro-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
    Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
    Copy-Item -LiteralPath "$demoRoot\.rdd\changes\archive\2026-10-26-level-mode-optimization" -Destination (Join-Path $root 'archive') -Recurse
    $bjPath = Join-Path $root ".rdd/goal-trees/$runId/bridge.json"
    $bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
    $bj.archive = (Join-Path $root 'archive')
    if ($InjectC3) {
        $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $c3 = [ordered]@{
            id = 'C3'; kind = 'file'; nodes = @('n13', 'n15', 'n16'); tasks = @(1, 4, 3)
            files = @('assets/scripts/core/level/config.ts', 'assets/scripts/core/level/types.ts', 'assets/scripts/core/level/level-session.ts', 'assets/scripts/level/LevelScene.ts')
            detected_by = 'planner'; status = 'open'; note = 'repro inject'; escalation = $null; ruling = $null; serialize = $null
            created_at = $now; updated_at = $now; history = @(@{ at = $now; action = 'open'; note = 'repro inject' })
        }
        $bj.conflicts = @($bj.conflicts) + $c3
    }
    [System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
    return $root
}

function Show-Result {
    param([string]$Tag, [string]$OutF, [string]$ErrF, [int]$Code, [long]$Ms)
    Write-Output "=== $Tag exit=$code elapsedMs=$ms ==="
    Write-Output ("stdout bytes={0}: {1}" -f (Get-Item $OutF).Length, (Get-Content $OutF -Raw -Encoding UTF8))
    Write-Output ("stderr bytes={0}: {1}" -f (Get-Item $ErrF).Length, (Get-Content $ErrF -Raw -Encoding UTF8))
}

$env:DSH_SESSION_ID = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'

switch ($Mode) {
    'direct' {
        $root = New-Scratch $true
        $env:RDD_PROJECT_ROOT = $root
        $outF = Join-Path $root 'o.txt'; $errF = Join-Path $root 'e.txt'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$engDir\delivery-bridge.ps1`" -Command conflict -RunId $runId -Action resolve -ConflictId C3 -Serialize n13 1>`"$outF`" 2>`"$errF`" "
        $code = $LASTEXITCODE; $sw.Stop()
        Show-Result 'direct .ps1 (no wrapper)' $outF $errF $code $sw.ElapsedMilliseconds
        $dl = Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"
        Write-Output "deps-log exists: $(Test-Path $dl)  root: $root"
    }
    'child' {
        $root = New-Scratch $false
        $env:RDD_PROJECT_ROOT = $root
        $outF = Join-Path $root 'o.txt'; $errF = Join-Path $root 'e.txt'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & cmd /c " `"$engDir\goal-tree.cmd`" -Command deps -DepAction add -RunId $runId -NodeId n15 -On n13 1>`"$outF`" 2>`"$errF`" "
        $code = $LASTEXITCODE; $sw.Stop()
        Show-Result 'child goal-tree.cmd deps add standalone' $outF $errF $code $sw.ElapsedMilliseconds
        $dl = Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"
        Write-Output "deps-log exists: $(Test-Path $dl)  root: $root"
    }
    'catch' {
        $root = New-Scratch $true
        $env:RDD_PROJECT_ROOT = $root
        $inner = "try { & '$engDir\delivery-bridge.ps1' -Command conflict -RunId $runId -Action resolve -ConflictId C3 -Serialize n13 } catch { Write-Output ('CAUGHT:[' + `$_.Exception.GetType().FullName + '] ' + `$_.Exception.Message); exit 99 }"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $inner 2>&1 | Out-String
        $code = $LASTEXITCODE; $sw.Stop()
        Write-Output "=== catch-wrap exit=$code elapsedMs=$($sw.ElapsedMilliseconds) ==="
        Write-Output "captured: $($out.Trim())"
        $dl = Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"
        Write-Output "deps-log exists: $(Test-Path $dl)  root: $root"
    }
}

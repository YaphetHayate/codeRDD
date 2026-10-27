# Stage-11b: instrumented single resolve on installed engine with watchdog.
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$root = Join-Path $env:TEMP ("rdd-acc11b-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
$bjPath = Join-Path $root ".rdd/goal-trees/$runId/bridge.json"
$bj = [System.IO.File]::ReadAllText($bjPath) | ConvertFrom-Json
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$bj.conflicts = @($bj.conflicts) + ([ordered]@{
    id = 'C3'; kind = 'file'; nodes = @('n13','n15','n16'); tasks = @(1,4,3)
    files = @('assets/scripts/core/level/config.ts','assets/scripts/core/level/types.ts','assets/scripts/core/level/level-session.ts','assets/scripts/level/LevelScene.ts')
    detected_by = 'planner'; status = 'open'; note = 'instrumented'; escalation = $null; ruling = $null; serialize = $null
    created_at = $now; updated_at = $now; history = @()
})
[System.IO.File]::WriteAllText($bjPath, ($bj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "scratch: $root"

$env:RDD_PROJECT_ROOT = $root
$env:DSH_SESSION_ID   = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'
$env:DSH_WEB_URL      = 'http://127.0.0.1:1'   # dead URL first: exclude HTTP waits
$o = Join-Path $root 'o.txt'; $e = Join-Path $root 'e.txt'
$bridgeCmd = Join-Path $engDir 'delivery-bridge.cmd'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$job = Start-Job -ScriptBlock {
    param($bc, $rid, $oo, $ee)
    & cmd /c " `"$bc`" -Command conflict -RunId $rid -Action resolve -ConflictId C3 -Serialize n13 1>`"$oo`" 2>`"$ee`" "
    "child-exit: $LASTEXITCODE"
} -ArgumentList $bridgeCmd, $runId, $o, $e
$done = Wait-Job $job -Timeout 60
if ($null -eq $done) {
    Write-Output "HUNG >60s (dead DSH_WEB_URL). Child process tree:"
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match [regex]::Escape($root) -or $_.CommandLine -match 'delivery-bridge|goal-tree' } |
        Select-Object ProcessId, ParentProcessId, Name, CreationDate, @{n='Cmd';e={ $_.CommandLine.Substring(0, [Math]::Min(200, $_.CommandLine.Length)) }} | Format-Table -AutoSize -Wrap | Out-String -Width 240
    Stop-Job $job; Remove-Job $job -Force
    Write-Output "partial stdout:"; if (Test-Path $o) { Get-Content $o -Raw -Encoding UTF8 }
    Write-Output "partial stderr:"; if (Test-Path $e) { Get-Content $e -Raw -Encoding UTF8 }
} else {
    $r = Receive-Job $job; Remove-Job $job
    Write-Output ("completed in {0}ms  job said: {1}" -f $sw.ElapsedMilliseconds, ($r -join ' '))
    Write-Output "exit marker above; stdout:"; Get-Content $o -Raw -Encoding UTF8
    Write-Output "stderr:"; Get-Content $e -Raw -Encoding UTF8
}
# scratch state after
$treePath = Join-Path $root ".rdd/goal-trees/$runId/state/tree.json"
if (Test-Path $treePath) {
    $t = Get-Content $treePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($nid in 'n2','n7','n10') { $n = @($t.nodes | Where-Object { $_.id -eq $nid })[0]; Write-Output "tree $nid depends_on: [$(@($n.depends_on) -join ',')]" }
}
$b2 = Get-Content $bjPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output "C3 status: $(@($b2.conflicts | Where-Object { $_.id -eq 'C3' })[0].status)"
foreach ($tk in '3','4') { Write-Output "task$tk dep_task_ids: [$(@($b2.tasks.$tk.dep_task_ids) -join ',')]" }
Write-Output "deps-log exists: $(Test-Path (Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"))"

# Stage-4 (v2): probe-instrumented copy of delivery-bridge.ps1 (TEMP copy only — installed engine untouched)
$ErrorActionPreference = 'Stop'
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

$engCopy = Join-Path $root 'eng'
Copy-Item -LiteralPath $engDir -Destination $engCopy -Recurse
$ps1 = Join-Path $engCopy 'delivery-bridge.ps1'
$rawBytes = [System.IO.File]::ReadAllBytes($ps1)
$hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
Write-Output "original delivery-bridge.ps1 BOM: $hasBom  size: $($rawBytes.Length)"
$gtBytes = [System.IO.File]::ReadAllBytes((Join-Path $engCopy 'goal-tree.ps1'))
Write-Output "original goal-tree.ps1 BOM: $($gtBytes[0] -eq 0xEF -and $gtBytes[1] -eq 0xBB -and $gtBytes[2] -eq 0xBF)  size: $($gtBytes.Length)"
$text = [System.IO.File]::ReadAllText($ps1)
$CR = "`r`n"

function Patch([string]$Name, [string]$Old, [string]$New) {
    $cnt = [regex]::Matches($script:text, [regex]::Escape($Old)).Count
    if ($cnt -ne 1) { throw "anchor '$Name' count=$cnt (expected 1)" }
    $script:text = $script:text.Replace($Old, $New)
    Write-Output "patched: $Name"
}

Patch 'T0'  '$ErrorActionPreference = "Stop"' ('Write-Host ''T0 start''' + $CR + '$ErrorActionPreference = "Stop"')

$oldT12 = '    $null = Enter-PlannerLease $runDir' + $CR + '    $tree = Get-TreeStatusView $RunId'
$newT12 = '    $null = Enter-PlannerLease $runDir' + $CR + '    Write-Host ''T1 lease''' + $CR + '    $tree = Get-TreeStatusView $RunId' + $CR + '    Write-Host ''T2 treeview'''
Patch 'T1+T2' $oldT12 $newT12

Patch 'P1'  '        $earlier = $Serialize.Trim()' ('        $earlier = $Serialize.Trim()' + $CR + '        Write-Host (''P1 serialize-branch earlier='' + $earlier)')
Patch 'T4'  '        $serialized = @(Set-ConflictSerializeEdges $RunDir $RunId $Bridge $entry $earlier)' ('        Write-Host ''T4 pre-scse''' + $CR + '        $serialized = @(Set-ConflictSerializeEdges $RunDir $RunId $Bridge $entry $earlier)')

$oldT5 = '    $others = @(@($Entry[''nodes'']) | Where-Object { ([string]$_) -ne $Earlier })'
Patch 'T5'  $oldT5 ($oldT5 + $CR + '    Write-Host (''T5 others=['' + ($others -join '','') + '']'')')

$oldT6 = '        $r = Invoke-GoalTree @("-Command", "deps", "-DepAction", "add", "-RunId", $RunIdText, "-NodeId", ([string]$later), "-On", $Earlier)'
$newT6 = '        Write-Host ''T6 pre-child later=$later''' + $CR + $oldT6 + $CR + '        Write-Host (''T7 post-child exit='' + $r.exit + '' len='' + $r.text.Length)'
Patch 'T6+T7' $oldT6 $newT6

$oldT8 = '                Write-ErrorResult "CONFLICT_ENTRY_INVALID" "serializing $later -> $Earlier failed (conflict stays OPEN): $($r.text)" 1'
Patch 'T8'  $oldT8 ('                Write-Host (''T8 pre-WER depCode='' + $depCode)' + $CR + $oldT8)

$oldW = '        [int]$ExitCode = 1' + $CR + '    )' + $CR + '    ConvertTo-PortableJson @{'
$newW = '        [int]$ExitCode = 1' + $CR + '    )' + $CR + '    Write-Host (''W1 wer-body code='' + $Code + '' msgLen='' + $Message.Length)' + $CR + '    ConvertTo-PortableJson @{'
Patch 'W1' $oldW $newW

Patch 'J1'  '    param($Object, [int]$Depth = 6)' ('    param($Object, [int]$Depth = 6)' + $CR + '    Write-Host ''J1 cpj-enter''')
Patch 'J2'  '    return ($Object | ConvertTo-Json -Depth $Depth -Compress)' ('    $converted = ($Object | ConvertTo-Json -Depth $Depth -Compress)' + $CR + '    Write-Host (''J2 cpj-converted len='' + $converted.Length)' + $CR + '    return $converted')

$oldT9b = '        error   = @{ code = $Code; message = $Message }' + $CR + '    } -Depth 3'
Patch 'T9b' $oldT9b ($oldT9b + $CR + '    Write-Host ''T9b wer-printed''')

Patch 'T10' 'ConvertTo-PortableJson $result -Depth 14' ('Write-Host ''T10 final''' + $CR + 'ConvertTo-PortableJson $result -Depth 14')

$oldCli = '    try {' + $CR + '        $output = & $Script @ArgList 2>$null' + $CR + '        $exitCode = $LASTEXITCODE' + $CR + '    }' + $CR + '    finally {' + $CR + '        $ErrorActionPreference = $prevEap' + $CR + '    }'
$newCli = '    Write-Host (''C1 cli-pre script='' + $Script) ' + $CR + '    try {' + $CR + '        $output = & $Script @ArgList 2>$null' + $CR + '        Write-Host (''C2 cli-post-native exit='' + $LASTEXITCODE) ' + $CR + '        $exitCode = $LASTEXITCODE' + $CR + '    }' + $CR + '    finally {' + $CR + '        $ErrorActionPreference = $prevEap' + $CR + '    }' + $CR + '    Write-Host (''C3 cli-post-finally exit='' + $exitCode + '' lines='' + @($output).Count)'
Patch 'CLI' $oldCli $newCli

[System.IO.File]::WriteAllText($ps1, $text, (New-Object System.Text.UTF8Encoding($true)))
Write-Output "patched copy ready: $ps1"

$env:RDD_PROJECT_ROOT = $root
$env:DSH_SESSION_ID   = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'
$outF = Join-Path $root 'o.txt'; $errF = Join-Path $root 'e.txt'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = & cmd /c " `"$root\eng\delivery-bridge.cmd`" -Command conflict -RunId $runId -Action resolve -ConflictId C3 -Serialize n13 1>`"$outF`" 2>`"$errF`" "
$code = $LASTEXITCODE; $sw.Stop()
Write-Output "=== instrumented exit=$code elapsedMs=$($sw.ElapsedMilliseconds) ==="
Write-Output ("stdout: {0}" -f (Get-Content $outF -Raw -Encoding UTF8))
Write-Output ("stderr: {0}" -f (Get-Content $errF -Raw -Encoding UTF8))
$dl = Join-Path $root ".rdd/goal-trees/$runId/state/deps-log.jsonl"
Write-Output "deps-log exists: $(Test-Path $dl)  root: $root"

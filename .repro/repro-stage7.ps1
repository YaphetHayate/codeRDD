# Stage-7: assignment-capture + exit, and the in-engine control error path
$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:TEMP ('rdd-matrix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $dir -Force

# M7: bare vs assignment-captured emit+exit
$f7 = @'
function f { 'X-OUTPUT'; exit 1 }
$x = f
'@
[System.IO.File]::WriteAllText((Join-Path $dir 'm7.ps1'), $f7, (New-Object System.Text.UTF8Encoding($true)))

# M8: assignment-captured, nested in switch, after failed native child
$f8 = @'
$ErrorActionPreference = 'Stop'
function WER {
    param([string]$C, [string]$M, [int]$E = 1)
    @{ success = $false; error = @{ code = $C; message = $M } } | ConvertTo-Json -Depth 3 -Compress
    exit $E
}
function Deep {
    $out = & cmd /c "exit 1" 2>$null
    if ($LASTEXITCODE -ne 0) { WER 'C' "failed: $out" 1 }
    return 'never'
}
switch ('go') {
    'go' { $result = Deep }
}
ConvertTo-Json $result
'@
[System.IO.File]::WriteAllText((Join-Path $dir 'm8.ps1'), $f8, (New-Object System.Text.UTF8Encoding($true)))

foreach ($n in 'm7', 'm8') {
    $f = Join-Path $dir "$n.ps1"; $o = Join-Path $dir "$n.out"; $e = Join-Path $dir "$n.err"
    $null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f`" 1>`"$o`" 2>`"$e`" "
    $outTxt = (Get-Content $o -Raw -ErrorAction SilentlyContinue); if ($null -eq $outTxt) { $outTxt = '' }
    $errTxt = (Get-Content $e -Raw -ErrorAction SilentlyContinue); if ($null -eq $errTxt) { $errTxt = '' }
    Write-Output ("{0} exit={1} out=[{2}] err=[{3}]" -f $n.ToUpper(), $LASTEXITCODE, $outTxt.Trim(), $errTxt.Trim())
}

# Control: same engine, same sink, KNOWN error path (CONFLICT_NOT_FOUND) must print JSON
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$root = Join-Path $env:TEMP ("rdd-serial-repro-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
$env:RDD_PROJECT_ROOT = $root
$env:DSH_SESSION_ID = 'session-c65ffe23-d85a-4cb9-b98e-a1bc14d302ff'
$o = Join-Path $root 'ctl.out'; $e = Join-Path $root 'ctl.err'
$null = & cmd /c " `"$engDir\delivery-bridge.cmd`" -Command conflict -RunId $runId -Action resolve -ConflictId C99 1>`"$o`" 2>`"$e`" "
Write-Output ("CTL CONFLICT_NOT_FOUND exit={0} out=[{1}] err=[{2}]" -f $LASTEXITCODE, (Get-Content $o -Raw -ErrorAction SilentlyContinue), (Get-Content $e -Raw -ErrorAction SilentlyContinue))
Write-Output "matrix dir: $dir"

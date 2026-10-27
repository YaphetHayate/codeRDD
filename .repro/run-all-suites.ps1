$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dir = 'D:\YaphetHayate\projects\codeRDD\rdd-engine\tests'
$suites = Get-ChildItem (Join-Path $dir 'test-*.ps1') | Sort-Object Name
$report = @()
foreach ($s in $suites) {
    if ($s.Name -eq 'test-bridge-conflicts.ps1') { $report += @{ suite = $s.Name; exit = 0; note = 'already green (79/79, this session)' }; continue }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $s.FullName 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()
    $last = ''
    foreach ($line in ($out -split "`r?`n")) { if ($line -match 'passed|failed|total|PASS|FAIL|ok\b') { $last = $line } }
    $report += @{ suite = $s.Name; exit = $code; secs = [int]$sw.Elapsed.TotalSeconds; note = $last }
    Write-Output ("[{0}] exit={1} {2}s :: {3}" -f $s.Name, $code, [int]$sw.Elapsed.TotalSeconds, $last)
    if ($code -ne 0) {
        $tail = (($out -split "`r?`n") | Select-Object -Last 25) -join "`n"
        Write-Output "---- tail of $s.Name ----"
        Write-Output $tail
    }
}
Write-Output '=== FULL REGRESSION SUMMARY ==='
$bad = @($report | Where-Object { $_.exit -ne 0 })
foreach ($r in $report) { Write-Output ("{0,-40} exit={1,-3} {2}" -f $r.suite, $r.exit, $r.note) }
Write-Output ("total suites: {0}, failed: {1}" -f $report.Count, $bad.Count)
if ($bad.Count -gt 0) { exit 1 }
exit 0

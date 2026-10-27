# Stage-5: isolate the exact Write-ErrorResult death — no engine files touched
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$runId    = 'deliver-2026-10-26-level-mode-optimization'

# fresh scratch for the child to mutate safely
$root = Join-Path $env:TEMP ("rdd-serial-repro-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse
$env:RDD_PROJECT_ROOT = $root
Write-Output "scratch: $root"

# --- exact Invoke-EngineCli replica ---
$Script = Join-Path $engDir 'goal-tree.cmd'
$ArgList = @('-Command', 'deps', '-DepAction', 'add', '-RunId', $runId, '-NodeId', 'n15', '-On', 'n13')
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$output = $null
$exitCode = 0
try {
    $output = & $Script @ArgList 2>$null
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $prevEap
}
$text = ($output | Out-String).Trim()
$json = $null
if ($text) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
Write-Output "child exit=$exitCode textLen=$($text.Length) jsonNull=$($null -eq $json)"

$depCode = ''
if ($null -ne $json -and $null -ne $json.error) { $depCode = [string]$json.error.code }
Write-Output "depCode=[$depCode]"

if ($depCode -ne 'DEP_EXISTS') {
    Write-Output "A: entering WER replica"
    $Code = 'CONFLICT_ENTRY_INVALID'
    $Message = "serializing n15 -> n13 failed (conflict stays OPEN): $text"
    $ExitCode = 1
    Write-Output "B: params bound, messageLen=$($Message.Length)"
    $obj = @{ success = $false; error = @{ code = $Code; message = $Message } }
    Write-Output "C: obj built"
    $s = ConvertTo-Json -InputObject $obj -Depth 3 -Compress
    Write-Output "D: converted, len=$($s.Length)"
    Write-Output $s
    Write-Output "E: emitted, now exit"
    exit 1
}
Write-Output "F: unexpected branch"

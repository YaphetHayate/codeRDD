# Stage-8: M9 hybrid — @(subexpression) capture + real failed child + WER
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$dir = Join-Path $env:TEMP ('rdd-matrix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $dir -Force

# fresh scratch for the child to mutate
$root = Join-Path $dir 'scratch'
$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse

$m9 = @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
function ConvertTo-PortableJson { param($Object, [int]$Depth = 6) return ($Object | ConvertTo-Json -Depth $Depth -Compress) }
function Write-ErrorResult {
    param([string]$Code, [string]$Message, [int]$ExitCode = 1)
    ConvertTo-PortableJson @{ success = $false; error = @{ code = $Code; message = $Message } } -Depth 3
    exit $ExitCode
}
function Invoke-EngineCli {
    param([string]$Script, [string[]]$ArgList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
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
    return @{ exit = $exitCode; text = $text; json = $json }
}
function Invoke-GoalTree { param([string[]]$A) Invoke-EngineCli ('ENGDIR\goal-tree.cmd') $A }
function Set-ConflictSerializeEdges {
    param([string]$RunIdText, [string]$Earlier)
    $others = @('n15', 'n16')
    $added = @()
    foreach ($later in $others) {
        $r = Invoke-GoalTree @("-Command", "deps", "-DepAction", "add", "-RunId", $RunIdText, "-NodeId", ([string]$later), "-On", $Earlier)
        if ($r.exit -ne 0 -or $null -eq $r.json -or -not $r.json.success) {
            $depCode = ''
            if ($null -ne $r.json -and $null -ne $r.json.error) { $depCode = [string]$r.json.error.code }
            if ($depCode -ne 'DEP_EXISTS') {
                Write-ErrorResult "CONFLICT_ENTRY_INVALID" "serializing $later -> $Earlier failed (conflict stays OPEN): $($r.text)" 1
            }
            $added += "$later->$Earlier (idempotent)"
        }
        else {
            $added += "$later->$Earlier"
        }
    }
    return $added
}
switch ('conflict') {
    'conflict' {
        $serialized = @(Set-ConflictSerializeEdges 'RUNID' 'n13')
        $result = @{ success = $true; data = @{ serialized = $serialized } }
    }
}
ConvertTo-PortableJson $result -Depth 14
exit 0
'@
$m9 = $m9.Replace('ENGDIR', $engDir).Replace('RUNID', $runId)
$m9f = Join-Path $dir 'm9.ps1'
[System.IO.File]::WriteAllText($m9f, $m9, (New-Object System.Text.UTF8Encoding($true)))

$env:RDD_PROJECT_ROOT = $root
$o = Join-Path $dir 'm9.out'; $e = Join-Path $dir 'm9.err'
$null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$m9f`" 1>`"$o`" 2>`"$e`" "
Write-Output ("M9 exit={0}" -f $LASTEXITCODE)
Write-Output ("M9 out=[{0}]" -f (Get-Content $o -Raw -ErrorAction SilentlyContinue))
Write-Output ("M9 err=[{0}]" -f (Get-Content $e -Raw -ErrorAction SilentlyContinue))
Write-Output "dir: $dir"

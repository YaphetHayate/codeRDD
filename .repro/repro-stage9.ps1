# Stage-9: minimize M9 — one-factor-at-a-time variants
$ErrorActionPreference = 'Continue'
$demoRoot = 'D:\YaphetHayate\projects\demo\ProtectTheCats\ProtectTheCats'
$engDir   = "$demoRoot\.rdd\skills\rdd-engine\scripts"
$runId    = 'deliver-2026-10-26-level-mode-optimization'
$dir = Join-Path $env:TEMP ('rdd-matrix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $dir -Force
$root = Join-Path $dir 'scratch'
$null = New-Item -ItemType Directory -Path (Join-Path $root '.rdd/goal-trees') -Force
Copy-Item -LiteralPath "$demoRoot\.rdd\goal-trees\$runId" -Destination (Join-Path $root ".rdd/goal-trees/$runId") -Recurse

# synthetic .cmd child: writes one JSON-ish line to stdout, exits 1
$miniCmd = Join-Path $dir 'minichild.cmd'
[System.IO.File]::WriteAllText($miniCmd, "@echo off`r`necho {""error"":{""code"":""X""}}`r`nexit /b 1", (New-Object System.Text.UTF8Encoding($false)))

$tmpl = @'
$ErrorActionPreference = 'Stop'
function Write-ErrorResult {
    param([string]$Code, [string]$Message, [int]$ExitCode = 1)
    @{ success = $false; error = @{ code = $Code; message = $Message } } | ConvertTo-Json -Depth 3 -Compress
    exit $ExitCode
}
function Set-Edges {
    param([string]$Child)
    $out = & $Child 2>$null
    $code = $LASTEXITCODE
    foreach ($later in @('n15')) {
        if ($code -ne 0) {
            Write-ErrorResult 'C' "failed: $out" 1
        }
    }
    return @('edge')
}
switch ('conflict') {
    'conflict' { $serialized = @(Set-Edges 'CHILD') }
}
'switch-done'
exit 0
'@

function Run-Variant([string]$Name, [string]$ChildPath) {
    $f = Join-Path $script:dir ($Name + '.ps1')
    [System.IO.File]::WriteAllText($f, ($script:tmpl.Replace('CHILD', $ChildPath)), (New-Object System.Text.UTF8Encoding($true)))
    $o = Join-Path $script:dir ($Name + '.out'); $e = Join-Path $script:dir ($Name + '.err')
    $null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f`" 1>`"$o`" 2>`"$e`" "
    $out = (Get-Content $o -Raw -ErrorAction SilentlyContinue); if ($null -eq $out) { $out = '' }
    $err = (Get-Content $e -Raw -ErrorAction SilentlyContinue); if ($null -eq $err) { $err = '' }
    Write-Output ("{0,-22} exit={1} out=[{2}] err=[{3}]" -f $Name, $LASTEXITCODE, $out.Trim(), $err.Trim())
}

$env:RDD_PROJECT_ROOT = $root
Run-Variant 'V1-minicmd'    $miniCmd
Run-Variant 'V2-realcmd'    (Join-Path $engDir 'goal-tree.cmd')

# V3: real child but deps LIST (exit 0) — child succeeds, WER not hit, prints switch-done
$tmpl3 = $tmpl.Replace("if (`$code -ne 0) {", "if (`$code -eq 999) {").Replace("Set-Edges 'CHILD'", "Set-Edges 'CHILDARGS'")
$tmpl3 = @'
$ErrorActionPreference = 'Stop'
function Set-Edges {
    param([string[]]$ChildArgs)
    $out = & 'REALCMD' @ChildArgs 2>$null
    $code = $LASTEXITCODE
    foreach ($later in @('n15')) {
        if ($code -ne 0) {
            @{ success = $false; error = @{ code = 'C'; message = "failed: $out" } } | ConvertTo-Json -Depth 3 -Compress
            exit 1
        }
    }
    return @('edge')
}
switch ('conflict') {
    'conflict' { $serialized = @(Set-Edges @('-Command','status','-RunId','RUNID')) }
}
'switch-done'
exit 0
'@
$tmpl3 = $tmpl3.Replace('REALCMD', (Join-Path $engDir 'goal-tree.cmd')).Replace('RUNID', $runId)
$f3 = Join-Path $dir 'V3-childok.ps1'
[System.IO.File]::WriteAllText($f3, $tmpl3, (New-Object System.Text.UTF8Encoding($true)))
$o3 = Join-Path $dir 'V3.out'; $e3 = Join-Path $dir 'V3.err'
$null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f3`" 1>`"$o3`" 2>`"$e3`" "
Write-Output ("{0,-22} exit={1} out=[{2}] err=[{3}]" -f 'V3-childok(status)', $LASTEXITCODE, ((Get-Content $o3 -Raw -ErrorAction SilentlyContinue) + '').Trim(), ((Get-Content $e3 -Raw -ErrorAction SilentlyContinue) + '').Trim())

# V4: real FAILING child, but hoist WER OUT of the @() — set flag inside, emit after
$tmpl4 = @'
$ErrorActionPreference = 'Stop'
function Set-Edges {
    param([string[]]$ChildArgs)
    $out = & 'REALCMD' @ChildArgs 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) { return @{ fail = $true; text = $out } }
    return @{ fail = $false }
}
$serialized = @(Set-Edges @('-Command','deps','-DepAction','add','-RunId','RUNID','-NodeId','n15','-On','n13'))
if ($serialized[0].fail) {
    @{ success = $false; error = @{ code = 'C'; message = "failed: $($serialized[0].text)" } } | ConvertTo-Json -Depth 3 -Compress
    exit 1
}
'@
$tmpl4 = $tmpl4.Replace('REALCMD', (Join-Path $engDir 'goal-tree.cmd')).Replace('RUNID', $runId)
$f4 = Join-Path $dir 'V4-hoisted.ps1'
[System.IO.File]::WriteAllText($f4, $tmpl4, (New-Object System.Text.UTF8Encoding($true)))
$o4 = Join-Path $dir 'V4.out'; $e4 = Join-Path $dir 'V4.err'
$null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f4`" 1>`"$o4`" 2>`"$e4`" "
Write-Output ("{0,-22} exit={1} out=[{2}] err=[{3}]" -f 'V4-hoisted-WER', $LASTEXITCODE, ((Get-Content $o4 -Raw -ErrorAction SilentlyContinue) + '').Trim(), ((Get-Content $e4 -Raw -ErrorAction SilentlyContinue) + '').Trim())

# V5: real failing child, WER inside @() but WITHOUT switch wrapper
$tmpl5 = @'
$ErrorActionPreference = 'Stop'
function Set-Edges {
    param([string[]]$ChildArgs)
    $out = & 'REALCMD' @ChildArgs 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        @{ success = $false; error = @{ code = 'C'; message = "failed: $out" } } | ConvertTo-Json -Depth 3 -Compress
        exit 1
    }
    return @('edge')
}
$serialized = @(Set-Edges @('-Command','deps','-DepAction','add','-RunId','RUNID','-NodeId','n15','-On','n13'))
'never'
'@
$tmpl5 = $tmpl5.Replace('REALCMD', (Join-Path $engDir 'goal-tree.cmd')).Replace('RUNID', $runId)
$f5 = Join-Path $dir 'V5-noswitch.ps1'
[System.IO.File]::WriteAllText($f5, $tmpl5, (New-Object System.Text.UTF8Encoding($true)))
$o5 = Join-Path $dir 'V5.out'; $e5 = Join-Path $dir 'V5.err'
$null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f5`" 1>`"$o5`" 2>`"$e4`" " 2>$null
$null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f5`" 1>`"$o5`" 2>`"$e5`" "
Write-Output ("{0,-22} exit={1} out=[{2}] err=[{3}]" -f 'V5-noswitch', $LASTEXITCODE, ((Get-Content $o5 -Raw -ErrorAction SilentlyContinue) + '').Trim(), ((Get-Content $e5 -Raw -ErrorAction SilentlyContinue) + '').Trim())
Write-Output "dir: $dir"

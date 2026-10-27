# Stage-6 matrix: when does PS 5.1 `exit` discard pending pipeline output?
# Each variant is a self-contained mini .ps1 run under cmd /c with 1>file redirect (same sink as the dying engine).
$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:TEMP ('rdd-matrix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $dir -Force

$variants = [ordered]@{
    'M1-func-exit'            = @'
function f { 'X-OUTPUT'; exit 1 }
f
'@
    'M2-func-exit-after-child' = @'
$null = & cmd /c "exit 1"
function f { 'X-OUTPUT'; exit 1 }
f
'@
    'M3-func-exit-child-2null' = @'
$null = & cmd /c "exit 1" 2>$null
function f { 'X-OUTPUT'; exit 1 }
f
'@
    'M4-deep-foreach-like-engine' = @'
$ErrorActionPreference = 'Stop'
function Inner {
    $out = & cmd /c "exit 1" 2>$null
    $code = $LASTEXITCODE
    foreach ($x in @('a')) {
        if ($code -ne 0) {
            WriteMid "serializing $x failed: $out"
        }
    }
}
function WriteMid {
    param([string]$Msg)
    EmitJson @{ success = $false; error = @{ code = 'C'; message = $Msg } }
    exit 1
}
function EmitJson { param($o) ($o | ConvertTo-Json -Depth 3 -Compress) }
Inner
'@
    'M5-toplevel-exit'        = @'
'X-OUTPUT'
exit 1
'@
    'M6-writehost-func-exit'  = @'
function f { Write-Host 'X-HOST'; 'X-OUTPUT'; exit 1 }
f
'@
}

foreach ($kv in $variants.GetEnumerator()) {
    $f = Join-Path $dir ($kv.Key + '.ps1')
    [System.IO.File]::WriteAllText($f, $kv.Value, (New-Object System.Text.UTF8Encoding($true)))
    $o = Join-Path $dir ($kv.Key + '.out'); $e = Join-Path $dir ($kv.Key + '.err')
    $null = & cmd /c " powershell -NoProfile -ExecutionPolicy Bypass -File `"$f`" 1>`"$o`" 2>`"$e`" "
    $code = $LASTEXITCODE
    $outTxt = (Get-Content $o -Raw -ErrorAction SilentlyContinue); if ($null -eq $outTxt) { $outTxt = '' }
    $errTxt = (Get-Content $e -Raw -ErrorAction SilentlyContinue); if ($null -eq $errTxt) { $errTxt = '' }
    Write-Output ("{0,-32} exit={1} out=[{2}] err=[{3}]" -f $kv.Key, $code, $outTxt.Trim(), $errTxt.Trim())
}
Write-Output "matrix dir: $dir"

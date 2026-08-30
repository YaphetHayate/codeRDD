# AST-based quantified review (re-check after DEV fix)
$files = @(
    'rdd-engine\scripts\explore.ps1',
    'rdd-engine\scripts\explore-store.ps1',
    'rdd-engine\scripts\recallers\lexical.ps1',
    'rdd-engine\scripts\recallers\vector.ps1'
)
foreach ($f in $files) {
    $path = (Resolve-Path $f).Path
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
    $text = [System.IO.File]::ReadAllLines($path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $funcs = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    Write-Output ("=== {0} :: BOM={1} :: syntaxErrors={2} ===" -f $f, $hasBom, $errs.Count)
    foreach ($fn in $funcs) {
        $start = $fn.Extent.StartLineNumber; $end = $fn.Extent.EndLineNumber
        $count = 0
        for ($i = $start; $i -le $end; $i++) {
            $trimmed = $text[$i - 1].Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
            if ($trimmed.StartsWith('<#')) {
                $j = $i
                while ($j -le $end -and $text[$j - 1] -notmatch '#>') { $j++ }
                $i = $j; continue
            }
            $count++
        }
        $flag = if ($count -gt 40) { ' <-- OVER 40' } else { '' }
        Write-Output ("  {0,-32} lines {1,3}{2}" -f $fn.Name, $count, $flag)
    }
}

# qa-metric-verify.ps1 — QA independent boundary probes for code-metrics
# (archive 2026-09-24-qa-metric-tooling, verification mode)
#
# QA independence rule: these samples are authored by QA from the requirement
# acceptance criteria (boundary-value analysis), NOT reusing DEV fixtures.
# All samples are plain ASCII so the generator stays PS5.1-safe; the probe
# drives the production interpreter (Windows PowerShell 5.1) like DEV's suite.
#
# Covered calibers (requirement AC-1/2/3/4 + boundaries):
#   - net lines subtract comments/blanks (75 physical -> 40 net stays silent)
#   - threshold boundary: exactly 50 net lines silent, 51 reported (> rule)
#   - nesting boundary: 5-level chain silent, 6-level reported; top level = 1
#   - do-while/do-until merge into the while family; switch NOT counted
#   - elseif clause annotation on the if ancestor
#   - determinism: byte-identical repeat; -Files no-baseline marker; exit codes

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$ToolPs1 = Join-Path (Join-Path $EngineDir 'rdd-engine') 'scripts\code-metrics.ps1'
if (-not (Test-Path -LiteralPath $ToolPs1)) { throw "code-metrics.ps1 not found at $ToolPs1" }
$Work = Join-Path $env:TEMP ('qa-metric-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Metrics { param([string[]]$ArgList, [string]$Cwd)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolPs1) + $ArgList
    $prev = (Get-Location).ProviderPath
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Set-Location -LiteralPath $Cwd
    try {
        $out = & powershell @all 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
        Set-Location -LiteralPath $prev
    }
    return @{ exit = $code; raw = $out }
}

function Write-Sample { param([string]$Name, [string]$Text)
    $path = Join-Path $Work $Name
    [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function New-LineBody { param([int]$Count)
    $lines = @()
    for ($i = 1; $i -le $Count; $i++) { $lines += ('    $value{0:d2} = {1}' -f $i, $i) }
    return ($lines -join "`r`n")
}

function New-IfChain { param([int]$Levels)
    $open = @()
    for ($i = 0; $i -lt $Levels; $i++) { $open += ('    ' * ($i + 1)) + 'if ($true) {' }
    $body = ('    ' * ($Levels + 1)) + '$hit = 1'
    $close = @()
    for ($i = $Levels; $i -ge 1; $i--) { $close += ('    ' * $i) + '}' }
    return (($open + $body + $close) -join "`r`n")
}

function New-DoWhileChain { param([int]$Levels)
    $open = @()
    for ($i = 0; $i -lt $Levels; $i++) { $open += ('    ' * ($i + 1)) + 'do {' }
    $body = ('    ' * ($Levels + 1)) + '$hit = 1'
    $close = @()
    for ($i = $Levels; $i -ge 1; $i--) { $close += ('    ' * $i) + '} while ($false)' }
    return (($open + $body + $close) -join "`r`n")
}

function New-SwitchChain { param([int]$Levels)
    $open = @()
    for ($i = 0; $i -lt $Levels; $i++) {
        $open += ('    ' * ($i + 1)) + 'switch (1) {'
        $open += ('    ' * ($i + 2)) + '1 {'
    }
    $body = ('    ' * ($Levels + 3)) + '$hit = 1'
    $close = @()
    for ($i = $Levels; $i -ge 1; $i--) {
        $close += ('    ' * ($i + 2)) + '}'
        $close += ('    ' * ($i + 1)) + '}'
    }
    return (($open + $body + $close) -join "`r`n")
}

try {
    New-Item -ItemType Directory -Path $Work -Force | Out-Null

    # ---- sample: exactly 50 net lines (declaration + 48 body + closing brace)
    $fifty = "function Test-ExactFifty {`r`n" + (New-LineBody 48) + "`r`n}"
    $null = Write-Sample 'exact-fifty.ps1' $fifty

    # ---- sample: 51 net lines (declaration + 49 body + closing brace)
    $fiftyOne = "function Test-FiftyOne {`r`n" + (New-LineBody 49) + "`r`n}"
    $null = Write-Sample 'fifty-one.ps1' $fiftyOne

    # ---- samples: 5-level vs 6-level if chains
    $null = Write-Sample 'nest-five.ps1' ("function Test-NestFive {`r`n" + (New-IfChain 5) + "`r`n}")
    $null = Write-Sample 'nest-six.ps1' ("function Test-NestSix {`r`n" + (New-IfChain 6) + "`r`n}")

    # ---- sample: 75 physical lines but 40 net (35 comment/blank interleaved)
    $chunk = @()
    for ($i = 1; $i -le 38; $i++) {
        $chunk += ('    $padded{0:d2} = {1}' -f $i, $i)
        $chunk += '    # trivia comment line that must not count toward net lines'
        if ($i % 2 -eq 0) { $chunk += '' }
    }
    $heavy = "function Test-CommentHeavy {`r`n" + ($chunk -join "`r`n") + "`r`n}"
    $null = Write-Sample 'comment-heavy.ps1' $heavy

    # ---- samples: do-while family and switch exclusion
    $null = Write-Sample 'do-while-deep.ps1' ("function Test-DoWhileSix {`r`n" + (New-DoWhileChain 6) + "`r`n}")
    $null = Write-Sample 'switch-deep.ps1' ("function Test-SwitchDeep {`r`n" + (New-SwitchChain 6) + "`r`n}")

    # ---- sample: 6-level chain entered through an elseif clause
    $innerLines = (New-IfChain 5) -split "`r`n"
    $shifted = @($innerLines | ForEach-Object { '    ' + $_ })
    $elseifFn = @(
        'function Test-ElseifSix {'
        '    if ($false) {'
        '        $early = 1'
        '    } elseif ($true) {'
    ) + $shifted + @(
        '    }'
        '}'
    )
    $null = Write-Sample 'elseif-deep.ps1' ($elseifFn -join "`r`n")

    $allFiles = 'exact-fifty.ps1,fifty-one.ps1,nest-five.ps1,nest-six.ps1,comment-heavy.ps1,do-while-deep.ps1,switch-deep.ps1,elseif-deep.ps1'
    $cleanFiles = 'exact-fifty.ps1,nest-five.ps1,comment-heavy.ps1,switch-deep.ps1'

    # ---------- Q1/Q2: violation set -> exit 1, 51-line boundary reported ----------
    $r1 = Invoke-Metrics @('-Command', 'scan', '-Files', $allFiles) $Work
    Assert-True ($r1.exit -eq 1) 'Q1 exit 1 when boundary violations exist' ("exit=$($r1.exit)")
    Assert-True ($r1.raw -match 'fifty-one\.ps1:L\d+ \| Test-FiftyOne \| #4 函数行数 \| 51') 'Q2 51-net-line function reported with file:line + name + value' ($r1.raw)

    # ---------- Q3: exactly 50 net lines stays silent (rule is > threshold) ----------
    Assert-True ($r1.raw -notmatch 'Test-ExactFifty') 'Q3 exactly-50 net-line function not reported' ($r1.raw)

    # ---------- Q4/Q5: nesting boundary 5 vs 6 ----------
    Assert-True ($r1.raw -match 'nest-six\.ps1:L\d+ \| Test-NestSix \| #5 嵌套深度 \| 6 \| 无基线 \| (if|loop)@L\d+( -> (if|loop)@L\d+){5}') 'Q4 6-level chain reported with 6-segment path + no-baseline cell' ($r1.raw)
    Assert-True ($r1.raw -notmatch 'Test-NestFive') 'Q5 5-level chain not reported' ($r1.raw)

    # ---------- Q6: comment/blank subtraction caliber ----------
    Assert-True ($r1.raw -notmatch 'Test-CommentHeavy') 'Q6 75-physical/40-net function not reported (comments+blanks subtracted)' ($r1.raw)

    # ---------- Q7/Q8: control-flow family membership ----------
    Assert-True ($r1.raw -match 'do-while-deep\.ps1:L\d+ \| Test-DoWhileSix \| #5 嵌套深度 \| 6') 'Q7 do-while nests counted in the while family' ($r1.raw)
    Assert-True ($r1.raw -notmatch 'Test-SwitchDeep') 'Q8 nested switch not counted as control-flow depth' ($r1.raw)

    # ---------- Q9: elseif clause annotation on the if ancestor ----------
    Assert-True ($r1.raw -match 'Test-ElseifSix \| #5 嵌套深度 \| 6' -and $r1.raw -match 'if@L\d+\(elseif\)') 'Q9 chain entering via elseif renders the (elseif) annotation' ($r1.raw)

    # ---------- Q10/Q11: report header + no-baseline cells ----------
    Assert-True ($r1.raw -match 'base: 无基线 \| files: 8 \| limits: function<=50 lines, nesting<=5 depth') 'Q10 header carries no-baseline base, file count, single-source limits' ($r1.raw)
    Assert-True ($r1.raw -match '汇总: 违规 4 项 \| 备忘 0 项') 'Q11 summary counts (4 violations: 51-line + three 6-level chains)' ($r1.raw)

    # ---------- Q12: determinism ----------
    $r2 = Invoke-Metrics @('-Command', 'scan', '-Files', $allFiles) $Work
    Assert-True ($r1.raw -ceq $r2.raw) 'Q12 byte-identical output on repeat run' ("len1=$($r1.raw.Length) len2=$($r2.raw.Length)")

    # ---------- Q13: threshold override flips the exact-50 boundary ----------
    $r3 = Invoke-Metrics @('-Command', 'scan', '-Files', 'exact-fifty.ps1', '-MaxFunctionLines', '40') $Work
    Assert-True ($r3.exit -eq 1 -and $r3.raw -match 'Test-ExactFifty \| #4 函数行数 \| 50') 'Q13 -MaxFunctionLines 40 flags the exact-50 function' ($r3.raw)

    # ---------- Q14: clean set -> exit 0 ----------
    $r4 = Invoke-Metrics @('-Command', 'scan', '-Files', $cleanFiles) $Work
    Assert-True ($r4.exit -eq 0 -and $r4.raw -match '违规 0 项') 'Q14 clean sample set exits 0 with zero violations' ("exit=$($r4.exit) raw=$($r4.raw)")

    # ---------- Q15: AC-5 process integration — DEV/QA docs invoke the tool ----------
    $docs = @(
        (Join-Path $EngineDir 'rdd-dev\references\execution-rules.md'),
        (Join-Path $EngineDir 'rdd-qa\references\code-quality-check.md')
    )
    $allCite = $true
    foreach ($doc in $docs) {
        if (-not (Select-String -LiteralPath $doc -Pattern 'code-metrics\.cmd' -Quiet)) { $allCite = $false }
    }
    Assert-True $allCite 'Q15 dev/QA process docs both invoke code-metrics.cmd' ("checked: {0}" -f ($docs -join ', '))

    # ---------- Q16: AC-3 threshold single source in docs/code-quality.md ----------
    $cq = Join-Path $EngineDir 'docs\code-quality.md'
    $single = (Select-String -LiteralPath $cq -Pattern '不超过 50 行' -Quiet) -and `
              (Select-String -LiteralPath $cq -Pattern '不超过 5 层' -Quiet)
    Assert-True $single 'Q16 docs/code-quality.md stays the 50/5 single threshold source' $cq
}
finally {
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

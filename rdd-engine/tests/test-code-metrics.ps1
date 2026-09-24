# code-metrics acceptance tests — QA 代码质量客观指标工具化（函数行数/嵌套深度）
#
# Baseline re-derived under the 50/5 caliber (user ruling 2026-09-24; CTO
# decisions #4/#6 in archive 2026-09-24-qa-metric-tooling):
#   detect  : n3-round 70/58 overlong + n7-R2 76/118 worsened + >=6 synthetic
#             nesting sample (no historical >=6 instance exists)
#   zero-FP : n3 46/42/41-line functions, n5 5/5/4-level chains, n7-R1 4-level
#             chain must NOT be reported under 50/5; untouched over-limit
#             functions land in the memo zone only
#   caliber : net lines = AST body extent minus comments/blanks; nesting =
#             if/for/foreach/while ancestor chains, top level = depth 1
#
# Fixtures are checked in under tests/fixtures/code-metrics (base/ + work/).
# The test builds a throwaway git repo in %TEMP% (test-phase-model precedent;
# never under .rdd/changes — TC-B12 pollution lesson), commits the base side,
# overlays the work side, and drives the production interpreter
# (Windows PowerShell 5.1). Exit code 0 = all green.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir = Split-Path -Parent $PSScriptRoot
$ToolPs1 = Join-Path $EngineDir 'scripts\code-metrics.ps1'
$FixtureRoot = Join-Path $EngineDir 'tests\fixtures\code-metrics'
$Work = Join-Path $env:TEMP ('code-metrics-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# Native stderr under EAP=Stop raises NativeCommandError in PS5.1; the tool's
# exit-2 channel is stderr, so invocation runs with EAP=Continue and merges.
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

function Invoke-TestGit { param([string[]]$GitArgs)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = git @GitArgs 2>&1; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $oldEap }
}

$GitIdentity = @('-c', 'user.name=code-metrics-test', '-c', 'user.email=code-metrics-test@example.local')

# ---------- fixture repo: commit base side, overlay work side ----------
New-Item -ItemType Directory -Path (Join-Path $Work 'src') -Force | Out-Null
$null = Invoke-TestGit (@('-c', 'init.defaultBranch=main', 'init', '-q') + @($Work))
Copy-Item -Path (Join-Path $FixtureRoot 'base\*.ps1') -Destination (Join-Path $Work 'src') -Force
$null = Invoke-TestGit (@('-C', $Work) + $GitIdentity + @('add', '-A'))
$initOk = Invoke-TestGit (@('-C', $Work) + $GitIdentity + @('commit', '-q', '-m', 'fixture base (HEAD side)'))
Assert-True ($initOk -eq 0) 'S0 fixture base commit created' ("git exit=$initOk")
Copy-Item -Path (Join-Path $FixtureRoot 'work\*.ps1') -Destination (Join-Path $Work 'src') -Force

try {
    # ---------- S1: baseline detection (default 50/5) ----------
    $r1 = Invoke-Metrics @('-Command', 'scan') $Work
    Assert-True ($r1.exit -eq 1) 'S1 exit 1 when hard violations exist' ("exit=$($r1.exit)")
    Assert-True ($r1.raw -match 'src/flow-n3\.ps1:L\d+ \| Invoke-SetRoute \| #4 函数行数 \| 70 \| 27->70 \| -') 'S1 n3 Invoke-SetRoute 70 (27->70)' ($r1.raw)
    Assert-True ($r1.raw -match 'src/bridge-n3\.ps1:L\d+ \| Get-RollbackContext \| #4 函数行数 \| 58 \| 33->58 \| -') 'S1 n3 Get-RollbackContext 58 (33->58)' ($r1.raw)
    Assert-True ($r1.raw -match 'src/flow-n7\.ps1:L\d+ \| Invoke-Init \| #4 函数行数 \| 76 \| 58->76 \| -') 'S1 n7-R2a Invoke-Init 76 (58->76)' ($r1.raw)
    Assert-True ($r1.raw -match 'src/flow-n7\.ps1:L\d+ \| Invoke-Check \| #4 函数行数 \| 118 \| 99->118 \| -') 'S1 n7-R2b Invoke-Check 118 (99->118)' ($r1.raw)
    Assert-True ($r1.raw -match 'src/nest-deep\.ps1:L\d+ \| Invoke-DeepNest \| #5 嵌套深度 \| 6 \| new->6 \| if@L\d+( -> (if|loop)@L\d+){5}') 'S1 synthetic 6-level nesting (new->6 + chain path)' ($r1.raw)
    Assert-True ($r1.raw -match '汇总: 违规 5 项 \| 备忘 2 项') 'S1 violations=5 memo=2 (re-derived 50/5 baseline)' ($r1.raw)

    # ---------- S2: zero false positives (touched but within 50/5) ----------
    foreach ($clean in @('Invoke-AddTask', 'Invoke-Reject', 'Write-TaskJson',
                         'Invoke-BridgeSettle', 'Resolve-RollbackGraftParent', 'Format-StageChain')) {
        Assert-True ($r1.raw -notmatch $clean) "S2 zero-FP: $clean not reported under 50/5" ($r1.raw)
    }
    Assert-True ($r1.raw -notmatch 'src/bridge-n7r1\.ps1:L\d+ \| Invoke-Promulgate') 'S2 zero-FP: n7-R1 4-level chain not reported under depth 5' ($r1.raw)

    # ---------- S3: memo zone (untouched over-limit only) ----------
    $zones = $r1.raw -split '-- 备忘', 2
    $memoPart = if ($zones.Count -eq 2) { $zones[1] } else { '' }
    $violPart = $zones[0]
    Assert-True ($memoPart -match 'src/bridge-n3\.ps1:L\d+ \| Invoke-Promulgate \| #4 函数行数 \| 60') 'S3 untouched 60-line function memo-only' ($r1.raw)
    Assert-True ($memoPart -match 'src/bridge-n3\.ps1:L\d+ \| Invoke-BridgeStatus \| #5 嵌套深度 \| 6') 'S3 untouched 6-level function memo-only' ($r1.raw)
    Assert-True (-not ($violPart -match 'Invoke-Promulgate|Invoke-BridgeStatus')) 'S3 memo functions absent from violation zone' ($r1.raw)

    # ---------- S4: determinism (byte-identical repeat) ----------
    $r2 = Invoke-Metrics @('-Command', 'scan') $Work
    Assert-True ($r1.raw -ceq $r2.raw) 'S4 byte-identical output on repeat run' ("len1=$($r1.raw.Length) len2=$($r2.raw.Length)")

    # ---------- S5: threshold override 40/3 regresses the original rounds ----------
    $r3 = Invoke-Metrics @('-Command', 'scan', '-MaxFunctionLines', '40', '-MaxNestingDepth', '3') $Work
    Assert-True ($r3.exit -eq 1) 'S5 exit 1 under overridden 40/3' ("exit=$($r3.exit)")
    Assert-True ($r3.raw -match '汇总: 违规 12 项 \| 备忘 2 项') 'S5 40/3 count: 7 overlong + 5 nesting = 12' ($r3.raw)
    Assert-True ($r3.raw -match 'Invoke-AddTask \| #4 函数行数 \| 46') 'S5 n3-round Invoke-AddTask 46 flagged' ($r3.raw)
    Assert-True ($r3.raw -match 'Invoke-Reject \| #4 函数行数 \| 42') 'S5 n3-round Invoke-Reject 42 flagged' ($r3.raw)
    Assert-True ($r3.raw -match 'Write-TaskJson \| #4 函数行数 \| 41') 'S5 n3-round Write-TaskJson 41 flagged' ($r3.raw)
    Assert-True ($r3.raw -match 'Invoke-BridgeSettle \| #5 嵌套深度 \| 5 \| 3->5') 'S5 n5-round BridgeSettle 5 (3->5)' ($r3.raw)
    Assert-True ($r3.raw -match 'Resolve-RollbackGraftParent \| #5 嵌套深度 \| 5 \| 2->5') 'S5 n5-round GraftParent 5 (2->5)' ($r3.raw)
    Assert-True ($r3.raw -match 'Format-StageChain \| #5 嵌套深度 \| 4 \| new->4') 'S5 n5-round StageChain 4 (new->4)' ($r3.raw)
    Assert-True ($r3.raw -match 'src/bridge-n7r1\.ps1:L\d+ \| Invoke-Promulgate \| #5 嵌套深度 \| 4') 'S5 n7-R1 4-level chain flagged under depth 3' ($r3.raw)
    Assert-True ($r3.raw -match 'if@L\d+\(else\)') 'S5 chain renders the (else) clause annotation' ($r3.raw)

    # ---------- S6: clean tree after commit -> exit 0 ----------
    $null = Invoke-TestGit (@('-C', $Work) + @('add', '-A'))
    $commitOk = Invoke-TestGit (@('-C', $Work) + $GitIdentity + @('commit', '-q', '-m', 'fixture work side'))
    Assert-True ($commitOk -eq 0) 'S6 fixture work commit created' ("git exit=$commitOk")
    $r4 = Invoke-Metrics @('-Command', 'scan') $Work
    Assert-True ($r4.exit -eq 0) 'S6 exit 0 on clean tree (no changed .ps1)' ("exit=$($r4.exit)")
    Assert-True ($r4.raw -match 'files: 0' -and $r4.raw -match '违规 0 项') 'S6 clean summary (files=0, 0 violations)' ($r4.raw)

    # ---------- S7: explicit -Base ref against the base commit ----------
    $r5 = Invoke-Metrics @('-Command', 'scan', '-Base', 'HEAD~1') $Work
    Assert-True ($r5.exit -eq 1) 'S7 -Base HEAD~1 detects the committed change' ("exit=$($r5.exit)")
    Assert-True ($r5.raw -match 'Get-RollbackContext \| #4 函数行数 \| 58 \| 33->58') 'S7 baseline transition via explicit -Base' ($r5.raw)
    Assert-True ($r5.raw -match 'src/nest-deep\.ps1:L\d+ \| Invoke-DeepNest \| #5 嵌套深度 \| 6 \| new->6') 'S7 new file vs explicit base counts as new' ($r5.raw)

    # ---------- S8: -Files override with baseline (untouched -> memo, exit 0) ----------
    $r6 = Invoke-Metrics @('-Command', 'scan', '-Files', 'src/bridge-n3.ps1') $Work
    Assert-True ($r6.exit -eq 0) 'S8 -Files unchanged file -> memo only, exit 0' ("exit=$($r6.exit) raw=$($r6.raw)")
    Assert-True ($r6.raw -match 'files: 1') 'S8 -Files bounds the scan set' ($r6.raw)
    Assert-True ($r6.raw -match '备忘 3 项' -and $r6.raw -match '违规 0 项') 'S8 untouched over-limit functions stay memo under -Files' ($r6.raw)

    # ---------- S9: no-git degradation ----------
    $Plain = $Work + '-plain'
    New-Item -ItemType Directory -Path (Join-Path $Plain 'src') -Force | Out-Null
    Copy-Item (Join-Path $FixtureRoot 'work\flow-n7.ps1') (Join-Path $Plain 'src') -Force
    $r7 = Invoke-Metrics @('-Command', 'scan', '-Files', 'src/flow-n7.ps1') $Plain
    Assert-True ($r7.exit -eq 1) 'S9 no-git -Files still scans' ("exit=$($r7.exit)")
    Assert-True ($r7.raw -match 'base: 无基线') 'S9 report carries the 无基线 marker' ($r7.raw)
    Assert-True ($r7.raw -match 'Invoke-Init \| #4 函数行数 \| 76 \| 无基线') 'S9 no-baseline cell in violation rows' ($r7.raw)
    $r8 = Invoke-Metrics @('-Command', 'scan') $Plain
    Assert-True ($r8.exit -eq 2) 'S9 no-git without -Files -> exit 2' ("exit=$($r8.exit)")

    # ---------- S10: #1 syntax fallback (parse failure fails loud) ----------
    $broken = Join-Path $Plain 'src\broken.ps1'
    $brokenText = "# deliberately broken fixture for the #1 syntax fallback`r`nfunction Invoke-Broken {`r`n    if (`$true) {`r`n"
    [System.IO.File]::WriteAllText($broken, $brokenText, (New-Object System.Text.UTF8Encoding($true)))
    $r9 = Invoke-Metrics @('-Command', 'scan', '-Files', 'src/broken.ps1') $Plain
    Assert-True ($r9.exit -eq 1) 'S10 syntax errors -> exit 1' ("exit=$($r9.exit)")
    Assert-True ($r9.raw -match '#1 语法解析') 'S10 #1 syntax row emitted' ($r9.raw)
    Assert-True ($r9.raw -notmatch '#4|#5') 'S10 no metric rows from a broken parse' ($r9.raw)

    # ---------- S11: dogfooding — the tool scans itself clean ----------
    $r10 = Invoke-Metrics @('-Command', 'scan', '-Files', $ToolPs1) $Plain
    Assert-True ($r10.exit -eq 0) 'S11 tool self-scan clean (dogfooding)' ("exit=$($r10.exit) raw=$($r10.raw)")
    Assert-True ($r10.raw -match '违规 0 项') 'S11 self-scan zero violations' ($r10.raw)

    # ---------- S12: UTF-8 BOM on the tool (docs/code-quality.md §6.1) ----------
    $bom = [System.IO.File]::ReadAllBytes($ToolPs1)[0..2]
    Assert-True ($bom[0] -eq 239 -and $bom[1] -eq 187 -and $bom[2] -eq 191) 'S12 tool saved as UTF-8 with BOM' ("first3=$($bom -join ',')")
}
finally {
    foreach ($dir in @($Work, ($Work + '-plain'))) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$failed = @($Results | Where-Object { -not $_.ok })
Write-Output ('total: {0}  failed: {1}' -f $Results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0

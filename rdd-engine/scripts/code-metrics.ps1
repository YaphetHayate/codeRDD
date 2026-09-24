# code-metrics.ps1 — QA/DEV code-quality objective metrics CLI (engine 4th CLI class)
#
# Turns QA hard items #4 (function net lines) and #5 (nesting depth) from
# manual LLM review into a deterministic tool run (design:
# 2026-09-24-qa-metric-tooling). DEV self-test runs it BEFORE handing off to
# QA; QA verification-mode reports cite its output directly.
#
# Caliber frozen from the three QA rounds of 2026-09-23-delivery-phase-model:
#   - net code lines = lines within the AST function-body extent that carry at
#     least one non-comment token (comments and blank lines subtracted)
#   - nesting depth  = if/for/foreach/while control-flow ancestor chains, the
#     top-level statement counting as depth 1; a violation is depth > threshold.
#     foreach counts as the for family; do-while/do-until merge into the while
#     family (caliber call: loop-shaped control flow, one family); switch is
#     NOT counted; chains entering an else/elseif clause of an if ancestor are
#     annotated (else)/(elseif) — mirrors the n5-round report format
#   - "touched this round" = per-function text comparison between the Base
#     version (git show) and the worktree version (CRLF-normalized)
#
# Interface:
#   code-metrics.cmd -Command scan [-Base <ref>] [-Files <a.ps1,b.ps1>]
#                     [-MaxFunctionLines 50] [-MaxNestingDepth 5]
#   -Base   comparison baseline (default HEAD; supports HEAD~N / branch names)
#   -Files  explicit comma-separated file list, overriding the git-diff set;
#           the only path when no git baseline is resolvable (the report then
#           carries the 无基线 marker and every function counts as touched)
#   Exit codes: 0 = no hard violation / 1 = violations exist / 2 = usage error
#
# Output: plain-text stdout — violation zone (touched & over limit) plus memo
# zone (untouched over-limit functions, never counted as violations), stable
# sort (path -> start line -> clause), byte-identical for identical inputs.

[CmdletBinding()]
param(
    [ValidateSet("scan")]
    [string]$Command = "scan",

    [string]$Base = "HEAD",
    [string[]]$Files = @(),
    [ValidateRange(1, 10000)][int]$MaxFunctionLines = 50,
    [ValidateRange(1, 100)][int]$MaxNestingDepth = 5
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Invoke-Git { param([string[]]$GitArgs)
    # 2>$null must stay inside try/catch: under PS5.1, redirected native stderr
    # plus $ErrorActionPreference=Stop raises NativeCommandError.
    try { return (git @GitArgs 2>$null) } catch { return $null }
}

function Get-RepoRoot {
    $top = Invoke-Git @('rev-parse', '--show-toplevel')
    if ($top) { return ([string]$top).Trim() }
    return $null
}

function Test-BaseRef { param([string]$RefSpec)
    $resolved = Invoke-Git @('rev-parse', '--verify', '--quiet', ($RefSpec + '^{commit}'))
    return ($null -ne $resolved -and [string]$resolved -ne '')
}

function Get-ChangedPs1Files { param([string]$BaseRef)
    # git diff (Base -> worktree, staged included) bounds the changed set;
    # untracked .ps1 files are new code by definition and join it.
    $names = @()
    $diff = Invoke-Git @('diff', '--name-only', $BaseRef)
    if ($diff) { $names += @($diff) }
    $untracked = Invoke-Git @('ls-files', '--others', '--exclude-standard')
    if ($untracked) { $names += @($untracked) }
    $set = New-Object 'System.Collections.Generic.SortedSet[string]'
    foreach ($name in $names) {
        $trimmed = ([string]$name).Trim()
        if ($trimmed -match '\.ps1$') { $null = $set.Add($trimmed) }
    }
    return @($set)
}

function Read-BaseContent { param([string]$BaseRef, [string]$RepoRelPath)
    # git show of the Base blob; $null when the path does not exist in Base.
    $lines = Invoke-Git @('show', ($BaseRef + ':' + $RepoRelPath))
    if ($null -eq $lines) { return $null }
    return (@($lines) -join "`n")
}

function ConvertTo-NormalizedText { param([string]$Text)
    # CRLF -> LF so worktree/autocrlf differences never fake a "touched" hit.
    return ($Text -replace "`r`n", "`n")
}

function ConvertTo-DisplayPath { param([string]$FullPath, $RepoRoot)
    # Repo-relative forward-slash display paths (git-style, stable output);
    # absolute forward-slash when the file lives outside the repo.
    $fwd = $FullPath -replace '\\', '/'
    if ($null -ne $RepoRoot) {
        $prefix = (($RepoRoot -replace '\\', '/') + '/')
        if ($fwd.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $fwd.Substring($prefix.Length)
        }
    }
    return $fwd
}

function Get-ControlKind { param($Node)
    # 'if' for if statements, 'loop' for the for/foreach/while family. do-while
    # and do-until merge into the while family (loop-shaped control flow, one
    # family — DEV caliber call per design); switch is NOT counted.
    if ($Node -is [System.Management.Automation.Language.IfStatementAst]) { return 'if' }
    $loopKinds = @(
        [System.Management.Automation.Language.ForStatementAst],
        [System.Management.Automation.Language.ForEachStatementAst],
        [System.Management.Automation.Language.WhileStatementAst],
        [System.Management.Automation.Language.DoWhileStatementAst],
        [System.Management.Automation.Language.DoUntilStatementAst]
    )
    foreach ($loopKind in $loopKinds) {
        if ($Node -is $loopKind) { return 'loop' }
    }
    return $null
}

function Get-CodeLineMap { param($Tokens, [int]$LineCount)
    # line -> carries at least one non-comment token; comment tokens and line
    # trivia are excluded so net lines subtract comment/blank lines.
    $skipKinds = @('Comment', 'CommentStart', 'CommentText', 'CommentEnd',
                   'NewLine', 'EndOfInput', 'LineContinuation')
    $map = [bool[]]::new($LineCount + 1)
    foreach ($tok in $Tokens) {
        if ($skipKinds -contains [string]$tok.Kind) { continue }
        $from = [Math]::Max($tok.Extent.StartLineNumber, 1)
        $to = [Math]::Min($tok.Extent.EndLineNumber, $LineCount)
        for ($ln = $from; $ln -le $to; $ln++) { $map[$ln] = $true }
    }
    return $map
}

function New-FunctionRecord { param($Fn, $CodeLineMap)
    $net = 0
    $bodyStart = $Fn.Body.Extent.StartLineNumber
    $bodyEnd = $Fn.Body.Extent.EndLineNumber
    for ($ln = $bodyStart; $ln -le $bodyEnd; $ln++) {
        if ($CodeLineMap[$ln]) { $net++ }
    }
    return @{
        ast = $Fn; name = $Fn.Name
        startLine = $Fn.Extent.StartLineNumber
        netLines = $net; depth = 0; chain = ''
        text = (ConvertTo-NormalizedText $Fn.Extent.Text)
    }
}

function Get-OwningFunction { param($Node)
    $cur = $Node.Parent
    while ($null -ne $cur) {
        if ($cur -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $cur }
        $cur = $cur.Parent
    }
    return $null
}

function Get-ControlChain { param($Node)
    # Control-flow ancestors of $Node, outermost..innermost, self included; the
    # walk stops at the nearest function definition (nested functions keep
    # their own chains).
    $chain = @()
    $cur = $Node
    while ($null -ne $cur) {
        if ($cur -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
        if ($null -ne (Get-ControlKind $cur)) { $chain += $cur }
        $cur = $cur.Parent
    }
    [array]::Reverse($chain)
    return $chain
}

function Test-ExtentInside { param($Inner, $Outer)
    return ($Inner.StartOffset -ge $Outer.StartOffset -and $Inner.EndOffset -le $Outer.EndOffset)
}

function Get-IfClauseTag { param($IfAst, $NextNode)
    # Which part of $IfAst the chain descends into: first clause '', elseif
    # clause '(elseif)', else clause '(else)'; extent offsets decide.
    if ($null -ne $IfAst.ElseClause) {
        if (Test-ExtentInside $NextNode.Extent $IfAst.ElseClause.Extent) { return '(else)' }
    }
    for ($i = 0; $i -lt $IfAst.Clauses.Count; $i++) {
        $body = $IfAst.Clauses[$i].Item2
        if (Test-ExtentInside $NextNode.Extent $body.Extent) {
            if ($i -gt 0) { return '(elseif)' }
            return ''
        }
    }
    return ''
}

function Format-ChainLabel { param([array]$Chain)
    # "if@L10 -> if@L12(else) -> loop@L14": a clause tag lands on the if
    # ANCESTOR entered through that clause — n5-round report format
    # ("if@L3255(else)").
    $parts = @()
    for ($i = 0; $i -lt $Chain.Count; $i++) {
        $kind = Get-ControlKind $Chain[$i]
        $label = '{0}@L{1}' -f $kind, $Chain[$i].Extent.StartLineNumber
        $next = $null
        if ($i + 1 -lt $Chain.Count) { $next = $Chain[$i + 1] }
        if ($null -ne $next -and $Chain[$i] -is [System.Management.Automation.Language.IfStatementAst]) {
            $label += (Get-IfClauseTag $Chain[$i] $next)
        }
        $parts += $label
    }
    return ($parts -join ' -> ')
}

function Add-NestingInfo { param($Ast, $Records)
    # Deepest control-flow chain per function; ties keep the first chain in
    # document order (FindAll is pre-order), keeping output deterministic.
    $finder = { param($a) $null -ne (Get-ControlKind $a) }
    foreach ($node in $Ast.FindAll($finder, $true)) {
        $owner = Get-OwningFunction $node
        if ($null -eq $owner) { continue }
        $rec = $null
        foreach ($candidate in $Records) {
            if ($candidate.ast -eq $owner) { $rec = $candidate; break }
        }
        if ($null -eq $rec) { continue }
        $chain = @(Get-ControlChain $node)
        if ($chain.Count -gt $rec.depth) {
            $rec.depth = $chain.Count
            $rec.chain = Format-ChainLabel $chain
        }
    }
}

function Measure-ScriptText { param([string]$Content)
    # Parse one script text with the production parser; also the #1 syntax
    # check fallback for projects (.ps1) with no lint/build config.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    $records = @()
    $codeMap = Get-CodeLineMap $tokens $ast.Extent.EndLineNumber
    $finder = { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    foreach ($fn in $ast.FindAll($finder, $true)) {
        $records += New-FunctionRecord $fn $codeMap
    }
    Add-NestingInfo $ast $records
    return @{ errors = @($errors); functions = $records }
}

function Get-FileBaseline { param([string]$BaseRef, [string]$DisplayPath)
    # Same-caliber measurement of the Base version of one file. Absolute
    # display paths (outside the repo), missing files and unparseable Base
    # content degrade to no-baseline; a missing file alone means "new".
    if ($DisplayPath -match '^[A-Za-z]:/' -or $DisplayPath.StartsWith('/')) {
        return @{ mode = 'no-base' }
    }
    $content = Read-BaseContent $BaseRef $DisplayPath
    if ($null -eq $content) { return @{ mode = 'new' } }
    $parsed = Measure-ScriptText $content
    if (@($parsed.errors).Count -gt 0) { return @{ mode = 'no-base' } }
    $byName = @{}
    foreach ($rec in $parsed.functions) { $byName[$rec.name] = $rec }
    return @{ mode = 'ok'; byName = $byName }
}

function Resolve-TouchState { param($Rec, $BaseInfo)
    # Caliber A: touched = Base-vs-worktree per-function text differs
    # (CRLF-normalized); missing or unusable baseline counts as touched.
    if ($null -eq $BaseInfo -or $BaseInfo.mode -eq 'no-base') {
        return @{ touched = $true; lines = 0; depth = 0; cell = '无基线' }
    }
    if ($BaseInfo.mode -eq 'new') {
        return @{ touched = $true; lines = 0; depth = 0; cell = 'new' }
    }
    if (-not $BaseInfo.byName.ContainsKey($Rec.name)) {
        return @{ touched = $true; lines = 0; depth = 0; cell = 'new' }
    }
    $peer = $BaseInfo.byName[$Rec.name]
    if ([string]$peer.text -eq [string]$Rec.text) {
        return @{ touched = $false; lines = $peer.netLines; depth = $peer.depth; cell = 'same' }
    }
    return @{ touched = $true; lines = $peer.netLines; depth = $peer.depth; cell = 'base' }
}

function Format-BaseCell { param($State, [string]$Metric, [string]$Current)
    # HEAD-baseline cell: 27->70 / new->70 / 无基线; '-' on untouched memo rows.
    if ($State.cell -eq 'same') { return '-' }
    if ($State.cell -eq 'new') { return ('new->{0}' -f $Current) }
    if ($State.cell -eq '无基线') { return '无基线' }
    return ('{0}->{1}' -f [string]$State[$Metric], $Current)
}

function New-MetricRow { param([string]$Path, [int]$Line, [string]$Name, [string]$Clause, [string]$Value, [string]$BaseCell, [string]$Chain, [string]$Kind)
    # pscustomobject (not ordered dict): Sort-Object cannot key off dictionary
    # "properties", which silently scrambled the row order.
    return [pscustomobject]@{ path = $Path; line = $Line; name = $Name; clause = $Clause
                              value = $Value; base = $BaseCell; chain = $Chain; kind = $Kind }
}

function Measure-File { param([string]$FullPath, [string]$DisplayPath, $BaseInfo)
    # One file -> metric rows. A worktree parse failure short-circuits to #1
    # syntax rows (fail loud: partial ASTs must not leak into metrics).
    $parsed = Measure-ScriptText ([System.IO.File]::ReadAllText($FullPath))
    if (@($parsed.errors).Count -gt 0) {
        $rows = @()
        foreach ($e in $parsed.errors) {
            $rows += New-MetricRow $DisplayPath $e.Extent.StartLineNumber '-' '#1 语法解析' '-' '-' $e.Message 'violation'
        }
        return @{ syntax = $rows; metrics = @() }
    }
    $rows = @()
    foreach ($rec in $parsed.functions) {
        $state = Resolve-TouchState $rec $BaseInfo
        $kind = 'memo'
        if ($state.touched) { $kind = 'violation' }
        if ($rec.netLines -gt $MaxFunctionLines) {
            $cell = Format-BaseCell $state 'lines' ([string]$rec.netLines)
            $rows += New-MetricRow $DisplayPath $rec.startLine $rec.name '#4 函数行数' ([string]$rec.netLines) $cell '-' $kind
        }
        if ($rec.depth -gt $MaxNestingDepth) {
            $cell = Format-BaseCell $state 'depth' ([string]$rec.depth)
            $rows += New-MetricRow $DisplayPath $rec.startLine $rec.name '#5 嵌套深度' ([string]$rec.depth) $cell $rec.chain $kind
        }
    }
    return @{ syntax = @(); metrics = $rows }
}

function Format-MetricRow { param($Row)
    return ('{0}:L{1} | {2} | {3} | {4} | {5} | {6}' -f `
            $Row.path, $Row.line, $Row.name, $Row.clause, $Row.value, $Row.base, $Row.chain)
}

function Format-Report { param([array]$Rows, [string]$BaseLabel, [int]$FileCount)
    # Byte-stable report: violation zone, memo zone, summary (no timestamps).
    $lines = @()
    $lines += '== code-metrics scan =='
    $lines += ('base: {0} | files: {1} | limits: function<={2} lines, nesting<={3} depth' -f `
               $BaseLabel, $FileCount, $MaxFunctionLines, $MaxNestingDepth)
    $viol = @($Rows | Where-Object { $_.kind -eq 'violation' })
    $memo = @($Rows | Where-Object { $_.kind -eq 'memo' })
    $lines += '-- 违规（本次触及且超限）--'
    if ($viol.Count -gt 0) { foreach ($r in $viol) { $lines += Format-MetricRow $r } }
    else { $lines += '（无）' }
    $lines += '-- 备忘（历史未触及的超限函数，不计违规）--'
    if ($memo.Count -gt 0) { foreach ($r in $memo) { $lines += Format-MetricRow $r } }
    else { $lines += '（无）' }
    $lines += ('-- 汇总: 违规 {0} 项 | 备忘 {1} 项 --' -f $viol.Count, $memo.Count)
    return ($lines -join "`n")
}

function Resolve-FileEntry { param([string]$Given, $RepoRoot)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Given)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        [Console]::Error.WriteLine(('code-metrics: -Files entry not found: {0}' -f $Given))
        exit 2
    }
    return @{ full = $full; display = (ConvertTo-DisplayPath $full $RepoRoot) }
}

function Get-ScanTargets { param($RepoRoot, [bool]$HasBase)
    # -Files explicitly overrides the set; entries may arrive comma/semicolon
    # separated (powershell -File binds "-Files a,b" as one string). Otherwise
    # git diff (Base -> worktree, staged included) plus untracked .ps1 bound it.
    $targets = @()
    if (@($Files).Count -gt 0) {
        foreach ($entry in $Files) {
            foreach ($given in (([string]$entry) -split '[,;]')) {
                $trimmed = $given.Trim()
                if ($trimmed) { $targets += (Resolve-FileEntry $trimmed $RepoRoot) }
            }
        }
        return $targets
    }
    foreach ($rel in (Get-ChangedPs1Files $Base)) {
        $full = Join-Path $RepoRoot ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $targets += @{ full = $full; display = $rel }
        }
    }
    return $targets
}

function Invoke-Scan {
    # Scan orchestration: file set -> per-file measurement -> report -> exit.
    $repoRoot = Get-RepoRoot
    $hasBase = ($null -ne $repoRoot) -and (Test-BaseRef $Base)
    if (-not $hasBase -and @($Files).Count -eq 0) {
        $msg = ('code-metrics: baseline "{0}" not resolvable and -Files not given; ' -f $Base)
        $msg += 'pass -Files <comma-separated .ps1 list> for a no-baseline scan'
        [Console]::Error.WriteLine($msg)
        exit 2
    }
    $targets = @(Get-ScanTargets $repoRoot $hasBase)
    $rows = @()
    foreach ($t in $targets) {
        $baseInfo = $null
        if ($hasBase) { $baseInfo = Get-FileBaseline $Base $t.display }
        $measured = Measure-File $t.full $t.display $baseInfo
        $rows += @($measured.syntax) + @($measured.metrics)
    }
    $sorted = @($rows | Sort-Object -Property path, line, clause)
    $label = $Base
    if (-not $hasBase) { $label = '无基线' }
    Write-Output (Format-Report $sorted $label @($targets).Count)
    $violCount = @($sorted | Where-Object { $_.kind -eq 'violation' }).Count
    if ($violCount -gt 0) { exit 1 }
    exit 0
}

Invoke-Scan

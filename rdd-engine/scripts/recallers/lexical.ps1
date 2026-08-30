# Lexical recaller plugin — BM25 over the frozen retrieval text.
#
# Frozen-contract mirror (change both sides together):
#   - this file                  <-> rdd-engine recallers counterpart of
#   - dsh packages/local/rdd-explore/src/recallers/lexical.ts
# Frozen formulas implemented here (see references/exploration-guide.md):
#   F1 retrieval text  = key + "\n" + tags.join(",") + "\n" + brief
#   F3 tokenizer       = lowercase -> ASCII [a-z0-9]+ runs are tokens ->
#                        CJK runs ([\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+)
#                        emit the WHOLE run plus every adjacent 2-char gram
#   F4 BM25            = standard BM25, idf = ln((N - df + 0.5)/(df + 0.5) + 1),
#                        summed over UNIQUE query tokens (first-appearance
#                        order), k1/b configurable; gate: score > 0
# Recaller contract: input @{ query; docs; config; paths } ->
#                    output @{ name; scores{key->double}; qualified[keys desc];
#                              warning? }. Only scores, never fusion; the
#                    pipeline catches throws and degrades to empty + warning.

function New-LexicalOrdinalTable {
    return [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}

function Get-LexicalTokens {
    # F3 (frozen). Returns the token MULTISET (CJK 2-char runs count the whole
    # run and its single bigram, i.e. twice; longer runs add n-1 bigrams).
    param([string]$Text)
    $tokens = @()
    if ([string]::IsNullOrEmpty($Text)) { return $tokens }
    $lower = $Text.ToLowerInvariant()
    foreach ($m in [regex]::Matches($lower, '[a-z0-9]+|[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+')) {
        $run = $m.Value
        $tokens += $run
        if ([int][char]$run[0] -gt 0x7F) {
            for ($i = 0; ($i + 2) -le $run.Length; $i++) {
                $tokens += $run.Substring($i, 2)
            }
        }
    }
    return $tokens
}

function Sort-LexicalScored {
    # Deterministic qualified ordering (frozen): score DESC, then key ordinal
    # ASC. Stable insertion sort — no culture-sensitive comparisons anywhere.
    param([object[]]$Items)
    for ($i = 1; $i -lt $Items.Count; $i++) {
        $cur = $Items[$i]
        $j = $i - 1
        while ($j -ge 0) {
            $a = $Items[$j]
            $diff = [double]$cur.score - [double]$a.score
            $cmp = 0
            if ($diff -gt 0) { $cmp = -1 }
            elseif ($diff -lt 0) { $cmp = 1 }
            else { $cmp = [string]::CompareOrdinal([string]$cur.key, [string]$a.key) }
            if ($cmp -ge 0) { break }
            $Items[$j + 1] = $a
            $j--
        }
        $Items[$j + 1] = $cur
    }
    return $Items
}

Register-Recaller -Name "lexical" -DefaultEnabled $true -ScriptBlock {
    param($ctx)

    $lexConfig = $ctx.config.recallers["lexical"]
    $k1 = [double]$lexConfig["bm25K1"]
    $b = [double]$lexConfig["bm25B"]
    $depth = [int]$ctx.config["recallDepth"]

    # Corpus: F1 text per doc, tokenized once (F3).
    $docTokens = New-LexicalOrdinalTable   # key -> token multiset
    $docFreq = New-LexicalOrdinalTable     # token -> number of docs containing it
    $totalLen = 0.0
    foreach ($doc in @($ctx.docs)) {
        $text = [string]$doc.key + "`n" + ((@($doc.tags) | ForEach-Object { [string]$_ }) -join ",") + "`n" + [string]$doc.brief
        $toks = @(Get-LexicalTokens $text)
        $docTokens[[string]$doc.key] = $toks
        $totalLen += $toks.Count
        $seen = New-LexicalOrdinalTable
        foreach ($t in $toks) {
            if (-not $seen.ContainsKey($t)) {
                $seen[$t] = $true
                if (-not $docFreq.ContainsKey($t)) { $docFreq[$t] = 0 }
                $docFreq[$t] = [int]$docFreq[$t] + 1
            }
        }
    }

    $n = @($ctx.docs).Count
    $avgdl = 0.0
    if ($n -gt 0) { $avgdl = $totalLen / $n }

    # Unique query tokens in first-appearance order (float-sum order frozen).
    $queryTokens = @(Get-LexicalTokens ([string]$ctx.query))
    $uniqueQuery = @()
    $seenQuery = New-LexicalOrdinalTable
    foreach ($t in $queryTokens) {
        if (-not $seenQuery.ContainsKey($t)) { $seenQuery[$t] = $true; $uniqueQuery += $t }
    }

    $scores = New-LexicalOrdinalTable
    $scored = @()
    if ($n -gt 0 -and $avgdl -gt 0) {
        foreach ($doc in @($ctx.docs)) {
            $key = [string]$doc.key
            $toks = $docTokens[$key]
            $termFreq = New-LexicalOrdinalTable
            foreach ($t in $toks) {
                if (-not $termFreq.ContainsKey($t)) { $termFreq[$t] = 0 }
                $termFreq[$t] = [int]$termFreq[$t] + 1
            }
            $dl = [double]$toks.Count
            $score = 0.0
            foreach ($qt in $uniqueQuery) {
                if (-not $termFreq.ContainsKey($qt)) { continue }
                $f = [double]$termFreq[$qt]
                $d = [double]$docFreq[$qt]
                $idf = [math]::Log(($n - $d + 0.5) / ($d + 0.5) + 1.0)
                $score = $score + $idf * ($f * ($k1 + 1.0)) / ($f + $k1 * (1.0 - $b + $b * $dl / $avgdl))
            }
            if ($score -gt 0.0) {
                $scores[$key] = $score
                $scored += @{ key = $key; score = $score }
            }
        }
    }

    $ordered = @(Sort-LexicalScored -Items ([object[]]$scored))
    $qualified = @()
    $take = $ordered.Count
    if ($take -gt $depth) { $take = $depth }
    for ($i = 0; $i -lt $take; $i++) { $qualified += $ordered[$i].key }

    return @{ name = "lexical"; scores = $scores; qualified = $qualified }
}

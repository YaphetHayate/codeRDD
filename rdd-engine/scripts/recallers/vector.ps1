# Vector recaller plugin — embedding cosine over the vectors.json sidecar.
#
# Frozen-contract mirror (change all copies together):
#   - this file                  <-> rdd-engine scripts/explore-store.ps1 (write face)
#   - dsh packages/local/rdd-explore/src/recallers/vector.ts
#   - dsh packages/local/rdd-explore/src/cache.ts (vectors IO + embedTexts)
# Frozen formulas implemented here (see references/exploration-guide.md):
#   F1 retrieval text = key + "\n" + tags.join(",") + "\n" + brief
#   F2 textHash       = "sha256:" + SHA256(utf8(F1 text)).hex
#   F5 embed request  = POST {endpoint}, body { "model": M, "input": [texts] },
#                       header Authorization: Bearer $env:RDD_EMBED_APIKEY,
#                       response data[i].embedding (OpenAI de-facto standard)
#   F6 vector valid   = model == configured && textHash == current F2 &&
#                       len(vector) == dimensions (else silently skipped)
# Gate: cosine >= minCosine (frozen cosine: dot / sqrt(|a|^2) / sqrt(|b|^2)).
# Auto-enable rule (frozen): endpoint + model + dimensions>=1 +
# RDD_EMBED_APIKEY all present, else the recaller reports disabled with the
# missing pieces as its warning.

function Get-VectorSearchText {
    # F1 (frozen).
    param($Doc)
    return ([string]$Doc.key + "`n" + ((@($Doc.tags) | ForEach-Object { [string]$_ }) -join ",") + "`n" + [string]$Doc.brief)
}

function Get-VectorTextHash {
    # F2 (frozen): sha256 of the UTF-8 bytes of the retrieval text.
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ("sha256:" + (($hash | ForEach-Object { $_.ToString("x2") }) -join ""))
    }
    finally {
        $sha.Dispose()
    }
}

function Read-VectorStore {
    # vectors.json sidecar: { "entries": [{ key, textHash, model, vector }] }.
    # Derived cache — absent = empty, corrupt = empty + stderr warning (the
    # fail-soft asymmetry vs index.json is intentional: rebuildable data).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj.entries) { return @() }
        return @($obj.entries)
    }
    catch {
        [Console]::Error.WriteLine("vectors.json unreadable (treated as empty; embed-backfill rebuilds it): $($_.Exception.Message)")
        return @()
    }
}

function Invoke-VectorEmbedApi {
    # F5 (frozen). Body is sent as UTF-8 BYTES so PS 5.1 never falls back to a
    # single-byte encoding for CJK payloads.
    param([string]$Endpoint, [string]$Model, [string]$ApiKey, [string[]]$Texts, [int]$TimeoutSeconds)
    $body = @{ model = $Model; input = @($Texts) } | ConvertTo-Json -Depth 4 -Compress
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = Invoke-RestMethod `
        -Method Post `
        -Uri $Endpoint `
        -ContentType "application/json; charset=utf-8" `
        -Headers @{ Authorization = "Bearer $ApiKey" } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec $TimeoutSeconds
    if ($null -eq $resp -or $null -eq $resp.data) {
        throw "embedding response missing data[] (endpoint: $Endpoint)"
    }
    # Comma-wrap each vector: plain += would FLATTEN the nested arrays.
    $out = @()
    foreach ($d in @($resp.data)) { $out += ,([double[]]($d.embedding)) }
    return $out
}

function Get-VectorCosine {
    # Frozen op order: dot / sqrt(|a|^2) / sqrt(|b|^2); zero vector -> 0.
    param([double[]]$A, [double[]]$B)
    $dot = 0.0
    $na = 0.0
    $nb = 0.0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $dot = $dot + $A[$i] * $B[$i]
        $na = $na + $A[$i] * $A[$i]
        $nb = $nb + $B[$i] * $B[$i]
    }
    if ($na -le 0.0 -or $nb -le 0.0) { return 0.0 }
    return $dot / [math]::Sqrt($na) / [math]::Sqrt($nb)
}

function Sort-VectorScored {
    # Deterministic qualified ordering (frozen): score DESC, then key ordinal
    # ASC — identical to the lexical recaller's tie-break.
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

Register-Recaller -Name "vector" -DefaultEnabled "auto" -AutoReady {
    # Auto rule (frozen): the vector path turns on only when its config is
    # complete. Returns @{ ready; reason? } — the pipeline reports the reason
    # as the disabled warning.
    param($Config)
    $v = $Config.recallers["vector"]
    $missing = @()
    if ([string]::IsNullOrWhiteSpace([string]$v["endpoint"])) { $missing += "endpoint" }
    if ([string]::IsNullOrWhiteSpace([string]$v["model"])) { $missing += "model" }
    if ([int]$v["dimensions"] -lt 1) { $missing += "dimensions" }
    if ([string]::IsNullOrWhiteSpace([string]$env:RDD_EMBED_APIKEY)) { $missing += "RDD_EMBED_APIKEY" }
    if ($missing.Count -gt 0) {
        return @{ ready = $false; reason = ("auto: vector config incomplete (" + ($missing -join ", ") + ")") }
    }
    return @{ ready = $true }
} -ScriptBlock {
    param($ctx)

    $v = $ctx.config.recallers["vector"]
    $apiKey = [string]$env:RDD_EMBED_APIKEY
    $minCosine = [double]$v["minCosine"]
    $depth = [int]$ctx.config["recallDepth"]

    # F6 filter first: docs whose sidecar vector is valid for the CURRENT
    # retrieval text and configured model/dimensions. Everything else is
    # silently skipped; if nothing survives, return without any API call
    # (no idle spending — lexical still serves the interface).
    $valid = @()
    $stored = @(Read-VectorStore -Path ([string]$ctx.paths.vectorsPath))
    foreach ($doc in @($ctx.docs)) {
        $textHash = Get-VectorTextHash (Get-VectorSearchText $doc)
        foreach ($e in $stored) {
            if ([string]$e.key -ne [string]$doc.key) { continue }
            if ([string]$e.model -ne [string]$v["model"]) { continue }
            if ([string]$e.textHash -ne $textHash) { continue }
            $vec = @($e.vector)
            if ($vec.Count -ne [int]$v["dimensions"]) { continue }
            $valid += @{ key = [string]$doc.key; vector = [double[]]$vec }
            break
        }
    }
    if ($valid.Count -eq 0) {
        return @{ name = "vector"; scores = @{}; qualified = @() }
    }

    # Embed the query once (F5).
    $embedded = @(Invoke-VectorEmbedApi `
        -Endpoint ([string]$v["endpoint"]) `
        -Model ([string]$v["model"]) `
        -ApiKey $apiKey `
        -Texts @([string]$ctx.query) `
        -TimeoutSeconds ([int]$v["timeoutSeconds"]))
    $queryVector = [double[]]$embedded[0]
    if ($queryVector.Length -ne [int]$v["dimensions"]) {
        throw ("embedding dimension mismatch: got " + $queryVector.Length + ", configured " + [int]$v["dimensions"])
    }

    $scores = @{}
    $scored = @()
    foreach ($cand in $valid) {
        $cos = Get-VectorCosine $queryVector $cand.vector
        if ($cos -ge $minCosine) {
            $scores[$cand.key] = $cos
            $scored += @{ key = $cand.key; score = $cos }
        }
    }

    $ordered = @(Sort-VectorScored -Items ([object[]]$scored))
    $qualified = @()
    $take = $ordered.Count
    if ($take -gt $depth) { $take = $depth }
    for ($i = 0; $i -lt $take; $i++) { $qualified += $ordered[$i].key }

    return @{ name = "vector"; scores = $scores; qualified = $qualified }
}

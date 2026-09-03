/**
 * Lexical recaller — BM25 over the frozen retrieval text. TypeScript mirror
 * of `rdd-engine/scripts/recallers/lexical.ps1` (frozen contract: change both
 * sides together). Frozen formulas (see rdd-engine references/exploration-guide.md):
 * - F1 retrieval text = key + "\n" + tags.join(",") + "\n" + brief
 * - F3 tokenizer = lowercase -> ASCII [a-z0-9]+ runs are tokens -> CJK runs
 *   ([\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+) emit the WHOLE run plus every
 *   adjacent 2-char gram
 * - F4 BM25 = standard BM25, idf = ln((N - df + 0.5)/(df + 0.5) + 1), summed
 *   over UNIQUE query tokens (first-appearance order), k1/b configurable;
 *   gate: score > 0
 * A recaller only scores — never fuses, never truncates; the pipeline catches
 * throws and degrades to an empty contribution plus a warning.
 * @module @coderrdd/dsh-rdd-explore/recallers/lexical
 */

import {
  searchTextOf,
  tokenizeSearchText,
  type Recaller,
  type RecallerContext,
  type RecallerResult,
} from '../cache.js'

/** Ordinal-only string maps/set semantics (mirrors PS Ordinal hashtables). */
const ordinalSet = (tokens: readonly string[]): string[] => {
  const seen = new Set<string>()
  const ordered: string[] = []
  for (const token of tokens) {
    if (!seen.has(token)) {
      seen.add(token)
      ordered.push(token)
    }
  }
  return ordered
}

/**
 * Score every doc with BM25 (F4) and rank the qualified (score > 0) list:
 * score DESC, then key ordinal ASC, truncated to `recallDepth`.
 */
export async function runLexicalRecaller(ctx: RecallerContext): Promise<RecallerResult> {
  const lexical = ctx.config.recallers.lexical
  const k1 = lexical.bm25K1
  const b = lexical.bm25B
  const depth = ctx.config.recallDepth

  const docs = ctx.docs
  const docTokens = new Map<string, string[]>()
  const docFreq = new Map<string, number>()
  let totalLen = 0
  for (const doc of docs) {
    const tokens = tokenizeSearchText(searchTextOf(doc.key, doc.tags, doc.brief))
    docTokens.set(doc.key, tokens)
    totalLen += tokens.length
    for (const token of new Set(tokens)) {
      docFreq.set(token, (docFreq.get(token) ?? 0) + 1)
    }
  }

  const n = docs.length
  const avgdl = n > 0 ? totalLen / n : 0
  const uniqueQuery = ordinalSet(tokenizeSearchText(ctx.query))

  const scores: Record<string, number> = {}
  const scored: Array<{ key: string; score: number }> = []
  if (n > 0 && avgdl > 0) {
    for (const doc of docs) {
      const tokens = docTokens.get(doc.key) ?? []
      const termFreq = new Map<string, number>()
      for (const token of tokens) termFreq.set(token, (termFreq.get(token) ?? 0) + 1)
      const dl = tokens.length
      let score = 0
      for (const queryToken of uniqueQuery) {
        const f = termFreq.get(queryToken)
        if (f === undefined) continue
        const d = docFreq.get(queryToken) ?? 0
        const idf = Math.log((n - d + 0.5) / (d + 0.5) + 1.0)
        score = score + idf * (f * (k1 + 1.0)) / (f + k1 * (1.0 - b + b * dl / avgdl))
      }
      if (score > 0) {
        scores[doc.key] = score
        scored.push({ key: doc.key, score })
      }
    }
  }

  scored.sort((x, y) => {
    // Descending by score; Array#sort uses the sign, and the raw difference
    // is the standard descending idiom (y - x > 0 puts x after y).
    if (x.score !== y.score) return y.score - x.score
    return x.key < y.key ? -1 : x.key > y.key ? 1 : 0
  })

  return {
    name: 'lexical',
    scores,
    qualified: scored.slice(0, depth).map(entry => entry.key),
  }
}

/** The registered lexical recaller plugin (DefaultEnabled = true). */
export const lexicalRecaller: Recaller = {
  name: 'lexical',
  defaultEnabled: true,
  run: runLexicalRecaller,
}

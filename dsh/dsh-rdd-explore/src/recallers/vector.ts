/**
 * Vector recaller — embedding cosine over the vectors.json sidecar.
 * TypeScript mirror of `rdd-engine/scripts/recallers/vector.ps1` (frozen
 * contract: change both sides together). Frozen formulas:
 * - F1 retrieval text = key + "\n" + tags.join(",") + "\n" + brief
 * - F2 textHash = "sha256:" + SHA256(utf8(F1 text)).hex
 * - F5 embed request = POST {endpoint}, body { "model": M, "input": [texts] },
 *   header Authorization: Bearer $RDD_EMBED_APIKEY, response data[i].embedding
 *   (OpenAI de-facto standard)
 * - F6 vector valid = model == configured && textHash == current F2 &&
 *   len(vector) == dimensions (else silently skipped)
 * Gate: cosine >= minCosine (frozen cosine: dot / sqrt(|a|^2) / sqrt(|b|^2)).
 * Auto-enable rule (frozen): endpoint + model + dimensions>=1 +
 * RDD_EMBED_APIKEY all present, else the pipeline reports disabled with the
 * missing pieces as its warning.
 * @module @coderrdd/dsh-rdd-explore/recallers/vector
 */

import {
  embedTexts,
  searchTextOf,
  textHashOf,
  readVectors,
  type Recaller,
  type RecallerContext,
  type RecallerResult,
  type SearchConfig,
  type VectorRecallerConfig,
} from '../cache.js'
import { dirname } from 'node:path'

/**
 * The frozen auto rule: the vector path turns on only when its config is
 * complete. Mirrors the AutoReady scriptblock in recallers/vector.ps1 and
 * explore-store.ps1's Test-EmbedVectorConfig.
 */
export function vectorAutoReady(config: SearchConfig): { ready: boolean; reason?: string | undefined } {
  const missing: string[] = []
  const vector = config.recallers.vector
  if (vector.endpoint.trim() === '') missing.push('endpoint')
  if (vector.model.trim() === '') missing.push('model')
  if (vector.dimensions < 1) missing.push('dimensions')
  if ((process.env.RDD_EMBED_APIKEY ?? '').trim() === '') missing.push('RDD_EMBED_APIKEY')
  if (missing.length > 0) {
    return { ready: false, reason: `auto: vector config incomplete (${missing.join(', ')})` }
  }
  return { ready: true }
}

/** Frozen cosine op order: dot / sqrt(|a|^2) / sqrt(|b|^2); zero vector -> 0. */
export function cosine(a: readonly number[], b: readonly number[]): number {
  let dot = 0
  let na = 0
  let nb = 0
  for (let i = 0; i < a.length; i += 1) {
    dot = dot + a[i]! * b[i]!
    na = na + a[i]! * a[i]!
    nb = nb + b[i]! * b[i]!
  }
  if (na <= 0 || nb <= 0) return 0
  return dot / Math.sqrt(na) / Math.sqrt(nb)
}

/**
 * F6-filter the sidecar against the docs' CURRENT retrieval texts, embed the
 * query once (F5), gate by minCosine, and rank qualified keys: cosine DESC,
 * then key ordinal ASC, truncated to `recallDepth`. Returns an empty
 * contribution WITHOUT any API call when no doc has a valid stored vector.
 */
export async function runVectorRecaller(ctx: RecallerContext): Promise<RecallerResult> {
  const vector: VectorRecallerConfig = ctx.config.recallers.vector
  const apiKey = process.env.RDD_EMBED_APIKEY ?? ''
  const minCosine = vector.minCosine
  const depth = ctx.config.recallDepth

  const stored = await readVectors(dirname(ctx.paths.vectorsPath))
  const valid: Array<{ key: string; vector: readonly number[] }> = []
  for (const doc of ctx.docs) {
    const textHash = textHashOf(searchTextOf(doc.key, doc.tags, doc.brief))
    for (const entry of stored) {
      if (entry.key !== doc.key) continue
      if (entry.model !== vector.model) continue
      if (entry.textHash !== textHash) continue
      if (entry.vector.length !== vector.dimensions) continue
      valid.push({ key: doc.key, vector: entry.vector })
      break
    }
  }
  if (valid.length === 0) {
    return { name: 'vector', scores: {}, qualified: [] }
  }

  const embedded = await embedTexts(vector, [ctx.query], apiKey)
  const queryVector = embedded[0] ?? []
  if (queryVector.length !== vector.dimensions) {
    throw new Error(`embedding dimension mismatch: got ${queryVector.length}, configured ${vector.dimensions}`)
  }

  const scores: Record<string, number> = {}
  const scored: Array<{ key: string; score: number }> = []
  for (const cand of valid) {
    const sim = cosine(queryVector, cand.vector)
    if (sim >= minCosine) {
      scores[cand.key] = sim
      scored.push({ key: cand.key, score: sim })
    }
  }

  scored.sort((x, y) => {
    // Descending by score; raw difference is the standard descending idiom.
    if (x.score !== y.score) return y.score - x.score
    return x.key < y.key ? -1 : x.key > y.key ? 1 : 0
  })

  return {
    name: 'vector',
    scores,
    qualified: scored.slice(0, depth).map(entry => entry.key),
  }
}

/** The registered vector recaller plugin (DefaultEnabled = 'auto'). */
export const vectorRecaller: Recaller = {
  name: 'vector',
  defaultEnabled: 'auto',
  autoReady: vectorAutoReady,
  run: runVectorRecaller,
}

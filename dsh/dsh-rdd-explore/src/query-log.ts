/**
 * Append-only query log for the exploration cache — the hit-rate data source
 * (requirement 2026-10-08-rdd-ops-dashboard/explore-query-log). Every executed
 * rdd_explore query appends ONE JSONL line to
 * `<repoRoot>/.rdd/exploration/query-log.jsonl`, UTF-8 without BOM, sharing
 * the frozen six-field line contract with the rdd-engine CLI mirror
 * (rdd-engine/scripts/explore.ps1 `Write-QueryLog` — change both sides
 * together):
 *   ts        ISO-8601 UTC with milliseconds
 *   entry     "cli" | "dsh-plugin" (always "dsh-plugin" here)
 *   query     original query text
 *   outcome   hit | miss | forced (miss/forced = a worker dispatch followed)
 *   keys      Top-K returned entry keys in rank order (miss/forced -> [])
 *   recallers [{name,status,qualified}] projected from the rankMeta outcomes
 * Field order is frozen (ts,entry,query,outcome,keys,recallers) so lines from
 * both writers are comparable apart from values.
 *
 * Failure isolation is a hard acceptance gate: any IO error degrades to a
 * console warning — the tool's result and the tool call are untouched.
 * @module @coderrdd/dsh-rdd-explore/query-log
 */

import { appendFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'

/** Which entry point wrote a query-log line. */
export type QueryLogEntry = 'cli' | 'dsh-plugin'

/** hit = the cache served the query; miss|forced = a worker dispatch followed. */
export type QueryLogOutcome = 'hit' | 'miss' | 'forced'

/** One recall path's projection into a log line (rankMeta minus warning). */
export interface QueryLogRecaller {
  readonly name: string
  readonly status: string
  readonly qualified: number
}

/** The frozen six-field JSONL record (see the module doc). */
export interface QueryLogRecord {
  readonly ts: string
  readonly entry: QueryLogEntry
  readonly query: string
  readonly outcome: QueryLogOutcome
  readonly keys: readonly string[]
  readonly recallers: readonly QueryLogRecaller[]
}

/** The query-log file inside an exploration directory. */
export function queryLogPathOf(explorationDir: string): string {
  return join(explorationDir, 'query-log.jsonl')
}

/**
 * Assemble one log record with the frozen field order. Separate export so
 * tests can pin the line format without touching the filesystem.
 * @param query - the original query text.
 * @param outcome - hit | miss | forced.
 * @param keys - Top-K returned entry keys in rank order (empty for miss/forced).
 * @param recallers - per-recaller rankMeta outcomes (only name/status/qualified are kept).
 */
export function buildQueryLogRecord(
  query: string,
  outcome: QueryLogOutcome,
  keys: readonly string[],
  recallers: readonly QueryLogRecaller[],
): QueryLogRecord {
  return {
    ts: new Date().toISOString(),
    entry: 'dsh-plugin',
    query,
    outcome,
    keys: [...keys],
    recallers: recallers.map(({ name, status, qualified }) => ({ name, status, qualified })),
  }
}

/**
 * Append one query-log line. Never throws: any failure (unwritable directory,
 * full disk, ...) becomes a console warning and the caller's flow continues
 * unchanged — the search result and the tool call are never affected.
 * @param explorationDir - the `.rdd/exploration` directory of the repository.
 * @param query - the original query text.
 * @param outcome - hit | miss | forced.
 * @param keys - Top-K returned entry keys in rank order (empty for miss/forced).
 * @param recallers - per-recaller rankMeta outcomes (only name/status/qualified are kept).
 */
export async function appendQueryLog(
  explorationDir: string,
  query: string,
  outcome: QueryLogOutcome,
  keys: readonly string[],
  recallers: readonly QueryLogRecaller[],
): Promise<void> {
  try {
    const record = buildQueryLogRecord(query, outcome, keys, recallers)
    await mkdir(explorationDir, { recursive: true })
    // appendFile with 'utf8' never writes a BOM; one small single-line write
    // per query keeps O_APPEND semantics at this message size.
    await appendFile(queryLogPathOf(explorationDir), `${JSON.stringify(record)}\n`, 'utf8')
  } catch (error: unknown) {
    console.warn(`[rdd-explore] query-log append failed (ignored, search unaffected): ${String(error)}`)
  }
}

// AC-1.5 probe: the query log is mechanically aggregatable — hit-rate
// percentage by outcome type (hit/(hit+miss), forced excluded from the
// denominator per the frozen contract), miss-query frequency grouping,
// per-entry split, unknown-field tolerance and corrupt-line skip.
//
// Feature: explore-query-log. Run: node .rdd/tests/explore-query-log/hit-rate-aggregation.mjs
// The fixture part asserts known counts; the live part parses this repo's
// real .rdd/exploration/query-log.jsonl and prints its current stats (smoke
// only — the live log keeps growing, so no count assertions there).
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const results = []
function assertTrue(cond, name, detail = '') {
  results.push({ name, ok: cond, detail })
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : `   ${detail}`}`)
}

/** The consumption contract #2's dashboard will build on: one pass, pure JSON.parse per line. */
function aggregate(text) {
  const stats = { total: 0, skipped: 0, hit: 0, miss: 0, forced: 0, byEntry: {}, missQueries: {} }
  for (const rawLine of text.split('\n')) {
    if (rawLine === '') continue
    let record
    try {
      record = JSON.parse(rawLine)
    } catch {
      stats.skipped++
      continue
    }
    stats.total++
    const outcome = record.outcome
    if (outcome === 'hit' || outcome === 'miss' || outcome === 'forced') stats[outcome]++
    const entry = typeof record.entry === 'string' ? record.entry : 'unknown'
    stats.byEntry[entry] = (stats.byEntry[entry] ?? 0) + 1
    if (outcome === 'miss') {
      const query = typeof record.query === 'string' ? record.query : ''
      stats.missQueries[query] = (stats.missQueries[query] ?? 0) + 1
    }
  }
  const denominator = stats.hit + stats.miss
  stats.hitRatePercent = denominator === 0 ? null : Math.round((stats.hit / denominator) * 10000) / 100
  return stats
}

// ===== fixture: 3 hit + 1 miss + 2 forced + 1 hit-with-unknown-field + 1 corrupt line
const fixtureLines = []
const mk = (outcome, query) => JSON.stringify({
  ts: '2026-10-08T00:00:00.000Z',
  entry: 'cli',
  query,
  outcome,
  keys: outcome === 'hit' ? ['k'] : [],
  recallers: [{ name: 'lexical', status: 'ok', qualified: 1 }],
})
fixtureLines.push(mk('hit', 'q1'), mk('hit', 'q2'), mk('hit', 'q3'))
fixtureLines.push(mk('miss', 'always-missing'))
fixtureLines.push(mk('forced', 'forced bypass 1'), mk('forced', 'forced bypass 2'))
fixtureLines.push(JSON.stringify({
  ts: '2026-10-08T00:00:01.000Z',
  entry: 'dsh-plugin',
  query: 'q5 with a future unknown field',
  outcome: 'hit',
  keys: ['k'],
  recallers: [],
  dashboardNote: 'unknown fields must be ignored by the aggregator',
}))
fixtureLines.push('{"broken json line')
const stats = aggregate(fixtureLines.join('\n'))
assertTrue(stats.total === 7, 'fixture: 7 parsable lines counted', `total=${stats.total}`)
assertTrue(stats.skipped === 1, 'fixture: corrupt line skipped exactly once', `skipped=${stats.skipped}`)
assertTrue(stats.hit === 4 && stats.miss === 1 && stats.forced === 2, 'fixture: outcome counts hit=4 miss=1 forced=2', `${stats.hit}/${stats.miss}/${stats.forced}`)
assertTrue(stats.hitRatePercent === 80, 'fixture: hit rate = hit/(hit+miss) = 80% (forced excluded from denominator)', String(stats.hitRatePercent))
assertTrue(stats.missQueries['always-missing'] === 1, 'fixture: miss query grouped by query text')
assertTrue((stats.byEntry.cli ?? 0) === 6 && (stats.byEntry['dsh-plugin'] ?? 0) === 1, 'fixture: per-entry split cli=6 dsh-plugin=1', JSON.stringify(stats.byEntry))

// ===== live smoke over this repo's real log
const here = dirname(fileURLToPath(import.meta.url))
const livePath = join(here, '..', '..', 'exploration', 'query-log.jsonl')
if (existsSync(livePath)) {
  const live = aggregate(await readFile(livePath, 'utf8'))
  console.log(`live stats: total=${live.total} hit=${live.hit} miss=${live.miss} forced=${live.forced} hitRate=${live.hitRatePercent}% byEntry=${JSON.stringify(live.byEntry)}`)
  assertTrue(live.skipped === 0, 'live: no corrupt lines in the real log', `skipped=${live.skipped}`)
  assertTrue(live.hitRatePercent === null || (live.hitRatePercent >= 0 && live.hitRatePercent <= 100), 'live: hit rate within [0,100]')
} else {
  console.log('live log not present yet — smoke section skipped')
}

const failed = results.filter((entry) => !entry.ok)
console.log('')
console.log(`total: ${results.length}  failed: ${failed.length}`)
process.exit(failed.length > 0 ? 1 : 0)

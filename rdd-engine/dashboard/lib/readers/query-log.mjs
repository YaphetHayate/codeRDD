// Reader: query log (.rdd/exploration/query-log.jsonl) — the hit-rate domain.
//
// Frozen six-field line contract shared by both writers (explore.ps1 --entry
// cli, dsh plugin --entry dsh-plugin): ts, entry, query, outcome, keys,
// recallers. Aggregation rules: hit-rate = hit / (hit + miss) with forced kept
// out of the denominator, miss queries grouped by query text, detail rows
// newest-first and truncated, trend bucketed by day. Corrupt/half-written lines
// are skipped and reported as notes instead of failing the domain.
import { join } from 'node:path'

import { listFiles, makeEnvelope, readText } from '../io.mjs'

const DOMAIN = 'hit-rate'
const SOURCE = '.rdd/exploration/query-log.jsonl'
const DETAIL_LIMIT = 200
const MAX_MISS_QUERIES = 20

/** Parse one JSONL line into the frozen record shape. */
function parseLine(line) {
  const record = JSON.parse(line)
  const recallers = Array.isArray(record.recallers) ? record.recallers : []
  return {
    ts: typeof record.ts === 'string' ? record.ts : '',
    entry: typeof record.entry === 'string' ? record.entry : 'unknown',
    query: typeof record.query === 'string' ? record.query : '',
    outcome: typeof record.outcome === 'string' ? record.outcome : 'unknown',
    keys: Array.isArray(record.keys) ? record.keys.map((key) => String(key)) : [],
    recallers: recallers.map((recaller) => ({
      name: String(recaller?.name ?? ''),
      status: String(recaller?.status ?? ''),
      qualified: Number(recaller?.qualified ?? 0),
    })),
  }
}

/** Count outcomes, group miss queries and collect the detail rows. */
function summarize(records) {
  const totals = { hit: 0, miss: 0, forced: 0, other: 0 }
  const byEntry = new Map()
  const missQueries = new Map()
  for (const record of records) {
    if (record.outcome in totals) totals[record.outcome] += 1
    else totals.other += 1
    byEntry.set(record.entry, (byEntry.get(record.entry) ?? 0) + 1)
    if (record.outcome === 'miss') {
      missQueries.set(record.query, (missQueries.get(record.query) ?? 0) + 1)
    }
  }
  return { totals, byEntry, missQueries }
}

/** Bucket records per calendar day (UTC) for the trend chart. */
function bucketByDay(records) {
  const days = new Map()
  for (const record of records) {
    const day = record.ts.slice(0, 10)
    if (day === '') continue
    const bucket = days.get(day) ?? { day, hit: 0, miss: 0, forced: 0, total: 0 }
    if (record.outcome in bucket) bucket[record.outcome] += 1
    bucket.total += 1
    days.set(day, bucket)
  }
  return [...days.values()].sort((left, right) => left.day.localeCompare(right.day))
}

/** Read the JSONL file, returning records plus the skipped-line count. */
function readRecords(logPath) {
  const { text, error } = readText(logPath)
  if (text === null) return { records: [], skipped: 0, present: false, error }
  const records = []
  let skipped = 0
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      records.push(parseLine(line))
    } catch {
      skipped += 1
    }
  }
  return { records, skipped, present: true, error: null }
}

/** Recaller coverage over the whole log (name|status → count, descending). */
function collectRecallers(records) {
  const recallers = new Map()
  for (const record of records) {
    for (const recaller of record.recallers) {
      const key = `${recaller.name}|${recaller.status}`
      const current = recallers.get(key) ?? { name: recaller.name, status: recaller.status, count: 0 }
      current.count += 1
      recallers.set(key, current)
    }
  }
  return [...recallers.values()].sort((left, right) => right.count - left.count)
}

/** Most frequent miss queries first (count desc, then query text). */
function topMissQueries(missQueries) {
  return [...missQueries.entries()]
    .map(([query, count]) => ({ query, count }))
    .sort((left, right) => right.count - left.count || left.query.localeCompare(right.query))
    .slice(0, MAX_MISS_QUERIES)
}

/**
 * Aggregate the hit-rate domain.
 * @param {{rddRoot: string}} context
 */
export function readHitRate(context) {
  const root = join(context.rddRoot, 'exploration')
  const env = makeEnvelope(DOMAIN, SOURCE)
  const logPath = join(root, 'query-log.jsonl')
  const { records, skipped, present, error } = readRecords(logPath)
  if (error !== null) env.meta.notes.push(`流水读取失败：${error}`)
  if (skipped > 0) env.meta.notes.push(`跳过 ${skipped} 行无法解析的流水记录。`)
  if (present && listFiles(root, (name) => name === 'query-log.jsonl').length === 0) {
    env.meta.notes.push('query-log.jsonl 命中夹具排除规则，未纳入统计。')
  }
  const { totals, byEntry, missQueries } = summarize(records)
  const denominator = totals.hit + totals.miss
  const newestFirst = [...records].reverse()
  env.available = records.length > 0
  if (!present) env.meta.notes.push('流水文件不存在：检索链路尚未产生查询流水（#1 数据源未交付或尚未积累）。')
  env.data = {
    total: records.length,
    hit: totals.hit,
    miss: totals.miss,
    forced: totals.forced,
    unknownOutcome: totals.other,
    skipped,
    hitRatePercent: denominator === 0 ? null : Math.round((totals.hit / denominator) * 10000) / 100,
    trend: bucketByDay(records),
    detailLimit: DETAIL_LIMIT,
    detail: newestFirst.slice(0, DETAIL_LIMIT).map((record) => ({
      ...record,
      keysTruncated: record.keys.length > 6,
    })),
    missQueries: topMissQueries(missQueries),
    byEntry: [...byEntry.entries()].map(([entry, count]) => ({ entry, count })),
    recallers: collectRecallers(records),
    timeRange: {
      first: records.length > 0 ? records[0].ts : '',
      last: records.length > 0 ? records[records.length - 1].ts : '',
    },
    newestQuery: newestFirst.length > 0 ? newestFirst[0].query : '',
  }
  return env
}

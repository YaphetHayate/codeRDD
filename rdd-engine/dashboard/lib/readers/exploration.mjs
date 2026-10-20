// Reader: exploration cache (.rdd/exploration/hot.json + index.json + artifacts).
//
// The hot zone holds freshly registered retrievable entries; index.json holds
// the persisted ones. The dashboard merges both, then reports entry count, tag
// distribution, registration timeline and artifact pairing.
//
// Pair observability extension (#2): every artifact record is paired with its
// summary file and — when one exists — the cache entry that declared it. The
// dashboard computes freshness itself (design §7.1): re-hash every file in the
// entry's `files` map and check the record path, mirroring
// rdd-engine/scripts/explore-store.ps1 Test-EntryFresh. Engine scripts and the
// frozen entry face stay untouched; the covered-files list rides on `pairs[]`
// because the /api/exploration entry field set is frozen (probe TC-015).
import { createHash } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

import { isoFromMs, listFiles, makeEnvelope, readJson } from '../io.mjs'

const DOMAIN = 'exploration'
const SOURCE = '.rdd/exploration/hot.json + index.json + artifacts/'
const ARTIFACT_DIR = '.rdd/exploration/artifacts'
// Design §7.3 guardrail: above this many hashed files per request the page
// cost is surfaced as a note (never blocks, never skips the computation).
const FRESHNESS_HASH_WARN_THRESHOLD = 2000

/**
 * Normalize one hot/index entry record.
 *
 * Returns the frozen envelope face (field order pinned by probe TC-015) plus
 * the raw files map ({relativePath: "sha256:..."}) kept beside it for the
 * dashboard-side freshness computation — the map itself never enters the
 * envelope.
 */
function normalizeEntry(rawEntry, zone) {
  const entry = rawEntry ?? {}
  const tags = Array.isArray(entry.tags) ? entry.tags.map((tag) => String(tag)) : []
  const filesMap = entry.files && typeof entry.files === 'object' ? entry.files : {}
  return {
    entry: {
      zone,
      key: String(entry.key ?? ''),
      tags,
      brief: String(entry.brief ?? ''),
      path: String(entry.path ?? ''),
      fileCount: Object.keys(filesMap).length,
      registeredAt: String(entry.registeredAt ?? ''),
    },
    filesMap,
  }
}

/** Read one zone file ({entries: [...]}) tolerantly. */
function readZone(absolutePath, zone, notes) {
  const parsed = readJson(absolutePath)
  if (parsed.error !== null) {
    notes.push(`${zone} 文件解析失败（${absolutePath}）：${parsed.error}`)
    return { records: [], present: !parsed.missing }
  }
  const raw = parsed.value?.entries
  const records = Array.isArray(raw) ? raw.map((entry) => normalizeEntry(entry, zone)) : []
  return { records, present: !parsed.missing }
}

/** sha256 of a file as the engine records it ("sha256:" + lowercase hex), or null when unreadable. */
function fileSha256(absolutePath) {
  try {
    const bytes = readFileSync(absolutePath)
    return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
  } catch {
    return null
  }
}

/** True when the record file an entry points at exists (engine Test-EntryFresh semantics). */
function recordPathExists(projectRoot, entryPath) {
  if (entryPath === '') return false
  try {
    statSync(join(projectRoot, entryPath))
    return true
  } catch {
    return false
  }
}

/**
 * Dashboard-side freshness (design §7.1, engine Test-EntryFresh semantics):
 * every recorded file must re-hash to its recorded value AND the record file
 * must exist. Read/hash errors degrade to "missing" per the fail-soft rule —
 * a single unreadable file never breaks the page.
 */
function computeFreshness(projectRoot, entry, filesMap) {
  const files = Object.keys(filesMap)
  const changed = []
  const missing = []
  for (const relativePath of files) {
    const current = fileSha256(join(projectRoot, relativePath))
    if (current === null) missing.push(relativePath)
    else if (current !== filesMap[relativePath]) changed.push(relativePath)
  }
  if (!recordPathExists(projectRoot, entry.path)) missing.push(entry.path)
  const state = changed.length + missing.length === 0 ? 'fresh' : 'stale'
  return { state, changed, missing, total: files.length }
}

/**
 * Pair artifact records with their summary files (`{slug}.md` ↔
 * `{slug}.summary.md`) and surface the missing-summary note in the existing
 * wording. Returns the name set reused by pair construction.
 */
function pairRecords(files, notes) {
  const names = new Set(files.map((file) => file.name))
  const records = files.filter((file) => file.name.endsWith('.md') && !file.name.endsWith('.summary.md'))
  const pairedCount = records.filter((file) => names.has(`${file.name.slice(0, -3)}.summary.md`)).length
  if (records.length > 0 && pairedCount < records.length) {
    notes.push(`${records.length - pairedCount} 条 artifact 记录缺少配对 summary。`)
  }
  return { names, records, pairedCount }
}

/**
 * Entry lookup keyed by the declared record path; when both zones declare the
 * same path the hot zone wins (same precedence as the retrieval pipeline).
 */
function buildEntryLookup(hotRecords, indexRecords) {
  const entryByPath = new Map()
  for (const record of hotRecords) entryByPath.set(record.entry.path, record)
  for (const record of indexRecords) {
    if (!entryByPath.has(record.entry.path)) entryByPath.set(record.entry.path, record)
  }
  return entryByPath
}

/**
 * Build one pair record: summary link, entry association, dashboard-side
 * freshness and the covered-files list. Freshness dispatch follows the §5.3
 * state machine (orphan → no-list → compute). Returns the pair plus its
 * hashed-file count so the caller can surface the §7.3 guardrail note.
 */
function buildPair(file, projectRoot, names, entryByPath) {
  const slug = file.name.slice(0, -3)
  const artifactPath = `${ARTIFACT_DIR}/${file.name}`
  const summaryName = `${slug}.summary.md`
  const matched = entryByPath.get(artifactPath) ?? null
  const filesMap = matched === null ? {} : matched.filesMap
  const coveredFiles = Object.keys(filesMap)
  let hashedCount = 0
  let freshness
  if (matched === null) {
    freshness = { state: 'orphan', changed: [], missing: [], total: 0 }
  } else if (coveredFiles.length === 0) {
    freshness = { state: 'no-list', changed: [], missing: [], total: 0 }
  } else {
    hashedCount = coveredFiles.length
    freshness = computeFreshness(projectRoot, matched.entry, filesMap)
  }
  return {
    pair: {
      slug,
      artifactPath,
      summaryPath: names.has(summaryName) ? `${ARTIFACT_DIR}/${summaryName}` : null,
      mtime: isoFromMs(file.mtimeMs),
      entry: matched === null ? null : { zone: matched.entry.zone, key: matched.entry.key, registeredAt: matched.entry.registeredAt },
      freshness,
      files: coveredFiles,
    },
    hashedCount,
  }
}

/**
 * Aggregate artifacts/ into the pair list (§7.2): every `.md` record pairs with
 * its summary and — when one exists — the cache entry that declared it; the
 * dashboard computes freshness itself (design §7.1). The count fields keep the
 * frozen envelope face (TC-015); `pairs[]` is the new observability face.
 */
function readArtifacts(absolutePath, projectRoot, hotRecords, indexRecords, notes) {
  const files = listFiles(absolutePath)
  const { names, records, pairedCount } = pairRecords(files, notes)
  const entryByPath = buildEntryLookup(hotRecords, indexRecords)
  let hashedTotal = 0
  const pairs = records
    .map((file) => {
      const { pair, hashedCount } = buildPair(file, projectRoot, names, entryByPath)
      hashedTotal += hashedCount
      return pair
    })
    .sort((left, right) => (left.slug < right.slug ? -1 : left.slug > right.slug ? 1 : 0))
  if (hashedTotal > FRESHNESS_HASH_WARN_THRESHOLD) {
    notes.push(`新鲜度现算涉及 ${hashedTotal} 个文件，页面生成耗时可能上升。`)
  }
  return { count: records.length, pairedCount, totalFiles: files.length, pairs }
}

/**
 * Aggregate the exploration cache domain.
 * @param {{rddRoot: string, projectRoot?: string}} context
 */
export function readExploration(context) {
  const root = join(context.rddRoot, 'exploration')
  const projectRoot = context.projectRoot ?? join(context.rddRoot, '..')
  const notes = []
  const env = makeEnvelope(DOMAIN, SOURCE)
  const hot = readZone(join(root, 'hot.json'), 'hot', notes)
  const index = readZone(join(root, 'index.json'), 'index', notes)
  const artifacts = readArtifacts(join(root, 'artifacts'), projectRoot, hot.records, index.records, notes)
  const entries = [...hot.records.map((record) => record.entry), ...index.records.map((record) => record.entry)]
  const tagCounts = new Map()
  for (const entry of entries) {
    for (const tag of entry.tags) tagCounts.set(tag, (tagCounts.get(tag) ?? 0) + 1)
  }
  const timeline = entries
    .filter((entry) => entry.registeredAt !== '')
    .sort((left, right) => right.registeredAt.localeCompare(left.registeredAt))
    .map((entry) => ({ key: entry.key, zone: entry.zone, at: entry.registeredAt, brief: entry.brief }))
  if (entries.length === 0) {
    notes.push('热区与持久区 entries 均为空，尚无已注册的检索条目。')
  }
  env.available = entries.length > 0
  env.meta.notes = env.meta.notes.concat(notes)
  env.data = {
    hotCount: hot.records.length,
    indexCount: index.records.length,
    totalCount: entries.length,
    entries,
    tags: [...tagCounts.entries()]
      .map(([tag, count]) => ({ tag, count }))
      .sort((left, right) => right.count - left.count),
    timeline,
    artifacts,
    zones: { hotPresent: hot.present, indexPresent: index.present },
  }
  return env
}

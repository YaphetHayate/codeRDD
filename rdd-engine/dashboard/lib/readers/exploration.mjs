// Reader: exploration cache (.rdd/exploration/hot.json + index.json + artifacts).
//
// The hot zone holds freshly registered retrievable entries; index.json holds
// the persisted ones. The dashboard merges both, then reports entry count, tag
// distribution, registration timeline and artifact pairing.
import { join } from 'node:path'

import { listFiles, makeEnvelope, readJson } from '../io.mjs'

const DOMAIN = 'exploration'
const SOURCE = '.rdd/exploration/hot.json + index.json + artifacts/'

/** Normalize one hot/index entry record. */
function normalizeEntry(rawEntry, zone) {
  const entry = rawEntry ?? {}
  const tags = Array.isArray(entry.tags) ? entry.tags.map((tag) => String(tag)) : []
  const files = entry.files && typeof entry.files === 'object' ? Object.keys(entry.files) : []
  return {
    zone,
    key: String(entry.key ?? ''),
    tags,
    brief: String(entry.brief ?? ''),
    path: String(entry.path ?? ''),
    fileCount: files.length,
    registeredAt: String(entry.registeredAt ?? ''),
  }
}

/** Read one zone file ({entries: [...]}) tolerantly. */
function readZone(absolutePath, zone, notes) {
  const parsed = readJson(absolutePath)
  if (parsed.error !== null) {
    notes.push(`${zone} 文件解析失败（${absolutePath}）：${parsed.error}`)
    return { entries: [], present: !parsed.missing }
  }
  const raw = parsed.value?.entries
  const entries = Array.isArray(raw) ? raw.map((entry) => normalizeEntry(entry, zone)) : []
  return { entries, present: !parsed.missing }
}

/** Count artifact records and how many carry a paired summary file. */
function readArtifacts(absolutePath, notes) {
  const files = listFiles(absolutePath)
  const names = new Set(files.map((file) => file.name))
  const records = files.filter((file) => file.name.endsWith('.md') && !file.name.endsWith('.summary.md'))
  const paired = records.filter((file) => {
    const summary = `${file.name.slice(0, -3)}.summary.md`
    return names.has(summary)
  })
  if (records.length > 0 && paired.length < records.length) {
    notes.push(`${records.length - paired.length} 条 artifact 记录缺少配对 summary。`)
  }
  return { count: records.length, pairedCount: paired.length, totalFiles: files.length }
}

/**
 * Aggregate the exploration cache domain.
 * @param {{rddRoot: string}} context
 */
export function readExploration(context) {
  const root = join(context.rddRoot, 'exploration')
  const notes = []
  const env = makeEnvelope(DOMAIN, SOURCE)
  const hot = readZone(join(root, 'hot.json'), 'hot', notes)
  const index = readZone(join(root, 'index.json'), 'index', notes)
  const artifacts = readArtifacts(join(root, 'artifacts'), notes)
  const entries = [...hot.entries, ...index.entries]
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
    hotCount: hot.entries.length,
    indexCount: index.entries.length,
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

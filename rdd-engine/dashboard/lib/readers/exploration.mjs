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
import { readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { isAbsolute, join, relative } from 'node:path'

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

// ── 写面：产物对成对删除（artifact-deletion 技术方向「删除一致性执行序」）──
// The FIRST data-face write path of the read-only dashboard. Fully synchronous
// (read → stage → write → unlink with no await gaps); every reversible step
// precedes the irreversible ones and any failure rolls the done steps back, so
// a pair is either fully deleted or fully present (AC 4). Engine scripts and
// the frozen GET envelope stay untouched.

/** Contracted deletion rejection: HTTP status + machine-readable code. */
export class DeletePairRejected extends Error {
  constructor(code, status, message) {
    super(message)
    this.code = code
    this.status = status
  }
}

const SLUG_MAX_LENGTH = 200

/** Step 1 gate — the slug shape problem, or null (path-traversal hard gate). */
function slugShapeProblem(slug) {
  if (slug === '') return 'slug 不能为空。'
  if (slug.length > SLUG_MAX_LENGTH) return `slug 长度 ${slug.length} 超过 ${SLUG_MAX_LENGTH} 上限。`
  if (slug.includes('/') || slug.includes('\\') || slug.includes('..')) return 'slug 含路径分隔符或「..」。'
  return null
}

/** Path identity (engine Get-PathIdentity semantics): lowercased repo-relative form. */
function pathIdentity(storedPath, projectRoot) {
  const raw = String(storedPath ?? '')
  if (raw.trim() !== '') {
    const absolute = isAbsolute(raw) ? raw : join(projectRoot, raw)
    try {
      statSync(absolute)
      return relative(projectRoot, absolute).replaceAll('\\', '/').toLowerCase()
    } catch {
      /* unreadable/unresolvable falls back to the raw lowercased form */
    }
  }
  return raw.toLowerCase()
}

/** Step 3 — raw zone read for the write face: missing file is empty, damage rejects. */
function readZoneForWrite(absolutePath, zone) {
  let raw
  try {
    raw = readFileSync(absolutePath, 'utf8')
  } catch (error) {
    if (error != null && error.code === 'ENOENT') return { existed: false, top: { entries: [] }, entries: [] }
    throw new DeletePairRejected('zone-corrupt', 500, `${zone} 文件读取失败（${absolutePath}）：${error instanceof Error ? error.message : String(error)}。写面拒绝在不可读 zone 上执行删除。`)
  }
  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    throw new DeletePairRejected('zone-corrupt', 500, `${zone} 文件解析失败（${absolutePath}）：${error instanceof Error ? error.message : String(error)}。写面拒绝把损坏 zone 当空处理。`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) || !Array.isArray(parsed.entries)) {
    throw new DeletePairRejected('zone-corrupt', 500, `${zone} 文件形状异常（entries 非数组）：${absolutePath}。写面拒绝把损坏 zone 当空处理。`)
  }
  return { existed: true, top: parsed, entries: parsed.entries }
}

/**
 * Atomic zone write mirroring the engine's Write-Index / Write-Hot shape
 * (compact `{"entries":[...]}`, no trailing newline — round-trip compatible).
 * Same-dir tmp → rename, mirroring writeSearchConfigAtomic; the tmp file is
 * best-effort unlinked on failure so a rejected write leaves zero residue.
 */
function writeZoneAtomic(absolutePath, top) {
  const tmp = `${absolutePath}.${process.pid}.tmp`
  const body = JSON.stringify(top)
  try {
    writeFileSync(tmp, body, 'utf8')
    renameSync(tmp, absolutePath)
  } catch (error) {
    try {
      unlinkSync(tmp)
    } catch {
      /* best effort — the rethrown error below is the actionable one */
    }
    throw error
  }
  return { bytes: Buffer.byteLength(body, 'utf8') }
}

/** Steps 3-4 — raw-read both zones and partition each by path identity. */
function prepareZonePlans(context, projectRoot, artifactPath) {
  const identity = relative(projectRoot, artifactPath).replaceAll('\\', '/').toLowerCase()
  const root = join(context.rddRoot, 'exploration')
  const plan = (file, zone) => {
    const state = readZoneForWrite(join(root, file), zone)
    const removed = []
    const kept = []
    for (const entry of state.entries) {
      if (pathIdentity(entry && entry.path, projectRoot) === identity) removed.push(entry)
      else kept.push(entry)
    }
    return { zone, absolutePath: join(root, file), top: state.top, removed, kept }
  }
  return { hot: plan('hot.json', 'hot'), index: plan('index.json', 'index') }
}

/** Rollback: staged files back to their names, written zones back to original bytes. */
function rollbackPairDeletion(staged, written) {
  for (const item of staged) {
    try {
      renameSync(item.tmp, item.original)
    } catch {
      /* best effort — the rethrown cause is the actionable error */
    }
  }
  for (const plan of written) {
    try {
      writeZoneAtomic(plan.absolutePath, plan.top)
    } catch {
      /* best effort */
    }
  }
}

/** Step 7 — physically remove the staged files; returns the rare leftovers. */
function unlinkStaged(staged) {
  const residual = []
  for (const item of staged) {
    try {
      unlinkSync(item.tmp)
    } catch {
      residual.push(item.tmp)
    }
  }
  return residual
}

/** Step 5a: stage the summary file, tolerating one that vanished; null when absent. */
function stageSummaryFile(summaryPath) {
  const tmp = `${summaryPath}.${process.pid}.tmp`
  try {
    renameSync(summaryPath, tmp)
  } catch (error) {
    if (error != null && error.code === 'ENOENT') return null // vanished since the scan: artifact-only delete
    throw error
  }
  return { original: summaryPath, tmp }
}

/** Steps 5-7 — stage → rewrite → unlink; any failure rolls everything back. */
function commitPairDeletion(zones, artifactPath, summaryPath, slug, projectRoot) {
  const staged = []
  const written = []
  try {
    // summary stages first: if the artifact rename then bounces, the rollback
    // surface stays minimal (design step 5)
    const summaryStaged = stageSummaryFile(summaryPath)
    if (summaryStaged !== null) staged.push(summaryStaged)
    const artifactStaged = { original: artifactPath, tmp: `${artifactPath}.${process.pid}.tmp` }
    renameSync(artifactPath, artifactStaged.tmp) // Windows file-lock early detection
    staged.push(artifactStaged)
    for (const plan of [zones.hot, zones.index]) {
      if (plan.removed.length === 0) continue // an unchanged zone stays byte-identical
      writeZoneAtomic(plan.absolutePath, { ...plan.top, entries: plan.kept })
      written.push(plan)
    }
  } catch (error) {
    rollbackPairDeletion(staged, written)
    const detail = error instanceof Error ? error.message : String(error)
    throw new DeletePairRejected('delete-failed', 500, `删除失败：${detail}。已回滚——文件与条目保持删除前状态。`)
  }
  const residual = unlinkStaged(staged)
  return {
    ok: true,
    code: 'deleted',
    slug,
    removed: { hot: zones.hot.removed.length, index: zones.index.removed.length },
    files: staged.map((item) => relative(projectRoot, item.original).replaceAll('\\', '/')),
    ...(residual.length > 0 ? { warning: `物理删除残留（可手工清理）：${residual.join('；')}。` } : {}),
  }
}

/**
 * Delete one artifact pair (write face, artifact-deletion design): remove
 * artifact.md + summary.md and the matching hot.json / index.json entries as
 * one all-or-nothing unit. Orphan pairs (no entry in either zone) are refused.
 * @param {{rddRoot: string, projectRoot?: string}} context
 * @returns {{ok: true, code: string, slug: string, removed: {hot: number, index: number}, files: string[], warning?: string}}
 */
export function deletePair(context, slug) {
  const shapeProblem = slugShapeProblem(slug)
  if (shapeProblem !== null) {
    throw new DeletePairRejected('invalid-payload', 400, `拒绝删除：${shapeProblem}请求体应为 {"slug": "<产物对 slug>"}。`)
  }
  const projectRoot = context.projectRoot ?? join(context.rddRoot, '..')
  const artifactsDir = join(context.rddRoot, 'exploration', 'artifacts')
  const artifactPath = join(artifactsDir, `${slug}.md`)
  const summaryPath = join(artifactsDir, `${slug}.summary.md`)
  let present = false
  try {
    statSync(artifactPath)
    present = true
  } catch {
    /* absence lands in the 404 below (idempotent re-delete semantics) */
  }
  if (!present) {
    throw new DeletePairRejected('pair-not-found', 404, `产物对 ${slug} 不存在（artifacts/ 内无 ${slug}.md）。可能已被删除，数据无需变更。`)
  }
  const zones = prepareZonePlans(context, projectRoot, artifactPath)
  if (zones.hot.removed.length + zones.index.removed.length === 0) {
    throw new DeletePairRejected('orphan-not-deletable', 422, `产物对 ${slug} 为孤儿（hot.json 与 index.json 均无关联条目），不在删除范围内；孤儿清理属缓存维护，不在看板职责内。`)
  }
  return commitPairDeletion(zones, artifactPath, summaryPath, slug, projectRoot)
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

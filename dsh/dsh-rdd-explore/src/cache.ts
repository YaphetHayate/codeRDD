/**
 * RDD exploration cache — the TypeScript port of `rdd-engine/scripts/explore-store.ps1`'s
 * write face and `explore.ps1`'s dual-zone read face. On-disk compatible with the
 * PowerShell implementation so dsh sessions and Claude Code / OpenCode / ZCode
 * clients share one `.rdd/exploration/` cache per repository.
 *
 * Format contract (frozen — change both writers together):
 * - Two index files. The HOT ZONE `hot.json` receives every registration
 *   (`{ "entries": HotEntry[] }`, compact JSON, UTF-8, no BOM); the persistent
 *   `index.json` holds `{ "entries": ExplorationEntry[] }` exactly as before.
 * - Hot entries are index entries plus `registeredAt` (ISO-8601 UTC). Retention
 *   7 days / capacity 50 entries (constants below, mirrored from
 *   explore-store.ps1; the frozen truth source is rdd-engine
 *   references/exploration-guide.md's hot-zone lifecycle table): every
 *   register/persist sweeps — expired or overflowing hot entries are promoted
 *   into index.json AS-IS ("no loss" hard constraint: an explored result never
 *   disappears because an async pipeline never ran). The dsh plugin
 *   additionally drives the same maintenance on a timer via maintainCache
 *   (freshness pass + sweep); the PS CLI stays call-driven.
 * - Promotion is index-first, hot-second, dedupe-replace — idempotent, and an
 *   interrupted promote self-heals via retrieval suppression (hot wins).
 * - Every path is repository-relative with `/` separators (absolute forward-
 *   slash forms from the Windows engine CLI are read compatibly).
 * - An entry's `files` map records `sha256:<lowercase-hex>` digests captured at
 *   registration; a reader re-hashes each file and treats any mismatch or missing
 *   file as stale. A missing artifact file is stale too. Stale entries are
 *   evicted from their own zone; a stale hot entry is dropped, never promoted.
 * - Artifacts are paired: a full record `<path>` always has a summary beside it at
 *   `summaryPathOf(path)`.
 * - SEARCH precision ranking (frozen with rdd-engine scripts/explore.ps1 +
 *   scripts/recallers/*.ps1): search-config.json is the runtime single source
 *   both implementations read; vectors.json is a derived, gitignored sidecar
 *   keyed by (key, textHash, model). Formulas F1-F8 are frozen — see the
 *   precision-ranking section near the end of this file and rdd-engine
 *   references/exploration-guide.md.
 * @module @coderrdd/dsh-rdd-explore/cache
 */

import { createHash } from 'node:crypto'
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve } from 'node:path'

/** Hot-zone retention window in days. Mirror of explore-store.ps1 `$HotRetentionDays` (frozen table: 7). */
export const HOT_RETENTION_DAYS = 7

/** Hot-zone capacity in entries. Mirror of explore-store.ps1 `$HotCapacity` (frozen table: 50). */
export const HOT_CAPACITY = 50

/** One persistent index entry. */
export interface ExplorationEntry {
  /** Semantic key identifying the exploration topic (Chinese allowed). */
  readonly key: string
  /** Keyword tags (module/feature/synonyms) the caller-side LLM matches against. */
  readonly tags: readonly string[]
  /** One-line summary of the artifact. */
  readonly brief: string
  /** Repository-relative POSIX path of the full record. */
  readonly path: string
  /** Repository-relative POSIX path to its `sha256:<hex>` digest at registration time. */
  readonly files: Readonly<Record<string, string>>
}

/** One hot-zone entry: an index entry stamped with its registration time. */
export interface HotEntry extends ExplorationEntry {
  /** ISO-8601 UTC registration stamp; drives hot ordering, TTL, and capacity sweeps. */
  readonly registeredAt: string
}

/** The fresh/stale split of one zone read. */
export interface FreshSelection<T extends ExplorationEntry = ExplorationEntry> {
  /** Entries whose file digests still match and whose artifact still exists. */
  readonly fresh: readonly T[]
  /** Repository-relative paths of stale entries, for zone cleanup. */
  readonly stalePaths: readonly string[]
}

/** Input to one registration. */
export interface RegisterInput {
  readonly key: string
  readonly tags: readonly string[]
  readonly brief: string
  /** Absolute path of the already-written full-record artifact. */
  readonly artifactAbsPath: string
  readonly repoRoot: string
  /** Repository-relative POSIX source-file paths anchoring freshness. */
  readonly files: readonly string[]
}

/** The durable outcome of one registration. */
export interface RegisterResult {
  readonly key: string
  readonly path: string
  readonly summaryPath: string
  readonly tagsCount: number
  readonly filesCount: number
}

/** The durable outcome of one explicit promotion (persist). */
export interface PersistResult {
  readonly key: string
  readonly path: string
  readonly summaryPath: string
}

/** Which zone a merged-read result came from. */
export type ZoneOrigin = 'hot' | 'persistent'

/** One merged dual-zone result with its origin. */
export interface MergedEntry {
  readonly entry: ExplorationEntry
  readonly origin: ZoneOrigin
}

/** The merged dual-zone read: hot first, persistent suppressed by hot collisions. */
export interface MergedRead {
  readonly results: readonly MergedEntry[]
  /** Total stale entries evicted from both zones during this read. */
  readonly staleRemoved: number
}

/**
 * Derive a deterministic, filesystem-safe artifact stem from a semantic key:
 * keep letters (including CJK), digits, `-`, `_`; collapse every other run
 * into one `-`; trim and cap. Colliding keys share one artifact pair, matching
 * the replace-by-key registration rule.
 * @param key - the semantic exploration key.
 * @returns the artifact filename stem.
 */
export function slugifyKey(key: string): string {
  const slug = key.trim().replace(/[^\p{L}\p{N}_-]+/gu, '-').replace(/^-+|-+$/g, '').slice(0, 80)
  return slug === '' ? 'exploration' : slug
}

/**
 * Persist one exploration payload as the paired artifact files. The plugin
 * owns every cache mutation; workers never write.
 * @param artifactsDir - the `.rdd/exploration/artifacts` directory.
 * @param slug - the artifact filename stem from {@link slugifyKey}.
 * @param full - the complete exploration record (markdown).
 * @param summary - the short summary record.
 * @returns the absolute paths of the written full record and summary.
 */
export async function writeArtifacts(
  artifactsDir: string,
  slug: string,
  full: string,
  summary: string,
): Promise<{ readonly fullAbs: string; readonly summaryAbs: string }> {
  await mkdir(artifactsDir, { recursive: true })
  const fullAbs = join(artifactsDir, `${slug}.md`)
  const summaryAbs = join(artifactsDir, `${slug}.summary.md`)
  await writeFile(fullAbs, full, { encoding: 'utf8', flag: 'w' })
  await writeFile(summaryAbs, summary.endsWith('\n') ? summary : `${summary}\n`, { encoding: 'utf8', flag: 'w' })
  return { fullAbs, summaryAbs }
}

/** Absolute path of the persistent index inside an exploration directory. */
export function indexPathOf(explorationDir: string): string {
  return join(explorationDir, 'index.json')
}

/** Absolute path of the hot zone inside an exploration directory. */
export function hotPathOf(explorationDir: string): string {
  return join(explorationDir, 'hot.json')
}

/**
 * Normalize a path to the stored form: repo-relative POSIX when under the
 * root, absolute POSIX otherwise — mirroring explore.ps1's fallback branch.
 */
function repoRelative(repoRoot: string, absPath: string): string {
  const rel = relative(repoRoot, absPath).replaceAll('\\', '/')
  return rel === '..' || rel.startsWith('../') ? absPath.replaceAll('\\', '/') : rel
}

/**
 * Stable comparison identity for a stored artifact path (writers may store
 * repo-relative OR absolute forward-slash forms): repo-relative POSIX when
 * under the root, else the stored form; lowercased on Windows.
 */
function pathIdentityOf(repoRoot: string, stored: string): string {
  const identity = repoRelative(repoRoot, resolveRepoPath(repoRoot, stored))
  return process.platform === 'win32' ? identity.toLowerCase() : identity
}

/**
 * Mirror explore.ps1 `Resolve-RepoPath`: stored paths may be repo-relative OR
 * absolute (on Windows the engine's `Get-NormalizedRelPath` falls back to
 * absolute forward-slash form, because `git rev-parse --show-toplevel` returns
 * forward slashes and its prefix comparison misses). Rooted values pass
 * through; relative ones join the repo root.
 */
function resolveRepoPath(repoRoot: string, stored: string): string {
  return isAbsolute(stored) ? stored : join(repoRoot, stored)
}

/** SHA-256 digest in the index's `sha256:<hex>` form; null when the file is absent. */
async function sha256File(absPath: string): Promise<string | null> {
  try {
    const buf = await readFile(absPath)
    return `sha256:${createHash('sha256').update(buf).digest('hex')}`
  } catch (error: unknown) {
    const code = (error as NodeJS.ErrnoException).code
    // A missing or directory path is a staleness fact, not a failure.
    if (code === 'ENOENT' || code === 'EISDIR') return null
    throw error
  }
}

/** Case-insensitive path equality on Windows, exact elsewhere. */
const samePath = (a: string, b: string): boolean =>
  process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b

/** Whether a path names an existing regular file. */
async function isFile(absPath: string): Promise<boolean> {
  try {
    return (await stat(absPath)).isFile()
  } catch {
    return false
  }
}

/** Parse a hot-zone registeredAt stamp into epoch ms; unparseable sorts oldest (0). */
function hotTimestampOf(entry: HotEntry): number {
  const parsed = Date.parse(entry.registeredAt)
  return Number.isNaN(parsed) ? 0 : parsed
}

/** Derive the paired summary path, mirroring explore.ps1 `Get-SummaryPath`. */
export function summaryPathOf(path: string): string {
  return path.endsWith('.md') ? `${path.slice(0, -'.md'.length)}.summary.md` : `${path}.summary.md`
}

/**
 * Read the persistent index. An absent file is a valid empty cache; a corrupt
 * or unexpected shape fails loud with the rebuild hint instead of returning
 * a silently wrong catalog.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @returns the entries, empty when no index exists yet.
 */
export async function readIndex(explorationDir: string): Promise<readonly ExplorationEntry[]> {
  let raw: string
  try {
    raw = await readFile(indexPathOf(explorationDir), 'utf8')
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (error: unknown) {
    throw new Error(
      `RDD exploration index is corrupt (${indexPathOf(explorationDir)}): ${String(error)}. Delete it to rebuild from artifacts.`,
    )
  }
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray((parsed as { entries?: unknown }).entries)) {
    throw new Error(
      `RDD exploration index has an unexpected shape (${indexPathOf(explorationDir)}); expected { entries: [...] }. Delete it to rebuild.`,
    )
  }
  // Same-process typed boundary: consumers validate what they use.
  return (parsed as { entries: ExplorationEntry[] }).entries
}

/**
 * Write the persistent index compact and BOM-less, creating the exploration
 * directory.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param entries - the complete entry list to persist.
 */
export async function writeIndex(explorationDir: string, entries: readonly ExplorationEntry[]): Promise<void> {
  await mkdir(explorationDir, { recursive: true })
  await writeFile(indexPathOf(explorationDir), JSON.stringify({ entries: [...entries] }), { encoding: 'utf8', flag: 'w' })
}

/**
 * Read the hot zone. Same semantics as {@link readIndex}: absent = empty,
 * corrupt fails loud.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @returns the hot entries, empty when no hot zone exists yet.
 */
export async function readHot(explorationDir: string): Promise<readonly HotEntry[]> {
  let raw: string
  try {
    raw = await readFile(hotPathOf(explorationDir), 'utf8')
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (error: unknown) {
    throw new Error(
      `RDD exploration hot zone is corrupt (${hotPathOf(explorationDir)}): ${String(error)}. Delete it and re-register from artifacts.`,
    )
  }
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray((parsed as { entries?: unknown }).entries)) {
    throw new Error(
      `RDD exploration hot zone has an unexpected shape (${hotPathOf(explorationDir)}); expected { entries: [...] }. Delete it and re-register from artifacts.`,
    )
  }
  return (parsed as { entries: HotEntry[] }).entries
}

/**
 * Write the hot zone compact and BOM-less, creating the exploration directory.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param entries - the complete hot entry list to persist.
 */
export async function writeHot(explorationDir: string, entries: readonly HotEntry[]): Promise<void> {
  await mkdir(explorationDir, { recursive: true })
  await writeFile(hotPathOf(explorationDir), JSON.stringify({ entries: [...entries] }), { encoding: 'utf8', flag: 'w' })
}

// ============================================================================
// Entry serialization. Every compound cache entry — register / persist /
// sweep / merged read-evict / maintenance — is a read-modify-write over
// hot.json/index.json, and the plugin's periodic timer added a second
// concurrent entry source alongside tool calls. Interleaving entries loses
// registrations (violating the no-loss constraint), so all five entries share
// one module-level promise chain. The chain is a module singleton: every
// session fiber in the process serializes through it. Locked entries must
// compose ONLY the unlocked private primitives below — re-acquiring the chain
// from inside an entry deadlocks on itself.
// ============================================================================

/** Tail of the entry-serialization promise chain; never rejects. */
let entryChain: Promise<unknown> = Promise.resolve()

/**
 * Run one compound cache entry under the module-level serialization chain.
 * @param operation - the entry body, composed of unlocked primitives only.
 * @returns the operation's result.
 */
async function withEntryLock<T>(operation: () => Promise<T>): Promise<T> {
  const run = entryChain.then(operation, operation)
  entryChain = run.then(() => undefined, () => undefined)
  return run
}

/**
 * Split entries into fresh and stale by re-hashing every anchor file and
 * checking artifact presence, exactly as explore.ps1 `Select-FreshEntries`
 * does. Generic over the entry shape so the hot zone (with `registeredAt`)
 * reuses it unchanged.
 * @param entries - the full zone content.
 * @param repoRoot - absolute repository root for resolving relative paths.
 * @returns the fresh entries and the stale entry paths.
 */
export async function selectFresh<T extends ExplorationEntry>(
  entries: readonly T[],
  repoRoot: string,
): Promise<FreshSelection<T>> {
  const fresh: T[] = []
  const stalePaths: string[] = []
  for (const entry of entries) {
    let stale = false
    for (const [rel, expected] of Object.entries(entry.files)) {
      const current = await sha256File(resolveRepoPath(repoRoot, rel))
      if (current === null || current !== expected) {
        stale = true
        break
      }
    }
    if (!stale && !(await isFile(resolveRepoPath(repoRoot, entry.path)))) stale = true
    if (stale) stalePaths.push(entry.path)
    else fresh.push(entry)
  }
  return { fresh, stalePaths }
}

/**
 * The promotion primitive: move hot entries into the persistent index AS-IS
 * (stripping `registeredAt`). Pure index-entry move — artifacts never move on
 * disk. Index is written FIRST, hot cleared SECOND: an interrupted promote
 * leaves the entry in both zones and heals via dedupe-replace on the next
 * promote plus same-key/path suppression on every merged read.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root for path-identity dedupe.
 * @param promote - the hot entries to promote.
 * @param remaining - the hot entries that stay in the zone.
 */
async function promoteHotEntries(
  explorationDir: string,
  repoRoot: string,
  promote: readonly HotEntry[],
  remaining: readonly HotEntry[],
): Promise<void> {
  const promoteKeys = new Set(promote.map(entry => entry.key))
  const promoteIdentities = new Set(promote.map(entry => pathIdentityOf(repoRoot, entry.path)))
  const index = await readIndex(explorationDir)
  const kept = index.filter(entry =>
    !promoteKeys.has(entry.key)
    && !promoteIdentities.has(pathIdentityOf(repoRoot, entry.path)))
  const promoted: ExplorationEntry[] = promote.map(entry => ({
    key: entry.key,
    tags: [...entry.tags],
    brief: entry.brief,
    path: entry.path,
    files: { ...entry.files },
  }))
  await writeIndex(explorationDir, [...kept, ...promoted])
  await writeHot(explorationDir, remaining)
}

/**
 * Sweep the hot zone: promote entries past the retention window, then shed
 * capacity overflow oldest-first. `reserve` holds one slot for an incoming
 * registration so the write itself never overflows. Serialized against every
 * other compound cache entry.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root for path-identity dedupe.
 * @param reserve - slots to reserve (register passes 1).
 * @returns the number of entries promoted into the persistent index.
 */
export async function sweepHot(explorationDir: string, repoRoot: string, reserve = 0): Promise<number> {
  return withEntryLock(() => sweepHotUnlocked(explorationDir, repoRoot, reserve))
}

/**
 * Unlocked sweep body — only callable while already holding the entry chain.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root for path-identity dedupe.
 * @param reserve - slots to reserve (register passes 1).
 * @returns the number of entries promoted into the persistent index.
 */
async function sweepHotUnlocked(explorationDir: string, repoRoot: string, reserve: number): Promise<number> {
  const hot = await readHot(explorationDir)
  if (hot.length === 0) return 0
  const cutoff = Date.now() - HOT_RETENTION_DAYS * 24 * 60 * 60 * 1000
  const sorted = [...hot].sort((a, b) => hotTimestampOf(a) - hotTimestampOf(b)) // oldest first
  const promote: HotEntry[] = []
  const remaining: HotEntry[] = []
  for (const entry of sorted) {
    if (hotTimestampOf(entry) < cutoff) promote.push(entry)
    else remaining.push(entry)
  }
  const limit = Math.max(0, HOT_CAPACITY - reserve)
  while (remaining.length > limit) {
    const oldest = remaining.shift()
    if (oldest === undefined) break
    promote.push(oldest)
  }
  if (promote.length > 0) await promoteHotEntries(explorationDir, repoRoot, promote, remaining)
  return promote.length
}

/**
 * Explicitly promote one hot entry by key into the persistent index, then
 * sweep. The async enhancement pipeline's promotion entry point (mirror of
 * `explore-store.ps1 -Type persist`). Serialized against every other
 * compound cache entry.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root for path-identity dedupe.
 * @param key - the hot entry's semantic key.
 * @returns the durable promotion outcome.
 */
export async function persistHotEntry(
  explorationDir: string,
  repoRoot: string,
  key: string,
): Promise<PersistResult> {
  return withEntryLock(async () => {
    const hot = await readHot(explorationDir)
    const idx = hot.findIndex(entry => entry.key === key)
    if (idx < 0) {
      throw new Error(`no hot-zone entry with key '${key}' in ${hotPathOf(explorationDir)} (already persisted, or never registered)`)
    }
    const target = hot[idx] as HotEntry
    const remaining = hot.filter((_, i) => i !== idx)
    await promoteHotEntries(explorationDir, repoRoot, [target], remaining)
    try {
      await sweepHotUnlocked(explorationDir, repoRoot, 0)
    } catch (error: unknown) {
      console.warn(`[rdd-explore] hot-zone sweep failed after persist (retried idempotently on next call): ${String(error)}`)
    }
    return { key: target.key, path: target.path, summaryPath: summaryPathOf(target.path) }
  })
}

/**
 * The merged dual-zone read (mirror of explore.ps1 `Get-MergedFresh`): stale
 * entries are evicted from their own zone (a stale hot entry is dropped,
 * never promoted), fresh hot entries come first (newest registeredAt first,
 * origin `hot`), then persistent entries (origin `persistent`) with key or
 * artifact-path collisions against hot suppressed — the hot view shadows the
 * old persistent one until promotion's dedupe-replace reconciles the index.
 * Serialized against every other compound cache entry.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root.
 * @returns merged results with origins, plus the total stale-eviction count.
 */
export async function mergedFresh(explorationDir: string, repoRoot: string): Promise<MergedRead> {
  return withEntryLock(() => mergedFreshUnlocked(explorationDir, repoRoot))
}

/**
 * Unlocked merged-read body — only callable while already holding the entry
 * chain.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root.
 * @returns merged results with origins, plus the total stale-eviction count.
 */
async function mergedFreshUnlocked(explorationDir: string, repoRoot: string): Promise<MergedRead> {
  const index = await readIndex(explorationDir)
  const indexSel = await selectFresh(index, repoRoot)
  if (indexSel.stalePaths.length > 0) {
    await writeIndex(explorationDir, index.filter(entry => !indexSel.stalePaths.includes(entry.path)))
  }
  const hot = await readHot(explorationDir)
  const hotSel = await selectFresh(hot, repoRoot)
  if (hotSel.stalePaths.length > 0) {
    await writeHot(explorationDir, hot.filter(entry => !hotSel.stalePaths.includes(entry.path)))
  }
  const hotFresh = [...hotSel.fresh].sort((a, b) => hotTimestampOf(b) - hotTimestampOf(a))
  const hotKeys = new Set(hotFresh.map(entry => entry.key))
  const hotIdentities = new Set(hotFresh.map(entry => pathIdentityOf(repoRoot, entry.path)))
  const persistFresh = indexSel.fresh.filter(entry =>
    !hotKeys.has(entry.key)
    && !hotIdentities.has(pathIdentityOf(repoRoot, entry.path)))
  return {
    results: [
      ...hotFresh.map(entry => ({ entry, origin: 'hot' as const })),
      ...persistFresh.map(entry => ({ entry, origin: 'persistent' as const })),
    ],
    staleRemoved: indexSel.stalePaths.length + hotSel.stalePaths.length,
  }
}

/** The outcome of one full maintenance pass over both zones. */
export interface MaintenanceResult {
  /** Stale entries evicted from both zones by the freshness pass. */
  readonly staleRemoved: number
  /** Hot entries promoted into the persistent index by the sweep. */
  readonly promoted: number
}

/**
 * One full maintenance pass over both zones — the timer-driven twin of the
 * call-driven maintenance. Freshness first (stale entries evicted from their
 * own zone, so a stale hot entry is dropped and never promoted), then the
 * sweep (retention-expired or capacity-overflowing hot entries promoted
 * AS-IS through the index-first no-loss write order). Idempotent: an empty
 * or already-maintained cache is a no-op. Serialized against every other
 * compound cache entry.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param repoRoot - absolute repository root.
 * @returns the stale-eviction and promotion counts of this pass.
 */
export async function maintainCache(explorationDir: string, repoRoot: string): Promise<MaintenanceResult> {
  return withEntryLock(async () => {
    const { staleRemoved } = await mergedFreshUnlocked(explorationDir, repoRoot)
    const promoted = await sweepHotUnlocked(explorationDir, repoRoot, 0)
    return { staleRemoved, promoted }
  })
}

/**
 * Register one artifact into the HOT ZONE: validate pairing, hash the anchor
 * files, sweep (reserving one slot; failure warns and continues — the hot
 * write below is what guarantees no loss), drop an existing HOT entry with
 * the same key or artifact identity, and persist. Persistent-index entries
 * with the same key stay untouched — retrieval shadows them and promotion's
 * dedupe-replace reconciles later. Mirrors explore-store.ps1 `-Type register`
 * including its failure modes. Serialized against every other compound cache
 * entry (a timer-driven maintenance never drops an in-flight registration).
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param input - the registration input.
 * @returns the durable registration outcome.
 */
export async function registerEntry(explorationDir: string, input: RegisterInput): Promise<RegisterResult> {
  return withEntryLock(async () => {
    const tags = input.tags.map(tag => tag.trim()).filter(tag => tag !== '')
    if (tags.length === 0) {
      throw new Error('registering an exploration artifact requires at least one non-empty tag')
    }
    if (!(await isFile(input.artifactAbsPath))) {
      throw new Error(`exploration artifact not found: ${input.artifactAbsPath}`)
    }
    const path = repoRelative(input.repoRoot, input.artifactAbsPath)
    const summaryPath = summaryPathOf(path)
    if (!(await isFile(join(input.repoRoot, summaryPath)))) {
      throw new Error(
        `paired summary not found: ${summaryPath} (the full record and its summary must be written together)`,
      )
    }
    const files: Record<string, string> = {}
    for (const rel of input.files) {
      const hash = await sha256File(resolveRepoPath(input.repoRoot, rel))
      if (hash === null) {
        throw new Error(`cannot hash anchor file (not found): ${rel}`)
      }
      files[rel] = hash
    }
    // Sweep before the write, reserving this entry's slot. Failure must not
    // block registration: no-loss is guaranteed by the hot write itself.
    try {
      await sweepHotUnlocked(explorationDir, input.repoRoot, 1)
    } catch (error: unknown) {
      console.warn(`[rdd-explore] hot-zone sweep failed (register proceeds; retried idempotently on next call): ${String(error)}`)
    }
    // Dedupe ONLY within the hot zone, by key OR by resolved artifact identity,
    // so a relative-form registration replaces an absolute-form entry written by
    // the engine CLI (and vice versa) for the same file.
    const artifactAbs = resolve(input.artifactAbsPath)
    const newIdentity = pathIdentityOf(input.repoRoot, path)
    const hot = await readHot(explorationDir)
    const kept = hot.filter(entry =>
      entry.key !== input.key
      && pathIdentityOf(input.repoRoot, entry.path) !== newIdentity
      && !samePath(resolveRepoPath(input.repoRoot, entry.path), artifactAbs))
    kept.push({
      key: input.key,
      tags,
      brief: input.brief,
      path,
      files,
      registeredAt: new Date().toISOString(),
    })
    await writeHot(explorationDir, kept)
    return { key: input.key, path, summaryPath, tagsCount: tags.length, filesCount: input.files.length }
  })
}

// ============================================================================
// Search precision ranking (frozen contract with rdd-engine scripts/explore.ps1
// + scripts/recallers/*.ps1). Pipeline: pluggable multi-recall (lexical BM25 +
// vector cosine) -> RRF fusion (F7) -> Top-K truncation (F8), stacked ON TOP of
// mergedFresh — the read face itself is untouched. See rdd-engine
// references/exploration-guide.md for the frozen formulas F1-F8.
// ============================================================================

/** One recaller's enabled setting: on, off, or "auto" (config-gated). */
export type RecallerEnabled = boolean | 'auto'

/** The lexical recaller's config section (mirrors explore.ps1 defaults). */
export interface LexicalRecallerConfig {
  enabled: RecallerEnabled
  weight: number
  bm25K1: number
  bm25B: number
}

/** The vector recaller's config section (mirrors explore.ps1 defaults). */
export interface VectorRecallerConfig {
  enabled: RecallerEnabled
  weight: number
  endpoint: string
  model: string
  dimensions: number
  minCosine: number
  timeoutSeconds: number
}

/** The full .rdd/exploration/search-config.json shape (all fields optional on disk). */
export interface SearchConfig {
  topK: number
  recallDepth: number
  rrfK: number
  recallers: {
    lexical: LexicalRecallerConfig
    vector: VectorRecallerConfig
  }
}

/**
 * Frozen default values — literal mirror of explore.ps1 `$SearchDefaults` and
 * explore-store.ps1 `$EmbedDefaults`. PS and TS read the SAME search-config.json,
 * so these defaults are the behavior-parity anchor of last resort.
 */
export const SEARCH_CONFIG_DEFAULTS: Readonly<SearchConfig> = Object.freeze({
  topK: 5,
  recallDepth: 20,
  rrfK: 60,
  recallers: {
    lexical: Object.freeze({ enabled: true, weight: 1.0, bm25K1: 1.2, bm25B: 0.75 }),
    vector: Object.freeze({
      enabled: 'auto',
      weight: 1.0,
      endpoint: '',
      model: '',
      dimensions: 0,
      minCosine: 0.30,
      timeoutSeconds: 10,
    }),
  },
})

/** A fresh mutable copy of {@link SEARCH_CONFIG_DEFAULTS} as a merge base. */
function searchConfigDefaults(): SearchConfig {
  return {
    topK: SEARCH_CONFIG_DEFAULTS.topK,
    recallDepth: SEARCH_CONFIG_DEFAULTS.recallDepth,
    rrfK: SEARCH_CONFIG_DEFAULTS.rrfK,
    recallers: {
      lexical: { ...SEARCH_CONFIG_DEFAULTS.recallers.lexical },
      vector: { ...SEARCH_CONFIG_DEFAULTS.recallers.vector },
    },
  }
}

/** Absolute path of search-config.json inside an exploration directory. */
export function searchConfigPathOf(explorationDir: string): string {
  return join(explorationDir, 'search-config.json')
}

/** Absolute path of the vectors sidecar inside an exploration directory. */
export function vectorsPathOf(explorationDir: string): string {
  return join(explorationDir, 'vectors.json')
}

// Field validators — exact mirrors of explore.ps1's Get-SearchConfigValue
// validators (invalid or unknown values silently keep the default; only
// file-level corruption warns, fail-soft like the PS side).
const isPositiveInt = (v: unknown): v is number => typeof v === 'number' && Number.isInteger(v) && v >= 1
const isPositiveNumber = (v: unknown): v is number => typeof v === 'number' && v > 0
const isNonNegativeNumber = (v: unknown): v is number => typeof v === 'number' && v >= 0
const isEnabledValue = (v: unknown): v is RecallerEnabled => typeof v === 'boolean' || v === 'auto'
const isString = (v: unknown): v is string => typeof v === 'string'
const isDimension = (v: unknown): v is number => typeof v === 'number' && Number.isInteger(v) && v >= 0
const isUnitInterval = (v: unknown): v is number => typeof v === 'number' && v >= 0 && v <= 1
const isCosineRange = (v: unknown): v is number => typeof v === 'number' && v >= -1 && v <= 1
const isTimeout = (v: unknown): v is number => typeof v === 'number' && v >= 1

function pick<T>(source: object, field: string, current: T, valid: (v: unknown) => v is T): T {
  const value: unknown = (source as Record<string, unknown>)[field]
  return valid(value) ? value : current
}

/**
 * Read search-config.json. Absent file = defaults (silent); unreadable or
 * corrupt file = defaults + a stderr warning — the fail-soft asymmetry vs the
 * fail-loud index data is intentional (tuning file vs source data), mirroring
 * explore.ps1 `Read-SearchConfig` and explore-store.ps1 exactly.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @returns the fully-merged effective config.
 */
export async function readSearchConfig(explorationDir: string): Promise<SearchConfig> {
  const config = searchConfigDefaults()
  let raw: string
  try {
    raw = await readFile(searchConfigPathOf(explorationDir), 'utf8')
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.warn(`[rdd-explore] search-config.json unreadable (built-in defaults apply): ${String(error)}`)
    }
    return config
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (error: unknown) {
    console.warn(`[rdd-explore] search-config.json unreadable (built-in defaults apply): ${String(error)}`)
    return config
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return config
  const root = parsed as Record<string, unknown>
  config.topK = pick(root, 'topK', config.topK, isPositiveInt)
  config.recallDepth = pick(root, 'recallDepth', config.recallDepth, isPositiveInt)
  config.rrfK = pick(root, 'rrfK', config.rrfK, isPositiveNumber)

  const recallers = root.recallers
  if (recallers !== null && typeof recallers === 'object' && !Array.isArray(recallers)) {
    const sections = recallers as Record<string, unknown>
    const lexical = sections.lexical
    if (lexical !== null && typeof lexical === 'object' && !Array.isArray(lexical)) {
      const section = lexical as Record<string, unknown>
      config.recallers.lexical = {
        enabled: pick(section, 'enabled', config.recallers.lexical.enabled, isEnabledValue),
        weight: pick(section, 'weight', config.recallers.lexical.weight, isPositiveNumber),
        bm25K1: pick(section, 'bm25K1', config.recallers.lexical.bm25K1, isNonNegativeNumber),
        bm25B: pick(section, 'bm25B', config.recallers.lexical.bm25B, isUnitInterval),
      }
    }
    const vector = sections.vector
    if (vector !== null && typeof vector === 'object' && !Array.isArray(vector)) {
      const section = vector as Record<string, unknown>
      config.recallers.vector = {
        enabled: pick(section, 'enabled', config.recallers.vector.enabled, isEnabledValue),
        weight: pick(section, 'weight', config.recallers.vector.weight, isPositiveNumber),
        endpoint: pick(section, 'endpoint', config.recallers.vector.endpoint, isString),
        model: pick(section, 'model', config.recallers.vector.model, isString),
        dimensions: pick(section, 'dimensions', config.recallers.vector.dimensions, isDimension),
        minCosine: pick(section, 'minCosine', config.recallers.vector.minCosine, isCosineRange),
        timeoutSeconds: pick(section, 'timeoutSeconds', config.recallers.vector.timeoutSeconds, isTimeout),
      }
    }
  }
  return config
}

/** One vectors.json sidecar entry; primary key = (key, textHash, model). */
export interface VectorSidecarEntry {
  readonly key: string
  readonly textHash: string
  readonly model: string
  readonly vector: readonly number[]
}

/**
 * Read the vectors sidecar. Derived, rebuildable data — absent = empty
 * (silent), unreadable/corrupt = empty + a warning (embed-backfill rebuilds);
 * the fail-soft asymmetry vs index.json is intentional, mirroring the PS side.
 * @param explorationDir - the `.rdd/exploration` directory.
 */
export async function readVectors(explorationDir: string): Promise<VectorSidecarEntry[]> {
  let raw: string
  try {
    raw = await readFile(vectorsPathOf(explorationDir), 'utf8')
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.warn(`[rdd-explore] vectors.json unreadable (treated as empty; embed-backfill rebuilds it): ${String(error)}`)
    }
    return []
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (error: unknown) {
    console.warn(`[rdd-explore] vectors.json unreadable (treated as empty; embed-backfill rebuilds it): ${String(error)}`)
    return []
  }
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray((parsed as { entries?: unknown }).entries)) {
    return []
  }
  const entries = (parsed as { entries: unknown[] }).entries
  const clean: VectorSidecarEntry[] = []
  for (const entry of entries) {
    if (entry === null || typeof entry !== 'object') continue
    const e = entry as Partial<VectorSidecarEntry>
    if (
      typeof e.key !== 'string' || typeof e.textHash !== 'string' || typeof e.model !== 'string'
      || !Array.isArray(e.vector) || !e.vector.every((n): n is number => typeof n === 'number')
    ) {
      continue
    }
    clean.push({ key: e.key, textHash: e.textHash, model: e.model, vector: e.vector })
  }
  return clean
}

/**
 * Write the vectors sidecar compact and BOM-less, creating the directory.
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param entries - the complete sidecar content.
 */
export async function writeVectors(explorationDir: string, entries: readonly VectorSidecarEntry[]): Promise<void> {
  await mkdir(explorationDir, { recursive: true })
  await writeFile(
    vectorsPathOf(explorationDir),
    JSON.stringify({ entries: entries.map(entry => ({ ...entry, vector: [...entry.vector] })) }),
    { encoding: 'utf8', flag: 'w' },
  )
}

/**
 * Upsert one sidecar entry by its (key, textHash, model) primary key: an exact
 * triple match is replaced, otherwise the entry is appended. Other models'
 * vectors coexist untouched (frozen rule).
 * @param explorationDir - the `.rdd/exploration` directory.
 * @param entry - the entry to upsert.
 */
export async function upsertVectorEntry(explorationDir: string, entry: VectorSidecarEntry): Promise<void> {
  const entries = await readVectors(explorationDir)
  const idx = entries.findIndex(
    candidate => candidate.key === entry.key && candidate.textHash === entry.textHash && candidate.model === entry.model)
  const next = idx >= 0
    ? entries.map((candidate, i) => (i === idx ? entry : candidate))
    : [...entries, entry]
  await writeVectors(explorationDir, next)
}

/**
 * F1 (frozen): the retrieval text both recallers share —
 * `key + "\n" + tags.join(",") + "\n" + brief`.
 */
export function searchTextOf(key: string, tags: readonly string[], brief: string): string {
  return `${key}\n${tags.join(',')}\n${brief}`
}

/** F2 (frozen): "sha256:" + the lowercase hex SHA-256 of the UTF-8 text. */
export function textHashOf(text: string): string {
  return `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`
}

const TOKEN_RUN = /[a-z0-9]+|[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+/g

/**
 * F3 (frozen): lowercase, then ASCII `[a-z0-9]+` runs are tokens and CJK runs
 * (`[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+`) emit the WHOLE run plus every
 * adjacent 2-char gram. Returns the token MULTISET — a 2-char CJK run yields
 * the same string twice (whole + bigram), exactly like the PS mirror.
 */
export function tokenizeSearchText(text: string): string[] {
  const tokens: string[] = []
  const lower = text.toLowerCase()
  for (const match of lower.matchAll(TOKEN_RUN)) {
    const run = match[0]
    tokens.push(run)
    const first = run.codePointAt(0) ?? 0
    if (first > 0x7f) {
      for (let i = 0; i + 2 <= run.length; i += 1) tokens.push(run.slice(i, i + 2))
    }
  }
  return tokens
}

/**
 * F5 (frozen): POST {endpoint} with `{ model, input: [texts] }`, Bearer key
 * from RDD_EMBED_APIKEY, take `data[i].embedding` in input order
 * (OpenAI-compatible de-facto standard). `fetchImpl` is injectable for tests;
 * production callers use the global fetch.
 * @param vector - the vector recaller config (endpoint/model/timeoutSeconds).
 * @param texts - the texts to embed.
 * @param apiKey - the bearer key (already read from the environment).
 * @param fetchImpl - fetch implementation override (tests).
 * @returns one embedding array per input text, in order.
 */
export async function embedTexts(
  vector: Pick<VectorRecallerConfig, 'endpoint' | 'model' | 'timeoutSeconds'>,
  texts: readonly string[],
  apiKey: string,
  fetchImpl: typeof globalThis.fetch = globalThis.fetch,
): Promise<number[][]> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), Math.max(1, vector.timeoutSeconds) * 1000)
  try {
    const response = await fetchImpl(vector.endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ model: vector.model, input: [...texts] }),
      signal: controller.signal,
    })
    if (!response.ok) {
      throw new Error(`embedding endpoint ${vector.endpoint} responded ${response.status} ${response.statusText}`)
    }
    const payload = (await response.json()) as { data?: unknown }
    if (payload === null || typeof payload !== 'object' || !Array.isArray(payload.data)) {
      throw new Error(`embedding response missing data[] (endpoint: ${vector.endpoint})`)
    }
    return payload.data.map((item: unknown, index: number): number[] => {
      const embedding = (item as { embedding?: unknown }).embedding
      if (!Array.isArray(embedding) || !embedding.every((n): n is number => typeof n === 'number')) {
        throw new Error(`embedding ${index} is missing or not numeric (endpoint: ${vector.endpoint})`)
      }
      return embedding
    })
  } finally {
    clearTimeout(timer)
  }
}

/** One doc as the recaller contract sees it (origin-tagged, tags normalized). */
export interface RecallerDoc {
  readonly key: string
  readonly tags: readonly string[]
  readonly brief: string
  readonly path: string
  readonly origin: ZoneOrigin
}

/** Everything a recaller receives; recallers never reach back into the host. */
export interface RecallerContext {
  readonly query: string
  readonly docs: readonly RecallerDoc[]
  readonly config: SearchConfig
  readonly paths: { readonly vectorsPath: string }
}

/** One recaller run's output: only scores + the qualified (desc) key list. */
export interface RecallerResult {
  readonly name: string
  readonly scores: Readonly<Record<string, number>>
  readonly qualified: readonly string[]
  readonly warning?: string | undefined
}

/** The "auto" enablement verdict for one recaller. */
export interface AutoReadyVerdict {
  readonly ready: boolean
  readonly reason?: string | undefined
}

/**
 * A recaller plugin (mirror of the PS `Register-Recaller` contract). A new
 * recaller joins by adding a file to recallers/ that exports this shape —
 * existing paths change nothing.
 */
export interface Recaller {
  readonly name: string
  readonly defaultEnabled: RecallerEnabled
  /** Evaluate the "auto" rule without running (no API calls). */
  autoReady?(config: SearchConfig): AutoReadyVerdict
  run(ctx: RecallerContext): Promise<RecallerResult>
}

/** One recall path's observable outcome in rankMeta. */
export interface RankOutcome {
  readonly name: string
  readonly status: 'ok' | 'disabled' | 'failed'
  readonly qualified: number
  readonly warning?: string | undefined
}

/** The ranked search result projected for callers (superset of the old view). */
export interface RankedResult {
  readonly key: string
  readonly tags: readonly string[]
  readonly brief: string
  readonly summaryPath: string
  readonly fullPath: string
  readonly origin: ZoneOrigin
  readonly score: number
  readonly recalledBy: readonly string[]
}

/** Pipeline observability: per-recaller outcomes plus fusion/truncation counts. */
export interface RankMeta {
  readonly recallers: readonly RankOutcome[]
  readonly fused: number
  readonly returned: number
}

/** The whole recall-fuse-truncate pipeline's output. */
export interface PipelineOutput {
  readonly results: readonly RankedResult[]
  readonly rankMeta: RankMeta
}

/** One qualified list entering RRF fusion (F7). */
export interface QualifiedList {
  readonly name: string
  readonly qualified: readonly string[]
  readonly weight: number
}

/** A doc's fused RRF score and the recall paths that qualified it. */
export interface FusedDoc {
  readonly score: number
  readonly recalledBy: readonly string[]
}

/**
 * F7 (frozen): `score(d) = SUM_r weight_r / (rrfK + rank_r(d))`, rank from 1,
 * accumulated per recaller in list order over each qualified list — the same
 * accumulation order as the PS mirror, so double arithmetic matches.
 * @param lists - the qualified lists (registration order), with weights.
 * @param rrfK - the RRF k constant (default 60).
 */
export function rrfFuse(lists: readonly QualifiedList[], rrfK: number): Map<string, FusedDoc> {
  const fused = new Map<string, FusedDoc>()
  for (const list of lists) {
    list.qualified.forEach((key, index) => {
      const rank = index + 1
      const contribution = list.weight / (rrfK + rank)
      const previous = fused.get(key)
      if (previous === undefined) {
        fused.set(key, { score: contribution, recalledBy: [list.name] })
      } else {
        fused.set(key, { score: previous.score + contribution, recalledBy: [...previous.recalledBy, list.name] })
      }
    })
  }
  return fused
}

const round6 = (value: number): number => Math.round(value * 1e6) / 1e6

/** registeredAt as epoch ms for hot entries; persistent entries sort as 0 (oldest). */
function rankTimestampOf(entry: ExplorationEntry, origin: ZoneOrigin): number {
  if (origin !== 'hot') return 0
  const parsed = Date.parse((entry as HotEntry).registeredAt)
  return Number.isNaN(parsed) ? 0 : parsed
}

/**
 * F8 (frozen total order): score DESC -> origin hot first -> registeredAt DESC
 * (persistent = oldest) -> key ordinal ASC; then Top-K truncation.
 * @param merged - the merged dual-zone pool (any order).
 * @param fused - the RRF fusion output.
 * @param topK - the truncation size.
 */
export function topKSelect(merged: readonly MergedEntry[], fused: Map<string, FusedDoc>, topK: number): RankedResult[] {
  const candidates: Array<{ entry: ExplorationEntry; origin: ZoneOrigin; score: number; recalledBy: readonly string[] }> = []
  for (const { entry, origin } of merged) {
    const fusedDoc = fused.get(entry.key)
    if (fusedDoc === undefined) continue
    candidates.push({ entry, origin, score: fusedDoc.score, recalledBy: fusedDoc.recalledBy })
  }
  candidates.sort((a, b) => {
    // F8 frozen order: score DESC, hot origin first, registeredAt DESC
    // (persistent = oldest), key ordinal ASC. Raw differences are the
    // standard idioms (positive puts `a` after `b`).
    const byScore = b.score - a.score
    if (byScore !== 0) return byScore
    const aHot = a.origin === 'hot'
    const bHot = b.origin === 'hot'
    if (aHot !== bHot) return aHot ? -1 : 1
    const byTime = rankTimestampOf(a.entry, a.origin) - rankTimestampOf(b.entry, b.origin)
    if (byTime !== 0) return -byTime
    return a.entry.key < b.entry.key ? -1 : a.entry.key > b.entry.key ? 1 : 0
  })
  return candidates.slice(0, Math.max(0, topK)).map(({ entry, origin, score, recalledBy }) => ({
    key: entry.key,
    tags: [...entry.tags],
    brief: entry.brief,
    summaryPath: summaryPathOf(entry.path),
    fullPath: entry.path,
    origin,
    score: round6(score),
    recalledBy: [...recalledBy],
  }))
}

/**
 * Run the whole precision pipeline over a merged pool: every registered
 * recaller (disabled/auto/failed paths degrade to empty contributions plus
 * rankMeta outcomes — the interface stays complete on any single-path
 * failure), then RRF fusion, then Top-K truncation. Results non-empty = HIT
 * (the interface's deterministic relevance verdict), empty = MISS.
 * @param input - the query, merged pool, effective config, exploration dir,
 *   and the recallers (registration order = F7 accumulation order).
 */
export async function runRecallPipeline(input: {
  readonly query: string
  readonly merged: readonly MergedEntry[]
  readonly config: SearchConfig
  readonly explorationDir: string
  readonly recallers: readonly Recaller[]
}): Promise<PipelineOutput> {
  const docs: RecallerDoc[] = input.merged.map(({ entry, origin }) => ({
    key: entry.key,
    tags: [...entry.tags],
    brief: entry.brief,
    path: entry.path,
    origin,
  }))
  const ctx: RecallerContext = {
    query: input.query,
    docs,
    config: input.config,
    paths: { vectorsPath: vectorsPathOf(input.explorationDir) },
  }

  const outcomes: RankOutcome[] = []
  const lists: QualifiedList[] = []
  for (const recaller of input.recallers) {
    const section: Partial<LexicalRecallerConfig & VectorRecallerConfig> | undefined
      = (input.config.recallers as Record<string, Partial<LexicalRecallerConfig & VectorRecallerConfig> | undefined>)[recaller.name]
    let enabled: RecallerEnabled = section?.enabled ?? recaller.defaultEnabled
    if (enabled === 'auto') {
      const verdict = recaller.autoReady === undefined ? { ready: true } : recaller.autoReady(input.config)
      if (!verdict.ready) {
        outcomes.push({ name: recaller.name, status: 'disabled', qualified: 0, warning: verdict.reason })
        continue
      }
      enabled = true
    }
    if (enabled !== true) {
      outcomes.push({ name: recaller.name, status: 'disabled', qualified: 0 })
      continue
    }
    try {
      const result = await recaller.run(ctx)
      outcomes.push({ name: result.name, status: 'ok', qualified: result.qualified.length, warning: result.warning })
      lists.push({ name: result.name, qualified: result.qualified, weight: section?.weight ?? 1 })
    } catch (error: unknown) {
      outcomes.push({ name: recaller.name, status: 'failed', qualified: 0, warning: String(error) })
    }
  }

  const fused = rrfFuse(lists, input.config.rrfK)
  const results = topKSelect(input.merged, fused, input.config.topK)
  return {
    results,
    rankMeta: { recallers: outcomes, fused: fused.size, returned: results.length },
  }
}

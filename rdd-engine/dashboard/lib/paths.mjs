// Data-root resolution + the single-source fixture exclusion rule.
//
// Two responsibilities only: locate the RDD project root (so every reader can
// resolve ".rdd/<domain>"), and answer "does this path belong to test fixture
// data?" — the invariant the UX spec (§6.8, CTO carry-forward note) makes a
// hard requirement: fixture noise must never reach a statistic, chart, list or
// count badge.
import { existsSync } from 'node:fs'
import { dirname, isAbsolute, join, resolve, sep } from 'node:path'

/** Sentinel years used by fixture generators ("2099-12-31-qa-fixture-*"). */
const SENTINEL_DATE_PATTERN = /\d{4}-12-31-qa-/

/** Directory/file name fragments that mark generated test fixtures. */
const FIXTURE_FRAGMENTS = ['qa-fixture', 'qa-bridge']

/** Auto-generated fixture prefixes (e.g. "qa-n5", "qa-head-scan"). */
const FIXTURE_PREFIX = 'qa-'

/** Path segments that hold scratch/e2e noise in every RDD project. */
const SCRATCH_SEGMENTS = new Set(['tmp'])

/**
 * Entries that mark a ".rdd" directory as a *project data root* rather than the
 * user-level skills install (~/.rdd/skills), which must never satisfy the walk —
 * accepting it would silently render an empty board instead of failing loudly.
 */
const DATA_ROOT_MARKERS = [
  'changes',
  'exploration',
  'goal-trees',
  'goal-trees-archive',
  'tips',
  'tests',
  'design-system',
  'handoff',
  'labs',
  'review-ledger.jsonl',
]

/**
 * Split a path into its segments, tolerating both separators.
 * @param {string} candidate
 * @returns {string[]}
 */
function segmentsOf(candidate) {
  return String(candidate)
    .split(/[\\/]+/)
    .filter((segment) => segment !== '' && segment !== '.')
}

/**
 * Decide whether one path segment names scratch or fixture data.
 * @param {string} segment
 * @returns {boolean}
 */
function isExcludedSegment(segment) {
  const lowered = segment.toLowerCase()
  if (SCRATCH_SEGMENTS.has(lowered)) return true
  if (FIXTURE_FRAGMENTS.some((fragment) => lowered.includes(fragment))) return true
  if (SENTINEL_DATE_PATTERN.test(lowered)) return true
  if (lowered.startsWith(FIXTURE_PREFIX)) return true
  return false
}

/**
 * The single source of truth for fixture exclusion: true when ANY path segment
 * is a scratch/fixture name. Readers must funnel every enumerated entry through
 * here instead of re-implementing the rule.
 * @param {string} candidate path (absolute or relative, any separator)
 * @returns {boolean}
 */
export function isExcludedPath(candidate) {
  if (candidate === null || candidate === undefined) return true
  return segmentsOf(candidate).some(isExcludedSegment)
}

/**
 * True when a ".rdd" directory carries at least one dashboard data domain.
 * @param {string} rddRoot
 * @returns {boolean}
 */
export function looksLikeDataRoot(rddRoot) {
  return DATA_ROOT_MARKERS.some((marker) => existsSync(join(rddRoot, marker)))
}

/**
 * Walk up from a directory until a ".rdd" data root is found.
 * Pure directory traversal — never spawns git, so it works in any checkout.
 * @param {string} startDir
 * @returns {string|null} the project root that owns ".rdd", or null
 */
function findRootUpwards(startDir) {
  let current = resolve(startDir)
  for (;;) {
    const rddRoot = join(current, '.rdd')
    if (existsSync(rddRoot) && looksLikeDataRoot(rddRoot)) return current
    const parent = dirname(current)
    if (parent === current) return null
    current = parent
  }
}

/**
 * Two-verdict validation of a candidate project root (single source for the
 * runtime data-root switch AND the RDD_PROJECT_ROOT branch — the rejection
 * wording must never drift between the two callers).
 * Reuses looksLikeDataRoot only; it never invents a second marker rule.
 * @param {string} candidate directory the user picked or pasted
 * @returns {{ok: true, projectRoot: string, rddRoot: string}|{ok: false, code: 'no-rdd-dir'|'not-data-root', message: string}}
 */
export function validateProjectRoot(candidate) {
  const input = String(candidate ?? '').trim()
  if (input === '') {
    return { ok: false, code: 'no-rdd-dir', message: '路径为空，未提供 RDD 项目目录。' }
  }
  const projectRoot = resolve(input)
  const rddRoot = join(projectRoot, '.rdd')
  if (!existsSync(rddRoot)) {
    return {
      ok: false,
      code: 'no-rdd-dir',
      message: `所选目录下没有 .rdd/ 数据目录。${projectRoot} 不是 RDD 项目目录。`,
    }
  }
  if (looksLikeDataRoot(rddRoot)) {
    return { ok: true, projectRoot, rddRoot }
  }
  return {
    ok: false,
    code: 'not-data-root',
    message: `.rdd/ 缺少数据域标记。${rddRoot} 存在 .rdd/ 但没有 changes/、tips/、exploration/ 等数据目录，不是项目数据根。`,
  }
}

/**
 * Resolve the RDD project root and its data root.
 * Priority: RDD_PROJECT_ROOT env var, then nearest ".rdd" ancestor of cwd.
 * Missing roots throw with an actionable message instead of serving empty data.
 * @param {{env?: Record<string, string|undefined>, cwd?: string}} [options]
 * @returns {{projectRoot: string, rddRoot: string, source: string}}
 */
export function resolveDataRoot(options = {}) {
  const env = options.env ?? process.env
  const cwd = options.cwd ?? process.cwd()
  const explicit = (env.RDD_PROJECT_ROOT ?? '').trim()
  if (explicit !== '') {
    const projectRoot = isAbsolute(explicit) ? explicit : resolve(cwd, explicit)
    const verdict = validateProjectRoot(projectRoot)
    if (verdict.ok !== true) {
      throw new Error(`RDD_PROJECT_ROOT 无效：${verdict.message}`)
    }
    return { projectRoot: verdict.projectRoot, rddRoot: verdict.rddRoot, source: 'RDD_PROJECT_ROOT' }
  }
  const found = findRootUpwards(cwd)
  if (found === null) {
    throw new Error(
      '未找到 .rdd/ 数据根目录。处置：在 RDD 项目目录内启动，或设置环境变量 RDD_PROJECT_ROOT。'
    )
  }
  return { projectRoot: found, rddRoot: join(found, '.rdd'), source: 'cwd-walk' }
}

/**
 * Join segments under the RDD data root.
 * @param {{rddRoot: string}} context
 * @param {...string} parts
 * @returns {string}
 */
export function rddPath(context, ...parts) {
  return join(context.rddRoot, ...parts)
}

/** @returns {string} the project root relative form used by the repo */
export function toPosix(candidate) {
  return candidate.split(sep).join('/')
}

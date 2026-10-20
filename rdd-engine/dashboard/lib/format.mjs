// Formatting primitives shared by every view.
//
// Timestamps in .rdd/ are ISO-8601 UTC (query log, tip records, tree state).
// The dashboard renders them verbatim in UTC and labels the column "UTC" —
// converting to a local zone would make the numbers disagree with the raw data
// users inspect next to it.

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }

/**
 * Escape text for HTML text nodes and attribute values.
 * @param {unknown} value
 * @returns {string}
 */
export function esc(value) {
  if (value === null || value === undefined) return ''
  return String(value).replace(/[&<>"']/g, (char) => HTML_ESCAPES[char])
}

/**
 * Render a number with thousands separators (locale-independent rounding).
 * @param {unknown} value
 * @returns {string}
 */
export function num(value) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return '—'
  return parsed.toLocaleString('en-US')
}

/**
 * Render a percentage with one decimal place.
 * @param {number|null} value
 * @returns {string}
 */
export function percent(value) {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return '—'
  return `${Number(value).toFixed(1)}%`
}

/** @returns {string} "YYYY-MM-DD" from an ISO stamp (empty input → "—") */
export function dateOnly(iso) {
  if (typeof iso !== 'string' || iso.length < 10) return '—'
  return iso.slice(0, 10)
}

/** @returns {string} "YYYY-MM-DD HH:MM" (UTC) from an ISO stamp */
export function dateTime(iso) {
  if (typeof iso !== 'string' || iso.length < 16) return '—'
  return `${iso.slice(0, 10)} ${iso.slice(11, 16)}`
}

/** @returns {string} "HH:MM" (UTC) from an ISO stamp */
export function timeOnly(iso) {
  if (typeof iso !== 'string' || iso.length < 16) return '—'
  return iso.slice(11, 16)
}

/**
 * Keep long paths readable while preserving both ends.
 * @param {string} path
 * @param {number} [limit]
 * @returns {string}
 */
export function shortenPath(path, limit = 56) {
  if (typeof path !== 'string') return ''
  if (path.length <= limit) return path
  const head = Math.ceil((limit - 1) / 2)
  const tail = Math.floor((limit - 1) / 2)
  return `${path.slice(0, head)}…${path.slice(-tail)}`
}

/**
 * vscode://file target (§6.4 jump protocol) from projectRoot + a repo-relative
 * path, always forward slashes regardless of host separator. Single shared
 * implementation — entry details and pair details must never drift apart.
 * @param {string} projectRoot
 * @param {string} relativePath
 * @returns {string}
 */
export function absoluteFilePath(projectRoot, relativePath) {
  const root = String(projectRoot ?? '').replace(/\\/g, '/').replace(/\/+$/, '')
  const relative = String(relativePath ?? '').replace(/\\/g, '/').replace(/^\/+/, '')
  return `${root}/${relative}`
}

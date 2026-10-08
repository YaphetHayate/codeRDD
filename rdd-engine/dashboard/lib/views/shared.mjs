// Blocks shared by several views: notes, domain-level empty/error states.
import { emptyState, noteBar } from '../components.mjs'

/**
 * Render every meta.notes entry as a NoteBar (info), plus an optional warn line.
 * @param {object} envelope
 * @param {{warn?: string}} [extra]
 */
export function notesBlock(envelope, extra = {}) {
  const notes = envelope?.meta?.notes ?? []
  const lines = notes.map((note) => noteBar({ variant: 'info', text: note }))
  if (extra.warn !== undefined) lines.unshift(noteBar({ variant: 'warn', text: extra.warn }))
  return lines.join('')
}

/**
 * Domain-level unavailable/empty block: notes + three-part empty state.
 * @param {object} envelope
 * @param {{fact: string, cause: string, action: string}} copy
 */
export function domainUnavailable(envelope, copy) {
  return `${notesBlock(envelope)}${emptyState(copy)}`
}

/**
 * Fixture-exclusion declaration (UX §5.7 fixture variant, §6.8).
 * The runtime computes every number; the text never hardcodes a count and never
 * repeats a fixture directory name — naming a pattern would put fixture
 * vocabulary on a rendered surface, which §6.8 exists to prevent.
 * @param {{excludedCount: number, enumeratedCount: number, deliverNamedCount: number, realCount: number}} fixture
 */
export function fixtureNote(fixture) {
  if (fixture.excludedCount === 0) return ''
  const text = `已排除 <b>${fixture.excludedCount}</b> 个测试夹具目录（按排除规则不计入统计、图表与列表）；本次枚举交付树目录 ${fixture.enumeratedCount} 个（其中 deliver-* 命名 ${fixture.deliverNamedCount} 个，含夹具），统计口径仅含 ${fixture.realCount} 棵真实交付树。`
  return noteBar({ variant: 'fixture', badge: `夹具排除 ×${fixture.excludedCount}`, html: text })
}

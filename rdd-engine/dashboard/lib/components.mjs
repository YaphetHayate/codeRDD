// UI components (server side) — the literal implementation of UX §5.
//
// Convention used throughout this module: a parameter named `html` is inserted
// verbatim (the caller escaped or built it), while `text` parameters are escaped
// here. That keeps every .rdd/ value out of the raw-injection path.
import { esc, dateTime } from './format.mjs'

/** 16px inline icons — no emoji, no icon font (offline requirement). */
const ICONS = {
  overview: '<path d="M3 3h7v7H3zM14 3h7v4h-7zM14 10h7v11h-7zM3 13h7v8H3z"/>',
  archive: '<path d="M3 5h18v4H3zM4 9h16v11H4zM9 13h6v2H9z"/>',
  cache: '<path d="M12 3c4.4 0 8 1.3 8 3s-3.6 3-8 3-8-1.3-8-3 3.6-3 8-3zM4 9.5c1.7 1.2 4.6 1.9 8 1.9s6.3-.7 8-1.9V12c0 1.7-3.6 3-8 3s-8-1.3-8-3zm0 5.5c1.7 1.2 4.6 1.9 8 1.9s6.3-.7 8-1.9V17c0 1.7-3.6 3-8 3s-8-1.3-8-3z"/>',
  target: '<path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 3a7 7 0 1 1 0 14 7 7 0 0 1 0-14zm0 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8z"/>',
  check: '<path d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/>',
  bulb: '<path d="M9 21h6v-1H9zM12 2a7 7 0 0 0-4 12.7V17h8v-2.3A7 7 0 0 0 12 2z"/>',
  tree: '<path d="M11 3h2v5h4v2h-4v3h4v2h-4v4h-2v-4H7v-2h4V10H7V8h4z"/>',
  refresh: '<path d="M12 5V2L7 6l5 4V7a5 5 0 1 1-5 5H5a7 7 0 1 0 7-7z"/>',
  switch: '<path d="M7 7h9.2l-2.6-2.6L14.9 3l5 5-5 5-1.3-1.3L16.2 9H7zM17 17H7.8l2.6 2.6L9.1 21l-5-5 5-5 1.3 1.3L7.8 15H17z"/>',
  copy: '<path d="M8 3h9v2H8zM6 6h13v14H6zM8 8v10h9V8z"/>',
  theme: '<path d="M12 3a9 9 0 1 0 9 9h-9z"/>',
  chevron: '<path d="M7 10l5 5 5-5z"/>',
  gear: '<path fill-rule="evenodd" d="M12 8.5A3.5 3.5 0 1 0 12 15.5 3.5 3.5 0 0 0 12 8.5zM19.4 13c.04-.33.06-.66.06-1s-.02-.67-.06-1l2.1-1.64a.5.5 0 0 0 .12-.64l-2-3.46a.5.5 0 0 0-.6-.22l-2.48 1a7.3 7.3 0 0 0-1.7-.98L14.4 2.4a.5.5 0 0 0-.5-.4h-3.8a.5.5 0 0 0-.5.4l-.44 2.66c-.6.25-1.17.58-1.7.98l-2.47-1a.5.5 0 0 0-.61.22l-2 3.46a.5.5 0 0 0 .12.64L4.6 11c-.04.33-.06.66-.06 1s.02.67.06 1l-2.1 1.64a.5.5 0 0 0-.12.64l2 3.46c.13.22.4.31.61.22l2.48-1c.53.4 1.1.73 1.7.98l.43 2.66c.04.23.25.4.5.4h3.8c.25 0 .46-.17.5-.4l.44-2.66c.6-.25 1.17-.58 1.7-.98l2.47 1c.22.09.48 0 .61-.22l2-3.46a.5.5 0 0 0-.12-.64L19.4 13z"/>',
}

/**
 * Render one icon.
 * @param {string} name
 * @param {string} [className]
 * @returns {string}
 */
export function icon(name, className = 'icon') {
  const path = ICONS[name] ?? ICONS.overview
  return `<svg class="${esc(className)}" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true">${path}</svg>`
}

/** Small state/`composition marker. */
export function chip(text, options = {}) {
  const tone = options.tone === undefined ? '' : ` chip-${options.tone}`
  const swatch =
    options.swatch === undefined
      ? ''
      : `<span class="chip-swatch" style="background:${esc(options.swatch)}"></span>`
  return `<span class="chip${tone}">${swatch}${esc(text)}</span>`
}

/** Status badge: colour + text, never colour alone. */export function badge(text, tone = 'neutral') {
  return `<span class="badge badge-${esc(tone)}">${esc(text)}</span>`
}

/** Composite chip that renders "label value". */
export function statChip(label, value, options = {}) {
  return `<span class="chip chip-stat${options.tone ? ` chip-${options.tone}` : ''}">${esc(label)}<b>${esc(value)}</b></span>`
}

/**
 * NoteBar — warn / info / error / fixture (UX §5.7).
 * @param {{variant?: string, badge?: string, text: string, html?: string, action?: string}} options
 */
export function noteBar(options) {
  const variant = options.variant ?? 'info'
  const badgeHtml =
    options.badge === undefined ? '' : `<span class="fx-badge">${esc(options.badge)}</span>`
  const body = options.html ?? esc(options.text ?? '')
  const action = options.action === undefined ? '' : `<div class="note-action">${options.action}</div>`
  return `<div class="note-bar note-${esc(variant)}">${badgeHtml}<span class="note-text">${body}</span>${action}</div>`
}

/**
 * Three-part empty state (fact / cause / action) — UX §5.6.
 * @param {{fact: string, cause: string, action: string, extra?: string, title?: string}} options
 */
export function emptyState(options) {
  const rows = [
    ['事实', options.fact],
    ['原因', options.cause],
    ['行动', options.action],
  ]
    .map(([key, value]) => `<div class="es-row"><span class="es-key">${esc(key)}</span><span class="es-fact">${esc(value)}</span></div>`)
    .join('')
  const extra = options.extra === undefined ? '' : `<div class="es-extra">${esc(options.extra)}</div>`
  const title = options.title === undefined ? '' : `<div class="es-title">${esc(options.title)}</div>`
  return `<div class="empty-state">${title}${rows}${extra}</div>`
}

/** KPI tile used on every domain page's first layer. */
export function statTile(options) {
  const unit = options.unit === undefined ? '' : `<span class="stat-unit">${esc(options.unit)}</span>`
  const hint = options.hint === undefined ? '' : `<div class="stat-hint">${esc(options.hint)}</div>`
  const tone = options.tone === undefined ? '' : ` stat-${esc(options.tone)}`
  return `<div class="stat-tile${tone}"><div class="stat-value">${esc(options.value)}${unit}</div><div class="stat-label">${esc(options.label)}</div>${hint}</div>`
}

/** Panel / ChartFrame container. */
export function panel(options) {
  const head =
    options.title === undefined
      ? ''
      : `<div class="panel-head"><div class="panel-title">${esc(options.title)}</div>${
          options.tag === undefined ? '' : `<span class="tag">${esc(options.tag)}</span>`
        }${options.note === undefined ? '' : `<div class="panel-note">${esc(options.note)}</div>`}</div>`
  const foot = options.foot === undefined ? '' : `<div class="panel-foot">${options.foot}</div>`
  const extra = options.extra === undefined ? '' : options.extra
  return `<section class="panel${options.chart ? ' chart-frame' : ''}"${options.id ? ` id="${esc(options.id)}"` : ''}>${head}<div class="panel-body">${options.html}</div>${extra}${foot}</section>`
}

/** Section heading with an optional right-hand note. */
export function sectionHead(title, note) {
  return `<div class="section-head"><h2>${esc(title)}</h2>${note === undefined ? '' : `<span class="section-note">${esc(note)}</span>`}</div>`
}

/**
 * DataTable.
 * @param {{columns: {label: string, align?: string}[], rows: object[], empty?: string, foot?: string, caption?: string}} options
 */
export function dataTable(options) {
  const head = options.columns
    .map((column) => `<th${column.align ? ` class="ta-${esc(column.align)}"` : ''}>${esc(column.label)}</th>`)
    .join('')
  const body =
    options.rows.length === 0
      ? `<tr class="table-empty"><td colspan="${options.columns.length}">${options.empty ?? ''}</td></tr>`
      : options.rows.map((row) => renderRow(row)).join('')
  const foot = options.foot === undefined ? '' : `<div class="panel-foot">${options.foot}</div>`
  return `<div class="table-wrap"><table class="data-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>${foot}`
}

/** One table row (cells may carry text, html, tone, title, mono). */
function renderRow(row) {
  const cells = row.cells
    .map((cell) => {
      const classes = [cell.mono ? 'td-mono' : '', cell.muted ? 'td-muted' : '', cell.align ? `ta-${cell.align}` : '']
        .filter((name) => name !== '')
        .join(' ')
      const content = cell.html ?? esc(cell.text ?? '')
      const title = cell.title === undefined ? '' : ` title="${esc(cell.title)}"`
      return `<td${classes === '' ? '' : ` class="${classes}"`}${title}>${content}</td>`
    })
    .join('')
  const attrs = [
    row.href === undefined ? '' : ` data-href="${esc(row.href)}"`,
    row.href === undefined ? '' : ' class="row-clickable"',
    row.selected ? ' data-selected="true"' : '',
    row.dataQuery === undefined ? '' : ` data-query="${esc(row.dataQuery)}"`,
  ].join('')
  return `<tr${attrs}>${cells}</tr>`
}

/**
 * Timeline — recent cross-domain activity (UX §5.11).
 * @param {{items: {at: string, kind: string, tone?: string, html: string, href?: string}[], empty?: string}} options
 */
export function timeline(options) {
  if (options.items.length === 0) return options.empty ?? ''
  return `<ol class="timeline">${options.items
    .map((item) => {
      const body = `<div class="tl-body"><div class="tl-meta"><span class="tl-date">${esc(dateTime(item.at))}</span>${badge(item.kind, item.tone ?? 'neutral')}</div><div class="tl-text">${item.html}</div></div>`
      const dot = `<span class="tl-rail" data-tone="${esc(item.tone ?? 'neutral')}" aria-hidden="true"></span>`
      return `<li class="tl-item">${item.href === undefined ? `${dot}${body}` : `<a class="tl-link" href="${esc(item.href)}">${dot}${body}</a>`}</li>`
    })
    .join('')}</ol>`
}

/**
 * FieldList — key/value pairs on the requirement detail view (UX §5.14).
 * @param {{rows: {key: string, text?: string, html?: string, mono?: boolean, copy?: boolean}[]}} options
 */
export function fieldList(options) {
  return `<div class="field-list">${options.rows
    .map((row) => {
      const valueHtml = row.html ?? (row.text === '' || row.text === undefined ? '<span class="field-empty">—</span>' : esc(row.text))
      const mono = row.mono ? ' field-val-mono' : ''
      const copy =
        row.copy === true && row.text
          ? `<button type="button" class="btn btn-ghost btn-copy" data-copy="${esc(row.text)}">复制路径</button><span class="copy-hint" aria-live="polite"></span>`
          : ''
      return `<div class="field"><span class="field-key">${esc(row.key)}</span><span class="field-val${mono}">${valueHtml}</span>${copy}</div>`
    })
    .join('')}</div>`
}

/** Breadcrumb (detail views). */
export function breadcrumb(items) {
  const parts = items.map((item, index) => {
    const isLast = index === items.length - 1
    if (isLast) return `<span class="crumb-current" aria-current="page">${esc(item.label)}</span>`
    return `<a href="${esc(item.href)}">${esc(item.label)}</a>`
  })
  return `<nav class="breadcrumb" aria-label="返回路径">${parts.join('<span class="crumb-sep" aria-hidden="true">/</span>')}</nav>`
}

/** Rejection records rendered as an ordered list of "|"-split segments. */
export function remarkList(segments) {
  if (segments.length === 0) return '<span class="field-empty">—</span>'
  return `<ol class="remark-list">${segments.map((segment) => `<li>${esc(segment)}</li>`).join('')}</ol>`
}

/** Map lifecycle / outcome / status values onto badge tones. */
export function toneForState(value) {
  const lowered = String(value ?? '').toLowerCase()
  if (['completed', 'done', 'pass', 'passed', 'hit', 'ok', 'running', 'active'].includes(lowered)) {
    return lowered === 'running' ? 'info' : 'success'
  }
  if (['partial', 'warn', 'warning', 'pending', 'paused'].includes(lowered)) return 'warn'
  if (['failed', 'fail', 'error', 'miss', 'rejected', 'blocked'].includes(lowered)) return 'error'
  if (['deprecated', 'archived', 'skipped'].includes(lowered)) return 'neutral'
  return 'info'
}

/** Status badge for an arbitrary state value with a translated label. */
export function stateBadge(value, labels = {}) {
  const raw = String(value ?? '')
  const label = labels[raw] ?? (raw === '' ? '—' : raw)
  return badge(label, toneForState(raw))
}

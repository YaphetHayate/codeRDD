// UI components (server side) — the literal implementation of UX §5.
//
// Convention used throughout this module: a parameter named `html` is inserted
// verbatim (the caller escaped or built it), while `text` parameters are escaped
// here. That keeps every .rdd/ value out of the raw-injection path.
import { absoluteFilePath, dateTime, esc } from './format.mjs'

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

/** KPI tile used on every domain page's first layer.
 * `id` / `dataKpi` mark the expandable variant (exploration-entry-expansion §5.1);
 * the tile stays a pure display box — tabindex / role / chevron are injected by app.js. */
export function statTile(options) {
  const unit = options.unit === undefined ? '' : `<span class="stat-unit">${esc(options.unit)}</span>`
  const hint = options.hint === undefined ? '' : `<div class="stat-hint">${esc(options.hint)}</div>`
  const tone = options.tone === undefined ? '' : ` stat-${esc(options.tone)}`
  const id = options.id === undefined ? '' : ` id="${esc(options.id)}"`
  const kpi = options.dataKpi === undefined ? '' : ` data-kpi="${esc(options.dataKpi)}"`
  return `<div class="stat-tile${tone}"${id}${kpi}><div class="stat-value">${esc(options.value)}${unit}</div><div class="stat-label">${esc(options.label)}</div>${hint}</div>`
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
 * Rows may carry `expand` ({ detailId, label, detail }) to render an expandable
 * row (exploration-entry-expansion §5.3): the row gets the trigger attributes and
 * a hidden `<tr class="row-detail">` with a full-width detail cell follows it.
 * Columns may carry `width` for fixed trigger-column sizing.
 * @param {{columns: {label: string, align?: string, width?: string}[], rows: object[], empty?: string, foot?: string, caption?: string}} options
 */
export function dataTable(options) {
  const head = options.columns
    .map((column) => {
      const width = column.width === undefined ? '' : ` style="width:${esc(column.width)}"`
      return `<th${column.align ? ` class="ta-${esc(column.align)}"` : ''}${width}>${esc(column.label)}</th>`
    })
    .join('')
  const body =
    options.rows.length === 0
      ? `<tr class="table-empty"><td colspan="${options.columns.length}">${options.empty ?? ''}</td></tr>`
      : options.rows.map((row) => renderRow(row, options.columns.length)).join('')
  const foot = options.foot === undefined ? '' : `<div class="panel-foot">${options.foot}</div>`
  return `<div class="table-wrap"><table class="data-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>${foot}`
}

/**
 * Shared cell mapping of data-table rows — dataTable and pairTable render the
 * identical td face (mono/muted/align classes, verbatim html or escaped text,
 * optional title). The two row renderers differ only in their trigger
 * vocabulary (§6.2), so the cells / detail-row / trigger-attrs faces live here
 * once.
 */
function renderCells(cells) {
  return cells
    .map((cell) => {
      const classes = [cell.mono ? 'td-mono' : '', cell.muted ? 'td-muted' : '', cell.align ? `ta-${cell.align}` : '']
        .filter((name) => name !== '')
        .join(' ')
      const content = cell.html ?? esc(cell.text ?? '')
      const title = cell.title === undefined ? '' : ` title="${esc(cell.title)}"`
      return `<td${classes === '' ? '' : ` class="${classes}"`}${title}>${content}</td>`
    })
    .join('')
}

/** Hidden full-width detail row following an expandable row. */
function detailRowHtml(detailId, columnCount, detail) {
  return `<tr class="row-detail" id="${esc(detailId)}" hidden><td colspan="${columnCount}">${detail}</td></tr>`
}

/** Trigger attributes of an expandable row (`data-entry` / `data-pair`, §6.2). */
function expandRowAttrs(vocabulary, trigger) {
  return ` ${vocabulary}="${esc(trigger.detailId)}" tabindex="0" role="button" aria-expanded="false" aria-controls="${esc(trigger.detailId)}" aria-label="${esc(trigger.label)}"`
}

/** One table row (cells may carry text, html, tone, title, mono). */
function renderRow(row, columnCount) {
  const expand = row.expand
  const attrs = [
    row.href === undefined ? '' : ` data-href="${esc(row.href)}"`,
    row.href === undefined ? '' : ' class="row-clickable"',
    row.selected ? ' data-selected="true"' : '',
    row.dataQuery === undefined ? '' : ` data-query="${esc(row.dataQuery)}"`,
    expand === undefined ? '' : expandRowAttrs('data-entry', expand),
  ].join('')
  const detailRow = expand === undefined ? '' : detailRowHtml(expand.detailId, columnCount, expand.detail)
  return `<tr${attrs}>${renderCells(row.cells)}</tr>${detailRow}`
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

/** Leading caret cell of an expandable entry row (exploration-entry-expansion §5.3). */
export function expandRowCaret() {
  return '<span class="row-caret" aria-hidden="true"><svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M7 10l5 5 5-5z"/></svg></span>'
}

const ZONE_LABELS = { hot: '热区 hot.json', index: '持久 index.json' }

/**
 * EntryDetail — one entry's full fields plus the open-in-editor / copy-path
 * action row (exploration-entry-expansion §5.4). Rendered inside the hidden
 * `<td>` of an expandable row; the copy button reuses the existing btn-copy
 * + copy-hint mechanism bound by app.js.
 * @param {{zone: string, key: string, tags: string[], brief: string, path: string, fileCount?: number, registeredAt: string}} entry
 * @param {{absolutePath: string}} options
 */
export function entryDetail(entry, options) {
  const tagsHtml = entry.tags.map((tag) => chip(tag)).join(' ')
  const fields = fieldList({
    rows: [
      { key: 'key', text: entry.key, mono: true },
      { key: '所属区', text: ZONE_LABELS[entry.zone] ?? entry.zone },
      { key: 'tags', html: tagsHtml === '' ? '<span class="field-empty">—</span>' : tagsHtml },
      { key: '涉及文件数', text: entry.fileCount === undefined || entry.fileCount === null ? '' : `${entry.fileCount} 个` },
      { key: '记录路径', text: entry.path, mono: true },
      { key: '注册时间 (UTC)', text: dateTime(entry.registeredAt), mono: true },
    ],
  })
  const target = esc(options.absolutePath)
  return `<div class="detail-brief">${esc(entry.brief)}</div>${fields}<div class="detail-actions"><a class="btn" href="vscode://file/${target}">在编辑器中打开</a><button type="button" class="btn btn-ghost btn-copy" data-copy="${target}">复制路径</button><span class="copy-hint" aria-live="polite"></span><span class="detail-note">编辑器打开失败时可用「复制路径」兜底</span></div>`
}

// ── Pair observability (artifact-pair-observability §5.3/§5.4) ──────────
// Freshness states come from the exploration reader (dashboard-side, engine
// Test-EntryFresh semantics). Colour dots are redundant decoration next to the
// text badge (aria-hidden, WCAG 1.4.11 exemption) — semantic colour never
// carries text (§1.2 判定法).

/** Status label + dot class + optional title for one freshness state (§5.3). */
function pairStateFace(freshness) {
  const state = freshness?.state
  if (state === 'orphan') return { label: '无条目', dot: 'dot-neutral', title: '无对应缓存条目，无法现算' }
  if (state === 'no-list') return { label: '无清单', dot: 'dot-neutral', title: '条目未携带 files 清单，无法现算' }
  if (state === 'stale') {
    return {
      label: `不新鲜 · ${freshness.changed.length} 变更 ${freshness.missing.length} 缺失`,
      dot: 'dot-warn',
      title: undefined,
    }
  }
  return { label: '新鲜', dot: 'dot-success', title: undefined }
}

/** PairStatusBadge (§5.3): dot + text, the text carries the semantics. */
export function pairStatusBadge(freshness) {
  const face = pairStateFace(freshness)
  const title = face.title === undefined ? '' : ` title="${esc(face.title)}"`
  return `<span class="badge-pair"${title}><span class="dot ${face.dot}" aria-hidden="true"></span>${esc(face.label)}</span>`
}

/** Zone badge for the pair's related entry, or the neutral orphan form (§5.2 col 3). */
export function pairEntryBadge(pair) {
  if (pair.entry === null) {
    return '<span class="badge-pair"><span class="dot dot-neutral" aria-hidden="true"></span>无条目</span>'
  }
  return badge(pair.entry.zone === 'hot' ? '热区' : '持久', pair.entry.zone === 'hot' ? 'info' : 'neutral')
}

/** Time face (§7.4): hot entries show registeredAt, everything else the artifact mtime (approx). */
export function pairTimeCell(pair) {
  const hot = pair.entry !== null && pair.entry.zone === 'hot'
  const prefix = hot
    ? ''
    : '<span class="time-approx" title="文件时间（近似）" aria-label="文件时间（近似）">≈ </span>'
  return `${prefix}${esc(dateTime(hot ? pair.entry.registeredAt : pair.mtime))}`
}

/** Verdict line (§2.1): the judgement and its basis in one self-evident sentence. */
function pairVerdictText(pair) {
  const fresh = pair.freshness ?? { state: 'orphan', changed: [], missing: [], total: 0 }
  const suffix = pair.summaryPath === null ? '　异常配对：无 summary 文件。' : ''
  if (fresh.state === 'orphan') return `判定：无条目 —— artifacts/ 中存在产物文件，但双 zone 无对应缓存条目，无法现算新鲜度。${suffix}`
  if (fresh.state === 'no-list') return `判定：无清单 —— 关联条目未携带 files 清单，无法现算新鲜度。${suffix}`
  if (fresh.state === 'stale') {
    return `判定：不新鲜 —— ${fresh.changed.length} 个文件已变更、${fresh.missing.length} 个文件缺失（条目清单共 ${fresh.total} 个文件）。${suffix}`
  }
  return `判定：新鲜 —— ${fresh.total} 个文件哈希全部匹配，记录文件存在。${suffix}`
}

/**
 * 文件清单区 (§5.4) — the covered-files list, rendered only for computable
 * states (fresh/stale). Stale puts the changed/missing groups first; matched
 * rows carry no dot. Mini copy buttons copy the absolute path; without a hint
 * container their feedback is the button-label flip (§2.1).
 */
export function pairFilesBlock(pair, options) {
  const fresh = pair.freshness
  if (!fresh || (fresh.state !== 'fresh' && fresh.state !== 'stale')) return ''
  const fileRow = (relativePath, dotClass) =>
    `<div class="pair-file-row">${dotClass === undefined ? '' : `<span class="dot ${dotClass}" aria-hidden="true"></span>`}<span class="pair-file-path">${esc(relativePath)}</span><button type="button" class="btn btn-ghost btn-copy btn-copy-mini" data-copy="${esc(absoluteFilePath(options.projectRoot, relativePath))}">复制</button></div>`
  const group = (title, rows, dotClass) =>
    rows.length === 0 ? '' : `<div class="pair-files-group">${esc(title)}</div>${rows.map((file) => fileRow(file, dotClass)).join('')}`
  let html = '<div class="pair-files">'
  if (fresh.state === 'stale') {
    const changedSet = new Set(fresh.changed)
    const missingSet = new Set(fresh.missing)
    const rest = pair.files.filter((file) => !changedSet.has(file) && !missingSet.has(file))
    html += group(`已变更（${fresh.changed.length}）`, fresh.changed, 'dot-warn')
    html += group(`缺失（${fresh.missing.length}）`, fresh.missing, 'dot-error')
    html += group(`其余匹配（${rest.length}）`, rest, undefined)
  } else {
    html += group(`涉及文件（${fresh.total}）`, pair.files, undefined)
  }
  return `${html}</div>`
}

/**
 * PairDetail (§5.4) — verdict line, files block, field list and the
 * open-in-editor / copy-path action row, rendered inside the hidden `<td>` of
 * an expandable pair row. Field-level copy buttons carry the absolute path
 * (#1 §6.4 parity); the display text stays the repo-relative path.
 * @param {object} pair envelope pair record (slug/artifactPath/summaryPath/mtime/entry/freshness/files)
 * @param {{projectRoot: string}} options
 */
export function pairDetail(pair, options) {
  const fresh = pair.freshness ?? { state: 'orphan', changed: [], missing: [], total: 0 }
  const hot = pair.entry !== null && pair.entry.zone === 'hot'
  const timeValue = hot ? pair.entry.registeredAt : pair.mtime
  const timeLabel = hot ? '（注册时间 · 热区条目）' : '（文件时间 · 近似）'
  const artifactAbsolute = absoluteFilePath(options.projectRoot, pair.artifactPath)
  const fields = [
    pair.entry === null
      ? { key: '关联条目', html: '<span class="field-empty">—（无对应缓存条目）</span>' }
      : {
          key: '关联条目',
          html: `<span class="field-val-mono">${esc(pair.entry.key)}</span>　${esc(pair.entry.zone === 'hot' ? '热区 hot.json' : '持久 index.json')}`,
        },
    { key: '生成时间 (UTC)', mono: true, html: `${esc(dateTime(timeValue))} <span class="time-approx">${esc(timeLabel)}</span>` },
    { key: 'artifact 路径', mono: true, text: pair.artifactPath, miniCopy: artifactAbsolute },
    pair.summaryPath === null
      ? { key: 'summary 路径', mono: true, html: '<span class="field-empty">—（无 summary 文件）</span>' }
      : { key: 'summary 路径', mono: true, text: pair.summaryPath, miniCopy: absoluteFilePath(options.projectRoot, pair.summaryPath) },
  ]
  if (pair.summaryPath === null) {
    fields.push({ key: '配对状态', text: '异常：无配对 summary 文件（页顶提示口径）。' })
  }
  const fieldHtml = fields
    .map((field) => {
      const mono = field.mono === true ? ' field-val-mono' : ''
      const valueHtml = field.html ?? esc(field.text ?? '')
      const copy =
        field.miniCopy === undefined
          ? ''
          : `<button type="button" class="btn btn-ghost btn-copy btn-copy-mini" data-copy="${esc(field.miniCopy)}">复制</button><span class="copy-hint" aria-live="polite"></span>`
      return `<div class="field"><span class="field-key">${esc(field.key)}</span><span class="field-val${mono}">${valueHtml}</span>${copy}</div>`
    })
    .join('')
  const face = pairStateFace(fresh)
  // The delete entry (#3) renders ONLY for entry-bearing pairs — orphan pairs
  // are out of delete scope (D10: no entry point, endpoint independently refuses).
  const deleteButton =
    pair.entry === null
      ? ''
      : `<button type="button" class="btn btn-ghost btn-danger" data-delete-pair="${esc(pair.slug)}">删除产物对</button>`
  return `<div class="pair-verdict"><span class="dot ${face.dot}" aria-hidden="true"></span><span class="pair-verdict-text">${esc(pairVerdictText(pair))}</span></div>${pairFilesBlock(pair, options)}<div class="field-list">${fieldHtml}</div><div class="detail-actions"><a class="btn" href="vscode://file/${esc(artifactAbsolute)}">在编辑器中打开</a>${
    pair.summaryPath === null
      ? ''
      : `<a class="btn" href="vscode://file/${esc(absoluteFilePath(options.projectRoot, pair.summaryPath))}">打开 summary</a>`
  }<button type="button" class="btn btn-ghost btn-copy" data-copy="${esc(artifactAbsolute)}">复制路径</button><span class="copy-hint" aria-live="polite"></span>${deleteButton}<span class="detail-note">编辑器打开失败时可用「复制路径」兜底</span></div>`
}

/**
 * Expandable pair table (§5.2) — same face as dataTable but rows carry
 * data-pair vocabulary (§6.2: tr[data-entry], tr[data-pair] share the toggle
 * logic in app.js; the row face itself comes from the shared renderCells /
 * detailRowHtml / expandRowAttrs helpers).
 */
export function pairTable(options) {
  const head = options.columns
    .map((column) => `<th${column.width === undefined ? '' : ` style="width:${esc(column.width)}"`}>${esc(column.label)}</th>`)
    .join('')
  const body =
    options.rows.length === 0
      ? `<tr class="table-empty"><td colspan="${options.columns.length}">${options.empty ?? ''}</td></tr>`
      : options.rows.map(renderPairRow).join('')
  const foot = options.foot === undefined ? '' : `<div class="panel-foot">${options.foot}</div>`
  return `<div class="table-wrap"><table class="data-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>${foot}`
}

/** One expandable pair row — renderRow's face with the data-pair vocabulary (§6.2). */
function renderPairRow(row) {
  return `<tr${expandRowAttrs('data-pair', row.pair)}>${renderCells(row.cells)}</tr>${detailRowHtml(row.pair.detailId, row.cells.length, row.pair.detail)}`
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

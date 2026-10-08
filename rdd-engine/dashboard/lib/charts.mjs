// Chart primitives.
//
// Distributions, ratios and ranked bars are laid out with markup + CSS (crisp at
// any zoom, no canvas, readable with JS disabled); the two time-based plots use
// inline SVG. Geometry follows UX §5.8: 18px bar height, 5px radius, dashed
// empty track for zero values, 2px line / 3px points, no area fill.
import { esc, num, percent, dateTime } from './format.mjs'

const CHART_COLORS = [1, 2, 3, 4, 5, 6].map((index) => `var(--ops-chart-${index})`)

/**
 * Horizontal distribution bars.
 * @param {{rows: {label: string, value: number, tone?: string, href?: string}[], unit?: string}} options
 */
export function barChart(options) {
  const max = Math.max(1, ...options.rows.map((row) => row.value))
  const rows = options.rows
    .map((row, index) => {
      const ratio = row.value === 0 ? 0 : Math.max(3, Math.round((row.value / max) * 100))
      const color = row.tone ?? CHART_COLORS[index % CHART_COLORS.length]
      const fill =
        row.value === 0
          ? '<span class="bar-empty" aria-hidden="true"></span>'
          : `<span class="bar-fill" style="width:${ratio}%;background:${esc(color)}"></span>`
      const label =
        row.href === undefined
          ? `<span class="chart-label">${esc(row.label)}</span>`
          : `<a class="chart-label" href="${esc(row.href)}">${esc(row.label)}</a>`
      return `<div class="chart-row">${label}<span class="bar-track">${fill}</span><span class="chart-value">${esc(num(row.value))}${esc(options.unit ?? '')}</span></div>`
    })
    .join('')
  return `<div class="bar-chart">${rows}</div>`
}

/**
 * Stacked composition bar with a legend.
 * @param {{segments: {label: string, value: number, tone?: string}[], note?: string}} options
 */
export function stackedBar(options) {
  const total = options.segments.reduce((sum, segment) => sum + segment.value, 0)
  const parts = options.segments
    .map((segment, index) => {
      const share = total === 0 ? 0 : (segment.value / total) * 100
      if (share === 0) return ''
      const color = segment.tone ?? CHART_COLORS[index % CHART_COLORS.length]
      return `<span class="stack-seg" style="width:${share}%;background:${esc(color)}" title="${esc(`${segment.label} ${segment.value}`)}"></span>`
    })
    .join('')
  const legend = options.segments
    .map((segment, index) => {
      const color = segment.tone ?? CHART_COLORS[index % CHART_COLORS.length]
      return `<span class="chip chip-legend"><span class="chip-swatch" style="background:${esc(color)}"></span>${esc(segment.label)}<b>${esc(num(segment.value))}</b></span>`
    })
    .join('')
  const empty = total === 0 ? '<span class="stack-empty"></span>' : ''
  return `<div class="stacked-wrap"><div class="stacked-bar">${empty}${parts}</div><div class="stack-legend">${legend}</div>${
    options.note === undefined ? '' : `<div class="chart-note">${esc(options.note)}</div>`
  }</div>`
}

/**
 * Hit / miss / forced ratio bar (forced rendered outside the denominator).
 * @param {{hit: number, miss: number, forced: number}} counts
 */
export function ratioBar(counts) {
  const denominator = counts.hit + counts.miss
  const hitShare = denominator === 0 ? 0 : (counts.hit / denominator) * 100
  const segments = [
    { label: '命中', value: counts.hit, tone: 'var(--ops-success)' },
    { label: '未命中', value: counts.miss, tone: 'var(--ops-error)' },
  ]
  const html = stackedBar({ segments, note: 'forced 单列，不计入分母' })
  return `<div class="ratio-bar" data-hit-share="${hitShare.toFixed(1)}"><div class="ratio-head"><span class="ratio-value">${esc(percent(denominator === 0 ? null : Number(hitShare.toFixed(1))))}</span><span class="ratio-label">命中率 = 命中 /（命中 + 未命中）</span></div>${html}</div>`
}

/**
 * Sparse trend: one dot per record, filled for hit and hollow for miss.
 * Used whenever the degradation matrix forbids a line (UX §5.8).
 * @param {{ts: string, outcome: string}[]} records oldest-first
 */
export function sparseTrend(records) {
  const width = 900
  const height = 190
  const left = 64
  const right = width - 24
  const span = Math.max(1, records.length - 1)
  const plotX = (index) => left + (index / span) * (right - left)
  // var() only resolves inside a style declaration, so every themed SVG colour
  // rides a style attribute rather than a presentation attribute.
  const dotStyle = (outcome) => {
    if (outcome === 'hit') return 'fill:var(--ops-success);stroke:var(--ops-success)'
    if (outcome === 'forced') return 'fill:var(--ops-chart-6);stroke:var(--ops-chart-6)'
    return 'fill:var(--ops-bg-surface);stroke:var(--ops-error)'
  }
  const dots = records
    .map((record, index) => {
      const y = record.outcome === 'hit' ? 58 : record.outcome === 'forced' ? 95 : 132
      return `<circle cx="${plotX(index).toFixed(1)}" cy="${y}" r="4.5" style="${dotStyle(record.outcome)}" stroke-width="2"><title>${esc(`${dateTime(record.ts)} · ${record.outcome}`)}</title></circle>`
    })
    .join('')
  const lanes = [
    ['命中', 58],
    ['forced', 95],
    ['未命中', 132],
  ]
    .map(
      ([label, y]) =>
        `<line x1="${left}" y1="${y}" x2="${right}" y2="${y}" style="stroke:var(--ops-border-default)" stroke-dasharray="4 4" stroke-width="1"/><text x="12" y="${Number(y) + 4}" class="chart-axis">${esc(label)}</text>`
    )
    .join('')
  const first = records.length > 0 ? dateTime(records[0].ts) : ''
  const last = records.length > 0 ? dateTime(records[records.length - 1].ts) : ''
  return `<svg class="chart-svg" viewBox="0 0 ${width} ${height}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="流水点阵">${lanes}${dots}<text x="${left}" y="${height - 12}" class="chart-axis">${esc(first)}</text><text x="${right}" y="${height - 12}" text-anchor="end" class="chart-axis">${esc(last)}</text></svg>`
}

/**
 * Daily trend line (only used once the sample-size threshold is met).
 * @param {{day: string, hit: number, miss: number, forced: number}[]} days
 */
export function dailyTrend(days) {
  const width = 900
  const height = 220
  const left = 56
  const right = width - 24
  const top = 24
  const bottom = height - 36
  const max = Math.max(1, ...days.map((day) => day.hit + day.miss + day.forced))
  const span = Math.max(1, days.length - 1)
  const plotX = (index) => left + (index / span) * (right - left)
  const plotY = (value) => bottom - (value / max) * (bottom - top)
  const series = [
    { key: 'hit', color: 'var(--ops-success)', label: '命中' },
    { key: 'miss', color: 'var(--ops-error)', label: '未命中' },
  ]
  const grid = [0, 0.5, 1]
    .map((ratio) => {
      const y = plotY(max * ratio)
      return `<line x1="${left}" y1="${y.toFixed(1)}" x2="${right}" y2="${y.toFixed(1)}" style="stroke:var(--ops-border-subtle)" stroke-width="1"/><text x="12" y="${(y + 4).toFixed(1)}" class="chart-axis">${esc(num(Math.round(max * ratio)))}</text>`
    })
    .join('')
  const lines = series
    .map((entry) => {
      const points = days.map((day, index) => `${plotX(index).toFixed(1)},${plotY(day[entry.key]).toFixed(1)}`).join(' ')
      const dots = days
        .map(
          (day, index) =>
            `<circle cx="${plotX(index).toFixed(1)}" cy="${plotY(day[entry.key]).toFixed(1)}" r="3" style="fill:${entry.color}"/>`
        )
        .join('')
      return `<polyline points="${points}" style="fill:none;stroke:${entry.color}" stroke-width="2"/>${dots}`
    })
    .join('')
  const legend = series
    .map(
      (entry) =>
        `<span class="chip chip-legend"><span class="chip-swatch" style="background:${entry.color}"></span>${esc(entry.label)}</span>`
    )
    .join('')
  const axis = days
    .map((day, index) => ({ day, index }))
    .filter(({ index }) => index === 0 || index === days.length - 1 || index % Math.ceil(days.length / 6) === 0)
    .map(
      ({ day, index }) =>
        `<text x="${plotX(index).toFixed(1)}" y="${height - 12}" class="chart-axis" text-anchor="middle">${esc(day.day.slice(5))}</text>`
    )
    .join('')
  return `<svg class="chart-svg" viewBox="0 0 ${width} ${height}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="按天分桶趋势">${grid}${lines}${axis}</svg><div class="stack-legend">${legend}</div>`
}

/**
 * Decide the trend rendering per the degradation matrix (UX §5.8).
 * @param {{day: string}[]} days
 * @param {number} recordCount
 * @returns {{mode: 'line'|'points'|'empty', reason: string}}
 */
export function trendMode(days, recordCount) {
  if (recordCount === 0) return { mode: 'empty', reason: '无流水记录' }
  if (days.length < 3 || recordCount < 5) {
    return {
      mode: 'points',
      reason: `样本量小（${days.length} 个日期分桶 / ${recordCount} 条流水），按降级规则不绘制趋势曲线，仅展示点阵与占比。`,
    }
  }
  return { mode: 'line', reason: `按天分桶（${days.length} 天，单位：条）` }
}

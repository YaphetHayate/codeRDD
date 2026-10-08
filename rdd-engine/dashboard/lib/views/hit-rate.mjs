// Hit-rate view (#/hit-rate) — consumes the frozen six-field query-log contract.
import { badge, dataTable, emptyState, noteBar, panel, statTile, stateBadge } from '../components.mjs'
import { dailyTrend, ratioBar, sparseTrend, trendMode } from '../charts.mjs'
import { dateTime, esc, num, percent } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, notesBlock } from './shared.mjs'

const OUTCOME_LABELS = { hit: '命中', miss: '未命中', forced: 'forced', unknown: '未知' }

const EMPTY_COPY = {
  fact: '暂无数据 —— 检索链路尚未产生查询流水。',
  cause: '#1 查询流水记录未交付或尚未积累流水（.rdd/exploration/query-log.jsonl 不存在或为空）。',
  action: '执行至少一次 rdd_explore 检索后刷新本页。',
}

/** Trend panel: line when the sample is big enough, point plot otherwise. */
function trendPanel(data) {
  const mode = trendMode(data.trend, data.total)
  if (mode.mode === 'empty') {
    return panel({
      chart: true,
      title: '命中率趋势',
      html: emptyState({ fact: '暂无流水', cause: '流水文件为空。', action: '执行检索查询后此处显示趋势。' }),
    })
  }
  const chart = mode.mode === 'line' ? dailyTrend(data.trend) : sparseTrend([...data.detail].reverse())
  const warn = mode.mode === 'points' ? [{ variant: 'warn', text: `${mode.reason} 4 条流水集中在 ${data.timeRange.first.slice(0, 16).replace('T', ' ')}–${data.timeRange.last.slice(11, 16)} UTC 同一窗口。` }] : []
  return panel({
    chart: true,
    title: '命中率趋势',
    tag: mode.mode === 'points' ? '小样本' : undefined,
    note: mode.mode === 'line' ? mode.reason : '点阵：实心 = 命中，空心 = 未命中',
    html: chart,
    extra: warn.map((entry) => noteBar(entry)).join(''),
    foot: mode.mode === 'line' ? '分桶单位：天（UTC）；无面积填充。' : '按降级规则不绘制趋势曲线，仅展示点阵与占比。',
  })
}

/** Miss query ranking — rows drive the client-side detail filter. */
function missPanel(data) {
  const rows = data.missQueries.map((entry, index) => ({
    label: entry.query,
    value: entry.count,
    share: data.miss === 0 ? 0 : entry.count / data.miss,
    href: undefined,
    color: `var(--ops-chart-${(index % 5) + 1})`,
  }))
  return panel({
    title: 'miss 高频 query',
    note: `按 query 分组（${data.missQueries.length} 组）`,
    html:
      rows.length === 0
        ? emptyState({ fact: '暂无未命中记录', cause: '流水中的 outcome 全部为 hit（或尚无流水）。', action: '出现未命中查询后此处按频次排行。' })
        : `<div class="bar-list bar-list-clickable" data-filter-source="miss">${rows
            .map(
              (row, index) =>
                `<button type="button" class="bar-row" data-query="${esc(row.label)}" data-index="${index}"><span class="bar-label">${esc(row.label)}</span><span class="bar-track"><span class="bar-fill" style="width:${Math.max(6, Math.round((row.value / Math.max(1, rows[0].value)) * 100))}%;background:${esc(row.color)}"></span></span><span class="bar-value">${esc(num(row.value))}<span class="bar-share">${esc(percent(row.share))}</span></span></button>`
            )
            .join('')}</div>`,
    foot: '点击任一行按该 query 过滤下方流水明细（本地过滤，不重新请求）。',
  })
}

/** Recaller status summary chips. */
function recallerChips(data) {
  if (data.recallers.length === 0) return '<span class="field-empty">—</span>'
  return data.recallers
    .map(
      (recaller) =>
        `<span class="chip chip-legend"><span class="chip-swatch" style="background:${recaller.status === 'ok' ? 'var(--ops-success)' : 'var(--ops-chart-6)'}"></span>${esc(recaller.name)}:${esc(recaller.status)}<b>${esc(num(recaller.count))}</b></span>`
    )
    .join('')
}

/** Detail rows, newest first, with the recaller projection per row. */
function detailRows(data) {
  return data.detail.map((record) => ({
    dataQuery: record.query,
    cells: [
      { text: dateTime(record.ts), mono: true, muted: true },
      { text: record.entry, muted: true },
      { text: record.query, title: record.query },
      { html: stateBadge(record.outcome, OUTCOME_LABELS) },
      { html: record.keys.length === 0 ? '<span class="field-empty">—</span>' : record.keys.map((key) => `<span class="chip">${esc(key)}</span>`).join(' ') },
      {
        html:
          record.recallers.length === 0
            ? '<span class="field-empty">—</span>'
            : record.recallers
                .map(
                  (recaller) =>
                    `${badge(`${recaller.name}:${recaller.status}`, recaller.status === 'ok' ? 'success' : 'neutral')}<span class="recaller-q">q=${esc(num(recaller.qualified))}</span>`
                )
                .join(' '),
      },
    ],
  }))
}

/** Body of the hit-rate page. */
function renderBody(domains) {
  const data = domains['hit-rate'].data
  const tiles = [
    statTile({ value: data.hitRatePercent === null ? '—' : percent(data.hitRatePercent), label: '命中率', hint: '命中 /（命中 + 未命中）' }),
    statTile({ value: num(data.hit), label: 'hit', unit: ' 条', tone: 'ok' }),
    statTile({ value: num(data.miss), label: 'miss', unit: ' 条', tone: data.miss > 0 ? 'warn' : 'ok' }),
    statTile({ value: num(data.forced), label: 'forced', unit: ' 条', hint: '不计入分母' }),
    statTile({ value: num(data.total), label: '流水总数', unit: ' 条', hint: `坏行跳过 ${data.skipped}` }),
  ].join('')
  const ratio = panel({
    chart: true,
    title: '命中 : 未命中',
    note: `流水时段 ${data.timeRange.first.slice(0, 10)}`,
    html: `${ratioBar({ hit: data.hit, miss: data.miss, forced: data.forced })}<div class="chart-note">入口分布：${data.byEntry.map((entry) => `${esc(entry.entry)} ${esc(num(entry.count))}`).join(' · ') || '—'}</div><div class="chart-note">召回器状态：${recallerChips(data)}</div>`,
  })
  const filterBar = '<div class="filter-bar" id="ops-filter" hidden><span class="chip chip-filter">过滤：<b data-filter-value></b><button type="button" class="btn btn-ghost" id="ops-filter-clear" aria-label="清除过滤">×</button></span></div>'
  const table = panel({
    title: '流水明细',
    note: '按时间倒序',
    html: `${filterBar}${dataTable({
      columns: [
        { label: '时间 (UTC)' },
        { label: '入口' },
        { label: 'query 原文' },
        { label: '结果' },
        { label: '命中 key' },
        { label: '召回器' },
      ],
      rows: detailRows(data),
      empty: emptyState({ fact: '暂无流水记录', cause: 'query-log.jsonl 为空。', action: '执行检索查询后此处出现明细行。' }),
    })}`,
    foot: `仅展示最近 ${num(data.detailLimit)} 条（共 ${num(data.total)} 条）；forced 为绕过缓存强制派发，单列且不计入命中率分母。`,
  })
  return `${tiles}${noteBar({ variant: 'info', text: '命中率 = 命中 /（命中 + 未命中），forced 不计入分母；明细按时间倒序截断。' })}<div class="split-5-7">${ratio}${trendPanel(data)}</div>${missPanel(data)}${table}`
}

/**
 * Render the hit-rate page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderHitRatePage(input) {
  const envelope = input.domains['hit-rate']
  const header = domainHeader({
    title: '命中率',
    subtitle: '流水口径：hit /（hit + miss），forced 单列不计分母；miss 按 query 分组，趋势按天分桶。',
    envelope,
  })
  const body = envelope.available === false ? domainUnavailable(envelope, EMPTY_COPY) : renderBody(input.domains)
  return renderLayout({
    title: '命中率',
    activeKey: 'hit-rate',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

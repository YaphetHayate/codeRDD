// Exploration-cache view (#/exploration).
import { dataTable, emptyState, panel, statTile, timeline } from '../components.mjs'
import { barChart } from '../charts.mjs'
import { dateTime, esc, num } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, notesBlock } from './shared.mjs'

const EMPTY_COPY = {
  fact: '暂无条目 —— hot.json 与 index.json 的 entries 均为空。',
  cause: '探索缓存热区当前为空，尚未注册任何检索条目。',
  action: '执行一次 rdd_explore 检索并注册，或运行缓存维护脚本后刷新本页。',
}

/** Entry rows (hot zone first, then the persisted index). */
function entryRows(entries) {
  return entries.map((entry) => ({
    cells: [
      { text: entry.key, mono: true },
      { text: entry.zone, muted: true },
      { html: entry.tags.map((tag) => `<span class="chip">${esc(tag)}</span>`).join(' ') || '<span class="field-empty">—</span>' },
      { text: entry.brief, title: entry.brief },
      { text: entry.path, mono: true, muted: true },
      { text: dateTime(entry.registeredAt), mono: true, muted: true },
    ],
  }))
}

/** KPI row of the exploration page. */
function summaryTiles(data) {
  return [
    statTile({ value: num(data.totalCount), label: '条目总数', unit: ' 条' }),
    statTile({ value: num(data.hotCount), label: '热区条目', unit: ' 条', hint: 'hot.json' }),
    statTile({ value: num(data.indexCount), label: '持久条目', unit: ' 条', hint: 'index.json' }),
    statTile({ value: num(data.artifacts.count), label: 'artifact 记录', unit: ' 条' }),
    statTile({ value: num(data.artifacts.pairedCount), label: '已配对 summary', unit: ' 条' }),
  ].join('')
}

/** Registration timeline (hot zone vs persisted). */
function timelinePanel(data) {
  return panel({
    title: '注册时间线',
    note: `${data.timeline.length} 条带时间戳的条目`,
    html: timeline({
      items: data.timeline.map((entry) => ({
        at: entry.at,
        kind: entry.zone === 'hot' ? '热区注册' : '持久注册',
        tone: entry.zone === 'hot' ? 'info' : 'success',
        href: '/exploration',
        html: `<code>${esc(entry.key)}</code> ${esc(entry.brief)}`,
      })),
      empty: emptyState({ fact: '暂无注册记录', cause: '条目均无 registeredAt 时间戳。', action: '注册条目后此处显示注册时间线。' }),
    }),
  })
}

/** Per-entry detail table. */
function entriesPanel(data) {
  return panel({
    title: '条目明细',
    note: `${data.totalCount} 条`,
    html: dataTable({
      columns: [
        { label: 'key' },
        { label: '区' },
        { label: 'tags' },
        { label: '摘要' },
        { label: '记录路径' },
        { label: '注册时间 (UTC)' },
      ],
      rows: entryRows(data.entries),
      empty: emptyState({ fact: '暂无条目', cause: '热区与持久区均为空。', action: '注册一条探索记录后此处出现行。' }),
    }),
    foot: '热区条目在提升（persist）前不外显于 index.json；两区合并展示。',
  })
}

/** Body of the exploration page. */
function renderBody(domains) {
  const data = domains.exploration.data
  const tiles = summaryTiles(data)
  const tagPanel = panel({
    title: 'tag 分布',
    note: '按条目 tag 计数（一条多 tag 重复计）',
    html:
      data.tags.length === 0
        ? emptyState({ fact: '暂无 tag 数据', cause: '尚未注册任何条目。', action: '注册一条探索记录后此处显示 tag 分布。' })
        : barChart({ rows: data.tags.slice(0, 12).map((tag) => ({ label: tag.tag, value: tag.count })) }),
    foot: esc('0 值行保留虚线空轨：空是事实，不隐藏。'),
  })
  return `${tiles}${tagPanel}${timelinePanel(data)}${entriesPanel(data)}`
}

/**
 * Render the exploration-cache page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderExplorationPage(input) {
  const envelope = input.domains.exploration
  const header = domainHeader({
    title: '探索缓存',
    subtitle: 'hot.json + index.json 的条目、tag 分布与注册时间线；artifacts 记录与配对计数。',
    envelope,
  })
  const body = envelope.available === false ? domainUnavailable(envelope, EMPTY_COPY) : renderBody(input.domains)
  return renderLayout({
    title: '探索缓存',
    activeKey: 'exploration',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

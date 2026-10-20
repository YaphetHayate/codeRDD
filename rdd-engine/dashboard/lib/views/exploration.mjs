// Exploration-cache view (#/exploration).
//
// KPI row = "count is the entry point" (exploration-entry-expansion §5): the
// total/hot/index tiles carry data-kpi and toggle their in-place KpiExpansionPanel
// (app.js injects the interactive bits). The bottom entries panel stays as the
// no-JS baseline and is hidden once app.js runs. The reader data face is unchanged.
import { badge, chip, dataTable, emptyState, entryDetail, expandRowCaret, panel, pairDetail, pairEntryBadge, pairStatusBadge, pairTimeCell, pairTable, statTile, timeline } from '../components.mjs'
import { barChart } from '../charts.mjs'
import { absoluteFilePath, dateTime, esc, num } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, notesBlock } from './shared.mjs'

const EMPTY_COPY = {
  fact: '暂无条目 —— hot.json 与 index.json 的 entries 均为空。',
  cause: '探索缓存热区当前为空，尚未注册任何检索条目。',
  action: '执行一次 rdd_explore 检索并注册，或运行缓存维护脚本后刷新本页。',
}

const HOT_EMPTY_COPY = {
  fact: '暂无热区条目 —— hot.json 的 entries 为空。',
  cause: '热区条目在提升（persist）后移入持久层，或因 TTL/容量淘汰清空。',
  action: '执行一次 rdd_explore 检索并注册后，展开此处查看。',
}

const INDEX_EMPTY_COPY = {
  fact: '暂无持久条目 —— index.json 的 entries 为空。',
  cause: '热区条目尚未提升（persist）到持久层。',
  action: '热区条目转正后出现在此处。',
}

const MERGE_FOOT = '热区条目在提升（persist）前不外显于 index.json；两区合并展示（纯拼接口径，同 key 双区可能重复计）。'

/** Entry rows for the flat baseline table (hot zone first, then the persisted index). */
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

/** KPI row of the exploration page — four tiles, the pair tile merges the two artifact counts. */
function summaryTiles(data) {
  return [
    statTile({ value: num(data.totalCount), label: '条目总数', unit: ' 条', id: 'kpi-total', dataKpi: 'total' }),
    statTile({ value: num(data.hotCount), label: '热区条目', unit: ' 条', hint: 'hot.json', id: 'kpi-hot', dataKpi: 'hot' }),
    statTile({ value: num(data.indexCount), label: '持久条目', unit: ' 条', hint: 'index.json', id: 'kpi-index', dataKpi: 'index' }),
    statTile({
      value: num(data.artifacts.count),
      label: '产物记录',
      unit: ' 条',
      hint: `${num(data.artifacts.pairedCount)} 对已配对 summary`,
      id: 'kpi-pairs',
      dataKpi: 'pairs',
    }),
  ].join('')
}

function zoneBadge(zone) {
  if (zone === 'hot') return badge('热区', 'info')
  if (zone === 'index') return badge('持久', 'neutral')
  return esc(zone)
}

function tagChips(tags) {
  return tags.map((tag) => chip(tag)).join(' ') || '<span class="field-empty">—</span>'
}

/** Trigger column shared by every expansion table (§5.2: caret cell, 36px). */
const EXP_TRIGGER_COLUMN = { label: '', width: '36px' }
const EXP_COLUMNS_TOTAL = [
  EXP_TRIGGER_COLUMN,
  { label: 'key' },
  { label: '区' },
  { label: 'tags' },
  { label: '摘要' },
  { label: '记录路径' },
  { label: '注册时间 (UTC)' },
]
const EXP_COLUMNS_ZONE = [
  EXP_TRIGGER_COLUMN,
  { label: 'key' },
  { label: 'tags' },
  { label: '摘要' },
  { label: '记录路径' },
  { label: '注册时间 (UTC)' },
]

/** Expandable entry rows: the whole row toggles its hidden detail row (§5.3). */
function expandableEntryRows(entries, zonePrefix, projectRoot, withZone) {
  return entries.map((entry, index) => {
    const detailId = `row-${zonePrefix}-${index}`
    return {
      cells: [
        { html: expandRowCaret() },
        { text: entry.key, mono: true, title: entry.key },
        ...(withZone ? [{ html: zoneBadge(entry.zone) }] : []),
        { html: tagChips(entry.tags) },
        { text: entry.brief, title: entry.brief },
        { text: entry.path, mono: true, muted: true, title: entry.path },
        { text: dateTime(entry.registeredAt), mono: true, muted: true },
      ],
      expand: {
        detailId,
        label: `条目 ${entry.key}，点击展开或收起详情`,
        detail: entryDetail(entry, { absolutePath: absoluteFilePath(projectRoot, entry.path) }),
      },
    }
  })
}

/** One KpiExpansionPanel (§5.2): collapsible head + bounded table (or empty state). */
function kpiExpansionPanel(config) {
  const collapseLabel = `收起「${config.title}」`
  return `<section class="kpi-expansion" id="${esc(config.id)}" role="region" aria-labelledby="${esc(config.labelledBy)}" hidden><div class="exp-head" data-collapse-zone="${esc(config.zone)}" tabindex="0" role="button" aria-label="${esc(collapseLabel)}"><div class="exp-title">${esc(config.title)}</div>${config.badgeHtml}<div class="exp-note">${esc(config.note)}</div><span class="exp-collapse-hint" aria-hidden="true">点击收起<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M7 14l5-5 5 5z"/></svg></span></div>${dataTable({ columns: config.columns, rows: config.rows, empty: config.empty })}${config.foot === undefined ? '' : `<div class="exp-foot">${esc(config.foot)}</div>`}</section>`
}

/** The three expansion panels, DOM order fixed: total → hot → index (decision D1). */
function kpiExpansionPanels(data, projectRoot) {
  const total = kpiExpansionPanel({
    id: 'exp-total',
    labelledBy: 'kpi-total',
    zone: 'total',
    title: '条目明细 · 全部',
    badgeHtml: badge('双 zone 合并', 'info'),
    note: `${num(data.totalCount)} 条 · 计数与行数一致`,
    columns: EXP_COLUMNS_TOTAL,
    rows: expandableEntryRows(data.entries, 'total', projectRoot, true),
    empty: emptyState(EMPTY_COPY),
    foot: MERGE_FOOT,
  })
  const hot = kpiExpansionPanel({
    id: 'exp-hot',
    labelledBy: 'kpi-hot',
    zone: 'hot',
    title: '热区条目 · hot.json',
    badgeHtml: badge('仅热区', 'neutral'),
    note: `${num(data.hotCount)} 条`,
    columns: EXP_COLUMNS_ZONE,
    rows: expandableEntryRows(
      data.entries.filter((entry) => entry.zone === 'hot'),
      'hot',
      projectRoot,
      false
    ),
    empty: emptyState(HOT_EMPTY_COPY),
  })
  const index = kpiExpansionPanel({
    id: 'exp-index',
    labelledBy: 'kpi-index',
    zone: 'index',
    title: '持久条目 · index.json',
    badgeHtml: badge('仅持久层', 'neutral'),
    note: `${num(data.indexCount)} 条`,
    columns: EXP_COLUMNS_ZONE,
    rows: expandableEntryRows(
      data.entries.filter((entry) => entry.zone === 'index'),
      'index',
      projectRoot,
      false
    ),
    empty: emptyState(INDEX_EMPTY_COPY),
  })
  return `${total}${hot}${index}`
}

// ── 产物对可观测（artifact-pair-observability §5.2/§5.5）────────────────

const PAIRS_FOOT =
  '状态为看板侧现算口径：按关联条目的 files 清单逐文件重算 SHA-256 并核对记录文件存在性，与引擎新鲜度判定同语义；无条目/无清单的产物对无法现算，如实标注。已消失（被淘汰）条目不追溯历史原因。'
const PAIRS_FLAT_FOOT = '状态为看板侧现算口径（与引擎新鲜度判定同语义）；无条目/无清单的产物对无法现算，如实标注。'
const PAIRS_EMPTY_COPY = {
  fact: '暂无产物对 —— artifacts/ 目录无 .md 产物文件。',
  cause: '尚未注册任何探索记录；register 注册条目时会同步产出 artifact 与 summary 文件。',
  action: '执行一次 rdd_explore 检索并注册后刷新本页。',
}

const PAIR_COLUMNS = [
  { label: '', width: '36px' },
  { label: '产物对' },
  { label: '关联条目' },
  { label: '状态' },
  { label: '生成时间 (UTC)' },
]

/** Expandable pair rows: the whole row toggles its hidden detail row (§5.2). */
function expandablePairRows(pairs, projectRoot) {
  return pairs.map((pair, index) => {
    const detailId = `pair-detail-${index}`
    return {
      cells: [
        { html: expandRowCaret() },
        { text: pair.slug, mono: true, title: pair.slug },
        { html: pairEntryBadge(pair) },
        { html: pairStatusBadge(pair.freshness) },
        { html: pairTimeCell(pair), mono: true, muted: true },
      ],
      pair: {
        detailId,
        label: `产物对 ${pair.slug}，点击展开或收起详情`,
        detail: pairDetail(pair, { projectRoot }),
      },
    }
  })
}

/** The pairs expansion panel, DOM order fixed after the three entry zones (§3.1). */
function pairsExpansionPanel(data, projectRoot) {
  return `<section class="kpi-expansion" id="exp-pairs" role="region" aria-labelledby="kpi-pairs" hidden><div class="exp-head" data-collapse-zone="pairs" tabindex="0" role="button" aria-label="收起「产物对 · artifacts/」"><div class="exp-title">产物对 · artifacts/</div>${badge(`${num(data.artifacts.count)} 条产物 · ${num(data.artifacts.pairedCount)} 对已配对`)}<div class="exp-note">${num(data.artifacts.count)} 条 · 计数与行数一致</div><span class="exp-collapse-hint" aria-hidden="true">点击收起<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M7 14l5-5 5 5z"/></svg></span></div>${pairTable({
    columns: PAIR_COLUMNS,
    rows: expandablePairRows(data.artifacts.pairs, projectRoot),
    empty: emptyState(PAIRS_EMPTY_COPY),
  })}<div class="exp-foot">${esc(PAIRS_FOOT)}</div></section>`
}

/** Flat pair rows — the no-JS baseline face: no caret, no row interaction. */
function flatPairRows(pairs) {
  return pairs.map((pair) => ({
    cells: [
      { text: pair.slug, mono: true, title: pair.slug },
      { html: pairEntryBadge(pair) },
      { html: pairStatusBadge(pair.freshness) },
      { html: pairTimeCell(pair), mono: true, muted: true },
    ],
  }))
}

/** Flat pairs panel — the no-JS baseline (§5.5); app.js hides it on boot. */
function pairsFlatPanel(data) {
  return panel({
    id: 'pairs-flat',
    title: '产物对',
    note: `${num(data.artifacts.count)} 条 · 无 JS 降级基线（状态与时间为现算值；逐文件明细需 JS 行展开）`,
    html: dataTable({
      columns: [
        { label: '产物对' },
        { label: '关联条目' },
        { label: '状态' },
        { label: '生成时间 (UTC)' },
      ],
      rows: flatPairRows(data.artifacts.pairs),
      empty: emptyState(PAIRS_EMPTY_COPY),
    }),
    foot: PAIRS_FLAT_FOOT,
  })
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

/** Flat entries panel — the no-JS baseline (§6.6); app.js hides it on boot. */
function entriesPanel(data) {
  return panel({
    id: 'entries-flat',
    title: '条目明细',
    note: `${num(data.totalCount)} 条 · 无 JS 降级基线（JS 环境此面板隐藏，明细已上移至 KPI 展开区）`,
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
function renderBody(domains, projectRoot) {
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
  return `${tiles}${kpiExpansionPanels(data, projectRoot)}${pairsExpansionPanel(data, projectRoot)}${tagPanel}${timelinePanel(data)}${entriesPanel(data)}${pairsFlatPanel(data)}`
}

/**
 * Render the exploration-cache page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderExplorationPage(input) {
  const envelope = input.domains.exploration
  const header = domainHeader({
    title: '探索缓存',
    subtitle: 'hot.json + index.json 的条目、tag 分布与注册时间线；artifacts 记录与配对计数；点击上方计数展开对应条目明细或产物对清单。',
    envelope,
  })
  const body = envelope.available === false ? domainUnavailable(envelope, EMPTY_COPY) : renderBody(input.domains, input.projectRoot)
  return renderLayout({
    title: '探索缓存',
    activeKey: 'exploration',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

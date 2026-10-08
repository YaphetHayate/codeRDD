// Tips view (#/tips).
import { badge, dataTable, emptyState, panel, statTile } from '../components.mjs'
import { barChart, stackedBar } from '../charts.mjs'
import { dateTime, esc, num } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, notesBlock } from './shared.mjs'

const EMPTY_COPY = {
  fact: '暂无 tips 条目 —— tips/entries 目录为空。',
  cause: '尚未有任何角色经 tips CLI 记录经验。',
  action: '完成一次带经验沉淀的任务后刷新本页。',
}

/** Tip rows; broken entries stay visible but carry no content. */
function tipRows(entries) {
  return entries.map((tip) => ({
    cells: [
      { text: tip.title === '' ? tip.id : tip.title, title: `${tip.title}\n\n问题：${tip.problem}`, html: undefined },
      { html: tip.roles.map((role) => badge(role, 'info')).join(' ') || '<span class="field-empty">—</span>' },
      { text: tip.recordedBy, muted: true },
      { text: dateTime(tip.recordedAt), mono: true, muted: true },
      { text: tip.broken ? '（解析失败）' : tip.avoidance, title: tip.avoidance, muted: tip.broken },
      { html: tip.deprecated ? badge('已废弃', 'neutral') : badge('有效', 'success') },
    ],
  }))
}

/** Body of the tips page. */
function renderBody(domains) {
  const data = domains.tips.data
  const tiles = [
    statTile({ value: num(data.count), label: '条目总数', unit: ' 条' }),
    statTile({ value: num(data.byRole.length), label: '覆盖角色', unit: ' 个' }),
    statTile({ value: num(data.byRecorder.length), label: '记录人', unit: ' 位' }),
    statTile({ value: num(data.activeCount), label: '有效条目', unit: ' 条', tone: 'ok' }),
    statTile({ value: num(data.deprecatedCount), label: '已废弃', unit: ' 条', tone: data.deprecatedCount > 0 ? 'warn' : 'ok' }),
  ].join('')
  const rolePanel = panel({
    title: '角色分布',
    note: '按 entry.roles 计数',
    html:
      data.byRole.length === 0
        ? emptyState({ fact: '暂无角色数据', cause: '条目 roles 为空。', action: '记录带 roles 的 tips 后此处显示分布。' })
        : barChart({ rows: data.byRole.map((entry) => ({ label: entry.role, value: entry.count })) }),
    foot: esc('一条 tip 可定向多个角色，故合计可大于条目数。'),
  })
  const recorderPanel = panel({
    title: '记录人构成',
    note: `${data.byRecorder.length} 位`,
    html:
      data.byRecorder.length === 0
        ? emptyState({ fact: '暂无记录人数据', cause: '条目 recordedBy 为空。', action: '记录 tips 后此处显示记录人构成。' })
        : stackedBar({ segments: data.byRecorder.map((entry) => ({ label: entry.recorder, value: entry.count })) }),
    foot: data.count < 5 ? `样本量小（${data.count} 条），分布仅作事实陈述，不具统计意义。` : '按 recordedBy 字段统计。',
  })
  const table = panel({
    title: '条目明细',
    note: `${data.count} 条`,
    html: dataTable({
      columns: [
        { label: '标题' },
        { label: '定向角色' },
        { label: '记录人' },
        { label: '记录时间 (UTC)' },
        { label: '回避方式' },
        { label: '状态' },
      ],
      rows: tipRows(data.entries),
      empty: emptyState({ fact: '暂无条目', cause: 'tips/entries 为空。', action: '记录一条经验后此处出现行。' }),
    }),
    foot: '标题与回避方式列完整文本在 title 属性中，表格内省略显示。',
  })
  return `${tiles}<div class="split-7-5">${rolePanel}${recorderPanel}</div>${table}`
}

/**
 * Render the tips page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderTipsPage(input) {
  const envelope = input.domains.tips
  const header = domainHeader({
    title: 'Tips',
    subtitle: '角色经验条目（rdd-tip/1）：列表、角色分布与记录人构成。',
    envelope,
  })
  const body = envelope.available === false ? domainUnavailable(envelope, EMPTY_COPY) : renderBody(input.domains)
  return renderLayout({
    title: 'Tips',
    activeKey: 'tips',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

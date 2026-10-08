// Retrieval-quality view (#/quality).
import { dataTable, emptyState, panel, statTile, stateBadge } from '../components.mjs'
import { stackedBar } from '../charts.mjs'
import { dateTime, esc, num, percent } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, notesBlock } from './shared.mjs'

const STATUS_LABELS = { pass: '通过', passed: '通过', partial: '部分', fail: '失败', failed: '失败', skip: '跳过', skipped: '跳过' }

const EMPTY_COPY = {
  fact: '暂无质量快照 —— results.json 不存在。',
  cause: '检索质量评估套件尚未在该数据根下运行（路径：.rdd/tests/explore-search/results.json）。',
  action: '运行检索质量评估后刷新本页。',
}

/** Per-case rows of the newest snapshot. */
function caseRows(snapshot) {
  if (snapshot === null) return []
  return snapshot.cases.map((testCase) => ({
    cells: [
      { text: testCase.id, mono: true },
      { html: stateBadge(testCase.status, STATUS_LABELS) },
      { text: testCase.checks === null ? '—' : `${testCase.checks.passed ?? 0}/${testCase.checks.total ?? 0}`, mono: true, align: 'right' },
      { text: testCase.checks === null ? '—' : String(testCase.checks.skipped ?? 0), mono: true, align: 'right', muted: true },
      { text: String(testCase.issueCount), mono: true, align: 'right', muted: true },
    ],
  }))
}

/** KPI row of the newest snapshot. */
function summaryTiles(data) {
  const summary = data.primary.summary
  const passRate = summary.total === 0 ? null : (summary.passed / summary.total) * 100
  return [
    statTile({ value: num(summary.total), label: '用例数', unit: ' 条', hint: `${data.snapshotCount} 份快照` }),
    statTile({ value: percent(passRate), label: '通过率', hint: '通过 / 用例总数' }),
    statTile({ value: num(summary.passed), label: '通过', unit: ' 条', tone: 'ok' }),
    statTile({ value: num(summary.partial), label: '部分', unit: ' 条', tone: summary.partial > 0 ? 'warn' : 'ok' }),
    statTile({ value: num(summary.failed), label: '失败', unit: ' 条', tone: summary.failed > 0 ? 'error' : 'ok' }),
    statTile({ value: num(summary.skipped), label: '跳过', unit: ' 条' }),
  ].join('')
}

/** Outcome-composition chart of the newest snapshot. */
function compositionPanel(data, summary) {
  return panel({
    chart: true,
    title: '结果构成',
    note: `快照生成于 ${data.primary.generatedAt === '' ? '—' : dateTime(data.primary.generatedAt)} UTC`,
    html: stackedBar({
      segments: [
        { label: '通过', value: summary.passed, tone: 'var(--ops-success)' },
        { label: '部分', value: summary.partial, tone: 'var(--ops-warn)' },
        { label: '失败', value: summary.failed, tone: 'var(--ops-error)' },
        { label: '跳过', value: summary.skipped, tone: 'var(--ops-chart-6)' },
      ],
    }),
    foot: `关联归档：${data.primary.archive === '' ? '—' : data.primary.archive}；特性：${data.primary.feature === '' ? '—' : data.primary.feature}。`,
  })
}

/** Snapshot-history table (newest first). */
function snapshotPanel(data) {
  return panel({
    title: '快照历史',
    note: `${data.snapshotCount} 份`,
    html: dataTable({
      columns: [{ label: '文件' }, { label: '生成时间 (UTC)' }, { label: '用例' }, { label: '通过' }, { label: '部分' }, { label: '失败' }],
      rows: data.snapshots.map((snapshot) => ({
        cells: [
          { text: snapshot.file, mono: true },
          { text: dateTime(snapshot.generatedAt), mono: true, muted: true },
          { text: num(snapshot.summary.total), align: 'right', mono: true },
          { text: num(snapshot.summary.passed), align: 'right', mono: true },
          { text: num(snapshot.summary.partial), align: 'right', mono: true },
          { text: num(snapshot.summary.failed), align: 'right', mono: true },
        ],
      })),
      empty: emptyState({ fact: '暂无快照', cause: 'results*.json 不存在。', action: '运行质量评估后此处出现快照。' }),
    }),
    foot: esc(data.snapshotCount <= 1 ? '仅 1 份快照：单点不构成趋势，不绘制趋势图。' : '多份快照按生成时间倒序排列。'),
  })
}

/** Per-case table of the newest snapshot. */
function casesPanel(data) {
  return panel({
    title: '用例明细',
    note: `${data.primary.cases.length} 条`,
    html: dataTable({
      columns: [
        { label: '用例' },
        { label: '结果' },
        { label: '检查通过/总数', align: 'right' },
        { label: '检查跳过', align: 'right' },
        { label: '问题数', align: 'right' },
      ],
      rows: caseRows(data.primary),
      empty: emptyState({ fact: '快照中无用例', cause: 'results.json 的 cases 为空。', action: '重跑质量评估并写入用例结果。' }),
    }),
    foot: `用例库（cases.json）当前登记 ${num(data.caseLibrary.activeCount)} 条；最近变更：${data.caseLibrary.lastChange === '' ? '—' : data.caseLibrary.lastChange}。`,
  })
}

/** Body of the quality page. */
function renderBody(domains) {
  const data = domains.quality.data
  const tiles = summaryTiles(data)
  const composition = compositionPanel(data, data.primary.summary)
  const snapshots = snapshotPanel(data)
  const cases = casesPanel(data)
  return `${tiles}${composition}${snapshots}${cases}`
}

/**
 * Render the retrieval-quality page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderQualityPage(input) {
  const envelope = input.domains.quality
  const header = domainHeader({
    title: '检索质量',
    subtitle: 'tests/explore-search/results.json 的质量摘要与逐用例结果。',
    envelope,
  })
  const body = envelope.available === false ? domainUnavailable(envelope, EMPTY_COPY) : renderBody(input.domains)
  return renderLayout({
    title: '检索质量',
    activeKey: 'quality',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

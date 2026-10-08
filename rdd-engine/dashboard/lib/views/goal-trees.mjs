// Delivery-tree view (#/goal-trees).
import { dataTable, emptyState, panel, statTile, stateBadge } from '../components.mjs'
import { barChart, stackedBar } from '../charts.mjs'
import { dateTime, esc, num } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, fixtureNote, notesBlock } from './shared.mjs'

const STATE_LABELS = {
  running: '进行中',
  completed: '已完成',
  concluded: '已收敛',
  blocked: '受阻',
  archived: '已归档',
  unknown: '未标注',
}

const EMPTY_COPY = {
  fact: '暂无真实交付树 —— goal-trees/ 下没有可识别的交付树目录。',
  cause: '交付树的目录缺 manifest.json 与 state/tree.json，或该数据根尚未运行交付。',
  action: '运行一次 delivery-bridge 交付后刷新本页。',
}

/** One row per tree. */
function treeRows(trees) {
  return trees.map((tree) => ({
    cells: [
      { text: tree.runId, mono: true },
      { text: tree.archive ? '已归档' : '活跃', muted: true },
      { html: stateBadge(tree.state, STATE_LABELS) },
      { text: `${num(tree.doneNodes)}/${num(tree.nodeCount)}`, mono: true, align: 'right' },
      { text: num(tree.rounds), mono: true, align: 'right' },
      { text: dateTime(tree.updatedAt), mono: true, muted: true },
      { text: tree.goal, title: tree.goal, muted: true },
    ],
  }))
}

/** KPI row of the delivery-tree page. */
function summaryTiles(data) {
  return [
    statTile({ value: num(data.totalCount), label: '真实交付树', unit: ' 棵', hint: '已排除夹具' }),
    statTile({ value: num(data.activeRootCount), label: '活跃', unit: ' 棵', hint: 'goal-trees/' }),
    statTile({ value: num(data.archivedRootCount), label: '已归档', unit: ' 棵', hint: 'goal-trees-archive/' }),
    statTile({ value: num(data.nodeCount), label: '节点合计', unit: ' 个' }),
    statTile({ value: num(data.roundMax), label: '最大轮次', unit: ' 轮', hint: `轮次合计 ${num(data.roundTotal)}` }),
    statTile({ value: num(data.excludedCount), label: '已排除夹具', unit: ' 个', tone: data.excludedCount > 0 ? 'warn' : 'ok' }),
  ].join('')
}

/** State-composition chart. */
function statesPanel(data) {
  return panel({
    chart: true,
    title: '状态构成',
    note: '按 manifest.state 计数',
    html:
      data.states.length === 0
        ? emptyState({ fact: '暂无状态数据', cause: '没有可识别的交付树。', action: '运行交付后此处显示状态构成。' })
        : stackedBar({ segments: data.states.map((entry) => ({ label: STATE_LABELS[entry.state] ?? entry.state, value: entry.count })) }),
    foot: '状态取自 tree 的 manifest.state；已归档树集中标记为「已归档」。',
  })
}

/** Active/archived root distribution chart. */
function rootsPanel(data) {
  return panel({
    title: '根目录分布',
    note: '活跃 / 已归档',
    html: barChart({
      rows: [
        { label: '活跃树', value: data.activeRootCount },
        { label: '已归档树', value: data.archivedRootCount },
      ],
    }),
    foot: `枚举交付树目录 ${num(data.dirCount)} 个：真实 ${num(data.totalCount)} 棵 + 夹具 ${num(data.excludedCount)} 个。`,
  })
}

/** Per-tree detail table. */
function tablePanel(data) {
  return panel({
    title: '交付树明细',
    note: `${data.totalCount} 棵`,
    html: dataTable({
      columns: [
        { label: 'run_id' },
        { label: '根' },
        { label: '状态' },
        { label: '完成/节点', align: 'right' },
        { label: '轮次', align: 'right' },
        { label: '更新时间 (UTC)' },
        { label: '目标' },
      ],
      rows: treeRows(data.trees),
      empty: emptyState({ fact: '暂无交付树', cause: '两个根目录下都没有可识别的交付树。', action: '运行一次交付后此处出现记录。' }),
    }),
    foot: '交付树只读 manifest / state/tree.json / round-log.jsonl，不读取 report/ 全量产物。',
  })
}

/** Fixture-exclusion declaration (AC 5 transparency). */
function excludedPanel(data) {
  return panel({
    title: '排除声明',
    html: fixtureNote({
      excludedCount: data.excludedCount,
      enumeratedCount: data.dirCount,
      deliverNamedCount: data.deliverNamedCount,
      realCount: data.totalCount,
    }),
    foot: '排除规则单源：dashboard/lib/paths.mjs isExcludedPath()（临时目录段、夹具命名约定、哨兵日期目录与 qa- 前缀自动目录）；被排除目录不出现在任何统计、图表与列表中。',
  })
}

/** Body of the delivery-tree page. */
function renderBody(domains) {
  const data = domains['goal-trees'].data
  return `${summaryTiles(data)}${excludedPanel(data)}<div class="split-7-5">${statesPanel(data)}${rootsPanel(data)}</div>${tablePanel(data)}`
}

/**
 * Render the delivery-tree page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderGoalTreesPage(input) {
  const envelope = input.domains['goal-trees']
  const header = domainHeader({
    title: '交付树',
    subtitle: 'goal-trees/ 与 goal-trees-archive/ 的树数量、状态与轮次（夹具目录已排除）。',
    envelope,
  })
  const body = envelope.available === false ? domainUnavailable(envelope, EMPTY_COPY) : renderBody(input.domains)
  return renderLayout({
    title: '交付树',
    activeKey: 'goal-trees',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

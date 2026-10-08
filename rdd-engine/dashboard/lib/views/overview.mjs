// Overview view (#/) — hero, six KPI cards, cross-domain scale, recent activity.
import { emptyState, icon, noteBar, panel, sectionHead, statChip, timeline } from '../components.mjs'
import { barChart, ratioBar, stackedBar } from '../charts.mjs'
import { esc, num, percent } from '../format.mjs'
import { renderLayout } from '../layout.mjs'
import { DOMAIN_DEFS } from '../overview.mjs'
import { fixtureNote } from './shared.mjs'

/** Hero chips: the four numbers the reporting scenario reads first. */
function heroChips(domains, overview) {
  const archives = domains.requirements.data
  const hitRate = domains['hit-rate'].data
  const tips = domains.tips.data
  const trees = domains['goal-trees'].data
  const items = [
    { label: '需求归档', value: num(archives.totalCount), note: `个归档 · 打回 ${archives.remarks.length}` },
    {
      label: '命中率',
      value: hitRate.hitRatePercent === null ? '暂无数据' : percent(hitRate.hitRatePercent),
      note: hitRate.total === 0 ? '尚无查询流水' : `hit ${hitRate.hit} / miss ${hitRate.miss}`,
    },
    { label: 'Tips', value: num(tips.count), note: `条经验 · ${tips.byRole.length} 个角色` },
    {
      label: '交付树',
      value: num(trees.totalCount),
      note: `棵真实 · 排除 ${overview.fixture.excludedCount} 夹具`,
    },
  ]
  return items
    .map(
      (item) =>
        `<div class="hero-chip"><span class="hero-chip-label">${esc(item.label)}</span><span class="hero-chip-value">${esc(item.value)}</span><span class="hero-chip-note">${esc(item.note)}</span></div>`
    )
    .join('')
}

/** Owner distribution for the requirement-archive card. */
function requirementMini(domains) {
  const owners = domains.requirements.data.owners.slice(0, 4)
  if (owners.length === 0) {
    return emptyState({ fact: '暂无 Owner 数据', cause: '归档任务尚未记录 currentOwners。', action: '任务进入路由后此处显示 Owner 分布。' })
  }
  return stackedBar({ segments: owners.map((owner) => ({ label: owner.name, value: owner.count })) })
}

/** Tag distribution for the exploration card. */
function explorationMini(domains) {
  const exploration = domains.exploration.data
  if (exploration.totalCount === 0) {
    return emptyState({
      fact: '暂无条目 —— hot.json 与 index.json 的 entries 均为空。',
      cause: '探索缓存热区当前为空，尚未注册任何检索条目。',
      action: '执行一次 rdd_explore 检索并注册，或运行缓存维护脚本后刷新本页。',
    })
  }
  return barChart({ rows: exploration.tags.slice(0, 4).map((tag) => ({ label: tag.tag, value: tag.count })) })
}

/** Hit/miss ratio bar for the hit-rate card. */
function hitRateMini(domains) {
  const hitRate = domains['hit-rate'].data
  if (hitRate.total === 0) {
    return emptyState({
      fact: '暂无数据 —— 检索链路尚未产生查询流水。',
      cause: '#1 查询流水记录未交付或尚未积累流水（.rdd/exploration/query-log.jsonl 不存在或为空）。',
      action: '执行至少一次 rdd_explore 检索后刷新本页。',
    })
  }
  return `${ratioBar({ hit: hitRate.hit, miss: hitRate.miss, forced: hitRate.forced })}<div class="chart-note">流水时段 ${esc(hitRate.timeRange.first.slice(0, 16).replace('T', ' '))} – ${esc(hitRate.timeRange.last.slice(11, 16))} UTC · 最近 query：<code>${esc(hitRate.newestQuery)}</code></div>`
}

/** Outcome composition for the quality card. */
function qualityMini(domains) {
  const summary = domains.quality.data.primary?.summary
  if (summary === undefined) {
    return emptyState({ fact: '暂无质量快照', cause: 'results.json 不存在。', action: '运行检索质量评估套件后刷新本页。' })
  }
  return stackedBar({
    segments: [
      { label: '通过', value: summary.passed, tone: 'var(--ops-success)' },
      { label: '部分', value: summary.partial, tone: 'var(--ops-warn)' },
      { label: '失败', value: summary.failed, tone: 'var(--ops-error)' },
      { label: '跳过', value: summary.skipped, tone: 'var(--ops-chart-6)' },
    ],
  })
}

/** Role distribution for the tips card. */
function tipsMini(domains) {
  const tips = domains.tips.data
  if (tips.count === 0) {
    return emptyState({ fact: '暂无 tips 条目', cause: 'tips/entries 目录为空。', action: '经 tips CLI 记录一条经验后刷新本页。' })
  }
  return stackedBar({ segments: tips.byRole.slice(0, 5).map((role) => ({ label: role.role, value: role.count })) })
}

/** Real-vs-fixture line plus active/archived split for the delivery-tree card. */
function goalTreesMini(domains) {
  const trees = domains['goal-trees'].data
  if (trees.totalCount === 0) {
    return emptyState({ fact: '暂无真实交付树', cause: 'goal-trees/ 下没有可识别的交付树目录。', action: '运行一次 delivery-bridge 交付后刷新本页。' })
  }
  return `<div class="chart-note">真实交付树 ${num(trees.totalCount)} 棵 · 已排除夹具 ${num(trees.excludedCount)} 个 · 节点合计 ${num(trees.nodeCount)}</div>${stackedBar({
    segments: [
      { label: '活跃', value: trees.activeRootCount },
      { label: '已归档', value: trees.archivedRootCount },
    ],
  })}`
}

const MINI_BUILDERS = {
  requirements: requirementMini,
  exploration: explorationMini,
  'hit-rate': hitRateMini,
  quality: qualityMini,
  tips: tipsMini,
  'goal-trees': goalTreesMini,
}

/** Mini visual inside a KPI card (distribution / ratio / fixture line). */
function cardMini(key, domains) {
  const build = MINI_BUILDERS[key] ?? goalTreesMini
  return build(domains)
}

/** One KPI card (整卡为链接, UX §5.5). */
function kpiCard(card, definition, domains, accentIndex) {
  const chips = card.chips
    .filter((entry) => entry.value !== undefined)
    .map((entry) => statChip(entry.label, entry.value, { tone: entry.tone }))
    .join('')
  const emptyTag = card.emptyWhenZero && Number(card.value) === 0 ? `<span class="card-tag">空态</span>` : ''
  return `<a class="kpi-card" href="${esc(definition.route)}" data-accent="${accentIndex + 1}"><span class="accent-rail" aria-hidden="true"></span><div class="kpi-top">${icon(definition.icon, 'kpi-icon')}<span class="kpi-title">${esc(definition.title)}</span>${emptyTag}</div><div class="kpi-value">${esc(card.value)}<span class="kpi-unit">${esc(card.unit)}</span></div><div class="kpi-sub">${chips}</div><div class="kpi-mini">${cardMini(card.key, domains)}</div><span class="card-link">进入 ${esc(definition.title)} →</span></a>`
}

/** Recent activity feed items as timeline entries. */
function recentItems(overview) {
  return overview.recent.map((item) => ({
    at: item.at,
    kind: item.kind,
    tone: item.tone,
    href: item.href,
    html: `${esc(item.text)}${item.meta === undefined ? '' : ` <span class="tl-meta-extra">${esc(item.meta)}</span>`}`,
  }))
}

/**
 * Overview page body: notices + hero + KPI grid + compare/recent panels.
 * @param {{domains: object, overview: object, projectRoot: string, generatedAt: string, notice?: string}} input
 */
function overviewBody(input) {
  const { domains, overview } = input
  const hero = `<section class="hero" id="ops-hero" aria-label="看板标题区"><button type="button" class="hero-toggle" id="ops-hero-toggle" aria-expanded="true" aria-label="折叠标题区">${icon('chevron', 'chevron')}</button><span class="hero-eyebrow">本地只读服务 · 每请求实时读盘</span><h1>RDD 运营看板</h1><p class="hero-desc">六个 P0 数据域的规模、质量与活动事实。数据根 <code>${esc(input.projectRoot)}</code>，刷新即见最新落盘数据。</p><div class="hero-kpis">${heroChips(domains, overview)}</div></section>`
  const cards = overview.cards
    .map((card, index) => kpiCard(card, DOMAIN_DEFS[index], domains, index))
    .join('')
  const grid = `${sectionHead('数据域总览', '6 个数据域')}<div class="kpi-grid">${cards}</div>${fixtureNote(overview.fixture)}`
  const compare = panel({
    title: '跨域规模对比',
    note: '条目计数（0 值保留虚线空轨）',
    html: barChart({ rows: overview.crossDomain.map((row) => ({ label: row.label, value: row.value, href: row.href })) }),
    foot: esc('最长条 = 当前最大域；各域口径见对应域页页脚说明。'),
  })
  const recent = panel({
    title: '近期活动',
    note: `最近 ${overview.recent.length} 条`,
    html: timeline({
      items: recentItems(overview),
      empty: emptyState({ fact: '暂无活动', cause: '六个数据域均无带时间戳的记录。', action: '任一写入方（需求归档 / tips / 探索缓存 / 交付树）产生数据后此处自动更新。' }),
    }),
    foot: esc('时间均为 UTC；跨域事件按时间倒序合并。'),
  })
  const allEmptyNote = overview.allEmpty
    ? noteBar({ variant: 'info', text: '全部 6 个数据域当前均无数据，请先运行相应写入方。' })
    : ''
  const notes = Object.values(domains)
    .flatMap((envelope) => envelope.meta.notes.slice(0, 1))
    .filter((note) => note !== '')
  const notesHtml = notes.length === 0 ? '' : noteBar({ variant: 'info', html: notes.map((note) => esc(note)).join(' · ') })
  return `${input.notice ?? ''}${allEmptyNote}${hero}${notesHtml}${grid}<div class="split-7-5">${compare}${recent}</div>`
}

/**
 * Render the overview page (route /) inside the shared AppShell — the landing
 * page the one-command start points at, so it must carry the same shell
 * (sidebar / topbar / footer / app.js) as every domain page.
 * @param {{domains: object, overview: object, projectRoot: string, generatedAt: string, counts: object}} input
 */
export function renderOverview(input) {
  return renderLayout({
    title: '总览',
    activeKey: 'overview',
    counts: input.counts,
    options: { ...input, fixture: input.overview.fixture },
    body: overviewBody(input),
  })
}

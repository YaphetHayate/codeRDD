// Cross-domain aggregation for the overview view.
//
// Reads every P0 domain through its reader and derives the numbers the overview
// needs: the six KPI cards, the cross-domain scale comparison, the recent
// activity feed, and the fixture-exclusion declaration. Nothing here formats
// HTML — views own presentation.
import { makeEnvelope } from './io.mjs'
import { readArchives } from './readers/archives.mjs'
import { readConfig } from './readers/config.mjs'
import { readExploration } from './readers/exploration.mjs'
import { readGoalTrees } from './readers/goal-trees.mjs'
import { readHitRate } from './readers/query-log.mjs'
import { readQuality } from './readers/quality.mjs'
import { readTips } from './readers/tips.mjs'

const RECENT_ARCHIVES = 6
const RECENT_TIPS = 3
const RECENT_TREES = 3

/** The six P0 domains with their routes (order is the navigation order). */
export const DOMAIN_DEFS = [
  { key: 'requirements', title: '需求归档', route: '/requirements', icon: 'archive' },
  { key: 'exploration', title: '探索缓存', route: '/exploration', icon: 'cache' },
  { key: 'hit-rate', title: '命中率', route: '/hit-rate', icon: 'target' },
  { key: 'quality', title: '检索质量', route: '/quality', icon: 'check' },
  { key: 'tips', title: 'Tips', route: '/tips', icon: 'bulb' },
  { key: 'goal-trees', title: '交付树', route: '/goal-trees', icon: 'tree' },
  { key: 'config', title: '配置中心', route: '/config', icon: 'gear' },
]

/**
 * Run one reader with the single-domain isolation contract (UX §6.2 / AC 2):
 * a domain that throws must degrade to "available: false + note" instead of
 * taking the whole page down with it. Readers already swallow per-file errors;
 * this is the last line of defence for unexpected failures.
 * @param {string} domain
 * @param {string} source
 * @param {() => object} reader
 */
function safeRead(domain, source, reader) {
  try {
    return reader()
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const env = makeEnvelope(domain, source, [`该数据域取数失败：${message}（其余数据域不受影响）`])
    env.data = { failed: true }
    return env
  }
}

/**
 * Read every domain once per request (no caching layer — AC 4).
 * @param {{rddRoot: string, projectRoot: string}} context
 */
export function readAllDomains(context) {
  return {
    requirements: safeRead('requirements', '.rdd/changes/archive/**', () => readArchives(context)),
    exploration: safeRead('exploration', '.rdd/exploration/**', () => readExploration(context)),
    'hit-rate': safeRead('hit-rate', '.rdd/exploration/query-log.jsonl', () => readHitRate(context)),
    quality: safeRead('quality', '.rdd/tests/explore-search/results.json', () => readQuality(context)),
    tips: safeRead('tips', '.rdd/tips/entries/*.json', () => readTips(context)),
    'goal-trees': safeRead('goal-trees', '.rdd/goal-trees*/**', () => readGoalTrees(context)),
    config: safeRead('config', 'env + .rdd/exploration/search-config.json + 内置镜像常量', () => readConfig(context)),
  }
}

/** Nav counters: one number per domain (0 stays visible — an empty domain is a fact). */
export function navCounts(domains) {
  return {
    requirements: domains.requirements.data?.totalCount ?? 0,
    exploration: domains.exploration.data?.totalCount ?? 0,
    'hit-rate': domains['hit-rate'].data?.total ?? 0,
    quality: domains.quality.data?.primary?.summary.total ?? 0,
    tips: domains.tips.data?.count ?? 0,
    'goal-trees': domains['goal-trees'].data?.totalCount ?? 0,
    config: domains.config.data?.l2?.nonDefaultCount ?? 0,
  }
}

/** Zeroed summary used when a data root has no quality snapshot at all. */
const EMPTY_QUALITY_SUMMARY = { total: 0, passed: 0, partial: 0, failed: 0, skipped: 0 }

/** Card for the requirement-archive domain. */
function requirementCard(archives) {
  const lifecycle = archives.lifecycle ?? {}
  const rejectionCount = archives.remarks.length
  return {
    key: 'requirements',
    value: String(archives.totalCount),
    unit: '个归档',
    chips: [
      { label: '进行中', value: lifecycle.active ?? 0 },
      { label: '已完成', value: lifecycle.completed ?? 0 },
      { label: '打回', value: rejectionCount, tone: rejectionCount > 0 ? 'warn' : undefined },
    ],
    note: `结构化 ${archives.structuredCount} · 旧结构 ${archives.legacyCount}`,
  }
}

/** Card for the exploration-cache domain. */
function explorationCard(exploration) {
  return {
    key: 'exploration',
    value: String(exploration.totalCount),
    unit: '条条目',
    chips: [
      { label: '热区', value: exploration.hotCount },
      { label: '持久', value: exploration.indexCount },
    ],
    note: `artifact 记录 ${exploration.artifacts.count} 条（配对 ${exploration.artifacts.pairedCount}）`,
    emptyWhenZero: true,
  }
}

/** Card for the hit-rate domain (no flow yet reads as "暂无数据", not as 0%). */
function hitRateCard(hitRate) {
  return {
    key: 'hit-rate',
    value: hitRate.hitRatePercent === null ? '暂无' : hitRate.hitRatePercent.toFixed(1),
    unit: hitRate.hitRatePercent === null ? '数据' : '%',
    chips: [
      { label: 'hit', value: hitRate.hit },
      { label: 'miss', value: hitRate.miss },
      { label: 'forced', value: hitRate.forced },
    ],
    note: hitRate.total === 0 ? '检索链路尚未产生查询流水' : `流水 ${hitRate.total} 条 · 最近 query：${hitRate.newestQuery}`,
    emptyWhenZero: hitRate.total === 0,
  }
}

/** Card for the retrieval-quality domain. */
function qualityCard(quality, summary) {
  return {
    key: 'quality',
    value: String(summary.total),
    unit: `用例 · ${quality.snapshotCount} 份快照`,
    chips: [
      { label: '通过', value: summary.passed },
      { label: '部分', value: summary.partial, tone: summary.partial > 0 ? 'warn' : undefined },
      { label: '失败', value: summary.failed, tone: summary.failed > 0 ? 'error' : undefined },
      { label: '跳过', value: summary.skipped },
    ],
    note: quality.primary === null ? '无质量快照' : `快照 ${quality.primary.generatedAt.slice(0, 10)} · 用例库 ${quality.caseLibrary.activeCount} 条`,
    emptyWhenZero: quality.primary === null,
  }
}

/** Card for the tips domain. */
function tipsCard(tips) {
  return {
    key: 'tips',
    value: String(tips.count),
    unit: '条经验',
    chips: tips.byRole.slice(0, 3).map((entry) => ({ label: entry.role, value: entry.count })),
    note: `记录人 ${tips.byRecorder.length} 位 · 已废弃 ${tips.deprecatedCount}`,
    emptyWhenZero: tips.count === 0,
  }
}

/** Card for the delivery-tree domain (fixture exclusions stay visible). */
function goalTreesCard(trees) {
  return {
    key: 'goal-trees',
    value: String(trees.totalCount),
    unit: '棵交付树',
    chips: [
      { label: '活跃', value: trees.activeRootCount },
      { label: '已归档', value: trees.archivedRootCount },
      { label: '已排除夹具', value: trees.excludedCount, tone: trees.excludedCount > 0 ? 'warn' : undefined },
    ],
    note: `节点合计 ${trees.nodeCount} · 最大轮次 ${trees.roundMax}`,
    emptyWhenZero: trees.totalCount === 0,
  }
}

/** KPI card payloads for the overview grid (order = DOMAIN_DEFS order). */
function buildCards(domains) {
  const quality = domains.quality.data
  return [
    requirementCard(domains.requirements.data),
    explorationCard(domains.exploration.data),
    hitRateCard(domains['hit-rate'].data),
    qualityCard(quality, quality.primary?.summary ?? EMPTY_QUALITY_SUMMARY),
    tipsCard(domains.tips.data),
    goalTreesCard(domains['goal-trees'].data),
  ]
}

/** Recent activity feed across domains (timeline of facts). */
function buildRecent(domains) {
  const items = []
  for (const archive of domains.requirements.data.archives.slice(0, RECENT_ARCHIVES)) {
    items.push({
      at: archive.updatedAt,
      kind: '需求归档',
      tone: 'info',
      text: archive.structured ? archive.firstTitle : `${archive.name}（旧结构，无 task.json）`,
      meta: archive.name,
      href: archive.structured
        ? `/requirements/${archive.name}/${archive.tasks[0]?.id ?? ''}`
        : '/requirements',
    })
  }
  for (const tip of domains.tips.data.entries.slice(0, RECENT_TIPS)) {
    items.push({
      at: tip.recordedAt,
      kind: 'tip',
      tone: 'success',
      text: tip.title === '' ? tip.id : tip.title,
      meta: tip.recordedBy,
      href: '/tips',
    })
  }
  for (const tree of domains['goal-trees'].data.trees.slice(0, RECENT_TREES)) {
    items.push({
      at: tree.updatedAt,
      kind: '交付树',
      tone: 'neutral',
      text: tree.runId,
      meta: tree.state,
      href: '/goal-trees',
    })
  }
  const newestQuery = domains['hit-rate'].data.detail[0]
  if (newestQuery !== undefined) {
    items.push({
      at: newestQuery.ts,
      kind: '流水',
      tone: newestQuery.outcome === 'hit' ? 'success' : 'error',
      text: newestQuery.query,
      meta: newestQuery.outcome,
      href: '/hit-rate',
    })
  }
  return items
    .filter((item) => item.at !== '')
    .sort((left, right) => right.at.localeCompare(left.at))
    .slice(0, 12)
}

/** The single "scale" number each domain contributes to the comparison chart. */
function domainScale(key, domain) {
  switch (key) {
    case 'requirements':
    case 'exploration':
      return domain.data.totalCount
    case 'hit-rate':
      return domain.data.total
    case 'quality':
      return domain.data.primary?.summary.total ?? 0
    case 'tips':
      return domain.data.count
    case 'config':
      return domain.data.l2?.nonDefaultCount ?? 0
    default:
      return domain.data.totalCount
  }
}

/** The overview payload (cards + comparisons + activity + exclusions). */
export function buildOverview(domains) {
  const trees = domains['goal-trees'].data
  return {
    cards: buildCards(domains),
    crossDomain: DOMAIN_DEFS.map((definition) => ({
      label: definition.title,
      value: domainScale(definition.key, domains[definition.key]),
      href: definition.route,
    })),
    recent: buildRecent(domains),
    fixture: {
      excludedCount: trees.excludedCount,
      enumeratedCount: trees.dirCount,
      deliverNamedCount: trees.deliverNamedCount,
      realCount: trees.totalCount,
    },
    allEmpty: DOMAIN_DEFS.every((definition) => domains[definition.key].available === false),
  }
}

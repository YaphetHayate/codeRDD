// DEV self-test for the operations dashboard (requirement
// 2026-10-08-rdd-ops-dashboard / ops-dashboard).
//
// Two layers:
//   1. reader unit assertions over purpose-built fixture data roots — fixture
//      exclusion, hit-rate accounting, sparse-data degradation, BOM tolerance,
//      corrupt-line skipping, legacy archives;
//   2. HTTP assertions over the real service — page text must carry the ground
//      truth numbers, the JSON API must follow the envelope contract, static
//      assets must be served, EADDRINUSE must be explicit, and no fixture token
//      may appear on any rendered page.
//
// Run: node rdd-engine/tests/test-dashboard.mjs
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, openSync, closeSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { isExcludedPath, resolveDataRoot } from '../dashboard/lib/paths.mjs'
import { readArchives, readArchiveDetail } from '../dashboard/lib/readers/archives.mjs'
import { readExploration } from '../dashboard/lib/readers/exploration.mjs'
import { readHitRate } from '../dashboard/lib/readers/query-log.mjs'
import { readQuality } from '../dashboard/lib/readers/quality.mjs'
import { readTips } from '../dashboard/lib/readers/tips.mjs'
import { readGoalTrees } from '../dashboard/lib/readers/goal-trees.mjs'
import { buildOverview, readAllDomains } from '../dashboard/lib/overview.mjs'
import { trendMode } from '../dashboard/lib/charts.mjs'
import { startServer } from '../dashboard/server.mjs'

const engineDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const launcher = join(engineDir, 'scripts', 'dashboard.cmd')
const results = []
const cleanups = []

function assertTrue(condition, name, detail = '') {
  results.push({ name, ok: Boolean(condition), detail })
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${condition ? '' : `   ${detail}`}`)
}

function write(root, relativePath, content, options = {}) {
  const absolute = join(root, relativePath)
  mkdirSync(dirname(absolute), { recursive: true })
  const body = options.bom === true ? `\uFEFF${content}` : content
  writeFileSync(absolute, body, 'utf8')
  return absolute
}

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`
}

function makeWorkspace(prefix) {
  const root = mkdtempSync(join(tmpdir(), `rdd-dashboard-${prefix}-`))
  cleanups.push(root)
  return root
}

/**
 * The first ancestor of the OS temp directory that already contains a project
 * data root (null when there is none) — the cwd-walk assertion may only expect a
 * failure when no ancestor would satisfy the walk. A ".rdd" that holds only the
 * user-level skills install is deliberately not a data root.
 */
function findRddAncestorStart() {
  const markers = ['changes', 'tips', 'exploration', 'goal-trees', 'design-system', 'handoff', 'labs', 'tests']
  let current = resolve(tmpdir())
  for (;;) {
    const rddRoot = join(current, '.rdd')
    if (existsSync(rddRoot) && markers.some((marker) => existsSync(join(rddRoot, marker)))) return current
    const parent = dirname(current)
    if (parent === current) return null
    current = parent
  }
}

/** Fixture data root A: every domain populated, plus noise that must be excluded. */
function buildRichRoot() {
  const root = makeWorkspace('rich')
  write(root, '.rdd/changes/archive/2026-01-01-alpha/task.json', json({
    archive: '2026-01-01-alpha',
    generatedAt: '2026-01-02T00:00:00Z',
    version: 1,
    tasks: [
      {
        id: 1,
        title: '第一条中文需求（BOM 与编码验证）',
        lifecycle: 'completed',
        phase: 'VERIFY',
        currentOwners: ['QA'],
        currentWorker: [{ DEV: '2026-01-01T01:00:00' }],
        remark: '先 CTO 后 UX | 打回一次：验收标准不完整',
        designDocs: [{ path: 'design/alpha-cto.md', status: 'ready' }],
        requirement: 'requirements/alpha.md',
      },
      {
        id: 2,
        title: '第二条需求（进行中）',
        lifecycle: 'active',
        phase: 'IMPL',
        currentOwners: ['DEV', 'QA'],
        remark: '',
        designDocs: [],
        requirement: 'requirements/alpha.md',
      },
    ],
  }))
  write(root, '.rdd/changes/archive/2026-01-01-alpha/requirements/alpha.md', [
    '# 第一条中文需求',
    '',
    '- **描述**：验证看板对中文与 BOM 数据的解码。',
    '- **优先级**：高',
    '- **验收标准**：',
    '  1. 页面出现中文标题',
    '  2. 数字与地面真值一致',
    '- **影响范围**：纯新增',
    '- **依赖关系**：无',
    '',
    '## 流转控制',
  ].join('\n'))
  write(root, '.rdd/changes/archive/2019-05-05-legacy/task.md', '# 旧结构归档\n\n本归档没有 task.json，只有根目录 task.md。\n')
  write(root, '.rdd/changes/archive/2099-12-31-qa-fixture-ghost/task.json', json({
    archive: '2099-12-31-qa-fixture-ghost',
    tasks: [{ id: 1, title: '夹具需求不得出现', lifecycle: 'active' }],
  }))
  write(root, '.rdd/exploration/hot.json', json({
    entries: [
      { key: 'demo/hot-entry', tags: ['dashboard', 'demo'], brief: '热区条目', path: '.rdd/exploration/artifacts/alpha.md', files: {}, registeredAt: '2026-01-03T02:00:00Z' },
      { key: 'demo/hot-second', tags: ['demo'], brief: '第二条热区条目', path: '.rdd/exploration/artifacts/beta.md', files: {}, registeredAt: '2026-01-02T02:00:00Z' },
    ],
  }))
  write(root, '.rdd/exploration/index.json', json({
    entries: [{ key: 'demo/indexed', tags: ['demo', 'index'], brief: '持久区条目', path: '.rdd/exploration/artifacts/alpha.md', files: {}, registeredAt: '2026-01-01T02:00:00Z' }],
  }))
  write(root, '.rdd/exploration/artifacts/alpha.md', '# alpha record\n')
  write(root, '.rdd/exploration/artifacts/alpha.summary.md', 'alpha summary\n')
  write(root, '.rdd/exploration/artifacts/beta.md', '# beta record (unpaired)\n')
  const logLines = [
    { ts: '2026-01-01T01:00:00.000Z', entry: 'cli', query: '第一条查询', outcome: 'hit', keys: ['demo/indexed'], recallers: [{ name: 'lexical', status: 'ok', qualified: 3 }] },
    { ts: '2026-01-01T02:00:00.000Z', entry: 'cli', query: '第二条查询', outcome: 'miss', keys: [], recallers: [{ name: 'lexical', status: 'ok', qualified: 0 }] },
    { ts: '2026-01-02T03:00:00.000Z', entry: 'dsh-plugin', query: '第三条查询', outcome: 'hit', keys: ['demo/hot-entry', 'demo/hot-second'], recallers: [{ name: 'lexical', status: 'ok', qualified: 2 }] },
    { ts: '2026-01-02T04:00:00.000Z', entry: 'dsh-plugin', query: '第四条查询', outcome: 'miss', keys: [], recallers: [] },
    { ts: '2026-01-03T05:00:00.000Z', entry: 'cli', query: '第五条查询', outcome: 'hit', keys: ['demo/hot-second'], recallers: [] },
    { ts: '2026-01-03T06:00:00.000Z', entry: 'cli', query: '强制派发查询', outcome: 'forced', keys: [], recallers: [] },
    { ts: '2026-01-03T07:00:00.000Z', entry: 'cli', query: '第六条查询', outcome: 'hit', keys: ['demo/hot-entry'], recallers: [], futureField: 'unknown fields are ignored' },
  ]
  write(root, '.rdd/exploration/query-log.jsonl', `${logLines.map((line) => JSON.stringify(line)).join('\n')}\n{"broken json line\n`)
  write(root, '.rdd/tips/entries/20260101T000000Z-DEV-aaaa.json', json({
    schema: 'rdd-tip/1', id: '20260101T000000Z-DEV-aaaa', title: '中文提示条目一', problem: '问题一', avoidance: '回避一',
    roles: ['DEV'], recordedBy: 'DEV', recordedAt: '2026-01-01T00:00:00Z', deprecated: false,
  }))
  write(root, '.rdd/tips/entries/20260102T000000Z-QA-bbbb.json', json({
    schema: 'rdd-tip/1', id: '20260102T000000Z-QA-bbbb', title: '中文提示条目二', problem: '问题二', avoidance: '回避二',
    roles: ['QA', 'DEV'], recordedBy: 'QA', recordedAt: '2026-01-02T00:00:00Z', deprecated: true,
  }), { bom: true })
  write(root, '.rdd/tips/entries/broken.json', '{"schema": "rdd-tip/1", "title": ')
  write(root, '.rdd/goal-trees/deliver-2026-01-01-alpha/manifest.json', json({
    format_version: 1, run_id: 'deliver-2026-01-01-alpha', goal: 'fixture run', state: 'running', created_at: '2026-01-01T00:00:00Z',
  }))
  write(root, '.rdd/goal-trees/deliver-2026-01-01-alpha/state/tree.json', json({
    run_id: 'deliver-2026-01-01-alpha', updated_at: '2026-01-04T00:00:00Z',
    nodes: [{ id: 'n1', status: 'done' }, { id: 'n2', status: 'done' }, { id: 'n3', status: 'claimed' }],
  }))
  write(root, '.rdd/goal-trees/deliver-2026-01-01-alpha/state/round-log.jsonl', '{"round":1}\n{"round":2}\n')
  write(root, '.rdd/goal-trees/deliver-2099-12-31-qa-fixture-ghost/manifest.json', json({ run_id: 'deliver-2099-12-31-qa-fixture-ghost', state: 'running' }))
  write(root, '.rdd/goal-trees/qa-bridge-plain-x/manifest.json', json({ run_id: 'qa-bridge-plain-x', state: 'running' }))
  write(root, '.rdd/goal-trees-archive/deliver-2026-01-02-beta/manifest.json', json({ run_id: 'deliver-2026-01-02-beta', state: 'concluded' }))
  write(root, '.rdd/goal-trees-archive/deliver-2026-01-02-beta/state/tree.json', json({ run_id: 'deliver-2026-01-02-beta', updated_at: '2026-01-05T00:00:00Z', nodes: [{ id: 'n1', status: 'done' }] }))
  write(root, '.rdd/tests/explore-search/results.json', json({
    generatedAt: '2026-01-06T00:00:00Z', archive: '2026-01-01-alpha', feature: 'explore-search',
    summary: { total: 3, passed: 2, failed: 1, skipped: 0, partial: 0 },
    cases: [{ id: 'TC-001', status: 'pass', checks: { total: 2, passed: 2 }, issues: [] }, { id: 'TC-002', status: 'pass', checks: { total: 1, passed: 1 }, issues: [] }, { id: 'TC-003', status: 'fail', checks: { total: 1, passed: 0 }, issues: [{ name: 'x' }] }],
  }))
  write(root, '.rdd/tests/explore-search/cases.json', json({ feature: 'explore-search', lastChange: '2026-01-01-alpha', cases: [{ id: 'TC-001' }, { id: 'TC-002' }, { id: 'TC-003' }] }))
  write(root, '.rdd/tmp/e2e-home/leak-token-aaa.txt', 'must never render\n')
  write(root, 'tmp/e2e-home/fixture-leak-token.txt', 'project-root tmp must never render\n')
  return root
}

/** Fixture data root B: sparse — no query log at all, one archive only. */
function buildSparseRoot() {
  const root = makeWorkspace('sparse')
  write(root, '.rdd/changes/archive/2026-02-02-solo/task.json', json({
    archive: '2026-02-02-solo', tasks: [{ id: 1, title: '稀疏数据域的单独需求', lifecycle: 'active', requirement: 'requirements/solo.md' }],
  }))
  write(root, '.rdd/changes/archive/2026-02-02-solo/requirements/solo.md', '# 稀疏需求\n\n- **描述**：只有一个归档。\n')
  return root
}

// ── unit: exclusion rule ───────────────────────────────────────────────
assertTrue(isExcludedPath('.rdd/tmp/e2e-home/x.json'), 'exclusion: .rdd/tmp/** excluded')
assertTrue(isExcludedPath('tmp/e2e-home/x.json'), 'exclusion: project tmp/** excluded')
assertTrue(isExcludedPath('deliver-2099-12-31-qa-fixture-ghost/state/tree.json'), 'exclusion: sentinel-date fixture excluded')
assertTrue(isExcludedPath('qa-bridge-plain-x/manifest.json'), 'exclusion: qa-bridge dir excluded')
assertTrue(isExcludedPath('qa-n5/whatever.txt'), 'exclusion: qa- prefixed dir excluded')
assertTrue(!isExcludedPath('.rdd/tests/explore-query-log/explore-query-log-qa-verify.ps1'), 'exclusion: ordinary test asset kept')
assertTrue(!isExcludedPath('deliver-2026-01-01-alpha/state/tree.json'), 'exclusion: real delivery tree kept')

const richRoot = buildRichRoot()
const richContext = { projectRoot: richRoot, rddRoot: join(richRoot, '.rdd') }

// ── unit: readers over the rich fixture ────────────────────────────────
const archives = readArchives(richContext)
assertTrue(archives.data.totalCount === 2, 'archives: fixture archive excluded from the total', `total=${archives.data.totalCount}`)
assertTrue(archives.data.legacyCount === 1 && archives.data.structuredCount === 1, 'archives: legacy structure counted separately', JSON.stringify(archives.data.lifecycle))
assertTrue(archives.data.remarks.length === 2, 'archives: remark split by "|" into two records', `remarks=${archives.data.remarks.length}`)
assertTrue(archives.data.owners.some((owner) => owner.name === 'QA' && owner.count === 2), 'archives: owner distribution aggregated', JSON.stringify(archives.data.owners))
assertTrue(archives.data.lifecycle.completed === 1 && archives.data.lifecycle.active === 1, 'archives: lifecycle counted per task', JSON.stringify(archives.data.lifecycle))

const detail = readArchiveDetail(richContext, '2026-01-01-alpha', '1')
assertTrue(detail.available === true && detail.data.task.title === '第一条中文需求（BOM 与编码验证）', 'detail: task resolved by archive + id')
assertTrue(detail.data.requirement.acceptanceItems.length === 2, 'detail: acceptance items parsed from the requirement doc', JSON.stringify(detail.data.requirement.acceptanceItems))
assertTrue(readArchiveDetail(richContext, '2099-12-31-qa-fixture-ghost', '1').available === false, 'detail: fixture archive is not reachable')
assertTrue(readArchiveDetail(richContext, '2026-01-01-alpha', '99').available === false, 'detail: unknown task id is not reachable')

const exploration = readExploration(richContext)
assertTrue(exploration.data.hotCount === 2 && exploration.data.indexCount === 1, 'exploration: hot + index merged', JSON.stringify({ hot: exploration.data.hotCount, index: exploration.data.indexCount }))
assertTrue(exploration.data.artifacts.count === 2 && exploration.data.artifacts.pairedCount === 1, 'exploration: artifact pairing counted', JSON.stringify(exploration.data.artifacts))

const hitRate = readHitRate(richContext)
assertTrue(hitRate.data.total === 7 && hitRate.data.skipped === 1, 'hit-rate: corrupt line skipped exactly once', JSON.stringify({ total: hitRate.data.total, skipped: hitRate.data.skipped }))
assertTrue(hitRate.data.hit === 4 && hitRate.data.miss === 2 && hitRate.data.forced === 1, 'hit-rate: outcome counts', JSON.stringify({ hit: hitRate.data.hit, miss: hitRate.data.miss, forced: hitRate.data.forced }))
assertTrue(hitRate.data.hitRatePercent === 66.67, 'hit-rate: hit/(hit+miss) with forced excluded from the denominator', String(hitRate.data.hitRatePercent))
assertTrue(hitRate.data.trend.length === 3, 'hit-rate: daily buckets', JSON.stringify(hitRate.data.trend.map((day) => day.day)))
assertTrue(hitRate.data.missQueries.length === 2, 'hit-rate: miss queries grouped by text', JSON.stringify(hitRate.data.missQueries))
assertTrue(hitRate.meta.notes.some((note) => note.includes('跳过 1 行')), 'hit-rate: skipped lines reported as a note', JSON.stringify(hitRate.meta.notes))

const quality = readQuality(richContext)
assertTrue(quality.data.primary.summary.failed === 1, 'quality: newest snapshot summary read', JSON.stringify(quality.data.primary.summary))
assertTrue(quality.data.snapshotCount === 1, 'quality: snapshot count')

const tips = readTips(richContext)
assertTrue(tips.data.count === 3, 'tips: broken entry counted as a file, not crashing the domain', `count=${tips.data.count}`)
assertTrue(tips.data.entries.some((tip) => tip.title === '中文提示条目二'), 'tips: BOM-prefixed entry parsed without mojibake')
assertTrue(tips.data.byRole.some((role) => role.role === 'DEV' && role.count === 2), 'tips: role distribution', JSON.stringify(tips.data.byRole))
assertTrue(tips.meta.notes.some((note) => note.includes('解析失败')), 'tips: broken entry surfaced as a note')

const trees = readGoalTrees(richContext)
assertTrue(trees.data.totalCount === 2, 'goal-trees: fixture trees excluded', `total=${trees.data.totalCount}`)
assertTrue(trees.data.excludedCount === 2, 'goal-trees: excluded fixture directories counted', `excluded=${trees.data.excludedCount}`)
assertTrue(trees.data.deliverNamedCount === 3, 'goal-trees: "deliver-*"-named enumeration matches the QA ground-truth formula (fixtures included in the enumeration count)', `named=${trees.data.deliverNamedCount}`)
assertTrue(trees.data.nodeCount === 4 && trees.data.roundMax === 2, 'goal-trees: node and round aggregation', JSON.stringify({ nodes: trees.data.nodeCount, rounds: trees.data.roundMax }))

// ── unit: degradation matrix + data-root resolution ────────────────────
assertTrue(trendMode([{ day: 'a' }], 3).mode === 'points', 'trend: sparse sample forbids a line chart')
assertTrue(trendMode([{ day: 'a' }, { day: 'b' }, { day: 'c' }], 7).mode === 'line', 'trend: three days and five-plus records allow a line chart')
assertTrue(trendMode([], 0).mode === 'empty', 'trend: no records renders the empty branch')
const cwdRoot = resolveDataRoot({ env: {}, cwd: join(richRoot, 'some', 'nested') })
assertTrue(cwdRoot.projectRoot === richRoot, 'root: nearest .rdd ancestor resolved from a nested cwd', cwdRoot.projectRoot)
assertTrue(resolveDataRoot({ env: { RDD_PROJECT_ROOT: richRoot }, cwd: tmpdir() }).projectRoot === richRoot, 'root: RDD_PROJECT_ROOT takes priority')
let explicitRootError = ''
try {
  resolveDataRoot({ env: { RDD_PROJECT_ROOT: join(richRoot, 'no-such-dir') }, cwd: richRoot })
} catch (error) {
  explicitRootError = error.message
}
assertTrue(explicitRootError.includes('没有 .rdd/'), 'root: a wrong RDD_PROJECT_ROOT fails loudly with guidance', explicitRootError)
const skillsOnlyRoot = makeWorkspace('skills-only')
write(skillsOnlyRoot, '.rdd/skills/manifest.json', json({ skills: [] }))
let skillsOnlyError = ''
try {
  resolveDataRoot({ env: { RDD_PROJECT_ROOT: skillsOnlyRoot }, cwd: skillsOnlyRoot })
} catch (error) {
  skillsOnlyError = error.message
}
assertTrue(skillsOnlyError.includes('不是项目数据根'), 'root: a skills-only .rdd is rejected instead of serving an empty board', skillsOnlyError)
assertTrue(findRddAncestorStart() === null, 'root: no project data root above the OS temp directory (precondition for the walk-miss assertion)')
let missingRootError = ''
try {
  resolveDataRoot({ env: {}, cwd: tmpdir() })
} catch (error) {
  missingRootError = error.message
}
assertTrue(missingRootError.includes('未找到 .rdd/'), 'root: the cwd walk skips non-data .rdd roots and fails loudly', missingRootError || '(no error thrown)')

// ── unit: single-domain isolation (AC 2) ──────────────────────────────
const brokenDomains = readAllDomains({ projectRoot: null, rddRoot: null })
assertTrue(Object.keys(brokenDomains).length === 6, 'isolation: all six domains are always present in the payload')
assertTrue(
  Object.values(brokenDomains).every((envelope) => envelope.available === false && envelope.meta.notes.length > 0),
  'isolation: a throwing domain degrades to available=false + note instead of failing the request',
  JSON.stringify(Object.keys(brokenDomains).filter((key) => brokenDomains[key].meta.notes.length === 0))
)
assertTrue(
  Object.values(brokenDomains).every((envelope) => envelope.meta.notes.some((note) => note.includes('取数失败'))),
  'isolation: the degraded note names the failing domain'
)

const overview = buildOverview(readAllDomains(richContext))
assertTrue(overview.fixture.excludedCount === 2 && overview.fixture.realCount === 2, 'overview: fixture declaration carries runtime numbers', JSON.stringify(overview.fixture))
assertTrue(overview.recent.some((item) => item.text === '第一条中文需求（BOM 与编码验证）'), 'overview: recent activity carries archive titles')

// ── HTTP: rich root pages ──────────────────────────────────────────────
function pageText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<style[\s\S]*?<\/style>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
}

async function fetchPage(base, path) {
  const response = await fetch(`${base}${path}`)
  return { status: response.status, html: await response.text() }
}

function listen(context, port) {
  return new Promise((resolvePromise, rejectPromise) => {
    const server = startServer({ context, port, quiet: true, onReady: () => resolvePromise(server) })
    server.on('error', rejectPromise)
    cleanups.push(() => server.close())
  })
}

const richPort = 8801
const sparsePort = 8802
const base = `http://127.0.0.1:${richPort}`
await listen(richContext, richPort)

const homeResponse = await fetchPage(base, '/')
const homeText = pageText(homeResponse.html)
assertTrue(homeResponse.status === 200 && homeText.trim().length > 200, 'HTTP: overview 200 with substantial text', `len=${homeText.trim().length}`)
assertTrue(/(?<!\d)2(?!\d)/.test(homeText) && homeText.includes('第一条中文需求（BOM 与编码验证）'), 'HTTP: overview carries ground-truth counts and CJK titles')
assertTrue(homeText.includes('66.7%') || homeText.includes('66.67%'), 'HTTP: overview shows the computed hit-rate percentage', homeText.match(/\d+(?:\.\d+)?%/g)?.join(',') ?? '')
assertTrue(homeText.includes('第六条查询'), 'HTTP: overview surfaces the newest logged query verbatim')
assertTrue(!/Unhandled|stack trace|Internal Server Error|System\.Exception/.test(homeText), 'HTTP: no crash markers on the overview')

const routeTexts = {}
for (const route of ['/', '/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees', '/requirements/2026-01-01-alpha/1']) {
  const page = await fetchPage(base, route)
  routeTexts[route] = pageText(page.html)
  assertTrue(page.status === 200, `HTTP: ${route} -> 200`, `status=${page.status}`)
}
const leaked = ['qa-fixture', 'qa-bridge', '2099-12-31', 'leak-token-aaa', 'fixture-leak-token', '夹具需求不得出现']
  .filter((token) => Object.values(routeTexts).some((text) => text.includes(token)))
assertTrue(leaked.length === 0, 'HTTP: no fixture token on any rendered page', `leaked=${leaked.join(',')}`)
assertTrue(routeTexts['/hit-rate'].includes('66.7%') || routeTexts['/hit-rate'].includes('66.67%'), 'HTTP: hit-rate page shows the ratio')
assertTrue(/<polyline/.test((await fetchPage(base, '/hit-rate')).html), 'HTTP: dense sample renders the daily trend line')
assertTrue(routeTexts['/requirements/2026-01-01-alpha/1'].includes('requirements/alpha.md'), 'HTTP: detail page shows document paths')
assertTrue(routeTexts['/requirements/2026-01-01-alpha/1'].includes('先 CTO 后 UX'), 'HTTP: detail page splits the remark into segments')
assertTrue(routeTexts['/goal-trees'].includes('已排除 2 个测试夹具目录'), 'HTTP: delivery-tree page declares the exclusion explicitly')

const missingDetail = await fetchPage(base, '/requirements/2026-01-01-alpha/99')
assertTrue(missingDetail.status === 404 && pageText(missingDetail.html).includes('未找到该需求'), 'HTTP: unknown task id renders the detail error state', `status=${missingDetail.status}`)
const unknownRoute = await fetchPage(base, '/nope')
assertTrue(unknownRoute.status === 404 && pageText(unknownRoute.html).includes('未识别的路由'), 'HTTP: unknown route falls back to the overview notice', `status=${unknownRoute.status}`)

const apiResponse = await fetch(`${base}/api/hit-rate`)
const apiEnvelope = await apiResponse.json()
assertTrue(apiResponse.status === 200 && apiEnvelope.domain === 'hit-rate' && typeof apiEnvelope.meta.generatedAt === 'string' && Array.isArray(apiEnvelope.meta.notes), 'API: hit-rate envelope contract', JSON.stringify(Object.keys(apiEnvelope)))
assertTrue(apiEnvelope.available === true && apiEnvelope.data.hitRatePercent === 66.67, 'API: hit-rate data payload', JSON.stringify(apiEnvelope.data.hitRatePercent))
const apiOverview = await (await fetch(`${base}/api/overview`)).json()
assertTrue(apiOverview.domain === 'overview' && apiOverview.data.cards.length === 6 && apiOverview.data.domains['goal-trees'].data.totalCount === 2, 'API: overview envelope aggregates all six domains')
const apiMissing = await fetch(`${base}/api/requirements/2026-01-01-alpha/99`)
assertTrue(apiMissing.status === 404, 'API: unknown detail returns 404 with the envelope', `status=${apiMissing.status}`)

const cssResponse = await fetch(`${base}/static/style.css`)
const cssText = await cssResponse.text()
assertTrue(cssResponse.status === 200 && cssText.includes('--ops-deepseek-500'), 'HTTP: stylesheet served with the token layer')
const jsResponse = await fetch(`${base}/static/app.js`)
assertTrue(jsResponse.status === 200 && (await jsResponse.text()).includes('ops-refresh'), 'HTTP: client script served')
const traversal = await fetch(`${base}/static/../server.mjs`)
assertTrue(traversal.status === 403 || traversal.status === 404, 'HTTP: static path traversal rejected', `status=${traversal.status}`)

// ── HTTP: real-time (AC 4) — a file written after startup shows up on refresh ──
const beforeTips = (await (await fetch(`${base}/api/tips`)).json()).data.count
write(richRoot, '.rdd/tips/entries/20260109T000000Z-DEV-live.json', json({
  schema: 'rdd-tip/1', id: '20260109T000000Z-DEV-live', title: '实时性验证条目', problem: 'p', avoidance: 'a',
  roles: ['DEV'], recordedBy: 'DEV', recordedAt: '2026-01-09T00:00:00Z', deprecated: false,
}))
const afterTipsResponse = await fetchPage(base, '/tips')
const afterTips = (await (await fetch(`${base}/api/tips`)).json()).data.count
assertTrue(afterTips === beforeTips + 1, 'HTTP: a new tips entry is visible without restarting the service', `before=${beforeTips} after=${afterTips}`)
assertTrue(pageText(afterTipsResponse.html).includes('实时性验证条目'), 'HTTP: refreshed page carries the new entry')
const noStoreResponse = await fetch(`${base}/`)
assertTrue(noStoreResponse.headers.get('cache-control')?.includes('no-store') === true, 'HTTP: responses are no-store (no caching layer above the readers)', String(noStoreResponse.headers.get('cache-control')))

// ── HTTP: sparse root (AC 2 placeholder branch) ────────────────────────
const sparseBase = `http://127.0.0.1:${sparsePort}`
const sparseRoot = buildSparseRoot()
await listen({ projectRoot: sparseRoot, rddRoot: join(sparseRoot, '.rdd') }, sparsePort)
const sparseSparse = await fetchPage(sparseBase, '/hit-rate')
const sparseText = pageText(sparseSparse.html)
assertTrue(sparseSparse.status === 200 && sparseText.includes('暂无数据'), 'HTTP: hit-rate renders the placeholder branch without a log file')
assertTrue(sparseText.includes('尚未产生查询流水') || sparseText.includes('尚未积累流水'), 'HTTP: placeholder explains why the domain is empty')
const sparseOverview = pageText((await fetchPage(sparseBase, '/')).html)
assertTrue(sparseOverview.includes('稀疏数据域的单独需求'), 'HTTP: other domains stay healthy when one domain is unavailable')
const sparseTrees = pageText((await fetchPage(sparseBase, '/goal-trees')).html)
assertTrue(sparseTrees.includes('暂无真实交付树'), 'HTTP: empty delivery-tree domain renders its own three-part empty state')

// ── launcher + port conflict (AC 1 / AC 6) ─────────────────────────────
const rootLauncher = join(engineDir, '..', 'ops-dashboard.cmd')
for (const [label, launcherPath] of [['rdd-engine/scripts/dashboard.cmd', launcher], ['ops-dashboard.cmd', rootLauncher]]) {
  const launcherBytes = readFileSync(launcherPath)
  assertTrue([...launcherBytes].every((byte) => byte < 0x80), `launcher: ${label} is pure ASCII (cmd codepage safety)`)
  const bareLf = launcherBytes.reduce(
    (count, byte, index) => count + (byte === 10 && launcherBytes[index - 1] !== 13 ? 1 : 0),
    0
  )
  assertTrue(bareLf === 0, `launcher: ${label} uses CRLF line endings (cmd.exe mis-parses LF-only batch files)`, `bareLF=${bareLf}`)
}
const conflictPort = 8803
function runLauncher(port, label) {
  const outPath = join(tmpdir(), `rdd-dashboard-${label}-out.txt`)
  const errPath = join(tmpdir(), `rdd-dashboard-${label}-err.txt`)
  const outFd = openSync(outPath, 'w')
  const errFd = openSync(errPath, 'w')
  const child = spawn('cmd.exe', ['/c', launcher, '-Port', String(port)], {
    stdio: ['ignore', outFd, errFd],
    env: { ...process.env, RDD_PROJECT_ROOT: richRoot },
  })
  cleanups.push(() => {
    try {
      if (child.exitCode === null) spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
    } catch (error) {
      /* already gone */
    }
    try {
      closeSync(outFd)
      closeSync(errFd)
    } catch (error) {
      /* already closed */
    }
    try {
      rmSync(outPath, { force: true })
      rmSync(errPath, { force: true })
    } catch (error) {
      /* best effort */
    }
  })
  return { child, outPath, errPath, read: () => `${readFileSync(outPath, 'utf8')}${readFileSync(errPath, 'utf8')}` }
}

const first = runLauncher(conflictPort, 'first')
const announcementDeadline = Date.now() + 30000
let announcement = ''
while (Date.now() < announcementDeadline) {
  announcement = first.read()
  if (/https?:\/\/127\.0\.0\.1:\d+/.test(announcement)) break
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 300))
}
const announcedUrl = /https?:\/\/127\.0\.0\.1:(\d+)/.exec(announcement)
assertTrue(announcedUrl !== null, 'launcher: dashboard.cmd announces the URL on stdout', announcement.slice(0, 200))
if (announcedUrl !== null) {
  const launched = await fetchPage(`http://127.0.0.1:${announcedUrl[1]}`, '/')
  assertTrue(launched.status === 200 && pageText(launched.html).length > 200, 'launcher: announced URL serves the board', `status=${launched.status}`)
}

const second = runLauncher(conflictPort, 'second')
const conflictDeadline = Date.now() + 25000
while (second.child.exitCode === null && Date.now() < conflictDeadline) {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 300))
}
const conflictOutput = second.read()
const conflictExplicit = /端口|port|EADDRINUSE|占用|in use/i.test(conflictOutput) && /占用|EADDRINUSE|in use|处置/i.test(conflictOutput)
assertTrue(conflictExplicit, 'launcher: second instance reports the port conflict explicitly', `exit=${second.child.exitCode} out=${conflictOutput.slice(0, 160)}`)
assertTrue(second.child.exitCode !== 0, 'launcher: port conflict exits non-zero (never silent)', `exit=${second.child.exitCode}`)
const survivorsResponse = await fetch(`http://127.0.0.1:${conflictPort}/`)
assertTrue(survivorsResponse.status === 200, 'launcher: the first instance survives the conflict')

// ── real repository smoke (live truth, no fixed numbers) ───────────────
const repoRoot = resolve(engineDir, '..')
const liveContext = { projectRoot: repoRoot, rddRoot: join(repoRoot, '.rdd') }
const liveDomains = readAllDomains(liveContext)
const liveOverview = buildOverview(liveDomains)
assertTrue(liveDomains.requirements.data.totalCount > 0, 'live: archives readable in this repository')
assertTrue(liveOverview.fixture.excludedCount > 0 && liveOverview.fixture.realCount > 0, 'live: fixture exclusion active on the real repository', JSON.stringify(liveOverview.fixture))
assertTrue(liveDomains['goal-trees'].data.totalCount < liveDomains['goal-trees'].data.deliverNamedCount, 'live: real trees are fewer than the raw enumeration (fixtures excluded)')

for (const cleanup of cleanups.reverse()) {
  try {
    cleanup()
  } catch (error) {
    /* best effort */
  }
}

const failed = results.filter((entry) => !entry.ok)
console.log('')
console.log(`total: ${results.length}  failed: ${failed.length}`)
if (failed.length > 0) {
  for (const entry of failed) console.log(`  FAILED  ${entry.name}   ${entry.detail}`)
}
process.exit(failed.length > 0 ? 1 : 0)

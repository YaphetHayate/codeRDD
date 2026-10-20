// QA test-first probe — 探索缓存页 KPI 层级式展开交互 (requirement #1, archive
// 2026-10-20-exploration-cache-ux / exploration-entry-expansion.md).
// Feature: ops-dashboard-exploration-expansion.
//
// Two groups:
//   baseline (TC-005..TC-025) — pins the contracts the rework must NOT break:
//     SSR visibility of entries, KPI ground-truth counts, the frozen
//     /api/exploration data face, the read-only invariant over the fixture
//     root, and the empty-zone emptyState branch. These are green today.
//   pending (TC-030..TC-065) — the undelivered KPI-expansion behaviour,
//     skip-guarded: a delivered-probe looks for expansion wiring on the three
//     KPI tiles (条目总数 / 热区条目 / 持久条目). No wiring -> every pending
//     TC SKIPs as "待 DEV 交付"; the same command re-run after delivery
//     activates them automatically.
//
// Contracts bind behaviour, not implementation form: expansion semantics
// accept a union of affordances (<summary>/aria-expanded/role=button/<button>/
// data-* wiring/tabindex), zone scoping is proven by unique fixture tokens,
// the height bound is a two-sided HTML-container <-> CSS-rule contract, and
// wiring consistency cross-checks the data-* vocabulary against app.js.
//
// Noise policy: fixture registeredAt values are fixed ISO strings; nothing
// asserts per-request timestamps (generatedAt/data-at), so no normalization
// is needed. The double-read stability check compares fixture FILES, not
// response bytes.
//
// Run: node .rdd/tests/ops-dashboard-exploration-expansion/exploration-kpi-expansion-qa-verify.mjs
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { startServer } from '../../../rdd-engine/dashboard/server.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..')
const results = []
const cleanups = []

function pass(name) {
  results.push({ name, kind: 'PASS' })
  console.log(`PASS  ${name}`)
}
function fail(name, detail = '') {
  results.push({ name, kind: 'FAIL', detail })
  console.log(`FAIL  ${name}${detail ? `   ${detail}` : ''}`)
}
function skip(name, reason) {
  results.push({ name, kind: 'SKIP', detail: reason })
  console.log(`SKIP  ${name}   ${reason}`)
}
function check(condition, name, detail = '') {
  if (condition) pass(name)
  else fail(name, detail)
}

// ── fixture roots ────────────────────────────────────────────────────
const FIX = {
  hot: [
    {
      key: 'explkpi-hot-alpha',
      tags: ['explkpi-zone-hot', 'auth'],
      brief: '热区条目阿尔法摘要 explkpi-brief-ha',
      path: '.rdd/exploration/artifacts/explkpi-hot-alpha.md',
      files: { '.rdd/exploration/artifacts/explkpi-hot-alpha.md': 'sha256:aaaa' },
      registeredAt: '2026-10-20T01:00:00Z',
    },
    {
      key: 'explkpi-hot-beta',
      tags: ['explkpi-zone-hot'],
      brief: '热区条目贝塔摘要 explkpi-brief-hb',
      path: '.rdd/exploration/artifacts/explkpi-hot-beta.md',
      files: { '.rdd/exploration/artifacts/explkpi-hot-beta.md': 'sha256:bbbb' },
      registeredAt: '2026-10-20T02:00:00Z',
    },
  ],
  index: [
    {
      key: 'explkpi-persist-gamma',
      tags: ['explkpi-zone-persist'],
      brief: '持久条目伽马摘要 explkpi-brief-pg',
      path: '.rdd/exploration/artifacts/explkpi-persist-gamma.md',
      files: { '.rdd/exploration/artifacts/explkpi-persist-gamma.md': 'sha256:cccc' },
      registeredAt: '2026-10-20T03:00:00Z',
    },
    {
      key: 'explkpi-persist-delta',
      tags: ['explkpi-zone-persist'],
      brief: '持久条目德尔塔摘要 explkpi-brief-pd',
      path: '.rdd/exploration/artifacts/explkpi-persist-delta.md',
      files: { '.rdd/exploration/artifacts/explkpi-persist-delta.md': 'sha256:dddd' },
      registeredAt: '2026-10-20T04:00:00Z',
    },
  ],
}
const ALL_KEYS = [...FIX.hot, ...FIX.index].map((entry) => entry.key)
const HOT_KEYS = FIX.hot.map((entry) => entry.key)
const INDEX_KEYS = FIX.index.map((entry) => entry.key)
const LABEL_TOTAL = '条目总数'
const LABEL_HOT = '热区条目'
const LABEL_PERSIST = '持久条目'

function write(root, relativePath, content) {
  const absolute = join(root, relativePath)
  mkdirSync(dirname(absolute), { recursive: true })
  writeFileSync(absolute, content, 'utf8')
  return absolute
}

const richRoot = mkdtempSync(join(tmpdir(), 'rdd-expl-kpi-rich-'))
const emptyRoot = mkdtempSync(join(tmpdir(), 'rdd-expl-kpi-empty-'))
cleanups.push(() => rmSync(richRoot, { recursive: true, force: true }), () => rmSync(emptyRoot, { recursive: true, force: true }))

write(richRoot, '.rdd/exploration/hot.json', `${JSON.stringify({ entries: FIX.hot }, null, 2)}\n`)
write(richRoot, '.rdd/exploration/index.json', `${JSON.stringify({ entries: FIX.index }, null, 2)}\n`)
for (const entry of [...FIX.hot, ...FIX.index]) {
  const fileName = entry.key + '.md'
  write(richRoot, join('.rdd', 'exploration', 'artifacts', fileName), `# full record ${entry.key}\n`)
  write(richRoot, join('.rdd', 'exploration', 'artifacts', `${entry.key}.summary.md`), `summary ${entry.key}\n`)
}
write(emptyRoot, '.rdd/exploration/hot.json', `${JSON.stringify({ entries: [] }, null, 2)}\n`)

/** relpath -> [size, mtimeMs, sha256] for every file under root (read-only snapshot). */
function treeSnapshot(root) {
  const snap = new Map()
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const absolute = join(dir, name)
      const stat = statSync(absolute)
      if (stat.isDirectory()) walk(absolute)
      else {
        const bytes = readFileSync(absolute)
        snap.set(relative(root, absolute).replaceAll('\\', '/'), [
          stat.size,
          stat.mtimeMs,
          createHash('sha256').update(bytes).digest('hex'),
        ])
      }
    }
  }
  walk(root)
  return snap
}
const snapshotBefore = treeSnapshot(richRoot)

// ── real service over the fixture roots (in-process, ephemeral port) ──
function listen(context) {
  return new Promise((resolveReady, rejectReady) => {
    const server = startServer({ context, port: 0, quiet: true, onReady: () => resolveReady(server) })
    server.on('error', rejectReady)
    // async close: awaiting the close callback lets the libuv loop drain
    // before exit (process.exit() racing server.close() trips a libuv
    // assertion on Windows and corrupts the exit code).
    cleanups.push(() => new Promise((resolveClose) => server.close(() => resolveClose())))
  })
}
const richServer = await listen({ projectRoot: richRoot, rddRoot: join(richRoot, '.rdd') })
const base = `http://127.0.0.1:${richServer.address().port}`
const emptyServer = await listen({ projectRoot: emptyRoot, rddRoot: join(emptyRoot, '.rdd') })
const emptyBase = `http://127.0.0.1:${emptyServer.address().port}`

const getPage = async (origin, path) => {
  const response = await fetch(origin + path)
  return { status: response.status, body: await response.text() }
}

const exploration = await getPage(base, '/exploration')
const html = exploration.body
const scriptStripped = html.replace(/<script[\s\S]*?<\/script>/g, ' ')
const apiExploration = await (await fetch(`${base}/api/exploration`)).json()
const appJs = await (await fetch(`${base}/static/app.js`)).text()
const styleCss = await (await fetch(`${base}/static/style.css`)).text()

// ═══ baseline group (green today; pins what the rework must keep) ═══
// TC-005 (AC-5): SSR baseline — entry info survives in raw markup without JS.
const visibleKeys = ALL_KEYS.filter((key) => scriptStripped.includes(key))
check(
  visibleKeys.length === ALL_KEYS.length && [...FIX.hot, ...FIX.index].every((entry) => scriptStripped.includes(entry.brief)),
  'TC-005 baseline: raw SSR markup carries every fixture key and brief (no-JS visibility face)',
  `missing keys: ${ALL_KEYS.filter((key) => !scriptStripped.includes(key)).join(',') || 'none'}`
)

// TC-010 (AC-1/AC-2 count side): KPI tiles carry the fixture ground truth.
const bounded = (window, number) => new RegExp(`(^|[>\\s])${number}([<\\s]|$)`).test(window.replace(/<[^>]+>/g, ' '))
const tileWindow = (label) => {
  const at = html.indexOf(label)
  return at < 0 ? null : html.slice(Math.max(0, at - 600), at + 200)
}
const totalWindow = tileWindow(LABEL_TOTAL)
const hotWindow = tileWindow(LABEL_HOT)
const persistWindow = tileWindow(LABEL_PERSIST)
check(
  exploration.status === 200 && totalWindow !== null && bounded(totalWindow, 4),
  'TC-010 baseline: /exploration 200 and 「条目总数」 tile shows ground truth 4',
  `status=${exploration.status} totalWindow=${totalWindow === null ? 'missing' : 'ok'}`
)
check(
  hotWindow !== null && bounded(hotWindow, 2) && persistWindow !== null && bounded(persistWindow, 2),
  'TC-010 baseline: 「热区条目」/「持久条目」 tiles show ground truth 2/2'
)

// TC-015 (整体判据 #2 / 影响范围): frozen /api/exploration data face.
const readerEntryFields = ['zone', 'key', 'tags', 'brief', 'path', 'fileCount', 'registeredAt']
const apiOk =
  exploration.status === 200 &&
  apiExploration.domain === 'exploration' &&
  apiExploration.available === true &&
  typeof apiExploration.meta?.generatedAt === 'string'
check(apiOk, 'TC-015 baseline: /api/exploration envelope {domain,available,meta,data} contract', JSON.stringify(Object.keys(apiExploration)))
check(
  apiExploration.data?.hotCount === 2 && apiExploration.data?.indexCount === 2 && apiExploration.data?.totalCount === 4 && apiExploration.data?.entries?.length === 4,
  'TC-015 baseline: API counts match fixture ground truth (hot 2 / index 2 / total 4)',
  JSON.stringify({ hot: apiExploration.data?.hotCount, index: apiExploration.data?.indexCount, total: apiExploration.data?.totalCount })
)
check(
  apiExploration.data?.artifacts?.count === 4 && apiExploration.data?.artifacts?.pairedCount === 4 && apiExploration.data?.zones?.hotPresent === true && apiExploration.data?.zones?.indexPresent === true,
  'TC-015 baseline: artifacts 4/4 paired and both zones present (reader 数据面不变)'
)
check(
  apiExploration.data?.entries?.every((entry) => Object.keys(entry).join(',') === readerEntryFields.join(',')) === true,
  'TC-015 baseline: entry field set frozen to the reader contract',
  JSON.stringify(apiExploration.data?.entries?.[0] && Object.keys(apiExploration.data.entries[0]))
)

// TC-025 (EC-1): empty zone keeps the existing emptyState branch.
const emptyPage = await getPage(emptyBase, '/exploration')
const emptyApi = await (await fetch(`${emptyBase}/api/exploration`)).json()
check(
  emptyPage.status === 200 && /暂无/.test(emptyPage.body) && !/Unhandled|stack trace|Internal Server Error/.test(emptyPage.body),
  'TC-025 baseline: empty exploration root renders the existing empty state without crashing',
  `status=${emptyPage.status}`
)
check(
  emptyApi.available === false && emptyApi.data?.hotCount === 0 && emptyApi.data?.indexCount === 0 && emptyApi.data?.totalCount === 0,
  'TC-025 baseline: empty root reports available=false with zero counts on the API face'
)

// TC-020 (整体判据 #2): read-only invariant — the whole read flow must not
// touch the fixture .rdd tree (content, size or mtime).
await getPage(base, '/exploration') // second read: stability + read-path coverage
const snapshotAfter = treeSnapshot(richRoot)
const drift = []
for (const [file, before] of snapshotBefore) {
  const after = snapshotAfter.get(file)
  if (after === undefined || after[0] !== before[0] || after[1] !== before[1] || after[2] !== before[2]) drift.push(file)
}
for (const file of snapshotAfter.keys()) if (!snapshotBefore.has(file)) drift.push(file)
check(drift.length === 0, 'TC-020 baseline: read interactions leave the fixture .rdd tree byte-identical (zero write)', `drift=${drift.join(',') || 'none'}`)

// ═══ delivered-probe: is the KPI expansion wiring present at all? ═══
const WIRING_RE = /<summary[\s>]|aria-expanded|role="(button|switch)"|<button[\s>]|data-(toggle|expand|expander|kpi|collapse|target|open|detail)|tabindex=/
const wiringWindows = [
  totalWindow !== null ? { label: LABEL_TOTAL, window: totalWindow } : null,
  hotWindow !== null ? { label: LABEL_HOT, window: hotWindow } : null,
  persistWindow !== null ? { label: LABEL_PERSIST, window: persistWindow } : null,
].filter(Boolean)
const wiredTiles = wiringWindows.filter((tile) => WIRING_RE.test(tile.window))
console.log(`INFO  delivered-probe: expansion wiring markers found on ${wiredTiles.length}/3 KPI tiles`)
const DELIVERED = wiredTiles.length === 3

// Region model v2 (verification round; instrument fix per tip
// 20261020T124430Z-QA-2dda): the delivered layout associates tiles and
// expansion panels by an id/data-kpi vocabulary — tile id="kpi-{zone}"
// data-kpi="{zone}" ↔ panel <section class="kpi-expansion" id="exp-{zone}"
// aria-labelledby="kpi-{zone}" hidden — with the three panels DOM-ordered
// AFTER the whole KPI row, not positionally interleaved between tiles. A
// panel region runs from its opening tag to the next <section. Label-window
// regions stay as the form-agnostic fallback when the vocabulary is absent.
// The requirement pins behaviour (zone-scoped detail reachable from the
// KPI), not DOM adjacency, so locating via the delivered association
// vocabulary is a locator fix, not a baseline weakening.
const ZONES = [
  { zone: 'total', label: LABEL_TOTAL, nextLabels: [LABEL_HOT] },
  { zone: 'hot', label: LABEL_HOT, nextLabels: [LABEL_PERSIST] },
  { zone: 'index', label: LABEL_PERSIST, nextLabels: [] },
]
function panelRegion(zone) {
  const open = html.search(new RegExp(`<(section|div)[^>]*id="exp-${zone}"`))
  if (open < 0) return null
  const next = html.indexOf('<section', open + 10)
  return html.slice(open, next < 0 ? html.length : next)
}
function labelRegion(info) {
  const anchors = info.nextLabels.length > 0 ? info.nextLabels : ['<section']
  const at = html.indexOf(info.label)
  if (at < 0) return null
  let end = html.length
  for (const anchor of anchors) {
    const found = html.indexOf(anchor, at + info.label.length)
    if (found >= 0 && found < end) end = found
  }
  return html.slice(at, end)
}
const keysPresent = (text, keys) => keys.filter((key) => text.includes(key))
const regions = ZONES.map((info) => panelRegion(info.zone) ?? labelRegion(info))
const [regionTotal, regionHot, regionPersist] = regions

if (!DELIVERED) {
  const reason = '待 DEV 交付：三个 KPI tile 均未探测到展开接线语义（<summary>/aria-expanded/role=button/<button>/data-* 接线/tabindex 并集）'
  for (const id of ['TC-030', 'TC-035', 'TC-040', 'TC-045', 'TC-050', 'TC-055', 'TC-060', 'TC-065', 'TC-070']) skip(id, reason)
} else {
  // TC-070 (AC-1/AC-2 linkage): the tile ↔ panel association must be complete
  // on all four anchors — a broken linkage is a dead expansion.
  const linkage = ZONES.map((info) => {
    const panel = panelRegion(info.zone)
    return (
      html.includes(`id="kpi-${info.zone}"`) &&
      html.includes(`data-kpi="${info.zone}"`) &&
      html.includes(`id="exp-${info.zone}"`) &&
      panel !== null &&
      panel.slice(0, 400).includes(`aria-labelledby="kpi-${info.zone}"`)
    )
  })
  check(linkage.every(Boolean), 'TC-070: tile↔panel linkage complete for all three zones (id/data-kpi/aria-labelledby/exp-id)', `ok=${linkage.filter(Boolean).length}/3`)
  // TC-030 (AC-1): 「条目总数」 is the merged entry list — count == rows.
  check(
    regionTotal !== null && keysPresent(regionTotal, ALL_KEYS).length === ALL_KEYS.length,
    'TC-030: 「条目总数」 expansion region carries all 4 merged entries (双 zone 合并)',
    `found=${regionTotal === null ? 'region missing' : keysPresent(regionTotal, ALL_KEYS).join(',')}`
  )
  const rowsTotal = regionTotal === null ? 0 : ALL_KEYS.filter((key) => regionTotal.includes(key)).length
  check(rowsTotal === 4, 'TC-030: merged detail row count matches the total KPI count (计数与明细行数一致)', `rows=${rowsTotal}`)

  // TC-035 (AC-2): zone-filtered regions contain only their own zone.
  const hotInHot = regionHot === null ? [] : keysPresent(regionHot, HOT_KEYS)
  const indexInHot = regionHot === null ? [] : keysPresent(regionHot, INDEX_KEYS)
  check(
    hotInHot.length === 2 && indexInHot.length === 0,
    'TC-035: 「热区条目」 expansion contains exactly the 2 hot entries and no persisted ones',
    `hot=${hotInHot.join(',')} leaked-index=${indexInHot.join(',') || 'none'}`
  )
  const indexInPersist = regionPersist === null ? [] : keysPresent(regionPersist, INDEX_KEYS)
  const hotInPersist = regionPersist === null ? [] : keysPresent(regionPersist, HOT_KEYS)
  check(
    indexInPersist.length === 2 && hotInPersist.length === 0,
    'TC-035: 「持久条目」 expansion contains exactly the 2 persisted entries and no hot ones',
    `persist=${indexInPersist.join(',')} leaked-hot=${hotInPersist.join(',') || 'none'}`
  )

  // TC-040 (AC-1 collapse half): the collapse state machinery. Design D7 keeps
  // the SSR tiles pure-display (aria/tabindex are JS-upgraded at runtime), so
  // the SSR-visible state contract is: default-collapsed panels (hidden) +
  // per-panel collapse control (exp-head role=button) + the JS state upgrade
  // present in app.js. A raw-tile window scan for aria-expanded would measure
  // the no-JS degradation face, which AC-5 deliberately allows to be flat.
  const collapseReady = ZONES.map((info) => {
    const panel = panelRegion(info.zone)
    if (panel === null) return false
    const opening = panel.slice(0, panel.indexOf('>') + 1)
    return /\bhidden\b/.test(opening) && /role="button"/.test(panel.slice(0, 600))
  })
  check(
    collapseReady.every(Boolean) && appJs.includes('aria-expanded'),
    'TC-040: all three panels ship default-collapsed (hidden) with a collapse control, and app.js carries the aria state upgrade',
    `panels=${collapseReady.filter(Boolean).length}/3 js-aria=${appJs.includes('aria-expanded')}`
  )

  // TC-045 (AC-3): per-entry second-level expansion + full fields on the SSR face.
  const perEntryAffordance = ALL_KEYS.filter((key) => {
    const at = html.indexOf(key)
    return at >= 0 && WIRING_RE.test(html.slice(Math.max(0, at - 400), at + 400))
  })
  check(
    perEntryAffordance.length === 4,
    'TC-045: every entry row carries its own expansion affordance',
    `affordable=${perEntryAffordance.length}/4`
  )
  const fieldsVisible = [...FIX.hot, ...FIX.index].every(
    (entry) =>
      scriptStripped.includes(entry.brief) &&
      scriptStripped.includes(entry.path) &&
      scriptStripped.includes(entry.key) &&
      entry.tags.every((tag) => scriptStripped.includes(tag)) &&
      /2026-10-20/.test(scriptStripped)
  )
  check(fieldsVisible, 'TC-045: full entry fields (key/brief/tags/path/注册时间) visible on the SSR face for every fixture entry')

  // TC-050 (AC-3): copyable path + jump control per entry. Association is by
  // the entry's unique record filename inside the carrier value — stronger
  // than a positional window (the delivered detail row sits well past the
  // row's key cell). Any scheme (vscode://, file://, plain path) qualifies;
  // the requirement defers the protocol form to UX/DEV.
  const copyOkCount = [...FIX.hot, ...FIX.index].filter((entry) => new RegExp(`data-copy="[^"]*${entry.key}\\.md"`).test(html)).length
  const jumpOkCount = [...FIX.hot, ...FIX.index].filter((entry) => new RegExp(`(href|data-href)="[^"]*${entry.key}\\.md"`).test(html)).length
  check(copyOkCount === 4, 'TC-050: every entry exposes a machine-readable copy carrier for its exact record path', `copy=${copyOkCount}/4`)
  check(jumpOkCount === 4, 'TC-050: every entry exposes a jump control whose target references its record file', `jump=${jumpOkCount}/4`)

  // TC-055 (AC-4): bounded height — any class used inside the expansion
  // regions must carry a CSS max-height + internal-scroll rule. The delivery
  // reuses the pre-existing .table-wrap 560px bound, so a semantic-name
  // filter would miss it; scan every class token instead.
  const containerClasses = new Set()
  for (const region of regions) {
    if (region === null) continue
    for (const match of region.matchAll(/class="([^"]+)"/g)) {
      for (const cls of match[1].split(/\s+/)) containerClasses.add(cls)
    }
  }
  const boundedClasses = [...containerClasses].filter((cls) => {
    for (const rule of styleCss.matchAll(new RegExp(`\\.${cls.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{[^}]*\\}`, 'g'))) {
      const body = rule[0]
      if (/max-height/.test(body) && /overflow(-y)?\s*:\s*(auto|scroll)/.test(body)) return true
    }
    return false
  })
  check(
    boundedClasses.length > 0,
    'TC-055: at least one class inside the expansion regions is CSS-bounded (max-height + internal scroll)',
    `bounded=[${boundedClasses.join(',')}]`
  )

  // TC-060: wiring consistency — no orphan data-* vocabulary in the KPI
  // regions. Native <details> needs no JS, so an empty new-vocabulary set
  // passes; any vocabulary the HTML introduces must be consumed by app.js.
  const LEGACY_DATA_ATTRS = new Set([
    'data-theme', 'data-at', 'data-bound', 'data-copy', 'data-href', 'data-query', 'data-tone',
    'data-selected', 'data-config-field', 'data-config-type', 'data-cross-module', 'data-original',
    'data-ux-agent', 'data-ux-field', 'data-filter-value', 'data-tone-info',
  ])
  const newVocab = new Set()
  for (const source of [...regions, ...wiringWindows.map((tile) => tile.window)]) {
    if (source === null || source === undefined) continue
    for (const match of source.matchAll(/data-([a-z0-9-]+)=/g)) {
      const name = `data-${match[1]}`
      if (!LEGACY_DATA_ATTRS.has(name)) newVocab.add(name)
    }
  }
  const orphans = [...newVocab].filter((name) => !appJs.includes(name))
  check(
    orphans.length === 0,
    'TC-060: every expansion data-* wiring token in the HTML is referenced by app.js (no dead wiring)',
    `vocab=[${[...newVocab].join(',')}] orphans=[${orphans.join(',')}]`
  )

  // TC-065 (AC-4): the rework keeps the page skeleton and sibling panels.
  check(
    /^<!DOCTYPE html/.test(html.trim()) &&
      html.includes('id="ops-main"') &&
      /rel="stylesheet"/.test(html) &&
      /src="[^"]*app\.js"/.test(html),
    'TC-065: page skeleton contract intact after the KPI rework (DOCTYPE/main/stylesheet/app.js)'
  )
  check(
    /tag 分布/.test(html) && /注册时间线/.test(html),
    'TC-065: sibling panels (tag 分布 / 注册时间线) survive the layout merge'
  )
}

// ── summary ──────────────────────────────────────────────────────────
const total = results.length
const passed = results.filter((item) => item.kind === 'PASS').length
const failed = results.filter((item) => item.kind === 'FAIL').length
const skipped = results.filter((item) => item.kind === 'SKIP').length
console.log(`\nSUMMARY total=${total} pass=${passed} fail=${failed} skip=${skipped}`)
process.exitCode = failed > 0 ? 1 : 0
for (const cleanup of cleanups) {
  try {
    await cleanup()
  } catch {
    /* closing an already-closed server is fine */
  }
}

// QA test-first probe — artifact/summary 合并产物条目与状态可观测 (requirement #2,
// archive 2026-10-20-exploration-cache-ux / requirements/artifact-pair-observability.md).
// Feature: ops-dashboard-exploration-pair-observability.
//
// Two groups:
//   baseline (TC-105..TC-130) — pins the pair-count semantics the merge must
//     keep: the N-records / M-paired ground truth on a mixed fixture (2
//     orphans, 1 record without summary, 1 lone summary), the read-only
//     invariant, the frozen envelope face, the existing missing-summary note
//     wording, and two boundary faces (lone summary; entries without any
//     artifacts directory). Green today; must stay green after the merge.
//   pending (TC-135..TC-175) — the undelivered pair-observability behaviour,
//     skip-guarded: a delivered-probe looks for expansion wiring on the
//     in-body KPI prefix (topbar excluded) OR wiring near the
//     only-after-delivery markers (「无条目」 status / 「文件时间」 annotation)
//     OR wiring around the orphan slugs. No delivery -> every pending TC
//     SKIPs as "待 DEV 交付"; the same command re-run after delivery
//     activates them automatically.
//
// Requirement-anchored semantics (behaviour, not implementation form):
//   freshness = every entry.files path re-hashes to its recorded
//   "sha256:<lowercase-hex>" value AND the record path exists — the same
//   semantics as rdd-engine/scripts/explore-store.ps1 Test-EntryFresh; stale
//   items must name the changed/missing files. Orphans (artifact files with
//   no cache entry) appear in the pair list marked 「无条目」. Time face: hot
//   entries show registeredAt; persisted entries and orphans show the
//   artifact file mtime annotated 「文件时间（近似）」 (D3). Pair expansion is
//   accepted as a union of affordances (same wiring union as feature #1's
//   probe), copy carriers accept the three known forms, and the height bound
//   is a two-sided container <-> CSS contract.
//
// Noise policy: registeredAt values are fixed ISO strings; artifact mtimes
// are pinned with utimesSync to fixed instants at 10:00Z (same calendar date
// across UTC-9..UTC+13), so date-only assertions carry no clock noise.
// Nothing asserts per-request timestamps (generatedAt/meta), so no
// normalization is needed (tip 20261009T062058Z-QA-9f26: never pin envelope
// timestamps — pretty/compact trap).
//
// Run: node .rdd/tests/ops-dashboard-exploration-pair-observability/exploration-pair-observability-qa-verify.mjs
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
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

// ── fixture slugs & ground truth ─────────────────────────────────────
const SLUG_FRESH = 'explpair-hot-fresh' // hot entry, all files match + record exists -> FRESH
const SLUG_STALE = 'explpair-hot-stale' // hot entry, covered file content rewritten -> hash mismatch
const SLUG_MISSING = 'explpair-persist-missing' // persisted entry, covered path absent -> missing
const SLUG_ORPHAN = 'explpair-orphan' // artifact pair with NO cache entry
const SLUG_NOSUMMARY = 'explpair-nosummary' // artifact record without summary, NO cache entry
const LONE_SUMMARY = 'explpair-lonely' // summary file without its record (anomaly, not a record)
const PAIR_SLUGS = [SLUG_FRESH, SLUG_STALE, SLUG_MISSING, SLUG_ORPHAN, SLUG_NOSUMMARY]
const ORPHAN_SLUGS = [SLUG_ORPHAN, SLUG_NOSUMMARY]

const SRC_FRESH_A = 'src/explpair/auth.ts' // real file, hash matches -> fresh
const SRC_FRESH_B = 'src/explpair/session.ts' // real file, hash matches -> fresh
const SRC_STALE = 'src/explpair/login.ts' // hashed as v1, rewritten as v2 -> changed
const SRC_GHOST = 'src/explpair/ghost.ts' // never written -> missing

const T_HOT_FRESH_AT = '2026-10-20T01:00:00Z' // hot: rendered face must be registeredAt
const T_HOT_STALE_AT = '2026-10-20T02:00:00Z'
const T_PERSIST_AT = '2025-12-31T23:00:00Z' // distinct from every mtime date on purpose
const M_PERSIST = '2026-03-04' // utimes-pinned mtime date (10:00Z)
const M_ORPHAN = '2026-05-06'
const M_NOSUMMARY = '2026-07-08'

// Ground truth: 3 cache entries (hot 2 + index 1); 5 artifact records; 4
// paired summaries; 2 orphans; 1 record missing its summary; 1 lone summary.
const GT_ENTRIES = 3
const GT_HOT = 2
const GT_INDEX = 1
const GT_RECORDS = 5
const GT_PAIRED = 4

const ART = (slug, suffix = '') => `.rdd/exploration/artifacts/${slug}${suffix}.md`
const sha256Of = (text) => `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`
const CONTENT_LOGIN_V1 = 'export const explpairLoginV1 = 1\n'
const CONTENT_LOGIN_V2 = 'export const explpairLoginV2 = 2\n'
const HASH_FRESH_A = sha256Of('export const explpairAuth = "alpha"\n')
const HASH_FRESH_B = sha256Of('export const explpairSession = "beta"\n')
const HASH_LOGIN_V1 = sha256Of(CONTENT_LOGIN_V1)
const HASH_GHOST = sha256Of('ghost file, never written')

const FIX = {
  hot: [
    {
      key: SLUG_FRESH,
      tags: ['explpair-zone-hot', 'auth'],
      brief: '热区新鲜条目摘要 explpair-brief-fresh',
      path: ART(SLUG_FRESH),
      files: { [SRC_FRESH_A]: HASH_FRESH_A, [SRC_FRESH_B]: HASH_FRESH_B },
      registeredAt: T_HOT_FRESH_AT,
    },
    {
      key: SLUG_STALE,
      tags: ['explpair-zone-hot'],
      brief: '热区已失效条目摘要 explpair-brief-stale',
      path: ART(SLUG_STALE),
      files: { [SRC_STALE]: HASH_LOGIN_V1 },
      registeredAt: T_HOT_STALE_AT,
    },
  ],
  index: [
    {
      key: SLUG_MISSING,
      tags: ['explpair-zone-persist'],
      brief: '持久缺文件条目摘要 explpair-brief-missing',
      path: ART(SLUG_MISSING),
      files: { [SRC_GHOST]: HASH_GHOST },
      registeredAt: T_PERSIST_AT,
    },
  ],
}

function write(root, relativePath, content) {
  const absolute = join(root, relativePath)
  mkdirSync(dirname(absolute), { recursive: true })
  writeFileSync(absolute, content, 'utf8')
  return absolute
}
const pinMtime = (root, relativePath, iso) => utimesSync(join(root, relativePath), new Date(iso), new Date(iso))

const richRoot = mkdtempSync(join(tmpdir(), 'rdd-expl-pair-rich-'))
const bareRoot = mkdtempSync(join(tmpdir(), 'rdd-expl-pair-bare-'))
const loneRoot = mkdtempSync(join(tmpdir(), 'rdd-expl-pair-lone-'))
cleanups.push(
  () => rmSync(richRoot, { recursive: true, force: true }),
  () => rmSync(bareRoot, { recursive: true, force: true }),
  () => rmSync(loneRoot, { recursive: true, force: true })
)

// rich root: mixed pairing world (fresh / stale / missing / orphan / no-summary / lone summary)
write(richRoot, '.rdd/exploration/hot.json', `${JSON.stringify({ entries: FIX.hot }, null, 2)}\n`)
write(richRoot, '.rdd/exploration/index.json', `${JSON.stringify({ entries: FIX.index }, null, 2)}\n`)
for (const slug of [SLUG_FRESH, SLUG_STALE, SLUG_MISSING, SLUG_ORPHAN]) {
  write(richRoot, ART(slug), `# full record ${slug}\n`)
  write(richRoot, ART(slug, '.summary'), `summary ${slug}\n`)
}
write(richRoot, ART(SLUG_NOSUMMARY), `# full record ${SLUG_NOSUMMARY} (no summary)\n`)
write(richRoot, ART(LONE_SUMMARY, '.summary'), `summary without record ${LONE_SUMMARY}\n`)
write(richRoot, SRC_FRESH_A, 'export const explpairAuth = "alpha"\n')
write(richRoot, SRC_FRESH_B, 'export const explpairSession = "beta"\n')
write(richRoot, SRC_STALE, CONTENT_LOGIN_V1) // hashed as v1 in the fixture entry...
write(richRoot, SRC_STALE, CONTENT_LOGIN_V2) // ...then rewritten -> dashboard must see it as changed
for (const [file, iso] of [
  [ART(SLUG_MISSING), `${M_PERSIST}T10:00:00Z`],
  [ART(SLUG_MISSING, '.summary'), `${M_PERSIST}T10:00:00Z`],
  [ART(SLUG_ORPHAN), `${M_ORPHAN}T10:00:00Z`],
  [ART(SLUG_ORPHAN, '.summary'), `${M_ORPHAN}T10:00:00Z`],
  [ART(SLUG_NOSUMMARY), `${M_NOSUMMARY}T10:00:00Z`],
]) {
  pinMtime(richRoot, file, iso)
}

// bare root: entries exist but the artifacts directory is absent entirely
write(bareRoot, '.rdd/exploration/hot.json', `${JSON.stringify({ entries: [{ key: 'explpair-bare', tags: [], brief: '裸根条目', path: ART('explpair-bare'), files: {}, registeredAt: '2026-01-02T03:04:05Z' }] }, null, 2)}\n`)

// lone root: only a summary file without its record lives in artifacts/
write(loneRoot, '.rdd/exploration/hot.json', `${JSON.stringify({ entries: [{ key: 'explpair-lonely-host', tags: [], brief: '孤儿 summary 宿主', path: ART('explpair-lonely-host'), files: {}, registeredAt: '2026-01-02T03:04:05Z' }] }, null, 2)}\n`)
write(loneRoot, ART(LONE_SUMMARY, '.summary'), `summary without record ${LONE_SUMMARY}\n`)

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
const snapRichBefore = treeSnapshot(richRoot)
const snapBareBefore = treeSnapshot(bareRoot)
const snapLoneBefore = treeSnapshot(loneRoot)

// ── real service over the fixture roots (in-process, ephemeral port) ──
function listen(context) {
  return new Promise((resolveReady, rejectReady) => {
    const server = startServer({ context, port: 0, quiet: true, onReady: () => resolveReady(server) })
    server.on('error', rejectReady)
    // async close: awaiting the close callback lets the libuv loop drain
    // before exit (process.exit() racing server.close() trips a libuv
    // assertion on Windows and corrupts the exit code — cf. n3 probe).
    cleanups.push(() => new Promise((resolveClose) => server.close(() => resolveClose())))
  })
}
const richServer = await listen({ projectRoot: richRoot, rddRoot: join(richRoot, '.rdd') })
const base = `http://127.0.0.1:${richServer.address().port}`
const bareServer = await listen({ projectRoot: bareRoot, rddRoot: join(bareRoot, '.rdd') })
const bareBase = `http://127.0.0.1:${bareServer.address().port}`
const loneServer = await listen({ projectRoot: loneRoot, rddRoot: join(loneRoot, '.rdd') })
const loneBase = `http://127.0.0.1:${loneServer.address().port}`

const getPage = async (origin, path) => {
  const response = await fetch(origin + path)
  return { status: response.status, body: await response.text() }
}

const t0 = performance.now()
const exploration = await getPage(base, '/exploration')
const elapsedMs = Math.round(performance.now() - t0)
const html = exploration.body
const scriptStripped = html.replace(/<script[\s\S]*?<\/script>/g, ' ')
const apiExploration = await (await fetch(`${base}/api/exploration`)).json()
const appJs = await (await fetch(`${base}/static/app.js`)).text()
const styleCss = await (await fetch(`${base}/static/style.css`)).text()
await getPage(base, '/exploration') // second read: stability + read-path coverage
const barePage = await getPage(bareBase, '/exploration')
const bareApi = await (await fetch(`${bareBase}/api/exploration`)).json()
const lonePage = await getPage(loneBase, '/exploration')
const loneApi = await (await fetch(`${loneBase}/api/exploration`)).json()
console.log(`INFO  per-request /exploration render took ~${elapsedMs}ms on the mixed fixture (watch item only — per-request SHA-256 cost口径由 UX/DEV 定，不做硬断言)`)

// ═══ helpers ═══
/** tag-stripped digit-boundary check (prevents "15 contains 5" false hits). */
const bounded = (window, number) => new RegExp(`(^|[>\\s])${number}([<\\s]|$)`).test(window.replace(/<[^>]+>/g, ' '))
const escapeRe = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
/** all occurrence indices of a token in a text */
function occurrences(text, token) {
  const found = []
  let at = text.indexOf(token)
  while (at >= 0) {
    found.push(at)
    at = text.indexOf(token, at + token.length)
  }
  return found
}
/** symmetric windows around every occurrence of slug; pred wins if ANY window passes */
function anyWin(text, slug, pred, pad = 700) {
  return occurrences(text, slug).some((at) => pred(text.slice(Math.max(0, at - pad), at + slug.length + pad)))
}
/** copy-carrier union for one exact path (data-copy= / <code>…path / >path<) */
function hasCopyCarrier(window, path) {
  return (
    window.includes(`data-copy="${path}"`) ||
    new RegExp(`<code>[^<]*${escapeRe(path)}`).test(window) ||
    window.includes(`>${path}<`)
  )
}

const WIRING_RE = /<summary[\s>]|aria-expanded|role="(button|switch)"|<button[\s>]|data-(toggle|expand|expander|kpi|collapse|target|open|detail)|tabindex=/
const STATUS_FRESH_RE = /(仍?新鲜|fresh|有效|健康|正常)/i
const STATUS_STALE_RE = /(不新鲜|失效|过期|已变更|变更|漂移|drift|stale|警告|warn|error|异常)/i
const STATUS_MISSING_RE = /(缺失|不存在|丢失|missing|消失|error|失效)/i
const TIME_APPROX_RE = /(文件时间|近似)/
const ORPHAN_MARK_RE = /(?<!暂)无条目/
const MARKER_RE = /(?<!暂)无条目|文件时间|近似/g

// ═══ baseline group (green today; pins what the merge must keep) ═══
// TC-105 (AC-1 count side): the N-records / M-paired ground truth stays on
// the KPI face — pre-merge as two tiles, post-merge as the single pair tile.
// Region model: the in-body prefix from ops-main to the first content
// <section>. The topbar's switcher <section> sits BEFORE ops-main, so a naive
// "everything before the first <section>" would truncate inside the topbar
// and never see the tiles (dry-run lesson, fixed same round).
const mainAt = html.indexOf('id="ops-main"')
const tilesRegion = mainAt >= 0 ? html.slice(mainAt, Math.max(mainAt, html.indexOf('<section', mainAt))) : ''
check(
  exploration.status === 200 && bounded(tilesRegion, GT_RECORDS),
  `TC-105 baseline: /exploration 200 and the KPI face carries artifact-record ground truth ${GT_RECORDS}`,
  `status=${exploration.status}`
)
check(
  bounded(tilesRegion, GT_PAIRED),
  `TC-105 baseline: the KPI face carries paired-summary ground truth ${GT_PAIRED} (口径不变：混合夹具含 2 孤儿 + 1 缺 summary)`
)

// TC-110 (整体判据 #2 / AC-7): read-only invariant — the whole read flow must
// not touch any fixture tree (content, size or mtime).
const driftOf = (root, before) => {
  const after = treeSnapshot(root)
  const drift = []
  for (const [file, was] of before) {
    const now = after.get(file)
    if (now === undefined || now[0] !== was[0] || now[1] !== was[1] || now[2] !== was[2]) drift.push(file)
  }
  for (const file of after.keys()) if (!before.has(file)) drift.push(file)
  return drift
}
const driftRich = driftOf(richRoot, snapRichBefore)
const driftBare = driftOf(bareRoot, snapBareBefore)
const driftLone = driftOf(loneRoot, snapLoneBefore)
check(
  driftRich.length === 0 && driftBare.length === 0 && driftLone.length === 0,
  'TC-110 baseline: all read interactions leave every fixture tree byte-identical (size+mtime+SHA256 zero-write)',
  `drift rich=[${driftRich.join(',')}] bare=[${driftBare.join(',')}] lone=[${driftLone.join(',')}]`
)

// TC-115 (整体判据 #2 / AC-7): frozen /api/exploration face on the mixed fixture.
check(
  apiExploration.domain === 'exploration' &&
    apiExploration.available === true &&
    typeof apiExploration.meta?.generatedAt === 'string' &&
    apiExploration.data?.hotCount === GT_HOT &&
    apiExploration.data?.indexCount === GT_INDEX &&
    apiExploration.data?.totalCount === GT_ENTRIES &&
    apiExploration.data?.entries?.length === GT_ENTRIES &&
    apiExploration.data?.artifacts?.count === GT_RECORDS &&
    apiExploration.data?.artifacts?.pairedCount === GT_PAIRED &&
    apiExploration.data?.zones?.hotPresent === true &&
    apiExploration.data?.zones?.indexPresent === true,
  `TC-115 baseline: envelope + counts frozen (hot ${GT_HOT} / index ${GT_INDEX} / total ${GT_ENTRIES} / artifacts ${GT_RECORDS}/${GT_PAIRED} / zones present)`,
  JSON.stringify({ hot: apiExploration.data?.hotCount, index: apiExploration.data?.indexCount, artifacts: apiExploration.data?.artifacts })
)

// TC-120 (EC-2): summary-missing keeps the existing note wording.
const notes = (apiExploration.meta?.notes ?? []).join('\n')
check(
  /缺少配对 summary/.test(notes),
  'TC-120 baseline: missing-summary keeps the existing meta.notes wording (「…缺少配对 summary」)',
  JSON.stringify(apiExploration.meta?.notes ?? [])
)

// TC-125 (EC-3): a lone summary (summary without its record) is not counted
// and does not break the page.
check(
  lonePage.status === 200 && !/Unhandled|Internal Server Error/.test(lonePage.body),
  'TC-125 baseline: lone-summary root renders 200 without crashing',
  `status=${lonePage.status}`
)
check(
  loneApi.data?.artifacts?.count === 0 && loneApi.data?.artifacts?.pairedCount === 0,
  'TC-125 baseline: lone summary enters neither the record count nor the paired count (0/0)',
  JSON.stringify(loneApi.data?.artifacts)
)

// TC-130 (EC-4): entries present but artifacts/ directory missing -> pair face
// degrades to 0/0 without crashing.
check(
  barePage.status === 200 && !/Unhandled|Internal Server Error/.test(barePage.body),
  'TC-130 baseline: entries-without-artifacts-dir renders 200 without crashing',
  `status=${barePage.status}`
)
check(
  bareApi.available === true && bareApi.data?.artifacts?.count === 0 && bareApi.data?.artifacts?.pairedCount === 0,
  'TC-130 baseline: API face reports available=true (entries exist) with a 0/0 pair face',
  JSON.stringify({ available: bareApi.available, artifacts: bareApi.data?.artifacts })
)

// ═══ delivered-probe: is the pair-observability delivery present at all? ═══
// Delivery signals that cannot fire pre-delivery: the 「无条目」/「文件时间」
// markers (zero hits on today's page) and the orphan slugs (only a pair list
// would render them). Tile-side wiring is probed on the in-body prefix with
// the topbar excluded (the topbar switch button carries aria-expanded).
const markerMatches = [...html.matchAll(MARKER_RE)]
const orphanSlugSeen = ORPHAN_SLUGS.some((slug) => scriptStripped.includes(slug))
const wiringNearMarkers = markerMatches.some((match) =>
  WIRING_RE.test(html.slice(Math.max(0, match.index - 400), match.index + 400))
)
const wiringNearOrphans = ORPHAN_SLUGS.some((slug) => anyWin(html, slug, (window) => WIRING_RE.test(window)))
const GATE_TILE = WIRING_RE.test(tilesRegion)
const GATE_MARKERS = orphanSlugSeen && (wiringNearMarkers || wiringNearOrphans)
const DELIVERED = GATE_TILE || GATE_MARKERS
console.log(
  `INFO  delivered-probe: markers=${markerMatches.length} orphan-slugs=${orphanSlugSeen ? 'seen' : 'none'} tile-wiring=${GATE_TILE ? 'yes' : 'no'} marker-wiring=${GATE_MARKERS ? 'yes' : 'no'}`
)

// Region helpers for the pending group (pair items are located by their
// covered-file paths, which only the pair list renders — the entries table
// never shows the files[] map).
const itemWin = (slug, pred, pad = 700) => anyWin(html, slug, pred, pad)

if (!DELIVERED) {
  const reason =
    '待 DEV 交付：未探测到产物对可观测交付信号（「无条目」/「文件时间」标记与孤儿 slug 均缺席，KPI 前缀亦无展开接线语义——<summary>/aria-expanded/role=button/<button>/data-* 接线/tabindex 并集）'
  for (const id of ['TC-135', 'TC-140', 'TC-145', 'TC-150', 'TC-155', 'TC-160', 'TC-165', 'TC-170', 'TC-175']) skip(id, reason)
} else {
  // TC-135 (AC-1): one merged pair entry + click-to-expand pair list with
  // every record (entry-bearing pairs AND orphans AND the no-summary record).
  const listedSlugs = PAIR_SLUGS.filter((slug) => scriptStripped.includes(slug))
  check(
    listedSlugs.length === PAIR_SLUGS.length,
    'TC-135: the expanded pair list carries all 5 fixture records (含孤儿与缺 summary 记录，行集=产物记录集)',
    `missing=${PAIR_SLUGS.filter((slug) => !scriptStripped.includes(slug)).join(',') || 'none'}`
  )
  check(
    bounded(tilesRegion, GT_RECORDS) && bounded(tilesRegion, GT_PAIRED) && GATE_TILE,
    'TC-135: the merged pair KPI keeps both counts and carries expansion wiring (两 KPI 合并为一块且可点击展开)',
    `tile-wiring=${GATE_TILE ? 'yes' : 'no'}`
  )

  // TC-140 (AC-2 fresh side): fresh classification + stale item names the
  // changed file. The item is anchored by its files[] path (pair-list-only).
  check(
    itemWin(SLUG_FRESH, (window) => window.includes(SRC_FRESH_A) && STATUS_FRESH_RE.test(window) && !TIME_APPROX_RE.test(window)),
    'TC-140: the all-matching pair is classified fresh (files 全匹配 + 记录存在 → 新鲜语义标记，且不带近似文件时间口径)',
    `looking for ${SRC_FRESH_A} + fresh-status in the pair item window`
  )
  check(
    itemWin(SLUG_STALE, (window) => window.includes(SRC_STALE) && STATUS_STALE_RE.test(window)),
    'TC-140: the hash-mismatch pair is stale AND lists the changed file (src/explpair/login.ts)',
    `looking for ${SRC_STALE} + stale-status in the pair item window`
  )

  // TC-145 (AC-2 missing side): the absent path is named on the item.
  check(
    itemWin(SLUG_MISSING, (window) => window.includes(SRC_GHOST) && STATUS_MISSING_RE.test(window)),
    'TC-145: the missing-path pair lists the absent file (src/explpair/ghost.ts) with a missing-state signal (path 存在性同引擎 Test-EntryFresh 语义)',
    `looking for ${SRC_GHOST} + missing-status in the pair item window`
  )

  // TC-150 (AC-3): orphans appear in the list marked 「无条目」.
  for (const slug of ORPHAN_SLUGS) {
    check(
      itemWin(slug, (window) => ORPHAN_MARK_RE.test(window)),
      `TC-150: orphan artifact ${slug} is listed and marked 「无条目」`,
      `「无条目」 not found near ${slug}`
    )
  }

  // TC-155 (AC-4): time face — hot=registeredAt; persisted/orphan=mtime+标注.
  check(
    itemWin(SLUG_FRESH, (window) => window.includes('2026-10-20') && window.includes(SRC_FRESH_A) && !TIME_APPROX_RE.test(window)),
    'TC-155: hot pair shows the registeredAt date (2026-10-20, 真实注册时间口径) on the pair item',
    'registeredAt date not found on the hot pair item'
  )
  check(
    itemWin(SLUG_MISSING, (window) => window.includes(M_PERSIST) && TIME_APPROX_RE.test(window) && window.includes(SRC_GHOST)),
    'TC-155: persisted pair shows the pinned mtime date (2026-03-04) annotated 「文件时间（近似）」',
    'mtime date or annotation not found on the persisted pair item'
  )
  check(
    itemWin(SLUG_ORPHAN, (window) => window.includes(M_ORPHAN) && TIME_APPROX_RE.test(window)),
    'TC-155: orphan pair shows the pinned mtime date (2026-05-06) annotated 「文件时间（近似）」',
    'mtime date or annotation not found on the orphan pair item'
  )
  check(
    itemWin(SLUG_NOSUMMARY, (window) => window.includes(M_NOSUMMARY) && TIME_APPROX_RE.test(window)),
    'TC-155: no-summary orphan shows the pinned mtime date (2026-07-08) annotated 「文件时间（近似）」',
    'mtime date or annotation not found on the no-summary pair item'
  )

  // TC-160 (AC-5): related artifacts — record path, summary path, files[]
  // list, with machine-readable copy carriers (three-form union).
  const recordPath = (slug) => ART(slug)
  const carrierOk = PAIR_SLUGS.filter((slug) => itemWin(slug, (window) => window.includes(recordPath(slug)) && hasCopyCarrier(window, recordPath(slug)), 900))
  check(
    carrierOk.length === PAIR_SLUGS.length,
    'TC-160: every pair item exposes its artifact path with a copy carrier (data-copy=精确路径 / <code> / 文本节点)',
    `carried=${carrierOk.join(',') || 'none'}`
  )
  check(
    itemWin(SLUG_FRESH, (window) => window.includes(ART(SLUG_FRESH, '.summary')) && hasCopyCarrier(window, ART(SLUG_FRESH, '.summary'))),
    'TC-160: the fresh pair item exposes its summary path with a copy carrier',
    `summary path ${ART(SLUG_FRESH, '.summary')} not carried`
  )
  check(
    itemWin(SLUG_FRESH, (window) => window.includes(SRC_FRESH_A) && window.includes(SRC_FRESH_B) && hasCopyCarrier(window, SRC_FRESH_A)),
    'TC-160: the fresh pair item lists its covered files (auth.ts + session.ts) with a copy carrier',
    'files list or carrier not found on the fresh pair item'
  )

  // TC-165 (AC-6): bounded height — two-sided container <-> CSS rule.
  const containerClasses = new Set()
  const classWindows = [tilesRegion]
  for (const slug of PAIR_SLUGS) {
    for (const at of occurrences(html, slug)) classWindows.push(html.slice(Math.max(0, at - 700), at + 700))
  }
  for (const match of markerMatches) classWindows.push(html.slice(Math.max(0, match.index - 400), match.index + 400))
  for (const window of classWindows) {
    for (const match of window.matchAll(/class="([^"]+)"/g)) {
      for (const cls of match[1].split(/\s+/)) {
        if (/(expand|pair|detail|entr|expl|list|scroll|artifact|prod)/i.test(cls)) containerClasses.add(cls)
      }
    }
  }
  const boundedClasses = [...containerClasses].filter((cls) => {
    for (const rule of styleCss.matchAll(new RegExp(`\\.${escapeRe(cls)}\\s*\\{[^}]*\\}`, 'g'))) {
      const body = rule[0]
      if (/max-height/.test(body) && /overflow(-y)?\s*:\s*(auto|scroll)/.test(body)) return true
    }
    return false
  })
  check(
    containerClasses.size > 0 && boundedClasses.length > 0,
    'TC-165: at least one pair-expansion container class is CSS-bounded (max-height + internal scroll)',
    `candidates=[${[...containerClasses].join(',')}] bounded=[${boundedClasses.join(',')}]`
  )

  // TC-170: wiring consistency — new data-* vocabulary introduced in the pair
  // faces must be consumed by app.js (native <details> needs none -> empty set passes).
  const LEGACY_DATA_ATTRS = new Set([
    'data-theme', 'data-at', 'data-bound', 'data-copy', 'data-href', 'data-query', 'data-tone',
    'data-selected', 'data-config-field', 'data-config-type', 'data-cross-module', 'data-original',
    'data-ux-agent', 'data-ux-field', 'data-filter-value', 'data-filter-source', 'data-tone-info',
    'data-accent', 'data-index', 'data-hit-share', 'data-route',
  ])
  const newVocab = new Set()
  for (const window of classWindows) {
    for (const match of window.matchAll(/data-([a-z0-9-]+)=/g)) {
      const name = `data-${match[1]}`
      if (!LEGACY_DATA_ATTRS.has(name)) newVocab.add(name)
    }
  }
  const orphans = [...newVocab].filter((name) => !appJs.includes(name))
  check(
    orphans.length === 0,
    'TC-170: every pair-face data-* wiring token is referenced by app.js (no dead wiring)',
    `vocab=[${[...newVocab].join(',')}] orphans=[${orphans.join(',')}]`
  )

  // TC-175 (AC-6): the merge keeps the page skeleton and sibling panels.
  check(
    /^<!DOCTYPE html/.test(html.trim()) &&
      html.includes('id="ops-main"') &&
      /rel="stylesheet"/.test(html) &&
      /src="[^"]*app\.js"/.test(html),
    'TC-175: page skeleton contract intact after the pair merge (DOCTYPE/main/stylesheet/app.js)'
  )
  check(
    /tag 分布/.test(html) && /注册时间线/.test(html),
    'TC-175: sibling panels (tag 分布 / 注册时间线) survive the pair merge'
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

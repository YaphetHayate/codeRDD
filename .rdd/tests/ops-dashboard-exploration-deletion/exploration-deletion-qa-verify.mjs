// QA test-first probe — 探索缓存产物删除能力（写路径）(requirement #3,
// archive 2026-10-20-exploration-cache-ux / requirements/artifact-deletion.md).
// Feature: ops-dashboard-exploration-deletion.
//
// Two groups:
//   baseline (TC-180/TC-185) — pins the read face the write path must keep:
//     the mixed-fixture ground truth on page + API (hot 3 / index 1 / total 4 /
//     artifacts 5/5) and the pure-read zero-write invariant. Green today; must
//     stay green after the delete capability lands (整体判据 #2 read half).
//   pending (TC-190..TC-225) — the undelivered deletion behaviour,
//     skip-guarded: a delivered-probe looks for delete vocabulary wired to
//     controls near the pair items in the SSR face OR a delete-semantic fetch
//     channel in app.js. No delivery -> every pending TC SKIPs as "待 DEV
//     交付"; the same command re-run after delivery activates them.
//
// Requirement-anchored semantics (behaviour, not implementation form — the
// write-path architecture form is CTO-decided and deliberately unread):
//   delete = pair delete: artifact.md AND summary.md leave the disk together
//   with the matching hot.json/index.json entry, no orphan file, no orphan
//   entry; both zones deletable; a confirmation gate must sit on the trigger
//   path before anything executes; failures surface a clear error and leave
//   either everything or nothing (never half). Orphan pairs (no cache entry)
//   are out of scope — no assertion demands a delete control on them, and the
//   collateral check demands they survive other pairs' deletions untouched.
//
// Trigger-channel discovery (how the probe replays "the same HTTP request the
// UI would issue" without a browser), union of three sources:
//   1. app.js fetch template — a fetch call whose window carries delete
//      vocabulary and an exploration-ish URL; ${slug}/{slug}/:slug placeholders
//      substituted with the victim slug (most faithful: it IS the UI channel);
//   2. SSR <form action> near delete vocabulary in the pair-item windows;
//   3. route-candidate probing on the hot victim (404 -> not the channel);
//      only reached when 1+2 yield nothing. If all three fail while delivery
//      signals exist, TC-195 FAILs (no silent SKIP for a bogus delivery).
//
// Failure injection (AC-4): chmod 0o444 on the victim's summary file (Windows
// read-only attribute -> unlink EPERM). Expected: error face + all-remain
// (files AND entries). Any half state (one file gone / entry gone) fails.
//
// Noise policy: registeredAt values are fixed ISO strings; no per-request
// timestamps are ever asserted (generatedAt untouched); mtime is only
// compared where writes must not happen. Pure-node probe: fs/http/in-process
// server only, no child processes (git/CLI re-checks belong to the verify
// round's shell evidence layer, not here — tip 20261020T144437Z-QA-1893).
// Region model: KPI face is anchored id="ops-main" -> next <section (the
// topbar switcher <section> sits BEFORE ops-main — tip 20261020T124430Z-QA-2dda).
//
// Run: node .rdd/tests/ops-dashboard-exploration-deletion/exploration-deletion-qa-verify.mjs
import { createHash } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
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
// rich root: 4 cache entries (hot 3 + index 1) over 5 artifact records
// (all paired). Three entry-bearing pairs are dedicated victims:
//   hot victim      — TC-200 (hot-zone pair delete, also the discovery probe)
//   persist victim  — TC-205 (persisted-layer pair delete)
//   fail victim     — TC-215 (read-only summary -> failure face)
// keep-hot survives everything (collateral sentinel + no-JS face anchor);
// the orphan pair has NO cache entry: out of delete scope, must survive.
const SLUG_VICTIM_HOT = 'expldel-hot-victim'
const SLUG_VICTIM_PERSIST = 'expldel-persist-victim'
const SLUG_VICTIM_FAIL = 'expldel-fail-victim'
const SLUG_KEEP_HOT = 'expldel-hot-keep'
const SLUG_ORPHAN = 'expldel-orphan'
const ENTRY_SLUGS = [SLUG_VICTIM_HOT, SLUG_VICTIM_PERSIST, SLUG_VICTIM_FAIL, SLUG_KEEP_HOT]

const GT_HOT = 3
const GT_INDEX = 1
const GT_TOTAL = 4
const GT_RECORDS = 5
const GT_PAIRED = 5

const ART = (slug) => `.rdd/exploration/artifacts/${slug}.md`
const SUM = (slug) => `.rdd/exploration/artifacts/${slug}.summary.md`
const T_AT = '2026-10-20T01:00:00Z' // fixed registeredAt — no clock noise

const HOT_ENTRIES = [SLUG_VICTIM_HOT, SLUG_VICTIM_FAIL, SLUG_KEEP_HOT].map((slug, index) => ({
  key: slug,
  tags: ['expldel-zone-hot'],
  brief: `热区条目摘要 ${slug}`,
  path: ART(slug),
  files: {},
  registeredAt: `2026-10-20T0${index + 1}:00:00Z`,
}))
const INDEX_ENTRIES = [
  {
    key: SLUG_VICTIM_PERSIST,
    tags: ['expldel-zone-persist'],
    brief: `持久层条目摘要 ${SLUG_VICTIM_PERSIST}`,
    path: ART(SLUG_VICTIM_PERSIST),
    files: {},
    registeredAt: T_AT,
  },
]
const ALL_RECORD_SLUGS = [SLUG_VICTIM_HOT, SLUG_VICTIM_PERSIST, SLUG_VICTIM_FAIL, SLUG_KEEP_HOT, SLUG_ORPHAN]

function write(root, relativePath, content) {
  const absolute = join(root, relativePath)
  mkdirSync(dirname(absolute), { recursive: true })
  writeFileSync(absolute, content, 'utf8')
  return absolute
}

const richRoot = mkdtempSync(join(tmpdir(), 'rdd-expl-del-'))
cleanups.push(() => {
  try {
    chmodSync(join(richRoot, '.rdd/exploration/hot.json'), 0o666)
  } catch {
    /* already writable or gone */
  }
  rmSync(richRoot, { recursive: true, force: true })
})

const hotRaw = `${JSON.stringify({ entries: HOT_ENTRIES }, null, 2)}\n`
const indexRaw = `${JSON.stringify({ entries: INDEX_ENTRIES }, null, 2)}\n`
write(richRoot, '.rdd/exploration/hot.json', hotRaw)
write(richRoot, '.rdd/exploration/index.json', indexRaw)
for (const slug of ALL_RECORD_SLUGS) {
  write(richRoot, ART(slug), `# full record ${slug}\n`)
  write(richRoot, SUM(slug), `summary ${slug}\n`)
}

/** relpath -> [size, mtimeMs, sha256] for every file under root. */
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
const diffOf = (root, before, { withMtime }) => {
  const after = treeSnapshot(root)
  const removed = []
  const changed = []
  for (const [file, was] of before) {
    const now = after.get(file)
    if (now === undefined) removed.push(file)
    else if (now[0] !== was[0] || now[2] !== was[2] || (withMtime && now[1] !== was[1])) changed.push(file)
  }
  for (const file of after.keys()) if (!before.has(file)) changed.push(`(+${file})`)
  return { removed, changed }
}
/** full drift (size+mtime+sha) — for writes that must not happen at all */
const driftOf = (root, before) => diffOf(root, before, { withMtime: true })
/** content drift (size+sha only) — tolerates identical-content re-serialization
 *  (a benign rewrite keeps the DATA untouched even though mtime rolls) */
const contentDriftOf = (root, before) => diffOf(root, before, { withMtime: false })
const snapFixture = treeSnapshot(richRoot)

// ── real service over the fixture root (in-process, ephemeral port) ──
// Deletion mutates .rdd — the probe NEVER points at the real repo data root.
function listen(context) {
  return new Promise((resolveReady, rejectReady) => {
    const server = startServer({ context, port: 0, quiet: true, onReady: () => resolveReady(server) })
    server.on('error', rejectReady)
    // async close: awaiting the close callback lets the libuv loop drain
    // before exit (process.exit() racing server.close() trips a libuv
    // assertion on Windows — cf. n3 probe).
    cleanups.push(() => new Promise((resolveClose) => server.close(() => resolveClose())))
  })
}
const server = await listen({ projectRoot: richRoot, rddRoot: join(richRoot, '.rdd') })
const base = `http://127.0.0.1:${server.address().port}`

const getPage = async (path) => {
  const response = await fetch(base + path)
  return { status: response.status, body: await response.text() }
}

const firstPage = await getPage('/exploration')
const html = firstPage.body
const scriptStripped = html.replace(/<script[\s\S]*?<\/script>/g, ' ')
const apiBefore = await (await fetch(`${base}/api/exploration`)).json()
const appJs = await (await fetch(`${base}/static/app.js`)).text()
await getPage('/exploration') // second read: stability + read-path coverage

// ═══ helpers ═══
/** tag-stripped digit-boundary check (prevents "15 contains 5" false hits). */
const bounded = (window, number) => new RegExp(`(^|[>\\s])${number}([<\\s]|$)`).test(window.replace(/<[^>]+>/g, ' '))
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
function anyWin(text, slug, pred, pad = 900) {
  return occurrences(text, slug).some((at) => pred(text.slice(Math.max(0, at - pad), at + slug.length + pad)))
}

// Region model: the in-body KPI prefix from ops-main to the first content
// <section> AFTER it. The topbar's switcher <section> sits BEFORE ops-main —
// a naive "everything before the first <section>" truncates inside the topbar
// (tip 20261020T124430Z-QA-2dda, fixed same round on feature #2's probe).
const mainAt = html.indexOf('id="ops-main"')
const tilesRegion = mainAt >= 0 ? html.slice(mainAt, Math.max(mainAt, html.indexOf('<section', mainAt))) : ''

const WIRING_RE = /<summary[\s>]|aria-expanded|role="(button|switch)"|<button[\s>]|<form[\s>]|data-(toggle|expand|expander|kpi|collapse|target|open|detail|delete|remove|confirm)|tabindex=/
const DELETE_VOCAB_RE = /(删除|刪除|清除|delete|remove)/i
const DELETE_VOCAB_GLOBAL_RE = /(删除|刪除|清除|delete|remove)/gi // matchAll demands the g flag (rehearsal-caught)
const CONFIRM_RE = /window\.confirm|(^|[^a-zA-Z.])confirm\s*\(|data-confirm|二次确认|确认删除/
const FETCH_URL_RE = /fetch\(\s*([`'"])([^`'"]+)\1/g

const readEntries = (file) => JSON.parse(readFileSync(join(richRoot, '.rdd/exploration', file), 'utf8')).entries ?? []
const fileGone = (relativePath) => !existsSync(join(richRoot, relativePath))
const hotKeys = () => readEntries('hot.json').map((entry) => entry.key)
const indexKeys = () => readEntries('index.json').map((entry) => entry.key)
const deletedFully = (slug) => fileGone(ART(slug)) && fileGone(SUM(slug)) && !hotKeys().includes(slug) && !indexKeys().includes(slug)

/** Fire one delete request through the discovered channel for a slug.
 *  Form-derived channels speak the form-native urlencoded encoding (a
 *  form-semantic endpoint would not parse a JSON body); JS/API-derived
 *  channels speak JSON. */
async function fire(channel, slug) {
  const init = { method: channel.method, headers: {} }
  if (channel.method !== 'GET') {
    if (channel.formEncoded === true) {
      init.headers['content-type'] = 'application/x-www-form-urlencoded'
      init.body = new URLSearchParams({ slug, key: slug, path: ART(slug) }).toString()
    } else {
      init.headers['content-type'] = 'application/json'
      init.body = JSON.stringify({ slug, key: slug, path: ART(slug), ...channel.extraBody })
    }
  }
  const response = await fetch(base + channel.urlFor(slug), init)
  const text = await response.text()
  let json = null
  try {
    json = JSON.parse(text)
  } catch {
    /* non-JSON face (204 / html error page) — status still carries the verdict */
  }
  return { status: response.status, json, text }
}
/** substitute ${slug} / {slug} / :slug placeholder families in a URL template */
const subSlug = (template, slug) =>
  template
    .replace(/\$\{[^}]*\}/g, encodeURIComponent(slug))
    .replace(/\{slug\}|\{key\}|\{id\}/g, encodeURIComponent(slug))
    .replace(/:slug\b|:key\b|:id\b/g, encodeURIComponent(slug))

/**
 * Build a placeholder template from a quoted fetch URL, following string
 * concatenation: 'prefix' + expr [+ 'suffix' + expr...]. Template literals
 * with ${...} pass through unchanged. Rehearsal-caught: a concatenated
 * channel ('/api/.../' + encodeURIComponent(slug)) must NOT resolve to the
 * bare prefix — the slug segment would be silently dropped and every fire
 * would 404.
 */
function fetchUrlTemplate(text, match, url) {
  let template = url
  let cursor = match.index + match[0].length // match[0] ends right after the closing quote (fetch( + quote + url + quote)
  let step = /^\s*\+\s*(?:encodeURIComponent\(\s*)?([A-Za-z_$][\w$.]*)\s*\)?/.exec(text.slice(cursor, cursor + 160))
  while (step !== null && /slug|key|id|pair|entry/i.test(step[1])) {
    template += '{slug}'
    cursor += step[0].length
    const literal = /^\s*\+\s*([`'"])([^`'"]+)\1/.exec(text.slice(cursor, cursor + 160))
    if (literal === null) break
    template += literal[2]
    cursor += literal[0].length
    step = /^\s*\+\s*(?:encodeURIComponent\(\s*)?([A-Za-z_$][\w$.]*)\s*\)?/.exec(text.slice(cursor, cursor + 160))
  }
  return template
}

// ═══ baseline group (green today; pins what the write path must keep) ═══
// TC-180 (整体判据 #2 read half): the read face keeps its ground truth —
// page KPI numbers AND the frozen API envelope. The delete capability must
// not change the read-side counting semantics.
check(
  firstPage.status === 200 &&
    bounded(tilesRegion, GT_HOT) &&
    bounded(tilesRegion, GT_INDEX) &&
    bounded(tilesRegion, GT_TOTAL) &&
    bounded(tilesRegion, GT_RECORDS),
  `TC-180 baseline: /exploration 200 and the KPI face carries the ground truth (hot ${GT_HOT} / index ${GT_INDEX} / total ${GT_TOTAL} / records ${GT_RECORDS})`,
  `status=${firstPage.status}`
)
check(
  apiBefore.domain === 'exploration' &&
    apiBefore.available === true &&
    typeof apiBefore.meta?.generatedAt === 'string' &&
    apiBefore.data?.hotCount === GT_HOT &&
    apiBefore.data?.indexCount === GT_INDEX &&
    apiBefore.data?.totalCount === GT_TOTAL &&
    apiBefore.data?.entries?.length === GT_TOTAL &&
    apiBefore.data?.artifacts?.count === GT_RECORDS &&
    apiBefore.data?.artifacts?.pairedCount === GT_PAIRED,
  `TC-180 baseline: API envelope frozen (hot ${GT_HOT} / index ${GT_INDEX} / total ${GT_TOTAL} / artifacts ${GT_RECORDS}/${GT_PAIRED})`,
  JSON.stringify({ hot: apiBefore.data?.hotCount, index: apiBefore.data?.indexCount, artifacts: apiBefore.data?.artifacts })
)

// TC-185 (整体判据 #2): pure reads never write — content, size or mtime.
const driftAfterReads = driftOf(richRoot, snapFixture)
check(
  driftAfterReads.removed.length === 0 && driftAfterReads.changed.length === 0,
  'TC-185 baseline: read interactions leave the fixture tree byte-identical (size+mtime+SHA256 zero-write)',
  `removed=[${driftAfterReads.removed.join(',')}] changed=[${driftAfterReads.changed.join(',')}]`
)

// ═══ delivered-probe: is the deletion delivery present at all? ═══
// HTML signal: delete vocabulary wired to a control inside a pair-item
// window (entry-bearing pairs; the orphan gets no demand — out of scope).
// app.js signal: a fetch channel whose window carries delete vocabulary and
// an exploration-ish URL. 删除 vocabulary is absent from today's /exploration
// face (grep-verified: it only lives on /config), so the gate cannot fire
// pre-delivery.
const htmlDeleteControls = Object.fromEntries(
  ENTRY_SLUGS.map((slug) => [slug, anyWin(html, slug, (window) => DELETE_VOCAB_RE.test(window) && WIRING_RE.test(window))])
)
const htmlSignal = Object.values(htmlDeleteControls).every(Boolean)
const appJsFetchWindows = []
for (const match of appJs.matchAll(FETCH_URL_RE)) {
  appJsFetchWindows.push(appJs.slice(Math.max(0, match.index - 200), match.index + 800))
}
const appJsSignal = appJsFetchWindows.some((window) => DELETE_VOCAB_RE.test(window) && /\/api\/|exploration|artifact/i.test(window))
const DELIVERED = htmlSignal || appJsSignal
console.log(
  `INFO  delivered-probe: html-controls=${Object.values(htmlDeleteControls).filter(Boolean).length}/${ENTRY_SLUGS.length} appjs-channel=${appJsSignal ? 'yes' : 'no'}`
)

if (!DELIVERED) {
  const reason =
    '待 DEV 交付：未探测到删除能力交付信号（entry 产物对窗内无删除语义控件接线，app.js 亦无删除语义 fetch 通道——删除/清除/delete/remove 词族 × 接线并集）'
  for (const id of ['TC-190', 'TC-195', 'TC-200', 'TC-205', 'TC-210', 'TC-215', 'TC-220', 'TC-225']) skip(id, reason)
} else {
  try {
  // TC-190 (AC-1 + AC-5 wiring face): a delete entry exists on the pair
  // expansion view — SSR per-pair controls (all entry-bearing pairs) OR the
  // JS channel carrying a pair identifier — and a confirmation gate sits on
  // the delete path BEFORE execution. Cancel-click itself cannot be simulated
  // in-process (no browser): the gate-on-path is the requirement-anchored
  // proxy, the behavioural cancel stays a verify-round manual protocol item.
  const appJsCarriesPairIdentity = appJsFetchWindows.some(
    (window) => DELETE_VOCAB_RE.test(window) && /\/api\/|exploration|artifact/i.test(window) && /slug|key|path|pair/i.test(window)
  )
  check(
    htmlSignal || appJsCarriesPairIdentity,
    'TC-190: every entry-bearing pair exposes a delete entry (SSR per-pair control union, or a JS channel that carries pair identity)',
    `html-controls=${JSON.stringify(htmlDeleteControls)} appjs-identity=${appJsCarriesPairIdentity}`
  )
  const appJsConfirmOnDeletePath = appJsFetchWindows.some((window) => DELETE_VOCAB_RE.test(window) && CONFIRM_RE.test(window)) ||
    [...appJs.matchAll(DELETE_VOCAB_GLOBAL_RE)].some((match) => CONFIRM_RE.test(appJs.slice(Math.max(0, match.index - 600), match.index + 600)))
  const htmlConfirmNearControls = ENTRY_SLUGS.some((slug) =>
    anyWin(html, slug, (window) => DELETE_VOCAB_RE.test(window) && /data-confirm|二次确认|确认删除/.test(window))
  )
  check(
    appJsConfirmOnDeletePath || htmlConfirmNearControls,
    'TC-190: a confirmation gate sits on the delete trigger path (window.confirm / data-confirm / 二次确认 vocabulary union)',
    `appjs=${appJsConfirmOnDeletePath} html=${htmlConfirmNearControls}`
  )

  // TC-195: trigger-channel discovery — replay "the same HTTP request the UI
  // would issue". Source 1: app.js fetch template (most faithful). Source 2:
  // SSR <form action> near delete vocabulary. Source 3: route-candidate
  // probing on the hot victim (mutating — victim is TC-200's target anyway).
  // All three empty while delivery signals fire -> FAIL, never a silent SKIP.
  let channel = null
  let channelSource = ''
  for (const match of appJs.matchAll(FETCH_URL_RE)) {
    const url = match[2]
    const window = appJs.slice(match.index, match.index + 900)
    if (!DELETE_VOCAB_RE.test(window)) continue
    if (!/\/api\/|exploration|artifact/i.test(url + window)) continue
    const methodMatch = /method:\s*['"](DELETE|POST|PUT|PATCH)['"]/.exec(window)
    const template = fetchUrlTemplate(appJs, match, url)
    channel = { method: methodMatch ? methodMatch[1] : 'POST', urlFor: (slug) => subSlug(template, slug) }
    channelSource = `app.js fetch ${channel.method} ${template}`
    break
  }
  if (channel === null) {
    // SSR forms render CONCRETE per-pair actions (server-side resolved), not
    // templates — the anchor pair's slug inside the action must be lifted to
    // a {slug} placeholder before the channel can serve any other victim.
    // Rehearsal-caught: the ±window around an anchor slug may contain the
    // PREVIOUS row's form first — a form only counts when it carries the
    // anchor's identity (slug in the action, or a hidden input value), else
    // the probe would delete the wrong pair. Form channels speak urlencoded.
    outerForm: for (const anchorSlug of ENTRY_SLUGS) {
      for (const at of occurrences(html, anchorSlug)) {
        const window = html.slice(Math.max(0, at - 900), at + anchorSlug.length + 900)
        if (!DELETE_VOCAB_RE.test(window)) continue
        for (const formMatch of window.matchAll(/<form[^>]*>/g)) {
          const tag = formMatch[0]
          const action = /action="([^"]*)"/.exec(tag)?.[1]
          if (action === undefined || action === '') continue
          const formBody = window.slice(formMatch.index, formMatch.index + 400)
          const carriesAnchor = action.includes(anchorSlug) || formBody.includes(`value="${anchorSlug}"`)
          if (!carriesAnchor) continue
          const method = (/method="([^"]*)"/.exec(tag)?.[1] ?? 'POST').toUpperCase()
          const template = action.split(anchorSlug).join('{slug}')
          channel = { method, urlFor: (slug) => subSlug(template, slug), formEncoded: true }
          channelSource = `SSR form ${method} ${template}`
          break outerForm
        }
      }
    }
  }
  let victimHotAlreadyDeleted = false
  let discoveryResponse = null
  if (channel === null) {
    const candidates = [
      { method: 'POST', url: (s) => `/api/exploration/artifacts/${s}/delete` },
      { method: 'DELETE', url: (s) => `/api/exploration/artifacts/${s}` },
      { method: 'POST', url: () => `/api/exploration/artifacts/delete` },
      { method: 'POST', url: () => `/api/exploration/delete` },
      { method: 'DELETE', url: (s) => `/api/exploration/entries/${s}` },
      { method: 'POST', url: (s) => `/api/exploration/artifacts/${s}` },
    ]
    const probed = []
    for (const candidate of candidates) {
      discoveryResponse = await fire({ method: candidate.method, urlFor: candidate.url }, SLUG_VICTIM_HOT)
      probed.push(`${candidate.method} ${candidate.urlFor(SLUG_VICTIM_HOT)} -> ${discoveryResponse.status}`)
      if (discoveryResponse.status === 404 || discoveryResponse.status === 405) continue
      if (deletedFully(SLUG_VICTIM_HOT)) {
        // candidates carry a url(slug) builder — normalize to the channel
        // shape fire() expects (urlFor). Rehearsal-caught: assigning the raw
        // candidate crashes fire() with "urlFor is not a function".
        channel = { method: candidate.method, urlFor: candidate.url }
        channelSource = `route-probe ${candidate.method} ${candidate.url(SLUG_VICTIM_HOT)}`
        victimHotAlreadyDeleted = true
        break
      }
    }
    console.log(`INFO  route-candidate probing: ${probed.join(' | ')}`)
  }
  if (channel !== null) {
    console.log(`INFO  trigger channel discovered via ${channelSource}`)
    pass('TC-195: the delete trigger channel is discoverable and replayable (app.js template / SSR form / route probe union)')
  } else {
    fail(
      'TC-195: the delete trigger channel is discoverable and replayable (app.js template / SSR form / route probe union)',
      'delivery signals present but no channel resolved: neither an app.js fetch template, nor an SSR form action, nor any candidate route answered non-404/405'
    )
  }

  if (channel !== null) {
    // One retry shape for challenge-style APIs: if the first fire hints at a
    // confirmation requirement, replay with explicit confirm flags (union
    // handling; exotic two-step protocols may need verify-round instrument
    // adjustment — same adjudication norm as status-word unions).
    const fireWithConfirmFallback = async (slug) => {
      const first = await fire(channel, slug)
      const hint = first.json?.message ?? first.text ?? ''
      if ((first.status === 400 || first.status === 409 || first.status === 428) && /confirm|确认/i.test(hint)) {
        channel.extraBody = { confirm: true, confirmed: true }
        return await fire(channel, slug)
      }
      return first
    }

    // TC-200 (AC-2 + AC-3 hot side): pair delete of a hot-zone pair.
    let response = null
    if (victimHotAlreadyDeleted) {
      console.log('INFO  TC-200 victim was consumed by route probing — asserting effects only')
    } else {
      response = await fireWithConfirmFallback(SLUG_VICTIM_HOT)
      console.log(`INFO  delete ${SLUG_VICTIM_HOT} -> HTTP ${response.status} ${response.json ? JSON.stringify(response.json).slice(0, 160) : '(non-JSON body)'}`)
    }
    check(
      response === null || (response.status >= 200 && response.status < 300) || response.json?.ok === true,
      'TC-200: the hot-zone delete request answers success (2xx or ok:true)',
      response === null ? 'consumed by discovery probing (effects asserted below)' : `status=${response.status}`
    )
    check(
      fileGone(ART(SLUG_VICTIM_HOT)) && fileGone(SUM(SLUG_VICTIM_HOT)),
      'TC-200: artifact.md AND summary.md both leave the disk (成对删除，无孤儿文件)',
      `artifact=${existsSync(join(richRoot, ART(SLUG_VICTIM_HOT))) ? 'present' : 'gone'} summary=${existsSync(join(richRoot, SUM(SLUG_VICTIM_HOT))) ? 'present' : 'gone'}`
    )
    check(
      !hotKeys().includes(SLUG_VICTIM_HOT) && hotKeys().includes(SLUG_VICTIM_FAIL) && hotKeys().includes(SLUG_KEEP_HOT),
      'TC-200: the hot.json entry is removed while sibling hot entries survive (无孤儿条目、无误伤)',
      `hot keys=[${hotKeys().join(',')}]`
    )
    check(
      readFileSync(join(richRoot, '.rdd/exploration/index.json'), 'utf8') === indexRaw,
      'TC-200: index.json is byte-untouched by a hot-zone delete',
      'index.json content drifted'
    )
    const pageAfterHot = await getPage('/exploration')
    const strippedAfterHot = pageAfterHot.body.replace(/<script[\s\S]*?<\/script>/g, ' ')
    const apiAfterHot = await (await fetch(`${base}/api/exploration`)).json()
    check(
      pageAfterHot.status === 200 && !strippedAfterHot.includes(SLUG_VICTIM_HOT),
      'TC-200: page refresh no longer shows the deleted pair (per-request re-read, no cache)',
      `status=${pageAfterHot.status}`
    )
    check(
      apiAfterHot.data?.hotCount === GT_HOT - 1 &&
        apiAfterHot.data?.totalCount === GT_TOTAL - 1 &&
        apiAfterHot.data?.artifacts?.count === GT_RECORDS - 1 &&
        apiAfterHot.data?.artifacts?.pairedCount === GT_PAIRED - 1 &&
        apiAfterHot.data?.indexCount === GT_INDEX,
      `TC-200: counts decrement exactly (hot ${GT_HOT - 1} / index ${GT_INDEX} / total ${GT_TOTAL - 1} / artifacts ${GT_RECORDS - 1}/${GT_PAIRED - 1})`,
      JSON.stringify({ hot: apiAfterHot.data?.hotCount, index: apiAfterHot.data?.indexCount, total: apiAfterHot.data?.totalCount, artifacts: apiAfterHot.data?.artifacts })
    )

    // TC-205 (AC-3 persisted side): the symmetric pair delete on the
    // persisted layer (index zone).
    const persistResponse = await fireWithConfirmFallback(SLUG_VICTIM_PERSIST)
    console.log(`INFO  delete ${SLUG_VICTIM_PERSIST} -> HTTP ${persistResponse.status}`)
    check(
      (persistResponse.status >= 200 && persistResponse.status < 300) || persistResponse.json?.ok === true,
      'TC-205: the persisted-layer delete request answers success (2xx or ok:true)',
      `status=${persistResponse.status}`
    )
    check(
      fileGone(ART(SLUG_VICTIM_PERSIST)) && fileGone(SUM(SLUG_VICTIM_PERSIST)) && !indexKeys().includes(SLUG_VICTIM_PERSIST),
      'TC-205: persisted pair delete removes both files AND the index.json entry',
      `artifact=${!fileGone(ART(SLUG_VICTIM_PERSIST)) ? 'present' : 'gone'} summary=${!fileGone(SUM(SLUG_VICTIM_PERSIST)) ? 'present' : 'gone'} index keys=[${indexKeys().join(',')}]`
    )
    const pageAfterPersist = await getPage('/exploration')
    const apiAfterPersist = await (await fetch(`${base}/api/exploration`)).json()
    check(
      pageAfterPersist.status === 200 &&
        !pageAfterPersist.body.replace(/<script[\s\S]*?<\/script>/g, ' ').includes(SLUG_VICTIM_PERSIST) &&
        apiAfterPersist.data?.indexCount === 0 &&
        apiAfterPersist.data?.totalCount === GT_TOTAL - 2 &&
        apiAfterPersist.data?.artifacts?.count === GT_RECORDS - 2 &&
        apiAfterPersist.data?.artifacts?.pairedCount === GT_PAIRED - 2,
      `TC-205: page refresh hides the pair and counts reach ${GT_TOTAL - 2} total / artifacts ${GT_RECORDS - 2}/${GT_PAIRED - 2} with index 0`,
      JSON.stringify({ index: apiAfterPersist.data?.indexCount, total: apiAfterPersist.data?.totalCount, artifacts: apiAfterPersist.data?.artifacts })
    )

    // TC-210 (整体判据 #2 write half): the delete action's change set is
    // EXACTLY the four victim files plus the two zone indexes — everything
    // else (keep-hot pair, fail-victim pair, orphan pair, source files)
    // stays byte- and mtime-identical.
    const driftAfterDeletes = driftOf(richRoot, snapFixture)
    const expectedRemoved = [ART(SLUG_VICTIM_HOT), SUM(SLUG_VICTIM_HOT), ART(SLUG_VICTIM_PERSIST), SUM(SLUG_VICTIM_PERSIST)].sort()
    const allowedChanged = new Set(['.rdd/exploration/hot.json', '.rdd/exploration/index.json'])
    const changedOutside = driftAfterDeletes.changed.filter((file) => !allowedChanged.has(file.replace(/^\(\+/, '').replace(/\)$/, '')))
    check(
      JSON.stringify(driftAfterDeletes.removed.sort()) === JSON.stringify(expectedRemoved) && changedOutside.length === 0,
      'TC-210: the write footprint is exactly the two victim pairs + the two zone indexes (其余零附带损伤，孤儿产物对完好)',
      `removed=[${driftAfterDeletes.removed.join(',')}] changed-outside=[${changedOutside.join(',')}]`
    )

    // TC-215 (AC-4 failure face): hot.json made read-only (0o444) must make
    // the entry-removal write fail (writeFileSync/rename-onto both honour the
    // attribute on Windows -> EPERM) and the failure must surface a clear
    // error leaving EVERYTHING behind — no half state. Rehearsal-caught
    // platform fact: chmod 0o444 does NOT block file DELETION on Windows
    // (libuv's unlink clears FILE_ATTRIBUTE_READONLY and retries), so the
    // injection targets the zone-file write, not the artifact unlink. An
    // implementation that removes the files first and only then fails the
    // json write has produced files-gone/entry-present — exactly the half
    // state AC-4 forbids (一致性由实现保证).
    chmodSync(join(richRoot, '.rdd/exploration/hot.json'), 0o444)
    const snapBeforeFail = treeSnapshot(richRoot)
    const failResponse = await fireWithConfirmFallback(SLUG_VICTIM_FAIL)
    console.log(`INFO  delete ${SLUG_VICTIM_FAIL} (summary read-only) -> HTTP ${failResponse.status} ${failResponse.json ? JSON.stringify(failResponse.json).slice(0, 200) : '(non-JSON body)'}`)
    const failFace = (failResponse.status >= 400 && failResponse.status !== 404) || failResponse.json?.ok === false
    const jsonPayload = failResponse.json
    const messageFace = jsonPayload !== null
      ? ((typeof jsonPayload.message === 'string' && jsonPayload.message.trim().length > 0) || typeof jsonPayload.error === 'string')
      : failResponse.status >= 400 && failResponse.text.trim().length > 0
    check(
      failFace,
      'TC-215: the blocked delete surfaces a clear failure face (4xx/5xx or ok:false — not a silent success)',
      `status=${failResponse.status} ok=${failResponse.json?.ok}`
    )
    check(
      messageFace,
      'TC-215: the failure response carries a non-empty message/error payload',
      `body=${failResponse.text.slice(0, 120)}`
    )
    const driftAfterFail = contentDriftOf(richRoot, snapBeforeFail)
    const apiAfterFail = await (await fetch(`${base}/api/exploration`)).json()
    check(
      driftAfterFail.removed.length === 0 &&
        driftAfterFail.changed.length === 0 &&
        hotKeys().includes(SLUG_VICTIM_FAIL) &&
        apiAfterFail.data?.hotCount === GT_HOT - 1 &&
        apiAfterFail.data?.artifacts?.count === GT_RECORDS - 2,
      'TC-215: no half state — files AND entries all remain after the failed delete (要么全删要么全留)',
      `removed=[${driftAfterFail.removed.join(',')}] changed=[${driftAfterFail.changed.join(',')}] hot keys=[${hotKeys().join(',')}]`
    )
    try {
      chmodSync(join(richRoot, '.rdd/exploration/hot.json'), 0o666)
    } catch {
      /* best effort — the root cleanup re-tries */
    }

    // TC-220 (boundary): deleting a non-existent target answers a clear
    // error, changes no data on disk (content-level: an identical-content
    // re-serialization is tolerated) and never crashes the service.
    const snapBeforeGhost = treeSnapshot(richRoot)
    const ghostResponse = await fireWithConfirmFallback('expldel-ghost-target')
    console.log(`INFO  delete expldel-ghost-target -> HTTP ${ghostResponse.status}`)
    const driftAfterGhost = contentDriftOf(richRoot, snapBeforeGhost)
    const pageAfterGhost = await getPage('/exploration')
    check(
      (ghostResponse.status >= 400 || ghostResponse.json?.ok === false) &&
        driftAfterGhost.removed.length === 0 &&
        driftAfterGhost.changed.length === 0 &&
        pageAfterGhost.status === 200,
      'TC-220: a non-existent target answers a clear error with zero disk change and the page keeps rendering',
      `status=${ghostResponse.status} removed=[${driftAfterGhost.removed.join(',')}] changed=[${driftAfterGhost.changed.join(',')}] page=${pageAfterGhost.status}`
    )

    // TC-225: the write path did not break the read face — skeleton, sibling
    // panels and the no-JS flattened pair list survive.
    const finalHtml = (await getPage('/exploration')).body
    const finalStripped = finalHtml.replace(/<script[\s\S]*?<\/script>/g, ' ')
    check(
      /^<!DOCTYPE html/.test(finalHtml.trim()) &&
        finalHtml.includes('id="ops-main"') &&
        /rel="stylesheet"/.test(finalHtml) &&
        /src="[^"]*app\.js"/.test(finalHtml) &&
        /tag 分布/.test(finalHtml) &&
        /注册时间线/.test(finalHtml),
      'TC-225: page skeleton + sibling panels survive the write path (DOCTYPE/main/stylesheet/app.js/tag 分布/注册时间线)'
    )
    check(
      finalStripped.includes(SLUG_KEEP_HOT) && finalStripped.includes(SLUG_ORPHAN),
      'TC-225: the no-JS flattened pair list still renders surviving pairs (keep + orphan slugs visible without script)',
      `keep=${finalStripped.includes(SLUG_KEEP_HOT)} orphan=${finalStripped.includes(SLUG_ORPHAN)}`
    )
  }
  } catch (probeError) {
    // crash insurance: a broken assertion path must surface as a FAIL with the
    // SUMMARY envelope intact, never as a lost run (verify-round evidence)
    fail('pending-group: unexpected probe error (仪表缺陷嫌疑——验证轮先零切换基线取证再修仪表)', probeError instanceof Error ? probeError.message : String(probeError))
  }
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

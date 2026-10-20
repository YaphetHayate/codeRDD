// QA stage-acceptance probe — [集成验收·S1] 读路径交付 (goal-tree bridge run
// deliver-2026-10-20-exploration-cache-ux node n18, QA).
// Archive: 2026-10-20-exploration-cache-ux · requirements/exploration-entry-expansion.md
// (+ artifact-pair-observability.md read faces) · criteria:
// requirements/overview.md#整体验收判据 #1(#1+#2 read segment) + #2(#1+#2).
//
// Unlike the two feature suites (fixture roots), this probe runs against the
// REAL repository data root and proves the integrated read path end to end:
//   L1 计数  — KPI face counts equal ground truth computed live from
//              .rdd/exploration (hot.json + index.json + artifacts/ walk)
//   L2 明细  — exp-total / exp-hot / exp-index panels carry exactly the
//              per-zone entries of the real data (merge = union, empty zone
//              stays empty, zero cross-zone leakage)
//   L3 条目  — a real entry's second-level detail: brief / 记录路径 /
//              涉及文件数 + jump (vscode://file/) and copy (data-copy=)
//              carriers resolving to the record file
//   L4 产物对 — real orphan pair row (「无条目」 + mtime + 文件时间（近似）)
//              and the entry-tied pair row (state machine orphan → no-list →
//              fresh/stale, same vocabulary as the reader), with artifact /
//              summary path copy carriers
//   no-JS   — script-stripped SSR still shows entry key/brief (entries-flat
//              / pairs-flat degradation face)
//   判据#2  — read-only invariant over the REAL .rdd/exploration tree
//              (size+mtime+SHA256 before/after the whole read battery). The
//              frozen engine contract (explore.ps1 / explore-store.ps1 zero
//              diff) is verified OUTSIDE this probe via git evidence in the
//              stage report, per TC-020 precedent (引擎脚本零改动项在验证轮
//              以 git diff 范围复核，不在运行时断言) and because the probe
//              must stay a pure read-face program (no subprocess spawning).
//
// Ground truth is computed at runtime (no hardcoded counts — the real cache
// evolves), pairing rule mirrors the engine write face: record = artifacts/
// <slug>.md, summary = <slug>.summary.md, entry↔record via entry.path; the
// single-source fixture-exclusion rule (dashboard/lib/paths.mjs) is mirrored
// for artifact names. Freshness state vocabulary: fresh / stale / orphan /
// no-list (reader state machine; no-list = entry without a files list —
// freshness is honestly "cannot compute", NOT claimed fresh).
//
// Run: node .rdd/tests/ops-dashboard-exploration-expansion/stage-acceptance-s1-verify.mjs
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { startServer } from '../../../rdd-engine/dashboard/server.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..')
const results = []

function pass(name) { results.push({ name, kind: 'PASS' }); console.log(`PASS  ${name}`) }
function fail(name, detail = '') { results.push({ name, kind: 'FAIL', detail }); console.log(`FAIL  ${name}   ${detail}`) }
function skip(name, reason) { results.push({ name, kind: 'SKIP', detail: reason }); console.log(`SKIP  ${name}   ${reason}`) }
function check(condition, name, detail = '') { if (condition) pass(name); else fail(name, detail) }

// ── ground truth computed live from the real data root ──────────────
const explRoot = join(repoRoot, '.rdd', 'exploration')
const readEntries = (file) => {
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8'))
    return Array.isArray(parsed?.entries) ? parsed.entries : []
  } catch { return [] }
}
const hotEntries = readEntries(join(explRoot, 'hot.json'))
const indexEntries = readEntries(join(explRoot, 'index.json'))
const allEntries = [...hotEntries, ...indexEntries]
const entryByRel = new Map(allEntries.map((e) => [String(e.path ?? ''), e]))

const artDir = join(explRoot, 'artifacts')
const isExcludedName = (name) => {
  const s = name.toLowerCase()
  return s === 'tmp' || s.startsWith('qa-') || s.includes('qa-fixture') || s.includes('qa-bridge') || /\d{4}-12-31-qa-/.test(s)
}
const names = existsSync(artDir) ? readdirSync(artDir).sort() : []
const recordNames = names.filter((n) => n.endsWith('.md') && !n.endsWith('.summary.md') && !isExcludedName(n))
const summaryNames = new Set(names.filter((n) => n.endsWith('.summary.md') && !isExcludedName(n)))
const GT = {
  hot: hotEntries.length,
  index: indexEntries.length,
  total: allEntries.length,
  records: recordNames.length,
  paired: recordNames.filter((n) => summaryNames.has(`${n.slice(0, -3)}.summary.md`)).length,
  mdTotal: names.filter((n) => n.endsWith('.md') && !isExcludedName(n)).length,
}
const relOf = (name) => `.rdd/exploration/artifacts/${name}`
const absPosix = (rel) => resolve(repoRoot, rel).split('\\').join('/')
const utcMinute = (ms) => new Date(ms).toISOString().slice(0, 16).replace('T', ' ')

const tiedNames = recordNames.filter((n) => entryByRel.has(relOf(n)))
const orphanNames = recordNames.filter((n) => !entryByRel.has(relOf(n)) && summaryNames.has(`${n.slice(0, -3)}.summary.md`))
const indexEntry = indexEntries[0] ?? allEntries[0] ?? null

/** mirror of the reader freshness state machine (orphan → no-list → compute) */
function expectedFreshness(entry) {
  if (!entry) return 'orphan'
  const files = entry.files && typeof entry.files === 'object' ? Object.keys(entry.files) : []
  if (files.length === 0) return 'no-list'
  for (const p of files) {
    const abs = resolve(repoRoot, p)
    if (!existsSync(abs)) return 'stale'
    const current = `sha256:${createHash('sha256').update(readFileSync(abs), 'utf8').digest('hex')}`
    if (current !== entry.files[p]) return 'stale'
  }
  if (!existsSync(resolve(repoRoot, String(entry.path)))) return 'stale'
  return 'fresh'
}

console.log(`INFO  gt: total=${GT.total} hot=${GT.hot} index=${GT.index} records=${GT.records} paired=${GT.paired} mdTotal=${GT.mdTotal} (computed live from real .rdd/exploration)`)
console.log('INFO  slice: L1 计数 → L2 zone 面板 → L3 条目详情 → L4 产物对 → 无 JS 基线 → 判据2 只读/冻结契约')

// ── read-only invariant setup: snapshot the REAL tree before the battery ──
function treeSnapshot(root) {
  const map = new Map()
  const walk = (dir, prefix) => {
    for (const name of readdirSync(dir, { withFileTypes: true })) {
      const abs = join(dir, name.name)
      const rel = prefix ? `${prefix}/${name.name}` : name.name
      if (name.isDirectory()) walk(abs, rel)
      else {
        const st = statSync(abs)
        map.set(rel, [st.size, st.mtimeMs, createHash('sha256').update(readFileSync(abs)).digest('hex')])
      }
    }
  }
  walk(root, '')
  return map
}
const snapBefore = treeSnapshot(explRoot)

// ── real service in-process (fresh node process → current build, tip 134143Z-DEV-48fb) ──
function listen(context) {
  return new Promise((resolveReady) => {
    const server = startServer({ context, port: 0, quiet: true, onReady: () => resolveReady(server) })
  })
}
const server = await listen({ projectRoot: repoRoot, rddRoot: join(repoRoot, '.rdd') })
const base = `http://127.0.0.1:${server.address().port}`

// read battery: SSR page ×2 + API ×2 + static assets (expand/collapse/jump/
// copy are client-side; the server-visible read path is exactly these GETs)
const page = await fetch(`${base}/exploration`)
const html = await page.text()
const apiRes = await fetch(`${base}/api/exploration`)
const api = await apiRes.json()
const page2 = await fetch(`${base}/exploration`)
const apiRes2 = await fetch(`${base}/api/exploration`)
const api2 = await apiRes2.json()
const cssHref = /href="(\/static\/[^"]+\.css)"/.exec(html)?.[1]
const jsSrc = /src="(\/static\/[^"]+\.js)"/.exec(html)?.[1]
const cssStatus = cssHref ? (await fetch(`${base}${cssHref}`)).status : 0
const jsStatus = jsSrc ? (await fetch(`${base}${jsSrc}`)).status : 0

// ── locators (tip 20261020T124430Z-QA-2dda: anchor in-body regions at ops-main) ──
const mainAt = html.indexOf('id="ops-main"')
const tilesRegion = mainAt >= 0 ? html.slice(mainAt, Math.max(mainAt, html.indexOf('<section', mainAt))) : ''
const panelRegion = (id) => {
  const start = html.indexOf(`id="${id}"`)
  return start >= 0 ? html.slice(start, Math.max(start, html.indexOf('<section', start))) : ''
}
const bounded = (text, n) => new RegExp(`(?<!\\d)${n}(?!\\d)`).test(text)
const occurrences = (text, token) => {
  const found = []
  let at = text.indexOf(token)
  while (at >= 0) { found.push(at); at = text.indexOf(token, at + token.length) }
  return found
}
/** symmetric windows around every occurrence; pred wins if ANY window passes */
const anyWin = (text, token, pred, pad = 1100) =>
  occurrences(text, token).some((at) => pred(text.slice(Math.max(0, at - pad), at + token.length + pad)))
const scriptStripped = html.replace(/<script[\s\S]*?<\/script>/gi, '')

// ═══ TC-080 [S1] API 计数 ↔ 实数据真值（判据 1：各层级信息与实数据一致） ═══
check(
  page.status === 200 && page2.status === 200 && apiRes.status === 200 && apiRes2.status === 200 &&
    cssStatus === 200 && jsStatus === 200 &&
    api.domain === 'exploration' && api.available === true && typeof api.meta?.generatedAt === 'string',
  'TC-080 [S1]: real-root read battery all 200 + envelope {domain,available,meta} contract',
  `page=${page.status}/${page2.status} api=${apiRes.status}/${apiRes2.status} css=${cssStatus} js=${jsStatus}`
)
check(
  api.data?.hotCount === GT.hot && api.data?.indexCount === GT.index && api.data?.totalCount === GT.total &&
    api.data?.entries?.length === GT.total &&
    api.data?.artifacts?.count === GT.records && api.data?.artifacts?.pairedCount === GT.paired &&
    api.data?.artifacts?.totalFiles === GT.mdTotal &&
    api.data?.zones?.hotPresent === true && api.data?.zones?.indexPresent === true,
  'TC-080 [S1]: API counts equal live-computed ground truth (hot/index/total/records/paired/mdTotal/zones)',
  `api=${JSON.stringify({ hot: api.data?.hotCount, index: api.data?.indexCount, total: api.data?.totalCount, art: api.data?.artifacts?.count, paired: api.data?.artifacts?.pairedCount })} gt=${JSON.stringify(GT)}`
)
{
  const norm = (o) => { const c = structuredClone(o); delete c.meta?.generatedAt; return JSON.stringify(c) }
  check(
    norm(api) === norm(api2),
    'TC-080 [S1]: repeat read is data-stable across requests (only per-request generatedAt may differ)',
    'api1 vs api2 payload drift (meta.generatedAt excluded per tip 20261009T062058Z-QA-9f26)'
  )
}

// ═══ TC-081 [S1] SSR KPI 面 ↔ 实数据（ops-main 锚定区域） ═══
{
  const labelFace = (label, value) => {
    const at = tilesRegion.indexOf(label)
    return at >= 0 && bounded(tilesRegion.slice(Math.max(0, at - 240), at + label.length + 240), value)
  }
  check(
    mainAt >= 0 &&
      labelFace('条目总数', GT.total) && labelFace('热区条目', GT.hot) &&
      labelFace('持久条目', GT.index) && labelFace('产物记录', GT.records) &&
      new RegExp(`(?<!\\d)${GT.paired} 对已配对 summary`).test(tilesRegion),
    `TC-081 [S1]: KPI tile face (anchored after ops-main) shows live ground truth ${GT.total}/${GT.hot}/${GT.index} + ${GT.records}/${GT.paired}`,
    `mainAt=${mainAt} tiles=${tilesRegion.length} chars`
  )
}

// ═══ TC-082 [S1] zone 展开面板 ↔ 实数据（合并=并集 / 空区空态 / 零泄漏） ═══
{
  const totalPanel = panelRegion('exp-total')
  const hotPanel = panelRegion('exp-hot')
  const indexPanel = panelRegion('exp-index')
  const keysOf = (list) => list.map((e) => String(e.key))
  const ownFace =
    keysOf(allEntries).every((k) => totalPanel.includes(k)) &&
    keysOf(hotEntries).every((k) => hotPanel.includes(k)) &&
    keysOf(indexEntries).every((k) => indexPanel.includes(k))
  const leakFace =
    keysOf(indexEntries).every((k) => !hotPanel.includes(k)) &&
    keysOf(hotEntries).every((k) => !indexPanel.includes(k))
  check(
    totalPanel !== '' && hotPanel !== '' && indexPanel !== '' && ownFace && leakFace &&
      totalPanel.includes(`${GT.total} 条`) && hotPanel.includes(`${GT.hot} 条`) && indexPanel.includes(`${GT.index} 条`),
    'TC-082 [S1]: exp-total/exp-hot/exp-index panels carry exactly the real per-zone entries (merge=union, empty zone 0 条, no leakage)',
    `panels=${totalPanel.length}/${hotPanel.length}/${indexPanel.length} chars`
  )
}

// ═══ TC-083 [S1] 条目二级展开（实数据条目）：详情字段 + 跳转/复制双载体 ═══
if (indexEntry) {
  const key = String(indexEntry.key)
  const recordAbs = absPosix(String(indexEntry.path))
  const fileCount = indexEntry.files && typeof indexEntry.files === 'object' ? Object.keys(indexEntry.files).length : 0
  const detailFace = (w) =>
    w.includes(String(indexEntry.brief ?? '')) &&
      w.includes('涉及文件数') && w.includes(`${fileCount} 个`) &&
      w.includes(String(indexEntry.path)) &&
      w.includes(`href="vscode://file/${recordAbs}"`) &&
      w.includes(`data-copy="${recordAbs}"`)
  check(
    anyWin(html, key, detailFace),
    'TC-083 [S1]: real entry second-level detail shows brief/涉及文件数/记录路径 with vscode jump + data-copy carriers to the record file',
    `key=${key} record=${recordAbs}`
  )
} else {
  skip('TC-083 [S1]: real entry second-level detail', 'real cache has no entries at run time (drift guard)')
}

// ═══ TC-084 [S1] 产物对行（孤儿）：无条目 + mtime 近似时间口径 + 路径载体 ═══
if (orphanNames.length > 0) {
  const slug = orphanNames[0].slice(0, -3)
  const artifactRel = relOf(orphanNames[0])
  const summaryRel = `${slug}.summary.md`
  const minute = utcMinute(statSync(join(artDir, orphanNames[0])).mtimeMs)
  check(
    anyWin(html, slug, (w) => /(?<!暂)无条目/.test(w)),
    `TC-084 [S1]: orphan pair ${slug} is listed and marked 「无条目」 on the real page`,
    'orphan mark not found near slug'
  )
  check(
    anyWin(html, slug, (w) => w.includes('文件时间（近似）') && w.includes(minute)) &&
      anyWin(html, slug, (w) => w.includes(artifactRel) && w.includes(`data-copy="${absPosix(artifactRel)}"`)) &&
      anyWin(html, slug, (w) => w.includes(summaryRel)),
    `TC-084 [S1]: orphan pair time face = artifact mtime ${minute} (UTC) + 「文件时间（近似）」, artifact/summary paths with copy carrier`,
    `minute=${minute}`
  )
} else {
  skip('TC-084 [S1]: orphan pair row', 'real cache has no orphan records at run time (drift guard)')
}

// ═══ TC-085 [S1] 产物对行（关联条目）：状态机词汇 + 持久条目 mtime 近似口径 ═══
{
  const tied = tiedNames[0]
  if (tied) {
    const slug = tied.slice(0, -3)
    const entry = entryByRel.get(relOf(tied))
    const expectedState = expectedFreshness(entry)
    const stateMarker =
      expectedState === 'no-list' ? /无清单/ :
      expectedState === 'fresh' ? /(仍?新鲜|fresh|有效|健康|正常)/i :
      /(不新鲜|失效|过期|已变更|变更|漂移|stale|警告|异常)/i
    const zoneBadge = entryByRel.get(relOf(tied)) ? '持久' : ''
    const minute = utcMinute(statSync(join(artDir, tied)).mtimeMs)
    check(
      anyWin(html, slug, (w) => stateMarker.test(w)) &&
        anyWin(html, slug, (w) => zoneBadge === '' || w.includes(zoneBadge)) &&
        anyWin(html, slug, (w) => w.includes('文件时间（近似）') && w.includes(minute)),
      `TC-085 [S1]: entry-tied pair ${slug} shows expected freshness state 「${expectedState === 'no-list' ? '无清单' : expectedState}」 + 持久 zone badge + mtime ${minute} 近似口径 (D3)`,
      `expectedState=${expectedState} minute=${minute}`
    )
    // no-list has a pinned verdict wording on the real page; fresh/stale
    // verdict wordings stay fixture-covered (TC-140/145) — here only the
    // verdict block presence is pinned for those states
    const verdictFace = expectedState === 'no-list' ? '判定：无清单' : '判定：'
    check(
      anyWin(html, slug, (w) => w.includes(verdictFace)),
      `TC-085 [S1]: pair verdict text renders the same state vocabulary (判定：…) as the reader state machine`,
      `expectedState=${expectedState}`
    )
  } else {
    skip('TC-085 [S1]: entry-tied pair row', 'no real record is tied to a cache entry at run time (drift guard)')
  }
}

// ═══ TC-086 [S1] 无 JS 降级基线（实数据） ═══
if (indexEntry) {
  check(
    scriptStripped.includes(String(indexEntry.key)) && scriptStripped.includes(String(indexEntry.brief ?? '')) &&
      scriptStripped.includes('id="entries-flat"') && scriptStripped.includes('无 JS 降级基线') &&
      (orphanNames.length === 0 || scriptStripped.includes(orphanNames[0].slice(0, -3))),
    'TC-086 [S1]: script-stripped SSR still carries entry key/brief (entries-flat) and the orphan slug (pairs-flat)',
    'no-JS degradation face missing real entry info'
  )
} else {
  skip('TC-086 [S1]: no-JS degradation face', 'real cache has no entries at run time (drift guard)')
}

// ═══ TC-087 [S1] 判据2 只读不变量：真实 .rdd/exploration 零回写 ═══
{
  const after = treeSnapshot(explRoot)
  const hardDrift = []
  const softDrift = []
  for (const [rel, was] of snapBefore) {
    const now = after.get(rel)
    const changed = now === undefined || now[0] !== was[0] || now[1] !== was[1] || now[2] !== was[2]
    if (!changed) continue
    if (rel === 'hot.json' || rel === 'index.json' || rel.startsWith('artifacts/')) hardDrift.push(rel)
    else softDrift.push(rel)
  }
  for (const rel of after.keys()) if (!snapBefore.has(rel)) {
    if (rel === 'hot.json' || rel === 'index.json' || rel.startsWith('artifacts/')) hardDrift.push(`${rel} (new)`)
    else softDrift.push(`${rel} (new)`)
  }
  if (softDrift.length > 0) {
    console.log(`INFO  query-log watch: non-criteria files drifted during the battery (concurrent writer, out of 判据2 scope): ${softDrift.join(', ')}`)
  }
  check(
    hardDrift.length === 0,
    'TC-087 [S1]: whole read battery leaves real hot.json/index.json/artifacts/** byte-identical (size+mtime+SHA256 zero-write)',
    `hardDrift=[${hardDrift.join(', ')}]`
  )
}

server.close(() => { process.exitCode = results.some((r) => r.kind === 'FAIL') ? 1 : 0 })
const counts = { total: results.length, pass: results.filter((r) => r.kind === 'PASS').length, fail: results.filter((r) => r.kind === 'FAIL').length, skip: results.filter((r) => r.kind === 'SKIP').length }
console.log(`SUMMARY total=${counts.total} pass=${counts.pass} fail=${counts.fail} skip=${counts.skip}`)

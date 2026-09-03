#!/usr/bin/env node
// Precision-ranking behavior test (run after `npm run build`: node tests/search-ranking.mjs).
//
// Covers the frozen F1-F8 formulas on a fixed fixture corpus:
//   1. TS pipeline: search-config merge + fail-soft, tokenizer (F3), lexical
//      ordering (F4), RRF exact values + F8 tie-breaks via stub recallers,
//      Top-K truncation, two-branch miss semantics, the vector path offline
//      via a mocked fetch (F2/F5/F6 + cosine gate), and recaller pluggability.
//   2. PS/TS consistency (runs when the rdd-engine checkout, git, and a
//      PowerShell runtime are discoverable; env RDD_ENGINE_ROOT overrides the
//      lookup): drives the engine CLI on the SAME fixture and asserts the two
//      implementations agree on ordering, Top-K, scores, and miss behavior.
// Set RDD_SEARCH_TEST_KEEP=1 to keep the fixture directory for inspection.
// @module @coderrdd/dsh-rdd-explore/search-ranking-test

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SEARCH_CONFIG_DEFAULTS,
  mergedFresh,
  readSearchConfig,
  readVectors,
  runRecallPipeline,
  searchTextOf,
  textHashOf,
  tokenizeSearchText,
  vectorsPathOf,
  writeVectors,
} from '../lib/cache.js'
import { lexicalRecaller } from '../lib/recallers/lexical.js'
import { vectorRecaller } from '../lib/recallers/vector.js'

const pkgDir = dirname(fileURLToPath(import.meta.url))
let failures = 0
const check = (name, condition, detail = '') => {
  const ok = condition === true
  if (!ok) failures += 1
  console.log(`${ok ? 'ok' : 'FAIL'} - ${name}${ok || detail === '' ? '' : ` :: ${detail}`}`)
}
const approx = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps
const round6 = v => Math.round(v * 1e6) / 1e6

// ---------------------------------------------------------------------------
// Fixture corpus (shared verbatim with the PS engine runs below)
// ---------------------------------------------------------------------------

const FIXTURE_DOCS = [
  { key: 'auth-middleware', tags: ['auth', 'middleware', 'security'], brief: 'jwt token verify chain and refresh', anchor: 'a1.txt', origin: 'persistent' },
  { key: 'auth-cn-middleware', tags: ['认证', '鉴权', 'auth', 'middleware'], brief: 'JWT 签发验证与刷新', anchor: 'a2.txt', origin: 'persistent' },
  { key: 'db-pool', tags: ['database', 'pool'], brief: 'connection pool sizing', anchor: 'a3.txt', origin: 'persistent' },
  { key: 'cache-redis', tags: ['cache', 'redis'], brief: 'redis cache layer', anchor: 'a1.txt', origin: 'persistent' },
  { key: 'session-store', tags: ['auth', 'session'], brief: 'session storage', anchor: 'a2.txt', origin: 'hot', registeredAt: '2026-08-29T10:00:00.000Z' },
]

const fixtureRoot = process.env.RDD_SEARCH_TEST_TMP !== undefined
  ? resolve(process.env.RDD_SEARCH_TEST_TMP)
  : mkdtempSync(join(tmpdir(), 'rdd-search-ranking-'))
const explorationDir = join(fixtureRoot, '.rdd', 'exploration')

const fileSha256 = path => `sha256:${createHash('sha256').update(readFileSync(path)).digest('hex')}`

function buildFixture() {
  mkdirSync(join(explorationDir, 'artifacts'), { recursive: true })
  for (const anchor of ['a1.txt', 'a2.txt', 'a3.txt']) {
    writeFileSync(join(fixtureRoot, anchor), `anchor ${anchor}\n`)
  }
  const indexEntries = []
  const hotEntries = []
  for (const doc of FIXTURE_DOCS) {
    writeFileSync(join(explorationDir, 'artifacts', `${doc.key}.md`), `# ${doc.key}\n`)
    writeFileSync(join(explorationDir, 'artifacts', `${doc.key}.summary.md`), `# ${doc.key} summary\n`)
    const entry = {
      key: doc.key,
      tags: [...doc.tags],
      brief: doc.brief,
      path: `.rdd/exploration/artifacts/${doc.key}.md`,
      files: { [doc.anchor]: fileSha256(join(fixtureRoot, doc.anchor)) },
    }
    if (doc.origin === 'hot') hotEntries.push({ ...entry, registeredAt: doc.registeredAt })
    else indexEntries.push(entry)
  }
  writeFileSync(join(explorationDir, 'index.json'), JSON.stringify({ entries: indexEntries }))
  writeFileSync(join(explorationDir, 'hot.json'), JSON.stringify({ entries: hotEntries }))
}

const runPipeline = async (query, options = {}) => {
  const config = options.config !== undefined ? options.config : await readSearchConfig(explorationDir)
  const merged = options.merged !== undefined ? options.merged : (await mergedFresh(explorationDir, fixtureRoot)).results
  return runRecallPipeline({
    query,
    merged,
    config,
    explorationDir,
    recallers: options.recallers !== undefined ? options.recallers : [lexicalRecaller, vectorRecaller],
  })
}

// ---------------------------------------------------------------------------
// TS-side checks
// ---------------------------------------------------------------------------

async function runTsChecks() {
  // --- search-config defaults & merge ------------------------------------
  const defaults = await readSearchConfig(explorationDir)
  check('defaults: no config file -> built-in defaults',
    defaults.topK === SEARCH_CONFIG_DEFAULTS.topK
    && defaults.recallDepth === SEARCH_CONFIG_DEFAULTS.recallDepth
    && defaults.rrfK === SEARCH_CONFIG_DEFAULTS.rrfK
    && defaults.recallers.lexical.bm25K1 === SEARCH_CONFIG_DEFAULTS.recallers.lexical.bm25K1
    && defaults.recallers.vector.minCosine === SEARCH_CONFIG_DEFAULTS.recallers.vector.minCosine
    && defaults.recallers.vector.enabled === 'auto')

  writeFileSync(join(explorationDir, 'search-config.json'), JSON.stringify({
    topK: 2,
    rrfK: 'not-a-number',
    recallers: { lexical: { bm25K1: 2.0, weight: 1.5 }, vector: { minCosine: 0.5 } },
    unknownField: { ignored: true },
  }))
  const merged1 = await readSearchConfig(explorationDir)
  check('config merge: valid overrides applied, invalid/unknown ignored',
    merged1.topK === 2 && merged1.rrfK === SEARCH_CONFIG_DEFAULTS.rrfK
    && merged1.recallers.lexical.bm25K1 === 2.0 && merged1.recallers.lexical.weight === 1.5
    && merged1.recallers.vector.minCosine === 0.5)

  writeFileSync(join(explorationDir, 'search-config.json'), '{{{ corrupt')
  const merged2 = await readSearchConfig(explorationDir)
  check('config corrupt -> fail-soft defaults', merged2.topK === SEARCH_CONFIG_DEFAULTS.topK)
  rmSync(join(explorationDir, 'search-config.json'), { force: true })

  // --- tokenizer (F3) ------------------------------------------------------
  const tokens = tokenizeSearchText('认证Auth中间件 jwt-token')
  check('F3 tokenizer: ASCII runs + CJK whole-run + adjacent bigrams',
    JSON.stringify(tokens) === JSON.stringify(['认证', '认证', 'auth', '中间件', '中间', '间件', 'jwt', 'token']),
    JSON.stringify(tokens))

  // --- lexical path on the fixture (F1/F4 + gate) ---------------------------
  const hitEn = await runPipeline('auth middleware')
  check('lexical: BM25 ordering + RRF ranks (auth middleware)',
    JSON.stringify(hitEn.results.map(r => r.key)) === JSON.stringify(['auth-middleware', 'auth-cn-middleware', 'session-store'])
    && hitEn.results[0].score === round6(1 / 61)
    && hitEn.results[1].score === round6(1 / 62)
    && hitEn.results[2].score === round6(1 / 63)
    && hitEn.results.every(r => r.recalledBy.length === 1 && r.recalledBy[0] === 'lexical'),
    JSON.stringify(hitEn.results.map(r => [r.key, r.score])))
  check('lexical: rankMeta fused/returned/recallers',
    hitEn.rankMeta.fused === 3 && hitEn.rankMeta.returned === 3
    && hitEn.rankMeta.recallers.some(o => o.name === 'lexical' && o.status === 'ok' && o.qualified === 3)
    && hitEn.rankMeta.recallers.some(o => o.name === 'vector' && o.status === 'disabled'))

  const hitCn = await runPipeline('认证 鉴权')
  check('lexical: CJK query recalls the Chinese-tagged doc only',
    hitCn.results.length === 1 && hitCn.results[0].key === 'auth-cn-middleware',
    JSON.stringify(hitCn.results.map(r => r.key)))

  const miss = await runPipeline('zzzqqq xyzzy')
  check('two-branch: unrelated query -> empty results (interface-level miss)',
    miss.results.length === 0 && miss.rankMeta.fused === 0
    && miss.rankMeta.recallers.find(o => o.name === 'lexical').qualified === 0)

  // --- RRF + F8 tie-breaks via stub recallers (extension point) -------------
  const stub = (name, qualified) => ({ name, defaultEnabled: true, run: async () => ({ name, scores: {}, qualified }) })
  const fakeMerged = [
    { entry: { key: 'a-key', tags: ['x'], brief: 'a', path: 'a.md', files: {} }, origin: 'persistent' },
    { entry: { key: 'b-key', tags: ['x'], brief: 'b', path: 'b.md', files: {} }, origin: 'hot', registeredAt: '2026-01-01T00:00:00.000Z' },
  ]
  const tie = await runPipeline('q', { merged: fakeMerged, recallers: [stub('one', ['a-key']), stub('two', ['b-key'])] })
  check('F7+F8: equal single-path contributions tie; hot origin wins',
    tie.results.length === 2 && tie.results[0].key === 'b-key' && tie.results[1].key === 'a-key'
    && tie.results[0].score === round6(1 / 61) && tie.results[1].score === round6(1 / 61)
    && tie.results[0].recalledBy.join(',') === 'two' && tie.results[1].recalledBy.join(',') === 'one',
    JSON.stringify(tie.results.map(r => [r.key, r.score, r.recalledBy])))

  const both = await runPipeline('q', { merged: fakeMerged, recallers: [stub('one', ['a-key', 'b-key']), stub('two', ['a-key'])] })
  check('F7: multi-path accumulation is additive (a: 1/61+1/61 > b: 1/62)',
    both.results[0].key === 'a-key' && both.results[0].score === round6(1 / 61 + 1 / 61)
    && both.results[1].key === 'b-key' && both.results[1].score === round6(1 / 62),
    JSON.stringify(both.results.map(r => [r.key, r.score])))

  const tieKeys = await runPipeline('q', {
    merged: [
      { entry: { key: 'zz', tags: [], brief: '', path: 'z.md', files: {} }, origin: 'persistent' },
      { entry: { key: 'aa', tags: [], brief: '', path: 'a.md', files: {} }, origin: 'persistent' },
    ],
    recallers: [stub('one', ['zz']), stub('two', ['aa'])],
  })
  check('F8: same score + same origin -> key ordinal ASC',
    tieKeys.results[0].key === 'aa' && tieKeys.results[1].key === 'zz')

  const baseConfig = await readSearchConfig(explorationDir)
  const topK2 = await runPipeline('auth middleware cache redis database pool', { config: { ...baseConfig, topK: 2 } })
  check('Top-K truncation (topK=2 over 5 fused)', topK2.rankMeta.fused === 5 && topK2.results.length === 2)

  // --- vector path offline: F2/F5/F6 + cosine gate via mocked fetch ---------
  const vectorConfig = {
    topK: 5, recallDepth: 20, rrfK: 60,
    recallers: {
      lexical: SEARCH_CONFIG_DEFAULTS.recallers.lexical,
      vector: { enabled: true, weight: 1.0, endpoint: 'http://127.0.0.1:1/embeddings', model: 'm1', dimensions: 3, minCosine: 0.30, timeoutSeconds: 5 },
    },
  }
  const docEntry = doc => ({
    key: doc.key,
    textHash: textHashOf(searchTextOf(doc.key, doc.tags, doc.brief)),
    model: 'm1',
    vector: doc.key === 'auth-middleware' ? [1, 0, 0] : [0, 1, 0],
  })
  await writeVectors(explorationDir, [
    docEntry(FIXTURE_DOCS[0]),
    docEntry(FIXTURE_DOCS[1]),
    { key: 'db-pool', textHash: 'sha256:stale-hash-for-invalidation-test', model: 'm1', vector: [1, 0, 0] },
  ])
  const realFetch = globalThis.fetch
  globalThis.fetch = async () => new Response(
    JSON.stringify({ data: [{ embedding: [1, 0, 0] }] }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  )
  try {
    const vecHit = await runPipeline('semantic query with no lexical overlap', { config: vectorConfig })
    check('vector: cosine gate + F6 stale-hash filter, offline mocked F5',
      vecHit.results.length === 1 && vecHit.results[0].key === 'auth-middleware'
      && vecHit.results[0].recalledBy.join(',') === 'vector'
      && vecHit.results[0].score === round6(1 / 61)
      && vecHit.rankMeta.recallers.find(o => o.name === 'vector').status === 'ok',
      JSON.stringify(vecHit.results.map(r => [r.key, r.score, r.recalledBy])))

    await writeVectors(explorationDir, [{
      key: 'auth-middleware',
      textHash: textHashOf(searchTextOf('auth-middleware', ['auth', 'middleware', 'security'], 'jwt token verify chain and refresh')),
      model: 'm1',
      vector: [1, 0],
    }])
    const vecDim = await runPipeline('semantic query with no lexical overlap', { config: vectorConfig })
    check('vector: F6 dimension mismatch -> silently skipped',
      vecDim.results.length === 0 && vecDim.rankMeta.recallers.find(o => o.name === 'vector').qualified === 0)
  } finally {
    globalThis.fetch = realFetch
  }
  rmSync(vectorsPathOf(explorationDir), { force: true })
}

// ---------------------------------------------------------------------------
// PS/TS consistency: drive the engine CLI on the fixture and compare
// ---------------------------------------------------------------------------

function discoverEngineRoot() {
  const candidates = [
    process.env.RDD_ENGINE_ROOT,
    resolve(pkgDir, '..', 'rdd-engine'),
    resolve(pkgDir, '..', '..', '..', 'rdd-engine'),
    resolve(pkgDir, '..', '..', '..', '..', '..', 'codeRDD', 'rdd-engine'),
  ].filter(Boolean)
  return candidates.find(root => existsSync(join(root, 'scripts', 'explore.ps1')))
}

async function runPsConsistencyChecks() {
  const engineRoot = discoverEngineRoot()
  const psBinary = process.platform === 'win32' ? 'powershell' : 'pwsh'
  if (engineRoot === undefined) {
    console.log('SKIP - PS/TS consistency: rdd-engine checkout not found (set RDD_ENGINE_ROOT to enable)')
    return
  }
  const gitProbe = spawnSync('git', ['init'], { cwd: fixtureRoot, stdio: 'ignore' })
  if (gitProbe.error !== undefined || gitProbe.status !== 0) {
    console.log('SKIP - PS/TS consistency: git unavailable')
    return
  }
  const psProbe = spawnSync(psBinary, ['-NoProfile', '-Command', 'exit 0'], { stdio: 'ignore' })
  if (psProbe.error !== undefined) {
    console.log(`SKIP - PS/TS consistency: ${psBinary} unavailable`)
    return
  }

  const enginePs1 = join(engineRoot, 'scripts', 'explore.ps1')
  const runEngine = (query) => {
    const outFile = join(fixtureRoot, 'ps-out.json')
    const script = `& '${enginePs1}' -Type search -Query '${query.replaceAll("'", "''")}' | Out-File -FilePath '${outFile}' -Encoding utf8`
    const run = spawnSync(psBinary, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], { cwd: fixtureRoot, stdio: 'ignore' })
    if (run.status !== 0) return { error: `engine exited ${String(run.status)}` }
    try {
      const parsed = JSON.parse(readFileSync(outFile, 'utf8').replace(/^\uFEFF/, ''))
      if (parsed.success !== true) return { error: `engine reported failure: ${JSON.stringify(parsed.error)}` }
      return { data: parsed.data }
    } catch (error) {
      return { error: `unparseable engine output: ${String(error)}` }
    }
  }

  for (const query of ['auth middleware', '认证 鉴权 jwt', 'auth middleware cache redis database pool']) {
    const ps = runEngine(query)
    if (ps.error !== undefined) {
      check(`PS/TS consistency (${query})`, false, ps.error)
      continue
    }
    const ts = await runPipeline(query)
    const psOrder = ps.data.results.map(r => r.key)
    const tsOrder = ts.results.map(r => r.key)
    const scoresMatch = ps.data.results.every((r, i) => approx(r.score, ts.results[i]?.score ?? Number.NaN))
    check(`PS/TS consistency (${query}): ordering + Top-K + scores`,
      JSON.stringify(psOrder) === JSON.stringify(tsOrder) && scoresMatch,
      `ps=${JSON.stringify(ps.data.results.map(r => [r.key, r.score]))} ts=${JSON.stringify(ts.results.map(r => [r.key, r.score]))}`)
    check(`PS/TS consistency (${query}): rankMeta counts`,
      ps.data.rankMeta.fused === ts.rankMeta.fused && ps.data.rankMeta.returned === ts.rankMeta.returned,
      `ps=${JSON.stringify(ps.data.rankMeta)} ts=${JSON.stringify(ts.rankMeta)}`)
  }

  const psMiss = runEngine('zzzqqq xyzzy')
  const tsMiss = await runPipeline('zzzqqq xyzzy')
  check('PS/TS consistency: miss query -> both empty + PS attaches dispatchPrompt',
    psMiss.error === undefined && psMiss.data.results.length === 0 && tsMiss.results.length === 0
    && typeof psMiss.data.dispatchPrompt === 'string' && psMiss.data.dispatchPrompt.length > 0,
    psMiss.error ?? 'mismatch')

  check('fixture intact after PS runs (vectors sidecar untouched)',
    (await readVectors(explorationDir)).length === 0)
}

buildFixture()
runTsChecks()
  .then(runPsConsistencyChecks)
  .then(() => {
    if (process.env.RDD_SEARCH_TEST_KEEP !== '1') rmSync(fixtureRoot, { recursive: true, force: true })
    console.log(failures === 0 ? 'search-ranking: all checks pass' : `search-ranking: ${failures} FAIL`)
    process.exit(failures === 0 ? 0 : 1)
  })
  .catch(error => {
    console.error('search-ranking: crashed', error)
    process.exit(1)
  })

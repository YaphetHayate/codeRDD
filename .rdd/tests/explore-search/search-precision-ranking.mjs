#!/usr/bin/env node
// QA acceptance tests for requirement "search-precision-ranking" (2026-08-29).
// Feature: explore-search. Run: node .rdd/tests/explore-search/search-precision-ranking.mjs
//
// Lives beside its case spec (cases.json) so the future visualization panel
// can scan ONE directory for spec + code + results. Machine-readable results:
// pass `--report <path>` to emit a per-TC status JSON (pass/fail/skip/partial
// + failed/skipped check details) for the panel to consume.
//
// Black-box, interface-level: each case builds an ISOLATED throwaway git repo
// (dual-zone exploration index + artifacts), drives the engine CLI
// (rdd-engine/scripts/explore.ps1 / explore-store.ps1) exactly like a real
// caller, and asserts ONLY what the acceptance criteria demand — never the
// internals. AC-10 (frozen PS/TS contract parity with the dsh plugin) is
// covered by running the dsh-side tests/search-ranking.mjs separately.
//
// PowerShell output is captured via Out-File (not piped stdio) to dodge both
// the PS 5.1 console-codepage maze and harness pipe restrictions; the JSON is
// read back with the BOM stripped.
//
// Vector-path checks that need a REAL HTTP round trip are guarded by a
// loopback probe: inside sandboxes that block child-process loopback sockets
// they report SKIP (run this file from a plain terminal for full coverage);
// everything that needs no network always runs.
//
// Set QA_SEARCH_TEST_KEEP=1 to keep the last fixture for inspection.

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const thisDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(thisDir, '..', '..', '..')
const engineRoot = join(repoRoot, 'rdd-engine')
const explorePs1 = join(engineRoot, 'scripts', 'explore.ps1')
const storePs1 = join(engineRoot, 'scripts', 'explore-store.ps1')
const psBinary = process.platform === 'win32' ? 'powershell' : 'pwsh'

// --- TC-level result collection (feeds --report for the visualization panel)
const ARCHIVE = '2026-08-29-search-precision-ranking'
const FEATURE = 'explore-search'
let failures = 0
let currentTc = null
const tcRecords = new Map() // tcId -> { checks: [{name, status, detail?}] }
const recordCheck = (name, status, detail) => {
  if (currentTc === null) return
  if (!tcRecords.has(currentTc)) tcRecords.set(currentTc, { checks: [] })
  tcRecords.get(currentTc).checks.push({ name, status, ...(detail !== undefined && detail !== '' ? { detail: String(detail) } : {}) })
}

const check = (name, condition, detail) => {
  const ok = condition === true
  if (!ok) failures += 1
  const suffix = ok || detail === undefined || detail === '' ? '' : ` :: ${detail}`
  console.log(`${ok ? 'ok' : 'FAIL'} - ${name}${suffix}`)
  recordCheck(name, ok ? 'pass' : 'fail', ok ? undefined : detail)
}
const skip = (name, reason) => {
  console.log(`SKIP - ${name} :: ${reason}`)
  recordCheck(name, 'skip', reason)
}
const approx = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps
const round6 = v => Math.round(v * 1e6) / 1e6

const reportPath = (() => {
  const idx = process.argv.indexOf('--report')
  return idx !== -1 && process.argv[idx + 1] !== undefined ? resolve(process.argv[idx + 1]) : null
})()

function writeReport() {
  if (reportPath === null) return
  const cases = []
  for (const [id, rec] of tcRecords) {
    const failed = rec.checks.filter(c => c.status === 'fail')
    const skipped = rec.checks.filter(c => c.status === 'skip')
    const status = failed.length > 0 ? 'fail'
      : skipped.length > 0 && skipped.length === rec.checks.length ? 'skip'
        : skipped.length > 0 ? 'partial' : 'pass'
    cases.push({
      id,
      status,
      checks: { total: rec.checks.length, passed: rec.checks.length - failed.length - skipped.length, failed: failed.length, skipped: skipped.length },
      issues: [...failed, ...skipped],
    })
  }
  const summary = {
    total: cases.length,
    passed: cases.filter(c => c.status === 'pass').length,
    failed: cases.filter(c => c.status === 'fail').length,
    skipped: cases.filter(c => c.status === 'skip').length,
    partial: cases.filter(c => c.status === 'partial').length,
  }
  const payload = { generatedAt: new Date().toISOString(), archive: ARCHIVE, feature: FEATURE, summary, cases }
  writeFileSync(reportPath, JSON.stringify(payload, null, 2))
  console.log(`report written: ${reportPath}`)
}

// ---------------------------------------------------------------------------
// Fixture: an isolated git repo with a dual-zone exploration cache
// ---------------------------------------------------------------------------

const BASE_DOCS = [
  { key: 'auth-middleware', tags: ['auth', 'middleware', 'security'], brief: 'jwt token verify chain and refresh', anchor: 'a1.txt', origin: 'persistent' },
  { key: 'auth-cn-middleware', tags: ['认证', '鉴权', 'auth', 'middleware'], brief: 'JWT 签发验证与刷新', anchor: 'a2.txt', origin: 'persistent' },
  { key: 'db-pool', tags: ['database', 'pool'], brief: 'connection pool sizing', anchor: 'a3.txt', origin: 'persistent' },
  { key: 'cache-redis', tags: ['cache', 'redis'], brief: 'redis cache layer', anchor: 'a1.txt', origin: 'persistent' },
  { key: 'session-store', tags: ['auth', 'session'], brief: 'session storage', anchor: 'a2.txt', origin: 'hot', registeredAt: '2026-08-29T10:00:00.000Z' },
]

// Cross-language probe query: shares ZERO F3 tokens (whole CJK runs and all
// adjacent bigrams) with every F1 text in BASE_DOCS, so the lexical path can
// never recall anything — only the vector path can.
const CN_QUERY = '会话保持策略'

const fileSha256 = path => `sha256:${createHash('sha256').update(readFileSync(path)).digest('hex')}`

function buildFixture(docs = BASE_DOCS) {
  const root = process.env.QA_SEARCH_TEST_TMP !== undefined
    ? resolve(process.env.QA_SEARCH_TEST_TMP)
    : mkdtempSync(join(tmpdir(), 'rdd-qa-search-'))
  const gitInit = spawnSync('git', ['init'], { cwd: root, stdio: 'ignore' })
  if (gitInit.error !== undefined || gitInit.status !== 0) throw new Error('git init failed in fixture')
  const explorationDir = join(root, '.rdd', 'exploration')
  mkdirSync(join(explorationDir, 'artifacts'), { recursive: true })
  for (const anchor of ['a1.txt', 'a2.txt', 'a3.txt']) {
    writeFileSync(join(root, anchor), `anchor ${anchor}\n`)
  }
  const indexEntries = []
  const hotEntries = []
  for (const doc of docs) {
    writeFileSync(join(explorationDir, 'artifacts', `${doc.key}.md`), `# ${doc.key}\n`)
    writeFileSync(join(explorationDir, 'artifacts', `${doc.key}.summary.md`), `# ${doc.key} summary\n`)
    const entry = {
      key: doc.key,
      tags: [...doc.tags],
      brief: doc.brief,
      path: `.rdd/exploration/artifacts/${doc.key}.md`,
      files: { [doc.anchor]: fileSha256(join(root, doc.anchor)) },
    }
    if (doc.origin === 'hot') hotEntries.push({ ...entry, registeredAt: doc.registeredAt })
    else indexEntries.push(entry)
  }
  writeFileSync(join(explorationDir, 'index.json'), JSON.stringify({ entries: indexEntries }))
  writeFileSync(join(explorationDir, 'hot.json'), JSON.stringify({ entries: hotEntries }))
  return { root, explorationDir }
}

const searchTextOf = (key, tags, brief) => `${key}\n${tags.join(',')}\n${brief}`
const textHashOf = text => `sha256:${createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex')}`

function writeSearchConfig(explorationDir, config) {
  writeFileSync(join(explorationDir, 'search-config.json'), JSON.stringify(config))
}

// Drive a .ps1 via -Command (DSH-tested quoting pattern); output lands in a
// file because piped stdio is both encoding-fragile and pipe-restricted.
function runScript(scriptPath, args, cwd, envExtra = {}) {
  const outFile = join(cwd, 'ps-out.json')
  const argText = args.map(([name, value]) => `-${name} '${String(value).replaceAll("'", "''")}'`).join(' ')
  const script = `& '${scriptPath}' ${argText} | Out-File -FilePath '${outFile}' -Encoding utf8 ; exit $LASTEXITCODE`
  const run = spawnSync(psBinary, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { cwd, stdio: 'ignore', env: { ...process.env, ...envExtra } })
  let payload = null
  if (existsSync(outFile)) {
    try {
      payload = JSON.parse(readFileSync(outFile, 'utf8').replace(/^\uFEFF/, ''))
    } catch { payload = null }
  }
  return { status: run.status, payload }
}

const search = (root, query, envExtra = {}) =>
  runScript(explorePs1, [['Type', 'search'], ['Query', query]], root, envExtra)
const explore = (root, query, envExtra = {}) =>
  runScript(explorePs1, [['Type', 'explore'], ['Query', query]], root, envExtra)

// Minimal offline embedding endpoint: always answers with QUERY_VECTOR and
// counts requests so tests can assert "no idle API call" (F6 all-stale gate).
const QUERY_VECTOR = [1, 0, 0]
function startEmbedStub() {
  let requests = 0
  const server = createServer((req, res) => {
    requests += 1
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ data: [{ embedding: QUERY_VECTOR }] }))
    })
  })
  return new Promise(resolveListener => {
    server.listen(0, '127.0.0.1', () => {
      resolveListener({
        endpoint: `http://127.0.0.1:${server.address().port}/embeddings`,
        requestCount: () => requests,
        close: () => new Promise(done => server.close(() => done())),
      })
    })
  })
}

// Can a child PowerShell process actually reach the stub over loopback?
// (Some sandboxes block child-process loopback sockets; vector HTTP checks
// degrade to SKIP there instead of producing false failures.)
async function probePsLoopback(stub) {
  const script = [
    `try {`,
    `  Invoke-RestMethod -Method Post -Uri '${stub.endpoint}' -ContentType 'application/json' -Body '{}' -TimeoutSec 3 | Out-Null`,
    `  exit 0`,
    `} catch {`,
    `  exit 1`,
    `}`,
  ].join('\n')
  const run = spawnSync(psBinary, ['-NoProfile', '-Command', script], { stdio: 'ignore' })
  if (run.error !== undefined) return false
  return run.status === 0
}

// A complete vector config aimed at the stub, plus the sidecar rows matching
// the FROZEN F1 text hash so the F6 filter accepts them.
function armVectorPath(explorationDir, stub, docRows) {
  writeSearchConfig(explorationDir, {
    recallers: {
      vector: { enabled: true, weight: 1.0, endpoint: stub.endpoint, model: 'm1', dimensions: 3, minCosine: 0.30, timeoutSeconds: 5 },
    },
  })
  const entries = docRows.map(row => ({
    key: row.key,
    textHash: textHashOf(searchTextOf(row.key, row.tags, row.brief)),
    model: 'm1',
    vector: row.vector,
  }))
  writeFileSync(join(explorationDir, 'vectors.json'), JSON.stringify({ entries }))
}

const docRow = (docs, key) => {
  const doc = docs.find(d => d.key === key)
  if (doc === undefined) throw new Error(`fixture doc not found: ${key}`)
  return { key: doc.key, tags: [...doc.tags], brief: doc.brief }
}

// ---------------------------------------------------------------------------
// TC-001 (AC-1/AC-2, positive, P0): lexical hit — ranked results, no
// dispatchPrompt on hit
// ---------------------------------------------------------------------------

async function testSearchHitReturnsRankedResults() {
  const { root } = buildFixture()
  const run = search(root, 'auth middleware')

  check('TC-001: engine exits 0 and reports success', run.status === 0 && run.payload?.success === true,
    `status=${run.status}`)
  const results = run.payload?.data?.results ?? []
  check('TC-001: results non-empty and bounded by default K=5',
    results.length > 0 && results.length <= 5, `len=${results.length}`)
  check('TC-001: every entry carries the location contract fields',
    results.every(r => typeof r.key === 'string' && Array.isArray(r.tags) && typeof r.brief === 'string'
      && typeof r.summaryPath === 'string' && typeof r.fullPath === 'string'
      && (r.origin === 'hot' || r.origin === 'persistent')
      && typeof r.score === 'number' && Array.isArray(r.recalledBy)),
    JSON.stringify(results[0]))
  const scores = results.map(r => r.score)
  check('TC-001: scores are strictly non-increasing (fused rank order)',
    scores.every((s, i) => i === 0 || scores[i - 1] >= s), JSON.stringify(scores))
  check('TC-001: hit response has NO dispatchPrompt (two-branch protocol)',
    run.payload.data.dispatchPrompt === undefined)
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-002 (AC-3, negative, P0): unrelated query -> miss + dispatchPrompt
// ---------------------------------------------------------------------------

async function testMissAttachesDispatchPrompt() {
  const { root } = buildFixture()
  const run = search(root, 'zzzqqq xyzzy')

  check('TC-002: unrelated query -> empty results', run.status === 0 && (run.payload?.data?.results ?? []).length === 0,
    `status=${run.status}`)
  const prompt = run.payload?.data?.dispatchPrompt
  check('TC-002: miss attaches a non-empty dispatchPrompt',
    typeof prompt === 'string' && prompt.length > 0)
  check('TC-002: dispatchPrompt embeds the worker protocol (guide + register line)',
    typeof prompt === 'string' && prompt.includes('exploration-guide.md') && prompt.includes('explore-store.cmd -Type register'),
    prompt?.slice(0, 120))
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-003 (AC-1, boundary, P0): Top-K truncation, configured and default
// ---------------------------------------------------------------------------

async function testTopKTruncation() {
  const wideQuery = 'auth middleware cache redis database pool'

  const { root } = buildFixture()
  writeSearchConfig(root + '/.rdd/exploration', { topK: 2 })
  const capped = search(root, wideQuery)
  check('TC-003: configured topK=2 truncates 5 fused entries to 2',
    capped.payload?.data?.rankMeta?.fused === 5 && capped.payload?.data?.results?.length === 2,
    JSON.stringify(capped.payload?.data?.rankMeta))
  rmSync(root, { recursive: true, force: true })

  const { root: root2 } = buildFixture()
  const deflt = search(root2, wideQuery)
  check('TC-003: default (no config file) K=5 keeps all 5 fused entries',
    deflt.payload?.data?.rankMeta?.fused === 5 && deflt.payload?.data?.results?.length === 5,
    JSON.stringify(deflt.payload?.data?.rankMeta))
  rmSync(root2, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-004 (AC-4, positive, P0): cross-language recall via the vector path
// ---------------------------------------------------------------------------

async function testCrossLanguageVectorRecall() {
  const stub = await startEmbedStub()
  const httpOk = await probePsLoopback(stub)
  if (!httpOk) {
    skip('TC-004: cross-language vector recall (real HTTP round trip)',
      'child PowerShell cannot reach the loopback stub in this sandbox — run from a plain terminal for full coverage')
  }
  try {
    if (httpOk) {
      const { root, explorationDir } = buildFixture()
      armVectorPath(explorationDir, stub, [
        { ...docRow(BASE_DOCS, 'auth-middleware'), vector: [1, 0, 0] },
        { ...docRow(BASE_DOCS, 'db-pool'), vector: [0, 1, 0] },
      ])
      const before = stub.requestCount()
      const run = search(root, CN_QUERY, { RDD_EMBED_APIKEY: 'qa-test-key' })

      check('TC-004: cross-language query recalled via the vector path only',
        run.status === 0 && run.payload?.data?.results?.length === 1
          && run.payload.data.results[0].key === 'auth-middleware'
          && run.payload.data.results[0].recalledBy.join(',') === 'vector',
        JSON.stringify(run.payload?.data?.results?.map(r => [r.key, r.recalledBy])))
      check('TC-004: vector recaller outcome is ok in rankMeta',
        run.payload?.data?.rankMeta?.recallers?.some(o => o.name === 'vector' && o.status === 'ok' && o.qualified === 1),
        JSON.stringify(run.payload?.data?.rankMeta?.recallers))
      check('TC-004: exactly one embedding API call for the query',
        stub.requestCount() - before === 1, `delta=${stub.requestCount() - before}`)
      rmSync(root, { recursive: true, force: true })
    }

    // No-idle guarantee (no network needed): all sidecar hashes stale ->
    // F6 filters everything -> recaller reports ok/0 and the interface still
    // answers miss WITHOUT any API call.
    const { root: root2, explorationDir: dir2 } = buildFixture()
    writeSearchConfig(dir2, {
      recallers: { vector: { enabled: true, endpoint: stub.endpoint, model: 'm1', dimensions: 3, minCosine: 0.30, timeoutSeconds: 5 } },
    })
    writeFileSync(join(dir2, 'vectors.json'), JSON.stringify({ entries: [
      { key: 'auth-middleware', textHash: 'sha256:stale', model: 'm1', vector: [1, 0, 0] },
    ] }))
    const idleBefore = stub.requestCount()
    const idle = search(root2, CN_QUERY, { RDD_EMBED_APIKEY: 'qa-test-key' })
    check('TC-004: F6 all-stale -> vector ok with 0 qualified, interface miss, zero API calls',
      idle.status === 0 && (idle.payload?.data?.results ?? []).length === 0
        && idle.payload?.data?.rankMeta?.recallers?.some(o => o.name === 'vector' && o.status === 'ok' && o.qualified === 0)
        && stub.requestCount() === idleBefore,
      `meta=${JSON.stringify(idle.payload?.data?.rankMeta)} requests=${stub.requestCount() - idleBefore}`)
    rmSync(root2, { recursive: true, force: true })
  } finally {
    await stub.close()
  }
}

// ---------------------------------------------------------------------------
// TC-005 (AC-5, negative/degradation, P0): pluggable enable/disable + failure
// ---------------------------------------------------------------------------

async function testRecallerDisableAndFailureDegrade() {
  // (a) lexical disabled -> vector alone still serves the interface (HTTP)
  const stub = await startEmbedStub()
  const httpOk = await probePsLoopback(stub)
  if (!httpOk) {
    skip('TC-005a: lexical disabled -> vector path alone serves the interface',
      'child PowerShell cannot reach the loopback stub in this sandbox — run from a plain terminal for full coverage')
  } else {
    try {
      const { root, explorationDir } = buildFixture()
      armVectorPath(explorationDir, stub, [
        { ...docRow(BASE_DOCS, 'auth-middleware'), vector: [1, 0, 0] },
      ])
      writeSearchConfig(explorationDir, {
        topK: 5,
        recallers: {
          lexical: { enabled: false },
          vector: { enabled: true, endpoint: stub.endpoint, model: 'm1', dimensions: 3, minCosine: 0.30, timeoutSeconds: 5 },
        },
      })
      const lexOff = search(root, 'auth middleware', { RDD_EMBED_APIKEY: 'qa-test-key' })
      check('TC-005a: lexical disabled -> vector path alone still returns results',
        lexOff.status === 0 && lexOff.payload?.data?.results?.length >= 1
          && lexOff.payload.data.results.every(r => r.recalledBy.join(',') === 'vector'),
        JSON.stringify(lexOff.payload?.data?.results?.map(r => [r.key, r.recalledBy])))
      check('TC-005a: rankMeta marks lexical disabled',
        lexOff.payload?.data?.rankMeta?.recallers?.some(o => o.name === 'lexical' && o.status === 'disabled'))
      rmSync(root, { recursive: true, force: true })
    } finally {
      await stub.close()
    }
  }

  // (b) vector "auto" with no config -> disabled with warning, lexical serves
  const { root: rootB } = buildFixture()
  const auto = search(rootB, 'auth middleware')
  check('TC-005b: unconfigured vector (auto) degrades to lexical-only hit',
    auto.status === 0 && (auto.payload?.data?.results ?? []).length > 0
      && auto.payload.data.results.every(r => r.recalledBy.join(',') === 'lexical')
      && auto.payload.data.rankMeta.recallers.some(o => o.name === 'vector' && o.status === 'disabled'),
    JSON.stringify(auto.payload?.data?.rankMeta))
  rmSync(rootB, { recursive: true, force: true })

  // (c) cross-language query with NO vector path available -> interface-level
  // miss (misfire fallback: dispatch the worker again), never an error
  const { root: rootC } = buildFixture()
  const cnMiss = search(rootC, CN_QUERY)
  check('TC-005c: cross-language query without vector config -> miss + dispatchPrompt, exit 0',
    cnMiss.status === 0 && (cnMiss.payload?.data?.results ?? []).length === 0
      && typeof cnMiss.payload?.data?.dispatchPrompt === 'string',
    `status=${cnMiss.status} results=${JSON.stringify(cnMiss.payload?.data?.results?.map(r => r.key))}`)
  rmSync(rootC, { recursive: true, force: true })

  // (d) runtime single-path failure (unreachable endpoint) -> status=failed,
  // remaining paths unaffected, interface complete
  const { root: rootD, explorationDir: dirD } = buildFixture()
  writeSearchConfig(dirD, {
    recallers: {
      vector: { enabled: true, endpoint: 'http://127.0.0.1:9/embeddings', model: 'm1', dimensions: 3, minCosine: 0.30, timeoutSeconds: 2 },
    },
  })
  writeFileSync(join(dirD, 'vectors.json'), JSON.stringify({ entries: [
    { key: 'auth-middleware', textHash: textHashOf(searchTextOf('auth-middleware', ['auth', 'middleware', 'security'], 'jwt token verify chain and refresh')), model: 'm1', vector: [1, 0, 0] },
  ] }))
  const failed = search(rootD, 'auth middleware', { RDD_EMBED_APIKEY: 'qa-test-key' })
  check('TC-005d: unreachable endpoint -> vector failed, lexical unaffected, exit 0',
    failed.status === 0 && (failed.payload?.data?.results ?? []).length > 0
      && failed.payload.data.results.every(r => r.recalledBy.includes('lexical'))
      && failed.payload.data.rankMeta.recallers.some(o => o.name === 'vector' && o.status === 'failed'),
    JSON.stringify(failed.payload?.data?.rankMeta))
  rmSync(rootD, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-006 (AC-7, positive, P0): register-then-search immediate visibility
// ---------------------------------------------------------------------------

async function testRegisterIsImmediatelyVisible() {
  const { root, explorationDir } = buildFixture()
  writeFileSync(join(explorationDir, 'artifacts', 'payment-billing.md'), '# payment-billing\n')
  writeFileSync(join(explorationDir, 'artifacts', 'payment-billing.summary.md'), '# payment-billing summary\n')

  const reg = runScript(storePs1, [
    ['Type', 'register'], ['Key', 'payment-billing'], ['Tags', 'payment,billing,invoice'],
    ['Path', '.rdd/exploration/artifacts/payment-billing.md'], ['Brief', 'payment and billing flows'],
    ['Files', 'a1.txt'],
  ], root)

  check('TC-006: register succeeds into the hot zone',
    reg.status === 0 && reg.payload?.success === true && reg.payload?.data?.zone === 'hot',
    JSON.stringify(reg.payload))
  check('TC-006: register output reports the embed hook outcome (no vector ready yet)',
    reg.payload?.data?.embed !== undefined && typeof reg.payload.data.embed.status === 'string',
    JSON.stringify(reg.payload?.data?.embed))

  // Vector not ready for the fresh entry: only the lexical path can recall it.
  const run = search(root, 'payment billing')
  const hit = (run.payload?.data?.results ?? []).find(r => r.key === 'payment-billing')
  check('TC-006: freshly registered entry is retrievable on the NEXT search (lexical)',
    run.status === 0 && hit !== undefined && hit.origin === 'hot' && hit.recalledBy.includes('lexical'),
    JSON.stringify(run.payload?.data?.results?.map(r => r.key)))
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-007 (AC-8, positive, P0): legacy explore face unchanged
// ---------------------------------------------------------------------------

async function testExploreCompatibilityFaceUnchanged() {
  const { root } = buildFixture()
  const run = explore(root, 'zzzqqq completely unrelated')

  check('TC-007: explore face exits 0 with candidates[]',
    run.status === 0 && Array.isArray(run.payload?.data?.candidates))
  const candidates = run.payload?.data?.candidates ?? []
  check('TC-007: NO semantic filtering — all fresh entries returned even for an unrelated query',
    candidates.length === BASE_DOCS.length, `len=${candidates.length}`)
  check('TC-007: candidates carry the legacy fields plus origin',
    candidates.every(c => typeof c.key === 'string' && Array.isArray(c.tags) && typeof c.brief === 'string'
      && typeof c.summaryPath === 'string' && (c.origin === 'hot' || c.origin === 'persistent')),
    JSON.stringify(candidates[0]))
  check('TC-007: dispatchPrompt is ALWAYS attached on the explore face',
    typeof run.payload?.data?.dispatchPrompt === 'string')

  const hitRun = explore(root, 'auth middleware')
  check('TC-007: dispatchPrompt attached on the explore face even for a matching query (always-attached contract)',
    typeof hitRun.payload?.data?.dispatchPrompt === 'string')
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-008 (AC-1, positive, P1): frozen RRF scores and rankMeta counters
// ---------------------------------------------------------------------------

async function testFrozenRrfScoresAndRankMeta() {
  const { root } = buildFixture()
  const run = search(root, 'auth middleware')
  const results = run.payload?.data?.results ?? []

  // Independent derivation: BM25 orders [auth-middleware, auth-cn-middleware,
  // session-store]; RRF weight=1, rrfK=60 -> ranks 1..3 score 1/61, 1/62, 1/63.
  check('TC-008: lexical ordering matches the frozen RRF values',
    results.length === 3
      && results[0].key === 'auth-middleware' && approx(results[0].score, round6(1 / 61))
      && results[1].key === 'auth-cn-middleware' && approx(results[1].score, round6(1 / 62))
      && results[2].key === 'session-store' && approx(results[2].score, round6(1 / 63)),
    JSON.stringify(results.map(r => [r.key, r.score])))
  check('TC-008: rankMeta fused/returned are consistent with results',
    run.payload?.data?.rankMeta?.fused === 3 && run.payload?.data?.rankMeta?.returned === 3,
    JSON.stringify(run.payload?.data?.rankMeta))
  check('TC-008: recallers meta lists lexical ok(3) and vector disabled',
    run.payload?.data?.rankMeta?.recallers?.some(o => o.name === 'lexical' && o.status === 'ok' && o.qualified === 3)
      && run.payload?.data?.rankMeta?.recallers?.some(o => o.name === 'vector' && o.status === 'disabled'))
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-009 (AC-6, positive, P1): new recaller via the extension point leaves
// existing paths untouched (engine copied into the fixture — the real
// scripts/recallers/ tree is never modified)
// ---------------------------------------------------------------------------

async function testNewRecallerViaExtensionPoint() {
  const { root } = buildFixture()
  const engineCopy = join(root, 'engine-copy')
  mkdirSync(join(engineCopy, 'recallers'), { recursive: true })
  cpSync(explorePs1, join(engineCopy, 'explore.ps1'))
  cpSync(join(engineRoot, 'scripts', 'recallers'), join(engineCopy, 'recallers'), { recursive: true })
  // explore.ps1 resolves ../references/exploration-guide.md relative to its
  // own location — mirror the real layout so a miss would still work.
  mkdirSync(join(root, 'references'), { recursive: true })
  cpSync(join(engineRoot, 'references', 'exploration-guide.md'), join(root, 'references', 'exploration-guide.md'))
  writeFileSync(join(engineCopy, 'recallers', 'zz-extra.ps1'), [
    '# Test-only plugin: qualifies every doc whose key starts with "auth".',
    'Register-Recaller -Name "extra" -DefaultEnabled $true -ScriptBlock {',
    '    param($ctx)',
    '    $qualified = @()',
    '    foreach ($d in @($ctx.docs)) {',
    '        if ([string]$d.key -like "auth*") { $qualified += [string]$d.key }',
    '    }',
    '    return @{ name = "extra"; scores = @{}; qualified = $qualified }',
    '}',
    '',
  ].join('\n'))

  const withExtra = runScript(join(engineCopy, 'explore.ps1'), [['Type', 'search'], ['Query', 'auth middleware']], root)
  const baseline = search(root, 'auth middleware')

  const crashed = withExtra.payload === null || withExtra.payload.success !== true
  check('TC-009: search with an unconfigured third-party recaller stays a working interface',
    !crashed,
    crashed ? `engine crashed (exit=${withExtra.status}, no/bad JSON output) — extension point rejects unconfigured recallers` : '')
  if (!crashed) {
    const extraMeta = withExtra.payload?.data?.rankMeta?.recallers?.find(o => o.name === 'extra')
    check('TC-009: dropped-in recaller is auto-registered and runs',
      extraMeta !== undefined && extraMeta.status === 'ok' && extraMeta.qualified === 2,
      JSON.stringify(withExtra.payload?.data?.rankMeta?.recallers))
    check('TC-009: existing lexical path behaves identically with the extra path present',
      withExtra.payload?.data?.rankMeta?.recallers?.find(o => o.name === 'lexical')?.qualified
        === baseline.payload?.data?.rankMeta?.recallers?.find(o => o.name === 'lexical')?.qualified,
      JSON.stringify(withExtra.payload?.data?.rankMeta?.recallers))
    check('TC-009: extra path contributes to fusion (auth* entries recalled by 2 paths)',
      (withExtra.payload?.data?.results ?? []).length >= 2
        && withExtra.payload.data.results.filter(r => r.key.startsWith('auth')).every(r => r.recalledBy.includes('extra')),
      JSON.stringify(withExtra.payload?.data?.results?.map(r => [r.key, r.recalledBy])))
  }
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-010 (AC-2, boundary, P1): summaryPath derivation + file existence
// ---------------------------------------------------------------------------

async function testSummaryPathDerivation() {
  const { root } = buildFixture()
  const run = search(root, 'auth middleware')
  const results = run.payload?.data?.results ?? []
  check('TC-010: summaryPath derives from the record path (.md -> .summary.md)',
    results.length > 0 && results.every(r => r.summaryPath === r.fullPath.replace(/\.md$/, '.summary.md')),
    JSON.stringify(results.map(r => [r.fullPath, r.summaryPath])))
  check('TC-010: every summaryPath points to an existing readable file (hit = read by position)',
    results.every(r => existsSync(join(root, r.summaryPath))))
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-011 (AC-9, positive, P1): protocol docs rewritten to the new contract
// ---------------------------------------------------------------------------

async function testProtocolDocsRewritten() {
  const guide = readFileSync(join(engineRoot, 'references', 'exploration-guide.md'), 'utf8')
  const manifest = readFileSync(join(engineRoot, 'references', 'capability-manifest.md'), 'utf8')

  check('TC-011: exploration-guide.md states the two-branch hit/miss protocol',
    guide.includes('两分支协议') && guide.includes('非空 = 命中') && guide.includes('dispatchPrompt'))
  check('TC-011: exploration-guide.md drops the legacy "non-empty but irrelevant" branch wording',
    !guide.includes('非空但不相关'))
  check('TC-011: capability-manifest.md drops the legacy "CLI does no semantic matching" claim',
    !manifest.includes('不做语义匹配') && !manifest.includes('三分支'))
  check('TC-011: capability-manifest.md documents the in-interface ranking verdict',
    /search/.test(manifest) && /Top-K|topK/i.test(manifest) && /dispatchPrompt/.test(manifest))
}

// ---------------------------------------------------------------------------
// TC-012 (AC-1/AC-5, negative, P2): corrupt search-config -> fail-soft
// ---------------------------------------------------------------------------

async function testCorruptConfigFailsSoft() {
  const { root, explorationDir } = buildFixture()
  writeFileSync(join(explorationDir, 'search-config.json'), '{{{ corrupt')
  const run = search(root, 'auth middleware')
  check('TC-012: corrupt config -> interface still answers with default behavior (fail-soft)',
    run.status === 0 && run.payload?.success === true && (run.payload?.data?.results ?? []).length > 0,
    `status=${run.status}`)
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-013 (AC-3/AC-8, negative, P2): empty query rejected on both faces
// ---------------------------------------------------------------------------

async function testEmptyQueryRejected() {
  const { root } = buildFixture()
  const s = search(root, '')
  check('TC-013: search face rejects an empty query with MISSING_QUERY (exit 1)',
    s.status === 1 && s.payload?.error?.code === 'MISSING_QUERY',
    `status=${s.status} code=${s.payload?.error?.code}`)
  const e = explore(root, '')
  check('TC-013: explore face rejects an empty query too',
    e.status === 1 && e.payload?.error?.code === 'MISSING_QUERY',
    `status=${e.status} code=${e.payload?.error?.code}`)
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// TC-014 (AC-7, boundary, P2): stale anchor eviction keeps results fresh
// ---------------------------------------------------------------------------

async function testStaleAnchorEviction() {
  const { root } = buildFixture()
  writeFileSync(join(root, 'a2.txt'), 'anchor a2.txt MUTATED\n') // invalidates auth-cn-middleware + session-store
  const run = search(root, 'auth middleware')

  const keys = (run.payload?.data?.results ?? []).map(r => r.key)
  check('TC-014: entries whose anchor hash changed are evicted from results',
    run.status === 0 && !keys.includes('auth-cn-middleware') && !keys.includes('session-store')
      && keys.includes('auth-middleware'),
    JSON.stringify(keys))
  check('TC-014: staleRemoved counts both evicted zones entries',
    run.payload?.data?.staleRemoved === 2, `staleRemoved=${run.payload?.data?.staleRemoved}`)
  rmSync(root, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------

const tests = [
  ['TC-001', testSearchHitReturnsRankedResults],
  ['TC-002', testMissAttachesDispatchPrompt],
  ['TC-003', testTopKTruncation],
  ['TC-004', testCrossLanguageVectorRecall],
  ['TC-005', testRecallerDisableAndFailureDegrade],
  ['TC-006', testRegisterIsImmediatelyVisible],
  ['TC-007', testExploreCompatibilityFaceUnchanged],
  ['TC-008', testFrozenRrfScoresAndRankMeta],
  ['TC-009', testNewRecallerViaExtensionPoint],
  ['TC-010', testSummaryPathDerivation],
  ['TC-011', testProtocolDocsRewritten],
  ['TC-012', testCorruptConfigFailsSoft],
  ['TC-013', testEmptyQueryRejected],
  ['TC-014', testStaleAnchorEviction],
]

async function main() {
  if (!existsSync(explorePs1) || !existsSync(storePs1)) {
    console.error(`engine scripts not found under ${engineRoot}`)
    process.exit(2)
  }
  const psProbe = spawnSync(psBinary, ['-NoProfile', '-Command', 'exit 0'], { stdio: 'ignore' })
  if (psProbe.error !== undefined) {
    console.error(`${psBinary} unavailable`)
    process.exit(2)
  }

  for (const [id, fn] of tests) {
    currentTc = id
    try {
      await fn()
    } catch (error) {
      failures += 1
      console.log(`FAIL - ${id}: crashed :: ${String(error?.stack ?? error)}`)
      recordCheck(`${id}: suite crashed`, 'fail', String(error?.stack ?? error))
    }
    currentTc = null
  }

  writeReport()
  console.log(failures === 0 ? 'search-precision-ranking: all checks pass' : `search-precision-ranking: ${failures} FAIL`)
  process.exit(failures === 0 ? 0 : 1)
}

main().catch(error => {
  console.error('search-precision-ranking: crashed', error)
  process.exit(1)
})

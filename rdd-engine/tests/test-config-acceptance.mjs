// QA acceptance suite for the config centre (goal-tree ops-config-panel n4).
//
// Independent black-box verification against the design contract
// (.rdd/goal-trees/ops-config-panel/design.md §2/§4-§9). The expectation
// tables below are hand-copied FROM THE DESIGN DOCUMENT — never imported
// from the implementation — so a mirror drift in lib/readers/config.mjs
// fails here. Each section runs against its own throwaway data root and
// port so save/refusal assertions cannot leak into each other.
//
//   §4  GET /api/config envelope schema (l1/l2/l3/l4/l5, fields three-state)
//   §5  POST error-code table: 405 / 400 / 413 / 422 unknown-field /
//       invalid-field / 500 write-failed, incl. the 8192-byte boundary
//   §6  the full illegal-sample matrix (every design sample → 422) plus the
//       legal boundary values (0/1/-1/1.5/"Auto"/"" → 200)
//   §2  merge chain + on-disk snapshot format (2-space indent, one \n)
//   §9  atomic write (tmp+rename fault injection, concurrent saves) and the
//       security boundary (no path escape, body limit, APIKEY never echoed,
//       HTML injection escaped)
//
// Run: node rdd-engine/tests/test-config-acceptance.mjs
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { writeSearchConfigAtomic } from '../dashboard/lib/readers/config.mjs'
import { startServer } from '../dashboard/server.mjs'

// ── design-doc expectation tables (single source: design.md §4/§6) ──────
const DESIGN_DEFAULTS = {
  topK: 5,
  recallDepth: 20,
  rrfK: 60,
  recallers: {
    lexical: { enabled: true, weight: 1.0, bm25K1: 1.2, bm25B: 0.75 },
    vector: { enabled: 'auto', weight: 1.0, endpoint: '', model: '', dimensions: 0, minCosine: 0.30, timeoutSeconds: 10 },
  },
}
const DESIGN_FIELD_ROWS = [
  ['topK', 'posInt', 5],
  ['recallDepth', 'posInt', 20],
  ['rrfK', 'posNum', 60],
  ['recallers.lexical.enabled', 'isEnabled', true],
  ['recallers.lexical.weight', 'posNum', 1.0],
  ['recallers.lexical.bm25K1', 'isK1', 1.2],
  ['recallers.lexical.bm25B', 'isB', 0.75],
  ['recallers.vector.enabled', 'isEnabled', 'auto'],
  ['recallers.vector.weight', 'posNum', 1.0],
  ['recallers.vector.endpoint', 'isString', ''],
  ['recallers.vector.model', 'isString', ''],
  ['recallers.vector.dimensions', 'isDim', 0],
  ['recallers.vector.minCosine', 'isCos', 0.30],
  ['recallers.vector.timeoutSeconds', 'isTimeout', 10],
]
const DESIGN_L1_ORDER = ['RDD_ENGINE_HOME', 'RDD_PROJECT_ROOT', 'RDD_RUNTIME', 'DSH_WEB_URL', 'RDD_EMBED_APIKEY']
const DESIGN_L5_PROBES = ['rdd-ux/ux_subagent.json', '.opencode/agent/', 'dsh/presets/', 'opencode.json', '.rdd/install.json']
/** Every illegal sample from design §6 (path → POST must be 422). */
const ILLEGAL_SAMPLES = [
  ['topK', 0], ['topK', -3], ['topK', 2.5], ['topK', '5'], ['topK', true], ['topK', null],
  ['recallDepth', 0], ['recallDepth', 1.5], ['recallDepth', '20'],
  ['rrfK', 0], ['rrfK', -1], ['rrfK', '60'],
  ['recallers.lexical.enabled', 'yes'], ['recallers.lexical.enabled', 1], ['recallers.lexical.enabled', null],
  ['recallers.lexical.weight', 0], ['recallers.lexical.weight', -0.5],
  ['recallers.lexical.bm25K1', -0.1], ['recallers.lexical.bm25K1', '1.2'],
  ['recallers.lexical.bm25B', 1.5], ['recallers.lexical.bm25B', -1],
  ['recallers.vector.enabled', 'on'], ['recallers.vector.enabled', 0],
  ['recallers.vector.weight', 0],
  ['recallers.vector.endpoint', 123], ['recallers.vector.endpoint', null], ['recallers.vector.endpoint', true],
  ['recallers.vector.model', 42],
  ['recallers.vector.dimensions', -1], ['recallers.vector.dimensions', 2.5], ['recallers.vector.dimensions', '768'],
  ['recallers.vector.minCosine', 1.5], ['recallers.vector.minCosine', -2],
  ['recallers.vector.timeoutSeconds', 0], ['recallers.vector.timeoutSeconds', 0.5], ['recallers.vector.timeoutSeconds', -5],
]
/** Legal boundary values from design §6 (path → POST must be 200). */
const LEGAL_SAMPLES = [
  ['topK', 1], ['rrfK', 0.5], ['recallers.lexical.bm25B', 0], ['recallers.lexical.bm25B', 1],
  ['recallers.vector.endpoint', ''], ['recallers.vector.dimensions', 0],
  ['recallers.vector.minCosine', -1], ['recallers.vector.minCosine', 1],
  ['recallers.vector.timeoutSeconds', 1.5], ['recallers.vector.enabled', 'Auto'],
]

const results = []
const cleanups = []
const APIKEY = 'qa-acceptance-secret-Z9y8X7w6'
const PREV_APIKEY = process.env.RDD_EMBED_APIKEY

function assertTrue(condition, name, detail = '') {
  results.push({ name, ok: Boolean(condition), detail })
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${condition ? '' : `   ${detail}`}`)
}

/** Build the nested patch object for one "a.b.c" path. */
function patchOf(path, value) {
  const parts = path.split('.')
  const config = {}
  let cursor = config
  for (let index = 0; index < parts.length - 1; index += 1) {
    cursor[parts[index]] = {}
    cursor = cursor[parts[index]]
  }
  cursor[parts[parts.length - 1]] = value
  return config
}

async function api(base, path, init) {
  const response = await fetch(`${base}${path}`, init)
  const contentType = response.headers.get('content-type') ?? ''
  const payload = contentType.includes('json') ? await response.json().catch(() => null) : null
  return { status: response.status, payload, text: contentType.includes('json') ? '' : await response.text() }
}

async function postConfig(base, config, extraTopLevel = undefined) {
  const body = extraTopLevel === undefined ? { config } : { config, ...extraTopLevel }
  return api(base, '/api/config/search-config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
}

async function postRaw(base, body) {
  return api(base, '/api/config/search-config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body })
}

function makeWorkspace(label) {
  const root = mkdtempSync(join(tmpdir(), `rdd-n4-${label}-`))
  cleanups.push(() => rmSync(root, { recursive: true, force: true }))
  return root
}

/** Boot a dashboard on an EXISTING workspace root; returns the base URL. */
async function bootOn(root, port) {
  await new Promise((resolveReady, rejectReady) => {
    const server = startServer({ context: { projectRoot: root, rddRoot: join(root, '.rdd') }, port, quiet: true, onReady: () => resolveReady(server) })
    server.on('error', rejectReady)
    cleanups.push(() => new Promise((done) => server.close(done)))
  })
  return `http://127.0.0.1:${port}`
}

/** A fresh workspace with a dashboard on its own port ({root, base}). */
async function bootWorkspace(label, port) {
  const root = makeWorkspace(label)
  const base = await bootOn(root, port)
  return { root, base }
}

// ── §4 GET envelope vs the design schema ────────────────────────────────
async function checkGetEnvelope(ctx) {
  const outcome = await api(ctx.base, '/api/config')
  const envelope = outcome.payload
  assertTrue(outcome.status === 200 && envelope.domain === 'config' && envelope.available === true, 'GET: domain envelope available')
  assertTrue(Object.keys(envelope).join(',') === 'domain,available,meta,data', 'GET: envelope top-level shape {domain,available,meta,data}', Object.keys(envelope).join(','))
  assertTrue(envelope.meta.source === 'env + .rdd/exploration/search-config.json + 内置镜像常量' && Array.isArray(envelope.meta.notes), 'GET: meta carries the design source string and notes array')
  assertTrue(!Number.isNaN(Date.parse(envelope.meta.generatedAt)), 'GET: meta.generatedAt is an ISO timestamp')

  const vars = envelope.data.l1.vars
  assertTrue(vars.map((row) => row.name).join(',') === DESIGN_L1_ORDER.join(','), 'GET: L1 lists the five variables in design order', vars.map((row) => row.name).join(','))
  const apikeyRow = vars.find((row) => row.name === 'RDD_EMBED_APIKEY')
  assertTrue(apikeyRow.set === true && !('value' in apikeyRow) && apikeyRow.masked === true, 'GET: the APIKEY row has no value field (masked in structure)')
  assertTrue(!JSON.stringify(envelope).includes(APIKEY), 'GET: the APIKEY value appears nowhere in the envelope')

  const l2 = envelope.data.l2
  assertTrue(l2.filePath === join(ctx.root, '.rdd', 'exploration', 'search-config.json'), 'GET: filePath is derived from the data root', l2.filePath)
  assertTrue(l2.fileExists === false && l2.parseError === null, 'GET: absent file reported cleanly')
  assertTrue(JSON.stringify(l2.defaults) === JSON.stringify(DESIGN_DEFAULTS), 'GET: defaults mirror the design §6 table exactly')
  assertTrue(JSON.stringify(l2.effective) === JSON.stringify(DESIGN_DEFAULTS), 'GET: effective equals defaults when no file exists')
  checkFieldRows(l2.fields)
  assertTrue(l2.unknownKeys.length === 0 && l2.nonDefaultCount === 0, 'GET: clean workspace has no unknown keys and zero non-default fields')
  const readiness = l2.vectorReadiness
  assertTrue(
    readiness.enabled === 'auto' && readiness.ready === false && readiness.missing.join(',') === 'endpoint,model,dimensions' && readiness.observedFrom === 'dashboard-process-env',
    'GET: vectorReadiness names only factor names (apikey satisfied by the test env)',
    JSON.stringify(readiness)
  )
  checkStaticLayers(envelope.data)
}

/** The 14 fields[] rows against the design table (path/validator/default). */
function checkFieldRows(fields) {
  assertTrue(fields.length === 14, 'GET: fields carries exactly 14 rows', String(fields.length))
  const problems = []
  fields.forEach((row, index) => {
    const [path, validator, fallback] = DESIGN_FIELD_ROWS[index]
    if (row.path !== path || row.validator !== validator) problems.push(`${index}:${row.path}/${row.validator}!=${path}/${validator}`)
    if (JSON.stringify(row.default) !== JSON.stringify(fallback)) problems.push(`${path} default ${JSON.stringify(row.default)}!=${JSON.stringify(fallback)}`)
    if (row.fileValue !== null || row.state !== 'unset' || JSON.stringify(row.effective) !== JSON.stringify(fallback)) problems.push(`${path} not unset:${row.state}`)
  })
  assertTrue(problems.length === 0, 'GET: every fields[] row matches the design table (unset state)', problems.join(' | '))
}

/** L3/L4/L5 static layers against design §3 rows 7-9. */
function checkStaticLayers(data) {
  assertTrue(data.l3.length === 5 && data.l3.some((row) => row.name === '热区保留期' && row.value === '7 天') && data.l3.some((row) => row.value === 'rdd-tip/1'), 'GET: L3 frozen constants table (5 rows)')
  const l4ByScript = new Map(data.l4.map((group) => [group.script, group]))
  const goalTree = l4ByScript.get('goal-tree')?.params ?? []
  const metrics = l4ByScript.get('code-metrics')?.params ?? []
  const bridge = l4ByScript.get('delivery-bridge')?.params ?? []
  const dash = l4ByScript.get('dashboard')?.params ?? []
  assertTrue(
    data.l4.length === 4 && goalTree.find((p) => p.name === 'MaxRounds')?.default === 5 && goalTree.find((p) => p.name === 'NodeWidth')?.default === 4 && goalTree.find((p) => p.name === 'MaxNodes')?.default === 30,
    'GET: L4 goal-tree defaults 5/4/30'
  )
  assertTrue(metrics.find((p) => p.name === 'MaxFunctionLines')?.default === 50 && metrics.find((p) => p.name === 'MaxNestingDepth')?.default === 5, 'GET: L4 code-metrics defaults 50/5')
  assertTrue(bridge.find((p) => p.name === 'MaxRounds')?.default === 12 && bridge.find((p) => p.name === 'MaxDerivations')?.default === 3, 'GET: L4 delivery-bridge defaults 12/3')
  assertTrue(dash.find((p) => p.name === '端口')?.default === 8787 && dash.find((p) => p.name === 'HOST')?.default === '127.0.0.1', 'GET: L4 dashboard port 8787 / HOST 127.0.0.1')
  const probes = data.l5.probes.map((probe) => probe.path)
  assertTrue(probes.join(',') === DESIGN_L5_PROBES.join(',') && data.l5.probes.every((probe) => typeof probe.exists === 'boolean'), 'GET: L5 probes the five design paths')
  assertTrue(data.l5.infoOnly.length === 1 && data.l5.infoOnly[0].path === '~/.rdd/engine/manifest.json', 'GET: L5 lists the info-only manifest row')
}

// ── §5.3 the POST error-code table (refusals only — no file may appear) ──
async function checkPostErrorTable(ctx) {
  const target = join(ctx.root, '.rdd', 'exploration', 'search-config.json')
  const wrongMethod = await api(ctx.base, '/api/config/search-config')
  assertTrue(wrongMethod.status === 405 && wrongMethod.payload.code === 'method-not-allowed' && wrongMethod.payload.message === '该端点只接受 POST。', 'POST: non-POST → 405 method-not-allowed with the exact message', JSON.stringify(wrongMethod.payload))

  const shapes = [
    ['malformed body', 'not json {'],
    ['empty body', ''],
    ['missing config key', JSON.stringify({ nope: 1 })],
    ['config is a string', JSON.stringify({ config: 'x' })],
    ['config is a number', JSON.stringify({ config: 5 })],
    ['config is an array', JSON.stringify({ config: [] })],
    ['recallers not an object', JSON.stringify({ config: { recallers: 'x' } })],
    ['lexical not an object', JSON.stringify({ config: { recallers: { lexical: 5 } } })],
    ['vector not an object', JSON.stringify({ config: { recallers: { vector: [] } } })],
  ]
  for (const [label, body] of shapes) {
    const outcome = await postRaw(ctx.base, body)
    assertTrue(outcome.status === 400 && outcome.payload.code === 'invalid-payload', `POST: ${label} → 400 invalid-payload`, JSON.stringify(outcome.payload))
  }

  const oversized = await postRaw(ctx.base, `${JSON.stringify({ config: { topK: 5 } })} ${'x'.repeat(8193)}`)
  assertTrue(oversized.status === 413 && oversized.payload.code === 'payload-too-large' && oversized.payload.message === '请求体超过大小上限（8192 字节）。', 'POST: >8192 bytes → 413 with the exact message', JSON.stringify(oversized.payload))

  const unknown = await postConfig(ctx.base, { topk: 1, TopK: 2, recallers: { vector: { dimensionz: 3 } } })
  assertTrue(
    unknown.status === 422 && unknown.payload.code === 'unknown-field' && ['topk', 'TopK', 'recallers.vector.dimensionz'].every((p) => unknown.payload.message.includes(p)),
    'POST: unknown keys (incl. case typos) → 422 unknown-field listing every offender at once',
    JSON.stringify(unknown.payload)
  )
  assertTrue(unknown.payload.message.includes('原文件保持不变') && !existsSync(target), 'POST: every refusal leaves the file non-existent (nothing created)')
}

// ── §6 predicate matrix: every illegal sample rejected, legal accepted ──
async function checkPredicateMatrix(ctx) {
  const target = join(ctx.root, '.rdd', 'exploration', 'search-config.json')
  const problems = []
  for (const [path, value] of ILLEGAL_SAMPLES) {
    const outcome = await postConfig(ctx.base, patchOf(path, value))
    if (outcome.status !== 422 || outcome.payload?.code !== 'invalid-field' || outcome.payload.fieldErrors?.[0]?.path !== path) {
      problems.push(`${path}=${JSON.stringify(value)}→${outcome.status}/${outcome.payload?.code}`)
    }
  }
  assertTrue(problems.length === 0, `POST: all ${ILLEGAL_SAMPLES.length} design illegal samples → 422 invalid-field naming the field`, problems.join(' | '))
  assertTrue(!existsSync(target), 'POST: the full illegal matrix never creates the file')

  const multi = await postConfig(ctx.base, { topK: 0, recallDepth: '20', rrfK: -1, recallers: { vector: { minCosine: 1.5 } } })
  assertTrue(
    multi.status === 422 && multi.payload.fieldErrors.length === 4 && multi.payload.fieldErrors.map((e) => e.path).join(',') === 'topK,recallDepth,rrfK,recallers.vector.minCosine',
    'POST: predicate failures are reported all-at-once with full paths',
    JSON.stringify(multi.payload.fieldErrors)
  )
  assertTrue(multi.payload.fieldErrors[0].reason === '需整数 ≥1' && typeof multi.payload.fieldErrors[0].value === 'string', 'POST: fieldErrors carry the reason and a stringified value')

  const longValue = await postConfig(ctx.base, patchOf('topK', 'x'.repeat(120)))
  assertTrue(longValue.payload.fieldErrors[0].value.length <= 65 && longValue.payload.fieldErrors[0].value.endsWith('…'), 'POST: offending values truncate to 64 chars')

  // Legal boundary values exercise the OTHER side of each predicate.
  const legalWorkspace = await bootWorkspace('legal', 8822)
  for (const [path, value] of LEGAL_SAMPLES) {
    const outcome = await postConfig(legalWorkspace.base, patchOf(path, value))
    assertTrue(outcome.status === 200, `POST: legal boundary ${path}=${JSON.stringify(value)} → 200`, `status=${outcome.status}`)
  }
  const legalRead = await api(legalWorkspace.base, '/api/config')
  const enabledRow = legalRead.payload.data.l2.fields.find((row) => row.path === 'recallers.vector.enabled')
  assertTrue(enabledRow.state === 'set' && enabledRow.effective === 'Auto', 'POST: "Auto" passes the case-insensitive isEnabled mirror (R9)')
}

// ── §2 merge chain + on-disk snapshot format (fresh workspace) ──────────
async function checkMergeAndDisk() {
  const ctx = await bootWorkspace('merge', 8823)
  const target = join(ctx.root, '.rdd', 'exploration', 'search-config.json')

  const exact = `${JSON.stringify({ config: { topK: 5 } })}${' '.repeat(8192 - Buffer.byteLength(JSON.stringify({ config: { topK: 5 } })))}`
  assertTrue(Buffer.byteLength(exact) === 8192, 'POST: boundary body is exactly 8192 bytes', String(Buffer.byteLength(exact)))
  const boundary = await postRaw(ctx.base, exact)
  assertTrue(boundary.status === 200 && boundary.payload.ok === true, 'POST: exactly 8192 bytes passes the size gate (reject is strictly >8192)', `status=${boundary.status}`)

  const saved = await postConfig(ctx.base, { topK: 8, recallers: { vector: { endpoint: 'https://e.example/v1', dimensions: 1024 } } })
  assertTrue(
    saved.status === 200 && saved.payload.ok === true && saved.payload.code === 'saved' && ['ok', 'code', 'path', 'bytes', 'writtenAt', 'effective', 'vectorReadiness'].every((key) => key in saved.payload),
    'POST: success response shape {ok,code,path,bytes,writtenAt,effective,vectorReadiness} (R2 superset: the optional impact key may appear when vector fields changed)',
    Object.keys(saved.payload ?? {}).join(',')
  )
  assertTrue(
    saved.payload.impact !== undefined && saved.payload.impact.crossModuleFields.join(',') === 'recallers.vector.endpoint,recallers.vector.dimensions',
    'POST: the optional impact key names exactly the changed cross-module vector fields (r2 §4.2)',
    JSON.stringify(saved.payload.impact ?? null)
  )
  assertTrue(saved.payload.path === target && saved.payload.bytes > 0 && !Number.isNaN(Date.parse(saved.payload.writtenAt)), 'POST: path/bytes/writtenAt are truthful')
  assertTrue(saved.payload.effective.topK === 8 && saved.payload.effective.rrfK === 60 && saved.payload.effective.recallers.lexical.bm25K1 === 1.2, 'POST: effective is the full merged 14-field snapshot')
  assertTrue(saved.payload.vectorReadiness.missing.join(',') === 'model' && saved.payload.vectorReadiness.ready === false, 'POST: vectorReadiness names the remaining factors', JSON.stringify(saved.payload.vectorReadiness))

  const text = readFileSync(target, 'utf8')
  assertTrue(text.endsWith('\n') && !text.endsWith('\n\n'), 'POST: the file ends with exactly one trailing newline')
  assertTrue(text.includes('\n  "topK"') && text.includes('\n    "lexical"') && text.includes('\n      "enabled"'), 'POST: the file uses 2-space indentation at every level')
  const onDisk = JSON.parse(text)
  assertTrue(onDisk.topK === 8 && onDisk.recallers.vector.endpoint === 'https://e.example/v1' && onDisk.recallers.vector.dimensions === 1024 && Object.keys(onDisk).length === 4, 'POST: the on-disk file is the full merged snapshot')
  assertTrue(Buffer.byteLength(text, 'utf8') === saved.payload.bytes, 'POST: the reported byte count matches the file')

  const followUp = await postConfig(ctx.base, { rrfK: 40 })
  const followUpDisk = JSON.parse(readFileSync(target, 'utf8'))
  assertTrue(followUp.status === 200 && followUpDisk.topK === 8 && followUpDisk.rrfK === 40 && followUpDisk.recallers.vector.dimensions === 1024, 'POST: a partial override inherits the previous effective values (merge chain §2)')

  const afterSave = await api(ctx.base, '/api/config')
  const topKRow = afterSave.payload.data.l2.fields.find((row) => row.path === 'topK')
  assertTrue(topKRow.state === 'set' && topKRow.fileValue === 8 && topKRow.effective === 8, 'GET: saved state round-trips (state=set, fileValue=8, effective=8)')
  // Snapshot semantics (D2 + dev-note #1): after any save the file carries ALL
  // 14 keys, so every field is explicitly set → nonDefaultCount is 14.
  assertTrue(afterSave.payload.data.l2.nonDefaultCount === 14, 'GET: nonDefaultCount=14 after a full-snapshot save (every key explicitly present)', String(afterSave.payload.data.l2.nonDefaultCount))
  assertTrue(afterSave.payload.data.l2.vectorReadiness.missing.join(',') === 'model', 'GET: readiness reflects the saved endpoint/dimensions')

  writeFileSync(target, '{"topK": 8,,}', 'utf8')
  const repair = await postConfig(ctx.base, {})
  const repairDisk = JSON.parse(readFileSync(target, 'utf8'))
  assertTrue(repair.status === 200 && repairDisk.topK === 5 && Object.keys(repairDisk).length === 4 && Object.keys(repairDisk.recallers.vector).length === 7, 'POST: an empty patch over a corrupt file repairs it to the full legal snapshot (R7)')
}

// ── §9.1 atomic write: fault injection + concurrency ────────────────────
function checkAtomicWriteUnits() {
  const root = makeWorkspace('atomic-tmp')
  const context = { projectRoot: root, rddRoot: join(root, '.rdd') }
  const targetDir = join(root, '.rdd', 'exploration')
  mkdirSync(targetDir, { recursive: true })
  const target = join(targetDir, 'search-config.json')
  writeFileSync(target, '{"topK":7}\n', 'utf8')
  mkdirSync(join(targetDir, `search-config.json.${process.pid}.tmp`))
  let threw = null
  try {
    writeSearchConfigAtomic(context, DESIGN_DEFAULTS)
  } catch (error) {
    threw = error
  }
  rmSync(join(targetDir, `search-config.json.${process.pid}.tmp`), { recursive: true })
  assertTrue(threw !== null, 'atomic: a tmp-write failure throws (write-failed upstream)')
  assertTrue(readFileSync(target, 'utf8') === '{"topK":7}\n', 'atomic: a failed tmp write leaves the original file untouched')
  assertTrue(readdirSync(targetDir).join(',') === 'search-config.json', 'atomic: a failed tmp write leaves no residue', readdirSync(targetDir).join(','))

  const root2 = makeWorkspace('atomic-rename')
  const targetDir2 = join(root2, '.rdd', 'exploration')
  mkdirSync(join(targetDir2, 'search-config.json', 'nested'), { recursive: true })
  writeFileSync(join(targetDir2, 'search-config.json', 'nested', 'keep.txt'), 'x', 'utf8')
  let threw2 = null
  try {
    writeSearchConfigAtomic({ projectRoot: root2, rddRoot: join(root2, '.rdd') }, DESIGN_DEFAULTS)
  } catch (error) {
    threw2 = error
  }
  const residue2 = readdirSync(targetDir2).filter((name) => name.endsWith('.tmp'))
  assertTrue(threw2 !== null && residue2.length === 0, 'atomic: a rename failure throws and the tmp file is cleaned up', `${threw2?.code ?? threw2?.message} residue=${residue2.join(',')}`)
  assertTrue(existsSync(join(targetDir2, 'search-config.json', 'nested', 'keep.txt')), 'atomic: a failed rename leaves the original target intact')
}

async function checkConcurrentSaves() {
  const ctx = await bootWorkspace('concurrent', 8824)
  const posts = []
  for (let index = 0; index < 30; index += 1) posts.push(postConfig(ctx.base, { topK: 11 + index }).then((outcome) => outcome.status))
  const settled = await Promise.all(posts)
  assertTrue(settled.every((status) => status === 200), 'atomic: 30 concurrent saves all return 200', JSON.stringify(settled.filter((s) => s !== 200)))
  const targetDir = join(ctx.root, '.rdd', 'exploration')
  const finalObject = JSON.parse(readFileSync(join(targetDir, 'search-config.json'), 'utf8'))
  assertTrue(finalObject.topK >= 11 && finalObject.topK <= 40 && Object.keys(finalObject).length === 4 && Object.keys(finalObject.recallers.vector).length === 7, 'atomic: the file after concurrency is a complete valid snapshot (no half file)', JSON.stringify(finalObject.topK))
  assertTrue(readdirSync(targetDir).filter((name) => name.endsWith('.tmp')).length === 0, 'atomic: no tmp residue after concurrent saves')
}

async function checkWriteFailedOverHttp() {
  const root = makeWorkspace('blocked')
  mkdirSync(join(root, '.rdd'), { recursive: true })
  writeFileSync(join(root, '.rdd', 'exploration'), 'a file blocking the directory', 'utf8')
  const base = await bootOn(root, 8825)
  const outcome = await postConfig(base, { topK: 9 })
  assertTrue(
    outcome.status === 500 && outcome.payload.code === 'write-failed' && outcome.payload.message.startsWith('写入失败：') && outcome.payload.message.endsWith('原文件保持不变。'),
    'POST: an unwritable target → 500 write-failed with the design message',
    JSON.stringify(outcome.payload)
  )
  assertTrue(!JSON.stringify(outcome.payload).includes(APIKEY), 'POST: the APIKEY value never appears in the 500 payload')
}

// ── §9.2-9.4 security boundary ──────────────────────────────────────────
function walkFiles(root, prefix = '') {
  const found = []
  for (const entry of readdirSync(join(root, prefix), { withFileTypes: true })) {
    const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`
    if (entry.isDirectory()) found.push(...walkFiles(root, relative))
    else found.push(relative)
  }
  return found
}

async function checkSecurityBoundary() {
  const ctx = await bootWorkspace('security', 8826)
  const target = join(ctx.root, '.rdd', 'exploration', 'search-config.json')
  const canonical = '.rdd/exploration/search-config.json'
  const escapes = [
    ['sibling path key', { path: '../../../../tmp/qa-evil.json' }],
    ['sibling target key', { target: 'C:/Windows/qa-evil.json' }],
    ['sibling file key', { file: '../../qa-evil.txt' }],
  ]
  for (const [label, extra] of escapes) {
    const outcome = await postConfig(ctx.base, { topK: 6 }, extra)
    assertTrue(outcome.status === 200 && outcome.payload.path === target, `security: ${label} cannot move the write target (derived from the data root only)`, `status=${outcome.status} path=${outcome.payload?.path}`)
  }
  const unknownInside = await postConfig(ctx.base, { topK: 6, filePath: 'x' })
  assertTrue(unknownInside.status === 422 && unknownInside.payload.code === 'unknown-field', 'security: path-like keys INSIDE config are rejected as unknown fields')
  const endpointPath = await postConfig(ctx.base, patchOf('recallers.vector.endpoint', '../../../../../qa-evil-endpoint'))
  assertTrue(endpointPath.status === 200 && endpointPath.payload.path === target, 'security: a path-looking endpoint value is stored as data, never used as a write path')

  const allFiles = walkFiles(ctx.root)
  assertTrue(allFiles.filter((file) => /evil/i.test(file)).length === 0, 'security: no escaped file exists anywhere in the workspace', allFiles.filter((file) => /evil/i.test(file)).join(','))
  assertTrue(allFiles.filter((file) => file.endsWith('search-config.json')).join(',') === canonical, 'security: exactly one search-config.json, at the canonical path', allFiles.filter((file) => file.endsWith('search-config.json')).join(','))
  assertTrue(statSync(target).isFile(), 'security: the write target is a regular file inside the data root')

  const page = await api(ctx.base, '/config')
  assertTrue(page.status === 200 && !page.text.includes(APIKEY) && page.text.includes('已设置（不回显）'), 'security: the /config page never echoes the APIKEY value')
  const invalid = await postConfig(ctx.base, { topK: 0 })
  assertTrue(!JSON.stringify(invalid.payload).includes(APIKEY), 'security: the APIKEY value never appears in 422 payloads')

  const injected = '<script>alert(1)</script><img src=x onerror=alert(2)>'
  const save = await postConfig(ctx.base, patchOf('recallers.vector.endpoint', injected))
  assertTrue(save.status === 200, 'security: the injection string saves legally (it is just data)')
  const afterInject = await api(ctx.base, '/config')
  assertTrue(!afterInject.text.includes('<script>alert') && !afterInject.text.includes('<img src=x'), 'security: the page escapes the injected HTML (no raw script/img tags)')
  assertTrue(afterInject.text.includes('&lt;script&gt;alert(1)&lt;/script&gt;'), 'security: the injected value renders entity-escaped')
}

// ── run ─────────────────────────────────────────────────────────────────
process.env.RDD_EMBED_APIKEY = APIKEY
try {
  const main = await bootWorkspace('main', 8821)
  await checkGetEnvelope(main)
  await checkPostErrorTable(main)
  await checkPredicateMatrix(main)
  await checkMergeAndDisk()
  checkAtomicWriteUnits()
  await checkConcurrentSaves()
  await checkWriteFailedOverHttp()
  await checkSecurityBoundary()
} finally {
  if (PREV_APIKEY === undefined) delete process.env.RDD_EMBED_APIKEY
  else process.env.RDD_EMBED_APIKEY = PREV_APIKEY
  for (const cleanup of cleanups.reverse()) {
    try {
      await cleanup()
    } catch {
      /* best effort */
    }
  }
}

const failed = results.filter((entry) => !entry.ok)
console.log('')
console.log(`total: ${results.length}  failed: ${failed.length}`)
if (failed.length > 0) for (const entry of failed) console.log(`  FAILED  ${entry.name}   ${entry.detail}`)
process.exit(failed.length > 0 ? 1 : 0)

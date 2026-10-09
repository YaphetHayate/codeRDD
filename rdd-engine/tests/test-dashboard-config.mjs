// DEV self-test for the config centre (/config — goal-tree ops-config-panel n3).
//
// Covers the n2 design contract:
//   1. reader unit assertions over purpose-built data roots — defaults when
//      the file is absent, per-field invalid→default drift, unknown keys,
//      corrupt-file fail-soft, the case-insensitive "auto" mirror;
//   2. POST control plane over the real service — full error-code spectrum
//      (405/400/413/422 unknown-field/422 invalid-field), the merge chain
//      (partial override inherits effective values), the full-snapshot
//      on-disk format (2-space indent + trailing newline), corrupt-file
//      repair via an empty patch, and the never-echo APIKEY guarantee;
//   3. SSR truth — /config renders all five layers into the HTML so a
//      no-JS reader sees everything, with the save button disabled.
//
// Run: node rdd-engine/tests/test-dashboard-config.mjs
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  FIELD_DEFS,
  SEARCH_CONFIG_DEFAULTS,
  computeVectorReadiness,
  loadEffectiveSearchConfig,
  mergeSearchConfigPatch,
  readConfig,
  validateSearchConfigPatch,
} from '../dashboard/lib/readers/config.mjs'
import { readAllDomains, DOMAIN_DEFS } from '../dashboard/lib/overview.mjs'
import { startServer } from '../dashboard/server.mjs'

const results = []
const cleanups = []
const APIKEY = 'sk-config-test-DO-NOT-ECHO-9f1c'
const PREV_APIKEY = process.env.RDD_EMBED_APIKEY

function assertTrue(condition, name, detail = '') {
  results.push({ name, ok: Boolean(condition), detail })
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${condition ? '' : `   ${detail}`}`)
}

function write(root, relativePath, content) {
  const absolute = join(root, relativePath)
  mkdirSync(dirname(absolute), { recursive: true })
  writeFileSync(absolute, content, 'utf8')
  return absolute
}

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`
}

function makeWorkspace(prefix) {
  const root = mkdtempSync(join(tmpdir(), `rdd-config-${prefix}-`))
  cleanups.push(() => rmSync(root, { recursive: true, force: true }))
  return root
}

function contextFor(root) {
  return { projectRoot: root, rddRoot: join(root, '.rdd') }
}

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

async function postJson(base, path, body, raw = false) {
  const response = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: raw ? body : JSON.stringify(body),
  })
  return { status: response.status, payload: await response.json().catch(() => null) }
}

// ── unit: single-source tables ─────────────────────────────────────────
assertTrue(FIELD_DEFS.length === 14, 'fields: the field table carries exactly 14 fields', String(FIELD_DEFS.length))
assertTrue(
  JSON.stringify(loadEffectiveSearchConfig({ rddRoot: join(makeWorkspace('empty'), '.rdd') })) === JSON.stringify(SEARCH_CONFIG_DEFAULTS),
  'defaults: a missing file resolves to the built-in defaults on every field'
)
assertTrue(
  Object.keys(SEARCH_CONFIG_DEFAULTS).join(',') === 'topK,recallDepth,rrfK,recallers' &&
    Object.keys(SEARCH_CONFIG_DEFAULTS.recallers.vector).join(',') === 'enabled,weight,endpoint,model,dimensions,minCosine,timeoutSeconds',
  'defaults: key order mirrors $SearchDefaults'
)

// ── unit: reader over fixture roots ────────────────────────────────────
process.env.RDD_EMBED_APIKEY = APIKEY

const bareRoot = makeWorkspace('bare')
const bare = readConfig(contextFor(bareRoot))
assertTrue(bare.available === true && bare.domain === 'config', 'reader: envelope is available with the config domain')
assertTrue(bare.data.l2.fileExists === false && bare.data.l2.parseError === null, 'reader: absent file reported without an error')
assertTrue(bare.data.l2.fields.every((field) => field.state === 'unset' && field.fileValue === null), 'reader: absent file leaves every field unset')
assertTrue(bare.data.l2.nonDefaultCount === 0, 'reader: absent file yields zero non-default fields')
assertTrue(
  bare.data.l1.vars.length === 5 && bare.data.l1.vars.every((entry) => typeof entry.set === 'boolean'),
  'reader: L1 lists the five environment variables'
)
const apikeyRow = bare.data.l1.vars.find((entry) => entry.name === 'RDD_EMBED_APIKEY')
assertTrue(apikeyRow.set === true && !('value' in apikeyRow) && apikeyRow.masked === true, 'reader: the APIKEY row has NO value field (masked in structure, not serialized)')
assertTrue(
  bare.data.l2.vectorReadiness.missing.join(',') === 'endpoint,model,dimensions' && bare.data.l2.vectorReadiness.ready === false,
  'reader: vector readiness names exactly the missing factors (apikey satisfied by the test env)',
  JSON.stringify(bare.data.l2.vectorReadiness)
)
assertTrue(bare.data.l3.length === 5 && bare.data.l4.length === 4 && bare.data.l5.probes.length === 5 && bare.data.l5.infoOnly.length === 1, 'reader: L3/L4/L5 static tables present')

const driftRoot = makeWorkspace('drift')
write(driftRoot, '.rdd/exploration/search-config.json', json({
  topK: 0,
  topk: 9,
  recallDepth: 30,
  recallers: { vector: { dimensions: -1, enabled: 'Auto', model: 'text-embed-x' } },
}))
const drift = readConfig(contextFor(driftRoot))
const driftByPath = new Map(drift.data.l2.fields.map((field) => [field.path, field]))
assertTrue(driftByPath.get('topK').state === 'invalid' && driftByPath.get('topK').effective === 5, 'reader: an invalid file value degrades to the default (fail-soft mirror)')
assertTrue(driftByPath.get('recallDepth').state === 'set' && driftByPath.get('recallDepth').effective === 30, 'reader: a legal file value overrides the default')
assertTrue(driftByPath.get('recallers.vector.dimensions').state === 'invalid' && driftByPath.get('recallers.vector.dimensions').effective === 0, 'reader: negative dimensions is invalid → effective 0')
assertTrue(driftByPath.get('recallers.vector.enabled').state === 'set' && driftByPath.get('recallers.vector.enabled').effective === 'Auto', 'reader: "Auto" passes the case-insensitive isEnabled mirror (PS -eq parity)')
assertTrue(drift.data.l2.unknownKeys.join(',') === 'topk', 'reader: unknown keys surfaced, not hidden', JSON.stringify(drift.data.l2.unknownKeys))
assertTrue(drift.data.l2.nonDefaultCount === 5, 'reader: non-default counts set + invalid fields', String(drift.data.l2.nonDefaultCount))
assertTrue(drift.data.l2.effective.recallers.vector.model === 'text-embed-x' && drift.data.l2.effective.topK === 5, 'reader: effective merges legal overrides over defaults')

const corruptRoot = makeWorkspace('corrupt')
write(corruptRoot, '.rdd/exploration/search-config.json', '{"topK": 8,,}')
const corrupt = readConfig(contextFor(corruptRoot))
assertTrue(corrupt.data.l2.fileExists === true && corrupt.data.l2.parseError !== null, 'reader: a corrupt file reports its parse error')
assertTrue(corrupt.data.l2.fields.every((field) => field.state === 'unset'), 'reader: a corrupt file leaves every field unset (engine falls back to defaults)')
assertTrue(
  corrupt.meta.notes.some((note) => note.includes('fail-soft')),
  'reader: the corrupt-file note names the fail-soft behaviour'
)

const ecoRoot = makeWorkspace('eco')
write(ecoRoot, 'rdd-ux/ux_subagent.json', json({ models: [] }))
mkdirSync(join(ecoRoot, '.opencode', 'agent'), { recursive: true })
const eco = readConfig(contextFor(ecoRoot))
const ecoProbes = new Map(eco.data.l5.probes.map((probe) => [probe.path, probe.exists]))
assertTrue(ecoProbes.get('rdd-ux/ux_subagent.json') === true && ecoProbes.get('.opencode/agent/') === true, 'reader: L5 probes detect existing ecosystem files')
assertTrue(ecoProbes.get('.rdd/install.json') === false && ecoProbes.get('dsh/presets/') === false, 'reader: L5 probes report absent files as false')

// ── unit: POST-side validators and merge ───────────────────────────────
const legalPatch = validateSearchConfigPatch({ topK: 8, recallers: { vector: { endpoint: 'https://e.example/v1', dimensions: 1024 } } })
assertTrue(legalPatch.unknownFields.length === 0 && legalPatch.fieldErrors.length === 0, 'validate: a legal partial patch clears both gates')
const typoPatch = validateSearchConfigPatch({ topk: 1, recallers: { vector: { dimensionz: 3 } } })
assertTrue(typoPatch.unknownFields.join(',') === 'topk,recallers.vector.dimensionz', 'validate: unknown keys reported all-at-once with full paths', JSON.stringify(typoPatch.unknownFields))
const badPatch = validateSearchConfigPatch({ topK: 0, recallDepth: -1, recallers: { vector: { minCosine: 1.5 } } })
assertTrue(badPatch.fieldErrors.length === 3 && badPatch.fieldErrors[0].path === 'topK' && badPatch.fieldErrors[0].reason === '需整数 ≥1', 'validate: invalid values reported all-at-once with reasons', JSON.stringify(badPatch.fieldErrors))
const longValue = validateSearchConfigPatch({ recallers: { vector: { endpoint: 5 } } })
assertTrue(longValue.fieldErrors.length === 1 && longValue.fieldErrors[0].reason === '需字符串', 'validate: a numeric endpoint is rejected (empty string would pass, number does not)')
const truncated = validateSearchConfigPatch({ topK: 'x'.repeat(120) })
assertTrue(truncated.fieldErrors[0].value.length <= 65 && truncated.fieldErrors[0].value.endsWith('…'), 'validate: offending values truncate to 64 chars')

const merged = mergeSearchConfigPatch(SEARCH_CONFIG_DEFAULTS, { topK: 8, recallers: { vector: { endpoint: 'https://e.example/v1' } } })
assertTrue(merged.topK === 8 && merged.rrfK === 60 && merged.recallers.vector.endpoint === 'https://e.example/v1' && merged.recallers.lexical.bm25K1 === 1.2, 'merge: partial patch inherits untouched effective values')
assertTrue(Object.keys(merged).length === 4 && Object.keys(merged.recallers.vector).length === 7, 'merge: the snapshot always carries the full 14 fields')

// ── HTTP: the control plane and the SSR page ───────────────────────────
const PORT = 8804
const BASE = `http://127.0.0.1:${PORT}`
const httpRoot = makeWorkspace('http')
write(httpRoot, '.rdd/changes/archive/2026-01-01-seed/task.json', json({ archive: '2026-01-01-seed', tasks: [{ id: 1, title: 'seed', lifecycle: 'active' }] }))
await new Promise((resolvePromise, rejectPromise) => {
  const server = startServer({ context: contextFor(httpRoot), port: PORT, quiet: true, onReady: () => resolvePromise(server) })
  server.on('error', rejectPromise)
  cleanups.push(() => server.close())
})

const envelope = await (await fetch(`${BASE}/api/config`)).json()
assertTrue(envelope.domain === 'config' && envelope.available === true && envelope.data.l2.fields.length === 14, 'API: GET /api/config returns the domain envelope with 14 fields')
assertTrue(!JSON.stringify(envelope).includes(APIKEY), 'API: the APIKEY value never appears in the envelope')

const page = await fetch(`${BASE}/config`)
const html = await page.text()
const text = pageText(html)
assertTrue(page.status === 200, 'HTTP: /config serves 200')
// R2 marker migration (design §6.4 row 2): module titles, no L1–L5 jargon.
for (const marker of ['配置中心', '两个可写点', '探索检索与缓存向量化', '跨模块公用配置', 'UX 视觉稿子代理', '热区保留期', 'MaxRounds', 'ux_subagent.json']) {
  assertTrue(text.includes(marker), `HTTP: /config SSR carries "${marker}" without JavaScript`)
}
assertTrue(!/\bL[1-5]\b/.test(text) && !text.includes('唯一可写点'), 'HTTP: /config carries no L1–L5 jargon and no retired single-writable wording')
assertTrue(html.includes('id="ops-config-form"') && html.includes('id="ops-config-save"') && html.includes('disabled'), 'HTTP: the SSR form ships with its save button disabled')
assertTrue(html.includes('保存需启用 JavaScript'), 'HTTP: the no-JS caveat states that saving needs JavaScript')
assertTrue(!html.includes(APIKEY), 'HTTP: the APIKEY value never appears in the page HTML')
assertTrue(html.includes('href="/config"') && html.includes('配置中心'), 'HTTP: the sidebar links the config domain')
assertTrue(html.includes('可写：search-config.json / ux_subagent.json（配置中心）'), 'HTTP: the footer carries the dual-writable-surface wording')

const navDef = DOMAIN_DEFS.find((definition) => definition.key === 'config')
assertTrue(navDef !== undefined && navDef.route === '/config' && navDef.icon === 'gear', 'nav: DOMAIN_DEFS carries the config entry from the design')
const domains = readAllDomains(contextFor(httpRoot))
assertTrue(domains.config.available === true && domains.config.data.l2.nonDefaultCount === 0, 'nav: the config domain rides the single-domain isolation contract')

// 405 / 400 / 413
const wrongMethod = await fetch(`${BASE}/api/config/search-config`)
assertTrue(wrongMethod.status === 405 && (await wrongMethod.json()).code === 'method-not-allowed', 'POST: non-POST is a 405 method-not-allowed')
assertTrue((await postJson(BASE, '/api/config/search-config', {}, true)).status === 400, 'POST: a malformed body is a 400')
for (const [label, body] of [
  ['missing config key', { nope: 1 }],
  ['config not an object', { config: 'x' }],
  ['recallers not an object', { config: { recallers: 'x' } }],
  ['lexical not an object', { config: { recallers: { lexical: 5 } } }],
  ['vector not an object', { config: { recallers: { vector: [] } } }],
]) {
  const outcome = await postJson(BASE, '/api/config/search-config', body)
  assertTrue(outcome.status === 400 && outcome.payload.code === 'invalid-payload', `POST: ${label} is a 400 invalid-payload`, JSON.stringify(outcome.payload))
}
const oversized = await postJson(BASE, '/api/config/search-config', { config: { recallers: { vector: { endpoint: 'x'.repeat(9000) } } } })
assertTrue(oversized.status === 413 && oversized.payload.code === 'payload-too-large', 'POST: an oversized body is a 413 (not the historic 500)', JSON.stringify(oversized.payload))

// 422 both flavours
const unknown = await postJson(BASE, '/api/config/search-config', { config: { topk: 1, recallers: { vector: { dimensionz: 3 } } } })
assertTrue(
  unknown.status === 422 && unknown.payload.code === 'unknown-field' && unknown.payload.message.includes('topk') && unknown.payload.message.includes('recallers.vector.dimensionz'),
  'POST: misspelled keys are a 422 unknown-field listing every offender'
)
const invalid = await postJson(BASE, '/api/config/search-config', { config: { topK: 0, recallDepth: 1.5, recallers: { vector: { minCosine: 1.5 } } } })
assertTrue(
  invalid.status === 422 && invalid.payload.code === 'invalid-field' && invalid.payload.fieldErrors.length === 3 && invalid.payload.fieldErrors[0].path === 'topK',
  'POST: predicate failures are a 422 invalid-field with per-field errors',
  JSON.stringify(invalid.payload)
)
assertTrue(invalid.payload.message.includes('原文件保持不变'), 'POST: the 422 message keeps the original file unchanged')
assertTrue(!existsSync(join(httpRoot, '.rdd', 'exploration', 'search-config.json')), 'POST: refusals never create the file')
assertTrue(!JSON.stringify(invalid.payload).includes(APIKEY), 'POST: the APIKEY value never appears in error payloads')

// legal save → on-disk contract
const saved = await postJson(BASE, '/api/config/search-config', { config: { topK: 8, recallers: { vector: { endpoint: 'https://e.example/v1', dimensions: 1024 } } } })
assertTrue(saved.status === 200 && saved.payload.ok === true && saved.payload.code === 'saved' && saved.payload.bytes > 0, 'POST: a legal patch saves')
assertTrue(saved.payload.path === join(httpRoot, '.rdd', 'exploration', 'search-config.json'), 'POST: the written path is derived from the data root only', saved.payload.path)
assertTrue(saved.payload.vectorReadiness.missing.join(',') === 'model' && saved.payload.vectorReadiness.ready === false, 'POST: the response vectorReadiness names the remaining factors', JSON.stringify(saved.payload.vectorReadiness))
const savedText = readFileSync(saved.payload.path, 'utf8')
const savedObject = JSON.parse(savedText)
assertTrue(savedText.endsWith('\n') && !savedText.endsWith('\n\n'), 'POST: the file ends with exactly one trailing newline')
assertTrue(savedText.includes('\n  "topK"') && savedText.includes('\n    "lexical"'), 'POST: the file uses 2-space indentation')
assertTrue(savedObject.topK === 8 && savedObject.rrfK === 60 && savedObject.recallers.lexical.bm25K1 === 1.2 && savedObject.recallers.vector.dimensions === 1024, 'POST: the file is the full merged snapshot')

// partial override inherits the current effective values (merge chain §2)
const followUp = await postJson(BASE, '/api/config/search-config', { config: { rrfK: 40 } })
const followUpObject = JSON.parse(readFileSync(join(httpRoot, '.rdd', 'exploration', 'search-config.json'), 'utf8'))
assertTrue(followUp.status === 200 && followUpObject.topK === 8 && followUpObject.rrfK === 40 && followUpObject.recallers.vector.dimensions === 1024, 'POST: a partial override inherits the previous effective values')

// the saved state is visible on the next GET
const afterSave = await (await fetch(`${BASE}/api/config`)).json()
const afterSaveTopK = afterSave.data.l2.fields.find((field) => field.path === 'topK')
assertTrue(afterSaveTopK.state === 'set' && afterSaveTopK.fileValue === 8 && afterSave.data.l2.nonDefaultCount >= 3, 'GET: the saved state round-trips through the reader')

// corrupt file + empty patch = repaired full snapshot (R7)
write(httpRoot, '.rdd/exploration/search-config.json', '{"topK": 8,,}')
const repair = await postJson(BASE, '/api/config/search-config', { config: {} })
const repairObject = JSON.parse(readFileSync(join(httpRoot, '.rdd', 'exploration', 'search-config.json'), 'utf8'))
assertTrue(repair.status === 200 && repairObject.topK === 5 && Object.keys(repairObject).length === 4 && Object.keys(repairObject.recallers.vector).length === 7, 'POST: an empty patch over a corrupt file repairs it to the full legal snapshot')

// "auto" canonical round-trips; numeric-string stays rejected server-side
const autoSave = await postJson(BASE, '/api/config/search-config', { config: { recallers: { lexical: { enabled: false }, vector: { enabled: 'auto' } } } })
const autoObject = JSON.parse(readFileSync(join(httpRoot, '.rdd', 'exploration', 'search-config.json'), 'utf8'))
assertTrue(autoSave.status === 200 && autoObject.recallers.lexical.enabled === false && autoObject.recallers.vector.enabled === 'auto', 'POST: canonical enabled values round-trip verbatim')
const stringNumber = await postJson(BASE, '/api/config/search-config', { config: { topK: '5' } })
assertTrue(stringNumber.status === 422 && stringNumber.payload.fieldErrors[0].path === 'topK', 'POST: a numeric string stays rejected (predicates are type-strict)')

// readiness computed against the dashboard process env
assertTrue(computeVectorReadiness(SEARCH_CONFIG_DEFAULTS).missing.includes('apikey') === false, 'readiness: the apikey factor resolves against the process env')
delete process.env.RDD_EMBED_APIKEY
assertTrue(computeVectorReadiness(SEARCH_CONFIG_DEFAULTS).missing.includes('apikey') === true, 'readiness: clearing the env adds the apikey factor back')
process.env.RDD_EMBED_APIKEY = APIKEY

// ── teardown ───────────────────────────────────────────────────────────
if (PREV_APIKEY === undefined) delete process.env.RDD_EMBED_APIKEY
else process.env.RDD_EMBED_APIKEY = PREV_APIKEY
for (const cleanup of cleanups.reverse()) {
  try {
    await cleanup()
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

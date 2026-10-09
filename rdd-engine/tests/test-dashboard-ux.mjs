// DEV self-test for the R2 config centre additions (goal-tree ops-config-panel-r2 n3).
//
// Covers the n2 design contract on three faces:
//   1. reader units — readUx probe-state matrix (synced / pending-sync /
//      pending-clean / orphan / unknown), validateUxAgents predicate table
//      (design §5.2, every 422 sample), mergeUxAgents key preservation,
//      and the module-table coverage assertion (risk R-UX10: every l1–l5
//      item maps into exactly one module);
//   2. runUxSync units — a fake injected .cmd exercises ok+changed parsing,
//      a non-zero exit (failed) and the timeout branch (never swallowed);
//   3. HTTP over the real service — the full ux error-code spectrum
//      (405/400/413/422 unknown-field/invalid-field/agent-count), a legal
//      save → on-disk assertions (agents ≡ submitted, managed/rules kept)
//      with the REAL sync script smoke-running inside the throwaway root,
//      the sync-only retry endpoint, and the search-config impact key.
//
// Run: node rdd-engine/tests/test-dashboard-ux.mjs
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  CROSS_MODULE_PATHS,
  MODULE_DEFS,
  mergeUxAgents,
  readConfig,
  readUx,
  validateUxAgents,
} from '../dashboard/lib/readers/config.mjs'
import { runUxSync } from '../dashboard/lib/ux-sync.mjs'
import { startServer } from '../dashboard/server.mjs'

const results = []
const cleanups = []
const APIKEY = 'ux-test-apikey-DO-NOT-ECHO-4e7q'
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
  const root = mkdtempSync(join(tmpdir(), `rdd-ux2-${prefix}-`))
  cleanups.push(() => rmSync(root, { recursive: true, force: true }))
  return root
}

function contextFor(root) {
  return { projectRoot: root, rddRoot: join(root, '.rdd') }
}

async function postJson(base, path, body, raw = false) {
  const response = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: raw ? body : JSON.stringify(body),
  })
  return { status: response.status, payload: await response.json().catch(() => null) }
}

const AGENT_A = { name: 'ux-mockup-a', model: 'p/m-a', temperature: 0.8, capability: '结构严谨 / 长上下文', note: 'A 执行器' }
const AGENT_B = { name: 'ux-mockup-b', model: 'p/m-b', temperature: 0.9, capability: '创意表现', note: 'B 执行器' }

/** A disk agent .md with the given frontmatter fields. */
function agentMd(model, temperature) {
  return `---\ndescription: >\n  stub\nmode: subagent\nhidden: true\nmodel: ${model}\ntemperature: ${temperature}\n---\n\nbody\n`
}

// ── unit: module-table coverage (risk R-UX10) ───────────────────────────
const MODULE_ORDER = ['shared', 'search', 'delivery', 'handoff', 'metrics', 'tips', 'ux', 'dashboard']
assertTrue(MODULE_DEFS.map((module) => module.key).join(',') === MODULE_ORDER.join(','), 'modules: the eight modules render in the design order (地基先行)')
assertTrue(MODULE_DEFS.every((module) => module.title !== '' && module.subtitle !== ''), 'modules: every module carries a plain title and subtitle')
const allItemsText = MODULE_DEFS.flatMap((module) => module.items.map((entry) => entry.item)).join('\n')
for (const envName of ['RDD_ENGINE_HOME', 'RDD_PROJECT_ROOT', 'RDD_RUNTIME', 'DSH_WEB_URL', 'RDD_EMBED_APIKEY']) {
  assertTrue(allItemsText.includes(envName), `coverage: the ${envName} variable maps into a module row`)
}
for (const token of ['topK', 'recallDepth', 'rrfK', 'bm25K1', 'bm25B', 'endpoint', 'minCosine', 'timeoutSeconds', 'dimensions']) {
  assertTrue(allItemsText.includes(token), `coverage: the tuning-file token "${token}" appears in the search module rows`)
}
for (const token of ['热区保留期', '热区容量', 'TipSchema', 'F1–F8', 'MaxRounds', 'GoalRoot', 'MaxFunctionLines', 'PurgeOtherModels', '8787']) {
  assertTrue(allItemsText.includes(token), `coverage: the frozen/CLI token "${token}" appears in module rows`)
}
for (const token of ['rdd-ux/ux_subagent.json', '.opencode/agent/', 'dsh/presets/', 'opencode.json', '.rdd/install.json', '~/.rdd/engine/manifest.json', 'rdd-engine/package.json']) {
  assertTrue(allItemsText.includes(token), `coverage: the ecosystem path "${token}" appears in module rows`)
}
// n5 D2: the version on that row must be the LIVE engine version read from
// the engine package — a hardcoded mirror would drift on the next bump.
const engineVersion = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'package.json'), 'utf8')).version
assertTrue(allItemsText.includes(`引擎版本 ${engineVersion}`), `coverage: the engine-version row reports the live version ${engineVersion} from the engine package`, engineVersion)
const editableRows = MODULE_DEFS.flatMap((module) => module.items.filter((entry) => entry.editable === true).map(() => module.key))
assertTrue(editableRows.join(',') === 'search,search,search,ux', 'modules: exactly four editable rows (three tuning rows + the UX agent list)', editableRows.join(','))
const crossRows = MODULE_DEFS.flatMap((module) => module.items.filter((entry) => entry.crossModule === true).map(() => module.key))
assertTrue(crossRows.length === 7, 'modules: seven cross-module (公用) rows — shared×4 / search×2 / handoff×1', crossRows.join(','))
assertTrue(CROSS_MODULE_PATHS.length === 7 && CROSS_MODULE_PATHS.every((path) => path.startsWith('recallers.vector.')), 'impact: CROSS_MODULE_PATHS is exactly the seven vector fields')

// ── unit: readUx probe-state matrix (§5.1) ──────────────────────────────
const probeRoot = makeWorkspace('probe')
write(probeRoot, 'rdd-ux/ux_subagent.json', json({ $schema: 'ux-subagent-config', comment: 'c', agents: [AGENT_A, AGENT_B], managed: ['ux-mockup-a', 'ux-mockup-b', 'ux-mockup-z'], rules: { count: 'r1' } }))
write(probeRoot, '.opencode/agent/ux-mockup-a.md', agentMd('p/m-a', '0.8')) // synced
write(probeRoot, '.opencode/agent/ux-mockup-b.md', agentMd('p/OLD', '0.5')) // pending-sync (both fields drift)
write(probeRoot, '.opencode/agent/ux-mockup-z.md', agentMd('p/m-z', '0.1')) // pending-clean (managed, not in agents)
write(probeRoot, '.opencode/agent/ux-mockup-orphan.md', agentMd('p/o', '0.2')) // orphan
write(probeRoot, '.opencode/agent/rdd-explore.md', 'not a ux-mockup file') // must be ignored by the scan
const probed = readUx(contextFor(probeRoot))
const probedByName = new Map(probed.syncStatus.perAgent.map((row) => [row.name, row]))
assertTrue(probed.syncStatus.state === 'drift', 'probe: overall state is drift when any agent is not synced')
assertTrue(probedByName.get('ux-mockup-a')?.state === 'synced', 'probe: json+disk+fields equal → synced')
assertTrue(probedByName.get('ux-mockup-b')?.state === 'pending-sync' && probedByName.get('ux-mockup-b')?.detail.includes('model') && probedByName.get('ux-mockup-b')?.detail.includes('temperature'), 'probe: field drift → pending-sync naming both fields', JSON.stringify(probedByName.get('ux-mockup-b')))
assertTrue(probedByName.get('ux-mockup-z')?.state === 'pending-clean', 'probe: managed-but-not-in-agents → pending-clean')
assertTrue(probedByName.get('ux-mockup-orphan')?.state === 'orphan', 'probe: disk-only file → orphan (skipped by the script)')
assertTrue(!probedByName.has('rdd-explore'), 'probe: non ux-mockup agent files are not scanned')
assertTrue([...probed.disk.map((entry) => entry.name)].sort().join(',') === ['ux-mockup-a', 'ux-mockup-b', 'ux-mockup-orphan', 'ux-mockup-z'].sort().join(','), 'probe: disk rows carry name/model/temperature from the frontmatter')

const syncedRoot = makeWorkspace('synced')
write(syncedRoot, 'rdd-ux/ux_subagent.json', json({ agents: [AGENT_A] }))
write(syncedRoot, '.opencode/agent/ux-mockup-a.md', agentMd('p/m-a', '0.8'))
assertTrue(readUx(contextFor(syncedRoot)).syncStatus.state === 'synced', 'probe: all synced → overall synced')

const missingRoot = makeWorkspace('missing')
const missing = readUx(contextFor(missingRoot))
assertTrue(missing.fileExists === false && missing.syncStatus.state === 'unknown' && missing.agents.length === 0, 'probe: a missing file → unknown state, no agents')
const corruptRoot = makeWorkspace('corrupt')
write(corruptRoot, 'rdd-ux/ux_subagent.json', '{"agents": [,,}')
const corrupt = readUx(contextFor(corruptRoot))
assertTrue(corrupt.parseError !== null && corrupt.syncStatus.state === 'unknown', 'probe: a corrupt file → unknown state (fail-soft, no throw)')

// ── unit: validateUxAgents predicate table (§5.2, every 422 sample) ────
const baseAgent = () => ({ ...AGENT_A })
const predicateSamples = [
  ['name empty', { ...baseAgent(), name: '' }, 'agents[0].name'],
  ['name missing prefix', { ...baseAgent(), name: 'mockup-a' }, 'agents[0].name'],
  ['name uppercase', { ...baseAgent(), name: 'ux-mockup-A' }, 'agents[0].name'],
  ['name trailing space', { ...baseAgent(), name: 'ux-mockup-a ' }, 'agents[0].name'],
  ['name over 40 chars', { ...baseAgent(), name: `ux-mockup-${'a'.repeat(40)}` }, 'agents[0].name'],
  ['model empty string', { ...baseAgent(), model: '' }, 'agents[0].model'],
  ['model whitespace only', { ...baseAgent(), model: '  ' }, 'agents[0].model'],
  ['model numeric', { ...baseAgent(), model: 123 }, 'agents[0].model'],
  ['model null', { ...baseAgent(), model: null }, 'agents[0].model'],
  ['temperature string', { ...baseAgent(), temperature: '0.8' }, 'agents[0].temperature'],
  ['temperature negative', { ...baseAgent(), temperature: -0.1 }, 'agents[0].temperature'],
  ['temperature over 2', { ...baseAgent(), temperature: 3 }, 'agents[0].temperature'],
  ['temperature null', { ...baseAgent(), temperature: null }, 'agents[0].temperature'],
  ['capability empty', { ...baseAgent(), capability: '' }, 'agents[0].capability'],
  ['capability numeric', { ...baseAgent(), capability: 42 }, 'agents[0].capability'],
  ['note numeric', { ...baseAgent(), note: 123 }, 'agents[0].note'],
  ['note over 200 chars', { ...baseAgent(), note: 'x'.repeat(201) }, 'agents[0].note'],
]
for (const [label, agent, expectedPath] of predicateSamples) {
  const gate = validateUxAgents({ agents: [agent] })
  assertTrue(
    gate.unknownFields.length === 0 && gate.fieldErrors.length === 1 && gate.fieldErrors[0].path === expectedPath && gate.countError === null,
    `predicate: ${label} → one field error at ${expectedPath}`,
    JSON.stringify(gate.fieldErrors)
  )
}
const duplicate = validateUxAgents({ agents: [{ ...AGENT_A }, { ...AGENT_B, name: 'ux-mockup-a' }] })
assertTrue(duplicate.fieldErrors.some((error) => error.path === 'agents[1].name' && error.reason.includes('重名')), 'predicate: a duplicated name is rejected naming both indexes', JSON.stringify(duplicate.fieldErrors))
const unknownKeys = validateUxAgents({ agents: [{ ...baseAgent(), mode: 'subagent' }], extra: 1 })
assertTrue(unknownKeys.unknownFields.join(',') === 'extra,agents[0].mode', 'predicate: unknown keys (top level + entry level) are reported all-at-once with full paths', unknownKeys.unknownFields.join(','))
assertTrue(validateUxAgents({ agents: [baseAgent()] }).fieldErrors.length === 0, 'predicate: a legal agent clears every gate')
assertTrue(validateUxAgents({ agents: [{ ...baseAgent(), note: '' }] }).fieldErrors.length === 0, 'predicate: an omitted/empty note is legal (defaults to "")')
assertTrue(validateUxAgents({ agents: [] }).countError !== null, 'predicate: an empty agents array is a count error (deletion goes through the manual path)')
const thirteen = []
for (let index = 0; index < 13; index += 1) thirteen.push({ ...AGENT_A, name: `ux-mockup-x${index}` })
assertTrue(validateUxAgents({ agents: thirteen }).countError !== null, 'predicate: 13 agents is a count error (1–12)')

// ── unit: mergeUxAgents preservation (§5.3 ⑤) ──────────────────────────
const original = { $schema: 'ux-subagent-config', comment: 'keep me', agents: [{ junk: true }], managed: ['ux-mockup-a'], rules: { count: 'r1', managed: 'r2' } }
const merged = mergeUxAgents(original, [AGENT_A, AGENT_B])
assertTrue(Object.keys(merged).join(',') === '$schema,comment,agents,managed,rules', 'merge: key order stays $schema→comment→agents→managed→rules', Object.keys(merged).join(','))
assertTrue(merged.comment === 'keep me' && merged.managed.join(',') === 'ux-mockup-a' && merged.rules.count === 'r1', 'merge: $schema/comment/managed/rules are preserved verbatim')
const skeleton = mergeUxAgents(null, [AGENT_A])
assertTrue(skeleton.$schema === 'ux-subagent-config' && skeleton.comment.includes('单一真相源') && Array.isArray(skeleton.managed) && skeleton.managed.length === 0 && ['count', 'managed', 'decoupling', 'fallback'].every((key) => typeof skeleton.rules[key] === 'string'), 'merge: a missing/corrupt original falls back to the built-in skeleton')

// ── unit: runUxSync with an injected fake command (§5.4) ────────────────
const fakeRoot = makeWorkspace('fake-cmd')
const fakeOk = write(fakeRoot, 'fake-ok.cmd', '@echo off\r\nchcp 65001 >nul\r\necho 变更操作：\r\necho   + created: ux-mockup-x  (model=p/m, temperature=0.8)\r\necho *** agent 配置已变更，需重启 opencode 才能生效 ***\r\nexit /b 0\r\n')
const okSync = await runUxSync(contextFor(fakeRoot), { command: fakeOk })
assertTrue(okSync.status === 'ok' && okSync.exitCode === 0 && okSync.changed === true && okSync.restartRequired === true, 'sync: exit 0 + the restart line → ok/changed/restartRequired (GBK-decoded)', JSON.stringify({ status: okSync.status, changed: okSync.changed }))
assertTrue(okSync.changes.length === 1 && okSync.changes[0].startsWith('created: ux-mockup-x'), 'sync: the change detail parses out of the 变更操作 section', JSON.stringify(okSync.changes))

const fakeNoChange = write(fakeRoot, 'fake-nochange.cmd', '@echo off\r\nchcp 65001 >nul\r\necho 结果：无变更，所有 agent 配置已是最新。\r\nexit /b 0\r\n')
const noChangeSync = await runUxSync(contextFor(fakeRoot), { command: fakeNoChange })
assertTrue(noChangeSync.status === 'ok' && noChangeSync.changed === false && noChangeSync.changes.length === 0, 'sync: exit 0 without the restart line → changed=false (no restart nag)')

const fakeFail = write(fakeRoot, 'fake-fail.cmd', '@echo off\r\necho boom detail 1>&2\r\nexit /b 1\r\n')
const failSync = await runUxSync(contextFor(fakeRoot), { command: fakeFail })
assertTrue(failSync.status === 'failed' && failSync.exitCode === 1 && failSync.stderr.includes('boom'), 'sync: a non-zero exit resolves failed with exitCode + stderr (never a fake success)', JSON.stringify({ status: failSync.status, exitCode: failSync.exitCode }))

const fakeHang = write(fakeRoot, 'fake-hang.cmd', '@echo off\r\nping -n 8 127.0.0.1 >nul\r\nexit /b 0\r\n')
const hangStarted = Date.now()
const timeoutSync = await runUxSync(contextFor(fakeRoot), { command: fakeHang, timeoutMs: 700 })
assertTrue(timeoutSync.status === 'timeout' && Date.now() - hangStarted < 10_000, 'sync: a hanging script is killed and reported as timeout', JSON.stringify({ status: timeoutSync.status }))

// ── HTTP: the ux control plane over the real service ────────────────────
process.env.RDD_EMBED_APIKEY = APIKEY
const PORT = 8831
const BASE = `http://127.0.0.1:${PORT}`
const httpRoot = makeWorkspace('http')
write(httpRoot, '.rdd/exploration/search-config.json', json({ topK: 5 }))
write(httpRoot, 'rdd-ux/ux_subagent.json', json({ $schema: 'ux-subagent-config', comment: 'http fixture', agents: [{ ...AGENT_A }, { ...AGENT_B }], managed: ['ux-mockup-a', 'ux-mockup-b'], rules: { count: 'r1', managed: 'r2', decoupling: 'r3', fallback: 'r4' } }))
write(httpRoot, '.opencode/agent/ux-mockup-a.md', agentMd('p/m-a', '0.8')) // a on disk & synced; b missing on disk → overall drift
await new Promise((resolvePromise, rejectPromise) => {
  const server = startServer({ context: contextFor(httpRoot), port: PORT, quiet: true, onReady: () => resolvePromise(server) })
  server.on('error', rejectPromise)
  cleanups.push(() => server.close())
})

const envelope = await (await fetch(`${BASE}/api/config`)).json()
assertTrue(envelope.data.modules.defs.length === 8 && envelope.data.modules.items.length === 30, 'API: GET /api/config carries data.modules (8 defs / 30 items)')
assertTrue(envelope.data.ux.fileExists === true && envelope.data.ux.agents.length === 2 && envelope.data.ux.syncStatus.state === 'drift', 'API: GET /api/config carries data.ux with the probe verdict')
const uxRow = envelope.data.modules.items.find((row) => row.editable === true && row.module === 'ux')
assertTrue(uxRow !== undefined && uxRow.exists === true, 'API: the module items merge the ecosystem probe result (ux row exists=true)')

// 405 / 400 / 413
const wrongMethod = await fetch(`${BASE}/api/config/ux-subagents`)
assertTrue(wrongMethod.status === 405 && (await wrongMethod.json()).code === 'method-not-allowed', 'POST ux: non-POST is a 405 method-not-allowed')
const wrongMethodSync = await fetch(`${BASE}/api/config/ux-subagents/sync`)
assertTrue(wrongMethodSync.status === 405 && (await wrongMethodSync.json()).code === 'method-not-allowed', 'POST sync: non-POST is a 405 method-not-allowed')
for (const [label, body] of [
  ['malformed body', 'not json {'],
  ['missing agents key', { nope: 1 }],
  ['agents not an array', { agents: 'x' }],
  ['entry not an object', { agents: ['x'] }],
  ['entry is null', { agents: [null] }],
]) {
  const outcome = await postJson(BASE, '/api/config/ux-subagents', body, typeof body === 'string')
  assertTrue(outcome.status === 400 && outcome.payload.code === 'invalid-payload', `POST ux: ${label} → 400 invalid-payload`, JSON.stringify(outcome.payload))
}
const oversized = await postJson(BASE, '/api/config/ux-subagents', { agents: [{ ...AGENT_A, note: 'x'.repeat(9000) }] })
assertTrue(oversized.status === 413 && oversized.payload.code === 'payload-too-large', 'POST ux: an oversized body is a 413')
const originalBefore = readFileSync(join(httpRoot, 'rdd-ux', 'ux_subagent.json'), 'utf8')

// 422 both flavours + count gate — every refusal leaves the file untouched
const unknown = await postJson(BASE, '/api/config/ux-subagents', { agents: [{ ...AGENT_A, mode: 'subagent' }], extra: 1 })
assertTrue(unknown.status === 422 && unknown.payload.code === 'unknown-field' && unknown.payload.message.includes('extra') && unknown.payload.message.includes('agents[0].mode'), 'POST ux: unknown keys → 422 listing every offender path (top level + entry level)')
const invalid = await postJson(BASE, '/api/config/ux-subagents', { agents: [{ ...AGENT_A, temperature: '0.8' }, { ...AGENT_B, model: '' }] })
assertTrue(invalid.status === 422 && invalid.payload.code === 'invalid-field' && invalid.payload.fieldErrors.length === 2 && invalid.payload.fieldErrors.map((error) => error.path).join(',') === 'agents[0].temperature,agents[1].model', 'POST ux: predicate failures → 422 invalid-field with per-field errors', JSON.stringify(invalid.payload.fieldErrors))
const emptyAgents = await postJson(BASE, '/api/config/ux-subagents', { agents: [] })
assertTrue(emptyAgents.status === 422 && emptyAgents.payload.code === 'agent-count' && emptyAgents.payload.message.includes('手工路径'), 'POST ux: an empty agents array → 422 agent-count pointing at the manual path')
assertTrue(readFileSync(join(httpRoot, 'rdd-ux', 'ux_subagent.json'), 'utf8') === originalBefore, 'POST ux: every refusal leaves the file byte-identical')
assertTrue(!JSON.stringify(invalid.payload).includes(APIKEY), 'POST ux: the APIKEY value never appears in ux payloads')

// legal save → the REAL sync script runs inside the throwaway root
const submitted = [
  { ...AGENT_A, model: 'p/m-a-NEW' },
  { ...AGENT_B },
  { name: 'ux-mockup-d', model: 'p/m-d', temperature: 0.7, capability: '新增方向', note: '' },
]
const saved = await postJson(BASE, '/api/config/ux-subagents', { agents: submitted })
assertTrue(saved.status === 200 && saved.payload.ok === true && saved.payload.code === 'saved' && saved.payload.bytes > 0, 'POST ux: a legal full list saves', JSON.stringify(saved.payload))
assertTrue(saved.payload.sync.status === 'ok', 'POST ux: the real sync script ran and exited 0', JSON.stringify(saved.payload.sync))
assertTrue(saved.payload.sync.changed === true && saved.payload.sync.restartRequired === true, 'POST ux: the model change + the new agent are reported as changed with the restart reminder')
assertTrue(saved.payload.sync.changes.some((line) => line.includes('updated: ux-mockup-a')) && saved.payload.sync.changes.some((line) => line.includes('created: ux-mockup-d')), 'POST ux: the change details name the update and the create', JSON.stringify(saved.payload.sync.changes))
assertTrue(saved.payload.syncStatusAfter.state === 'synced', 'POST ux: the post-save probe reports everything synced')
const savedText = readFileSync(join(httpRoot, 'rdd-ux', 'ux_subagent.json'), 'utf8')
const savedObject = JSON.parse(savedText)
assertTrue(JSON.stringify(savedObject.agents) === JSON.stringify(submitted), 'POST ux: the on-disk agents ≡ the submitted array (full replacement)')
assertTrue(savedObject.comment === 'http fixture' && savedObject.rules.fallback === 'r4', 'POST ux: comment/rules survive the rewrite verbatim')
assertTrue(savedObject.managed.includes('ux-mockup-d') && savedObject.managed.includes('ux-mockup-a'), 'POST ux: the sync script extended managed for the created agent (reread-from-disk truth)')
assertTrue(savedText.endsWith('\n') && !savedText.endsWith('\n\n') && JSON.parse(savedText).agents.length === 3, 'POST ux: the on-disk file stays valid JSON with one trailing newline (byte-idenpotence NOT promised — the sync script may rewrite managed, R-UX6)')
const diskA = readFileSync(join(httpRoot, '.opencode', 'agent', 'ux-mockup-a.md'), 'utf8')
const diskD = readFileSync(join(httpRoot, '.opencode', 'agent', 'ux-mockup-d.md'), 'utf8')
assertTrue(diskA.includes('model: p/m-a-NEW') && diskA.includes('temperature: 0.8'), 'POST ux: the agent .md frontmatter carries the new model')
assertTrue(diskD.includes('model: p/m-d'), 'POST ux: the created agent .md exists on disk')
assertTrue(!existsSync(join(httpRoot, '.opencode', 'agent', 'rdd-explore.md')), 'POST ux: the sync never touches non-ux-mockup files')

// second save with no changes → changed=false, restartRequired=false
const again = await postJson(BASE, '/api/config/ux-subagents', { agents: submitted })
assertTrue(again.status === 200 && again.payload.sync.status === 'ok' && again.payload.sync.changed === false && again.payload.sync.restartRequired === false, 'POST ux: an unchanged list → sync ok with changed=false (no restart nag)')

// the sync-only retry endpoint — real script over a CORRUPT json → honest failure
write(httpRoot, 'rdd-ux/ux_subagent.json', '{"agents": [,,}')
const failedSync = await postJson(BASE, '/api/config/ux-subagents/sync', {})
assertTrue(failedSync.status === 200 && failedSync.payload.ok === true && failedSync.payload.sync.status === 'failed' && failedSync.payload.sync.exitCode === 1, 'POST sync: a corrupt json → HTTP 200 with sync.status=failed exit 1 (never swallowed as success)', JSON.stringify(failedSync.payload.sync))
assertTrue(failedSync.payload.syncStatusAfter.state === 'unknown', 'POST sync: the post-sync probe reports unknown over a corrupt file')
write(httpRoot, 'rdd-ux/ux_subagent.json', savedText)
const okSyncOnly = await postJson(BASE, '/api/config/ux-subagents/sync', {})
assertTrue(okSyncOnly.status === 200 && okSyncOnly.payload.code === 'synced' && okSyncOnly.payload.sync.status === 'ok' && okSyncOnly.payload.sync.changed === false, 'POST sync: the retry endpoint runs the script without rewriting the file')
assertTrue(readFileSync(join(httpRoot, 'rdd-ux', 'ux_subagent.json'), 'utf8') === savedText, 'POST sync: the sync-only endpoint leaves the json byte-identical when nothing changes')

// skeleton path: a missing original builds the full file
const skeletonRoot = makeWorkspace('skeleton-http')
const SK_PORT = 8832
const SK_BASE = `http://127.0.0.1:${SK_PORT}`
await new Promise((resolvePromise, rejectPromise) => {
  const server = startServer({ context: contextFor(skeletonRoot), port: SK_PORT, quiet: true, onReady: () => resolvePromise(server) })
  server.on('error', rejectPromise)
  cleanups.push(() => server.close())
})
const skeletonSave = await postJson(SK_BASE, '/api/config/ux-subagents', { agents: [AGENT_A] })
const skeletonDisk = JSON.parse(readFileSync(join(skeletonRoot, 'rdd-ux', 'ux_subagent.json'), 'utf8'))
assertTrue(skeletonSave.status === 200 && skeletonDisk.$schema === 'ux-subagent-config' && skeletonDisk.comment.includes('单一真相源') && ['count', 'managed', 'decoupling', 'fallback'].every((key) => typeof skeletonDisk.rules[key] === 'string'), 'POST ux: a missing original saves into the built-in skeleton', JSON.stringify(Object.keys(skeletonDisk)))
assertTrue(skeletonDisk.managed.includes('ux-mockup-a'), 'POST ux: the sync script populated managed from empty for the created agent')

// search-config impact key (§4.2 ③) rides the R1 endpoint
const noImpact = await postJson(BASE, '/api/config/search-config', { config: { topK: 9 } })
assertTrue(noImpact.status === 200 && noImpact.payload.impact === undefined, 'impact: a non-vector patch carries NO impact key (R1 shape intact)')
const withImpact = await postJson(BASE, '/api/config/search-config', { config: { recallers: { vector: { endpoint: 'https://e.example/v1' } } } })
assertTrue(withImpact.status === 200 && withImpact.payload.impact.crossModuleFields.join(',') === 'recallers.vector.endpoint', 'impact: a changed vector field is reported in the optional impact key', JSON.stringify(withImpact.payload.impact ?? null))
const sameValue = await postJson(BASE, '/api/config/search-config', { config: { recallers: { vector: { endpoint: 'https://e.example/v1' } } } })
assertTrue(sameValue.status === 200 && sameValue.payload.impact === undefined, 'impact: resubmitting the effective value reports no impact')

// SSR: the /config page renders the module reorganisation + UX editor
const page = await fetch(`${BASE}/config`)
const html = await page.text()
const text = html
  .replace(/<script[\s\S]*?<\/script>/g, ' ')
  .replace(/<style[\s\S]*?<\/style>/g, ' ')
  .replace(/<[^>]+>/g, ' ')
for (const marker of ['跨模块公用配置', '探索检索与缓存向量化', 'UX 视觉稿子代理', '两个可写点', 'GoalRoot', 'goal-root 模式', `引擎版本 ${engineVersion}`, 'ux-mockup-a', 'p/m-a-NEW', '同步状态探测', 'rules 摘要', '添加子代理']) {
  assertTrue(text.includes(marker), `SSR: /config carries "${marker}" without JavaScript`)
}
assertTrue(!/\bL[1-5]\b/.test(text), 'SSR: the page never shows L1–L5 jargon')
assertTrue(html.includes('id="ops-ux-form"') && html.includes('id="ops-ux-sync"') && html.includes('id="ops-ux-agent-template"'), 'SSR: the UX form shell, sync button and clone template ship')
assertTrue(html.split('data-config-field="1"').length - 1 === 14 && html.split('data-cross-module="1"').length - 1 === 7, 'SSR: the tuning form still carries 14 fields, 7 flagged cross-module')

// the config reader over the module-organized page keeps its R1 spine
const configEnv = readConfig(contextFor(httpRoot))
assertTrue(configEnv.data.l2.fields.length === 14 && configEnv.data.l1.vars.length === 5 && configEnv.data.l3.length === 5 && configEnv.data.l4.length === 4 && configEnv.data.l5.probes.length === 5, 'reader: the l1–l5 spine is untouched by the module layer')

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

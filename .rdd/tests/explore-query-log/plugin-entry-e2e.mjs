// Dual-entry query-log e2e — the dsh-plugin side (AC-1.1/1.2/1.3, plugin entry).
// Drives the REAL built plugin tool (lib/index.js execute) against a fixture
// cache through a minimal fake ctx, so the three decision-point arms
// (hit / miss / forced) are verified at runtime without a live host reload
// (a running host holds the pre-change module image until redeploy).
// The engine CLI entry is covered by rdd-engine/tests/test-query-log.ps1.
//
// Feature: explore-query-log. Run: node .rdd/tests/explore-query-log/plugin-entry-e2e.mjs
// Lib resolution: env RDD_EXPLORE_LIB (abs path to lib/index.js) overrides the
// default sibling dsh checkout path. Missing lib -> SKIP (exit 0) so the
// suite stays runnable from checkouts without the sibling repo.
import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const defaultLib = join(here, '..', '..', '..', '..', 'dsh', 'deepseek-harness', 'packages', 'local', 'rdd-explore', 'lib', 'index.js')
const libPath = process.env.RDD_EXPLORE_LIB ?? defaultLib
if (!existsSync(libPath)) {
  console.log(`SKIP: plugin lib not found (${libPath}) — build it first: pnpm --filter @coderrdd/dsh-rdd-explore build`)
  process.exit(0)
}

const results = []
function assertTrue(cond, name, detail = '') {
  results.push({ name, ok: cond, detail })
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : `   ${detail}`}`)
}

const work = join(tmpdir(), `rdd-plugin-entry-e2e-${process.pid}-${Date.now()}`)
const proj = join(work, 'proj')
const explDir = join(proj, '.rdd', 'exploration')
const artsDir = join(explDir, 'artifacts')
await mkdir(artsDir, { recursive: true })

const sha256Of = (text) => `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`

const artifacts = [
  { key: 'auth-module', tags: ['auth', 'login', 'access'], brief: 'authentication module login overview', file: 'auth-module.md', text: 'full record: authentication module overview' },
  { key: 'auth-session-store', tags: ['auth', 'session', 'token'], brief: 'session token store module overview', file: 'auth-session-store.md', text: 'full record: session token store overview' },
]
for (const art of artifacts) {
  await writeFile(join(artsDir, art.file), art.text, 'utf8')
}
const entries = artifacts.map((art, index) => ({
  key: art.key,
  tags: art.tags,
  brief: art.brief,
  path: `.rdd/exploration/artifacts/${art.file}`,
  files: { [`.rdd/exploration/artifacts/${art.file}`]: sha256Of(art.text) },
  registeredAt: new Date(Date.now() - index * 1000).toISOString(),
}))
await writeFile(join(explDir, 'index.json'), JSON.stringify({ entries }, null, 2), 'utf8')

// Minimal fake ctx: capture the tool registration; give subagents.start an
// explicit throw so the dispatch arm fails DETERMINISTICALLY right after its
// query-log append (the log records the dispatch decision, not completion);
// every other host service is absorbed behind a no-op proxy.
const registeredTools = []
const absorb = new Proxy(function absorbService() { return absorb }, { get: () => absorb, apply: () => absorb })
const ctx = new Proxy({
  tools: { register: (tool) => registeredTools.push(tool) },
  effect: () => () => {},
  subagents: { start: () => { throw new Error('test harness: subagents service not available') } },
}, { get: (target, prop) => (prop in target ? target[prop] : absorb) })

const plugin = await import(pathToFileURL(libPath).href)
plugin.apply(ctx, { repoRoot: proj })
const tool = registeredTools.find((candidate) => typeof candidate?.execute === 'function')
assertTrue(tool !== undefined, 'plugin registers an executable rdd_explore tool')

const logPath = join(explDir, 'query-log.jsonl')
const exec = { agent: { session: { header: { cwd: proj } } } }
const readLogLines = async () => (await readFile(logPath, 'utf8')).split('\n').filter((line) => line !== '')

// --- 1. HIT arm: a cache-served query returns candidates AND appends one line
const hitResult = await tool.execute({ query: 'auth login session token' }, exec)
assertTrue(hitResult?.outcome === 'candidates' && hitResult.candidates.length > 0, 'hit: tool returns candidates', JSON.stringify(hitResult).slice(0, 120))
let lines = await readLogLines()
assertTrue(lines.length === 1, 'hit: exactly one log line appended', `lines=${lines.length}`)
const hitLine = lines[0]
const hitRec = JSON.parse(hitLine)
assertTrue(Object.keys(hitRec).join(',') === 'ts,entry,query,outcome,keys,recallers', 'hit: frozen six fields in frozen order', Object.keys(hitRec).join(','))
assertTrue(hitRec.entry === 'dsh-plugin', 'hit: entry=dsh-plugin')
assertTrue(hitRec.outcome === 'hit', 'hit: outcome=hit')
assertTrue(JSON.stringify(hitRec.keys) === JSON.stringify(hitResult.candidates.map((candidate) => candidate.key)), 'hit: keys == returned keys in rank order', hitRec.keys.join('|'))
assertTrue(hitRec.recallers.some((recaller) => recaller.name === 'lexical' && recaller.status === 'ok'), 'hit: lexical recaller ok')
assertTrue(hitRec.recallers.every((recaller) => Object.keys(recaller).join(',') === 'name,status,qualified'), 'hit: recallers projected to three fields')

// --- 2. FORCED arm: force_dispatch appends a forced line BEFORE dispatching;
// the fake host's subagents.start throws right after the append
let forcedThrew = null
try {
  await tool.execute({ query: 'auth login', force_dispatch: true }, exec)
} catch (error) {
  forcedThrew = error
}
lines = await readLogLines()
assertTrue(lines.length === 2 && lines[0] === hitLine, 'forced: one more line appended, history byte-identical', `lines=${lines.length}`)
const forcedRec = JSON.parse(lines[1])
assertTrue(forcedRec.outcome === 'forced' && Array.isArray(forcedRec.keys) && forcedRec.keys.length === 0, 'forced: outcome=forced with empty keys')
assertTrue(forcedThrew !== null, 'forced: dispatch attempted after the append (throws on the fake host)')

// --- 3. MISS arm: a nonsense query appends a miss line (dispatch marker),
// then the dispatch fails on the fake host the same way
let missThrew = null
try {
  await tool.execute({ query: 'zzzqqq wubble' }, exec)
} catch (error) {
  missThrew = error
}
lines = await readLogLines()
assertTrue(lines.length === 3 && lines[0] === hitLine, 'miss: one more line appended, history still byte-identical', `lines=${lines.length}`)
const missRec = JSON.parse(lines[2])
assertTrue(missRec.outcome === 'miss' && Array.isArray(missRec.keys) && missRec.keys.length === 0, 'miss: outcome=miss (dispatch marker) with empty keys')
assertTrue(missThrew !== null, 'miss: dispatch attempted after the append (throws on the fake host)')

await rm(work, { recursive: true, force: true })
const failed = results.filter((entry) => !entry.ok)
console.log('')
console.log(`total: ${results.length}  failed: ${failed.length}`)
process.exit(failed.length > 0 ? 1 : 0)

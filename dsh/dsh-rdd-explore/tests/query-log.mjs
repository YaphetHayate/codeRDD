// query-log tests for the dsh-rdd-explore plugin (plain node, no framework).
// Mirrors rdd-engine/tests/test-query-log.ps1 (the PS writer of the same
// frozen contract): schema + append behavior + failure isolation + no BOM +
// the frozen field ORDER both writers share.
//
// Run: pnpm --filter @coderrdd/dsh-rdd-explore build && node tests/query-log.mjs
import { existsSync } from 'node:fs'
import { readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

if (!existsSync(new URL('../lib/query-log.js', import.meta.url))) {
  console.error('lib/query-log.js not found — run: pnpm --filter @coderrdd/dsh-rdd-explore build')
  process.exit(1)
}
const { appendQueryLog, buildQueryLogRecord, queryLogPathOf } = await import('../lib/query-log.js')

const results = []
function assertTrue(cond, name, detail = '') {
  results.push({ name, ok: cond, detail })
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : `   ${detail}`}`)
}

const work = join(tmpdir(), `rdd-query-log-${process.pid}-${Date.now()}`)
const dir = join(work, 'exploration')

const recallers = [
  { name: 'lexical', status: 'ok', qualified: 2 },
  { name: 'vector', status: 'disabled', qualified: 0, warning: 'no endpoint' },
]

// 1. hit record appended into a fresh (not yet existing) directory
await appendQueryLog(dir, 'auth login', 'hit', ['auth-module', 'auth-session-store'], recallers)
const file = queryLogPathOf(dir)
const raw1 = await readFile(file, 'utf8')
const line1 = raw1.split('\n')[0]
assertTrue(raw1.endsWith('\n') && raw1.split('\n').length === 2, 'hit: file is exactly one LF-terminated line')
const rec = JSON.parse(line1)
assertTrue(Object.keys(rec).join(',') === 'ts,entry,query,outcome,keys,recallers', 'hit: frozen six fields in frozen order', Object.keys(rec).join(','))
assertTrue(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(rec.ts), 'hit: ts is ISO-8601 UTC millis', rec.ts)
assertTrue(rec.entry === 'dsh-plugin', 'hit: entry=dsh-plugin')
assertTrue(rec.query === 'auth login', 'hit: query recorded verbatim')
assertTrue(rec.outcome === 'hit', 'hit: outcome=hit')
assertTrue(JSON.stringify(rec.keys) === JSON.stringify(['auth-module', 'auth-session-store']), 'hit: keys in rank order')
assertTrue(JSON.stringify(rec.recallers) === JSON.stringify([
  { name: 'lexical', status: 'ok', qualified: 2 },
  { name: 'vector', status: 'disabled', qualified: 0 },
]), 'hit: recallers projected to exactly name,status,qualified')

// 2. miss append -> append-only
await appendQueryLog(dir, 'zzzqqq wubble', 'miss', [], recallers)
const raw2 = await readFile(file, 'utf8')
const lines = raw2.split('\n').filter(line => line !== '')
assertTrue(lines.length === 2, 'miss: exactly one more line appended', `lines=${lines.length}`)
assertTrue(lines[0] === line1, 'append-only: historical line byte-identical')
const rec2 = JSON.parse(lines[1])
assertTrue(rec2.outcome === 'miss' && Array.isArray(rec2.keys) && rec2.keys.length === 0, 'miss: outcome=miss with empty keys')

// 3. raw line parity anchor with the PS mirror: the engine writer serializes
//    the same frozen field sequence ([ordered] hashtable), so every line from
//    either writer opens identically
assertTrue(line1.startsWith('{"ts":"'), 'parity: raw line opens with {"ts":" (PS [ordered] mirror)')

// 4. failure isolation: explorationDir occupied by a FILE -> append fails,
//    the promise still resolves, and the failure is a console warning only
const blocked = join(work, 'blocked-file')
await writeFile(blocked, 'not a directory', 'utf8')
const warned = []
const originalWarn = console.warn
console.warn = message => { warned.push(String(message)) }
try {
  await appendQueryLog(blocked, 'anything', 'hit', [], recallers)
} finally {
  console.warn = originalWarn
}
assertTrue(warned.some(message => message.includes('query-log append failed')), 'isolation: failure surfaced as a console warning only')
const rawBlocked = await readFile(blocked, 'utf8')
assertTrue(rawBlocked === 'not a directory', 'isolation: caller data untouched')

// 5. no BOM
const bytes = await readFile(file)
assertTrue(!(bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF), 'encoding: query-log.jsonl has no UTF-8 BOM')

// 6. pure record assembly (the forced arm projects like any other)
{
  const built = buildQueryLogRecord('q', 'forced', [], recallers)
  assertTrue(built.outcome === 'forced' && built.entry === 'dsh-plugin' && Array.isArray(built.keys) && built.keys.length === 0,
    'builder: pure record assembly (forced arm)')
}

// cleanup + summary
await rm(work, { recursive: true, force: true })
const failed = results.filter(entry => !entry.ok)
console.log('')
console.log(`total: ${results.length}  failed: ${failed.length}`)
process.exit(failed.length > 0 ? 1 : 0)

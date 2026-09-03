#!/usr/bin/env node
// Periodic-maintenance behavior test (run after `npm run build`: node tests/maintenance.mjs).
//
// Covers maintainCache — the timer-driven twin of the call-driven sweep/read
// eviction — and the module-level entry serialization it shares with register:
//   1. TS side: clean-then-promote order (a stale hot entry is dropped, never
//      promoted), the 7-day retention / 50-entry capacity thresholds,
//      idempotence, empty-zone no-op, and mutex behavior (concurrent entries
//      serialize: each hot entry is promoted exactly once, and a registration
//      issued while maintenance is in flight is never lost).
//   2. PS/TS threshold parity (runs when the rdd-engine checkout is
//      discoverable; env RDD_ENGINE_ROOT overrides the lookup): the frozen
//      hot-zone constants must match between explore-store.ps1 and cache.ts.
// Set RDD_MAINT_TEST_KEEP=1 to keep the fixture directory for inspection.
// @module @coderrdd/dsh-rdd-explore/maintenance-test

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  HOT_CAPACITY,
  HOT_RETENTION_DAYS,
  maintainCache,
  readHot,
  readIndex,
  registerEntry,
} from '../lib/cache.js'

const pkgDir = dirname(fileURLToPath(import.meta.url))
let failures = 0
const check = (name, condition, detail = '') => {
  const ok = condition === true
  if (!ok) failures += 1
  console.log(`${ok ? 'ok' : 'FAIL'} - ${name}${ok || detail === '' ? '' : ` :: ${detail}`}`)
}

const DAY_MS = 24 * 60 * 60 * 1000
const EXPIRED = new Date(Date.now() - 8 * DAY_MS).toISOString() // past the 7-day window
const RECENT = new Date(Date.now() - 1 * DAY_MS).toISOString() // inside the window
const NEWEST = new Date().toISOString()

const fixtureBase = process.env.RDD_MAINT_TEST_TMP !== undefined
  ? resolve(process.env.RDD_MAINT_TEST_TMP)
  : mkdtempSync(join(tmpdir(), 'rdd-maintenance-'))

const fileSha256 = path => `sha256:${createHash('sha256').update(readFileSync(path)).digest('hex')}`

/**
 * Build one isolated scenario directory: repoRoot/.rdd/exploration with the
 * given hot and index entries materialized (anchor files, artifact pairs).
 * `stale: true` hashes anchor content that is NOT what lands on disk.
 */
function makeScenario(name, hotSpecs, indexSpecs = []) {
  const repoRoot = join(fixtureBase, name)
  const explorationDir = join(repoRoot, '.rdd', 'exploration')
  mkdirSync(join(explorationDir, 'artifacts'), { recursive: true })
  const materialize = spec => {
    const anchorRel = `${spec.key}-anchor.txt`
    const anchorAbs = join(repoRoot, anchorRel)
    writeFileSync(anchorAbs, `${spec.key} v1\n`)
    writeFileSync(join(explorationDir, 'artifacts', `${spec.key}.md`), `# ${spec.key}\n`)
    writeFileSync(join(explorationDir, 'artifacts', `${spec.key}.summary.md`), `# ${spec.key} summary\n`)
    const entry = {
      key: spec.key,
      tags: ['t'],
      brief: `brief ${spec.key}`,
      path: `.rdd/exploration/artifacts/${spec.key}.md`,
      files: { [anchorRel]: spec.stale === true ? `sha256:${'0'.repeat(64)}` : fileSha256(anchorAbs) },
    }
    return spec.registeredAt !== undefined ? { ...entry, registeredAt: spec.registeredAt } : entry
  }
  writeFileSync(join(explorationDir, 'hot.json'), JSON.stringify({ entries: hotSpecs.map(materialize) }))
  writeFileSync(join(explorationDir, 'index.json'), JSON.stringify({ entries: indexSpecs.map(materialize) }))
  return { repoRoot, explorationDir }
}

/** Pre-write one registrable artifact pair + anchor and return the register input. */
function registrable(repoRoot, key) {
  const artifactsDir = join(repoRoot, '.rdd', 'exploration', 'artifacts')
  const anchorRel = `${key}-anchor.txt`
  writeFileSync(join(repoRoot, anchorRel), `${key} v1\n`)
  writeFileSync(join(artifactsDir, `${key}.md`), `# ${key}\n`)
  writeFileSync(join(artifactsDir, `${key}.summary.md`), `# ${key} summary\n`)
  return {
    key,
    tags: ['t'],
    brief: `brief ${key}`,
    artifactAbsPath: join(artifactsDir, `${key}.md`),
    repoRoot,
    files: [anchorRel],
  }
}

const keysOf = entries => [...entries].map(entry => entry.key).sort()

// ---------------------------------------------------------------------------
// 1. Frozen thresholds
// ---------------------------------------------------------------------------

check('thresholds: 7-day retention / 50-entry capacity (TS constants)',
  HOT_RETENTION_DAYS === 7 && HOT_CAPACITY === 50,
  `days=${HOT_RETENTION_DAYS} capacity=${HOT_CAPACITY}`)

// ---------------------------------------------------------------------------
// 2. maintainCache: clean-then-promote, stale never promoted
// ---------------------------------------------------------------------------

{
  const { repoRoot, explorationDir } = makeScenario('order', [
    { key: 'stale-expired', registeredAt: EXPIRED, stale: true },
    { key: 'fresh-expired', registeredAt: EXPIRED },
    { key: 'fresh-recent', registeredAt: RECENT },
  ])
  const result = await maintainCache(explorationDir, repoRoot)
  check('order: one stale evicted, one expired promoted',
    result.staleRemoved === 1 && result.promoted === 1, JSON.stringify(result))
  const hot = await readHot(explorationDir)
  const index = await readIndex(explorationDir)
  check('order: fresh-recent stays hot, fresh-expired moved to index',
    JSON.stringify(keysOf(hot)) === JSON.stringify(['fresh-recent'])
    && JSON.stringify(keysOf(index)) === JSON.stringify(['fresh-expired']),
    `hot=${JSON.stringify(keysOf(hot))} index=${JSON.stringify(keysOf(index))}`)
  check('order: stale entry present in neither zone',
    ![...hot, ...index].some(entry => entry.key === 'stale-expired'))
}

// Capacity + staleness in one pass proves freshness ran BEFORE the sweep: with
// the wrong order, the sweep would promote the overflow (reporting promoted >
// 0) and the freshness pass would then evict it from the index.
{
  const hotSpecs = [
    { key: 'stale-oldest', registeredAt: EXPIRED, stale: true },
    ...Array.from({ length: 50 }, (_, i) => ({ key: `cap-${String(i).padStart(2, '0')}`, registeredAt: RECENT })),
  ]
  const { repoRoot, explorationDir } = makeScenario('capacity-order', hotSpecs)
  const result = await maintainCache(explorationDir, repoRoot)
  check('capacity-order: stale dropped first, no overflow left to promote',
    result.staleRemoved === 1 && result.promoted === 0, JSON.stringify(result))
  const hot = await readHot(explorationDir)
  const index = await readIndex(explorationDir)
  check('capacity-order: hot exactly at the 50-entry capacity, index untouched',
    hot.length === 50 && index.length === 0, `hot=${hot.length} index=${index.length}`)
}

// Pure capacity shedding with no stale entries asserts the new 50-entry limit
// and oldest-first overflow promotion.
{
  const hotSpecs = Array.from({ length: 52 }, (_, i) => ({
    key: `ovf-${String(i).padStart(2, '0')}`,
    registeredAt: i < 2 ? RECENT : NEWEST,
  }))
  const { repoRoot, explorationDir } = makeScenario('overflow', hotSpecs)
  const result = await maintainCache(explorationDir, repoRoot)
  const hot = await readHot(explorationDir)
  const index = await readIndex(explorationDir)
  check('overflow: 52 fresh entries -> 2 oldest shed to index, hot at 50',
    result.promoted === 2 && hot.length === 50 && index.length === 2, JSON.stringify(result))
  check('overflow: the two oldest (lowest registeredAt) are the promoted ones',
    JSON.stringify(keysOf(index)) === JSON.stringify(['ovf-00', 'ovf-01']),
    JSON.stringify(keysOf(index)))
}

// ---------------------------------------------------------------------------
// 3. Idempotence and empty-zone no-op
// ---------------------------------------------------------------------------

{
  const { repoRoot, explorationDir } = makeScenario('idempotent', [
    { key: 'fresh-expired', registeredAt: EXPIRED },
    { key: 'fresh-recent', registeredAt: RECENT },
  ])
  await maintainCache(explorationDir, repoRoot)
  const hotBefore = readFileSync(join(explorationDir, 'hot.json'), 'utf8')
  const indexBefore = readFileSync(join(explorationDir, 'index.json'), 'utf8')
  const again = await maintainCache(explorationDir, repoRoot)
  check('idempotent: settled cache -> zero-work second pass',
    again.staleRemoved === 0 && again.promoted === 0, JSON.stringify(again))
  check('idempotent: zone files byte-identical after second pass',
    readFileSync(join(explorationDir, 'hot.json'), 'utf8') === hotBefore
    && readFileSync(join(explorationDir, 'index.json'), 'utf8') === indexBefore)
}

{
  const repoRoot = join(fixtureBase, 'empty')
  const explorationDir = join(repoRoot, '.rdd', 'exploration')
  mkdirSync(explorationDir, { recursive: true })
  const result = await maintainCache(explorationDir, repoRoot)
  check('empty zones: maintenance is a no-op',
    result.staleRemoved === 0 && result.promoted === 0, JSON.stringify(result))
  check('empty zones: no zone files created',
    !existsSync(join(explorationDir, 'hot.json')) && !existsSync(join(explorationDir, 'index.json')))
}

// ---------------------------------------------------------------------------
// 4. Entry mutex: concurrent entries serialize through one module lock
// ---------------------------------------------------------------------------

// Two concurrent passes over the same backlog promote every entry exactly
// once: without the lock both read the same hot zone and each reports the
// full backlog, doubling the sum.
{
  const hotSpecs = Array.from({ length: 12 }, (_, i) => ({ key: `mut-${String(i).padStart(2, '0')}`, registeredAt: EXPIRED }))
  const { repoRoot, explorationDir } = makeScenario('mutex-passes', hotSpecs)
  const [first, second] = await Promise.all([
    maintainCache(explorationDir, repoRoot),
    maintainCache(explorationDir, repoRoot),
  ])
  const index = await readIndex(explorationDir)
  check('mutex: concurrent passes share the backlog (each entry promoted once)',
    first.promoted + second.promoted === 12 && index.length === 12,
    `first=${first.promoted} second=${second.promoted} index=${index.length}`)
}

// Registrations issued while maintenance is in flight queue behind it and are
// never lost — the no-loss regression the lock exists for. Without the lock a
// maintenance writeHot can land after a registration's writeHot and erase it.
{
  let lost = 0
  for (let round = 0; round < 5; round += 1) {
    const hotSpecs = Array.from({ length: 24 }, (_, i) => ({ key: `r${round}-m${String(i).padStart(2, '0')}`, registeredAt: EXPIRED }))
    const { repoRoot, explorationDir } = makeScenario(`mutex-register-${round}`, hotSpecs)
    const inputs = [registrable(repoRoot, `r${round}-new-a`), registrable(repoRoot, `r${round}-new-b`)]
    const maintenance = maintainCache(explorationDir, repoRoot)
    const registrations = Promise.all(inputs.map(input => registerEntry(explorationDir, input)))
    await Promise.all([maintenance, registrations])
    const union = new Set([...(await readHot(explorationDir)), ...(await readIndex(explorationDir))].map(entry => entry.key))
    for (const input of inputs) if (!union.has(input.key)) lost += 1
  }
  check('mutex: registrations during in-flight maintenance are never lost', lost === 0, `lost=${lost}`)
}

// ---------------------------------------------------------------------------
// 5. PS/TS threshold parity (frozen contract, both writers together)
// ---------------------------------------------------------------------------

function discoverEngineRoot() {
  const candidates = [
    process.env.RDD_ENGINE_ROOT,
    resolve(pkgDir, '..', 'rdd-engine'),
    resolve(pkgDir, '..', '..', '..', 'rdd-engine'),
    resolve(pkgDir, '..', '..', '..', '..', '..', 'codeRDD', 'rdd-engine'),
    resolve(pkgDir, '..', '..', '..', '..', '.rdd', 'skills', 'rdd-engine'),
  ].filter(Boolean)
  return candidates.find(root => existsSync(join(root, 'scripts', 'explore-store.ps1')))
}

{
  const engineRoot = discoverEngineRoot()
  if (engineRoot === undefined) {
    console.log('SKIP - PS/TS threshold parity: rdd-engine checkout not found (set RDD_ENGINE_ROOT to enable)')
  } else {
    const ps1 = readFileSync(join(engineRoot, 'scripts', 'explore-store.ps1'), 'utf8')
    const days = /\$HotRetentionDays\s*=\s*(\d+)/.exec(ps1)?.[1]
    const capacity = /\$HotCapacity\s*=\s*(\d+)/.exec(ps1)?.[1]
    check('PS/TS threshold parity: explore-store.ps1 mirrors cache.ts constants',
      Number(days) === HOT_RETENTION_DAYS && Number(capacity) === HOT_CAPACITY,
      `ps ${days ?? '?'}/${capacity ?? '?'} vs ts ${HOT_RETENTION_DAYS}/${HOT_CAPACITY}`)
  }
}

if (process.env.RDD_MAINT_TEST_KEEP !== '1') rmSync(fixtureBase, { recursive: true, force: true })
console.log(failures === 0 ? 'maintenance: all checks pass' : `maintenance: ${failures} FAIL`)
process.exit(failures === 0 ? 0 : 1)

#!/usr/bin/env node
// engineRoot candidate-chain test (run after `npm run build`: node tests/engine-root.mjs).
//
// Covers resolveEngineRoot's six candidates and their ordering:
//   ① config override (always first when present)
//   ② <repoRoot>/.rdd/skills/rdd-engine      (v1 coderrdd project layout)
//   ③ <repoRoot>/.agents/skills/rdd-engine
//   ④ <repoRoot>/rdd-engine                  (codeRDD checkout layout)
//   ⑤ the package's vendored assets/rdd-engine (install-anywhere fallback)
//   ⑥ ~/.rdd/engine/current                  (user-level engine install; not
//      faked here — creating dirs under the real HOME is invasive. The chain
//      is ordered, so ⑥ only matters when ⑤ missed, which a packed tarball
//      with its committed assets cannot hit in practice.)
// The probe is always references/exploration-guide.md existence.
// @module @coderrdd/dsh-rdd-explore/engine-root-test

import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveEngineRoot } from '../lib/index.js'

const pkgRoot = dirname(dirname(fileURLToPath(import.meta.url)))
let failures = 0
const check = (name, condition, detail = '') => {
  const ok = condition === true
  if (!ok) failures += 1
  console.log(`${ok ? 'ok' : 'FAIL'} - ${name}${ok || detail === '' ? '' : ` :: ${detail}`}`)
}

/** One empty repo root with a probe-carrying engine at the given relative layout. */
function repoWith(layout) {
  const repoRoot = mkdtempSync(join(tmpdir(), 'rdd-engine-root-'))
  const engine = join(repoRoot, ...layout)
  mkdirSync(join(engine, 'references'), { recursive: true })
  writeFileSync(join(engine, 'references', 'exploration-guide.md'), '# probe\n')
  return { repoRoot, engine }
}

const GUIDE = join('references', 'exploration-guide.md')

// ② v1 coderrdd layout
{
  const { repoRoot, engine } = repoWith(['.rdd', 'skills', 'rdd-engine'])
  check('candidate ② .rdd/skills/rdd-engine wins over later candidates',
    resolveEngineRoot(undefined, repoRoot) === engine)
  rmSync(repoRoot, { recursive: true, force: true })
}

// ③ .agents layout
{
  const { repoRoot, engine } = repoWith(['.agents', 'skills', 'rdd-engine'])
  check('candidate ③ .agents/skills/rdd-engine wins over later candidates',
    resolveEngineRoot(undefined, repoRoot) === engine)
  rmSync(repoRoot, { recursive: true, force: true })
}

// ④ checkout layout
{
  const { repoRoot, engine } = repoWith(['rdd-engine'])
  check('candidate ④ <repoRoot>/rdd-engine wins over the vendored fallback',
    resolveEngineRoot(undefined, repoRoot) === engine)
  rmSync(repoRoot, { recursive: true, force: true })
}

// ① config override outranks a repo-local engine
{
  const { repoRoot, engine } = repoWith(['.agents', 'skills', 'rdd-engine'])
  const override = mkdtempSync(join(tmpdir(), 'rdd-engine-override-'))
  mkdirSync(join(override, 'references'), { recursive: true })
  writeFileSync(join(override, GUIDE), '# override\n')
  check('candidate ① engineRoot config override outranks repo-local layouts',
    resolveEngineRoot(override, repoRoot) === override)
  rmSync(repoRoot, { recursive: true, force: true })
  rmSync(override, { recursive: true, force: true })
}

// ⑤ vendored package assets: any project, no engine anywhere
{
  const repoRoot = mkdtempSync(join(tmpdir(), 'rdd-engine-empty-'))
  const resolved = resolveEngineRoot(undefined, repoRoot)
  const vendored = join(pkgRoot, 'assets', 'rdd-engine')
  check('candidate ⑤ vendored assets/rdd-engine serves an engine-less project',
    resolved === vendored, `resolved=${resolved} vendored=${vendored}`)
  check('candidate ⑤ resolved root carries the probe file',
    existsSync(join(resolved, GUIDE)))
  rmSync(repoRoot, { recursive: true, force: true })
}

console.log(failures === 0 ? 'engine-root: all checks pass' : `engine-root: ${failures} FAIL`)
process.exit(failures === 0 ? 0 : 1)

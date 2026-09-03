#!/usr/bin/env node
/**
 * Keyless debug CLI over the exploration cache (built lib). Used for manual
 * inspection and cross-client interop checks against rdd-engine's explore /
 * explore-store CLIs; not wired into any product path.
 *
 * Usage:
 *   node tests/cache-cli.mjs select <repoRoot>        # merged dual-zone read (hot first, origin)
 *   node tests/cache-cli.mjs search <repoRoot> <query> # precision ranking (lexical + vector -> RRF -> Top-K)
 *   node tests/cache-cli.mjs register <repoRoot> <key> <tagsCsv> <brief> <artifactAbsPath> <filesCsv>
 *   node tests/cache-cli.mjs persist <repoRoot> <key> # promote one hot entry into index.json
 * @module @coderrdd/dsh-rdd-explore/cache-cli
 */

import { registerEntry, mergedFresh, persistHotEntry, summaryPathOf, readSearchConfig, runRecallPipeline } from '../lib/cache.js'
import { lexicalRecaller } from '../lib/recallers/lexical.js'
import { vectorRecaller } from '../lib/recallers/vector.js'
import { join } from 'node:path'

function fail(message) {
  console.error(String(message))
  process.exit(1)
}

const [command, ...rest] = process.argv.slice(2)
const repoRoot = rest[0]

if (command === 'select') {
  if (repoRoot === undefined) fail('usage: select <repoRoot>')
  const explorationDir = join(repoRoot, '.rdd', 'exploration')
  const { results, staleRemoved } = await mergedFresh(explorationDir, repoRoot)
  console.log(JSON.stringify({
    results: results.map(({ entry, origin }) => ({
      key: entry.key,
      tags: [...entry.tags],
      brief: entry.brief,
      path: entry.path,
      summaryPath: summaryPathOf(entry.path),
      origin,
    })),
    staleRemoved,
  }, null, 2))
} else if (command === 'search') {
  const [_, query] = rest
  if (repoRoot === undefined || query === undefined) {
    fail('usage: search <repoRoot> <query>')
  }
  const explorationDir = join(repoRoot, '.rdd', 'exploration')
  const { results: merged, staleRemoved } = await mergedFresh(explorationDir, repoRoot)
  const outcome = await runRecallPipeline({
    query,
    merged,
    config: await readSearchConfig(explorationDir),
    explorationDir,
    recallers: [lexicalRecaller, vectorRecaller],
  })
  console.log(JSON.stringify({ staleRemoved, ...outcome }, null, 2))
} else if (command === 'register') {
  const [_, key, tagsCsv, brief, artifactAbsPath, filesCsv] = rest
  if (repoRoot === undefined || key === undefined || tagsCsv === undefined || brief === undefined || artifactAbsPath === undefined || filesCsv === undefined) {
    fail('usage: register <repoRoot> <key> <tagsCsv> <brief> <artifactAbsPath> <filesCsv>')
  }
  const result = await registerEntry(join(repoRoot, '.rdd', 'exploration'), {
    key,
    tags: tagsCsv.split(','),
    brief,
    artifactAbsPath,
    repoRoot,
    files: filesCsv.split(','),
  })
  console.log(JSON.stringify(result, null, 2))
} else if (command === 'persist') {
  const [_, key] = rest
  if (repoRoot === undefined || key === undefined) {
    fail('usage: persist <repoRoot> <key>')
  }
  const result = await persistHotEntry(join(repoRoot, '.rdd', 'exploration'), repoRoot, key)
  console.log(JSON.stringify(result, null, 2))
} else {
  fail(`unknown command: ${String(command)} (expected select | search | register | persist)`)
}

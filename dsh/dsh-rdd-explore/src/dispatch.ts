/**
 * Self-contained dispatch prompt for the rdd-explore worker subagent,
 * mirroring `explore.ps1`'s `Build-DispatchPrompt`: the query, the
 * repository/cache paths, the registration instruction, and the full
 * exploration-guide protocol read from the rdd-engine skill assets.
 * @module @coderrdd/dsh-rdd-explore/dispatch
 */

import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

/** Inputs to one dispatch-prompt build. */
export interface DispatchOptions {
  /** The exploration query, in the caller's words. */
  readonly query: string
  /** Absolute repository root. */
  readonly repoRoot: string
  /** Absolute `.rdd/exploration` directory. */
  readonly explorationDir: string
  /** Absolute `.rdd/exploration/artifacts` directory. */
  readonly artifactsDir: string
  /** Absolute rdd-engine skill directory (contains `references/` and `scripts/`). */
  readonly engineRoot: string
  /**
   * Who registers the finished artifact: `'worker'` has the child call the
   * engine CLI itself (needs pwsh on every platform); `'plugin'` has the child
   * act as a pure researcher — no file writes — returning the payload via the
   * run's structured output, which the plugin persists and registers.
   */
  readonly registerMode: 'worker' | 'plugin'
}

/**
 * Build the worker's complete, standalone prompt. Fails loud when the
 * exploration-guide reference is missing — the engine assets are a load-time
 * precondition, not something to silently degrade.
 * @param options - the dispatch inputs.
 * @returns the full prompt text.
 */
export async function buildDispatchPrompt(options: DispatchOptions): Promise<string> {
  const guidePath = join(options.engineRoot, 'references', 'exploration-guide.md')
  let guide: string
  try {
    guide = await readFile(guidePath, 'utf8')
  } catch (error: unknown) {
    throw new Error(
      `rdd-engine reference not found: ${guidePath} (${String(error)}) — point the plugin's engineRoot at the rdd-engine skill directory`,
    )
  }
  return [
    options.registerMode === 'plugin'
      ? 'You are the rdd-engine code-exploration worker (rdd-explore): a pure researcher WITHOUT file-write tools.'
      : 'You are the rdd-engine code-exploration worker (rdd-explore). You are NOT a read-only explorer: you must write artifacts and register them.',
    '',
    `User exploration query: ${options.query}`,
    '',
    `Repository root: ${options.repoRoot}`,
    `Exploration cache directory: ${options.explorationDir}`,
    `Artifacts directory: ${options.artifactsDir}`,
    '',
    'Follow the protocol below strictly.',
    registerInstruction(options),
    '',
    '--- exploration-guide.md ---',
    guide,
  ].join('\n')
}

/** The mode-appropriate result/registration instruction. */
function registerInstruction(options: DispatchOptions): string {
  if (options.registerMode === 'plugin') {
    return [
      'Deliver the exploration as your STRUCTURED RESULT (the run carries an output schema), with exactly these fields:',
      '  key     — semantic topic key (Chinese ok)',
      '  tags    — module/feature/synonym keywords (Chinese and English, at least one)',
      '  brief   — one-line summary',
      '  summary — the short summary record (conclusion plus entry points)',
      '  full    — the complete exploration record (markdown)',
      '  files   — repository-relative POSIX paths of the analyzed files (at least one)',
      'The harness writes the artifact files and registers the cache entry from this result; do not attempt to write or register anything yourself.',
    ].join('\n')
  }
  const scripts = join(options.engineRoot, 'scripts')
  // Registration is the write face (explore-store): it lands in the hot zone
  // (hot.json), visible to the next retrieval without any async pipeline.
  // explore-store.sh is itself only a pwsh wrapper, so call pwsh directly on
  // POSIX; both platforms therefore require PowerShell 7+ for worker-mode
  // registration.
  const register = process.platform === 'win32'
    ? `& "${join(scripts, 'explore-store.cmd')}" -Type register`
    : `pwsh -NoProfile -ExecutionPolicy Bypass -File "${join(scripts, 'explore-store.ps1')}" -Type register`
  return [
    `On finish, call: ${register} -Key "<semantic key, Chinese ok>" -Tags "<comma-separated module/feature/synonym keywords, Chinese and English>" -Path "<repo-relative FULL record path>" -Brief "<one-line summary>" -Files "<comma-separated repo-relative file paths>"`,
    'Note: the full record and its paired summary ({slug}.summary.md) must both be written before registering. Registration lands in the hot zone (.rdd/exploration/hot.json) and is retrievable immediately.',
  ].join('\n')
}

/**
 * Cache-first code exploration as one model-facing tool. The tool reads the
 * repository's `.rdd/exploration` cache (shared with the rdd-engine CLI and
 * other AI clients) — merged over the hot zone and the persistent index, hot
 * first with the serving zone (`origin`) annotated — then runs the precision
 * pipeline INSIDE the tool: pluggable multi-recall (lexical BM25 + vector
 * cosine) -> RRF fusion -> Top-K truncation. Results non-empty = HIT (the
 * relevance verdict is the interface's, deterministic and testable — read the
 * summaries by rank); empty = MISS and a worker subagent is dispatched through
 * the `ctx.subagents` service — so a preset that mounts this tool instead of
 * `tool-subagent` makes the cache the only exploration path the model can
 * take.
 *
 * While the session runs, a periodic timer (Config `maintenanceIntervalMinutes`,
 * default 60, `0` disables) maintains the cache without any tool call: one
 * dual-zone freshness pass plus a hot-zone sweep per tick, so the persistent
 * index keeps accumulating even when no RDD activity touches the cache.
 *
 * Named exports only (`name`/`inject`/`Config`/`apply`): a default export
 * would make the Loader drop this function plugin's inject metadata.
 * @module @coderrdd/dsh-rdd-explore
 */

import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ObjectJsonSchema } from '@deepseek-ai/dsh-tools'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import type { SubagentResult, SubagentRun } from '@deepseek-ai/dsh-subagent'
import { effectiveSandboxMode, setSandboxMode } from '@deepseek-ai/dsh-sandbox-policy'
import {
  maintainCache,
  mergedFresh,
  readSearchConfig,
  registerEntry,
  runRecallPipeline,
  slugifyKey,
  writeArtifacts,
  type RegisterResult,
} from './cache.js'
import { lexicalRecaller } from './recallers/lexical.js'
import { vectorRecaller } from './recallers/vector.js'
import { buildDispatchPrompt } from './dispatch.js'

export const name = 'rdd-explore'
export const inject = ['tools', 'subagents']

/** This package's root on disk (lib/../) — anchors the vendored guide candidate. */
const PACKAGE_ROOT = dirname(dirname(fileURLToPath(import.meta.url)))

/** Plugin configuration. */
export interface Config {
  /** The `ctx.subagents` provider name to dispatch workers on. Default `spawn`. */
  provider?: string
  /** Model-facing tool name. Default `rdd_explore`. */
  toolName?: string
  /**
   * Absolute rdd-engine skill directory (contains `references/exploration-guide.md`).
   * Default: discovered through the candidate chain — config override, the
   * project layouts (`.rdd/skills/rdd-engine`, `.agents/skills/rdd-engine`,
   * `rdd-engine`), this package's vendored `assets/rdd-engine`, then the
   * user-level `~/.rdd/engine/current` install.
   */
  engineRoot?: string
  /**
   * Absolute repository root that owns `.rdd/`. Default: the nearest `.git`
   * ancestor of the process working directory (dsh's project-root rule).
   */
  repoRoot?: string
  /**
   * Who registers finished artifacts: `'worker'` keeps the CLI self-registration
   * in the child's prompt (pwsh required on every platform); `'plugin'` has the
   * child write a sidecar meta file which this plugin registers after the run
   * (cross-platform, and the recommended mode for dsh).
   */
  registerMode?: 'worker' | 'plugin'
  /** Per-child persona shadowing the deployment persona. */
  persona?: string
  /** Per-child tool filter forwarded to the provider. */
  toolFilter?: { allow?: string[]; deny?: string[] }
  /**
   * Skill names the `skill` tool refuses to load in this composition. The
   * catalog still lists them (skill-filesystem has no per-skill filter), so
   * this pre-execute denial is the enforcement point; a denied call returns
   * an error explaining where the content lives instead.
   */
  forbiddenSkills?: string[]
  /**
   * Session-workspace-relative prefixes the `write`/`edit` tools may target;
   * a call outside every prefix is denied with a teaching error. Omit for no
   * guard (the sandbox's own mode still applies).
   */
  writePrefixes?: string[]
  /**
   * Seed this session as OS-level read-only at its first tool call: one
   * `sandbox/mode` session event, appended only when the session has no
   * explicit override yet. A later UI switch appends after it and an approved
   * escalation still outranks the fold, so the seed is a default rather than a
   * lock. The exploration worker is unaffected: it has no write tools.
   */
  sessionReadOnly?: boolean
  /**
   * Periodic cache maintenance interval in minutes while the session runs:
   * each tick runs one dual-zone freshness pass plus a hot-zone sweep
   * (promote retention-expired / capacity-overflowing hot entries into
   * index.json, evict stale entries) with no tool call required. Default 60;
   * `0` disables the timer — call-driven maintenance on register/persist/read
   * remains either way.
   */
  maintenanceIntervalMinutes?: number
}

export const Config: z<Config> = z.object({
  provider: z.string().default('spawn'),
  toolName: z.string().default('rdd_explore'),
  engineRoot: z.string(),
  repoRoot: z.string(),
  registerMode: z.union(['worker', 'plugin'] as const).default('plugin'),
  persona: z.string(),
  // Preserve omission; Schemastery's `{ allow: [] }` default would deny every tool.
  toolFilter: z.object({
    allow: z.array(z.string()).default(undefined as unknown as string[]),
    deny: z.array(z.string()).default(undefined as unknown as string[]),
  }).default(undefined as unknown as { allow: string[]; deny: string[] }),
  forbiddenSkills: z.array(z.string()).default(undefined as unknown as string[]),
  writePrefixes: z.array(z.string()).default(undefined as unknown as string[]),
  sessionReadOnly: z.boolean().default(undefined as unknown as boolean),
  maintenanceIntervalMinutes: z.number().step(1).min(0).default(60),
})

/**
 * Whether one model-provided file path stays inside the session workspace and
 * under one allowed prefix. Relative paths resolve against the session cwd;
 * the comparison uses platform `relative`, so Windows matches
 * case-insensitively.
 * @param cwd - the session workspace directory.
 * @param filePath - the model-provided target path.
 * @param prefixes - normalized workspace-relative prefixes (no trailing slash).
 * @returns whether the write target is allowed.
 */
export function isAllowedWrite(cwd: string, filePath: string, prefixes: readonly string[]): boolean {
  const root = resolve(cwd)
  const rel = relative(root, resolve(root, filePath))
  if (rel === '' || rel === '..' || rel.startsWith('..\\') || rel.startsWith('../') || isAbsolute(rel)) return false
  const normalized = rel.replaceAll('\\', '/')
  return prefixes.some(prefix => normalized === prefix || normalized.startsWith(`${prefix}/`))
}

/** Normalize one configured write prefix to forward-slash form without a trailing slash. */
function normalizePrefix(prefix: string): string {
  return prefix.replace(/\\/g, '/').replace(/\/+$/, '')
}

/** One ranked cache candidate projected for the model (schema-shaped). */
interface CandidateView {
  key: string
  tags: string[]
  brief: string
  summaryPath: string
  fullPath: string
  /** Which zone served this candidate: the hot zone (recent, un-promoted) or the persistent index. */
  origin: 'hot' | 'persistent'
  /** Fused RRF score, rounded to 6 decimals (frozen with the engine). */
  score: number
  /** Recall paths that qualified this candidate, in registration order. */
  recalledBy: string[]
}

/** The pipeline's per-call observability (schema-shaped). */
interface RankMetaView {
  recallers: Array<{ name: string; status: 'ok' | 'disabled' | 'failed'; qualified: number; warning?: string }>
  fused: number
  returned: number
}

/** The tool's canonical output. */
type ToolValue =
  | { outcome: 'candidates'; query: string; candidates: CandidateView[]; rankMeta: RankMetaView }
  | { outcome: 'dispatched'; query: string; report: string; registered: RegisterResult[] }

/** The worker's structured-output schema for plugin-mode runs (the enforced JSON Schema subset). */
const EXPLORATION_OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['key', 'tags', 'brief', 'summary', 'full', 'files'],
  properties: {
    key: { type: 'string' },
    tags: { type: 'array', items: { type: 'string' } },
    brief: { type: 'string' },
    summary: { type: 'string' },
    full: { type: 'string' },
    files: { type: 'array', items: { type: 'string' } },
  },
} satisfies ObjectJsonSchema

const TOOL_DESCRIPTION =
  'Query this repository\'s RDD exploration cache before searching code yourself. Relevance is decided '
  + 'INSIDE the tool: multi-recall (lexical BM25 + vector cosine) fused via RRF and truncated to Top-K, so '
  + 'non-empty results are already the relevant ones — read the summaries (key, brief, fused score, and the '
  + 'paths of a short summary plus the full record, ranked best-first with the serving zone) instead of '
  + 're-scanning tags yourself. Empty results mean the cache has nothing relevant: the tool dispatches a '
  + 'worker subagent that explores the code, writes a paired record and summary under '
  + '.rdd/exploration/artifacts/, registers them into the hot zone, and returns the worker\'s report '
  + '(force_dispatch: true skips the cache and dispatches immediately). Use it for recurring exploration '
  + 'themes (module overviews, middleware chains, data flows); use direct glob/grep for one-off lookups.'

/**
 * Walk up from a start directory to the nearest `.git` marker; with none,
 * fall back to the start itself, matching dsh's project-root rule.
 * @param start - the session workspace cwd (or process cwd for non-agent callers).
 * @returns the resolved repository root.
 */
function findRepoRoot(start: string): string {
  let dir = resolve(start)
  for (;;) {
    if (existsSync(join(dir, '.git'))) return dir
    const parent = dirname(dir)
    if (parent === dir) return resolve(start)
    dir = parent
  }
}

/**
 * Resolve the rdd-engine skill directory from config or the standard
 * installation layouts, failing loud when no candidate carries the
 * exploration-guide reference the dispatch prompt needs.
 *
 * Candidate chain (first hit wins; the probe is always
 * `references/exploration-guide.md` existence):
 *  ① `engineRoot` config override
 *  ② `<repoRoot>/.rdd/skills/rdd-engine` (v1 coderrdd project layout)
 *  ③ `<repoRoot>/.agents/skills/rdd-engine`
 *  ④ `<repoRoot>/rdd-engine` (codeRDD checkout layout)
 *  ⑤ the vendored guide inside this package (`assets/rdd-engine`) — the
 *     install-anywhere fallback: the tool works in ANY dsh project, with or
 *     without rdd-engine checked out or installed
 *  ⑥ `~/.rdd/engine/current` (user-level engine install; keeps worker mode
 *     usable outside rdd projects — mirrors engine-location.md's chain)
 * @param configured - the configured override, when present.
 * @param repoRoot - the resolved repository root.
 * @returns the absolute engine directory.
 */
export function resolveEngineRoot(configured: string | undefined, repoRoot: string): string {
  const candidates = [
    ...(configured !== undefined ? [resolve(configured)] : []),
    join(repoRoot, '.rdd', 'skills', 'rdd-engine'),
    join(repoRoot, '.agents', 'skills', 'rdd-engine'),
    join(repoRoot, 'rdd-engine'),
    join(PACKAGE_ROOT, 'assets', 'rdd-engine'),
    join(homedir(), '.rdd', 'engine', 'current'),
  ]
  const found = candidates.find(dir => existsSync(join(dir, 'references', 'exploration-guide.md')))
  if (found === undefined) {
    throw new Error(
      `rdd-explore: no rdd-engine skill directory found (looked for references/exploration-guide.md under: ${candidates.join('; ')}). `
      + 'The plugin ships a vendored guide at assets/rdd-engine inside the package — if this error appears, the installation is broken. '
      + 'Reinstall the plugin (dsh plugin --profile <name> add <dsh-rdd-explore.tgz>) or set engineRoot in the plugin row config.',
    )
  }
  return found
}

/** A non-`completed` stop reason means the worker did not finish cleanly. */
function stopReasonError(result: SubagentResult): string | undefined {
  switch (result.stopReason) {
    case 'completed':
      return undefined
    case 'aborted':
      return 'exploration worker was cancelled'
    case 'error':
      return 'exploration worker failed'
    case 'max-tokens':
      return 'exploration worker hit its token limit before finishing'
    case 'refusal':
      return 'exploration worker declined the task'
    // Merge-extensible union: treat an unknown terminal reason as a failure.
    default:
      return `exploration worker ended abnormally (${String(result.stopReason)})`
  }
}

/** Join a worker result's text blocks into one report string. */
function textOf(result: SubagentResult): string {
  return result.output
    .filter((block): block is Extract<ContentBlock, { type: 'text' }> => block.type === 'text')
    .map(block => block.text)
    .join('')
}

/**
 * Collect and release one foreground worker run without letting disposal
 * replace an independent result failure, mirroring `tool-subagent`'s
 * foreground settlement.
 * @param run - the started run.
 * @returns the worker's terminal result (text output and structured payload).
 */
async function settleWorkerRun(run: SubagentRun): Promise<SubagentResult> {
  const [execution] = await Promise.allSettled([
    run.result.then((result): SubagentResult => {
      const error = stopReasonError(result)
      if (error !== undefined) {
        const diagnostic = result.diagnostic === undefined ? '' : `\nDiagnostic: ${result.diagnostic}`
        const partial = textOf(result)
        throw new Error(partial === '' ? `${error}${diagnostic}` : `${error}${diagnostic}\nPartial output before the run ended:\n${partial}`)
      }
      return result
    }),
  ])
  const [disposal] = await Promise.allSettled([Promise.resolve().then(() => run.dispose())])
  if (execution.status === 'rejected') {
    if (disposal.status === 'rejected') {
      throw new AggregateError(
        [execution.reason, disposal.reason],
        `exploration worker failed: ${String(execution.reason)}; dispose failed: ${String(disposal.reason)}`,
      )
    }
    throw execution.reason
  }
  if (disposal.status === 'rejected') throw disposal.reason
  return execution.value
}

/** The worker's structured exploration payload (the run's outputSchema shape). */
interface ExplorationPayload {
  readonly key: string
  readonly tags: readonly string[]
  readonly brief: string
  readonly summary: string
  readonly full: string
  readonly files: readonly string[]
}

/**
 * Narrow the provider-validated structured result into the exploration
 * payload, re-checking the model-boundary semantic minimums the schema cannot
 * express (non-empty content, at least one tag and one anchor file).
 * @param result - the settled worker result.
 * @returns the validated payload.
 */
function structuredPayloadOf(result: SubagentResult): ExplorationPayload {
  const value = result.structured
  if (typeof value !== 'object' || value === null) {
    throw new Error(
      'exploration worker finished without a structured result; the run may have ended before capturing it '
      + '(registerMode plugin requires the outputSchema capability on the provider)',
    )
  }
  const payload = value as Partial<ExplorationPayload>
  if (
    typeof payload.key !== 'string' || payload.key.trim() === ''
    || typeof payload.brief !== 'string' || payload.brief.trim() === ''
    || typeof payload.summary !== 'string' || payload.summary.trim() === ''
    || typeof payload.full !== 'string' || payload.full.trim() === ''
    || !Array.isArray(payload.tags) || payload.tags.length === 0
    || !Array.isArray(payload.files) || payload.files.length === 0
    || !payload.tags.every(tag => typeof tag === 'string' && tag.trim() !== '')
    || !payload.files.every(file => typeof file === 'string' && file.trim() !== '')
  ) {
    throw new Error(
      'exploration worker returned an incomplete structured result; expected non-empty { key, tags[] (>=1), brief, summary, full, files[] (>=1) }',
    )
  }
  // The guard above verified every field; the cast records that runtime fact.
  return payload as ExplorationPayload
}

/**
 * Register the tool: cache query first, worker dispatch on miss or force.
 * @param ctx - registrant context carrying the tool and subagent services.
 * @param config - deployment configuration.
 */
export function apply(ctx: Context, config: Config): void {
  const toolName = config.toolName ?? 'rdd_explore'

  const forbidden = config.forbiddenSkills !== undefined && config.forbiddenSkills.length > 0
    ? new Set(config.forbiddenSkills)
    : undefined
  const writePrefixes = config.writePrefixes !== undefined && config.writePrefixes.length > 0
    ? config.writePrefixes.map(normalizePrefix)
    : undefined
  const sessionReadOnly = config.sessionReadOnly === true
  if (forbidden !== undefined || writePrefixes !== undefined || sessionReadOnly) {
    // All three policies enforce at the decision point; prompt clauses are
    // not enforcement. Seeding happens here so the SAME call's policy
    // resolution (inside the tool body, after pre-execute) already folds it.
    ctx.on('tools/pre-execute', (exec, next) => {
      const session = exec.agent?.session
      if (sessionReadOnly && session !== undefined && effectiveSandboxMode(session.events) === undefined) {
        setSandboxMode(session, 'read-only')
      }
      const args = exec.arguments
      const fields = typeof args === 'object' && args !== null && !Array.isArray(args)
        ? args as { name?: unknown; file_path?: unknown }
        : undefined
      if (forbidden !== undefined && exec.name === 'skill' && typeof fields?.name === 'string' && forbidden.has(fields.name)) {
        return Promise.resolve({
          kind: 'deny' as const,
          reason: `skill "${fields.name}" is forbidden in this session: its content is already in this session's `
          + 'system prompt or carried by the rdd_explore tool; read references directly with the read tool',
        })
      }
      if (
        writePrefixes !== undefined && (exec.name === 'write' || exec.name === 'edit')
        && typeof fields?.file_path === 'string' && session !== undefined
        && !isAllowedWrite(session.header.cwd ?? process.cwd(), fields.file_path, writePrefixes)
      ) {
        return Promise.resolve({
          kind: 'deny' as const,
          reason: `"${fields.file_path}" is outside this role's write whitelist (${writePrefixes.join(', ')}); `
          + 'this session produces only its own artifacts under those prefixes',
        })
      }
      return next()
    })
  }

  // --- Periodic cache maintenance ------------------------------------------
  // One freshness pass plus one sweep per interval, no tool call required —
  // the hot zone keeps promoting into index.json and shedding stale entries
  // even when no RDD session touches the cache. apply has no session context
  // to resolve a repo root from (presets mount per-session fiber; the host
  // process cwd is NOT the session project), so the target pins on the first
  // tool call and never drifts afterwards; ticks before the pin skip, and the
  // first pinned tick sweeps any backlog idempotently.
  let pinnedRepoRoot: string | undefined
  const maintenanceIntervalMs = (config.maintenanceIntervalMinutes ?? 60) * 60_000
  if (maintenanceIntervalMs > 0) {
    ctx.effect(() => {
      const timer = setInterval(() => {
        const target = config.repoRoot !== undefined ? resolve(config.repoRoot) : pinnedRepoRoot
        if (target === undefined) return
        void maintainCache(join(target, '.rdd', 'exploration'), target).catch((error: unknown) => {
          // Only maintenance failures (IO/parse) land here; the next tick
          // retries idempotently, so warn instead of letting the error
          // surface as an unhandled rejection.
          console.warn(`[rdd-explore] periodic maintenance failed (retried idempotently next tick): ${String(error)}`)
        })
      }, maintenanceIntervalMs)
      timer.unref() // a CLI single-task process must not be held open by maintenance
      return () => clearInterval(timer)
    }, 'rdd-explore: periodic cache maintenance')
  }

  ctx.tools.register(defineTool({
    name: toolName,
    description: TOOL_DESCRIPTION,
    parameters: {
      query: {
        type: 'string',
        required: true,
        description: 'What to explore in the codebase — the requirement or topic, in the user\'s words.',
      },
      force_dispatch: {
        type: 'boolean',
        description: 'Skip the cache and dispatch the worker immediately. Results are pre-filtered by the pipeline; set this only to force a fresh exploration.',
      },
    },
    output: {
      schema: {
        oneOf: [
          {
            type: 'object',
            additionalProperties: false,
            properties: {
              outcome: { type: 'string', required: true, const: 'candidates' },
              query: { type: 'string', required: true },
              candidates: {
                type: 'array',
                required: true,
                items: {
                  type: 'object',
                  additionalProperties: false,
                  properties: {
                    key: { type: 'string', required: true },
                    tags: { type: 'array', required: true, items: { type: 'string' } },
                    brief: { type: 'string', required: true },
                    summaryPath: { type: 'string', required: true },
                    fullPath: { type: 'string', required: true },
                    origin: { type: 'string', required: true, enum: ['hot', 'persistent'] },
                    score: { type: 'number', required: true },
                    recalledBy: { type: 'array', required: true, items: { type: 'string' } },
                  },
                },
              },
              rankMeta: {
                type: 'object',
                required: true,
                additionalProperties: false,
                properties: {
                  recallers: {
                    type: 'array',
                    required: true,
                    items: {
                      type: 'object',
                      additionalProperties: false,
                      properties: {
                        name: { type: 'string', required: true },
                        status: { type: 'string', required: true, enum: ['ok', 'disabled', 'failed'] },
                        qualified: { type: 'integer', required: true },
                        warning: { type: 'string' },
                      },
                    },
                  },
                  fused: { type: 'integer', required: true },
                  returned: { type: 'integer', required: true },
                },
              },
            },
          },
          {
            type: 'object',
            additionalProperties: false,
            properties: {
              outcome: { type: 'string', required: true, const: 'dispatched' },
              query: { type: 'string', required: true },
              report: { type: 'string', required: true },
              registered: {
                type: 'array',
                required: true,
                items: {
                  type: 'object',
                  additionalProperties: false,
                  properties: {
                    key: { type: 'string', required: true },
                    path: { type: 'string', required: true },
                    summaryPath: { type: 'string', required: true },
                    tagsCount: { type: 'integer', required: true },
                    filesCount: { type: 'integer', required: true },
                  },
                },
              },
            },
          },
        ],
      },
      render: (_args, value) => [{
        type: 'text',
        text: renderValue(value as ToolValue),
      }],
    },
    // Registration writes the shared hot zone; keep concurrent calls serialized.
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      const parent = exec.agent
      if (!parent) {
        throw new Error(`${toolName} requires a calling agent (exec.agent was undefined)`)
      }

      // The session workspace owns .rdd/: resolve per call from the session cwd
      // (the GUI session's project), never the host process launch dir — the
      // same rule tool-fs applies via session.header.cwd.
      const repoRoot = config.repoRoot !== undefined
        ? resolve(config.repoRoot)
        : findRepoRoot(parent.session.header.cwd ?? process.cwd())
      // Freeze the periodic-maintenance target on the first call; later
      // sessions' cwds never drift the pin (same config-first rule the timer
      // reads, so the two resolutions cannot disagree).
      if (config.repoRoot === undefined) pinnedRepoRoot ??= repoRoot
      const engineRoot = resolveEngineRoot(config.engineRoot, repoRoot)
      const explorationDir = join(repoRoot, '.rdd', 'exploration')
      const artifactsDir = join(explorationDir, 'artifacts')

      // 1. Merged dual-zone cache read with stale cleanup, exactly as the
      // engine read face does: hot first (newest registeredAt first), then
      // the persistent index; hot shadows same-key/same-artifact persistent
      // entries; stale entries are evicted from their own zone.
      const { results: merged } = await mergedFresh(explorationDir, repoRoot)

      // 2. Precision pipeline INSIDE the tool (frozen contract with the
      // engine): multi-recall -> RRF fusion -> Top-K. Non-empty results are
      // the interface's deterministic relevance verdict (HIT — read summaries
      // by rank); empty means MISS -> dispatch below. A disabled or failed
      // recall path degrades to the remaining paths, never to an error.
      const searchConfig = await readSearchConfig(explorationDir)
      const { results: ranked, rankMeta } = await runRecallPipeline({
        query: args.query,
        merged,
        config: searchConfig,
        explorationDir,
        recallers: [lexicalRecaller, vectorRecaller],
      })
      if (ranked.length > 0 && args.force_dispatch !== true) {
        const candidates: CandidateView[] = ranked.map(result => ({
          key: result.key,
          tags: [...result.tags],
          brief: result.brief,
          summaryPath: result.summaryPath,
          fullPath: result.fullPath,
          origin: result.origin,
          score: result.score,
          recalledBy: [...result.recalledBy],
        }))
        const metaView: RankMetaView = {
          recallers: rankMeta.recallers.map(outcome => {
            const view: RankMetaView['recallers'][number] = {
              name: outcome.name,
              status: outcome.status,
              qualified: outcome.qualified,
            }
            if (outcome.warning !== undefined) view.warning = outcome.warning
            return view
          }),
          fused: rankMeta.fused,
          returned: rankMeta.returned,
        }
        return { outcome: 'candidates', query: args.query, candidates, rankMeta: metaView } satisfies ToolValue
      }

      // 3. Dispatch the worker through the subagent service. Plugin mode runs
      // a pure researcher: the structured output carries the payload, and the
      // plugin (trusted code) owns every cache mutation afterwards.
      const registerMode = config.registerMode ?? 'plugin'
      const prompt = await buildDispatchPrompt({
        query: args.query,
        repoRoot,
        explorationDir,
        artifactsDir,
        engineRoot,
        registerMode,
      })
      const run: SubagentRun = await ctx.subagents.start(config.provider ?? 'spawn', {
        label: `rdd-explore: ${args.query.slice(0, 60)}`,
        prompt: [{ type: 'text', text: prompt }] as ContentBlock[],
        parent,
        signal: exec.signal,
        ...(registerMode !== 'worker' ? { outputSchema: EXPLORATION_OUTPUT_SCHEMA } : {}),
        ...(config.persona !== undefined ? { persona: config.persona } : {}),
        ...(config.toolFilter !== undefined ? { toolFilter: config.toolFilter } : {}),
      })
      const result = await settleWorkerRun(run)
      const report = textOf(result)

      // 4. Plugin-mode persistence from the structured payload: artifacts
      // land on disk, the entry registers into the HOT zone (visible to the
      // very next query, no async pipeline required).
      const registered: RegisterResult[] = []
      if (registerMode !== 'worker') {
        const payload = structuredPayloadOf(result)
        const { fullAbs } = await writeArtifacts(artifactsDir, slugifyKey(payload.key), payload.full, payload.summary)
        registered.push(await registerEntry(explorationDir, {
          key: payload.key,
          tags: payload.tags,
          brief: payload.brief,
          artifactAbsPath: fullAbs,
          repoRoot,
          files: payload.files,
        }))
      }
      return { outcome: 'dispatched', query: args.query, report, registered } satisfies ToolValue
    },
    presentCall: args => ({ card: 'generic', title: 'Explore code (RDD cache)', kind: 'other', rawInput: args }),
  }))
}

/** Render the canonical value as the model-facing text block. */
function renderValue(value: ToolValue): string {
  if (value.outcome === 'candidates') {
    if (value.candidates.length === 0) {
      return 'Cache has nothing relevant; dispatched an exploration worker.'
    }
    const lines = value.candidates.map(candidate =>
      `- ${candidate.key} — ${candidate.brief} (score ${candidate.score} via ${candidate.recalledBy.join('+')}, ${candidate.origin === 'hot' ? 'hot zone' : 'persistent'}) summary: ${candidate.summaryPath}`)
    const paths = value.rankMeta.recallers.map(outcome => `${outcome.name}:${outcome.status}`).join(', ')
    return `Ranked cache results for ${JSON.stringify(value.query)}:\n${lines.join('\n')}\n`
      + `Results are already relevance-filtered and Top-K truncated (${value.rankMeta.fused} recalled, ${value.rankMeta.returned} returned; recallers: ${paths}). `
      + 'Read the summaries from the top; use force_dispatch: true only to force a fresh exploration.'
  }
  const registered = value.registered.length === 0
    ? ''
    : `\nRegistered: ${value.registered.map(result => `${result.key} (${result.path})`).join('; ')}`
  return `Exploration worker report:\n${value.report}${registered}`
}

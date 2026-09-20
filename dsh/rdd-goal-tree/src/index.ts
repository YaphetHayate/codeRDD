/**
 * rdd-goal-tree, host half: one read-only HTTP surface over the repository's
 * goal-tree runs, plus the worker-report → Planner callback.
 *
 * `GET /rdd-goal-tree/runs?cwd=<session workspace>` resolves the repo root
 * (nearest `.git` ancestor, the same rule dsh-rdd-explore applies) and
 * aggregates `.rdd/goal-trees/` state files through the pure
 * {@link aggregateGoalTrees} — no goal-tree CLI invocation, no write primitive,
 * no lock. The browser half (exports["./client"], discovered via the
 * `dsh.client` declaration) polls this endpoint and renders the dock strip.
 *
 * The callback side watches ledgers of the repositories the endpoint served
 * (a plain interval over a bounded LRU of roots). Each NEW ledger report
 * entry is delivered once into the CURRENT effective planner session's inbox
 * (`agent.inbox.append('next-turn', …` — the same durable queue the goal
 * round driver uses): target resolution is fresh-lease-first — a fresh
 * `planner-lease.json` holder (`^dsh-<sid>`) wins, else the additive
 * `state/planner.json` sidecar (written when a dsh session runs goal-tree
 * start / bridge promulgate) carries the run-creating session id; legacy runs
 * with neither are skipped. Delivery never starts a turn by itself.
 *
 * Runtime imports beyond the platform: `createUserMessage` (dsh-llm) and the
 * `agents` registry service (dsh-agent). Everything else is type-only.
 * @module @coderrdd/dsh-rdd-goal-tree
 */

import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { SessionId } from '@deepseek-ai/dsh-session'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
// Type-only: pulls the webServer Context declaration merge (ctx.webServer).
import type {} from '@deepseek-ai/dsh-host-webserver'
import { aggregateGoalTrees, artifactLine, collectReportEntries, readPlannerLease, type GoalTreeReportEntry } from './goaltrees.js'

export const name = 'rdd-goal-tree'
export const inject = ['webServer', 'agents']

/** Plugin configuration (declared inline; every field optional). */
export interface Config {
  /** Absolute repository root override; default resolves per request from the cwd query. */
  repoRoot?: string
  /** Deliver worker-report callbacks to the Planner session's inbox. Default true. */
  notifyPlanner?: boolean
  /** Ledger scan cadence in milliseconds. Default 5000; <= 0 disables the watcher. */
  scanIntervalMs?: number
}

/** This plugin's identity in message sources (also the dedupe marker). */
const PLUGIN_ID = '@coderrdd/dsh-rdd-goal-tree'

/**
 * Walk up from a start directory to the nearest `.git` marker; with none,
 * fall back to the start itself — dsh's project-root rule, identical to
 * dsh-rdd-explore's `findRepoRoot`.
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

const ENDPOINT_PATH = '/rdd-goal-tree/runs'
const LIVENESS_PATH = '/rdd-goal-tree/liveness'

/**
 * Serve `GET /rdd-goal-tree/runs?cwd=…`: the whole run list for the session's
 * repository, JSON-serialized {@link aggregateGoalTrees} output.
 */
async function serve(req: IncomingMessage, res: ServerResponse, config: Config, learnRoot: (root: string) => void): Promise<void> {
  const send = (status: number, body: unknown): void => {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
    res.end(JSON.stringify(body))
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    send(405, { error: 'method not allowed' })
    return
  }
  const url = new URL(req.url ?? '/', 'http://localhost')
  const pathname = decodeURIComponent(url.pathname)
  if (pathname !== ENDPOINT_PATH) {
    send(404, { error: 'unknown resource' })
    return
  }
  const cwd = url.searchParams.get('cwd')
  if (cwd === null || cwd.trim() === '') {
    send(400, { error: 'missing cwd query parameter' })
    return
  }
  try {
    const repoRoot = config.repoRoot !== undefined ? resolve(config.repoRoot) : findRepoRoot(cwd)
    learnRoot(repoRoot)
    const { runs } = await aggregateGoalTrees(join(repoRoot, '.rdd', 'goal-trees'))
    send(200, { repoRoot, runs })
  } catch (error) {
    send(500, { error: error instanceof Error ? error.message : String(error) })
  }
}

/**
 * Serve `GET /rdd-goal-tree/liveness?cwd=…&run=…&node=…`: read-only session
 * liveness for one claimed node — the claims-sidecar session id joined against
 * the agents registry (the SAME source the worker-report callback delivery
 * uses: resolvable = alive). Consumed by the engine bridge's reclaim precheck
 * (RECLAIM_TARGET_ALIVE / unknown fallback); read-only, never starts a turn.
 */
async function serveLiveness(
  req: IncomingMessage,
  res: ServerResponse,
  config: Config,
  ctx: Context,
): Promise<void> {
  const send = (status: number, body: unknown): void => {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
    res.end(JSON.stringify(body))
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    send(405, { error: 'method not allowed' })
    return
  }
  const url = new URL(req.url ?? '/', 'http://localhost')
  const run = url.searchParams.get('run')
  const node = url.searchParams.get('node')
  if ((run === null || run.trim() === '') || (node === null || node.trim() === '')) {
    send(400, { error: 'missing run or node query parameter' })
    return
  }
  const cwd = url.searchParams.get('cwd') ?? ''
  try {
    const repoRoot = config.repoRoot !== undefined ? resolve(config.repoRoot) : findRepoRoot(cwd)
    const { runs } = await aggregateGoalTrees(join(repoRoot, '.rdd', 'goal-trees'))
    const view = runs.find(r => r.runId === run)
    const viewNode = view?.nodes.find(n => n.id === node) ?? null
    const sessionId = viewNode?.claimSessionId ?? null
    if (sessionId === null) {
      send(200, { run, node, session_id: null, liveness: 'unknown', reason: 'no dsh session binding on the claim sidecar' })
      return
    }
    let liveness: 'alive' | 'dead' = 'dead'
    try {
      const agent = ctx.agents.get(sessionId as SessionId)
      liveness = agent !== undefined ? 'alive' : 'dead'
    } catch {
      liveness = 'dead'
    }
    send(200, { run, node, session_id: sessionId, liveness, reason: 'agents registry (same source as callback delivery)' })
  } catch (error) {
    send(500, { error: error instanceof Error ? error.message : String(error) })
  }
}

/**
 * The watcher: bounded LRU of served repo roots, rescanned on an interval.
 * Every not-yet-delivered ledger entry is reported into its run's Planner
 * session inbox exactly once (an in-memory delivered set plus an inbox scan,
 * so a plugin restart cannot double-deliver what a previous life queued).
 */
class PlannerCallbackWatcher {
  private readonly delivered = new Set<string>()
  private readonly roots = new Map<string, number>()
  private timer: ReturnType<typeof setInterval> | undefined

  constructor(
    private readonly ctx: Context,
    private readonly enabled: boolean,
    private readonly intervalMs: number,
  ) {}

  /** Record a repository the endpoint served; the scan loop picks it up. */
  learn(repoRoot: string): void {
    if (!this.enabled) return
    this.roots.set(repoRoot, Date.now())
    if (this.roots.size > 8) {
      // Evict the least recently touched root.
      let oldest: string | undefined
      let oldestAt = Number.POSITIVE_INFINITY
      for (const [root, at] of this.roots) {
        if (at < oldestAt) {
          oldestAt = at
          oldest = root
        }
      }
      if (oldest !== undefined) this.roots.delete(oldest)
    }
  }

  start(): void {
    if (!this.enabled || this.intervalMs <= 0 || this.timer !== undefined) return
    this.timer = setInterval(() => { void this.scan() }, this.intervalMs)
    this.timer.unref?.()
  }

  stop(): void {
    if (this.timer !== undefined) clearInterval(this.timer)
    this.timer = undefined
  }

  /** One scan pass over every learned root; per-root errors are logged and swallowed. */
  private async scan(): Promise<void> {
    for (const repoRoot of [...this.roots.keys()]) {
      try {
        await this.scanRoot(repoRoot)
      } catch (error) {
        this.ctx.logger.warn(`rdd-goal-tree: callback scan failed for ${repoRoot}: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  }

  private async scanRoot(repoRoot: string): Promise<void> {
    const goalTreesRoot = join(repoRoot, '.rdd', 'goal-trees')
    const [entries, { runs }] = await Promise.all([
      collectReportEntries(goalTreesRoot),
      aggregateGoalTrees(goalTreesRoot),
    ])
    const plannerOf = new Map<string, string | null>()
    for (const run of runs) {
      // Callback-target resolution (planner-uniqueness-callback): fresh-lease
      // first, planner.json fallback. A FRESH planner-lease.json holder
      // (^dsh-<sid>) wins — takeover/resume hand the lease to the new planner
      // session without touching planner.json, so lease-first re-points
      // delivery and repairs the resume break. Anything else (no lease, stale
      // lease, non-dsh holder) falls back to the run-creating planner.json
      // sidecar: a mistakenly started second planner never holds the lease,
      // so callbacks keep reaching the original planner (no drift). The
      // exactly-once dedupe key (repo::run::entry) is target-independent.
      plannerOf.set(run.runId, (await readPlannerLease(join(goalTreesRoot, run.runId))) ?? run.plannerSessionId)
    }
    for (const entry of entries) {
      const key = `${repoRoot}::${entry.runId}::${entry.entryId}`
      if (this.delivered.has(key)) continue
      const plannerSessionId = plannerOf.get(entry.runId) ?? null
      if (plannerSessionId === null) continue // legacy run (no planner sidecar): no callback target
      const agent = this.resolveAgent(plannerSessionId)
      if (agent === undefined) continue // planner session not live in this process; retry next scan
      if (this.alreadyQueued(agent, entry)) {
        this.delivered.add(key) // a previous plugin life delivered it: mark and move on
        continue
      }
      agent.inbox.append('next-turn', this.buildMessage(entry))
      this.delivered.add(key)
      this.ctx.logger.info(`rdd-goal-tree: callback delivered — run "${entry.runId}" ${entry.entryId} (${entry.nodeId} by ${entry.worker ?? '?'}) → session ${plannerSessionId}`)
    }
  }

  /** Resolve a live Agent by session id (agent id ≡ session id in this deployment). */
  private resolveAgent(sessionId: string): Agent | undefined {
    try {
      return this.ctx.agents.get(sessionId as SessionId)
    } catch {
      return undefined
    }
  }

  /** Whether this exact entry's callback already sits in the agent's pending queue. */
  private alreadyQueued(agent: Agent, entry: GoalTreeReportEntry): boolean {
    const marker = `ledger ${entry.entryId}`
    for (const message of [...agent.inbox.nextTurn, ...agent.inbox.nextStep]) {
      if (message.source.kind !== 'plugin' || message.source.plugin !== PLUGIN_ID) continue
      for (const block of message.content) {
        if (block.type === 'text' && block.text.includes(marker)) return true
      }
    }
    return false
  }

  /** One queued context message for the Planner. */
  private buildMessage(entry: GoalTreeReportEntry) {
    const summary = (entry.summary ?? '').replace(/\s+/g, ' ').slice(0, 160)
    const confidence = entry.confidence === null ? '' : ` confidence=${entry.confidence}`
    // Artifact locations (planner-callback-handoff): the Planner settles from
    // this single message — change list, deliverable doc pointer, verification
    // digest — without consulting the ledger.
    const text = [
      `[rdd-goal-tree] run "${entry.runId}" · node ${entry.nodeId} reported by ${entry.worker ?? 'unknown'} — verdict=${entry.verdict ?? 'unknown'}${confidence} (ledger ${entry.entryId}).`,
      artifactLine(entry),
      'Planner action: settle (goal-tree.cmd -Command settle) or prune with a reason, or graft follow-up nodes; reported nodes are never re-consumed.',
      ...(summary === '' ? [] : [`Worker summary: ${summary}`]),
    ].join('\n')
    return createUserMessage({
      content: [{ type: 'text', text }],
      source: {
        kind: 'plugin',
        plugin: PLUGIN_ID,
        context: { form: 'notice', summary: `goal-tree ${entry.nodeId} reported (${entry.verdict ?? 'unknown'})` },
      },
    })
  }
}

/**
 * Plugin body: register the read-only prefix route and start the watcher.
 * @param ctx - host plugin context carrying the webServer and agents services.
 * @param config - deployment configuration.
 */
export function apply(ctx: Context, config: Config = {}): void {
  const watcher = new PlannerCallbackWatcher(ctx, config.notifyPlanner !== false, config.scanIntervalMs ?? 5_000)

  ctx.effect(
    () => ctx.webServer.register({
      kind: 'prefix',
      path: '/rdd-goal-tree',
      handler: (req: IncomingMessage, res: ServerResponse): Promise<void> | void => {
        const pathname = decodeURIComponent(new URL(req.url ?? '/', 'http://localhost').pathname)
        if (pathname === LIVENESS_PATH) return serveLiveness(req, res, config, ctx)
        return serve(req, res, config, root => watcher.learn(root))
      },
    }),
    'rdd-goal-tree: read-only run status + claim liveness route',
  )

  if (config.notifyPlanner !== false && (config.scanIntervalMs ?? 5_000) > 0) {
    ctx.effect(() => {
      watcher.start()
      return () => watcher.stop()
    }, 'rdd-goal-tree: worker-report callback watcher')
  }
}

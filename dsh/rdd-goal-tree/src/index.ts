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
 * The callback side (see ./watcher.ts) watches ledgers of the repositories
 * the endpoint served. Each NEW ledger report entry / open escalation is
 * delivered once into the CURRENT effective planner session via
 * `agent.send(…, 'next-turn', true)` — the same durable queue boundary the
 * goal round driver drains, plus the wake that makes an idle planner session
 * actually consume it (the F3 ruling): fresh-lease-first target resolution,
 * exactly-once dedupe (repo::run::marker) across plugin lives.
 *
 * Runtime imports beyond the platform: `createUserMessage` (dsh-llm) and the
 * `agents` registry service (dsh-agent). Everything else is type-only.
 * @module @coderrdd/dsh-rdd-goal-tree
 */

import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import type { SessionId } from '@deepseek-ai/dsh-session'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
// Type-only: pulls the webServer Context declaration merge (ctx.webServer).
import type {} from '@deepseek-ai/dsh-host-webserver'
import { aggregateGoalTrees } from './goaltrees.js'
import { PlannerCallbackWatcher } from './watcher.js'

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
 * Plugin body: register the read-only prefix route and start the watcher.
 * @param ctx - host plugin context carrying the webServer and agents services.
 * @param config - deployment configuration.
 */
export function apply(ctx: Context, config: Config = {}): void {
  const watcher = new PlannerCallbackWatcher(ctx, config.notifyPlanner !== false, config.scanIntervalMs ?? 5_000, createUserMessage)

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

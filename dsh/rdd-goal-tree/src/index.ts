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
 * Payload (plugin-perf L3): the default response carries run SUMMARIES —
 * every run-level scalar plus slim census nodes; full node detail (task
 * texts, doc links, mockup chips) ships only for runs with a LIVE dsh-bound
 * claim (the run some worker session renders now) or through the
 * `&run=<runId>` detail form, which returns that one run in full. The
 * aggregation itself runs concurrently behind a per-run mtime-fingerprint
 * cache (plugin-perf L1/L2), so a poll re-stats a handful of files instead
 * of re-reading every run from zero.
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
import { aggregateGoalTrees, projectRunView, readClaimSession } from './goaltrees.js'
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
 * Whether one run carries a LIVE dsh-bound claim (plugin-perf L3's detail
 * rule): a claim sidecar whose session still resolves in the agents registry
 * — the same liveness source the callback delivery and the liveness route
 * use. Historical claims (finished runs, dead sessions) are exactly the runs
 * NO session renders as its worker view, so they ship slim; a live worker
 * session implies its run ships full, which is precisely when the task text
 * and doc chips are needed. Registry lookups are in-memory — cheap enough
 * to run per request over every node.
 */
function hasLiveClaimSession(run: { nodes: ReadonlyArray<{ claimSessionId: string | null }> }, ctx: Context): boolean {
  return run.nodes.some(node => {
    if (node.claimSessionId === null) return false
    try {
      return ctx.agents.get(node.claimSessionId as SessionId) !== undefined
    } catch {
      return false
    }
  })
}

/**
 * Serve `GET /rdd-goal-tree/runs?cwd=…`: the run list for the session's
 * repository. Default form — run summaries plus slim nodes; full detail only
 * for runs with a LIVE dsh-bound claim (the run some worker session renders
 * NOW — see {@link hasLiveClaimSession}). Detail form `?cwd=…&run=<runId>` —
 * exactly that run with full node detail, in the same `{repoRoot, runs}`
 * envelope (an unknown run yields an empty list, never an error, so
 * old-host/new-client mixes degrade to the slim rendering).
 */
async function serve(req: IncomingMessage, res: ServerResponse, config: Config, ctx: Context, learnRoot: (root: string) => void): Promise<void> {
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
  const runParam = url.searchParams.get('run')
  try {
    const repoRoot = config.repoRoot !== undefined ? resolve(config.repoRoot) : findRepoRoot(cwd)
    learnRoot(repoRoot)
    // repoRoot passed explicitly so doc-pointer resolution (node-doc-links)
    // never depends on the two-level-parent derivation.
    const { runs } = await aggregateGoalTrees(join(repoRoot, '.rdd', 'goal-trees'), repoRoot)
    if (runParam !== null && runParam.trim() !== '') {
      // detail form (plugin-perf L3): one run, full node detail — a client
      // expanding a slim run fetches exactly what it renders.
      const one = runs.find(r => r.runId === runParam)
      send(200, { repoRoot, runs: one === undefined ? [] : [projectRunView(one, true)] })
      return
    }
    // default form: summaries + slim nodes; full detail only for runs a LIVE
    // worker session renders — every run-level scalar stays present so the
    // bar header (and old clients) render unchanged.
    send(200, { repoRoot, runs: runs.map(r => projectRunView(r, hasLiveClaimSession(r, ctx))) })
  } catch (error) {
    send(500, { error: error instanceof Error ? error.message : String(error) })
  }
}

/**
 * Serve `GET /rdd-goal-tree/liveness?cwd=…&run=…&node=…` — and the session-
 * keyed variant `?cwd=…&session_id=…`: read-only session liveness against the
 * agents registry (the SAME source the worker-report callback delivery uses:
 * resolvable = alive). The node-keyed form resolves the claims-sidecar session
 * id first (consumed by the engine bridge's reclaim precheck —
 * RECLAIM_TARGET_ALIVE / unknown fallback); the session-keyed form queries the
 * registry directly with the caller's id (consumed by the bridge's reuse
 * resolution — roster candidates are historical dispatches with no live claim
 * sidecar). Read-only either way, never starts a turn. Without session_id the
 * behavior is unchanged (byte-identical legacy contract).
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
  const sessionIdParam = url.searchParams.get('session_id')
  if (sessionIdParam !== null && sessionIdParam.trim() !== '') {
    // session-keyed probe (inplace-redo-session-reuse): registry direct, no
    // sidecar resolution — the run/node query params are ignored in this form.
    // Failure semantics (liveness-false-dead fix): a registry MISS is
    // 'unknown', never 'dead' — the in-process registry only carries LOADED
    // conversations, so a miss conflates "unloaded but resumable" with
    // "terminal", and a false 'dead' unlocks exactly the wrong action
    // (reclaim/prune of a live worker). A probe EXCEPTION is equally
    // 'unknown' — errors are not death verdicts. Only an explicit terminal
    // signal may ever answer 'dead'; this view has none, so it never does.
    let liveness: 'alive' | 'unknown' = 'unknown'
    let reason = 'session not live in this process (unloaded or terminal — unverifiable here)'
    try {
      const agent = ctx.agents.get(sessionIdParam as SessionId)
      if (agent !== undefined) {
        liveness = 'alive'
        reason = 'agents registry (session-keyed probe)'
      }
    } catch (error) {
      reason = `registry probe failed: ${error instanceof Error ? error.message : String(error)}`
    }
    send(200, { session_id: sessionIdParam, liveness, reason })
    return
  }
  const run = url.searchParams.get('run')
  const node = url.searchParams.get('node')
  if ((run === null || run.trim() === '') || (node === null || node.trim() === '')) {
    send(400, { error: 'missing run or node query parameter' })
    return
  }
  const cwd = url.searchParams.get('cwd') ?? ''
  try {
    const repoRoot = config.repoRoot !== undefined ? resolve(config.repoRoot) : findRepoRoot(cwd)
    // Liveness shortcut (plugin-perf L2): the node-keyed probe reads the one
    // claim sidecar directly instead of aggregating every run — the binding
    // lives in state/claims/<node>.json and nothing else is needed.
    // Failure semantics: identical to the session-keyed form above
    // (liveness-false-dead fix) — miss and exception both answer 'unknown';
    // this view never asserts 'dead'.
    const sessionId = await readClaimSession(join(repoRoot, '.rdd', 'goal-trees'), run, node)
    if (sessionId === null) {
      send(200, { run, node, session_id: null, liveness: 'unknown', reason: 'no dsh session binding on the claim sidecar' })
      return
    }
    let liveness: 'alive' | 'unknown' = 'unknown'
    let reason = 'session not live in this process (unloaded or terminal — unverifiable here)'
    try {
      const agent = ctx.agents.get(sessionId as SessionId)
      if (agent !== undefined) {
        liveness = 'alive'
        reason = 'agents registry (same source as callback delivery)'
      }
    } catch (error) {
      reason = `registry probe failed: ${error instanceof Error ? error.message : String(error)}`
    }
    send(200, { run, node, session_id: sessionId, liveness, reason })
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
        return serve(req, res, config, ctx, root => watcher.learn(root))
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

/**
 * The Planner callback watcher — worker-report callbacks plus pure-auto-mode
 * escalation notices (planner-auto-mode), extracted from the host-half entry
 * so the smoke suite can drive it standalone: every `@deepseek-ai/*` import
 * here is type-only and the one runtime dependency (the identified-message
 * factory) is constructor-injected, so `lib/watcher.js` loads under a bare
 * harness with no DSH profile store in reach.
 *
 * A bounded LRU of served repo roots, rescanned on an interval. Every
 * not-yet-delivered ledger entry / open escalation is delivered ONCE into
 * the run's Planner session via `agent.send(message, 'next-turn', true)`:
 * routed to the same durable next-turn queue the goal-round driver drains
 * AND waking the driver (the F3 ruling, 2026-09-22) — a merely-queued
 * callback leaves an idle planner session forever unaware ("delivered but
 * asleep"), so the wake is part of the delivery contract, not an option.
 * Exactly-once rests on three layers: the in-memory delivered set, the
 * agent's pending-inbox scan, and a durable per-run marker sidecar
 * (`.callback-delivered.json`, incident 0923 fix).
 * @module rdd-goal-tree/watcher
 */

import { join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type { UserMessage, createUserMessage } from '@deepseek-ai/dsh-llm'
import { aggregateGoalTrees, artifactLine, collectDecisionEntries, collectReportEntries, readDeliveredMarkers, readPlannerLease, recordDeliveredMarker, type GoalTreeDecisionEntry, type GoalTreeReportEntry, type GoalTreeRunView } from './goaltrees.js'

/**
 * The identified-message factory planner notices are built with. Injected
 * through the constructor (the real `createUserMessage` is a `@deepseek-ai/dsh-llm`
 * runtime import the host entry supplies) — this module stays loadable
 * without the DSH profile store.
 */
export type UserMessageFactory = typeof createUserMessage

/** This plugin's identity in message sources (also the dedupe marker). */
const PLUGIN_ID = '@coderrdd/dsh-rdd-goal-tree'

/**
 * The backstop arm's cadence (planner-reconcile-throttle): a digest fires when
 * a scan tick crosses a 30-minute wall-clock boundary (:00/:30). The instant
 * arms stay event-driven; this arm only guarantees that nothing reported stays
 * unseen — it never replaces them.
 */
const DIGEST_PERIOD_MS = 30 * 60_000
/**
 * Planner quiet threshold for the backstop (planner-reconcile-throttle): a
 * planner whose session logged any event within this window is left alone (it
 * is being served by the instant arms or by the user); the dual predicate —
 * `status === 'idle'` AND last event older than the window — makes
 * better-safe-than-silent the rule: a miss only delays to the next boundary.
 */
const DIGEST_PLANNER_QUIET_MS = 30 * 60_000

/** One delivery the watcher owes the planner (built by scanRoot's two arms). */
interface PendingDelivery {
  runId: string
  /** Dedupe marker (`ledger L<n>` / `decision D<n>`) — also the inbox-scan probe. */
  marker: string
  message: UserMessage
  /** Log-line prefix; the resolved session id is appended on delivery. */
  log: string
}

/** The watcher: bounded LRU of served repo roots, rescanned on an interval. */
class PlannerCallbackWatcher {
  private readonly delivered = new Set<string>()
  private readonly roots = new Map<string, number>()
  private timer: ReturnType<typeof setInterval> | undefined
  /**
   * Overlap guard (duplicate-callback fix): a slow pass — cold aggregation
   * cache, a burst of fresh fixture runs — can outlive the interval tick, and
   * `setInterval` fires the next `void this.scan()` regardless. Two
   * concurrent passes double-walk the delivery arm and race the sidecar
   * rewrite; a tick that lands mid-pass is simply dropped (the next tick
   * re-derives everything — scans are stateless over the same files).
   */
  private scanning = false
  /** Last crossed 30-minute boundary (0 = never; a fresh watcher digests on its first scan — crash recovery). */
  private lastDigestSlot = 0

  constructor(
    private readonly ctx: Context,
    private readonly enabled: boolean,
    private readonly intervalMs: number,
    private readonly createMessage: UserMessageFactory,
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
    if (this.scanning) return // mid-pass tick dropped: see the field doc
    this.scanning = true
    try {
      const slot = Math.floor(Date.now() / DIGEST_PERIOD_MS)
      const digestDue = slot > this.lastDigestSlot
      if (digestDue) this.lastDigestSlot = slot
      for (const repoRoot of [...this.roots.keys()]) {
        try {
          await this.scanRoot(repoRoot, digestDue)
        } catch (error) {
          this.ctx.logger.warn(`rdd-goal-tree: callback scan failed for ${repoRoot}: ${error instanceof Error ? error.message : String(error)}`)
        }
      }
    } finally {
      this.scanning = false
    }
  }

  /** One scan pass over one root: resolve callback targets, then run both delivery arms. */
  private async scanRoot(repoRoot: string, digestDue = false): Promise<void> {
    const goalTreesRoot = join(repoRoot, '.rdd', 'goal-trees')
    const [entries, decisions, { runs }] = await Promise.all([
      collectReportEntries(goalTreesRoot),
      collectDecisionEntries(goalTreesRoot),
      aggregateGoalTrees(goalTreesRoot),
    ])
    const plannerOf = await this.resolvePlanners(repoRoot, goalTreesRoot, runs)
    await this.deliverPending(repoRoot, goalTreesRoot, plannerOf, entries.map(entry => ({
      runId: entry.runId,
      marker: `ledger ${entry.entryId}`,
      message: this.buildMessage(entry),
      log: `rdd-goal-tree: callback delivered — run "${entry.runId}" ${entry.entryId} (${entry.nodeId} by ${entry.worker ?? '?'})`,
    })))
    // planner-auto-mode: open escalations ride the same pipeline with a
    // `decision <id>` marker namespace (never collides with ledger ids).
    await this.deliverPending(repoRoot, goalTreesRoot, plannerOf, decisions.map(entry => ({
      runId: entry.runId,
      marker: `decision ${entry.entryId}`,
      message: this.buildDecisionMessage(entry),
      log: `rdd-goal-tree: escalation delivered — run "${entry.runId}" ${entry.entryId} (${entry.nodeId} checkpoint ${entry.checkpoint ?? '?'})`,
    })))
    if (digestDue) await this.digestBackstop(runs, plannerOf)
  }

  /**
   * The timed backstop arm (planner-reconcile-throttle): when a scan tick
   * crosses a 30-minute boundary, collect every ACTIVE tree's reported-but-
   * unsettled nodes into ONE digest per planner session and wake it — but only
   * through the dual quiet predicate (`status === 'idle'` AND no session event
   * within the quiet window). This mechanically replaces the planner-side
   * "reconcile on every wake" discipline: the digest message IS the
   * reconciliation result, so a woken planner always holds a concrete pending
   * list and never needs a speculative global status sweep.
   *
   * Deliberately NOT exactly-once-durable: a digest is a state reminder, not
   * an event — its throttle is the boundary cadence plus the predicates. A
   * planner that left some nodes unsettled simply gets them again next
   * boundary (they are still truly pending); once settled, the run drops out
   * of the collection by itself. Workers stuck on a question/permission never
   * enter: they are still `claimed` (no report), and an out-of-date-claim
   * never wakes the planner either — dead-claim judgement stays off this arm.
   */
  private async digestBackstop(runs: GoalTreeRunView[], plannerOf: Map<string, string | null>): Promise<void> {
    type DigestNode = { id: string; claimedBy: string | null; verdict: string | null; confidence: number | null }
    type DigestLine = { runId: string; nodes: DigestNode[] }
    const perPlanner = new Map<string, DigestLine[]>()
    for (const run of runs) {
      if (run.counts.reported <= 0) continue
      const reported = run.nodes.filter(node => node.status === 'reported')
      if (reported.length === 0) continue
      const plannerSessionId = plannerOf.get(run.runId) ?? null
      if (plannerSessionId === null) continue // legacy run: no callback target
      const lines = perPlanner.get(plannerSessionId) ?? []
      lines.push({ runId: run.runId, nodes: reported.map(node => ({ id: node.id, claimedBy: node.claimedBy, verdict: node.verdict, confidence: node.confidence })) })
      perPlanner.set(plannerSessionId, lines)
    }
    const marker = `digest ${Math.floor(Date.now() / DIGEST_PERIOD_MS)}`
    for (const [plannerSessionId, lines] of perPlanner) {
      const agent = this.resolveAgent(plannerSessionId)
      if (agent === undefined) {
        this.ctx.logger.info(`rdd-goal-tree: digest skipped — planner session ${plannerSessionId} not live in this process; retry next boundary`)
        continue
      }
      // dual quiet predicate: never interrupt a running turn (a planner held on
      // a question/permission is mid-turn => 'running'), never re-ping a
      // recently active one (the instant arms or the user just served it).
      let lastActive = 0
      try {
        const events = agent.session.events
        lastActive = events.length > 0 ? events[events.length - 1].time : 0
      } catch { lastActive = 0 } // unreadable log: treat as long-quiet (probe failure must not block the backstop)
      if (agent.status !== 'idle' || Date.now() - lastActive < DIGEST_PLANNER_QUIET_MS) continue
      if (this.alreadyQueued(agent, marker)) continue
      const message = this.buildDigestMessage(lines)
      agent.send(message, 'next-turn', true)
      this.ctx.logger.info(`rdd-goal-tree: digest backstop delivered (${lines.reduce((sum, line) => sum + line.nodes.length, 0)} reported node(s)) → session ${plannerSessionId}`)
    }
  }

  /**
   * The digest message (planner-reconcile-throttle): the unified
   * reported-but-unsettled list across the root's active trees. The message IS
   * the reconciliation result — the action line explicitly retires the global
   * status sweep the old discipline demanded on every wake.
   */
  private buildDigestMessage(lines: readonly { runId: string; nodes: { id: string; claimedBy: string | null; verdict: string | null; confidence: number | null }[] }[]) {
    const total = lines.reduce((sum, line) => sum + line.nodes.length, 0)
    const body = lines.map(line => {
      const parts = line.nodes.map(node => {
        const owner = node.claimedBy !== null ? ` by ${node.claimedBy}` : ''
        const conf = node.confidence !== null ? `, conf ${node.confidence}` : ''
        return `${node.id}${owner} (verdict=${node.verdict ?? '?'}${conf})`
      })
      return `- run "${line.runId}": ${parts.join(' / ')}`
    })
    const text = [
      `[rdd-goal-tree·定时兜底] ${total} 个节点已回调待裁决（规划者 30 分钟无活动，兜底唤醒——即时回调可能未达）。本消息即待决清单：`,
      ...body,
      'Planner action: 逐个 settle (goal-tree.cmd -Command settle) 或 prune with a reason; 处置需全树视野（graft 下探 / rollback 波及面）时才查对应 run。无需全局 status 对账——升级类消息自带裁定上下文，直接呈用户后 decide 记账。',
    ].join('\n')
    return this.createMessage({
      content: [{ type: 'text', text }],
      source: {
        kind: 'plugin',
        plugin: PLUGIN_ID,
        context: { form: 'notice', summary: `goal-tree digest: ${total} node(s) awaiting verdict` },
      },
    })
  }

  /**
   * Resolve every run's callback target (planner-uniqueness-callback) and
   * hydrate the run's persisted delivered-markers into the in-memory set
   * BEFORE the delivery loops (incident 0923 fix): after a host crash+restart
   * the in-memory set is empty and the inbox guard only sees still-PENDING
   * messages, which alone re-delivered the whole consumed ledger (the
   * L1..Ln replay storm); hydration is per-root-per-scan and idempotent.
   * Fresh-lease-first: a FRESH `planner-lease.json` holder (`^dsh-<sid>`)
   * wins — takeover/resume hand the lease to the new planner session without
   * touching planner.json, so lease-first re-points delivery and repairs the
   * resume break. Anything else (no lease, stale lease, non-dsh holder)
   * falls back to the run-creating planner.json sidecar: a mistakenly
   * started second planner never holds the lease, so callbacks keep reaching
   * the original planner (no drift). The exactly-once dedupe key
   * (repo::run::marker) is target-independent.
   */
  private async resolvePlanners(repoRoot: string, goalTreesRoot: string, runs: GoalTreeRunView[]): Promise<Map<string, string | null>> {
    const plannerOf = new Map<string, string | null>()
    for (const run of runs) {
      plannerOf.set(run.runId, (await readPlannerLease(join(goalTreesRoot, run.runId))) ?? run.plannerSessionId)
      for (const marker of await readDeliveredMarkers(join(goalTreesRoot, run.runId))) {
        this.delivered.add(`${repoRoot}::${run.runId}::${marker}`)
      }
    }
    return plannerOf
  }

  /**
   * The one shared delivery arm — ledger reports and open escalations are the
   * same exactly-once pipeline (the M1 dedupe: one skeleton, parameterized by
   * {@link PendingDelivery}): marker → planner resolution → live-agent
   * resolution → pending-inbox guard → wakeful send → durable marker → log.
   */
  private async deliverPending(repoRoot: string, goalTreesRoot: string, plannerOf: Map<string, string | null>, items: readonly PendingDelivery[]): Promise<void> {
    for (const item of items) {
      const key = `${repoRoot}::${item.runId}::${item.marker}`
      if (this.delivered.has(key)) continue
      const plannerSessionId = plannerOf.get(item.runId) ?? null
      if (plannerSessionId === null) continue // legacy run (no planner sidecar): no callback target
      const agent = this.resolveAgent(plannerSessionId)
      if (agent === undefined) continue // planner session not live in this process; retry next scan
      const runDir = join(goalTreesRoot, item.runId)
      if (this.alreadyQueued(agent, item.marker)) {
        await this.persist(runDir, key, item.marker) // a previous plugin life delivered it: mark and move on
        continue
      }
      agent.send(item.message, 'next-turn', true)
      await this.persist(runDir, key, item.marker)
      this.ctx.logger.info(`${item.log} → session ${plannerSessionId}`)
    }
  }

  /**
   * Mark one delivery as done in BOTH the in-memory set and the run's durable
   * sidecar (`.callback-delivered.json`) — sidecar failures are logged and
   * swallowed (advisory persistence: a failed write only re-opens the
   * restart-replay window for this one marker, it never blocks delivery).
   */
  private async persist(runDir: string, key: string, marker: string): Promise<void> {
    this.delivered.add(key)
    try {
      await recordDeliveredMarker(runDir, marker)
    } catch (error) {
      this.ctx.logger.warn(`rdd-goal-tree: delivered-marker persist failed for ${marker}: ${error instanceof Error ? error.message : String(error)}`)
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

  /**
   * Whether a callback carrying this marker already sits in the agent's
   * pending queue. Exact-token match (duplicate/missed-callback fix): the
   * old `text.includes(marker)` substring check matched `ledger L2` inside
   * `ledger L21` — whenever a higher-numbered sibling entry id was queued,
   * the shorter id was falsely treated as delivered, marked in the sidecar,
   * and its callback silently skipped (the planner only learned about the
   * node again through the 30-minute digest). Marker tokens are extracted
   * from the notice text and compared whole; unrelated digits never
   * collide. The digest marker namespace rides the same extraction.
   */
  private alreadyQueued(agent: Agent, marker: string): boolean {
    for (const message of [...agent.inbox.nextTurn, ...agent.inbox.nextStep]) {
      if (message.source.kind !== 'plugin' || message.source.plugin !== PLUGIN_ID) continue
      for (const block of message.content) {
        if (block.type !== 'text') continue
        for (const token of block.text.match(/\b(?:ledger|decision|digest)\s+[^\s,.;:)]+/g) ?? []) {
          if (token.replace(/\s+/g, ' ') === marker) return true
        }
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
    return this.createMessage({
      content: [{ type: 'text', text }],
      source: {
        kind: 'plugin',
        plugin: PLUGIN_ID,
        context: { form: 'notice', summary: `goal-tree ${entry.nodeId} reported (${entry.verdict ?? 'unknown'})` },
      },
    })
  }

  /**
   * One queued context message for an OPEN escalation (planner-auto-mode):
   * the "ask the user" chain's asynchronous arm — the worker escalated a
   * checkpoint the risk-grading table routes to humans and is WAITING. The
   * Planner presents this to the user (tool-ask-user is preset-mounted) and
   * records the verdict through the decide resolution command; delivery
   * wakes the planner session so the notice is consumed without a manual
   * nudge (the F3 ruling).
   */
  private buildDecisionMessage(entry: GoalTreeDecisionEntry) {
    const question = (entry.question ?? '').replace(/\s+/g, ' ').slice(0, 160)
    const inputs = entry.inputs === null ? '' : (entry.inputs.replace(/\s+/g, ' ').slice(0, 160))
    const text = [
      `[rdd-goal-tree] run "${entry.runId}" · node ${entry.nodeId} (${entry.stage ?? '?'}) escalated a checkpoint for human adjudication — decision ${entry.entryId} is OPEN; the worker is WAITING.`,
      `Checkpoint: ${entry.checkpoint ?? 'unspecified'} · risk=${entry.risk ?? 'unspecified'} · rule=${entry.ruleId ?? 'unmatched'}`,
      `Question: ${question === '' ? 'unspecified' : question}`,
      ...(inputs === '' ? [] : [`Inputs: ${inputs}`]),
      `Planner action: present this to the user, then record the verdict: delivery-bridge.cmd -Command decide -RunId ${entry.runId} -NodeId ${entry.nodeId} -Kind resolution -RefEntry ${entry.entryId} -Checkpoint "<checkpoint>" -Decision "<user verdict>". Open escalations remain visible via delivery-bridge status/resume.`,
    ].join('\n')
    return this.createMessage({
      content: [{ type: 'text', text }],
      source: {
        kind: 'plugin',
        plugin: PLUGIN_ID,
        context: { form: 'notice', summary: `goal-tree ${entry.nodeId} escalation open (${entry.entryId})` },
      },
    })
  }
}

export { PlannerCallbackWatcher }

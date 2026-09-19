/**
 * Pure aggregation over a repository's `.rdd/goal-trees/` state directory —
 * the read-only wire the DSH GoalTreeBar renders. File formats are the
 * rdd-engine goal-tree CLI's frozen contract (files are the only authority);
 * every read is tolerant: a missing manifest skips the run, a missing tree or
 * round log degrades to empty, so a partially written run never breaks the
 * endpoint. No goal-tree write primitive is ever touched from here.
 *
 * Session binding joins (both engine-written additive sidecars, absent on
 * legacy runs): `state/planner.json` carries the run-creating DSH session
 * (the worker-report callback target); `state/claims/<node>.json` carries the
 * claiming DSH session per node (a worker session's focused view).
 * @module rdd-goal-tree/goaltrees
 */

import { readdir, readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'

/** One tree node projected for the strip (depth is computed from the parent chain). */
export interface GoalTreeNodeView {
  id: string
  parent: string | null
  title: string
  /** The node's task text (what a worker session executes); null when absent. */
  task: string | null
  /**
   * Engine node type passthrough: 'goal' marks the original-requirement root
   * (unclaimable conclude anchor — rendered distinctly, excluded from the
   * status census); 'sweep'/'probe' appear as grafted; null on plain nodes.
   */
  type: string | null
  status: string
  claimedBy: string | null
  /** Latest reported verdict/confidence (null until a report lands). */
  verdict: string | null
  confidence: number | null
  /**
   * The DSH session id that claimed this node (joined from the engine's
   * state/claims/<node>.json sidecar; null outside dsh or on legacy claims).
   */
  claimSessionId: string | null
  /** Unsatisfied depends_on targets (the claim gate) — empty when none. */
  blockedBy: string[]
  depth: number
}

/** One run's whole status as the bar consumes it. */
export interface GoalTreeRunView {
  runId: string
  state: string
  goal: string
  /** Conclude outcome (achieved / budget_exhausted / space_exhausted), null while running. */
  outcome: string | null
  createdBy: string | null
  createdAt: string | null
  updatedAt: string | null
  maxRounds: number
  maxNodes: number
  /** Rounds actually started (the engine's last_round). */
  roundsUsed: number
  /** A started round without its end line, null when every round is closed. */
  openRound: number | null
  counts: { pending: number; claimed: number; reported: number; done: number; pruned: number }
  nodes: GoalTreeNodeView[]
  /**
   * The DSH session that started the run (joined from the engine's
   * state/planner.json sidecar; null outside dsh or on legacy runs) — the
   * worker-report callback target.
   */
  plannerSessionId: string | null
}

/** One ledger report entry (the callback payload's source facts). */
export interface GoalTreeReportEntry {
  runId: string
  entryId: string
  nodeId: string
  worker: string | null
  verdict: string | null
  confidence: number | null
  summary: string | null
  reportedAt: string | null
  /**
   * Artifact locations for the Planner's single-message verdict
   * (planner-callback-handoff): extracted from the ledger entry's callback —
   * citations count + first refs, the full_report doc pointer, and the
   * extras.verification digest. All degrade to empty/null on legacy entries.
   */
  citationCount: number
  /** First citation refs (bounded at 3 by collectReportEntries). */
  citationRefs: string[]
  fullReport: string | null
  verification: string | null
}

/** Compact-discipline cap shared by the callback message lines (chars). */
const MESSAGE_LINE_CAP = 160

/** Tolerant JSON file read: missing or unparsable returns undefined (never throws). */
async function readJson(file: string): Promise<Record<string, unknown> | undefined> {
  try {
    return JSON.parse(await readFile(file, 'utf8')) as Record<string, unknown>
  } catch {
    return undefined
  }
}

function num(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function str(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/**
 * Fold the append-only round log into { roundsUsed, openRound }: a start line
 * bumps the high-water round and opens it; an end line closes it.
 */
function foldRoundLog(lines: readonly string[]): { roundsUsed: number; openRound: number | null } {
  let roundsUsed = 0
  let openRound: number | null = null
  for (const line of lines) {
    const trimmed = line.trim()
    if (trimmed === '') continue
    let entry: Record<string, unknown>
    try {
      entry = JSON.parse(trimmed) as Record<string, unknown>
    } catch {
      continue // quarantined-shaped line: the engine isolates corruption; we skip
    }
    const round = num(entry.round, 0)
    if (round <= 0) continue
    if (entry.event === 'round-start') {
      roundsUsed = Math.max(roundsUsed, round)
      openRound = round
    } else if (entry.event === 'round-end' && openRound === round) {
      openRound = null
    }
  }
  return { roundsUsed, openRound }
}

/** Compute node depth via the parent chain (cycle-guarded; orphans sit at 1). */
function depthOf(id: string, parentOf: ReadonlyMap<string, string | null>): number {
  let depth = 0
  let cursor: string | null | undefined = id
  const seen = new Set<string>()
  while (cursor !== null && cursor !== undefined && !seen.has(cursor)) {
    seen.add(cursor)
    cursor = parentOf.get(cursor) ?? null
    depth += 1
    if (depth > 64) break
  }
  return Math.max(0, depth - 1)
}

/**
 * Aggregate every run directory under the goal-trees root.
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 * @returns runs sorted running-first then most recently updated; empty when the
 * directory is missing (a project with no goal-tree activity).
 */
export async function aggregateGoalTrees(rootDir: string): Promise<{ runs: GoalTreeRunView[] }> {
  const dirents = await readdir(rootDir, { withFileTypes: true }).catch(() => null)
  if (dirents === null) return { runs: [] } // no .rdd/goal-trees at all: nothing to show

  const runs: GoalTreeRunView[] = []
  for (const dirent of dirents) {
    if (!dirent.isDirectory() || dirent.name.startsWith('_') || dirent.name.startsWith('.')) continue
    const runDir = join(rootDir, dirent.name)

    const manifest = await readJson(join(runDir, 'manifest.json'))
    if (manifest === undefined) continue // not a run directory

    const tree = await readJson(join(runDir, 'state', 'tree.json'))
    const rawNodes = Array.isArray(tree?.nodes) ? (tree?.nodes as Record<string, unknown>[]) : []

    let roundLines: string[] = []
    try {
      roundLines = (await readFile(join(runDir, 'state', 'round-log.jsonl'), 'utf8')).split('\n')
    } catch {
      roundLines = [] // no rounds started yet
    }
    const { roundsUsed, openRound } = foldRoundLog(roundLines)

    // Session-binding sidecars (engine additive; both may be missing on legacy runs).
    const planner = await readJson(join(runDir, 'state', 'planner.json'))
    const claimDirents = await readdir(join(runDir, 'state', 'claims'), { withFileTypes: true }).catch(() => null)
    const claimSession = new Map<string, string>()
    if (claimDirents !== null) {
      for (const claimFile of claimDirents) {
        if (!claimFile.isFile() || !claimFile.name.endsWith('.json')) continue
        const claim = await readJson(join(runDir, 'state', 'claims', claimFile.name))
        const nodeId = str(claim?.node_id)
        const sessionId = str(claim?.dsh_session_id)
        if (nodeId !== null && sessionId !== null) claimSession.set(nodeId, sessionId)
      }
    }

    const parentOf = new Map<string, string | null>()
    const known = new Set<string>()
    const counts = { pending: 0, claimed: 0, reported: 0, done: 0, pruned: 0 }
    for (const node of rawNodes) {
      const id = typeof node.id === 'string' ? node.id : null
      if (id === null) continue
      known.add(id)
      parentOf.set(id, typeof node.parent === 'string' ? node.parent : null)
    }
    const nodes: GoalTreeNodeView[] = []
    for (const node of rawNodes) {
      const id = typeof node.id === 'string' ? node.id : null
      if (id === null) continue
      const status = typeof node.status === 'string' ? node.status : 'pending'
      const type = str(node.type)
      // The five-state census counts WORK nodes only: the type=goal root is the
      // original requirement's conclude anchor — pending forever by design and
      // never a delivery unit, so it stays out of every status count.
      if (type !== 'goal') {
        if (status === 'pending') counts.pending += 1
        else if (status === 'claimed') counts.claimed += 1
        else if (status === 'reported') counts.reported += 1
        else if (status === 'done') counts.done += 1
        else if (status === 'pruned') counts.pruned += 1
      }
      const dependsOn = Array.isArray(node.depends_on)
        ? (node.depends_on as unknown[]).filter((d): d is string => typeof d === 'string' && known.has(d) && d !== id)
        : []
      const confidenceRaw = node.last_confidence
      nodes.push({
        id,
        parent: parentOf.get(id) ?? null,
        title: typeof node.title === 'string' ? node.title : id,
        task: str(node.task),
        type,
        status,
        claimedBy: str(node.claimed_by),
        verdict: str(node.last_verdict),
        confidence: typeof confidenceRaw === 'number' && Number.isFinite(confidenceRaw) ? confidenceRaw : null,
        claimSessionId: claimSession.get(id) ?? null,
        blockedBy: dependsOn,
        depth: depthOf(id, parentOf),
      })
    }

    let updatedAt = str(tree?.updated_at)
    if (updatedAt === null) {
      try {
        updatedAt = new Date((await stat(join(runDir, 'state', 'tree.json'))).mtimeMs).toISOString()
      } catch {
        updatedAt = null
      }
    }

    const budget = (manifest.budget ?? {}) as Record<string, unknown>
    const concluded = (manifest.concluded ?? null) as Record<string, unknown> | null
    runs.push({
      runId: str(manifest.run_id) ?? dirent.name,
      state: str(manifest.state) ?? 'running',
      goal: str(manifest.goal) ?? '',
      outcome: concluded === null ? null : str(concluded.outcome),
      createdBy: str(manifest.created_by),
      createdAt: str(manifest.created_at),
      updatedAt,
      maxRounds: num(budget.max_rounds, 0),
      maxNodes: num(budget.max_nodes, 0),
      roundsUsed,
      openRound,
      counts,
      nodes,
      plannerSessionId: str(planner?.dsh_session_id),
    })
  }

  runs.sort((a, b) => {
    const rank = (run: GoalTreeRunView): number => (run.state === 'running' ? 0 : 1)
    if (rank(a) !== rank(b)) return rank(a) - rank(b)
    return (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '')
  })
  return { runs }
}

/**
 * Read one run's ledger text; null when the ledger is absent (a missing
 * ledger yields no entries — the run is skipped, never an error).
 */
async function readLedgerText(rootDir: string, runId: string): Promise<string | null> {
  try {
    return await readFile(join(rootDir, runId, 'state', 'ledger.jsonl'), 'utf8')
  } catch {
    return null
  }
}

/**
 * Project one ledger line into a report entry; null on blank, corrupt, or
 * id-less lines (corruption is the engine's quarantine domain — tolerated
 * here exactly like the round-log fold).
 */
function parseLedgerEntry(line: string, runId: string): GoalTreeReportEntry | null {
  const trimmed = line.trim()
  if (trimmed === '') return null
  let entry: Record<string, unknown>
  try {
    entry = JSON.parse(trimmed) as Record<string, unknown>
  } catch {
    return null
  }
  const entryId = str(entry.entry_id)
  const nodeId = str(entry.node_id)
  if (entryId === null || nodeId === null) return null
  const callback = (entry.callback ?? {}) as Record<string, unknown>
  const citations = Array.isArray(callback.citations)
    ? (callback.citations as Record<string, unknown>[])
    : []
  const citationRefs = citations
    .map(c => (typeof c?.ref === 'string' && c.ref !== '' ? c.ref : null))
    .filter((r): r is string => r !== null)
    .slice(0, 3)
  const extras = (callback.extras ?? {}) as Record<string, unknown>
  const verificationRaw = typeof extras.verification === 'string' ? extras.verification.replace(/\s+/g, ' ').trim() : ''
  return {
    runId,
    entryId,
    nodeId,
    worker: str(entry.worker),
    verdict: str(callback.verdict),
    confidence: typeof callback.confidence === 'number' && Number.isFinite(callback.confidence) ? callback.confidence : null,
    summary: str(callback.summary),
    reportedAt: str(entry.reported_at),
    citationCount: citations.length,
    citationRefs,
    fullReport: str(callback.full_report),
    verification: verificationRaw === '' ? null : verificationRaw.slice(0, MESSAGE_LINE_CAP),
  }
}

/**
 * Collect every ledger report entry across the runs of one goal-trees root —
 * the watcher's input for Planner callbacks. Per-run reads and per-line
 * projection live in the helpers above; corrupt lines are skipped (the
 * engine quarantines them); a missing ledger yields no entries.
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 */
export async function collectReportEntries(rootDir: string): Promise<GoalTreeReportEntry[]> {
  const { runs } = await aggregateGoalTrees(rootDir)
  const entries: GoalTreeReportEntry[] = []
  for (const run of runs) {
    const ledger = await readLedgerText(rootDir, run.runId)
    if (ledger === null) continue
    for (const line of ledger.split('\n')) {
      const entry = parseLedgerEntry(line, run.runId)
      if (entry !== null) entries.push(entry)
    }
  }
  return entries
}

/**
 * The artifact-location line for the Planner callback message
 * (planner-callback-handoff): `Changes: N (first 3 refs) / Doc: <full_report> /
 * Verified: <digest>` — the Planner judges a settle from this one message,
 * without consulting the ledger. Missing slots render as `none` (legacy
 * entries degrade visibly instead of silently). Line capped at
 * {@link MESSAGE_LINE_CAP} chars, continuing the summary's compact discipline.
 * Pure so it lives beside the extraction (client-side safe, smoke-testable).
 * @param entry - one collected report entry.
 */
export function artifactLine(entry: GoalTreeReportEntry): string {
  const changes = entry.citationCount > 0
    ? `${entry.citationCount}${entry.citationRefs.length > 0 ? ` (${entry.citationRefs.join(', ')})` : ''}`
    : 'none'
  const line = `Artifacts: Changes: ${changes} / Doc: ${entry.fullReport ?? 'none'} / Verified: ${entry.verification ?? 'none'}`
  return line.length > MESSAGE_LINE_CAP ? `${line.slice(0, MESSAGE_LINE_CAP - 1)}…` : line
}

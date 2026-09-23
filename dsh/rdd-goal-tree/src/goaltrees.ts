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
 * (the worker-report callback fallback target — a fresh planner-lease.json
 * holder wins over it, see {@link readPlannerLease});
 * `state/claims/<node>.json` carries the claiming DSH session per node (a
 * worker session's focused view).
 * @module rdd-goal-tree/goaltrees
 */

import { readdir, readFile, stat, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

/**
 * One clickable document pointer projected for the worker's structured rows
 * (node-doc-links): `rel` is the archive-relative spelling exactly as it
 * appears inside the node's task text (what the worker reads), `abs` is the
 * resolved absolute path under `.rdd/changes/archive/<归档名>/` (what the
 * browser half feeds `ctx.workspaces.openPath`), and `exists` is a host-side
 * stat so a not-yet-produced design doc (designDocs[].status=pending) renders
 * as a disabled chip instead of a dead link.
 */
export interface GoalTreeDocLink {
  rel: string
  abs: string
  exists: boolean
}

/**
 * The structured decomposition of a bridge node's synthesized task text
 * (delivery-bridge.ps1 `New-NodeTaskText` — the sole authoritative producer).
 * The worker strip renders these as dedicated slots instead of one blob;
 * null on every non-matching task (plain goal-tree runs, legacy shapes) —
 * the client then falls back to the plain single-line rendering.
 */
export interface GoalTreeNodeDocs {
  /** The goal sentence: 完成「<标题>」的 <阶段> 阶段（<阶段职责>）。 */
  goal: string
  stage: string
  /** Stage duty incl. its parens (（编码实现）); null when the template omitted it. */
  duty: string | null
  requirement: GoalTreeDocLink | null
  designs: GoalTreeDocLink[]
  /**
   * UX visual mockups enumerated from the archive's design/mockups/ directory
   * (ux-mockup-links): final.html, the gallery page, and the direction
   * artifacts (*.html / *.png). Unlike designs these never ride the task text
   * (UX registers only the spec .md in designDocs) — the host lists the
   * conventional directory instead. Empty when the archive carries none.
   */
  mockups: GoalTreeDocLink[]
}

/** One tree node projected for the strip (depth is computed from the parent chain). */
export interface GoalTreeNodeView {
  id: string
  parent: string | null
  title: string
  /** The node's task text (what a worker session executes); null when absent. */
  task: string | null
  /**
   * Structured decomposition of `task` when it carries the bridge template
   * (goal sentence + doc pointers); null on every other shape (legacy runs,
   * plain goal-tree tasks) — additive, never breaks the plain rendering.
   */
  docs: GoalTreeNodeDocs | null
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

/**
 * One open escalation entry from a bridge run's decisions.jsonl
 * (planner-auto-mode): a checkpoint the risk-grading table routed to humans.
 * "Open" is join-derived — a resolution/overturn entry references the
 * escalation via ref_entry; the ledger itself is never rewritten. Entries on
 * pruned nodes are still collected (flagged historical — the user may still
 * owe a verdict; the planner decides the disposition).
 */
export interface GoalTreeDecisionEntry {
  runId: string
  entryId: string
  nodeId: string
  stage: string | null
  checkpoint: string | null
  /** The question awaiting the user (the escalation's decision field). */
  question: string | null
  risk: string | null
  ruleId: string | null
  inputs: string | null
  basis: string | null
  at: string | null
}

/** Compact-discipline cap shared by the callback message lines (chars). */
const MESSAGE_LINE_CAP = 160

/**
 * Durable exactly-once marker store for planner callback delivery
 * (incident 0923 fix): one JSON sidecar per run, `<runDir>/.callback-delivered.json`
 * — `{"delivered": ["ledger L7", "decision D3", ...]}`. The in-memory delivered
 * set dies with the host process; without this sidecar a dsh crash+restart
 * re-delivers every already-consumed ledger entry (the L1..Ln replay storm —
 * the inbox guard only sees still-PENDING messages). Markers are namespaced
 * exactly like the runtime dedupe keys' suffixes (`ledger <id>` / `decision
 * <id>`), so both delivery loops share one store. Tolerant by design: a
 * missing or corrupt sidecar reads as empty (degrades to the pre-fix window,
 * never worse); writes rewrite the full sorted set.
 */
const DELIVERED_MARKERS_FILE = '.callback-delivered.json'

/** Read one run's delivered-marker set (missing/corrupt file -> empty set). */
export async function readDeliveredMarkers(runDir: string): Promise<Set<string>> {
  try {
    const raw = JSON.parse(await readFile(join(runDir, DELIVERED_MARKERS_FILE), 'utf8')) as { delivered?: unknown }
    const list = Array.isArray(raw?.delivered) ? (raw.delivered as unknown[]) : []
    return new Set(list.filter((m): m is string => typeof m === 'string' && m !== ''))
  } catch {
    return new Set<string>()
  }
}

/** Persist one delivered marker (idempotent; full-set rewrite keeps it plain). */
export async function recordDeliveredMarker(runDir: string, marker: string): Promise<void> {
  const current = await readDeliveredMarkers(runDir)
  if (current.has(marker)) return
  current.add(marker)
  await writeFile(join(runDir, DELIVERED_MARKERS_FILE), `${JSON.stringify({ delivered: [...current].sort() }, null, 2)}\n`, 'utf8')
}

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
 * Lease freshness window for callback-target resolution
 * (planner-uniqueness-callback). MUST stay in sync with the engine side:
 * delivery-bridge.ps1's `-LeaseStaleMinutes` default (30). A lease older than
 * this is stale — the resolver then falls back to the planner.json sidecar,
 * mirroring the engine's own lease-staleness gating.
 */
export const PLANNER_LEASE_FRESH_MS = 30 * 60 * 1000

/**
 * Resolve a callback target from the bridge-written lease sidecar
 * (planner-lease.json). Returns the DSH session id when the lease is FRESH
 * (within {@link PLANNER_LEASE_FRESH_MS}) and its holder is dsh-shaped
 * (`^dsh-<sid>$` — the bridge's prefix for DSH session holders); null
 * otherwise (no lease, stale lease, non-dsh holder such as a CLI pid,
 * unparsable file) so the caller falls back to the planner.json sidecar.
 * Tolerant by design: a corrupt lease must never break callback delivery.
 * Semantics (planner-uniqueness-callback): takeover/resume hand the lease to
 * the new planner session without touching planner.json, so lease-first
 * re-points delivery legally; a mistakenly started second planner never holds
 * the lease, so callbacks keep reaching the original planner (no drift, no
 * double delivery — the exactly-once key ignores the target).
 * @param runDir - absolute path of one run directory under the goal-trees root.
 */
export async function readPlannerLease(runDir: string): Promise<string | null> {
  const lease = await readJson(join(runDir, 'planner-lease.json'))
  if (lease === undefined) return null
  const acquiredAt = str(lease.acquired_at)
  const holder = str(lease.holder)
  if (acquiredAt === null || holder === null) return null
  const acquiredMs = Date.parse(acquiredAt)
  if (!Number.isFinite(acquiredMs)) return null
  if (Date.now() - acquiredMs > PLANNER_LEASE_FRESH_MS) return null // stale → planner.json fallback
  const match = /^dsh-(.+)$/.exec(holder)
  return match === null ? null : match[1]
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

// --- Structured node-task decomposition (node-doc-links) -----------------------
//
// The bridge synthesizes a bridge node's task text through the frozen template
// in delivery-bridge.ps1's New-NodeTaskText (sole authoritative producer):
//   目标：完成「<标题>」的 <阶段> 阶段（<职责>）。需求文档：<rel>[；设计文档：<rel>、<rel>…][；归档：<归档名>]。…
// The parser below mirrors that template exactly (the same regexes the engine
// side's Get-NodeTaskBrief uses to re-extract segments). Any non-matching text
// — plain goal-tree tasks, legacy shapes, the pre-template "Execute TaskId…"
// English signature — returns null: zero-injection degradation, the strip
// keeps rendering the raw task line.

/** Bridge task head: the goal sentence with title, stage, and stage duty. */
const BRIDGE_TASK_HEAD = /^目标：完成「(?<title>.+?)」的 (?<stage>CTO|UX|DEV|QA) 阶段(?<duty>（[^）]*）)?。/
/** One `；`-delimited pointer segment (需求文档 / 设计文档 / 归档). */
const bridgeSegment = (name: string): RegExp => new RegExp(`${name}：(?<v>[^；。]+)`)

/** The pure parse product: doc pointers are archive-relative, pre-resolution. */
export interface ParsedNodeTask {
  goal: string
  stage: string
  duty: string | null
  reqRel: string | null
  designRels: string[]
  archiveName: string | null
}

/**
 * Decompose a bridge node's task text into its structured segments. Pure and
 * total: every non-matching input (null/empty/free text) returns null.
 * @param task - the node's task text verbatim from state/tree.json.
 */
export function parseNodeTask(task: string | null): ParsedNodeTask | null {
  if (task === null || task === '') return null
  if (task.startsWith('Execute TaskId')) return null // legacy pre-template signature
  const head = BRIDGE_TASK_HEAD.exec(task)
  if (head?.groups === undefined) return null
  const title = head.groups.title ?? ''
  const stage = head.groups.stage
  const duty = head.groups.duty ?? null
  const req = bridgeSegment('需求文档').exec(task)?.groups?.v?.trim()
  const designs = bridgeSegment('设计文档').exec(task)?.groups?.v
  const archive = bridgeSegment('归档').exec(task)?.groups?.v?.trim()
  return {
    goal: `完成「${title}」的 ${stage} 阶段${duty ?? ''}。`,
    stage,
    duty,
    reqRel: req === undefined || req === '' ? null : req,
    designRels: designs === undefined
      ? []
      : designs.split('、').map(d => d.trim()).filter(d => d !== ''),
    archiveName: archive === undefined || archive === '' ? null : archive,
  }
}

/**
 * Resolve one archive-relative doc pointer into a wire link: absolute path
 * under the run's archive root plus a host-side existence stat. Never throws —
 * an unreadable path simply reports exists:false.
 */
async function toDocLink(archiveRoot: string, rel: string): Promise<GoalTreeDocLink> {
  const abs = join(archiveRoot, ...rel.split('/'))
  const exists = await stat(abs).then(() => true, () => false)
  return { rel, abs, exists }
}

// --- UX mockup enumeration (ux-mockup-links) ----------------------------------
//
// The UX role's Phase 2.5 artifacts (rdd-ux references/mockup-generation.md)
// land in the task archive's design/mockups/ directory by convention:
// final.html (the finalized mockup — DEV's primary visual reference),
// index.html (the gallery page copied from the fixed template), direction
// artifacts (*.html / *.png), and images/ (image-source references). Only the
// spec .md is registered in task.json designDocs, so the mockups never appear
// in the node's task text — the host enumerates the conventional directory
// instead and the worker view renders the links as an extra chip row. Read-only
// and convention-based: a missing directory simply yields no chips.

/** Visual-artifact extensions surfaced from design/mockups/. */
const MOCKUP_EXTS = new Set(['.html', '.png'])
/** Display priority: the finalized mockup first, then the gallery page. */
const MOCKUP_PRIORITY = ['final.html', 'index.html']
/** Chip budget per node — priority files first, then the name-sorted rest. */
const MOCKUP_CAP = 8
/** Walk guard: directory entries visited per archive (pathological dirs). */
const MOCKUP_WALK_CAP = 256

/** Lower-cased extension of one file name ('' when bare). */
function extOf(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot === -1 ? '' : name.slice(dot).toLowerCase()
}

/**
 * Enumerate one task archive's UX mockups — visual artifacts only
 * (manifest.json is the gallery's data source, not something to open).
 * Deterministic order: final.html, index.html, then the name-sorted rest,
 * capped at {@link MOCKUP_CAP}. Never throws: a missing or unreadable
 * design/mockups/ directory yields [].
 * @param archiveRoot - absolute path of `.rdd/changes/archive/<归档名>`.
 */
async function listMockupLinks(archiveRoot: string): Promise<GoalTreeDocLink[]> {
  const root = join(archiveRoot, 'design', 'mockups')
  const found: { rel: string; abs: string }[] = []
  const walk = async (dir: string, prefix: string, depth: number): Promise<void> => {
    const dirents = await readdir(dir, { withFileTypes: true }).catch(() => null)
    if (dirents === null) return
    for (const dirent of dirents) {
      if (found.length >= MOCKUP_WALK_CAP) return
      if (dirent.name.startsWith('.')) continue
      if (dirent.isDirectory()) {
        if (depth + 1 > 2) continue // mockups/ + images/ is the whole convention
        await walk(join(dir, dirent.name), `${prefix}${dirent.name}/`, depth + 1)
      } else if (dirent.isFile() && MOCKUP_EXTS.has(extOf(dirent.name))) {
        found.push({ rel: `design/mockups/${prefix}${dirent.name}`, abs: join(dir, dirent.name) })
      }
    }
  }
  await walk(root, '', 0)
  const rank = (rel: string): number => {
    const parts = rel.split('/')
    const index = MOCKUP_PRIORITY.indexOf(parts[parts.length - 1] ?? '')
    return index === -1 ? MOCKUP_PRIORITY.length : index
  }
  found.sort((a, b) => rank(a.rel) - rank(b.rel) || a.rel.localeCompare(b.rel))
  return found.slice(0, MOCKUP_CAP).map(f => ({ rel: f.rel, abs: f.abs, exists: true }))
}

/**
 * Aggregate every run directory under the goal-trees root.
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 * @param repoRootOverride - explicit repository root for doc-pointer
 * resolution (node-doc-links); defaults to the two-level parent of rootDir,
 * which is exactly `<repoRoot>` for the standard `.rdd/goal-trees` layout.
 * @returns runs sorted running-first then most recently updated; empty when the
 * directory is missing (a project with no goal-tree activity).
 */
export async function aggregateGoalTrees(rootDir: string, repoRootOverride?: string): Promise<{ runs: GoalTreeRunView[] }> {
  const repoRoot = repoRootOverride !== undefined ? repoRootOverride : dirname(dirname(rootDir))
  const dirents = await readdir(rootDir, { withFileTypes: true }).catch(() => null)
  if (dirents === null) return { runs: [] } // no .rdd/goal-trees at all: nothing to show

  const runs: GoalTreeRunView[] = []
  for (const dirent of dirents) {
    if (!dirent.isDirectory() || dirent.name.startsWith('_') || dirent.name.startsWith('.')) continue
    const runDir = join(rootDir, dirent.name)

    const manifest = await readJson(join(runDir, 'manifest.json'))
    if (manifest === undefined) continue // not a run directory
    const runId = str(manifest.run_id) ?? dirent.name

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
    // ux-mockup-links: one enumeration per archive per aggregate call — a
    // task's whole stage chain (UX→DEV→QA nodes) shares one archiveRoot, so
    // the directory walk happens once and every sibling node reuses the links.
    const mockupsByArchive = new Map<string, GoalTreeDocLink[]>()
    const mockupsFor = async (archiveRoot: string): Promise<GoalTreeDocLink[]> => {
      const cached = mockupsByArchive.get(archiveRoot)
      if (cached !== undefined) return cached
      const links = await listMockupLinks(archiveRoot)
      mockupsByArchive.set(archiveRoot, links)
      return links
    }
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
      const task = str(node.task)
      // node-doc-links: decompose a bridge-shaped task into structured slots
      // (goal sentence + doc pointers). Archive root resolution prefers the
      // template's own 归档 segment, falling back to the frozen deliver-<archive>
      // run-id convention; every non-bridge task parses to null (no rows, no
      // stats — the plain rendering is the zero-degradation path).
      let docs: GoalTreeNodeDocs | null = null
      const parsed = parseNodeTask(task)
      if (parsed !== null) {
        const archiveName = parsed.archiveName ?? runId.replace(/^deliver-/, '')
        const archiveRoot = join(repoRoot, '.rdd', 'changes', 'archive', archiveName)
        docs = {
          goal: parsed.goal,
          stage: parsed.stage,
          duty: parsed.duty,
          requirement: parsed.reqRel !== null ? await toDocLink(archiveRoot, parsed.reqRel) : null,
          designs: await Promise.all(parsed.designRels.map(rel => toDocLink(archiveRoot, rel))),
          mockups: await mockupsFor(archiveRoot),
        }
      }
      nodes.push({
        id,
        parent: parentOf.get(id) ?? null,
        title: typeof node.title === 'string' ? node.title : id,
        task,
        docs,
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
      runId,
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

/**
 * Read one run's decision-ledger text; null when absent (a run without pure
 * auto mode — the default — never writes decisions.jsonl).
 */
async function readDecisionsText(rootDir: string, runId: string): Promise<string | null> {
  try {
    return await readFile(join(rootDir, runId, 'decisions.jsonl'), 'utf8')
  } catch {
    return null
  }
}

/**
 * Project one decisions.jsonl line; null on blank/corrupt/id-less/kind-less
 * lines (same tolerance as {@link parseLedgerEntry}).
 */
function parseDecisionEntry(line: string, runId: string): Record<string, unknown> | null {
  const trimmed = line.trim()
  if (trimmed === '') return null
  try {
    const entry = JSON.parse(trimmed) as Record<string, unknown>
    if (typeof entry.entry_id !== 'string' || entry.entry_id === '') return null
    if (typeof entry.kind !== 'string' || entry.kind === '') return null
    return entry
  } catch {
    return null
  }
}

/**
 * Collect every OPEN escalation across the runs of one goal-trees root — the
 * watcher's input for the planner-auto-mode human-adjudication callback
 * (planner-auto-mode). An escalation is open until a resolution/overturn
 * entry references it via ref_entry (join-derived, ledger never rewritten);
 * an escalation that lands already-resolved never notifies (nothing to
 * adjudicate). Corrupt lines are skipped; a missing ledger yields no entries.
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 */
export async function collectDecisionEntries(rootDir: string): Promise<GoalTreeDecisionEntry[]> {
  const { runs } = await aggregateGoalTrees(rootDir)
  const open: GoalTreeDecisionEntry[] = []
  for (const run of runs) {
    const text = await readDecisionsText(rootDir, run.runId)
    if (text === null) continue
    const raw = text.split('\n')
      .map(line => parseDecisionEntry(line, run.runId))
      .filter((e): e is Record<string, unknown> => e !== null)
    // join inputs: entry_ids already closed by a resolution/overturn
    const referenced = new Set<string>()
    for (const entry of raw) {
      if (entry.kind === 'resolution' || entry.kind === 'overturn') {
        if (typeof entry.ref_entry === 'string' && entry.ref_entry !== '') referenced.add(entry.ref_entry)
      }
    }
    for (const entry of raw) {
      if (entry.kind !== 'escalation') continue
      const entryId = entry.entry_id as string
      if (referenced.has(entryId)) continue
      open.push({
        runId: run.runId,
        entryId,
        nodeId: str(entry.node_id) ?? '',
        stage: str(entry.stage),
        checkpoint: str(entry.checkpoint),
        question: str(entry.decision),
        risk: str(entry.risk),
        ruleId: str(entry.rule_id),
        inputs: str(entry.inputs),
        basis: str(entry.basis),
        at: str(entry.at),
      })
    }
  }
  return open
}

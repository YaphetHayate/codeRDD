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

import { readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join } from 'node:path'

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
  /**
   * Wake-model fields (goal-tree-wake-model §4): per-duty-segment wake usage.
   * wakeMax null = not stamped (payload never set one; the engine resolves the
   * run default at claim/redo time) — the badge then shows the count alone.
   * Containers and the goal root carry no quota.
   */
  wakeCount: number
  wakeMax: number | null
  /** Current duty segment label (e.g. 'cto' / 'design-review'); null when unset. */
  duty: string | null
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
 * One open escalation entry from a bridge run's unified decision ledger
 * `decisions.jsonl` — archive-level since planner-midrun-derive
 * (`.rdd/changes/archive/<归档名>/`, located through the run's bridge.json;
 * planner-auto-mode): a checkpoint the risk-grading table routed to humans.
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

/**
 * In-flight marker-write chains per run dir (duplicate-callback fix): the
 * sidecar update is a read-modify-write, so two concurrent writers —
 * overlapping scan passes (a slow cold scan outlives the 5s interval tick)
 * or a second host process watching the same repo — interleave their reads
 * and the last write silently drops the other's marker. Every write for one
 * run dir chains onto the previous one; the map entry is replaced with a
 * settled (never-rejecting) tail so one failure cannot poison the chain.
 */
const markerWriteChains = new Map<string, Promise<void>>()

/** Temp-file sequence for atomic sidecar replaces (per process). */
let markerTempSeq = 0

/**
 * Persist one delivered marker (idempotent; full-set rewrite keeps it plain).
 * Serialized per run dir ({@link markerWriteChains}) and committed by
 * write-temp-then-rename: a torn in-place write reads back as EMPTY on the
 * next restart hydration (the whole-ledger replay storm this sidecar exists
 * to prevent), while rename leaves either the old complete set or the new
 * one. Windows rename-over-locked-dest falls back to a direct complete
 * write (best effort) instead of dropping the marker.
 */
export async function recordDeliveredMarker(runDir: string, marker: string): Promise<void> {
  const previous = markerWriteChains.get(runDir) ?? Promise.resolve()
  const task = previous.then(() => writeDeliveredMarkerSerialized(runDir, marker))
  markerWriteChains.set(runDir, task.then(() => undefined, () => undefined))
  await task
}

/** The serialized write itself — one writer per run dir at a time. */
async function writeDeliveredMarkerSerialized(runDir: string, marker: string): Promise<void> {
  const file = join(runDir, DELIVERED_MARKERS_FILE)
  const current = await readDeliveredMarkers(runDir)
  if (current.has(marker)) return
  current.add(marker)
  const payload = `${JSON.stringify({ delivered: [...current].sort() }, null, 2)}\n`
  const temp = `${file}.tmp-${process.pid}-${++markerTempSeq}`
  try {
    await writeFile(temp, payload, 'utf8')
    await rename(temp, file)
  } catch {
    try { await unlink(temp) } catch { /* best-effort cleanup */ }
    await writeFile(file, payload, 'utf8')
  }
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

/**
 * Outline order for the wire node list: DFS pre-order from the roots, children
 * sorted by numeric node id (the engine assigns ids monotonically with graft
 * order). The panel renders this list as an indented outline whose nesting
 * semantics come from (order, depth) alone — but tree.json's array order is
 * GRAFT order, not a DFS traversal: a chain continuation grafted under n2
 * (n8) can follow later-created heads still hanging under n1 (n7), and the
 * outline then nests n8 visually under n7. Roots here also cover orphans (a
 * parent id absent from the set); anything unreachable through a corrupted
 * parent cycle is appended in input order — no node is ever dropped.
 * Twin of the client-side renderer guard in client/index.tsx (kept
 * dependency-free on both sides so each half can stand alone).
 */
export function orderOutlineNodes<T extends { id: string; parent: string | null }>(nodes: readonly T[]): T[] {
  const inputIndex = new Map<string, number>()
  for (const [i, node] of nodes.entries()) if (!inputIndex.has(node.id)) inputIndex.set(node.id, i)
  const known = new Set(inputIndex.keys())
  const numericId = (id: string): number => (/^n\d+$/.test(id) ? Number.parseInt(id.slice(1), 10) : Number.MAX_SAFE_INTEGER)
  const byOutline = (a: T, b: T): number => {
    const delta = numericId(a.id) - numericId(b.id)
    return delta !== 0 ? delta : (inputIndex.get(a.id) ?? 0) - (inputIndex.get(b.id) ?? 0)
  }
  const childrenOf = new Map<string, T[]>()
  const roots: T[] = []
  for (const node of nodes) {
    if (node.parent === null || !known.has(node.parent)) roots.push(node)
    else {
      const bucket = childrenOf.get(node.parent)
      if (bucket === undefined) childrenOf.set(node.parent, [node])
      else bucket.push(node)
    }
  }
  const out: T[] = []
  const seen = new Set<string>()
  const visit = (node: T): void => {
    if (seen.has(node.id)) return
    seen.add(node.id)
    out.push(node)
    const children = childrenOf.get(node.id)
    if (children === undefined) return
    children.sort(byOutline)
    for (const child of children) visit(child)
  }
  roots.sort(byOutline)
  for (const root of roots) visit(root)
  // cycle leftovers (parent chain never reaching a root): keep them visible
  if (out.length !== nodes.length) for (const node of nodes) visit(node)
  return out
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

// --- run aggregation cache (plugin-perf L2) ------------------------------------
//
// Per-run aggregation cache keyed by an mtime+size fingerprint over the run's
// state sources (manifest.json / state/tree.json / state/round-log.jsonl /
// state/planner.json / state/claims/*). A request re-stats only those few
// files; an unchanged fingerprint reuses the cached view verbatim — zero file
// re-reads, zero doc-link stats, zero mockup walks. A small TTL floor
// debounces even the fingerprint stats when the strip poll, liveness probes,
// and watcher scans land in a burst. Scope: the fingerprint covers run-state
// files only — archive-side doc/mockup appearance rides along the next
// tree.json write (every claim/settle/prune/graft rewrites it), never later
// than that.

/** Debounce floor between fingerprint re-stats of one run (ms). */
export const RUN_CACHE_TTL_MS = 2_000

let runCacheTtlMs = RUN_CACHE_TTL_MS

/**
 * Test seam for the smoke suite: shrink/expand the debounce floor (0 forces a
 * fingerprint re-stat on every call). Production code never calls this.
 */
export function setRunCacheTtlForTests(ms: number): void {
  runCacheTtlMs = ms
}

/** One cached run view plus the fingerprint and last-stat time guarding it. */
interface RunCacheEntry {
  fingerprint: string
  checkedAt: number
  /**
   * The aggregated view; null = the directory is not a run (cached so a
   * manifest landing inside the TTL window stays skipped until re-stat).
   */
  view: GoalTreeRunView | null
}

/** rootDir → run directory name → cache entry (vanished runs purged per pass). */
const runCache = new Map<string, Map<string, RunCacheEntry>>()

/** One file's fingerprint component: mtime+size, 'x' when absent. */
async function stampOf(file: string): Promise<string> {
  try {
    const info = await stat(file)
    return `${info.mtimeMs}:${info.size}`
  } catch {
    return 'x'
  }
}

/**
 * Compute one run's state-source fingerprint (plugin-perf L2): stat stamps of
 * the four fixed state files plus the sorted claims sidecars. Any write the
 * aggregation reads changes exactly one component.
 */
async function fingerprintRun(runDir: string): Promise<string> {
  const claimsDir = join(runDir, 'state', 'claims')
  const dirents = await readdir(claimsDir, { withFileTypes: true }).catch(() => null)
  const claimNames = dirents === null
    ? []
    : dirents.filter(d => d.isFile() && d.name.endsWith('.json')).map(d => d.name).sort()
  const parts = await Promise.all([
    stampOf(join(runDir, 'manifest.json')),
    stampOf(join(runDir, 'state', 'tree.json')),
    stampOf(join(runDir, 'state', 'round-log.jsonl')),
    stampOf(join(runDir, 'state', 'planner.json')),
    ...claimNames.map(name => stampOf(join(claimsDir, name))),
  ])
  return parts.join('|')
}

/**
 * Aggregate ONE run directory (plugin-perf L1): every read the old serial
 * pipeline issued — manifest, tree, round log, planner sidecar, all claim
 * sidecars, every node's doc links and mockup walks — now runs concurrently
 * (runs against each other via {@link aggregateGoalTrees}, files within the
 * run via Promise.all). Output and tolerance are identical to the serial
 * pipeline: a missing manifest skips the run (null), missing pieces degrade
 * to empty.
 */
async function aggregateOneRun(rootDir: string, dirName: string, repoRoot: string): Promise<GoalTreeRunView | null> {
  const runDir = join(rootDir, dirName)
  const stateDir = join(runDir, 'state')
  const [manifest, tree, roundText, planner, claimDirents] = await Promise.all([
    readJson(join(runDir, 'manifest.json')),
    readJson(join(stateDir, 'tree.json')),
    readFile(join(stateDir, 'round-log.jsonl'), 'utf8').catch(() => ''), // no rounds started yet
    readJson(join(stateDir, 'planner.json')),
    readdir(join(stateDir, 'claims'), { withFileTypes: true }).catch(() => null),
  ])
  if (manifest === undefined) return null // not a run directory
  const runId = str(manifest.run_id) ?? dirName

  const rawNodes = Array.isArray(tree?.nodes) ? (tree?.nodes as Record<string, unknown>[]) : []
  const { roundsUsed, openRound } = foldRoundLog(roundText.split('\n'))

  // Session-binding sidecars (engine additive; both may be missing on legacy runs).
  const claimFiles = claimDirents === null ? [] : claimDirents.filter(d => d.isFile() && d.name.endsWith('.json'))
  const claimReads = await Promise.all(claimFiles.map(d => readJson(join(stateDir, 'claims', d.name))))
  const claimSession = new Map<string, string>()
  for (const claim of claimReads) {
    const nodeId = str(claim?.node_id)
    const sessionId = str(claim?.dsh_session_id)
    if (nodeId !== null && sessionId !== null) claimSession.set(nodeId, sessionId)
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
  // The map caches the in-flight PROMISE (not the value) so concurrent
  // sibling resolutions share one walk too.
  const mockupsByArchive = new Map<string, Promise<GoalTreeDocLink[]>>()
  const mockupsFor = (archiveRoot: string): Promise<GoalTreeDocLink[]> => {
    let pending = mockupsByArchive.get(archiveRoot)
    if (pending === undefined) {
      pending = listMockupLinks(archiveRoot)
      mockupsByArchive.set(archiveRoot, pending)
    }
    return pending
  }
  // node-doc-links resolutions run concurrently across ALL nodes (plugin-perf
  // L1); each job fills its node view's docs slot before the barrier below
  // returns — the node view must be created first so the job has a stable
  // slot to write into.
  const docJobs: Promise<void>[] = []
  for (const node of rawNodes) {
    const id = typeof node.id === 'string' ? node.id : null
    if (id === null) continue
    const status = typeof node.status === 'string' ? node.status : 'pending'
    const type = str(node.type)
    // The five-state census counts WORK nodes only: the type=goal root is the
    // original requirement's conclude anchor and type=sub/accept containers are
    // the WBS layer (goal-tree-wake-model §3.1) — pending forever by design and
    // never delivery units, so they stay out of every status count.
    if (type !== 'goal' && type !== 'sub' && type !== 'accept') {
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
    const wakeCountRaw = node.wake_count
    const wakeMaxRaw = node.wake_max
    const task = str(node.task)
    const nodeView: GoalTreeNodeView = {
      id,
      parent: parentOf.get(id) ?? null,
      title: typeof node.title === 'string' ? node.title : id,
      task,
      docs: null,
      type,
      status,
      claimedBy: str(node.claimed_by),
      verdict: str(node.last_verdict),
      confidence: typeof confidenceRaw === 'number' && Number.isFinite(confidenceRaw) ? confidenceRaw : null,
      claimSessionId: claimSession.get(id) ?? null,
      blockedBy: dependsOn,
      wakeCount: typeof wakeCountRaw === 'number' && Number.isFinite(wakeCountRaw) ? wakeCountRaw : 0,
      wakeMax: typeof wakeMaxRaw === 'number' && Number.isFinite(wakeMaxRaw) ? wakeMaxRaw : null,
      duty: str(node.duty),
      depth: depthOf(id, parentOf),
    }
    nodes.push(nodeView)
    // node-doc-links: decompose a bridge-shaped task into structured slots
    // (goal sentence + doc pointers). Archive root resolution prefers the
    // template's own 归档 segment, falling back to the frozen deliver-<archive>
    // run-id convention; every non-bridge task parses to null (no rows, no
    // stats — the plain rendering is the zero-degradation path).
    const parsed = parseNodeTask(task)
    if (parsed !== null) {
      const archiveName = parsed.archiveName ?? runId.replace(/^deliver-/, '')
      const archiveRoot = join(repoRoot, '.rdd', 'changes', 'archive', archiveName)
      const requirement = parsed.reqRel !== null ? toDocLink(archiveRoot, parsed.reqRel) : Promise.resolve(null)
      const designs = Promise.all(parsed.designRels.map(rel => toDocLink(archiveRoot, rel)))
      const mockups = mockupsFor(archiveRoot)
      docJobs.push((async () => {
        const [requirementLink, designLinks, mockupLinks] = await Promise.all([requirement, designs, mockups])
        nodeView.docs = {
          goal: parsed.goal,
          stage: parsed.stage,
          duty: parsed.duty,
          requirement: requirementLink,
          designs: designLinks,
          mockups: mockupLinks,
        }
      })())
    }
  }
  if (docJobs.length > 0) await Promise.all(docJobs)

  let updatedAt = str(tree?.updated_at)
  if (updatedAt === null) {
    try {
      updatedAt = new Date((await stat(join(stateDir, 'tree.json'))).mtimeMs).toISOString()
    } catch {
      updatedAt = null
    }
  }

  const budget = (manifest.budget ?? {}) as Record<string, unknown>
  const concluded = (manifest.concluded ?? null) as Record<string, unknown> | null
  return {
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
    nodes: orderOutlineNodes(nodes),
    plannerSessionId: str(planner?.dsh_session_id),
  }
}

/**
 * Aggregate every run directory under the goal-trees root. Runs aggregate
 * concurrently (plugin-perf L1) behind the per-run mtime-fingerprint cache
 * (plugin-perf L2); both layers are invisible to the output — same views,
 * same order, same tolerance.
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

  const names = dirents
    .filter(dirent => dirent.isDirectory() && !dirent.name.startsWith('_') && !dirent.name.startsWith('.'))
    .map(dirent => dirent.name)

  const byName = runCache.get(rootDir) ?? new Map<string, RunCacheEntry>()
  const views = await Promise.all(names.map(async name => {
    const cached = byName.get(name)
    // Debounce floor: inside the window the cached view is served as-is, no
    // stats at all (checkedAt deliberately NOT bumped here so a poll cadence
    // faster than the floor cannot starve the re-stat).
    if (cached !== undefined && Date.now() - cached.checkedAt < runCacheTtlMs) return cached.view
    const fingerprint = await fingerprintRun(join(rootDir, name))
    if (cached !== undefined && cached.fingerprint === fingerprint) {
      cached.checkedAt = Date.now()
      return cached.view
    }
    const view = await aggregateOneRun(rootDir, name, repoRoot)
    byName.set(name, { fingerprint, checkedAt: Date.now(), view })
    return view
  }))
  // Purge entries of runs that vanished (archived/moved out) and keep the map.
  const present = new Set(names)
  for (const name of byName.keys()) {
    if (!present.has(name)) byName.delete(name)
  }
  runCache.set(rootDir, byName)

  const runs = views.filter((view): view is GoalTreeRunView => view !== null)
  runs.sort((a, b) => {
    const rank = (run: GoalTreeRunView): number => (run.state === 'running' ? 0 : 1)
    if (rank(a) !== rank(b)) return rank(a) - rank(b)
    return (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '')
  })
  return { runs }
}

/**
 * Read one node's claim-sidecar session binding DIRECTLY (the liveness
 * shortcut, plugin-perf L2): `<rootDir>/<runId>/state/claims/<nodeId>.json`
 * → its dsh_session_id, with zero aggregation. Mirrors the aggregate join's
 * discipline: the sidecar's own node_id must agree with the queried node
 * (the join keys by content), and every missing/corrupt/malformed shape
 * returns null (the caller reports "unknown", never an error).
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 */
export async function readClaimSession(rootDir: string, runId: string, nodeId: string): Promise<string | null> {
  const claim = await readJson(join(rootDir, runId, 'state', 'claims', `${nodeId}.json`))
  if (claim === undefined) return null
  if (str(claim.node_id) !== nodeId) return null
  return str(claim.dsh_session_id)
}

// --- wire projection (plugin-perf L3) ------------------------------------------
//
// The /runs endpoint's default payload: run summaries plus slim nodes. The
// strip renders ONE run per session; the full every-run-every-field payload
// (task texts, doc links with absolute paths, mockup chips) was ~111KB per
// poll. The default now carries full detail ONLY for runs with a LIVE
// dsh-bound claim (the run some worker session renders NOW — its view needs
// the task text and doc chips; the live-claim rule itself lives in
// ./index.ts where the agents registry is); every other run — including
// concluded runs whose claim sidecars outlived their sessions — ships a
// summary: all run-level scalars (state/census/budget — the bar header)
// plus per-node census fields (the view-gating join needs claimSessionId,
// the tree list needs id/title/status/owner/depth). The heavy per-node
// fields (task text, docs, verdict, confidence) are omitted; the additive
// `detail` marker flags the shape and the `?run=<id>` detail parameter
// returns that one run in full. Old clients stay functional on the default
// payload (every field they read is present — slim nodes merely degrade the
// tree list's tooltip to the title); new clients backfill `?run=` for a
// slim run they expand.

/** The wire node shape: every heavy field optional (absent on slim runs). */
export type GoalTreeWireNode = Omit<GoalTreeNodeView, 'task' | 'docs' | 'verdict' | 'confidence'> &
  Partial<Pick<GoalTreeNodeView, 'task' | 'docs' | 'verdict' | 'confidence'>>

/** The wire run shape: same run-level scalars, nodes possibly slim, detail marker. */
export interface GoalTreeWireRun extends Omit<GoalTreeRunView, 'nodes'> {
  nodes: GoalTreeWireNode[]
  /** false = this run's nodes are slim (fetch `?run=<id>` for full detail). */
  detail: boolean
}

/**
 * Project one aggregated run into its wire shape (plugin-perf L3). Default
 * detail rule (the pure fallback): a run with ANY dsh-bound claim ships
 * full. The /runs route OVERRIDES this with the live-claim rule
 * (hasLiveClaimSession in ./index.ts): only a claim whose session still
 * resolves in the agents registry forces full detail — historical claims of
 * dead sessions ship slim (no session renders them as its worker view), which
 * is what actually shrinks the default payload on repos with many concluded
 * runs. The explicit `detail` argument wins either way (the `?run=` detail
 * route always asks full). Pure: the aggregated input is never mutated
 * (fresh objects out).
 */
export function projectRunView(run: GoalTreeRunView, detail?: boolean): GoalTreeWireRun {
  const wantDetail = detail ?? run.nodes.some(node => node.claimSessionId !== null)
  if (wantDetail) return { ...run, nodes: [...run.nodes], detail: true }
  return {
    ...run,
    nodes: run.nodes.map(node => ({
      id: node.id,
      parent: node.parent,
      title: node.title,
      type: node.type,
      status: node.status,
      claimedBy: node.claimedBy,
      claimSessionId: node.claimSessionId,
      blockedBy: node.blockedBy,
      wakeCount: node.wakeCount,
      wakeMax: node.wakeMax,
      duty: node.duty,
      depth: node.depth,
    })),
    detail: false,
  }
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
  // type-carrying entries are planner-side audit rows (type=redo,
  // inplace-redo-session-reuse), not worker reports — the watcher must not
  // deliver them as callbacks (the engine's Get-LedgerStats applies the same
  // guard). Legacy entries carry no type and pass unchanged.
  if (str(entry.type) !== null) return null
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
 * the watcher's input for Planner callbacks. Run ledgers are read
 * concurrently (plugin-perf L1; the run list itself comes back from the
 * aggregation cache); per-line projection lives in {@link parseLedgerEntry};
 * corrupt lines are skipped (the engine quarantines them); a missing ledger
 * yields no entries.
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 */
export async function collectReportEntries(rootDir: string): Promise<GoalTreeReportEntry[]> {
  const { runs } = await aggregateGoalTrees(rootDir)
  const ledgers = await Promise.all(runs.map(run => readLedgerText(rootDir, run.runId)))
  const entries: GoalTreeReportEntry[] = []
  runs.forEach((run, index) => {
    const ledger = ledgers[index] ?? null
    if (ledger === null) return
    for (const line of ledger.split('\n')) {
      const entry = parseLedgerEntry(line, run.runId)
      if (entry !== null) entries.push(entry)
    }
  })
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
 * Resolve one run's archive root from the bridge's own record
 * (`<runDir>/bridge.json` → `archive_rel`, written at promulgate). The unified
 * decision ledger lives at the ARCHIVE root, NOT the run dir
 * (planner-midrun-derive: 账本是长期分析资产、归档是长期载体) — the watcher
 * must read the very source the engine writes, or auto-mode escalation
 * delivery breaks silently. Null when the run carries no bridge.json
 * (plain goal-tree runs — the caller then falls back to the pre-migration
 * run-dir location).
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 */
async function readBridgeArchiveDir(rootDir: string, runId: string): Promise<string | null> {
  const bridge = await readJson(join(rootDir, runId, 'bridge.json'))
  const archiveRel = bridge === undefined ? null : str(bridge.archive_rel)
  if (archiveRel === null) return null
  if (isAbsolute(archiveRel)) return archiveRel
  return join(dirname(dirname(rootDir)), ...archiveRel.split(/[\\/]+/).filter(segment => segment !== ''))
}

/**
 * Read one run's decision-ledger text plus the file it came from; text null
 * when absent (a run without pure auto mode — the default — writes no
 * ledger). Archive-level first (the single standard), legacy run-dir second
 * (pre-migration AutoMode runs wrote the ledger beside the run state); the
 * first readable candidate wins, and a missing ledger yields no entries
 * instead of an error. The resolved source path feeds the cross-run
 * once-per-ledger dedup in {@link collectDecisionEntries}.
 */
async function readDecisionsText(rootDir: string, runId: string): Promise<{ text: string | null; source: string | null }> {
  const runDir = join(rootDir, runId)
  const archiveDir = await readBridgeArchiveDir(rootDir, runId)
  const candidates = [
    ...(archiveDir === null ? [] : [join(archiveDir, 'decisions.jsonl')]),
    join(runDir, 'decisions.jsonl'),
  ]
  for (const file of candidates) {
    try {
      return { text: await readFile(file, 'utf8'), source: file }
    } catch {
      // try the next candidate; all-missing reads as null
    }
  }
  return { text: null, source: null }
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
 * adjudicate). Decision ledgers are read concurrently (plugin-perf L1) — each
 * run's ledger resolved at its archive root via bridge.json, run-dir legacy
 * fallback (readDecisionsText) — and read fresh every call: it is NOT part of
 * the aggregation fingerprint, so a just-appended resolution takes effect
 * immediately. Corrupt lines are skipped; a missing ledger yields no entries.
 *
 * Once per ledger file (duplicate-callback fix): the ledger lives at the
 * ARCHIVE root precisely because several runs (replan / midrun derive) can
 * share one archive — two runs resolving the same `decisions.jsonl` each
 * collected the same open escalation under different dedupe keys
 * (`repo::runA::decision D3` / `repo::runB::decision D3`) and the planner got
 * one notice per RUN. Entries are now keyed by their source file: the first
 * run that surfaces a ledger's entry carries it; later runs sharing that
 * file stay silent. Run-dir fallback files are per-run by construction, so
 * legacy runs are unaffected.
 * @param rootDir - absolute path of `<repoRoot>/.rdd/goal-trees`.
 */
export async function collectDecisionEntries(rootDir: string): Promise<GoalTreeDecisionEntry[]> {
  const { runs } = await aggregateGoalTrees(rootDir)
  const texts = await Promise.all(runs.map(run => readDecisionsText(rootDir, run.runId)))
  const open: GoalTreeDecisionEntry[] = []
  const seenLedgerEntry = new Set<string>()
  runs.forEach((run, index) => {
    const { text, source } = texts[index] ?? { text: null, source: null }
    if (text === null || source === null) return
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
      const onceKey = `${source}::${entryId}`
      if (seenLedgerEntry.has(onceKey)) continue // a sibling run already carries this archive's entry
      seenLedgerEntry.add(onceKey)
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
  })
  return open
}

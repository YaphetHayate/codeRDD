/**
 * rdd-goal-tree, browser half: the GoalTreeBar entry in the
 * `conversation.input.dock` strip (order 30, after todo/goal/queue). The bar is
 * a READ-ONLY surface over the host half's `/rdd-goal-tree/runs` endpoint: it
 * polls the session repository's goal-tree runs (15s + on visibility) and
 * renders the most relevant one — glyph, run id, state badge, round x/y, node
 * budget, status counts, and an expandable node list. No goal-tree write
 * primitive exists here; management stays on the Planner session's CLI.
 *
 * Session-scoped views (both joined from the engine's additive sidecars via
 * the host payload): a session whose id matches a node's claim sidecar gets
 * the WORKER view — its own node, its task, and the report next-step — with
 * the full tree collapsed behind a chevron; a session whose id matches a
 * run's planner sidecar (any run, not just the lead one) gets the full tree
 * plus a settle/prune action hint whenever nodes are reported. Everyone else
 * renders nothing — except when the lead run carries no planner sidecar
 * (legacy run / started outside dsh), where the plain full-tree strip stays
 * as the degradation. The order-sensitive gating lives in view-picker.ts
 * (pickGoalTreeView), asserted row by row in the smoke suite.
 *
 * Loading, absent, and empty states render nothing at all (the GoalBar
 * posture). All framework imports are type-only except React (baseline module
 * table) — the bundle's runtime requires are exactly `react`, `react/jsx-runtime`,
 * and `@deepseek-ai/dsh-client-ui-primitives`.
 */
import { useEffect, useState } from 'react'
import type { ClientContext } from '@deepseek-ai/dsh-client-runtime/client'
import { IconChevronDownOutline14, IconChevronUpOutline14, IconGoalOutline16 } from '@deepseek-ai/dsh-client-ui-primitives'
import type { PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
// Type-only: pulls the ui-conversation SlotMap merge (the conversation.input.dock seat),
// the client-runtime standard-kit merge (useSessions over SessionListState), and the
// locale plugin's Context merge (ctx.locale).
import type {} from '@deepseek-ai/dsh-client-ui-conversation/client'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import { pickGoalTreeView } from './view-picker.js'

// ── locale ────────────────────────────────────────────────────────────────────

const zh = {
  'title': '目标树',
  'state.running': '运行中',
  'state.other': '已结案',
  'round': '轮次',
  'nodes': '节点',
  'expand': '展开节点',
  'collapse': '收起节点',
  'count.pending': '待认领',
  'count.claimed': '进行中',
  'count.reported': '待裁定',
  'count.done': '完成',
  'count.pruned': '已剪枝',
  'blocked': '被依赖阻塞',
  'mine': '我的节点',
  'mine.claimed': '执行中',
  'mine.reported': '已回报·待裁定',
  'mine.done': '已裁定完成',
  'mine.pruned': '已被剪枝',
  'task': '任务',
  'task.reportNext': '完成后回报：goal-tree-leaf.cmd -Command report -RunId {run} -Worker {worker} -CallbackFile <callback.json>',
  'task.reportedHint': '已回报，等待规划者裁定（settle / prune / graft）',
  'planner.hint': '个节点已回报，等待你的裁定 → settle / prune',
  'fulltree': '查看整棵树',
  'fulltree.hide': '收起整棵树',
} as const

const en = {
  'title': 'Goal tree',
  'state.running': 'running',
  'state.other': 'concluded',
  'round': 'round',
  'nodes': 'nodes',
  'expand': 'expand nodes',
  'collapse': 'collapse nodes',
  'count.pending': 'pending',
  'count.claimed': 'in flight',
  'count.reported': 'reported',
  'count.done': 'done',
  'count.pruned': 'pruned',
  'blocked': 'blocked by deps',
  'mine': 'my node',
  'mine.claimed': 'in flight',
  'mine.reported': 'reported · awaiting verdict',
  'mine.done': 'settled done',
  'mine.pruned': 'pruned',
  'task': 'task',
  'task.reportNext': 'when done, report: goal-tree-leaf.cmd -Command report -RunId {run} -Worker {worker} -CallbackFile <callback.json>',
  'task.reportedHint': 'reported — awaiting Planner verdict (settle / prune / graft)',
  'planner.hint': 'node(s) reported, awaiting your verdict → settle / prune',
  'fulltree': 'show full tree',
  'fulltree.hide': 'hide full tree',
} as const

export type GoalTreeKey = keyof typeof zh

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** The goal-tree strip's copy. */
    rddGoalTree: GoalTreeKey
  }
}

/** Dictionary namespace owned by this plugin. */
const NS = 'rddGoalTree'

// ── wire view (mirrors the host half's aggregateGoalTrees output) ────────────

interface GoalTreeNodeView {
  id: string
  parent: string | null
  title: string
  task: string | null
  /** Engine node type: 'goal' = original-requirement root (rendered with the ◎ glyph). */
  type: string | null
  status: string
  claimedBy: string | null
  verdict: string | null
  confidence: number | null
  claimSessionId: string | null
  blockedBy: string[]
  depth: number
}

interface GoalTreeRunView {
  runId: string
  state: string
  goal: string
  outcome: string | null
  createdAt: string | null
  updatedAt: string | null
  maxRounds: number
  maxNodes: number
  roundsUsed: number
  openRound: number | null
  counts: { pending: number; claimed: number; reported: number; done: number; pruned: number }
  nodes: GoalTreeNodeView[]
  plannerSessionId: string | null
}

// ── polling hook ──────────────────────────────────────────────────────────────

const POLL_MS = 15_000

/** Poll the host endpoint for the repository's runs; undefined = not loaded / no cwd. */
function useGoalTreeRuns(cwd: string | undefined): GoalTreeRunView[] | undefined {
  const [runs, setRuns] = useState<GoalTreeRunView[] | undefined>(undefined)

  useEffect(() => {
    if (cwd === undefined || cwd === '') {
      setRuns(undefined)
      return
    }
    let alive = true
    const load = async (): Promise<void> => {
      try {
        const res = await fetch(`/rdd-goal-tree/runs?cwd=${encodeURIComponent(cwd)}`)
        if (!res.ok) return
        const json = (await res.json()) as { runs?: GoalTreeRunView[] }
        if (alive && Array.isArray(json.runs)) setRuns(json.runs)
      } catch {
        // transient transport failure: keep the previous snapshot
      }
    }
    void load()
    const timer = setInterval(() => { void load() }, POLL_MS)
    const onVisible = (): void => { if (!document.hidden) void load() }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive = false
      clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [cwd])

  return runs
}

// ── strip ─────────────────────────────────────────────────────────────────────

/** Status glyphs and colors per node lifecycle state. */
const STATUS_GLYPH: Record<string, { glyph: string; className: string }> = {
  pending: { glyph: '○', className: 'rdgt-st-pending' },
  claimed: { glyph: '◐', className: 'rdgt-st-claimed' },
  reported: { glyph: '◆', className: 'rdgt-st-reported' },
  done: { glyph: '✔', className: 'rdgt-st-done' },
  pruned: { glyph: '✕', className: 'rdgt-st-pruned' },
}

const CSS = `
.rdgt-dock{box-sizing:border-box;width:calc(100% - 2*var(--dsh-composer-side-clearance,0px));margin:0 auto}
.rdgt-card{box-sizing:border-box;width:100%;max-width:var(--dsh-composer-card-max-width,760px);border:1px solid var(--dsw-alias-border-l1,rgba(127,127,127,.35));background:var(--dsw-specific-tip,rgba(127,127,127,.08));border-radius:12px;margin:0 auto;padding:4px 6px 4px 12px;display:flex;flex-direction:column}
.rdgt-head{display:flex;align-items:center;gap:10px;min-height:30px;width:100%;background:none;border:none;cursor:pointer;padding:0;color:inherit;text-align:left;font:inherit}
.rdgt-glyph{color:var(--dsw-alias-label-tertiary,#888);flex:none;display:inline-flex}
.rdgt-title{color:var(--dsw-alias-label-primary,#eee);flex:none;font-size:13px;font-weight:500;line-height:22px}
.rdgt-run{color:var(--dsw-alias-label-secondary,#aaa);flex:none;font-size:12px;line-height:20px;font-family:ui-monospace,Consolas,monospace}
.rdgt-badge{flex:none;font-size:11px;line-height:18px;padding:0 8px;border-radius:999px;border:1px solid var(--dsw-alias-border-l2,rgba(127,127,127,.4));color:var(--dsw-alias-label-secondary,#aaa)}
.rdgt-badge[data-running='1']{color:var(--dsw-alias-state-business-primary,#4c8dff);border-color:currentColor}
.rdgt-badge[data-mine='1']{color:var(--dsw-alias-state-business-primary,#4c8dff);border-color:currentColor}
.rdgt-badge[data-mine='2']{color:var(--dsw-alias-state-warning-primary,#e0a23a);border-color:currentColor}
.rdgt-badge[data-mine='3']{color:var(--dsw-alias-state-success-primary,#3fb96f);border-color:currentColor}
.rdgt-meta{color:var(--dsw-alias-label-secondary,#aaa);flex:none;font-size:12px;line-height:20px;white-space:nowrap}
.rdgt-counts{color:var(--dsw-alias-label-tertiary,#888);flex:none;font-size:12px;line-height:20px;white-space:nowrap}
.rdgt-goal{min-width:0;color:var(--dsw-alias-label-primary-dimmed,#999);text-overflow:ellipsis;white-space:nowrap;overflow:hidden;flex:1;font-size:13px;line-height:20px}
.rdgt-chevron{color:var(--dsw-alias-label-tertiary,#888);flex:none;display:inline-flex}
.rdgt-body{margin:1px 0 2px;padding:0 2px;display:flex;flex-direction:column;gap:1px}
.rdgt-task{color:var(--dsw-alias-label-primary,#ddd);font-size:12px;line-height:19px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.rdgt-hint{color:var(--dsw-alias-label-tertiary,#888);font-size:11px;line-height:18px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.rdgt-hint[data-kind='reported']{color:var(--dsw-alias-state-warning-primary,#e0a23a)}
.rdgt-hint[data-kind='planner']{color:var(--dsw-alias-state-warning-primary,#e0a23a)}
.rdgt-more{margin:0 0 4px 4px;background:none;border:none;cursor:pointer;padding:0;color:var(--dsw-alias-label-tertiary,#777);font-size:11px;line-height:18px;text-align:left;font:inherit}
.rdgt-more:hover{color:var(--dsw-alias-label-secondary,#aaa)}
.rdgt-list{margin:2px 0 6px 4px;padding:0;list-style:none;display:flex;flex-direction:column;gap:2px;max-height:240px;overflow:auto}
.rdgt-item{display:flex;align-items:center;gap:8px;font-size:12px;line-height:20px;color:var(--dsw-alias-label-primary-dimmed,#bbb)}
.rdgt-itemTitle{min-width:0;text-overflow:ellipsis;white-space:nowrap;overflow:hidden}
.rdgt-itemWorker{color:var(--dsw-alias-label-tertiary,#777);flex:none;font-family:ui-monospace,Consolas,monospace;font-size:11px}
.rdgt-blocked{color:var(--dsw-alias-state-warning-primary,#e0a23a);flex:none;font-size:11px}
.rdgt-st-pending{color:var(--dsw-alias-label-tertiary,#888)}
.rdgt-st-goal{color:var(--dsw-alias-state-business-primary,#4c8dff);font-weight:600}
.rdgt-st-claimed{color:var(--dsw-alias-state-business-primary,#4c8dff)}
.rdgt-st-reported{color:var(--dsw-alias-state-warning-primary,#e0a23a)}
.rdgt-st-done{color:var(--dsw-alias-state-success-primary,#3fb96f)}
.rdgt-st-pruned{color:var(--dsw-alias-label-tertiary,#666);text-decoration:line-through}
`

let cssInjected = false

/** One-time style injection (the manual twin of a CSS module's bundle hook). */
function ensureCss(): void {
  if (cssInjected || typeof document === 'undefined') return
  cssInjected = true
  const tagId = '@coderrdd/dsh-rdd-goal-tree/css'
  if (document.querySelector(`style[data-plugin-css=${JSON.stringify(tagId)}]`) === null) {
    const tag = document.createElement('style')
    tag.dataset.plugin = '@coderrdd/dsh-rdd-goal-tree'
    tag.dataset.pluginCss = tagId
    tag.textContent = CSS
    document.head.appendChild(tag)
  }
}

function Count({ label, glyph, value }: { label: string; glyph: string; value: number }): null | JSX.Element {
  if (value <= 0) return null
  return <span title={label}>{glyph}{value}</span>
}

/** The expandable whole-tree list, shared by the full bar and the worker bar. */
function NodeList({ run, t }: { run: GoalTreeRunView; t: (key: GoalTreeKey) => string }) {
  return (
    <ul className="rdgt-list">
      {run.nodes.map(node => {
        const status = STATUS_GLYPH[node.status] ?? STATUS_GLYPH.pending!
        // type=goal root: the original requirement's final objective — its own glyph
        // (◎) and posture; plain nodes (type null) render exactly as before.
        const isGoal = node.type === 'goal'
        return (
          <li
            key={node.id}
            className={`rdgt-item ${isGoal ? 'rdgt-st-goal' : status.className}`}
            style={{ paddingLeft: `${4 + node.depth * 16}px` }}
            data-status={node.status}
            data-node-type={node.type ?? undefined}
          >
            <span aria-hidden>{isGoal ? '◎' : status.glyph}</span>
            <span className="rdgt-itemTitle" title={node.task ?? node.title}>{node.id} · {node.title}</span>
            {node.claimedBy !== null && <span className="rdgt-itemWorker">@{node.claimedBy}</span>}
            {node.blockedBy.length > 0 && <span className="rdgt-blocked">{t('blocked')} ← {node.blockedBy.join('+')}</span>}
          </li>
        )
      })}
    </ul>
  )
}

/**
 * The worker (leaf-session) view: this session's claimed node front and center
 * — id, status badge, the task text, the report next-step — with the full tree
 * behind a "show full tree" toggle.
 */
export function WorkerNodeBar({ run, node, t }: { run: GoalTreeRunView; node: GoalTreeNodeView; t: (key: GoalTreeKey) => string }) {
  ensureCss()
  const [showTree, setShowTree] = useState(false)
  const badge = node.status === 'claimed'
    ? { text: t('mine.claimed'), data: '1' }
    : node.status === 'reported'
      ? { text: t('mine.reported'), data: '2' }
      : node.status === 'done'
        ? { text: t('mine.done'), data: '3' }
        : node.status === 'pruned'
          ? { text: t('mine.pruned'), data: '0' }
          : { text: t('mine.claimed'), data: '1' }
  const reportNext = t('task.reportNext').replace('{run}', run.runId).replace('{worker}', node.claimedBy ?? '?')

  return (
    <div className="rdgt-dock" data-rdd-goal-tree="" data-view="worker">
      <div className="rdgt-card">
        <div className="rdgt-head" title={node.task ?? node.title}>
          <span className="rdgt-glyph" aria-hidden><IconGoalOutline16 size={14} /></span>
          <span className="rdgt-title">{t('mine')}</span>
          <span className="rdgt-run">{node.id} · {node.title}</span>
          <span className="rdgt-badge" data-mine={badge.data}>{badge.text}</span>
          {node.claimedBy !== null && <span className="rdgt-meta">@{node.claimedBy}</span>}
          <span className="rdgt-meta">{t('round')} {run.roundsUsed}/{run.maxRounds}</span>
          <span className="rdgt-meta">{run.runId}</span>
          <span className="rdgt-goal">{run.goal}</span>
        </div>
        <div className="rdgt-body">
          <div className="rdgt-task" title={node.task ?? ''}>{t('task')}: {node.task ?? node.title}</div>
          {node.status === 'reported' || node.status === 'done' ? (
            <div className="rdgt-hint" data-kind="reported">{t('task.reportedHint')}</div>
          ) : (
            <div className="rdgt-hint" title={reportNext}>{reportNext}</div>
          )}
        </div>
        <button type="button" className="rdgt-more" onClick={() => { setShowTree(v => !v) }}>
          {showTree ? t('fulltree.hide') : t('fulltree')}
        </button>
        {showTree && <NodeList run={run} t={t} />}
      </div>
    </div>
  )
}

/**
 * The run bar: full-tree posture (Planner and plain sessions). A Planner
 * session additionally gets an inline settle/prune hint while any node is
 * reported but unsettled.
 */
export function GoalTreeBar({ run, t, isPlanner = false }: { run: GoalTreeRunView; t: (key: GoalTreeKey) => string; isPlanner?: boolean }) {
  ensureCss()
  const [expanded, setExpanded] = useState(false)
  const running = run.state === 'running'
  const nodesUsed = run.counts.pending + run.counts.claimed + run.counts.reported + run.counts.done
  const hanging = running && run.openRound !== null
  const verdictDue = isPlanner && run.counts.reported > 0

  return (
    <div className="rdgt-dock" data-rdd-goal-tree="" data-view={isPlanner ? 'planner' : 'plain'}>
      <div className="rdgt-card">
        <button
          type="button"
          className="rdgt-head"
          aria-expanded={expanded}
          aria-label={expanded ? t('collapse') : t('expand')}
          title={run.goal}
          onClick={() => { setExpanded(v => !v) }}
        >
          <span className="rdgt-glyph" aria-hidden><IconGoalOutline16 size={14} /></span>
          <span className="rdgt-title">{t('title')}</span>
          <span className="rdgt-run">{run.runId}</span>
          <span className="rdgt-badge" data-running={running ? '1' : '0'}>
            {running ? t('state.running') : (run.outcome ?? t('state.other'))}
          </span>
          <span className="rdgt-meta">{t('round')} {run.roundsUsed}/{run.maxRounds}{hanging ? '⏳' : ''}</span>
          <span className="rdgt-meta">{t('nodes')} {nodesUsed}/{run.maxNodes}</span>
          <span className="rdgt-counts">
            <Count label={t('count.claimed')} glyph="◐" value={run.counts.claimed} />
            <Count label={t('count.pending')} glyph="○" value={run.counts.pending} />
            <Count label={t('count.reported')} glyph="◆" value={run.counts.reported} />
            <Count label={t('count.done')} glyph="✔" value={run.counts.done} />
          </span>
          <span className="rdgt-goal">{run.goal}</span>
          <span className="rdgt-chevron" aria-hidden>
            {expanded ? <IconChevronDownOutline14 /> : <IconChevronUpOutline14 />}
          </span>
        </button>
        {verdictDue && (
          <div className="rdgt-body">
            <div className="rdgt-hint" data-kind="planner">◆ {run.counts.reported} {t('planner.hint')}</div>
          </div>
        )}
        {expanded && <NodeList run={run} t={t} />}
      </div>
    </div>
  )
}

/** Full props of the dock entry: session standard kit + global seat + the locale seat. */
export type GoalTreeDockProps = PropsRuntime<'conversation.input.dock'> & PropsLocale<'rddGoalTree'>

/**
 * Dock adapter: reads the current session's cwd and id, polls the repository's
 * runs, and picks the view through the gating table in view-picker.ts —
 * worker (this session claims a node) > planner (this session created a run)
 * > plain degradation (lead run without a planner sidecar) > nothing.
 */
export function GoalTreeDock({ useSessions, t }: GoalTreeDockProps) {
  const cwd = useSessions(list =>
    list.current === undefined ? undefined : list.byId[list.current]?.cwd)
  const sessionId = useSessions(list => list.current)
  const runs = useGoalTreeRuns(cwd)
  if (runs === undefined || runs.length === 0) return null

  const picked = pickGoalTreeView(runs, sessionId)
  if (picked === null) return null
  if (picked.view === 'worker') return <WorkerNodeBar run={picked.run} node={picked.node} t={t} />
  return <GoalTreeBar run={picked.run} t={t} isPlanner={picked.view === 'planner'} />
}

// ── plugin body ───────────────────────────────────────────────────────────────

/** Required services: the slot registry and the locale registry. */
export const inject = ['slots', 'locale']

/**
 * Client plugin body: register the dictionaries and the dock entry.
 * @param ctx - client root context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'rdd-goal-tree: dictionaries')

  ctx.slots.inject('conversation.input.dock', () => ctx.slots.register({
    name: 'conversation.input.dock',
    id: 'rdd-goal-tree',
    order: 30,
    locale: NS,
  }, GoalTreeDock))
}

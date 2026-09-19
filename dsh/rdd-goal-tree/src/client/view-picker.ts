/**
 * The session-scoped view gating table (tree-display-scoping), extracted as a
 * dependency-free pure function so the smoke suite can assert every row
 * directly (this module must never import react or node builtins — the client
 * bundle wraps it alongside the dock entry, and the host-side compile emits it
 * under lib/client/ for node-side imports).
 *
 * Order-sensitive judgment table:
 *   ① worker  — any run where this session's id matches a node's claim
 *               sidecar (the most specific identity wins, current behavior);
 *   ② planner — the FIRST run in the current sort order whose planner
 *               sidecar matches this session — a full-table scan, not
 *               runs[0]-only, so the creator of a non-first run still gets
 *               their own tree instead of someone else's;
 *   ③ plain   — runs[0] carries no planner sidecar (legacy run / started
 *               outside dsh): keep the plain full-tree strip as the
 *               degradation. Only runs[0]; never fall back to a later run;
 *   ④ null    — everyone else (bound to neither half of any sidecar-carrying
 *               run) renders nothing — the convergence item.
 * @module rdd-goal-tree/client/view-picker
 */

/** Minimal structural shape the picker needs from a wire node. */
export interface PickableNodeView {
  claimSessionId: string | null
}

/** Minimal structural shape the picker needs from a wire run. */
export interface PickableRunView {
  nodes: readonly PickableNodeView[]
  plannerSessionId: string | null
}

/** The picked view: which posture renders and with which run (and node). */
export type GoalTreeViewSelection<R extends PickableRunView> =
  | { view: 'worker'; run: R; node: R['nodes'][number] }
  | { view: 'planner'; run: R }
  | { view: 'plain'; run: R }
  | null

/**
 * Pick the dock strip's view for one session from the repository's runs.
 * @param runs - the wire run list in the host's sort order (running first,
 * then most recently updated).
 * @param sessionId - the current session's id (nullish when unknown — matches
 * nothing, exactly like a non-matching string).
 * @returns the judgment table's row for this session; null renders nothing.
 */
export function pickGoalTreeView<R extends PickableRunView>(
  runs: readonly R[],
  sessionId: string | null | undefined,
): GoalTreeViewSelection<R> {
  for (const run of runs) {
    const mine = run.nodes.find(node => node.claimSessionId !== null && node.claimSessionId === sessionId)
    if (mine !== undefined) return { view: 'worker', run, node: mine }
  }
  const planned = runs.find(run => run.plannerSessionId !== null && run.plannerSessionId === sessionId)
  if (planned !== undefined) return { view: 'planner', run: planned }
  if (runs.length > 0 && runs[0].plannerSessionId === null) {
    return { view: 'plain', run: runs[0] }
  }
  return null
}

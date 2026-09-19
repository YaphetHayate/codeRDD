#!/usr/bin/env node
/**
 * Smoke checks for the built bundle — run AFTER `node scripts/build-dsh-goal-tree.mjs`:
 *   1. aggregateGoalTrees against the real demo run (.rdd/goal-trees/dsh-demo)
 *      and the degenerate cases (missing root, manifest-only run)
 *   2. session-binding sidecar joins: claims/<node>.json + planner.json
 *      (focused worker view / Planner callback target), plus collectReportEntries
 *   2b. goal-root aggregation: type passthrough on nodes and counts excluding
 *      the type=goal root (goal-tree-goal-root)
 *   3. engine regression (real CLI, temp fixture): claim writes the claims
 *      sidecar (with DSH_SESSION_ID when the env is set, null when not) and
 *      start writes planner.json
 *   4. lib/client.js is a well-formed module-loader registration whose factory
 *      evaluates under stub requires and exports the plugin face
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { aggregateGoalTrees, artifactLine, collectReportEntries } from '../lib/goaltrees.js'

// --- 1. aggregation -----------------------------------------------------------
{
  const repoRoot = process.cwd()
  const { runs } = await aggregateGoalTrees(join(repoRoot, '.rdd', 'goal-trees'))
  const demo = runs.find(run => run.runId === 'dsh-demo')
  assert.ok(demo !== undefined, 'dsh-demo run aggregated')
  assert.equal(demo.state, 'running')
  assert.equal(demo.roundsUsed, 1)
  assert.equal(demo.openRound, 1)
  assert.equal(demo.maxRounds, 5)
  assert.equal(demo.maxNodes, 30)
  assert.deepEqual(demo.counts, { pending: 3, claimed: 1, reported: 0, done: 0, pruned: 0 })
  assert.equal(demo.nodes.length, 4)
  const claimed = demo.nodes.find(node => node.id === 'n2')
  assert.equal(claimed.status, 'claimed')
  assert.equal(claimed.claimedBy, 'demo-ui')
  assert.equal(claimed.depth, 1)
  assert.equal(demo.nodes.find(node => node.id === 'n1')?.depth, 0)
  // legacy run (created before the sidecars existed): joins degrade to null
  assert.equal(demo.plannerSessionId, null, 'legacy run: plannerSessionId null')
  assert.equal(claimed.claimSessionId, null, 'legacy claim: claimSessionId null')
  console.log('[smoke] aggregation against dsh-demo OK')

  const missing = await aggregateGoalTrees(join(repoRoot, '.rdd', 'definitely-not-here'))
  assert.deepEqual(missing, { runs: [] })
  console.log('[smoke] missing root -> empty OK')

  const tmpRoot = join(tmpdir(), `rdgt-smoke-${Date.now()}`)
  mkdirSync(join(tmpRoot, 'half-run'), { recursive: true })
  writeFileSync(join(tmpRoot, 'half-run', 'manifest.json'), JSON.stringify({
    run_id: 'half-run', state: 'running', goal: 'g', budget: { max_rounds: 3, max_nodes: 9, node_width: 2 },
  }))
  const half = await aggregateGoalTrees(tmpRoot)
  assert.equal(half.runs.length, 1)
  assert.equal(half.runs[0].nodes.length, 0)
  assert.equal(half.runs[0].roundsUsed, 0)
  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] manifest-only run degrades to empty tree OK')
}

// --- 2. sidecar joins + report collection -------------------------------------
{
  const tmpRoot = join(tmpdir(), `rdgt-smoke-sc-${Date.now()}`)
  const runDir = join(tmpRoot, 'bound-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(join(stateDir, 'claims'), { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'bound-run', state: 'running', goal: 'bound goal', budget: { max_rounds: 4, max_nodes: 12 },
  }))
  writeFileSync(join(stateDir, 'planner.json'), JSON.stringify({
    format_version: 1, run_id: 'bound-run', dsh_session_id: 'session-planner-1', recorded_at: '2026-01-01T00:00:00Z',
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'bound-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [
      { id: 'n1', parent: null, title: 'root', task: 'root task', status: 'pending', depends_on: [] },
      { id: 'n2', parent: 'n1', title: 'leaf', task: 'leaf task', status: 'claimed', claimed_by: 'DEV', depends_on: [] },
      { id: 'n3', parent: 'n1', title: 'leaf2', task: 'leaf2 task', status: 'reported', claimed_by: 'QA', last_verdict: 'done', last_confidence: 0.9, depends_on: [] },
    ],
  }))
  writeFileSync(join(stateDir, 'claims', 'n2.json'), JSON.stringify({
    format_version: 1, run_id: 'bound-run', node_id: 'n2', worker: 'DEV', dsh_session_id: 'session-worker-2', claimed_at: '2026-01-01T00:05:00Z',
  }))
  writeFileSync(join(stateDir, 'ledger.jsonl'), [
    JSON.stringify({ entry_id: 'L1', node_id: 'n3', worker: 'QA', reported_at: '2026-01-01T00:09:00Z', callback: {
      verdict: 'done', confidence: 0.9, summary: 'all good', full_report: 'report/n3.md',
      citations: [{ ref: 'rdd-engine/scripts/goal-tree.ps1', locator: 'schema' }, { ref: 'rdd-engine/scripts/goal-tree-leaf.ps1', locator: 'report' }, { ref: 'rdd-engine/scripts/delivery-bridge.ps1', locator: 'claim' }, { ref: 'rdd-engine/scripts/start-role.ps1', locator: 'marker' }],
      extras: { verification: 'lint + tests + build pass' },
    } }),
    JSON.stringify({ entry_id: 'L2', node_id: 'n2', worker: 'DEV', reported_at: '2026-01-01T00:06:00Z', callback: { verdict: 'inconclusive', confidence: 0.5, summary: 'legacy-shaped' } }),
    '',
  ].join('\n'))

  const { runs } = await aggregateGoalTrees(tmpRoot)
  const run = runs[0]
  assert.equal(run.plannerSessionId, 'session-planner-1', 'planner sidecar joined')
  const n2 = run.nodes.find(node => node.id === 'n2')
  assert.equal(n2.claimSessionId, 'session-worker-2', 'claim sidecar joined')
  assert.equal(n2.task, 'leaf task', 'task text surfaced')
  const n3 = run.nodes.find(node => node.id === 'n3')
  assert.equal(n3.verdict, 'done', 'verdict surfaced')
  assert.equal(n3.confidence, 0.9, 'confidence surfaced')
  assert.equal(n3.claimSessionId, null, 'unbound claim stays null')
  assert.equal(run.nodes.find(node => node.id === 'n1')?.claimSessionId, null, 'pending node unbound')

  const entries = await collectReportEntries(tmpRoot)
  assert.equal(entries.length, 2)
  const l1 = entries.find(e => e.entryId === 'L1')
  assert.deepEqual(l1, {
    runId: 'bound-run', entryId: 'L1', nodeId: 'n3', worker: 'QA',
    verdict: 'done', confidence: 0.9, summary: 'all good', reportedAt: '2026-01-01T00:09:00Z',
    citationCount: 4,
    citationRefs: ['rdd-engine/scripts/goal-tree.ps1', 'rdd-engine/scripts/goal-tree-leaf.ps1', 'rdd-engine/scripts/delivery-bridge.ps1'],
    fullReport: 'report/n3.md', verification: 'lint + tests + build pass',
  })
  // legacy-shaped entry (no artifacts): fields degrade to empty/null, never throw
  const l2 = entries.find(e => e.entryId === 'L2')
  assert.equal(l2.citationCount, 0)
  assert.deepEqual(l2.citationRefs, [])
  assert.equal(l2.fullReport, null)
  assert.equal(l2.verification, null)
  // artifact line (planner-callback-handoff): first-3 refs + doc + digest —
  // the full form runs past the 160-char compact cap, so the rendered line is
  // the capped form (159 chars + ellipsis)
  const fullForm = 'Artifacts: Changes: 4 (rdd-engine/scripts/goal-tree.ps1, rdd-engine/scripts/goal-tree-leaf.ps1, rdd-engine/scripts/delivery-bridge.ps1) / Doc: report/n3.md / Verified: lint + tests + build pass'
  assert.ok(fullForm.length > 160, 'fixture line must actually exercise the cap')
  assert.equal(artifactLine(l1), `${fullForm.slice(0, 159)}…`)
  assert.equal(artifactLine(l2), 'Artifacts: Changes: none / Doc: none / Verified: none')
  // compact discipline: a bloated line caps at 160 chars
  const bloated = artifactLine({ ...l1, fullReport: 'x'.repeat(400), verification: 'y'.repeat(400) })
  assert.equal(bloated.length, 160)
  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] sidecar joins + collectReportEntries + artifactLine OK')
}

// --- 2b. goal-root aggregation: type passthrough + counts exclusion -----------
{
  const tmpRoot = join(tmpdir(), `rdgt-smoke-goal-${Date.now()}`)
  const stateDir = join(tmpRoot, 'goal-root-run', 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(tmpRoot, 'goal-root-run', 'manifest.json'), JSON.stringify({
    run_id: 'goal-root-run', state: 'running', goal: 'original requirement text', budget: { max_rounds: 3, max_nodes: 12, node_width: 3 },
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'goal-root-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [
      { id: 'n1', parent: null, title: '原始需求标题', task: '原始需求描述', status: 'pending', type: 'goal', depends_on: [] },
      { id: 'n2', parent: 'n1', title: '需求A链头', task: 'a', status: 'pending', depends_on: [] },
      { id: 'n3', parent: 'n1', title: '需求B链头', task: 'b', status: 'claimed', claimed_by: 'DEV', depends_on: [] },
      { id: 'n4', parent: 'n1', title: '需求A-QA', task: 'a-qa', status: 'done', depends_on: [] },
    ],
  }))
  const { runs } = await aggregateGoalTrees(tmpRoot)
  const run = runs[0]
  const root = run.nodes.find(node => node.id === 'n1')
  assert.equal(root.type, 'goal', 'goal root type passthrough')
  assert.equal(root.depth, 0, 'goal root is the tree root')
  assert.equal(run.nodes.find(node => node.id === 'n2')?.type, null, 'non-goal node type stays null')
  // counts exclude the type=goal root: pending would be 2 if the root leaked in
  assert.deepEqual(run.counts, { pending: 1, claimed: 1, reported: 0, done: 1, pruned: 0 }, 'goal root excluded from counts')
  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] goal-root aggregation (type passthrough + counts exclusion) OK')
}

// --- 2c. view gating table (tree-display-scoping) ----------------------------
{
  const { pickGoalTreeView } = await import('../lib/client/view-picker.js')
  const run = over => ({ runId: 'r1', nodes: [], plannerSessionId: null, ...over })
  const node = over => ({ claimSessionId: null, ...over })

  // ① worker: a node's claim sidecar matches this session in ANY run — worker
  //    identity wins even when the same session also created a run (current
  //    precedence), and even from a non-first run.
  const w = pickGoalTreeView([
    run({ plannerSessionId: 's-me' }),
    run({ runId: 'r2', nodes: [node({ claimSessionId: 's-me' })] }),
  ], 's-me')
  assert.equal(w.view, 'worker')
  assert.equal(w.run.runId, 'r2')
  assert.equal(w.node.claimSessionId, 's-me')

  // ② planner: full-table scan — the creator of a NON-first run gets their own
  //    tree (the runs[0]-only misattribution fix); first hit in current order.
  const p = pickGoalTreeView([
    run({ runId: 'other', plannerSessionId: 's-someone-else' }),
    run({ runId: 'mine', plannerSessionId: 's-me' }),
  ], 's-me')
  assert.equal(p.view, 'planner')
  assert.equal(p.run.runId, 'mine')

  // ③ plain degradation: the LEAD run carries no planner sidecar (legacy run /
  //    started outside dsh) — bystanders keep the plain full-tree strip.
  const d = pickGoalTreeView([
    run({ runId: 'legacy', plannerSessionId: null }),
    run({ runId: 'r2', plannerSessionId: 's-x' }),
  ], 's-bystander')
  assert.equal(d.view, 'plain')
  assert.equal(d.run.runId, 'legacy')

  // ④ convergence: a sidecar-carrying lead run renders NOTHING for an
  //    unrelated session — no fallback to a later legacy run.
  const n = pickGoalTreeView([
    run({ runId: 'new', plannerSessionId: 's-planner' }),
    run({ runId: 'legacy', plannerSessionId: null }),
  ], 's-bystander')
  assert.equal(n, null)

  // single-run parity with the pre-convergence behavior + degenerate inputs
  assert.equal(pickGoalTreeView([run({ plannerSessionId: 's-me' })], 's-me').view, 'planner')
  assert.equal(pickGoalTreeView([run({ plannerSessionId: null })], 's-me').view, 'plain')
  assert.equal(pickGoalTreeView([run({ plannerSessionId: 's-p' })], undefined), null)
  assert.equal(pickGoalTreeView([], 's-me'), null)
  console.log('[smoke] view gating table (worker/planner/plain/null) OK')
}

// --- 3. engine regression: sidecars on the real CLI ---------------------------
// Runs the patched engine scripts in a temp fixture. Skipped when the ambient
// sandbox forbids spawning a capturing subprocess (EPERM on piped stdio) — the
// same regression then runs from the harness shell instead.
{
  let cliAllowed = true
  try {
    const repoRoot = process.cwd()
    const engineScripts = join(repoRoot, 'rdd-engine', 'scripts')
    const tmpRepo = join(tmpdir(), `rdgt-smoke-cli-${Date.now()}`)
    mkdirSync(tmpRepo, { recursive: true })
    // goal-tree.ps1 resolves its repo root via `git rev-parse` from cwd — the
    // temp fixture must be its own (freshly initialized) git repo, otherwise
    // the CLI dies with "not a git repository" before any sidecar is written
    execFileSync('git', ['init', '--quiet', tmpRepo], { stdio: 'ignore' })
    const runCli = (script, args, env) => {
      try {
        return JSON.parse(execFileSync('powershell.exe', [
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(engineScripts, script),
          ...args,
        ], { cwd: tmpRepo, encoding: 'utf8', env: { ...process.env, ...env } }))
      } catch (error) {
        if (error !== null && typeof error === 'object' && error.code === 'EPERM') {
          cliAllowed = false
          return { success: false }
        }
        throw error
      }
    }

    // start without DSH_SESSION_ID -> planner.json records null
    const started = runCli('goal-tree.ps1', [
      '-Command', 'start', '-RunId', 'smoke-run', '-Goal', 'smoke goal',
      '-RefRoots', '.', '-CreatedBy', 'smoke',
    ], { DSH_SESSION_ID: '' })
    assert.equal(started.success, true)
    const plannerBare = JSON.parse(readFileSync(join(tmpRepo, '.rdd', 'goal-trees', 'smoke-run', 'state', 'planner.json'), 'utf8'))
    assert.equal(plannerBare.dsh_session_id, null, 'planner sidecar null outside dsh')

    // round + claim with a DSH session id -> claims sidecar carries it
    assert.equal(runCli('goal-tree.ps1', ['-Command', 'round-start', '-RunId', 'smoke-run']).success, true)
    const claimed = runCli('goal-tree-leaf.ps1', [
      '-Command', 'claim', '-RunId', 'smoke-run', '-NodeId', 'n1', '-Worker', 'smoke-worker',
    ], { DSH_SESSION_ID: 'session-smoke-worker' })
    assert.equal(claimed.success, true)
    const claimSidecar = JSON.parse(readFileSync(join(tmpRepo, '.rdd', 'goal-trees', 'smoke-run', 'state', 'claims', 'n1.json'), 'utf8'))
    assert.equal(claimSidecar.node_id, 'n1')
    assert.equal(claimSidecar.worker, 'smoke-worker')
    assert.equal(claimSidecar.dsh_session_id, 'session-smoke-worker', 'claims sidecar binds the dsh session')

    // the join surfaces through the aggregate
    const { runs } = await aggregateGoalTrees(join(tmpRepo, '.rdd', 'goal-trees'))
    const smoke = runs.find(run => run.runId === 'smoke-run')
    assert.equal(smoke.plannerSessionId, null)
    assert.equal(smoke.nodes.find(node => node.id === 'n1')?.claimSessionId, 'session-smoke-worker')

    rmSync(tmpRepo, { recursive: true, force: true })
    console.log('[smoke] engine sidecar regression OK')
  } catch (skip) {
    if (!cliAllowed) {
      console.log('[smoke] engine sidecar regression SKIPPED (sandbox forbids capturing subprocesses) — run from the harness shell')
    } else {
      throw skip
    }
  }
}

// --- 4. client bundle format --------------------------------------------------
{
  const src = readFileSync(new URL('../lib/client.js', import.meta.url), 'utf8')
  assert.ok(src.startsWith('window.__ModuleLoader__.load({'), 'client bundle is a loader registration')
  assert.ok(src.includes('"@coderrdd/dsh-rdd-goal-tree"'), 'registration carries the package id')

  let captured = null
  const fakeWindow = { __ModuleLoader__: { load: registration => { captured = registration } } }
  new Function('window', src)(fakeWindow)
  assert.ok(captured !== null, 'registration captured')
  assert.equal(captured.id, '@coderrdd/dsh-rdd-goal-tree')

  const stubs = {
    'react': { useEffect: () => {}, useState: () => [undefined, () => {}] },
    'react/jsx-runtime': { jsx: () => null, jsxs: () => null, Fragment: 'Fragment' },
    '@deepseek-ai/dsh-client-ui-primitives': {
      IconGoalOutline16: () => null,
      IconChevronDownOutline14: () => null,
      IconChevronUpOutline14: () => null,
    },
  }
  const face = captured.factory(spec => {
    if (!(spec in stubs)) throw new Error(`unexpected runtime require: ${spec} (must be a baseline module)`)
    return stubs[spec]
  })
  assert.equal(typeof face.apply, 'function', 'exports.apply')
  assert.ok(Array.isArray(face.inject) && face.inject.includes('slots') && face.inject.includes('locale'), 'exports.inject')
  assert.equal(typeof face.GoalTreeBar, 'function', 'exports.GoalTreeBar')
  assert.equal(typeof face.WorkerNodeBar, 'function', 'exports.WorkerNodeBar')
  assert.equal(typeof face.GoalTreeDock, 'function', 'exports.GoalTreeDock')
  // the dock routes through the gating table, and the picker ships inlined in
  // the bundle (its relative require intercepted — no non-baseline require)
  assert.ok(src.includes('pickGoalTreeView'), 'bundle carries the gating table call')
  assert.ok(src.includes('./view-picker.js'), 'bundle intercepts the picker require')
  console.log('[smoke] client bundle factory + plugin face OK')
}

console.log('[smoke] all green')

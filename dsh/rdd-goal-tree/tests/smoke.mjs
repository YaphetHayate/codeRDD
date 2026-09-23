#!/usr/bin/env node
/**
 * Smoke checks for the built bundle — run AFTER `node scripts/build-dsh-goal-tree.mjs`:
 *   1. aggregateGoalTrees against a seeded legacy demo run (temp fixture,
 *      pre-sidecar shape) and the degenerate cases (missing root, manifest-only run)
 *   2. session-binding sidecar joins: claims/<node>.json + planner.json
 *      (focused worker view / Planner callback target), plus collectReportEntries
 *   2b. goal-root aggregation: type passthrough on nodes and counts excluding
 *      the type=goal root (goal-tree-goal-root)
 *   2g. watcher delivery harness (F3): delivery goes through
 *      agent.send(message, 'next-turn', true) — never a bare inbox.append —
 *      with exactly-once across scans, restarts, and the pending guard
 *   3. engine regression (real CLI, temp fixture): claim writes the claims
 *      sidecar (with DSH_SESSION_ID when the env is set, null when not) and
 *      start writes planner.json
 *   4. lib/client.js is a well-formed module-loader registration whose factory
 *      evaluates under stub requires and exports the plugin face
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { aggregateGoalTrees, artifactLine, collectReportEntries } from '../lib/goaltrees.js'

// --- 1. aggregation -----------------------------------------------------------
{
  const repoRoot = process.cwd()
  // legacy demo run seeded as a temp fixture (pre-sidecar shape) — the repo's
  // .rdd/goal-trees/ keeps only real runs, nothing test-owned
  const demoRoot = join(tmpdir(), `rdgt-smoke-demo-${Date.now()}`)
  const demoState = join(demoRoot, 'dsh-demo', 'state')
  mkdirSync(demoState, { recursive: true })
  writeFileSync(join(demoRoot, 'dsh-demo', 'manifest.json'), JSON.stringify({
    run_id: 'dsh-demo', state: 'running', goal: 'demo goal tree for smoke',
    created_by: 'qa-fixture', created_at: '2026-09-20T06:53:02Z',
    budget: { node_width: 2, max_rounds: 5, max_nodes: 30 },
  }))
  writeFileSync(join(demoState, 'tree.json'), JSON.stringify({
    format_version: 1, updated_at: '2026-09-20T06:53:02Z', run_id: 'dsh-demo',
    nodes: [
      { id: 'n1', parent: null, title: 'root', task: 'root task', status: 'pending', depends_on: [] },
      { id: 'n2', parent: 'n1', title: 'leaf-claimed', task: 'claimed task', status: 'claimed', claimed_by: 'demo-ui', depends_on: [] },
      { id: 'n3', parent: 'n1', title: 'leaf-pending-a', task: 'pending task a', status: 'pending', depends_on: [] },
      { id: 'n4', parent: 'n1', title: 'leaf-pending-b', task: 'pending task b', status: 'pending', depends_on: [] },
    ],
  }))
  writeFileSync(join(demoState, 'round-log.jsonl'), `${JSON.stringify({ event: 'round-start', round: 1, at: '2026-09-20T06:53:02Z' })}\n`)

  const { runs } = await aggregateGoalTrees(demoRoot)
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
  rmSync(demoRoot, { recursive: true, force: true })
  console.log('[smoke] aggregation against seeded legacy demo run OK')

  // the live repo root (real delivery runs, if any) must aggregate without throwing
  const live = await aggregateGoalTrees(join(repoRoot, '.rdd', 'goal-trees'))
  assert.ok(Array.isArray(live.runs), 'live repo root aggregates')
  console.log('[smoke] live repo root aggregates without throwing OK')

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

// --- 2h. structured doc rows (node-doc-links) + UX mockups (ux-mockup-links) --
// The bridge task template (delivery-bridge New-NodeTaskText) decomposes into
// goal/stage/duty + archive-relative doc pointers; the aggregate resolves
// them against .rdd/changes/archive/<归档名>/ with a host-side exists stat.
// Every other shape (free text, legacy English signature, null) parses to
// null — the plain single-line rendering stays the fallback. The aggregate
// additionally enumerates the archive's design/mockups/ directory (UX Phase
// 2.5 convention: final.html / gallery page / direction artifacts) into
// docs.mockups — html/png only, deterministic order, capped; an archive
// without the directory degrades to [] (no chips, no row).
{
  const { parseNodeTask } = await import('../lib/goaltrees.js')
  const bridgeTask = '目标：完成「planner 纯自动模式——worker 侧检查点自动决策」的 DEV 阶段（编码实现）。需求文档：requirements/planner-auto-mode.md；设计文档：design/planner-auto-mode-cto.md、design/planner-auto-mode-qa.md；归档：2026-09-22-planner-auto-mode。开工动作（辅助）：delivery-bridge.cmd -Command claim -RunId deliver-2026-09-22-planner-auto-mode -NodeId <本节点id> -Role DEV。'
  const parsed = parseNodeTask(bridgeTask)
  assert.equal(parsed.goal, '完成「planner 纯自动模式——worker 侧检查点自动决策」的 DEV 阶段（编码实现）。')
  assert.equal(parsed.stage, 'DEV')
  assert.equal(parsed.duty, '（编码实现）')
  assert.equal(parsed.reqRel, 'requirements/planner-auto-mode.md')
  assert.deepEqual(parsed.designRels, ['design/planner-auto-mode-cto.md', 'design/planner-auto-mode-qa.md'])
  assert.equal(parsed.archiveName, '2026-09-22-planner-auto-mode')
  // non-matching shapes degrade to null (zero-injection contract)
  assert.equal(parseNodeTask(null), null)
  assert.equal(parseNodeTask(''), null)
  assert.equal(parseNodeTask('leaf task'), null)
  assert.equal(parseNodeTask('Execute TaskId 1 now'), null)

  // aggregation: abs resolution under the archive root + exists stat
  const tmp = join(tmpdir(), `rdgt-smoke-docs-${Date.now()}`)
  const runId = 'deliver-2026-09-22-demo'
  const runDir = join(tmp, '.rdd', 'goal-trees', runId)
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  const arch = join(tmp, '.rdd', 'changes', 'archive', '2026-09-22-demo')
  mkdirSync(join(arch, 'requirements'), { recursive: true })
  mkdirSync(join(arch, 'design'), { recursive: true })
  writeFileSync(join(arch, 'requirements', 'auto-mode.md'), '# requirement')
  writeFileSync(join(arch, 'design', 'auto-mode-cto.md'), '# design') // the QA design stays absent (pending)
  // UX Phase 2.5 mockup convention: finalized mockup + gallery page + one
  // direction artifact + image reference; manifest.json is the gallery's data
  // source and must NOT surface as a chip.
  mkdirSync(join(arch, 'design', 'mockups', 'images'), { recursive: true })
  writeFileSync(join(arch, 'design', 'mockups', 'final.html'), '<html>final</html>')
  writeFileSync(join(arch, 'design', 'mockups', 'index.html'), '<html>gallery</html>')
  writeFileSync(join(arch, 'design', 'mockups', 'direction-a-info-density.png'), 'png')
  writeFileSync(join(arch, 'design', 'mockups', 'images', 'reference.png'), 'png')
  writeFileSync(join(arch, 'design', 'mockups', 'manifest.json'), '{}')
  // sibling task archive WITHOUT a mockups directory: degrades to []
  const bareArch = join(tmp, '.rdd', 'changes', 'archive', '2026-09-22-bare')
  mkdirSync(join(bareArch, 'design'), { recursive: true })
  const bareRunDir = join(tmp, '.rdd', 'goal-trees', 'deliver-2026-09-22-bare')
  mkdirSync(join(bareRunDir, 'state'), { recursive: true })
  writeFileSync(join(bareRunDir, 'manifest.json'), JSON.stringify({
    run_id: 'deliver-2026-09-22-bare', state: 'running', goal: 'bare goal', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeFileSync(join(bareRunDir, 'state', 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'deliver-2026-09-22-bare', updated_at: '2026-09-22T00:00:00Z',
    nodes: [
      {
        id: 'b1', parent: null, title: '裸归档任务', status: 'claimed', claimed_by: 'DEV', depends_on: [],
        task: '目标：完成「裸归档任务」的 DEV 阶段（编码实现）。需求文档：requirements/bare.md；归档：2026-09-22-bare。开工动作（辅助）：delivery-bridge.cmd -Command claim -RunId deliver-2026-09-22-bare -NodeId <本节点id> -Role DEV。',
      },
    ],
  }))
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: runId, state: 'running', goal: 'structured docs goal', budget: { max_rounds: 4, max_nodes: 12 },
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: runId, updated_at: '2026-09-22T00:00:00Z',
    nodes: [
      { id: 'n1', parent: null, title: '原始需求', task: '原始需求描述全文', status: 'pending', type: 'goal', depends_on: [] },
      {
        id: 'n2', parent: 'n1', title: 'planner 纯自动模式——worker 侧检查点自动决策', status: 'claimed', claimed_by: 'DEV', depends_on: [],
        task: '目标：完成「planner 纯自动模式——worker 侧检查点自动决策」的 DEV 阶段（编码实现）。需求文档：requirements/auto-mode.md；设计文档：design/auto-mode-cto.md、design/auto-mode-qa.md；归档：2026-09-22-demo。开工动作（辅助）：delivery-bridge.cmd -Command claim -RunId deliver-2026-09-22-demo -NodeId <本节点id> -Role DEV。',
      },
      { id: 'n3', parent: 'n1', title: 'legacy leaf', task: 'legacy free-text task', status: 'pending', depends_on: [] },
    ],
  }))
  const { runs } = await aggregateGoalTrees(join(tmp, '.rdd', 'goal-trees'), tmp)
  const run = runs.find(r => r.runId === runId)
  assert.equal(run.nodes.find(n => n.id === 'n1')?.docs, null, 'goal-root free text never parses')
  const n2 = run.nodes.find(n => n.id === 'n2')
  assert.ok(n2.docs !== null, 'bridge node parses')
  assert.equal(n2.docs.goal, '完成「planner 纯自动模式——worker 侧检查点自动决策」的 DEV 阶段（编码实现）。')
  assert.deepEqual(n2.docs.requirement, {
    rel: 'requirements/auto-mode.md', abs: join(arch, 'requirements', 'auto-mode.md'), exists: true,
  })
  assert.equal(n2.docs.designs.length, 2)
  assert.deepEqual(n2.docs.designs[0], { rel: 'design/auto-mode-cto.md', abs: join(arch, 'design', 'auto-mode-cto.md'), exists: true })
  assert.equal(n2.docs.designs[1].exists, false, 'not-yet-produced design doc reports exists=false')
  // ux-mockup-links: deterministic order (final → gallery → name-sorted),
  // html/png only (manifest.json excluded), enumerated chips exist by
  // construction, archive-relative rel spelling
  assert.deepEqual(n2.docs.mockups.map(m => m.rel), [
    'design/mockups/final.html',
    'design/mockups/index.html',
    'design/mockups/direction-a-info-density.png',
    'design/mockups/images/reference.png',
  ])
  assert.deepEqual(n2.docs.mockups[0], {
    rel: 'design/mockups/final.html', abs: join(arch, 'design', 'mockups', 'final.html'), exists: true,
  })
  assert.equal(run.nodes.find(n => n.id === 'n3')?.docs, null, 'legacy task: docs null (plain fallback)')
  // archive without design/mockups/: mockups degrade to [] (no row rendered)
  const bare = runs.find(r => r.runId === 'deliver-2026-09-22-bare')
  assert.ok(bare !== undefined, 'bare run aggregated')
  const b1 = bare.nodes.find(n => n.id === 'b1')
  assert.ok(b1.docs !== null, 'bare bridge node parses')
  assert.deepEqual(b1.docs.mockups, [], 'no mockups directory -> empty chips (zero degradation)')

  rmSync(tmp, { recursive: true, force: true })
  console.log('[smoke] structured doc rows (parse + archive join + exists) + UX mockups OK')
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

// --- 2d. planner lease resolution (planner-uniqueness-callback) ---------------
// The watcher's callback-target rule: a FRESH dsh-shaped lease holder wins,
// anything else falls back to planner.json. These assertions also pin the
// freshness constant against the engine side (delivery-bridge.ps1's
// $LeaseStaleMinutes default = 30) — drift between the two breaks the
// takeover/resume semantics both sides assume.
{
  const { readPlannerLease, PLANNER_LEASE_FRESH_MS } = await import('../lib/goaltrees.js')
  assert.equal(PLANNER_LEASE_FRESH_MS, 30 * 60 * 1000, 'freshness window mirrors delivery-bridge $LeaseStaleMinutes default (30min)')

  const tmpRoot = join(tmpdir(), `rdgt-smoke-lease-${Date.now()}`)
  const mk = (name, lease) => {
    const dir = join(tmpRoot, name)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'planner-lease.json'), typeof lease === 'string' ? lease : JSON.stringify(lease))
    return dir
  }
  const iso = msAgo => new Date(Date.now() - msAgo).toISOString()

  // fresh dsh holder → its sid wins (takeover/resume re-pointing, resume repair)
  const fresh = mk('fresh', { acquired_at: iso(5 * 60 * 1000), holder: 'dsh-session-takeover', taken_over_from: 'dsh-session-origin' })
  assert.equal(await readPlannerLease(fresh), 'session-takeover')

  // just inside the boundary still counts as fresh
  const boundary = mk('boundary', { acquired_at: iso(PLANNER_LEASE_FRESH_MS - 1000), holder: 'dsh-session-b' })
  assert.equal(await readPlannerLease(boundary), 'session-b')

  // stale lease → null: falls back to planner.json (idle-origin case)
  const stale = mk('stale', { acquired_at: iso(31 * 60 * 1000), holder: 'dsh-session-old' })
  assert.equal(await readPlannerLease(stale), null)

  // non-dsh holder (CLI pid shape) → null: planner.json fallback preserves the CLI status quo
  const cli = mk('cli', { acquired_at: iso(60 * 1000), holder: 'planner-pid-1234' })
  assert.equal(await readPlannerLease(cli), null)

  // missing / corrupt / malformed leases never throw (delivery must not break)
  const none = join(tmpRoot, 'no-lease')
  mkdirSync(none, { recursive: true })
  assert.equal(await readPlannerLease(none), null)
  assert.equal(await readPlannerLease(mk('corrupt', '{not json')), null)
  assert.equal(await readPlannerLease(mk('malformed', { holder: 'dsh-session-x' })), null)
  assert.equal(await readPlannerLease(mk('badtime', { acquired_at: 'not-a-date', holder: 'dsh-session-y' })), null)

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] planner lease resolution (fresh-lease-first, fallback) OK')
}

// --- 2e. decision collection (planner-auto-mode) -------------------------------
// Open-escalation join over decisions.jsonl: escalation entries minus those
// referenced by a resolution/overturn ref_entry; corrupt lines skip; a run
// without the ledger (the default, non-auto-mode shape) yields nothing.
{
  const { collectDecisionEntries } = await import('../lib/goaltrees.js')
  const tmpRoot = join(tmpdir(), `rdgt-smoke-dec-${Date.now()}`)
  const runDir = join(tmpRoot, 'auto-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'auto-run', state: 'running', goal: 'auto mode goal', budget: { max_rounds: 4, max_nodes: 12 },
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'auto-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [{ id: 'n1', parent: null, title: 'root', task: 't', status: 'pending', depends_on: [] }],
  }))
  writeFileSync(join(runDir, 'decisions.jsonl'), [
    JSON.stringify({ entry_id: 'D1', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'auto', checkpoint: '命名', decision: 'x', decider: 'auto/R7@CTO' }),
    JSON.stringify({ entry_id: 'D2', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'escalation', checkpoint: '技术选型', decision: 'A 还是 B？', risk: 'high', rule_id: 'R4', decider: null }),
    JSON.stringify({ entry_id: 'D3', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'escalation', checkpoint: 'git 操作', decision: '允许 push 吗？', risk: 'high', rule_id: 'R1' }),
    JSON.stringify({ entry_id: 'D4', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'resolution', checkpoint: '技术选型', decision: '选 A', decider: 'user@in-session', ref_entry: 'D2' }),
    'not json at all',
    JSON.stringify({ entry_id: 'D5', node_id: 'n1', task_id: 1, stage: 'DEV', kind: 'overturn', checkpoint: '命名', decision: '重想', decider: 'user@in-session', ref_entry: 'D1' }),
    '',
  ].join('\n'))
  // sibling run WITHOUT a decisions ledger (legacy / default posture) must stay silent
  const plainDir = join(tmpRoot, 'plain-run')
  mkdirSync(join(plainDir, 'state'), { recursive: true })
  writeFileSync(join(plainDir, 'manifest.json'), JSON.stringify({
    run_id: 'plain-run', state: 'running', goal: 'g', budget: { max_rounds: 2, max_nodes: 6 },
  }))

  const open = await collectDecisionEntries(tmpRoot)
  // D2 is closed by D4 (resolution), D1 is referenced by D5 (overturn), D3 stays open
  assert.equal(open.length, 1, 'only the unreferenced escalation is open')
  const d3 = open[0]
  assert.equal(d3.entryId, 'D3')
  assert.equal(d3.runId, 'auto-run')
  assert.equal(d3.nodeId, 'n1')
  assert.equal(d3.stage, 'CTO')
  assert.equal(d3.checkpoint, 'git 操作')
  assert.equal(d3.question, '允许 push 吗？')
  assert.equal(d3.risk, 'high')
  assert.equal(d3.ruleId, 'R1')
  assert.equal(d3.decider, undefined, 'decider is not part of the wire shape')

  // resolution closing the remaining escalation empties the open set (join-derived)
  appendFileSync(join(runDir, 'decisions.jsonl'), `${JSON.stringify({ entry_id: 'D6', kind: 'resolution', ref_entry: 'D3', decision: 'no' })}\n`)
  const closed = await collectDecisionEntries(tmpRoot)
  assert.equal(closed.length, 0, 'all escalations closed')

  // corrupt-line prefix never throws (degrades to the parseable set)
  writeFileSync(join(runDir, 'decisions.jsonl'), [
    '{broken',
    JSON.stringify({ entry_id: 'D9', node_id: 'n1', kind: 'escalation', checkpoint: 'c', decision: 'q' }),
  ].join('\n'))
  const degraded = await collectDecisionEntries(tmpRoot)
  assert.equal(degraded.length, 1)
  assert.equal(degraded[0].entryId, 'D9')

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] collectDecisionEntries (open-escalation join) OK')
}

// --- 2f. durable delivered-markers (incident 0923 fix) -------------------------
// The exactly-once sidecar: missing/corrupt file reads empty (never throws),
// record is idempotent, and a fresh read after "restart" (new call = new
// in-memory life) recovers the recorded markers — the replay-storm fix.
{
  const { readDeliveredMarkers, recordDeliveredMarker } = await import('../lib/goaltrees.js')
  const tmpRoot = join(tmpdir(), `rdgt-smoke-markers-${Date.now()}`)
  const runDir = join(tmpRoot, 'mk-run')
  mkdirSync(runDir, { recursive: true })

  const empty = await readDeliveredMarkers(runDir)
  assert.equal(empty.size, 0, 'missing sidecar reads as empty')

  await recordDeliveredMarker(runDir, 'ledger L1')
  await recordDeliveredMarker(runDir, 'decision D3')
  await recordDeliveredMarker(runDir, 'ledger L1') // idempotent
  const one = await readDeliveredMarkers(runDir)
  assert.equal(one.size, 2, 'two distinct markers persisted')
  assert.ok(one.has('ledger L1') && one.has('decision D3'), 'markers round-trip')

  // "crash + restart": a fresh read (new process would re-read the same file)
  const two = await readDeliveredMarkers(runDir)
  assert.ok(two.has('ledger L1'), 'marker survives a reader restart')

  // corrupt sidecar degrades to empty, and record rewrites it whole
  writeFileSync(join(runDir, '.callback-delivered.json'), '{broken json')
  const degraded = await readDeliveredMarkers(runDir)
  assert.equal(degraded.size, 0, 'corrupt sidecar reads as empty')
  await recordDeliveredMarker(runDir, 'ledger L2')
  const repaired = await readDeliveredMarkers(runDir)
  assert.equal(repaired.size, 1, 'record repairs a corrupt sidecar')
  assert.ok(repaired.has('ledger L2'))

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] durable delivered-markers (restart-safe exactly-once) OK')
}

// --- 2g. watcher delivery harness (F3 wake semantics + exactly-once) -----------
// Drives the extracted PlannerCallbackWatcher standalone (the module is
// runtime-dependency-free: the message factory is constructor-injected, the
// agent registry is a recording stub). Pins the F3 ruling — delivery routes
// through agent.send(message, 'next-turn', true) and NEVER a bare
// inbox.append — plus the exactly-once invariants around it (in-memory set,
// restart marker hydration, pending-inbox guard). scanRoot is TS-private;
// the harness reaches it deliberately from untyped JS.
{
  const { PlannerCallbackWatcher } = await import('../lib/watcher.js')
  const { readDeliveredMarkers } = await import('../lib/goaltrees.js')
  const PLUGIN_ID = '@coderrdd/dsh-rdd-goal-tree'
  const tmpRoot = join(tmpdir(), `rdgt-smoke-watcher-${Date.now()}`)
  // scanRoot treats its argument as a REPO root and joins .rdd/goal-trees itself
  const runDir = join(tmpRoot, '.rdd', 'goal-trees', 'watch-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'watch-run', state: 'running', goal: 'watcher harness goal', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeFileSync(join(stateDir, 'planner.json'), JSON.stringify({
    format_version: 1, run_id: 'watch-run', dsh_session_id: 'session-planner-w', recorded_at: '2026-01-01T00:00:00Z',
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'watch-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [{ id: 'n1', parent: null, title: 'root', task: 't', status: 'pending', depends_on: [] }],
  }))
  writeFileSync(join(stateDir, 'ledger.jsonl'), `${JSON.stringify({
    entry_id: 'L1', node_id: 'n1', worker: 'DEV', reported_at: '2026-01-01T00:20:00Z', callback: {
      verdict: 'done', confidence: 0.9, summary: 'watcher fixture', full_report: 'report/n1.md',
      citations: [{ ref: 'rdd-engine/scripts/delivery-bridge.ps1', locator: 'claim' }],
      extras: { verification: 'tests pass' },
    },
  })}\n`)
  writeFileSync(join(runDir, 'decisions.jsonl'), `${JSON.stringify({
    entry_id: 'D2', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'escalation',
    checkpoint: '技术选型', decision: 'A 还是 B？', risk: 'high', rule_id: 'R4', decider: null,
  })}\n`)

  const sends = [], appends = [], infoLogs = []
  let seq = 0
  const stubFactory = input => ({ id: `m-${++seq}`, role: 'user', content: input.content, source: input.source })
  const fakeAgent = {
    inbox: {
      nextTurn: [],
      nextStep: [],
      append: (target, message) => { appends.push({ target, message }) },
    },
    send: (message, target, wakeup) => { sends.push({ message, target, wakeup }) },
  }
  const ctx = {
    logger: { info: line => infoLogs.push(line), warn: () => {} },
    agents: { get: sid => (sid === 'session-planner-w' ? fakeAgent : undefined) },
  }

  const watcher = new PlannerCallbackWatcher(ctx, true, 0, stubFactory)
  await watcher.scanRoot(tmpRoot)

  // F3 core: wakeful delivery on the next-turn boundary, no bare appends
  assert.equal(sends.length, 2, 'ledger + escalation each delivered once')
  assert.ok(sends.every(call => call.target === 'next-turn'), 'delivery targets the next-turn boundary')
  assert.ok(sends.every(call => call.wakeup === true), 'F3: delivery wakes the planner driver')
  assert.equal(appends.length, 0, 'F3: no bare inbox.append delivery path')
  assert.ok(sends.every(call => call.message.source.kind === 'plugin' && call.message.source.plugin === PLUGIN_ID))
  const ledgerText = sends[0].message.content.map(block => block.text).join('\n')
  const decisionText = sends[1].message.content.map(block => block.text).join('\n')
  assert.ok(ledgerText.includes('(ledger L1)') && ledgerText.includes('verdict=done'), 'ledger notice carries entry + verdict')
  assert.ok(decisionText.includes('decision D2 is OPEN') && decisionText.includes('技术选型'), 'escalation notice carries id + checkpoint')
  assert.ok(infoLogs.length === 2 && infoLogs.every(line => line.endsWith('→ session session-planner-w')), 'delivery logs name the target session')
  const markers = await readDeliveredMarkers(runDir)
  assert.ok(markers.has('ledger L1') && markers.has('decision D2'), 'durable markers persisted')

  // exactly-once within a plugin life (in-memory set)
  await watcher.scanRoot(tmpRoot)
  assert.equal(sends.length, 2, 'exactly-once within a plugin life')

  // exactly-once across a restart: fresh watcher, empty in-memory set, the
  // durable markers hydrate back in before the delivery arm runs
  const restarted = new PlannerCallbackWatcher(ctx, true, 0, stubFactory)
  await restarted.scanRoot(tmpRoot)
  assert.equal(sends.length, 2, 'exactly-once across a plugin restart (marker hydration)')

  // pending-inbox guard: a previous plugin life already queued both notices
  // (markers wiped to force the path) — the guard marks and skips, no re-send
  rmSync(join(runDir, '.callback-delivered.json'))
  fakeAgent.inbox.nextTurn.push(
    { source: { kind: 'plugin', plugin: PLUGIN_ID }, content: [{ type: 'text', text: 'already carrying ledger L1' }] },
    { source: { kind: 'plugin', plugin: PLUGIN_ID }, content: [{ type: 'text', text: 'already carrying decision D2' }] },
  )
  const third = new PlannerCallbackWatcher(ctx, true, 0, stubFactory)
  await third.scanRoot(tmpRoot)
  assert.equal(sends.length, 2, 'already-queued notices are marked, never re-sent')
  assert.ok((await readDeliveredMarkers(runDir)).has('ledger L1'), 'the guard persists the marker it skipped')

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] watcher delivery harness (send+wakeup, exactly-once, hydration, pending guard) OK')
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
  assert.ok(
    Array.isArray(face.inject) && face.inject.includes('slots') && face.inject.includes('locale') && face.inject.includes('workspaces'),
    'exports.inject (slots + locale + workspaces for the doc opener)',
  )
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

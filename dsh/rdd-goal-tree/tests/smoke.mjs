#!/usr/bin/env node
/**
 * Smoke checks for the built bundle — run AFTER `node scripts/build-dsh-goal-tree.mjs`:
 *   1. aggregateGoalTrees against a seeded legacy demo run (temp fixture,
 *      pre-sidecar shape) and the degenerate cases (missing root, manifest-only run)
 *   2. session-binding sidecar joins: claims/<node>.json + planner.json
 *      (focused worker view / Planner callback target), plus collectReportEntries
 *   2b. goal-root aggregation: type passthrough on nodes and counts excluding
 *      the type=goal root (goal-tree-goal-root)
 *   2e. decision-ledger collection (planner-auto-mode): archive-level ledger
 *      resolved per run through bridge.json `archive_rel` + legacy run-dir fallback;
 *      once-per-ledger across sibling runs sharing one archive
 *   2f. durable delivered-markers (incident 0923 fix): restart-safe exactly-once
 *      sidecar — serialized read-modify-write + atomic temp-rename (concurrent
 *      writers lose nothing, no torn files, no temp residue)
 *   2g. watcher delivery harness (F3): delivery goes through
 *      agent.send(message, 'next-turn', true) — never a bare inbox.append —
 *      with exactly-once across scans, restarts, and the pending guard
 *      (exact-token marker match: 'ledger L2' never satisfies 'ledger L21')
 *   2i. plugin-perf L2/L3: liveness shortcut (direct claim-sidecar read,
 *      no aggregation) + wire projection (slim default payload, full detail
 *      for claim-carrying runs, ?run detail shape)
 *   2j. plugin-perf L2: per-run aggregation cache — TTL debounce floor,
 *      mtime-fingerprint invalidation, reference-stable reuse on hit
 *   3. engine regression (real CLI, temp fixture): claim writes the claims
 *      sidecar (with DSH_SESSION_ID when the env is set, null when not) and
 *      start writes planner.json
 *   4. lib/client.js is a well-formed module-loader registration whose factory
 *      evaluates under stub requires and exports the plugin face
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
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

  // outline order: tree.json graft order is NOT a DFS traversal — a chain
  // node grafted under an early head (n8 → n2) while later heads still hang
  // under the root (n3..n7) must not nest visually under its numeric
  // predecessor (the n8-under-n7 panel regression)
  const orderRoot = join(tmpdir(), `rdgt-smoke-order-${Date.now()}`)
  const orderState = join(orderRoot, 'order-run', 'state')
  mkdirSync(orderState, { recursive: true })
  writeFileSync(join(orderRoot, 'order-run', 'manifest.json'), JSON.stringify({
    run_id: 'order-run', state: 'running', goal: 'outline order fixture', budget: { node_width: 10, max_rounds: 5, max_nodes: 30 },
  }))
  writeFileSync(join(orderState, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'order-run', updated_at: '2026-10-16T00:00:00Z',
    nodes: [
      { id: 'n1', parent: null, title: 'root', task: 'root task', status: 'pending', depends_on: [] },
      { id: 'n2', parent: 'n1', title: 'head-a', task: 'head a', status: 'done', depends_on: [] },
      { id: 'n3', parent: 'n1', title: 'head-b', task: 'head b', status: 'pending', depends_on: [] },
      { id: 'n4', parent: 'n1', title: 'head-c', task: 'head c', status: 'pending', depends_on: [] },
      { id: 'n5', parent: 'n1', title: 'head-d', task: 'head d', status: 'pending', depends_on: [] },
      { id: 'n6', parent: 'n1', title: 'head-e', task: 'head e', status: 'pending', depends_on: [] },
      { id: 'n7', parent: 'n1', title: 'head-f', task: 'head f', status: 'pending', depends_on: [] },
      { id: 'n8', parent: 'n2', title: 'chain', task: 'chain of head a', status: 'done', depends_on: [] },
      { id: 'n9', parent: 'n8', title: 'chain-2', task: 'chain of n8', status: 'done', depends_on: [] },
      { id: 'n10', parent: 'n1', title: 'late-head', task: 'late head', status: 'pending', depends_on: [] },
    ],
  }))
  const { runs: orderedRuns } = await aggregateGoalTrees(orderRoot)
  const ordered = orderedRuns.find(run => run.runId === 'order-run')
  assert.ok(ordered !== undefined, 'order-run aggregated')
  assert.deepEqual(ordered.nodes.map(node => node.id), [
    'n1', 'n2', 'n8', 'n9', 'n3', 'n4', 'n5', 'n6', 'n7', 'n10',
  ], 'wire node list is DFS pre-order, not graft order')
  assert.ok(
    ordered.nodes.findIndex(node => node.id === 'n8') === ordered.nodes.findIndex(node => node.id === 'n2') + 1,
    'n8 renders directly under n2 (not under its numeric predecessor n7)',
  )
  // orphan parent (dangling ref) anchors at the top level instead of dropping
  const { orderOutlineNodes } = await import('../lib/goaltrees.js')
  const withOrphan = [
    { id: 'n1', parent: null },
    { id: 'n2', parent: 'n1' },
    { id: 'n3', parent: 'nX' },
  ]
  assert.deepEqual(orderOutlineNodes(withOrphan).map(node => node.id), ['n1', 'n2', 'n3'], 'orphan anchors top-level, nothing dropped')
  const withCycle = [
    { id: 'n1', parent: null },
    { id: 'n2', parent: 'n3' },
    { id: 'n3', parent: 'n2' },
  ]
  assert.deepEqual(orderOutlineNodes(withCycle).map(node => node.id), ['n1', 'n2', 'n3'], 'cycle leftovers stay visible in input order')
  rmSync(orderRoot, { recursive: true, force: true })
  console.log('[smoke] outline DFS order (graft order != DFS) OK')

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

// --- 2f. wake-rotation: two-tier fields + withered lineage + report digest ----
{
  const tmpRoot = join(tmpdir(), `rdgt-smoke-rot-${Date.now()}`)
  const runDir = join(tmpRoot, 'deliver-rot-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'deliver-rot-run', state: 'running', goal: 'rotation goal',
    budget: { max_rounds: 4, max_nodes: 12, wake_max: 3, wake_total_max: 6 },
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'deliver-rot-run', updated_at: '2026-10-24T00:10:00Z',
    nodes: [
      { id: 'n1', parent: null, title: 'root', task: 'root task', status: 'pending', depends_on: [] },
      // rotated slot: s2 serving, 3 wakes burned across 2 segments
      { id: 'n2', parent: 'n1', title: 'cto slot', task: 'cto task', status: 'done', claimed_by: 'CTO', wake_count: 0, wake_max: 3, segment: 2, wake_total: 3, ledger_refs: ['L1', 'L3'], depends_on: [] },
      // legacy slot: no segment fields -> 1 / null
      { id: 'n3', parent: 'n1', title: 'legacy slot', task: 'legacy', status: 'pending', wake_count: 2, depends_on: [] },
    ],
  }))
  writeFileSync(join(stateDir, 'ledger.jsonl'), [
    JSON.stringify({ entry_id: 'L1', node_id: 'n2', worker: 'CTO', reported_at: '2026-10-24T00:01:00Z', callback: {
      verdict: 'done', confidence: 0.8, summary: 'first segment delivery', full_report: 'report/dev-design.md',
      citations: [{ ref: 'rdd-engine/scripts/goal-tree.ps1', locator: 'schema' }],
      extras: { verification: 'smoke ok', rework_round3_report: 'report/rework-3.md', rework_round1_report: 'report/rework-1.md' },
    } }),
    JSON.stringify({ entry_id: 'L2', type: 'rotate', node_id: 'n2', at: '2026-10-24T00:02:00Z', from_segment: 1, to_segment: 2, wake_total: 3, reason: 'wake-rotation: segment s1 burned its quota [3/3]' }),
    JSON.stringify({ entry_id: 'L3', node_id: 'n2', worker: 'CTO', reported_at: '2026-10-24T00:03:00Z', callback: {
      verdict: 'done', confidence: 0.9, summary: 'second segment delivery — the tail ref wins', full_report: 'report/dev-final.md',
      citations: [], extras: { verification: 'lint pass', rework_round3_report: 'report/rework-3.md', rework_round1_report: 'report/rework-1.md' },
    } }),
    '',
  ].join('\n'))

  const { runs } = await aggregateGoalTrees(tmpRoot)
  const run = runs[0]
  const n2 = run.nodes.find(node => node.id === 'n2')
  // two-tier fields passthrough
  assert.equal(n2.segment, 2, 'segment passthrough')
  assert.equal(n2.wakeTotal, 3, 'wake_total passthrough')
  assert.equal(n2.wakeCount, 0, 'post-rotation segment counter is zero')
  // withered lineage: s1 dead (with rotate note) + s2 serving
  assert.deepEqual(n2.lineage, [
    { segment: 1, active: false, note: 'wake-rotation: segment s1 burned its quota [3/3]' },
    { segment: 2, active: true, note: null },
  ], 'lineage rows: withered s1 with rotate reason + active s2')
  // legacy node: no lineage, segment reads 1
  const n3 = run.nodes.find(node => node.id === 'n3')
  assert.equal(n3.segment, 1, 'legacy node segment defaults to 1')
  assert.equal(n3.wakeTotal, null, 'legacy node wake_total stays null (engine interprets)')
  assert.deepEqual(n3.lineage, [], 'legacy node carries no lineage rows')
  // report digest joins on the TAIL ref (L3), not the first
  assert.ok(n2.report !== null, 'report digest attached')
  assert.equal(n2.report.entryId, 'L3', 'digest joins ledger_refs[-1]')
  assert.equal(n2.report.summary, 'second segment delivery — the tail ref wins')
  assert.equal(n2.report.verdict, 'done')
  assert.equal(n2.report.confidence, 0.9)
  assert.equal(n2.report.verification, 'lint pass')
  assert.equal(n2.report.fullReport?.rel, 'report/dev-final.md', 'full report chip resolved')
  // rework chips surface sorted by round
  assert.equal(n2.report.reworkReports.length, 2, 'rework reports extracted')
  assert.deepEqual(n2.report.reworkReports.map(d => d.rel), ['report/rework-1.md', 'report/rework-3.md'], 'rework chips round-sorted')
  // nodes without a report ref keep the digest null
  assert.equal(run.nodes.find(node => node.id === 'n1')?.report ?? null, null, 'unreported node: null digest')
  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] wake-rotation two-tier fields + lineage + report digest OK')
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
// Open-escalation join over the unified decision ledger: escalation entries minus
// those referenced by a resolution/overturn ref_entry; corrupt lines skip; a run
// without the ledger (the default, non-auto-mode shape) yields nothing. Since
// planner-midrun-derive the ledger lives at the ARCHIVE ROOT
// (.rdd/changes/archive/<归档名>/decisions.jsonl), resolved per run through its
// bridge.json `archive_rel` — the pre-migration run-dir location stays readable
// as a legacy fallback. (QA defect R1: the watcher kept reading the run dir while
// the engine wrote the archive, silently breaking auto-mode escalation delivery.)
{
  const { collectDecisionEntries } = await import('../lib/goaltrees.js')
  const repoRoot = join(tmpdir(), `rdgt-smoke-dec-${Date.now()}`)
  const rootDir = join(repoRoot, '.rdd', 'goal-trees')
  const runDir = join(rootDir, 'auto-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'auto-run', state: 'running', goal: 'auto mode goal', budget: { max_rounds: 4, max_nodes: 12 },
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'auto-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [{ id: 'n1', parent: null, title: 'root', task: 't', status: 'pending', depends_on: [] }],
  }))
  // the engine's ledger sits at the ARCHIVE root; bridge.json is the run's own
  // pointer to it (the single source the watcher must follow)
  const archiveDir = join(repoRoot, '.rdd', 'changes', 'archive', 'auto-arch')
  mkdirSync(archiveDir, { recursive: true })
  writeFileSync(join(runDir, 'bridge.json'), JSON.stringify({
    run_id: 'auto-run', archive: archiveDir, archive_rel: '.rdd/changes/archive/auto-arch',
  }))
  const ledger = join(archiveDir, 'decisions.jsonl')
  writeFileSync(ledger, [
    JSON.stringify({ entry_id: 'D1', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'auto', checkpoint: '命名', decision: 'x', decider: 'auto/R7@CTO' }),
    JSON.stringify({ entry_id: 'D2', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'escalation', checkpoint: '技术选型', decision: 'A 还是 B？', risk: 'high', rule_id: 'R4', decider: null }),
    JSON.stringify({ entry_id: 'D3', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'escalation', checkpoint: 'git 操作', decision: '允许 push 吗？', risk: 'high', rule_id: 'R1' }),
    JSON.stringify({ entry_id: 'D4', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'resolution', checkpoint: '技术选型', decision: '选 A', decider: 'user@in-session', ref_entry: 'D2' }),
    'not json at all',
    JSON.stringify({ entry_id: 'D5', node_id: 'n1', task_id: 1, stage: 'DEV', kind: 'overturn', checkpoint: '命名', decision: '重想', decider: 'user@in-session', ref_entry: 'D1' }),
    '',
  ].join('\n'))
  // sibling run WITHOUT a decisions ledger (legacy / default posture) must stay silent
  const plainDir = join(rootDir, 'plain-run')
  mkdirSync(join(plainDir, 'state'), { recursive: true })
  writeFileSync(join(plainDir, 'manifest.json'), JSON.stringify({
    run_id: 'plain-run', state: 'running', goal: 'g', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  // sibling LEGACY run (pre-migration shape): no bridge.json, the ledger still
  // sits in the run dir — the fallback keeps its escalations deliverable
  const legacyDir = join(rootDir, 'legacy-run')
  mkdirSync(join(legacyDir, 'state'), { recursive: true })
  writeFileSync(join(legacyDir, 'manifest.json'), JSON.stringify({
    run_id: 'legacy-run', state: 'running', goal: 'legacy auto goal', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeFileSync(join(legacyDir, 'decisions.jsonl'), [
    JSON.stringify({ entry_id: 'D7', node_id: 'n1', task_id: 1, stage: 'DEV', kind: 'escalation', checkpoint: '成本', decision: '允许外呼吗？', risk: 'high', rule_id: 'R2' }),
  ].join('\n'))

  const open = await collectDecisionEntries(rootDir)
  // D2 is closed by D4 (resolution), D1 is referenced by D5 (overturn); the
  // archive-level D3 and the legacy run-dir D7 stay open
  assert.equal(open.length, 2, 'only the unreferenced escalations are open')
  // the bridge run carries NO run-dir ledger: a run-dir-only read (the pre-fix
  // shape) finds nothing here, so the archive-level hit below IS the R1 anchor
  assert.ok(!existsSync(join(runDir, 'decisions.jsonl')), 'bridge-run fixture pins the archive-level-only shape')
  const d3 = open.find(entry => entry.runId === 'auto-run')
  assert.ok(d3 !== undefined, 'archive-level ledger reached through bridge.json archive_rel')
  assert.equal(d3.entryId, 'D3')
  assert.equal(d3.nodeId, 'n1')
  assert.equal(d3.stage, 'CTO')
  assert.equal(d3.checkpoint, 'git 操作')
  assert.equal(d3.question, '允许 push 吗？')
  assert.equal(d3.risk, 'high')
  assert.equal(d3.ruleId, 'R1')
  assert.equal(d3.decider, undefined, 'decider is not part of the wire shape')
  const legacyEsc = open.find(entry => entry.runId === 'legacy-run')
  assert.ok(legacyEsc !== undefined, 'legacy run-dir ledger still readable (pre-migration fallback)')
  assert.equal(legacyEsc.entryId, 'D7')
  assert.equal(legacyEsc.checkpoint, '成本')

  // resolution closing the remaining escalation empties the open set (join-derived)
  appendFileSync(ledger, `${JSON.stringify({ entry_id: 'D6', kind: 'resolution', ref_entry: 'D3', decision: 'no' })}\n`)
  const closed = await collectDecisionEntries(rootDir)
  assert.equal(closed.length, 1, 'archive-side resolution closes the escalation')
  assert.equal(closed[0].runId, 'legacy-run', 'the untouched legacy escalation stays open')

  // corrupt-line prefix never throws (degrades to the parseable set)
  writeFileSync(ledger, [
    '{broken',
    JSON.stringify({ entry_id: 'D9', node_id: 'n1', kind: 'escalation', checkpoint: 'c', decision: 'q' }),
  ].join('\n'))
  const degraded = await collectDecisionEntries(rootDir)
  assert.equal(degraded.length, 2)
  assert.deepEqual(degraded.map(entry => entry.entryId).sort(), ['D7', 'D9'])

  rmSync(repoRoot, { recursive: true, force: true })
  console.log('[smoke] collectDecisionEntries (open-escalation join) OK')
}

// --- 2e-bis. shared-archive escalations deliver once (duplicate-callback fix) ----
// The decision ledger is ARCHIVE-level precisely because several runs
// (replan / midrun-derive) can share one archive. Two runs resolving the
// same decisions.jsonl used to each collect the same open escalation under
// different dedupe keys (repo::runA::decision D5 / repo::runB::decision D5)
// and the planner got one notice per RUN. Keyed by the ledger FILE, the
// first run carries the entry and siblings stay silent.
{
  const { collectDecisionEntries } = await import('../lib/goaltrees.js')
  const repoRoot = join(tmpdir(), `rdgt-smoke-shared-arch-${Date.now()}`)
  const rootDir = join(repoRoot, '.rdd', 'goal-trees')
  const archiveDir = join(repoRoot, '.rdd', 'changes', 'archive', 'shared-arch')
  mkdirSync(archiveDir, { recursive: true })
  writeFileSync(join(archiveDir, 'decisions.jsonl'), [
    JSON.stringify({ entry_id: 'D5', node_id: 'n1', task_id: 1, stage: 'CTO', kind: 'escalation', checkpoint: '技术选型', decision: 'A 还是 B？', risk: 'high', rule_id: 'R4', decider: null }),
  ].join('\n'))
  // two bridge runs pointing at the SAME archive
  for (const runId of ['share-run-a', 'share-run-b']) {
    const runDir = join(rootDir, runId, 'state')
    mkdirSync(runDir, { recursive: true })
    writeFileSync(join(rootDir, runId, 'manifest.json'), JSON.stringify({
      run_id: runId, state: 'running', goal: 'shared archive goal', budget: { max_rounds: 2, max_nodes: 6 },
    }))
    writeFileSync(join(rootDir, runId, 'bridge.json'), JSON.stringify({
      run_id: runId, archive: archiveDir, archive_rel: '.rdd/changes/archive/shared-arch',
    }))
  }

  const open = await collectDecisionEntries(rootDir)
  assert.equal(open.length, 1, 'one shared-archive escalation collected exactly once across sibling runs')
  assert.ok(['share-run-a', 'share-run-b'].includes(open[0].runId), 'the first run surfacing the ledger carries the entry')
  assert.equal(open[0].entryId, 'D5')

  rmSync(repoRoot, { recursive: true, force: true })
  console.log('[smoke] collectDecisionEntries (shared-archive once-per-ledger) OK')
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

  // concurrent writers (overlapping scans / a second host on the same repo)
  // must not lose markers: the read-modify-write is serialized per run dir
  // and the commit is write-temp-then-rename. The pre-fix shape — bare
  // read → add → writeFile — deterministically kept only the LAST writer's
  // marker (all reads resolved against the same empty file), and a restart
  // then replayed every lost entry as a duplicate callback.
  const raceRoot = join(tmpdir(), `rdgt-smoke-markers-race-${Date.now()}`)
  const raceDir = join(raceRoot, 'race-run')
  mkdirSync(raceDir, { recursive: true })
  await Promise.all(['ledger L1', 'ledger L2', 'decision D3', 'decision D4'].map(marker => recordDeliveredMarker(raceDir, marker)))
  const raced = await readDeliveredMarkers(raceDir)
  assert.equal(raced.size, 4, 'concurrent marker writes lose nothing (serialized RMW)')
  assert.ok(['ledger L1', 'ledger L2', 'decision D3', 'decision D4'].every(marker => raced.has(marker)))
  assert.deepEqual(readdirSync(raceDir).filter(name => name.startsWith('.callback-delivered.json.tmp-')), [], 'no temp-file residue after atomic replaces')

  rmSync(tmpRoot, { recursive: true, force: true })
  rmSync(raceRoot, { recursive: true, force: true })
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
  // the escalation rides the ARCHIVE-level ledger (planner-midrun-derive): the
  // engine writes it there and bridge.json points at it — reading the run dir
  // instead (QA defect R1) silently drops every escalation notice
  const archiveDir = join(tmpRoot, '.rdd', 'changes', 'archive', 'watch-arch')
  mkdirSync(archiveDir, { recursive: true })
  writeFileSync(join(runDir, 'bridge.json'), JSON.stringify({
    run_id: 'watch-run', archive: archiveDir, archive_rel: '.rdd/changes/archive/watch-arch',
  }))
  writeFileSync(join(archiveDir, 'decisions.jsonl'), `${JSON.stringify({
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

// --- 2g-ter. pending-inbox guard matches markers EXACTLY (missed-callback fix) ---
// The old `text.includes(marker)` substring check matched 'ledger L2' inside
// 'ledger L21': whenever a higher-numbered sibling entry id was queued, the
// shorter id was falsely treated as delivered, marked in the sidecar, and its
// callback silently skipped (the node only resurfaced through the 30-minute
// digest). Exact-token extraction must keep L2 deliverable while L21 —
// genuinely queued — is marked and skipped.
{
  const { PlannerCallbackWatcher } = await import('../lib/watcher.js')
  const { readDeliveredMarkers } = await import('../lib/goaltrees.js')
  const PLUGIN_ID = '@coderrdd/dsh-rdd-goal-tree'
  const tmpRoot = join(tmpdir(), `rdgt-smoke-prefix-${Date.now()}`)
  const runDir = join(tmpRoot, '.rdd', 'goal-trees', 'prefix-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'prefix-run', state: 'running', goal: 'prefix harness goal', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeFileSync(join(stateDir, 'planner.json'), JSON.stringify({
    format_version: 1, run_id: 'prefix-run', dsh_session_id: 'session-planner-p', recorded_at: '2026-01-01T00:00:00Z',
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'prefix-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [{ id: 'n1', parent: null, title: 'root', task: 't', status: 'reported', depends_on: [] }],
  }))
  // two ledger entries: L2 (id is a strict PREFIX of L21) and L21
  const reportLine = (entryId, node) => JSON.stringify({
    entry_id: entryId, node_id: node, worker: 'DEV', reported_at: '2026-01-01T00:20:00Z', callback: {
      verdict: 'done', confidence: 0.9, summary: `report ${entryId}`, full_report: `report/${node}.md`, citations: [],
    },
  })
  writeFileSync(join(stateDir, 'ledger.jsonl'), `${reportLine('L2', 'n1')}\n${reportLine('L21', 'n1')}\n`)

  const sends = []
  let seq = 0
  const stubFactory = input => ({ id: `m-${++seq}`, role: 'user', content: input.content, source: input.source })
  const fakeAgent = {
    inbox: {
      nextTurn: [
        // a previous plugin life queued the L21 notice; its text naturally
        // contains '(ledger L21).' — under substring matching this ALSO
        // satisfied the pending marker 'ledger L2' (the silent skip)
        { source: { kind: 'plugin', plugin: PLUGIN_ID }, content: [{ type: 'text', text: 'run "prefix-run" · node n1 reported by DEV — verdict=done (ledger L21).' }] },
      ],
      nextStep: [],
    },
    send: (message, target, wakeup) => { sends.push({ message, target, wakeup }) },
  }
  const ctx = {
    logger: { info: () => {}, warn: () => {} },
    agents: { get: sid => (sid === 'session-planner-p' ? fakeAgent : undefined) },
  }

  const watcher = new PlannerCallbackWatcher(ctx, true, 0, stubFactory)
  await watcher.scanRoot(tmpRoot)

  assert.equal(sends.length, 1, 'L2 is delivered — the queued L21 notice no longer satisfies it (exact-token match)')
  const sentText = sends[0].message.content.map(block => block.text).join('\n')
  assert.ok(sentText.includes('(ledger L2)'), 'the delivered notice is L2 itself')
  const markers = await readDeliveredMarkers(runDir)
  assert.ok(markers.has('ledger L2') && markers.has('ledger L21'), 'both markers persisted (one sent, one marked-and-skipped)')

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] watcher pending guard (exact-token marker match) OK')
}

// --- 2g-bis. digest backstop arm (planner-reconcile-throttle) -------------------
// The timed arm crosses a 30-minute boundary, collects every active tree's
// reported-but-unsettled nodes into ONE wakeful digest per planner, and ONLY
// through the dual quiet predicate (status 'idle' AND no session event within
// 30 min). The instant arms are untouched (scanRoot's second arg defaults
// false); a digest is a state reminder, never a durable exactly-once event.
{
  const { PlannerCallbackWatcher } = await import('../lib/watcher.js')
  const PLUGIN_ID = '@coderrdd/dsh-rdd-goal-tree'
  const tmpRoot = join(tmpdir(), `rdgt-smoke-digest-${Date.now()}`)
  const runDir = join(tmpRoot, '.rdd', 'goal-trees', 'digest-run')
  const stateDir = join(runDir, 'state')
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    run_id: 'digest-run', state: 'running', goal: 'digest harness goal', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeFileSync(join(stateDir, 'planner.json'), JSON.stringify({
    format_version: 1, run_id: 'digest-run', dsh_session_id: 'session-planner-d', recorded_at: '2026-01-01T00:00:00Z',
  }))
  // two reported nodes (the pending backstop payload) + one claimed (must NOT
  // appear: workers stuck on a question/permission are still claimed, and a
  // claimed worker never enters the digest collection)
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'digest-run', updated_at: '2026-01-01T00:10:00Z',
    nodes: [
      { id: 'n1', parent: null, title: 'root', task: 't', status: 'pending', depends_on: [] },
      { id: 'n2', parent: 'n1', title: 'a', task: 't', status: 'reported', depends_on: [], claimed_by: 'DEV', last_verdict: 'done', last_confidence: 0.9 },
      { id: 'n3', parent: 'n1', title: 'b', task: 't', status: 'reported', depends_on: [], claimed_by: 'QA', last_verdict: 'redo', last_confidence: 0.4 },
      { id: 'n4', parent: 'n1', title: 'c', task: 't', status: 'claimed', depends_on: [], claimed_by: 'CTO' },
    ],
  }))
  writeFileSync(join(stateDir, 'ledger.jsonl'), '')

  const sends = []
  let seq = 0
  const stubFactory = input => ({ id: `m-${++seq}`, role: 'user', content: input.content, source: input.source })
  const quietAgent = () => ({
    inbox: { nextTurn: [], nextStep: [] },
    send: (message, target, wakeup) => { sends.push({ message, target, wakeup }) },
    status: 'idle',
    session: { events: [{ time: Date.now() - 31 * 60_000 }] }, // long quiet
  })
  const ctx = {
    logger: { info: () => {}, warn: () => {} },
    agents: { get: sid => (sid === 'session-planner-d' ? fake : undefined) },
  }
  let fake = quietAgent()

  // positive: boundary due + idle + quiet -> one wakeful digest carrying the list
  const watcher = new PlannerCallbackWatcher(ctx, true, 0, stubFactory)
  await watcher.scanRoot(tmpRoot, true)
  assert.equal(sends.length, 1, 'digest delivered once (instant arms empty: no ledger entries)')
  const digest = sends[0]
  assert.ok(digest.target === 'next-turn' && digest.wakeup === true, 'digest rides the same wakeful send path')
  const text = digest.message.content.map(block => block.text).join('\n')
  assert.ok(text.includes('2 个节点已回调待裁决'), 'digest states the pending count')
  assert.ok(text.includes('n2 by DEV (verdict=done, conf 0.9)') && text.includes('n3 by QA (verdict=redo, conf 0.4)'), 'digest lists each reported node with owner+verdict')
  assert.ok(!text.includes('n4'), 'claimed nodes never enter the digest (question/permission-stuck workers are still claimed)')
  assert.ok(text.includes('无需全局 status 对账'), 'digest retires the global reconcile sweep')

  // negative 1: planner mid-turn (held on a question/permission) -> no digest
  sends.length = 0
  fake = quietAgent(); fake.status = 'running'
  await watcher.scanRoot(tmpRoot, true)
  assert.equal(sends.length, 0, 'running planner is never interrupted by the backstop')

  // negative 2: planner active within the quiet window -> no digest
  sends.length = 0
  fake = quietAgent(); fake.session.events = [{ time: Date.now() - 5 * 60_000 }]
  await watcher.scanRoot(tmpRoot, true)
  assert.equal(sends.length, 0, 'recently active planner is left alone')

  // negative 3: boundary not due (scanRoot default) -> no digest even when idle+quiet
  sends.length = 0
  fake = quietAgent()
  await watcher.scanRoot(tmpRoot)
  assert.equal(sends.length, 0, 'no boundary crossing, no backstop')

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] digest backstop arm (dual quiet predicate, claimed exclusion, no-sweep action line) OK')
}

// --- 2i. plugin-perf L2/L3: liveness shortcut + wire projection ----------------
// The node-keyed liveness route now reads state/claims/<node>.json directly
// (no full aggregation); the /runs default payload ships slim summaries and
// reserves full node detail for claim-carrying runs (or the ?run form). The
// two contracts pinned here: (a) the shortcut answers exactly what the old
// aggregate-join answered for every miss shape, and agrees with it on hits;
// (b) slim runs keep every census field the client renders (view gating +
// tree list) and drop only the heavy per-node fields.
{
  const { readClaimSession, projectRunView } = await import('../lib/goaltrees.js')
  const tmpRoot = join(tmpdir(), `rdgt-smoke-liv-${Date.now()}`)
  const stateDir = join(tmpRoot, 'live-run', 'state')
  const claimsDir = join(stateDir, 'claims')
  mkdirSync(claimsDir, { recursive: true })
  writeFileSync(join(tmpRoot, 'live-run', 'manifest.json'), JSON.stringify({
    run_id: 'live-run', state: 'running', goal: 'g', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'live-run', updated_at: '2026-01-01T00:00:00Z',
    nodes: [
      {
        id: 'n1', parent: null, title: 'bridge root', status: 'pending', depends_on: [],
        task: '目标：完成「演示」的 DEV 阶段（编码实现）。需求文档：requirements/a.md；归档：demo-arch。',
      },
      { id: 'n2', parent: 'n1', title: 'leaf', task: 'leaf task', status: 'claimed', claimed_by: 'DEV', depends_on: [] },
    ],
  }))
  writeFileSync(join(claimsDir, 'n2.json'), JSON.stringify({
    format_version: 1, node_id: 'n2', dsh_session_id: 'session-live-2',
  }))
  writeFileSync(join(claimsDir, 'nX.json'), '{broken json')

  // shortcut: hit → the sidecar's session id (parity with the aggregate join)
  assert.equal(await readClaimSession(tmpRoot, 'live-run', 'n2'), 'session-live-2')
  // every miss shape → null (the route's "unknown"), never an error
  assert.equal(await readClaimSession(tmpRoot, 'live-run', 'n1'), null, 'unclaimed node')
  assert.equal(await readClaimSession(tmpRoot, 'live-run', 'nX'), null, 'corrupt sidecar')
  assert.equal(await readClaimSession(tmpRoot, 'no-such-run', 'n1'), null, 'missing run')
  // the join keys by CONTENT node_id — a sidecar whose content disagrees
  // with its filename (or the queried node) yields no binding
  writeFileSync(join(claimsDir, 'n3.json'), JSON.stringify({ node_id: 'other', dsh_session_id: 'session-x' }))
  assert.equal(await readClaimSession(tmpRoot, 'live-run', 'n3'), null, 'content/filename mismatch → null')
  // join parity: the aggregate's claimSessionId for n2 is the same binding
  const { runs } = await aggregateGoalTrees(tmpRoot)
  assert.equal(runs.length, 1)
  assert.equal(runs[0].nodes.find(n => n.id === 'n2')?.claimSessionId, 'session-live-2')

  // wire projection: the claim-carrying run ships FULL (a worker session
  // renders it — task text + doc rows must be present), detail marker set
  const full = projectRunView(runs[0])
  assert.equal(full.detail, true, 'run with a dsh-bound claim ships full')
  const fullN1 = full.nodes.find(n => n.id === 'n1')
  assert.ok(fullN1.docs !== null && fullN1.docs !== undefined, 'full payload keeps doc rows')
  assert.equal(fullN1.docs.goal, '完成「演示」的 DEV 阶段（编码实现）。')
  assert.equal(fullN1.task !== null && fullN1.task !== undefined, true, 'full payload keeps the task text')

  // explicit detail=false → slim regardless of claims (the shape is a choice)
  const slim = projectRunView(runs[0], false)
  assert.equal(slim.detail, false, 'explicit detail=false wins')
  // run-level scalars survive the slim projection verbatim
  assert.equal(slim.runId, 'live-run')
  assert.equal(slim.state, 'running')
  assert.deepEqual(slim.counts, { pending: 1, claimed: 1, reported: 0, done: 0, pruned: 0 })
  assert.equal(slim.plannerSessionId, null)
  // slim nodes carry EXACTLY the census fields (view gating needs
  // claimSessionId; the tree list needs id/title/status/owner/depth/blockedBy;
  // wake-model badge needs wakeCount/wakeMax/duty; wake-rotation adds the
  // light joins segment/wakeTotal/lineage — report stays detail-only)
  const slimN2 = slim.nodes.find(n => n.id === 'n2')
  assert.deepEqual(Object.keys(slimN2).sort(),
    ['blockedBy', 'claimSessionId', 'claimedBy', 'depth', 'duty', 'id', 'lineage', 'parent', 'segment', 'status', 'title', 'type', 'wakeCount', 'wakeMax', 'wakeTotal'])
  assert.equal(slimN2.claimSessionId, 'session-live-2', 'claimSessionId kept on slim nodes (view gating)')
  assert.equal(slimN2.claimedBy, 'DEV', 'owner kept for the tree list')
  const slimN1 = slim.nodes.find(n => n.id === 'n1')
  assert.equal(slimN1.task, undefined, 'task text dropped on slim')
  assert.equal(slimN1.docs, undefined, 'doc rows dropped on slim')
  // claimless DEFAULT: the summary rule (what /runs serves for idle runs)
  const claimless = runs[0].nodes.map(n => ({ ...n, claimSessionId: null }))
  assert.equal(projectRunView({ ...runs[0], nodes: claimless }).detail, false, 'claimless run defaults to slim')
  // the projection is pure: the aggregated input keeps its full nodes
  assert.ok(runs[0].nodes.find(n => n.id === 'n1').docs !== null, 'input run not mutated by projection')

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] liveness shortcut (readClaimSession) + wire projection (slim/full) OK')
}

// --- 2j. plugin-perf L2: per-run aggregation cache ------------------------------
// Three invariants: (1) a rewrite landing INSIDE the TTL floor is served
// stale by design (debounce — the object is reference-identical, zero
// re-reads); (2) past the floor, a changed state file (tree.json) breaks
// the mtime fingerprint and re-aggregates; (3) an UNCHANGED fingerprint
// reuses the cached view object verbatim (reference-equal — no re-read).
{
  const { setRunCacheTtlForTests } = await import('../lib/goaltrees.js')
  const tmpRoot = join(tmpdir(), `rdgt-smoke-cache-${Date.now()}`)
  const stateDir = join(tmpRoot, 'cache-run', 'state')
  mkdirSync(stateDir, { recursive: true })
  const writeTree = extra => writeFileSync(join(stateDir, 'tree.json'), JSON.stringify({
    format_version: 1, run_id: 'cache-run', updated_at: '2026-01-01T00:00:00Z',
    nodes: [
      { id: 'n1', parent: null, title: 'root', task: 't', status: 'pending', depends_on: [] },
      ...(extra ?? []),
    ],
  }))
  writeFileSync(join(tmpRoot, 'cache-run', 'manifest.json'), JSON.stringify({
    run_id: 'cache-run', state: 'running', goal: 'g', budget: { max_rounds: 2, max_nodes: 6 },
  }))
  writeTree()

  const first = await aggregateGoalTrees(tmpRoot)
  assert.equal(first.runs[0].nodes.length, 1)

  // (1) TTL debounce: the rewrite below lands inside the 2s floor → the
  // cached view is served as-is (same object, stale node count)
  writeTree([{ id: 'n2', parent: 'n1', title: 'leaf', task: 't2', status: 'pending', depends_on: [] }])
  const debounced = await aggregateGoalTrees(tmpRoot)
  assert.equal(debounced.runs[0].nodes.length, 1, 'inside the TTL floor: debounced snapshot')
  assert.ok(debounced.runs[0] === first.runs[0], 'TTL reuse returns the reference-identical cached view')

  // (2) fingerprint invalidation: past the floor (ttl → 0 forces a re-stat),
  // the changed tree.json breaks the fingerprint and re-aggregates
  setRunCacheTtlForTests(0)
  const fresh = await aggregateGoalTrees(tmpRoot)
  assert.equal(fresh.runs[0].nodes.length, 2, 'changed tree.json re-aggregates past the floor')
  assert.ok(fresh.runs[0] !== first.runs[0], 'invalidation built a fresh view object')

  // (3) unchanged fingerprint: reference-stable reuse, no re-read
  const again = await aggregateGoalTrees(tmpRoot)
  assert.ok(again.runs[0] === fresh.runs[0], 'unchanged fingerprint reuses the cached view object')
  setRunCacheTtlForTests(2000)

  rmSync(tmpRoot, { recursive: true, force: true })
  console.log('[smoke] per-run aggregation cache (TTL debounce + fingerprint invalidation + stable reuse) OK')
}

// --- 3. engine regression: sidecars on the real CLI ---------------------------
// Runs the patched engine scripts in a temp fixture. Skipped when the ambient
// sandbox forbids spawning a capturing subprocess (EPERM on piped stdio) — the
// same regression then runs from the harness shell instead.
{
  let cliAllowed = true
  try {
    // repo root from THIS FILE's location (tests/ -> plugin dir -> checkout
    // root), never process.cwd() — the harness runs smoke from varying cwds
    // and a cwd-relative 'rdd-engine' silently resolves to a nonexistent path
    // under the plugin dir (previously masked by the EPERM skip).
    const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
    const engineScripts = join(repoRoot, 'rdd-engine', 'scripts')
    if (!existsSync(join(engineScripts, 'goal-tree.ps1'))) {
      console.log('[smoke] engine sidecar regression SKIPPED (no rdd-engine checkout alongside the plugin) — run from the harness shell')
    } else {
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
    }
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
  // the shipped renderer guard: the outline must derive nesting from parent
  // links, not from the wire order (the n8-under-n7 panel regression)
  assert.equal(typeof face.orderOutlineNodes, 'function', 'exports.orderOutlineNodes')
  const graftOrderList = [
    { id: 'n1', parent: null },
    { id: 'n2', parent: 'n1' },
    { id: 'n3', parent: 'n1' },
    { id: 'n4', parent: 'n1' },
    { id: 'n5', parent: 'n1' },
    { id: 'n6', parent: 'n1' },
    { id: 'n7', parent: 'n1' },
    { id: 'n8', parent: 'n2' },
    { id: 'n9', parent: 'n8' },
  ]
  assert.deepEqual(
    face.orderOutlineNodes(graftOrderList).map(node => node.id),
    ['n1', 'n2', 'n8', 'n9', 'n3', 'n4', 'n5', 'n6', 'n7'],
    'client outline order is DFS pre-order regardless of wire order',
  )
  // the dock routes through the gating table, and the picker ships inlined in
  // the bundle (its relative require intercepted — no non-baseline require)
  assert.ok(src.includes('pickGoalTreeView'), 'bundle carries the gating table call')
  assert.ok(src.includes('./view-picker.js'), 'bundle intercepts the picker require')
  console.log('[smoke] client bundle factory + plugin face OK')
}

console.log('[smoke] all green')

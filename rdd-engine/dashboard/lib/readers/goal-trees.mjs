// Reader: delivery trees (.rdd/goal-trees/** + goal-trees-archive/**).
//
// Only the lightweight tree files are read (manifest.json, state/tree.json,
// state/round-log.jsonl) — report/ and state/claims/ hold per-node payloads
// that would make aggregation scale with the number of nodes, not the number
// of trees. Directories without a manifest or tree state are not trees and are
// reported as skipped; fixture directories are excluded and counted so the UI
// can state the exclusion explicitly.
import { join } from 'node:path'

import { countExcludedDirs, listDirs, listEntries, makeEnvelope, readJson, readText } from '../io.mjs'

const DOMAIN = 'goal-trees'
const SOURCE = '.rdd/goal-trees/** + .rdd/goal-trees-archive/**'
const ROOTS = [
  { key: 'goal-trees', label: '活跃', archive: false },
  { key: 'goal-trees-archive', label: '已归档', archive: true },
]

const GOAL_TEXT_LIMIT = 160

/** Count lines of a JSONL file (round log) without parsing each record. */
function countLines(absolutePath) {
  const { text } = readText(absolutePath)
  if (text === null) return 0
  return text.split('\n').filter((line) => line.trim() !== '').length
}

/** Derive node status counts from state/tree.json. */
function summarizeNodes(treeJson) {
  const nodes = Array.isArray(treeJson?.nodes) ? treeJson.nodes : []
  const byStatus = new Map()
  for (const node of nodes) {
    const status = String(node?.status ?? 'unknown')
    byStatus.set(status, (byStatus.get(status) ?? 0) + 1)
  }
  return {
    nodeCount: nodes.length,
    doneNodes: byStatus.get('done') ?? 0,
    byStatus: [...byStatus.entries()].map(([status, count]) => ({ status, count })),
  }
}

/** Read one candidate tree directory, or null when it is not a tree. */
function readTree(dir, archive) {
  const manifest = readJson(join(dir.path, 'manifest.json'))
  const tree = readJson(join(dir.path, 'state', 'tree.json'))
  const isTree = manifest.value !== null || tree.value !== null
  if (!isTree) return null
  const nodes = summarizeNodes(tree.value)
  const rounds = countLines(join(dir.path, 'state', 'round-log.jsonl'))
  const goal = String(tree.value?.goal ?? manifest.value?.goal ?? '')
  return {
    runId: String(manifest.value?.run_id ?? tree.value?.run_id ?? dir.name),
    dir: dir.name,
    archive,
    state: String(manifest.value?.state ?? (archive ? 'archived' : 'unknown')),
    createdAt: String(manifest.value?.created_at ?? ''),
    updatedAt: String(tree.value?.updated_at ?? manifest.value?.created_at ?? ''),
    goal: goal.length > GOAL_TEXT_LIMIT ? `${goal.slice(0, GOAL_TEXT_LIMIT)}…` : goal,
    ...nodes,
    rounds,
  }
}

/** Enumerate one root, splitting real / excluded / non-tree directories. */
function readRoot(context, root, notes) {
  const absolute = join(context.rddRoot, root.key)
  const dirs = listEntries(absolute).filter(
    (entry) => entry.isDirectory() && entry.name !== '_inputs'
  )
  const deliverNamed = dirs.filter((entry) => entry.name.startsWith('deliver-')).length
  const excludedCount = countExcludedDirs(absolute)
  const trees = []
  let skipped = 0
  for (const dir of listDirs(absolute)) {
    const tree = readTree(dir, root.archive)
    if (tree === null) {
      skipped += 1
      continue
    }
    trees.push(tree)
  }
  if (skipped > 0) notes.push(`${root.key}/ 下 ${skipped} 个目录不是交付树（缺 manifest/tree.json），未计入。`)
  return { trees, excludedCount, deliverNamed, dirCount: dirs.length }
}

/**
 * Aggregate the delivery-tree domain.
 * @param {{rddRoot: string}} context
 */
export function readGoalTrees(context) {
  const notes = []
  const env = makeEnvelope(DOMAIN, SOURCE)
  const trees = []
  let excludedCount = 0
  let deliverNamedCount = 0
  let rootCount = 0
  for (const root of ROOTS) {
    const result = readRoot(context, root, notes)
    trees.push(...result.trees)
    excludedCount += result.excludedCount
    deliverNamedCount += result.deliverNamed
    rootCount += result.dirCount
  }
  const states = new Map()
  for (const tree of trees) states.set(tree.state, (states.get(tree.state) ?? 0) + 1)
  if (excludedCount > 0) {
    // Deliberately does not repeat the fixture name patterns: naming one would
    // put fixture vocabulary on a rendered note surface (§6.8 invariant).
    notes.push(`已排除 ${excludedCount} 个测试夹具目录（按排除规则不计入统计）。`)
  }
  env.available = trees.length > 0
  env.meta.notes = env.meta.notes.concat(notes)
  env.data = {
    totalCount: trees.length,
    activeRootCount: trees.filter((tree) => !tree.archive).length,
    archivedRootCount: trees.filter((tree) => tree.archive).length,
    excludedCount,
    deliverNamedCount,
    dirCount: rootCount,
    nodeCount: trees.reduce((sum, tree) => sum + tree.nodeCount, 0),
    roundTotal: trees.reduce((sum, tree) => sum + tree.rounds, 0),
    roundMax: trees.reduce((max, tree) => Math.max(max, tree.rounds), 0),
    states: [...states.entries()].map(([state, count]) => ({ state, count })),
    trees: trees.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)),
  }
  return env
}

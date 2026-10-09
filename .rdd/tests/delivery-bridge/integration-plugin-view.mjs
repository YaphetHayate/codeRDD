#!/usr/bin/env node
/**
 * DEV 集成/联调探针（跨组件只读驱动器）— 插件产物视角的 run 视图 + 未决升级集合
 *
 * 用法：node integration-plugin-view.mjs <repoRoot> [runId]
 *
 * 职责：把**插件产物**（dsh/rdd-goal-tree/lib/goaltrees.js）指向给定仓的
 * `.rdd/goal-trees` 根，回吐
 *   - open：collectDecisionEntries 的结果（watcher 视角的未决升级条目集）
 *   - run ：aggregateGoalTrees 里该 runId 的投影（state/counts/nodes 精简形）
 * stdout 单行 JSON 信封；退出码 0 = 读成功 / 1 = 读失败 / 2 = 参数缺失。
 *
 * 分工（沙箱纪律）：PS 探针驱动真引擎写盘（engine CLI），本驱动器只读 FS——
 * 写端与读端在同一 run 上对拍，正是「账本搬到归档根、消费方未同步 → 升级
 * 投递静默断链」这类跨组件失效面的判别形态。
 */
import { join } from 'node:path'

const repoRoot = process.argv[2]
const runId = process.argv[3] ?? null
if (!repoRoot) {
  process.stderr.write('usage: node integration-plugin-view.mjs <repoRoot> [runId]\n')
  process.exit(2)
}

const LIB_URL = new URL('../../../dsh/rdd-goal-tree/lib/goaltrees.js', import.meta.url)

try {
  const lib = await import(LIB_URL.href)
  const rootDir = join(repoRoot, '.rdd', 'goal-trees')
  const open = await lib.collectDecisionEntries(rootDir)
  let run = null
  if (runId) {
    const agg = await lib.aggregateGoalTrees(rootDir)
    const hit = agg.runs.find(r => r.runId === runId)
    if (hit) {
      run = {
        runId: hit.runId,
        state: hit.state,
        goal: hit.goal,
        counts: hit.counts,
        maxNodes: hit.maxNodes,
        nodes: hit.nodes.map(n => ({ id: n.id, status: n.status, title: n.title, type: n.type })),
      }
    }
  }
  process.stdout.write(`${JSON.stringify({ success: true, count: open.length, open, run })}\n`)
  process.exit(0)
} catch (err) {
  process.stdout.write(`${JSON.stringify({ success: false, error: String(err && err.message ? err.message : err) })}\n`)
  process.exit(1)
}

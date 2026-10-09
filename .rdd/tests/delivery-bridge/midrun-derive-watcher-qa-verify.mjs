#!/usr/bin/env node
/**
 * QA 独立探针（辅助驱动器）— planner midrun derive / QA 缺陷 R1 的跨组件锚
 *
 * 用法：node midrun-derive-watcher-qa-verify.mjs <repoRoot>
 *   <repoRoot> 为一次性夹具仓（内含 .rdd/goal-trees/ 与 .rdd/changes/archive/）。
 *
 * 职责只有一件事：把**插件产物**（dsh/rdd-goal-tree/lib/goaltrees.js，
 * collectDecisionEntries）指向该仓的 goal-trees 根，回吐 watcher 视角的
 * 「未决升级条目」集合（stdout 单行 JSON）。引擎侧的账本由 PS 探针用真实
 * CLI（escalate / decide）写入——写端与读端在同一 run 上对拍，正是 R1
 * （账本搬到归档根、watcher 仍读 run 目录 → 升级投递静默断链）的失效面。
 *
 * 独立于 DEV 侧 smoke.mjs：后者用手工播种的 lib 级夹具（不驱动引擎写入），
 * 本驱动器不构造账本、不复制其断言，只消费真引擎写下的那份账本。
 * 退出码：0 = 读成功（stdout JSON 信封）；1 = 读失败；2 = 参数缺失。
 */
import { join } from 'node:path'

const repoRoot = process.argv[2]
if (!repoRoot) {
  process.stderr.write('usage: node midrun-derive-watcher-qa-verify.mjs <repoRoot>\n')
  process.exit(2)
}

const LIB_URL = new URL('../../../dsh/rdd-goal-tree/lib/goaltrees.js', import.meta.url)

try {
  const { collectDecisionEntries } = await import(LIB_URL.href)
  const open = await collectDecisionEntries(join(repoRoot, '.rdd', 'goal-trees'))
  process.stdout.write(`${JSON.stringify({ success: true, count: open.length, open })}\n`)
  process.exit(0)
} catch (err) {
  process.stdout.write(`${JSON.stringify({ success: false, error: String(err && err.message ? err.message : err) })}\n`)
  process.exit(1)
}

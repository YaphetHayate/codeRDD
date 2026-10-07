#!/usr/bin/env node
/**
 * 更新后一键本地构建（post-update local build）。
 *
 * 场景：源仓 `git pull`（或任意源码变更）之后，一条命令完成本地全量构建——
 *       coderdd CLI、三组件分发 tarball 与跟踪态 preset 生成物全部新鲜：
 *
 *   node scripts/build-local.mjs                  # 全链
 *   npm run build:local                           # 等价别名
 *   node scripts/build-local.mjs --commit         # preset 产物漂移时自动提交
 *   node scripts/build-local.mjs --with-goal-tree # 附加 goal-tree 插件 tarball
 *
 * 管线（fail-fast，任一步失败即停，退出码 1）：
 *   0. preflight：node >= 18、git 仓在位
 *   1. npm install           依赖刷新（幂等；--no-audit --no-fund 静默）
 *   2. npm run build         tsc → dist/（coderdd CLI 本体，目标项目
 *                            `coderdd update .` 依赖它）
 *   3. build-release.mjs     三组件：engine + dsh-rdd-explore 插件 + skills
 *                            （内部先跑 build-dsh-presets.mjs 保证 preset
 *                            生成物新鲜；汇聚 dist/release/ 固定名+版本名
 *                            6 tarball + SHA256SUMS + release-notes 模板）
 *   4. --with-goal-tree      附加 build-dsh-goal-tree.mjs（独立分发，不在
 *                            release 三组件内，默认跳过）
 *   5. preset 产物卫生       dsh/presets/ 为跟踪态生成物——构建后若与 HEAD
 *                            漂移：默认 WARN + 给出建议提交命令（改卡忘重建
 *                            = 交付 F3 类缺陷的根因）；--commit 时仅对该路径
 *                            git add + 提交，绝不触碰其他工作区改动
 *
 * 环境约束（DSH 沙箱）：node 子进程禁止管道 stdio（EPERM），子进程经 shell 以
 * stdio:inherit 运行（与 build-release.mjs 同约定）；git 输出捕获非 node 子进程，不受限。
 * 零依赖：node:child_process / node:fs / node:path / node:process / node:url。
 * @module coderrdd/build-local
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const args = new Set(process.argv.slice(2))
const autoCommit = args.has('--commit') || args.has('-Commit')
const withGoalTree = args.has('--with-goal-tree') || args.has('-WithGoalTree')

const fail = msg => { console.error(`✗ ${msg}`); process.exit(1) }

/** 与 build-release.mjs 同约定：子进程经 shell、stdio:inherit（沙箱 EPERM 规避）。 */
function run(cmd, label) {
  console.log(`--- ${label}: ${cmd}`)
  const t0 = Date.now()
  try {
    execFileSync(cmd, { cwd: repoRoot, stdio: 'inherit', shell: true })
  } catch (err) {
    fail(`步骤失败: ${label}（${err.message}）——修复后重跑本脚本（各步幂等）`)
  }
  return Date.now() - t0
}

/** 捕获型 git 查询：管道 stdio 在 DSH 沙箱 EPERM——经临时文件重定向捕获。 */
function gitOut(gitArgs) {
  const tmp = join(tmpdir(), `build-local-git-${process.pid}-${Date.now()}.tmp`)
  execFileSync(`git ${gitArgs} > "${tmp}"`, { cwd: repoRoot, stdio: 'ignore', shell: true })
  const out = existsSync(tmp) ? readFileSync(tmp, 'utf8').trim() : ''
  try { rmSync(tmp, { force: true }) } catch { /* best-effort */ }
  return out
}

// ---------------------------------------------------------------------------
// 0. preflight
// ---------------------------------------------------------------------------
const startedAt = Date.now()
const [major] = process.versions.node.split('.').map(Number)
if (major < 18) fail(`node >= 18 required, got ${process.versions.node}`)
if (!existsSync(join(repoRoot, 'package.json'))) fail('必须在 codeRDD 仓内运行（未找到 package.json）')

console.log(`build-local @ ${repoRoot}`)
console.log(`node ${process.versions.node}${autoCommit ? ' | --commit' : ''}${withGoalTree ? ' | --with-goal-tree' : ''}`)

// ---------------------------------------------------------------------------
// 1-3. 依赖 → CLI → 三组件发布产物
// ---------------------------------------------------------------------------
const steps = []
steps.push(['deps', run('npm install --no-audit --no-fund', 'npm install')])
steps.push(['cli', run('npm run build', 'tsc (coderdd CLI)')])
steps.push(['release', run('node scripts/build-release.mjs', 'release components (engine + plugin + skills)')])
if (withGoalTree) steps.push(['goal-tree', run('node scripts/build-dsh-goal-tree.mjs', 'goal-tree plugin')])

// ---------------------------------------------------------------------------
// 5. preset 产物卫生（F3 防复发）：dsh/presets/ 跟踪态生成物漂移检查
// ---------------------------------------------------------------------------
const drift = gitOut('status --porcelain -- dsh/presets/')
if (drift) {
  const changed = drift.split(/\r?\n/).map(l => l.slice(3).trim())
  if (autoCommit) {
    run('git add -- dsh/presets', 'git add (dsh/presets only)')
    run(`git commit -m "chore: rebuild generated preset artifacts (post-update build)" -o -- dsh/presets`,
      'git commit (preset artifacts only)')
    console.log(`✓ preset 生成物漂移已提交: ${changed.length} 个文件`)
  } else {
    console.warn(`⚠ dsh/presets/ 生成物与 HEAD 漂移（${changed.length} 个文件，改卡未重建的 F3 类风险）:`)
    for (const f of changed) console.warn(`    ${f}`)
    console.warn(`  提交建议: git add -- dsh/presets && git commit -m "chore: rebuild generated preset artifacts" -- dsh/presets`)
    console.warn(`  或重跑本脚本加 --commit 自动处理（仅触及该路径）`)
  }
} else {
  console.log('✓ preset 生成物与 HEAD 一致（无漂移）')
}

// ---------------------------------------------------------------------------
// summary
// ---------------------------------------------------------------------------
console.log('')
console.log('=== build-local 完成 ===')
for (const [name, ms] of steps) console.log(`  ${name.padEnd(10)} ${(ms / 1000).toFixed(1)}s`)
console.log(`  total      ${((Date.now() - startedAt) / 1000).toFixed(1)}s`)
console.log('产物: dist/（coderdd CLI）+ dist/release/（三组件 tarball + SHA256SUMS + notes）')
console.log('后续: 目标项目 coderdd update . / 目标机器 install-rdd.ps1；发布 gh release create 见 build-release.mjs 头注')

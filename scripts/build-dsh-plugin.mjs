#!/usr/bin/env node
/**
 * 构建 @coderrdd/dsh-rdd-explore 独立分发包（rdd-explore-plugin 需求 1）。
 *
 * 管线（真相源 = codeRDD dsh/dsh-rdd-explore/，git 追踪）：
 *   1. 同步 vendored guide：rdd-engine/references/exploration-guide.md
 *      → dsh/dsh-rdd-explore/assets/rdd-engine/references/exploration-guide.md
 *   2. DSH workspace 集成（packages/local/rdd-explore）：
 *      junction 优先（反向 junction 指向真相源），junction 不可用时退化为
 *      目录同步（构建输入拷入 DSH 侧，构建后 lib/ 拷回）
 *   3. pnpm --filter @coderrdd/dsh-rdd-explore build（DSH checkout 内）
 *   4. npm pack（真相源目录，预构建 lib/ 进包）→ 双产物：
 *        dist/plugin/dsh-rdd-explore.tgz               # 固定名（Release latest 直链）
 *        dist/plugin/dsh-rdd-explore-<version>.tgz     # 带版本名归档
 *
 * 校验：
 *   C1 vendored guide 与 rdd-engine 真相源逐字节一致（漂移即失败）
 *   C2 tarball 文件名与 package.json name/version 推导一致
 *   C3 包内契约成员：package.json + cordis.patch.yml + lib/index.js +
 *      assets/rdd-engine/references/exploration-guide.md
 *   C4 包内条目全部位于 package/ 前缀下
 *
 * --check（CI）：只跑 C1 + manifest 不变量（dsh.bundle 声明 / peers 规格 /
 *   files 清单 / patch 行），不集成 workspace、不构建、不落盘。
 *
 * 环境约束（DSH 沙箱）：node 子进程禁止管道 stdio（EPERM），故 pnpm/npm 经
 * shell 以 stdio:inherit 运行，产物名从输出目录发现（不捕获 stdout）。
 *
 * DSH checkout 定位（依序）：环境变量 RDD_DSH_CHECKOUT → codeRDD 仓的
 * ../dsh/deepseek-harness（兄弟布局）。均未命中且 packages/local 集成点缺失
 * 时 fail-loud 并给出设置指引。
 *
 * 用法:
 *   node scripts/build-dsh-plugin.mjs            # 全管线 → dist/plugin/
 *   node scripts/build-dsh-plugin.mjs --check    # CI 一致性校验
 * 零依赖：node:fs / node:path / node:child_process / node:os / node:zlib。
 * @module coderrdd/build-dsh-plugin
 */

import { execFileSync } from 'node:child_process'
import {
  copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync,
  readFileSync, readdirSync, readlinkSync, rmSync, statSync, symlinkSync, rmdirSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { gunzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const pluginDir = join(repoRoot, 'dsh', 'dsh-rdd-explore')
const outDir = join(repoRoot, 'dist', 'plugin')
const checkMode = process.argv.includes('--check')

const toPosix = p => p.split('\\').join('/')
const fail = msg => { console.error(`✗ ${msg}`); process.exit(1) }

/** 构建输入（同步兜底模式下拷入 DSH 侧的文件/目录；node_modules/lib/tests 不拷）。 */
const BUILD_INPUTS = ['package.json', 'tsconfig.json', 'assets', 'src', 'cordis.patch.yml']

// --- manifest（真相源） ---
const pkgPath = join(pluginDir, 'package.json')
if (!existsSync(pkgPath)) fail('dsh/dsh-rdd-explore/package.json not found — 插件真相源缺失')
const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
if (pkg.name !== '@coderrdd/dsh-rdd-explore') fail(`unexpected package name: ${pkg.name}`)
const expectedTarName = pkg.name.replace(/^@/, '').replace('/', '-') + `-${pkg.version}.tgz`

const guideSrc = join(repoRoot, 'rdd-engine', 'references', 'exploration-guide.md')
const guideDst = join(pluginDir, 'assets', 'rdd-engine', 'references', 'exploration-guide.md')
const patchPath = join(pluginDir, 'cordis.patch.yml')

// ---------------------------------------------------------------------------
// C1 vendored guide 同步（普通模式）/ 漂移校验（CI 模式）
// ---------------------------------------------------------------------------
if (!existsSync(guideSrc)) fail(`rdd-engine guide not found: ${guideSrc}`)
if (checkMode) {
  if (!existsSync(guideDst)) fail(`vendored guide missing: ${guideDst}（运行 node scripts/build-dsh-plugin.mjs 同步）`)
  if (!readFileSync(guideSrc).equals(readFileSync(guideDst))) {
    fail(`vendored guide drifted from rdd-engine truth source: ${toPosix(guideDst)}（运行 node scripts/build-dsh-plugin.mjs 重新同步）`)
  }
  console.log('ok - vendored exploration-guide in sync with rdd-engine truth source')
} else {
  mkdirSync(dirname(guideDst), { recursive: true })
  copyFileSync(guideSrc, guideDst)
  console.log('ok - vendored exploration-guide synced from rdd-engine')
}

// ---------------------------------------------------------------------------
// manifest 不变量（两种模式都校验）
// ---------------------------------------------------------------------------
{
  const peers = pkg.peerDependencies ?? {}
  for (const dep of [
    '@deepseek-ai/cordis', '@deepseek-ai/dsh-tools', '@deepseek-ai/dsh-subagent',
    '@deepseek-ai/dsh-llm', '@deepseek-ai/dsh-sandbox-policy', '@deepseek-ai/schemastery',
  ]) {
    if (peers[dep] !== '*') fail(`peerDependencies 缺失或规格非 '*': ${dep}（实际: ${peers[dep] ?? 'absent'}）`)
  }
  if (pkg.dependencies !== undefined && Object.keys(pkg.dependencies).length > 0) {
    fail(`package.json 仍携带 dependencies: ${Object.keys(pkg.dependencies).join(', ')}（6 个 @deepseek-ai/* 必须只以 peers 声明）`)
  }
  if (pkg.dsh?.bundle?.patch !== './cordis.patch.yml') fail('package.json 缺少 dsh.bundle 声明（{ dsh: { bundle: { patch: "./cordis.patch.yml" } } }）')
  for (const entry of ['lib/', 'cordis.patch.yml', 'assets/']) {
    if (!pkg.files?.includes(entry)) fail(`package.json files 清单缺少: ${entry}`)
  }
  if (pkg.private === true) fail('package.json 仍是 private —— 分发包必须可发布')
  if (!existsSync(patchPath)) fail(`bundle patch missing: ${patchPath}`)
  const patch = readFileSync(patchPath, 'utf8')
  if (!patch.includes(`name: '@coderrdd/dsh-rdd-explore'`)) fail('cordis.patch.yml 未插入本包插件行（name）')
  for (const tool of ['read', 'read_image', 'glob', 'grep']) {
    if (!new RegExp(`allow:\\s*\\[[^\\]]*\\b${tool}\\b`).test(patch)) {
      fail(`cordis.patch.yml toolFilter.allow 缺少四读工具之一: ${tool}（worker 最小权限基线）`)
    }
  }
  console.log('ok - manifest invariants (bundle declaration / peers * / files / toolFilter baseline)')
}

if (checkMode) {
  console.log('CHECK OK: dsh-rdd-explore manifest + vendored guide consistent')
  process.exit(0)
}

// ---------------------------------------------------------------------------
// DSH workspace 集成：junction 优先 / 同步兜底
// ---------------------------------------------------------------------------
function findDshCheckout() {
  const candidates = [
    process.env.RDD_DSH_CHECKOUT,
    resolve(repoRoot, '..', 'dsh', 'deepseek-harness'),
  ].filter(Boolean)
  return candidates.find(root => existsSync(join(root, 'pnpm-workspace.yaml')))
}

const dshRoot = findDshCheckout()
if (dshRoot === undefined) {
  fail('DSH checkout 未定位（需要 pnpm-workspace.yaml）。设置环境变量 RDD_DSH_CHECKOUT=<dsh checkout 根> 后重试。')
}
const integratePath = join(dshRoot, 'packages', 'local', 'rdd-explore')

/** Windows junction 创建（无需管理员权限）；成功返回 true。 */
function tryJunction() {
  try {
    let present = false
    try { lstatSync(integratePath); present = true } catch { present = false }
    if (present) {
      const st = lstatSync(integratePath)
      if (st.isSymbolicLink()) {
        // 已是链接：目标正确直接复用；错误目标则重建
        const target = readlinkSync(integratePath)
        if (resolve(dirname(integratePath), target) === resolve(pluginDir)) return true
        rmdirSync(integratePath)
      } else if (st.isDirectory()) {
        // 真实目录（旧物理源或同步兜底残留）：让位给 junction；
        // 其 node_modules 有搬迁价值，真相源缺它时先整体挪过去
        const nmSrc = join(integratePath, 'node_modules')
        const nmDst = join(pluginDir, 'node_modules')
        if (existsSync(nmSrc) && !existsSync(nmDst)) {
          try { cpSync(nmSrc, nmDst, { recursive: true, verbatimSymlinks: true }) } catch { /* 挪不动就随目录一起删；DSH 侧 pnpm install 重建 */ }
        }
        rmSync(integratePath, { recursive: true, force: true })
      }
    }
  } catch { /* 落到下面统一尝试创建 */ }
  try {
    symlinkSync(pluginDir, integratePath, 'junction')
    return true
  } catch {
    return false
  }
}

let integrationMode
if (tryJunction()) {
  integrationMode = 'junction'
  console.log(`ok - DSH workspace integration: junction ${toPosix(integratePath)} -> truth source`)
} else {
  // 兜底：目录同步（构建输入拷入 DSH 侧；node_modules 若在真相源则反向借用不了，构建由 DSH 侧自装）
  mkdirSync(integratePath, { recursive: true })
  for (const input of BUILD_INPUTS) {
    const src = join(pluginDir, input)
    if (!existsSync(src)) continue
    rmSync(join(integratePath, input), { recursive: true, force: true })
    cpSync(src, join(integratePath, input), { recursive: true })
  }
  // 真相源若有 node_modules，链接过去（同卷 junction，零拷贝）
  const nmDst = join(integratePath, 'node_modules')
  if (existsSync(join(pluginDir, 'node_modules')) && !existsSync(nmDst)) {
    try { symlinkSync(join(pluginDir, 'node_modules'), nmDst, 'junction') } catch { /* DSH 侧需自行 pnpm install */ }
  }
  integrationMode = 'sync'
  console.log(`ok - DSH workspace integration: sync fallback (junction rejected) -> ${toPosix(integratePath)}`)
}

// ---------------------------------------------------------------------------
// pnpm --filter build（DSH checkout 内）
// ---------------------------------------------------------------------------
try {
  execFileSync(`pnpm --filter @coderrdd/dsh-rdd-explore build`, {
    cwd: dshRoot,
    stdio: 'inherit',
    shell: true,
  })
} catch (err) {
  fail(`pnpm --filter @coderrdd/dsh-rdd-explore build 失败: ${err.message}（若报 filter 未命中，先在 DSH checkout 跑一次 pnpm install 收编 packages/local/rdd-explore）`)
}
const libIndex = join(pluginDir, 'lib', 'index.js')
if (integrationMode === 'sync') {
  // 构建产物落在 DSH 侧拷贝里，拷回真相源
  rmSync(join(pluginDir, 'lib'), { recursive: true, force: true })
  cpSync(join(integratePath, 'lib'), join(pluginDir, 'lib'), { recursive: true })
}
if (!existsSync(libIndex)) fail(`build output missing: ${toPosix(libIndex)}`)
console.log('ok - plugin built (lib/ fresh)')

// ---------------------------------------------------------------------------
// npm pack → 双产物 + 包内校验
// ---------------------------------------------------------------------------
const tmp = mkdtempSync(join(tmpdir(), 'rdd-plugin-pack-'))
const npmCache = join(tmp, 'npm-cache')
mkdirSync(npmCache, { recursive: true })
try {
  const q = p => (/\s/.test(p) ? `"${p}"` : p)
  try {
    execFileSync(`npm.cmd pack --pack-destination ${q(tmp)}`, {
      cwd: pluginDir,
      stdio: 'inherit',
      shell: true,
      env: { ...process.env, npm_config_cache: npmCache, npm_config_update_notifier: 'false' },
    })
  } catch (err) {
    fail(`npm pack 失败: ${err.message}`)
  }
  const produced = readdirSync(tmp).filter(f => f.endsWith('.tgz'))
  if (produced.length !== 1) fail(`npm pack 产物数量异常（${produced.length} 个 .tgz）: ${produced.join(', ')}`)
  if (produced[0] !== expectedTarName) fail(`tarball 文件名 '${produced[0]}' 与清单推导不符（预期 '${expectedTarName}'）`)
  const tarPath = join(tmp, produced[0])

  // 纯 node 解析 tar 成员（ustar 512 字节头遍历）
  const buf = gunzipSync(readFileSync(tarPath))
  const members = []
  {
    let off = 0
    while (off + 512 <= buf.length) {
      const header = buf.subarray(off, off + 512)
      if (header.every(b => b === 0)) break
      const name = header.subarray(0, 100).toString('utf8').replace(/\0.*/, '')
      const sizeField = header.subarray(124, 136).toString('utf8').replace(/[\0 ]/g, '')
      const size = parseInt(sizeField, 8) || 0
      const typeflag = String.fromCharCode(header[156] || 0x30)
      if (typeflag === '0' || typeflag === '\0') members.push(name)
      off += 512 + Math.ceil(size / 512) * 512
    }
  }
  for (const line of members) {
    if (!line.startsWith('package/')) fail(`包内出现非 package/ 前缀条目: ${line}`)
  }
  const files = members.map(l => l.replace(/^package\//, '')).filter(l => l !== '' && !l.endsWith('/'))
  for (const required of [
    'package.json', 'cordis.patch.yml', 'lib/index.js',
    'assets/rdd-engine/references/exploration-guide.md',
  ]) {
    if (!files.includes(required)) fail(`tarball 缺少分发契约成员: ${required}`)
  }
  for (const libMember of ['lib/cache.js', 'lib/dispatch.js', 'lib/recallers/lexical.js']) {
    if (!files.includes(libMember)) fail(`tarball 缺少 lib 构建产物: ${libMember}——files 清单或构建输出不完整`)
  }

  mkdirSync(outDir, { recursive: true })
  copyFileSync(tarPath, join(outDir, 'dsh-rdd-explore.tgz'))
  copyFileSync(tarPath, join(outDir, `dsh-rdd-explore-${pkg.version}.tgz`))
  const kb = Math.round(statSync(tarPath).size / 1024)
  console.log(`built: dist/plugin/dsh-rdd-explore.tgz + dsh-rdd-explore-${pkg.version}.tgz (${kb} kB, integration: ${integrationMode})`)
}
finally {
  rmSync(tmp, { recursive: true, force: true })
}

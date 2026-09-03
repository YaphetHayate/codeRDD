#!/usr/bin/env node
/**
 * 聚合发布构建（unified-release 需求 4）。
 *
 * 串联三组件构建保证同源，汇聚产物到 dist/release/：
 *   node scripts/build-release.mjs [--tag vX.Y.Z]
 *     1. build-engine-package.mjs   → dist/engine/rdd-engine{,-<v>}.tgz
 *     2. build-dsh-plugin.mjs       → dist/plugin/dsh-rdd-explore{,-<v>}.tgz
 *     3. build-skills-package.mjs   → dist/skills/rdd-skills{,-<v>}.tgz
 *     4. 汇聚 6 个 tarball 到 dist/release/（固定名 + 带版本名双份）
 *     5. 生成 SHA256SUMS（全部 6 件）+ release-notes.md 模板（组件版本对照表）
 *
 * 版本方案：release tag 统一 vX.Y.Z（codeRDD 仓库主版本，起步 v1.0.0，--tag 覆盖）；
 * 三 tarball 内部版本各自独立线（notes 模板携带对照表）。
 *
 * --check（CI）：委托三组件各自 --check；dist/release/ 存在时附加 SHA256SUMS
 * 一致性复核（产物被篡改/过期即失败）。
 *
 * 发布动作（手动，本期非验收项）：
 *   gh release create vX.Y.Z dist/release/*.tgz dist/release/SHA256SUMS dist/release/release-notes.md \
 *     --title "RDD vX.Y.Z" --notes-file dist/release/release-notes.md
 *
 * 环境约束（DSH 沙箱）：node 子进程禁止管道 stdio（EPERM），子进程经 shell 以
 * stdio:inherit 运行。
 * 零依赖：node:fs / node:path / node:child_process / node:crypto。
 * @module coderrdd/build-release
 */

import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const checkMode = process.argv.includes('--check')

const fail = msg => { console.error(`✗ ${msg}`); process.exit(1) }

const tagIndex = process.argv.indexOf('--tag')
const releaseTag = tagIndex !== -1 && process.argv[tagIndex + 1] ? process.argv[tagIndex + 1] : 'v1.0.0'

/** 三组件构建脚本（顺序即依赖顺序：plugin 构建读 rdd-engine 的 vendored guide 源）。 */
const COMPONENTS = [
  { name: 'engine', script: 'build-engine-package.mjs', dist: join('dist', 'engine'), fixed: 'rdd-engine.tgz', version: () => JSON.parse(readFileSync(join(repoRoot, 'rdd-engine', 'package.json'), 'utf8')).version },
  { name: 'plugin', script: 'build-dsh-plugin.mjs', dist: join('dist', 'plugin'), fixed: 'dsh-rdd-explore.tgz', version: () => JSON.parse(readFileSync(join(repoRoot, 'dsh', 'dsh-rdd-explore', 'package.json'), 'utf8')).version },
  { name: 'skills', script: 'build-skills-package.mjs', dist: join('dist', 'skills'), fixed: 'rdd-skills.tgz', version: () => JSON.parse(readFileSync(join(repoRoot, 'dist', 'skills-staging', 'package.json'), 'utf8')).version },
]

// ---------------------------------------------------------------------------
// 1. 串联三组件构建（--check 委托各组件 --check）
// ---------------------------------------------------------------------------
for (const comp of COMPONENTS) {
  const cmd = `node scripts/${comp.script}${checkMode ? ' --check' : ''}`
  console.log(`--- ${comp.name}: ${cmd}`)
  try {
    execFileSync(cmd, { cwd: repoRoot, stdio: 'inherit', shell: true })
  } catch (err) {
    fail(`组件构建失败: ${comp.script}${checkMode ? ' --check' : ''}（${err.message}）`)
  }
}

if (checkMode) {
  // 附加：dist/release/ 已存在时复核 SHA256SUMS 与实际产物一致（防篡改/过期）
  const releaseDir = join(repoRoot, 'dist', 'release')
  const sumsPath = join(releaseDir, 'SHA256SUMS')
  if (existsSync(sumsPath)) {
    const actual = new Map(readdirSync(releaseDir).filter(f => f.endsWith('.tgz')).map(f => [f, sha256Of(join(releaseDir, f))]))
    for (const line of readFileSync(sumsPath, 'utf8').split(/\r?\n/).filter(Boolean)) {
      const [sum, ...rest] = line.split(/\s+/)
      const file = rest.join(' ')
      if (!actual.has(file)) fail(`SHA256SUMS 引用的产物缺失: ${file}（重跑 build-release.mjs）`)
      if (actual.get(file) !== sum) fail(`SHA256SUMS 与产物不一致: ${file}（产物过期或被改动，重跑 build-release.mjs）`)
    }
    for (const file of actual.keys()) {
      if (!readFileSync(sumsPath, 'utf8').includes(file)) fail(`产物未记入 SHA256SUMS: ${file}`)
    }
    console.log('ok - dist/release SHA256SUMS consistent with artifacts')
  }
  console.log('CHECK OK: all three components verified')
  process.exit(0)
}

// ---------------------------------------------------------------------------
// 2. 汇聚产物 + SHA256SUMS + release notes
// ---------------------------------------------------------------------------
const releaseDir = join(repoRoot, 'dist', 'release')
mkdirSync(releaseDir, { recursive: true })
const versioned = []
for (const comp of COMPONENTS) {
  const version = comp.version()
  const versionedName = comp.fixed.replace(/\.tgz$/, `-${version}.tgz`)
  copyFileSync(join(repoRoot, comp.dist, comp.fixed), join(releaseDir, comp.fixed))
  copyFileSync(join(repoRoot, comp.dist, versionedName), join(releaseDir, versionedName))
  versioned.push({ label: comp.name, fixed: comp.fixed, versionedName, version })
}

const sums = readdirSync(releaseDir).filter(f => f.endsWith('.tgz')).sort()
  .map(f => `${sha256Of(join(releaseDir, f))}  ${f}`)
writeFileSync(join(releaseDir, 'SHA256SUMS'), sums.join('\n') + '\n', 'utf8')

const notes = [
  `# RDD ${releaseTag}`,
  '',
  'Three same-source components (install order engine → plugin → skills is enforced by install-rdd.ps1):',
  '',
  '| component | asset (fixed name) | internal version |',
  '|---|---|---|',
  ...versioned.map(v => `| ${v.label} | ${v.fixed} | ${v.version} |`),
  '',
  '## Install (one command)',
  '',
  '```powershell',
  'powershell -ExecutionPolicy Bypass -File install-rdd.ps1    # latest release; add -Release <tag> to pin/downgrade',
  '```',
  '',
  'Prerequisites: Windows 10 1803+ (tar.exe), PowerShell 5.1+, git, standard DSH (dsh + pnpm on PATH).',
  '',
  '## Verify / upgrade / uninstall',
  '',
  '```powershell',
  'powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Status',
  'powershell -ExecutionPolicy Bypass -File install-rdd.ps1               # upgrade to latest',
  'powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Release v1.0.0  # downgrade',
  'powershell -ExecutionPolicy Bypass -File install-rdd.ps1 -Remove',
  '```',
  '',
  'Checksums: SHA256SUMS (beside the assets).',
  '',
  '> Release notes template generated by scripts/build-release.mjs - edit the body before publishing.',
].join('\n') + '\n'
writeFileSync(join(releaseDir, 'release-notes.md'), notes, 'utf8')

function sha256Of(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

console.log(`release staged: dist/release/ (${releaseTag})`)
for (const v of versioned) console.log(`  ${v.fixed} + ${v.versionedName} (${v.label} v${v.version})`)
console.log('  SHA256SUMS + release-notes.md')
console.log('publish: gh release create <tag> dist/release/*.tgz dist/release/SHA256SUMS dist/release/release-notes.md --notes-file dist/release/release-notes.md')

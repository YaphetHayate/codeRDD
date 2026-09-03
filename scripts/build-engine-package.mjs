#!/usr/bin/env node
/**
 * 构建 rdd-engine 独立发行包（engine-cli-distribution）。
 *
 * rdd-engine/ 原地成包（开发形态 = 分发形态，零装配同步环节）：npm pack 产出
 * npm-pack 格式 tarball，复制为双产物：
 *   dist/engine/rdd-engine.tgz               # 固定名（GitHub Release 稳定资产名）
 *   dist/engine/rdd-engine-<version>.tgz     # 带版本名归档
 *
 * 校验（普通/CI 两种模式都执行）：
 *   V1 tarball 文件名与 package.json 的 name/version 推导一致
 *   V2 定位链契约成员在包内：package.json + scripts/rdd-flow.cmd + references/engine-location.md
 *   V3 漂移检查：rdd-engine/ 目录树中的文件必须进包（意图性排除项除外），包内成员必须存在于目录树
 *   V4 包内条目全部位于 package/ 前缀下
 *   V5 旧定位 snippet 残留检查（技能/文档零容忍，防定位链协议与技能脱钩——R2）
 *
 * 环境约束（DSH 沙箱）：node 子进程禁止管道 stdio（EPERM），故
 *   - npm pack 经 cmd.exe /c 以 stdio:inherit 运行，产物名从输出目录发现（不捕获 stdout）
 *   - tar 成员清单用纯 node 解析（zlib.gunzipSync + 512 字节 tar 头遍历），不派生 tar.exe
 *   - 漂移/残留扫描用目录遍历，不依赖 git
 *
 * 用法:
 *   node scripts/build-engine-package.mjs            # 构建双产物到 dist/engine/
 *   node scripts/build-engine-package.mjs --check    # CI：临时目录打包 + 全量校验，不写 dist
 * 零依赖：node:fs / node:path / node:zlib / node:child_process / node:os。
 * @module coderrdd/build-engine-package
 */

import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { gunzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const engineDir = join(repoRoot, 'rdd-engine')
const outDir = join(repoRoot, 'dist', 'engine')
const checkMode = process.argv.includes('--check')

/** rdd-engine/ 目录中存在但有意不进引擎 tarball 的文件（skill 正文经技能通道分发，非引擎产物）。 */
const EXCLUSIONS = new Set(['SKILL.md'])

/** 旧定位 snippet 的特征前缀（已被三级定位链取代，源码中出现即失败）。 */
const LEGACY_SNIPPET = "$rdd = (Get-ChildItem (git rev-parse --show-toplevel)"

/** 残留扫描作用域：这些目录（及 README.md）下的 .md/.yml 不允许出现旧 snippet（含隐藏 dot 目录内的子代理 prompt）。 */
const RESIDUE_SCOPES = [
  'rdd-engine', 'rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse',
  join('dsh', 'presets'), 'docs',
  join('.claude', 'agents'), join('.opencode', 'agent'), join('.zcode', 'agents'),
]

const toPosix = p => p.split('\\').join('/')
const fail = msg => { console.error(`✗ ${msg}`); process.exit(1) }

/** 递归列出目录下全部文件（相对 posix 路径），跳过 VCS/依赖目录。 */
function walkFiles(root, dir = root) {
  const out = []
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    if (ent.name === '.git' || ent.name === 'node_modules' || ent.name === '.idea') continue
    const p = join(dir, ent.name)
    if (ent.isDirectory()) out.push(...walkFiles(root, p))
    else if (ent.isFile()) out.push(toPosix(relative(root, p)))
  }
  return out
}

/** 纯 node 解析 tar 成员清单（ustar：512 字节头 + 数据块补齐；只取普通文件条目）。 */
function listTarMemberNames(tarBuffer) {
  const names = []
  let off = 0
  while (off + 512 <= tarBuffer.length) {
    const header = tarBuffer.subarray(off, off + 512)
    if (header.every(b => b === 0)) break // end-of-archive
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*/, '')
    const sizeField = header.subarray(124, 136).toString('utf8').replace(/[\0 ]/g, '')
    const size = parseInt(sizeField, 8) || 0
    const typeflag = String.fromCharCode(header[156] || 0x30)
    if (typeflag === '0' || typeflag === '\0') names.push(name)
    off += 512 + Math.ceil(size / 512) * 512
  }
  return names
}

// --- 包清单（发行版本真相源） ---
const pkgPath = join(engineDir, 'package.json')
if (!existsSync(pkgPath)) fail('rdd-engine/package.json not found — 引擎包清单缺失')
const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
if (pkg.name !== '@coderrdd/rdd-engine') fail(`unexpected package name: ${pkg.name}`)
const expectedTarName = pkg.name.replace(/^@/, '').replace('/', '-') + `-${pkg.version}.tgz`

// --- npm pack 到临时目录（cmd.exe / stdio:inherit；产物名从目录发现） ---
const tmp = mkdtempSync(join(tmpdir(), 'rdd-engine-pack-'))
// npm cache 隔离到临时目录内：既保证 hermetic 构建，也兼容受限沙箱（用户级 npm-cache 不可写时）
const npmCache = join(tmp, 'npm-cache')
mkdirSync(npmCache, { recursive: true })
let tarPath
let tarKb = 0
try {
  try {
    // shell:true 单命令串（引号只在路径含空格时添加）；npm cache 经 env 传入，绕开 cmd 引号透传问题
    const q = p => (/\s/.test(p) ? `"${p}"` : p)
    execFileSync(`npm.cmd pack --pack-destination ${q(tmp)}`, {
      cwd: engineDir,
      stdio: 'inherit',
      shell: true,
      env: { ...process.env, npm_config_cache: npmCache, npm_config_update_notifier: 'false' },
    })
  } catch (err) {
    fail(`npm pack 失败: ${err.message}`)
  }
  const produced = readdirSync(tmp).filter(f => f.endsWith('.tgz'))
  // V1 文件名
  if (produced.length !== 1) fail(`npm pack 产物数量异常（${produced.length} 个 .tgz）: ${produced.join(', ')}`)
  if (produced[0] !== expectedTarName) {
    fail(`tarball 文件名 '${produced[0]}' 与清单推导不符（预期 '${expectedTarName}'）`)
  }
  tarPath = join(tmp, produced[0])

  // --- tar 实际成员（纯 node 解析） ---
  const tarLines = listTarMemberNames(gunzipSync(readFileSync(tarPath)))
  // V4 全部位于 package/ 前缀
  for (const line of tarLines) {
    if (!line.startsWith('package/')) fail(`包内出现非 package/ 前缀条目: ${line}`)
  }
  const tarMembers = tarLines.map(l => l.replace(/^package\//, '')).filter(l => l !== '' && !l.endsWith('/'))
  // V2 定位链契约成员
  for (const required of ['package.json', 'scripts/rdd-flow.cmd', 'references/engine-location.md']) {
    if (!tarMembers.includes(required)) fail(`tarball 缺少定位链契约成员: ${required}`)
  }

  // --- V3 漂移：目录树与包成员双向对账（意图性排除项除外） ---
  const diskFiles = walkFiles(engineDir)
  for (const f of diskFiles) {
    if (EXCLUSIONS.has(f)) continue
    if (!tarMembers.includes(f)) fail(`rdd-engine/ 目录文件未进 tarball（补 package.json files 或确认排除项）: ${f}`)
  }
  for (const m of tarMembers) {
    if (!existsSync(join(engineDir, m))) fail(`tarball 成员在 rdd-engine/ 目录中不存在（清单过期）: ${m}`)
  }

  // --- V5 旧定位 snippet 残留（零容忍） ---
  const scanFiles = RESIDUE_SCOPES.flatMap(scope => {
    const abs = join(repoRoot, scope)
    return existsSync(abs) ? walkFiles(abs).map(f => join(scope, f)) : []
  }).concat(['README.md'])
  for (const f of scanFiles.filter(f => /\.(md|yml)$/.test(f))) {
    if (readFileSync(join(repoRoot, f), 'utf8').includes(LEGACY_SNIPPET)) {
      fail(`旧定位 snippet 残留: ${f}（须替换为 engine-location.md 规范单行 snippet）`)
    }
  }

  // --- 产出双产物（CI 模式不落盘） ---
  if (!checkMode) {
    mkdirSync(outDir, { recursive: true })
    copyFileSync(tarPath, join(outDir, 'rdd-engine.tgz'))
    copyFileSync(tarPath, join(outDir, `rdd-engine-${pkg.version}.tgz`))
  }
  tarKb = Math.round(statSync(tarPath).size / 1024)
}
finally {
  rmSync(tmp, { recursive: true, force: true })
}

console.log(checkMode
  ? `CHECK OK: ${expectedTarName} (${tarKb} kB, tarball verified)`
  : `built: dist/engine/rdd-engine.tgz + dist/engine/rdd-engine-${pkg.version}.tgz (${tarKb} kB)`)

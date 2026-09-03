#!/usr/bin/env node
/**
 * 构建 RDD 角色体系分发包（role-skills-global-install 需求 2）。
 *
 * 管线：
 *   1. 先跑 build-dsh-presets.mjs 保证 preset 与技能源新鲜（生成物零漂移）
 *   2. 组装 dist/skills-staging/（gitignored）：
 *        package.json   @coderrdd/rdd-skills（files: skills/ + presets/）
 *        skills/        8 个角色技能目录（rdd-engine 仅 SKILL.md——协议文档经
 *                       引擎三级定位链解析到引擎侧，与脚本同版本，不随包重复）
 *        presets/       7 组 dsh 生成物（agent.cordis.yml + preset.yml）
 *   3. npm pack → 双产物：
 *        dist/skills/rdd-skills.tgz               # 固定名（Release latest 直链）
 *        dist/skills/rdd-skills-<version>.tgz     # 带版本名归档
 *
 * 安装边界 = 子树边界：skills/ 与 presets/ 两个子树分别落
 * $DSH_HOME/skills/ 与 $DSH_HOME/.agent-presets/（install-rdd-skills.ps1）。
 *
 * 校验：
 *   S1 技能源 junction fail-loud（codeRDD v1 junction 布局携带链接目录 = 拷贝失真）
 *   S2 rdd-engine 子树仅 SKILL.md（references/ 泄漏 = 与引擎脚本版本脱钩）
 *   S3 tarball 文件名与 package.json name/version 推导一致
 *   S4 包内条目全部位于 package/ 前缀下；契约成员（8×SKILL.md + 7×agent.cordis.yml）齐全
 *
 * --check（CI）：S1 + S2 + preset 新鲜度（委托 build-dsh-presets.mjs --check）+
 *   staging 结构完整性，不 pack、不落盘。
 *
 * 环境约束（DSH 沙箱）：node 子进程禁止管道 stdio（EPERM），子 node/npm 进程经
 * shell 以 stdio:inherit 运行。
 *
 * 用法:
 *   node scripts/build-skills-package.mjs            # 全管线 → dist/skills/
 *   node scripts/build-skills-package.mjs --check    # CI 一致性校验
 * 零依赖：node:fs / node:path / node:child_process / node:os / node:zlib。
 * @module coderrdd/build-skills-package
 */

import { execFileSync } from 'node:child_process'
import { copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { gunzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const checkMode = process.argv.includes('--check')

const toPosix = p => p.split('\\').join('/')
const fail = msg => { console.error(`✗ ${msg}`); process.exit(1) }

/** 8 个角色技能目录（7 流程角色 + rdd-engine）。 */
const SKILL_ROLES = ['rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse', 'rdd-engine']

/** 7 组 preset 生成物（engine 职能由 rdd-explore 插件 + CLI 承接，无 preset）。 */
const PRESET_ROLES = ['rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse']

const SKILLS_VERSION = '1.0.0'
const PKG_NAME = '@coderrdd/rdd-skills'

// ---------------------------------------------------------------------------
// 1. preset 新鲜度（两种模式都需要；--check 委托给生成器的 --check）
// ---------------------------------------------------------------------------
try {
  execFileSync(`node ${checkMode ? 'scripts/build-dsh-presets.mjs --check' : 'scripts/build-dsh-presets.mjs'}`, {
    cwd: repoRoot,
    stdio: 'inherit',
    shell: true,
  })
} catch (err) {
  fail(`build-dsh-presets.mjs ${checkMode ? '--check' : ''} 失败: ${err.message}（preset 生成物与技能源不一致，先再生成）`)
}

// ---------------------------------------------------------------------------
// S1 技能源 junction fail-loud + S2 rdd-engine 子树约束
// ---------------------------------------------------------------------------
for (const role of SKILL_ROLES) {
  const dir = join(repoRoot, role)
  if (!existsSync(join(dir, 'SKILL.md'))) fail(`技能源缺少 SKILL.md: ${role}/`)
  let st
  try { st = lstatSync(dir) } catch { fail(`技能源目录不存在: ${role}/`) }
  if (st.isSymbolicLink()) fail(`技能源是 junction/符号链接: ${role}/（v1 junction 布局不支持打包——先落成真实目录）`)
  const nm = join(dir, 'node_modules')
  if (existsSync(nm)) fail(`技能源含 node_modules: ${role}/（不应存在，检查误装）`)
}
{
  const engineExtras = readdirSync(join(repoRoot, 'rdd-engine'), { withFileTypes: true })
    .filter(ent => ent.name !== 'SKILL.md' && ent.name !== 'references' && ent.name !== 'scripts' && ent.name !== 'package.json')
    .map(ent => ent.name)
  // 仓内 rdd-engine/ 同时是引擎包源（package.json/scripts/references 属引擎 tarball）；
  // 技能包只取 SKILL.md。这里只检查技能包将携带的部分，不约束引擎自身布局。
  if (engineExtras.length > 0) console.log(`note - rdd-engine 仓内额外内容不进技能包: ${engineExtras.join(', ')}`)
}

// ---------------------------------------------------------------------------
// 2. 组装 staging
// ---------------------------------------------------------------------------
const stagingRoot = checkMode ? mkdtempSync(join(tmpdir(), 'rdd-skills-check-')) : join(repoRoot, 'dist', 'skills-staging')
rmSync(stagingRoot, { recursive: true, force: true })
mkdirSync(join(stagingRoot, 'skills'), { recursive: true })
mkdirSync(join(stagingRoot, 'presets'), { recursive: true })

writeFileSync(join(stagingRoot, 'package.json'), JSON.stringify({
  name: PKG_NAME,
  version: SKILLS_VERSION,
  description: 'RDD role skills (8) + dsh agent presets (7) as one user-level distribution: install once via install-rdd-skills.ps1 into $DSH_HOME/skills and $DSH_HOME/.agent-presets, available to every project',
  files: ['skills/', 'presets/'],
  repository: { type: 'git', url: 'git+https://github.com/YaphetHayate/codeRDD.git' },
  license: 'MIT',
}, null, 2) + '\n', 'utf8')

const copied = []
for (const role of SKILL_ROLES) {
  const dst = join(stagingRoot, 'skills', role)
  mkdirSync(dst, { recursive: true })
  copyFileSync(join(repoRoot, role, 'SKILL.md'), join(dst, 'SKILL.md'))
  copied.push(`skills/${role}/SKILL.md`)
  if (role !== 'rdd-engine') {
    // 流程角色：references/ 随技能走；rdd-engine 特例——S2：仅 SKILL.md
    cpSync(join(repoRoot, role, 'references'), join(dst, 'references'), { recursive: true })
    for (const f of readdirSync(join(dst, 'references'), { recursive: true })) {
      copied.push(`skills/${role}/references/${toPosix(String(f))}`)
    }
  }
}
for (const role of PRESET_ROLES) {
  const src = join(repoRoot, 'dsh', 'presets', role)
  if (!existsSync(join(src, 'agent.cordis.yml')) || !existsSync(join(src, 'preset.yml'))) {
    fail(`preset 生成物缺失: dsh/presets/${role}/（agent.cordis.yml + preset.yml）`)
  }
  cpSync(src, join(stagingRoot, 'presets', role), { recursive: true })
  copied.push(`presets/${role}/agent.cordis.yml`, `presets/${role}/preset.yml`)
}

// staging 结构完整性（两种模式共用）
{
  const skillsDirs = readdirSync(join(stagingRoot, 'skills'))
  const presetDirs = readdirSync(join(stagingRoot, 'presets'))
  if (skillsDirs.length !== 8 || !SKILL_ROLES.every(r => skillsDirs.includes(r))) fail(`staging skills/ 子树不完整: ${skillsDirs.join(', ')}`)
  if (presetDirs.length !== 7 || !PRESET_ROLES.every(r => presetDirs.includes(r))) fail(`staging presets/ 子树不完整: ${presetDirs.join(', ')}`)
  const engineSubtree = readdirSync(join(stagingRoot, 'skills', 'rdd-engine'))
  if (engineSubtree.length !== 1 || engineSubtree[0] !== 'SKILL.md') {
    fail(`skills/rdd-engine 子树必须仅含 SKILL.md（实际: ${engineSubtree.join(', ')}）——协议文档经引擎定位链解析，不随技能包重复`)
  }
  console.log(`ok - staging assembled: 8 skills + 7 presets (${copied.length} files)`)
}

if (checkMode) {
  rmSync(stagingRoot, { recursive: true, force: true })
  console.log('CHECK OK: rdd-skills staging structure + preset freshness verified')
  process.exit(0)
}

// ---------------------------------------------------------------------------
// 3. npm pack → 双产物 + 包内校验
// ---------------------------------------------------------------------------
const tmp = mkdtempSync(join(tmpdir(), 'rdd-skills-pack-'))
const npmCache = join(tmp, 'npm-cache')
mkdirSync(npmCache, { recursive: true })
try {
  const q = p => (/\s/.test(p) ? `"${p}"` : p)
  const expectedTarName = PKG_NAME.replace(/^@/, '').replace('/', '-') + `-${SKILLS_VERSION}.tgz`
  try {
    execFileSync(`npm.cmd pack --pack-destination ${q(tmp)}`, {
      cwd: stagingRoot,
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
  for (const required of ['package.json', ...SKILL_ROLES.map(r => `skills/${r}/SKILL.md`), ...PRESET_ROLES.map(r => `presets/${r}/agent.cordis.yml`)]) {
    if (!files.includes(required)) fail(`tarball 缺少契约成员: ${required}`)
  }
  if (files.some(f => f.startsWith('skills/rdd-engine/references/'))) {
    fail('tarball 泄漏 skills/rdd-engine/references/——协议文档必须经引擎定位链解析（与脚本同版本）')
  }

  const outDir = join(repoRoot, 'dist', 'skills')
  mkdirSync(outDir, { recursive: true })
  copyFileSync(tarPath, join(outDir, 'rdd-skills.tgz'))
  copyFileSync(tarPath, join(outDir, `rdd-skills-${SKILLS_VERSION}.tgz`))
  const kb = Math.round(statSync(tarPath).size / 1024)
  console.log(`built: dist/skills/rdd-skills.tgz + rdd-skills-${SKILLS_VERSION}.tgz (${kb} kB, ${files.length} files)`)
}
finally {
  rmSync(tmp, { recursive: true, force: true })
}

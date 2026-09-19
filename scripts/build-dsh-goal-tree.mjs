#!/usr/bin/env node
/**
 * Build @coderrdd/dsh-rdd-goal-tree into an installable dsh profile bundle.
 *
 * Pipeline (zero DSH-checkout mutation — types resolve through tsconfig paths
 * and a read-only @types/react junction):
 *   1. ensure node_modules/@types/react (junction into the DSH checkout's
 *      pnpm store — build-time only, never packed)
 *   2. tsc -p tsconfig.json            → lib/          (host half, ESM)
 *   3. tsc -p tsconfig.client.json     → lib/_client/  (browser half, CJS)
 *   4. wrap lib/_client/index.js into lib/client.js — the exact
 *      `window.__ModuleLoader__.load({id, factory})` factory format the web
 *      boot graph expects (mirrors @deepseek-ai client bundles)
 *   5. npm pack → dist/plugin/coderrdd-dsh-rdd-goal-tree-<version>.tgz
 *      copied to the fixed release name dist/plugin/dsh-rdd-goal-tree.tgz
 *
 * `--check` verifies the built artifacts' shapes without rebuilding.
 */
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PKG_DIR = join(REPO_ROOT, 'dsh', 'rdd-goal-tree')
const CHECKOUT = process.env.DSH_CHECKOUT !== undefined
  ? resolve(process.env.DSH_CHECKOUT)
  : resolve(REPO_ROOT, '..', 'dsh', 'deepseek-harness')
const PKG_ID = '@coderrdd/dsh-rdd-goal-tree'
const DIST_DIR = join(REPO_ROOT, 'dist', 'plugin')

/** Locate a typescript compiler: package-local, sibling plugin, repo, checkout. */
function findTsc() {
  const candidates = [
    join(PKG_DIR, 'node_modules', 'typescript', 'bin', 'tsc'),
    join(REPO_ROOT, 'dsh', 'dsh-rdd-explore', 'node_modules', 'typescript', 'bin', 'tsc'),
    join(REPO_ROOT, 'node_modules', 'typescript', 'bin', 'tsc'),
    join(CHECKOUT, 'node_modules', 'typescript', 'bin', 'tsc'),
  ]
  const found = candidates.find(existsSync)
  if (found === undefined) throw new Error(`build-dsh-goal-tree: no tsc found (tried: ${candidates.join('; ')})`)
  return found
}

/** Ensure node_modules/@types/react points into the checkout's pnpm store. */
function ensureReactTypes() {
  const linkPath = join(PKG_DIR, 'node_modules', '@types', 'react')
  if (existsSync(linkPath)) return
  const pnpmAtTypes = join(CHECKOUT, 'node_modules', '.pnpm')
  if (!existsSync(pnpmAtTypes)) throw new Error(`build-dsh-goal-tree: DSH checkout pnpm store not found at ${pnpmAtTypes} (set DSH_CHECKOUT)`)
  const versions = readdirSync(pnpmAtTypes)
    .filter(name => /^@types\+react@\d/.test(name))
    .sort()
  const latest = versions.at(-1)
  if (latest === undefined) throw new Error('build-dsh-goal-tree: no @types/react in the checkout pnpm store')
  const target = join(pnpmAtTypes, latest, 'node_modules', '@types', 'react')
  if (!existsSync(join(target, 'package.json'))) throw new Error(`build-dsh-goal-tree: @types/react store entry broken at ${target}`)
  mkdirSync(dirname(linkPath), { recursive: true })
  symlinkSync(target, linkPath, 'junction')
  process.stdout.write(`[build] @types/react junction -> ${target}\n`)
}

/** Run one tsc project build. */
function runTsc(project) {
  const tsc = findTsc()
  const result = spawnSync(process.execPath, [tsc, '-p', project], { cwd: PKG_DIR, stdio: 'inherit' })
  if (result.status !== 0) throw new Error(`build-dsh-goal-tree: tsc -p ${project} failed (exit ${result.status})`)
}

/** Wrap the compiled CJS client into the module-loader factory registration. */
function wrapClientBundle() {
  const compiledPath = join(PKG_DIR, 'lib', '_client', 'index.js')
  const compiled = readFileSync(compiledPath, 'utf8')
  const bundled = [
    'window.__ModuleLoader__.load({',
    `\tid: "${PKG_ID}",`,
    '\tfactory: (require) => {',
    '\t\tvar module = { exports: {} };',
    '\t\tvar exports = module.exports;',
    compiled,
    '\t\treturn module.exports;',
    '\t}',
    '});',
    '',
  ].join('\n')
  writeFileSync(join(PKG_DIR, 'lib', 'client.js'), bundled)
  rmSync(join(PKG_DIR, 'lib', '_client'), { recursive: true, force: true })
}

/** npm pack into dist/plugin and normalize to the fixed release name. */
function pack() {
  const pkg = JSON.parse(readFileSync(join(PKG_DIR, 'package.json'), 'utf8'))
  mkdirSync(DIST_DIR, { recursive: true })
  const result = spawnSync('npm.cmd', ['pack', '--silent', '--pack-destination', DIST_DIR], {
    cwd: PKG_DIR,
    stdio: 'inherit',
    shell: true,
    // Keep npm's cache inside the repo: the build may run under a workspace-scoped
    // sandbox where the user-level npm-cache directory is not writable.
    env: { ...process.env, npm_config_cache: join(REPO_ROOT, '.rdd', 'tmp', 'npm-cache') },
  })
  if (result.status !== 0) throw new Error(`build-dsh-goal-tree: npm pack failed (exit ${result.status})`)
  const versioned = join(DIST_DIR, `coderrdd-dsh-rdd-goal-tree-${pkg.version}.tgz`)
  const fixed = join(DIST_DIR, 'dsh-rdd-goal-tree.tgz')
  cpSync(versioned, fixed, { force: true })
  process.stdout.write(`[build] ${versioned}\n[build] ${fixed} (fixed release name)\n`)
}

function check() {
  const client = readFileSync(join(PKG_DIR, 'lib', 'client.js'), 'utf8')
  if (!client.startsWith('window.__ModuleLoader__.load({')) throw new Error('check: lib/client.js is not a module-loader registration')
  if (!client.includes(`\tid: "${PKG_ID}",`)) throw new Error('check: lib/client.js carries the wrong package id')
  for (const file of ['lib/index.js', 'lib/goaltrees.js', 'lib/client.js']) {
    if (!existsSync(join(PKG_DIR, file))) throw new Error(`check: missing build artifact ${file}`)
  }
  const pkg = JSON.parse(readFileSync(join(PKG_DIR, 'package.json'), 'utf8'))
  if (pkg.dsh?.bundle?.patch === undefined) throw new Error('check: package.json declares no dsh.bundle')
  if (pkg.dsh?.client?.platform !== 'web') throw new Error('check: package.json declares no dsh.client web platform')
  if (!existsSync(join(DIST_DIR, 'dsh-rdd-goal-tree.tgz'))) throw new Error('check: dist/plugin/dsh-rdd-goal-tree.tgz missing (run without --check first)')
  process.stdout.write('[check] artifacts OK\n')
}

if (process.argv.includes('--check')) {
  check()
} else {
  ensureReactTypes()
  runTsc('tsconfig.json')
  runTsc('tsconfig.client.json')
  wrapClientBundle()
  pack()
  check()
  process.stdout.write('[build] done\n')
}

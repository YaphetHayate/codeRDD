// Keyless smoke: write-whitelist guard and slug derivation (run: node tests/policy-smoke.mjs).
import { slugifyKey } from '../lib/cache.js'
import { isAllowedWrite } from '../lib/index.js'

const cwd = process.platform === 'win32' ? 'D:/work/proj' : '/work/proj'
const win = process.platform === 'win32'
const prefixes = ['.rdd']
const cases = [
  ['.rdd/changes/archive/c1/requirements/a.md', true],
  ['.rdd/exploration/index.json', true],
  [win ? '.rdd\\handoff\\p.md' : '.rdd/handoff/p.md', true],
  ['src/auth.ts', false],
  ['../outside/x.md', false],
  [`${cwd}/.rdd/handoff/p.md`.replaceAll('/', win ? '\\' : '/'), true],
  [`${cwd}/package.json`.replaceAll('/', win ? '\\' : '/'), false],
  [win ? 'D:/other/f.md' : '/other/f.md', false],
  ['.rdd/../src/a.ts', false],
  ['.rddx/evil.md', false],
]
let bad = 0
for (const [path, want] of cases) {
  const got = isAllowedWrite(cwd, path, prefixes)
  if (got !== want) {
    bad += 1
    console.log('FAIL', path, 'got', got, 'want', want)
  }
}
console.log(`isAllowedWrite: ${bad === 0 ? `all ${cases.length} pass` : `${bad} FAIL`}`)
const slugCases = [
  ['认证 模块/JWT：token 流程', '认证-模块-JWT-token-流程'],
  ['///', 'exploration'],
]
for (const [key, want] of slugCases) {
  const got = slugifyKey(key)
  if (got !== want) {
    bad += 1
    console.log('FAIL slugifyKey', JSON.stringify(key), 'got', JSON.stringify(got), 'want', JSON.stringify(want))
  }
}
const long = slugifyKey('a'.repeat(120))
if (long.length > 80) {
  bad += 1
  console.log('FAIL slug length', long.length)
}
console.log(bad === 0 ? 'smoke OK' : 'smoke FAILED')
process.exit(bad === 0 ? 0 : 1)

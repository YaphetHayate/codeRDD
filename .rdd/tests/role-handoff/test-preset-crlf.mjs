#!/usr/bin/env node
/**
 * TC-132 ~ TC-137：preset 生成器 CRLF/LF 行尾替换与防残留断言（黑盒）。
 * 归档：2026-09-26-preset-generator-crlf（role-handoff 功能）。
 *
 * 黑盒驱动方式：把生成器、模板、7 份 SKILL.md 复制进临时沙盒，按场景构造
 * 模板形态（CRLF 原样 / LF 归一化 / 占位符行破坏），动态 import 沙盒里的
 * 生成器触发其主流程（argv 注入 --out），断言产物与 fail-loud 行为——
 * 全程不触碰仓库业务文件。
 *
 * 场景矩阵：
 *   TC-132 crlf-ok     CRLF 模板（真实缺陷现场）生成成功、8 组产物零占位符残留、
 *                      pm/cto 落 writePrefixes、无策略角色该行消失
 *   TC-133 lf-ok       LF 模板回归——修复前 LF 精确匹配可工作的形态不得回归
 *   TC-134 crlf-broken CRLF 模板占位符行破坏（计数 1、正则不命中）→ throw 残留断言
 *   TC-135 lf-broken   LF 模板同破坏 → throw（断言对两种行尾形态均生效）
 *   TC-136 parse       工作树 8 组 dsh/presets 产物经 dsh 同款解析器
 *                      （js-yaml load + @deepseek-ai/cordis-plugin-include
 *                      entryListSchema）验证可解析 + 零残留 + 策略语义
 *   TC-137 zero-drift  CRLF 沙盒产物与工作树 dsh/presets 逐字节一致（可复现构建）
 *
 * 用法：node .rdd/tests/role-handoff/test-preset-crlf.mjs
 * 退出码：0=全部通过 / 1=存在失败。
 */
import { readFileSync, writeFileSync, mkdirSync, cpSync, rmSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
const TMP_ROOT = join(repoRoot, '.rdd', 'tests', 'role-handoff', '.tmp', 'preset-crlf')

/** 生成器 ROLES 的镜像（SKILL.md 源）；产物组 = 这 7 组 + rdd-planner。 */
const SKILL_ROLES = ['rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse']
const ALL_PRESET_ROLES = [...SKILL_ROLES, 'rdd-planner']
const POLICY_ROLES = ['rdd-pm', 'rdd-cto']

const results = []
let failed = 0

/**
 * 记录一条用例结果。
 * @param {string} id - 用例编号。
 * @param {string} title - 用例标题。
 * @param {boolean} pass - 是否通过。
 * @param {string} [detail] - 失败现象（客观描述）。
 */
function report(id, title, pass, detail = '') {
  results.push({ id, title, pass, detail })
  if (!pass) failed += 1
}

/**
 * 断言辅助：通过返回空串，失败返回一句客观现象。
 * @param {boolean} cond - 条件。
 * @param {string} message - 失败现象描述。
 * @returns {string} 空串或失败现象。
 */
function check(cond, message) {
  return cond ? '' : message
}

/**
 * 断言一组生成产物满足占位符与策略语义。
 * @param {string} outDir - 生成输出目录。
 * @param {string} tag - 场景标签（失败现象定位用）。
 * @returns {string[]} 失败现象列表。
 */
function assertArtifacts(outDir, tag) {
  const problems = []
  for (const role of ALL_PRESET_ROLES) {
    const cordisPath = join(outDir, role, 'agent.cordis.yml')
    if (!existsSync(cordisPath)) {
      problems.push(`${tag}: 缺少 ${role}/agent.cordis.yml`)
      continue
    }
    const cordis = readFileSync(cordisPath, 'utf8')
    for (const placeholder of ['__PERSONA__', '__ROLE_POLICY__']) {
      if (cordis.includes(placeholder)) {
        problems.push(`${tag}: ${role}/agent.cordis.yml 残留占位符 ${placeholder}`)
      }
    }
    const presetPath = join(outDir, role, 'preset.yml')
    if (!existsSync(presetPath)) {
      problems.push(`${tag}: 缺少 ${role}/preset.yml`)
    } else if (!readFileSync(presetPath, 'utf8').startsWith('name: ')) {
      problems.push(`${tag}: ${role}/preset.yml 缺少 name 字段`)
    }
    const hasPolicy = cordis.includes("writePrefixes: ['.rdd/']")
    if (POLICY_ROLES.includes(role) && !hasPolicy) {
      problems.push(`${tag}: ${role}/agent.cordis.yml 缺少 writePrefixes: ['.rdd/'] 策略行`)
    }
    if (!POLICY_ROLES.includes(role) && cordis.includes('writePrefixes')) {
      problems.push(`${tag}: ${role}/agent.cordis.yml 不应携带 writePrefixes（无策略角色）`)
    }
  }
  return problems
}

/**
 * 搭建一个场景沙盒（生成器 + 模板变体 + 7 份 SKILL.md）。
 * @param {{ id: string, lineEnd: 'crlf'|'lf', breakPolicy?: boolean }} scenario - 场景定义。
 * @returns {string} 沙盒根目录。
 */
function buildSandbox(scenario) {
  const sandbox = join(TMP_ROOT, scenario.id)
  rmSync(sandbox, { recursive: true, force: true })
  let template = readFileSync(join(repoRoot, 'scripts', 'dsh-preset-template.yml'), 'utf8')
  if (scenario.lineEnd === 'lf') template = template.replace(/\r\n/g, '\n')
  if (scenario.breakPolicy) {
    // 占位符行破坏：占位符后追加固件文本再行尾——split 计数仍为 1，
    // 但 /__ROLE_POLICY__\r?\n/ 不再命中，替换静默失败 → 残留断言应当接管。
    template = template.replace(/__ROLE_POLICY__(\r?\n)/, '__ROLE_POLICY__ BROKEN$1')
  }
  mkdirSync(join(sandbox, 'scripts'), { recursive: true })
  writeFileSync(join(sandbox, 'scripts', 'dsh-preset-template.yml'), template, 'utf8')
  cpSync(join(repoRoot, 'scripts', 'build-dsh-presets.mjs'), join(sandbox, 'scripts', 'build-dsh-presets.mjs'))
  for (const role of SKILL_ROLES) {
    mkdirSync(join(sandbox, role), { recursive: true })
    cpSync(join(repoRoot, role, 'SKILL.md'), join(sandbox, role, 'SKILL.md'))
  }
  return sandbox
}

/**
 * 在沙盒中触发生成器主流程（动态 import 沙盒副本，argv 注入 --out）。
 * @param {string} sandbox - 沙盒根目录。
 * @returns {Promise<{ ok: boolean, error?: Error, outDir: string }>} 执行结果。
 */
async function runGenerator(sandbox) {
  const outDir = join(sandbox, 'out')
  const prevArgv = process.argv
  process.argv = [prevArgv[0], 'build-dsh-presets.mjs', '--out', outDir]
  try {
    await import(pathToFileURL(join(sandbox, 'scripts', 'build-dsh-presets.mjs')).href)
    return { ok: true, outDir }
  } catch (error) {
    return { ok: false, error, outDir }
  } finally {
    process.argv = prevArgv
  }
}

rmSync(TMP_ROOT, { recursive: true, force: true })

// ── TC-132：CRLF 模板正向（真实缺陷现场：模板 164/164 行 CRLF） ──────────
{
  const sandbox = buildSandbox({ id: 'crlf-ok', lineEnd: 'crlf' })
  const run = await runGenerator(sandbox)
  let detail = ''
  if (!run.ok) {
    detail = `CRLF 模板下生成器异常退出：${run.error?.message ?? '(无错误消息)'}`
  } else {
    const problems = assertArtifacts(run.outDir, 'crlf-ok')
    detail = problems.join('；')
  }
  report('TC-132', 'CRLF 模板正向：8 组产物生成成功、零占位符残留、策略语义落位', run.ok && detail === '', detail)
}

// ── TC-133：LF 模板回归（修复前 LF 精确匹配可工作的形态，不得回归） ──────
{
  const sandbox = buildSandbox({ id: 'lf-ok', lineEnd: 'lf' })
  const run = await runGenerator(sandbox)
  let detail = ''
  if (!run.ok) {
    detail = `LF 模板下生成器异常退出：${run.error?.message ?? '(无错误消息)'}`
  } else {
    const problems = assertArtifacts(run.outDir, 'lf-ok')
    detail = problems.join('；')
  }
  report('TC-133', 'LF 模板回归：正则替换对 LF 模板同样生效，产物零残留', run.ok && detail === '', detail)
}

// ── TC-134：CRLF 模板占位符行破坏 → 残留断言 fail-loud ───────────────────
{
  const sandbox = buildSandbox({ id: 'crlf-broken', lineEnd: 'crlf', breakPolicy: true })
  const run = await runGenerator(sandbox)
  const pass = !run.ok && (run.error?.message ?? '').includes('残留占位符 __ROLE_POLICY__')
  const detail = !run.ok
    ? check((run.error?.message ?? '').includes('残留占位符 __ROLE_POLICY__'),
      `CRLF 破坏模板下错误消息不含「残留占位符 __ROLE_POLICY__」，实际：${run.error?.message ?? '(无)'}`)
    : 'CRLF 破坏模板下生成器未抛错（残留断言未接管，坏产物可能静默落盘）'
  report('TC-134', 'CRLF 模板替换未命中 → throw 且消息指明残留占位符', pass && detail === '', detail)
}

// ── TC-135：LF 模板占位符行破坏 → 残留断言同样生效 ────────────────────────
{
  const sandbox = buildSandbox({ id: 'lf-broken', lineEnd: 'lf', breakPolicy: true })
  const run = await runGenerator(sandbox)
  const pass = !run.ok && (run.error?.message ?? '').includes('残留占位符 __ROLE_POLICY__')
  const detail = !run.ok
    ? check((run.error?.message ?? '').includes('残留占位符 __ROLE_POLICY__'),
      `LF 破坏模板下错误消息不含「残留占位符 __ROLE_POLICY__」，实际：${run.error?.message ?? '(无)'}`)
    : 'LF 破坏模板下生成器未抛错（残留断言未接管，坏产物可能静默落盘）'
  report('TC-135', 'LF 模板替换未命中 → throw 且消息指明残留占位符', pass && detail === '', detail)
}

// ── TC-136：工作树 8 组产物经 dsh 同款解析器验证（AC2） ───────────────────
{
  const problems = []
  let parserReady = true
  const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh')
  const anchor = join(dshHome, 'profiles', 'node_modules')
  try {
    const requireFromDsh = createRequire(join(anchor, 'package.json'))
    const { load } = requireFromDsh('js-yaml')
    const { entryListSchema } = requireFromDsh('@deepseek-ai/cordis-plugin-include')
    for (const role of ALL_PRESET_ROLES) {
      const cordisPath = join(repoRoot, 'dsh', 'presets', role, 'agent.cordis.yml')
      const cordis = readFileSync(cordisPath, 'utf8')
      for (const placeholder of ['__PERSONA__', '__ROLE_POLICY__']) {
        if (cordis.includes(placeholder)) {
          problems.push(`${role}/agent.cordis.yml 残留占位符 ${placeholder}`)
        }
      }
      let rows
      try {
        rows = load(cordis, { schema: entryListSchema })
      } catch (error) {
        problems.push(`${role}/agent.cordis.yml dsh 同款解析器（js-yaml load + entryListSchema）解析失败：${error instanceof Error ? error.message.split('\n')[0] : String(error)}`)
        continue
      }
      // 浅校验同 harness entryListProblem：顶层数组、每行是带 name 字符串的 map（group 递归）。
      const shapeProblem = (list, at) => {
        if (!Array.isArray(list)) return `${at} 不是 entry 数组`
        for (const [index, row] of list.entries()) {
          if (typeof row !== 'object' || row === null || Array.isArray(row)) return `${at} 第 ${index + 1} 行不是 plugin map`
          if (typeof row.name !== 'string' || row.name === '') return `${at} 第 ${index + 1} 行缺少 name`
          if (row.group === true) {
            const nested = shapeProblem(row.config, `${at} 第 ${index + 1} 行 group`)
            if (nested) return nested
          }
        }
        return ''
      }
      const shape = shapeProblem(rows, role)
      if (shape) problems.push(`${role}/agent.cordis.yml entry 结构问题：${shape}`)
      const hasPolicy = cordis.includes("writePrefixes: ['.rdd/']")
      if (POLICY_ROLES.includes(role) && !hasPolicy) problems.push(`${role}/agent.cordis.yml 缺少 writePrefixes: ['.rdd/']`)
      if (!POLICY_ROLES.includes(role) && cordis.includes('writePrefixes')) problems.push(`${role}/agent.cordis.yml 不应携带 writePrefixes`)
    }
  } catch (error) {
    parserReady = false
    problems.push(`dsh 解析器依赖不可用（${anchor}）：${error instanceof Error ? error.message : String(error)}`)
  }
  report('TC-136', '工作树 8 组产物：dsh 同款解析器（entryListSchema）全部可解析、零残留、策略语义正确', parserReady && problems.length === 0, problems.join('；'))
}

// ── TC-137：CRLF 沙盒产物与工作树 dsh/presets 逐字节一致（零漂移） ────────
{
  const problems = []
  const sandboxOut = join(TMP_ROOT, 'crlf-ok', 'out')
  for (const role of ALL_PRESET_ROLES) {
    for (const file of ['agent.cordis.yml', 'preset.yml']) {
      const sandboxFile = join(sandboxOut, role, file)
      const repoFile = join(repoRoot, 'dsh', 'presets', role, file)
      if (!existsSync(sandboxFile) || !existsSync(repoFile)) {
        problems.push(`${role}/${file} 沙盒或工作树副本缺失`)
        continue
      }
      if (readFileSync(sandboxFile, 'utf8') !== readFileSync(repoFile, 'utf8')) {
        problems.push(`${role}/${file} 沙盒再生成产物与工作树不一致（构建不可复现）`)
      }
    }
  }
  report('TC-137', '沙盒再生成产物与工作树 dsh/presets 逐字节一致（零漂移）', problems.length === 0, problems.join('；'))
}

rmSync(TMP_ROOT, { recursive: true, force: true })

console.log(`preset 生成器 CRLF 验证：通过 ${results.length - failed}/${results.length}`)
for (const { id, title, pass, detail } of results) {
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}  ${title}${pass ? '' : `\n      失败现象：${detail}`}`)
}
process.exit(failed === 0 ? 0 : 1)

#!/usr/bin/env node
/**
 * 从各角色 SKILL.md 生成 dsh agent presets（单一事实源 → 生成物）。
 *
 * SKILL.md 是唯一事实源（Claude Code / OpenCode / ZCode 仍在用 skill 流程）；
 * 本脚本把正文迁移进每个角色 preset 的 persona 段，使 dsh 会话第一轮即角色在线，
 * 无需再经 skill 工具加载正文；references 仍按需渐进读取。
 *
 * 适配规则（正文其余部分逐字保留，零改写）：
 * - 剥离 frontmatter（触发语义 "仅当用户输入 /RDD-XX" 在 preset 模式下无意义）
 * - 「## rdd-engine 能力（工作前必读）」boilerplate 节替换为 dsh 版（explore.cmd → rdd_explore 工具）
 * - persona 头部附加 dsh 环境适配声明（路径基准 / 角色切换机制 / 无通用 subagent）
 * - 生成前断言 persona 携带 start-role.cmd 交接指引且无旧式人工指引（加固闸②）
 * - persona 尾部附加防重复加载声明
 *
 * rdd-manager 特例：Manager 是引擎编排形态（无 SKILL.md），persona 为自举指针
 * （指向 rdd-engine/references/manager-guide.md），由本生成器内建常量装配。
 *
 * 用法:
 *   node scripts/build-dsh-presets.mjs                 # 生成到 dsh/presets/
 *   node scripts/build-dsh-presets.mjs --check         # 校验已生成文件与源一致（幂等），不一致退出 1
 *   node scripts/build-dsh-presets.mjs --out <dir>     # 输出到其他目录
 * 零依赖：仅 node:fs / node:path。
 * @module coderrdd/build-dsh-presets
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

/** 生成目标角色（engine 除外：其职能在 dsh 中由 rdd-explore 插件 + CLI 脚本承接）。 */
const ROLES = ['rdd-pm', 'rdd-cto', 'rdd-ux', 'rdd-dev', 'rdd-qa', 'rdd-eval', 'rdd-pse']

/**
 * Manager 引导 preset（rdd-manager）：Manager 是引擎编排形态而非角色卡（无 SKILL.md），
 * persona 是自举指针——行为载荷唯一事实源在引擎侧 manager-guide.md，随引擎版本分发。
 * start-role -Role MANAGER 的 dsh 后端依赖本 preset 创建会话（见 manager-guide 部署前提）。
 */
const MANAGER_PRESET = {
  role: 'rdd-manager',
  name: 'RDD-MANAGER',
  description: 'Manager 交付编排模式（引擎编排形态，非角色卡）。归档较重时接管整批交付：颁布节点、调动角色会话、统一流转与结案报告。',
}

/** Manager 自举 persona（与角色 persona 同头部的环境适配 + 指向 manager-guide 的引导载荷）。 */
function assembleManagerPersona() {
  const lines = [
    'You are a coding agent powered by the {{model}} model. Your working directory is {{cwd}}.',
    '',
    '【dsh 环境适配】',
    '- 本会话即 RDD-MANAGER 编排会话。Manager 是 rdd-engine 的引擎编排形态（非第六张角色卡），没有技能正文可加载——行为载荷的唯一事实源是 `rdd-engine/references/manager-guide.md`：任何动作前先读它。',
    '- 引擎定位：`rdd-engine/references/...` 与 `scripts/*.cmd` 经引擎三级定位链解析（协议单源：`rdd-engine/references/engine-location.md`）。',
    '- 代码探索：需要理解项目代码时调用 `rdd_explore` 工具查询探索缓存；本会话没有通用 subagent 工具，探索性委派一律走 `rdd_explore`。',
    '- 编排操作：一律经桥接 CLI `delivery-bridge.cmd`（promulgate / dispatch / claim / reclaim / settle / status / resume / conclude / lease）；树内依赖维护经 `goal-tree.cmd -Command deps`；为节点调动角色会话经 `start-role.cmd -Role <CTO/UX/DEV/QA>`（复用现有交接链路，不新造机制）。',
    '- 硬约束（详见 manager-guide.md）：桥接 run 的 task.json 流转只能走 bridge settle，禁止手工 advance/complete；不合格交付（三查不过）不得流转；Manager 变更操作需持租约；中断恢复不重复消费已回写节点。',
    '- 汇报风格：进展用进度表，异常先查 manager-guide.md「异常处置速查」再行动。',
  ]
  return lines.join('\n') + '\n'
}

/**
 * 会话权限策略（按角色）：writePrefixes 限制 write/edit 的落盘前缀（硬白名单，
 * 与会话沙箱模式无关）。未列出的角色不设限。
 * 不用 sessionReadOnly：base bundle 的 permission-presets 在会话创建时即钉住
 * 沙箱模式，种子不会生效；强行覆盖会与用户的手动选择打架，且真生效时会把
 * 角色自己的产物写入也拦进逐次审批。
 */
const ROLE_POLICY = {
  'rdd-pm': { writePrefixes: ['.rdd/'] },
  'rdd-cto': { writePrefixes: ['.rdd/'] },
}

/** 模板中 persona 文本占位符（每角色被缩进 6 空格的正文替换）。 */
const PERSONA_PLACEHOLDER = '__PERSONA__'

/** 模板中 rdd-explore 行内角色策略占位符（整行含换行替换）。 */
const ROLE_POLICY_PLACEHOLDER = '__ROLE_POLICY__'

/** persona 在 YAML 中的缩进层级（`text: |-` 之下）。 */
const PERSONA_INDENT = '      '

/**
 * 剥离 frontmatter，返回 { name, description, body }。
 * description 为折叠块（`>`），按行重组为单句流。
 * @param {string} source - SKILL.md 原文。
 * @returns {{name: string, description: string, body: string}} 解析结果。
 */
function parseFrontmatter(source) {
  const match = source.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/)
  if (match === null) throw new Error('SKILL.md 缺少 frontmatter')
  const fm = match[1]
  const name = fm.match(/^name:\s*(.+)$/m)?.[1]?.trim()
  if (name === undefined) throw new Error('frontmatter 缺少 name')
  const descMatch = fm.match(/^description:\s*>[^\n]*\n((?:[ \t]+\S[^\n]*\n?)+)/m)
  const description = descMatch === null
    ? ''
    : descMatch[1].split(/\r?\n/).map(line => line.trim()).filter(line => line !== '').join(' ')
  return { name, description, body: source.slice(match[0].length) }
}

/**
 * preset.yml 的展示描述：去掉激活语义句后的职责描述。
 * @param {string} description - frontmatter 折叠描述。
 * @returns {string} 过滤后的描述。
 */
function displayDescription(description) {
  return description
    .split(/(?<=。)/)
    .filter(sentence => !sentence.includes('触发') && !sentence.includes('/RDD-'))
    .join('')
    .trim()
}

/**
 * 替换「rdd-engine 能力」boilerplate 节为 dsh 版；恰好一处，否则失败（fail loud）。
 * @param {string} body - SKILL.md 正文（frontmatter 已剥离）。
 * @returns {string} 适配后的正文。
 */
function adaptEngineSection(body) {
  const pattern = /## rdd-engine 能力（工作前必读）\r?\n\r?\n[^\r\n]+\r?\n/
  const replacement = '## rdd-engine 能力（dsh 适配）\n\n需要理解项目代码时，第一步调用 `rdd_explore` 工具查询探索缓存（返回 candidates，按 tags/brief 判断并读 summary；未命中自动派遣探索 worker 并注册）。完整能力清单与硬约束见 `rdd-engine/references/capability-manifest.md`。\n'
  const count = (body.match(pattern) ?? []).length
  if (count !== 1) {
    throw new Error(`「## rdd-engine 能力（工作前必读）」节匹配 ${count} 次（预期恰好 1 次）——SKILL.md 结构变化，请更新生成器`)
  }
  return body.replace(pattern, replacement)
}

/**
 * 加固闸②：persona 必须携带 start-role.cmd 交接指引，且不得残留旧式人工指引。
 * 生成器常量与各角色 SKILL.md 是两处独立的措辞来源，任一处漏改都会让下游会话
 * 收到错误指引（dsh 后端落副本未回灌源仓即由此产生），故在生成阶段 fail loud。
 * @param {string} persona - 组装完成的 persona 全文。
 * @param {string} role - 角色目录名（失败信息用）。
 * @returns {void}
 */
function assertHandoffGuidance(persona, role) {
  if (!persona.includes('start-role.cmd')) {
    throw new Error(`${role} persona 未携带 start-role.cmd 交接指引——检查 scripts/build-dsh-presets.mjs 的 persona 头部常量与 SKILL.md`)
  }
  const retired = '新建目标角色会话'
  if (persona.includes(retired)) {
    throw new Error(`${role} persona 残留旧式人工指引「${retired}」——dsh 交接已改为脚本自动建会话，请更新措辞`)
  }
}

/**
 * 组装某角色的完整 persona 文本。
 * @param {string} role - 角色目录名（如 rdd-dev）。
 * @param {string} skillName - frontmatter 角色名（如 RDD-DEV）。
 * @param {string} body - 已适配的 SKILL.md 正文。
 * @param {{ writePrefixes?: string[], sessionReadOnly?: boolean } | undefined} policy - 角色权限策略。
 * @returns {string} persona 全文。
 */
function assemblePersona(role, skillName, body, policy) {
  const header = [
    'You are a coding agent powered by the {{model}} model. Your working directory is {{cwd}}.',
    '',
    '【dsh 环境适配（本节优先于下方正文中任何环境性描述）】',
    `- 本会话即 ${skillName} 角色会话：下方正文的角色身份即刻生效（正文已内置本会话；rdd-* 系列经 skill 工具加载会被拒绝）；文内 references 按需用 read 工具渐进读取。`,
    `- 路径基准：本角色 \`references/...\` 按安装形态解析——项目级 \`.agents/skills/${role}/references/\` 优先，用户级 \`$DSH_HOME/skills/${role}/references/\`（shell 经 \`$env:DSH_HOME\` 锚定，默认 \`~/.dsh\`）；read 失败时用 glob 搜 \`**/skills/${role}/references/\` 兜底。\`rdd-engine/references/...\` 不在技能目录内，经引擎三级定位链解析（协议单源：rdd-engine/references/engine-location.md）。`,
    '- 代码探索：正文中 explore.cmd / 探索缓存相关指引一律经 `rdd_explore` 工具执行；本会话没有通用 subagent 工具，探索性委派一律走 `rdd_explore`。',
    ...(policy !== undefined ? [
      `- 权限：write/edit 仅允许 ${policy.writePrefixes.map(p => `\`${p}\``).join('、')} 前缀——本角色只产出自己的产物，其余路径的写入一律会被拒绝。`,
    ] : []),
    '- 角色切换：正文中 /RDD-XX 指令与 start-role 开新终端的机制不适用——完成归档并按 transition-guide 4 步交接后（第 3 步仍须用户确认目标角色），经 shell 调用 `start-role.cmd -Role <下游角色> -TaskId <n>` 为该角色开会话——脚本按 `RDD_RUNTIME` → `DSH_WEB_URL` → CLI 判据链自选后端（agent 不判断模式），dsh 下自动创建 preset 已绑定的会话并投递 B2 指针消息，不可达时报错并回退人工指引；rdd-flow 的 advance/next/recommend/handoff 照常经 shell 调用。',
    '',
    '―――― 以下为本角色 SKILL.md 正文（frontmatter 与触发语义已移除） ――――',
    '',
  ].join('\n')
  const footer = [
    '',
    '―――― 正文结束 ――――',
  ].join('\n')
  const normalizedBody = body.replace(/\r\n/g, '\n').replace(/\n+$/, '')
  return `${header}${normalizedBody}${footer}\n`
}

/**
 * 渲染 preset 文件对（模板填充）：SKILL 角色与 Manager 引导 preset 共用。
 * @param {string} template - 模板原文（含占位符）。
 * @param {string} persona - 组装完成的 persona 全文。
 * @param {{ writePrefixes?: string[], sessionReadOnly?: boolean } | undefined} policy - 权限策略。
 * @param {string} name - preset 名（preset.yml name）。
 * @param {string} description - preset 展示描述。
 * @param {number} order - preset 排序值。
 * @returns {{ cordis: string, preset: string, personaChars: number }} 生成内容。
 */
function renderPreset(template, persona, policy, name, description, order) {
  for (const [placeholder, expected] of [[PERSONA_PLACEHOLDER, 1], [ROLE_POLICY_PLACEHOLDER, 1]]) {
    const count = template.split(placeholder).length - 1
    if (count !== expected) throw new Error(`模板占位符 ${placeholder} 出现 ${count} 次（预期 ${expected}）`)
  }
  const indented = persona.split('\n').map(line => line === '' ? '' : PERSONA_INDENT + line).join('\n')
  const policyLines = policy === undefined ? '' : [
    ...(policy.writePrefixes !== undefined ? [`        writePrefixes: [${policy.writePrefixes.map(p => `'${p}'`).join(', ')}]`] : []),
    ...(policy.sessionReadOnly === true ? ['        sessionReadOnly: true'] : []),
  ].join('\n') + '\n'
  const cordis = template
    .replace(PERSONA_PLACEHOLDER, indented)
    .replace(`${ROLE_POLICY_PLACEHOLDER}\n`, policyLines)
  const preset = `name: ${name}\ndescription: ${description || name}\norder: ${order}\n`
  return { cordis, preset, personaChars: persona.length }
}

/**
 * 生成单角色 preset 文件对（persona 来自角色 SKILL.md）。
 * @param {string} template - 模板原文（含占位符）。
 * @param {string} role - 角色目录名。
 * @param {number} order - preset 排序值。
 * @returns {{ cordis: string, preset: string, personaChars: number }} 生成内容。
 */
function buildPreset(template, role, order) {
  const skillPath = join(repoRoot, role, 'SKILL.md')
  if (!existsSync(skillPath)) throw new Error(`缺少 ${skillPath}`)
  // Strip a UTF-8 BOM before frontmatter matching (PowerShell-authored files carry one).
  const { name, description, body } = parseFrontmatter(readFileSync(skillPath, 'utf8').replace(/^\uFEFF/, ''))
  const adapted = adaptEngineSection(body)
  const policy = ROLE_POLICY[role]
  const persona = assemblePersona(role, name, adapted, policy)
  assertHandoffGuidance(persona, role)
  return renderPreset(template, persona, policy, name, displayDescription(description), order)
}

/**
 * 生成 Manager 引导 preset 文件对（persona 为自举指针，非角色卡）。
 * @param {string} template - 模板原文（含占位符）。
 * @param {number} order - preset 排序值。
 * @returns {{ cordis: string, preset: string, personaChars: number }} 生成内容。
 */
function buildManagerPreset(template, order) {
  const persona = assembleManagerPersona()
  assertHandoffGuidance(persona, MANAGER_PRESET.role)
  return renderPreset(template, persona, undefined, MANAGER_PRESET.name, MANAGER_PRESET.description, order)
}

const checkMode = process.argv.includes('--check')
const outFlagIndex = process.argv.indexOf('--out')
const outDir = outFlagIndex !== -1 ? process.argv[outFlagIndex + 1] : join(repoRoot, 'dsh', 'presets')
const template = readFileSync(join(repoRoot, 'scripts', 'dsh-preset-template.yml'), 'utf8')

const summary = []
let mismatch = false
// 生成任务序列：7 个 SKILL 角色 preset + 1 个 Manager 引导 preset（非角色卡，殿后）
const buildTasks = [
  ...ROLES.map(role => ({ kind: 'skill', role })),
  { kind: 'manager', role: MANAGER_PRESET.role },
]
for (const [index, task] of buildTasks.entries()) {
  const { cordis, preset, personaChars } = task.kind === 'skill'
    ? buildPreset(template, task.role, index + 2)
    : buildManagerPreset(template, index + 2)
  const role = task.role
  const dir = join(outDir, role)
  const cordisPath = join(dir, 'agent.cordis.yml')
  const presetPath = join(dir, 'preset.yml')
  const expected = { [cordisPath]: cordis, [presetPath]: preset }
  if (checkMode) {
    for (const [path, content] of Object.entries(expected)) {
      if (!existsSync(path) || readFileSync(path, 'utf8') !== content) {
        console.error(`STALE: ${path}`)
        mismatch = true
      }
    }
  } else {
    mkdirSync(dir, { recursive: true })
    writeFileSync(cordisPath, cordis, 'utf8')
    writeFileSync(presetPath, preset, 'utf8')
  }
  summary.push(`${role}  persona ${personaChars} chars`)
}
console.log(checkMode ? (mismatch ? 'CHECK FAILED' : 'CHECK OK') : summary.join('\n'))
if (checkMode && mismatch) process.exit(1)

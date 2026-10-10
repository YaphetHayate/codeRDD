// Reader: config centre — the five configuration layers (ops-config-panel §4)
// re-organised into eight functional modules (ops-config-panel-r2 §2).
//
// The engine layers stay the data spine (environment variables observed from
// THIS dashboard process, the runtime tuning file .rdd/exploration/
// search-config.json, frozen-constant/CLI mirrors, ecosystem probes); R2 adds
// the module metadata on top so the view can group every item by FUNCTION
// while the l1–l5 envelope keys stay byte-compatible with R1.
//
// Single-source rule (design §4): SEARCH_CONFIG_DEFAULTS, the validator
// predicates and the L3/L4/L5 tables are defined ONCE here — the view and the
// POST control plane both import from this module, never re-declare. The
// defaults and predicates are frozen JS mirrors of recall-shared.ps1
// $SearchDefaults and Get-SearchFieldValidator (scripts/lib/recall-shared.ps1,
// shared with explore.ps1 since the P1 extraction); changing the engine side
// requires changing this mirror in the same commit.
import { mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { listFiles, makeEnvelope, readJson } from '../io.mjs'

const DOMAIN = 'config'
const SOURCE = 'env + .rdd/exploration/search-config.json + 内置镜像常量'

// ── L2 single-source constants ─────────────────────────────────────────

/** Mirror of recall-shared.ps1 $SearchDefaults (14 fields, key order preserved). */
export const SEARCH_CONFIG_DEFAULTS = {
  topK: 5,
  recallDepth: 20,
  rrfK: 60,
  recallers: {
    lexical: {
      enabled: true,
      weight: 1.0,
      bm25K1: 1.2,
      bm25B: 0.75,
    },
    vector: {
      enabled: 'auto',
      weight: 1.0,
      endpoint: '',
      model: '',
      dimensions: 0,
      minCosine: 0.30,
      timeoutSeconds: 10,
    },
  },
}

/**
 * JS mirrors of the nine Get-SearchFieldValidator predicates (design §6).
 * `num(v)` ≡ typeof number && finite; an unknown kind never matches.
 */
const isNum = (v) => typeof v === 'number' && Number.isFinite(v)
export const FIELD_VALIDATORS = {
  posInt: (v) => Number.isInteger(v) && v >= 1,
  posNum: (v) => isNum(v) && v > 0,
  isEnabled: (v) => typeof v === 'boolean' || (typeof v === 'string' && v.toLowerCase() === 'auto'),
  isString: (v) => typeof v === 'string',
  isDim: (v) => Number.isInteger(v) && v >= 0,
  isK1: (v) => isNum(v) && v >= 0,
  isB: (v) => isNum(v) && v >= 0 && v <= 1,
  isCos: (v) => isNum(v) && v >= -1 && v <= 1,
  isTimeout: (v) => isNum(v) && v >= 1,
}

/** One human reason per predicate — the wording the 422 fieldErrors carry. */
export const VALIDATOR_REASONS = {
  posInt: '需整数 ≥1',
  posNum: '需数值 >0',
  isEnabled: '需布尔值或字符串 "auto"',
  isString: '需字符串',
  isDim: '需整数 ≥0',
  isK1: '需数值 ≥0',
  isB: '需数值且 0≤值≤1',
  isCos: '需数值且 -1≤值≤1',
  isTimeout: '需数值 ≥1',
}

/** The 14-field table driving the reader, the form and the POST validation. */
export const FIELD_DEFS = [
  { path: 'topK', section: 'global', validator: 'posInt', label: 'topK', hint: '检索返回条数' },
  { path: 'recallDepth', section: 'global', validator: 'posInt', label: 'recallDepth', hint: '每路召回截断深度' },
  { path: 'rrfK', section: 'global', validator: 'posNum', label: 'rrfK', hint: 'RRF 融合常数' },
  { path: 'recallers.lexical.enabled', section: 'lexical', validator: 'isEnabled', label: 'enabled', hint: '词法路开关（true/false/auto）' },
  { path: 'recallers.lexical.weight', section: 'lexical', validator: 'posNum', label: 'weight', hint: '词法路融合权重' },
  { path: 'recallers.lexical.bm25K1', section: 'lexical', validator: 'isK1', label: 'bm25K1', hint: 'BM25 k1' },
  { path: 'recallers.lexical.bm25B', section: 'lexical', validator: 'isB', label: 'bm25B', hint: 'BM25 b' },
  { path: 'recallers.vector.enabled', section: 'vector', validator: 'isEnabled', label: 'enabled', hint: '向量路开关（true/false/auto）' },
  { path: 'recallers.vector.weight', section: 'vector', validator: 'posNum', label: 'weight', hint: '向量路融合权重' },
  { path: 'recallers.vector.endpoint', section: 'vector', validator: 'isString', label: 'endpoint', hint: 'embedding POST 端点（空=未配置）' },
  { path: 'recallers.vector.model', section: 'vector', validator: 'isString', label: 'model', hint: 'embedding 模型名（空=未配置）' },
  { path: 'recallers.vector.dimensions', section: 'vector', validator: 'isDim', label: 'dimensions', hint: '向量维度（0=未配置，≥1 才有效）' },
  { path: 'recallers.vector.minCosine', section: 'vector', validator: 'isCos', label: 'minCosine', hint: '余弦相似度门槛' },
  { path: 'recallers.vector.timeoutSeconds', section: 'vector', validator: 'isTimeout', label: 'timeoutSeconds', hint: 'embed 请求超时（秒）' },
]

const KNOWN_TOP_KEYS = new Set(['topK', 'recallDepth', 'rrfK', 'recallers'])
const KNOWN_SECTION_KEYS = {
  lexical: new Set(['enabled', 'weight', 'bm25K1', 'bm25B']),
  vector: new Set(['enabled', 'weight', 'endpoint', 'model', 'dimensions', 'minCosine', 'timeoutSeconds']),
}

/** L1 environment variables in display order (observed from this process). */
const L1_VAR_NAMES = ['RDD_ENGINE_HOME', 'RDD_PROJECT_ROOT', 'RDD_RUNTIME', 'DSH_WEB_URL', 'RDD_EMBED_APIKEY']

/** L3 frozen constants — static mirror of the exploration panorama artifact. */
const L3_TABLE = [
  { name: '热区保留期', value: '7 天', location: 'explore-store.ps1:60 $HotRetentionDays' },
  { name: '热区容量', value: '50 条', location: 'explore-store.ps1:61 $HotCapacity' },
  { name: 'TipSchema', value: 'rdd-tip/1', location: 'tips.ps1:107 $TipSchema' },
  { name: 'Tips 记录角色白名单', value: '9 角色白名单', location: 'tips.ps1:107-108 $RecorderRoles' },
  { name: 'F1–F8 检索公式', value: '冻结契约（PS/TS 双侧字面镜像）', location: 'explore.ps1 / recallers/*.ps1 + dsh cache.ts' },
]

/** L4 CLI parameter defaults, grouped by script (static mirror). */
const L4_TABLE = [
  {
    script: 'goal-tree',
    params: [
      { name: 'MaxRounds', default: 5, range: '1–1000' },
      { name: 'NodeWidth', default: 4, range: '1–100' },
      { name: 'MaxNodes', default: 30, range: '1–10000' },
      { name: 'GateMode', default: 'warn', range: 'warn | enforce（未传=warn）' },
    ],
  },
  {
    script: 'delivery-bridge',
    params: [
      { name: 'MaxRounds', default: 12, range: '≥1' },
      { name: 'NodeWidth', default: 'auto', range: 'auto：≥任务数，floor 4' },
      { name: 'MaxNodes', default: 'auto', range: 'auto：任务数×5+6+评审派生余量' },
      { name: 'MaxDerivations', default: 3, range: '超限仅警告（DERIVATION_LIMIT_WARNING）' },
    ],
  },
  {
    script: 'code-metrics',
    params: [
      { name: 'MaxFunctionLines', default: 50, range: '1–10000' },
      { name: 'MaxNestingDepth', default: 5, range: '1–100' },
    ],
  },
  {
    script: 'dashboard',
    params: [
      { name: '端口', default: 8787, range: '1–65535（CLI -Port/--port/-p 覆盖）' },
      { name: 'HOST', default: '127.0.0.1', range: '固定，不可配置' },
    ],
  },
]

/** L5 ecosystem probes (relative to the current project root) + info-only rows. */
const L5_PROBES = [
  { path: 'rdd-ux/ux_subagent.json', role: 'UX 子代理 model 清单一源' },
  { path: '.opencode/agent/', role: '子代理定义目录' },
  { path: 'dsh/presets/', role: 'dsh 会话角色 preset' },
  { path: 'opencode.json', role: 'opencode 客户端 instructions' },
  { path: '.rdd/install.json', role: '非 git 项目根锚点（本仓预期不存在）' },
]
const L5_INFO_ONLY = [{ path: '~/.rdd/engine/manifest.json', role: '用户级安装版本账本（用户级/引擎侧，不在数据根内）' }]

// ── path helpers over the two-level config shape ───────────────────────

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function hasPath(root, path) {
  let current = root
  for (const part of path.split('.')) {
    if (!isPlainObject(current) || !Object.prototype.hasOwnProperty.call(current, part)) return false
    current = current[part]
  }
  return true
}

function getPath(root, path) {
  let current = root
  for (const part of path.split('.')) {
    if (current === null || current === undefined) return undefined
    current = current[part]
  }
  return current
}

function setPath(root, path, value) {
  const parts = path.split('.')
  let current = root
  for (let index = 0; index < parts.length - 1; index += 1) current = current[parts[index]]
  current[parts[parts.length - 1]] = value
}

/** Deep copy preserving the default key order (the shape is fixed, two levels). */
function cloneConfig(config) {
  return {
    topK: config.topK,
    recallDepth: config.recallDepth,
    rrfK: config.rrfK,
    recallers: {
      lexical: { ...config.recallers.lexical },
      vector: { ...config.recallers.vector },
    },
  }
}

/** The file path of the tuning file inside the current data root. */
export function searchConfigPath(context) {
  return join(context.rddRoot, 'exploration', 'search-config.json')
}

// ── L2 engine-mirror merge (fail-soft, same semantics as Read-SearchConfig) ──

/**
 * Field-level fail-soft merge: a present key whose value passes the predicate
 * overrides the default; anything else keeps the default (mirror of
 * Get-SearchConfigValue — a defensive read contract, not an editor semantic).
 * @param {object|null} fileObject parsed file JSON when it is a plain object
 */
function effectiveFrom(fileObject) {
  const effective = cloneConfig(SEARCH_CONFIG_DEFAULTS)
  if (fileObject === null) return effective
  for (const def of FIELD_DEFS) {
    if (!hasPath(fileObject, def.path)) continue
    const value = getPath(fileObject, def.path)
    if (FIELD_VALIDATORS[def.validator](value)) setPath(effective, def.path, value)
  }
  return effective
}

/**
 * The current effective config (fail-soft: missing/corrupt file → defaults).
 * This is the POST merge baseline (design §2 / R7: corrupt content never
 * enters the new file — the baseline is already the healed defaults).
 */
export function loadEffectiveSearchConfig(context) {
  const parsed = readJson(searchConfigPath(context))
  return effectiveFrom(isPlainObject(parsed.value) ? parsed.value : null)
}

/** Vector-path readiness: the auto four-factor rule (rankMeta.warning 口径). */
export function computeVectorReadiness(effective) {
  const vector = effective.recallers.vector
  const missing = []
  if (vector.endpoint === '') missing.push('endpoint')
  if (vector.model === '') missing.push('model')
  if (!(Number.isInteger(vector.dimensions) && vector.dimensions >= 1)) missing.push('dimensions')
  if (!(typeof process.env.RDD_EMBED_APIKEY === 'string' && process.env.RDD_EMBED_APIKEY !== '')) missing.push('apikey')
  return { enabled: vector.enabled, ready: missing.length === 0, missing, observedFrom: 'dashboard-process-env' }
}

/** Unknown keys the engine would silently ignore — surfaced, not hidden. */
function collectUnknownKeys(fileObject) {
  if (fileObject === null) return []
  const unknown = []
  for (const key of Object.keys(fileObject)) {
    if (!KNOWN_TOP_KEYS.has(key)) unknown.push(key)
  }
  if (isPlainObject(fileObject.recallers)) {
    for (const key of Object.keys(fileObject.recallers)) {
      if (key !== 'lexical' && key !== 'vector') unknown.push(`recallers.${key}`)
    }
    for (const section of ['lexical', 'vector']) {
      const node = fileObject.recallers[section]
      if (!isPlainObject(node)) continue
      for (const key of Object.keys(node)) {
        if (!KNOWN_SECTION_KEYS[section].has(key)) unknown.push(`recallers.${section}.${key}`)
      }
    }
  }
  return unknown
}

/** Per-field three-state row for the comparison table (§4 fields[]). */
function buildFields(fileObject) {
  return FIELD_DEFS.map((def) => {
    const fallback = getPath(SEARCH_CONFIG_DEFAULTS, def.path)
    if (!hasPath(fileObject, def.path)) {
      return { path: def.path, validator: def.validator, default: fallback, fileValue: null, effective: fallback, state: 'unset' }
    }
    const value = getPath(fileObject, def.path)
    if (FIELD_VALIDATORS[def.validator](value)) {
      return { path: def.path, validator: def.validator, default: fallback, fileValue: value, effective: value, state: 'set' }
    }
    return { path: def.path, validator: def.validator, default: fallback, fileValue: value, effective: fallback, state: 'invalid' }
  })
}

// ── POST-side validation + merge + atomic write (control plane helpers) ──

/** Truncate an offending value for an error payload (64 chars, never the key). */
function truncateValue(value) {
  const text = typeof value === 'string' ? value : (JSON.stringify(value) ?? String(value))
  return text.length > 64 ? `${text.slice(0, 64)}…` : text
}

/**
 * Gate ③ unknown keys + gate ④ predicates over a request config object
 * (both report ALL findings at once, never fail-fast — design §5.2).
 * @returns {{unknownFields: string[], fieldErrors: {path: string, value: string, reason: string}[]}}
 */
export function validateSearchConfigPatch(config) {
  const unknownFields = []
  for (const key of Object.keys(config)) {
    if (!KNOWN_TOP_KEYS.has(key)) unknownFields.push(key)
  }
  if (isPlainObject(config.recallers)) {
    for (const key of Object.keys(config.recallers)) {
      if (key !== 'lexical' && key !== 'vector') unknownFields.push(`recallers.${key}`)
    }
    for (const section of ['lexical', 'vector']) {
      const node = config.recallers[section]
      if (!isPlainObject(node)) continue
      for (const key of Object.keys(node)) {
        if (!KNOWN_SECTION_KEYS[section].has(key)) unknownFields.push(`recallers.${section}.${key}`)
      }
    }
  }
  const fieldErrors = []
  for (const def of FIELD_DEFS) {
    if (!hasPath(config, def.path)) continue
    const value = getPath(config, def.path)
    if (!FIELD_VALIDATORS[def.validator](value)) {
      fieldErrors.push({ path: def.path, value: truncateValue(value), reason: VALIDATOR_REASONS[def.validator] })
    }
  }
  return { unknownFields, fieldErrors }
}

/**
 * Merge chain (design §2): built-in defaults ← current effective ← request
 * values. The result is ALWAYS the full 14-field snapshot that gets written.
 * Callers must pass a patch that already cleared validateSearchConfigPatch.
 */
export function mergeSearchConfigPatch(effective, patch) {
  const merged = cloneConfig(effective)
  for (const def of FIELD_DEFS) {
    if (hasPath(patch, def.path)) setPath(merged, def.path, getPath(patch, def.path))
  }
  return merged
}

/**
 * Atomic write (design §9.1): mkdir → tmp file in the SAME directory (same
 * volume ⇒ rename is atomic) → rename over the target. On failure the tmp
 * file is best-effort unlinked and the ORIGINAL file stays untouched.
 * @returns {{path: string, bytes: number, writtenAt: string}}
 */
export function writeSearchConfigAtomic(context, merged) {
  const targetDir = join(context.rddRoot, 'exploration')
  const target = join(targetDir, 'search-config.json')
  const tmp = join(targetDir, `search-config.json.${process.pid}.tmp`)
  const body = `${JSON.stringify(merged, null, 2)}\n`
  try {
    mkdirSync(targetDir, { recursive: true })
    writeFileSync(tmp, body, 'utf8')
    renameSync(tmp, target)
  } catch (error) {
    try {
      unlinkSync(tmp)
    } catch {
      /* best effort — the error below is the actionable one */
    }
    throw error
  }
  return { path: target, bytes: Buffer.byteLength(body, 'utf8'), writtenAt: new Date().toISOString() }
}

// ── the reader itself ──────────────────────────────────────────────────

/** L1 rows — observed from THIS process; the APIKEY row has NO value field. */
function readL1() {
  return {
    observedFrom: 'dashboard-process',
    vars: L1_VAR_NAMES.map((name) => {
      const raw = process.env[name]
      const set = typeof raw === 'string' && raw !== ''
      if (name === 'RDD_EMBED_APIKEY') return { name, set, masked: true }
      return { name, set, value: set ? raw : null }
    }),
  }
}

/** L5 existence probes against the current project root. */
function readL5(context) {
  return {
    probes: L5_PROBES.map((probe) => {
      let exists = false
      try {
        statSync(join(context.projectRoot, probe.path))
        exists = true
      } catch {
        exists = false
      }
      return { path: probe.path, role: probe.role, exists }
    }),
    infoOnly: L5_INFO_ONLY,
  }
}

/**
 * Read the whole config domain (all five layers, fully fault-tolerant).
 * @param {{rddRoot: string, projectRoot: string}} context
 */
export function readConfig(context) {
  const env = makeEnvelope(DOMAIN, SOURCE)
  env.available = true
  const notes = []
  const filePath = searchConfigPath(context)
  const parsed = readJson(filePath)
  const fileExists = !parsed.missing
  const parseError = parsed.error
  const fileObject = isPlainObject(parsed.value) ? parsed.value : null
  if (parseError !== null) {
    notes.push(`search-config.json 损坏，引擎已 fail-soft 回内置默认（${parseError}）。保存任意值即可修复为合法完整文件。`)
  } else if (parsed.value !== null && !isPlainObject(parsed.value)) {
    notes.push('search-config.json 不是 JSON 对象，引擎按全默认处理。保存任意值即可修复为合法完整文件。')
  } else if (fileObject !== null && fileObject.recallers !== undefined && !isPlainObject(fileObject.recallers)) {
    notes.push('search-config.json 的 recallers 不是对象，引擎忽略该节（字段全部按默认生效）。')
  }
  const effective = effectiveFrom(fileObject)
  const fields = buildFields(fileObject)
  const l5 = readL5(context)
  env.data = {
    l1: readL1(),
    l2: {
      filePath,
      fileExists,
      parseError,
      defaults: cloneConfig(SEARCH_CONFIG_DEFAULTS),
      effective,
      fields,
      unknownKeys: collectUnknownKeys(fileObject),
      nonDefaultCount: fields.filter((field) => field.state !== 'unset').length,
      vectorReadiness: computeVectorReadiness(effective),
    },
    l3: L3_TABLE,
    l4: L4_TABLE,
    l5,
    modules: buildModules(l5),
    ux: readUx(context),
  }
  env.meta.notes = env.meta.notes.concat(notes)
  return env
}

// ── R2: functional modules (design ops-config-panel-r2 §2/§3) ──────────
//
// Single source for the module reorganisation: 8 modules in display order,
// each item mapped to EXACTLY ONE module with plain-language layer labels
// (环境变量/调参文件/冻结常量/命令行参数/生态配置文件 — never L1–L5 jargon).
// The consumers wording doubles as the rendered annotation (§4.1) and the
// POST-side cross-module judgement consumes CROSS_MODULE_PATHS below.

/**
 * The engine version shown on the shared module row (n5 D2): read at import
 * time from THIS engine's own package.json — the path derives from this
 * module's location (dashboard/lib/readers → the engine root is dashboard's
 * parent), so the row always reports the running engine's real version,
 * never a hardcoded mirror that drifts on bumps.
 */
function readEngineVersion() {
  try {
    const parsed = JSON.parse(readFileSync(fileURLToPath(new URL('../../../package.json', import.meta.url)), 'utf8'))
    return typeof parsed.version === 'string' && parsed.version !== '' ? parsed.version : '未知'
  } catch {
    return '未知' // unreadable/missing package.json: honest placeholder, never a fake version
  }
}

const ENGINE_VERSION = readEngineVersion()

export const MODULE_DEFS = [
  {
    key: 'shared',
    title: '跨模块公用配置',
    subtitle: '引擎与数据落点的定位变量：引擎装在哪（RDD_ENGINE_HOME）、项目数据落在哪（RDD_PROJECT_ROOT）。被几乎所有引擎命令共同消费——改动影响全部命令的定位行为，仅在启动 shell 前设置才生效，本页只读。',
    items: [
      { item: 'RDD_ENGINE_HOME', layer: '环境变量', editable: false, crossModule: true, consumers: ['所有引擎 CLI 的 $rdd 定位：三级定位链①，嵌入全部角色 SKILL 与 dsh preset 的调用 snippet（不在引擎脚本内）'] },
      { item: 'RDD_PROJECT_ROOT', layer: '环境变量', editable: false, crossModule: true, consumers: ['9 个数据面脚本的 Resolve-RepoRoot 根定位链（explore / explore-store / goal-tree / goal-tree-leaf / delivery-bridge / rdd-flow / start-role / sync-ux-subagents / tips）', '看板 Node 侧 resolveDataRoot（paths.mjs）'] },
      { item: '.rdd/install.json', layer: '生态配置文件', editable: false, crossModule: true, probe: '.rdd/install.json', consumers: ['非 git 项目根锚点（定位链④；本仓预期不存在）'] },
      { item: '~/.rdd/engine/manifest.json', layer: '生态配置文件', editable: false, crossModule: true, infoOnly: true, consumers: ['用户级安装版本账本（current junction 指针，定位链③；用户级文件，不在数据根内，仅列示）'] },
      { item: `rdd-engine/package.json（引擎版本 ${ENGINE_VERSION}）`, layer: '生态配置文件', editable: false, infoOnly: true, consumers: ['引擎版本账本（package 元数据；rdd-flow -Command version 读它报告版本，安装器自检/诊断用——非用户可调配置）'] },
    ],
  },
  {
    key: 'search',
    title: '探索检索与缓存向量化',
    subtitle: '「rdd explore」代码搜索的调参与开关：词法 BM25 + 向量双路召回、RRF 融合，以及探索缓存写入向量时的同一套向量配置。改这里影响所有代码探索的召回结果与缓存向量化行为；文件 .rdd/exploration/search-config.json，保存即全量生效（下次检索起）。',
    items: [
      { item: 'search-config.json：topK / recallDepth / rrfK', layer: '调参文件', editable: true, consumers: ['explore.ps1 检索合并（Read-SearchConfig）', 'dsh 插件 TS 侧同款读取'] },
      { item: 'recallers.lexical.*（enabled / weight / bm25K1 / bm25B）', layer: '调参文件', editable: true, consumers: ['recallers/lexical.ps1（BM25 参数）', 'dsh 插件 TS 侧'] },
      { item: 'recallers.vector.*（enabled / weight / endpoint / model / dimensions / minCosine / timeoutSeconds）', layer: '调参文件', editable: true, crossModule: true, consumers: ['检索召回（recallers/vector.ps1 AutoReady 四要素 + F5/F6）', '缓存向量化（explore-store.ps1 Test-EmbedVectorConfig / register 的 embed / embed-backfill）', 'dsh 插件 TS 侧'] },
      { item: 'RDD_EMBED_APIKEY', layer: '环境变量', editable: false, crossModule: true, consumers: ['向量检索召回（vector.ps1，仅显已设/未设）', '缓存向量化（explore-store.ps1 register / embed-backfill；缺失时 fail-loud EMBED_CONFIG_INCOMPLETE）'] },
      { item: '向量路就绪卡（四要素判定）', layer: '派生展示', editable: false, consumers: ['endpoint 非空 + model 非空 + dimensions≥1 + env APIKEY 非空（rankMeta.warning 同口径）'] },
      { item: '热区保留期 7 天 / 热区容量 50', layer: '冻结常量', editable: false, consumers: ['explore-store.ps1 $HotRetentionDays / $HotCapacity（sweep 到期保底转正 / 溢出最旧转正）'] },
      { item: 'F1–F8 检索公式冻结契约', layer: '冻结常量', editable: false, consumers: ['explore.ps1 / recallers/*.ps1 与 dsh 插件 cache.ts 双侧字面镜像（tests/search-ranking.mjs 回归）'] },
      { item: 'PurgeOtherModels（embed-backfill 换模型清旧向量）', layer: '命令行参数', editable: false, consumers: ['explore-store.ps1'] },
      { item: '.opencode/agent/rdd-explore.md', layer: '生态配置文件', editable: false, probe: '.opencode/agent/rdd-explore.md', consumers: ['opencode 运行时（可写探索 worker 定义；permission：edit 仅 allow .rdd/exploration/**）'] },
    ],
  },
  {
    key: 'delivery',
    title: '交付编排（goal-tree / delivery-bridge）',
    subtitle: '长程任务树与交付桥接的预算和开关默认值：轮数/宽度/节点数上限、派生上限、评审与自动模式。只影响新发起的 run（参数在启动时固化进 manifest/bridge，运行中不可变），已在跑的任务不受影响。',
    items: [
      { item: 'goal-tree：MaxRounds 5（1–1000）/ NodeWidth 4（1–100）/ MaxNodes 30（1–10000）/ GoalRoot off（switch，goal-root 模式：根为不可认领 conclude 锚点）/ GateMode warn|enforce / CoverageToleranceS 0', layer: '命令行参数', editable: false, consumers: ['goal-tree.ps1 start（预算固化进 manifest.json budget，运行期只读；derive 超预算报 DERIVE_BUDGET_EXCEEDED；GoalRoot 与 -GoalFile 成对，建树时决定根节点是否升格为 type=goal 终局锚）'] },
      { item: 'goal-tree-leaf：Command="next" / Limit=0（0=不截断）', layer: '命令行参数', editable: false, consumers: ['goal-tree-leaf.ps1（worker 消费面）'] },
      { item: 'delivery-bridge：MaxRounds 12 / NodeWidth auto（≥任务数，floor 4）/ MaxNodes auto（任务数×5+6+评审派生余量）/ MaxDerivations 3（超限仅 WARNING）/ ReviewMode / AutoMode / RiskPolicy / NoPush / NoReuse / CreatedBy="planner"', layer: '命令行参数', editable: false, consumers: ['delivery-bridge.ps1 promulgate 预算与模式开关（固化 bridge.json；AutoMode 快照风险分级表）'] },
    ],
  },
  {
    key: 'handoff',
    title: '会话交接与运行时',
    subtitle: '角色会话怎么被拉起、开在哪里：运行时判据链（Plus / dsh / CLI 三后端选择）、任务路由输出格式、dsh preset 与 opencode 客户端配置。改这里影响下一个角色会话的后端选择与交接行为。',
    items: [
      { item: 'RDD_RUNTIME', layer: '环境变量', editable: false, consumers: ['start-role.ps1 Resolve-RuntimeMode 判据链①（=app → Plus 后端；判据链固定 RDD_RUNTIME→DSH_WEB_URL→CLI，防泄漏标记劫持）'] },
      { item: 'DSH_WEB_URL', layer: '环境变量', editable: false, crossModule: true, consumers: ['start-role.ps1（交接后端判定②，非空→dsh 后端）', 'delivery-bridge.ps1（会话活性检查）'] },
      { item: 'start-role：TaskId=-1 / PlusUrl="http://127.0.0.1:8000" / DshUrl=""（空→回退 env）', layer: '命令行参数', editable: false, consumers: ['start-role.ps1 会话拉起'] },
      { item: 'rdd-flow：Command="handoff" / Role="DEV" / Format="json"|"markdown"', layer: '命令行参数', editable: false, consumers: ['rdd-flow.ps1 任务路由与 handoff 输出'] },
      { item: 'dsh/presets/（rdd-<role>/preset.yml + agent.cordis.yml）', layer: '生态配置文件', editable: false, probe: 'dsh/presets/', consumers: ['start-role dsh 后端 agentPreset=rdd-<role>（经 agentPreset.list 预检）'] },
      { item: 'opencode.json', layer: '生态配置文件', editable: false, probe: 'opencode.json', consumers: ['opencode 客户端 instructions（docs/code-quality.md）'] },
    ],
  },
  {
    key: 'metrics',
    title: '代码度量阈值',
    subtitle: 'code-metrics 质量扫描的违规判定阈值：单函数最大行数、最大嵌套深度。改这里影响扫描报告的违规计数与质量卡口径。',
    items: [
      { item: 'code-metrics：Command="scan" / Base="HEAD" / MaxFunctionLines=50（1–10000）/ MaxNestingDepth=5（1–100）', layer: '命令行参数', editable: false, consumers: ['code-metrics.ps1 违规判定阈值'] },
    ],
  },
  {
    key: 'tips',
    title: '经验记录（tips）冻结约定',
    subtitle: '项目经验条目的记录格式与可记录角色。零配置设计——格式与白名单冻结在代码里，改动=改代码（No config file, no env var）。',
    items: [
      { item: 'TipSchema rdd-tip/1', layer: '冻结常量', editable: false, consumers: ['tips.ps1（记录格式版本）'] },
      { item: 'Tips 记录角色白名单（9 角色）', layer: '冻结常量', editable: false, consumers: ['tips.ps1 $RecorderRoles（嵌入式白名单，零配置设计：No config file, no env var）'] },
    ],
  },
  {
    key: 'ux',
    title: 'UX 视觉稿子代理',
    subtitle: 'UX 出视觉稿时派遣的子代理（ux-mockup-a/b/c…）各绑定哪个模型、什么温度、擅长什么。改这里影响视觉稿的生成质量与多方向差异化；保存后自动同步 .opencode/agent/ 并需重启 opencode 才生效。',
    items: [
      { item: 'rdd-ux/ux_subagent.json 的 agents[]（name / model / temperature / capability / note）', layer: '生态配置文件', editable: true, probe: 'rdd-ux/ux_subagent.json', consumers: ['sync-ux-subagents.ps1 读它 Create/Update/Delete .opencode/agent/ux-mockup-*.md → opencode 运行时', 'UX fork-join 派遣按条目数选方向子集（rules.count）'] },
      { item: 'managed[] 清单', layer: '生态配置文件', editable: false, consumers: ['sync 脚本所有权账本（Create 追加 / Delete 移除；防误删用户手建 agent）——单一写者，编辑器不碰'] },
      { item: '.opencode/agent/ux-mockup-*.md（同步产物，请勿手改——改了也被下次同步覆盖）', layer: '生态配置文件', editable: false, probe: '.opencode/agent/', consumers: ['opencode 运行时（frontmatter model/temperature 生效）'] },
    ],
  },
  {
    key: 'dashboard',
    title: '看板自身',
    subtitle: '本看板服务的启动默认值：端口与监听地址（仅本机）。改这里影响下次启动看板用的端口，对引擎其他功能零影响。',
    items: [
      { item: 'dashboard：端口 8787（CLI -Port/--port/-p 覆盖，1–65535）/ HOST 固定 127.0.0.1', layer: '命令行参数', editable: false, consumers: ['server.mjs 启动参数'] },
    ],
  },
]

/**
 * The cross-module vector paths (design §4.2): touching any of these with a
 * save triggers the three-layer reminder (hint + confirm + impact notice).
 * Client-side the set ships via data-cross-module attributes — never copied.
 */
export const CROSS_MODULE_PATHS = [
  'recallers.vector.enabled',
  'recallers.vector.weight',
  'recallers.vector.endpoint',
  'recallers.vector.model',
  'recallers.vector.dimensions',
  'recallers.vector.minCosine',
  'recallers.vector.timeoutSeconds',
]

/**
 * Machine-readable module metadata + the flat item list with probe results
 * merged in (design §6.3): view rendering and the page footer count share it.
 */
function buildModules(l5) {
  const probeByPath = new Map(l5.probes.map((probe) => [probe.path, probe.exists]))
  const defs = MODULE_DEFS.map((module, index) => ({ key: module.key, title: module.title, subtitle: module.subtitle, order: index + 1 }))
  const items = []
  for (const module of MODULE_DEFS) {
    for (const entry of module.items) {
      const row = { item: entry.item, module: module.key, layer: entry.layer, editable: entry.editable === true, consumers: [...entry.consumers], crossModule: entry.crossModule === true }
      if (entry.probe !== undefined) row.probe = entry.probe
      if (entry.probe !== undefined) row.exists = probeByPath.get(entry.probe) === true
      if (entry.infoOnly === true) row.infoOnly = true
      items.push(row)
    }
  }
  return { defs, items }
}

/**
 * The vector paths a save actually CHANGED (r2 §4.2 ③): server-side diff =
 * paths present in the patch whose submitted value differs from the currently
 * effective value, intersected with CROSS_MODULE_PATHS. Null when empty —
 * the POST response then carries no impact key at all (R1 superset rule).
 */
export function crossModuleImpact(effective, patch) {
  const changed = CROSS_MODULE_PATHS.filter((path) => hasPath(patch, path) && getPath(patch, path) !== getPath(effective, path))
  return changed.length === 0 ? null : { crossModuleFields: changed }
}

// ── R2: UX subagent editor — validation, read probe, atomic write ──────

/** name must be a stable executor id the sync script's disk scan can match. */
const UX_NAME_RE = /^ux-mockup-[a-z0-9]([-a-z0-9]*[a-z0-9])?$/
const UX_AGENT_KEYS = ['name', 'model', 'temperature', 'capability', 'note']
const UX_AGENT_LIMITS = { name: 40, model: 200, capability: 100, note: 200 }

/** Skeleton used when the original file is missing/corrupt (design §5.3 ⑤). */
const UX_SKELETON_RULES = {
  count: 'agents 条目数 = 可用执行器数量。fork-join 默认派 3 个方向，若条目 <3 则部分方向会复用同一 model（差异化退化，UX 派遣时应提示用户）；条目 >3 时 UX 按需求选定参与 fork-join 的子集。',
  managed: 'managed 列表记录本系统（sync 脚本）创建过所有权的全部 agent name。只有在此列表中的 agent 才允许被脚本删除——这是防止误删用户手建 agent 的安全机制。脚本 Create 时追加 name，Delete 时移除 name。',
  decoupling: '方向（信息/任务/体验优先等）不绑定到本文件。方向由 UX 在 mockup-generation.md 定义并在 dispatch 简报中动态注入到执行器。本文件只管 model 层。',
  fallback: '换 provider 导致 model 不可用时：① 编辑本文件 agents 替换为 provider 可用 model（按 capability 就近匹配）；② 运行 sync-ux-subagents.cmd 同步 agent 定义；③ 重启 opencode。若要废弃某执行器：从 agents 删除该条目（保留在 managed 里），再跑脚本，脚本会自动删除对应 .md。',
}
const UX_SKELETON_COMMENT =
  'UX 视觉稿生成子代理的 model 清单。这是单一真相源——本文件定义了哪些 subagent 可用、各自绑定哪个 model。修改本文件后运行 rdd-engine/scripts/sync-ux-subagents.cmd 完成同步（脚本自动 Create/Update/Delete 对应的 .opencode/agent/*.md），然后重启 opencode（见 rdd-ux/references/mockup-generation.md「子代理配置维护」）。'

/** The file path of the UX subagent list inside the current project root. */
export function uxSubagentsPath(context) {
  return join(context.projectRoot, 'rdd-ux', 'ux_subagent.json')
}

/**
 * Gate ③ unknown keys + gate ④ predicates over a request body whose shape
 * already cleared (design §5.2). All findings at once, never fail-fast.
 * @returns {{unknownFields: string[], fieldErrors: {path: string, value: string, reason: string}[], countError: string|null}}
 */
export function validateUxAgents(payload) {
  const unknownFields = []
  for (const key of Object.keys(payload)) {
    if (key !== 'agents') unknownFields.push(key)
  }
  const agents = payload.agents
  const fieldErrors = []
  const seenNames = new Map()
  for (let index = 0; index < agents.length; index += 1) {
    const entry = agents[index]
    const at = `agents[${index}]`
    for (const key of Object.keys(entry)) {
      if (!UX_AGENT_KEYS.includes(key)) unknownFields.push(`${at}.${key}`)
    }
    const name = entry.name
    if (typeof name !== 'string' || name.trim() === '') fieldErrors.push({ path: `${at}.name`, value: truncateValue(name), reason: '需非空字符串（ux-mockup-<小写字母/数字> 前缀）' })
    else if (name.length > UX_AGENT_LIMITS.name) fieldErrors.push({ path: `${at}.name`, value: truncateValue(name), reason: '长度需 ≤40 字符' })
    else if (!UX_NAME_RE.test(name)) fieldErrors.push({ path: `${at}.name`, value: truncateValue(name), reason: '需匹配 ux-mockup-<小写字母/数字>（如 ux-mockup-a）——不合前缀的 name 永远同步不收敛' })
    else if (seenNames.has(name)) fieldErrors.push({ path: `${at}.name`, value: truncateValue(name), reason: `agents 内重名（与 agents[${seenNames.get(name)}]）` })
    else seenNames.set(name, index)
    pushUxFieldError(fieldErrors, at, entry, 'model', (v) => typeof v === 'string' && v.trim() !== '' && v.length <= UX_AGENT_LIMITS.model, '需非空字符串（trim 后）且 ≤200 字符')
    pushUxFieldError(fieldErrors, at, entry, 'temperature', (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 2, '需数值且 0≤值≤2')
    pushUxFieldError(fieldErrors, at, entry, 'capability', (v) => typeof v === 'string' && v !== '' && v.length <= UX_AGENT_LIMITS.capability, '需非空字符串且 ≤100 字符')
    if (entry.note !== undefined) pushUxFieldError(fieldErrors, at, entry, 'note', (v) => typeof v === 'string' && v.length <= UX_AGENT_LIMITS.note, '需字符串且 ≤200 字符')
  }
  const countError = agents.length < 1 || agents.length > 12 ? 'agents 条目数需在 1–12 之间（空清单=删除全部，请走手工路径）。' : null
  return { unknownFields, fieldErrors, countError }
}

/** Append one predicate error when the field is present and fails. */
function pushUxFieldError(errors, at, entry, field, predicate, reason) {
  if (entry[field] === undefined) return
  if (!predicate(entry[field])) errors.push({ path: `${at}.${field}`, value: truncateValue(entry[field]), reason })
}

/** Merge keeping $schema/comment/managed/rules verbatim (design §5.3 ⑤). */
export function mergeUxAgents(originalParsed, agents) {
  const base = isPlainObject(originalParsed) ? originalParsed : {}
  return {
    $schema: typeof base.$schema === 'string' ? base.$schema : 'ux-subagent-config',
    comment: typeof base.comment === 'string' ? base.comment : UX_SKELETON_COMMENT,
    agents,
    managed: Array.isArray(base.managed) ? base.managed : [],
    rules: isPlainObject(base.rules) ? base.rules : UX_SKELETON_RULES,
  }
}

/** Atomic write for the UX list — same five-step sequence as search-config. */
export function writeUxSubagentsAtomic(context, fullObject) {
  const targetDir = join(context.projectRoot, 'rdd-ux')
  const target = join(targetDir, 'ux_subagent.json')
  const tmp = join(targetDir, `ux_subagent.json.${process.pid}.tmp`)
  const body = `${JSON.stringify(fullObject, null, 2)}\n`
  try {
    mkdirSync(targetDir, { recursive: true })
    writeFileSync(tmp, body, 'utf8')
    renameSync(tmp, target)
  } catch (error) {
    try {
      unlinkSync(tmp)
    } catch {
      /* best effort — the error below is the actionable one */
    }
    throw error
  }
  return { path: target, bytes: Buffer.byteLength(body, 'utf8'), writtenAt: new Date().toISOString() }
}

/** Mirror of the script's Get-AgentField: one flat frontmatter line, trimmed. */
function agentFrontmatterField(content, field) {
  const block = /^---\r?\n([\s\S]*?)\r?\n---/.exec(content)
  if (block === null) return null
  for (const line of block[1].split(/\r?\n/)) {
    const match = new RegExp(`^\\s*${field}\\s*:`).exec(line)
    if (match !== null) return line.replace(new RegExp(`^\\s*${field}\\s*:\\s*`), '').trim()
  }
  return null
}

/** Scan .opencode/agent for ux-mockup-*.md and read frontmatter fields. */
function probeDiskAgents(context) {
  const agentDir = join(context.projectRoot, '.opencode', 'agent')
  return listFiles(agentDir, (name) => /^ux-mockup-.*\.md$/.test(name)).map((file) => {
    let model = null
    let temperature = null
    try {
      const raw = readFileSync(file.path, 'utf8')
      // The sync script writes .md files WITH a UTF-8 BOM ($utf8Bom) — strip
      // it or the leading '---' anchor never matches (readText semantics).
      const content = raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw
      model = agentFrontmatterField(content, 'model')
      temperature = agentFrontmatterField(content, 'temperature')
    } catch {
      /* unreadable file: report as present with unknown fields (drift) */
    }
    return { name: file.name.replace(/\.md$/, ''), exists: true, model, temperature }
  })
}

/** The per-agent sync verdicts (design §5.1 probe-state table). */
function buildSyncStatus(agents, managed, disk) {
  const diskByName = new Map(disk.map((entry) => [entry.name, entry]))
  const perAgent = []
  for (const agent of agents) {
    if (!isPlainObject(agent) || typeof agent.name !== 'string') continue
    const onDisk = diskByName.get(agent.name)
    if (onDisk === undefined) {
      perAgent.push({ name: agent.name, state: 'pending-sync', detail: '磁盘无对应 .md（保存或运行同步即创建）' })
      continue
    }
    const diffs = []
    if (onDisk.model !== agent.model) diffs.push(`model: ${onDisk.model ?? '（无）'} -> ${agent.model}`)
    const tempText = typeof agent.temperature === 'number' ? String(agent.temperature) : String(agent.temperature)
    if (onDisk.temperature !== tempText) diffs.push(`temperature: ${onDisk.temperature ?? '（无）'} -> ${tempText}`)
    perAgent.push(diffs.length === 0 ? { name: agent.name, state: 'synced', detail: '' } : { name: agent.name, state: 'pending-sync', detail: `字段不一致（${diffs.join('; ')}）` })
  }
  const agentNames = new Set(agents.filter((agent) => isPlainObject(agent)).map((agent) => agent.name))
  for (const name of managed) {
    if (!agentNames.has(name) && diskByName.has(name)) {
      perAgent.push({ name, state: 'pending-clean', detail: '已从清单移除，跑同步即删' })
    }
  }
  for (const entry of disk) {
    if (!agentNames.has(entry.name) && !managed.includes(entry.name)) {
      perAgent.push({ name: entry.name, state: 'orphan', detail: '非本系统管理，脚本跳过' })
    }
  }
  const state = perAgent.every((row) => row.state === 'synced') ? 'synced' : 'drift'
  return { state, perAgent }
}

/**
 * Read the UX subagent domain: the json single source + the disk probe +
 * the sync verdicts. Fully fault-tolerant (missing/corrupt → unknown).
 * @param {{projectRoot: string}} context
 */
export function readUx(context) {
  const filePath = uxSubagentsPath(context)
  const parsed = readJson(filePath)
  const fileExists = !parsed.missing
  const parseError = parsed.error
  const object = isPlainObject(parsed.value) ? parsed.value : null
  const agentsRaw = object !== null && Array.isArray(object.agents) ? object.agents : []
  const managed = object !== null && Array.isArray(object.managed) ? object.managed.filter((name) => typeof name === 'string') : []
  const disk = probeDiskAgents(context)
  const unknown = object === null
  return {
    filePath,
    fileExists,
    parseError,
    agents: agentsRaw,
    managed,
    rules: object !== null && isPlainObject(object.rules) ? object.rules : UX_SKELETON_RULES,
    disk,
    syncStatus: unknown ? { state: 'unknown', perAgent: [] } : buildSyncStatus(agentsRaw, managed, disk),
  }
}

// Config centre view (#/config) — ops-config-panel-r2 design §2/§3/§5.
//
// The page is organised by FUNCTIONAL MODULE (eight panels, MODULE_DEFS is
// the single source) instead of the engine's internal layering; every row
// carries a plain-language layer chip (环境变量/调参文件/…, never L1–L5).
// Everything renders server-side: module tables, the tuning-file comparison
// table, the edit form AND the UX subagent editor are in the served HTML, so
// a no-JS reader sees every value (saving needs JavaScript, as in R1).
import { badge, chip, dataTable, noteBar, panel } from '../components.mjs'
import { esc } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { CROSS_MODULE_PATHS, FIELD_DEFS, MODULE_DEFS } from '../readers/config.mjs'
import { notesBlock } from './shared.mjs'

/** Render one JSON-ish config value for the comparison table. */
function valueText(value) {
  if (value === null || value === undefined) return '—'
  if (typeof value === 'string') return value === '' ? '""' : value
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

/** The two declaration lines every config page opens with (r2 §6.4 markers). */
function declarationBars() {
  return [
    noteBar({
      variant: 'info',
      badge: '写边界',
      text: '本页两个可写点：.rdd/exploration/search-config.json（检索调参，POST 校验后原子写入）与 rdd-ux/ux_subagent.json（UX 子代理清单，保存后自动触发同步脚本）；其余配置全部只读。',
    }),
    noteBar({
      variant: 'info',
      badge: '观测点',
      text: '环境变量与向量路就绪性以看板进程环境为观测点；引擎 CLI 在其他 shell 中的环境可能不同。',
    }),
  ].join('')
}

/** Observed environment-variable rows for one module (APIKEY never echoes). */
function envValueTable(vars, names, title) {
  const rows = vars
    .filter((entry) => names.includes(entry.name))
    .map((entry) => ({
      cells: [
        { text: entry.name, mono: true },
        { html: entry.set ? badge('已设置', 'success') : badge('未设', 'neutral') },
        entry.name === 'RDD_EMBED_APIKEY'
          ? { text: entry.set ? '已设置（不回显）' : '未设', muted: !entry.set }
          : { text: entry.set ? entry.value : '未设', mono: entry.set, muted: !entry.set },
      ],
    }))
  return panel({
    title,
    note: '观测点：看板进程环境',
    html: dataTable({ columns: [{ label: '变量' }, { label: '状态' }, { label: '值' }], rows }),
    foot: '密钥类变量只显示存在性，绝不回显值。',
  })
}

/** One module's read-only item table: item / layer chip / writability / consumers (+probe). */
function moduleItemsTable(module) {
  const rows = module.items.map((entry) => ({
    cells: [
      { html: `${esc(entry.item)}${entry.crossModule === true ? ` ${badge('公用', 'info')}` : ''}` },
      { html: chip(entry.layer) },
      { html: entry.editable === true ? badge('可写', 'info') : badge('只读', 'neutral') },
      { text: entry.consumers.join('；') },
      {
        html:
          entry.infoOnly === true
            ? badge('不探测', 'neutral')
            : entry.probe === undefined
              ? '<span class="td-muted">—</span>'
              : entry.exists === true
                ? badge('存在', 'success')
                : badge('不存在', 'neutral'),
      },
    ],
  }))
  return dataTable({
    columns: [{ label: '配置项' }, { label: '层' }, { label: '可写性' }, { label: '消费方' }, { label: '探测' }],
    rows,
  })
}

/** Tuning-file state line (path + existence chip; corruption via notes). */
function l2StatePanel(l2) {
  const existsChip = l2.fileExists ? chip('文件存在') : chip('文件不存在（全默认生效）')
  const rows = [
    {
      cells: [
        { text: l2.filePath, mono: true },
        { html: existsChip },
        {
          text:
            l2.parseError !== null
              ? '文件损坏，引擎已 fail-soft 回内置默认'
              : `未知键 ${l2.unknownKeys.length} 个 · 非默认字段 ${l2.nonDefaultCount} 个`,
          muted: true,
        },
      ],
    },
  ]
  return panel({
    title: 'search-config.json 状态',
    note: '引擎读侧 fail-soft：缺失/损坏/非法值 → 回内置默认',
    html: dataTable({ columns: [{ label: '文件路径' }, { label: '存在性' }, { label: '概况' }], rows }),
    foot:
      l2.unknownKeys.length > 0
        ? `引擎会静默忽略未知键：${l2.unknownKeys.map((key) => esc(key)).join('、')}（编辑保存时会将其清除——落盘为完整 14 字段快照）。`
        : undefined,
  })
}

/** The core 14-row × 5-column comparison table. */
function l2ComparePanel(l2) {
  const stateBadge = { unset: ['默认', 'neutral'], set: ['覆盖', 'info'], invalid: ['非法', 'error'] }
  const rows = l2.fields.map((field) => {
    const [label, tone] = stateBadge[field.state]
    const fileCell =
      field.state === 'unset'
        ? { text: '—', muted: true }
        : { text: valueText(field.fileValue), mono: true, muted: field.state === 'invalid', title: field.state === 'invalid' ? '该值不过引擎谓词，引擎按默认值运行' : undefined }
    return {
      cells: [
        { text: field.path, mono: true },
        fileCell,
        { text: valueText(field.default), mono: true, muted: true },
        { text: valueText(field.effective), mono: true },
        { html: field.state === 'invalid' ? badge(`${label}→默认`, tone) : badge(label, tone) },
      ],
    }
  })
  return panel({
    title: '调参字段对比（核心）',
    note: `${l2.nonDefaultCount}/14 非默认`,
    html: dataTable({
      columns: [{ label: '字段' }, { label: '文件值' }, { label: '内置默认' }, { label: '生效值' }, { label: '状态' }],
      rows,
    }),
    foot: '状态：默认=文件无此键；覆盖=文件值合法并生效；非法=文件值不过引擎谓词，生效值回内置默认（「所见即所跑」以生效值列为准）。',
  })
}

/** Vector-path readiness card (auto four-factor rule) — R1 component kept. */
function l2VectorPanel(readiness) {
  const factorNames = { endpoint: 'endpoint', model: 'model', dimensions: 'dimensions', apikey: 'RDD_EMBED_APIKEY' }
  const missingText = readiness.missing.map((factor) => factorNames[factor]).join('、')
  const enabledChip = `enabled = ${typeof readiness.enabled === 'string' ? `"${readiness.enabled}"` : readiness.enabled}`
  let bar
  if (readiness.enabled === false) {
    bar = noteBar({ variant: 'info', text: `向量路已手动关闭（enabled=false），四要素判定：${missingText === '' ? '齐备' : `缺 ${missingText}`}。` })
  } else if (readiness.enabled === 'auto') {
    bar = readiness.ready
      ? noteBar({ variant: 'success', text: '向量路 auto 模式：四要素齐备，检索时自动启用。' })
      : noteBar({ variant: 'warn', text: `向量路 auto 模式：缺失 ${missingText}，自动停用（rankMeta.warning 同口径）。` })
  } else {
    bar = readiness.ready
      ? noteBar({ variant: 'success', text: '向量路强制启用（enabled=true）：四要素齐备。' })
      : noteBar({ variant: 'error', text: `向量路强制启用（enabled=true）但四要素缺失：${missingText}——引擎仍会尝试调用，预期请求失败。` })
  }
  return panel({
    title: '向量路就绪性',
    note: enabledChip,
    html: `${bar}<p class="prose">四要素 = endpoint 非空 + model 非空 + dimensions≥1 + 环境变量 RDD_EMBED_APIKEY 非空；观测点为看板进程环境（${esc(readiness.observedFrom)}）。</p>`,
  })
}

/** One form row: label + input/select + hint, with data-original (client diff)
 *  and data-cross-module (the vector seven, r2 §4.2) attributes. */
function formRow(def, effective) {
  const id = `cfg-${def.path.replace(/\./g, '-')}`
  const original = typeof effective === 'string' ? effective : String(effective)
  const cross = CROSS_MODULE_PATHS.includes(def.path) ? ' data-cross-module="1"' : ''
  const common = `id="${esc(id)}" name="${esc(def.path)}" data-config-field="1" data-original="${esc(original)}"${cross}`
  let control
  if (def.validator === 'isEnabled') {
    const current = typeof effective === 'string' ? effective : String(effective)
    control = `<select class="config-input" ${common} data-config-type="enabled">${['true', 'false', 'auto']
      .map((option) => `<option value="${option}"${option === current ? ' selected' : ''}>${option}</option>`)
      .join('')}</select>`
  } else if (def.validator === 'isString') {
    control = `<input class="config-input" type="text" ${common} data-config-type="string" value="${esc(effective)}" spellcheck="false">`
  } else {
    control = `<input class="config-input" type="text" ${common} data-config-type="number" value="${esc(effective)}" inputmode="decimal">`
  }
  return `<div class="config-field"><label class="config-label" for="${esc(id)}">${esc(def.label)}</label>${control}<span class="config-hint">${esc(def.hint)}</span></div>`
}

/** The tuning-file edit form — three groups + the always-on vector hint (r2 ①). */
function l2FormPanel(l2) {
  const effective = l2.effective
  const groups = [
    { title: '全局', paths: ['topK', 'recallDepth', 'rrfK'] },
    { title: '词法路', paths: ['recallers.lexical.enabled', 'recallers.lexical.weight', 'recallers.lexical.bm25K1', 'recallers.lexical.bm25B'] },
    { title: '向量路（公用：检索召回 + 缓存向量化）', paths: ['recallers.vector.enabled', 'recallers.vector.weight', 'recallers.vector.endpoint', 'recallers.vector.model', 'recallers.vector.dimensions', 'recallers.vector.minCosine', 'recallers.vector.timeoutSeconds'] },
  ]
  const byPath = new Map(FIELD_DEFS.map((def) => [def.path, def]))
  const groupHtml = groups
    .map((group) => {
      const rows = group.paths.map((path) => formRow(byPath.get(path), path.split('.').reduce((node, key) => node[key], effective))).join('')
      return `<fieldset class="config-group"><legend class="config-group-title">${esc(group.title)}</legend>${rows}</fieldset>`
    })
    .join('')
  const hint = noteBar({
    variant: 'info',
    badge: '跨模块影响',
    text: '向量路字段是公用配置：同时影响检索召回（rdd explore 搜索的向量路）与探索缓存向量化（register/embed-backfill 的向量写入）——保存前会再弹确认。',
  })
  const form = `<form class="config-form" id="ops-config-form" aria-label="编辑 search-config.json">${groupHtml}${hint}
<div class="config-actions"><button type="button" class="btn btn-primary" id="ops-config-save" disabled>校验并保存</button><span class="config-nojs" id="ops-config-nojs">保存需启用 JavaScript（本页数据全部服务端渲染，无 JS 也可见）。</span></div>
<div class="config-note" id="ops-config-note" aria-live="polite"></div></form>`
  return panel({
    title: '编辑调参文件（可写）',
    note: '预填当前生效值',
    html: form,
    foot: '提交 = 强校验（不过谓词的值被 422 拒绝，绝不落盘）→ 与当前生效值合并 → 以完整 14 字段快照原子写回（tmp+rename）。省略语义不存在——表单每次提交全部 14 字段。',
  })
}

/** CLI-parameter detail table for a subset of scripts (frozen mirrors). */
function l4GroupPanel(l4, scripts, title) {
  const rows = []
  for (const group of l4) {
    if (!scripts.includes(group.script)) continue
    for (const param of group.params) {
      rows.push({
        cells: [
          { text: group.script, mono: true },
          { text: param.name, mono: true },
          { text: typeof param.default === 'string' ? param.default : String(param.default), mono: true },
          { text: param.range, muted: true },
        ],
      })
    }
  }
  return panel({
    title,
    html: dataTable({ columns: [{ label: '脚本' }, { label: '参数' }, { label: '默认' }, { label: '范围/说明' }], rows }),
    foot: '预算类参数在 start/promulgate 时固化进 manifest.json / bridge.json，运行期不可增长。',
  })
}

// ── UX subagent editor (r2 §5.1 four-piece block) ───────────────────────

/** Plain read of one agent entry field for SSR prefill. */
function uxField(agent, field) {
  if (agent === null || typeof agent !== 'object') return ''
  const value = agent[field]
  if (value === null || value === undefined) return ''
  return typeof value === 'object' ? JSON.stringify(value) : String(value)
}

/** One agent editor fieldset; existing rows keep name readonly (r2 §5.2). */
function uxAgentBlock(agent, index) {
  const name = uxField(agent, 'name')
  const readonly = index >= 0 ? ' readonly' : ''
  const legend = index >= 0 ? `子代理 ${esc(name)}` : '新子代理'
  return `<fieldset class="ux-agent-block" data-ux-agent="1"><legend class="config-group-title">${legend}</legend>
<div class="config-field"><label class="config-label">name</label><input class="config-input" type="text" data-ux-field="name" value="${esc(name)}" spellcheck="false"${readonly}><span class="config-hint">执行器标识（ux-mockup-<小写字母/数字>；既有子代理不可改名）</span></div>
<div class="config-field"><label class="config-label">model</label><input class="config-input" type="text" data-ux-field="model" value="${esc(uxField(agent, 'model'))}" spellcheck="false"><span class="config-hint">绑定的模型（非空，≤200 字符）</span></div>
<div class="config-field"><label class="config-label">temperature</label><input class="config-input" type="text" data-ux-field="temperature" value="${esc(uxField(agent, 'temperature'))}" inputmode="decimal"><span class="config-hint">生成温度（数值 0–2）</span></div>
<div class="config-field"><label class="config-label">capability</label><input class="config-input" type="text" data-ux-field="capability" value="${esc(uxField(agent, 'capability'))}" spellcheck="false"><span class="config-hint">能力画像（非空，≤100 字符）</span></div>
<div class="config-field"><label class="config-label">note</label><input class="config-input" type="text" data-ux-field="note" value="${esc(uxField(agent, 'note'))}" spellcheck="false"><span class="config-hint">备注（可空，≤200 字符）</span></div>
</fieldset>`
}

/** Piece 1 + 2: per-agent table and the sync-status probe panel. */
function uxStatusPanels(ux) {
  const managedNames = new Set(ux.managed)
  const rows = (Array.isArray(ux.agents) ? ux.agents : []).map((agent) => ({
    cells: [
      { text: uxField(agent, 'name'), mono: true },
      { text: uxField(agent, 'model'), mono: true },
      { text: uxField(agent, 'temperature'), mono: true },
      { text: uxField(agent, 'capability') },
      { text: uxField(agent, 'note'), muted: true },
      { html: managedNames.has(uxField(agent, 'name')) ? badge('managed', 'info') : badge('未入账', 'warn') },
    ],
  }))
  const stateBadge = { synced: ['已同步', 'success'], drift: ['待同步 · 保存或运行同步', 'warn'], unknown: ['配置文件缺失/损坏，状态未知', 'error'] }
  const [stateLabel, stateTone] = stateBadge[ux.syncStatus.state] ?? ['未知', 'neutral']
  const perAgentBadge = { synced: ['已同步', 'success'], 'pending-sync': ['待同步', 'warn'], 'pending-clean': ['待清理', 'warn'], orphan: ['orphan', 'error'] }
  const perRows = ux.syncStatus.perAgent.map((row) => {
    const [label, tone] = perAgentBadge[row.state] ?? [row.state, 'neutral']
    return { cells: [{ text: row.name, mono: true }, { html: badge(label, tone) }, { text: row.detail, muted: true }] }
  })
  const fileLine =
    ux.parseError !== null
      ? noteBar({ variant: 'error', badge: '文件状态', text: `ux_subagent.json 损坏（${esc(ux.parseError)}）——探测状态未知；保存任意合法清单即重建完整文件。` })
      : ux.fileExists
        ? ''
        : noteBar({ variant: 'warn', badge: '文件状态', text: 'ux_subagent.json 不存在（探测状态未知）——保存任意合法清单即创建。' })
  return `${panel({
    title: '子代理清单（单源文件）',
    note: ux.filePath,
    html: `${fileLine}${dataTable({ columns: [{ label: 'name' }, { label: 'model' }, { label: 'temperature' }, { label: 'capability' }, { label: 'note' }, { label: '归属' }], rows })}`,
  })}${panel({
    title: '同步状态探测（纯读侧，不跑脚本）',
    note: '探测 .opencode/agent/ux-mockup-*.md 的 frontmatter',
    html: `<div class="ux-sync-head">${badge(stateLabel, stateTone)}<button type="button" class="btn" id="ops-ux-sync" disabled>运行同步</button><span class="config-nojs" id="ops-ux-sync-nojs">同步需启用 JavaScript（或手工运行 rdd-engine/scripts/sync-ux-subagents.cmd）。</span></div>${dataTable({ columns: [{ label: '子代理' }, { label: '状态' }, { label: '差异' }], rows: perRows })}`,
    foot: '删除/改名子代理：手工编辑 rdd-ux/ux_subagent.json 后运行 rdd-engine/scripts/sync-ux-subagents.cmd（见 rules.fallback）。',
  })}`
}

/** Piece 3 + 4: the edit form and the rules digest. */
function uxEditPanels(ux) {
  const agents = Array.isArray(ux.agents) ? ux.agents : []
  const blocks = agents.map((agent, index) => uxAgentBlock(agent, index)).join('')
  const rules = ux.rules ?? {}
  const ruleRows = ['count', 'managed', 'decoupling', 'fallback']
    .map((key) => ({ cells: [{ text: key, mono: true }, { text: typeof rules[key] === 'string' ? rules[key] : '—', muted: true }] }))
  const form = `<form class="config-form" id="ops-ux-form" aria-label="编辑 ux_subagent.json">${blocks}
<div class="config-actions"><button type="button" class="btn" id="ops-ux-add">添加子代理</button><button type="button" class="btn btn-primary" id="ops-ux-save" disabled>校验并保存（全量替换）</button><span class="config-nojs" id="ops-ux-nojs">保存需启用 JavaScript（清单只读可见）。</span></div>
<div class="config-note" id="ops-ux-note" aria-live="polite"></div></form>
<template id="ops-ux-agent-template">${uxAgentBlock(null, -1)}</template>`
  return `${panel({
    title: '编辑 UX 子代理清单（可写，全量替换）',
    note: '保存 = 校验 → 原子写 → 自动触发同步脚本 → 回读落盘状态',
    html: form,
    foot: '编辑器的边界即下方 rules：只写 agents（name/model/temperature/capability/note），managed/rules 由同步脚本与协议持有，编辑器一律不碰。',
  })}${panel({
    title: 'rules 摘要（只读）',
    html: dataTable({ columns: [{ label: '规则' }, { label: '要点' }], rows: ruleRows }),
  })}`
}

/** The four UX pieces in order (r2 §5.1). */
function uxPanels(ux) {
  return `${uxStatusPanels(ux)}${uxEditPanels(ux)}`
}

/** Per-module dynamic content following the shared items table. */
function moduleExtras(moduleKey, data) {
  if (moduleKey === 'shared') return envValueTable(data.l1.vars, ['RDD_ENGINE_HOME', 'RDD_PROJECT_ROOT'], '定位变量观测（本进程）')
  if (moduleKey === 'handoff') return envValueTable(data.l1.vars, ['RDD_RUNTIME', 'DSH_WEB_URL'], '运行时判据链观测（本进程）')
  if (moduleKey === 'search') {
    return `${envValueTable(data.l1.vars, ['RDD_EMBED_APIKEY'], '向量密钥观测（本进程）')}${l2StatePanel(data.l2)}${l2ComparePanel(data.l2)}${l2VectorPanel(data.l2.vectorReadiness)}${l2FormPanel(data.l2)}`
  }
  if (moduleKey === 'delivery') return l4GroupPanel(data.l4, ['goal-tree', 'delivery-bridge'], '预算与模式参数明细')
  if (moduleKey === 'metrics') return l4GroupPanel(data.l4, ['code-metrics'], '度量阈值明细')
  if (moduleKey === 'dashboard') return l4GroupPanel(data.l4, ['dashboard'], '启动参数明细')
  if (moduleKey === 'ux') return uxPanels(data.ux)
  return ''
}

/** One functional-module panel: title + subtitle + items table + extras. */
function renderModule(module, data) {
  return panel({
    id: `ops-module-${module.key}`,
    title: module.title,
    tag: `模块 ${MODULE_DEFS.findIndex((entry) => entry.key === module.key) + 1}/8`,
    html: `<p class="prose module-sub">${esc(module.subtitle)}</p>${moduleItemsTable(module)}${moduleExtras(module.key, data)}`,
  })
}

/** Body of the config page: declaration bars + the eight module panels. */
function renderBody(data) {
  return [declarationBars(), ...MODULE_DEFS.map((module) => renderModule(module, data))].join('')
}

/**
 * Render the config-centre page.
 * @param {{domains: object, counts: object, projectRoot: string, generatedAt: string}} input
 */
export function renderConfigPage(input) {
  const envelope = input.domains.config
  const header = domainHeader({
    title: '配置中心',
    subtitle: '按功能组织的配置全景：每个模块说明这是什么功能的配置、改了影响什么。两个可写点：检索调参文件与 UX 子代理清单；其余全部只读。',
    envelope,
  })
  const body =
    envelope.available === false || envelope.data === null
      ? `<section class="panel"><div class="panel-body"><p class="prose">配置域取数失败（其余数据域不受影响），请刷新重试。</p></div></section>`
      : renderBody(envelope.data)
  return renderLayout({
    title: '配置中心',
    activeKey: 'config',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

// DEV page-contract probe (n9 fix round).
//
// Two gaps that no existing suite covered, both found by hand during the
// quality-gate rework:
//   A) Document shell — every other page assertion strips the HTML down to text
//      (`replace(/<[^>]+>/g, ' ')`), so a body-only response with no <head>,
//      stylesheet or script tags still looked green. The overview view was in
//      fact served as a bare fragment, which silently killed styling and every
//      client behaviour on the landing page.
//   B) Client behaviour — server-side suites strip <script>, so static/app.js
//      was never executed anywhere. Loading it into a stubbed DOM keeps the
//      module wiring (theme, refresh, shortcuts) under assertion.
//
// Usage: node rdd-engine/tests/test-dashboard-page-contract.mjs
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { startServer } from '../dashboard/server.mjs'

const engineDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const repoRoot = resolve(engineDir, '..')
const appJsPath = join(engineDir, 'dashboard', 'static', 'app.js')
const PORT = 8811
const ROUTES = ['/', '/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees', '/config']
const SIDEBAR_ROUTES = ['/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees', '/config']

let total = 0
let failures = 0
function assertTrue(condition, name, detail = '') {
  total += 1
  if (condition) {
    console.log(`PASS  ${name}`)
    return
  }
  failures += 1
  console.log(`FAIL  ${name}   ${detail}`)
}

/** Fetch one path from the probe server. */
async function fetchPage(path) {
  const response = await fetch(`http://127.0.0.1:${PORT}${path}`)
  return { status: response.status, html: await response.text() }
}

/** Structural anchors every page of this dashboard must carry. */
function pageContractProblems(html) {
  const problems = []
  if (!html.startsWith('<!DOCTYPE html>')) problems.push('no doctype')
  if (!html.includes('<link rel="stylesheet" href="/static/style.css">')) problems.push('no stylesheet link')
  if (!html.includes('<script type="module" src="/static/app.js"></script>')) problems.push('no module script tag')
  if (!html.includes("document.documentElement.setAttribute('data-theme'")) problems.push('no inline theme boot')
  for (const marker of ['id="ops-sidebar"', 'id="ops-refresh"', 'id="ops-main"', 'id="ops-freshness"', 'class="page-foot"', 'id="ops-project-switch"', 'id="ops-project-panel"', 'id="ops-project-pick"', 'id="ops-project-path"', 'id="ops-project-apply"', 'id="ops-flash-slot"', 'aria-label="切换数据根"']) {
    if (!html.includes(marker)) problems.push(`no ${marker}`)
  }
  if (!html.includes('</html>')) problems.push('no closing html tag')
  return problems
}

/** Section A: every route is a complete document with the shared shell. */
async function checkPageContract() {
  for (const route of ROUTES) {
    const page = await fetchPage(route)
    const problems = pageContractProblems(page.html)
    assertTrue(page.status === 200 && problems.length === 0, `contract: ${route} is a complete document`, `status=${page.status} problems=${problems.join(', ')}`)
  }
  const missing = await fetchPage('/requirements/__missing__/__missing__')
  assertTrue(pageContractProblems(missing.html).length === 0, 'contract: unknown detail route is still a complete document', `status=${missing.status}`)
  const home = await fetchPage('/')
  assertTrue(/<title>总览 · RDD 运营看板<\/title>/.test(home.html), 'contract: root page carries its title', (home.html.match(/<title>[^<]*<\/title>/) ?? [''])[0])
  const sidebarMissing = SIDEBAR_ROUTES.filter((route) => !home.html.includes(`href="${route}"`))
  assertTrue(sidebarMissing.length === 0, 'contract: root sidebar links every domain route', `missing=${sidebarMissing.join(',')}`)
  const rootHits = home.html.split(repoRoot).length - 1
  assertTrue(rootHits >= 2, 'contract: the switcher panel carries the full current root (truthful SSR)', `hits=${rootHits}`)
  assertTrue(home.html.includes('切换数据根（项目）') && home.html.includes('或 手动输入路径'), 'contract: switcher panel copy present')
}

/** Strip scripts/styles/tags down to visible text — what a no-JS reader sees. */
function visibleText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<style[\s\S]*?<\/style>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
}

/** Assert every marker is present in the given text, reporting all misses. */
function assertMarkersPresent(text, markers, name) {
  const missing = markers.filter((marker) => !text.includes(marker))
  assertTrue(missing.length === 0, name, `missing=${missing.join(',')}`)
}

/**
 * Section D: the /config page serves all five configuration layers into the
 * HTML so a no-JS reader sees everything (ops-config-panel n4 acceptance ①).
 */
async function checkConfigPageContract() {
  const secret = 'qa-page-contract-apikey-A1b2C3d4'
  const previousApikey = process.env.RDD_EMBED_APIKEY
  process.env.RDD_EMBED_APIKEY = secret
  let page
  try {
    page = await fetchPage('/config')
  } finally {
    if (previousApikey === undefined) delete process.env.RDD_EMBED_APIKEY
    else process.env.RDD_EMBED_APIKEY = previousApikey
  }
  const text = visibleText(page.html)
  assertTrue(page.status === 200, 'config contract: /config serves 200', `status=${page.status}`)
  assertTrue(/<title>配置中心 · RDD 运营看板<\/title>/.test(page.html), 'config contract: the page carries its title')
  // R2 migration (design §6.4 row 4): dual-writable declaration + module titles.
  assertMarkersPresent(text, ['两个可写点', 'search-config.json', '观测点'], 'config contract: the two declaration bars render (dual writable points)')
  assertMarkersPresent(
    text,
    ['跨模块公用配置', '探索检索与缓存向量化', 'UX 视觉稿子代理'],
    'config contract: the R2 module titles render'
  )
  assertTrue(!/\bL[1-5]\b/.test(text) && !text.includes('唯一可写点'), 'config contract: no L1–L5 jargon and no retired single-writable wording')
  assertMarkersPresent(
    text,
    ['RDD_ENGINE_HOME', 'RDD_PROJECT_ROOT', 'RDD_RUNTIME', 'DSH_WEB_URL', 'RDD_EMBED_APIKEY', '已设置（不回显）'],
    'config contract: the five environment variables render without echoing the APIKEY value'
  )
  assertTrue(!page.html.includes(secret), 'config contract: the APIKEY value never appears in the HTML')
  assertMarkersPresent(
    text,
    ['topK', 'recallDepth', 'rrfK', 'recallers.lexical.enabled', 'recallers.lexical.weight', 'recallers.lexical.bm25K1', 'recallers.lexical.bm25B', 'recallers.vector.enabled', 'recallers.vector.weight', 'recallers.vector.endpoint', 'recallers.vector.model', 'recallers.vector.dimensions', 'recallers.vector.minCosine', 'recallers.vector.timeoutSeconds', '文件值', '内置默认', '生效值', '四要素'],
    'config contract: L2 shows the 14-field comparison table and readiness factors'
  )
  assertMarkersPresent(text, ['热区保留期', 'rdd-tip/1', 'F1–F8'], 'config contract: L3 frozen constants render')
  assertMarkersPresent(text, ['goal-tree', 'delivery-bridge', 'code-metrics', 'MaxRounds', 'MaxFunctionLines', '8787'], 'config contract: L4 CLI defaults render')
  assertMarkersPresent(text, ['rdd-ux/ux_subagent.json', '.opencode/agent/', 'dsh/presets/', 'opencode.json', '.rdd/install.json', '~/.rdd/engine/manifest.json'], 'config contract: every ecosystem probe path renders (module rows)')
  assertMarkersPresent(text, ['消费方'], 'config contract: the consumers column of the module tables renders')
  checkConfigFormShell(page.html)
  checkUxFormShell(page.html)
}

/** The SSR edit form: 14 fields prefilled, submit disabled without JS. */
function checkConfigFormShell(html) {
  assertTrue(html.includes('id="ops-config-form"') && html.includes('id="ops-config-save"'), 'config contract: the edit form and save button exist')
  assertTrue(html.split('data-config-field="1"').length - 1 === 14, 'config contract: the form carries exactly 14 fields', `count=${html.split('data-config-field="1"').length - 1}`)
  assertTrue(html.split('data-cross-module="1"').length - 1 === 7, 'config contract: the seven vector fields carry the cross-module attribute', `count=${html.split('data-cross-module="1"').length - 1}`)
  assertTrue(html.includes('id="cfg-recallers-lexical-enabled"') && html.includes('id="cfg-recallers-vector-enabled"'), 'config contract: both enabled fields use selects')
  assertTrue(html.includes('data-original='), 'config contract: form fields carry data-original for the client-side diff')
  const saveButton = /<button[^>]*id="ops-config-save"[^>]*>/.exec(html)?.[0] ?? ''
  assertTrue(saveButton.includes('disabled'), 'config contract: the save button ships disabled (no JS cannot save)', saveButton)
  assertTrue(html.includes('保存需启用 JavaScript'), 'config contract: the no-JS caveat is stated')
  assertTrue(html.includes('同时影响检索召回') && html.includes('缓存向量化'), 'config contract: the always-on vector cross-module hint renders (layer ①)')
}

/** The SSR UX editor block (r2 §5.1, design §8 anchors). */
function checkUxFormShell(html) {
  assertTrue(html.includes('id="ops-ux-form"') && html.includes('id="ops-ux-save"') && html.includes('id="ops-ux-add"'), 'ux contract: the UX form, save and add buttons exist')
  assertTrue(html.includes('id="ops-ux-sync"'), 'ux contract: the standalone sync button exists')
  assertTrue(html.includes('id="ops-ux-agent-template"'), 'ux contract: the new-agent template ships for JS row cloning')
  const saveButton = /<button[^>]*id="ops-ux-save"[^>]*>/.exec(html)?.[0] ?? ''
  assertTrue(saveButton.includes('disabled'), 'ux contract: the UX save button ships disabled (no JS cannot save)', saveButton)
  assertTrue(html.split('data-ux-field="name"').length - 1 >= 1, 'ux contract: at least one agent row renders with a name field')
  assertTrue(html.includes('需重启 opencode') || html.includes('sync-ux-subagents.cmd'), 'ux contract: the escape hatch footer names the manual sync path')
}

/** Minimal selector matcher for the exact selectors app.js delegates on. */
function matchesSelector(element, selector) {
  if (typeof selector !== 'string' || selector === '' || selector.indexOf(' ') !== -1) return false
  let tag = ''
  const classes = []
  const attrs = []
  for (const part of selector.split(/(?=[.[])/)) {
    if (part === '') continue
    if (part.startsWith('.')) classes.push(part.slice(1))
    else if (part.startsWith('[')) attrs.push(part.slice(1, -1))
    else tag = part.toLowerCase()
  }
  if (tag !== '' && String(element.tagName ?? '').toLowerCase() !== tag) return false
  if (classes.some((name) => !element.classList.contains(name))) return false
  return attrs.every((attr) => element.getAttribute(attr) !== null)
}

/** A DOM element stub (attributes, listeners and the members the script touches). */
function stubElement(id) {
  const attrs = new Map()
  const listeners = new Map()
  const classes = new Set()
  const element = {
    id,
    tagName: id.startsWith('#') ? id.slice(1) : 'div',
    parentElement: null,
    innerHTML: '',
    textContent: '',
    value: '',
    hidden: false,
    disabled: false,
    listeners,
    attrs,
    setAttribute(key, value) { attrs.set(key, String(value)) },
    removeAttribute(key) { attrs.delete(key) },
    getAttribute(key) { return attrs.has(key) ? attrs.get(key) : null },
    addEventListener(type, handler) { listeners.set(type, handler) },
    querySelector() { return null },
    querySelectorAll() { return [] },
    appendChild() {},
    insertBefore() {},
    remove() {},
    matches(selector) { return matchesSelector(element, selector) },
    closest(selector) {
      let node = element
      while (node !== null && node !== undefined) {
        if (typeof node.matches === 'function' && node.matches(selector)) return node
        node = node.parentElement
      }
      return null
    },
    focus() { element.focusCalls = (element.focusCalls ?? 0) + 1 },
    insertAdjacentHTML(_position, html) { element.insertedHtml = String(html ?? '') },
  }
  element.classList = {
    add: (name) => classes.add(name),
    remove: (name) => classes.delete(name),
    contains: (name) => classes.has(name),
    toggle: (name, on) => (on === undefined ? (classes.has(name) ? classes.delete(name) : classes.add(name)) : on ? classes.add(name) : classes.delete(name)),
  }
  return element
}

/** The id → stub-element table, mirroring the SSR state (panel collapsed). */
function buildStubNodes() {
  const switcherIds = ['ops-project-switch', 'ops-project-panel', 'ops-project-pick', 'ops-project-path', 'ops-project-apply', 'ops-project-note', 'ops-project-close', 'ops-flash-slot']
  const nodes = new Map(['ops-theme', 'ops-refresh', 'ops-main', 'ops-freshness', ...switcherIds].map((id) => [id, stubElement(id)]))
  nodes.get('ops-refresh').querySelector = () => stubElement('btn-text')
  nodes.get('ops-project-panel').hidden = true
  // /exploration expansion anchors (exploration-entry-expansion §5): tiles,
  // panels, one head row, one entry row + its hidden detail row and a link.
  const statTileNode = (id, kpi) => {
    const tile = stubElement(id)
    tile.classList.add('stat-tile')
    tile.setAttribute('data-kpi', kpi)
    return tile
  }
  for (const kpi of ['total', 'hot', 'index']) nodes.set(`kpi-${kpi}`, statTileNode(`kpi-${kpi}`, kpi))
  for (const zone of ['total', 'hot', 'index']) {
    const section = stubElement(`exp-${zone}`)
    section.classList.add('kpi-expansion')
    const head = stubElement(`exp-head-${zone}`)
    head.classList.add('exp-head')
    head.setAttribute('data-collapse-zone', zone)
    head.parentElement = section
    nodes.set(`exp-${zone}`, section)
    nodes.set(`exp-head-${zone}`, head)
  }
  const flat = stubElement('entries-flat')
  flat.classList.add('panel')
  nodes.set('entries-flat', flat)
  const row = stubElement('entry-row-total-0')
  row.tagName = 'tr'
  row.setAttribute('data-entry', 'row-total-0')
  row.setAttribute('aria-controls', 'row-total-0')
  const detail = stubElement('row-total-0')
  detail.tagName = 'tr'
  detail.classList.add('row-detail')
  detail.hidden = true
  const link = stubElement('detail-link-0')
  link.tagName = 'a'
  link.parentElement = detail
  nodes.set('entry-row-total-0', row)
  nodes.set('row-total-0', detail)
  nodes.set('detail-link-0', link)
  return nodes
}

/** The document stub: element lookup, listener capture, node factory. */
function buildStubDocument(nodes, listeners, documentElement) {
  return {
    documentElement,
    activeElement: null,
    readyState: 'complete',
    getElementById: (id) => nodes.get(id) ?? null,
    querySelector: (selector) => (typeof selector === 'string' && selector.startsWith('#') ? nodes.get(selector.slice(1)) ?? null : null),
    querySelectorAll: (selector) => {
      if (typeof selector !== 'string' || selector.indexOf(' ') !== -1) return []
      const found = []
      nodes.forEach((node) => {
        if (typeof node.matches === 'function' && node.matches(selector)) found.push(node)
      })
      return found
    },
    addEventListener: (type, handler) => listeners.set(`document:${type}`, handler),
    createElement: (tag) => stubElement(tag),
    createTextNode: (text) => {
      const node = stubElement('#text')
      node.textContent = String(text)
      return node
    },
  }
}

/** The window stub: storages, fetch recorder (canceled-dialog JSON), DOMParser. */
function buildStubWindow(parts) {
  return {
    localStorage: { getItem: (key) => (parts.storage.has(key) ? parts.storage.get(key) : null), setItem: (key, value) => parts.storage.set(key, value) },
    sessionStorage: { getItem: (key) => (parts.session.has(key) ? parts.session.get(key) : null), setItem: (key, value) => parts.session.set(key, String(value)), removeItem: (key) => parts.session.delete(key) },
    setTimeout: () => 0,
    location: { pathname: '/requirements', search: '', href: '', reload() {} },
    history: { back() { parts.countBack() } },
    fetch: async (url) => {
      parts.fetchCalls.push(String(url))
      return {
        ok: true,
        status: 200,
        text: async () => '<html><div id="ops-main">refreshed</div><div id="ops-freshness" data-at="2026-01-01T00:00:00Z">f</div></html>',
        json: async () => ({ ok: false, code: 'canceled' }),
      }
    },
    DOMParser: class {
      parseFromString() {
        return {
          getElementById: (id) => {
            const parsed = stubElement(id)
            parsed.innerHTML = id === 'ops-main' ? 'refreshed' : 'f'
            parsed.attrs.set('data-at', '2026-01-01T00:00:00Z')
            return parsed
          },
        }
      }
    },
  }
}

/** Install the stubbed browser environment app.js expects. */
function installDomStub() {
  const nodes = buildStubNodes()
  const documentElement = {
    attrs: new Map(),
    setAttribute(key, value) { this.attrs.set(key, String(value)) },
    getAttribute(key) { return this.attrs.has(key) ? this.attrs.get(key) : null },
  }
  const listeners = new Map()
  const storage = new Map()
  const session = new Map()
  const fetchCalls = []
  let backCalls = 0
  globalThis.document = buildStubDocument(nodes, listeners, documentElement)
  globalThis.window = buildStubWindow({ storage, session, fetchCalls, countBack: () => { backCalls += 1 } })
  try {
    Object.defineProperty(globalThis, 'navigator', { value: {}, configurable: true })
  } catch {
    /* Node ships a read-only navigator; copyText is not exercised here */
  }
  return { nodes, listeners, storage, session, documentElement, fetchCalls, backCalls: () => backCalls }
}

/** Section B: the client module wires up and behaves. */
async function checkClientModule() {
  const stub = installDomStub()
  await import(pathToFileURL(appJsPath).href)
  assertTrue(stub.nodes.get('ops-theme').listeners.has('click'), 'client: theme button wired on load')
  assertTrue(stub.nodes.get('ops-refresh').listeners.has('click'), 'client: refresh button wired on load')
  assertTrue(stub.listeners.has('document:keydown'), 'client: keyboard shortcuts wired on load')
  assertTrue(globalThis.init === undefined && globalThis.refreshView === undefined, 'client: module scope honoured (no globals leaked)')
  assertTrue(stub.documentElement.getAttribute('data-theme') === 'light', 'client: boot applies the active theme', `theme=${stub.documentElement.getAttribute('data-theme')}`)

  stub.nodes.get('ops-theme').listeners.get('click')()
  assertTrue(stub.documentElement.getAttribute('data-theme') === 'dark', 'client: theme toggle flips to dark')
  assertTrue(stub.storage.get('ops-dashboard:theme') === 'dark', 'client: theme choice is persisted')
  assertTrue(stub.nodes.get('ops-theme').getAttribute('aria-pressed') === 'true', 'client: theme toggle updates aria-pressed')

  stub.listeners.get('document:keydown')({ key: '3', target: { tagName: 'body' }, metaKey: false, ctrlKey: false, altKey: false, preventDefault() {} })
  assertTrue(globalThis.window.location.href === '/exploration', 'client: numeric shortcut routes to the third domain', `href=${globalThis.window.location.href}`)

  const refresh = stub.nodes.get('ops-refresh')
  refresh.listeners.get('click')()
  assertTrue(refresh.disabled === true && refresh.getAttribute('aria-busy') === 'true', 'client: refresh enters the busy state')
  await new Promise((resolvePromise) => setImmediate(resolvePromise))
  await new Promise((resolvePromise) => setImmediate(resolvePromise))
  assertTrue(refresh.disabled === false && refresh.getAttribute('aria-busy') === null, 'client: refresh leaves the busy state', `disabled=${refresh.disabled}`)
  assertTrue(stub.nodes.get('ops-main').innerHTML === 'refreshed', 'client: refresh swaps the fetched main content', `innerHTML=${stub.nodes.get('ops-main').innerHTML}`)
  return stub
}

/** Section C: the project switcher panel wires up and behaves. */
async function checkSwitcherModule(stub) {
  const keyEvent = (key, target) => ({ key, target: target ?? { tagName: 'body' }, metaKey: false, ctrlKey: false, altKey: false, preventDefault() {} })
  const settle = async () => {
    await new Promise((resolvePromise) => setImmediate(resolvePromise))
    await new Promise((resolvePromise) => setImmediate(resolvePromise))
  }
  const toggle = stub.nodes.get('ops-project-switch')
  const panel = stub.nodes.get('ops-project-panel')
  const pick = stub.nodes.get('ops-project-pick')
  const pathInput = stub.nodes.get('ops-project-path')
  const apply = stub.nodes.get('ops-project-apply')
  assertTrue(toggle.listeners.has('click'), 'switcher: toggle wired on load')
  assertTrue(pick.listeners.has('click'), 'switcher: browse button wired on load')
  assertTrue(apply.listeners.has('click'), 'switcher: manual submit wired on load')
  assertTrue(pathInput.listeners.has('keydown'), 'switcher: path input Enter wired on load')

  toggle.listeners.get('click')()
  assertTrue(panel.hidden === false && toggle.getAttribute('aria-expanded') === 'true', 'switcher: toggle opens the panel and announces expansion')
  stub.nodes.get('ops-project-close').listeners.get('click')()
  assertTrue(panel.hidden === true && toggle.getAttribute('aria-expanded') === 'false', 'switcher: close collapses the panel again')

  stub.listeners.get('document:keydown')(keyEvent('p'))
  assertTrue(panel.hidden === false, 'switcher: shortcut P opens the panel')
  stub.listeners.get('document:keydown')(keyEvent('p', { tagName: 'input' }))
  assertTrue(panel.hidden === false, 'switcher: P while typing never toggles the panel')
  stub.listeners.get('document:keydown')(keyEvent('Escape'))
  assertTrue(panel.hidden === true && stub.backCalls() === 0, 'switcher: Escape closes the panel before detail-page history.back')

  const callsBefore = stub.fetchCalls.length
  pathInput.value = '   '
  apply.listeners.get('click')()
  assertTrue(stub.fetchCalls.length === callsBefore, 'switcher: an empty manual path stays local (no request)')

  pathInput.value = 'D:\\work\\proj-b'
  apply.listeners.get('click')()
  assertTrue(apply.disabled === true && pick.disabled === true && pathInput.disabled === true, 'switcher: a switch in flight disables every panel control')
  await settle()
  assertTrue(stub.fetchCalls[stub.fetchCalls.length - 1] === '/api/project/switch', 'switcher: manual submit posts to the switch endpoint', stub.fetchCalls.join(','))
  assertTrue(apply.disabled === false && pick.disabled === false && pathInput.disabled === false, 'switcher: controls recover after the switch settles')

  pick.listeners.get('click')()
  assertTrue(pick.disabled === true && pick.getAttribute('aria-busy') === 'true', 'switcher: browse enters the busy state')
  await settle()
  assertTrue(stub.fetchCalls[stub.fetchCalls.length - 1] === '/api/project/pick', 'switcher: browse posts to the pick endpoint', stub.fetchCalls.join(','))
  assertTrue(pick.disabled === false && pick.getAttribute('aria-busy') === null, 'switcher: a canceled dialog restores the browse button')
}

/** Section E: KPI expansion client behaviour (exploration-entry-expansion §5/§6). */
function checkKpiExpansionBehaviour(stub) {
  const tile = stub.nodes.get('kpi-total')
  const panelEl = stub.nodes.get('exp-total')
  const head = stub.nodes.get('exp-head-total')
  const row = stub.nodes.get('entry-row-total-0')
  const detail = stub.nodes.get('row-total-0')
  const link = stub.nodes.get('detail-link-0')
  const flat = stub.nodes.get('entries-flat')
  const click = (target) => stub.listeners.get('document:click')({ target })
  const key = (keyName, target) => stub.listeners.get('document:keydown')({ key: keyName, target, metaKey: false, ctrlKey: false, altKey: false, preventDefault() {} })

  // JS enhancement (§5.1/§6.6): tiles upgraded, flat baseline hidden, chevron injected
  assertTrue(tile.getAttribute('data-bound') === '1' && tile.classList.contains('is-expandable'), 'expansion: tiles enhanced on boot (is-expandable)')
  assertTrue(tile.getAttribute('role') === 'button' && tile.getAttribute('tabindex') === '0', 'expansion: tile is a focusable button')
  assertTrue(tile.getAttribute('aria-expanded') === 'false' && tile.getAttribute('aria-controls') === 'exp-total', 'expansion: tile aria wiring points at its panel')
  assertTrue(typeof tile.insertedHtml === 'string' && tile.insertedHtml.includes('stat-chevron'), 'expansion: chevron injected by JS only (D7)')
  assertTrue(flat.hidden === true, 'expansion: flat baseline hidden once JS runs (§6.6)')

  // click tile → panel opens; second click collapses (AC1)
  click(tile)
  assertTrue(panelEl.hidden === false && tile.getAttribute('aria-expanded') === 'true' && tile.classList.contains('is-open'), 'expansion: clicking the total tile opens its panel (AC1)')
  click(tile)
  assertTrue(panelEl.hidden === true && tile.getAttribute('aria-expanded') === 'false' && !tile.classList.contains('is-open'), 'expansion: clicking the tile again collapses (AC1)')

  // head-row collapse hands focus back to the tile (D5 + §6.5)
  click(tile)
  click(head)
  assertTrue(panelEl.hidden === true && tile.focusCalls === 1, 'expansion: head-row collapse refocuses the KPI tile')

  // entry row toggles its hidden detail row; links never toggle (AC3, §6.1)
  click(row)
  assertTrue(detail.hidden === false && row.classList.contains('is-open') && row.getAttribute('aria-expanded') === 'true', 'expansion: entry row opens its detail row (AC3)')
  click(link)
  assertTrue(detail.hidden === false, 'expansion: link clicks never toggle rows')
  click(row)
  assertTrue(detail.hidden === true && row.getAttribute('aria-expanded') === 'false', 'expansion: entry row collapses again')

  // keyboard: Enter opens the focused tile; Esc inside the panel collapses + refocuses (§6.1)
  key('Enter', tile)
  assertTrue(panelEl.hidden === false, 'expansion: Enter opens the focused tile panel')
  globalThis.document.activeElement = head
  const backCallsBefore = stub.backCalls()
  key('Escape', head)
  assertTrue(panelEl.hidden === true && tile.focusCalls === 2 && stub.backCalls() === backCallsBefore, 'expansion: Esc collapses the expansion and refocuses the tile without history.back')
  globalThis.document.activeElement = null
}

/** The client script must stay a module: an anonymous wrapper is itself a 200+ line function. */
function checkClientScriptShape() {
  const source = readFileSync(appJsPath, 'utf8')
  assertTrue(!/;\s*\(function\s*\(\)\s*\{/.test(source), 'shape: app.js carries no anonymous IIFE wrapper')
  assertTrue(!/['"]use strict['"]/.test(source), 'shape: strict mode comes from the module loader, not a directive')
}

let server = null
try {
  await new Promise((resolvePromise, rejectPromise) => {
    server = startServer({ context: { projectRoot: repoRoot, rddRoot: join(repoRoot, '.rdd') }, port: PORT, quiet: true, onReady: () => resolvePromise() })
    server.on('error', rejectPromise)
  })
  await checkPageContract()
  await checkConfigPageContract()
  const stub = await checkClientModule()
  await checkSwitcherModule(stub)
  checkKpiExpansionBehaviour(stub)
  checkClientScriptShape()
} finally {
  if (server !== null) await new Promise((resolvePromise) => server.close(resolvePromise))
}

console.log(`\ntotal: ${total}  failed: ${failures}`)
process.exitCode = failures === 0 ? 0 : 1

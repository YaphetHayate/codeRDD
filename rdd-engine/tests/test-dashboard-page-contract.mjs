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
const ROUTES = ['/', '/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees']
const SIDEBAR_ROUTES = ['/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees']

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

/** A DOM element stub (attributes, listeners and the members the script touches). */
function stubElement(id) {
  const attrs = new Map()
  const listeners = new Map()
  const classes = new Set()
  const element = {
    id,
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
    closest() { return null },
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
  return nodes
}

/** The document stub: element lookup, listener capture, node factory. */
function buildStubDocument(nodes, listeners, documentElement) {
  return {
    documentElement,
    readyState: 'complete',
    getElementById: (id) => nodes.get(id) ?? null,
    querySelectorAll: () => [],
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
  const stub = await checkClientModule()
  await checkSwitcherModule(stub)
  checkClientScriptShape()
} finally {
  if (server !== null) await new Promise((resolvePromise) => server.close(resolvePromise))
}

console.log(`\ntotal: ${total}  failed: ${failures}`)
process.exitCode = failures === 0 ? 0 : 1

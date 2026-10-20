// 端到端集成联调探针 — exploration-cache-ux 整体验收（goal-tree node n23, integrate）。
//
// 使命：三个子交付（#1 KPI 层级展开 / #2 产物对可观测 / #3 产物对删除）全部完成后，
// 真实串联各模块数据/调用链，端到端跑通 requirements/overview.md#整体验收判据 的完整
// 场景（不是各模块独立子验收）：
//
//   R 段（真实仓 · 只读全链）—— 场景 2 + 场景 1 前半：
//     真实服务进程 + 真实 .rdd/exploration 数据 → SSR 各层级与磁盘真值一致 →
//     客户端 app.js 在真实 HTML 上的展开/收起/复制/链接不冒泡交互 →
//     全部读交互后 hot.json / index.json / artifacts/** 的 size+mtime+SHA256 零漂移。
//
//   S 段（沙箱副本 · 破坏性全链）—— 场景 1 完整闭环：
//     受控夹具项目根（真实服务、真实删除写路径）→ KPI 展开 → 条目详情（摘要/字段/
//     vscode 跳转/复制）→ 产物对清单展开 → 新鲜状态（新鲜/变更/缺失/无条目/无清单）→
//     生成时间双轨（registeredAt / ≈文件时间）→ 相关产物路径 → 取消二次确认零变更 →
//     确认删除（热区对 + 持久层对）→ 刷新后条目/计数/产物文件三处一致消失 →
//     错误契约（405/400×3/404/422）→ zone 文件紧凑形状往返兼容。
//
// 用法：node .rdd/tests/ops-dashboard-exploration-integration/exploration-integration-e2e.mjs
// 零依赖；不触碰真实仓数据（删除全部落在临时沙箱副本，结束自清理）。
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { startServer } from '../../../rdd-engine/dashboard/server.mjs'
import { validateProjectRoot } from '../../../rdd-engine/dashboard/lib/paths.mjs'

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(SCRIPT_DIR, '..', '..', '..')
const APP_JS = join(REPO_ROOT, 'rdd-engine', 'dashboard', 'static', 'app.js')
const ENGINE_SCRIPTS = [join(REPO_ROOT, 'rdd-engine', 'scripts', 'explore.ps1'), join(REPO_ROOT, 'rdd-engine', 'scripts', 'explore-store.ps1')]

let total = 0
let failures = 0
function assertTrue(condition, id, name, detail = '') {
  total += 1
  if (condition) {
    console.log(`PASS  ${id}  ${name}`)
    return
  }
  failures += 1
  console.log(`FAIL  ${id}  ${name}   ${detail}`)
}

/** Await a predicate (polling) until it holds or the timeout expires. */
async function waitFor(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (predicate()) return true
    if (Date.now() > deadline) return false
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 20))
  }
}

const settle = async () => {
  for (let round = 0; round < 12; round += 1) await new Promise((resolvePromise) => setImmediate(resolvePromise))
}

// ── 磁盘真值助手 ─────────────────────────────────────────────────────────

function shaFile(absolutePath) {
  return createHash('sha256').update(readFileSync(absolutePath)).digest('hex')
}

/** names excluded the same way the dashboard's fixture rule excludes them. */
function isExcludedName(name) {
  const lowered = name.toLowerCase()
  return lowered.startsWith('qa-') || lowered.includes('qa-fixture') || lowered.includes('qa-bridge') || /\d{4}-12-31-qa-/.test(lowered) || lowered === 'tmp'
}

function readZoneEntries(absolutePath) {
  const parsed = JSON.parse(readFileSync(absolutePath, 'utf8'))
  return Array.isArray(parsed.entries) ? parsed.entries : []
}

function artifactTruth(artifactsDir) {
  const names = readdirSync(artifactsDir).filter((name) => !isExcludedName(name))
  const records = names.filter((name) => name.endsWith('.md') && !name.endsWith('.summary.md'))
  const pairedCount = records.filter((name) => names.includes(`${name.slice(0, -3)}.summary.md`)).length
  return { names, records, pairedCount }
}

/** size + mtime + sha256 of every file under rootDir (recursive), keyed by repo-relative posix path. */
function snapshotTree(rootDir) {
  const map = new Map()
  const walk = (dir, prefix) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const rel = prefix === '' ? entry.name : `${prefix}/${entry.name}`
      if (entry.isDirectory()) walk(join(dir, entry.name), rel)
      else {
        const absolute = join(dir, entry.name)
        const stats = statSync(absolute)
        map.set(rel, `${stats.size}|${stats.mtimeMs}|${shaFile(absolute)}`)
      }
    }
  }
  walk(rootDir, '')
  return map
}

/** Differences between two snapshots, restricted to `accept(key)` entries. */
function snapshotDiff(before, after, accept = () => true) {
  const problems = []
  for (const key of before.keys()) {
    if (!accept(key)) continue
    if (!after.has(key)) problems.push(`deleted: ${key}`)
    else if (after.get(key) !== before.get(key)) problems.push(`changed: ${key}`)
  }
  for (const key of after.keys()) {
    if (accept(key) && !before.has(key)) problems.push(`created: ${key}`)
  }
  return problems
}

// ── HTTP 助手（真实服务进程上的真实请求）────────────────────────────────

function makeHttp(base) {
  return {
    async get(path) {
      const response = await fetch(`${base}${path}`, { headers: { 'Cache-Control': 'no-store' } })
      return { status: response.status, body: await response.text() }
    },
    async getJson(path) {
      const response = await fetch(`${base}${path}`)
      return { status: response.status, json: await response.json() }
    },
    async post(path, payload) {
      const response = await fetch(`${base}${path}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      let json = null
      try {
        json = await response.json()
      } catch {
        json = null
      }
      return { status: response.status, json }
    },
  }
}

/** Boot the real dashboard server against an explicit project root (ephemeral port). */
async function bootServer(projectRoot) {
  const verdict = validateProjectRoot(projectRoot)
  if (verdict.ok !== true) throw new Error(`数据根无效：${projectRoot} → ${verdict.message}`)
  return new Promise((resolvePromise) => {
    const server = startServer({
      port: 0,
      quiet: true,
      context: { projectRoot: verdict.projectRoot, rddRoot: verdict.rddRoot },
      onReady(listening) {
        resolvePromise({ server, base: `http://127.0.0.1:${listening.address().port}` })
      },
    })
  })
}

async function shutdown(server) {
  if (typeof server.closeAllConnections === 'function') server.closeAllConnections()
  await new Promise((resolvePromise) => server.close(resolvePromise))
}

// ── HTML 层级切片助手 ────────────────────────────────────────────────────

function sliceSection(html, startId, endId) {
  const start = html.indexOf(`id="${startId}"`)
  if (start === -1) return ''
  if (endId === undefined) return html.slice(start)
  const end = html.indexOf(`id="${endId}"`, start)
  return end === -1 ? html.slice(start) : html.slice(start, end)
}

function countOccurrences(haystack, needle) {
  return haystack.split(needle).length - 1
}

function tileValue(html, tileId) {
  const match = new RegExp(`id="${tileId}"[\\s\\S]*?stat-value">([^<]*)`).exec(html)
  return match === null ? null : match[1].trim()
}

/** One expandable row's chunk (its <tr …> plus the detail row that follows), located by detail id. */
function rowChunk(sectionHtml, vocabulary, detailId) {
  const marker = `${vocabulary}="${detailId}"`
  const start = sectionHtml.indexOf(marker)
  if (start === -1) return ''
  const next = sectionHtml.indexOf(`<tr ${vocabulary}=`, start + marker.length)
  return next === -1 ? sectionHtml.slice(start) : sectionHtml.slice(start, next)
}

/** One expandable row's chunk, located by a slug (or any text unique to that row). */
function rowChunkBySlug(sectionHtml, vocabulary, slug) {
  const slugPos = sectionHtml.indexOf(slug)
  if (slugPos === -1) return ''
  const start = sectionHtml.lastIndexOf(`<tr ${vocabulary}=`, slugPos)
  if (start === -1) return ''
  const next = sectionHtml.indexOf(`<tr ${vocabulary}=`, slugPos)
  return next === -1 ? sectionHtml.slice(start) : sectionHtml.slice(start, next)
}

// ── 客户端桩环境（从真实 HTML 扫描出节点，加载真实 app.js）──────────────

/** Minimal selector matcher for the exact simple selectors app.js delegates on. */
function matchesSelector(element, selector) {
  if (typeof selector !== 'string' || selector === '' || selector.includes(' ')) return false
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

function stubElement(init) {
  const attrs = new Map(Object.entries(init.attrs ?? {}))
  const listeners = new Map()
  const classes = new Set((init.classNames ?? []).flatMap((value) => value.split(/\s+/)).filter((value) => value !== ''))
  const element = {
    id: init.id ?? '',
    tagName: init.tagName ?? 'div',
    parentElement: init.parentElement ?? null,
    innerHTML: init.innerHTML ?? '',
    textContent: init.textContent ?? '',
    value: '',
    hidden: init.hidden === true,
    disabled: false,
    listeners,
    attrs,
    setAttribute(key, value) {
      attrs.set(key, String(value))
    },
    removeAttribute(key) {
      attrs.delete(key)
    },
    getAttribute(key) {
      return attrs.has(key) ? attrs.get(key) : null
    },
    addEventListener(type, handler) {
      if (!listeners.has(type)) listeners.set(type, [])
      listeners.get(type).push(handler)
    },
    querySelector() {
      return null
    },
    querySelectorAll() {
      return []
    },
    appendChild() {},
    insertBefore() {},
    remove() {},
    matches(selector) {
      return matchesSelector(element, selector)
    },
    closest(selector) {
      let node = element
      while (node !== null && node !== undefined) {
        if (typeof node.matches === 'function' && node.matches(selector)) return node
        node = node.parentElement
      }
      return null
    },
    focus() {
      element.focusCalls = (element.focusCalls ?? 0) + 1
    },
    insertAdjacentHTML(_position, html) {
      element.insertedHtml = String(html ?? '')
    },
  }
  element.classList = {
    add: (name) => classes.add(name),
    remove: (name) => classes.delete(name),
    contains: (name) => classes.has(name),
    toggle: (name, on) => (on === undefined ? (classes.has(name) ? classes.delete(name) : classes.add(name)) : on ? classes.add(name) : classes.delete(name)),
  }
  return element
}

function parseTagAttrs(tagText) {
  const attrs = {}
  for (const match of tagText.matchAll(/([a-zA-Z][a-zA-Z0-9-]*)="([^"]*)"/g)) attrs[match[1]] = match[2]
  if (/(^|\s)hidden(\s|$|>)/.test(tagText)) attrs.hidden = ''
  if (/(^|\s)disabled(\s|$|>)/.test(tagText)) attrs.disabled = ''
  return attrs
}

/**
 * Scan the served HTML for the interaction vocabulary (ids, expandable rows,
 * delete/copy buttons, vscode links) and build a faithful stub node table.
 */
function scanNodes(html) {
  const byId = new Map()
  const all = []
  let synthetic = 0
  let currentDetailRow = null
  const register = (node) => {
    all.push(node)
    if (node.id !== '') byId.set(node.id, node)
    return node
  }
  for (const tagMatch of html.matchAll(/<([a-z][a-zA-Z0-9-]*)((?:\s+[^<>]*?)?)>/g)) {
    const tagName = tagMatch[1].toLowerCase()
    const attrs = parseTagAttrs(tagMatch[2] ?? '')
    const classNames = attrs.class ? attrs.class.split(/\s+/) : []
    if (tagName === 'tr') {
      const isDetailRow = classNames.includes('row-detail')
      if (isDetailRow) {
        currentDetailRow = register(stubElement({ id: attrs.id ?? '', tagName: 'tr', attrs, classNames, hidden: true, parentElement: currentDetailRow?.parentElement ?? null }))
        continue
      }
      if (attrs['data-entry'] !== undefined || attrs['data-pair'] !== undefined) {
        const row = register(stubElement({ id: attrs.id ?? `syn-row-${synthetic++}`, tagName: 'tr', attrs, classNames }))
        currentDetailRow = row
        continue
      }
      currentDetailRow = null
      continue
    }
    if (tagName === 'button' && (attrs['data-delete-pair'] !== undefined || classNames.includes('btn-copy'))) {
      register(stubElement({ id: attrs.id ?? `syn-btn-${synthetic++}`, tagName: 'button', attrs, classNames, hidden: attrs.hidden !== undefined, parentElement: currentDetailRow }))
      continue
    }
    if (tagName === 'a' && typeof attrs.href === 'string' && attrs.href.startsWith('vscode://')) {
      register(stubElement({ id: attrs.id ?? `syn-link-${synthetic++}`, tagName: 'a', attrs, classNames, hidden: attrs.hidden !== undefined, parentElement: currentDetailRow }))
      continue
    }
    if (attrs.id !== undefined) {
      register(stubElement({ id: attrs.id, tagName, attrs, classNames, hidden: attrs.hidden !== undefined }))
      continue
    }
    if (classNames.includes('exp-head') && attrs['data-collapse-zone'] !== undefined) {
      register(stubElement({ id: `syn-head-${synthetic++}`, tagName: 'div', attrs, classNames }))
    }
  }
  return { byId, all }
}

/**
 * Install the stubbed browser environment over globalThis, backed by the REAL
 * server (window.fetch resolves relative URLs against the live base URL) and
 * the REAL fetched HTML (DOMParser slices the live document on refresh).
 */
function installClientStub(scanned, base, fetchedHtml) {
  const docListeners = new Map()
  const fetchLog = []
  const clipboardLog = []
  const confirmCalls = []
  const confirmResult = { value: true }
  let reloads = 0
  const documentElement = stubElement({ tagName: 'html' })
  const storage = () => {
    const map = new Map()
    return { getItem: (key) => (map.has(key) ? map.get(key) : null), setItem: (key, value) => map.set(key, String(value)), removeItem: (key) => map.delete(key) }
  }
  const document = {
    documentElement,
    activeElement: null,
    readyState: 'complete',
    getElementById: (id) => scanned.byId.get(id) ?? null,
    querySelector: (selector) => (typeof selector === 'string' && selector.startsWith('#') ? scanned.byId.get(selector.slice(1)) ?? null : null),
    querySelectorAll: (selector) => {
      if (typeof selector !== 'string' || selector.includes(' ')) return []
      return scanned.all.filter((node) => node.matches(selector))
    },
    addEventListener: (type, handler) => {
      if (!docListeners.has(type)) docListeners.set(type, [])
      docListeners.get(type).push(handler)
    },
    createElement: (tag) => stubElement({ tagName: tag }),
    createTextNode: (text) => stubElement({ tagName: '#text', id: '' , textContent: String(text) }),
  }
  const sliceMain = (html) => {
    const match = /<main[^>]*\bid="ops-main"[^>]*>([\s\S]*)<\/main>/.exec(html)
    return match === null ? '' : match[1]
  }
  const window = {
    localStorage: storage(),
    sessionStorage: storage(),
    setTimeout,
    clearTimeout,
    location: { pathname: '/exploration', search: '', origin: base, href: `${base}/exploration`, reload() { reloads += 1 } },
    confirm(message) {
      confirmCalls.push(String(message))
      return confirmResult.value
    },
    fetch: (url, init) => {
      const absolute = new URL(String(url), `${base}/`).href
      fetchLog.push({ url: absolute, method: (init && init.method) || 'GET' })
      return fetch(absolute, init)
    },
    DOMParser: class {
      parseFromString(html) {
        return {
          getElementById(id) {
            if (id === 'ops-main') return stubElement({ tagName: 'main', id, innerHTML: sliceMain(html) })
            if (id === 'ops-freshness') {
              const at = /id="ops-freshness"[^>]*data-at="([^"]*)"/.exec(html)
              const node = stubElement({ tagName: 'span', id })
              node.setAttribute('data-at', at === null ? '' : at[1])
              return node
            }
            return stubElement({ id })
          },
        }
      }
    },
  }
  globalThis.document = document
  globalThis.window = window
  let navigatorInstalled = true
  try {
    Object.defineProperty(globalThis, 'navigator', { value: { clipboard: { writeText: async (value) => { clipboardLog.push(String(value)) } } }, configurable: true })
  } catch {
    navigatorInstalled = false // read-only platform navigator: copy falls back to the label flip
  }
  const dispatchClick = (target) => {
    // 真实浏览器语义：目标自身与祖先链上的监听先触发，再冒泡到 document 委托。
    let node = target
    while (node !== null && node !== undefined) {
      for (const handler of node.listeners?.get('click') ?? []) handler({ target })
      node = node.parentElement
    }
    for (const handler of docListeners.get('click') ?? []) handler({ target })
  }
  const dispatchKey = (key, target) => {
    for (const handler of docListeners.get('keydown') ?? []) handler({ key, target, metaKey: false, ctrlKey: false, altKey: false, preventDefault() {} })
  }
  return { document, window, dispatchClick, dispatchKey, fetchLog, clipboardLog, confirmCalls, confirmResult, reloads: () => reloads, navigatorInstalled, liveHtml: fetchedHtml }
}

/**
 * Load the real app.js into the current stub environment. The source is
 * evaluated through `new Function` with window/document/navigator shadowed as
 * parameters: app.js has no package.json "type" context, so dynamic import()
 * loads it through the CommonJS interop whose cache ignores URL queries — two
 * phases in one process would silently share the first evaluation. A fresh
 * function scope per call keeps each phase's wiring isolated.
 */
function bootClientApp() {
  const source = readFileSync(APP_JS, 'utf8')
  const runner = new Function('window', 'document', 'navigator', `${source}\n`)
  runner(globalThis.window, globalThis.document, globalThis.navigator)
}

// ── R 段：真实仓只读全链 ────────────────────────────────────────────────

async function realRepoPhase() {
  console.log('\n=== R 段：真实仓只读全链（场景 2 + 场景 1 前半）===')
  const explorationRoot = join(REPO_ROOT, '.rdd', 'exploration')
  const artifactsDir = join(explorationRoot, 'artifacts')
  const hotEntries = readZoneEntries(join(explorationRoot, 'hot.json'))
  const indexEntries = readZoneEntries(join(explorationRoot, 'index.json'))
  const truth = artifactTruth(artifactsDir)
  const allEntries = [...hotEntries, ...indexEntries]
  const httpBase = await bootServer(REPO_ROOT)
  const http = makeHttp(httpBase.base)
  try {
    const beforeTree = snapshotTree(explorationRoot)
    const inScope = (key) => key === 'hot.json' || key === 'index.json' || key.startsWith('artifacts/')

    const page = await http.get('/exploration')
    assertTrue(page.status === 200 && page.body.startsWith('<!DOCTYPE html>'), 'R1', '/exploration 服务端渲染完整文档（真实仓）', `status=${page.status}`)

    assertTrue(tileValue(page.body, 'kpi-total') === String(allEntries.length), 'R2a', `KPI 条目总数与磁盘真值一致（${allEntries.length}）`, `tile=${tileValue(page.body, 'kpi-total')}`)
    assertTrue(tileValue(page.body, 'kpi-hot') === String(hotEntries.length), 'R2b', `KPI 热区计数与 hot.json 一致（${hotEntries.length}）`, `tile=${tileValue(page.body, 'kpi-hot')}`)
    assertTrue(tileValue(page.body, 'kpi-index') === String(indexEntries.length), 'R2c', `KPI 持久计数与 index.json 一致（${indexEntries.length}）`, `tile=${tileValue(page.body, 'kpi-index')}`)
    assertTrue(tileValue(page.body, 'kpi-pairs') === String(truth.records.length), 'R2d', `KPI 产物记录数与 artifacts/ 一致（${truth.records.length}）`, `tile=${tileValue(page.body, 'kpi-pairs')}`)
    assertTrue(page.body.includes(`${truth.pairedCount} 对已配对 summary`), 'R2e', `产物卡副行配对计数一致（${truth.pairedCount}）`)

    const totalSection = sliceSection(page.body, 'exp-total', 'exp-hot')
    const hotSection = sliceSection(page.body, 'exp-hot', 'exp-index')
    const indexSection = sliceSection(page.body, 'exp-index', 'exp-pairs')
    const pairsSection = sliceSection(page.body, 'exp-pairs', 'entries-flat')
    assertTrue(countOccurrences(totalSection, 'data-entry="row-') === allEntries.length, 'R3a', `总数展开区行数 == 条目总数（${allEntries.length}）`, `rows=${countOccurrences(totalSection, 'data-entry="row-')}`)
    assertTrue(countOccurrences(hotSection, 'data-entry="row-') === hotEntries.length, 'R3b', `热区展开区行数 == hot 计数`, `rows=${countOccurrences(hotSection, 'data-entry="row-')}`)
    assertTrue(countOccurrences(indexSection, 'data-entry="row-') === indexEntries.length, 'R3c', `持久展开区行数 == index 计数`, `rows=${countOccurrences(indexSection, 'data-entry="row-')}`)
    assertTrue(countOccurrences(pairsSection, 'data-pair="pair-detail-') === truth.records.length, 'R3d', `产物对展开区行数 == 产物记录数（${truth.records.length}）`, `rows=${countOccurrences(pairsSection, 'data-pair="pair-detail-')}`)

    const api = await http.getJson('/api/exploration')
    const apiData = api.json.data
    assertTrue(api.status === 200 && apiData.artifacts.pairs.length === truth.records.length, 'R4a', 'API envelope pairs 面与磁盘产物集一致', `pairs=${apiData?.artifacts?.pairs?.length}`)
    const frozenFace = ['zone', 'key', 'tags', 'brief', 'path', 'fileCount', 'registeredAt']
    assertTrue(allEntries.every((_, i) => JSON.stringify(Object.keys(apiData.entries[i])) === JSON.stringify(frozenFace)), 'R4b', 'API entry 冻结 7 字段面保持（TC-015 基线）')
    const entryBearing = apiData.artifacts.pairs.filter((pair) => pair.entry !== null)
    assertTrue(entryBearing.length === indexEntries.length + hotEntries.length, 'R4c', `关联条目产物对数 == 双区条目数（${entryBearing.length}）`)
    assertTrue(entryBearing.every((pair) => pair.freshness.state === 'no-list'), 'R4d', '真实仓关联条目 files 为空 → 现算口径如实标注「无清单」')
    const orphanSlugs = new Set(apiData.artifacts.pairs.filter((pair) => pair.entry === null).map((pair) => pair.slug))
    assertTrue(orphanSlugs.size === truth.records.length - entryBearing.length, 'R4e', `孤儿产物对数与磁盘推算一致（${orphanSlugs.size}）`)

    if (allEntries.length > 0) {
      const liveSlug = String(allEntries[0].path).split('/').pop().replace(/\.md$/, '')
      const liveRow = rowChunkBySlug(pairsSection, 'data-pair', liveSlug)
      assertTrue(liveRow.includes('无清单'), 'R5a', '页面产物对行对关联条目显示「无清单」状态', `slug=${liveSlug} chunk=${liveRow.slice(0, 80)}`)
      assertTrue(totalSection.includes(allEntries[0].key), 'R5b', '总数展开区含真实条目 key')
    }
    const firstOrphanSlug = [...orphanSlugs][0]
    assertTrue(firstOrphanSlug === undefined || pairsSection.includes('无条目'), 'R5c', '页面产物对区含「无条目」孤儿标注')

    const flatEntries = sliceSection(page.body, 'entries-flat', 'pairs-flat')
    const flatPairs = sliceSection(page.body, 'pairs-flat')
    assertTrue(flatEntries.includes('id="entries-flat"') && !/<section[^>]*id="entries-flat"[^>]*hidden/.test(page.body), 'R6a', '无 JS 基线：entries-flat 平铺面板可见（无 hidden）')
    assertTrue(flatPairs.includes('id="pairs-flat"') && !/<section[^>]*id="pairs-flat"[^>]*hidden/.test(page.body), 'R6b', '无 JS 基线：pairs-flat 平铺面板可见（无 hidden）')
    if (allEntries.length > 0) assertTrue(flatEntries.includes(allEntries[0].key), 'R6c', '无 JS 环境条目信息可见（首条 key 在平铺基线中）')
    if (firstOrphanSlug !== undefined) assertTrue(flatPairs.includes(firstOrphanSlug), 'R6d', '无 JS 环境产物对信息可见（首孤儿 slug 在平铺基线中）')

    // 客户端链：真实 app.js + 真实 HTML 桩环境（读交互）
    const scanned = scanNodes(page.body)
    const client = installClientStub(scanned, httpBase.base, page.body)
    bootClientApp()
    const tileTotal = scanned.byId.get('kpi-total')
    const expTotal = scanned.byId.get('exp-total')
    assertTrue(expTotal.hidden === true, 'R7-pre', 'SSR 展开区默认收起（hidden）')
    assertTrue(tileTotal.classList.contains('is-expandable') && tileTotal.getAttribute('aria-expanded') === 'false', 'R7a', '客户端启动：KPI 卡升级为可展开触发器')
    assertTrue(scanned.byId.get('entries-flat').hidden === true && scanned.byId.get('pairs-flat').hidden === true, 'R7b', '客户端启动：JS 环境隐藏双平铺基线')
    client.dispatchClick(tileTotal)
    assertTrue(expTotal.hidden === false && tileTotal.getAttribute('aria-expanded') === 'true', 'R7c', '点击「条目总数」→ 合并明细展开区打开')
    const firstEntryRow = scanned.all.find((node) => node.getAttribute('data-entry') !== null)
    if (firstEntryRow !== undefined) {
      const detail = scanned.byId.get(firstEntryRow.getAttribute('data-entry'))
      client.dispatchClick(firstEntryRow)
      assertTrue(detail.hidden === false, 'R7d', '点击条目行 → 详情行展开（真实条目）')
      client.dispatchClick(firstEntryRow)
      assertTrue(detail.hidden === true, 'R7e', '再点条目行 → 详情行收起')
    }
    const vscodeLink = scanned.all.find((node) => node.tagName === 'a' && String(node.getAttribute('href') ?? '').startsWith('vscode://file/'))
    if (firstEntryRow !== undefined && vscodeLink !== undefined) {
      const detail = scanned.byId.get(firstEntryRow.getAttribute('data-entry'))
      detail.hidden = true
      client.dispatchClick(vscodeLink)
      assertTrue(detail.hidden === true && client.fetchLog.every((entry) => entry.method === 'GET'), 'R7f', '点击 vscode 跳转链接：不冒泡触发行开合、不发任何请求')
    }
    const copyButton = scanned.all.find((node) => node.classList.contains('btn-copy'))
    if (copyButton !== undefined) {
      client.dispatchClick(copyButton)
      await settle()
      const expectedCopy = allEntries.length > 0 ? `${REPO_ROOT.replaceAll('\\', '/')}/${allEntries[0].path}` : null
      assertTrue(
        !client.navigatorInstalled || client.clipboardLog[client.clipboardLog.length - 1] === expectedCopy,
        'R7g',
        '点击「复制路径」→ 剪贴板收到条目记录文件绝对路径',
        `got=${client.clipboardLog[client.clipboardLog.length - 1]}`
      )
    }
    const headRow = scanned.all.find((node) => node.classList.contains('exp-head') && node.getAttribute('data-collapse-zone') === 'total')
    if (headRow !== undefined) {
      client.dispatchClick(headRow)
      assertTrue(expTotal.hidden === true && tileTotal.focusCalls >= 1, 'R7h', '点击展开区头部行 → 原位收起并回焦 KPI 卡')
    }
    client.dispatchKey('Enter', scanned.all.find((node) => node.getAttribute('data-pair') !== null))
    const firstPairRow = scanned.all.find((node) => node.getAttribute('data-pair') !== null)
    if (firstPairRow !== undefined) {
      const pairDetail = scanned.byId.get(firstPairRow.getAttribute('data-pair'))
      assertTrue(pairDetail.hidden === false, 'R7i', 'Enter 键展开首个产物对详情行（键盘等价通道）')
    }
    assertTrue(client.fetchLog.every((entry) => entry.method === 'GET'), 'R7j', '全部读交互零写请求（fetch 通道无 POST）')

    // 读漂移复核：页面/API/静态资产反复读取后磁盘零变更
    await http.get('/exploration')
    await http.get('/exploration')
    await http.getJson('/api/exploration')
    await http.get('/static/app.js')
    await http.get('/static/style.css')
    const afterTree = snapshotTree(explorationRoot)
    const drift = snapshotDiff(beforeTree, afterTree, inScope)
    assertTrue(drift.length === 0, 'R8', '只读基线：全部读交互后 hot.json/index.json/artifacts 内容与 mtime 零漂移', drift.join(' ; '))
  } finally {
    await shutdown(httpBase.server)
  }
  return { realOk: failures === 0 }
}

// ── S 段：沙箱副本破坏性全链 ────────────────────────────────────────────

function shaOfText(text) {
  return `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`
}

/**
 * 受控沙箱：真实引擎数据形状（compact zone JSON、artifact+summary 配对、
 * files 哈希清单），覆盖新鲜/变更/缺失/无条目/无 summary 全部状态面。
 */
function buildSandbox() {
  const sandbox = join(REPO_ROOT, '.rdd', 'tests', 'ops-dashboard-exploration-integration', '.sandbox-live')
  rmSync(sandbox, { recursive: true, force: true })
  const artifactsDir = join(sandbox, '.rdd', 'exploration', 'artifacts')
  const srcDir = join(sandbox, 'src')
  mkdirSync(artifactsDir, { recursive: true })
  mkdirSync(srcDir, { recursive: true })

  const sources = {
    'src/login.js': 'export const login = () => 1\n',
    'src/payment.js': 'export const pay = () => 2\n', // 实际内容 v2（记录哈希为 v1 → 变更）
    'src/profile.js': 'export const profile = () => 3\n',
  }
  for (const [rel, content] of Object.entries(sources)) writeFileSync(join(sandbox, rel), content, 'utf8')
  // src/config.js 有意不创建 → gamma 的清单中出现「缺失」

  const writeArtifact = (slug, recordBody, summaryBody) => {
    writeFileSync(join(artifactsDir, `${slug}.md`), `# ${slug}\n\n${recordBody}\n`, 'utf8')
    if (summaryBody !== null) writeFileSync(join(artifactsDir, `${slug}.summary.md`), `# ${slug} — summary\n\n${summaryBody}\n`, 'utf8')
  }
  writeArtifact('alpha-login-flow', '登录链路探索记录（新鲜）', '登录链路摘要：覆盖 src/login.js。')
  writeArtifact('beta-payment-check', '支付校验探索记录（已变更）', '支付校验摘要：src/payment.js 已被改动。')
  writeArtifact('gamma-config-sync', '配置同步探索记录（缺失文件）', '配置同步摘要：src/config.js 已不存在。')
  writeArtifact('delta-user-profile', '用户资料探索记录（持久层新鲜）', '用户资料摘要：src/profile.js 哈希匹配。')
  writeArtifact('orphan-legacy-notes', '历史遗留孤儿产物', '孤儿摘要：双区无关联条目。')
  writeArtifact('solo-no-summary', '无 summary 的异常配对记录', null)

  const hotEntries = [
    {
      key: 'sandbox/alpha-login-flow',
      tags: ['sandbox', 'integration'],
      brief: '登录链路探索（新鲜面）',
      path: '.rdd/exploration/artifacts/alpha-login-flow.md',
      files: { 'src/login.js': shaOfText(sources['src/login.js']) },
      registeredAt: '2026-10-20T10:00:00Z',
    },
    {
      key: 'sandbox/beta-payment-check',
      tags: ['sandbox'],
      brief: '支付校验探索（变更面）',
      path: '.rdd/exploration/artifacts/beta-payment-check.md',
      files: { 'src/payment.js': shaOfText('export const pay = () => 1\n') },
      registeredAt: '2026-10-20T11:00:00Z',
    },
  ]
  const indexEntries = [
    {
      key: 'sandbox/gamma-config-sync',
      tags: ['sandbox', 'persist'],
      brief: '配置同步探索（缺失面，无 registeredAt 容错面）',
      path: '.rdd/exploration/artifacts/gamma-config-sync.md',
      files: { 'src/config.js': shaOfText('export const config = () => 0\n') },
    },
    {
      key: 'sandbox/delta-user-profile',
      tags: ['persist'],
      brief: '用户资料探索（持久层新鲜面）',
      path: '.rdd/exploration/artifacts/delta-user-profile.md',
      files: { 'src/profile.js': shaOfText(sources['src/profile.js']) },
      registeredAt: '2026-10-19T09:30:00Z',
    },
  ]
  const compact = (entries) => JSON.stringify({ entries })
  writeFileSync(join(sandbox, '.rdd', 'exploration', 'hot.json'), compact(hotEntries), 'utf8')
  writeFileSync(join(sandbox, '.rdd', 'exploration', 'index.json'), compact(indexEntries), 'utf8')
  return { sandbox, artifactsDir, hotEntries, indexEntries }
}

async function sandboxPhase() {
  console.log('\n=== S 段：沙箱副本破坏性全链（场景 1 完整闭环）===')
  const { sandbox, artifactsDir } = buildSandbox()
  const explorationRoot = join(sandbox, '.rdd', 'exploration')
  const httpBase = await bootServer(sandbox)
  const http = makeHttp(httpBase.base)
  try {
    const beforeTree = snapshotTree(explorationRoot)

    // —— SSR 各层级与夹具真值一致 ——
    const page = await http.get('/exploration')
    assertTrue(page.status === 200, 'S1a', '沙箱 /exploration 服务端渲染 200', `status=${page.status}`)
    assertTrue(tileValue(page.body, 'kpi-total') === '4' && tileValue(page.body, 'kpi-hot') === '2' && tileValue(page.body, 'kpi-index') === '2', 'S1b', 'KPI 计数：总数 4 / 热区 2 / 持久 2', `total=${tileValue(page.body, 'kpi-total')} hot=${tileValue(page.body, 'kpi-hot')} index=${tileValue(page.body, 'kpi-index')}`)
    assertTrue(tileValue(page.body, 'kpi-pairs') === '6' && page.body.includes('5 对已配对 summary'), 'S1c', 'KPI 产物记录 6 条 · 5 对已配对', `pairs=${tileValue(page.body, 'kpi-pairs')}`)
    assertTrue(page.body.includes('1 条 artifact 记录缺少配对 summary'), 'S1d', '缺 summary 的异常配对如实进入页顶 note')

    const totalSection = sliceSection(page.body, 'exp-total', 'exp-hot')
    const hotSection = sliceSection(page.body, 'exp-hot', 'exp-index')
    const indexSection = sliceSection(page.body, 'exp-index', 'exp-pairs')
    const pairsSection = sliceSection(page.body, 'exp-pairs', 'entries-flat')
    assertTrue(countOccurrences(totalSection, 'data-entry="row-') === 4 && countOccurrences(hotSection, 'data-entry="row-') === 2 && countOccurrences(indexSection, 'data-entry="row-') === 2, 'S2a', '三个条目展开区行数 4/2/2（计数即行数）')
    assertTrue(countOccurrences(pairsSection, 'data-pair="pair-detail-') === 6, 'S2b', '产物对展开区 6 行（字母序）')

    const alphaRow = rowChunk(totalSection, 'data-entry', 'row-total-0')
    const sandboxPosix = sandbox.replaceAll('\\', '/')
    assertTrue(alphaRow.includes('登录链路探索（新鲜面）') && alphaRow.includes('sandbox/alpha-login-flow') && alphaRow.includes('2026-10-20 10:00'), 'S3a', '条目详情：摘要/key/注册时间（registeredAt 原样渲染）')
    assertTrue(alphaRow.includes(`href="vscode://file/${sandboxPosix}/.rdd/exploration/artifacts/alpha-login-flow.md"`), 'S3b', '条目详情：vscode 跳转指向记录文件绝对路径')
    assertTrue(alphaRow.includes(`data-copy="${sandboxPosix}/.rdd/exploration/artifacts/alpha-login-flow.md"`), 'S3c', '条目详情：复制路径按钮携带绝对路径')

    const pairRow = (slug) => rowChunk(pairsSection, 'data-pair', `pair-detail-${['alpha-login-flow', 'beta-payment-check', 'delta-user-profile', 'gamma-config-sync', 'orphan-legacy-notes', 'solo-no-summary'].indexOf(slug)}`)
    const alphaPair = pairRow('alpha-login-flow')
    const betaPair = pairRow('beta-payment-check')
    const gammaPair = pairRow('gamma-config-sync')
    const deltaPair = pairRow('delta-user-profile')
    const orphanPair = pairRow('orphan-legacy-notes')
    const soloPair = pairRow('solo-no-summary')
    assertTrue(alphaPair.includes('新鲜') && alphaPair.includes('data-delete-pair="alpha-login-flow"') && !alphaPair.slice(0, alphaPair.indexOf('row-detail')).includes('time-approx'), 'S4a', 'alpha：新鲜 + 删除入口 + 热区 registeredAt 无 ≈ 前缀')
    assertTrue(betaPair.includes('不新鲜 · 1 变更 0 缺失') && betaPair.includes('已变更（1）') && betaPair.includes('src/payment.js'), 'S4b', 'beta：不新鲜并列出具体变更文件')
    assertTrue(gammaPair.includes('缺失（1）') && gammaPair.includes('src/config.js') && gammaPair.includes('≈'), 'S4c', 'gamma：缺失文件列出 + 持久层时间 ≈ 文件时间近似')
    assertTrue(deltaPair.includes('新鲜') && deltaPair.includes('（文件时间 · 近似）') && deltaPair.includes('data-delete-pair="delta-user-profile"'), 'S4d', 'delta：持久层新鲜 + 近似时间口径 + 删除入口（双轨对照）')
    assertTrue(orphanPair.includes('无条目') && !orphanPair.includes('data-delete-pair'), 'S4e', 'orphan：无条目标注 + 无删除入口（D10）')
    assertTrue(soloPair.includes('—（无 summary 文件）') && soloPair.includes('配对状态') && !soloPair.includes('data-delete-pair'), 'S4f', 'solo：无 summary 异常配对如实标注 + 无死链 + 无删除入口')
    assertTrue(alphaPair.includes('artifact 路径') && alphaPair.includes('summary 路径') && alphaPair.includes('.rdd/exploration/artifacts/alpha-login-flow.summary.md'), 'S4g', '产物对详情：相关产物双路径可见')

    // —— 客户端全场景点击链 ——
    const scanned = scanNodes(page.body)
    const client = installClientStub(scanned, httpBase.base, page.body)
    bootClientApp()
    const tileTotal = scanned.byId.get('kpi-total')
    const tilePairs = scanned.byId.get('kpi-pairs')
    const expTotal = scanned.byId.get('exp-total')
    const expPairs = scanned.byId.get('exp-pairs')
    client.dispatchClick(tileTotal)
    const entryRowAlpha = scanned.all.find((node) => node.getAttribute('data-entry') === 'row-total-0')
    client.dispatchClick(entryRowAlpha)
    assertTrue(expTotal.hidden === false && scanned.byId.get('row-total-0').hidden === false, 'S5a', '点击条目总数 → 合并明细展开 → 点开 alpha 条目详情（层级递进）')
    const vscodeInAlpha = scanned.all.find((node) => node.tagName === 'a' && String(node.getAttribute('href') ?? '').includes('alpha-login-flow'))
    client.dispatchClick(vscodeInAlpha)
    assertTrue(scanned.byId.get('row-total-0').hidden === false, 'S5b', '详情内 vscode 链接点击不冒泡收起详情')
    const copyInAlpha = scanned.all.find((node) => node.classList.contains('btn-copy') && String(node.getAttribute('data-copy') ?? '').includes('alpha-login-flow'))
    client.dispatchClick(copyInAlpha)
    await settle()
    assertTrue(!client.navigatorInstalled || client.clipboardLog.includes(`${sandboxPosix}/.rdd/exploration/artifacts/alpha-login-flow.md`), 'S5c', '条目详情「复制路径」落地剪贴板')

    client.dispatchClick(tilePairs)
    const pairRowAlpha = scanned.all.find((node) => node.getAttribute('data-pair') === 'pair-detail-0')
    client.dispatchClick(pairRowAlpha)
    assertTrue(expPairs.hidden === false && scanned.byId.get('pair-detail-0').hidden === false, 'S5d', '点击产物记录卡 → 产物对清单展开 → 点开 alpha 产物对详情')

    const deleteAlpha = scanned.all.find((node) => node.getAttribute('data-delete-pair') === 'alpha-login-flow')
    // 取消二次确认：零请求、零磁盘变更
    client.confirmResult.value = false
    client.dispatchClick(deleteAlpha)
    await settle()
    assertTrue(client.confirmCalls.length === 1 && client.confirmCalls[0].includes('alpha-login-flow'), 'S5e', '删除先弹二次确认（文案含 slug 与不可恢复提示）')
    assertTrue(client.fetchLog.every((entry) => entry.method === 'GET'), 'S5f', '取消二次确认 → 零写请求')
    const afterCancel = snapshotTree(explorationRoot)
    assertTrue(snapshotDiff(beforeTree, afterCancel).length === 0, 'S5g', '取消二次确认 → 沙箱树零变更（含 mtime）')

    // 确认删除 alpha（热区对）
    const hotBeforeBytes = readFileSync(join(explorationRoot, 'hot.json'))
    const indexBeforeBytes = readFileSync(join(explorationRoot, 'index.json'))
    const indexBeforeMtime = statSync(join(explorationRoot, 'index.json')).mtimeMs
    client.confirmResult.value = true
    client.dispatchClick(deleteAlpha)
    const alphaGone = await waitFor(() => !existsSync(join(artifactsDir, 'alpha-login-flow.md')) && !existsSync(join(artifactsDir, 'alpha-login-flow.summary.md')), 4000)
    assertTrue(alphaGone, 'S5h', '确认删除 → artifact+summary 成对消失（热区对）')
    await settle()
    const deletePost = client.fetchLog.filter((entry) => entry.method === 'POST').map((entry) => entry.url)
    assertTrue(deletePost.some((url) => url.endsWith('/api/exploration/pair/delete')), 'S5i', '确认删除 → 经 UI 写通道 POST /api/exploration/pair/delete')
    const hotAfter = readZoneEntries(join(explorationRoot, 'hot.json'))
    assertTrue(hotAfter.length === 1 && hotAfter[0].key === 'sandbox/beta-payment-check', 'S5j', 'hot.json 同步移除 alpha 条目（剩 beta）')
    assertTrue(readFileSync(join(explorationRoot, 'index.json')).equals(indexBeforeBytes) && statSync(join(explorationRoot, 'index.json')).mtimeMs === indexBeforeMtime, 'S5k', '无关 zone（index.json）字节与 mtime 均不动')
    const hotAfterText = readFileSync(join(explorationRoot, 'hot.json'), 'utf8')
    assertTrue(hotAfterText === JSON.stringify({ entries: hotAfter }), 'S5l', 'zone 写形状 = 引擎同款紧凑 JSON（往返兼容）', JSON.stringify(hotAfterText.slice(0, 60)))
    assertTrue(readdirSync(artifactsDir).every((name) => !name.includes('.tmp')) && readdirSync(explorationRoot).every((name) => !name.includes('.tmp')), 'S5m', '删除后 artifacts/ 与 exploration/ 无 .tmp 残留')
    const mainNode = scanned.byId.get('ops-main')
    const swapped = await waitFor(() => mainNode.innerHTML.length > 0 && !mainNode.innerHTML.includes('alpha-login-flow'), 4000)
    assertTrue(swapped && tileValue(mainNode.innerHTML, 'kpi-total') === '3' && tileValue(mainNode.innerHTML, 'kpi-pairs') === '5', 'S5n', '删除成功后刷新管线换页：alpha 消失、计数 3/5（条目/计数一致递减）', `swapped=${swapped} total=${tileValue(mainNode.innerHTML, 'kpi-total')} pairs=${tileValue(mainNode.innerHTML, 'kpi-pairs')}`)

    const page2 = await http.get('/exploration')
    assertTrue(tileValue(page2.body, 'kpi-total') === '3' && tileValue(page2.body, 'kpi-hot') === '1' && tileValue(page2.body, 'kpi-index') === '2' && tileValue(page2.body, 'kpi-pairs') === '5', 'S6a', '删除后独立复取：计数 3/1/2/5 三处一致', `t=${tileValue(page2.body, 'kpi-total')} h=${tileValue(page2.body, 'kpi-hot')} i=${tileValue(page2.body, 'kpi-index')} p=${tileValue(page2.body, 'kpi-pairs')}`)
    assertTrue(!page2.body.includes('alpha-login-flow') && page2.body.includes('beta-payment-check') && page2.body.includes('delta-user-profile'), 'S6b', '删除后条目与产物文件三处一致消失（其余保留）')
    assertTrue(!existsSync(join(artifactsDir, 'alpha-login-flow.md')) && !existsSync(join(artifactsDir, 'alpha-login-flow.summary.md')), 'S6c', '磁盘复核：alpha 双文件无残留')

    // —— 错误契约（直接 HTTP 面）——
    const preErrors = snapshotTree(explorationRoot)
    const orphanDelete = await http.post('/api/exploration/pair/delete', { slug: 'orphan-legacy-notes' })
    assertTrue(orphanDelete.status === 422 && orphanDelete.json?.code === 'orphan-not-deletable', 'S7a', '孤儿产物对删除 → 422 orphan-not-deletable', `status=${orphanDelete.status} code=${orphanDelete.json?.code}`)
    const reDelete = await http.post('/api/exploration/pair/delete', { slug: 'alpha-login-flow' })
    assertTrue(reDelete.status === 404 && reDelete.json?.code === 'pair-not-found', 'S7b', '幂等重删 → 404 pair-not-found', `status=${reDelete.status}`)
    const badPayload = await http.post('/api/exploration/pair/delete', {})
    assertTrue(badPayload.status === 400 && badPayload.json?.code === 'invalid-payload', 'S7c', '空 payload → 400 invalid-payload')
    const traversal = await http.post('/api/exploration/pair/delete', { slug: '../hot' })
    assertTrue(traversal.status === 400 && traversal.json?.code === 'invalid-payload', 'S7d', '路径穿越 slug → 400（硬门）')
    const backslash = await http.post('/api/exploration/pair/delete', { slug: 'a\\b' })
    assertTrue(backslash.status === 400, 'S7e', '反斜杠 slug → 400')
    const methodGuard = await fetch(`${httpBase.base}/api/exploration/pair/delete`)
    assertTrue(methodGuard.status === 405, 'S7f', 'GET 打写端点 → 405 方法守卫', `status=${methodGuard.status}`)
    const afterErrors = snapshotTree(explorationRoot)
    assertTrue(snapshotDiff(preErrors, afterErrors).length === 0 && existsSync(join(artifactsDir, 'orphan-legacy-notes.md')), 'S7g', '全部拒绝路径零数据变更（孤儿文件仍在）')

    // —— 持久层对删除（gamma：缺失面条目）——
    const hotBytesBeforeGamma = readFileSync(join(explorationRoot, 'hot.json'))
    const gammaDelete = await http.post('/api/exploration/pair/delete', { slug: 'gamma-config-sync' })
    assertTrue(gammaDelete.status === 200 && gammaDelete.json?.ok === true && gammaDelete.json?.removed?.index === 1 && gammaDelete.json?.removed?.hot === 0, 'S8a', '持久层产物对删除：removed index=1 hot=0', JSON.stringify(gammaDelete.json))
    assertTrue(!existsSync(join(artifactsDir, 'gamma-config-sync.md')) && !existsSync(join(artifactsDir, 'gamma-config-sync.summary.md')), 'S8b', 'gamma 双文件成对消失')
    assertTrue(readFileSync(join(explorationRoot, 'hot.json')).equals(hotBytesBeforeGamma), 'S8c', '本次无关 zone（hot.json）字节不动')
    const indexAfterGamma = readFileSync(join(explorationRoot, 'index.json'), 'utf8')
    assertTrue(indexAfterGamma === JSON.stringify(JSON.parse(indexAfterGamma)), 'S8d', 'index.json 紧凑形状往返一致')
    const page3 = await http.get('/exploration')
    assertTrue(tileValue(page3.body, 'kpi-total') === '2' && tileValue(page3.body, 'kpi-index') === '1' && tileValue(page3.body, 'kpi-pairs') === '4', 'S8e', 'gamma 删除后计数 2/1/4 一致', `t=${tileValue(page3.body, 'kpi-total')} i=${tileValue(page3.body, 'kpi-index')} p=${tileValue(page3.body, 'kpi-pairs')}`)
    assertTrue(!page3.body.includes('gamma-config-sync') && page3.body.includes('delta-user-profile'), 'S8f', 'gamma 消失、delta 保留')

    // —— 收尾只读漂移复核 ——
    const finalTree = snapshotTree(explorationRoot)
    await http.get('/exploration')
    await http.getJson('/api/exploration')
    await http.get('/static/style.css')
    const finalTree2 = snapshotTree(explorationRoot)
    assertTrue(snapshotDiff(finalTree, finalTree2).length === 0, 'S9', '收尾只读复核：删除后再次全读零漂移')
  } finally {
    await shutdown(httpBase.server)
    rmSync(sandbox, { recursive: true, force: true })
  }
}

// ── 主流程 ──────────────────────────────────────────────────────────────

async function main() {
  const engineHashesBefore = ENGINE_SCRIPTS.map((path) => shaFile(path))
  await realRepoPhase()
  await sandboxPhase()
  const engineHashesAfter = ENGINE_SCRIPTS.map((path) => shaFile(path))
  assertTrue(engineHashesBefore.every((hash, index) => hash === engineHashesAfter[index]), 'P0', '引擎脚本 explore.ps1/explore-store.ps1 全程零改动（SHA256 恒定）')

  console.log(`\n集成联调总结：total=${total} pass=${total - failures} fail=${failures}`)
  if (failures > 0) {
    console.error('INTEGRATION FAILED')
    process.exitCode = 1
  } else {
    console.log('总结论：通过（端到端集成全绿）')
  }
}

main().catch((error) => {
  console.error(`集成联调脚本异常终止：${error instanceof Error ? error.stack : String(error)}`)
  process.exitCode = 1
})

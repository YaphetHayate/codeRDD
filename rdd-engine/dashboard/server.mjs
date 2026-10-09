#!/usr/bin/env node
// RDD operations dashboard — zero-dependency local read-only service.
//
// One command starts it (rdd-engine/scripts/dashboard.cmd → this file), every
// request re-reads .rdd/ from disk with no cache layer (AC 4), and each page is
// rendered server-side so the numbers are present in the served HTML even
// without JavaScript. /api/* exposes the same data as the CTO-contracted
// envelope {domain, available, meta, data}.
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join, normalize, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

import { resolveDataRoot } from './lib/paths.mjs'
import { createDataRootHolder } from './lib/data-root.mjs'
import { pickDirectory } from './lib/native-dialog.mjs'
import { readAllDomains, buildOverview, navCounts, DOMAIN_DEFS } from './lib/overview.mjs'
import { readArchiveDetail } from './lib/readers/archives.mjs'
import { makeEnvelope } from './lib/io.mjs'
import { renderOverview } from './lib/views/overview.mjs'
import { renderRequirementsPage, renderRequirementDetail } from './lib/views/requirements.mjs'
import { renderExplorationPage } from './lib/views/exploration.mjs'
import { renderHitRatePage } from './lib/views/hit-rate.mjs'
import { renderQualityPage } from './lib/views/quality.mjs'
import { renderTipsPage } from './lib/views/tips.mjs'
import { renderGoalTreesPage } from './lib/views/goal-trees.mjs'

const DEFAULT_PORT = 8787
const HOST = '127.0.0.1'
const STATIC_ROOT = normalize(fileURLToPath(new URL('./static/', import.meta.url))).replace(/[\\/]+$/, '')
const MIME_TYPES = {
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.ico': 'image/x-icon',
}

/** Parse "-Port <n>" / "--port <n>" / "--port=<n>" (default 8787). */
function parsePort(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    const inline = /^--?(?:port|p)=(\d+)$/i.exec(arg)
    if (inline !== null) return Number(inline[1])
    if (/^--?(?:port|p)$/i.test(arg) && argv[index + 1] !== undefined) {
      const value = Number(argv[index + 1])
      if (Number.isInteger(value) && value > 0 && value < 65536) return value
      throw new Error(`端口参数无效：${argv[index + 1]}（应为 1-65535 的整数）`)
    }
  }
  return DEFAULT_PORT
}

/** Send a response with the dashboard's no-store policy. */
function send(res, status, contentType, body) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store, must-revalidate',
    'X-Content-Type-Options': 'nosniff',
  })
  res.end(body)
}

/** JSON response (API face). */
function sendJson(res, status, payload) {
  send(res, status, 'application/json; charset=utf-8', `${JSON.stringify(payload, null, 2)}\n`)
}

/** Largest accepted request body — switch payloads are one path, bytes at most. */
const MAX_BODY_BYTES = 8192

/** Read one request body as a UTF-8 string (oversized bodies reject). */
function readRequestBody(req) {
  return new Promise((resolveBody, rejectBody) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        rejectBody(new Error('请求体超过大小上限'))
        req.removeAllListeners('data')
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolveBody(Buffer.concat(chunks).toString('utf8')))
    req.on('error', rejectBody)
  })
}

/** Parse the request body as a JSON object (null when absent or malformed). */
async function parseJsonBody(req) {
  const raw = await readRequestBody(req)
  if (raw.trim() === '') return null
  try {
    const parsed = JSON.parse(raw)
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null
  } catch {
    return null
  }
}

/** POST /api/project/pick — spawn the native directory dialog (control plane). */
async function handleProjectPick(res) {
  const outcome = await pickDirectory()
  if (outcome.status === 'picked') return sendJson(res, 200, { ok: true, path: outcome.path })
  if (outcome.status === 'canceled') return sendJson(res, 200, { ok: false, code: 'canceled' })
  return sendJson(res, 200, { ok: false, code: outcome.code, message: outcome.message })
}

/** POST /api/project/switch — validate + atomically swap the current root. */
async function handleProjectSwitch(req, res, holder) {
  const payload = await parseJsonBody(req)
  if (payload === null || typeof payload.path !== 'string') {
    return sendJson(res, 400, { ok: false, code: 'invalid-payload', message: '请求体必须是 JSON 对象：{"path": "<RDD 项目目录>"}。' })
  }
  const previousRoot = holder.getCurrent().projectRoot
  const result = holder.switchTo(payload.path)
  if (result.ok !== true) {
    const tail = result.code === 'no-rdd-dir' ? `数据根保持 ${previousRoot} 不变，可重新选择。` : '数据根保持不变。'
    return sendJson(res, 422, { ok: false, code: result.code, message: `拒绝切换：${result.message}${tail}` })
  }
  return sendJson(res, 200, { ok: true, projectRoot: result.projectRoot, previousRoot })
}

/** Read every domain once for this request and build the shared view input. */
function buildViewInput(context, routeKey) {
  const domains = readAllDomains(context)
  return {
    domains,
    counts: navCounts(domains),
    projectRoot: context.projectRoot,
    generatedAt: new Date().toISOString(),
    route: routeKey,
  }
}

/** Static assets under dashboard/static (path traversal rejected). */
async function serveStatic(pathname, res) {
  const relative = normalize(decodeURIComponent(pathname.slice('/static/'.length)))
  const absolute = join(STATIC_ROOT, relative)
  if (!absolute.startsWith(STATIC_ROOT + sep) || relative.includes('..')) {
    send(res, 403, 'text/plain; charset=utf-8', 'forbidden\n')
    return
  }
  try {
    const body = await readFile(absolute)
    send(res, 200, MIME_TYPES[extname(absolute)] ?? 'application/octet-stream', body)
  } catch {
    send(res, 404, 'text/plain; charset=utf-8', 'not found\n')
  }
}

/** HTML page routes. */
function servePage(pathname, res, context) {
  if (pathname === '/requirements') {
    return send(res, 200, 'text/html; charset=utf-8', renderRequirementsPage(buildViewInput(context, 'requirements')))
  }
  const detailMatch = /^\/requirements\/([^/]+)\/([^/]+)$/.exec(pathname)
  if (detailMatch !== null) {
    const archive = decodeURIComponent(detailMatch[1])
    const taskId = decodeURIComponent(detailMatch[2])
    const input = buildViewInput(context, 'requirements')
    input.detail = readArchiveDetail(context, archive, taskId)
    input.archive = archive
    input.taskId = taskId
    const html = renderRequirementDetail(input)
    return send(res, input.detail.available === false ? 404 : 200, 'text/html; charset=utf-8', html)
  }
  const domainRoutes = {
    '/exploration': renderExplorationPage,
    '/hit-rate': renderHitRatePage,
    '/quality': renderQualityPage,
    '/tips': renderTipsPage,
    '/goal-trees': renderGoalTreesPage,
  }
  if (pathname === '/') {
    const input = buildViewInput(context, 'overview')
    input.overview = buildOverview(input.domains)
    return send(res, 200, 'text/html; charset=utf-8', renderOverview(input))
  }
  if (pathname in domainRoutes) {
    const key = DOMAIN_DEFS.find((definition) => definition.route === pathname)?.key ?? 'overview'
    return send(res, 200, 'text/html; charset=utf-8', domainRoutes[pathname](buildViewInput(context, key)))
  }
  return send(res, 404, 'text/html; charset=utf-8', renderNotFound(pathname, context))
}

/** 404 page with a route back to the overview. */
function renderNotFound(pathname, context) {
  const input = buildViewInput(context, 'overview')
  input.overview = buildOverview(input.domains)
  input.notice = `<section class="panel"><div class="panel-head"><div class="panel-title">未识别的路由</div></div><div class="panel-body"><p class="prose">未识别的路由 <code>${pathname.replace(/[<>&"]/g, '')}</code>，已回到总览。可用路由：<code>/</code>、<code>/requirements</code>、<code>/exploration</code>、<code>/hit-rate</code>、<code>/quality</code>、<code>/tips</code>、<code>/goal-trees</code>。</p></div><div class="panel-foot"><a class="btn" href="/">返回总览</a></div></section>`
  return renderOverview(input)
}

/** API routes — the CTO-contracted envelope per domain, plus control plane. */
function serveApi(pathname, req, res, holder) {
  if (pathname === '/api/project/pick' || pathname === '/api/project/switch') {
    if (req.method !== 'POST') {
      sendJson(res, 405, { ok: false, code: 'method-not-allowed', message: '该端点只接受 POST。' })
      return
    }
    if (pathname === '/api/project/pick') return handleProjectPick(res)
    return handleProjectSwitch(req, res, holder)
  }
  const context = holder.getCurrent()
  if (pathname === '/api/overview') {
    const domains = readAllDomains(context)
    const overview = buildOverview(domains)
    const env = makeEnvelope('overview', 'all P0 domains', [])
    env.available = DOMAIN_DEFS.some((definition) => domains[definition.key].available)
    env.data = {
      cards: overview.cards,
      crossDomain: overview.crossDomain,
      recent: overview.recent,
      fixture: overview.fixture,
      domains: domains,
    }
    return sendJson(res, 200, env)
  }
  const detailMatch = /^\/api\/requirements\/([^/]+)\/([^/]+)$/.exec(pathname)
  if (detailMatch !== null) {
    const env = readArchiveDetail(context, decodeURIComponent(detailMatch[1]), decodeURIComponent(detailMatch[2]))
    return sendJson(res, env.available ? 200 : 404, env)
  }
  const definition = DOMAIN_DEFS.find((entry) => `/api${entry.route}` === pathname)
  if (definition !== undefined) {
    const domains = readAllDomains(context)
    return sendJson(res, 200, domains[definition.key])
  }
  return sendJson(res, 404, { error: 'unknown endpoint', path: pathname })
}

/** Build the request handler bound to a swappable data-root holder. */
function createHandler(holder) {
  return (req, res) => {
    try {
      const sentinel = 'http://127.0.0.1'
      const url = new URL(req.url ?? '/', sentinel)
      const pathname = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, '') : url.pathname
      if (pathname === '/favicon.ico') return send(res, 204, 'image/x-icon', '')
      if (pathname.startsWith('/static/')) {
        serveStatic(url.pathname, res)
        return
      }
      if (pathname.startsWith('/api/')) {
        const outcome = serveApi(pathname, req, res, holder)
        if (outcome instanceof Promise) {
          outcome.catch((error) => {
            const message = error instanceof Error ? error.message : String(error)
            sendJson(res, 500, { ok: false, code: 'internal', message })
          })
        }
        return
      }
      servePage(pathname, res, holder.getCurrent())
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      const body = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>取数失败</title></head><body><h1>该数据域取数失败（HTTP 500）</h1><p>其余数据域不受影响。请刷新重试；若持续失败，检查 .rdd/ 数据文件是否可读。</p><pre>${message.replace(/[<>&]/g, '')}</pre></body></html>`
      send(res, 500, 'text/html; charset=utf-8', body)
    }
  }
}

/** Announce the URL on stdout — users must know where to open the board (AC 1). */
function announce(context, port) {
  const lines = [
    `RDD 运营看板 · 数据根 ${context.projectRoot}`,
    `看板服务已启动：http://${HOST}:${port}`,
    '在浏览器打开上面的地址（Ctrl+C 停止服务）',
  ]
  process.stdout.write(`${lines.join('\n')}\n`)
}

/** Start the server (exported for tests). */
export function startServer(options = {}) {
  const port = options.port ?? DEFAULT_PORT
  const holder = createDataRootHolder(options.context ?? resolveDataRoot())
  const server = createServer(createHandler(holder))
  server.on('error', (error) => {
    if (error.code === 'EADDRINUSE') {
      process.stderr.write(
        `端口 ${port} 已被占用（EADDRINUSE）。处置：① 关闭已在运行的看板实例；② 用 -Port <其他端口> 启动。\n`
      )
      process.exit(1)
    }
    process.stderr.write(`看板启动失败：${error.message}\n`)
    process.exit(1)
  })
  server.listen(port, HOST, () => {
    if (options.quiet !== true) announce(holder.getCurrent(), port)
    if (typeof options.onReady === 'function') options.onReady(server)
  })
  return server
}

/** CLI entry: resolve the data root first so failures are actionable. */
function main() {
  let port
  let context
  try {
    port = parsePort(process.argv.slice(2))
    context = resolveDataRoot()
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exit(1)
  }
  startServer({ port, context })
}

const invokedDirectly = (() => {
  const entryPath = process.argv[1] === undefined ? '' : resolve(process.argv[1])
  if (entryPath === '') return false
  const selfPath = fileURLToPath(import.meta.url)
  return process.platform === 'win32'
    ? entryPath.toLowerCase() === selfPath.toLowerCase()
    : entryPath === selfPath
})()
if (invokedDirectly) main()

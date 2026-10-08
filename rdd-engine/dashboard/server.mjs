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

/** API routes — the CTO-contracted envelope per domain. */
function serveApi(pathname, res, context) {
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

/** Build the request handler bound to a resolved data root. */
function createHandler(context) {
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
        serveApi(pathname, res, context)
        return
      }
      servePage(pathname, res, context)
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
  const context = options.context ?? resolveDataRoot()
  const server = createServer(createHandler(context))
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
    if (options.quiet !== true) announce(context, port)
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

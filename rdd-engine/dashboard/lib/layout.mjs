// AppShell layout: sidebar + topbar + content + footer (UX §4.1, §5.1–5.3).
//
// The page is rendered server-side on every request, so the numbers are in the
// served HTML (no fetch-then-paint dependency) and app.js only adds behaviour:
// theme, sidebar collapse, refresh, keyboard shortcuts, copy, row filtering.
import { DOMAIN_DEFS } from './overview.mjs'
import { esc, dateTime, shortenPath } from './format.mjs'
import { icon } from './components.mjs'

/** Critical design tokens inlined to avoid a flash of unstyled content. */
const CRITICAL_TOKENS = `:root{--ops-bg-app:rgb(245,246,247);--ops-bg-surface:#FFFFFF;--ops-text-primary:rgb(15,17,21);--ops-text-secondary:rgb(97,102,107);--ops-border-subtle:rgba(0,0,0,0.06);--ops-action-primary:rgb(65,118,230);--ops-action-fill:rgb(72,104,178);--ops-sidebar-width:220px;--ops-font-sans:"PingFang SC","Microsoft YaHei","Segoe UI",system-ui,-apple-system,sans-serif}html[data-theme="dark"]{--ops-bg-app:rgb(21,21,23);--ops-bg-surface:rgb(35,35,36);--ops-text-primary:rgb(249,250,251);--ops-text-secondary:rgb(207,211,214);--ops-border-subtle:rgba(255,255,255,0.08);--ops-action-primary:rgb(103,158,254)}html,body{margin:0;background:var(--ops-bg-app);color:var(--ops-text-primary);font-family:var(--ops-font-sans);font-size:14px}`

/** Inline boot script: applies the stored theme before first paint (no FOUC). */
const THEME_BOOT = `(function(){try{var t=localStorage.getItem('ops-dashboard:theme');if(t==='dark'||t==='light'){document.documentElement.setAttribute('data-theme',t)}}catch(e){}})()`

/** One sidebar navigation item. */
function navItem(definition, activeKey, count) {
  const isActive = definition.key === activeKey
  const badgeValue = count === undefined ? '' : `<span class="nav-count">${esc(count)}</span>`
  return `<a class="nav-item${isActive ? ' is-active' : ''}" href="${esc(definition.route)}"${
    isActive ? ' aria-current="page"' : ''
  }>${icon(definition.icon, 'nav-icon')}<span class="nav-text">${esc(definition.title)}</span>${badgeValue}</a>`
}

/** Sidebar: brand, domain navigation, read-only badge. */
function renderSidebar(activeKey, counts) {
  const items = [
    navItem({ key: 'overview', title: '总览', route: '/', icon: 'overview' }, activeKey, undefined),
    ...DOMAIN_DEFS.map((definition) => navItem(definition, activeKey, counts[definition.key])),
  ].join('')
  return `<aside class="sidebar" id="ops-sidebar"><div class="brand"><span class="brand-mark">${icon('overview', 'brand-icon')}</span><div class="brand-text"><span class="brand-name">RDD 看板</span><span class="brand-sub">本地 · 双点可写</span></div></div><div class="nav-group"><span class="nav-group-title">数据域</span>${items}</div><div class="sidebar-foot"><span class="chip chip-strong">只读数据面</span><span class="sidebar-note">消费 .rdd/ · 可写：search-config.json + ux_subagent.json（配置中心）</span></div></aside>`
}

/** Switcher panel skeleton (UX §5.2/§5.7) — SSR so it is truthful without JS. */
function renderSwitcherPanel(options) {
  return `<section class="switcher" id="ops-project-panel" role="region" aria-label="切换数据根" hidden>
<div class="switcher-head"><div class="switcher-title">切换数据根（项目）</div><div class="switcher-current">当前 <code>${esc(options.projectRoot)}</code></div><button type="button" class="btn btn-ghost switcher-close" id="ops-project-close">${icon('chevron', 'btn-icon')}<span class="btn-text">收起</span></button></div>
<div class="switcher-primary"><button type="button" class="btn btn-primary" id="ops-project-pick">${icon('switch', 'btn-icon')}<span class="btn-text">浏览目录选择…</span></button><p class="switcher-hint">在弹出的 Windows 目录选择窗口中选定另一个 RDD 项目目录；服务不重启，切换即时生效。</p></div>
<div class="switcher-divider"><span>或 手动输入路径</span></div>
<div class="switcher-manual"><label class="switcher-label" for="ops-project-path">项目路径</label><input class="switcher-input" id="ops-project-path" type="text" placeholder="D:\\work\\other-rdd-project" autocomplete="off" spellcheck="false"><button type="button" class="btn" id="ops-project-apply"><span class="btn-text">校验并切换</span></button></div>
<div class="switcher-note" id="ops-project-note" aria-live="polite"></div>
</section>`
}

/** TopBar: data root, project switch, freshness, refresh + theme controls. */
function renderTopBar(options) {
  const switcherTitle = '切换数据根（快捷键 P）'
  return `<header class="topbar"><span class="root-chip">数据根 <code>${esc(shortenPath(options.projectRoot, 46))}</code></span><button type="button" class="btn btn-ghost topbar-switch" id="ops-project-switch" aria-expanded="false" aria-controls="ops-project-panel" title="${esc(switcherTitle)}" aria-label="${esc(switcherTitle)}">${icon('switch', 'btn-icon')}<span class="btn-text">切换</span></button><span class="freshness" id="ops-freshness" data-at="${esc(options.generatedAt)}">最近更新 <b>${esc(dateTime(options.generatedAt))}</b> <span class="freshness-tz">UTC</span></span><span class="topbar-actions"><button type="button" class="btn btn-primary" id="ops-refresh" aria-live="polite">${icon('refresh', 'btn-icon')}<span class="btn-text">刷新</span></button><button type="button" class="btn" id="ops-theme" aria-pressed="false">${icon('theme', 'btn-icon')}<span class="btn-text">深色</span></button></span>${renderSwitcherPanel(options)}</header>`
}

/** Page footer: read-only statement, data root, generation time, accounting. */
function renderFooter(options) {
  const fixture = options.fixture
  const fixtureText =
    fixture === undefined || fixture.excludedCount === 0
      ? '统计口径：仅含真实交付数据，未发现测试夹具目录。'
      : `统计口径：已排除 ${fixture.excludedCount} 个测试夹具目录（枚举 ${fixture.enumeratedCount} 个交付树目录）。`
  return `<footer class="page-foot"><span>数据面只读 · 可写：search-config.json / ux_subagent.json（配置中心） · 数据根 <code>${esc(options.projectRoot)}</code></span><span>生成时间 ${esc(dateTime(options.generatedAt))} UTC</span><span>${esc(fixtureText)}</span></footer>`
}

/**
 * Render the complete HTML document.
 * @param {{title: string, activeKey: string, counts: object, options: object, body: string, boot?: object}} input
 */
export function renderLayout(input) {
  const options = input.options
  const boot = JSON.stringify({
    route: options.route ?? '/',
    generatedAt: options.generatedAt,
    theme: 'light',
  })
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(input.title)} · RDD 运营看板</title>
<link rel="stylesheet" href="/static/style.css">
<style>${CRITICAL_TOKENS}</style>
<script>${THEME_BOOT}</script>
</head>
<body data-route="${esc(input.activeKey)}">
<a class="skip-link" href="#ops-main">跳到主内容</a>
<div class="app" id="ops-app">
${renderSidebar(input.activeKey, input.counts)}
<div class="main">
${renderTopBar(options)}
<main class="content" id="ops-main">
<div id="ops-flash-slot" hidden></div>
${input.body}
</main>
${renderFooter(options)}
</div>
</div>
<script type="application/json" id="ops-boot">${boot.replace(/</g, '\\u003c')}</script>
<script type="module" src="/static/app.js"></script>
</body>
</html>`
}

/**
 * Standard page header for domain views (UX §3.2.2).
 * @param {{title: string, subtitle: string, envelope: object, badgeHtml?: string}} input
 */
export function domainHeader(input) {
  const meta = input.envelope.meta
  return `<header class="domain-head"><div class="domain-title"><h1>${esc(input.title)}</h1>${input.badgeHtml ?? ''}</div><p class="domain-sub">${esc(input.subtitle)}</p><div class="domain-meta"><span>来源 <code>${esc(meta.source)}</code></span><span>生成于 ${esc(dateTime(meta.generatedAt))} UTC</span></div></header>`
}

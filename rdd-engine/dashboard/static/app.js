// Dashboard behaviours. Everything visible is rendered server-side; this file
// only adds interaction: theme, hero collapse, refresh, shortcuts, path copy,
// row navigation and the miss-query detail filter (UX §6).
//
// Loaded as a module (layout.mjs) so this top level is the script scope: no
// wrapper IIFE is needed and nothing leaks onto `window`.
var THEME_KEY = 'ops-dashboard:theme'
var HERO_KEY = 'ops-dashboard:hero-collapsed'
var REFRESH_HIGHLIGHT_MS = 600
var SHORTCUT_ROUTES = ['/', '/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees']

function readStorage(key) {
  try {
    return window.localStorage.getItem(key)
  } catch (error) {
    return null
  }
}

function writeStorage(key, value) {
  try {
    window.localStorage.setItem(key, value)
  } catch (error) {
    /* private mode: remembering is a nicety, not a requirement */
  }
}

// ── theme ────────────────────────────────────────────────────────────
function currentTheme() {
  return document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light'
}

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme)
  var button = document.getElementById('ops-theme')
  if (button !== null) {
    button.setAttribute('aria-pressed', theme === 'dark' ? 'true' : 'false')
    var label = button.querySelector('.btn-text')
    if (label !== null) label.textContent = theme === 'dark' ? '浅色' : '深色'
  }
}

function setupTheme() {
  var stored = readStorage(THEME_KEY)
  applyTheme(stored === 'dark' || stored === 'light' ? stored : currentTheme())
  var button = document.getElementById('ops-theme')
  if (button === null) return
  button.addEventListener('click', function () {
    var next = currentTheme() === 'dark' ? 'light' : 'dark'
    applyTheme(next)
    writeStorage(THEME_KEY, next)
  })
}

// ── hero collapse (remembered) ───────────────────────────────────────
function applyHeroCollapsed(collapsed) {
  var hero = document.getElementById('ops-hero')
  var toggle = document.getElementById('ops-hero-toggle')
  if (hero === null) return
  hero.classList.toggle('is-collapsed', collapsed)
  if (toggle !== null) toggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true')
}

function setupHero() {
  applyHeroCollapsed(readStorage(HERO_KEY) === '1')
  var toggle = document.getElementById('ops-hero-toggle')
  if (toggle === null) return
  toggle.addEventListener('click', function () {
    var hero = document.getElementById('ops-hero')
    var collapsed = hero !== null && !hero.classList.contains('is-collapsed')
    applyHeroCollapsed(collapsed)
    writeStorage(HERO_KEY, collapsed ? '1' : '0')
  })
}

// ── sidebar collapse (session only) ──────────────────────────────────
function toggleSidebar() {
  var app = document.getElementById('ops-app')
  if (app !== null) app.classList.toggle('is-sidebar-collapsed')
}

// ── refresh: re-fetch this view, swap <main>, flash freshness ────────
function flashFreshness() {
  var freshness = document.getElementById('ops-freshness')
  if (freshness === null) return
  freshness.classList.add('is-flash')
  window.setTimeout(function () {
    freshness.classList.remove('is-flash')
  }, REFRESH_HIGHLIGHT_MS)
}

/** Swap the freshly fetched <main> and freshness strip into the live document. */
function swapRefreshedContent(html) {
  var parser = new window.DOMParser()
  var next = parser.parseFromString(html, 'text/html')
  var main = document.getElementById('ops-main')
  var incoming = next.getElementById('ops-main')
  if (main !== null && incoming !== null) {
    main.innerHTML = incoming.innerHTML
    bindContent(main)
  }
  var nextFresh = next.getElementById('ops-freshness')
  var freshness = document.getElementById('ops-freshness')
  if (nextFresh !== null && freshness !== null) {
    freshness.innerHTML = nextFresh.innerHTML
    freshness.setAttribute('data-at', nextFresh.getAttribute('data-at') || '')
  }
  flashFreshness()
}

/** Loading state of the refresh button (start = true, finish = false). */
function setRefreshBusy(button, label, busy) {
  button.disabled = busy
  if (busy) {
    button.setAttribute('aria-busy', 'true')
    button.classList.add('is-loading')
  } else {
    button.removeAttribute('aria-busy')
    button.classList.remove('is-loading')
  }
  if (label !== null) label.textContent = busy ? '刷新中' : '刷新'
}

function refreshView() {
  var button = document.getElementById('ops-refresh')
  if (button === null || button.disabled) return
  var label = button.querySelector('.btn-text')
  setRefreshBusy(button, label, true)
  window
    .fetch(window.location.pathname + window.location.search, { cache: 'no-store' })
    .then(function (response) {
      if (!response.ok) throw new Error('HTTP ' + response.status)
      return response.text()
    })
    .then(swapRefreshedContent)
    .catch(function (error) {
      showRefreshError(error.message)
    })
    .then(function () {
      setRefreshBusy(button, label, false)
    })
}

function showRefreshError(detail) {
  var main = document.getElementById('ops-main')
  if (main === null) return
  var bar = document.createElement('div')
  bar.className = 'note-bar note-error'
  var text = document.createElement('span')
  text.className = 'note-text'
  text.textContent = '无法连接到看板服务或取数失败（' + detail + '）。其余数据域不受影响。'
  var retry = document.createElement('button')
  retry.type = 'button'
  retry.className = 'btn'
  retry.textContent = '重试'
  retry.addEventListener('click', function () {
    bar.remove()
    refreshView()
  })
  bar.appendChild(text)
  bar.appendChild(retry)
  main.insertBefore(bar, main.firstChild)
}

function setupRefresh() {
  var button = document.getElementById('ops-refresh')
  if (button !== null) button.addEventListener('click', refreshView)
}

// ── copy path (inline feedback, no toast) ────────────────────────────
function copyText(button) {
  var value = button.getAttribute('data-copy') || ''
  var hint = button.parentElement === null ? null : button.parentElement.querySelector('.copy-hint')
  var report = function (message) {
    if (hint === null) return
    hint.textContent = message
    window.setTimeout(function () {
      hint.textContent = ''
    }, 1500)
  }
  if (navigator.clipboard !== undefined && navigator.clipboard.writeText !== undefined) {
    navigator.clipboard.writeText(value).then(
      function () {
        report('已复制')
      },
      function () {
        report('复制失败，请手动选择文本')
      }
    )
    return
  }
  report('复制失败，请手动选择文本')
}

function bindCopy(scope) {
  var buttons = scope.querySelectorAll('.btn-copy')
  Array.prototype.forEach.call(buttons, function (button) {
    if (button.getAttribute('data-bound') === '1') return
    button.setAttribute('data-bound', '1')
    button.addEventListener('click', function () {
      copyText(button)
    })
  })
}

// ── clickable table rows ─────────────────────────────────────────────
function bindRows(scope) {
  var rows = scope.querySelectorAll('tr[data-href]')
  Array.prototype.forEach.call(rows, function (row) {
    if (row.getAttribute('data-bound') === '1') return
    row.setAttribute('data-bound', '1')
    row.addEventListener('click', function (event) {
      var target = event.target
      if (target !== null && target.closest !== undefined && target.closest('a') !== null) return
      var href = row.getAttribute('data-href')
      if (href) window.location.href = href
    })
  })
}

// ── miss-query → detail filter (local, no re-request) ────────────────
function applyFilter(query) {
  var rows = document.querySelectorAll('#ops-main tr[data-query]')
  var matched = 0
  Array.prototype.forEach.call(rows, function (row) {
    var isMatch = query === '' || row.getAttribute('data-query') === query
    row.hidden = !isMatch
    if (isMatch) matched += 1
  })
  var bar = document.getElementById('ops-filter')
  if (bar !== null) {
    bar.hidden = query === ''
    var label = bar.querySelector('[data-filter-value]')
    if (label !== null) label.textContent = query + '（' + matched + ' 条）'
  }
  var sources = document.querySelectorAll('.bar-list-clickable .bar-row')
  Array.prototype.forEach.call(sources, function (row) {
    row.setAttribute('aria-pressed', row.getAttribute('data-query') === query ? 'true' : 'false')
  })
}

function bindFilter(scope) {
  var sources = scope.querySelectorAll('.bar-list-clickable .bar-row[data-query]')
  Array.prototype.forEach.call(sources, function (row) {
    if (row.getAttribute('data-bound') === '1') return
    row.setAttribute('data-bound', '1')
    row.addEventListener('click', function () {
      var query = row.getAttribute('data-query') || ''
      var current = row.getAttribute('aria-pressed') === 'true'
      applyFilter(current ? '' : query)
    })
  })
  var clear = document.getElementById('ops-filter-clear')
  if (clear !== null && clear.getAttribute('data-bound') !== '1') {
    clear.setAttribute('data-bound', '1')
    clear.addEventListener('click', function () {
      applyFilter('')
    })
  }
}

/** Re-bind the behaviours that live inside the swapped <main> content. */
function bindContent(scope) {
  bindCopy(scope)
  bindRows(scope)
  bindFilter(scope)
}

// ── keyboard shortcuts (all have mouse equivalents) ──────────────────
function isTypingTarget(target) {
  if (target === null) return false
  var tag = target.tagName ? target.tagName.toLowerCase() : ''
  return tag === 'input' || tag === 'textarea' || tag === 'select' || target.isContentEditable === true
}

/** Route for a numeric shortcut key, or null when the digit is not a route. */
function routeForKey(key) {
  var index = Number(key)
  if (Number.isInteger(index) && index >= 1 && index <= SHORTCUT_ROUTES.length) return SHORTCUT_ROUTES[index - 1]
  return null
}

function setupShortcuts() {
  document.addEventListener('keydown', function (event) {
    if (isTypingTarget(event.target) || event.metaKey || event.ctrlKey || event.altKey) return
    if (event.key === 'r' || event.key === 'R') {
      event.preventDefault()
      refreshView()
      return
    }
    if (event.key === '[') {
      event.preventDefault()
      toggleSidebar()
      return
    }
    if (event.key === 'Escape') {
      if (window.location.pathname.indexOf('/requirements/') === 0) window.history.back()
      return
    }
    var route = routeForKey(event.key)
    if (route !== null) window.location.href = route
  })
}

function init() {
  setupTheme()
  setupHero()
  setupRefresh()
  setupShortcuts()
  bindContent(document)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init)
} else {
  init()
}

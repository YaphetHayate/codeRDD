// Dashboard behaviours. Everything visible is rendered server-side; this file
// only adds interaction: theme, hero collapse, refresh, shortcuts, path copy,
// row navigation and the miss-query detail filter (UX §6).
//
// Loaded as a module (layout.mjs) so this top level is the script scope: no
// wrapper IIFE is needed and nothing leaks onto `window`.
var THEME_KEY = 'ops-dashboard:theme'
var HERO_KEY = 'ops-dashboard:hero-collapsed'
var REFRESH_HIGHLIGHT_MS = 600
var SHORTCUT_ROUTES = ['/', '/requirements', '/exploration', '/hit-rate', '/quality', '/tips', '/goal-trees', '/config']

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

// ── project switcher (runtime data-root switch, UX §3.3) ─────────────
var SWITCH_FLASH_KEY = 'ops-dashboard:switch-flash'
var SWITCH_RELOAD_MS = 800
var isPickDegraded = false // a failed dialog keeps the browse button off until reload
var isSwitcherBusy = false // single-flight: at most one switch action in flight

function readSession(key) {
  try {
    return window.sessionStorage.getItem(key)
  } catch (error) {
    return null
  }
}

function writeSession(key, value) {
  try {
    window.sessionStorage.setItem(key, value)
  } catch (error) {
    /* the flash is a nicety: reload still lands on the new root */
  }
}

function switcherEls() {
  return {
    toggle: document.getElementById('ops-project-switch'),
    panel: document.getElementById('ops-project-panel'),
    pick: document.getElementById('ops-project-pick'),
    path: document.getElementById('ops-project-path'),
    apply: document.getElementById('ops-project-apply'),
    note: document.getElementById('ops-project-note'),
    close: document.getElementById('ops-project-close'),
  }
}

/** Full current-root path as the server rendered it into the panel. */
function currentRootText(els) {
  if (els.panel === null) return ''
  var chip = els.panel.querySelector('.switcher-current code')
  return chip === null || chip === undefined ? '' : chip.textContent
}

function focusEl(element) {
  if (element !== null && element !== undefined && typeof element.focus === 'function') element.focus()
}

function setBtnLabel(button, text) {
  var label = button === null ? null : button.querySelector('.btn-text')
  if (label !== null && label !== undefined) label.textContent = text
}

/** Panel note area: at most one note, replaced in place; text only via textContent. */
function showSwitcherNote(els, kind, text) {
  if (els.note === null) return
  els.note.textContent = ''
  var bar = document.createElement('div')
  bar.className = 'note-bar note-' + kind + ' switcher-note'
  var span = document.createElement('span')
  span.className = 'note-text'
  var cut = text.indexOf('。')
  if (cut > 0) {
    var lead = document.createElement('b')
    lead.textContent = text.slice(0, cut + 1)
    span.appendChild(lead)
    span.appendChild(document.createTextNode(text.slice(cut + 1)))
  } else {
    span.textContent = text
  }
  bar.appendChild(span)
  els.note.appendChild(bar)
}

/** Busy lock: every panel control disabled while a switch action is in flight. */
function setSwitcherBusy(els, busy, pickLabel) {
  if (els.pick !== null) {
    els.pick.disabled = busy || isPickDegraded
    if (busy) els.pick.setAttribute('aria-busy', 'true')
    else els.pick.removeAttribute('aria-busy')
    setBtnLabel(els.pick, busy ? pickLabel : '浏览目录选择…')
  }
  if (els.path !== null) els.path.disabled = busy
  if (els.apply !== null) {
    els.apply.disabled = busy
    if (busy) els.apply.setAttribute('aria-busy', 'true')
    else els.apply.removeAttribute('aria-busy')
    setBtnLabel(els.apply, busy ? '校验中…' : '校验并切换')
  }
}

/** Unpack a control-plane response body into { status, payload } for handlers. */
function readControlResponse(response) {
  return response.json().then(function (payload) {
    return { status: response.status, payload: payload }
  })
}

/** Submit one candidate path — the paste fallback shares this exact channel. */
function submitSwitchPath(els, path) {
  isSwitcherBusy = true
  setSwitcherBusy(els, true, '校验中…')
  window
    .fetch('/api/project/switch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: path }),
    })
    .then(readControlResponse)
    .then(function (result) {
      handleSwitchResult(els, result)
    })
    .catch(function (error) {
      isSwitcherBusy = false
      setSwitcherBusy(els, false)
      showSwitcherNote(els, 'error', '请求失败（' + error.message + '）。数据根保持不变，可重试或改用手动输入路径。')
    })
}

function handleSwitchResult(els, result) {
  var payload = result.payload
  if (payload !== null && payload !== undefined && payload.ok === true) {
    showSwitcherNote(els, 'success', '校验通过，已切换到 ' + payload.projectRoot + '，正在重新加载看板…')
    writeSession(SWITCH_FLASH_KEY, JSON.stringify({ from: payload.previousRoot, to: payload.projectRoot }))
    window.setTimeout(function () {
      window.location.reload()
    }, SWITCH_RELOAD_MS)
    return
  }
  isSwitcherBusy = false
  setSwitcherBusy(els, false)
  var message =
    payload !== null && payload !== undefined && typeof payload.message === 'string'
      ? payload.message
      : '切换失败（HTTP ' + result.status + '）。数据根保持不变。'
  showSwitcherNote(els, 'error', message)
}

/** Browse: ask the server to open the native Windows directory dialog. */
function startPick(els) {
  if (isSwitcherBusy || isPickDegraded) return
  isSwitcherBusy = true
  setSwitcherBusy(els, true, '等待选择…')
  showSwitcherNote(els, 'info', '已在桌面弹出目录选择窗口。请切换到该窗口选定项目目录；直接关闭弹窗即取消，数据根不变。')
  window
    .fetch('/api/project/pick', { method: 'POST' })
    .then(readControlResponse)
    .then(function (result) {
      handlePickResult(els, result)
    })
    .catch(function (error) {
      degradePick(els, '网络或服务错误：' + error.message)
    })
}

function handlePickResult(els, result) {
  var payload = result.payload
  if (payload !== null && payload !== undefined && payload.ok === true && typeof payload.path === 'string' && payload.path !== '') {
    submitSwitchPath(els, payload.path) // seamless hand-off: picking → validating
    return
  }
  var code = payload === null || payload === undefined ? '' : payload.code
  var note = payload !== null && payload !== undefined && typeof payload.message === 'string' ? payload.message : ''
  if (code === 'canceled') {
    isSwitcherBusy = false
    setSwitcherBusy(els, false)
    showSwitcherNote(els, 'info', '已取消选择，数据根未变：' + currentRootText(els) + '。可重新浏览或粘贴路径。')
    return
  }
  if (code === 'busy') {
    isSwitcherBusy = false
    setSwitcherBusy(els, false)
    showSwitcherNote(els, 'info', note || '另一个目录选择正在进行中，请稍候。')
    return
  }
  degradePick(els, note || '失败（HTTP ' + result.status + '）')
}

/** Dialog failed / timed out / no desktop session: browse off, input takes over. */
function degradePick(els, reason) {
  isSwitcherBusy = false
  isPickDegraded = true
  setSwitcherBusy(els, false)
  showSwitcherNote(
    els,
    'error',
    '无法弹出目录选择窗口（' + reason + '）。请在上方输入框粘贴项目路径后回车或点「校验并切换」，校验规则与弹窗选择完全一致。'
  )
  focusEl(els.path)
}

/** Manual paste path: trim first; an empty value stays local (C15, no request). */
function submitManualPath(els) {
  if (isSwitcherBusy) return
  var value = els.path === null ? '' : String(els.path.value || '').trim()
  if (value === '') {
    showSwitcherNote(els, 'error', '请先输入项目路径（例如 D:\\work\\other-rdd-project）。')
    focusEl(els.path)
    return
  }
  submitSwitchPath(els, value)
}

function openSwitcherPanel(els) {
  if (els.panel === null) return
  els.panel.hidden = false
  if (els.toggle !== null) els.toggle.setAttribute('aria-expanded', 'true')
  if (els.note !== null) els.note.textContent = ''
  focusEl(isPickDegraded || els.pick === null ? els.path : els.pick)
}

function closeSwitcherPanel(els) {
  if (els.panel === null || els.panel.hidden) return
  els.panel.hidden = true
  if (els.toggle !== null) els.toggle.setAttribute('aria-expanded', 'false')
  focusEl(els.toggle)
}

function toggleSwitcherPanel(els) {
  if (els.panel === null) return
  if (els.panel.hidden) openSwitcherPanel(els)
  else closeSwitcherPanel(els)
}

function isSwitcherOpen() {
  var panel = document.getElementById('ops-project-panel')
  return panel !== null && !panel.hidden
}

/** Clicks outside the panel and its toggle collapse the panel. */
function switcherLightDismiss(target) {
  if (!isSwitcherOpen() || target === null) return
  var panel = document.getElementById('ops-project-panel')
  var toggle = document.getElementById('ops-project-switch')
  var inPanel = panel !== null && typeof panel.contains === 'function' && panel.contains(target)
  var inToggle = toggle !== null && typeof toggle.contains === 'function' && toggle.contains(target)
  if (!inPanel && !inToggle) closeSwitcherPanel(switcherEls())
}

function appendFlashCode(parent, value) {
  var code = document.createElement('code')
  code.textContent = value === undefined || value === null || value === '' ? '（未知）' : value
  parent.appendChild(code)
}

/** One-shot success flash after reload (consumed from sessionStorage, UX §5.5). */
function renderSwitchFlash(slot, data) {
  var bar = document.createElement('div')
  bar.className = 'note-bar note-success switch-flash'
  bar.innerHTML =
    '<svg class="btn-icon" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/></svg>'
  var text = document.createElement('span')
  text.className = 'note-text'
  text.appendChild(document.createTextNode('已切换数据根：'))
  appendFlashCode(text, data.from)
  text.appendChild(document.createTextNode(' → '))
  appendFlashCode(text, data.to)
  text.appendChild(document.createTextNode('。以下各域数据均为新根真值。'))
  var close = document.createElement('button')
  close.type = 'button'
  close.className = 'btn'
  close.textContent = '关闭'
  close.addEventListener('click', function () {
    slot.hidden = true
    slot.textContent = ''
  })
  bar.appendChild(text)
  bar.appendChild(close)
  slot.textContent = ''
  slot.appendChild(bar)
  slot.hidden = false
}

function consumeSwitchFlash() {
  var slot = document.getElementById('ops-flash-slot')
  if (slot === null) return
  var raw = readSession(SWITCH_FLASH_KEY)
  if (raw === null) return
  try {
    window.sessionStorage.removeItem(SWITCH_FLASH_KEY)
  } catch (error) {
    /* best effort: a stale key only breaks the "once" promise, not the page */
  }
  var data = null
  try {
    data = JSON.parse(raw)
  } catch (error) {
    data = null
  }
  if (data === null || typeof data.to !== 'string') return
  renderSwitchFlash(slot, data)
}

function setupProjectSwitcher() {
  var els = switcherEls()
  if (els.toggle === null || els.panel === null) return
  els.toggle.addEventListener('click', function () {
    toggleSwitcherPanel(els)
  })
  if (els.close !== null) {
    els.close.addEventListener('click', function () {
      closeSwitcherPanel(els)
    })
  }
  if (els.pick !== null) {
    els.pick.addEventListener('click', function () {
      startPick(els)
    })
  }
  if (els.apply !== null) {
    els.apply.addEventListener('click', function () {
      submitManualPath(els)
    })
  }
  if (els.path !== null) {
    els.path.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') {
        event.preventDefault()
        submitManualPath(els)
      }
    })
  }
  document.addEventListener('click', function (event) {
    switcherLightDismiss(event.target)
  })
}


// ── config form (/config) — the single writable surface ───────────────
var CONFIG_SAVE_ENDPOINT = '/api/config/search-config'
var CONFIG_RELOAD_MS = 800
var CONFIG_NUMERIC_RE = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/
var isConfigSaveBusy = false // single-flight: one save in flight at a time

/** Config-form controls inside a scope (null when the page has no form). */
function configEls(scope) {
  var form = scope.querySelector('#ops-config-form')
  if (form === null || form === undefined) return null
  return {
    form: form,
    save: form.querySelector('#ops-config-save'),
    nojs: form.querySelector('#ops-config-nojs'),
    note: form.querySelector('#ops-config-note'),
  }
}

/** Build the per-field error list (shared by the config and UX editors). */
function buildFieldErrorList(fieldErrors) {
  var list = document.createElement('ul')
  list.className = 'config-error-list'
  Array.prototype.forEach.call(fieldErrors, function (error) {
    var item = document.createElement('li')
    var path = document.createElement('code')
    path.textContent = error.path
    item.appendChild(path)
    item.appendChild(document.createTextNode('：' + (error.reason || '不合法')))
    if (error.value !== undefined && error.value !== null && error.value !== '') {
      item.appendChild(document.createTextNode('（当前值：' + error.value + '）'))
    }
    list.appendChild(item)
  })
  return list
}

/** Note area under the form: one note-bar, replaced in place; textContent only. */
function showConfigNote(els, kind, text, fieldErrors) {
  if (els.note === null || els.note === undefined) return
  els.note.textContent = ''
  var bar = document.createElement('div')
  bar.className = 'note-bar note-' + kind + ' config-note-bar'
  var span = document.createElement('span')
  span.className = 'note-text'
  span.textContent = text
  bar.appendChild(span)
  if (fieldErrors !== null && fieldErrors !== undefined && fieldErrors.length > 0) {
    bar.appendChild(buildFieldErrorList(fieldErrors))
  }
  els.note.appendChild(bar)
}

/** Collect the 14 fields; types come from data-config-type, not a hardcoded list. */
function collectConfigValues(form) {
  var config = {}
  var fields = form.querySelectorAll('[data-config-field]')
  Array.prototype.forEach.call(fields, function (field) {
    var name = field.getAttribute('name') || ''
    if (name === '') return
    var type = field.getAttribute('data-config-type') || 'string'
    var raw = String(field.value !== undefined ? field.value : '')
    if (type === 'enabled') {
      config[name] = raw === 'true' ? true : raw === 'false' ? false : 'auto'
      return
    }
    if (type === 'number') {
      var trimmed = raw.trim()
      if (CONFIG_NUMERIC_RE.test(trimmed)) {
        config[name] = Number(trimmed)
        return
      }
      // Non-numeric input travels verbatim: the server's predicate rejection
      // names the exact requirement, which beats a client-side guess.
    }
    config[name] = raw
  })
  return config
}

function setConfigBusy(els, busy) {
  if (els.save === null || els.save === undefined) return
  els.save.disabled = busy
  if (busy) els.save.setAttribute('aria-busy', 'true')
  else els.save.removeAttribute('aria-busy')
  els.save.textContent = busy ? '校验并保存中…' : '校验并保存'
}

function handleConfigResult(els, result) {
  var payload = result.payload
  if (payload !== null && payload !== undefined && payload.ok === true) {
    var readiness = payload.vectorReadiness
    var readyText =
      readiness !== null && readiness !== undefined && readiness.ready
        ? '就绪'
        : '缺失 ' + (readiness !== null && readiness !== undefined ? readiness.missing.join('、') : '未知')
    var impactText = ''
    if (payload.impact !== null && payload.impact !== undefined && payload.impact.crossModuleFields !== undefined && payload.impact.crossModuleFields.length > 0) {
      impactText = ' · 影响面：检索召回 + 缓存向量化'
    }
    showConfigNote(els, 'success', '已保存' + impactText + ' · ' + payload.bytes + ' 字节 · 向量路：' + readyText + '。正在刷新页面…')
    window.setTimeout(function () {
      window.location.reload()
    }, CONFIG_RELOAD_MS)
    return
  }
  isConfigSaveBusy = false
  setConfigBusy(els, false)
  var code = payload === null || payload === undefined ? '' : payload.code
  var message =
    payload !== null && payload !== undefined && typeof payload.message === 'string'
      ? payload.message
      : '保存失败（HTTP ' + result.status + '）。原文件保持不变。'
  var errors = payload !== null && payload !== undefined ? payload.fieldErrors : null
  showConfigNote(els, 'error', message, code === 'invalid-field' || code === 'unknown-field' ? errors : null)
}

/** The cross-module vector fields whose value differs from the SSR original (r2 §4.2 ②). */
function crossModuleTouches(form) {
  var touched = []
  var fields = form.querySelectorAll('[data-cross-module="1"]')
  Array.prototype.forEach.call(fields, function (field) {
    var original = field.getAttribute('data-original')
    if (original === null) original = ''
    var current = String(field.value !== undefined ? field.value : '')
    if (current !== original) {
      var name = field.getAttribute('name') || ''
      if (name !== '') touched.push(name)
    }
  })
  return touched
}

function submitConfigForm(els) {
  if (isConfigSaveBusy) return
  var touched = crossModuleTouches(els.form)
  if (touched.length > 0) {
    var confirmed = window.confirm(
      '本次修改涉及向量路配置（' + touched.join('、') + '）：同时影响检索召回（rdd explore 搜索的向量路）与探索缓存向量化（register/embed-backfill 的向量写入）。确认保存？'
    )
    if (!confirmed) return // 取消 = 不发请求，表单状态保留
  }
  isConfigSaveBusy = true
  setConfigBusy(els, true)
  window
    .fetch(CONFIG_SAVE_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ config: collectConfigValues(els.form) }),
    })
    .then(readControlResponse)
    .then(function (result) {
      handleConfigResult(els, result)
    })
    .catch(function (error) {
      isConfigSaveBusy = false
      setConfigBusy(els, false)
      showConfigNote(els, 'error', '请求失败（' + error.message + '）。原文件保持不变，可重试。')
    })
}

/** Wire the config form: enable the save button, hide the no-JS caveat. */
function bindConfigForm(scope) {
  var els = configEls(scope)
  if (els === null || els.form.getAttribute('data-bound') === '1') return
  els.form.setAttribute('data-bound', '1')
  els.form.addEventListener('submit', function (event) {
    event.preventDefault()
  })
  if (els.nojs !== null && els.nojs !== undefined) els.nojs.hidden = true
  if (els.save !== null && els.save !== undefined) {
    els.save.removeAttribute('disabled')
    els.save.addEventListener('click', function () {
      submitConfigForm(els)
    })
  }
}

// ── ux subagent editor (/config · UX module, ops-config-panel-r2 §5) ──
var UX_SAVE_ENDPOINT = '/api/config/ux-subagents'
var UX_SYNC_ENDPOINT = '/api/config/ux-subagents/sync'
var UX_RELOAD_MS = 800
var isUxBusy = false // single-flight: one save or sync in flight at a time

/** UX editor controls (the form plus the sync button outside it). */
function uxEls(scope) {
  var form = scope.querySelector('#ops-ux-form')
  if (form === null || form === undefined) return null
  return {
    form: form,
    save: form.querySelector('#ops-ux-save'),
    add: form.querySelector('#ops-ux-add'),
    nojs: form.querySelector('#ops-ux-nojs'),
    note: form.querySelector('#ops-ux-note'),
    sync: scope.querySelector('#ops-ux-sync'),
    syncNojs: scope.querySelector('#ops-ux-sync-nojs'),
  }
}

/** One appended note bar (the UX panel may stack saved + sync notes). */
function addUxNote(els, kind, text) {
  var bar = document.createElement('div')
  bar.className = 'note-bar note-' + kind + ' config-note-bar'
  var span = document.createElement('span')
  span.className = 'note-text'
  span.textContent = text
  bar.appendChild(span)
  els.note.appendChild(bar)
}

/** Replace the UX note area: [kind, text] entries, optional fieldErrors list. */
function showUxNotes(els, entries, fieldErrors) {
  if (els.note === null || els.note === undefined) return
  els.note.textContent = ''
  Array.prototype.forEach.call(entries, function (entry) {
    addUxNote(els, entry[0], entry[1])
  })
  if (fieldErrors !== null && fieldErrors !== undefined && fieldErrors.length > 0) {
    var bar = document.createElement('div')
    bar.className = 'note-bar note-error config-note-bar'
    bar.appendChild(buildFieldErrorList(fieldErrors))
    els.note.appendChild(bar)
  }
}

/** Collect the full agents array (full-replacement semantics, r2 §6.2). */
function collectUxAgents(form) {
  var agents = []
  var blocks = form.querySelectorAll('[data-ux-agent]')
  Array.prototype.forEach.call(blocks, function (block) {
    var agent = {}
    var sawField = false
    Array.prototype.forEach.call(block.querySelectorAll('[data-ux-field]'), function (field) {
      var key = field.getAttribute('data-ux-field') || ''
      if (key === '') return
      var raw = String(field.value !== undefined ? field.value : '')
      if (key === 'temperature') {
        var trimmed = raw.trim()
        agent.temperature = CONFIG_NUMERIC_RE.test(trimmed) ? Number(trimmed) : raw
        sawField = true
        return
      }
      agent[key] = raw
      sawField = true
    })
    if (sawField) agents.push(agent)
  })
  return agents
}

function setUxBusy(els, busy) {
  if (els.save !== null && els.save !== undefined) {
    els.save.disabled = busy
    if (busy) els.save.setAttribute('aria-busy', 'true')
    else els.save.removeAttribute('aria-busy')
    els.save.textContent = busy ? '校验并保存中…' : '校验并保存（全量替换）'
  }
  if (els.sync !== null && els.sync !== undefined) {
    els.sync.disabled = busy
    if (busy) els.sync.setAttribute('aria-busy', 'true')
    else els.sync.removeAttribute('aria-busy')
  }
}

/** The note entries for one sync outcome; restart reminder mirrors the script. */
function uxSyncNotes(sync) {
  if (sync === null || sync === undefined) return []
  if (sync.status === 'ok') {
    if (sync.changed === true) {
      var detail = sync.changes !== undefined && sync.changes.length > 0 ? '（' + sync.changes.join('；') + '）' : ''
      return [['success', '已同步 .opencode/agent/ —— 需重启 opencode 才能生效。' + detail]]
    }
    return [['info', '同步完成：无变更，.opencode/agent/ 已是最新。']]
  }
  var reason =
    sync.status === 'timeout'
      ? '同步超时（' + sync.durationMs + 'ms，已终止脚本）'
      : '同步失败（exit ' + sync.exitCode + (sync.stderr !== undefined && sync.stderr !== '' ? '：' + String(sync.stderr).slice(0, 200) : '') + '）'
  return [['warn', reason + '——.opencode/agent/ 尚未更新。点击「运行同步」重试，或手工运行 rdd-engine/scripts/sync-ux-subagents.cmd。']]
}

function handleUxResult(els, result) {
  var payload = result.payload
  if (payload !== null && payload !== undefined && payload.ok === true) {
    var entries = [['success', '文件已保存（' + payload.path + ' · ' + payload.bytes + ' 字节）。']]
    var sync = payload.sync
    var syncNotes = uxSyncNotes(sync)
    Array.prototype.forEach.call(syncNotes, function (entry) {
      entries.push(entry)
    })
    showUxNotes(els, entries)
    if (sync !== null && sync !== undefined && sync.status === 'ok') {
      window.setTimeout(function () {
        window.location.reload()
      }, UX_RELOAD_MS)
      return
    }
    // sync failed/timeout: keep the failure guidance visible — no auto reload
    isUxBusy = false
    setUxBusy(els, false)
    return
  }
  isUxBusy = false
  setUxBusy(els, false)
  var code = payload === null || payload === undefined ? '' : payload.code
  var message =
    payload !== null && payload !== undefined && typeof payload.message === 'string'
      ? payload.message
      : '保存失败（HTTP ' + result.status + '）。原文件保持不变。'
  showUxNotes(els, [['error', message]], code === 'invalid-field' || code === 'unknown-field' ? (payload ? payload.fieldErrors : null) : null)
}

function submitUxForm(els) {
  if (isUxBusy) return
  isUxBusy = true
  setUxBusy(els, true)
  window
    .fetch(UX_SAVE_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ agents: collectUxAgents(els.form) }),
    })
    .then(readControlResponse)
    .then(function (result) {
      handleUxResult(els, result)
    })
    .catch(function (error) {
      isUxBusy = false
      setUxBusy(els, false)
      showUxNotes(els, [['error', '请求失败（' + error.message + '）。原文件保持不变，可重试。']])
    })
}

/** The standalone sync button — retry path after a failed sync (r2 §5.4). */
function runUxSyncNow(els) {
  if (isUxBusy) return
  isUxBusy = true
  setUxBusy(els, true)
  window
    .fetch(UX_SYNC_ENDPOINT, { method: 'POST' })
    .then(readControlResponse)
    .then(function (result) {
      var payload = result.payload
      if (payload !== null && payload !== undefined && payload.ok === true) {
        showUxNotes(els, uxSyncNotes(payload.sync))
        if (payload.sync !== null && payload.sync !== undefined && payload.sync.status === 'ok') {
          window.setTimeout(function () {
            window.location.reload()
          }, UX_RELOAD_MS)
          return
        }
        isUxBusy = false
        setUxBusy(els, false)
        return
      }
      isUxBusy = false
      setUxBusy(els, false)
      showUxNotes(els, [['error', '同步请求失败（HTTP ' + result.status + '）。']])
    })
    .catch(function (error) {
      isUxBusy = false
      setUxBusy(els, false)
      showUxNotes(els, [['error', '同步请求失败（' + error.message + '）。']])
    })
}

/** Clone a fresh agent block from the SSR template (JS-gated, r2 §7). */
function addUxAgentRow(els) {
  var template = document.getElementById('ops-ux-agent-template')
  var anchor = els.form.querySelector('.config-actions')
  if (template !== null && template.content !== null && template.content !== undefined) {
    var node = template.content.firstElementChild !== null && template.content.firstElementChild !== undefined ? template.content.firstElementChild.cloneNode(true) : null
    if (node !== null) {
      els.form.insertBefore(node, anchor)
      var name = node.querySelector('[data-ux-field="name"]')
      if (name !== null && name !== undefined && typeof name.focus === 'function') name.focus()
      return
    }
  }
  var first = els.form.querySelector('[data-ux-agent]')
  if (first === null || first === undefined) return
  var clone = first.cloneNode(true)
  Array.prototype.forEach.call(clone.querySelectorAll('[data-ux-field]'), function (field) {
    field.value = ''
    field.readOnly = false
  })
  els.form.insertBefore(clone, anchor)
}

function bindUxForm(scope) {
  var els = uxEls(scope)
  if (els === null || els.form.getAttribute('data-bound') === '1') return
  els.form.setAttribute('data-bound', '1')
  els.form.addEventListener('submit', function (event) {
    event.preventDefault()
  })
  if (els.nojs !== null && els.nojs !== undefined) els.nojs.hidden = true
  if (els.syncNojs !== null && els.syncNojs !== undefined) els.syncNojs.hidden = true
  if (els.save !== null && els.save !== undefined) {
    els.save.removeAttribute('disabled')
    els.save.addEventListener('click', function () {
      submitUxForm(els)
    })
  }
  if (els.add !== null && els.add !== undefined) {
    els.add.addEventListener('click', function () {
      addUxAgentRow(els)
    })
  }
  if (els.sync !== null && els.sync !== undefined) {
    els.sync.removeAttribute('disabled')
    els.sync.addEventListener('click', function () {
      runUxSyncNow(els)
    })
  }
}

// ── copy path (inline feedback, no toast) ────────────────────────────
function copyText(button) {
  var value = button.getAttribute('data-copy') || ''
  var hint = button.parentElement === null ? null : button.parentElement.querySelector('.copy-hint')
  var report = function (message) {
    if (hint !== null) {
      hint.textContent = message
      window.setTimeout(function () {
        hint.textContent = ''
      }, 1500)
      return
    }
    // mini copy buttons have no hint container — the label flips briefly (§2.1)
    var label = button.textContent
    button.textContent = message === '已复制' ? '✓' : '×'
    window.setTimeout(function () {
      button.textContent = label
    }, 900)
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

// ── KPI expansion (/exploration): count tiles toggle in-place detail panels ──
// The server renders the pure display shape (no chevron, no tabindex, §6.6);
// this section upgrades the tiles into triggers, hides the flat baseline panel
// and keeps the interactions on document-level delegation (§6.2) so refresh
// re-binding needs no extra work here.
var KPI_CHEVRON_SVG =
  '<svg class="stat-chevron" viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M7 10l5 5 5-5z"/></svg>'

/** Upgrade the SSR tiles into expandable triggers and hide the flat baseline. */
function enhanceKpiExpansion(scope) {
  var tiles = scope.querySelectorAll('.stat-tile[data-kpi]')
  Array.prototype.forEach.call(tiles, function (tile) {
    if (tile.getAttribute('data-bound') === '1') return
    tile.setAttribute('data-bound', '1')
    tile.classList.add('is-expandable')
    tile.setAttribute('tabindex', '0')
    tile.setAttribute('role', 'button')
    tile.setAttribute('aria-expanded', 'false')
    tile.setAttribute('aria-controls', 'exp-' + tile.getAttribute('data-kpi'))
    tile.insertAdjacentHTML('beforeend', KPI_CHEVRON_SVG)
  })
  var flat = scope.querySelector('#entries-flat')
  if (flat !== null) flat.hidden = true
  var pairsFlat = scope.querySelector('#pairs-flat')
  if (pairsFlat !== null) pairsFlat.hidden = true
}

function setKpiExpanded(zone, open) {
  var tile = document.getElementById('kpi-' + zone)
  var panel = document.getElementById('exp-' + zone)
  if (tile === null || panel === null) return
  tile.setAttribute('aria-expanded', open ? 'true' : 'false')
  tile.classList.toggle('is-open', open)
  panel.hidden = !open
}

/** Collapse one zone and hand focus back to its KPI tile (§6.5). */
function collapseKpiZone(zone) {
  setKpiExpanded(zone, false)
  var tile = document.getElementById('kpi-' + zone)
  if (tile !== null) tile.focus()
}

function toggleEntryRow(row) {
  var detail = document.getElementById(row.getAttribute('aria-controls'))
  if (detail === null) return
  var open = detail.hidden
  detail.hidden = !open
  row.classList.toggle('is-open', open)
  row.setAttribute('aria-expanded', open ? 'true' : 'false')
}

/** The expansion trigger under a click/keyboard target, or null. */
function expansionTarget(target) {
  if (target === null || target === undefined || typeof target.closest !== 'function') return null
  var head = target.closest('.exp-head[data-collapse-zone]')
  if (head !== null) return { kind: 'head', zone: head.getAttribute('data-collapse-zone') }
  var tile = target.closest('.stat-tile.is-expandable[data-kpi]')
  if (tile !== null) return { kind: 'tile', zone: tile.getAttribute('data-kpi'), open: tile.getAttribute('aria-expanded') !== 'true' }
  var row = target.closest('tr[data-entry]') || target.closest('tr[data-pair]')
  if (row !== null) return { kind: 'row', row: row }
  return null
}

function handleExpansionActivate(activate) {
  if (activate.kind === 'head') collapseKpiZone(activate.zone)
  else if (activate.kind === 'tile') setKpiExpanded(activate.zone, activate.open)
  else toggleEntryRow(activate.row)
}

/** Esc with focus inside an open expansion collapses it and refocuses the tile. */
function collapseFocusedExpansion() {
  var active = document.activeElement
  if (active === null || active === undefined || typeof active.closest !== 'function') return false
  var panel = active.closest('.kpi-expansion')
  if (panel === null || panel.hidden || typeof panel.id !== 'string' || panel.id.indexOf('exp-') !== 0) return false
  collapseKpiZone(panel.id.slice(4))
  return true
}

function setupKpiExpansion() {
  document.addEventListener('click', function (event) {
    var target = event.target
    if (target === null || typeof target.closest !== 'function') return
    if (target.closest('a')) return // links keep their native behaviour (vscode:// etc.)
    var activate = expansionTarget(target)
    if (activate !== null) handleExpansionActivate(activate)
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
  enhanceKpiExpansion(scope)
  bindCopy(scope)
  bindRows(scope)
  bindFilter(scope)
  bindConfigForm(scope)
  bindUxForm(scope)
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
    if (event.key === 'Enter' || event.key === ' ') {
      var activate = expansionTarget(event.target)
      if (activate !== null) {
        event.preventDefault()
        handleExpansionActivate(activate)
        return
      }
    }
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
    if (event.key === 'p' || event.key === 'P') {
      event.preventDefault()
      toggleSwitcherPanel(switcherEls())
      return
    }
    if (event.key === 'Escape') {
      if (isSwitcherOpen()) {
        event.preventDefault()
        closeSwitcherPanel(switcherEls())
        return
      }
      if (collapseFocusedExpansion()) {
        event.preventDefault()
        return
      }
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
  setupProjectSwitcher()
  setupKpiExpansion()
  consumeSwitchFlash()
  setupShortcuts()
  bindContent(document)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init)
} else {
  init()
}

// Native Windows directory picker — a PowerShell FolderBrowserDialog child
// process (CTO decision 1). Zero npm dependencies; the script is pure ASCII
// and answers with one line of JSON on stdout, so console-codepage quirks and
// CJK project paths never corrupt the channel (ConvertTo-Json escapes
// non-ASCII). One picker at a time per server (single-flight, decision 8):
// concurrent callers get "busy" instead of stacking dialogs. Lock release
// converges in finish() which every exit path (close, error, timeout) reaches.
import { spawn } from 'node:child_process'

/** How long the native dialog may stay open before we kill it (decision 8). */
const PICK_TIMEOUT_MS = 300000

/** Inline picker script — ASCII only, single-line JSON protocol on stdout. */
const PICKER_SCRIPT = [
  'Add-Type -AssemblyName System.Windows.Forms;',
  "$d = New-Object System.Windows.Forms.FolderBrowserDialog;",
  "$d.Description = 'Select the RDD project directory';",
  'if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)',
  " { Write-Output ('{\"status\":\"picked\",\"path\":' + (ConvertTo-Json -Compress -InputObject $d.SelectedPath) + '}') }",
  'else { Write-Output "{\\"status\\":\\"canceled\\"}" }',
].join(' ')

/** Module-wide single-flight state: one dialog per process at a time. */
let isPickInFlight = false

/** Non-Windows platforms never get a dialog — the paste fallback is the path. */
function unsupportedOutcome() {
  return {
    status: 'failed',
    code: 'unsupported',
    message: '当前平台不支持原生目录选择对话框（仅 Windows）。请改用手动输入项目路径。',
  }
}

/** A second pick while one dialog is already open is rejected, not queued. */
function busyOutcome() {
  return { status: 'failed', code: 'busy', message: '另一个目录选择正在进行中，请稍候或改用手动输入项目路径。' }
}

/**
 * Spawn the picker and route every exit path through finish() (idempotent).
 * @param {object} options command/args/timeoutMs overrides (tests inject fakes)
 * @param {(outcome: object) => void} report exactly-once callback
 */
function runPicker(options, report) {
  const command = options.command ?? 'powershell.exe'
  const args = options.args ?? ['-NoProfile', '-NonInteractive', '-STA', '-Command', PICKER_SCRIPT]
  const timeoutMs = options.timeoutMs ?? PICK_TIMEOUT_MS
  const spawner = options.spawnImpl ?? spawn
  let isSettled = false
  let stdout = ''
  let timer = null
  const finish = (outcome) => {
    if (isSettled) return
    isSettled = true
    isPickInFlight = false
    clearTimeout(timer)
    report(outcome)
  }
  let child
  try {
    child = spawner(command, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
  } catch (error) {
    finish({ status: 'failed', code: 'spawn', message: `目录选择进程启动失败：${error.message}` })
    return
  }
  timer = setTimeout(() => {
    finish({ status: 'failed', code: 'timeout', message: `等待目录选择超时（${Math.round(timeoutMs / 1000)} 秒），已终止本次选择。` })
    child.kill()
  }, timeoutMs)
  child.stdout.on('data', (chunk) => {
    stdout += chunk
  })
  child.stderr.on('data', () => {}) // drain: a full stderr pipe would block the child
  child.on('error', (error) => finish({ status: 'failed', code: 'spawn', message: `目录选择进程启动失败：${error.message}` }))
  child.on('close', (code) => finish(parsePickerOutput(stdout, code)))
}

/** Interpret the child's stdout: picked / canceled / unparseable (exit). */
function parsePickerOutput(stdout, exitCode) {
  const lines = String(stdout).split(/\r?\n/).filter((line) => line.trim() !== '')
  const last = lines[lines.length - 1]
  if (last !== undefined) {
    try {
      const parsed = JSON.parse(last)
      if (parsed.status === 'picked' && typeof parsed.path === 'string' && parsed.path !== '') {
        return { status: 'picked', path: parsed.path }
      }
      if (parsed.status === 'canceled') return { status: 'canceled' }
    } catch {
      /* fall through: unparseable output is an exit failure */
    }
  }
  return {
    status: 'failed',
    code: 'exit',
    message: `PowerShell 目录选择进程未返回有效结果（退出码 ${exitCode ?? 'unknown'}）。`,
  }
}

/**
 * Open the native directory-selection dialog.
 * @param {{platform?: string, command?: string, args?: string[], timeoutMs?: number, spawnImpl?: Function}} [options]
 * @returns {Promise<{status: 'picked', path: string}|{status: 'canceled'}|{status: 'failed', code: string, message: string}>}
 */
export function pickDirectory(options = {}) {
  if ((options.platform ?? process.platform) !== 'win32') return Promise.resolve(unsupportedOutcome())
  if (isPickInFlight) return Promise.resolve(busyOutcome())
  isPickInFlight = true
  return new Promise((resolvePick) => {
    runPicker(options, resolvePick)
  })
}

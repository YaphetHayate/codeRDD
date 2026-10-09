// UX subagent sync runner (ops-config-panel-r2 §5.4).
//
// Spawns the documented entry point rdd-engine/scripts/sync-ux-subagents.cmd
// (path derived from THIS module's own location — dashboard/lib → engine
// scripts — never from the request), with RDD_PROJECT_ROOT pinned to the
// current data root so the script syncs exactly the json the dashboard just
// wrote. stdout/stderr are captured via temp-file redirection instead of
// piped stdio: the hosting sandbox forbids named pipes, and redirection
// keeps the same capture semantics (full output, 16KB cap per stream) with
// zero behavioural difference for the caller. The sync outcome is reported
// in-band and honestly: a non-zero exit, a timeout or a spawn failure
// resolves with status 'failed'/'timeout' — never swallowed into a success.
import { spawn } from 'node:child_process'
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** The documented sync entry point next to this dashboard's engine scripts. */
const DEFAULT_COMMAND = fileURLToPath(new URL('../../scripts/sync-ux-subagents.cmd', import.meta.url))

/** stdout/stderr capture cap each (truncate with an ellipsis beyond). */
const CAPTURE_LIMIT = 16 * 1024

/** The script is pure local file work: PS cold start 1–3s ⇒ 15s is 5× slack. */
const DEFAULT_TIMEOUT_MS = 15_000

/**
 * Decode captured child bytes: cmd/PS on Chinese Windows writes the console
 * OEM code page (GBK) when redirected; try UTF-8 first, fall back to GBK when
 * the UTF-8 decode shows replacement characters. ASCII output is identical
 * both ways, so injected fake commands in tests stay on the UTF-8 path.
 */
function decodeBytes(buffer) {
  if (buffer.length === 0) return ''
  const utf8 = buffer.toString('utf8')
  if (!utf8.includes('\uFFFD')) return utf8
  try {
    return new TextDecoder('gbk').decode(buffer)
  } catch {
    return utf8 // undecodable environment: keep the raw decode, honest about it
  }
}

/** Cap a captured stream at the limit (character-count approximation). */
function capStream(text) {
  return text.length > CAPTURE_LIMIT ? `${text.slice(0, CAPTURE_LIMIT)}…` : text
}

/** Read one captured redirection file (empty string when absent). */
function readCapture(path) {
  try {
    return readFileSync(path)
  } catch {
    return Buffer.alloc(0)
  }
}

/**
 * Parse the script's report: `changed` mirrors the exact line the script
 * prints only when changes>0 and not in -WhatIf (需重启 opencode 才能生效);
 * the change details are the `+ created:/updated:/deleted:/synced:` lines of
 * the 变更操作 section.
 */
function parseSyncChanges(stdout) {
  const changed = stdout.includes('需重启 opencode 才能生效')
  const changes = []
  const sectionIndex = stdout.indexOf('变更操作：')
  if (sectionIndex !== -1) {
    for (const line of stdout.slice(sectionIndex).split(/\r?\n/)) {
      const match = /^\s*\+\s*((?:created|updated|deleted|synced):.*)$/.exec(line)
      if (match !== null) changes.push(match[1].trim())
    }
  }
  return { changed, restartRequired: changed, changes }
}

/** Kill the whole spawned tree (cmd.exe → powershell) — Windows needs /T. */
function killTree(child) {
  if (process.platform === 'win32' && typeof child.pid === 'number') {
    try {
      spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
      return
    } catch {
      /* fall through to the direct kill */
    }
  }
  try {
    child.kill()
  } catch {
    /* already gone */
  }
}

/** Best-effort removal of the temp files one run created (out/err/wrapper). */
function cleanupFiles(paths) {
  for (const path of paths) {
    try {
      rmSync(path, { force: true })
    } catch {
      /* best effort */
    }
  }
}

/** Read both redirection files and return capped, decoded stream text. */
function captureStreams(outPath, errPath) {
  return { stdout: capStream(decodeBytes(readCapture(outPath))), stderr: capStream(decodeBytes(readCapture(errPath))) }
}

/**
 * Write the cmd wrapper and spawn it. A generated wrapper keeps every quoting
 * inside a cmd FILE (parsed by the cmd script parser, not the /c command-line
 * rules) — the only form that survives arbitrary spaces in paths on every host.
 */
function startWrapper(context, command, outPath, errPath, wrapperPath) {
  writeFileSync(wrapperPath, `@echo off\r\ncall "${command}" > "${outPath}" 2> "${errPath}"\r\nexit /b %ERRORLEVEL%\r\n`, 'utf8')
  return spawn('cmd.exe', ['/d', '/c', wrapperPath], {
    cwd: context.projectRoot,
    env: { ...process.env, RDD_PROJECT_ROOT: context.projectRoot },
    stdio: 'ignore',
  })
}

/** The failed-outcome shape shared by the three failure paths (single source). */
function failedOutcome(durationMs, exitCode, stdout, stderr) {
  return { status: 'failed', exitCode, durationMs, changed: false, restartRequired: false, changes: [], stdout, stderr }
}

/**
 * First-call-wins settle guard: owns the kill timer; the first settle clears
 * the timer + temp files and resolves — later calls are ignored.
 * @returns {{timedOut: () => boolean, settle: (outcome: object) => void}}
 */
function settleOnce(resolve, cleanup, child, timeoutMs) {
  let settled = false
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    killTree(child)
  }, timeoutMs)
  return {
    timedOut: () => timedOut,
    settle: (outcome) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      cleanup()
      resolve(outcome)
    },
  }
}

/**
 * Run the sync script once.
 * @param {{projectRoot: string}} context
 * @param {{timeoutMs?: number, command?: string}} [options] tests inject a fake command
 * @returns {Promise<{status: 'ok'|'failed'|'timeout', exitCode: number|null, durationMs: number,
 *   changed: boolean, restartRequired: boolean, changes: string[], stdout: string, stderr: string}>}
 */
export function runUxSync(context, options = {}) {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const command = options.command ?? DEFAULT_COMMAND
  const stamp = `${process.pid}-${Date.now()}`
  const outPath = join(tmpdir(), `ux-sync-${stamp}.out`)
  const errPath = join(tmpdir(), `ux-sync-${stamp}.err`)
  const wrapperPath = join(tmpdir(), `ux-sync-${stamp}.cmd`)
  return new Promise((resolve) => {
    const startedAt = Date.now()
    const cleanup = () => cleanupFiles([outPath, errPath, wrapperPath])
    let child
    try {
      child = startWrapper(context, command, outPath, errPath, wrapperPath)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      cleanup()
      resolve(failedOutcome(0, null, '', `spawn 失败：${message}`))
      return
    }
    const guard = settleOnce(resolve, cleanup, child, timeoutMs)
    child.on('error', (error) => {
      const message = error instanceof Error ? error.message : String(error)
      const streams = captureStreams(outPath, errPath)
      guard.settle(failedOutcome(Date.now() - startedAt, null, streams.stdout, capStream(`${streams.stderr}\nspawn 错误：${message}`)))
    })
    child.on('close', (code) => {
      const { stdout, stderr } = captureStreams(outPath, errPath)
      const durationMs = Date.now() - startedAt
      if (guard.timedOut()) {
        guard.settle({ status: 'timeout', exitCode: code, durationMs, changed: false, restartRequired: false, changes: [], stdout, stderr })
        return
      }
      if (code !== 0) {
        guard.settle(failedOutcome(durationMs, code, stdout, stderr))
        return
      }
      guard.settle({ status: 'ok', exitCode: 0, durationMs, ...parseSyncChanges(stdout) })
    })
  })
}

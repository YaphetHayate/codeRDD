// Tolerant filesystem reads shared by every reader.
//
// All RDD data files are UTF-8 without BOM (.rdd/ encoding convention), but the
// dashboard must also survive BOM-carrying writers and half-written lines while
// other role sessions keep writing the same files. Every helper therefore
// degrades to null/[] plus a note instead of throwing.
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

import { isExcludedPath } from './paths.mjs'

/**
 * Read a text file, stripping a UTF-8 BOM if a writer left one.
 * @param {string} absolutePath
 * @returns {{text: string|null, error: string|null}}
 */
export function readText(absolutePath) {
  try {
    const raw = readFileSync(absolutePath, 'utf8')
    return { text: raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw, error: null }
  } catch (error) {
    if (error.code === 'ENOENT') return { text: null, error: null }
    return { text: null, error: error.message }
  }
}

/**
 * Parse JSON text defensively.
 * @param {string|null} text
 * @returns {{value: unknown|null, error: string|null}}
 */
export function parseJson(text) {
  if (text === null || text === undefined || text.trim() === '') {
    return { value: null, error: null }
  }
  try {
    return { value: JSON.parse(text), error: null }
  } catch (error) {
    return { value: null, error: error.message }
  }
}

/**
 * Read + parse a JSON file in one step.
 * @param {string} absolutePath
 * @returns {{value: unknown|null, missing: boolean, error: string|null}}
 */
export function readJson(absolutePath) {
  const { text, error } = readText(absolutePath)
  if (text === null) return { value: null, missing: error === null, error }
  const parsed = parseJson(text)
  return { value: parsed.value, missing: false, error: parsed.error }
}

/**
 * List directory entries (files + directories), never throwing.
 * @param {string} absolutePath
 * @returns {import('node:fs').Dirent[]}
 */
export function listEntries(absolutePath) {
  try {
    return readdirSync(absolutePath, { withFileTypes: true })
  } catch {
    return []
  }
}

/**
 * List non-excluded child directories, paired with their mtime.
 * @param {string} absolutePath
 * @returns {{name: string, path: string, mtimeMs: number}[]}
 */
export function listDirs(absolutePath) {
  return listEntries(absolutePath)
    .filter((entry) => entry.isDirectory() && !isExcludedPath(entry.name))
    .map((entry) => {
      const childPath = join(absolutePath, entry.name)
      let mtimeMs = 0
      try {
        mtimeMs = statSync(childPath).mtimeMs
      } catch {
        mtimeMs = 0
      }
      return { name: entry.name, path: childPath, mtimeMs }
    })
}

/**
 * List non-excluded files in a directory.
 * @param {string} absolutePath
 * @param {(name: string) => boolean} [accept]
 * @returns {{name: string, path: string, mtimeMs: number}[]}
 */
export function listFiles(absolutePath, accept = () => true) {
  return listEntries(absolutePath)
    .filter(
      (entry) =>
        entry.isFile() && !isExcludedPath(entry.name) && accept(entry.name)
    )
    .map((entry) => {
      const childPath = join(absolutePath, entry.name)
      let mtimeMs = 0
      try {
        mtimeMs = statSync(childPath).mtimeMs
      } catch {
        mtimeMs = 0
      }
      return { name: entry.name, path: childPath, mtimeMs }
    })
}

/**
 * Count directory entries that the exclusion rule rejects (for the explicit
 * "fixtures excluded" declaration the UI must show).
 * @param {string} absolutePath
 * @param {(name: string) => boolean} [accept]
 * @returns {number}
 */
export function countExcludedDirs(absolutePath, accept = () => true) {
  return listEntries(absolutePath).filter(
    (entry) => entry.isDirectory() && accept(entry.name) && isExcludedPath(entry.name)
  ).length
}

/**
 * Format a millisecond timestamp as an ISO-8601 UTC string (empty when absent).
 * @param {number} mtimeMs
 * @returns {string}
 */
export function isoFromMs(mtimeMs) {
  if (!Number.isFinite(mtimeMs) || mtimeMs <= 0) return ''
  return new Date(mtimeMs).toISOString()
}

/**
 * Build the unified response envelope every domain endpoint returns.
 * @param {string} domain
 * @param {string} source repo-relative description of the data source
 * @param {string[]} [notes]
 * @returns {{domain: string, available: boolean, meta: object, data: unknown}}
 */
export function makeEnvelope(domain, source, notes = []) {
  return {
    domain,
    available: false,
    meta: {
      source,
      generatedAt: new Date().toISOString(),
      notes: notes.filter((note) => typeof note === 'string' && note !== ''),
    },
    data: null,
  }
}

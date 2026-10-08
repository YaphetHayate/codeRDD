// Requirement-document bullet parser.
//
// Requirement markdown files in .rdd/changes/archive/<archive>/requirements/
// carry their structured fields as top-level bullets ("- **描述**：…"), with
// nested/continuation lines holding list values. The dashboard shows those
// fields verbatim on the requirement detail page, so the parser only needs to
// group lines under their bullet key — it does not interpret markdown.
import { readText } from './io.mjs'

const BULLET_PATTERN = /^-\s+\*\*(.+?)\*\*\s*[：:]\s*(.*)$/

/**
 * Parse the bullet fields of a requirement document.
 * @param {string} text
 * @returns {{fields: Record<string, string>, order: string[]}}
 */
export function parseRequirementBullets(text) {
  const fields = {}
  const order = []
  let currentKey = null
  for (const line of text.split(/\r?\n/)) {
    const bullet = BULLET_PATTERN.exec(line)
    if (bullet !== null) {
      currentKey = bullet[1].trim()
      if (!(currentKey in fields)) {
        fields[currentKey] = bullet[2].trim()
        order.push(currentKey)
      } else {
        fields[currentKey] += `\n${bullet[2].trim()}`
      }
      continue
    }
    if (currentKey !== null && /^\s+\S/.test(line)) {
      fields[currentKey] += `\n${line.trim()}`
    } else if (line.trim() === '' || /^#{1,6}\s/.test(line) || /^>/.test(line)) {
      currentKey = null
    }
  }
  return { fields, order }
}

/**
 * Split a bullet value into display items (nested bullets and numbered lines).
 * @param {string} value
 * @returns {string[]}
 */
export function toItems(value) {
  if (typeof value !== 'string') return []
  return value
    .split('\n')
    .map((line) => line.replace(/^[-*]\s+/, '').trim())
    .filter((line) => line !== '')
}

/**
 * Read and parse one requirement document.
 * @param {string} absolutePath
 * @returns {{fields: Record<string, string>, order: string[], error: string|null}}
 */
export function readRequirementDoc(absolutePath) {
  const { text, error } = readText(absolutePath)
  if (text === null) return { fields: {}, order: [], error }
  const parsed = parseRequirementBullets(text)
  return { ...parsed, error: null }
}

/**
 * Project the raw bullet fields onto the names the detail view renders.
 * @param {Record<string, string>} fields
 * @returns {Record<string, string>}
 */
export function pickRequirementFields(fields) {
  return {
    description: fields['描述'] ?? '',
    priority: fields['优先级'] ?? '',
    acceptance: fields['验收标准'] ?? '',
    userScenario: fields['用户场景'] ?? '',
    impact: fields['影响范围'] ?? '',
    edgeCases: fields['边界与异常'] ?? '',
    dependencies: fields['依赖关系'] ?? '',
    dataDomains: fields['数据域清单'] ?? '',
    lifecycleNote: fields['流转控制'] ?? '',
  }
}

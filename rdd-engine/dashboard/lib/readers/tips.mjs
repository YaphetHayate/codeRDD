// Reader: tips entries (.rdd/tips/entries/*.json, schema rdd-tip/1).
//
// Lists role experience entries with their role distribution and recorders.
// Deprecated entries stay visible (they are facts) but are counted separately.
import { join } from 'node:path'

import { listFiles, makeEnvelope, readJson } from '../io.mjs'

const DOMAIN = 'tips'
const SOURCE = '.rdd/tips/entries/*.json'

/** Normalize one rdd-tip/1 entry file (broken files keep the same shape). */
function normalizeTip(file) {
  const parsed = readJson(file.path)
  const fallbackId = file.name.replace(/\.json$/, '')
  if (parsed.value === null) {
    return {
      id: fallbackId,
      schema: '',
      title: '',
      problem: '',
      avoidance: '',
      roles: [],
      recordedBy: '',
      recordedAt: '',
      deprecated: false,
      broken: true,
      error: parsed.error,
      file: file.name,
    }
  }
  const entry = parsed.value
  return {
    id: String(entry.id ?? file.name.replace(/\.json$/, '')),
    schema: String(entry.schema ?? ''),
    title: String(entry.title ?? ''),
    problem: String(entry.problem ?? ''),
    avoidance: String(entry.avoidance ?? ''),
    roles: Array.isArray(entry.roles) ? entry.roles.map((role) => String(role)) : [],
    recordedBy: String(entry.recordedBy ?? ''),
    recordedAt: String(entry.recordedAt ?? ''),
    deprecated: entry.deprecated === true,
    broken: false,
    error: null,
    file: file.name,
  }
}

/**
 * Aggregate the tips domain.
 * @param {{rddRoot: string}} context
 */
export function readTips(context) {
  const root = join(context.rddRoot, 'tips', 'entries')
  const env = makeEnvelope(DOMAIN, SOURCE)
  const tips = listFiles(root, (name) => name.toLowerCase().endsWith('.json'))
    .map((file) => normalizeTip(file))
    .sort((left, right) => right.recordedAt.localeCompare(left.recordedAt))
  const broken = tips.filter((tip) => tip.broken)
  if (broken.length > 0) {
    env.meta.notes.push(`${broken.length} 个 tips 条目解析失败（已跳过内容，仅计文件）。`)
  }
  const byRole = new Map()
  for (const tip of tips) {
    for (const role of tip.roles) byRole.set(role, (byRole.get(role) ?? 0) + 1)
  }
  const byRecorder = new Map()
  for (const tip of tips) {
    const recorder = tip.recordedBy === '' ? '未知' : tip.recordedBy
    byRecorder.set(recorder, (byRecorder.get(recorder) ?? 0) + 1)
  }
  env.available = tips.length > 0
  if (tips.length === 0) env.meta.notes.push('tips/entries 为空：尚无角色经验条目。')
  if (tips.length > 0 && tips.length < 5) {
    env.meta.notes.push(`样本量小（${tips.length} 条），分布仅作事实陈述，不具统计意义。`)
  }
  env.data = {
    count: tips.length,
    activeCount: tips.filter((tip) => !tip.deprecated).length,
    deprecatedCount: tips.filter((tip) => tip.deprecated).length,
    entries: tips,
    byRole: [...byRole.entries()]
      .map(([role, count]) => ({ role, count }))
      .sort((left, right) => right.count - left.count),
    byRecorder: [...byRecorder.entries()]
      .map(([recorder, count]) => ({ recorder, count }))
      .sort((left, right) => right.count - left.count),
  }
  return env
}

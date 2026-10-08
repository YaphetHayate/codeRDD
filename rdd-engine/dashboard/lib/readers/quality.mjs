// Reader: retrieval-quality snapshots (.rdd/tests/explore-search/results.json).
//
// The quality domain consumes the evaluate-suite result snapshots: the newest
// snapshot drives the KPI row, older ones are counted as history. The case
// library file (cases.json) supplies the active case count.
import { join } from 'node:path'

import { listFiles, makeEnvelope, readJson } from '../io.mjs'

const DOMAIN = 'quality'
const SOURCE = '.rdd/tests/explore-search/results.json'

/** Normalize the summary block of one snapshot. */
function normalizeSummary(rawSummary, cases) {
  const summary = rawSummary ?? {}
  const derived = { passed: 0, failed: 0, skipped: 0, partial: 0, other: 0 }
  for (const testCase of cases) {
    const status = String(testCase?.status ?? 'other')
    if (status in derived) derived[status] += 1
    else derived.other += 1
  }
  return {
    total: Number(summary.total ?? cases.length),
    passed: Number(summary.passed ?? derived.passed),
    failed: Number(summary.failed ?? derived.failed),
    skipped: Number(summary.skipped ?? derived.skipped),
    partial: Number(summary.partial ?? derived.partial),
  }
}

/** Normalize one snapshot file. */
function normalizeSnapshot(file) {
  const parsed = readJson(file.path)
  const snapshot = parsed.value ?? {}
  const cases = Array.isArray(snapshot.cases) ? snapshot.cases : []
  return {
    file: file.name,
    generatedAt: typeof snapshot.generatedAt === 'string' ? snapshot.generatedAt : '',
    archive: typeof snapshot.archive === 'string' ? snapshot.archive : '',
    feature: typeof snapshot.feature === 'string' ? snapshot.feature : '',
    summary: normalizeSummary(snapshot.summary, cases),
    cases: cases.map((testCase) => ({
      id: String(testCase?.id ?? ''),
      status: String(testCase?.status ?? 'unknown'),
      checks: testCase?.checks ?? null,
      issueCount: Array.isArray(testCase?.issues) ? testCase.issues.length : 0,
    })),
    error: parsed.error,
  }
}

/**
 * Aggregate the retrieval-quality domain.
 * @param {{rddRoot: string}} context
 */
export function readQuality(context) {
  const root = join(context.rddRoot, 'tests', 'explore-search')
  const env = makeEnvelope(DOMAIN, SOURCE)
  const snapshots = listFiles(root, (name) => /^results.*\.json$/.test(name))
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    .map((file) => normalizeSnapshot(file))
  for (const snapshot of snapshots) {
    if (snapshot.error !== null) env.meta.notes.push(`${snapshot.file} 解析失败：${snapshot.error}`)
  }
  const library = readJson(join(root, 'cases.json'))
  const libraryCases = Array.isArray(library.value?.cases) ? library.value.cases.length : 0
  const primary = snapshots[0] ?? null
  env.available = primary !== null
  if (primary === null) {
    env.meta.notes.push('未找到检索质量快照（.rdd/tests/explore-search/results.json）。')
  } else if (snapshots.length <= 1) {
    env.meta.notes.push('仅 1 份质量快照：单点不构成趋势，不绘制趋势图。')
  }
  env.data = {
    snapshotCount: snapshots.length,
    primary,
    snapshots: snapshots.map((snapshot) => ({
      file: snapshot.file,
      generatedAt: snapshot.generatedAt,
      archive: snapshot.archive,
      summary: snapshot.summary,
    })),
    caseLibrary: {
      activeCount: libraryCases,
      lastChange: typeof library.value?.lastChange === 'string' ? library.value.lastChange : '',
    },
  }
  return env
}

// Reader: requirement archives (.rdd/changes/archive/**).
//
// Counts, timeline, owner distribution, lifecycle state and rejection (打回)
// records. Archives without task.json are the documented legacy shape: they
// count towards the archive total, get an explicit "legacy" marker, and are not
// deep-parsed (requirement doc layouts differ across history).
import { join } from 'node:path'

import { isoFromMs, listDirs, listFiles, makeEnvelope, readJson } from '../io.mjs'
import {
  pickRequirementFields,
  readRequirementDoc,
  toItems,
} from '../requirement-doc.mjs'

const DOMAIN = 'requirements'
const SOURCE = '.rdd/changes/archive/**'

/** Split a route remark into its "|"-separated rejection segments. */
function remarkSegments(remark) {
  if (typeof remark !== 'string' || remark.trim() === '') return []
  return remark
    .split('|')
    .map((segment) => segment.trim())
    .filter((segment) => segment !== '')
}

/** Normalize one task entry from task.json. */
function normalizeTask(rawTask, archiveName) {
  const task = rawTask ?? {}
  const owners = Array.isArray(task.currentOwners) ? task.currentOwners : []
  const designDocs = Array.isArray(task.designDocs) ? task.designDocs : []
  const workers = Array.isArray(task.currentWorker) ? task.currentWorker : []
  return {
    archive: archiveName,
    id: task.id ?? null,
    title: typeof task.title === 'string' ? task.title : '',
    lifecycle: typeof task.lifecycle === 'string' ? task.lifecycle : '',
    phase: typeof task.phase === 'string' ? task.phase : '',
    routeOwner: typeof task.routeOwner === 'string' ? task.routeOwner : '',
    workMode: typeof task.workMode === 'string' ? task.workMode : '',
    running: typeof task.running === 'boolean' ? task.running : null,
    owners: owners.map((owner) => String(owner)),
    workers: workers.map((worker) => {
      const entries = Object.entries(worker ?? {})
      const [role, at] = entries.length > 0 ? entries[0] : ['', '']
      return { role: String(role), at: String(at) }
    }),
    remark: typeof task.remark === 'string' ? task.remark : '',
    remarks: remarkSegments(task.remark),
    designDocs: designDocs.map((doc) => ({
      path: String(doc?.path ?? ''),
      status: String(doc?.status ?? ''),
    })),
    requirementPath: typeof task.requirement === 'string' ? task.requirement : '',
    requirementDocument: task.requirement ?? null,
    involvedFiles: Array.isArray(task.involvedFiles)
      ? task.involvedFiles.map((file) => String(file))
      : [],
    priority: typeof task.priority === 'string' ? task.priority : '',
    dependencies: typeof task.dependencies === 'string' ? task.dependencies : '',
    impact: typeof task.impact === 'string' ? task.impact : '',
    acceptance: typeof task.acceptance === 'string' ? task.acceptance : '',
  }
}

/**
 * Legacy archive shape (no parseable task.json).
 * @returns {object|null} null when the directory is not an archive at all.
 */
function legacyArchiveEntry(base, dir) {
  const markdown = listFiles(dir.path, (name) => name.toLowerCase().endsWith('.md'))
  const hasTaskDoc = markdown.some((file) => file.name === 'task.md')
  if (!hasTaskDoc && markdown.length === 0) {
    // A directory with neither task.json nor any markdown is not an archive.
    return null
  }
  return {
    ...base,
    structured: false,
    taskCount: 0,
    tasks: [],
    firstTitle: '',
    owners: [],
    lifecycle: {},
    remarks: [],
    designDocs: [],
  }
}

/** Cross-task aggregates of one structured archive (lifecycle / owners / remarks). */
function aggregateTasks(tasks, archiveName) {
  const lifecycle = {}
  const owners = new Map()
  const remarks = []
  for (const task of tasks) {
    const key = task.lifecycle === '' ? 'unknown' : task.lifecycle
    lifecycle[key] = (lifecycle[key] ?? 0) + 1
    for (const owner of task.owners) owners.set(owner, (owners.get(owner) ?? 0) + 1)
    for (const segment of task.remarks) {
      remarks.push({ archive: archiveName, id: task.id, title: task.title, text: segment })
    }
  }
  return {
    lifecycle,
    owners: [...owners.entries()].map(([name, count]) => ({ name, count })),
    remarks,
  }
}

/** Read one archive directory into its list-view record. */
function readArchiveEntry(dir) {
  const taskJsonPath = join(dir.path, 'task.json')
  const parsed = readJson(taskJsonPath)
  const base = {
    name: dir.name,
    path: dir.path,
    updatedAt: isoFromMs(dir.mtimeMs),
    legacy: parsed.value === null,
    notes: [],
  }
  if (parsed.error !== null) base.notes.push(`task.json 解析失败：${parsed.error}`)
  if (parsed.value === null) return legacyArchiveEntry(base, dir)
  const tasks = Array.isArray(parsed.value.tasks)
    ? parsed.value.tasks.map((task) => normalizeTask(task, dir.name))
    : []
  const aggregates = aggregateTasks(tasks, dir.name)
  return {
    ...base,
    structured: true,
    taskCount: tasks.length,
    tasks,
    firstTitle: tasks.length > 0 ? tasks[0].title : '',
    owners: aggregates.owners,
    lifecycle: aggregates.lifecycle,
    remarks: aggregates.remarks,
    designDocs: tasks.flatMap((task) => task.designDocs),
    generatedAt: typeof parsed.value.generatedAt === 'string' ? parsed.value.generatedAt : '',
  }
}

/** Lifecycle buckets and owner counts merged across every archive. */
function mergeArchiveTotals(archives) {
  const lifecycle = {}
  const owners = new Map()
  for (const archive of archives) {
    for (const [key, count] of Object.entries(archive.lifecycle)) {
      lifecycle[key] = (lifecycle[key] ?? 0) + count
    }
    for (const owner of archive.owners) {
      owners.set(owner.name, (owners.get(owner.name) ?? 0) + owner.count)
    }
  }
  return { lifecycle, owners }
}

/** Timeline rows (one per archive, newest first by caller order). */
function archiveTimeline(archives) {
  return archives.map((archive) => ({
    name: archive.name,
    at: archive.updatedAt,
    title: archive.firstTitle,
    legacy: !archive.structured,
  }))
}

/**
 * One archive's parsed state, newest first, plus cross-archive aggregates.
 * @param {{rddRoot: string}} context
 */
export function readArchives(context) {
  const root = join(context.rddRoot, 'changes', 'archive')
  const notes = []
  const dirs = listDirs(root).sort((left, right) => right.mtimeMs - left.mtimeMs)
  const env = makeEnvelope(DOMAIN, SOURCE)
  if (dirs.length === 0) {
    env.meta.notes.push('archive 目录为空：尚未归档任何需求。')
    env.data = { totalCount: 0, structuredCount: 0, legacyCount: 0, archives: [], owners: [], lifecycle: {}, remarks: [], timeline: [] }
    return env
  }
  const archives = []
  for (const dir of dirs) {
    const entry = readArchiveEntry(dir)
    if (entry === null) continue
    for (const note of entry.notes) notes.push(`${entry.name}：${note}`)
    archives.push(entry)
  }
  const legacyCount = archives.filter((archive) => !archive.structured).length
  if (legacyCount > 0) {
    notes.push(`${legacyCount} 个归档为旧结构（无 task.json），仅计入总数并标注 legacy。`)
  }
  const { lifecycle, owners } = mergeArchiveTotals(archives)
  env.available = archives.length > 0
  env.meta.notes = env.meta.notes.concat(notes)
  env.data = {
    totalCount: archives.length,
    structuredCount: archives.length - legacyCount,
    legacyCount,
    taskCount: archives.reduce((sum, archive) => sum + archive.taskCount, 0),
    archives,
    owners: [...owners.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((left, right) => right.count - left.count),
    lifecycle,
    remarks: archives.flatMap((archive) => archive.remarks),
    timeline: archiveTimeline(archives),
  }
  return env
}

/**
 * One requirement detail: task fields + the requirement document's bullets.
 * @param {{rddRoot: string}} context
 * @param {string} archiveName
 * @param {string} taskId
 */
export function readArchiveDetail(context, archiveName, taskId) {
  const env = makeEnvelope(DOMAIN, SOURCE)
  const archive = readArchives(context).data.archives.find(
    (entry) => entry.name === archiveName
  )
  if (archive === undefined) {
    env.meta.notes.push(`未找到归档 ${archiveName}`)
    return env
  }
  const task = archive.tasks.find((entry) => String(entry.id) === String(taskId))
  if (task === undefined) {
    env.meta.notes.push(`归档 ${archiveName} 中无任务 #${taskId}`)
    return env
  }
  const requirementAbs = join(archive.path, task.requirementPath)
  const doc = readRequirementDoc(requirementAbs)
  const fields = pickRequirementFields(doc.fields)
  env.available = true
  env.data = {
    archive: archiveName,
    legacy: archive.legacy,
    task,
    requirement: {
      path: task.requirementPath,
      fields,
      acceptanceItems: toItems(fields.acceptance),
      dataDomainItems: toItems(fields.dataDomains),
      error: doc.error,
    },
  }
  if (doc.error !== null) env.meta.notes.push(`需求文档读取失败：${doc.error}`)
  return env
}

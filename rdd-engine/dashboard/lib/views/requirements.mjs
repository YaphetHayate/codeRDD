// Requirement-archive views: the list (#/requirements) and the drill-down
// detail (#/requirements/<archive>/<id>) — acceptance criteria 3's landing spot.
import { badge, breadcrumb, chip, dataTable, emptyState, fieldList, icon, panel, remarkList, sectionHead, statTile, stateBadge } from '../components.mjs'
import { barChart, stackedBar } from '../charts.mjs'
import { dateTime, esc, num } from '../format.mjs'
import { domainHeader, renderLayout } from '../layout.mjs'
import { domainUnavailable, notesBlock } from './shared.mjs'

const LIFECYCLE_LABELS = { active: '进行中', completed: '已完成', deprecated: '已废弃', unknown: '未标注' }
const LIFECYCLE_TONES = { active: 'info', completed: 'success', deprecated: 'neutral', unknown: 'neutral' }

/** One table row per archive. */
function archiveRows(archives) {
  return archives.map((archive) => {
    const target = archive.structured && archive.tasks.length > 0 ? `/requirements/${archive.name}/${archive.tasks[0].id}` : ''
    const lifecycleCells = Object.entries(archive.lifecycle)
      .map(([state, count]) => badge(`${LIFECYCLE_LABELS[state] ?? state} ${count}`, LIFECYCLE_TONES[state] ?? 'neutral'))
      .join(' ')
    return {
      href: target === '' ? undefined : target,
      cells: [
        { text: archive.name, mono: true },
        { text: String(archive.taskCount), align: 'right', mono: true },
        { text: archive.firstTitle === '' ? '（旧结构，无 task.json）' : archive.firstTitle, title: archive.firstTitle },
        { text: archive.owners.map((owner) => owner.name).join(' / ') || '—' },
        { html: archive.structured ? lifecycleCells : badge('旧结构', 'neutral') },
        { text: dateTime(archive.updatedAt), mono: true, muted: true },
        { html: target === '' ? '<span class="field-empty">—</span>' : `<a class="row-link" href="${esc(target)}">进入</a>` },
      ],
    }
  })
}

/** KPI row of the archive list. */
function listSummaryTiles(data) {
  return [
    statTile({ value: num(data.totalCount), label: '归档总数', unit: ' 个', hint: '含旧结构归档' }),
    statTile({ value: num(data.structuredCount), label: '结构化归档', unit: ' 个' }),
    statTile({ value: num(data.legacyCount), label: '旧结构归档', unit: ' 个', tone: data.legacyCount > 0 ? 'warn' : 'ok', hint: '无 task.json，仅计数' }),
    statTile({ value: num(data.taskCount), label: '任务合计', unit: ' 条' }),
    statTile({ value: num(data.remarks.length), label: '打回记录', unit: ' 条', tone: data.remarks.length > 0 ? 'warn' : 'ok' }),
  ].join('')
}

/** Owner distribution panel. */
function ownerPanel(data) {
  return panel({
    title: 'Owner 分布',
    note: '按 currentOwners 计数',
    html: data.owners.length === 0
      ? emptyState({ fact: '暂无 Owner 数据', cause: '归档任务尚未记录 currentOwners。', action: '任务进入路由后此处显示 Owner 分布。' })
      : barChart({ rows: data.owners.map((owner) => ({ label: owner.name, value: owner.count })) }),
    foot: esc('同一任务可归属多个 Owner，故合计可大于任务数。'),
  })
}

/** Lifecycle-state panel. */
function lifecyclePanel(data) {
  return panel({
    title: '生命周期状态',
    note: '按 task.lifecycle 计数',
    html: Object.keys(data.lifecycle).length === 0
      ? emptyState({ fact: '暂无生命周期数据', cause: '归档任务未记录 lifecycle 字段。', action: '任务流转后此处显示 active / completed / deprecated 分布。' })
      : stackedBar({
          segments: Object.entries(data.lifecycle).map(([state, count]) => ({
            label: LIFECYCLE_LABELS[state] ?? state,
            value: count,
          })),
        }),
  })
}

/** Archive table panel. */
function archiveTablePanel(data) {
  return panel({
    title: '需求归档列表',
    note: `${data.totalCount} 个归档`,
    html: dataTable({
      columns: [
        { label: '归档' },
        { label: '任务', align: 'right' },
        { label: '标题' },
        { label: 'Owner' },
        { label: '生命周期' },
        { label: '更新时间 (UTC)' },
        { label: '详情' },
      ],
      rows: archiveRows(data.archives),
      empty: emptyState({ fact: '暂无归档', cause: '.rdd/changes/archive/ 下没有归档目录。', action: '完成一次需求流转（PM 归档）后此处出现记录。' }),
    }),
    foot: '旧结构归档（无 task.json）计入总数并标注，不做深度解析。',
  })
}

/** Rejection (打回) feed panel. */
function rejectionPanel(data) {
  return panel({
    title: '打回记录',
    note: 'task.remark 按竖线分段',
    html:
      data.remarks.length === 0
        ? emptyState({ fact: '暂无打回记录', cause: '全部归档任务的 remark 为空。', action: '发生驳回或路由备注后此处逐段列出。' })
        : `<ul class="remark-feed">${data.remarks
            .map(
              (entry) =>
                `<li><div class="remark-meta">${icon('archive', 'inline-icon')}<span class="remark-arch">${esc(entry.archive)} #${esc(entry.id)}</span><span class="remark-title">${esc(entry.title)}</span></div><div class="remark-text">${esc(entry.text)}</div></li>`
            )
            .join('')}</ul>`,
  })
}

/** Overview KPI row + charts + archive table + rejection records. */
function renderList(domains) {
  const data = domains.requirements.data
  return `<div class="stat-row">${listSummaryTiles(data)}</div><div class="split-7-5">${ownerPanel(data)}${lifecyclePanel(data)}</div>${archiveTablePanel(data)}${rejectionPanel(data)}`
}

/**
 * Render the requirement list page body.
 * @param {{domains: object, projectRoot: string, generatedAt: string, counts: object}} input
 */
export function renderRequirementsPage(input) {
  const envelope = input.domains.requirements
  const header = domainHeader({
    title: '需求归档',
    subtitle: 'changes/archive/ 下的一次需求批次：数量、时间线、Owner 分布、生命周期与打回记录。',
    envelope,
  })
  const body =
    envelope.available === false
      ? domainUnavailable(envelope, {
          fact: `暂无归档 —— .rdd/changes/archive/ 下没有归档目录。`,
          cause: '该数据源为空或尚未创建（路径：.rdd/changes/archive/）。',
          action: '完成一次需求流转（PM 归档）后刷新本页。',
        })
      : renderList(input.domains)
  return renderLayout({
    title: '需求归档',
    activeKey: 'requirements',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(envelope)}${body}`,
  })
}

/** Detail field rows in the UX §3.2.3 order. */
function detailFields(data) {
  const task = data.task
  const fields = data.requirement.fields
  return fieldList({
    rows: [
      { key: '归档目录', text: data.archive, mono: true },
      { key: '任务 ID', text: task.id === null ? '—' : `#${task.id}` },
      { key: '优先级', text: fields.priority || task.priority || '' },
      { key: '生命周期', html: stateBadge(task.lifecycle, LIFECYCLE_LABELS) },
      { key: '阶段', text: task.phase || '' },
      { key: '当前 Owner', html: task.owners.length === 0 ? '<span class="field-empty">—</span>' : task.owners.map((owner) => badge(owner, 'info')).join(' ') },
      { key: '路由 / 工作模式', text: [task.routeOwner, task.workMode].filter((value) => value !== '').join(' · ') },
      { key: 'running', text: task.running === null ? '' : String(task.running) },
      { key: '需求文档路径', text: task.requirementPath, mono: true, copy: true },
    ],
  })
}

/** Claim trail (currentWorker) as its own field block. */
function workerField(data) {
  const workers = data.task.workers
  return fieldList({
    rows: [
      {
        key: '认领留痕',
        html:
          workers.length === 0
            ? '<span class="field-empty">—</span>'
            : `<ul class="worker-list">${workers.map((worker) => `<li><b>${esc(worker.role)}</b><span>${esc(dateTime(worker.at))}</span></li>`).join('')}</ul>`,
      },
    ],
  })
}

/** Design-doc references, cross-requirement links and long-text fields. */
function documentFields(data) {
  const task = data.task
  const fields = data.requirement.fields
  const designDocs =
    task.designDocs.length === 0
      ? '<span class="field-empty">—</span>'
      : `<ul class="doc-list">${task.designDocs
          .map((doc) => `<li><code>${esc(doc.path)}</code>${stateBadge(doc.status, { ready: '已就绪', pending: '待处理', active: 'active' })}</li>`)
          .join('')}</ul>`
  const acceptance =
    data.requirement.acceptanceItems.length === 0
      ? '<span class="field-empty">—</span>'
      : `<ol class="acceptance-list">${data.requirement.acceptanceItems.map((item) => `<li>${esc(item)}</li>`).join('')}</ol>`
  return fieldList({
    rows: [
      { key: '设计文档', html: designDocs },
      { key: '关联设计文档路径（跨需求）', text: fields.dependencies },
      { key: '影响范围', text: fields.impact },
      { key: '依赖关系', text: fields.dependencies },
      { key: '涉及文件', html: task.involvedFiles.length === 0 ? '<span class="field-empty">—</span>' : `<ul class="doc-list">${task.involvedFiles.map((file) => `<li><code>${esc(file)}</code></li>`).join('')}</ul>` },
      { key: '验收标准', html: acceptance },
      { key: '数据域清单', html: data.requirement.dataDomainItems.length === 0 ? '<span class="field-empty">—</span>' : `<ul class="doc-list">${data.requirement.dataDomainItems.map((item) => `<li>${esc(item)}</li>`).join('')}</ul>` },
    ],
  })
}

/** Layout for "no such requirement" (unknown archive or task id). */
function detailNotFound(input, crumbs) {
  const body = `${breadcrumb(crumbs)}${panel({
    title: '未找到该需求',
    html: emptyState({
      fact: `未找到该需求（归档 ${input.archive}，任务 #${input.taskId}）。`,
      cause: '可能已被归档整理或 ID 变更。',
      action: '返回需求归档列表重新选择。',
      extra: undefined,
    }),
    foot: `<a class="btn" href="/requirements">返回需求归档</a>`,
  })}`
  return renderLayout({
    title: '未找到该需求',
    activeKey: 'requirements',
    counts: input.counts,
    options: input,
    body,
  })
}

/** Status chips of the detail header. */
function detailBadges(task, fields) {
  return [
    task.id === null ? '' : chip(`任务 #${task.id}`),
    stateBadge(task.lifecycle, LIFECYCLE_LABELS),
    fields.priority === '' ? '' : badge(fields.priority, 'info'),
    task.phase === '' ? '' : badge(`阶段 ${task.phase}`, 'info'),
    task.running === true ? badge('running', 'success') : '',
  ]
    .filter((entry) => entry !== '')
    .join(' ')
}

/** Detail header: breadcrumb + title + status chips. */
function detailHeader(crumbs, title, task, fields) {
  return `<header class="detail-head">${breadcrumb(crumbs)}<h1>${esc(title)}</h1><div class="detail-badges">${detailBadges(task, fields)}</div></header>`
}

/**
 * Render the requirement detail page body (or its not-found state).
 * @param {{detail: object, domains: object, counts: object, projectRoot: string, generatedAt: string, archive: string, taskId: string}} input
 */
export function renderRequirementDetail(input) {
  const detail = input.detail
  const crumbs = [
    { label: '总览', href: '/' },
    { label: '需求归档', href: '/requirements' },
    { label: `${input.archive} #${input.taskId}` },
  ]
  if (detail.available === false) return detailNotFound(input, crumbs)
  const task = detail.data.task
  const fields = detail.data.requirement.fields
  const title = task.title === '' ? `${detail.data.archive} #${task.id}` : task.title
  const header = detailHeader(crumbs, title, task, fields)
  const remarkPanel = panel({
    title: '打回 / 路由备注',
    note: '竖线分段，逐段成条',
    html: remarkList(task.remarks),
  })
  const fieldsPanel = panel({ title: '需求字段', html: detailFields(detail.data) + workerField(detail.data) + documentFields(detail.data) })
  const descriptionPanel = panel({
    title: '需求描述',
    html: fields.description === '' ? '<span class="field-empty">—</span>' : `<p class="prose">${esc(fields.description)}</p>`,
  })
  const scenarioPanel = panel({ title: '用户场景', html: `<p class="prose">${esc(fields.userScenario || '—')}</p>` })
  const sourceNote = `${sectionHead('原始文档')}<p class="prose prose-muted">完整需求正文：<code>${esc(task.requirementPath)}</code>（归档根 <code>${esc(detail.data.archive)}</code>）。</p>`
  return renderLayout({
    title,
    activeKey: 'requirements',
    counts: input.counts,
    options: input,
    body: `${header}${notesBlock(detail)}${fieldsPanel}${descriptionPanel}${scenarioPanel}${remarkPanel}${sourceNote}`,
  })
}

#!/usr/bin/env node
// convert-openrca.mjs — L2 观测面改装脚本(改装规则 = 可审代码)
//
// RULE_VERSION 2(2026-08-31,依 pilot 实测结构校准;v1 通用骨架存 convert-openrca.v1.mjs):
//   数据源形态(实测 datasets/OpenRCA-data/Bank):
//     query.csv            task_index, instruction(现象), scoring_points(真值,严禁进 plane)
//     record.csv           level, component, timestamp, datetime, reason(根因真值,UTC+8)
//     telemetry/<date>/{log,metric,trace}/*.csv  全系统平面遥测(大文件,trace 可达 1.2GB)
//
// 规则映射(设计「改装规则」→ 实现):
//   R1 时间归一   T0 = query 症状窗口起点(不用根因时刻,防泄答案);plane 时间列输出相对 T0 秒数
//   R2 实体处理   组件名(cmdb_id)保留——多组件平面数据中组件名非答案线索(哪个组件才是根因),
//                 且组件名是评分要素(root cause component),中性化破坏与论文基线可比性(审计已记)
//   R3 窗口切片   [T0-3600s, T0+2400s](60min 因果追溯 + 40min 覆盖症状窗口);大文件流式过滤
//   R4 答案剔除   query.csv / record.csv / scoring_points 一律不进 plane;产物落地后复检
//   R5 信号保留   四类遥测(log/metric_app/metric_container/trace_span)全保留,指标与日志名不动
//
// 用法:
//   node tools/convert-openrca.mjs --openrca --system Bank --task task_1 \
//        --data datasets/OpenRCA-data/Bank --out cases/l2-openrca/openrca-bank-task1 [--audit]
//   输出:case 目录(plane/ 四文件 + topology.json + case.json)+ stdout 两行 JSON(answers 行 + registry 行)
//
// 体积说明:plane 为百 MB 级 grep 观测面(worker 按需查询,不全读);plane 已 gitignore,可由本脚本再生。

import { createReadStream, createWriteStream, readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { once } from "node:events";

const LAB_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const RULE_VERSION = 2;
const ADAPTER = {
  tzOffset: "+08:00",                 // OpenRCA 全部时间戳为 UTC+8(官方 FAQ)
  windowBeforeSec: 3600,              // R3:症状窗口起点前 60min(因果追溯)
  windowAfterSec: 2400,               // R3:起点后 40min(覆盖 30min 症状窗口 + 尾部)
  telemetryFiles: {
    log: "log_service.csv",           // timestamp(s), cmdb_id, log_name, value
    metricApp: "metric_app.csv",      // timestamp(s), rr, sr, cnt, mrt, tc
    metricContainer: "metric_container.csv", // timestamp(s), cmdb_id, kpi_name, value
    trace: "trace_span.csv",          // timestamp(ms), cmdb_id, parent_id, span_id, trace_id, duration
  },
};

function fail(msg) { console.error(`[convert-openrca] FAIL: ${msg}`); process.exit(1); }

function parseArgs(argv) {
  const a = {};
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--openrca") a.openrca = true;
    else if (argv[i] === "--system") a.system = argv[++i];
    else if (argv[i] === "--task") a.task = argv[++i];
    else if (argv[i] === "--data") a.data = argv[++i];
    else if (argv[i] === "--out") a.out = argv[++i];
    else if (argv[i] === "--audit") a.audit = true;
    else if (argv[i] === "--range") a.range = argv[++i]; // "HH:MM-HH:MM" — task_index 非唯一(=任务类型),按窗口唯一定位
  }
  return a;
}

// ---------- CSV(带引号/换行字段)----------
function splitCsvLine(line) {
  const out = [];
  let cur = "", inQ = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQ) {
      if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (c === '"') inQ = false;
      else cur += c;
    } else if (c === '"') inQ = true;
    else if (c === ",") { out.push(cur); cur = ""; }
    else cur += c;
  }
  out.push(cur);
  return out;
}
function readCsv(path) { // 小文件全载(仅 query/record)
  const rows = [];
  let header = null, buf = "";
  const text = readFileSync(path, "utf8");
  for (const rawLine of text.split(/\r?\n/)) {
    buf = buf ? buf + "\n" + rawLine : rawLine;
    if ((buf.match(/"/g) || []).length % 2 === 1) continue; // 引号未闭合,续行
    if (!buf.trim()) { buf = ""; continue; }
    const cols = splitCsvLine(buf);
    buf = "";
    if (!header) { header = cols; continue; }
    rows.push(Object.fromEntries(header.map((h, i) => [h, cols[i] ?? ""])));
  }
  return rows;
}

// ---------- 时间 ----------
const MONTHS = { January: 1, February: 2, March: 3, April: 4, May: 5, June: 6, July: 7, August: 8, September: 9, October: 10, November: 11, December: 12 };
function epochUTC8(dateStr, timeStr) {
  // dateStr: "March 4, 2021";timeStr: "14:30"
  const m = dateStr.match(/^([A-Z][a-z]+)\s+(\d{1,2}),\s*(\d{4})$/);
  const t = timeStr.match(/^(\d{1,2}):(\d{2})$/);
  if (!m || !t || !MONTHS[m[1]]) return null;
  const ms = Date.parse(`${m[3]}-${String(MONTHS[m[1]]).padStart(2, "0")}-${String(m[2]).padStart(2, "0")}T${t[1].padStart(2, "0")}:${t[2]}:00${ADAPTER.tzOffset}`);
  return isNaN(ms) ? null : ms;
}
function parseWindowFromInstruction(instr) {
  // 日期措辞:"On March 4, 2021" / "of March 6, 2021,";时间措辞:"time range of 14:30 to 15:00" / "between 18:00 and 18:30" / "from 06:00 to 06:30"
  const d = instr.match(/(?:On|of)\s+([A-Z][a-z]+\s+\d{1,2},\s*\d{4})/);
  const w = instr.match(/(\d{1,2}:\d{2})\s+(?:to|and)\s+(?:(?:March|April|May|June|July|August|September|October|November|December|January|February)\s+\d{1,2},\s*\d{4},?\s*at\s+)?(\d{1,2}:\d{2})/);
  if (!d || !w) return null;
  const t0 = epochUTC8(d[1], w[1]);
  const t1 = epochUTC8(d[1], w[2]);
  if (t0 == null || t1 == null || t1 <= t0) return null; // 跨日窗口(t1<=t0)不支持——切片语义按单日遥测目录设计
  return { t0, t1, date: d[1], start: w[1], end: w[2] };
}
function dateDirOf(dateStr) { // "March 4, 2021" → "2021_03_04"
  const m = dateStr.match(/^([A-Z][a-z]+)\s+(\d{1,2}),\s*(\d{4})$/);
  if (!m) return null;
  return `${m[3]}_${String(MONTHS[m[1]]).padStart(2, "0")}_${String(m[2]).padStart(2, "0")}`;
}

// ---------- 流式切片(R3+R1)----------
const cmdbIdxCache = new Map(); // src → cmdb_id 列下标(主流程预探测)
async function peekColumns(path) {
  const rl = createInterface({ input: createReadStream(path, "utf8"), crlfDelay: Infinity });
  for await (const line of rl) { rl.close(); return splitCsvLine(line); }
  return [];
}
async function sliceTelemetry(src, dst, tsUnit, tStartMs, tEndMs, t0Ms, audit) {
  const rl = createInterface({ input: createReadStream(src, "utf8"), crlfDelay: Infinity });
  const ws = createWriteStream(dst, "utf8");
  let headerIdx = -1, kept = 0, total = 0;
  const cmdbSeen = new Set();
  let first = true;
  for await (const line of rl) {
    if (first) {
      headerIdx = splitCsvLine(line).indexOf("timestamp");
      if (headerIdx < 0) headerIdx = 0;
      ws.write(line + "\n");
      first = false;
      continue;
    }
    if (!line.trim()) continue;
    total++;
    const cols = splitCsvLine(line);
    const raw = Number(cols[headerIdx]);
    if (!Number.isFinite(raw)) continue;
    const ms = tsUnit === "ms" ? raw : raw * 1000;
    if (ms < tStartMs || ms > tEndMs) continue;
    cols[headerIdx] = String(Math.round((ms - t0Ms) / 1000)); // R1:相对 T0 秒
    const ci = cmdbIdxCache.get(src);
    if (ci != null && ci >= 0 && cols[ci]) cmdbSeen.add(cols[ci]);
    ws.write(cols.join(",") + "\n");
    kept++;
  }
  ws.end();
  await once(ws, "finish");
  audit.sliced.push({ file: basename(src), kept, total });
  return cmdbSeen;
}

// ---------- 主流程 ----------
async function main() {
  const a = parseArgs(process.argv);
  if (!a.openrca || !a.system || !a.task || !a.data || !a.out) {
    fail("用法: --openrca --system Bank --task task_1 --data datasets/OpenRCA-data/Bank --out cases/l2-openrca/openrca-bank-task1 [--audit]");
  }

  // 1) query:定位 task 行(task_index 非唯一 = 任务类型;有 --range 时按窗口唯一定位,否则取首个匹配)
  const queryPath = join(a.data, "query.csv");
  if (!existsSync(queryPath)) fail(`query.csv 缺失: ${queryPath}`);
  const queries = readCsv(queryPath);
  let q;
  if (a.range) {
    const rm = a.range.match(/^(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$/);
    if (!rm) fail(`--range 格式应为 HH:MM-HH:MM,收到: ${a.range}`);
    const cands = queries.filter((r) => {
      const w = parseWindowFromInstruction(r.instruction);
      return r.task_index === a.task && w && w.start === rm[1] && w.end === rm[2];
    });
    if (cands.length === 0) fail(`task ${a.task} 无窗口 ${a.range} 的行`);
    if (cands.length > 1) fail(`task ${a.task} 窗口 ${a.range} 命中 ${cands.length} 行(非唯一),需检查 query.csv`);
    q = cands[0];
  } else {
    q = queries.find((r) => r.task_index === a.task);
    if (q) console.error(`[warn] 未指定 --range,task ${a.task} 取首个匹配行(同 index 共 ${queries.filter((r) => r.task_index === a.task).length} 行)`);
  }
  if (!q) fail(`task ${a.task} 不在 query.csv(共 ${queries.length} 行)`);
  const win = parseWindowFromInstruction(q.instruction);
  if (!win) fail(`instruction 窗口解析失败(需含 'On <Month d, yyyy>' 与 'time range of HH:MM to HH:MM'): ${q.instruction.slice(0, 120)}`);

  // 2) record:窗口内真值(答案来源,不进 plane)
  const recordPath = join(a.data, "record.csv");
  if (!existsSync(recordPath)) fail(`record.csv 缺失: ${recordPath}`);
  const records = readCsv(recordPath).filter((r) => {
    const ms = Date.parse(`${r.datetime.replace(" ", "T")}${ADAPTER.tzOffset}`);
    return Number.isFinite(ms) && ms >= win.t0 && ms <= win.t1;
  });
  if (records.length === 0) fail(`record.csv 中无窗口内真值(${win.date} ${win.start}~${win.end})——检查数据完整性`);

  // 3) telemetry 目录定位(query 日期 → telemetry/<date>)
  const dateDir = dateDirOf(win.date);
  const teleDir = join(a.data, "telemetry", dateDir);
  if (!existsSync(teleDir)) fail(`telemetry 目录缺失: ${teleDir}(期望日期 ${dateDir})`);

  // 4) R3 切片窗口
  const tStart = win.t0 - ADAPTER.windowBeforeSec * 1000;
  const tEnd = win.t0 + ADAPTER.windowAfterSec * 1000;

  // 5) 逐文件切片
  const planeDir = join(a.out, "plane");
  mkdirSync(planeDir, { recursive: true });
  const audit = { rule_version: RULE_VERSION, task: a.task, window: { date: win.date, start: win.start, end: win.end }, sliceEpochMs: { start: tStart, end: tEnd }, sliced: [], skipped: [], records_in_window: records.length };
  const srcs = [
    { key: "log", file: ADAPTER.telemetryFiles.log, unit: "s" },
    { key: "metric", file: ADAPTER.telemetryFiles.metricApp, unit: "s" },
    { key: "metric", file: ADAPTER.telemetryFiles.metricContainer, unit: "s" },
    { key: "trace", file: ADAPTER.telemetryFiles.trace, unit: "ms" },
  ];
  const cmdbAll = new Set();
  for (const s of srcs) {
    const realSrc = join(teleDir, s.key, s.file);
    if (!existsSync(realSrc)) { audit.skipped.push(s.file); continue; }
    const cols = await peekColumns(realSrc);
    cmdbIdxCache.set(realSrc, cols.indexOf("cmdb_id"));
    const seen = await sliceTelemetry(realSrc, join(planeDir, s.file), s.unit, tStart, tEnd, win.t0, audit);
    if (seen) for (const c of seen) cmdbAll.add(c);
  }

  // 6) topology.json(组件清单 + 说明;Bank 无显式拓扑文件,调用关系从 trace 推断)
  const topo = {
    format_version: 1,
    system: a.system,
    level: "pod",
    components: [...cmdbAll].sort().map((id) => ({ id, kind: kindOf(id) })),
    edges: [],
    note: "组件清单由窗口内遥测 cmdb_id 汇总;调用关系请从 plane/trace_span.csv 的 parent_id/span_id/trace_id 推断(OpenRCA Bank 为 pod 级平面数据)",
  };
  writeFileSync(join(planeDir, "topology.json"), JSON.stringify(topo, null, 2) + "\n", "utf8");

  // 7) case.json(R4:instruction 原文为 symptom;scoring_points/record 不进)
  const caseId = basename(a.out.replace(/[\\/]+$/, ""));
  const caseJson = {
    format_version: 1,
    case_id: caseId,
    tier: "l2-openrca",
    title: `${a.system} ${a.task} root cause localization`,
    source: { repo: "github.com/microsoft/OpenRCA", original_id: `${a.system}/${a.task}` },
    symptom: `${q.instruction}\n\n观测面说明:plane/ 为静态快照,时间列已归一为相对 T0 的秒数(T0 = 症状窗口起点 ${win.date} ${win.start} UTC+8,症状窗口 ${win.start}~${win.end};负值 = 窗口起点前)。文件为百 MB 级平面遥测,请用 grep 按组件名(cmdb_id)/时间范围按需查询,不要整读。时间粒度:log/trace 秒级事件,metric 分钟级采样。`,
    topology_entry: "plane/topology.json",
    plane_manifest: [
      { file: "plane/topology.json", desc: "组件清单(cmdb_id)与拓扑说明" },
      { file: "plane/metric_container.csv", desc: "组件级 KPI:timestamp(相对秒), cmdb_id, kpi_name, value" },
      { file: "plane/metric_app.csv", desc: "应用级 KPI:timestamp(相对秒), rr, sr, cnt, mrt, tc(服务)" },
      { file: "plane/log_service.csv", desc: "服务日志:timestamp(相对秒), cmdb_id, log_name, value(事件内容)" },
      { file: "plane/trace_span.csv", desc: "调用链 span:timestamp(相对秒), cmdb_id, parent_id, span_id, trace_id, duration(ms)" },
    ].filter((m) => existsSync(join(a.out, m.file))),
    answer_ref: `analysis/scoring/answers.jsonl#${caseId}`,
    conversion: {
      tool: "tools/convert-openrca.mjs", rule_version: RULE_VERSION,
      audit: `task=${a.task}; 窗口=[T0-${ADAPTER.windowBeforeSec / 60}min, T0+${ADAPTER.windowAfterSec / 60}min];切片 ${audit.sliced.map((s) => `${s.file}:${s.kept}/${s.total}`).join("; ")};组件名保留(R2 审计:平面数据非答案线索,评分要素);query/record/scoring_points 未进 plane(R4)`,
      regen: `node tools/convert-openrca.mjs --openrca --system ${a.system} --task ${a.task}${a.range ? ` --range ${a.range}` : ""} --data ${a.data} --out ${a.out}`,
    },
  };
  writeFileSync(join(a.out, "case.json"), JSON.stringify(caseJson, null, 2) + "\n", "utf8");

  // 8) R4 落地复检:结构化文件不得含真值(component+reason 组合)
  const truthLeak = [];
  for (const r of records) {
    const pat = new RegExp(`${escapeRe(r.component)}.*${escapeRe(r.reason)}`, "i");
    for (const f of ["plane/topology.json", "case.json"]) {
      if (pat.test(readFileSync(join(a.out, f), "utf8"))) truthLeak.push(`${f}: ${r.component}+${r.reason}`);
    }
  }

  // 9) answers 行 + registry 行(stdout 交流程合入 answers.jsonl / registry.jsonl)
  const answersLine = {
    case_id: caseId,
    root_cause: records.map((r) => `${r.component} ${r.reason} @ ${r.datetime} UTC+8`).join("; "),
    root_cause_rel_epoch_sec: records.map((r) => `T+${Math.round((Date.parse(`${r.datetime.replace(" ", "T")}${ADAPTER.tzOffset}`) - win.t0) / 1000)}s`).join(", "),
    verdict_keywords: [...new Set(records.flatMap((r) => [r.component, ...r.reason.split(/\s+/).filter((w) => w.length > 3)]))],
    reject_keywords: [],
    key_evidence_hint: [
      `plane/metric_container.csv 中 ${records[0].component} 的 KPI 在真值相对时刻(${records.length === 1 ? "见 root_cause_rel_epoch_sec" : "各真值时刻"})前后异常`,
      "plane/log_service.csv 同组件异常日志事件",
      "对照:其他组件同时刻 KPI 平稳(排除全局性故障)",
    ],
    notes: `时刻判定容差 ±90s(结论相对秒与真值差 ≤90);机械判定以 component+reason 关键词命中为主(≥2 命中=located);${truthLeak.length ? "⚠️ 真值泄漏:" + truthLeak.join("; ") : "R4 复检通过"}`,
    format_version: 1,
  };
  const registryLine = {
    case_id: caseId, tier: "l2-openrca", dir: `cases/l2-openrca/${caseId}`,
    source: "github.com/microsoft/OpenRCA(Google Drive telemetry)", source_ref: `datasets/OpenRCA-data/${a.system} ${a.task}`,
    conversion: { tool: "tools/convert-openrca.mjs", rule_version: RULE_VERSION, audit_summary: caseJson.conversion.audit, leak_check: truthLeak.length ? "FAIL" : "pass" },
    answer_ref: `analysis/scoring/answers.jsonl#${caseId}`,
    registered_at: new Date().toISOString().slice(0, 10), format_version: 1,
  };
  console.log(JSON.stringify(answersLine));
  console.log(JSON.stringify(registryLine));
  if (a.audit) {
    mkdirSync(join(LAB_ROOT, "analysis", "audits"), { recursive: true });
    writeFileSync(join(LAB_ROOT, "analysis", "audits", `convert-${caseId}.json`), JSON.stringify(audit, null, 2) + "\n", "utf8");
  }
  console.error(`[ok] ${caseId}: ${audit.sliced.length} plane files, 窗口 [T0-60min, T0+40min], R4 复检 ${truthLeak.length ? "发现泄漏!" : "通过"}`);
  if (truthLeak.length) process.exit(2);
}

function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
function kindOf(id) {
  if (/^mysql/i.test(id)) return "database";
  if (/^redis/i.test(id)) return "cache";
  if (/^tomcat/i.test(id)) return "app-server";
  if (/^docker/i.test(id)) return "container";
  if (/^gw/i.test(id)) return "gateway";
  if (/^service/i.test(id)) return "service";
  return "unknown";
}

main().catch((e) => fail(e.stack || e.message));

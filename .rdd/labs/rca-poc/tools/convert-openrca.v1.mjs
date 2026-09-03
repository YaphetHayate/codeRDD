#!/usr/bin/env node
// convert-openrca.mjs — L2 观测面改装脚本(改装规则 = 可审代码)
//
// 权威规则(design/rca-investigation-poc-cto.md 技术方案「改装规则」):
//   R1 时间戳归一:绝对时间 → 相对 T-0(症状爆发 = 0,单位分钟)
//   R2 主机/实例名中性化:同案例内映射一致(host-01/inst-02/…),拓扑关系不变
//   R3 仅取事件前窗口遥测 + 系统拓扑(默认 [T-60, T+10],可 --window 覆盖)
//   R4 根因标注/修复记录/事后分析一律不进 plane(文件名+内容双向扫描)
//   R5 指标与日志名保留(合法调查信号)
//
// 结构适配(adapter)声明:
//   OpenRCA 数据集内部结构以 pilot 首跑实际观察为准(设计决策 #10:单案例 pilot 先行)。
//   ADAPTER_CALIBRATED=false 时,遇到结构不符将**诚实失败**并输出结构诊断,
//   校准点全部集中在下方 ADAPTER 常量区,校准后将 RULE_VERSION +1 并置 true。
//
// 用法:
//   node tools/convert-openrca.mjs --case datasets/OpenRCA/<case-dir> --out cases/l2-openrca/openrca-<id>
//   node tools/convert-openrca.mjs --case ... --out ... --window -120:15 --audit
//   node tools/convert-openrca.mjs --probe datasets/OpenRCA/<case-dir>   # 仅探测结构,不写文件

import { readdirSync, readFileSync, writeFileSync, mkdirSync, statSync, existsSync } from "node:fs";
import { join, relative, basename, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// 实验根 = 本脚本上级目录(rca-poc/),输出产物一律锚定于此,不依赖 cwd
const LAB_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

// ---------- 规则版本 ----------
const RULE_VERSION = 1;
const ADAPTER_CALIBRATED = false; // pilot 校准前置 false:结构断言失败 = 诚实失败 + 诊断

// ---------- ADAPTER 常量区(pilot 校准点,集中于此) ----------
const ADAPTER = {
  // 案例元数据文件:症状描述 + 症状爆发时间(T0)来源
  metaCandidates: ["incident.json", "case.json", "metadata.json", "incident.yaml", "meta.json"],
  // 症状爆发时间字段名(按序探测,首个命中者为准)
  t0Fields: ["incident_start", "start_time", "detect_time", "detected_at", "startTime", "onset"],
  // 症状文本字段名
  symptomFields: ["description", "incident_description", "summary", "symptom", "title"],
  // 遥测文件目录候选
  telemetryDirs: ["telemetry", "data", "metrics", "logs", "artifacts"],
  // 拓扑文件候选
  topologyCandidates: ["topology.json", "topology.yaml", "service_topology.json"],
};

// R4 敏感剔除词(文件名与内容双向)
const SENSITIVE_PATTERNS = [
  /root[\s_-]?cause/i, /resolution/i, /post[\s_-]?mortem/i, /postmortem/i,
  /\brca\b/i, /remediation/i, /fix[\s_-]?record/i, /fault[\s_-]?inject/i,
  /ground[\s_-]?truth/i, /answer/i, /label/i, /mitigation/i, /aftermath/i,
];
// R5 保留的合法信号文件扩展名
const KEEP_EXTS = new Set([".json", ".jsonl", ".csv", ".log", ".txt", ".yaml", ".yml"]);

// R2 中性化:可审的正则捕获集(具体形态在前,宽泛形态在后;命中者替换为中性名,案例内一致)
const ENTITY_PATTERNS = [
  /\b[a-z]{2,8}-\d{2,4}-[a-z0-9]{3,}/gi, // 云资源 ID 形态,如 vm-0231-a9f3 / service-451-alpha(整体)
  /(?:vm|node|host|machine|server|inst|instance|pod|svc|service)[-_.]?(\d{1,4})/gi,
];
// 时间列/字段识别
const TIME_KEYS = [/^t(ime)?$/i, /^time.?stamp/i, /^ts$/i, /_at$/i, /^date/i, /^minute/i, /^second/i];

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--case") args.case = argv[++i];
    else if (a === "--out") args.out = argv[++i];
    else if (a === "--window") args.window = argv[++i];
    else if (a === "--audit") args.audit = true;
    else if (a === "--probe") args.probe = true;
    else args._.push(a);
  }
  return args;
}

function fail(msg) {
  console.error(`[convert-openrca] FAIL: ${msg}`);
  process.exit(1);
}

function walk(dir, base = dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...walk(p, base));
    else out.push({ path: p, rel: relative(base, p).split("\\").join("/"), size: st.size });
  }
  return out;
}

// 找到案例元数据文件
function findMeta(caseDir) {
  const files = walk(caseDir);
  for (const cand of ADAPTER.metaCandidates) {
    const hit = files.find((f) => f.rel === cand || f.rel.endsWith("/" + cand));
    if (hit) return { meta: hit, files };
  }
  return { meta: null, files };
}

// 从元数据 JSON 提取 T0 与症状文本(浅层 + 一层嵌套探测)
function extractMeta(rawJson) {
  const get = (obj, fields) => {
    for (const f of fields) {
      if (obj && obj[f] != null && obj[f] !== "") return obj[f];
    }
    return null;
  };
  let t0 = get(rawJson, ADAPTER.t0Fields);
  let symptom = get(rawJson, ADAPTER.symptomFields);
  if ((!t0 || !symptom) && typeof rawJson === "object") {
    for (const k of Object.keys(rawJson || {})) {
      if (rawJson[k] && typeof rawJson[k] === "object" && !Array.isArray(rawJson[k])) {
        t0 = t0 || get(rawJson[k], ADAPTER.t0Fields);
        symptom = symptom || get(rawJson[k], ADAPTER.symptomFields);
      }
    }
  }
  return { t0, symptom };
}

// R1 时间解析(尽力而为:ISO/Unix 秒/毫秒)
function parseTime(v) {
  if (v == null) return null;
  if (/^-?\d{10,13}$/.test(String(v).trim())) {
    const n = Number(v);
    return new Date(String(v).length >= 13 ? n : n * 1000);
  }
  const d = new Date(v);
  return isNaN(d.getTime()) ? null : d;
}

// R2 中性化器:案例内一致映射。
// 两遍占位符法:pass1 把各 pattern 的命中替换为不可见占位符(\0N\0,纯数字,任何实体 pattern 均不会再匹配),
// pass2 占位符 → 中性名——避免前一个 pattern 产出的中性名被后一个 pattern 二次匹配(自测发现的交叉替换 bug)。
function makeNeutralizer() {
  const map = new Map();
  return {
    neutralize(text) {
      let out = text;
      const slots = [];
      for (const re of ENTITY_PATTERNS) {
        out = out.replace(re, (m) => {
          if (!map.has(m)) map.set(m, `neut-entity-${String(map.size + 1).padStart(2, "0")}`);
          slots.push(map.get(m));
          return `\u0000${slots.length - 1}\u0000`;
        });
      }
      return out.replace(/\u0000(\d+)\u0000/g, (_, i) => slots[Number(i)]);
    },
    mapping: map,
  };
}

function isTimeKey(key) {
  return TIME_KEYS.some((re) => re.test(key));
}

// R1+R2+R4 对单文件内容转换;返回 {ok, content, skipped, reason}
function convertContent(rel, text, t0, neutralizer, windowMin, audit) {
  const low = rel.toLowerCase();
  if (SENSITIVE_PATTERNS.some((re) => re.test(low))) {
    return { skipped: true, reason: "R4: 文件名命中敏感词" };
  }
  if (SENSITIVE_PATTERNS.some((re) => re.test(text.slice(0, 4000)))) {
    // 仅扫描头部 4KB:根因标注通常在文档头;正文偶词不误杀遥测数字
    return { skipped: true, reason: "R4: 文件内容头部命中敏感词" };
  }
  const ext = extname(rel).toLowerCase();
  if (!KEEP_EXTS.has(ext)) return { skipped: true, reason: "扩展名不在保留清单" };

  let converted = text;
  let timeConversions = 0;

  if (ext === ".json" || ext === ".jsonl") {
    try {
      const lines = ext === ".jsonl" ? text.split(/\r?\n/).filter(Boolean) : [text];
      const outLines = lines.map((line) => {
        let obj;
        try { obj = JSON.parse(line); } catch { return line; }
        const conv = (o) => {
          if (!o || typeof o !== "object") return o;
          for (const k of Object.keys(o)) {
            if (isTimeKey(k) && t0) {
              const d = parseTime(o[k]);
              if (d) { o[k] = Math.round((d.getTime() - t0.getTime()) / 60000); timeConversions++; }
            } else if (typeof o[k] === "string") {
              o[k] = neutralizer.neutralize(o[k]);
            } else if (o[k] && typeof o[k] === "object") {
              conv(o[k]);
            }
          }
          return o;
        };
        return JSON.stringify(conv(obj));
      });
      converted = outLines.join("\n");
    } catch { /* 非法 JSON 原样保留(仅中性化) */ }
    converted = neutralizer.neutralize(converted);
  } else {
    // CSV / LOG / TXT:按行处理
    const outLines = [];
    let timeColIdx = [];
    const srcLines = text.split(/\r?\n/);
    for (let li = 0; li < srcLines.length; li++) {
      const line = srcLines[li];
      if (line.trim() === "" || line.trimStart().startsWith("#")) { outLines.push(neutralizer.neutralize(line)); continue; }
      const isCsv = ext === ".csv";
      if (isCsv && li === 0) {
        const header = line.split(",");
        timeColIdx = header.map((h, i) => (isTimeKey(h.trim()) ? i : -1)).filter((i) => i >= 0);
        outLines.push(neutralizer.neutralize(line));
        continue;
      }
      if (isCsv && timeColIdx.length && t0) {
        const cols = line.split(",");
        for (const ci of timeColIdx) {
          const d = parseTime(cols[ci]);
          if (d) { cols[ci] = String(Math.round((d.getTime() - t0.getTime()) / 60000)); timeConversions++; }
        }
        outLines.push(neutralizer.neutralize(cols.join(",")));
      } else {
        // 日志:常见 "ts=... " / 行首时间戳
        let l = line;
        if (t0) {
          l = l.replace(/(\d{4}-\d{2}-\d{2}[T ][\d:.]+Z?)/g, (m) => {
            const d = parseTime(m);
            if (!d) return m;
            timeConversions++;
            return `t=${Math.round((d.getTime() - t0.getTime()) / 60000)}min`;
          });
        }
        outLines.push(neutralizer.neutralize(l));
      }
    }
    converted = outLines.join("\n");
  }

  return { skipped: false, content: converted, timeConversions };
}

// R3 窗口过滤(对已归一化 t 值的 json/csv 行;保守跳过无法判定的行,不误删)
function inWindow(line, win) {
  const m = line.match(/(?:^|[,{"\s])(?:t(?:ime|imeStamp|imestamp)?|minute|ts)["\s:=]+(-?\d+(?:\.\d+)?)/i);
  if (!m) return true;
  const v = Number(m[1]);
  return v >= win[0] && v <= win[1];
}

function probe(caseDir) {
  const { meta, files } = findMeta(caseDir);
  console.log(JSON.stringify({
    adapter_calibrated: ADAPTER_CALIBRATED,
    rule_version: RULE_VERSION,
    meta_file: meta ? meta.rel : null,
    file_count: files.length,
    top_level: [...new Set(files.map((f) => f.rel.split("/")[0]))].slice(0, 30),
    candidates: {
      telemetry_dirs_found: ADAPTER.telemetryDirs.filter((d) => files.some((f) => f.rel.startsWith(d + "/"))),
      topology_found: ADAPTER.topologyCandidates.filter((c) => files.some((f) => f.rel.endsWith(c))),
    },
  }, null, 2));
}

function main() {
  const args = parseArgs(process.argv);
  if (args.probe) {
    const target = args.case || args._[0];
    if (!target) fail("--probe 需要 --case <目录>(或 --probe <目录>)");
    probe(target);
    return;
  }
  if (!args.case || !args.out) fail("用法: --case <OpenRCA案例目录> --out <输出案例目录> [--window -60:10] [--audit]");

  const win = (args.window || "-60:10").split(":").map(Number);
  if (win.length !== 2 || win.some(isNaN)) fail("--window 格式: -60:10");

  const { meta, files } = findMeta(args.case);
  if (!meta) {
    fail(`未找到案例元数据(期望其一: ${ADAPTER.metaCandidates.join(", ")})。` +
      (ADAPTER_CALIBRATED ? "" : "ADAPTER_CALIBRATED=false:请先 --probe 观察实际结构,校准 ADAPTER 常量区(见文件头注释)。"));
  }

  let rawMeta = {};
  try { rawMeta = JSON.parse(readFileSync(meta.path, "utf8")); }
  catch { fail(`元数据不是合法 JSON: ${meta.rel}`); }

  const { t0, symptom } = extractMeta(rawMeta);
  if (!symptom) fail("元数据中未找到症状文本字段(候选: " + ADAPTER.symptomFields.join(", ") + ")——需校准 adapter。");
  const t0Date = parseTime(t0);
  if (!t0Date) fail("元数据中未找到可解析的症状爆发时间(候选: " + ADAPTER.t0Fields.join(", ") + ")——需校准 adapter(R1 依赖 T0)。");

  const neutralizer = makeNeutralizer();
  const caseId = basename(args.out.replace(/[\\/]+$/, ""));
  const audit = { rule_version: RULE_VERSION, case_id: caseId, t0_source: String(t0), window_min: win, converted: [], skipped: [], entity_map_size: 0, time_conversions: 0 };
  const planeFiles = [];

  for (const f of files) {
    if (f.rel === meta.rel) continue;
    let text;
    try { text = readFileSync(f.path, "utf8"); } catch { audit.skipped.push({ file: f.rel, reason: "不可读(非 UTF-8?)" }); continue; }
    const r = convertContent(f.rel, text, t0Date, neutralizer, win, audit);
    if (r.skipped) { audit.skipped.push({ file: f.rel, reason: r.reason }); continue; }
    const lines = r.content.split(/\r?\n/);
    const filtered = lines.filter((l) => inWindow(l, win));
    if (filtered.length === 0) { audit.skipped.push({ file: f.rel, reason: `R3: 窗口过滤后为空 [${win[0]},${win[1]}]` }); continue; }
    const outRel = join(args.out, "plane", f.rel);
    mkdirSync(dirname(outRel), { recursive: true });
    writeFileSync(outRel, filtered.join("\n") + "\n", "utf8");
    audit.converted.push({ file: "plane/" + f.rel, lines_kept: filtered.length, lines_total: lines.length, time_conversions: r.timeConversions || 0 });
    audit.time_conversions += r.timeConversions || 0;
    planeFiles.push("plane/" + f.rel);
  }

  if (planeFiles.length === 0) fail("改装后 plane 为空——R4 剔除或 R3 窗口过滤过猛,请检查审计输出(信号阉割风险,决策 #10 回退:扩窗口)。");

  audit.entity_map_size = neutralizer.mapping.size;

  const caseJson = {
    format_version: 1,
    case_id: caseId,
    tier: "l2-openrca",
    title: neutralizer.neutralize(String(rawJsonTitle(rawMeta) || caseId)),
    source: { repo: "github.com/microsoft/OpenRCA", original_id: caseId },
    symptom: "T0 为症状爆发时刻。" + neutralizer.neutralize(String(symptom)),
    topology_entry: null,
    plane_manifest: planeFiles.map((p) => ({ file: p, desc: "改装自 OpenRCA 原始遥测(时间已归一为相对 T0 分钟偏移,实体名已中性化)" })),
    answer_ref: `analysis/scoring/answers.jsonl#${caseId}`,
    conversion: {
      tool: "tools/convert-openrca.mjs",
      rule_version: RULE_VERSION,
      audit: `t0=${t0}; window=[${win[0]},${win[1]}]min; converted=${audit.converted.length} skipped=${audit.skipped.length}; 实体中性化映射 ${audit.entity_map_size} 项;时间转换 ${audit.time_conversions} 处`,
    },
  };
  const topo = planeFiles.find((p) => ADAPTER.topologyCandidates.some((c) => p.endsWith(c)));
  if (topo) caseJson.topology_entry = topo;
  writeFileSync(join(args.out, "case.json"), JSON.stringify(caseJson, null, 2) + "\n", "utf8");

  // registry 行与审计文件由调用方(prompt 指示的 pilot 操作者)合入;此处输出到 stdout + analysis
  const registryLine = JSON.stringify({
    case_id: caseId, tier: "l2-openrca", dir: relative(LAB_ROOT, args.out).split("\\").join("/"),
    source: "github.com/microsoft/OpenRCA", source_ref: relative(LAB_ROOT, args.case).split("\\").join("/"),
    conversion: { tool: "tools/convert-openrca.mjs", rule_version: RULE_VERSION, audit_summary: caseJson.conversion.audit, leak_check: "pending-pilot" },
    answer_ref: caseJson.answer_ref, registered_at: new Date().toISOString().slice(0, 10), format_version: 1,
  });
  console.log(registryLine);
  if (args.audit) {
    mkdirSync(join(LAB_ROOT, "analysis", "audits"), { recursive: true });
    writeFileSync(join(LAB_ROOT, "analysis", "audits", `convert-${caseId}.json`), JSON.stringify(audit, null, 2) + "\n", "utf8");
    console.error(`[audit] analysis/audits/convert-${caseId}.json`);
  }
  console.error(`[ok] ${planeFiles.length} plane files → ${args.out}(R1 时间转换 ${audit.time_conversions} 处,R2 中性化 ${audit.entity_map_size} 实体,R4 剔除 ${audit.skipped.length} 文件)`);
}

function rawJsonTitle(rawMeta) {
  return rawMeta && (rawMeta.title || rawMeta.name || rawMeta.incident_id || "");
}

main();

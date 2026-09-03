#!/usr/bin/env node
// score.mjs — 对托管答案评分 + 两臂汇总
//
// 职责(design 变更地图 + 验收 2/3):
//   --preflight <case-dir>   案例就绪预检(goal 创建前必须通过,决策 #8)
//   --run <run-dir>          单 run 评分:定位判定 + 证据链完整性 + confidence 范围复算(决策 #9 终检)
//   --all                    汇总 runs/ 全部 run → analysis/scoring/summary.json + summary.md(两臂对照)
//
// 评分口径:机械判定为主(verdict_keywords 命中 / reject_keywords 误归因 / final_state 语义),
// 语义灰区输出 needs_human_review=true 交人工复核(不冒充语义智能)。
// 答案来源:analysis/scoring/answers.jsonl(托管,结构性隔离,本脚本唯一读者)。

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { join, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const LAB_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--preflight") args.preflight = argv[++i];
    else if (a === "--run") args.run = argv[++i];
    else if (a === "--all") args.all = true;
  }
  return args;
}

function readJson(p) { return JSON.parse(readFileSync(p, "utf8")); }
function readJsonl(p) {
  return readFileSync(p, "utf8").split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l));
}
function fail(msg, code = 1) { console.error(`[score] FAIL: ${msg}`); process.exit(code); }

function loadAnswers() {
  const p = join(LAB_ROOT, "analysis", "scoring", "answers.jsonl");
  if (!existsSync(p)) fail("托管答案缺失: analysis/scoring/answers.jsonl");
  const map = new Map();
  for (const a of readJsonl(p)) map.set(a.case_id, a);
  return map;
}

// ---------- --preflight ----------
function preflight(caseDir) {
  const problems = [];
  const caseJsonPath = join(caseDir, "case.json");
  if (!existsSync(caseJsonPath)) { console.log(JSON.stringify({ ok: false, problems: ["case.json 缺失"] }, null, 2)); process.exit(1); }
  let c;
  try { c = readJson(caseJsonPath); } catch (e) { console.log(JSON.stringify({ ok: false, problems: [`case.json 非法 JSON: ${e.message}`] })); process.exit(1); }

  for (const f of ["format_version", "case_id", "tier", "symptom", "plane_manifest", "answer_ref"]) {
    if (c[f] == null) problems.push(`case.json 缺字段: ${f}`);
  }
  // plane 文件存在性
  const missing = [];
  for (const m of c.plane_manifest || []) {
    if (!existsSync(join(caseDir, m.file))) missing.push(m.file);
  }
  if (missing.length) problems.push(`plane 文件缺失: ${missing.join(", ")}`);
  if (!existsSync(join(caseDir, "plane"))) problems.push("plane/ 目录缺失");
  // 答案托管存在性
  const answers = loadAnswers();
  if (!answers.has(c.case_id)) problems.push(`托管答案缺失: ${c.answer_ref}(answers.jsonl 中无 ${c.case_id})`);
  // 泄漏粗检:案例目录文本中不得出现敏感标注
  const sensitive = [/root[\s_-]?cause/i, /ground[\s_-]?truth/i, /post[\s_-]?mortem/i];
  const leakHits = [];
  const walkFiles = (d) => {
    for (const name of readdirSync(d)) {
      const p = join(d, name);
      if (/answer|solution/.test(name)) continue;
      let txt = "";
      try { txt = readFileSync(p, "utf8").slice(0, 8000); } catch { continue; }
      if (sensitive.some((re) => re.test(txt)) && name !== "case.json") leakHits.push(name);
    }
  };
  if (existsSync(join(caseDir, "plane"))) walkFiles(join(caseDir, "plane"));

  const ok = problems.length === 0;
  console.log(JSON.stringify({ ok, case_id: c.case_id, plane_files: (c.plane_manifest || []).length, leak_scan_hits: leakHits, problems }, null, 2));
  process.exit(ok ? 0 : 1);
}

// ---------- --run ----------
function scoreRun(runDir, answers) {
  const problems = [];
  const manifestPath = join(runDir, "manifest.json");
  if (!existsSync(manifestPath)) fail(`run 缺 manifest.json: ${runDir}`);
  const manifest = readJson(manifestPath);
  const caseId = manifest.case_id;
  const answer = answers.get(caseId);
  if (!answer) fail(`run ${basename(runDir)} 的案例 ${caseId} 无托管答案`);

  // 状态文件
  const treePath = join(runDir, "state", "hypothesis-tree.json");
  const chainPath = join(runDir, "state", "evidence-chain.jsonl");
  if (!existsSync(treePath)) problems.push("state/hypothesis-tree.json 缺失");
  if (!existsSync(chainPath)) problems.push("state/evidence-chain.jsonl 缺失");
  if (problems.length) return { run_id: basename(runDir), case_id: caseId, arm: manifest.arm, problems };

  const tree = readJson(treePath);
  const chain = existsSync(chainPath) ? readJsonl(chainPath) : [];
  const evidById = new Map(chain.map((e) => [e.id, e]));

  // 1) 定位判定:final-report 结论文本 vs 关键词口径
  const reportPath = join(runDir, "report", "final-report.md");
  let verdict = "no_report";
  let reportText = "";
  let hit = [], rejectHit = [];
  if (existsSync(reportPath)) {
    reportText = readFileSync(reportPath, "utf8");
    const conclusionZone = extractConclusion(reportText);
    hit = (answer.verdict_keywords || []).filter((k) => conclusionZone.toLowerCase().includes(k.toLowerCase()));
    rejectHit = (answer.reject_keywords || []).filter((k) => conclusionZone.toLowerCase().includes(k.toLowerCase()));
    if (manifest.final_state === "hypothesis_space_exhausted") verdict = "escalated";
    else if (manifest.final_state === "budget_exhausted") verdict = "budget_exhausted";
    else if (manifest.final_state === "root_cause_concluded") {
      // 关键词口径:≥2 verdict 命中且 0 reject 命中 → located;1 命中 → needs_human_review;reject 命中 → misattributed
      if (rejectHit.length > 0) verdict = "misattributed";
      else if (hit.length >= 2) verdict = "located";
      else if (hit.length === 1) verdict = "located_needs_review";
      else verdict = "missed";
    } else verdict = "incomplete";
  }

  // 2) 证据链完整性:每个 pruned/concluded 节点有 evidence 引用;引用文件存在于 plane
  const tier = tree.tier || tierFromCaseId(caseId);
  const caseDir = join(LAB_ROOT, "cases", tier, caseId);
  const unsupportedNodes = [];
  const danglingCitations = [];
  for (const n of tree.nodes || []) {
    if ((n.status === "pruned" || n.status === "concluded") && (!n.evidence_ids || n.evidence_ids.length === 0)) {
      unsupportedNodes.push(n.id);
    }
  }
  for (const e of chain) {
    for (const c of e.citations || []) {
      if (!c.file || !c.locator) danglingCitations.push(`${e.id}:citation 无 file/locator`);
      else if (!existsSync(join(caseDir, c.file))) danglingCitations.push(`${e.id} 引用不存在文件 ${c.file}`);
    }
  }

  // 3) confidence 范围复算(决策 #9 机器化终检)
  const rangeViolations = [];
  for (const e of chain) {
    if (typeof e.confidence !== "number" || e.confidence < 0 || e.confidence > 1) rangeViolations.push(`${e.id}: confidence=${e.confidence}`);
  }
  for (const n of tree.nodes || []) {
    if (n.confidence != null && (typeof n.confidence !== "number" || n.confidence < 0 || n.confidence > 1)) rangeViolations.push(`node ${n.id}: confidence=${n.confidence}`);
  }

  // 4) causal 支撑检查:结论节点至少一条 causal 证据
  const causalGaps = [];
  const concluded = (tree.nodes || []).filter((n) => n.status === "concluded");
  for (const n of concluded) {
    const hasCausal = (n.evidence_ids || []).some((id) => evidById.get(id) && evidById.get(id).type === "causal");
    if (!hasCausal) causalGaps.push(n.id);
  }

  const result = {
    run_id: basename(runDir),
    case_id: caseId,
    arm: manifest.arm,
    final_state: manifest.final_state,
    truth_component: (answer && answer.verdict_keywords && answer.verdict_keywords[0]) || null,
    verdict,
    verdict_keywords_hit: hit,
    reject_keywords_hit: rejectHit,
    rounds_used: (tree.updated_round != null ? tree.updated_round : null),
    evidence_count: chain.length,
    correlational: chain.filter((e) => e.type === "correlational").length,
    causal: chain.filter((e) => e.type === "causal").length,
    chain_integrity: {
      unsupported_prune_or_conclude_nodes: unsupportedNodes,
      dangling_citations: danglingCitations,
    },
    confidence_range_violations: rangeViolations,
    concluded_without_causal: causalGaps,
    needs_human_review: verdict === "located_needs_review" || causalGaps.length > 0,
  };
  if (!problems.length) return result;
  return { ...result, problems };
}

function tierFromCaseId(caseId) {
  if (caseId.startsWith("mock-")) return "l1-mock";
  if (caseId.startsWith("openrca-")) return "l2-openrca";
  if (caseId.startsWith("pm-")) return "l3-postmortem";
  return "l1-mock";
}

// 从 final-report 提取结论文本(根因结论章节;无明确章节则全文,保守)
function extractConclusion(md) {
  const zones = [];
  let capture = false;
  for (const line of md.split(/\r?\n/)) {
    if (/^#{1,3}\s/.test(line)) capture = /根因|结论|root.?cause|conclusion/i.test(line);
    else if (capture) zones.push(line);
  }
  if (zones.length === 0) return md; // 无明确章节 → 全文(保守)
  return zones.join("\n");
}

// ---------- --all ----------
function scoreAll() {
  const answers = loadAnswers();
  const runsDir = join(LAB_ROOT, "runs");
  const runs = existsSync(runsDir) ? readdirSync(runsDir).filter((d) => existsSync(join(runsDir, d, "manifest.json"))) : [];
  const results = [];
  for (const r of runs) {
    try { results.push(scoreRun(join(runsDir, r), answers)); }
    catch (e) { results.push({ run_id: r, verdict: "error", problems: [e.message] }); }
  }

  // 两臂汇总:按案例分组
  const byCase = new Map();
  for (const r of results) {
    if (!byCase.has(r.case_id)) byCase.set(r.case_id, []);
    byCase.get(r.case_id).push(r);
  }
  const located = (r) => r.verdict === "located" || r.verdict === "located_needs_review";
  const isBaseline = (r) => (r.arm || "").startsWith("baseline") || (r.arm || "").startsWith("ralph"); // ralph-baseline 兼容
  const compHit = (r) => {
    // 组件命中:verdict_keywords_hit 含真值组件名(answers.verdict_keywords[0],由 convert 保证组件名居首)
    const comp = r.truth_component;
    return Boolean(comp) && (r.verdict_keywords_hit || []).includes(comp);
  };
  const summary = {
    generated_at: new Date().toISOString(),
    runs_total: results.length,
    by_case: [...byCase.entries()].map(([cid, rs]) => ({
      case_id: cid,
      arms: rs.map((r) => ({ run_id: r.run_id, arm: r.arm, verdict: r.verdict, located: located(r), component_hit: compHit(r), keyword_hits: (r.verdict_keywords_hit || []).length, rounds_used: r.rounds_used, evidence_count: r.evidence_count, causal: r.causal })),
    })),
    orchestrated_located: results.filter((r) => r.arm === "orchestrated" && located(r)).length,
    orchestrated_total: results.filter((r) => r.arm === "orchestrated").length,
    orchestrated_component_hit: results.filter((r) => r.arm === "orchestrated" && compHit(r)).length,
    baseline_located: results.filter((r) => isBaseline(r) && located(r)).length,
    baseline_total: results.filter((r) => isBaseline(r)).length,
    baseline_component_hit: results.filter((r) => isBaseline(r) && compHit(r)).length,
    component_hit_note: "component_hit=结论含真值组件名(独立于结案状态:软结案 escalated 但组件对 vs 硬结案 concluded 但组件错,两臂公平对照维度)",
    paper_reference_note: "论文单体基线为参照口径(模型/提示/预算不同,不并表硬比,双口径落档见 R6)",
  };

  mkdirSync(join(LAB_ROOT, "analysis", "scoring"), { recursive: true });
  for (const r of results) {
    writeFileSync(join(LAB_ROOT, "analysis", "scoring", `${r.run_id}.json`), JSON.stringify(r, null, 2) + "\n", "utf8");
  }
  writeFileSync(join(LAB_ROOT, "analysis", "scoring", "summary.json"), JSON.stringify(summary, null, 2) + "\n", "utf8");

  // summary.md(人类可读,两臂对照表)
  const lines = [];
  lines.push("# 两臂评分汇总");
  lines.push("");
  lines.push(`生成于 ${summary.generated_at};共 ${summary.runs_total} 个 run。verdict 口径:located=≥2 关键词命中且无误归因;located_needs_review=1 命中(需人工复核);misattributed=误归因;escalated=升级人类;missed=结论未命中。`);
  lines.push("");
  lines.push("| 案例 | run | 臂 | verdict | 定位 | 组件命中 | 关键词 | 轮次 | 证据(correlational/causal) |");
  lines.push("|------|-----|----|---------|------|----------|--------|------|------------------------------|");
  for (const c of summary.by_case) {
    for (const a of c.arms) {
      const r = results.find((x) => x.run_id === a.run_id);
      lines.push(`| ${c.case_id} | ${a.run_id} | ${a.arm} | ${a.verdict} | ${a.located ? "✅" : "❌"} | ${a.component_hit ? "✅" : "❌"} | ${a.keyword_hits} | ${a.rounds_used ?? "-"} | ${r.evidence_count}(${r.correlational}/${r.causal}) |`);
    }
  }
  lines.push("");
  lines.push(`**编排臂**:located ${summary.orchestrated_located}/${summary.orchestrated_total},组件命中 ${summary.orchestrated_component_hit}/${summary.orchestrated_total};**基线臂**:located ${summary.baseline_located}/${summary.baseline_total},组件命中 ${summary.baseline_component_hit}/${summary.baseline_total}。`);
  lines.push("");
  lines.push(`> ${summary.paper_reference_note}`);
  writeFileSync(join(LAB_ROOT, "analysis", "scoring", "summary.md"), lines.join("\n") + "\n", "utf8");
  console.log(JSON.stringify(summary, null, 2));
}

function main() {
  const args = parseArgs(process.argv);
  if (args.preflight) return preflight(args.preflight);
  if (args.run) {
    const answers = loadAnswers();
    const r = scoreRun(args.run, answers);
    mkdirSync(join(LAB_ROOT, "analysis", "scoring"), { recursive: true });
    writeFileSync(join(LAB_ROOT, "analysis", "scoring", `${r.run_id}.json`), JSON.stringify(r, null, 2) + "\n", "utf8");
    console.log(JSON.stringify(r, null, 2));
    return;
  }
  if (args.all) return scoreAll();
  fail("用法: --preflight <case-dir> | --run <run-dir> | --all");
}

main();

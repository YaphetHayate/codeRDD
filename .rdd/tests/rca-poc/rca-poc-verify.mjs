#!/usr/bin/env node
// rca-poc-verify.mjs — RCA 调查流 PoC 验收验证器（QA 独立实现,零依赖,不依赖 tools/score.mjs）
//
// 被测对象:.rdd/labs/rca-poc/ 实验目录（假设树驱动 Manager-Worker 调查循环 PoC）
// 用例规约:.rdd/tests/rca-poc/cases.json（TC-001 ~ TC-062,映射需求验收标准 AC-1 ~ AC-7）
//
// 用法:
//   node rca-poc-verify.mjs [--suite all|meta|l1|l2|constraints] [--lab <dir>] [--reset-baseline] [--json]
//
// 套件说明:
//   meta        校验器自检（fixture 植入违规必须逐项检出,好样本零误报）——TC-005/TC-014
//   l1          L1 冒烟机械结构（真实 run 状态三件套/轮次/停止/恢复）——TC-001~004/006
//   l2          L2 能力验证（OpenRCA 改装/定位复算/证据链/对照/归因）——TC-011~016/021~023/031
//   constraints 约束门禁（归属判据报告/格式稳定/confinement/只读边界）——TC-041~042/051~052/061~062
//   all         全部（严格验收口径:L2 产物缺失即 FAIL）
//
// 严重度语义:P0 失败=阻塞（退出码 1）;P1 失败=严重不阻塞;P2=备忘警告。
// 退出码:0=无 P0 失败;1=存在 P0 失败;2=验证器自身错误。

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, basename, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "..", "..", "..");
const DEFAULT_LAB = join(REPO_ROOT, ".rdd", "labs", "rca-poc");
const RESULTS_PATH = join(SCRIPT_DIR, "results.json");
const BASELINE_PATH = join(SCRIPT_DIR, "confinement-baseline.json");
const FIXTURES_DIR = join(SCRIPT_DIR, "fixtures");

// ---------- 契约枚举（来源:需求验收标准 + 实验目录 README 状态契约） ----------
const NODE_STATUS = ["pending", "supported", "pruned", "concluded"];
const EV_TYPE = ["correlational", "causal"];
const EV_VERDICT = ["support", "refute", "inconclusive"];
const ARMS = ["orchestrated", "baseline"];
const FINAL_STATES = ["root_cause_concluded", "budget_exhausted", "hypothesis_space_exhausted"];
const VERDICTS = ["located", "located_needs_review", "misattributed", "escalated", "budget_exhausted", "missed", "no_report", "incomplete"];

// confinement 基线:受保护路径（PoC 禁改）与允许新增产物的根
const PROTECTED_ROOTS = [
  "rdd-engine", "dsh", "src", "scripts", "bin", "dist",
  "rdd-pm", "rdd-cto", "rdd-dev", "rdd-qa", "rdd-pse", "rdd-ux", "rdd-eval",
  ".claude", ".zcode",
];
const PROTECTED_FILES = [
  "package.json", "package-lock.json", "tsconfig.json", "install.ps1", "README.md", ".gitignore", "LICENSE",
];
const ALLOWED_NEW_PREFIXES = [".rdd/labs/", ".rdd/tests/", ".rdd/exploration/", ".rdd/changes/", ".rdd/tmp/", ".rdd/handoff/"];
const WALK_SKIP_DIRS = new Set([".git", "node_modules"]);
// 外部素材克隆,允许根内,不进基线(rel 路径统一为正斜杠比较)
const WALK_SKIP_SUBTREES = [".rdd/labs/rca-poc/datasets"];

// ---------- 小工具 ----------
function readJson(p) { return JSON.parse(readFileSync(p, "utf8")); }
function readJsonl(p) {
  return readFileSync(p, "utf8").split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l));
}
function pad2(n) { return String(n).padStart(2, "0"); }
function tierFromCaseId(caseId) {
  if (caseId.startsWith("mock-")) return "l1-mock";
  if (caseId.startsWith("openrca-")) return "l2-openrca";
  if (caseId.startsWith("pm-")) return "l3-postmortem";
  return "l1-mock";
}

// ---------- run 装载 ----------
function loadRun(runDir) {
  const run = { id: basename(runDir), dir: runDir, ioProblems: [] };
  const need = [
    ["manifest.json", "manifest"],
    ["state/hypothesis-tree.json", "tree"],
    ["state/evidence-chain.jsonl", "chain"],
    ["state/round-log.jsonl", "rounds"],
  ];
  for (const [rel, key] of need) {
    const p = join(runDir, rel);
    if (!existsSync(p)) { run.ioProblems.push(`缺失 ${rel}`); continue; }
    try {
      run[key] = rel.endsWith(".jsonl") ? readJsonl(p) : readJson(p);
    } catch (e) {
      run.ioProblems.push(`${rel} 解析失败: ${e.message}`);
    }
  }
  run.reportExists = existsSync(join(runDir, "report", "final-report.md"));
  run.reportText = run.reportExists ? readFileSync(join(runDir, "report", "final-report.md"), "utf8") : "";
  return run;
}

function caseDirFor(lab, manifest) {
  const tier = manifest?.case_tier || (manifest?.case_id ? tierFromCaseId(manifest.case_id) : "l1-mock");
  return join(lab, "cases", tier, manifest.case_id);
}
function loadCaseJson(lab, manifest) {
  const p = join(caseDirFor(lab, manifest), "case.json");
  if (!existsSync(p)) return null;
  try { return readJson(p); } catch { return null; }
}

// ---------- 结构校验(规则编号即 fixture expected-findings 契约) ----------
// 返回 problems: [{rule, run, msg}]
function validateRun(run, caseJson) {
  const P = (rule, msg) => ({ rule, run: run.id, msg });
  const problems = [];
  for (const io of run.ioProblems) problems.push(P("R-RUN-READ", io));
  const m = run.manifest, t = run.tree, chain = run.chain || [], rounds = run.rounds || [];

  // R-MANIFEST-ENUM — manifest 契约
  if (m) {
    if (!ARMS.includes(m.arm)) problems.push(P("R-MANIFEST-ENUM", `arm 非法: ${m.arm}`));
    if (!FINAL_STATES.includes(m.final_state)) problems.push(P("R-MANIFEST-ENUM", `final_state 非法: ${m.final_state}`));
    const b = m.budget || {};
    if (!Number.isInteger(b.max_rounds) || b.max_rounds < 1) problems.push(P("R-MANIFEST-ENUM", `budget.max_rounds 非法: ${b.max_rounds}`));
    if (!(b.confidence_stop > 0 && b.confidence_stop <= 1)) problems.push(P("R-MANIFEST-ENUM", `budget.confidence_stop 非法: ${b.confidence_stop}`));
    if (!(b.verify_prune_prior >= 0 && b.verify_prune_prior <= 1)) problems.push(P("R-MANIFEST-ENUM", `budget.verify_prune_prior 非法: ${b.verify_prune_prior}`));
  }

  // R-TREE-SCHEMA — 假设树 schema
  if (t) {
    if (typeof t.format_version !== "number") problems.push(P("R-TREE-SCHEMA", "tree.format_version 非数字"));
    if (m && t.case_id !== m.case_id) problems.push(P("R-TREE-SCHEMA", `tree.case_id(${t.case_id}) ≠ manifest.case_id(${m.case_id})`));
    const nodes = t.nodes || [];
    if (!Array.isArray(nodes) || nodes.length === 0) problems.push(P("R-TREE-SCHEMA", "nodes 为空"));
    const ids = new Set(nodes.map((n) => n.id));
    if (ids.size !== nodes.length) problems.push(P("R-TREE-SCHEMA", "node id 重复"));
    for (const n of nodes) {
      if (!NODE_STATUS.includes(n.status)) problems.push(P("R-TREE-SCHEMA", `node ${n.id} status 非法: ${n.status}`));
      if (n.prior != null && !(n.prior >= 0 && n.prior <= 1)) problems.push(P("R-TREE-SCHEMA", `node ${n.id} prior 越界: ${n.prior}`));
      if (n.confidence != null && !(n.confidence >= 0 && n.confidence <= 1)) problems.push(P("R-TREE-SCHEMA", `node ${n.id} confidence 越界: ${n.confidence}`));
      if (n.parent != null && !ids.has(n.parent)) problems.push(P("R-TREE-SCHEMA", `node ${n.id} parent 不存在: ${n.parent}`));
      for (const c of n.children || []) {
        if (!ids.has(c)) problems.push(P("R-TREE-SCHEMA", `node ${n.id} child 不存在: ${c}`));
        else {
          const cn = nodes.find((x) => x.id === c);
          if (cn.parent !== n.id) problems.push(P("R-TREE-SCHEMA", `parent/child 不一致: ${n.id}→${c} 但 ${c}.parent=${cn.parent}`));
        }
      }
    }
    for (const f of t.active_focus || []) if (!ids.has(f)) problems.push(P("R-TREE-SCHEMA", `active_focus 引用不存在节点: ${f}`));
  }

  // R-CHAIN-SCHEMA — 证据链行 schema
  const evidById = new Map();
  for (const e of chain) {
    if (!/^E\d+$/.test(e.id || "")) problems.push(P("R-CHAIN-SCHEMA", `证据 id 非法: ${e.id}`));
    else if (evidById.has(e.id)) problems.push(P("R-CHAIN-SCHEMA", `证据 id 重复: ${e.id}`));
    evidById.set(e.id, e);
    if (!Number.isInteger(e.round) || e.round < 1) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} round 非法: ${e.round}`));
    if (!EV_TYPE.includes(e.type)) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} type 非法: ${e.type}`));
    if (!EV_VERDICT.includes(e.verdict)) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} verdict 非法: ${e.verdict}`));
    if (typeof e.confidence !== "number" || e.confidence < 0 || e.confidence > 1) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} confidence 越界: ${e.confidence}`));
    const cits = e.citations || [];
    if (e.verdict && e.verdict !== "inconclusive" && cits.length === 0) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} 非 inconclusive 但无 citations`));
    for (const c of cits) if (!c.file || !c.locator) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} citation 缺 file/locator`));
    if (e.verdict === "inconclusive" && !((e.note || "").trim())) problems.push(P("R-CHAIN-SCHEMA", `证据 ${e.id} inconclusive 但 note/next_probe 为空(回调契约)`));
  }

  // R-CHAIN-SEQ — 证据 id 连续无缺号(E1..En)
  if (chain.length > 0) {
    const nums = chain.map((e) => parseInt((e.id || "").slice(1), 10)).filter((x) => Number.isInteger(x)).sort((a, b) => a - b);
    for (let i = 0; i < nums.length; i++) {
      if (nums[i] !== i + 1) { problems.push(P("R-CHAIN-SEQ", `证据 id 序列不连续: 期望 E${i + 1},实际含 E${nums[i]}`)); break; }
    }
  }

  // R-ROUNDS-CONTIG — 轮次连续、每轮首读、派发=回调、非末轮 continue/末轮 stop、轮报快照存在
  const N = rounds.length;
  if (m && N > (m.budget?.max_rounds ?? Infinity)) problems.push(P("R-ROUNDS-CONTIG", `轮次 ${N} 超出 max_rounds ${m.budget.max_rounds}`));
  rounds.forEach((r, i) => {
    const isLast = i === N - 1;
    if (r.round !== i + 1) problems.push(P("R-ROUNDS-CONTIG", `轮次编号不连续: 第 ${i + 1} 条记录 round=${r.round}`));
    if (r.state_read_first !== true) problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} state_read_first ≠ true(违反每轮首读持久化状态)`));
    if (!Array.isArray(r.dispatched) || r.dispatched.length === 0) problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} dispatched 为空`));
    if (r.callbacks_valid !== (r.dispatched || []).length) problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} callbacks_valid=${r.callbacks_valid} ≠ dispatched ${(r.dispatched || []).length}(回调丢失=状态丢失)`));
    if (!["continue", "stop"].includes(r.decision)) problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} decision 非法: ${r.decision}`));
    if (!isLast && r.decision !== "continue") problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} 非末轮但 decision=${r.decision}`));
    if (!isLast && !((r.stop_check?.why_not_stop || "").trim())) problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} 继续但无 why_not_stop 理由`));
    if (isLast && r.decision === "stop" && !((r.stop_check?.why_stop || "").trim()) && r.stop_check?.rounds_left !== 0) {
      problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} 末轮停止但无 why_stop 理由`));
    }
    if (!r.integration || !Array.isArray(r.integration.pruned) || !Array.isArray(r.integration.dove)) {
      problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} 缺 integration 快照`));
    }
    if (!existsSync(join(run.dir, "report", "rounds", `round-${pad2(r.round)}.md`))) {
      problems.push(P("R-ROUNDS-CONTIG", `round ${r.round} 缺 report/rounds/round-${pad2(r.round)}.md 轮报快照`));
    }
  });

  // R-DISPATCH-REF — 派发假设引用闭合
  if (t) {
    const ids = new Set((t.nodes || []).map((n) => n.id));
    for (const r of rounds) for (const d of r.dispatched || []) {
      if (!ids.has(d.hypothesis_id)) problems.push(P("R-DISPATCH-REF", `round ${r.round} 派发不存在假设: ${d.hypothesis_id}`));
    }
  }

  // R-TREE-CHAIN-REF — 树↔链引用闭合;剪枝/结论必须有证据支撑
  if (t) {
    for (const n of t.nodes || []) {
      for (const eid of n.evidence_ids || []) if (!evidById.has(eid)) problems.push(P("R-TREE-CHAIN-REF", `node ${n.id} 引用不存在证据: ${eid}`));
      if ((n.status === "pruned" || n.status === "concluded") && (!n.evidence_ids || n.evidence_ids.length === 0)) {
        problems.push(P("R-TREE-CHAIN-REF", `node ${n.id} ${n.status} 但无证据支撑(无凭空排除/结论)`));
      }
      if (n.status === "pruned") {
        if (!n.prune_reason) problems.push(P("R-TREE-CHAIN-REF", `node ${n.id} 剪枝无 prune_reason`));
        else if (!/E\d+/.test(n.prune_reason)) problems.push(P("R-TREE-CHAIN-REF", `node ${n.id} prune_reason 未引用证据 id`));
      }
    }
  }

  // R-CONCLUDED-CAUSAL — 结论节点至少一条 causal+support 证据(相关证据不得单独支撑结论)
  if (t) {
    for (const n of (t.nodes || []).filter((x) => x.status === "concluded")) {
      const ok = (n.evidence_ids || []).some((id) => {
        const e = evidById.get(id);
        return e && e.type === "causal" && e.verdict === "support";
      });
      if (!ok) problems.push(P("R-CONCLUDED-CAUSAL", `concluded 节点 ${n.id} 无 causal+support 证据(归因谬误防线)`));
    }
  }

  // R-STOP-CONSISTENCY — 停止条件三方一致 + 诚实语义
  if (m && t && N > 0) {
    const last = rounds[N - 1];
    if (last.final_state == null) problems.push(P("R-STOP-CONSISTENCY", "末轮 round-log 缺 final_state"));
    else if (last.final_state !== m.final_state) problems.push(P("R-STOP-CONSISTENCY", `manifest.final_state(${m.final_state}) ≠ round-log 末轮(${last.final_state})`));
    if (last.decision !== "stop") problems.push(P("R-STOP-CONSISTENCY", `末轮 decision=${last.decision} ≠ stop(停止条件未触发=死锁)`));
    const concl = t.conclusion || {};
    if (m.final_state === "root_cause_concluded") {
      const node = (t.nodes || []).find((n) => n.id === concl.root_cause_hypothesis);
      if (!concl.root_cause_hypothesis) problems.push(P("R-STOP-CONSISTENCY", "final_state=root_cause_concluded 但 conclusion 无根因假设"));
      else if (!node) problems.push(P("R-STOP-CONSISTENCY", `conclusion.root_cause_hypothesis(${concl.root_cause_hypothesis}) 不在树中`));
      else if (node.status !== "concluded") problems.push(P("R-STOP-CONSISTENCY", `根因假设 ${node.id} status=${node.status} ≠ concluded`));
      if (typeof concl.confidence !== "number" || concl.confidence < (m.budget?.confidence_stop ?? 0.8)) {
        problems.push(P("R-STOP-CONSISTENCY", `conclusion.confidence(${concl.confidence}) 低于停止阈值 ${m.budget?.confidence_stop}`));
      }
    }
    if (m.final_state === "hypothesis_space_exhausted") {
      const concludedNodes = (t.nodes || []).filter((n) => n.status === "concluded");
      if (concludedNodes.length > 0 || concl.root_cause_hypothesis) {
        problems.push(P("R-STOP-CONSISTENCY", "假设空间耗尽仍宣称根因结论(必须诚实升级人类,禁止硬编结论)"));
      }
    }
    if (m.final_state === "budget_exhausted" && N !== m.budget?.max_rounds) {
      problems.push(P("R-STOP-CONSISTENCY", `budget_exhausted 但轮次 ${N} ≠ max_rounds ${m.budget?.max_rounds}`));
    }
  }

  // R-UPDATED-ROUND — 树快照轮次同步
  if (t && N > 0) {
    const lastRound = rounds[N - 1].round;
    if (t.updated_round !== lastRound) problems.push(P("R-UPDATED-ROUND", `tree.updated_round(${t.updated_round}) ≠ 末轮(${lastRound})`));
  }

  // R-REPORT-EXISTS — 结案报告存在
  if (!run.reportExists) problems.push(P("R-REPORT-EXISTS", "report/final-report.md 缺失"));

  // R-CITATION-CONFINEMENT / R-CITATION-CLOSED — 只读边界:引用面限定于静态观测面
  const manifestFiles = new Set((caseJson?.plane_manifest || []).map((x) => x.file));
  for (const e of chain) {
    for (const c of e.citations || []) {
      const f = c.file || "";
      if (/^([a-zA-Z]:|[\\/])/.test(f) || f.includes("\\") || f.includes("..") || !f.startsWith("plane/")) {
        problems.push(P("R-CITATION-CONFINEMENT", `证据 ${e.id} 引用越界(须为 plane/ 相对路径且无逃逸): ${f}`));
      } else if (manifestFiles.size > 0 && !manifestFiles.has(f)) {
        problems.push(P("R-CITATION-CLOSED", `证据 ${e.id} 引用观测面外文件(不在 plane_manifest): ${f}`));
      }
    }
  }
  return problems;
}

// ---------- 定位判定独立复算(与 score.mjs 双实现交叉验证) ----------
function extractConclusionZone(md) {
  const zones = [];
  let capture = false;
  for (const line of md.split(/\r?\n/)) {
    if (/^#{1,3}\s/.test(line)) capture = /根因|结论|root.?cause|conclusion/i.test(line);
    else if (capture) zones.push(line);
  }
  return zones.length === 0 ? md : zones.join("\n");
}
function recomputeVerdict(run, answer) {
  if (!answer) return { verdict: "no_answer", hits: [], rejects: [] };
  if (!run.reportExists) return { verdict: "no_report", hits: [], rejects: [] };
  const zone = extractConclusionZone(run.reportText).toLowerCase();
  const hits = (answer.verdict_keywords || []).filter((k) => zone.includes(k.toLowerCase()));
  const rejects = (answer.reject_keywords || []).filter((k) => zone.includes(k.toLowerCase()));
  const fs = run.manifest?.final_state;
  let verdict;
  if (fs === "hypothesis_space_exhausted") verdict = "escalated";
  else if (fs === "budget_exhausted") verdict = "budget_exhausted";
  else if (fs === "root_cause_concluded") {
    if (rejects.length > 0) verdict = "misattributed";
    else if (hits.length >= 2) verdict = "located";
    else if (hits.length === 1) verdict = "located_needs_review";
    else verdict = "missed";
  } else verdict = "incomplete";
  return { verdict, hits, rejects };
}

// ---------- 用例执行框架 ----------
function makeTc(id, title, ac, priority, suite) { return { id, title, ac, priority, suite, status: "pass", details: [] }; }
function fail(tc, msg) { tc.status = "fail"; tc.details.push(msg); }
function note(tc, msg) { tc.details.push(msg); }
function warn(tc, msg) { if (tc.status !== "fail") tc.status = "warn"; tc.details.push(`[备忘] ${msg}`); }

function listRuns(lab) {
  const runsDir = join(lab, "runs");
  if (!existsSync(runsDir)) return [];
  return readdirSync(runsDir).filter((d) => existsSync(join(runsDir, d, "manifest.json"))).map((d) => loadRun(join(runsDir, d)));
}
function loadRegistry(lab) {
  const p = join(lab, "cases", "registry.jsonl");
  if (!existsSync(p)) return null;
  try { return readJsonl(p); } catch { return null; }
}
function loadAnswers(lab) {
  const p = join(lab, "analysis", "scoring", "answers.jsonl");
  if (!existsSync(p)) return new Map();
  try { return new Map(readJsonl(p).map((a) => [a.case_id, a])); } catch { return new Map(); }
}
function loadCaseJsonByCaseId(lab, caseId, tier) {
  const p = join(lab, "cases", tier || tierFromCaseId(caseId), caseId, "case.json");
  if (!existsSync(p)) return null;
  try { return readJson(p); } catch { return null; }
}

// ---------- suite: meta ----------
function suiteMeta(lab) {
  const tcs = [makeTc("TC-005", "校验器自检:坏 fixture 的结构违规必须逐项检出,好 fixture 零误报", "AC-1", "P0", "meta"),
               makeTc("TC-014", "校验器自检:坏证据链 fixture(无据剪枝/悬空引用/无 causal 结论/越界引用)逐项检出", "AC-2", "P0", "meta")];
  const answers = loadAnswers(lab);
  if (!answers.has("mock-001")) { fail(tcs[0], "fixture 依赖的 mock-001 托管答案缺失,无法自检"); fail(tcs[1], tcs[0].details[0]); return tcs; }
  const caseJson = loadCaseJsonByCaseId(lab, "mock-001", "l1-mock");
  if (!caseJson) { fail(tcs[0], "fixture 依赖的 mock-001 case.json 缺失"); fail(tcs[1], tcs[0].details[0]); return tcs; }

  const good = loadRun(join(FIXTURES_DIR, "good-run"));
  const bad = loadRun(join(FIXTURES_DIR, "bad-run"));
  const expected = readJson(join(FIXTURES_DIR, "bad-run", "expected-findings.json"));
  const goodProblems = validateRun(good, caseJson);
  const badProblems = validateRun(bad, caseJson);
  const fired = (rule) => badProblems.some((p) => p.rule === rule);

  // TC-005:结构规则检出 + 好样本零误报 + 定位复算路径可用
  if (goodProblems.length > 0) fail(tcs[0], `好 fixture 被误报 ${goodProblems.length} 项: ${goodProblems.map((p) => `${p.rule}(${p.msg})`).join("; ")}`);
  const vr = recomputeVerdict(good, answers.get("mock-001"));
  if (vr.verdict !== "located") fail(tcs[0], `好 fixture 定位复算期望 located,实际 ${vr.verdict}(hits=${vr.hits})`);
  for (const rule of expected["TC-005"]) if (!fired(rule)) fail(tcs[0], `坏 fixture 未检出规则 ${rule}(校验器漏检)`);
  // TC-014:证据链规则检出
  for (const rule of expected["TC-014"]) if (!fired(rule)) fail(tcs[1], `坏 fixture 未检出规则 ${rule}(校验器漏检)`);
  if (tcs[0].status === "pass") note(tcs[0], `好样本 0 误报;坏样本检出 ${badProblems.length} 项违规,含全部期望规则`);
  return tcs;
}

// ---------- suite: l1 ----------
function suiteL1(lab) {
  const tcs = [
    makeTc("TC-001", "L1 run 状态三件套 schema 合法(字段/枚举/数值范围)", "AC-1", "P0", "l1"),
    makeTc("TC-002", "轮次连续无死锁:1..N、每轮首读状态、派发=回调数、停止有据、轮报快照齐全", "AC-1", "P0", "l1"),
    makeTc("TC-003", "停止条件三方一致(manifest↔round-log↔tree);escalated 不得宣称根因", "AC-1", "P0", "l1"),
    makeTc("TC-004", "断点恢复信息完备:证据 id 连续、树↔链↔派发引用闭合、updated_round 同步、结案报告存在", "AC-1", "P0", "l1"),
    makeTc("TC-006", "全部已注册 L1 mock 案例均有编排臂 run 且通过结构校验", "AC-1", "P1", "l1"),
  ];
  const runs = listRuns(lab).filter((r) => (r.manifest?.case_tier || tierFromCaseId(r.manifest?.case_id || "")) === "l1-mock");
  if (runs.length === 0) { for (const t of tcs) fail(t, "无任何 L1 run(runs/ 下无 case_tier=l1-mock 的运行实例)"); return tcs; }

  const groups = {
    "TC-001": ["R-RUN-READ", "R-MANIFEST-ENUM", "R-TREE-SCHEMA", "R-CHAIN-SCHEMA"],
    "TC-002": ["R-ROUNDS-CONTIG", "R-DISPATCH-REF"],
    "TC-003": ["R-STOP-CONSISTENCY"],
    "TC-004": ["R-CHAIN-SEQ", "R-TREE-CHAIN-REF", "R-UPDATED-ROUND", "R-REPORT-EXISTS", "R-CONCLUDED-CAUSAL", "R-CITATION-CONFINEMENT", "R-CITATION-CLOSED"],
  };
  const byTc = new Map(tcs.map((t) => [t.id, t]));
  for (const run of runs) {
    const problems = validateRun(run, loadCaseJson(lab, run.manifest));
    for (const [tcId, rules] of Object.entries(groups)) {
      const hits = problems.filter((p) => rules.includes(p.rule));
      if (hits.length) fail(byTc.get(tcId), `${run.id}: ${hits.map((h) => `${h.rule} ${h.msg}`).join(" | ")}`);
    }
  }
  for (const t of tcs.slice(0, 4)) if (t.status === "pass") note(t, `${runs.length} 个 L1 run 全部通过(${runs.map((r) => r.id).join(", ")})`);

  // TC-006:注册的 l1-mock 案例覆盖
  const registry = loadRegistry(lab);
  if (!registry) fail(tcs[4], "cases/registry.jsonl 缺失或不可解析");
  else {
    const l1Cases = registry.filter((x) => x.tier === "l1-mock").map((x) => x.case_id);
    if (l1Cases.length === 0) fail(tcs[4], "registry 无 l1-mock 案例注册");
    for (const cid of l1Cases) {
      const orch = runs.filter((r) => r.manifest?.case_id === cid && r.manifest?.arm === "orchestrated");
      if (orch.length === 0) { fail(tcs[4], `案例 ${cid} 无编排臂 run`); continue; }
      for (const run of orch) {
        const problems = validateRun(run, loadCaseJson(lab, run.manifest));
        if (problems.length) fail(tcs[4], `${run.id} 结构校验未过: ${problems.map((p) => p.rule).join(",")}`);
      }
    }
    if (tcs[4].status === "pass") note(tcs[4], `${l1Cases.length} 个已注册 L1 案例均有编排臂 run 且结构合规`);
  }
  return tcs;
}

// ---------- suite: l2 ----------
function suiteL2(lab) {
  const tcs = [
    makeTc("TC-011", "OpenRCA 改装案例注册数 ≥5(5~10 区间,>10 备忘)", "AC-2", "P0", "l2"),
    makeTc("TC-012", "L2 案例结构合规 + 改装审计落档(rule_version/audit_summary/leak_check)", "AC-2", "P0", "l2"),
    makeTc("TC-013", "≥1 个 L2 编排臂 run 独立复算 verdict=located 且证据链完整可复核", "AC-2", "P0", "l2"),
    makeTc("TC-015", "无凭空排除:全部剪枝有 refute 证据 + 高先验剪枝双验记录完备", "AC-2", "P1", "l2"),
    makeTc("TC-016", "L2 plane 文本敏感词独立粗检(改装不得泄露根因线索)", "AC-2", "P1", "l2"),
    makeTc("TC-021", "两臂汇总如实落档:summary 与单 run 评分重算一致、论文参照口径标注", "AC-3", "P0", "l2"),
    makeTc("TC-022", "基线臂公平对照:所测 L2 案例有同案例 baseline run 且同 max_rounds", "AC-3", "P1", "l2"),
    makeTc("TC-023", "无增益信号如实呈现:编排不高于基线时结案文档必须记录", "AC-3", "P2", "l2"),
    makeTc("TC-031", "评分 verdict 枚举合法且分层可归因(机械/能力/无增益可区分)", "AC-4", "P1", "l2"),
  ];
  const answers = loadAnswers(lab);
  const registry = loadRegistry(lab);
  const l2Lines = (registry || []).filter((x) => x.tier === "l2-openrca");
  const allRuns = listRuns(lab);
  const l2Runs = allRuns.filter((r) => (r.manifest?.case_tier || tierFromCaseId(r.manifest?.case_id || "")) === "l2-openrca");

  // TC-011
  if (l2Lines.length < 5) fail(tcs[0], `l2-openrca 注册案例 ${l2Lines.length} 个 < 5(验收要求抽取 5~10 个)`);
  else if (l2Lines.length > 10) warn(tcs[0], `注册 ${l2Lines.length} 个,超出承诺区间 5~10(备忘,不阻塞)`);
  else note(tcs[0], `l2-openrca 注册 ${l2Lines.length} 个,处于 5~10 区间`);

  // TC-012
  if (!registry) fail(tcs[1], "cases/registry.jsonl 缺失或不可解析");
  if (l2Lines.length > 0) {
    for (const line of l2Lines) {
      const cj = loadCaseJsonByCaseId(lab, line.case_id, "l2-openrca");
      if (!cj) { fail(tcs[1], `${line.case_id}: case.json 缺失或不可解析`); continue; }
      for (const f of ["format_version", "case_id", "tier", "symptom", "plane_manifest", "answer_ref"]) {
        if (cj[f] == null) fail(tcs[1], `${line.case_id}: case.json 缺字段 ${f}`);
      }
      if (cj.tier && cj.tier !== "l2-openrca") fail(tcs[1], `${line.case_id}: tier=${cj.tier} ≠ l2-openrca`);
      const cdir = join(lab, "cases", "l2-openrca", line.case_id);
      for (const mf of cj.plane_manifest || []) if (!existsSync(join(cdir, mf.file))) fail(tcs[1], `${line.case_id}: plane 文件缺失 ${mf.file}`);
      if (!answers.has(line.case_id)) fail(tcs[1], `${line.case_id}: 托管答案缺失(answers.jsonl 无此 case_id)`);
      const conv = line.conversion || {};
      for (const f of ["rule_version", "audit_summary", "leak_check"]) {
        if (!conv[f] || !String(conv[f]).trim()) fail(tcs[1], `${line.case_id}: registry 行 conversion.${f} 未落档(改装保真审计)`);
      }
      if (cj.source?.repo && !/openrca/i.test(cj.source.repo)) warn(tcs[1], `${line.case_id}: source.repo=${cj.source.repo} 未指向 OpenRCA(确认来源)`);
    }
    if (tcs[1].status === "pass") note(tcs[1], `${l2Lines.length} 个 L2 案例结构合规、改装审计齐全`);
  } else note(tcs[1], "尚无 L2 案例注册(TC-011 已拦截)");

  // TC-013 — 独立复算定位 + 链完整
  const locatedRuns = [];
  for (const run of l2Runs.filter((r) => r.manifest?.arm === "orchestrated")) {
    const answer = answers.get(run.manifest.case_id);
    if (!answer) { fail(tcs[2], `${run.id}: 无托管答案,无法复算`); continue; }
    const vr = recomputeVerdict(run, answer);
    if (vr.verdict === "located") {
      const problems = validateRun(run, loadCaseJson(lab, run.manifest));
      if (problems.length === 0) locatedRuns.push(run);
      else fail(tcs[2], `${run.id}: located 但链完整性未过 — ${problems.map((p) => `${p.rule} ${p.msg}`).join(" | ")}`);
    }
  }
  if (locatedRuns.length === 0) fail(tcs[2], `无任何 L2 编排臂 run 同时满足「独立复算 located」且「证据链完整」(当前 L2 编排臂 run ${l2Runs.filter((r) => r.manifest?.arm === "orchestrated").length} 个)`);
  else note(tcs[2], `${locatedRuns.length} 个 L2 编排臂 run 独立复算 located 且链完整: ${locatedRuns.map((r) => r.id).join(", ")}`);

  // TC-015 — 剪枝证据支撑 + 双验记录
  if (l2Runs.length === 0) note(tcs[3], "尚无 L2 run(随 TC-011/013 拦截)");
  for (const run of l2Runs) {
    const tree = run.tree;
    if (!tree) continue;
    const evidById = new Map((run.chain || []).map((e) => [e.id, e]));
    const priorThreshold = run.manifest?.budget?.verify_prune_prior ?? 0.6;
    for (const n of (tree.nodes || []).filter((x) => x.status === "pruned")) {
      const refIds = ((n.prune_reason || "").match(/E\d+/g) || []);
      const hasRefute = refIds.some((id) => evidById.get(id)?.verdict === "refute");
      if (!hasRefute) fail(tcs[3], `${run.id}: 剪枝 ${n.id} 引用证据无 refute 判定(关键剪枝须直接反证): ${(n.evidence_ids || []).join(",")}`);
      if ((n.prior ?? 0) >= priorThreshold) {
        const logs = (run.rounds || []).map((r) => JSON.stringify({
          applied: (r.verify_prune_applied || []).map((x) => x.id || x),
          note: r.verify_prune_skipped_note || "",
        })).join(" ");
        if (!logs.includes(n.id)) fail(tcs[3], `${run.id}: 高先验(prior=${n.prior}≥${priorThreshold})剪枝 ${n.id} 无双验记录(verify_prune_applied/skipped_note 均未提及)`);
      }
    }
  }
  if (tcs[3].status === "pass" && l2Runs.length > 0) note(tcs[3], `${l2Runs.length} 个 L2 run 全部剪枝有 refute 支撑、双验记录完备`);

  // TC-016 — plane 敏感词独立粗检
  const sensitive = [/root[\s_-]?cause/i, /ground[\s_-]?truth/i, /post[\s_-]?mortem/i];
  const textExt = /\.(log|txt|csv|json|md)$/i;
  for (const line of l2Lines) {
    const cdir = join(lab, "cases", "l2-openrca", line.case_id);
    const planeDir = join(cdir, "plane");
    if (!existsSync(planeDir)) { fail(tcs[4], `${line.case_id}: plane/ 目录缺失`); continue; }
    const walk = (d) => {
      for (const name of readdirSync(d)) {
        const p = join(d, name);
        const st = statSync(p);
        if (st.isDirectory()) walk(p);
        else if (textExt.test(name)) {
          const txt = readFileSync(p, "utf8");
          for (const re of sensitive) if (re.test(txt)) fail(tcs[4], `${relative(lab, p)} 命中敏感词 ${re}(改装泄露根因线索风险)`);
        }
      }
    };
    walk(planeDir);
  }
  if (tcs[4].status === "pass") note(tcs[4], l2Lines.length === 0 ? "尚无 L2 案例(随 TC-011 拦截)" : `${l2Lines.length} 个 L2 案例 plane 敏感词粗检通过`);

  // TC-021 — 汇总如实落档(独立重算比对)
  const scoringDir = join(lab, "analysis", "scoring");
  const scoringFiles = existsSync(scoringDir) ? readdirSync(scoringDir).filter((f) => f.endsWith(".json") && f !== "summary.json") : [];
  const scorings = [];
  for (const f of scoringFiles) {
    try { scorings.push({ file: f, data: readJson(join(scoringDir, f)) }); }
    catch (e) { fail(tcs[5], `评分产物 ${f} 不可解析: ${e.message}`); }
  }
  const summaryPath = join(scoringDir, "summary.json");
  if (!existsSync(summaryPath)) fail(tcs[5], "analysis/scoring/summary.json 缺失(两臂汇总未落档)");
  else {
    const s = readJson(summaryPath);
    for (const r of allRuns) {
      if (!scorings.some((x) => x.file === `${r.id}.json`)) fail(tcs[5], `run ${r.id} 无评分产物(${r.id}.json)`);
    }
    const isLoc = (v) => v === "located" || v === "located_needs_review";
    const o = scorings.filter((x) => x.data.arm === "orchestrated");
    const b = scorings.filter((x) => x.data.arm === "baseline");
    if (s.orchestrated_total !== o.length) fail(tcs[5], `summary.orchestrated_total=${s.orchestrated_total} ≠ 评分文件重算 ${o.length}`);
    if (s.orchestrated_located !== o.filter((x) => isLoc(x.data.verdict)).length) fail(tcs[5], `summary.orchestrated_located=${s.orchestrated_located} ≠ 重算 ${o.filter((x) => isLoc(x.data.verdict)).length}`);
    if (s.baseline_total !== b.length) fail(tcs[5], `summary.baseline_total=${s.baseline_total} ≠ 评分文件重算 ${b.length}`);
    if (s.baseline_located !== b.filter((x) => isLoc(x.data.verdict)).length) fail(tcs[5], `summary.baseline_located=${s.baseline_located} ≠ 重算 ${b.filter((x) => isLoc(x.data.verdict)).length}`);
    if (s.runs_total !== scorings.length) fail(tcs[5], `summary.runs_total=${s.runs_total} ≠ 评分文件数 ${scorings.length}`);
    const mdPath = join(scoringDir, "summary.md");
    if (!existsSync(mdPath)) fail(tcs[5], "summary.md 缺失");
    else if (!/论文|paper/i.test(readFileSync(mdPath, "utf8"))) fail(tcs[5], "summary.md 未标注论文单体基线参照口径(AC-3 如实落档要求)");
  }

  // TC-022 — 基线臂公平对照
  const orchCases = new Set(l2Runs.filter((r) => r.manifest?.arm === "orchestrated").map((r) => r.manifest.case_id));
  if (l2Runs.length === 0 || orchCases.size === 0) note(tcs[6], "尚无 L2 编排臂 run(随 TC-011/013 拦截)");
  else {
    for (const cid of orchCases) {
      const base = l2Runs.filter((r) => r.manifest?.case_id === cid && r.manifest?.arm === "baseline");
      if (base.length === 0) { fail(tcs[6], `所测案例 ${cid} 无 baseline run(两臂对照缺失)`); continue; }
      const orchRounds = new Set(l2Runs.filter((r) => r.manifest?.case_id === cid && r.manifest?.arm === "orchestrated").map((r) => r.manifest.budget?.max_rounds));
      for (const r of base) {
        if (!orchRounds.has(r.manifest.budget?.max_rounds)) fail(tcs[6], `${r.id}: baseline max_rounds=${r.manifest.budget?.max_rounds} 与编排臂 ${[...orchRounds].join("/")} 不同值(公平性)`);
      }
    }
    if (tcs[6].status === "pass") note(tcs[6], `${orchCases.size} 个所测 L2 案例均有同预算 baseline run`);
  }

  // TC-023 — 无增益信号如实呈现(P2)
  const myLoc = (runs) => runs.filter((r) => {
    const vr = recomputeVerdict(r, answers.get(r.manifest?.case_id));
    return vr.verdict === "located" || vr.verdict === "located_needs_review";
  }).length;
  const orchRuns = l2Runs.filter((r) => r.manifest?.arm === "orchestrated");
  const baseRuns = l2Runs.filter((r) => r.manifest?.arm === "baseline");
  if (baseRuns.length === 0) note(tcs[7], "无 baseline run,无增益判定不适用");
  else if (myLoc(orchRuns) <= myLoc(baseRuns)) {
    const docs = ["attribution-report.md", "observations.md", "scoring/summary.md"]
      .map((f) => join(lab, "analysis", f))
      .filter((p) => existsSync(p))
      .map((p) => readFileSync(p, "utf8"))
      .join("\n");
    if (!/无增益|不高于基线|不优于|no.?gain/i.test(docs)) warn(tcs[7], `编排臂 located(${myLoc(orchRuns)})≤基线臂(${myLoc(baseRuns)}),但结案文档未见无增益信号记录(AC-3 如实落档)`);
    else note(tcs[7], "无增益信号已在结案文档如实记录");
  } else note(tcs[7], `编排臂 located ${myLoc(orchRuns)} > 基线臂 ${myLoc(baseRuns)}`);

  // TC-031 — verdict 枚举
  for (const x of scorings) {
    if (!VERDICTS.includes(x.data.verdict)) fail(tcs[8], `${x.file}: verdict 非法 ${x.data.verdict}(分层归因口径被破坏)`);
  }
  if (tcs[8].status === "pass") note(tcs[8], `${scorings.length} 个评分产物 verdict 全部合法(机械=incomplete/no_report;能力=missed/misattributed;升级=escalated;预算=budget_exhausted 可区分)`);

  return tcs;
}

// ---------- suite: constraints ----------
function walkTree(root, prefix, out) {
  if (!existsSync(root)) return;
  for (const name of readdirSync(root)) {
    if (WALK_SKIP_DIRS.has(name)) continue;
    const p = join(root, name);
    const rel = prefix ? `${prefix}/${name}` : name;
    if (WALK_SKIP_SUBTREES.some((s) => rel === s || rel.startsWith(s + "/"))) continue;
    const st = statSync(p);
    if (st.isDirectory()) walkTree(p, rel, out);
    else out[rel] = [st.size, st.mtimeMs];
  }
}
function suiteConstraints(lab, resetBaseline) {
  const tcs = [
    makeTc("TC-041", "归属判据报告产出:三判据章节齐全(原语够用性+缺口/格式稳定性/归属建议)", "AC-5", "P0", "constraints"),
    makeTc("TC-042", "格式稳定性追踪:observations.md 落档且各 run 状态文件 format_version 一致", "AC-5", "P1", "constraints"),
    makeTc("TC-051", "影响范围 confined:受保护路径(harness/rdd-engine/角色目录等)对照基线快照零改动", "AC-6", "P0", "constraints"),
    makeTc("TC-052", "新增产物 confined:基线后新增/变更文件仅在允许根(labs/tests/exploration 等)", "AC-6", "P1", "constraints"),
    makeTc("TC-061", "只读边界:全部 citations 为 plane/ 相对路径且无绝对路径/逃逸", "AC-7", "P0", "constraints"),
    makeTc("TC-062", "引用面封闭:citations 均落在案例 plane_manifest 声明的静态文件集内", "AC-7", "P1", "constraints"),
  ];

  // TC-041
  const attrPath = join(lab, "analysis", "attribution-report.md");
  if (!existsSync(attrPath)) fail(tcs[0], "analysis/attribution-report.md 缺失(PoC 结案交付物,三判据未产出)");
  else {
    const txt = readFileSync(attrPath, "utf8");
    if (!/原语|够用|缺口/.test(txt)) fail(tcs[0], "缺判据(a):现有原语够用性结论及缺口清单");
    if (!/格式.{0,8}稳定|稳定性/.test(txt)) fail(tcs[0], "缺判据(b):假设树/证据链格式稳定性评估");
    if (!/归属/.test(txt) || !/建议|决策/.test(txt)) fail(tcs[0], "缺判据(c):归属建议");
    if (tcs[0].status === "pass") note(tcs[0], "三判据章节齐全");
  }

  // TC-042
  const obsPath = join(lab, "analysis", "observations.md");
  if (!existsSync(obsPath)) fail(tcs[1], "analysis/observations.md 缺失(运行期观察项未落档)");
  else {
    const txt = readFileSync(obsPath, "utf8");
    if (txt.length < 200) fail(tcs[1], "observations.md 内容过少(<200 字符)");
    if (!/格式|format_version/i.test(txt)) fail(tcs[1], "observations.md 未记录格式稳定性观察");
  }
  const versions = new Set();
  for (const run of listRuns(lab)) {
    if (run.tree?.format_version != null) versions.add(run.tree.format_version);
  }
  if (versions.size > 1) fail(tcs[1], `各 run 状态文件 format_version 不一致: ${[...versions].join(", ")}`);
  else if (tcs[1].status === "pass") note(tcs[1], `observations.md 落档,format_version 统一为 ${[...versions][0] ?? "n/a(无 run)"}`);

  // TC-051 / TC-052 — 全仓文件基线(不依赖 git,避免沙箱管道限制)
  const current = {};
  walkTree(REPO_ROOT, "", current);
  if (!existsSync(BASELINE_PATH) || resetBaseline) {
    writeFileSync(BASELINE_PATH, JSON.stringify({ created_at: new Date().toISOString(), files: current }, null, 2), "utf8");
    note(tcs[2], `confinement 基线首次建立(${Object.keys(current).length} 个文件快照)。后续运行将对照本基线检测违规`);
    note(tcs[3], "confinement 基线首次建立,新增产物检查自下次运行生效");
  } else {
    const baseline = readJson(BASELINE_PATH).files;
    const added = [], removed = [], changed = [];
    for (const [p, v] of Object.entries(current)) {
      if (!(p in baseline)) added.push(p);
      else if (baseline[p][0] !== v[0]) changed.push(p); // size 变化(内容改动)
    }
    for (const p of Object.keys(baseline)) if (!(p in current)) removed.push(p);
    const isProtected = (p) => PROTECTED_ROOTS.some((r) => p === r || p.startsWith(r + "/")) || PROTECTED_FILES.includes(p);
    const isAllowed = (p) => ALLOWED_NEW_PREFIXES.some((r) => p.startsWith(r));
    const fmt = (arr) => arr.slice(0, 15).join("; ") + (arr.length > 15 ? ` 等 ${arr.length} 项` : "");
    // TC-051:受保护路径零改动
    const pv = [...added, ...removed, ...changed].filter(isProtected);
    if (pv.length) fail(tcs[2], `受保护路径出现改动 ${pv.length} 处(违反 AC-6 影响范围约束): ${fmt(pv)}`);
    else note(tcs[2], `受保护路径(${PROTECTED_ROOTS.join(",")} + ${PROTECTED_FILES.length} 个根文件)对照基线零改动`);
    // TC-052:基线后的全部变更必须在允许根内
    const nv = [...added, ...removed, ...changed].filter((p) => !isAllowed(p));
    if (nv.length) fail(tcs[3], `允许根之外出现新增/变更 ${nv.length} 处: ${fmt(nv)}`);
    else note(tcs[3], `基线后全部变更 confined 于允许根(${ALLOWED_NEW_PREFIXES.join(", ")})`);
  }

  // TC-061 / TC-062 — 引用面只读边界(全部 run)
  const runs = listRuns(lab);
  if (runs.length === 0) { fail(tcs[4], "无 run 可检查"); fail(tcs[5], "无 run 可检查"); }
  for (const run of runs) {
    const problems = validateRun(run, loadCaseJson(lab, run.manifest)).filter((p) => p.rule === "R-CITATION-CONFINEMENT" || p.rule === "R-CITATION-CLOSED");
    for (const p of problems) {
      if (p.rule === "R-CITATION-CONFINEMENT") fail(tcs[4], `${run.id}: ${p.msg}`);
      else fail(tcs[5], `${run.id}: ${p.msg}`);
    }
  }
  if (tcs[4].status === "pass") note(tcs[4], `${runs.length} 个 run 的全部证据引用均为 plane/ 相对路径,无越界`);
  if (tcs[5].status === "pass") note(tcs[5], `${runs.length} 个 run 的全部证据引用均落在 plane_manifest 静态文件集内`);

  return tcs;
}

// ---------- main ----------
function parseArgs(argv) {
  const args = { suite: "all", lab: DEFAULT_LAB, resetBaseline: false, json: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--suite") args.suite = argv[++i];
    else if (a === "--lab") args.lab = resolve(argv[++i]);
    else if (a === "--reset-baseline") args.resetBaseline = true;
    else if (a === "--json") args.json = true;
  }
  return args;
}

const args = parseArgs(process.argv);
const lab = args.lab;
const labExists = existsSync(lab);
const suites = args.suite === "all" ? ["meta", "l1", "l2", "constraints"] : [args.suite];

let tcs = [];
for (const s of suites) {
  if (s === "meta") tcs.push(...suiteMeta(labExists ? lab : DEFAULT_LAB));
  else if (s === "l1") tcs.push(...suiteL1(lab));
  else if (s === "l2") tcs.push(...suiteL2(lab));
  else if (s === "constraints") tcs.push(...suiteConstraints(lab, args.resetBaseline));
  else { console.error(`未知套件: ${s}`); process.exit(2); }
}
if (!labExists) {
  const msg = `实验目录不存在: ${lab}`;
  for (const t of tcs) if (t.suite !== "meta") fail(t, msg);
}

const totals = { pass: 0, fail: 0, warn: 0, skip: 0 };
for (const t of tcs) totals[t.status] = (totals[t.status] || 0) + 1;
const p0Fails = tcs.filter((t) => t.priority === "P0" && t.status === "fail");

const results = {
  generated_at: new Date().toISOString(),
  suite: args.suite,
  lab,
  totals,
  blocking: p0Fails.length > 0,
  p0_fail_ids: p0Fails.map((t) => t.id),
  cases: tcs,
};
writeFileSync(RESULTS_PATH, JSON.stringify(results, null, 2), "utf8");

if (!args.json) {
  console.log(`\n=== rca-poc 验收验证(${suites.join("+")}) — ${lab} ===`);
  for (const t of tcs) {
    const icon = t.status === "pass" ? "✅" : t.status === "fail" ? "❌" : "⚠️ ";
    console.log(`${icon} ${t.id} [${t.priority}] ${t.title}`);
    for (const d of t.details) console.log(`     · ${d}`);
  }
  console.log(`\n总览: 通过 ${totals.pass} / 失败 ${totals.fail} / 备忘 ${totals.warn} | 阻塞判断: ${p0Fails.length > 0 ? "🔴 存在 P0 失败" : "🟢 无 P0 失败"}`);
  if (p0Fails.length) console.log(`P0 失败: ${p0Fails.map((t) => t.id).join(", ")}(DEV 完成对应产物后复跑)`);
  console.log(`结果已写入 ${RESULTS_PATH}`);
}
process.exit(p0Fails.length > 0 ? 1 : 0);

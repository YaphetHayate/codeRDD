// render-tree.mjs — 从每个 run 的 state 三件套 + scoring 机械生成 Mermaid 执行决策树
// 图上每个节点的 verdict/confidence 均可回查:state/*.json(l) 与 analysis/scoring/<run-id>.json
// 用法:node tools/render-tree.mjs [runId ...](无参数 = 全部 runs)
import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const LAB_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const RUNS = join(LAB_ROOT, "runs");
const OUT = join(LAB_ROOT, "analysis", "trees");
mkdirSync(OUT, { recursive: true });

const clean = (s, n = 46) => String(s ?? "").replace(/["<>{}|\\]/g, "'").replace(/[\r\n]+/g, " ").slice(0, n);
const rdJson = (p) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8").replace(/^\uFEFF/, "")) : null);
const rdLines = (p) => (existsSync(p) ? readFileSync(p, "utf8").replace(/^\uFEFF/, "").split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l)) : []);

const args = process.argv.slice(2);
const runIds = args.length ? args : readdirSync(RUNS).filter((d) => !d.startsWith("_"));
const summary = rdJson(join(LAB_ROOT, "analysis", "scoring", "summary.json"));
const summaryIdx = new Map();
if (summary) for (const c of summary.by_case || []) for (const a of c.arms || []) summaryIdx.set(a.run_id, { ...a, case_id: c.case_id });

let made = 0;
for (const runId of runIds) {
  const dir = join(RUNS, runId);
  const tree = rdJson(join(dir, "state", "hypothesis-tree.json"));
  const evid = rdLines(join(dir, "state", "evidence-chain.jsonl"));
  const rounds = rdLines(join(dir, "state", "round-log.jsonl"));
  const manifest = rdJson(join(dir, "manifest.json"));
  const score = rdJson(join(LAB_ROOT, "analysis", "scoring", `${runId}.json`));
  if (!tree && !evid.length) continue;

  const L = [];
  L.push(`# 执行决策树 — ${runId}`);
  L.push("");
  L.push(`- 臂:\`${manifest?.arm ?? "?"}\` | 案例层级:\`${manifest?.case_tier ?? "?"}\` | 预算:\`${manifest?.budget?.max_rounds ?? "?"}\` 轮 | 终态:\`${manifest?.final_state ?? "?"}\``);
  L.push(`- 证据 \`${evid.length}\` 条(correlational ${evid.filter((e) => e.type === "correlational").length} / causal ${evid.filter((e) => e.type === "causal").length});轮次记录 \`${rounds.length}\``);
  if (score) L.push(`- 评分:verdict=\`${score.verdict}\`,关键词命中 \`${score.verdict_keywords_hit?.length ?? 0}\`(\`${(score.verdict_keywords_hit || []).join(",")}\`),误归因 \`${score.reject_keywords_hit?.length ?? 0}\`,需复核=\`${score.needs_human_review}\``);
  L.push("");
  L.push("> 本图由 \`tools/render-tree.mjs\` 从 state 机械生成;任何节点可回查 \`runs/${runId}/state/*\` 与 \`analysis/scoring/${runId}.json\`。节点色:🟢=concluded,🔵=supported,🔴=pruned/refuted,⚪=pending。");
  L.push("");
  L.push("```mermaid");
  L.push("flowchart TD");

  // 起点
  L.push(`  START(["${clean(tree?.case_id ?? manifest?.case_id ?? runId)}<br/>假设树起点"])`);

  const styleOf = { concluded: "#c8e6c9", supported: "#cfe8ff", pruned: "#ffcdd2", refuted: "#ffcdd2", pending: "#f5f5f5", established: "#cfe8ff" };

  const nodes = tree?.nodes || [];
  const byId = new Map(nodes.map((n) => [n.id, n]));
  // 假设节点
  for (const n of nodes) {
    const st = n.status || "pending";
    const tag = st === "concluded" ? "🟢" : st === "supported" ? "🔵" : st === "pruned" || st === "refuted" ? "🔴" : "⚪";
    const ev = (n.evidence_ids || []).join(",");
    L.push(`  ${n.id}["${tag} ${n.id} ${clean(n.statement)}<br/>prior ${n.prior ?? "-"} → conf ${n.confidence ?? "-"} ${ev ? "· " + ev : ""}"]`);
    // 父子
    if (n.parent && byId.has(n.parent)) L.push(`  ${n.parent} -->|下探| ${n.id}`);
    else L.push(`  START --> ${n.id}`);
  }

  // 证据节点 + 派发边(按 round 分组)
  const byRound = new Map();
  for (const e of evid) { const r = e.round ?? "?"; if (!byRound.has(r)) byRound.set(r, []); byRound.get(r).push(e); }
  for (const [r, es] of [...byRound.entries()].sort((a, b) => a[0] - b[0])) {
    L.push(`  subgraph R${r}["第 ${r} 轮"]`);
    for (const e of es) {
      const v = e.verdict === "refute" ? "🔴refute" : e.verdict === "support" ? "🟢support" : e.verdict;
      const en = `E_${e.id.replace(/[^A-Za-z0-9]/g, "_")}`;
      L.push(`  ${en}("${v} ${e.confidence ?? "-"}<br/>${clean(e.worker ?? e.id)} · ${e.type}")`);
      L.push(`  ${e.hypothesis_id} -.->|派发采证| ${en}`);
      // 证据→目标假设的裁决边
      const tgt = byId.get(e.hypothesis_id);
      if (tgt) {
        const act = e.verdict === "refute" ? "裁决:剪枝/排除" : e.verdict === "support" ? "裁决:支持/下探" : "裁决:存疑";
        L.push(`  ${en} -.->|${act}| ${e.hypothesis_id}`);
      }
    }
    L.push(`  end`);
    const rl = rounds.find((x) => x.round === Number(r));
    if (rl) {
      const sc = rl.stop_check || {};
      const dec = rl.decision === "stop" ? `STOP(${sc.why_stop ? clean(sc.why_stop, 60) : rl.final_state})` : "继续(整合后进入下一轮)";
      const dn = `D${r}`;
      L.push(`  ${dn}["${rl.decision === "stop" ? "🛑" : "➡️"} R${r} 决策:${clean(dec, 70)}"]`);
      L.push(`  R${r} -.-> ${dn}`);
    }
  }

  // 结论节点
  if (tree?.conclusion) {
    const c = tree.conclusion;
    L.push(`  CONCL["🏁 结案:${clean(c.root_cause_hypothesis)} conf ${c.confidence}<br/>停止:${clean(c.stop_reason)}<br/>${clean(c.summary, 80)}"]`);
    for (const n of nodes.filter((x) => x.status === "concluded")) L.push(`  ${n.id} ==> CONCL`);
    if (!nodes.some((x) => x.status === "concluded")) {
      const best = nodes.find((x) => x.status === "supported") || nodes[nodes.length - 1];
      if (best) L.push(`  ${best.id} ==>|评测口径裁决| CONCL`);
    }
  }

  // 样式
  for (const n of nodes) {
    L.push(`  style ${n.id} fill:${styleOf[n.status] || styleOf.pending},stroke:#666`);
  }
  L.push("```");
  L.push("");
  L.push(`## 断言摘要(每条证据一句话,全文见 \`runs/${runId}/state/evidence-chain.jsonl\`)`);
  L.push("");
  L.push("| 证据 | 假设 | 轮 | verdict | conf | 类型 | 断言(截断)|");
  L.push("|------|------|----|---------|------|------|------------|");
  for (const e of evid) L.push(`| ${e.id} | ${e.hypothesis_id} | ${e.round ?? "?"} | ${e.verdict} | ${e.confidence} | ${e.type} | ${clean(e.assertion, 90)} |`);

  writeFileSync(join(OUT, `${runId}.md`), L.join("\n") + "\n", "utf8");
  made++;
  console.log("tree:", runId, `(${evid.length} evid, ${nodes.length} nodes)`);
}
console.log(`\n${made} trees -> analysis/trees/`);

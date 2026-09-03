// gen-pm001.mjs — L3 pm-001 观测面生成器(蓝本:CircleCI 2021-11-08 postmortem,合成回放)
// 改装规则(R1-R5 手工执行):
//   R1 时间归一:T0=现象爆发(队列深度告警 08:00),分钟粒度,事件窗 [T-95, T+40]
//   R2 实体中性:job 类型名/distributor 保留(泛型组件名,无泄答案路径);deploy 编号保留(#4821=变更线索,合法)
//   R3 窗口:[T-95, T+40](deploy 前后 + 恢复)
//   R4 根因剔除:字段名/类型变更细节不进任何 plane 文件(pg.log 审计只记"ALTER on jobs 表 by deploy #4821"不含具体后果;validation 错误消息描述现象不指向变更)
//   R5 噪声鲁棒性(L3 专有):无关 GC/重连噪声、无关 deploy #4822、时间模糊(pg 审计无时刻)、误导信号(队列服务本身健康/worker 健康/网络平稳)
import { mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CASE = join(ROOT, "cases", "l3-postmortem", "pm-001");
const PLANE = join(CASE, "plane");

// ---------- 时间线(T 相对分钟)----------
// T-95 deploy#4821 开始 / T-92 完成 / T-90 新类型行开始写入 / T-88 首 validation error
// T-85 分发停止 / T-84.. 队列攀升 / T-60 canary 重启(噪声) / T-40 deploy#4822(无关,陷阱)
// T0 告警 / T+15 回滚#4821 / T+18 回滚完成 / T+19 scan 仍失败(关键判别) / T+25 手工 build+扩容 / T+40 恢复
const rnd = (seed) => { let s = seed; return () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648; }; };
const r = rnd(20211108);
const jitter = (a, b) => a + (b - a) * r();

mkdirSync(join(PLANE, "metrics"), { recursive: true });
mkdirSync(join(PLANE, "logs"), { recursive: true });

// ---------- metrics/job-queue-depth.csv(现象载体)----------
{
  const rows = ["offset_min,pending_jobs,oldest_job_age_min"];
  for (let t = -95; t <= 40; t++) {
    let depth, age;
    if (t < -85) { depth = Math.round(jitter(40, 80)); age = +(2 + jitter(0, 6)).toFixed(1); }
    else if (t < -40) { depth = Math.round(60 + (t + 85) * jitter(6.5, 9.5)); age = +((t + 85) * 0.9 + jitter(0, 3)).toFixed(1); }
    else if (t < 0) { depth = Math.round(340 + (t + 40) * jitter(8.5, 11.5)); age = +((t + 85) * 0.92 + jitter(0, 3)).toFixed(1); }
    else if (t < 25) { depth = Math.round(760 + t * jitter(3.5, 6)); age = +((t + 85) * 0.93 + jitter(0, 2)).toFixed(1); }
    else if (t < 34) { depth = Math.round(880 - (t - 25) * jitter(55, 75)); age = +Math.max(1, (110 - (t - 25) * 9 + jitter(0, 3))).toFixed(1); }
    else { depth = Math.round(jitter(45, 90)); age = +(2 + jitter(0, 5)).toFixed(1); }
    rows.push(`${t},${depth},${age}`);
  }
  writeFileSync(join(PLANE, "metrics", "job-queue-depth.csv"), rows.join("\n") + "\n", "utf8");
}

// ---------- metrics/distributor-scan-rate.csv(根因机制的可见面)----------
{
  const rows = ["offset_min,scans_per_min,rows_scanned_per_min,validation_fail_rows"];
  for (let t = -95; t <= 40; t++) {
    let scans, scanned, fails;
    if (t < -88) { scans = 12; scanned = Math.round(jitter(115000, 125000)); fails = 0; }
    else if (t < -85) { scans = 12; scanned = Math.round(jitter(115000, 125000)); fails = Math.round(jitter(180, 420)); } // T-88 起每 scan 撞到混合行
    else if (t < 19) { scans = t < 0 ? 12 : 12; scanned = Math.round(jitter(115000, 125000)); fails = Math.round(jitter(900, 1400)); } // 分发停但 scan 在跑(重试);回滚后(T+18 完成)仍失败
    else if (t < 25) { scans = 12; scanned = Math.round(jitter(115000, 125000)); fails = Math.round(jitter(900, 1400)); }
    else if (t < 31) { scans = 12; scanned = Math.round(jitter(115000, 125000)); fails = Math.round(1400 - (t - 25) * jitter(180, 260)); } // 手工 build 生效,fails 下降
    else { scans = 12; scanned = Math.round(jitter(115000, 125000)); fails = 0; }
    rows.push(`${t},${scans},${scanned},${fails}`);
  }
  writeFileSync(join(PLANE, "metrics", "distributor-scan-rate.csv"), rows.join("\n") + "\n", "utf8");
}

// ---------- metrics/distributor-dispatch.csv(分发速率=症状直接机制)----------
{
  const rows = ["offset_min,jobs_dispatched_per_min"];
  for (let t = -95; t <= 40; t++) {
    let d;
    if (t < -85) d = Math.round(jitter(95, 125));
    else if (t < 25) d = 0; // T-85 分发停止(校验失败即拒发)
    else if (t < 31) d = Math.round(jitter(130, 190)); // 扩容后排空
    else d = Math.round(jitter(95, 125));
    rows.push(`${t},${d}`);
  }
  writeFileSync(join(PLANE, "metrics", "distributor-dispatch.csv"), rows.join("\n") + "\n", "utf8");
}

// ---------- metrics/worker-cpu.csv(噪声/误导:worker 一直健康)----------
{
  const rows = ["offset_min,worker_cpu_pct,worker_mem_pct,gc_pause_ms"];
  for (let t = -95; t <= 40; t++) {
    const cpu = 22 + jitter(0, 14) + (t >= -60 && t < -52 ? 18 : 0); // T-60 canary 重启期 CPU 微升(陷阱)
    const mem = 54 + jitter(0, 6);
    const gc = Math.round(jitter(20, 90) + (t >= -60 && t < -52 ? jitter(200, 400) : 0));
    rows.push(`${t},${cpu.toFixed(1)},${mem.toFixed(1)},${gc}`);
  }
  writeFileSync(join(PLANE, "metrics", "worker-cpu.csv"), rows.join("\n") + "\n", "utf8");
}

// ---------- metrics/api-latency.csv(噪声:api 面平稳)----------
{
  const rows = ["offset_min,api_p99_ms,api_5xx_per_min"];
  for (let t = -95; t <= 40; t++) {
    const p99 = Math.round(jitter(180, 320) + (t >= 0 && t < 20 ? jitter(60, 140) : 0)); // 现象期轻微上扬(排队查询)
    rows.push(`${t},${p99},${Math.round(jitter(0, 2))}`);
  }
  writeFileSync(join(PLANE, "metrics", "api-latency.csv"), rows.join("\n") + "\n", "utf8");
}

// ---------- logs/deploy.log(合法审计线索:变更可见,后果不可见——R4)----------
{
  const rows = [
    "offset_min,event",
    "-95,deploy #4821 STARTED target=distributor-api component_group=jobs-infra operator=ci-bot",
    "-92,deploy #4821 COMPLETED status=ok targets=distributor-api,pg-migrator",
    "-40,deploy #4822 STARTED target=billing-web component_group=billing operator=human-jane",
    "-38,deploy #4822 COMPLETED status=ok targets=billing-web",
    "15,rollback #4821 REQUESTED reason=incident-1147 operator=oncall-dana",
    "18,rollback #4821 COMPLETED status=ok note=reverted distributor-api to v2.29 (pg-migrator NOT reverted)",
    "25,manual-deploy build=hotfix-ignore-field-8803 target=distributor-api operator=oncall-dana note=custom build",
    "27,scale-out distributor workers 4x operator=oncall-dana",
  ];
  writeFileSync(join(PLANE, "logs", "deploy.log"), rows.join("\n") + "\n", "utf8");
}

// ---------- logs/distributor.log(根因机制的直接观测:validation 错误,消息描述现象不指向变更——R4)----------
{
  const rows = ["offset_min,level,message"];
  // 事件前的常规日志(少量)
  rows.push("-90,info,scan cycle completed rows=120431 dispatched=118");
  rows.push("-89,info,scan cycle completed rows=120566 dispatched=121");
  // T-88 首错
  rows.push("-88,error,strict schema validation failed on scan: column 14 type mismatch (expected text representation of numeric, got raw numeric) row_id_hint=jobs:1742091");
  rows.push("-88,error,dispatch halted: scan validation gate failed (refusing to dispatch from inconsistent snapshot)");
  // 之后每分钟重复错误(抽样记录,间隔表达)
  for (const t of [-87, -86, -84, -80, -76, -70, -65, -55, -45, -30, -20, -10, -5, -1, 3, 8, 12, 19, 20, 21, 22, 24]) {
    const hints = { 19: "jobs:1755402 (row written AFTER rollback window began)", 20: "jobs:1755418", 21: "jobs:1755430" };
    rows.push(`${t},error,strict schema validation failed on scan: column 14 type mismatch (expected text representation of numeric, got raw numeric) row_id_hint=${hints[t] || "jobs:" + (1740000 + Math.round(jitter(1000, 15500)))}`);
  }
  // 恢复
  rows.push("30,info,scan cycle completed rows=121980 dispatched=165 validation=clean");
  rows.push("33,info,backlog drained: queue depth normalized");
  writeFileSync(join(PLANE, "logs", "distributor.log"), rows.join("\n") + "\n", "utf8");
}

// ---------- logs/pg.log(时间模糊的审计线索——L3 噪声特性:ALTER 只记日期)----------
{
  const rows = [
    "logged_date,offset_min_unknown,level,message",
    "2021-11-08,,notice,ALTER TABLE jobs executed by role=pg-migrator (deploy #4821 migration step 2/2) — statement detail elided by audit policy",
    "2021-11-08,,info,table jobs: 1742091 rows before alteration",
    "2021-11-08,,info,sequential inserts to jobs resumed after alteration (approx. 13300 rows over the following hours per WAL rate)",
    "2021-11-08,,warning,pg-migrator replay of reverse migration skipped: reverse step not defined in deploy #4821 manifest",
  ];
  writeFileSync(join(PLANE, "logs", "pg.log"), rows.join("\n") + "\n", "utf8");
}

// ---------- logs/app.log(纯噪声:无关错误/重连/GC——L3 噪声鲁棒性)----------
{
  const rows = ["offset_min,component,level,message"];
  const noise = [
    [-61, "canary", "warn", "canary pod restarted (liveness probe timeout, known flake CR-882)"],
    [-60, "canary", "info", "canary back online"],
    [-59, "web", "warn", "session store reconnect: 1 retry (redis-primary failover test window)"],
    [-44, "billing-web", "info", "deploy #4822 picked up new feature flags (12 flags changed)"],
    [-33, "worker-3", "info", "GC pause 412ms (normal for heap profile)"],
    [-21, "web", "warn", "upstream dependency billing-web slow response 1.2s (p99 window)"],
    [-9, "worker-1", "warn", "disk usage 71% on /var/lib (threshold 75%)"],
    [4, "web", "info", "rate limiter adjusted for incident traffic"],
    [11, "worker-2", "info", "GC pause 388ms (normal for heap profile)"],
    [22, "billing-web", "warn", "queue sink lag 40s (catching up after unrelated deploy #4822)"],
    [35, "canary", "warn", "canary pod restarted (liveness probe timeout, known flake CR-882)"],
  ];
  for (const [t, c, l, m] of noise) rows.push(`${t},${c},${l},${m}`);
  writeFileSync(join(PLANE, "logs", "app.log"), rows.join("\n") + "\n", "utf8");
}

// ---------- topology.json ----------
writeFileSync(join(PLANE, "topology.json"), JSON.stringify({
  format_version: 1, system: "ci-jobs-infra", level: "service",
  components: [
    { id: "api", kind: "api-gateway" }, { id: "distributor", kind: "dispatcher" },
    { id: "worker-pool", kind: "executor-pool" }, { id: "pg", kind: "database" },
    { id: "redis", kind: "cache" }, { id: "web", kind: "web-frontend" },
    { id: "billing-web", kind: "unrelated-service" },
  ],
  edges: [
    { from: "api", to: "distributor" }, { from: "distributor", to: "worker-pool" },
    { from: "distributor", to: "pg", note: "scan + dispatch bookkeeping" },
    { from: "api", to: "pg" }, { from: "web", to: "api" }, { from: "web", to: "redis" },
  ],
}, null, 2) + "\n", "utf8");

// ---------- case.json ----------
writeFileSync(join(CASE, "case.json"), JSON.stringify({
  format_version: 1, case_id: "pm-001", tier: "l3-postmortem",
  title: "CI jobs stuck in not-running state after a deploy (postmortem replay)",
  source: {
    blueprint: "real postmortem: CircleCI 2021-11-08 jobs-stuck incident (danluu/post-mortems index)",
    telemetry: "SYNTHETIC REPLAY — 观测面为按 postmortem 叙述重建的合成遥测,非原始监控数据",
    original_id: "l3/pm-001",
  },
  symptom: `11 月 8 日上午,CI 平台的 job 大量停留在 not-running 状态,队列深度持续攀升并在 ${"T0"} 触发告警。job 被创建但从不下发执行;worker 池本身空闲。请定位根因(变更?数据?服务?)并解释:为什么 T+15 的回滚没有恢复分发。`,
  topology_entry: "plane/topology.json",
  plane_manifest: [
    { file: "plane/topology.json", desc: "组件清单与调用关系" },
    { file: "plane/metrics/job-queue-depth.csv", desc: "待执行 job 数与最老 job 年龄(分钟,T0 相对)" },
    { file: "plane/metrics/distributor-scan-rate.csv", desc: "distributor 扫描速率与校验失败行数" },
    { file: "plane/metrics/distributor-dispatch.csv", desc: "每分钟下发的 job 数" },
    { file: "plane/metrics/worker-cpu.csv", desc: "worker 池资源(含 GC)" },
    { file: "plane/metrics/api-latency.csv", desc: "api 面 p99 与 5xx" },
    { file: "plane/logs/deploy.log", desc: "部署/回滚审计(组件与目标,不含变更内容)" },
    { file: "plane/logs/distributor.log", desc: "distributor 运行日志(含校验错误明细)" },
    { file: "plane/logs/pg.log", desc: "pg 审计(仅日期,无时刻——原始审计策略如此)" },
    { file: "plane/logs/app.log", desc: "应用杂项日志" },
  ],
  answer_ref: "analysis/scoring/answers.jsonl#pm-001",
  conversion: {
    tool: "tools/gen-pm001.mjs(手工改装脚本,L3)", rule_version: 1,
    audit: "R1 时间归一 T0=告警;R2 泛型组件名+deploy 编号保留(合法变更线索);R3 [T-95,T+40];R4 根因细节(字段名/类型/污染机制)仅在托管答案——deploy.log 只见目标、distributor.log 只见现象、pg.log 只见'有 ALTER 且反向迁移未定义'且无时刻;R5/L3 噪声:无关 deploy #4822、canary 重启、GC/磁盘/重连噪声、误导信号(worker/队列服务/网络健康)",
    regen: "node tools/gen-pm001.mjs",
  },
}, null, 2) + "\n", "utf8");

console.log("pm-001 generated at", CASE);

# rdd_explore failure playbook

> Second-level reference: linked from `rdd_explore` error messages at failure
> time, not loaded before invocation. Each error already carries a one-line
> next step; this file holds the full recovery detail for the cases that need
> it. Read only the section matching your error.

## Invariants (true for every failure below)

- **The cache is never mutated by a failed call.** Registration happens only
  after a worker completes cleanly; a failed dispatch leaves `.rdd/exploration/`
  byte-identical. Retrying is always safe.
- **Hit-path failures degrade, never error.** A disabled or failed recall path
  (see `rankMeta.recallers[].status`) only shrinks the candidate pool; the tool
  still returns ranked results from the remaining paths.

## Worker terminal failures (`exploration worker ...`)

The dispatched subagent ended without a clean `completed` stop reason. The
error message embeds the worker's partial output when any exists — read it
first, it usually names the failing step.

| Stop reason | Meaning | Recovery |
|---|---|---|
| `aborted` | Cancelled (user interrupt / harness shutdown / parent signal) | **Do not auto-retry.** Ask the user whether they still want the exploration; if yes, call again (same query is fine — nothing was registered). |
| `error` / `failed` | The worker crashed (tool failure, environment error) | Retry **once** with the same query. If it fails again, narrow the query to one module or theme; after a third failure fall back to direct `grep`/`glob` exploration. |
| `max-tokens` | The worker hit its output limit mid-report | The query is too broad — the worker tried to explore too much. Retry with a narrower scope (one module, one flow), or split into two queries. |
| `refusal` | The worker declined the task | Rephrase once (plain, task-focused wording). Do **not** loop on refusals — after one rephrase, fall back to direct exploration and mention it to the user. |

## Structured result missing / incomplete

`exploration worker finished without a structured result` — the run ended
before the provider captured the JSON payload (registerMode `plugin` requires
the provider's `outputSchema` capability).

`exploration worker returned an incomplete structured result` — the payload
was captured but failed semantic minimums (non-empty key/brief/summary/full,
≥1 tag, ≥1 anchor file).

Recovery: retry once with the same query. If it repeats, the likely cause is a
provider/model boundary issue, not the query — report it to the user and
suggest either (a) switching the profile's `rdd-explore` row to
`registerMode: worker` (needs rdd-engine installed; see the plugin README
"registerMode 选择"), or (b) falling back to the engine CLI path
(`explore.cmd -Type search`).

## No rdd-engine skill directory found

`resolveEngineRoot` walked the whole candidate chain (config override →
project layouts → vendored assets → `~/.rdd/engine/current`) and found no
`references/exploration-guide.md`. This only happens on a broken installation.

Recovery: reinstall the plugin (`dsh plugin --profile <name> add
dsh-rdd-explore.tgz`) or set `engineRoot` in the `rdd-explore` row config to
an rdd-engine directory. Not query-related — do not retry with a different
query.

## Vector recaller disabled (`rankMeta.recallers[].name === "vector", status: "disabled"`)

Not an error: the vector path needs all four of `endpoint`, `model`,
`dimensions`, and `RDD_EMBED_APIKEY` in `search-config.json` / the
environment. The `warning` field names the missing pieces. To enable:
configure them (OpenAI-shaped embedding API), then run the engine's
`explore-store.cmd -Type embed-backfill` once to build `vectors.json` for
existing entries. Lexical recall keeps working meanwhile.

## When to stop retrying

Two consecutive failures of the same kind → stop, use direct `grep`/`glob`
for the current question, and tell the user which error persisted. The
exploration cache is an accelerator, never a dependency: every task is
completable without it.

# Cold Review Probes

Use this reference with `code-review` before writing the verdict. Apply
only the surface-specific probes matching the diff; record the reason for
excluded concerns together when they share one boundary.

Contents: [Full-Picture Gate](#full-picture-gate),
[Adversarial Probe Matrix](#adversarial-probe-matrix),
[Output Template](#output-template).

## Full-Picture Gate

Trace the changed flow before judging it:

- production subject under review, not just the test helper or script wrapper;
- entrypoints, transformations, persistence, queue/worker boundaries,
  transactions, graph writes, API/MCP/CLI outputs, docs, and CI consumers;
- package owner, upstream contract, downstream contract, and invariants at each
  hop;
- cardinality and hot-path shape for runtime, query, graph, storage, or CI
  paths;
- invalid, empty, duplicate, stale, mixed-case, numeric-scalar, partial-failure,
  retry, ordering, idempotency, cleanup, and rollback behavior;
- transaction scope, lock scope, worker/concurrency scope, conflict domain, and
  idempotency key;
- operator-facing signal proving failure, no-regression, or successful recovery;
- source-of-truth artifact for each generated file, workflow trigger, CLI flag,
  OpenAPI/MCP/API shape, cassette, golden snapshot, and public report.

## Adversarial Probe Matrix

| Surface | Required probe |
| --- | --- |
| Workflow or gate registry | Compare every changed workflow path/filter, called script, fixture, manifest ref, and generated artifact against the local registry trigger. Prove a change to each referenced input selects the intended gate. |
| CLI/API/MCP contract | Run or statically validate the exact advertised argv, flag, route, schema, response shape, and output mode. Path-only tests are insufficient. |
| Public report or redaction | Test strings, numbers, mixed case, nested scalars, URLs, hostnames, account-like IDs, and unrelated metadata that should not classify as evidence. |
| Hot table, migration, or DDL | Prove first and repeated application on a populated supported backend, lock behavior, concurrency mode, rollback/retry behavior, and bootstrap/restart interaction. Inspect internal or index-backed result cardinality where possible; do not accept `IF NOT EXISTS` or unchanged domain-row counts as idempotency evidence. |
| Performance or query path | Compare before/after on the same input shape, include cardinality, plan/trace/buffer or p95 evidence, name the stop threshold, and **prove the measured SQL/function is the exact statement executed by the production caller** (not a whole-chunk helper or test twin). |
| Live/integration test harness | Prove cleanup happens before resources close, failures are not ignored, fixtures are isolated, reruns cannot leave durable state, and **grep untouched `*_live_test.go` siblings in every modified package** so DSN-less `t.Skip` never masks broken live assertions. |
| Generated, cassette, golden, or manifest | Prove source-of-truth regeneration path, watcher coverage, stale deletion behavior, and consumer readback. |
| Queue, worker, retry, or concurrent write | Prove idempotency key, conflict domain, claim/lock ordering, duplicate delivery, retry scope, dead-letter behavior, and contention impact. |
| Declared contract (env var, client dial, port, listener, flag) | Name the live reader, server, or listener for every declared setting, dial, and port the diff adds or enables. A declared-but-unwired contract — a setting with no reader, a dial with no live-server test, a port with no listener — is a blocking finding. Tests that pass without touching the production subject do not count. |
| Refactor or anti-slop / reader load | Confirm a behavior-pin existed before moving structure, check the 30-second test (*where does X come from and what can change it?*), and flag single-caller wrappers, speculative guards on impossible states, or narrating/workaround comments. |
| Blast radius (high-risk diff) | Name the single safety fact that clears the widest downstream risk (wire/DB format, goroutine teardown, 3-hop callers, feature flags) and prove it by running code against the real subject (step 4/5 of the [interrogate](../../../core/interrogate/SKILL.md) blast-radius ladder), or explicitly mark it `unproven`. |

## Output Template

This is an evidence checklist, not a mandatory verbosity level. Group clean
passes and inapplicable surfaces with reasons; retain every required result,
finding disposition, and stale-input condition from the skill entrypoint.

```text
Eshu code review verdict: self-review|separate-review
Base/head: <base>..<head>
Review packet inspected: yes|no
Reviewer mode: read-only|self-review
Proof tier decision: <one tier>
Why sufficient: <rationale; name cassette/golden assertions or missing runtime condition>

Proof already established:
- <facts proven by current diff/tests/checks; no praise, only evidence>

Full-picture gate:
- flow traced:
- ownership and upstream/downstream contracts:
- cardinality/hot path:
- edge/concurrency/rollback model:
- operator evidence:

Pass 0 - Scope, ownership, and diff integrity:
- Findings: <pass, class, severity, confidence, disposition, file:line, rule/skill, fix>

Pass 1 - Correctness and truth:
- Findings: <pass, class, severity, confidence, disposition, file:line, rule/skill, fix>

Pass 2 - Performance and storage/query shape:
- NornicDB pinned/current source checked: <image/tag/digest and source commit/docs>
- Expected fast paths/fallbacks: <flags and evidence>
- Findings: <pass, class, severity, confidence, disposition, file:line, rule/skill, fix>

Pass 3 - Reliability, concurrency, security, workflow hygiene:
- Findings: <pass, class, severity, confidence, disposition, file:line, rule/skill, fix>

Pass 4 - Hostile read and abuse cases:
- Findings: <pass, class, severity, confidence, disposition, file:line, rule/skill, fix>

Cross-pass comparison:
- Contradictions/repeated findings:
- Eshu failure classes checked:
- Hostile-read classes checked:
- Adversarial probes checked:
- Generated artifacts checked:
- Private-data/AI-attribution scan:
- GitHub review threads checked:
- GitHub check rollup checked:
- Follow-on validation required:

Disposition:
- P0=<n>, P1=<n>, P2-blocking=<n>, P2-deferred=<n>, P3=<n>
- Fixed/reviewed again:
- Deferred follow-ups:

Verification evidence inspected:
- <commands and runtime proof>

Final readiness:
- ready to push/create PR/merge: yes|no
- latest GitHub truth timestamp:
- verdict becomes stale if:
```

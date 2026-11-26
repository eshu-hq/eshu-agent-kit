# Proof Tier Selection

## Proof Tier Decision

Compute the proof rows first ([proof-matrix.md](proof-matrix.md)): one row
per touched surface, from the changed paths. Then select, per surface, every
tier whose evidence the in-scope claims need, and explain why. A change can
owe several tiers at once (a queue rewrite owes unit, race, live-backend
contention, and scaled proof together); satisfying one row discharges no
other, and naming one overall tier for the diff is how the expensive rows
used to disappear. If cassette proof is sufficient for a row, name the exact
cassette/golden assertions that would fail on the bug. If it is not sufficient
for behavior changed by the PR, name the missing runtime condition and block
merge until the stronger gate runs. Link or create a follow-up only when the
stronger proof is genuinely outside the PR scope and the current PR does not
claim that condition is proven.

| Tier | Use when |
| --- | --- |
| Unit/static proof enough | Documentation and agent guidance, pure helper logic, parser-local behavior, generated string construction, or small contract code with no projected truth or runtime coupling. Guidance changes need semantic review of the instructions as well as the docs build and `make pre-push` static-analysis gates. |
| Cassette/golden replay required and sufficient | Deterministic fact emission, reducer/projector truth, API/MCP response shape, capability truth, dead-code classification, cross-repo liveness, stale generations, tenant/repo scope boundaries, or no-provider-key evidence is covered by committed replay inputs and golden assertions. |
| Backend-required cassette/replay required | Correctness depends on real NornicDB/Neo4j behavior, Cypher dialect support, schema/index behavior, planner/hot-path eligibility, or exact emitted query shape against a live graph backend. |
| Scaled/performance replay required | Small replay may be correct but cardinality, fanout, queue depth, batching, graph write budgets, Postgres indexes, or p95/p99 latency can fail. |
| Full remote corpus required | Live collector behavior, clone/discover/parse cost, provider credentials, cross-service startup/restart behavior, image/runtime version drift, pprof/resource attribution, or queue-terminal guarantees are load-bearing. |

Wrong proof tier is a P1 unless it could ship wrong graph/query/deployment truth
or private data, in which case it is P0. The same grades apply per row: a
computed proof row left missing or skipped (a skipped live test counts as
missing) on a touched surface is that P1 or P0, never a deferrable P2 — see
[proof-matrix.md](proof-matrix.md#severity-of-an-undischarged-row).

## What counts as evidence

A proof row is `satisfied` only by evidence that meets all of these:

- **A bug fix has a regression test that fails before the fix** and passes
  after it. A test that would pass without the fix is a false-green test.
  Done when the verdict names the pre-fix failure or the mutant below.
- **A test guards only what it pins.** For each new assertion on text, a
  pattern, or a count, ask whether an edit past the matched part (a clause
  appended, a branch added, a value changed after the match) would still
  pass. Unanchored patterns and "at least one" counts are the usual holes.
- **An expected value copied from the code is a tautology.** Derive
  expectations from an independent source (a fixture intent, a spec, a
  hand-computed case), never from the implementation under test or a copy
  of its own data.
- **A performance claim has a before and after** on the same corpus, input
  shape, topology, and start/end events, with exact figures. A mechanism
  description ("it uses the index now") is a claim, not proof.
- **Evidence postdates the last edit** it is offered for. A green run from
  before the final change proves nothing about the final change.
- **Exit codes are captured directly.** `cmd; echo $?` is evidence;
  `cmd | tail; echo $?` reports the exit status of `tail`.
- **Flaky or timing-based proof is not proof from one passing sample.**
  State the number of runs and what makes the result stable.
- **A check that silently skips without a credential, database, or
  service** needs a hermetic structural guard that runs everywhere, or its
  row is `skipped` (counts as missing) in the matrix.

## The mutation challenge

For every new or changed test, name the single production change that
should make it fail. Where the reviewer can run code, make that change in a
scratch copy (never the working tree), run the test, and record whether it
failed. A test that survives its mutant does not guard that behavior: the
usual causes are a missing assertion, an assertion on the wrong value, or
dead code. Where code cannot run, trace which assertion the mutant would
break and record the mutant as not checked, with what stopped it. Done when
the verdict lists each mutant tried and its result, or the traced assertion
for each one not run.

Pressure scenarios reviewers must distinguish:

- Dead-code semantics: cassette/golden replay is sufficient only when the
  library asserts live-by-consumer, unknown ownership, stale generations,
  cycles, tenant boundaries, API/MCP parity, evidence citations, confidence
  labels, and candidate bucket items.
- Graph write/retract timeout fixes: normal cassette truth is not enough;
  backend-required or scaled proof must expose graph-write timeout budgets.
- Reducer, materialization, or search-index long poles: replay can expose queue
  truth, but scaled or full-corpus proof is needed for latency and pprof.
- Parser regressions: collector cassettes are insufficient when they replay
  after collection or parse instead of exercising the broken parser path.
- Bootstrap or DDL restart waits: require fault-injection or live runtime
  restart proof rather than ordinary replay.
- Backend image or optimizer upgrades: cassette/golden replay proves functional
  truth, but backend-version, hot-path, startup, and performance proof need
  stronger validation.

## Seeded-violation proof for a new or tightened gate

A new or tightened gate, validator, or guard is not proven by a green run
alone — a green run also happens when the check never fires. Require a
seeded-violation RED/GREEN pair: plant the exact violation the gate exists to
catch, show the gate fails on it, then show the same gate passes on the clean
tree. A guard whose only proof is a comment describing what it checks, or a
test built from a copy of the guard's own data or implementation, is not
proof — it can pass unconditionally regardless of whether the check runs at
all. This is the repo's most recurring defect class in review: a tautological
guard satisfied by its own restatement rather than by an independent
violation.

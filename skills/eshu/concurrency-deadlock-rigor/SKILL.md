---
name: concurrency-deadlock-rigor
description: Use when changing Eshu workers, leases, retries, claim or lock ordering, or other shared state whose correctness depends on interleaving. Defines the replay/retry matrix and the contention proof required.
---

# Concurrency And Deadlock Rigor

Scope: this is the `eshu` layer of the kit. Root `AGENTS.md` section links resolve against the kit's `AGENTS.md`; the Eshu-process sections they name land with consumer cutover.

Use this skill when correctness depends on ordering, isolation, coordination, or
shared-state access. Do not change concurrent behavior from intuition. A
queue/lease/claim change is in scope for root
[Prove-The-Theory-First](../../../AGENTS.md#mandatory-prove-the-theory-first):
prove the theory with the cheapest shim before implementing or dispatching it.

Add `performance-rigor` when changing concurrency to improve throughput,
queue drain, bootstrap wall time, or resource use.

## Mandatory Reasoning

Before proposing or implementing a non-trivial change, MUST identify:

- workflow stages and entrypoint
- shared state and conflict domains
- transaction boundaries
- retry boundaries
- lock, claim, or write ordering
- idempotency keys
- deadlock, race, starvation, duplication, and stale-work hazards
- observability that reveals contention and progress
- verification that proves the unsafe overlap is gone

## Workflow

1. Draw the sequence. Include producers, queues, leases, workers, graph/Postgres
   writes, retries, acknowledgements, and downstream consumers.
2. List contested resources at the resource level, not just service level:
   tables, rows, keys, graph nodes/relationships, leases, files, caches, or
   external APIs.
3. Separate transaction scope from retry scope. Name what can repeat and what
   must be idempotent.
4. Analyze ordering. Write down the bad interleaving when a deadlock or race is
   plausible.
5. Check actual system semantics. MUST use official docs or source for database,
   queue, or runtime guarantees when they affect the design.
6. Prefer fixes that remove unsafe overlap by design: readiness gates,
   ownership separation, conflict-domain partitioning, durable coordination, or
   explicit sequencing.
7. Preserve useful concurrency. Lower worker counts, smaller batches, longer
   timeouts, and more retries are diagnostics or temporary mitigations, never a
   shipped fix for a non-idempotent write, `MERGE` race, or uniqueness
   conflict — see root
   [Serialization Is Not A Fix](../../../AGENTS.md#serialization-is-not-a-fix)
   for the accepted exceptions and their proof bar.

## Replay And Retry Matrix

For queue, recovery, replay, or dead-letter changes, tests MUST cover every
owned dispatch variant, not one representative query or handler. Include:

- duplicate delivery of already-succeeded work
- stale state replay after partial projection
- retry preserving transient failures without overwriting terminal state
- dead-letter replay returning to the intended queue state
- concurrent workers touching the same conflict domain
- empty or already-drained queue state
- a claim/lock/lease rewrite that relocates `FOR UPDATE` off the
  predicate-bearing SELECT onto an id-join lock CTE: under Read Committed the row
  lock re-runs only the locking level's quals (EvalPlanQual recheck), so re-apply
  the row-self lease/status/visibility predicates on the locked relation and prove
  a row another worker claimed and committed between snapshot and lock is dropped.
  Row-set equivalence does NOT cover this.

### Producer And Consumer Proof

A queue defect is never proven fixed from one side: the producer can enqueue
exactly what the consumer cannot handle, and the consumer can mishandle exactly
what the producer wrote correctly. Every queue fix therefore ships three tests,
repro-first:

1. A reproducer of the reported defect that fails before the fix and passes
   after, on the same input. Done when the pre-fix run is red and the
   post-fix run is green.
2. A producer-side test at the enqueue boundary: payload shape, ordering,
   idempotency keys, lease and claim terms. Done when the malformed or
   duplicate enqueue the defect allowed is now rejected or deduplicated.
3. A consumer-side test at the dequeue boundary: handling, acknowledgement,
   retry, and dead-letter routing. Done when the poison, duplicate, or stale
   message the defect mishandled now lands in the intended state.

Where each test lives follows the defect, not the symptom:

- Defect in shared in-flight mechanics (materialized edges, determinism, the
  contract layer) is pinned in `go/internal/ifa`, beside the mechanism it
  covers.
- Defect in what one side writes or reads lives beside that producer or
  consumer. A defect spanning the boundary gets tests on both sides; never
  cover a two-sided defect with only the side that was easier to test.

## Observability

Concurrency-sensitive paths MUST expose enough telemetry to answer:

- what is blocked or retrying
- which conflict domain is hot
- how long claims, transactions, and retries take
- whether stale or duplicate work committed
- whether progress resumed after coordination

## Repo Enforcement

Concurrency changes are not complete with only a safety argument. If the diff
touches workers, leases, queues, batching, channels, goroutines, retry loops, or
claim behavior, run:

```bash
scripts/test-verify-performance-evidence.sh
scripts/verify-performance-evidence.sh
```

The PR must include a tracked evidence note with one of `Performance Evidence:`,
`Benchmark Evidence:`, or `No-Regression Evidence:` plus either
`Observability Evidence:` or `No-Observability-Change:`. The note must name the
conflict domain, worker/lease settings, before/after queue or row counts, and
the metric/span/log/status signal that shows progress, blocking, retries, and
failure class.

## Done Criteria

- The actual conflict domain is named.
- Transaction and retry scopes are separated.
- The fix removes unsafe overlap rather than only reducing its frequency.
- Useful unrelated concurrency is preserved where possible.
- Tests, load checks, or failure injections prove the design.
- Remaining risk is stated plainly.

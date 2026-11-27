# Performance Proof Plan

## Proof Ladder

Select the stopping rung before implementation from the changed contract and
acceptance criteria. Preserve input semantics and record each required result
before escalation. Local optimizations need representative exactness, applicable
concurrency proof, and a built-binary replay; a full-corpus run is required only
when the acceptance criteria or a repo-scale claim requires it. This selection
does not waive repository gates, explicit issue requirements, or real scale risks.

1. **Theory shim.** Use `EXPLAIN (ANALYZE, BUFFERS)`, Cypher `PROFILE`, a
   microbenchmark, or a throwaway query against representative worst-case data.
2. **Exactness.** For output-preserving work, prove bidirectional set difference
   0/0, identical ordered output, or equivalent counts. For a behavior fix,
   prove the explicit expected delta.
3. **Concurrency.** For claims, locks, leases, queues, DDL, or shared writers,
   prove contention, retry, idempotency, ordering, and failure recovery. Set
   equivalence alone is insufficient. Index and constraint candidates must
   prove first application, identical reapplication, restart/bootstrap
   behavior, and rollback on an isolated populated store. A fast first build
   does not authorize production DDL when repeated application mutates backend
   index state.
4. **Built-binary bounded replay.** Rebuild the production binary and run the
   worst-case repository, partition, scope, or backlog. Query-shape proof does
   not establish wall time.
5. **Small corpus, when scale or integration coverage is needed.** Progress
   through a representative large repository and small/medium proof before the
   credential-free 20-25 repository or equivalent bounded corpus. Verify
   graph/content/API truth.
6. **Full corpus, when required by acceptance.** Run once only after the
   previous rungs pass and the [scaled-run preflight](scaled-runs.md) matches a
   named baseline profile.

If a rung disproves the hypothesis, record it in the hypothesis ledger and do
not implement or retain an optimization justified by that hypothesis. A rejected
hypothesis is a valid result.

## Ordered Optimization Mantras

Try earlier categories before later ones and stop as soon as the target is met:

1. Don't do it (eliminate unnecessary work).
2. Don't do it again (cache/reuse/deduplicate).
3. Do it less (batch, narrow scope, push down filters).
4. Do it later (defer off the critical path).
5. Do it when nobody is waiting (background/precompute).
6. Do it concurrently (only after eliminating shared mutation).
7. Do it cheaper (micro-optimize hot loops and allocations last).

## Benchmark Sanity Check (Explain The Number)

Before reporting or acting on any measured speedup, regression, throughput, or
latency number, answer all seven questions (missing limiter, untuned baseline,
or unchecked error/work counts makes the verdict `INCONCLUSIVE`):

1. **Why not double?** Name the concrete limiter from an actual profile or
   counters during a run (CPU, lock wait, network RTT, DB I/O, GC) — never from
   reading code alone. Keep timing runs unprofiled and profile separately.
2. **Was both sides tuned fairly?** Confirm baseline and candidate ran with
   matched config, warmup, pool sizes, and flags.
3. **Did it break physical or Amdahl limits?** Check the math against core
   count, bandwidth, and the fraction of end-to-end time the stage occupies.
4. **Did it error?** Verify error, retry, and dead-letter counters are zero (a
   fast error path is not a speedup).
5. **Does it reproduce?** Run at least 5 alternating A/B trials and report run
   count, median, and spread (stop if noise exceeds the effect).
6. **Does it matter end-to-end?** Report the stage's share of total wall time
   beside any microbenchmark win.
7. **Did the work actually happen?** Check work-done counters and output hashes
   to rule out skipped, cached, lazy, or compiler-elided work.

For multi-iteration optimization runs (hillclimb), freeze a sensitivity-proven
harness first, set both a metric target and a minimum attempt floor (so a noisy
early run cannot trigger premature stop), test one hypothesis per iteration,
commit only wins that beat noise and pass correctness, and revert misses cleanly.

## Timing Proof Rules

A wall-time or ratio gate follows three rules from #7127 PR-3d. The reasoning
and evidence are in
`[fill-in: timing proof rules — this repo's wall-time proof rules]`.

- **Own the host.** Pause every other gate, build, and live suite while it runs.
  Declare a quiet host, and require load1 below half the CPU count at the start,
  at the end, and as the in-run maximum. Run the unchanged base binary as a
  control canary each round; a control over its bound voids the round.
- **Derive the bound.** Set it outside the estimator's measured spread on
  unchanged code, from at least two prior sets. Report same-round ratios with
  mean and SD beside any ratio of medians. Prefer plan and buffer checks the
  host cannot move.
- **Tear down with a live context.** `t.Cleanup` must not use `t.Context()` for
  teardown I/O; it is cancelled before Cleanup runs. Use a background context
  with a timeout and report the error.

## Caller And Route Inventory

Before changing an index, readiness gate, cache, fallback, queue fence, or
shared state, inventory every caller and user-visible route. Search interfaces,
direct calls, indirect enrichment paths, pagination helpers, CLI, API, MCP,
background jobs, and recovery paths.

For each path state whether it:

- remains available;
- fails closed with a documented bounded error;
- uses a different exact index or scope;
- retries safely; or
- is intentionally outside the change.

Add tests for every distinct path class. Do not rely on final hostile review to
discover bypasses.

# Proof Matrix: Required Proof Per Touched Surface

A change does not owe one proof tier. It owes one proof row per surface it
touches, and satisfying one row discharges no other. This file computes those
rows from the changed paths so a local review and the reviewd daemon hold a
diff to the same floor: the requirement ids below are the ids reviewd writes
in `packet/proof.md`, and a local verdict carries the same rows so the two
reconcile line by line.

## Compute the rows

1. List the changed paths: `git diff --name-only <base>..<head>`. Done when
   every path in the list has been classified against the table below.
2. Collect the files that can evidence rows: test files (`_test.go`,
   `tests/`, `testdata/`), contract files (paths containing `openapi`,
   `golden`, `snapshot`, or `contract`, plus `.proto`), and diagram or
   architecture files (paths containing `diagram`, `.mmd`, `.puml`, or an
   architecture record). Done when each list is written into the packet,
   including when it is empty: "none" is a fact, not an omission.
3. Give every triggered row one status: `satisfied`, `missing`, `skipped`,
   or `not_applicable`. Done when no triggered row lacks a status and its
   evidence or reason.

| Requirement | Trigger (any changed path matches) | Evidence that discharges it |
| --- | --- | --- |
| `focused-tests` | Any source or test file; also behavior-bearing Markdown (below) | Focused tests for the changed packages ran and passed after the last edit, and a new or changed test would fail on the behavior it guards (name the mutant or the pre-fix failure) |
| `race` | Queue/claim/lease/reducer/projector paths, or in-process shared state (`poller`, `worker`, concurrent paths) | The changed packages pass under `-race`, with the shared state exercised concurrently, not only sequentially |
| `live-postgres` | `postgres`, `migration`, or `.sql` paths; in Eshu also live graph-backend behavior (Cypher dialect, planner, schema/index) | Live tests against the real database or graph backend ran on this head — not skipped for a missing DSN or credential |
| `contention` | `queue`, `claim`, `lease`, `reducer`, or `projector` paths | Real-dependency contention proof at the [at-scale shape](#the-at-scale-shape-for-queue-and-producer-consumer-rows) below |
| `producer-consumer` | `enqueue`, `reducer`, `projector`, `ingester`, or `projection` paths | A producer-to-consumer proof at the at-scale shape: emitted and re-emitted input converges to the consumer-visible result and the system quiesces |
| `scaled-perf` | `reducer`, `projector`, `materializ`, `cypher`, `queryplan`, `storage/`, or `ingester` paths | Before/after on the same corpus, topology, and start/end events at production-like cardinality, with the budget and its provenance |
| `contract-golden` | `openapi`, `schema`, `golden`, `snapshot`, or serialization paths — **or an API surface** (route wiring, `api`/`httpapi` packages, MCP paths, handlers in `query`/`api`/`http` trees) | Committed contract/golden assertions pin the exact output shape. When an API surface changed: the contract change is in this diff, or the row cites the existing contract entry that already covers the new operations and shapes. A domain work handler (a reducer handler) is not an API surface |
| `flow-diagram` | `queue`, `reducer`, `projector`, `ingester`, `pipeline`, or `.github/workflows/` paths | If flow topology changed (below), the owning diagram or architecture record changed in this diff; otherwise the reason the topology is unchanged |

Documentation-only changes owe no rows. One exception: **behavior-bearing
Markdown** — text a binary embeds or an agent loads at runtime (prompt
modules, templates, skills, agent-rule files) owes `focused-tests` and
`contract-golden`, because editing it changes behavior and its contract is
what tests and recorded hashes pin.

**Flow topology** changes when a pipeline stage is added, removed, or
reordered; an edge changes (a queue, store, claim/lease path, retry or
dead-letter route); an ownership boundary moves; or a producer/consumer
pair changes who emits or who reads. Work inside one stage is not topology.

## Row statuses

- `satisfied` needs named evidence: the check or command, its result, and
  proof it postdates the last edit. A CI check *name* is a lead, not proof:
  confirm the changed code's tests were selected and did not skip (the
  check's own events or logs show this where they exist).
- `skipped` means the proof exists but did not run — a DSN- or
  credential-gated live test under a green package run is the usual case.
  **Skipped counts as missing.** Name what would run it.
- `missing` means no such proof ran or exists for this change.
- `not_applicable` needs the concrete reason the surface is not really
  touched. "Small change" is not a reason.

Expected versus ran is part of the row: state which CI checks the touched
surfaces should have produced on this head and which the rollup actually
shows. A scheduled-only gate (for example a contention or golden-corpus
lane that runs on main, not on PR heads) is never ran evidence for this
head, however green its last scheduled run was.

## Severity of an undischarged row

A row left `missing` or `skipped` on a surface this change touches is a
finding, anchored on the nearest changed line of that surface:

- **P1** by default. It is the severity table's "required proof tier not
  run" made row-sized.
- **P0** when the unproven path could ship wrong stored or projected
  truth, a re-ingestion loop, a deadlock, data loss, or private data.

It cannot be discharged by deferral: a follow-up lane, a scheduled gate, or
a linked issue does not convert it to a deferrable P2 under
[merge-bar.md](merge-bar.md), because the change itself is unproven where
it can break. Genuine missing coverage on code this change does not touch
is a different finding (P2 by the merge bar); do not tax this author for
the repository's history, and do not let a present-but-worthless test
satisfy a row — a test that passes on the unfixed code is `false-green`,
graded on its own.

## The at-scale shape for queue and producer-consumer rows

`contention` and `producer-consumer` rows are satisfied only by proof at a
production-shaped scale. All five conditions, or the row stays open:

1. **Re-ingestion is in the input**: the same facts replayed, rescanned, or
   re-pended, proving idempotency and quiescence.
2. **A real backlog**: enough queued work that claim ordering, fairness,
   batch rank, and lease expiry actually contend.
3. **A hot key or high cardinality**: the input shape that turns a fine
   query into a mass scan is present.
4. **Real dependencies under concurrency**: multiple workers against real
   Postgres or the graph backend, exercising the actual claim, lock-recheck,
   and lease-reclaim paths. Fakes and pure replay cannot prove this row.
5. **A consumer-side budget**: final state equality plus a wall-clock or
   throughput bound, not only eventual correctness on a toy input.

Done when the verdict's row cites the test or run that carried all five, or
names which condition is unproven and grades the row above.

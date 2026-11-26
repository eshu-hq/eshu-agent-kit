---
name: correlation-truth
description: Use when reducer, projector, or query changes turn evidence into graph truth -- workload/service materialization, admission, or deployment tracing. Requires positive/negative/ambiguous proof and direct graph checks.
---

# Correlation Truth

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths, `eshu-*` skill names (all renamed by now; see `skills/registry.md`), and eshu repo tooling (`scripts/`, `specs/`, `make`, `ci-gates`) resolve in the consuming repo checkout (see `skills/registry.md`).

## Overview

Use this skill for reducer and query work where evidence becomes canonical graph
truth. The goal is not "tests pass"; the goal is "the graph tells the truth and
the query surfaces say the same thing."

## When to Use

- Reducer changes in `go/internal/reducer` (cross-domain materialization, admission)
- Projector changes in `go/internal/projector` (canonical graph write, phase publication)
- Query truth changes in `go/internal/query`
- Graph write or relationship projection changes
- Workload classification, admission, or materialization changes
- Deployment tracing, service story, or repo story changes
- Correlation fixture or compose verification changes

Do not use this skill for ordinary CRUD or isolated UI work.

## Required Thinking Order

1. Trace the full path: raw evidence -> candidate -> admission ->
   materialization -> graph write -> query surface.
2. Name the invariants before editing. Example: "deployment repos must remain
   provenance-only" or "controller-only repos must not materialize as services."
3. List the edge classes that could falsify the change before writing code.

## Mandatory Proof Matrix

Cover every row in [proof-matrix.md](references/proof-matrix.md) on a non-trivial change.

## Workflow

### 1. Read the local docs first

Read, pulling the extraction target named per doc:

- `docs/public/reference/local-testing.md` → the pre-push floor and the
  fresh-compose rule for fixture changes
- `docs/public/run-locally/docker-compose.md` → the compose rebuild/restart
  sequence that makes a verification fresh
- `docs/public/reference/telemetry/index.md` → which span/metric/log proves
  the runtime behavior changed

### 2. Write the failing proof first

Add or update focused tests before implementation. Prefer targeted reducer or
query tests that show the exact false positive, false negative, or ambiguity.

### 3. Implement the smallest truthful fix

Do not patch query output to hide graph problems. Fix the actual stage that is
wrong:

- extraction
- correlation
- admission
- materialization
- graph projection
- query synthesis

### 4. Verify in layers

Run focused package tests first, then a fresh compose verification after the
last logic patch. A stale container or stale reducer run is not valid evidence.

Required layers:

- Focused Go tests for touched packages
- Fresh compose rebuild/restart verification when fixture truth changed
- Direct graph check of canonical nodes and edges
- API/query checks for repo context, service context, and deployment trace
- Markers and gates: `performance-rigor` owns the evidence-marker format
  and the verify scripts; follow it for hot-path graph, reducer, queue, or
  materialization changes.

### 5. Reconcile disagreements

If tests pass but the graph is wrong, the change is not done.
If the graph is right but the query surface lies, the change is not done.
If repo context and service context disagree, the change is not done.

## CI Gates That Enforce This

These are blocking gates in `specs/ci-gates.v1.yaml`. They are part of what
`required-gates-complete` (plus `go-core-complete`/`go-race-complete`) waits
on in CI, and each has a `local.command` you can run directly to reproduce a
red result:

- `ifa-materialized-edge-coverage` -- materialized-edge family exhaustiveness
  across `go/internal/ifa/materializededges`, `go/internal/reducer/...`, and
  `go/internal/storage/cypher/...`.
- `ifa-determinism` -- the graph-determinism matrix; a non-idempotent write
  that only shows up on retry fails this, not a one-shot test.
- `ifa-contract-layer` -- reducer contract-layer coverage
  (`go/internal/ifa`, `go/internal/reducer/...`).
- `golden-corpus-gate-neo4j` (B-7 on Neo4j) -- end-to-end replay proving collector fact
  emission, graph write, and query/MCP response shape agree; see
  `golden-corpus-rigor` for cassette/snapshot mechanics.

Do not guess a gate's script name -- look up its `local.command` (and
`test_command`) by `id` in `specs/ci-gates.v1.yaml` before running it:

```bash
(cd go && go test ./internal/reducer/... ./internal/projector/... ./internal/query/... -count=1)
rg -n -A 8 'id: ifa-(materialized-edge-coverage|determinism|contract-layer)' specs/ci-gates.v1.yaml
```

## Direct Graph Truth Checks

Use direct graph inspection whenever correlation truth is in question. Confirm:

- which repositories define workloads
- which workloads materialize instances
- which deployment relationships exist
- which environments and platforms are actually present

Do not infer truth from logs, confidence scores, or reducer completion alone.

## Anti-Patterns

- Treating reducer completion timing as proof that the logic is correct
- Inventing default environments, platforms, or instances without evidence
- Letting broad provenance like raw `k8s_resource` or raw `argocd_application`
  over-admit workloads
- Validating only one happy-path service repo
- Accepting repo-name or namespace coincidence as deployment truth
- Fixing API output while leaving the graph semantically wrong

## Failure And Recovery

- **When tests pass, but direct graph inspection or query output disagrees:** trace the record from extraction through correlation, admission, materialization, and projection; fix the owning stage rather than patching API output, then recover with a fresh compose run.
- **When a stale container or reducer run hides a regression:** rebuild and restart compose from a clean state after the final logic patch before accepting graph or API output as proof.
- **When `ifa-determinism` fails on retry while one-shot tests pass:** inspect the graph write for non-idempotent edge/node mutation or order-dependent state, fix the projection write, and rerun the gate's `local.command` from `specs/ci-gates.v1.yaml`.

## Done Criteria

The change is done only when:

- tests prove the positive, negative, and ambiguous cases
- direct graph inspection matches the intended model
- repo context, service context, and deployment trace tell the same story
- you can explain why adjacent repo families did not regress

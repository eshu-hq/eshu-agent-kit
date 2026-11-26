---
name: golden-corpus-rigor
description: Use when collector fact emission, reducer/projector graph writes, or query/MCP response shapes change and must pass the B-7 golden-corpus gate. Update testdata/cassettes/ and the B-12 snapshot together.
---

# Golden Corpus Rigor

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths, `eshu-*` skill names (all renamed by now; see `skills/registry.md`), and eshu repo tooling (`scripts/`, `specs/`, `make`, `ci-gates`) resolve in the consuming repo checkout (see `skills/registry.md`).

The B-7 golden-corpus gate is Eshu's golden standard: it replays fixed inputs
through the real pipeline (`sync -> discover -> parse -> collect -> reduce ->
project -> query`) and asserts the resulting graph and query truth against a
committed contract. Two artifacts ARE that contract:

- **Cassettes** — `testdata/cassettes/<collector>/supply-chain-demo.json`: the
  recorded facts each credentialed collector replays (credential-free).
- **B-12 snapshot** — `testdata/golden/e2e-20repo-snapshot.json`: the required
  correlations, node/edge count tolerances, and HTTP + MCP query shapes the gate
  diffs against.

Both are driven by `go/cmd/golden-corpus-gate/` and run by
`scripts/verify-golden-corpus-gate.sh`.

## Operating rule

**If your change alters what the pipeline projects, update the cassette and/or
the snapshot in the SAME change, and prove it with the gate.** The gate exists to
fail when code and the golden fixtures drift — that is the feature, not a
nuisance. Do not "fix" a red gate by loosening an assertion; fix the code or
update the fixture to the new, correct truth under review.

## Does my change touch the golden corpus?

Ask this before you finish any change to these surfaces:

- **Collector fact emission** (`go/internal/collector/*`): new/changed fact kind,
  payload field, or evidence kind → the matching cassette must carry the new
  shape, or the gate runs against stale recorded facts.
- **Reducer / projector graph writes** (`go/internal/reducer/*`, `projector/*`,
  `storage/cypher/*`): new/changed node label, edge type, correlation, or
  property → add or adjust the snapshot's `required_correlations` / `node_counts`
  / `edge_counts` / required-node-property assertions.
- **Query or MCP tool response shape** (`go/internal/query/*`,
  `go/internal/mcp/*`, `go/cmd/api`/`go/cmd/mcp-server` wiring): new/renamed response
  field, a new tool, or a new mounted route → update `query_shapes.http` /
  `query_shapes.mcp`.
- **A new verb/ecosystem** (parser + collector + correlation): add a fixture
  and/or cassette that produces its edge, plus a required `rc-NN` that isolates
  it (see Cassette vs fixture, and the evidence-kind predicate below).

If yes to any, the change is not done until the gate is green with the updated
fixture.

## Cassette vs fixture (which input to update)

- **Live-collector edges** (anything replayed from the collectors listed in
  `collector_specs` in `scripts/verify-golden-corpus-gate.sh`: cloud, k8s, vault,
  OCI, package, terraform-state, prometheus, and the rest) come from **cassettes**.
  Change the recorded facts in `testdata/cassettes/<collector>/`, after
  confirming the collector is still listed in `collector_specs` there; if it
  is not, add fixture coverage instead.
- **Static-parse edges** (code, gitlab, atlantis, terragrunt, kustomize, ...)
  come from **fixture repos** under `tests/fixtures/ecosystems/`. Add/adjust the
  fixture file; there is no cassette for these.

## Cassette contract

- **`fact_kind` is replayed verbatim** (`go/internal/replay/cassette/source.go` sets the
  envelope kind to the JSON string as-is — no namespace transform). It must be
  byte-equal to the constant the consuming reducer matches (some families match
  an UNPREFIXED kind, e.g. `facts.VaultAuthRoleFactKind == "vault_auth_role"`). A
  mismatched/namespaced kind is silently **inert** — no error, zero nodes.
- **Cross-fact join keys are matched literally**, not re-derived. Linked facts
  (e.g. a vault role bound to a k8s service account) join on string-equal keys
  (`service_account_join_key`, `role_join_key`, ...). Use consistent synthetic
  values across the related facts; they are HMAC fingerprints in live collection
  but only need to be self-consistent strings in a cassette.
- **Synthetic/redacted data only.** NEVER commit real ARNs, account IDs, IPs,
  hostnames, or employer identifiers. The collector's redaction layer is why live
  recordings look synthetic; a hand-authored cassette must match that posture.
- A **0-node gate result is almost always a `fact_kind` or join-key mismatch**,
  not a graph-writer bug. Verify the projection emits nodes before blaming the
  writer.

## Snapshot contract

- **`required_correlations` (rc-NN)** are existence assertions; node/edge **count
  ranges** are cardinality assertions; **`query_shapes`** assert response truth.
- A new required correlation must be BOTH in the snapshot AND in the verify
  script's `-required-correlations` list, or it is silently not asserted (a
  **false green**). Shared edge types (DEPENDS_ON, DEPLOYS_FROM) need an
  `evidence_kinds` predicate to isolate a verb, not a per-tool edge type.
- **Calibrate count ranges to the real deterministic corpus**, not aspirations:
  floors that catch a major projection drop (e.g. #4019), ceilings wide for
  parser growth. Tolerances are asserted as **required** in full mode
  (`-graph-required-only=false`); advisory-tier entries assert nothing —
  promote one to required or delete it.
- **MCP query shapes** are asserted live over the MCP truth envelope; see
  `mcp-call-rigor` for the envelope and route-mount rules.
- **Governance-gated families assert `max: 0`.** The SecretsIAM graph projection
  is OFF by default (`ESHU_REDUCER_SECRETS_IAM_GRAPH_PROJECTION_ENABLED`, ADR
  #1314); never enable a governed feature just to satisfy a count.

## Validate

1. Update the matching cassette under `testdata/cassettes/<collector>/` or
   fixture under `tests/fixtures/ecosystems/` together with
   `testdata/golden/e2e-20repo-snapshot.json` (and `-required-correlations` in
   `scripts/verify-golden-corpus-gate.sh` for any new `rc-NN`) in the same
   change. Done when code and golden fixtures reflect the same intended truth.
2. Run the fast unit and static contract mirror, then the full live Docker B-7
   gate on Neo4j:

```bash
# unit + static contract (fast, no Docker) -- gate id: golden-corpus-mirror
cd go && go test ./cmd/golden-corpus-gate/ -count=1
bash scripts/test-verify-golden-corpus-gate.sh
# full live run (Docker): bootstrap + replay cassettes + drain + diff snapshot
# -- gate id: golden-corpus-gate-neo4j (B-7 on Neo4j), tier ci-heavy, blocking on
# required-gates-complete. golden-corpus-gate is the watch-only NornicDB leg.
ESHU_GRAPH_BACKEND=neo4j bash scripts/verify-golden-corpus-gate.sh
```

3. Confirm the full live run prints `N pass, 0 required-fail, 0 advisory-warn`
   and `PASS: B-7 golden corpus gate green`. Never run `docker compose down -v`
   while a gate run is live (it kills the run's backends). Done when the live
   gate exits 0 with your updated fixtures.

## Failure And Recovery

- **0-node gate failure:** inspect `fact_kind` verbatim spelling and cross-fact
  literal join keys in the cassette before blaming the graph writer; fix the
  mismatch and rerun `scripts/verify-golden-corpus-gate.sh`.
- **New `rc-NN` silently skipped (false green):** add the correlation ID to both
  `testdata/golden/e2e-20repo-snapshot.json` and `-required-correlations` in
  `scripts/verify-golden-corpus-gate.sh`, then re-verify with the mirror and
  live gate.
- **Count or shape diff fails after a pipeline change:** determine whether the
  code regressed or the snapshot drifted; fix the code or update the golden
  fixture under review rather than loosening tolerances, then rerun until green.

## Out of scope / related

- Editing the gate command itself or its evidence: see
  `go/cmd/golden-corpus-gate/AGENTS.md`.
- Cassette replay internals: see `go/internal/replay/cassette/AGENTS.md`.
- Hot-path Cypher/perf evidence on graph writes: add `cypher-query-rigor`.
- Correlation/materialization truth: add `correlation-truth`.
- Whether every compiled Go package the gate depends on is still in its own
  CI path filter: that is `golden-corpus-filter-exhaustive`, a separate
  self-checking gate over `.github/workflows/golden-corpus-gate.yml` and
  `scripts/lib/golden-corpus-filter-exclusions.txt`, not this skill's job.
- Offline cassette replay against a real NornicDB build (as opposed to the
  live Docker corpus run above) is the separate `replay-tier` gate
  (`scripts/verify-replay-tier.sh`, `testdata/cassettes/replayoffline/`,
  `testdata/cassettes/replaydelta/`).

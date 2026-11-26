---
name: telemetry-coverage-discipline
description: Use when adding a metric, span, log key, or pipeline stage, or chasing a missing operator signal, in go/internal/telemetry and the telemetry-coverage doc/gate.
---

# Telemetry coverage discipline

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths and eshu repo tooling (`scripts/`, `specs/`, CI gates) resolve in the consuming repo checkout (see `skills/registry.md`).

Keep operator signals consistent across these artifacts. Paths are relative to
the repository root.

| Artifact | Contract |
| --- | --- |
| Coverage doc | `docs/public/observability/telemetry-coverage.md`: each stage names a real signal or a justified marker. |
| Verifier | `scripts/verify-telemetry-coverage.sh` and its test mirror compare docs, registrations, and added stage-owner files (a Go file adding a pipeline stage needs its own coverage row naming the owning dispatcher). |
| CI gate | `telemetry-coverage` (blocking, `specs/ci-gates.v1.yaml`), job "Verify telemetry coverage gate" in `.github/workflows/static-contract-gates.yml`, enforces the verifier. |
| Dashboard | `docs/public/observability/dashboards/eshu-operator-overview.json` and its generator expose operator-facing signals, gated by the separate blocking `operator-dashboard` id in the same workflow. |

Metrics are registered in `go/internal/telemetry/instruments.go`. Dimensions,
span names, and log keys live in `contract.go` and `contract_*.go` there. Keep
names and instrument types intentional, labels closed and bounded, and emission
at the owning dispatcher. Update the public operator reference at
`docs/public/reference/telemetry/index.md` when its documented surface changes.

When existing signals diagnose a new path, use this positive assertion in its
coverage row and name at least one registered metric:

```text
No-Observability-Change: <existing eshu_dp_* signals>
```

A blank, TODO, or invented metric is invalid. For a new metric or stage, read
[the contributor workflow](references/new-metric.md).

## Evidence limits

A passing static verifier does not prove emission at runtime. It catches
registered/documented metric drift and added Go files without a coverage row.
It misses stages added inside existing files, old gaps, label cardinality
explosions, and metrics outside the telemetry package. Inspect the changed
emission path when those limitations matter. For missing signals or uncertain
coverage, consult the “Limitations Of The X2 Gate” section in
`[fill-in: telemetry precedent — this repo's telemetry incident precedent]`.
The guide owns historical incident links; do not duplicate stale inventories.

## Verification by affected surface

1. **Coverage, registrations, or stages:** run the coverage verifier against
   the reviewed base (and its test mirror when verifier logic or fixtures
   change); done when it exits 0:

   ```bash
   ESHU_TELEMETRY_COVERAGE_BASE=origin/main bash scripts/verify-telemetry-coverage.sh
   ```

2. **Dashboard, generator, or metric registry feeding panels:** add template
   variables to `OPERATOR_DASHBOARD_METRIC_VARS` when needed, run the generator
   test mirror, regenerate, and confirm a subsequent run produces no drift; done
   when both commands exit 0 and `git diff` is unchanged after the second run:

   ```bash
   bash scripts/test-generate-operator-dashboard.sh
   bash scripts/generate-operator-dashboard.sh
   ```

3. **Go emission changes:** run focused production-path tests and relevant Go
   gates; done when emission is verified on the owning dispatcher.
4. **Documentation changes:** run the repository docs build and
   `git diff --check`; done when both exit 0.

## Failure And Recovery

- **When `verify-telemetry-coverage.sh` fails on an undocumented metric or new stage-owner file:** register the metric in `go/internal/telemetry/instruments.go` (and `contract.go`/`contract_*.go`) or add the stage row (or `No-Observability-Change: <existing eshu_dp_* signals>`) in `docs/public/observability/telemetry-coverage.md`, then re-run the verifier until exit 0.
- **When `operator-dashboard` fails on drift or a missing variable:** add the metric variable to `OPERATOR_DASHBOARD_METRIC_VARS`, regenerate via `scripts/generate-operator-dashboard.sh`, and confirm a second run produces zero diff.

These are focused development checks. Required CI, hooks, docs, and promotion
gates still apply; do not rerun unrelated artifact suites merely because this
skill was loaded. Finish the scoped implementation and local proof before
publishing under the session's existing authorization.

---
name: security-scan-gates
description: "Use when a security-scan.yml job (Trivy, govulncheck, gosec, nancy) fails or a Go toolchain bump changes scanner results. Covers local reproduction, SARIF severity filtering, and #nosec rules."
---

# Security Scan Gates

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths, `eshu-*` skill names (all renamed by now; see `skills/registry.md`), and eshu repo tooling (`scripts/`, `specs/`, `make`, `ci-gates`) resolve in the consuming repo checkout (see `skills/registry.md`).

The `.github/workflows/security-scan.yml` jobs (Trivy fs, Trivy image,
govulncheck, gosec, nancy) fail in ways that do **not** reproduce with a naive
local run. This skill records the traps so the next Go bump or gate edit does
not cost another multi-hour diagnosis.

## Meta-rule: reproduce with the EXACT CI tool version + flags

Local-vs-CI drift was the single biggest time sink. Before concluding a gate is
clean:

- **Match the pinned tool version.** `aquasecurity/trivy-action@<v>` pins a
  specific trivy binary (e.g. v0.36.0 -> trivy 0.70.0; the run log prints
  "current version is 0.70.0"). A brew/`@latest` trivy can rate the same rule
  differently (its misconfig **checks bundle** is downloaded separately and
  versioned independently). Install the pinned version to reproduce.
- **Match the flags exactly**, including how they are passed (CLI flag vs the
  action's env var). A CLI `--severity` filter behaves differently from the
  action's `severity:` input — see the trivy trap below.
- **CI scans the PR merge commit** (`refs/pull/<n>/merge`), which folds in
  current `main`. Pull the exact findings from the uploaded SARIF:
  `gh api -H "Accept: application/sarif+json" repos/eshu-hq/eshu/code-scanning/analyses/<id>`
  and read each rule's `properties.security-severity` — the result `level`
  (note/warning/error) compresses the real score.
- A `-no-fail` local run does NOT prove the gate passes (it suppresses the exit
  code). Verify the gate the way CI does. Exception: the gosec SARIF
  count-gate in [gosec suppressions](references/gosec-nosec.md) is the one
  sanctioned `-no-fail` use — there the gate is the `jq` result count, not
  the exit code.

Re-check the run logs after any toolchain bump; version pins below rot fast.

## Scanner guides

- [Trivy](references/trivy.md): SARIF severity trap, `limit-severities-for-sarif`, fixture skip-dirs.
- [Go toolchain scanners](references/go-toolchain.md): govulncheck package mode, gosec SSA recovery, stdlib CVEs, nancy.
- [gosec suppressions](references/gosec-nosec.md): `#nosec` placement, G201/G202/G703 proof rule.
- [Workflow runs](references/workflow.md): `workflow_run` concurrency groups.

## Touching hot-path files triggers the performance-evidence gate

Edits under hot-path locations also trigger `scripts/verify-performance-evidence.sh` — `performance-rigor` owns the marker format and recognized evidence files; follow it. Note: a PR first past the hot-path step can surface pre-existing golangci-lint debt (oversized files, unused funcs) — fix that debt in the same PR.

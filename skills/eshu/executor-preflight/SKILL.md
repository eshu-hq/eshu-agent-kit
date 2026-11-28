---
name: executor-preflight
description: "Use as the last step before an executor hands a branch to a reviewer: shape-checks the PR body, re-measures its decision-bearing claims at HEAD, and clears the registry traps that static gates catch late."
---

# Executor Preflight

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths, `eshu-*` skill names (all renamed by now; see `skills/registry.md`), and eshu repo tooling (`scripts/`, `specs/`, `make`, `ci-gates`) resolve in the consuming repo checkout (see `skills/registry.md`). The shape check ships with the `publish` skill.

Run this on the final commit, before you hand a branch to a reviewer. It catches
the text and registry defects that otherwise cost one review round each.

It does not replace review, `make pre-push`, or promotion. The coordinator owns
those. You are a leaf agent: do not dispatch other agents.

## Steps

**Pre-Handoff Checklist:** commit first and run `scripts/preflight.sh` to bind `HEAD`/`BODY_SHA256` and execute the deterministic shape, registry, and TODO checks; re-measure every decision-bearing claim at `HEAD`; clear any failing trap (if `verify-license-header.sh` fails, run `bash scripts/add-license-header.sh`; if `verify-env-registry-doc.sh` fails, run `bash scripts/generate-env-registry-doc.sh`); never run `make pre-push` as a leaf executor.

1. **Bind the run and run deterministic checks.** Run
   [preflight.sh](scripts/preflight.sh)
   (`.agents/skills/executor-preflight/scripts/preflight.sh` in a consumer
   checkout) from the branch you are handing off:

   ```bash
   bash .agents/skills/executor-preflight/scripts/preflight.sh --repo . --body <pr-body.md>
   ```

   Add `--issue` for an issue draft, omit `--body` when no draft exists, or pass
   `--base <ref>` to override the diff base (`origin/main`, else `main`; an
   explicit base that does not resolve is an error). The script prints
   `HEAD=<sha>`, `BODY_SHA256=<sha256>` when `--body` is given, and
   `PASS`/`FAIL`/`NOT_CHECKED` rows for `bind`, `shape`, `license-header`,
   `live-tests-ledger`, `env-registry-doc`, `docs-cli-env-refs`,
   `test-todo-scan`, and `live-test-refs`. The `bind` row fails on a dirty tracked tree or a `HEAD`
   that moved during the run, so every result belongs to the printed `HEAD`.
   Exit 0 means no row failed, 1 means a row failed (its full output is on
   stderr), 2 means bad arguments or environment. Recovery: if it exits 1, fix
   the failing row, commit the fix, and re-run from this step. Done when the
   script exits 0 at the commit you are handing off.

2. **Check the shape.** Covered by the `shape` row of `scripts/preflight.sh`
   when `--body` is passed; you can also invoke
   `bash scripts/check-shape.sh --pr <body-file>` directly from the `publish`
   skill directory (`skills/eshu/publish/scripts/` in-kit,
   `.agents/skills/publish/scripts/` in a consumer checkout).
   Use `--issue` for an issue draft. Fix every `FAIL` line. Done when the exit
   code is 0. If no body exists, record this step as `NOT_CHECKED` with that
   reason.

3. **Re-measure the claims that bear on a decision.** List each contract
   claim, measured result, and statement of what a test or gate proves in the PR
   body and in the docs you changed — at most ~10 decision-bearing rows; group
   the rest by gate. Run a command at this HEAD for each one.
   Write the rows as `claim | command | measured | match`. If a row does not
   match, fix the text. If the text is right, fix the code. Done when every row
   matches.

   Do not hand-write a derivable figure (see
   [Derivable figures](../code-review/references/merge-bar.md#derivable-figures)).
   Link it, name its command, or use a generated value. If a derivable figure
   is wrong, fix it in this pass: no receipt exists yet, so the fix costs one
   pass. A derivable-figure mismatch that you leave does not block the handoff.
   Record it for the verdict's P3 list with the correct value and the command
   that computes it.

   Leave a timing or baseline-bound claim as it is. Do not re-run it at this
   HEAD, because that destroys its provenance. Check that it names its run id
   or baseline SHA, and see
   `[fill-in: timing proof rules — this repo's wall-time proof rules]`.

4. **Clear the registry traps.** Check each row that your diff touches:

   | The diff adds | Check |
   |---|---|
   | a `.go` file, tests included | `bash scripts/verify-license-header.sh`; fix with `bash scripts/add-license-header.sh` (rule owned by `golang-engineering`). |
   | a `*_live_test.go` file | Classified row in `specs/live-tests.v1.yaml`, then `bash scripts/verify-live-tests-ledger.sh` (ledger mechanics: `generator-script-discipline`). |
   | an `ESHU_*` environment variable | `Entry` in `go/internal/envregistry/entries.go`; run `bash scripts/generate-env-registry-doc.sh`, then `scripts/verify-env-registry-doc.sh` and `scripts/verify-docs-cli-env-refs.sh` (ledger mechanics: `generator-script-discipline`). |
   | a new test file | The `test-todo-scan` row from step 1. A hit is a `FAIL`: reword the line or fix the stub, not the scan. Placeholder lines that carry SQL are not hits. |
| a newly set or provisioned env var, a new client dial, or a new listener port | Name the live code that reads it, the live server that answers it, and the listener that opens it, plus the test that proves it end to end. A setting with no reader, a dial with no live-server test, or a port with no listener blocks the handoff. |
| a changed `.go` file in a package containing `*_live_test.go` | Check the `live-test-refs` row from step 1 and grep sibling `*_live_test.go` files for assertions affected by the behavior change. Never claim "full suite green" from a DSN-less `go test` that silently `SKIP`s live tests. |
| a performance, EXPLAIN, buffer, or latency claim | Trace the production caller to the exact SQL statement or function measured. Measuring a whole-chunk helper or test-only twin that the production path never executes blocks the handoff (`evidence-overclaim`). |
| a PR body claiming `0 P0`/`0 P1`, "clean preliminary review", or "full suite green" | Name the verifiable receipt, verdict/HEAD SHA, or executed command + live/skip scope; `check-shape.sh` fails unbacked hand-typed claims (`unbacked-review-claim`, `unscoped-full-suite`). |

   In `specs/ci-gates.v1.yaml`, `env-registry-doc` and `live-backend-tests` (the
   owner of the ledger validator) have no `local.pre_push: floor`. `make
   pre-push` defers them, so the `license-header`, `live-tests-ledger`,
   `env-registry-doc`, and `docs-cli-env-refs` rows from step 1 are their first
   local run. A `NOT_CHECKED` row means that script is absent in the repo.

5. **Confirm the role gates.** Rerun the registry-selected static gates your role
   names if you committed after their last run. Report each as `PASS`, `FAIL`, or
   `NOT_CHECKED`. Do not run `make pre-push` or `make pre-pr`.

6. **Check test sensitivity.** Skip this step for a test whose red-first run
   already showed the failure. Otherwise mutate the production assertion and
   watch the test fail. Restore the file with `git restore <file>`. Confirm that
   `git status --short <file>` prints nothing before you go on.
   [golang-engineering](../golang-engineering/SKILL.md) holds the rule.

7. **Repeat until clean.** Any fix is a new commit and restarts at step 1. Stop
   when one full pass changes nothing. After six passes, stop and report the
   remaining blockers instead of looping.

## Handoff

Include the head line from
[Messages name their head](../session-lifecycle/SKILL.md#messages-name-their-head).
Your report must contain:

- `HEAD`, the body `sha256` when a body exists, and the number of passes
- the claim table, or the path to it
- each gate and registry check with `PASS`, `FAIL`, or `NOT_CHECKED`
- the reason for every `NOT_CHECKED`

## Mistakes

| Mistake | What it costs |
|---|---|
| Running the preflight, then committing a "small" fix | Results that belong to a HEAD no reviewer will see |
| Copying a measured figure from the last run into the body | A stale claim that a reviewer re-measures and blocks on |
| Re-running a baseline-bound timing at this HEAD | A number that no longer matches its named baseline |
| Treating a `make pre-push` exit 0 as proof the ledger and env-registry checks passed | The first run of those checks happens in CI |
| Running `make pre-push` yourself to feel safe | One more floor run per branch: changed-package tests, race tests, and lint |

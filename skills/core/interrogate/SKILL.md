---
name: interrogate
tier: core
description: "Adversarial diff review and blast-radius proof: attack a change in isolated worktrees keeping only findings proven by a failing command, and prove the single safety fact that clears downstream breakage."
---

# Interrogate

Break a diff before it ships, and separate **proven bugs** from speculative review noise. Pairs executable-proof-only adversarial review with a 5-step blast-radius safety ladder.

Scope: portable `core` layer across all harnesses. Never mutate the author's working branch during interrogation.

## Core rule: executable proof only

Every finding reported from an interrogation pass MUST include an exact command, test, or repro script that fails against the diff and violates the restated intent. **Drop anything you did not run.** Style, naming, structure, and hypothetical "if someone later changes X" risks belong in a separate design review, never as interrogation findings.

## Blast-radius epistemic ladder

When assessing what a change could break beyond what `rg` finds (library internals, teardown timing, wire/DB formats, feature flags, 3-hop callers), grade every safety claim on five rungs:

1. **Asserted** (opinion only — not proof).
2. **Cited** (`file:line` read).
3. **Traced** (end-to-end call/data path verified in source).
4. **Executed** (ran a targeted test or script against the real code).
5. **End-to-end repro** (observed in the running application or live backend).

Focus effort on finding **the single safety fact** that clears the widest downstream risk and proving it at rung 4 or 5 — or explicitly marking it `unproven`.

## Workflow

1. **Freeze the target diff and restate intent.** Capture the exact base/head SHAs and write the change's intended behavior in two sentences so reviewers attack real intent, not a strawman. Inspect changed files and map 3-hop callers, wire/storage formats, and lifecycle boundaries. Done when `BASE`, `HEAD`, and restated intent are recorded.

```bash
BASE="$(git merge-base origin/main HEAD)"
HEAD="$(git rev-parse HEAD)"
git diff --stat "${BASE}..${HEAD}"
```

2. **Run adversarial attacks in isolated worktrees.** Create a detached temporary worktree at `HEAD` (copying uncommitted patches if reviewing dirty state) and dispatch one or more independent reviewers (ideally from diverse model families when available) with a strict brief: *find concrete inputs, interleavings, error paths, or caller interactions that break the restated intent; output only findings with runnable repro commands.* Keep every unique failure — do not vote away a proven bug because only one reviewer found it. Done when all reviewers return their candidate findings and repro commands.

```bash
WORK="$(mktemp -d)"
git worktree add --detach "${WORK}/target" "${HEAD}"
# Optional: run a cold cross-family pass when another model CLI is installed:
bash scripts/cross-review.sh --base origin/main
```

3. **Re-run every candidate finding and audit blast radius.** Execute each finding's repro command yourself in the isolated worktree. Confirm two things: (a) the command actually fails on `HEAD`, and (b) the failure genuinely breaks the restated intent rather than an artificial assumption. Merge findings that share one root cause. Run the rung-4/5 check for the primary blast-radius safety fact. Done when every surviving finding has an independently observed failing command output.

4. **Clean up and report Verified vs. Dropped.** Remove temporary worktrees and report in three tight sections:
   - **Verified findings:** root cause, affected `file:line`, exact repro command, observed failure output, and smallest fix direction.
   - **Blast-radius safety fact:** the one fact the change relies on, its rung (`4`/`5` or `unproven`), and the command that checked it.
   - **Dropped candidates:** count and one-line reason each dropped claim failed verification (unrun, did not fail, or outside intent). Done when temporary worktrees are pruned and `git worktree list` matches the starting state.

```bash
git worktree remove --force "${WORK}/target"
rm -rf "${WORK}"
git worktree prune
```

## Error recovery

- When the target has uncommitted local changes: export `git diff` and `git diff --cached` into a patch file and `git apply` it inside the detached worktree; never run destructive repros in the main checkout.
- When a repro requires a backend or service that is unavailable locally: downgrade that specific finding to `UNVERIFIED (missing runtime: <service>)` rather than silently dropping or falsely confirming it.
- When a temporary worktree fails to remove because of build artifacts: delete build outputs inside `${WORK}/target`, run `git worktree remove --force "${WORK}/target"`, and confirm with `git worktree list`.

## License

Adapted from `interrogate` and `blast-radius` in `pstack` (MIT License, Copyright (c) poteto).

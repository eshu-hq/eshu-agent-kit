---
name: correct
tier: core
description: "Stop recurring agent mistakes structurally: mine git history and reviews for mistakes that happened twice, fix each at the highest level (architecture, types/lint, behavioral tests, docs last), and prune dead rules."
---

# Correct

Assume every future contributor is an agent that sees only the files it opened, copies the nearest example, and takes the shortest path that compiles. Design the repository so a change that looks right from one file is right for the whole repo.

Scope: portable `core` layer across all harnesses.

## Enforcement hierarchy (highest to lowest)

Human review is not on this list. Always fix at the highest level that works, and state why higher levels could not work whenever you land below level 1:

1. **Architecture:** one owner per state, one supported way per task, hide internals so wrong imports fail to compile, replace hand-synced lists with a single source of truth, and delete legacy/dead examples agents might copy.
2. **Types, lint, or static CI gate:** make illegal states unrepresentable in types. If bad code still compiles, add a lint or CI check whose **error message names the exact replacement file, type, or helper** to use instead. For widespread legacy patterns, ship a ratchet (fail only on newly added occurrences).
3. **Behavioral tests:** write or tighten observable contract tests that fail when the mistake recurs and keep passing across internal refactors.
4. **Docs or agent instructions (last resort, judgment-only):** nothing fails when an agent skips a prose rule. Only add prose for judgment calls that levels 1–3 cannot encode.

## Workflow

1. **Mine recurring mistake classes (2x threshold).** Inspect recent commits, reverts, review comments, papercut/bug reports, and workaround comments. Group failures into classes. A mistake class qualifies once it has happened **at least twice** (one-offs do not earn new machinery). Done when candidate classes are ranked by frequency and cost, each citing at least two concrete commits, PRs, or issues.

```bash
git log --grep='revert\|fix' --oneline -n 40
git log --stat -n 20
```

2. **Choose the highest enforcement rung for each top class.** Walk rungs 1 → 4 in order. If you settle below level 1, write a one-sentence justification of why architecture (or types/lint) could not prevent it. Done when each selected class has a concrete structural fix design.

3. **Implement one class per commit and prove the check catches the past mistake.** Build the architectural fix, type, lint, or test so the exact same command runs locally and in CI. **Mutation/regression proof:** verify your new check fails against a real past mistake (or minimal scratch reproduction of it) and passes on clean code. Any inline suppression escape must carry a reason, an expiry date, and explicit approval. Done when every new check has observed RED-on-mistake and GREEN-on-fix output.

```bash
# Example: confirm a new lint/check fails on a seeded bad snippet before keeping it
git diff --stat
```

4. **Update and prune the enforcement table.** Keep a compact table in the repo's agent guide pairing each rule with what enforces it (type, lint name, test name, or `prose-only`). If a `prose-only` rule gets violated again, escalate it up the hierarchy in the same PR. **Delete any prose rule once architecture, types, or lint make the mistake impossible.** Done when the report lists each fixed class with evidence, level chosen, why a higher level did not work, and any deleted obsolete rules.

## Error recovery

- When git history is sparse or shallow and fewer than two examples appear: check open PR review threads and issue trackers before acting; if truly a one-off, fix the bug directly and do not add speculative lints or prose rules.
- When a new lint flags dozens of pre-existing legacy lines: switch the check to diff/ratchet mode (fail only on added violations) or open a focused cleanup sweep rather than disabling the rule.
- When a proposed check cannot be shown to fail on a seeded past mistake: refine the check until it fails reliably, or discard it — a check never seen failing proves nothing.

## License

Adapted from `correct` and `principle-encode-lessons-in-structure` in `pstack` (MIT License, Copyright (c) poteto).

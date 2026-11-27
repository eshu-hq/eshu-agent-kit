---
name: show-me-your-work
tier: core
description: "Keep an append-only, formula-safe TSV decision trail for long or unattended runs, self-audit rows against the session transcript, and finish with an independent Attention review."
---

# Show me your work

Leave a concise, reviewable decision trail for multi-step or unattended runs so a human can audit *what was decided, why, and what proved it* in under two minutes instead of reading a long transcript.

Scope: portable `core` layer across all harnesses. Resolve `$LOG_SH` from this skill's `scripts/log.sh` (template schema: [decision-log-template.tsv](references/decision-log-template.tsv)).

## Schema

Six tab-separated columns: `ts`, `phase`, `decision`, `why`, `evidence`, `result`. Never edit or delete prior rows; append a superseding row when a decision or measurement changes. `scripts/log.sh` appends with `>>`, flattens embedded tabs/newlines, and neutralizes spreadsheet formula injection (`=`, `+`, `-`, `@` prefixed with `'`).

## Workflow

1. **Open the trail with a `start` marker.** Pick a scratch or branch-scoped path (for example `decisions.tsv` inside your run directory or PR artifact dir) and log a `start` row naming the goal and, when resuming, the prior run's timestamp range. Done when the header and `start` row exist on disk.

```bash
bash scripts/log.sh decisions.tsv start "goal: <short goal>" "kickoff" "<branch-or-sha>" "started"
```

2. **Log one row per meaningful decision, test, or pivot.** Record architectural choices, hypothesis results, skipped checks, reverts, and gate outcomes right as they happen. Keep cells concrete: cite the exact command, file, or metric in `evidence`, and use clear outcomes (`ok`, `reverted`, `blocked`, `inconclusive`) in `result`. Done when every major branch point in the run has an appended row.

```bash
bash scripts/log.sh decisions.tsv verify "keep change X" "p95 dropped 22% across 5 A/B runs" "bench.txt" "ok"
```

3. **Self-audit the trail against the session transcript.** Before final handoff, compare every row against the actual commands and tool outputs from this session. If any claim, count, or result drifted from what actually ran, append a `correction` row citing the original timestamp — never rewrite history. Done when every row's `evidence` and `result` match observed run outputs.

```bash
wc -l decisions.tsv && tail -n 10 decisions.tsv
```

4. **Run an independent Attention review.** Dispatch a read-only reviewer (preferably from another model family when your harness supports it; otherwise a fresh independent session) to read the decision log alongside the diff/transcript and emit a short `Attention` section (`reviewed by <model-or-role>`) flagging weak evidence, skipped verification, or risky calls. Include that `Attention` section verbatim in your final handoff. Done when the `Attention` section is attached (or `none` is confirmed by the reviewer).

## Error recovery

- **Failure on wrong argument count (`scripts/log.sh` exits 1):** pass all six positional arguments (`<logfile> <phase> <decision> <why> <evidence> <result>`), quoting multi-word values.
- **Gotcha with leading `=`, `+`, `-`, or `@` in evidence (for example a CLI flag or PR title):** let `scripts/log.sh` prefix it with `'` so spreadsheet viewers cannot execute it as a formula; do not hand-append with `echo`.
- **Fallback when an independent reviewer cannot be spawned (offline or single-session mode):** perform the step-3 transcript self-audit, note `Attention: self-audited only (no independent reviewer available)`, and list the top two calls most worth human scrutiny.

## License

Adapted from `show-me-your-work` in `pstack` (MIT License, Copyright (c) poteto).

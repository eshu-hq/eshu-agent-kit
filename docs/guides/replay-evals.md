# Replay Evals

Measure whether loading a skill changes outcomes across **any skill** and all
three harnesses (**Claude**, **Agy**, and **Muse**). Replays prompts in an
isolated workspace with the target `SKILL.md` injected versus stripped, then
runs deterministic trajectory checks and blind A/B judging.

Nothing in this harness runs in CI by design. Starter golden/edge suites live
under [evals/README.md](../../evals/README.md). To check whether a skill gets
loaded at all, see [Trigger evals](trigger-evals.md).

## Workflow

1. **Mine production prompts** (optional; keep mined output local, never commit
   raw transcripts):

   ```bash
   # Auto-discovers default Muse, Claude, and Agy roots; filter by skill or regex
   bash scripts/replay-eval.sh mine \
     --harness all --skill code-review --top-steered --max 20 \
     --out /tmp/evals-prod.json
   ```

   Pass `--sessions-root PATH` (repeatable) to override default discovery roots,
   `--query REGEX` to match first prompts, and `--category golden|production|edge`.
   Re-run `mine` as new sessions accrue to refresh production evals.

2. **Replay prompts in isolated workspaces** (`with-skill` vs `without-skill`):

   ```bash
   bash scripts/replay-eval.sh replay \
     --evals evals/code-review.json \
     --skill code-review \
     --harness claude \
     --workspace /path/to/repo \
     --repeats 3 \
     --out /tmp/pairs.json \
     --seal /tmp/seal.json
   ```

   When `--runner` is omitted, `replay` invokes `scripts/replay-runner.sh`,
   which creates a detached temporary git worktree (or temp dir) per run and
   cleans it up automatically:
   - `claude`: passes `--output-format stream-json --verbose
     --no-session-persistence --disable-slash-commands`, adding
     `--append-system-prompt-file <SKILL.md>` only in `with-skill` mode.
   - `agy`: passes `--output-format json --disable-slash-commands -p=<prompt>`,
     prepending `SKILL.md` only in `with-skill` mode.
   - `muse`: passes `muse exec --json --no-session-log --disable-web-tools
     --disable-reminders --disable-request-user-input --no-foreign-personal-context
     --approval-mode never --trust-workspace --workspace <iso_dir> --prompt-file <file>`
     on both arms (writing the prompt file outside `<iso_dir>` so the worktree
     stays clean and both arms have identical workspace tool access). In
     `with-skill` mode it prepends `SKILL.md`; in `without-skill` mode it strips
     `<iso_dir>/.agents/skills` inside the isolated worktree and relies on
     `--no-foreign-personal-context` to exclude foreign personal skills.

   Pass `--runner PATH` to plug in a custom runner executable (for offline
   tests or bespoke harnesses). Use `scripts/replay-runner.sh --dry-run-cmd ...`
   to inspect the exact CLI invocation without calling an LLM.

3. **Blind-judge pairs and grade trajectory expectations**:

   ```bash
   # Real blind LLM judge (claude, agy, or muse)
   bash scripts/replay-eval.sh judge \
     --runs /tmp/pairs.json \
     --judge-harness claude \
     --out /tmp/verdict.json
   ```

   Alternative judge modes:
   - Omit `--judge-harness` and `--judge-cmd` to use the offline fallback
     rubric (`0.55 * goal_coverage + 0.20 * tool_use + 0.25 * error_free` —
     zero skill or arm leakage).
   - Pass `--judge-cmd PATH` to pipe each pair JSON to a custom executable that
     prints `A`, `B`, or `TIE`.

   When an eval item includes `expectations` (`must_call_tools`, `must_mention`,
   `must_not_mention`, `max_errors`), `judge` deterministically grades both
   anonymous trajectories alongside the A/B verdict.

4. **Report metrics and export JSON for `/debrief`**:

   ```bash
   bash scripts/replay-eval.sh report \
     --verdict /tmp/verdict.json \
     --seal /tmp/seal.json \
     --json-out /tmp/eval-summary.json
   ```

   Pass `--aa-verdict FILE` if A/A repeat comparisons live in a separate verdict
   file (otherwise `report` reads `kind == "aa"` entries from `--verdict`).
   The report prints win rate, A/A noise band with a signal-vs-noise note,
   trajectory pass rates (with a sweet-spot warning when `with-skill` hits 100%
   over 3+ pairs), token cost delta, wall-time latency delta, and a tool delta
   line (mean tool calls and tool errors, with-skill minus stripped).

   `--json-out` writes the machine-readable JSON summary contract that
   `/debrief` ingests via `--evals`. Beyond the win-rate and cost fields it
   carries `tool_calls_delta`, `tool_errors_delta`, `tool_pairs`, `skill_sha`,
   and `kind: "ablation"`.

   Tool and error deltas are `null` (never 0) with no `--seal`, or when the
   verdict was judged before these fields existed. Re-run `judge` on a fresh
   `replay` to get them. `skill_sha` is the sha256 of the raw `SKILL.md` bytes,
   taken at `replay` time (so it names what was injected, not what is on disk
   at report time) and stored in the seal meta, never in the pairs the judge
   sees. It is `null` for a flat legacy seal or an unresolvable skill file.

5. **Keep a version history** (optional). Append the summary to a JSONL ledger:

   ```bash
   bash scripts/replay-eval.sh report --verdict /tmp/verdict.json --seal /tmp/seal.json \
     --history ~/replay-history.jsonl      # or --default-history
   ```

   `--default-history` writes `$DEBRIEF_DATA_DIR/replay-eval-history.jsonl`
   (default `$XDG_DATA_HOME/eshu-agent-kit/`). The two flags are mutually
   exclusive and need `--seal`; without one the run is not comparable and exits
   2. Each line is the `--json-out` object, compact with sorted keys, written
   with one `O_APPEND` write, so concurrent reports do not interleave. There is
   no lock and no pruning command. Pass the ledger to `/debrief` with
   `aggregate --eval-history PATH` (bare flag = default ledger) to render the
   **Skill Quality Trends (Version History)** card: one row per
   `(skill, harness, skill_sha)` showing the newest run of that version, never
   averaged, with the win-rate change against the prior version on the same
   harness (`within noise` when it is inside the larger noise band). The
   aggregate keeps the newest 20 versions per skill and harness; the card shows
   5. Records whose `kind` is not `ablation` (trigger results) never enter it.

### How tool calls are counted

`tool_calls` is the length of the runner's `tools` list before the 50-entry
truncation in the pair. Claude appends one entry per `tool_use` block, Muse one
per `tool_batch.effect.terminal` event, and agy copies the `tools` list from
the CLI result. The agy count is only as complete as that list; whether the
agy CLI deduplicates it is unverified, so compare agy deltas against agy only.

## Blindness And Strip-Proof Gate

`blind_traj` removes `skill_count`, strips `skills`/`mode`/`arm` fields, and
scrubs arm tokens (`with-skill`, `without-skill`, and underscore forms) before
pairing. `judge` runs a strip-proof taint scan over the entire pair package
before invoking any judge and refuses tainted input. Arm labels live only in
`seal.json`, which the judge never sees.

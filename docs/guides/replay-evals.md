# Replay Evals

Measure whether loading a skill changes outcomes across **any skill** and all
three harnesses (**Claude**, **Agy**, and **Muse**). Replays prompts in an
isolated workspace with the target `SKILL.md` injected versus stripped, then
runs deterministic trajectory checks and blind A/B judging.

Nothing in this harness runs in CI by design. Starter golden/edge suites live
under [evals/README.md](../../evals/README.md).

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
   - `muse`: passes `muse exec --json --no-session-log --no-foreign-personal-context
     --approval-mode never --workspace <iso_dir> --prompt-file <file>` (writing
     the prompt file outside `<iso_dir>` so the worktree stays clean). In
     `with-skill` mode (and in `muse` judge calls), it passes `--trust-workspace`
     so workspace tools work and prepends `SKILL.md`. In `without-skill` mode,
     project skills under `<iso_dir>/.agents/skills` are removed and
     `--no-foreign-personal-context` strips foreign personal skills without
     trusting the workspace.

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
   over 3+ pairs), token cost delta, and wall-time latency delta.

   `--json-out` writes the machine-readable JSON summary contract (which
   `/debrief` will ingest via `--evals` once #100 lands).

## Blindness And Strip-Proof Gate

`blind_traj` removes `skill_count`, strips `skills`/`mode`/`arm` fields, and
scrubs arm tokens (`with-skill`, `without-skill`, and underscore forms) before
pairing. `judge` runs a strip-proof taint scan over the entire pair package
before invoking any judge and refuses tainted input. Arm labels live only in
`seal.json`, which the judge never sees.

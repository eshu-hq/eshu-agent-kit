# Replay evals

Measure whether loading a skill changes outcomes: replay real mined prompts
with the skill loaded versus stripped, and blind-judge which trajectory better
satisfies the session's evident goal. Issue #83.

Scope is deliberately small (arbiter D5, do not widen):

- One skill: `performance-rigor`.
- One harness: Muse. Prompts are re-mined from raw Muse transcripts only.
- First prompt only per session; subagent children and fixture sessions skipped.
- Nothing in this harness runs in CI.

## Commands

```bash
# 1. Mine fixtures from raw transcripts (refresh path: re-run as sessions accrue).
bash scripts/replay-eval.sh mine --sessions-root "$XDG_DATA_HOME/muse/sessions" --out evals.json

# 2. Replay each prompt both ways. The runner loads or strips the skill:
#    CMD --mode with-skill|without-skill --skill performance-rigor \
#        --prompt-file PROMPT --out TRAJECTORY_JSON
bash scripts/replay-eval.sh replay --evals evals.json --runner ./run-once.sh \
  --skill performance-rigor --out pairs.json --seal seal.json --repeats 3

# 3. Blind-judge the pair package. The judge sees randomized A/B labels only;
#    any arm identity in the input fails the strip-proof gate.
bash scripts/replay-eval.sh judge --runs pairs.json --out verdict.json

# 4. Report win rate (decoded with --seal, which the judge never saw),
#    A/A repeat noise band, and token cost delta (#80 field names).
bash scripts/replay-eval.sh report --verdict verdict.json \
  --aa-verdict verdict.json --seal seal.json
```

Pairs with `--repeats N` also compare repeat runs of the same arm (`aa`
pairs). Their disagreement fraction is the noise band: a win rate inside the
band is measurement noise, not skill value.

`judge` also accepts `--judge-cmd PATH`: the pair package is piped as JSON to
that executable on stdin and its stdout must be `A`, `B`, or `TIE`. The
strip-proof gate runs first, so an external judge stays blind too. The default
is the built-in goal-coverage rubric.

## Worked example (stub runner, 3 mined prompts, repeats=2)

```
replay-eval report: skill=performance-rigor
cross pairs: 3 (3 decisive, 0 ties)
win rate (with-skill): 3/3 = 1.00
noise band (A/A disagreement): 0/6 = 0.00
cost delta (mean with-skill minus stripped, #80 token fields): +50.0 in / +140.0 out over 3 pairs
```

The stub runner answers the goal verbatim with the skill and rambles without
it, so 1.00 is the ceiling, not a claim. Replace the stub with a runner that
drives the real agent (skill pinned vs stripped) to measure actual skill value.

Blindness is enforced by substring: any arm token (`with-skill`,
`without-skill`, and their underscore forms) anywhere in the judged package
fails the gate, and runner transcripts are scrubbed the same way before
pairing. Keep arm tokens out of prompts and tool names or the run refuses.

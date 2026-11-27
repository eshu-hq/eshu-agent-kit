# Trigger Evals

Measure whether a skill's `name` and `description` make an agent reach for the
skill when it should, and stay quiet when it should not.
[Replay evals](replay-evals.md) ask whether a loaded skill helps; this covers
whether it gets loaded. Only the frontmatter `name` and `description` are used
(the loader stops at the closing `---`), and nothing here runs in CI.

## Run it

```bash
# Offline rubric (default), no model calls
bash scripts/replay-eval.sh trigger --suite evals/triggers.json --json-out trigger.json

# A live router (claude, agy, or muse), or your own decider (stdin payload, {"skills": [...]} out)
bash scripts/replay-eval.sh trigger --suite evals/triggers.json --harness claude --repeats 3
bash scripts/replay-eval.sh trigger --suite evals/triggers.json --decider-cmd ./my-decider
```

Options: `--skills-dir DIR` (repeatable, flat or layered, later dirs win;
defaults to the kit `skills/`), `--aliases TSV`, `--model ID`, `--threshold F`
(rubric only), `--repeats N`, `--timeout SEC`, `--allow-errors`. Exit `0` ok,
`1` a trial errored and no `--json-out` is written (unless `--allow-errors`), `2` bad
usage or invalid suite (including `--decider-cmd` with `--harness`).

## Suite schema

`evals/triggers.json` is `{"version": 1, "cases": [...]}`. The key is `cases`,
not `evals`, so a stray `--evals evals/` skips it.

| Field | Meaning |
| --- | --- |
| `id` | Unique string. |
| `kind` | `positive`, `negative`, or `competing`. |
| `prompt` | The user prompt to route. |
| `expect` | Skills that should trigger. Required for `positive` and `competing`; empty for `negative`. |
| `reject` | Skills that should not trigger. Required for `negative` and `competing`. `["*"]` means every catalog skill not in `expect`. |

A negative case is a near miss that shares vocabulary with a skill's scope but
is not that work. A competing case names a skill that should win and a sibling
that should not. Names resolve through the alias map and lose any `prefix:`. An
unknown skill, a duplicate id, or one skill in both lists exits 2.

## Deciders

Every decider gets the same payload, with skills sorted by name:
`{"prompt": "...", "skills": [{"name": "...", "description": "..."}]}`.

- **rubric** (`mode: "lexical-rubric"`): tokens are `[a-z0-9]+` of length 3 or
  more, minus the replay-eval stopwords. A skill triggers when
  `|prompt ∩ (name + description)| / |prompt| >= --threshold`; an empty prompt
  triggers nothing. Deterministic, and a lexical proxy only.
- **cmd** (`mode: "custom"`): your executable.
- **claude / agy / muse** (`mode: "router-prompt"`): the payload goes into a
  router prompt run in an empty temp directory with the replay runner's harness
  flags (slash commands disabled where the harness has that flag). The reply must be a JSON object with a `skills` list. This is a router over
  the catalog, not the harness's native skill-loading decision, so do not read
  it as a native trigger rate.

## Scoring

Only labelled cases are scored. For skill S over trials (case x repeat): TP is
S in `expect` and selected; FN is in `expect`, not selected; FP is in `reject`
and selected; TN is in `reject`, not selected. A selection in neither list goes
to `unlabeled_triggers` and is never an FP; names not in the catalog go to
`unknown_selected` and are not counted.

`precision = TP/(TP+FP)`, `recall = TP/(TP+FN)`,
`f1 = 2TP/(2TP+FP+FN)`, `trigger_rate = (TP+FP)/(TP+FP+FN+TN)`,
`false_trigger_rate = FP/(FP+TN)`. A zero denominator gives `null`, except F1,
which is `null` only when `2TP+FP+FN` is 0, so a skill that never fires on its
positives scores `0.0`. Overall figures are micro (summed counts) plus
`macro_f1`, the mean of the non-null per-skill F1.

Errored trials (non-zero exit, timeout, unparseable reply) are excluded from
every count, never scored as "did not trigger", and fail the run by default.

## Output

`--json-out` writes `kind: "trigger-eval"`, `version: 1`, `decider`, `mode`,
`model`, `threshold` (`null` unless rubric), `repeats`, `suite`, `recorded_at`,
`cases`, `trials`, `errors`, `overall`, and `per_skill` rows (counts, the five
rates, `positives`, `negatives`, `unlabeled_triggers`, and `description_sha`:
the first 12 hex of `sha256(name + "\n" + description)`). It also lists
`false_positives`, `false_negatives`, and `unknown_selected` as
`{case_id, skill, repeat}` (repeat is 1-based).

## In /debrief

`debrief.sh aggregate --trigger-evals PATH` (repeatable, files or directories)
keeps the newest `recorded_at` per skill and decider. Skill-table rows gain
`trigger_precision`, `trigger_recall`, `trigger_f1`, and `trigger_decider` (a
live router is preferred over the rubric). The report's Trigger Precision /
Recall card sits beside the nudged share and always names the decider. A file
that is not `kind: "trigger-eval"` makes aggregate exit non-zero, and trigger
JSON given to `--evals` never changes win-rate rows.

## Threshold calibration

The rubric default is `0.25`, picked by sweeping the committed starter suite
(39 cases, 23 skills). Treat it as a starting point, not a validated setting:

| Threshold | FP | FN | Precision | Recall | F1 | Macro F1 |
| --- | --- | --- | --- | --- | --- | --- |
| 0.20 | 3 | 0 | 0.9118 | 1.0000 | 0.9538 | 0.9681 |
| 0.25 | 2 | 0 | 0.9394 | 1.0000 | 0.9688 | 0.9826 |
| 0.30 | 1 | 1 | 0.9677 | 0.9677 | 0.9677 | 0.9826 |
| 0.40 | 1 | 6 | 0.9615 | 0.8065 | 0.8772 | 0.8536 |

Recall holds through 0.25, then falls. The prompts were written alongside the
descriptions and share their vocabulary, so the rubric scores flatter than it
would on mined prompts. Re-sweep on real prompts first.

## Known limits

- The rubric measures word overlap, not meaning: a cheap regression check on
  description edits, not a real signal. Use a live router for that.
- Router-prompt selection may not track native triggering, and a live harness
  may still load its own global skills despite the empty working directory.
  Neither is verified. Catalog order (sorted by name) could also bias a router.

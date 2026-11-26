# Replay Eval Suites

Starter evaluation suites for skills in this kit. Each `<skill>.json` file holds
versioned golden and edge cases used with `scripts/replay-eval.sh` (see
[replay-evals.md](../docs/guides/replay-evals.md)).

## Suite Mix (5 / 80 / 15)

Target a balanced eval distribution across three categories:

- **5% `golden`** (committed here): canonical regression anchors that verify the
  core contract of a skill never regresses.
- **80% `production`** (mined locally, **never committed**): first prompts
  mined from real Muse, Claude, and Agy transcripts via `replay-eval.sh mine`.
- **15% `edge`** (committed here): boundary, adversarial, or refusal cases where
  an unguided model commonly slips.

## Privacy Rule

**Never commit raw user transcripts or mined `production` eval files.** Mine
production prompts into a local temporary or untracked directory (for example,
`/tmp/evals/`), run `replay`, `judge`, and `report`, and commit only curated
synthetic `golden` and `edge` cases under `evals/`.

## Item And Expectations Schema

Each suite is a JSON array of eval items:

```json
[
  {
    "id": "code-review-golden-1",
    "category": "golden",
    "skill": "code-review",
    "prompt": "Review this diff ...",
    "expectations": {
      "must_call_tools": [],
      "must_mention": ["P1", "proof"],
      "must_not_mention": ["looks good to merge"],
      "max_errors": 0
    }
  }
]
```

Supported `expectations` keys (graded deterministically on both blind arms):

- `must_call_tools`: list of tool names that must appear in the trajectory's
  `tools` list (case-insensitive).
- `must_mention`: list of case-insensitive substrings or regular expressions
  that must match the final transcript.
- `must_not_mention`: list of forbidden case-insensitive substrings or regular
  expressions that must not match the final transcript.
- `max_errors`: maximum allowed tool/run error count (integer).

Keep arm identity tokens out of prompts and expectations: the strip-proof gate
rejects any pair containing arm tokens before judging.

## Sweet-Spot Rule

A healthy eval suite lands around **60-90%** pass rate on the target arm. When
`report` sees a **100%** trajectory pass rate across 3 or more pairs, it prints
a saturation warning — add harder edge cases or mine fresher production prompts
with `--top-steered`.

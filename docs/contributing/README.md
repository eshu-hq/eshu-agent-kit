# Contributing to eshu-agent-kit

The canonical guide is [CONTRIBUTING.md](../../CONTRIBUTING.md) — this
page is the quick version, and CONTRIBUTING.md wins on any disagreement.

## Setup

You need `bash` and `python3`. There's nothing to build and nothing to
run: the kit is markdown, JSON, and scripts.

## Run the lanes locally

CI runs only the lanes a PR can affect; `ci-complete` is the one
required check. Run them first:

```sh
# shell lane
shellcheck --severity=error $(git ls-files '*.sh')
shfmt --diff $(git ls-files '*.sh')

# shell-tests lane
bash scripts/run-tests.sh

# docs lane
bash scripts/check-docs-stale.sh --all && test ! -s .eshu-doc-state/stale.jsonl
bash scripts/check-md-links.sh
bash scripts/layer-lint.sh
```

## Ground rules

- Every change proves itself before merge. New standalone test suites go
  in `scripts/tests/` or `hooks/tests/` and must be added to
  `scripts/run-tests.sh`. A skipped test cites an open issue.
- Keep each file under 500 lines. One meaning lives in one place —
  `skills/registry.md` is the rename and migration map; don't restate it.
- Write steps in order, each ending on a checkable done condition.
- Keep Eshu coupling in `skills/eshu/` and named adapters, never in `core/`.
- No AI attribution in commits, PRs, or docs. Never push to `main`.

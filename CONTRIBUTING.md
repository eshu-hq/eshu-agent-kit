# Contributing

This repo keeps one promise: every change proves itself before merge. CI runs
only the lanes a PR can affect; `ci-complete` is the one required check.

## Which lane runs when

| PR changes | Lanes that must pass |
|---|---|
| Shell scripts, their tests, or testdata | `shell`, `shell-tests` |
| Markdown, skills, rules, agents, docs, or templates | `docs` |
| `install.sh` | `shell`, `shell-tests` |
| `.github/workflows/**` | `actionlint`, plus all three lanes |
| `VERSION` or tag `v*` | tag-versus-`VERSION` check |

Anything else runs all three lanes. Pushes to `main` run everything; a weekly
schedule re-runs the docs link check and files an issue on failure.

## Run the lanes locally

```sh
# shell lane: errors fail, warnings stay visible
shellcheck --severity=error $(git ls-files '*.sh')
shfmt --diff $(git ls-files '*.sh')
awk -v cap=500 'FNR>cap{print FILENAME":"FNR}' $(git ls-files '*.sh')

# shell-tests lane: the six self-hosted suites end to end
bash scripts/run-tests.sh

# docs lane: staleness drift, internal links, layer lint
bash scripts/check-docs-stale.sh --all && test ! -s .eshu-doc-state/stale.jsonl
bash scripts/check-md-links.sh
bash scripts/layer-lint.sh
```

New standalone test suites go in `scripts/tests/` or `hooks/tests/` and must be
added to `scripts/run-tests.sh`. A skipped test cites an open issue. Fixes land
under the epic that owns the lane — findings are fixed, never silently
excluded. The one allowed static gate is the 500-line `wc -l` cap on `.sh`
files; a temporary allowlist entry must cite its child issue and may only
shrink.

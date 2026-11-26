#!/usr/bin/env bash
# scripts/replay-eval.sh — Multi-harness replay evals (issue #103).
#
# Mine first prompts from Muse, Claude, or Agy transcripts, replay each prompt
# with a target skill loaded vs stripped (via built-in isolated runner or custom
# --runner), blind-judge A/B pairs with trajectory grading, and report win rate,
# noise band, pass rates, cost delta, and latency delta.
#
# Subcommands: mine | replay | judge | report (see --help on each).
# Nothing in this harness runs in CI by design.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib"

usage() {
	cat >&2 <<'EOF'
Usage: bash scripts/replay-eval.sh <mine|replay|judge|report> [options...]

Examples:
  bash scripts/replay-eval.sh mine --harness all --skill code-review --top-steered --out evals.json
  bash scripts/replay-eval.sh replay --evals evals/code-review.json --skill code-review --harness claude --out pairs.json --seal seal.json --repeats 3
  bash scripts/replay-eval.sh judge --runs pairs.json --judge-harness claude --out verdict.json
  bash scripts/replay-eval.sh report --verdict verdict.json --seal seal.json --json-out summary.json
EOF
}

if ! command -v python3 >/dev/null 2>&1; then
	echo "replay-eval: python3 is required" >&2
	exit 1
fi

cmd="${1:-}"
[ -n "${cmd}" ] || {
	usage
	exit 2
}
shift

case "${cmd}" in
mine | replay)
	exec python3 -B "${LIB}/replay_eval.py" "${cmd}" "$@"
	;;
judge | report)
	exec python3 -B "${LIB}/replay_judge.py" "${cmd}" "$@"
	;;
-h | --help)
	usage
	exit 0
	;;
*)
	echo "replay-eval: unknown subcommand: ${cmd}" >&2
	usage
	exit 2
	;;
esac

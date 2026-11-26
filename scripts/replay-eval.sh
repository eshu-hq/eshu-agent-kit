#!/usr/bin/env bash
# scripts/replay-eval.sh — Replay evals for issue #83 (D5 scope).
#
# Mine first prompts from raw Muse transcripts, replay each prompt with the
# performance-rigor skill loaded vs stripped, blind-judge the pair, and report
# win rate with an A/A repeat noise band.
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
  bash scripts/replay-eval.sh mine --sessions-root "$XDG_DATA_HOME/muse/sessions" --out evals.json
  bash scripts/replay-eval.sh replay --evals evals.json --runner ./run-once.sh --skill performance-rigor --out pairs.json --seal seal.json --repeats 3
  bash scripts/replay-eval.sh judge --runs pairs.json --out verdict.json
  bash scripts/replay-eval.sh report --verdict verdict.json --aa-verdict verdict-aa.json --seal seal.json
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

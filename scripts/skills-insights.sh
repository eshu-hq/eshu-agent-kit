#!/usr/bin/env bash
# skills-insights.sh — report skill-use telemetry for improving how we work.
#
# Reads the JSONL event logs written by hooks/lib/skills-insights-events.sh
# (skill loads, nudge blocks, goal outcomes) and prints per-skill tables:
# loads, forced-vs-voluntary split, no-progress-session share, and outcome
# correlation — plus friction hotspots and a paste-ready summary for chat
# synthesis. Deterministic, no model calls, no network.
#
# Usage: bash scripts/skills-insights.sh [--log PATH]... [--since YYYY-MM-DD]
#   [--format text|json] [--repo PATH]... [--transcript-root PATH]...
#   [--project SUB] [--no-mine]
#   --project scopes transcript mining to sessions whose project contains
#   SUB (Claude transcripts dir slug, or Muse workspace_root).
#   Defaults to $XDG_DATA_HOME/eshu-agent-kit/skills-usage.jsonl.
#   Skill-load events exist on Claude+Muse only (no Codex/OpenCode load
#   signal); those harnesses are labeled exclusions, never ranked.
#   --format json emits the machine-readable aggregate (sessions with ordered
#   did → broke → solved timelines) for the debrief synthesis step.
#   Transcript mining (tool mix, errors, timings — counts only, never
#   message text) runs by default over the known Claude/Muse log roots
#   within --since; --no-mine skips it. --repo adds git history
#   (commits, merges, reverts, lines) per repo, defaulting to 90 days
#   without --since.
#
# Attribution ceiling, stated in the output too: aggregates show correlation
# ("sessions loading X merge cleaner"), never causation. Do not build a
# leaderboard on this.
set -uo pipefail

LOGS=()
SINCE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--log)
		[ $# -ge 2 ] || {
			echo "skills-insights: --log needs a path" >&2
			exit 1
		}
		LOGS+=("$2")
		shift 2
		;;
	--since)
		[ $# -ge 2 ] || {
			echo "skills-insights: --since needs YYYY-MM-DD" >&2
			exit 1
		}
		SINCE="$2"
		shift 2
		;;
	--format)
		[ $# -ge 2 ] || {
			echo "skills-insights: --format needs text or json" >&2
			exit 1
		}
		FORMAT="$2"
		shift 2
		;;
	--repo)
		[ $# -ge 2 ] || {
			echo "skills-insights: --repo needs a path" >&2
			exit 1
		}
		REPOS="${REPOS:-}$2
"
		shift 2
		;;
	--transcript-root)
		[ $# -ge 2 ] || {
			echo "skills-insights: --transcript-root needs a path" >&2
			exit 1
		}
		TROOTS="${TROOTS:-}$2
"
		shift 2
		;;
	--project)
		[ $# -ge 2 ] || {
			echo "skills-insights: --project needs a substring" >&2
			exit 1
		}
		PROJECT="$2"
		shift 2
		;;
	--no-mine)
		NOMINE=1
		shift
		;;
	--help | -h)
		sed -n '2,14p' "$0"
		exit 0
		;;
	*)
		echo "skills-insights: unknown argument: $1" >&2
		exit 1
		;;
	esac
done
if [ "${#LOGS[@]}" -eq 0 ]; then
	LOGS=("${XDG_DATA_HOME:-${HOME:-}/.local/share}/eshu-agent-kit/skills-usage.jsonl")
fi
FORMAT="${FORMAT:-text}"
if [ "${FORMAT}" != "text" ] && [ "${FORMAT}" != "json" ]; then
	echo "skills-insights: --format needs text or json" >&2
	exit 1
fi

command -v python3 >/dev/null 2>&1 || {
	echo "skills-insights: python3 required" >&2
	exit 1
}

REPORT_LIB="$(dirname "$0")/lib/skills-insights-report.py"
ARGS=()
# LOGS is non-empty here (defaulted above), so plain quoted expansion is safe.
for l in "${LOGS[@]}"; do ARGS+=(--log "$l"); done
[ -n "${SINCE:-}" ] && ARGS+=(--since "$SINCE")
ARGS+=(--format "${FORMAT:-text}")
while IFS= read -r r; do [ -n "$r" ] && ARGS+=(--repo "$r"); done <<<"${REPOS:-}"
while IFS= read -r r; do [ -n "$r" ] && ARGS+=(--transcript-root "$r"); done <<<"${TROOTS:-}"
[ -n "${PROJECT:-}" ] && ARGS+=(--project "${PROJECT}")
[ -n "${NOMINE:-}" ] && ARGS+=(--no-mine)
if [ "${#ARGS[@]}" -gt 0 ]; then
	exec python3 "${REPORT_LIB}" "${ARGS[@]}"
else
	exec python3 "${REPORT_LIB}"
fi

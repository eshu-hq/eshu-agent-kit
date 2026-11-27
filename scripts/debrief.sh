#!/usr/bin/env bash
# scripts/debrief.sh — Multi-harness /debrief v2 pipeline (Muse, Antigravity, Claude, Codex, OpenCode).
#
# Subcommands:
#   sessions    List discoverable sessions (id, harness, project, prompts, tools, errors)
#               for picking exact --session targets.
#   prepare     Scan/cache Stage 1 session-meta, import native Claude facets,
#               roll child subagents into parents, and emit batched digests for
#               up to --max-new uncached non-trivial sessions (default: 30d, 100).
#   cache-write Validate and atomically store Stage 2 facet JSON records.
#   aggregate   Merge Stage 1 meta, Stage 2 facets, hook logs (skills-usage.jsonl),
#               multi-agent parallelism, optional --repo git rollups, and --compare-prev.
#   diff        Compare two report snapshots (or a prior snapshot vs current aggregate)
#               to verify recommendation accountability and radar trajectory deltas.
#   render      Render offline interactive HTML from aggregate + synthesis JSON
#               into $XDG_DATA_HOME/eshu-agent-kit/debrief-reports/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib"

usage() {
	cat >&2 <<'EOF'
Usage: bash scripts/debrief.sh <sessions|prepare|cache-write|aggregate|diff|render> [options...]

Examples:
  bash scripts/debrief.sh sessions --days 14 --harness opencode --limit 20
  bash scripts/debrief.sh prepare --current
  bash scripts/debrief.sh prepare --session abc12345 --session def67890
  bash scripts/debrief.sh prepare --days 30 --max-new 100 --batch-size 10
  bash scripts/debrief.sh cache-write facets-batch-01.json
  bash scripts/debrief.sh aggregate --days 30 --repo /path/to/repo --compare-prev --out agg.json
  bash scripts/debrief.sh diff --prev snap-a.json --curr agg-b.json --repo /path/to/repo
  bash scripts/debrief.sh render --aggregate agg.json --synthesis syn.json
EOF
}

if ! command -v python3 >/dev/null 2>&1; then
	echo "debrief: python3 is required" >&2
	exit 1
fi

cmd="${1:-}"
[ -n "${cmd}" ] || {
	usage
	exit 2
}
shift

case "${cmd}" in
sessions | prepare | cache-write | aggregate | diff)
	exec python3 -B "${LIB}/debrief_pipeline.py" "${cmd}" "$@"
	;;
render)
	exec python3 -B "${LIB}/debrief_render.py" "$@"
	;;
-h | --help)
	usage
	exit 0
	;;
*)
	echo "debrief: unknown subcommand: ${cmd}" >&2
	usage
	exit 2
	;;
esac

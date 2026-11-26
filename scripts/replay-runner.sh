#!/usr/bin/env bash
# scripts/replay-runner.sh — Isolated multi-harness replay runner (issue #103).
#
# Runs a single prompt in an isolated worktree/tempdir against claude, agy, or
# muse with a target SKILL.md injected (with-skill) or stripped (without-skill),
# emitting a normalized trajectory JSON file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib"

if ! command -v python3 >/dev/null 2>&1; then
	echo "replay-runner: python3 is required" >&2
	exit 1
fi

exec python3 -B "${LIB}/replay_runner.py" "$@"

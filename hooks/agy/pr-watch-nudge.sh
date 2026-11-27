#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# .agy/hooks/pr-watch-nudge.sh -- Antigravity (agy) PostToolUse hook (run_command).
set -uo pipefail

# shellcheck source=hooks/agy/lib/agy-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agy-root.sh" 2>/dev/null || {
	exit 0
}
agy_run pr-watch-nudge pr-watch-nudge PostToolUse

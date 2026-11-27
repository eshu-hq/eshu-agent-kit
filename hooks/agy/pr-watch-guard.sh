#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# .agy/hooks/pr-watch-guard.sh -- Antigravity (agy) PreToolUse hook (run_command).
set -uo pipefail

# shellcheck source=hooks/agy/lib/agy-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agy-root.sh" 2>/dev/null || {
	exit 0
}
agy_run pr-watch-guard pr-watch-guard PreToolUse

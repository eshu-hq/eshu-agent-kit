#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/codex/pr-watch-nudge.sh -- Adapt Codex PostToolUse shell events to
# hooks/pr-watch-nudge.sh with KIT_HARNESS=codex. Never blocks.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
core_hook="${repo_root}/.claude/hooks/pr-watch-nudge.sh"
[ -x "${core_hook}" ] || exit 0
export KIT_HARNESS=codex
exec bash "${core_hook}"

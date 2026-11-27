#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# .muse/hooks/pr-watch-nudge.sh -- Muse Code PostToolUse hook (bash).
# Delegates to .claude/hooks/pr-watch-nudge.sh with KIT_HARNESS=muse.
set -uo pipefail

# shellcheck source=hooks/muse/lib/muse-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/muse-root.sh"

CLAUDE_HOOK="$(muse_repo_root)/.claude/hooks/pr-watch-nudge.sh"
[ -x "${CLAUDE_HOOK}" ] || exit 0
payload="$(cat)"
kit_muse_prepare "pr-watch-nudge.sh" "${payload}"
[ $? -eq 3 ] && exit 0
export KIT_HARNESS=muse
printf '%s' "${payload}" | exec "${CLAUDE_HOOK}"

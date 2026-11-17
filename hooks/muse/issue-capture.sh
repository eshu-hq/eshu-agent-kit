#!/usr/bin/env bash
# .muse/hooks/issue-capture.sh -- Muse Code PostToolUse hook (bash).
#
# Envelope contract, recorded live from `muse exec` (see hooks/README.md,
# Muse Code section): the Muse payload carries `session_id`, `cwd` and
# the command at `tool_input.command` under Claude's names, so those need no
# translation. `tool_response` differs: Muse sends a JSON-encoded STRING whose
# object holds the printed text under `output` (Claude sends an object with
# `stdout`). The sibling reads both shapes, so this wrapper only resolves the
# sibling by wrapper location and is the seam if the envelope ever diverges.
# Delegates to .claude/hooks/issue-capture.sh.
set -uo pipefail

# shellcheck source=hooks/muse/lib/muse-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/muse-root.sh"

CLAUDE_HOOK="$(muse_repo_root)/.claude/hooks/issue-capture.sh"
[ -x "${CLAUDE_HOOK}" ] || exit 0
exec "${CLAUDE_HOOK}"

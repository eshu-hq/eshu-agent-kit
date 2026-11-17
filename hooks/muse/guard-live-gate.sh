#!/usr/bin/env bash
# .muse/hooks/guard-live-gate.sh -- Muse Code PreToolUse hook (bash).
#
# Envelope contract, recorded live from `muse exec` (see hooks/README.md,
# Muse Code section): the Muse payload carries the command at
# `tool_input.command` and the checkout at `cwd`, both under the same names
# as Claude's, so no translation is needed. Delegates to
# .claude/hooks/guard-live-gate.sh. The per-call `CLAUDE_HOOK_ALLOW=1`
# override keeps its name: it is command text, not environment (Muse hooks
# run with a cleared environment -- exported variables do not survive).
set -uo pipefail

# shellcheck source=hooks/muse/lib/muse-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/muse-root.sh"

CLAUDE_HOOK="$(muse_repo_root)/.claude/hooks/guard-live-gate.sh"
[ -x "${CLAUDE_HOOK}" ] || exit 0
exec "${CLAUDE_HOOK}"

#!/usr/bin/env bash
# .muse/hooks/eshu-doc-staleness.sh -- Muse Code PostToolUse hook
# (write_file, edit_file).
#
# The Claude sibling drains stdin and delegates to
# scripts/check-docs-stale.sh, which is harness-neutral already, so no
# translation is needed. Delegates to .claude/hooks/eshu-doc-staleness.sh.
set -uo pipefail

# shellcheck source=hooks/muse/lib/muse-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/muse-root.sh"

CLAUDE_HOOK="$(muse_repo_root)/.claude/hooks/eshu-doc-staleness.sh"
[ -x "${CLAUDE_HOOK}" ] || exit 0
exec "${CLAUDE_HOOK}"

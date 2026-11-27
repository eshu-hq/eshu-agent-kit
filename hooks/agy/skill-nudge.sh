#!/usr/bin/env bash
# .agy/hooks/skill-nudge.sh -- Antigravity (agy) skill-nudge PreToolUse (edit_file|write_file).
#
# Translates the agy camelCase envelope for the .claude/hooks/skill-nudge.sh sibling
# and maps its verdict back to ONE agy JSON object (always exit 0). All the
# logic lives in lib/agy-root.sh and lib/agy-translate.py; see hooks/README.md
# (Antigravity section) for the envelope contract and its unverified edges.
set -uo pipefail

# shellcheck source=hooks/agy/lib/agy-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agy-root.sh" 2>/dev/null || {
	printf '{}\n'
	exit 0
}
agy_run skill-nudge skill-nudge PreToolUse

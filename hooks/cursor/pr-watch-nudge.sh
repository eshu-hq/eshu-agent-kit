#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/cursor/pr-watch-nudge.sh -- Adapt Cursor afterShellExecution events
# ({conversation_id, workspace_roots, command, output}) to
# hooks/pr-watch-nudge.sh with KIT_HARNESS=cursor. Never blocks.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core_hook=""
for cand in "${here}/../../.claude/hooks/pr-watch-nudge.sh" "${here}/../pr-watch-nudge.sh"; do
	[ -x "${cand}" ] && {
		core_hook="${cand}"
		break
	}
done
[ -n "${core_hook}" ] || exit 0

payload="$(cat)"
[ -n "${payload}" ] || exit 0
case "${payload}" in
*"/pull/"* | *"pr create"* | *"watch-pr.sh"* | *"pr-watch"*) ;;
*) exit 0 ;;
esac

normalized="$(printf '%s' "${payload}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)
sid = str(d.get("conversation_id") or d.get("session_id") or "").strip()
roots = d.get("workspace_roots")
cwd = roots[0] if isinstance(roots, list) and roots else str(d.get("cwd") or "")
cmd = str(d.get("command") or "")
out = str(d.get("output") or "")
if not sid or not cmd:
    raise SystemExit(0)
print(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": "Bash",
    "session_id": sid,
    "cwd": cwd,
    "tool_input": {"command": cmd},
    "tool_response": {"stdout": out},
}))
' 2>/dev/null)" || exit 0
[ -n "${normalized}" ] || exit 0

export KIT_HARNESS=cursor
res="$(printf '%s' "${normalized}" | bash "${core_hook}" 2>/dev/null)" || exit 0
[ -n "${res}" ] || exit 0

# Translate additionalContext to Cursor afterShellExecution response shape.
printf '%s' "${res}" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    ctx = (d.get("hookSpecificOutput") or {}).get("additionalContext") or ""
except Exception:
    ctx = ""
if ctx:
    print(json.dumps({"additional_context": ctx}))
' 2>/dev/null || exit 0
exit 0

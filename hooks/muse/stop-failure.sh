#!/usr/bin/env bash
# .muse/hooks/stop-failure.sh -- Muse StopFailure hook (no matcher).
#
# Envelope contract: the docs promise the failure category and safe
# details, but the exact keys are unpinned, so the translation below
# probes several names and defaults the rest -- an unrecognized shape is
# still worth a note with category "unknown", never a failed hook.
# Then it delegates to .claude/hooks/stop-failure.sh so hook logic stays
# in one copy.
#
# Fail-open is inherited: without python3 the payload passes through raw
# and the sibling exits 0 on its own guard.
set -uo pipefail

# shellcheck source=hooks/muse/lib/muse-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/muse-root.sh"

CLAUDE_HOOK="$(muse_repo_root)/.claude/hooks/stop-failure.sh"
payload="$(cat)"

translated="$(printf '%s' "${payload}" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print(raw, end="")
    raise SystemExit(0)
if not isinstance(d, dict):
    print(raw, end="")
    raise SystemExit(0)
def first(*keys, default=""):
    for k in keys:
        v = d.get(k)
        if isinstance(v, str) and v.strip():
            return v
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return str(v)
    return default
out = {
    "hook_event_name": "StopFailure",
    "session_id": first("session_id"),
    "cwd": first("cwd"),
    "failure_category": first("failure_category", "category", "failureCategory", "error_category", default="unknown"),
    "failure_details": first("failure_details", "details", "safe_details", "message", "error", "error_message"),
}
if isinstance(d.get("turn_id"), str) and d.get("turn_id"):
    out["turn_id"] = d["turn_id"]
print(json.dumps(out))
' 2>/dev/null)" || translated="${payload}"

kit_muse_prepare "stop-failure.sh" "${payload}"
[ $? -eq 3 ] && exit 0
[ -x "${CLAUDE_HOOK}" ] || exit 0
printf '%s' "${translated}" | exec "${CLAUDE_HOOK}"

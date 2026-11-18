#!/usr/bin/env bash
# StopFailure hook: when a turn ends in a final model failure, record an
# at-most-once resume note so the next turn starts from what was in flight
# instead of a blank slate.
#
# It cannot re-drive the model -- nothing a hook emits restarts a dead
# turn -- so this hook writes state and gets out of the way. The next
# UserPromptSubmit picks the note up through goal-refresh.sh, which deletes
# it on read. A second failure writes a fresh note, so every dead turn is
# announced exactly once.
#
# Contract:
#   stdin  : {"session_id","cwd","failure_category","failure_details",...}
#            -- any field may be missing; missing means "unknown"/empty,
#            never an error.
#   writes : <cwd>/.claude/active-goal.<sid>.resume (tmp file + rename)
#   stdout : nothing, ever. exit 0 : always -- a dead turn must not also
#            become a failed hook.
#
# Deliberately NOT here:
#   - no retry, no re-drive, no model call. Hooks observe; only the runner
#     can start a new turn, and it already retried before giving up.
#   - no goal lookup. The refresher owns goal resolution; this hook only
#     keys the note by session so the refresher finds it.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
# shellcheck source=hooks/lib/resume-note.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/resume-note.sh" 2>/dev/null || exit 0
payload="$(cat)"
[ -n "${payload}" ] || exit 0

# Defensive envelope read: unparseable input, missing keys, and wrong types
# all degrade to placeholders. Four \n-separated fields, one line each --
# every field is flattened by the parser so the separator cannot collide.
# This sibling only understands post-translation envelopes: the owning
# wrapper (hooks/muse/stop-failure.sh) maps the harness's key spellings
# onto the four names below first. A direct caller must do the same.
parsed="$(printf '%s' "${payload}" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
def g(k, dflt=""):
    v = d.get(k)
    if v is None:
        return dflt
    return str(v)
def flat(v):
    return re.sub(r"\s+", " ", v).strip()
session_id = flat(g("session_id"))
cwd = flat(g("cwd"))
print(session_id if session_id else "-")
print(cwd if cwd else "-")
cat = flat(g("failure_category") or g("category"))
print(cat if cat else "unknown")
# Prefer explicitly safe text when the envelope carries both.
det = re.sub(r"\s+", " ", g("safe_details") or g("failure_details") or g("details") or g("message"))
print(det[:500])
' 2>/dev/null)" || exit 0
{
	IFS= read -r session_id
	IFS= read -r cwd
	IFS= read -r category
	IFS= read -r details
} < <(printf '%s\n' "${parsed}")
[ -n "${session_id:-}" ] && [ "${session_id}" != "-" ] || exit 0
[ -n "${cwd:-}" ] && [ "${cwd}" != "-" ] && [ -d "${cwd}" ] || exit 0

# A note with no content says nothing; do not write an empty file the
# reader would then surface as a blank announcement. The path convention
# lives in lib/resume-note.sh so writer and reader cannot drift apart.
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts="unknown-time"
text="LAST TURN FAILED (${category}) at ${ts}: ${details:-no details recorded}"
text="${text}
The active goal, if any, is unchanged -- continue it with the next concrete step."
[ -n "${text}" ] || exit 0
note="$(resume_note_path "${cwd}" "${session_id}")"
[ -n "${note}" ] || exit 0
mkdir -p "$(dirname "${note}")" 2>/dev/null || exit 0
tmp="${note}.tmp.$$"
if printf '%s\n' "${text}" >"${tmp}" 2>/dev/null; then
	mv "${tmp}" "${note}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null
fi
exit 0

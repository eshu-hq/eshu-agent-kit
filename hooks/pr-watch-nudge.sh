#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/pr-watch-nudge.sh - PostToolUse hook (Bash / bash / run_command / shell):
# 1. When `gh pr create` opens a PR, records it as unwatched for this session,
#    logs `pr-opened` telemetry, and injects the exact watcher command via
#    `additionalContext` in the same turn.
# 2. When a valid watcher (`watch-pr.sh`, `pr-watch`, or polling loop) runs,
#    marks the PR(s) armed and logs `pr-watch-armed` telemetry.
#
# Fail-open contract: always exit 0. Honor KIT_PR_WATCH_OFF=1 / CLAUDE_HOOK_ALLOW=1.
set -uo pipefail

[ "${KIT_PR_WATCH_OFF:-0}" = "1" ] && exit 0
[ "${CLAUDE_HOOK_ALLOW:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload="$(cat)"
[ -n "${payload}" ] || exit 0

# Fast-path skip: 99% of shell commands do not create or watch PRs.
case "${payload}" in
*"/pull/"* | *"pr create"* | *"watch-pr.sh"* | *"pr-watch"*) ;;
*) exit 0 ;;
esac

libdir="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=hooks/lib/pr-watch-state.sh
. "${libdir}/pr-watch-state.sh" 2>/dev/null || exit 0
# shellcheck source=hooks/lib/skills-insights-events.sh
# shellcheck disable=SC1091
. "${libdir}/skills-insights-events.sh" 2>/dev/null || true

parsed="$(printf '%s' "${payload}" | python3 -c '
import json, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)

sid = str(d.get("session_id") or d.get("thread_id") or d.get("conversation_id") or "").strip()
if not sid:
    raise SystemExit(0)

ti = d.get("tool_input")
if isinstance(ti, str):
    try:
        ti = json.loads(ti)
    except Exception:
        ti = {"command": ti}
if not isinstance(ti, dict):
    ti = {}
cmd = str(ti.get("command") or ti.get("cmd") or ti.get("CommandLine") or "")

# Extract stdout/output across Claude ({stdout}), Muse (JSON string with output),
# and Codex/Cursor/OpenCode/agy plain-string responses.
tr = d.get("tool_response")
out_text = ""
if isinstance(tr, dict):
    out_text = str(tr.get("stdout") or tr.get("output") or "")
elif isinstance(tr, str):
    try:
        inner = json.loads(tr)
        if isinstance(inner, dict):
            out_text = str(inner.get("output") or inner.get("stdout") or tr)
        else:
            out_text = tr
    except Exception:
        out_text = tr
if not out_text and isinstance(d.get("output"), str):
    out_text = d["output"]

pr_urls = re.findall(r"https?://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([0-9]+)", out_text)
is_create = bool(re.search(r"\bgh\s+pr\s+create\b", cmd))

print(sid)
print(cmd.replace("\r", " ").replace("\n", " "))
if is_create and pr_urls:
    seen = set()
    for repo, num in pr_urls:
        if (repo, num) not in seen:
            seen.add((repo, num))
            print(f"PR\t{repo}\t{num}")
' 2>/dev/null)" || exit 0
[ -n "${parsed}" ] || exit 0

sid="$(printf '%s\n' "${parsed}" | sed -n '1p')"
cmd="$(printf '%s\n' "${parsed}" | sed -n '2p')"
pr_lines="$(printf '%s\n' "${parsed}" | tail -n +3 | grep '^PR	' || true)"

[ -n "${sid}" ] || exit 0

if [ "$(prw_classify_cmd "${cmd}")" = "valid" ]; then
	prw_mark_armed "${sid}" "${cmd}"
	command -v si_event >/dev/null 2>&1 && si_event "pr-watch-armed" "${sid}"
fi

[ -n "${pr_lines}" ] || exit 0

ws="$(prw_watch_script)"
harness="${KIT_HARNESS:-claude}"
msg=""
while IFS=$'\t' read -r _tag repo pr; do
	[ -n "${repo}" ] && [ -n "${pr}" ] || continue
	prw_record_open "${sid}" "${repo}" "${pr}"
	command -v si_event >/dev/null 2>&1 && si_event "pr-opened" "${sid}"
	piece="$(prw_guidance "${harness}" "${ws}" "${repo}" "${pr}")"
	msg="${msg:+${msg}

}${piece}"
	printf 'pr-watch-nudge: opened %s#%s (watcher not yet armed)\n' "${repo}" "${pr}" >&2
done <<<"${pr_lines}"

[ -n "${msg}" ] || exit 0

MSG="${msg}" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": os.environ["MSG"],
}}))
' 2>/dev/null || exit 0

exit 0

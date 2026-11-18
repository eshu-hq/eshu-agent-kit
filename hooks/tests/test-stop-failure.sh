#!/usr/bin/env bash
# Behavioural mirror for hooks/stop-failure.sh (the StopFailure hook).
#
# When a turn ends in a final model failure there is no agent left to ask
# for help, so this hook's only job is to leave a note the NEXT turn will
# read: what failed and when. It never blocks, never emits context of its
# own, and never touches anything but one per-session resume file.
#
# The suite drives the sibling directly (same harness shape as the other
# sibling suites): hermetic HOME/TMPDIR, no ambient goal switches.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${repo_root}/stop-failure.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/home/.claude" "${work}/tmp" "${work}/repo/.claude"
real_tmpdir="${TMPDIR:-/tmp}"
export TMPDIR="${work}/tmp"
export HOME="${work}/home"
unset CLAUDE_GOAL_FILE CLAUDE_GOAL_OFF CLAUDE_GOAL_CONSENT CLAUDE_GOAL_MAX_NUDGES XDG_CONFIG_HOME
git -C "${work}/repo" init -q 2>/dev/null || true

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1"
	failed=$((failed + 1))
}

sid="11111111-2222-3333-4444-555555555555"
resume="${work}/repo/.claude/active-goal.11111111-2222-3333-4444-555555555555.resume"
payload='{"hook_event_name":"StopFailure","session_id":"SID","cwd":"CWD","failure_category":"server_error","failure_details":"the model failed to generate a response"}'
with_ids() { printf '%s' "$1" | sed -e "s|SID|${sid}|g" -e "s|CWD|${work}/repo|g"; }

# 1. Garbage input fails open: no note anywhere, exit 0.
if printf 'garbage' | bash "${HOOK}" >/dev/null 2>&1; then
	[ ! -e "${resume}" ] &&
		ok "garbage input fails open with no note" || no "garbage input fails open with no note"
else
	no "garbage input fails open with no note"
fi

# 2. Missing session_id fails open.
if printf '{"hook_event_name":"StopFailure","cwd":"CWD"}' | sed "s|CWD|${work}/repo|" | bash "${HOOK}" >/dev/null 2>&1; then
	[ ! -e "${resume}" ] &&
		ok "missing session_id fails open" || no "missing session_id fails open"
else
	no "missing session_id fails open"
fi

# 3. Missing or unresolvable cwd fails open.
if printf '{"hook_event_name":"StopFailure","session_id":"SID"}' | sed "s|SID|${sid}|" | bash "${HOOK}" >/dev/null 2>&1; then
	ok "missing cwd fails open" || no "missing cwd fails open"
else
	no "missing cwd fails open"
fi
if printf '{"hook_event_name":"StopFailure","session_id":"SID","cwd":"/no/such/dir"}' | sed "s|SID|${sid}|" | bash "${HOOK}" >/dev/null 2>&1; then
	[ ! -e "/no/such/dir" ] &&
		ok "unresolvable cwd fails open" || no "unresolvable cwd fails open"
else
	no "unresolvable cwd fails open"
fi

# 4. No python3 fails open (the sibling never runs unparsed input).
if PATH="${work}/emptybin" "${BASH}" "${HOOK}" >/dev/null 2>&1 <<<"$(with_ids "${payload}")"; then
	[ ! -e "${resume}" ] &&
		ok "missing python3 fails open" || no "missing python3 fails open"
else
	no "missing python3 fails open"
fi

# 5. A real failure writes the resume note with category and timestamp,
# silently on stdout, and exits 0.
out="$(with_ids "${payload}" | bash "${HOOK}" 2>/dev/null)"
[ -z "${out}" ] && [ -f "${resume}" ] &&
	ok "failure writes a silent note" || no "failure writes a silent note"
rg -q 'LAST TURN FAILED \(server_error\)' "${resume}" &&
	ok "note names the failure category" || no "note names the failure category"
rg -q 'the model failed to generate a response' "${resume}" &&
	ok "note carries the failure details" || no "note carries the failure details"
rg -q '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "${resume}" &&
	ok "note carries a UTC timestamp" || no "note carries a UTC timestamp"

# 6. A second failure overwrites rather than appends: exactly one record,
# and it is the latest one.
with_ids '{"hook_event_name":"StopFailure","session_id":"SID","cwd":"CWD","failure_category":"timeout","failure_details":"second"}' |
	bash "${HOOK}" >/dev/null 2>&1
[ "$(rg -c 'LAST TURN FAILED' "${resume}")" = "1" ] &&
	ok "a second failure overwrites the note" || no "a second failure overwrites the note"
rg -q 'LAST TURN FAILED \(timeout\)' "${resume}" &&
	ok "the note holds the latest failure" || no "the note holds the latest failure"

# 7. Unknown category keys degrade to "unknown" instead of failing.
with_ids '{"hook_event_name":"StopFailure","session_id":"SID","cwd":"CWD","error":"boom"}' |
	bash "${HOOK}" >/dev/null 2>&1
rg -q 'LAST TURN FAILED \(unknown\)' "${resume}" &&
	ok "unknown categories degrade gracefully" || no "unknown categories degrade gracefully"

# 8. Nothing is ever written outside the payload cwd.
[ ! -e "${HOME}/.claude/active-goal.${sid}.resume" ] &&
	[ -z "$(find "${work}" -name '*.resume' -not -path "${work}/repo/*" 2>/dev/null)" ] &&
	ok "no note escapes the payload repo" || no "no note escapes the payload repo"

# 9. An unwritable .claude dir fails open instead of erroring out.
chmod a-w "${work}/repo/.claude"
if with_ids "${payload}" | bash "${HOOK}" >/dev/null 2>&1; then
	ok "unwritable dir fails open" || no "unwritable dir fails open"
else
	no "unwritable dir fails open"
fi
chmod u+w "${work}/repo/.claude"

# 15. When the envelope carries both raw and explicitly safe text, the note
# records the safe text only.
dual='{"hook_event_name":"StopFailure","session_id":"SID","cwd":"CWD","failure_category":"server_error","failure_details":"RAW-PRIVATE-XYZ","safe_details":"safe summary"}'
with_ids "${dual}" | bash "${HOOK}" >/dev/null 2>&1
note="$(cat "${resume}" 2>/dev/null)"
rg -q 'safe summary' <<<"${note}" && ! rg -q 'RAW-PRIVATE-XYZ' <<<"${note}" &&
	ok "safe text wins over raw details" || no "safe text wins over raw details"
rm -f "${resume}"

# 16. Round trip through the real refresher: a note written by the sibling
# surfaces once with the goal restated, and the file is gone after.
rtsid="roundtrip-aaaa-bbbb-cccc-000011112222"
printf 'SESSION: %s\nWork the widgets.\n' "${rtsid}" >"${work}/repo/.claude/active-goal.${rtsid}"
printf '{"hook_event_name":"StopFailure","session_id":"SID","cwd":"CWD","failure_category":"server_error","failure_details":"live wires"}' |
	sed -e "s|SID|${rtsid}|" -e "s|CWD|${work}/repo|" |
	bash "${HOOK}" >/dev/null 2>&1
rout="$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"SID","turn_id":"t9","cwd":"CWD","transcript_path":null}' |
	sed -e "s|SID|${rtsid}|" -e "s|CWD|${work}/repo|" |
	bash "${repo_root}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${rout}" && rg -q 'Work the widgets' <<<"${rout}" &&
	ok "round trip restates the recorded failure" || no "round trip restates the recorded failure"
[ ! -e "${work}/repo/.claude/active-goal.${rtsid}.resume" ] &&
	ok "round trip consumes the note" || no "round trip consumes the note"

printf '\nstop-failure mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

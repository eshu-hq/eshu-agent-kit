#!/usr/bin/env bash
# Behavioural mirror for hooks/muse wrappers.
#
# Installs the hooks into a scratch git repo with the real installer, then
# feeds recorded Muse payload shapes (see hooks/README.md, Muse section)
# through the installed wrappers. The wrappers only translate the envelope
# and delegate to the .claude/hooks siblings, so each case asserts the
# sibling's verdict arrives intact through the Muse shape: goal block,
# skill nudge, fresh-startup silence, and fail-open on garbage or a missing
# sibling.
set -uo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"; rm -f /tmp/claude-skill-loaded-11111111-222-*' EXIT

export HOME="${work}/home"
# Hook budget/refusal counters live under TMPDIR keyed by session+turn id;
# the suite's fixed ids would exhaust the goal budget across reruns without
# a private TMPDIR. (Skill markers are hardcoded to /tmp; the trap and the
# case-5 reset clean those by name.)
export TMPDIR="${work}/tmp"
mkdir -p "${HOME}" "${TMPDIR}"
unset CLAUDE_GOAL_FILE CLAUDE_GOAL_OFF CLAUDE_GOAL_CONSENT CLAUDE_GOAL_MAX_NUDGES XDG_CONFIG_HOME

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

repo="${work}/repo"
mkdir -p "${repo}/sub"
git -C "${repo}" init -q
"${kit}/install.sh" --hooks --repo "${repo}" >/dev/null 2>&1
MH="${repo}/.muse/hooks"
sid="11111111-2222-3333-4444-555555555555"

payload_stop='{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"t1","cwd":"REPO","transcript_path":null}'
payload_prompt='{"hook_event_name":"UserPromptSubmit","prompt":"continue","session_id":"SID","turn_id":"t1","cwd":"REPO","transcript_path":null}'
with_ids() { printf '%s' "$1" | sed -e "s|SID|${sid}|g" -e "s|REPO|${repo}|g"; }

# 1. Garbage input fails open in every wrapper.
for w in goal-continue goal-refresh skill-nudge skill-loaded guard-live-gate on-compact eshu-doc-staleness issue-capture; do
	if printf 'garbage' | bash "${MH}/${w}.sh" >/dev/null 2>&1; then
		ok "garbage payload fails open: ${w}"
	else
		no "garbage payload fails open: ${w}"
	fi
done

# 2. Fresh SessionStart stays silent; a compacted-context claim would be a lie.
out="$(printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s","cwd":"%s","transcript_path":null}' "${sid}" "${repo}" | bash "${MH}/on-compact.sh" 2>/dev/null)"
[ -z "${out}" ] && ok "on-compact is silent on fresh startup" || no "on-compact is silent on fresh startup"

# 3. Stop is refused while the seeded goal is unfinished, allowed once DONE.
# The Muse shape carries turn_id where Claude carries prompt_id.
printf 'SESSION: %s\nFinish the migration.\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
out="$(with_ids "${payload_stop}" | bash "${MH}/goal-continue.sh" 2>/dev/null)"
rg -q 'Finish the migration' <<<"${out}" &&
	ok "goal-continue blocks Stop on an unfinished goal" || no "goal-continue blocks Stop on an unfinished goal"
printf 'DONE\nFinished.\n' >"${repo}/.claude/active-goal.${sid}"
out="$(with_ids "${payload_stop}" | bash "${MH}/goal-continue.sh" 2>/dev/null)"
rg -q '"decision"[[:space:]]*:[[:space:]]*"block"' <<<"${out}" &&
	no "goal-continue allows Stop once DONE" || ok "goal-continue allows Stop once DONE"

# 4. The active goal is restated on prompt submit, from any subdirectory.
printf 'SESSION: %s\nHold the line.\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
out="$(cd "${repo}/sub" && with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'Hold the line' <<<"${out}" &&
	ok "goal-refresh restates the goal from a subdirectory" || no "goal-refresh restates the goal from a subdirectory"

# 5. A governed .go write is refused until the skill load is recorded.
nudge_in='{"hook_event_name":"PreToolUse","tool_name":"write_file","tool_input":{"path":"REPO/x.go","content":"x"},"tool_use_id":"u1","session_id":"SID","turn_id":"t1","cwd":"REPO","transcript_path":null}'
if with_ids "${nudge_in}" | bash "${MH}/skill-nudge.sh" >/dev/null 2>&1; then
	no "skill-nudge refuses an unskilled .go write"
else
	[ "$?" -eq 2 ] && ok "skill-nudge refuses an unskilled .go write" || no "skill-nudge refuses an unskilled .go write"
fi
printf '{"hook_event_name":"PostToolUse","tool_name":"read_skill","tool_input":{"name":"golang-engineering"},"tool_use_id":"u1","session_id":"%s","turn_id":"t1","cwd":"%s","transcript_path":null}' "${sid}" "${repo}" |
	bash "${MH}/skill-loaded.sh" >/dev/null 2>&1
if with_ids "${nudge_in}" | bash "${MH}/skill-nudge.sh" >/dev/null 2>&1; then
	ok "skill-nudge allows the write after read_skill records the load"
else
	no "skill-nudge allows the write after read_skill records the load"
fi
# A relative path resolves against the payload cwd before the table lookup.
rm -f /tmp/claude-skill-loaded-11111111-222-*
rel_in='{"hook_event_name":"PreToolUse","tool_name":"write_file","tool_input":{"path":"sub/y.go","content":"x"},"tool_use_id":"u1","session_id":"SID","turn_id":"t1","cwd":"REPO","transcript_path":null}'
if with_ids "${rel_in}" | bash "${MH}/skill-nudge.sh" >/dev/null 2>&1; then
	no "skill-nudge resolves a relative path against payload cwd"
else
	ok "skill-nudge resolves a relative path against payload cwd"
fi

# 6. Recorded payloads for the remaining wrappers exit clean in a plain repo.
if printf '{"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"echo hi","description":"t"},"tool_use_id":"u1","session_id":"%s","turn_id":"t1","cwd":"%s","transcript_path":null}' "${sid}" "${repo}" |
	bash "${MH}/guard-live-gate.sh" >/dev/null 2>&1; then
	ok "guard-live-gate allows a plain command"
else
	no "guard-live-gate allows a plain command"
fi
if printf '{"hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{"command":"echo hi"},"tool_use_id":"u1","tool_response":"ok","session_id":"%s","turn_id":"t1","cwd":"%s","transcript_path":null}' "${sid}" "${repo}" |
	bash "${MH}/issue-capture.sh" >/dev/null 2>&1; then
	ok "issue-capture accepts a plain bash result"
else
	no "issue-capture accepts a plain bash result"
fi
if printf '{"hook_event_name":"PostToolUse","tool_name":"write_file","tool_input":{"path":"%s/x.go"},"tool_use_id":"u1","tool_response":"ok","session_id":"%s","turn_id":"t1","cwd":"%s","transcript_path":null}' "${repo}" "${sid}" "${repo}" |
	bash "${MH}/eshu-doc-staleness.sh" >/dev/null 2>&1; then
	ok "eshu-doc-staleness no-ops without a checker"
else
	no "eshu-doc-staleness no-ops without a checker"
fi

# 7. A missing .claude/hooks sibling fails open in every wrapper, never
# blocks the tool call. on-compact needs a delegating payload to reach its
# guard at all; the rest reach it on any input.
for w in goal-continue goal-refresh skill-nudge skill-loaded guard-live-gate on-compact eshu-doc-staleness issue-capture; do
	rm "${repo}/.claude/hooks/${w}.sh"
	if [ "${w}" = on-compact ]; then
		in="$(printf '{"hook_event_name":"PreCompact","session_id":"%s","cwd":"%s","transcript_path":null}' "${sid}" "${repo}")"
	else
		in='garbage'
	fi
	if printf '%s' "${in}" | bash "${MH}/${w}.sh" >/dev/null 2>&1; then
		ok "missing sibling fails open: ${w}"
	else
		no "missing sibling fails open: ${w}"
	fi
	ln -sfn "${kit}/hooks/${w}.sh" "${repo}/.claude/hooks/${w}.sh"
done

printf '\nmuse wrappers mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

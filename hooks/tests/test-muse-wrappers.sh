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
for w in goal-continue goal-refresh skill-nudge skill-loaded guard-live-gate on-compact eshu-doc-staleness issue-capture stop-failure; do
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

# 3b. A Muse-format transcript counts completed tool effects as progress, so
# a working Muse session is never released by the no-progress budget. The
# scanner used to know only Claude/Codex records and read every Muse stop
# as no-progress: three working stops spent the budget and the fourth stop
# was allowed mid-goal, which reads exactly like a clean finish.
printf 'SESSION: %s\nShip muse work.\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
musetx="${repo}/.claude/muse-transcript.jsonl"
: >"${musetx}"
muse_work() { # one completed Muse tool effect
	printf '%s\n' '{"record_type":"event","payload_type":"tool_batch.effect.terminal","payload":{"kind":"tool_batch_effect","record":{"kind":"terminal","call_id":"c1","tool_name":"bash"}}}' >>"${musetx}"
}
muse_stop='{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"mt1","cwd":"REPO","transcript_path":"MTX"}'
muse_stop_payload() { with_ids "${muse_stop}" | sed -e "s|MTX|${musetx}|g"; }
mblocks=0
for _ in 1 2 3 4 5 6; do
	muse_work
	rg -q '"block"' <<<"$(muse_stop_payload | bash "${MH}/goal-continue.sh" 2>/dev/null)" && mblocks=$((mblocks + 1))
done
[ "${mblocks}" -eq 6 ] &&
	ok "goal-continue counts Muse tool effects as progress" || no "goal-continue counts Muse tool effects as progress (blocked ${mblocks}/6)"

# 3c. A started-but-never-completed Muse effect earns no credit: only the
# terminal record proves the agent did work.
: >"${musetx}"
printf '%s\n' '{"record_type":"event","payload_type":"tool_batch.effect.started","payload":{"kind":"tool_batch_effect","record":{"kind":"started","call_id":"c2","tool_name":"bash"}}}' >>"${musetx}"
muse_stop2='{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"mt2","cwd":"REPO","transcript_path":"MTX"}'
muse_stop_payload2() { with_ids "${muse_stop2}" | sed -e "s|MTX|${musetx}|g"; }
mblocks2=0
for _ in 1 2 3 4 5; do
	rg -q '"block"' <<<"$(muse_stop_payload2 | bash "${MH}/goal-continue.sh" 2>/dev/null)" && mblocks2=$((mblocks2 + 1))
done
[ "${mblocks2}" -eq 3 ] &&
	ok "an uncompleted Muse effect still spends the budget" || no "an uncompleted Muse effect still spends the budget (blocked ${mblocks2}/5)"

# 4. The active goal is restated on prompt submit, from any subdirectory.
printf 'SESSION: %s\nHold the line.\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
out="$(cd "${repo}/sub" && with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'Hold the line' <<<"${out}" &&
	ok "goal-refresh restates the goal from a subdirectory" || no "goal-refresh restates the goal from a subdirectory"

# 4b. A StopFailure note is restated once with the goal, then consumed.
printf 'SESSION: %s\nFinish the migration.\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\nThe active goal, if any, is unchanged.\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${out}" && rg -q 'Finish the migration' <<<"${out}" &&
	ok "resume note is restated once with the goal" || no "resume note is restated once with the goal"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "resume note is consumed after surfacing" || no "resume note is consumed after surfacing"

# 4c. A StopFailure note with no goal in flight surfaces standalone.
rm -f "${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (timeout) at 2026-01-01T00:00:00Z: stuck\nThe active goal, if any, is unchanged.\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(timeout\)' <<<"${out}" &&
	ok "resume note without a goal still surfaces" || no "resume note without a goal still surfaces"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "standalone note is consumed after surfacing" || no "standalone note is consumed after surfacing"

# 4d. A retired goal is skipped by the lookup, so a leftover note surfaces
# standalone once (a completed turn never re-announces a dead one).
printf 'DONE\nFinished.\n' >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${out}" &&
	ok "retired goal still surfaces the note once" || no "retired goal still surfaces the note once"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "surfaced note is consumed" || no "surfaced note is consumed"

# 4e. A StopFailure payload writes the resume note through the wrapper.
rm -f "${repo}/.claude/active-goal.${sid}.resume"
printf '{"hook_event_name":"StopFailure","session_id":"SID","turn_id":"t9","cwd":"REPO","failure_category":"server_error","failure_details":"the model failed"}' |
	sed -e "s|SID|${sid}|g" -e "s|REPO|${repo}|g" |
	bash "${MH}/stop-failure.sh" >/dev/null 2>&1
rg -q 'LAST TURN FAILED \(server_error\)' "${repo}/.claude/active-goal.${sid}.resume" &&
	ok "stop-failure wrapper records the dead turn" || no "stop-failure wrapper records the dead turn"
rm -f "${repo}/.claude/active-goal.${sid}.resume"

# 4f. An unrecognized StopFailure shape still leaves a note, never an error.
printf '{"hook_event_name":"StopFailure","session_id":"SID","cwd":"REPO","weird":"1"}' |
	sed -e "s|SID|${sid}|g" -e "s|REPO|${repo}|g" |
	bash "${MH}/stop-failure.sh" >/dev/null 2>&1
[ -f "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "unknown StopFailure shape degrades gracefully" || no "unknown StopFailure shape degrades gracefully"
rm -f "${repo}/.claude/active-goal.${sid}.resume"

# 4f2. A dual envelope through the wrapper records the safe text, not raw.
printf '{"hook_event_name":"StopFailure","session_id":"SID","cwd":"REPO","failure_category":"server_error","failure_details":"RAW-PRIVATE-XYZ","safe_details":"safe summary"}' |
	sed -e "s|SID|${sid}|g" -e "s|REPO|${repo}|g" |
	bash "${MH}/stop-failure.sh" >/dev/null 2>&1
note="$(cat "${repo}/.claude/active-goal.${sid}.resume" 2>/dev/null)"
rg -q 'safe summary' <<<"${note}" && ! rg -q 'RAW-PRIVATE-XYZ' <<<"${note}" &&
	ok "wrapper prefers safe text end to end" || no "wrapper prefers safe text end to end"
rm -f "${repo}/.claude/active-goal.${sid}.resume"

# 4g. An empty goal file cannot restate, but the note still gets its
# one announcement instead of lingering silently.
: >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${out}" &&
	ok "empty goal still surfaces the note once" || no "empty goal still surfaces the note once"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	rm -f "${repo}/.claude/active-goal.${sid}" &&
	ok "empty goal consumes the note" || no "empty goal consumes the note"

# 4h. A note for another session is not this session's business.
printf 'SESSION: %s\nHold the line.\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: theirs\n' >"${repo}/.claude/active-goal.00000000-0000-0000-0000-000000000000.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
! rg -q 'theirs' <<<"${out}" &&
	ok "another session's note stays untouched" || no "another session's note stays untouched"
[ -f "${repo}/.claude/active-goal.00000000-0000-0000-0000-000000000000.resume" ] &&
	ok "another session's note is not consumed" || no "another session's note is not consumed"
rm -f "${repo}/.claude/active-goal.00000000-0000-0000-0000-000000000000.resume"

# 4i. An explicit retired goal file clears a pending note silently: the
# override names that file on purpose, so there is nothing to restate.
printf 'DONE\nFinished.\n' >"${repo}/.claude/override-goal.md"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | CLAUDE_GOAL_FILE="${repo}/.claude/override-goal.md" bash "${MH}/goal-refresh.sh" 2>/dev/null)"
[ -z "${out}" ] &&
	ok "override retired goal stays silent" || no "override retired goal stays silent"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "override retired goal consumes the note" || no "override retired goal consumes the note"
rm -f "${repo}/.claude/override-goal.md"

# 4j. A pending note is never stranded by an unrestatable goal: another
# session's file, a header-only file, and a metadata-only file all surface
# the note standalone instead of leaving it to go stale.
printf 'SESSION: someone-else\nTheir objective.\n' >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${out}" && ! rg -q 'Their objective' <<<"${out}" &&
	ok "foreign goal surfaces the note alone" || no "foreign goal surfaces the note alone"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "foreign goal consumes the note" || no "foreign goal consumes the note"
printf 'SESSION: %s\n' "${sid}" >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${out}" &&
	ok "header-only goal surfaces the note alone" || no "header-only goal surfaces the note alone"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "header-only goal consumes the note" || no "header-only goal consumes the note"
printf 'CONSENT: /tmp/x\n' >"${repo}/.claude/active-goal.${sid}"
printf 'LAST TURN FAILED (server_error) at 2026-01-01T00:00:00Z: boom\n' >"${repo}/.claude/active-goal.${sid}.resume"
out="$(with_ids "${payload_prompt}" | bash "${MH}/goal-refresh.sh" 2>/dev/null)"
rg -q 'LAST TURN FAILED \(server_error\)' <<<"${out}" &&
	ok "metadata-only goal surfaces the note alone" || no "metadata-only goal surfaces the note alone"
[ ! -e "${repo}/.claude/active-goal.${sid}.resume" ] &&
	ok "metadata-only goal consumes the note" || no "metadata-only goal consumes the note"
rm -f "${repo}/.claude/active-goal.${sid}"

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
for w in goal-continue goal-refresh skill-nudge skill-loaded guard-live-gate on-compact eshu-doc-staleness issue-capture stop-failure; do
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

# --- Global install (--hooks --global muse): same wrappers, machine tree ---
# The global copies must behave identically on kit-pinned repos, never
# execute repo code (nudge table, doc checker), and defer per
# (event, matcher, hook) to a project hooks.json that registers the same
# wrapper, so nothing ever fires twice.
gx="${work}/gxdg"
HOME="${HOME}" XDG_CONFIG_HOME="${gx}" "${kit}/install.sh" --hooks --global muse >/dev/null 2>&1
GMH="${gx}/muse/agent-kit-hooks/.muse/hooks"
grepo="${work}/grepo"
mkdir -p "${grepo}/.claude" "${grepo}/.agents" "${grepo}/scripts"
git -C "${grepo}" init -q
cat "${kit}/VERSION" >"${grepo}/.agent-kit-version"
gp() { printf '%s' "$1" | sed -e "s|SID|${sid}|g" -e "s|GREPO|${grepo}|g"; }
gstop='{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"g1","cwd":"GREPO","transcript_path":null}'
gstop2='{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"g2","cwd":"GREPO","transcript_path":null}'
gstop3='{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"g3","cwd":"GREPO","transcript_path":null}'

# 8. Garbage input fails open in every global wrapper.
for w in goal-continue goal-refresh skill-nudge skill-loaded guard-live-gate on-compact eshu-doc-staleness issue-capture stop-failure; do
	if printf 'garbage' | bash "${GMH}/${w}.sh" >/dev/null 2>&1; then
		ok "global garbage payload fails open: ${w}"
	else
		no "global garbage payload fails open: ${w}"
	fi
done

# 9. Global nudge enforces the builtin table and never sources the repo's
# own nudge table (repo code must not run under machine-wide authority).
rm -f /tmp/claude-skill-loaded-11111111-222-*
printf 'touch "%s/nudge-sentinel"\nnudge_ids_for() { IDS=""; NOTE=""; }\n' "${work}" >"${grepo}/.agents/nudge-table.sh"
gnudge='{"hook_event_name":"PreToolUse","tool_name":"TOOL","tool_input":{"path":"GREPO/x.go","content":"x"},"tool_use_id":"u1","session_id":"SID","turn_id":"t1","cwd":"GREPO","transcript_path":null}'
if gp "${gnudge/TOOL/write_file}" | bash "${GMH}/skill-nudge.sh" >/dev/null 2>&1; then
	no "global skill-nudge refuses and never sources the repo table"
else
	[ ! -e "${work}/nudge-sentinel" ] &&
		ok "global skill-nudge refuses and never sources the repo table" || no "global skill-nudge refuses and never sources the repo table"
fi

# 10. Global doc-staleness never executes the repo's checker script.
printf '#!/usr/bin/env bash\ntouch "%s/stale-sentinel"\n' "${work}" >"${grepo}/scripts/check-docs-stale.sh"
chmod +x "${grepo}/scripts/check-docs-stale.sh"
(cd "${grepo}" && gp "${gnudge/TOOL/write_file}" | sed 's/PreToolUse/PostToolUse/' | bash "${GMH}/eshu-doc-staleness.sh" >/dev/null 2>&1)
[ ! -e "${work}/stale-sentinel" ] &&
	ok "global doc-staleness never runs the repo checker" || no "global doc-staleness never runs the repo checker"

# 11. Deferral: with the full project hooks.json the global Stop copy stays
# silent; partial files defer exactly the registered (event, matcher, hook).
printf 'SESSION: %s\nShip global.\n' "${sid}" >"${grepo}/.claude/active-goal.${sid}"
out="$(gp "${gstop}" | bash "${GMH}/goal-continue.sh" 2>/dev/null)"
rg -q 'Ship global' <<<"${out}" &&
	ok "global goal-continue blocks without project hooks" || no "global goal-continue blocks without project hooks"
mkdir -p "${grepo}/.muse"
cp "${kit}/hooks/muse/hooks.json" "${grepo}/.muse/hooks.json"
out="$(gp "${gstop2}" | bash "${GMH}/goal-continue.sh" 2>/dev/null)"
[ -z "${out}" ] && ok "global copy defers to a full project hooks.json" || no "global copy defers to a full project hooks.json"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"exec \\"$r/.muse/hooks/goal-continue.sh\\""}]}]}}\n' >"${grepo}/.muse/hooks.json"
out="$(gp "${gstop3}" | bash "${GMH}/goal-continue.sh" 2>/dev/null)"
[ -z "${out}" ] && ok "partial project file defers its Stop entry" || no "partial project file defers its Stop entry"
rm -f /tmp/claude-skill-loaded-11111111-222-*
if gp "${gnudge/TOOL/write_file}" | bash "${GMH}/skill-nudge.sh" >/dev/null 2>&1; then
	no "partial project file leaves other hooks to the global copy"
else
	ok "partial project file leaves other hooks to the global copy"
fi
printf '{"hooks":{"PreToolUse":[{"matcher":"write_file","hooks":[{"type":"command","command":"exec \\"$r/.muse/hooks/skill-nudge.sh\\""}]}]}}\n' >"${grepo}/.muse/hooks.json"
if gp "${gnudge/TOOL/write_file}" | bash "${GMH}/skill-nudge.sh" >/dev/null 2>&1; then
	ok "matcher-scoped entry defers write_file only (write side)"
else
	no "matcher-scoped entry defers write_file only (write side)"
fi
if gp "${gnudge/TOOL/edit_file}" | bash "${GMH}/skill-nudge.sh" >/dev/null 2>&1; then
	no "matcher-scoped entry defers write_file only (edit side)"
else
	ok "matcher-scoped entry defers write_file only (edit side)"
fi
printf '{"hooks":{"PreToolUse":[{"matcher":"write_file|edit_file","hooks":[{"type":"command","command":"exec \\"$r/.muse/hooks/skill-nudge.sh\\""}]}]}}\n' >"${grepo}/.muse/hooks.json"
if gp "${gnudge/TOOL/edit_file}" | bash "${GMH}/skill-nudge.sh" >/dev/null 2>&1; then
	ok "pipe-list matcher defers both listed tools"
else
	no "pipe-list matcher defers both listed tools"
fi
rm -f "${grepo}/.muse/hooks.json"

# 11b. Deferral covers StopFailure too: a project hooks.json that registers
# the StopFailure wrapper quiets the global copy for that event only.
gfail='{"hook_event_name":"StopFailure","session_id":"SID","turn_id":"t9","cwd":"GREPO","failure_category":"server_error","failure_details":"boom"}'
out="$(gp "${gfail}" | bash "${GMH}/stop-failure.sh" 2>/dev/null)"
[ -f "${grepo}/.claude/active-goal.${sid}.resume" ] &&
	ok "global stop-failure records without project hooks" || no "global stop-failure records without project hooks"
rm -f "${grepo}/.claude/active-goal.${sid}.resume"
printf '{"hooks":{"StopFailure":[{"matcher":"","hooks":[{"type":"command","command":"exec \\"$r/.muse/hooks/stop-failure.sh\\""}]}]}}\n' >"${grepo}/.muse/hooks.json"
out="$(gp "${gfail}" | bash "${GMH}/stop-failure.sh" 2>/dev/null)"
[ -z "${out}" ] && [ ! -e "${grepo}/.claude/active-goal.${sid}.resume" ] &&
	ok "project StopFailure entry defers the global copy" || no "project StopFailure entry defers the global copy"
rm -f "${grepo}/.muse/hooks.json"

# 12. Unpinned repo: nudge stays silent, goal machinery still works globally.
urepo="${work}/urepo"
mkdir -p "${urepo}"
git -C "${urepo}" init -q
up() { printf '%s' "$1" | sed -e "s|SID|${sid}|g" -e "s|UREPO|${urepo}|g"; }
unud='{"hook_event_name":"PreToolUse","tool_name":"write_file","tool_input":{"path":"UREPO/x.go","content":"x"},"tool_use_id":"u1","session_id":"SID","turn_id":"t1","cwd":"UREPO","transcript_path":null}'
if up "${unud}" | bash "${GMH}/skill-nudge.sh" >/dev/null 2>&1; then
	ok "global nudge is silent in an unpinned repo"
else
	no "global nudge is silent in an unpinned repo"
fi
up '{"hook_event_name":"UserPromptSubmit","prompt":"/goal Ship unpinned","session_id":"SID","turn_id":"t1","cwd":"UREPO","transcript_path":null}' |
	bash "${GMH}/goal-refresh.sh" >/dev/null 2>&1
out="$(up '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"status","session_id":"SID","turn_id":"t2","cwd":"UREPO","transcript_path":null}' | bash "${GMH}/goal-continue.sh" 2>/dev/null)"
rg -q 'Ship unpinned' <<<"${out}" &&
	ok "global goal write + Stop block work in an unpinned repo" || no "global goal write + Stop block work in an unpinned repo"

# 13. Project copy with payload cwd in a nested git repo keeps repo-code
# paths: only the global tree may gate them. CLAUDE_PROJECT_DIR names the
# outer repo the way the Muse runtime sets it.
git -C "${repo}/sub" init -q
rm "${repo}/scripts/check-docs-stale.sh"
printf '#!/usr/bin/env bash\ntouch "%s/nested-sentinel"\n' "${work}" >"${repo}/scripts/check-docs-stale.sh"
chmod +x "${repo}/scripts/check-docs-stale.sh"
(cd "${repo}/sub" && printf '{"hook_event_name":"PostToolUse","tool_name":"write_file","tool_input":{"path":"%s/x.go"},"tool_use_id":"u1","tool_response":"ok","session_id":"%s","turn_id":"t9","cwd":"%s/sub","transcript_path":null}' "${repo}" "${sid}" "${repo}" |
	CLAUDE_PROJECT_DIR="${repo}" bash "${MH}/eshu-doc-staleness.sh" >/dev/null 2>&1)
[ -e "${work}/nested-sentinel" ] &&
	ok "project copy runs the repo checker from a nested cwd" || no "project copy runs the repo checker from a nested cwd"

# 14. Non-git workspace: no deferral machinery errors, clean exit.
mkdir -p "${work}/plain"
if printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"%s","turn_id":"t1","cwd":"%s/plain","transcript_path":null}' "${sid}" "${work}" |
	bash "${GMH}/goal-refresh.sh" >/dev/null 2>&1; then
	ok "global wrapper is clean in a non-git workspace"
else
	no "global wrapper is clean in a non-git workspace"
fi

printf '\nmuse wrappers mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

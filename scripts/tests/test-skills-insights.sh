#!/usr/bin/env bash
# Behavioural suite for skills-insights telemetry: event emission from the
# hooks plus aggregation in scripts/skills-insights.sh.
#
# Every hook keeps its existing contract (markers, exit codes, block JSON);
# each case below asserts the telemetry line in addition, never instead.
# All state stays under a private XDG_DATA_HOME/HOME/TMPDIR so a run never
# touches the real log or ambient session files.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="${KIT_DIR}/hooks"
REPORT="${KIT_DIR}/scripts/skills-insights.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg"
export HOME="${work}/home"
export TMPDIR="${work}/tmp"
mkdir -p "${XDG_DATA_HOME}" "${HOME}" "${TMPDIR}"
unset ESHU_SKILLS_TELEMETRY_OFF CLAUDE_GOAL_FILE CLAUDE_GOAL_OFF KIT_HARNESS
LOG="${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"

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
loglines() { [ -f "${LOG}" ] && wc -l <"${LOG}" || echo 0; }

SID="testsession1"

# 1. A Skill load writes the marker (existing contract) and one event.
out="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s-uuid-extra","tool_input":{"skill":"code-review"}}' "${SID}" |
	bash "${HOOKS}/skill-loaded.sh" 2>/dev/null)"
[ -z "${out}" ] && [ -f "/tmp/claude-skill-loaded-${SID}-code-review" ] &&
	ok "skill load keeps marker, stays silent" || no "skill load keeps marker, stays silent"
rm -f "/tmp/claude-skill-loaded-${SID}-code-review"
rg -q '"type": "skill-load"' "${LOG}" && rg -q '"skill": "code-review"' "${LOG}" &&
	rg -q "\"session\": \"${SID}\"" "${LOG}" && rg -q '"harness": "claude"' "${LOG}" &&
	ok "skill load logs session-truncated bare-id claude event" ||
	no "skill load logs session-truncated bare-id claude event"

# 2. Plugin prefixes normalize; harness follows KIT_HARNESS.
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"eshu-agent-kit:issue-driver"}}' "${SID}" |
	KIT_HARNESS=muse bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
rg -q '"skill": "issue-driver"' "${LOG}" && rg -q '"harness": "muse"' "${LOG}" &&
	ok "plugin prefix stripped, muse harness recorded" ||
	no "plugin prefix stripped, muse harness recorded"
rm -f "/tmp/claude-skill-loaded-${SID}-issue-driver"

# 3. Garbage fails open with no event; opt-out writes nothing.
before="$(loglines)"
printf 'garbage' | bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
[ "$(loglines)" = "${before}" ] && ok "garbage payload logs nothing" || no "garbage payload logs nothing"
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"publish"}}' "${SID}" |
	ESHU_SKILLS_TELEMETRY_OFF=1 bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
[ "$(loglines)" = "${before}" ] && [ -f "/tmp/claude-skill-loaded-${SID}-publish" ] &&
	ok "opt-out keeps the marker, suppresses the event" || no "opt-out keeps the marker, suppresses the event"
rm -f "/tmp/claude-skill-loaded-${SID}-publish"

# 4. A nudge block logs the demanded skills (builtin table, pinned checkout).
repo="${work}/repo"
mkdir -p "${repo}"
touch "${repo}/.agent-kit-version"
if printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/x.go"},"session_id":"%s"}' "${repo}" "${SID}" |
	bash "${HOOKS}/skill-nudge.sh" >/dev/null 2>&1; then
	no "nudge block still exits nonzero"
else
	[ "$?" -eq 2 ] && rg -q '"type": "nudge-block"' "${LOG}" &&
		rg -q '"skills": \["golang-engineering"\]' "${LOG}" &&
		ok "nudge block logs demanded skills" ||
		no "nudge block logs demanded skills (exit $?)"
fi

# 5. si_event sanitizes hostile input and never fails the caller.
bash -c 'source "'"${HOOKS}"'/lib/skills-insights-events.sh"; si_event "skill-load" "a/b\"c
d" "{\"skill\":\"x\"}"; echo "caller-survives=$?"' >/dev/null 2>&1
rg -q '"session": "a-b-c-d"' "${LOG}" &&
	ok "session ids sanitize to marker charset" || no "session ids sanitize to marker charset"
before="$(loglines)"
bash -c 'source "'"${HOOKS}"'/lib/skills-insights-events.sh"; si_event "" "" ""' >/dev/null 2>&1
[ "$(loglines)" = "${before}" ] && ok "empty type/session logs nothing" || no "empty type/session logs nothing"

# 6. Rotation keeps one spare at 5 MiB.
printf 'x%.0s' $(seq 1 6291456) >"${LOG}"
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"release"}}' "${SID}" |
	bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
[ -f "${LOG}.1" ] && [ "$(loglines)" -eq 1 ] &&
	ok "log rotates keeping one spare" || no "log rotates keeping one spare"
rm -f "/tmp/claude-skill-loaded-${SID}-release"

# 7. DONE goal logs goal-done and allows the stop.
goal="${work}/goal.md"
printf 'DONE\nFinished.\n' >"${goal}"
out="$(printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"g1","cwd":"%s"}' "${SID}" "${work}" |
	CLAUDE_GOAL_FILE="${goal}" bash "${HOOKS}/goal-continue.sh" 2>/dev/null)"
rg -q '"decision"[[:space:]]*:[[:space:]]*"block"' <<<"${out}" &&
	no "DONE goal allows the stop" || ok "DONE goal allows the stop"
rg -q '"type": "goal-done"' "${LOG}" &&
	ok "DONE goal logs goal-done" || no "DONE goal logs goal-done"

# 8. Exhausted budget logs goal-released with the stop count.
printf 'Grind on.\n' >"${goal}"
printf '3 0' >"${TMPDIR}/claude-goal-nudge-${SID}-t2"
out="$(printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"t2","cwd":"%s"}' "${SID}" "${work}" |
	CLAUDE_GOAL_FILE="${goal}" bash "${HOOKS}/goal-continue.sh" 2>/dev/null)"
rg -q '"decision"[[:space:]]*:[[:space:]]*"block"' <<<"${out}" &&
	no "exhausted budget allows the stop" || ok "exhausted budget allows the stop"
rg -q '"type": "goal-released"' "${LOG}" && rg -q '"stops": 3' "${LOG}" &&
	ok "exhaustion logs goal-released with count" || no "exhaustion logs goal-released with count"

# 9. A continued stop logs progress; a live watcher logs blocked-watcher.
out="$(printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"t3","cwd":"%s"}' "${SID}" "${work}" |
	CLAUDE_GOAL_FILE="${goal}" bash "${HOOKS}/goal-continue.sh" 2>/dev/null)"
rg -q '"decision"[[:space:]]*:[[:space:]]*"block"' <<<"${out}" &&
	rg -q '"type": "goal-continued"' "${LOG}" &&
	ok "continued stop blocks and logs progress" || no "continued stop blocks and logs progress"
printf 'BLOCKED: waiting on CI WATCH=%s\n' "$$" >"${goal}"
out="$(printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"t4","cwd":"%s"}' "${SID}" "${work}" |
	CLAUDE_GOAL_FILE="${goal}" bash "${HOOKS}/goal-continue.sh" 2>/dev/null)"
rg -q '"decision"[[:space:]]*:[[:space:]]*"block"' <<<"${out}" &&
	no "live watcher allows the stop" || ok "live watcher allows the stop"
rg -q '"type": "goal-blocked-watcher"' "${LOG}" &&
	ok "live watcher logs blocked-watcher" || no "live watcher logs blocked-watcher"

# 10. Report aggregates a fixture log: joins, outcomes, filters, merge.
fix="${work}/fix.jsonl"
cat >"${fix}" <<'EOF'
{"harness":"claude","session":"s1","ts":"2026-11-20T10:00:00+00:00","type":"skill-load","detail":{"skill":"code-review"}}
{"harness":"claude","session":"s1","ts":"2026-11-20T10:01:00+00:00","type":"nudge-block","detail":{"skills":["code-review"]}}
{"harness":"claude","session":"s1","ts":"2026-11-20T10:05:00+00:00","type":"goal-continued","detail":{"progress":2,"remaining":2}}
{"harness":"claude","session":"s1","ts":"2026-11-20T10:09:00+00:00","type":"goal-done","detail":{}}
{"harness":"muse","session":"s2","ts":"2026-11-21T10:00:00+00:00","type":"skill-load","detail":{"skill":"publish"}}
{"harness":"muse","session":"s2","ts":"2026-11-21T10:06:00+00:00","type":"goal-released","detail":{"stops":3}}
EOF
rep="$(bash "${REPORT}" --log "${fix}")"
rg -q "code-review \| 1 load \| 1 [(]100%[)] \| 1 session \| 1 \| 0 \| 0%" <<<"${rep}" &&
	rg -q "publish \| 1 load \| 0 [(]0%[)] \| 1 session \| 0 \| 1 \| 100%" <<<"${rep}" &&
	rg -q "nudge-blocked skills" <<<"${rep}" &&
	rg -q "goal-done=1, goal-released=1" <<<"${rep}" &&
	rg -q "paste into chat" <<<"${rep}" &&
	ok "report joins loads, blocks, outcomes" || no "report joins loads, blocks, outcomes"
rg -q "publish \| 1 load" <<<"$(bash "${REPORT}" --log "${fix}" --since 2026-11-21)" &&
	! rg -q "code-review \|" <<<"$(bash "${REPORT}" --log "${fix}" --since 2026-11-21)" &&
	ok "--since filters by date" || no "--since filters by date"
before="$(rg -c '"type": "goal-done"' "${LOG}" || true)"
out="$(printf '{"hook_event_name":"Stop","session_id":"nogoal-session","prompt_id":"t9","cwd":"%s"}' "${work}" |
	bash "${HOOKS}/goal-continue.sh" 2>/dev/null)"
[ "$(rg -c '"type": "goal-done"' "${LOG}" || true)" = "${before}" ] &&
	ok "goalless stop emits no goal-done" || no "goalless stop emits no goal-done"
mkdir -p "${work}/.claude"
printf 'DONE\nFinished.\n' >"${work}/.claude/active-goal.retiredsess"
before="$(rg -c '"type": "goal-done"' "${LOG}" || true)"
printf '{"hook_event_name":"Stop","session_id":"retiredsess","prompt_id":"t9","cwd":"%s"}' "${work}" |
	bash "${HOOKS}/goal-continue.sh" >/dev/null 2>&1
[ "$(rg -c '"type": "goal-done"' "${LOG}" || true)" = "$((before + 1))" ] &&
	ok "retired tombstone still logs goal-done" || no "retired tombstone still logs goal-done"
rm -rf "${work}/.claude"
printf '{"harness":"codex","session":"s9","ts":"2026-11-22T10:00:00+00:00","type":"goal-done","detail":{}}' >"${work}/fix2.jsonl"
out="$(bash "${REPORT}" --log "${fix}" --log "${work}/fix2.jsonl")"
rg -q "3 sessions" <<<"${out}" && rg -q "harnesses observed: claude, codex, muse" <<<"${out}" &&
	ok "multiple logs merge" || no "multiple logs merge"
out="$(bash "${REPORT}" --log "${work}/missing.jsonl")"
rg -q "no events yet" <<<"${out}" &&
	ok "missing log reports empty, stays green" || no "missing log reports empty, stays green"
printf '{"type":"skill-load","detail":{"skill":"ghost"}}' >"${work}/hostile.jsonl"
out="$(bash "${REPORT}" --log "${work}/hostile.jsonl")" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && ! rg -q "ghost|Traceback" <<<"${out}" &&
	ok "session-less line is skipped, not fatal" || no "session-less line is skipped, not fatal"
mkdir -p "${XDG_DATA_HOME}/eshu-agent-kit"
printf '{"harness":"muse","session":"dflt","ts":"2026-11-24T10:00:00+00:00","type":"skill-load","detail":{"skill":"publish"}}\n' \
	>"${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"
out="$(bash "${REPORT}")"
rg -q "publish \| 1 load" <<<"${out}" &&
	ok "default log path aggregates without --log" || no "default log path aggregates without --log"

printf '\nskills-insights: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

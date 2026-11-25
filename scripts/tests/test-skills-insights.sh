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
trap '[ -f "${work}/miners-away.py" ] && mv "${work}/miners-away.py" "${KIT_DIR}/scripts/lib/skills-insights-miners.py"; [ -f "${work}/text-away.py" ] && mv "${work}/text-away.py" "${KIT_DIR}/scripts/lib/skills-insights-text.py"; rm -rf "${work}"' EXIT
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
{"harness":"claude","session":"s1","ts":"2026-11-20T10:05:00+00:00","type":"goal-continued","detail":{"progress":2,"remaining":2,"turn":"t1"}}
{"harness":"claude","session":"s1","ts":"2026-11-20T10:09:00+00:00","type":"goal-done","detail":{}}
{"harness":"muse","session":"s2","ts":"2026-11-21T10:00:00+00:00","type":"skill-load","detail":{"skill":"publish"}}
{"harness":"muse","session":"s2","ts":"2026-11-21T10:02:00+00:00","type":"model-failure","detail":{"category":"server_error"}}
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
rm -f "${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"
mv "${KIT_DIR}/scripts/lib/skills-insights-miners.py" "${work}/miners-away.py"
out="$(bash "${REPORT}" --log "${fix}" --no-mine --repo "${work}/not-a-repo" 2>&1)" && rc=0 || rc=1
mv "${work}/miners-away.py" "${KIT_DIR}/scripts/lib/skills-insights-miners.py"
[ "${rc}" -eq 0 ] && rg -q "code-review \| 1 load" <<<"${out}" &&
	! rg -q "Traceback" <<<"${out}" &&
	ok "missing miners file degrades, never crashes" || no "missing miners file degrades, never crashes"
mv "${KIT_DIR}/scripts/lib/skills-insights-text.py" "${work}/text-away.py"
out="$(bash "${REPORT}" --log "${fix}" --no-mine 2>&1)" && rc=0 || rc=1
mv "${work}/text-away.py" "${KIT_DIR}/scripts/lib/skills-insights-text.py"
[ "${rc}" -eq 0 ] && rg -q "renderer unavailable" <<<"${out}" &&
	rg -q "code-review: 1 load" <<<"${out}" &&
	! rg -q "Traceback" <<<"${out}" &&
	ok "missing text renderer degrades, never crashes" || no "missing text renderer degrades, never crashes"

# 11. A dead turn logs its category, never its details.
out="$(printf '{"hook_event_name":"StopFailure","session_id":"deadsess01","cwd":"%s","failure_category":"server_error","failure_details":"sekret-payload-text"}' "${work}" |
	bash "${HOOKS}/stop-failure.sh" 2>/dev/null)"
[ "$?" -eq 0 ] && rg -q '"type": "model-failure"' "${LOG}" &&
	rg -q '"category": "server_error"' "${LOG}" &&
	! rg -q "sekret-payload-text" "${LOG}" &&
	ok "dead turn logs category, never details" || no "dead turn logs category, never details"

# 12. Timelines, wins, friction, and JSON validate end to end.
rep="$(bash "${REPORT}" --log "${fix}")"
rg -q "did:load[+]publish . broke:model-failure[(]server_error[)] . end:released" <<<"${rep}" &&
	rg -q "wins . sessions that reached DONE" <<<"${rep}" &&
	rg -q "friction . stalled sessions" <<<"${rep}" &&
	rg -q "model failures by category" <<<"${rep}" &&
	ok "text prints timelines, wins, friction" || no "text prints timelines, wins, friction"
bash "${REPORT}" --log "${fix}" --format json >"${work}/rep.json" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/rep.json" <<'PYEOF' && ok "JSON validates with timelines" || no "JSON validates with timelines"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["meta"]["sessions"] == 2, d["meta"]
s2 = next(s for s in d["sessions"] if s["session"] == "s2")
assert s2["timeline"] == ["did:load+publish", "broke:model-failure(server_error)", "end:released"], s2
s1 = next(s for s in d["sessions"] if s["session"] == "s1")
assert s1["timeline"][-1] == "solved:done", s1
assert d["friction"]["model_failures"] == {"server_error": 1}, d["friction"]
s1turns = next(s for s in d["sessions"] if s["session"] == "s1")["turns"]
assert s1turns == [{"turn": "t1", "progress": 2, "stops": 1}], s1turns
PYEOF

# 13. Transcript miners attribute tools, errors, prompts (counts only).
troot="${work}/tlogs"
mkdir -p "${troot}/claude" "${troot}/muse/sess1"
cat >"${troot}/claude/claude-fix-1.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]},"timestamp":"2026-11-20T10:00:00.000Z","sessionId":"claude-fix-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{}}]},"timestamp":"2026-11-20T10:00:05.000Z","sessionId":"claude-fix-1"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":"boom"}]},"timestamp":"2026-11-20T10:00:06.000Z","sessionId":"claude-fix-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fixed"}]},"timestamp":"2026-11-20T10:00:10.000Z","sessionId":"claude-fix-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Agent","input":{"description":"scan it","subagent_type":"scan-eshu","model":"sonnet"}}]},"timestamp":"2026-11-20T10:00:12.000Z","sessionId":"claude-fix-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu3","name":"Skill","input":{"skill":"eshu-agent-kit:code-review"}}]},"timestamp":"2026-11-20T10:00:13.000Z","sessionId":"claude-fix-1"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"thanks"}]},"timestamp":"2026-11-20T10:00:40.000Z","sessionId":"claude-fix-1"}
EOF
mkdir -p "${troot}/muse2/parent-sess/subagent/child-1"
cat >"${troot}/muse2/parent-sess/subagent/child-1/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795000010000000,"stream":{"id":"child-1","kind":"x"},"payload":{"record":{"kind":"started","call_id":"c9","tool_name":"Bash"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795000011000000,"stream":{"id":"child-1","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"c9","outcome":{"kind":"completed"}}}}
EOF
cat >"${troot}/muse/sess1/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"runtime.session.metadata","recorded_at":1794999999000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"workspace_root":"/repo/alpha"}}}
{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795000000000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{}}
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795000001000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"started","call_id":"c1","tool_name":"Bash"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795000002000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"c1","outcome":{"kind":"failed"}}}}
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795000003000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"started","call_id":"c2","tool_name":"read_skill"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795000004000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"c2","outcome":{"kind":"completed"}}}}
{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795000005000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{}}
{"record_type":"event","payload_type":"subagent.control.spawn_accepted","recorded_at":1795000006000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"spawn_accepted","subagent_id":"child-1","task_id":"task-1","role":"develop-eshu","depth":1}}}
{"record_type":"event","payload_type":"run.model.configured","recorded_at":1795000007000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"configured","command_id":"cmd-1","model_id":"muse-spark-1.3"}}}
{"record_type":"event","payload_type":"run.model.configured","recorded_at":1795000008000000,"stream":{"id":"muse-fix-1","kind":"x"},"payload":{"record":{"kind":"configured","command_id":"cmd-9","model_id":"muse-ember-1.0"}}}
EOF
python3 - "${troot}" <<'PYEOF' && ok "miners attribute tools, errors, prompts" || no "miners attribute tools, errors, prompts"
import json, subprocess, sys
troot = sys.argv[1]
out = subprocess.run([sys.executable,
                      "scripts/lib/skills-insights-miners.py",
                      "--root", troot + "/claude", "--root", troot + "/muse"],
                     capture_output=True, text=True)
assert out.returncode == 0, out.stderr
d = json.loads(out.stdout)
assert len(d["sessions"]) == 2, d
cf = next(s for s in d["sessions"] if s["id"] == "claude-fix-1")
assert cf["prompts"] == 2 and cf["tools"] == {"Bash": 1, "Agent": 1, "Skill": 1}, cf
assert cf["errors"] == {"Bash": 1}, cf
assert len(cf["response_gaps"]) == 1, cf
assert cf["skill_loads"] == ["code-review"], cf
mu = next(s for s in d["sessions"] if s["id"] == "muse-fix-1")
assert mu["prompts"] == 2 and mu["tools"] == {"Bash": 1, "read_skill": 1}, mu
assert mu["errors"] == {"Bash": 1}, mu
assert mu["subagents"] == 1 and mu["subagent_roles"] == {"develop-eshu": 1}, mu
assert mu.get("subagent_models", {}) == {}, mu
assert mu["session_models"] == {"muse-spark-1.3": 1, "muse-ember-1.0": 1}, mu
assert mu["max_depth"] == 1, mu
assert cf["subagents"] == 1 and cf["subagent_roles"] == {"scan-eshu": 1}, cf
assert cf["subagent_models"] == {"sonnet": 1}, cf
child = subprocess.run([sys.executable,
                        "scripts/lib/skills-insights-miners.py",
                        "--root", troot + "/muse2"],
                       capture_output=True, text=True)
assert child.returncode == 0, child.stderr
kid = json.loads(child.stdout)["sessions"]
assert len(kid) == 1 and kid[0]["parent_session"] == "parent-sess", kid
PYEOF
# 13b. Sessions carry a project (Claude dir slug, Muse workspace_root);
# --project scopes mining to one repo, fail-open on anything else.
# sess2 carries a decoy workspace_root string in a non-metadata record:
# the filter must read the metadata signal, not the raw string.
mkdir -p "${troot}/muse/sess2"
cat >"${troot}/muse/sess2/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"custom.note","recorded_at":1795000010000000,"stream":{"id":"sess2","kind":"x"},"payload":{"record":{"workspace_root":"/repo/alpha"}}}
{"record_type":"event","payload_type":"runtime.session.metadata","recorded_at":1795000011000000,"stream":{"id":"sess2","kind":"x"},"payload":{"record":{"workspace_root":"/repo/beta"}}}
EOF
python3 - "${troot}" <<'PYEOF' && ok "sessions carry project, --project scopes" || no "sessions carry project, --project scopes"
import json, subprocess, sys
troot = sys.argv[1]
base = [sys.executable, "scripts/lib/skills-insights-miners.py",
        "--root", troot + "/claude", "--root", troot + "/muse"]
d = json.loads(subprocess.run(base, capture_output=True, text=True).stdout)
by_id = {s["id"]: s for s in d["sessions"]}
assert by_id["claude-fix-1"]["project"] == "claude", by_id["claude-fix-1"]
assert by_id["muse-fix-1"]["project"] == "/repo/alpha", by_id["muse-fix-1"]
assert by_id["sess2"]["project"] == "/repo/beta", by_id["sess2"]
scoped = json.loads(subprocess.run(
    base + ["--project", "alpha"], capture_output=True, text=True).stdout)
assert [s["id"] for s in scoped["sessions"]] == ["muse-fix-1"], scoped
scoped2 = json.loads(subprocess.run(
    base + ["--project", "claude"], capture_output=True, text=True).stdout)
assert [s["id"] for s in scoped2["sessions"]] == ["claude-fix-1"], scoped2
scoped3 = json.loads(subprocess.run(
    base + ["--project", "beta"], capture_output=True, text=True).stdout)
assert [s["id"] for s in scoped3["sessions"]] == ["sess2"], scoped3
PYEOF
# 13c. Muse read_skill args mine into named loads (snapshot repeats dedupe).
mkdir -p "${troot}/muse3/rs-sess"
cat >"${troot}/muse3/rs-sess/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"runtime.session.metadata","recorded_at":1795000020000000,"stream":{"id":"rs-1","kind":"x"},"payload":{"record":{"workspace_root":"/repo/gamma"}}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795000021000000,"stream":{"id":"rs-1","kind":"x"},"payload":{"event":{"tool_calls":[{"call_id":"c1","id":"t1","name":"read_skill","args":"{\"name\":\"issue-driver\"}"},{"call_id":"c2","id":"t2","name":"bash","args":"{\"command\":\"true\"}"}]}}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795000022000000,"stream":{"id":"rs-1","kind":"x"},"payload":{"event":{"tool_calls":[{"call_id":"c1","id":"t1","name":"read_skill","args":"{\"name\":\"issue-driver\"}"},{"call_id":"c3","id":"t3","name":"read_skill","args":"{\"name\":\"eshu-agent-kit:publish\"}"},{"call_id":"c4","id":"t4","name":"read_skill","args":"not-json"},{"call_id":"c5","id":"t5","name":"read_skill","args":"{\"name\":\"/home/u/.claude/skills/eshu-code-review/SKILL.md\"}"}]}}}
EOF
python3 - "${troot}" <<'PYEOF' && ok "read_skill args mine into named loads" || no "read_skill args mine into named loads"
import json, subprocess, sys
troot = sys.argv[1]
out = subprocess.run([sys.executable, "scripts/lib/skills-insights-miners.py",
                      "--root", troot + "/muse3"],
                     capture_output=True, text=True)
assert out.returncode == 0, out.stderr
d = json.loads(out.stdout)
assert len(d["sessions"]) == 1, d
rs = d["sessions"][0]
assert rs["id"] == "rs-1", rs
assert rs["skill_loads"] == ["eshu-code-review", "issue-driver", "publish"], rs
PYEOF
# 16. Unloaded work: progress with no skill loaded, hook and mined sides.
cat >"${work}/fix4.jsonl" <<'EOF'
{"harness":"muse","session":"loaded1","ts":"2026-11-20T10:00:00+00:00","type":"skill-load","detail":{"skill":"publish"}}
{"harness":"muse","session":"loaded1","ts":"2026-11-20T10:01:00+00:00","type":"goal-continued","detail":{"progress":1,"remaining":1,"turn":"t1"}}
{"harness":"muse","session":"bare1","ts":"2026-11-20T10:00:00+00:00","type":"goal-continued","detail":{"progress":2,"remaining":0,"turn":"t1"}}
EOF
mkdir -p "${troot}/muse4/plain-sess"
cat >"${troot}/muse4/plain-sess/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"runtime.session.metadata","recorded_at":1795000030000000,"stream":{"id":"plain-1","kind":"x"},"payload":{"record":{"workspace_root":"/repo/delta"}}}
{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795000031000000,"stream":{"id":"plain-1","kind":"x"},"payload":{}}
EOF
bash "${REPORT}" --log "${work}/fix4.jsonl" --transcript-root "${troot}/muse4" --format json >"${work}/fix4.json" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/fix4.json" <<'PYEOF' && ok "unloaded work has a denominator" || no "unloaded work has a denominator"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["unloaded"]["sessions"] == ["bare1"], d["unloaded"]
assert d["unloaded"]["mined_sessions"] == 1, d["unloaded"]
assert d["unloaded"]["mined_prompts"] == 1, d["unloaded"]
PYEOF
rg -q "unloaded work" <<<"$(bash "${REPORT}" --log "${work}/fix4.jsonl" --transcript-root "${troot}/muse4")" &&
	ok "text names unloaded work" || no "text names unloaded work"
bash "${REPORT}" --log "${fix}" --transcript-root "${troot}/claude" \
	--transcript-root "${troot}/muse" --format json >"${work}/proj.json" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/proj.json" <<'PYEOF' && ok "report scopes and breaks down by project" || no "report scopes and breaks down by project"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mined"]["projects"] == {"claude": 1, "/repo/alpha": 1, "/repo/beta": 1}, d["mined"]
assert not [n for n in d["notes"] if n.startswith("--project scopes")], d["notes"]
PYEOF
bash "${REPORT}" --log "${fix}" --transcript-root "${troot}/claude" \
	--transcript-root "${troot}/muse" --project alpha --format json >"${work}/proj1.json" &&
	python3 -c 'import json,sys; d = json.load(open(sys.argv[1])); assert d["mined"]["sessions"] == 1, d["mined"]; assert d["meta"]["project"] == "alpha", d["meta"]; assert d["notes"][-1].startswith("--project scopes transcript mining only"), d["notes"]' "${work}/proj1.json" &&
	ok "report --project filters to one repo" || no "report --project filters to one repo"
rg -q "transcript scope: alpha" <<<"$(bash "${REPORT}" --log "${fix}" --transcript-root "${troot}/muse" --project alpha)" &&
	ok "text names the transcript scope" || no "text names the transcript scope"
txt="$(bash "${REPORT}" --log "${fix}" --transcript-root "${troot}/claude" --transcript-root "${troot}/muse")"
rg -q "top tools: Bash 2" <<<"${txt}" &&
	rg -q "tool errors: Bash 2" <<<"${txt}" &&
	rg -q "projects: .*claude 1" <<<"${txt}" &&
	rg -q "projects: .*/repo/alpha 1" <<<"${txt}" &&
	rg -q "subagents spawned: 2" <<<"${txt}" &&
	ok "split renderer keeps mined text sections" || no "split renderer keeps mined text sections"
capdir="${troot}/cap"
mkdir -p "${capdir}"
printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"old"}]},"timestamp":"2026-11-20T10:00:00.000Z","sessionId":"old-sess"}\n' >"${capdir}/old.jsonl"
printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"new"}]},"timestamp":"2026-11-20T10:00:00.000Z","sessionId":"new-sess"}\n' >"${capdir}/new.jsonl"
touch -d "2020-01-01 00:00" "${capdir}/old.jsonl"
touch -d "2026-11-20 10:00" "${capdir}/new.jsonl"
capped="$(python3 scripts/lib/skills-insights-miners.py --root "${capdir}" --cap-bytes 250)"
capped_ids="$(printf '%s' "${capped}" | python3 -c 'import json,sys; print(" ".join(s["id"] for s in json.load(sys.stdin)["sessions"]))')"
[ "${capped_ids}" = "new" ] &&
	ok "byte cap keeps newest sessions first" || no "byte cap keeps newest sessions first (got: ${capped_ids})"

# 14. Git history counts merges and reverts; unknown paths stay green.
grepo="${work}/grepo"
(
	cd "${work}" >/dev/null 2>&1 || exit 1
	git init -qb main grepo >/dev/null 2>&1 || exit 1
	cd grepo >/dev/null 2>&1 || exit 1
	export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
	export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
	echo a >f.txt && git add f.txt && git commit -qm "one" || exit 1
	echo b >>f.txt && git commit -qam "two" || exit 1
	git revert --no-edit HEAD >/dev/null 2>&1 || exit 1
	git checkout -qb feat >/dev/null 2>&1 || exit 1
	echo c >>f.txt && git commit -qam "feat" || exit 1
	git checkout -q main >/dev/null 2>&1 || exit 1
	git merge -q --no-ff feat -m "Merge feat" >/dev/null 2>&1 || exit 1
) || no "git fixture setup failed"
bash "${REPORT}" --log "${fix}" --repo "${grepo}" --repo "${work}/not-a-repo" --format json >"${work}/grepo.json" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/grepo.json" "${grepo}" <<'PYEOF' && ok "git history counts merges and reverts" || no "git history counts merges and reverts"
import json, sys
d = json.load(open(sys.argv[1]))
repos = {r["path"]: r for r in d["meta"]["repos"]}
mine = repos[sys.argv[2]]
assert mine["merges"] == 1 and mine["reverts"] == 1, mine
assert mine["commits"] == 5, mine
bad = [r for r in d["meta"]["repos"] if r.get("unreadable")]
assert len(bad) == 1, d["meta"]["repos"]
PYEOF

# 15. Test-fixture sessions never pollute the aggregate.
cat >"${work}/fix3.jsonl" <<'EOF'
{"harness":"claude","session":"abcdefghijkl","ts":"2026-11-20T10:00:00+00:00","type":"nudge-block","detail":{"skills":["golang-engineering"]}}
{"harness":"claude","session":"ses9","ts":"2026-11-20T10:00:00+00:00","type":"model-failure","detail":{"category":"UnknownError"}}
{"harness":"claude","session":"ses9","ts":"2026-11-20T10:01:00+00:00","type":"model-failure","detail":{"category":429}}
{"harness":"muse","session":"realsess","ts":"2026-11-20T10:00:00+00:00","type":"skill-load","detail":{"skill":"publish"}}
EOF
bash "${REPORT}" --log "${work}/fix3.jsonl" --no-mine --format json >"${work}/fix3.json" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/fix3.json" <<'PYEOF' && ok "fixture sessions excluded from aggregate" || no "fixture sessions excluded from aggregate"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["meta"]["events"] == 1, d["meta"]
assert d["meta"]["sessions"] == 1, d["meta"]
assert [s["session"] for s in d["sessions"]] == ["realsess"], d["sessions"]
assert d["friction"]["nudge_blocked"] == {}, d["friction"]
assert d["friction"]["model_failures"] == {}, d["friction"]
assert d["friction"]["repeat_blocked_sessions"] == [], d["friction"]
assert any("fixture" in n for n in d["notes"]), d["notes"]
PYEOF

printf '\nskills-insights: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

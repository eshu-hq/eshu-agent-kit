#!/usr/bin/env bash
# Behavioral suite for hook telemetry (skills-insights-events.sh) and the
# Debrief v2 multi-harness pipeline (scripts/debrief.sh).
# All state stays under a private XDG_DATA_HOME/HOME/TMPDIR.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="${KIT_DIR}/hooks"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

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
loglines() { [ -f "${LOG}" ] && wc -l <"${LOG}" | tr -d ' ' || echo 0; }

SID="debrieftest1"

# --- Part A: Hook telemetry emission (skills-insights-events.sh) ---

# 1. Skill load writes marker + event; plugin prefix strips; KIT_HARNESS works.
out="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s-extra","tool_input":{"skill":"code-review"}}' "${SID}" |
	bash "${HOOKS}/skill-loaded.sh" 2>/dev/null)"
[ -z "${out}" ] && [ -f "/tmp/claude-skill-loaded-${SID}-code-review" ] &&
	rg -q '"type": "skill-load"' "${LOG}" && rg -q '"skill": "code-review"' "${LOG}" &&
	rg -q "\"session\": \"${SID}\"" "${LOG}" && rg -q '"harness": "claude"' "${LOG}" &&
	ok "skill-loaded logs claude event and writes marker" ||
	no "skill-loaded logs claude event and writes marker"
rm -f "/tmp/claude-skill-loaded-${SID}-code-review"

printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"eshu-agent-kit:issue-driver"}}' "${SID}" |
	KIT_HARNESS=muse bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
rg -q '"skill": "issue-driver"' "${LOG}" && rg -q '"harness": "muse"' "${LOG}" &&
	ok "plugin prefix stripped and KIT_HARNESS=muse recorded" ||
	no "plugin prefix stripped and KIT_HARNESS=muse recorded"
rm -f "/tmp/claude-skill-loaded-${SID}-issue-driver"

# 2. Opt-out suppresses telemetry but keeps marker; garbage fails open.
before="$(loglines)"
printf 'garbage' | bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"publish"}}' "${SID}" |
	ESHU_SKILLS_TELEMETRY_OFF=1 bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
[ "$(loglines)" = "${before}" ] && [ -f "/tmp/claude-skill-loaded-${SID}-publish" ] &&
	ok "opt-out suppresses event while keeping marker" ||
	no "opt-out suppresses event while keeping marker"
rm -f "/tmp/claude-skill-loaded-${SID}-publish"

# 3. Nudge block logs demanded skill; canonical marker satisfies eshu-* arm.
repo="${work}/repo"
mkdir -p "${repo}"
touch "${repo}/.agent-kit-version"
if printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/x.go"},"session_id":"%s"}' "${repo}" "${SID}" |
	bash "${HOOKS}/skill-nudge.sh" >/dev/null 2>&1; then
	no "nudge block exits nonzero and logs demanded skill"
else
	[ "$?" -eq 2 ] && rg -q '"type": "nudge-block"' "${LOG}" &&
		rg -q '"skills": \["golang-engineering"\]' "${LOG}" &&
		ok "nudge block exits nonzero and logs demanded skill" ||
		no "nudge block exits nonzero and logs demanded skill"
fi
touch "/tmp/claude-skill-loaded-${SID}-postgres-rigor"
if printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/storage/postgres/q.sql"},"session_id":"%s"}' "${repo}" "${SID}" |
	bash "${HOOKS}/skill-nudge.sh" >/dev/null 2>&1; then
	ok "canonical marker satisfies eshu-* nudge arm"
else
	no "canonical marker satisfies eshu-* nudge arm"
fi
rm -f "/tmp/claude-skill-loaded-${SID}-postgres-rigor"

# 4. Sanitization, rotation at 5 MiB, goal-continue outcomes, and stop-failure.
bash -c 'source "'"${HOOKS}"'/lib/skills-insights-events.sh"; si_event "skill-load" "a/b\"c
d" "{\"skill\":\"x\"}"' >/dev/null 2>&1
rg -q '"session": "a-b-c-d"' "${LOG}" &&
	ok "si_event sanitizes hostile session ids" || no "si_event sanitizes hostile session ids"

dd if=/dev/zero bs=1048576 count=6 2>/dev/null | tr '\0' 'x' >"${LOG}"
printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"release"}}' "${SID}" |
	bash "${HOOKS}/skill-loaded.sh" >/dev/null 2>&1
[ -f "${LOG}.1" ] && [ "$(loglines)" -eq 1 ] &&
	ok "hook telemetry rotates at 5 MiB keeping one spare" ||
	no "hook telemetry rotates at 5 MiB keeping one spare"
rm -f "/tmp/claude-skill-loaded-${SID}-release"

goal="${work}/goal.md"
printf 'DONE\nFinished.\n' >"${goal}"
printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"g1","cwd":"%s"}' "${SID}" "${work}" |
	CLAUDE_GOAL_FILE="${goal}" bash "${HOOKS}/goal-continue.sh" >/dev/null 2>&1
printf '{"hook_event_name":"StopFailure","session_id":"dead01","cwd":"%s","failure_category":"server_error","failure_details":"secret-body"}' "${work}" |
	bash "${HOOKS}/stop-failure.sh" >/dev/null 2>&1
rg -q '"type": "goal-done"' "${LOG}" && rg -q '"type": "model-failure"' "${LOG}" &&
	! rg -q "secret-body" "${LOG}" &&
	ok "goal-done and stop-failure log category without details" ||
	no "goal-done and stop-failure log category without details"

# --- Part B: Multi-harness Stage 1 extraction, subagent rollup, prepare, cache-write ---

troot="${work}/transcripts"
cache="${work}/cache"
batches="${work}/batches"
cfacets="${work}/claude-facets"
mkdir -p "${troot}/muse/parent-m" "${troot}/muse/parent-m/subagent/child-m" \
	"${troot}/muse/trivial-m" \
	"${troot}/agy-cli/brain/conv-agy-1/.system_generated/logs" \
	"${troot}/agy-app/brain/conv-agy-1/.system_generated/logs" \
	"${troot}/claude/proj-alpha/cl-parent/subagents" \
	"${cfacets}"

# Muse parent + child + trivial session (epoch 1795168800 = 2026-11-20T10:00:00Z)
cat >"${troot}/muse/parent-m/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"session.workspace_branch.observed","recorded_at":1795168800000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"workspace_root":"/repo/alpha"}}}
{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795168805000000,"stream":{"id":"parent-m","kind":"x"},"payload":{}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795168805000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"event":{"kind":"model_user_messages","messages":["Fix CI flakes in go/pkg/foo.go"]}}}
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795168806000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"kind":"started","call_id":"c1","tool_name":"bash"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795168807000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"c1","outcome":{"kind":"failed","error":"exit status 1: permission denied"}}}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795168808000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"event":{"kind":"assistant_tool_calls_committed","tool_calls":[{"call_id":"c2","name":"read_skill","args":"{\"name\":\"eshu-code-review\"}"},{"call_id":"c3","name":"edit_file","args":"{\"path\":\"go/pkg/foo.go\"}"},{"call_id":"c4","name":"bash","args":"{\"command\":\"git commit -m fix && git push\"}"}]}}}
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795168808000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"kind":"started","call_id":"c2","tool_name":"read_skill"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795168809000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"c2","outcome":{"kind":"completed"}}}}
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795168809000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"kind":"started","call_id":"c3","tool_name":"edit_file"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795168810000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"c3","outcome":{"kind":"completed"}}}}
{"record_type":"event","payload_type":"subagent.control.spawn_accepted","recorded_at":1795168810000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"subagent_id":"sub1","role":"develop-eshu","depth":1}}}
{"record_type":"event","payload_type":"subagent.control.child_session_bound","recorded_at":1795168811000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"record":{"child_session_id":"child-m"}}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795168830000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"event":{"kind":"assistant_message_committed","text":"Fixed foo.go and pushed."}}}
{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795168865000000,"stream":{"id":"parent-m","kind":"x"},"payload":{}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795168865000000,"stream":{"id":"parent-m","kind":"x"},"payload":{"event":{"kind":"model_user_messages","messages":["Looks great, merge it"]}}}
EOF

cat >"${troot}/muse/parent-m/subagent/child-m/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"tool_batch.effect.started","recorded_at":1795168812000000,"stream":{"id":"child-m","kind":"x"},"payload":{"record":{"kind":"started","call_id":"sc1","tool_name":"bash"}}}
{"record_type":"event","payload_type":"tool_batch.effect.terminal","recorded_at":1795168814000000,"stream":{"id":"child-m","kind":"x"},"payload":{"record":{"kind":"terminal","call_id":"sc1","outcome":{"kind":"completed"}}}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795168815000000,"stream":{"id":"child-m","kind":"x"},"payload":{"event":{"kind":"assistant_message_committed","text":"Subagent finished tests."}}}
EOF

cat >"${troot}/muse/trivial-m/session.jsonl" <<'EOF'
{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795168900000000,"stream":{"id":"trivial-m","kind":"x"},"payload":{}}
{"record_type":"event","payload_type":"runtime.session","recorded_at":1795168900000000,"stream":{"id":"trivial-m","kind":"x"},"payload":{"event":{"kind":"model_user_messages","messages":["hi"]}}}
EOF

# Agy transcript (older in agy-app, newer in agy-cli with real conversation_summaries.db schema)
cat >"${troot}/agy-app/brain/conv-agy-1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"created_at":"2026-11-20T10:00:00Z","type":"USER_INPUT","content":"old duplicate"}
EOF
cat >"${troot}/agy-cli/brain/conv-agy-1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"created_at":"2026-11-20T10:00:10Z","type":"USER_INPUT","content":"Check python pipeline in scripts/app.py"}
{"created_at":"2026-11-20T10:00:15Z","type":"PLANNER_RESPONSE","model":"gemini-flash","tool_calls":[{"name":"read_file","args":{"Path":"/repo/skills/eshu/publish/SKILL.md"}},{"name":"edit_file","args":{"Path":"/repo/alpha/scripts/app.py"}},{"name":"run_command","args":{"CommandLine":"pytest"}}],"response":"Checking app.py."}
{"created_at":"2026-11-20T10:00:16Z","type":"GENERIC","text":"ok"}
{"created_at":"2026-11-20T10:00:17Z","type":"GENERIC","text":"ok"}
{"created_at":"2026-11-20T10:00:25Z","type":"GENERIC","error":"Command exited with code 1"}
{"created_at":"2026-11-20T10:00:50Z","type":"USER_INPUT","content":"Fix the assertion and re-run"}
{"created_at":"2026-11-20T10:01:05Z","type":"PLANNER_RESPONSE","model":"gemini-flash","response":"All tests green now."}
EOF
python3 - "${troot}/agy-cli/conversation_summaries.db" "${troot}/agy-app/brain/conv-agy-1/.system_generated/logs/transcript.jsonl" "${troot}/agy-cli/brain/conv-agy-1/.system_generated/logs/transcript.jsonl" <<'PYEOF'
import os, sqlite3, sys
db, old_p, new_p = sys.argv[1], sys.argv[2], sys.argv[3]
con = sqlite3.connect(db)
con.execute("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, workspace_uris TEXT, parent_conversation_id TEXT, nesting_depth INTEGER, agent_name TEXT)")
con.execute("INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?)", ("conv-agy-1", '["file:///repo/alpha"]', None, 0, "coordinator"))
con.commit()
con.close()
os.utime(old_p, (1795168800, 1795168800))
os.utime(new_p, (1795168900, 1795168900))
PYEOF

# Claude parent (already has native facet) + child subagent under <parent>/subagents/
cat >"${troot}/claude/proj-alpha/cl-parent.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Audit SQL query in query.sql"}]},"timestamp":"2026-11-20T10:00:20.000Z","sessionId":"cl-parent"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"cu1","name":"Read","input":{"file_path":"query.sql"}},{"type":"tool_use","id":"cu2","name":"Bash","input":{"command":"git commit -m sql"}},{"type":"tool_use","id":"cu3","name":"Skill","input":{"skill":"eshu-agent-kit:postgres-rigor"}}]},"timestamp":"2026-11-20T10:00:30.000Z","sessionId":"cl-parent"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Ship it"}]},"timestamp":"2026-11-20T10:00:55.000Z","sessionId":"cl-parent"}
EOF
cat >"${troot}/claude/proj-alpha/cl-parent/subagents/agent-child1.jsonl" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"scu1","name":"Bash","input":{"command":"true"}}]},"timestamp":"2026-11-20T10:00:35.000Z","sessionId":"cl-parent"}
EOF
cat >"${cfacets}/cl-parent.json" <<'EOF'
{"session_id":"cl-parent","underlying_goal":"Audit SQL query","goal_categories":{"sql_optimization":1},"outcome":"fully_achieved","user_satisfaction_counts":{"satisfied":2},"friction_counts":{},"primary_success":"good_debugging","session_type":"single_task","brief_summary":"Audited and committed SQL fix."}
EOF

prep_out="$(bash "${DEBRIEF}" prepare --since 2026-11-01 --max-new 10 --batch-size 1 \
	--cache-dir "${cache}" --out-dir "${batches}" \
	--claude-facets-dir "${cfacets}" \
	--transcript-root "${troot}/muse" \
	--transcript-root "${troot}/agy-app/brain" \
	--transcript-root "${troot}/agy-cli/brain" \
	--transcript-root "${troot}/claude")" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${prep_out}" <<'PYEOF' && ok "prepare extracts all 3 harnesses, rolls children, skips trivial, imports Claude facets" || no "prepare extracts all 3 harnesses, rolls children, skips trivial, imports Claude facets"
import json, sys
m = json.loads(sys.argv[1])
assert m["claude_native_imported"] == 1, m
assert m["rolled_up_children"] == 2, m
assert m["skipped_trivial"] == 1, m
assert m["facets_already_cached"] == 1, m
assert m["facets_queued"] == 2, m
assert len(m["batch_files"]) == 2, m
digs = []
for bf in m["batch_files"]:
    digs.extend(json.load(open(bf))["digests"])
by_h = {d["harness"]: d for d in digs}
assert set(by_h) == {"muse", "agy"}, by_h
assert by_h["muse"]["rolled_up_children"] == 1, by_h["muse"]
assert by_h["agy"]["project"] == "/repo/alpha", by_h["agy"]
PYEOF

# Test cache-write: valid facets + invalid facet rejection
cat >"${work}/facets-valid.json" <<'EOF'
{"facets":[
  {"session_id":"parent-m","harness":"muse","underlying_goal":"Fix CI flake in foo.go","goal_categories":{"bug_fix":1},"outcome":"fully_achieved","satisfaction":"satisfied","friction_counts":{"tool_or_env_error":1},"friction_detail":"Hit permission denied once.","primary_success":"good_debugging","session_type":"single_task","brief_summary":"Fixed foo.go and pushed."},
  {"session_id":"conv-agy-1","harness":"agy","underlying_goal":"Fix Python test in app.py","goal_categories":{"testing_and_verification":1},"outcome":"mostly_achieved","satisfaction":"likely_satisfied","friction_counts":{"buggy_code":1},"friction_detail":"First pytest run failed.","primary_success":"correct_code_edits","session_type":"iterative_refinement","brief_summary":"Updated app.py until pytest passed."}
]}
EOF
cw_ok="$(bash "${DEBRIEF}" cache-write --cache-dir "${cache}" "${work}/facets-valid.json")" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && rg -q '"written": 2' <<<"${cw_ok}" &&
	ok "cache-write validates and stores facets atomically" ||
	no "cache-write validates and stores facets atomically"

if printf '{"session_id":"","harness":"invalid"}' | bash "${DEBRIEF}" cache-write --cache-dir "${cache}" - >/dev/null 2>&1; then
	no "cache-write rejects invalid facet schema"
else
	ok "cache-write rejects invalid facet schema"
fi

# Second prepare sees 0 queued because facets are now mtime-cached
prep2="$(bash "${DEBRIEF}" prepare --since 2026-11-01 --cache-dir "${cache}" --out-dir "${batches}" \
	--claude-facets-dir "${cfacets}" \
	--transcript-root "${troot}/muse" --transcript-root "${troot}/agy-cli/brain" --transcript-root "${troot}/claude")"
python3 -c 'import json,sys; m=json.loads(sys.argv[1]); assert m["facets_queued"]==0 and m["facets_already_cached"]==3, m' "${prep2}" &&
	ok "second prepare hits mtime cache with zero re-queued facets" ||
	no "second prepare hits mtime cache with zero re-queued facets"

# --- Part C: Aggregate (hooks, fixture exclusion, alias folding, overlap, git UTC --since) ---

grepo="${work}/grepo"
since_day="2026-11-20"
(
	cd "${work}" || exit 1
	git init -qb main grepo || exit 1
	cd grepo || exit 1
	export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
	echo pre >pre.txt && git add pre.txt && GIT_COMMITTER_DATE="2026-11-19T23:59:59Z" GIT_AUTHOR_DATE="2026-11-19T23:59:59Z" git commit -qm "pre" || exit 1
	export GIT_COMMITTER_DATE="${since_day}T00:05:00Z" GIT_AUTHOR_DATE="${since_day}T00:05:00Z"
	echo a >f.txt && git add f.txt && git commit -qm "one" || exit 1
	echo b >>f.txt && git commit -qam "two" || exit 1
	git revert --no-edit HEAD >/dev/null 2>&1 || exit 1
	git checkout -qb feat && echo c >>f.txt && git commit -qam "feat" || exit 1
	git checkout -q main && git merge -q --no-ff feat -m "Merge feat" || exit 1
) || no "git fixture setup failed"

cat >"${work}/hooks.jsonl" <<'EOF'
{"harness":"claude","session":"abcdefghijkl","ts":"2026-11-20T10:00:00+00:00","type":"nudge-block","detail":{"skills":["golang-engineering"]}}
{"harness":"claude","session":"t2821813","ts":"2026-11-20T10:01:00+00:00","type":"skill-load","detail":{"skill":"brainstorming"}}
{"harness":"claude","session":"ses9","ts":"2026-11-20T10:01:00+00:00","type":"model-failure","detail":{"category":"429"}}
{"harness":"muse","session":"worker1","ts":"2026-11-20T10:00:00+00:00","type":"nudge-block","detail":{"skills":["eshu-postgres-rigor"]}}
{"harness":"muse","session":"worker1","ts":"2026-11-20T10:01:00+00:00","type":"skill-load","detail":{"skill":"eshu-postgres-rigor"}}
{"harness":"muse","session":"goal1","ts":"2026-11-20T11:00:00+00:00","type":"skill-load","detail":{"skill":"eshu-performance-rigor"}}
{"harness":"muse","session":"goal1","ts":"2026-11-20T11:01:00+00:00","type":"goal-continued","detail":{"progress":0,"remaining":2,"turn":"t1"}}
{"harness":"muse","session":"goal2","ts":"2026-11-20T12:00:00+00:00","type":"goal-done","detail":{}}
EOF

TZ=UTC+5 bash "${DEBRIEF}" aggregate --since "${since_day}" --cache-dir "${cache}" \
	--log "${work}/hooks.jsonl" --repo "${grepo}" --repo "${work}/missing-repo" \
	--out "${work}/agg.json" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/agg.json" "${grepo}" <<'PYEOF' && ok "aggregate merges facets, hooks, fixture exclusion, overlap, and UTC git --since" || no "aggregate merges facets, hooks, fixture exclusion, overlap, and UTC git --since"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["meta"]["facets_analyzed"] == 3, d["meta"]
assert d["meta"]["fixtures_excluded"] == 3, d["meta"]
assert set(d["by_harness"]) == {"muse", "agy", "claude"}, d["by_harness"]
assert d["charts"]["multi_agent_overlap"]["overlap_events"] >= 1, d["charts"]["multi_agent_overlap"]
assert d["charts"]["languages"].get("Go", 0) >= 1 and d["charts"]["languages"].get("Python", 0) >= 1, d["charts"]["languages"]
by_sk = {r["skill"]: r for r in d["skill_table"]}
assert "postgres-rigor" in by_sk and by_sk["postgres-rigor"]["forced_pct"] == 100, by_sk
assert by_sk["performance-rigor"]["no_progress_share_pct"] == 100, by_sk
assert d["hooks"]["goal_done"] == 1 and d["hooks"]["model_failures"] == {}, d["hooks"]
repos = {r["path"]: r for r in d["meta"]["repos"]}
g = repos[sys.argv[2]]
assert g["commits"] == 5 and g["merges"] == 1 and g["reverts"] == 1, g
assert any(r.get("unreadable") for r in d["meta"]["repos"]), d["meta"]["repos"]
PYEOF

# --- Part D: Offline HTML renderer + XSS escaping ---

cat >"${work}/syn.json" <<'EOF'
{
  "at_a_glance": {"working": "Parallel work <script>alert(1)</script>", "hindering": "Env errors", "quick_wins": "Add pre-brief", "ambitious": "Auto triage"},
  "project_areas": [{"name": "Core Platform", "sessions_label": "~3 sessions", "description": "Go, Python, and SQL fixes."}],
  "narrative_paragraphs": ["You ran parallel sessions across Muse, agy, and Claude."],
  "key_insight": "Pre-loading skills eliminates nudge blocks.",
  "wins_intro": "Clean multi-harness delivery.",
  "big_wins": [{"title": "Cross-Harness Debugging", "description": "Fixed foo.go (parent-m) and app.py (conv-agy-1)."}],
  "friction_intro": "Two small friction hits.",
  "friction_categories": [{"title": "Tool Errors", "description": "Permission and test errors.", "examples": ["parent-m hit permission denied."]}],
  "agents_md_additions": [{"target": "AGENTS.md", "snippet": "Run pytest before commit.", "why": "Avoids retry loops."}],
  "features_to_try": [{"title": "Pre-briefs", "oneliner": "Inject skill cues.", "why": "Cuts forced loads.", "example": "agents/roles.json"}],
  "usage_patterns": [{"title": "Batch Verification", "summary": "Verify once.", "detail": "Group test checks.", "prompt": "Run full suite once."}],
  "horizon_intro": "Next-step workflows.",
  "horizon_workflows": [{"title": "Overnight CI Triage", "possible": "Auto-classify flakes.", "tip": "Start with /schedule.", "prompt": "Scan failed workflows."}]
}
EOF

rdir="${work}/reports"
ren_out="$(bash "${DEBRIEF}" render --aggregate "${work}/agg.json" --synthesis "${work}/syn.json" --reports-dir "${rdir}")" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${ren_out}" "${rdir}" <<'PYEOF' && ok "render writes offline escaped HTML + report-latest.html" || no "render writes offline escaped HTML + report-latest.html"
import json, os, re, sys
info = json.loads(sys.argv[1])
assert os.path.isfile(info["report"]) and os.path.isfile(info["latest"]), info
html = open(info["report"], encoding="utf-8").read()
assert "<script>alert(1)</script>" not in html, "unescaped script tag!"
assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html, "escaped text missing"
assert not re.search(r'https?://', html), "external URL found in offline HTML!"
assert "copyAllCheckedRules" in html and "timezone-select" in html and "rawUtcHours" in html
assert "&amp;middot;" not in html, "double-escaped middot!"
PYEOF

printf '\ndebrief: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

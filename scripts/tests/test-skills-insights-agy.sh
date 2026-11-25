#!/usr/bin/env bash
# Behavioural suite for Antigravity (agy) transcript mining and debrief
# aggregation in scripts/skills-insights.sh.
#
# All state stays under a private XDG_DATA_HOME/HOME/TMPDIR so a run never
# touches the real telemetry log or ~/.gemini directories.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT="${KIT_DIR}/scripts/skills-insights.sh"
MINERS="${KIT_DIR}/scripts/lib/skills-insights-miners.py"

work="$(mktemp -d)"
trap '[ -f "${work}/agy-away.py" ] && mv "${work}/agy-away.py" "${KIT_DIR}/scripts/lib/skills-insights-miners-agy.py"; rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg"
export HOME="${work}/home"
export TMPDIR="${work}/tmp"
mkdir -p "${XDG_DATA_HOME}" "${HOME}" "${TMPDIR}"

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

# Build a realistic Antigravity appDataDir with two conversations (parent +
# child subagent), duplicate transcript_full/chunk files that must be skipped,
# and a conversation_summaries.db with structural columns plus decoy text
# columns (title/preview) that must never leak.
cli_dir="${HOME}/.gemini/antigravity-cli"
parent_logs="${cli_dir}/brain/agy-parent-1/.system_generated/logs"
child_logs="${cli_dir}/brain/agy-child-1/.system_generated/logs"
unloaded_logs="${cli_dir}/brain/agy-bare-1/.system_generated/logs"
mkdir -p "${parent_logs}/chunks/transcript" "${parent_logs}/chunks/transcript_full" \
	"${child_logs}" "${unloaded_logs}"

cat >"${parent_logs}/transcript.jsonl" <<'EOF'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-24T10:00:00Z","content":"SECRET-PROMPT-TEXT"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T10:00:05Z","model":"gemini-4-neon-high","tool_calls":[{"name":"read_file","args":{"Path":"\"/Users/u/.gemini/config/skills/code-review/SKILL.md\""}},{"name":"read_file","args":{"Path":"\"/repo/alpha/README.md\""}},{"name":"run_command","args":{"CommandLine":"\"false\""}}]}
{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-24T10:00:06Z","content":"ok"}
{"step_index":3,"source":"MODEL","type":"GENERIC","status":"ERROR","created_at":"2026-11-24T10:00:07Z","error":"SECRET-ERROR-BODY"}
{"step_index":4,"source":"MODEL","type":"GENERIC","status":"INVALID","created_at":"2026-11-24T10:00:08Z","error":"bad command"}
{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T10:00:10Z","model":"gemini-4-neon-high","tool_calls":[{"name":"invoke_subagent","args":{"TypeName":"\"debug-eshu\"","Role":"\"Debugger\"","Model":"\"flash\"","Prompt":"\"SECRET-SUBAGENT-PROMPT\""}},{"name":"swarm","args":{"action":"\"add\"","name":"\"worker\"","model":"\"pro\"","tasks":["a","b"]}}]}
{"step_index":6,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-24T10:00:11Z"}
{"step_index":7,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-24T10:00:12Z"}
{"step_index":8,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-24T10:00:40Z","content":"second turn"}
{"step_index":9,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T10:00:45Z","model":"gemini-4-hydrogen-tiered-xhigh","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"\"/repo/alpha/.agents/skills/eshu-agent-kit:publish/SKILL.md\""}}]}
{"step_index":10,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-24T10:00:46Z"}
EOF

# Duplicates, chunks, and scratch/*.jsonl must never be mined or misclassified.
cp "${parent_logs}/transcript.jsonl" "${parent_logs}/transcript_full.jsonl"
cp "${parent_logs}/transcript.jsonl" "${parent_logs}/chunks/transcript/00000000.jsonl"
cp "${parent_logs}/transcript.jsonl" "${parent_logs}/chunks/transcript_full/00000000.jsonl"
mkdir -p "${cli_dir}/brain/agy-parent-1/scratch/debug-run"
printf '{"kind":"scratch","event":"not-a-transcript"}\n' \
	>"${cli_dir}/brain/agy-parent-1/scratch/debug-run/events.jsonl"

cat >"${child_logs}/transcript.jsonl" <<'EOF'
{"step_index":0,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-24T10:00:12Z","content":"subagent task"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T10:00:15Z","model":"gemini-3.8-flash-high","tool_calls":[{"name":"read_file","args":{"Path":"/Users/u/.gemini/config/skills/diagnostic-rigor/SKILL.md"}}]}
{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-24T10:00:16Z"}
EOF

cat >"${unloaded_logs}/transcript.jsonl" <<'EOF'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-25T09:00:00Z","content":"quick question"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T09:00:04Z","model":"gemini-4-neon-high","tool_calls":[{"name":"edit_file","args":{"Path":"\"/repo/beta/main.go\""}}]}
{"step_index":2,"source":"MODEL","type":"GENERIC","status":"ERROR","created_at":"2026-11-25T09:00:05Z","error":"target not found"}
EOF

python3 - "${cli_dir}/conversation_summaries.db" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("""
CREATE TABLE conversation_summaries (
    conversation_id text PRIMARY KEY,
    title text NOT NULL DEFAULT "",
    preview text NOT NULL DEFAULT "",
    workspace_uris text NOT NULL DEFAULT "",
    parent_conversation_id text NOT NULL DEFAULT "",
    nesting_depth integer NOT NULL DEFAULT 0,
    agent_name text NOT NULL DEFAULT ""
)
""")
rows = [
    ("agy-parent-1", "SECRET-TITLE-ALPHA", "SECRET-PREVIEW-ALPHA",
     '["file:///repo/alpha%20one"]', "", 0, ""),
    ("agy-child-1", "SECRET-TITLE-CHILD", "SECRET-PREVIEW-CHILD",
     '["file:///repo/alpha%20one"]', "agy-parent-1", 1, "debug-eshu"),
    ("agy-bare-1", "SECRET-TITLE-BETA", "SECRET-PREVIEW-BETA",
     '["file:///repo/beta"]', "", 0, ""),
]
con.executemany("INSERT INTO conversation_summaries VALUES (?,?,?,?,?,?,?)", rows)
con.commit()
con.close()
PYEOF

# 1. Default discovery mines agy sessions, skips transcript_full and chunks,
#    attributes tools/errors/skills/subagents/models/gaps/metadata, and leaks
#    zero content or DB title/preview strings.
mined_json="${work}/mined.json"
python3 "${MINERS}" >"${mined_json}" && rc=0 || rc=1
if [ "${rc}" -eq 0 ] && python3 - "${mined_json}" <<'PYEOF'; then
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
for secret in ("SECRET-PROMPT-TEXT", "SECRET-ERROR-BODY",
               "SECRET-SUBAGENT-PROMPT", "SECRET-TITLE-ALPHA",
               "SECRET-PREVIEW-ALPHA"):
    assert secret not in raw, f"leaked {secret}"
d = json.loads(raw)
assert len(d["sessions"]) == 3, [s["id"] for s in d["sessions"]]
by_id = {s["id"]: s for s in d["sessions"]}
p = by_id["agy-parent-1"]
assert p["harness"] == "agy", p
assert p["prompts"] == 2 and p["assistant_messages"] == 3, p
assert p["tools"] == {"read_file": 2, "run_command": 1, "invoke_subagent": 1, "swarm": 1, "view_file": 1}, p
assert p["errors"] == {"read_file": 1, "run_command": 1}, p
assert p["skill_loads"] == ["code-review", "publish"], p
assert p["subagents"] == 3, p
assert p["subagent_roles"] == {"debug-eshu": 1, "worker": 2}, p
assert p["subagent_models"] == {"flash": 1, "pro": 2}, p
# Transitions only: gemini-4-neon-high stayed active for 2 steps -> count 1, then switched -> count 1.
assert p["session_models"] == {"gemini-4-neon-high": 1, "gemini-4-hydrogen-tiered-xhigh": 1}, p
assert len(p["response_gaps"]) == 1, p
assert p["project"] == "/repo/alpha one", p
assert p["parent_session"] is None and p["max_depth"] == 1, p

c = by_id["agy-child-1"]
assert c["prompts"] == 0 and c["parent_session"] == "agy-parent-1", c
assert c["max_depth"] == 1 and c["skill_loads"] == ["diagnostic-rigor"], c
assert c["session_models"] == {"gemini-3.8-flash-high": 1}, c

b = by_id["agy-bare-1"]
assert b["project"] == "/repo/beta" and b["errors"] == {"edit_file": 1}, b
assert b["skill_loads"] == [], b
PYEOF
	ok "agy miner attributes tools, errors, skills, subagents, models, gaps, metadata (content-free)"
else
	no "agy miner attributes tools, errors, skills, subagents, models, gaps, metadata (content-free)"
fi

# 2. Same conversation appearing in both antigravity-cli and antigravity deduplicates
#    to the newest copy.
app_logs="${HOME}/.gemini/antigravity/brain/agy-parent-1/.system_generated/logs"
mkdir -p "${app_logs}"
cp "${parent_logs}/transcript.jsonl" "${app_logs}/transcript.jsonl"
touch -t 202611200000 "${app_logs}/transcript.jsonl"
if python3 "${MINERS}" | python3 -c 'import json,sys; s=json.load(sys.stdin)["sessions"]; ids=[x["id"] for x in s]; assert ids.count("agy-parent-1") == 1, ids'; then
	ok "duplicate agy conversation across cli and app roots deduplicates"
else
	no "duplicate agy conversation across cli and app roots deduplicates"
fi
rm -rf "${HOME}/.gemini/antigravity"

# 3. --project filters agy sessions via conversation_summaries.db and fails open
#    when no DB exists.
if python3 "${MINERS}" --project "alpha one" | python3 -c 'import json,sys; ids=sorted(x["id"] for x in json.load(sys.stdin)["sessions"]); assert ids == ["agy-child-1", "agy-parent-1"], ids'; then
	ok "agy --project filters by workspace_uris from conversation_summaries.db"
else
	no "agy --project filters by workspace_uris from conversation_summaries.db"
fi
nodir="${work}/no-db/brain/agy-nodb/.system_generated/logs"
mkdir -p "${nodir}"
cp "${unloaded_logs}/transcript.jsonl" "${nodir}/transcript.jsonl"
if python3 "${MINERS}" --root "${work}/no-db/brain" --project "anything" | python3 -c 'import json,sys; ids=[x["id"] for x in json.load(sys.stdin)["sessions"]]; assert ids == ["agy-nodb"], ids'; then
	ok "agy --project fails open when conversation_summaries.db is absent"
else
	no "agy --project fails open when conversation_summaries.db is absent"
fi

# 4. End-to-end skills-insights.sh on agy-only data (no hook event log at all):
#    JSON and text both surface agy harness, dates, skills, gaps, subagents, unloaded.
agy_json="${work}/agy-report.json"
bash "${REPORT}" --format json >"${agy_json}" && rc=0 || rc=1
if [ "${rc}" -eq 0 ] && python3 - "${agy_json}" <<'PYEOF'; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["meta"]["harnesses"] == ["agy"], d["meta"]
assert d["meta"]["from"] == "2026-11-24" and d["meta"]["to"] == "2026-11-25", d["meta"]
assert d["mined"]["sessions"] == 3, d["mined"]
assert d["mined"]["harnesses"] == {"agy": 3}, d["mined"]
assert d["mined"]["skill_loads"] == {"code-review": 1, "diagnostic-rigor": 1, "publish": 1}, d["mined"]
assert d["mined"]["subagents"] == 3 and d["mined"]["child_sessions"] == 1, d["mined"]
assert d["mined"]["max_depth"] == 1, d["mined"]
assert d["mined"]["median_response_gap_s"] == 30.0, d["mined"]
assert d["unloaded"]["mined_sessions"] == 1 and d["unloaded"]["mined_prompts"] == 1, d["unloaded"]
by_id = {s["session"]: s for s in d["mined"]["unjoined_sessions"]}
assert by_id["agy-parent-1"]["project"] == "/repo/alpha one", by_id["agy-parent-1"]
assert by_id["agy-parent-1"]["skill_loads"] == ["code-review", "publish"], by_id["agy-parent-1"]
PYEOF
	ok "skills-insights --format json works end-to-end on agy-only sessions"
else
	no "skills-insights --format json works end-to-end on agy-only sessions"
fi

txt="$(bash "${REPORT}")"
if rg -q "harnesses observed: agy" <<<"${txt}" &&
	rg -q "2026-11-24 to 2026-11-25" <<<"${txt}" &&
	rg -q "3 mined sessions [(]agy 3[)] across 3 prompts" <<<"${txt}" &&
	rg -q "median response gap: 30s over 1 gap [(]Claude/agy sessions[)]" <<<"${txt}" &&
	rg -q "code-review: 1 load" <<<"${txt}" &&
	rg -q "subagents spawned: 3" <<<"${txt}"; then
	ok "skills-insights text renders agy sessions, gaps, skills, and subagents"
else
	no "skills-insights text renders agy sessions, gaps, skills, and subagents"
fi

# 5. Mixed Claude + Muse + agy run keeps all three harnesses distinct.
mkdir -p "${HOME}/.claude/projects/demo-proj" "${XDG_DATA_HOME}/muse/sessions/m1"
printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"timestamp":"2026-11-24T12:00:00Z","sessionId":"c1"}\n' \
	>"${HOME}/.claude/projects/demo-proj/c1.jsonl"
printf '{"record_type":"event","payload_type":"runtime.user_intent.accepted","recorded_at":1795000000000000,"stream":{"id":"m1","kind":"x"},"payload":{}}\n' \
	>"${XDG_DATA_HOME}/muse/sessions/m1/session.jsonl"
if bash "${REPORT}" --format json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["harnesses"] == ["agy", "claude", "muse"], d["meta"]; assert d["mined"]["harnesses"] == {"agy": 3, "claude": 1, "muse": 1}, d["mined"]'; then
	ok "mixed claude, muse, and agy sessions aggregate together"
else
	no "mixed claude, muse, and agy sessions aggregate together"
fi

# 6. Missing skills-insights-miners-agy.py degrades cleanly without crashing.
mv "${KIT_DIR}/scripts/lib/skills-insights-miners-agy.py" "${work}/agy-away.py"
out="$(bash "${REPORT}" --format json 2>&1)" && rc=0 || rc=1
mv "${work}/agy-away.py" "${KIT_DIR}/scripts/lib/skills-insights-miners-agy.py"
if [ "${rc}" -eq 0 ] && ! rg -q "Traceback" <<<"${out}" &&
	python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["mined"]["harnesses"] == {"claude": 1, "muse": 1}, d["mined"]' "${out}"; then
	ok "missing agy miner degrades cleanly without crashing"
else
	no "missing agy miner degrades cleanly without crashing"
fi

printf '\nskills-insights-agy: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

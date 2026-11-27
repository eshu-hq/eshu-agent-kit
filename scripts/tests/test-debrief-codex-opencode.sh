#!/usr/bin/env bash
# Hermetic tests for Codex + OpenCode (v1 & v2) debrief extractors and Muse
# subagent.control.runtime_observed post-load fallback attribution (issue #129).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg"
export HOME="${work}/home"
mkdir -p "${XDG_DATA_HOME}" "${HOME}"

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

# --- Fixtures: Codex (.jsonl + optional .jsonl.zst), OpenCode (v2 + v1 SQLite), Muse (fallback) ---
CODEX_DIR="${work}/codex/sessions/2026/11/15"
CODEX_ARCH="${work}/codex/archived_sessions"
OC_DIR="${work}/opencode"
MUSE_DIR="${work}/muse/sessions/muse-fb-1"
mkdir -p "${CODEX_DIR}" "${CODEX_ARCH}" "${OC_DIR}" "${MUSE_DIR}"

cat >"${CODEX_DIR}/rollout-2026-11-15T10-00-00-11111111-2222-3333-4444-555555555555.jsonl" <<'EOF'
{"timestamp":"2026-11-15T10:00:00Z","type":"session_meta","payload":{"id":"11111111-2222-3333-4444-555555555555","cwd":"/tmp/ws/eshu-wt-12","git":{"branch":"feat/x","commit_hash":"abc1234"}}}
{"timestamp":"2026-11-15T10:00:01Z","type":"turn_context","payload":{"cwd":"/tmp/ws/eshu-wt-12","model":"gpt-5.4"}}
{"timestamp":"2026-11-15T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n<INSTRUCTIONS>ignore boilerplate"}]}}
{"timestamp":"2026-11-15T10:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Audit the postgres queue query in go/internal/queue/claim.go"}]}}
{"timestamp":"2026-11-15T10:00:05Z","type":"token_usage_record","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":100}}}
{"timestamp":"2026-11-15T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100}}}}
{"timestamp":"2026-11-15T10:00:07Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"c1","name":"exec","input":"cat /repo/skills/eshu/postgres-rigor/SKILL.md && cat /repo/go/internal/queue/claim.go"}}
{"timestamp":"2026-11-15T10:00:08Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"ok"}}
{"timestamp":"2026-11-15T10:00:10Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Loaded postgres-rigor and inspected claim.go."}]}}
{"timestamp":"2026-11-15T10:00:30Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Stop and don't skip EXPLAIN ANALYZE on claim.go"}]}}
{"timestamp":"2026-11-15T10:00:32Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"c2","name":"exec","input":"psql -c 'EXPLAIN ANALYZE SELECT 1' && git commit -m 'fix'"}}
{"timestamp":"2026-11-15T10:00:34Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"Process exited with code 1: connection refused"}}
{"timestamp":"2026-11-15T10:00:36Z","type":"token_usage_record","payload":{"usage":{"input_tokens":3000,"cached_input_tokens":1800,"cache_write_input_tokens":0,"output_tokens":250}}}
{"timestamp":"2026-11-15T10:00:37Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done checking claim.go."}]}}
EOF

# Optional .jsonl.zst archive fixture when zstd is available
cat >"${work}/arch.jsonl" <<'EOF'
{"timestamp":"2026-11-15T11:00:00Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/ws/eshu-agent-kit"}}
{"timestamp":"2026-11-15T11:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review PR 99"}]}}
{"timestamp":"2026-11-15T11:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"f1","name":"read_skill","arguments":"{\"name\":\"code-review\"}"}}
{"timestamp":"2026-11-15T11:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":500,"output_tokens":150},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":500,"output_tokens":150}}}}
EOF
has_zstd=0
if command -v zstd >/dev/null 2>&1; then
	zstd -q -f "${work}/arch.jsonl" -o "${CODEX_ARCH}/rollout-2026-11-15T11-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl.zst"
	has_zstd=1
fi

# OpenCode SQLite fixture with BOTH v2 (parent + child) and v1-only session
python3 - "${OC_DIR}/opencode.db" <<'PYEOF'
import json, sqlite3, sys

con = sqlite3.connect(sys.argv[1])
con.execute("""CREATE TABLE session_v2 (
    id TEXT, parent_id TEXT, directory TEXT, model TEXT,
    time_created INTEGER, time_updated INTEGER,
    tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER
)""")
con.execute("""CREATE TABLE session_message (
    id TEXT, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT
)""")
con.execute("""CREATE TABLE session (
    id TEXT, parent_id TEXT, directory TEXT, model TEXT,
    time_created INTEGER, time_updated INTEGER,
    tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER
)""")
con.execute("""CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)""")
con.execute("""CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT)""")

t0 = 1794740000000  # 2026-11-15 UTC ms
# V2 parent session (pre-load 500 in / 50 out, then loads eshu-code-review -> code-review, then 1000 in + 4000 cr / 200 out + 1 tool error)
con.execute("INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?)", (
    "ses_v2_parent", None, "/tmp/ws/eshu", json.dumps({"id": "gpt-5.6-sol"}),
    t0, t0 + 60000, 1500, 250, 4000, 0
))
con.execute("INSERT INTO session_message VALUES (?,?,?,?,?,?)", (
    "m1", "ses_v2_parent", "user", 1, t0, json.dumps({"text": "Review PR 42 in eshu"})
))
con.execute("INSERT INTO session_message VALUES (?,?,?,?,?,?)", (
    "m2", "ses_v2_parent", "assistant", 2, t0 + 5000, json.dumps({
        "model": {"id": "gpt-5.6-sol"},
        "tokens": {"input": 500, "output": 50, "cache": {"read": 0, "write": 0}},
        "content": [{"type": "text", "text": "Checking diff first."}],
    })
))
con.execute("INSERT INTO session_message VALUES (?,?,?,?,?,?)", (
    "m3", "ses_v2_parent", "user", 3, t0 + 25000, json.dumps({"text": "Why did tests fail?"})
))
con.execute("INSERT INTO session_message VALUES (?,?,?,?,?,?)", (
    "m4", "ses_v2_parent", "assistant", 4, t0 + 35000, json.dumps({
        "model": {"id": "gpt-5.6-sol"},
        "tokens": {"input": 1000, "output": 200, "cache": {"read": 4000, "write": 0}},
        "content": [
            {"type": "tool", "name": "skill", "state": {"status": "completed", "input": {"id": "eshu-code-review"}}},
            {"type": "tool", "name": "edit", "state": {"status": "error", "input": {"path": "/tmp/ws/eshu/main.go"}, "error": "not found in file"}},
            {"type": "text", "text": "Found a P1 bug."},
        ],
    })
))
# V2 child session
con.execute("INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?)", (
    "ses_v2_child", "ses_v2_parent", "", json.dumps({"id": "qwen3.8-flash"}),
    t0 + 10000, t0 + 20000, 200, 40, 800, 0
))
con.execute("INSERT INTO session_message VALUES (?,?,?,?,?,?)", (
    "mc1", "ses_v2_child", "assistant", 1, t0 + 15000, json.dumps({
        "model": {"id": "qwen3.8-flash"},
        "tokens": {"input": 200, "output": 40, "cache": {"read": 800, "write": 0}},
        "content": [{"type": "text", "text": "Child scan complete."}],
    })
))
# V1-only session (not in session_v2) + duplicate of ses_v2_parent in session to verify v2 wins
con.execute("INSERT INTO session VALUES (?,?,?,?,?,?,?,?,?,?)", (
    "ses_v2_parent", None, "/tmp/ws/old-dup", "old-model", t0, t0 + 1000, 1, 1, 0, 0
))
con.execute("INSERT INTO session VALUES (?,?,?,?,?,?,?,?,?,?)", (
    "ses_v1_only", None, "/tmp/ws/eshu-agent-kit", "claude-sonnet", t0 + 1000, t0 + 40000, 400, 80, 1200, 0
))
con.execute("INSERT INTO message VALUES (?,?,?,?)", ("vm1", "ses_v1_only", t0 + 1000, json.dumps({"role": "user"})))
con.execute("INSERT INTO message VALUES (?,?,?,?)", ("vm2", "ses_v1_only", t0 + 5000, json.dumps({"role": "assistant", "modelID": "claude-sonnet"})))
con.execute("INSERT INTO part VALUES (?,?,?,?,?)", ("p1", "vm1", "ses_v1_only", t0 + 1000, json.dumps({"type": "text", "text": "Optimize benchmark latency"})))
con.execute("INSERT INTO part VALUES (?,?,?,?,?)", ("p2", "vm2", "ses_v1_only", t0 + 6000, json.dumps({
    "type": "tool", "tool": "skill", "state": {"status": "completed", "input": {"name": "eshu-performance-rigor"}}
})))
con.execute("INSERT INTO part VALUES (?,?,?,?,?)", ("p3", "vm2", "ses_v1_only", t0 + 9000, json.dumps({
    "type": "step-finish", "tokens": {"input": 400, "output": 80, "cache": {"read": 1200, "write": 0}}
})))
con.commit()
con.close()
PYEOF

# Muse session using subagent.control.runtime_observed fallback (no model_completed):
# 500 in before skill load, 1500 in after skill load -> post-load should get 1500, unattributed 500!
cat >"${MUSE_DIR}/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-15T12:00:00+00:00","stream":{"id":"muse-fb-1"},"payload_type":"session.workspace_branch.observed","payload":{"workspace_root":"/tmp/ws/eshu"}}
{"recorded_at":"2026-11-15T12:00:01+00:00","payload_type":"runtime.user_intent.accepted","payload":{"text":"Investigate stall"}}
{"recorded_at":"2026-11-15T12:00:05+00:00","payload_type":"subagent.control.runtime_observed","payload":{"subagent_id":"c1","usage":{"input_tokens":500,"output_tokens":50,"cache_read_tokens":200,"cache_write_tokens":0}}}
{"recorded_at":"2026-11-15T12:00:10+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"skill_read_observed","skill_id":"diagnostic-rigor"}}}
{"recorded_at":"2026-11-15T12:00:20+00:00","payload_type":"subagent.control.runtime_observed","payload":{"subagent_id":"c2","usage":{"input_tokens":1500,"output_tokens":150,"cache_read_tokens":900,"cache_write_tokens":0}}}
{"recorded_at":"2026-11-15T12:00:25+00:00","payload_type":"runtime.user_intent.accepted","payload":{"text":"Keep going"}}
EOF

cache="${work}/cache"
out_dir="${work}/batches"
prep_json="${work}/prep.json"
agg_json="${work}/agg.json"
html_out="${work}/report.html"

# 1. Prepare across codex, opencode, muse using repeatable --transcript-root (including .db dir)
if bash "${DEBRIEF}" prepare --since 2026-11-01 --harness codex,opencode,muse \
	--cache-dir "${cache}" --out-dir "${out_dir}" \
	--transcript-root "${work}/codex" --transcript-root "${OC_DIR}" --transcript-root "${work}/muse/sessions" \
	--no-claude-import >"${prep_json}" &&
	python3 - "${prep_json}" "${cache}/meta" "${has_zstd}" <<'PYEOF'; then
import json, os, sys
manifest = json.load(open(sys.argv[1]))
meta_dir = sys.argv[2]
has_zstd = int(sys.argv[3])
expected_n = 6 if has_zstd else 5
assert manifest["sessions_discovered"] == expected_n, manifest
assert manifest["rolled_up_children"] == 1, manifest

codex = json.load(open(os.path.join(meta_dir, "codex__11111111-2222-3333-4444-555555555555.json")))
assert codex["prompts"] == 2, codex["prompts"]  # boilerplate AGENTS.md skipped
assert codex["skill_loads"] == ["postgres-rigor"], codex["skill_loads"]
assert codex["tokens_in"] == 4000 and codex["tokens_out"] == 350 and codex["tokens_cache_read"] == 2200, codex
assert codex["post_load_attribution"]["postgres-rigor"]["tokens_in"] == 3000.0, codex["post_load_attribution"]
assert codex["post_load_attribution"]["postgres-rigor"]["errors"] == 1.0, codex["post_load_attribution"]
assert codex["interjection_reasons"].get("redirect_goal") == 1, codex["interjection_reasons"]
assert codex["git_commits"] == 1 and codex["languages"].get("Go", 0) >= 1, codex

if has_zstd:
    arch = json.load(open(os.path.join(meta_dir, "codex__aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json")))
    assert arch["skill_loads"] == ["code-review"] and arch["tokens_in"] == 2000, arch

oc_v2 = json.load(open(os.path.join(meta_dir, "opencode__ses_v2_parent.json")))
assert oc_v2["project"] == "/tmp/ws/eshu"  # v2 preferred over v1 dup
assert oc_v2["skill_loads"] == ["code-review"], oc_v2["skill_loads"]
assert oc_v2["tokens_in"] == 5500 and oc_v2["tokens_out"] == 250 and oc_v2["tokens_cache_read"] == 4000, oc_v2
assert oc_v2["post_load_attribution"]["code-review"]["tokens_in"] == 5000.0, oc_v2["post_load_attribution"]
assert oc_v2["post_load_attribution"]["code-review"]["errors"] == 1.0, oc_v2["post_load_attribution"]
assert oc_v2["interjection_reasons"].get("debugging") == 1, oc_v2["interjection_reasons"]

oc_v1 = json.load(open(os.path.join(meta_dir, "opencode__ses_v1_only.json")))
assert oc_v1["skill_loads"] == ["performance-rigor"] and oc_v1["tokens_in"] == 1600, oc_v1
assert oc_v1["post_load_attribution"]["performance-rigor"]["tokens_in"] == 1600.0, oc_v1["post_load_attribution"]

muse = json.load(open(os.path.join(meta_dir, "muse__muse-fb-1.json")))
assert muse["tokens_in"] == 2000 and muse["tokens_out"] == 200, muse
assert muse["post_load_attribution"]["diagnostic-rigor"]["tokens_in"] == 1500.0, muse["post_load_attribution"]
assert muse["post_load_attribution"]["diagnostic-rigor"]["tokens_out"] == 150.0, muse["post_load_attribution"]
PYEOF
	ok "prepare extracts Codex (.jsonl/.zst), OpenCode (v1+v2), and Muse fallback with exact post-load attribution"
else
	no "prepare extracts Codex (.jsonl/.zst), OpenCode (v1+v2), and Muse fallback with exact post-load attribution"
fi

# 2. cache-write accepts codex and opencode facets cleanly.
cat >"${work}/facets.json" <<'EOF'
{"facets":[
  {"session_id":"11111111-2222-3333-4444-555555555555","harness":"codex","underlying_goal":"Audit postgres claim query","goal_categories":{"performance_investigation":1},"outcome":"fully_achieved","satisfaction":"satisfied","friction_counts":{},"primary_success":"good_debugging","session_type":"single_task","brief_summary":"Checked claim.go."},
  {"session_id":"ses_v2_parent","harness":"opencode","underlying_goal":"Review PR 42","goal_categories":{"pr_review_and_merge":1},"outcome":"mostly_achieved","satisfaction":"likely_satisfied","friction_counts":{"tool_failure":1},"primary_success":"hostile_review","session_type":"single_task","brief_summary":"Found P1."}
]}
EOF
if bash "${DEBRIEF}" cache-write --cache-dir "${cache}" "${work}/facets.json" >/dev/null; then
	ok "cache-write validates codex and opencode Stage 2 facets"
else
	no "cache-write validates codex and opencode Stage 2 facets"
fi

# 3. Aggregate & render reconcile tokens exactly (0.00 delta) and include codex + opencode in HTML.
printf '{"at_a_glance":{"working":"5-harness debrief works"}}\n' >"${work}/syn.json"
if bash "${DEBRIEF}" aggregate --since 2026-11-01 --harness codex,opencode,muse \
	--cache-dir "${cache}" --log "${work}/no-log.jsonl" --out "${agg_json}" >/dev/null &&
	bash "${DEBRIEF}" render --aggregate "${agg_json}" --synthesis "${work}/syn.json" --out "${html_out}" >/dev/null &&
	python3 - "${agg_json}" "${html_out}" <<'PYEOF'; then
import json, sys
agg = json.load(open(sys.argv[1]))
html = open(sys.argv[2], encoding="utf-8").read()
assert set(agg["by_harness"]) == {"codex", "opencode", "muse"}, agg["by_harness"]
assert not any("no load signal exists" in x for x in agg["not_tracked"]), agg["not_tracked"]
sc = agg["skill_costs"]
attr_in = sum(r["attributed_tokens_in"] for r in sc["per_skill"])
attr_out = sum(r["attributed_tokens_out"] for r in sc["per_skill"])
assert abs((attr_in + sc["unattributed"]["tokens_in"]) - sc["totals"]["tokens_in"]) < 0.05, sc
assert abs((attr_out + sc["unattributed"]["tokens_out"]) - sc["totals"]["tokens_out"]) < 0.05, sc
by_sk = {r["skill"]: r for r in sc["per_skill"]}
assert by_sk["postgres-rigor"]["attributed_tokens_in"] == 3000.0, by_sk
assert by_sk["code-review"]["attributed_tokens_in"] >= 5000.0, by_sk
assert by_sk["diagnostic-rigor"]["attributed_tokens_in"] == 1500.0, by_sk
assert "<code>codex</code>" in html and "<code>opencode</code>" in html
PYEOF
	ok "aggregate reconciles post-load costs across codex, opencode, muse and renders HTML"
else
	no "aggregate reconciles post-load costs across codex, opencode, muse and renders HTML"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL debrief-codex-opencode: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS debrief-codex-opencode: %d checks green\n' "${passed}"

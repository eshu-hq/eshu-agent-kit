#!/usr/bin/env bash
# Offline behavioral suite for multi-harness replay evals (issue #103).
# Tests mine (muse/claude/agy/all), unlocked skills, blind_traj & unbiased
# rubric_score, strip-proof gate (incl. skill_count), replay-runner.sh dry-run
# & output parsers, trajectory expectations & sweet-spot warning, blind judge
# verdict parser, report --json-out contract, and committed starter evals.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPLAY="${KIT_DIR}/scripts/replay-eval.sh"
RUNNER="${KIT_DIR}/scripts/replay-runner.sh"
LIB="${KIT_DIR}/scripts/lib"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg" HOME="${work}/home" TMPDIR="${work}/tmp"
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

# --- Fixtures: Muse + Claude + Agy transcripts (real, subagent, fixture). ---
MUSE_ROOT="${work}/muse/sessions"
CLAUDE_ROOT="${work}/claude/projects/demo"
AGY_BRAIN="${work}/agy/brain"
mkdir -p "${MUSE_ROOT}/sess-m1" "${MUSE_ROOT}/sess-m2" "${MUSE_ROOT}/t0001" \
	"${MUSE_ROOT}/sess-m1/subagent/child-m" \
	"${CLAUDE_ROOT}/parent-c/subagents" \
	"${AGY_BRAIN}/agy-real-1/.system_generated/logs" \
	"${AGY_BRAIN}/agy-child-1/.system_generated/logs" \
	"${AGY_BRAIN}/t0002/.system_generated/logs"

cat >"${MUSE_ROOT}/sess-m1/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-20T10:00:00+00:00","payload_type":"runtime.user_intent.accepted","payload":{}}
{"recorded_at":"2026-11-20T10:00:01+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["Fix the slow graph query on the dashboard"]}}}
{"recorded_at":"2026-11-20T10:00:02+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"skill_read_observed","skill_id":"performance-rigor"}}}
{"recorded_at":"2026-11-20T10:01:00+00:00","payload_type":"runtime.user_intent.accepted","payload":{}}
{"recorded_at":"2026-11-20T10:01:01+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["Second prompt must not leak"]}}}
{"recorded_at":"2026-11-20T10:02:00+00:00","payload_type":"runtime.user_intent.accepted","payload":{}}
EOF
cat >"${MUSE_ROOT}/sess-m2/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-21T10:00:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["Add retry with backoff to the queue worker"]}}}
EOF
cat >"${MUSE_ROOT}/t0001/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-21T10:00:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["fixture prompt that must be skipped"]}}}
EOF
cat >"${MUSE_ROOT}/sess-m1/subagent/child-m/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-20T10:05:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["child prompt that must be skipped"]}}}
EOF

cat >"${CLAUDE_ROOT}/claude-real-1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-20T10:00:00Z","promptSource":"system","message":{"content":"Stop hook feedback"}}
{"type":"user","timestamp":"2026-11-20T10:00:05Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"user","timestamp":"2026-11-20T10:00:10Z","message":{"content":"Review PR 99 for lease safety"}}
{"type":"assistant","timestamp":"2026-11-20T10:00:12Z","message":{"content":[{"type":"tool_use","id":"u1","name":"Skill","input":{"skill":"code-review"}}]}}
{"type":"user","timestamp":"2026-11-20T10:01:00Z","message":{"content":"Follow-up steering 1"}}
{"type":"user","timestamp":"2026-11-20T10:02:00Z","message":{"content":"Follow-up steering 2"}}
{"type":"user","timestamp":"2026-11-20T10:03:00Z","message":{"content":"Follow-up steering 3"}}
{"type":"user","timestamp":"2026-11-20T10:04:00Z","message":{"content":"Follow-up steering 4"}}
EOF
cat >"${CLAUDE_ROOT}/parent-c/subagents/agent-1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-20T10:00:10Z","message":{"content":"Claude subagent prompt must be skipped"}}
EOF

cat >"${AGY_BRAIN}/agy-real-1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","created_at":"2026-11-20T10:00:00Z","text":"Optimize cypher query indexing for workloads"}
{"type":"PLANNER_RESPONSE","created_at":"2026-11-20T10:00:05Z","tool_calls":[{"name":"read_file","args":{"Path":"/repo/skills/eshu/performance-rigor/SKILL.md"}}]}
{"type":"USER_INPUT","created_at":"2026-11-20T10:01:00Z","text":"Second agy prompt"}
EOF
cat >"${AGY_BRAIN}/agy-child-1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","created_at":"2026-11-20T10:00:00Z","text":"Agy nested child prompt must be skipped"}
EOF
cat >"${AGY_BRAIN}/t0002/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","created_at":"2026-11-20T10:00:00Z","text":"Agy fixture prompt must be skipped"}
EOF
python3 - "${work}/agy/conversation_summaries.db" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE conversation_summaries (conversation_id TEXT, workspace_uris TEXT, parent_conversation_id TEXT, nesting_depth INTEGER, agent_name TEXT)")
con.execute("INSERT INTO conversation_summaries VALUES ('agy-real-1', '[]', NULL, 0, 'main')")
con.execute("INSERT INTO conversation_summaries VALUES ('agy-child-1', '[]', 'agy-real-1', 1, 'sub')")
con.commit()
con.close()
PYEOF

# 1. mine --harness all across repeatable --sessions-root extracts all 3 harnesses cleanly.
bash "${REPLAY}" mine --harness all \
	--sessions-root "${MUSE_ROOT}" --sessions-root "${CLAUDE_ROOT}" --sessions-root "${AGY_BRAIN}" \
	--out "${work}/evals-all.json" >/dev/null &&
	python3 - "${work}/evals-all.json" <<'PYEOF' && ok "mine extracts first owner prompts across muse, claude, and agy" || no "mine extracts first owner prompts across muse, claude, and agy"
import json, sys
evals = json.load(open(sys.argv[1]))
by_id = {e["session_id"]: e for e in evals}
assert set(by_id) == {"sess-m1", "sess-m2", "claude-real-1", "agy-real-1"}, by_id
assert by_id["sess-m1"]["prompt"] == "Fix the slow graph query on the dashboard"
assert by_id["sess-m1"]["prompts_in_session"] == 3
assert by_id["claude-real-1"]["prompt"] == "Review PR 99 for lease safety"
assert by_id["claude-real-1"]["prompts_in_session"] == 5
assert by_id["agy-real-1"]["prompt"] == "Optimize cypher query indexing for workloads"
assert by_id["agy-real-1"]["prompts_in_session"] == 2
assert all(e["category"] == "production" and e["id"].startswith(e["harness"] + "-") for e in evals)
PYEOF

# 2. mine supports --skill, --query, --top-steered, --category, and --help refresh path.
bash "${REPLAY}" mine --harness all \
	--sessions-root "${MUSE_ROOT}" --sessions-root "${CLAUDE_ROOT}" --sessions-root "${AGY_BRAIN}" \
	--skill performance-rigor --top-steered --category edge --out "${work}/evals-filt.json" >/dev/null &&
	bash "${REPLAY}" mine --harness all \
		--sessions-root "${MUSE_ROOT}" --sessions-root "${CLAUDE_ROOT}" --sessions-root "${AGY_BRAIN}" \
		--query "lease safety" --out "${work}/evals-q.json" >/dev/null &&
	bash "${REPLAY}" mine --help 2>&1 | rg -qi "refresh" &&
	python3 - "${work}/evals-filt.json" "${work}/evals-q.json" <<'PYEOF' && ok "mine filters by --skill, --query, --top-steered, and --category" || no "mine filters by --skill, --query, --top-steered, and --category"
import json, sys
f = json.load(open(sys.argv[1]))
assert [e["session_id"] for e in f] == ["sess-m1", "agy-real-1"], f
assert all(e["skill"] == "performance-rigor" and e["category"] == "edge" for e in f)
q = json.load(open(sys.argv[2]))
assert [e["session_id"] for e in q] == ["claude-real-1"], q
PYEOF

# --- Stub runners: (a) skill-helps, (b) identical-output (bias check), (c) flaky. ---
cat >"${work}/runner.sh" <<'EOF'
#!/usr/bin/env bash
mode=""; prompt_file=""; out=""
while [ "$#" -gt 0 ]; do case "$1" in
	--mode) mode="$2"; shift 2;;
	--prompt-file) prompt_file="$2"; shift 2;;
	--out) out="$2"; shift 2;;
	*) shift;;
esac; done
prompt="$(cat "${prompt_file}")"
python3 - "${out}" "${mode}" "${prompt}" <<'PYEOF'
import json, sys
out, mode, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
if mode == "with-skill":
    json.dump({"transcript": prompt + " benchmark measured before and after with-skill With_Skill",
        "tools": ["benchmark", "read"], "skills": ["code-review"], "errors": 0,
        "tokens_in": 120, "tokens_out": 200, "cache_read_tokens": 40, "wall_time_s": 4.2, "cost_usd": 0.02}, open(out, "w"))
else:
    json.dump({"transcript": "unrelated weather chatter without_skill",
        "tools": [], "skills": [], "errors": 2,
        "tokens_in": 60, "tokens_out": 80, "cache_read_tokens": 10, "wall_time_s": 2.1, "cost_usd": 0.01}, open(out, "w"))
PYEOF
EOF
chmod +x "${work}/runner.sh"

cat >"${work}/same-runner.sh" <<'EOF'
#!/usr/bin/env bash
mode=""; prompt_file=""; out=""
while [ "$#" -gt 0 ]; do case "$1" in
	--mode) mode="$2"; shift 2;;
	--prompt-file) prompt_file="$2"; shift 2;;
	--out) out="$2"; shift 2;;
	*) shift;;
esac; done
python3 - "${out}" "${mode}" <<'PYEOF'
import json, sys
out, mode = sys.argv[1], sys.argv[2]
json.dump({"transcript": "identical answer mentioning benchmark and latency",
    "tools": ["read"], "skills": ["performance-rigor"] if mode == "with-skill" else [],
    "errors": 0, "tokens_in": 100, "tokens_out": 50, "wall_time_s": 1.0}, open(out, "w"))
PYEOF
EOF
chmod +x "${work}/same-runner.sh"

# 3. Unlocked skills + blind_traj removes skill_count & scrubs arm tokens + seal stores meta.
bash "${REPLAY}" replay --evals "${work}/evals-filt.json" --runner "${work}/runner.sh" \
	--skill code-review --harness claude --out "${work}/pairs.json" --seal "${work}/seal.json" >/dev/null &&
	python3 - "${work}/pairs.json" "${work}/seal.json" <<'PYEOF' && ok "replay unlocks any skill, removes skill_count, and seals meta" || no "replay unlocks any skill, removes skill_count, and seals meta"
import json, sys
pairs = json.load(open(sys.argv[1]))
seal = json.load(open(sys.argv[2]))
raw = json.dumps(pairs).lower()
for bad in ("with-skill", "without-skill", "with_skill", "without_skill", '"skill_count"', '"mode"', '"arm"'):
    assert bad not in raw, f"leaked {bad}: {raw}"
assert all("cache_read_tokens" in p["traj_a"] and "wall_time_s" in p["traj_a"] and "cost_usd" in p["traj_a"] for p in pairs)
assert seal["meta"] == {"skill": "code-review", "harness": "claude"}, seal
assert set(seal["arms"]) == {"p0", "p1"}, seal
PYEOF

# 4. Unbiased rubric_score proof: identical outputs with different skills -> tie!
bash "${REPLAY}" replay --evals "${work}/evals-filt.json" --runner "${work}/same-runner.sh" \
	--skill performance-rigor --out "${work}/pairs-same.json" --seal "${work}/seal-same.json" >/dev/null &&
	bash "${REPLAY}" judge --runs "${work}/pairs-same.json" --out "${work}/verdict-same.json" >/dev/null &&
	python3 - "${work}/verdict-same.json" <<'PYEOF' && ok "unbiased rubric_score ties when only skills metadata differed" || no "unbiased rubric_score ties when only skills metadata differed"
import json, sys
v = json.load(open(sys.argv[1]))
assert v["comparisons"] and all(c["winner"] == "tie" for c in v["comparisons"]), v
assert all("skill_use" not in c["rubric"]["A"] for c in v["comparisons"]), v
PYEOF

# 5. Strip-proof gate rejects mode, skill_count, and embedded arm tokens.
python3 - "${work}/pairs.json" "${work}" <<'PYEOF'
import copy, json, os, sys
base = json.load(open(sys.argv[1]))
p1 = copy.deepcopy(base); p1[0]["mode"] = "with-skill"
json.dump(p1, open(os.path.join(sys.argv[2], "taint-mode.json"), "w"))
p2 = copy.deepcopy(base); p2[0]["traj_a"]["skill_count"] = 1
json.dump(p2, open(os.path.join(sys.argv[2], "taint-sc.json"), "w"))
p3 = copy.deepcopy(base); p3[0]["traj_a"]["transcript"] = "ran in without-skill mode"
json.dump(p3, open(os.path.join(sys.argv[2], "taint-emb.json"), "w"))
PYEOF
! bash "${REPLAY}" judge --runs "${work}/taint-mode.json" --out "${work}/b1.json" >/dev/null 2>&1 &&
	! bash "${REPLAY}" judge --runs "${work}/taint-sc.json" --out "${work}/b2.json" >/dev/null 2>&1 &&
	! bash "${REPLAY}" judge --runs "${work}/taint-emb.json" --out "${work}/b3.json" >/dev/null 2>&1 &&
	ok "strip-proof gate refuses mode, skill_count, and embedded arm tokens" || no "strip-proof gate refuses mode, skill_count, and embedded arm tokens"

# 6. replay-runner.sh --dry-run-cmd for claude/agy/muse + missing-skill fail-fast.
printf 'Check lock contention\n' >"${work}/p.txt"
python3 - "${RUNNER}" "${KIT_DIR}" "${work}/p.txt" <<'PYEOF' && ok "replay-runner.sh --dry-run-cmd builds verified flags for all 3 harnesses" || no "replay-runner.sh --dry-run-cmd builds verified flags for all 3 harnesses"
import json, subprocess, sys
runner, kit, pf = sys.argv[1], sys.argv[2], sys.argv[3]
def dry(harness, mode, skill="performance-rigor"):
    p = subprocess.run(["bash", runner, "--harness", harness, "--mode", mode,
        "--skill", skill, "--prompt-file", pf, "--kit-dir", kit, "--dry-run-cmd"],
        capture_output=True, text=True)
    return p
r = dry("claude", "with-skill"); assert r.returncode == 0, r.stderr
d = json.loads(r.stdout)
assert "--append-system-prompt-file" in d["cmd"] and d["skill_path"].endswith("SKILL.md"), d
r2 = dry("claude", "without-skill"); assert r2.returncode == 0
d2 = json.loads(r2.stdout)
assert "--append-system-prompt-file" not in d2["cmd"] and d2["skill_path"] == "", d2
ra = dry("agy", "with-skill"); assert ra.returncode == 0
da = json.loads(ra.stdout)
parg = [a for a in da["cmd"] if a.startswith("-p=")]
assert parg and "Performance Rigor" in parg[0], da
ra2 = dry("agy", "without-skill"); assert ra2.returncode == 0
da2 = json.loads(ra2.stdout)
parg2 = [a for a in da2["cmd"] if a.startswith("-p=")]
assert parg2 and parg2[0] == "-p=Check lock contention\n", da2
rm = dry("muse", "with-skill"); assert rm.returncode == 0
dm = json.loads(rm.stdout)
assert "--no-foreign-personal-context" in dm["cmd"] and "--workspace" in dm["cmd"] and "--prompt-file" in dm["cmd"], dm
rbad = dry("claude", "with-skill", skill="nonexistent-skill-xyz")
assert rbad.returncode != 0, "must fail fast on missing skill"
PYEOF

# 7. Unit tests for parse_harness_output (claude/agy/muse), isolated_workspace, and parse_judge_verdict.
python3 -B - "${LIB}" "${work}" <<'PYEOF' && ok "parse_harness_output, isolated_workspace, and parse_judge_verdict pass unit checks" || no "parse_harness_output, isolated_workspace, and parse_judge_verdict pass unit checks"
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import replay_runner as rr
import replay_judge as rj

c_out = json.dumps({"result": "claude ok", "is_error": False, "duration_api_ms": 2500,
    "total_cost_usd": 0.015, "usage": {"input_tokens": 100, "cache_creation_input_tokens": 20,
    "cache_read_input_tokens": 30, "output_tokens": 50}})
pc = rr.parse_harness_output("claude", c_out, 9.0)
assert pc["transcript"] == "claude ok" and pc["tokens_in"] == 150.0 and pc["tokens_out"] == 50.0
assert pc["cache_read_tokens"] == 30.0 and pc["wall_time_s"] == 2.5 and pc["cost_usd"] == 0.015 and pc["errors"] == 0

a_out = json.dumps({"response": "agy ok", "status": "SUCCESS", "duration_seconds": 1.8,
    "usage": {"input_tokens": 80, "cache_read_tokens": 20, "output_tokens": 40}})
pa = rr.parse_harness_output("agy", a_out, 5.0)
assert pa["transcript"] == "agy ok" and pa["tokens_in"] == 100.0 and pa["cache_read_tokens"] == 20.0
assert pa["wall_time_s"] == 1.8 and pa["errors"] == 0

m_out = "\n".join([
    json.dumps({"payload_type": "tool_batch.effect.started", "payload": {"call_id": "c1", "tool_name": "read_file"}}),
    json.dumps({"payload_type": "tool_batch.effect.terminal", "payload": {"call_id": "c1", "outcome": {"kind": "completed"}}}),
    json.dumps({"payload_type": "tool_batch.effect.terminal", "payload": {"call_id": "c2", "tool_name": "bash", "outcome": {"kind": "failed"}}}),
    json.dumps({"payload": {"event": {"kind": "assistant_message_committed", "text": "muse done"}}}),
    json.dumps({"payload": {"event": {"kind": "model_completed", "duration_ms": 3100, "usage": {"input_tokens": 70, "cache_read_tokens": 10, "output_tokens": 30}}}}),
])
pm = rr.parse_harness_output("muse", m_out, 9.0)
assert pm["transcript"] == "muse done" and pm["tools"] == ["read_file", "bash"] and pm["errors"] == 1
assert pm["tokens_in"] == 80.0 and pm["tokens_out"] == 30.0 and pm["wall_time_s"] == 3.1

# Git worktree isolation test
repo = os.path.join(sys.argv[2], "mini-repo")
os.makedirs(repo)
subprocess.run(["git", "-C", repo, "init", "-q"], check=True)
subprocess.run(["git", "-C", repo, "config", "user.email", "t@example.com"], check=True)
subprocess.run(["git", "-C", repo, "config", "user.name", "T"], check=True)
open(os.path.join(repo, "f.txt"), "w").write("hi\n")
subprocess.run(["git", "-C", repo, "add", "f.txt"], check=True)
subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "init"], check=True)
with rr.isolated_workspace(repo) as iso:
    assert os.path.isfile(os.path.join(iso, "f.txt")) and iso != repo
    saved_iso = iso
assert not os.path.exists(saved_iso)

# Judge verdict parser
v1 = rj.parse_judge_verdict('{"winner": "A", "scores": {"A": {"goal": 5}}, "rationale": "better"}')
assert v1["winner"] == "A" and v1["rationale"] == "better"
v2 = rj.parse_judge_verdict('Here is my verdict:\n```json\n{"winner": "TIE", "scores": {}, "rationale": "even"}\n```')
assert v2["winner"] == "tie"
v3 = rj.parse_judge_verdict('Prefix {"winner": "b", "rationale": "ok"} suffix')
assert v3["winner"] == "B"
try:
    rj.parse_judge_verdict("no json here")
    raise AssertionError("should have failed")
except ValueError:
    pass
PYEOF

# 8. grade_expectations + 100% sweet-spot warning + report --json-out contract + flat seal compat.
cat >"${work}/exp-evals.json" <<'EOF'
[
  {"id":"e1","category":"golden","prompt":"Benchmark latency before and after","expectations":{"must_call_tools":["benchmark"],"must_mention":["before","after"],"must_not_mention":["weather"],"max_errors":0}},
  {"id":"e2","category":"golden","prompt":"Benchmark throughput before and after","expectations":{"must_call_tools":["benchmark"],"must_mention":["before"],"must_not_mention":["weather"],"max_errors":0}},
  {"id":"e3","category":"edge","prompt":"Benchmark memory before and after","expectations":{"must_call_tools":["benchmark"],"must_mention":["after"],"must_not_mention":["weather"],"max_errors":0}}
]
EOF
bash "${REPLAY}" replay --evals "${work}/exp-evals.json" --runner "${work}/runner.sh" \
	--skill performance-rigor --harness agy --repeats 2 \
	--out "${work}/pairs-exp.json" --seal "${work}/seal-exp.json" >/dev/null &&
	bash "${REPLAY}" judge --runs "${work}/pairs-exp.json" --out "${work}/verdict-exp.json" >/dev/null &&
	bash "${REPLAY}" report --verdict "${work}/verdict-exp.json" --seal "${work}/seal-exp.json" \
		--json-out "${work}/summary.json" >"${work}/report-exp.txt" &&
	rg -q "WARNING: sweet-spot" "${work}/report-exp.txt" &&
	rg -q "latency delta" "${work}/report-exp.txt" &&
	rg -q "signal-vs-noise" "${work}/report-exp.txt" &&
	python3 - "${work}/summary.json" "${work}/seal-exp.json" "${work}/flat-seal.json" <<'PYEOF' && ok "expectations grading, sweet-spot warning, and --json-out contract verified" || no "expectations grading, sweet-spot warning, and --json-out contract verified"
import json, sys
s = json.load(open(sys.argv[1]))
expected_keys = {
    "skill", "harness", "cross_pairs", "decisive_pairs", "ties",
    "with_skill_wins", "win_rate", "noise_band", "aa_pairs",
    "pass_rate_with", "pass_rate_without", "cost_delta_in",
    "cost_delta_out", "latency_delta_s", "recorded_at",
}
assert set(s) == expected_keys, set(s) ^ expected_keys
assert s["skill"] == "performance-rigor" and s["harness"] == "agy"
assert s["cross_pairs"] == 3 and s["with_skill_wins"] == 3 and s["win_rate"] == 1.0
assert s["noise_band"] == 0.0 and s["aa_pairs"] == 6
assert s["pass_rate_with"] == 1.0 and s["pass_rate_without"] == 0.0
assert s["cost_delta_in"] == 60.0 and s["cost_delta_out"] == 120.0
assert abs(s["latency_delta_s"] - 2.1) < 0.01
# Emit flat seal for backward-compat test
seal = json.load(open(sys.argv[2]))
json.dump(seal["arms"], open(sys.argv[3], "w"))
PYEOF
bash "${REPLAY}" report --verdict "${work}/verdict-exp.json" --seal "${work}/flat-seal.json" \
	--skill performance-rigor >"${work}/report-flat.txt" &&
	rg -q "win rate \(with-skill\): 3/3 = 1.00" "${work}/report-flat.txt" &&
	ok "report stays backward-compatible with flat seal.json" || no "report stays backward-compatible with flat seal.json"

# 9. Flaky runner produces nonzero A/A noise band + external --judge-cmd (A & TIE).
cat >"${work}/flaky.sh" <<'EOF'
#!/usr/bin/env bash
out=""; while [ "$#" -gt 0 ]; do case "$1" in --out) out="$2"; shift 2;; *) shift;; esac; done
n="$(cat "${TMPDIR:-/tmp}/flaky-count" 2>/dev/null || echo 0)"; echo $((n + 1)) >"${TMPDIR:-/tmp}/flaky-count"
if [ $((n % 3)) -eq 0 ]; then txt="benchmark latency before and after"; err=0; else txt="weather chatter"; err=1; fi
python3 - "${out}" "${txt}" "${err}" <<'PYEOF'
import json, sys
json.dump({"transcript": sys.argv[2], "tools": ["benchmark"], "errors": int(sys.argv[3]),
    "tokens_in": 10, "tokens_out": 10, "wall_time_s": 1.0}, open(sys.argv[1], "w"))
PYEOF
EOF
chmod +x "${work}/flaky.sh"
echo 0 >"${work}/tmp/flaky-count"
cat >"${work}/tie-judge.sh" <<'EOF'
#!/usr/bin/env bash
python3 -c "import json,sys; json.load(sys.stdin)"
printf 'TIE'
EOF
chmod +x "${work}/tie-judge.sh"
bash "${REPLAY}" replay --evals "${work}/evals-filt.json" --runner "${work}/flaky.sh" \
	--skill performance-rigor --repeats 2 --out "${work}/pairs-flaky.json" --seal "${work}/seal-flaky.json" >/dev/null &&
	bash "${REPLAY}" judge --runs "${work}/pairs-flaky.json" --out "${work}/verdict-flaky.json" >/dev/null &&
	bash "${REPLAY}" judge --runs "${work}/pairs.json" --judge-cmd "${work}/tie-judge.sh" --out "${work}/verdict-tie.json" >/dev/null &&
	python3 - "${work}/verdict-flaky.json" "${work}/verdict-tie.json" <<'PYEOF' && ok "flaky repeats yield nonzero noise and external TIE judge decodes as tie" || no "flaky repeats yield nonzero noise and external TIE judge decodes as tie"
import json, sys
vf = json.load(open(sys.argv[1]))
aa = [c for c in vf["comparisons"] if c.get("kind") == "aa"]
assert aa and any(c["winner"] != "tie" for c in aa), aa
vt = json.load(open(sys.argv[2]))
assert vt["comparisons"] and all(c["winner"] == "tie" for c in vt["comparisons"]), vt
PYEOF

# 10. Starter suites evals/code-review.json & evals/performance-rigor.json are valid and untainted.
python3 -B - "${LIB}" "${KIT_DIR}/evals/code-review.json" "${KIT_DIR}/evals/performance-rigor.json" <<'PYEOF' && ok "starter eval suites are valid JSON with golden+edge mix and zero taint" || no "starter eval suites are valid JSON with golden+edge mix and zero taint"
import json, sys
sys.path.insert(0, sys.argv[1])
from replay_eval import _taint_scan
for path in sys.argv[2:]:
    items = json.load(open(path))
    assert len(items) >= 4, path
    cats = [i["category"] for i in items]
    assert cats.count("golden") >= 3 and cats.count("edge") >= 1, (path, cats)
    for item in items:
        assert item.get("prompt") and isinstance(item.get("expectations"), dict), item
        assert not _taint_scan({"prompt": item["prompt"], "expectations": item["expectations"]}), item
PYEOF

# 11. Built-in replay-runner.sh (no --runner) + --judge-harness claude end-to-end via mock binary.
FAKE_BIN="${work}/fake-bin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/claude" <<'EOF'
#!/usr/bin/env bash
has_sys=0
for arg in "$@"; do
	[ "${arg}" = "--append-system-prompt-file" ] && has_sys=1
done
stdin_data="$(cat)"
python3 - "${has_sys}" "${stdin_data}" <<'PYEOF'
import json, sys
has_sys, prompt = int(sys.argv[1]), sys.argv[2]
if "You are a blind evaluator" in prompt:
    assert "with-skill" not in prompt.lower() and "without-skill" not in prompt.lower(), "tainted judge prompt"
    reply = json.dumps({"winner": "A", "scores": {"A": {"goal": 5, "correctness": 5, "efficiency": 4},
        "B": {"goal": 2, "correctness": 3, "efficiency": 4}}, "rationale": "Response A is complete"})
else:
    reply = "Measured before and after with baseline" if has_sys else "Quick guess without evidence"
print(json.dumps({"result": reply, "is_error": False, "duration_api_ms": 1200, "total_cost_usd": 0.01,
    "usage": {"input_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 10, "output_tokens": 25}}))
PYEOF
EOF
chmod +x "${FAKE_BIN}/claude"
printf '[{"id":"e1","category":"golden","prompt":"Measure queue latency"}]\n' >"${work}/one.json"
PATH="${FAKE_BIN}:${PATH}" bash "${REPLAY}" replay --evals "${work}/one.json" \
	--skill performance-rigor --harness claude --kit-dir "${KIT_DIR}" \
	--out "${work}/pairs-e2e.json" --seal "${work}/seal-e2e.json" >/dev/null &&
	PATH="${FAKE_BIN}:${PATH}" bash "${REPLAY}" judge --runs "${work}/pairs-e2e.json" \
		--judge-harness claude --out "${work}/verdict-e2e.json" >/dev/null &&
	python3 - "${work}/verdict-e2e.json" <<'PYEOF' && ok "built-in runner and --judge-harness claude work end-to-end" || no "built-in runner and --judge-harness claude work end-to-end"
import json, sys
v = json.load(open(sys.argv[1]))
assert len(v["comparisons"]) == 1, v
c = v["comparisons"][0]
assert c["winner"] == "A" and c["rubric"]["rationale"] == "Response A is complete", c
assert c["rubric"]["scores"]["A"]["goal"] == 5, c
PYEOF

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL replay-eval: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS replay-eval: %d checks green\n' "${passed}"

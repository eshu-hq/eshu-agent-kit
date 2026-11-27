#!/usr/bin/env bash
# Hermetic tests for Codex & OpenCode replay-eval adapters, --skills-dir
# portability, and #115 closeout hardening (issue #130).
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

# 1. replay-runner.sh --dry-run-cmd supports codex, opencode, and repeatable --skills-dir (flat dir).
mkdir -p "${work}/custom-skills/my-skill"
printf -- '---\nname: my-skill\ndescription: Custom standalone skill.\n---\n# My Skill\n1. Check logs.\n' >"${work}/custom-skills/my-skill/SKILL.md"
printf 'Inspect queue latency\n' >"${work}/p.txt"

if python3 - "${RUNNER}" "${work}/custom-skills" "${work}/p.txt" <<'PYEOF'; then
import json, subprocess, sys
runner, sdir, pf = sys.argv[1:4]
for h, expect_flag in (("codex", "exec"), ("opencode", "run")):
    r = subprocess.run([
        "bash", runner, "--harness", h, "--mode", "with-skill",
        "--skill", "my-skill", "--skills-dir", sdir, "--prompt-file", pf, "--dry-run-cmd",
    ], capture_output=True, text=True)
    assert r.returncode == 0, (h, r.stderr)
    d = json.loads(r.stdout)
    assert d["skill_path"].endswith("/my-skill/SKILL.md") and expect_flag in d["cmd"], d
PYEOF
	ok "replay-runner.sh supports codex, opencode, and standalone --skills-dir"
else
	no "replay-runner.sh supports codex, opencode, and standalone --skills-dir"
fi

# 2. Pure parsers for codex exec --json and opencode run --format json.
if python3 -B - "${LIB}" <<'PYEOF'; then
import json, sys
sys.path.insert(0, sys.argv[1])
from replay_parsers import parse_harness_output

cdx_out = "\n".join([
    json.dumps({"type": "item.completed", "item": {"type": "command_execution", "name": "shell", "exit_code": 0}}),
    json.dumps({"type": "item.completed", "item": {"type": "command_execution", "name": "shell", "exit_code": 1}}),
    json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "Codex verdict ok"}}),
    json.dumps({"type": "turn.completed", "usage": {"input_tokens": 500, "cached_input_tokens": 200, "output_tokens": 80}}),
])
pc = parse_harness_output("codex", cdx_out, 1.5)
assert pc["transcript"] == "Codex verdict ok" and len(pc["tools"]) == 2 and pc["errors"] == 1, pc
assert pc["tokens_in"] == 500.0 and pc["cache_read_tokens"] == 200.0 and pc["tokens_out"] == 80.0, pc
assert parse_harness_output("codex", "", 1.0)["errors"] == 1

oc_out = "\n".join([
    json.dumps({"type": "tool_use", "part": {"tool": "read", "state": {"status": "completed"}}}),
    json.dumps({"type": "text", "part": {"text": "OpenCode verdict ok"}}),
    json.dumps({"type": "step_finish", "part": {"cost": 0.012, "tokens": {"input": 300, "output": 60, "cache": {"read": 100, "write": 50}}}}),
])
po = parse_harness_output("opencode", oc_out, 2.0)
assert po["transcript"] == "OpenCode verdict ok" and po["tools"] == ["read"] and po["errors"] == 0, po
assert po["tokens_in"] == 450.0 and po["cache_read_tokens"] == 100.0 and po["tokens_out"] == 60.0 and po["cost_usd"] == 0.012, po
assert parse_harness_output("opencode", "", 1.0)["errors"] == 1
PYEOF
	ok "replay_parsers parses codex and opencode JSON streams accurately"
else
	no "replay_parsers parses codex and opencode JSON streams accurately"
fi

# 3. replay-eval.sh mine extracts first prompts from Codex JSONL and OpenCode SQLite.
mkdir -p "${work}/codex" "${work}/opencode"
cat >"${work}/codex/rollout-2026-11-15T10-00-00-11111111-2222-3333-4444-555555555555.jsonl" <<'EOF'
{"timestamp":"2026-11-15T10:00:00Z","type":"session_meta","payload":{"id":"11111111-2222-3333-4444-555555555555","cwd":"/tmp/r"}}
{"timestamp":"2026-11-15T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Trace slow query in codex"}]}}
{"timestamp":"2026-11-15T10:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"read_skill","arguments":"{\"name\":\"postgres-rigor\"}"}}
EOF
python3 - "${work}/opencode/opencode.db" <<'PYEOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE session_v2 (id TEXT, parent_id TEXT, directory TEXT, model TEXT, time_created INTEGER, time_updated INTEGER, tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER)")
con.execute("CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, data TEXT)")
t0 = 1794740000000
con.execute("INSERT INTO session_v2 VALUES ('oc_mine_1', NULL, '/tmp/r', 'm', ?, ?, 10, 5, 0, 0)", (t0, t0 + 1000))
con.execute("INSERT INTO session_message VALUES ('m1', 'oc_mine_1', 'user', 1, ?, ?)", (t0, json.dumps({"text": "Check lease lock ordering in opencode"})))
con.execute("INSERT INTO session_message VALUES ('m2', 'oc_mine_1', 'assistant', 2, ?, ?)", (t0 + 500, json.dumps({"content": [{"type": "tool", "name": "skill", "state": {"status": "completed", "input": {"id": "postgres-rigor"}}}]})))
con.commit()
con.close()
PYEOF

if bash "${REPLAY}" mine --harness all --sessions-root "${work}/codex" --sessions-root "${work}/opencode" \
	--skill postgres-rigor --out "${work}/mined.json" >/dev/null &&
	python3 - "${work}/mined.json" <<'PYEOF'; then
import json, sys
items = json.load(open(sys.argv[1]))
by_h = {i["harness"]: i["prompt"] for i in items}
assert by_h == {"codex": "Trace slow query in codex", "opencode": "Check lease lock ordering in opencode"}, by_h
PYEOF
	ok "mine extracts first prompts from Codex and OpenCode with --skill filter"
else
	no "mine extracts first prompts from Codex and OpenCode with --skill filter"
fi

# 4. #115 hardening: empty --history rejected; win_rate range & hex sha enforced; missing recorded_at runs do not collapse; partial trigger badge renders.
printf '{"comparisons":[]}\n' >"${work}/empty-v.json"
printf '{"meta":{"skill":"code-review","harness":"claude"},"arms":{}}\n' >"${work}/empty-s.json"
if (
	bash "${REPLAY}" report --verdict "${work}/empty-v.json" --seal "${work}/empty-s.json" --history "" >/dev/null 2>&1
	[ "$?" -eq 2 ]
) && python3 -B - "${LIB}" "${work}" <<'PYEOF'; then
import json, os, sys
sys.path.insert(0, sys.argv[1])
from debrief_evals import _eval_entry, eval_trends
from debrief_triggers import render_trigger_card, trigger_stats

bad = _eval_entry({"skill": "code-review", "win_rate": 1.5, "noise_band": -0.2, "skill_sha": "not-hex-xyz!"})
assert bad["win_rate"] is None and bad["noise_band"] is None and bad["skill_sha"] is None, bad
good = _eval_entry({"skill": "code-review", "win_rate": 0.75, "skill_sha": "abcdef012345"})
assert good["win_rate"] == 0.75 and good["skill_sha"] == "abcdef012345", good

r1 = (_eval_entry({"skill": "code-review", "harness": "claude", "win_rate": 0.5, "skill_sha": "abcdef01"}), True)
r2 = (_eval_entry({"skill": "code-review", "harness": "claude", "win_rate": 0.8, "skill_sha": "abcdef01"}), True)
tr = eval_trends([r1, r2], ["src"])
assert tr["per_skill"]["code-review"][0]["runs"] == 2, tr

tp = os.path.join(sys.argv[2], "trig-partial.json")
json.dump({
    "kind": "trigger-eval", "decider": "codex", "mode": "router-prompt",
    "recorded_at": "2026-11-27T00:00:00Z", "errors": 2,
    "per_skill": [{"skill": "code-review", "tp": 2, "fp": 0, "fn": 0, "tn": 1, "precision": 1.0, "recall": 1.0, "f1": 1.0}],
}, open(tp, "w"))
ts = trigger_stats([tp])
assert ts["per_skill"]["code-review"]["codex"]["partial"] is True, ts
card = render_trigger_card({"trigger_evals": ts, "skill_table": []})
assert "(partial)" in card and "codex" in card, card
PYEOF
	ok "#115 hardening: --history '', win_rate/sha validation, undated run count, and partial trigger badge"
else
	no "#115 hardening: --history '', win_rate/sha validation, undated run count, and partial trigger badge"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL replay-codex-opencode: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS replay-codex-opencode: %d checks green\n' "${passed}"

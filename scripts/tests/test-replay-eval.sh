#!/usr/bin/env bash
# Behavioral suite for replay evals (issue #83).
# Mines first prompts from raw Muse transcripts, replays each prompt with the
# target skill loaded vs stripped, blind-judges the pair, and reports win rate
# with an A/A repeat noise band. All state stays under a private work dir.
# Nothing here runs in CI (no workflow registration by design).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPLAY="${KIT_DIR}/scripts/replay-eval.sh"

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

# --- Fake Muse sessions root: two real sessions + one fixture session. ---
ROOT="${work}/muse/sessions"
mkdir -p "${ROOT}/sess-real-1" "${ROOT}/sess-real-2" "${ROOT}/t0001"
cat >"${ROOT}/sess-real-1/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-20T10:00:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["Fix the slow graph query on the dashboard"]}}}
{"recorded_at":"2026-11-20T10:01:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["Also update the docs"]}}}
{"recorded_at":"2026-11-20T10:02:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"assistant_message_committed","text":"done"}}}
EOF
cat >"${ROOT}/sess-real-2/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-21T10:00:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["Add retry with backoff to the queue worker"]}}}
EOF
cat >"${ROOT}/t0001/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-21T10:00:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["fixture prompt that must be skipped"]}}}
EOF
mkdir -p "${ROOT}/sess-real-1/subagent/child-a"
cat >"${ROOT}/sess-real-1/subagent/child-a/session.jsonl" <<'EOF'
{"recorded_at":"2026-11-20T10:05:00+00:00","payload_type":"runtime.session.nested","payload":{"event":{"kind":"model_user_messages","messages":["child prompt that must be skipped"]}}}
EOF

# 1. mine re-mines the FIRST prompt only from raw transcripts, skips fixtures.
bash "${REPLAY}" mine --sessions-root "${ROOT}" --out "${work}/evals.json" >/dev/null &&
	python3 - "${work}/evals.json" <<'PYEOF' && ok "mine emits first-prompts-only from raw transcripts" || no "mine emits first-prompts-only from raw transcripts"
import json, sys
evals = json.load(open(sys.argv[1]))
assert len(evals) == 2, evals
by_id = {e["session_id"]: e["prompt"] for e in evals}
assert by_id.get("sess-real-1") == "Fix the slow graph query on the dashboard", by_id
assert by_id.get("sess-real-2") == "Add retry with backoff to the queue worker", by_id
assert all("Also update the docs" not in e["prompt"] for e in evals), "second prompt leaked"
assert all("fixture" not in e["prompt"] for e in evals), "fixture session leaked"
assert all("child prompt" not in e["prompt"] for e in evals), "subagent child leaked"
PYEOF

# 2. mine documents the refresh path (re-mine as new sessions accrue).
bash "${REPLAY}" mine --help 2>&1 | rg -qi "refresh" &&
	ok "mine help documents the refresh path" || no "mine help documents the refresh path"

# 3. Only performance-rigor is accepted; only the Muse harness is supported.
bash "${REPLAY}" replay --evals "${work}/evals.json" --runner /bin/true \
	--skill contract-rigor --out "${work}/x.json" >/dev/null 2>&1 &&
	no "replay rejects non-performance-rigor skills" || ok "replay rejects non-performance-rigor skills"
bash "${REPLAY}" mine --sessions-root "${ROOT}" --harness claude \
	--out "${work}/x.json" >/dev/null 2>&1 &&
	no "mine rejects non-muse harnesses" || ok "mine rejects non-muse harnesses"

# --- Stub runner: with-skill answers the goal, without-skill rambles. ---
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
if [ "${mode}" = "with-skill" ]; then
	python3 - "${out}" "${prompt}" <<'PYEOF'
import json, sys
out, prompt = sys.argv[1], sys.argv[2]
json.dump({"transcript": prompt + " measured before and after with a benchmark",
	"tools": ["benchmark", "read"], "skills": ["performance-rigor"],
	"errors": 0, "tokens_in": 100, "tokens_out": 200}, open(out, "w"))
PYEOF
else
	python3 - "${out}" "${prompt}" <<'PYEOF'
import json, sys
out, prompt = sys.argv[1], sys.argv[2]
json.dump({"transcript": "some unrelated chatter about the weather",
	"tools": [], "skills": [],
	"errors": 2, "tokens_in": 50, "tokens_out": 60}, open(out, "w"))
PYEOF
fi
EOF
chmod +x "${work}/runner.sh"

# 4. replay records a blind pair: no arm identity in the judged package.
bash "${REPLAY}" replay --evals "${work}/evals.json" --runner "${work}/runner.sh" \
	--skill performance-rigor --out "${work}/pairs.json" --seal "${work}/seal.json" >/dev/null &&
	python3 - "${work}/pairs.json" <<'PYEOF' && ok "replay emits a strip-proof blind pair package" || no "replay emits a strip-proof blind pair package"
import json, sys
pairs = json.load(open(sys.argv[1]))
assert len(pairs) == 2, pairs
banned = ("with-skill", "without-skill", "with_skill", "without_skill", "\"mode\"", "\"arm\"")
raw = json.dumps(pairs)
assert not any(b in raw for b in banned), raw
assert all(set(p) >= {"pair_id", "prompt", "traj_a", "traj_b"} for p in pairs), pairs
PYEOF

# 5. judge refuses tainted input that carries arm identity (strip-proof gate).
python3 - "${work}/pairs.json" "${work}/tainted.json" <<'PYEOF'
import json, sys
pairs = json.load(open(sys.argv[1]))
pairs[0]["mode"] = "with-skill"
json.dump(pairs, open(sys.argv[2], "w"))
PYEOF
bash "${REPLAY}" judge --runs "${work}/tainted.json" --out "${work}/bad.json" >/dev/null 2>&1 &&
	no "judge refuses arm-labeled input" || ok "judge refuses arm-labeled input"

# 6. blind judge picks the goal-satisfying trajectory without knowing the arm.
bash "${REPLAY}" judge --runs "${work}/pairs.json" --out "${work}/verdict.json" >/dev/null &&
	python3 - "${work}/verdict.json" "${work}/seal.json" <<'PYEOF' && ok "blind judge favors the goal-satisfying trajectory" || no "blind judge favors the goal-satisfying trajectory"
import json, sys
verdict = json.load(open(sys.argv[1]))
seal = json.load(open(sys.argv[2]))
assert verdict["comparisons"], verdict
for c in verdict["comparisons"]:
	winner_label = c["winner"]
	assert winner_label in ("A", "B", "tie"), c
	assert seal[c["pair_id"]] == winner_label or winner_label == "tie", (c, seal)
	assert "rubric" in c and "goal_coverage" in c["rubric"]["A"], c
PYEOF

# 7. A/A repeats on a deterministic runner measure zero noise.
bash "${REPLAY}" replay --evals "${work}/evals.json" --runner "${work}/runner.sh" \
	--skill performance-rigor --out "${work}/pairs-aa.json" --seal "${work}/seal-aa.json" \
	--repeats 2 >/dev/null &&
	bash "${REPLAY}" judge --runs "${work}/pairs-aa.json" --out "${work}/verdict-aa.json" >/dev/null &&
	bash "${REPLAY}" report --verdict "${work}/verdict.json" --aa-verdict "${work}/verdict-aa.json" \
		--seal "${work}/seal.json" \
		>"${work}/report.txt" &&
	rg -q "win rate" "${work}/report.txt" && rg -q "noise band" "${work}/report.txt" &&
	rg -q "cost delta" "${work}/report.txt" &&
	python3 - "${work}/verdict-aa.json" <<'PYEOF' && ok "report carries win rate, noise band, and cost delta" || no "report carries win rate, noise band, and cost delta"
import json, sys
v = json.load(open(sys.argv[1]))
aa = [c for c in v["comparisons"] if c.get("kind") == "aa"]
assert aa, v
assert all(c["winner"] == "tie" for c in aa), aa
PYEOF

# 8. A flaky runner shows nonzero noise: the band measures repeat variance.
cat >"${work}/flaky.sh" <<'EOF'
#!/usr/bin/env bash
out=""; while [ "$#" -gt 0 ]; do case "$1" in --out) out="$2"; shift 2;; *) shift;; esac; done
n="$(cat "${TMPDIR:-/tmp}/flaky-count" 2>/dev/null || echo 0)"; echo $((n + 1)) >"${TMPDIR:-/tmp}/flaky-count"
if [ $((n % 3)) -eq 0 ]; then txt="benchmark measured before and after"; err=0; else txt="weather chatter"; err=1; fi
python3 - "${out}" "${txt}" "${err}" <<'PYEOF'
import json, sys
json.dump({"transcript": sys.argv[2], "tools": ["benchmark"], "skills": [],
	"errors": int(sys.argv[3]), "tokens_in": 10, "tokens_out": 10},
	open(sys.argv[1], "w"))
PYEOF
EOF
chmod +x "${work}/flaky.sh"
export TMPDIR="${work}/tmp"
echo 0 >"${work}/tmp/flaky-count"
bash "${REPLAY}" replay --evals "${work}/evals.json" --runner "${work}/flaky.sh" \
	--skill performance-rigor --out "${work}/pairs-flaky.json" --seal "${work}/seal-flaky.json" \
	--repeats 2 >/dev/null &&
	bash "${REPLAY}" judge --runs "${work}/pairs-flaky.json" \
		--out "${work}/verdict-flaky.json" >/dev/null &&
	python3 - "${work}/verdict-flaky.json" <<'PYEOF' && ok "flaky repeats yield a nonzero noise band" || no "flaky repeats yield a nonzero noise band"
import json, sys
v = json.load(open(sys.argv[1]))
aa = [c for c in v["comparisons"] if c.get("kind") == "aa"]
assert aa, v
assert any(c["winner"] != "tie" for c in aa), aa
PYEOF

# 9. strip-proof gate catches arm identity embedded in longer strings.
python3 - "${work}/pairs.json" "${work}/embedded.json" <<'PYEOF2'
import json, sys
pairs = json.load(open(sys.argv[1]))
pairs[0]["traj_a"]["transcript"] = "ran in mode with-skill for this task"
json.dump(pairs, open(sys.argv[2], "w"))
PYEOF2
bash "${REPLAY}" judge --runs "${work}/embedded.json" --out "${work}/bad2.json" >/dev/null 2>&1 &&
	no "judge refuses embedded arm identity" || ok "judge refuses embedded arm identity"

# 10. blind scrub covers underscore arm tokens in runner transcripts.
cat >"${work}/leaky.sh" <<'EOF2'
#!/usr/bin/env bash
mode=""; prompt_file=""; out=""
while [ "$#" -gt 0 ]; do case "$1" in
	--mode) mode="$2"; shift 2;;
	--prompt-file) prompt_file="$2"; shift 2;;
	--out) out="$2"; shift 2;;
	*) shift;;
esac; done
python3 - "${out}" "${mode}" <<'PYEOF2'
import json, sys
json.dump({"transcript": "ran in " + sys.argv[2].replace("-", "_") + " mode ok",
	"tools": [], "skills": [],
	"errors": 0, "tokens_in": 10, "tokens_out": 10},
	open(sys.argv[1], "w"))
PYEOF2
EOF2
chmod +x "${work}/leaky.sh"
bash "${REPLAY}" replay --evals "${work}/evals.json" --runner "${work}/leaky.sh" \
	--skill performance-rigor --out "${work}/pairs-leaky.json" --seal "${work}/seal-leaky.json" >/dev/null &&
	python3 - "${work}/pairs-leaky.json" <<'PYEOF2' && ok "blind scrub covers underscore arm tokens" || no "blind scrub covers underscore arm tokens"
import json, sys
raw = open(sys.argv[1]).read()
banned = ("with-skill", "without-skill", "with_skill", "without_skill")
assert not any(b in raw for b in banned), raw
PYEOF2

# 11. an external --judge-cmd decides the winner (stub prints A unconditionally).
cat >"${work}/stub-judge.sh" <<'EOF2'
#!/usr/bin/env bash
python3 -c "import json,sys; json.load(sys.stdin)"
printf 'A'
EOF2
chmod +x "${work}/stub-judge.sh"
bash "${REPLAY}" judge --runs "${work}/pairs.json" --judge-cmd "${work}/stub-judge.sh" \
	--out "${work}/verdict-ext.json" >/dev/null &&
	python3 - "${work}/verdict-ext.json" <<'PYEOF2' && ok "external judge-cmd decides the winner" || no "external judge-cmd decides the winner"
import json, sys
v = json.load(open(sys.argv[1]))
assert v["comparisons"], v
assert all(c["winner"] == "A" for c in v["comparisons"]), v
PYEOF2

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL replay-eval: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS replay-eval: %d checks green\n' "${passed}"

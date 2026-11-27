#!/usr/bin/env bash
# Offline behavioral suite for replay-eval ablation deltas (issue #118): tool
# call and error deltas, SKILL.md content hash at replay time, and the
# append-only `report --history` ledger. Stub runners only; no network, no
# real harness, temp DEBRIEF_DATA_DIR.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPLAY="${KIT_DIR}/scripts/replay-eval.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg" HOME="${work}/home" TMPDIR="${work}/tmp"
export DEBRIEF_DATA_DIR="${work}/data"
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

# Stub runner: with-skill makes ${WITH_TOOLS:-3} calls and 0 errors; the
# stripped arm makes 1 call and 2 errors. Output never names an arm.
cat >"${work}/runner.sh" <<'EOF'
#!/usr/bin/env bash
mode=""; out=""
while [ "$#" -gt 0 ]; do case "$1" in --mode) mode="$2"; shift 2;; --out) out="$2"; shift 2;; *) shift;; esac; done
python3 - "${out}" "${mode}" "${WITH_TOOLS:-3}" <<'PYEOF'
import json, sys
out, mode, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
if mode == "with-skill":
    traj = {"transcript": "benchmark before and after", "tools": ["t%d" % i for i in range(n)], "errors": 0}
else:
    traj = {"transcript": "weather chatter", "tools": ["t0"], "errors": 2}
traj.update({"tokens_in": 10, "tokens_out": 10, "wall_time_s": 1.0})
import os
if os.environ.get("NO_TOOLS"):
    traj.pop("tools")
if mode == "with-skill" and os.environ.get("EDIT_SKILL"):
    open(os.environ["EDIT_SKILL"], "a").write("edited mid-replay\n")
json.dump(traj, open(out, "w"))
PYEOF
EOF
chmod +x "${work}/runner.sh"
cat >"${work}/evals.json" <<'EOF'
[
  {"id": "e1", "category": "golden", "prompt": "Benchmark latency before and after"},
  {"id": "e2", "category": "golden", "prompt": "Benchmark throughput before and after"},
  {"id": "e3", "category": "edge", "prompt": "Benchmark memory before and after"}
]
EOF

# Fixture kit so skill_sha is hermetic and independent of the real SKILL.md.
KIT="${work}/kit"
mkdir -p "${KIT}/skills/eshu/demo-skill"
printf 'demo skill body v1\n' >"${KIT}/skills/eshu/demo-skill/SKILL.md"

run_pipeline() { # <tag> <skill> [replay extra args...]
	local tag="$1" skill="$2"
	shift 2
	bash "${REPLAY}" replay --evals "${work}/evals.json" --runner "${work}/runner.sh" \
		--skill "${skill}" --harness claude --repeats 2 "$@" \
		--out "${work}/pairs-${tag}.json" --seal "${work}/seal-${tag}.json" >/dev/null &&
		bash "${REPLAY}" judge --runs "${work}/pairs-${tag}.json" --out "${work}/verdict-${tag}.json" >/dev/null
}

# 1. Tool and error deltas: 3 calls/0 errors with the skill vs 1 call/2 errors without.
run_pipeline base demo-skill --kit-dir "${KIT}" &&
	bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
		--json-out "${work}/summary-base.json" >"${work}/report-base.txt" &&
	python3 - "${work}/summary-base.json" "${work}/report-base.txt" <<'PYEOF' && ok "report carries tool_calls_delta, tool_errors_delta, tool_pairs, kind" || no "report carries tool_calls_delta, tool_errors_delta, tool_pairs, kind"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["tool_calls_delta"] == 2.0 and s["tool_errors_delta"] == -2.0, s
assert s["tool_pairs"] == 3 and s["kind"] == "ablation", s
line = [ln for ln in open(sys.argv[2]).read().splitlines() if ln.startswith("tool delta")]
assert line == ["tool delta (mean with-skill minus stripped): +2.00 calls / -2.00 errors over 3 pairs"], line
PYEOF

# 2. Tool count is taken before the 50-entry tools[] truncation.
WITH_TOOLS=60 run_pipeline big demo-skill --kit-dir "${KIT}" &&
	bash "${REPLAY}" report --verdict "${work}/verdict-big.json" --seal "${work}/seal-big.json" \
		--json-out "${work}/summary-big.json" >/dev/null &&
	python3 - "${work}/summary-big.json" "${work}/pairs-big.json" <<'PYEOF' && ok "60-call trajectory counts past the 50-entry tools list" || no "60-call trajectory counts past the 50-entry tools list"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["tool_calls_delta"] == 59.0 and s["tool_calls_delta"] > 50, s
pairs = json.load(open(sys.argv[2]))
mx = max(len(p[k]["tools"]) for p in pairs for k in ("traj_a", "traj_b"))
assert mx == 50, mx
assert max(p[k]["tool_calls"] for p in pairs for k in ("traj_a", "traj_b")) == 60
PYEOF

# 3. skill_sha lives in seal meta only, equals sha256(SKILL.md bytes), and tracks edits.
sha1="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${KIT}/skills/eshu/demo-skill/SKILL.md")"
printf 'demo skill body v2 (edited)\n' >"${KIT}/skills/eshu/demo-skill/SKILL.md"
sha2="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${KIT}/skills/eshu/demo-skill/SKILL.md")"
run_pipeline v2 demo-skill --kit-dir "${KIT}" &&
	bash "${REPLAY}" report --verdict "${work}/verdict-v2.json" --seal "${work}/seal-v2.json" \
		--json-out "${work}/summary-v2.json" >/dev/null &&
	python3 - "${work}" "${sha1}" "${sha2}" <<'PYEOF' && ok "skill_sha is the SKILL.md sha256 in seal meta, changes on edit, never enters pairs" || no "skill_sha is the SKILL.md sha256 in seal meta, changes on edit, never enters pairs"
import json, re, sys
work, sha1, sha2 = sys.argv[1:4]
assert sha1 != sha2 and re.fullmatch(r"[0-9a-f]{64}", sha1)
base = json.load(open(work + "/seal-base.json"))
v2 = json.load(open(work + "/seal-v2.json"))
assert base["meta"]["skill_sha"] == sha1 and v2["meta"]["skill_sha"] == sha2, (base["meta"], v2["meta"])
assert json.load(open(work + "/summary-base.json"))["skill_sha"] == sha1
assert json.load(open(work + "/summary-v2.json"))["skill_sha"] == sha2
for tag in ("base", "v2"):
    text = open("%s/pairs-%s.json" % (work, tag)).read()
    assert "skill_sha" not in text and sha1 not in text and sha2 not in text, tag
PYEOF

# 4. Unresolvable SKILL.md: replay continues and the sha is null.
run_pipeline nokit ghost-skill --kit-dir "${KIT}" &&
	bash "${REPLAY}" report --verdict "${work}/verdict-nokit.json" --seal "${work}/seal-nokit.json" \
		--json-out "${work}/summary-nokit.json" >/dev/null &&
	python3 - "${work}/seal-nokit.json" "${work}/summary-nokit.json" <<'PYEOF' && ok "missing SKILL.md gives a null skill_sha without failing replay" || no "missing SKILL.md gives a null skill_sha without failing replay"
import json, sys
assert json.load(open(sys.argv[1]))["meta"]["skill_sha"] is None
assert json.load(open(sys.argv[2]))["skill_sha"] is None
PYEOF

# 5. Legacy verdict (pre-#118 rubric) and flat seal: null, never 0.
python3 - "${work}" <<'PYEOF'
import json, sys
work = sys.argv[1]
v = json.load(open(work + "/verdict-base.json"))
for c in v["comparisons"]:
    c["rubric"].pop("tool_calls", None)
    c["rubric"].pop("errors", None)
json.dump(v, open(work + "/verdict-legacy.json", "w"))
seal = json.load(open(work + "/seal-base.json"))
json.dump(seal["arms"], open(work + "/seal-flat.json", "w"))
PYEOF
bash "${REPLAY}" report --verdict "${work}/verdict-legacy.json" --seal "${work}/seal-base.json" \
	--json-out "${work}/summary-legacy.json" >"${work}/report-legacy.txt" &&
	bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-flat.json" \
		--skill demo-skill --json-out "${work}/summary-flat.json" >/dev/null &&
	bash "${REPLAY}" report --verdict "${work}/verdict-base.json" \
		--json-out "${work}/summary-blind.json" >"${work}/report-blind.txt" &&
	python3 - "${work}" <<'PYEOF' && ok "legacy verdict, flat seal, and no seal give null deltas and null sha" || no "legacy verdict, flat seal, and no seal give null deltas and null sha"
import json, sys
work = sys.argv[1]
leg = json.load(open(work + "/summary-legacy.json"))
assert leg["tool_calls_delta"] is None and leg["tool_errors_delta"] is None and leg["tool_pairs"] == 0, leg
assert leg["skill_sha"] is not None
assert "tool delta: no tool-bearing pairs" in open(work + "/report-legacy.txt").read()
flat = json.load(open(work + "/summary-flat.json"))
assert flat["skill_sha"] is None and flat["tool_calls_delta"] == 2.0, flat
blind = json.load(open(work + "/summary-blind.json"))
assert blind["tool_calls_delta"] is None and blind["tool_errors_delta"] is None and blind["skill_sha"] is None, blind
assert "tool delta: withheld" in open(work + "/report-blind.txt").read()
PYEOF

# 6. --history appends one compact, sorted-key JSON object per report.
ledger="${work}/ledger/runs.jsonl"
for _ in 1 2; do
	bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
		--history "${ledger}" --json-out "${work}/summary-hist.json" >/dev/null || break
done
python3 - "${ledger}" "${work}/summary-hist.json" <<'PYEOF' && ok "report --history appends exactly one parseable line per run" || no "report --history appends exactly one parseable line per run"
import json, sys
raw = open(sys.argv[1]).read()
lines = raw.splitlines()
assert len(lines) == 2 and raw.endswith("\n"), lines
recs = [json.loads(ln) for ln in lines]
for ln, rec in zip(lines, recs):
    assert ln == json.dumps(rec, sort_keys=True, separators=(",", ":")), ln
assert recs[1] == json.load(open(sys.argv[2])), "ledger line must equal the last --json-out object"
assert recs[0]["skill"] == "demo-skill" and recs[0]["kind"] == "ablation"
PYEOF

# 7. --default-history lands under DEBRIEF_DATA_DIR and honors DEBRIEF_APP_NAME.
bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
	--default-history >/dev/null &&
	DEBRIEF_DATA_DIR="" DEBRIEF_APP_NAME="kit-x" XDG_DATA_HOME="${work}/xdg2" \
		bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
		--default-history >/dev/null &&
	[ "$(wc -l <"${work}/data/replay-eval-history.jsonl")" -eq 1 ] &&
	[ "$(wc -l <"${work}/xdg2/kit-x/replay-eval-history.jsonl")" -eq 1 ] &&
	ok "--default-history writes replay-eval-history.jsonl under the data dir" || no "--default-history writes replay-eval-history.jsonl under the data dir"

# 8. Flag misuse exits 2 and writes nothing.
rc_noseal=0
bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --history "${work}/h2.jsonl" >/dev/null 2>"${work}/err-noseal.txt" || rc_noseal=$?
rc_both=0
bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
	--history "${work}/h2.jsonl" --default-history >/dev/null 2>"${work}/err-both.txt" || rc_both=$?
[ "${rc_noseal}" -eq 2 ] && [ "${rc_both}" -eq 2 ] && [ ! -e "${work}/h2.jsonl" ] &&
	rg -q "requires --seal" "${work}/err-noseal.txt" && rg -q "mutually exclusive" "${work}/err-both.txt" &&
	ok "--history needs --seal and excludes --default-history (exit 2, no write)" || no "--history needs --seal and excludes --default-history (exit 2, no write)"

# 9. Concurrent appenders never interleave a line (single O_APPEND write).
conc="${work}/conc.jsonl"
for i in 1 2 3 4 5 6; do
	bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
		--history "${conc}" >/dev/null &
done
wait
python3 - "${conc}" <<'PYEOF' && ok "6 concurrent report --history runs leave 6 intact lines" || no "6 concurrent report --history runs leave 6 intact lines"
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 6 and all(json.loads(ln)["kind"] == "ablation" for ln in lines), len(lines)
PYEOF

# 10. Unit checks: arm-neutral rubric fields and field-presence rules in judge_pair.
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "judge_pair emits arm-neutral tool_calls/errors only when both sides carry the count" || no "judge_pair emits arm-neutral tool_calls/errors only when both sides carry the count"
import sys
sys.path.insert(0, sys.argv[1])
import replay_judge as rj
side = lambda n, e: {"transcript": "x", "tools": [], "errors": e, "tool_calls": n, "tokens_in": 1, "tokens_out": 1}
_, rub = rj.judge_pair({"pair_id": "p0", "kind": "cross", "prompt": "benchmark", "traj_a": side(4, 1), "traj_b": side(2, 0)})
assert rub["tool_calls"] == {"A": 4, "B": 2} and rub["errors"] == {"A": 1, "B": 0}, rub
old = {"transcript": "x", "tools": [], "errors": 0, "tokens_in": 1, "tokens_out": 1}
_, rub = rj.judge_pair({"pair_id": "p1", "kind": "cross", "prompt": "benchmark", "traj_a": side(4, 1), "traj_b": old})
assert "tool_calls" not in rub and "errors" not in rub, rub
PYEOF

# 6. Unmeasured tool counts are null, never a measured 0.0 (P2: custom runner without `tools`).
NO_TOOLS=1 run_pipeline notools demo-skill --kit-dir "${KIT}" &&
	bash "${REPLAY}" report --verdict "${work}/verdict-notools.json" --seal "${work}/seal-notools.json" \
		--json-out "${work}/summary-notools.json" >"${work}/report-notools.txt" &&
	python3 - "${work}/summary-notools.json" "${work}/report-notools.txt" <<'PYEOF' && ok "a runner that reports no tools gives null deltas and tool_pairs 0" || no "a runner that reports no tools gives null deltas and tool_pairs 0"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["tool_calls_delta"] is None and s["tool_errors_delta"] is None and s["tool_pairs"] == 0, s
assert "+0.0 calls" not in open(sys.argv[2]).read()
PYEOF

# 7. agy parser leaves `tools` absent when the CLI result carries none (missing is not an empty list).
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "agy output without tools yields no tools key; an explicit empty list stays measured" || no "agy output without tools yields no tools key; an explicit empty list stays measured"
import json, sys
sys.path.insert(0, sys.argv[1])
from replay_runner import _parse_agy_output
from replay_eval import blind_traj
missing = _parse_agy_output(json.dumps({"response": "x", "status": "SUCCESS"}), 1.0)
assert "tools" not in missing, missing
assert "tool_calls" not in blind_traj(missing)
empty = _parse_agy_output(json.dumps({"response": "x", "status": "SUCCESS", "tools": []}), 1.0)
assert empty["tools"] == [] and blind_traj(empty)["tool_calls"] == 0
PYEOF

# 8. SKILL.md edited while replay runs: the hash cannot name one version, so it is null.
printf 'steady body\n' >"${KIT}/skills/eshu/demo-skill/SKILL.md"
EDIT_SKILL="${KIT}/skills/eshu/demo-skill/SKILL.md" run_pipeline midedit demo-skill --kit-dir "${KIT}" 2>"${work}/midedit.err" &&
	python3 - "${work}/seal-midedit.json" "${work}/midedit.err" <<'PYEOF' && ok "SKILL.md edited during replay gives a null skill_sha and a warning" || no "SKILL.md edited during replay gives a null skill_sha and a warning"
import json, sys
assert json.load(open(sys.argv[1]))["meta"]["skill_sha"] is None
assert "changed during replay" in open(sys.argv[2]).read()
PYEOF

# 9. A torn ledger tail (no trailing newline) does not swallow the next record.
printf '{"skill":"x","win' >"${work}/torn.jsonl"
bash "${REPLAY}" report --verdict "${work}/verdict-base.json" --seal "${work}/seal-base.json" \
	--history "${work}/torn.jsonl" >/dev/null &&
	python3 - "${work}/torn.jsonl" <<'PYEOF' && ok "append after a torn tail keeps the new record parseable on its own line" || no "append after a torn tail keeps the new record parseable on its own line"
import json, sys
lines = open(sys.argv[1]).read().split("\n")
assert lines[0] == '{"skill":"x","win', lines
assert json.loads(lines[1])["kind"] == "ablation", lines
PYEOF

printf 'replay-history: %d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]

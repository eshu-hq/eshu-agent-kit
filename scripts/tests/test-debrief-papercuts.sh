#!/usr/bin/env bash
# Behavioral suite for the debrief papercut loop (issue #82).
# Aggregate joins a caller-supplied papercut issue snapshot (no live gh calls)
# on the required `skill:` body line and surfaces per-skill filed vs fixed.
# All state stays under a private XDG_DATA_HOME/HOME/TMPDIR.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
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

cache="${work}/cache"
mkdir -p "${cache}"

# Snapshot v1: two debrief findings (one open, one closed), one closed
# issue-driver finding, one papercut without a skill line, one CLOSED as
# NOT_PLANNED (filed but never fixed), and one joining via a trailing
# period in the skill line.
cat >"${work}/papercuts-v1.json" <<'EOF'
[
  {"number": 101, "title": "[papercut] gap table off by one", "state": "OPEN",
   "body": "Tried X. Expected Y. Happened Z.\nskill: debrief\nFix: adjust bucket."},
  {"number": 102, "title": "[papercut] stale facet wins", "state": "CLOSED",
   "body": "Tried A. Expected B. Happened C.\nSkill: eshu-agent-kit:debrief\nFix: refresh cache."},
  {"number": 103, "title": "[papercut] filing path unclear", "state": "CLOSED",
   "body": "Tried filing. Expected template. Got free text.\nskill: issue-driver\nFix: add template."},
  {"number": 104, "title": "[papercut] vague report", "state": "OPEN",
   "body": "No skill line in this body at all."},
  {"number": 105, "title": "[papercut] out of scope", "state": "CLOSED", "stateReason": "NOT_PLANNED",
   "body": "Tried Q. Expected R. Happened S.\nskill: debrief\nFix: none planned."},
  {"number": 106, "title": "[papercut] join on sentence-final skill", "state": "OPEN",
   "body": "Tried T. Expected U. Happened V.\nskill: debrief.\nFix: normalize the join key."}
]
EOF

# A hook load for debrief so the skill_table carries a row to join against.
cat >"${work}/hooks.jsonl" <<'EOF'
{"harness":"muse","session":"s1","ts":"2026-11-20T10:00:00+00:00","type":"skill-load","detail":{"skill":"debrief"}}
EOF

bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" \
	--log "${work}/hooks.jsonl" --papercuts "${work}/papercuts-v1.json" \
	--out "${work}/agg-v1.json" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/agg-v1.json" <<'PYEOF' && ok "aggregate joins papercut snapshot on skill: line with filed vs fixed" || no "aggregate joins papercut snapshot on skill: line with filed vs fixed"
import json, sys
d = json.load(open(sys.argv[1]))
pc = d["papercuts"]
assert pc["total_filed"] == 5, pc
assert pc["total_open"] == 2, pc
assert pc["total_fixed"] == 2, pc
assert pc["unmatched_without_skill"] == 1, pc
assert pc["per_skill"]["debrief"] == {"filed": 4, "open": 2, "fixed": 1}, pc["per_skill"]
assert pc["per_skill"]["issue-driver"] == {"filed": 1, "open": 0, "fixed": 1}, pc["per_skill"]
assert "debrief." not in pc["per_skill"], pc["per_skill"]
by_sk = {r["skill"]: r for r in d["skill_table"]}
assert by_sk["debrief"]["papercut_filed"] == 4, by_sk["debrief"]
assert by_sk["debrief"]["papercut_open"] == 2, by_sk["debrief"]
assert by_sk["debrief"]["papercut_fixed"] == 1, by_sk["debrief"]
PYEOF

# Dict-wrapped snapshot with lowercase states parses the same way.
python3 - "${work}/papercuts-v1.json" "${work}/papercuts-dict.json" <<'PYEOF'
import json, sys
raw = json.load(open(sys.argv[1]))
for rec in raw:
    rec["state"] = rec["state"].lower()
json.dump({"issues": raw}, open(sys.argv[2], "w"))
PYEOF
bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" \
	--log "${work}/hooks.jsonl" --papercuts "${work}/papercuts-dict.json" \
	--out "${work}/agg-dict.json" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/agg-v1.json" "${work}/agg-dict.json" <<'PYEOF' && ok "dict-wrapped snapshot with lowercase states matches" || no "dict-wrapped snapshot with lowercase states matches"
import json, sys
a = json.load(open(sys.argv[1]))["papercuts"]
b = json.load(open(sys.argv[2]))["papercuts"]
assert a["per_skill"] == b["per_skill"], (a, b)
assert a["total_filed"] == b["total_filed"] and a["total_open"] == b["total_open"] and a["total_fixed"] == b["total_fixed"], (a, b)
PYEOF

# Closed-loop demo: issue 101 closes between runs; the later debrief run
# confirms it fixed without any other input changing.
python3 - "${work}/papercuts-v1.json" "${work}/papercuts-v2.json" <<'PYEOF'
import json, sys
raw = json.load(open(sys.argv[1]))
for rec in raw:
    if rec["number"] == 101:
        rec["state"] = "CLOSED"
json.dump(raw, open(sys.argv[2], "w"))
PYEOF
bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" \
	--log "${work}/hooks.jsonl" --papercuts "${work}/papercuts-v2.json" \
	--out "${work}/agg-v2.json" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/agg-v1.json" "${work}/agg-v2.json" <<'PYEOF' && ok "later run confirms the finding fixed (open drops from 2 to 1)" || no "later run confirms the finding fixed (open drops from 2 to 1)"
import json, sys
d1 = json.load(open(sys.argv[1]))
d2 = json.load(open(sys.argv[2]))
assert d1["papercuts"]["total_open"] == 2 and d2["papercuts"]["total_open"] == 1, (d1["papercuts"], d2["papercuts"])
before = d1["papercuts"]["per_skill"]["debrief"]
after = d2["papercuts"]["per_skill"]["debrief"]
assert before == {"filed": 4, "open": 2, "fixed": 1}, before
assert after == {"filed": 4, "open": 1, "fixed": 2}, after
by_sk2 = {r["skill"]: r for r in d2["skill_table"]}
assert by_sk2["debrief"]["papercut_open"] == 1 and by_sk2["debrief"]["papercut_fixed"] == 2, by_sk2["debrief"]
PYEOF

# Missing snapshot fails fast instead of silently reporting zeros.
if bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" \
	--papercuts "${work}/does-not-exist.json" --out "${work}/agg-bad.json" >/dev/null 2>&1; then
	no "missing papercut snapshot fails fast"
else
	ok "missing papercut snapshot fails fast"
fi

# No flag, no section: backward compatible, skill rows still carry zeros/nulls.
bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" \
	--log "${work}/hooks.jsonl" --out "${work}/agg-plain.json" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/agg-plain.json" <<'PYEOF' && ok "aggregate without --papercuts or --evals stays backward compatible" || no "aggregate without --papercuts or --evals stays backward compatible"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["papercuts"] is None and d["evals"] is None, (d["papercuts"], d["evals"])
by_sk = {r["skill"]: r for r in d["skill_table"]}
assert by_sk["debrief"]["papercut_filed"] == 0 and by_sk["debrief"]["papercut_open"] == 0 and by_sk["debrief"]["papercut_fixed"] == 0, by_sk["debrief"]
assert by_sk["debrief"]["eval_win_rate"] is None and by_sk["debrief"]["eval_pairs"] is None, by_sk["debrief"]
PYEOF

if bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" \
	--evals "${work}/no-such-evals.json" --out "${work}/agg-bad-eval.json" >/dev/null 2>&1; then
	no "missing --evals path fails fast"
else
	ok "missing --evals path fails fast"
fi

# HTML rendering: open/fixed counts render with --papercuts and dash without.
cat >"${work}/syn.json" <<'EOF'
{"at_a_glance":{"working":"Good","hindering":"None","quick_wins":"None","ambitious":"None"},"project_areas":[],"narrative_paragraphs":[],"key_insight":"Ok","wins_intro":"","big_wins":[],"friction_intro":"","friction_categories":[],"agents_md_additions":[],"features_to_try":[],"usage_patterns":[],"horizon_intro":"","horizon_workflows":[]}
EOF
bash "${DEBRIEF}" render --aggregate "${work}/agg-v1.json" --synthesis "${work}/syn.json" --out "${work}/r-v1.html" >/dev/null &&
	bash "${DEBRIEF}" render --aggregate "${work}/agg-v2.json" --synthesis "${work}/syn.json" --out "${work}/r-v2.html" >/dev/null &&
	bash "${DEBRIEF}" render --aggregate "${work}/agg-plain.json" --synthesis "${work}/syn.json" --out "${work}/r-plain.html" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/r-v1.html" "${work}/r-v2.html" "${work}/r-plain.html" <<'PYEOF' && ok "HTML renderer shows open/fixed papercuts and flywheel summary" || no "HTML renderer shows open/fixed papercuts and flywheel summary"
import re, sys
h1 = open(sys.argv[1], encoding="utf-8").read()
h2 = open(sys.argv[2], encoding="utf-8").read()
hp = open(sys.argv[3], encoding="utf-8").read()
assert "Top Skills (Flywheel Scorecard)" in h1 and "Skill Quality Flywheel" in h1
assert "2 open / 2 fixed" in h1 and ">2/1<" in h1, "v1 papercut render mismatch"
assert "1 open / 3 fixed" in h2 and ">1/2<" in h2, "v2 papercut render mismatch"
assert "open /" not in hp and ">0/0<" not in hp and ">—<" in hp, "plain render should show dash"
for h in (h1, h2, hp):
    assert not re.search(r"https?://", h), "external URL found in offline HTML!"
PYEOF

# --- Stage 1 meta schema upgrade: pre-#100 meta re-extracts without invalidating cached facet ---
upg_root="${work}/upg-agy/brain/conv-upg/.system_generated/logs"
upg_cache="${work}/upg-cache"
upg_batches="${work}/upg-batches"
mkdir -p "${upg_root}" "${upg_cache}/meta" "${upg_cache}/digests" "${upg_cache}/facets"
cat >"${upg_root}/transcript.jsonl" <<'EOF'
{"created_at":"2026-11-20T10:00:10Z","type":"USER_INPUT","content":"Audit upgrade"}
{"created_at":"2026-11-20T10:00:15Z","type":"PLANNER_RESPONSE","model":"gemini-flash","input_tokens":500,"output_tokens":120,"cache_read_tokens":2000,"tool_calls":[{"name":"read_file","args":{"Path":"/repo/skills/eshu/publish/SKILL.md"}}],"response":"Done."}
{"created_at":"2026-11-20T10:00:40Z","type":"USER_INPUT","content":"Thanks"}
EOF
python3 - "${upg_root}/transcript.jsonl" "${upg_cache}" <<'PYEOF'
import json, os, sys
p, cdir = sys.argv[1], sys.argv[2]
mt = os.path.getmtime(p)
json.dump({"id": "conv-upg", "harness": "agy", "source_path": p, "source_mtime": mt, "prompts": 2, "tool_calls": 1, "tokens_in": 0, "tokens_out": 0}, open(os.path.join(cdir, "meta", "agy__conv-upg.json"), "w"))
json.dump({"session_id": "conv-upg", "harness": "agy", "source_mtime": mt}, open(os.path.join(cdir, "digests", "agy__conv-upg.json"), "w"))
json.dump({"session_id": "conv-upg", "harness": "agy", "source_mtime": mt, "outcome": "fully_achieved", "satisfaction": "satisfied", "session_type": "single_task", "goal_categories": {}, "friction_counts": {}, "primary_success": "none", "underlying_goal": "Cached", "friction_detail": "", "brief_summary": "Cached"}, open(os.path.join(cdir, "facets", "agy__conv-upg.json"), "w"))
PYEOF
upg_prep="$(bash "${DEBRIEF}" prepare --since 2026-11-01 --harness agy --cache-dir "${upg_cache}" --out-dir "${upg_batches}" --transcript-root "${work}/upg-agy/brain")" && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${upg_prep}" "${upg_cache}/meta/agy__conv-upg.json" <<'PYEOF' && ok "pre-#100 meta re-extracts on schema upgrade while cached facet stays valid" || no "pre-#100 meta re-extracts on schema upgrade while cached facet stays valid"
import json, sys
m = json.loads(sys.argv[1])
assert m["facets_queued"] == 0 and m["facets_already_cached"] == 1, m
meta = json.load(open(sys.argv[2]))
assert meta["meta_version"] == 4, meta
assert meta["tokens_in"] == 2500 and meta["tokens_out"] == 120 and meta["tokens_cache_read"] == 2000, meta
PYEOF

# --- --evals error paths, record skipping, and timestamp precedence ---
printf '{bad json' >"${work}/eval-malformed.json"
if bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" --evals "${work}/eval-malformed.json" --out "${work}/agg-err1.json" >/dev/null 2>&1; then
	no "malformed --evals JSON fails fast"
else
	ok "malformed --evals JSON fails fast"
fi

printf '42\n' >"${work}/eval-scalar.json"
if bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" --evals "${work}/eval-scalar.json" --out "${work}/agg-err2.json" >/dev/null 2>&1; then
	no "invalid top-level --evals JSON fails fast"
else
	ok "invalid top-level --evals JSON fails fast"
fi

cat >"${work}/eval-edge.json" <<'EOF'
[
  "not-a-dict",
  {"win_rate": 0.5},
  {"skill": "debrief", "win_rate": 0.80, "recorded_at": "2026-11-20T10:00:00Z"},
  {"skill": "debrief", "win_rate": 0.10, "recorded_at": "zzzz-not-a-date"},
  {"skill": "publish", "win_rate": 0.20, "recorded_at": "zzzz-not-a-date"},
  {"skill": "publish", "win_rate": 0.90, "recorded_at": "2026-11-20T10:00:00Z"}
]
EOF
bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${cache}" --log "${work}/hooks.jsonl" \
	--evals "${work}/eval-edge.json" --out "${work}/agg-eval-edge.json" >/dev/null && rc=0 || rc=1
[ "${rc}" -eq 0 ] && python3 - "${work}/agg-eval-edge.json" <<'PYEOF' && ok "--evals skips non-dict/skill-less rows and prevents garbage recorded_at from overwriting ISO" || no "--evals skips non-dict/skill-less rows and prevents garbage recorded_at from overwriting ISO"
import json, sys
ev = json.load(open(sys.argv[1]))["evals"]
assert ev["records_skipped"] == 2 and ev["records_loaded"] == 4, ev
assert ev["per_skill"]["debrief"]["win_rate"] == 0.80 and ev["per_skill"]["debrief"]["recorded_at"] == "2026-11-20T10:00:00Z", ev
assert ev["per_skill"]["publish"]["win_rate"] == 0.90 and ev["per_skill"]["publish"]["recorded_at"] == "2026-11-20T10:00:00Z", ev
PYEOF

# --- Non-finite numeric guards + render P3 tie-break & safe_int checks ---
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "non-finite guards, ascending context-tax tie-break, safe_int, and legacy open fallback hold" || no "non-finite guards, ascending context-tax tie-break, safe_int, and legacy open fallback hold"
import sys
sys.path.insert(0, sys.argv[1])
from debrief_aggregate import _opt_float
from debrief_common import safe_float
from debrief_render_skills import _fmt_eval_win, _fmt_num, _fmt_pct, _fmt_tokens, _render_flywheel_summary, render_harness_skill_section
from debrief_skill_costs import _nonneg_float

for bad in (float("nan"), float("inf"), float("-inf")):
    assert _opt_float(bad) is None, bad
    assert _nonneg_float(bad) == 0.0, bad
    assert safe_float(bad, 0.0) == 0.0, bad
    assert _fmt_tokens(bad) == "—", bad
    assert _fmt_num(bad) == "—", bad
    assert _fmt_pct(bad) is None, bad
    assert _fmt_eval_win({"eval_win_rate": bad, "eval_noise_band": 0.05}) == "—", bad
    assert _fmt_eval_win({"eval_win_rate": 0.8, "eval_noise_band": bad}) == "80%", bad

agg = {
    "by_harness": {"muse": {"top_sessions": None, "sessions": "bad", "facets": 1, "prompts": "5", "tool_calls": None, "errors": 0}},
    "skill_costs": {
        "per_skill": [
            {"skill": "zeta", "attributed_tokens_total": 100.0, "estimated_context_tax_tokens": 500.0},
            {"skill": "alpha", "attributed_tokens_total": 100.0, "estimated_context_tax_tokens": 500.0},
        ],
        "by_harness": {},
    },
    "papercuts": {"total_filed": 5, "total_fixed": 2},
    "skill_table": [{"skill": "alpha", "mined_loads": 1, "hook_loads": 0, "forced": 0, "forced_pct": None, "attributed_tokens_total": 100.0, "estimated_context_tax_tokens": 500.0, "papercut_filed": 3, "papercut_fixed": 1}],
}
fly = _render_flywheel_summary(agg)
assert "alpha (500)" in fly and "3 open / 2 fixed" in fly, fly
sec = render_harness_skill_section(agg)
assert "0 / 0" in sec and ">2/1<" in sec, sec
PYEOF

printf '\ndebrief-papercuts: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

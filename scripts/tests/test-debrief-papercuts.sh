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
assert pc["total_fixed"] == 2, pc
assert pc["unmatched_without_skill"] == 1, pc
assert pc["per_skill"]["debrief"] == {"filed": 4, "fixed": 1}, pc["per_skill"]
assert pc["per_skill"]["issue-driver"] == {"filed": 1, "fixed": 1}, pc["per_skill"]
assert "debrief." not in pc["per_skill"], pc["per_skill"]
by_sk = {r["skill"]: r for r in d["skill_table"]}
assert by_sk["debrief"]["papercut_filed"] == 4, by_sk["debrief"]
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
assert a["total_filed"] == b["total_filed"] and a["total_fixed"] == b["total_fixed"], (a, b)
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
[ "${rc}" -eq 0 ] && python3 - "${work}/agg-v1.json" "${work}/agg-v2.json" <<'PYEOF' && ok "later run confirms the finding fixed (0 open debrief papercuts remain)" || no "later run confirms the finding fixed (0 open debrief papercuts remain)"
import json, sys
before = json.load(open(sys.argv[1]))["papercuts"]["per_skill"]["debrief"]
after = json.load(open(sys.argv[2]))["papercuts"]["per_skill"]["debrief"]
assert before == {"filed": 4, "fixed": 1}, before
assert after == {"filed": 4, "fixed": 2}, after
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
assert by_sk["debrief"]["papercut_filed"] == 0 and by_sk["debrief"]["papercut_fixed"] == 0, by_sk["debrief"]
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
assert "3 open / 2 fixed" in h1 and ">3/1<" in h1, "v1 papercut render mismatch"
assert "2 open / 3 fixed" in h2 and ">2/2<" in h2, "v2 papercut render mismatch"
assert "open /" not in hp and ">0/0<" not in hp and ">—<" in hp, "plain render should show dash"
for h in (h1, h2, hp):
    assert not re.search(r"https?://", h), "external URL found in offline HTML!"
PYEOF

printf '\ndebrief-papercuts: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

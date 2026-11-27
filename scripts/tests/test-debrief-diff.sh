#!/usr/bin/env bash
# scripts/tests/test-debrief-diff.sh — Verify report snapshots, --compare-prev /
# --compare / `debrief.sh diff`, recommendation accountability (implemented_verified,
# implemented_ineffective, not_done with carry_over_count), and overlaid SVG Radar chart.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKILLS="${TMP}/skills"
mkdir -p "${SKILLS}/alpha-skill" "${SKILLS}/beta-skill" "${SKILLS}/gamma-skill"
printf -- '---\nname: alpha-skill\ndescription: v1\n---\n# Alpha v1\n' >"${SKILLS}/alpha-skill/SKILL.md"
printf -- '---\nname: beta-skill\ndescription: v1\n---\n# Beta v1\n' >"${SKILLS}/beta-skill/SKILL.md"
printf -- '---\nname: gamma-skill\ndescription: v1\n---\n# Gamma v1\n' >"${SKILLS}/gamma-skill/SKILL.md"

REPORTS="${TMP}/reports"
CACHE1="${TMP}/cache1"
CACHE2="${TMP}/cache2"
mkdir -p "${CACHE1}/meta" "${CACHE1}/facets" "${CACHE2}/meta" "${CACHE2}/facets"

NOW="$(python3 -B -c 'import time; print(int(time.time()))')"

# Seed Window 1:
#  - alpha-skill: 5 sessions, 3 errors/session (triggers MODIFY)
#  - beta-skill:  5 sessions, 3 errors/session (triggers MODIFY)
#  - gamma-skill: 5 sessions, 3 errors/session (triggers MODIFY)
python3 -B - "${CACHE1}/meta" "${CACHE1}/facets" "${NOW}" <<'PY'
import json, os, sys
md, fd, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
for idx in range(5):
    for sk, errs, red in (("alpha-skill", 3, 2), ("beta-skill", 3, 2), ("gamma-skill", 3, 2)):
        sid = f"{sk[:4]}-w1-{idx:04d}"
        with open(os.path.join(md, f"claude__{sid}.json"), "w") as fh:
            json.dump({
                "meta_version": 5, "id": sid, "harness": "claude",
                "project": "/tmp/demo", "workspaces": ["/tmp/demo"],
                "first_ts": "2026-11-20T10:00:00Z", "last_ts": "2026-11-20T10:05:00Z",
                "first_epoch": now - 600, "last_epoch": now - 300, "source_mtime": now - 300,
                "prompts": 3, "tool_calls": 10, "errors": {"Bash": errs},
                "error_categories": {"Command Failed": errs},
                "interjection_reasons": {"redirect_goal": red},
                "tokens_in": 1000, "tokens_out": 500, "cache_read": 2000, "cache_write": 200,
                "skill_loads": [sk],
            }, fh)
        with open(os.path.join(fd, f"claude__{sid}.json"), "w") as fh:
            json.dump({
                "session_id": sid, "harness": "claude", "source_mtime": now - 300,
                "underlying_goal": "Work", "goal_categories": {"bug_fix": 1},
                "outcome": "partially_achieved", "satisfaction": "unsure",
                "friction_counts": {"tool_failure": 1}, "friction_detail": "failed",
                "primary_success": "none", "session_type": "single_task", "brief_summary": "w1",
            }, fh)
PY

AGG1="${TMP}/agg1.json"
SYN="${TMP}/syn.json"
SNAP1="${TMP}/snap1.json"
EMPTY_LOG="${TMP}/empty.jsonl"
: >"${EMPTY_LOG}"
printf '{"at_a_glance":{"working":"w1"},"narrative_paragraphs":["w1"]}\n' >"${SYN}"

bash "${DEBRIEF}" aggregate --cache-dir "${CACHE1}" --log "${EMPTY_LOG}" --skills-dir "${SKILLS}" --out "${AGG1}" >/dev/null
bash "${DEBRIEF}" render --aggregate "${AGG1}" --synthesis "${SYN}" --reports-dir "${REPORTS}" --skills-dir "${SKILLS}" --snapshot-out "${SNAP1}" >/dev/null

[ -f "${SNAP1}" ] || {
	echo "FAIL: --snapshot-out not written" >&2
	exit 1
}
[ -f "${REPORTS}/snapshots/latest-snapshot.json" ] || {
	echo "FAIL: latest-snapshot.json missing" >&2
	exit 1
}
echo "ok - render persists snapshot + latest-snapshot + --snapshot-out"

# Simulate edits between Window 1 and Window 2:
#  - alpha-skill edited AND errors drop 3 -> 0 (implemented_verified)
#  - beta-skill edited BUT errors stay 3 -> 4 (implemented_ineffective)
#  - gamma-skill NOT edited and errors stay 3 (not_done, carry_over_count=1)
printf -- '---\nname: alpha-skill\ndescription: v2 improved\n---\n# Alpha v2\n' >"${SKILLS}/alpha-skill/SKILL.md"
printf -- '---\nname: beta-skill\ndescription: v2 tweaked\n---\n# Beta v2\n' >"${SKILLS}/beta-skill/SKILL.md"

python3 -B - "${CACHE2}/meta" "${CACHE2}/facets" "${NOW}" <<'PY'
import json, os, sys
md, fd, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
for idx in range(5):
    for sk, errs, red, outc in (
        ("alpha-skill", 0, 0, "fully_achieved"),
        ("beta-skill", 4, 2, "partially_achieved"),
        ("gamma-skill", 3, 2, "partially_achieved"),
    ):
        sid = f"{sk[:4]}-w2-{idx:04d}"
        with open(os.path.join(md, f"claude__{sid}.json"), "w") as fh:
            json.dump({
                "meta_version": 5, "id": sid, "harness": "claude",
                "project": "/tmp/demo", "workspaces": ["/tmp/demo"],
                "first_ts": "2026-11-27T10:00:00Z", "last_ts": "2026-11-27T10:05:00Z",
                "first_epoch": now - 200, "last_epoch": now - 100, "source_mtime": now - 100,
                "prompts": 2, "tool_calls": 8, "errors": {"Bash": errs} if errs else {},
                "error_categories": {"Command Failed": errs} if errs else {},
                "interjection_reasons": {"redirect_goal": red} if red else {},
                "tokens_in": 500, "tokens_out": 300, "cache_read": 5000, "cache_write": 100,
                "skill_loads": [sk],
            }, fh)
        with open(os.path.join(fd, f"claude__{sid}.json"), "w") as fh:
            json.dump({
                "session_id": sid, "harness": "claude", "source_mtime": now - 100,
                "underlying_goal": "Work", "goal_categories": {"bug_fix": 1},
                "outcome": outc, "satisfaction": "satisfied" if outc == "fully_achieved" else "unsure",
                "friction_counts": {}, "friction_detail": "",
                "primary_success": "correct_code_edits", "session_type": "single_task", "brief_summary": "w2",
            }, fh)
PY

# 2. aggregate --compare-prev verifies all 3 statuses + computes positive radar area delta
AGG2="${TMP}/agg2.json"
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE2}" --log "${EMPTY_LOG}" --skills-dir "${SKILLS}" --reports-dir "${REPORTS}" --compare-prev --out "${AGG2}" >/dev/null
python3 -B - "${AGG2}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
d = a["diff_from_prev"]
assert d is not None, "diff_from_prev missing"
by_target = {r["target"]: r for r in d["accountability"]}
assert by_target["alpha-skill"]["status"] == "implemented_verified", by_target["alpha-skill"]
assert by_target["beta-skill"]["status"] == "implemented_ineffective", by_target["beta-skill"]
assert by_target["gamma-skill"]["status"] == "not_done", by_target["gamma-skill"]
assert by_target["gamma-skill"]["carry_over_count"] == 1
rd = d["radar_diff"]
assert rd["area_curr"] > rd["area_prev"], f"expected radar area expansion: {rd}"
assert rd["axes"]["reliability"]["direction"] == "improved", rd["axes"]["reliability"]
assert rd["axes"]["alignment"]["direction"] == "improved", rd["axes"]["alignment"]
PY
echo "ok - --compare-prev classifies verified/ineffective/not_done and detects radar expansion"

# 3. Standalone `debrief.sh diff` works on snapshot vs aggregate
DIFF_OUT="${TMP}/diff.json"
bash "${DEBRIEF}" diff --prev "${SNAP1}" --curr "${AGG2}" --skills-dir "${SKILLS}" --out "${DIFF_OUT}" >/dev/null
python3 -B - "${DIFF_OUT}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["accountability_counts"]["implemented_verified"] == 1
assert d["accountability_counts"]["implemented_ineffective"] == 1
assert d["accountability_counts"]["not_done"] == 1
PY
echo "ok - standalone debrief.sh diff reproduces exact accountability counts"

# 4. Render HTML includes overlaid Radar SVG (dashed previous + filled current) and Accountability table
HTML2="${TMP}/report2.html"
bash "${DEBRIEF}" render --aggregate "${AGG2}" --synthesis "${SYN}" --out "${HTML2}" --no-snapshot >/dev/null
grep -q 'Operational Trajectory Radar' "${HTML2}"
grep -q 'stroke-dasharray="5,4"' "${HTML2}"
grep -q 'DONE + VERIFIED' "${HTML2}"
grep -q 'DONE + NO EFFECT' "${HTML2}"
grep -q 'NOT DONE' "${HTML2}"
grep -q 'Trajectory: Expanded' "${HTML2}"
echo "ok - rendered HTML displays overlaid Trajectory Radar SVG and Accountability badges"

# 5. Invalid --compare file exits 2
set +e
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE2}" --compare "${TMP}/missing.json" >/dev/null 2>&1
rc=$?
set -e
[ "${rc}" -eq 2 ] || {
	echo "FAIL: missing --compare exited ${rc}, expected 2" >&2
	exit 1
}
echo "ok - missing --compare exits 2"

echo "PASS debrief-diff: 5 checks green"

#!/usr/bin/env bash
# scripts/tests/test-debrief-pareto.sh — Verify multi-objective Pareto optimizer:
# noise-aware skill_sha version frontier, HEAD regression alert, portfolio frontier
# + knee point + dominated_by, hypervolume ΔHV in diff, and offline SVG frontier plot.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Unit proof: noise-aware dominance, knee point, HEAD regression, and 2D hypervolume
python3 -B - "${KIT_DIR}/scripts/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import debrief_pareto as dp

# 1a. Uncertainty-aware dominance: within noise band -> neither dominates
eval_trends_noisy = {
    "per_skill": {
        "noisy-skill": [
            {"harness": "claude", "skill_sha": "aaaa1111aaaa1111", "sha_short": "aaaa1111", "win_rate": 0.75, "noise_band": 0.15, "cost_delta_in": 1000, "cost_delta_out": 0, "tool_errors_delta": 0.0, "last_recorded_at": "2026-11-01T00:00:00Z"},
            {"harness": "claude", "skill_sha": "bbbb2222bbbb2222", "sha_short": "bbbb2222", "win_rate": 0.68, "noise_band": 0.15, "cost_delta_in": 1000, "cost_delta_out": 0, "tool_errors_delta": 0.0, "last_recorded_at": "2026-11-02T00:00:00Z"},
        ]
    }
}
res_noisy = dp.compute_pareto_analysis([], eval_trends_noisy)
assert len(res_noisy["head_regressions"]) == 0, f"noise should prevent false dominance: {res_noisy}"
assert len(res_noisy["version_fronts"][0]["frontier"]) == 2

# 1b. Real HEAD regression + genuine quality/cost trade-off on frontier
eval_trends_reg = {
    "per_skill": {
        "code-review": [
            # v1: leanest cost, decent quality -> frontier
            {"harness": "claude", "skill_sha": "1111aaaa", "sha_short": "1111aaaa", "win_rate": 0.72, "noise_band": 0.05, "cost_delta_in": 500, "cost_delta_out": 100, "tool_errors_delta": 0.0, "last_recorded_at": "2026-11-01T00:00:00Z"},
            # v2: highest quality, higher cost -> frontier (trade-off vs v1)
            {"harness": "claude", "skill_sha": "2222bbbb", "sha_short": "2222bbbb", "win_rate": 0.90, "noise_band": 0.05, "cost_delta_in": 3000, "cost_delta_out": 500, "tool_errors_delta": -0.2, "last_recorded_at": "2026-11-02T00:00:00Z"},
            # v3 (HEAD): worse quality than v2 AND higher cost AND worse errors -> strictly dominated by v2!
            {"harness": "claude", "skill_sha": "3333cccc", "sha_short": "3333cccc", "win_rate": 0.65, "noise_band": 0.05, "cost_delta_in": 4000, "cost_delta_out": 800, "tool_errors_delta": 0.5, "last_recorded_at": "2026-11-03T00:00:00Z"},
        ]
    }
}
res_reg = dp.compute_pareto_analysis([], eval_trends_reg)
vf = res_reg["version_fronts"][0]
assert vf["head_regressed"] is True
assert {f["sha"] for f in vf["frontier"]} == {"1111aaaa", "2222bbbb"}
assert vf["dominated"][0]["sha"] == "3333cccc"
assert "2222bbbb" in vf["dominated"][0]["dominated_by"]
assert vf["hypervolume"] > 0.5
assert len(res_reg["head_regressions"]) == 1
assert res_reg["head_regressions"][0]["head_sha"] == "3333cccc"

# 1c. Portfolio front separates review_diagnostic from execution & identifies strictly dominated skill
skill_table = [
    {"skill": "lean-star", "mined_loads": 10, "hook_loads": 10, "forced_pct": 5.0, "estimated_context_tax_tokens": 5_000_000, "error_rate_per_session": 0.2, "redirect_interjections": 0, "eval_win_rate": 0.85, "eval_noise_band": 0.05},
    {"skill": "heavy-ace", "mined_loads": 10, "hook_loads": 10, "forced_pct": 5.0, "estimated_context_tax_tokens": 30_000_000, "error_rate_per_session": 0.1, "redirect_interjections": 0, "eval_win_rate": 0.95, "eval_noise_band": 0.05},
    {"skill": "bloated-lag", "mined_loads": 10, "hook_loads": 10, "forced_pct": 40.0, "estimated_context_tax_tokens": 40_000_000, "error_rate_per_session": 2.5, "redirect_interjections": 5, "eval_win_rate": 0.55, "eval_noise_band": 0.05},
]
res_p = dp.compute_pareto_analysis(skill_table)
pf = res_p["portfolio_fronts"][0]
assert {f["skill"] for f in pf["frontier"]} == {"lean-star", "heavy-ace"}
assert pf["dominated"][0]["skill"] == "bloated-lag"
assert "lean-star" in pf["dominated"][0]["dominated_by"]
assert pf["knee_skill"] in ("lean-star", "heavy-ace")
assert pf["hypervolume"] > 0.0
PY
echo "ok - noise-aware Pareto dominance, knee point, HEAD regression, and portfolio stratification"

# 2. End-to-end aggregate + diff (ΔHV) + SVG render proof
CACHE="${TMP}/cache"
REPORTS="${TMP}/reports"
EMPTY_LOG="${TMP}/empty.jsonl"
HIST1="${TMP}/hist1.jsonl"
HIST2="${TMP}/hist2.jsonl"
mkdir -p "${CACHE}/meta" "${CACHE}/facets"
: >"${EMPTY_LOG}"

NOW="$(python3 -B -c 'import time; print(int(time.time()))')"
python3 -B - "${CACHE}/meta" "${HIST1}" "${HIST2}" "${NOW}" <<'PY'
import json, os, sys
md, h1, h2, now = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
for i in range(6):
    for sk, sz, errs in (("lean-sk", 1000, 0), ("bloated-sk", 20000, 3)):
        sid = f"{sk[:4]}-{i:04d}"
        with open(os.path.join(md, f"claude__{sid}.json"), "w") as fh:
            json.dump({
                "meta_version": 5, "id": sid, "harness": "claude",
                "project": "/tmp/p", "workspaces": ["/tmp/p"],
                "first_ts": "2026-11-27T10:00:00Z", "last_ts": "2026-11-27T10:05:00Z",
                "first_epoch": now - 200, "last_epoch": now - 100, "source_mtime": now - 100,
                "prompts": 2, "tool_calls": 6, "errors": {"Bash": errs} if errs else {},
                "tokens_in": sz, "tokens_out": 500, "turns_after_skill_load": {sk: 4},
                "skill_loads": [sk],
            }, fh)

def rec(sha, wr, cost_in, errs, ts):
    return json.dumps({
        "kind": "ablation", "skill": "lean-sk", "harness": "claude", "skill_sha": sha,
        "win_rate": wr, "noise_band": 0.05, "pass_rate_with": wr, "cross_pairs": 10,
        "cost_delta_in": cost_in, "cost_delta_out": 0, "tool_errors_delta": errs, "recorded_at": ts,
    })

with open(h1, "w") as fh:
    fh.write(rec("1111aaaa1111aaaa", 0.70, 2000, 0.2, "2026-11-20T00:00:00Z") + "\n")
    fh.write(rec("2222bbbb2222bbbb", 0.55, 4000, 0.5, "2026-11-21T00:00:00Z") + "\n")
with open(h2, "w") as fh:
    fh.write(rec("1111aaaa1111aaaa", 0.70, 2000, 0.2, "2026-11-20T00:00:00Z") + "\n")
    fh.write(rec("3333cccc3333cccc", 0.92, 1000, 0.0, "2026-11-27T00:00:00Z") + "\n")
PY

SYN="${TMP}/syn.json"
printf '{"at_a_glance":{"working":"ok"},"narrative_paragraphs":["ok"]}\n' >"${SYN}"
AGG1="${TMP}/agg1.json"
AGG2="${TMP}/agg2.json"
HTML1="${TMP}/r1.html"
HTML2="${TMP}/r2.html"

bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${EMPTY_LOG}" --eval-history "${HIST1}" --out "${AGG1}" >/dev/null
bash "${DEBRIEF}" render --aggregate "${AGG1}" --synthesis "${SYN}" --reports-dir "${REPORTS}" --out "${HTML1}" >/dev/null
grep -q 'Pareto HEAD Regression Alert' "${HTML1}"
grep -q 'Multi-Objective Pareto Front' "${HTML1}"
grep -q 'Skill Portfolio Pareto Frontier' "${HTML1}"

bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${EMPTY_LOG}" --eval-history "${HIST2}" --reports-dir "${REPORTS}" --compare-prev --out "${AGG2}" >/dev/null
python3 -B - "${AGG2}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["pareto"]["summary"]["head_regressions_count"] == 0
hv = a["diff_from_prev"]["pareto_hv"]
assert hv["delta"] > 0, f"expected positive hypervolume delta after beating v1: {hv}"
PY
bash "${DEBRIEF}" render --aggregate "${AGG2}" --synthesis "${SYN}" --out "${HTML2}" --no-snapshot >/dev/null
grep -q 'Pareto Hypervolume' "${HTML2}"
grep -q 'HEAD ON FRONTIER' "${HTML2}"
echo "ok - end-to-end Pareto SVG, HEAD regression alert, and positive ΔHV diff verified"

echo "PASS debrief-pareto: 2 checks green"

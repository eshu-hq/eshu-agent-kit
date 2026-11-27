#!/usr/bin/env bash
# Offline suite for the Skill Quality Trends card (issue #118): aggregate
# --eval-history folds the replay-eval ledger and --evals records into
# per-(skill, harness, skill_sha) versions; render shows them as a card.
# Hermetic: temp XDG/HOME/DEBRIEF_DATA_DIR, no network.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg" HOME="${work}/home" TMPDIR="${work}/tmp"
export DEBRIEF_DATA_DIR="${work}/data"
mkdir -p "${XDG_DATA_HOME}" "${HOME}" "${TMPDIR}" "${DEBRIEF_DATA_DIR}" "${work}/cache"
: >"${work}/hooks.jsonl"

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

agg() { # <out> [aggregate args...]
	local out="$1"
	shift
	bash "${DEBRIEF}" aggregate --since 2026-11-01 --cache-dir "${work}/cache" \
		--log "${work}/hooks.jsonl" "$@" --out "${out}" >/dev/null
}

python3 -B - "${work}" <<'PYEOF'
import json, sys
work = sys.argv[1]
A, B, C, D, E, F = ("a" * 64, "b" * 64, "c" * 64, "d" * 64, "e" * 64, "f" * 64)
def rec(skill, sha, ts, win, noise=0.1, harness="claude", **extra):
    base = {"skill": skill, "harness": harness, "skill_sha": sha, "recorded_at": ts, "win_rate": win,
            "noise_band": noise, "pass_rate_with": 0.8, "cross_pairs": 5, "tool_calls_delta": 2.0,
            "tool_errors_delta": -1.0, "cost_delta_in": 10.0, "cost_delta_out": 20.0,
            "latency_delta_s": 1.5, "tool_pairs": 5, "kind": "ablation"}
    base.update(extra)
    return base
lines = [
    rec("publish", None, "2026-11-01T10:00:00+00:00", 0.4),
    rec("publish", A, "2026-11-10T10:00:00+00:00", 0.6),
    rec("publish", A, "2026-11-11T10:00:00+00:00", 0.7),
    rec("publish", A, "2026-11-11T10:00:00+00:00", 0.7),  # exact duplicate line
    rec("publish", B, "2026-11-20T10:00:00+00:00", 0.9),
    rec("publish", A, "2026-11-12T10:00:00+00:00", 0.5, harness="agy"),
    rec("publish", A, "2026-11-13T10:00:00+00:00", 0.5, harness="<b>x</b>"),
    rec("code-review", C, "2026-11-15T10:00:00+00:00", 0.5, noise=0.2),
    rec("diagnostic-rigor", D, "2026-11-15T10:00:00+00:00", 0.5, noise=0.2),
    rec("diagnostic-rigor", E, "2026-11-18T10:00:00+00:00", 0.55, noise=0.2),
    {"kind": "trigger-eval", "skill": "publish", "harness": "claude", "skill_sha": F, "recorded_at": "2026-11-19T10:00:00+00:00", "win_rate": 0.0},
]
with open(work + "/ledger.jsonl", "w") as fh:
    for ln in lines[:5]:
        fh.write(json.dumps(ln, sort_keys=True, separators=(",", ":")) + "\n")
    fh.write('{"skill": "publish", "win_ra\n')  # torn write
    fh.write("[1, 2]\n\n")  # non-object line plus a blank line
    for ln in lines[5:]:
        fh.write(json.dumps(ln, sort_keys=True, separators=(",", ":")) + "\n")
# --evals summary duplicating the code-review ledger record plus a trigger-kind record.
json.dump([lines[7], lines[-1]], open(work + "/evals-dup.json", "w"))
# 25 versions for one skill: aggregate keeps 20, the card shows 5.
with open(work + "/ledger-big.jsonl", "w") as fh:
    for i in range(25):
        fh.write(json.dumps(rec("big", format(i + 16, "02x") * 32, "2026-11-%02dT00:00:00+00:00" % (i + 1), 0.5)) + "\n")
PYEOF
SYN='{"at_a_glance":{"working":"Good","hindering":"None","quick_wins":"None","ambitious":"None"},"project_areas":[],"narrative_paragraphs":[],"key_insight":"Ok","wins_intro":"","big_wins":[],"friction_intro":"","friction_categories":[],"agents_md_additions":[],"features_to_try":[],"usage_patterns":[],"horizon_intro":"","horizon_workflows":[]}'
printf '%s' "${SYN}" >"${work}/syn.json"
render() { bash "${DEBRIEF}" render --aggregate "$1" --synthesis "${work}/syn.json" --out "$2" >/dev/null; }

# 1. Versions: ordered, one per (skill, harness, sha), runs folded, newest run shown, harnesses apart.
agg "${work}/agg.json" --eval-history "${work}/ledger.jsonl" --evals "${work}/evals-dup.json" &&
	python3 - "${work}/agg.json" <<'PYEOF' && ok "ledger folds into ordered per-sha versions; harnesses stay separate" || no "ledger folds into ordered per-sha versions; harnesses stay separate"
import json, sys
d = json.load(open(sys.argv[1]))
tr = d["eval_trends"]
pub = [v for v in tr["per_skill"]["publish"] if v["harness"] == "claude"]
assert [v["sha_short"] for v in pub] == ["unversioned", "aaaaaaaa", "bbbbbbbb"], pub
assert [v["runs"] for v in pub] == [1, 2, 1], pub
assert pub[1]["win_rate"] == 0.7 and pub[1]["last_recorded_at"].startswith("2026-11-11"), pub[1]
assert pub[1]["first_recorded_at"].startswith("2026-11-10") and pub[1]["tool_calls_delta"] == 2.0, pub[1]
assert pub[0]["skill_sha"] is None and pub[1]["skill_sha"] == "a" * 64
assert {v["harness"] for v in tr["per_skill"]["publish"]} == {"claude", "agy", "<b>x</b>"}
assert len(tr["per_skill"]["code-review"]) == 1 and tr["per_skill"]["code-review"][0]["runs"] == 1, "evals+ledger duplicate must fold"
ev = d["evals"]["per_skill"]["code-review"]
assert ev["tool_calls_delta"] == 2.0 and ev["tool_errors_delta"] == -1.0 and ev["skill_sha"] == "c" * 64, ev
PYEOF

# 2. Torn, non-object, and non-ablation lines are counted and never become versions.
python3 - "${work}/agg.json" "${work}/ledger.jsonl" <<'PYEOF' && ok "torn, non-object, and trigger-eval records count as skipped and never enter trends" || no "torn, non-object, and trigger-eval records count as skipped and never enter trends"
import json, sys
tr = json.load(open(sys.argv[1]))["eval_trends"]
assert tr["records_skipped"] == 4 and tr["records_loaded"] == 11, tr  # skipped: torn, array, 2 trigger-eval
assert sys.argv[2] in tr["sources"], tr["sources"]
assert all(v["skill_sha"] != "f" * 64 for vs in tr["per_skill"].values() for v in vs)
PYEOF

# 3. Missing explicit path fails fast; bare flag with a missing default is zero records; bare reads the default.
if agg "${work}/agg-miss.json" --eval-history "${work}/no-such-ledger.jsonl" 2>"${work}/err-miss.txt"; then
	no "explicit missing --eval-history path fails fast"
elif rg -q "no-such-ledger.jsonl.*not found" "${work}/err-miss.txt"; then
	ok "explicit missing --eval-history path fails fast"
else
	no "explicit missing --eval-history path fails fast"
fi
agg "${work}/agg-empty.json" --eval-history &&
	cp "${work}/ledger.jsonl" "${DEBRIEF_DATA_DIR}/replay-eval-history.jsonl" &&
	agg "${work}/agg-default.json" --eval-history &&
	python3 - "${work}/agg-empty.json" "${work}/agg-default.json" <<'PYEOF' && ok "bare --eval-history: missing default is empty, present default is read" || no "bare --eval-history: missing default is empty, present default is read"
import json, sys
e = json.load(open(sys.argv[1]))["eval_trends"]
assert e["records_loaded"] == 0 and e["per_skill"] == {}, e
d = json.load(open(sys.argv[2]))["eval_trends"]
assert d["per_skill"]["publish"] and d["records_loaded"] > 0, d
PYEOF

# 4. No flags: eval_trends is null and the HTML has no card.
agg "${work}/agg-none.json" && render "${work}/agg-none.json" "${work}/r-none.html" &&
	render "${work}/agg.json" "${work}/r-trends.html" && render "${work}/agg-empty.json" "${work}/r-empty.html" &&
	python3 - "${work}" <<'PYEOF' && ok "no flags omit the card; trends render versions, baseline, and noise-aware deltas" || no "no flags omit the card; trends render versions, baseline, and noise-aware deltas"
import json, re, sys
w = sys.argv[1]
assert json.load(open(w + "/agg-none.json"))["eval_trends"] is None
none = open(w + "/r-none.html", encoding="utf-8").read()
assert "Skill Quality Trends" not in none
h = open(w + "/r-trends.html", encoding="utf-8").read()
assert "Skill Quality Trends (Version History)" in h
for needle in ("aaaaaaaa", "bbbbbbbb", "baseline", "within noise", "+20 pts", "unversioned"):
    assert needle in h, needle
assert "&lt;b&gt;x&lt;/b&gt;" in h and "<b>x</b>" not in h, "harness must be HTML-escaped"
assert not re.search(r"https?://", h)
empty = open(w + "/r-empty.html", encoding="utf-8").read()
assert "Skill Quality Trends (Version History)" in empty and "No ablation records" in empty
PYEOF

# 5. Bounds: aggregate keeps 20 versions per (skill, harness); the card shows the newest 5.
agg "${work}/agg-big.json" --eval-history "${work}/ledger-big.jsonl" && render "${work}/agg-big.json" "${work}/r-big.html" &&
	python3 - "${work}" <<'PYEOF' && ok "25 versions: 20 kept in aggregate, newest 5 on the card" || no "25 versions: 20 kept in aggregate, newest 5 on the card"
import json, re, sys
w = sys.argv[1]
vs = json.load(open(w + "/agg-big.json"))["eval_trends"]["per_skill"]["big"]
assert len(vs) == 20 and vs[0]["sha_short"] == format(21, "02x") * 4 and vs[-1]["sha_short"] == format(40, "02x") * 4, [v["sha_short"] for v in vs]
h = open(w + "/r-big.html", encoding="utf-8").read()
shown = [s for s in (format(i, "02x") * 4 for i in range(16, 41)) if "<code>%s</code>" % s in h]
assert shown == [format(i, "02x") * 4 for i in range(36, 41)], shown
PYEOF

printf 'debrief-trends: %d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]

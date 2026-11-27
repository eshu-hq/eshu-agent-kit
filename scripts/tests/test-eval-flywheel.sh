#!/usr/bin/env bash
# Hermetic tests for replay-eval mix (5/80/15), from-papercut, calibrate,
# and tool-execution.json must_call_tools grading (issue #131).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPLAY="${KIT_DIR}/scripts/replay-eval.sh"
LIB="${KIT_DIR}/scripts/lib"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

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

# 1. mix combines committed golden/edge suite + mined production prompts into ~5/80/15 composition.
python3 - "${work}/mined.json" <<'PYEOF'
import json, sys
items = [
    {"id": f"prod-{i}", "category": "production", "skill": "code-review", "prompt": f"Review PR #{i} for lease bugs"}
    for i in range(1, 21)
]
json.dump(items, open(sys.argv[1], "w"))
PYEOF

if bash "${REPLAY}" mix --suite "${KIT_DIR}/evals/code-review.json" --mined "${work}/mined.json" \
	--skill code-review --target-size 20 --out "${work}/mixed.json" >"${work}/mix.out" &&
	python3 - "${work}/mixed.json" <<'PYEOF'; then
import json, sys
m = json.load(open(sys.argv[1]))
assert len(m) == 20, len(m)
cats = [x["category"] for x in m]
assert cats.count("golden") >= 1 and cats.count("edge") >= 1 and cats.count("production") >= 15, cats
PYEOF
	ok "mix produces 5/80/15 golden/production/edge composition"
else
	no "mix produces 5/80/15 golden/production/edge composition"
fi

# 2. mix warns when 0 production prompts are supplied.
if bash "${REPLAY}" mix --suite "${KIT_DIR}/evals/code-review.json" --target-size 4 --out "${work}/mix-noprod.json" |
	grep -q "WARNING: 0 production prompts"; then
	ok "mix warns when production prompts are absent"
else
	no "mix warns when production prompts are absent"
fi

# 3. from-papercut drafts both ablation edge items and trigger cases from a papercut snapshot.
cat >"${work}/papercuts.json" <<'EOF'
[
  {
    "number": 108,
    "title": "[papercut] issue-driver: docs CI runs skill-lint without ripgrep",
    "body": "skill: issue-driver\n\n## Tried\nRan docs CI on a runner without rg.\n\n## Expected\nskill-lint.sh should pass with POSIX grep -E.\n\n## Happened\nCommand failed with rg: not found.\n\n## Smallest fix\nReplace rg calls with POSIX grep -E in skill-lint.sh."
  }
]
EOF

if bash "${REPLAY}" from-papercut --papercuts "${work}/papercuts.json" --mode ablation --out "${work}/pc-abl.json" >/dev/null &&
	bash "${REPLAY}" from-papercut --papercuts "${work}/papercuts.json" --mode trigger --out "${work}/pc-trig.json" >/dev/null &&
	python3 - "${work}/pc-abl.json" "${work}/pc-trig.json" <<'PYEOF'; then
import json, sys
abl = json.load(open(sys.argv[1]))
assert len(abl) == 1 and abl[0]["id"] == "issue-driver-papercut-108" and abl[0]["category"] == "edge", abl
assert abl[0]["expectations"]["max_errors"] == 0 and abl[0]["expectations"]["must_mention"], abl
trig = json.load(open(sys.argv[2]))
assert trig["version"] == 1 and len(trig["cases"]) == 1 and trig["cases"][0]["expect"] == ["issue-driver"], trig
PYEOF
	ok "from-papercut drafts ablation edge cases and trigger cases from papercut snapshots"
else
	no "from-papercut drafts ablation edge cases and trigger cases from papercut snapshots"
fi

# 4. calibrate computes agreement against truth + derived expectations and flags verbosity bias.
cat >"${work}/verdict.json" <<'EOF'
{"comparisons":[
  {"pair_id":"p0","kind":"cross","winner":"A","rubric":{"expectations":{"A":{"passed":true},"B":{"passed":false}}}},
  {"pair_id":"p1","kind":"cross","winner":"B","rubric":{"expectations":{"A":{"passed":true},"B":{"passed":false}}}},
  {"pair_id":"p2","kind":"cross","winner":"A","rubric":{"expectations":{"A":{"passed":true},"B":{"passed":false}}}},
  {"pair_id":"p3","kind":"cross","winner":"A","rubric":{"expectations":{"A":{"passed":true},"B":{"passed":false}}}}
]}
EOF
cat >"${work}/runs.json" <<'EOF'
[
  {"pair_id":"p0","traj_a":{"transcript":"long answer with lots of text here"},"traj_b":{"transcript":"short"}},
  {"pair_id":"p1","traj_a":{"transcript":"short"},"traj_b":{"transcript":"long answer with lots of text here"}},
  {"pair_id":"p2","traj_a":{"transcript":"long answer with lots of text here"},"traj_b":{"transcript":"short"}},
  {"pair_id":"p3","traj_a":{"transcript":"long answer with lots of text here"},"traj_b":{"transcript":"short"}}
]
EOF

if bash "${REPLAY}" calibrate --verdict "${work}/verdict.json" --runs "${work}/runs.json" \
	--json-out "${work}/cal.json" >"${work}/cal.out" &&
	grep -q "WARNING: verbosity bias" "${work}/cal.out" &&
	python3 - "${work}/cal.json" <<'PYEOF'; then
import json, sys
c = json.load(open(sys.argv[1]))
assert c["compared_pairs"] == 4 and c["agreed"] == 3 and c["agreement_rate"] == 0.75, c
assert c["verbosity_bias_rate"] == 1.0 and len(c["disagreements"]) == 1, c
PYEOF
	ok "calibrate measures judge accuracy against expectations and flags verbosity bias"
else
	no "calibrate measures judge accuracy against expectations and flags verbosity bias"
fi

# 5. evals/tool-execution.json enforces non-empty must_call_tools (tool-free transcripts fail).
if python3 -B - "${LIB}" "${KIT_DIR}/evals/tool-execution.json" <<'PYEOF'; then
import json, sys
sys.path.insert(0, sys.argv[1])
from replay_judge import grade_expectations
items = json.load(open(sys.argv[2]))
assert len(items) >= 3 and all(i["expectations"].get("must_call_tools") for i in items), items
for i in items:
    no_tool = grade_expectations({"transcript": "HEAD branch clean abc1234 0 errors diff stat", "tools": [], "errors": 0}, i["expectations"])
    with_tool = grade_expectations({"transcript": "HEAD branch clean abc1234 0 errors diff stat", "tools": ["Bash"], "errors": 0}, i["expectations"])
    assert not no_tool["passed"], f"{i['id']} passed without tool calls"
    assert with_tool["passed"], f"{i['id']} failed with Bash tool call: {with_tool}"
PYEOF
	ok "tool-execution.json requires real tool calls and rejects tool-free transcripts"
else
	no "tool-execution.json requires real tool calls and rejects tool-free transcripts"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL eval-flywheel: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS eval-flywheel: %d checks green\n' "${passed}"

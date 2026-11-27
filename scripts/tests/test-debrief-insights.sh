#!/usr/bin/env bash
# Hermetic tests for /debrief repository breakdown, interjection intent classification,
# and Create/Modify/Remove skill recommendations.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1" >&2
	failed=$((failed + 1))
}

# 1. normalize_repo_name collapses worktrees, Claude paths, sandboxes, and blanks.
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "normalize_repo_name collapses worktrees and Claude paths" || no "normalize_repo_name collapses worktrees and Claude paths"
import sys
sys.path.insert(0, sys.argv[1])
from debrief_insights import normalize_repo_name

cases = [
    ("/Users/alice/personal-repos/eshu", "eshu"),
    ("/Users/alice/personal-repos/eshu-wt-102-lint", "eshu"),
    ("/Users/alice/personal-repos/eshu/.claude/worktrees/drive-1", "eshu"),
    ("-Users-alice-personal-repos-eshu", "eshu"),
    ("-Users-alice-personal-repos-eshu--claude-worktrees-drive-8855", "eshu"),
    ("-Users-alice-personal-repos-eshu--claude", "eshu"),
    ("-Users-alice-personal-repos-eshu-wt-9805", "eshu"),
    ("-Users-alice-repos-iac-eks-addons", "iac-eks-addons"),
    ("-home-dev-src-eshu-agent-kit", "eshu-agent-kit"),
    ("wf_8741b927-606", "(workflow sandbox)"),
    ("-Users-alice-Library-Application-Support-Claude-scratch-workspaces-abc", "(scratch workspace)"),
    ("", "(no repo recorded)"),
]
for raw, want in cases:
    got = normalize_repo_name(raw)
    assert got == want, f"{raw!r} -> {got!r}, want {want!r}"
PYEOF

# 2. classify_interjection categorizes all 6 follow-up intents cleanly.
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "classify_interjection classifies all 6 follow-up intent buckets" || no "classify_interjection classifies all 6 follow-up intent buckets"
import sys
sys.path.insert(0, sys.argv[1])
from debrief_common import classify_interjection

cases = [
    ("yes, go ahead", "approval"),
    ("looks good!", "approval"),
    ("stop, you forgot to follow the merge bar rule", "redirect_goal"),
    ("wait — don't skip the test suite, stick to the goal", "redirect_goal"),
    ("CI is still failing with exit code 1 and a traceback", "debugging"),
    ("why did it fail with 503?", "debugging"),
    ("what does this column mean and how does it work?", "thought_process"),
    ("should we compare those two options?", "thought_process"),
    ("also let's add a repository breakdown table next", "new_scope"),
    ("the config lives in deploy/prod.yaml", "clarification"),
]
for txt, want in cases:
    got = classify_interjection(txt)
    assert got == want, f"{txt!r} -> {got!r}, want {want!r}"
PYEOF

# 3. End-to-end prepare -> aggregate -> render across all 3 harnesses verifies repo grouping,
#    interjection_reasons (prompt #2+ only, zero raw text in meta), and Create/Modify/Remove recs.
export HOME="${work}/home"
export XDG_DATA_HOME="${work}/xdg"
mkdir -p "${HOME}/.claude/projects/-Users-alice-personal-repos-eshu" \
	"${HOME}/.claude/projects/-Users-alice-personal-repos-eshu--claude-worktrees-drive-1" \
	"${HOME}/.gemini/antigravity-cli/brain/agy-conv-1/.system_generated/logs" \
	"${XDG_DATA_HOME}/muse/sessions/muse-s1"

cat >"${HOME}/.claude/projects/-Users-alice-personal-repos-eshu/c1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-25T10:00:00Z","message":{"role":"user","content":"Review this PR"}}
{"type":"assistant","timestamp":"2026-11-25T10:00:10Z","message":{"role":"assistant","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":500,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"code-review"}}]}}
{"type":"user","timestamp":"2026-11-25T10:01:00Z","message":{"role":"user","content":"stop, you forgot to check the migration"}}
{"type":"assistant","timestamp":"2026-11-25T10:01:20Z","message":{"role":"assistant","usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":600,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Checked."}]}}
{"type":"user","timestamp":"2026-11-25T10:02:00Z","message":{"role":"user","content":"the test failed with a traceback"}}
{"type":"assistant","timestamp":"2026-11-25T10:02:30Z","message":{"role":"assistant","usage":{"input_tokens":1500,"output_tokens":400,"cache_read_input_tokens":700,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Fixed."}]}}
{"type":"user","timestamp":"2026-11-25T10:03:00Z","message":{"role":"user","content":"looks good"}}
{"type":"assistant","timestamp":"2026-11-25T10:03:10Z","message":{"role":"assistant","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Done."}]}}
EOF

cat >"${HOME}/.claude/projects/-Users-alice-personal-repos-eshu--claude-worktrees-drive-1/c2.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-25T11:00:00Z","message":{"role":"user","content":"Initial ask"}}
{"type":"assistant","timestamp":"2026-11-25T11:00:10Z","message":{"role":"assistant","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"ok"}]}}
{"type":"user","timestamp":"2026-11-25T11:01:00Z","message":{"role":"user","content":"what does this function do?"}}
{"type":"assistant","timestamp":"2026-11-25T11:01:10Z","message":{"role":"assistant","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"Explained."}]}}
EOF

cat >"${HOME}/.gemini/antigravity-cli/brain/agy-conv-1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","timestamp":"2026-11-25T12:00:00Z","text":"Open issue 99"}
{"type":"PLANNER_RESPONSE","timestamp":"2026-11-25T12:00:10Z","input_tokens":400,"output_tokens":100,"cache_read_tokens":200,"response":"Done"}
{"type":"USER_INPUT","timestamp":"2026-11-25T12:01:00Z","text":"also add a summary chart"}
{"type":"PLANNER_RESPONSE","timestamp":"2026-11-25T12:01:10Z","input_tokens":500,"output_tokens":150,"cache_read_tokens":250,"response":"Added"}
EOF

cat >"${XDG_DATA_HOME}/muse/sessions/muse-s1/session.jsonl" <<'EOF'
{"ts":"2026-11-25T13:00:00Z","stream":{"id":"muse-s1"},"payload_type":"runtime.session.metadata","payload":{"workspace_root":"/Users/alice/personal-repos/eshu-agent-kit-wt-101"}}
{"ts":"2026-11-25T13:00:01Z","stream":{"id":"muse-s1"},"payload_type":"runtime.user_intent.accepted","payload":{"text":"Fix lint"}}
{"ts":"2026-11-25T13:00:10Z","stream":{"id":"muse-s1"},"payload_type":"runtime.session","payload":{"event":{"kind":"assistant_message_committed","text":"Done"}}}
{"ts":"2026-11-25T13:01:00Z","stream":{"id":"muse-s1"},"payload_type":"runtime.user_intent.accepted","payload":{"text":"wait, remember to run tests"}}
{"ts":"2026-11-25T13:01:10Z","stream":{"id":"muse-s1"},"payload_type":"runtime.session","payload":{"event":{"kind":"assistant_message_committed","text":"Ran tests"}}}
EOF

bash "${DEBRIEF}" prepare --since 2026-11-20 --max-new 0 >/dev/null &&
	bash "${DEBRIEF}" aggregate --since 2026-11-20 --out "${work}/agg.json" >/dev/null &&
	python3 - "${work}/agg.json" <<'PYEOF' && ok "prepare + aggregate normalize repos, classify follow-ups across 3 harnesses, and build recommendations" || no "prepare + aggregate normalize repos, classify follow-ups across 3 harnesses, and build recommendations"
import json, sys
agg = json.load(open(sys.argv[1]))
repos = {r["repo"]: r for r in agg["repositories"]}
assert "eshu" in repos and repos["eshu"]["total_sessions"] == 2, repos
assert "eshu-agent-kit" in repos and repos["eshu-agent-kit"]["total_sessions"] == 1, repos
reasons = agg["charts"]["interjection_reasons"]
assert reasons.get("redirect_goal") == 2, reasons
assert reasons.get("debugging") == 1, reasons
assert reasons.get("approval") == 1, reasons
assert reasons.get("thought_process") == 1, reasons
assert reasons.get("new_scope") == 1, reasons
assert "stop, you forgot" not in json.dumps(agg), "raw prompt leaked into aggregate.json!"
recs = agg["skill_recommendations"]
assert any(r["action"] == "remove" for r in recs), recs
PYEOF

# 4. build_skill_recommendations emits create, modify, and remove actions with concrete evidence.
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "build_skill_recommendations produces Create, Modify, and Remove actions" || no "build_skill_recommendations produces Create, Modify, and Remove actions"
import sys
sys.path.insert(0, sys.argv[1])
from debrief_insights import build_skill_recommendations

skill_table = [
    {"skill": "noisy-skill", "mined_loads": 10, "hook_loads": 4, "forced_pct": 50.0, "estimated_context_tax_tokens": 60_000_000, "error_rate_per_session": 2.5, "papercut_open": 1, "redirect_interjections": 5, "eval_win_rate": None, "eval_noise_band": None, "eval_pass_rate": None},
    {"skill": "bad-eval-skill", "mined_loads": 5, "hook_loads": 0, "forced_pct": None, "estimated_context_tax_tokens": 1000, "error_rate_per_session": 0.2, "papercut_open": 0, "redirect_interjections": 0, "eval_win_rate": 0.2, "eval_noise_band": 0.1, "eval_pass_rate": 0.2},
    {"skill": "code-review", "mined_loads": 400, "hook_loads": 0, "forced_pct": None, "estimated_context_tax_tokens": 10_000_000, "error_rate_per_session": 2.1, "papercut_open": 0, "redirect_interjections": 49, "eval_win_rate": 0.5, "eval_noise_band": 1.0, "eval_pass_rate": 1.0},
]
repos = [
    {"repo": "payments-svc", "main_sessions": 20, "total_sessions": 25, "prompts": 60, "tool_calls": 400, "errors": 35, "tokens_total": 5_000_000, "unattributed_sessions": 15, "interjections": 12, "interjection_reasons": {"redirect_goal": 4, "debugging": 5}, "top_interjection_reason": "debugging", "top_skills": []},
]
skill_sizes = {"noisy-skill": 12000, "bad-eval-skill": 4000, "code-review": 9000, "dormant-skill": 6000}
recs = build_skill_recommendations(skill_table, repos, skill_sizes, {"redirect_goal": 12}, days_active=14)
acts = {(r["action"], r["target"]) for r in recs}
assert ("modify", "noisy-skill") in acts, recs
assert ("remove", "bad-eval-skill") in acts, recs
assert ("remove", "dormant-skill") in acts, recs
assert ("create", "payments-svc workflow skill") in acts, recs
assert ("create", "guardrail rule / skill for unattributed goal-redirects") in acts, recs
cr_rec = next(r for r in recs if r["target"] == "code-review")
assert "errors/session" not in cr_rec["reason"] and "goal-redirect" not in cr_rec["reason"], cr_rec
assert "judge noise" in cr_rec["reason"] and "stronger model" in cr_rec["suggestion"], cr_rec
PYEOF

# 5. HTML render includes all 3 new cards cleanly escaped.
printf '{"at_a_glance":{"working":"ok"}}' >"${work}/syn.json"
bash "${DEBRIEF}" render --aggregate "${work}/agg.json" --synthesis "${work}/syn.json" --out "${work}/out.html" >/dev/null &&
	python3 - "${work}/out.html" <<'PYEOF' && ok "render emits Activity by Repository, Why You Interjected, and Recommended Skill Actions cards" || no "render emits Activity by Repository, Why You Interjected, and Recommended Skill Actions cards"
import sys
h = open(sys.argv[1], encoding="utf-8").read()
for needle in (
    "Activity by Repository",
    "Why You Interjected (Follow-Up Intent)",
    "Recommended Skill Actions (Create / Modify / Remove)",
    "Redirecting / Re-following Goal",
    "Debugging / Fixing an Error",
    "Thinking / Design / Q&amp;A",
    "Adding Scope / Next Task",
    "Approving / Confirming",
    "eshu-agent-kit",
    "action-pill",
    "Context Bloat (Skills Stacked Per Chat)",
    "Model Mix",
):
    assert needle in h, f"missing {needle!r} in rendered HTML!"
PYEOF

# 6. session_health_stats + build_coaching_playbook flag bloated/mega/error threads and produce two-sided coaching.
python3 -B - "${KIT_DIR}/scripts/lib" <<'PYEOF' && ok "session_health_stats and build_coaching_playbook flag runaway threads and two-sided actions" || no "session_health_stats and build_coaching_playbook flag runaway threads and two-sided actions"
import sys
sys.path.insert(0, sys.argv[1])
from debrief_coaching import build_coaching_playbook, render_coaching_playbook_card, render_session_health_section, session_health_stats

metas = [
    {"id": "mega-1", "harness": "claude", "project": "-Users-a-personal-repos-eshu", "tokens_in": 600_000_000, "tokens_out": 2_000_000, "duration_minutes": 300.0, "prompts": 45, "errors": {"Bash": 25}, "skill_loads": [f"s{i}" for i in range(7)], "session_models": {"claude-sonnet": 40}},
    {"id": "small-1", "harness": "agy", "project": "/Users/a/personal-repos/eshu-agent-kit", "tokens_in": 10_000, "tokens_out": 500, "duration_minutes": 5.0, "prompts": 2, "errors": {}, "skill_loads": ["publish"], "session_models": {"gemini-flash": 4}},
]
sc = {"by_harness": {"claude": {"tokens_in": 600_000_000, "tokens_cache_read": 540_000_000, "tokens_cache_write": 30_000_000}}, "unattributed": {"sessions": 10}}
h = session_health_stats(metas, sc)
assert h["bloated_skill_sessions"] == 1 and h["mega_token_sessions"] == 1 and h["high_error_sessions"] == 1, h
assert h["cache_by_harness"]["claude"]["cache_hit_pct"] == 90.0 and h["cache_by_harness"]["claude"]["cache_write_pct"] == 5.0, h
assert h["outliers"][0]["session_id"] == "mega-1" and "7 skills stacked" in h["outliers"][0]["flags"], h

agg = {
    "meta": {"total_sessions": 20},
    "charts": {
        "interjection_reasons": {"redirect_goal": 12},
        "prompt_distribution": {"10+": 4},
        "response_time_buckets": {">15m": 15, "1-2m": 5},
        "median_response_gap_s": 180.0,
        "tool_error_categories": {"Hook Blocked": 30, "File Not Found": 25, "Edit Failed": 10, "Command Failed": 40, "Timeout": 5},
        "primary_friction_types": {"hook_or_env_retry": 12},
    },
    "skill_costs": sc,
    "repositories": [{"repo": "eshu", "unattributed_sessions": 10}],
    "skill_recommendations": [{"action": "modify", "target": "code-review", "reason": "high overhead", "suggestion": "split references/"}],
    "session_health": h,
}
pb = build_coaching_playbook(agg, h)
agg["coaching_playbook"] = pb
assert len(pb["for_you"]) >= 3 and len(pb["for_agents"]) >= 3, pb
html_pb = render_coaching_playbook_card(agg)
html_sh = render_session_health_section(agg)
assert "For You (Habits &amp; Prompting)" in html_pb and "For Your Agents (Skills, Rules &amp; Hooks)" in html_pb
assert "Runaway &amp; High-Friction Threads" in html_sh and "mega-1" in html_sh and "90.0%" in html_sh
PYEOF

printf '\ndebrief-insights: %d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]

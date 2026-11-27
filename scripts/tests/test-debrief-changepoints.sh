#!/usr/bin/env bash
# scripts/tests/test-debrief-changepoints.sh — Verify git change-point / post-edit
# attribution: prevents stale pre-fix history from firing MODIFY nags, classifies
# improved / awaiting_data / regressed skills & hooks, and honors --ignore-changepoints
# and --since-last-edit.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="${TMP}/repo"
mkdir -p "${REPO}/skills/fixed-skill" "${REPO}/skills/fresh-skill" "${REPO}/skills/still-bad" "${REPO}/hooks"
git -C "${REPO}" init -q
git -C "${REPO}" config user.email "test@example.com"
git -C "${REPO}" config user.name "Test"

printf -- '---\nname: fixed-skill\ndescription: v1\n---\n# v1\n' >"${REPO}/skills/fixed-skill/SKILL.md"
printf -- '---\nname: fresh-skill\ndescription: v1\n---\n# v1\n' >"${REPO}/skills/fresh-skill/SKILL.md"
printf -- '---\nname: still-bad\ndescription: v1\n---\n# v1\n' >"${REPO}/skills/still-bad/SKILL.md"
printf '#!/bin/bash\nexit 0\n' >"${REPO}/hooks/skill-nudge.sh"

NOW="$(python3 -B -c 'import time; print(int(time.time()))')"
T_INIT="$((NOW - 10 * 86400))"
T_EDIT="$((NOW - 2 * 86400))"

GIT_AUTHOR_DATE="${T_INIT} +0000" GIT_COMMITTER_DATE="${T_INIT} +0000" git -C "${REPO}" add -A
GIT_AUTHOR_DATE="${T_INIT} +0000" GIT_COMMITTER_DATE="${T_INIT} +0000" git -C "${REPO}" commit -q -m "initial"

# Edit all 3 skills + hooks/ at T_EDIT (2 days ago)
printf -- '---\nname: fixed-skill\ndescription: v2 fixed\n---\n# v2\n' >"${REPO}/skills/fixed-skill/SKILL.md"
printf -- '---\nname: fresh-skill\ndescription: v2 fresh\n---\n# v2\n' >"${REPO}/skills/fresh-skill/SKILL.md"
printf -- '---\nname: still-bad\ndescription: v2 still bad\n---\n# v2\n' >"${REPO}/skills/still-bad/SKILL.md"
printf '#!/bin/bash\n# improved hook\nexit 0\n' >"${REPO}/hooks/skill-nudge.sh"
GIT_AUTHOR_DATE="${T_EDIT} +0000" GIT_COMMITTER_DATE="${T_EDIT} +0000" git -C "${REPO}" add -A
GIT_AUTHOR_DATE="${T_EDIT} +0000" GIT_COMMITTER_DATE="${T_EDIT} +0000" git -C "${REPO}" commit -q -m "improve skills and hooks"

CACHE="${TMP}/cache"
EMPTY_LOG="${TMP}/empty.jsonl"
mkdir -p "${CACHE}/meta" "${CACHE}/facets"
: >"${EMPTY_LOG}"

# Seed pre-edit (5 days ago) and post-edit (1 day ago) sessions:
#  - fixed-skill: 8 pre-edit sessions (4 errs/sess, 2 hook-blocked) -> 4 post-edit sessions (0 errs/sess, 0 hook-blocked) => IMPROVED, no MODIFY!
#  - fresh-skill: 8 pre-edit sessions (4 errs/sess) -> 1 post-edit session (0 errs) => AWAITING DATA, no stale MODIFY!
#  - still-bad:   6 pre-edit sessions (3 errs/sess) -> 4 post-edit sessions (4 errs/sess) => REGRESSED/UNCHANGED, MODIFY still fires with post-edit note!
python3 -B - "${CACHE}/meta" "${T_EDIT}" <<'PY'
import json, os, sys
md, t_edit = sys.argv[1], int(sys.argv[2])
t_pre = t_edit - 3 * 86400
t_post = t_edit + 1 * 86400

def emit(sk, tag, count, ep, errs, hblk):
    for i in range(count):
        sid = f"{sk[:4]}-{tag}-{i:03d}"
        with open(os.path.join(md, f"claude__{sid}.json"), "w") as fh:
            json.dump({
                "meta_version": 5, "id": sid, "harness": "claude",
                "project": "/tmp/p", "workspaces": ["/tmp/p"],
                "first_ts": "2026-11-25T10:00:00Z", "last_ts": "2026-11-25T10:05:00Z",
                "first_epoch": ep, "last_epoch": ep + 60, "source_mtime": ep + 60,
                "prompts": 2, "tool_calls": 6,
                "errors": {"Bash": errs} if errs else {},
                "error_categories": {"Hook Blocked": hblk} if hblk else {},
                "skill_loads": [sk],
            }, fh)

emit("fixed-skill", "pre", 8, t_pre, 4, 2)
emit("fixed-skill", "post", 4, t_post, 0, 0)
emit("fresh-skill", "pre", 8, t_pre, 4, 1)
emit("fresh-skill", "post", 1, t_post, 0, 0)
emit("still-bad", "pre", 6, t_pre, 3, 0)
emit("still-bad", "post", 4, t_post, 4, 0)
PY

# Edit an unused skill AFTER all sessions — --since-last-edit must ignore never-loaded skills
mkdir -p "${REPO}/skills/unused-skill"
printf -- '---\nname: unused-skill\ndescription: never loaded\n---\n# unused\n' >"${REPO}/skills/unused-skill/SKILL.md"
T_LATER="$((NOW - 60))"
GIT_AUTHOR_DATE="${T_LATER} +0000" GIT_COMMITTER_DATE="${T_LATER} +0000" git -C "${REPO}" add -A
GIT_AUTHOR_DATE="${T_LATER} +0000" GIT_COMMITTER_DATE="${T_LATER} +0000" git -C "${REPO}" commit -q -m "touch unused skill"

# Non-edited 4-load skill with 3 errs/sess must NOT get MODIFY (full-window minimum stays 5)
python3 -B - "${CACHE}/meta" "${T_EDIT}" <<'PY'
import json, os, sys
md, t_edit = sys.argv[1], int(sys.argv[2])
t_pre = t_edit - 3 * 86400
for i in range(4):
    sid = f"uned-pre-{i:03d}"
    with open(os.path.join(md, f"claude__{sid}.json"), "w") as fh:
        json.dump({
            "meta_version": 5, "id": sid, "harness": "claude",
            "project": "/tmp/p", "workspaces": ["/tmp/p"],
            "first_ts": "2026-11-25T10:00:00Z", "last_ts": "2026-11-25T10:05:00Z",
            "first_epoch": t_pre, "last_epoch": t_pre + 60, "source_mtime": t_pre + 60,
            "prompts": 2, "tool_calls": 6, "errors": {"Bash": 3},
            "skill_loads": ["unedited-small"],
        }, fh)
PY

AGG_CP="${TMP}/agg-cp.json"
AGG_RAW="${TMP}/agg-raw.json"
AGG_POST="${TMP}/agg-post.json"
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${EMPTY_LOG}" --repo "${REPO}" --out "${AGG_CP}" >/dev/null
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${EMPTY_LOG}" --repo "${REPO}" --ignore-changepoints --out "${AGG_RAW}" >/dev/null
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${EMPTY_LOG}" --repo "${REPO}" --since-last-edit --out "${AGG_POST}" >/dev/null

python3 -B - "${AGG_CP}" "${AGG_RAW}" "${AGG_POST}" <<'PY'
import json, sys
acp = json.load(open(sys.argv[1]))
araw = json.load(open(sys.argv[2]))
apost = json.load(open(sys.argv[3]))

cp = acp["changepoints"]
assert cp["skills"]["fixed-skill"]["verdict"] == "improved", cp["skills"]["fixed-skill"]
assert cp["skills"]["fresh-skill"]["verdict"] == "awaiting_data", cp["skills"]["fresh-skill"]
assert cp["skills"]["still-bad"]["verdict"] in ("regressed", "unchanged"), cp["skills"]["still-bad"]
assert cp["hooks"]["verdict"] == "improved", cp["hooks"]

rec_targets_cp = {r["target"]: r for r in acp["skill_recommendations"]}
assert "fixed-skill" not in rec_targets_cp, f"improved skill should not get stale MODIFY: {rec_targets_cp}"
assert "fresh-skill" not in rec_targets_cp, f"recently edited skill (<3 post loads) should not get stale MODIFY: {rec_targets_cp}"
assert "still-bad" in rec_targets_cp, f"still-failing post-edit skill must stay recommended: {rec_targets_cp}"
assert "post-edit since" in rec_targets_cp["still-bad"]["reason"]
assert "Strictly Pareto-dominated in" in rec_targets_cp["still-bad"]["reason"]
assert "unedited-small" not in rec_targets_cp, f"non-edited 4-load skill must stay below 5-load floor: {rec_targets_cp}"

# --ignore-changepoints restores raw pre-edit MODIFY nags
rec_targets_raw = {r["target"] for r in araw["skill_recommendations"]}
assert "fixed-skill" in rec_targets_raw and "fresh-skill" in rec_targets_raw

# --since-last-edit restricts total sessions to the 9 post-edit sessions (ignoring unused-skill edit)
assert apost["meta"]["total_sessions"] == 9, apost["meta"]
PY
echo "ok - post-edit attribution suppresses stale MODIFY nags, tracks hooks impact, and honors flags"

SYN="${TMP}/syn.json"
HTML="${TMP}/cp.html"
printf '{"at_a_glance":{"working":"ok"},"narrative_paragraphs":["ok"]}\n' >"${SYN}"
bash "${DEBRIEF}" render --aggregate "${AGG_CP}" --synthesis "${SYN}" --out "${HTML}" --no-snapshot >/dev/null
grep -q 'Post-Edit Impact' "${HTML}"
grep -q 'IMPROVED' "${HTML}"
grep -q 'AWAITING DATA' "${HTML}"
grep -q 'hooks/' "${HTML}"
echo "ok - HTML renders Post-Edit Impact card with skill and hooks/ verdicts"

echo "PASS debrief-changepoints: 2 checks green"

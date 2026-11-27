#!/usr/bin/env bash
# scripts/tests/test-debrief-scope.sh — Verify flexible /debrief scoping:
# --current (env + CWD recency + ambiguity), --session (exact, prefix, multi,
# harness:id, auto child rollup, --no-children), --sessions-file, --all-time,
# strict --harness validation, `sessions` listing, and single-session HTML view.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBRIEF="${KIT_DIR}/scripts/debrief.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CACHE="${TMP}/cache"
META="${CACHE}/meta"
FACETS="${CACHE}/facets"
ROOT="${TMP}/transcripts"
mkdir -p "${META}" "${FACETS}" "${ROOT}"

NOW="$(python3 -B -c 'import time; print(int(time.time()))')"
OLD_EPOCH="$((NOW - 120 * 86400))"
RECENT_1="$((NOW - 120))"
RECENT_2="$((NOW - 140))"

# Seed 4 cached sessions:
#  1) claude parent (recent, matching workspace /tmp/ws-alpha) + 1 child subagent
#  2) opencode session (recent within 60s, matching /tmp/ws-alpha -> triggers ambiguity unless --harness set)
#  3) codex old session (120 days ago -> only found with --all-time or explicit --session)
#  4) muse trivial session (1 prompt, 1 tool call -> skipped normally, included when explicitly targeted)
python3 -B - "${META}" "${FACETS}" "${NOW}" "${OLD_EPOCH}" "${RECENT_1}" "${RECENT_2}" <<'PY'
import json, os, sys
meta_dir, facets_dir = sys.argv[1], sys.argv[2]
now, old_ep, rec1, rec2 = map(int, sys.argv[3:7])

def w(d, name, obj):
    with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
        json.dump(obj, fh)

w(meta_dir, "claude__sessalpha1111.json", {
    "meta_version": 5, "id": "sessalpha1111", "harness": "claude",
    "project": "/tmp/ws-alpha", "workspaces": ["/tmp/ws-alpha"],
    "first_ts": "2026-11-27T10:00:00Z", "last_ts": "2026-11-27T10:05:00Z",
    "first_epoch": rec1 - 300, "last_epoch": rec1, "source_mtime": rec1,
    "prompts": 4, "tool_calls": 12, "errors": {"Bash": 1}, "error_categories": {"Command Failed": 1},
    "skill_loads": ["code-review"], "child_sessions": ["sesschild9999"],
})
w(meta_dir, "claude__sesschild9999.json", {
    "meta_version": 5, "id": "sesschild9999", "harness": "claude",
    "project": "/tmp/ws-alpha", "workspaces": ["/tmp/ws-alpha"],
    "parent_session": "sessalpha1111",
    "first_ts": "2026-11-27T10:01:00Z", "last_ts": "2026-11-27T10:03:00Z",
    "first_epoch": rec1 - 240, "last_epoch": rec1 - 60, "source_mtime": rec1 - 60,
    "prompts": 1, "tool_calls": 5, "errors": {}, "skill_loads": [],
})
w(meta_dir, "opencode__sessbeta2222.json", {
    "meta_version": 5, "id": "sessbeta2222", "harness": "opencode",
    "project": "/tmp/ws-alpha", "workspaces": ["/tmp/ws-alpha"],
    "first_ts": "2026-11-27T10:00:00Z", "last_ts": "2026-11-27T10:04:00Z",
    "first_epoch": rec2 - 200, "last_epoch": rec2, "source_mtime": rec2,
    "prompts": 3, "tool_calls": 8, "errors": {}, "skill_loads": ["golang-engineering"],
})
w(meta_dir, "codex__sessold3333.json", {
    "meta_version": 5, "id": "sessold3333", "harness": "codex",
    "project": "/tmp/ws-old", "workspaces": ["/tmp/ws-old"],
    "first_ts": "2026-07-01T10:00:00Z", "last_ts": "2026-07-01T10:10:00Z",
    "first_epoch": old_ep, "last_epoch": old_ep, "source_mtime": old_ep,
    "prompts": 5, "tool_calls": 9, "errors": {}, "skill_loads": ["postgres-rigor"],
})
w(meta_dir, "muse__sesstriv4444.json", {
    "meta_version": 5, "id": "sesstriv4444", "harness": "muse",
    "project": "/tmp/ws-muse", "workspaces": ["/tmp/ws-muse"],
    "first_ts": "2026-11-27T09:00:00Z", "last_ts": "2026-11-27T09:01:00Z",
    "first_epoch": now - 3600, "last_epoch": now - 3600, "source_mtime": now - 3600,
    "prompts": 1, "tool_calls": 1, "errors": {}, "skill_loads": [],
})
w(facets_dir, "claude__sessalpha1111.json", {
    "session_id": "sessalpha1111", "harness": "claude", "source_mtime": rec1,
    "underlying_goal": "Verify single-session deep-dive rendering",
    "goal_categories": {"testing_and_verification": 1},
    "outcome": "fully_achieved", "satisfaction": "satisfied",
    "friction_counts": {}, "friction_detail": "",
    "primary_success": "good_debugging", "session_type": "single_task",
    "brief_summary": "Completed scoped review cleanly.",
})
PY

# Hook log with events for both sessalpha1111 and an unrelated session
LOG="${TMP}/usage.jsonl"
cat >"${LOG}" <<'EOF'
{"detail":{"skill":"code-review"},"harness":"claude","session":"sessalpha111","ts":"2026-11-27T10:02:00+00:00","type":"skill-load"}
{"detail":{"skill":"postgres-rigor"},"harness":"claude","session":"unrelated999","ts":"2026-11-27T10:02:00+00:00","type":"skill-load"}
EOF

# 1. Strict --harness rejects invalid names (including alongside 'all') with exit 2
for bad_h in bogus "all,bogus" "muse,typo"; do
	set +e
	bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --harness "${bad_h}" >/dev/null 2>&1
	rc=$?
	set -e
	[ "${rc}" -eq 2 ] || {
		echo "FAIL: invalid --harness '${bad_h}' exited ${rc}, expected 2" >&2
		exit 1
	}
done
echo "ok - invalid --harness (including all,bogus) exits 2"

# 2. --all-time cannot be combined with --days
set +e
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --all-time --days 7 >/dev/null 2>&1
rc=$?
set -e
[ "${rc}" -eq 2 ] || {
	echo "FAIL: --all-time --days exited ${rc}, expected 2" >&2
	exit 1
}
echo "ok - --all-time rejects --days with exit 2"

# 3. --all-time includes 120-day-old codex session; default 30d omits it
AGG_30="${TMP}/agg30.json"
AGG_ALL="${TMP}/aggall.json"
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --out "${AGG_30}" >/dev/null
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --all-time --out "${AGG_ALL}" >/dev/null
python3 -B - "${AGG_30}" "${AGG_ALL}" <<'PY'
import json, sys
a30 = json.load(open(sys.argv[1]))
aall = json.load(open(sys.argv[2]))
assert "codex" not in a30["by_harness"], f"30d should omit 120d codex: {a30['by_harness']}"
assert aall["by_harness"]["codex"]["sessions"] == 1
assert aall["meta"]["scope"]["all_time"] is True
PY
echo "ok - --all-time surfaces older sessions while default 30d filters them"

# 4. --session exact/prefix pulls in linked child subagent + filters hook log + finds old session without --all-time
AGG_ONE="${TMP}/agg1.json"
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --session sessalpha11 --out "${AGG_ONE}" >/dev/null
python3 -B - "${AGG_ONE}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["meta"]["top_level_sessions"] == 1, a["meta"]
assert a["meta"]["child_sessions"] == 1, a["meta"]
assert a["meta"]["total_sessions"] == 2, a["meta"]
assert a["meta"]["scope"]["mode"] == "session"
assert a["meta"]["scope"]["session_ids"] == ["sessalpha1111"]
skills = {r["skill"]: r["hook_loads"] for r in a["skill_table"]}
assert skills.get("code-review") == 1, skills
assert "postgres-rigor" not in skills, f"unrelated hook event leaked: {skills}"
PY
echo "ok - --session prefix auto-includes child subagent and scopes hook events"

# 5. --no-children excludes child subagent; --sessions-file loads multiple explicit IDs including old codex session
SFILE="${TMP}/sids.txt"
printf '# comment\nclaude:sessalpha1111\ncodex:sessold3333\n' >"${SFILE}"
AGG_MULTI="${TMP}/aggm.json"
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --sessions-file "${SFILE}" --no-children --out "${AGG_MULTI}" >/dev/null
python3 -B - "${AGG_MULTI}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["meta"]["total_sessions"] == 2, a["meta"]
assert a["meta"]["child_sessions"] == 0, a["meta"]
assert a["meta"]["scope"]["mode"] == "sessions"
assert sorted(a["meta"]["scope"]["session_ids"]) == ["sessalpha1111", "sessold3333"]
PY
echo "ok - --sessions-file and --no-children scope cleanly across harnesses and ages"

# 5b. One valid + one missing --session warns on stderr and records missing_sessions
PARTIAL_ERR="${TMP}/partial.stderr"
PARTIAL_OUT="${TMP}/partial.json"
bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --session sessalpha1111 --session typo-missing-999 --out "${PARTIAL_OUT}" >/dev/null 2>"${PARTIAL_ERR}"
grep -q 'typo-missing-999' "${PARTIAL_ERR}"
python3 -B - "${PARTIAL_OUT}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["meta"]["scope"]["missing_sessions"] == ["typo-missing-999"]
PY
echo "ok - partial --session miss warns on stderr and records missing_sessions"

# 6. --current env var resolves cleanly; CWD ambiguity fails with exit 2; --harness disambiguates CWD
AGG_CUR_ENV="${TMP}/agg-cur-env.json"
CLAUDE_SESSION_ID="sessalpha1111" bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --current --out "${AGG_CUR_ENV}" >/dev/null
python3 -B - "${AGG_CUR_ENV}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["meta"]["scope"]["session_ids"] == ["sessalpha1111"]
PY

set +e
env -u CLAUDE_SESSION_ID -u MUSE_SESSION_ID -u OPENCODE_SESSION_ID -u CODEX_THREAD_ID -u AGY_CONVERSATION_ID -u CONVERSATION_ID \
	bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --current --current-cwd /tmp/ws-alpha >/dev/null 2>&1
rc=$?
set -e
[ "${rc}" -eq 2 ] || {
	echo "FAIL: ambiguous --current exited ${rc}, expected 2" >&2
	exit 1
}

AGG_CUR_OC="${TMP}/agg-cur-oc.json"
env -u CLAUDE_SESSION_ID -u MUSE_SESSION_ID -u OPENCODE_SESSION_ID -u CODEX_THREAD_ID -u AGY_CONVERSATION_ID -u CONVERSATION_ID \
	bash "${DEBRIEF}" aggregate --cache-dir "${CACHE}" --log "${LOG}" --current --current-cwd /tmp/ws-alpha --harness opencode --out "${AGG_CUR_OC}" >/dev/null
python3 -B - "${AGG_CUR_OC}" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["meta"]["scope"]["session_ids"] == ["sessbeta2222"]
PY
echo "ok - --current env resolution, CWD ambiguity guard, and --harness disambiguation"

# 7. Single-session HTML render shows Session Deep-Dive banner
SYN="${TMP}/syn.json"
printf '{"at_a_glance":{"working":"ok"},"narrative_paragraphs":["done"]}\n' >"${SYN}"
HTML_OUT="${TMP}/one.html"
bash "${DEBRIEF}" render --aggregate "${AGG_ONE}" --synthesis "${SYN}" --out "${HTML_OUT}" >/dev/null
grep -q 'Session Deep-Dive' "${HTML_OUT}"
grep -q 'sessalpha1111' "${HTML_OUT}"
echo "ok - single-session HTML report renders Session Deep-Dive banner"

echo "PASS debrief-scope: 7 checks green"

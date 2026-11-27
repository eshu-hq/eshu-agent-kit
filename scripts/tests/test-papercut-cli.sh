#!/usr/bin/env bash
# Behavioral suite for scripts/file-papercut.sh (#101).
# Runs fully offline using --dry-run, --dedupe-file, and a temp fake `gh`
# shim in PATH. Proves snapshot field-contract enforcement for standalone debrief ingestion.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${KIT_DIR}/scripts/file-papercut.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export XDG_DATA_HOME="${work}/xdg"
export HOME="${work}/home"
export TMPDIR="${work}/tmp"
mkdir -p "${XDG_DATA_HOME}" "${HOME}" "${TMPDIR}" "${work}/bin"

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

# Fake gh shim that records every argv invocation as JSONL and serves fixtures.
cat >"${work}/bin/gh" <<'GHEOF'
#!/usr/bin/env python3
import json, os, sys

log_path = os.environ.get("FAKE_GH_LOG", "")
if log_path:
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(sys.argv[1:]) + "\n")

args = sys.argv[1:]
if len(args) >= 2 and args[0] == "issue" and args[1] == "list":
    if os.environ.get("FAKE_GH_BAD_JSON") == "1":
        sys.stdout.write("{not valid json\n")
        sys.exit(0)
    src = os.environ.get("FAKE_GH_LIST_FILE", "")
    if src and os.path.exists(src):
        with open(src, encoding="utf-8") as fh:
            sys.stdout.write(fh.read())
    else:
        sys.stdout.write("[]\n")
    sys.exit(0)
if len(args) >= 2 and args[0] == "issue" and args[1] == "create":
    sys.stdout.write("https://github.com/eshu-hq/eshu-agent-kit/issues/999\n")
    sys.exit(0)
if len(args) >= 2 and args[0] == "issue" and args[1] == "comment":
    sys.stdout.write(f"https://github.com/eshu-hq/eshu-agent-kit/issues/{args[2]}#issuecomment-1\n")
    sys.exit(0)
sys.stderr.write(f"fake gh: unexpected args: {args}\n")
sys.exit(1)
GHEOF
chmod +x "${work}/bin/gh"

# 1. Missing required flags fail fast with exit 2.
out="$(bash "${CLI}" file --skill debrief --tried "ran it" 2>&1)"
rc=$?
if [ "${rc}" -eq 2 ] && printf '%s' "${out}" | grep -q -- '--expected' &&
	printf '%s' "${out}" | grep -q -- '--happened' &&
	printf '%s' "${out}" | grep -q -- '--fix'; then
	ok "missing required file flags exit 2 with clear stderr"
else
	no "missing required file flags exit 2 with clear stderr (rc=${rc}: ${out})"
fi

out="$(bash "${CLI}" file --skill "..." --tried "a" --expected "b" --happened "c" --fix "d" 2>&1)"
rc=$?
if [ "${rc}" -eq 2 ]; then
	ok "punctuation-only --skill exits 2"
else
	no "punctuation-only --skill exits 2 (rc=${rc}: ${out})"
fi

out="$(bash "${CLI}" snapshot 2>&1)"
rc=$?
if [ "${rc}" -eq 2 ]; then
	ok "snapshot without --out exits 2"
else
	no "snapshot without --out exits 2 (rc=${rc}: ${out})"
fi

if bash "${CLI}" --help >/dev/null 2>&1; then
	ok "--help exits 0"
else
	no "--help exits 0"
fi

# 2. --dry-run --no-dedupe canonicalizes skill and emits 4 sections + [papercut] title.
dry_out="$(bash "${CLI}" file \
	--skill "eshu-agent-kit:eshu-debrief." \
	--title "[papercut] gap table off by one" \
	--tried "Ran aggregate on zero sessions." \
	--expected "Empty valid report." \
	--happened "Exited 1 on missing field." \
	--fix "Default optional field to 0." \
	--repo "eshu-hq/eshu-agent-kit" \
	--dry-run --no-dedupe 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && python3 - "${dry_out}" <<'PYEOF'; then
import sys
out = sys.argv[1]
assert "title: [papercut] debrief: gap table off by one\n" in out, out
assert "[papercut] [papercut]" not in out, out
assert "labels: papercut\n" in out, out
assert "\nskill: debrief\n" in out, out
for hdr in (
    "### What the agent tried",
    "### What was expected",
    "### What happened instead",
    "### What would fix it",
):
    assert hdr in out, (hdr, out)
PYEOF
	ok "dry-run canonicalizes eshu-agent-kit:eshu-debrief. and formats title + 4 sections"
else
	no "dry-run canonicalizes eshu-agent-kit:eshu-debrief. and formats title + 4 sections (rc=${rc})"
fi

# 3. --dedupe-file catches open same-skill duplicate, ignores closed/other-skill issues.
cat >"${work}/open-issues.json" <<'EOF'
[
  {"number": 41, "title": "[papercut] debrief: stale facet cache", "state": "CLOSED",
   "body": "skill: debrief\n\n### What the agent tried\nOld."},
  {"number": 42, "title": "[papercut] issue-driver: gap table off by one", "state": "OPEN",
   "body": "skill: issue-driver\n\n### What the agent tried\nOther skill."},
  {"number": 43, "title": "[papercut] debrief: gap table off by one", "state": "OPEN",
   "body": "skill: eshu-agent-kit:debrief\n\n### What the agent tried\nHit off-by-one."}
]
EOF

dup_out="$(bash "${CLI}" file \
	--skill "debrief" \
	--title "gap table off-by-one bucket" \
	--tried "Ran aggregate." \
	--expected "Exact bucket." \
	--happened "Bucket off by one." \
	--fix "Fix boundary." \
	--dedupe-file "${work}/open-issues.json" \
	--dry-run 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${dup_out}" | grep -q '^duplicate: #43 '; then
	ok "--dedupe-file matches open same-skill duplicate #43"
else
	no "--dedupe-file matches open same-skill duplicate #43 (rc=${rc}: ${dup_out})"
fi

reopen_out="$(bash "${CLI}" file \
	--skill "debrief" \
	--title "stale facet cache" \
	--tried "Ran prepare." \
	--expected "Fresh facet." \
	--happened "Stale cache used." \
	--fix "Invalidate cache." \
	--dedupe-file "${work}/open-issues.json" \
	--dry-run 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${reopen_out}" | grep -q '^title: \[papercut\] debrief: stale facet cache$'; then
	ok "--dedupe-file ignores CLOSED issue #41 so regressions can be filed"
else
	no "--dedupe-file ignores CLOSED issue #41 so regressions can be filed (rc=${rc}: ${reopen_out})"
fi

# 4. Live file with fake gh creates issue when no duplicate, comments when duplicate matches.
gh_log="${work}/gh-create.jsonl"
printf '[]\n' >"${work}/empty.json"
create_out="$(PATH="${work}/bin:${PATH}" FAKE_GH_LOG="${gh_log}" FAKE_GH_LIST_FILE="${work}/empty.json" \
	bash "${CLI}" file \
	--skill "eshu-issue-driver" \
	--title "claim comment missing" \
	--tried "Started drive." \
	--expected "Prompted to post claim." \
	--happened "Skipped claim check." \
	--fix "Enforce claim check." \
	--repo "eshu-hq/eshu-agent-kit" 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && python3 - "${gh_log}" <<'PYEOF'; then
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(calls) == 2, calls
assert calls[0][:2] == ["issue", "list"] and "--label" in calls[0] and "papercut" in calls[0], calls[0]
c = calls[1]
assert c[:2] == ["issue", "create"], c
assert "--label" in c and c[c.index("--label") + 1] == "papercut", c
assert c[c.index("--title") + 1] == "[papercut] issue-driver: claim comment missing", c
body = c[c.index("--body") + 1]
assert body.startswith("skill: issue-driver\n"), body
PYEOF
	ok "live file calls gh issue create --label papercut with canonical skill: body"
else
	no "live file calls gh issue create --label papercut with canonical skill: body (rc=${rc}: ${create_out})"
fi

gh_dup_log="${work}/gh-comment.jsonl"
comment_out="$(PATH="${work}/bin:${PATH}" FAKE_GH_LOG="${gh_dup_log}" FAKE_GH_LIST_FILE="${work}/open-issues.json" \
	bash "${CLI}" file \
	--skill "debrief" \
	--title "gap table off by one" \
	--tried "Ran aggregate again." \
	--expected "Accurate gap table." \
	--happened "Still off by one." \
	--fix "Fix upper bound." \
	--repo "eshu-hq/eshu-agent-kit" 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${comment_out}" | grep -q '#43' && python3 - "${gh_dup_log}" <<'PYEOF'; then
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(calls) == 2, calls
assert calls[0][:2] == ["issue", "list"], calls[0]
assert calls[1][:3] == ["issue", "comment", "43"], calls[1]
assert "skill: debrief\n" in calls[1][calls[1].index("--body") + 1], calls[1]
PYEOF
	ok "live file comments on duplicate #43 instead of creating a second issue"
else
	no "live file comments on duplicate #43 instead of creating a second issue (rc=${rc}: ${comment_out})"
fi

# 5. snapshot --out writes atomic JSON with required fields for standalone debrief ingestion.
cat >"${work}/gh-snapshot-fixture.json" <<'EOF'
[
  {"number": 201, "title": "[papercut] debrief: gap table off by one", "state": "OPEN", "stateReason": null,
   "body": "skill: debrief\n\n### What the agent tried\nRan aggregate.\n\n### What was expected\nZeroed table.\n\n### What happened instead\nOff by one.\n\n### What would fix it\nAdjust bucket."},
  {"number": 202, "title": "[papercut] debrief: stale facet", "state": "CLOSED", "stateReason": "COMPLETED",
   "body": "skill: debrief\n\n### What the agent tried\nRan prepare.\n\n### What was expected\nFresh facet.\n\n### What happened instead\nStale cache.\n\n### What would fix it\nRefresh cache."},
  {"number": 203, "title": "[papercut] issue-driver: duplicate filed", "state": "CLOSED", "stateReason": "NOT_PLANNED",
   "body": "skill: issue-driver\n\n### What the agent tried\nFiled issue.\n\n### What was expected\nDeduped.\n\n### What happened instead\nDuplicated.\n\n### What would fix it\nDedupe."}
]
EOF

snap_file="${work}/out/papercuts-snapshot.json"
snap_log="${work}/gh-snap.jsonl"
snap_out="$(PATH="${work}/bin:${PATH}" FAKE_GH_LOG="${snap_log}" FAKE_GH_LIST_FILE="${work}/gh-snapshot-fixture.json" \
	bash "${CLI}" snapshot --out "${snap_file}" --repo "eshu-hq/eshu-agent-kit" --limit 50 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ] && [ -f "${snap_file}" ] && python3 - "${snap_log}" "${snap_file}" <<'PYEOF'; then
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(calls) == 1 and calls[0][:2] == ["issue", "list"], calls
assert "--state" in calls[0] and calls[0][calls[0].index("--state") + 1] == "all", calls[0]
assert calls[0][calls[0].index("--limit") + 1] == "50", calls[0]
assert calls[0][calls[0].index("--json") + 1] == "number,title,body,state,stateReason", calls[0]
data = json.load(open(sys.argv[2], encoding="utf-8"))
assert isinstance(data, list) and len(data) == 3, data
PYEOF
	ok "snapshot --out writes valid JSON array from gh issue list"
else
	no "snapshot --out writes valid JSON array from gh issue list (rc=${rc}: ${snap_out})"
fi

# Atomic guard: malformed gh output must not clobber existing snapshot file.
if PATH="${work}/bin:${PATH}" FAKE_GH_BAD_JSON=1 \
	bash "${CLI}" snapshot --out "${snap_file}" --repo "eshu-hq/eshu-agent-kit" >/dev/null 2>&1; then
	no "snapshot rejects invalid JSON without overwriting target"
else
	if python3 -c 'import json, sys; assert len(json.load(open(sys.argv[1]))) == 3' "${snap_file}"; then
		ok "snapshot rejects invalid JSON without overwriting target"
	else
		no "snapshot corrupted existing file on invalid JSON"
	fi
fi

# Field-contract check: derive expected fields from the captured gh --json argv and confirm
# cmd_snapshot rejects a gh payload missing stateReason without overwriting the existing snapshot.
cat >"${work}/gh-snapshot-missing-field.json" <<'EOF'
[
  {"number": 204, "title": "[papercut] publish: incomplete row", "state": "CLOSED", "body": "skill: publish\nmissing stateReason"}
]
EOF
if python3 - "${snap_log}" "${snap_file}" <<'PYEOF' &&
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
req_fields = set(calls[0][calls[0].index("--json") + 1].split(","))
assert req_fields == {"number", "title", "body", "state", "stateReason"}, req_fields
rows = json.load(open(sys.argv[2], encoding="utf-8"))
assert len(rows) == 3 and all(req_fields <= set(r) for r in rows), rows
PYEOF
	! PATH="${work}/bin:${PATH}" FAKE_GH_LIST_FILE="${work}/gh-snapshot-missing-field.json" \
		bash "${CLI}" snapshot --out "${snap_file}" --repo "eshu-hq/eshu-agent-kit" >/dev/null 2>"${work}/snap-miss.err" &&
	grep -q "stateReason" "${work}/snap-miss.err" &&
	python3 -c 'import json, sys; assert len(json.load(open(sys.argv[1]))) == 3' "${snap_file}"; then
	ok "snapshot enforces required gh --json field contract and rejects rows missing stateReason"
else
	no "snapshot enforces required gh --json field contract and rejects rows missing stateReason"
fi

# 6. Regression coverage for review findings F1, F5, F6, F7.
# F1: generic-word-only overlap (e.g. "missing error") must NOT falsely dedupe.
cat >"${work}/generic-issues.json" <<'EOF'
[
  {"number": 51, "title": "[papercut] debrief: missing error on bad date", "state": "OPEN", "body": "skill: debrief\nold"},
  {"number": true, "title": "[papercut] debrief: cache collision", "state": "OPEN", "body": "skill: debrief\nbool num"},
  {"number": "#99", "title": "[papercut] debrief: cache collision", "state": "OPEN", "body": "skill: debrief\nstr num"},
  {"number": -1, "title": "[papercut] debrief: cache collision", "state": "OPEN", "body": "skill: debrief\nneg num"}
]
EOF
gen_out="$(bash "${CLI}" file --skill debrief --title "missing error on empty cache" \
	--tried "Ran aggregate." --expected "Clean output." --happened "Errored." --fix "Handle empty." \
	--dry-run --dedupe-file "${work}/generic-issues.json" 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${gen_out}" | grep -q '^title: \[papercut\] debrief: missing error on empty cache$'; then
	ok "generic-word-only overlap does not falsely dedupe (F1)"
else
	no "generic-word-only overlap does not falsely dedupe (rc=${rc}: ${gen_out})"
fi

# F5: bool, non-numeric, and negative issue numbers are ignored without crash.
badnum_out="$(bash "${CLI}" file --skill debrief --title "cache collision" \
	--tried "Ran prepare." --expected "Clean cache." --happened "Collision." --fix "Key by mtime." \
	--dry-run --dedupe-file "${work}/generic-issues.json" 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${badnum_out}" | grep -q '^title: \[papercut\] debrief: cache collision$'; then
	ok "invalid issue numbers (bool, string, negative) are safely ignored (F5)"
else
	no "invalid issue numbers (bool, string, negative) are safely ignored (rc=${rc}: ${badnum_out})"
fi

# F6: detect_repo matches authenticated HTTPS origin with trailing slash.
authrepo="${work}/auth-origin"
git init -qb main "${authrepo}"
git -C "${authrepo}" remote add origin "https://x-access-token:secret@github.com/acme/demo-kit.git/"
repo_out="$(cd "${authrepo}" && bash "${CLI}" file --skill debrief \
	--tried "Ran \`cmd\` with \$(uname) and \"quotes\"" --expected "No injection" \
	--happened $'First line fallback title\nskill: other-skill' --fix "Escape safely" \
	--dry-run --no-dedupe 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -eq 0 ] &&
	printf '%s' "${repo_out}" | grep -q '^repo: acme/demo-kit$' &&
	printf '%s' "${repo_out}" | grep -q '^title: \[papercut\] debrief: First line fallback title$' &&
	printf '%s' "${repo_out}" | grep -qF '$(uname)'; then
	ok "authenticated HTTPS origin, omitted --title fallback, and metacharacters stay safe (F6/F7)"
else
	no "authenticated HTTPS origin, omitted --title fallback, and metacharacters stay safe (rc=${rc}: ${repo_out})"
fi

# F7: invalid --limit, malformed --dedupe-file, and gh failure fail cleanly.
if bash "${CLI}" snapshot --out "${work}/x.json" --limit 0 >/dev/null 2>&1; then
	no "snapshot rejects --limit 0"
else
	ok "snapshot rejects --limit 0"
fi
printf '{not json' >"${work}/bad.json"
if bash "${CLI}" file --skill debrief --tried a --expected b --happened c --fix d --dry-run --dedupe-file "${work}/bad.json" >/dev/null 2>&1; then
	no "file rejects malformed --dedupe-file"
else
	ok "file rejects malformed --dedupe-file"
fi
nogh_bin="${work}/nogh-bin"
mkdir -p "${nogh_bin}"
ln -s "$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')" "${nogh_bin}/python3"
ln -s "$(command -v dirname)" "${nogh_bin}/dirname"
ln -s "$(command -v bash)" "${nogh_bin}/bash"
nogh_out="$(PATH="${nogh_bin}" "${nogh_bin}/bash" "${CLI}" snapshot --out "${work}/no-gh.json" --repo "eshu-hq/eshu-agent-kit" 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${nogh_out}" | grep -q 'gh CLI not found'; then
	ok "snapshot fails cleanly when gh is unavailable"
else
	no "snapshot fails cleanly when gh is unavailable (rc=${rc}: ${nogh_out})"
fi

printf '\npapercut-cli: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

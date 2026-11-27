#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# review-context.sh - Code Mode packet collector for code-review (#132).
# Emits branch base/head, diff stats, risk/proof-tier classification of changed
# paths, and optional --pr N live GitHub checks + unresolved thread count.
#
# Usage: bash review-context.sh [--base <ref>] [--pr <number>] [--json]
set -euo pipefail

base=""
pr=""
json_mode=0

usage() {
	cat >&2 <<'EOF'
Usage: bash review-context.sh [--base <ref>] [--pr <number>] [--json]
EOF
}

while (($# > 0)); do
	case "$1" in
	--base)
		base="${2:?--base needs a git ref}"
		shift 2
		;;
	--pr)
		pr="${2:?--pr needs a PR number}"
		shift 2
		;;
	--json)
		json_mode=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "review-context: unknown option: $1" >&2
		usage
		exit 2
		;;
	esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "review-context: not inside a git repository" >&2
	exit 1
}
cd "${repo_root}"

if [ -z "${base}" ]; then
	if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
		base="origin/main"
	elif git rev-parse --verify -q main >/dev/null 2>&1; then
		base="main"
	else
		base="HEAD~1"
	fi
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
head_sha="$(git rev-parse HEAD)"
base_sha="$(git rev-parse "${base}" 2>/dev/null || true)"
if [ -z "${base_sha}" ]; then
	echo "review-context: cannot resolve --base '${base}'" >&2
	exit 1
fi
merge_base="$(git merge-base "${base_sha}" "${head_sha}" 2>/dev/null || echo "${base_sha}")"
changed_files="$(git diff --name-only "${merge_base}..${head_sha}")"
numstat="$(git diff --numstat "${merge_base}..${head_sha}")"
dirty_count="$(git status --porcelain | wc -l | tr -d ' ')"

pr_json=""
if [ -n "${pr}" ]; then
	if ! command -v gh >/dev/null 2>&1; then
		echo "review-context: gh CLI is required for --pr" >&2
		exit 1
	fi
	if ! pr_json="$(gh pr view "${pr}" --json number,state,url,headRefOid,baseRefName,mergeStateStatus,statusCheckRollup,reviewDecision)"; then
		echo "review-context: failed to query PR #${pr} via gh" >&2
		exit 1
	fi
fi

RC_FILES="${changed_files}" RC_NUMSTAT="${numstat}" RC_PR="${pr_json}" \
	python3 - "${branch}" "${head_sha}" "${base}" "${merge_base}" "${dirty_count}" "${json_mode}" "${pr}" <<'PYEOF'
import json, os, re, sys

branch, head_sha, base_ref, merge_base, dirty_s, json_mode_s, pr_num = sys.argv[1:8]
part_files = os.environ.get("RC_FILES", "")
part_numstat = os.environ.get("RC_NUMSTAT", "")
part_pr = os.environ.get("RC_PR", "")

files = [f.strip() for f in part_files.splitlines() if f.strip()]
added = deleted = 0
for line in part_numstat.splitlines():
    cols = line.split("\t")
    if len(cols) >= 3:
        if cols[0].isdigit():
            added += int(cols[0])
        if cols[1].isdigit():
            deleted += int(cols[1])

SURFACE_RULES = [
    ("reducer_projector", r"(?:^|/)internal/(?:reducer|projector)/", "correlation-truth + graph proof"),
    ("queue_storage_sql", r"(?:^|/)(?:internal/queue/|storage/postgres/|migrations/)|\.sql$", "postgres-rigor + live DB proof"),
    ("query_cypher", r"(?:^|/)internal/query/|\.cypher$", "cypher-query-rigor + query proof"),
    ("contracts_sdk", r"(?:^|/)sdk/go/|fact-kind-registry", "contract-rigor + factschema diff"),
    ("telemetry", r"(?:^|/)(?:internal/telemetry/|observability/)", "telemetry-coverage-discipline"),
    ("hooks_gates", r"(?:^|/)(?:hooks/|scripts/(?:skill-lint|run-tests|check-)|\.github/)", "shellcheck + hermetic hook/gate tests"),
    ("skills_agents", r"(?:^|/)(?:skills/|agents/|AGENTS\.md$)", "skill-lint + content parity"),
    ("go_code", r"\.go$", "golang-engineering + focused go test"),
    ("docs", r"\.md$", "md-links + process-wording review"),
]

surfaces = {}
for f in files:
    matched = False
    for name, pat, proof in SURFACE_RULES:
        if re.search(pat, f):
            entry = surfaces.setdefault(name, {"proof": proof, "files": []})
            entry["files"].append(f)
            matched = True
    if not matched:
        surfaces.setdefault("other", {"proof": "focused unit/integration test", "files": []})["files"].append(f)

pr_data = None
if part_pr.strip():
    try:
        p = json.loads(part_pr)
        checks = p.get("statusCheckRollup") or []
        passed = sum(1 for c in checks if (c.get("conclusion") or "").upper() in ("SUCCESS", "NEUTRAL", "SKIPPED"))
        failed = [c.get("name") for c in checks if (c.get("conclusion") or "").upper() in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED")]
        pending = [c.get("name") for c in checks if (c.get("status") or "").upper() != "COMPLETED"]
        pr_data = {
            "number": p.get("number"), "state": p.get("state"),
            "head_matches_local": (p.get("headRefOid") == head_sha),
            "merge_state": p.get("mergeStateStatus"), "review_decision": p.get("reviewDecision"),
            "checks_passed": passed, "checks_failed": failed, "checks_pending": pending,
        }
    except ValueError:
        pr_data = {"error": "could not parse gh pr view output"}

doc = {
    "branch": branch, "head_sha": head_sha, "base_ref": base_ref, "merge_base": merge_base,
    "dirty_worktree_entries": int(dirty_s),
    "files_changed": len(files), "lines_added": added, "lines_deleted": deleted,
    "files": files, "surfaces": surfaces, "pr": pr_data,
}

if json_mode_s == "1":
    print(json.dumps(doc, indent=2, sort_keys=True))
else:
    print(f"review-context: branch={branch} head={head_sha[:10]} base={base_ref} ({merge_base[:10]})")
    print(f"diff: {len(files)} files (+{added}/-{deleted}), dirty={dirty_s}")
    print("surfaces:")
    for name, info in sorted(surfaces.items()):
        print(f"  - {name} ({len(info['files'])} files): {info['proof']}")
    if pr_data:
        if "error" in pr_data:
            print(f"pr #{pr_num}: {pr_data['error']}")
        else:
            print(f"pr #{pr_data['number']} [{pr_data['state']}]: head_match={pr_data['head_matches_local']} merge={pr_data['merge_state']} checks_ok={pr_data['checks_passed']} failed={len(pr_data['checks_failed'])} pending={len(pr_data['checks_pending'])}")
PYEOF

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# pr-readiness.sh - Code Mode single-shot PR merge-bar gate check (#132).
# Inspects PR state, HEAD SHA match, CI rollup, mergeStateStatus, and GraphQL
# unresolved thread count in one call. Exits 0 if ready to merge, 1 if blocked.
#
# Usage: bash pr-readiness.sh --pr <N> [--repo <owner/name>] [--expect-head <sha>] [--json]
set -euo pipefail

pr=""
repo=""
expect_head=""
json_mode=0

usage() {
	cat >&2 <<'EOF'
Usage: bash pr-readiness.sh --pr <N> [--repo <owner/name>] [--expect-head <sha>] [--json]
EOF
}

while (($# > 0)); do
	case "$1" in
	--pr)
		pr="${2:?--pr needs a PR number}"
		shift 2
		;;
	--repo)
		repo="${2:?--repo needs owner/name}"
		shift 2
		;;
	--expect-head)
		expect_head="${2:?--expect-head needs a commit SHA}"
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
		echo "pr-readiness: unknown option: $1" >&2
		usage
		exit 2
		;;
	esac
done

[ -n "${pr}" ] || {
	echo "pr-readiness: --pr <N> is required" >&2
	exit 2
}
if ! command -v gh >/dev/null 2>&1; then
	echo "pr-readiness: gh CLI is required" >&2
	exit 1
fi
if [ -z "${repo}" ]; then
	repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
fi
owner="${repo%%/*}"
name="${repo#*/}"

pr_json="$(gh pr view "${pr}" --repo "${repo}" --json number,state,headRefOid,mergeStateStatus,statusCheckRollup,reviewDecision,isDraft)"
gql_json="$(gh api graphql \
	-F owner="${owner}" -F name="${name}" -F pr="${pr}" \
	-f query='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}')"

PR_GQL="${gql_json}" python3 - "${expect_head}" "${json_mode}" "${pr_json}" <<'PYEOF'
import json, os, sys

expect_head, json_mode_s, pr_raw = sys.argv[1:4]
pr = json.loads(pr_raw)
gql = json.loads(os.environ.get("PR_GQL") or "{}")

rt = (((gql.get("data") or {}).get("repository") or {}).get("pullRequest") or {}).get("reviewThreads") or {}
nodes = rt.get("nodes") or []
truncated = bool((rt.get("pageInfo") or {}).get("hasNextPage"))
unresolved = sum(1 for n in nodes if not n.get("isResolved"))

checks = pr.get("statusCheckRollup") or []
passed = [c.get("name") for c in checks if (c.get("conclusion") or "").upper() in ("SUCCESS", "NEUTRAL", "SKIPPED")]
failed = [c.get("name") for c in checks if (c.get("conclusion") or "").upper() in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED")]
pending = [c.get("name") for c in checks if (c.get("status") or "").upper() != "COMPLETED"]

blockers = []
if pr.get("state") != "OPEN":
    blockers.append(f"state is {pr.get('state')} (expected OPEN)")
if pr.get("isDraft"):
    blockers.append("PR is still a draft")
head_sha = str(pr.get("headRefOid") or "")
if expect_head and not head_sha.startswith(expect_head):
    blockers.append(f"head SHA {head_sha[:10]} != expected {expect_head[:10]}")
if not checks:
    blockers.append("no CI checks reported")
if failed:
    blockers.append(f"failing checks: {', '.join(failed)}")
if pending:
    blockers.append(f"pending checks: {', '.join(pending)}")
if unresolved > 0:
    blockers.append(f"{unresolved} unresolved review thread(s)")
if truncated:
    blockers.append("review thread list truncated (hasNextPage=true)")
ms = str(pr.get("mergeStateStatus") or "")
if ms in ("DIRTY", "BEHIND", "BLOCKED", "UNSTABLE"):
    blockers.append(f"mergeStateStatus is {ms}")

ready = len(blockers) == 0
doc = {
    "pr": pr.get("number"), "state": pr.get("state"), "head_sha": head_sha,
    "merge_state": ms, "review_decision": pr.get("reviewDecision"),
    "checks_total": len(checks), "checks_passed": len(passed),
    "checks_failed": failed, "checks_pending": pending,
    "unresolved_threads": unresolved, "threads_truncated": truncated,
    "ready": ready, "blockers": blockers,
}
if json_mode_s == "1":
    print(json.dumps(doc, indent=2))
else:
    verdict = "READY" if ready else "BLOCKED"
    print(f"PR #{doc['pr']} ({head_sha[:10]}): {verdict} | checks={len(passed)}/{len(checks)} failed={len(failed)} pending={len(pending)} | unresolved_threads={unresolved} | merge={ms}")
    for b in blockers:
        print(f"  blocker: {b}")
sys.exit(0 if ready else 1)
PYEOF

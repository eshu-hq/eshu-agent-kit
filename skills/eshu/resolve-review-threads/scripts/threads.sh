#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# threads.sh - Code Mode GraphQL helper for resolve-review-threads (#132).
# Subcommands:
#   list    --pr <N> [--repo <owner/name>] [--json]
#   resolve --thread-id <ID> [--thread-id <ID> ...] [--dry-run] [--json]
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage:
  bash threads.sh list --pr <N> [--repo <owner/name>] [--json]
  bash threads.sh resolve --thread-id <ID> [--thread-id <ID> ...] [--dry-run] [--json]
EOF
}

cmd="${1:-}"
[ -n "${cmd}" ] || {
	usage
	exit 2
}
shift

if ! command -v gh >/dev/null 2>&1; then
	echo "threads: gh CLI is required" >&2
	exit 1
fi

case "${cmd}" in
list)
	pr=""
	repo=""
	json_mode=0
	while (($# > 0)); do
		case "$1" in
		--pr)
			pr="${2:?--pr needs a number}"
			shift 2
			;;
		--repo)
			repo="${2:?--repo needs owner/name}"
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
			echo "threads list: unknown option $1" >&2
			exit 2
			;;
		esac
	done
	[ -n "${pr}" ] || {
		echo "threads list: --pr <N> is required" >&2
		exit 2
	}
	if [ -z "${repo}" ]; then
		repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
	fi
	owner="${repo%%/*}"
	name="${repo#*/}"
	pr_meta="$(gh pr view "${pr}" --repo "${repo}" --json number,state,headRefOid,headRefName,baseRefName)"
	state="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' <<<"${pr_meta}")"
	if [ "${state}" = "MERGED" ] || [ "${state}" = "CLOSED" ]; then
		echo "threads list: refusing to run on ${state} PR #${pr}" >&2
		exit 1
	fi
	raw_gql="$(gh api graphql \
		-F owner="${owner}" -F name="${name}" -F pr="${pr}" \
		-f query='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved isOutdated path line originalLine comments(first:1){nodes{author{login} body}}}}}}}')"
	TH_GQL="${raw_gql}" python3 - "${json_mode}" "${pr_meta}" <<'PYEOF'
import json, os, sys

json_mode = sys.argv[1] == "1"
meta = json.loads(sys.argv[2])
data = json.loads(os.environ.get("TH_GQL") or "{}")
rt = (((data.get("data") or {}).get("repository") or {}).get("pullRequest") or {}).get("reviewThreads") or {}
truncated = bool((rt.get("pageInfo") or {}).get("hasNextPage"))
nodes = rt.get("nodes") or []
open_threads = []
resolved_count = 0
for n in nodes:
    if n.get("isResolved"):
        resolved_count += 1
        continue
    c0 = ((n.get("comments") or {}).get("nodes") or [{}])[0]
    first_line = str(c0.get("body") or "").strip().splitlines()[0][:140] if str(c0.get("body") or "").strip() else ""
    open_threads.append({
        "id": n.get("id"),
        "path": n.get("path") or "",
        "line": n.get("line") if n.get("line") is not None else n.get("originalLine"),
        "isOutdated": bool(n.get("isOutdated")),
        "author": ((c0.get("author") or {}).get("login")) or "unknown",
        "preview": first_line,
    })

out = {
    "pr": meta.get("number"), "state": meta.get("state"),
    "head_sha": meta.get("headRefOid"), "truncated": truncated,
    "scanned": len(nodes), "already_resolved": resolved_count,
    "unresolved": len(open_threads), "threads": open_threads,
}
if json_mode:
    print(json.dumps(out, indent=2))
else:
    print(f"PR #{out['pr']} ({out['head_sha'][:10]}): {out['unresolved']} unresolved / {out['scanned']} scanned ({out['already_resolved']} already resolved)")
    if truncated:
        print("WARNING: thread list is truncated (hasNextPage=true); paginate before classifying.")
    for t in open_threads:
        flag = " [outdated]" if t["isOutdated"] else ""
        print(f"  {t['id']} {t['path']}:{t['line']}{flag} (@{t['author']}): {t['preview']}")
if truncated:
    sys.exit(3)
PYEOF
	;;
resolve)
	ids=()
	dry_run=0
	json_mode=0
	while (($# > 0)); do
		case "$1" in
		--thread-id)
			ids+=("${2:?--thread-id needs a GraphQL thread ID}")
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
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
			echo "threads resolve: unknown option $1" >&2
			exit 2
			;;
		esac
	done
	if [ "${#ids[@]}" -eq 0 ]; then
		echo "threads resolve: at least one --thread-id is required" >&2
		exit 2
	fi
	failed=0
	results=()
	for tid in "${ids[@]}"; do
		if [ "${dry_run}" -eq 1 ]; then
			results+=("$(python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"status":"dry-run"}))' "${tid}")")
			continue
		fi
		resp="$(gh api graphql -F threadId="${tid}" \
			-f query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{id isResolved}}}' 2>&1)" || {
			failed=$((failed + 1))
			results+=("$(python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"status":"error","detail":sys.argv[2][:200]}))' "${tid}" "${resp}")")
			continue
		}
		ok_flag="$(python3 -c 'import json,sys; d=json.load(sys.stdin); t=(((d.get("data") or {}).get("resolveReviewThread") or {}).get("thread") or {}); print("1" if t.get("isResolved") is True else "0")' <<<"${resp}" 2>/dev/null || echo 0)"
		if [ "${ok_flag}" = "1" ]; then
			results+=("$(python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"status":"resolved"}))' "${tid}")")
		else
			failed=$((failed + 1))
			results+=("$(python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"status":"silent-failure","detail":sys.argv[2][:200]}))' "${tid}" "${resp}")")
		fi
	done
	python3 - "${json_mode}" "${results[@]}" <<'PYEOF'
import json, sys
json_mode = sys.argv[1] == "1"
rows = [json.loads(x) for x in sys.argv[2:]]
if json_mode:
    print(json.dumps({"results": rows}, indent=2))
else:
    for r in rows:
        det = f" ({r['detail']})" if r.get("detail") else ""
        print(f"  {r['id']}: {r['status']}{det}")
PYEOF
	[ "${failed}" -eq 0 ]
	;;
-h | --help)
	usage
	exit 0
	;;
*)
	echo "threads: unknown subcommand: ${cmd}" >&2
	usage
	exit 2
	;;
esac

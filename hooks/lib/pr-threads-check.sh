#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/lib/pr-threads-check.sh - Check whether an open PR for the current
# branch has unanswered P0/P1 review threads whose cited files are NOT touched
# by the commits about to be pushed. Fails open on offline/no-gh/no-PR.

prw_is_git_push_cmd() { # <command> -> 0 if real git push, 1 otherwise
	PRW_CMD="$1" python3 -c '
import os, re
cmd = os.environ.get("PRW_CMD", "").strip()
# Match a command segment invoking `git ... push` (ignoring dry-run/delete/tags).
if not re.search(r"(?:^|[;&|]\s*|&&\s*|\|\|\s*)(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*git(?:\s+-C\s+\S+|\s+-c\s+\S+)*\s+push\b", cmd):
    raise SystemExit(1)
if re.search(r"\bgit\b[^;&|]*\bpush\b[^;&|]*(?:--dry-run|-n\b|--delete\b|-d\b|--tags\b|--help\b|-h\b)", cmd):
    raise SystemExit(1)
raise SystemExit(0)
' 2>/dev/null
}

# Prints tab-separated rows: "<pr_num>\t<path>\t<line>\t<summary>" for each
# unresolved, zero-reply P0/P1 thread (excluding pure CI-pending noise) whose
# cited file is NOT modified in the commits about to be pushed.
prw_unanswered_p01_threads() { # <cwd>
	local cwd="$1"
	[ -n "${cwd}" ] && [ -d "${cwd}" ] || return 0
	command -v gh >/dev/null 2>&1 || return 0
	command -v git >/dev/null 2>&1 || return 0
	command -v python3 >/dev/null 2>&1 || return 0

	local branch
	branch="$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
	case "${branch}" in
	"" | HEAD | main | master) return 0 ;;
	esac

	# Resolve open PR for current branch (fail open on offline/no-PR).
	local pr_json
	pr_json="$(cd "${cwd}" && gh pr view --json number,state,url 2>/dev/null)" || return 0
	[ -n "${pr_json}" ] || return 0

	# Files changed in commits about to be pushed (upstream..HEAD, fallback empty).
	local pushed_files=""
	if git -C "${cwd}" rev-parse --verify --quiet '@{u}^{commit}' >/dev/null 2>&1; then
		pushed_files="$(git -C "${cwd}" diff --name-only '@{u}..HEAD' 2>/dev/null || true)"
	fi

	PRW_CWD="${cwd}" PRW_PR_JSON="${pr_json}" PRW_PUSHED="${pushed_files}" python3 -c '
import json, os, re, subprocess

try:
    pr = json.loads(os.environ["PRW_PR_JSON"])
except Exception:
    raise SystemExit(0)
if str(pr.get("state") or "").upper() != "OPEN":
    raise SystemExit(0)
num = pr.get("number")
url = str(pr.get("url") or "")
m = re.search(r"github\.com/([^/]+)/([^/]+)/pull/(\d+)", url)
if not (num and m):
    raise SystemExit(0)
owner, repo = m.group(1), m.group(2)

q = """
query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          path
          line
          originalLine
          comments(first: 2) {
            totalCount
            nodes { body }
          }
        }
      }
    }
  }
}
"""
try:
    raw = subprocess.check_output(
        ["gh", "api", "graphql", "-f", f"query={q}", "-f", f"owner={owner}", "-f", f"repo={repo}", "-F", f"num={num}"],
        cwd=os.environ["PRW_CWD"], stderr=subprocess.DEVNULL, text=True, timeout=8,
    )
    nodes = json.loads(raw)["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
except Exception:
    raise SystemExit(0)

pushed = {ln.strip() for ln in os.environ.get("PRW_PUSHED", "").splitlines() if ln.strip()}
sev_re = re.compile(r"(?:\*\*(P[01])\*\*|img\.shields\.io/badge/(P[01])|\[(P[01])\])", re.I)
timing_phrases = (
    "ci pending", "live lanes pending", "sandbox has no database", "blocked offline",
    "pending in ci", "ci shards pending", "pending on this head", "no observed live",
    "not yet observed", "needs eshu_postgres_test_dsn", "ci still pending",
)

for t in nodes or []:
    if t.get("isResolved"):
        continue
    cm = t.get("comments") or {}
    if int(cm.get("totalCount") or 0) > 1:
        continue
    c0 = (cm.get("nodes") or [{}])[0]
    body = str(c0.get("body") or "")
    if not sev_re.search(body[:400]):
        continue
    low = body.lower()
    if any(p in low for p in timing_phrases):
        continue
    path = str(t.get("path") or "")
    if path and path in pushed:
        continue
    line = t.get("line") or t.get("originalLine") or 0
    first = next((ln.strip() for ln in body.splitlines() if ln.strip()), "P0/P1 finding")[:120]
    first = first.replace("\t", " ")
    print(f"{num}\t{path}\t{line}\t{first}")
' 2>/dev/null || true
}

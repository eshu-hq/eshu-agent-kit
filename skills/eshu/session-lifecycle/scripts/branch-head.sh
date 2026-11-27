#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# branch-head.sh - resolve canonical branch head stamp and verified worktree.
#
# Usage: branch-head.sh [--repo <dir>] [--base <ref>] [--re <id>] [--expect-head <sha>]
#
# Prints the canonical stamp line first (HEAD=<sha> BASE=<sha> [RE:<id>]),
# followed by BRANCH=<name>|(detached), WORKTREE=<path>, STATUS=clean|dirty (<n>).
# Base: --base, else origin/main, else main; an unresolvable base is an error.
# --expect-head takes 10-64 hex characters and must prefix-match HEAD.
# Exit 0 on success, 1 when --expect-head does not match (STALE on stderr),
# 2 on usage or environment error.
set -euo pipefail
export LC_ALL=C GIT_OPTIONAL_LOCKS=0

usage() {
	sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//'
}

repo_arg="."
base_ref=""
re_id=""
expect_head=""

while (($# > 0)); do
	case "$1" in
	--repo)
		[[ $# -ge 2 && -n "$2" ]] || {
			echo "error: --repo requires a directory" >&2
			exit 2
		}
		repo_arg="$2"
		shift 2
		;;
	--base)
		[[ $# -ge 2 && -n "$2" ]] || {
			echo "error: --base requires a git ref" >&2
			exit 2
		}
		base_ref="$2"
		shift 2
		;;
	--re)
		[[ $# -ge 2 && -n "$2" ]] || {
			echo "error: --re requires a request id" >&2
			exit 2
		}
		re_id="$2"
		shift 2
		;;
	--expect-head)
		[[ $# -ge 2 && -n "$2" ]] || {
			echo "error: --expect-head requires a sha" >&2
			exit 2
		}
		expect_head="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [[ ! -d "${repo_arg}" ]]; then
	echo "error: repo directory not found: ${repo_arg}" >&2
	exit 2
fi
repo_dir="$(cd "${repo_arg}" && pwd -P)"
git_repo() { git -C "${repo_dir}" "$@"; }

if [[ -n "${expect_head}" && ! "${expect_head}" =~ ^[0-9a-fA-F]{10,64}$ ]]; then
	echo "error: --expect-head must be 10-64 hex characters: ${expect_head}" >&2
	exit 2
fi

inside="$(git_repo rev-parse --is-inside-work-tree 2>/dev/null)" || inside=""
if [[ "${inside}" != "true" ]]; then
	echo "error: not a git work tree (bare or missing repo): ${repo_dir}" >&2
	exit 2
fi
if ! head_sha="$(git_repo rev-parse --verify HEAD 2>/dev/null)"; then
	echo "error: repository has no HEAD commit: ${repo_dir}" >&2
	exit 2
fi

toplevel_phys="$(cd "$(git_repo rev-parse --show-toplevel)" && pwd -P)"
worktree_path=""
while IFS= read -r line; do
	case "${line}" in
	"worktree "*)
		cand="${line#worktree }"
		if [[ -d "${cand}" ]] && [[ "$(cd "${cand}" && pwd -P)" == "${toplevel_phys}" ]]; then
			worktree_path="${toplevel_phys}"
			break
		fi
		;;
	esac
done < <(git_repo worktree list --porcelain)

if [[ -z "${worktree_path}" ]]; then
	echo "error: ${toplevel_phys} is not in git worktree list --porcelain" >&2
	exit 2
fi

resolved_base_ref=""
if [[ -n "${base_ref}" ]]; then
	if ! git_repo rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
		echo "error: base ref not found: ${base_ref}" >&2
		exit 2
	fi
	resolved_base_ref="${base_ref}"
elif git_repo rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null; then
	resolved_base_ref="origin/main"
elif git_repo rev-parse --verify --quiet 'main^{commit}' >/dev/null; then
	resolved_base_ref="main"
else
	echo "error: no base ref resolves (tried origin/main, main); pass --base" >&2
	exit 2
fi
if ! base_sha="$(git_repo merge-base HEAD "${resolved_base_ref}" 2>/dev/null)"; then
	echo "error: no merge-base between HEAD and ${resolved_base_ref}" >&2
	exit 2
fi

branch="$(git_repo symbolic-ref -q --short HEAD || printf '(detached)')"
dirty_count="$(git_repo status --porcelain | wc -l | tr -d ' ')"
if [[ "${dirty_count}" -eq 0 ]]; then
	status="clean"
else
	status="dirty (${dirty_count})"
fi

if [[ -n "${re_id}" ]]; then
	printf 'HEAD=%s BASE=%s RE:%s\n' "${head_sha}" "${base_sha}" "${re_id}"
else
	printf 'HEAD=%s BASE=%s\n' "${head_sha}" "${base_sha}"
fi
printf 'BRANCH=%s\n' "${branch}"
printf 'WORKTREE=%s\n' "${worktree_path}"
printf 'STATUS=%s\n' "${status}"

if [[ -n "${expect_head}" ]]; then
	expect_lower="$(printf '%s' "${expect_head}" | tr '[:upper:]' '[:lower:]')"
	if [[ "${head_sha}" != "${expect_lower}"* ]]; then
		printf 'STALE: expected %s got %s\n' "${expect_head}" "${head_sha}" >&2
		exit 1
	fi
fi

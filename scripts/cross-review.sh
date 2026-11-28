#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# scripts/cross-review.sh - Portable, zero-build cold cross-family adversarial
# diff reviewer. Invokes an installed CLI from a DIFFERENT model family with
# zero chat history and only the bounded git diff + optional PR body so the
# authoring model never grades its own high-risk diff alone.
#
# Usage:
#   scripts/cross-review.sh [--base <ref>] [--pr <number>] [--repo <dir>]
#                           [--current-family <claude|muse|codex|gemini|opencode>]
#                           [--family <claude|muse|codex|gemini|opencode>]
#                           [--out <file>] [--dry-run]
#
# Exits 0 on completed review, --dry-run, or NOT_AVAILABLE (no cross-family CLI
# installed); exits 2 on bad usage or invalid git ref.
set -uo pipefail

usage() {
	sed -n '10,16p' "$0" | sed 's/^# \{0,1\}//'
}

need_val() {
	if [ "$2" -lt 2 ] || [ -z "${3:-}" ]; then
		printf 'cross-review.sh: %s requires a value\n' "$1" >&2
		usage >&2
		exit 2
	fi
}

base_ref=""
pr_num=""
repo_dir="."
current_family=""
target_family=""
out_file=""
dry_run=0

while [ $# -gt 0 ]; do
	case "$1" in
	--base)
		need_val "$1" "$#" "${2:-}"
		base_ref="$2"
		shift 2
		;;
	--pr)
		need_val "$1" "$#" "${2:-}"
		pr_num="$2"
		shift 2
		;;
	--repo)
		need_val "$1" "$#" "${2:-}"
		repo_dir="$2"
		shift 2
		;;
	--current-family)
		need_val "$1" "$#" "${2:-}"
		current_family="$2"
		shift 2
		;;
	--family)
		need_val "$1" "$#" "${2:-}"
		target_family="$2"
		shift 2
		;;
	--out)
		need_val "$1" "$#" "${2:-}"
		out_file="$2"
		shift 2
		;;
	--dry-run)
		dry_run=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'cross-review.sh: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

[ -d "${repo_dir}" ] || {
	printf 'cross-review.sh: repo directory not found: %s\n' "${repo_dir}" >&2
	exit 2
}
repo_root="$(git -C "${repo_dir}" rev-parse --show-toplevel 2>/dev/null)" || {
	printf 'cross-review.sh: not a git repository: %s\n' "${repo_dir}" >&2
	exit 2
}

if [ -z "${base_ref}" ]; then
	if git -C "${repo_root}" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null 2>&1; then
		base_ref="origin/main"
	elif git -C "${repo_root}" rev-parse --verify --quiet 'main^{commit}' >/dev/null 2>&1; then
		base_ref="main"
	else
		base_ref="HEAD~1"
	fi
fi
base_sha="$(git -C "${repo_root}" merge-base HEAD "${base_ref}" 2>/dev/null)" || {
	printf 'cross-review.sh: cannot resolve merge-base with %s\n' "${base_ref}" >&2
	exit 2
}
head_sha="$(git -C "${repo_root}" rev-parse HEAD)"

detect_current_family() {
	if [ -n "${current_family}" ]; then
		printf '%s\n' "${current_family}"
		return
	fi
	if [ -n "${MUSE_SESSION_ID:-}" ]; then
		printf 'muse\n'
	elif [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ]; then
		printf 'claude\n'
	elif [ -n "${CODEX_THREAD_ID:-}" ]; then
		printf 'codex\n'
	elif [ -n "${ANTIGRAVITY_CONVERSATION_ID:-}" ] || [ -n "${GEMINI_CLI:-}" ]; then
		printf 'gemini\n'
	elif [ -n "${OPENCODE:-}" ]; then
		printf 'opencode\n'
	else
		printf 'unknown\n'
	fi
}

family_bin() {
	case "$1" in
	codex) printf 'codex\n' ;;
	claude) printf 'claude\n' ;;
	gemini) printf 'gemini\n' ;;
	muse) printf 'muse\n' ;;
	opencode) printf 'opencode\n' ;;
	*) printf '\n' ;;
	esac
}

cur_fam="$(detect_current_family)"

if [ -n "${target_family}" ]; then
	if [ "${target_family}" = "${cur_fam}" ]; then
		printf 'cross-review.sh: --family %s matches current family %s (must be cross-family)\n' "${target_family}" "${cur_fam}" >&2
		exit 2
	fi
	if [ -z "$(family_bin "${target_family}")" ]; then
		printf 'cross-review.sh: unknown family: %s\n' "${target_family}" >&2
		exit 2
	fi
fi

# Pick a different model family than the authoring harness.
pick_family() {
	if [ -n "${target_family}" ]; then
		local b
		b="$(family_bin "${target_family}")"
		if command -v "${b}" >/dev/null 2>&1; then
			printf '%s\n' "${target_family}"
			return 0
		fi
		return 1
	fi

	# Preference order keeps model families genuinely distinct (Anthropic/Muse vs OpenAI vs Google).
	local candidates
	case "${cur_fam}" in
	claude | muse) candidates="codex gemini opencode" ;;
	codex) candidates="claude gemini muse opencode" ;;
	gemini) candidates="codex claude muse opencode" ;;
	opencode) candidates="codex claude gemini muse" ;;
	*) candidates="codex claude gemini muse opencode" ;;
	esac
	local f b
	for f in ${candidates}; do
		b="$(family_bin "${f}")"
		if command -v "${b}" >/dev/null 2>&1; then
			printf '%s\n' "${f}"
			return 0
		fi
	done
	return 1
}

chosen_fam="$(pick_family)" || {
	printf 'NOT_AVAILABLE: no cross-family reviewer CLI installed for current_family=%s (install codex, claude, gemini, muse, or opencode)\n' "${cur_fam}"
	exit 0
}
chosen_bin="$(family_bin "${chosen_fam}")"

diff_stat="$(git -C "${repo_root}" diff --stat "${base_sha}..${head_sha}")"
diff_files="$(git -C "${repo_root}" diff --name-only "${base_sha}..${head_sha}" | wc -l | tr -d ' ')"

if [ "${dry_run}" -eq 1 ]; then
	printf 'current_family=%s\nreviewer_family=%s\nbinary=%s\nbase=%s\nhead=%s\ndiff_files=%s\n' \
		"${cur_fam}" "${chosen_fam}" "${chosen_bin}" "${base_sha:0:12}" "${head_sha:0:12}" "${diff_files}"
	exit 0
fi

tmp_prompt="$(mktemp "${TMPDIR:-/tmp}/cross-review.XXXXXX")"
trap 'rm -f "${tmp_prompt}"' EXIT

{
	printf 'You are a cold, read-only adversarial code reviewer from an independent model family.\n'
	printf 'You have ZERO prior chat history. Do not edit files, commit, or push.\n'
	printf 'Hunt specifically for:\n'
	printf '1. false-green-proof (tests that skip silently, assert helpers instead of production callers, or mask regressions)\n'
	printf '2. evidence-overclaim (PR claims, benchmarks, or EXPLAIN plans measured on a statement/path production does not execute)\n'
	printf '3. contract-mismatch (code, docs, schemas, or sibling *_live_test.go files disagreeing)\n'
	printf '4. concurrency, lock, rollback, or error-handling bugs\n\n'
	printf 'Format each finding with severity (P0/P1/P2/P3), category, file:line, concrete evidence, and fix.\n'
	printf 'If no blocking P0/P1/P2 findings exist, state P0=0 P1=0 P2=0 clearly.\n\n'
	printf 'Base: %s\nHead: %s\n\nDiff stat:\n%s\n\n' "${base_sha:0:12}" "${head_sha:0:12}" "${diff_stat}"
	if [ -n "${pr_num}" ] && command -v gh >/dev/null 2>&1; then
		printf 'PR #%s body:\n' "${pr_num}"
		(cd "${repo_root}" && gh pr view "${pr_num}" --json title,body --jq '(.title + "\n\n" + .body)' 2>/dev/null) || true
		printf '\n\n'
	fi
	printf 'Unified diff (truncated to 60KB if larger):\n'
	git -C "${repo_root}" diff "${base_sha}..${head_sha}" | head -c 61440
} >"${tmp_prompt}"

run_reviewer() {
	case "${chosen_fam}" in
	codex)
		codex exec --sandbox read-only -C "${repo_root}" - <"${tmp_prompt}"
		;;
	claude)
		claude -p --permission-mode plan <"${tmp_prompt}"
		;;
	gemini)
		gemini -p "$(cat "${tmp_prompt}")"
		;;
	muse)
		muse exec --read-only <"${tmp_prompt}"
		;;
	opencode)
		opencode run "$(cat "${tmp_prompt}")"
		;;
	esac
}

if [ -n "${out_file}" ]; then
	run_reviewer >"${out_file}"
	printf 'cross-review.sh: wrote %s review to %s\n' "${chosen_fam}" "${out_file}"
else
	run_reviewer
fi

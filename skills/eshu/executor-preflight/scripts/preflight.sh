#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# preflight.sh - deterministic pre-handoff checks for executor-preflight.
#
# Usage: preflight.sh [--repo <dir>] [--body <file>] [--issue] [--base <ref>]
#
# Prints HEAD=<sha>, BODY_SHA256=<sha256> (when --body is given), and one
# table row per check: <check> | PASS|FAIL|NOT_CHECKED | <detail>.
# Rows: bind, shape, license-header, live-tests-ledger, env-registry-doc,
# docs-cli-env-refs, test-todo-scan, live-test-refs. Full output of a failing check goes to
# stderr. Base: --base, else origin/main, else main.
# Exit 0 when no check fails, 1 on any FAIL, 2 on usage or environment error.
set -euo pipefail
export LC_ALL=C GIT_OPTIONAL_LOCKS=0

usage() {
	sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//'
}

repo_arg="."
body_arg=""
shape_mode="pr"
base_ref=""

while (($# > 0)); do
	case "$1" in
	--repo)
		[[ $# -ge 2 ]] || {
			echo "error: --repo requires a directory" >&2
			exit 2
		}
		repo_arg="$2"
		shift 2
		;;
	--body)
		[[ $# -ge 2 ]] || {
			echo "error: --body requires a file" >&2
			exit 2
		}
		body_arg="$2"
		shift 2
		;;
	--issue)
		shape_mode="issue"
		shift
		;;
	--base)
		[[ $# -ge 2 ]] || {
			echo "error: --base requires a git ref" >&2
			exit 2
		}
		base_ref="$2"
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

inside="$(git_repo rev-parse --is-inside-work-tree 2>/dev/null)" || inside=""
if [[ "${inside}" != "true" ]]; then
	echo "error: not a git work tree (bare or missing repo): ${repo_dir}" >&2
	exit 2
fi
# Scope every check to the work-tree root so --repo may be any subdirectory.
repo_dir="$(git_repo rev-parse --show-toplevel)"
if ! head_sha="$(git_repo rev-parse --verify HEAD 2>/dev/null)"; then
	echo "error: repository has no HEAD commit: ${repo_dir}" >&2
	exit 2
fi

base_resolved=""
if [[ -n "${base_ref}" ]]; then
	if ! git_repo rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
		echo "error: base ref not found: ${base_ref}" >&2
		exit 2
	fi
	base_resolved="${base_ref}"
elif git_repo rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null; then
	base_resolved="origin/main"
elif git_repo rev-parse --verify --quiet 'main^{commit}' >/dev/null; then
	base_resolved="main"
fi

body_file=""
if [[ -n "${body_arg}" ]]; then
	if [[ ! -f "${body_arg}" ]]; then
		echo "error: body file not found: ${body_arg}" >&2
		exit 2
	fi
	body_file="$(cd "$(dirname "${body_arg}")" && pwd -P)/$(basename "${body_arg}")"
fi

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

one_line() {
	local text="$1"
	text="$(printf '%s' "${text}" | tr '\r\n' '  ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
	if ((${#text} > 220)); then
		printf '%s...' "${text:0:217}"
	else
		printf '%s' "${text}"
	fi
}

any_fail=0
rows=()
# row <check> <status> <detail> [full-output]: queue one table row; on FAIL the
# optional full output goes to stderr so the row can stay on one line.
row() {
	local name="$1" status="$2" detail="$3" full="${4:-}"
	rows+=("$(printf '%s | %s | %s' "${name}" "${status}" "$(one_line "${detail}")")")
	if [[ "${status}" == "FAIL" ]]; then
		any_fail=1
		if [[ -n "${full}" ]]; then
			printf -- '--- %s: full output ---\n%s\n' "${name}" "${full}" >&2
		fi
	fi
}

tracked_dirty_count() {
	git_repo status --porcelain --untracked-files=no | wc -l | tr -d ' '
}
untracked_count() {
	git_repo ls-files --others --exclude-standard | wc -l | tr -d ' '
}
dirty_at_start="$(tracked_dirty_count)"

resolve_check_shape() {
	local script_dir script_dir_phys candidate
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	script_dir_phys="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
	for candidate in \
		"${script_dir}/../../publish/scripts/check-shape.sh" \
		"${script_dir_phys}/../../publish/scripts/check-shape.sh" \
		"${repo_dir}/.agents/skills/publish/scripts/check-shape.sh" \
		"${repo_dir}/skills/eshu/publish/scripts/check-shape.sh"; do
		if [[ -f "${candidate}" ]]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done
	return 1
}

run_repo_script() {
	local check_name="$1" rel_path="$2" out rc
	if [[ ! -f "${repo_dir}/${rel_path}" ]]; then
		row "${check_name}" "NOT_CHECKED" "${rel_path} not present"
		return 0
	fi
	rc=0
	out="$(cd "${repo_dir}" && bash "${rel_path}" 2>&1)" || rc=$?
	if ((rc == 0)); then
		row "${check_name}" "PASS" "${out:-${rel_path} exited 0}"
	else
		row "${check_name}" "FAIL" "exit ${rc}: ${out:-${rel_path} failed}" "${out}"
	fi
}

# Files added between the merge-base with the base ref and HEAD, named
# *_test.go or test-*.sh, are scanned at their committed content. A line with
# the word TODO or placeholder is a hit; the one exclusion is a placeholder
# line that also carries sql or a $N parameter.
run_test_todo_scan() {
	local base_sha rel name hits file_hits n_files=0 locs=""
	if [[ -z "${base_resolved}" ]]; then
		row "test-todo-scan" "NOT_CHECKED" "pass --base (neither origin/main nor main resolves)"
		return 0
	fi
	if ! base_sha="$(git_repo merge-base HEAD "${base_resolved}" 2>/dev/null)"; then
		row "test-todo-scan" "NOT_CHECKED" "pass --base (no merge-base with ${base_resolved})"
		return 0
	fi

	hits=""
	while IFS= read -r -d '' rel; do
		name="${rel##*/}"
		case "${name}" in
		*_test.go | test-*.sh) ;;
		*) continue ;;
		esac
		n_files=$((n_files + 1))
		file_hits="$(git_repo show "HEAD:${rel}" | awk -v rel="${rel}" '
			{
				line = $0
				low = tolower(line)
				has_todo = (line ~ /(^|[^A-Za-z0-9_])TODO([^A-Za-z0-9_]|$)/)
				has_ph = (low ~ /(^|[^a-z0-9_])placeholder([^a-z0-9_]|$)/)
				if (!has_todo && !has_ph) next
				if (!has_todo && (low ~ /sql/ || line ~ /\$[0-9]+/)) next
				sub(/^[[:space:]]+/, "", line)
				printf "%s:%d:%s\n", rel, NR, line
			}
		')"
		if [[ -n "${file_hits}" ]]; then
			hits="${hits:+${hits}$'\n'}${file_hits}"
		fi
	done < <(git_repo diff -M --name-only -z --diff-filter=A "${base_sha}" HEAD)

	if [[ -n "${hits}" ]]; then
		locs="$(printf '%s\n' "${hits}" | cut -d: -f1,2 | paste -sd ' ' -)"
		row "test-todo-scan" "FAIL" "${locs} (base ${base_sha:0:12})" "${hits}"
	else
		row "test-todo-scan" "PASS" "scanned ${n_files} added test file(s) since ${base_sha:0:12}, no hits"
	fi
}

# Detect untouched *_live_test.go siblings in packages whose non-test .go files
# changed, so DSN-less `go test` passes cannot silently mask broken live tests.
run_live_test_refs_scan() {
	local base_sha rel dir live_files="" changed_set="" n_live=0
	if [[ -z "${base_resolved}" ]]; then
		row "live-test-refs" "NOT_CHECKED" "pass --base (neither origin/main nor main resolves)"
		return 0
	fi
	if ! base_sha="$(git_repo merge-base HEAD "${base_resolved}" 2>/dev/null)"; then
		row "live-test-refs" "NOT_CHECKED" "pass --base (no merge-base with ${base_resolved})"
		return 0
	fi
	changed_set="$(git_repo diff --name-only "${base_sha}" HEAD)"
	local dirs=""
	while IFS= read -r rel; do
		case "${rel}" in
		*.go)
			case "${rel}" in
			*_test.go) continue ;;
			esac
			dir="${rel%/*}"
			[ "${dir}" = "${rel}" ] && dir="."
			dirs="${dirs:+${dirs}$'\n'}${dir}"
			;;
		esac
	done <<<"${changed_set}"
	[ -n "${dirs}" ] || {
		row "live-test-refs" "PASS" "no non-test .go files changed"
		return 0
	}
	while IFS= read -r dir; do
		[ -n "${dir}" ] || continue
		while IFS= read -r lf; do
			[ -n "${lf}" ] || continue
			if ! printf '%s\n' "${changed_set}" | grep -Fxq "${lf}"; then
				live_files="${live_files:+${live_files}$'\n'}${lf}"
				n_live=$((n_live + 1))
			fi
		done < <(git_repo ls-files "${dir}/*_live_test.go")
	done < <(printf '%s\n' "${dirs}" | sort -u)
	if ((n_live == 0)); then
		row "live-test-refs" "PASS" "no untouched *_live_test.go siblings in changed Go packages"
		return 0
	fi
	if [[ -n "${body_file}" ]] && grep -Eiq '(full[[:space:]]+[a-z0-9_./-]+[[:space:]]+suite[[:space:]]+(green|pass)|all[[:space:]]+tests[[:space:]]+pass)' "${body_file}" && ! grep -Eiq '(live[- ]?(db|postgres|neo4j|backend|test)|ESHU_POSTGRES_TEST_DSN|SKIP|hermetic)' "${body_file}"; then
		row "live-test-refs" "FAIL" "PR body claims full suite green while ${n_live} untouched *_live_test.go sibling(s) exist in changed package(s); inspect assertions or state live-DSN run/skip" "${live_files}"
	else
		row "live-test-refs" "PASS" "${n_live} untouched *_live_test.go sibling(s) in changed Go package(s) — verify assertions before claiming full suite green"
	fi
}

if [[ -z "${body_file}" ]]; then
	row "shape" "NOT_CHECKED" "no --body provided"
elif shape_script="$(resolve_check_shape)"; then
	shape_rc=0
	shape_out="$(bash "${shape_script}" "--${shape_mode}" "${body_file}" 2>&1)" || shape_rc=$?
	if ((shape_rc == 0)); then
		row "shape" "PASS" "${shape_out:-OK shape check passed (${shape_mode})}"
	else
		fail_lines="$(printf '%s\n' "${shape_out}" | grep '^FAIL ' || true)"
		row "shape" "FAIL" "${fail_lines:-${shape_out}}" "${shape_out}"
	fi
else
	row "shape" "FAIL" "check-shape.sh not found"
fi

run_repo_script "license-header" "scripts/verify-license-header.sh"
run_repo_script "live-tests-ledger" "scripts/verify-live-tests-ledger.sh"
run_repo_script "env-registry-doc" "scripts/verify-env-registry-doc.sh"
run_repo_script "docs-cli-env-refs" "scripts/verify-docs-cli-env-refs.sh"
run_test_todo_scan
run_live_test_refs_scan

# bind: every result above belongs to head_sha only if HEAD never moved and no
# tracked file differs from it, before or after the checks ran.
head_end="$(git_repo rev-parse --verify HEAD 2>/dev/null || printf 'unreadable')"
dirty_at_end="$(tracked_dirty_count)"
bind_detail="HEAD ${head_sha:0:12}, tracked changes ${dirty_at_start} at start/${dirty_at_end} at end, untracked $(untracked_count)"
bind_status="PASS"
if [[ "${head_end}" != "${head_sha}" ]]; then
	bind_status="FAIL"
	bind_detail="HEAD moved to ${head_end:0:12} during the run; ${bind_detail}"
elif [[ "${dirty_at_start}" != "0" || "${dirty_at_end}" != "0" ]]; then
	bind_status="FAIL"
	bind_detail="tracked tree is dirty; ${bind_detail}"
fi
bind_row="$(printf '%s | %s | %s' "bind" "${bind_status}" "$(one_line "${bind_detail}")")"
[[ "${bind_status}" == "FAIL" ]] && any_fail=1

printf 'HEAD=%s\n' "${head_sha}"
if [[ -n "${body_file}" ]]; then
	printf 'BODY_SHA256=%s\n' "$(sha256_of "${body_file}")"
fi
printf '%s\n' "${bind_row}"
printf '%s\n' "${rows[@]}"

exit "${any_fail}"

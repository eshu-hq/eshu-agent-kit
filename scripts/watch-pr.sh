#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# scripts/watch-pr.sh - Portable, zero-build GitHub PR event watcher.
#
# Polls one or more PRs and emits one structured event line ONLY when state
# changes, staying silent on unchanged polls. Designed for streaming monitors
# (Muse `monitor` with persistent: true, Claude background Monitor/Bash) and
# non-streaming background waiters (--exit-on-event for agy, Codex, Cursor,
# OpenCode). Works on macOS bash 3.2+ and Linux bash 4+.
#
# Usage:
#   watch-pr.sh [--repo owner/repo] [--interval 60] [--stable-reads 2]
#               [--required ctx1,ctx2] [--account login] [--exit-on-event]
#               [--max-polls N | --once] <pr> [<pr> ...]
set -uo pipefail

usage() {
	sed -n '12,15p' "$0" | sed 's/^# \{0,1\}//'
}

repo=""
interval=60
stable_reads=2
required_csv=""
account=""
exit_on_event=0
max_polls=0
prs=()

while [ $# -gt 0 ]; do
	case "$1" in
	--repo | -R)
		repo="${2:-}"
		shift 2
		;;
	--interval)
		interval="${2:-60}"
		shift 2
		;;
	--stable-reads)
		stable_reads="${2:-2}"
		shift 2
		;;
	--required)
		required_csv="${2:-}"
		shift 2
		;;
	--account)
		account="${2:-}"
		shift 2
		;;
	--exit-on-event)
		exit_on_event=1
		shift
		;;
	--max-polls)
		max_polls="${2:-0}"
		shift 2
		;;
	--once)
		max_polls=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		while [ $# -gt 0 ]; do
			prs+=("$1")
			shift
		done
		;;
	-*)
		printf 'watch-pr.sh: unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*)
		prs+=("$1")
		shift
		;;
	esac
done

if [ "${#prs[@]}" -eq 0 ]; then
	printf 'watch-pr.sh: at least one PR number is required\n' >&2
	usage >&2
	exit 2
fi

for pr in "${prs[@]}"; do
	case "${pr}" in
	'' | *[!0-9]*)
		printf 'watch-pr.sh: invalid PR number: %s\n' "${pr}" >&2
		exit 2
		;;
	esac
done

for cmd in gh jq; do
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		printf '%s WATCH state=exit reason=missing-%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${cmd}"
		exit 1
	fi
done

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() {
	printf '%s %s\n' "$(ts)" "$1"
}

run_gh() {
	if [ -n "${account}" ]; then
		local tok
		tok="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "${account}" 2>/dev/null || true)"
		if [ -z "${tok}" ]; then
			return 1
		fi
		GH_TOKEN="${tok}" GITHUB_TOKEN="" gh "$@"
	else
		gh "$@"
	fi
}

if [ -z "${repo}" ]; then
	repo="$(run_gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
case "${repo}" in
*/*) ;;
*)
	emit "WATCH state=exit reason=no-repo"
	exit 1
	;;
esac

owner="${repo%%/*}"
name="${repo#*/}"

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/watch-pr.XXXXXX")"
trap 'rm -rf "${state_dir}"' EXIT

st_get() { # <pr> <key> [default]
	local f="${state_dir}/$1.$2"
	if [ -f "${f}" ]; then
		cat "${f}"
	else
		printf '%s' "${3:-}"
	fi
}

st_set() { # <pr> <key> <val>
	printf '%s' "$3" >"${state_dir}/$1.$2"
}

prs_csv="$(
	IFS=,
	printf '%s' "${prs[*]}"
)"
emit "WATCH state=start repo=${repo} prs=${prs_csv} interval=${interval}s"

poll_one() { # <pr> -> sets actionable=1 when an event fires
	local pr="$1" json err_msg state merge mergeable head head10
	local total pending bad req_missing reviews latest_review comments threads
	local prev_head prev_total stable prev_bad prev_conflict unk_count
	local prev_threads prev_reviews prev_comments prev_green

	local err_file="${state_dir}/${pr}.err"
	json="$(run_gh pr view "${pr}" -R "${repo}" \
		--json state,mergeStateStatus,mergeable,headRefOid,comments,reviews,statusCheckRollup 2>"${err_file}")" || {
		err_msg="$(tr '\n\r\t' '   ' <"${err_file}" 2>/dev/null | cut -c1-160)"
		[ -n "${err_msg}" ] || err_msg="gh pr view exited non-zero"
		if [ "$(st_get "${pr}" last_err)" != "${err_msg}" ]; then
			st_set "${pr}" last_err "${err_msg}"
			emit "ERROR pr=${pr} message=\"${err_msg}\""
		fi
		return 0
	}
	st_set "${pr}" last_err ""

	# Parse all pr-view fields in one jq pass.
	local parsed
	parsed="$(jq -r \
		--arg ign "${WATCH_IGNORE:-}" \
		--arg req "${required_csv}" '
		def is_pending:
			((.status // "") == "QUEUED" or (.status // "") == "IN_PROGRESS" or (.state // "") == "PENDING");
		def is_bad:
			(((.conclusion // "") | test("FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE|STALE"))
			or ((.state // "") | test("FAILURE|ERROR")));
		def is_ok:
			(((.conclusion // "") | test("SUCCESS|NEUTRAL|SKIPPED"))
			or ((.state // "") == "SUCCESS"));
		($ign | split(",") | map(select(. != ""))) as $skip |
		($req | split(",") | map(select(. != ""))) as $reqs |
		(.statusCheckRollup // []) as $c |
		([$c[] | select(is_pending)] | length) as $pend |
		([$c[] | select(is_bad) | (.name // .context // "unknown") | select(. as $n | $skip | index($n) | not)] | unique | join(",")) as $bad |
		([$c[] | select(is_ok) | (.name // .context // "")] | unique) as $ok_names |
		([$reqs[] | select(. as $r | $ok_names | index($r) | not)] | join(",")) as $req_miss |
		([(.comments // [])[] | select((.author.login // "") as $a | ["cloudflare-workers-and-pages","github-actions","mergify[bot]","vercel[bot]","netlify[bot]"] | index($a) | not)] | length) as $comm |
		((.reviews // []) | length) as $revs |
		((.reviews // []) | if length > 0 then (.[-1] | ((.author.login // "unknown") + ":" + (.state // "COMMENTED"))) else "" end) as $lrev |
		[
			(.state // "UNKNOWN"),
			(.mergeStateStatus // "UNKNOWN"),
			(.mergeable // "UNKNOWN"),
			(.headRefOid // ""),
			($c | length | tostring),
			($pend | tostring),
			$bad,
			$req_miss,
			($revs | tostring),
			$lrev,
			($comm | tostring)
		] | .[]
	' <<<"${json}" 2>/dev/null)" || {
		emit "ERROR pr=${pr} message=\"failed to parse gh pr view JSON\""
		return 0
	}

	{
		IFS= read -r state
		IFS= read -r merge
		IFS= read -r mergeable
		IFS= read -r head
		IFS= read -r total
		IFS= read -r pending
		IFS= read -r bad
		IFS= read -r req_missing
		IFS= read -r reviews
		IFS= read -r latest_review
		IFS= read -r comments
	} <<<"${parsed}"
	head10="$(printf '%s' "${head}" | cut -c1-10)"

	# Terminal PR states end watching for this PR immediately.
	if [ "${state}" = "MERGED" ] || [ "${state}" = "CLOSED" ]; then
		emit "${state} pr=${pr} head=${head10}"
		st_set "${pr}" done "1"
		actionable=1
		return 0
	fi

	# Query unresolved review threads via GraphQL.
	local gql
	gql="query{repository(owner:\"${owner}\",name:\"${name}\"){pullRequest(number:${pr}){reviewThreads(first:100){nodes{isResolved}}}}}"
	threads="$(run_gh api graphql -f query="${gql}" \
		-q '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length' 2>/dev/null || echo "?")"

	# Head movement resets stability and per-head dedupe keys.
	prev_head="$(st_get "${pr}" head)"
	if [ -n "${prev_head}" ] && [ "${prev_head}" != "${head}" ]; then
		emit "HEAD-MOVED pr=${pr} from=$(printf '%s' "${prev_head}" | cut -c1-10) to=${head10}"
		st_set "${pr}" stable "0"
		st_set "${pr}" prev_total "-1"
		st_set "${pr}" green_head ""
		st_set "${pr}" bad ""
		st_set "${pr}" conflict ""
		actionable=1
	fi
	st_set "${pr}" head "${head}"

	# Conflict / behind detection (UNKNOWN only after 2 consecutive polls).
	local cstate=""
	if [ "${mergeable}" = "CONFLICTING" ] || [ "${merge}" = "DIRTY" ]; then
		cstate="CONFLICTING"
		st_set "${pr}" unk_count "0"
	elif [ "${merge}" = "BEHIND" ]; then
		cstate="BEHIND"
		st_set "${pr}" unk_count "0"
	elif [ "${mergeable}" = "UNKNOWN" ]; then
		unk_count="$(st_get "${pr}" unk_count "0")"
		unk_count=$((unk_count + 1))
		st_set "${pr}" unk_count "${unk_count}"
		[ "${unk_count}" -ge 2 ] && cstate="UNKNOWN"
	else
		st_set "${pr}" unk_count "0"
		st_set "${pr}" conflict ""
	fi
	prev_conflict="$(st_get "${pr}" conflict)"
	if [ -n "${cstate}" ] && [ "${cstate}:${head10}" != "${prev_conflict}" ]; then
		st_set "${pr}" conflict "${cstate}:${head10}"
		emit "CONFLICT pr=${pr} state=${cstate} head=${head10}"
		actionable=1
	fi

	# CI failures (full failure/cancelled/error set).
	prev_bad="$(st_get "${pr}" bad)"
	if [ -n "${bad}" ] && [ "${bad}:${head10}" != "${prev_bad}" ]; then
		st_set "${pr}" bad "${bad}:${head10}"
		emit "CI-FAIL pr=${pr} head=${head10} jobs=\"${bad}\""
		actionable=1
	fi

	# Unresolved review threads, new reviews, new comments.
	prev_threads="$(st_get "${pr}" threads "-1")"
	if [ "${threads}" != "?" ]; then
		if [ "${prev_threads}" = "-1" ]; then
			if [ "${threads}" -gt 0 ]; then
				emit "NEW-THREAD pr=${pr} unresolved=${threads}"
				actionable=1
			fi
		elif [ "${threads}" -gt "${prev_threads}" ]; then
			emit "NEW-THREAD pr=${pr} unresolved=${threads}"
			actionable=1
		fi
		st_set "${pr}" threads "${threads}"
	fi

	prev_reviews="$(st_get "${pr}" reviews "-1")"
	if [ "${prev_reviews}" != "-1" ] && [ "${reviews}" -gt "${prev_reviews}" ]; then
		emit "NEW-REVIEW pr=${pr} count=${reviews} latest=${latest_review}"
		actionable=1
	fi
	st_set "${pr}" reviews "${reviews}"

	prev_comments="$(st_get "${pr}" comments "-1")"
	if [ "${prev_comments}" != "-1" ] && [ "${comments}" -gt "${prev_comments}" ]; then
		emit "NEW-COMMENT pr=${pr} count=${comments}"
		actionable=1
	fi
	st_set "${pr}" comments "${comments}"

	# GREEN requires stable_reads consecutive polls with 0 pending, 0 failing,
	# non-zero unchanged total, unchanged head, and all required contexts ok.
	prev_total="$(st_get "${pr}" prev_total "-1")"
	stable="$(st_get "${pr}" stable "0")"
	if [ "${pending}" -eq 0 ] && [ "${total}" -gt 0 ] && [ -z "${bad}" ] && [ -z "${req_missing}" ]; then
		if [ "${total}" -eq "${prev_total}" ]; then
			stable=$((stable + 1))
		else
			stable=1
		fi
	else
		stable=0
	fi
	st_set "${pr}" prev_total "${total}"
	st_set "${pr}" stable "${stable}"

	prev_green="$(st_get "${pr}" green_head)"
	if [ "${stable}" -ge "${stable_reads}" ] && [ "${prev_green}" != "${head10}" ]; then
		st_set "${pr}" green_head "${head10}"
		emit "GREEN pr=${pr} head=${head10} checks=${total} merge=${merge} unresolved=${threads}"
		actionable=1
	fi
}

polls=0
while :; do
	polls=$((polls + 1))
	actionable=0
	active=0
	for pr in "${prs[@]}"; do
		[ "$(st_get "${pr}" done "0")" = "1" ] && continue
		active=$((active + 1))
		poll_one "${pr}"
	done

	# Re-count active after polling so terminal PRs exit cleanly on this pass.
	remaining=0
	for pr in "${prs[@]}"; do
		[ "$(st_get "${pr}" done "0")" = "1" ] || remaining=$((remaining + 1))
	done
	if [ "${remaining}" -eq 0 ]; then
		emit "WATCH state=done repo=${repo}"
		exit 0
	fi
	if [ "${exit_on_event}" -eq 1 ] && [ "${actionable}" -eq 1 ]; then
		emit "WATCH state=stopped reason=event"
		exit 0
	fi
	if [ "${max_polls}" -gt 0 ] && [ "${polls}" -ge "${max_polls}" ]; then
		emit "WATCH state=stopped reason=max-polls"
		exit 0
	fi
	sleep "${interval}"
done

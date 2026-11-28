#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/pr-watch-guard.sh - PreToolUse guard for PR watcher hygiene:
# 1. On Bash/bash/run_command/monitor launching a valid looping watcher
#    (`watch-pr.sh`, `pr-watch`, or polling loop), marks matching session PRs
#    armed immediately and logs `pr-watch-armed` (exit 0).
# 2. On Muse `monitor` called with a one-shot `gh pr view`/`gh pr checks`
#    command (no loop, exits in 1s), blocks (exit 2) with the exact
#    `watch-pr.sh` command.
# 3. On Muse `report_progress` with `snooze_minutes > 0` while this session
#    still has an unwatched PR opened by `gh pr create`, blocks (exit 2) with
#    the exact `monitor` + `watch-pr.sh` command.
#
# Override escape: KIT_PR_WATCH_OFF=1, KIT_PR_THREADS_GUARD_OFF=1 (push guard only), or CLAUDE_HOOK_ALLOW=1.
set -uo pipefail

[ "${KIT_PR_WATCH_OFF:-0}" = "1" ] && exit 0
[ "${CLAUDE_HOOK_ALLOW:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload="$(cat)"
[ -n "${payload}" ] || exit 0

# Fast-path skip for unrelated PreToolUse calls.
case "${payload}" in
*"monitor"* | *"report_progress"* | *"snooze_minutes"* | *"watch-pr.sh"* | *"pr-watch"* | *"gh pr"* | *"git push"* | *"git -C"*"push"*) ;;
*) exit 0 ;;
esac

libdir="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=hooks/lib/pr-watch-state.sh
. "${libdir}/pr-watch-state.sh" 2>/dev/null || exit 0
# shellcheck source=hooks/lib/pr-threads-check.sh
. "${libdir}/pr-threads-check.sh" 2>/dev/null || true
# shellcheck source=hooks/lib/skills-insights-events.sh
# shellcheck disable=SC1091
. "${libdir}/skills-insights-events.sh" 2>/dev/null || true

parsed="$(printf '%s' "${payload}" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)

sid = str(d.get("session_id") or d.get("thread_id") or d.get("conversation_id") or "").strip()
tool = str(d.get("tool_name") or "").strip().lower()
ti = d.get("tool_input")
if isinstance(ti, str):
    try:
        ti = json.loads(ti)
    except Exception:
        ti = {}
if not isinstance(ti, dict):
    ti = {}
cmd = str(ti.get("command") or ti.get("cmd") or ti.get("CommandLine") or "").replace("\r", " ").replace("\n", " ")
snooze = ti.get("snooze_minutes")
try:
    snooze_num = int(snooze) if snooze is not None else 0
except (TypeError, ValueError):
    snooze_num = 0

cwd = str(d.get("cwd") or "").strip()
print(sid)
print(tool)
print(snooze_num)
print(cwd)
print(cmd)
' 2>/dev/null)" || exit 0
[ -n "${parsed}" ] || exit 0

sid="$(printf '%s\n' "${parsed}" | sed -n '1p')"
tool="$(printf '%s\n' "${parsed}" | sed -n '2p')"
snooze="$(printf '%s\n' "${parsed}" | sed -n '3p')"
cwd="$(printf '%s\n' "${parsed}" | sed -n '4p')"
cmd="$(printf '%s\n' "${parsed}" | sed -n '5p')"

[ -n "${sid}" ] || exit 0
ws="$(prw_watch_script)"

case "${tool}" in
bash | run_command | shell)
	if [ "$(prw_classify_cmd "${cmd}")" = "valid" ]; then
		prw_mark_armed "${sid}" "${cmd}"
		command -v si_event >/dev/null 2>&1 && si_event "pr-watch-armed" "${sid}"
		exit 0
	fi
	if [ "${KIT_PR_THREADS_GUARD_OFF:-0}" != "1" ] && command -v prw_is_git_push_cmd >/dev/null 2>&1 && prw_is_git_push_cmd "${cmd}"; then
		unanswered="$(prw_unanswered_p01_threads "${cwd:-${PWD}}")"
		if [ -n "${unanswered}" ]; then
			command -v si_event >/dev/null 2>&1 && si_event "pr-watch-block" "${sid}" "reason=unanswered-p01"
			printf 'pr-watch-guard: REFUSED git push — open PR still has unanswered P0/P1 review thread(s) whose cited files are untouched in the commits being pushed:\n' >&2
			pr_num=""
			while IFS=$'\t' read -r pnum tpath tline tsum; do
				[ -n "${pnum}" ] || continue
				pr_num="${pnum}"
				printf '  - PR #%s %s:%s — %s\n' "${pnum}" "${tpath}" "${tline}" "${tsum}" >&2
			done <<<"${unanswered}"
			printf 'Read and fix (or reply to) every P0/P1 thread before pushing again:\n  bash .agents/skills/resolve-review-threads/scripts/threads.sh list --pr %s\n' "${pr_num}" >&2
			printf 'Override with CLAUDE_HOOK_ALLOW=1 only if this push intentionally addresses the finding in another file.\n' >&2
			exit 2
		fi
	fi
	exit 0
	;;
monitor)
	cls="$(prw_classify_cmd "${cmd}")"
	if [ "${cls}" = "valid" ]; then
		prw_mark_armed "${sid}" "${cmd}"
		command -v si_event >/dev/null 2>&1 && si_event "pr-watch-armed" "${sid}"
		exit 0
	fi
	if [ "${cls}" = "oneshot" ]; then
		command -v si_event >/dev/null 2>&1 && si_event "pr-watch-block" "${sid}" "reason=oneshot-monitor"
		printf 'pr-watch-guard: REFUSED one-shot `gh pr view`/`gh pr checks` inside `monitor` (it prints once, emits stream_ended after 1 second, and leaves the PR unwatched).\n' >&2
		printf 'Use a continuous watcher with `persistent: true` instead:\n  bash %s --repo <owner/repo> <pr-number>\n' "${ws}" >&2
		exit 2
	fi
	exit 0
	;;
report_progress)
	if [ "${snooze:-0}" -gt 0 ]; then
		unwatched="$(prw_list_unwatched "${sid}")"
		if [ -n "${unwatched}" ]; then
			command -v si_event >/dev/null 2>&1 && si_event "pr-watch-block" "${sid}" "reason=snooze-unwatched"
			printf 'pr-watch-guard: REFUSED snoozing %sm with unwatched PR(s) opened in this session:\n' "${snooze}" >&2
			while IFS=$'\t' read -r repo pr; do
				[ -n "${repo}" ] && [ -n "${pr}" ] || continue
				printf '  - %s#%s -> arm `monitor` (`persistent: true`): bash %s --repo %s %s\n' \
					"${repo}" "${pr}" "${ws}" "${repo}" "${pr}" >&2
			done <<<"${unwatched}"
			printf 'Arm a live looping PR monitor first, then call report_progress. Override with CLAUDE_HOOK_ALLOW=1 if intentional.\n' >&2
			exit 2
		fi
	fi
	exit 0
	;;
esac

exit 0

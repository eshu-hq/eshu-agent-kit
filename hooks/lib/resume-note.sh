#!/usr/bin/env bash
# At-most-once resume notes for dead turns (see hooks/stop-failure.sh).
#
# A frozen or crashed model call leaves no agent to report what it was
# doing, so the StopFailure hook writes a one-line note and the next
# UserPromptSubmit surfaces it -- once -- then deletes it. Everything here
# is best-effort and silent: a hook must never become the reason a prompt
# fails, and a missing note must never block a restatement.
#
# The filename convention mirrors goal files (active-goal.<sid>[.resume])
# so a note is scoped to exactly the session that died; concurrent agents
# never see each other's notes. Sourced once by goal-refresh.sh, which
# holds no other copy of these paths.
# shellcheck shell=bash

# resume_note_path <dir> <session-id> -- print the note path for this
# session. Same transform as goal-refresh.sh's sid_safe; the writer and
# the reader share this one definition.
resume_note_path() {
	printf '%s/.claude/active-goal.%s.resume\n' "${1:-}" "$(printf '%s' "${2:-}" | tr -c 'A-Za-z0-9._-' '-' 2>/dev/null)"
}

# resume_note_load <dir> <session-id> <have-cwd: 1|0> -- set the globals
# resume_file and resume_note (empty when there is nothing pending).
resume_note_load() {
	resume_file=""
	resume_note=""
	[ "${3:-}" = "1" ] || return 0
	resume_file="$(resume_note_path "$1" "$2")"
	[ -f "${resume_file}" ] || {
		resume_file=""
		return 0
	}
	resume_note="$(head -c 2000 "${resume_file}" 2>/dev/null)"
	return 0
}

# resume_note_consume_standalone -- emit the loaded note as a UserPromptSubmit
# additionalContext block for turns with no restatable goal. Prints the JSON
# on success and deletes the note; prints nothing otherwise. Callers exit
# right after regardless -- a failed emit must not fail the turn.
resume_note_consume_standalone() {
	local out=""
	[ -n "${resume_note:-}" ] || return 0
	out="$(printf '%s' "${resume_note}" | python3 -c '
import json, sys
text = sys.stdin.read().strip()
if not text:
    raise SystemExit(0)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": text}}))' 2>/dev/null)" || return 0
	[ -n "${out}" ] || return 0
	printf '%s\n' "${out}"
	[ -n "${resume_file:-}" ] && rm -f "${resume_file}" 2>/dev/null
	return 0
}

# resume_note_discard -- drop a leftover note (retired goal: nothing to
# resume). Always succeeds.
resume_note_discard() {
	[ -n "${resume_file:-}" ] && rm -f "${resume_file}" 2>/dev/null
	return 0
}

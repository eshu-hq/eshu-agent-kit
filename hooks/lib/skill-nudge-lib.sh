#!/usr/bin/env bash
# Sourced by skill-nudge.sh (and the goal hooks when they move) -- not run on its own.
#
# kit_root_path walks up from a file or directory looking for the kit pin file
# (.agent-kit-version) and prints the resolved repo root on success. Callers
# that only need the gate use kit_root; callers that build paths under the
# root use the printed path. One shared implementation so copies cannot drift.
kit_root_path() { # path
	local d="${1:-}"
	[ -n "$d" ] || return 1
	[ -d "$d" ] || d="$(dirname "$d")"
	while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
		if [ -e "$d/.agent-kit-version" ]; then
			printf '%s\n' "$d"
			return 0
		fi
		d="$(dirname "$d")"
	done
	return 1
}

# Boolean-only form for callers that just need the gate, not the path.
kit_root() { # path
	kit_root_path "$1" >/dev/null
}

# Finds project skills a goal's text names that this session has not loaded,
# reusing the marker `skill-nudge.sh` and `skill-loaded.sh` already own
# (`/tmp/claude-skill-loaded-<sid12>-<id>`, keyed on the first 12 characters
# of the session id) rather than inventing a second convention. Only a real
# directory under `.agents/skills/` counts as a named skill; an id that does
# not exist there is ordinary prose and gets no nudge.
#
# Matching is word-bounded so a goal mentioning, say,
# "golang-engineering-notes" does not fire the `golang-engineering` nudge.
# Split out of goal-refresh.sh to keep that file under the repo's 500-line cap.

goal_refresh_missing_skill_nudges() { # goal_text skills_dir sid12
	local goal_text="$1" skills_dir="$2" sid="$3"
	GOAL="${goal_text}" SKILLS_DIR="${skills_dir}" SKILL_SID="${sid}" python3 -c '
import os, re
goal = os.environ.get("GOAL", "")
skills_dir = os.environ.get("SKILLS_DIR", "")
sid = os.environ.get("SKILL_SID", "")
missing = []
try:
    ids = sorted(d for d in os.listdir(skills_dir)
                 if os.path.isdir(os.path.join(skills_dir, d)))
except Exception:
    ids = []
for skill_id in ids:
    pattern = r"(?<![A-Za-z0-9_-])" + re.escape(skill_id) + r"(?![A-Za-z0-9_-])"
    if not re.search(pattern, goal):
        continue
    canon = skill_id[5:] if skill_id.startswith("eshu-") else skill_id
    if any(os.path.exists("/tmp/claude-skill-loaded-%s-%s" % (sid, n))
           for n in (skill_id, canon, "eshu-" + canon)):
        continue
    missing.append(skill_id)
print(" ".join(missing))
' 2>/dev/null
}

# Prints the space-joined skill-nudge names for a goal, or nothing when
# there is nothing to scan. Split out of goal-refresh.sh to keep that file
# under the repo's 500-line cap; behavior matches the inline block it
# replaces. Always succeeds: an empty print is a legitimate "nothing to
# nudge here" outcome, not a failure.
goal_refresh_nudge_scan() { # goal_text session_id have_cwd cwd_prefix
	local goal_text="$1" session_id="$2" have_cwd="$3" cwd_prefix="$4"
	local skills_root="" d
	# The scan needs the kit's skill dirs, not the cwd's own skill trees --
	# those directories only exist at the kit root. A cwd one level down or
	# any deeper worktree subdirectory has no skills of its own, so the scan
	# would silently find nothing and no nudge would ever fire outside the
	# repo root. kit_root_path is the same walk-up skill-nudge.sh already
	# does to find the kit pin; sharing it keeps the two from drifting apart.
	#
	# Deliberately silent, not an error, when a root cannot be resolved: the
	# cwd-less path the hook supports (no "cwd" in the payload) has nothing
	# to walk up from, and a fixture or worktree that is not a kit-pinned
	# checkout at all has no marker to find.
	if [ "${have_cwd}" = "1" ]; then
		skills_root="$(kit_root_path "${cwd_prefix}" 2>/dev/null)" || skills_root=""
	fi
	[ -n "${skills_root}" ] || return 0
	# The skills a consuming repo sees are its harness trees: the installer
	# puts every skill under its harness-visible name in .claude/skills,
	# while .agents/skills carries only the ones the alias manifest does not
	# rename. Both are scanned, because together they are the census a
	# consumer's goal can name. The kit's own skills/eshu and skills/core are
	# the SOURCE of those names, not what a consumer's goal can name.
	#
	# No scratch file in a shared /tmp: the loop output stays in the shell,
	# so no PID-predictable path to squat on.
	for d in "${skills_root}/.claude/skills" "${skills_root}/.agents/skills"; do
		[ -d "$d" ] || continue
		goal_refresh_missing_skill_nudges "${goal_text}" "$d" "$(printf '%s' "${session_id}" | cut -c1-12)"
	done | tr '\n' ' '
	return 0
}

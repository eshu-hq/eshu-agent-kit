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
    marker = "/tmp/claude-skill-loaded-%s-%s" % (sid, skill_id)
    if os.path.exists(marker):
        continue
    missing.append(skill_id)
print(" ".join(missing))
' 2>/dev/null
}

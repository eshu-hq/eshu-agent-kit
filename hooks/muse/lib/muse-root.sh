#!/usr/bin/env bash
# Sourced by .muse/hooks/* -- not run on its own.
#
# Resolves the tree root from the calling wrapper's own location, so a hook
# fires correctly no matter which subdirectory the session cwd is in. The
# same wrappers serve two installs: project (.muse/hooks in a repo, found
# via `git rev-parse` in hooks.json) and global (the agent-kit-hooks
# pseudo-root under the Muse config dir, found via absolute commands in
# the managed hooks file). kit_muse_prepare tells them apart per payload
# and makes the global copy defer to a project hooks.json that registers
# the same wrapper for the same (event, matcher), so no hook fires twice.

# BASH_SOURCE[1] is the wrapper that sourced this file; [0] is this file.
# Captured at source time: the helpers below call each other, which would
# shift the stack this resolution depends on.
_kit_muse_src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
KIT_MUSE_TREE_ROOT="$(cd "$(dirname "${_kit_muse_src}")/../.." 2>/dev/null && pwd)"
unset _kit_muse_src

muse_repo_root() {
	[ -n "${KIT_MUSE_TREE_ROOT:-}" ] || return 1
	printf '%s\n' "${KIT_MUSE_TREE_ROOT}"
}

# _kit_muse_git_root <cwd> -- nearest ancestor holding .git, stopping at
# $HOME or the filesystem root; prints nothing when there is none.
_kit_muse_git_root() {
	local d="$1"
	while [ -n "$d" ] && [ "$d" != "/" ]; do
		if [ -e "$d/.git" ]; then
			printf '%s\n' "$d"
			return 0
		fi
		[ "$d" = "${HOME:-/nonexistent}" ] && break
		d="$(dirname "$d")"
	done
	return 0
}

# kit_muse_prepare <wrapper-basename> <payload>
#   0 = delegate to the sibling in this tree (KIT_GLOBAL_HOOK=1 is exported
#       first when this is the global copy, which tells siblings to never
#       execute repo-supplied code)
#   3 = defer: the payload repo's own .muse/hooks.json registers this
#       wrapper for this (event, matcher); the caller exits 0 quietly.
# Every ambiguity -- no python3, unparseable payload or project file, no
# git root -- delegates: exactly one firing beats none, and the project
# copy cannot be relied on to fire from here.
kit_muse_prepare() {
	local name="$1" payload="$2" fields event tool cwd gitroot own
	command -v python3 >/dev/null 2>&1 || return 0
	fields="$(printf '%s' "${payload}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
print(chr(31).join([str(d.get("hook_event_name") or ""), str(d.get("tool_name") or ""), str(d.get("cwd") or "")]))
' 2>/dev/null)" || return 0
	IFS="$(printf '\037')" read -r event tool cwd <<<"${fields}"
	[ -n "${cwd:-}" ] && [ -d "${cwd}" ] || return 0
	gitroot="$(_kit_muse_git_root "${cwd}")"
	own="${KIT_MUSE_TREE_ROOT:-}"
	if [ -n "${gitroot}" ] && [ -n "${own}" ] &&
		[ "$(cd "${own}" 2>/dev/null && pwd -P)" = "$(cd "${gitroot}" 2>/dev/null && pwd -P)" ]; then
		return 0
	fi
	export KIT_GLOBAL_HOOK=1
	[ -n "${gitroot}" ] || return 0
	[ -f "${gitroot}/.muse/hooks.json" ] || return 0
	python3 - "${gitroot}/.muse/hooks.json" "${event}" "${tool}" "${name}" <<'PYEOF' 2>/dev/null
import json, sys

path, event, tool, name = sys.argv[1:5]
try:
    entries = json.load(open(path)).get("hooks", {}).get(event, [])
    for entry in entries:
        # Empty matches all; Claude-style pipe lists and "*" count too:
        # over-deferring to the project copy is the safe side.
        matcher = str(entry.get("matcher") or "")
        if matcher not in ("", "*") and tool not in matcher.split("|"):
            continue
        for hook in entry.get("hooks", []):
            if "/.muse/hooks/" + name in str(hook.get("command", "")):
                raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    pass
raise SystemExit(1)
PYEOF
	[ $? -eq 0 ] && return 3
	return 0
}

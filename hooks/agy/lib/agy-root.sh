#!/usr/bin/env bash
# Sourced by hooks/agy/* (.agy/hooks/*) -- not run on its own.
#
# Every agy adapter prints at most one JSON object and exits 0: agy does not
# understand the kit's exit-2 + stderr block, and a hook crash may fail open
# or closed (unverified), so no path here may print anything but a verdict.
# Neutral is EMPTY output (live: agy 1.5.18 treats a PreToolUse `{}` as a
# deny); "allow" is never emitted (agy treats it as an automatic
# approval that would bypass the user's permission prompts).
#
# Tree layout this resolves, from the calling wrapper's own location:
#   repo install   <repo>/.agy/hooks/*.sh  -> <repo>/.claude/hooks/*.sh
#   global tree    ~/.gemini/config/agent-kit-hooks/.agy/hooks/*.sh (same shape)
#   kit checkout   <kit>/hooks/agy/*.sh    -> <kit>/hooks/*.sh

# BASH_SOURCE[1] is the wrapper that sourced this file; [0] is this file.
_kit_agy_src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
KIT_AGY_SCRIPT_DIR="$(cd "$(dirname "${_kit_agy_src}")" 2>/dev/null && pwd)"
KIT_AGY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
KIT_AGY_TREE_ROOT="$(cd "${KIT_AGY_SCRIPT_DIR}/../.." 2>/dev/null && pwd)"
unset _kit_agy_src

agy_sibling() { # <sibling-basename> -> path of the shared kit hook
	local cand
	for cand in "${KIT_AGY_TREE_ROOT}/.claude/hooks/$1" "${KIT_AGY_SCRIPT_DIR}/../$1"; do
		[ -x "${cand}" ] && [ -f "${cand}" ] && {
			printf '%s\n' "${cand}"
			return 0
		}
	done
	return 1
}

# agy_global_peer <name> <event> -- 0 when a working GLOBAL install already
# covers this wrapper, so the REPO copy (KIT_GLOBAL_HOOK unset) may stand down.
# The global copy never stands down and never reads a path from the payload:
# a workspace can at worst add a firing, never silence a guard. Every check
# reads $HOME files only and ANY doubt or exception returns 1 (fire):
#  - HOME is set, non-empty and absolute (no fallback: agy may have read another);
#  - ~/.gemini/config/hooks.json is a regular, non-symlink file that parses as
#    strictly as Go (no NaN/Infinity/out-of-range numbers/BOM) and has no two
#    keys equal after casefold at ANY level (Go matches struct keys
#    case-insensitively; this also covers a top-level case variant of the
#    kit key, so do not narrow it to the kit key only);
#  - its eshu-agent-kit-global key deep-equals the WHOLE generated global key
#    (every event, group, matcher, command, timeout, no extra member such as
#    `enabled`), rebuilt here from the kit template; scripts/lib/install-hooks-agy.sh
#    builds the same strings and uninstall deep-compares them, pinned by test 10;
#  - the global tree has executable .agy/hooks/<name>.sh and .claude/hooks/<name>.sh
#    and readable lib/agy-root.sh and lib/agy-translate.py (symlinks into the
#    kit are the design and are accepted).
agy_global_peer() {
	python3 -I -c '
import copy, json, os, re, shlex, sys
name, mine = sys.argv[1:3]
def pairs(items):
    keys = [k.casefold() for k, _ in items]
    if len(keys) != len(set(keys)):
        raise ValueError("case-folded duplicate key")
    return dict(items)
def strict(path):
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh, parse_int=float, object_pairs_hook=pairs)
    json.dumps(d, allow_nan=False)
    return d
try:
    home = os.environ.get("HOME") or ""
    if not os.path.isabs(home):
        raise SystemExit(1)
    path = os.path.join(home, ".gemini", "config", "hooks.json")
    tree = os.path.join(home, ".gemini", "config", "agent-kit-hooks")
    if os.path.islink(path) or not os.path.isfile(path):
        raise SystemExit(1)
    want = copy.deepcopy(strict(os.path.join(os.path.dirname(os.path.realpath(mine)), "hooks.json"))["eshu-agent-kit"])
    for groups in want.values():
        for g in groups:
            for hd in g["hooks"] if isinstance(g.get("hooks"), list) else [g]:
                base = re.search(r"/([A-Za-z0-9_-]+\.sh)", hd["command"]).group(1)
                hd["command"] = "h=%s; [ -x \"$h\" ] || exit 0; KIT_GLOBAL_HOOK=1 exec \"$h\"" % shlex.quote(os.path.join(tree, ".agy", "hooks", base))
    if strict(path).get("eshu-agent-kit-global") != want:
        raise SystemExit(1)
    for rel in (".agy/hooks/" + name + ".sh", ".claude/hooks/" + name + ".sh"):
        f = os.path.join(tree, rel)
        if not (os.path.isfile(f) and os.access(f, os.X_OK)):
            raise SystemExit(1)
    for rel in (".agy/hooks/lib/agy-root.sh", ".agy/hooks/lib/agy-translate.py"):
        f = os.path.join(tree, rel)
        if not (os.path.isfile(f) and os.access(f, os.R_OK)):
            raise SystemExit(1)
    raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    raise SystemExit(1)
' "$1" "${KIT_AGY_SCRIPT_DIR}/$1.sh" 2>/dev/null
}

# _agy_pipeline <name> <kind> <event> <payload> -- sets `verdict` (the caller's
# local) or leaves it empty for neutral.
_agy_pipeline() {
	local name="$1" kind="$2" event="$3" payload="$4" sib in tmp rc
	command -v python3 >/dev/null 2>&1 || return 0
	sib="$(agy_sibling "${name}.sh")" || return 0
	# Repo copy only: stand down beside a working global install. skill-nudge is
	# the one wrapper whose copies differ (the global one skips a repo
	# .agents/nudge-table.sh), so it still runs and the sibling exits at once
	# unless that table exists.
	if [ "${KIT_GLOBAL_HOOK:-}" != "1" ] && agy_global_peer "${name}"; then
		[ "${name}" = skill-nudge ] || return 0
		export KIT_GLOBAL_PEER=1
	fi
	in="$(printf '%s' "${payload}" | python3 -I "${KIT_AGY_LIB_DIR}/agy-translate.py" in "${kind}" 2>/dev/null)" || return 0
	[ -n "${in}" ] || return 0
	tmp="$(mktemp -d 2>/dev/null)" || return 0
	# Telemetry from the shared sibling attributes to agy through this.
	export KIT_HARNESS=agy
	printf '%s' "${in}" | "${sib}" >"${tmp}/out" 2>"${tmp}/err"
	rc=$?
	verdict="$(python3 -I "${KIT_AGY_LIB_DIR}/agy-translate.py" out "${kind}" "${rc}" "${tmp}/out" "${tmp}/err" 2>/dev/null)"
	rm -rf "${tmp}"
	return 0
}

# agy_run <name> <kind> <event> -- the single exit path of every wrapper.
agy_run() {
	local verdict="" payload
	payload="$(cat 2>/dev/null)" || payload=""
	_agy_pipeline "$1" "$2" "$3" "${payload}" || true
	case "${verdict}" in
	"{}") ;;
	"{"*) printf '%s\n' "${verdict}" ;;
	*) ;;
	esac
	exit 0
}

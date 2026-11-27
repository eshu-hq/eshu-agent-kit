# Antigravity (agy) hooks delivery and removal. Sourced by install.sh;
# extracted to keep it and install-uninstall.sh under the 500-line cap.
#
# agy reads a NAME-keyed hooks.json; the kit owns one key per scope:
# `eshu-agent-kit` (repo) and `eshu-agent-kit-global` (global).
#   repo    .agents/hooks.json (agy runs commands from .agents/, so wrappers
#           are reached as ../.agy/hooks/NAME.sh)
#   global  ~/.gemini/config/hooks.json + a pseudo-root tree under
#           ~/.gemini/config/agent-kit-hooks; absolute commands set
#           KIT_GLOBAL_HOOK=1 (no repo code runs; always fires, and a repo copy
#           stands down only on an exact global install).
# One generator builds the key for both scopes; install, the differs-from-kit
# check and uninstall's deep-equal all compare that one value.
# shellcheck shell=bash
# Modes (args: mode file scope tree template):
#   check   print CREATE|MERGE|REPLACE|OK; refuse (exit 3) writing nothing on
#           invalid JSON, non-object, symlink, BOM, duplicate keys, or a kit
#           key that is not provably ours.
#   apply   atomic write (temp file + os.replace) of the kit key only.
#   remove  drop the kit key only when it deep-equals the generated value;
#           delete the file only when left with {}. Prints REMOVED_KEY|
#           REMOVED_FILE|NONE|KEPT:<reason>.
AGY_HOOKS_PY='
import json, os, re, shlex, sys, tempfile

mode, path, scope, tree, template = sys.argv[1:6]
TKEY = "eshu-agent-kit"  # the key in the shipped template; global scope installs it as KEY below
KEY = TKEY if scope == "repo" else TKEY + "-global"  # a distinct name: agy merges same-named hooks across files undocumented

def refuse(msg):
    print("refusing: " + msg, file=sys.stderr)
    sys.exit(3)

def command(base, legacy=False):
    fb = "{ printf %s; exit 0; }" % shlex.quote("{}") if legacy else "exit 0"
    if scope == "repo":
        h, pre = "../.agy/hooks/" + base, ""
    else:
        h, pre = tree + "/.agy/hooks/" + base, "KIT_GLOBAL_HOOK=1 "
    return "h=%s; [ -x \"$h\" ] || %s; %sexec \"$h\"" % (shlex.quote(h), fb, pre)

def handlers(key):
    for groups in key.values():
        if isinstance(groups, list):
            for g in groups:
                if isinstance(g, dict):
                    yield from (g["hooks"] if isinstance(g.get("hooks"), list) else [g])

def want(legacy=False):
    key = json.load(open(template))[TKEY]
    for h in handlers(key):
        h["command"] = command(re.search(r"/([A-Za-z0-9_-]+\.sh)", h["command"]).group(1), legacy)
    return key

# A key is ours only when every command has the exact shape command() generates
# (any kit .agy/hooks/ wrapper name, relative or absolute path); a user command
# that merely mentions .agy/hooks/ is never reclaimed.
Q = chr(39)
OWNED = re.compile("^h=" + Q + "?(?:\\.\\.|/[^;" + Q + "\"]*)/\\.agy/hooks/[A-Za-z0-9_-]+\\.sh" + Q + "?; \\[ -x \"\\$h\" \\] \\|\\| (?:exit 0|\\{ printf " + Q + "\\{\\}" + Q + "; exit 0; \\}); (?:KIT_GLOBAL_HOOK=1 )?exec \"\\$h\"$")

def no_dupes(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate keys")
    return dict(pairs)

def load():
    """(data, exists) or a refusal; strict, never repairs."""
    if os.path.islink(path):
        refuse("%s is a symlink; merge the kit key by hand" % path)
    if not os.path.exists(path):
        return {}, False
    raw = open(path, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        refuse("%s starts with a byte-order mark; left untouched" % path)
    try:
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=no_dupes,
                          parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
    except Exception as exc:
        refuse("%s is not valid JSON (%s); left untouched" % (path, exc))
    if not isinstance(data, dict):
        refuse("%s top level is not a JSON object; left untouched" % path)
    return data, True

def write(data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".hooks-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(json.dumps(data, indent=2) + "\n")
        json.load(open(tmp))
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def action(data, exists):
    cur, mine = data.get(KEY), want()
    if cur == mine:
        return "OK"
    if cur is not None:
        hs = list(handlers(cur)) if isinstance(cur, dict) else []
        if not hs or not all(isinstance(h, dict) and OWNED.match(str(h.get("command", ""))) for h in hs):
            refuse("%s already has an %s key whose commands are not the kit-generated hook commands; not reclaiming it" % (path, KEY))
        return "REPLACE"
    return "MERGE" if exists else "CREATE"

if mode == "remove":
    try:
        data, exists = load()
    except SystemExit:
        print("KEPT:not strict JSON; left untouched")
        sys.exit(0)
    if KEY not in data:
        print("NONE")
    elif data[KEY] not in (want(), want(True)):
        print("KEPT:modified %s key; remove it by hand" % KEY)
    else:
        del data[KEY]
        if data:
            write(data)
            print("REMOVED_KEY")
        else:
            os.unlink(path)
            print("REMOVED_FILE")
    sys.exit(0)

data, exists = load()
act = action(data, exists)
if mode == "check":
    print(act)
elif act == "OK":
    print("%s already registers the kit hooks; unchanged" % path)
else:
    new = dict(data)
    new[KEY] = want()
    write(new)
    back = json.load(open(path))
    if back.get(KEY) != want() or any(back.get(k) != v for k, v in data.items() if k != KEY):
        refuse("internal compare failed; check %s" % path)
    print("%s %s (%s key %s; formatting normalized to indent=2)" % ("created" if not exists else "updated", path, KEY, {"CREATE": "added", "MERGE": "merged", "REPLACE": "replaced"}[act]))
'

agy_hooks_json() { # <mode> <file> <scope> <tree>
	python3 -c "$AGY_HOOKS_PY" "$1" "$2" "$3" "$4" "$KIT_DIR/hooks/agy/hooks.json"
}

agy_link_tree() { # <root> -- wrappers under <root>/.agy/hooks
	link_files "$KIT_DIR/hooks/agy/*.sh" "$1/.agy/hooks"
	link_files "$KIT_DIR/hooks/agy/lib/*" "$1/.agy/hooks/lib"
	prune_dir "$1/.agy/hooks" "$KIT_DIR/hooks/agy/*.sh"
	prune_dir "$1/.agy/hooks/lib" "$KIT_DIR/hooks/agy/lib/*"
}

# install_agy_hooks_repo <target> -- called after the .claude/hooks siblings
# are linked. A refusal is reported and writes nothing agy-related, but does
# not fail the rest of the repo hooks install.
install_agy_hooks_repo() {
	local target="$1" file="$1/.agents/hooks.json" res
	command -v python3 >/dev/null 2>&1 || {
		echo "skipping $file: agy hooks need python3" >&2
		return 0
	}
	if ! agy_hooks_json check "$file" repo "" >/dev/null; then
		echo "agy hooks not installed into $target (see the refusal above)" >&2
		return 0
	fi
	agy_link_tree "$target"
	res="$(agy_hooks_json apply "$file" repo "")" || return 0
	echo "$res"
}

install_hooks_global_agy() {
	local cfg="$HOME/.gemini/config" tree hooks
	hooks="$cfg/hooks.json"
	tree="$cfg/agent-kit-hooks"
	echo "warning: global agy hooks run in every workspace with no trust step; the hook tree is symlinks into this kit checkout ($KIT_DIR)" >&2
	command -v python3 >/dev/null 2>&1 || {
		echo "error: --hooks --global agy needs python3; nothing installed" >&2
		return 1
	}
	agy_hooks_json check "$hooks" global "$tree" >/dev/null || return 1
	mkdir -p "$tree/.claude/hooks/lib"
	link_files "$KIT_DIR/hooks/*.sh" "$tree/.claude/hooks"
	link_files "$KIT_DIR/hooks/lib/*" "$tree/.claude/hooks/lib"
	prune_dir "$tree/.claude/hooks" "$KIT_DIR/hooks/*.sh"
	prune_dir "$tree/.claude/hooks/lib" "$KIT_DIR/hooks/lib/*"
	agy_link_tree "$tree"
	agy_hooks_json apply "$hooks" global "$tree" || return 1
	echo "installed global agy hooks (key eshu-agent-kit in $hooks)"
	echo "undo: ./install.sh --uninstall --hooks --global agy (or delete that key and $tree)"
}

# agy_uninstall_json <file> <scope> <tree> -- drop the kit key with proof.
agy_uninstall_json() {
	local res
	[ -e "$1" ] || [ -L "$1" ] || return 0
	command -v python3 >/dev/null 2>&1 || {
		uninstall_keeping "$1" "cannot verify the kit key without python3; remove by hand"
		return 0
	}
	res="$(agy_hooks_json remove "$1" "$2" "$3" 2>/dev/null)" || res="KEPT:could not be processed; left untouched"
	case "$res" in
	REMOVED_FILE | REMOVED_KEY)
		UNINSTALL_REMOVED=$((UNINSTALL_REMOVED + 1))
		printf 'removed %s%s\n' "$([ "$res" = REMOVED_KEY ] && echo 'the eshu-agent-kit key from ')" "$1"
		;;
	KEPT:*) uninstall_keeping "$1" "${res#KEPT:}" ;;
	esac
}

uninstall_agy_hooks_repo() { # <target> <force>
	uninstall_managed_tree "$1/.agy/hooks" "$2"
	uninstall_managed_tree "$1/.agy/hooks/lib" "$2"
	agy_uninstall_json "$1/.agents/hooks.json" repo ""
	uninstall_rmdir "$1/.agy/hooks/lib"
	uninstall_rmdir "$1/.agy/hooks"
}

uninstall_note_global_agy() { # a broad uninstall never removes global hooks
	[ ! -e "$HOME/.gemini/config/agent-kit-hooks" ] || uninstall_keeping "$HOME/.gemini/config/agent-kit-hooks" "installed by --hooks --global agy; run --uninstall --hooks --global agy to remove it"
}

uninstall_hooks_global_agy() { # <force>
	local tree="$HOME/.gemini/config/agent-kit-hooks" d
	for d in .claude/hooks .claude/hooks/lib .agy/hooks .agy/hooks/lib; do
		uninstall_managed_tree "$tree/$d" "${1:-0}"
	done
	agy_uninstall_json "$HOME/.gemini/config/hooks.json" global "$tree"
	for d in .claude/hooks/lib .claude/hooks .claude .agy/hooks/lib .agy/hooks .agy; do
		uninstall_rmdir "$tree/$d"
	done
	uninstall_rmdir "$tree"
}

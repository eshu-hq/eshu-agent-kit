# Global Claude hooks delivery (--hooks --global claude). Sourced by
# install.sh; extracted to keep the entrypoint under the 500-line cap, like
# install-hooks-global.sh. Registration merges the 8 shared entries from
# hooks/hooks.json into ~/.claude/settings.json with absolute commands into
# a kit-owned tree that mirrors the repo layout, so the siblings resolve
# their lib and helpers unchanged. Claude matchers are regex alternation
# natively (Edit|MultiEdit|Write in one entry, proven live against claude
# before these entries were generated), unlike Muse one-entry-per-tool.
# shellcheck shell=bash

# Strict Claude settings reader/writer. Like the Muse writer this never
# repairs input: a malformed write bricks every claude command. Modes:
#   check <settings> <src> <tree>  print CREATE|MERGE|OK; refuse (exit 3,
#                                   reason on stderr) writing nothing.
#   apply <settings> <src> <tree>  atomic write after a deep-compare that
#                                   only our merged entries may add.
# Entries the plugin registration already covers (same event, matcher, and
# hook basename, e.g. a ${CLAUDE_PLUGIN_ROOT} command) are skipped with a
# warning on stderr: plugin users would otherwise fire twice, and the global
# copy cannot defer the way the Muse wrappers do.
CLAUDE_SETTINGS_PY='
import json, os, re, sys, tempfile

mode, path, src, tree = sys.argv[1:5]

def refuse(msg):
    print("refusing: " + msg, file=sys.stderr)
    sys.exit(3)

exists = os.path.exists(path)
data, created = {}, not exists
if exists:
    raw = open(path).read()
    if raw.strip():
        try:
            data = json.loads(raw)
        except Exception as exc:
            refuse("%s is not valid JSON (%s); left untouched" % (path, exc))
        if not isinstance(data, dict):
            refuse("%s top level is not a JSON object; left untouched" % path)
hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    refuse("%s hooks block is not an object; left untouched" % path)
if "CLAUDE_PLUGIN_ROOT" in json.dumps(hooks):
    print("warning: %s already has plugin-registered kit hooks; covered entries are skipped so they never double-fire" % path, file=sys.stderr)

doc = json.load(open(src))
canonical = []
for event, items in doc["hooks"].items():
    for item in items:
        for hook in item["hooks"]:
            m = re.search(r"/hooks/([A-Za-z0-9_-]+\.sh)", hook["command"])
            assert m, hook["command"]
            entry = {"matcher": item["matcher"]} if "matcher" in item else {}
            entry["hooks"] = [{"type": "command", "command": "KIT_GLOBAL_HOOK=1 exec \"%s/.claude/hooks/%s\"" % (tree, m.group(1))}]
            canonical.append((event, entry, m.group(1)))

adds = []
for event, entry, base in canonical:
    covered = False
    for have in hooks.get(event, []):
        if base in json.dumps(have) and have.get("matcher", "") == entry.get("matcher", ""):
            covered = True
            break
    if not covered:
        adds.append((event, entry))
action = "OK" if not adds and not created else ("CREATE" if created else "MERGE")
if mode == "check":
    print(action)
    sys.exit(0)
if not adds:
    print("%s already registers the kit hooks; unchanged" % path)
    sys.exit(0)
new = dict(data)
merged = {e: [dict(i) for i in items] for e, items in hooks.items()}
for event, entry in adds:
    merged.setdefault(event, []).append(entry)
new["hooks"] = merged
for k, v in data.items():
    if k == "hooks":
        for e, items in v.items():
            if merged.get(e, [])[:len(items)] != items:
                refuse("internal compare failed on hooks %r; %s untouched" % (e, path))
    elif k not in new or new[k] != v:
        refuse("internal compare failed on key %r; %s untouched" % (k, path))
if set(new) - set(data) - {"hooks"}:
    refuse("internal compare failed on new keys; %s untouched" % path)
d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".json")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(json.dumps(new, indent=2) + "\n")
    json.load(open(tmp))
    if exists:
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("%s %s (merged %d hook entries; formatting normalized to indent=2)" % ("created" if created else "updated", path, len(adds)))
'

install_hooks_global_claude() {
	local cfg settings tree
	cfg="$HOME/.claude"
	settings="$cfg/settings.json"
	tree="$cfg/agent-kit-hooks"
	echo "warning: global Claude hooks run in every workspace with no trust step; the hook tree is symlinks into this kit checkout ($KIT_DIR)" >&2
	command -v python3 >/dev/null 2>&1 || {
		echo "error: --hooks --global claude needs python3; nothing installed" >&2
		return 1
	}
	[ ! -L "$settings" ] || {
		echo "refusing: $settings is a symlink; merge the kit entries by hand" >&2
		return 1
	}
	python3 -c "$CLAUDE_SETTINGS_PY" check "$settings" "$KIT_DIR/hooks/hooks.json" "$tree" >/dev/null || return 1
	mkdir -p "$tree/.claude/hooks/lib"
	link_files "$KIT_DIR/hooks/*.sh" "$tree/.claude/hooks"
	link_files "$KIT_DIR/hooks/lib/*" "$tree/.claude/hooks/lib"
	prune_dir "$tree/.claude/hooks" "$KIT_DIR/hooks/*.sh"
	prune_dir "$tree/.claude/hooks/lib" "$KIT_DIR/hooks/lib/*"
	python3 -c "$CLAUDE_SETTINGS_PY" apply "$settings" "$KIT_DIR/hooks/hooks.json" "$tree" || return 1
	echo "installed global Claude hooks (merged into $settings)"
	echo "undo: delete the kit entries from $settings and remove $tree"
}

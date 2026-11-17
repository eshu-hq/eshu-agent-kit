# Global Muse hooks delivery (--hooks --global muse). Sourced by
# install.sh; extracted to keep the entrypoint under the 500-line cap, like
# install-aliases.sh. Registration is one settings key (managed_hooks_path)
# pointing at a kit-owned hooks file in a pseudo-root tree that mirrors the
# repo layout, so the same wrappers resolve their siblings unchanged.
# shellcheck shell=bash

muse_config_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/muse"; }

# Strict Muse settings reader/writer. Unlike the OpenCode JSONC merger in
# install.sh, this never repairs input: Muse settings are vendor-strict
# and a malformed write bricks every muse command. Modes:
#   check <settings> <managed-abs>  print CREATE|SET|OK; refuse (exit 3,
#                                   reason on stderr) writing nothing.
#   apply <settings> <managed-abs>  atomic write after a deep-compare that
#                                   only our two keys may differ.
# A settings "hooks" block already referencing the kit tree warns (stderr)
# in both modes: those entries would double-fire beside the managed file.
MUSE_SETTINGS_PY='
import json, os, sys, tempfile

mode, path, managed = sys.argv[1:4]

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
    sv = data.get("schema_version")
    if sv is not None and (isinstance(sv, bool) or sv != 1):
        refuse("%s has schema_version %r (only 1 is supported); left untouched" % (path, sv))
ptr = data.get("managed_hooks_path")
if ptr is not None and not isinstance(ptr, str):
    refuse("managed_hooks_path in %s is not a string (%r); left untouched" % (path, ptr))
if ptr is not None and ptr != managed:
    refuse("managed_hooks_path in %s already points at %s; not reclaiming it (remove that key or point it at %s by hand)" % (path, ptr, managed))
if "agent-kit-hooks" in json.dumps(data.get("hooks", "")):
    print("warning: %s already has hooks entries referencing the kit global tree; they will double-fire beside the managed file until removed" % path, file=sys.stderr)
action = "OK" if ptr == managed else ("CREATE" if created else "SET")
if mode == "check":
    print(action)
    sys.exit(0)
if action == "OK" and data.get("schema_version") == 1:
    print("%s already registers the kit hooks; unchanged" % path)
    sys.exit(0)
new = dict(data)
mutations = []
if new.get("schema_version") != 1:
    new["schema_version"] = 1
    mutations.append("set schema_version=1")
if ptr != managed:
    new["managed_hooks_path"] = managed
    mutations.append("set managed_hooks_path=%s" % managed)
allowed = {"schema_version", "managed_hooks_path"}
for k, v in data.items():
    if k not in new or new[k] != v:
        refuse("internal compare failed on key %r; %s untouched" % (k, path))
if set(new) - set(data) - allowed:
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
print("%s %s (%s; formatting normalized to indent=2)" % ("created" if created else "updated", path, ", ".join(mutations)))
'

# write_managed_hooks <managed-file> <tree> -- generate the managed hooks
# file from the project hooks.json with absolute wrapper commands, so entry
# parity holds by construction.
write_managed_hooks() {
	python3 - "$KIT_DIR/hooks/muse/hooks.json" "$1" "$2" <<'PYEOF'
import json, os, re, sys, tempfile

src, dest, tree = sys.argv[1:4]
doc = json.load(open(src))
for items in doc["hooks"].values():
    for item in items:
        for hook in item["hooks"]:
            m = re.search(r"/\.muse/hooks/([A-Za-z0-9_-]+\.sh)", hook["command"])
            assert m, hook["command"]
            hook["command"] = 'exec "%s/.muse/hooks/%s"' % (tree, m.group(1))
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".managed-", suffix=".json")
with os.fdopen(fd, "w") as fh:
    fh.write(json.dumps(doc, indent=2) + "\n")
os.replace(tmp, dest)
PYEOF
}

install_hooks_global_muse() {
	local cfg settings tree managed
	cfg="$(muse_config_dir)"
	settings="$cfg/settings.json"
	tree="$cfg/agent-kit-hooks"
	managed="$tree/managed-hooks.json"
	echo "warning: global Muse hooks run outside the Muse sandbox in every workspace, including untrusted ones, with no trust step; the hook tree is symlinks into this kit checkout ($KIT_DIR)" >&2
	command -v python3 >/dev/null 2>&1 || {
		echo "error: --hooks --global muse needs python3; nothing installed" >&2
		return 1
	}
	[ ! -L "$settings" ] || {
		echo "refusing: $settings is a symlink; point managed_hooks_path at $managed by hand" >&2
		return 1
	}
	python3 -c "$MUSE_SETTINGS_PY" check "$settings" "$managed" >/dev/null || return 1
	mkdir -p "$tree/.claude/hooks/lib" "$tree/.muse/hooks/lib"
	link_files "$KIT_DIR/hooks/*.sh" "$tree/.claude/hooks"
	link_files "$KIT_DIR/hooks/lib/*" "$tree/.claude/hooks/lib"
	link_files "$KIT_DIR/hooks/muse/*.sh" "$tree/.muse/hooks"
	link_files "$KIT_DIR/hooks/muse/lib/*" "$tree/.muse/hooks/lib"
	prune_dir "$tree/.claude/hooks" "$KIT_DIR/hooks/*.sh"
	prune_dir "$tree/.claude/hooks/lib" "$KIT_DIR/hooks/lib/*"
	prune_dir "$tree/.muse/hooks" "$KIT_DIR/hooks/muse/*.sh"
	prune_dir "$tree/.muse/hooks/lib" "$KIT_DIR/hooks/muse/lib/*"
	write_managed_hooks "$managed" "$tree"
	python3 -c "$MUSE_SETTINGS_PY" apply "$settings" "$managed" || return 1
	echo "installed global Muse hooks (managed_hooks_path -> $managed)"
	echo "undo: remove the managed_hooks_path key from $settings and delete $tree"
}

#!/usr/bin/env bash
# Behavioural mirror for install.sh --hooks --global muse.
#
# Global Muse hooks register through one settings key (managed_hooks_path)
# pointing at a kit-owned file in a pseudo-root tree under the Muse config
# dir. The settings writer is the dangerous surface -- a malformed write
# bricks every muse command -- so refusal cases assert byte-identical files
# and zero tree creation, and success cases assert deep preservation of
# unknown keys. Hermetic HOME + XDG_CONFIG_HOME per case.
set -uo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1"
	failed=$((failed + 1))
}

# run_install <home> <xdg> <args...> -- installer under a hermetic env.
run_install() {
	local h="$1" x="$2"
	shift 2
	HOME="$h" XDG_CONFIG_HOME="$x" "${kit}/install.sh" "$@" </dev/null
}
settings_of() { printf '%s/muse/settings.json' "$1"; }
tree_of() { printf '%s/muse/agent-kit-hooks' "$1"; }
key_is() { # file key expected -> 0 when settings[key] deep-equals expected JSON
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get(sys.argv[2]) == json.loads(sys.argv[3]) else 1)
' "$1" "$2" "$3" 2>/dev/null
}

# 1. Absent settings: created with exactly schema_version + pointer; tree and
# managed file land; managed commands are absolute into the tree.
h1="${work}/h1"
x1="${work}/x1"
run_install "$h1" "$x1" --hooks --global muse >/dev/null 2>&1 &&
	ok "global install succeeds without settings" || no "global install succeeds without settings"
want_ptr="\"$(tree_of "$x1")/managed-hooks.json\""
key_is "$(settings_of "$x1")" schema_version 1 && key_is "$(settings_of "$x1")" managed_hooks_path "$want_ptr" &&
	ok "created settings carry schema_version and the pointer" || no "created settings carry schema_version and the pointer"
[ "$(readlink "$(tree_of "$x1")/.muse/hooks/goal-refresh.sh")" = "${kit}/hooks/muse/goal-refresh.sh" ] &&
	[ "$(readlink "$(tree_of "$x1")/.claude/hooks/skill-nudge.sh")" = "${kit}/hooks/skill-nudge.sh" ] &&
	ok "pseudo-root mirrors wrappers and siblings as kit links" || no "pseudo-root mirrors wrappers and siblings as kit links"

# 2. Managed file parity with the project hooks.json: same 11
# (event, matcher, basename) entries, absolute commands, no repo discovery.
python3 - "$(tree_of "$x1")/managed-hooks.json" "${kit}/hooks/muse/hooks.json" "$(tree_of "$x1")" <<'PY' &&
import json, re, sys

managed, project, root = (json.load(open(p)) if i < 2 else p for i, p in enumerate(sys.argv[1:4]))


def entries(doc):
    out = set()
    for event, items in doc["hooks"].items():
        for item in items:
            for hook in item["hooks"]:
                m = re.search(r"/\.muse/hooks/([A-Za-z0-9_-]+\.sh)", hook["command"])
                out.add((event, item.get("matcher", ""), m.group(1) if m else hook["command"]))
    return out


me, pe = entries(managed), entries(project)
assert me == pe and len(me) == 11, (sorted(me ^ pe), len(me))
for items in managed["hooks"].values():
    for item in items:
        for hook in item["hooks"]:
            assert root in hook["command"], hook
            assert "git rev-parse" not in hook["command"], hook
            assert "guard-spawn" not in hook["command"] and "goal-role-router" not in hook["command"], hook
PY
	ok "managed file matches project entries with absolute commands" || no "managed file matches project entries with absolute commands"

# 3. Pointer-equal rerun is byte-idempotent on settings.
cp "$(settings_of "$x1")" "${work}/settings.after1"
run_install "$h1" "$x1" --hooks --global muse >/dev/null 2>&1
cmp -s "$(settings_of "$x1")" "${work}/settings.after1" &&
	ok "rerun leaves settings byte-identical" || no "rerun leaves settings byte-identical"

# 4. Unknown keys survive deep-equal; a missing schema_version is added.
h2="${work}/h2"
x2="${work}/x2"
mkdir -p "$x2/muse"
printf '{"model":"keep-me","tui":{"nested":[1,2,{"a":true}]}}\n' >"$(settings_of "$x2")"
run_install "$h2" "$x2" --hooks --global muse >/dev/null 2>&1
key_is "$(settings_of "$x2")" model '"keep-me"' && key_is "$(settings_of "$x2")" tui '{"nested":[1,2,{"a":true}]}' &&
	key_is "$(settings_of "$x2")" schema_version 1 &&
	ok "unknown keys preserved and schema_version added" || no "unknown keys preserved and schema_version added"

# 5. Refusals: every one leaves settings byte-identical, creates no tree,
# and exits nonzero. The pointer is never reclaimed from anyone else.
refuse() { # name setup-file-content
	local name="$1" content="$2" h="${work}/ref-$1" x="${work}/refx-$1"
	mkdir -p "$x/muse"
	printf '%s\n' "$content" >"$(settings_of "$x")"
	cp "$(settings_of "$x")" "$x/golden.json"
	if run_install "$h" "$x" --hooks --global muse >/dev/null 2>&1; then
		no "refuses $name"
		return
	fi
	cmp -s "$(settings_of "$x")" "$x/golden.json" && [ ! -e "$(tree_of "$x")" ] &&
		ok "refuses $name untouched" || no "refuses $name untouched"
}
refuse occupied '{"schema_version":1,"managed_hooks_path":"/elsewhere/hooks.json"}'
refuse nonstring '{"schema_version":1,"managed_hooks_path":123}'
refuse malformed '{"schema_version":1,,'
refuse toplevel '[1,2]'
refuse badschema '{"schema_version":2}'
# Symlinked settings: an atomic rename would clobber the link, so refuse.
hs="${work}/hsym"
xs="${work}/xsym"
mkdir -p "$xs/muse"
printf '{"schema_version":1}\n' >"$xs/real-settings.json"
ln -s "$xs/real-settings.json" "$(settings_of "$xs")"
if run_install "$hs" "$xs" --hooks --global muse >/dev/null 2>&1; then
	no "refuses symlinked settings untouched"
else
	[ -L "$(settings_of "$xs")" ] && [ "$(cat "$xs/real-settings.json")" = '{"schema_version":1}' ] && [ ! -e "$(tree_of "$xs")" ] &&
		ok "refuses symlinked settings untouched" || no "refuses symlinked settings untouched"
fi

# 6. Harness surface: muse exactly, nothing else, zero mutations on refusal.
for bad in "" claude all "muse extra"; do
	hb="${work}/hb"
	xb="${work}/xb"
	rm -rf "$hb" "$xb"
	if HOME="$hb" XDG_CONFIG_HOME="$xb" "${kit}/install.sh" --hooks --global $bad </dev/null >/dev/null 2>&1; then
		no "refuses --hooks --global '${bad}'"
	else
		[ ! -e "$xb" ] && ok "refuses --hooks --global '${bad}'" || no "refuses --hooks --global '${bad}'"
	fi
done

# 7. Other modes never install hooks: plain --global muse and
# --agents --global muse create neither tree nor settings change.
for mode in "--global" "--agents --global"; do
	hn="${work}/hn"
	xn="${work}/xn"
	rm -rf "$hn" "$xn"
	# shellcheck disable=SC2086 # mode words are the point
	run_install "$hn" "$xn" $mode muse >/dev/null 2>&1
	[ ! -e "$(tree_of "$xn")" ] && [ ! -e "$(settings_of "$xn")" ] &&
		ok "'$mode muse' installs no hooks" || no "'$mode muse' installs no hooks"
done

# 8. Prune applies to the global tree; --no-prune protects; unmarked survives.
ln -s "${kit}/hooks/muse/goal-refresh.sh" "$(tree_of "$x1")/.muse/hooks/stale-old.sh"
printf '# mine\n' >"$(tree_of "$x1")/.muse/hooks/mine.sh"
run_install "$h1" "$x1" --hooks --global muse >/dev/null 2>&1
[ ! -L "$(tree_of "$x1")/.muse/hooks/stale-old.sh" ] &&
	ok "stale global wrapper pruned" || no "stale global wrapper pruned"
[ "$(cat "$(tree_of "$x1")/.muse/hooks/mine.sh")" = "# mine" ] &&
	ok "unmarked file in global tree survives" || no "unmarked file in global tree survives"
ln -s "${kit}/hooks/muse/goal-refresh.sh" "$(tree_of "$x1")/.muse/hooks/stale-old.sh"
run_install "$h1" "$x1" --hooks --global muse --no-prune >/dev/null 2>&1 &&
	[ -L "$(tree_of "$x1")/.muse/hooks/stale-old.sh" ] &&
	key_is "$(settings_of "$x1")" managed_hooks_path "$want_ptr" &&
	ok "--no-prune runs the install and keeps the stale global wrapper" || no "--no-prune runs the install and keeps the stale global wrapper"

# 9. Without XDG_CONFIG_HOME the tree lands under ~/.config/muse.
h9="${work}/h9"
mkdir -p "$h9"
env -u XDG_CONFIG_HOME HOME="$h9" "${kit}/install.sh" --hooks --global muse </dev/null >/dev/null 2>&1
key_is "$h9/.config/muse/settings.json" managed_hooks_path "\"$h9/.config/muse/agent-kit-hooks/managed-hooks.json\"" &&
	ok "XDG-unset install lands under ~/.config/muse" || no "XDG-unset install lands under ~/.config/muse"

printf '\nglobal muse hooks mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

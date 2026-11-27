#!/usr/bin/env bash
# Behavioural mirror for install.sh --hooks --global claude.
#
# Global Claude hooks merge the 8 shared entries into ~/.claude/settings.json
# with absolute commands into a kit-owned tree, one settings key per entry
# (Claude has no managed_hooks_path). The settings writer is the dangerous
# surface -- a malformed write bricks every claude command -- so refusal cases
# assert byte-identical files and zero tree creation, success cases assert
# deep preservation of unknown and pre-existing hook entries, and plugin
# registration (${CLAUDE_PLUGIN_ROOT}) dedupes instead of double-firing.
# Hermetic HOME per case. Matcher alternation (Edit|MultiEdit|Write in a
# single entry) was proven live against claude before these entries were
# generated: one probe entry fired for both Write and Edit.
set -uo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
unset XDG_CONFIG_HOME

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

# run_install <home> <args...> -- installer under a hermetic HOME.
run_install() {
	local h="$1"
	shift
	HOME="$h" "${kit}/install.sh" "$@" </dev/null
}
settings_of() { printf '%s/.claude/settings.json' "$1"; }
tree_of() { printf '%s/.claude/agent-kit-hooks' "$1"; }
key_is() { # file key expected -> 0 when settings[key] deep-equals expected JSON
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get(sys.argv[2]) == json.loads(sys.argv[3]) else 1)
' "$1" "$2" "$3" 2>/dev/null
}

# 1. Absent settings: created with exactly the hooks block; tree and links
# land; commands are absolute into the tree behind KIT_GLOBAL_HOOK=1.
h1="${work}/h1"
mkdir -p "$h1"
run_install "$h1" --hooks --global claude >/dev/null 2>&1 &&
	ok "global install succeeds without settings" || no "global install succeeds without settings"
python3 - "$(settings_of "$h1")" "${kit}/hooks/hooks.json" "$(tree_of "$h1")" <<'PY' &&
import json, re, sys

settings, hooks_src, root = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
assert set(settings) == {"hooks"}, sorted(settings)
got, want = settings["hooks"], hooks_src["hooks"]
assert set(got) == set(want), (sorted(got), sorted(want))


def entries(doc):
    out = set()
    for event, items in doc.items():
        for item in items:
            for hook in item["hooks"]:
                m = re.search(r"/hooks/([A-Za-z0-9_-]+\.sh)", hook["command"])
                out.add((event, item.get("matcher", ""), m.group(1) if m else hook["command"]))
    return out


assert entries(got) == entries(want), "entry parity"
n = 0
for event, items in got.items():
    for item in items:
        for hook in item["hooks"]:
            n += 1
            assert hook["type"] == "command", hook
            base = re.search(r"/\.claude/hooks/([A-Za-z0-9_-]+\.sh)", hook["command"]).group(1)
            assert hook["command"] == 'KIT_GLOBAL_HOOK=1 exec "%s/.claude/hooks/%s"' % (root, base), hook
assert n == 10, n
PY
	ok "created settings carry the 10 entries with global commands" || no "created settings carry the 10 entries with global commands"
[ "$(readlink "$(tree_of "$h1")/.claude/hooks/skill-nudge.sh")" = "${kit}/hooks/skill-nudge.sh" ] &&
	[ "$(readlink "$(tree_of "$h1")/.claude/hooks/lib/skill-nudge-lib.sh")" = "${kit}/hooks/lib/skill-nudge-lib.sh" ] &&
	ok "pseudo-root mirrors siblings and lib as kit links" || no "pseudo-root mirrors siblings and lib as kit links"

# 2. Pointer-equal rerun is byte-identical on settings.
cp "$(settings_of "$h1")" "${work}/settings.after1"
run_install "$h1" --hooks --global claude >/dev/null 2>&1
cmp -s "$(settings_of "$h1")" "${work}/settings.after1" &&
	ok "rerun leaves settings byte-identical" || no "rerun leaves settings byte-identical"

# 3. Unknown keys and pre-existing user hook entries survive deep-equal.
h3="${work}/h3"
mkdir -p "$h3/.claude"
cat >"$(settings_of "$h3")" <<'EOF'
{"model":"keep-me","tui":{"nested":[1,2,{"a":true}]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/mine/guard.sh"}]}]}}
EOF
run_install "$h3" --hooks --global claude >/dev/null 2>&1
key_is "$(settings_of "$h3")" model '"keep-me"' && key_is "$(settings_of "$h3")" tui '{"nested":[1,2,{"a":true}]}' &&
	ok "unknown keys preserved" || no "unknown keys preserved"
python3 - "$(settings_of "$h3")" <<'PY' &&
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
mine = [i for i in hooks["PreToolUse"] if i.get("matcher") == "Bash" and any(h.get("command") == "/mine/guard.sh" for h in i["hooks"])]
assert len(mine) == 1 and len(mine[0]["hooks"]) == 1, hooks["PreToolUse"]
n = sum(len(i["hooks"]) for items in hooks.values() for i in items)
assert n == 11, n
PY
	ok "user hook entry kept verbatim beside the 10 merged" || no "user hook entry kept verbatim beside the 10 merged"

# 4. Refusals: every one leaves settings byte-identical, creates no tree,
# and exits nonzero.
refuse() { # name setup-content
	local name="$1" content="$2" h="${work}/ref-$1"
	mkdir -p "$h/.claude"
	printf '%s\n' "$content" >"$(settings_of "$h")"
	cp "$(settings_of "$h")" "$h/golden.json"
	if run_install "$h" --hooks --global claude >/dev/null 2>&1; then
		no "refuses $name"
		return
	fi
	cmp -s "$(settings_of "$h")" "$h/golden.json" && [ ! -e "$(tree_of "$h")" ] &&
		ok "refuses $name untouched" || no "refuses $name untouched"
}
refuse malformed '{"hooks":,'
refuse toplevel '[1,2]'
refuse nonobject-hooks '{"hooks":[]}'
# Symlinked settings: an atomic rename would clobber the link, so refuse.
hs="${work}/hsym"
mkdir -p "$hs/.claude"
printf '{"hooks":{}}\n' >"$hs/real-settings.json"
ln -s "$hs/real-settings.json" "$(settings_of "$hs")"
if run_install "$hs" --hooks --global claude >/dev/null 2>&1; then
	no "refuses symlinked settings untouched"
else
	[ -L "$(settings_of "$hs")" ] && [ "$(cat "$hs/real-settings.json")" = '{"hooks":{}}' ] && [ ! -e "$(tree_of "$hs")" ] &&
		ok "refuses symlinked settings untouched" || no "refuses symlinked settings untouched"
fi

# 5. Plugin dedupe: entries the plugin registration already covers are
# skipped with a warning, never duplicated; uncovered ones still merge.
h5="${work}/h5"
mkdir -p "$h5/.claude"
cat >"$(settings_of "$h5")" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Edit|MultiEdit|Write","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/skill-nudge.sh\""}]}]}}
EOF
err="$(run_install "$h5" --hooks --global claude 2>&1 >/dev/null)"
printf '%s\n' "$err" | rg -q "plugin-registered kit hooks" &&
	ok "plugin registration warns" || no "plugin registration warns"
python3 - "$(settings_of "$h5")" <<'PY' &&
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
pre = hooks["PreToolUse"]
assert len(pre) == 3, pre
assert sum('skill-nudge' in h.get("command", "") for i in pre for h in i["hooks"]) == 1, pre
n = sum(len(i["hooks"]) for items in hooks.values() for i in items)
assert n == 10, n
PY
	ok "plugin-covered entry deduped, other nine merged" || no "plugin-covered entry deduped, other nine merged"
cp "$(settings_of "$h5")" "${work}/settings.after5"
run_install "$h5" --hooks --global claude >/dev/null 2>&1
cmp -s "$(settings_of "$h5")" "${work}/settings.after5" &&
	ok "plugin-mixed rerun is byte-identical" || no "plugin-mixed rerun is byte-identical"

# 6. Harness surface: claude exactly, nothing else, zero mutations on refusal.
for bad in "" all "muse extra" "claude extra" "claude muse"; do
	hb="${work}/hb"
	rm -rf "$hb"
	# shellcheck disable=SC2086 # token-splitting the bad surface is the point
	if HOME="$hb" "${kit}/install.sh" --hooks --global $bad </dev/null >/dev/null 2>&1; then
		no "refuses --hooks --global '${bad}'"
	else
		[ ! -e "$hb" ] && ok "refuses --hooks --global '${bad}'" || no "refuses --hooks --global '${bad}'"
	fi
done

# 7. Other modes never install hooks: plain --global claude and
# --agents --global claude create neither tree nor settings change.
for mode in "--global" "--agents --global"; do
	hn="${work}/hn"
	rm -rf "$hn"
	# shellcheck disable=SC2086 # mode words are the point
	HOME="$hn" "${kit}/install.sh" $mode claude </dev/null >/dev/null 2>&1
	[ ! -e "$(tree_of "$hn")" ] && [ ! -e "$(settings_of "$hn")" ] &&
		ok "'$mode claude' installs no hooks" || no "'$mode claude' installs no hooks"
done

# 8. Prune applies to the global tree; --no-prune protects; unmarked survives.
ln -s "${kit}/hooks/skill-nudge.sh" "$(tree_of "$h1")/.claude/hooks/stale-old.sh"
printf '# mine\n' >"$(tree_of "$h1")/.claude/hooks/mine.sh"
run_install "$h1" --hooks --global claude >/dev/null 2>&1
[ ! -L "$(tree_of "$h1")/.claude/hooks/stale-old.sh" ] &&
	ok "stale global wrapper pruned" || no "stale global wrapper pruned"
[ "$(cat "$(tree_of "$h1")/.claude/hooks/mine.sh")" = "# mine" ] &&
	ok "unmarked file in global tree survives" || no "unmarked file in global tree survives"
ln -s "${kit}/hooks/skill-nudge.sh" "$(tree_of "$h1")/.claude/hooks/stale-old.sh"
run_install "$h1" --hooks --global claude --no-prune >/dev/null 2>&1 &&
	[ -L "$(tree_of "$h1")/.claude/hooks/stale-old.sh" ] &&
	python3 - "$(settings_of "$h1")" "$(tree_of "$h1")" <<'PY' &&
import json, sys
settings, root = json.load(open(sys.argv[1])), sys.argv[2]
n = sum(len(i["hooks"]) for items in settings["hooks"].values() for i in items)
assert n == 10, n
PY
	ok "--no-prune runs the install and keeps the stale wrapper" || no "--no-prune runs the install and keeps the stale wrapper"

# 9. The generated command shape gates repo code: with KIT_GLOBAL_HOOK=1 a
# seeded repo nudge table is never sourced and the doc checker never runs.
repo="${work}/pinned"
mkdir -p "$repo/.agents"
cp "${kit}/VERSION" "$repo/.agent-kit-version"
printf 'touch "%s/sourced-sentinel"\n' "$repo" >"$repo/.agents/nudge-table.sh"
cmd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$(settings_of "$h1")")"
[ "${cmd#KIT_GLOBAL_HOOK=1 exec }" != "$cmd" ] &&
	ok "generated command carries the global flag" || no "generated command carries the global flag"
printf '{"session_id":"abcdefghijkl","tool_input":{"file_path":"%s/x.go"}}\n' "$repo" |
	(eval "$cmd" >/dev/null 2>&1)
[ ! -e "$repo/sourced-sentinel" ] &&
	ok "global skill-nudge never sources the repo table" || no "global skill-nudge never sources the repo table"

printf '\nglobal claude hooks mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

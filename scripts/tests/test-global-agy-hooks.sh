#!/usr/bin/env bash
# Behavioural mirror for the Antigravity (agy) hooks installer:
#   ./install.sh --hooks --repo DIR        -> DIR/.agents/hooks.json + DIR/.agy/hooks
#   ./install.sh --hooks --global agy      -> ~/.gemini/config/hooks.json + tree
#   ./install.sh --uninstall --hooks ...   -> remove only what the kit proves it owns
#
# agy hooks.json is NAME-keyed: the kit owns exactly one key, eshu-agent-kit,
# and merges it. The writer is the dangerous surface, so every refusal case
# asserts a byte-identical file and no agy tree, success cases assert foreign
# keys survive in order, and a re-run is byte-identical. Hermetic HOME,
# XDG_DATA_HOME, XDG_CONFIG_HOME and TMPDIR per case.
set -uo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
unset KIT_GLOBAL_HOOK KIT_HARNESS ESHU_SKILLS_TELEMETRY_OFF

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
check() { # description command...
	local d="$1"
	shift
	if "$@"; then ok "$d"; else no "$d"; fi
}

cases=0
fresh() { # new hermetic env; sets B (case dir), R (repo), G (global hooks.json)
	cases=$((cases + 1))
	B="${work}/c${cases}"
	export HOME="${B}/home" XDG_DATA_HOME="${B}/xdg" XDG_CONFIG_HOME="${B}/cfg" TMPDIR="${B}/tmp"
	R="${B}/repo"
	G="${HOME}/.gemini/config/hooks.json"
	mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${TMPDIR}" "${R}"
	git -C "${R}" init -q
}
inst() { "${kit}/install.sh" "$@" </dev/null >"${B}/out" 2>"${B}/err"; }
sum() { cksum <"$1"; }
keys() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))))' "$1"; }
key_equals_template() { # file -- the kit key equals the shipped template (repo scope)
	python3 - "$1" "${kit}/hooks/agy/hooks.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))["eshu-agent-kit"] == json.load(open(sys.argv[2]))["eshu-agent-kit"] else 1)
PY
}
no_agy_tree() { [ ! -e "${R}/.agy/hooks" ]; }
refused() { rg -q 'refusing' "${B}/err"; }

# 1. Repo, no file: created, key equals the shipped template, wrappers linked.
fresh
inst --hooks --repo "${R}"
check "repo install creates .agents/hooks.json with only the kit key" test "$(keys "${R}/.agents/hooks.json")" = eshu-agent-kit
check "repo kit key equals hooks/agy/hooks.json" key_equals_template "${R}/.agents/hooks.json"
check "wrappers and lib are kit links under .agy/hooks" test "$(readlink "${R}/.agy/hooks/skill-nudge.sh")" = "${kit}/hooks/agy/skill-nudge.sh" -a "$(readlink "${R}/.agy/hooks/lib/agy-translate.py")" = "${kit}/hooks/agy/lib/agy-translate.py"
check "the .claude/hooks siblings are linked too" test -L "${R}/.claude/hooks/goal-continue.sh"

# 2. Merge keeps foreign keys, their values and their order; kit key is appended.
fresh
mkdir -p "${R}/.agents"
printf '{"lint":{"PostToolUse":[{"matcher":"run_command","hooks":[{"command":"./lint.sh"}]}]},"zz":{"enabled":false}}\n' >"${R}/.agents/hooks.json"
inst --hooks --repo "${R}"
check "merge appends the kit key after the foreign keys" test "$(keys "${R}/.agents/hooks.json")" = lint,zz,eshu-agent-kit
check "merge leaves foreign values untouched" python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["lint"]["PostToolUse"][0]["hooks"][0]["command"] == "./lint.sh" and d["zz"] == {"enabled": False}' "${R}/.agents/hooks.json"

# 3. Re-run is byte-identical.
before="$(sum "${R}/.agents/hooks.json")"
inst --hooks --repo "${R}"
check "re-run leaves the file byte-identical" test "$(sum "${R}/.agents/hooks.json")" = "${before}"

# 4. Each refusal leaves the file byte-identical, installs no agy tree, exits 0 for the rest.
refusal() { # name content-writer-fn
	fresh
	mkdir -p "${R}/.agents"
	"$2" "${R}/.agents/hooks.json"
	local b
	b="$(sum "${R}/.agents/hooks.json")"
	inst --hooks --repo "${R}"
	check "refuse ${1}: file byte-identical" test "$(sum "${R}/.agents/hooks.json")" = "${b}"
	check "refuse ${1}: says refusing and installs no agy tree" bash -c "$(declare -f refused no_agy_tree); B='${B}' R='${R}'; refused && no_agy_tree"
}
w_invalid() { printf '{"a": ' >"$1"; }
w_array() { printf '[]\n' >"$1"; }
w_bom() { printf '\xef\xbb\xbf{}\n' >"$1"; }
w_dupe() { printf '{"a":1,"a":2}\n' >"$1"; }
w_empty() { : >"$1"; }
w_foreign() { printf '{"eshu-agent-kit":{"PreToolUse":[{"matcher":"x","hooks":[{"command":"./mine.sh"}]}]}}\n' >"$1"; }
w_usermine() { printf '{"eshu-agent-kit":{"Stop":[{"command":"/home/x/.agy/hooks/mine.sh"}]}}\n' >"$1"; }
w_disabled() { printf '{"eshu-agent-kit":{"enabled":false}}\n' >"$1"; }
w_symlink() { printf '{}\n' >"$1.real" && ln -s "$1.real" "$1"; }
refusal "invalid JSON" w_invalid
refusal "non-object top level" w_array
refusal "a byte-order mark" w_bom
refusal "duplicate keys" w_dupe
refusal "an empty file" w_empty
refusal "a foreign eshu-agent-kit key" w_foreign
refusal "a user key whose command only mentions .agy/hooks/" w_usermine
refusal "a disabled kit key with no kit commands" w_disabled
refusal "a symlinked hooks.json" w_symlink
check "a symlinked hooks.json target stays untouched" test "$(cat "${R}/.agents/hooks.json.real")" = "{}"

# 5. A stale kit key (every command into a kit .agy/hooks/ path) is replaced in place.
fresh
mkdir -p "${R}/.agents"
printf '{"first":{},"eshu-agent-kit":{"Stop":[{"type":"command","command":"h=../.agy/hooks/old.sh; [ -x \\"$h\\" ] || { printf '"'"'{}'"'"'; exit 0; }; exec \\"$h\\""}]},"last":{}}\n' >"${R}/.agents/hooks.json"
inst --hooks --repo "${R}"
check "a differing kit key is replaced, order kept" test "$(keys "${R}/.agents/hooks.json")" = first,eshu-agent-kit,last
check "the replaced key equals the template" key_equals_template "${R}/.agents/hooks.json"

# 5b. A hooks.json written by the earlier release (fallback printed {}, which agy
# treats as a PreToolUse deny) is upgraded by a re-run and removed by uninstall.
legacy_key() { # rewrite the installed kit key to the earlier fallback shape
	python3 - "$1" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for groups in d["eshu-agent-kit"].values():
    for g in groups:
        for h in g["hooks"] if isinstance(g.get("hooks"), list) else [g]:
            assert "|| exit 0;" in h["command"]
            h["command"] = h["command"].replace("|| exit 0;", "|| { printf '{}'; exit 0; };")
json.dump(d, open(p, "w"), indent=2)
PY
}
fresh
inst --hooks --repo "${R}"
legacy_key "${R}/.agents/hooks.json"
inst --hooks --repo "${R}"
check "a legacy-shape kit key is upgraded to the empty-neutral commands" key_equals_template "${R}/.agents/hooks.json"
check "the upgraded key no longer prints {} anywhere" bash -c "! rg -q \"printf\" '${R}/.agents/hooks.json'"
legacy_key "${R}/.agents/hooks.json"
inst --uninstall --hooks --repo "${R}"
check "uninstall removes a legacy-shape kit key it generated" test ! -e "${R}/.agents/hooks.json"

# 6. Prune: a stale kit link under .agy/hooks goes on re-run.
fresh
inst --hooks --repo "${R}"
ln -s "${kit}/hooks/agy/retired.sh" "${R}/.agy/hooks/retired.sh"
inst --hooks --repo "${R}"
check "re-run prunes a stale kit link" test ! -L "${R}/.agy/hooks/retired.sh"

# 7. Repo uninstall: owned key + file go; foreign keys stay; modified key is kept.
fresh
inst --hooks --repo "${R}"
inst --uninstall --hooks --repo "${R}"
check "uninstall deletes hooks.json when only the kit key was there" test ! -e "${R}/.agents/hooks.json"
check "uninstall removes the agy links and empty dirs" test ! -e "${R}/.agy"
fresh
mkdir -p "${R}/.agents"
printf '{"lint":{"enabled":true}}\n' >"${R}/.agents/hooks.json"
inst --hooks --repo "${R}"
inst --uninstall --hooks --repo "${R}"
check "uninstall keeps foreign keys and drops only the kit key" test "$(keys "${R}/.agents/hooks.json")" = lint
fresh
inst --hooks --repo "${R}"
python3 - "${R}/.agents/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["eshu-agent-kit"]["Stop"][0]["timeout"] = 99
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
b="$(sum "${R}/.agents/hooks.json")"
inst --uninstall --hooks --repo "${R}"
check "uninstall keeps a modified kit key and says so" bash -c "[ \"\$(cksum <'${R}/.agents/hooks.json')\" = '${b}' ] && rg -q 'modified eshu-agent-kit key' '${B}/err'"

# 8. Global: create, absolute commands with KIT_GLOBAL_HOOK=1, tree links, warning.
fresh
inst --hooks --global agy
tree="${HOME}/.gemini/config/agent-kit-hooks"
check "global install creates ~/.gemini/config/hooks.json with only the global key" test "$(keys "${G}")" = eshu-agent-kit-global
check "global commands are absolute into the tree with KIT_GLOBAL_HOOK=1" python3 - "${G}" "${tree}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))["eshu-agent-kit-global"]
cmds = [h["command"] for g in doc["PreToolUse"] + doc["PostToolUse"] for h in g["hooks"]] + [h["command"] for h in doc["Stop"]]
assert len(cmds) == 4, cmds
for c in cmds:
    assert "h=%s/.agy/hooks/" % sys.argv[2] in c and "KIT_GLOBAL_HOOK=1 exec" in c, c
assert [h["timeout"] for h in doc["Stop"]] == [30] and all(h["timeout"] == 10 for g in doc["PreToolUse"] + doc["PostToolUse"] for h in g["hooks"])
PY
check "global tree links siblings and wrappers into the kit" test "$(readlink "${tree}/.claude/hooks/skill-nudge.sh")" = "${kit}/hooks/skill-nudge.sh" -a "$(readlink "${tree}/.agy/hooks/goal-continue.sh")" = "${kit}/hooks/agy/goal-continue.sh"
check "global install warns about the missing trust step" rg -q 'no trust step' "${B}/err"
b="$(sum "${G}")"
inst --hooks --global agy
check "global re-run is byte-identical" test "$(sum "${G}")" = "${b}"
python3 - "${G}" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for groups in d["eshu-agent-kit-global"].values():
    for g in groups:
        for h in g["hooks"] if isinstance(g.get("hooks"), list) else [g]:
            h["command"] = h["command"].replace("|| exit 0;", "|| { printf '{}'; exit 0; };")
json.dump(d, open(p, "w"), indent=2)
PY
inst --hooks --global agy
check "a legacy-shape global key is upgraded by a re-run" bash -c "! rg -q printf '${G}'"

# 8b. Global merge keeps foreign keys; global refusals write nothing.
fresh
mkdir -p "${HOME}/.gemini/config"
printf '{"mine":{"Stop":[]}}\n' >"${G}"
inst --hooks --global agy
check "global merge keeps foreign keys in order" test "$(keys "${G}")" = mine,eshu-agent-kit-global
fresh
mkdir -p "${HOME}/.gemini/config"
printf 'not json' >"${G}"
b="$(sum "${G}")"
inst --hooks --global agy
rc=$?
check "global refusal exits non-zero with the file byte-identical" test "${rc}" -ne 0 -a "$(sum "${G}")" = "${b}"
check "global refusal creates no tree" test ! -e "${HOME}/.gemini/config/agent-kit-hooks"

# 8c. A repo-named `eshu-agent-kit` key in the global file is foreign: install keeps it and uninstall leaves it.
fresh
mkdir -p "${HOME}/.gemini/config"
printf '{"eshu-agent-kit":{"Stop":[]}}\n' >"${G}"
inst --hooks --global agy
check "global install keeps a foreign eshu-agent-kit key beside the global key" test "$(keys "${G}")" = eshu-agent-kit,eshu-agent-kit-global
check "the foreign eshu-agent-kit key is untouched" test "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["eshu-agent-kit"]))' "${G}")" = '{"Stop": []}'
inst --uninstall --hooks --global agy
check "global uninstall leaves the foreign eshu-agent-kit key" test "$(keys "${G}")" = eshu-agent-kit

# 9. Global uninstall: key + file + tree go; foreign keys stay.
fresh
inst --hooks --global agy
inst --uninstall --global agy
broad_keeps() { [ -d "${HOME}/.gemini/config/agent-kit-hooks" ] && [ -f "${G}" ] && rg -q 'run --uninstall --hooks --global agy' "${B}/err"; }
check "a broad global uninstall keeps the hooks and points at the explicit undo" broad_keeps
inst --uninstall --hooks --global agy
check "global uninstall deletes the file and the tree" test ! -e "${G}" -a ! -e "${HOME}/.gemini/config/agent-kit-hooks"
fresh
mkdir -p "${HOME}/.gemini/config"
printf '{"mine":{"Stop":[]}}\n' >"${G}"
inst --hooks --global agy
inst --uninstall --hooks --global agy
check "global uninstall keeps foreign keys" test "$(keys "${G}")" = mine

# 10. Global plus repo: the global copy always fires; the repo copy stands down on an exact global install.
fresh
inst --hooks --repo "${R}"
inst --hooks --global agy
sid="agyg0001-0000-0000-0000-000000000001"
trap 'rm -rf "${work}"; rm -f /tmp/claude-skill-loaded-agyg0001-000-*' EXIT
payload() { # <cwd>
	printf '{"conversationId":"%s","cwd":"%s","hookEventName":"PostToolUse","toolCall":{"name":"read_file","args":{"Path":"/w/skills/publish/SKILL.md"}}}' "${sid}" "$1"
}
events() { [ -f "${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl" ] && wc -l <"${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl" | tr -d ' ' || echo 0; }
cmd_of() { # <hooks.json> <key> -> the skill-loaded command
	python3 -c '
import json, sys
for g in json.load(open(sys.argv[1]))[sys.argv[2]]["PostToolUse"]:
    print(g["hooks"][0]["command"])' "$1" "$2"
}
(cd "${HOME}/.gemini/config" && payload "${R}" | sh -c "$(cmd_of "${G}" eshu-agent-kit-global)" >"${B}/g.out" 2>/dev/null)
check "the global copy fires inside a repo that registers the kit key" test "$(events)" = 1 -a -z "$(cat "${B}/g.out")"
(cd "${R}/.agents" && payload "${R}" | sh -c "$(cmd_of "${R}/.agents/hooks.json" eshu-agent-kit)" >"${B}/r.out" 2>/dev/null)
check "the repo copy stands down beside an exact global install (still one event)" test "$(events)" = 1 -a -z "$(cat "${B}/r.out")"
mkdir -p "${B}/plain"
(cd "${HOME}/.gemini/config" && payload "${B}/plain" | sh -c "$(cmd_of "${G}" eshu-agent-kit-global)" >"${B}/g2.out" 2>/dev/null)
check "the global copy fires in a workspace without the key" test "$(events)" = 2 -a -z "$(cat "${B}/g2.out")"
check "both events are attributed to harness agy" test "$(rg -c '"harness": "agy"' "${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl")" = 2
# Repo alone fires once; a hand-edited global entry makes the repo copy fire too (two events: fail toward firing).
fresh
inst --hooks --repo "${R}"
(cd "${R}/.agents" && payload "${R}" | sh -c "$(cmd_of "${R}/.agents/hooks.json" eshu-agent-kit)" >/dev/null 2>&1)
check "the repo copy alone fires once" test "$(events)" = 1
inst --hooks --global agy
python3 - "${G}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["eshu-agent-kit-global"]["PostToolUse"][0]["matcher"] = "view_file"
json.dump(d, open(sys.argv[1], "w"))
PY
(cd "${R}/.agents" && payload "${R}" | sh -c "$(cmd_of "${R}/.agents/hooks.json" eshu-agent-kit)" >/dev/null 2>&1)
check "a hand-edited global entry makes the repo copy fire too" test "$(events)" = 2

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]

#!/usr/bin/env bash
# Behavioural suite for the Antigravity (agy) hook adapters in hooks/agy/.
#
# agy speaks camelCase JSON on stdin and JSON on stdout; the kit siblings
# under .claude/hooks block with exit 2 + stderr, which agy does not read.
# So every adapter must translate in and out, print at most one JSON object
# and exit 0 -- including on garbage input, a missing sibling and a missing
# python3. Neutral is EMPTY stdout (live: agy 1.5.18 treats a PreToolUse `{}` as
# a deny); "allow" is never emitted (agy defines it as an
# automatic approval that would bypass the user's permission prompts).
#
# Cases run the real command string from the installed .agents/hooks.json
# (cwd = the directory holding it, the way agy runs it) against payloads
# built from hooks/tests/testdata/agy-*.json. Those four fixtures are
# SYNTHETIC (vendor doc envelope + transcript arg names), not live captures.
# Hermetic HOME, XDG_DATA_HOME, XDG_CONFIG_HOME and TMPDIR per case.
set -uo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
td="${kit}/hooks/tests/testdata"
work="$(mktemp -d)"
sid="agyt0001-0000-0000-0000-000000000001"
sid12="${sid:0:12}"
trap 'rm -rf "${work}"; rm -f /tmp/claude-skill-loaded-agyt0001-000-*' EXIT
unset CLAUDE_GOAL_FILE CLAUDE_GOAL_OFF CLAUDE_GOAL_CONSENT CLAUDE_GOAL_MAX_NUDGES KIT_GLOBAL_HOOK KIT_HARNESS ESHU_SKILLS_TELEMETRY_OFF

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
fresh() { # new hermetic env + clean markers
	cases=$((cases + 1))
	local b="${work}/c${cases}"
	export HOME="${b}/home" XDG_DATA_HOME="${b}/xdg" XDG_CONFIG_HOME="${b}/cfg" TMPDIR="${b}/tmp"
	mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${TMPDIR}"
	LOG="${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"
	rm -f /tmp/claude-skill-loaded-agyt0001-000-*
}

repo="${work}/repo"
mkdir -p "${repo}/sub"
git -C "${repo}" init -q
(HOME="${work}/ih" "${kit}/install.sh" --hooks --repo "${repo}" >/dev/null 2>&1)

# pl <fixture> [python-statements-on-d] -- a payload with SID/REPO filled in.
pl() {
	PL_SID="${sid}" PL_REPO="${repo}" python3 -c '
import json, os, sys
raw = open(sys.argv[1]).read().replace("SID", os.environ["PL_SID"]).replace("REPO", os.environ["PL_REPO"])
d = json.loads(raw)
exec(sys.argv[2] if len(sys.argv) > 2 else "")
print(json.dumps(d))
' "${td}/$1" "${2:-}"
}

# hook_cmd <root> <name> -- the hooks.json command that runs <name>.sh.
hook_cmd() {
	python3 -c '
import json, sys
doc = json.load(open(sys.argv[1] + "/.agents/hooks.json"))["eshu-agent-kit"]
for groups in doc.values():
    for g in groups:
        for h in g.get("hooks", [g]):
            if "/" + sys.argv[2] + ".sh" in h["command"]:
                print(h["command"]); raise SystemExit(0)
raise SystemExit(1)
' "$1" "$2"
}

# run <name> <payload> -- run the installed hook the way agy does.
run() {
	local cmd
	cmd="$(hook_cmd "${repo}" "$1")" || {
		out=""
		rc=99
		return
	}
	out="$(cd "${repo}/.agents" && printf '%s' "$2" | sh -c "${cmd}" 2>"${work}/err")"
	rc=$?
}
one_json() { # stdout is exactly one JSON object
	python3 -c 'import json,sys; sys.exit(0 if isinstance(json.loads(sys.stdin.read()), dict) else 1)' <<<"${out}" 2>/dev/null
}
is_neutral() { [ -z "${out}" ] && [ "${rc}" -eq 0 ]; }
quiet_neutral() { [ ! -s "${LOG}" ] && is_neutral; }
reason_has() { field reason | rg -q -- "$1"; }
reason_lacks() { ! reason_has "$1"; }
no_allow() { ! printf '%s' "${out}" | rg -q allow; }
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$1" <<<"${out}" 2>/dev/null; }
ev_count() { # type [skill]
	python3 - "${LOG}" "$1" "${2:-}" <<'PY' 2>/dev/null || echo 0
import json, sys
log, typ, skill = sys.argv[1:4]
n = 0
for line in open(log):
    e = json.loads(line)
    if e["harness"] == "agy" and e["type"] == typ and (not skill or e["detail"].get("skill") == skill):
        n += 1
print(n)
PY
}

# 1. PostToolUse: a SKILL.md read records one agy skill-load and the marker.
fresh
run skill-loaded "$(pl agy-posttool-read.json)"
check "skill read is empty (never allow)" is_neutral
check "skill read logs one agy skill-load event" test "$(ev_count skill-load golang-engineering)" = 1
check "skill read writes the shared marker" test -f "/tmp/claude-skill-loaded-${sid12}-golang-engineering"
check "skill-load event session is the conversation id prefix" rg -q "\"session\": \"${sid12}\"" "${LOG}"

# 1b. view_file / AbsolutePath, and a JSON-quoted path (agy transcripts quote some args).
fresh
run skill-loaded "$(pl agy-posttool-read.json 'a = d["toolCall"]; a["name"] = "view_file"; a["args"] = {"AbsolutePath": "/w/skills/publish/SKILL.md"}')"
check "view_file with AbsolutePath counts" test "$(ev_count skill-load publish)" = 1
fresh
run skill-loaded "$(pl agy-posttool-read.json 'd["toolCall"]["args"]["Path"] = json.dumps("/w/skills/code-review/SKILL.md")')"
check "a JSON-quoted Path counts" test "$(ev_count skill-load code-review)" = 1

# 2. Reads that are not skill loads write nothing.
for p in '"/w/src/main.go"' '"/w/skills/publish/README.md"' '"/w/skills/SKILL.md"' '"/w/notskills/x/SKILL.md"'; do
	fresh
	run skill-loaded "$(pl agy-posttool-read.json "d['toolCall']['args']['Path'] = ${p}")"
	check "non-skill read ${p} logs nothing and prints nothing" quiet_neutral
done
fresh
run skill-loaded "$(pl agy-posttool-read.json 'd["toolCall"]["name"] = "edit_file"')"
check "a non-read tool never counts as a load" quiet_neutral
fresh
run skill-loaded "$(pl agy-posttool-read.json 'd["error"] = "no such file"')"
check "a failed read is not a load" quiet_neutral

# 3. PreToolUse skill-nudge: deny until the skill is loaded, then neutral.
fresh
run skill-nudge "$(pl agy-pretool-edit.json)"
check "nudge deny prints one JSON object and exits 0" one_json
check "nudge deny sets decision deny" test "$(field decision)" = deny
check "nudge deny carries the sibling reason" reason_has golang-engineering
check "nudge deny tells the model to read_file the SKILL.md" reason_has read_file
check "nudge deny logs one nudge-block event with harness agy" test "$(ev_count nudge-block)" = 1
run skill-loaded "$(pl agy-posttool-read.json)"
run skill-nudge "$(pl agy-pretool-edit.json)"
check "nudge is neutral once the skill read is recorded" is_neutral
check "no adapter ever emits decision allow" no_allow
fresh
run skill-nudge "$(pl agy-pretool-edit.json 'd["toolCall"]["args"]["Path"] = "sub/y.go"')"
check "relative Path is joined to cwd before the table lookup" test "$(field decision)" = deny
run skill-nudge "$(pl agy-pretool-edit.json 'd["toolCall"]["name"] = "write_file"')"
check "write_file is covered too" test "$(field decision)" = deny
run skill-nudge "$(pl agy-pretool-edit.json 'd["toolCall"]["args"]["Path"] = "/elsewhere/x.txt"')"
check "an ungoverned path is neutral" is_neutral

# 4. PreToolUse guard-live-gate: deny while a live stack holds a probed port.
fresh
run guard-live-gate "$(pl agy-pretool-command.json 'd["toolCall"]["args"]["CommandLine"] = "make build"')"
check "an unguarded command is neutral" is_neutral
mkdir -p "${repo}/.agents/skills/code-review"
if command -v lsof >/dev/null 2>&1; then
	python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 &
	srv=$!
	sleep 1
	if lsof -nP -iTCP:18080 -sTCP:LISTEN >/dev/null 2>&1; then
		run guard-live-gate "$(pl agy-pretool-command.json)"
		check "live gate deny prints one JSON object" one_json
		check "live gate deny sets decision deny" test "$(field decision)" = deny
		check "live gate deny carries the port reason" reason_has 'port 18080'
		check "live gate deny has no skill-tool guidance" reason_lacks read_file
	else
		printf 'skip - live gate deny (could not bind 18080)\n'
	fi
	kill "${srv}" 2>/dev/null
	wait "${srv}" 2>/dev/null
else
	printf 'skip - live gate deny (needs lsof and python3)\n'
fi

# 5. Stop: continue while a goal is open, neutral otherwise.
goalf="${repo}/.claude/active-goal.${sid}"
printf 'SESSION: %s\nFinish the migration.\n' "${sid}" >"${goalf}"
fresh
run goal-continue "$(pl agy-stop.json)"
check "open goal continues the turn" test "$(field decision)" = continue
check "continue carries the goal text as reason" reason_has 'Finish the migration'
check "continue logs a goal-continued event with harness agy" test "$(ev_count goal-continued)" = 1
run goal-continue "$(pl agy-stop.json 'd["terminationReason"] = "MAX_INVOCATIONS"')"
check "a non-NO_TOOL_CALL stop is neutral" is_neutral
run goal-continue "$(pl agy-stop.json 'del d["continuationActive"]')"
check "missing continuationActive (agy < 1.5.6) is neutral" is_neutral
CLAUDE_GOAL_MAX_NUDGES=0 run goal-continue "$(pl agy-stop.json)"
check "an exhausted budget releases with empty output" is_neutral
printf 'DONE\nFinished.\n' >"${goalf}"
run goal-continue "$(pl agy-stop.json)"
check "a DONE goal releases with empty output" is_neutral
rm -f "${goalf}"
run goal-continue "$(pl agy-stop.json)"
check "no goal releases with empty output" is_neutral

# 5b. Turn id: minted when continuationActive is false, reused while true.
printf 'SESSION: %s\nFinish the migration.\n' "${sid}" >"${goalf}"
fresh
nfiles() { find "${TMPDIR}" -maxdepth 1 -name 'claude-goal-nudge-*' | wc -l | tr -d ' '; }
run goal-continue "$(pl agy-stop.json)"
a="$(nfiles)"
run goal-continue "$(pl agy-stop.json 'd["continuationActive"] = True')"
b="$(nfiles)"
run goal-continue "$(pl agy-stop.json)"
c="$(nfiles)"
check "continuationActive true reuses the turn id; false starts a new one" test "${a}/${b}/${c}" = "1/1/2"
rm -f "${goalf}"

# 6. Failure safety: every path exits 0 and prints no verdict (never a deny).
fresh
for w in skill-loaded skill-nudge guard-live-gate goal-continue; do
	for junk in 'garbage' '' '[]' '{"toolCall":"x"}' 'null'; do
		run "${w}" "${junk}"
		check "${w}: payload '${junk}' -> neutral (empty)" is_neutral
	done
done
repo2="${work}/repo2"
mkdir -p "${repo2}"
git -C "${repo2}" init -q
(HOME="${work}/ih" "${kit}/install.sh" --hooks --repo "${repo2}" >/dev/null 2>&1)
rm -f "${repo2}/.claude/hooks/skill-nudge.sh"
out="$(cd "${repo2}/.agents" && pl agy-pretool-edit.json | sh -c "$(hook_cmd "${repo2}" skill-nudge)" 2>/dev/null)"
rc=$?
check "a missing .claude sibling is neutral" is_neutral
rm -f "${repo2}/.agy/hooks/skill-nudge.sh"
# From a file, not a pipe: the fallback exits without reading stdin, and a pipe
# writer would die of SIGPIPE under pipefail.
pl agy-pretool-edit.json >"${work}/missing-wrapper.json"
out="$(cd "${repo2}/.agents" && sh -c "$(hook_cmd "${repo2}" skill-nudge)" <"${work}/missing-wrapper.json" 2>/dev/null)"
rc=$?
check "a missing wrapper prints nothing from the hooks.json command itself" is_neutral
for w in skill-loaded skill-nudge guard-live-gate goal-continue; do
	rm -rf "${work}/nolib" && mkdir -p "${work}/nolib/lib" && cp "${repo}/.agy/hooks/${w}.sh" "${work}/nolib/${w}.sh"
	# A file, not a pipe: the wrapper exits without reading stdin, and a pipe
	# writer would die of SIGPIPE under pipefail.
	pl agy-pretool-edit.json >"${work}/nolib/payload.json"
	out="$("${work}/nolib/${w}.sh" <"${work}/nolib/payload.json" 2>/dev/null)"
	rc=$?
	check "${w}: a lib/ without agy-root.sh prints nothing and exits 0" is_neutral
done
nopy="${work}/nopy"
mkdir -p "${nopy}"
for t in bash sh cat dirname rm mkdir mktemp env; do ln -sf "$(command -v "${t}")" "${nopy}/${t}"; done
out="$(cd "${repo}/.agents" && pl agy-pretool-edit.json | PATH="${nopy}" sh -c "$(hook_cmd "${repo}" skill-nudge)" 2>/dev/null)"
rc=$?
check "a missing python3 is neutral" is_neutral

# 7. The GLOBAL copy always fires: it never reads the workspace it runs in.
fresh
out="$(pl agy-posttool-read.json | (cd "${repo}/.agents" && KIT_GLOBAL_HOOK=1 sh -c "$(hook_cmd "${repo}" skill-loaded)") 2>/dev/null)"
rc=$?
check "global copy fires even when the workspace registers eshu-agent-kit" test "$(ev_count skill-load golang-engineering)" = 1
fresh
plain="${work}/plain"
mkdir -p "${plain}"
out="$(pl agy-posttool-read.json 'd["cwd"] = "'"${plain}"'"; d["workspacePaths"] = ["'"${plain}"'"]' | (cd "${repo}/.agents" && KIT_GLOBAL_HOOK=1 sh -c "$(hook_cmd "${repo}" skill-loaded)") 2>/dev/null)"
check "global copy fires in a workspace without the key" test "$(ev_count skill-load golang-engineering)" = 1

# 7b. A substitute workspace wrapper cannot silence the global copy.
fresh
repo4="${work}/repo4"
mkdir -p "${repo4}"
git -C "${repo4}" init -q
(HOME="${work}/ih" "${kit}/install.sh" --hooks --repo "${repo4}" >/dev/null 2>&1)
rm -f "${repo4}/.agy/hooks/skill-loaded.sh"
printf '#!/bin/sh\nexit 0\n' >"${repo4}/.agy/hooks/skill-loaded.sh"
chmod +x "${repo4}/.agy/hooks/skill-loaded.sh"
pl agy-posttool-read.json 'd["cwd"] = "'"${repo4}"'"; d["workspacePaths"] = ["'"${repo4}"'"]' | KIT_GLOBAL_HOOK=1 "${repo}/.agy/hooks/skill-loaded.sh" >/dev/null 2>&1
check "global copy still fires when the workspace wrapper is not the kit file" test "$(ev_count skill-load golang-engineering)" = 1

# 7c. Every tampered or odd workspace (forged command, string `enabled`, narrowed
# matcher, KIT_GLOBAL_HOOK=1 in the command, missing or swapped sibling or lib,
# NaN/1e999/400-digit numbers) leaves the global copy firing: it reads none of it.
defer_bypass() { # label python-on-doc [rm-sibling]
	fresh
	local r="${work}/bypass${cases}"
	mkdir -p "${r}"
	git -C "${r}" init -q
	(HOME="${work}/ih" "${kit}/install.sh" --hooks --repo "${r}" >/dev/null 2>&1)
	python3 -c '
import json, sys
p = sys.argv[1] + "/.agents/hooks.json"
doc = json.load(open(p)); k = doc["eshu-agent-kit"]
exec(sys.argv[2])
json.dump(doc, open(p, "w"))
' "${r}" "$2"
	case "${3:-}" in rm | stub) rm -f "${r}/.claude/hooks/skill-loaded.sh" ;; esac
	[ "${3:-}" != libstub ] || { rm -f "${r}/.agy/hooks/lib/agy-root.sh" && printf '#!/bin/sh\nagy_run() { exit 0; }\n' >"${r}/.agy/hooks/lib/agy-root.sh"; }
	[ "${3:-}" != stub ] || { printf '#!/bin/sh\nexit 0\n' >"${r}/.claude/hooks/skill-loaded.sh" && chmod +x "${r}/.claude/hooks/skill-loaded.sh"; }
	[ -z "${4:-}" ] || sed -i.bk "$4" "${r}/.agents/hooks.json"
	pl agy-posttool-read.json 'd["cwd"] = "'"${r}"'"; d["workspacePaths"] = ["'"${r}"'"]' | KIT_GLOBAL_HOOK=1 "${repo}/.agy/hooks/skill-loaded.sh" >/dev/null 2>&1
	check "global copy still fires: $1" test "$(ev_count skill-load golang-engineering)" = 1
}
defer_bypass "forged command naming the wrapper in a comment" 'k["PostToolUse"][0]["hooks"][0]["command"] = "printf {} # /skill-loaded.sh"'
defer_bypass "enabled is the string false" 'k["enabled"] = "false"'
defer_bypass "matcher narrowed to view_file" 'k["PostToolUse"][0]["matcher"] = "view_file"'
defer_bypass "workspace command carries KIT_GLOBAL_HOOK=1" 'h = k["PostToolUse"][0]["hooks"][0]; h["command"] = h["command"].replace("exec ", "KIT_GLOBAL_HOOK=1 exec ")'
defer_bypass "workspace .claude sibling is missing" 'pass' rm
defer_bypass "workspace .claude sibling is a substitute script" 'pass' stub
defer_bypass "workspace lib/agy-root.sh is a substitute" 'pass' libstub
defer_bypass "workspace file has a NaN agy cannot parse" 'doc["zz"] = float("nan")'
defer_bypass "workspace file has 1e999, which Go rejects" 'doc["zz"] = 7' '' 's/"zz": 7/"zz": 1e999/'
defer_bypass "workspace file has a 400-digit integer, which Go rejects" 'doc["zz"] = 7' '' "s/\"zz\": 7/\"zz\": 1$(printf '0%.0s' $(seq 1 400))/"

# 7d. Only exit 2 is a deny: a sibling that crashes (rc 1) stays neutral.
fresh
repo5="${work}/repo5"
mkdir -p "${repo5}"
git -C "${repo5}" init -q
(HOME="${work}/ih" "${kit}/install.sh" --hooks --repo "${repo5}" >/dev/null 2>&1)
rm -f "${repo5}/.claude/hooks/skill-nudge.sh"
printf '#!/bin/sh\necho boom >&2\nexit 1\n' >"${repo5}/.claude/hooks/skill-nudge.sh"
chmod +x "${repo5}/.claude/hooks/skill-nudge.sh"
out="$(cd "${repo5}/.agents" && pl agy-pretool-edit.json | sh -c "$(hook_cmd "${repo5}" skill-nudge)" 2>/dev/null)"
rc=$?
check "a sibling that exits 1 is neutral, not a deny" is_neutral
printf '#!/bin/sh\necho blocked >&2\nexit 2\n' >"${repo5}/.claude/hooks/skill-nudge.sh"
out="$(cd "${repo5}/.agents" && pl agy-pretool-edit.json | sh -c "$(hook_cmd "${repo5}" skill-nudge)" 2>/dev/null)"
check "a sibling that exits 2 is a deny" test "$(field decision)" = deny

# 7e. The REPO copy stands down only beside an exact, working global install;
# any other state fires (fail toward a double fire, never a silenced guard).
detach() { # replace a tree symlink with a private copy so chmod never touches the kit
	local f="$1" t
	t="$(readlink "${f}")" && rm -f "${f}" && cp "${t}" "${f}"
}
peer_case() { # label stand|fire mutation-shell [env-prefix...]
	local label="$1" want="$2" mut="$3" n
	shift 3
	fresh
	(HOME="${HOME}" "${kit}/install.sh" --hooks --global agy >/dev/null 2>&1)
	G="${HOME}/.gemini/config/hooks.json"
	tree="${HOME}/.gemini/config/agent-kit-hooks"
	eval "${mut}"
	out="$(cd "${repo}/.agents" && pl agy-posttool-read.json | env "$@" sh -c "$(hook_cmd "${repo}" skill-loaded)" 2>/dev/null)"
	n="$(ev_count skill-load golang-engineering)"
	if [ "${want}" = stand ]; then check "repo copy stands down: ${label}" test "${n}" = 0; else check "repo copy fires: ${label}" test "${n}" = 1; fi
}
gmut() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); k=d["eshu-agent-kit-global"]; exec(sys.argv[2]); json.dump(d, open(sys.argv[1],"w"))' "${G}" "$1"; }
peer_case "exact global install" stand ':'
peer_case "no global hooks.json" fire 'rm -f "${G}"'
peer_case "HOME unset" fire ':' -u HOME
peer_case "HOME empty" fire ':' HOME=
peer_case "HOME relative" fire ':' HOME=relative/home
peer_case "enabled is false" fire 'gmut "k[\"enabled\"] = False"'
peer_case "enabled is the string false" fire 'gmut "k[\"enabled\"] = \"false\""'
peer_case "matcher narrowed" fire 'gmut "k[\"PostToolUse\"][0][\"matcher\"] = \"view_file\""'
peer_case "command lacks KIT_GLOBAL_HOOK=1" fire 'gmut "h = k[\"PostToolUse\"][0][\"hooks\"][0]; h[\"command\"] = h[\"command\"].replace(\"KIT_GLOBAL_HOOK=1 \", \"\")"'
peer_case "command points into another tree" fire 'gmut "h = k[\"PostToolUse\"][0][\"hooks\"][0]; h[\"command\"] = h[\"command\"].replace(\"agent-kit-hooks\", \"other-hooks\")"'
peer_case "global file has NaN" fire 'gmut "d[\"zz\"] = float(\"nan\")"'
peer_case "global file has 1e999" fire 'gmut "d[\"zz\"] = 7"; sed -i.bk "s/\"zz\": 7/\"zz\": 1e999/" "${G}"'
peer_case "global file starts with a BOM" fire 'printf "\xef\xbb\xbf" | cat - "${G}" >"${G}.n" && mv "${G}.n" "${G}"'
peer_case "global key collides case-insensitively" fire 'gmut "d[\"ESHU-AGENT-KIT-GLOBAL\"] = {}"'
peer_case "hooks.json is a symlink" fire 'mv "${G}" "${G}.real" && ln -s "${G}.real" "${G}"'
peer_case "global wrapper missing" fire 'rm -f "${tree}/.agy/hooks/skill-loaded.sh"'
peer_case "global wrapper not executable" fire 'detach "${tree}/.agy/hooks/skill-loaded.sh" && chmod -x "${tree}/.agy/hooks/skill-loaded.sh"'
peer_case "global wrapper is a dangling symlink" fire 'ln -sf /nonexistent/x.sh "${tree}/.agy/hooks/skill-loaded.sh"'
peer_case "global sibling missing" fire 'rm -f "${tree}/.claude/hooks/skill-loaded.sh"'
peer_case "global lib file missing" fire 'rm -f "${tree}/.agy/hooks/lib/agy-root.sh"'
peer_case "global translate helper missing" fire 'rm -f "${tree}/.agy/hooks/lib/agy-translate.py"'
# A relative HOME that would resolve to a genuine install from the hook's cwd must still fire.
fresh
mkdir -p "${repo}/.agents/rh"
(cd "${repo}/.agents" && HOME=rh "${kit}/install.sh" --hooks --global agy >/dev/null 2>&1)
out="$(cd "${repo}/.agents" && pl agy-posttool-read.json | env HOME=rh sh -c "$(hook_cmd "${repo}" skill-loaded)" 2>/dev/null)"
check "repo copy fires when a relative HOME would resolve to a real install" test "$(ev_count skill-load golang-engineering)" = 1
rm -rf "${repo}/.agents/rh"
peer_case "enabled: true is present (whole key must equal the generated one)" fire 'gmut "k[\"enabled\"] = True"'
peer_case "an extra member in the key" fire 'gmut "k[\"extra\"] = 1"'
peer_case "Enabled: false sits beside the key" fire 'gmut "k[\"Enabled\"] = False"'
peer_case "stop beside Stop (case-fold collision in the key)" fire 'gmut "k[\"stop\"] = k[\"Stop\"]"'
peer_case "a foreign hook holding a and A" fire 'gmut "d[\"foreign\"] = {\"a\": 1, \"A\": 2}"'
peer_case "another wrapper's timeout is edited (whole key)" fire 'gmut "k[\"Stop\"][0][\"timeout\"] = 99"'
peer_case "~/.gemini is itself a symlink and the tree files are symlinks into the kit" stand 'mv "${HOME}/.gemini" "${HOME}/real-gemini" && ln -s real-gemini "${HOME}/.gemini"'

# 7f. skill-nudge is the one wrapper whose copies differ: the repo copy keeps the
# repo's own nudge table, and does nothing extra when there is none.
nudge_case() { # label table(yes|no) expect-decision-of-repo-copy
	fresh
	rm -f "${repo}/.agents/nudge-table.sh"
	(HOME="${HOME}" "${kit}/install.sh" --hooks --global agy >/dev/null 2>&1)
	[ "$2" = no ] || printf 'nudge_ids_for() { IDS="publish"; NOTE="repo table"; }\n' >"${repo}/.agents/nudge-table.sh"
	run skill-nudge "$(pl agy-pretool-edit.json 'd["toolCall"]["args"]["Path"] = "'"${repo}"'/zz.txt"')"
	check "$1" test "$(field decision)" = "$3"
	rm -f "${repo}/.agents/nudge-table.sh"
}
nudge_case "repo copy beside a global install is neutral without a repo table" no ""
nudge_case "repo copy beside a global install still denies from the repo table" yes deny
# A repo table that empties the list neutralises only the repo copy; the global copy still denies.
fresh
rm -f "${repo}/.agents/nudge-table.sh"
printf 'nudge_ids_for() { IDS=""; }\n' >"${repo}/.agents/nudge-table.sh"
run skill-nudge "$(pl agy-pretool-edit.json)"
check "with no global install an empty repo table is neutral (supported)" is_neutral
(HOME="${HOME}" "${kit}/install.sh" --hooks --global agy >/dev/null 2>&1)
run skill-nudge "$(pl agy-pretool-edit.json)"
check "with a global install the empty repo table makes the repo copy neutral" is_neutral
rm -f "${repo}/.agents/nudge-table.sh"
fresh
(HOME="${HOME}" "${kit}/install.sh" --hooks --global agy >/dev/null 2>&1)
out="$(cd "${HOME}/.gemini/config" && pl agy-pretool-edit.json | KIT_GLOBAL_HOOK=1 sh -c "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["eshu-agent-kit-global"]["PreToolUse"][0]["hooks"][0]["command"])' "${HOME}/.gemini/config/hooks.json")" 2>/dev/null)"
check "the global copy denies the same edit" test "$(field decision)" = deny

# 7g. Stop with HOME unset still continues an open goal (the sibling must not die on ${HOME}).
fresh
printf 'SESSION: %s\nFinish the migration.\n' "${sid}" >"${goalf}"
out="$(cd "${repo}/.agents" && pl agy-stop.json | env -u HOME sh -c "$(hook_cmd "${repo}" goal-continue)" 2>/dev/null)"
check "an open goal continues with HOME unset" test "$(field decision)" = continue
rm -f "${goalf}"

# 8. Debrief: an agy hook event joins its agy__<conversationId> session, and the
# not_tracked caveat is data-driven (present only with agy sessions and no agy events).
fresh
cid="agy-conv-0001-aaaa"
tr="${work}/tr/agy-cli/brain/${cid}/.system_generated/logs"
mkdir -p "${tr}"
cat >"${tr}/transcript.jsonl" <<'EOF'
{"created_at":"2026-11-20T10:00:10Z","type":"USER_INPUT","content":"Publish the change"}
{"created_at":"2026-11-20T10:00:15Z","type":"PLANNER_RESPONSE","model":"gemini-flash","input_tokens":500,"output_tokens":120,"cache_read_tokens":0,"tool_calls":[{"name":"read_file","args":{"Path":"/repo/skills/publish/SKILL.md"}}],"response":"Reading."}
{"created_at":"2026-11-20T10:00:50Z","type":"USER_INPUT","content":"Go on"}
EOF
python3 -c 'import os,sys; os.utime(sys.argv[1], (1795168900, 1795168900))' "${tr}/transcript.jsonl"
cache="${work}/cache"
bash "${kit}/scripts/debrief.sh" prepare --since 2026-11-01 --harness agy --cache-dir "${cache}" --out-dir "${work}/batches" \
	--transcript-root "${work}/tr/agy-cli/brain" >/dev/null 2>&1
agg() { bash "${kit}/scripts/debrief.sh" aggregate --since 2026-11-01 --harness agy --cache-dir "${cache}" --log "$1" --out "${work}/agg.json" >/dev/null 2>&1; }
: >"${work}/empty.jsonl"
agg "${work}/empty.jsonl"
check "agy sessions with zero agy hook events -> caveat names transcript mining" python3 - "${work}/agg.json" <<'PY'
import json, sys
nt = " ".join(json.load(open(sys.argv[1]))["not_tracked"])
assert "Antigravity (agy) hook telemetry is absent" in nt and "transcript mining" in nt, nt
assert "not wired on agy yet" not in nt, nt
d = json.load(open(sys.argv[1]))
assert d["hooks"]["agy"] == {"sessions": 1, "hook_events": 0, "sessions_with_hook_events": 0}, d["hooks"]["agy"]
PY
run skill-loaded "$(pl agy-posttool-read.json 'd["conversationId"] = "'"${cid}"'"; d["toolCall"]["args"]["Path"] = "/repo/skills/publish/SKILL.md"')"
agg "${LOG}"
check "an agy hook event joins its agy session and clears the caveat" python3 - "${work}/agg.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
row = {r["skill"]: r for r in d["skill_table"]}["publish"]
assert row["hook_loads"] == 1 and row["mined_loads"] == 1, row
assert not any("Antigravity" in s for s in d["not_tracked"]), d["not_tracked"]
assert d["hooks"]["agy"] == {"sessions": 1, "hook_events": 1, "sessions_with_hook_events": 1}, d["hooks"]["agy"]
PY

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]

#!/usr/bin/env bash
# Behavioural mirror for install.sh usability: --help, composable part
# flags in one call, and the --pick multi-select.
#
# Existing invocations keep working exactly (pinned by the other suites);
# these cases pin the new surface: help text, stacked parts, the picker
# with piped answers and with EOF defaults, and refusals for unknown
# tokens, rules-with-global, and uninstall mixed with install parts.
set -euo pipefail

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

# 1. --help prints one complete reference and exits 0; -h matches it.
if "${kit}/install.sh" --help >"${work}/help.txt" 2>&1; then
	ok "--help exits 0"
else
	no "--help exits 0"
fi
for word in --pick --agents --hooks --rules --skills --global --repo --uninstall --force --no-prune; do
	rg -q -- "$word" "${work}/help.txt" ||
		{
			no "--help names $word"
			break
		}
done
ok "--help names every mode and flag"
rg -q "agents.*hooks|hooks.*agents" "${work}/help.txt" &&
	ok "--help shows a stacked example" || no "--help shows a stacked example"
"${kit}/install.sh" -h >"${work}/help-h.txt" 2>&1
cmp -s "${work}/help.txt" "${work}/help-h.txt" &&
	ok "-h matches --help" || no "-h matches --help"

# 2. Stacked parts install in one call: --agents --hooks --repo.
stacked="${work}/stacked"
"${kit}/install.sh" --agents --hooks --repo "${stacked}" >/dev/null 2>&1 ||
	no "stacked install exits 0"
[ -f "${stacked}/.agents/agents/scan-eshu.md" ] && cmp -s "${stacked}/.agents/agents/scan-eshu.md" "${kit}/agents/scan-eshu.md" &&
	ok "stacked install places agents" || no "stacked install places agents"
[ -f "${stacked}/.muse/hooks.json" ] && [ -L "${stacked}/.muse/hooks/goal-refresh.sh" ] &&
	ok "stacked install places hooks" || no "stacked install places hooks"
[ -f "${stacked}/.agent-kit-version" ] &&
	ok "stacked install stamps the version pin once" || no "stacked install stamps the version pin once"

# 3. Stacked global parts: --skills --agents --global one harness.
h1="${work}/h1"
HOME="${h1}" "${kit}/install.sh" --skills --agents --global muse </dev/null >/dev/null 2>&1 ||
	no "stacked global install exits 0"
[ -L "${h1}/.agents/skills/code-review" ] &&
	ok "stacked global install places skills" || no "stacked global install places skills"
[ -f "${h1}/.config/muse/agents/scan-eshu.md" ] &&
	ok "stacked global install places agents" || no "stacked global install places agents"
[ ! -e "${h1}/.config/muse/agent-kit-hooks" ] &&
	ok "stacked global install adds no hooks unless asked" || no "stacked global install adds no hooks unless asked"

# 4. Bare modes keep their legacy meaning (no silent expansion).
legacy="${work}/legacy"
"${kit}/install.sh" --repo "${legacy}" >/dev/null 2>&1
[ -L "${legacy}/.agents/skills/code-review" ] && [ ! -e "${legacy}/.agents/agents" ] &&
	ok "bare --repo still installs skills only" || no "bare --repo still installs skills only"

# 5. Refusals: unknown token, rules with global, uninstall mixed in.
if "${kit}/install.sh" --frobnicate --repo "${work}/x" >/dev/null 2>&1; then
	no "unknown token fails"
else
	ok "unknown token fails"
fi
if "${kit}/install.sh" --rules --global >/dev/null 2>&1; then
	no "--rules --global fails"
else
	ok "--rules --global fails"
fi
if "${kit}/install.sh" --agents --uninstall --repo "${work}/x" >/dev/null 2>&1; then
	no "uninstall mixed with parts fails"
else
	ok "uninstall mixed with parts fails"
fi
if "${kit}/install.sh" --pick --agents --repo "${work}/x" >/dev/null 2>&1; then
	no "--pick mixed with parts fails"
else
	ok "--pick mixed with parts fails"
fi
# Bare --repo rejects trailing args: --uninstall stays exclusive everywhere,
# so a combined uninstall can never silently install instead.
if "${kit}/install.sh" --repo "${work}/should-not-exist" --uninstall >/dev/null 2>&1; then
	no "bare --repo rejects a trailing --uninstall"
else
	[ ! -e "${work}/should-not-exist" ] &&
		ok "bare --repo rejects a trailing --uninstall" || no "bare --repo rejects a trailing --uninstall"
fi

# 6. --pick with piped answers installs exactly the picked parts.
picked="${work}/picked"
printf '1 3\n' | "${kit}/install.sh" --pick --repo "${picked}" >/dev/null 2>&1 ||
	no "picker with piped answers exits 0"
[ -L "${picked}/.agents/skills/code-review" ] && [ -f "${picked}/.muse/hooks.json" ] &&
	ok "picker installs the picked parts" || no "picker installs the picked parts"
[ ! -e "${picked}/.agents/agents" ] && [ ! -e "${picked}/.claude/rules" ] &&
	ok "picker skips the unpicked parts" || no "picker skips the unpicked parts"

# 7. --pick with EOF stdin keeps the displayed defaults, never global hooks.
eofrepo="${work}/eofrepo"
"${kit}/install.sh" --pick --repo "${eofrepo}" </dev/null >/dev/null 2>&1 ||
	no "picker with EOF exits 0"
[ -L "${eofrepo}/.agents/skills/code-review" ] && cmp -s "${eofrepo}/.agents/agents/scan-eshu.md" "${kit}/agents/scan-eshu.md" &&
	[ -f "${eofrepo}/.muse/hooks.json" ] && [ -e "${eofrepo}/.claude/rules" ] &&
	ok "picker EOF defaults to every repo part" || no "picker EOF defaults to every repo part"
eofglob="${work}/eofglob"
HOME="${eofglob}" "${kit}/install.sh" --pick --global muse </dev/null >/dev/null 2>&1 ||
	no "global picker with EOF exits 0"
[ -L "${eofglob}/.agents/skills/code-review" ] && [ -f "${eofglob}/.config/muse/agents/scan-eshu.md" ] &&
	ok "global picker EOF defaults to skills and agents" || no "global picker EOF defaults to skills and agents"
[ ! -e "${eofglob}/.config/muse/agent-kit-hooks" ] &&
	ok "global picker EOF never defaults to hooks" || no "global picker EOF never defaults to hooks"

# 8. --pick without a scope and without a terminal refuses with the
# equivalent explicit command instead of guessing.
if "${kit}/install.sh" --pick </dev/null >/tmp/pick-err.log 2>&1; then
	no "scopeless picker with EOF fails"
else
	rg -q "install.sh --pick --(repo|global)" /tmp/pick-err.log &&
		ok "scopeless picker prints the explicit equivalent" || no "scopeless picker prints the explicit equivalent"
fi

# 9. The agent writer never produces empty or model-less files: an
# empty source or an empty model fails loudly and writes nothing.
eval "$(sed -n '/^write_agent_file()/,/^}/p' "${kit}/install.sh")"
: >"${work}/empty-src.md"
printf '%s\n' '---' 'name: x' 'model: real-model' '---' 'body' >"${work}/ok-src.md"
if write_agent_file "${work}/empty-src.md" "${work}/ux-out1" "some-model" 2>/dev/null; then
	no "empty agent source is refused"
else
	ok "empty agent source is refused"
fi
[ ! -e "${work}/ux-out1/empty-src.md" ] &&
	ok "refused source leaves no file" || no "refused source leaves no file"
if write_agent_file "${work}/ok-src.md" "${work}/ux-out2" "" 2>/dev/null; then
	no "empty model is refused"
else
	ok "empty model is refused"
fi
[ ! -e "${work}/ux-out2" ] &&
	ok "refused model leaves nothing behind" || no "refused model leaves nothing behind"

printf '\ninstall-ux mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

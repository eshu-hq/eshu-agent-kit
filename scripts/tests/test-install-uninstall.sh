#!/usr/bin/env bash
# Behavioural mirror for install.sh --uninstall.
#
# Uninstall removes only what the kit provably owns and prints every
# removal: symlinks resolving into this kit (or dangling links naming an
# eshu-agent-kit* path), Generated-by marker files, byte-identical copies
# of kit files, and the matching version pin. User files, modified
# copies, out-of-kit links, and real directories always survive; alias
# wrappers (real dirs carrying .kit-alias) go only with --force. Global
# uninstall never edits settings keys holding merged user choices
# (opencode.jsonc, Muse settings.json): it prints the manual undo.
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

# 1. Repo uninstall removes every kit-owned placement and prints each,
# while user files, modified copies, and out-of-kit links survive.
repo="${work}/repo"
"${kit}/install.sh" --repo "${repo}" >/dev/null 2>&1
"${kit}/install.sh" --agents --repo "${repo}" >/dev/null 2>&1
"${kit}/install.sh" --hooks --repo "${repo}" >/dev/null 2>&1
"${kit}/install.sh" --rules --repo "${repo}" >/dev/null 2>&1
printf '# mine\n' >"${repo}/.agents/agents/mine.md"
printf '# custom scan\n' >"${repo}/.agents/agents/scan-eshu.md"
printf 'x\n' >"${work}/outside.md"
ln -s "${work}/outside.md" "${repo}/.agents/skills/ext-link"
mkdir -p "${repo}/.agents/skills/my-skill"
printf '# MY SKILL\n' >"${repo}/.agents/skills/my-skill/SKILL.md"
if out="$("${kit}/install.sh" --uninstall --repo "${repo}" 2>"${work}/err1")"; then
	ok "repo uninstall exits 0"
else
	no "repo uninstall exits 0"
fi
err1="$(cat "${work}/err1")"
[ ! -L "${repo}/.agents/skills/code-review" ] &&
	ok "repo uninstall removes skill links" || no "repo uninstall removes skill links"
[ ! -e "${repo}/.agents/agents/develop-eshu.md" ] &&
	ok "repo uninstall removes identical agent copies" || no "repo uninstall removes identical agent copies"
[ ! -L "${repo}/.agents/roles.json" ] &&
	ok "repo uninstall removes the role manifest link" || no "repo uninstall removes the role manifest link"
[ ! -L "${repo}/scripts/agent-roles.py" ] &&
	ok "repo uninstall removes the role launcher link" || no "repo uninstall removes the role launcher link"
[ ! -L "${repo}/scripts/check-docs-stale.sh" ] &&
	ok "repo uninstall removes the linked staleness checker" || no "repo uninstall removes the linked staleness checker"
[ ! -L "${repo}/scripts/claude-rules-lint.sh" ] &&
	ok "repo uninstall removes the rules lint link" || no "repo uninstall removes the rules lint link"
[ ! -L "${repo}/.claude/hooks/guard-live-gate.sh" ] &&
	ok "repo uninstall removes hook links" || no "repo uninstall removes hook links"
[ ! -e "${repo}/.muse/hooks.json" ] &&
	ok "repo uninstall removes the generic hooks.json copy" || no "repo uninstall removes the generic hooks.json copy"
rules_gone=1
for rule in "${kit}"/rules/*.md; do
	[ "$(basename "${rule}")" = README.md ] && continue
	[ -e "${repo}/.claude/rules/$(basename "${rule}")" ] && rules_gone=0
done
[ "${rules_gone}" -eq 1 ] &&
	ok "repo uninstall removes rule links" || no "repo uninstall removes rule links"
[ ! -e "${repo}/.agent-kit-version" ] &&
	ok "repo uninstall removes the matching version pin" || no "repo uninstall removes the matching version pin"
rg -q "removed ${repo}/.agents/skills/code-review" <<<"${out}" &&
	rg -q "removed ${repo}/.agent-kit-version" <<<"${out}" &&
	ok "every repo removal is printed" || no "every repo removal is printed"
[ "$(cat "${repo}/.agents/agents/mine.md")" = "# mine" ] &&
	ok "unmarked user agent survives uninstall" || no "unmarked user agent survives uninstall"
[ "$(cat "${repo}/.agents/agents/scan-eshu.md")" = "# custom scan" ] &&
	ok "modified agent copy survives uninstall" || no "modified agent copy survives uninstall"
rg -q "keeping ${repo}/.agents/agents/scan-eshu.md" <<<"${err1}" &&
	ok "kept copies are reported" || no "kept copies are reported"
[ -L "${repo}/.agents/skills/ext-link" ] &&
	ok "out-of-kit symlink survives uninstall" || no "out-of-kit symlink survives uninstall"
[ "$(cat "${repo}/.agents/skills/my-skill/SKILL.md")" = "# MY SKILL" ] &&
	ok "user skill dir survives uninstall" || no "user skill dir survives uninstall"

# 1b. A consumer-owned hooks.json and checker are kept; the pin from a
# foreign edit is kept too.
kept="${work}/kept"
"${kit}/install.sh" --repo "${kept}" >/dev/null 2>&1
mkdir -p "${kept}/scripts" "${kept}/.muse"
printf '# CONSUMER-MARKER\n' >"${kept}/scripts/check-docs-stale.sh"
printf '# CONSUMER-HOOKS\n' >"${kept}/.muse/hooks.json"
"${kit}/install.sh" --hooks --repo "${kept}" >/dev/null 2>&1
printf 'tampered\n' >"${kept}/.agent-kit-version"
"${kit}/install.sh" --uninstall --repo "${kept}" >/dev/null 2>"${work}/err1b" || no "consumer-owned uninstall exits 0"
[ "$(cat "${kept}/scripts/check-docs-stale.sh")" = "# CONSUMER-MARKER" ] &&
	ok "consumer checker survives uninstall" || no "consumer checker survives uninstall"
[ "$(cat "${kept}/.muse/hooks.json")" = "# CONSUMER-HOOKS" ] &&
	ok "consumer hooks.json survives uninstall" || no "consumer hooks.json survives uninstall"
[ "$(cat "${kept}/.agent-kit-version")" = "tampered" ] &&
	ok "foreign version pin survives uninstall" || no "foreign version pin survives uninstall"

# 2. Alias wrappers (real dirs with .kit-alias) survive without --force
# and go with it.
aliased="${work}/aliased"
printf 'my-alias\tcode-review\n' >"${work}/manifest.tsv"
"${kit}/install.sh" --repo "${aliased}" --aliases "${work}/manifest.tsv" >/dev/null 2>&1
"${kit}/install.sh" --uninstall --repo "${aliased}" >/dev/null 2>"${work}/err2" || no "alias uninstall exits 0"
[ -d "${aliased}/.claude/skills/my-alias" ] && [ -f "${aliased}/.claude/skills/my-alias/.kit-alias" ] &&
	ok "alias wrapper survives without --force" || no "alias wrapper survives without --force"
rg -q "keeping ${aliased}/.claude/skills/my-alias.*--force" "${work}/err2" &&
	ok "kept wrapper names --force" || no "kept wrapper names --force"
mkdir -p "${aliased}/.claude/skills/fake-wrapper"
printf 'not a kit marker\n' >"${aliased}/.claude/skills/fake-wrapper/.kit-alias"
printf 'x\n' >"${aliased}/.claude/skills/fake-wrapper/SKILL.md"
"${kit}/install.sh" --uninstall --repo "${aliased}" --force >/dev/null 2>&1 || no "forced uninstall exits 0"
[ ! -e "${aliased}/.claude/skills/my-alias" ] && [ ! -e "${aliased}/.codex/skills/my-alias" ] &&
	ok "--force removes alias wrappers" || no "--force removes alias wrappers"
[ -f "${aliased}/.claude/skills/fake-wrapper/SKILL.md" ] &&
	ok "--force keeps dirs with a stray marker" || no "--force keeps dirs with a stray marker"

# 3. Partial uninstall removes its own mode, keeps the rest and the pin.
part="${work}/part"
"${kit}/install.sh" --repo "${part}" >/dev/null 2>&1
"${kit}/install.sh" --agents --repo "${part}" >/dev/null 2>&1
"${kit}/install.sh" --hooks --repo "${part}" >/dev/null 2>&1
"${kit}/install.sh" --uninstall --agents --repo "${part}" >/dev/null 2>&1 || no "partial uninstall exits 0"
[ ! -e "${part}/.agents/agents/develop-eshu.md" ] && [ ! -L "${part}/.agents/roles.json" ] &&
	ok "partial uninstall removes its mode" || no "partial uninstall removes its mode"
[ -L "${part}/.agents/skills/code-review" ] &&
	ok "partial uninstall keeps other modes" || no "partial uninstall keeps other modes"
[ -L "${part}/.claude/hooks/guard-live-gate.sh" ] &&
	ok "partial uninstall keeps hooks" || no "partial uninstall keeps hooks"
[ "$(cat "${part}/.agent-kit-version")" = "$(cat "${kit}/VERSION")" ] &&
	ok "partial uninstall keeps the version pin" || no "partial uninstall keeps the version pin"

# 4. Global uninstall removes owned links and default agent files, keeps
# model choices and user files, and never edits the opencode config.
h1="${work}/h1"
HOME="${h1}" "${kit}/install.sh" --global muse opencode </dev/null >/dev/null 2>&1
sed -i 's/^model:.*/model: custom-model/' "${h1}/.config/muse/agents/develop-eshu.md"
printf '# keep\n' >"${h1}/.config/muse/agents/keep.md"
mkdir -p "${h1}/.agents/agents"
printf '# prior choice\n' >"${h1}/.agents/agents/scan-eshu.md"
cfg_sum_before="$(sha256sum "${h1}/.config/opencode/opencode.jsonc" | cut -d' ' -f1)"
if out4="$(HOME="${h1}" "${kit}/install.sh" --uninstall --global muse opencode 2>"${work}/err4")"; then
	ok "global uninstall exits 0"
else
	no "global uninstall exits 0"
fi
[ ! -L "${h1}/.agents/skills/code-review" ] &&
	ok "global uninstall removes skill links" || no "global uninstall removes skill links"
[ ! -e "${h1}/.config/muse/agents/scan-eshu.md" ] &&
	ok "global uninstall removes default agent files" || no "global uninstall removes default agent files"
[ "$(cat "${h1}/.config/muse/agents/develop-eshu.md")" != "" ] && rg -q "custom-model" "${h1}/.config/muse/agents/develop-eshu.md" &&
	ok "global uninstall keeps model choices" || no "global uninstall keeps model choices"
rg -q "keeping ${h1}/.config/muse/agents/develop-eshu.md" "${work}/err4" &&
	ok "kept model choices are reported" || no "kept model choices are reported"
[ "$(cat "${h1}/.config/muse/agents/keep.md")" = "# keep" ] &&
	ok "unmarked global agent survives" || no "unmarked global agent survives"
[ "$(cat "${h1}/.agents/agents/scan-eshu.md")" = "# prior choice" ] &&
	ok "superseded ~/.agents/agents untouched by uninstall" || no "superseded ~/.agents/agents untouched by uninstall"
[ "$(sha256sum "${h1}/.config/opencode/opencode.jsonc" | cut -d' ' -f1)" = "${cfg_sum_before}" ] &&
	ok "global uninstall never edits opencode.jsonc" || no "global uninstall never edits opencode.jsonc"
rg -q "opencode.jsonc" "${work}/err4" &&
	ok "opencode manual undo is printed" || no "opencode manual undo is printed"
HOME="${h1}" "${kit}/install.sh" --uninstall --global muse opencode --force >/dev/null 2>&1 || no "forced global uninstall exits 0"
[ ! -e "${h1}/.config/muse/agents/develop-eshu.md" ] &&
	ok "--force removes model-choice agent files" || no "--force removes model-choice agent files"
[ "$(cat "${h1}/.config/muse/agents/keep.md")" = "# keep" ] &&
	ok "--force still keeps unmarked files" || no "--force still keeps unmarked files"

# 5. Global Muse hooks uninstall drops the tree but never the settings key.
h3="${work}/h3"
HOME="${h3}" "${kit}/install.sh" --global muse </dev/null >/dev/null 2>&1
HOME="${h3}" "${kit}/install.sh" --hooks --global muse </dev/null >/dev/null 2>&1
tree="${h3}/.config/muse/agent-kit-hooks"
if out5="$(HOME="${h3}" "${kit}/install.sh" --uninstall --global muse 2>"${work}/err5")"; then
	ok "global uninstall exits 0 with hooks tree present"
else
	no "global uninstall exits 0 with hooks tree present"
fi
[ -e "${tree}/managed-hooks.json" ] &&
	ok "plain global uninstall keeps the hooks tree" || no "plain global uninstall keeps the hooks tree"
rg -q -- "--hooks --global muse" "${work}/err5" &&
	ok "kept hooks tree points at its uninstall mode" || no "kept hooks tree points at its uninstall mode"
HOME="${h3}" "${kit}/install.sh" --uninstall --hooks --global muse >/dev/null 2>"${work}/err5b" || no "hooks uninstall exits 0"
[ ! -e "${tree}/managed-hooks.json" ] && [ ! -L "${tree}/.claude/hooks/guard-live-gate.sh" ] &&
	ok "hooks uninstall removes the tree" || no "hooks uninstall removes the tree"
rg -q "managed_hooks_path" "${h3}/.config/muse/settings.json" &&
	ok "hooks uninstall never edits the settings key" || no "hooks uninstall never edits the settings key"
rg -q "managed_hooks_path" "${work}/err5b" &&
	ok "settings manual undo is printed" || no "settings manual undo is printed"

# 6. Usage errors fail; an empty target succeeds with nothing to do.
if "${kit}/install.sh" --uninstall >/dev/null 2>&1; then
	no "--uninstall without scope fails"
else
	ok "--uninstall without scope fails"
fi
if "${kit}/install.sh" --uninstall --repo >/dev/null 2>&1; then
	no "--uninstall --repo without target fails"
else
	ok "--uninstall --repo without target fails"
fi
if "${kit}/install.sh" --uninstall --repo "${work}/missing" >/dev/null 2>&1; then
	no "--uninstall --repo on a missing target fails"
else
	ok "--uninstall --repo on a missing target fails"
fi
if HOME="${h1}" "${kit}/install.sh" --uninstall --global badharness </dev/null >/dev/null 2>&1; then
	no "--uninstall --global rejects unknown harnesses"
else
	ok "--uninstall --global rejects unknown harnesses"
fi
if "${kit}/install.sh" --uninstall --rules --global >/dev/null 2>&1; then
	no "--uninstall --rules --global fails"
else
	ok "--uninstall --rules --global fails"
fi
mkdir -p "${work}/empty"
if "${kit}/install.sh" --uninstall --repo "${work}/empty" >/dev/null 2>&1; then
	ok "--uninstall on an empty target exits 0"
else
	no "--uninstall on an empty target exits 0"
fi

printf '\ninstall-uninstall mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

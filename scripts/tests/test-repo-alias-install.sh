#!/usr/bin/env bash
# Behavioural mirror for install.sh --repo --aliases.
#
# A product repo whose harness-visible skill names differ from the kit
# directory names installs alias wrappers instead of plain symlinks:
# every alias dir carries the alias in its frontmatter `name:`, cross-skill
# links point at aliases, and no generic twin is left discoverable.
# The eshu alias manifest is the worked example under test.
set -euo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="${kit}/templates/repo-overlay/eshu-aliases.tsv"

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

renamed="$(awk -F'\t' 'NF == 2 && $1 !~ /^#/ && $1 != $2 {print $2}' "${manifest}")"
identical="$(awk -F'\t' 'NF == 2 && $1 !~ /^#/ && $1 == $2 {print $1}' "${manifest}")"
aliases="$(awk -F'\t' 'NF == 2 && $1 !~ /^#/ {print $1}' "${manifest}")"

# 1. Alias install populates both harness skill trees.
repo="${work}/repo"
"${kit}/install.sh" --repo "${repo}" --aliases "${manifest}" >/dev/null 2>&1
for alias in ${aliases}; do
	if [ -d "${repo}/.claude/skills/${alias}" ] && [ -d "${repo}/.codex/skills/${alias}" ]; then
		ok "alias installed in both trees: ${alias}"
	else
		no "alias installed in both trees: ${alias}"
	fi
done

# 2. Every wrapper frontmatter name equals its directory name.
# (Capture the substitution first: comparing it inline failed
# deterministically in this loop for an undetermined reason, while the
# captured form below verifies green including the RED probe in step 8.)
for tree in .claude/skills .codex/skills; do
	for alias in ${aliases}; do
		got="$(sed -n 's/^name: //p' "${repo}/${tree}/${alias}/SKILL.md")"
		if [ "${got}" = "${alias}" ]; then
			ok "frontmatter names alias: ${tree}/${alias}"
		else
			no "frontmatter names alias: ${tree}/${alias} (got: ${got})"
		fi
	done
done

# 3. Renamed sources leave no generic twin in .agents/skills.
for src in ${renamed}; do
	if [ -e "${repo}/.agents/skills/${src}" ]; then
		no "no generic twin for renamed source: ${src}"
	else
		ok "no generic twin for renamed source: ${src}"
	fi
done

# 3b. Identical alias==source rows still link into .agents/skills, so the
# tree is never left empty and today's plain-repo behavior is unchanged.
for same in ${identical}; do
	if [ -L "${repo}/.agents/skills/${same}" ]; then
		ok "identical alias links into .agents/skills: ${same}"
	else
		no "identical alias links into .agents/skills: ${same}"
	fi
done

# 4. Rewritten cross-links point at aliases; generic targets are gone.
if grep -rF -q "](../eshu-session-lifecycle/references/rebase-verify.md" "${repo}/.claude/skills/eshu-code-review/"; then
	ok "code-review wrapper links the eshu session-lifecycle"
else
	no "code-review wrapper links the eshu session-lifecycle"
fi
for src in ${renamed}; do
	if grep -rF -q "](../${src}/" "${repo}/.claude/skills/" || grep -rF -q "](../${src})" "${repo}/.claude/skills/" || grep -rF -q "](../${src}#" "${repo}/.claude/skills/"; then
		no "no generic cross-link target remains: ${src}"
	else
		ok "no generic cross-link target remains: ${src}"
	fi
done

# 5. Every sibling cross-skill link in the installed wrappers resolves.
# (Grandparent links like ../../../AGENTS.md resolve in the consuming repo
# by design; see the Scope lines. This probe guards what the installer
# rewrites: single-level ../ targets must land inside the installed tree.)
unresolved=0
while IFS= read -r hit || [ -n "$hit" ]; do
	file="${hit%%:*}"
	link="${hit#*:}"
	link="${link#](}"
	link="${link%)}"
	link="${link%%#*}"
	if [ ! -e "$(dirname "${file}")/${link}" ]; then
		no "wrapper link resolves: ${file}: ${link}"
		unresolved=1
	fi
done < <(grep -ro --include='*.md' '](\.\./[^.)/][^)]*)' "${repo}/.claude/skills" "${repo}/.codex/skills" 2>/dev/null || true)
if [ "${unresolved}" -eq 0 ]; then
	ok "every wrapper sibling link resolves"
fi

# 6. Idempotent: a second install over the same repo changes nothing.
cp -r "${repo}" "${work}/repo-once"
"${kit}/install.sh" --repo "${repo}" --aliases "${manifest}" >/dev/null 2>&1
if diff -r "${work}/repo-once" "${repo}" >/dev/null 2>&1; then
	ok "alias reinstall is byte-identical"
else
	no "alias reinstall is byte-identical"
fi

# 7. Negative cases fail loudly. A collision mid-manifest rolls back this
# run's fresh wrappers and restores replaced symlinks, so clearing the
# collision and rerunning completes cleanly.
printf 'eshu-ghost\tno-such-skill\n' >"${work}/bad-source.tsv"
if "${kit}/install.sh" --repo "${work}/bad1" --aliases "${work}/bad-source.tsv" >/dev/null 2>&1; then
	no "unknown source fails"
else
	ok "unknown source fails"
fi
printf 'BAD NAME\tcode-review\n' >"${work}/bad-alias.tsv"
if "${kit}/install.sh" --repo "${work}/bad2" --aliases "${work}/bad-alias.tsv" >/dev/null 2>&1; then
	no "bad alias fails"
else
	ok "bad alias fails"
fi
printf 'eshu-code-review\tcode-review\neshu-code-review\tpublish\n' >"${work}/dup-alias.tsv"
if "${kit}/install.sh" --repo "${work}/bad3" --aliases "${work}/dup-alias.tsv" >/dev/null 2>&1; then
	no "duplicate alias fails"
else
	ok "duplicate alias fails"
fi
if "${kit}/install.sh" --repo "${work}/bad4" --aliases "${work}/nope.tsv" >/dev/null 2>&1; then
	no "missing manifest fails"
else
	ok "missing manifest fails"
fi
mkdir -p "${work}/collide/.claude/skills/eshu-code-review"
if "${kit}/install.sh" --repo "${work}/collide" --aliases "${manifest}" >/dev/null 2>&1; then
	no "real-dir collision fails"
else
	if [ ! -f "${work}/collide/.claude/skills/eshu-code-review/.kit-alias" ]; then
		ok "real-dir collision fails and dir untouched"
	else
		no "real-dir collision fails and dir untouched"
	fi
fi
rbrepo="${work}/rollback"
mkdir -p "${rbrepo}/.claude/skills/eshu-publish" "${rbrepo}/.codex/skills/eshu-publish"
if "${kit}/install.sh" --repo "${rbrepo}" --aliases "${manifest}" >/dev/null 2>&1; then
	no "mid-manifest collision fails"
else
	if [ ! -e "${rbrepo}/.claude/skills/eshu-code-review" ] && [ ! -e "${rbrepo}/.codex/skills/eshu-code-review" ] && [ -d "${rbrepo}/.claude/skills/eshu-publish" ] && [ ! -f "${rbrepo}/.claude/skills/eshu-publish/.kit-alias" ]; then
		ok "mid-manifest collision rolls back fresh wrappers"
	else
		no "mid-manifest collision rolls back fresh wrappers"
	fi
fi
rbswap="${work}/swapback"
mkdir -p "${rbswap}/.claude/skills" "${rbswap}/.codex/skills" "${work}/origskill"
ln -sfn "${work}/origskill" "${rbswap}/.claude/skills/eshu-code-review"
ln -sfn "${work}/origskill" "${rbswap}/.codex/skills/eshu-code-review"
mkdir -p "${rbswap}/.claude/skills/eshu-publish" "${rbswap}/.codex/skills/eshu-publish"
if "${kit}/install.sh" --repo "${rbswap}" --aliases "${manifest}" >/dev/null 2>&1; then
	no "collision after replacements fails"
else
	if [ "$(readlink "${rbswap}/.claude/skills/eshu-code-review")" = "${work}/origskill" ] && [ "$(readlink "${rbswap}/.codex/skills/eshu-code-review")" = "${work}/origskill" ] && [ ! -e "${rbswap}/.claude/skills/eshu-contract-rigor" ]; then
		ok "rollback restores replaced symlinks"
	else
		no "rollback restores replaced symlinks"
	fi
fi
spaced="${work}/my repo"
mkdir -p "${spaced}/.claude/skills/eshu-publish" "${spaced}/.codex/skills/eshu-publish"
mkdir -p "${work}/decoy"
if (cd "${work}/decoy" && mkdir -p repo/.claude/skills/eshu-code-review && touch repo/.claude/skills/eshu-code-review/KEEP && "${kit}/install.sh" --repo "${spaced}" --aliases "${manifest}" >/dev/null 2>&1); then
	no "space-path collision fails"
else
	if [ ! -e "${spaced}/.claude/skills/eshu-code-review" ] && [ ! -e "${spaced}/.codex/skills/eshu-diagnostic-rigor" ] && [ -f "${work}/decoy/repo/.claude/skills/eshu-code-review/KEEP" ]; then
		ok "space-path collision rolls back exactly"
	else
		no "space-path collision rolls back exactly"
	fi
fi
spacedclean="${work}/my clean repo"
if "${kit}/install.sh" --repo "${spacedclean}" --aliases "${manifest}" >/dev/null 2>&1; then
	gotname="$(sed -n 's/^name: //p' "${spacedclean}/.claude/skills/eshu-code-review/SKILL.md")"
	if [ "$(ls "${spacedclean}/.claude/skills" | wc -l | tr -d ' ')" = 21 ] && [ "${gotname}" = eshu-code-review ]; then
		ok "space-path clean install works"
	else
		no "space-path clean install works"
	fi
else
	no "space-path clean install works"
fi
stale="${work}/staler"
"${kit}/install.sh" --repo "${stale}" --aliases "${manifest}" >/dev/null 2>&1
printf 'eshu-code-review\tcode-review\n' >"${work}/subset.tsv"
out="$("${kit}/install.sh" --repo "${stale}" --aliases "${work}/subset.tsv" 2>&1)"
if [ "$?" = 0 ] && printf '%s' "${out}" | grep -q "stale kit alias wrapper"; then
	ok "dropped alias warns instead of lingering silently"
else
	no "dropped alias warns instead of lingering silently"
fi

# 8. RED at installer level: a source whose frontmatter name does not match
# the alias fails install.sh itself. The lib is sourced with a scratch kit
# so the production tree is never mutated. GREEN is the rest of this suite:
# the same installer path succeeds on a well-formed source end to end.
fakekit="${work}/fakekit"
mkdir -p "${fakekit}/skills/eshu"
cp -r "${kit}/skills/eshu/code-review" "${fakekit}/skills/eshu/tampered"
sed -i.bak 's/^name: code-review$/name: wrong-name/' "${fakekit}/skills/eshu/tampered/SKILL.md"
rm -f "${fakekit}/skills/eshu/tampered/SKILL.md.bak"
printf 'eshu-code-review\ttampered\n' >"${work}/red.tsv"
if (
	KIT_DIR="${fakekit}"
	source "${kit}/scripts/lib/install-aliases.sh"
	install_aliases_repo "${work}/red" "${work}/red.tsv" >/dev/null 2>&1
); then
	no "tampered source fails at installer level"
else
	ok "tampered source fails at installer level"
fi

printf '\nalias-install mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

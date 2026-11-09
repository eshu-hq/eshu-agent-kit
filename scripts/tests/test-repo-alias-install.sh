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

# 7. Negative cases fail loudly instead of installing half a tree.
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

# 8. RED: a corrupted wrapper frontmatter no longer satisfies name == dir.
printf 'name: wrong-name\n' >"${repo}/.claude/skills/eshu-code-review/SKILL.md"
if [ "$(sed -n 's/^name: //p' "${repo}/.claude/skills/eshu-code-review/SKILL.md")" = "eshu-code-review" ]; then
	no "corrupted frontmatter detected"
else
	ok "corrupted frontmatter detected"
fi

printf '\nalias-install mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

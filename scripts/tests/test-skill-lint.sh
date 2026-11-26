#!/usr/bin/env bash
# Behavioural mirror for scripts/skill-lint.sh (#81).
#
# One RED/GREEN seeded pair per rule family (structure, links/size,
# verification, error recovery), run against fixture skills in a temp dir:
# the real tree is never mutated. Tier 1 failures exit nonzero with the
# rule and line cited; Tier 2 findings print as advisories and exit 0.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="${repo_root}/scripts/skill-lint.sh"
BASELINE="${repo_root}/scripts/skill-lint-baseline.tsv"
EMPTY_BASELINE="/dev/null"

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

# make_skill NAME [BODY-FILE]: fixture skill dir with matching name.
make_skill() {
	local dir="${work}/$1"
	mkdir -p "${dir}"
	if (($# > 1)); then
		cat "$2" >"${dir}/SKILL.md"
	else
		cat >"${dir}/SKILL.md" <<EOF
---
name: $1
description: Fixture skill for the skill-lint suite.
---

# Fixture

## Workflow

1. Do the thing with one objective.
2. Check the result before moving on.

\`\`\`bash
bash scripts/skill-lint.sh "\${dir}/SKILL.md"
\`\`\`

## Error recovery

When the check fails, read the cited line and fix the fixture.
EOF
	fi
	printf '%s' "${dir}/SKILL.md"
}

good="$(make_skill good)"

# 1. Structure RED: missing name fires SKILL001 with a file:line citation.
bad_name="${work}/bad-name/SKILL.md"
mkdir -p "${work}/bad-name"
cat >"${bad_name}" <<'EOF'
---
description: No name field here.
---

# Bad
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${bad_name}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "missing name fails" || no "missing name fails (exit 0)"
case "${out}" in
*"SKILL001"*) ok "missing name cites SKILL001" ;;
*) no "missing name cites SKILL001 (got: ${out:0:120})" ;;
esac
case "${out}" in
*bad-name/SKILL.md:1:*) ok "failure carries a file:line citation" ;;
*) no "failure carries a file:line citation (got: ${out:0:120})" ;;
esac

# 2. Structure RED: name/directory mismatch fires SKILL003.
mismatch="${work}/right-dir/SKILL.md"
mkdir -p "${work}/right-dir"
cat >"${mismatch}" <<'EOF'
---
name: wrong-name
description: Name does not match the directory.
---

# Bad
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${mismatch}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "name mismatch fails" || no "name mismatch fails (exit 0)"
case "${out}" in
*"SKILL003"*) ok "name mismatch cites SKILL003" ;;
*) no "name mismatch cites SKILL003 (got: ${out:0:120})" ;;
esac

# 3. Structure RED: missing description fires SKILL002.
no_desc="${work}/no-desc/SKILL.md"
mkdir -p "${work}/no-desc"
cat >"${no_desc}" <<'EOF'
---
name: no-desc
---

# No description
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${no_desc}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "missing description fails" || no "missing description fails (exit 0)"
case "${out}" in
*"SKILL002"*) ok "missing description cites SKILL002" ;;
*) no "missing description cites SKILL002 (got: ${out:0:120})" ;;
esac

# 4. Structure GREEN: the good fixture passes Tier 1 silently.
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${good}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "good fixture passes" || no "good fixture passes (exit ${code}: ${out:0:150})"
case "${out}" in
*"0 errors, 0 advisories (0 suppressed"*) ok "good fixture prints no advisories" ;;
*) no "good fixture prints no advisories (got: ${out:0:150})" ;;
esac

# 5. Links RED: a dangling relative link fires SKILL004 at the link line.
bad_link="${work}/bad-link/SKILL.md"
mkdir -p "${work}/bad-link"
cat >"${bad_link}" <<'EOF'
---
name: bad-link
description: Points at a reference that does not exist.
---

# Bad

See [the missing doc](references/missing.md) for details.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${bad_link}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "dangling link fails" || no "dangling link fails (exit 0)"
case "${out}" in
*":8: SKILL004"*) ok "dangling link cites SKILL004 at the link line" ;;
*) no "dangling link cites SKILL004 at the link line (got: ${out:0:150})" ;;
esac

# 6. Links RED: a dangling reference-style link target fires SKILL004.
bad_ref="${work}/bad-ref/SKILL.md"
mkdir -p "${work}/bad-ref"
cat >"${bad_ref}" <<'EOF'
---
name: bad-ref
description: Points at a reference definition that does not exist.
---

# Bad

See [the missing doc][rf] for details.

[rf]: references/missing.md
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${bad_ref}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "dangling reference target fails" || no "dangling reference target fails (exit 0)"
case "${out}" in
*":10: SKILL004"*) ok "dangling reference target cites SKILL004 at the definition line" ;;
*) no "dangling reference target cites SKILL004 at the definition line (got: ${out:0:150})" ;;
esac

# 7. Links GREEN: a titled link to an existing file passes Tier 1.
titled="${work}/titled/SKILL.md"
mkdir -p "${work}/titled/references"
printf -- '# Guide\n' >"${work}/titled/references/guide.md"
cat >"${titled}" <<'EOF'
---
name: titled
description: Titled link to a file that exists.
---

# Titled

See [the guide](references/guide.md "Guide title") for details.

## Workflow

1. Do the thing with one objective.
2. Check the result before moving on.

```bash
run-the-thing
```

## Error recovery

If it fails, read the log and fix the cited line.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${titled}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "titled link to existing file passes" || no "titled link to existing file passes (exit ${code}: ${out:0:150})"
case "${out}" in
*"SKILL004"*) no "titled link to existing file fires no SKILL004 (got: ${out:0:150})" ;;
*) ok "titled link to existing file fires no SKILL004" ;;
esac

# 8. Links GREEN: whitespace and quote variants of titles still resolve.
titled2="${work}/titled2/SKILL.md"
mkdir -p "${work}/titled2/references"
printf -- '# Guide\n' >"${work}/titled2/references/guide.md"
cat >"${titled2}" <<'EOF'
---
name: titled2
description: Title separator and quote variants.
---

# Titled

See [multi](references/guide.md  "spaced") and [apos](references/guide.md "it's") for details.
EOF
printf 'See [tab](references/guide.md\t"tabbed") for details.\n' >>"${titled2}"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${titled2}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "title variants resolve to the existing file" || no "title variants resolve to the existing file (exit ${code}: ${out:0:150})"
case "${out}" in
*"SKILL004"*) no "title variants fire no SKILL004 (got: ${out:0:150})" ;;
*) ok "title variants fire no SKILL004" ;;
esac

# 9. Links RED: a full reference use with no definition fails.
ref_use="${work}/ref-use/SKILL.md"
mkdir -p "${work}/ref-use"
cat >"${ref_use}" <<'EOF'
---
name: ref-use
description: Reference use whose label is never defined.
---

# Bad

See [the guide][nosuch] here.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${ref_use}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "undefined reference use fails" || no "undefined reference use fails (exit 0)"
case "${out}" in
*"SKILL004"*) ok "undefined reference use cites SKILL004" ;;
*) no "undefined reference use cites SKILL004 (got: ${out:0:120})" ;;
esac

# 10. Links ADVISORY: an undefined shortcut reference prints SKILL004
# without failing, since bare brackets cannot prove link intent.
ref_short="${work}/ref-short/SKILL.md"
mkdir -p "${work}/ref-short"
cat >"${ref_short}" <<'EOF'
---
name: ref-short
description: Shortcut reference whose label is never defined.
---

# Bad

See [nosuch] here.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${ref_short}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "undefined shortcut reference stays exit 0" || no "undefined shortcut reference stays exit 0 (exit ${code})"
case "${out}" in
*"SKILL004 (advisory)"*) ok "undefined shortcut reference prints a SKILL004 advisory" ;;
*) no "undefined shortcut reference prints a SKILL004 advisory (got: ${out:0:150})" ;;
esac

# 11. Links GREEN: defined full, collapsed, and shortcut uses pass.
ref_ok="${work}/ref-ok/SKILL.md"
mkdir -p "${work}/ref-ok/references"
printf -- '# Guide\n' >"${work}/ref-ok/references/guide.md"
cat >"${ref_ok}" <<'EOF'
---
name: ref-ok
description: Every reference use has a definition.
---

# Fine

See [the guide][present] and [present][] and [present] for details.

[present]: references/guide.md
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${ref_ok}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "defined reference uses pass" || no "defined reference uses pass (exit ${code}: ${out:0:150})"
case "${out}" in
*"SKILL004"*) no "defined reference uses fire no SKILL004 (got: ${out:0:150})" ;;
*) ok "defined reference uses fire no SKILL004" ;;
esac

# 12. Links GREEN: leading-dash labels match their definitions.
ref_dash="${work}/ref-dash/SKILL.md"
mkdir -p "${work}/ref-dash/references"
printf -- '# Guide\n' >"${work}/ref-dash/references/guide.md"
cat >"${ref_dash}" <<'EOF'
---
name: ref-dash
description: Leading-dash label on both sides.
---

# Fine

See [a][-foo] here.

[-foo]: references/guide.md
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${ref_dash}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "leading-dash reference uses pass" || no "leading-dash reference uses pass (exit ${code}: ${out:0:150})"
case "${out}" in
*"SKILL004"*) no "leading-dash reference uses fire no SKILL004 (got: ${out:0:150})" ;;
*) ok "leading-dash reference uses fire no SKILL004" ;;
esac

# 13. Links GREEN: whitespace-collapsed labels match their definitions.
ref_ws="${work}/ref-ws/SKILL.md"
mkdir -p "${work}/ref-ws/references"
printf -- '# Guide\n' >"${work}/ref-ws/references/guide.md"
cat >"${ref_ws}" <<'EOF'
---
name: ref-ws
description: Equivalent labels with different inner spacing.
---

# Fine

See [the guide][my  label] here.

[my label]: references/guide.md
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${ref_ws}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "whitespace-variant reference uses pass" || no "whitespace-variant reference uses pass (exit ${code}: ${out:0:150})"
case "${out}" in
*"SKILL004"*) no "whitespace-variant reference uses fire no SKILL004 (got: ${out:0:150})" ;;
*) ok "whitespace-variant reference uses fire no SKILL004" ;;
esac

# 14. Size RED: a line-count oversized skill fires SKILL005.
big="${work}/big/SKILL.md"
mkdir -p "${work}/big"
{
	printf -- '---\nname: big\ndescription: Oversized fixture.\n---\n\n# Big\n\n'
	for _ in $(seq 1 600); do printf 'Filler line.\n'; done
} >"${big}"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${big}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "oversized skill fails" || no "oversized skill fails (exit 0)"
case "${out}" in
*"SKILL005"*) ok "oversized skill cites SKILL005" ;;
*) no "oversized skill cites SKILL005 (got: ${out:0:120})" ;;
esac

# 15. Size RED: narrow lines but over the byte cap still fires SKILL005.
wide="${work}/wide/SKILL.md"
mkdir -p "${work}/wide"
{
	printf -- '---\nname: wide\ndescription: Many bytes, few lines.\n---\n\n# Wide\n\n'
	for _ in $(seq 1 400); do
		printf '0123456789%.0s' $(seq 1 10)
		printf '\n'
	done
} >"${wide}"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${wide}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "byte-heavy skill fails" || no "byte-heavy skill fails (exit 0)"
case "${out}" in
*"SKILL005"*) ok "byte-heavy skill cites SKILL005" ;;
*) no "byte-heavy skill cites SKILL005 (got: ${out:0:120})" ;;
esac

# 16. Verification RED: no numbered steps and no fences print advisories
# but stay exit 0 (Tier 2 never blocks).
bare="${work}/bare/SKILL.md"
mkdir -p "${work}/bare"
cat >"${bare}" <<'EOF'
---
name: bare
description: Prose-only fixture with no steps, commands, or recovery.
---

# Bare

Some guidance with no structure at all.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${bare}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "Tier 2 gaps do not fail the run" || no "Tier 2 gaps do not fail the run (exit ${code})"
for rule in SKILL006 SKILL007 SKILL008; do
	case "${out}" in
	*"${rule}"*"advisory"*) ok "${rule} advisory prints for the bare fixture" ;;
	*) no "${rule} advisory prints for the bare fixture (got: ${out:0:150})" ;;
	esac
done

# 17. Recovery RED: a body whose only recovery advice is "try again" still
# fires SKILL008, and a real recovery section clears it.
retry="${work}/retry/SKILL.md"
mkdir -p "${work}/retry"
cat >"${retry}" <<'EOF'
---
name: retry
description: Recovery section that only says try again.
---

# Retry

## Workflow

1. Run the thing.

```bash
run-the-thing
```

## Error recovery

If it fails, try again.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${retry}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "try-again-only stays exit 0" || no "try-again-only stays exit 0 (exit ${code})"
case "${out}" in
*"SKILL008"*) ok "\"try again\" alone still fires SKILL008" ;;
*) no "\"try again\" alone still fires SKILL008 (got: ${out:0:150})" ;;
esac
case "${out}" in
*"SKILL006"* | *"SKILL007"*) no "retry fixture fires only SKILL008 (got: ${out:0:150})" ;;
*) ok "retry fixture fires only SKILL008" ;;
esac

# 18. Baseline GREEN: a listed Tier 2 exemption suppresses the advisory,
# while Tier 1 still fires for a listed skill.
fixture_base="${work}/baseline.tsv"
printf 'bare\tSKILL006\tFixture exemption for the suite.\n' >"${fixture_base}"
out="$(bash "${LINT}" --baseline "${fixture_base}" "${bare}" 2>&1)"
case "${out}" in
*"SKILL006"*) no "baseline suppresses the listed SKILL006 advisory" ;;
*) ok "baseline suppresses the listed SKILL006 advisory" ;;
esac
case "${out}" in
*"1 suppressed"*) ok "suppression is counted in the summary" ;;
*) no "suppression is counted in the summary (got: ${out:0:150})" ;;
esac
printf 'bad-link\tSKILL004\tTier 1 is never suppressible, even when listed.\n' >>"${fixture_base}"
out="$(bash "${LINT}" --baseline "${fixture_base}" "${bad_link}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "Tier 1 fires despite a baseline row" || no "Tier 1 fires despite a baseline row (exit 0)"
case "${out}" in
*"SKILL004"*) ok "Tier 1 is never suppressed by the baseline" ;;
*) no "Tier 1 is never suppressed by the baseline (got: ${out:0:150})" ;;
esac

# 19. Baseline hygiene: every shipped exemption names a skill that exists,
# so NEW skills cannot arrive pre-exempted.
stale=0
while IFS=$'\t' read -r skill _rule _reason; do
	case "${skill}" in '' | \#*) continue ;; esac
	if [[ ! -d "${repo_root}/skills/eshu/${skill}" && ! -d "${repo_root}/skills/core/${skill}" ]]; then
		printf 'stale baseline row for missing skill: %s\n' "${skill}"
		stale=1
	fi
done <"${BASELINE}"
[ "${stale}" = "0" ] && ok "every baseline row names an existing skill" || no "every baseline row names an existing skill"

printf '\nskill-lint mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

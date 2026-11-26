#!/usr/bin/env bash
# Behavioural mirror for scripts/skill-lint.sh SKILL004 (#81).
#
# Link-target cases: inline, reference-style, and shortcut uses against
# fixture skills in a temp dir; the real tree is never mutated. Tier 1
# failures exit nonzero with the rule and line cited; Tier 2 findings
# print as advisories and exit 0.
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

# 1. Links RED: a dangling relative link fires SKILL004 at the link line.
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
fixture_base="${work}/links-baseline.tsv"
printf 'bad-link\tSKILL004\tTier 1 is never suppressible, even when listed.\n' >"${fixture_base}"
out="$(bash "${LINT}" --baseline "${fixture_base}" "${bad_link}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "SKILL004 fires despite a baseline row" || no "SKILL004 fires despite a baseline row (exit 0)"
case "${out}" in
*"SKILL004"*) ok "SKILL004 citation present despite baseline row" ;;
*) no "SKILL004 citation present despite baseline row (got: ${out:0:120})" ;;
esac

# 2. Links RED: a dangling reference-style link target fires SKILL004.
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

# 3. Links GREEN: a titled link to an existing file passes Tier 1.
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

# 4. Links GREEN: whitespace and quote variants of titles still resolve.
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

# 5. Links RED: a full reference use with no definition fails.
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

# 6. Links ADVISORY: an undefined shortcut reference prints SKILL004
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

# 7. Links GREEN: defined full, collapsed, and shortcut uses pass.
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

# 8. Links GREEN: leading-dash labels match their definitions.
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

# 9. Links GREEN: whitespace-collapsed labels match their definitions.
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

# 10. Links RED: a collapsed reference use with no definition fails.
ref_collapsed="${work}/ref-collapsed/SKILL.md"
mkdir -p "${work}/ref-collapsed"
cat >"${ref_collapsed}" <<'EOF'
---
name: ref-collapsed
description: Collapsed reference use whose label is never defined.
---

# Bad

See [nosuch][] here.
EOF
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${ref_collapsed}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "collapsed reference use without a definition fails" || no "collapsed reference use without a definition fails (exit 0)"
case "${out}" in
*"SKILL004"*) ok "collapsed reference use cites SKILL004" ;;
*) no "collapsed reference use cites SKILL004 (got: ${out:0:120})" ;;
esac

# 11. Links GREEN: trailing whitespace before the closing paren is not
# part of the target (CommonMark strips it), so a titled link with a
# trailing space still resolves to the existing file.
titled_ws="${work}/titled-ws/SKILL.md"
mkdir -p "${work}/titled-ws/references"
printf -- '# Guide\n' >"${work}/titled-ws/references/guide.md"
printf -- '%s\n' '---' 'name: titled-ws' 'description: Titled link with trailing space before the paren.' '---' '' '# Titled' '' 'See [the guide](references/guide.md "Guide title" ) for details.' >"${titled_ws}"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${titled_ws}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "titled link with trailing space passes" || no "titled link with trailing space passes (exit ${code}: ${out:0:150})"
case "${out}" in
*"SKILL004"*) no "titled link with trailing space fires no SKILL004 (got: ${out:0:150})" ;;
*) ok "titled link with trailing space fires no SKILL004" ;;
esac

printf '\nskill-lint-links mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

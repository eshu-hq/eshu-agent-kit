#!/usr/bin/env bash
# Behavioural mirror for scripts/skill-lint.sh (#81).
#
# One RED/GREEN seeded pair per rule family (structure, size,
# verification, error recovery), run against fixture skills in a temp dir:
# the real tree is never mutated. Tier 1 failures exit nonzero with the
# rule and line cited; Tier 2 findings print as advisories and exit 0.
# Link-target cases live in test-skill-lint-links.sh.
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

# 5. Size RED: a line-count oversized skill fires SKILL005.
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

# 6. Size RED: narrow lines but over the byte cap still fires SKILL005.
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

# 7. Verification RED: no numbered steps and no fences print advisories
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

# 8. Recovery RED: a body whose only recovery advice is "try again" still
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

# 9. Baseline GREEN: a listed Tier 2 exemption suppresses the advisory,
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
printf 'big\tSKILL005\tTier 1 is never suppressible, even when listed.\n' >>"${fixture_base}"
out="$(bash "${LINT}" --baseline "${fixture_base}" "${big}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "Tier 1 fires despite a baseline row" || no "Tier 1 fires despite a baseline row (exit 0)"
case "${out}" in
*"SKILL005"*) ok "Tier 1 is never suppressed by the baseline" ;;
*) no "Tier 1 is never suppressed by the baseline (got: ${out:0:150})" ;;
esac

# 10. Baseline hygiene: every shipped exemption names a skill that exists,
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

# 11. SKILL009 RED/ADVISORY/GREEN: description token budget (>600 error,
# 401-600 advisory, <=400 clean).
make_desc_skill() {
	local name="$1" len="$2"
	local dir="${work}/${name}"
	local pad
	mkdir -p "${dir}"
	pad="$(python3 -c "print('a' * ${len})")"
	cat >"${dir}/SKILL.md" <<EOF
---
name: ${name}
description: ${pad}
---

# ${name}

## Workflow

1. Run the check.

\`\`\`bash
echo ok
\`\`\`

## Error recovery

When the check fails, read the cited line and fix it.
EOF
	printf '%s' "${dir}/SKILL.md"
}

desc_err="$(make_desc_skill desc-err 601)"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${desc_err}" 2>&1)"
code=$?
[ "${code}" != "0" ] && ok "SKILL009 >600 chars fails" || no "SKILL009 >600 chars fails (exit 0)"
case "${out}" in
*"SKILL009 (error)"*) ok "SKILL009 >600 chars cites SKILL009 (error)" ;;
*) no "SKILL009 >600 chars cites SKILL009 (error) (got: ${out:0:150})" ;;
esac

desc_adv="$(make_desc_skill desc-adv 450)"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${desc_adv}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "SKILL009 401-600 chars stays exit 0" || no "SKILL009 401-600 chars stays exit 0 (exit ${code})"
case "${out}" in
*"SKILL009 (advisory)"*) ok "SKILL009 401-600 chars emits SKILL009 (advisory)" ;;
*) no "SKILL009 401-600 chars emits SKILL009 (advisory) (got: ${out:0:150})" ;;
esac

desc_ok="$(make_desc_skill desc-ok 400)"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${desc_ok}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "SKILL009 <=400 chars passes" || no "SKILL009 <=400 chars passes (exit ${code})"
case "${out}" in
*"SKILL009"*) no "SKILL009 <=400 chars emits no SKILL009 (got: ${out:0:150})" ;;
*) ok "SKILL009 <=400 chars emits no SKILL009" ;;
esac

# 12. SKILL010 RED/GREEN: >200 lines without references/ or scripts/ triggers
# advisory; adding references/ clears it.
long_skill="${work}/long-skill/SKILL.md"
mkdir -p "${work}/long-skill"
{
	cat <<'EOF'
---
name: long-skill
description: Longer skill testing progressive disclosure.
---

# Long skill

## Workflow

1. Run the check.

```bash
echo ok
```

## Error recovery

When the check fails, read the cited line and fix it.
EOF
	for _ in $(seq 1 200); do printf 'Detail line.\n'; done
} >"${long_skill}"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${long_skill}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "SKILL010 stays exit 0" || no "SKILL010 stays exit 0 (exit ${code})"
case "${out}" in
*"SKILL010 (advisory)"*) ok "SKILL010 fires over 200 lines with no references/ or scripts/" ;;
*) no "SKILL010 fires over 200 lines with no references/ or scripts/ (got: ${out:0:150})" ;;
esac

mkdir -p "${work}/long-skill/references"
out="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" "${long_skill}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "SKILL010 with references/ passes" || no "SKILL010 with references/ passes (exit ${code})"
case "${out}" in
*"SKILL010"*) no "adding references/ clears SKILL010 (got: ${out:0:150})" ;;
*) ok "adding references/ clears SKILL010" ;;
esac

# 13. --json output: valid JSON with expected fields; exits 1 on Tier 1 error.
json_ok="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" --json "${good}" "${long_skill}" 2>&1)"
code=$?
[ "${code}" = "0" ] && ok "--json exits 0 when clean" || no "--json exits 0 when clean (exit ${code})"
if python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["checked"] == 2 and d["errors"] == 0 and d["advisories"] == 0 and d["suppressed"] == 0
by_name = {s["skill"]: s for s in d["skills"]}
assert set(by_name) == {"good", "long-skill"}
assert by_name["good"]["has_references"] is False and by_name["long-skill"]["has_references"] is True
for s in by_name.values():
    for k in ("path", "lines", "bytes", "desc_chars", "est_desc_tokens", "est_body_tokens", "has_scripts", "errors", "advisories"):
        assert k in s, f"missing {k}"
    assert s["est_desc_tokens"] > 0 and s["est_body_tokens"] > 0
' <<<"${json_ok}"; then
	ok "--json emits valid JSON with token counts, has_references, and skills list"
else
	no "--json emits valid JSON with token counts, has_references, and skills list"
fi

json_err="$(bash "${LINT}" --baseline "${EMPTY_BASELINE}" --json "${desc_err}" 2>&1)"
code=$?
[ "${code}" = "1" ] && ok "--json exits 1 on Tier 1 error" || no "--json exits 1 on Tier 1 error (exit ${code})"
if python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["checked"] == 1 and d["errors"] == 1
assert len(d["skills"]) == 1 and d["skills"][0]["errors"][0]["rule"] == "SKILL009"
' <<<"${json_err}"; then
	ok "--json records Tier 1 error in skills[].errors"
else
	no "--json records Tier 1 error in skills[].errors"
fi

printf '\nskill-lint mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

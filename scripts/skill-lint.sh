#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# skill-lint.sh - content linter for skills/**/SKILL.md (#81).
#
# Usage: bash scripts/skill-lint.sh [--baseline <file>] [<path> ...]
#
# With no paths, scans skills/*/SKILL.md and skills/*/*/SKILL.md
# (today: skills/eshu/*/SKILL.md; tomorrow also skills/core/*/SKILL.md).
# Exit 0 when every Tier 1 check passes, 1 naming each failure otherwise.
# Tier 2 findings print as advisories and never fail the run.
#
# Rule list (single source of truth; linked from skills/registry.md).
# New rules from review findings get added here, not improvised per skill.
#
# Tier 1 (blocking): the structural minimum. A skill that fails one of
# these is malformed or points at nothing, so the run fails.
#   SKILL001  Frontmatter carries a non-empty `name:` field.
#   SKILL002  Frontmatter carries a non-empty `description:` field.
#   SKILL003  `name:` matches the parent directory basename, so the
#             install.sh basename link and the skill name agree.
#   SKILL004  Every relative link target resolves to a file that exists,
#             relative to the SKILL.md directory (same class as #5905:
#             a pointer that looks authoritative while resolving to
#             nothing). Absolute paths, http(s) URLs, and pure #anchors
#             are out of scope.
#   SKILL005  Size cap: at most 500 lines and 32768 bytes. Matches the
#             repo 500-line cap; oversized skills split like code does.
#
# Tier 2 (advisory): the Uber-distilled body shape. Printed, never
# blocking. Existing skills carry per-skill exemptions with reasons in
# scripts/skill-lint-baseline.tsv; NEW skills get no baseline entries,
# so their advisories stay visible until the body earns them.
#   SKILL006  Numbered steps with one objective each: the body has at
#             least one `N. ` step line.
#   SKILL007  Concrete command or check per step: the body has at least
#             one fenced code block carrying the command to run.
#   SKILL008  Error-recovery section: a non-heading body line names a
#             recovery, troubleshooting, failure, mistake, gotcha,
#             fallback, or rollback path. A heading alone and a bare
#             "try again" do not count.
#
# Output is shellcheck-style: <file>:<line>: <RULE> (<tier>): <detail>.
set -euo pipefail
export LC_ALL=C

KIT_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null ||
	(cd "$(dirname "$0")/.." && pwd))"
BASELINE="${KIT_DIR}/scripts/skill-lint-baseline.tsv"

targets=()
while (($# > 0)); do
	case "$1" in
	--baseline)
		BASELINE="${2:?--baseline needs a file}"
		shift 2
		;;
	-h | --help)
		sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		targets+=("$1")
		shift
		;;
	esac
done

files=()
if ((${#targets[@]} == 0)); then
	shopt -s nullglob
	files=("${KIT_DIR}"/skills/*/SKILL.md "${KIT_DIR}"/skills/*/*/SKILL.md)
	shopt -u nullglob
else
	for t in "${targets[@]}"; do
		if [[ -d "${t}" ]]; then
			files+=("${t}/SKILL.md")
		else
			files+=("${t}")
		fi
	done
fi

# Baseline: skill<TAB>rule<TAB>reason. Tier 2 only; Tier 1 never suppresses.
declare -A exempt=()
if [[ -f "${BASELINE}" ]]; then
	while IFS=$'\t' read -r skill rule _reason; do
		case "${skill}" in '' | \#*) continue ;; esac
		exempt["${skill}|${rule}"]=1
	done <"${BASELINE}"
fi

errors=0
advisories=0
suppressed=0
checked=0

err() { # file line rule detail
	printf '%s:%s: %s (error): %s\n' "$1" "$2" "$3" "$4"
	errors=$((errors + 1))
}
adv() { # skill file line rule detail
	if [[ -n "${exempt["$1|$4"]:-}" ]]; then
		suppressed=$((suppressed + 1))
		return 0
	fi
	printf '%s:%s: %s (advisory): %s\n' "$2" "$3" "$4" "$5"
	advisories=$((advisories + 1))
}
norm_label() { # canonicalize a reference label the CommonMark way
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
		sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g'
}

for skill_file in "${files[@]}"; do
	rel="${skill_file#"${KIT_DIR}"/}"
	skill="$(basename "$(dirname "${skill_file}")")"
	checked=$((checked + 1))

	if [[ ! -f "${skill_file}" ]]; then
		err "${rel}" 1 SKILL001 "no such SKILL.md"
		continue
	fi

	# Frontmatter block: line 1 must open it, first closing --- ends it.
	body_start=1
	name=""
	name_line=1
	desc=""
	if [[ "$(head -n 1 "${skill_file}")" == "---" ]]; then
		end="$(awk 'NR>1 && /^---$/{print NR; exit}' "${skill_file}")"
		if [[ -n "${end}" ]]; then
			body_start=$((end + 1))
			name="$(awk -v e="${end}" 'NR>1 && NR<e && /^name:[[:space:]]*/{sub(/^name:[[:space:]]*/, ""); print; exit}' "${skill_file}")"
			name_line="$(awk -v e="${end}" 'NR>1 && NR<e && /^name:[[:space:]]*/{print NR; exit}' "${skill_file}")"
			desc="$(awk -v e="${end}" 'NR>1 && NR<e && /^description:[[:space:]]*/{sub(/^description:[[:space:]]*/, ""); print; exit}' "${skill_file}")"
		fi
	fi
	name="$(printf '%s' "${name}" | sed -e 's/^["'\'']//' -e 's/["'\'']$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
	desc="$(printf '%s' "${desc}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
	[[ -z "${name_line}" ]] && name_line=1

	# SKILL001 / SKILL002: frontmatter name and description present.
	if [[ -z "${name}" ]]; then
		err "${rel}" 1 SKILL001 "frontmatter carries no non-empty name: field"
	else
		# SKILL003: name matches the directory it ships in.
		if [[ "${name}" != "${skill}" ]]; then
			err "${rel}" "${name_line}" SKILL003 "name '${name}' does not match directory '${skill}'"
		fi
	fi
	if [[ -z "${desc}" ]]; then
		err "${rel}" 1 SKILL002 "frontmatter carries no non-empty description: field"
	fi

	# SKILL004: every relative link target resolves, inline or
	# reference-style. An optional quoted title is not part of the target.
	# Known boundary (not checked): a quoted title containing ")" truncates
	# the target at the first paren, since the inline extractor stops there.
	while IFS= read -r hit; do
		lnum="${hit%%:*}"
		target="${hit#*:}"
		case "${target}" in
		http://* | https://* | mailto:* | \#* | /*) continue ;;
		esac
		target="$(printf '%s' "${target}" | sed -e "s/[[:space:]][[:space:]]*\"[^\"]*\"$//" -e "s/[[:space:]][[:space:]]*'[^']*'$//")"
		target="${target%%\#*}"
		[[ -z "${target}" ]] && continue
		if [[ ! -e "$(dirname "${skill_file}")/${target}" ]]; then
			err "${rel}" "${lnum}" SKILL004 "link target '${target}' resolves to nothing"
		fi
	done < <({
		rg -n --no-heading -o '\]\(([^)]+)\)' "${skill_file}" 2>/dev/null |
			sed -e 's/:](\(.*\))$/:\1/'
		rg -n --no-heading -o '^[[:space:]]*\[[^]]+\]:[[:space:]]*[^[:space:]]+' "${skill_file}" 2>/dev/null |
			sed -e 's/^\([0-9][0-9]*\):\[[^]]*\]:[[:space:]]*\(.*\)$/\1:\2/'
	} || true)
	# SKILL004, reference uses: [text][label], [label][], and shortcut
	# [label] each need a matching [label]: definition (case-insensitive).
	defined_labels="$(rg --no-heading -o '^[[:space:]]*\[[^]]+\]:' "${skill_file}" 2>/dev/null |
		sed -e 's/^[[:space:]]*\[//' -e 's/\]:$//' |
		while IFS= read -r raw; do norm_label "${raw}"; done || true)"
	while IFS= read -r use; do
		ulnum="${use%%:*}"
		pair="${use#*:}"
		text="${pair%%\]*}"
		text="${text#\[}"
		rest="${pair#*\]\[}"
		label="${rest%\]}"
		[[ -z "${label}" ]] && label="${text}"
		[[ -z "${label}" ]] && continue
		label="$(norm_label "${label}")"
		if ! printf '%s\n' "${defined_labels}" | rg -qxF -- "${label}" 2>/dev/null; then
			err "${rel}" "${ulnum}" SKILL004 "reference '[${label}]' has no matching definition"
		fi
	done < <(rg -n --no-heading -o '\[[^]]*\]\[[^]]*\]' "${skill_file}" 2>/dev/null || true)
	# Bare [label] cannot prove link intent ([fill-in: ...], [string], and
	# quoted prose all use bare brackets without referencing anything), so
	# an undefined shortcut is advisory, not blocking. Full and collapsed
	# uses above stay Tier 1: their syntax is unambiguous reference intent.
	while IFS= read -r use; do
		ulnum="${use%%:*}"
		fragment="${use#*:}"
		case "${fragment}" in
		"!"*) continue ;;
		*"(" | *"[" | *":") continue ;;
		esac
		inner="$(printf '%s' "${fragment}" | sed -e 's/^[^\[]*\[//' -e 's/\].*//')"
		inner="${inner#\[}"
		[[ -z "${inner}" ]] && continue
		label="$(norm_label "${inner}")"
		if ! printf '%s\n' "${defined_labels}" | rg -qxF -- "${label}" 2>/dev/null; then
			adv "${skill}" "${rel}" "${ulnum}" SKILL004 "possible shortcut reference '[${label}]' has no matching definition"
		fi
	done < <(rg -n --no-heading -o '.?\[[^]]+\].?' "${skill_file}" 2>/dev/null || true)

	# SKILL005: size cap.
	lines="$(wc -l <"${skill_file}" | tr -d ' ')"
	bytes="$(wc -c <"${skill_file}" | tr -d ' ')"
	if ((lines > 500)) || ((bytes > 32768)); then
		err "${rel}" 1 SKILL005 "SKILL.md is ${lines} lines / ${bytes} bytes (cap 500 lines / 32768 bytes): split it"
	fi

	# Tier 2 runs over the body only (after frontmatter).
	body="$(tail -n +"${body_start}" "${skill_file}")"

	# SKILL006: at least one numbered step.
	if ! printf '%s' "${body}" | rg -q '^[0-9]+\. '; then
		adv "${skill}" "${rel}" 1 SKILL006 "no numbered steps: write the workflow as N. one-objective steps"
	fi

	# SKILL007: at least one fenced command block.
	if ! printf '%s' "${body}" | rg -q '^[[:space:]]*```'; then
		adv "${skill}" "${rel}" 1 SKILL007 "no fenced command block: give each step a concrete command or check to run"
	fi

	# SKILL008: an error-recovery section with real content: headings alone
	# and bare "try again" lines are ignored.
	recovery_left="$(printf '%s' "${body}" | rg -v -i 'try again' | rg -v '^[[:space:]]*#' | rg -i -c 'recover|troubleshoot|failure|mistake|gotcha|fallback|rollback|when .*fail|if .*fail' || true)"
	if [[ -z "${recovery_left}" || "${recovery_left}" == "0" ]]; then
		adv "${skill}" "${rel}" 1 SKILL008 "no error-recovery section: name the failure path and the fix (\"try again\" does not count)"
	fi
done

printf 'skill-lint: %s files, %s errors, %s advisories (%s suppressed by baseline)\n' \
	"${checked}" "${errors}" "${advisories}" "${suppressed}"
exit "$((errors > 0 ? 1 : 0))"

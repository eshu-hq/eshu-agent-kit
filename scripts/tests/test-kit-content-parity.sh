#!/usr/bin/env bash
# Regression coverage for kit content parity with the eshu review regime.
#
# Guards two ported behaviors:
# 1. The fixed-awaiting-push transfer and inherited-breakage dispositions
#    live in the kit review skills (they were dropped in the rename move).
# 2. No skill links into docs/eshu: installed skills are symlinks, so a
#    relative ../../../docs/eshu link dangles outside the kit. Eshu values
#    for the generic [fill-in: ...] placeholders live in exactly one place,
#    templates/repo-overlay/eshu-adapter.md.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS="${repo_root}/skills/eshu"
ADAPTER="${repo_root}/templates/repo-overlay/eshu-adapter.md"

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

# 1. No relative link into docs/eshu survives under skills/.
dangling=$(rg -l --no-heading '\]\(.*docs/eshu' -g '*.md' "${repo_root}/skills" 2>/dev/null || true)
if [ -z "${dangling}" ]; then
	ok "no skill links into docs/eshu"
else
	no "no skill links into docs/eshu (found in: ${dangling})"
fi

# 2. Every process-doc placeholder key resolves in the adapter.
keys=(
	"fill-in: merge rule"
	"fill-in: model bindings"
	"fill-in: orchestration model"
	"fill-in: orchestration, PR, and CI discipline"
	"fill-in: undecided-design escalation"
	"fill-in: verification details"
	"fill-in: timing proof rules"
	"fill-in: naming standard"
	"fill-in: restack rule"
	"fill-in: contract system"
	"fill-in: telemetry precedent"
	"fill-in: query engineering"
	"fill-in: release process"
	"fill-in: communication standard"
	"fill-in: issue capture hooks"
)
for key in "${keys[@]}"; do
	if rg -q --fixed-strings "${key}" "${SKILLS}" 2>/dev/null; then
		ok "placeholder used: ${key}"
	else
		no "placeholder used: ${key} (no skill references it)"
	fi
	if rg -q --fixed-strings "${key}" "${ADAPTER}" 2>/dev/null; then
		ok "adapter covers: ${key}"
	else
		no "adapter covers: ${key} (missing from eshu-adapter.md)"
	fi
done

# 3. Fixed-awaiting-push transfer disposition is ported.
REVIEW="${SKILLS}/code-review/SKILL.md"
MERGEBAR="${SKILLS}/code-review/references/merge-bar.md"
VERDICT="${SKILLS}/code-review/references/verdict.md"
REBASE="${SKILLS}/session-lifecycle/references/rebase-verify.md"
if rg -q --fixed-strings "### Fixed-awaiting-push transfer across a content-identical rebase" "${REVIEW}" 2>/dev/null; then
	ok "transfer section present in code-review SKILL"
else
	no "transfer section present in code-review SKILL"
fi
for probe in \
	"${REVIEW}|unless the [fixed-awaiting-push transfer](#fixed-awaiting-push-transfer-across-a-content-identical-rebase) holds" \
	"${REVIEW}|git diff <base>..HEAD | git patch-id --stable" \
	"${REVIEW}|never as a zero count" \
	"${REVIEW}|The waiver note, the fixed-awaiting-push transfer note, and the scoped rebase" \
	"${REVIEW}|A waiver or transfer receipt proves only that the note and the inputs did" \
	"${REVIEW}|inherited-breakage" \
	"${MERGEBAR}|the fixed-awaiting-push" \
	"${VERDICT}|A row 2 rebase takes the fixed-awaiting-push transfer note only" \
	"${REBASE}|the fixed-awaiting-push transfer note (row 2," \
	; do
	path="${probe%%|*}"
	need="${probe#*|}"
	if rg -q --fixed-strings "${need}" "${path}" 2>/dev/null; then
		ok "ported disposition text: $(basename "${path}"): ${need:0:60}"
	else
		no "ported disposition text: $(basename "${path}"): ${need:0:60}"
	fi
done

# 4. RED check: the link scan flags a synthetic docs/eshu link.
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/skills/eshu/demo"
printf '# Demo\n\nSee [doc](../../../docs/eshu/agent-guide.md).\n' >"${work}/skills/eshu/demo/SKILL.md"
if rg -l --no-heading '\]\(.*docs/eshu' -g '*.md' "${work}/skills" 2>/dev/null | rg -q demo; then
	ok "link scan flags a synthetic docs/eshu link (RED)"
else
	no "link scan flags a synthetic docs/eshu link (RED)"
fi

printf '\nkit-content-parity: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

#!/usr/bin/env bash
# Behavioural mirror for hooks/eshu-doc-staleness.sh.
#
# The hook is a pure signal: it must exit 0 whether the checker runs or not,
# and degrade to a no-op when the consuming repo did not install
# scripts/check-docs-stale.sh. With the checker present, a stale README under
# go/ must produce a snapshot entry in .eshu-doc-state/stale.jsonl.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${repo_root}/eshu-doc-staleness.sh"
CHECKER_SRC="${repo_root}/../scripts/check-docs-stale.sh"

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

# 1. Missing checker degrades to a silent no-op.
plain="${work}/plain"
mkdir -p "${plain}"
printf '' | CLAUDE_PROJECT_DIR="${plain}" bash "${HOOK}" >/dev/null 2>&1
code=$?
if [ "${code}" = "0" ]; then ok "missing checker exits 0"; else no "missing checker exits 0 (got ${code})"; fi
if [ ! -e "${plain}/.eshu-doc-state" ]; then ok "missing checker writes no state"; else no "missing checker writes no state"; fi

# 2. Present checker flags a stale README and still exits 0.
repo="${work}/repo"
mkdir -p "${repo}/scripts" "${repo}/go/pkg"
cp "${CHECKER_SRC}" "${repo}/scripts/check-docs-stale.sh"
printf 'package pkg\n' >"${repo}/go/pkg/foo.go"
printf '# pkg\n' >"${repo}/go/pkg/README.md"
printf 'package pkg\n' >"${repo}/go/pkg/doc.go"
touch -d '2020-01-01' "${repo}/go/pkg/README.md" "${repo}/go/pkg/doc.go"
out=$(printf '' | CLAUDE_PROJECT_DIR="${repo}" bash "${HOOK}" 2>&1)
code=$?
if [ "${code}" = "0" ]; then ok "checker run exits 0"; else no "checker run exits 0 (got ${code})"; fi
if [ -f "${repo}/.eshu-doc-state/stale.jsonl" ]; then ok "checker writes the drift snapshot"; else no "checker writes the drift snapshot"; fi
case "${out}" in
*stale-readme*) ok "snapshot names the stale README" ;;
*) no "snapshot names the stale README (got: ${out:0:120})" ;;
esac

printf '\neshu-doc-staleness hook mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

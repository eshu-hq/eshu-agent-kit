#!/usr/bin/env bash
# hooks/tests/test-skill-nudge-docs.sh
#
# Proves skill-nudge.sh blocks edits to docs/public/*.md and docs/internal/*.md
# until eshu-publish is loaded, and allows them once loaded.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${KIT_DIR}/hooks/skill-nudge.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}" /tmp/claude-skill-loaded-docsnudgetst-*' EXIT
printf 'v0.1.0\n' >"${tmp}/.agent-kit-version"
mkdir -p "${tmp}/docs/public/guides" "${tmp}/docs/internal"

sid="docsnudgetst1"
for rel in "docs/public/guides/example.md" "docs/internal/guide.md"; do
	fp="${tmp}/${rel}"
	payload="$(printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "${sid}" "${fp}")"
	rc=0
	err="$(printf '%s' "${payload}" | bash "${HOOK}" 2>&1 >/dev/null)" || rc=$?
	if [ "${rc}" -ne 2 ]; then
		printf 'FAIL: expected exit 2 for unskilled edit to %s, got %s\n' "${rel}" "${rc}" >&2
		exit 1
	fi
	if ! printf '%s' "${err}" | rg -q 'eshu-publish'; then
		printf 'FAIL: expected eshu-publish in block message for %s, got: %s\n' "${rel}" "${err}" >&2
		exit 1
	fi
done

# Loading publish unlocks both doc surfaces.
touch "/tmp/claude-skill-loaded-docsnudgetst-publish"
for rel in "docs/public/guides/example.md" "docs/internal/guide.md"; do
	fp="${tmp}/${rel}"
	payload="$(printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "${sid}" "${fp}")"
	rc=0
	printf '%s' "${payload}" | bash "${HOOK}" >/dev/null 2>&1 || rc=$?
	if [ "${rc}" -ne 0 ]; then
		printf 'FAIL: expected exit 0 after loading publish for %s, got %s\n' "${rel}" "${rc}" >&2
		exit 1
	fi
done

printf 'PASS test-skill-nudge-docs\n'

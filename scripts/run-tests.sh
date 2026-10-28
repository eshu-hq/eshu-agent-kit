#!/usr/bin/env bash
# scripts/run-tests.sh
#
# Execute the self-hosted suites end to end. This is the body the CI
# shell-tests lane runs; run it locally the same way before pushing.
#
# Usage: bash scripts/run-tests.sh
# Exit 0 when every suite passes, 1 naming each failing suite otherwise.
#
# Suite layout: scripts/tests/ and hooks/tests/ hold standalone suites, plus
# two helper files (hooks/tests/test-goal-continue-hook-cases.sh and
# -budget-cases.sh) that the main goal-continue suite sources. Helpers are not
# standalone suites, so this runner enumerates suites explicitly instead of
# globbing test-*.sh; a new standalone suite must be added here. Skipped cases
# inside a suite must cite an open issue; a skipped suite must do the same.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

suites=(
	scripts/tests/test-claude-rules-lint.sh
	scripts/tests/test-global-install.sh
	scripts/tests/test-repo-install.sh
	hooks/tests/test-doc-staleness-hook.sh
	hooks/tests/test-goal-continue-hook.sh
	hooks/tests/test-guard-live-gate.sh
)

failed=()
for suite in "${suites[@]}"; do
	printf '=== %s ===\n' "${suite}"
	if bash "${KIT_DIR}/${suite}"; then
		printf 'PASS %s\n' "${suite}"
	else
		printf 'FAIL %s\n' "${suite}" >&2
		failed+=("${suite}")
	fi
done

if [ "${#failed[@]}" -gt 0 ]; then
	printf 'FAIL run-tests: %s\n' "${failed[*]}" >&2
	exit 1
fi
printf 'PASS run-tests: %s suites green\n' "${#suites[@]}"

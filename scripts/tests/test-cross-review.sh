#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# scripts/tests/test-cross-review.sh - Hermetic tests for scripts/cross-review.sh.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${KIT_DIR}/scripts/cross-review.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1" >&2
	failed=$((failed + 1))
}

# Build a tiny git repo with 1 commit on top of main.
repo="${WORK}/repo"
mkdir -p "${repo}" "${WORK}/bin-codex" "${WORK}/bin-empty"
git -C "${repo}" init -q -b main
git -C "${repo}" config user.email "test@example.com"
git -C "${repo}" config user.name "Test"
printf 'v1\n' >"${repo}/app.txt"
git -C "${repo}" add app.txt && git -C "${repo}" commit -q -m "base"
git -C "${repo}" checkout -q -b feat/test
printf 'v2\n' >"${repo}/app.txt"
git -C "${repo}" add app.txt && git -C "${repo}" commit -q -m "change"

# Stub codex binary.
printf '#!/usr/bin/env bash\necho "P0=0 P1=0 P2=0"\n' >"${WORK}/bin-codex/codex"
chmod +x "${WORK}/bin-codex/codex"

# 1. --help prints usage and missing flag value exits 2.
h_out="$(bash "${SCRIPT}" --help)"
set +e
bash "${SCRIPT}" --base 2>/dev/null
bad_rc=$?
set -e
if printf '%s' "${h_out}" | grep -q "cross-review.sh" && [ "${bad_rc}" -eq 2 ]; then
	ok "--help prints usage and missing flag value exits 2"
else
	no "--help prints usage and missing flag value exits 2 (rc=${bad_rc})"
fi

# 2. --current-family claude selects codex in --dry-run when codex is on PATH.
dr_out="$(PATH="${WORK}/bin-codex:/usr/bin:/bin" bash "${SCRIPT}" --repo "${repo}" --base main --current-family claude --dry-run)"
if printf '%s' "${dr_out}" | grep -q 'current_family=claude' &&
	printf '%s' "${dr_out}" | grep -q 'reviewer_family=codex' &&
	printf '%s' "${dr_out}" | grep -q 'diff_files=1'; then
	ok "selects cross-family reviewer (claude -> codex) in --dry-run"
else
	printf '%s\n' "${dr_out}" >&2
	no "selects cross-family reviewer (claude -> codex) in --dry-run"
fi

# 3. Rejects same-family --family override with exit 2.
set +e
PATH="${WORK}/bin-codex:/usr/bin:/bin" bash "${SCRIPT}" --repo "${repo}" --base main --current-family codex --family codex --dry-run 2>/dev/null
same_rc=$?
set -e
if [ "${same_rc}" -eq 2 ]; then
	ok "rejects same-family --family override (exit 2)"
else
	no "rejects same-family --family override (rc=${same_rc})"
fi

# 4. Fails open cleanly with NOT_AVAILABLE when no cross-family CLI is installed.
na_out="$(PATH="${WORK}/bin-empty:/usr/bin:/bin" bash "${SCRIPT}" --repo "${repo}" --base main --current-family claude --dry-run)"
if printf '%s' "${na_out}" | grep -q '^NOT_AVAILABLE:'; then
	ok "fails open with NOT_AVAILABLE when no cross-family CLI is on PATH"
else
	printf '%s\n' "${na_out}" >&2
	no "fails open with NOT_AVAILABLE when no cross-family CLI is on PATH"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL cross-review: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS cross-review: %d checks green\n' "${passed}"

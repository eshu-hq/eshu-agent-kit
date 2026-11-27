#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# Hermetic tests for skills/core/show-me-your-work/scripts/log.sh.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_SH="${KIT_DIR}/skills/core/show-me-your-work/scripts/log.sh"
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

# 1. Bad argument count exits 1 with usage on stderr.
if ! err="$(bash "${LOG_SH}" only two args 2>&1)" && grep -q '^usage: log.sh' <<<"${err}"; then
	ok "bad argument count exits 1 with usage"
else
	no "bad argument count exits 1 with usage"
fi

# 2. Creates parent dirs, writes header once, and appends rows with 6 tab-separated columns.
tsv="${work}/nested/decisions.tsv"
if bash "${LOG_SH}" "${tsv}" start "goal: demo" "kickoff" "sha=abc" "started" &&
	bash "${LOG_SH}" "${tsv}" verify "keep patch" "tests pass" "run.log" "ok" &&
	[ "$(wc -l <"${tsv}" | tr -d ' ')" -eq 3 ] &&
	[ "$(head -n 1 "${tsv}")" = "$(printf 'ts\tphase\tdecision\twhy\tevidence\tresult')" ] &&
	awk -F'\t' 'NF != 6 { exit 1 }' "${tsv}"; then
	ok "creates parent dir, writes single header, and appends valid 6-column rows"
else
	no "creates parent dir, writes single header, and appends valid 6-column rows"
fi

# 3. Strips embedded tabs/newlines and neutralizes formula injection prefixes (=, +, -, @).
tsv2="${work}/sanitize.tsv"
if bash "${LOG_SH}" "${tsv2}" "=CMD()" "+1+1" "-flag" "@SUM(A1)" "$(printf 'line1\tcol\nline2')" &&
	[ "$(wc -l <"${tsv2}" | tr -d ' ')" -eq 2 ] &&
	row="$(tail -n 1 "${tsv2}")" &&
	awk -F'\t' '
		NF != 6 { exit 1 }
		$2 != "'\''=CMD()" { exit 1 }
		$3 != "'\''+1+1" { exit 1 }
		$4 != "'\''-flag" { exit 1 }
		$5 != "'\''@SUM(A1)" { exit 1 }
		$6 != "line1 col line2" { exit 1 }
	' <<<"${row}"; then
	ok "sanitizes tabs/newlines and neutralizes spreadsheet formula prefixes"
else
	no "sanitizes tabs/newlines and neutralizes spreadsheet formula prefixes"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL show-me-your-work-log: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS show-me-your-work-log: %d checks green\n' "${passed}"

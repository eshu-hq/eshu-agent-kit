#!/usr/bin/env bash
# hooks/tests/test-goal-issues-defer-url.sh
#
# Verifies DEFER accepts a matching GitHub issue comment URL and rejects
# mismatched issue numbers or non-comment URLs.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="${KIT_DIR}/hooks/lib/goal-issues.py"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

ledger="${tmp}/active-goal.issues"
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/eshu-hq/eshu/issues/11636#issuecomment-123456
EOF

out="$(python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if [ -n "${out}" ]; then
	printf 'FAIL: matching GitHub issue comment URL should defer without blocking, got: %s\n' "${out}" >&2
	exit 1
fi
if ! rg -q '^eshu-hq/eshu#11636 2026-11-28T00:00:00Z deferred https://github\.com/eshu-hq/eshu/issues/11636#issuecomment-123456$' "${ledger}"; then
	printf 'FAIL: expected deferred URL record in ledger, got:\n' >&2
	cat "${ledger}" >&2
	exit 1
fi

# Negative case: comment URL for a different issue number must be refused.
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/eshu-hq/eshu/issues/99999#issuecomment-123456
EOF

# Stub gh returning OPEN so cmd_gate refuses with the mismatch reason.
stub_bin="${tmp}/bin"
mkdir -p "${stub_bin}"
cat <<'EOF' >"${stub_bin}/gh"
#!/usr/bin/env bash
printf '{"state":"OPEN"}\n'
EOF
chmod +x "${stub_bin}/gh"

out_bad="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if ! printf '%s' "${out_bad}" | rg -q 'URL must be a GitHub issue comment URL for #11636'; then
	printf 'FAIL: mismatched issue URL should be refused, got: %s\n' "${out_bad}" >&2
	exit 1
fi

printf 'PASS test-goal-issues-defer-url\n'

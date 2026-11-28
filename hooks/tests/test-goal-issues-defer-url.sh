#!/usr/bin/env bash
# hooks/tests/test-goal-issues-defer-url.sh
#
# Verifies DEFER accepts a verified GitHub issue comment URL for the same repo
# and issue, preserves local-file backward compatibility, and rejects cross-repo,
# fabricated, mismatched-issue, or non-comment URLs.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="${KIT_DIR}/hooks/lib/goal-issues.py"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

stub_bin="${tmp}/bin"
mkdir -p "${stub_bin}"
cat <<'EOF' >"${stub_bin}/gh"
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
	case "$2" in
	repos/eshu-hq/eshu/issues/comments/123456)
		printf '{"issue_url":"https://api.github.com/repos/eshu-hq/eshu/issues/11636","body":"Arbiter ruling: defer #11636."}\n'
		exit 0
		;;
	*)
		exit 1
		;;
	esac
fi
printf '{"state":"OPEN"}\n'
EOF
chmod +x "${stub_bin}/gh"

ledger="${tmp}/active-goal.issues"

# 1. Verified comment URL for matching repo + issue defers cleanly.
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/eshu-hq/eshu/issues/11636#issuecomment-123456
EOF
out="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if [ -n "${out}" ]; then
	printf 'FAIL [verified URL]: expected allow, got: %s\n' "${out}" >&2
	exit 1
fi
if ! rg -q '^eshu-hq/eshu#11636 2026-11-28T00:00:00Z deferred https://github\.com/eshu-hq/eshu/issues/11636#issuecomment-123456$' "${ledger}"; then
	printf 'FAIL [verified URL]: ledger missing deferred record\n' >&2
	exit 1
fi

# 2. Fabricated comment ID (gh api returns non-zero) is refused.
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/eshu-hq/eshu/issues/11636#issuecomment-999999
EOF
out="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if ! printf '%s' "${out}" | rg -q 'could not verify issue comment 999999'; then
	printf 'FAIL [fabricated comment]: got: %s\n' "${out}" >&2
	exit 1
fi

# 3. Cross-repo URL is refused.
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/evil/fork/issues/11636#issuecomment-123456
EOF
out="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if ! printf '%s' "${out}" | rg -q 'URL repo evil/fork does not match eshu-hq/eshu'; then
	printf 'FAIL [cross-repo URL]: got: %s\n' "${out}" >&2
	exit 1
fi

# 4. Mismatched issue number URL is refused.
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/eshu-hq/eshu/issues/99999#issuecomment-123456
EOF
out="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if ! printf '%s' "${out}" | rg -q 'URL must be a GitHub issue comment URL for #11636'; then
	printf 'FAIL [mismatched issue]: got: %s\n' "${out}" >&2
	exit 1
fi

# 5. Plain issue URL without #issuecomment fragment is refused.
cat <<'EOF' >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 https://github.com/eshu-hq/eshu/issues/11636
EOF
out="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if ! printf '%s' "${out}" | rg -q 'URL must be a GitHub issue comment URL for #11636'; then
	printf 'FAIL [plain issue URL]: got: %s\n' "${out}" >&2
	exit 1
fi

# 6. Backward compatibility: existing local ruling file naming #11636 still defers.
ruling="${tmp}/ruling.md"
printf 'Arbiter ruling: defer #11636 until prerequisite merges.\n' >"${ruling}"
cat <<EOF >"${ledger}"
eshu-hq/eshu#11636 2026-11-28T00:00:00Z open
DEFER: #11636 ${ruling}
EOF
out="$(PATH="${stub_bin}:${PATH}" python3 "${PY}" gate "${ledger}" --cwd "${tmp}" 2>/dev/null)"
if [ -n "${out}" ]; then
	printf 'FAIL [local file compat]: expected allow, got: %s\n' "${out}" >&2
	exit 1
fi

printf 'PASS test-goal-issues-defer-url\n'

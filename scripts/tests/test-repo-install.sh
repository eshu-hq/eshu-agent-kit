#!/usr/bin/env bash
# Behavioural mirror for install.sh repo modes.
#
# The global installer path is covered by test-global-install.sh. This suite
# covers the repo path the epic gates on: a product repo stays thin (a version
# pin plus symlinks), so --repo, --agents/--hooks/--rules --repo must link the
# kit material and stamp the kit VERSION. A hardcoded version stamp would let
# the pin drift from VERSION silently; the suite pins them together.
set -euo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

# 1. --repo links every skill and stamps VERSION.
repo="${work}/repo"
"${kit}/install.sh" --repo "${repo}" >/dev/null 2>&1
for skill in "${kit}"/skills/eshu/*/; do
	name="$(basename "${skill}")"
	if [ "$(readlink "${repo}/.agents/skills/${name}")" = "${skill}" ]; then
		ok "--repo links ${name}"
	else
		no "--repo links ${name}"
	fi
done
if [ "$(cat "${repo}/.agent-kit-version")" = "$(cat "${kit}/VERSION")" ]; then
	ok "--repo stamps kit VERSION"
else
	no "--repo stamps kit VERSION"
fi

# 2. --repo is idempotent and rejects a missing target.
"${kit}/install.sh" --repo "${repo}" >/dev/null 2>&1 &&
	ok "--repo rerun succeeds" || no "--repo rerun succeeds"
if "${kit}/install.sh" --repo >/dev/null 2>&1; then
	no "--repo without target fails"
else
	ok "--repo without target fails"
fi

# 3. Mode installers land in the repo layout the READMEs promise.
"${kit}/install.sh" --agents --repo "${repo}" >/dev/null 2>&1
[ -e "${repo}/.agents/agents" ] &&
	ok "--agents --repo creates agents dir" || no "--agents --repo creates agents dir"
"${kit}/install.sh" --hooks --repo "${repo}" >/dev/null 2>&1
[ -e "${repo}/.claude/hooks/guard-live-gate.sh" ] &&
	ok "--hooks --repo links hook scripts" || no "--hooks --repo links hook scripts"
[ -e "${repo}/scripts/check-docs-stale.sh" ] &&
	ok "--hooks --repo links the staleness checker" || no "--hooks --repo links the staleness checker"
"${kit}/install.sh" --rules --repo "${repo}" >/dev/null 2>&1
[ -e "${repo}/.claude/rules" ] &&
	ok "--rules --repo creates rules dir" || no "--rules --repo creates rules dir"
[ -e "${repo}/scripts/claude-rules-lint.sh" ] &&
	ok "--rules --repo links the rules lint" || no "--rules --repo links the rules lint"

printf '\nrepo-install mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

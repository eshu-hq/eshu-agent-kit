#!/usr/bin/env bash
# Behavioural mirror for install.sh repo modes.
#
# The global installer path is covered by test-global-install.sh. This suite
# covers the repo path the epic gates on: a product repo stays thin (a version
# pin plus symlinks; Muse project agents are copies, per its symlink refusal),
# so --repo, --agents/--hooks/--rules --repo must link the
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
# Muse refuses symlinked project definitions, so the Muse project agents
# must be regular files whose content matches the kit sources.
if [ -f "${repo}/.agents/agents/scan-eshu.md" ] &&
	[ ! -L "${repo}/.agents/agents/scan-eshu.md" ] &&
	cmp -s "${repo}/.agents/agents/scan-eshu.md" "${kit}/agents/scan-eshu.md"; then
	ok "--agents --repo copies Muse project agents as regular files"
else
	no "--agents --repo copies Muse project agents as regular files"
fi
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

# 3a. The two deliveries the epic adds, pinned by their link TARGET rather
# than by existence. The role manifest is the binding of record (the
# consumer's router reads it, and its drift check compares it against this
# repo), and scripts/agent-roles.py is the launcher the router tells the
# coordinator to run. Existence alone would pass with either pointed at the
# wrong file, so each is compared to the kit path it must resolve to.
if [ "$(readlink "${repo}/.agents/roles.json")" = "${kit}/agents/roles.json" ]; then
	ok "--agents --repo links the role manifest to the kit copy"
else
	no "--agents --repo links the role manifest to the kit copy"
fi
if [ "$(readlink "${repo}/scripts/agent-roles.py")" = "${kit}/agents/agent-roles.py" ]; then
	ok "--agents --repo links the role launcher to the kit copy"
else
	no "--agents --repo links the role launcher to the kit copy"
fi

# 3b. A partial install still stamps the version pin. The launcher finds its
# workspace by walking up to the nearest ancestor carrying
# .agent-kit-version, so a --agents-only consumer without the pin would run
# every role inside this kit instead of in the consumer -- the exact bug the
# launcher fix addressed. Each mode gets its own fresh directory: a directory
# already installed by --repo carries the pin from that step, which would
# make the assertion pass without the mode doing anything.
for mode in --agents --hooks --rules; do
	pinned="${work}/pin-${mode}"
	"${kit}/install.sh" "${mode}" --repo "${pinned}" >/dev/null 2>&1
	if [ "$(cat "${pinned}/.agent-kit-version" 2>/dev/null)" = "$(cat "${kit}/VERSION")" ]; then
		ok "${mode} --repo stamps the kit version pin"
	else
		no "${mode} --repo stamps the kit version pin"
	fi
done

# 3c. The preserve branch, asserted by CONTENT rather than by existence.
# A consumer may track its own staleness checker, and that copy can be newer
# than this kit's. Existence is a weak assertion here: [ -e ] holds for both
# the preserved regular file and the clobbering symlink, so an
# always-symlink mutant keeps the suite green. The marker content plus the
# not-a-symlink test tell the two states apart.
kept="${work}/preserve"
mkdir -p "${kept}/scripts"
printf '# CONSUMER-MARKER\n' >"${kept}/scripts/check-docs-stale.sh"
"${kit}/install.sh" --hooks --repo "${kept}" >/dev/null 2>&1
if [ ! -L "${kept}/scripts/check-docs-stale.sh" ] &&
	[ "$(cat "${kept}/scripts/check-docs-stale.sh")" = "# CONSUMER-MARKER" ]; then
	ok "--hooks --repo preserves a tracked staleness checker"
else
	no "--hooks --repo preserves a tracked staleness checker"
fi
# The same path, absent, is still linked: preserving must not skip the
# install for a consumer that has no copy of its own.
linked="${work}/link"
"${kit}/install.sh" --hooks --repo "${linked}" >/dev/null 2>&1
if [ -L "${linked}/scripts/check-docs-stale.sh" ] &&
	[ "$(readlink "${linked}/scripts/check-docs-stale.sh")" = "${kit}/scripts/check-docs-stale.sh" ]; then
	ok "--hooks --repo links the checker when the consumer has none"
else
	no "--hooks --repo links the checker when the consumer has none"
fi

# 4. --rules --repo installs only frontmatter-scoped rules. rules/README.md is
# the index, not a rule: it has no `paths:`, so installing it would load index
# prose at launch and trip claude-rules-lint in every consumer.
if [ -e "${repo}/.claude/rules/README.md" ]; then
	no "--rules --repo excludes the rules index README"
else
	ok "--rules --repo excludes the rules index README"
fi
unscoped=""
for rule in "${repo}"/.claude/rules/*.md; do
	[ -f "${rule}" ] || continue
	if [ "$(head -n 1 "${rule}")" != "---" ] || ! rg -q '^paths:' "${rule}"; then
		unscoped="${unscoped} $(basename "${rule}")"
	fi
done
if [ -z "${unscoped}" ]; then
	ok "--rules --repo installs only frontmatter-scoped rules"
else
	no "--rules --repo installs only frontmatter-scoped rules (unscoped:${unscoped})"
fi

printf '\nrepo-install mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

#!/usr/bin/env bash
# Hermetic tests for skills/core/ portability, PAPERCUT_REPO decoupling,
# and skill-lint --json tier/owner metadata (issue #134).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# 1. core skills live in skills/core/, debrief is extracted, and layer-lint.sh passes with zero T1 hits.
core_skills=(architect correct explain interrogate ketchup papercut show-me-your-work)
core_present=1
for s in "${core_skills[@]}"; do
	if [ ! -f "${KIT_DIR}/skills/core/${s}/SKILL.md" ] || [ -e "${KIT_DIR}/skills/eshu/${s}" ]; then
		core_present=0
	fi
done
if [ "${core_present}" -eq 1 ] &&
	[ ! -e "${KIT_DIR}/skills/core/debrief" ] &&
	[ ! -e "${KIT_DIR}/skills/eshu/debrief" ] &&
	bash "${KIT_DIR}/scripts/layer-lint.sh" >/dev/null; then
	ok "core skills live in skills/core/, debrief is extracted, and layer-lint.sh passes"
else
	no "core skills live in skills/core/, debrief is extracted, and layer-lint.sh passes"
fi

# 2. install.sh --skills --repo links core skills cleanly and preserves external debrief symlinks.
repo="${work}/non-eshu-repo"
ext_debrief="${work}/external-debrief"
mkdir -p "${repo}/.agents/skills" "${ext_debrief}"
printf -- '---\nname: debrief\ndescription: standalone\n---\n' >"${ext_debrief}/SKILL.md"
ln -sfn "${ext_debrief}" "${repo}/.agents/skills/debrief"
git -C "${repo}" init -q -b main
links_ok=1
if bash "${KIT_DIR}/install.sh" --skills --repo "${repo}" </dev/null >/dev/null 2>&1; then
	for s in "${core_skills[@]}"; do
		if [ ! -L "${repo}/.agents/skills/${s}" ] ||
			[ "$(readlink "${repo}/.agents/skills/${s}" | sed 's|/$||')" != "${KIT_DIR}/skills/core/${s}" ]; then
			links_ok=0
		fi
	done
else
	links_ok=0
fi
if [ "${links_ok}" -eq 1 ] &&
	[ -L "${repo}/.agents/skills/debrief" ] &&
	ext_target="$(readlink "${repo}/.agents/skills/debrief")" &&
	[ "${ext_target%/}" = "${ext_debrief}" ]; then
	ok "install.sh --skills --repo links all core skills and preserves external debrief symlink"
else
	no "install.sh --skills --repo links all core skills and preserves external debrief symlink"
fi

# 3. file-papercut.sh honors PAPERCUT_REPO override outside any git remote.
if out="$(cd "${work}" && PAPERCUT_REPO="acme/agent-skills" bash "${KIT_DIR}/scripts/file-papercut.sh" file \
	--skill debrief --title "standalone test" --tried "ran debrief" \
	--expected "works" --happened "failed" --fix "patch it" --dry-run --no-dedupe)" &&
	grep -q '^repo: acme/agent-skills$' <<<"${out}"; then
	ok "file-papercut.sh honors PAPERCUT_REPO env var cleanly"
else
	no "file-papercut.sh honors PAPERCUT_REPO env var cleanly"
fi

# 4. skill-lint.sh --json exposes optional tier and owner frontmatter fields cleanly.
mkdir -p "${work}/demo-skill"
cat >"${work}/demo-skill/SKILL.md" <<'EOF'
---
name: demo-skill
tier: core
owner: platform-team
description: "Demo skill with tier and owner metadata."
---

# Demo

1. Run check:

```bash
echo ok
```

## Recovery

When the check fails, inspect stderr and retry with verbose output.
EOF
if bash "${KIT_DIR}/scripts/skill-lint.sh" --json "${work}/demo-skill/SKILL.md" >"${work}/lint.json" &&
	python3 - "${work}/lint.json" <<'PYEOF'; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["errors"] == 0 and len(d["skills"]) == 1, d
s = d["skills"][0]
assert s["tier"] == "core" and s["owner"] == "platform-team", s
PYEOF
	ok "skill-lint.sh --json extracts optional tier and owner frontmatter fields"
else
	no "skill-lint.sh --json extracts optional tier and owner frontmatter fields"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL core-portable: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS core-portable: %d checks green\n' "${passed}"

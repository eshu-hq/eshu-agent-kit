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

# 1. debrief and papercut live in skills/core/ and pass layer-lint.sh with zero T1 hits.
if [ -f "${KIT_DIR}/skills/core/debrief/SKILL.md" ] &&
	[ -f "${KIT_DIR}/skills/core/papercut/SKILL.md" ] &&
	[ ! -e "${KIT_DIR}/skills/eshu/debrief" ] &&
	[ ! -e "${KIT_DIR}/skills/eshu/papercut" ] &&
	bash "${KIT_DIR}/scripts/layer-lint.sh" >/dev/null; then
	ok "debrief and papercut live in skills/core/ and pass layer-lint.sh"
else
	no "debrief and papercut live in skills/core/ and pass layer-lint.sh"
fi

# 2. install.sh --skills --repo links core skills cleanly into a non-Eshu consumer repo.
repo="${work}/non-eshu-repo"
mkdir -p "${repo}"
git -C "${repo}" init -q -b main
if bash "${KIT_DIR}/install.sh" --skills --repo "${repo}" </dev/null >/dev/null 2>&1 &&
	[ -L "${repo}/.agents/skills/debrief" ] &&
	[ -L "${repo}/.agents/skills/papercut" ] &&
	target="$(readlink "${repo}/.agents/skills/debrief")" &&
	[ "${target%/}" = "${KIT_DIR}/skills/core/debrief" ]; then
	ok "install.sh --skills --repo links core skills into a non-Eshu consumer repo"
else
	no "install.sh --skills --repo links core skills into a non-Eshu consumer repo"
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

#!/usr/bin/env bash
# Layer lint for eshu-agent-kit: enforces the T1 layer rule from
# skills/registry.md plus link resolution and skill-name uniqueness.
# Usage: bash scripts/layer-lint.sh
# Exit 0 when every gate passes, 1 with reasons otherwise. Zero tolerance:
# any dangling link fails directly; there is no baseline file (#24).
set -euo pipefail
export LC_ALL=C

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

say_fail() {
	echo "FAIL layer-lint: $1"
	fails=1
}

# T1: denylist over skills/core/ (markdown only; .gitkeep ignored).
# HOME_LITERAL holds the literal text the denylist looks for in markdown: it is
# an rg *pattern*, never expanded as a path, so the quotes are the intent.
# shellcheck disable=SC2088 # HOME_LITERAL is pattern text, never a path
HOME_LITERAL='~/.eshu'
if [ -d "${KIT_DIR}/skills/core" ]; then
	while IFS= read -r hit; do
		say_fail "T1 coupling in core: ${hit}"
	done < <(rg -n --no-heading -e 'make pre-(push|pr)' -e 'ci-gates|review-attest' \
		-e 'scripts/(dev|lib)/' -e 'specs/ci-gates' -e 'docs/(public|internal)/' \
		-e 'eshu-hq' -e "${HOME_LITERAL}" -e '[a-z]+-eshu' \
		-e 'Cypher|Neo4j|NornicDB|reducer|collector|graph truth' \
		-g '*.md' "${KIT_DIR}/skills/core" 2>/dev/null || true)
fi

# Basename uniqueness: install.sh links by basename into one dir.
# shellcheck disable=SC2012 # inputs are repo-controlled skill basenames (newline-free); ls output feeds only sort/uniq
dups=$(ls "${KIT_DIR}/skills/core" "${KIT_DIR}/skills/eshu" 2>/dev/null | sort | uniq -d || true)
if [ -n "${dups}" ]; then
	say_fail "duplicate skill dir names across layers:${dups}"
fi

# No core -> eshu/docs links (dependency direction: adapter may reference core).
if [ -d "${KIT_DIR}/skills/core" ]; then
	while IFS= read -r hit; do
		say_fail "core links out of layer: ${hit}"
	done < <(rg -n --no-heading '\]\([^)]*(skills/eshu|docs/eshu)[^)]*\)' \
		-g '*.md' "${KIT_DIR}/skills/core" 2>/dev/null || true)
fi

# Link resolution: every relative .md link under skills/ and docs/ must
# resolve. Zero tolerance: any dangling link fails directly (#24).
actual="$(mktemp)"
trap 'rm -f "${actual}"' EXIT
python3 - "${KIT_DIR}" >"${actual}" <<'EOF'
import re, pathlib, sys
root = pathlib.Path(sys.argv[1])
for base in ('skills', 'docs'):
    for md in sorted((root / base).rglob('*.md')):
        if 'scripts/testdata' in str(md):
            continue
        for m in re.finditer(r'\]\(([^)]+?\.md)(?:#[^)]*)?\)', md.read_text()):
            t = m.group(1)
            if t.startswith(('http://', 'https://')):
                continue
            if not (md.parent / t).exists():
                print(f'{md.relative_to(root)}:{t}')
EOF
sort -o "${actual}" "${actual}"
if [ -s "${actual}" ]; then
	say_fail "dangling links (no baseline; fix the link):"
	cat "${actual}"
fi

if [ "${fails}" -eq 0 ]; then
	echo "OK layer-lint passed"
fi
exit "${fails}"

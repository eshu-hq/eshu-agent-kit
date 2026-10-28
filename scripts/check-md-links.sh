#!/usr/bin/env bash
# scripts/check-md-links.sh
#
# Fail when a relative Markdown link in this repo points at nothing.
# Covers every tracked *.md file. External http(s) links are lychee's job
# in CI; this script owns relative-path resolution only.
#
# Usage: bash scripts/check-md-links.sh
# Exit 0 when every relative .md link resolves, 1 with reasons otherwise.
#
# Testdata fixtures are excluded: they carry intentionally invalid content
# (same precedent as layer-lint.sh). Fragments (#...) are ignored.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails="$(
	python3 - "${KIT_DIR}" <<'EOF'
import re, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
tracked = set(subprocess.run(
    ['git', '-C', str(root), 'ls-files', '*.md'],
    capture_output=True, text=True, check=True).stdout.splitlines())
out = []
for rel in sorted(tracked):
    md = root / rel
    if '/testdata/' in rel:
        continue
    try:
        text = md.read_text()
    except OSError:
        continue
    for m in re.finditer(r'\]\(([^)]+?\.md)(?:#[^)]*)?\)', text):
        t = m.group(1)
        if t.startswith(('http://', 'https://')):
            continue
        if not (md.parent / t).exists():
            out.append(f'{rel}:{t}')
print('\n'.join(out))
EOF
)"

if [ -n "${fails}" ]; then
	printf 'FAIL md-links: dangling relative links:\n%s\n' "${fails}" >&2
	exit 1
fi
printf 'md-links: every relative .md link resolves\n'

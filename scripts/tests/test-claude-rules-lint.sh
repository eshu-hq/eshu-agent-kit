#!/usr/bin/env bash
# Behavioural mirror for scripts/claude-rules-lint.sh.
#
# The script guards against silent rule death: a rule with no `paths:` loads
# unconditionally, and a glob matching nothing never loads. Both must fail
# loudly. The suite builds synthetic git repos (hermetic, no sibling checkout)
# and asserts the RED/GREEN pair for each failure mode plus the clean pass.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_SRC="${repo_root}/scripts/claude-rules-lint.sh"

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

# make_repo NAME -> path; installs the lint script the way install.sh does.
make_repo() {
	local r="${work}/$1"
	mkdir -p "${r}/.claude/rules" "${r}/scripts" "${r}/go/pkg"
	ln -sfn "${LINT_SRC}" "${r}/scripts/claude-rules-lint.sh"
	printf 'package pkg\n' >"${r}/go/pkg/foo.go"
	git -C "${r}" init -q 2>/dev/null
	git -C "${r}" add -A 2>/dev/null
	printf '%s' "${r}"
}

# 1. Clean repo: one scoped rule matching a tracked file.
r=$(make_repo clean)
cat >"${r}/.claude/rules/pkg.md" <<'EOF'
---
paths:
  - "go/pkg/*.go"
---

# Pkg
EOF
out=$(bash "${r}/scripts/claude-rules-lint.sh" 2>&1)
code=$?
[ "${code}" = "0" ] && ok "scoped rule with a live glob passes" || no "scoped rule with a live glob passes (got ${code}: ${out:0:100})"

# 2. Rule with frontmatter but no paths: fails.
r=$(make_repo nopaths)
printf -- '---\nname: bad\n---\n\n# Unscoped rule, loads at launch\n' >"${r}/.claude/rules/bad.md"
out=$(bash "${r}/scripts/claude-rules-lint.sh" 2>&1)
code=$?
[ "${code}" != "0" ] && ok "rule without paths fails" || no "rule without paths fails (exit 0)"
case "${out}" in
*"no \`paths:\`"*) ok "failure names the missing paths field" ;;
*) no "failure names the missing paths field (got: ${out:0:120})" ;;
esac

# 3. Dead glob: fails.
r=$(make_repo deadglob)
cat >"${r}/.claude/rules/dead.md" <<'EOF'
---
paths:
  - "go/does-not-exist/**/*.go"
---

# Dead
EOF
out=$(bash "${r}/scripts/claude-rules-lint.sh" 2>&1)
code=$?
[ "${code}" != "0" ] && ok "rule with a dead glob fails" || no "rule with a dead glob fails (exit 0)"
case "${out}" in
*"matches no tracked file"*) ok "failure names the dead glob" ;;
*) no "failure names the dead glob (got: ${out:0:120})" ;;
esac

# 4. Missing frontmatter on line 1: fails.
r=$(make_repo nofm)
printf '# Rule\n\npaths:\n  - "go/pkg/*.go"\n' >"${r}/.claude/rules/nofm.md"
out=$(bash "${r}/scripts/claude-rules-lint.sh" 2>&1)
code=$?
[ "${code}" != "0" ] && ok "rule without line-1 frontmatter fails" || no "rule without line-1 frontmatter fails (exit 0)"

printf '\nclaude-rules-lint mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

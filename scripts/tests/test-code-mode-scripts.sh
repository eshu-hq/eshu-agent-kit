#!/usr/bin/env bash
# Hermetic tests for code-mode skill scripts:
#   - skills/eshu/executor-preflight/scripts/preflight.sh
#   - skills/eshu/session-lifecycle/scripts/branch-head.sh
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="${repo_root}/skills/eshu/executor-preflight/scripts/preflight.sh"
BRANCH_HEAD="${repo_root}/skills/eshu/session-lifecycle/scripts/branch-head.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Isolate from the operator's git config and prove neither script shells out
# to gh: the fake gh is a tripwire that logs every call and exits 97.
mkdir -p "${work}/home" "${work}/bin"
export HOME="${work}/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
gh_log="${work}/gh-calls.log"
: >"${gh_log}"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 97\n' "${gh_log}" >"${work}/bin/gh"
chmod +x "${work}/bin/gh"
export PATH="${work}/bin:${PATH}"

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
assert_eq() {
	if [[ "$1" == "$2" ]]; then
		ok "$3"
	else
		no "$3 (expected '$2', got '$1')"
	fi
}
assert_contains() {
	case "$1" in
	*"$2"*) ok "$3" ;;
	*) no "$3 (missing '$2' in: ${1:0:220})" ;;
	esac
}

make_git_repo() {
	local dir="${work}/$1"
	mkdir -p "${dir}"
	git -C "${dir}" init -q -b main
	git -C "${dir}" config user.email "test@example.com"
	git -C "${dir}" config user.name "Test User"
	printf 'initial\n' >"${dir}/README.md"
	git -C "${dir}" add README.md
	git -C "${dir}" commit -q -m "initial commit"
	printf '%s' "${dir}"
}

make_valid_pr_body() {
	cat >"$1" <<'EOF'
Refs #119.

**Adds deterministic helper scripts for preflight and branch head checks.**

| At a glance | |
|---|---|
| Scope | Two skill scripts and tests |

NOT_CHECKED: live cluster run (no cluster needed).
EOF
}

make_valid_issue_body() {
	cat >"$1" <<'EOF'
**Tracks deterministic code-mode scripts for two skills.**

## Problem

Manual shell chains drift across handoffs.

## Acceptance criteria

- Both scripts exit 0 on clean fixtures.
EOF
}

# --- 1. preflight.sh: clean repo without --body or verify scripts ---
r1="$(make_git_repo clean-minimal)"
r1_head="$(git -C "${r1}" rev-parse HEAD)"
out="$(bash "${PREFLIGHT}" --repo "${r1}" 2>&1)"
rc=$?
assert_eq "${rc}" "0" "preflight clean minimal repo exits 0"
assert_contains "${out}" "HEAD=${r1_head}" "preflight prints HEAD"
case "${out}" in
*BODY_SHA256=*) no "preflight omits BODY_SHA256 when no --body" ;;
*) ok "preflight omits BODY_SHA256 when no --body" ;;
esac
assert_contains "${out}" "shape | NOT_CHECKED |" "preflight marks shape NOT_CHECKED without --body"
assert_contains "${out}" "license-header | NOT_CHECKED |" "preflight marks missing license-header NOT_CHECKED"
assert_contains "${out}" "live-tests-ledger | NOT_CHECKED |" "preflight marks missing live-tests-ledger NOT_CHECKED"
assert_contains "${out}" "env-registry-doc | NOT_CHECKED |" "preflight marks missing env-registry-doc NOT_CHECKED"
assert_contains "${out}" "docs-cli-env-refs | NOT_CHECKED |" "preflight marks missing docs-cli-env-refs NOT_CHECKED"
assert_contains "${out}" "test-todo-scan | PASS |" "preflight clean test-todo-scan passes"

# --- 2. preflight.sh: passing body + all 4 verify scripts ---
r2="$(make_git_repo all-green)"
mkdir -p "${r2}/scripts"
for s in verify-license-header.sh verify-live-tests-ledger.sh verify-env-registry-doc.sh verify-docs-cli-env-refs.sh; do
	printf '#!/usr/bin/env bash\necho "ok %s"\n' "${s}" >"${r2}/scripts/${s}"
	chmod +x "${r2}/scripts/${s}"
done
git -C "${r2}" add scripts/
git -C "${r2}" commit -q -m "add passing verify scripts"
pr_ok="${work}/pr-ok.md"
make_valid_pr_body "${pr_ok}"
out="$(bash "${PREFLIGHT}" --repo "${r2}" --body "${pr_ok}" 2>&1)"
rc=$?
assert_eq "${rc}" "0" "preflight with valid PR body and green scripts exits 0"
assert_contains "${out}" "BODY_SHA256=" "preflight prints BODY_SHA256 when --body given"
assert_contains "${out}" "shape | PASS |" "preflight shape passes on valid PR body"
assert_contains "${out}" "license-header | PASS |" "preflight license-header passes"
assert_contains "${out}" "live-tests-ledger | PASS |" "preflight live-tests-ledger passes"
assert_contains "${out}" "env-registry-doc | PASS |" "preflight env-registry-doc passes"
assert_contains "${out}" "docs-cli-env-refs | PASS |" "preflight docs-cli-env-refs passes"

# --- 3. preflight.sh: --issue body passes ---
issue_ok="${work}/issue-ok.md"
make_valid_issue_body "${issue_ok}"
out="$(bash "${PREFLIGHT}" --repo "${r2}" --body "${issue_ok}" --issue 2>&1)"
rc=$?
assert_eq "${rc}" "0" "preflight with valid --issue body exits 0"
assert_contains "${out}" "shape | PASS |" "preflight shape passes in --issue mode"

# --- 4. preflight.sh: failing shape check ---
pr_bad="${work}/pr-bad.md"
printf 'No refs line and no bold lead.\n' >"${pr_bad}"
out="$(bash "${PREFLIGHT}" --repo "${r2}" --body "${pr_bad}" 2>&1)"
rc=$?
assert_eq "${rc}" "1" "preflight fails with exit 1 on bad PR shape"
assert_contains "${out}" "shape | FAIL |" "preflight reports shape FAIL"

# --- 5. preflight.sh: failing license-header check ---
printf '#!/usr/bin/env bash\necho "missing SPDX header in foo.go" >&2\nexit 1\n' >"${r2}/scripts/verify-license-header.sh"
out="$(bash "${PREFLIGHT}" --repo "${r2}" --body "${pr_ok}" 2>&1)"
rc=$?
assert_eq "${rc}" "1" "preflight fails with exit 1 when license-header fails"
assert_contains "${out}" "license-header | FAIL |" "preflight reports license-header FAIL"
git -C "${r2}" checkout -q -- scripts/verify-license-header.sh

# --- 6. preflight.sh: test-todo-scan ignores placeholder lines that carry SQL ---
r3="$(make_git_repo todo-scan)"
todo_tok="TO""DO"
ph_tok="place""holder"
git -C "${r3}" checkout -q -b feat
cat >"${r3}/query_test.go" <<EOF
package demo

func TestSQL() {
	// SQL \$1 ${ph_tok} for parameterized lookup
	_ = "SELECT id FROM items WHERE id = \$1" // \$1 ${ph_tok}
}
EOF
git -C "${r3}" add query_test.go
git -C "${r3}" commit -q -m "add benign test file"
out="$(bash "${PREFLIGHT}" --repo "${r3}" --base main 2>&1)"
rc=$?
assert_eq "${rc}" "0" "preflight ignores SQL \$1 placeholder lines"
assert_contains "${out}" "test-todo-scan | PASS |" "preflight test-todo-scan PASS on benign test file"

# --- 7. preflight.sh: committed marker in an added *_test.go is a FAIL ---
printf 'package demo\n// %s: implement real check\n' "${todo_tok}" >"${r3}/stub_test.go"
git -C "${r3}" add stub_test.go
git -C "${r3}" commit -q -m "add stub test"
out="$(bash "${PREFLIGHT}" --repo "${r3}" --base main 2>&1)"
rc=$?
assert_eq "${rc}" "1" "preflight fails on real marker in *_test.go"
assert_contains "${out}" "test-todo-scan | FAIL |" "preflight reports test-todo-scan FAIL"
assert_contains "${out}" "stub_test.go:2" "preflight names matching test file and line"
git -C "${r3}" reset -q --hard HEAD~1

# --- 8. preflight.sh: stub marker in an added test-*.sh; marker plus SQL still hits ---
printf '#!/usr/bin/env bash\n# %s assertion until wired\n' "${ph_tok}" >"${r3}/test-stub.sh"
printf 'package demo\n// %s sql $1 lookup\n' "${todo_tok}" >"${r3}/sql_test.go"
git -C "${r3}" add test-stub.sh sql_test.go
git -C "${r3}" commit -q -m "add stub scripts"
out="$(bash "${PREFLIGHT}" --repo "${r3}" --base main 2>&1)"
rc=$?
assert_eq "${rc}" "1" "preflight fails on stub marker in test-*.sh"
assert_contains "${out}" "test-stub.sh:2" "preflight names matching test-*.sh file and line"
assert_contains "${out}" "sql_test.go:2" "preflight keeps a marker hit even when the line carries SQL"
git -C "${r3}" reset -q --hard HEAD~1

# --- 9. branch-head.sh: clean repo with --re and --base ---
r4="$(make_git_repo branch-head)"
r4_main="$(git -C "${r4}" rev-parse HEAD)"
r4_phys="$(cd "${r4}" && pwd -P)"
out="$(bash "${BRANCH_HEAD}" --repo "${r4}" --base main --re req-42 2>&1)"
rc=$?
assert_eq "${rc}" "0" "branch-head exits 0 on clean repo"
first_line="$(printf '%s\n' "${out}" | head -n 1)"
assert_eq "${first_line}" "HEAD=${r4_main} BASE=${r4_main} RE:req-42" "branch-head canonical first line with RE"
assert_contains "${out}" "BRANCH=main" "branch-head prints BRANCH"
assert_contains "${out}" "WORKTREE=${r4_phys}" "branch-head prints verified WORKTREE"
assert_contains "${out}" "STATUS=clean" "branch-head prints STATUS=clean"

# --- 10. branch-head.sh: without --re and dirty status ---
printf 'untracked\n' >"${r4}/dirty.txt"
out="$(bash "${BRANCH_HEAD}" --repo "${r4}" --base main 2>&1)"
rc=$?
assert_eq "${rc}" "0" "branch-head exits 0 on dirty repo"
first_line="$(printf '%s\n' "${out}" | head -n 1)"
assert_eq "${first_line}" "HEAD=${r4_main} BASE=${r4_main}" "branch-head first line omits RE when not passed"
assert_contains "${out}" "STATUS=dirty (1)" "branch-head prints dirty file count"
rm -f "${r4}/dirty.txt"

# --- 11. branch-head.sh: --expect-head match vs STALE exit 1 ---
prefix="${r4_main:0:10}"
out="$(bash "${BRANCH_HEAD}" --repo "${r4}" --expect-head "${prefix}" 2>&1)"
rc=$?
assert_eq "${rc}" "0" "branch-head exits 0 when --expect-head prefix matches"

stderr_file="${work}/stale.err"
stdout_file="${work}/stale.out"
bash "${BRANCH_HEAD}" --repo "${r4}" --expect-head deadbeef00 >"${stdout_file}" 2>"${stderr_file}"
rc=$?
assert_eq "${rc}" "1" "branch-head exits 1 on STALE --expect-head mismatch"
assert_contains "$(cat "${stderr_file}")" "STALE: expected deadbeef00 got ${r4_main}" "branch-head prints STALE to stderr"

# --- 12. branch-head.sh: verified linked git worktree path ---
wt_dir="${work}/branch-head-wt"
git -C "${r4}" worktree add -q -b feat-wt "${wt_dir}" main
printf 'feature change\n' >"${wt_dir}/feat.txt"
git -C "${wt_dir}" add feat.txt
git -C "${wt_dir}" commit -q -m "feature commit"
wt_head="$(git -C "${wt_dir}" rev-parse HEAD)"
wt_phys="$(cd "${wt_dir}" && pwd -P)"
out="$(bash "${BRANCH_HEAD}" --repo "${wt_dir}" --base main --re wt-1 2>&1)"
rc=$?
assert_eq "${rc}" "0" "branch-head exits 0 in linked git worktree"
first_line="$(printf '%s\n' "${out}" | head -n 1)"
assert_eq "${first_line}" "HEAD=${wt_head} BASE=${r4_main} RE:wt-1" "branch-head computes merge-base against main in linked worktree"
assert_contains "${out}" "BRANCH=feat-wt" "branch-head prints linked worktree branch"
assert_contains "${out}" "WORKTREE=${wt_phys}" "branch-head prints verified linked worktree path"
assert_contains "${out}" "STATUS=clean" "branch-head prints clean status in linked worktree"

# --- A. a marker comment mentioning a filter is still a hit ---
r5="$(make_git_repo case-a)"
git -C "${r5}" checkout -q -b feat
printf 'package demo\n// %s implement the filter check\n' "${todo_tok}" >"${r5}/a_test.go"
git -C "${r5}" add a_test.go
git -C "${r5}" commit -q -m "add a_test"
out="$(bash "${PREFLIGHT}" --repo "${r5}" --base main 2>&1)"
rc=$?
assert_eq "${rc}" "1" "A: marker comment about a filter exits 1"
assert_contains "${out}" "a_test.go:2" "A: marker comment about a filter is named"

# --- B. base resolution: local main is used; no base at all is NOT_CHECKED ---
r6="$(make_git_repo case-b)"
git -C "${r6}" checkout -q -b feat
printf 'package demo\n// %s later\n' "${todo_tok}" >"${r6}/b_test.go"
git -C "${r6}" add b_test.go
git -C "${r6}" commit -q -m "add b_test"
printf 'x\n' >"${r6}/other.txt"
git -C "${r6}" add other.txt
git -C "${r6}" commit -q -m "unrelated change"
out="$(bash "${PREFLIGHT}" --repo "${r6}" 2>&1)"
rc=$?
assert_eq "${rc}" "1" "B: test file added two commits back is found via main"
assert_contains "${out}" "b_test.go:2" "B: names the file added two commits back"
r7="${work}/case-b-trunk"
mkdir -p "${r7}"
git -C "${r7}" init -q -b trunk
git -C "${r7}" config user.email "test@example.com"
git -C "${r7}" config user.name "Test User"
printf 'package demo\n// %s x\n' "${todo_tok}" >"${r7}/t_test.go"
git -C "${r7}" add t_test.go
git -C "${r7}" commit -q -m "first"
out="$(bash "${PREFLIGHT}" --repo "${r7}" 2>&1)"
rc=$?
assert_eq "${rc}" "0" "B: no resolvable base never FAILs the scan"
assert_contains "${out}" "test-todo-scan | NOT_CHECKED | pass --base" "B: no resolvable base is NOT_CHECKED with a hint"

# --- C. an explicit unresolvable --base is a usage error ---
out="$(bash "${PREFLIGHT}" --repo "${r5}" --base nope 2>&1)"
rc=$?
assert_eq "${rc}" "2" "C: preflight --base nope exits 2"

# --- D. bind row: dirty tracked tree FAILs, clean PASSes, HEAD moves FAIL ---
out="$(bash "${PREFLIGHT}" --repo "${r1}" 2>&1)"
assert_contains "${out}" "bind | PASS |" "D: clean tree binds"
printf 'changed\n' >>"${r1}/README.md"
printf 'u\n' >"${r1}/untracked.txt"
out="$(bash "${PREFLIGHT}" --repo "${r1}" 2>&1)"
rc=$?
assert_eq "${rc}" "1" "D: dirty tracked tree exits 1"
assert_contains "${out}" "bind | FAIL |" "D: dirty tracked tree FAILs bind"
assert_contains "${out}" "untracked 1" "D: bind detail carries the untracked count"
git -C "${r1}" checkout -q -- README.md
rm -f "${r1}/untracked.txt"
r8="$(make_git_repo case-d-move)"
mkdir -p "${r8}/scripts"
printf '#!/usr/bin/env bash\ngit commit -q --allow-empty -m moved\n' >"${r8}/scripts/verify-env-registry-doc.sh"
git -C "${r8}" add scripts
git -C "${r8}" commit -q -m "add moving verify script"
out="$(bash "${PREFLIGHT}" --repo "${r8}" 2>&1)"
rc=$?
assert_eq "${rc}" "1" "D: HEAD moving during the run exits 1"
assert_contains "${out}" "bind | FAIL |" "D: HEAD moving during the run FAILs bind"

# --- row order is fixed ---
out="$(bash "${PREFLIGHT}" --repo "${r2}" --body "${pr_ok}" 2>/dev/null)"
order="$(printf '%s\n' "${out}" | awk -F' [|] ' 'NF >= 3 {printf "%s,", $1}')"
assert_eq "${order}" "bind,shape,license-header,live-tests-ledger,env-registry-doc,docs-cli-env-refs,test-todo-scan," "preflight rows print in the fixed order"

# --- E. branch-head --base nope is a usage error, never BASE=none ---
out="$(bash "${BRANCH_HEAD}" --repo "${r4}" --base nope 2>&1)"
rc=$?
assert_eq "${rc}" "2" "E: branch-head --base nope exits 2"
case "${out}" in
*BASE=none*) no "E: branch-head never prints BASE=none" ;;
*) ok "E: branch-head never prints BASE=none" ;;
esac
r9="${work}/case-e-trunk"
mkdir -p "${r9}"
git -C "${r9}" init -q -b trunk
git -C "${r9}" config user.email "test@example.com"
git -C "${r9}" config user.name "Test User"
git -C "${r9}" commit -q --allow-empty -m first
bash "${BRANCH_HEAD}" --repo "${r9}" >/dev/null 2>&1
assert_eq "$?" "2" "E: branch-head with no resolvable base exits 2"

# --- F. detached HEAD ---
git -C "${r4}" checkout -q --detach
out="$(bash "${BRANCH_HEAD}" --repo "${r4}" --base main 2>&1)"
assert_contains "${out}" "BRANCH=(detached)" "F: detached HEAD prints BRANCH=(detached)"
git -C "${r4}" checkout -q main

# --- G. --expect-head must be 10-64 hex characters ---
bash "${BRANCH_HEAD}" --repo "${r4}" --expect-head "${r4_main:0:6}" >/dev/null 2>&1
assert_eq "$?" "2" "G: --expect-head shorter than 10 hex chars exits 2 even when it prefixes HEAD"
out="$(bash "${BRANCH_HEAD}" --repo "${r4}" --expect-head zzzzzzzzzzzz 2>&1)"
rc=$?
assert_eq "${rc}" "2" "G: --expect-head with non-hex characters exits 2"
case "${out}" in
*STALE*) no "G: non-hex --expect-head is a usage error, not STALE" ;;
*) ok "G: non-hex --expect-head is a usage error, not STALE" ;;
esac

# --- H. bare repository ---
git clone -q --bare "${r4}" "${work}/bare.git"
bash "${PREFLIGHT}" --repo "${work}/bare.git" >/dev/null 2>&1
assert_eq "$?" "2" "H: preflight on a bare repo exits 2"
bash "${BRANCH_HEAD}" --repo "${work}/bare.git" >/dev/null 2>&1
assert_eq "$?" "2" "H: branch-head on a bare repo exits 2"

# --- I. failing verify output: one-line row, full output on stderr ---
r10="$(make_git_repo case-i)"
mkdir -p "${r10}/scripts"
long="$(printf 'x%.0s' $(seq 1 400))"
printf '#!/usr/bin/env bash\necho "%s-TAILMARK" >&2\nexit 1\n' "${long}" >"${r10}/scripts/verify-license-header.sh"
git -C "${r10}" add scripts
git -C "${r10}" commit -q -m "add failing verify script"
bash "${PREFLIGHT}" --repo "${r10}" >"${work}/i.out" 2>"${work}/i.err"
rc=$?
assert_eq "${rc}" "1" "I: failing verify script exits 1"
assert_eq "$(grep -c 'license-header |' "${work}/i.out")" "1" "I: failing check stays one row on stdout"
assert_contains "$(cat "${work}/i.err")" "-TAILMARK" "I: full failing output reaches stderr untruncated"

# --- 12a. preflight scopes to the repo root, not the --repo subdirectory ---
r6="$(make_git_repo subdir)"
mkdir -p "${r6}/scripts" "${r6}/sub"
printf 'echo root-license-ok\n' >"${r6}/scripts/verify-license-header.sh"
printf 'x\n' >"${r6}/sub/keep.txt"
git -C "${r6}" add scripts sub
git -C "${r6}" commit -q -m "add root verify script"
printf 'stray\n' >"${r6}/untracked-at-root.txt"
out="$(bash "${PREFLIGHT}" --repo "${r6}/sub" --base main 2>&1)"
assert_contains "${out}" "license-header | PASS | root-license-ok" "preflight --repo <subdir> runs the root verify script"
assert_contains "${out}" "untracked 1" "preflight --repo <subdir> counts untracked files across the repo root"

# --- 12b. the TODO scan covers added files only, never lines edited in an existing test ---
r7="$(make_git_repo added-only)"
printf 'package demo\n' >"${r7}/old_test.go"
git -C "${r7}" add old_test.go
git -C "${r7}" commit -q -m "existing test file on the base"
git -C "${r7}" checkout -q -b feat
printf '// %s: inherited note\n' "${todo_tok}" >>"${r7}/old_test.go"
git -C "${r7}" commit -q -am "edit existing test file"
out="$(bash "${PREFLIGHT}" --repo "${r7}" --base main 2>&1)"
assert_contains "${out}" "test-todo-scan | PASS |" "a TODO line added to a modified (not added) test file is not a hit"

# --- 12c. origin/main outranks main and HEAD~1 when --base is absent ---
r8="$(make_git_repo origin-pref)"
c1="$(git -C "${r8}" rev-parse HEAD)"
printf '// %s: stub\n' "${todo_tok}" >"${r8}/stub_test.go"
git -C "${r8}" add stub_test.go
git -C "${r8}" commit -q -m "add test file with a hit"
printf 'more\n' >"${r8}/more.txt"
git -C "${r8}" add more.txt
git -C "${r8}" commit -q -m "unrelated follow-up"
git -C "${r8}" update-ref refs/remotes/origin/main "${c1}"
out="$(bash "${PREFLIGHT}" --repo "${r8}" 2>&1)"
assert_contains "${out}" "test-todo-scan | FAIL |" "preflight defaults the base to origin/main, not main or HEAD~1"
out="$(bash "${BRANCH_HEAD}" --repo "${r8}" 2>&1)"
assert_contains "${out}" "BASE=${c1}" "branch-head defaults BASE to the merge-base with origin/main"

# --- gh tripwire: no script touched gh ---
assert_eq "$(wc -c <"${gh_log}" | tr -d ' ')" "0" "neither script called gh"

# --- 13. --help flags ---
bash "${PREFLIGHT}" --help >/dev/null 2>&1
assert_eq "$?" "0" "preflight --help exits 0"
bash "${BRANCH_HEAD}" --help >/dev/null 2>&1
assert_eq "$?" "0" "branch-head --help exits 0"

printf '\ncode-mode-scripts: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

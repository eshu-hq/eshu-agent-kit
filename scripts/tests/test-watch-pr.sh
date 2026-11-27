#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# Hermetic tests for scripts/watch-pr.sh using a stubbed `gh` binary.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCH="${KIT_DIR}/scripts/watch-pr.sh"
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

# Build a stub `gh` that pops sequential JSON fixtures per subcommand.
mkdir -p "${work}/bin"
cat >"${work}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
case "${sub}" in
repo)
	printf 'acme/widget\n'
	exit 0
	;;
auth)
	printf 'stub-token\n'
	exit 0
	;;
pr)
	idx_file="${STUB_DIR}/pr.idx"
	n=1
	[ -f "${idx_file}" ] && n=$(( $(cat "${idx_file}") + 1 ))
	printf '%s' "${n}" >"${idx_file}"
	f="${STUB_DIR}/pr.${n}.json"
	[ -f "${f}" ] || f="${STUB_DIR}/pr.last.json"
	cat "${f}"
	exit 0
	;;
api)
	idx_file="${STUB_DIR}/api.idx"
	n=1
	[ -f "${idx_file}" ] && n=$(( $(cat "${idx_file}") + 1 ))
	printf '%s' "${n}" >"${idx_file}"
	f="${STUB_DIR}/api.${n}.txt"
	[ -f "${f}" ] || f="${STUB_DIR}/api.last.txt"
	cat "${f}"
	exit 0
	;;
esac
exit 1
EOF
chmod +x "${work}/bin/gh" "${WATCH}"

# 1. Usage / bad PR validation exits 2.
if ! bash "${WATCH}" >/dev/null 2>&1 && ! bash "${WATCH}" abc >/dev/null 2>&1; then
	ok "rejects missing or non-numeric PR arguments"
else
	no "rejects missing or non-numeric PR arguments"
fi

# 2. GREEN requires 2 stable reads + required context; unchanged poll stays silent; MERGED exits with WATCH state=done.
c2="${work}/c2"
mkdir -p "${c2}"
cat >"${c2}/pr.1.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","headRefOid":"aaaa111122223333","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci-complete","status":"COMPLETED","conclusion":"SUCCESS"}]}
EOF
cp "${c2}/pr.1.json" "${c2}/pr.2.json"
cat >"${c2}/pr.3.json" <<'EOF'
{"state":"MERGED","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","headRefOid":"aaaa111122223333","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci-complete","status":"COMPLETED","conclusion":"SUCCESS"}]}
EOF
printf '0\n' >"${c2}/api.last.txt"

out2="$(PATH="${work}/bin:${PATH}" STUB_DIR="${c2}" bash "${WATCH}" --interval 0 --stable-reads 2 --required ci-complete 455)"
if grep -q 'WATCH state=start repo=acme/widget prs=455' <<<"${out2}" &&
	[ "$(grep -c 'GREEN pr=455 head=aaaa111122 checks=1' <<<"${out2}")" -eq 1 ] &&
	grep -q 'MERGED pr=455 head=aaaa111122' <<<"${out2}" &&
	grep -q 'WATCH state=done repo=acme/widget' <<<"${out2}"; then
	ok "emits GREEN on 2nd stable read with required context and exits done on MERGED"
else
	printf '%s\n' "${out2}" >&2
	no "emits GREEN on 2nd stable read with required context and exits done on MERGED"
fi

# 3. Detects CONFLICT, CANCELLED CI-FAIL, NEW-THREAD, NEW-REVIEW, NEW-COMMENT, and HEAD-MOVED.
c3="${work}/c3"
mkdir -p "${c3}"
cat >"${c3}/pr.1.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","headRefOid":"1111aaaa0000","comments":[],"reviews":[],"statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"CANCELLED"}]}
EOF
cat >"${c3}/pr.2.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","headRefOid":"2222bbbb0000","comments":[{"author":{"login":"teammate"}}],"reviews":[{"author":{"login":"reviewer"},"state":"CHANGES_REQUESTED"}],"statusCheckRollup":[{"name":"lint","status":"IN_PROGRESS","conclusion":""}]}
EOF
printf '0\n' >"${c3}/api.1.txt"
printf '2\n' >"${c3}/api.2.txt"

out3="$(PATH="${work}/bin:${PATH}" STUB_DIR="${c3}" bash "${WATCH}" --repo org/app --interval 0 --max-polls 2 99)"
if grep -q 'CONFLICT pr=99 state=CONFLICTING head=1111aaaa00' <<<"${out3}" &&
	grep -q 'CI-FAIL pr=99 head=1111aaaa00 jobs="lint"' <<<"${out3}" &&
	grep -q 'HEAD-MOVED pr=99 from=1111aaaa00 to=2222bbbb00' <<<"${out3}" &&
	grep -q 'NEW-THREAD pr=99 unresolved=2' <<<"${out3}" &&
	grep -q 'NEW-REVIEW pr=99 count=1 latest=reviewer:CHANGES_REQUESTED' <<<"${out3}" &&
	grep -q 'NEW-COMMENT pr=99 count=1' <<<"${out3}" &&
	! grep -q 'GREEN ' <<<"${out3}"; then
	ok "detects CONFLICT, CANCELLED CI-FAIL, HEAD-MOVED, NEW-THREAD, NEW-REVIEW, and NEW-COMMENT"
else
	printf '%s\n' "${out3}" >&2
	no "detects CONFLICT, CANCELLED CI-FAIL, HEAD-MOVED, NEW-THREAD, NEW-REVIEW, and NEW-COMMENT"
fi

# 4. --exit-on-event stops immediately on first actionable event.
c4="${work}/c4"
mkdir -p "${c4}"
cp "${c3}/pr.1.json" "${c4}/pr.last.json"
printf '0\n' >"${c4}/api.last.txt"
out4="$(PATH="${work}/bin:${PATH}" STUB_DIR="${c4}" bash "${WATCH}" --repo org/app --interval 0 --exit-on-event 99)"
if grep -q 'WATCH state=stopped reason=event' <<<"${out4}" &&
	[ "$(cat "${c4}/pr.idx")" -eq 1 ]; then
	ok "--exit-on-event stops after first actionable event"
else
	printf '%s\n' "${out4}" >&2
	no "--exit-on-event stops after first actionable event"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL watch-pr: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS watch-pr: %d checks green\n' "${passed}"

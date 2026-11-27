#!/usr/bin/env bash
# Hermetic tests for Wave 3 Code Mode scripts: review-context.sh, threads.sh,
# and pr-readiness.sh (issue #132).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEW_CTX="${KIT_DIR}/skills/eshu/code-review/scripts/review-context.sh"
THREADS="${KIT_DIR}/skills/eshu/resolve-review-threads/scripts/threads.sh"
READINESS="${KIT_DIR}/skills/eshu/issue-driver/scripts/pr-readiness.sh"

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

# --- Temp git repo with multi-surface diff ---
repo="${work}/repo"
mkdir -p "${repo}/go/internal/reducer" "${repo}/go/internal/queue" "${repo}/skills/eshu/demo"
git -C "${repo}" init -q -b main
git -C "${repo}" config user.email test@example.com
git -C "${repo}" config user.name Test
printf 'package main\n' >"${repo}/go/internal/reducer/r.go"
git -C "${repo}" add -A && git -C "${repo}" commit -q -m init
git -C "${repo}" checkout -q -b feat/test
printf 'package reducer\n// change\n' >>"${repo}/go/internal/reducer/r.go"
printf 'SELECT 1;\n' >"${repo}/go/internal/queue/claim.sql"
printf '# Demo\n' >"${repo}/skills/eshu/demo/SKILL.md"
git -C "${repo}" add -A && git -C "${repo}" commit -q -m "touch surfaces"
head_sha="$(git -C "${repo}" rev-parse HEAD)"

# --- Stub gh binary driven by GH_STUB_MODE ---
FAKE_BIN="${work}/bin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
mode="${GH_STUB_MODE:-ready}"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
	echo "eshu-hq/demo"
	exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
	case "${mode}" in
	closed)
		printf '{"number":42,"state":"MERGED","headRefOid":"%s","headRefName":"feat/test","baseRefName":"main","mergeStateStatus":"CLEAN","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[]}\n' "${GH_STUB_HEAD}"
		;;
	failing)
		printf '{"number":42,"state":"OPEN","headRefOid":"%s","headRefName":"feat/test","baseRefName":"main","mergeStateStatus":"UNSTABLE","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"name":"ci/test","status":"COMPLETED","conclusion":"FAILURE"}]}\n' "${GH_STUB_HEAD}"
		;;
	gh-error)
		echo "gh: pull request not found" >&2
		exit 1
		;;
	*)
		printf '{"number":42,"state":"OPEN","headRefOid":"%s","headRefName":"feat/test","baseRefName":"main","mergeStateStatus":"CLEAN","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[{"name":"ci/test","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' "${GH_STUB_HEAD}"
		;;
	esac
	exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
	if printf '%s ' "$@" | grep -q 'resolveReviewThread'; then
		if [ "${mode}" = "silent-fail" ]; then
			printf '{"data":{"resolveReviewThread":{"thread":{"id":"T_BAD","isResolved":false}}}}\n'
		else
			printf '{"data":{"resolveReviewThread":{"thread":{"id":"T_OPEN","isResolved":true}}}}\n'
		fi
		exit 0
	fi
	case "${mode}" in
	open-thread)
		printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"T_DONE","isResolved":true,"isOutdated":false,"path":"a.go","line":1,"originalLine":1,"comments":{"nodes":[{"author":{"login":"bot"},"body":"old"}]}},{"id":"T_OPEN","isResolved":false,"isOutdated":true,"path":"r.go","line":10,"originalLine":10,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"fix nil check\\nsecond line"}]}}]}}}}}\n'
		;;
	truncated)
		printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}}\n'
		;;
	*)
		printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"T_DONE","isResolved":true,"isOutdated":false,"path":"a.go","line":1,"originalLine":1,"comments":{"nodes":[{"author":{"login":"bot"},"body":"done"}]}}]}}}}}\n'
		;;
	esac
	exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
EOF
chmod +x "${FAKE_BIN}/gh"

# 1. review-context.sh classifies diff surfaces and joins PR checks.
if (cd "${repo}" && PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=ready GH_STUB_HEAD="${head_sha}" \
	bash "${REVIEW_CTX}" --base main --pr 42 --json >"${work}/ctx.json") &&
	python3 - "${work}/ctx.json" "${head_sha}" <<'PYEOF'; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["head_sha"] == sys.argv[2] and d["files_changed"] == 3, d
assert {"reducer_projector", "queue_storage_sql", "skills_agents", "go_code"}.issubset(d["surfaces"]), d["surfaces"]
assert d["pr"]["number"] == 42 and d["pr"]["head_matches_local"] is True and d["pr"]["checks_passed"] == 1, d["pr"]
PYEOF
	ok "review-context.sh classifies multi-surface diff and PR check rollup"
else
	no "review-context.sh classifies multi-surface diff and PR check rollup"
fi

if ! (cd "${repo}" && PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=gh-error GH_STUB_HEAD="${head_sha}" \
	bash "${REVIEW_CTX}" --base main --pr 999 >/dev/null 2>&1); then
	ok "review-context.sh fails loudly when gh pr view fails"
else
	no "review-context.sh fails loudly when gh pr view fails"
fi

# 2. threads.sh list filters open threads, refuses MERGED PRs, and exits 3 on truncation.
if PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=open-thread GH_STUB_HEAD="${head_sha}" \
	bash "${THREADS}" list --pr 42 --json >"${work}/threads.json" &&
	python3 - "${work}/threads.json" <<'PYEOF'; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["scanned"] == 2 and d["already_resolved"] == 1 and d["unresolved"] == 1, d
t = d["threads"][0]
assert t["id"] == "T_OPEN" and t["isOutdated"] is True and t["author"] == "reviewer", t
assert "\n" not in t["preview"] and "fix nil check" in t["preview"], t
PYEOF
	ok "threads.sh list returns open threads including outdated and strips newlines"
else
	no "threads.sh list returns open threads including outdated and strips newlines"
fi

if ! (PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=closed GH_STUB_HEAD="${head_sha}" \
	bash "${THREADS}" list --pr 42 >/dev/null 2>&1) &&
	(
		PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=truncated GH_STUB_HEAD="${head_sha}" \
			bash "${THREADS}" list --pr 42 >/dev/null 2>&1
		[ "$?" -eq 3 ]
	); then
	ok "threads.sh list refuses MERGED PRs and exits 3 when truncated"
else
	no "threads.sh list refuses MERGED PRs and exits 3 when truncated"
fi

# 3. threads.sh resolve supports --dry-run, live resolve, and catches silent isResolved=false failures.
if PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=ready GH_STUB_HEAD="${head_sha}" \
	bash "${THREADS}" resolve --thread-id T_OPEN --dry-run --json | grep -q '"dry-run"' &&
	PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=ready GH_STUB_HEAD="${head_sha}" \
		bash "${THREADS}" resolve --thread-id T_OPEN --json | grep -q '"resolved"' &&
	! (PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=silent-fail GH_STUB_HEAD="${head_sha}" \
		bash "${THREADS}" resolve --thread-id T_BAD >/dev/null 2>&1); then
	ok "threads.sh resolve handles --dry-run, live resolve, and silent-failure detection"
else
	no "threads.sh resolve handles --dry-run, live resolve, and silent-failure detection"
fi

# 4. pr-readiness.sh exits 0 when ready, exits 1 on open threads / failing checks / head mismatch.
if PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=ready GH_STUB_HEAD="${head_sha}" \
	bash "${READINESS}" --pr 42 --expect-head "${head_sha:0:8}" --json >"${work}/ready.json" &&
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ready"] is True and d["unresolved_threads"]==0' "${work}/ready.json" &&
	! (PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=open-thread GH_STUB_HEAD="${head_sha}" \
		bash "${READINESS}" --pr 42 >/dev/null 2>&1) &&
	! (PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=failing GH_STUB_HEAD="${head_sha}" \
		bash "${READINESS}" --pr 42 >/dev/null 2>&1) &&
	! (PATH="${FAKE_BIN}:${PATH}" GH_STUB_MODE=ready GH_STUB_HEAD="${head_sha}" \
		bash "${READINESS}" --pr 42 --expect-head deadbeef >/dev/null 2>&1); then
	ok "pr-readiness.sh exits 0 when ready and 1 on open threads, red checks, or SHA drift"
else
	no "pr-readiness.sh exits 0 when ready and 1 on open threads, red checks, or SHA drift"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL code-mode-wave3: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS code-mode-wave3: %d checks green\n' "${passed}"

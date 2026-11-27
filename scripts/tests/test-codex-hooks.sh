#!/usr/bin/env bash
# Hermetic tests for Codex skill-loaded.sh & skill-nudge.sh adapters (issue #133).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"; rm -f /tmp/claude-skill-loaded-cdx133-* /tmp/claude-skill-nudged-cdx133-*' EXIT

export HOME="${work}/home"
export XDG_DATA_HOME="${work}/xdg"
export TMPDIR="${work}/tmp"
mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${TMPDIR}"

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

repo="${work}/repo"
mkdir -p "${repo}"
git -C "${repo}" init -q -b main
bash "${KIT_DIR}/install.sh" --hooks --repo "${repo}" </dev/null >/dev/null 2>&1

# 1. Repo install delivers Codex skill-loaded.sh and skill-nudge.sh symlinks.
if [ -L "${repo}/.codex/hooks/skill-loaded.sh" ] && [ -L "${repo}/.codex/hooks/skill-nudge.sh" ]; then
	ok "install.sh --hooks --repo delivers Codex skill-loaded.sh and skill-nudge.sh"
else
	no "install.sh --hooks --repo delivers Codex skill-loaded.sh and skill-nudge.sh"
fi

# 2. Codex skill-nudge blocks an un-loaded Go edit and logs harness=codex nudge event.
sid="cdx133-00001"
if (
	cd "${repo}"
	printf '{"session_id":"%s","tool_name":"apply_patch","tool_input":{"input":"*** Begin Patch\\n*** Update File: go/internal/queue/claim.go\\n"}}' "${sid}" |
		bash "${repo}/.codex/hooks/skill-nudge.sh" >/dev/null 2>&1
	[ "$?" -eq 2 ]
) && grep -q '"harness": "codex"' "${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"; then
	ok "Codex skill-nudge blocks un-loaded apply_patch on Go/queue path and logs harness=codex"
else
	no "Codex skill-nudge blocks un-loaded apply_patch on Go/queue path and logs harness=codex"
fi

# 3. Codex skill-loaded recognizes SKILL.md reads in exec and explicit read_skill calls.
if (
	cd "${repo}"
	printf '{"session_id":"%s","tool_name":"exec","tool_input":{"cmd":"cat /repo/skills/eshu/postgres-rigor/SKILL.md"}}' "${sid}" |
		bash "${repo}/.codex/hooks/skill-loaded.sh" &&
		printf '{"session_id":"%s","tool_name":"read_skill","tool_input":{"name":"concurrency-deadlock-rigor"}}' "${sid}" |
		bash "${repo}/.codex/hooks/skill-loaded.sh"
) && [ -f "/tmp/claude-skill-loaded-${sid}-postgres-rigor" ] &&
	[ -f "/tmp/claude-skill-loaded-${sid}-concurrency-deadlock-rigor" ] &&
	grep -q '"skill": "postgres-rigor"' "${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl" &&
	grep -q '"skill": "concurrency-deadlock-rigor"' "${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"; then
	ok "Codex skill-loaded writes markers and logs skill-load events for SKILL.md and read_skill"
else
	no "Codex skill-loaded writes markers and logs skill-load events for SKILL.md and read_skill"
fi

# 4. After skill-loaded fires, Codex skill-nudge permits the edit cleanly (exit 0).
if (
	cd "${repo}"
	printf '{"session_id":"%s","tool_name":"apply_patch","tool_input":{"input":"*** Begin Patch\\n*** Update File: go/internal/queue/claim.go\\n"}}' "${sid}" |
		bash "${repo}/.codex/hooks/skill-nudge.sh" >/dev/null 2>&1
); then
	ok "Codex skill-nudge permits edit after skill-loaded records markers"
else
	no "Codex skill-nudge permits edit after skill-loaded records markers"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL codex-hooks: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS codex-hooks: %d checks green\n' "${passed}"

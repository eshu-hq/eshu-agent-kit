#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# Hermetic cross-harness behavioral tests for hooks/pr-watch-nudge.sh,
# hooks/pr-watch-guard.sh, and the Muse, Claude, agy, OpenCode, Codex,
# and Cursor adapters.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

export HOME="${work}/home"
export XDG_DATA_HOME="${work}/xdg"
export TMPDIR="${work}/tmp"
mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${TMPDIR}"
unset KIT_PR_WATCH_OFF CLAUDE_HOOK_ALLOW ESHU_SKILLS_TELEMETRY_OFF KIT_GLOBAL_HOOK KIT_HARNESS

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

# 1. Repo install links scripts/watch-pr.sh and all harness wrappers.
if [ -L "${repo}/scripts/watch-pr.sh" ] &&
	[ -L "${repo}/.claude/hooks/pr-watch-nudge.sh" ] &&
	[ -L "${repo}/.claude/hooks/pr-watch-guard.sh" ] &&
	[ -L "${repo}/.muse/hooks/pr-watch-nudge.sh" ] &&
	[ -L "${repo}/.muse/hooks/pr-watch-guard.sh" ] &&
	[ -L "${repo}/.agy/hooks/pr-watch-nudge.sh" ] &&
	[ -L "${repo}/.agy/hooks/pr-watch-guard.sh" ] &&
	[ -L "${repo}/.codex/hooks/pr-watch-nudge.sh" ] &&
	[ -L "${repo}/.cursor/hooks/pr-watch-nudge.sh" ]; then
	ok "install --hooks --repo links watch-pr.sh and all 6 harness hooks"
else
	no "install --hooks --repo links watch-pr.sh and all 6 harness hooks"
fi

# 2. Muse flow: gh pr create nudges with monitor + watch-pr.sh, blocks snooze & one-shot monitor, then allows snooze after valid monitor arms it.
msid="museprw00001-full"
m_create='{"hook_event_name":"PostToolUse","tool_name":"bash","session_id":"'"${msid}"'","cwd":"'"${repo}"'","tool_input":{"command":"gh pr create --title test"},"tool_response":"{\"output\":\"https://github.com/acme/app/pull/455\\n\"}"}'
m_out="$(printf '%s' "${m_create}" | bash "${repo}/.muse/hooks/pr-watch-nudge.sh" 2>/dev/null)"
if grep -q 'monitor' <<<"${m_out}" && grep -q 'watch-pr.sh --repo acme/app 455' <<<"${m_out}"; then
	ok "Muse PostToolUse on gh pr create emits monitor + watch-pr.sh command"
else
	no "Muse PostToolUse on gh pr create emits monitor + watch-pr.sh command"
fi

# 2b. Muse PreToolUse blocks report_progress(snooze_minutes: 30) while #455 is unwatched.
m_snooze='{"hook_event_name":"PreToolUse","tool_name":"report_progress","session_id":"'"${msid}"'","cwd":"'"${repo}"'","tool_input":{"current_work":"waiting","snooze_minutes":30}}'
set +e
m_s_err="$(printf '%s' "${m_snooze}" | bash "${repo}/.muse/hooks/pr-watch-guard.sh" 2>&1)"
m_s_rc=$?
set -e
if [ "${m_s_rc}" -eq 2 ] && grep -q 'acme/app#455' <<<"${m_s_err}"; then
	ok "Muse PreToolUse blocks report_progress snooze while PR #455 is unwatched"
else
	no "Muse PreToolUse blocks report_progress snooze while PR #455 is unwatched (rc=${m_s_rc})"
fi

# 2c. Muse PreToolUse blocks one-shot gh pr view inside monitor.
m_badmon='{"hook_event_name":"PreToolUse","tool_name":"monitor","session_id":"'"${msid}"'","cwd":"'"${repo}"'","tool_input":{"command":"gh pr view 455 --json statusCheckRollup"}}'
set +e
m_bm_err="$(printf '%s' "${m_badmon}" | bash "${repo}/.muse/hooks/pr-watch-guard.sh" 2>&1)"
m_bm_rc=$?
set -e
if [ "${m_bm_rc}" -eq 2 ] && grep -q 'one-shot' <<<"${m_bm_err}"; then
	ok "Muse PreToolUse blocks one-shot gh pr view inside monitor"
else
	no "Muse PreToolUse blocks one-shot gh pr view inside monitor (rc=${m_bm_rc})"
fi

# 2c-bis. Read-only commands referencing hook files or --help do NOT falsely arm PR #455.
for benign in \
	"cat hooks/pr-watch-nudge.sh" \
	"shellcheck hooks/pr-watch-guard.sh" \
	"rg pr-watch hooks/" \
	"bash ${KIT_DIR}/scripts/watch-pr.sh --help"; do
	b_pre='{"hook_event_name":"PreToolUse","tool_name":"bash","session_id":"'"${msid}"'","cwd":"'"${repo}"'","tool_input":{"command":"'"${benign}"'"}}'
	b_post='{"hook_event_name":"PostToolUse","tool_name":"bash","session_id":"'"${msid}"'","cwd":"'"${repo}"'","tool_input":{"command":"'"${benign}"'"},"tool_response":"{\"output\":\"ok\"}"}'
	printf '%s' "${b_pre}" | bash "${repo}/.muse/hooks/pr-watch-guard.sh" 2>/dev/null || true
	printf '%s' "${b_post}" | bash "${repo}/.muse/hooks/pr-watch-nudge.sh" 2>/dev/null || true
done
set +e
printf '%s' "${m_snooze}" | bash "${repo}/.muse/hooks/pr-watch-guard.sh" 2>/dev/null
m_s_still_rc=$?
set -e
if [ "${m_s_still_rc}" -eq 2 ]; then
	ok "read-only commands mentioning hook files or --help do not falsely arm PR #455"
else
	no "read-only commands mentioning hook files or --help do not falsely arm PR #455 (rc=${m_s_still_rc})"
fi

# 2d. Muse PreToolUse allows valid looping watch-pr.sh inside monitor and clears unwatched flag.
m_goodmon='{"hook_event_name":"PreToolUse","tool_name":"monitor","session_id":"'"${msid}"'","cwd":"'"${repo}"'","tool_input":{"command":"bash '"${KIT_DIR}"'/scripts/watch-pr.sh --repo acme/app 455","persistent":true}}'
if printf '%s' "${m_goodmon}" | bash "${repo}/.muse/hooks/pr-watch-guard.sh" 2>/dev/null &&
	printf '%s' "${m_snooze}" | bash "${repo}/.muse/hooks/pr-watch-guard.sh" 2>/dev/null; then
	ok "Muse PreToolUse marks PR armed on watch-pr.sh monitor and then allows snooze"
else
	no "Muse PreToolUse marks PR armed on watch-pr.sh monitor and then allows snooze"
fi

# 3. Claude Code PostToolUse emits watch-pr.sh command and records telemetry.
csid="claudprw0001-full"
c_create='{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"'"${csid}"'","cwd":"'"${repo}"'","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"https://github.com/acme/app/pull/77\n"}}'
c_out="$(printf '%s' "${c_create}" | bash "${repo}/.claude/hooks/pr-watch-nudge.sh" 2>/dev/null)"
if grep -q 'watch-pr.sh --repo acme/app 77' <<<"${c_out}"; then
	ok "Claude PostToolUse on gh pr create emits watch-pr.sh guidance"
else
	no "Claude PostToolUse on gh pr create emits watch-pr.sh guidance"
fi

# 4. Antigravity (agy) PostToolUse adapter translates camelCase run_command and emits additionalContext.
asid="agyprw000001-full"
a_create='{"conversationId":"'"${asid}"'","cwd":"'"${repo}"'","toolCall":{"name":"run_command","args":{"CommandLine":"gh pr create --fill"}},"toolResult":"https://github.com/acme/app/pull/88\n"}'
a_out="$(cd "${repo}/.agents" && printf '%s' "${a_create}" | bash "${repo}/.agy/hooks/pr-watch-nudge.sh" 2>/dev/null)"
if grep -q 'additionalContext' <<<"${a_out}" && grep -q -- '--exit-on-event 88' <<<"${a_out}"; then
	ok "agy PostToolUse translates run_command gh pr create to additionalContext"
else
	no "agy PostToolUse translates run_command gh pr create to additionalContext"
fi

# 5. Codex adapter emits --exit-on-event guidance with KIT_HARNESS=codex.
xsid="codexprw0001-full"
x_create='{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"'"${xsid}"'","cwd":"'"${repo}"'","tool_input":{"command":"gh pr create"},"tool_response":{"stdout":"https://github.com/acme/app/pull/89\n"}}'
x_out="$(cd "${repo}" && printf '%s' "${x_create}" | bash "${repo}/.codex/hooks/pr-watch-nudge.sh" 2>/dev/null)"
if grep -q -- '--exit-on-event 89' <<<"${x_out}"; then
	ok "Codex PostToolUse adapter emits --exit-on-event watcher guidance"
else
	no "Codex PostToolUse adapter emits --exit-on-event watcher guidance"
fi

# 6. Cursor adapter translates afterShellExecution to additional_context.
ksid="curprw000001-full"
k_create='{"conversation_id":"'"${ksid}"'","workspace_roots":["'"${repo}"'"],"command":"gh pr create","output":"https://github.com/acme/app/pull/90\n"}'
k_out="$(printf '%s' "${k_create}" | bash "${repo}/.cursor/hooks/pr-watch-nudge.sh" 2>/dev/null)"
if grep -q 'additional_context' <<<"${k_out}" && grep -q -- '--exit-on-event 90' <<<"${k_out}"; then
	ok "Cursor afterShellExecution adapter emits additional_context with watch-pr.sh"
else
	no "Cursor afterShellExecution adapter emits additional_context with watch-pr.sh"
fi

# 7. OpenCode V2 bridge records PR creation and appends watcher guidance on bash execute.after.
if command -v node >/dev/null 2>&1; then
	oc_res="$(ESHU_KIT_DIR="${KIT_DIR}" node -e '
		import("file://" + process.env.ESHU_KIT_DIR + "/plugins/opencode/eshu-bridge.js").then(async ({default: plugin}) => {
			let afterFn;
			const ctx = {
				directory: process.argv[1],
				tool: { hook: async (ev, fn) => { if (ev === "execute.after") afterFn = fn; return { dispose() {} }; } },
			};
			const stop = await plugin.setup(ctx);
			const ev = { status: "completed", sessionID: "ocprw0000001-full", tool: "bash", input: { command: "gh pr create" }, output: "https://github.com/acme/app/pull/91" };
			await afterFn(ev);
			await stop();
			process.stdout.write(ev.output);
		});
	' "${repo}" 2>/dev/null)"
	if grep -q -- '--exit-on-event 91' <<<"${oc_res}"; then
		ok "OpenCode V2 bridge appends watch-pr.sh guidance on bash gh pr create"
	else
		no "OpenCode V2 bridge appends watch-pr.sh guidance on bash gh pr create"
	fi
fi

# 8. Telemetry recorded across harnesses in skills-usage.jsonl.
log="${XDG_DATA_HOME}/eshu-agent-kit/skills-usage.jsonl"
if [ -f "${log}" ] &&
	grep -q '"type": "pr-opened"' "${log}" &&
	grep -q '"type": "pr-watch-armed"' "${log}" &&
	grep -q '"type": "pr-watch-block"' "${log}" &&
	grep -q '"harness": "muse"' "${log}" &&
	grep -q '"harness": "cursor"' "${log}" &&
	grep -q '"harness": "codex"' "${log}" &&
	grep -q '"harness": "agy"' "${log}"; then
	ok "telemetry logs pr-opened, pr-watch-armed, and pr-watch-block across harnesses"
else
	no "telemetry logs pr-opened, pr-watch-armed, and pr-watch-block across harnesses"
fi

if [ "${failed}" -gt 0 ]; then
	printf 'FAIL pr-watch-hooks: %d of %d checks failed\n' "${failed}" "$((passed + failed))" >&2
	exit 1
fi
printf 'PASS pr-watch-hooks: %d checks green\n' "${passed}"

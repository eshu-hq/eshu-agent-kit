#!/usr/bin/env bash
# Behavioural mirror for hooks/guard-live-gate.sh.
#
# This hook can REFUSE a Bash call (exit 2), so every fail-open path is
# load-bearing: outside an Eshu checkout, for a command it does not guard,
# on empty/unparseable input, without python3, or with CLAUDE_HOOK_ALLOW=1,
# it must allow. The one BLOCKED path is proven by binding a probed port
# (GATE_API_PORT 18080) inside a fake Eshu checkout; if the bind fails the
# case skips instead of failing, so the suite never reds a busy machine.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${repo_root}/guard-live-gate.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
eshu="${work}/eshu"
mkdir -p "${eshu}/.agents/skills/code-review"
plain="${work}/plain"
mkdir -p "${plain}"

passed=0
failed=0
ok() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
no() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }

# run CWD CMD -> exit code; stdout/stderr discarded except where noted.
run() { printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1" | bash "${HOOK}" >/dev/null 2>&1; }

printf '{"tool_input":{"command":"make pre-pr"},"cwd":"%s"}' "${eshu}" | bash "${HOOK}" >/dev/null 2>&1; code=$?
[ "${code}" = "0" ] && ok "guarded command on a quiet machine allows (exit 0)" || no "guarded command on a quiet machine allows (got ${code})"

run "${plain}" "make pre-pr"; [ "$?" = "0" ] && ok "outside an Eshu checkout a guarded command allows" || no "outside an Eshu checkout a guarded command allows"
run "${eshu}" "make build"; [ "$?" = "0" ] && ok "an unguarded command allows inside Eshu" || no "an unguarded command allows inside Eshu"
printf '' | bash "${HOOK}" >/dev/null 2>&1; [ "$?" = "0" ] && ok "empty stdin allows" || no "empty stdin allows"
printf 'not json' | bash "${HOOK}" >/dev/null 2>&1; [ "$?" = "0" ] && ok "unparseable input allows" || no "unparseable input allows"
run "${eshu}" "CLAUDE_HOOK_ALLOW=1 make pre-pr"; [ "$?" = "0" ] && ok "CLAUDE_HOOK_ALLOW=1 override allows" || no "CLAUDE_HOOK_ALLOW=1 override allows"

# BLOCKED path: bind 18080 (GATE_API_PORT default) then run a guarded command.
if command -v python3 >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
  python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 &
  srv=$!
  sleep 1
  if lsof -nP -iTCP:18080 -sTCP:LISTEN >/dev/null 2>&1; then
    out=$(printf '{"tool_input":{"command":"make pre-pr"},"cwd":"%s"}' "${eshu}" | bash "${HOOK}" 2>&1); code=$?
    [ "${code}" = "2" ] && ok "guarded command with a bound probed port blocks (exit 2)" || no "guarded command with a bound probed port blocks (got ${code})"
    case "${out}" in
      *BLOCKED:*) ok "block message names the contention" ;;
      *) no "block message names the contention" ;;
    esac
    out2=$(printf '{"tool_input":{"command":"GATE_API_PORT=18081 make pre-pr"},"cwd":"%s"}' "${eshu}" | bash "${HOOK}" 2>&1); code2=$?
    # 18081 is free, so the waived probe plus free siblings still allow.
    [ "${code2}" = "0" ] && ok "per-port override waives only its own probe" || no "per-port override waives only its own probe (got ${code2})"
    out3=$(printf '{"tool_input":{"command":"CLAUDE_HOOK_ALLOW=1 make pre-pr"},"cwd":"%s"}' "${eshu}" | bash "${HOOK}" 2>&1); code3=$?
    [ "${code3}" = "0" ] && ok "override allows while a port is bound" || no "override allows while a port is bound (got ${code3})"
  else
    ok "SKIP blocked-path cases: port 18080 already in use on this machine"
    ok "SKIP blocked-path cases: port 18080 already in use on this machine"
    ok "SKIP blocked-path cases: port 18080 already in use on this machine"
  fi
  kill "${srv}" 2>/dev/null
  wait "${srv}" 2>/dev/null || true
else
  ok "SKIP blocked-path cases: python3 or lsof missing"
  ok "SKIP blocked-path cases: python3 or lsof missing"
  ok "SKIP blocked-path cases: python3 or lsof missing"
fi

printf '\nguard-live-gate hook mirror: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]

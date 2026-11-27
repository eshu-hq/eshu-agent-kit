#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/codex/skill-nudge.sh - Adapt Codex PreToolUse events to the shared
# skill-nudge.sh hook with KIT_HARNESS=codex (#133).
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
core_hook="${repo_root}/.claude/hooks/skill-nudge.sh"
[ -x "${core_hook}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

export KIT_HARNESS=codex
payload="$(cat)"
[ -n "${payload}" ] || exit 0

normalized="$(CODEX_REPO_ROOT="${repo_root}" printf '%s' "${payload}" | CODEX_REPO_ROOT="${repo_root}" python3 -c '
import json, os, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)

sid = str(d.get("session_id") or d.get("thread_id") or "").strip()
tname = str(d.get("tool_name") or d.get("name") or "")
ti = d.get("tool_input")
if isinstance(ti, str):
    try:
        ti = json.loads(ti)
    except Exception:
        ti = {"input": ti}
if not isinstance(ti, dict):
    ti = {}

out_ti = dict(ti)
fp = out_ti.get("file_path") or out_ti.get("path") or out_ti.get("Path") or out_ti.get("target_file") or ""
if not fp and tname == "apply_patch":
    raw = str(out_ti.get("input") or out_ti.get("patch") or "")
    m = re.search(r"^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$", raw, re.MULTILINE)
    if m:
        fp = m.group(1).strip()
if fp:
    root = os.environ.get("CODEX_REPO_ROOT") or ""
    if root and not os.path.isabs(fp):
        fp = os.path.join(root, fp)
    out_ti["file_path"] = fp
if not out_ti.get("command") and isinstance(out_ti.get("cmd"), str):
    out_ti["command"] = out_ti["cmd"]

mapped_tool = {
    "apply_patch": "Edit",
    "edit_file": "Edit",
    "write_file": "Write",
    "exec": "Bash",
    "exec_command": "Bash",
    "shell": "Bash",
}.get(tname, tname)

print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": mapped_tool,
    "session_id": sid,
    "tool_input": out_ti,
}, separators=(",", ":")))
' 2>/dev/null)"

[ -n "${normalized}" ] || exit 0
printf '%s' "${normalized}" | bash "${core_hook}"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/codex/skill-loaded.sh - Adapt Codex PostToolUse events to the shared
# skill-loaded.sh hook so Codex skill reads record markers and skills-usage
# telemetry with KIT_HARNESS=codex (#133). Never blocks.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
core_hook="${repo_root}/.claude/hooks/skill-loaded.sh"
[ -x "${core_hook}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

export KIT_HARNESS=codex
payload="$(cat)"
[ -n "${payload}" ] || exit 0

normalized="$(printf '%s' "${payload}" | python3 -c '
import json, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)

sid = str(d.get("session_id") or d.get("thread_id") or "").strip()
if not sid:
    raise SystemExit(0)

ti = d.get("tool_input")
if isinstance(ti, str):
    try:
        ti = json.loads(ti)
    except Exception:
        ti = {"raw": ti}
if not isinstance(ti, dict):
    ti = {}

skill = ""
for key in ("skill", "skill_name", "name", "id"):
    v = ti.get(key)
    if isinstance(v, str) and v.strip():
        tname = str(d.get("tool_name") or "").lower()
        if key in ("skill", "skill_name") or tname in ("skill", "read_skill"):
            skill = v.strip().split(":")[-1]
            break

if not skill:
    blob = " ".join(str(v) for v in ti.values() if isinstance(v, str))
    m = re.search(r"skills/(?:[A-Za-z0-9._-]+/)?([A-Za-z0-9._-]+)/SKILL\.md", blob)
    if m:
        skill = m.group(1)

if not skill:
    raise SystemExit(0)

print(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": "Skill",
    "session_id": sid,
    "tool_input": {"skill": skill},
}, separators=(",", ":")))
' 2>/dev/null)"

[ -n "${normalized}" ] || exit 0
printf '%s' "${normalized}" | bash "${core_hook}"
exit 0

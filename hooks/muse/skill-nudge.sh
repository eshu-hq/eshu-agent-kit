#!/usr/bin/env bash
# .muse/hooks/skill-nudge.sh -- Muse Code PreToolUse hook (write_file, edit_file).
#
# Envelope contract, recorded live from `muse exec` (see hooks/README.md,
# Muse Code section): Muse names the edited file
# `tool_input.path` where Claude uses `tool_input.file_path`, and the path
# may be relative to the payload `cwd` (Claude sends absolute paths, so the
# sibling never joins). The translation below fills `file_path` from `path`
# when it is absent, resolving a relative path against `cwd`, then delegates
# to .claude/hooks/skill-nudge.sh so the nudge table lives in exactly one
# place. A relative
# path with no `cwd` is left as-is and fails open downstream.
#
# Fail-open is inherited: without python3 the payload passes through raw and
# the sibling exits 0 on its own guard.
set -uo pipefail

# shellcheck source=hooks/muse/lib/muse-root.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/muse-root.sh"

CLAUDE_HOOK="$(muse_repo_root)/.claude/hooks/skill-nudge.sh"
payload="$(cat)"

translated="$(printf '%s' "${payload}" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print(raw, end="")
    raise SystemExit(0)
ti = d.get("tool_input")
if isinstance(ti, dict) and not ti.get("file_path") and ti.get("path"):
    p = ti["path"]
    if not p.startswith("/") and d.get("cwd"):
        p = d["cwd"].rstrip("/") + "/" + p
    ti["file_path"] = p
print(json.dumps(d))
' 2>/dev/null)" || translated="${payload}"

kit_muse_prepare "skill-nudge.sh" "${payload}"
[ $? -eq 3 ] && exit 0
[ -x "${CLAUDE_HOOK}" ] || exit 0
# Telemetry from the shared sibling attributes to muse through this.
export KIT_HARNESS=muse
printf '%s' "${translated}" | exec "${CLAUDE_HOOK}"

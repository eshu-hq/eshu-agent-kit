#!/usr/bin/env bash
# skills-insights-events.sh — sourced by kit hooks, never run on its own.
#
# Appends one JSONL telemetry event per call for the skills-insights report
# (which skills loaded, which nudge blocks fired, how goal sessions ended).
# Local-only: one per-user log, no prompt content, no file contents, no
# identifiers beyond skill names, outcome labels, and counters.
#
# Fail-open contract: every failure path returns 0 silently. Callers must
# never let telemetry change hook behavior. Honor ESHU_SKILLS_TELEMETRY_OFF=1.
#
# si_event <type> <session_id> [key=value ...]
#   type:         skill-load | nudge-block | goal-done | goal-released |
#                 goal-blocked-watcher | goal-continued
#   session_id:   any session string; sanitized then truncated to 12 chars.
#                 Events join with each other on that form, which matches the
#                 skill-loaded markers for ordinary ids (markers truncate the
#                 raw id; hostile ids sanitize differently, so treat those as
#                 distinct).
#   key=value:    detail fields. Keys must look like identifiers; values may
#                 hold spaces (the known list key `skills` splits on them).
#                 Numbers become JSON numbers. Anything else is dropped
#                 field-wise, never fails. Deliberately no JSON literals at
#                 call sites: plain words survive every quoting layer intact.
# Harness comes from $KIT_HARNESS (muse/codex wrappers export it; default
# claude). Log: $XDG_DATA_HOME/eshu-agent-kit/skills-usage.jsonl, rotated
# at 5 MiB keeping one .1 spare.

SI_MAX_BYTES=5242880

si_event() { # type session_id [key=value ...]
	[ $# -ge 2 ] || return 0
	local ev_type="$1" raw_sid="$2"
	shift 2
	[ "${ESHU_SKILLS_TELEMETRY_OFF:-0}" = "1" ] && return 0
	command -v python3 >/dev/null 2>&1 || return 0
	[ -n "${ev_type}" ] && [ -n "${raw_sid}" ] || return 0
	SI_TYPE="${ev_type}" SI_SID="${raw_sid}" SI_DETAIL="$(printf '%s\n' "$@")" \
	SI_HARNESS="${KIT_HARNESS:-claude}" \
	SI_HOME="${XDG_DATA_HOME:-${HOME:-}/.local/share}" \
	SI_MAX="${SI_MAX_BYTES}" python3 -c '
import datetime
import json
import os
import re

try:
    base = os.environ.get("SI_HOME") or ""
    if not base:
        raise SystemExit(0)
    logdir = os.path.join(base, "eshu-agent-kit")
    os.makedirs(logdir, exist_ok=True)
    log = os.path.join(logdir, "skills-usage.jsonl")
    try:
        if os.path.getsize(log) > int(os.environ.get("SI_MAX") or 5242880):
            try:
                os.replace(log, log + ".1")
            except OSError:
                pass
    except OSError:
        pass
    detail = {}
    for line in (os.environ.get("SI_DETAIL") or "").splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", key):
            continue
        words = value.split()
        if key == "skills":
            items = [re.sub(r"[^A-Za-z0-9._-]", "", w)[:40] for w in words]
            items = [w for w in items if w]
            if items:
                detail[key] = items
        elif len(words) == 1 and re.fullmatch(r"[0-9]+", words[0]):
            detail[key] = int(words[0])
        elif len(words) == 1:
            clean = re.sub(r"[^A-Za-z0-9._-]", "", words[0])[:64]
            if clean:
                detail[key] = clean
    sid = re.sub(r"[^A-Za-z0-9._-]", "-", os.environ.get("SI_SID") or "")[:12]
    if not sid:
        raise SystemExit(0)
    event = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "session": sid,
        "harness": re.sub(r"[^a-z]", "", (os.environ.get("SI_HARNESS") or "claude").lower())[:16] or "claude",
        "type": re.sub(r"[^a-z-]", "", os.environ.get("SI_TYPE") or "")[:32],
        "detail": detail,
    }
    if not event["type"]:
        raise SystemExit(0)
    with open(log, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")
except SystemExit:
    pass
except Exception:
    pass
' 2>/dev/null || true
	return 0
}

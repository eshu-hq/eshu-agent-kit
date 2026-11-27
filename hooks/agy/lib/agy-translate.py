#!/usr/bin/env python3
"""Translate between Antigravity (agy) hook envelopes and the kit siblings.

The kit hooks under .claude/hooks read Claude-shaped snake_case payloads and
block with exit 2 + stderr. agy sends camelCase JSON and reads ONE JSON object
on stdout, so each adapter translates in and out:

  agy-translate.py in  <kind>   agy payload on stdin -> sibling payload on
      stdout; nothing when the event is not applicable (a non-SKILL.md read,
      an unguarded tool, a Stop that is not a plain turn end, ...), which the
      wrapper turns into the neutral empty reply.
  agy-translate.py out <kind> <rc> <stdout-file> <stderr-file>
      sibling result -> the agy verdict JSON object on stdout.

kind: skill-loaded | skill-nudge | guard-live-gate | goal-continue. Never
raises: failure prints nothing (in) or `{}` (out). "allow" is never produced
(agy defines it as an automatic approval).
"""
import json
import os
import re
import sys
import uuid

SKILL_RE = re.compile(r"/skills/([^/]+)/SKILL\.md$")
NUDGE_GUIDE = (
    "agy: load each skill named above by calling read_file on its SKILL.md "
    "(.../skills/<id>/SKILL.md); agy has no Skill tool. Then retry the edit."
)


def unquote(val):
    """agy transcripts quote some args; mirror debrief_extract_agy._unquote."""
    if not isinstance(val, str):
        return ""
    s = val.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        try:
            dec = json.loads(s)
            if isinstance(dec, str):
                return dec
        except ValueError:
            return s[1:-1]
    return s


def read(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def turn_id(cid, active):
    """agy has no turn id: mint one per conversation turn.

    continuationActive false starts a new turn (new id); true reuses the id
    from the state file, so the sibling's per-turn no-progress budget
    accumulates. An id that cannot be persisted returns None (neutral): a
    fresh id on every stop would reset the budget and loop.
    """
    safe = re.sub(r"[^A-Za-z0-9._-]", "-", cid)[:80]
    path = os.path.join(os.environ.get("TMPDIR") or "/tmp", "agy-turn-" + safe)
    tid = read(path).strip() if active else ""
    if tid:
        return tid
    tid = uuid.uuid4().hex[:16]
    tmp = "%s.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(tid)
        os.replace(tmp, path)
    except OSError:
        return None
    return tid


def build_in(kind, d):
    cid = d.get("conversationId")
    if not isinstance(cid, str) or not cid:
        return None
    cwd = d.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        ws = d.get("workspacePaths")
        cwd = ws[0] if isinstance(ws, list) and ws and isinstance(ws[0], str) else ""
    tc = d.get("toolCall") if isinstance(d.get("toolCall"), dict) else {}
    args = tc.get("args") if isinstance(tc.get("args"), dict) else {}
    name = tc.get("name")
    base = {"session_id": cid, "cwd": cwd}
    if kind == "skill-loaded":
        if name not in ("read_file", "view_file") or d.get("error"):
            return None  # a failed read is not a load
        path = unquote(args.get("Path")) or unquote(args.get("AbsolutePath"))
        m = SKILL_RE.search(path.replace("\\", "/"))
        if not m:
            return None
        base.update(hook_event_name="PostToolUse", tool_name="Skill", tool_input={"skill": m.group(1)})
    elif kind == "skill-nudge":
        if name not in ("edit_file", "write_file"):
            return None
        path = unquote(args.get("Path"))
        if not path:
            return None
        path = path if path.startswith("/") or not cwd else cwd.rstrip("/") + "/" + path
        base.update(hook_event_name="PreToolUse", tool_name="Edit", tool_input={"file_path": path})
    elif kind == "guard-live-gate":
        cmd = unquote(args.get("CommandLine"))
        if name != "run_command" or not cmd:
            return None
        base.update(hook_event_name="PreToolUse", tool_name="Bash", tool_input={"command": cmd})
    elif kind == "goal-continue":
        active = d.get("continuationActive")
        # Act only on a plain turn end, and only when loop protection exists
        # (continuationActive arrived in agy 1.5.6; absent => never force).
        if d.get("terminationReason") != "NO_TOOL_CALL" or not isinstance(active, bool):
            return None
        tid = turn_id(cid, active)
        if tid is None:
            return None
        base.update(
            hook_event_name="Stop",
            prompt_id=tid,
            stop_hook_active=active,
            transcript_path=d.get("transcriptPath") or "",
        )
    else:
        return None
    return base


def build_out(kind, rc, out_path, err_path):
    if kind in ("skill-nudge", "guard-live-gate"):
        if rc != 2:
            return {}
        reason = read(err_path).strip()[:3500] or "blocked by an eshu-agent-kit hook"
        if kind == "skill-nudge":
            reason += "\n" + NUDGE_GUIDE
        return {"decision": "deny", "reason": reason}
    if kind == "goal-continue" and rc == 0:
        text = read(out_path).strip()
        for cand in (text, text.splitlines()[-1] if text else ""):
            try:
                v = json.loads(cand)
            except ValueError:
                continue
            if isinstance(v, dict) and v.get("decision") == "block" and isinstance(v.get("reason"), str):
                return {"decision": "continue", "reason": v["reason"]}
            break
    return {}


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode == "in" and len(argv) == 3:
            d = json.loads(sys.stdin.read())
            res = build_in(argv[2], d) if isinstance(d, dict) else None
            if res is not None:
                sys.stdout.write(json.dumps(res))
        elif mode == "out":
            res = build_out(argv[2], int(argv[3]), argv[4], argv[5]) if len(argv) == 6 else {}
            sys.stdout.write(json.dumps(res))
    except Exception:
        if mode == "out":
            sys.stdout.write("{}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

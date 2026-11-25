#!/usr/bin/env python3
"""Transcript miners for the skills debrief.

Reads local Claude transcripts (~/.claude/projects/*/*.jsonl) and Muse
session logs (session.jsonl) and emits per-session COUNT aggregates as JSON.
Never extracts message text, file contents, prompts, or error bodies: tool
names, error flags, timestamps, and structural ids only.

Usage: miners.py [--root PATH]... [--since YYYY-MM-DD] [--cap-bytes N]
  Defaults roots: ~/.claude/projects and $XDG_DATA_HOME/muse/sessions
  (fallback ~/.local/share). Skips files older than --since by mtime and
  stops adding files past --cap-bytes (default 512 MiB), reporting both.

Claude record shapes (observed live, fail open on anything else):
  type=user|assistant with message.role and message.content[]; tool_use
  blocks carry name+id; tool_result blocks carry tool_use_id+is_error.
  Response gap = an assistant timestamp -> the next user timestamp.
Muse record shapes:
  tool_batch.effect.started carries tool_name+call_id; .terminal carries
  call_id plus outcome.kind (completed vs failed). user_intent.accepted
  records count prompts. recorded_at is microseconds. Skill names are NOT
  in effect records, so read_skill loads count without names.
"""
import argparse
import json
import os
import sys
from collections import Counter


def _load_json_lines(path, budget):
    """Yield parsed records, deducting file size from budget[0]."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size > budget[0]:
        return
    budget[0] -= size
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec


def mine_claude(path, budget):
    """Mine one Claude transcript. Content-free: names, flags, times only."""
    sess = os.path.splitext(os.path.basename(path))[0]
    prompts = 0
    assistants = 0
    tools = Counter()
    errors = Counter()
    use_id_to_tool = {}
    last_assistant_ts = None
    gaps = []
    first_ts = None
    last_ts = None
    for rec in _load_json_lines(path, budget):
        if not isinstance(rec.get("timestamp"), str):
            pass
        else:
            if first_ts is None:
                first_ts = rec["timestamp"]
            last_ts = rec["timestamp"]
        if rec.get("type") == "assistant":
            msg = rec.get("message") or {}
            if not isinstance(msg, dict):
                continue
            assistants += 1
            if isinstance(rec.get("timestamp"), str):
                last_assistant_ts = rec["timestamp"]
            for block in msg.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use" and block.get("name"):
                    tools[str(block["name"])] += 1
                    if block.get("id"):
                        use_id_to_tool[str(block["id"])] = str(block["name"])
        elif rec.get("type") == "user":
            msg = rec.get("message") or {}
            if not isinstance(msg, dict):
                continue
            has_text = any(isinstance(b, dict) and b.get("type") == "text"
                           for b in (msg.get("content") or []))
            if has_text:
                prompts += 1
                if last_assistant_ts and isinstance(rec.get("timestamp"), str):
                    gaps.append([last_assistant_ts, rec["timestamp"]])
                    last_assistant_ts = None
            for block in msg.get("content") or []:
                if (isinstance(block, dict) and block.get("type") == "tool_result"
                        and block.get("is_error")):
                    tool = use_id_to_tool.get(str(block.get("tool_use_id") or ""),
                                             "unknown")
                    errors[tool] += 1
    return {"id": sess, "harness": "claude", "prompts": prompts,
            "assistant_messages": assistants, "tools": dict(tools),
            "errors": dict(errors), "response_gaps": gaps,
            "first_ts": first_ts, "last_ts": last_ts}


def mine_muse(path, budget):
    """Mine one Muse session log. Same content-free contract."""
    sess = None
    prompts = 0
    tools = Counter()
    errors = Counter()
    subagents = 0
    started = {}
    first_ts = None
    last_ts = None
    for rec in _load_json_lines(path, budget):
        ts = rec.get("recorded_at")
        if isinstance(ts, int):
            if first_ts is None:
                first_ts = ts
            last_ts = ts
        stream = rec.get("stream") or {}
        if isinstance(stream, dict) and stream.get("id") and sess is None:
            sess = str(stream["id"])
        pt = rec.get("payload_type") or ""
        if pt == "runtime.user_intent.accepted":
            prompts += 1
        elif pt == "subagent.control.spawn_accepted":
            subagents += 1
        elif pt == "tool_batch.effect.started":
            inner = (rec.get("payload") or {}).get("record") or {}
            if isinstance(inner, dict) and inner.get("call_id"):
                started[str(inner["call_id"])] = str(inner.get("tool_name") or "unknown")
        elif pt == "tool_batch.effect.terminal":
            inner = (rec.get("payload") or {}).get("record") or {}
            if not isinstance(inner, dict):
                continue
            tool = started.get(str(inner.get("call_id") or ""), "unknown")
            tools[tool] += 1
            outcome = inner.get("outcome") or {}
            kind = outcome.get("kind") if isinstance(outcome, dict) else outcome
            if kind != "completed":
                errors[tool] += 1
    if sess is None:
        sess = os.path.basename(os.path.dirname(path)) or path
    return {"id": str(sess), "harness": "muse", "prompts": prompts,
            "assistant_messages": None, "tools": dict(tools),
            "errors": dict(errors), "response_gaps": [],
            "subagents": subagents, "first_ts": first_ts, "last_ts": last_ts}


def _mtime_ok(path, since):
    if not since:
        return True
    try:
        import datetime
        return datetime.datetime.fromtimestamp(
            os.path.getmtime(path)).isoformat()[:10] >= since
    except (OSError, ValueError):
        return False


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--since", default="")
    ap.add_argument("--cap-bytes", type=int, default=512 * 1024 * 1024)
    args = ap.parse_args(argv)
    roots = args.root or [
        os.path.expanduser("~/.claude/projects"),
        os.path.join(os.environ.get("XDG_DATA_HOME",
                                    os.path.expanduser("~/.local/share")),
                     "muse", "sessions"),
    ]
    budget = [args.cap_bytes]
    sessions = []
    skipped_old = 0
    capped = False
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in sorted(filenames):
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, name)
                if not _mtime_ok(path, args.since):
                    skipped_old += 1
                    continue
                try:
                    if name == "session.jsonl" or "muse" in root:
                        probe = None
                        with open(path, encoding="utf-8",
                                  errors="replace") as fh:
                            for _ in range(5):
                                line = fh.readline()
                                if '"payload_type"' in line:
                                    probe = "muse"
                                    break
                                if '"sessionId"' in line:
                                    probe = "claude"
                                    break
                        miner = mine_muse if probe != "claude" else mine_claude
                    else:
                        miner = mine_claude
                except OSError:
                    continue
                if budget[0] <= 0:
                    capped = True
                    break
                rec = miner(path, budget)
                rec["path"] = path
                sessions.append(rec)
            if capped:
                break
    sys.stdout.write(json.dumps({"sessions": sessions,
                                 "skipped_old": skipped_old,
                                 "byte_capped": capped}, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1:])

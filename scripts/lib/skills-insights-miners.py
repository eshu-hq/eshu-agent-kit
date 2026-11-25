#!/usr/bin/env python3
"""Transcript and git-history collectors for the skills debrief.

Reads local Claude transcripts (~/.claude/projects/*/*.jsonl) and Muse
session logs (session.jsonl) and emits per-session COUNT aggregates as JSON.
Never extracts message text, file contents, prompts, or error bodies: tool
names, error flags, timestamps, and structural ids only.

Usage: miners.py [--root PATH]... [--since YYYY-MM-DD] [--cap-bytes N]
  [--project SUB]
  Defaults roots: ~/.claude/projects and $XDG_DATA_HOME/muse/sessions
  (fallback ~/.local/share). Skips files older than --since by mtime and
  stops adding files past --cap-bytes (default 512 MiB), reporting both.
  --project keeps only sessions whose project contains SUB: the Claude
  transcripts dir slug, or the Muse workspace_root. Muse files with no
  workspace_root in the peek window stay in (fail-open).

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
import re
import sys
from collections import Counter


def _load_json_lines(path, budget):
    """Yield parsed records. Callers gate on budget[0] first; files that
    do not fit are skipped before this runs, so skipped files never
    produce phantom zero-sessions."""
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
    skill_loads = []
    subagents = 0
    subagent_roles = Counter()
    subagent_models = Counter()
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
                    if block.get("name") == "Agent":
                        subagents += 1
                        inp = block.get("input") or {}
                        if isinstance(inp, dict):
                            if isinstance(inp.get("subagent_type"), str) and inp["subagent_type"]:
                                subagent_roles[inp["subagent_type"][:80]] += 1
                            if isinstance(inp.get("model"), str) and inp["model"]:
                                subagent_models[inp["model"][:60]] += 1
                    if block.get("name") == "Skill":
                        raw = ((block.get("input") or {}).get("skill", "")
                               if isinstance(block.get("input"), dict) else "")
                        bare = str(raw).strip().split(":")[-1]
                        bare = re.sub(r"[^A-Za-z0-9._-]", "", bare)[:40]
                        if bare:
                            skill_loads.append(bare)
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
            "skill_loads": sorted(set(skill_loads)),
            "subagents": subagents, "subagent_roles": dict(subagent_roles),
            "subagent_models": dict(subagent_models),
            "project": os.path.basename(os.path.dirname(path)),
            "first_ts": first_ts, "last_ts": last_ts}


def mine_muse(path, budget):
    """Mine one Muse session log. Same content-free contract."""
    sess = None
    prompts = 0
    tools = Counter()
    errors = Counter()
    subagents = 0
    subagent_roles = Counter()
    session_models = Counter()
    max_depth = 0
    started = {}
    project = ""
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
            inner = (rec.get("payload") or {}).get("record") or {}
            if isinstance(inner, dict):
                if isinstance(inner.get("role"), str) and inner["role"]:
                    subagent_roles[inner["role"][:80]] += 1
                try:
                    depth = int(inner.get("depth", 0) or 0)
                except (TypeError, ValueError):
                    depth = 0
                if depth > max_depth:
                    max_depth = depth
        elif pt == "run.model.configured":
            # Session-level only: command ids live in a different space from
            # spawn command ids, so these models cannot be attributed to a
            # specific child. Never merge into subagent_models.
            inner = (rec.get("payload") or {}).get("record") or {}
            if isinstance(inner, dict) and isinstance(inner.get("model_id"), str):
                if inner["model_id"]:
                    session_models[inner["model_id"][:60]] += 1
        elif pt == "runtime.session.metadata" and not project:
            inner = (rec.get("payload") or {}).get("record") or {}
            if isinstance(inner, dict) and isinstance(inner.get("workspace_root"), str):
                project = inner["workspace_root"][:240]
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
    parent = None
    parts = path.split(os.sep)
    if len(parts) >= 4 and parts[-2] != "sessions" and parts[-3] == "subagent":
        parent = parts[-4] or None
    return {"id": str(sess), "harness": "muse", "prompts": prompts,
            "assistant_messages": None, "tools": dict(tools),
            "errors": dict(errors), "response_gaps": [],
            "subagents": subagents, "subagent_roles": dict(subagent_roles),
            "session_models": dict(session_models), "max_depth": max_depth,
            "parent_session": parent, "project": project,
            "first_ts": first_ts, "last_ts": last_ts}


def _mtime_ok(path, since):
    if not since:
        return True
    try:
        import datetime
        return datetime.datetime.fromtimestamp(
            os.path.getmtime(path)).isoformat()[:10] >= since
    except (OSError, ValueError):
        return False


def _project_ok(path, want):
    """Substring match on the Claude dir slug or Muse workspace_root.

    Muse files with no workspace_root in the peek window stay in
    (fail-open): absence of signal is not evidence of another project.
    """
    if not want:
        return True
    if os.path.basename(path) != "session.jsonl":
        return want in os.path.basename(os.path.dirname(path))
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for _ in range(40):
                line = fh.readline()
                if not line:
                    break
                m = re.search(r'"workspace_root"\s*:\s*"((?:[^"\\]|\\.)*)"',
                              line)
                if m:
                    try:
                        return want in json.loads('"' + m.group(1) + '"')
                    except ValueError:
                        continue
    except OSError:
        return True
    return True


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--since", default="")
    ap.add_argument("--cap-bytes", type=int, default=512 * 1024 * 1024)
    ap.add_argument("--project", default="")
    ap.add_argument("--git", action="append", default=[])
    args = ap.parse_args(argv)
    if args.git:
        repos = []
        for repo in args.git:
            stats = collect_git_stats(repo.strip(), args.since)
            repos.append(stats if stats else {"path": repo.strip(),
                                              "unreadable": True})
        sys.stdout.write(json.dumps({"repos": repos}, sort_keys=True))
        return
    roots = args.root or [
        os.path.expanduser("~/.claude/projects"),
        os.path.join(os.environ.get("XDG_DATA_HOME",
                                    os.path.expanduser("~/.local/share")),
                     "muse", "sessions"),
    ]
    budget = [args.cap_bytes]
    want = args.project.strip()
    sessions = []
    skipped_old = 0
    capped = False
    candidates = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, name)
                if not _mtime_ok(path, args.since):
                    skipped_old += 1
                    continue
                if not _project_ok(path, want):
                    continue
                try:
                    candidates.append((os.path.getmtime(path), path))
                except OSError:
                    continue
    candidates.sort(key=lambda p: p[0], reverse=True)
    for _, path in candidates:
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        if size > budget[0]:
            capped = True
            continue
        budget[0] -= size
        try:
            if os.path.basename(path) == "session.jsonl":
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
        rec = miner(path, budget)
        rec["path"] = path
        sessions.append(rec)
    sys.stdout.write(json.dumps({"sessions": sessions,
                                 "skipped_old": skipped_old,
                                 "byte_capped": capped}, sort_keys=True))


def collect_git_stats(path, since):
    """Deterministic git history rollup; {} when not a repo or git fails."""
    import datetime
    import subprocess
    if not os.path.isdir(os.path.join(path, ".git")):
        return {}
    window = since or ""
    if not window:
        try:
            window = (datetime.date.today() -
                      datetime.timedelta(days=90)).isoformat()
        except ValueError:
            window = ""
    cmd = ["git", "-C", path, "log", "--pretty=%H %P %s", "--numstat"]
    if window:
        cmd += ["--since=" + window]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, ValueError):
        return {}
    if out.returncode != 0:
        return {}
    commits = merges = reverts = files = added = deleted = 0
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if (len(parts) == 3 and parts[0].strip().isdigit()
                and parts[1].strip().isdigit()):
            added += int(parts[0].strip())
            deleted += int(parts[1].strip())
            files += 1
        elif line and not line[0].isspace():
            m = re.match(r"^[0-9a-f]{40}((?: [0-9a-f]{40})*) (.*)$", line)
            if not m:
                continue
            commits += 1
            if len(m.group(1).split()) >= 2:
                merges += 1
            if m.group(2).lower().startswith("revert"):
                reverts += 1
    return {"path": path, "commits": commits, "merges": merges,
            "reverts": reverts, "files": files,
            "added": added, "deleted": deleted}


if __name__ == "__main__":
    main(sys.argv[1:])

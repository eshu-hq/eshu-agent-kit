#!/usr/bin/env python3
"""Antigravity (agy) transcript collector for the skills debrief.

Reads local Antigravity transcripts
(~/.gemini/antigravity{-cli,,-ide}/brain/<id>/.system_generated/logs/transcript.jsonl)
plus structural columns from sibling conversation_summaries.db and emits the
same content-free per-session COUNT aggregate dict as Claude and Muse miners.

Never extracts message text, thoughts, prompts, file contents, error bodies,
or summary titles/previews: tool names, error flags, timestamps, model ids,
skill identifiers, and structural ids only.
"""
import json
import os
import re
import sqlite3
import urllib.parse
from collections import Counter


def default_roots():
    """Known Antigravity brain directories (CLI, Desktop/2.0, IDE)."""
    return [
        os.path.expanduser("~/.gemini/antigravity-cli/brain"),
        os.path.expanduser("~/.gemini/antigravity/brain"),
        os.path.expanduser("~/.gemini/antigravity-ide/brain"),
    ]


def is_agy_root(root):
    """True when root is an Antigravity brain directory."""
    norm = os.path.normpath(root)
    if os.path.basename(norm) == "brain":
        return True
    return os.path.isfile(os.path.join(os.path.dirname(norm),
                                       "conversation_summaries.db"))


def is_skipped_path(path, root=""):
    """Skip untruncated duplicates, chunk files, and non-transcript scratch files."""
    base = os.path.basename(path)
    if base == "transcript_full.jsonl":
        return True
    parts = path.replace("\\", "/").split("/")
    for i in range(len(parts) - 2):
        if parts[i] == ".system_generated" and parts[i + 1] == "logs" and parts[i + 2] == "chunks":
            return True
    if root and is_agy_root(root):
        return parts[-3:] != [".system_generated", "logs", "transcript.jsonl"]
    return False


def is_agy_transcript(path):
    """True when path is an Antigravity transcript.jsonl (probed fail-open)."""
    if os.path.basename(path) != "transcript.jsonl":
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for _ in range(5):
                line = fh.readline()
                if not line:
                    break
                if ('"step_index"' in line or '"PLANNER_RESPONSE"' in line
                        or '"USER_INPUT"' in line or '"SYSTEM_MESSAGE"' in line):
                    return True
                if '"sessionId"' in line:
                    return False
    except OSError:
        return False
    return True


def conversation_id(path):
    """Extract conversation id from <root>/<id>/.system_generated/logs/transcript.jsonl."""
    parts = os.path.normpath(path).split(os.sep)
    if ".system_generated" in parts:
        idx = parts.index(".system_generated")
        if idx >= 1 and parts[idx - 1]:
            return parts[idx - 1]
    parent = os.path.basename(os.path.dirname(path))
    if parent and parent != "logs":
        return parent
    return os.path.splitext(os.path.basename(path))[0]


def _db_path_for(path):
    """Locate sibling conversation_summaries.db one level above brain/."""
    parts = os.path.normpath(path).split(os.sep)
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "brain" and i >= 1:
            base = os.sep.join(parts[:i]) or os.sep
            return os.path.join(base, "conversation_summaries.db")
    return ""


def _parse_workspace_uris(raw):
    """Decode JSON workspace_uris array into local filesystem paths."""
    if not isinstance(raw, str) or not raw.strip():
        return []
    try:
        items = json.loads(raw)
    except ValueError:
        return []
    if not isinstance(items, list):
        return []
    paths = []
    for item in items:
        if not isinstance(item, str) or not item:
            continue
        p = item
        if p.startswith("file://"):
            p = urllib.parse.unquote(p[7:])
        if p:
            paths.append(p[:240])
    return paths


def load_meta(path, cache):
    """Return structural summary metadata for one agy conversation (fail-open).

    Reads only conversation_id, workspace_uris, parent_conversation_id,
    nesting_depth, and agent_name — never title, preview, or FTS body text.
    """
    db = _db_path_for(path)
    if not db or not os.path.isfile(db):
        return {}
    if db not in cache:
        table = {}
        try:
            uri = "file:%s?mode=ro" % urllib.parse.quote(db)
            con = sqlite3.connect(uri, uri=True, timeout=1.0)
            try:
                cur = con.execute(
                    "SELECT conversation_id, workspace_uris, "
                    "parent_conversation_id, nesting_depth, agent_name "
                    "FROM conversation_summaries"
                )
                for cid, w_uris, parent_id, depth, agent_name in cur:
                    if not isinstance(cid, str) or not cid:
                        continue
                    workspaces = _parse_workspace_uris(w_uris)
                    try:
                        d_int = int(depth or 0)
                    except (TypeError, ValueError):
                        d_int = 0
                    table[cid] = {
                        "project": workspaces[0] if workspaces else "",
                        "workspaces": workspaces,
                        "parent_session": (str(parent_id)
                                           if isinstance(parent_id, str) and parent_id
                                           else None),
                        "nesting_depth": d_int,
                        "agent_name": (str(agent_name)[:80]
                                       if isinstance(agent_name, str) and agent_name
                                       else ""),
                    }
            finally:
                con.close()
        except Exception:
            table = {}
        cache[db] = table
    return cache[db].get(conversation_id(path), {})


def project_ok(path, want, cache):
    """Substring match against agy workspace_uris; fail-open when absent."""
    if not want:
        return True
    meta = load_meta(path, cache)
    workspaces = meta.get("workspaces") or []
    if not workspaces:
        return True
    return any(want in w for w in workspaces)


def _unquote(val):
    """Decode agy's JSON-quoted string args (e.g. '"/path/to/file"')."""
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


def _skill_from_path(raw_path):
    """Extract bare skill id from a .../skills/.../<name>/SKILL.md read."""
    p = _unquote(raw_path).replace("\\", "/").rstrip("/")
    if not p:
        return ""
    parts = [seg for seg in p.split("/") if seg]
    if len(parts) < 3 or parts[-1] != "SKILL.md":
        return ""
    if "skills" not in parts[:-2]:
        return ""
    bare = parts[-2].strip().split(":")[-1]
    return re.sub(r"[^A-Za-z0-9._-]", "", bare)[:40]


def _swarm_add_count(args):
    """Count workers spawned by one swarm(action=add) call."""
    raw_tasks = args.get("tasks")
    if isinstance(raw_tasks, list):
        return max(len(raw_tasks), 1)
    if isinstance(raw_tasks, str) and raw_tasks.strip():
        try:
            dec = json.loads(raw_tasks)
            if isinstance(dec, list):
                return max(len(dec), 1)
        except ValueError:
            pass
    raw_n = args.get("n")
    try:
        n = int(raw_n)
        if n > 0:
            return n
    except (TypeError, ValueError):
        pass
    return 1


def mine_agy(path, budget, load_lines, meta_cache=None):
    """Mine one Antigravity transcript. Content-free: names, flags, times only."""
    sess = conversation_id(path)
    meta = load_meta(path, meta_cache) if meta_cache is not None else {}
    prompts = 0
    assistants = 0
    tools = Counter()
    errors = Counter()
    skill_loads = []
    subagents = 0
    subagent_roles = Counter()
    subagent_models = Counter()
    session_models = Counter()
    last_model = None
    nesting_depth = int(meta.get("nesting_depth") or 0)
    max_depth = nesting_depth
    pending_tools = []
    pending_idx = 0
    last_assistant_ts = None
    gaps = []
    first_ts = None
    last_ts = None

    for rec in load_lines(path, budget):
        ts = rec.get("created_at")
        if isinstance(ts, str) and ts:
            if first_ts is None:
                first_ts = ts
            last_ts = ts
        rtype = rec.get("type") or ""
        if rtype == "PLANNER_RESPONSE":
            assistants += 1
            if isinstance(ts, str) and ts:
                last_assistant_ts = ts
            model = rec.get("model")
            if isinstance(model, str) and model:
                m_clean = model[:60]
                if m_clean != last_model:
                    session_models[m_clean] += 1
                    last_model = m_clean
            pending_tools = []
            pending_idx = 0
            for tc in rec.get("tool_calls") or []:
                if not isinstance(tc, dict) or not tc.get("name"):
                    continue
                tname = str(tc["name"])
                tools[tname] += 1
                pending_tools.append(tname)
                args = tc.get("args")
                if not isinstance(args, dict):
                    continue
                if tname in ("read_file", "view_file"):
                    rawp = args.get("Path") or args.get("AbsolutePath") or ""
                    sk = _skill_from_path(rawp)
                    if sk:
                        skill_loads.append(sk)
                elif tname == "invoke_subagent":
                    subagents += 1
                    if nesting_depth + 1 > max_depth:
                        max_depth = nesting_depth + 1
                    role = _unquote(args.get("TypeName")) or _unquote(args.get("Role"))
                    if role:
                        subagent_roles[role[:80]] += 1
                    sub_model = _unquote(args.get("Model"))
                    if sub_model:
                        subagent_models[sub_model[:60]] += 1
                elif tname == "swarm" and _unquote(args.get("action")) == "add":
                    cnt = _swarm_add_count(args)
                    subagents += cnt
                    if nesting_depth + 1 > max_depth:
                        max_depth = nesting_depth + 1
                    wname = _unquote(args.get("name"))
                    if wname:
                        subagent_roles[wname[:80]] += cnt
                    wmodel = _unquote(args.get("model"))
                    if wmodel:
                        subagent_models[wmodel[:60]] += cnt
        elif rtype == "GENERIC":
            tname = (pending_tools[pending_idx]
                     if pending_idx < len(pending_tools) else "unknown")
            pending_idx += 1
            if rec.get("error") or rec.get("status") in ("ERROR", "INVALID"):
                errors[tname] += 1
        elif rtype == "USER_INPUT":
            prompts += 1
            pending_tools = []
            pending_idx = 0
            if last_assistant_ts and isinstance(ts, str) and ts:
                gaps.append([last_assistant_ts, ts])
                last_assistant_ts = None
        elif rtype == "CHECKPOINT":
            pending_tools = []
            pending_idx = 0

    return {
        "id": sess,
        "harness": "agy",
        "prompts": prompts,
        "assistant_messages": assistants,
        "tools": dict(tools),
        "errors": dict(errors),
        "response_gaps": gaps,
        "skill_loads": sorted(set(skill_loads)),
        "subagents": subagents,
        "subagent_roles": dict(subagent_roles),
        "subagent_models": dict(subagent_models),
        "session_models": dict(session_models),
        "max_depth": max_depth,
        "parent_session": meta.get("parent_session"),
        "project": meta.get("project") or "",
        "first_ts": first_ts,
        "last_ts": last_ts,
    }

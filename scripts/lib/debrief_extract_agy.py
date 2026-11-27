#!/usr/bin/env python3
"""Antigravity (agy) transcript extractor (Stage 1 rich meta + Stage 2 digest)."""
import json
import os
import re
import sqlite3
import urllib.parse
from collections import Counter, defaultdict

from debrief_common import (
    META_SCHEMA_VERSION,
    canon_skill,
    categorize_error,
    classify_interjection,
    epoch_to_iso,
    epoch_to_utc_hour,
    lang_from_path,
    load_json_lines,
    safe_int,
    truncate_text,
    ts_to_epoch,
)


def default_roots():
    return [
        os.path.expanduser("~/.gemini/antigravity-cli/brain"),
        os.path.expanduser("~/.gemini/antigravity/brain"),
        os.path.expanduser("~/.gemini/antigravity-ide/brain"),
    ]


def conversation_id(path):
    parts = os.path.normpath(path).split(os.sep)
    if ".system_generated" in parts:
        idx = parts.index(".system_generated")
        if idx >= 1 and parts[idx - 1]:
            return parts[idx - 1]
    parent = os.path.basename(os.path.dirname(path))
    return parent if parent and parent != "logs" else os.path.splitext(os.path.basename(path))[0]


def discover(roots, since_epoch):
    """Discover agy transcript.jsonl files, deduplicating CLI vs app roots by newest mtime."""
    by_id = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, _, fns in os.walk(root):
            if "transcript.jsonl" not in fns:
                continue
            parts = dp.replace("\\", "/").split("/")
            if len(parts) < 2 or parts[-2:] != [".system_generated", "logs"]:
                continue
            p = os.path.join(dp, "transcript.jsonl")
            try:
                mt = os.path.getmtime(p)
            except OSError:
                continue
            if since_epoch and mt < since_epoch:
                continue
            cid = conversation_id(p)
            prev = by_id.get(cid)
            if prev is None or mt > prev[1]:
                by_id[cid] = (p, mt)
    out = list(by_id.values())
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def _db_path_for(path):
    parts = os.path.abspath(path).split(os.sep)
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "brain" and i >= 1:
            base = os.sep.join(parts[:i]) or os.sep
            return os.path.join(base, "conversation_summaries.db")
    return ""


def _parse_workspaces(raw):
    if not isinstance(raw, str) or not raw.strip():
        return []
    try:
        items = json.loads(raw)
    except ValueError:
        return []
    out = []
    if isinstance(items, list):
        for item in items:
            if isinstance(item, str) and item:
                p = urllib.parse.unquote(item[7:]) if item.startswith("file://") else item
                if p:
                    out.append(p[:240])
    return out


def load_summary_meta(path, db_cache):
    db = _db_path_for(path)
    if not db or not os.path.isfile(db):
        return {}
    if db not in db_cache:
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
                    ws = _parse_workspaces(w_uris)
                    try:
                        d_int = int(depth or 0)
                    except (TypeError, ValueError):
                        d_int = 0
                    table[cid] = {
                        "project": ws[0] if ws else "",
                        "workspaces": ws,
                        "parent_session": str(parent_id) if isinstance(parent_id, str) and parent_id else None,
                        "nesting_depth": d_int,
                        "agent_name": str(agent_name)[:80] if isinstance(agent_name, str) and agent_name else "",
                    }
            finally:
                con.close()
        except Exception:
            table = {}
        db_cache[db] = table
    return db_cache[db].get(conversation_id(path), {})


def _unquote(val):
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
    p = _unquote(raw_path).replace("\\", "/").rstrip("/")
    parts = [seg for seg in p.split("/") if seg]
    if len(parts) < 3 or parts[-1] != "SKILL.md" or "skills" not in parts[:-2]:
        return ""
    return canon_skill(parts[-2])


def extract_session(path, mtime=0.0, db_cache=None):
    """Return (meta_dict, digest_dict) for one agy transcript.jsonl."""
    cid = conversation_id(path)
    smeta = load_summary_meta(path, db_cache if db_cache is not None else {})
    prompts = 0
    assistants = 0
    tools = Counter()
    errors = Counter()
    error_cats = Counter()
    languages = Counter()
    skill_loads = set()
    skill_first_turn = {}
    subagents = 0
    subagent_roles = Counter()
    session_models = Counter()
    msg_hours = Counter()
    gaps = []
    pending = []
    pending_idx = 0
    first_ep = None
    last_ep = None
    last_assistant_ep = None
    last_model = None
    git_commits = 0
    git_pushes = 0
    tokens_in = 0
    tokens_out = 0
    tokens_cache_read = 0
    post_in = defaultdict(float)
    post_out = defaultdict(float)
    post_cr = defaultdict(float)
    post_err = defaultdict(float)
    nesting = int(smeta.get("nesting_depth") or 0)
    max_depth = nesting

    user_prompts = []
    interjection_reasons = Counter()
    assistant_tail = []
    subagent_runs = []
    error_samples = []
    touched_files = []
    touched_seen = set()

    for rec in load_json_lines(path):
        ep = ts_to_epoch(rec.get("created_at"))
        if ep is not None:
            if first_ep is None or ep < first_ep:
                first_ep = ep
            if last_ep is None or ep > last_ep:
                last_ep = ep
        rtype = rec.get("type") or ""
        if rtype == "PLANNER_RESPONSE":
            assistants += 1
            if ep is not None:
                last_assistant_ep = ep
            inp_tok = max(0, safe_int(rec.get("input_tokens"), 0))
            out_tok = max(0, safe_int(rec.get("output_tokens"), 0))
            cr_tok = max(0, safe_int(rec.get("cache_read_tokens"), 0))
            tokens_in += inp_tok + cr_tok
            tokens_out += out_tok
            tokens_cache_read += cr_tok
            model = rec.get("model")
            if isinstance(model, str) and model:
                mc = model[:60]
                if mc != last_model:
                    session_models[mc] += 1
                    last_model = mc
            resp_txt = truncate_text(rec.get("response") or rec.get("text") or "", 280)
            if resp_txt:
                assistant_tail.append(resp_txt)
                if len(assistant_tail) > 3:
                    assistant_tail.pop(0)
            pending = []
            pending_idx = 0
            tcalls = rec.get("tool_calls")
            for tc in (tcalls if isinstance(tcalls, list) else []):
                if not isinstance(tc, dict) or not tc.get("name"):
                    continue
                tname = str(tc["name"])
                tools[tname] += 1
                pending.append(tname)
                args = tc.get("args") if isinstance(tc.get("args"), dict) else {}
                if tname in ("read_file", "view_file", "edit_file", "write_file"):
                    fp = _unquote(args.get("Path") or args.get("AbsolutePath") or "")
                    if fp:
                        sk = _skill_from_path(fp)
                        if sk:
                            skill_loads.add(sk)
                            skill_first_turn.setdefault(sk, assistants)
                        lang = lang_from_path(fp)
                        if lang:
                            languages[lang] += 1
                        if fp not in touched_seen and len(touched_files) < 15:
                            touched_seen.add(fp)
                            touched_files.append(fp[-120:])
                elif tname == "run_command":
                    cmd = _unquote(args.get("CommandLine") or "")
                    if re.search(r"\bgit\s+commit\b", cmd):
                        git_commits += 1
                    if re.search(r"\bgit\s+push\b", cmd):
                        git_pushes += 1
                elif tname == "invoke_subagent":
                    subagents += 1
                    max_depth = max(max_depth, nesting + 1)
                    role = _unquote(args.get("TypeName")) or _unquote(args.get("Role")) or "subagent"
                    subagent_roles[role[:80]] += 1
                    if len(subagent_runs) < 10:
                        subagent_runs.append({
                            "role": role[:60],
                            "objective": truncate_text(_unquote(args.get("Prompt") or ""), 160),
                        })
            if skill_loads and ((inp_tok + cr_tok) or out_tok):
                n_sk = float(len(skill_loads))
                for sk in skill_loads:
                    post_in[sk] += (inp_tok + cr_tok) / n_sk
                    post_out[sk] += out_tok / n_sk
                    post_cr[sk] += cr_tok / n_sk
        elif rtype == "GENERIC":
            tname = pending[pending_idx] if pending_idx < len(pending) else "unknown"
            pending_idx += 1
            if rec.get("error") or rec.get("status") in ("ERROR", "INVALID"):
                errors[tname] += 1
                if skill_loads:
                    share = 1.0 / float(len(skill_loads))
                    for sk in skill_loads:
                        post_err[sk] += share
                err_txt = str(rec.get("error") or rec.get("output") or rec.get("status") or "")
                error_cats[categorize_error(tname, err_txt)] += 1
                if len(error_samples) < 8:
                    error_samples.append(f"{tname}: {truncate_text(err_txt, 140)}")
        elif rtype == "USER_INPUT":
            prompts += 1
            pending = []
            pending_idx = 0
            hr = epoch_to_utc_hour(ep)
            if hr is not None:
                msg_hours[str(hr)] += 1
            if last_assistant_ep is not None and ep is not None and ep > last_assistant_ep:
                gaps.append(round(ep - last_assistant_ep, 2))
                last_assistant_ep = None
            raw_u = rec.get("text") or rec.get("user_response") or rec.get("content") or ""
            txt = truncate_text(raw_u, 260)
            if prompts >= 2 and txt:
                interjection_reasons[classify_interjection(txt)] += 1
            if txt and len(user_prompts) < 8:
                user_prompts.append(txt)
        elif rtype == "CHECKPOINT":
            pending = []
            pending_idx = 0

    dur_min = round((last_ep - first_ep) / 60.0, 2) if (first_ep and last_ep and last_ep >= first_ep) else 0.0
    turns_after_skill_load = {
        sk: max(1, assistants - first_t + 1)
        for sk, first_t in sorted(skill_first_turn.items())
    }
    meta = {
        "meta_version": META_SCHEMA_VERSION,
        "id": cid,
        "harness": "agy",
        "source_path": path,
        "source_mtime": mtime,
        "project": smeta.get("project") or "",
        "workspaces": smeta.get("workspaces") or [],
        "branch": "",
        "commit": "",
        "first_ts": epoch_to_iso(first_ep),
        "last_ts": epoch_to_iso(last_ep),
        "first_epoch": first_ep,
        "last_epoch": last_ep,
        "duration_minutes": dur_min,
        "prompts": prompts,
        "assistant_messages": assistants,
        "tools": dict(tools),
        "tool_calls": sum(tools.values()),
        "errors": dict(errors),
        "error_categories": dict(error_cats),
        "languages": dict(languages),
        "skill_loads": sorted(skill_loads),
        "subagents": subagents,
        "subagent_roles": dict(subagent_roles),
        "session_models": dict(session_models),
        "max_depth": max_depth,
        "parent_session": smeta.get("parent_session"),
        "child_sessions": [],
        "response_gaps": gaps,
        "message_hours": dict(msg_hours),
        "hook_blocks": {},
        "git_commits": git_commits,
        "git_pushes": git_pushes,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "tokens_cache_read": tokens_cache_read,
        "tokens_cache_write": 0,
        "turns_after_skill_load": turns_after_skill_load,
        "post_load_attribution": {
            sk: {
                "tokens_in": round(post_in[sk], 2),
                "tokens_out": round(post_out[sk], 2),
                "tokens_cache_read": round(post_cr[sk], 2),
                "tokens_cache_write": 0.0,
                "errors": round(post_err[sk], 2),
            }
            for sk in sorted(skill_loads)
        } if skill_loads else {},
        "interjection_reasons": dict(interjection_reasons),
    }
    digest = {
        "session_id": cid,
        "harness": "agy",
        "source_mtime": mtime,
        "project": meta["project"],
        "agent_name": smeta.get("agent_name") or "",
        "duration_minutes": dur_min,
        "prompts_count": prompts,
        "tool_calls": meta["tool_calls"],
        "top_tools": dict(tools.most_common(6)),
        "languages": dict(languages.most_common(6)),
        "skill_loads": meta["skill_loads"],
        "error_categories": dict(error_cats),
        "user_prompts": user_prompts[:6],
        "subagent_runs": subagent_runs[:8],
        "error_samples": error_samples[:8],
        "touched_files": touched_files[:12],
        "final_assistant_notes": assistant_tail[-2:],
    }
    return meta, digest

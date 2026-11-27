#!/usr/bin/env python3
"""OpenCode (v1 + v2 SQLite) session extractor (Stage 1 rich meta + Stage 2 digest)."""
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
    safe_int,
    truncate_text,
    ts_to_epoch,
)

_SKILL_PATH_RE = re.compile(r"([A-Za-z0-9._/-]*skills/[A-Za-z0-9._/-]+/SKILL\.md)")


def default_roots():
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return [os.path.join(base, "opencode")]


def _open_ro(db_path):
    uri = "file:%s?mode=ro" % urllib.parse.quote(os.path.abspath(db_path))
    return sqlite3.connect(uri, uri=True, timeout=2.0)


def _db_files(roots):
    out = []
    seen = set()
    for root in roots:
        if os.path.isfile(root) and root.endswith(".db"):
            ap = os.path.abspath(root)
            if ap not in seen:
                seen.add(ap)
                out.append(ap)
        elif os.path.isdir(root):
            cand = os.path.join(root, "opencode.db")
            if os.path.isfile(cand):
                ap = os.path.abspath(cand)
                if ap not in seen:
                    seen.add(ap)
                    out.append(ap)
    return out


def session_id_from_ref(ref):
    if "#" in ref:
        tag = ref.rsplit("#", 1)[1]
        if ":" in tag:
            return tag.split(":", 1)[1]
        return tag
    return os.path.splitext(os.path.basename(ref))[0]


def _parse_ref(ref):
    db_path, tag = ref.rsplit("#", 1)
    schema, sid = tag.split(":", 1)
    return db_path, schema, sid


def _tables(con):
    return {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def discover(roots, since_epoch):
    """Discover OpenCode sessions as virtual refs '<db>#v2:<sid>' or '<db>#v1:<sid>'."""
    since_ms = int(since_epoch * 1000) if since_epoch else 0
    by_sid = {}
    for db_path in _db_files(roots):
        try:
            con = _open_ro(db_path)
        except sqlite3.Error:
            continue
        try:
            tbls = _tables(con)
            for schema, tbl in (("v2", "session_v2"), ("v1", "session")):
                if tbl not in tbls:
                    continue
                q = f"SELECT id, time_updated, time_created FROM {tbl}"
                params = ()
                if since_ms:
                    q += " WHERE COALESCE(time_updated, time_created, 0) >= ?"
                    params = (since_ms,)
                for sid, t_upd, t_crt in con.execute(q, params):
                    if not isinstance(sid, str) or not sid:
                        continue
                    mt = (ts_to_epoch(t_upd) or ts_to_epoch(t_crt) or 0.0)
                    prev = by_sid.get(sid)
                    # Prefer v2 over v1, otherwise newest mtime.
                    if prev is None or (schema == "v2" and prev[2] != "v2") or (schema == prev[2] and mt > prev[1]):
                        by_sid[sid] = (f"{db_path}#{schema}:{sid}", mt, schema)
        except sqlite3.Error:
            continue
        finally:
            con.close()
    out = [(ref, mt) for ref, mt, _ in by_sid.values()]
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def _skill_from_path(raw_path):
    parts = [seg for seg in str(raw_path or "").replace("\\", "/").split("/") if seg]
    if len(parts) < 3 or parts[-1] != "SKILL.md" or "skills" not in parts[:-2]:
        return ""
    return canon_skill(parts[-2])


def _extract_model_name(raw_model):
    if isinstance(raw_model, dict):
        return str(raw_model.get("id") or raw_model.get("modelID") or "")[:60]
    if isinstance(raw_model, str) and raw_model.strip():
        s = raw_model.strip()
        if s.startswith("{"):
            try:
                obj = json.loads(s)
                if isinstance(obj, dict):
                    return str(obj.get("id") or obj.get("modelID") or "")[:60]
            except ValueError:
                pass
        return s[:60]
    return ""


def _parse_tokens(tok):
    if not isinstance(tok, dict):
        return 0, 0, 0, 0
    inp = max(0, safe_int(tok.get("input"), 0))
    out = max(0, safe_int(tok.get("output"), 0))
    cache = tok.get("cache") if isinstance(tok.get("cache"), dict) else {}
    cr = max(0, safe_int(cache.get("read"), 0))
    cw = max(0, safe_int(cache.get("write"), 0))
    # OpenCode stores non-cached input separately from cache.read/cache.write (same as Claude).
    return inp + cr + cw, out, cr, cw


def _handle_tool_call(tname, state, st):
    st["tools"][tname] += 1
    inp = state.get("input") if isinstance(state.get("input"), dict) else {}
    low_t = tname.lower()

    if low_t in ("skill", "read_skill"):
        raw_sk = inp.get("id") or inp.get("name") or inp.get("skill") or ""
        sk = canon_skill(raw_sk)
        if sk:
            st["skill_loads"].add(sk)
            st["skill_first_turn"].setdefault(sk, max(1, st["assistants"]))

    for key in ("filePath", "file_path", "path", "Path", "target_file"):
        fp = inp.get(key)
        if isinstance(fp, str) and fp.strip():
            sk = _skill_from_path(fp)
            if sk:
                st["skill_loads"].add(sk)
                st["skill_first_turn"].setdefault(sk, max(1, st["assistants"]))
            lang = lang_from_path(fp)
            if lang:
                st["languages"][lang] += 1
            if fp not in st["touched_seen"] and len(st["touched_files"]) < 15:
                st["touched_seen"].add(fp)
                st["touched_files"].append(fp[-120:])

    cmd = inp.get("command") or inp.get("cmd") or ""
    if isinstance(cmd, str) and cmd:
        if re.search(r"\bgit\s+commit\b", cmd):
            st["git_commits"] += 1
        if re.search(r"\bgit\s+push\b", cmd):
            st["git_pushes"] += 1

    if low_t in ("task", "subagent", "agent"):
        st["subagents"] += 1
        role = str(inp.get("subagent_type") or inp.get("agent") or inp.get("description") or "subagent")[:60]
        st["subagent_roles"][role] += 1
        if len(st["subagent_runs"]) < 10:
            st["subagent_runs"].append({"role": role, "objective": truncate_text(inp.get("prompt") or "", 160)})

    status = str(state.get("status") or "").lower()
    err_val = state.get("error")
    if status == "error" or err_val:
        st["errors"][tname] += 1
        if st["skill_loads"]:
            share = 1.0 / float(len(st["skill_loads"]))
            for sk in st["skill_loads"]:
                st["post_err"][sk] += share
        err_txt = str(err_val or state.get("output") or status)
        st["error_cats"][categorize_error(tname, err_txt)] += 1
        if len(st["error_samples"]) < 8:
            st["error_samples"].append(f"{tname}: {truncate_text(err_txt, 140)}")


def _record_user_prompt(txt, ep, st):
    st["prompts"] += 1
    hr = epoch_to_utc_hour(ep)
    if hr is not None:
        st["msg_hours"][str(hr)] += 1
    if st["last_assistant_ep"] is not None and ep is not None and ep > st["last_assistant_ep"]:
        st["gaps"].append(round(ep - st["last_assistant_ep"], 2))
        st["last_assistant_ep"] = None
    short = truncate_text(txt, 260)
    if st["prompts"] >= 2 and short:
        st["interjection_reasons"][classify_interjection(short)] += 1
    if short and len(st["user_prompts"]) < 8:
        st["user_prompts"].append(short)


def _accrue_tokens(t_in, t_out, t_cr, t_cw, st):
    st["tokens_in"] += t_in
    st["tokens_out"] += t_out
    st["tokens_cr"] += t_cr
    st["tokens_cw"] += t_cw
    if st["skill_loads"] and (t_in or t_out):
        n_sk = float(len(st["skill_loads"]))
        for sk in st["skill_loads"]:
            st["post_in"][sk] += t_in / n_sk
            st["post_out"][sk] += t_out / n_sk
            st["post_cr"][sk] += t_cr / n_sk
            st["post_cw"][sk] += t_cw / n_sk


def _extract_v2(con, sid, st):
    row = con.execute(
        "SELECT parent_id, directory, model, time_created, time_updated, "
        "tokens_input, tokens_output, tokens_cache_read, tokens_cache_write "
        "FROM session_v2 WHERE id = ?",
        (sid,),
    ).fetchone()
    if row:
        st["parent_id"] = row[0] or None
        st["project"] = str(row[1] or "")[:240]
        mname = _extract_model_name(row[2])
        if mname:
            st["fallback_model"] = mname
        for ep in (ts_to_epoch(row[3]), ts_to_epoch(row[4])):
            if ep is not None:
                st["first_ep"] = ep if st["first_ep"] is None else min(st["first_ep"], ep)
                st["last_ep"] = ep if st["last_ep"] is None else max(st["last_ep"], ep)
        st["row_tokens"] = (
            max(0, safe_int(row[5], 0)) + max(0, safe_int(row[7], 0)) + max(0, safe_int(row[8], 0)),
            max(0, safe_int(row[6], 0)),
            max(0, safe_int(row[7], 0)),
            max(0, safe_int(row[8], 0)),
        )
    cur = con.execute(
        "SELECT type, time_created, data FROM session_message WHERE session_id = ? ORDER BY seq ASC, time_created ASC",
        (sid,),
    )
    for mtype, t_crt, raw in cur:
        ep = ts_to_epoch(t_crt)
        if ep is not None:
            st["first_ep"] = ep if st["first_ep"] is None else min(st["first_ep"], ep)
            st["last_ep"] = ep if st["last_ep"] is None else max(st["last_ep"], ep)
        try:
            obj = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        if mtype == "user":
            txt = obj.get("text") or ""
            if isinstance(txt, str) and txt.strip():
                _record_user_prompt(txt, ep, st)
        elif mtype == "assistant":
            st["assistants"] += 1
            if ep is not None:
                st["last_assistant_ep"] = ep
            mname = _extract_model_name(obj.get("model"))
            if mname and mname != st["last_model"]:
                st["session_models"][mname] += 1
                st["last_model"] = mname
            texts = []
            for item in (obj.get("content") if isinstance(obj.get("content"), list) else []):
                if not isinstance(item, dict):
                    continue
                itype = item.get("type")
                if itype == "tool":
                    tname = str(item.get("name") or item.get("tool") or "unknown")
                    state = item.get("state") if isinstance(item.get("state"), dict) else {}
                    _handle_tool_call(tname, state, st)
                elif itype == "text" and isinstance(item.get("text"), str):
                    texts.append(item["text"])
            if texts:
                short = truncate_text(" ".join(texts), 280)
                if short:
                    st["assistant_tail"].append(short)
                    if len(st["assistant_tail"]) > 3:
                        st["assistant_tail"].pop(0)
            t_in, t_out, t_cr, t_cw = _parse_tokens(obj.get("tokens"))
            if t_in or t_out or t_cr or t_cw:
                st["saw_step_tokens"] = True
                _accrue_tokens(t_in, t_out, t_cr, t_cw, st)


def _extract_v1(con, sid, st):
    row = con.execute(
        "SELECT parent_id, directory, model, time_created, time_updated, "
        "tokens_input, tokens_output, tokens_cache_read, tokens_cache_write "
        "FROM session WHERE id = ?",
        (sid,),
    ).fetchone()
    if row:
        st["parent_id"] = row[0] or None
        st["project"] = str(row[1] or "")[:240]
        mname = _extract_model_name(row[2])
        if mname:
            st["fallback_model"] = mname
        for ep in (ts_to_epoch(row[3]), ts_to_epoch(row[4])):
            if ep is not None:
                st["first_ep"] = ep if st["first_ep"] is None else min(st["first_ep"], ep)
                st["last_ep"] = ep if st["last_ep"] is None else max(st["last_ep"], ep)
        st["row_tokens"] = (
            max(0, safe_int(row[5], 0)) + max(0, safe_int(row[7], 0)) + max(0, safe_int(row[8], 0)),
            max(0, safe_int(row[6], 0)),
            max(0, safe_int(row[7], 0)),
            max(0, safe_int(row[8], 0)),
        )
    msg_roles = {}
    for mid, t_crt, raw in con.execute(
        "SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created ASC",
        (sid,),
    ):
        ep = ts_to_epoch(t_crt)
        if ep is not None:
            st["first_ep"] = ep if st["first_ep"] is None else min(st["first_ep"], ep)
            st["last_ep"] = ep if st["last_ep"] is None else max(st["last_ep"], ep)
        try:
            obj = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        role = str(obj.get("role") or "")
        msg_roles[mid] = (role, ep)
        if role == "assistant":
            st["assistants"] += 1
            if ep is not None:
                st["last_assistant_ep"] = ep
            mname = _extract_model_name(obj.get("modelID") or obj.get("model"))
            if mname and mname != st["last_model"]:
                st["session_models"][mname] += 1
                st["last_model"] = mname
    seen_user_msgs = set()
    for mid, t_crt, raw in con.execute(
        "SELECT message_id, time_created, data FROM part WHERE session_id = ? ORDER BY time_created ASC, rowid ASC",
        (sid,),
    ):
        ep = ts_to_epoch(t_crt)
        try:
            obj = json.loads(raw) if isinstance(raw, str) else {}
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        ptype = obj.get("type")
        role, mep = msg_roles.get(mid, ("", ep))
        if ptype == "text" and isinstance(obj.get("text"), str) and obj["text"].strip():
            if role == "user" and mid not in seen_user_msgs:
                seen_user_msgs.add(mid)
                _record_user_prompt(obj["text"], mep or ep, st)
            elif role == "assistant":
                short = truncate_text(obj["text"], 280)
                if short:
                    st["assistant_tail"].append(short)
                    if len(st["assistant_tail"]) > 3:
                        st["assistant_tail"].pop(0)
        elif ptype == "tool":
            tname = str(obj.get("tool") or obj.get("name") or "unknown")
            state = obj.get("state") if isinstance(obj.get("state"), dict) else {}
            _handle_tool_call(tname, state, st)
        elif ptype == "step-finish":
            t_in, t_out, t_cr, t_cw = _parse_tokens(obj.get("tokens"))
            if t_in or t_out or t_cr or t_cw:
                st["saw_step_tokens"] = True
                _accrue_tokens(t_in, t_out, t_cr, t_cw, st)


def extract_session(ref, mtime=0.0, db_cache=None):
    """Return (meta_dict, digest_dict) for one OpenCode session ref '<db>#<v1|v2>:<sid>'."""
    db_path, schema, sid = _parse_ref(ref)
    st = {
        "parent_id": None, "project": "", "fallback_model": "", "last_model": None,
        "first_ep": None, "last_ep": None, "last_assistant_ep": None,
        "prompts": 0, "assistants": 0, "git_commits": 0, "git_pushes": 0,
        "tools": Counter(), "errors": Counter(), "error_cats": Counter(),
        "languages": Counter(), "skill_loads": set(), "skill_first_turn": {},
        "subagents": 0, "subagent_roles": Counter(), "session_models": Counter(),
        "msg_hours": Counter(), "gaps": [], "interjection_reasons": Counter(),
        "user_prompts": [], "assistant_tail": [], "subagent_runs": [],
        "error_samples": [], "touched_files": [], "touched_seen": set(),
        "tokens_in": 0, "tokens_out": 0, "tokens_cr": 0, "tokens_cw": 0,
        "post_in": defaultdict(float), "post_out": defaultdict(float),
        "post_cr": defaultdict(float), "post_cw": defaultdict(float),
        "post_err": defaultdict(float), "saw_step_tokens": False, "row_tokens": (0, 0, 0, 0),
    }
    con = None
    close_con = False
    try:
        if isinstance(db_cache, dict):
            con = db_cache.get(db_path)
            if con is None:
                con = _open_ro(db_path)
                db_cache[db_path] = con
        else:
            con = _open_ro(db_path)
            close_con = True
        if schema == "v2":
            _extract_v2(con, sid, st)
        else:
            _extract_v1(con, sid, st)
    except sqlite3.Error:
        pass
    finally:
        if close_con and con is not None:
            con.close()

    if not st["session_models"] and st["fallback_model"]:
        st["session_models"][st["fallback_model"]] = 1
    if not st["saw_step_tokens"] and any(st["row_tokens"]):
        st["tokens_in"], st["tokens_out"], st["tokens_cr"], st["tokens_cw"] = st["row_tokens"]
    first_ep, last_ep = st["first_ep"], st["last_ep"]
    dur_min = round((last_ep - first_ep) / 60.0, 2) if (first_ep and last_ep and last_ep >= first_ep) else 0.0
    turns_after = {
        sk: max(1, st["assistants"] - ft + 1) for sk, ft in sorted(st["skill_first_turn"].items())
    }
    has_post = bool(st["skill_loads"] and (st["saw_step_tokens"] or any(st["post_err"].values())))
    meta = {
        "meta_version": META_SCHEMA_VERSION, "id": sid, "harness": "opencode",
        "source_path": ref, "source_mtime": mtime, "project": st["project"],
        "workspaces": [st["project"]] if st["project"] else [], "branch": "", "commit": "",
        "first_ts": epoch_to_iso(first_ep), "last_ts": epoch_to_iso(last_ep),
        "first_epoch": first_ep, "last_epoch": last_ep, "duration_minutes": dur_min,
        "prompts": st["prompts"], "assistant_messages": st["assistants"],
        "tools": dict(st["tools"]), "tool_calls": sum(st["tools"].values()),
        "errors": dict(st["errors"]), "error_categories": dict(st["error_cats"]),
        "languages": dict(st["languages"]), "skill_loads": sorted(st["skill_loads"]),
        "subagents": st["subagents"], "subagent_roles": dict(st["subagent_roles"]),
        "session_models": dict(st["session_models"]), "max_depth": 1 if st["subagents"] else 0,
        "parent_session": st["parent_id"], "child_sessions": [],
        "response_gaps": st["gaps"], "message_hours": dict(st["msg_hours"]),
        "hook_blocks": {}, "git_commits": st["git_commits"], "git_pushes": st["git_pushes"],
        "tokens_in": st["tokens_in"], "tokens_out": st["tokens_out"],
        "tokens_cache_read": st["tokens_cr"], "tokens_cache_write": st["tokens_cw"],
        "turns_after_skill_load": turns_after,
        "post_load_attribution": {
            sk: {
                "tokens_in": round(st["post_in"][sk], 2), "tokens_out": round(st["post_out"][sk], 2),
                "tokens_cache_read": round(st["post_cr"][sk], 2), "tokens_cache_write": round(st["post_cw"][sk], 2),
                "errors": round(st["post_err"][sk], 2),
            }
            for sk in sorted(st["skill_loads"])
        } if has_post else {},
        "interjection_reasons": dict(st["interjection_reasons"]),
    }
    digest = {
        "session_id": sid, "harness": "opencode", "source_mtime": mtime,
        "project": st["project"], "duration_minutes": dur_min, "prompts_count": st["prompts"],
        "tool_calls": meta["tool_calls"], "top_tools": dict(st["tools"].most_common(6)),
        "languages": dict(st["languages"].most_common(6)), "skill_loads": meta["skill_loads"],
        "error_categories": dict(st["error_cats"]), "user_prompts": st["user_prompts"][:6],
        "subagent_runs": st["subagent_runs"][:8], "error_samples": st["error_samples"][:8],
        "touched_files": st["touched_files"][:12], "final_assistant_notes": st["assistant_tail"][-2:],
    }
    return meta, digest

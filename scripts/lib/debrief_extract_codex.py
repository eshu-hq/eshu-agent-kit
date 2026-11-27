#!/usr/bin/env python3
"""Codex rollout transcript extractor (Stage 1 rich meta + Stage 2 digest)."""
import json
import os
import re
import shutil
import subprocess
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

_SKILL_PATH_RE = re.compile(r"([A-Za-z0-9._/-]*skills/[A-Za-z0-9._/-]+/SKILL\.md)")
_FILE_PATH_RE = re.compile(r"(?:^|[\s'\"(=])(/[A-Za-z0-9._/-]+\.[A-Za-z0-9]{1,8})(?:[\s'\",:;)\]]|$)")
_EXIT_NZ_RE = re.compile(r"(?:exit(?:ed)?\s+(?:with\s+)?code|exit\s+status)\s*[:=]?\s*([1-9][0-9]*)", re.IGNORECASE)
_BOILERPLATE_PREFIXES = (
    "# agents.md instructions",
    "<instructions>",
    "<environment_context>",
    "<permissions instructions>",
    "<collaboration_mode>",
    "<turn_aborted>",
    "<skill>",
)


def default_roots():
    home = os.path.expanduser("~/.codex")
    return [os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")]


def session_id_from_path(path):
    base = os.path.basename(path)
    for suf in (".jsonl.zst", ".jsonl"):
        if base.endswith(suf):
            base = base[: -len(suf)]
            break
    m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", base, re.IGNORECASE)
    return m.group(1) if m else base


def _looks_like_codex(path, fn):
    if fn in ("session.jsonl", "transcript.jsonl", "transcript_full.jsonl", "history.jsonl"):
        return False
    if fn.startswith("rollout-"):
        return True
    for idx, rec in enumerate(_iter_records(path)):
        if rec.get("type") in ("session_meta", "turn_context", "response_item", "token_usage_record", "event_msg"):
            return True
        if idx >= 4:
            break
    return False


def discover(roots, since_epoch):
    """Discover Codex rollout .jsonl (and .jsonl.zst when zstd is available) files."""
    has_zstd = bool(shutil.which("zstd"))
    by_id = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, _, fns in os.walk(root):
            for fn in fns:
                if fn.endswith(".jsonl"):
                    pass
                elif fn.endswith(".jsonl.zst") and has_zstd:
                    pass
                else:
                    continue
                p = os.path.join(dp, fn)
                if not _looks_like_codex(p, fn):
                    continue
                try:
                    mt = os.path.getmtime(p)
                except OSError:
                    continue
                if since_epoch and mt < since_epoch:
                    continue
                sid = session_id_from_path(p)
                prev = by_id.get(sid)
                if prev is None or mt > prev[1]:
                    by_id[sid] = (p, mt)
    out = list(by_id.values())
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def _iter_records(path):
    if not path.endswith(".zst"):
        yield from load_json_lines(path)
        return
    zstd_bin = shutil.which("zstd")
    if not zstd_bin:
        return
    try:
        proc = subprocess.Popen(
            [zstd_bin, "-dc", "--", path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace",
        )
    except OSError:
        return
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            s = line.strip()
            if not s:
                continue
            try:
                rec = json.loads(s)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec
    finally:
        if proc.stdout:
            proc.stdout.close()
        proc.wait()


def _skill_from_path(raw_path):
    parts = [seg for seg in str(raw_path or "").replace("\\", "/").split("/") if seg]
    if len(parts) < 3 or parts[-1] != "SKILL.md" or "skills" not in parts[:-2]:
        return ""
    return canon_skill(parts[-2])


def _is_owner_prompt(text):
    low = text.strip().lower()
    if not low:
        return False
    return not any(low.startswith(pref) for pref in _BOILERPLATE_PREFIXES)


def _extract_text_blocks(content):
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for blk in content:
            if isinstance(blk, dict) and isinstance(blk.get("text"), str):
                parts.append(blk["text"])
            elif isinstance(blk, str):
                parts.append(blk)
        return "\n".join(parts).strip()
    return ""


def _output_text(raw):
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        return "\n".join(
            str(b.get("text") or "") for b in raw if isinstance(b, dict)
        )
    if isinstance(raw, dict):
        return json.dumps(raw)
    return str(raw or "")


def _output_is_error(out_txt):
    if not out_txt:
        return False
    if _EXIT_NZ_RE.search(out_txt):
        return True
    s = out_txt.strip()
    if s.startswith("{"):
        try:
            obj = json.loads(s)
            if isinstance(obj, dict):
                meta = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
                ec = meta.get("exit_code") if "exit_code" in meta else obj.get("exit_code")
                if isinstance(ec, int) and ec != 0:
                    return True
                if obj.get("error") or obj.get("is_error"):
                    return True
        except ValueError:
            pass
    low = s[:300].lower()
    return low.startswith("error:") or "permission denied" in low or "blocked by hook" in low


def _parent_from_meta(pl):
    src = pl.get("source")
    if isinstance(src, dict):
        sub = src.get("subagent")
        if isinstance(sub, dict):
            ts = sub.get("thread_spawn")
            if isinstance(ts, dict) and isinstance(ts.get("parent_thread_id"), str):
                return ts["parent_thread_id"]
    for key in ("parent_thread_id", "parent_session_id", "forked_from_id"):
        val = pl.get(key)
        if isinstance(val, str) and val:
            return val
    return None


def _parse_usage_tuple(usage):
    if not isinstance(usage, dict):
        return 0, 0, 0, 0
    t_in = max(0, safe_int(usage.get("input_tokens"), 0))
    t_out = max(0, safe_int(usage.get("output_tokens"), 0))
    t_cr = max(0, safe_int(usage.get("cached_input_tokens"), 0))
    if not t_cr:
        t_cr = max(0, safe_int(usage.get("cache_read_input_tokens"), 0))
    t_cw = max(0, safe_int(usage.get("cache_write_input_tokens"), 0))
    return t_in, t_out, t_cr, t_cw


def extract_session(path, mtime=0.0):
    """Return (meta_dict, digest_dict) for one Codex rollout JSONL/JSONL.zst."""
    sess_id = parent_id = last_model = first_ep = last_ep = last_assistant_ep = last_total_seen = None
    project = branch = commit = ""
    workspaces = []
    prompts = assistants = subagents = git_commits = git_pushes = 0
    tools, errors, error_cats, languages = Counter(), Counter(), Counter(), Counter()
    subagent_roles, session_models, msg_hours, interjection_reasons = Counter(), Counter(), Counter(), Counter()
    skill_loads, touched_seen = set(), set()
    skill_first_turn, call_tools = {}, {}
    gaps, user_prompts, assistant_tail, subagent_runs, error_samples, touched_files = [], [], [], [], [], []
    has_usage_rec = False
    ur_in = ur_out = ur_cr = ur_cw = tc_in = tc_out = tc_cr = tc_cw = 0
    ur_post_in, ur_post_out, ur_post_cr, ur_post_cw = defaultdict(float), defaultdict(float), defaultdict(float), defaultdict(float)
    tc_post_in, tc_post_out, tc_post_cr, tc_post_cw = defaultdict(float), defaultdict(float), defaultdict(float), defaultdict(float)
    post_err = defaultdict(float)

    for rec in _iter_records(path):
        ep = ts_to_epoch(rec.get("timestamp"))
        if ep is not None:
            if first_ep is None or ep < first_ep:
                first_ep = ep
            if last_ep is None or ep > last_ep:
                last_ep = ep
        rtype = rec.get("type") or ""
        pl = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        pt = pl.get("type") or ""

        if rtype == "session_meta":
            sid = pl.get("id") or pl.get("session_id")
            if isinstance(sid, str) and sid and not sess_id:
                sess_id = sid
            if not parent_id:
                parent_id = _parent_from_meta(pl)
            cwd = pl.get("cwd")
            if isinstance(cwd, str) and cwd and not project:
                project = cwd[:240]
            roots = pl.get("runtime_workspace_roots")
            if isinstance(roots, list) and not workspaces:
                workspaces = [str(w)[:240] for w in roots if isinstance(w, str) and w]
            git_info = pl.get("git") if isinstance(pl.get("git"), dict) else {}
            if isinstance(git_info.get("branch"), str) and not branch:
                branch = git_info["branch"][:120]
            if isinstance(git_info.get("commit_hash"), str) and not commit:
                commit = git_info["commit_hash"][:40]
        elif rtype == "turn_context":
            cwd = pl.get("cwd")
            if isinstance(cwd, str) and cwd and not project:
                project = cwd[:240]
            model = pl.get("model")
            if isinstance(model, str) and model:
                mc = model[:60]
                if mc != last_model:
                    session_models[mc] += 1
                    last_model = mc
        elif rtype == "token_usage_record":
            has_usage_rec = True
            t_in, t_out, t_cr, t_cw = _parse_usage_tuple(pl.get("usage"))
            ur_in += t_in
            ur_out += t_out
            ur_cr += t_cr
            ur_cw += t_cw
            if skill_loads and (t_in or t_out):
                n_sk = float(len(skill_loads))
                for sk in skill_loads:
                    ur_post_in[sk] += t_in / n_sk
                    ur_post_out[sk] += t_out / n_sk
                    ur_post_cr[sk] += t_cr / n_sk
                    ur_post_cw[sk] += t_cw / n_sk
        elif rtype == "event_msg" and pt == "token_count":
            info = pl.get("info") if isinstance(pl.get("info"), dict) else {}
            tot = info.get("total_token_usage") if isinstance(info.get("total_token_usage"), dict) else None
            last_u = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else None
            sig = tuple(_parse_usage_tuple(tot)) if tot else None
            if last_u and (sig is None or sig != last_total_seen):
                last_total_seen = sig
                t_in, t_out, t_cr, t_cw = _parse_usage_tuple(last_u)
                tc_in += t_in
                tc_out += t_out
                tc_cr += t_cr
                tc_cw += t_cw
                if skill_loads and (t_in or t_out):
                    n_sk = float(len(skill_loads))
                    for sk in skill_loads:
                        tc_post_in[sk] += t_in / n_sk
                        tc_post_out[sk] += t_out / n_sk
                        tc_post_cr[sk] += t_cr / n_sk
                        tc_post_cw[sk] += t_cw / n_sk
        elif rtype == "response_item" and pt == "message":
            role = pl.get("role") or ""
            txt = _extract_text_blocks(pl.get("content"))
            if role == "user" and _is_owner_prompt(txt):
                prompts += 1
                hr = epoch_to_utc_hour(ep)
                if hr is not None:
                    msg_hours[str(hr)] += 1
                if last_assistant_ep is not None and ep is not None and ep > last_assistant_ep:
                    gaps.append(round(ep - last_assistant_ep, 2))
                    last_assistant_ep = None
                short = truncate_text(txt, 260)
                if prompts >= 2 and short:
                    interjection_reasons[classify_interjection(short)] += 1
                if short and len(user_prompts) < 8:
                    user_prompts.append(short)
            elif role == "assistant":
                assistants += 1
                if ep is not None:
                    last_assistant_ep = ep
                short = truncate_text(txt, 280)
                if short:
                    assistant_tail.append(short)
                    if len(assistant_tail) > 3:
                        assistant_tail.pop(0)
        elif rtype == "response_item" and pt in ("function_call", "custom_tool_call"):
            tname = str(pl.get("name") or "unknown")
            tools[tname] += 1
            cid = str(pl.get("call_id") or pl.get("id") or "")
            if cid:
                call_tools[cid] = tname
            raw_arg = str(pl.get("arguments") or pl.get("input") or "")
            for m in _SKILL_PATH_RE.finditer(raw_arg):
                sk = _skill_from_path(m.group(1))
                if sk:
                    skill_loads.add(sk)
                    skill_first_turn.setdefault(sk, max(1, assistants))
            if tname.lower() in ("skill", "read_skill"):
                try:
                    parsed = json.loads(raw_arg) if raw_arg.strip().startswith("{") else {}
                except ValueError:
                    parsed = {}
                if isinstance(parsed, dict):
                    sk = canon_skill(parsed.get("skill") or parsed.get("name") or parsed.get("id") or "")
                    if sk:
                        skill_loads.add(sk)
                        skill_first_turn.setdefault(sk, max(1, assistants))
            if re.search(r"\bgit\s+commit\b", raw_arg):
                git_commits += 1
            if re.search(r"\bgit\s+push\b", raw_arg):
                git_pushes += 1
            for fm in _FILE_PATH_RE.finditer(raw_arg):
                fp = fm.group(1)
                lang = lang_from_path(fp)
                if lang:
                    languages[lang] += 1
                if fp not in touched_seen and len(touched_files) < 15:
                    touched_seen.add(fp)
                    touched_files.append(fp[-120:])
            if tname == "spawn_agent":
                subagents += 1
                role_s = "subagent"
                try:
                    parsed = json.loads(raw_arg) if raw_arg.strip().startswith("{") else {}
                    if isinstance(parsed, dict):
                        role_s = str(parsed.get("agent_type") or parsed.get("role") or "subagent")[:60]
                except ValueError:
                    pass
                subagent_roles[role_s] += 1
                if len(subagent_runs) < 10:
                    subagent_runs.append({"role": role_s})
        elif rtype == "response_item" and pt in ("function_call_output", "custom_tool_call_output"):
            cid = str(pl.get("call_id") or "")
            tname = call_tools.get(cid, "exec")
            out_txt = _output_text(pl.get("output"))
            if _output_is_error(out_txt):
                errors[tname] += 1
                if skill_loads:
                    share = 1.0 / float(len(skill_loads))
                    for sk in skill_loads:
                        post_err[sk] += share
                error_cats[categorize_error(tname, out_txt)] += 1
                if len(error_samples) < 8:
                    error_samples.append(f"{tname}: {truncate_text(out_txt, 140)}")

    if not sess_id:
        sess_id = session_id_from_path(path)
    if project and not workspaces:
        workspaces = [project]
    dur_min = round((last_ep - first_ep) / 60.0, 2) if (first_ep and last_ep and last_ep >= first_ep) else 0.0
    if has_usage_rec:
        tokens_in, tokens_out, tokens_cr, tokens_cw = ur_in, ur_out, ur_cr, ur_cw
        p_in, p_out, p_cr, p_cw = ur_post_in, ur_post_out, ur_post_cr, ur_post_cw
    else:
        tokens_in, tokens_out, tokens_cr, tokens_cw = tc_in, tc_out, tc_cr, tc_cw
        p_in, p_out, p_cr, p_cw = tc_post_in, tc_post_out, tc_post_cr, tc_post_cw
    turns_after_skill_load = {
        sk: max(1, assistants - first_t + 1) for sk, first_t in sorted(skill_first_turn.items())
    }
    meta = {
        "meta_version": META_SCHEMA_VERSION,
        "id": sess_id,
        "harness": "codex",
        "source_path": path,
        "source_mtime": mtime,
        "project": project,
        "workspaces": workspaces,
        "branch": branch,
        "commit": commit,
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
        "max_depth": 1 if subagents else 0,
        "parent_session": parent_id,
        "child_sessions": [],
        "response_gaps": gaps,
        "message_hours": dict(msg_hours),
        "hook_blocks": {},
        "git_commits": git_commits,
        "git_pushes": git_pushes,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "tokens_cache_read": tokens_cr,
        "tokens_cache_write": tokens_cw,
        "turns_after_skill_load": turns_after_skill_load,
        "post_load_attribution": {
            sk: {
                "tokens_in": round(p_in[sk], 2),
                "tokens_out": round(p_out[sk], 2),
                "tokens_cache_read": round(p_cr[sk], 2),
                "tokens_cache_write": round(p_cw[sk], 2),
                "errors": round(post_err[sk], 2),
            }
            for sk in sorted(skill_loads)
        } if skill_loads else {},
        "interjection_reasons": dict(interjection_reasons),
    }
    digest = {
        "session_id": sess_id,
        "harness": "codex",
        "source_mtime": mtime,
        "project": project,
        "branch": branch,
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

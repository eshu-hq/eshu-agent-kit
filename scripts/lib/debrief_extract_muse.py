#!/usr/bin/env python3
"""Muse session extractor (Stage 1 rich metadata + bounded Stage 2 digest)."""
import json
import os
import re
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
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return [os.path.join(base, "muse", "sessions")]


def discover(roots, since_epoch):
    """Yield (path, mtime) for Muse session.jsonl files newer than since_epoch."""
    out = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, _, fns in os.walk(root):
            if "session.jsonl" not in fns:
                continue
            p = os.path.join(dp, "session.jsonl")
            try:
                mt = os.path.getmtime(p)
            except OSError:
                continue
            if since_epoch and mt < since_epoch:
                continue
            out.append((p, mt))
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def _extract_path_from_args(args):
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return ""
    if not isinstance(args, dict):
        return ""
    for k in ("path", "file_path", "Path", "target_file", "filename"):
        v = args.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def _extract_cmd_from_args(args):
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return ""
    if isinstance(args, dict):
        for k in ("command", "cmd"):
            v = args.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return ""


def _skill_from_read_skill(args):
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return ""
    if not isinstance(args, dict) or not isinstance(args.get("name"), str):
        return ""
    name = args["name"].strip().rstrip("/")
    parts = name.split("/")
    if len(parts) >= 2:
        name = parts[-2]
    return canon_skill(name)


def _usage_cache_read(usage):
    val = usage.get("cache_read_tokens")
    if val is None:
        val = usage.get("cached_tokens")
    return max(0, safe_int(val, 0))


def extract_session(path, mtime=0.0):
    """Return (meta_dict, digest_dict) for one Muse session.jsonl."""
    sess_id = None
    parent_id = None
    child_ids = set()
    project = ""
    branch = ""
    commit = ""
    prompts = 0
    assistants = 0
    tools = Counter()
    errors = Counter()
    error_cats = Counter()
    languages = Counter()
    subagents = 0
    subagent_roles = Counter()
    session_models = Counter()
    skill_loads = set()
    skill_first_model_turn = {}
    skill_first_asst = {}
    hook_blocks = Counter()
    msg_hours = Counter()
    fallback_hours = Counter()
    gaps = []
    started = {}
    read_seen = set()
    first_ep = None
    last_ep = None
    last_assistant_ep = None
    git_commits = 0
    git_pushes = 0
    model_turns = 0
    has_model_completed = False
    mc_tokens_in = mc_tokens_out = mc_cache_read = mc_cache_write = 0
    fb_tokens_in = fb_tokens_out = fb_cache_read = fb_cache_write = 0
    model_duration_ms = 0
    post_in = defaultdict(float)
    post_out = defaultdict(float)
    post_cr = defaultdict(float)
    post_cw = defaultdict(float)
    fb_post_in = defaultdict(float)
    fb_post_out = defaultdict(float)
    fb_post_cr = defaultdict(float)
    fb_post_cw = defaultdict(float)
    post_err = defaultdict(float)
    max_depth = 0

    user_prompts = []
    seen_user_msgs = set()
    interjection_reasons = Counter()
    intent_classified = 0
    assistant_tail = []
    subagent_runs = []
    error_samples = []
    touched_files = []
    touched_seen = set()

    # Check path-based child detection (.../<parent>/subagent/<child>/session.jsonl)
    norm_parts = os.path.normpath(path).split(os.sep)
    if len(norm_parts) >= 4 and norm_parts[-3] == "subagent":
        parent_id = norm_parts[-4]

    for rec in load_json_lines(path):
        ep = ts_to_epoch(rec.get("recorded_at"))
        if ep is not None:
            if first_ep is None or ep < first_ep:
                first_ep = ep
            if last_ep is None or ep > last_ep:
                last_ep = ep
        stream = rec.get("stream")
        if isinstance(stream, dict) and stream.get("id") and sess_id is None:
            sess_id = str(stream["id"])
        pt = rec.get("payload_type") or ""
        pl = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        inner = pl.get("record") if isinstance(pl.get("record"), dict) else pl

        if pt == "runtime.user_intent.accepted":
            prompts += 1
            utxt = truncate_text(
                inner.get("text") or inner.get("prompt") or inner.get("content") or inner.get("message") or "",
                260,
            )
            if prompts >= 2 and utxt:
                interjection_reasons[classify_interjection(utxt)] += 1
                intent_classified += 1
            hr = epoch_to_utc_hour(ep)
            if hr is not None:
                msg_hours[str(hr)] += 1
            if last_assistant_ep is not None and ep is not None and ep > last_assistant_ep:
                gaps.append(round(ep - last_assistant_ep, 2))
                last_assistant_ep = None
        elif pt == "session.workspace_branch.observed":
            ws = inner.get("workspace_root")
            if isinstance(ws, str) and ws and not project:
                project = ws[:240]
            ref = inner.get("reference")
            if isinstance(ref, dict) and isinstance(ref.get("name"), str) and not branch:
                branch = ref["name"][:120]
            cm = inner.get("commit")
            if isinstance(cm, str) and cm and not commit:
                commit = cm[:40]
        elif pt == "runtime.session.metadata" and not project:
            ws = inner.get("workspace_root")
            if isinstance(ws, str) and ws:
                project = ws[:240]
        elif pt == "run.model.configured":
            mid = inner.get("model_id")
            if isinstance(mid, str) and mid:
                session_models[mid[:60]] += 1
        elif pt == "subagent.control.spawn_accepted":
            subagents += 1
            role = str(inner.get("role") or "")[:80]
            if role:
                subagent_roles[role] += 1
            try:
                d = int(inner.get("depth") or 0)
                if d > max_depth:
                    max_depth = d
            except (TypeError, ValueError):
                pass
            obj = truncate_text(inner.get("objective") or "", 180)
            if len(subagent_runs) < 12:
                subagent_runs.append({"role": role or "subagent", "objective": obj})
        elif pt == "subagent.control.child_session_bound":
            cid = inner.get("child_session_id")
            if isinstance(cid, str) and cid:
                child_ids.add(cid)
        elif pt == "subagent.control.result_ready":
            summ = truncate_text(inner.get("summary") or "", 200)
            errk = str(inner.get("error_kind") or "")
            if subagent_runs and "summary" not in subagent_runs[-1]:
                subagent_runs[-1]["summary"] = summ
                if errk:
                    subagent_runs[-1]["error_kind"] = errk
            elif len(subagent_runs) < 12 and (summ or errk):
                subagent_runs.append({"role": "subagent", "summary": summ, "error_kind": errk})
        elif pt == "subagent.control.runtime_observed":
            usage = inner.get("usage") if isinstance(inner.get("usage"), dict) else {}
            f_in = max(0, safe_int(usage.get("input_tokens"), 0))
            f_out = max(0, safe_int(usage.get("output_tokens"), 0))
            f_cr = _usage_cache_read(usage)
            f_cw = max(0, safe_int(usage.get("cache_write_tokens"), 0))
            fb_tokens_in += f_in
            fb_tokens_out += f_out
            fb_cache_read += f_cr
            fb_cache_write += f_cw
            if skill_loads and (f_in or f_out):
                n_sk = float(len(skill_loads))
                for sk in skill_loads:
                    fb_post_in[sk] += f_in / n_sk
                    fb_post_out[sk] += f_out / n_sk
                    fb_post_cr[sk] += f_cr / n_sk
                    fb_post_cw[sk] += f_cw / n_sk
        elif pt == "tool_batch.effect.started":
            cid = inner.get("call_id")
            if cid:
                started[str(cid)] = str(inner.get("tool_name") or "unknown")
        elif pt == "tool_batch.effect.terminal":
            tool = started.get(str(inner.get("call_id") or ""), "unknown")
            tools[tool] += 1
            outcome = inner.get("outcome")
            kind = outcome.get("kind") if isinstance(outcome, dict) else outcome
            if kind != "completed":
                errors[tool] += 1
                if skill_loads:
                    share = 1.0 / float(len(skill_loads))
                    for sk in skill_loads:
                        post_err[sk] += share
                err_txt = str(outcome) if outcome else str(kind)
                error_cats[categorize_error(tool, err_txt)] += 1
                if len(error_samples) < 8:
                    error_samples.append(f"{tool}: {truncate_text(err_txt, 140)}")

        # runtime.session nested events (user messages, tool args, hooks, skills, assistant text)
        ev = pl.get("event") if isinstance(pl.get("event"), dict) else None
        if ev:
            ek = ev.get("kind") or ev.get("type") or ""
            if ek == "model_user_messages":
                msgs = ev.get("messages")
                if isinstance(msgs, list):
                    for m in msgs:
                        txt = truncate_text(m, 260)
                        if txt and txt not in seen_user_msgs:
                            seen_user_msgs.add(txt)
                            if len(seen_user_msgs) >= 2 and intent_classified == 0:
                                interjection_reasons[classify_interjection(txt)] += 1
                            if len(user_prompts) < 8:
                                user_prompts.append(txt)
                            hr = epoch_to_utc_hour(ep)
                            if hr is not None:
                                fallback_hours[str(hr)] += 1
            elif ek == "model_completed":
                has_model_completed = True
                model_turns += 1
                usage = ev.get("usage") if isinstance(ev.get("usage"), dict) else {}
                t_in = max(0, safe_int(usage.get("input_tokens"), 0))
                t_out = max(0, safe_int(usage.get("output_tokens"), 0))
                t_cr = _usage_cache_read(usage)
                t_cw = max(0, safe_int(usage.get("cache_write_tokens"), 0))
                mc_tokens_in += t_in
                mc_tokens_out += t_out
                mc_cache_read += t_cr
                mc_cache_write += t_cw
                model_duration_ms += max(0, safe_int(ev.get("duration_ms"), 0))
                if skill_loads and (t_in or t_out):
                    n_sk = float(len(skill_loads))
                    for sk in skill_loads:
                        post_in[sk] += t_in / n_sk
                        post_out[sk] += t_out / n_sk
                        post_cr[sk] += t_cr / n_sk
                        post_cw[sk] += t_cw / n_sk
            elif ek == "assistant_message_committed":
                assistants += 1
                if ep is not None:
                    last_assistant_ep = ep
                txt = truncate_text(ev.get("text") or "", 280)
                if txt:
                    assistant_tail.append(txt)
                    if len(assistant_tail) > 3:
                        assistant_tail.pop(0)
            elif ek == "skill_read_observed":
                sk = canon_skill(ev.get("skill_id") or "")
                if sk:
                    skill_loads.add(sk)
                    skill_first_model_turn.setdefault(sk, max(1, model_turns))
                    skill_first_asst.setdefault(sk, assistants)
            elif ek == "hook_run_terminal":
                ec = ev.get("exit_code")
                if isinstance(ec, int) and ec != 0:
                    hk = str(ev.get("hook_key") or ev.get("event") or "hook")
                    hook_blocks[hk] += 1
                    error_cats["Hook Blocked"] += 1
                    if len(error_samples) < 8:
                        detail = ev.get("stderr") or ev.get("stdout") or f"exit {ec}"
                        error_samples.append(f"hook({hk}): {truncate_text(detail, 140)}")
            elif ek == "assistant_tool_calls_committed":
                tcalls = ev.get("tool_calls")
                for tc in (tcalls if isinstance(tcalls, list) else []):
                    if not isinstance(tc, dict):
                        continue
                    tname = str(tc.get("name") or "")
                    cid = str(tc.get("call_id") or "")
                    args = tc.get("args")
                    if tname == "read_skill":
                        if not cid or cid not in read_seen:
                            if cid:
                                read_seen.add(cid)
                            sk = _skill_from_read_skill(args)
                            if sk:
                                skill_loads.add(sk)
                                skill_first_model_turn.setdefault(sk, max(1, model_turns))
                                skill_first_asst.setdefault(sk, assistants)
                    elif tname in ("read_file", "edit_file", "write_file"):
                        fp = _extract_path_from_args(args)
                        if fp:
                            lang = lang_from_path(fp)
                            if lang:
                                languages[lang] += 1
                            if fp not in touched_seen and len(touched_files) < 15:
                                touched_seen.add(fp)
                                touched_files.append(fp[-120:])
                    elif tname == "bash":
                        cmd = _extract_cmd_from_args(args)
                        if re.search(r"\bgit\s+commit\b", cmd):
                            git_commits += 1
                        if re.search(r"\bgit\s+push\b", cmd):
                            git_pushes += 1

    if not sess_id:
        sess_id = os.path.basename(os.path.dirname(path))
    if prompts == 0 and user_prompts:
        prompts = len(user_prompts)
        if not msg_hours:
            msg_hours.update(fallback_hours)
    dur_min = round((last_ep - first_ep) / 60.0, 2) if (first_ep and last_ep and last_ep >= first_ep) else 0.0
    if has_model_completed:
        tokens_in, tokens_out = mc_tokens_in, mc_tokens_out
        tokens_cache_read, tokens_cache_write = mc_cache_read, mc_cache_write
        attr_in, attr_out, attr_cr, attr_cw = post_in, post_out, post_cr, post_cw
    else:
        tokens_in, tokens_out = fb_tokens_in, fb_tokens_out
        tokens_cache_read, tokens_cache_write = fb_cache_read, fb_cache_write
        attr_in, attr_out, attr_cr, attr_cw = fb_post_in, fb_post_out, fb_post_cr, fb_post_cw
    turns_after_skill_load = {
        sk: (
            max(1, model_turns - skill_first_model_turn.get(sk, 1) + 1)
            if model_turns > 0
            else max(1, assistants - skill_first_asst.get(sk, 0))
        )
        for sk in sorted(skill_loads)
    }

    meta = {
        "meta_version": META_SCHEMA_VERSION,
        "id": sess_id,
        "harness": "muse",
        "source_path": path,
        "source_mtime": mtime,
        "project": project,
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
        "max_depth": max_depth,
        "parent_session": parent_id,
        "child_sessions": sorted(child_ids),
        "response_gaps": gaps,
        "message_hours": dict(msg_hours),
        "hook_blocks": dict(hook_blocks),
        "git_commits": git_commits,
        "git_pushes": git_pushes,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "tokens_cache_read": tokens_cache_read,
        "tokens_cache_write": tokens_cache_write,
        "model_duration_ms": model_duration_ms,
        "turns_after_skill_load": turns_after_skill_load,
        "post_load_attribution": {
            sk: {
                "tokens_in": round(attr_in[sk], 2),
                "tokens_out": round(attr_out[sk], 2),
                "tokens_cache_read": round(attr_cr[sk], 2),
                "tokens_cache_write": round(attr_cw[sk], 2),
                "errors": round(post_err[sk], 2),
            }
            for sk in sorted(skill_loads)
        } if skill_loads else {},
        "interjection_reasons": dict(interjection_reasons),
    }
    digest = {
        "session_id": sess_id,
        "harness": "muse",
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

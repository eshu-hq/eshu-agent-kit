#!/usr/bin/env python3
"""Claude Code transcript extractor + native ~/.claude/usage-data/facets importer."""
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
    read_json,
    safe_int,
    truncate_text,
    ts_to_epoch,
    validate_facet,
)


def default_roots():
    return [os.path.expanduser("~/.claude/projects")]


def default_claude_facets_dir():
    return os.path.expanduser("~/.claude/usage-data/facets")


def discover(roots, since_epoch):
    """Yield (path, mtime) for Claude *.jsonl transcripts newer than since_epoch."""
    out = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, _, fns in os.walk(root):
            norm_dp = dp.replace("\\", "/")
            if "/.system_generated" in norm_dp or "/subagent/" in norm_dp:
                continue
            for fn in fns:
                if not fn.endswith(".jsonl") or fn.startswith("rollout-") or fn in (
                    "journal.jsonl",
                    "session.jsonl",
                    "transcript.jsonl",
                    "transcript_full.jsonl",
                    "history.jsonl",
                ):
                    continue
                p = os.path.join(dp, fn)
                try:
                    mt = os.path.getmtime(p)
                except OSError:
                    continue
                if since_epoch and mt < since_epoch:
                    continue
                out.append((p, mt))
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def _parent_from_path(path):
    """Detect ~/.claude/projects/<proj>/<parent-uuid>/subagents/agent-*.jsonl."""
    parts = os.path.normpath(path).split(os.sep)
    if len(parts) >= 3 and parts[-2] == "subagents":
        return parts[-3]
    return None


def _project_from_path(path):
    parts = os.path.normpath(path).split(os.sep)
    if len(parts) >= 4 and parts[-2] == "subagents":
        return parts[-4]
    return os.path.basename(os.path.dirname(path))


def import_native_claude_facets(facets_dir=None):
    """Load native ~/.claude/usage-data/facets/*.json into canonical facet dicts."""
    fdir = facets_dir or default_claude_facets_dir()
    imported = {}
    if not os.path.isdir(fdir):
        return imported
    for fn in os.listdir(fdir):
        if not fn.endswith(".json"):
            continue
        p = os.path.join(fdir, fn)
        raw = read_json(p)
        if not raw:
            continue
        sid = str(raw.get("session_id") or os.path.splitext(fn)[0]).strip()
        sat = "likely_satisfied"
        sc = raw.get("user_satisfaction_counts")
        if isinstance(sc, dict) and sc:
            scored = [(str(k), safe_int(v, 0)) for k, v in sc.items()]
            scored = [kv for kv in scored if kv[1] > 0]
            if scored:
                sat = max(scored, key=lambda kv: kv[1])[0]
        try:
            mt = os.path.getmtime(p)
        except OSError:
            mt = 0.0
        cand = {
            "session_id": sid,
            "harness": "claude",
            "source_mtime": mt,
            "underlying_goal": raw.get("underlying_goal") or "",
            "goal_categories": raw.get("goal_categories") or {},
            "outcome": raw.get("outcome") or "unclear",
            "session_type": raw.get("session_type") or "single_task",
            "friction_counts": raw.get("friction_counts") or {},
            "friction_detail": raw.get("friction_detail") or "",
            "primary_success": raw.get("primary_success") or "none",
            "satisfaction": sat,
            "brief_summary": raw.get("brief_summary") or "",
            "imported_from": "claude-native-facets",
        }
        norm, err = validate_facet(cand)
        if not err and norm:
            imported[sid] = norm
    return imported


def _block_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and isinstance(b.get("text"), str):
                parts.append(b["text"])
            elif isinstance(b, str):
                parts.append(b)
        return " ".join(parts)
    return ""


# User-role records the harness generates itself: slash-command records,
# hook feedback, delivery notices, goal check-ins, teammate relays, task
# notifications, skill-load reminders, context summaries, injected skill
# bodies. None of these is the owner interjecting.
_SYSTEM_TURN_MARKERS = (
    "Base directory for this skill:",
    "local-command",
    "<command-",
    "Stop hook feedback",
    "Cross-session delivery",
    "Goal check-in",
    "session-scoped Stop hook",
    "Another Claude session sent a message",
    "was loaded earlier",
    "is already loaded above",
    "<task-notification>",
    "continued from a previous conversation",
    "<artifact-",
    "<bash-input>",
)


def _is_owner_turn(rec, text, has_tool_result):
    """True when a user-role record is the owner's own turn (issue #77).

    System turnOrigin/promptSource always excludes; otherwise known
    harness-generated shapes are excluded by marker. Unmarked,
    unattributed turns count: new notice formats inflate until listed
    in _SYSTEM_TURN_MARKERS.
    """
    if not text or has_tool_result:
        return False
    if rec.get("turnOrigin") in ("task_notification", "system"):
        return False
    if rec.get("promptSource") == "system":
        return False
    if any(m in text for m in _SYSTEM_TURN_MARKERS):
        return False
    return True


def extract_session(path, mtime=0.0):
    """Return (meta_dict, digest_dict) for one Claude JSONL transcript."""
    sess_id = os.path.splitext(os.path.basename(path))[0]
    parent_id = _parent_from_path(path)
    project = _project_from_path(path)
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
    use_id_to_tool = {}
    first_ep = None
    last_ep = None
    last_assistant_ep = None
    git_commits = 0
    git_pushes = 0
    tokens_in = 0
    tokens_out = 0
    tokens_cache_read = 0
    tokens_cache_write = 0
    post_in = defaultdict(float)
    post_out = defaultdict(float)
    post_cr = defaultdict(float)
    post_cw = defaultdict(float)
    post_err = defaultdict(float)

    user_prompts = []
    interjection_reasons = Counter()
    assistant_tail = []
    subagent_runs = []
    error_samples = []
    touched_files = []
    touched_seen = set()

    for rec in load_json_lines(path):
        ep = ts_to_epoch(rec.get("timestamp"))
        if ep is not None:
            if first_ep is None or ep < first_ep:
                first_ep = ep
            if last_ep is None or ep > last_ep:
                last_ep = ep
        rtype = rec.get("type") or ""
        if rtype == "assistant":
            msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
            assistants += 1
            if ep is not None:
                last_assistant_ep = ep
            mdl = msg.get("model")
            if isinstance(mdl, str) and mdl:
                session_models[mdl[:60]] += 1
            usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
            inp_tok = max(0, safe_int(usage.get("input_tokens"), 0))
            cw_tok = max(0, safe_int(usage.get("cache_creation_input_tokens"), 0))
            cr_tok = max(0, safe_int(usage.get("cache_read_input_tokens"), 0))
            out_tok = max(0, safe_int(usage.get("output_tokens"), 0))
            tokens_in += inp_tok + cw_tok + cr_tok
            tokens_cache_write += cw_tok
            tokens_cache_read += cr_tok
            tokens_out += out_tok
            turn_in = inp_tok + cw_tok + cr_tok
            txt_parts = []
            blocks = msg.get("content")
            for block in (blocks if isinstance(blocks, list) else []):
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text" and isinstance(block.get("text"), str):
                    txt_parts.append(block["text"])
                elif btype == "tool_use" and block.get("name"):
                    tname = str(block["name"])
                    tools[tname] += 1
                    if block.get("id"):
                        use_id_to_tool[str(block["id"])] = tname
                    inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                    if tname == "Agent":
                        subagents += 1
                        role = str(inp.get("subagent_type") or "subagent")[:80]
                        subagent_roles[role] += 1
                        if len(subagent_runs) < 10:
                            subagent_runs.append({
                                "role": role,
                                "objective": truncate_text(inp.get("description") or inp.get("prompt") or "", 160),
                            })
                    elif tname == "Skill":
                        sk = canon_skill(inp.get("skill") or "")
                        if sk:
                            skill_loads.add(sk)
                            skill_first_turn.setdefault(sk, assistants)
                    elif tname in ("Read", "Edit", "Write", "MultiEdit"):
                        fp = str(inp.get("file_path") or "")
                        if fp:
                            lang = lang_from_path(fp)
                            if lang:
                                languages[lang] += 1
                            if fp not in touched_seen and len(touched_files) < 15:
                                touched_seen.add(fp)
                                touched_files.append(fp[-120:])
                    elif tname == "Bash":
                        cmd = str(inp.get("command") or "")
                        if re.search(r"\bgit\s+commit\b", cmd):
                            git_commits += 1
                        if re.search(r"\bgit\s+push\b", cmd):
                            git_pushes += 1
            if skill_loads and (turn_in or out_tok):
                n_sk = float(len(skill_loads))
                for sk in skill_loads:
                    post_in[sk] += turn_in / n_sk
                    post_out[sk] += out_tok / n_sk
                    post_cr[sk] += cr_tok / n_sk
                    post_cw[sk] += cw_tok / n_sk
            joined = truncate_text(" ".join(txt_parts), 280)
            if joined:
                assistant_tail.append(joined)
                if len(assistant_tail) > 3:
                    assistant_tail.pop(0)
        elif rtype == "user":
            msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
            content = msg.get("content") or []
            user_txt = ""
            has_tool_result = False
            if isinstance(content, str):
                user_txt = content
            elif isinstance(content, list):
                tparts = [
                    b["text"]
                    for b in content
                    if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
                ]
                user_txt = " ".join(tparts)
                has_tool_result = any(
                    isinstance(block, dict) and block.get("type") == "tool_result" for block in content
                )
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error"):
                        tool = use_id_to_tool.get(str(block.get("tool_use_id") or ""), "unknown")
                        errors[tool] += 1
                        if skill_loads:
                            share = 1.0 / float(len(skill_loads))
                            for sk in skill_loads:
                                post_err[sk] += share
                        etxt = _block_text(block.get("content"))
                        error_cats[categorize_error(tool, etxt)] += 1
                        if len(error_samples) < 8:
                            error_samples.append(f"{tool}: {truncate_text(etxt, 140)}")
            clean_u = truncate_text(user_txt, 260)
            if _is_owner_turn(rec, clean_u, has_tool_result):
                prompts += 1
                if prompts >= 2 and clean_u:
                    interjection_reasons[classify_interjection(clean_u)] += 1
                hr = epoch_to_utc_hour(ep)
                if hr is not None:
                    msg_hours[str(hr)] += 1
                if last_assistant_ep is not None and ep is not None and ep > last_assistant_ep:
                    gaps.append(round(ep - last_assistant_ep, 2))
                    last_assistant_ep = None
                if len(user_prompts) < 8:
                    user_prompts.append(clean_u)

    dur_min = round((last_ep - first_ep) / 60.0, 2) if (first_ep and last_ep and last_ep >= first_ep) else 0.0
    turns_after_skill_load = {
        sk: max(1, assistants - first_t + 1)
        for sk, first_t in sorted(skill_first_turn.items())
    }
    meta = {
        "meta_version": META_SCHEMA_VERSION,
        "id": sess_id,
        "harness": "claude",
        "source_path": path,
        "source_mtime": mtime,
        "project": project,
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
        "max_depth": 1 if (subagents or parent_id) else 0,
        "parent_session": parent_id,
        "child_sessions": [],
        "response_gaps": gaps,
        "message_hours": dict(msg_hours),
        "hook_blocks": {},
        "git_commits": git_commits,
        "git_pushes": git_pushes,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "tokens_cache_read": tokens_cache_read,
        "tokens_cache_write": tokens_cache_write,
        "turns_after_skill_load": turns_after_skill_load,
        "post_load_attribution": {
            sk: {
                "tokens_in": round(post_in[sk], 2),
                "tokens_out": round(post_out[sk], 2),
                "tokens_cache_read": round(post_cr[sk], 2),
                "tokens_cache_write": round(post_cw[sk], 2),
                "errors": round(post_err[sk], 2),
            }
            for sk in sorted(skill_loads)
        } if skill_loads else {},
        "interjection_reasons": dict(interjection_reasons),
    }
    digest = {
        "session_id": sess_id,
        "harness": "claude",
        "source_mtime": mtime,
        "project": project,
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

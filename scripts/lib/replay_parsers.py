#!/usr/bin/env python3
"""Pure harness stdout parsers for replay-eval (issues #103, #130).

Normalizes raw stdout from claude, agy, muse, codex, and opencode into a single
canonical trajectory dict: transcript, tools, errors, tokens_in, tokens_out,
cache_read_tokens, wall_time_s, cost_usd.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import safe_float, safe_int  # noqa: E402


def _load_last_json_obj(raw):
    text = (raw or "").strip()
    if not text:
        return {}
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except ValueError:
        pass
    for line in reversed(text.splitlines()):
        s = line.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            obj = json.loads(s)
            if isinstance(obj, dict):
                return obj
        except ValueError:
            continue
    return {}


def _iter_json_objs(raw):
    text = (raw or "").strip()
    if not text:
        return []
    try:
        single = json.loads(text)
        if isinstance(single, dict):
            return [single]
    except ValueError:
        pass
    out = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("{"):
            try:
                obj = json.loads(s)
                if isinstance(obj, dict):
                    out.append(obj)
            except ValueError:
                continue
    return out


def _parse_claude_output(stdout, wall_time_s):
    records = _iter_json_objs(stdout)
    tools, result_rec = [], None
    for rec in records:
        rtype = rec.get("type")
        if rtype == "assistant":
            msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
            for blk in (msg.get("content") if isinstance(msg.get("content"), list) else []):
                if isinstance(blk, dict) and blk.get("type") == "tool_use" and blk.get("name"):
                    tools.append(str(blk["name"]))
        if rtype == "result" or ("result" in rec and rtype is None):
            result_rec = rec
    if result_rec is None:
        return {
            "transcript": "", "tools": tools, "errors": 1,
            "tokens_in": 0.0, "tokens_out": 0.0, "cache_read_tokens": 0.0,
            "wall_time_s": round(max(0.0, safe_float(wall_time_s, 0.0)), 3), "cost_usd": 0.0,
        }
    usage = result_rec.get("usage") if isinstance(result_rec.get("usage"), dict) else {}
    cache_read = safe_float(usage.get("cache_read_input_tokens"), 0.0)
    cache_create = safe_float(usage.get("cache_creation_input_tokens"), 0.0)
    tin = safe_float(usage.get("input_tokens"), 0.0) + cache_create + cache_read
    tout = safe_float(usage.get("output_tokens"), 0.0)
    dur_ms = safe_float(result_rec.get("duration_api_ms"), 0.0) or safe_float(result_rec.get("duration_ms"), 0.0)
    dur = (dur_ms / 1000.0) if dur_ms > 0 else max(0.0, safe_float(wall_time_s, 0.0))
    if not tools and isinstance(result_rec.get("tools"), list):
        tools = [str(t) for t in result_rec["tools"]]
    return {
        "transcript": str(result_rec.get("result") or ""), "tools": tools,
        "errors": 1 if result_rec.get("is_error") else 0,
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout), "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, dur), 3),
        "cost_usd": round(max(0.0, safe_float(result_rec.get("total_cost_usd"), 0.0)), 6),
    }


def _parse_agy_output(stdout, wall_time_s):
    data = _load_last_json_obj(stdout)
    usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    cache_read = safe_float(usage.get("cache_read_tokens"), 0.0)
    tin = safe_float(usage.get("input_tokens"), 0.0) + cache_read
    tout = safe_float(usage.get("output_tokens"), 0.0)
    dur = safe_float(data.get("duration_seconds"), 0.0)
    if dur <= 0:
        dur = max(0.0, safe_float(wall_time_s, 0.0))
    status = str(data.get("status") or "").upper()
    traj = {
        "transcript": str(data.get("response") or data.get("text") or ""),
        "errors": 0 if status == "SUCCESS" else 1,
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout),
        "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, dur), 3),
        "cost_usd": round(max(0.0, safe_float(data.get("cost_usd"), 0.0)), 6),
    }
    if isinstance(data.get("tools"), list):  # absent means unmeasured, not zero
        traj["tools"] = [str(t) for t in data["tools"]]
    return traj


def _parse_muse_output(stdout, wall_time_s):
    parts, deltas, tools, started = [], [], [], {}
    terminal_text, parsed_any, errors = "", False, 0
    tin = tout = cache_read = cost_usd = dur_total = 0.0

    for rec in _iter_json_objs(stdout):
        parsed_any = True
        pl = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        inner = pl.get("record") if isinstance(pl.get("record"), dict) else (pl or rec)
        ev = pl.get("event") if isinstance(pl.get("event"), dict) else rec.get("event")
        ev = ev if isinstance(ev, dict) else {}
        pt = str(rec.get("payload_type") or rec.get("type") or rec.get("kind") or "")
        pk = str(pl.get("kind") or "")
        ek = str(ev.get("kind") or ev.get("type") or "")

        if ek == "assistant_message_committed" or pt == "assistant_message_committed":
            txt = ev.get("text") if ek == "assistant_message_committed" else (inner.get("text") or rec.get("text"))
            if isinstance(txt, str) and txt.strip():
                parts.append(txt.strip())
        elif pt == "run.output.delta" or pk == "run_output_delta":
            if isinstance(pl.get("text"), str):
                deltas.append(pl["text"])
        elif pt.startswith("run.terminal.") or pk == "run_terminal":
            if isinstance(pl.get("text"), str) and pl["text"].strip():
                terminal_text = pl["text"].strip()
            term = str(pl.get("terminal") or "")
            if term and term != "completed":
                errors += 1
        elif pt == "run.usage" or pk == "run_usage":
            for m in (pl.get("models") if isinstance(pl.get("models"), list) else []):
                if isinstance(m, dict):
                    cache_read += safe_float(m.get("cached_tokens"), 0.0)
                    tin += safe_float(m.get("input_tokens"), 0.0)
                    tout += safe_float(m.get("output_tokens"), 0.0)
            errors += max(0, safe_int(pl.get("failed_calls"), 0))
        elif pt == "tool_batch.effect.started" or ek == "tool_batch.effect.started":
            src = ev if ek == "tool_batch.effect.started" else inner
            cid = str(src.get("call_id") or "")
            if cid:
                started[cid] = str(src.get("tool_name") or "unknown")
        elif pt == "tool_batch.effect.terminal" or ek == "tool_batch.effect.terminal":
            src = ev if ek == "tool_batch.effect.terminal" else inner
            cid = str(src.get("call_id") or "")
            tools.append(str(src.get("tool_name") or started.get(cid) or "unknown"))
            outcome = src.get("outcome")
            kind = outcome.get("kind") if isinstance(outcome, dict) else outcome
            if kind != "completed":
                errors += 1
        elif ek == "model_completed" or pt == "model_completed":
            src = ev if ek == "model_completed" else inner
            usage = src.get("usage") if isinstance(src.get("usage"), dict) else {}
            cr = safe_float(usage.get("cache_read_tokens"), 0.0) or safe_float(usage.get("cache_read_input_tokens"), 0.0)
            cache_read += cr
            tin += safe_float(usage.get("input_tokens"), 0.0) + cr
            tout += safe_float(usage.get("output_tokens"), 0.0)
            cost_usd += safe_float(src.get("cost_usd"), 0.0) or safe_float(usage.get("cost_usd"), 0.0)
            ds, dm = safe_float(src.get("duration_seconds"), 0.0), safe_float(src.get("duration_ms"), 0.0)
            dur_total += ds if ds > 0 else ((dm / 1000.0) if dm > 0 else 0.0)

    if not parsed_any:
        errors = max(errors, 1)
    transcript = terminal_text or ("\n".join(parts) if parts else "".join(deltas).strip())
    dur = dur_total if dur_total > 0 else max(0.0, safe_float(wall_time_s, 0.0))
    return {
        "transcript": transcript, "tools": tools, "errors": max(0, errors),
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout), "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, dur), 3), "cost_usd": round(max(0.0, cost_usd), 6),
    }


def _parse_codex_output(stdout, wall_time_s):
    """Parse `codex exec --json` JSONL stream."""
    records = _iter_json_objs(stdout)
    parts, tools = [], []
    errors = 0
    tin = tout = cache_read = 0.0
    for rec in records:
        rtype = str(rec.get("type") or "")
        if rtype == "item.completed":
            item = rec.get("item") if isinstance(rec.get("item"), dict) else {}
            itype = str(item.get("type") or "")
            if itype == "agent_message" and isinstance(item.get("text"), str) and item["text"].strip():
                parts.append(item["text"].strip())
            elif itype in ("command_execution", "mcp_tool_call", "file_change", "web_search"):
                tname = str(item.get("tool") or item.get("name") or itype)
                tools.append(tname)
                ec = item.get("exit_code")
                if (isinstance(ec, int) and ec != 0) or str(item.get("status") or "").lower() in ("failed", "error"):
                    errors += 1
        elif rtype == "turn.completed":
            usage = rec.get("usage") if isinstance(rec.get("usage"), dict) else {}
            tin += safe_float(usage.get("input_tokens"), 0.0)
            cache_read += safe_float(usage.get("cached_input_tokens"), 0.0)
            tout += safe_float(usage.get("output_tokens"), 0.0)
        elif rtype in ("turn.failed", "error"):
            errors += 1
    if not records:
        errors = max(errors, 1)
    return {
        "transcript": "\n".join(parts), "tools": tools, "errors": max(0, errors),
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout),
        "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, safe_float(wall_time_s, 0.0)), 3), "cost_usd": 0.0,
    }


def _parse_opencode_output(stdout, wall_time_s):
    """Parse `opencode run --format json` JSONL stream."""
    records = _iter_json_objs(stdout)
    parts, tools = [], []
    errors = 0
    tin = tout = cache_read = cost_usd = 0.0
    for rec in records:
        rtype = str(rec.get("type") or "")
        part = rec.get("part") if isinstance(rec.get("part"), dict) else {}
        if rtype == "text":
            txt = part.get("text") if isinstance(part.get("text"), str) else rec.get("text")
            if isinstance(txt, str) and txt.strip():
                parts.append(txt.strip())
        elif rtype in ("tool_use", "tool"):
            tname = str(part.get("tool") or part.get("name") or rec.get("tool") or "tool")
            tools.append(tname)
            st = part.get("state") if isinstance(part.get("state"), dict) else {}
            if str(st.get("status") or "").lower() == "error" or st.get("error"):
                errors += 1
        elif rtype == "step_finish":
            tok = part.get("tokens") if isinstance(part.get("tokens"), dict) else {}
            cache = tok.get("cache") if isinstance(tok.get("cache"), dict) else {}
            cr = safe_float(cache.get("read"), 0.0)
            cw = safe_float(cache.get("write"), 0.0)
            cache_read += cr
            tin += safe_float(tok.get("input"), 0.0) + cr + cw
            tout += safe_float(tok.get("output"), 0.0)
            cost_usd += safe_float(part.get("cost"), 0.0)
        elif rtype == "error":
            errors += 1
    if not records:
        errors = max(errors, 1)
    return {
        "transcript": "\n".join(parts), "tools": tools, "errors": max(0, errors),
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout),
        "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, safe_float(wall_time_s, 0.0)), 3),
        "cost_usd": round(max(0.0, cost_usd), 6),
    }


def parse_harness_output(harness, stdout, wall_time_s=0.0):
    """Pure parser from raw harness stdout to canonical trajectory dict."""
    if harness == "claude":
        return _parse_claude_output(stdout, wall_time_s)
    if harness == "agy":
        return _parse_agy_output(stdout, wall_time_s)
    if harness == "muse":
        return _parse_muse_output(stdout, wall_time_s)
    if harness == "codex":
        return _parse_codex_output(stdout, wall_time_s)
    if harness == "opencode":
        return _parse_opencode_output(stdout, wall_time_s)
    raise ValueError("unsupported harness: %r" % harness)

#!/usr/bin/env python3
"""Flexible scoping for /debrief: --current, --session, --sessions-file, --all-time, and sessions listing."""
import hashlib
import html
import json
import os
import sys
import time

from debrief_common import VALID_HARNESSES, resolve_since, safe_int


def _fail(msg, code=2):
    sys.stderr.write(str(msg).rstrip("\n") + "\n")
    raise SystemExit(code)

CURRENT_ENV_VARS = (
    ("CLAUDE_SESSION_ID", "claude"),
    ("MUSE_SESSION_ID", "muse"),
    ("OPENCODE_SESSION_ID", "opencode"),
    ("CODEX_THREAD_ID", "codex"),
    ("AGY_CONVERSATION_ID", "agy"),
    ("CONVERSATION_ID", "agy"),
)

CURRENT_RECENCY_WINDOW_S = 900.0   # 15 minutes for CWD-based current-session detection
AMBIGUITY_WINDOW_S = 60.0          # two active sessions within 60s -> fail closed & ask


def parse_harnesses_strict(raw):
    """Parse comma-separated harnesses; accept 'all' or empty; exit 2 on unknown names."""
    if not raw or not str(raw).strip():
        return list(VALID_HARNESSES)
    tokens = [t.strip().lower() for t in str(raw).split(",") if t.strip()]
    if not tokens:
        return list(VALID_HARNESSES)
    invalid = [t for t in tokens if t not in VALID_HARNESSES and t != "all"]
    if invalid:
        valid = ", ".join((*VALID_HARNESSES, "all"))
        _fail(
            f"debrief: unknown --harness value(s): {', '.join(invalid)} (valid: {valid})"
        )
    if "all" in tokens:
        return list(VALID_HARNESSES)
    seen = []
    for t in tokens:
        if t not in seen:
            seen.append(t)
    return seen


def resolve_window(since, days, all_time=False, explicit_sessions=False, days_explicit=False):
    """Resolve (since_str, since_epoch) honoring --all-time and explicit session IDs."""
    if all_time and (since or days_explicit):
        _fail("debrief: --all-time cannot be combined with --since or --days")
    if all_time:
        return "", 0.0
    if explicit_sessions and not since and not days_explicit:
        return "", 0.0
    return resolve_since(since or "", days if days is not None else 30)


def parse_session_specs(session_args, sessions_file=""):
    """Parse repeatable --session values and optional --sessions-file into [(harness|None, id_token)]."""
    raw_items = []
    for entry in session_args or []:
        for piece in str(entry).split(","):
            piece = piece.strip()
            if piece:
                raw_items.append(piece)
    if sessions_file:
        if not os.path.isfile(sessions_file):
            _fail(f"debrief: --sessions-file not found: {sessions_file}")
        with open(sessions_file, encoding="utf-8") as fh:
            text = fh.read().strip()
        if text.startswith("["):
            try:
                arr = json.loads(text)
            except Exception as exc:
                _fail(f"debrief: invalid JSON in --sessions-file {sessions_file}: {exc}")
            if not isinstance(arr, list):
                _fail(f"debrief: --sessions-file JSON must be an array: {sessions_file}")
            for item in arr:
                s = str(item).strip()
                if s:
                    raw_items.append(s)
        else:
            for line in text.splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    raw_items.append(line)

    specs = []
    seen = set()
    for item in raw_items:
        h_filt = None
        tok = item
        if ":" in item:
            left, _, right = item.partition(":")
            cand_h = left.strip().lower()
            if cand_h in VALID_HARNESSES and right.strip():
                h_filt = cand_h
                tok = right.strip()
        if not tok:
            continue
        key = (h_filt, tok)
        if key not in seen:
            seen.add(key)
            specs.append(key)
    return specs


def _norm_path(p):
    if not p:
        return ""
    try:
        return os.path.realpath(str(p).rstrip("/"))
    except OSError:
        return str(p).rstrip("/")


def _cwd_matches(meta, cwd_norm, cwd_base):
    if not cwd_norm:
        return False
    proj = str(meta.get("project") or "")
    if proj:
        pn = _norm_path(proj)
        if pn == cwd_norm or os.path.basename(pn) == cwd_base:
            return True
    for ws in meta.get("workspaces") or []:
        wn = _norm_path(ws)
        if wn == cwd_norm or os.path.basename(wn) == cwd_base:
            return True
    return False


def _meta_epoch(m):
    for key in ("last_epoch", "source_mtime", "first_epoch"):
        val = m.get(key)
        if isinstance(val, (int, float)) and val > 0:
            return float(val)
    return 0.0


def resolve_current_session(metas_by_key, harnesses, cwd=None, env=None, now_epoch=None):
    """Resolve the active session via harness env vars or CWD recency.

    Returns a single-item spec list [(harness|None, session_id)] or exits 2
    when no active session is found or multiple sessions are ambiguously active.
    """
    env_map = env if env is not None else os.environ
    for var, h in CURRENT_ENV_VARS:
        val = str(env_map.get(var) or "").strip()
        if val and h in harnesses:
            return [(h, val)]

    # Fallback: match top-level sessions touching cwd within CURRENT_RECENCY_WINDOW_S.
    now = float(now_epoch) if now_epoch is not None else time.time()
    cwd_norm = _norm_path(cwd or os.getcwd())
    cwd_base = os.path.basename(cwd_norm)
    child_ids = set()
    for m in metas_by_key.values():
        h = m.get("harness")
        for cid in m.get("child_sessions") or []:
            child_ids.add((h, cid))

    recent = []
    for m in metas_by_key.values():
        h = m.get("harness")
        if h not in harnesses:
            continue
        if m.get("parent_session") or (h, m.get("id")) in child_ids:
            continue
        ep = _meta_epoch(m)
        if ep <= 0 or (now - ep) > CURRENT_RECENCY_WINDOW_S:
            continue
        if _cwd_matches(m, cwd_norm, cwd_base):
            recent.append((ep, h, str(m.get("id") or "")))

    if not recent:
        _fail(
            "debrief: --current found no active session for this workspace within the last 15m; "
            "run `scripts/debrief.sh sessions` and pass `--session <id>`"
        )
    recent.sort(key=lambda x: x[0], reverse=True)
    top_ep = recent[0][0]
    close = [r for r in recent if (top_ep - r[0]) <= AMBIGUITY_WINDOW_S]
    if len(close) > 1:
        cands = ", ".join(f"{h}:{sid[:16]}" for _, h, sid in close[:5])
        _fail(
            f"debrief: --current is ambiguous ({len(close)} sessions active within 60s: {cands}); "
            "pass `--harness <name>` or `--session <id>`"
        )
    return [(recent[0][1], recent[0][2])]


def filter_metas_by_sessions(metas_by_key, specs, include_children=True):
    """Filter metas_by_key to sessions matching specs (+ descendant children).

    Returns (filtered_metas, matched_top_keys, missing_specs).
    Exits 2 on ambiguous prefix or when zero requested sessions match.
    """
    matched_roots = []
    matched_set = set()
    missing = []
    for h_filt, tok in specs:
        exact = [
            k for k, m in metas_by_key.items()
            if (not h_filt or m.get("harness") == h_filt) and str(m.get("id") or "") == tok
        ]
        hits = exact
        if not hits and len(tok) >= 8:
            hits = [
                k for k, m in metas_by_key.items()
                if (not h_filt or m.get("harness") == h_filt)
                and str(m.get("id") or "").startswith(tok)
            ]
        if len(hits) > 1:
            labels = ", ".join(
                f"{metas_by_key[k]['harness']}:{metas_by_key[k]['id'][:16]}" for k in sorted(hits)[:5]
            )
            _fail(
                f"debrief: --session '{tok}' matches multiple sessions ({labels}); pass a longer prefix or <harness>:<id>"
            )
        if not hits:
            missing.append(f"{h_filt}:{tok}" if h_filt else tok)
            continue
        k = hits[0]
        if k not in matched_set:
            matched_set.add(k)
            matched_roots.append(k)

    if not matched_roots:
        _fail(
            f"debrief: no sessions matched --session: {', '.join(missing)}"
        )
    if missing:
        sys.stderr.write(
            f"debrief: warning: unmatched --session spec(s) omitted: {', '.join(missing)}\n"
        )

    selected = set(matched_roots)
    if include_children:
        by_id = {(m["harness"], m["id"]): k for k, m in metas_by_key.items()}
        parent_to_kids = {}
        for k, m in metas_by_key.items():
            h = m["harness"]
            pid = m.get("parent_session")
            if pid and (h, pid) in by_id:
                parent_to_kids.setdefault(by_id[(h, pid)], set()).add(k)
            for cid in m.get("child_sessions") or []:
                ck = by_id.get((h, cid))
                if ck:
                    parent_to_kids.setdefault(k, set()).add(ck)
        frontier = list(matched_roots)
        while frontier:
            cur = frontier.pop()
            for ck in parent_to_kids.get(cur, ()):
                if ck not in selected:
                    selected.add(ck)
                    frontier.append(ck)

    filtered = {k: metas_by_key[k] for k in selected}
    return filtered, matched_roots, missing


def filter_hook_events_by_sessions(hook_events, metas_by_key):
    """Restrict hook events to sessions present in metas_by_key (12-char sid prefix match)."""
    allowed = set()
    for m in metas_by_key.values():
        sid = str(m.get("id") or "")
        if sid:
            allowed.add(sid[:12])
            allowed.add(sid)
    if not allowed:
        return []
    out = []
    for ev in hook_events:
        esid = str(ev.get("session") or "")
        if esid and (esid in allowed or esid[:12] in allowed):
            out.append(ev)
    return out


def build_scope_meta(harnesses, project, since_str, days, all_time, session_ids=None, missing_sessions=None):
    """Build normalized scope metadata + deterministic scope_key for snapshot pairing."""
    sids = sorted(set(session_ids or []))
    if sids:
        mode = "session" if len(sids) == 1 else "sessions"
    elif project:
        mode = "project"
    elif len(harnesses) < len(VALID_HARNESSES):
        mode = "harness"
    else:
        mode = "all"
    key_payload = json.dumps(
        {
            "mode": mode,
            "harnesses": sorted(harnesses),
            "project": project or "",
            "all_time": bool(all_time),
            "days": None if (all_time or sids) else int(days),
            "session_ids": sids if len(sids) <= 20 else [f"count:{len(sids)}"],
        },
        sort_keys=True,
    )
    scope_key = hashlib.sha256(key_payload.encode("utf-8")).hexdigest()[:12]
    return {
        "mode": mode,
        "scope_key": scope_key,
        "harnesses": list(harnesses),
        "project": project or None,
        "all_time": bool(all_time),
        "since": since_str or None,
        "days": None if (all_time or sids) else int(days),
        "session_ids": sids,
        "missing_sessions": list(missing_sessions or []),
    }


def session_detail_rows(metas_by_key, children_keys, facets_by_key, limit=25):
    """Build compact per-session detail rows for explicit-session or single-session reports."""
    rows = []
    for k, m in metas_by_key.items():
        if k in children_keys:
            continue
        f = facets_by_key.get(k) or {}
        errs = sum((m.get("errors") or {}).values())
        rows.append({
            "session_id": str(m.get("id") or ""),
            "harness": str(m.get("harness") or ""),
            "project": os.path.basename(str(m.get("project") or "").rstrip("/")) or "unknown",
            "first_ts": m.get("first_ts") or "",
            "last_ts": m.get("last_ts") or "",
            "prompts": safe_int(m.get("prompts"), 0),
            "tool_calls": safe_int(m.get("tool_calls"), 0),
            "errors": safe_int(errs, 0),
            "skills": sorted(set(m.get("skill_loads") or [])),
            "child_count": len(m.get("child_sessions") or []),
            "outcome": f.get("outcome") or None,
            "goal": f.get("underlying_goal") or None,
            "friction_detail": f.get("friction_detail") or None,
            "source_mtime": _meta_epoch(m),
        })
    rows.sort(key=lambda r: (-r["source_mtime"], r["session_id"]))
    return rows[:limit]


def render_single_session_banner(agg):
    """Render a Session Deep-Dive card when the debrief targets a single top-level session."""
    meta = agg.get("meta") or {}
    if safe_int(meta.get("top_level_sessions"), 0) != 1:
        return ""
    details = agg.get("sessions_detail") or []
    if not details:
        return ""
    d = details[0]
    esc = lambda v: html.escape(str(v if v is not None else ""), quote=True)
    skills = ", ".join(d.get("skills") or []) or "none"
    goal = d.get("goal") or "Not yet classified (run prepare + Stage 2 facets for goal/outcome)."
    outcome = d.get("outcome") or "unclassified"
    fric = d.get("friction_detail") or ""
    fric_html = f'<div style="margin-top:6px;color:#991b1b"><strong>Friction:</strong> {esc(fric)}</div>' if fric else ""
    return (
        '<div class="at-a-glance" style="border-left:4px solid #0284c7;margin-bottom:20px">'
        '<div class="glance-title">Session Deep-Dive</div>'
        f'<div style="font-size:13px;color:#334155;line-height:1.6">'
        f'<strong>Session:</strong> <code>{esc(d.get("session_id"))}</code> '
        f'&middot; <strong>Harness:</strong> {esc(d.get("harness"))} '
        f'&middot; <strong>Project:</strong> {esc(d.get("project"))} '
        f'&middot; <strong>Outcome:</strong> <code>{esc(outcome)}</code><br>'
        f'<strong>Activity:</strong> {safe_int(d.get("prompts"))} prompts, '
        f'{safe_int(d.get("tool_calls"))} tool calls, {safe_int(d.get("errors"))} errors, '
        f'{safe_int(d.get("child_count"))} subagents &middot; <strong>Skills:</strong> {esc(skills)}<br>'
        f'<strong>Goal:</strong> {esc(goal)}{fric_html}'
        '</div></div>'
    )

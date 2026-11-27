#!/usr/bin/env python3
"""Hook telemetry aggregation for the /debrief v2 pipeline.

Moved out of ``debrief_aggregate.py`` to keep that module under the 500-line
limit. Joins hook ``skill-load`` windows with mined skill loads and folds
per-skill attributed cost fields (issue #80) into each skill-table row.
"""
import json
import os
import re
import subprocess
from collections import Counter, defaultdict

from debrief_common import (  # noqa: E402
    canon_skill,
    is_fixture_session,
    load_json_lines,
    safe_int,
    safe_key,
)


def _read_hook_events(log_paths, since_str):
    events = []
    dropped = 0
    for p in log_paths:
        if not p or not os.path.isfile(p):
            continue
        for ev in load_json_lines(p):
            if since_str and str(ev.get("ts") or "") < since_str:
                continue
            sid = str(ev.get("session") or "")
            if not sid:
                continue
            if is_fixture_session(sid):
                dropped += 1
                continue
            events.append(ev)
    return events, dropped


def _aggregate_hooks(hook_events, mined_skills, skill_costs_by_skill=None, metas=None):
    """Join hook loads with mined loads; each row also carries cost fields.

    ``mined_skills`` maps canonical skill to mined load count (Counter or
    dict). ``skill_costs_by_skill`` maps canonical skill to its
    ``attribute_skill_costs`` per-skill row (attributed_tokens_in/out/total,
    attributed_errors, token_bearing_sessions); skills absent from it report
    zeros. ``metas`` (session metas) feeds ``hooks_summary["agy"]``. Returns
    ``(skill_table, hooks_summary)``.
    """
    hook_loads = Counter()
    hook_forced = Counter()
    nudge_blocked = Counter()
    model_failures = Counter()
    sessions = defaultdict(lambda: {"skills": set(), "blocked": set(), "goal": False, "progressed": False, "outcome": None})
    goal_done = goal_released = goal_blocked_watcher = 0

    for ev in hook_events:
        sid = str(ev.get("session") or "")
        etype = str(ev.get("type") or "")
        det = ev.get("detail") if isinstance(ev.get("detail"), dict) else {}
        st = sessions[sid]
        if etype == "nudge-block":
            for sk in det.get("skills") or []:
                c = canon_skill(sk)
                if c:
                    st["blocked"].add(c)
                    nudge_blocked[c] += 1
        elif etype == "goal-continued":
            st["goal"] = True
            if safe_int(det.get("progress"), 0) > 0:
                st["progressed"] = True
        elif etype == "goal-done":
            st["goal"] = True
            st["outcome"] = "done"
            goal_done += 1
        elif etype == "goal-released":
            st["goal"] = True
            st["outcome"] = "released"
            goal_released += 1
        elif etype == "goal-blocked-watcher":
            st["goal"] = True
            goal_blocked_watcher += 1
        elif etype == "model-failure":
            cat = str(det.get("category") or "unknown")
            model_failures[cat] += 1

    for ev in hook_events:
        if ev.get("type") == "skill-load":
            sid = str(ev.get("session") or "")
            det = ev.get("detail") if isinstance(ev.get("detail"), dict) else {}
            sk = canon_skill(det.get("skill") or "")
            if sk:
                hook_loads[sk] += 1
                sessions[sid]["skills"].add(sk)
                if sk in sessions[sid]["blocked"]:
                    hook_forced[sk] += 1

    if isinstance(mined_skills, Counter):
        mined_counts = mined_skills
    else:
        mined_counts = Counter(dict(mined_skills or {}))
    costs = skill_costs_by_skill or {}
    all_sk = sorted(set(hook_loads) | set(mined_counts),
                    key=lambda s: (-(mined_counts[s] + hook_loads[s]), s))
    skill_table = []
    for s in all_sk[:25]:
        goal_s = [st for st in sessions.values() if s in st["skills"] and st["goal"]]
        no_prog = sum(1 for st in goal_s if not st["progressed"] and st["outcome"] != "done")
        cost = costs.get(s) or {}
        skill_table.append({
            "skill": s,
            "hook_loads": hook_loads[s],
            "forced": hook_forced[s],
            "forced_pct": round(100 * hook_forced[s] / hook_loads[s]) if hook_loads[s] else None,
            "mined_loads": mined_counts[s],
            "goal_sessions": len(goal_s),
            "no_progress_share_pct": round(100 * no_prog / len(goal_s)) if goal_s else None,
            "attributed_tokens_in": cost.get("attributed_tokens_in", 0.0),
            "attributed_tokens_out": cost.get("attributed_tokens_out", 0.0),
            "attributed_tokens_total": cost.get("attributed_tokens_total", 0.0),
            "attributed_cache_read": cost.get("attributed_cache_read", 0.0),
            "attributed_cache_write": cost.get("attributed_cache_write", 0.0),
            "attributed_errors": cost.get("attributed_errors", 0.0),
            "error_rate_per_session": cost.get("error_rate_per_session", 0.0),
            "token_bearing_sessions": cost.get("token_bearing_sessions", 0),
            "median_gap_s": cost.get("median_gap_s"),
            "median_duration_min": cost.get("median_duration_min"),
            "estimated_context_tax_tokens": cost.get("estimated_context_tax_tokens", 0.0),
        })

    hooks_summary = {
        "events": len(hook_events),
        "sessions": len(sessions),
        "goal_done": goal_done,
        "goal_released": goal_released,
        "goal_blocked_watcher": goal_blocked_watcher,
        "nudge_blocked": dict(nudge_blocked.most_common(12)),
        "model_failures": dict(model_failures.most_common(12)),
        "agy": agy_hook_join(metas or {}, hook_events),
    }
    return skill_table, hooks_summary


def agy_hook_join(metas, hook_events):
    """Join agy hook events to mined agy sessions.

    A hook event's ``session`` is the conversationId sanitized and cut to 12
    characters (``si_event``), so an agy meta ``id`` is reduced the same way.
    """
    def key(sid):
        return re.sub(r"[^A-Za-z0-9._-]", "-", str(sid or ""))[:12]

    agy_ids = {key(m.get("id")) for m in metas.values() if m.get("harness") == "agy"}
    agy_events = [e for e in hook_events if str(e.get("harness") or "") == "agy"]
    joined = agy_ids & {key(e.get("session")) for e in agy_events}
    return {"sessions": len(agy_ids), "hook_events": len(agy_events), "sessions_with_hook_events": len(joined)}


def agy_hook_caveats(join):
    """``not_tracked`` line when agy sessions exist but no agy hook event does."""
    if not join["sessions"] or join["hook_events"]:
        return []
    return [
        "Antigravity (agy) hook telemetry is absent from this window (agy hooks are opt-in: "
        "./install.sh --hooks --repo, or --hooks --global agy); agy skill loads come from transcript mining."
    ]


PAPERCUT_SKILL_RE = re.compile(r"^\s*skill\s*:\s*[`'\"]?([A-Za-z0-9_.:-]+)", re.IGNORECASE | re.MULTILINE)


def papercut_stats(path):
    """Per-skill papercut filed, open, and fixed counts from a snapshot file.

    The snapshot is JSON exported out of band (e.g. ``gh issue list --label
    papercut --json number,title,body,state,stateReason``), either a bare
    array or ``{"issues": [...]}``. The join key is the required ``skill:``
    body line the papercut template asks for; issues without one count as
    unmatched, never as zero-skill findings. Open means state == OPEN; fixed
    means CLOSED for a reason other than NOT_PLANNED. Offline only: no network calls.
    """
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"aggregate: cannot read --papercuts snapshot {path!r}: {exc}")
    if isinstance(raw, dict):
        for key in ("issues", "papercuts"):
            if isinstance(raw.get(key), list):
                raw = raw[key]
                break
    if not isinstance(raw, list):
        raise SystemExit(f"aggregate: --papercuts snapshot {path!r} must be a JSON array or {{\"issues\": [...]}}")
    per_skill = {}
    unmatched = 0
    for rec in raw:
        if not isinstance(rec, dict):
            unmatched += 1
            continue
        match = PAPERCUT_SKILL_RE.search(str(rec.get("body") or ""))
        # Sentence-final periods are prose, not part of the name ("skill: debrief." joins debrief).
        skill = canon_skill(match.group(1).rstrip(".")) if match else ""
        if not skill:
            unmatched += 1
            continue
        entry = per_skill.setdefault(skill, {"filed": 0, "open": 0, "fixed": 0})
        entry["filed"] += 1
        state = str(rec.get("state") or "").upper()
        reason = str(rec.get("stateReason") or "").upper()
        if state == "OPEN":
            entry["open"] += 1
        elif state == "CLOSED" and reason != "NOT_PLANNED":
            entry["fixed"] += 1
    return {
        "snapshot": path,
        "total_filed": sum(e["filed"] for e in per_skill.values()),
        "total_open": sum(e["open"] for e in per_skill.values()),
        "total_fixed": sum(e["fixed"] for e in per_skill.values()),
        "unmatched_without_skill": unmatched,
        "per_skill": dict(sorted(per_skill.items())),
    }


def _collect_git_stats(path, since_str):
    if not os.path.isdir(os.path.join(path, ".git")):
        return {"path": path, "name": os.path.basename(os.path.normpath(path)) or path, "unreadable": True}
    cmd = ["git", "-C", path, "log", "--pretty=%H %P %s", "--numstat"]
    if since_str:
        w = since_str + "T00:00:00Z" if re.fullmatch(r"\d{4}-\d{2}-\d{2}", since_str) else since_str
        cmd += ["--since=" + w]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {"path": path, "name": os.path.basename(os.path.normpath(path)) or path, "unreadable": True}
    if out.returncode != 0:
        return {"path": path, "name": os.path.basename(os.path.normpath(path)) or path, "unreadable": True}
    commits = merges = reverts = files = added = deleted = 0
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].strip().isdigit() and parts[1].strip().isdigit():
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
    return {
        "path": path,
        "name": os.path.basename(os.path.normpath(path)) or path,
        "commits": commits,
        "merges": merges,
        "reverts": reverts,
        "files": files,
        "added": added,
        "deleted": deleted,
    }


def _compute_overlap(metas):
    """Detect parallel overlapping top-level sessions (Multi-Agenting)."""
    intervals = []
    for m in metas:
        s, e = m.get("first_epoch"), m.get("last_epoch")
        if isinstance(s, (int, float)) and isinstance(e, (int, float)) and e > s + 10:
            intervals.append((s, e, safe_key(m["harness"], m["id"])))
    intervals.sort()
    involved = set()
    overlap_events = 0
    active = []
    for s, e, k in intervals:
        active = [(ae, ak) for ae, ak in active if ae > s]
        if active:
            overlap_events += 1
            involved.add(k)
            for _, ak in active:
                involved.add(ak)
        active.append((e, k))
    total_msgs = sum(m.get("prompts", 0) for m in metas) or 1
    ov_msgs = sum(m.get("prompts", 0) for m in metas if safe_key(m["harness"], m["id"]) in involved)
    return {
        "overlap_events": overlap_events,
        "sessions_involved": len(involved),
        "pct_of_messages": round(100.0 * ov_msgs / total_msgs),
    }

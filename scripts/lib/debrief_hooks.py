#!/usr/bin/env python3
"""Hook telemetry aggregation for the /debrief v2 pipeline.

Moved out of ``debrief_aggregate.py`` to keep that module under the 500-line
limit. Joins hook ``skill-load`` windows with mined skill loads and folds
per-skill attributed cost fields (issue #80) into each skill-table row.
"""
import os
from collections import Counter, defaultdict

from debrief_common import (  # noqa: E402
    canon_skill,
    is_fixture_session,
    load_json_lines,
    safe_int,
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


def _aggregate_hooks(hook_events, mined_skills, skill_costs_by_skill=None):
    """Join hook loads with mined loads; each row also carries cost fields.

    ``mined_skills`` maps canonical skill to mined load count (Counter or
    dict). ``skill_costs_by_skill`` maps canonical skill to its
    ``attribute_skill_costs`` per-skill row (attributed_tokens_in/out/total,
    attributed_errors, token_bearing_sessions); skills absent from it report
    zeros. Returns ``(skill_table, hooks_summary)``.
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
            "attributed_errors": cost.get("attributed_errors", 0.0),
            "token_bearing_sessions": cost.get("token_bearing_sessions", 0),
        })

    hooks_summary = {
        "events": len(hook_events),
        "sessions": len(sessions),
        "goal_done": goal_done,
        "goal_released": goal_released,
        "goal_blocked_watcher": goal_blocked_watcher,
        "nudge_blocked": dict(nudge_blocked.most_common(12)),
        "model_failures": dict(model_failures.most_common(12)),
    }
    return skill_table, hooks_summary

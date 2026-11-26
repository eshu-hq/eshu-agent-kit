#!/usr/bin/env python3
"""Debrief v2 aggregation: Stage 1 meta + Stage 2 facets + hook logs + git stats."""
import datetime
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_common import (  # noqa: E402
    atomic_write_json,
    canon_skill,
    default_cache_dir,
    default_usage_log,
    gap_bucket,
    is_fixture_session,
    load_json_lines,
    read_json,
    resolve_since,
    safe_int,
    safe_key,
)


def parse_harnesses(raw):
    if not raw:
        return ["muse", "agy", "claude"]
    out = [h.strip().lower() for h in raw.split(",") if h.strip().lower() in ("muse", "agy", "claude")]
    return out or ["muse", "agy", "claude"]


def inherit_parent_projects(metas_by_key):
    """Propagate parent project/workspaces to linked children missing their own."""
    by_id = {(m["harness"], m["id"]): m for m in metas_by_key.values()}
    parent_map = {}
    for m in metas_by_key.values():
        h = m["harness"]
        pid = m.get("parent_session")
        if pid and (h, pid) in by_id and by_id[(h, pid)] is not m:
            parent_map[(h, m["id"])] = by_id[(h, pid)]
        for cid in m.get("child_sessions") or []:
            cm = by_id.get((h, cid))
            if cm and cm is not m:
                parent_map[(h, cid)] = m
    for m in metas_by_key.values():
        if m.get("project") or m.get("workspaces"):
            continue
        cur = m
        seen = set()
        while (cur["harness"], cur["id"]) in parent_map:
            key = (cur["harness"], cur["id"])
            if key in seen:
                break
            seen.add(key)
            cur = parent_map[key]
            if cur.get("project") or cur.get("workspaces"):
                if cur.get("project"):
                    m["project"] = cur["project"]
                if cur.get("workspaces"):
                    m["workspaces"] = list(cur["workspaces"])
                break


def project_match(meta, want):
    if not want:
        return True
    w = want.lower()
    proj = str(meta.get("project") or "").lower()
    if proj and w in proj:
        return True
    for ws in meta.get("workspaces") or []:
        if w in str(ws).lower():
            return True
    return False


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


def _aggregate_hooks(hook_events, mined_skills):
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

    all_sk = sorted(set(hook_loads) | set(mined_skills),
                    key=lambda s: (-(mined_skills[s] + hook_loads[s]), s))
    skill_table = []
    for s in all_sk[:25]:
        goal_s = [st for st in sessions.values() if s in st["skills"] and st["goal"]]
        no_prog = sum(1 for st in goal_s if not st["progressed"] and st["outcome"] != "done")
        skill_table.append({
            "skill": s,
            "hook_loads": hook_loads[s],
            "forced": hook_forced[s],
            "forced_pct": round(100 * hook_forced[s] / hook_loads[s]) if hook_loads[s] else None,
            "mined_loads": mined_skills[s],
            "goal_sessions": len(goal_s),
            "no_progress_share_pct": round(100 * no_prog / len(goal_s)) if goal_s else None,
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


def cmd_aggregate(args):
    since_str, since_ep = resolve_since(args.since, args.days)
    harnesses = parse_harnesses(args.harness)
    cache_dir = args.cache_dir or default_cache_dir()
    meta_dir = os.path.join(cache_dir, "meta")
    facets_dir = os.path.join(cache_dir, "facets")

    metas = {}
    if os.path.isdir(meta_dir):
        for fn in os.listdir(meta_dir):
            if not fn.endswith(".json"):
                continue
            m = read_json(os.path.join(meta_dir, fn))
            if not m or m.get("harness") not in harnesses:
                continue
            mt = float(m.get("source_mtime") or 0)
            fe = m.get("last_epoch") or m.get("first_epoch") or mt
            if since_ep and float(fe or 0) < since_ep and mt < since_ep:
                continue
            k = safe_key(m["harness"], m["id"])
            if k not in metas or mt > float(metas[k].get("source_mtime") or 0):
                metas[k] = m

    inherit_parent_projects(metas)
    if args.project:
        metas = {k: m for k, m in metas.items() if project_match(m, args.project)}

    by_id = {(m["harness"], m["id"]): k for k, m in metas.items()}
    children = set()
    for k, m in metas.items():
        pid = m.get("parent_session")
        if pid and (m["harness"], pid) in by_id and by_id[(m["harness"], pid)] != k:
            children.add(k)
        for cid in m.get("child_sessions") or []:
            ck = by_id.get((m["harness"], cid))
            if ck and ck != k:
                children.add(ck)

    top_metas = [m for k, m in metas.items() if k not in children]
    facets = {}
    if os.path.isdir(facets_dir):
        for k in metas:
            f = read_json(os.path.join(facets_dir, k + ".json"))
            if f:
                facets[k] = f

    tools = Counter()
    err_cats = Counter()
    langs = Counter()
    hours = Counter()
    gaps = []
    mined_skills = Counter()
    projects = Counter()
    by_harness = defaultdict(lambda: {"sessions": 0, "top_sessions": 0, "facets": 0, "prompts": 0, "tool_calls": 0, "errors": 0})
    dates = set()
    total_prompts = total_tools = total_commits = total_pushes = 0

    for k, m in metas.items():
        h = m["harness"]
        by_harness[h]["sessions"] += 1
        if k not in children:
            by_harness[h]["top_sessions"] += 1
        if k in facets:
            by_harness[h]["facets"] += 1
        p_cnt = int(m.get("prompts") or 0)
        t_cnt = int(m.get("tool_calls") or 0)
        e_cnt = sum((m.get("errors") or {}).values())
        by_harness[h]["prompts"] += p_cnt
        by_harness[h]["tool_calls"] += t_cnt
        by_harness[h]["errors"] += e_cnt
        total_prompts += p_cnt
        total_tools += t_cnt
        total_commits += int(m.get("git_commits") or 0)
        total_pushes += int(m.get("git_pushes") or 0)
        for tn, tv in (m.get("tools") or {}).items():
            tools[tn] += tv
        for ec, ev in (m.get("error_categories") or {}).items():
            err_cats[ec] += ev
        for ln, lv in (m.get("languages") or {}).items():
            langs[ln] += lv
        for hr, hv in (m.get("message_hours") or {}).items():
            hours[str(hr)] += hv
        for g in m.get("response_gaps") or []:
            if isinstance(g, (int, float)) and g >= 2:
                gaps.append(float(g))
        for sk in m.get("skill_loads") or []:
            mined_skills[canon_skill(sk)] += 1
        proj = os.path.basename(str(m.get("project") or "").rstrip("/")) or "unknown"
        if k not in children:
            projects[proj] += 1
        ft = str(m.get("first_ts") or "")[:10]
        lt = str(m.get("last_ts") or "")[:10]
        if ft and (not since_str or ft >= since_str):
            dates.add(ft)
        elif lt and (not since_str or lt >= since_str):
            dates.add(lt)

    gap_buckets = Counter(gap_bucket(g) for g in gaps)
    gaps_sorted = sorted(gaps)
    med_gap = round(gaps_sorted[len(gaps_sorted) // 2], 1) if gaps_sorted else None
    avg_gap = round(sum(gaps_sorted) / len(gaps_sorted), 1) if gaps_sorted else None

    goal_cats = Counter()
    session_types = Counter()
    outcomes = Counter()
    friction_types = Counter()
    primary_success = Counter()
    satisfaction = Counter()
    facet_summaries = []
    for k, f in facets.items():
        for gc, gv in (f.get("goal_categories") or {}).items():
            goal_cats[gc] += gv
        session_types[f.get("session_type") or "single_task"] += 1
        outcomes[f.get("outcome") or "unclear"] += 1
        for fc, fv in (f.get("friction_counts") or {}).items():
            friction_types[fc] += fv
        ps = f.get("primary_success") or "none"
        if ps != "none":
            primary_success[ps] += 1
        satisfaction[f.get("satisfaction") or "unsure"] += 1
        m = metas.get(k) or {}
        facet_summaries.append({
            "session_id": f["session_id"][:16],
            "harness": f["harness"],
            "project": os.path.basename(str(m.get("project") or "").rstrip("/")) or "unknown",
            "goal": f.get("underlying_goal") or "",
            "outcome": f.get("outcome") or "unclear",
            "friction": f.get("friction_counts") or {},
            "friction_detail": f.get("friction_detail") or "",
            "summary": f.get("brief_summary") or "",
        })

    log_paths = [p for p in (args.log or []) if p] or [default_usage_log()]
    hook_events, fixtures_dropped = _read_hook_events(log_paths, since_str)
    skill_table, hooks_summary = _aggregate_hooks(hook_events, mined_skills)

    repos = [_collect_git_stats(r, since_str) for r in (args.repo or []) if r.strip()]
    today_iso = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    span_from = min(dates) if dates else since_str
    span_to = max(dates) if dates else today_iso
    days_active = max(1, len(dates))

    agg = {
        "meta": {
            "from": span_from,
            "to": span_to,
            "since": since_str,
            "days_active": days_active,
            "harnesses": harnesses,
            "project": args.project or None,
            "total_sessions": len(metas),
            "top_level_sessions": len(top_metas),
            "child_sessions": len(children),
            "facets_analyzed": len(facets),
            "prompts": total_prompts,
            "msgs_per_day": round(total_prompts / days_active, 1),
            "tool_calls": total_tools,
            "git_commits_in_transcripts": total_commits,
            "git_pushes_in_transcripts": total_pushes,
            "fixtures_excluded": fixtures_dropped,
            "repos": repos,
        },
        "by_harness": dict(by_harness),
        "hooks": hooks_summary,
        "charts": {
            "what_you_wanted": dict(goal_cats.most_common(8)),
            "top_tools": dict(tools.most_common(8)),
            "languages": dict(langs.most_common(8)),
            "session_types": dict(session_types.most_common(8)),
            "response_time_buckets": {b: gap_buckets[b] for b in ("2-10s", "10-30s", "30s-1m", "1-2m", "2-5m", "5-15m", ">15m")},
            "median_response_gap_s": med_gap,
            "avg_response_gap_s": avg_gap,
            "hour_counts_utc": {str(h): hours[str(h)] for h in range(24)},
            "tool_error_categories": dict(err_cats.most_common(8)),
            "what_helped_most": dict(primary_success.most_common(8)),
            "outcomes": dict(outcomes.most_common(8)),
            "primary_friction_types": dict(friction_types.most_common(8)),
            "satisfaction": dict(satisfaction.most_common(6)),
            "multi_agent_overlap": _compute_overlap(top_metas),
        },
        "projects": dict(projects.most_common(12)),
        "skill_table": skill_table,
        "facet_summaries": facet_summaries,
        "not_tracked": [
            "Per-hook firing counts (volume without signal; first-fire witnesses plus transcript joins cover compliance).",
            "Antigravity (agy) hook telemetry (kit hooks are not wired on agy yet; agy metrics come from transcript mining).",
            "Codex and OpenCode skill loads (no load signal exists; excluded, never ranked).",
            "Correlation is never causation: facet outcomes and satisfaction are model-estimated from bounded session digests.",
        ],
    }
    if args.out:
        atomic_write_json(args.out, agg)
    sys.stdout.write(json.dumps(agg, indent=2, sort_keys=True) + "\n")

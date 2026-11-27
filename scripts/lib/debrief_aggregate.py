#!/usr/bin/env python3
"""Debrief v2 aggregation: Stage 1 meta + Stage 2 facets + hook logs + git stats."""
import datetime
import json
import os
import statistics
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_common import (  # noqa: E402
    VALID_HARNESSES,
    atomic_write_json,
    default_cache_dir,
    default_usage_log,
    read_json,
    resolve_since,
    safe_int,
    safe_key,
)
from debrief_evals import (  # noqa: E402,F401
    _opt_float, _opt_int, _should_replace_eval, eval_stats, eval_trends, load_eval_history,
)
from debrief_hooks import (  # noqa: E402
    _aggregate_hooks,
    agy_hook_caveats,
    _collect_git_stats,
    _compute_overlap,
    _read_hook_events,
    papercut_stats,
)
from debrief_changepoints import (  # noqa: E402
    compute_changepoint_impact,
    discover_changepoints,
    latest_changepoint_epoch,
)
from debrief_coaching import build_coaching_playbook, session_health_stats  # noqa: E402
from debrief_insights import (  # noqa: E402
    build_skill_recommendations,
    interjection_reason_stats,
    repo_stats,
)
from debrief_skill_costs import attribute_skill_costs, gap_stats, load_skill_sizes  # noqa: E402
from debrief_diff import (  # noqa: E402
    build_snapshot,
    diff_snapshots,
    find_previous_snapshot,
)
from debrief_pareto import compute_pareto_analysis  # noqa: E402
from debrief_radar import compute_radar_profile  # noqa: E402
from debrief_scope import (  # noqa: E402
    build_scope_meta,
    filter_hook_events_by_sessions,
    filter_metas_by_sessions,
    parse_harnesses_strict,
    parse_session_specs,
    resolve_current_session,
    resolve_window,
    session_detail_rows,
)
from debrief_triggers import join_trigger_rows, trigger_stats  # noqa: E402


def parse_harnesses(raw):
    return parse_harnesses_strict(raw)


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


def _prompt_bucket(n):
    return "1" if n <= 1 else "2-3" if n <= 3 else "4-9" if n <= 9 else "10+"


def interjection_stats(top_metas):
    """Prompts-per-session distribution and follow-up rates (issue #77).

    Per-session ``prompts`` (accepted user turns) on top-level sessions.
    Ids only, never message text. Zero-prompt sessions are reported, not
    hidden: prompt mining is lossy, so every rate is a lower bound.
    """
    dist = {"1": 0, "2-3": 0, "4-9": 0, "10+": 0}
    per_harness = defaultdict(list)
    zero = 0
    steered = []
    for m in top_metas:
        p = safe_int(m.get("prompts"), 0)
        if p < 1:
            zero += 1
            continue
        dist[_prompt_bucket(p)] += 1
        per_harness[str(m.get("harness") or "unknown")].append(p)
        steered.append(m)

    def rate(ps):
        return round(100.0 * sum(1 for p in ps if p > 1) / len(ps), 1) if ps else None

    def med(ps):
        return round(float(statistics.median(ps)), 1) if ps else None

    by_harness = {
        h: {
            "sessions_with_prompts": len(per_harness[h]),
            "median_prompts": med(per_harness[h]),
            "follow_up_rate_pct": rate(per_harness[h]),
        }
        for h in sorted({str(m.get("harness") or "unknown") for m in top_metas})
    }
    steered = [m for m in steered if safe_int(m.get("prompts"), 0) > 1]
    top = sorted(steered, key=lambda m: (-safe_int(m.get("prompts"), 0), str(m.get("id") or "")))[:5]
    return dist, {
        "prompt_bearing_sessions": sum(dist.values()),
        "zero_prompt_sessions": zero,
        "follow_up_rate_pct": rate([p for ps in per_harness.values() for p in ps]),
        "by_harness": by_harness,
        "top_steered": [
            {
                "session_id": str(m.get("id") or ""),
                "harness": str(m.get("harness") or "unknown"),
                "prompts": safe_int(m.get("prompts"), 0),
                "tool_calls": safe_int(m.get("tool_calls"), 0),
            }
            for m in top
        ],
    }


def cmd_aggregate(args):
    harnesses = parse_harnesses_strict(args.harness)
    specs = parse_session_specs(getattr(args, "session", None), getattr(args, "sessions_file", "") or "")
    is_current = bool(getattr(args, "current", False))
    all_time = bool(getattr(args, "all_time", False))
    explicit_sessions = bool(is_current or specs)
    days_explicit = getattr(args, "days", None) is not None
    since_str, since_ep = resolve_window(
        getattr(args, "since", "") or "",
        getattr(args, "days", None),
        all_time=all_time,
        explicit_sessions=explicit_sessions,
        days_explicit=days_explicit,
    )
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

    matched_sids = []
    missing_specs = []
    if is_current:
        specs = resolve_current_session(
            metas, harnesses, cwd=getattr(args, "current_cwd", "") or None
        ) + specs
    if specs:
        metas, matched_keys, missing_specs = filter_metas_by_sessions(
            metas, specs, include_children=not bool(getattr(args, "no_children", False))
        )
        matched_sids = [metas[k]["id"] for k in matched_keys]

    repo_paths = [r for r in (args.repo or []) if r.strip()]
    skills_dirs = getattr(args, "skills_dir", None) or None
    cp_raw = discover_changepoints(skills_dirs=skills_dirs, repo_paths=repo_paths)
    if bool(getattr(args, "since_last_edit", False)):
        loaded_sks = {sk for m in metas.values() for sk in (m.get("skill_loads") or [])}
        lce = latest_changepoint_epoch(cp_raw, loaded_skills=loaded_sks)
        if lce:
            metas = {k: m for k, m in metas.items() if float(m.get("last_epoch") or m.get("first_epoch") or m.get("source_mtime") or 0) >= lce}

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
    gaps_with_harness = []
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
                gaps_with_harness.append((float(g), h))
        proj = os.path.basename(str(m.get("project") or "").rstrip("/")) or "unknown"
        if k not in children:
            projects[proj] += 1
        ft = str(m.get("first_ts") or "")[:10]
        lt = str(m.get("last_ts") or "")[:10]
        if ft and (not since_str or ft >= since_str):
            dates.add(ft)
        elif lt and (not since_str or lt >= since_str):
            dates.add(lt)

    gap_buckets, med_gap, avg_gap, med_gap_by_harness = gap_stats(gaps_with_harness)
    prompt_dist, interjections = interjection_stats(top_metas)
    ij_reasons, ij_by_skill, ij_unattr = interjection_reason_stats(top_metas, metas.values())
    interjections["reasons"] = ij_reasons
    skill_sizes = load_skill_sizes(skills_dirs=getattr(args, "skills_dir", None) or None)
    skill_costs = attribute_skill_costs(metas.values(), skill_sizes=skill_sizes)
    mined_skills = Counter(skill_costs["mined_skills"])
    repositories = repo_stats(metas, children)

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
    if explicit_sessions:
        hook_events = filter_hook_events_by_sessions(hook_events, metas)
    costs_by_skill = {r["skill"]: r for r in skill_costs["per_skill"]}
    skill_table, hooks_summary = _aggregate_hooks(hook_events, mined_skills, costs_by_skill, metas)

    papercuts = papercut_stats(getattr(args, "papercuts", "") or "")
    filed_by_skill = papercuts["per_skill"] if papercuts else {}
    eval_records = []
    evals = eval_stats(getattr(args, "evals", None) or [], records_out=eval_records)
    history_paths = getattr(args, "eval_history", None) or []
    eval_trend_stats = None
    if evals is not None or history_paths:
        history, trend_sources, history_skipped = load_eval_history(history_paths)
        eval_trend_stats = eval_trends(
            eval_records + history, (evals["sources"] if evals else []) + trend_sources, history_skipped)
    evals_by_skill = evals["per_skill"] if evals else {}
    trigger_evals = trigger_stats(getattr(args, "trigger_evals", None) or [])
    join_trigger_rows(skill_table, trigger_evals)
    for row in skill_table:
        counts = filed_by_skill.get(row["skill"], {"filed": 0, "open": 0, "fixed": 0})
        row["papercut_filed"] = counts["filed"]
        row["papercut_open"] = counts.get("open", max(0, counts["filed"] - counts["fixed"]))
        row["papercut_fixed"] = counts["fixed"]
        ev = evals_by_skill.get(row["skill"]) or {}
        row["eval_win_rate"] = ev.get("win_rate")
        row["eval_noise_band"] = ev.get("noise_band")
        row["eval_pass_rate"] = ev.get("pass_rate_with")
        row["eval_pairs"] = ev.get("cross_pairs")
        sk_ij = ij_by_skill.get(row["skill"]) or {}
        row["redirect_interjections"] = safe_int(sk_ij.get("redirect_goal"), 0)
        row["top_interjection_reason"] = (
            max(sk_ij.items(), key=lambda kv: (kv[1], kv[0]))[0] if sk_ij else None
        )

    repos = [_collect_git_stats(r, since_str) for r in (args.repo or []) if r.strip()]
    today_iso = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    span_from = min(dates) if dates else since_str
    span_to = max(dates) if dates else today_iso
    days_active = max(1, len(dates))
    cp_impact = compute_changepoint_impact(metas.values(), hook_events, skill_sizes, cp_raw, since_epoch=since_ep)
    ignore_cp = bool(getattr(args, "ignore_changepoints", False))
    pareto = compute_pareto_analysis(skill_table, eval_trend_stats)
    skill_recs = build_skill_recommendations(
        skill_table, repositories, skill_sizes, ij_unattr, days_active,
        pareto=pareto, changepoints=None if ignore_cp else cp_impact,
    )
    sess_health = session_health_stats(metas.values(), skill_costs)
    scope_meta = build_scope_meta(
        harnesses,
        args.project,
        since_str,
        args.days if days_explicit else 30,
        all_time,
        session_ids=matched_sids,
        missing_sessions=missing_specs,
    )
    sess_details = session_detail_rows(metas, children, facets, limit=25) if (explicit_sessions or len(top_metas) == 1) else []

    agg = {
        "meta": {
            "from": span_from,
            "to": span_to,
            "since": since_str or None,
            "days_active": days_active,
            "harnesses": harnesses,
            "project": args.project or None,
            "scope": scope_meta,
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
        "sessions_detail": sess_details,
        "by_harness": dict(by_harness),
        "hooks": hooks_summary,
        "charts": {
            "what_you_wanted": dict(goal_cats.most_common(8)),
            "top_tools": dict(tools.most_common(8)),
            "languages": dict(langs.most_common(8)),
            "session_types": dict(session_types.most_common(8)),
            "response_time_buckets": {b: gap_buckets[b] for b in ("2-10s", "10-30s", "30s-1m", "1-2m", "2-5m", "5-15m", ">15m")},
            "prompt_distribution": dict(prompt_dist),
            "interjection_reasons": ij_reasons,
            "median_response_gap_s": med_gap,
            "median_response_gap_s_by_harness": med_gap_by_harness,
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
        "repositories": repositories,
        "skill_table": skill_table,
        "changepoints": cp_impact,
        "pareto": pareto,
        "skill_recommendations": skill_recs,
        "session_health": sess_health,
        "skill_costs": skill_costs,
        "papercuts": papercuts,
        "evals": evals,
        "eval_trends": eval_trend_stats,
        "trigger_evals": trigger_evals,
        "interjections": interjections,
        "facet_summaries": facet_summaries,
        "not_tracked": [
            "Per-hook firing counts (volume without signal; first-fire witnesses plus transcript joins cover compliance).",
            *agy_hook_caveats(hooks_summary["agy"]),
            "Codex and OpenCode hook nudge telemetry when their skill hooks or v2 bridge are not installed (transcript sessions and SKILL.md / skill tool loads ARE mined).",
            "Correlation is never causation: facet outcomes and satisfaction are model-estimated from bounded session digests.",
        ],
    }
    agg["coaching_playbook"] = build_coaching_playbook(agg, sess_health)
    agg["radar_profile"] = compute_radar_profile(agg)
    compare_path = getattr(args, "compare", "") or ""
    compare_prev = bool(getattr(args, "compare_prev", False))
    agg["diff_from_prev"] = None
    if compare_path or compare_prev:
        prev_snap = None
        if compare_path:
            prev_snap = read_json(compare_path)
            if not isinstance(prev_snap, dict) or not prev_snap.get("kpis"):
                sys.stderr.write(f"debrief aggregate: invalid or missing --compare snapshot: {compare_path}\n")
                raise SystemExit(2)
        else:
            _, prev_snap = find_previous_snapshot(
                reports_dir=getattr(args, "reports_dir", "") or None,
                scope_key=scope_meta.get("scope_key"),
            )
        if prev_snap:
            repo_paths = [r for r in (args.repo or []) if r.strip()]
            skills_dirs = getattr(args, "skills_dir", None) or None
            curr_snap = build_snapshot(agg, repo_paths=repo_paths, skills_dirs=skills_dirs)
            agg["diff_from_prev"] = diff_snapshots(
                prev_snap, curr_snap, repo_paths=repo_paths, skills_dirs=skills_dirs
            )
    if args.out:
        atomic_write_json(args.out, agg)
    sys.stdout.write(json.dumps(agg, indent=2, sort_keys=True) + "\n")

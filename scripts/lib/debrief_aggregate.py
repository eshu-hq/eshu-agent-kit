#!/usr/bin/env python3
"""Debrief v2 aggregation: Stage 1 meta + Stage 2 facets + hook logs + git stats."""
import datetime
import json
import math
import os
import statistics
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_common import (  # noqa: E402
    atomic_write_json,
    canon_skill,
    default_cache_dir,
    default_usage_log,
    read_json,
    resolve_since,
    safe_int,
    safe_key,
    ts_to_epoch,
)
from debrief_hooks import (  # noqa: E402
    _aggregate_hooks,
    _collect_git_stats,
    _compute_overlap,
    _read_hook_events,
    papercut_stats,
)
from debrief_insights import (  # noqa: E402
    build_skill_recommendations,
    interjection_reason_stats,
    repo_stats,
)
from debrief_skill_costs import attribute_skill_costs, gap_stats, load_skill_sizes  # noqa: E402


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


def _opt_float(val):
    if isinstance(val, bool) or val is None:
        return None
    try:
        num = float(val)
    except (TypeError, ValueError):
        return None
    return num if math.isfinite(num) else None


def _opt_int(val):
    if isinstance(val, bool) or val is None:
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        return None


def _should_replace_eval(prev, cand):
    old_ts, new_ts = prev.get("recorded_at") or "", cand.get("recorded_at") or ""
    if old_ts and new_ts:
        old_ep, new_ep = ts_to_epoch(old_ts), ts_to_epoch(new_ts)
        if old_ep is not None and new_ep is not None:
            return new_ep >= old_ep
        if old_ep is not None and new_ep is None:
            return False
        if old_ep is None and new_ep is not None:
            return True
        return new_ts >= old_ts
    return bool(new_ts) or not old_ts


def eval_stats(paths):
    """Per-skill replay-eval summary from offline JSON file(s) or directories.

    Accepts a path or sequence of paths. Each file may hold a single JSON
    object, a JSON array, or ``{"evals": [...]}``; directories expand to
    sorted ``*.json`` files. Deduplicates per canonical skill keeping the
    newest ``recorded_at`` (or last when tied/absent). Offline only.
    """
    if not paths:
        return None
    raw_paths = [paths] if isinstance(paths, str) else list(paths)
    clean_paths = [p for p in raw_paths if p and str(p).strip()]
    if not clean_paths:
        return None
    files = []
    for p in clean_paths:
        if os.path.isdir(p):
            for fn in sorted(os.listdir(p)):
                fp = os.path.join(p, fn)
                if fn.endswith(".json") and os.path.isfile(fp):
                    files.append(fp)
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise SystemExit(f"aggregate: cannot read --evals path {p!r}: not found")
    per_skill = {}
    loaded = skipped = 0
    for fp in files:
        try:
            with open(fp, encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError) as exc:
            raise SystemExit(f"aggregate: cannot read --evals file {fp!r}: {exc}")
        if isinstance(raw, list):
            recs = raw
        elif isinstance(raw, dict) and isinstance(raw.get("evals"), list):
            recs = raw["evals"]
        elif isinstance(raw, dict):
            recs = [raw]
        else:
            raise SystemExit(f"aggregate: --evals file {fp!r} must be a JSON object, array, or {{\"evals\": [...]}}")
        for rec in recs:
            if not isinstance(rec, dict):
                skipped += 1
                continue
            skill = canon_skill(str(rec.get("skill") or "").rstrip("."))
            if not skill:
                skipped += 1
                continue
            loaded += 1
            entry = {
                "skill": skill,
                "win_rate": _opt_float(rec.get("win_rate")),
                "noise_band": _opt_float(rec.get("noise_band")),
                "pass_rate_with": _opt_float(rec.get("pass_rate_with")),
                "pass_rate_without": _opt_float(rec.get("pass_rate_without")),
                "cross_pairs": _opt_int(rec.get("cross_pairs")),
                "cost_delta_in": _opt_float(rec.get("cost_delta_in")),
                "cost_delta_out": _opt_float(rec.get("cost_delta_out")),
                "latency_delta_s": _opt_float(rec.get("latency_delta_s")),
                "harness": str(rec.get("harness") or ""),
                "recorded_at": str(rec.get("recorded_at") or ""),
            }
            prev = per_skill.get(skill)
            if prev is None or _should_replace_eval(prev, entry):
                per_skill[skill] = entry
    return {
        "sources": clean_paths,
        "skills_evaluated": len(per_skill),
        "records_loaded": loaded,
        "records_skipped": skipped,
        "per_skill": dict(sorted(per_skill.items())),
    }


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
    skill_sizes = load_skill_sizes()
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
    costs_by_skill = {r["skill"]: r for r in skill_costs["per_skill"]}
    skill_table, hooks_summary = _aggregate_hooks(hook_events, mined_skills, costs_by_skill)

    papercuts = papercut_stats(getattr(args, "papercuts", "") or "")
    filed_by_skill = papercuts["per_skill"] if papercuts else {}
    evals = eval_stats(getattr(args, "evals", None) or [])
    evals_by_skill = evals["per_skill"] if evals else {}
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
    skill_recs = build_skill_recommendations(skill_table, repositories, skill_sizes, ij_unattr, days_active)

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
        "skill_recommendations": skill_recs,
        "skill_costs": skill_costs,
        "papercuts": papercuts,
        "evals": evals,
        "interjections": interjections,
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

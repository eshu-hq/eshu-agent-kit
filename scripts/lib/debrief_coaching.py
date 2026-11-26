#!/usr/bin/env python3
"""Humanized two-sided coaching playbook, session health outliers, and model/cache telemetry."""
import html
from collections import Counter

from debrief_common import safe_float, safe_int
from debrief_insights import _SYNTHETIC_REPOS, normalize_repo_name


def _e(val):
    return html.escape(str(val if val is not None else ""), quote=True)


def _fmt_tok(val):
    num = safe_float(val, 0.0)
    if num >= 1_000_000_000:
        return f"{num / 1_000_000_000.0:.2f}B"
    if num >= 1_000_000:
        return f"{num / 1_000_000.0:.1f}M"
    if num >= 1000:
        return f"{num / 1000.0:.1f}k"
    return str(int(round(num)))


def _fmt_dur(minutes):
    m = safe_float(minutes, 0.0)
    if m >= 120:
        return f"{m / 60.0:.1f}h"
    if m >= 1:
        return f"{m:.0f}m"
    return "<1m"


def session_health_stats(metas, skill_costs):
    """Compute skill-stacking distribution, model mix, cache efficiency, and runaway outliers."""
    stack_buckets = {
        "0 skills": 0,
        "1-2 skills (focused)": 0,
        "3-5 skills (busy)": 0,
        "6+ skills (bloated)": 0,
    }
    models = Counter()
    outliers = []
    bloated_cnt = 0
    mega_tok_cnt = 0
    high_err_cnt = 0

    for m in metas:
        n_sk = len(m.get("skill_loads") or [])
        if n_sk == 0:
            stack_buckets["0 skills"] += 1
        elif n_sk <= 2:
            stack_buckets["1-2 skills (focused)"] += 1
        elif n_sk <= 5:
            stack_buckets["3-5 skills (busy)"] += 1
        else:
            stack_buckets["6+ skills (bloated)"] += 1
            bloated_cnt += 1

        for mod, cnt in (m.get("session_models") or {}).items():
            c = safe_int(cnt, 0)
            if mod and c > 0 and mod != "<synthetic>":
                models[str(mod)] += c

        tok = safe_int(m.get("tokens_in"), 0) + safe_int(m.get("tokens_out"), 0)
        errs = sum(safe_int(v, 0) for v in (m.get("errors") or {}).values())
        dur = safe_float(m.get("duration_minutes"), 0.0)
        prompts = safe_int(m.get("prompts"), 0)
        flags = []
        if tok >= 500_000_000:
            mega_tok_cnt += 1
            flags.append(f"Mega-thread ({_fmt_tok(tok)})")
        if n_sk >= 6:
            flags.append(f"{n_sk} skills stacked")
        if errs >= 20:
            high_err_cnt += 1
            flags.append(f"Error loop ({errs} errs)")
        if flags or tok >= 250_000_000 or errs >= 15:
            outliers.append({
                "session_id": str(m.get("id") or "")[:12],
                "harness": str(m.get("harness") or "unknown"),
                "repo": normalize_repo_name(m.get("project") or ""),
                "tokens_total": tok,
                "duration_min": round(dur, 1),
                "prompts": prompts,
                "errors": errs,
                "skills_loaded": n_sk,
                "flags": flags or [f"Heavy ({_fmt_tok(tok)})"],
            })

    outliers.sort(key=lambda x: (-x["tokens_total"], -x["errors"], -x["skills_loaded"], x["session_id"]))

    cache_by_harness = {}
    for h, c in sorted(((skill_costs or {}).get("by_harness") or {}).items()):
        tin = safe_float(c.get("tokens_in"), 0.0)
        cr = safe_float(c.get("tokens_cache_read"), 0.0)
        cw = safe_float(c.get("tokens_cache_write"), 0.0)
        if tin > 0:
            hit_pct = round(100.0 * min(cr, tin) / tin, 1)
            write_pct = round(100.0 * min(cw, tin) / tin, 1)
            fresh_pct = round(max(0.0, 100.0 - hit_pct - write_pct), 1)
        else:
            hit_pct = write_pct = fresh_pct = 0.0
        cache_by_harness[h] = {
            "tokens_in": int(round(tin)),
            "cache_hit_pct": hit_pct,
            "cache_write_pct": write_pct,
            "fresh_pct": fresh_pct,
        }

    return {
        "skill_stacking": stack_buckets,
        "models": dict(models.most_common(8)),
        "cache_by_harness": cache_by_harness,
        "bloated_skill_sessions": bloated_cnt,
        "mega_token_sessions": mega_tok_cnt,
        "high_error_sessions": high_err_cnt,
        "outliers": outliers[:6],
    }


def build_coaching_playbook(agg, health):
    """Build a plain-English two-sided action plan: For You vs. For Your Agents."""
    for_you = []
    for_agents = []
    charts = agg.get("charts") or {}
    meta = agg.get("meta") or {}
    repos = agg.get("repositories") or []
    recs = agg.get("skill_recommendations") or []
    reasons = charts.get("interjection_reasons") or {}
    err_cats = charts.get("tool_error_categories") or {}
    pdist = charts.get("prompt_distribution") or {}
    gaps = charts.get("response_time_buckets") or {}

    # --- FOR YOU (end-user habits & prompting) ---
    bloated = safe_int(health.get("bloated_skill_sessions"), 0)
    megas = safe_int(health.get("mega_token_sessions"), 0)
    top_out = (health.get("outliers") or [None])[0]
    if bloated > 0 or megas > 0:
        peak = f" (peak: {_fmt_tok(top_out['tokens_total'])} in one thread)" if top_out and top_out["tokens_total"] > 0 else ""
        for_you.append({
            "title": "Split long threads before context bloats",
            "evidence": f"{bloated} sessions stacked 6+ skills and {megas} burned 500M+ tokens{peak}.",
            "action": "Start a fresh chat or run /compact when switching subtasks or around 20-30 turns so the agent stops re-reading old skills and drifting.",
        })

    redirects = safe_int(reasons.get("redirect_goal"), 0)
    heavy_steer = safe_int(pdist.get("10+"), 0)
    if redirects > 0 or heavy_steer > 0:
        for_you.append({
            "title": "Front-load the finish line on complex tasks",
            "evidence": f"You stepped in {redirects:,} times to pull an agent back on goal and had {heavy_steer:,} threads needing 10+ messages.",
            "action": "State the target files, exact test command, and 'done' bar in prompt #1 — then mine 10+ threads with replay-eval.sh mine --top-steered to see which rules agents keep missing.",
        })

    slow_gaps = safe_int(gaps.get(">15m"), 0)
    tot_gaps = sum(safe_int(v, 0) for v in gaps.values()) or 1
    if slow_gaps >= 10 and (100.0 * slow_gaps / tot_gaps) >= 20.0:
        med_s = charts.get("median_response_gap_s")
        med_txt = f"{med_s:.0f}s" if isinstance(med_s, (int, float)) else "—"
        for_you.append({
            "title": "Keep active threads warm; hand long waits to /goal",
            "evidence": f"{slow_gaps:,} replies ({round(100.0 * slow_gaps / tot_gaps)}%) came 15+ minutes later (active median: {med_txt}).",
            "action": "Pauses over ~5-15m expire prompt caches so the next turn re-writes the full context. Batch quick back-and-forth replies together, and use /goal when stepping away.",
        })

    tot_sess = max(1, safe_int(meta.get("total_sessions"), 1))
    unattr_sess = safe_int(((agg.get("skill_costs") or {}).get("unattributed") or {}).get("sessions"), 0)
    real_repos = [r for r in repos if r.get("repo") not in _SYNTHETIC_REPOS and r.get("unattributed_sessions", 0) > 0]
    if unattr_sess > 0 and (100.0 * unattr_sess / tot_sess) >= 35.0:
        top_r = max(real_repos, key=lambda r: r["unattributed_sessions"]) if real_repos else None
        repo_hint = f" (most often in {top_r['repo']}: {top_r['unattributed_sessions']} skill-free sessions)" if top_r else ""
        for_you.append({
            "title": "Stop repeating baseline instructions by hand",
            "evidence": f"{round(100.0 * unattr_sess / tot_sess)}% of sessions ({unattr_sess:,}/{tot_sess:,}) ran with zero skills loaded{repo_hint}.",
            "action": "Load the relevant skill on turn 1 or add a lightweight repo overlay so you do not have to re-explain team conventions.",
        })

    # --- FOR YOUR AGENTS (skills, rules & hooks to fix) ---
    hook_blk = safe_int(err_cats.get("Hook Blocked"), 0)
    hook_fric = safe_int((charts.get("primary_friction_types") or {}).get("hook_or_env_retry"), 0)
    if hook_blk >= 10 or hook_fric >= 5:
        for_agents.append({
            "title": "Eliminate hook-block retry loops",
            "evidence": f"{hook_blk:,} Hook Blocked tool errors and {hook_fric:,} hook/env retry friction hits.",
            "action": "Pre-load demanded skills in role/subagent briefs so agents comply on turn 1 instead of slamming into guard hooks and wasting turns.",
        })

    fnf = safe_int(err_cats.get("File Not Found"), 0)
    edit_fail = safe_int(err_cats.get("Edit Failed"), 0)
    if (fnf + edit_fail) >= 20:
        for_agents.append({
            "title": "Stop blind path guesses and stale edits",
            "evidence": f"{fnf:,} File Not Found reads and {edit_fail:,} Edit Failed target mismatches.",
            "action": "Add an explicit AGENTS.md rule: locate paths before opening them, read target lines immediately before editing, and fix stale links with check-md-links.sh.",
        })

    cmd_fail = safe_int(err_cats.get("Command Failed"), 0)
    timeouts = safe_int(err_cats.get("Timeout"), 0)
    if (cmd_fail + timeouts) >= 20:
        for_agents.append({
            "title": "Harden recurring shell commands and slow tests",
            "evidence": f"{cmd_fail:,} Command Failed exits and {timeouts:,} tool timeouts ({safe_int(health.get('high_error_sessions'), 0)} sessions hit 20+ errors).",
            "action": "Put copy-pasteable working commands inside your top skills, run slow suites asynchronously, and file papercuts (scripts/file-papercut.sh) for brittle scripts.",
        })

    top_rec = next((r for r in recs if r.get("action") in ("modify", "create")), None)
    if top_rec:
        for_agents.append({
            "title": f"Highest-leverage skill fix: {top_rec['target']}",
            "evidence": top_rec["reason"],
            "action": top_rec["suggestion"],
        })

    return {"for_you": for_you[:4], "for_agents": for_agents[:4]}


def render_coaching_playbook_card(agg):
    """Render side-by-side 'For You' vs 'For Your Agents' humanized coaching card."""
    pb = agg.get("coaching_playbook") or {}
    fy = pb.get("for_you") or []
    fa = pb.get("for_agents") or []
    if not fy and not fa:
        return ""

    def _col(items, cls, heading, sub):
        cards = []
        for it in items:
            cards.append(
                f'<div class="coach-item {cls}">'
                f'<div class="coach-title">{_e(it.get("title"))}</div>'
                f'<div class="coach-ev">{_e(it.get("evidence"))}</div>'
                f'<div class="coach-act"><strong>Next step:</strong> {_e(it.get("action"))}</div></div>'
            )
        body = "\n".join(cards) or '<div class="subtitle" style="margin:0">No major issues flagged in this window.</div>'
        return f'<div class="chart-card"><div class="chart-title">{_e(heading)}</div><div style="font-size:12px;color:#64748b;margin:-6px 0 10px">{_e(sub)}</div>{body}</div>'

    return (
        '<h2 id="section-coaching">Coaching Playbook: How You &amp; Your Agents Can Improve</h2>'
        '<div class="charts-row">'
        + _col(fy, "coach-user", "For You (Habits & Prompting)", "Changes in how you start, pace, and split chats that immediately save time and tokens.")
        + _col(fa, "coach-agent", "For Your Agents (Skills, Rules & Hooks)", "Changes in skills, AGENTS.md, and hooks that cut errors and stop agents from drifting.")
        + '</div>'
    )


def render_session_health_section(agg):
    """Render Session Health (skill stacking + runaway threads) and Model Mix & Cache Health."""
    h = agg.get("session_health") or {}
    if not h:
        return ""

    def _mini_bars(data, color, left_col, right_col):
        if not data or not any(safe_int(v, 0) > 0 for v in data.values()):
            return '<div class="subtitle" style="margin:0">No observations in this window.</div>'
        mx = max(safe_int(v, 0) for v in data.values()) or 1
        out = [f'<div class="bar-head"><span>{_e(left_col)}</span><span>{_e(right_col)}</span></div>']
        for k, v in data.items():
            iv = safe_int(v, 0)
            pct = (float(iv) / float(mx)) * 100.0
            out.append(
                f'<div class="bar-row">'
                f'<div class="bar-label" style="width:170px" title="{_e(k)}">{_e(k)}</div>'
                f'<div class="bar-track"><div class="bar-fill" style="width:{pct:.1f}%;background:{color}"></div></div>'
                f'<div class="bar-value">{iv:,}</div></div>'
            )
        return "\n".join(out)

    stack_card = (
        '<div class="chart-card">'
        '<div class="chart-title">Context Bloat (Skills Stacked Per Chat)</div>'
        '<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">'
        'Loading 1-2 focused skills is ideal; stacking 6+ skills in one long chat inflates every turn and weakens instruction following.'
        '</div>'
        + _mini_bars(h.get("skill_stacking"), "#8b5cf6", "Skills loaded in one chat", "Sessions")
        + '</div>'
    )

    cache_rows = []
    for hn, c in sorted((h.get("cache_by_harness") or {}).items()):
        cache_rows.append(
            f'<tr><td><code>{_e(hn)}</code></td>'
            f'<td class="num">{c.get("cache_hit_pct", 0):.1f}%</td>'
            f'<td class="num">{c.get("cache_write_pct", 0):.1f}%</td>'
            f'<td class="num">{c.get("fresh_pct", 0):.1f}%</td></tr>'
        )
    cache_tbl = (
        '<table style="margin-top:12px"><thead><tr>'
        '<th>Harness</th><th class="num" title="Input tokens served cheaply from prompt cache">Cache Hit</th>'
        '<th class="num" title="Input tokens paid to create/rebuild cache">Cache Write</th>'
        '<th class="num" title="Uncached fresh input tokens">Fresh Input</th>'
        '</tr></thead><tbody>' + "".join(cache_rows) + '</tbody></table>'
        if cache_rows else ""
    )
    model_card = (
        '<div class="chart-card">'
        '<div class="chart-title">Model Mix &amp; Prompt Cache Health</div>'
        '<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">'
        'Which models ran the most turns and how much input came from warm prompt caches vs fresh re-writes.'
        '</div>'
        + _mini_bars(h.get("models"), "#0d9488", "Model", "Turns")
        + cache_tbl
        + '</div>'
    )

    out_rows = []
    for o in h.get("outliers") or []:
        flags = ", ".join(o.get("flags") or [])
        out_rows.append(
            f'<tr><td><code>{_e(o.get("session_id"))}</code></td>'
            f'<td><code>{_e(o.get("harness"))}</code></td>'
            f'<td><code>{_e(o.get("repo"))}</code></td>'
            f'<td class="num">{_e(_fmt_tok(o.get("tokens_total")))}</td>'
            f'<td class="num">{_e(_fmt_dur(o.get("duration_min")))}</td>'
            f'<td class="num">{safe_int(o.get("prompts"), 0)}</td>'
            f'<td class="num">{safe_int(o.get("skills_loaded"), 0)}</td>'
            f'<td class="num">{safe_int(o.get("errors"), 0)}</td>'
            f'<td>{_e(flags)}</td></tr>'
        )
    outlier_card = (
        '<div class="chart-card" style="margin:20px 0;overflow-x:auto">'
        '<div class="chart-title">Runaway &amp; High-Friction Threads (Top Outliers)</div>'
        '<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">'
        'Your heaviest chats by token burn, stacked skills, or error loops — prime candidates to inspect or split next time.'
        '</div>'
        '<table><thead><tr>'
        '<th>Session</th><th>Harness</th><th>Repository</th>'
        '<th class="num">Tokens</th><th class="num">Duration</th><th class="num">Prompts</th>'
        '<th class="num">Skills</th><th class="num">Errors</th><th>Why Flagged</th>'
        '</tr></thead><tbody>'
        + "".join(out_rows)
        + '</tbody></table></div>'
        if out_rows else ""
    )

    return f'<div class="charts-row">{stack_card}{model_card}</div>{outlier_card}'

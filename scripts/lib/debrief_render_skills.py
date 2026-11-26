#!/usr/bin/env python3
"""Harness activity and Skill Quality Flywheel HTML sections for /debrief v2."""
import html
import math

from debrief_common import safe_float, safe_int


def _e(val):
    return html.escape(str(val if val is not None else ""), quote=True)


def _fmt_tokens(val):
    """Compact token figure: millions (1.2M), thousands (12.5k), or plain ints."""
    if isinstance(val, bool) or val is None:
        return "—"
    try:
        num = float(val)
    except (TypeError, ValueError):
        return "—"
    if not math.isfinite(num):
        return "—"
    if num >= 1_000_000:
        return f"{num / 1_000_000.0:.1f}M"
    if num >= 1000:
        return f"{num / 1000.0:.1f}k"
    if num == int(num):
        return str(int(num))
    return f"{num:.2f}"


def _fmt_num(val):
    if isinstance(val, bool) or val is None:
        return "—"
    try:
        num = float(val)
    except (TypeError, ValueError):
        return "—"
    if not math.isfinite(num):
        return "—"
    if num == int(num):
        return str(int(num))
    return f"{num:.1f}"


def _fmt_pct(val):
    if isinstance(val, bool) or val is None:
        return None
    try:
        num = float(val)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(num):
        return None
    if 0.0 <= num <= 1.0:
        num *= 100.0
    return f"{round(num)}%"


def _fmt_latency(row):
    gap = row.get("median_gap_s")
    dur = row.get("median_duration_min")
    parts = []
    if gap is not None:
        parts.append(f"{gap}s")
    if dur is not None:
        parts.append(f"{dur}m")
    return " / ".join(parts) if parts else "—"


def _fmt_errors(row):
    errs = safe_float(row.get("attributed_errors"), 0.0)
    if errs <= 0:
        return "0"
    rate = row.get("error_rate_per_session")
    if rate is not None:
        return f"{_fmt_num(errs)} ({safe_float(rate, 0.0):.2f}/s)"
    return _fmt_num(errs)


def _fmt_papercuts(row, has_papercuts):
    if not has_papercuts:
        return "—"
    filed = safe_int(row.get("papercut_filed"), 0)
    fixed = safe_int(row.get("papercut_fixed"), 0)
    open_val = safe_int(row.get("papercut_open"), None)
    open_cnt = max(0, open_val) if open_val is not None else max(0, filed - fixed)
    return f"{open_cnt}/{fixed}"


def _fmt_eval_win(row):
    wr = _fmt_pct(row.get("eval_win_rate"))
    if wr is None:
        return "—"
    nb = _fmt_pct(row.get("eval_noise_band"))
    return f"{wr} (±{nb})" if nb is not None else wr


def _render_flywheel_summary(agg):
    skill_costs = agg.get("skill_costs") or {}
    per_skill = skill_costs.get("per_skill") or []
    total_attr = sum(safe_float(r.get("attributed_tokens_total"), 0.0) for r in per_skill)
    tax_rows = [
        r for r in per_skill
        if safe_float(r.get("estimated_context_tax_tokens"), 0.0) > 0
    ]
    if tax_rows:
        top_tax = min(
            tax_rows,
            key=lambda r: (-safe_float(r.get("estimated_context_tax_tokens"), 0.0), str(r.get("skill") or "")),
        )
        top_tax_val = f'{top_tax.get("skill", "")} ({_fmt_tokens(top_tax.get("estimated_context_tax_tokens"))})'
    else:
        top_tax_val = "—"

    tiles = [
        (_fmt_tokens(total_attr), "Attributed Tokens"),
        (top_tax_val, "Top Context-Tax Skill"),
    ]
    pc = agg.get("papercuts")
    if isinstance(pc, dict):
        filed = safe_int(pc.get("total_filed"), 0)
        fixed = safe_int(pc.get("total_fixed"), 0)
        open_val = safe_int(pc.get("total_open"), None)
        open_cnt = max(0, open_val) if open_val is not None else max(0, filed - fixed)
        tiles.append((f"{open_cnt} open / {fixed} fixed", "Papercuts"))
    ev = agg.get("evals")
    if isinstance(ev, dict):
        ev_cnt = safe_int(ev.get("skills_evaluated"), 0)
        tiles.append((str(ev_cnt), "Eval-Covered Skills"))

    tile_html = "".join(
        f'<div><div class="overlap-num" style="font-size:18px">{_e(val)}</div>'
        f'<div class="stat-label">{_e(lbl)}</div></div>'
        for val, lbl in tiles
    )
    return (
        '<div class="chart-card" style="margin:0 0 18px">'
        '<div class="chart-title">Skill Quality Flywheel</div>'
        f'<div class="overlap-stats">{tile_html}</div>'
        '</div>'
    )


def render_harness_skill_section(agg):
    costs_by_harness = (agg.get("skill_costs") or {}).get("by_harness") or {}
    tok_by_h = {}
    for h in sorted((agg.get("by_harness") or {})):
        c = costs_by_harness.get(h)
        if c is None:
            tok_by_h[h] = "—"
            continue
        tin = _fmt_tokens(c.get("attributed_tokens_in"))
        tout = _fmt_tokens(c.get("attributed_tokens_out"))
        tok_by_h[h] = f"{tin} in / {tout} out"

    h_rows = []
    for h, info in sorted((agg.get("by_harness") or {}).items()):
        info = info if isinstance(info, dict) else {}
        h_rows.append(
            f'<tr><td><code>{_e(h)}</code></td>'
            f'<td class="num">{safe_int(info.get("top_sessions"), 0)} / {safe_int(info.get("sessions"), 0)}</td>'
            f'<td class="num">{safe_int(info.get("facets"), 0)}</td>'
            f'<td class="num">{safe_int(info.get("prompts"), 0):,}</td>'
            f'<td class="num">{safe_int(info.get("tool_calls"), 0):,}</td>'
            f'<td class="num">{safe_int(info.get("errors"), 0):,}</td>'
            f'<td class="num">{_e(tok_by_h.get(h, "—"))}</td></tr>'
        )
    harness_tok_foot = (
        "Tokens mined across Claude (assistant usage + cache), agy "
        "(PLANNER_RESPONSE input/output/cache_read), and Muse (main-session "
        "model_completed, falling back to subagent runtime_observed). Older "
        "sessions without usage fields report 0. Per-harness rollups are never ranked."
    )

    has_papercuts = isinstance(agg.get("papercuts"), dict)
    s_rows = []
    for row in (agg.get("skill_table") or [])[:15]:
        fp = (
            f'{row["forced_pct"]}% ({row["forced"]}/{row["hook_loads"]})'
            if row.get("forced_pct") is not None
            else "—"
        )
        cost = _fmt_tokens(row.get("attributed_tokens_total"))
        tax_num = safe_float(row.get("estimated_context_tax_tokens"), 0.0)
        tax = _fmt_tokens(tax_num) if tax_num > 0 else "—"
        lat = _fmt_latency(row)
        errs = _fmt_errors(row)
        pcs = _fmt_papercuts(row, has_papercuts)
        evw = _fmt_eval_win(row)
        s_rows.append(
            f'<tr><td><code>{_e(row["skill"])}</code></td>'
            f'<td class="num">{_e(row["mined_loads"])}</td>'
            f'<td class="num">{_e(row["hook_loads"])}</td>'
            f'<td class="num">{_e(fp)}</td>'
            f'<td class="num">{_e(cost)}</td>'
            f'<td class="num">{_e(tax)}</td>'
            f'<td class="num">{_e(lat)}</td>'
            f'<td class="num">{_e(errs)}</td>'
            f'<td class="num">{_e(pcs)}</td>'
            f'<td class="num">{_e(evw)}</td></tr>'
        )
    cost_foot = (
        "Cost splits each session's tokens equally among its own skills; "
        "context tax approximates (SKILL.md bytes / 4) * turns after load; "
        "latency shows median response gap / session duration; "
        "papercuts show open/fixed when --papercuts is passed; "
        "eval win rate shows with-skill win rate (±noise band) when --evals is passed."
    )
    return (
        '<h2 id="section-harnesses">Harnesses &amp; Skill Effectiveness</h2>'
        f'{_render_flywheel_summary(agg)}'
        '<div class="chart-card" style="margin:0 0 18px">'
        '<div class="chart-title">Per-Harness Activity</div>'
        '<table><thead><tr><th>Harness</th><th class="num">Top / All</th><th class="num">Facets</th>'
        '<th class="num">Prompts</th><th class="num">Tools</th><th class="num">Errors</th>'
        '<th class="num">Attributed tokens</th></tr></thead>'
        f'<tbody>{"".join(h_rows)}</tbody></table>'
        f'<div style="font-size:12px;color:#64748b;margin-top:8px">{_e(harness_tok_foot)}</div></div>'
        '<div class="chart-card" style="margin:0 0 18px;overflow-x:auto">'
        '<div class="chart-title">Top Skills (Flywheel Scorecard)</div>'
        '<table><thead><tr><th>Skill</th><th class="num">Mined</th><th class="num">Hook</th>'
        '<th class="num">Forced</th><th class="num">Cost (tok)</th><th class="num">Context Tax</th>'
        '<th class="num">Latency</th><th class="num">Errors</th><th class="num">Papercuts</th>'
        '<th class="num">Eval Win Rate</th></tr></thead>'
        f'<tbody>{"".join(s_rows) or "<tr><td colspan=10>No skill loads in window.</td></tr>"}</tbody></table>'
        f'<div style="font-size:12px;color:#64748b;margin-top:8px">{_e(cost_foot)}</div></div>'
    )

#!/usr/bin/env python3
"""Offline inline-SVG 6-axis Trajectory Radar chart for /debrief (standalone + diff overlay)."""
import html
import math

from debrief_common import safe_float, safe_int

RADAR_AXES = (
    ("quality", "Outcome Quality", "Goal achievement or eval win rate (higher = better)"),
    ("trigger", "Trigger Precision", "Trigger F1 or unnudged self-load rate (higher = better)"),
    ("reliability", "Reliability", "1 / (1 + errors/session / 2.0) (higher = fewer errors)"),
    ("alignment", "Goal Alignment", "1 / (1 + goal-redirects/session) (higher = less steering)"),
    ("efficiency", "Token Efficiency", "1 / (1 + overhead/load / 5M) (higher = leaner skills)"),
    ("cache", "Cache Efficiency", "Weighted prompt cache hit rate (higher = better reuse)"),
)


def _clamp01(val):
    return round(max(0.0, min(1.0, float(val))), 4)


def compute_radar_profile(agg):
    """Compute normalized [0, 1] 6-axis operational profile (higher = better) with raw values."""
    meta = agg.get("meta") or {}
    charts = agg.get("charts") or {}
    by_h = agg.get("by_harness") or {}
    skills = agg.get("skill_table") or []
    health = agg.get("session_health") or {}
    trig = agg.get("trigger_evals") or {}

    total_sess = sum(safe_int(v.get("sessions"), 0) for v in by_h.values())
    top_sess = max(1, safe_int(meta.get("top_level_sessions"), 0))
    total_errs = sum(safe_int(v.get("errors"), 0) for v in by_h.values())

    axes = {}

    # 1. Quality: prefer mean eval_win_rate if evaluated, else facet outcome achievement rate.
    eval_wrs = [safe_float(r.get("eval_win_rate"), -1.0) for r in skills if r.get("eval_win_rate") is not None]
    eval_wrs = [w for w in eval_wrs if 0.0 <= w <= 1.0]
    outcomes = charts.get("outcomes") or {}
    tot_out = sum(safe_int(v, 0) for v in outcomes.values())
    if eval_wrs:
        avg_wr = sum(eval_wrs) / len(eval_wrs)
        axes["quality"] = {"score": _clamp01(avg_wr), "raw": f"{avg_wr * 100:.1f}% eval win rate ({len(eval_wrs)} skills)", "source": "eval_win_rate"}
    elif tot_out > 0:
        ach = safe_int(outcomes.get("fully_achieved"), 0) + 0.7 * safe_int(outcomes.get("mostly_achieved"), 0) + 0.3 * safe_int(outcomes.get("partially_achieved"), 0)
        rate = ach / tot_out
        axes["quality"] = {"score": _clamp01(rate), "raw": f"{rate * 100:.1f}% weighted achievement ({tot_out} facets)", "source": "facets"}
    else:
        axes["quality"] = {"score": None, "raw": "n/a", "source": None}

    # 2. Trigger Precision: prefer mean trigger F1, else 1 - mean(forced_pct / 100).
    f1s = []
    for per_dec in (trig.get("per_skill") or {}).values():
        if isinstance(per_dec, dict):
            for rec in per_dec.values():
                if isinstance(rec, dict) and rec.get("f1") is not None:
                    f1s.append(safe_float(rec.get("f1"), 0.0))
    forced_vals = [safe_float(r.get("forced_pct"), -1.0) for r in skills if r.get("forced_pct") is not None and safe_int(r.get("hook_loads"), 0) >= 1]
    forced_vals = [f for f in forced_vals if 0.0 <= f <= 100.0]
    if f1s:
        mf1 = sum(f1s) / len(f1s)
        axes["trigger"] = {"score": _clamp01(mf1), "raw": f"F1 {mf1:.3f} ({len(f1s)} skill-deciders)", "source": "trigger_evals"}
    elif forced_vals:
        unforced = 1.0 - (sum(forced_vals) / len(forced_vals)) / 100.0
        axes["trigger"] = {"score": _clamp01(unforced), "raw": f"{unforced * 100:.1f}% unnudged ({len(forced_vals)} skills)", "source": "hook_forced"}
    else:
        axes["trigger"] = {"score": None, "raw": "n/a", "source": None}

    # 3. Reliability: 1 / (1 + errors_per_session / 2.0) — smooth, never saturates flat.
    if total_sess > 0:
        eps = total_errs / float(total_sess)
        axes["reliability"] = {"score": _clamp01(1.0 / (1.0 + eps / 2.0)), "raw": f"{eps:.2f} errors/sess ({total_errs:,} errs / {total_sess:,} sess)", "source": "transcripts"}
    else:
        axes["reliability"] = {"score": None, "raw": "n/a", "source": None}

    # 4. Goal Alignment: 1 / (1 + redirects_per_session).
    redirs = safe_int((charts.get("interjection_reasons") or {}).get("redirect_goal"), 0)
    if safe_int(meta.get("top_level_sessions"), 0) > 0:
        rr = redirs / float(top_sess)
        axes["alignment"] = {"score": _clamp01(1.0 / (1.0 + rr)), "raw": f"{rr:.2f} redirects/sess ({redirs} / {top_sess})", "source": "interjections"}
    else:
        axes["alignment"] = {"score": None, "raw": "n/a", "source": None}

    # 5. Token Efficiency: 1 / (1 + mean overhead per load / 5M).
    ov_rates = []
    for r in skills:
        loads = safe_int(r.get("mined_loads"), 0)
        tax = safe_float(r.get("estimated_context_tax_tokens"), 0.0)
        if loads > 0 and tax > 0:
            ov_rates.append(tax / float(loads))
    if ov_rates:
        avg_ov = sum(ov_rates) / len(ov_rates)
        axes["efficiency"] = {"score": _clamp01(1.0 / (1.0 + avg_ov / 5_000_000.0)), "raw": f"{avg_ov / 1e6:.2f}M overhead/load ({len(ov_rates)} skills)", "source": "skill_costs"}
    else:
        axes["efficiency"] = {"score": None, "raw": "n/a", "source": None}

    # 6. Cache Efficiency: weighted prompt cache hit % from cache_by_harness or skill_costs totals.
    cbh = health.get("cache_by_harness") or {}
    c_hits = 0.0
    c_tot = 0.0
    for hv in cbh.values():
        if not isinstance(hv, dict):
            continue
        tin = safe_float(hv.get("tokens_in"), 0.0)
        hpct = hv.get("cache_hit_pct")
        if tin > 0 and hpct is not None:
            c_hits += tin * (safe_float(hpct, 0.0) / 100.0)
            c_tot += tin
    if c_tot <= 0:
        totals = (agg.get("skill_costs") or {}).get("totals") or {}
        cr = safe_float(totals.get("tokens_cache_read"), 0.0)
        tin = safe_float(totals.get("tokens_in"), 0.0)
        if tin > 0 and cr > 0:
            c_hits, c_tot = min(cr, tin), tin
    if c_tot > 0:
        ch = c_hits / c_tot
        axes["cache"] = {"score": _clamp01(ch), "raw": f"{ch * 100:.1f}% cache hit", "source": "cache_by_harness"}
    else:
        axes["cache"] = {"score": None, "raw": "n/a", "source": None}

    return {"axes": axes, "order": [k for k, _, _ in RADAR_AXES]}


def _polygon_area(scores):
    """Relative polygon area for ordered radii in [0, 1] (normalized to unit regular N-gon = 1.0)."""
    n = len(scores)
    if n < 3:
        return None
    sin_step = math.sin(2.0 * math.pi / n)
    raw = sum(scores[i] * scores[(i + 1) % n] * sin_step for i in range(n))
    max_area = n * sin_step
    return round(raw / max_area, 4) if max_area > 0 else 0.0


def compare_radar_profiles(prev_profile, curr_profile):
    """Compare previous vs current 6-axis radar profiles; return per-axis deltas and area movement."""
    p_axes = (prev_profile or {}).get("axes") or {}
    c_axes = (curr_profile or {}).get("axes") or {}
    deltas = {}
    shared_prev = []
    shared_curr = []
    improved = []
    regressed = []
    for key, label, _ in RADAR_AXES:
        pv = (p_axes.get(key) or {}).get("score")
        cv = (c_axes.get(key) or {}).get("score")
        d = round(cv - pv, 4) if (pv is not None and cv is not None) else None
        if d is None:
            direction = "n/a"
        elif d >= 0.02:
            direction = "improved"
            improved.append(label)
        elif d <= -0.02:
            direction = "regressed"
            regressed.append(label)
        else:
            direction = "flat"
        deltas[key] = {
            "label": label,
            "prev": pv,
            "curr": cv,
            "delta": d,
            "direction": direction,
            "prev_raw": (p_axes.get(key) or {}).get("raw") or "n/a",
            "curr_raw": (c_axes.get(key) or {}).get("raw") or "n/a",
        }
        if pv is not None and cv is not None:
            shared_prev.append(float(pv))
            shared_curr.append(float(cv))
    a_prev = _polygon_area(shared_prev)
    a_curr = _polygon_area(shared_curr)
    area_delta_pct = None
    if a_prev is not None and a_curr is not None:
        if a_prev > 0:
            area_delta_pct = round(((a_curr - a_prev) / a_prev) * 100.0, 1)
        elif a_curr > 0:
            area_delta_pct = 100.0
        else:
            area_delta_pct = 0.0
    return {
        "axes": deltas,
        "area_prev": a_prev,
        "area_curr": a_curr,
        "area_delta_pct": area_delta_pct,
        "improved_axes": improved,
        "regressed_axes": regressed,
    }


def _xy(cx, cy, radius, idx, total):
    angle = -math.pi / 2.0 + (2.0 * math.pi * idx / total)
    return cx + radius * math.cos(angle), cy + radius * math.sin(angle)


def _e(val):
    return html.escape(str(val if val is not None else ""), quote=True)


def render_radar_card(agg):
    """Render pure offline inline-SVG Trajectory Radar card (single or overlaid diff)."""
    curr_prof = agg.get("radar_profile") or compute_radar_profile(agg)
    c_axes = curr_prof.get("axes") or {}
    diff = agg.get("diff_from_prev") or {}
    radar_diff = diff.get("radar_diff") if isinstance(diff, dict) else None
    has_diff = bool(radar_diff and isinstance(radar_diff.get("axes"), dict))

    cx, cy, max_r = 190.0, 165.0, 112.0
    n = len(RADAR_AXES)
    svg = [
        '<svg viewBox="0 0 380 330" width="380" height="330" role="img" aria-label="Operational Trajectory Radar" style="max-width:100%;height:auto;display:block">',
    ]

    # Concentric grid rings (25%, 50%, 75%, 100%)
    for ring in (0.25, 0.5, 0.75, 1.0):
        pts = " ".join(f"{_xy(cx, cy, max_r * ring, i, n)[0]:.1f},{_xy(cx, cy, max_r * ring, i, n)[1]:.1f}" for i in range(n))
        svg.append(f'<polygon points="{pts}" fill="none" stroke="#e2e8f0" stroke-width="1"/>')
    # Spokes + labels
    for i, (key, label, hint) in enumerate(RADAR_AXES):
        x2, y2 = _xy(cx, cy, max_r, i, n)
        svg.append(f'<line x1="{cx:.1f}" y1="{cy:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="#cbd5e1" stroke-width="1"/>')
        lx, ly = _xy(cx, cy, max_r + 22.0, i, n)
        anchor = "middle" if abs(lx - cx) < 12 else ("start" if lx > cx else "end")
        dy = "0.35em"
        svg.append(f'<text x="{lx:.1f}" y="{ly:.1f}" text-anchor="{anchor}" dy="{dy}" font-size="11" font-weight="600" fill="#334155"><title>{_e(hint)}</title>{_e(label)}</text>')

    # Previous snapshot polygon (dashed slate overlay) when diff is present
    if has_diff:
        p_pts = []
        for i, (key, _, _) in enumerate(RADAR_AXES):
            pv = (radar_diff["axes"].get(key) or {}).get("prev")
            r = max_r * (float(pv) if pv is not None else 0.0)
            px, py = _xy(cx, cy, r, i, n)
            p_pts.append(f"{px:.1f},{py:.1f}")
        svg.append(
            f'<polygon points="{" ".join(p_pts)}" fill="rgba(100,116,139,0.12)" '
            f'stroke="#64748b" stroke-width="2" stroke-dasharray="5,4"/>'
        )

    # Current window polygon (filled teal/indigo)
    c_pts = []
    dots = []
    for i, (key, label, _) in enumerate(RADAR_AXES):
        rec = c_axes.get(key) or {}
        cv = rec.get("score")
        r = max_r * (float(cv) if cv is not None else 0.0)
        px, py = _xy(cx, cy, r, i, n)
        c_pts.append(f"{px:.1f},{py:.1f}")
        if cv is not None:
            tip = f"{label}: {cv:.2f} ({rec.get('raw', '')})"
            if has_diff:
                drec = radar_diff["axes"].get(key) or {}
                if drec.get("delta") is not None:
                    tip += f" | prev: {drec['prev']:.2f} (delta {drec['delta']:+.2f})"
            color = "#0f766e" if has_diff else "#4f46e5"
            dots.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="4.2" fill="{color}" stroke="#ffffff" stroke-width="1.5"><title>{_e(tip)}</title></circle>')
    poly_stroke = "#0f766e" if has_diff else "#4f46e5"
    poly_fill = "rgba(15,118,110,0.22)" if has_diff else "rgba(79,70,229,0.20)"
    svg.append(f'<polygon points="{" ".join(c_pts)}" fill="{poly_fill}" stroke="{poly_stroke}" stroke-width="2.2"/>')
    svg.extend(dots)
    svg.append("</svg>")

    # Axis scorecard table alongside the SVG
    rows = []
    for key, label, _ in RADAR_AXES:
        rec = c_axes.get(key) or {}
        cv = rec.get("score")
        c_txt = f"{cv:.2f}" if cv is not None else "n/a"
        raw_txt = rec.get("raw") or "n/a"
        delta_td = ""
        if has_diff:
            drec = radar_diff["axes"].get(key) or {}
            pv = drec.get("prev")
            dv = drec.get("delta")
            p_txt = f"{pv:.2f}" if pv is not None else "n/a"
            if dv is None:
                badge = '<span style="color:#64748b">n/a</span>'
            elif dv >= 0.02:
                badge = f'<span style="color:#15803d;font-weight:700">{dv:+.2f} &uarr;</span>'
            elif dv <= -0.02:
                badge = f'<span style="color:#b91c1c;font-weight:700">{dv:+.2f} &darr;</span>'
            else:
                badge = f'<span style="color:#64748b">{dv:+.2f} &rarr;</span>'
            delta_td = f'<td style="text-align:right;font-family:monospace">{_e(p_txt)}</td><td style="text-align:right;font-family:monospace">{badge}</td>'
        rows.append(
            f'<tr><td><strong>{_e(label)}</strong></td>'
            f'<td style="text-align:right;font-family:monospace">{_e(c_txt)}</td>'
            f'{delta_td}'
            f'<td style="font-size:11px;color:#64748b">{_e(raw_txt)}</td></tr>'
        )

    th_diff = '<th style="text-align:right">Prev</th><th style="text-align:right">Move</th>' if has_diff else ""
    legend = (
        '<div style="font-size:12px;color:#475569;margin-bottom:8px">'
        '<span style="display:inline-block;width:12px;height:3px;background:#0f766e;vertical-align:middle;margin-right:4px"></span>Current '
        '&nbsp;&nbsp;<span style="display:inline-block;width:12px;height:0;border-top:2px dashed #64748b;vertical-align:middle;margin-right:4px"></span>Previous'
        '</div>'
    ) if has_diff else ""
    banner = ""
    if has_diff and radar_diff.get("area_delta_pct") is not None:
        ad = radar_diff["area_delta_pct"]
        cls = "#15803d" if ad > 0 else ("#b91c1c" if ad < 0 else "#475569")
        verb = "Expanded" if ad > 0 else ("Contracted" if ad < 0 else "Unchanged")
        banner = f'<span style="font-size:12px;font-weight:700;color:{cls};margin-left:8px">Trajectory: {verb} {ad:+.1f}% area</span>'

    return (
        '<div class="chart-card" id="section-radar" style="margin:20px 0">'
        f'<div class="chart-title">Operational Trajectory Radar (Outward = Better){banner}</div>'
        f'{legend}'
        '<div style="display:flex;flex-wrap:wrap;gap:20px;align-items:center">'
        f'<div style="flex:0 0 380px">{"".join(svg)}</div>'
        '<div style="flex:1;min-width:260px">'
        '<table class="skill-table" style="margin:0;width:100%">'
        f'<thead><tr><th>Axis</th><th style="text-align:right">Curr</th>{th_diff}<th>Raw Signal</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table>'
        '</div></div></div>'
    )


def render_diff_accountability_card(agg):
    """Render Last Report Diff & Recommendation Accountability HTML card."""
    diff = agg.get("diff_from_prev")
    if not isinstance(diff, dict) or not diff.get("prev_snapshot_id"):
        return ""
    warn_html = ""
    if diff.get("scope_warnings"):
        items = "".join(f"<li>{_e(w)}</li>" for w in diff["scope_warnings"])
        warn_html = f'<div style="background:#fef3c7;border:1px solid #f59e0b;border-radius:6px;padding:8px 12px;margin-bottom:12px;font-size:12px"><strong>Scope mismatch note:</strong><ul style="margin:4px 0 0 16px">{items}</ul></div>'

    pills = []
    labels = {
        "errors_per_session": "Errors/Sess",
        "hook_blocked": "Hook Blocked",
        "redirect_per_session": "Redirects/Sess",
        "cache_hit_pct": "Cache Hit %",
        "eval_mean_win_rate": "Eval Win Rate",
        "trigger_mean_f1": "Trigger F1",
    }
    for key, lbl in labels.items():
        kd = (diff.get("kpi_deltas") or {}).get(key) or {}
        if kd.get("delta") is None:
            continue
        col = "#15803d" if kd.get("improved") is True else ("#b91c1c" if kd.get("improved") is False else "#475569")
        pills.append(
            f'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:6px 10px;font-size:12px">'
            f'<div style="color:#64748b;font-size:11px">{_e(lbl)}</div>'
            f'<div style="font-weight:700;color:{col}">{_e(kd["prev"])} &rarr; {_e(kd["curr"])} ({kd["delta"]:+.2f})</div></div>'
        )
    hv = diff.get("pareto_hv") or {}
    if hv.get("delta") is not None:
        col = "#15803d" if hv["delta"] > 0 else ("#b91c1c" if hv["delta"] < 0 else "#475569")
        pills.append(
            f'<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:6px;padding:6px 10px;font-size:12px">'
            f'<div style="color:#64748b;font-size:11px">Pareto Hypervolume</div>'
            f'<div style="font-weight:700;color:{col}">{hv["prev"]:.3f} &rarr; {hv["curr"]:.3f} ({hv["delta"]:+.3f})</div></div>'
        )
    pills_html = f'<div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:14px">{"".join(pills)}</div>' if pills else ""

    badge_styles = {
        "implemented_verified": ("DONE + VERIFIED", "#dcfce7", "#166534"),
        "implemented_ineffective": ("DONE + NO EFFECT", "#fee2e2", "#991b1b"),
        "implemented_pending_data": ("DONE (PENDING DATA)", "#e0f2fe", "#075985"),
        "not_done": ("NOT DONE", "#fef3c7", "#92400e"),
        "resolved_externally": ("RESOLVED", "#f1f5f9", "#334155"),
    }
    rows = []
    for r in diff.get("accountability") or []:
        st = r.get("status") or "not_done"
        lbl, bg, fg = badge_styles.get(st, (st.upper(), "#f1f5f9", "#334155"))
        if st == "not_done" and safe_int(r.get("carry_over_count"), 0) > 1:
            lbl += f" (x{r['carry_over_count']})"
        m = r.get("metric") or {}
        m_txt = f"{m.get('name')}: {m.get('prev')} -> {m.get('curr')}" if m.get("name") else "n/a"
        ev_txt = "; ".join(r.get("evidence") or []) or "no target change detected"
        rows.append(
            f'<tr>'
            f'<td><span style="display:inline-block;padding:2px 7px;border-radius:4px;font-size:11px;font-weight:700;background:{bg};color:{fg}">{_e(lbl)}</span></td>'
            f'<td><strong>{_e(r.get("target"))}</strong><div style="font-size:11px;color:#64748b">{_e(r.get("summary"))}</div></td>'
            f'<td style="font-size:12px">{_e(ev_txt)}</td>'
            f'<td style="font-size:12px;font-family:monospace">{_e(m_txt)}</td></tr>'
        )
    table_html = (
        '<table class="skill-table" style="width:100%">'
        '<thead><tr><th>Status</th><th>Previous Recommendation</th><th>Implementation Evidence</th><th>Metric Move</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table>'
    ) if rows else '<div style="font-size:12px;color:#64748b">No open recommendations were tracked in the previous snapshot.</div>'

    return (
        '<div class="chart-card" id="section-diff" style="margin:20px 0">'
        f'<div class="chart-title">Diff vs Previous Report ({_e(diff.get("prev_snapshot_id"))}) &amp; Recommendation Accountability</div>'
        f'{warn_html}{pills_html}{table_html}</div>'
    )

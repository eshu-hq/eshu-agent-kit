#!/usr/bin/env python3
"""Deterministic offline HTML renderer for /debrief v2 (aggregate + synthesis JSON)."""
import argparse
import datetime
import html
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_common import default_reports_dir, read_json, safe_float, safe_int  # noqa: E402
from debrief_coaching import render_coaching_playbook_card, render_session_health_section  # noqa: E402
from debrief_html_assets import REPORT_CSS, REPORT_JS  # noqa: E402
from debrief_insights import (  # noqa: E402
    render_interjection_reasons_card,
    render_repo_activity_section,
    render_skill_recommendations_card,
)
from debrief_changepoints import render_changepoint_card  # noqa: E402
from debrief_diff import build_snapshot, save_snapshot  # noqa: E402
from debrief_pareto import render_pareto_card  # noqa: E402
from debrief_radar import render_diff_accountability_card, render_radar_card  # noqa: E402
from debrief_render_skills import render_friction_cards, render_harness_skill_section  # noqa: E402
from debrief_render_trends import render_skill_trends_card  # noqa: E402
from debrief_scope import render_single_session_banner  # noqa: E402
from debrief_triggers import render_trigger_card  # noqa: E402


def _e(val):
    return html.escape(str(val if val is not None else ""), quote=True)


def _safe_js_json(obj):
    raw = json.dumps(obj, sort_keys=True)
    return raw.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")


def _label(key):
    return str(key or "").replace("_", " ").strip().title()


def _render_bars(data, color, title_case=True, left_col="", right_col=""):
    if not data or not any(v for v in data.values()):
        return '<div class="subtitle" style="margin:0">No observations in this window.</div>'
    mx = max(data.values()) or 1
    out = []
    if left_col or right_col:
        out.append(f'<div class="bar-head"><span>{_e(left_col)}</span><span>{_e(right_col)}</span></div>')
    for k, v in data.items():
        lbl = _label(k) if title_case else str(k)
        pct = (float(v) / float(mx)) * 100.0
        val_txt = f"{v:,}" if isinstance(v, int) else str(v)
        out.append(
            f'<div class="bar-row">'
            f'<div class="bar-label" title="{_e(lbl)}">{_e(lbl)}</div>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{pct:.1f}%;background:{color}"></div></div>'
            f'<div class="bar-value">{_e(val_txt)}</div></div>'
        )
    return "\n".join(out)


def _render_chart_card(title, data, color, title_case=True, footer="", left_col="", right_col="", hint=""):
    hint_html = f'<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">{_e(hint)}</div>' if hint else ""
    foot = f'<div style="font-size:12px;color:#64748b;margin-top:8px">{footer}</div>' if footer else ""
    return (
        f'<div class="chart-card">'
        f'<div class="chart-title">{_e(title)}</div>'
        f'{hint_html}{_render_bars(data, color, title_case=title_case, left_col=left_col, right_col=right_col)}{foot}</div>'
    )


def _render_rules(items):
    if not items:
        return ""
    rows = []
    for i, item in enumerate(items):
        code = str(item.get("snippet") or item.get("code") or "")
        target = str(item.get("target") or "AGENTS.md")
        why = str(item.get("why") or "")
        payload = f"Add to {target}:\n\n{code}"
        rows.append(
            f'<div class="rule-item">'
            f'<input type="checkbox" id="rule-{i}" class="cmd-checkbox" checked data-text="{_e(payload)}">'
            f'<code class="cmd-code">{_e(code)}</code>'
            f'<button class="copy-btn" onclick="copyRuleItem({i})">Copy</button>'
            f'<div class="cmd-why"><strong>{_e(target)}:</strong> {_e(why)}</div></div>'
        )
    return (
        '<div class="rules-section">'
        '<h3>Suggested AGENTS.md, Role &amp; Hook Additions</h3>'
        '<div class="rules-actions"><button class="copy-all-btn" onclick="copyAllCheckedRules()">Copy All Checked</button></div>'
        + "\n".join(rows)
        + "</div>"
    )


def _render_features(items):
    if not items:
        return ""
    cards = []
    for item in items:
        ex = str(item.get("example") or "")
        ex_html = (
            f'<div class="copyable-prompt-row"><code class="copyable-prompt">{_e(ex)}</code>'
            f'<button class="copy-btn" onclick="copyText(this)">Copy</button></div>'
        ) if ex else ""
        cards.append(
            f'<div class="feature-card">'
            f'<div class="feature-title">{_e(item.get("title"))}</div>'
            f'<div class="feature-oneliner">{_e(item.get("oneliner"))}</div>'
            f'<div class="feature-why"><strong>Why for you:</strong> {_e(item.get("why"))}</div>'
            f'{ex_html}</div>'
        )
    return '<div class="features-section">' + "\n".join(cards) + "</div>"


def _render_patterns(items):
    if not items:
        return ""
    cards = []
    for item in items:
        pr = str(item.get("prompt") or "")
        pr_html = (
            f'<div class="prompt-label">Paste into Muse / agy / Claude:</div>'
            f'<div class="copyable-prompt-row"><code class="copyable-prompt">{_e(pr)}</code>'
            f'<button class="copy-btn" onclick="copyText(this)">Copy</button></div>'
        ) if pr else ""
        cards.append(
            f'<div class="pattern-card">'
            f'<div class="pattern-title">{_e(item.get("title"))}</div>'
            f'<div class="pattern-summary">{_e(item.get("summary"))}</div>'
            f'<div class="pattern-detail">{_e(item.get("detail"))}</div>'
            f'{pr_html}</div>'
        )
    return '<div class="patterns-section">' + "\n".join(cards) + "</div>"


def _render_horizon(items):
    if not items:
        return ""
    cards = []
    for item in items:
        pr = str(item.get("prompt") or "")
        pr_html = (
            f'<div class="prompt-label">Ready-to-paste workflow prompt:</div>'
            f'<div class="copyable-prompt-row"><code class="copyable-prompt">{_e(pr)}</code>'
            f'<button class="copy-btn" onclick="copyText(this)">Copy</button></div>'
        ) if pr else ""
        tip = str(item.get("tip") or "")
        tip_html = f'<div class="horizon-tip"><strong>Getting started:</strong> {_e(tip)}</div>' if tip else ""
        cards.append(
            f'<div class="horizon-card">'
            f'<div class="horizon-title">{_e(item.get("title"))}</div>'
            f'<div class="horizon-possible">{_e(item.get("possible"))}</div>'
            f'{tip_html}{pr_html}</div>'
        )
    return '<div class="horizon-section">' + "\n".join(cards) + "</div>"


def render_html(agg, syn):
    meta = agg.get("meta") or {}
    charts = agg.get("charts") or {}
    glance = syn.get("at_a_glance") or {}
    repos = [r for r in (meta.get("repos") or []) if not r.get("unreadable")]
    lines_added = sum(r.get("added", 0) for r in repos)
    lines_del = sum(r.get("deleted", 0) for r in repos)
    merges = sum(r.get("merges", 0) for r in repos)
    lines_str = f"+{lines_added:,}/-{lines_del:,}" if repos else "—"

    areas_html = "\n".join(
        f'<div class="project-area"><div class="area-header">'
        f'<span class="area-name">{_e(a.get("name"))}</span>'
        f'<span class="area-count">{_e(a.get("sessions_label"))}</span></div>'
        f'<div class="area-desc">{_e(a.get("description"))}</div></div>'
        for a in (syn.get("project_areas") or [])
    )
    narr_paras = "\n".join(f"<p>{_e(p)}</p>" for p in (syn.get("narrative_paragraphs") or []))
    key_ins = syn.get("key_insight") or ""
    wins_html = "\n".join(
        f'<div class="big-win"><div class="big-win-title">{_e(w.get("title"))}</div>'
        f'<div class="big-win-desc">{_e(w.get("description"))}</div></div>'
        for w in (syn.get("big_wins") or [])
    )
    fric_intro, fric_html = render_friction_cards(agg, syn)
    raw_pdist = charts.get("prompt_distribution") or {}
    pdist_labels = {"1": "1 prompt (one-shot)", "2-3": "2-3 prompts", "4-9": "4-9 prompts", "10+": "10+ prompts"}
    prompt_dist_disp = {pdist_labels.get(str(k), str(k)): v for k, v in raw_pdist.items()}
    ov = charts.get("multi_agent_overlap") or {}
    med_g = charts.get("median_response_gap_s")
    avg_g = charts.get("avg_response_gap_s")
    med_by_h = charts.get("median_response_gap_s_by_harness") or {}
    gap_rows = []
    for h in sorted(med_by_h):
        cell = f'{_e(med_by_h[h])}s' if med_by_h[h] is not None else "—"
        gap_rows.append(f'<tr><td><code>{_e(h)}</code></td><td class="num">{cell}</td></tr>')
    gap_harness_table = (
        '<div class="chart-card" style="margin:0 0 20px">'
        '<div class="chart-title">Median Response Gap by Harness</div>'
        '<table><thead><tr><th>Harness</th><th class="num">Median gap</th></tr></thead>'
        f'<tbody>{"".join(gap_rows) or "<tr><td colspan=2>No multi-turn gaps observed.</td></tr>"}</tbody></table></div>'
    )
    if med_g is not None:
        per_h = ", ".join(
            f'{h}: {med_by_h[h]}s' if med_by_h.get(h) is not None else f'{h}: —'
            for h in sorted(med_by_h)
        )
        gap_foot = (f"Median: {_e(med_g)}s &bull; Average: {_e(avg_g)}s"
                    + (f" &bull; Per harness — {_e(per_h)}" if per_h else ""))
    else:
        gap_foot = "No multi-turn gaps observed."
    ij = agg.get("interjections") or {}
    ij_rate = ij.get("follow_up_rate_pct")
    ij_bearing = safe_int(ij.get("prompt_bearing_sessions"), 0)
    ij_zero = safe_int(ij.get("zero_prompt_sessions"), 0)
    ij_foot = (
        f"{_e(ij_rate)}% of {ij_bearing} prompt-bearing sessions had follow-ups"
        f" &bull; {ij_zero} sessions mined zero prompts (rates are lower bounds)"
        if ij_rate is not None else "No prompt-bearing sessions in window."
    )
    caveats_li = "".join(f"<li>{_e(c)}</li>" for c in (agg.get("not_tracked") or []))
    raw_hours = charts.get("hour_counts_utc") if isinstance(charts.get("hour_counts_utc"), dict) else {}
    clean_hours = {str(h): safe_int(raw_hours.get(str(h)), 0) for h in range(24)}
    utc_hours_json = _safe_js_json(clean_hours)
    harnesses_lbl = ", ".join(str(x) for x in (meta.get("harnesses") or ["muse", "agy", "claude"]))
    proj_lbl = f" &middot; Project: {_e(meta['project'])}" if meta.get("project") else " &middot; All projects"
    m_prompts = safe_int(meta.get("prompts"), 0)
    m_tools = safe_int(meta.get("tool_calls"), 0)
    m_top = safe_int(meta.get("top_level_sessions"), 0)
    m_tot = safe_int(meta.get("total_sessions"), 0)
    m_fac = safe_int(meta.get("facets_analyzed"), 0)
    m_days = safe_int(meta.get("days_active"), 1)
    m_mpd = safe_float(meta.get("msgs_per_day"), 0.0)
    m_commits = safe_int(meta.get("git_commits_in_transcripts"), 0)
    m_fix = safe_int(meta.get("fixtures_excluded"), 0)
    ov_ev = safe_int(ov.get("overlap_events"), 0)
    ov_sess = safe_int(ov.get("sessions_involved"), 0)
    ov_pct = safe_int(ov.get("pct_of_messages"), 0)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Multi-Harness Agent Debrief ({_e(meta.get("from"))} to {_e(meta.get("to"))})</title>
<style>{REPORT_CSS}</style>
</head>
<body>
<div class="container">
  <h1>Multi-Harness Agent Debrief</h1>
  <p class="subtitle">{m_prompts:,} prompts &middot; {m_tools:,} tool calls across {m_top} top-level sessions ({m_tot} total, {m_fac} facets analyzed) &middot; {_e(meta.get("from"))} to {_e(meta.get("to"))} &middot; Harnesses: {_e(harnesses_lbl)}{proj_lbl}</p>

  {render_single_session_banner(agg)}

  <div class="at-a-glance">
    <div class="glance-title">At a Glance</div>
    <div class="glance-sections">
      <div class="glance-section"><strong>What's working:</strong> {_e(glance.get("working"))} <a href="#section-wins" class="see-more">Impressive Things You Did &rarr;</a></div>
      <div class="glance-section"><strong>What's hindering you:</strong> {_e(glance.get("hindering"))} <a href="#section-friction" class="see-more">Where Things Go Wrong &rarr;</a></div>
      <div class="glance-section"><strong>Quick wins to try:</strong> {_e(glance.get("quick_wins"))} <a href="#section-fixes" class="see-more">Rules, Skills &amp; Hooks &rarr;</a></div>
      <div class="glance-section"><strong>Ambitious workflows:</strong> {_e(glance.get("ambitious"))} <a href="#section-horizon" class="see-more">On the Horizon &rarr;</a></div>
    </div>
  </div>

  <nav class="nav-toc">
    <a href="#section-radar">Trajectory Radar</a>
    <a href="#section-coaching">Coaching Playbook</a>
    <a href="#section-work">What You Work On</a>
    <a href="#section-usage">How You Work</a>
    <a href="#section-harnesses">Harnesses &amp; Skills</a>
    <a href="#section-wins">Impressive Things</a>
    <a href="#section-friction">Where Things Go Wrong</a>
    <a href="#section-fixes">Rules, Skills &amp; Hooks</a>
    <a href="#section-patterns">New Usage Patterns</a>
    <a href="#section-horizon">On the Horizon</a>
  </nav>

  <div class="stats-row">
    <div class="stat"><div class="stat-value">{m_prompts:,}</div><div class="stat-label">User Prompts</div></div>
    <div class="stat"><div class="stat-value">{m_tools:,}</div><div class="stat-label">Tool Calls</div></div>
    <div class="stat"><div class="stat-value">{m_fac}</div><div class="stat-label">Sessions Analyzed</div></div>
    <div class="stat"><div class="stat-value">{_e(lines_str)}</div><div class="stat-label">Lines Changed (+/-)</div></div>
    <div class="stat"><div class="stat-value">{merges if repos else m_commits}</div><div class="stat-label">{"Merge Commits" if repos else "Git Commits"}</div></div>
    <div class="stat"><div class="stat-value">{m_days}d ({m_mpd:.1f}/d)</div><div class="stat-label">Active Days</div></div>
  </div>

  {render_diff_accountability_card(agg)}

  {render_changepoint_card(agg)}

  {render_radar_card(agg)}

  {render_coaching_playbook_card(agg)}

  <h2 id="section-work">What You Work On</h2>
  <div class="project-areas">{areas_html}</div>

  {render_repo_activity_section(agg)}

  <div class="charts-row">
    {_render_chart_card("What You Wanted", charts.get("what_you_wanted"), "#2563eb", left_col="Goal", right_col="Sessions")}
    {_render_chart_card("Top Tools Used", charts.get("top_tools"), "#0891b2", title_case=False, left_col="Tool", right_col="Calls")}
  </div>
  <div class="charts-row">
    {_render_chart_card("Languages Touched", charts.get("languages"), "#10b981", title_case=False, left_col="Language", right_col="File touches")}
    {_render_chart_card("Session Types", charts.get("session_types"), "#8b5cf6", left_col="Type", right_col="Sessions")}
  </div>

  <h2 id="section-usage">How You Use Your Harnesses</h2>
  <div class="narrative">
    {narr_paras}
    <div class="key-insight"><strong>Key pattern:</strong> {_e(key_ins)}</div>
  </div>

  {_render_chart_card("User Response Time Distribution", charts.get("response_time_buckets"), "#6366f1", title_case=False, footer=gap_foot, left_col="Time until your next reply", right_col="Replies", hint="How long you took to reply after an agent finished a turn. Fast (2s–1m) = live back-and-forth; 1–5m = reviewing output or switching agents; >5m = async / parallel delegation (average includes overnight pauses — look at median for active pace).")}

  {gap_harness_table}

  {_render_chart_card("Prompts Per Session (Interjections)", prompt_dist_disp, "#0ea5e9", title_case=False, footer=ij_foot, left_col="Prompts in session", right_col="Sessions", hint="How many messages you sent in a single main chat. 1 prompt = autonomous one-shot; 2–3 = light nudge; 4+ = interactive iteration or heavy steering.")}

  {render_interjection_reasons_card(agg)}

  <div class="chart-card" style="margin:20px 0">
    <div class="chart-title">Multi-Agent Parallelism (Overlapping Sessions Across Harnesses)</div>
    <div class="overlap-stats">
      <div><div class="overlap-num">{ov_ev}</div><div class="stat-label">Overlap Events</div></div>
      <div><div class="overlap-num">{ov_sess}</div><div class="stat-label">Sessions Involved</div></div>
      <div><div class="overlap-num">{ov_pct}%</div><div class="stat-label">Of Prompts</div></div>
    </div>
    <p style="font-size:13px;color:#475569">Detected when top-level sessions overlap in wall-clock time across Muse, Antigravity, and Claude.</p>
  </div>

  <div class="charts-row">
    <div class="chart-card">
      <div class="chart-title" style="display:flex;align-items:center;justify-content:space-between;gap:8px">
        <span>Prompts by Time of Day</span>
        <select id="timezone-select" style="font-size:11px;padding:3px 6px;border-radius:4px;border:1px solid #cbd5e1">
          <option value="-8">PT (UTC-8)</option>
          <option value="-5" selected>ET (UTC-5)</option>
          <option value="0">UTC</option>
          <option value="1">CET (UTC+1)</option>
          <option value="9">Tokyo (UTC+9)</option>
        </select>
      </div>
      <div id="hour-histogram"></div>
    </div>
    {_render_chart_card("Tool Errors Encountered", charts.get("tool_error_categories"), "#dc2626", title_case=False, left_col="Error type", right_col="Occurrences")}
  </div>

  {render_harness_skill_section(agg)}

  {render_skill_trends_card(agg)}

  {render_trigger_card(agg)}

  {render_pareto_card(agg)}

  {render_skill_recommendations_card(agg)}

  {render_session_health_section(agg)}

  <h2 id="section-wins">Impressive Things You Did</h2>
  <p class="section-intro">{_e(syn.get("wins_intro"))}</p>
  <div class="big-wins">{wins_html}</div>

  <div class="charts-row">
    {_render_chart_card("What Helped Most", charts.get("what_helped_most"), "#16a34a", left_col="Factor", right_col="Sessions")}
    {_render_chart_card("Session Outcomes", charts.get("outcomes"), "#8b5cf6", left_col="Outcome", right_col="Sessions")}
  </div>

  <h2 id="section-friction">Where Things Go Wrong</h2>
  <p class="section-intro">{_e(fric_intro)}</p>
  <div class="friction-categories">{fric_html}</div>

  <div class="charts-row">
    {_render_chart_card("Primary Friction Types", charts.get("primary_friction_types"), "#dc2626", left_col="Friction type", right_col="Sessions")}
    {_render_chart_card("Inferred Satisfaction (Model-Estimated)", charts.get("satisfaction"), "#eab308", left_col="Rating", right_col="Sessions")}
  </div>

  <h2 id="section-fixes">Rules, Skills &amp; Hooks to Add or Tune</h2>
  {_render_rules(syn.get("agents_md_additions"))}
  {_render_features(syn.get("features_to_try"))}

  <h2 id="section-patterns">New Ways to Use Your Harnesses</h2>
  {_render_patterns(syn.get("usage_patterns"))}

  <h2 id="section-horizon">On the Horizon</h2>
  <p class="section-intro">{_e(syn.get("horizon_intro"))}</p>
  {_render_horizon(syn.get("horizon_workflows"))}

  <div class="caveats">
    <strong>Not tracked on purpose &amp; correlation caveats</strong>
    <ul>{caveats_li}</ul>
    <p style="margin-top:8px">Fixtures excluded from hook log: {m_fix}. Generated offline with zero external requests.</p>
  </div>
</div>
<script>
const rawUtcHours = {utc_hours_json};
{REPORT_JS}
</script>
</body>
</html>
"""


def main(argv=None):
    ap = argparse.ArgumentParser(prog="debrief-render")
    ap.add_argument("--aggregate", required=True)
    ap.add_argument("--synthesis", required=True)
    ap.add_argument("--out", default="")
    ap.add_argument("--reports-dir", default="")
    ap.add_argument("--snapshot-out", default="", help="Optional extra path for the content-free report snapshot JSON")
    ap.add_argument("--no-snapshot", action="store_true", help="Skip persisting a report snapshot")
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--skills-dir", action="append", default=[])
    args = ap.parse_args(argv)

    agg = read_json(args.aggregate)
    syn = read_json(args.synthesis)
    if not agg or not syn:
        raise SystemExit("debrief-render: both --aggregate and --synthesis must be valid JSON objects")

    doc = render_html(agg, syn)
    rdir = args.reports_dir or default_reports_dir()
    snap_path = None
    if not args.no_snapshot:
        snap = build_snapshot(agg, syn=syn, repo_paths=args.repo, skills_dirs=args.skills_dir)
        snap_path = save_snapshot(snap, reports_dir=rdir, explicit_out=args.snapshot_out)
    elif args.snapshot_out:
        snap = build_snapshot(agg, syn=syn, repo_paths=args.repo, skills_dirs=args.skills_dir)
        os.makedirs(os.path.dirname(os.path.abspath(args.snapshot_out)), exist_ok=True)
        with open(args.snapshot_out, "w", encoding="utf-8") as fh:
            json.dump(snap, fh, indent=2, sort_keys=True)
            fh.write("\n")
        snap_path = args.snapshot_out

    if args.out:
        out_path = args.out
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(doc)
        res = {"report": out_path}
        if snap_path:
            res["snapshot"] = snap_path
        sys.stdout.write(json.dumps(res) + "\n")
        return

    os.makedirs(rdir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    out_path = os.path.join(rdir, f"report-{ts}.html")
    latest = os.path.join(rdir, "report-latest.html")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(doc)
    shutil.copyfile(out_path, latest)
    res = {"report": out_path, "latest": latest}
    if snap_path:
        res["snapshot"] = snap_path
    sys.stdout.write(json.dumps(res) + "\n")


if __name__ == "__main__":
    main()

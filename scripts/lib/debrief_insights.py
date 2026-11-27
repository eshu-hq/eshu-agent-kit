#!/usr/bin/env python3
"""Repository breakdown, interjection intent analysis, and Create/Modify/Remove skill actions."""
import html
import os
import re
from collections import Counter, defaultdict

from debrief_common import canon_skill, safe_float, safe_int

INTERJECTION_LABELS = {
    "redirect_goal": "Redirecting / Re-following Goal",
    "debugging": "Debugging / Fixing an Error",
    "thought_process": "Thinking / Design / Q&A",
    "new_scope": "Adding Scope / Next Task",
    "approval": "Approving / Confirming",
    "clarification": "Clarifying / Giving Context",
}

_SYNTHETIC_REPOS = frozenset({"(no repo recorded)", "(workflow sandbox)", "(scratch workspace)"})
_REVIEW_DIAGNOSTIC_SKILLS = frozenset({"code-review", "diagnostic-rigor", "resolve-review-threads"}) | {
    canon_skill(x) for x in (os.environ.get("DEBRIEF_REVIEW_SKILLS") or "").split(",") if canon_skill(x)
}
_WF_RE = re.compile(r"^wf_[0-9a-f-]+$", re.IGNORECASE)
_CLAUDE_PREFIX_RE = re.compile(
    r"^-(?:Users|home|Volumes)-[^-]+-(?:(?:personal-repos|repos|projects|src|code|dev|work|workspace|git|Documents|Desktop)-)?",
    re.IGNORECASE,
)
_WT_SUFFIX_RE = re.compile(r"(?:--claude(?:-worktrees-.*)?|-wt-[A-Za-z0-9._-]+)$")


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


def normalize_repo_name(raw):
    """Collapse raw harness paths and worktree directories into a clean repo name."""
    s = str(raw or "").strip().rstrip("/")
    if not s:
        return "(no repo recorded)"
    low = s.lower()
    if _WF_RE.match(s):
        return "(workflow sandbox)"
    if "scratch-workspaces" in low or "/tmp/" in low or low.startswith("-private-tmp-") or low.startswith("-tmp-"):
        return "(scratch workspace)"
    if "/" in s:
        s = re.sub(r"/\.claude/worktrees/[^/]+.*$", "", s)
        s = re.sub(r"/\.claude$", "", s)
        base = os.path.basename(s.rstrip("/"))
        base = _WT_SUFFIX_RE.sub("", base).strip("-_")
        return base or "(no repo recorded)"
    cleaned = _WT_SUFFIX_RE.sub("", s)
    if cleaned.startswith(("-Users-", "-home-", "-Volumes-")):
        cleaned = _CLAUDE_PREFIX_RE.sub("", cleaned)
        cleaned = _WT_SUFFIX_RE.sub("", cleaned)
    cleaned = cleaned.strip("-_/")
    return cleaned or "(no repo recorded)"


def repo_stats(metas, children):
    """Aggregate session, prompt, tool, error, token, skill, and interjection stats per repository."""
    acc = defaultdict(lambda: {
        "main_sessions": 0,
        "total_sessions": 0,
        "prompts": 0,
        "tool_calls": 0,
        "errors": 0,
        "tokens_total": 0,
        "unattributed_sessions": 0,
        "interjections": 0,
        "reasons": Counter(),
        "skills": Counter(),
    })
    for k, m in metas.items():
        repo = normalize_repo_name(m.get("project") or "")
        row = acc[repo]
        is_main = k not in children
        row["total_sessions"] += 1
        if is_main:
            row["main_sessions"] += 1
        p = safe_int(m.get("prompts"), 0)
        row["prompts"] += p
        row["tool_calls"] += safe_int(m.get("tool_calls"), 0)
        row["errors"] += sum(safe_int(v, 0) for v in (m.get("errors") or {}).values())
        row["tokens_total"] += safe_int(m.get("tokens_in"), 0) + safe_int(m.get("tokens_out"), 0)
        if is_main and p > 1:
            row["interjections"] += p - 1
        skills = {canon_skill(s) for s in (m.get("skill_loads") or []) if canon_skill(s)}
        if not skills:
            row["unattributed_sessions"] += 1
        for sk in skills:
            row["skills"][sk] += 1
        for rk, rv in (m.get("interjection_reasons") or {}).items():
            cnt = safe_int(rv, 0)
            if cnt > 0:
                row["reasons"][rk] += cnt

    out = []
    for repo, r in acc.items():
        top_reason = r["reasons"].most_common(1)[0][0] if r["reasons"] else None
        out.append({
            "repo": repo,
            "main_sessions": r["main_sessions"],
            "total_sessions": r["total_sessions"],
            "prompts": r["prompts"],
            "tool_calls": r["tool_calls"],
            "errors": r["errors"],
            "tokens_total": r["tokens_total"],
            "unattributed_sessions": r["unattributed_sessions"],
            "interjections": r["interjections"],
            "interjection_reasons": dict(r["reasons"]),
            "top_interjection_reason": top_reason,
            "top_skills": [sk for sk, _ in r["skills"].most_common(3)],
        })
    out.sort(key=lambda x: (-x["total_sessions"], -x["prompts"], x["repo"]))
    return out


def interjection_reason_stats(top_metas, all_metas):
    """Aggregate why the user stepped in globally, per skill, and on unattributed sessions."""
    global_reasons = Counter()
    per_skill = defaultdict(Counter)
    unattributed = Counter()
    for m in top_metas:
        for rk, rv in (m.get("interjection_reasons") or {}).items():
            cnt = safe_int(rv, 0)
            if cnt > 0:
                global_reasons[rk] += cnt
    for m in all_metas:
        reasons = {rk: safe_int(rv, 0) for rk, rv in (m.get("interjection_reasons") or {}).items() if safe_int(rv, 0) > 0}
        if not reasons:
            continue
        skills = {canon_skill(s) for s in (m.get("skill_loads") or []) if canon_skill(s)}
        if not skills:
            for rk, cnt in reasons.items():
                unattributed[rk] += cnt
        else:
            for sk in skills:
                for rk, cnt in reasons.items():
                    per_skill[sk][rk] += cnt
    return (
        {k: global_reasons[k] for k in INTERJECTION_LABELS if global_reasons[k] > 0}
        | {k: v for k, v in global_reasons.items() if k not in INTERJECTION_LABELS and v > 0},
        {sk: dict(cnts) for sk, cnts in per_skill.items()},
        dict(unattributed),
    )


def build_skill_recommendations(skill_table, repos, skill_sizes, unattributed_reasons, days_active=14, pareto=None, changepoints=None):
    """Generate evidence-backed Create / Modify / Remove skill recommendations."""
    recs = []
    seen = set()

    def add(action, target, reason, suggestion):
        key = (action, target)
        if key in seen:
            return
        seen.add(key)
        recs.append({"action": action, "target": target, "reason": reason, "suggestion": suggestion})

    cp_skills = (changepoints or {}).get("skills") or {} if isinstance(changepoints, dict) else {}
    pareto_dom_by_skill = {}
    if isinstance(pareto, dict):
        for reg in pareto.get("head_regressions") or []:
            peers = ", ".join(reg.get("dominated_by") or [])
            add(
                "modify",
                reg.get("skill") or "",
                f"Pareto HEAD regression on {reg.get('harness')}: current SHA {reg.get('head_sha')} is strictly dominated by prior version(s) {peers}.",
                f"Revert to {peers} or beat its quality/cost/friction frontier before keeping this edit.",
            )
        for dom in pareto.get("portfolio_dominated") or []:
            dsk = dom.get("skill") or ""
            if dsk in cp_skills and cp_skills[dsk].get("verdict") in ("awaiting_data", "improved"):
                continue
            pareto_dom_by_skill[dsk] = dom

    # 1. MODIFY: existing skills with concrete quality, overhead, nudge, error, redirect, or eval issues.
    used_skills = set()
    for row in skill_table:
        sk = row.get("skill") or ""
        if not sk:
            continue
        mined = safe_int(row.get("mined_loads"), 0)
        loads = mined + safe_int(row.get("hook_loads"), 0)
        if loads > 0:
            used_skills.add(sk)
        cp_info = cp_skills.get(sk)
        cp_note = ""
        is_post_edit = False
        if cp_info:
            if cp_info.get("verdict") == "awaiting_data":
                # Edited recently inside the window with <3 post-edit sessions: do not nag from stale pre-edit history.
                continue
            post = cp_info.get("post") or {}
            if safe_int(post.get("loads"), 0) >= 3:
                is_post_edit = True
                mined = safe_int(post.get("loads"), 0)
                sha_lbl = cp_info.get("edited_sha") or str(cp_info.get("edited_at") or "")[:10]
                cp_note = f" (post-edit since {sha_lbl}, {mined} sess)"
                row = dict(row)
                if post.get("forced_pct") is not None:
                    row["forced_pct"] = post["forced_pct"]
                if post.get("errors_per_session") is not None:
                    row["error_rate_per_session"] = post["errors_per_session"]
                if post.get("redirects_per_session") is not None:
                    row["redirect_interjections"] = round(post["redirects_per_session"] * mined)
                if post.get("overhead_per_load") is not None:
                    row["estimated_context_tax_tokens"] = post["overhead_per_load"] * mined
        need = 3 if is_post_edit else 5
        reasons = []
        suggestions = []
        is_review_diag = sk in _REVIEW_DIAGNOSTIC_SKILLS
        fp = row.get("forced_pct")
        if fp is not None and safe_int(row.get("hook_loads"), 0) >= 3 and safe_float(fp, 0.0) >= 25.0:
            reasons.append(f"{fp}% nudged loads{cp_note}")
            suggestions.append("tighten frontmatter description trigger keywords")
        tax = safe_float(row.get("estimated_context_tax_tokens"), 0.0)
        if tax >= 50_000_000:
            sz = safe_int((skill_sizes or {}).get(sk), 0)
            sz_note = f" (SKILL.md is {sz / 1024.0:.1f} KB)" if sz > 0 else ""
            reasons.append(f"{_fmt_tok(tax)} skill overhead tokens{sz_note}{cp_note}")
            suggestions.append("trim SKILL.md and move detailed tables/procedures into references/")
        err_rate = safe_float(row.get("error_rate_per_session"), 0.0)
        if not is_review_diag and mined >= need and err_rate >= 2.0:
            reasons.append(f"{err_rate:.2f} errors/session{cp_note}")
            suggestions.append("add explicit verification commands and recovery steps")
        if safe_int(row.get("papercut_open"), 0) > 0:
            reasons.append(f"{safe_int(row.get('papercut_open'), 0)} open papercut issue(s)")
            suggestions.append("resolve open papercut issues tied to this skill")
        redirs = safe_int(row.get("redirect_interjections"), 0)
        if not is_review_diag and mined >= need and redirs >= need and (redirs / float(mined)) >= 0.30:
            reasons.append(f"{redirs} goal-redirect interjections ({redirs / float(mined):.2f}/sess){cp_note}")
            suggestions.append("add a concise pre-flight checklist so the agent stays on goal")
        wr = row.get("eval_win_rate")
        nb = row.get("eval_noise_band")
        pr = row.get("eval_pass_rate")
        if wr is not None:
            wr_f = safe_float(wr, 0.0)
            nb_f = safe_float(nb, 0.0) if nb is not None else 0.0
            if wr_f < 0.4 and (wr_f + nb_f) < 0.5:
                add(
                    "remove",
                    sk,
                    f"Blind A/B eval win rate {round(wr_f * 100)}% (±{round(nb_f * 100)}% noise) underperformed stripped baseline.",
                    "Rewrite from scratch or retire this skill and re-run scripts/replay-eval.sh.",
                )
                continue
            if nb_f >= 0.5:
                pr_note = f"; deterministic pass rate {round(safe_float(pr, 0.0) * 100)}%" if pr is not None else ""
                reasons.append(f"A/B judge noise ±{round(nb_f * 100)}% is too high{pr_note}")
                suggestions.append("re-run replay-eval.sh judge with a stronger model (e.g., Sonnet/Opus)")
            elif wr_f <= 0.5 or wr_f <= nb_f:
                reasons.append(f"A/B win rate {round(wr_f * 100)}% (±{round(nb_f * 100)}% noise) inconclusive")
                suggestions.append("sharpen skill instructions or expand eval edge cases")
        dom = pareto_dom_by_skill.get(sk)
        if dom:
            peers = ", ".join(dom.get("dominated_by") or [])
            reasons.append(
                f"Strictly Pareto-dominated in {dom.get('stratum')} ({dom.get('quality_source')}) "
                f"by {peers} (eff={dom.get('effectiveness'):.2f}, ov={dom.get('overhead_per_load', 0)/1e6:.2f}M/load, "
                f"fric={dom.get('friction_per_load'):.2f})"
            )
            suggestions.append(f"trim overhead or reduce friction to reach the frontier defined by {peers}")
        if reasons:
            add("modify", sk, "; ".join(reasons) + ".", "; ".join(dict.fromkeys(suggestions)).capitalize() + ".")

    # 2. CREATE: active repos with many skill-less sessions + friction, or high unattributed redirects/debugging.
    for r in repos:
        repo = r["repo"]
        if repo in _SYNTHETIC_REPOS:
            continue
        unattr = r["unattributed_sessions"]
        red = r["interjection_reasons"].get("redirect_goal", 0)
        dbg = r["interjection_reasons"].get("debugging", 0)
        if unattr >= 10 and (r["errors"] >= 20 or (red + dbg) >= 5):
            add(
                "create",
                f"{repo} workflow skill",
                f"{unattr} sessions in {repo} ran with no skill loaded ({r['errors']:,} tool errors, {red} goal-redirects, {dbg} debugging follow-ups).",
                f"Create a concise workflow skill or repo overlay for {repo} covering its build/test commands and common pitfalls.",
            )
    un_red = safe_int(unattributed_reasons.get("redirect_goal"), 0)
    un_dbg = safe_int(unattributed_reasons.get("debugging"), 0)
    if un_red >= 10:
        add(
            "create",
            "guardrail rule / skill for unattributed goal-redirects",
            f"{un_red} goal-redirect follow-ups occurred in sessions with zero skills loaded.",
            "Mine those sessions via scripts/replay-eval.sh mine --top-steered and codify the recurring checklist in AGENTS.md or a new skill.",
        )
    elif un_dbg >= 15:
        add(
            "create",
            "debugging playbook for unattributed sessions",
            f"{un_dbg} debugging follow-ups occurred in sessions with zero skills loaded.",
            "Ensure your debugging skill triggers automatically or add repo-specific troubleshooting commands to AGENTS.md.",
        )

    # 3. REMOVE / RETIRE: shipped kit skills with zero loads across the window.
    unused = sorted(sk for sk in (skill_sizes or {}) if sk not in used_skills)
    for sk in unused[:5]:
        sz = safe_int(skill_sizes.get(sk), 0)
        add(
            "remove",
            sk,
            f"0 loads across this {days_active}-day window ({sz:,} bytes on disk; description still consumes prompt tokens every turn).",
            "Confirm if this skill is seasonal/rare; otherwise retire or merge it to cut always-loaded description overhead.",
        )
    return recs[:12]


def render_repo_activity_section(agg):
    """Render the Activity by Repository card (bar chart + detailed table)."""
    repos = agg.get("repositories") or []
    if not repos:
        return ""
    top_bars = repos[:8]
    mx = max((r["total_sessions"] for r in top_bars), default=1) or 1
    bars = ['<div class="bar-head"><span>Repository</span><span>Sessions</span></div>']
    for r in top_bars:
        pct = (float(r["total_sessions"]) / float(mx)) * 100.0
        bars.append(
            f'<div class="bar-row">'
            f'<div class="bar-label" title="{_e(r["repo"])}">{_e(r["repo"])}</div>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{pct:.1f}%;background:#0284c7"></div></div>'
            f'<div class="bar-value">{r["total_sessions"]:,}</div></div>'
        )
    trows = []
    for r in repos[:12]:
        skills_str = ", ".join(r["top_skills"]) if r["top_skills"] else "none"
        top_r = INTERJECTION_LABELS.get(r.get("top_interjection_reason") or "", "—")
        trows.append(
            f'<tr><td><code>{_e(r["repo"])}</code></td>'
            f'<td class="num">{r["main_sessions"]:,} / {r["total_sessions"]:,}</td>'
            f'<td class="num">{r["prompts"]:,}</td>'
            f'<td class="num">{r["tool_calls"]:,}</td>'
            f'<td class="num">{r["errors"]:,}</td>'
            f'<td class="num">{_e(_fmt_tok(r["tokens_total"]))}</td>'
            f'<td>{_e(skills_str)}</td>'
            f'<td>{_e(top_r)}</td></tr>'
        )
    return (
        '<div class="chart-card" style="margin:20px 0;overflow-x:auto">'
        '<div class="chart-title">Activity by Repository</div>'
        '<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">'
        'Where your sessions ran (git worktrees and Claude worktree paths are grouped under their parent repo).'
        '</div>'
        + "\n".join(bars)
        + '<table style="margin-top:14px"><thead><tr>'
        '<th>Repository</th>'
        '<th class="num" title="Main user chats / total chats including subagents">Sessions (Main / Total)</th>'
        '<th class="num">User Prompts</th>'
        '<th class="num">Tool Calls</th>'
        '<th class="num">Tool Errors</th>'
        '<th class="num">Tokens Used</th>'
        '<th>Top Skills Used</th>'
        '<th>Top Reason You Stepped In</th>'
        '</tr></thead><tbody>'
        + "".join(trows)
        + '</tbody></table></div>'
    )


def render_interjection_reasons_card(agg):
    """Render Why You Interjected (Follow-Up Intent) bar chart + reading guide."""
    reasons = (agg.get("charts") or {}).get("interjection_reasons") or {}
    if not reasons or not any(safe_int(v, 0) > 0 for v in reasons.values()):
        return (
            '<div class="chart-card" style="margin:20px 0">'
            '<div class="chart-title">Why You Interjected (Follow-Up Intent)</div>'
            '<div class="subtitle" style="margin:0">No follow-up prompts classified in this window.</div></div>'
        )
    items = sorted(((k, safe_int(v, 0)) for k, v in reasons.items() if safe_int(v, 0) > 0), key=lambda kv: (-kv[1], kv[0]))
    total = sum(v for _, v in items) or 1
    mx = items[0][1] or 1
    rows = ['<div class="bar-head"><span>Why you stepped in</span><span>Follow-ups</span></div>']
    for k, v in items:
        lbl = INTERJECTION_LABELS.get(k, k.replace("_", " ").title())
        pct = (float(v) / float(mx)) * 100.0
        share = round(100.0 * v / total)
        rows.append(
            f'<div class="bar-row">'
            f'<div class="bar-label" style="width:205px" title="{_e(lbl)}">{_e(lbl)}</div>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{pct:.1f}%;background:#f97316"></div></div>'
            f'<div class="bar-value" style="width:82px">{v:,} ({share}%)</div></div>'
        )
    return (
        '<div class="chart-card" style="margin:20px 0">'
        '<div class="chart-title">Why You Interjected (Follow-Up Intent)</div>'
        '<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">'
        'Every follow-up prompt (turn #2+) classified locally without storing raw prompt text: '
        '<strong>Redirecting Goal</strong> = agent drifted or skipped a step (strongest signal to tighten a skill); '
        '<strong>Debugging</strong> = errors/failures forced intervention; '
        '<strong>Thinking / Q&amp;A</strong> = deliberate design discussion; '
        '<strong>Adding Scope</strong> = chaining new work; '
        '<strong>Approving</strong> = confirming next steps.'
        '</div>'
        + "\n".join(rows)
        + '</div>'
    )


def render_skill_recommendations_card(agg):
    """Render Recommended Skill Actions (Create / Modify / Remove) card."""
    recs = agg.get("skill_recommendations") or []
    if not recs:
        return ""
    rows = []
    for r in recs:
        act = str(r.get("action") or "modify").lower()
        cls = "act-create" if act == "create" else "act-remove" if act == "remove" else "act-modify"
        rows.append(
            f'<tr>'
            f'<td><span class="action-pill {cls}">{_e(act.upper())}</span></td>'
            f'<td><code>{_e(r.get("target"))}</code></td>'
            f'<td>{_e(r.get("reason"))}</td>'
            f'<td>{_e(r.get("suggestion"))}</td></tr>'
        )
    return (
        '<div class="chart-card" style="margin:0 0 18px;overflow-x:auto">'
        '<div class="chart-title">Recommended Skill Actions (Create / Modify / Remove)</div>'
        '<div style="font-size:12px;color:#64748b;margin:-6px 0 10px">'
        'Auto-prioritized from your repo frequency, skill usage, overhead, error rates, open papercuts, A/B evals, and goal-redirect interjections.'
        '</div>'
        '<table><thead><tr>'
        '<th>Action</th><th>Skill / Repo Target</th><th>Why (Evidence)</th><th>Suggested Next Step</th>'
        '</tr></thead><tbody>'
        + "".join(rows)
        + '</tbody></table></div>'
    )

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
        return f"{_fmt_num(errs)} ({safe_float(rate, 0.0):.2f}/sess)"
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
        (_fmt_tokens(total_attr), "Tokens Tracked"),
        (top_tax_val, "Biggest Skill Overhead"),
    ]
    pc = agg.get("papercuts")
    if isinstance(pc, dict):
        filed = safe_int(pc.get("total_filed"), 0)
        fixed = safe_int(pc.get("total_fixed"), 0)
        open_val = safe_int(pc.get("total_open"), None)
        open_cnt = max(0, open_val) if open_val is not None else max(0, filed - fixed)
        tiles.append((f"{open_cnt} open / {fixed} fixed", "Papercut Issues"))
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
        "(PLANNER_RESPONSE input/output/cache_read), Muse (model_completed or "
        "subagent runtime_observed fallback), Codex (token_usage_record / "
        "token_count), and OpenCode (v2 session_message + v1 step-finish). "
        "Older sessions without usage fields report 0. Per-harness rollups are never ranked."
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
    scorecard_guide = (
        '<details open class="col-guide">'
        '<summary>How to read this scorecard</summary>'
        '<ul>'
        '<li><strong>Sessions Used</strong>: Chats that loaded this skill in transcripts (higher = more impact if you improve it).</li>'
        '<li><strong>Hook Loads / Nudged %</strong>: Loads caught by live hooks, and how often a hook had to remind the agent to load it (lower Nudged % is better; high % means the skill description is not triggering naturally).</li>'
        '<li><strong>Total Tokens</strong>: This skill\'s equal share of all tokens spent in sessions that loaded it.</li>'
        '<li><strong>Skill Overhead (tok)</strong>: Estimated extra tokens spent keeping the <code>SKILL.md</code> text in context across turns (high overhead = good candidate to trim or split into <code>references/</code>).</li>'
        '<li><strong>Reply Gap / Session Len</strong>: Typical wait between your replies (seconds) / typical total session duration (minutes).</li>'
        '<li><strong>Errors (Avg / Session)</strong>: Total tool errors attributed to sessions using this skill, and average errors per session (high avg/sess = check <em>Where Things Go Wrong</em> or file a papercut).</li>'
        '<li><strong>Issues (Open / Fixed)</strong>: Open vs fixed papercut issues tied to this skill (populated when <code>--papercuts</code> is passed).</li>'
        '<li><strong>A/B Win Rate (&plusmn;Noise)</strong>: How often the skill beat a stripped no-skill run in blind replay evals, plus the A/A judge noise band (win rate clearly above noise = proven lift; inside noise = inconclusive or noisy judge).</li>'
        '</ul></details>'
    )
    return (
        '<h2 id="section-harnesses">Harnesses &amp; Skill Effectiveness</h2>'
        f'{_render_flywheel_summary(agg)}'
        '<div class="chart-card" style="margin:0 0 18px">'
        '<div class="chart-title">Per-Harness Activity</div>'
        '<table><thead><tr>'
        '<th>Harness</th>'
        '<th class="num" title="Main user chats / total chats including subagents">Sessions (Main / Total)</th>'
        '<th class="num" title="Sessions classified by semantic facets">Sessions Analyzed</th>'
        '<th class="num" title="User prompts sent">User Prompts</th>'
        '<th class="num" title="Tool invocations executed">Tool Calls</th>'
        '<th class="num" title="Tool calls that returned an error">Tool Errors</th>'
        '<th class="num" title="Input and output tokens attributed to sessions with skills">Tokens Used (In / Out)</th>'
        '</tr></thead>'
        f'<tbody>{"".join(h_rows)}</tbody></table>'
        f'<div style="font-size:12px;color:#64748b;margin-top:8px">{_e(harness_tok_foot)}</div></div>'
        '<div class="chart-card" style="margin:0 0 18px;overflow-x:auto">'
        '<div class="chart-title">Top Skills (Flywheel Scorecard)</div>'
        '<table><thead><tr>'
        '<th>Skill</th>'
        '<th class="num" title="Chats that loaded this skill in transcripts">Sessions Used</th>'
        '<th class="num" title="Loads captured by live hooks">Hook Loads</th>'
        '<th class="num" title="Percent of hook loads forced after a nudge block (lower is better)">Nudged %</th>'
        '<th class="num" title="Equal share of total session tokens">Total Tokens</th>'
        '<th class="num" title="Estimated extra tokens spent keeping SKILL.md in context across turns">Skill Overhead (tok)</th>'
        '<th class="num" title="Median wait between replies (s) / median session length (m)">Reply Gap / Session Len</th>'
        '<th class="num" title="Attributed tool errors and average errors per session">Errors (Avg / Session)</th>'
        '<th class="num" title="Open vs fixed papercut issues linked to this skill">Issues (Open / Fixed)</th>'
        '<th class="num" title="Blind A/B with-skill win rate and A/A judge noise band">A/B Win Rate (&plusmn;Noise)</th>'
        '</tr></thead>'
        f'<tbody>{"".join(s_rows) or "<tr><td colspan=10>No skill loads in window.</td></tr>"}</tbody></table>'
        f'{scorecard_guide}</div>'
    )


_FRICTION_REMEDIATIONS = {
    "hook_or_env_retry": (
        "Hook blocks or environment retries",
        "Agents repeatedly hit a hook guard or missing local tool/env setup and had to retry.",
        "Pre-load the demanded skill in role/agent briefs, check the blocking hook's trigger conditions, or document the required command/env in AGENTS.md.",
    ),
    "tool_failure": (
        "Tool or shell command failures",
        "Commands, tests, or CLI tools exited non-zero and forced recovery turns.",
        "Add a working copy-pasteable verification command to the relevant SKILL.md or AGENTS.md, and file a papercut if a repo script is brittle.",
    ),
    "buggy_code": (
        "Code regressions or failing edits",
        "Generated code or patches failed compilation, lint, or tests and needed rework.",
        "Require running the focused test/lint command right after edits in the skill workflow, and add a replay-eval edge case for the recurring mistake.",
    ),
    "wrong_approach": (
        "Wrong initial approach",
        "The agent started down an unfruitful path before being redirected or backtracking.",
        "Tighten the skill's first step with an explicit scope/evidence check before editing, and add the recurring pitfall to AGENTS.md.",
    ),
    "misunderstood_request": (
        "Misunderstood request or scope",
        "The agent interpreted requirements differently from what was intended.",
        "Clarify non-obvious defaults in AGENTS.md or prompt for a quick confirmation when requirements have multiple valid interpretations.",
    ),
    "missing_path_probe": (
        "Missing file or path guesses",
        "The agent guessed file paths that did not exist instead of locating them first.",
        "Keep key directory pointers accurate in AGENTS.md / repo docs and instruct agents to search before opening guessed paths.",
    ),
    "user_rejected_action": (
        "User-rejected actions",
        "You had to reject a proposed command, edit, or tool action.",
        "Codify the boundary as a clear rule in AGENTS.md or a PreToolUse guard hook so the agent stops proposing it.",
    ),
    "context_loss": (
        "Context loss across turns or compaction",
        "Important decisions or constraints were forgotten mid-session.",
        "Write concise resume notes or plans to a file before long tasks and keep SKILL.md files slim so context lasts longer.",
    ),
    "Command Failed": (
        "Shell commands exiting non-zero",
        "Frequent failing shell invocations across sessions.",
        "Inspect the most common failing command flags/paths, document the canonical invocation in AGENTS.md, and file a papercut for flaky scripts.",
    ),
    "Hook Blocked": (
        "Hook guard blocks",
        "A safety or skill-nudge hook stopped an action before execution.",
        "If the block is legitimate, pre-brief the required skill/rule so agents comply on the first try; if noisy, narrow the hook matcher.",
    ),
    "File Not Found": (
        "File-not-found reads",
        "Agents tried to read paths that moved or do not exist.",
        "Fix stale path links in skills/docs (run check-md-links.sh) and update repo layout pointers in AGENTS.md.",
    ),
    "Edit Failed": (
        "Patch/edit target mismatches",
        "File edits failed because the target snippet did not match the current file.",
        "Read the exact target lines immediately before editing and avoid stale cached snippets across turns.",
    ),
    "Timeout": (
        "Command or tool timeouts",
        "Long-running tests, builds, or network calls exceeded tool timeouts.",
        "Run slow checks asynchronously in the background or narrow the test scope during iteration before running the full suite.",
    ),
    "Permission/Sandbox": (
        "Sandbox or permission denials",
        "Actions attempted outside allowed paths or credentials were blocked.",
        "Keep scratch artifacts inside the workspace or designated scratch dir and document any required host-only steps.",
    ),
    "MCP/API Error": (
        "MCP or API errors",
        "External API or MCP tool calls failed or returned errors.",
        "Check query limits/scopes in mcp-call-rigor and handle transient 5xx responses with bounded retries.",
    ),
}


def render_friction_cards(agg, syn):
    """Render Where Things Go Wrong cards with remediation, falling back to aggregate data."""
    items = syn.get("friction_categories") or []
    intro = syn.get("friction_intro") or ""
    if not items:
        charts = agg.get("charts") or {}
        facets = agg.get("facet_summaries") or []
        pft = charts.get("primary_friction_types") or {}
        tec = charts.get("tool_error_categories") or {}
        src = pft if any(safe_int(v, 0) > 0 for v in pft.values()) else tec
        unit = "sessions" if src is pft else "occurrences"
        top = sorted(((k, safe_int(v, 0)) for k, v in src.items() if safe_int(v, 0) > 0), key=lambda kv: (-kv[1], kv[0]))[:4]
        items = []
        for key, cnt in top:
            title, why, fix = _FRICTION_REMEDIATIONS.get(
                key,
                (key.replace("_", " ").title(), f"Observed {cnt:,} times across this window.", "Inspect affected sessions, add a rule or skill clarification, and file a papercut with scripts/file-papercut.sh."),
            )
            exs = []
            for f in facets:
                if len(exs) >= 2:
                    break
                fmap = f.get("friction") or {}
                detail = str(f.get("friction_detail") or "").strip()
                if key in fmap and detail:
                    sid = str(f.get("session_id") or "")[:12]
                    exs.append(f"[{sid}] {detail[:180]}")
            items.append({
                "title": f"{title} ({cnt:,} {unit})",
                "description": why,
                "examples": exs,
                "remediation": fix,
            })
        if items and not intro:
            intro = "Top recurring failure patterns observed in this window, paired with concrete steps to fix them."

    cards = []
    for f in items:
        ex_li = "".join(f"<li>{_e(ex)}</li>" for ex in (f.get("examples") or []))
        ex_html = f'<ul class="friction-examples">{ex_li}</ul>' if ex_li else ""
        rem = str(f.get("remediation") or "").strip()
        rem_html = f'<div class="friction-fix"><strong>How to remediate:</strong> {_e(rem)}</div>' if rem else ""
        cards.append(
            f'<div class="friction-category">'
            f'<div class="friction-title">{_e(f.get("title"))}</div>'
            f'<div class="friction-desc">{_e(f.get("description"))}</div>'
            f'{ex_html}{rem_html}</div>'
        )
    return intro, "\n".join(cards)

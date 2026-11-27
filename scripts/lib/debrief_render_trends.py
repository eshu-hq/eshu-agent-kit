#!/usr/bin/env python3
"""Skill Quality Trends (Version History) card for /debrief (issue #118)."""
import html
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_evals import _opt_float  # noqa: E402
from debrief_render_skills import _fmt_pct  # noqa: E402

TITLE = "Skill Quality Trends (Version History)"
SHOWN = 5  # newest versions per (skill, harness) on the card


def _e(val):
    return html.escape(str(val if val is not None else ""), quote=True)


def _signed(val, fmt):
    num = _opt_float(val)
    return "—" if num is None else format(num, fmt)


def _win(ver):
    pct = _fmt_pct(ver.get("win_rate"))
    if pct is None:
        return "—"
    band = _fmt_pct(ver.get("noise_band"))
    return f"{pct} (±{band})" if band is not None else pct


def _vs_previous(ver, prev):
    """Win-rate change against the prior version on the same harness."""
    if prev is None:
        return "baseline"
    cur, old = _opt_float(ver.get("win_rate")), _opt_float(prev.get("win_rate"))
    if cur is None or old is None:
        return "—"
    delta = cur - old
    band = max(_opt_float(ver.get("noise_band")) or 0.0, _opt_float(prev.get("noise_band")) or 0.0)
    return "within noise" if abs(delta) <= band else f"{delta * 100:+.0f} pts"


def _row(skill, ver, prev):
    tokens = f'{_signed(ver.get("cost_delta_in"), "+.0f")} / {_signed(ver.get("cost_delta_out"), "+.0f")}'
    pass_rate = _fmt_pct(ver.get("pass_rate_with")) or "—"
    sha_title = _e(ver.get("skill_sha") or "no SKILL.md hash recorded")
    return (
        f'<tr><td><code>{_e(skill)}</code></td><td>{_e(ver.get("harness") or "unknown")}</td>'
        f'<td title="{sha_title}"><code>{_e(ver.get("sha_short"))}</code></td>'
        f'<td>{_e(str(ver.get("last_recorded_at") or "")[:10] or "—")}</td>'
        f'<td class="num">{_e(ver.get("runs"))}</td><td class="num">{_e(_win(ver))}</td>'
        f'<td class="num">{_e(pass_rate)}</td>'
        f'<td class="num">{_e(_signed(ver.get("tool_calls_delta"), "+.1f"))}</td>'
        f'<td class="num">{_e(_signed(ver.get("tool_errors_delta"), "+.1f"))}</td>'
        f'<td class="num">{_e(tokens)}</td><td>{_e(_vs_previous(ver, prev))}</td></tr>'
    )


def render_skill_trends_card(agg):
    """Version history per skill; '' when no trend input was given."""
    trends = agg.get("eval_trends")
    if not isinstance(trends, dict):
        return ""
    rows = []
    for skill, versions in sorted((trends.get("per_skill") or {}).items()):
        series = {}
        for ver in versions if isinstance(versions, list) else []:
            if isinstance(ver, dict):
                series.setdefault(str(ver.get("harness") or ""), []).append(ver)
        for _harness, vers in sorted(series.items()):
            start = max(0, len(vers) - SHOWN)
            rows += [_row(skill, v, vers[start + i - 1] if start + i else None) for i, v in enumerate(vers[start:])]
    head = f'<div class="chart-card" style="margin:0 0 18px;overflow-x:auto"><div class="chart-title">{TITLE}</div>'
    if not rows:
        return head + (
            '<div style="font-size:13px;color:#64748b">No ablation records yet. Run '
            "<code>replay-eval.sh report --history</code> after a replay to start a version history.</div></div>"
        )
    return (
        head + "<table><thead><tr><th>Skill</th><th>Harness</th>"
        '<th title="First 8 hex of the SKILL.md sha256 captured at replay time">Version (sha8)</th><th>Recorded</th>'
        '<th class="num" title="Runs folded into this version">Runs</th>'
        '<th class="num" title="Blind A/B with-skill win rate and A/A noise band">Win Rate (&plusmn;Noise)</th>'
        '<th class="num">Pass Rate</th>'
        '<th class="num" title="Mean with-skill minus stripped tool calls">Tool Calls &Delta;</th>'
        '<th class="num" title="Mean with-skill minus stripped tool errors">Tool Errors &Delta;</th>'
        '<th class="num" title="Mean with-skill minus stripped tokens, in / out">Tokens &Delta; in/out</th>'
        '<th title="Win-rate change vs the prior version on the same harness">vs Previous</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table>'
        '<div style="font-size:12px;color:#64748b;margin-top:8px">Each row is the newest run of one SKILL.md '
        "version (never averaged); a win-rate change inside the noise band is not a signal. "
        f"Newest {SHOWN} versions per harness.</div></div>"
    )

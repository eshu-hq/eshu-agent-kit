#!/usr/bin/env python3
"""Join trigger-eval results (issue #117) into /debrief aggregates and the report card.

Reads `kind == "trigger-eval"` JSON written by `replay-eval.sh trigger --json-out`.
Results never flow through --evals, so win_rate rows are never affected.
"""
import html
import json
import math
import os

from debrief_common import canon_skill

# A live router beats a custom decider, which beats the lexical rubric proxy.
DECIDER_RANK = {"rubric": 0, "cmd": 1, "claude": 2, "agy": 2, "muse": 2, "codex": 2, "opencode": 2}
DECIDER_NOTES = {
    "rubric": "rubric = offline lexical overlap between the prompt and name+description (a proxy).",
    "cmd": "cmd = a custom decider command.",
    "live": "claude/agy/muse/codex/opencode = router-prompt mode over the name+description catalog, not the native skill trigger rate.",
}
_METRICS = ("precision", "recall", "f1", "trigger_rate", "false_trigger_rate")


def _num(val):
    if isinstance(val, bool) or val is None:
        return None
    try:
        out = float(val)
    except (TypeError, ValueError):
        return None
    return out if math.isfinite(out) else None


def _count(val):
    num = _num(val)
    return max(0, int(num)) if num is not None else 0


def _files(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            files += [os.path.join(path, fn) for fn in sorted(os.listdir(path)) if fn.endswith(".json")]
        elif os.path.isfile(path):
            files.append(path)
        else:
            raise SystemExit(f"aggregate: cannot read --trigger-evals path {path!r}: not found")
    return files


def trigger_stats(paths):
    """Newest result per (skill, decider) from trigger-eval JSON; None without paths."""
    paths = [p for p in (paths or []) if str(p).strip()]
    if not paths:
        return None
    per_skill, loaded = {}, 0
    for fp in _files(paths):
        try:
            with open(fp, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            raise SystemExit(f"aggregate: cannot read --trigger-evals file {fp!r}: {exc}")
        if not isinstance(doc, dict) or doc.get("kind") != "trigger-eval":
            raise SystemExit(f"aggregate: --trigger-evals file {fp!r} is not a trigger-eval summary (kind must be 'trigger-eval')")
        loaded += 1
        decider, stamp = str(doc.get("decider") or "unknown"), str(doc.get("recorded_at") or "")
        doc_errors = _count(doc.get("errors"))
        for row in doc.get("per_skill") if isinstance(doc.get("per_skill"), list) else []:
            skill = canon_skill(row.get("skill")) if isinstance(row, dict) else ""
            counts = {k: _count(row.get(k)) for k in ("tp", "fp", "fn", "tn")} if skill else {}
            if not skill or not sum(counts.values()):
                continue
            entry = {"decider": decider, "mode": str(doc.get("mode") or ""), "recorded_at": stamp,
                     "partial": doc_errors > 0, "errors": doc_errors, **counts,
                     **{k: _num(row.get(k)) for k in _METRICS}}
            prev = per_skill.setdefault(skill, {}).get(decider)
            if prev is None or stamp >= prev["recorded_at"]:
                per_skill[skill][decider] = entry
    return {"sources": paths, "files_loaded": loaded, "skills_evaluated": len(per_skill),
            "per_skill": dict(sorted(per_skill.items()))}


def _preferred(by_decider):
    if not by_decider:
        return None
    return max(by_decider.values(), key=lambda e: (DECIDER_RANK.get(e["decider"], 1), e["recorded_at"]))


def join_trigger_rows(skill_table, stats):
    """Add trigger_precision/recall/f1/decider to every skill-table row (None when absent)."""
    per_skill = (stats or {}).get("per_skill") or {}
    for row in skill_table:
        best = _preferred(per_skill.get(row["skill"]))
        row["trigger_precision"] = best["precision"] if best else None
        row["trigger_recall"] = best["recall"] if best else None
        row["trigger_f1"] = best["f1"] if best else None
        row["trigger_decider"] = best["decider"] if best else None


def _cell(val):
    return "—" if val is None else f"{val:.2f}"


def render_trigger_card(agg):
    """Trigger precision/recall beside the forced share; '' when no trigger evals were loaded."""
    stats = agg.get("trigger_evals")
    if not isinstance(stats, dict):
        return ""
    forced = {r.get("skill"): r.get("forced_pct") for r in agg.get("skill_table") or []}
    rows = sorted(
        (_preferred(by) | {"skill": skill} for skill, by in (stats.get("per_skill") or {}).items()),
        key=lambda e: (e["f1"] is None, e["f1"] if e["f1"] is not None else 0.0, e["skill"]),
    )[:15]
    body = "".join(
        f'<tr><td><code>{html.escape(e["skill"])}</code></td>'
        f'<td><code>{html.escape(e["decider"])}</code>{" (partial)" if e.get("partial") else ""}</td>'
        f'<td class="num">{_cell(e["precision"])}</td><td class="num">{_cell(e["recall"])}</td>'
        f'<td class="num">{_cell(e["f1"])}</td><td class="num">{e["fp"]} / {e["fn"]}</td>'
        f'<td class="num">{"—" if forced.get(e["skill"]) is None else str(forced[e["skill"]]) + "%"}</td></tr>'
        for e in rows
    ) or "<tr><td colspan=7>No labelled trigger results.</td></tr>"
    seen = {e["decider"] for by in (stats.get("per_skill") or {}).values() for e in by.values()}
    notes = [DECIDER_NOTES["rubric"]] * ("rubric" in seen) + [DECIDER_NOTES["cmd"]] * ("cmd" in seen)
    notes += [DECIDER_NOTES["live"]] * bool(seen & {"claude", "agy", "muse", "codex", "opencode"})
    return (
        '<div class="chart-card" style="margin:0 0 18px;overflow-x:auto">'
        '<div class="chart-title">Trigger Precision / Recall</div>'
        '<table><thead><tr><th>Skill</th><th title="Which decider produced these numbers">Decider</th>'
        '<th class="num">Precision</th><th class="num">Recall</th><th class="num">F1</th>'
        '<th class="num" title="False positives / false negatives">FP / FN</th>'
        '<th class="num" title="Percent of hook loads forced after a nudge (live usage)">Nudged %</th></tr></thead>'
        f'<tbody>{body}</tbody></table>'
        f'<div style="font-size:12px;color:#64748b;margin-top:8px">Scored from skill names and descriptions only. '
        f'{html.escape(" ".join(notes))} Lowest F1 first.</div></div>'
    )

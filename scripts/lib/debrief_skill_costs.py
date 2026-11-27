#!/usr/bin/env python3
"""Per-skill cost, context tax, latency, and error attribution for /debrief v2.

Implements issues #80 and #100: every Stage 1 meta mines ``tokens_in`` /
``tokens_out`` / ``tokens_cache_read`` / ``tokens_cache_write`` across Claude
(assistant usage + cache), agy (PLANNER_RESPONSE input/output/cache_read), and
Muse (main-session ``model_completed`` usage with fallback to subagent
``runtime_observed``), plus ``skill_loads``, ``turns_after_skill_load``,
``response_gaps``, ``duration_minutes``, and ``errors``.

Scope rules:
- Aggregate ALL metas (top-level and children); never inherit parent skills
  onto children — each record attributes only its own ``skill_loads``.
- Per-harness token rollups reconcile exactly: attributed + unattributed =
  harness totals = global totals (up to float rounding).
- Response gaps are tagged with their meta's harness; per-harness medians sit
  beside the global median. No cross-harness cost ranking is emitted anywhere.
"""

import math
import os
from collections import Counter, defaultdict

from debrief_common import canon_skill, gap_bucket, safe_int  # noqa: E402


def load_skill_sizes(kit_root=None, skills_dirs=None):
    """Map canonical skill name -> SKILL.md byte size across flat or layered skill dirs."""
    roots = []
    if skills_dirs:
        roots.extend(os.path.expanduser(str(d)) for d in skills_dirs if str(d).strip())
    else:
        env_dirs = (os.environ.get("DEBRIEF_SKILLS_DIRS") or "").strip()
        if env_dirs:
            roots.extend(os.path.expanduser(d) for d in env_dirs.split(os.pathsep) if d.strip())
    if not roots:
        root = kit_root or os.path.abspath(
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
        )
        roots.append(os.path.join(root, "skills"))

    sizes = {}
    for sroot in roots:
        if not os.path.isdir(sroot):
            continue
        for entry in sorted(os.listdir(sroot)):
            edir = os.path.join(sroot, entry)
            if not os.path.isdir(edir):
                continue
            direct_md = os.path.join(edir, "SKILL.md")
            if os.path.isfile(direct_md):
                sk = canon_skill(entry)
                if sk:
                    try:
                        sizes[sk] = os.path.getsize(direct_md)
                    except OSError:
                        pass
                continue
            for sname in sorted(os.listdir(edir)):
                md = os.path.join(edir, sname, "SKILL.md")
                if not os.path.isfile(md):
                    continue
                sk = canon_skill(sname)
                if not sk:
                    continue
                try:
                    sizes[sk] = os.path.getsize(md)
                except OSError:
                    continue
    return sizes


def _meta_errors(meta):
    """Total error count for one meta (sum of per-tool error hits)."""
    try:
        return sum((meta.get("errors") or {}).values())
    except (AttributeError, TypeError):
        return 0


def _nonneg_float(val):
    if isinstance(val, bool) or val is None:
        return 0.0
    try:
        num = float(val)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, num) if math.isfinite(num) else 0.0


def _meta_tokens(meta):
    """(tokens_in, tokens_out, cache_read, cache_write) as non-negative floats."""
    return (
        _nonneg_float(meta.get("tokens_in")),
        _nonneg_float(meta.get("tokens_out")),
        _nonneg_float(meta.get("tokens_cache_read")),
        _nonneg_float(meta.get("tokens_cache_write")),
    )


def _upper_median(vals):
    """Upper median matching the aggregate's historical convention."""
    if not vals:
        return None
    s = sorted(vals)
    return round(float(s[len(s) // 2]), 1)


def _normalize_sizes(skill_sizes):
    sizes = {}
    if not isinstance(skill_sizes, dict):
        return sizes
    for k, v in skill_sizes.items():
        ck = canon_skill(k)
        sz = safe_int(v, 0)
        if ck and sz > 0:
            sizes[ck] = sz
    return sizes


def attribute_skill_costs(metas, skill_sizes=None):
    """Attribute tokens, cache, context tax, latency, and errors across ALL metas.

    ``metas`` is an iterable of Stage 1 meta dicts. ``skill_sizes`` is an
    optional dict mapping canonical skill names to ``SKILL.md`` byte sizes
    (default ``None`` for backward compatibility). Returns a dict with
    ``per_skill`` (sorted by attributed token total, desc), ``by_harness``,
    ``unattributed``, ``totals``, ``mined_skills``, and ``caveats``.
    """
    sizes = _normalize_sizes(skill_sizes)
    per_skill = defaultdict(lambda: {
        "attributed_tokens_in": 0.0,
        "attributed_tokens_out": 0.0,
        "attributed_cache_read": 0.0,
        "attributed_cache_write": 0.0,
        "attributed_errors": 0.0,
        "estimated_context_tax_tokens": 0.0,
        "sessions": 0,
        "token_bearing_sessions": 0,
        "gaps": [],
        "durations": [],
    })
    mined_skills = Counter()
    by_harness = defaultdict(lambda: {
        "sessions": 0,
        "token_bearing_sessions": 0,
        "tokens_in": 0.0,
        "tokens_out": 0.0,
        "tokens_cache_read": 0.0,
        "tokens_cache_write": 0.0,
        "errors": 0,
        "attributed_tokens_in": 0.0,
        "attributed_tokens_out": 0.0,
        "attributed_cache_read": 0.0,
        "attributed_cache_write": 0.0,
        "attributed_errors": 0.0,
        "unattributed_tokens_in": 0.0,
        "unattributed_tokens_out": 0.0,
        "unattributed_cache_read": 0.0,
        "unattributed_cache_write": 0.0,
        "unattributed_errors": 0,
        "unattributed_sessions": 0,
    })
    unattributed = {
        "sessions": 0, "tokens_in": 0.0, "tokens_out": 0.0,
        "tokens_cache_read": 0.0, "tokens_cache_write": 0.0, "errors": 0,
    }
    totals = {
        "sessions": 0, "tokens_in": 0.0, "tokens_out": 0.0,
        "tokens_cache_read": 0.0, "tokens_cache_write": 0.0, "errors": 0,
    }

    for meta in metas:
        if not isinstance(meta, dict):
            continue
        harness = str(meta.get("harness") or "unknown")
        skills = sorted({canon_skill(s) for s in (meta.get("skill_loads") or []) if canon_skill(s)})
        for skill in skills:
            mined_skills[skill] += 1
        tin, tout, cr, cw = _meta_tokens(meta)
        errs = _meta_errors(meta)
        bearing = (tin + tout) > 0

        totals["sessions"] += 1
        totals["tokens_in"] += tin
        totals["tokens_out"] += tout
        totals["tokens_cache_read"] += cr
        totals["tokens_cache_write"] += cw
        totals["errors"] += errs
        bucket = by_harness[harness]
        bucket["sessions"] += 1
        bucket["tokens_in"] += tin
        bucket["tokens_out"] += tout
        bucket["tokens_cache_read"] += cr
        bucket["tokens_cache_write"] += cw
        bucket["errors"] += errs
        if bearing:
            bucket["token_bearing_sessions"] += 1

        if not skills:
            unattributed["sessions"] += 1
            unattributed["tokens_in"] += tin
            unattributed["tokens_out"] += tout
            unattributed["tokens_cache_read"] += cr
            unattributed["tokens_cache_write"] += cw
            unattributed["errors"] += errs
            bucket["unattributed_sessions"] += 1
            bucket["unattributed_tokens_in"] += tin
            bucket["unattributed_tokens_out"] += tout
            bucket["unattributed_cache_read"] += cr
            bucket["unattributed_cache_write"] += cw
            bucket["unattributed_errors"] += errs
            continue

        raw_pla = meta.get("post_load_attribution")
        pla = {}
        if isinstance(raw_pla, dict) and raw_pla:
            for k, v in raw_pla.items():
                ck = canon_skill(k)
                if ck in skills and isinstance(v, dict):
                    pla[ck] = {
                        "in": _nonneg_float(v.get("tokens_in")),
                        "out": _nonneg_float(v.get("tokens_out")),
                        "cr": _nonneg_float(v.get("tokens_cache_read")),
                        "cw": _nonneg_float(v.get("tokens_cache_write")),
                        "err": _nonneg_float(v.get("errors")),
                    }
        # A v4 meta carrying post_load_attribution keys for its skills is exact
        # even when every share is zero (all work was pre-load); only a meta
        # with no matching keys (legacy v3) falls back to equal-split.
        use_pla = bool(pla)

        if use_pla:
            sum_in = min(tin, sum(v["in"] for v in pla.values()))
            sum_out = min(tout, sum(v["out"] for v in pla.values()))
            sum_cr = min(cr, sum(v["cr"] for v in pla.values()))
            sum_cw = min(cw, sum(v["cw"] for v in pla.values()))
            sum_err = min(float(errs), sum(v["err"] for v in pla.values()))
            raw_sum_in = sum(v["in"] for v in pla.values())
            raw_sum_out = sum(v["out"] for v in pla.values())
            raw_sum_cr = sum(v["cr"] for v in pla.values())
            raw_sum_cw = sum(v["cw"] for v in pla.values())
            raw_sum_err = sum(v["err"] for v in pla.values())
            scale_in = (sum_in / raw_sum_in) if raw_sum_in > 0 else 0.0
            scale_out = (sum_out / raw_sum_out) if raw_sum_out > 0 else 0.0
            scale_cr = (sum_cr / raw_sum_cr) if raw_sum_cr > 0 else 0.0
            scale_cw = (sum_cw / raw_sum_cw) if raw_sum_cw > 0 else 0.0
            scale_err = (sum_err / raw_sum_err) if raw_sum_err > 0 else 0.0
            pre_in, pre_out = max(0.0, tin - sum_in), max(0.0, tout - sum_out)
            pre_cr, pre_cw = max(0.0, cr - sum_cr), max(0.0, cw - sum_cw)
            pre_err = max(0.0, float(errs) - sum_err)
            bucket["attributed_tokens_in"] += sum_in
            bucket["attributed_tokens_out"] += sum_out
            bucket["attributed_cache_read"] += sum_cr
            bucket["attributed_cache_write"] += sum_cw
            bucket["attributed_errors"] += sum_err
            unattributed["tokens_in"] += pre_in
            unattributed["tokens_out"] += pre_out
            unattributed["tokens_cache_read"] += pre_cr
            unattributed["tokens_cache_write"] += pre_cw
            unattributed["errors"] += pre_err
            bucket["unattributed_tokens_in"] += pre_in
            bucket["unattributed_tokens_out"] += pre_out
            bucket["unattributed_cache_read"] += pre_cr
            bucket["unattributed_cache_write"] += pre_cw
            bucket["unattributed_errors"] += pre_err
        else:
            n = len(skills)
            share_in = tin / n
            share_out = tout / n
            share_cr = cr / n
            share_cw = cw / n
            share_err = errs / n
            bucket["attributed_tokens_in"] += tin
            bucket["attributed_tokens_out"] += tout
            bucket["attributed_cache_read"] += cr
            bucket["attributed_cache_write"] += cw
            bucket["attributed_errors"] += errs

        raw_gaps = [
            float(g) for g in (meta.get("response_gaps") or [])
            if isinstance(g, (int, float)) and not isinstance(g, bool) and math.isfinite(g) and g >= 2
        ]
        dur = meta.get("duration_minutes")
        valid_dur = (
            float(dur)
            if isinstance(dur, (int, float)) and not isinstance(dur, bool) and math.isfinite(dur) and dur > 0
            else None
        )
        raw_tasl = meta.get("turns_after_skill_load")
        tasl = {}
        if isinstance(raw_tasl, dict):
            for k, v in raw_tasl.items():
                ck = canon_skill(k)
                if ck:
                    tasl[ck] = max(1, safe_int(v, 1))
        fallback_turns = max(1, safe_int(meta.get("assistant_messages"), 0))

        for skill in skills:
            row = per_skill[skill]
            row["sessions"] += 1
            if use_pla:
                pv = pla.get(skill) or {"in": 0.0, "out": 0.0, "cr": 0.0, "cw": 0.0, "err": 0.0}
                row["attributed_tokens_in"] += pv["in"] * scale_in
                row["attributed_tokens_out"] += pv["out"] * scale_out
                row["attributed_cache_read"] += pv["cr"] * scale_cr
                row["attributed_cache_write"] += pv["cw"] * scale_cw
                row["attributed_errors"] += pv["err"] * scale_err
            else:
                row["attributed_tokens_in"] += share_in
                row["attributed_tokens_out"] += share_out
                row["attributed_cache_read"] += share_cr
                row["attributed_cache_write"] += share_cw
                row["attributed_errors"] += share_err
            if bearing:
                row["token_bearing_sessions"] += 1
            if raw_gaps:
                row["gaps"].extend(raw_gaps)
            if valid_dur is not None:
                row["durations"].append(valid_dur)
            if skill in sizes:
                turns = tasl.get(skill, fallback_turns)
                row["estimated_context_tax_tokens"] += (sizes[skill] / 4.0) * turns

    per_skill_rows = []
    for skill, row in per_skill.items():
        total = row["attributed_tokens_in"] + row["attributed_tokens_out"]
        sess_n = row["sessions"]
        per_skill_rows.append({
            "skill": skill,
            "sessions": sess_n,
            "token_bearing_sessions": row["token_bearing_sessions"],
            "attributed_tokens_in": round(row["attributed_tokens_in"], 2),
            "attributed_tokens_out": round(row["attributed_tokens_out"], 2),
            "attributed_tokens_total": round(total, 2),
            "attributed_cache_read": round(row["attributed_cache_read"], 2),
            "attributed_cache_write": round(row["attributed_cache_write"], 2),
            "attributed_errors": round(row["attributed_errors"], 2),
            "error_rate_per_session": round(row["attributed_errors"] / sess_n, 2) if sess_n else 0.0,
            "median_gap_s": _upper_median(row["gaps"]),
            "median_duration_min": _upper_median(row["durations"]),
            "estimated_context_tax_tokens": round(row["estimated_context_tax_tokens"], 2),
        })
    per_skill_rows.sort(key=lambda r: (-r["attributed_tokens_total"], r["skill"]))

    for harness in by_harness:
        for key in ("tokens_in", "tokens_out", "tokens_cache_read", "tokens_cache_write",
                    "attributed_tokens_in", "attributed_tokens_out",
                    "attributed_cache_read", "attributed_cache_write",
                    "unattributed_tokens_in", "unattributed_tokens_out",
                    "unattributed_cache_read", "unattributed_cache_write"):
            by_harness[harness][key] = round(by_harness[harness][key], 2)
        by_harness[harness]["attributed_errors"] = round(by_harness[harness]["attributed_errors"], 2)

    return {
        "per_skill": per_skill_rows,
        "by_harness": dict(sorted(by_harness.items())),
        "unattributed": {
            "sessions": unattributed["sessions"],
            "tokens_in": round(unattributed["tokens_in"], 2),
            "tokens_out": round(unattributed["tokens_out"], 2),
            "tokens_cache_read": round(unattributed["tokens_cache_read"], 2),
            "tokens_cache_write": round(unattributed["tokens_cache_write"], 2),
            "errors": round(unattributed["errors"], 2),
        },
        "totals": {
            "sessions": totals["sessions"],
            "tokens_in": round(totals["tokens_in"], 2),
            "tokens_out": round(totals["tokens_out"], 2),
            "tokens_cache_read": round(totals["tokens_cache_read"], 2),
            "tokens_cache_write": round(totals["tokens_cache_write"], 2),
            "errors": totals["errors"],
        },
        "mined_skills": dict(mined_skills),
        "caveats": [
            "Post-load attribution credits tokens and errors only to skills already loaded at each turn (pre-load work and skill-free sessions land in unattributed); legacy metas fall back to equal-split.",
            "Tokens are mined across Claude (assistant usage + cache), agy "
            "(PLANNER_RESPONSE input/output/cache_read), and Muse (main-session "
            "model_completed usage, falling back to subagent runtime_observed). "
            "Older sessions lacking usage fields report 0. No cross-harness "
            "cost ranking is intended.",
            "Estimated context tax approximates (SKILL.md bytes / 4) * "
            "turns_after_load; gaps, tokens, and errors are mined per session, "
            "so zero-prompt or missing-usage windows are lower bounds.",
        ],
    }


def gap_stats(gaps_with_harness):
    """Summarize (gap_seconds, harness) pairs tagged per meta.

    Returns ``(buckets, med_gap, avg_gap, med_by_harness)`` where buckets use
    the shared gap buckets, med/avg follow the aggregate convention, and
    ``med_by_harness`` maps each harness to its own median (None when empty).
    """
    gaps = [float(g) for g, _ in gaps_with_harness]
    buckets = Counter(gap_bucket(g) for g in gaps)
    med_gap = _upper_median(gaps)
    avg_gap = round(sum(gaps) / len(gaps), 1) if gaps else None
    per_harness = defaultdict(list)
    for gap, harness in gaps_with_harness:
        per_harness[str(harness or "unknown")].append(float(gap))
    med_by_harness = {h: _upper_median(v) for h, v in sorted(per_harness.items())}
    return buckets, med_gap, avg_gap, med_by_harness

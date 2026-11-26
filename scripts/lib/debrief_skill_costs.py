#!/usr/bin/env python3
"""Per-skill cost, latency, and error attribution for the /debrief v2 aggregate.

Implements the issue #80 design: every Stage 1 meta already mines
``tokens_in``/``tokens_out`` (Muse: subagent runtime-observed usage only;
Claude: assistant usage blocks; agy: not mined, always 0), ``skill_loads``,
``response_gaps``, and ``errors``. This module splits one meta's
``tokens_in``, ``tokens_out``, and total error count equally among the
distinct canonical skills in that record's own ``skill_loads``. Sessions with
no loaded skill accumulate into an explicit ``unattributed`` total.

Scope rules (arbiter design, do not redesign):

- Aggregate ALL metas (top-level and children); never inherit parent skills
  onto children — each record attributes only its own ``skill_loads``.
- Per-harness token rollups reconcile exactly: attributed + unattributed =
  harness totals = global totals (up to float rounding).
- Response gaps are tagged with their meta's harness; per-harness medians sit
  beside the global median. No cross-harness cost ranking is emitted anywhere.
"""

from collections import Counter, defaultdict

from debrief_common import canon_skill, gap_bucket  # noqa: E402


def _meta_errors(meta):
    """Total error count for one meta (sum of per-tool error hits)."""
    try:
        return sum((meta.get("errors") or {}).values())
    except (AttributeError, TypeError):
        return 0


def _meta_tokens(meta):
    """(tokens_in, tokens_out) for one meta as floats, lossy values coerced to 0."""
    try:
        tin = float(meta.get("tokens_in") or 0)
    except (TypeError, ValueError):
        tin = 0.0
    try:
        tout = float(meta.get("tokens_out") or 0)
    except (TypeError, ValueError):
        tout = 0.0
    return max(0.0, tin), max(0.0, tout)


def _upper_median(vals):
    """Upper median matching the aggregate's historical convention."""
    if not vals:
        return None
    s = sorted(vals)
    return round(float(s[len(s) // 2]), 1)


def attribute_skill_costs(metas):
    """Attribute tokens/errors across ALL metas to their own canonical skills.

    ``metas`` is an iterable of Stage 1 meta dicts. Returns a dict with
    ``per_skill`` (sorted by attributed token total, desc), ``by_harness``,
    ``unattributed``, ``totals``, ``mined_skills``, and ``caveats``.
    Field names: ``attributed_tokens_in`` / ``attributed_tokens_out`` /
    ``attributed_errors`` / ``token_bearing_sessions`` per skill and harness.
    """
    per_skill = defaultdict(lambda: {
        "attributed_tokens_in": 0.0,
        "attributed_tokens_out": 0.0,
        "attributed_errors": 0.0,
        "sessions": 0,
        "token_bearing_sessions": 0,
    })
    mined_skills = Counter()
    by_harness = defaultdict(lambda: {
        "sessions": 0,
        "token_bearing_sessions": 0,
        "tokens_in": 0.0,
        "tokens_out": 0.0,
        "errors": 0,
        "attributed_tokens_in": 0.0,
        "attributed_tokens_out": 0.0,
        "attributed_errors": 0.0,
        "unattributed_tokens_in": 0.0,
        "unattributed_tokens_out": 0.0,
        "unattributed_errors": 0,
        "unattributed_sessions": 0,
    })
    unattributed = {"sessions": 0, "tokens_in": 0.0, "tokens_out": 0.0, "errors": 0}
    totals = {"sessions": 0, "tokens_in": 0.0, "tokens_out": 0.0, "errors": 0}

    for meta in metas:
        if not isinstance(meta, dict):
            continue
        harness = str(meta.get("harness") or "unknown")
        skills = sorted({canon_skill(s) for s in (meta.get("skill_loads") or []) if canon_skill(s)})
        for skill in skills:
            mined_skills[skill] += 1
        tin, tout = _meta_tokens(meta)
        errs = _meta_errors(meta)
        bearing = (tin + tout) > 0

        totals["sessions"] += 1
        totals["tokens_in"] += tin
        totals["tokens_out"] += tout
        totals["errors"] += errs
        bucket = by_harness[harness]
        bucket["sessions"] += 1
        bucket["tokens_in"] += tin
        bucket["tokens_out"] += tout
        bucket["errors"] += errs
        if bearing:
            bucket["token_bearing_sessions"] += 1

        if not skills:
            unattributed["sessions"] += 1
            unattributed["tokens_in"] += tin
            unattributed["tokens_out"] += tout
            unattributed["errors"] += errs
            bucket["unattributed_sessions"] += 1
            bucket["unattributed_tokens_in"] += tin
            bucket["unattributed_tokens_out"] += tout
            bucket["unattributed_errors"] += errs
            continue

        share_in = tin / len(skills)
        share_out = tout / len(skills)
        share_err = errs / len(skills)
        bucket["attributed_tokens_in"] += tin
        bucket["attributed_tokens_out"] += tout
        bucket["attributed_errors"] += errs
        for skill in skills:
            row = per_skill[skill]
            row["sessions"] += 1
            row["attributed_tokens_in"] += share_in
            row["attributed_tokens_out"] += share_out
            row["attributed_errors"] += share_err
            if bearing:
                row["token_bearing_sessions"] += 1

    per_skill_rows = []
    for skill, row in per_skill.items():
        total = row["attributed_tokens_in"] + row["attributed_tokens_out"]
        per_skill_rows.append({
            "skill": skill,
            "sessions": row["sessions"],
            "token_bearing_sessions": row["token_bearing_sessions"],
            "attributed_tokens_in": round(row["attributed_tokens_in"], 2),
            "attributed_tokens_out": round(row["attributed_tokens_out"], 2),
            "attributed_tokens_total": round(total, 2),
            "attributed_errors": round(row["attributed_errors"], 2),
        })
    per_skill_rows.sort(key=lambda r: (-r["attributed_tokens_total"], r["skill"]))

    for harness in by_harness:
        for key in ("tokens_in", "tokens_out", "attributed_tokens_in",
                    "attributed_tokens_out", "unattributed_tokens_in",
                    "unattributed_tokens_out"):
            by_harness[harness][key] = round(by_harness[harness][key], 2)
        by_harness[harness]["attributed_errors"] = round(by_harness[harness]["attributed_errors"], 2)

    return {
        "per_skill": per_skill_rows,
        "by_harness": dict(sorted(by_harness.items())),
        "unattributed": {
            "sessions": unattributed["sessions"],
            "tokens_in": round(unattributed["tokens_in"], 2),
            "tokens_out": round(unattributed["tokens_out"], 2),
            "errors": unattributed["errors"],
        },
        "totals": {
            "sessions": totals["sessions"],
            "tokens_in": round(totals["tokens_in"], 2),
            "tokens_out": round(totals["tokens_out"], 2),
            "errors": totals["errors"],
        },
        "mined_skills": dict(mined_skills),
        "caveats": [
            "Token/error shares split each session's tokens_in, tokens_out, "
            "and error count equally among its own distinct canonical "
            "skills; sessions with no loaded skill land in unattributed.",
            "Muse tokens are subagent-observed only (subagent "
            "runtime_observed usage); agy transcripts carry no token usage "
            "(not mined). No cross-harness cost ranking is intended.",
            "Gaps, tokens, and errors are mined per session; zero-prompt or "
            "mining-loss windows understate their totals, so rates are "
            "lower bounds.",
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


#!/usr/bin/env python3
"""Replay-eval summary loading for debrief (issue #118 split from aggregate)."""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_common import canon_skill, ts_to_epoch  # noqa: E402


def _opt_float(val):
    if isinstance(val, bool) or val is None:
        return None
    try:
        num = float(val)
    except (TypeError, ValueError):
        return None
    return num if math.isfinite(num) else None


def _opt_int(val):
    if isinstance(val, bool) or val is None:
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        return None


def _should_replace_eval(prev, cand):
    old_ts, new_ts = prev.get("recorded_at") or "", cand.get("recorded_at") or ""
    if old_ts and new_ts:
        old_ep, new_ep = ts_to_epoch(old_ts), ts_to_epoch(new_ts)
        if old_ep is not None and new_ep is not None:
            return new_ep >= old_ep
        if old_ep is not None and new_ep is None:
            return False
        if old_ep is None and new_ep is not None:
            return True
        return new_ts >= old_ts
    return bool(new_ts) or not old_ts


def eval_stats(paths):
    """Per-skill replay-eval summary from offline JSON file(s) or directories.

    Accepts a path or sequence of paths. Each file may hold a single JSON
    object, a JSON array, or ``{"evals": [...]}``; directories expand to
    sorted ``*.json`` files. Deduplicates per canonical skill keeping the
    newest ``recorded_at`` (or last when tied/absent). Offline only.
    """
    if not paths:
        return None
    raw_paths = [paths] if isinstance(paths, str) else list(paths)
    clean_paths = [p for p in raw_paths if p and str(p).strip()]
    if not clean_paths:
        return None
    files = []
    for p in clean_paths:
        if os.path.isdir(p):
            for fn in sorted(os.listdir(p)):
                fp = os.path.join(p, fn)
                if fn.endswith(".json") and os.path.isfile(fp):
                    files.append(fp)
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise SystemExit(f"aggregate: cannot read --evals path {p!r}: not found")
    per_skill = {}
    loaded = skipped = 0
    for fp in files:
        try:
            with open(fp, encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError) as exc:
            raise SystemExit(f"aggregate: cannot read --evals file {fp!r}: {exc}")
        if isinstance(raw, list):
            recs = raw
        elif isinstance(raw, dict) and isinstance(raw.get("evals"), list):
            recs = raw["evals"]
        elif isinstance(raw, dict):
            recs = [raw]
        else:
            raise SystemExit(f"aggregate: --evals file {fp!r} must be a JSON object, array, or {{\"evals\": [...]}}")
        for rec in recs:
            if not isinstance(rec, dict):
                skipped += 1
                continue
            skill = canon_skill(str(rec.get("skill") or "").rstrip("."))
            if not skill:
                skipped += 1
                continue
            loaded += 1
            entry = {
                "skill": skill,
                "win_rate": _opt_float(rec.get("win_rate")),
                "noise_band": _opt_float(rec.get("noise_band")),
                "pass_rate_with": _opt_float(rec.get("pass_rate_with")),
                "pass_rate_without": _opt_float(rec.get("pass_rate_without")),
                "cross_pairs": _opt_int(rec.get("cross_pairs")),
                "cost_delta_in": _opt_float(rec.get("cost_delta_in")),
                "cost_delta_out": _opt_float(rec.get("cost_delta_out")),
                "latency_delta_s": _opt_float(rec.get("latency_delta_s")),
                "harness": str(rec.get("harness") or ""),
                "recorded_at": str(rec.get("recorded_at") or ""),
            }
            prev = per_skill.get(skill)
            if prev is None or _should_replace_eval(prev, entry):
                per_skill[skill] = entry
    return {
        "sources": clean_paths,
        "skills_evaluated": len(per_skill),
        "records_loaded": loaded,
        "records_skipped": skipped,
        "per_skill": dict(sorted(per_skill.items())),
    }

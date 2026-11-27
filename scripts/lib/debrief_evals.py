#!/usr/bin/env python3
"""Replay-eval summary loading for debrief (issue #118 split from aggregate)."""
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_common import canon_skill, default_eval_history, ts_to_epoch  # noqa: E402

VERSIONS_KEPT = 20  # newest versions kept per (skill, harness) in the aggregate


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


_HEX_SHA_RE = re.compile(r"^[0-9a-f]{7,64}$")


def _unit_float(val):
    num = _opt_float(val)
    return num if (num is not None and 0.0 <= num <= 1.0) else None


def _sha(val):
    if not isinstance(val, str):
        return None
    s = val.strip().lower()[:64]
    return s if _HEX_SHA_RE.match(s) else None


def _eval_entry(rec):
    """Normalize one replay-eval summary record; None without a skill."""
    skill = canon_skill(str(rec.get("skill") or "").rstrip("."))
    if not skill:
        return None
    return {
        "skill": skill,
        "win_rate": _unit_float(rec.get("win_rate")),
        "noise_band": _unit_float(rec.get("noise_band")),
        "pass_rate_with": _unit_float(rec.get("pass_rate_with")),
        "pass_rate_without": _unit_float(rec.get("pass_rate_without")),
        "cross_pairs": _opt_int(rec.get("cross_pairs")),
        "cost_delta_in": _opt_float(rec.get("cost_delta_in")),
        "cost_delta_out": _opt_float(rec.get("cost_delta_out")),
        "latency_delta_s": _opt_float(rec.get("latency_delta_s")),
        "tool_calls_delta": _opt_float(rec.get("tool_calls_delta")),
        "tool_errors_delta": _opt_float(rec.get("tool_errors_delta")),
        "skill_sha": _sha(rec.get("skill_sha")),
        "harness": str(rec.get("harness") or ""),
        "recorded_at": str(rec.get("recorded_at") or ""),
    }


def _is_ablation(rec):
    """A record with a `kind` other than "ablation" (e.g. trigger-eval) is not a trend point."""
    return "kind" not in rec or rec["kind"] == "ablation"


def eval_stats(paths, records_out=None):
    """Per-skill replay-eval summary from offline JSON file(s) or directories.

    Accepts a path or sequence of paths. Each file may hold a single JSON
    object, a JSON array, or ``{"evals": [...]}``; directories expand to
    sorted ``*.json`` files. Deduplicates per canonical skill keeping the
    newest ``recorded_at`` (or last when tied/absent). Offline only. When
    ``records_out`` is a list, every loaded record (before dedup) is appended
    to it as ``(entry, is_ablation)`` for the trend loader.
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
            entry = _eval_entry(rec) if isinstance(rec, dict) else None
            if entry is None:
                skipped += 1
                continue
            loaded += 1
            if records_out is not None:
                records_out.append((entry, _is_ablation(rec)))
            prev = per_skill.get(entry["skill"])
            if prev is None or _should_replace_eval(prev, entry):
                per_skill[entry["skill"]] = entry
    return {
        "sources": clean_paths,
        "skills_evaluated": len(per_skill),
        "records_loaded": loaded,
        "records_skipped": skipped,
        "per_skill": dict(sorted(per_skill.items())),
    }


def load_eval_history(paths):
    """Read replay-eval ledger JSONL file(s): (records, resolved_paths, skipped).

    A ``None`` entry means the default ledger, which may be absent (zero
    records); an explicit path that is missing fails fast. Torn, non-object,
    and skill-less lines are skipped and counted; blank lines are ignored.
    """
    records, resolved, skipped = [], [], 0
    for p in paths or []:
        path = default_eval_history() if p is None else p
        resolved.append(path)
        if p is None and not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError as exc:
            raise SystemExit(f"aggregate: cannot read --eval-history path {path!r}: not found or unreadable ({exc})")
        for line in lines:
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                skipped += 1
                continue
            entry = _eval_entry(rec) if isinstance(rec, dict) else None
            if entry is None:
                skipped += 1
                continue
            records.append((entry, _is_ablation(rec)))
    return records, resolved, skipped


def _first_key(ts):
    epoch = ts_to_epoch(ts) if ts else None
    if epoch is not None:
        return (0, epoch, "")
    return (1, 0.0, ts) if ts else (2, 0.0, "")


def _version(key, runs):
    newest = runs[0]
    for cand in runs[1:]:
        if _should_replace_eval(newest, cand):
            newest = cand
    first = min((r["recorded_at"] for r in runs), key=_first_key)
    sha = key[2]
    ver = {k: newest[k] for k in (
        "win_rate", "noise_band", "pass_rate_with", "cross_pairs", "tool_calls_delta",
        "tool_errors_delta", "cost_delta_in", "cost_delta_out", "latency_delta_s")}
    return {"harness": key[1], "skill_sha": sha, "sha_short": sha[:8] if sha else "unversioned",
            "first_recorded_at": first, "last_recorded_at": newest["recorded_at"], "runs": len(runs), **ver}


def eval_trends(records, sources, skipped=0):
    """Per-skill version history from ablation records (--evals before dedup plus ledger lines).

    A version is one (skill, harness, skill_sha) group, shown with its newest run
    (never averaged); runs dedupe on (skill, harness, skill_sha, recorded_at). A
    null sha is its own "unversioned" group and harnesses never merge. Keeps the
    newest VERSIONS_KEPT versions per (skill, harness).
    """
    groups, loaded = {}, 0
    for idx, (entry, ablation) in enumerate(records):
        if not ablation:
            skipped += 1
            continue
        loaded += 1
        key = (entry["skill"], entry["harness"], entry["skill_sha"])
        runs = groups.setdefault(key, {})
        ts_key = entry["recorded_at"] if entry["recorded_at"] else f"__missing__{idx}"
        runs.setdefault(ts_key, entry)
    by_series = {}
    for key, runs in groups.items():
        by_series.setdefault((key[0], key[1]), []).append(_version(key, list(runs.values())))
    per_skill = {}
    for (skill, _harness), versions in by_series.items():
        versions.sort(key=lambda v: (_first_key(v["first_recorded_at"]), v["sha_short"]))
        per_skill.setdefault(skill, []).extend(versions[-VERSIONS_KEPT:])
    for versions in per_skill.values():
        versions.sort(key=lambda v: (_first_key(v["first_recorded_at"]), v["harness"], v["sha_short"]))
    return {"sources": list(sources), "records_loaded": loaded, "records_skipped": skipped,
            "per_skill": dict(sorted(per_skill.items()))}

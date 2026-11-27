#!/usr/bin/env python3
"""Ablation helpers for replay-eval reports (issue #118).

skill_sha: content hash of SKILL.md taken at replay time.
tool_deltas: mean with-skill minus stripped tool calls and errors.
append_history: append-only JSONL ledger, one atomic O_APPEND write per line.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import safe_float  # noqa: E402


def skill_sha(kit_dir, skill, skills_dirs=None):
    """sha256 hex of the raw SKILL.md bytes, or None when it cannot be read.

    Hashes SKILL.md only (references/ are never injected) with no
    normalization, so any byte change is a new version.
    """
    from replay_runner import default_kit_dir, resolve_skill_path

    try:
        path = resolve_skill_path(kit_dir or default_kit_dir(), skill, skills_dirs=skills_dirs)
        if not path:
            return None
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def _mean(vals):
    return sum(vals) / len(vals) if vals else 0.0


def load_seal(path):
    """Return (arms, meta) from a nested or legacy flat seal file."""
    if not path:
        return {}, {}
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    if isinstance(raw, dict) and isinstance(raw.get("arms"), dict):
        return raw["arms"], (raw.get("meta") if isinstance(raw.get("meta"), dict) else {})
    return (raw if isinstance(raw, dict) else {}), {}


def tool_deltas(cross, seal_map):
    """Return (calls_delta, errors_delta, pairs) over cross pairs with both fields.

    A pair counts only when the rubric carries tool_calls and errors for both
    arms (older verdicts do not). Deltas are None, never 0, with no such pair.
    """
    with_calls, without_calls, with_errs, without_errs = [], [], [], []
    for comp in cross if seal_map else []:
        arm = seal_map.get(comp.get("pair_id"))
        if arm not in ("A", "B"):
            continue
        other = "B" if arm == "A" else "A"
        rub = comp.get("rubric") or {}
        calls, errs = rub.get("tool_calls"), rub.get("errors")
        if not (isinstance(calls, dict) and isinstance(errs, dict)):
            continue
        if not all(side in d for d in (calls, errs) for side in (arm, other)):
            continue
        with_calls.append(safe_float(calls[arm], 0.0))
        without_calls.append(safe_float(calls[other], 0.0))
        with_errs.append(safe_float(errs[arm], 0.0))
        without_errs.append(safe_float(errs[other], 0.0))
    if not with_calls:
        return None, None, 0
    return (
        round(_mean(with_calls) - _mean(without_calls), 2),
        round(_mean(with_errs) - _mean(without_errs), 2),
        len(with_calls),
    )


def append_history(path, summary):
    """Append one compact, sorted-key JSON line to the ledger at path.

    One os.write on an O_APPEND descriptor keeps concurrent appenders from
    interleaving lines; there is no lock, rewrite, or pruning by design.
    """
    line = json.dumps(summary, sort_keys=True, separators=(",", ":")) + "\n"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        size = os.fstat(fd).st_size
        if size and os.pread(fd, 1, size - 1) != b"\n":  # torn tail: start a fresh line
            line = "\n" + line
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)

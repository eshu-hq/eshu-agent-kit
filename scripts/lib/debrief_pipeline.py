#!/usr/bin/env python3
"""Debrief v2 pipeline CLI: prepare (Stage 1+digests), cache-write (Stage 2), aggregate."""
import argparse
import json
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from debrief_aggregate import (  # noqa: E402
    cmd_aggregate,
    inherit_parent_projects,
    parse_harnesses,
    project_match,
)
from debrief_common import (  # noqa: E402
    META_SCHEMA_VERSION,
    atomic_write_json,
    default_cache_dir,
    read_json,
    resolve_since,
    safe_key,
    validate_facet,
)
import debrief_extract_agy as EX_AGY  # noqa: E402
import debrief_extract_claude as EX_CLAUDE  # noqa: E402
import debrief_extract_muse as EX_MUSE  # noqa: E402


def _load_or_extract(harness, path, mtime, cache_dir, agy_db_cache):
    meta_dir = os.path.join(cache_dir, "meta")
    dig_dir = os.path.join(cache_dir, "digests")
    cand_id = None
    if harness == "agy":
        cand_id = EX_AGY.conversation_id(path)
    elif harness == "claude":
        cand_id = os.path.splitext(os.path.basename(path))[0]
    elif harness == "muse":
        cand_id = os.path.basename(os.path.dirname(path))

    if cand_id:
        key = safe_key(harness, cand_id)
        cm = read_json(os.path.join(meta_dir, key + ".json"))
        cd = read_json(os.path.join(dig_dir, key + ".json"))
        if cm and cd:
            cached_mt = float(cm.get("source_mtime") or 0)
            if cm.get("meta_version") == META_SCHEMA_VERSION and (
                abs(cached_mt - mtime) < 0.01 or cached_mt > mtime
            ):
                return cm, cd

    if harness == "muse":
        meta, dig = EX_MUSE.extract_session(path, mtime)
    elif harness == "agy":
        meta, dig = EX_AGY.extract_session(path, mtime, agy_db_cache)
    else:
        meta, dig = EX_CLAUDE.extract_session(path, mtime)

    key = safe_key(harness, meta["id"])
    atomic_write_json(os.path.join(meta_dir, key + ".json"), meta)
    atomic_write_json(os.path.join(dig_dir, key + ".json"), dig)
    if cand_id and cand_id != meta["id"]:
        alias_key = safe_key(harness, cand_id)
        atomic_write_json(os.path.join(meta_dir, alias_key + ".json"), meta)
        atomic_write_json(os.path.join(dig_dir, alias_key + ".json"), dig)
    return meta, dig


def _discover_all(harnesses, since_epoch, roots_override=None):
    """Return list of (harness, path, mtime) across requested harnesses."""
    items = []
    valid_roots = [r for r in (roots_override or []) if os.path.isdir(r)] if roots_override else None
    if "muse" in harnesses:
        roots = valid_roots if valid_roots is not None else EX_MUSE.default_roots()
        for p, mt in EX_MUSE.discover(roots, since_epoch):
            items.append(("muse", p, mt))
    if "agy" in harnesses:
        roots = valid_roots if valid_roots is not None else EX_AGY.default_roots()
        for p, mt in EX_AGY.discover(roots, since_epoch):
            items.append(("agy", p, mt))
    if "claude" in harnesses:
        roots = valid_roots if valid_roots is not None else EX_CLAUDE.default_roots()
        for p, mt in EX_CLAUDE.discover(roots, since_epoch):
            items.append(("claude", p, mt))
    items.sort(key=lambda x: x[2], reverse=True)
    return items


def _rollup_children(metas_by_key, digests_by_key):
    """Attach child subagent summaries into parent digests; return rolled-up child keys."""
    by_id = {(m["harness"], m["id"]): k for k, m in metas_by_key.items()}
    rolled_up = set()
    parent_to_children = defaultdict(list)
    for k, m in metas_by_key.items():
        pid = m.get("parent_session")
        if pid and (m["harness"], pid) in by_id:
            pk = by_id[(m["harness"], pid)]
            if pk != k and k not in parent_to_children[pk]:
                parent_to_children[pk].append(k)
        for cid in m.get("child_sessions") or []:
            ck = by_id.get((m["harness"], cid))
            if ck and ck != k and ck not in parent_to_children[k]:
                parent_to_children[k].append(ck)

    for pk, ckeys in parent_to_children.items():
        pdig = digests_by_key.get(pk)
        if not pdig:
            continue
        summaries = list(pdig.get("child_summaries") or [])
        for ck in ckeys:
            rolled_up.add(ck)
            cm = metas_by_key[ck]
            cd = digests_by_key.get(ck) or {}
            if len(summaries) < 10:
                summaries.append({
                    "child_id": cm["id"][:16],
                    "tool_calls": cm.get("tool_calls", 0),
                    "error_categories": cm.get("error_categories") or {},
                    "error_samples": (cd.get("error_samples") or [])[:2],
                    "final_note": (cd.get("final_assistant_notes") or [""])[-1][:180],
                })
        pdig["child_summaries"] = summaries
        pdig["rolled_up_children"] = len(ckeys)
    return rolled_up


def _sync_claude_facets(cache_dir, claude_facets_dir=None):
    facets_dir = os.path.join(cache_dir, "facets")
    imported = EX_CLAUDE.import_native_claude_facets(claude_facets_dir)
    count = 0
    for sid, facet in imported.items():
        fpath = os.path.join(facets_dir, safe_key("claude", sid) + ".json")
        if not os.path.isfile(fpath):
            atomic_write_json(fpath, facet)
            count += 1
    return count


def _facet_is_fresh(cache_dir, harness, sid, source_mtime):
    fpath = os.path.join(cache_dir, "facets", safe_key(harness, sid) + ".json")
    cf = read_json(fpath)
    if not cf:
        return False
    if cf.get("imported_from") == "claude-native-facets":
        return True
    return abs(float(cf.get("source_mtime") or 0) - float(source_mtime or 0)) < 1.0


def cmd_prepare(args):
    since_str, since_ep = resolve_since(args.since, args.days)
    harnesses = parse_harnesses(args.harness)
    cache_dir = args.cache_dir or default_cache_dir()
    out_dir = args.out_dir or os.path.join(cache_dir, "work-batches")
    os.makedirs(out_dir, exist_ok=True)
    for fn in os.listdir(out_dir):
        if fn.startswith("batch-") and fn.endswith(".json"):
            try:
                os.unlink(os.path.join(out_dir, fn))
            except OSError:
                pass

    imported_claude = 0
    if not args.no_claude_import and "claude" in harnesses:
        imported_claude = _sync_claude_facets(cache_dir, args.claude_facets_dir)

    discovered = _discover_all(harnesses, since_ep, args.transcript_root)
    agy_db_cache = {}
    metas_by_key = {}
    digests_by_key = {}
    for h, p, mt in discovered:
        m, d = _load_or_extract(h, p, mt, cache_dir, agy_db_cache)
        k = safe_key(h, m["id"])
        if k not in metas_by_key or mt > float(metas_by_key[k].get("source_mtime") or 0):
            metas_by_key[k] = m
            digests_by_key[k] = d

    inherit_parent_projects(metas_by_key)
    if args.project:
        metas_by_key = {k: m for k, m in metas_by_key.items() if project_match(m, args.project)}
        digests_by_key = {k: d for k, d in digests_by_key.items() if k in metas_by_key}

    rolled_up = _rollup_children(metas_by_key, digests_by_key)

    candidates = []
    cached_ok = 0
    skipped_trivial = 0
    for k, m in metas_by_key.items():
        if k in rolled_up:
            continue
        if (m.get("prompts", 0) < 2) and (m.get("tool_calls", 0) < 3):
            skipped_trivial += 1
            continue
        if _facet_is_fresh(cache_dir, m["harness"], m["id"], m.get("source_mtime")):
            cached_ok += 1
            continue
        candidates.append((float(m.get("source_mtime") or 0), k, digests_by_key[k]))

    candidates.sort(key=lambda x: x[0], reverse=True)
    max_new = max(0, int(args.max_new))
    selected = candidates[:max_new]
    deferred = max(0, len(candidates) - len(selected))

    bsize = max(1, int(args.batch_size))
    batch_files = []
    for i in range(0, len(selected), bsize):
        chunk = [item[2] for item in selected[i : i + bsize]]
        bpath = os.path.join(out_dir, f"batch-{len(batch_files) + 1:02d}.json")
        atomic_write_json(bpath, {"batch_index": len(batch_files) + 1, "digests": chunk})
        batch_files.append(bpath)

    manifest = {
        "since": since_str,
        "harnesses": harnesses,
        "project": args.project or None,
        "cache_dir": cache_dir,
        "sessions_discovered": len(metas_by_key),
        "rolled_up_children": len(rolled_up),
        "skipped_trivial": skipped_trivial,
        "facets_already_cached": cached_ok,
        "claude_native_imported": imported_claude,
        "facets_queued": len(selected),
        "facets_deferred_by_cap": deferred,
        "batch_files": batch_files,
    }
    atomic_write_json(os.path.join(out_dir, "prepare-manifest.json"), manifest)
    sys.stdout.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def cmd_cache_write(args):
    cache_dir = args.cache_dir or default_cache_dir()
    if args.input == "-":
        raw_txt = sys.stdin.read()
    else:
        with open(args.input, encoding="utf-8") as fh:
            raw_txt = fh.read()
    parsed = json.loads(raw_txt)
    if isinstance(parsed, dict) and isinstance(parsed.get("facets"), list):
        items = parsed["facets"]
    elif isinstance(parsed, list):
        items = parsed
    elif isinstance(parsed, dict):
        items = [parsed]
    else:
        raise SystemExit('cache-write: input must be JSON object, list, or {"facets": [...]}')

    written = 0
    errors = []
    for idx, item in enumerate(items):
        norm, err = validate_facet(item)
        if err:
            errors.append({"index": idx, "error": err})
            continue
        key = safe_key(norm["harness"], norm["session_id"])
        if not norm.get("source_mtime"):
            cm = read_json(os.path.join(cache_dir, "meta", key + ".json"))
            if cm:
                norm["source_mtime"] = float(cm.get("source_mtime") or 0)
        atomic_write_json(os.path.join(cache_dir, "facets", key + ".json"), norm)
        written += 1

    res = {"written": written, "rejected": len(errors), "errors": errors}
    sys.stdout.write(json.dumps(res, indent=2, sort_keys=True) + "\n")
    if errors and written == 0:
        raise SystemExit(1)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="debrief")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_prep = sub.add_parser("prepare")
    p_prep.add_argument("--since", default="")
    p_prep.add_argument("--days", type=int, default=30)
    p_prep.add_argument("--max-new", type=int, default=100)
    p_prep.add_argument("--batch-size", type=int, default=10)
    p_prep.add_argument("--project", default="")
    p_prep.add_argument("--harness", default="")
    p_prep.add_argument("--cache-dir", default="")
    p_prep.add_argument("--out-dir", default="")
    p_prep.add_argument("--transcript-root", action="append", default=[])
    p_prep.add_argument("--claude-facets-dir", default="")
    p_prep.add_argument("--no-claude-import", action="store_true")

    p_cw = sub.add_parser("cache-write")
    p_cw.add_argument("--cache-dir", default="")
    p_cw.add_argument("input", nargs="?", default="-")

    p_agg = sub.add_parser("aggregate")
    p_agg.add_argument("--since", default="")
    p_agg.add_argument("--days", type=int, default=30)
    p_agg.add_argument("--project", default="")
    p_agg.add_argument("--harness", default="")
    p_agg.add_argument("--cache-dir", default="")
    p_agg.add_argument("--log", action="append", default=[])
    p_agg.add_argument("--repo", action="append", default=[])
    p_agg.add_argument("--papercuts", default="",
                       help="JSON snapshot of papercut issues (array or {\"issues\": [...]}) joined on the skill: body line; no live gh calls")
    p_agg.add_argument("--evals", action="append", default=[],
                       help="JSON file or directory of *.json replay-eval summaries joined per skill; offline only")
    p_agg.add_argument("--out", default="")

    args = ap.parse_args(argv)
    if args.cmd == "prepare":
        cmd_prepare(args)
    elif args.cmd == "cache-write":
        cmd_cache_write(args)
    elif args.cmd == "aggregate":
        cmd_aggregate(args)


if __name__ == "__main__":
    main()

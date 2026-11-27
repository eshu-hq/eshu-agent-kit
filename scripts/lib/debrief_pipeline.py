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
    project_match,
)
from debrief_common import (  # noqa: E402
    META_SCHEMA_VERSION,
    atomic_write_json,
    configure_aliases,
    default_cache_dir,
    read_json,
    safe_key,
    validate_facet,
)
from debrief_diff import (  # noqa: E402
    build_snapshot,
    diff_snapshots,
)
from debrief_scope import (  # noqa: E402
    build_scope_meta,
    filter_metas_by_sessions,
    parse_harnesses_strict,
    parse_session_specs,
    resolve_current_session,
    resolve_window,
    session_detail_rows,
)
import debrief_extract_agy as EX_AGY  # noqa: E402
import debrief_extract_claude as EX_CLAUDE  # noqa: E402
import debrief_extract_codex as EX_CODEX  # noqa: E402
import debrief_extract_muse as EX_MUSE  # noqa: E402
import debrief_extract_opencode as EX_OPENCODE  # noqa: E402


def _load_or_extract(harness, path, mtime, cache_dir, agy_db_cache, opencode_db_cache=None):
    meta_dir = os.path.join(cache_dir, "meta")
    dig_dir = os.path.join(cache_dir, "digests")
    cand_id = None
    if harness == "agy":
        cand_id = EX_AGY.conversation_id(path)
    elif harness == "claude":
        cand_id = os.path.splitext(os.path.basename(path))[0]
    elif harness == "muse":
        cand_id = os.path.basename(os.path.dirname(path))
    elif harness == "codex":
        cand_id = EX_CODEX.session_id_from_path(path)
    elif harness == "opencode":
        cand_id = EX_OPENCODE.session_id_from_ref(path)

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
    elif harness == "codex":
        meta, dig = EX_CODEX.extract_session(path, mtime)
    elif harness == "opencode":
        meta, dig = EX_OPENCODE.extract_session(path, mtime, opencode_db_cache)
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
    valid_dirs = [r for r in (roots_override or []) if os.path.isdir(r)] if roots_override else None
    valid_paths = [r for r in (roots_override or []) if os.path.exists(r)] if roots_override else None
    if "muse" in harnesses:
        roots = valid_dirs if valid_dirs is not None else EX_MUSE.default_roots()
        for p, mt in EX_MUSE.discover(roots, since_epoch):
            items.append(("muse", p, mt))
    if "agy" in harnesses:
        roots = valid_dirs if valid_dirs is not None else EX_AGY.default_roots()
        for p, mt in EX_AGY.discover(roots, since_epoch):
            items.append(("agy", p, mt))
    if "claude" in harnesses:
        roots = valid_dirs if valid_dirs is not None else EX_CLAUDE.default_roots()
        for p, mt in EX_CLAUDE.discover(roots, since_epoch):
            items.append(("claude", p, mt))
    if "codex" in harnesses:
        roots = valid_dirs if valid_dirs is not None else EX_CODEX.default_roots()
        for p, mt in EX_CODEX.discover(roots, since_epoch):
            items.append(("codex", p, mt))
    if "opencode" in harnesses:
        roots = valid_paths if valid_paths is not None else EX_OPENCODE.default_roots()
        for p, mt in EX_OPENCODE.discover(roots, since_epoch):
            items.append(("opencode", p, mt))
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


def _extract_metas_and_digests(harnesses, since_ep, cache_dir, roots_override=None):
    discovered = _discover_all(harnesses, since_ep, roots_override)
    agy_db_cache = {}
    opencode_db_cache = {}
    metas_by_key = {}
    digests_by_key = {}
    try:
        for h, p, mt in discovered:
            m, d = _load_or_extract(h, p, mt, cache_dir, agy_db_cache, opencode_db_cache)
            k = safe_key(h, m["id"])
            if k not in metas_by_key or mt > float(metas_by_key[k].get("source_mtime") or 0):
                metas_by_key[k] = m
                digests_by_key[k] = d
    finally:
        for con in opencode_db_cache.values():
            try:
                con.close()
            except Exception:
                pass
    inherit_parent_projects(metas_by_key)
    return metas_by_key, digests_by_key


def cmd_sessions(args):
    harnesses = parse_harnesses_strict(args.harness)
    days_explicit = args.days is not None
    since_str, since_ep = resolve_window(
        args.since, args.days, all_time=args.all_time, days_explicit=days_explicit
    )
    cache_dir = args.cache_dir or default_cache_dir()
    metas_by_key, digests_by_key = _extract_metas_and_digests(
        harnesses, since_ep, cache_dir, args.transcript_root
    )
    if args.project:
        metas_by_key = {k: m for k, m in metas_by_key.items() if project_match(m, args.project)}
    children = _rollup_children(metas_by_key, digests_by_key)
    facets_dir = os.path.join(cache_dir, "facets")
    facets = {}
    if os.path.isdir(facets_dir):
        for k in metas_by_key:
            f = read_json(os.path.join(facets_dir, k + ".json"))
            if f:
                facets[k] = f
    rows = session_detail_rows(metas_by_key, children, facets, limit=max(1, int(args.limit)))
    if args.json:
        out = {
            "since": since_str or None,
            "all_time": bool(args.all_time),
            "harnesses": harnesses,
            "project": args.project or None,
            "total_top_sessions": len([k for k in metas_by_key if k not in children]),
            "sessions": rows,
        }
        sys.stdout.write(json.dumps(out, indent=2, sort_keys=True) + "\n")
        return
    if not rows:
        sys.stdout.write("No sessions found.\n")
        return
    sys.stdout.write(f"{'HARNESS':<9} {'SESSION_ID':<20} {'PROJECT':<20} {'PROMPTS':>7} {'TOOLS':>6} {'ERRS':>5}  LAST_TS\n")
    for r in rows:
        sys.stdout.write(
            f"{r['harness']:<9} {r['session_id'][:20]:<20} {r['project'][:20]:<20} "
            f"{r['prompts']:>7} {r['tool_calls']:>6} {r['errors']:>5}  {str(r['last_ts'])[:19]}\n"
        )


def cmd_prepare(args):
    harnesses = parse_harnesses_strict(args.harness)
    specs = parse_session_specs(args.session, args.sessions_file)
    explicit_sessions = bool(args.current or specs)
    days_explicit = args.days is not None
    since_str, since_ep = resolve_window(
        args.since,
        args.days,
        all_time=args.all_time,
        explicit_sessions=explicit_sessions,
        days_explicit=days_explicit,
    )
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

    metas_by_key, digests_by_key = _extract_metas_and_digests(
        harnesses, since_ep, cache_dir, args.transcript_root
    )
    if args.project:
        metas_by_key = {k: m for k, m in metas_by_key.items() if project_match(m, args.project)}
        digests_by_key = {k: d for k, d in digests_by_key.items() if k in metas_by_key}

    matched_sids = []
    missing_specs = []
    if args.current:
        specs = resolve_current_session(metas_by_key, harnesses, cwd=args.current_cwd or None) + specs
    if specs:
        metas_by_key, matched_keys, missing_specs = filter_metas_by_sessions(
            metas_by_key, specs, include_children=not args.no_children
        )
        digests_by_key = {k: d for k, d in digests_by_key.items() if k in metas_by_key}
        matched_sids = [metas_by_key[k]["id"] for k in matched_keys]

    rolled_up = _rollup_children(metas_by_key, digests_by_key)

    candidates = []
    cached_ok = 0
    skipped_trivial = 0
    for k, m in metas_by_key.items():
        if k in rolled_up:
            continue
        if not explicit_sessions and (m.get("prompts", 0) < 2) and (m.get("tool_calls", 0) < 3):
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

    scope = build_scope_meta(
        harnesses,
        args.project,
        since_str,
        args.days if days_explicit else 30,
        args.all_time,
        session_ids=matched_sids,
        missing_sessions=missing_specs,
    )
    manifest = {
        "since": since_str or None,
        "harnesses": harnesses,
        "project": args.project or None,
        "scope": scope,
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


def cmd_diff(args):
    prev_obj = read_json(args.prev)
    curr_obj = read_json(args.curr)
    if not isinstance(prev_obj, dict):
        sys.stderr.write(f"debrief diff: invalid or missing --prev JSON: {args.prev}\n")
        raise SystemExit(2)
    if not isinstance(curr_obj, dict):
        sys.stderr.write(f"debrief diff: invalid or missing --curr JSON: {args.curr}\n")
        raise SystemExit(2)
    prev_snap = prev_obj if prev_obj.get("schema_version") and "kpis" in prev_obj else build_snapshot(prev_obj, repo_paths=args.repo, skills_dirs=args.skills_dir)
    curr_snap = curr_obj if curr_obj.get("schema_version") and "kpis" in curr_obj else build_snapshot(curr_obj, repo_paths=args.repo, skills_dirs=args.skills_dir)
    res = diff_snapshots(prev_snap, curr_snap, repo_paths=args.repo, skills_dirs=args.skills_dir)
    if args.out:
        atomic_write_json(args.out, res)
    sys.stdout.write(json.dumps(res, indent=2, sort_keys=True) + "\n")


def _add_scope_args(parser):
    parser.add_argument("--since", default="")
    parser.add_argument("--days", type=int, default=None)
    parser.add_argument("--all-time", action="store_true", help="Include all available sessions with no time cutoff")
    parser.add_argument("--project", default="")
    parser.add_argument("--harness", default="", help="Comma-separated harnesses (muse,agy,claude,codex,opencode) or all")
    parser.add_argument("--current", action="store_true", help="Scope to the active session (env var or CWD recency)")
    parser.add_argument("--current-cwd", default="", help="Workspace path override for --current fallback resolution")
    parser.add_argument("--session", action="append", default=[], help="Target session ID or prefix (repeatable, comma-separated, optional harness:id)")
    parser.add_argument("--sessions-file", default="", help="File containing target session IDs (newline-delimited or JSON array)")
    parser.add_argument("--no-children", action="store_true", help="Do not auto-include child subagent sessions for targeted --session/--current")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="debrief")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_sess = sub.add_parser("sessions")
    p_sess.add_argument("--since", default="")
    p_sess.add_argument("--days", type=int, default=None)
    p_sess.add_argument("--all-time", action="store_true")
    p_sess.add_argument("--project", default="")
    p_sess.add_argument("--harness", default="")
    p_sess.add_argument("--limit", type=int, default=30)
    p_sess.add_argument("--json", action="store_true")
    p_sess.add_argument("--cache-dir", default="")
    p_sess.add_argument("--transcript-root", action="append", default=[])
    p_sess.add_argument("--aliases", default="")

    p_prep = sub.add_parser("prepare")
    _add_scope_args(p_prep)
    p_prep.add_argument("--max-new", type=int, default=100)
    p_prep.add_argument("--batch-size", type=int, default=10)
    p_prep.add_argument("--cache-dir", default="")
    p_prep.add_argument("--out-dir", default="")
    p_prep.add_argument("--transcript-root", action="append", default=[])
    p_prep.add_argument("--claude-facets-dir", default="")
    p_prep.add_argument("--no-claude-import", action="store_true")
    p_prep.add_argument("--aliases", default="", help="Optional TSV skill alias map (default: kit overlay or none)")

    p_cw = sub.add_parser("cache-write")
    p_cw.add_argument("--cache-dir", default="")
    p_cw.add_argument("input", nargs="?", default="-")

    p_agg = sub.add_parser("aggregate")
    _add_scope_args(p_agg)
    p_agg.add_argument("--cache-dir", default="")
    p_agg.add_argument("--log", action="append", default=[])
    p_agg.add_argument("--repo", action="append", default=[])
    p_agg.add_argument("--aliases", default="", help="Optional TSV skill alias map (default: kit overlay or none)")
    p_agg.add_argument("--skills-dir", action="append", default=[],
                       help="Skill directory to scan for SKILL.md byte sizes (repeatable; flat or layered)")
    p_agg.add_argument("--papercuts", default="",
                       help="JSON snapshot of papercut issues (array or {\"issues\": [...]}) joined on the skill: body line; no live gh calls")
    p_agg.add_argument("--evals", action="append", default=[],
                       help="JSON file or directory of *.json replay-eval summaries joined per skill; offline only")
    p_agg.add_argument("--eval-history", action="append", nargs="?", const=None, default=[],
                       help="replay-eval.sh report --history JSONL ledger (repeatable); bare flag reads the default ledger; "
                            "feeds the Skill Quality Trends card together with --evals")
    p_agg.add_argument("--trigger-evals", action="append", default=[],
                       help="JSON file or directory of trigger-eval summaries (replay-eval.sh trigger --json-out); never use --evals")
    p_agg.add_argument("--compare-prev", action="store_true", help="Diff against the most recent saved snapshot for this scope")
    p_agg.add_argument("--compare", default="", help="Diff against an explicit previous snapshot JSON file")
    p_agg.add_argument("--reports-dir", default="", help="Override debrief reports dir (for --compare-prev snapshot lookup)")
    p_agg.add_argument("--ignore-changepoints", action="store_true", help="Evaluate recommendations on full window without post-edit splitting")
    p_agg.add_argument("--since-last-edit", action="store_true", help="Restrict aggregate sessions to those after the latest skill/hook edit")
    p_agg.add_argument("--out", default="")

    p_diff = sub.add_parser("diff")
    p_diff.add_argument("--prev", required=True, help="Previous snapshot or aggregate JSON")
    p_diff.add_argument("--curr", required=True, help="Current snapshot or aggregate JSON")
    p_diff.add_argument("--repo", action="append", default=[])
    p_diff.add_argument("--skills-dir", action="append", default=[])
    p_diff.add_argument("--out", default="")

    args = ap.parse_args(argv)
    if getattr(args, "aliases", ""):
        configure_aliases(args.aliases)
    if args.cmd == "sessions":
        cmd_sessions(args)
    elif args.cmd == "prepare":
        cmd_prepare(args)
    elif args.cmd == "cache-write":
        cmd_cache_write(args)
    elif args.cmd == "aggregate":
        cmd_aggregate(args)
    elif args.cmd == "diff":
        cmd_diff(args)


if __name__ == "__main__":
    main()

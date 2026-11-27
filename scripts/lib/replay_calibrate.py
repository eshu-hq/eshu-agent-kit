#!/usr/bin/env python3
"""Eval flywheel utilities: 5/80/15 suite mixer, papercut-to-eval, and judge calibration (#131).

Subcommands (dispatched by scripts/replay-eval.sh):
  mix            Combine committed golden/edge suites with local mined production prompts.
  from-papercut  Draft candidate ablation or trigger eval cases from a papercut snapshot.
  calibrate      Measure blind judge agreement against author ground truth and verbosity bias.
"""
import getopt
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import canon_skill, safe_int, truncate_text  # noqa: E402


def _fail(msg, code=1):
    print("replay-calibrate: %s" % msg, file=sys.stderr)
    sys.exit(code)


def _load_items(path):
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict) and isinstance(raw.get("evals"), list):
        return raw["evals"]
    if isinstance(raw, dict) and isinstance(raw.get("issues"), list):
        return raw["issues"]
    if isinstance(raw, dict):
        return [raw]
    _fail("unsupported JSON top-level shape in %s" % path, 2)


def cmd_mix(args):
    try:
        opts, _ = getopt.getopt(args, "", [
            "suite=", "mined=", "skill=", "target-size=", "out=", "help",
        ])
    except getopt.GetoptError as exc:
        _fail(str(exc), 2)
    suites, mined_paths, skill_opt, target_size, out = [], [], "", 20, ""
    for key, val in opts:
        if key == "--suite":
            suites.append(val)
        elif key == "--mined":
            mined_paths.append(val)
        elif key == "--skill":
            skill_opt = canon_skill(val)
        elif key == "--target-size":
            try:
                target_size = int(val)
            except ValueError:
                _fail("--target-size must be an integer", 2)
        elif key == "--out":
            out = val
        elif key == "--help":
            print("mix: build a 5/80/15 (golden/production/edge) suite without committing raw prompts.\n"
                  "Options: --suite FILE (repeatable) [--mined FILE ...] [--skill NAME] [--target-size N] --out FILE")
            return
    if not suites and not mined_paths:
        _fail("mix needs at least one --suite or --mined file", 2)
    if target_size < 1:
        _fail("--target-size must be >= 1", 2)
    if not out:
        _fail("mix needs --out", 2)

    buckets = {"golden": [], "production": [], "edge": []}
    seen_ids = set()
    for src, default_cat in [(p, "golden") for p in suites] + [(p, "production") for p in mined_paths]:
        for item in _load_items(src):
            if not isinstance(item, dict) or not item.get("prompt"):
                continue
            sk = canon_skill(item.get("skill") or "")
            if skill_opt and sk and sk != skill_opt:
                continue
            cat = str(item.get("category") or default_cat).strip().lower()
            if cat not in buckets:
                cat = default_cat
            iid = str(item.get("id") or f"{cat}-{len(seen_ids) + 1}")
            if iid in seen_ids:
                continue
            seen_ids.add(iid)
            rec = dict(item)
            rec["id"] = iid
            rec["category"] = cat
            buckets[cat].append(rec)

    want_golden = max(1, round(target_size * 0.05)) if buckets["golden"] else 0
    want_edge = max(1, round(target_size * 0.15)) if buckets["edge"] else 0
    want_prod = max(0, target_size - want_golden - want_edge)

    mixed = []
    mixed.extend(buckets["golden"][:want_golden])
    mixed.extend(buckets["production"][:want_prod])
    mixed.extend(buckets["edge"][:want_edge])
    # Top up from remaining items if any bucket was short.
    used = {m["id"] for m in mixed}
    for cat in ("production", "edge", "golden"):
        for item in buckets[cat]:
            if len(mixed) >= target_size:
                break
            if item["id"] not in used:
                mixed.append(item)
                used.add(item["id"])

    counts = {c: sum(1 for m in mixed if m["category"] == c) for c in ("golden", "production", "edge")}
    tot = len(mixed)
    pct = {c: round(100.0 * counts[c] / tot, 1) if tot else 0.0 for c in counts}
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(mixed, fh, indent=2)
        fh.write("\n")
    print(
        "mix: %d items -> %s (golden=%d/%.1f%%, production=%d/%.1f%%, edge=%d/%.1f%%)"
        % (tot, out, counts["golden"], pct["golden"], counts["production"], pct["production"], counts["edge"], pct["edge"])
    )
    if counts["production"] == 0:
        print("WARNING: 0 production prompts in mixed suite (target ~80%; pass --mined from `replay-eval.sh mine`)")


def _extract_section(body, heading):
    pat = re.compile(r"^##\s+" + re.escape(heading) + r"\s*$(.*?)(?=^##\s+|\Z)", re.MULTILINE | re.DOTALL | re.IGNORECASE)
    m = pat.search(body or "")
    return truncate_text(m.group(1), 320) if m else ""


def _skill_from_issue(issue):
    body = str(issue.get("body") or "")
    m = re.search(r"^\s*skill\s*:\s*([A-Za-z0-9._:/-]+)", body, re.MULTILINE | re.IGNORECASE)
    if m:
        return canon_skill(m.group(1))
    title = str(issue.get("title") or "")
    m2 = re.search(r"\[papercut\]\s*([A-Za-z0-9._-]+)\s*:", title, re.IGNORECASE)
    return canon_skill(m2.group(1)) if m2 else ""


def _keywords(text, limit=3):
    stop = {"that", "this", "with", "from", "when", "should", "must", "failed", "error", "skill", "using", "into", "after", "before", "instead"}
    out = []
    for tok in re.findall(r"[A-Za-z0-9_./-]{4,}", text or ""):
        low = tok.lower()
        if low not in stop and low not in out and not low.isdigit():
            out.append(tok)
        if len(out) >= limit:
            break
    return out


def cmd_from_papercut(args):
    try:
        opts, _ = getopt.getopt(args, "", ["papercuts=", "issue=", "skill=", "mode=", "out=", "help"])
    except getopt.GetoptError as exc:
        _fail(str(exc), 2)
    pc_path = skill_opt = out = ""
    issue_num = None
    mode = "ablation"
    for key, val in opts:
        if key == "--papercuts":
            pc_path = val
        elif key == "--issue":
            try:
                issue_num = int(val)
            except ValueError:
                _fail("--issue must be an integer", 2)
        elif key == "--skill":
            skill_opt = canon_skill(val)
        elif key == "--mode":
            mode = val.strip().lower()
        elif key == "--out":
            out = val
        elif key == "--help":
            print("from-papercut: draft candidate eval cases from a papercut snapshot.\n"
                  "Options: --papercuts FILE [--issue N] [--skill NAME] [--mode ablation|trigger] --out FILE")
            return
    if not pc_path or not out:
        _fail("from-papercut needs --papercuts and --out", 2)
    if mode not in ("ablation", "trigger"):
        _fail("--mode must be ablation or trigger", 2)

    issues = _load_items(pc_path)
    drafts = []
    for iss in issues:
        if not isinstance(iss, dict):
            continue
        num = safe_int(iss.get("number"), 0)
        if issue_num is not None and num != issue_num:
            continue
        sk = _skill_from_issue(iss)
        if not sk:
            continue
        if skill_opt and sk != skill_opt:
            continue
        body = str(iss.get("body") or "")
        tried = _extract_section(body, "Tried")
        expected = _extract_section(body, "Expected")
        happened = _extract_section(body, "Happened")
        fix = _extract_section(body, "Smallest fix")
        title = truncate_text(iss.get("title") or "", 160)
        prompt_parts = [f"Regression check for {sk} (from papercut #{num or 'local'}): {title}."]
        if tried:
            prompt_parts.append(f"Context / action attempted: {tried}.")
        if expected:
            prompt_parts.append(f"Required outcome: {expected}.")
        prompt = " ".join(prompt_parts)
        if mode == "trigger":
            drafts.append({
                "id": f"{sk}-papercut-{num or len(drafts) + 1}",
                "kind": "positive",
                "prompt": prompt,
                "expect": [sk],
            })
        else:
            must_mention = _keywords(fix or expected, limit=3) or [sk]
            must_not = _keywords(happened, limit=1) if happened else []
            drafts.append({
                "id": f"{sk}-papercut-{num or len(drafts) + 1}",
                "category": "edge",
                "skill": sk,
                "source_issue": num or None,
                "prompt": prompt,
                "expectations": {
                    "must_mention": must_mention,
                    "must_not_mention": must_not,
                    "max_errors": 0,
                },
            })

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    payload = {"version": 1, "cases": drafts} if mode == "trigger" else drafts
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    print("from-papercut: %d %s draft(s) -> %s" % (len(drafts), mode, out))


def _norm_side(val):
    s = str(val or "").strip().upper()
    if s in ("A", "B"):
        return s
    if s == "TIE":
        return "tie"
    return ""


def cmd_calibrate(args):
    try:
        opts, _ = getopt.getopt(args, "", ["verdict=", "truth=", "runs=", "json-out=", "help"])
    except getopt.GetoptError as exc:
        _fail(str(exc), 2)
    verdict_path = truth_path = runs_path = json_out = ""
    for key, val in opts:
        if key == "--verdict":
            verdict_path = val
        elif key == "--truth":
            truth_path = val
        elif key == "--runs":
            runs_path = val
        elif key == "--json-out":
            json_out = val
        elif key == "--help":
            print("calibrate: compare blind judge verdicts against author ground truth and check verbosity bias.\n"
                  "Options: --verdict FILE [--truth FILE] [--runs FILE] [--json-out FILE]")
            return
    if not verdict_path:
        _fail("calibrate needs --verdict", 2)

    with open(verdict_path, encoding="utf-8") as fh:
        comps = json.load(fh).get("comparisons") or []

    truth_map = {}
    if truth_path:
        with open(truth_path, encoding="utf-8") as fh:
            raw_t = json.load(fh)
        if isinstance(raw_t, dict):
            truth_map = {str(k): _norm_side(v) for k, v in raw_t.items() if _norm_side(v)}
        elif isinstance(raw_t, list):
            for item in raw_t:
                if isinstance(item, dict) and item.get("pair_id"):
                    side = _norm_side(item.get("expected_winner") or item.get("winner"))
                    if side:
                        truth_map[str(item["pair_id"])] = side
    else:
        # Derive deterministic ground truth from rubric.expectations when exactly one arm passed.
        for c in comps:
            exps = (c.get("rubric") or {}).get("expectations") or {}
            if isinstance(exps.get("A"), dict) and isinstance(exps.get("B"), dict):
                pa, pb = bool(exps["A"].get("passed")), bool(exps["B"].get("passed"))
                if pa and not pb:
                    truth_map[str(c.get("pair_id"))] = "A"
                elif pb and not pa:
                    truth_map[str(c.get("pair_id"))] = "B"
                elif pa == pb:
                    truth_map[str(c.get("pair_id"))] = "tie"

    lengths = {}
    if runs_path:
        with open(runs_path, encoding="utf-8") as fh:
            for p in json.load(fh):
                if isinstance(p, dict) and p.get("pair_id"):
                    la = len(str((p.get("traj_a") or {}).get("transcript") or ""))
                    lb = len(str((p.get("traj_b") or {}).get("transcript") or ""))
                    lengths[str(p["pair_id"])] = (la, lb)

    compared = agreed = decisive_truth = decisive_agreed = 0
    longer_picks = len_decisive = 0
    disagreements = []
    for c in comps:
        pid = str(c.get("pair_id") or "")
        jw = _norm_side(c.get("winner"))
        if pid in truth_map and jw:
            tw = truth_map[pid]
            compared += 1
            if jw == tw:
                agreed += 1
            else:
                disagreements.append({"pair_id": pid, "judge": jw, "truth": tw})
            if tw in ("A", "B"):
                decisive_truth += 1
                if jw == tw:
                    decisive_agreed += 1
        if pid in lengths and jw in ("A", "B"):
            la, lb = lengths[pid]
            if la != lb:
                len_decisive += 1
                if (jw == "A" and la > lb) or (jw == "B" and lb > la):
                    longer_picks += 1

    agreement = round(agreed / compared, 4) if compared else None
    decisive_acc = round(decisive_agreed / decisive_truth, 4) if decisive_truth else None
    verbosity_rate = round(longer_picks / len_decisive, 4) if len_decisive else None
    res = {
        "kind": "judge-calibration",
        "compared_pairs": compared,
        "agreed": agreed,
        "agreement_rate": agreement,
        "decisive_truth_pairs": decisive_truth,
        "decisive_accuracy": decisive_acc,
        "verbosity_bias_rate": verbosity_rate,
        "verbosity_checked_pairs": len_decisive,
        "disagreements": disagreements,
    }
    print(
        "calibrate: compared=%d agreed=%d agreement=%s decisive_accuracy=%s verbosity_longer_pick=%s"
        % (
            compared, agreed,
            "n/a" if agreement is None else "%.2f" % agreement,
            "n/a" if decisive_acc is None else "%.2f" % decisive_acc,
            "n/a" if verbosity_rate is None else "%.2f" % verbosity_rate,
        )
    )
    if verbosity_rate is not None and len_decisive >= 4 and verbosity_rate >= 0.85:
        print("WARNING: verbosity bias — judge picked the longer transcript on %.0f%% of %d pairs" % (verbosity_rate * 100, len_decisive))
    if json_out:
        os.makedirs(os.path.dirname(os.path.abspath(json_out)), exist_ok=True)
        with open(json_out, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=2)
            fh.write("\n")


def main(argv):
    if len(argv) < 2:
        _fail("usage: replay_calibrate.py <mix|from-papercut|calibrate> [options]", 2)
    cmd, rest = argv[1], argv[2:]
    if cmd == "mix":
        cmd_mix(rest)
    elif cmd == "from-papercut":
        cmd_from_papercut(rest)
    elif cmd == "calibrate":
        cmd_calibrate(rest)
    else:
        _fail("unknown subcommand %r" % cmd, 2)


if __name__ == "__main__":
    main(sys.argv)

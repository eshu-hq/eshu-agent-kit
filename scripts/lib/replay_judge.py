#!/usr/bin/env python3
"""Blind judge and report for replay evals (issue #83, D5 scope).

Judge never learns arm identity: cmd_judge runs the strip-proof gate over the
pair package first and refuses input carrying mode/skill keys or arm tokens.
Win rate and cost delta are decoded in cmd_report with the sealed mapping the
judge never saw. One skill (performance-rigor), one harness (Muse).
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from replay_eval import SKILL, _taint_scan, fail, rubric_score  # noqa: E402


def _traj_tokens(traj):
    try:
        tin = float(traj.get("tokens_in") or 0)
    except (TypeError, ValueError):
        tin = 0.0
    try:
        tout = float(traj.get("tokens_out") or 0)
    except (TypeError, ValueError):
        tout = 0.0
    return {"in": max(0.0, tin), "out": max(0.0, tout)}


def judge_pair(pair, judge_cmd=None):
    for side in ("traj_a", "traj_b"):
        if side not in pair or not isinstance(pair[side], dict):
            fail("pair %s is missing %s" % (pair.get("pair_id"), side))
    tokens = {"A": _traj_tokens(pair["traj_a"]),
              "B": _traj_tokens(pair["traj_b"])}
    if judge_cmd:
        proc = subprocess.run(
            [judge_cmd], input=json.dumps(pair), capture_output=True,
            text=True, timeout=300)
        if proc.returncode != 0:
            fail("judge command failed: %s" % proc.stderr.strip()[-300:])
        verdict = proc.stdout.strip().upper()
        if verdict not in ("A", "B", "TIE"):
            fail("judge command must print A, B, or TIE (got %r)" % verdict)
        return verdict, {"tokens": tokens}
    prompt = pair.get("prompt") or ""
    score_a = rubric_score(prompt, pair["traj_a"])
    score_b = rubric_score(prompt, pair["traj_b"])
    diff = score_a["total"] - score_b["total"]
    if abs(diff) < 1e-9:
        winner = "tie"
    else:
        winner = "A" if diff > 0 else "B"
    return winner, {"A": score_a, "B": score_b,
                    "margin": round(abs(diff), 3), "tokens": tokens}


def cmd_judge(args):
    import getopt
    try:
        opts, _ = getopt.getopt(args, "", ["runs=", "out=", "judge-cmd=",
                                            "help"])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    runs = out = judge_cmd = None
    for key, val in opts:
        if key == "--runs":
            runs = val
        elif key == "--out":
            out = val
        elif key == "--judge-cmd":
            judge_cmd = val
        elif key == "--help":
            print("judge: blind rubric over pairs; refuses arm-labeled input.")
            return
    if not runs or not out:
        fail("judge needs --runs and --out", 2)
    with open(runs, encoding="utf-8") as fh:
        pairs = json.load(fh)
    if not isinstance(pairs, list) or not pairs:
        fail("no pairs to judge in %s" % runs)
    taint = _taint_scan(pairs)
    if taint:
        fail("strip-proof gate: judged package carries arm identity (%s); "
             "re-emit pairs via replay" % taint)
    comparisons = []
    for pair in pairs:
        winner, rubric = judge_pair(pair, judge_cmd)
        comparisons.append({"pair_id": pair.get("pair_id"),
                            "kind": pair.get("kind", "cross"),
                            "winner": winner, "rubric": rubric})
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"comparisons": comparisons}, fh, indent=1)
        fh.write("\n")
    print("judge: %d comparisons -> %s" % (len(comparisons), out))


def _mean(vals):
    return sum(vals) / len(vals) if vals else 0.0


def cmd_report(args):
    import getopt
    try:
        opts, _ = getopt.getopt(args, "", ["verdict=", "aa-verdict=", "seal=",
                                            "help"])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    verdict = aa_verdict = seal = None
    for key, val in opts:
        if key == "--verdict":
            verdict = val
        elif key == "--aa-verdict":
            aa_verdict = val
        elif key == "--seal":
            seal = val
        elif key == "--help":
            print("report: win rate (needs --seal), noise band, cost delta.")
            return
    if not verdict:
        fail("report needs --verdict", 2)
    with open(verdict, encoding="utf-8") as fh:
        cross = json.load(fh).get("comparisons", [])
    aa = []
    if aa_verdict:
        with open(aa_verdict, encoding="utf-8") as fh:
            aa = [c for c in json.load(fh).get("comparisons", [])
                  if c.get("kind") == "aa"]
    seal_map = {}
    if seal:
        with open(seal, encoding="utf-8") as fh:
            seal_map = json.load(fh)
    cross = [c for c in cross if c.get("kind") == "cross"]
    decisive = [c for c in cross if c.get("winner") != "tie"]
    wins = [c for c in decisive
            if seal_map.get(c.get("pair_id")) == c.get("winner")] \
        if seal_map else []
    ties = len(cross) - len(decisive)
    disagreements = [c for c in aa if c.get("winner") != "tie"]
    lines = []
    lines.append("replay-eval report: skill=%s" % SKILL)
    lines.append("cross pairs: %d (%d decisive, %d ties)" % (
        len(cross), len(decisive), ties))
    if seal_map and decisive:
        lines.append("win rate (with-skill): %d/%d = %.2f" % (
            len(wins), len(decisive), len(wins) / len(decisive)))
    elif seal_map:
        lines.append("win rate (with-skill): no decisive pairs")
    else:
        lines.append("win rate: withheld (no --seal; judge stayed blind)")
    if aa:
        lines.append("noise band (A/A disagreement): %d/%d = %.2f" % (
            len(disagreements), len(aa), len(disagreements) / len(aa)))
    else:
        lines.append("noise band: no A/A repeats recorded")
    if seal_map and cross:
        with_in, with_out, without_in, without_out = [], [], [], []
        for c in cross:
            toks = (c.get("rubric") or {}).get("tokens") or {}
            arm = seal_map.get(c.get("pair_id"))
            if arm not in ("A", "B") or arm not in toks:
                continue
            other = "B" if arm == "A" else "A"
            with_in.append(toks[arm]["in"])
            with_out.append(toks[arm]["out"])
            without_in.append(toks[other]["in"])
            without_out.append(toks[other]["out"])
        if with_in:
            lines.append("cost delta (mean with-skill minus stripped, "
                         "#80 token fields): %+.1f in / %+.1f out "
                         "over %d pairs" % (
                             _mean(with_in) - _mean(without_in),
                             _mean(with_out) - _mean(without_out),
                             len(with_in)))
        else:
            lines.append("cost delta: no token-bearing pairs")
    else:
        lines.append("cost delta: withheld (no --seal; judge stayed blind)")
    print("\n".join(lines))


def main(argv):
    if len(argv) < 2:
        print("Usage: replay_judge.py <judge|report> [options]",
              file=sys.stderr)
        sys.exit(2)
    cmd, rest = argv[1], argv[2:]
    if cmd == "judge":
        cmd_judge(rest)
    elif cmd == "report":
        cmd_report(rest)
    else:
        fail("unknown subcommand %r" % cmd, 2)


if __name__ == "__main__":
    main(sys.argv)

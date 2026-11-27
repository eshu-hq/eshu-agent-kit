#!/usr/bin/env python3
"""Blind judge, trajectory grader, and report for replay evals (issue #103).

Judge never learns arm identity: cmd_judge runs the strip-proof gate over the
pair package first and refuses input carrying mode/skill/skill_count keys or
arm tokens. Win rate, trajectory pass rates, cost delta, and latency delta are
decoded in cmd_report with the sealed mapping the judge never saw.
"""
import datetime
import getopt
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import canon_skill, default_eval_history, safe_float, safe_int  # noqa: E402
from replay_eval import _taint_scan, fail, rubric_score  # noqa: E402
from replay_history import _mean, append_history, load_seal, tool_deltas  # noqa: E402
from replay_runner import VALID_HARNESSES, parse_harness_output  # noqa: E402

_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL | re.IGNORECASE)
JUDGE_MAX_TRANSCRIPT_CHARS = 12000


def _traj_tokens(traj):
    return {
        "in": max(0.0, safe_float(traj.get("tokens_in"), 0.0)),
        "out": max(0.0, safe_float(traj.get("tokens_out"), 0.0)),
    }


def _pattern_matches(pattern, text):
    pat = str(pattern or "")
    if not pat:
        return False
    try:
        return bool(re.search(pat, text, re.IGNORECASE))
    except re.error:
        return pat.lower() in text.lower()


def grade_expectations(traj, expectations):
    """Deterministically grade one trajectory against an expectations dict."""
    if not isinstance(expectations, dict) or not expectations:
        return None
    text = str(traj.get("transcript") or "")
    tools = [str(t).lower() for t in (traj.get("tools") or [])]
    errors = max(0, safe_int(traj.get("errors"), 0))
    checks, failures = [], []

    req_tools = expectations.get("must_call_tools")
    if isinstance(req_tools, list) and req_tools:
        missing = [str(t) for t in req_tools if str(t).lower() not in tools]
        checks.append({"check": "must_call_tools", "passed": not missing, "missing": missing})
        if missing:
            failures.append("missing tools: %s" % ", ".join(missing))

    must_mention = expectations.get("must_mention")
    if isinstance(must_mention, list) and must_mention:
        missing = [str(p) for p in must_mention if not _pattern_matches(p, text)]
        checks.append({"check": "must_mention", "passed": not missing, "missing": missing})
        if missing:
            failures.append("missing mentions: %s" % ", ".join(missing))

    must_not = expectations.get("must_not_mention")
    if isinstance(must_not, list) and must_not:
        found = [str(p) for p in must_not if _pattern_matches(p, text)]
        checks.append({"check": "must_not_mention", "passed": not found, "found": found})
        if found:
            failures.append("forbidden mentions: %s" % ", ".join(found))

    if "max_errors" in expectations and expectations["max_errors"] is not None:
        limit = max(0, safe_int(expectations["max_errors"], 0))
        ok = errors <= limit
        checks.append({"check": "max_errors", "passed": ok, "actual": errors, "limit": limit})
        if not ok:
            failures.append("errors %d > max_errors %d" % (errors, limit))

    return {"passed": all(c["passed"] for c in checks) if checks else True, "checks": checks, "failures": failures}


def _bound_transcript(text, limit=JUDGE_MAX_TRANSCRIPT_CHARS):
    s = str(text or "")
    return s if len(s) <= limit else (s[:limit] + "\n...[truncated]")


def build_judge_prompt(pair):
    """Build a strictly blind A/B judge prompt with zero arm identity."""
    ta, tb = pair["traj_a"], pair["traj_b"]
    return (
        "You are a blind evaluator comparing two anonymous assistant responses "
        "(Response A and Response B) to the same task. Judge strictly on goal "
        "fulfillment, technical correctness, and efficiency. Do not guess how "
        "either response was produced.\n\n"
        "Task:\n%s\n\n"
        "=== Response A ===\nTools called: %s\nTool/run errors: %d\nTranscript:\n%s\n\n"
        "=== Response B ===\nTools called: %s\nTool/run errors: %d\nTranscript:\n%s\n\n"
        "Respond with ONLY a single JSON object (no prose outside JSON):\n"
        '{"winner": "A"|"B"|"TIE", '
        '"scores": {"A": {"goal": 1-5, "correctness": 1-5, "efficiency": 1-5}, '
        '"B": {"goal": 1-5, "correctness": 1-5, "efficiency": 1-5}}, '
        '"rationale": "concise justification"}'
    ) % (
        pair.get("prompt") or "",
        ", ".join(ta.get("tools") or []) or "none", max(0, safe_int(ta.get("errors"), 0)), _bound_transcript(ta.get("transcript")),
        ", ".join(tb.get("tools") or []) or "none", max(0, safe_int(tb.get("errors"), 0)), _bound_transcript(tb.get("transcript")),
    )


def _extract_json_object(raw_text):
    text = (raw_text or "").strip()
    if not text:
        raise ValueError("empty judge output")
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except ValueError:
        pass
    fenced = []
    for m in _FENCE_RE.finditer(text):
        try:
            obj = json.loads(m.group(1))
            if isinstance(obj, dict):
                fenced.append(obj)
        except ValueError:
            continue
    for obj in fenced:
        if "winner" in obj:
            return obj
    if fenced:
        return fenced[0]
    decoder, found, idx = json.JSONDecoder(), [], text.find("{")
    while idx != -1:
        try:
            obj, end = decoder.raw_decode(text, idx)
            if isinstance(obj, dict):
                found.append(obj)
            idx = text.find("{", end)
        except ValueError:
            idx = text.find("{", idx + 1)
    for obj in found:
        if "winner" in obj:
            return obj
    if found:
        return found[0]
    raise ValueError("no JSON object found in judge output")


def parse_judge_verdict(raw_text):
    """Parse blind LLM judge output into {'winner', 'scores', 'rationale'}."""
    data = _extract_json_object(raw_text)
    raw_winner = str(data.get("winner") or "").strip().upper()
    if raw_winner == "TIE":
        winner = "tie"
    elif raw_winner in ("A", "B"):
        winner = raw_winner
    else:
        raise ValueError("invalid winner %r (expected A, B, or TIE)" % raw_winner)
    scores = data.get("scores") if isinstance(data.get("scores"), dict) else {}
    return {"winner": winner, "scores": scores, "rationale": str(data.get("rationale") or "").strip()}


def _invoke_judge_harness(harness, model, prompt_text, timeout=180):
    with tempfile.TemporaryDirectory(prefix="replay-judge-") as tmpdir:
        stdin_text = None
        if harness == "claude":
            cmd = ["claude", "-p", "--output-format", "json", "--no-session-persistence", "--disable-slash-commands"]
            if model:
                cmd += ["--model", model]
            stdin_text = prompt_text
        elif harness == "agy":
            cmd = ["agy", "--output-format", "json", "--disable-slash-commands"]
            if model:
                cmd += ["--model", model]
            cmd.append("-p=" + prompt_text)
        elif harness == "muse":
            pf = os.path.join(tmpdir, "judge-prompt.txt")
            with open(pf, "w", encoding="utf-8") as fh:
                fh.write(prompt_text)
            cmd = [
                "muse", "exec", "--json", "--no-session-log", "--disable-web-tools",
                "--disable-reminders", "--disable-request-user-input",
                "--no-foreign-personal-context", "--trust-workspace",
                "--approval-mode", "never", "--workspace", tmpdir,
            ]
            if model:
                cmd += ["--model", model]
            cmd += ["--prompt-file", pf]
        elif harness == "codex":
            cmd = ["codex", "exec", "--json", "--skip-git-repo-check", "-C", tmpdir]
            if model:
                cmd += ["-m", model]
            cmd.append("-")
            stdin_text = prompt_text
        elif harness == "opencode":
            cmd = ["opencode", "run", "--format", "json", "--archived"]
            if model:
                cmd += ["-m", model]
            cmd.append(prompt_text)
        else:
            fail("unsupported --judge-harness %r" % harness, 2)
        try:
            proc = subprocess.run(cmd, input=stdin_text, cwd=tmpdir, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            fail("judge harness %s timed out after %ds" % (harness, timeout))
        except FileNotFoundError:
            fail("judge harness binary not found on PATH: %s" % cmd[0])
        except OSError as exc:
            fail("judge harness %s could not execute: %s" % (harness, exc))
        if proc.returncode != 0:
            fail("judge harness %s failed: %s" % (harness, (proc.stderr or proc.stdout).strip()[-400:]))
        parsed = parse_harness_output(harness, proc.stdout, 0.0)
        try:
            return parse_judge_verdict(parsed.get("transcript") or proc.stdout)
        except ValueError as exc:
            fail("judge harness %s returned invalid verdict JSON: %s" % (harness, exc))


def judge_pair(pair, judge_cmd=None, judge_harness=None, judge_model="", timeout=180):
    for side in ("traj_a", "traj_b"):
        if side not in pair or not isinstance(pair[side], dict):
            fail("pair %s is missing %s" % (pair.get("pair_id"), side))
    rubric = {
        "tokens": {"A": _traj_tokens(pair["traj_a"]), "B": _traj_tokens(pair["traj_b"])},
        "wall_time_s": {
            "A": max(0.0, safe_float(pair["traj_a"].get("wall_time_s"), 0.0)),
            "B": max(0.0, safe_float(pair["traj_b"].get("wall_time_s"), 0.0)),
        },
    }
    if all(isinstance(pair[side].get("tool_calls"), int) for side in ("traj_a", "traj_b")):
        rubric["tool_calls"] = {"A": pair["traj_a"]["tool_calls"], "B": pair["traj_b"]["tool_calls"]}
        rubric["errors"] = {
            side: max(0, safe_int(pair["traj_" + side.lower()].get("errors"), 0)) for side in ("A", "B")
        }
    exp = pair.get("expectations")
    if isinstance(exp, dict) and exp:
        rubric["expectations"] = {
            "A": grade_expectations(pair["traj_a"], exp),
            "B": grade_expectations(pair["traj_b"], exp),
        }
    if judge_cmd:
        cmd_timeout = max(60, timeout)
        try:
            proc = subprocess.run([judge_cmd], input=json.dumps(pair), capture_output=True, text=True, timeout=cmd_timeout)
        except subprocess.TimeoutExpired:
            fail("judge command %s timed out after %ds" % (judge_cmd, cmd_timeout))
        except OSError as exc:
            fail("judge command %s could not execute: %s" % (judge_cmd, exc))
        if proc.returncode != 0:
            fail("judge command failed: %s" % proc.stderr.strip()[-300:])
        verdict = proc.stdout.strip().upper()
        if verdict not in ("A", "B", "TIE"):
            fail("judge command must print A, B, or TIE (got %r)" % verdict)
        return ("tie" if verdict == "TIE" else verdict), rubric
    if judge_harness:
        res = _invoke_judge_harness(judge_harness, judge_model, build_judge_prompt(pair), timeout=timeout)
        rubric["scores"] = res["scores"]
        rubric["rationale"] = res["rationale"]
        return res["winner"], rubric
    prompt = pair.get("prompt") or ""
    score_a, score_b = rubric_score(prompt, pair["traj_a"]), rubric_score(prompt, pair["traj_b"])
    diff = score_a["total"] - score_b["total"]
    winner = "tie" if abs(diff) < 1e-9 else ("A" if diff > 0 else "B")
    rubric.update({"A": score_a, "B": score_b, "margin": round(abs(diff), 3)})
    return winner, rubric


def cmd_judge(args):
    try:
        opts, _ = getopt.getopt(args, "", [
            "runs=", "out=", "judge-cmd=", "judge-harness=", "judge-model=", "timeout=", "help",
        ])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    runs = out = judge_cmd = judge_harness = None
    judge_model, timeout = "", 180
    for key, val in opts:
        if key == "--runs":
            runs = val
        elif key == "--out":
            out = val
        elif key == "--judge-cmd":
            judge_cmd = val
        elif key == "--judge-harness":
            judge_harness = val.strip().lower()
        elif key == "--judge-model":
            judge_model = val
        elif key == "--timeout":
            try:
                timeout = int(val)
            except ValueError:
                fail("--timeout must be an integer", 2)
        elif key == "--help":
            print(
                "judge: blind rubric / LLM judge over pairs; refuses arm-labeled input.\n"
                "Options: --runs FILE --out FILE [--judge-cmd PATH]\n"
                "         [--judge-harness claude|agy|muse] [--judge-model ID] [--timeout SEC]"
            )
            return
    if not runs or not out:
        fail("judge needs --runs and --out", 2)
    if timeout < 1:
        fail("--timeout must be >= 1", 2)
    if judge_cmd and judge_harness:
        fail("use either --judge-cmd or --judge-harness, not both", 2)
    if judge_harness and judge_harness not in VALID_HARNESSES:
        fail("unsupported --judge-harness %r (expected claude|agy|muse)" % judge_harness, 2)
    with open(runs, encoding="utf-8") as fh:
        pairs = json.load(fh)
    if not isinstance(pairs, list) or not pairs:
        fail("no pairs to judge in %s" % runs)
    taint = _taint_scan(pairs)
    if taint:
        fail("strip-proof gate: judged package carries arm identity (%s); re-emit pairs via replay" % taint)
    comparisons = []
    for pair in pairs:
        winner, rubric = judge_pair(pair, judge_cmd=judge_cmd, judge_harness=judge_harness,
                                    judge_model=judge_model, timeout=timeout)
        comparisons.append({
            "pair_id": pair.get("pair_id"), "kind": pair.get("kind", "cross"),
            "category": pair.get("category", "production"), "winner": winner, "rubric": rubric,
        })
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"comparisons": comparisons}, fh, indent=1)
        fh.write("\n")
    print("judge: %d comparisons -> %s" % (len(comparisons), out))


def cmd_report(args):
    try:
        opts, _ = getopt.getopt(args, "", [
            "verdict=", "aa-verdict=", "seal=", "skill=", "json-out=", "history=", "default-history", "help",
        ])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    verdict = aa_verdict = seal = skill_opt = json_out = history = None
    for key, val in opts:
        if key == "--verdict":
            verdict = val
        elif key == "--aa-verdict":
            aa_verdict = val
        elif key == "--seal":
            seal = val
        elif key == "--skill":
            skill_opt = canon_skill(val)
        elif key == "--json-out":
            json_out = val
        elif key in ("--history", "--default-history"):
            if history:
                fail("--history and --default-history are mutually exclusive", 2)
            if key == "--history" and not str(val or "").strip():
                fail("--history requires a non-empty file path", 2)
            history = val if key == "--history" else default_eval_history()
        elif key == "--help":
            print("report: win rate, noise band, pass rates, tool/error, cost & latency delta.\n"
                  "Options: --verdict FILE [--aa-verdict FILE] [--seal FILE] [--skill NAME] [--json-out FILE]\n"
                  "         [--history FILE | --default-history]  append the summary to a JSONL ledger (needs --seal)")
            return
    if not verdict:
        fail("report needs --verdict", 2)
    if history and not seal:
        fail("--history/--default-history requires --seal (a ledger line without arm decoding is not comparable)", 2)
    with open(verdict, encoding="utf-8") as fh:
        all_comps = json.load(fh).get("comparisons", [])
    cross = [c for c in all_comps if c.get("kind") == "cross"]
    if aa_verdict:
        with open(aa_verdict, encoding="utf-8") as fh:
            aa = [c for c in json.load(fh).get("comparisons", []) if c.get("kind") == "aa"]
    else:
        aa = [c for c in all_comps if c.get("kind") == "aa"]
    seal_map, seal_meta = load_seal(seal)
    if seal:
        missing = [str(c.get("pair_id")) for c in cross if seal_map.get(c.get("pair_id")) not in ("A", "B")]
        if missing:
            fail("seal %s is missing valid A/B arm mapping for cross pair(s): %s" % (seal, ", ".join(missing[:10])))
    skill = skill_opt or str(seal_meta.get("skill") or "unknown")
    harness = str(seal_meta.get("harness") or "unknown")
    decisive = [c for c in cross if c.get("winner") != "tie"]
    wins = [c for c in decisive if seal_map.get(c.get("pair_id")) == c.get("winner")] if seal_map else []
    ties = len(cross) - len(decisive)
    win_rate = round(len(wins) / len(decisive), 4) if (seal_map and decisive) else None
    disagreements = [c for c in aa if c.get("winner") != "tie"]
    noise_band = round(len(disagreements) / len(aa), 4) if aa else None

    with_in, with_out, without_in, without_out, with_lat, without_lat, pass_with, pass_without = (
        [], [], [], [], [], [], [], []
    )
    for c in (cross if seal_map else []):
        arm = seal_map.get(c.get("pair_id"))
        if arm not in ("A", "B"):
            continue
        other = "B" if arm == "A" else "A"
        rub = c.get("rubric") or {}
        toks, wt, exps = rub.get("tokens") or {}, rub.get("wall_time_s") or {}, rub.get("expectations") or {}
        if arm in toks and other in toks:
            with_in.append(safe_float(toks[arm].get("in"), 0.0))
            with_out.append(safe_float(toks[arm].get("out"), 0.0))
            without_in.append(safe_float(toks[other].get("in"), 0.0))
            without_out.append(safe_float(toks[other].get("out"), 0.0))
        if arm in wt and other in wt:
            with_lat.append(safe_float(wt[arm], 0.0))
            without_lat.append(safe_float(wt[other], 0.0))
        if isinstance(exps.get(arm), dict) and isinstance(exps.get(other), dict):
            pass_with.append(1 if exps[arm].get("passed") else 0)
            pass_without.append(1 if exps[other].get("passed") else 0)

    pass_rate_with = round(sum(pass_with) / len(pass_with), 4) if pass_with else None
    pass_rate_without = round(sum(pass_without) / len(pass_without), 4) if pass_without else None
    cost_delta_in = round(_mean(with_in) - _mean(without_in), 2) if with_in else None
    cost_delta_out = round(_mean(with_out) - _mean(without_out), 2) if with_out else None
    latency_delta_s = round(_mean(with_lat) - _mean(without_lat), 3) if with_lat else None
    tool_calls_delta, tool_errors_delta, tool_pairs = tool_deltas(cross, seal_map)
    sha = seal_meta.get("skill_sha") if isinstance(seal_meta.get("skill_sha"), str) else None

    lines = [
        "replay-eval report: skill=%s harness=%s" % (skill, harness),
        "cross pairs: %d (%d decisive, %d ties)" % (len(cross), len(decisive), ties),
    ]
    if win_rate is not None:
        lines.append("win rate (with-skill): %d/%d = %.2f" % (len(wins), len(decisive), win_rate))
    else:
        lines.append("win rate (with-skill): no decisive pairs" if seal_map else "win rate: withheld (no --seal; judge stayed blind)")
    if noise_band is not None:
        lines.append("noise band (A/A disagreement): %d/%d = %.2f" % (len(disagreements), len(aa), noise_band))
        if win_rate is not None:
            note = "within A/A noise band (inconclusive)" if (noise_band >= 0.5 or abs(win_rate - 0.5) <= noise_band / 2.0) else "exceeds A/A noise band"
            lines.append("signal-vs-noise: %s" % note)
    else:
        lines.append("noise band: no A/A repeats recorded")
    if pass_rate_with is not None:
        lines.append("trajectory pass rate (with vs without): %d/%d = %.2f vs %d/%d = %.2f" % (
            sum(pass_with), len(pass_with), pass_rate_with, sum(pass_without), len(pass_without), pass_rate_without))
        if pass_rate_with == 1.0 and len(pass_with) >= 3:
            lines.append("WARNING: sweet-spot check — with-skill pass rate is 100%% over %d pairs (target 60-90%%; suite may be saturated, add harder edge cases)" % len(pass_with))
    else:
        lines.append("trajectory pass rate: no expectations recorded" if seal_map else "trajectory pass rate: withheld (no --seal; judge stayed blind)")
    if cost_delta_in is not None:
        lines.append("cost delta (mean with-skill minus stripped): %+.1f in / %+.1f out over %d pairs" % (cost_delta_in, cost_delta_out, len(with_in)))
    else:
        lines.append("cost delta: no token-bearing pairs" if seal_map else "cost delta: withheld (no --seal; judge stayed blind)")
    if latency_delta_s is not None:
        lines.append("latency delta (mean with-skill minus stripped): %+.3fs over %d pairs" % (latency_delta_s, len(with_lat)))
    else:
        lines.append("latency delta: no latency-bearing pairs" if seal_map else "latency delta: withheld (no --seal; judge stayed blind)")
    if tool_calls_delta is not None:
        lines.append("tool delta (mean with-skill minus stripped): %+.2f calls / %+.2f errors over %d pairs" % (
            tool_calls_delta, tool_errors_delta, tool_pairs))
    else:
        lines.append("tool delta: no tool-bearing pairs" if seal_map else "tool delta: withheld (no --seal; judge stayed blind)")
    print("\n".join(lines))

    if json_out or history:
        summary = {
            "skill": skill, "harness": harness, "cross_pairs": len(cross),
            "decisive_pairs": len(decisive), "ties": ties,
            "with_skill_wins": len(wins) if seal_map else None, "win_rate": win_rate,
            "noise_band": noise_band, "aa_pairs": len(aa),
            "pass_rate_with": pass_rate_with, "pass_rate_without": pass_rate_without,
            "cost_delta_in": cost_delta_in, "cost_delta_out": cost_delta_out,
            "latency_delta_s": latency_delta_s,
            "tool_calls_delta": tool_calls_delta, "tool_errors_delta": tool_errors_delta,
            "tool_pairs": tool_pairs, "skill_sha": sha, "kind": "ablation",
            "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        if json_out:
            with open(json_out, "w", encoding="utf-8") as fh:
                json.dump(summary, fh, indent=2)
                fh.write("\n")
        if history:
            append_history(history, summary)


def main(argv):
    if len(argv) < 2:
        print("Usage: replay_judge.py <judge|report> [options]", file=sys.stderr)
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

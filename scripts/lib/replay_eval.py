#!/usr/bin/env python3
"""Multi-harness replay-eval backend (issue #103).

Mine first prompts from Muse, Claude, or Agy transcripts, replay each prompt
with any target skill loaded vs stripped via the built-in isolated runner (or a
custom --runner), and emit strip-proof blind A/B pairs plus a sealed arm map.

Subcommands:
  mine    First-prompt-only fixtures from raw Muse, Claude, or Agy transcripts.
  replay  Run each prompt both ways; emit blind A/B pairs plus seal.json.

Refresh path: re-run `mine` as new sessions accrue; keep mined production suites
local (never commit raw transcripts). Nothing in this harness runs in CI.
"""
import getopt
import json
import os
import random
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import debrief_extract_agy as agy_mod  # noqa: E402
import debrief_extract_claude as claude_mod  # noqa: E402
import debrief_extract_muse as muse_mod  # noqa: E402
from debrief_common import (  # noqa: E402
    canon_skill, is_fixture_session, load_json_lines,
    safe_float, safe_int, truncate_text,
)

VALID_HARNESSES = ("muse", "claude", "agy")
VALID_CATEGORIES = ("golden", "production", "edge")
BANNED_KEYS = frozenset({
    "mode", "arm", "skill", "skills", "skill_count",
    "with_skill", "without_skill", "with-skill", "without-skill",
})
BANNED_VALUES = frozenset({
    "with-skill", "without-skill", "with_skill", "without_skill",
})
ARM_TOKEN_RE = re.compile(r"with[-_]skill|without[-_]skill", re.IGNORECASE)
STOPWORDS = frozenset(
    "the a an and or for with from that this what how add use via per our your "
    "are was were been does did doing than then into over under again once here "
    "there when where which while".split()
)


def fail(msg, code=1):
    print("replay-eval: %s" % msg, file=sys.stderr)
    sys.exit(code)


def usage(code=2):
    print(__doc__.split("Subcommands")[0].strip(), file=sys.stderr)
    print("Usage: replay-eval.sh <mine|replay|judge|report> [options]", file=sys.stderr)
    sys.exit(code)


def _first_prompt_muse(path):
    for rec in load_json_lines(path):
        pl = rec.get("payload")
        ev = pl.get("event") if isinstance(pl, dict) else None
        if not isinstance(ev, dict) or ev.get("kind") != "model_user_messages":
            continue
        for msg in (ev.get("messages") if isinstance(ev.get("messages"), list) else []):
            if isinstance(msg, str) and msg.strip():
                return msg.strip()
    return ""


def _first_prompt_claude(path):
    for rec in load_json_lines(path):
        if rec.get("type") != "user":
            continue
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        content = msg.get("content") or []
        has_tool_result = False
        if isinstance(content, str):
            text = content.strip()
        elif isinstance(content, list):
            text = " ".join(
                b["text"] for b in content
                if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
            ).strip()
            has_tool_result = any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
        else:
            text = ""
        if claude_mod._is_owner_turn(rec, text, has_tool_result):
            return text
    return ""


def _first_prompt_agy(path):
    for rec in load_json_lines(path):
        if rec.get("type") != "USER_INPUT":
            continue
        raw = rec.get("text") or rec.get("user_response") or rec.get("content") or ""
        if isinstance(raw, str) and raw.strip():
            return raw.strip()
    return ""


def _maybe_append(items, harness, sid, prompt, meta, req_skill, query_re, category):
    if not prompt:
        return
    loads = [canon_skill(s) for s in (meta.get("skill_loads") or []) if s]
    if req_skill and req_skill not in loads:
        return
    if query_re and not query_re.search(prompt):
        return
    items.append({
        "id": "%s-%s" % (harness, sid),
        "session_id": sid,
        "harness": harness,
        "skill": req_skill if req_skill else (loads[0] if loads else ""),
        "category": category,
        "prompt": truncate_text(prompt, 1000),
        "prompts_in_session": max(1, safe_int(meta.get("prompts"), 1)),
    })


def _mine_harness(harness, roots, req_skill, query_re, category):
    items = []
    if harness == "muse":
        for path, mt in muse_mod.discover(roots or muse_mod.default_roots(), 0):
            parts = os.path.normpath(path).split(os.sep)
            if len(parts) >= 4 and parts[-3] == "subagent":
                continue
            meta, _ = muse_mod.extract_session(path, mt)
            sid = str(meta.get("id") or "")
            if sid and not meta.get("parent_session") and not is_fixture_session(sid):
                _maybe_append(items, harness, sid, _first_prompt_muse(path), meta, req_skill, query_re, category)
    elif harness == "claude":
        for path, mt in claude_mod.discover(roots or claude_mod.default_roots(), 0):
            if claude_mod._parent_from_path(path):
                continue
            meta, _ = claude_mod.extract_session(path, mt)
            sid = str(meta.get("id") or "")
            if sid and not meta.get("parent_session") and not is_fixture_session(sid):
                _maybe_append(items, harness, sid, _first_prompt_claude(path), meta, req_skill, query_re, category)
    elif harness == "agy":
        db_cache = {}
        for path, mt in agy_mod.discover(roots or agy_mod.default_roots(), 0):
            smeta = agy_mod.load_summary_meta(path, db_cache)
            if safe_int(smeta.get("nesting_depth"), 0) > 0 or smeta.get("parent_session"):
                continue
            meta, _ = agy_mod.extract_session(path, mt, db_cache=db_cache)
            sid = str(meta.get("id") or "")
            if sid and not meta.get("parent_session") and not is_fixture_session(sid):
                _maybe_append(items, harness, sid, _first_prompt_agy(path), meta, req_skill, query_re, category)
    return items


def cmd_mine(args):
    try:
        opts, _ = getopt.getopt(args, "", [
            "harness=", "sessions-root=", "skill=", "query=", "top-steered",
            "category=", "max=", "out=", "help",
        ])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    harness, roots, req_skill, query_str = "all", [], "", ""
    top_steered, category, maxn, out = False, "production", 50, None
    for key, val in opts:
        if key == "--harness":
            harness = val.strip().lower()
        elif key == "--sessions-root":
            roots.append(val)
        elif key == "--skill":
            req_skill = canon_skill(val)
        elif key == "--query":
            query_str = val
        elif key == "--top-steered":
            top_steered = True
        elif key == "--category":
            category = val.strip().lower()
        elif key == "--max":
            try:
                maxn = int(val)
            except ValueError:
                fail("--max must be an integer", 2)
        elif key == "--out":
            out = val
        elif key == "--help":
            print(
                "mine: re-mine first prompts from raw Muse, Claude, or Agy transcripts.\n"
                "Refresh path: re-run mine as new sessions accrue; keep mined production\n"
                "evals local and never commit raw transcripts.\n"
                "Options: --harness muse|claude|agy|all --sessions-root PATH (repeatable)\n"
                "         --skill NAME --query REGEX --top-steered\n"
                "         --category golden|production|edge --max N --out FILE"
            )
            return
    if harness != "all" and harness not in VALID_HARNESSES:
        fail("unsupported --harness %r (expected muse|claude|agy|all)" % harness, 2)
    if category not in VALID_CATEGORIES:
        fail("unsupported --category %r (expected golden|production|edge)" % category, 2)
    if maxn < 1:
        fail("--max must be >= 1", 2)
    if not out:
        fail("mine needs --out", 2)
    query_re = None
    if query_str:
        try:
            query_re = re.compile(query_str, re.IGNORECASE)
        except re.error as exc:
            fail("invalid --query regex %r: %s" % (query_str, exc), 2)
    evals = []
    for h in (VALID_HARNESSES if harness == "all" else (harness,)):
        evals.extend(_mine_harness(h, roots, req_skill, query_re, category))
    if top_steered:
        evals.sort(key=lambda e: (-e["prompts_in_session"], e["harness"], e["session_id"]))
    else:
        evals.sort(key=lambda e: (e["harness"], e["session_id"]))
    evals = evals[:maxn]
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(evals, fh, indent=1)
        fh.write("\n")
    print("mine: %d evals -> %s" % (len(evals), out))


def _builtin_runner_path():
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "replay-runner.sh")


def run_runner(runner, mode, skill, prompt, prompt_file, out_path,
               harness="claude", model="", workspace="", kit_dir="", timeout=300):
    with open(prompt_file, "w", encoding="utf-8") as fh:
        fh.write(prompt)
    if runner:
        cmd = [runner, "--mode", mode, "--skill", skill, "--prompt-file", prompt_file, "--out", out_path]
    else:
        cmd = ["bash", _builtin_runner_path(), "--harness", harness, "--mode", mode, "--skill", skill,
               "--prompt-file", prompt_file, "--out", out_path, "--timeout", str(timeout)]
    for flag, val in (("--model", model), ("--workspace", workspace), ("--kit-dir", kit_dir)):
        if val:
            cmd += [flag, val]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=max(60, timeout + 60))
    if proc.returncode != 0:
        label = runner or ("replay-runner.sh(%s)" % harness)
        fail("runner %s failed for mode %s: %s" % (label, mode, (proc.stderr or proc.stdout).strip()[-500:]))
    try:
        with open(out_path, encoding="utf-8") as fh:
            traj = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("runner wrote no trajectory JSON for mode %s: %s" % (mode, exc))
    if not isinstance(traj, dict) or not isinstance(traj.get("transcript"), str):
        fail("runner trajectory needs a transcript string (mode %s)" % mode)
    return traj


def blind_traj(traj):
    """Strip arm identity and skill_count; keep behavior and cost metrics."""
    raw_tools = traj.get("tools")
    tools = [ARM_TOKEN_RE.sub("[arm]", str(t)) for t in raw_tools[:50]] if isinstance(raw_tools, list) else []
    return {
        "transcript": ARM_TOKEN_RE.sub("[arm]", traj.get("transcript") or ""),
        "tools": tools,
        "errors": max(0, safe_int(traj.get("errors"), 0)),
        "tokens_in": max(0.0, safe_float(traj.get("tokens_in"), 0.0)),
        "tokens_out": max(0.0, safe_float(traj.get("tokens_out"), 0.0)),
        "cache_read_tokens": max(0.0, safe_float(traj.get("cache_read_tokens"), 0.0)),
        "wall_time_s": round(max(0.0, safe_float(traj.get("wall_time_s"), 0.0)), 3),
        "cost_usd": round(max(0.0, safe_float(traj.get("cost_usd"), 0.0)), 6),
    }


def cmd_replay(args):
    try:
        opts, _ = getopt.getopt(args, "", [
            "evals=", "runner=", "skill=", "harness=", "model=", "workspace=",
            "kit-dir=", "timeout=", "out=", "seal=", "repeats=", "help",
        ])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    evals_path = runner = out = seal = None
    skill = model = workspace = kit_dir = ""
    harness, repeats, timeout = "claude", 1, 300
    for key, val in opts:
        if key == "--evals":
            evals_path = val
        elif key == "--runner":
            runner = val
        elif key == "--skill":
            skill = canon_skill(val)
        elif key == "--harness":
            harness = val.strip().lower()
        elif key == "--model":
            model = val
        elif key == "--workspace":
            workspace = val
        elif key == "--kit-dir":
            kit_dir = val
        elif key == "--timeout":
            try:
                timeout = int(val)
            except ValueError:
                fail("--timeout must be an integer", 2)
        elif key == "--out":
            out = val
        elif key == "--seal":
            seal = val
        elif key == "--repeats":
            try:
                repeats = int(val)
            except ValueError:
                fail("--repeats must be an integer", 2)
        elif key == "--help":
            print(
                "replay: run each eval with-skill vs stripped; emit blind pairs + seal.\n"
                "Options: --evals FILE --skill NAME [--harness claude|agy|muse]\n"
                "         [--runner CMD] [--model ID] [--workspace PATH] [--kit-dir PATH]\n"
                "         [--timeout SEC] [--repeats N] --out FILE --seal FILE"
            )
            return
    if not skill:
        fail("replay needs --skill", 2)
    if harness not in VALID_HARNESSES:
        fail("unsupported --harness %r (expected claude|agy|muse)" % harness, 2)
    if not evals_path or not out or not seal:
        fail("replay needs --evals, --skill, --out, and --seal", 2)
    if repeats < 1:
        fail("--repeats must be >= 1", 2)
    with open(evals_path, encoding="utf-8") as fh:
        evals = json.load(fh)
    if not isinstance(evals, list):
        fail("evals file must be a JSON array")
    rng = random.Random()
    tmp = os.path.dirname(os.path.abspath(out)) or "."
    pairs, arms_map = [], {}
    for idx, item in enumerate(evals):
        prompt = item.get("prompt") or ""
        if not prompt:
            fail("eval %d has no prompt" % idx)
        with_runs, without_runs = [], []
        for rep in range(repeats):
            pf = os.path.join(tmp, ".replay-prompt-%d-%d" % (idx, rep))
            for mode, bucket in (("with-skill", with_runs), ("without-skill", without_runs)):
                op = os.path.join(tmp, ".replay-traj-%d-%d-%s" % (idx, rep, mode))
                traj = run_runner(
                    runner, mode, skill, prompt, pf, op, harness=harness,
                    model=model, workspace=workspace, kit_dir=kit_dir, timeout=timeout,
                )
                bucket.append(blind_traj(traj))
                try:
                    os.remove(op)
                except OSError:
                    pass
            try:
                os.remove(pf)
            except OSError:
                pass
        pid = "p%d" % idx
        order = ["with", "without"]
        rng.shuffle(order)
        trajs = {"with": with_runs[0], "without": without_runs[0]}
        pair = {
            "pair_id": pid, "kind": "cross",
            "category": str(item.get("category") or "production"),
            "prompt": prompt, "session_id": item.get("session_id", ""),
        }
        if isinstance(item.get("expectations"), dict):
            pair["expectations"] = item["expectations"]
        for pos, arm in zip(("traj_a", "traj_b"), order):
            pair[pos] = trajs[arm]
            if arm == "with":
                arms_map[pid] = pos[-1].upper()
        pairs.append(pair)
        for rep in range(1, repeats):
            for bucket in (with_runs, without_runs):
                apid = "p%d-aa%d" % (idx, len(arms_map))
                aa = [bucket[0], bucket[rep]]
                rng.shuffle(aa)
                pairs.append({
                    "pair_id": apid, "kind": "aa",
                    "category": str(item.get("category") or "production"),
                    "prompt": prompt, "session_id": item.get("session_id", ""),
                    "traj_a": aa[0], "traj_b": aa[1],
                })
                arms_map[apid] = "A"
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(pairs, fh, indent=1)
        fh.write("\n")
    with open(seal, "w", encoding="utf-8") as fh:
        json.dump({"meta": {"skill": skill, "harness": harness}, "arms": arms_map}, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print("replay: %d pairs (%d evals, skill=%s, harness=%s, repeats=%d) -> %s" % (
        len(pairs), len(evals), skill, harness, repeats, out))


def _taint_scan(node):
    if isinstance(node, dict):
        for key, val in node.items():
            if key in BANNED_KEYS:
                return "banned key %r" % key
            hit = _taint_scan(val)
            if hit:
                return hit
    elif isinstance(node, list):
        for val in node:
            hit = _taint_scan(val)
            if hit:
                return hit
    elif isinstance(node, str):
        lowered = node.strip().lower()
        for banned in BANNED_VALUES:
            if banned in lowered:
                return "banned arm value %r" % banned
    return ""


def _sig_words(prompt):
    words = []
    for raw in prompt.lower().split():
        word = "".join(ch for ch in raw if ch.isalnum())
        if len(word) > 3 and word not in STOPWORDS and word not in words:
            words.append(word)
    return words[:24]


def rubric_score(prompt, traj):
    """Blind offline fallback rubric: zero skill or arm leakage."""
    words = _sig_words(prompt)
    text = (traj.get("transcript") or "").lower()
    coverage = (sum(1 for w in words if w in text) / len(words)) if words else 0.0
    tool_use = 1.0 if traj.get("tools") else 0.0
    error_free = 1.0 if safe_int(traj.get("errors"), 0) == 0 else 0.0
    total = 0.55 * coverage + 0.20 * tool_use + 0.25 * error_free
    return {
        "goal_coverage": round(coverage, 3), "tool_use": tool_use,
        "error_free": error_free, "total": round(total, 3),
    }


def main(argv):
    if len(argv) < 2:
        usage()
    cmd, rest = argv[1], argv[2:]
    if cmd == "mine":
        cmd_mine(rest)
    elif cmd == "replay":
        cmd_replay(rest)
    elif cmd in ("judge", "report"):
        fail("%r lives in replay_judge.py (routed by replay-eval.sh)" % cmd, 2)
    elif cmd in ("-h", "--help", "help"):
        usage(0)
    else:
        fail("unknown subcommand %r" % cmd, 2)


if __name__ == "__main__":
    main(sys.argv)

#!/usr/bin/env python3
"""Replay-eval harness backend for issue #83 (D5 scope, do not widen).

One skill (performance-rigor), one harness (Muse). Replays first prompts
re-mined from raw Muse transcripts with the skill loaded vs stripped, then
blind-judges which trajectory better satisfies the session's evident goal.

Mine and replay half of the harness (judge/report live in replay_judge.py).

Subcommands:
  mine    First-prompt-only fixtures from raw session.jsonl transcripts.
  replay  Run each prompt both ways via an injectable --runner; emit a blind
          pair package (randomized A/B labels) plus a sealed arm mapping.

Refresh path: re-run `mine` as new sessions accrue and concat new session_ids;
fixtures are never hand-written. Nothing in this harness runs in CI.
"""
import json
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import is_fixture_session, truncate_text  # noqa: E402

SKILL = "performance-rigor"
HARNESS = "muse"
BANNED_KEYS = frozenset({
    "mode", "arm", "skill", "skills", "with_skill", "without_skill",
    "with-skill", "without-skill",
})
BANNED_VALUES = frozenset({"with-skill", "without-skill",
                                 "with_skill", "without_skill"})
STOPWORDS = frozenset(
    "the a an and or for with from that this what how add use via per our your "
    "are was were been does did doing than then into over under again once here "
    "there when where which while with".split()
)


def fail(msg, code=1):
    print("replay-eval: %s" % msg, file=sys.stderr)
    sys.exit(code)


def usage(code=2):
    print(__doc__.split("Subcommands")[0].strip(), file=sys.stderr)
    print("Usage: replay-eval.sh <mine|replay|judge|report> [options]",
          file=sys.stderr)
    sys.exit(code)


def load_json_lines(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s:
                continue
            try:
                yield json.loads(s)
            except ValueError:
                continue


def _first_user_text(path):
    """First model_user_messages text in a raw Muse session.jsonl."""
    for rec in load_json_lines(path):
        if not isinstance(rec, dict):
            continue
        pl = rec.get("payload")
        if not isinstance(pl, dict):
            continue
        ev = pl.get("event")
        if not isinstance(ev, dict):
            continue
        if ev.get("kind") != "model_user_messages":
            continue
        msgs = ev.get("messages")
        if not isinstance(msgs, list):
            continue
        for m in msgs:
            if isinstance(m, str) and m.strip():
                return m.strip()
    return ""


def _session_id(path, rec_id):
    if rec_id:
        return str(rec_id)
    parent = os.path.basename(os.path.dirname(path))
    return parent or path


def cmd_mine(args):
    import getopt
    try:
        opts, _ = getopt.getopt(args, "", [
            "sessions-root=", "out=", "max=", "harness=", "help"])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    root = out = None
    maxn = 50
    harness = HARNESS
    for key, val in opts:
        if key == "--sessions-root":
            root = val
        elif key == "--out":
            out = val
        elif key == "--max":
            maxn = int(val)
        elif key == "--harness":
            harness = val
        elif key == "--help":
            print("mine: re-mine first prompts from raw Muse transcripts.\n"
                  "Refresh path: re-run mine as new sessions accrue and keep\n"
                  "new session_ids; fixtures stay mined, never hand-written.")
            return
    if harness != HARNESS:
        fail("only the muse harness is supported (got %r)" % harness, 2)
    if not root or not out:
        fail("mine needs --sessions-root and --out", 2)
    found = []
    for dp, _, fns in os.walk(root):
        if "session.jsonl" not in fns:
            continue
        parts = os.path.normpath(os.path.join(dp, "session.jsonl")).split(os.sep)
        if len(parts) >= 4 and parts[-3] == "subagent":
            continue  # children roll into parents; seed from top-level only
        found.append(os.path.join(dp, "session.jsonl"))
    found.sort()
    evals = []
    for path in found:
        if len(evals) >= maxn:
            break
        stream_id = None
        for rec in load_json_lines(path):
            stream = rec.get("stream") if isinstance(rec, dict) else None
            if isinstance(stream, dict) and stream.get("id"):
                stream_id = stream["id"]
                break
        sid = _session_id(path, stream_id)
        if is_fixture_session(sid):
            continue
        prompt = _first_user_text(path)
        if not prompt:
            continue
        evals.append({"session_id": sid, "harness": HARNESS,
                      "prompt": truncate_text(prompt, 1000)})
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(evals, fh, indent=1)
        fh.write("\n")
    print("mine: %d evals -> %s" % (len(evals), out))


def run_runner(runner, mode, prompt, prompt_file, out_path):
    with open(prompt_file, "w", encoding="utf-8") as fh:
        fh.write(prompt)
    proc = subprocess.run(
        [runner, "--mode", mode, "--skill", SKILL,
         "--prompt-file", prompt_file, "--out", out_path],
        capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        fail("runner %s failed for mode %s: %s" % (
            runner, mode, (proc.stderr or proc.stdout).strip()[-500:]))
    try:
        with open(out_path, encoding="utf-8") as fh:
            traj = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("runner wrote no trajectory JSON for mode %s: %s" % (mode, exc))
    if not isinstance(traj, dict) or not isinstance(
            traj.get("transcript"), str):
        fail("runner trajectory needs a transcript string (mode %s)" % mode)
    return traj


def blind_traj(traj):
    """Strip arm identity; keep behavior the rubric may score."""
    skills = traj.get("skills")
    count = len(skills) if isinstance(skills, list) else 0
    tools = traj.get("tools")
    tools = [str(t) for t in tools] if isinstance(tools, list) else []
    text = traj.get("transcript") or ""
    for token in BANNED_VALUES:
        text = text.replace(token, "[arm]")
    try:
        errors = int(traj.get("errors") or 0)
    except (TypeError, ValueError):
        errors = 0
    try:
        tin = float(traj.get("tokens_in") or 0)
    except (TypeError, ValueError):
        tin = 0.0
    try:
        tout = float(traj.get("tokens_out") or 0)
    except (TypeError, ValueError):
        tout = 0.0
    return {"transcript": text, "tools": tools[:20], "skill_count": count,
            "errors": max(0, errors), "tokens_in": max(0.0, tin),
            "tokens_out": max(0.0, tout)}


def cmd_replay(args):
    import getopt
    try:
        opts, _ = getopt.getopt(args, "", [
            "evals=", "runner=", "skill=", "out=", "seal=", "repeats=",
            "help"])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    evals_path = runner = out = seal = None
    skill = SKILL
    repeats = 1
    for key, val in opts:
        if key == "--evals":
            evals_path = val
        elif key == "--runner":
            runner = val
        elif key == "--skill":
            skill = val
        elif key == "--out":
            out = val
        elif key == "--seal":
            seal = val
        elif key == "--repeats":
            repeats = int(val)
        elif key == "--help":
            print("replay: run each eval with-skill vs stripped; emit blind "
                  "pairs + seal.")
            return
    if skill != SKILL:
        fail("only skill %r is in scope (got %r)" % (SKILL, skill), 2)
    if not evals_path or not runner or not out or not seal:
        fail("replay needs --evals, --runner, --out, and --seal", 2)
    if repeats < 1:
        fail("--repeats must be >= 1", 2)
    with open(evals_path, encoding="utf-8") as fh:
        evals = json.load(fh)
    rng = random.Random()
    tmp = os.path.dirname(os.path.abspath(out)) or "."
    pairs = []
    seal_map = {}
    for idx, item in enumerate(evals):
        prompt = item.get("prompt") or ""
        if not prompt:
            fail("eval %d has no prompt" % idx)
        with_runs, without_runs = [], []
        for rep in range(max(1, repeats)):
            pf = os.path.join(tmp, ".replay-prompt-%d-%d" % (idx, rep))
            for mode, bucket in (("with-skill", with_runs),
                                 ("without-skill", without_runs)):
                op = os.path.join(
                    tmp, ".replay-traj-%d-%d-%s" % (idx, rep, mode))
                traj = run_runner(runner, mode, prompt, pf, op)
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
        label_of = {}
        trajs = {"with": with_runs[0], "without": without_runs[0]}
        pair = {"pair_id": pid, "kind": "cross", "prompt": prompt,
                "session_id": item.get("session_id", "")}
        for pos, arm in zip(("traj_a", "traj_b"), order):
            pair[pos] = trajs[arm]
            label_of[arm] = pos[-1].upper()
        seal_map[pid] = label_of["with"]
        pairs.append(pair)
        for rep in range(1, repeats):
            for arm_no, bucket in enumerate((with_runs, without_runs)):
                apid = "p%d-aa%d" % (idx, len(seal_map))
                aa = [bucket[0], bucket[rep]]
                rng.shuffle(aa)
                pairs.append({"pair_id": apid, "kind": "aa", "prompt": prompt,
                              "session_id": item.get("session_id", ""),
                              "traj_a": aa[0], "traj_b": aa[1]})
                seal_map[apid] = "A"  # same arm both sides; label unused
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(pairs, fh, indent=1)
        fh.write("\n")
    with open(seal, "w", encoding="utf-8") as fh:
        json.dump(seal_map, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print("replay: %d pairs (%d evals, repeats=%d) -> %s" % (
        len(pairs), len(evals), repeats, out))


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
    words = _sig_words(prompt)
    text = (traj.get("transcript") or "").lower()
    coverage = (sum(1 for w in words if w in text) / len(words)) if words else 0.0
    tool_use = 1.0 if traj.get("tools") else 0.0
    discipline = 1.0 if (traj.get("skill_count") or 0) > 0 else 0.0
    error_free = 1.0 if (traj.get("errors") or 0) == 0 else 0.0
    total = (0.50 * coverage + 0.20 * tool_use + 0.15 * discipline
             + 0.15 * error_free)
    return {"goal_coverage": round(coverage, 3), "tool_use": tool_use,
            "skill_use": discipline, "error_free": error_free,
            "total": round(total, 3)}




def main(argv):
    if len(argv) < 2:
        usage()
    cmd, rest = argv[1], argv[2:]
    if cmd == "mine":
        cmd_mine(rest)
    elif cmd == "replay":
        cmd_replay(rest)
    elif cmd in ("judge", "report"):
        fail("%r lives in replay_judge.py (routed by replay-eval.sh)" % cmd,
             2)
    elif cmd in ("-h", "--help", "help"):
        usage(0)
    else:
        fail("unknown subcommand %r" % cmd, 2)


if __name__ == "__main__":
    main(sys.argv)

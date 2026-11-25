#!/usr/bin/env python3
"""Aggregate skills-insights events into CLI tables.

Invoked by scripts/skills-insights.sh, which validates flags first; also
runnable directly (see --help). Inputs arrive as argv, never environment.
"""
import argparse
import datetime
import json
import os
import re
import sys
from collections import Counter, defaultdict

TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")

try:
    from signal import SIG_DFL, SIGPIPE, signal
    signal(SIGPIPE, SIG_DFL)
except (ImportError, OSError, ValueError):
    pass


def _load_text():
    """Load the sibling text renderer (dashed filename needs importlib)."""
    import importlib.util
    sys.dont_write_bytecode = True
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "skills-insights-text.py")
    spec = importlib.util.spec_from_file_location("skills_insights_text", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _args(argv):
    ap = argparse.ArgumentParser(prog="skills-insights.sh")
    ap.add_argument("--log", action="append", default=[])
    ap.add_argument("--since", default="")
    ap.add_argument("--format", default="text")
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--transcript-root", action="append", default=[])
    ap.add_argument("--project", default="")
    ap.add_argument("--no-mine", action="store_true")
    return ap.parse_args(argv)


ARGS = _args(sys.argv[1:])

logs = [p for p in ARGS.log if p]
since = ARGS.since or ""
events = []
for path in logs:
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(ev, dict):
                    continue
                if since and str(ev.get("ts", "")) < since:
                    continue
                events.append(ev)
    except OSError:
        continue

# Test-fixture sessions never describe real work. The hook suites run
# hermetic, but hand-fired probes and live-fire checks have written fixture
# ids into real logs (abcdefghijkl from test-global-claude-hooks.sh, ses9
# from the opencode bridge tests). Real harness ids are UUIDs, so these
# cannot collide; drop them before any aggregation counts them.
FIXTURE_SESSIONS = frozenset({"abcdefghijkl", "ses9"})
fixture_dropped = sum(1 for e in events
                      if str(e.get("session", "")) in FIXTURE_SESSIONS)
if fixture_dropped:
    events = [e for e in events
              if str(e.get("session", "")) not in FIXTURE_SESSIONS]

sessions = {str(e.get("session", "")) for e in events if e.get("session")}
harnesses = sorted({str(e.get("harness", "")) for e in events if e.get("harness")})
tss = sorted(t for t in (str(e.get("ts", "")) for e in events) if TS_RE.match(t))


def _load_aliases():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "templates", "repo-overlay", "eshu-aliases.tsv")
    try:
        with open(path, encoding="utf-8") as fh:
            return {p[0].strip(): p[1].strip() for line in fh
                    if line.strip() and not line.lstrip().startswith("#")
                    for p in [line.split("\t")] if len(p) >= 2 and p[0].strip() and p[1].strip()}
    except OSError:
        return {}


ALIASES = _load_aliases()
_canon = lambda s: ALIASES.get(s, s)


loads = [(str(e.get("session", "")), _canon(str(e["detail"].get("skill", ""))))
         for e in events
         if e.get("type") == "skill-load" and e.get("session")
         and isinstance(e.get("detail"), dict)
         and e["detail"].get("skill")]
blocked = defaultdict(set)
for e in events:
    if e.get("type") == "nudge-block" and isinstance(e.get("detail"), dict):
        for s in e["detail"].get("skills", []) or []:
            if isinstance(s, str) and s:
                blocked[str(e.get("session", ""))].add(_canon(s))
outcomes = {}
for e in events:
    t = e.get("type")
    if t in ("goal-done", "goal-released", "goal-blocked-watcher"):
        outcomes[str(e.get("session", ""))] = t
progress_sessions = {str(e.get("session", "")) for e in events
                     if e.get("type") == "goal-continued"
                     and isinstance(e.get("detail"), dict)
                     and e["detail"].get("progress", 0) not in (0, "0", "")}
goal_sessions = set(outcomes) | {
    str(e.get("session", "")) for e in events
    if e.get("type") == "goal-continued" and e.get("session")
}

by_skill_sessions = defaultdict(set)
for sess, skill in loads:
    by_skill_sessions[skill].add(sess)
load_counts = Counter(skill for _, skill in loads)
forced_counts = Counter()
for sess, skill in loads:
    if skill in blocked.get(sess, set()):
        forced_counts[skill] += 1
done_counts = Counter()
released_counts = Counter()
stalled_counts = Counter()
goal_skill_counts = Counter()
for skill, sessset in by_skill_sessions.items():
    for sess in sessset:
        if sess in goal_sessions:
            goal_skill_counts[skill] += 1
            if outcomes.get(sess) == "goal-done":
                done_counts[skill] += 1
            if outcomes.get(sess) == "goal-released":
                released_counts[skill] += 1
            if sess not in progress_sessions and outcomes.get(sess) != "goal-done":
                stalled_counts[skill] += 1

block_counts = Counter()
for sess, skills in blocked.items():
    for s in skills:
        block_counts[s] += 1
term = Counter(outcomes.values())
failures = Counter()
for e in events:
    if e.get("type") == "model-failure" and isinstance(e.get("detail"), dict):
        failures[str(e["detail"].get("category", "") or "unknown")] += 1
block_event_counts = Counter()
for e in events:
    if e.get("type") == "nudge-block":
        block_event_counts[str(e.get("session", ""))] += 1


try:
    T = _load_text()
except Exception:
    T = None


def _sess_harness(sess):
    return T._sess_harness(sess, events) if T else ""


def _sess_skills(sess):
    return T._sess_skills(sess, loads) if T else []


def _timeline(sess):
    return T._timeline(sess, events) if T else []


def _median(vals):
    vals = sorted(vals)
    if not vals:
        return None
    mid = len(vals) // 2
    if len(vals) % 2:
        return vals[mid]
    return (vals[mid - 1] + vals[mid]) / 2


def _parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _run_miners(argv, timeout=300):
    """Run miners.py; parsed dict or {} on any failure (fail-open)."""
    import subprocess
    miner = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "skills-insights-miners.py")
    if not os.path.isfile(miner):
        return {}
    try:
        out = subprocess.run([sys.executable, miner] + argv,
                             capture_output=True, text=True, timeout=timeout)
    except (OSError, ValueError):
        return {}
    if out.returncode != 0:
        return {}
    try:
        data = json.loads(out.stdout or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _mine_transcripts():
    """Transcript sessions dict; {} when skipped or unreadable."""
    if ARGS.no_mine:
        return {}
    cmd = []
    for root in ARGS.transcript_root:
        if root.strip():
            cmd += ["--root", root.strip()]
    if since:
        cmd += ["--since", since]
    if ARGS.project.strip():
        cmd += ["--project", ARGS.project.strip()]
    return _run_miners(cmd)


def _git_repos_stats(paths, since):
    """One miners call for all repos; unreadable repos come back flagged."""
    cmd = []
    for path in paths:
        if path.strip():
            cmd += ["--git", path.strip()]
    if since:
        cmd += ["--since", since]
    data = _run_miners(cmd, timeout=180)
    repos = data.get("repos")
    if isinstance(repos, list):
        return [r for r in repos if isinstance(r, dict)]
    return []


def _sess_turns(sess):
    turns = {}
    for e in sorted((x for x in events if str(x.get("session", "")) == sess),
                    key=lambda x: str(x.get("ts", ""))):
        if e.get("type") != "goal-continued":
            continue
        d = e.get("detail") if isinstance(e.get("detail"), dict) else {}
        key = str(d.get("turn", "") or "unknown")
        row = turns.setdefault(key, {"turn": key, "progress": 0, "stops": 0})
        row["stops"] += 1
        try:
            row["progress"] += int(d.get("progress", 0))
        except (TypeError, ValueError):
            pass
    return [turns[k] for k in sorted(turns)]


mined = _mine_transcripts()
mined_sessions = mined.get("sessions", []) if isinstance(mined, dict) else []
if not events and not mined_sessions:
    print("skills-insights: no events yet (logs: " + ", ".join(logs) + ")")
    print("Load a skill in a session with the kit hooks installed, then re-run.")
    raise SystemExit(0)
mined_by_prefix = {}
for ms in mined_sessions:
    mid = str(ms.get("id", ""))
    if mid:
        mined_by_prefix.setdefault(mid[:12], ms)
        mined_by_prefix.setdefault(mid, ms)
repos = _git_repos_stats([r for r in ARGS.repo], since) if any(
    r.strip() for r in ARGS.repo) else []

def _mined_ts_date(val):
    if isinstance(val, str) and TS_RE.match(val):
        return val[:10]
    if isinstance(val, int) and val > 0:
        try:
            return datetime.datetime.fromtimestamp(
                val / 1_000_000, tz=datetime.timezone.utc).isoformat()[:10]
        except (OSError, OverflowError, ValueError):
            return None
    return None


mined_tools = Counter()
mined_errors = Counter()
mined_projects = Counter()
mined_harnesses = Counter()
mined_skill_loads = Counter()
mined_sub_roles = Counter()
mined_sub_models = Counter()
mined_session_models = Counter()
mined_prompts = 0
mined_calls = 0
mined_subagents = 0
mined_max_depth = 0
mined_child_sessions = 0
gap_seconds = []
mined_dates = []
for ms in mined_sessions:
    if ms.get("harness"):
        mined_harnesses[str(ms["harness"])] += 1
    for tk in ("first_ts", "last_ts"):
        d_str = _mined_ts_date(ms.get(tk))
        if d_str:
            mined_dates.append(d_str)
    mined_prompts += ms.get("prompts", 0) or 0
    for sk in ms.get("skill_loads") or []:
        if isinstance(sk, str) and sk:
            mined_skill_loads[_canon(sk)] += 1
    mined_subagents += ms.get("subagents", 0) or 0
    for role, c in (ms.get("subagent_roles") or {}).items():
        mined_sub_roles[str(role)] += c
    for key, counter in (("subagent_models", mined_sub_models),
                         ("session_models", mined_session_models)):
        for model, c in (ms.get(key) or {}).items():
            counter[str(model)] += c
    try:
        depth = int(ms.get("max_depth", 0) or 0)
    except (TypeError, ValueError):
        depth = 0
    if depth > mined_max_depth:
        mined_max_depth = depth
    if ms.get("parent_session"):
        mined_child_sessions += 1
    for tool, c in (ms.get("tools") or {}).items():
        mined_tools[str(tool)] += c
        mined_calls += c
    for tool, c in (ms.get("errors") or {}).items():
        mined_errors[str(tool)] += c
    mined_projects[str(ms.get("project") or "unknown")] += 1
    for pair in ms.get("response_gaps") or []:
        if isinstance(pair, list) and len(pair) == 2:
            a, b = _parse_ts(pair[0]), _parse_ts(pair[1])
            if a and b and b >= a:
                gap_seconds.append((b - a).total_seconds())
median_gap = _median(gap_seconds)

joined_mined_ids = {str((mined_by_prefix.get(s) or {}).get("id", ""))
                    for s in sorted(sessions)} - {""}


harnesses = sorted(set(harnesses) | set(mined_harnesses))
if not tss and mined_dates:
    tss = sorted(mined_dates)


def _mined_summary(ms):
    tools = ms.get("tools") or {}
    return {"session": str(ms.get("id", "")),
            "harness": str(ms.get("harness", "")),
            "project": str(ms.get("project") or ""),
            "prompts": ms.get("prompts", 0) or 0,
            "tool_calls": sum(tools.values()),
            "skill_loads": list(ms.get("skill_loads") or []),
            "errors": dict(ms.get("errors") or {})}


unjoined = [_mined_summary(ms) for ms in mined_sessions
            if str(ms.get("id", "")) not in joined_mined_ids]

# Unloaded work: progress the hooks saw with no skill loaded, plus mined
# sessions whose transcripts show prompts but no consulted skill. Counts
# only — whether a missing skill explains any of it is a debrief judgment
# over sampled transcripts, never a claim this aggregate makes.
loaded_sessions = {sess for sess, _ in loads}
unloaded_hook = sorted(s for s in progress_sessions if s not in loaded_sessions)
unloaded_mined = [ms for ms in mined_sessions
                  if (ms.get("prompts") or 0) > 0 and not (ms.get("skill_loads") or [])]

data = {
    "meta": {
        "events": len(events),
        "sessions": len(sessions),
        "from": tss[0][:10] if tss else None,
        "to": tss[-1][:10] if tss else None,
        "harnesses": harnesses,
        "project": ARGS.project.strip() or None,
        "mined_sessions": len(mined_sessions),
        "mined_prompts": mined_prompts,
        "mined_tool_calls": mined_calls,
        "median_response_gap_s": median_gap,
        "repos": repos,
    },
    "skills": [
        {"skill": skill,
         "loads": load_counts[skill],
         "forced": forced_counts.get(skill, 0),
         "sessions": len(by_skill_sessions[skill]),
         "goal_sessions": goal_skill_counts.get(skill, 0),
         "done_with": done_counts.get(skill, 0),
         "released_with": released_counts.get(skill, 0),
         "no_progress_share_pct": (
             100 * stalled_counts.get(skill, 0) // goal_skill_counts[skill]
             if goal_skill_counts.get(skill, 0) else None)}
        for skill in sorted(by_skill_sessions, key=lambda s: (-load_counts[s], s))
    ],
    "sessions": [
        {"session": sess,
         "harness": _sess_harness(sess) or (mined_by_prefix.get(sess) or {}).get("harness", ""),
         "outcome": outcomes.get(sess),
         "skills": _sess_skills(sess),
         "turns": _sess_turns(sess),
         "activity": ({k: (mined_by_prefix.get(sess) or {}).get(k)
                       for k in ("prompts", "tools", "errors")}
                      if sess in mined_by_prefix else None),
         "timeline": _timeline(sess)}
        for sess in sorted(sessions)
    ],
    "friction": {
        "nudge_blocked": {s: c for s, c in block_counts.most_common(10)},
        "model_failures": dict(failures),
        "repeat_blocked_sessions": sorted(
            s for s, c in block_event_counts.items() if c >= 3),
    },
    "unloaded": {
        "sessions": unloaded_hook,
        "mined_sessions": len(unloaded_mined),
        "mined_prompts": sum(ms.get("prompts", 0) or 0 for ms in unloaded_mined),
        "mined_joined": sum(1 for ms in unloaded_mined
                            if str(ms.get("id", "")) in joined_mined_ids),
    },
    "mined": {
        "sessions": len(mined_sessions),
        "harnesses": dict(mined_harnesses),
        "prompts": mined_prompts,
        "tool_calls": mined_calls,
        "tools": dict(mined_tools.most_common(15)),
        "errors": dict(mined_errors.most_common(15)),
        "projects": dict(mined_projects.most_common(15)),
        "skill_loads": dict(mined_skill_loads.most_common(25)),
        "subagents": mined_subagents,
        "subagent_roles": dict(mined_sub_roles.most_common(15)),
        "subagent_models": dict(mined_sub_models.most_common(15)),
        "session_models": dict(mined_session_models.most_common(15)),
        "max_depth": mined_max_depth,
        "child_sessions": mined_child_sessions,
        "median_response_gap_s": median_gap,
        "response_gaps_n": len(gap_seconds),
        "byte_capped": bool(mined.get("byte_capped")),
        "skipped_old": mined.get("skipped_old", 0),
        "unjoined_sessions": unjoined,
    },
    "notes": [
        "Correlation only, never causation: do not rank people or harnesses on this.",
        "no-progress share is computed over goal sessions only (null when none ran): "
        "the skill coincided with goal sessions that never progressed — it may be unrelated to the stall.",
        "Hook skill-load events exist on Claude+Muse only (agy skill loads are "
        "mined from transcripts; Codex/OpenCode are labeled exclusions, never ranked).",
    ] + (["%d test-fixture event(s) excluded (hook-probe session ids, "
          "never real work)." % fixture_dropped] if fixture_dropped else []
    ) + (["--project scopes transcript mining only: the skill table, "
           "outcomes, and session list stay global (event logs carry no "
           "repo signal)."] if ARGS.project.strip() else []),
}

if ARGS.format == "json":
    print(json.dumps(data, indent=1, sort_keys=True))
    raise SystemExit(0)

if T is None:
    print("skills-insights: text renderer unavailable — degraded skill "
          "summary only (--format json still works)")
    for row in data["skills"][:15]:
        np = "n/a" if row["no_progress_share_pct"] is None else "%d%%" % row["no_progress_share_pct"]
        print("- %s: %d %s (%d forced), done-with %d, released-with %d, "
              "no-progress share %s" % (
                  row["skill"], row["loads"],
                  "load" if row["loads"] == 1 else "loads", row["forced"],
                  row["done_with"], row["released_with"], np))
    raise SystemExit(0)
T.render_text(data, {
    "events": events, "sessions": sessions, "loads": loads,
    "outcomes": outcomes, "progress_sessions": progress_sessions,
    "goal_sessions": goal_sessions, "block_counts": block_counts,
    "failures": failures,
})
raise SystemExit(0)

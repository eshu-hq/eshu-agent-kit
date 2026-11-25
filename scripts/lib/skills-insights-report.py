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


def _args(argv):
    ap = argparse.ArgumentParser(prog="skills-insights.sh")
    ap.add_argument("--log", action="append", default=[])
    ap.add_argument("--since", default="")
    ap.add_argument("--format", default="text")
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--transcript-root", action="append", default=[])
    ap.add_argument("--no-mine", action="store_true")
    return ap.parse_args(argv)


ARGS = _args(sys.argv[1:])
MINERS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "skills-insights-miners.py")

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

if not events:
    print("skills-insights: no events yet (logs: " + ", ".join(logs) + ")")
    print("Load a skill in a session with the kit hooks installed, then re-run.")
    raise SystemExit(0)

sessions = {str(e.get("session", "")) for e in events if e.get("session")}
harnesses = sorted({str(e.get("harness", "")) for e in events if e.get("harness")})
tss = sorted(t for t in (str(e.get("ts", "")) for e in events) if TS_RE.match(t))


def _n(n, singular):
    return "%d %s%s" % (n, singular, "" if n == 1 else "s")

loads = [(str(e.get("session", "")), str(e["detail"].get("skill", "")))
         for e in events
         if e.get("type") == "skill-load" and e.get("session")
         and isinstance(e.get("detail"), dict)
         and e["detail"].get("skill")]
blocked = defaultdict(set)
for e in events:
    if e.get("type") == "nudge-block" and isinstance(e.get("detail"), dict):
        for s in e["detail"].get("skills", []) or []:
            if isinstance(s, str) and s:
                blocked[str(e.get("session", ""))].add(s)
outcomes = {}
for e in events:
    t = e.get("type")
    if t in ("goal-done", "goal-released", "goal-blocked-watcher"):
        outcomes[str(e.get("session", ""))] = t
progress_sessions = {str(e.get("session", "")) for e in events
                     if e.get("type") == "goal-continued"
                     and isinstance(e.get("detail"), dict)
                     and e["detail"].get("progress", 0) not in (0, "0", "")}

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
for skill, sessset in by_skill_sessions.items():
    for sess in sessset:
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


def _timeline(sess):
    rows = []
    for e in sorted((x for x in events if str(x.get("session", "")) == sess),
                    key=lambda x: str(x.get("ts", ""))):
        t = e.get("type")
        d = e.get("detail") if isinstance(e.get("detail"), dict) else {}
        if t == "skill-load" and d.get("skill"):
            rows.append("did:load+" + str(d["skill"]))
        elif t == "nudge-block":
            rows.append("broke:blocked-need+" + ",".join(
                sorted(str(s) for s in (d.get("skills") or []) if s)))
        elif t == "goal-continued":
            rows.append("did:progress=%s" % d.get("progress", 0))
        elif t == "model-failure":
            rows.append("broke:model-failure(%s)" % (d.get("category") or "unknown"))
        elif t == "goal-done":
            rows.append("solved:done")
        elif t in ("goal-released", "goal-blocked-watcher"):
            rows.append("end:" + t.replace("goal-", ""))
    return rows


def _sess_harness(sess):
    hs = Counter(str(x.get("harness", "")) for x in events
                 if str(x.get("session", "")) == sess and x.get("harness"))
    return hs.most_common(1)[0][0] if hs else ""


def _sess_skills(sess):
    return sorted({skill for s, skill in loads if s == sess})


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


def _mine_transcripts():
    """Run the miners lib; returns its dict or {} on any failure."""
    import subprocess
    if ARGS.no_mine:
        return {}
    miner = MINERS
    if not os.path.isfile(miner):
        return {}
    cmd = [sys.executable, miner]
    for root in ARGS.transcript_root:
        if root.strip():
            cmd += ["--root", root.strip()]
    if since:
        cmd += ["--since", since]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except (OSError, ValueError):
        return {}
    if out.returncode != 0:
        return {}
    try:
        data = json.loads(out.stdout or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _git_repo_stats(path, since):
    """Deterministic git history rollup; {} when not a repo or git fails."""
    import subprocess
    if not os.path.isdir(os.path.join(path, ".git")):
        return {}
    window = since or ""
    if not window:
        try:
            import datetime as _dt
            window = (_dt.date.today() - _dt.timedelta(days=90)).isoformat()
        except ValueError:
            window = ""
    cmd = ["git", "-C", path, "log", "--pretty=%H %P %s", "--numstat"]
    if window:
        cmd += ["--since=" + window]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, ValueError):
        return {}
    if out.returncode != 0:
        return {}
    commits = merges = reverts = files = added = deleted = 0
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].strip().isdigit():
            try:
                added += int(parts[0].strip())
            except ValueError:
                pass
            try:
                deleted += int(parts[1].strip())
            except ValueError:
                pass
            files += 1
        elif line and not line[0].isspace():
            m = re.match(r"^[0-9a-f]{40}((?: [0-9a-f]{40})*) (.*)$", line)
            if not m:
                continue
            commits += 1
            if len(m.group(1).split()) >= 2:
                merges += 1
            if m.group(2).lower().startswith("revert"):
                reverts += 1
    return {"path": path, "commits": commits, "merges": merges,
            "reverts": reverts, "files": files,
            "added": added, "deleted": deleted}


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
mined_by_prefix = {}
for ms in mined_sessions:
    mid = str(ms.get("id", ""))
    if mid:
        mined_by_prefix.setdefault(mid[:12], ms)
        mined_by_prefix.setdefault(mid, ms)
repos = []
for repo in ARGS.repo:
    repo = repo.strip()
    if not repo:
        continue
    stats = _git_repo_stats(repo, since)
    repos.append(stats if stats else {"path": repo, "unreadable": True})

mined_tools = Counter()
mined_errors = Counter()
mined_prompts = 0
mined_calls = 0
gap_seconds = []
for ms in mined_sessions:
    mined_prompts += ms.get("prompts", 0) or 0
    for tool, c in (ms.get("tools") or {}).items():
        mined_tools[str(tool)] += c
        mined_calls += c
    for tool, c in (ms.get("errors") or {}).items():
        mined_errors[str(tool)] += c
    for pair in ms.get("response_gaps") or []:
        if isinstance(pair, list) and len(pair) == 2:
            a, b = _parse_ts(pair[0]), _parse_ts(pair[1])
            if a and b and b >= a:
                gap_seconds.append((b - a).total_seconds())
median_gap = _median(gap_seconds)

joined_mined_ids = set()


for sess in sorted(sessions):
    ms = mined_by_prefix.get(sess)
    if ms:
        ms["_joined"] = True
        joined_mined_ids.add(str(ms.get("id", "")))


def _mined_summary(ms):
    tools = ms.get("tools") or {}
    return {"session": str(ms.get("id", "")),
            "harness": str(ms.get("harness", "")),
            "prompts": ms.get("prompts", 0) or 0,
            "tool_calls": sum(tools.values()),
            "errors": dict(ms.get("errors") or {})}


unjoined = [_mined_summary(ms) for ms in mined_sessions
            if str(ms.get("id", "")) not in joined_mined_ids]

data = {
    "meta": {
        "events": len(events),
        "sessions": len(sessions),
        "from": tss[0][:10] if tss else None,
        "to": tss[-1][:10] if tss else None,
        "harnesses": harnesses,
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
         "done_with": done_counts.get(skill, 0),
         "released_with": released_counts.get(skill, 0),
         "no_progress_share_pct": (100 * stalled_counts.get(skill, 0)
                                   // len(by_skill_sessions[skill]))}
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
    "mined": {
        "sessions": len(mined_sessions),
        "prompts": mined_prompts,
        "tool_calls": mined_calls,
        "tools": dict(mined_tools.most_common(15)),
        "errors": dict(mined_errors.most_common(15)),
        "median_response_gap_s": median_gap,
        "response_gaps_n": len(gap_seconds),
        "byte_capped": bool(mined.get("byte_capped")),
        "skipped_old": mined.get("skipped_old", 0),
        "unjoined_sessions": unjoined,
    },
    "notes": [
        "Correlation only, never causation: do not rank people or harnesses on this.",
        "no-progress share is an approximation: the skill coincided with "
        "sessions that never progressed — it may be unrelated to the stall.",
        "Skill-load events exist on Claude+Muse only; Codex/OpenCode are "
        "labeled exclusions, never ranked.",
    ],
}

if ARGS.format == "json":
    print(json.dumps(data, indent=1, sort_keys=True))
    raise SystemExit(0)

print("skills-insights: %s, %s, %s to %s" % (
    _n(len(events), "event"), _n(len(sessions), "session"),
    tss[0][:10] if tss else "?", tss[-1][:10] if tss else "?"))
print("harnesses observed: %s" % (", ".join(harnesses) or "?"))
print("skill-load events exist on Claude+Muse only; Codex/OpenCode are")
print("labeled exclusions, never ranked.")
print()
print("skill | loads | forced | sessions | done-with | released-with | no-progress-session share")
for row in data["skills"]:
    print("%s | %s | %d (%d%%) | %s | %d | %d | %d%%" % (
        row["skill"], _n(row["loads"], "load"),
        row["forced"], (100 * row["forced"] // row["loads"]),
        _n(row["sessions"], "session"), row["done_with"], row["released_with"],
        row["no_progress_share_pct"]))
print()
print("no-progress-session share is an approximation: the skill coincided")
print("with sessions that never progressed — it may be unrelated to the stall.")
print()
if block_counts:
    print("nudge-blocked skills (forced-load demand):")
    for s, c in block_counts.most_common(10):
        print("  %s: %s blocked" % (s, _n(c, "session")))
    print()
if failures:
    print("model failures by category:")
    for cat, c in failures.most_common(10):
        print("  %s: %s" % (cat, _n(c, "session")))
    print()
print("session outcomes: " + (", ".join(
    "%s=%d" % (k, term[k]) for k in ("goal-done", "goal-released", "goal-blocked-watcher") if term[k]
) or "none recorded"))
print()
if mined_sessions:
    print("session activity (transcript mining, counts only — never message text):")
    print("  %s across %s" % (_n(len(mined_sessions), "mined session"),
                              _n(mined_prompts, "prompt")))
    top_tools = mined_tools.most_common(8)
    if top_tools:
        print("  top tools: " + ", ".join(
            "%s %d" % (t, c) for t, c in top_tools))
    if mined_errors:
        print("  tool errors: " + ", ".join(
            "%s %d" % (t, c) for t, c in mined_errors.most_common(8)))
    if median_gap is not None:
        print("  median response gap: %ds over %s (Claude sessions only)" % (
            int(median_gap), _n(len(gap_seconds), "gap")))
    else:
        print("  response gaps: unobserved (needs Claude assistant→user pairs)")
    if mined.get("byte_capped"):
        print("  WARNING: transcript byte cap hit — activity is partial")
    print()
if repos:
    print("git history (--repo):")
    for r in repos:
        if r.get("unreadable"):
            print("  %s: unreadable (not a repo?)" % r.get("path"))
        else:
            print("  %s: %s, %s, %s, %s, +%d/-%d" % (
                r.get("path"), _n(r.get("commits", 0), "commit"),
                _n(r.get("merges", 0), "merge"), _n(r.get("reverts", 0), "revert"),
                _n(r.get("files", 0), "file"), r.get("added", 0), r.get("deleted", 0)))
    print()
stalled = [s for s in sorted(sessions)
           if outcomes.get(s) == "goal-released"
           or (s not in progress_sessions and outcomes.get(s) != "goal-done"
               and any(ss == s for ss, _ in loads))]
if stalled:
    print("friction — stalled sessions (did → broke, never solved):")
    for s in stalled[:10]:
        tl = _timeline(s)
        print("  %s [%s]: %s" % (s, outcomes.get(s) or "open",
                                 " → ".join(tl) if tl else "no events"))
    if len(stalled) > 10:
        print("  ...and %d more" % (len(stalled) - 10))
    print()
wins = [s for s in sorted(sessions) if outcomes.get(s) == "goal-done"]
if wins:
    print("wins — sessions that reached DONE:")
    for s in wins[:10]:
        sk = _sess_skills(s)
        print("  %s: %s" % (s, ", ".join(sk) if sk else "no skills logged"))
    if len(wins) > 10:
        print("  ...and %d more" % (len(wins) - 10))
    print()
print("--- paste into chat for the fix-list synthesis ---")
for row in data["skills"][:15]:
    print("- %s: %s (%d forced), done-with %d, released-with %d, no-progress share %d%%" % (
        row["skill"], _n(row["loads"], "load"), row["forced"],
        row["done_with"], row["released_with"], row["no_progress_share_pct"]))
print("Correlation only, never causation: do not rank people or harnesses on this.")
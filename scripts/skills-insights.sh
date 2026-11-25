#!/usr/bin/env bash
# skills-insights.sh — report skill-use telemetry for improving how we work.
#
# Reads the JSONL event logs written by hooks/lib/skills-insights-events.sh
# (skill loads, nudge blocks, goal outcomes) and prints per-skill tables:
# loads, forced-vs-voluntary split, no-progress-session share, and outcome
# correlation — plus friction hotspots and a paste-ready summary for chat
# synthesis. Deterministic, no model calls, no network.
#
# Usage: bash scripts/skills-insights.sh [--log PATH]... [--since YYYY-MM-DD]
#   [--format text|json]
#   Defaults to $XDG_DATA_HOME/eshu-agent-kit/skills-usage.jsonl.
#   Skill-load events exist on Claude+Muse only (no Codex/OpenCode load
#   signal); those harnesses are labeled exclusions, never ranked.
#   --format json emits the machine-readable aggregate (sessions with ordered
#   did → broke → solved timelines) for the debrief synthesis step.
#
# Attribution ceiling, stated in the output too: aggregates show correlation
# ("sessions loading X merge cleaner"), never causation. Do not build a
# leaderboard on this.
set -uo pipefail

LOGS=()
SINCE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--log)
		[ $# -ge 2 ] || {
			echo "skills-insights: --log needs a path" >&2
			exit 1
		}
		LOGS+=("$2")
		shift 2
		;;
	--since)
		[ $# -ge 2 ] || {
			echo "skills-insights: --since needs YYYY-MM-DD" >&2
			exit 1
		}
		SINCE="$2"
		shift 2
		;;
	--format)
		[ $# -ge 2 ] || {
			echo "skills-insights: --format needs text or json" >&2
			exit 1
		}
		FORMAT="$2"
		shift 2
		;;
	--help | -h)
		sed -n '2,14p' "$0"
		exit 0
		;;
	*)
		echo "skills-insights: unknown argument: $1" >&2
		exit 1
		;;
	esac
done
if [ "${#LOGS[@]}" -eq 0 ]; then
	LOGS=("${XDG_DATA_HOME:-${HOME:-}/.local/share}/eshu-agent-kit/skills-usage.jsonl")
fi
FORMAT="${FORMAT:-text}"
if [ "${FORMAT}" != "text" ] && [ "${FORMAT}" != "json" ]; then
	echo "skills-insights: --format needs text or json" >&2
	exit 1
fi

command -v python3 >/dev/null 2>&1 || {
	echo "skills-insights: python3 required" >&2
	exit 1
}

SI_LOGS="$(printf '%s\n' "${LOGS[@]}")" SI_SINCE="${SINCE}" SI_FORMAT="${FORMAT}" python3 - <<'EOF'
"""Aggregate skills-insights events into CLI tables."""
import json
import os
import re
import sys
from collections import Counter, defaultdict

TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")

logs = [p for p in (os.environ.get("SI_LOGS") or "").splitlines() if p]
since = os.environ.get("SI_SINCE") or ""
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


data = {
    "meta": {
        "events": len(events),
        "sessions": len(sessions),
        "from": tss[0][:10] if tss else None,
        "to": tss[-1][:10] if tss else None,
        "harnesses": harnesses,
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
         "harness": _sess_harness(sess),
         "outcome": outcomes.get(sess),
         "skills": _sess_skills(sess),
         "turns": _sess_turns(sess),
         "timeline": _timeline(sess)}
        for sess in sorted(sessions)
    ],
    "friction": {
        "nudge_blocked": {s: c for s, c in block_counts.most_common(10)},
        "model_failures": dict(failures),
        "repeat_blocked_sessions": sorted(
            s for s, c in block_event_counts.items() if c >= 3),
    },
    "notes": [
        "Correlation only, never causation: do not rank people or harnesses on this.",
        "no-progress share is an approximation: the skill coincided with "
        "sessions that never progressed — it may be unrelated to the stall.",
        "Skill-load events exist on Claude+Muse only; Codex/OpenCode are "
        "labeled exclusions, never ranked.",
    ],
}

if (os.environ.get("SI_FORMAT") or "text") == "json":
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
EOF

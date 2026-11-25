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
#   Defaults to $XDG_DATA_HOME/eshu-agent-kit/skills-usage.jsonl.
#   Skill-load events exist on Claude+Muse only (no Codex/OpenCode load
#   signal); those harnesses are labeled exclusions, never ranked.
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
	--help | -h)
		sed -n '2,12p' "$0"
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

command -v python3 >/dev/null 2>&1 || {
	echo "skills-insights: python3 required" >&2
	exit 1
}

SI_LOGS="$(printf '%s\n' "${LOGS[@]}")" SI_SINCE="${SINCE}" python3 - <<'EOF'
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

print("skills-insights: %s, %s, %s to %s" % (
    _n(len(events), "event"), _n(len(sessions), "session"),
    tss[0][:10] if tss else "?", tss[-1][:10] if tss else "?"))
print("harnesses observed: %s" % (", ".join(harnesses) or "?"))
print("skill-load events exist on Claude+Muse only; Codex/OpenCode are")
print("labeled exclusions, never ranked.")
print()
print("skill | loads | forced | sessions | done-with | released-with | no-progress-session share")
for skill in sorted(by_skill_sessions, key=lambda s: (-load_counts[s], s)):
    n = len(by_skill_sessions[skill])
    f = forced_counts.get(skill, 0)
    d = done_counts.get(skill, 0)
    r = released_counts.get(skill, 0)
    st = stalled_counts.get(skill, 0)
    print("%s | %s | %d (%d%%) | %s | %d | %d | %d%%" % (
        skill, _n(load_counts[skill], "load"), f, (100 * f // load_counts[skill]),
        _n(n, "session"), d, r, (100 * st // n) if n else 0))
print()
print("no-progress-session share is an approximation: the skill coincided")
print("with sessions that never progressed — it may be unrelated to the stall.")
print()
block_counts = Counter()
for sess, skills in blocked.items():
    for s in skills:
        block_counts[s] += 1
if block_counts:
    print("nudge-blocked skills (forced-load demand):")
    for s, c in block_counts.most_common(10):
        print("  %s: %s blocked" % (s, _n(c, "session")))
    print()
term = Counter(outcomes.values())
print("session outcomes: " + (", ".join(
    "%s=%d" % (k, term[k]) for k in ("goal-done", "goal-released", "goal-blocked-watcher") if term[k]
) or "none recorded"))
print()
print("--- paste into chat for the fix-list synthesis ---")
for skill in sorted(by_skill_sessions, key=lambda s: (-load_counts[s], s))[:15]:
    n = len(by_skill_sessions[skill])
    print("- %s: %s (%d forced), done-with %d, released-with %d, no-progress share %d%%" % (
        skill, _n(load_counts[skill], "load"), forced_counts.get(skill, 0),
        done_counts.get(skill, 0), released_counts.get(skill, 0),
        (100 * stalled_counts.get(skill, 0) // n) if n else 0))
print("Correlation only, never causation: do not rank people or harnesses on this.")
EOF

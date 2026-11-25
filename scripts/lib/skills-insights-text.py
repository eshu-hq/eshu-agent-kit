#!/usr/bin/env python3
"""Human-readable rendering for the skills-insights report.

Pure functions of the aggregate `data` dict plus a small context dict;
no file or subprocess access, so the text shape can evolve without
touching aggregation. Imported by skills-insights-report.py via importlib
(dashed filename is not directly importable).
"""
from collections import Counter


def _n(n, singular):
    return "%d %s%s" % (n, singular, "" if n == 1 else "s")


def _pct(val):
    return "n/a" if val is None else "%d%%" % val


def _timeline(sess, events):
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


def _sess_harness(sess, events):
    hs = Counter(str(x.get("harness", "")) for x in events
                 if str(x.get("session", "")) == sess and x.get("harness"))
    return hs.most_common(1)[0][0] if hs else ""


def _sess_skills(sess, loads):
    return sorted({skill for s, skill in loads if s == sess})


def render_text(data, ctx):
    """Print the text report. ctx carries events, sessions, loads,
    outcomes, progress_sessions, block_counts, failures."""
    events = ctx["events"]
    sessions = ctx["sessions"]
    loads = ctx["loads"]
    outcomes = ctx["outcomes"]
    progress_sessions = ctx["progress_sessions"]
    block_counts = ctx["block_counts"]
    failures = ctx["failures"]
    term = Counter(outcomes.values())
    mined = data["mined"]
    tss = [data["meta"]["from"] or "?", data["meta"]["to"] or "?"]

    print("skills-insights: %s, %s, %s to %s" % (
        _n(data["meta"]["events"], "event"), _n(data["meta"]["sessions"], "session"),
        tss[0], tss[1]))
    print("harnesses observed: %s" % (", ".join(data["meta"]["harnesses"]) or "?"))
    if data["meta"].get("project"):
        print("transcript scope: %s (skill table and outcomes stay global)" % data["meta"]["project"])
    print("hook skill-load events exist on Claude+Muse only (agy skill loads are")
    print("mined from transcripts; Codex/OpenCode are labeled exclusions, never ranked).")
    print()
    print("skill | loads | forced | sessions | done-with | released-with | no-progress-session share")
    for row in data["skills"]:
        print("%s | %s | %d (%d%%) | %s | %d | %d | %s" % (
            row["skill"], _n(row["loads"], "load"),
            row["forced"], (100 * row["forced"] // row["loads"]),
            _n(row["sessions"], "session"), row["done_with"], row["released_with"],
            _pct(row["no_progress_share_pct"])))
    print()
    print("no-progress-session share is computed over goal sessions only (n/a when")
    print("none ran) — the skill coincided with goal sessions that never progressed.")
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
    unloaded = data.get("unloaded") or {}
    if (unloaded.get("sessions") or unloaded.get("mined_sessions")):
        print("unloaded work (progress with no skill loaded — gap-mining")
        print("candidates, not findings):")
        if unloaded.get("sessions"):
            print("  hook sessions: %s" % ", ".join(unloaded["sessions"][:10]))
        if unloaded.get("mined_sessions"):
            print("  mined sessions: %s across %s (transcripts show work, "
                  "no skill consulted)" % (
                      _n(unloaded["mined_sessions"], "session"),
                      _n(unloaded.get("mined_prompts", 0), "prompt")))
        print()
    if mined["sessions"]:
        print("session activity (transcript mining, counts only — never message text):")
        h_part = ""
        if mined.get("harnesses"):
            h_part = " (" + ", ".join(
                "%s %d" % (h, c) for h, c in sorted(mined["harnesses"].items())) + ")"
        print("  %s%s across %s" % (_n(mined["sessions"], "mined session"),
                                    h_part, _n(mined["prompts"], "prompt")))
        top_tools = Counter(mined["tools"]).most_common(8)
        if top_tools:
            print("  top tools: " + ", ".join(
                "%s %d" % (t, c) for t, c in top_tools))
        if mined["errors"]:
            print("  tool errors: " + ", ".join(
                "%s %d" % (t, c) for t, c in Counter(mined["errors"]).most_common(8)))
        if mined.get("projects"):
            print("  projects: " + ", ".join(
                "%s %d" % (p, c) for p, c in Counter(mined["projects"]).most_common(8)))
        if mined["median_response_gap_s"] is not None:
            print("  median response gap: %ds over %s (Claude/agy sessions)" % (
                int(mined["median_response_gap_s"]), _n(mined["response_gaps_n"], "gap")))
        else:
            print("  response gaps: unobserved (needs Claude or agy assistant→user pairs)")
        if mined["byte_capped"]:
            print("  WARNING: transcript byte cap hit — activity is partial")
        if mined["skill_loads"]:
            print("  transcript skill loads (backfill: every load the transcripts "
                  "show, including sessions predating telemetry):")
            for sk, c in Counter(mined["skill_loads"]).most_common(15):
                print("  %s: %s" % (sk, _n(c, "load")))
        if mined["tools"].get("read_skill"):
            print("  read_skill calls (Muse): %d total — named loads are counted "
                  "above" % mined["tools"]["read_skill"])
        if mined["subagents"]:
            print("  subagents spawned: %d across %s (%s child sessions logged separately)" % (
                mined["subagents"], _n(mined["sessions"], "mined session"), mined["child_sessions"]))
            if mined["subagent_roles"]:
                print("  roles: " + ", ".join(
                    "%s %d" % (r, c) for r, c in Counter(mined["subagent_roles"]).most_common(8)))
            if mined["subagent_models"]:
                print("  models: " + ", ".join(
                    "%s %d" % (m, c) for m, c in Counter(mined["subagent_models"]).most_common(8)))
            if mined["session_models"]:
                print("  session models (harness-level, not per-subagent): " + ", ".join(
                    "%s %d" % (m, c) for m, c in Counter(mined["session_models"]).most_common(8)))
            if mined["max_depth"]:
                print("  deepest delegation chain: %d" % mined["max_depth"])
        print()
    repos = data["meta"]["repos"]
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
    goal_sessions = ctx.get("goal_sessions", set(outcomes) | progress_sessions)
    stalled = [s for s in sorted(sessions)
               if outcomes.get(s) == "goal-released"
               or (s in goal_sessions and s not in progress_sessions
                   and outcomes.get(s) != "goal-done"
                   and any(ss == s for ss, _ in loads))]
    if stalled:
        print("friction — stalled sessions (did → broke, never solved):")
        for s in stalled[:10]:
            tl = _timeline(s, events)
            print("  %s [%s]: %s" % (s, outcomes.get(s) or "open",
                                     " → ".join(tl) if tl else "no events"))
        if len(stalled) > 10:
            print("  ...and %d more" % (len(stalled) - 10))
        print()
    wins = [s for s in sorted(sessions) if outcomes.get(s) == "goal-done"]
    if wins:
        print("wins — sessions that reached DONE:")
        for s in wins[:10]:
            sk = _sess_skills(s, loads)
            print("  %s: %s" % (s, ", ".join(sk) if sk else "no skills logged"))
        if len(wins) > 10:
            print("  ...and %d more" % (len(wins) - 10))
        print()
    print("--- paste into chat for the fix-list synthesis ---")
    for row in data["skills"][:15]:
        print("- %s: %s (%d forced), done-with %d, released-with %d, no-progress share %s" % (
            row["skill"], _n(row["loads"], "load"), row["forced"],
            row["done_with"], row["released_with"], _pct(row["no_progress_share_pct"])))
    print("Correlation only, never causation: do not rank people or harnesses on this.")

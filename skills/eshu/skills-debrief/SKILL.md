---
name: skills-debrief
description: "Use when asked for a skills debrief, /debrief, a usage-insights-style report, or what skill usage says about how we work. Reads scripts/skills-insights.sh --format json plus transcript evidence and writes a single self-contained HTML debrief: wins, friction with examples, actionable fixes, horizon ideas."
---

# Skills Debrief

Write the kit equivalent of a usage-insights report from debrief data. The
deterministic aggregates already exist — your job is the narrative a counter
cannot write: what got solved, what broke, what it means, what changes.

Scope: this is the `eshu` layer of the kit. Skill names, goal mechanics, and
hook events resolve per `skills/registry.md`. Relative `docs/` paths resolve
in the consuming repo checkout.

Non-kit projects: when the aggregate carries no kit signals (no skill
events, no nudge blocks, no goal turns), do not force kit language.
Write the project-aware subset instead — header stats, activity, wins,
friction, fixes as tooling or workflow changes — and say the page is
shorter because the data is thinner, not because nothing happened.
Scope transcript activity to one repo with `--project` (the skill table,
outcomes, and session list stay global — event logs carry no repo
signal); the default unified run answers "how do we work", not "how is
this repo".

## Inputs

1. Run `bash scripts/skills-insights.sh --format json` (add `--log` paths
   for other machines, `--repo` paths for git history, `--since` to bound
   the window). This JSON is the skeleton: per-skill aggregates, per-session
   timelines, wins, friction, mined activity, git history.
2. Read session timelines in did → broke → solved order before judging any
   skill: `did:load+X` and `did:progress=N` (what the agent did),
   `broke:blocked-need+X` and `broke:model-failure(cat)` (what broke),
   `solved:done` or `end:released` (how it ended). A skill that appears in a
   timeline without progress beside it is coincidence until a second session
   says otherwise.
3. Sample transcripts only to confirm a pattern the aggregates already
   suggest — never to go fishing. Quote session ids, never message text.

## Solved Is A Judgment

Call work solved only over a complete evidence chain: progress pulses, then
DONE, then an outcome the timeline supports (merged PR, green CI, clean
first verdict). A DONE with no progress behind it is a claim, not a win. A
release that later needed no revert still counts when the timeline shows
why. Say which chain each win rests on.

## Sections (adapted from the usage-insights shape)

Write every section the data supports; omit and name any the data cannot:

- Header stats: sessions, events, date range, goals DONE versus released,
  merged PRs, lines changed.
- At a glance: what is working, what is hindering, quick wins, ambitious —
  one line each, each pointing at its section.
- Skill table: loads, forced share, no-progress share, outcome correlation.
- Session activity: prompts, tool mix, errors by tool, response gaps (label
  harness gaps where unobserved). Error counts mix hook blocks with
  genuine tool failures: on Claude transcripts most edit errors are
  skill-nudge blocks (the guard working, not the tool failing), while
  Muse failures are near-verbatim misses the agent retries out of.
  Sample the sessions before judging a tool.
- Narrative plus key insight: how the sessions actually ran, in second
  person, then the one finding that matters most.
- Wins: DONE sessions with the chain that proves each.
- Friction: stalled sessions, repeated nudge blocks, model-failure clusters —
  with session ids, never message text.
- Actionable fixes: copy-pasteable overlay snippets, skill pointer fixes, or
  hook changes, one per finding. A finding with no fix is a note, not an
  action.
- Horizon: ambitious workflows the data hints at, marked as ideas.

Do not write an upsell card, team feedback section, or entertainment. Do not
rank people or harnesses. Correlation is never causation: say which
alternative explanations the data cannot exclude.

## Not tracked (on purpose)

Name these exclusions instead of working around them: per-hook firing
counts (volume without signal — first-fire witnesses plus transcript
joins already cover compliance), Codex/OpenCode skill loads (no load
signal exists; labeled exclusions, never ranked), publish
non-conversion and repeat-stall rules (no trigger data yet; parked
until outcomes accrue).

## Output

A single self-contained HTML file at the path the request names (inline CSS
only, system font stack, no external requests so it reads offline), plus a
chat summary: the key insight, the top three fixes, and what the data could
not answer. Keep the file under 500 lines; split narrative detail into the
chat summary rather than bloating the page.

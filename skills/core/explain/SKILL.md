---
name: explain
tier: core
description: "Explain how a subsystem works, why it was built that way from git/PR history (never guessing from code), and teach unfamiliar code progressively with plain language and step-by-step diagrams."
---

# Explain

Help a capable colleague actually understand a subsystem, change, or design decision without walls of jargon, ex-post guesswork, or patronizing tutor theater.

Scope: portable `core` layer across all harnesses. This skill is read-only.

## Modes

Pick the mode that fits the question (combine **How** + **Why** whenever teaching):

- **How (mechanics):** trace how the subsystem runs today, where responsibilities live, and where a new change belongs.
- **Why (archaeology):** answer *why* code exists or has a specific constant/workaround **from the historical record, never by rationalizing the code**.
- **Teach (progressive understanding):** weave mechanics and history into a plain explanation built step by step from the smallest complete mental model.

## Workflow

1. **Pin scope and separate mechanics from history.** Infer what the reader is trying to do (reviewing, debugging, modifying, onboarding) from the conversation without quizzing them. If scope is mildly ambiguous, state your interpretation in one sentence and explore rather than stalling. Done when target files, symbols, or commits are identified.

2. **Trace mechanics (How) and mine the record (Why).**
   - For **How:** read the real entrypoints and callers (delegate bulk directory exploration to a read-only subagent so raw dumps stay out of the main thread). Name real files and symbols.
   - For **Why:** inspect git history, commit messages, PR descriptions, and linked issues for the introducing commit and every later modification. Quote what the authors actually wrote, explicitly mark your own inferences as `inferred`, and state plainly when **the record does not answer why**. Never invent a plausible rationale from reading the code alone. Done when every claim cites either live code (`file:line`) or a specific commit/PR record.

```bash
git log -S "<symbol-or-literal>" --oneline -n 15
git log -L <start>,<end>:<path> --no-patch
gh pr list --search "<commit-sha>" --state merged --json number,title,body,url 2>/dev/null || true
```

3. **Deliver a progressive, anti-theater explanation (Teach).**
   - Start with the smallest complete answer (1 to 2 plain sentences) tied directly to the user's case. Skip material they already know.
   - Walk through what happens when a real request or action runs through the code rather than listing functions as a dry reference.
   - Keep `Why` confidence language intact: uncertainty about intent is a finding, not prose style to polish away.
   - **Progressive diagrams (for 3 or more moving parts):** never dump one giant all-at-once diagram at the end. Draw a short sequence of small Mermaid diagrams (at most 6 boxes each) where each step redraws the previous diagram and adds one new part or edge.
   - **Ban AI tutor theater:** never print framing labels (`"TL;DR"`, `"Key insight:"`, `"At its core"`, `"The one idea to hold onto"`, `"Here is the tricky part"`, `"Pause"`), never quiz the reader, and stop when a layer is complete so they can pull the next layer if needed. Done when the explanation reads cleanly in plain spoken English with zero unexplained jargon.

## Error recovery

- **Fallback when `git log` history is squashed, shallow, or has no PR/issue context:** inspect `git blame` and related tests/docs, quote whatever commit text exists, and state explicitly `"the record does not answer why"` rather than guessing.
- **Fallback when `gh` fails or the repo is local-only:** rely on local `git log` and commit bodies, and note that PR discussions were not checked.
- **Recovery when a trace spans too many files for one pass:** bound the first pass to the single end-to-end happy path, state what branches were deferred, and offer to trace the next branch on demand.

## License

Adapted from `how`, `why`, and `teach` in `pstack` (MIT License, Copyright (c) poteto).

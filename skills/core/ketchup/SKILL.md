---
name: ketchup
tier: core
description: "Catch the user up in plain spoken English with zero unexplained jargon: what changed since their last message, small visuals when helpful, and every call waiting on them decidable from the reply alone."
---

# Ketchup

Give the user a plain-English catch-up covering what changed in this session since their last written message, plus every decision waiting on them so they can decide from your reply alone. Also use this voice whenever the user asks to restate a technical reply in plain words without jargon.

Scope: portable `core` layer across all harnesses. Keep the catch-up turn read-only: do not edit code, start jobs, or post external messages while gathering status.

## Voice

Speak like one person catching up another: short sentences, everyday words, zero unexplained jargon. Say what changed for the user, not how you ran commands. Say "the tests pass", not "CI is green". Leave out commit hashes, file paths, raw commands, build numbers, and test counts unless the user needs one to act. Name each PR, branch, or task the way the user knows it. If a fact needs context to make sense, give the context in one short phrase or leave the fact out.

## Workflow

1. **Gather live state without mutating anything.** Inspect what changed since the user's last written message (tool outputs and subagent reports are not user messages). Check live branch, PR, and check state against actual sources and verify every number you plan to quote. Done when every claimed status matches live tool output.

```bash
git status -sb
gh pr list --state open --json number,title,url,headRefName,statusCheckRollup 2>/dev/null || true
```

2. **Separate human-only calls from agent work.** An action item is a decision or step only the user can take: a product choice, an approval, an irreversible action (deploy, delete data, force-push shared branch, external message), or missing access. Include unresolved calls from earlier in the chat. Work you can still finish yourself is never an action item. Never invent a call to fill space. Done when every action item is genuinely human-only.

3. **Write the reply in plain chat (decidable on its own).** Spend your words on the calls, not the backstory. Keep "what happened" under about 100 words (excluding diagrams). Never collapse a list of action items into a count or replace an item with a bare link.
   - **Opening line:** one short sentence naming what waits on the user, or stating that nothing does. If nothing happened and nothing waits, say so and stop.
   - **Visuals (only when a picture beats sentences):** embed existing screenshots or draw one small Mermaid diagram (at most 6 boxes, at most 8 plain words per box) for a dependency chain, before/after flow, or side-by-side options. Never draw a status list, an action list, or duplicate facts already stated in text.
   - **What changed:** one short spoken bullet per item the user asked for ("Search was slow because an index was missing", not "Search review: done"). Name bugs found and fixed along the way. Never mark an item done if it still waits on the user. Add one short line for remaining work you can finish yourself.
   - **Action items shaped to the call:**
     - *Single item:* one bullet with the call, your pick, what changes for users, the evidence behind your pick, and the risk (even when low: "Low risk: only copy changes.").
     - *Shared call across multiple items (such as PRs to merge):* state the call and pick once, then one bullet per item **riskiest first** (link and plain name, what changes, evidence, risk; note a different pick only where it differs).
     - *Call between options:* list every option weighed with what it gains and what it costs; those costs are the risk.
   - **Unknowns:** write `unknown` for any decision-critical fact you could not verify, and list what you did not check in one short line. Done when the user can reply "yes / option B / merge 1 and 2" without opening another tab.

## Error recovery

- **Fallback when `gh` or a tracker tool fails or is unauthenticated:** report the local git state you verified, mark remote PR/CI state `unknown (gh unavailable)`, and never guess whether checks passed.
- **Recovery when an earlier number disagrees with live state:** report the live value and note the correction in one plain phrase.
- **Fallback when a user asks "restate that plainly" on your previous reply:** skip step 1 and rewrite your last message in Ketchup voice with zero jargon, preserving accuracy and any open decision.

## License

Adapted from `ketchup` and `bro` in `pstack` (MIT License, Copyright (c) poteto).

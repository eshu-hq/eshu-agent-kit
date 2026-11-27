# Owner report

The owner follows many sessions at once and wants plain spoken updates they can
act on immediately — without decoding engineering jargon or opening extra files
for routine status checks.

**Default: plain-chat catch-up (`ketchup` style).** Follow the portable
[ketchup](../../../core/ketchup/SKILL.md) format directly in chat for status
updates, session catch-ups, and decision requests. Keep the standalone HTML page
optional for large multi-diagram comparisons or when the owner explicitly asks
for an HTML report.

## Plain-chat default (ketchup style)

Use plain words, short sentences, and zero unexplained jargon — like one person
catching up another. Say what changed for the user or operator, not how you ran
commands. Leave out commit hashes, file paths, raw commands, and test counts
unless the owner needs one to decide or act.

1. **Open with what waits on the owner** (one short sentence). Say if nothing
   waits on them. If nothing changed and nothing waits, say so and stop.
2. **What changed (under ~100 words, excluding diagrams).** One short spoken
   bullet per item requested: what happened and its state (done, running,
   failed, or not checked). Write how you would say it out loud ("Search was
   slow because an index was missing", not "Search review: done"). Never mark
   an item done if it still waits on the owner. Name any bug found and fixed on
   the way. Add one short line for remaining work you can finish yourself.
3. **Small diagram only when it beats sentences.** Keep any Mermaid diagram to
   at most 6 boxes with at most 8 plain words per box. Never draw a status list
   or duplicate facts already stated in the text.
4. **Calls waiting on the owner (decidable from the reply alone).** List only
   calls that only the owner can make (product choice, approval, irreversible
   action, missing access) — never work you can still do or settle via the
   arbiter. Never replace a list with a count or a bare link.
   - **Single item:** one bullet with the call, your recommendation, what
     changes, evidence behind your pick, and explicit risk (even when low:
     "Low risk: only copy changes.").
   - **Shared call across items (e.g., PRs to merge):** state the call and your
     pick once, then one bullet per item **riskiest first** (PR/issue link and
     plain name, what changes, evidence, risk; note item pick only where it
     differs).
   - **Call between options:** list every option weighed with what it gains and
     what it costs; those costs are the risk.
5. **NOT_CHECKED:** one short line naming what you did not verify.

## Optional HTML page (large comparisons or on request)

Use the standalone HTML page only when the owner asks for it or when a multi-lane
comparison needs rich diagrams that do not read cleanly in chat.

1. Copy [the skeleton](owner-report-skeleton.html) to your scratch directory as
   `show-me-<topic>.html`. Do not write into the repository.
2. Fill these sections in order and delete any empty section: **Status**
   (`Done`, `Blocked`, `Needs your decision`, or `Working` + one sentence),
   **Answer** (2 to 4 plain sentences), **Decision** (plain call, pick, option
   costs), **What changed or what we found**, **Evidence** (table with `Proven`,
   `Inferred`, or `NOT_CHECKED` tags), **NOT_CHECKED**, **Next step**.
3. Open the file (`open <file>` on macOS, or paste Mermaid inline when headless)
   and send 2 to 4 plain lines in chat with the state and file path.

## Rules (both chat and HTML)

- The owner's words are the test: "plainly state it", "what you need from me",
  "what is the recommendation". Answer those three first.
- A status request asks what you finished and what remains. Name each lane or
  session: its state, why it holds, and its next step. Do not write "nothing is
  blocked" without saying what each lane waits for.
- A claim about an artifact must match the artifact. If you say "the issue says
  X", X must be in the issue text. Quote it.
- Say the owner asked for something only when you can quote the request. Do not
  say "as you asked" from memory.
- Use the numbers and names the owner sees on GitHub, such as the PR and issue
  numbers, so the owner can open the item.
- Keep pod IDs, image digests, entity IDs, and credentials out of the report.
- When you ask peer sessions to report to the owner, tell them to follow this
  file. Do not copy its rules into the message.

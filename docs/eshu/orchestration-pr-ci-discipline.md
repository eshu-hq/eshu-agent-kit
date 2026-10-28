# Orchestration, PR, And CI Discipline

> Extracted from `eshu/AGENTS.md` (at the migration commit) with skill names updated to their kit renames. Do not extend here: discipline changes land in the eshu source until cutover, then this file moves with them.


- For substantive implementation, review, and research, the orchestrator MUST use bounded subagents/workflows on two or more independent lanes (or record why inline is correct); single-lane work stays inline. On Muse this overrides the built-in inline preference (native spawns apply each definition's manifest model; workflow children take it per call), per the tier map in [Agent Orchestration Model](agent-orchestration.md#roles-models-and-tools). A subagent never downgrades its own model. Leaf agents do not dispatch. After every `gh pr create`, arm the CI watcher in the same turn (GHA failures, merge conflicts, any-author reviews/comments; `session-lifecycle` babysit-prs). NEVER request a GitHub Copilot review. Every issue created during a goal is captured in the goal's issue ledger and worked in that goal: the Stop hook refuses `DONE` while one is open without a `DEFER: #N <arbiter ruling path>` line ([Issue Capture Hooks](agent-hooks-issues.md)). Give it an existing label and link its epic when one exists (`issue-driver`).
- Only the **orchestrator** runs `make pre-push`, exactly once, immediately
  before the push. It also runs `make pre-pr` or `make pre-pr-full` when the
  change needs that deeper, optional preflight. Subagents MUST NOT run these:
  running the floor N times per branch wastes CPU. Subagents run focused
  verification. Executors also run the registry-selected static gates
  (`develop-eshu` role). Subagents paste the results in the handoff. The live
  gate binds fixed host ports and holds a cross-worktree mutex. See
  [serialization and contention](agent-guide.md#live-gate-serialization-and-contention).
- MUST check open and merged PRs (`gh pr list --state all --search <issue>`)
  and recent commits for the same root cause before you start an issue. A
  shallow clone hides history; see
  [Agent Git And Worktree Hygiene](agent-git-hygiene.md). MUST isolate formatter drift in its own commit. See
  [duplicate-work and formatter-drift guards](agent-guide.md#duplicate-work-and-formatter-drift-guards).
- Before you claim merge-ready, the PR **title AND description** MUST both match
  the final diff. The description MUST carry the before and after evidence. A
  wrong derivable figure is exempt when the verdict's P3 list (posted as a PR
  comment, not in the body) records the correct figure (see
  [Derivable figures](../../skills/eshu/code-review/references/merge-bar.md#derivable-figures)).
- CI is complete ONLY after **two consecutive stable reads of the full check
  set** (`pending == 0` and an unchanged total). Large sets register in waves,
  so one `0-pending` read is a false done. State the query you used. Reconcile
  the review-thread API with the displayed unresolved comments before you
  declare the threads clear.
- When a PR uses `Refs #N` and leaves the issue open, comment on #N with what
  remains. That comment, on the issue your PR references, needs no extra
  approval. A reader of the issue then needs no search to find the fix.


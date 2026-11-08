# Concepts

A few terms first. A **skill** is a written procedure an agent loads for
a kind of task. A **hook** is a small script the harness (Claude Code,
Codex, and friends) runs on its own at set moments, like before an
edit. A **subagent role** is a named helper-agent definition with its
own instructions and model.

## The problem this solves

Without the kit, every repo carries its own copy of the same skills and
hooks. Copies drift, fixes land in one repo and never reach the others,
and nobody knows which copy is current. With the kit, a product repo
keeps only a version pin plus a small overlay. Everything shared lives
here and ships by version.

## From a task to an answer

You hand the harness a task and it hands the work to an agent, which
loads whichever kit skill fits. Some skills send the agent to Eshu's
MCP or API tools for graph answers (`eshu-mcp-call-rigor` covers how to
call them well), and hooks sit underneath the whole run, allowing or
blocking actions as they happen.

The kit itself calls no Eshu API and reads no Eshu database. It holds
the procedures, and the agent does the calling. Diagram:
[From a task to an answer](../diagrams/README.md#from-a-task-to-an-answer).

## The loop the kit exists for

Most of the weight sits on one path: you declare a goal against a
GitHub epic or issue, and the kit drives it to a merged PR. Nothing
stops at "PR opened". Diagram:
[The task-to-merged-PR loop](../diagrams/README.md#the-task-to-merged-pr-loop).

Three pieces carry that loop:

- **`issue-driver` owns the outcome**, not just the edit. It enumerates
  an epic's leaf issues, claims one publicly so concurrent agents don't
  collide, works each leaf in its own worktree with focused proof, and
  keeps going past "PR opened" through review and CI.
- **`session-lifecycle` owns the mechanics** long goals die without:
  resuming a branch mid-flight, pausing with a note and picking it up
  after compaction or days offline, judging whether a worker is alive
  before touching its tree, rebasing when `main` moves, and cleaning up.
- **Hooks own enforcement at the exact point of action.** An edit can
  trigger skill-nudge or doc-staleness; a shell command can hit
  guard-live-gate; stopping can trigger goal-continue. Every hook fails
  open outside its scope — a missing interpreter, a non-Eshu checkout,
  or no goal file all allow the action through.
  [hooks/README.md](../../hooks/README.md) has the full table.

`publish` is the last pass: issue bodies, PR descriptions, and status
notes written so the next reader needs no other context.

## Boundaries

Don't copy kit files into a product repo, and don't treat the
`skills/eshu/` procedures as generic advice for unrelated codebases —
they cite Eshu surfaces by design. The kit runs no service and stores
no Eshu data.

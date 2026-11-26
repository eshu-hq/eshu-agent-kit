---
name: session-lifecycle
description: Session mechanics for Eshu work — resume a branch/handoff, pause with a resume note, babysit an open PR through CI, judge agent/worktree liveness, clean up worktrees, rebase and re-verify a branch, or answer a stale handoff message.
---

# Session Lifecycle

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths and tooling (`make`, `ci-gates`, `scripts/`) resolve in the consuming repo checkout (all `eshu-*` names per `skills/registry.md` are already canonical; resolve old prefixes via the rename map).

## Evidence at handoff

Preserve the prior investigation's file map, settled design decisions, and
rejected hypotheses. Verify the evidence behind claims before relying on them.
A summary saying "tests pass" is not proof.

For an inherited result, inspect the actual command, exit status, tested
commit/tree, relevant inputs, and environment. Reuse an artifact only when
these still match and its provenance is verifiable; name it as inherited proof,
not a run you performed. Re-run affected checks when the evidence is absent,
ambiguous, invalidated, or the environment matters and cannot be verified.
Refresh live PR status and ownership even when local proof remains reusable.

This does not waive final promotion: `make pre-push` is the required floor
once per PR, on the push that opens it (never on row 4a, tier S, or an owner
push order; see Rebase Waiver in `code-review` for a rebase), `make pre-pr`/
`make pre-pr-full` run only for a package move, a CI red to reproduce, or when
the owner asks, and `review-attest verify` must match the reviewed inputs
before push. A rebase or amend invalidates prior review
receipts. Once pushed, CI decides the merge (`[fill-in: merge rule — this repo's merge bar: when a PR may merge]`).
See the consuming repo's local-testing doc (Eshu:
`docs/public/reference/local-testing.md`).

## Routing

| Situation | Playbook |
|---|---|
| "Take over this", "resume #NNNN", a branch handed to you, work you left days ago, the first turn after a compaction | [session-pickup.md](references/session-pickup.md) |
| "I'm going offline", "restart", context is about to compact | [pause-safely.md](references/pause-safely.md) |
| A PR is open and needs watching through review and CI to merge | [babysit-prs.md](references/babysit-prs.md) |
| `git worktree list` has grown long, disk is tight, trees look abandoned | [worktree-cleanup.md](references/worktree-cleanup.md) |
| "run until done", "going to bed", a `/loop`, or any goal handed over with no checkpoint schedule | [autonomous-run.md](references/autonomous-run.md) |
| `main` moved under a branch you have out; rebase and re-verify; a gate red after a rebase | [rebase-verify.md](references/rebase-verify.md) |

Choose the playbook for the current event. Preserve its applicable ownership,
evidence, and authorization checks; report the resulting resume point or
blocker. Do not copy an entire playbook into a todo list for a narrow task.

## Liveness is not mtime

This applies across every playbook, so it lives here.

A subagent that is thinking writes no files. Its transcript buffer stays small
until it completes. Judging "this agent is dead" or "this worktree is
abandoned" from a file timestamp will be wrong in the one direction that costs
you: it reads a live worker as dead, and then you collide with it.

Judge liveness from something that moves for a reason:

- a process whose working directory is that tree,
- an open PR or an unmerged branch with commits ahead of `origin/main`,
- a task the harness still reports as running,
- the user telling you.

When those disagree, the answer is "assume alive": leave it and keep working.

## Messages name their head

Heads move while a request is in flight, so a request can arrive after the
state it describes is gone. This applies across every playbook.

1. **Resolve branch HEAD, BASE, and verified worktree path.** Measure `HEAD`,
   `BASE`, and the live worktree path in the branch's worktree rather than
   guessing `.worktrees/<branch>`:

   ```bash
   git rev-parse HEAD
   git merge-base HEAD origin/main
   git worktree list --porcelain
   ```

   Done when the brief names a path present in `git worktree list --porcelain`
   and a 10+ character `HEAD` and `BASE` SHA.
2. **Stamp the head line first.** Put one line in every message that carries a
   verdict, handoff, ruling, or request about a branch:
   `HEAD=<sha> BASE=<sha> RE:<request-id>`. Put it first, after any status token
   the message must start with, such as `RULING:` or `BLOCKED:`, and name the
   branch in the same message. Done when the sender picks a short request id and
   the reply copies it.
3. **Reject stale requests before starting work.** If a request names a `HEAD`
   that is not the current tip of that branch, reply `STALE` with the current
   tip and do not start the work. If the named worktree path does not exist on
   disk, check `git worktree list --porcelain` (or reply `STALE` when read-only
   without shell access) instead of probing guessed paths. Done when work begins
   only on a live, matching tip and path.

## Common mistakes

| Mistake | What it costs |
|---|---|
| Re-running the prior agent's whole investigation | A session of context, and the design reasoning that was already paid for |
| Accepting "tests pass" without inspecting verifiable evidence | Shipping on a self-report |
| Pausing by pushing or opening a PR "so it's saved" | An irreversible action taken for a reversible reason |
| `git stash` to park work | The stash stack is shared across all worktrees; concurrent agents corrupt each other |
| Editing in the main checkout because the worktree "was just for the last task" | Main must stay a clean fast-forward of `origin/main` |
| Passing a guessed `.worktrees/<branch>` path in a subagent brief | Subagents burn dozens of `read_file` errors on missing paths instead of reading the live sibling worktree |
| Reading one `pending == 0` and calling CI green | Large check sets register in waves |
| Retrying a failed exact-match edit with a longer block from memory | The failure already names the closest match — re-read those lines and retry with the shortest unique match; long blocks drift |
| Deleting a worktree that looked idle | Uncommitted work is unrecoverable; the tree may be in active use |

## Related skills

- `issue-driver` owns driving an issue to merged. This skill owns the
  session mechanics that driver depends on.
- `code-review` owns the pre-push verdict. Pickup and babysit hand off to
  it, they do not replace it.
- `publish` is the last pass over any status update, resume note, or PR
  reply these playbooks produce.
- `resolve-review-threads` owns thread resolution that babysit-prs events
  hand off to.

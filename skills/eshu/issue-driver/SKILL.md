---
name: issue-driver
description: Drives an assigned eshu-hq issue or epic through implementation, review, promotion, and a verified merged/closed outcome — worktree per leaf, PR monitoring, to closure.
---

# Issue driver

Scope: this is the `eshu` layer of the kit. Relative `docs/` and `scripts/` paths resolve in the consuming repo checkout. Skill-to-skill links resolve in-kit.

Use for assigned issues in `eshu-hq` repos. A request to edit skills or open a PR
alone does not authorize driving issues through merge and closure. Follow the
user's requested endpoint and existing session grants; skill invocation never
adds authorization for external actions or peer-owned work.

## Establish The Work Set

Require issue numbers or URLs from the request; do not invent them. Read each
issue's title, body, labels, and state. For epics (tracking labels, child task
lists, or sub-task sections), recursively enumerate children and deduplicate
leaves, stopping cycles. Restate each leaf's problem, acceptance criteria, and
affected flow, then present a numbered execution order.

Read-only exploration may proceed within the authorized scope. Continue to
implementation when scope and acceptance criteria are clear and already
authorized; take unresolved decisions to an arbiter model instead of asking.
Do not introduce a second plan approval after the user has authorized the work.
Check open PRs and recent commits for the same root cause before claiming a leaf.
Respect existing ownership; do not take over an active peer PR without assignment.

Post a claim comment on the issue naming the files or families this drive owns
before the first edit. Read sibling claim comments live at each push, not only
once at the start — a peer's claim posted after this drive began still owns
what it names.

Sweep every acceptance criterion against current `origin/main` before
implementing, not against the issue text alone. On an older issue, later work
often already satisfies some criteria; implementing an already-met one
duplicates work and can reintroduce a fixed defect.

Create a worktree per leaf and verify its path before editing. Load the minimum
project skills covering its touched surfaces using root skill routing. Preserve
TDD for code, package ownership, graph/query truth, performance and concurrency
proof, private-data boundaries, and the prohibition on shared-worktree stashes.
Delegate independent work when available and authorized; executors run focused
proof and only the orchestrator runs the promotion gate. Commit before
dispatching any subagent — a "read-only" reviewer once reverted a production
fix while probing a test tautology, and there was nothing to recover but the
commit. Include the verified absolute worktree path from
`git worktree list --porcelain` in each subagent brief so read-only reviewers
and debuggers inspect the live checkout instead of guessing `.worktrees/<slug>`.
Re-verify a subagent's findings yourself before acting on them, and
before passing them to an executor as verified; a finding is what the subagent
believes, not what you have confirmed.

Stop a leaf agent once its handoff is consumed. Keep a reviewer alive only
while its PR is open, because its retained context makes re-review rounds
cheaper, and stop it when the PR merges or closes. Close idle executors and
arbiters immediately; a pane left open reads as live work and invites a
liveness misjudgement.

## Implement And Promote Each PR

1. Implement and commit the authorized change with focused verification from
   `docs/public/reference/local-testing.md`. Runtime changes also require
   performance/no-regression and operator evidence. Use the root rules for
   proof order and selected gates.
2. Verify authentication before push/PR actions. If `gh` is unavailable, an
   equivalent installed GitHub connector may be used; identify that fallback
   in the evidence. Fetch `origin`, rebase on fresh `origin/main`, rerun proof
   affected by the rebase, and inspect the diff for unrelated reversions.
   For Go changes, run the consuming repo's vet gate for the touched packages
   (Eshu: `cd go && go vet ./...`) to catch test compilation drift.
3. Run the complete preliminary `code-review` on the rebased diff, except
   when the rebase table in that skill ("Rebase Waiver") sends this rebase to a
   waiver note or a scoped re-review instead. See step 5. Use
   separate-context review when available and authorized; otherwise explicitly
   identify self-review and its limitation. Fix P0/P1/blocking P2 findings,
   rerun affected proof, and repeat review until those counts are zero.
   Use that skill's finding schema, proof tiers, and merge bar as the single
   source of review policy.
4. Capture the clean review's inputs with `ci-gates review-attest capture`.
   For a waiver note or a scoped rebase verdict, run `make pre-push` first only
   when the rebase triggers it (`code-review`, "The floor on a rebase"), and
   capture after it exits 0.
   Run `make pre-push` once per PR, on the push that opens it (never on row 4a,
   tier S, or an owner push order; see Rebase Waiver in `code-review`) — the
   fast floor (changed-package test/lint/build/vet, file cap,
   registry-selected static gates, docs-contradiction). Later pushes run
   focused proof only. `make pre-pr` is not part of promotion: run it for a
   package move (`make pre-pr-full`), to reproduce a CI red, or when the owner
   asks. Keep the shared machine quiet for
   either live lane: coordinate ownership across worktrees/clones and inspect
   the live-gate lock and running gate process; absence of a `make pre-pr`
   process alone does not prove the machine is free. A wall-time proof owns the
   host: pause every other gate until its results are closed (`[fill-in: timing proof rules — this repo's wall-time proof rules]`). Never kill another
   session's gate.
5. Verify the receipt with `ci-gates review-attest verify` after preflight.
   Matching inputs reuse the preliminary semantic review. A changed base,
   commit, tree, worktree, submodule, PR claim, review packet, or verdict
   requires affected proof and a new full review/receipt before promotion.
   The one exception is a rebase: follow the decision table in `code-review`
   ("Rebase Waiver") for which outcome applies — row 4a, tier S, waiver note,
   scoped re-review with a scoped rebase verdict, or full review. That table
   is the single source; do not re-derive its rows here. A `CHANGELOG.md`
   union or a regenerated pin is row 4a; do not wait on a floor for it.
   On preflight failure, diagnose and fix it, rerun affected proof, and obtain
   a clean preliminary review before another attempt. Deferred P2 and cosmetic
   P3 findings do not restart this loop. Once pushed, CI decides the merge
   (`[fill-in: merge rule — this repo's merge bar: when a PR may merge]`);
   on a red gate, reproduce only that gate locally.
6. With authorization already established for the act, push the reviewed head
   and verify the remote SHA equals local HEAD before PR creation/update.
   Use `--force-with-lease` for an authorized rebase of an already-pushed branch.
   No edits may occur between verified attestation and push. Make the PR title,
   description, and affected docs match the final change and its proof.
   An explicit owner order to push overrides the floor, the review, and the
   receipt for that push: push now and record it (`code-review`, "Owner
   push order"). Never refuse or ask again after the order.
7. Arm the CI watcher in the same turn as the `gh pr create` (see
   [babysit-prs step 1](../session-lifecycle/references/babysit-prs.md): one watcher, rebuilt set,
   GHA failures + merge conflicts + any-author reviews/comments/threads;
   Monitor tool on Muse). Collect current GitHub checks, mergeability,
   review bodies, issue comments,
   and review threads immediately after publication. During an authorized
   merge/closure drive, follow [monitoring.md](references/monitoring.md) for
   stable check reads, cancelled gates, findings, and unavailable reviewers.
   Never request a GitHub Copilot review; handle any unrequested Copilot
   comment like any present reviewer's.
   Every requested reviewer must have a disposition. A reviewer that does not
   answer does not trigger another review: the independent review that ran
   before the push and the green CI wave stand, and the PR says which reviewers
   were unavailable (owner direction 2026-11-22).
8. Merge only when that endpoint and act are authorized, checks are stably
   green, findings and threads are dispositioned, current base/head evidence
   remains valid, and the pre-push review is clean. Confirm local
   HEAD equals the PR head, execute the merge, and verify `MERGED` through the
   GitHub API. Existing session authorization applies without repeated consent.
   An authorized merge needs no arbiter review: the preliminary review and the
   hosted reviews already read this head, so a third review of the same
   content adds cost, not evidence. Take a merge to an arbiter only when the
   act is not authorized, a finding is disputed, or the change moves a shared
   contract those reviews did not cover. Before any merge, run
   `bash scripts/dev/pre-enqueue-check.sh <pr> <reviewed-head-sha>` (and hand
   its output to the arbiter when one runs); see [monitoring.md](references/monitoring.md)
   for what its arms mean. The script is one
   read, so it does not replace the two stable CI reads.

For long-running `/goal` drives, load [sustained-drives.md](references/sustained-drives.md)
for goal composition and bounded waiter/liveness mechanics. The skill does not
create a goal or schedule future work by itself.

## Before You File An Issue

Filing is not deferring. The issue storm and the goal items that bubbled up
late both came from treating a filed issue as finished work. Settle these first:

1. A fix that fits the files this PR already changes goes into this PR: a doc
   line, a test, a comment, a small cleanup. Do it now; do not file it.
2. Search before you create: `gh issue list --state open --search "<key words>"`
   and the open children of the epic. When one matches, comment on it with what
   you found. Never open a second issue for the same problem.
3. File only real work: it needs a design decision, its own measurement or
   proof, access you do not have, or it spans more than one package owner. The
   number of issues is not limited, but each issue is exactly one problem. Do
   not bundle two problems into one issue, and do not split one problem across
   several.

## Issues Created During A Goal

Every GitHub issue this session creates as part of a goal MUST, in the same
turn that creates it and before work on it starts:

1. Be in the goal's issue ledger. The issue-capture hook records every issue
   it sees created into `<goal file>.issues`
   (`[fill-in: issue capture hooks — this repo's issue-capture hook doc]`); add
   one by hand only if the hook missed it. Also add it to the GitHub
   Project/milestone when the goal names one and access allows — never invent
   a project number. A created issue outside the ledger is an orphan and a
   rule violation.
2. Carry at least one **existing** label, chosen from `gh label list` output.
   Never invent a label; if no existing label fits, say so in the issue and
   the goal inventory instead of creating one silently.
3. Be linked to its epic when one exists: search open `type:epic` issues
   (`gh issue list --label type:epic --state open`), add `Part of #<epic>` to
   the body and reference the epic from the goal inventory. When no epic fits,
   state that explicitly in the inventory.
4. Be worked as in-goal work, in a parallel lane where safe, now, not at the
   end. "Filed for later" is not an outcome. The only other exit is a
   `DEFER: #N <path>` line in the ledger, where `<path>` is an arbiter ruling
   file that names `#N` and says why it waits. The Stop hook refuses `DONE`
   while a ledger issue is open with neither.

Tell every subagent/workflow on the goal to follow this for issues it creates.

## Defects Found During The Drive

Fix related defects inline when they fit the authorized change and its proof.
Use `code-review`'s merge bar to classify blocking and deferred findings.
A defect needing a design decision, unrelated projected-truth changes, or
unavailable infrastructure may need separate work. Take the design decision to
an arbiter model, not the owner. Create the follow-up issue inside the goal and
link it to the originating issue and epic; the ledger then holds it to the goal.
Do not expand the drive silently: say in the goal report what was added.
A small defect goes into an open PR of this goal that already touches that
file, within the small-change tier. Otherwise file one issue for it (the ledger
holds it to the goal); do not park it on a list nothing checks. Open no PR for
one or two Markdown files unless that is the whole deliverable or it repairs
`main`. At the start of a goal, group the lanes by the files they touch and give
each group one PR. These last two are guidance, not a check: nothing verifies
them, so the report says what was grouped.
A follow-up issue created under this section follows
[Issues Created During A Goal](#issues-created-during-a-goal) in full.

## Completion Evidence

At the requested endpoint, report commands and results once with durable evidence
links; do not repaste an unchanged checklist every turn. A merged/closed drive
is complete only when:

- GitHub directly reports every assigned leaf and epic `CLOSED` and its PRs
  `MERGED`; use `gh issue view ... --json state` and `gh pr view ... --json state`.
- Every follow-up is closed or explicitly deferred with the owner's agreement.
- Current review-thread API results confirm no unresolved threads, and all
  review-body/issue-comment findings have dispositions. Inline comment REST
  output alone does not expose thread resolution state.
- The final review has P0=0, P1=0, P2-blocking=0. Each deferred P2 has a linked
  issue, owner agreement quoted in the PR, and its severity-table category per
  the merge bar. The verdict includes applicable proof and probes, all five
  passes, cross-pass comparison, generated/docs/private-data scans, and verification.
- The PR says which requested reviewers were unavailable, if any.
- The promotion record includes clean preliminary review counts, reviewed
  inputs, exact preflight command/result, post-preflight head and clean status,
  and a verified receipt, or a row 4a or tier S record. GitHub CI evidence uses
  two stable full-check reads tied to the current head, as monitoring specifies.
- Before closing an issue as fixed, the applicable full verification suite from
  `docs/public/reference/local-testing.md` has run with exact tool versions and
  captured results. A code inspection or unsupported prior summary is not proof.

If the request ends at PR creation, report the PR and pending CI/review state;
do not claim the stronger merged/closed completion conditions or continue into
an unauthorized merge.

# Issue Filing, Goal Ledgers, Defect Routing, And Completion Evidence

Detailed rules referenced from [issue-driver/SKILL.md](../SKILL.md).

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
   `DEFER: #N <issue-comment-url>` line in the ledger pointing at the GitHub
   comment recording the arbiter ruling on `#N` (or an untracked local ruling
   file; never commit ruling files under `docs/internal/arbiter/`). The Stop
   hook refuses `DONE` while a ledger issue is open with neither.

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

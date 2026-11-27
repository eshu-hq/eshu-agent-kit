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

## Pre-Flight Drive Checklist

- Confirm issue numbers/URLs, sweep acceptance criteria against live `origin/main`, and post a claim comment before the first edit.
- Create one worktree per leaf, commit before dispatching any subagent, and pass verified paths from `git worktree list --porcelain`.
- Keep executors on focused proof; run `make pre-push` once per PR (opening push only) and arm the CI watcher in the same turn as `gh pr create`.
- Resolve every review thread via GraphQL after CI is green on the fixing SHA and re-query to confirm `0` unresolved threads before merge.
- Close idle executors/arbiters immediately; keep reviewers alive only while their PR is open.

## Establish The Work Set

Require issue numbers or URLs from the request; do not invent them. Read each
issue's title, body, labels, and state. For epics, recursively enumerate children
and deduplicate leaves, stopping cycles. Restate each leaf's problem, acceptance
criteria, and affected flow, then present a numbered execution order.

Read-only exploration may proceed within authorized scope. Continue to
implementation when scope and acceptance criteria are clear and authorized; take
unresolved decisions to an arbiter model instead of asking (never introduce a
second plan approval). Check open PRs and recent commits before claiming a leaf,
respect peer ownership, post a claim comment naming owned files before the first
edit, and re-read sibling claim comments at each push. Sweep every acceptance
criterion against current `origin/main` first so already-satisfied criteria are
not re-implemented.

Create one worktree per leaf and verify its path before editing. Load the minimum
project skills matching its touched surfaces. Preserve TDD, package ownership,
graph/query truth, performance/concurrency proof, private-data boundaries, and
the prohibition on shared-worktree stashes. Commit before dispatching any
subagent, pass the verified absolute worktree path (`git worktree list --porcelain`)
and explicit file list (`git diff --name-only` / `rg --files`), and re-verify
every subagent finding yourself before acting on it. Stop idle executors and
arbiters immediately; stop a reviewer when its PR merges or closes.

## Implement And Promote Each PR

1. Implement and commit with focused verification from
   `docs/public/reference/local-testing.md` (runtime changes also require
   performance/no-regression and operator evidence).
2. Verify `gh` authentication (or note equivalent connector fallback), fetch
   `origin`, rebase on fresh `origin/main`, rerun affected proof, inspect for
   unrelated reversions, and for Go changes run `cd go && go vet ./...`.
3. Run the complete preliminary `code-review` on the rebased diff (separate
   context when available; otherwise name self-review and its limitation), except
   when `code-review`'s [Rebase Waiver](../code-review/SKILL.md#rebase-waiver)
   grants row 4a, tier S, a waiver note, or scoped re-review. Fix P0/P1/blocking
   P2 findings, rerun affected proof, and repeat until zero blockers remain.
4. Capture the clean verdict with `ci-gates review-attest capture`. Run
   `make pre-push` **once per PR** on the opening push (never on row 4a, tier S,
   or an owner push order; later pushes run focused proof only; `make pre-pr` is
   only for package moves, reproducing a CI red, or owner request). Keep the
   shared machine quiet: inspect the live-gate lock, pause other gates during
   wall-time proofs (`[fill-in: timing proof rules — this repo's wall-time proof rules]`),
   and never kill another session's gate.
5. Verify with `ci-gates review-attest verify`. Any edit or changed base/claim/packet
   voids the receipt except under `code-review`'s Rebase Waiver. On preflight
   failure, diagnose, fix, rerun affected proof, and repeat preliminary review
   before retrying. Once pushed, CI decides the merge
   (`[fill-in: merge rule — this repo's merge bar: when a PR may merge]`); on a
   red gate, reproduce only that gate locally.
6. Push the reviewed head (`--force-with-lease` on authorized rebases) and verify
   remote SHA equals local HEAD. No edits between verified attestation and push.
   An explicit owner push order overrides floor/review/receipt for that one push
   (`code-review`, Owner push order).
7. Arm the CI watcher in the same turn as `gh pr create`
   ([babysit-prs.md](../session-lifecycle/references/babysit-prs.md)) and follow
   [monitoring.md](references/monitoring.md). Never request a GitHub Copilot
   review; triage any unrequested comment like any reviewer's. Request owner
   review at creation; silence is never unavailability (positive decline/absence
   plus 24h minimum only; self-opened PRs under owner credentials wait for
   explicit owner review/merge action). Disposition every red gate (fix or prove
   pre-existing on bare base). Work every reviewer comment, reply after pushing,
   wait for green CI on the fixing SHA, resolve threads via the GraphQL API
   (`resolve-review-threads`), and re-query to confirm zero unresolved threads.
8. Merge only when authorized, checks are stably green (two consecutive reads),
   threads/findings are dispositioned, and local HEAD equals PR head. Run
   `bash .agents/skills/issue-driver/scripts/pr-readiness.sh --pr <pr> --expect-head <sha>`
   (and `bash scripts/dev/pre-enqueue-check.sh <pr> <reviewed-head-sha>` in Eshu) before merge
   (an authorized merge with clean preliminary + hosted reviews needs no third
   arbiter unless a finding is disputed or a shared contract moved). Verify
   `MERGED` via GitHub API.

For long-running `/goal` drives, load [sustained-drives.md](references/sustained-drives.md).

## Issue Filing, Goal Ledgers, Defects, And Completion Evidence

Follow [issue-and-closeout.md](references/issue-and-closeout.md) for:
- **Before You File An Issue** (inline-fix vs search-first vs single-problem rules),
- **Issues Created During A Goal** (goal ledger, existing labels only, epic link, in-goal work or arbiter `DEFER:`),
- **Defects Found During The Drive** (inline vs follow-up routing), and
- **Completion Evidence** (direct GitHub API `CLOSED`/`MERGED` verification, zero unresolved threads, two stable CI reads, and full local-testing proof).

Small in-session friction (a skill, hook, script, or doc that misled the session)
takes [papercut](../../core/papercut/SKILL.md) instead of a full issue so the
`skill: <name>` join-key stays canonical for `/debrief`:

```bash
bash "$KIT/scripts/file-papercut.sh" file --skill <name> --title "<summary>" \
  --tried "<action>" --expected "<promised>" \
  --happened "<observed>" --fix "<smallest fix>"
```

# Monitor Owned PRs

Monitor only PRs owned by this drive. Do not rebase, fix, or resolve comments
on a peer-owned PR without explicit assignment. Read review bodies and issue
comments as well as inline threads; an inline-only scan misses findings.
Keep outward-facing comments and review requests within user authorization.

- Rebase open PRs on `main`; resolve conflicts immediately (PRs merge fast).
  During CI/review waiting, check `gh pr view <n> --json mergeable,headRefOid`
  about every 60 seconds; do not wait for the gates to finish before looking.
  If `mergeable` becomes `CONFLICTING` or `UNKNOWN` for more than one poll,
  fetch, rebase on `origin/main`, and take the row the Rebase Waiver table in
  `code-review` gives. A mechanical conflict (row 4a, including every
  [conflict recipe](../../code-review/references/conflict-recipes.md)
  file) needs only its file-type checks and a PR comment before the
  `--force-with-lease` push; other rows repeat the promotion sequence. Restart
  the poll after the push. Active agents merge constantly; a green check
  snapshot can become stale while the PR is waiting.
- `scripts/dev/pre-enqueue-check.sh` checks the merge rule. It fails on a
  ruleset-required check that is not green, and on a completed red check that
  is not named with `--dispositioned '<check>=<reason>'`; a pending or absent
  non-required check is only a note. Do not bypass the script by hand and do
  not merge on a red arm.
- CI is done only after **two consecutive stable reads of the full check set**
  (`gh pr checks <n> --json bucket` shows `pending == 0` AND the total count is
  unchanged across two polls). GitHub registers large check sets in waves, so a
  single `0-pending` read is a false "done" — never merge or claim green on it.
  Report CI status with the exact query used, **and the head SHA it was read
  against**. Re-resolve the SHA at read time, never at watcher launch: a poller
  that captured `$SHA` when it started keeps reporting that commit after a
  force-push, so both of its "stable" reads can honestly describe a head that no
  longer exists. A read whose SHA is not the current head is stale — discard it.
  Before merging, confirm local `HEAD` equals the PR's `headRefOid`.
  Only the orchestrator runs `make pre-push`, once per PR on the push that opens
  it (never on row 4a, tier S, or an owner push order), and `make pre-pr` or
  `make pre-pr-full` only for a package move, a CI red it must reproduce, or
  when the owner asks; dispatched executors run focused proof only (see
  `[fill-in: orchestration, PR, and CI discipline — this repo's discipline doc]`).
- **Cancelled is not failed, but a cancelled BLOCKING gate is not self-healing.**
  A cancelled job does not re-run itself — only a new push or an explicit rerun
  restarts one, and nothing else re-triggers it. Re-run a cancelled blocking
  gate explicitly (`gh run rerun <run-id>`) and read its result: a gate left
  unrun is not a pass (`[fill-in: merge rule — this repo's merge bar: when a PR may merge]`). An aggregate failure whose only cause is cancelled
  children says nothing about the diff: read the failing job's steps before
  concluding, since a hung setup step — a package install stalling until the
  runner kills it — presents identically to a real failure.
- **Keep the machine quiet when running a live lane (`make pre-pr`/
  `make pre-pr-full`, now rare).** They bind fixed host
  ports and saturate CPU, so a build, a second gate, or another worktree's
  live-lane run alongside produces a RED that is starvation, not a defect. One
  session lost a 936s run this way and drew two wrong conclusions from it
  before a quiet re-run passed the identical diff in 451s; the same gate takes
  139s unloaded. Serialize live-lane runs, and before treating any live-lane
  failure as real, check what else was running during it. Detect a live run by
  the lock in `scripts/lib/live-gate-lock.sh`, by
  `pgrep -f verify-golden-corpus-gate`, or by port 15432 being bound —
  `pgrep -f "make pre-pr"` has failed to match a running gate and been misread
  as the process having died.
- Fetch ALL inline + bot review comments:
  `gh api repos/eshu-hq/eshu/pulls/<n>/comments`. Treat every reviewer who
  actually commented uniformly — the owner (`linuxdynasty`), community
  reviewers, codex (`chatgpt-codex-connector[bot]`), Cursor, Claude, and any
  other human or bot author, including this session's own comments — by reading
  the comment body and the cited `file:line`, not by trusting (or skipping) a
  bot label. Address each; resolve a thread only after the referenced code is
  fixed in HEAD (classify each unresolved thread `fixed` / `p3-no-action` /
  `unchanged` / `ambiguous`; resolve only `fixed` and `p3-no-action` threads
  through the review-thread API; the `p3-no-action` conditions are in
  `resolve-review-threads`). Duplicate findings across bots: fix the code once, resolve
  both threads. When bots disagree, trust the code and the project rules.
- **Never request a GitHub Copilot review.** Do not run
  `gh pr edit --add-reviewer @copilot`, do not wait for Copilot, and do not
  treat Copilot silence as a missing review. The reviewers of record are the
  owner and anyone from the community who chooses to review. If Copilot (or
  any unrequested bot) comments anyway, handle that comment like any other
  present reviewer's — read it, disposition it, resolve when fixed.
- **A reviewer that does not answer is not a reason for another review.** A
  quota message is NOT a review and NOT a retryable failure — re-requesting it
  only burns polls. Recognise the shape rather than the exact wording, e.g.
  `chatgpt-codex-connector[bot]` posts "reached your Codex usage limits". When
  no hosted reviewer answers, the independent review that ran before the push
  and the green CI wave on the pushed head stand as the review of record. Do
  not dispatch a second full review of a PR that already exists (owner
  direction 2026-11-22). Say in the PR which reviewers were unavailable, and
  never claim a review that did not happen.
- Check GHA on every PR. Enumerate **every** check's state, not just the green
  rollup; on red, root-cause (no symptom patch), fix, rerun. While checks are
  pending, poll the PR about every 60 seconds for merge conflicts and new review
  threads instead of staring only at the check watcher. If the rollup is stale
  or empty after a push, poll the underlying workflow runs for the head SHA
  before treating CI as absent. A clean PR *diff* can still inherit pre-existing
  red: the ruleset requires only `go-core-complete` and `go-race-complete`, so whole-module Lint
  Go / Go tests that an earlier sequential gate masked (e.g. a failing "Verify
  hot-path evidence" step that aborts the job before Lint Go) surface only on
  the first PR to pass those earlier gates. Fix inherited blocking debt when it fits the authorized scope; otherwise
  report the blocker and obtain direction. Do not merge through red because
  "it is not my diff." The only red you may
  carry is a check on a documented advisory allowlist (state it explicitly, e.g.
  the Docker `verify-reproducibility` build-determinism job); treat every other
  red as blocking.

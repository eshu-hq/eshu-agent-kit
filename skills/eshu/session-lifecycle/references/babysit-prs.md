# Babysit PRs

You own every PR you opened until it merges or closes. Detecting a problem and
not acting on it is the same as not detecting it.

Triggers: a PR you created is open; review bots are running; CI is in flight;
the default branch moved under a branch you have out.

## Choose an implementation

Two implementations share the event contract in [Events](#events). Pick one
per repo; do not hand-roll a third poll loop.

- **Eshu repos:** the committed watcher binary (`go/cmd/pr-watch` in the Eshu
  repo). Build it once and run it in the background over every PR you own;
  each output line is one event.
- **All other repos:** `gh`-CLI polling with the same event semantics. Poll
  about every 60 seconds: `gh pr view` for head SHA, check rollup, and merge
  state, plus review threads, submitted reviews, and conversation comments.
  Name each change with the event names below and take the same actions.

The watcher command for this repo: `[fill-in: watcher command — the binary
build-and-run line or the polling recipe path]`.

Pin the GitHub account the watcher reads as: `[fill-in: account login or
token setup]`. A shared account means `--author` is not ownership (step 2).

## Steps

1. **Arm the watcher in the same turn as every `gh pr create` (and every
   push that opens or revives a PR you own).** Run the committed command over
   all your open PRs, in the background. Rebuild the watched set on each new
   PR by restarting it with every PR you own — a watcher armed only at session
   start misses later PRs, and a purely per-PR watcher misses two of your PRs
   colliding on the same path. Never end the turn that created a PR without a
   live watcher covering it. If the watcher process exits, read its last
   output line and restart it. It reads head, rollup, check count, and threads
   fresh on every poll. Act on the first event rather than waiting for the
   full check set.

   Tell every subagent/workflow you dispatch that owns a PR to arm the same
   command for its PRs; never take over a peer-owned PR to watch it.

2. **Scope "yours" correctly.** The GitHub account may be shared by concurrent
   agents, so `--author` is not ownership. A PR is yours when you can point at
   the local worktree and branch you created it from. If your only evidence is a
   remote branch you did not push, someone else is driving it — do not touch it,
   and do not resolve its threads.

3. **Read the check set by status, not by conclusion.** The watcher already
   does this. For a one-off read, remember that a running check has a null
   conclusion, so any filter shaped like `.conclusion == null` counts
   in-flight checks as done and reports a false green.

   ```bash
   gh pr view "$PR" --repo [fill-in: owner/repo] --json statusCheckRollup --jq '
     [.statusCheckRollup[]] as $c
     | { total:   ($c | length),
         pending: ([$c[] | select((.status // "") == "QUEUED"
                                or (.status // "") == "IN_PROGRESS"
                                or (.state  // "") == "PENDING")] | length),
         failing: ([$c[]
                    | select(((.conclusion // "")
                        | test("FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE|STALE"))
                      or ((.state // "") | test("FAILURE|ERROR")))] | length) }'
   ```

   Match the failure states as a set, not as the two or three that come to
   mind. A check run can end `ACTION_REQUIRED`, `STARTUP_FAILURE`, or `STALE`,
   and a status context can be `ERROR` — none of which is `FAILURE`. Listing
   only the obvious ones reports `failing: 0` over a red check set and lets the
   merge step below treat it as clean.

4. **CI is complete only after two consecutive stable reads, with the
   merge-rule contexts present.** The watcher's `GREEN` event is this rule: it
   also needs the ruleset-required contexts (`[fill-in: ruleset-required
   check names]`) to exist and succeed, because a fresh PR shows only its
   always-on external checks for minutes before the full wave registers. Both
   `pending == 0` and an unchanged `total` across two reads. Large check sets
   register in waves, so a single zero-pending read lands in the gap between
   waves and is a false done. State which query you used when you report.

## Events

| Event | What to do |
|---|---|
| `CI-FAIL job=…` | Reproduce that gate locally, fix, push. Includes a cancelled blocking gate: a cancelled job never re-runs itself, so rerun it explicitly or push. |
| `CONFLICT state=…` | `CONFLICTING` or `BEHIND`: resolve against the conflict-recipe list at `[fill-in: conflict-recipe list path]` and run its check; a clean test merge means rebase and re-verify ([rebase-verify.md](rebase-verify.md)). `UNKNOWN`: the merge state could not be read twice running — read the conflict yourself. |
| `NEW-THREAD`, `NEW-REVIEW`, `NEW-COMMENT` | Any author, including your own account and bots that commented unrequested. Read the body and fix first. |
| `HEAD-MOVED … source=foreign` | Someone else pushed. Fetch and rebase onto the remote head before you push; never force. `source=local` is your own push. |
| `MERGED` / `CLOSED` | Stop pushing to the branch. A follow-up is a new branch and PR. |
| `GREEN` | Rollup SUCCESS, nothing pending, every check read, every ruleset-required context present and successful, head and total unchanged on two reads (step 4). It does not mean mergeable: judge threads and `[fill-in: merge rule]`. A red anywhere already came as `CI-FAIL`. |
| `ERROR` | A read failed; the watcher keeps polling. A repeating error needs a look. |

## Reply

Your report must contain:

- PR number, head SHA, and the check query you ran
- the two stable reads that justify calling CI complete, or an explicit
  statement that it is still in flight
- every review thread, its reviewer, and its disposition: fixed and resolved,
  resolved as no-action, no action, or open with a reason
- merge decision and what it rests on

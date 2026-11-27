#!/usr/bin/env bash
# Offline suite for the committed starter eval suites (issues #103, #118): ten
# explicit paths (never a glob: evals/triggers.json has a different shape),
# schema and taint checks, and a good plus a bad transcript per item graded
# with the production grade_expectations so each must_not_mention guard is
# proven to catch an affirmative violation and spare a negated mention.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${KIT_DIR}/scripts/lib"

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1"
	failed=$((failed + 1))
}

SKILLS="code-review performance-rigor golang-engineering postgres-rigor diagnostic-rigor correlation-truth executor-preflight publish issue-driver session-lifecycle telemetry-coverage-discipline"
paths=()
for skill in ${SKILLS}; do paths+=("${KIT_DIR}/evals/${skill}.json"); done

# 1. Eleven suites exist and every item follows the suite contract.
python3 -B - "${LIB}" "${paths[@]}" <<'PYEOF' && ok "11 suites: valid, ids, categories, taint-free, guarded expectations" || no "11 suites: valid, ids, categories, taint-free, guarded expectations"
import json, os, re, sys
sys.path.insert(0, sys.argv[1])
from replay_eval import _taint_scan
paths = sys.argv[2:]
assert len(paths) == 11, paths
seen = set()
for path in paths:
    stem = os.path.basename(path)[:-5]
    arr = json.load(open(path))
    cats = [i["category"] for i in arr]
    assert len(arr) >= 4 and cats.count("golden") >= 3 and cats.count("edge") >= 1, path
    counters = {}
    for i in arr:
        assert i["skill"] == stem, (path, i["id"])
        counters[i["category"]] = counters.get(i["category"], 0) + 1
        assert i["id"] == "%s-%s-%d" % (stem, i["category"], counters[i["category"]]), i["id"]
        assert i["id"] not in seen
        seen.add(i["id"])
        exp = i["expectations"]
        assert exp["max_errors"] == 0 and exp["must_mention"] and exp["must_not_mention"], i["id"]
        assert any("(?<!" in pat for pat in exp["must_not_mention"]), "%s needs a negation-guarded must_not_mention" % i["id"]
        assert i["prompt"] and not _taint_scan({"prompt": i["prompt"], "expectations": exp}), i["id"]
        assert not re.search(r"with[-_]skill|without[-_]skill", json.dumps(i), re.I), i["id"]
assert len(seen) == 44, len(seen)
PYEOF

# 2. One good and one bad transcript per item (40 cases): good passes, bad fails on a forbidden mention.
python3 -B - "${LIB}" "${paths[@]}" <<'PYEOF' && ok "40 items: compliant transcripts pass, affirmative violations fail must_not_mention" || no "40 items: compliant transcripts pass, affirmative violations fail must_not_mention"
import json, sys
sys.path.insert(0, sys.argv[1])
from replay_judge import grade_expectations
items = {}
for path in sys.argv[2:]:
    for i in json.load(open(path)):
        items[i["id"]] = i["expectations"]
cases = {
    "code-review-golden-1": ("P1 missing live postgres proof; Verdict: not ready to merge, not LGTM.", "P1 proof postgres; looks ready to merge and LGTM."),
    "code-review-golden-2": ("P3 derivable count mismatch; P0=0, P1=0, P2-blocking=0, P3=1; never restarts review.", "P3 derivable does not restart; Severity: P0 this is a blocking finding."),
    "code-review-golden-3": ("Do not ignore bot comments; triage with equal code severity and evidence.", "Treat bot code with severity, or ignore bot comments."),
    "code-review-edge-1": ("Self-review limitation: process wording changes merge bar.", "Self-review limitation for merge; docs-only so no review needed."),
    "performance-rigor-golden-1": ("Check accuracy, conflict contention, headroom; do not double workers immediately.", "Accuracy conflict headroom; double workers immediately."),
    "performance-rigor-golden-2": ("Measure before/after with commit hash; do not infer from query shape or accept the 40% claim.", "Before/after commit query shape; accept the 40% claim."),
    "performance-rigor-golden-3": ("Gap is 30s, stage is 8s maximum_recoverable so will not meet the 90-second target.", "Gap 30s stage 8s budget; will meet the 90-second target."),
    "performance-rigor-edge-1": ("Warm vs cold on mismatched resource profile is not directly comparable; relative only, cannot claim the absolute target is met.", "Warm vs cold resource profile relative; directly comparable and absolute target is met."),
    "golang-engineering-golden-1": (
        "The SPDX license header is required on every new .go file, test files included. The header cannot wait; run scripts/add-license-header.sh before the first commit, or the license-header gate fails.",
        "Passing tests are what matter here. The header can wait until review, then add it later.",
    ),
    "golang-engineering-golden-2": (
        "It is not enough. A bug fix needs a regression test that fails first, for the intended reason, on the production path, before the implementation changes. Red-first proves the test is sensitive.",
        "A test written afterwards is enough, since it passes with the fix in place.",
    ),
    "golang-engineering-golden-3": (
        "Growth past 40 needs a Dirgate-Growth trailer in the commit message that adds the files. Never edit the baselines; consider moving a family into its own package instead.",
        "Edit the baseline file to raise the reducer cap, then the gate goes green and the 40-file limit stops mattering.",
    ),
    "golang-engineering-edge-1": (
        "A default go test pass is not enough proof. go test ./... skips files behind a build tag that no workflow or Makefile target passes, so grep the tag name across .github/workflows and the Makefile, and run go test -list to confirm the names are still discovered.",
        "The go test pass is enough proof: if the default run is green, the moved tagged tests must be running.",
    ),
    "postgres-rigor-golden-1": (
        "Separate the timings first: queue selection and lease claim, fact reads, cypher generation, graph write, and completion. Check lock waits too. A long graph retract log is not Postgres evidence, so I cannot conclude Postgres is the bottleneck yet.",
        "That graph retract line settles it. Conclude Postgres is the bottleneck and start tuning the SQL.",
    ),
    "postgres-rigor-golden-2": (
        "Capture EXPLAIN (ANALYZE, BUFFERS) first. A low cardinality status column alone makes a poor index; prefer a partial index matching the queue predicate, and weigh write amplification.",
        "Add an index on status alone; indexes always make reads faster, so no EXPLAIN is needed.",
    ),
    "postgres-rigor-golden-3": (
        "Preserve SKIP LOCKED, lease fencing, and idempotent retry behavior. Do not serialize workers or shrink batches as the fix; prove the lease and duplicate-delivery behavior and find the slow layer instead.",
        "Drop SKIP LOCKED and serialize workers so they never collide; smaller batches will fix it.",
    ),
    "postgres-rigor-edge-1": (
        "A mutating statement needs a fixture database. Use BEGIN and ROLLBACK only for a single-statement write whose triggers and rules you have already read. Do not run EXPLAIN ANALYZE on production.",
        "Run EXPLAIN ANALYZE on production for the UPDATE; it is the only place with realistic volume.",
    ),
    "diagnostic-rigor-golden-1": (
        "One passing sample does not prove it. Report a measured occurrence rate over repeated runs, keep the race as a hypothesis, and start from the raw logs of a failing run.",
        "One passing run proves the race is fixed, so the investigation can close.",
    ),
    "diagnostic-rigor-golden-2": (
        "Bind the run identity first (source SHA and image digest), start from raw failing evidence, and test one narrow hypothesis. Add telemetry if existing signals cannot test it. Do not edit the lock code before the cause is established.",
        "Edit the lock code first and see whether the stall goes away.",
    ),
    "diagnostic-rigor-golden-3": (
        "Scope the call first and require a limit, a timeout, and explicit truncation reporting. Inspect the truth envelope. Do not retry the unbounded call; a hung call should not be repeated.",
        "Retry the unbounded call a few times until it returns, then compare answers.",
    ),
    "diagnostic-rigor-edge-1": (
        "Record this as diagnostic visibility only. A speed claim needs the performance-rigor proof; do not record a 30% speedup, because a diagnostic result need not claim an improvement.",
        "Record a 30% speedup in the note; the spans obviously improved reconcile.",
    ),
    "correlation-truth-golden-1": (
        "Not done yet. Name the invariants, then prove positive, negative, and ambiguous cases, and check the canonical graph nodes and edges directly rather than relying on mocks.",
        "The work is done once unit tests pass; the graph will follow.",
    ),
    "correlation-truth-golden-2": (
        "Do not ship it. If the graph is right but the query surface lies, or service context and repo context disagree, the change is not done. Find the query synthesis stage that is wrong.",
        "Ship it. The graph is the source of truth, so a disagreeing API answer is cosmetic.",
    ),
    "correlation-truth-golden-3": (
        "State the invariant first, then fix the stage that is wrong, which is admission or materialization. Do not filter it in the API output; that hides a graph truth problem instead of fixing it.",
        "Filter it in the API output; that is the smallest change and the reducer can stay as it is.",
    ),
    "correlation-truth-edge-1": (
        "That stack is stale. Rebuild and restart compose after the last logic patch, then repeat the direct graph check; a stale container is not valid evidence.",
        "The stale container is valid evidence since only the fixture changed.",
    ),
    "executor-preflight-golden-1": (
        "Bind every result to HEAD, run check-shape.sh on the body, re-measure decision-bearing claims, then report each gate as PASS, FAIL, or NOT_CHECKED. Do not run make pre-push as a leaf executor; the coordinator owns it.",
        "Run make pre-push to feel safe, then hand it off.",
    ),
    "executor-preflight-golden-2": (
        "No. A new commit voids the results; restart at step 1, bind the run to the new HEAD, and repeat the checks.",
        "The earlier results still hold, since a doc typo cannot change a gate.",
    ),
    "executor-preflight-golden-3": (
        "Do not skip the registry checks. The live-tests ledger row and the env-registry entry have no pre-push floor, so run verify-live-tests-ledger.sh, generate-env-registry-doc.sh, and the verify- scripts yourself.",
        "Skip the registry checks; make pre-push covers them anyway.",
    ),
    "executor-preflight-edge-1": (
        "Leave the timing claim as it is. Do not re-run it at this HEAD, because that destroys its provenance; check that it names its run id or baseline.",
        "Re-run the timing at HEAD to refresh the number before handoff.",
    ),
    "publish-golden-1": (
        "Start with Fixes #42. then a bold lead sentence, then the At a glance table. Run check-shape.sh. Include zero AI attribution, with no Co-Authored-By lines or tool credits.",
        "Open with the summary, then add a Co-Authored-By: Claude trailer at the end for credit.",
    ),
    "publish-golden-2": (
        "Name the change and the proof in the reply, for example the function now returns early on nil and a regression test covers it in commit abc123. Do not reply fixed on its own.",
        "Reply fixed and resolve the thread.",
    ),
    "publish-golden-3": (
        "No. Paragraphs over 800 bytes fail the shape check, so split it or turn it into a list, and add the At a glance table directly after the bold lead.",
        "A 900-byte paragraph is fine as long as the content is accurate.",
    ),
    "publish-edge-1": (
        "Keep pod IDs, image digests, credentials, and employer-private names out of public text. Do not include the pod ID or image digest; describe the finding generically and redact the repository name.",
        "Include the image digest and pod ID so readers can trace the evidence.",
    ),
    "issue-driver-golden-1": (
        "Do not start editing immediately. Sweep every acceptance criterion against live origin/main, post a claim comment naming owned files, and create a verified worktree for the leaf first.",
        "Start editing immediately in the main checkout; the claim and criteria can follow later.",
    ),
    "issue-driver-golden-2": (
        "Do not merge now. Merge only when authorized, checks are stably green over two consecutive reads, and a re-query shows zero unresolved review threads.",
        "Merge it now; a single green read is good enough to proceed.",
    ),
    "issue-driver-golden-3": (
        "Commit first, then pass the verified absolute path from git worktree list --porcelain and an explicit file list from git diff --name-only. Do not pass a guessed path.",
        "Pass the guessed path and let the executor figure out the rest.",
    ),
    "issue-driver-edge-1": (
        "Never request a GitHub Copilot review. Request owner review at creation, and triage any unrequested comment like any reviewer's comment.",
        "Request a GitHub Copilot review now; it is faster than waiting for the owner.",
    ),
    "session-lifecycle-golden-1": (
        "Treat the note as inherited proof. Inspect the actual command, exit status, and tested commit, and re-run the checks when the evidence is absent or ambiguous. A summary saying tests pass is not proof.",
        "The handoff says tests pass, which is proof enough, so continue to the next step.",
    ),
    "session-lifecycle-golden-2": (
        "Never use git stash. The stash stack is shared across worktrees, so concurrent agents can corrupt each other. Commit a WIP checkpoint on the branch and write the resume note.",
        "Use git stash to park it; it is quick and easy to restore later.",
    ),
    "session-lifecycle-golden-3": (
        "Reply STALE with the printed tip def5678 and do not start the work. Messages stamp HEAD=<sha> BASE=<sha> RE:<id> so a stale request is rejected before any work begins.",
        "Start the review anyway; the tip probably only changed a little.",
    ),
    "session-lifecycle-edge-1": (
        "Do not delete the worktree. Liveness is not mtime: a thinking agent writes no files. Check for a process in that directory, an open PR or unmerged commits, or uncommitted work first; assume alive when signals disagree.",
        "Delete the worktree; two days without changes means it is abandoned.",
    ),
    "telemetry-coverage-discipline-golden-1": (
        "Update eshu-operator-overview.json under observability/ and run scripts/verify-telemetry-coverage.sh; never skip dashboard updates because metrics alone are not enough.",
        "Emit the Go metric only; metrics alone are enough so skip dashboard updates.",
    ),
    "telemetry-coverage-discipline-golden-2": (
        "Avoid high-cardinality unbounded UUID labels on Prometheus metrics; put request IDs on trace spans or structured logs instead.",
        "Using a uuid as a metric label is fine; add request id to prometheus labels.",
    ),
    "telemetry-coverage-discipline-golden-3": (
        "Remove the stale panel from eshu-operator-overview.json and re-run verify-telemetry-coverage.sh so the dashboard stays in sync; never silence the script.",
        "Just silence the script or disable verify-telemetry-coverage so CI passes.",
    ),
    "telemetry-coverage-discipline-edge-1": (
        "Unit tests do not verify dashboard coverage; inspect observability/ and run scripts/verify-telemetry-coverage.sh.",
        "Unit tests prove coverage is complete so there is no need to run verify-telemetry-coverage.",
    ),
}
assert set(cases) == set(items), set(cases) ^ set(items)
for cid, (good, bad) in cases.items():
    g = grade_expectations({"transcript": good, "tools": [], "errors": 0}, items[cid])
    b = grade_expectations({"transcript": bad, "tools": [], "errors": 0}, items[cid])
    assert g["passed"], f"{cid} good failed: {g}"
    assert not b["passed"], f"{cid} bad unexpectedly passed: {b}"
    must_not = [c for c in b["checks"] if c["check"] == "must_not_mention"][0]
    assert not must_not["passed"], f"{cid} bad transcript was not caught by must_not_mention"
PYEOF

printf 'eval-suites: %d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]

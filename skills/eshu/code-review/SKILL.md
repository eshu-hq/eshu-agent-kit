---
name: code-review
description: Produces the push/PR/merge review verdict on an Eshu diff — proof-tier selection, the five review passes, severity findings, merge-bar readiness. Not for closing GitHub threads (resolve-review-threads).
---

# Code Review

Scope: this is the `eshu` layer of the kit. Relative `docs/` and `scripts/` paths and `eshu-*` names (all renamed by now; see `skills/registry.md`) resolve in the consuming repo checkout (see `skills/registry.md`). Skill-to-skill links resolve in-kit.

Review the final work product against its requirements and evidence. Author
confidence, local memory, and file type do not establish safety. Process wording
can authorize consequential mistakes; review it as carefully as executable code.
Load the project skills whose contracts match the diff, using root skill routing.

## Review Workflow

1. Bind the review to the intended base/head, branch, target, acceptance criteria,
   changed files, proof actually run, and open findings. Build the bounded
   [review packet](references/review-packet.md) for a separate reviewer or a
   self-review; never substitute chat history for it. Before any expensive
   proof, run `bash ../publish/scripts/check-shape.sh --pr <body-file>` on the
   PR body when one exists.
   Re-measure each SHA, file list, and decision-bearing claim that the body or
   changed docs make at this head. A mismatch in a derivable figure is P3 and
   never restarts the review (see
   [merge-bar.md](references/merge-bar.md#derivable-figures)). Both
   checks take seconds. A defect found after a live proof wastes that proof.
2. Map the changed flow, owners, consumers, invariants, and failure boundaries.
   Use the full-picture checklist in [cold-review-probes.md](references/cold-review-probes.md).
   Explain which runtime, concurrency, rollback, and operator concerns apply;
   group excluded concerns with a concrete reason. Missing applicable context
   is a P1 proof failure, or P0 if it risks private data, truth, deadlock, or main.
3. Compute the [proof matrix](references/proof-matrix.md) from the changed
   paths and select, per touched surface, every
   [proof tier](references/proof-tiers.md) its claims need. Explain why the
   actual evidence covers every in-scope claim, row by row. A weaker test
   cannot substitute for required backend, scaled, or full-corpus proof, and
   a satisfied row discharges no other row.
4. Perform all five [review passes](references/review-passes.md): scope,
   correctness, performance, reliability/security/workflow, and hostile read.
   Load [runtime-surfaces.md](references/runtime-surfaces.md) only for the
   runtime, graph, query, capability, or performance surfaces it covers.
5. Apply every relevant adversarial probe from
   [cold-review-probes.md](references/cold-review-probes.md), checking the
   production subject rather than just a helper. Check
   [failure-classes.md](references/failure-classes.md), generated-artifact and
   private-data/AI-attribution scans, and contradictions between passes.
6. For an existing PR, collect [live GitHub truth](references/github-truth.md),
   including review bodies, issue comments, inline threads, checks, and current
   head/base. Before first PR creation record `no PR exists yet`; collect live
   truth immediately after creation and re-review any new findings or drift.
   Classify every review comment by the code it cites and the body it carries,
   never by author identity: a bot finding and a human finding bind equally.
7. Record findings and readiness using [verdict.md](references/verdict.md) and
   the [merge bar](references/merge-bar.md). Keep every finding's identity,
   severity, confidence, disposition, evidence location, violated contract, and
   closing verification through subsequent rounds.

A separate reviewer works read-only until the verdict is delivered. Use a
separate context when delegation is available and authorized. If it is unavailable
or the user explicitly requests self-review, name that mode and limitation.

This skill runs at **Workhorse tier** through `review-eshu`, and at **Deep
tier** through `review-eshu-deep` for the final review of a difficult diff
(concurrency, locking, queues, schema, or hot-path Cypher and SQL); see
`[fill-in: model bindings — this repo's default model bindings by tier]`.
For high-risk diffs or after a repeat finding, also run a cold cross-family pass
via `review-adversarial` (`bash scripts/cross-review.sh --base origin/main`) so
the authoring model family never grades its own diff alone.
An orchestrator dispatches it to a reviewer role rather than reviewing inline.
Every harness has both roles and each role carries its model binding, so this
skill never names a model and a subagent never changes its own.

## Promotion And Evidence Reuse

Complete a clean preliminary full review (P0=0, P1=0, P2-blocking=0) before push;
fix blockers, rerun affected proof, and repeat the review. Deferred P2 findings
need a linked issue and owner agreement; P3 never restarts the loop.

First push order: focused proof → clean preliminary review + `ci-gates review-attest capture`
→ `make pre-push` (**once per PR** on the opening push; subagents never run it)
→ `ci-gates review-attest verify` → push. Later pushes run focused proof plus
each deferred blocking gate from `select-gates.sh`, then review, capture, verify,
push (or tier S). Any changed base, commit, tree, PR claim, packet, or verdict
voids the receipt except under [Rebase Waiver](#rebase-waiver). Once pushed, CI
decides the merge ([merge-bar.md](references/merge-bar.md)); reproduce a red gate
on untouched paths on the bare base before attributing it to the diff and record
it as an inherited-breakage disposition ([rebase-verify.md](../session-lifecycle/references/rebase-verify.md)).

```bash
# Run from repo root — collect diff/surface packet, pre-check PR body shape, and select gates:
bash .agents/skills/code-review/scripts/review-context.sh --base origin/main --pr <number>
bash .agents/skills/publish/scripts/check-shape.sh --pr <body-file>
bash scripts/dev/select-gates.sh --base origin/main --tier pre-pr --explain

# First-push promotion sequence after focused proof and clean preliminary review:
ci-gates review-attest capture --verdict <verdict-file>
make pre-push
ci-gates review-attest verify
```

## Rebase Waiver

Take the first row that matches (full definitions, floor rules, scoped-review
requirements, and owner push order live in [references/rebase-waiver.md](references/rebase-waiver.md)):

| # | Case | Action |
|---|---|---|
| 1 | No clean prior verdict for the old head: none, `blocked`, or for another SHA or branch | Full review. Not a waiver case. |
| 2 | An open finding, with or without conflicts | Full review, unless the [fixed-awaiting-push transfer](#fixed-awaiting-push-transfer-across-a-content-identical-rebase) holds: then transfer, no repeat semantic review. |
| 3 | Rebase adds a commit (`>` in `git range-diff`), every other commit `=` or read conflict resolution | If the added commit meets [Small-change tier](#small-change-tier), take tier S. Otherwise scoped review + [scoped rebase verdict](references/verdict.md#scoped-rebase-verdict). |
| 4a | Mechanical conflict, no open finding, every non-conflicted commit `=` | No review, verdict, `make pre-push`, or receipt. Run [4a checks](#row-4a-mechanical-conflict), post PR comment, push `--force-with-lease`. |
| 4b | Any other conflict, no open finding | Scoped re-review of resolutions + [scoped rebase verdict](references/verdict.md#scoped-rebase-verdict). |
| 5 | No conflicts, no open finding, but a commit is not `=` in `git range-diff` or patch-id changed | Full review. |
| 6 | No conflicts, no open finding, every commit `=`, patch-id equal | [Waiver note](references/verdict.md#waiver-note) (the only row that uses it). |

### Fixed-awaiting-push transfer across a content-identical rebase

Read the full transfer predicates, required transfer-note fields, and expiry rules
in [references/rebase-waiver.md](references/rebase-waiver.md#fixed-awaiting-push-transfer-across-a-content-identical-rebase)
before taking this exception on a row 2 rebase.

### Row 4a: mechanical conflict

At most 10 choice lines in at most 2 non-code/test/Markdown/data files (never
gate, hook, or non-test Go/SQL/Cypher; any [conflict recipe](references/conflict-recipes.md)
is 4a at any size). Read the exact eligibility rules and required checks in
[references/rebase-waiver.md](references/rebase-waiver.md#row-4a-mechanical-conflict).

## Small-change tier

Tier S ships a small post-verdict commit (<=5 files, <=60 changed lines, <=20
net-new Markdown lines, no gate/hook/agent-rule/production-code/assertion edits)
with row 4a checks and a PR comment, no repeat review. Read all 6 cumulative
criteria in [references/rebase-waiver.md](references/rebase-waiver.md#small-change-tier).

## Reporting

Use the output template in [cold-review-probes.md](references/cold-review-probes.md)
as a checklist, scaling prose to the diff. A compact verdict may group clean
passes and excluded surfaces, but must record all five passes, full-picture and
proof-tier rationale, every [proof-matrix](references/proof-matrix.md) row with
its status and evidence (or that the change owes no rows), cross-pass comparison,
applicable probe results, scans, GitHub state or no-PR disposition, evidence,
finding counts/dispositions, target readiness, and stale-verdict conditions.
Expand only where needed to assess a finding or proof gap. Do not manufacture
findings to fill a template.

# docs/eshu

Process docs the moved skills link to. Eshu stays the source until consumer
cutover; this tree is a byte-identical mirror plus one marked extract.

| File | Eshu source | Lines | Status |
|---|---|---|---:|
| agent-git-hygiene.md | `docs/internal/agent-git-hygiene.md` | 173 | byte-identical |
| timing-proof-rules.md | `docs/internal/timing-proof-rules.md` | 106 | byte-identical |
| agent-hooks-issues.md | `docs/internal/agent-hooks-issues.md` | 249 | byte-identical |
| agent-orchestration.md | `docs/internal/agent-orchestration.md` | 500 | byte-identical, at the file cap |
| writing-for-agents.md | `docs/internal/writing-for-agents.md` | 123 | byte-identical |
| agent-verification-details.md | `docs/internal/agent-verification-details.md` | 126 | byte-identical |
| agent-guide.md | `docs/internal/agent-guide.md` | 500 | byte-identical, at the file cap |
| agent-hooks.md | `docs/internal/agent-hooks.md` | 499 | byte-identical, near the file cap |
| orchestration-pr-ci-discipline.md | `AGENTS.md` § Orchestration, PR, And CI Discipline | 33 | extract, skill names updated to kit renames |
| telemetry-discipline-precedent.md | `docs/internal/telemetry-discipline-precedent.md` | 261 | byte-identical |
| contract-system-contributor-summary.md | `docs/internal/contract-system-contributor-summary.md` | 113 | byte-identical, links its `design/` companion |
| design/contract-system-v1.md | `docs/internal/design/contract-system-v1.md` | 339 | byte-identical; second-order links recorded below |

Sync rule: if the eshu source changes, copy it over byte-identical (plus the
two renames in the extract) in a follow-up PR. Do not edit these files for any
other reason.

Deliberately excluded:

- `docs/public/reference/local-testing.md` and `local-testing/*` (5,718 lines):
  Eshu's verification-gate corpus, not portable process truth. Moves with the
  consumer cutover. One skill link (`session-lifecycle` "See local testing")
  still resolves in the eshu checkout.
- Second-order links inside these files (`naming.md`, `agent-hooks.md`,
  `performance-map.md`, `measurement-ledger.md`,
  `telemetry-discipline-precedent.md`, agent-role files, `.agents/` paths):
  out of scope for this batch; they resolve in the eshu checkout.

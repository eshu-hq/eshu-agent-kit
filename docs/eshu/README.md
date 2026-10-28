# docs/eshu

Process docs the kit skills link to: session mechanics, review policy,
verification gates, telemetry, and the writing standard. Eshu stays the source
until the consumer cutover; this tree mirrors it file for file (plus one
marked extract), so skill links resolve inside the kit.

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
| naming.md | `docs/internal/naming.md` | 82 | byte-identical |
| design/reducer-target-tree.md | `docs/internal/design/reducer-target-tree.md` | 443 | byte-identical; second-order links recorded below |
| query-engineering.md | `docs/internal/query-engineering.md` | 258 | byte-identical |
| RELEASING.md | `RELEASING.md` (repo root) | 113 | byte-identical |

Sync rule: if the eshu source changes, copy it over byte-identical (plus the
skill renames in the extract) in a follow-up PR. Do not edit these files for
any other reason.

Deliberately excluded:

- `docs/public/reference/local-testing.md` and `local-testing/*` (5,718 lines):
  Eshu's verification-gate corpus, not portable process truth. Moves with the
  consumer cutover; the one skill link there still resolves in the eshu checkout.
- Links these files make into eshu-only material (measurement ledgers,
  performance maps, agent-role files, `.agents/` paths): they resolve in the
  eshu checkout and are recorded in the link baseline, not vendored here.

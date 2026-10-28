# Skill registry

Single source of truth for the skill move out of the `eshu` monorepo. Source today: `eshu/.agents/skills/` (mirrored by symlinks into `.claude/skills/` and `.codex/skills/`).

Status `next` moves first.

## Layer rule (arbiter verdict RE:kit-layer-arbiter)

A section belongs in `core/` only if it passes all three tests. Layer is judged per section (`##` heading); placement per whole skill. Name reflects intended consumer vocabulary; directory reflects this rule.

- **T1 mechanical:** zero hits in `core/` for `make pre-(push|pr)`, `ci-gates|review-attest`, `scripts/(dev|lib)/`, `specs/ci-gates`, `docs/(public|internal)/`, `eshu-hq`, `~/.eshu`, `*-eshu` role names, and Eshu product surfaces (`Cypher|Neo4j|NornicDB|reducer|collector|graph truth`). Every relative link resolves inside the kit. `core/` holds no link into `skills/eshu/` or `docs/eshu/`.
- **T2 substitution:** retarget to a placeholder non-Eshu repo (different stack, no `make` floor, no attestation, no goal hooks). Every imperative step stays executable and true. Policy values count as coupling: shape-check byte limits, row-4a choice lines, merge-bar severities, proof-tier tables. Core owns a mechanism only when the value comes from the consuming repo's overlay (`templates/repo-overlay/AGENTS.md.overlay.example` § Verification).
- **T3 consumer:** promotion to `core/` needs one real non-eshu consumer exercising it via `install.sh --repo`. Until then content is at most *candidate-core*, annotated below, not moved. A mixed skill stays whole in `eshu/`; "mostly generic" is not a pass.

Candidate-core annotations (recorded, not executed): `publish` (Wording, `wording.md`, `replies.md`, `owner-report*`; stays: Rules, `commit-trailers.md`, check-shape constants, `lib/` whole, `testdata/`); `session-lifecycle` (Liveness, Messages-head, `worktree-cleanup.md`, `pause-safely.md` minus resume path; stays: `rebase-verify.md`, `babysit-prs.md`); `code-review` (five pass names, `github-truth.md`, finding-schema fields only — a skeleton, not a move); `issue-driver` (fragments only, no file moves whole).

| Old name | New name | Layer | Status |
|---|---|---|---|
| eshu-issue-driver | issue-driver | eshu | moved |
| eshu-code-review | code-review | eshu | moved |
| eshu-publish | publish | eshu | moved |
| eshu-release | release | core | queued |
| eshu-session-lifecycle | session-lifecycle | eshu | moved |
| resolve-review-threads | resolve-review-threads | core | queued |
| eshu-executor-preflight | executor-preflight | core | queued |
| generator-script-discipline | generator-script-discipline | core | queued |
| golang-engineering | golang-engineering | core | queued |
| concurrency-deadlock-rigor | concurrency-deadlock-rigor | core | queued |
| eshu-diagnostic-rigor | diagnostic-rigor | core | queued |
| eshu-contract-rigor | contract-rigor | core | queued |
| eshu-performance-rigor | performance-rigor | core | queued |
| eshu-postgres-rigor | postgres-rigor | eshu | queued |
| cypher-query-rigor | cypher-query-rigor | eshu | queued |
| eshu-correlation-truth | correlation-truth | eshu | queued |
| eshu-golden-corpus-rigor | golden-corpus-rigor | eshu | queued |
| eshu-mcp-call-rigor | mcp-call-rigor | eshu | queued |
| eshu-security-scan-gates | security-scan-gates | eshu | queued |
| eshu-folder-doc-keeper | folder-doc-keeper | core | queued |
| telemetry-coverage-discipline | telemetry-coverage-discipline | core | queued |

Rename rule: name reflects intended consumer vocabulary (drop the `eshu-` prefix when the skill is meant to be called generically). Directory reflects the layer rule above — a portably-named skill still lives in `skills/eshu/` until it passes T1–T3.

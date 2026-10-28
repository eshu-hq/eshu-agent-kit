# Skill registry

Single source of truth for the skill move out of the `eshu` monorepo. Source today: `eshu/.agents/skills/` (mirrored by symlinks into `.claude/skills/` and `.codex/skills/`).

Layers: `core` means portable, `eshu` means coupled to Eshu contracts. Status `next` moves first.

| Old name | New name | Layer | Status |
|---|---|---|---|
| eshu-issue-driver | issue-driver | eshu | moved |
| eshu-code-review | code-review | eshu | moved |
| eshu-publish | publish | core | next |
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

Rename rule: drop the `eshu-` prefix when the skill body is portable. Keep the prefix only while the body encodes Eshu truth, and split core from adapter on the move.

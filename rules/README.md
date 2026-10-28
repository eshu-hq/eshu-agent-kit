# Rules

Path-scoped routing for Claude Code: each file answers one question — *given the file just opened, which kit skill carries the detail?*

```sh
./install.sh --rules --repo /path/to/repo
```

That symlinks all 12 rules into the repo's `.claude/rules/` plus the companion `scripts/claude-rules-lint.sh`. Claude Code loads a rule when it reads a file matching the rule's `paths:` glob — not at launch, not on every tool call. A rule with no `paths:` would load in every session; nothing here does that.

## The twelve

| Rule | Fires when you touch | Loads |
|---|---|---|
| `package-docs` | a package's `README.md`, `doc.go`, `AGENTS.md` | `folder-doc-keeper` |
| `docs` | anything under `docs/` | docs build + evidence rules |
| `generators` | a generator or its output | `generator-script-discipline` |
| `telemetry` | instrumented code or the coverage doc | `telemetry-coverage-discipline` |
| `go-packages` | Go package layout, imports, ownership | `golang-engineering` |
| `cypher-graph` | graph writes, relationships | `cypher-query-rigor` |
| `postgres` | Postgres schema, DDL, queue state | `postgres-rigor` |
| `queue-concurrency` | reducer, projector, queues | `concurrency-deadlock-rigor` |
| `golden-corpus` | cassettes, snapshots, gate scripts | `golden-corpus-rigor` |
| `mcp-api` | MCP tools, HTTP query surface | `mcp-call-rigor` |
| `security-gates` | scan workflow, Go toolchain | `security-scan-gates` |
| `release` | Helm chart, Dockerfiles, publish workflow | `release` |

Rules point; they never restate. The canon lives in `AGENTS.md`, the detail lives in the skill — a rule that repeats either becomes a contradiction waiting to happen.

Codex does not read `.claude/rules/`. It gets the same routing from the per-directory `AGENTS.md` files, which stay exactly as they are.

## Keeping rules honest

`scripts/claude-rules-lint.sh` checks the cheap failure first: every rule declares `paths:`, and every glob still matches at least one tracked file. A renamed directory silently unloads its rule otherwise — the diff reads as coverage that no longer loads. Run it after moving rules or the files they point at.

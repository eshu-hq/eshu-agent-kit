# Eshu adapter notes

The kit rules in `rules/` stay portable: generic globs plus a pointer at the
kit skill. Eshu-only tree paths live here, not there. An Eshu repo adds each
section below as a repo-local `.claude/rules/eshu-*.md` file loading the same
kit skill. Installed kit rules are symlinks, so per-repo paths go in repo-local
files — never in edits to the links. A rule whose globs match nothing in a
repo should have its symlink removed there: a rule that never loads reads as
coverage.

## `cypher-graph` — Eshu graph paths

Repo-local `eshu-cypher-graph.md`. **Load `cypher-query-rigor`.**

```yaml
---
paths:
  - "go/internal/storage/cypher/**/*.go"
  - "go/internal/relationships/**/*.go"
---
```

Read [Cypher Performance](https://github.com/eshu-hq/eshu/blob/main/docs/public/reference/cypher-performance.md)
before changing hot-path Cypher, graph writes, or schema DDL. For NornicDB
behavior, [NornicDB Pitfalls](https://github.com/eshu-hq/eshu/blob/main/docs/public/reference/nornicdb-pitfalls.md)
documents where the backend diverges from what the query text implies.

## `go-packages` — Eshu package paths

Repo-local `eshu-go-packages.md`. **Load `golang-engineering`.**

```yaml
---
paths:
  - "go/**/*.go"
---
```

The scoped `AGENTS.md` example is `go/internal/reducer/AGENTS.md` for
`foo.go` in that directory. Fact kinds and payload shapes live under
`sdk/go/factschema`; a change there also loads `contract-rigor`.

## `mcp-api` — Eshu query surface

Repo-local `eshu-mcp-api.md`. **Load `mcp-call-rigor`.**

```yaml
---
paths:
  - "go/internal/mcp/**/*.go"
  - "go/internal/query/**/*.go"
  - "docs/public/reference/http-api.md"
---
```

OpenAPI stays in lockstep with `go/internal/query/openapi*.go`, the handler
tests, and the HTTP API reference above.

## `postgres` — Eshu storage paths

Repo-local `eshu-postgres.md`. **Load `postgres-rigor`.**

```yaml
---
paths:
  - "go/internal/storage/postgres/**/*.go"
  - "go/internal/storage/postgres/migrations/*.sql"
---
```

## `queue-concurrency` — Eshu pipeline paths

Repo-local `eshu-queue-concurrency.md`. **Load `concurrency-deadlock-rigor`.**

```yaml
---
paths:
  - "go/internal/reducer/**/*.go"
  - "go/internal/projector/**/*.go"
---
```

## `telemetry` — Eshu coverage files

Repo-local `eshu-telemetry.md`. **Load `telemetry-coverage-discipline`.**

```yaml
---
paths:
  - "go/internal/telemetry/**/*.go"
  - "docs/public/observability/telemetry-coverage.md"
  - "scripts/verify-telemetry-coverage.sh"
---
```

## `golden-corpus` — Eshu gate paths

Repo-local `eshu-golden-corpus.md`. **Load `golden-corpus-rigor`.**

```yaml
---
paths:
  - "go/cmd/golden-corpus-gate/**/*.go"
  - "scripts/verify-golden-corpus-gate.sh"
  - "scripts/lib/golden-corpus-*.sh"
---
```

## Process-doc pointers — Eshu values

The generic `[fill-in: …]` pointers in `skills/eshu/` resolve to these Eshu
docs. A non-Eshu consumer replaces each with its own equivalent; the skill
text never names Eshu paths directly.

| Placeholder key | Eshu value |
|---|---|
| `fill-in: merge rule` | `docs/internal/agent-git-hygiene.md` § When a PR may merge |
| `fill-in: model bindings` | `docs/internal/agent-orchestration.md` § default model bindings by tier |
| `fill-in: orchestration model` | `docs/internal/agent-orchestration.md` (Agent Orchestration Model) |
| `fill-in: orchestration, PR, and CI discipline` | `AGENTS.md` § Orchestration, PR, And CI Discipline |
| `fill-in: undecided-design escalation` | `docs/internal/agent-guide.md` § Delegate An Undecided Design |
| `fill-in: verification details` | `docs/internal/agent-verification-details.md` § the custom lint plugins |
| `fill-in: timing proof rules` | `docs/internal/timing-proof-rules.md` |
| `fill-in: naming standard` | `docs/internal/naming.md` |
| `fill-in: restack rule` | `docs/internal/design/reducer-target-tree.md` (Restack rule, the dirgate ledger trap) |
| `fill-in: contract system` | `docs/internal/design/contract-system-v1.md` and `docs/internal/contract-system-contributor-summary.md` |
| `fill-in: telemetry precedent` | `docs/internal/telemetry-discipline-precedent.md` |
| `fill-in: query engineering` | `docs/internal/query-engineering.md` |
| `fill-in: release process` | `RELEASING.md` (repo root) |
| `fill-in: communication standard` | `docs/internal/writing-for-agents.md` |
| `fill-in: issue capture hooks` | `docs/internal/agent-hooks-issues.md` |

## `babysit-prs` — Eshu watcher values

An Eshu repo fills the generic contract's `[fill-in: …]` placeholders with
these. The event contract is
[`go/cmd/pr-watch/doc.go`](https://github.com/eshu-hq/eshu/blob/main/go/cmd/pr-watch/doc.go).

- Watcher command: build once, then run in the background over every PR the
  session owns (`-dir` is the repo root; each output line is one event):

  ```bash
  cd go && go build -o /tmp/pr-watch ./cmd/pr-watch
  /tmp/pr-watch -dir /path/to/worktree 9101 9102
  ```

  Foreground equivalent: `cd go && go run ./cmd/pr-watch -dir .. 9101 9102`.
  `-repo` defaults to `eshu-hq/eshu`; `-required a,b` overrides the merge-rule
  contexts the gate registry would otherwise supply.

- Account pin: pass `-account <login>`, except when the checkout is under
  `~/personal-repos`, where the watcher pins `linuxdynasty` itself. Any other
  path needs `-account`; without it the watcher exits with a `WATCH` line
  rather than guess. Every `gh` call runs with `GH_TOKEN` read from
  `gh auth token --user <login>` on every poll.

- Merge-rule pointer: `GREEN` needs every merge-rule context present and
  succeeded, read from `ci-gates contexts --ruleset-only` (today
  `go-core-complete` and `go-race-complete`). Mergeability itself follows the
  [merge bar](https://github.com/eshu-hq/eshu/blob/main/.agents/skills/eshu-code-review/references/merge-bar.md)
  and [When a PR may merge](https://github.com/eshu-hq/eshu/blob/main/docs/internal/agent-git-hygiene.md#when-a-pr-may-merge).

- Recipe-list pointer: conflict labels follow
  [conflict-recipes.md](https://github.com/eshu-hq/eshu/blob/main/.agents/skills/eshu-code-review/references/conflict-recipes.md)
  ([Row 4a](https://github.com/eshu-hq/eshu/blob/main/.agents/skills/eshu-code-review/SKILL.md#row-4a-mechanical-conflict)
  in `eshu-code-review`); a clean test merge means rebase via
  [rebase-verify.md](https://github.com/eshu-hq/eshu/blob/main/.agents/skills/eshu-session-lifecycle/references/rebase-verify.md).

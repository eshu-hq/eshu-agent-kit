---
paths:
  - "go/**/*.go"
---

# Go package work

**Load `golang-engineering`.**

**Follow the `AGENTS.md` in the directory you are editing.** Every Go package
directory under `go/` carries one. Claude Code loads it when it reads a file in
that directory, so read the file before editing it; an edit made from a search
hit alone never loads `go/internal/reducer/AGENTS.md` for `foo.go`.

Its siblings serve different audiences and are worth the read for different
reasons: `doc.go` is the godoc contract, `README.md` is the human architecture
and operational context.

Surfaces that need a second skill on top of `golang-engineering`:

| If the file touches | Also load |
| --- | --- |
| Cypher, graph reads/writes, indexes | `cypher-query-rigor` |
| Postgres SQL, DDL, migrations, queue queries | `postgres-rigor` |
| workers, leases, conflict keys, retries, queue ordering | `concurrency-deadlock-rigor` |
| correlation, materialization, deployment tracing | `correlation-truth` |
| MCP or API tool calls, bounded graph-backed queries | `mcp-call-rigor` |
| benchmarks, query/index optimization, throughput | `performance-rigor` |
| fact kinds, payload shapes, `sdk/go/factschema` | `contract-rigor` |

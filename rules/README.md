# Rules

Harness rules live here. Source today: `eshu/.claude/rules/`.

Move order: package docs, docs, release, telemetry first (portable). Eshu-coupled rules (`cypher-graph`, `queue-concurrency`, `postgres`, `golden-corpus`, `security-gates`, `go-packages`, `generators`, `mcp-api`) follow as the `eshu` layer.

One rule per file. Name the trigger branch in the first line so the pointer fires reliably.

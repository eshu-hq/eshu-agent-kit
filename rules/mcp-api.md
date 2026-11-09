---
paths:
  - "**/mcp/**"
  - "**/openapi*"
  - "**/http-api.md"
---

# MCP tools and the HTTP query surface

**Load `mcp-call-rigor`.** Add `cypher-query-rigor` when the handler issues
graph reads.

OpenAPI stays in lockstep with its source, the handler tests, and the HTTP
API reference: the overlay names this repo's files, and Eshu values live in
the [Eshu adapter](../templates/repo-overlay/eshu-adapter.md). These
are a wire contract: a shape change that lands in one and not the others is
visible to callers before it is visible to the tests.

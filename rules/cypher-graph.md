---
paths:
  - "**/cypher/**"
  - "**/*.cypher"
---

# Cypher and graph writes

**Load `cypher-query-rigor`.** Add `performance-rigor` for any change on a
hot path, and `correlation-truth` when the change decides what a correlation
means.

Eshu tree paths and backend notes live in the [Eshu adapter](../templates/repo-overlay/eshu-adapter.md):
add them as a repo-local rule, not here.

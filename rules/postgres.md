---
paths:
  - "**/postgres/**"
  - "**/migrations/*.sql"
---

# Postgres, schema, and queue state

**Load `postgres-rigor`.** Add `concurrency-deadlock-rigor` when the change
touches claim, lease, retry, or queue-ordering behavior.

Eshu tree paths live in the [Eshu adapter](../templates/repo-overlay/eshu-adapter.md):
add them as a repo-local rule, not here.

A migration is a one-way door in a way ordinary code is not: it runs once against
data that already exists. Prove the statement against representative data before
writing it, not after.

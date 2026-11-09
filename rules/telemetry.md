---
paths:
  - "**/telemetry/**"
---

# Telemetry contract

**Load `telemetry-coverage-discipline`.**

Eshu coverage files live in the [Eshu adapter](../templates/repo-overlay/eshu-adapter.md):
add them as a repo-local rule, not here.

The four artifacts move together: the X1 contract doc, the X2 verifier, the X3 CI
gate, and the X4 dashboard. Registering an instrument without a doc row fails the
gate, and a doc row naming a metric that was never registered fails it the other
way.

Adding any new `.go` file under an instrumented collector triggers the blocking
coverage gate. If the new file genuinely reuses existing signals, that is what
the `No-Observability-Change:` marker is for — it is a positive assertion naming
the existing metrics, not a TODO.

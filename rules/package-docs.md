---
paths:
  - "**/doc.go"
  - "**/README.md"
  - "**/AGENTS.md"
---

# Package documentation

**Load `folder-doc-keeper`.**

The three files in every Go package directory serve different readers and are not
interchangeable: `doc.go` is the godoc contract, `README.md` is human
architecture and operational context, `AGENTS.md` is scoped agent instructions
that Codex loads for that directory tree. `AGENTS.md` stays a trigger on
purpose: Claude, unlike Codex, does not load it unprompted, so without this
glob the do-not-delete guard below would never load at the moment it matters.

Do not delete a scoped `AGENTS.md` unless the replacement is proven to be loaded
by the target harness with the same scope and precedence. Claude reads these only
when a rule or a prompt points at them; Codex resolves them automatically.

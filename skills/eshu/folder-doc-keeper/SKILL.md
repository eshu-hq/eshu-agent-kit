---
name: folder-doc-keeper
description: Use when a Go package's doc.go, README.md, or scoped AGENTS.md is missing, stale, or failing the package-docs gate after a contract change or package move.
---

# Folder doc keeper

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths, `eshu-*` skill names (all renamed by now; see `skills/registry.md`), and eshu repo tooling resolve in the consuming repo checkout (see `skills/registry.md`).

Keep the affected package's documentation aligned with the code. Every changed
package under `go/internal` or `go/cmd` needs `README.md`, `doc.go`, and
`AGENTS.md`; the package-doc gate enforces this baseline.

- `doc.go` states the godoc contract: real package name and identifiers,
  guarantees, failure modes, and caller invariants.
- `README.md` explains ownership, dependencies, telemetry, and operational
  context. Point to the contract instead of duplicating it.
- `AGENTS.md` carries scoped contributor instructions. Preserve its harness
  scope and precedence; add only relevant invariants and change guidance.

## Workflow

1. **Identify target packages.** Use the request, diff, and
   `.eshu-doc-state/stale.jsonl` to list affected packages under `go/internal`
   or `go/cmd`; when the target cannot be inferred, cover every stale package.
   Done when every stale or changed package directory is named.

2. **Inspect package source within directory bounds.** Inspect enough package
   source to support each claim; keep discovery within that directory
   (`rg --max-depth 1`) so subpackages do not contaminate its documented
   surface. Read [workflows](references/workflows.md) for stale-marker
   processing or new package scaffolding, and [templates](references/templates.md)
   when creating or restructuring package docs; keep each README heading with a
   brief explanation when a section does not apply. Done when every claim maps
   to code in that directory.

3. **Update only affected sections.** Rewrite only affected sections of
   `doc.go`, `README.md`, and `AGENTS.md`, preserving human-authored content
   elsewhere. Use `publish` for the prose pass. Reduce unsupported claims rather
   than inventing facts; take an unresolved decision to the coordinator with an
   arbiter-eshu ruling request. Done when all three files match the current
   package contract.

4. **Verify and clear resolved stale markers.** Run Go commands from `go/`,
   where `go.mod` lives. Check changed `doc.go` with `go doc ./<package>`, run
   package vet/build checks when code or declarations change, and run
   `scripts/verify-package-docs.sh` from the repo root (plus its test mirror
   when changing the verifier). Clear only resolved stale markers after
   verification; done when the package-docs verifier exits 0:

   ```bash
   (cd go && go doc ./<package>)
   bash scripts/verify-package-docs.sh
   ```

The repository docs build and promotion gates still apply; this skill does not
waive them. Continue through the session's authorized completion boundary
without adding a separate commit stop.

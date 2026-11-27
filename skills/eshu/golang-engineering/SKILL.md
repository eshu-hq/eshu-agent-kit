---
name: golang-engineering
description: "Use when writing or changing any *.go or *_test.go file under go/ or sdk/go/: package and file naming, SPDX license headers, TDD, exported contracts, lint, the 40-file directory cap, compat-surface moves, and build-tag traps."
---

# Go engineering in Eshu

Scope: this is the `eshu` layer of the kit. Relative `docs/` paths, `eshu-*` skill names (all renamed by now; see `skills/registry.md`), and eshu repo tooling (`go/`, `scripts/`, `Makefile`, CI gates) resolve in the consuming repo checkout (see `skills/registry.md`).

Use owning-package guidance to resolve ownership and behavior before changing
its contract. Read the relevant entrypoint or dispatcher when the change crosses
runtime boundaries; a small edit does not require an unrelated package tour.

## Behavioral proof

**Pre-Commit Go Checklist:** name the data shape first (`architect`), add MIT SPDX header on every new `.go` file (`bash scripts/add-license-header.sh`), verify red-first behavior TDD on production paths, run `cd go && go vet ./...` + focused `-race` tests, remove dead/wrapper slop, and stay under the 40-file directory cap.

Follow the root TDD policy. Bug fixes need a regression that fails for the
intended reason before the implementation changes. Tests must exercise the
production path, not a copied implementation or a stand-in for the behavior
being asserted. Judge every test with two imagined edits: breaking observable
behavior MUST fail the test, and changing internals while preserving behavior
MUST keep it green. Assert observable contracts (`errors.Is`/`errors.As`, return
values, durable state) rather than internal call order or error text; pair every
negative ("never happens") test with a positive case where it does happen; and
prefer no new test over a brittle mock-heavy test that mirrors implementation.
Cover every affected dispatch variant of shared helpers, query builders, replay
paths, and retry classifiers. Confirm filtered tests actually ran. Use
deliberate mutation of the production assertion when test sensitivity is
uncertain; do not require a separate mutation exercise for every test whose
regression failure already demonstrates that sensitivity.

## Design, simplicity, and comment discipline

- **Data shape and boundaries first.** For changes crossing function or package
  boundaries, settle types, ownership, and caller signatures first (see
  [architect](../../core/architect/SKILL.md)). Parse and validate external inputs
  (JSON, DB rows, CLI flags, env vars) at system boundaries into typed domain
  values; trust internal types inside and keep business logic pure behind thin
  adapters.
- **Subtract before you add.** Delete dead code, unused branches, and
  speculative validators before building on top of a package.
- **Minimize reader load.** Pass the 30-second test (*where does X come from,
  and what can change it?*). Collapse single-caller wrappers and single-impl
  interfaces, keep mutable state in the tightest scope possible, and avoid
  synchronized shadow fields.
- **Build the lever for sweeps.** On any multi-file refactor or mechanical
  migration, do the first unit by hand, write a small idempotent script or
  codemod, and prove it by rerunning on the first unit before applying it across
  the tree.
- **Keep signal comments, delete narration.** Preserve MIT SPDX headers,
  package/exported Go doc comments (`folder-doc-keeper`), `#nosec` justifications,
  and external-quirk links. Delete inline comments that narrate obvious control
  flow; for constraint comments ("do not reorder", "must match X"), encode the
  constraint in a type, test, or lint before deleting the comment.

Keep ownership boundaries intact. For workers, queues, transactions, retries,
or shared-state changes, use `concurrency-deadlock-rigor` for the relevant proof.
Runtime and performance work retains the repo's accuracy, performance, and
concurrency evidence requirements.

Every new `.go` file, tests included, needs the MIT SPDX header; the
`license-header` gate fails without it. Run `bash scripts/add-license-header.sh`
inside the worktree, or copy the two header lines from a sibling file, before
the first commit that holds the file.

## Restructuring and naming

Apply `[fill-in: naming standard — this repo's naming doc]` to every package,
directory, and file a change touches, not only the ones being moved: plain
English at each path level, never repeat the directory name in the file name,
nest compound names into directories instead of gluing them, no package-name
stutter in exported identifiers, and leave every touched name better than you
found it. The same reasoning extends to a name that shadows a standard-library
package (`sort`, `context`, `errors`, ...) — nest or rename instead of
colliding with it.

The dirgate gate (`go/cmd/dirgate`, issue #6054) caps non-test `.go` files per
directory at 40 as a ratchet derived from git, plus two write-once baselines
(`go/cmd/dirgate/baseline-cap.tsv`, `baseline-naming.tsv`) for what already
existed: a directory may not grow past `max(40, its count at the base)`, and the
gate also names growth that landed concurrently and was never waived. Shrinking,
swapping, and renaming inside a directory need no action. Growth needs a
`Dirgate-Growth:` trailer in the commit message that adds the files — see the
[`Dirgate-Growth` trailer](../publish/references/commit-trailers.md) for
the syntax. Never edit the baselines; there is no ledger row to re-derive and no
mirror to regenerate. See
`[fill-in: restack rule — this repo's restack and ledger-trap rule]`
for why the old ledger was retired. `//nolint:dirgate // <reason>` is the
naming escape only; it no longer waives the cap.

When a family moves to its own package, repoint its root callers at the leaf
in the same PR. The `compat_*.go` alias surface that used to bridge moves
(type aliases and thin forwarders grouped by family stanza) was retired in
#8733 once the last caller moved; do not recreate it. A family move lands
directly in the leaf package.

Package-move mechanics, in order:

1. Use `git mv` for every relocated file, so history follows the move instead
   of showing a delete plus an unrelated add. Done when `git status` shows
   renames rather than delete/add pairs.
2. Census what actually moves by symbol, never by filename prefix: a filename
   prefix both over- and under-states real package membership. Use `go/types`
   or a trial compile with `-gcflags=-e` to enumerate the exported and
   cross-file-referenced symbols a file depends on before deciding it belongs
   in the move. Done when every moved symbol's callers resolve.
3. Use recursive `./pkg/...` test paths for both the old and new locations, not
   a bare package path — a non-recursive path silently skips subpackages a
   move touched. Done when every touched package and subpackage compiles and
   passes tests.
4. Prove repointed tests still run, not merely still compile: `go test -list
   '.*' ./pkg/...` against the moved package confirms the test names the move
   was supposed to carry are still discovered, catching a test file left
   behind under a build tag or an old package name that compiles clean but
   registers nothing. Done when every expected test name appears in the listing.
5. When a PR creates a subpackage, place its tests in that package (an
   external `_test` package if they need the parent), never as a `<pkg>_*`
   family in the parent. Done when no orphaned `<pkg>_*` test remains in the
   parent directory.

`go build/vet/test ./...` silently skips any file behind a `//go:build` tag
that no workflow, Makefile target, or script ever passes — a moved or renamed
build-tagged file can look green on the default checks while it never compiles
or runs anywhere (see the incident recorded in
`go/internal/query/cloud_inventory_account_alias_live_test.go`). Before
trusting a default `go test ./...` on tagged code, grep the tag's
build-constraint name across `.github/workflows`, `Makefile`, and `scripts/`.

## Local verification and docs

Use the repo's formatter on changed Go files (`gofumpt` where the repo
requires it, else `gofmt`). Run focused
proof, then broader checks when callers or shared contracts are affected. Use
the consuming repo's local-testing doc (`docs/public/reference/local-testing.md`
in Eshu) as the gate
source of truth.

`make pre-push` is the fast local floor, run once per PR on the push that opens
it (never on row 4a, tier S, or an owner push order): changed-package
test, lint, build, and vet, the file-count cap, the registry-selected static
gates (slow ones deferred to CI with a printed reason), and
docs-contradiction. Later pushes run focused proof only. `make pre-pr` and
`make pre-pr-full` are not part of promotion: run them for a package move (use
`pre-pr-full`), to reproduce a CI red, or when the owner asks. CI decides the merge (`[fill-in: merge rule — this repo's merge bar: when a PR may merge]`): a
red Ifá/Odù, contract, performance, or end-to-end gate is a finding; when CI
fails, reproduce only that failing gate locally.

- Go code changes require the repo lint entrypoint unless the user narrows
  verification. See [verification](references/verification-and-linting.md) when
  selecting the scope or diagnosing lint setup.
- Changed packages under `go/internal` or `go/cmd` need `doc.go`, `README.md`,
  and `AGENTS.md`; run `scripts/verify-package-docs.sh`. Update their contents
  when contracts or contributor guidance change, using `folder-doc-keeper`.
- Run `scripts/verify-performance-evidence.sh` for Cypher, graph-write, runtime
  stage, worker, queue, lease, batching, or concurrency changes, including new
  collectors that introduce those patterns. Use the reviewed branch base.
- Report commands, actual results, and unverified scope.

```bash
bash scripts/add-license-header.sh
(cd go && go test -list '.*' ./<pkg>/... && go test -count=1 ./<pkg>/...)
bash scripts/verify-package-docs.sh
bash scripts/verify-performance-evidence.sh
```

When running Go tools on a shared host or with concurrent agents, read
[shared-machine constraints](references/shared-machine.md) before execution.
They cover isolated caches, process-local environment settings, and short
`GOTMPDIR` paths outside worktrees.

For a specific unresolved Go design, testing, or documentation question, consult
only the relevant reference: [design](references/go-best-practices.md),
[testing](references/tdd-workflow.md), or
[documentation](references/documentation-guidelines.md). Repository contracts
and conventions take precedence over generic examples.

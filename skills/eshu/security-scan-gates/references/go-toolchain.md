# Go Toolchain Scanners

Scanner detail for `security-scan-gates`.

## Go 1.26: gosec and govulncheck both break on x/tools SSA

Both build an SSA representation via `golang.org/x/tools`, which breaks on
Go 1.26 generics. As of mid-2026 even the latest released x/tools and x/vuln
master still hit it.

- **govulncheck** default symbol mode panics
  (`ForEachElement called on type containing *types.TypeParam`). Fix: run
  `govulncheck -scan package ./...` — package mode resolves vulnerable imports
  without the SSA call graph, does not panic, and is strictly more conservative
  than symbol mode (it flags an imported vulnerable package even when no
  vulnerable symbol is called), so it never hides a vulnerability.
- **gosec** v2.22.0 lets the SSA panic abort the job; bump to >= v2.27.1, which
  recovers ("skipping SSA analysis"). BUT v2.27.1 then logs "package
  query/reducer has type errors" (its bundled go/types cannot fully load some
  Go 1.26 generics) and **exits non-zero even with zero findings**. Fix: run
  `gosec -no-fail -fmt=sarif -out gosec.sarif ./...` and gate on the finding
  count instead of gosec's exit code:
  `jq '[.runs[].results[]] | length' gosec.sarif` — any reported result fails
  the job; the benign type-check artifact (which carries no SARIF results) does
  not. gosec on Go 1.26 is slow (SSA recover per package): emit SARIF once (not
  a second text pass) and set `timeout-minutes: >= 30`.
- **Stdlib CVEs:** `govulncheck -scan package` and trivy report Go-1.26.0 stdlib
  CVEs. The toolchain is the fix — bump the `go` directive in `go/go.mod` to a
  patched patch release (e.g. `go 1.26.4`); `setup-go` installs exactly what the
  `go` directive says via `go-version-file`.


## Nancy

Nancy reads `go.sum`, so a `go` directive or dependency bump changes its
verdict. Reproduce with the pinned nancy version and the exact CI flags,
report the vulnerable module and version from its output, and fix by bumping
the module — the same EXACT-version meta-rule applies.

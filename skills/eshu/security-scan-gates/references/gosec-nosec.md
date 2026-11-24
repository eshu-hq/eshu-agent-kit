# Gosec Suppressions

Scanner detail for `security-scan-gates`.

## gosec false positives: it ignores `//nolint:gosec`

Standalone gosec does NOT honor golangci-lint's `//nolint:gosec`, so it re-flags
sites the repo already vetted. Suppress with a gosec-native
`// #nosec <RULE> -- <specific, truthful reason>` placed as the FIRST directive
in the comment (before any pre-existing `//nolint`); gosec only honors `#nosec`
when it leads. gosec/noctx are NOT in the golangci-lint enabled set
(`go/.golangci.yml`, `default: none`), so the trailing `//nolint` is inert for
the lint gate. Suppress per-site (never blanket-exclude a rule), and FIX real
issues (weak file/dir perms, missing `ReadHeaderTimeout`, math/rand for
security, unparameterized SQL) rather than annotating them.

## SQL/Cypher (`G201`/`G202`/`G703`) — suppress only with proof

Suppress only when the interpolated part is a compile-time constant or a fixed
internal identifier (and the values are bound parameters, e.g. `$N`
placeholders). If any user/request-derived value is concatenated into the query
text, that is a real injection bug — parameterize it.

A SQL-injection audit MUST cite the gate that actually detects injection —
gosec `G201`/`G202` (and `G703` for Cypher), or CodeQL's injection queries.
Do NOT claim "zero injection findings" from an unrelated check: staticcheck
`SA1029` flags an inappropriate key in `context.WithValue` and says nothing
about SQL, so a clean `SA1029` run is not evidence about injection. Run
`gosec -no-fail -fmt=sarif -out gosec.sarif ./...` and report the
`G201`/`G202`/`G703` result count (see the SARIF count gate in
[go-toolchain.md](go-toolchain.md)), pinned to
the commit scanned.


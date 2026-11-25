# Trivy

Scanner detail for `security-scan-gates`.

## Trivy: `format: sarif` ignores the `severity` filter by default

With `format: sarif`, `trivy-action` does NOT apply the `severity:` input to the
SARIF output or to the exit code — it emits every severity and `exit-code: 1`
fires on MEDIUM/LOW findings too (e.g. opinionated KSV/DS k8s/Docker hardening
rules on our own charts). This reproduces ONLY in CI; a local
`trivy fs --severity CRITICAL,HIGH` filters correctly and exits 0.

**Fix:** set `limit-severities-for-sarif: true` on every trivy step so the
declared threshold actually gates. Only CRITICAL/HIGH then block; MEDIUM/LOW
still upload to the Security tab for visibility.

**Genuine HIGH misconfigs** (e.g. KSV-0014 read-only root FS, KSV-0118 default
security context on a real manifest) must be FIXED, not suppressed — add a pod +
container `securityContext` (the eshu image runs as non-root uid 10001 and
writes only to its data volume, so `runAsNonRoot` + `readOnlyRootFilesystem`
with a `/tmp` emptyDir are safe).

**Intentionally-vulnerable fixtures and examples** belong in `skip-dirs`, not
"fixed": the govuln test corpus
(`go/internal/collector/vulnerabilityintelligence/testdata`) embeds known CVEs
to test the vuln collector, and the example collector-extension worker images
run as root by design (documented, to read the mounted docker socket).


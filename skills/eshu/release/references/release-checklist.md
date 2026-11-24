# Release Checklist

Template for the release record. Keep the prerequisite and monitoring sections
so `publish`'s shape check (`check-shape.sh --issue-checklist`) preserves them.
Copy it, replace every `REPLACE:` line, delete what has nothing to say.

Refs #NNNN.

**REPLACE: release scope in one sentence — what ships and why now.**

## Prerequisites

- Source commit SHA: `REPLACE`
- Approvals held: REPLACE (owner order, arbiter ruling file, or linked decision)
- `code-review` verdict: P0=0, P1=0, P2-blocking=0 on the pushed head
- Preconditions from `docs/eshu/RELEASING.md` met: REPLACE (SDK: CHANGELOG
  entry renamed, compatibility row added, factschema-diff green)

## Artifacts

- Release tag: `REPLACE`
- `Chart.yaml` `version` / `appVersion`: REPLACE / REPLACE
- Image tag and digest: REPLACE
- cosign + attestation verification results: REPLACE
- Helm chart OCI location and version: REPLACE
- CLI release artifact names: REPLACE

## Monitoring

- Rollout health checks, dashboards, logs, or sync state: REPLACE
- Watcher armed over: REPLACE (image workflow, chart publish, binaries)
- Known advisory reds carried explicitly: REPLACE, or "none"

# Architecture

This repo is the single source of shared agent material. The installer
(or the Claude Code plugin) links it into whichever harness you run, at
the version your repo pins. The overview diagram is in
[Diagrams: Where the kit sits](../diagrams/README.md#where-the-kit-sits).

## The pieces

- **`skills/`** — written procedures. `skills/eshu/` holds all 21 today;
  `skills/core/` is empty until a skill passes the portability tests in
  [skills/registry.md](../../skills/registry.md). One meaning lives in
  one place: the registry is the rename and migration map.
- **`agents/`** — 10 subagent roles. `agents/roles.json` is the source;
  `agents/agent-roles.py` renders per-harness mirrors and fails on drift.
- **`hooks/`** — 8 scripts the harness runs at set moments. They fail
  open outside their scope. Wiring lives in
  [hooks/README.md](../../hooks/README.md).
- **`rules/`** — 12 path-scoped rules (Claude Code), with their own lint.
- **`docs/eshu/`** — process docs mirrored file-for-file from Eshu so
  skill links resolve inside the kit. Sync rule in
  [docs/eshu/README.md](../eshu/README.md): copy byte-identical, never
  edit for any other reason.
- **`templates/repo-overlay/`** — the pin + pointer files a product
  repo copies in. Product repos own their overlay; this repo owns the
  shared material ([AGENTS.md](../../AGENTS.md)).

## Boundaries

- Keep every skill, agent, rule, and hook portable first. Eshu coupling
  lives in `skills/eshu/` and named adapters, never in `core/`.
- Never copy kit material into a product repo. Pin a version, run `install.sh`.
- The kit is files — markdown, JSON, and scripts. It calls no Eshu API,
  reads no Eshu database, runs no service, and stores no Eshu data.

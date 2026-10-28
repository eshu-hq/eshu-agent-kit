# Hooks

Hook scripts live here. Sources today: `eshu/.claude/hooks/` and `eshu/.codex/hooks/`, wired through `eshu/.claude/settings.json` and `eshu/.codex/hooks.json`.

Inventory to port: `skill-nudge`, `skill-loaded`, `guard-live-gate`, `eshu-doc-staleness`, `goal-continue`, `goal-refresh`, `goal-role-router`, `issue-capture`, `on-compact`.

Portability bar: a hook ships here only with a guard that exits 0 when its script is absent from the target repo, and with per-harness wiring notes (Claude, Codex). Eshu-only hooks (doc staleness against Eshu docs, live-gate guard) stay behind an adapter flag until the target repo needs them.

# eshu-agent-kit

Shared agent toolkit for `eshu-hq` repos. Single source of truth for skills, agents, rules, and hooks.

Each product repo stays thin: it holds a version pin plus a small overlay, and installs this kit globally or per repo.

## Layout

- `skills/core/` — portable skills, no Eshu coupling.
- `skills/eshu/` — Eshu-coupled adapters (graph, queue, collector contracts).
- `skills/registry.md` — the rename and migration map. Read this before moving a skill.
- `agents/` — `roles.json` + `agent-roles.py` generator and rendered per-harness mirrors (`arbiter`, `develop`, `review`, `debug`, `perf`, `scan`).
- `rules/` — harness rules, ported from per-repo `.claude/rules/`.
- `hooks/` — hook scripts plus per-harness wiring notes.
- `templates/repo-overlay/` — the thin files a product repo keeps.
- `install.sh` — links this checkout into `~/.claude/skills`, `~/.codex/skills`, or a target repo.

## Use it

Pin a version in the product repo (`.agent-kit-version`), then install.

Claude Code (marketplace, versioned):

```sh
claude plugin marketplace add eshu-hq/eshu-agent-kit
claude plugin install eshu-agent-kit@eshu-agent-kit
```

Or inside Claude Code:

```
/plugin install eshu-agent-kit --marketplace eshu-hq/eshu-agent-kit
```

Releases are SemVer git tags; the `version` in `.claude-plugin/plugin.json` keeps installs on the cataloged version until the marketplace refreshes to a new tag.

Codex (no marketplace — open-standard skills, symlinked):

```sh
./install.sh --global
./install.sh --repo /path/to/repo
```

Subagents ship through `install.sh` on every harness until plugin hosts support them; skills and (once migrated) hooks ride the plugin on Claude Code.

```sh
./install.sh --agents --global
./install.sh --agents --repo /path/to/repo
```

Agent source of truth is `agents/roles.json`; `agents/agent-roles.py generate` renders the per-harness mirrors (`agents/`, `.claude/agents/`, `.codex/agents/`, `.opencode/agent/`, `.cursor/agents/`) and `check` fails on drift. Role names keep their `*-eshu` suffix until consumer cutover.

## Versioning

Tags (`v0.1.0`, …). Repos upgrade by moving the pin and re-running the installer. Never copy a skill into a product repo; point at the kit.

## Migration status

Source of record today is still the `eshu` monorepo (`.agents/skills/`, `.agents/agents/`, `.claude/rules/`, `.claude/hooks/`, `.codex/hooks/`). `skills/registry.md` tracks what moves, in which order, and under which new name.

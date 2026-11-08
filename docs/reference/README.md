# Reference

## What you get

These counts come from this tree. Skills are folders holding a
`SKILL.md`, roles come from `agents/roles.json`, hooks are the scripts
registered in `hooks/hooks.json`, and rules and docs exclude their
index files.

|  | Count | Lives in | Loads via |
| --- | --- | --- | --- |
| Skills | 21 | `skills/eshu/` | Claude Code plugin, or `install.sh` on any harness |
| Subagent roles | 10 | `agents/` (source: `agents/roles.json`) | `install.sh --agents` |
| Hooks | 8 | `hooks/` | Plugin via `hooks/hooks.json`, or `install.sh --hooks` plus manual wiring |
| Path-scoped rules | 12 | `rules/` | `install.sh --rules` (Claude Code) |
| Process docs | 16 | `docs/eshu/` | Linked from the skills that cite them |

All 21 skills live in `skills/eshu/` today, written for Eshu-family
repos. `skills/core/` exists but is empty. A skill only moves there
after it passes the portability tests in
[skills/registry.md](../../skills/registry.md), which is also the
rename and layer map. Don't assume a generically named skill is
portable — check the registry.

## Harness support

[install.sh](../../install.sh) supports five harnesses by name:
`claude`, `codex`, `opencode`, `muse`, and `cursor`, plus `all`. No
name means all of them.

| Harness | Skills | Roles | Hooks | Rules |
| --- | --- | --- | --- | --- |
| Claude Code | plugin or installer | installer | plugin registers all 8 | yes (`--rules`) |
| Codex, OpenCode, Muse, Cursor | installer | installer | separate install + explicit registration | no |

Installing the plugin won't break an unrelated repo, because every
hook fails open outside its scope. See
[hooks/README.md](../../hooks/README.md) for adapters, such as the two
Codex adapters in `hooks/codex/`.

## Generated files

Subagent role source of truth is
[agents/roles.json](../../agents/roles.json).
`agents/agent-roles.py generate` renders the per-harness mirror files
(10 in each harness agent directory) and `check` fails on drift.

## Runtime needs

`bash` and `python3`, nothing else. Hooks are plain bash and python3
scripts; the installer is bash with a bit of python3 for the OpenCode
config merge. There's no `go.mod`, `Dockerfile`, or `Makefile` here,
and nothing to deploy.

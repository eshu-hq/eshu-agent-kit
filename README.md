<div align="center">

# eshu-agent-kit

**One kit for every agent that works your repos. Skills, subagents, hooks, and rules — pinned, versioned, never copy-pasted.**

<a href="https://github.com/eshu-hq/eshu-agent-kit/stargazers"><img src="https://img.shields.io/github/stars/eshu-hq/eshu-agent-kit?style=flat-square" alt="GitHub stars"></a>

**[Install](#install) · [What you get](#what-you-get) · [Two harnesses](#two-harnesses-one-kit) · [Pin a version](#pin-a-version) · [Repo overlay](#repo-overlay)**

</div>

---

Without the kit, every repo carries its own copy of the same skills and hooks. Copies drift. Fixes land in one repo and never reach the others. Nobody knows which copy is current.

With the kit, product repos stay thin: a version pin plus a two-file overlay. Everything shared lives here and ships by version.

| | Before | After |
|---|---|---|
| Skills | copied per repo, drifted | `install.sh --repo` symlinks all 21 |
| Hooks | wired by hand, half missing | plugin registers 8, or one installer command |
| Fixes | patched N times | patched once, repos re-run the installer |
| Versions | "which copy?" | `.agent-kit-version` says exactly |

## Install

Claude Code (marketplace, versioned):

```sh
claude plugin marketplace add eshu-hq/eshu-agent-kit
claude plugin install eshu-agent-kit@eshu-agent-kit
```

Or inside Claude Code:

```
/plugin install eshu-agent-kit --marketplace eshu-hq/eshu-agent-kit
```

Codex (no marketplace — open-standard skills, symlinked):

```sh
./install.sh --global          # this machine
./install.sh --repo /path/to/repo   # one repo
```

That is the whole install. The plugin registers skills and hooks automatically. `install.sh` symlinks them, so updates arrive by re-running it — nothing is ever copied.

## What you get

| | Count | Lives in | Loads on |
|---|---|---|---|
| Skills | 21 | `skills/` | Claude Code plugin, Codex via `install.sh` |
| Subagent roles | 10 | `agents/` | `install.sh --agents` (Claude, Codex, Cursor, OpenCode) |
| Hooks | 8 | `hooks/` | plugin via `hooks/hooks.json`, or `install.sh --hooks` |
| Path-scoped rules | 12 | `rules/` | `install.sh --rules` (Claude Code) |
| Process docs | 16 | `docs/eshu/` | linked from the skills that cite them |

Skills split two ways: `skills/core/` holds portable skills with zero repo coupling; `skills/eshu/` holds adapters for Eshu-family repos (graph, queue, collector contracts). The rename and layer map is [`skills/registry.md`](skills/registry.md).

## End to end: issue to merged

This is the loop the kit exists for. The owner declares a goal against a GitHub epic or issue; the kit drives it to a merged PR without being asked twice.

```text
GitHub epic / issue
        │
        ▼
issue-driver ── posts a claim, opens one worktree per leaf,
        │        implements with proof, opens the PR
        ▼
code-review ── verdict on the diff:
        │       P0/P1/P2-blocking must be zero to merge
        ▼
session-lifecycle (babysit) ── watches CI, fixes findings,
        │                        rebases, re-verifies, repeats
        ▼
PR merged ── issue closed, worktree cleaned
```

Three pieces carry the weight:

- **`issue-driver`** owns the outcome, not just the edit. It enumerates the epic's leaves, claims one publicly so concurrent agents don't collide, works each leaf in its own worktree with focused proof, and doesn't stop at "PR opened" — it monitors the PR through review and CI to merged or closed.
- **`session-lifecycle`** owns the session mechanics that long goals die without: resume a branch mid-flight, pause with a note and pick it back up after compaction or days offline, judge whether a worker is alive before touching its tree, rebase and re-verify when `main` moves, clean up when it's done.
- **Hooks** own enforcement at the exact point of action — no prose reminders, no asking:

```text
Edit ──▶ skill-nudge: governed file? governing skill loaded? ──▶ allow / BLOCK
Bash ──▶ guard-live-gate: second live gate running? ──▶ allow / BLOCK
Edit ──▶ doc-staleness: rebuild drift snapshot (signals only, never blocks)
Stop ──▶ goal-continue: goal unfinished? ──▶ hand the goal back / allow end
Prompt ─▶ goal-refresh: restate the goal ··· SessionStart ─▶ on-compact: restore
```

Every hook fails open outside its scope — missing interpreter, non-Eshu checkout, no goal file all allow. A hook that cannot read its input has no basis to refuse anything. [`hooks/README.md`](hooks/README.md) has the full table and wiring.

`publish` is the last pass: issue bodies, PR descriptions, and status notes written so the next reader — owner, executor, or reviewer a year later — needs no other context.

## Two harnesses, one kit

- **Claude Code.** The marketplace plugin carries skills and registers all 8 hooks (`hooks/hooks.json`): skill enforcement, goal continuation, the live-gate guard, and the doc-staleness signal. Every hook fails open outside its scope — installing the plugin never breaks an unrelated repo.
- **Codex.** No plugin host, so `install.sh` symlinks skills, agents, hooks, and rules into the repo's `.agents/`, `.codex/`, and `.claude/` trees. Same files, same behavior.

Subagents ship through `install.sh` on every harness until plugin hosts support them. Their source of truth is `agents/roles.json`; `agents/agent-roles.py generate` renders the per-harness mirrors and `check` fails on drift.

## Pin a version

Releases are SemVer git tags. A product repo pins one line in `.agent-kit-version` and installs against it. Upgrade by moving the pin and re-running the installer. Never copy a skill into a product repo; point at the kit.

## Repo overlay

Everything a product repo keeps lives in [`templates/repo-overlay/`](templates/repo-overlay/): the version pin and a pointer-style `AGENTS.md`. Copy both, set the pin, run the installer. Details in [its README](templates/repo-overlay/README.md).

## Further reading

- [`hooks/README.md`](hooks/README.md) — every hook, its matcher, and the manual wiring block.
- [`rules/README.md`](rules/README.md) — the routing-layer contract and the rules lint script.
- [`docs/eshu/README.md`](docs/eshu/README.md) — vendored process docs and the sync rule.
- [`skills/registry.md`](skills/registry.md) — rename map and layer rule.

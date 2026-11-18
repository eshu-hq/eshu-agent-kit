# Hooks

Executable enforcement for the skill system. Plain bash + python3 scripts; wiring is per harness.

Install them two ways. The marketplace plugin registers everything below automatically through `hooks/hooks.json`. Everywhere else, `install.sh` symlinks the scripts and you wire them explicitly — Muse excepted, which gets its registration file written (see Muse Code below):

```sh
./install.sh --hooks --repo /path/to/repo
```

## What fires when

| Hook | Event | Matcher | What it does |
|---|---|---|---|
| `skill-nudge.sh` | PreToolUse | `Edit\|MultiEdit\|Write` | Refuses edits to a governed surface until the governing skill loads. Table overridable per repo via `.agents/nudge-table.sh`. |
| `guard-live-gate.sh` | PreToolUse | `Bash` | Refuses a second live gate while Eshu ports are bound. Silent outside Eshu checkouts. |
| `skill-loaded.sh` | PostToolUse | `Skill` | Records loaded skills as `/tmp` markers the nudge checks. |
| `issue-capture.sh` | PostToolUse | `Bash` | Ledgers issues filed during a goal so the Stop gate can enforce them. |
| `eshu-doc-staleness.sh` | PostToolUse | `Edit\|MultiEdit\|Write` | Rebuilds the doc-drift snapshot via `<repo>/scripts/check-docs-stale.sh`. No-op when the checker is absent. |
| `goal-refresh.sh` | UserPromptSubmit | — | Restates the active goal every turn; writes the goal file `/goal` commands create. |
| `on-compact.sh` | SessionStart | `compact\|resume` | Clears stale markers, re-points at `session-lifecycle`. Kit-pinned checkouts only. |
| `goal-continue.sh` | Stop | — | Refuses to end the session while a declared goal is unfinished. Fail-open with no goal file. |
| `stop-failure.sh` | StopFailure (Muse only) | — | Writes an at-most-once resume note when a turn dies in a model failure; the next prompt surfaces it and deletes it. Cannot re-drive the turn. |

Shared code lives in `lib/` (skill-nudge gate, goal machinery). `tests/` mirrors the blocking hooks — run the suite after any edit. `codex/` holds the Codex adapters (`goal-continue.sh` on `stop`, `eshu-doc-staleness.sh` on `apply_patch`).

## Contract

Every hook fails open outside its scope: missing interpreter, missing checker, non-Eshu checkout, no goal file — all allow. A hook that cannot read its input has no basis to refuse anything. One-off override for the guard: prefix the command with `CLAUDE_HOOK_ALLOW=1`.

## Manual wiring (Claude Code)

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Edit|MultiEdit|Write", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/skill-nudge.sh"}
      ]},
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/guard-live-gate.sh"}
      ]}
    ],
    "PostToolUse": [
      {"matcher": "Skill", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/skill-loaded.sh"}
      ]},
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/issue-capture.sh"}
      ]},
      {"matcher": "Edit|MultiEdit|Write", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/eshu-doc-staleness.sh"}
      ]}
    ],
    "UserPromptSubmit": [
      {"hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/goal-refresh.sh"}
      ]}
    ],
    "SessionStart": [
      {"matcher": "compact|resume", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/on-compact.sh"}
      ]}
    ],
    "Stop": [
      {"hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/goal-continue.sh"}
      ]}
    ]
  }
}
```

Codex (`~/.codex/config.toml`): `codex/eshu-doc-staleness.sh` on `apply_patch`; the shared `codex/goal-continue.sh` on `stop`.

## Muse Code

No manual wiring. `./install.sh --hooks --repo /path/to/repo` also links the
`muse/` wrappers into `.muse/hooks/` and writes `.muse/hooks.json`, the
registration file Muse reads at session start. Project hooks run only
after you trust the folder, so the written file is inert until then. An
existing `.muse/hooks.json` is never overwritten; the installer preserves it
and says so.

Each wrapper translates the Muse envelope where it differs from Claude's
(`tool_input.path` vs `file_path`, `turn_id` vs `prompt_id`, `read_skill`'s
`name` vs `skill`) and delegates to the `.claude/hooks/` sibling, so hook
logic stays in one copy. Matchers are Muse tool names, one entry per tool.
Wrappers fail open on garbage payloads and on a missing sibling. Repo-specific
guards (eshu's dispatch guard and goal-role router entries) are not part of
the generic set; they stay in the consuming repo's own `hooks.json`.

`stop-failure.sh` handles the `StopFailure` event: when a turn ends in a
final model failure, it records an at-most-once note (`.claude/`
`active-goal.<session>.resume`) with the failure category, and the next
`UserPromptSubmit` surfaces it through the normal goal restatement -- or
standalone when no goal is in flight -- then deletes it. A retired goal
clears a leftover note silently instead. Treat the note like any other
goal file for version control: wherever a repo ignores `active-goal*`,
ignore `active-goal.*.resume` too, so a failure note is never committed.
Be clear-eyed about what this
does not do: no hook can re-drive a dead turn or retry the model call.
The runner already retried before giving up; the note means the next turn
starts from what was in flight instead of a blank slate. Consuming repos
adopt it the same way as the other wrappers (re-run the installer to link
the new files); the global pseudo-root picks it up through the generated
`managed-hooks.json` with no extra step.

### Global install (machine-wide, opt-in)

Per-repo installs are untracked artifacts: they do not follow you into other
repos or fresh worktrees. `./install.sh --hooks --global muse` installs the
same wrappers once per machine instead. It links a pseudo-root tree under
`~/.config/muse/agent-kit-hooks/` (mirroring the repo layout, so wrappers
resolve their siblings unchanged) and registers it by setting
`managed_hooks_path` in `~/.config/muse/settings.json` to the tree's
generated `managed-hooks.json`. Read this before opting in:

- **Hooks run outside the Muse sandbox in every workspace, including
  untrusted ones, with no trust step.** That is why this is an explicit
  command, never part of `--global`.
- **No double firing.** The global copy of each wrapper defers (exits 0)
  when the payload repo's own `.muse/hooks.json` registers the same
  wrapper for the same event and matcher; partial project files defer
  exactly what they register and leave the rest to the global copy.
- **Global hooks never execute repo code.** The builtin nudge table applies
  (a repo's `.agents/nudge-table.sh` is not sourced), the doc-staleness hook
  no-ops, and goal-router expansion stays off. Reading per-repo *data*
  (goal files under the payload `cwd`) is the point and stays on.
- **The tree is symlinks into your kit checkout.** Keep the checkout in
  place; if it moves, re-run the installer. A dangling pointer or wrapper
  does not break Muse (verified), it just stops the hooks.
- **Settings safety.** The writer is strict JSON: it refuses (file
  untouched) on malformed JSON, a non-object top level, a `schema_version`
  other than 1, a symlinked `settings.json`, or a `managed_hooks_path`
  already pointing elsewhere — that pointer is never reclaimed, only set
  when absent. Successful writes are atomic and normalize formatting.
- **Undo:** remove the `managed_hooks_path` key from `settings.json` and
  delete `~/.config/muse/agent-kit-hooks/`.

### Global install for Claude Code (machine-wide, opt-in)

Plugin users already get machine-wide hooks through the marketplace plugin
(`hooks/hooks.json` auto-registers). `./install.sh --hooks --global claude`
is the non-plugin path: it links a pseudo-root tree under
`~/.claude/agent-kit-hooks/` (mirroring the repo layout, so siblings resolve
their lib unchanged) and merges the same 8 entries into the `hooks` block of
`~/.claude/settings.json` with absolute commands into that tree. Matchers
stay exactly as in `hooks/hooks.json` — Claude matches them as regex
alternation natively (`Edit|MultiEdit|Write` in one entry, verified live),
unlike Muse one-entry-per-tool. Read this before opting in:

- **No double firing.** Every generated command runs with
  `KIT_GLOBAL_HOOK=1`, under which global hooks never execute repo code: the
  builtin nudge table applies (a repo's `.agents/nudge-table.sh` is not
  sourced), the doc-staleness hook no-ops, and goal-router expansion stays
  off. Reading per-repo *data* (goal files under the payload `cwd`) stays on.
  Entries the plugin registration already covers (same event, matcher, and
  hook basename) are skipped with a warning, so plugin users never fire
  twice; re-run the installer after disabling the plugin to pick them up.
- **Settings safety.** The writer is strict JSON: it refuses (file untouched,
  no tree created) on malformed JSON, a non-object top level or `hooks`
  block, or a symlinked `settings.json`. Existing entries and unknown keys
  are never touched — covered entries are skipped, the rest are appended —
  and reruns are byte-identical. Successful writes are atomic and normalize
  formatting.
- **The tree is symlinks into your kit checkout.** Keep the checkout in
  place; if it moves, re-run the installer.
- **Undo:** delete the kit entries from `~/.claude/settings.json` and remove
  `~/.claude/agent-kit-hooks/`.

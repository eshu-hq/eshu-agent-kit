# Hooks

Executable enforcement for the skill system. Plain bash + python3 scripts; wiring is per harness.

Install them two ways. The marketplace plugin registers everything below automatically through `hooks/hooks.json`. Everywhere else, `install.sh` symlinks the scripts and you wire them explicitly:

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

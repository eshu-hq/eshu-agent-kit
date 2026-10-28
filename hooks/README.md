# Hooks

Executable enforcement for the skill system. Scripts are harness-agnostic
bash + python3; wiring is per harness (see Wiring below).

Moved (generic skill-enforcement trio):

- `skill-nudge.sh` — PreToolUse on Edit|MultiEdit|Write. Blocks edits to a
  governed surface until the governing skill is loaded. Table is overridable
  per repo via `.agents/nudge-table.sh` redefining `nudge_ids_for`.
- `skill-loaded.sh` — PostToolUse on Skill. Records loaded skills as
  `/tmp` markers that the nudge checks.
- `on-compact.sh` — SessionStart on compact|resume. Clears stale markers
  and re-points at `session-lifecycle`. Speaks only in kit-pinned checkouts
  (`.agent-kit-version` marker).
- `lib/skill-nudge-lib.sh` — shared `kit_root_path`/`kit_root` gate.

Also moved (goal workflow): `goal-continue.sh` (Stop gate), `goal-refresh.sh`
(prompt restatement + producer), `issue-capture.sh` (PostToolUse ledger),
`lib/` goal machinery, `tests/` mirror suite (run it after any edit),
`codex/goal-continue.sh` (Codex Stop adapter delegating to the shared hook).
Goal files resolve through the kit pin; the `goal-role-router.py` expansion
stays guarded-off until that script moves.

Not yet moved (eshu-coupled): `guard-live-gate.sh` (eshu ports),
`eshu-doc-staleness.sh` (eshu docs).

## Wiring

The installer links scripts only; hook registration stays explicit in the
consuming repo. Claude Code (`settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Edit|MultiEdit|Write", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/skill-nudge.sh"}
      ]}
    ],
    "PostToolUse": [
      {"matcher": "Skill", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/skill-loaded.sh"}
      ]}
    ],
    "SessionStart": [
      {"matcher": "compact|resume", "hooks": [
        {"type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/on-compact.sh"}
      ]}
    ]
  }
}
```

`install.sh --hooks --repo PATH` links `hooks/` + `hooks/lib/` into
`PATH/.claude/hooks/` and prints this block. Plugin-manifest `hooks`
wiring lands with the goal-hook move.

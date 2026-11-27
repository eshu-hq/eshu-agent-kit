# Hooks

Executable enforcement for the skill system. Plain bash + python3 scripts; wiring is per harness.

Install them two ways. The marketplace plugin registers everything below automatically through `hooks/hooks.json`. Everywhere else, `install.sh` symlinks the scripts and you wire them explicitly — Muse and Antigravity (`agy`) excepted, which get their registration written (see Muse Code and Antigravity below):

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

Shared code lives in `lib/` (skill-nudge gate, goal machinery). `tests/` mirrors the blocking hooks — run the suite after any edit. `codex/` holds the Codex adapters (`goal-continue.sh` on `stop`, `eshu-doc-staleness.sh` on `apply_patch`). `agy/` holds the Antigravity adapters (below).

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

### Global install for OpenCode (machine-wide, opt-in)

OpenCode has no shell-hook lifecycle: behavior ships as a small JavaScript
plugin on its event bus instead. `./install.sh --hooks --global opencode`
copies one generated file,
`~/.config/opencode/plugins/eshu-bridge.js` (auto-discovered, no settings
merge), with this checkout's path baked in. The bridge translates OpenCode
events into the same sibling envelopes the Muse wrappers use, then runs the
shared bash scripts — the hook logic stays in one copy per event. Every
mapping below was verified live against OpenCode 1.19.6 with a real model,
not just fixtures; the verification record lives on issue #46.

| Kit hook | OpenCode event | Status |
|---|---|---|
| goal-refresh plus resume note | `chat.message` appends the restated goal as a text part | Shipped, verified live |
| stop-failure note | `session.error` records a note on terminal provider failure | Shipped, verified live |
| on-compact warning | `experimental.session.compacting` appends the warning to the compaction context | V1-only (bridge is a V1 plugin; does not load on the v2 host) — see #97 (V2 port); live firing still unobserved (was #54, now tracked by #97) |
| skill-nudge, live-gate blocks | throwing in `tool.execute.before` blocks the call and the session survives, but V1 omits the command text the guard and nudge decide on | Designed, not built |
| issue-capture | same missing command text: the extractor cannot tell a create from a read | Designed, not built |
| doc-staleness | global hooks never execute repo code, so the checker no-ops by rule | Not applicable |
| skill-loaded markers | OpenCode has no skill-load event to observe | Not applicable |

A plugin file must carry exactly one export: the default plugin function.
V1 silently skips files with extra named exports, with no error logged, so
the bridge keeps every helper module-local and the tests drive it through
the default export.

- **Trust model.** The plugin is in-process code, so the global bridge shells
  out only to this kit checkout, never to repo code. Sibling writes stay
  where the other harnesses put them: the resume note lands in the session's
  own cwd, beside its goal file. The bridge file carries a Generated-by
  marker; uninstall regenerates the expected content and byte-compares
  before deleting, and never scans the shared plugins directory, so user
  plugins are never inventoried or touched.
- **Undo:** `./install.sh --uninstall --hooks --global opencode`. If you moved
  the checkout since installing, reinstall from the new location first so
  uninstall recognizes the file; otherwise it keeps it and tells you to
  remove it by hand.

## Antigravity (`agy`)

`./install.sh --hooks --repo /path/to/repo` also links the `agy/` wrappers
into `.agy/hooks/` and merges one key, `eshu-agent-kit`, into
`.agents/hooks.json`. agy's `hooks.json` is name-keyed, so the merge never
touches your other keys or their order; a re-run is byte-identical. The
installer refuses (file untouched, nothing agy-related linked) on invalid
JSON, a non-object, a duplicate key, a byte-order mark, a symlink, or an
`eshu-agent-kit` key whose commands are not the kit-generated ones.
Project hooks run only for trusted workspaces (unverified for this install).

| agy event | Matcher | Kit hook it runs |
| --- | --- | --- |
| `PostToolUse` | `read_file\|view_file` | `skill-loaded.sh`, only for `.../skills/<id>/SKILL.md` |
| `PreToolUse` | `edit_file\|write_file` | `skill-nudge.sh` |
| `PreToolUse` | `run_command` | `guard-live-gate.sh` |
| `Stop` | none | `goal-continue.sh` |

**Adapter contract.** agy speaks camelCase JSON on stdin and reads one JSON
object on stdout; the kit siblings block with exit 2 and stderr, which agy
does not understand. So each wrapper translates in, runs the `.claude/hooks/`
sibling with `KIT_HARNESS=agy`, translates the verdict out, prints at most one
JSON object, and always exits 0. Neutral is **empty output**: a live agy
1.5.18 run treated a PreToolUse reply of `{}` as a deny (the tool call failed
with an empty reason), while empty output, and `{}` from PostToolUse or Stop,
were accepted. A sibling block becomes
`{"decision":"deny","reason":...}` (the skill-nudge reason also tells the
model to `read_file` the skill's `SKILL.md`, since agy has no Skill tool) or,
for Stop, `{"decision":"continue","reason":...}`. `"allow"` is never emitted:
agy defines it as an automatic approval that would skip the user's permission
prompts. Garbage input, a missing sibling or a missing `python3` print nothing.
Tool hooks time out at 10 seconds, Stop at 30.

- **Stop guards.** The hook acts only when `terminationReason` is
  `NO_TOOL_CALL` and `continuationActive` is present (agy 1.5.6 and later);
  without it there is no loop protection, so it prints nothing. agy has no turn
  id, so the adapter mints one per turn (new when `continuationActive` is
  false, reused while true) in `$TMPDIR/agy-turn-<conversation>`.
  *Known limit:* the no-progress scan (`goal-progress.sh`) does not
  recognize agy transcript records, so every agy stop counts as no-progress
  and a goal is released after the 3-stop budget per user message even if
  the agent kept working.
- **Telemetry.** Events go through the same `si_event` log with harness
  `agy`; the skill-loaded marker convention is shared. Hook skill loads count
  reads only, while the transcript extractor also counts edits and writes of
  a `SKILL.md`, so the two totals can differ slightly.
- **Version floor.** `hookEventName`, `cwd` and `toolCall.id` need agy 1.5.4;
  `continuationActive` needs 1.5.6.
- **Envelope fixtures.** `hooks/tests/testdata/agy-*.json` are synthetic,
  built from agy's hooks doc and transcript argument names, not live
  captures. A probe hook on agy 1.5.18 in print mode did confirm: the read
  tool is `read_file` with `args.Path`; the Stop payload spells the key
  `continuationActive`; hooks inherit `HOME` and `TMPDIR` (`XDG_DATA_HOME` is
  unset) and run with the `.agents` directory as cwd; and a workspace
  `.agents/hooks.json` loads in a fresh folder with no trust step.

### Global install for agy (machine-wide, opt-in)

`./install.sh --hooks --global agy` links a pseudo-root tree under
`~/.gemini/config/agent-kit-hooks/` and merges a key named
`eshu-agent-kit-global` (the repo install uses `eshu-agent-kit`; distinct
names, so same-named hooks never depend on how agy merges two files) into
`~/.gemini/config/hooks.json` with absolute commands that set
`KIT_GLOBAL_HOOK=1`. **These hooks run in every workspace with no trust
step**, so this is an explicit command, never part of `--global`. Siblings
never execute repo-supplied code under `KIT_GLOBAL_HOOK=1` (the Stop hook
still reads goal files under the payload `cwd`, as the other global installs
do).

**No double firing, and no silenced guard.** The global copy always fires and
never reads the workspace it runs in. The *repo* copy stands down only when
`$HOME/.gemini/config/hooks.json` (a regular, non-symlink file that parses as
strictly as Go: no `NaN`/`Infinity`, out-of-range numbers or BOM, and no two
keys equal after case-folding at any level, because Go matches keys
case-insensitively) holds an `eshu-agent-kit-global` key that deep-equals the
WHOLE generated key (so no `enabled` member and no hand edit to any wrapper's
entry), and the global tree's wrapper, sibling and lib files are in place
(symlinks into the kit are the design). `HOME` unset, empty or relative, or
any doubt, means the repo copy fires too. A workspace can therefore add a
firing but never switch a global guard off. `skill-nudge` is the exception
that keeps a repo copy useful: it still runs and exits at once unless the repo
has its own `.agents/nudge-table.sh`, which the global copy never sources. With
a global install, a repo table can extend the builtin nudge arms but not
narrow or replace them; with none, the repo table applies in full.

Double firing happens only with an unusable `HOME`, a hand-edited global key,
or a repo nudge table. Costs, measured: `skill-loaded` writes its event twice,
the nudge and live-gate deny twice (same verdict), and `goal-continue` mints a
second turn id, so a goal's continuation budget runs double (one continuation
fewer). It is bounded and cannot loop.

**Upgrading from the first agy release.** That release printed `{}` as its
neutral reply and as the "wrapper missing" fallback, which agy treats as a
PreToolUse deny. Re-run `./install.sh --hooks` (repo or `--global agy`): the
installer recognizes the old command shape as its own and rewrites it.
Until a global install is re-run its key no longer deep-equals the generated
one, so repo copies fire beside it (the safe double fire above).

The merge refuses on the same conditions as the repo install. Undo:
`./install.sh --uninstall --hooks --global agy` removes the key only when it
still equals what the installer wrote (a modified key is kept and reported),
deletes the file only when nothing else is left in it, then removes the tree.

## Skills insights telemetry

Which skills get loaded, which loads were forced, and how sessions end —
for improving how we work, not for watching people.

**Events.** `skill-loaded.sh` appends `skill-load` (skill id, session,
harness); `skill-nudge.sh` appends `nudge-block` (demanded skill ids) on its
refusal path; `goal-continue.sh` appends `goal-done`, `goal-released`
(stop count), `goal-blocked-watcher`, or `goal-continued` (progress,
remaining, turn); `stop-failure.sh` appends `model-failure` (category only,
never details). Muse and Codex wrappers attribute via `KIT_HARNESS`. All
events go to `$XDG_DATA_HOME/eshu-agent-kit/skills-usage.jsonl` (fallback
`~/.local/share`), rotated at 5 MiB keeping one spare.

**Privacy bar.** Skill names, outcome labels, counters, timestamps. No prompt
content, no file contents, no file paths, no identifiers beyond the
truncated session id. Every failure path is silent and non-blocking;
`ESHU_SKILLS_TELEMETRY_OFF=1` disables all of it.

**Manual probes.** Firing an installed hook by hand (or any live-fire check
outside the suites) writes to the real log under your actual `$HOME`, and
fixture session ids then pollute every later debrief. Export
`ESHU_SKILLS_TELEMETRY_OFF=1` for such runs; the suites already run hermetic
and need no change.

**Coverage.** Hook telemetry (`skills-usage.jsonl`) exists on Claude, Muse
and, once the `agy` hooks above are installed, Antigravity; neither Codex nor
OpenCode exposes a skill-load event. When agy sessions appear in a window
with no agy hook event at all, the debrief says so in `not_tracked` (agy
hooks are opt-in). Transcript mining covers Claude, Muse, and
Antigravity (`agy`), including `agy` skill loads (`read_file`/`view_file`
reads of `SKILL.md`), tool mix, errors, response gaps, subagents, models,
and workspace projects; Codex and OpenCode remain labeled exclusions, never
ranked. Multi-machine: each machine writes its own log;
`scripts/debrief.sh aggregate --log a.jsonl --log b.jsonl` merges them.

**Debrief v2 pipeline.** `scripts/debrief.sh` replaces the old single-stage
text report with a four-subcommand local pipeline:
- `scripts/debrief.sh prepare [--days 30] [--since DATE] [--max-new 100] [--batch-size 10] [--project SUB] [--harness muse,agy,claude]` — extracts and mtime-caches Stage 1 session metadata and bounded digests across Muse, `agy`, and Claude under `$XDG_DATA_HOME/eshu-agent-kit/debrief-cache/`, imports native `~/.claude/usage-data/facets/*.json`, rolls child subagents into their parent coordinator digest, skips trivial sessions, and writes batched digests for fast-tier Stage 2 facet classification.
- `scripts/debrief.sh cache-write <FILE|->` — validates and atomically stores Stage 2 semantic facet JSON records in the local cache (never committed or uploaded).
- `scripts/debrief.sh aggregate [--days 30] [--since DATE] [--log PATH]... [--repo PATH]... [--project SUB] [--harness ...] [--out FILE]` — merges Stage 1 metadata, Stage 2 facets, hook logs (`skills-usage.jsonl`), multi-agent parallel overlap, and git rollups (anchoring bare `--since YYYY-MM-DD` at UTC midnight).
- `scripts/debrief.sh render --aggregate AGG.json --synthesis SYN.json [--out FILE]` — renders an offline interactive HTML report to `$XDG_DATA_HOME/eshu-agent-kit/debrief-reports/report-YYYY-MM-DD-HHMMSS.html` and `report-latest.html`.

**Debrief skill.** Invoke `/debrief` (loaded from `skills/eshu/debrief/SKILL.md`)
to run `prepare`, classify uncached batches in parallel with fast-tier
subagents, run `aggregate`, synthesize evidence-backed `AGENTS.md`/role/hook
recommendations, and `render` the interactive offline HTML report.

**Limits.** Hook telemetry stays strictly content-free; semantic facets stay
local in `$XDG_DATA_HOME/eshu-agent-kit/debrief-cache/`. Aggregates and model-estimated
facets show correlation, not causation — never rank people or harnesses, and
treat `no-progress-session share` as coincidence until corroborated.
